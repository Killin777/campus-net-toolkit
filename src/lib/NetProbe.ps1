#Requires -Version 5.1
<#
    src/lib/NetProbe.ps1 — 分层网络探测（只读）
    · 所有请求强制绕过系统代理（Proxy=$null），结论代表"链路本身"
    · 每个探测点采样 2 次取多数，抗单次丢包
    · 输出的对象可直接喂给 NetLayers.ps1 的 Resolve-LayerConclusion
    调用方先加载 Common.ps1 与 NetLayers.ps1。
#>

function Resolve-ProbeMajority {
    param([bool[]]$Samples)
    # 2 次采样：至少一次通过即算通过；空输入为未知
    $list = @($Samples)
    if ($list.Count -eq 0) { return 'Unknown' }
    $passed = @($list | Where-Object { $_ }).Count
    if ($passed * 2 -gt $list.Count) { return 'Ok' }
    return 'Fail'
}

function Invoke-ProbeRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$TimeoutMs = 2500,
        [string[]]$ExpectBody = @()
    )
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) { return $false }
    $request = [Net.HttpWebRequest]::Create($uri)
    $request.Proxy = $null              # 关键：直连探测，避免把代理状态混进结论
    $request.AllowAutoRedirect = $false # 重定向单独判定，用于识别门户劫持
    $request.Timeout = $TimeoutMs
    $request.ReadWriteTimeout = $TimeoutMs
    $request.UserAgent = 'CampusNetToolkit/layer-probe'
    $response = $null
    $reader = $null
    try {
        $response = $request.GetResponse()
        $code = [int]$response.StatusCode
        if ($code -lt 200 -or $code -ge 400) { return $false }
        if ($ExpectBody.Count -gt 0) {
            $reader = New-Object IO.StreamReader($response.GetResponseStream())
            $body = $reader.ReadToEnd()
            foreach ($key in $ExpectBody) { if ($body -notlike "*$key*") { return $false } }
        }
        return $true
    } catch [Net.WebException] {
        return $false
    } catch {
        return $false
    } finally {
        if ($reader) { $reader.Dispose() }
        if ($response) { $response.Close() }
        $request.Abort()
    }
}

function Get-DefaultProbeEndpoints {
    param([ValidateSet('Domestic','Intl')][string]$Layer)
    if ($Layer -eq 'Intl') {
        return @(
            @{ Name = 'cloudflare'; Url = 'https://www.cloudflare.com/cdn-cgi/trace' }
            @{ Name = 'google'; Url = 'https://www.google.com/generate_204' }
        )
    }
    return @(
        @{ Name = '小米'; Url = 'http://connect.rom.miui.com/generate_204' }
        @{ Name = '百度'; Url = 'https://www.baidu.com' }
        @{ Name = '腾讯'; Url = 'http://www.qq.com' }
    )
}

function Get-ProbeEndpoints {
    param([ValidateSet('Domestic','Intl')][string]$Layer)
    $root = if ($script:DataRoot) { $script:DataRoot } else { Join-Path $env:LOCALAPPDATA 'CampusNetToolkit' }
    $path = Join-Path $root 'config\probe-endpoints.json'
    if (Test-Path -LiteralPath $path) {
        try {
            $doc = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            $list = @($doc.$Layer)
            $out = @()
            foreach ($item in $list) {
                if (-not $item -or -not $item.url) { continue }
                $name = if ($item.name) { [string]$item.name } else { [string]$item.url }
                $out += @{ Name = $name; Url = [string]$item.url }
            }
            if ($out.Count -gt 0) { return $out }
        } catch { }
    }
    return (Get-DefaultProbeEndpoints -Layer $Layer)
}

function Get-LayerProbes {
    param(
        [hashtable]$Counters = @{},
        [int]$TimeoutMs = 2500
    )
    $now = Get-Date

    # ---- L1 DNS：国内 + 境外各解析一次 ----
    $dnsCn = $false
    $dnsIntl = $false
    try { $dnsCn = [bool](Resolve-DnsName 'www.baidu.com' -Type A -ErrorAction Stop) } catch { $dnsCn = $false }
    try { $dnsIntl = [bool](Resolve-DnsName 'www.cloudflare.com' -Type A -ErrorAction Stop) } catch { $dnsIntl = $false }
    $dnsState = if ($dnsCn) { 'Ok' } else { 'Fail' }
    $dnsDetail = if ($dnsCn -and $dnsIntl) { '国内外域名均可解析' }
                 elseif ($dnsCn) { '国内可解析；境外域名解析失败（可能被污染）' }
                 else { '域名解析失败' }

    # ---- L2 国内出口：每个端点各采 2 次，记录每个链接的结果 ----
    $domesticPoints = @(Get-ProbeEndpoints -Layer Domestic)
    $domPassed = 0
    $domTotal = 0
    $domFailures = @()
    $domResults = @()
    foreach ($point in $domesticPoints) {
        $samples = @()
        $lastMs = -1
        for ($i = 0; $i -lt 2; $i++) {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $ok = Invoke-ProbeRequest -Url $point.Url -TimeoutMs $TimeoutMs
            $sw.Stop()
            $samples += $ok
            if ($ok) { $lastMs = [int]$sw.ElapsedMilliseconds }
        }
        $domTotal++
        $pointOk = ((Resolve-ProbeMajority -Samples $samples) -eq 'Ok')
        $domResults += [pscustomobject]@{ Name = [string]$point.Name; Url = [string]$point.Url; Ok = $pointOk; Ms = $lastMs }
        if ($pointOk) { $domPassed++ } else { $domFailures += $point.Name }
    }
    $domState = if ($domPassed -eq 0) { 'Fail' } elseif ($domPassed -eq $domTotal) { 'Ok' } else { 'Partial' }
    $domDetail = if ($domPassed -eq $domTotal) { "直连探测：国内 $domTotal/$domTotal 通过" }
                 elseif ($domPassed -gt 0) { "直连探测：国内 $domPassed/$domTotal 通过（$($domFailures -join '、') 失败）" }
                 else { '直连探测：国内探测点全部失败' }

    # ---- L3 国际出口：用配置里的端点逐个测，cloudflare trace 仍校验正文 ----
    $intlPoints = @(Get-ProbeEndpoints -Layer Intl)
    $intlResults = @()
    foreach ($point in $intlPoints) {
        $expect = @()
        if ($point.Url -match 'cloudflare\.com/cdn-cgi/trace') { $expect = @('ip=', 'loc=') }
        $samples = @()
        $lastMs = -1
        for ($i = 0; $i -lt 2; $i++) {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $ok = Invoke-ProbeRequest -Url $point.Url -TimeoutMs $TimeoutMs -ExpectBody $expect
            $sw.Stop()
            $samples += $ok
            if ($ok) { $lastMs = [int]$sw.ElapsedMilliseconds }
        }
        $pointOk = ((Resolve-ProbeMajority -Samples $samples) -eq 'Ok')
        $intlResults += [pscustomobject]@{ Name = [string]$point.Name; Url = [string]$point.Url; Ok = $pointOk; Ms = $lastMs }
    }
    $intlTotal = $intlResults.Count
    $intlPassed = @($intlResults | Where-Object { $_.Ok }).Count
    $intlFailures = @($intlResults | Where-Object { -not $_.Ok } | ForEach-Object { $_.Name })
    $intlState = if ($intlTotal -eq 0) { 'Unknown' } elseif ($intlPassed -eq 0) { 'Fail' } elseif ($intlPassed -eq $intlTotal) { 'Ok' } else { 'Partial' }
    $intlDetail = if ($intlTotal -eq 0) { '没有配置国际探测点' }
                  elseif ($intlPassed -eq $intlTotal) { "直连探测：国际 $intlPassed/$intlTotal 通过" }
                  elseif ($intlPassed -gt 0) { "直连探测：国际 $intlPassed/$intlTotal 通过（$($intlFailures -join '、') 失败）" }
                  else { '直连探测：国际探测点全部失败' }

    [pscustomobject]@{
        Link     = $null    # 链路来自 NetworkMonitor，不在这里重复测
        Dns      = New-LayerState -State $dnsState -Detail $dnsDetail -At $now
        Domestic = New-LayerState -State $domState -Detail $domDetail -At $now -Passed $domPassed -Total $domTotal -Endpoints $domResults
        Intl     = New-LayerState -State $intlState -Detail $intlDetail -At $now -Passed $intlPassed -Total $intlTotal -Endpoints $intlResults
        At       = $now
    }
}
