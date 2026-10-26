#Requires -Version 5.1
<#
    src/lib/CampusPortal.ps1 — 校园网门户检测与自动弹窗

    职责边界（合规）：
      · 只做两件事：判断"是否已联网"，以及"把登录页打开"
      · 不替你输入账号密码，不代提交登录，不保存任何凭据
      · 密码记忆交给浏览器自带的密码管理器

    检测原理：
      访问系统/厂商的连通性探测地址，观察是否被劫持到门户：
        · 返回 204 / 预期文本  → 已联网
        · 返回 3xx 到别的地址  → 被门户劫持，取出跳转地址
        · 返回 200 但内容是登录页 → 直接就是门户

    用法（独立运行）：
      .\CampusPortal.ps1 check     打印状态
      .\CampusPortal.ps1 open      打开登录页
      .\CampusPortal.ps1 json      输出 JSON
#>
[CmdletBinding()]
param(
    [ValidateSet('check', 'open', 'json')]
    [string]$Action = 'check',
    [switch]$NoRun
)

$ErrorActionPreference = 'Continue'

# 输出编码统一为 UTF-8：被 GUI 重定向捕获时，避免按 GBK 解码出现乱码
if ([Console]::IsOutputRedirected) {
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
}

$script:ProjRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:CampusDataRoot = if ([string]::IsNullOrWhiteSpace($env:CAMPUS_NET_DATA_ROOT)) { $script:ProjRoot } else { $env:CAMPUS_NET_DATA_ROOT }
$script:CampusConfigPath = Join-Path $script:CampusDataRoot 'config\campus-config.json'
$script:CampusImportedConfigPath = Join-Path $script:CampusDataRoot 'runtime\imported-campus-config.json'

function Get-CampusConfig {
    $def = @{ portalUrl = ''; httpsProbe = 'https://www.baidu.com'; internalDomains = @(); internalNets = @() }
    # 旧安装配置的导入副本只作后备，用户手工配置最后覆盖；两处均只读。
    foreach ($path in @($script:CampusImportedConfigPath, $script:CampusConfigPath)) {
        if (Test-Path -LiteralPath $path) {
            try {
                $j = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($pr in $j.PSObject.Properties) { $def[$pr.Name] = $pr.Value }
            } catch { }
        }
    }
    return $def
}

function Test-PortalUrl {
    param([string]$Url)
    $uri = $null
    return (-not [string]::IsNullOrWhiteSpace($Url) -and
        [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -and
        $uri.Scheme -in @('http', 'https') -and -not [string]::IsNullOrWhiteSpace($uri.Host))
}

function Test-RealReach {
    param([string]$Url, [int]$TimeoutMs = 6000)
    if (-not (Test-PortalUrl $Url) -or ([Uri]$Url).Scheme -ne 'https') {
        return [pscustomobject]@{ Ok = $false; Known = $false; Skipped = $true; Detail = 'HTTPS 探测地址无效（仅支持绝对 HTTPS 地址）' }
    }
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path -LiteralPath $curl)) {
        return [pscustomobject]@{ Ok = $false; Known = $false; Skipped = $true; Detail = '未完成 HTTPS 实测（缺少系统 curl.exe）' }
    }
    $sec = [Math]::Max(2, [int]($TimeoutMs / 1000))
    try { $out = & $curl -s -o NUL -w '%{http_code}' --max-time $sec -- $Url 2>$null }
    catch { return [pscustomobject]@{ Ok = $false; Known = $false; Skipped = $true; Detail = '未完成 HTTPS 实测（curl.exe 无法运行）' } }
    $code = 0
    [void][int]::TryParse("$out", [ref]$code)
    $ok = ($LASTEXITCODE -eq 0 -and $code -ge 200 -and $code -lt 400)
    return [pscustomobject]@{ Ok = $ok; Known = $true; Skipped = $false; Detail = "HTTP $code" }
}
function Invoke-NoRedirect {
    param([string]$Url, [int]$TimeoutMs = 6000)
    $req = $null
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.AllowAutoRedirect = $false
        $req.Timeout = $TimeoutMs
        $req.ReadWriteTimeout = $TimeoutMs
        $req.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
        $req.Method = 'GET'
        $resp = $req.GetResponse()
        $code = [int]$resp.StatusCode
        $loc = "$($resp.Headers['Location'])"
        $body = ''
        try {
            $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $body = $sr.ReadToEnd()
            $sr.Close()
        } catch { }
        $resp.Close()
        return [pscustomobject]@{ Code = $code; Location = $loc; Body = $body; Error = '' }
    } catch [System.Net.WebException] {
        $ex = $_.Exception
        if ($ex.Response) {
            $r = $ex.Response
            $code = 0
            try { $code = [int]$r.StatusCode } catch { }
            $loc = ''
            try { $loc = "$($r.Headers['Location'])" } catch { }
            $body = ''
            try {
                $sr = New-Object System.IO.StreamReader($r.GetResponseStream())
                $body = $sr.ReadToEnd()
                $sr.Close()
            } catch { }
            try { $r.Close() } catch { }
            return [pscustomobject]@{ Code = $code; Location = $loc; Body = $body; Error = '' }
        }
        return [pscustomobject]@{ Code = 0; Location = ''; Body = ''; Error = "$($ex.Message)" }
    } catch {
        return [pscustomobject]@{ Code = 0; Location = ''; Body = ''; Error = "$($_.Exception.Message)" }
    } finally {
        if ($req) { try { $req.Abort() } catch { } }
    }
}

function Resolve-PortalUrl {
    param([string]$ProbeUrl, [string]$Location)
    if ([string]::IsNullOrWhiteSpace($Location)) { return '' }
    try {
        $uri = $null
        if ([Uri]::TryCreate($Location, [UriKind]::Absolute, [ref]$uri)) {
            if (Test-PortalUrl $uri.AbsoluteUri) { return $uri.AbsoluteUri }
            return ''
        }
        # 带协议却无效的地址不可再当相对路径拼接。
        if ($Location -match '^\s*[a-zA-Z][a-zA-Z0-9+.-]*:' -or -not (Test-PortalUrl $ProbeUrl)) { return '' }
        $uri = [Uri]::new([Uri]$ProbeUrl, $Location)
        if (Test-PortalUrl $uri.AbsoluteUri) { return $uri.AbsoluteUri }
    } catch { }
    return ''
}

function Test-IsLoginPage {
    param([string]$Body)
    if ([string]::IsNullOrWhiteSpace($Body)) { return $false }
    # 出现这些特征大概率是门户登录页
    return ($Body -match '(?i)<form|password|login|用户名|password|认证|上网|portal|srun|drcom|h3c')
}

function Get-CampusAuthState {
    param([int]$TimeoutMs = 6000)

    $probes = @(
        @{ Name = '小米 204'; Url = 'http://connect.rom.miui.com/generate_204'; Kind = '204' },
        @{ Name = '微软';     Url = 'http://www.msftconnecttest.com/connecttest.txt'; Kind = 'text'; Expect = 'Microsoft Connect Test' },
        @{ Name = '苹果';     Url = 'http://captive.apple.com/hotspot-detect.html'; Kind = 'text'; Expect = 'Success' }
    )

    foreach ($p in $probes) {
        $r = Invoke-NoRedirect -Url $p.Url -TimeoutMs $TimeoutMs
        if ($r.Error) { continue }

        # 3xx：被劫持
        if ($r.Code -ge 300 -and $r.Code -lt 400) {
            $portal = Resolve-PortalUrl -ProbeUrl $p.Url -Location $r.Location
            return [pscustomobject]@{
                Authenticated = $false
                PortalUrl     = $portal
                Probe         = $p.Name
                Code          = $r.Code
                Detail        = "探测地址返回 $($r.Code) 跳转，判定为门户劫持"
            }
        }

        # 204 / 预期文本：正常
        if ($p.Kind -eq '204' -and $r.Code -eq 204) {
            return [pscustomobject]@{ Authenticated = $true; PortalUrl = ''; Probe = $p.Name; Code = 204; Detail = '探测返回 204，已联网' }
        }
        if ($p.Kind -eq 'text' -and $r.Code -eq 200 -and $r.Body -match [regex]::Escape($p.Expect)) {
            return [pscustomobject]@{ Authenticated = $true; PortalUrl = ''; Probe = $p.Name; Code = 200; Detail = '探测文本匹配，已联网' }
        }

        # 200 但不是预期内容：可能是门户直接返回的登录页
        if ($r.Code -eq 200 -and (Test-IsLoginPage $r.Body)) {
            return [pscustomobject]@{
                Authenticated = $false
                PortalUrl     = $p.Url
                Probe         = $p.Name
                Code          = 200
                Detail        = '探测返回 200 但内容是登录页'
            }
        }
    }

    return [pscustomobject]@{
        Authenticated = $false
        PortalUrl     = ''
        Probe         = ''
        Code          = 0
        Detail        = '所有探测均失败：可能完全没网，或 HTTPS 门户无法从 HTTP 探测'
    }
}

function Get-CampusState {
    param([int]$TimeoutMs = 6000)
    $cfg = Get-CampusConfig
    $s = Get-CampusAuthState -TimeoutMs $TimeoutMs
    $configuredPortal = Resolve-PortalUrl -ProbeUrl '' -Location ([string]$cfg.portalUrl)

    if ($s.Authenticated) {
        # 二次确认：探测地址可能被门户放行，用真实 HTTPS 访问复核
        $probeUrl = if ($cfg.httpsProbe) { $cfg.httpsProbe } else { 'https://www.baidu.com' }
        $real = Test-RealReach -Url $probeUrl -TimeoutMs $TimeoutMs
        if ($real.Known -eq $false) {
            return [pscustomobject]@{
                Authenticated = $false
                PortalUrl     = $configuredPortal
                Probe         = $s.Probe
                Code          = $s.Code
                Detail        = "连通性探测通过；HTTPS 实测未完成（$($real.Detail)），联网状态尚未确认"
                VerificationKnown = $false
                HttpsVerified = $false
                Skipped       = $true
                Suspicious    = $false
            }
        }
        if (-not $real.Ok) {
            return [pscustomobject]@{
                Authenticated = $false
                PortalUrl     = $(if ($configuredPortal) { $configuredPortal } else { $s.PortalUrl })
                Probe         = $s.Probe
                Code          = $s.Code
                Detail        = "探测通过但实际访问 $probeUrl 失败（$($real.Detail)），门户可能只放行了探测地址"
                VerificationKnown = $true
                HttpsVerified = $false
                Suspicious    = $true
            }
        }
        $s | Add-Member -NotePropertyName VerificationKnown -NotePropertyValue $true -Force
        $s | Add-Member -NotePropertyName HttpsVerified -NotePropertyValue $true -Force
        $s.Detail = '连通性探测与 HTTPS 实测均通过'
        return $s
    }

    # 未认证：探测到的地址优先，否则用配置里的门户地址
    if ([string]::IsNullOrWhiteSpace($s.PortalUrl) -and $configuredPortal) {
        $s.PortalUrl = $configuredPortal
        $s.Detail = $s.Detail + '；已改用配置里的登录地址'
    }
    return $s
}
function Open-Portal($state) {
    if (-not $state) { $state = Get-CampusState }
    if ($state.Authenticated) { Write-Host '当前已联网，无需登录。' -ForegroundColor Green; return $false }
    if ([string]::IsNullOrWhiteSpace($state.PortalUrl)) {
        Write-Host ('未取到登录页地址：' + $state.Detail) -ForegroundColor Yellow
        Write-Host '可以在浏览器里随便打开一个 http 网站，通常会被自动跳到登录页。' -ForegroundColor DarkGray
        return $false
    }
    if (-not (Test-PortalUrl $state.PortalUrl)) {
        Write-Host '登录页地址无效：仅支持绝对 HTTP 或 HTTPS 网页地址。' -ForegroundColor Yellow
        return $false
    }
    Start-Process -FilePath $state.PortalUrl
    Write-Host ('已打开登录页：' + $state.PortalUrl) -ForegroundColor Green
    Write-Host '账号密码请自行输入，浏览器会提示是否记住。' -ForegroundColor DarkGray
    return $true
}

if (-not $NoRun) {
    switch ($Action) {
        'check' {
            $s = Get-CampusState
            if ($s.Authenticated) { Write-Host ("√ 已联网（连通性探测 + HTTPS 实测均通过；探测点 " + $s.Probe + "）") -ForegroundColor Green }
            elseif ($s.VerificationKnown -eq $false) {
                Write-Host ('! 联网状态未确认：' + $s.Detail) -ForegroundColor Yellow
            } else {
                Write-Host '× 尚未联网 / 被门户拦截' -ForegroundColor Yellow
                Write-Host ("  " + $s.Detail) -ForegroundColor DarkGray
                if ($s.PortalUrl) { Write-Host ("  登录页：" + $s.PortalUrl) -ForegroundColor Cyan }
            }
        }
        'open' { [void](Open-Portal (Get-CampusState)) }
        'json' { Get-CampusState | ConvertTo-Json -Depth 3 }
    }
}
