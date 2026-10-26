#Requires -Version 5.1
<#
    src/lib/RouteGuard.ps1 — 路由守卫

    回答一个问题：现在的网络配置里，有没有东西在偷偷抢流量、或者留下隐患？

    三项核心检查：
      1. 虚拟网卡抢占       metric 极低的 VPN/虚拟网卡 + 默认路由成本低于主链路
      2. TUN 与系统代理双开  两份劫持同时生效，容易出现"部分网站打不开"
      3. 代理端口对内网开放  监听非环回地址（含 0.0.0.0 / :: 和指定网卡地址）

    另附两项一致性检查（与 ProxyCtl 互补）：
      4. 代理残留           系统代理开着但端口已死
      5. PAC 与手动代理并存  PAC 会接管解析，手动代理设置形同虚设

    纯只读，不修改任何配置。

    用法（独立运行）：
      .\RouteGuard.ps1 check     打印报告
      .\RouteGuard.ps1 json      输出 JSON
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

# 虚拟/隧道类网卡的识别关键词
$script:VirtualPattern = '(?i)vpn|virtual|tun|tap|wireguard|tailscale|radmin|zerotier|openvpn|mihomo|sing-?box|clash|wintun|vmware|hyper-v|loopback'

function Get-WinInetState {
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $p = Get-ItemProperty $k -ErrorAction SilentlyContinue
    [pscustomobject]@{
        Enabled  = ($p.ProxyEnable -eq 1)
        Server   = "$($p.ProxyServer)"
        Override = "$($p.ProxyOverride)"
        PacUrl   = "$($p.AutoConfigURL)"
    }
}

function Test-RouteLoopbackAddress([string]$Address) {
    if ($Address -eq 'localhost') { return $true }
    $ip = $null
    return ([Net.IPAddress]::TryParse($Address, [ref]$ip) -and [Net.IPAddress]::IsLoopback($ip))
}

function Get-RouteProxyEndpoint([string]$server) {
    $unknown = [pscustomobject]@{ Known = $false; Host = ''; Port = 0; IsLoopback = $false }
    if ([string]::IsNullOrWhiteSpace($server)) { return $unknown }
    $v = $server.Trim()
    if ($v -match '=') {
        $http = ($v -split ';' | Where-Object { $_ -match '^\s*http=' } | Select-Object -First 1)
        if ($http) { $v = ($http -replace '^\s*http=', '') } else { $v = (($v -split ';')[0] -replace '^\s*[a-z]+=', '') }
    }
    if ($v -notmatch '^\s*(\[[^\]]+\]|[^:;\s]+):(\d+)\s*$') { return $unknown }
    $serverName = $Matches[1].Trim('[', ']')
    $port = 0
    if (-not [int]::TryParse($Matches[2], [ref]$port) -or $port -lt 1 -or $port -gt 65535) { return $unknown }
    return [pscustomobject]@{ Known = $true; Host = $serverName; Port = $port; IsLoopback = (Test-RouteLoopbackAddress $serverName) }
}

function Get-ProxyPortFromRegistry([string]$server) {
    return (Get-RouteProxyEndpoint $server).Port
}

function Get-DefaultRouteTable {
    $up = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' | Select-Object -ExpandProperty ifIndex)
    $routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                Where-Object { $up -contains $_.ifIndex -and $_.NextHop -and $_.NextHop -ne '0.0.0.0' })
    $out = foreach ($r in $routes) {
        [pscustomobject]@{
            InterfaceAlias = $r.InterfaceAlias
            NextHop        = $r.NextHop
            Cost           = [int]$r.RouteMetric + [int]$r.InterfaceMetric
            RouteMetric    = [int]$r.RouteMetric
            IfMetric       = [int]$r.InterfaceMetric
            IfIndex        = $r.ifIndex
        }
    }
    return @($out | Sort-Object Cost)
}

function New-Finding($id, $severity, $title, $detail, $fix) {
    [pscustomobject]@{ Id = $id; Severity = $severity; Title = $title; Detail = $detail; Fix = $fix }
}

function Get-RouteGuardReport {
    param([int]$ProxyPort = 0)

    $findings = New-Object System.Collections.ArrayList
    $wi = Get-WinInetState
    $proxyEndpoint = Get-RouteProxyEndpoint $wi.Server
    $inspectLocalPort = ($ProxyPort -gt 0 -or $proxyEndpoint.IsLoopback)
    if ($ProxyPort -le 0) { $ProxyPort = $proxyEndpoint.Port }
    $routes = Get-DefaultRouteTable

    # ---------- 1. 虚拟网卡抢占 ----------
    $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up')
    $risky = @()
    foreach ($a in $adapters) {
        if ($a.Name -notmatch $script:VirtualPattern) { continue }
        $ipif = Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if (-not $ipif) { continue }
        if ([int]$ipif.InterfaceMetric -le 5) {
            $rt = $routes | Where-Object { $_.IfIndex -eq $a.ifIndex } | Select-Object -First 1
            $risky += [pscustomobject]@{
                Name      = $a.Name
                Metric    = [int]$ipif.InterfaceMetric
                HasRoute  = [bool]$rt
                Cost      = if ($rt) { $rt.Cost } else { $null }
            }
        }
    }

    if ($risky.Count -eq 0) {
        [void]$findings.Add((New-Finding 'virtual-metric' 'ok' '虚拟网卡跃点' '没有发现跃点 ≤5 的虚拟网卡' ''))
    } else {
        $primary = if ($routes.Count -gt 0) { $routes[0] } else { $null }
        foreach ($r in $risky) {
            $detail = "「$($r.Name)」接口跃点 = $($r.Metric)（越低越优先）"
            $bad = $false
            if ($r.HasRoute -and $primary) {
                if ($r.Cost -le $primary.Cost) { $bad = $true; $detail += "；它的默认路由成本 $($r.Cost) ≤ 主链路 $($primary.InterfaceAlias) 的 $($primary.Cost)，会抢走流量" }
                else { $detail += "；有默认路由但成本 $($r.Cost) 高于主链路 $($primary.Cost)，暂不抢占" }
            } else {
                $detail += '；当前未挂默认路由，但当其他链路断开时会被启用'
            }
            [void]$findings.Add((New-Finding 'virtual-metric' $(if ($bad) { 'warn' } else { 'ok' }) "虚拟网卡「$($r.Name)」" $detail 'VPN 不使用时禁用该网卡，或把它的接口跃点提到 9000'))
        }
    }

    # ---------- 2. TUN 与系统代理双开 ----------
    $tun = @($adapters | Where-Object { $_.Name -match '(?i)mihomo|sing-?box|clash|wintun' })
    if ($tun.Count -gt 0 -and $wi.Enabled) {
        [void]$findings.Add((New-Finding 'tun-proxy-both' 'warn' 'TUN 与系统代理同时开启' `
            ("检测到 TUN 网卡（" + (($tun | ForEach-Object { $_.Name }) -join ', ') + '）且系统代理也开着，流量被劫持了两次，容易出现部分网站异常') `
            '二选一：要么关 TUN 用系统代理，要么关系统代理用 TUN'))
    } elseif ($tun.Count -gt 0) {
        [void]$findings.Add((New-Finding 'tun-proxy-both' 'warn' '仅 TUN 模式' `
            ("检测到 TUN 网卡（" + (($tun | ForEach-Object { $_.Name }) -join ', ') + '），此时系统代理开关是无效的——关掉它也照样走代理') `
            '要彻底直连，必须退出代理软件关闭 TUN'))
    } else {
        [void]$findings.Add((New-Finding 'tun-proxy-both' 'ok' 'TUN 状态' '没有代理 TUN 网卡，系统代理开关是有效的' ''))
    }

    # ---------- 3. 代理端口对内网开放 ----------
    $listen = @()
    $listenKnown = $false
    if ($ProxyPort -gt 0 -and $inspectLocalPort) {
        try {
            $listen = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object { $_.LocalPort -eq $ProxyPort })
            $listenKnown = $true
        } catch { }
        if (-not $listenKnown) {
            [void]$findings.Add((New-Finding 'lan-expose' 'warn' "本机端口 $ProxyPort" '无法读取监听信息，局域网暴露状态未知' ''))
        } elseif ($listen.Count -eq 0) {
            [void]$findings.Add((New-Finding 'lan-expose' 'ok' "本机端口 $ProxyPort" '本机未监听此端口' ''))
        } else {
            $exposed = @($listen | Where-Object { -not (Test-RouteLoopbackAddress $_.LocalAddress) })
            if ($exposed.Count -gt 0) {
                $addrs = ($exposed | ForEach-Object { $_.LocalAddress }) -join ', '
                [void]$findings.Add((New-Finding 'lan-expose' 'warn' "端口 $ProxyPort 监听非环回地址" `
                    "监听地址是 $addrs；可能接受局域网连接，是否可达还取决于防火墙。在校园网里可能被判定为私搭代理" `
                    '在代理客户端里关闭「允许局域网连接 / Allow LAN」'))
            } else {
                [void]$findings.Add((New-Finding 'lan-expose' 'ok' "端口 $ProxyPort" ("仅本机监听（" + (($listen | ForEach-Object { $_.LocalAddress }) -join ', ') + '）') ''))
            }
        }
    }

    # ---------- 4. 代理残留 ----------
    if ($wi.Enabled) {
        if (-not $proxyEndpoint.Known) {
            [void]$findings.Add((New-Finding 'stale-proxy' 'warn' '系统代理状态未知' '无法解析系统代理端点，未验证其可用性' '检查代理地址和端口格式'))
        } elseif (-not $proxyEndpoint.IsLoopback) {
            [void]$findings.Add((New-Finding 'stale-proxy' 'warn' '远端代理状态未知' `
                "系统代理指向 $($wi.Server)；未验证远端端点，本机监听信息不能判断它是否存活" ''))
        } else {
            $endpointListeners = $listen
            $endpointKnown = $listenKnown
            if ($proxyEndpoint.Port -ne $ProxyPort) {
                try {
                    $endpointListeners = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object { $_.LocalPort -eq $proxyEndpoint.Port })
                    $endpointKnown = $true
                } catch { $endpointKnown = $false }
            }
            $alive = $false
            foreach ($listener in $endpointListeners) {
                $localIp = $null
                if (-not [Net.IPAddress]::TryParse($listener.LocalAddress, [ref]$localIp)) { continue }
                if ($proxyEndpoint.Host -eq 'localhost') {
                    if ([Net.IPAddress]::IsLoopback($localIp) -or $localIp.Equals([Net.IPAddress]::Any) -or $localIp.Equals([Net.IPAddress]::IPv6Any)) { $alive = $true }
                } else {
                    $targetIp = [Net.IPAddress]::Parse($proxyEndpoint.Host)
                    if ($localIp.Equals($targetIp) -or
                        ($localIp.Equals([Net.IPAddress]::Any) -and $targetIp.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) -or
                        ($localIp.Equals([Net.IPAddress]::IPv6Any) -and $targetIp.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6)) { $alive = $true }
                }
            }
            if (-not $endpointKnown) {
                [void]$findings.Add((New-Finding 'stale-proxy' 'warn' '系统代理状态未知' '无法读取本机目标端点的监听信息，未验证代理可用性' ''))
            } elseif (-not $alive) {
                [void]$findings.Add((New-Finding 'stale-proxy' 'err' '代理残留' `
                    "系统代理开着（$($wi.Server)），但本机目标地址和端口没有进程监听，使用此代理的请求可能失败" `
                    '执行「代理开关」的关闭动作，或点「一键修复」'))
            } else {
                [void]$findings.Add((New-Finding 'stale-proxy' 'ok' '系统代理' "指向 $($wi.Server)，对应本机端点已监听（未验证代理协议）" ''))
            }
        }
    } else {
        [void]$findings.Add((New-Finding 'stale-proxy' 'ok' '系统代理' '未开启' ''))
    }

    # ---------- 5. PAC 与手动代理并存 ----------
    if ($wi.PacUrl -and $wi.Server) {
        [void]$findings.Add((New-Finding 'pac-conflict' 'warn' 'PAC 与手动代理并存' `
            "同时设置了 PAC（$($wi.PacUrl)）和手动代理（$($wi.Server)），PAC 会接管解析，手动设置形同虚设" `
            '只保留一种：要么用 PAC，要么用固定代理'))
    }

    return [pscustomobject]@{
        CheckedAt   = (Get-Date).ToString('s')
        ProxyPort   = $ProxyPort
        SystemProxy = $wi
        Routes      = $routes
        Findings    = @($findings)
        Worst       = $(if (@($findings | Where-Object Severity -eq 'err').Count -gt 0) { 'err' }
                        elseif (@($findings | Where-Object Severity -eq 'warn').Count -gt 0) { 'warn' }
                        else { 'ok' })
    }
}

function Show-RouteGuardReport {
    $r = Get-RouteGuardReport
    Write-Host ''
    Write-Host ("路由守卫  检查于 " + (Get-Date).ToString('HH:mm:ss')) -ForegroundColor Cyan
    Write-Host ('-' * 64) -ForegroundColor DarkGray
    foreach ($f in $r.Findings) {
        $mark = switch ($f.Severity) { 'ok' { '  √' } 'warn' { '  !' } default { '  ×' } }
        $color = switch ($f.Severity) { 'ok' { 'DarkGray' } 'warn' { 'Yellow' } default { 'Red' } }
        Write-Host ("{0} {1}" -f $mark, $f.Title) -ForegroundColor $color
        if ($f.Detail) { Write-Host ("      " + $f.Detail) -ForegroundColor DarkGray }
        if ($f.Fix) { Write-Host ("      → " + $f.Fix) -ForegroundColor DarkCyan }
    }
    Write-Host ('-' * 64) -ForegroundColor DarkGray
    $worst = switch ($r.Worst) { 'ok' { '未发现问题' } 'warn' { '发现需要注意的项' } default { '发现严重问题' } }
    Write-Host ("结论：" + $worst) -ForegroundColor $(switch ($r.Worst) { 'ok' { 'Green' } 'warn' { 'Yellow' } default { 'Red' } })
    Write-Host ''
    return $r
}

if (-not $NoRun) {
    switch ($Action) {
        'check' { [void](Show-RouteGuardReport) }
        'json'  { Get-RouteGuardReport | ConvertTo-Json -Depth 5 }
    }
}
