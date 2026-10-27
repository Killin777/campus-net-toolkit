#Requires -Version 5.1
<#
    后台只读监测。点源只声明函数；New 才创建一个可复用 runspace。
    UI 只调用 New/Request/Receive/Stop。默认30秒连接心跳、60秒质量检测、5秒代理轻读。
    网卡事件回调全部在 C# 中只置标志；不把 PowerShell scriptblock 交给无 runspace 的事件线程。
#>

function Resolve-NetworkConclusion {
    param([Parameter(Mandatory=$true)]$Snapshot)
    if (-not $Snapshot.Connection -or -not $Snapshot.Proxy -or -not $Snapshot.Quality) { throw '快照缺少 Connection/Proxy/Quality 证据' }
    $connection=$Snapshot.Connection; $proxy=$Snapshot.Proxy; $quality=$Snapshot.Quality
    $state='Unknown'; $title='外网尚未验证'; $detail=[string]$quality.Detail; $action='Refresh'
    $checkedAt=$quality.CheckedAt
    if (-not $connection.Known) {
        $title='连接状态未知'; $detail='无法读取网卡连接状态：' + $connection.Error; $checkedAt=$connection.CheckedAt
    } elseif (-not $connection.Connected) {
        $state='Offline'; $title='未检测到已连接的网卡'; $detail=[string]$connection.Detail; $action='InspectConnection'; $checkedAt=$connection.CheckedAt
        if ($connection.ConnectionType -eq 'Ethernet') { $title='有线连接已断开' }
        elseif ($connection.ConnectionType -eq 'Wireless') { $title='无线网络尚未关联' }
    } elseif ($proxy.Known -and $proxy.Enabled -and $proxy.IsLocal -and $proxy.TargetKnown -and -not $proxy.Alive) {
        $state='ProxyIssue'; $title='系统代理指向未响应的本机端口'; $detail='实际手动代理目标未监听；该结果只说明系统代理目标，不能代表所有应用的代理方式。'; $action='InspectProxy'; $checkedAt=$proxy.CheckedAt
    } elseif (-not $quality.Known) {
        $title='外网尚未验证'
        if (-not $detail) { $detail='尚未完成外网探测；网卡连接和网关响应不能证明互联网可用。' }
    } elseif (($Snapshot.CheckedAt-[datetime]$quality.CheckedAt).TotalSeconds -gt 90) {
        $title='需要重新验证外网'; $detail='上次外网证据已超过90秒；当前只有连接或代理设置更新。'
    } else {
        switch ($quality.Kind) {
            'Online' { $state='Online'; $title='外网已验证可用'; $action='InspectNetwork' }
            'NeedsAuth' { $state='NeedsAuth'; $title='需要完成网页认证'; $action='OpenPortal' }
            'PossibleAuth' { $state='NeedsAuth'; $title='可能需要网页认证'; $action='InspectNetwork' }
            'Failed' { $state='ExternalFailure'; $title='网卡已连接，外网验证未通过'; $action='InspectNetwork' }
            default { $title='外网状态未知'; $action='Refresh' }
        }
    }
    return [pscustomobject]@{
        State=$state; Title=$title; Detail=$detail; Action=$action; PrimaryAction=$action
        CheckedAt=$checkedAt; Known=($state -ne 'Unknown'); Evidence=@($detail)
    }
}

function Resolve-MonitorQuality {
    param($Http, $Https, [string]$PortalUrl, [datetime]$CheckedAt)
    $kind='Unknown'; $known=$false; $detail='外网探测尚未完成'; $portal=''
    $httpOk=($Http.Known -and $Http.Code -eq 200 -and ([string]$Http.Body).Trim() -eq 'Microsoft Connect Test')
    $httpsOk=($Https.Known -and $Https.Code -ge 200 -and $Https.Code -lt 400)
    if ($httpOk -and $httpsOk) {
        $kind='Online'; $known=$true; $detail='HTTP预期文本与直接HTTPS访问均通过；这是本次探测目标的证据，不代表已验证代理出口。'
    } elseif ($Http.Known -and $Http.Code -ge 300 -and $Http.Code -lt 400) {
        $known=$true; $kind='PossibleAuth'; $detail='HTTP探测收到重定向，尚不能确认是否为校园认证。'
        $destination=$null; $configured=$null
        if ([Uri]::TryCreate([Uri]'http://www.msftconnecttest.com/connecttest.txt', [string]$Http.Location, [ref]$destination) -and
            $destination.Scheme -in @('http','https') -and [Uri]::TryCreate($PortalUrl,[UriKind]::Absolute,[ref]$configured) -and
            $configured.Scheme -in @('http','https') -and $destination.Host -eq $configured.Host) {
            $kind='NeedsAuth'; $portal=$destination.AbsoluteUri; $detail='HTTP探测被重定向到已配置的认证站点；需要在浏览器完成认证。'
        }
    } elseif ($Http.Known -and $Http.Code -eq 200 -and $Http.Body -match '(?is)<form\b.*(?:password|认证|用户名)') {
        $kind='PossibleAuth'; $known=$true; $detail='HTTP探测返回含登录表单的页面，可能需要认证；尚未确认校园门户。'
    } elseif ($Http.Known -and $Https.Known) {
        $kind='Failed'; $known=$true; $detail='HTTP预期响应或HTTPS验证未通过；这不足以确定是认证、DNS还是上游故障。'
    }
    $errors=@($Http.Error,$Https.Error | Where-Object { $_ })
    if ($errors.Count -gt 0) { $detail += ' ' + ($errors -join '；') }
    return [pscustomobject]@{
        Kind=$kind; Known=$known; CheckedAt=$CheckedAt; Detail=$detail; PortalUrl=$portal
        HttpVerified=$httpOk; HttpsVerified=$httpsOk; DnsKnown=($Http.Code -gt 0 -or $Https.Code -gt 0)
        DnsDetail='收到HTTP响应可证明本次目标已解析；未单独测量DNS服务器性能。'; Error=($errors -join '；')
    }
}

function Get-MonitorProxyState {
    param([int]$ConfiguredPort = 7897)
    $result=[pscustomobject]@{
        Known=$false; Enabled=$false; Endpoint=''; PacUrl=''; Port=$ConfiguredPort; Host=''
        Alive=$false; TargetKnown=$false; IsLocal=$false; CheckedAt=(Get-Date); Error=''; Detail='系统代理状态未知'
    }
    try {
        $reg=Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        $result.Known=$true; $result.Enabled=($reg.ProxyEnable -eq 1); $result.Endpoint=[string]$reg.ProxyServer; $result.PacUrl=[string]$reg.AutoConfigURL
        if (-not $result.Enabled) { $result.Detail='手动系统代理已关闭；不代表所有应用均为直连。'; return $result }
        $entries=@($result.Endpoint -split ';' | Where-Object { $_ })
        $entry=@($entries | Where-Object { $_ -match '^\s*http=' } | Select-Object -First 1)
        if ($entry.Count -eq 0) { $entry=@($entries | Select-Object -First 1) }
        $value=([string]($entry | Select-Object -First 1)) -replace '^\s*\w+=',''
        $port=0
        if ($value -notmatch '^\s*(\[[^\]]+\]|[^:;\s]+):(\d{1,5})\s*$') { $result.Detail='无法解析实际手动代理目标，目标可用性未验证。'; return $result }
        $targetHost=$Matches[1].Trim('[',']')
        if (-not [int]::TryParse($Matches[2],[ref]$port) -or $port -lt 1 -or $port -gt 65535) { $result.Detail='手动代理端口无效，目标可用性未验证。'; return $result }
        $result.Host=$targetHost; $result.Port=$port
        $address=$null
        $isAddress=[Net.IPAddress]::TryParse($targetHost,[ref]$address)
        $result.IsLocal=($targetHost -eq 'localhost' -or ($isAddress -and [Net.IPAddress]::IsLoopback($address)))
        if (-not $result.IsLocal) { $result.Detail='系统代理指向远端目标；本轮轻读不将本机监听状态当作远端代理证据。'; return $result }
        $listeners=[Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
        $result.TargetKnown=$true
        foreach ($listener in $listeners) {
            if ($listener.Port -ne $port) { continue }
            if (($targetHost -eq 'localhost' -and [Net.IPAddress]::IsLoopback($listener.Address)) -or
                ($isAddress -and ($listener.Address.Equals($address) -or $listener.Address.Equals([Net.IPAddress]::Any) -or $listener.Address.Equals([Net.IPAddress]::IPv6Any)))) {
                $result.Alive=$true; break
            }
        }
        $result.Detail=if ($result.Alive) { '本机代理目标端口正在监听；代理协议和出口尚未由此验证。' } else { '实际本机代理目标端口没有监听。' }
    } catch { $result.Error=$_.Exception.Message; $result.Detail='系统代理或本机监听状态读取失败：' + $result.Error; $result.TargetKnown=$false }
    return $result
}

function Get-MonitorConfiguration {
    param([string]$DataRoot)
    $config=[pscustomobject]@{ PortalUrl=''; HttpsProbe='https://www.baidu.com'; ProxyPort=7897; Errors=@() }
    foreach ($relative in @('runtime\imported-campus-config.json','config\campus-config.json','runtime\imported-proxy-config.json','config\proxy-config.json','runtime\proxy-settings.json')) {
        $path=Join-Path $DataRoot $relative
        if (-not [IO.File]::Exists($path)) { continue }
        try {
            $value=ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)) -ErrorAction Stop
            if ($value.portalUrl) { $config.PortalUrl=[string]$value.portalUrl }
            if ($value.httpsProbe) { $config.HttpsProbe=[string]$value.httpsProbe }
            if ($value.PSObject.Properties['port']) {
                $port=0
                if (-not [int]::TryParse([string]$value.port,[ref]$port) -or $port -lt 1 -or $port -gt 65535) { throw '代理配置的port无效' }
                $config.ProxyPort=$port
            }
        } catch { $config.Errors += ($relative + '：' + $_.Exception.Message) }
    }
    return $config
}

function New-NetworkProbeInfo {
    return [ordered]@{
        SSID='—'; Band='—'; Channel='—'; Signal='—'; Rssi='—'; IP='—'; Gateway='—'; DNS='—'; Adapter='—'; Link='—'
        ProxyOn=$false; ProxyPort=$false; ProxyNum=7897; ProxyKnown=$false; ProxyEndpoint=''; PacUrl=''
        ConnectionType='Unknown'; InterfaceIndex=0; LinkSpeedMbps=0
    }
}

function Resolve-MonitorPhysicalConnection {
    param([object[]]$Adapters, [object[]]$PhysicalAdapters, [bool]$PhysicalKnown)
    $result=[pscustomobject]@{ Known=$false; Connected=$false; ConnectionType='Unknown'; InterfaceIndex=0; Detail='尚未可靠识别物理网卡，虚拟网卡Up不作为物理连接证据。' }
    if (-not $PhysicalKnown -or $PhysicalAdapters.Count -eq 0) { return $result }
    $matched=@($Adapters | Where-Object { $PhysicalAdapters.InterfaceIndex -contains $_.InterfaceIndex })
    $up=@($matched | Where-Object { $_.OperationalStatus -eq 'Up' })
    $result.Connected=($up.Count -gt 0)
    $result.Known=($result.Connected -or $matched.Count -eq $PhysicalAdapters.Count)
    $selected=if ($up.Count -gt 0) { $up[0] } else { $PhysicalAdapters[0] }
    $result.ConnectionType=$selected.ConnectionType; $result.InterfaceIndex=$selected.InterfaceIndex
    if ($result.Known) {
        $result.Detail=if ($result.Connected) { '已识别的物理网卡处于连接状态；这不证明外网可用。' } else { '已识别的物理有线/无线接口均未连接；虚拟网卡状态未用于证明物理在线。' }
    }
    return $result
}

function Get-MonitorConnectionState {
    param($Previous, [switch]$Full, $Signal)
    $now=Get-Date
    $info=New-NetworkProbeInfo
    if ($Previous) {
        foreach ($key in @('SSID','Band','Channel','Signal','Rssi')) { $info[$key]=$Previous.Info[$key] }
    }
    $connection=[pscustomobject]@{
        Known=$false; Connected=$false; CheckedAt=$now; Detail='网卡状态未知'; Error=''; AdapterId=''
        ConnectionType='Unknown'; InterfaceIndex=0; HasDefaultRoute=$false; RouteKnown=$false; RouteCheckedAt=$null
        PhysicalAdapters=@(); PhysicalKnown=$false; PhysicalCheckedAt=$null; PhysicalInterfaceIndex=0
    }
    $errors=@()
    try {
        $adapters=@([Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object {
            $_.NetworkInterfaceType -ne [Net.NetworkInformation.NetworkInterfaceType]::Loopback -and
            $_.NetworkInterfaceType -ne [Net.NetworkInformation.NetworkInterfaceType]::Tunnel
        })
        $up=@($adapters | Where-Object { $_.OperationalStatus -eq [Net.NetworkInformation.OperationalStatus]::Up })
        $statuses=@($adapters | ForEach-Object {
            $ipv4=$_.GetIPProperties().GetIPv4Properties()
            [pscustomobject]@{
                InterfaceIndex=$(if ($ipv4) { $ipv4.Index } else { 0 }); OperationalStatus=$_.OperationalStatus.ToString()
                ConnectionType=$(if ($_.NetworkInterfaceType -eq [Net.NetworkInformation.NetworkInterfaceType]::Wireless80211) { 'Wireless' } elseif ($_.NetworkInterfaceType.ToString() -match 'Ethernet') { 'Ethernet' } else { 'Unknown' })
            }
        })
        if ($Full) {
            try {
                $physical=@(Get-NetAdapter -Physical -ErrorAction Stop)
                $connection.PhysicalAdapters=@($physical | ForEach-Object {
                    $index=[int]$_.ifIndex
                    $status=$statuses | Where-Object { $_.InterfaceIndex -eq $index } | Select-Object -First 1
                    [pscustomobject]@{ InterfaceIndex=$index; ConnectionType=$(if ($status) { $status.ConnectionType } else { 'Unknown' }) }
                })
                $connection.PhysicalKnown=($connection.PhysicalAdapters.Count -gt 0); $connection.PhysicalCheckedAt=$now
            } catch { $connection.Error='物理网卡识别失败：' + $_.Exception.Message; $errors += $connection.Error }
        } elseif ($Previous) {
            $connection.PhysicalAdapters=@($Previous.Connection.PhysicalAdapters); $connection.PhysicalKnown=$Previous.Connection.PhysicalKnown; $connection.PhysicalCheckedAt=$Previous.Connection.PhysicalCheckedAt
        }
        $physicalState=Resolve-MonitorPhysicalConnection -Adapters $statuses -PhysicalAdapters $connection.PhysicalAdapters -PhysicalKnown $connection.PhysicalKnown
        $connection.Known=$physicalState.Known; $connection.Connected=$physicalState.Connected; $connection.ConnectionType=$physicalState.ConnectionType
        $connection.PhysicalInterfaceIndex=$physicalState.InterfaceIndex; $connection.Detail=$physicalState.Detail
        if (-not $connection.Known -and -not $connection.Error) { $connection.Error=$physicalState.Detail }
        $routes=@()
        if ($Full -and $up.Count -gt 0) {
            try {
                $indices=@($up | ForEach-Object { $_.GetIPProperties().GetIPv4Properties().Index })
                $routes=@(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Where-Object { $indices -contains $_.InterfaceIndex -and $_.NextHop -ne '0.0.0.0' } | Sort-Object { [long]$_.RouteMetric+[long]$_.InterfaceMetric })
                $connection.RouteKnown=$true; $connection.HasDefaultRoute=($routes.Count -gt 0); $connection.RouteCheckedAt=$now
            } catch { $errors += ('默认出口读取失败：' + $_.Exception.Message) }
        } elseif (-not $Full -and $Previous) {
            $connection.RouteKnown=$Previous.Connection.RouteKnown; $connection.HasDefaultRoute=$Previous.Connection.HasDefaultRoute; $connection.RouteCheckedAt=$Previous.Connection.RouteCheckedAt
        } elseif ($Full) { $connection.RouteKnown=$true; $connection.RouteCheckedAt=$now }
        $selected=$null
        if ($routes.Count -gt 0) { $selected=$up | Where-Object { $_.GetIPProperties().GetIPv4Properties().Index -eq $routes[0].InterfaceIndex } | Select-Object -First 1 }
        elseif ($Previous -and $Previous.Connection.AdapterId) { $selected=$up | Where-Object { $_.Id -eq $Previous.Connection.AdapterId } | Select-Object -First 1 }
        if (-not $selected) { $selected=$up | Where-Object { $_.GetIPProperties().GatewayAddresses.Count -gt 0 } | Select-Object -First 1 }
        if (-not $selected) { $selected=$up | Select-Object -First 1 }
        if (-not $selected) { $selected=$adapters | Select-Object -First 1 }
        if ($selected) {
            $properties=$selected.GetIPProperties()
            $connection.AdapterId=$selected.Id; $info.Adapter=$selected.Name
            $info.ConnectionType=if ($selected.NetworkInterfaceType -eq [Net.NetworkInformation.NetworkInterfaceType]::Wireless80211) { 'Wireless' } elseif ($selected.NetworkInterfaceType.ToString() -match 'Ethernet') { 'Ethernet' } else { 'Unknown' }
            $ipv4=$properties.GetIPv4Properties()
            if ($ipv4) { $connection.InterfaceIndex=$ipv4.Index; $info.InterfaceIndex=$ipv4.Index }
            $ip=@($properties.UnicastAddresses | Where-Object { $_.Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and $_.Address.ToString() -notmatch '^169\.254\.' } | Select-Object -First 1)
            if ($ip.Count -gt 0) { $info.IP=$ip[0].Address.ToString() }
            if ($routes.Count -gt 0) { $info.Gateway=[string]$routes[0].NextHop }
            else {
                $gateway=$properties.GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and $_.Address.ToString() -ne '0.0.0.0' } | Select-Object -First 1
                if ($gateway) { $info.Gateway=$gateway.Address.ToString() }
            }
            $dns=@($properties.DnsAddresses | Where-Object { $_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork } | ForEach-Object { $_.ToString() })
            if ($dns.Count -gt 0) { $info.DNS=$dns -join ', ' }
            $info.LinkSpeedMbps=[Math]::Round(([double]$selected.Speed/1000000),1)
            if ($selected.Speed -ge 1000000000) { $info.Link='{0:N1} Gbps' -f ($selected.Speed/1000000000) }
            elseif ($selected.Speed -gt 0) { $info.Link='{0:N0} Mbps' -f $info.LinkSpeedMbps }
        }
        if ($info.ConnectionType -ne 'Wireless') { foreach ($key in @('SSID','Band','Channel','Signal','Rssi')) { $info[$key]='—' } }
        if ($Full -and $info.ConnectionType -eq 'Wireless' -and $connection.Connected) {
            $process=New-Object Diagnostics.Process
            $process.StartInfo=New-Object Diagnostics.ProcessStartInfo
            $process.StartInfo.FileName=Join-Path $env:SystemRoot 'System32\netsh.exe'; $process.StartInfo.Arguments='wlan show interfaces'
            $process.StartInfo.UseShellExecute=$false; $process.StartInfo.CreateNoWindow=$true; $process.StartInfo.RedirectStandardOutput=$true
            $process.StartInfo.StandardOutputEncoding=[Text.Encoding]::Default
            try {
                [void]$process.Start()
                if ($Signal) { $Signal.SetProcess($process) }
                if (-not $process.WaitForExit(1500)) { $process.Kill(); throw 'WLAN细节读取超时' }
                $wlan=$process.StandardOutput.ReadToEnd()
                if ($process.ExitCode -ne 0) { throw ('netsh退出码：' + $process.ExitCode) }
                if ($wlan -match '(?m)^\s*SSID\s*:\s*(.+)$') { $info.SSID=$Matches[1].Trim() }
                if ($wlan -match '(?:Band|频带)\s*:\s*(.+)') { $info.Band=$Matches[1].Trim() }
                if ($wlan -match '(?:Channel|信道)\s*:\s*(\d+)') { $info.Channel=$Matches[1] }
                if ($wlan -match '(?:Signal|信号)\s*:\s*(\d+)') { $info.Signal=$Matches[1]+'%' }
                if ($wlan -match 'Rssi\s*:\s*(-?\d+)') { $info.Rssi=$Matches[1]+' dBm' }
            } catch { $errors += ('WLAN细节未知：' + $_.Exception.Message) }
            finally { if ($Signal) { $Signal.ClearProcess($process) }; $process.Dispose() }
        }
    } catch { $connection.Known=$false; $connection.Error=$_.Exception.Message; $connection.Detail='网卡读取失败：' + $connection.Error; $errors += $connection.Detail }
    return [pscustomobject]@{ Info=$info; Connection=$connection; Errors=$errors }
}

function Invoke-MonitorHttpProbe {
    param([string]$Url, [switch]$ReadBody, [switch]$HttpsOnly, $Signal, [int]$TimeoutMs=2500)
    $uri=$null
    if (-not [Uri]::TryCreate($Url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -notin @('http','https') -or ($HttpsOnly -and $uri.Scheme -ne 'https')) {
        return [pscustomobject]@{ Known=$false; Code=0; Location=''; Body=''; Error='探测地址无效，仅支持HTTP/HTTPS。' }
    }
    $request=[Net.HttpWebRequest]::Create($uri)
    $request.Proxy=$null; $request.AllowAutoRedirect=$false; $request.Timeout=$TimeoutMs; $request.ReadWriteTimeout=$TimeoutMs
    $request.UserAgent='CampusNetToolkit/readonly-monitor'; $request.Method='GET'
    $response=$null; $reader=$null
    if ($Signal) { $Signal.SetRequest($request) }
    try {
        $response=$request.GetResponse()
        $body=''
        if ($ReadBody) {
            $reader=New-Object IO.StreamReader($response.GetResponseStream())
            $buffer=New-Object char[] 4096
            $count=$reader.ReadBlock($buffer,0,$buffer.Length)
            $body=New-Object string -ArgumentList @($buffer,0,$count)
        }
        return [pscustomobject]@{ Known=$true; Code=[int]$response.StatusCode; Location=[string]$response.Headers['Location']; Body=$body; Error='' }
    } catch [Net.WebException] {
        if ($_.Exception.Response) { $response=$_.Exception.Response; return [pscustomobject]@{ Known=$true; Code=[int]$response.StatusCode; Location=[string]$response.Headers['Location']; Body=''; Error=$_.Exception.Message } }
        return [pscustomobject]@{ Known=$true; Code=0; Location=''; Body=''; Error=$_.Exception.Message }
    } catch { return [pscustomobject]@{ Known=$false; Code=0; Location=''; Body=''; Error=$_.Exception.Message } }
    finally {
        if ($reader) { $reader.Dispose() }
        if ($response) { $response.Close() }
        if ($Signal) { $Signal.ClearRequest($request) }
        $request.Abort()
    }
}

function Get-NetworkProbeSnapshot {
    param([string]$ProjectRoot, [string]$DataRoot, $Previous, [switch]$Full, [switch]$Heartbeat, [switch]$ProxyOnly, $Signal, $ProgressQueue, $Counters)
    $now=Get-Date
    $config=if ($Full -or -not $Previous) { Get-MonitorConfiguration -DataRoot $DataRoot } else { $Previous.Configuration }
    $errors=@($config.Errors)
    if ($ProxyOnly -and $Previous) {
        $info=[ordered]@{}
        foreach ($key in $Previous.Info.Keys) { $info[$key]=$Previous.Info[$key] }
        $connection=$Previous.Connection
    } else {
        $local=Get-MonitorConnectionState -Previous $Previous -Full:$Full -Signal $Signal
        $info=$local.Info; $connection=$local.Connection; $errors += $local.Errors
    }
    $proxy=Get-MonitorProxyState -ConfiguredPort $config.ProxyPort
    $info.ProxyOn=$proxy.Enabled; $info.ProxyPort=$proxy.Alive; $info.ProxyNum=$proxy.Port; $info.ProxyKnown=$proxy.Known; $info.ProxyEndpoint=$proxy.Endpoint; $info.PacUrl=$proxy.PacUrl
    if ($proxy.Error) { $errors += $proxy.Error }
    $quality=if ($Previous) { $Previous.Quality } else { [pscustomobject]@{ Kind='Unknown'; Known=$false; CheckedAt=$now; Detail='尚未完成外网探测。'; PortalUrl=''; Error='' } }
    $ping=if ($Previous) { $Previous.GatewayPing } else { [pscustomobject]@{ Known=$false; Success=$false; Milliseconds=-1; CheckedAt=$now; Detail='网关未测量'; Error='' } }
    if (-not $ProxyOnly) {
        $ping=[pscustomobject]@{ Known=$false; Success=$false; Milliseconds=-1; CheckedAt=$now; Detail='没有可探测的IPv4网关'; Error='' }
        if ($connection.Known -and $connection.Connected -and $info.Gateway -ne '—') {
            $probe=New-Object Net.NetworkInformation.Ping
            try {
                $reply=$probe.Send([string]$info.Gateway,800)
                $ping.Known=$true; $ping.Success=($reply.Status -eq [Net.NetworkInformation.IPStatus]::Success); $ping.Milliseconds=$(if ($ping.Success) { [int]$reply.RoundtripTime } else { -1 })
                $ping.Detail=if ($ping.Success) { '网关回应ICMP；不代表互联网可用。' } else { '网关未回应ICMP；不能据此判断断网。' }
            } catch { $ping.Error=$_.Exception.Message; $ping.Detail='网关ICMP测量未完成；不能据此判断断网。'; $errors += $ping.Error }
            finally { $probe.Dispose() }
        }
    }
    if ($Full) {
        $quality=[pscustomobject]@{
            Kind='Unknown'; Known=$false; CheckedAt=$now; Detail='连接证据已更新，正在验证外网。'; PortalUrl=''; Error=''
            LastKnownAt=$(if ($Previous -and $Previous.Quality.Known) { $Previous.Quality.CheckedAt } elseif ($Previous) { $Previous.Quality.LastKnownAt } else { $null })
        }
        if ($null -ne $ProgressQueue) {
            $early=[pscustomobject]@{
                Info=$info; Connection=$connection; Proxy=$proxy; Quality=$quality; GatewayPing=$ping
                CheckedAt=(Get-Date); Errors=$errors; Configuration=$config; PendingQuality=$true; Counters=$Counters
            }
            $early | Add-Member -NotePropertyName Conclusion -NotePropertyValue (Resolve-NetworkConclusion $early)
            $ProgressQueue.Enqueue($early)
        }
        if ($connection.Known -and $connection.Connected) {
            $http=Invoke-MonitorHttpProbe -Url 'http://www.msftconnecttest.com/connecttest.txt' -ReadBody -Signal $Signal
            $https=Invoke-MonitorHttpProbe -Url $config.HttpsProbe -HttpsOnly -Signal $Signal
            $quality=Resolve-MonitorQuality -Http $http -Https $https -PortalUrl $config.PortalUrl -CheckedAt (Get-Date)
            if ($quality.Error) { $errors += $quality.Error }
        } else { $quality=[pscustomobject]@{ Kind='Unknown'; Known=$false; CheckedAt=$now; Detail='没有已确认的连接，未执行外网探测。'; PortalUrl=''; Error='' } }
    }
    $snapshot=[pscustomobject]@{
        Info=$info; Connection=$connection; Proxy=$proxy; Quality=$quality; GatewayPing=$ping
        CheckedAt=(Get-Date); Errors=$errors; Configuration=$config; Conclusion=$null; PendingQuality=$false
    }
    $snapshot.Conclusion=Resolve-NetworkConclusion -Snapshot $snapshot
    return $snapshot
}

function New-NetworkMonitor {
    param(
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$ProjectRoot,
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$DataRoot,
        [scriptblock]$Collector,
        [ValidateRange(1,3600)][int]$HeartbeatSeconds=30,
        [ValidateRange(1,3600)][int]$QualitySeconds=60,
        [ValidateRange(1,3600)][int]$ProxyPollSeconds=5
    )
    $ProjectRoot=[IO.Path]::GetFullPath($ProjectRoot); $DataRoot=[IO.Path]::GetFullPath($DataRoot)
    $module=Join-Path $ProjectRoot 'src\lib\NetworkMonitor.ps1'
    if (-not [IO.File]::Exists($module)) { throw 'ProjectRoot中缺少NetworkMonitor.ps1' }
    if (-not ('CampusNet.MonitorSignal' -as [type])) {
        # .NET事件线程只有C#回调。官方API：https://learn.microsoft.com/dotnet/api/system.net.networkinformation.networkchange
        Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.NetworkInformation;
using System.Diagnostics;
using System.Threading;
namespace CampusNet {
    public sealed class MonitorSignal : IDisposable {
        private readonly object gate = new object();
        private readonly AutoResetEvent wake = new AutoResetEvent(false);
        private int pending = 3;
        private bool cancelled;
        private HttpWebRequest request;
        private Process process;
        public bool Subscribed { get; private set; }
        public string CancellationError { get; private set; }
        public bool Cancelled { get { lock (gate) { return cancelled; } } }
        public MonitorSignal() {
            NetworkChange.NetworkAddressChanged += AddressChanged;
            NetworkChange.NetworkAvailabilityChanged += AvailabilityChanged;
            Subscribed = true;
        }
        private void AddressChanged(object sender, EventArgs e) { Request(true); }
        private void AvailabilityChanged(object sender, NetworkAvailabilityEventArgs e) { Request(true); }
        public void Request(bool full) { lock (gate) { if (cancelled) return; pending |= full ? 3 : 1; wake.Set(); } }
        public int Consume() { lock (gate) { int value = pending; pending = 0; return value; } }
        public bool Wait(int milliseconds) { return wake.WaitOne(milliseconds); }
        public void SetRequest(HttpWebRequest value) { lock (gate) { if (cancelled) value.Abort(); else request = value; } }
        public void ClearRequest(HttpWebRequest value) { lock (gate) { if (Object.ReferenceEquals(request, value)) request = null; } }
        public void SetProcess(Process value) { lock (gate) { if (cancelled) StopProcess(value); else process = value; } }
        public void ClearProcess(Process value) { lock (gate) { if (Object.ReferenceEquals(process, value)) process = null; } }
        private void StopProcess(Process value) {
            try { if (!value.HasExited) value.Kill(); }
            catch (InvalidOperationException error) { CancellationError = error.Message; }
        }
        public void Cancel() {
            lock (gate) {
                if (cancelled) return;
                cancelled = true;
                if (Subscribed) {
                    NetworkChange.NetworkAddressChanged -= AddressChanged;
                    NetworkChange.NetworkAvailabilityChanged -= AvailabilityChanged;
                    Subscribed = false;
                }
                if (request != null) request.Abort();
                if (process != null) StopProcess(process);
                wake.Set();
            }
        }
        public void Dispose() { Cancel(); wake.Dispose(); }
    }
}
'@ -ErrorAction Stop
    }
    $usesDefaultCollector=(-not $Collector)
    if ($usesDefaultCollector) { $Collector=${function:Get-NetworkProbeSnapshot} }
    $signal=New-Object CampusNet.MonitorSignal
    $queue=New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $runspace=[RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState='MTA'; $runspace.ThreadOptions='ReuseThread'
    $runspace.Open()
    $powershell=[PowerShell]::Create(); $powershell.Runspace=$runspace
    $worker={
        param($Module,$ProjectRoot,$DataRoot,$CollectorText,$Signal,$Queue,$HeartbeatSeconds,$QualitySeconds,$ProxyPollSeconds,$DefaultCollector)
        $ErrorActionPreference='Stop'
        . $Module
        $collector=[scriptblock]::Create($CollectorText)
        $previous=$null; $nextHeartbeat=[datetime]::MinValue; $nextQuality=[datetime]::MinValue; $nextProxy=[datetime]::MinValue
        $probeCount=0; $fullCount=0; $connectionCount=0; $proxyCount=0
        while (-not $Signal.Cancelled) {
            $flags=$Signal.Consume(); $now=Get-Date
            $full=(($flags -band 2) -ne 0 -or $now -ge $nextQuality)
            $heartbeat=(($flags -band 1) -ne 0 -or $now -ge $nextHeartbeat)
            $proxyOnly=(-not $full -and -not $heartbeat -and $now -ge $nextProxy)
            if (-not $full -and -not $heartbeat -and -not $proxyOnly) {
                $next=@($nextHeartbeat,$nextQuality,$nextProxy | Sort-Object | Select-Object -First 1)[0]
                [void]$Signal.Wait([Math]::Max(1,[int]($next-$now).TotalMilliseconds))
                continue
            }
            $probeCount++; $proxyCount++
            if ($full) { $fullCount++ }
            if (-not $proxyOnly) { $connectionCount++ }
            $counters=[pscustomobject]@{ ProbeCount=$probeCount; FullCount=$fullCount; ConnectionCount=$connectionCount; ProxyCount=$proxyCount }
            try {
                $arguments=@{ ProjectRoot=$ProjectRoot; DataRoot=$DataRoot; Previous=$previous; Full=$full; Heartbeat=$heartbeat; ProxyOnly=$proxyOnly; Signal=$Signal }
                if ($DefaultCollector) { $arguments.ProgressQueue=$Queue; $arguments.Counters=$counters }
                $snapshot=& $collector @arguments
                if ($Signal.Cancelled) { break }
                if ($null -eq $snapshot) { throw '采集器没有返回快照' }
                $snapshot | Add-Member -NotePropertyName Counters -NotePropertyValue $counters -Force
                $snapshot | Add-Member -NotePropertyName Conclusion -NotePropertyValue (Resolve-NetworkConclusion $snapshot) -Force
            } catch {
                if ($Signal.Cancelled) { break }
                $now=Get-Date
                $failedInfo=New-NetworkProbeInfo
                if ($previous) { foreach ($key in $previous.Info.Keys) { $failedInfo[$key]=$previous.Info[$key] } }
                $failedInfo.ProxyKnown=$false
                $snapshot=[pscustomobject]@{
                    CheckedAt=$now; Info=$failedInfo
                    Configuration=$(if ($previous) { $previous.Configuration } else { Get-MonitorConfiguration -DataRoot $DataRoot })
                    Connection=[pscustomobject]@{ Known=$false; Connected=$false; CheckedAt=$(if ($previous) { $previous.Connection.CheckedAt } else { $now }); Error=$_.Exception.Message }
                    Proxy=[pscustomobject]@{ Known=$false; Enabled=$false }
                    Quality=[pscustomobject]@{ Known=$false; Kind='Unknown'; CheckedAt=$(if ($previous) { $previous.Quality.CheckedAt } else { $now }); Detail='后台采集未完成：' + $_.Exception.Message }
                    Errors=@($_.Exception.Message); Counters=[pscustomobject]@{ ProbeCount=$probeCount; FullCount=$fullCount; ConnectionCount=$connectionCount; ProxyCount=$proxyCount }
                }
                $snapshot | Add-Member -NotePropertyName Conclusion -NotePropertyValue (Resolve-NetworkConclusion $snapshot)
            }
            if ($Signal.Cancelled) { break }
            $previous=$snapshot
            $discard=$null
            while ($Queue.TryDequeue([ref]$discard)) { $discard=$null }
            $Queue.Enqueue($snapshot)
            $now=Get-Date
            if ($full) { $nextQuality=$now.AddSeconds($QualitySeconds) }
            if ($full -or $heartbeat) { $nextHeartbeat=$now.AddSeconds($HeartbeatSeconds) }
            $nextProxy=$now.AddSeconds($ProxyPollSeconds)
        }
    }
    try {
        [void]$powershell.AddScript($worker.ToString()).AddArgument($module).AddArgument($ProjectRoot).AddArgument($DataRoot).AddArgument($Collector.ToString()).AddArgument($signal).AddArgument($queue).AddArgument($HeartbeatSeconds).AddArgument($QualitySeconds).AddArgument($ProxyPollSeconds).AddArgument($usesDefaultCollector)
        $handle=$powershell.BeginInvoke()
        return [pscustomobject]@{ Signal=$signal; Queue=$queue; PowerShell=$powershell; Runspace=$runspace; Handle=$handle; Stopped=$false; StopError='' }
    } catch { $signal.Dispose(); $powershell.Dispose(); $runspace.Dispose(); throw }
}

function Request-NetworkMonitorRefresh {
    param([Parameter(Mandatory=$true)]$Monitor, [switch]$Full)
    if (-not $Monitor.Stopped) { $Monitor.Signal.Request([bool]$Full) }
}

function Receive-NetworkMonitorSnapshot {
    param([Parameter(Mandatory=$true)]$Monitor)
    $latest=$null; $item=$null
    while ($Monitor.Queue.TryDequeue([ref]$item)) { $latest=$item; $item=$null }
    return $latest
}

function Stop-NetworkMonitor {
    param([Parameter(Mandatory=$true)]$Monitor)
    if ($Monitor.Stopped) { return }
    $Monitor.Signal.Cancel()
    try {
        if (-not $Monitor.Handle.IsCompleted) { $Monitor.PowerShell.Stop() }
        [void]$Monitor.PowerShell.EndInvoke($Monitor.Handle)
    } catch [Management.Automation.PipelineStoppedException] { $Monitor.StopError='' }
    catch { $Monitor.StopError=$_.Exception.Message }
    finally {
        $Monitor.PowerShell.Dispose(); $Monitor.Runspace.Dispose(); $Monitor.Signal.Dispose(); $Monitor.Stopped=$true
    }
}
