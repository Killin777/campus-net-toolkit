#Requires -Version 5.1
<#
    src/lib/CampusCheck.ps1 — 校园网体检（只读）

    六项检查，全部不修改系统：
      1. 认证状态      是否被门户拦截（复用 CampusPortal）
      2. DNS 是否合理  当前 DNS 是校内还是公共；两边解析耗时对比
      3. IPv6 可用性   有没有全局地址、能不能出去
      4. 路径 MTU      二分探测（校园网 PPPoE 常见 1480/1492，MTU 不对会随机卡顿）
      5. 代理绕过列表  校内网段是否被排除在代理之外
      6. 无线信号      按 dBm 分级，并给出"换位置/有线"的建议

    合规边界：只测量、只提示，不绕认证、不改账号相关设置、不碰共享。

    用法：
      .\CampusCheck.ps1 check
      .\CampusCheck.ps1 json
#>
[CmdletBinding()]
param(
    [ValidateSet('check', 'json')]
    [string]$Action = 'check',
    [switch]$NoRun
)

$ErrorActionPreference = 'Continue'

# 输出编码统一为 UTF-8：被 GUI 重定向捕获时，避免按 GBK 解码出现乱码
if ([Console]::IsOutputRedirected) {
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
}

$script:PortalScript = Join-Path $PSScriptRoot 'CampusPortal.ps1'

function New-Item3($id, $severity, $title, $detail, $fix) {
    [pscustomobject]@{ Id = $id; Severity = $severity; Title = $title; Detail = $detail; Fix = $fix }
}

function Test-Rfc1918([string]$ip) {
    if ($ip -match '^10\.') { return $true }
    if ($ip -match '^192\.168\.') { return $true }
    if ($ip -match '^172\.(1[6-9]|2\d|3[01])\.') { return $true }
    return $false
}

function Measure-DnsOnce([string]$Server, [string]$Domain) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $ok = $false
    try {
        $null = Resolve-DnsName $Domain -Server $Server -Type A -DnsOnly -ErrorAction Stop
        $ok = $true
    } catch { }
    $sw.Stop()
    if (-not $ok) { return -1 }
    return [int]$sw.ElapsedMilliseconds
}

function Test-MtuPayload([string]$Target, [int]$Payload) {
    try {
        $p = New-Object System.Net.NetworkInformation.Ping
        $opt = New-Object System.Net.NetworkInformation.PingOptions
        $opt.DontFragment = $true
        $buf = New-Object byte[] $Payload
        $r = $p.Send($Target, 3000, $buf, $opt)
        $p.Dispose()
        return ($r.Status -eq 'Success')
    } catch { return $false }
}

function Get-PathMtu([string]$Target) {
    # 二分必须以成功的探测为下界。ICMP 被过滤或链路不可达时不能推算 MTU。
    if (Test-MtuPayload $Target 1472) { return 1500 }
    if (-not (Test-MtuPayload $Target 1200)) { return $null }
    $lo = 1200; $hi = 1472
    while ($lo -lt $hi - 1) {
        $mid = [int][Math]::Floor(($lo + $hi) / 2)
        if (Test-MtuPayload $Target $mid) { $lo = $mid } else { $hi = $mid }
    }
    return $lo + 28
}

function Get-PrimaryAdapter {
    $up = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' | Select-Object -ExpandProperty ifIndex)
    $r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
         Where-Object { $up -contains $_.ifIndex -and $_.NextHop -and $_.NextHop -ne '0.0.0.0' } |
         Sort-Object RouteMetric | Select-Object -First 1
    return $r
}

function Get-CampusReport {

    $findings = New-Object System.Collections.ArrayList

    # ---------- 1. 认证状态 ----------
    $auth = $null
    if (Test-Path $script:PortalScript) {
        $previousAction = $Action
        $previousNoRun = $NoRun
        try {
            . $script:PortalScript -NoRun
            $auth = Get-CampusState
        } catch { $auth = $null }
        finally { $Action = $previousAction; $NoRun = $previousNoRun }
    }
    # 先判断是否在校园网：不在校园网时，"认证状态"这类检查没有意义，不能打勾
    $campusCfg = $null
    try { $campusCfg = Get-CampusConfig } catch { }
    $nets = @()
    if ($campusCfg) { $nets = @($campusCfg.internalNets | Where-Object { $_ }) }
    $ssid = ''
    $wl = (netsh wlan show interfaces) -join "`n"
    if ($wl -match '(?m)^\s*SSID\s*:\s*(.+)$') { $ssid = $Matches[1].Trim() }
    $route = Get-PrimaryAdapter
    $gw = if ($route) { [string]$route.NextHop } else { '' }
    $localIp = ''
    if ($route) {
        $localIp = (Get-NetIPAddress -InterfaceIndex $route.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.IPAddress -notmatch '^169\.254\.' } | Select-Object -First 1).IPAddress
    }
    # 无法判断时按"在校内"处理：宁可少报，也不能把通用体检误判成"不在校园网"
    $onCampus = $true
    $campusDetermined = $false
    if ($nets.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($localIp) -and -not [string]::IsNullOrWhiteSpace($gw)) {
        $campusDetermined = $true
        $onCampus = $false
        foreach ($n in $nets) {
            if ($localIp -like "$n*" -or $gw -like "$n*") { $onCampus = $true; break }
        }
    }
    if (-not $onCampus) {
        [void]$findings.Add((New-Item3 'campus' 'warn' '当前不在校园网' ("网络：" + $ssid + "，本机 " + $localIp + "，网关 " + $gw + "；认证状态、校园 DNS 等检查不适用") '连上校园 WiFi 或插网线后再跑这一项'))
    } elseif (-not $auth) {
        [void]$findings.Add((New-Item3 'auth' 'warn' '认证状态' '无法检测（缺少 CampusPortal.ps1）' ''))
    } elseif ($auth.Authenticated) {
        [void]$findings.Add((New-Item3 'auth' 'ok' '认证状态' $auth.Detail ''))
    } elseif ($auth.VerificationKnown -eq $false) {
        [void]$findings.Add((New-Item3 'auth' 'warn' '认证状态' $auth.Detail ''))
    } else {
        [void]$findings.Add((New-Item3 'auth' 'warn' '认证状态' $auth.Detail '点「校园网登录」打开登录页'))
    }

    # ---------- 2. DNS ----------
    $route = Get-PrimaryAdapter
    $ifAlias = if ($route) { $route.InterfaceAlias } else { '' }
    $dns = @()
    if ($ifAlias) {
        $dns = @((Get-DnsClientServerAddress -InterfaceAlias $ifAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses | Where-Object { $_ })
    }
    $internal = @($dns | Where-Object { Test-Rfc1918 $_ })
    $public   = @($dns | Where-Object { -not (Test-Rfc1918 $_) })

    $testDomain = 'www.baidu.com'
    $tInternal = if ($internal.Count -gt 0) { Measure-DnsOnce $internal[0] $testDomain } else { -1 }
    $tPublic   = Measure-DnsOnce '223.5.5.5' $testDomain

    $dnsDesc = if ($dns.Count -eq 0) { '未配置' } else { ($dns -join ', ') }
    $detail = "当前：$dnsDesc"
    $sev = 'ok'
    $fix = ''
    if ($internal.Count -gt 0) {
        $detail += "；内网 DNS 解析 $($tInternal)ms，公共 DNS $($tPublic)ms"
        if ($tInternal -lt 0) { $sev = 'warn'; $detail += '（内网 DNS 无响应）'; $fix = '内网 DNS 不通时，改用公共 DNS 更快' }
        elseif ($tPublic -gt 0 -and $tInternal -gt $tPublic * 3) { $sev = 'warn'; $fix = '内网 DNS 明显偏慢，可改用公共 DNS' }
    } else {
        $detail += "；未使用内网 DNS，公共 DNS 解析 $($tPublic)ms"
        if ($tPublic -lt 0) { $sev = 'err'; $detail += '（公共 DNS 也无响应）'; $fix = '检查网络是否已认证，或手动指定 DNS' }
    }
    [void]$findings.Add((New-Item3 'dns' $sev 'DNS 配置' $detail $fix))

    # ---------- 3. IPv6 ----------
    $v6all = @(Get-NetIPAddress -AddressFamily IPv6 -ErrorAction SilentlyContinue |
               Where-Object { $_.IPAddress -notmatch '^(fe80|::1)' -and $_.PrefixOrigin -ne 'WellKnown' })
    # 2000::/3 才是全球可路由；fc00::/7 是私有地址（ULA），不能当作"有公网 IPv6"
    $v6 = @($v6all | Where-Object { $_.IPAddress -match '^[23]' })
    $ula = @($v6all | Where-Object { $_.IPAddress -match '^(fc|fd)' })
    if ($v6.Count -eq 0 -and $ula.Count -gt 0) {
        [void]$findings.Add((New-Item3 'ipv6' 'warn' 'IPv6' ("只有私有地址（ULA " + $ula[0].IPAddress + "），没有全球可路由地址") '校园网 IPv6 需在自助服务开通，或确认 RA 是否下发全局前缀'))
    } elseif ($v6.Count -eq 0) {
        [void]$findings.Add((New-Item3 'ipv6' 'warn' 'IPv6' '没有 IPv6 地址。校园网通常支持 IPv6，部分教育网资源需要它' '如需 IPv6，可在校园网自助服务里开通'))
    } else {
        $p6 = New-Object System.Net.NetworkInformation.Ping
        $ok6 = $false
        try { $ok6 = ($p6.Send('2400:3200::1', 2000).Status -eq 'Success') } catch { }
        $p6.Dispose()
        if ($ok6) {
            [void]$findings.Add((New-Item3 'ipv6' 'ok' 'IPv6' ("有全局地址 " + ($v6 | Select-Object -First 1).IPAddress + '，可访问 IPv6 网络') ''))
        } else {
            [void]$findings.Add((New-Item3 'ipv6' 'warn' 'IPv6' '有全局地址但出不去，可能是只有地址没路由' '在自助服务确认 IPv6 已开通'))
        }
    }

    # ---------- 4. 路径 MTU ----------
    $mtu = Get-PathMtu '223.5.5.5'
    if ($null -eq $mtu) {
        [void]$findings.Add((New-Item3 'mtu' 'warn' '路径 MTU' '无法测量（ICMP 无响应或链路不可达），当前 MTU 未知' ''))
    } elseif ($mtu -ge 1500) {
        [void]$findings.Add((New-Item3 'mtu' 'ok' '路径 MTU' '1500（标准以太网，无需调整）' ''))
    } elseif ($mtu -ge 1480) {
        [void]$findings.Add((New-Item3 'mtu' 'ok' '路径 MTU' "$mtu（常见于 PPPoE，属正常范围）" ''))
    } elseif ($mtu -ge 1400) {
        [void]$findings.Add((New-Item3 'mtu' 'ok' '路径 MTU' "$mtu（手机热点 / 4G 隧道封装常见，属正常）" ''))
    } else {
        [void]$findings.Add((New-Item3 'mtu' 'warn' '路径 MTU' "$mtu，偏小；大文件传输可能卡住" '若经常出现大文件卡住，可按此值调整网卡 MTU'))
    }

    # ---------- 5. 代理绕过列表 ----------
    $reg = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    $bypass = "$($reg.ProxyOverride)"
    $enabled = ($reg.ProxyEnable -eq 1)
    if (-not $enabled) {
        [void]$findings.Add((New-Item3 'bypass' 'ok' '代理绕过列表' '系统代理未开启，无需检查' ''))
    } else {
        $hasPrivate = ($bypass -match '172\.16|192\.168|10\.\*')
        if ($hasPrivate) {
            [void]$findings.Add((New-Item3 'bypass' 'ok' '代理绕过列表' '已包含内网网段，校内资源不会绕远路' ''))
        } else {
            [void]$findings.Add((New-Item3 'bypass' 'warn' '代理绕过列表' '未包含内网网段，访问校内资源会被代理拖慢甚至失败' '在代理客户端里把 10.* / 172.16-31.* / 192.168.* 加入直连'))
        }
    }

    # ---------- 6. 无线信号 ----------
    $wlan = (netsh wlan show interfaces) -join "`n"
    if ($wlan -match 'Rssi\s+:\s*(-?\d+)') {
        $rssi = [int]$Matches[1]
        $band = if ($wlan -match 'Band\s+:\s*(.+)') { $Matches[1].Trim() } else { '' }
        $q = if ($rssi -ge -55) { '优秀' } elseif ($rssi -ge -65) { '良好' } elseif ($rssi -ge -72) { '偏弱' } else { '很差' }
        $sev = if ($rssi -ge -65) { 'ok' } elseif ($rssi -ge -72) { 'warn' } else { 'err' }
        $fix = if ($rssi -lt -65) { '尽量靠近 AP，或改用有线；2.4GHz 干扰大时可切 5GHz 热点' } else { '' }
        [void]$findings.Add((New-Item3 'signal' $sev '无线信号' ("$rssi dBm（$q）  $band") $fix))
    } else {
        [void]$findings.Add((New-Item3 'signal' 'ok' '无线信号' '当前为有线连接' ''))
    }

    return [pscustomobject]@{
        CheckedAt = (Get-Date).ToString('s')
        Adapter   = $ifAlias
        Findings  = @($findings)
        Worst     = $(if (@($findings | Where-Object Severity -eq 'err').Count -gt 0) { 'err' }
                     elseif (@($findings | Where-Object Severity -eq 'warn').Count -gt 0) { 'warn' }
                     else { 'ok' })
    }
}

function Show-CampusReport {
    $r = Get-CampusReport
    Write-Host ''
    Write-Host ("校园网体检  " + (Get-Date).ToString('HH:mm:ss') + "  承载网卡: " + $r.Adapter) -ForegroundColor Cyan
    Write-Host ('-' * 66) -ForegroundColor DarkGray
    foreach ($f in $r.Findings) {
        $mark = switch ($f.Severity) { 'ok' { '  √' } 'warn' { '  !' } default { '  ×' } }
        $color = switch ($f.Severity) { 'ok' { 'DarkGray' } 'warn' { 'Yellow' } default { 'Red' } }
        Write-Host ("{0} {1}" -f $mark, $f.Title) -ForegroundColor $color
        if ($f.Detail) { Write-Host ("      " + $f.Detail) -ForegroundColor DarkGray }
        if ($f.Fix)    { Write-Host ("      → " + $f.Fix) -ForegroundColor DarkCyan }
    }
    Write-Host ('-' * 66) -ForegroundColor DarkGray
    $worst = switch ($r.Worst) { 'ok' { '未发现问题' } 'warn' { '有需要注意的项' } default { '有严重问题' } }
    Write-Host ("结论：" + $worst) -ForegroundColor $(switch ($r.Worst) { 'ok' { 'Green' } 'warn' { 'Yellow' } default { 'Red' } })
    Write-Host ''
    return $r
}

if (-not $NoRun) {
    switch ($Action) {
        'check' { [void](Show-CampusReport) }
        'json'  { Get-CampusReport | ConvertTo-Json -Depth 5 }
    }
}
