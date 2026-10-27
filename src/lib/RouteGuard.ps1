#Requires -Version 5.1
<#
    src/lib/RouteGuard.ps1 — 路由守卫

    检查当前默认路由候选、系统代理端点和监听范围。
    网卡名称只用作线索；配置并存不等于实际流量冲突。
    结构化证据供独立的逐项修复模块使用，本模块不执行修复。

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
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    try {
        $value = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
        return [pscustomobject]@{
            Known = $true; Error = ''; Enabled = ($value.ProxyEnable -eq 1)
            ProxyEnableExists = [bool]$value.PSObject.Properties['ProxyEnable']
            ProxyEnableValue = $value.ProxyEnable
            Server = [string]$value.ProxyServer; Override = [string]$value.ProxyOverride; PacUrl = [string]$value.AutoConfigURL
        }
    } catch {
        return [pscustomobject]@{ Known = $false; Error = $_.Exception.Message; Enabled = $false; ProxyEnableExists = $false; ProxyEnableValue = $null; Server = ''; Override = ''; PacUrl = '' }
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
    $up = @(Get-NetAdapter -ErrorAction Stop | Where-Object Status -eq 'Up' | Select-Object -ExpandProperty ifIndex)
    $routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
                Where-Object { $up -contains $_.ifIndex -and $_.NextHop })
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
    $routes = @()
    $routeError = ''
    try { $routes = @(Get-DefaultRouteTable) } catch { $routeError = $_.Exception.Message }
    $adapters = @()
    $adapterError = ''
    try { $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object Status -eq 'Up') } catch { $adapterError = $_.Exception.Message }
    $metricCandidates = New-Object System.Collections.ArrayList
    $physicalIndexes = @($adapters | Where-Object { $_.HardwareInterface -eq $true } | ForEach-Object { $_.ifIndex })
    $physical = $routes | Where-Object { $physicalIndexes -contains $_.IfIndex } | Sort-Object Cost | Select-Object -First 1

    # 名称只是线索；只有明确的非物理接口和另一物理默认路由才形成可比较证据。
    foreach ($adapter in $adapters) {
        $hardwareVirtual = ($adapter.PSObject.Properties['HardwareInterface'] -and $adapter.HardwareInterface -eq $false)
        if (-not $hardwareVirtual -and $adapter.Name -notmatch $script:VirtualPattern) { continue }
        try {
            $ipif = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop | Select-Object -First 1
            if (-not $ipif) { throw '没有读取到 IPv4 接口配置' }
        } catch {
            [void]$findings.Add((New-Finding 'virtual-metric' 'warn' ('接口「' + $adapter.Name + '」') ('无法读取接口跃点：' + $_.Exception.Message) '重新检测接口配置'))
            continue
        }
        $route = $routes | Where-Object { $_.IfIndex -eq $adapter.ifIndex } | Sort-Object Cost | Select-Object -First 1
        $competing = ($hardwareVirtual -and $route -and $physical -and $route.IfIndex -ne $physical.IfIndex -and $route.Cost -le $physical.Cost)
        $detail = '「' + $adapter.Name + '」接口跃点 = ' + $ipif.InterfaceMetric
        if ($routeError) { $detail += '；默认路由读取失败，当前路由状态未知：' + $routeError }
        elseif (-not $route) { $detail += '；当前无此接口的默认路由，未据此预测之后的出口' }
        elseif (-not $physical) { $detail += '；当前默认路由成本 ' + $route.Cost + '，没有可比较的物理默认路由' }
        else { $detail += '；默认路由成本 ' + $route.Cost + '，物理候选「' + $physical.InterfaceAlias + '」成本 ' + $physical.Cost }
        if (-not $hardwareVirtual) { $detail += '；名称仅为虚拟接口线索，未确认接口类型' }
        if ($competing) { $detail += '；该默认出口优先级不低于物理候选，可能是用户所需的 VPN 路径，未据此认定故障' }
        $fix = if ($competing) { '如需优先使用物理出口，可查看逐项处理中的具体目标值与影响' } else { '' }
        [void]$findings.Add((New-Finding 'virtual-metric' $(if ($competing) { 'warn' } else { 'ok' }) ('接口「' + $adapter.Name + '」') $detail $fix))
        [void]$metricCandidates.Add([pscustomobject]@{
            InterfaceIndex = [int]$adapter.ifIndex; InterfaceAlias = [string]$adapter.Name
            InterfaceMetric = [int]$ipif.InterfaceMetric; AutomaticMetric = [string]$ipif.AutomaticMetric
            HardwareVirtual = [bool]$hardwareVirtual; HasRoute = [bool]$route; Competing = [bool]$competing
            RouteMetric = $(if ($route) { [int]$route.RouteMetric } else { $null })
            RouteCost = $(if ($route) { [int]$route.Cost } else { $null })
            PhysicalInterfaceIndex = $(if ($physical) { [int]$physical.IfIndex } else { $null })
            PhysicalInterfaceAlias = $(if ($physical) { [string]$physical.InterfaceAlias } else { '' })
            PhysicalCost = $(if ($physical) { [int]$physical.Cost } else { $null })
        })
    }
    if ($adapterError -or $routeError) {
        [void]$findings.Add((New-Finding 'virtual-metric' 'warn' '默认路由状态未知' (($adapterError, $routeError | Where-Object { $_ }) -join '；') '重新检测'))
    } elseif ($metricCandidates.Count -eq 0) {
        [void]$findings.Add((New-Finding 'virtual-metric' 'ok' '默认路由候选' '没有发现需要比较的疑似虚拟接口' ''))
    }

    $tun = @($adapters | Where-Object { $_.Name -match '(?i)mihomo|sing-?box|clash|wintun' })
    if ($tun.Count -gt 0) {
        $tunDetail = '名称匹配到疑似 TUN 接口（' + (($tun | ForEach-Object { $_.Name }) -join ', ') + '）；名称仅为线索，未验证 TUN 是否承载当前流量'
        if ($wi.Enabled) { $tunDetail += '；手动系统代理已开启，配置并存不能确认双重代理或故障' }
        [void]$findings.Add((New-Finding 'tun-proxy-both' 'warn' '疑似 TUN 接口' $tunDetail '需要确认时查看代理客户端及实际出口设置'))
    } else {
        [void]$findings.Add((New-Finding 'tun-proxy-both' 'ok' 'TUN 线索' '没有匹配的 TUN 接口名称；未验证其他隧道或应用自己的代理路径' ''))
    }

    # ---------- 3. 代理端口对内网开放 ----------
    $listen = @()
    $listenKnown = $false
    if ($ProxyPort -gt 0 -and $inspectLocalPort) {
        try {
            $listen = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object { $_.LocalPort -eq $ProxyPort })
            $listenKnown = $true
        } catch { $listenKnown = $false }
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
    $endpointKnown = $false
    $alive = $false
    if ($wi.PSObject.Properties['Known'] -and -not $wi.Known) {
        [void]$findings.Add((New-Finding 'stale-proxy' 'warn' '系统代理状态未知' ('无法读取系统代理：' + $wi.Error) '重新检测'))
    } elseif ($wi.Enabled) {
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
                    '查看逐项处理中的关闭手动代理操作，或启动对应代理客户端'))
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
            "同时保存了 PAC（$($wi.PacUrl)）和手动代理（$($wi.Server)）；实际使用取决于应用和自动配置结果，未验证二者发生冲突" `
            '如有访问异常，核对应用实际采用的代理设置'))
    }

    return [pscustomobject]@{
        CheckedAt   = (Get-Date).ToString('s')
        ProxyPort   = $ProxyPort
        SystemProxy = $wi
        Routes      = $routes
        RoutesKnown = (-not $routeError -and -not $adapterError)
        MetricCandidates = @($metricCandidates)
        ProxyEvidence = [pscustomobject]@{
            Endpoint = $proxyEndpoint; ListenerKnown = $endpointKnown; ListenerAlive = $alive
            ManualDisableSupported = ($wi.Enabled -and $proxyEndpoint.IsLoopback -and $endpointKnown -and -not $alive -and $wi.Server -notmatch '[=;]')
        }
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
