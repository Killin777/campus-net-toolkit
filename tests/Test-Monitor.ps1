#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script:ProjRoot = $root
$script:DataRoot = Join-Path $root ('_qa\monitor-tests-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($script:DataRoot)
. (Join-Path $root 'src\lib\Common.ps1')
$monitorPath = Join-Path $root 'src\lib\NetworkMonitor.ps1'
$historyPath = Join-Path $root 'src\lib\LinkHistory.ps1'
if (Test-Path -LiteralPath $monitorPath) { . $monitorPath }
if (Test-Path -LiteralPath $historyPath) { . $historyPath }
$script:total = 0
$script:fail = 0
function Assert-True($condition, $message) { if (-not $condition) { throw $message } }
function Assert-Api([string]$name) {
    Assert-True ([bool](Get-Command $name -ErrorAction SilentlyContinue)) ('尚未实现接口：' + $name)
}
function Test-Case($name, [scriptblock]$test) {
    $script:total++
    try { & $test; Write-Host ('  PASS ' + $name) }
    catch { $script:fail++; Write-Host ('  FAIL ' + $name + ' : ' + $_.Exception.Message) -ForegroundColor Red }
}
function New-FixtureSnapshot([datetime]$at, [bool]$connected = $true) {
    return [pscustomobject]@{
        CheckedAt = $at
        Info = [ordered]@{ SSID='—'; Band='—'; Channel='—'; Signal='—'; Rssi='—'; IP='—'; Gateway='—'; DNS='—'; Adapter='fixture'; Link='—'; ProxyOn=$false; ProxyPort=$false; ProxyNum=7897; ProxyKnown=$true; ProxyEndpoint=''; PacUrl='' }
        Connection = [pscustomobject]@{ Known=$true; Connected=$connected; CheckedAt=$at; Detail='fixture'; Error='' }
        Proxy = [pscustomobject]@{ Known=$true; Enabled=$false; TargetKnown=$false; Alive=$false; IsLocal=$false; CheckedAt=$at; Error='' }
        Quality = [pscustomobject]@{ Kind='Unknown'; Known=$false; CheckedAt=$at; Detail='外网尚未验证'; PortalUrl=''; Error='' }
        Errors = @()
    }
}
function Write-FixtureJson([string]$relative, $value) {
    $path = Join-Path $script:DataRoot $relative
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
    [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $value -Depth 8), (New-Object Text.UTF8Encoding($true)))
}
function Wait-FixtureSnapshot($monitor, [int]$timeoutMs = 6000) {
    $until = [datetime]::UtcNow.AddMilliseconds($timeoutMs)
    do {
        $snapshot = Receive-NetworkMonitorSnapshot -Monitor $monitor
        if ($snapshot) { return $snapshot }
        Start-Sleep -Milliseconds 20
    } while ([datetime]::UtcNow -lt $until)
    throw '后台未在测试期限内产生快照'
}

Test-Case '仅网卡在线与网关响应不能确认外网在线' {
    Assert-Api 'Resolve-NetworkConclusion'
    $s = New-FixtureSnapshot (Get-Date)
    $s | Add-Member GatewayPing ([pscustomobject]@{ Known=$true; Success=$true })
    $r = Resolve-NetworkConclusion -Snapshot $s
    Assert-True ($r.State -eq 'Unknown' -and $r.Detail -match '未验证|未完成|未知') '局部连通被写成已联网'
}
Test-Case '已验证HTTP与HTTPS结果产生在线结论并保留证据时间' {
    Assert-Api 'Resolve-NetworkConclusion'
    $s = New-FixtureSnapshot (Get-Date)
    $s.Quality.Kind='Online'; $s.Quality.Known=$true; $s.Quality.Detail='HTTP预期文本与HTTPS均通过'
    $r = Resolve-NetworkConclusion $s
    Assert-True ($r.State -eq 'Online' -and $r.CheckedAt -eq $s.Quality.CheckedAt) '完整外网证据未形成在线结论'
}
Test-Case '已识别门户和不明跳转分别显示需要与可能需要认证' {
    Assert-Api 'Resolve-NetworkConclusion'
    $s = New-FixtureSnapshot (Get-Date)
    $s.Quality.Kind='NeedsAuth'; $s.Quality.Known=$true; $s.Quality.PortalUrl='https://portal.example/login'; $s.Quality.Detail='跳转至配置的认证页'
    Assert-True ((Resolve-NetworkConclusion $s).Action -eq 'OpenPortal') '已知门户缺少登录动作'
    $s.Quality.Kind='PossibleAuth'; $s.Quality.Detail='收到未知重定向，尚不能确认认证'
    $r = Resolve-NetworkConclusion $s
    Assert-True ($r.State -eq 'NeedsAuth' -and $r.Title -match '可能' -and $r.Action -ne 'OpenPortal') '未知跳转被断言为认证'
}
Test-Case '已知本机代理目标无响应优先提示代理异常' {
    Assert-Api 'Resolve-NetworkConclusion'
    $s = New-FixtureSnapshot (Get-Date)
    $s.Proxy.Enabled=$true; $s.Proxy.TargetKnown=$true; $s.Proxy.IsLocal=$true
    $r = Resolve-NetworkConclusion $s
    Assert-True ($r.State -eq 'ProxyIssue' -and $r.Action -eq 'InspectProxy') '已知本机代理异常未呈现'
    $s.Proxy.TargetKnown=$false
    Assert-True ((Resolve-NetworkConclusion $s).State -eq 'Unknown') '代理目标未知仍被判死'
}
Test-Case '网卡断开与外网探测失败保留不同结论' {
    Assert-Api 'Resolve-NetworkConclusion'
    $s = New-FixtureSnapshot (Get-Date) $false
    Assert-True ((Resolve-NetworkConclusion $s).State -eq 'Offline') '明确断开没有离线结论'
    $s.Connection.Connected=$true; $s.Quality.Kind='Failed'; $s.Quality.Known=$true; $s.Quality.Detail='HTTPS探测超时'
    Assert-True ((Resolve-NetworkConclusion $s).State -eq 'ExternalFailure') '网卡在线外网失败被写成在线'
    $s.Connection.Known=$false; $s.Connection.Error='无法读取网卡'
    Assert-True ((Resolve-NetworkConclusion $s).State -eq 'Unknown') '网卡读取失败被当作断开'
}
Test-Case '过期在线证据保留原时间并显示需要复检' {
    Assert-Api 'Resolve-NetworkConclusion'
    $s = New-FixtureSnapshot (Get-Date)
    $s.Quality.Kind='Online'; $s.Quality.Known=$true; $s.Quality.CheckedAt=$s.CheckedAt.AddMinutes(-3)
    $r = Resolve-NetworkConclusion $s
    Assert-True ($r.State -eq 'Unknown' -and $r.CheckedAt -eq $s.Quality.CheckedAt) '旧在线证据被当作持续实测'
}
Test-Case '任意HTTP重定向仅是认证线索' {
    Assert-Api 'Resolve-MonitorQuality'
    $http = [pscustomobject]@{ Known=$true; Code=302; Location='https://elsewhere.example/path'; Body=''; Error='' }
    $https = [pscustomobject]@{ Known=$true; Code=0; Error='连接失败' }
    $q = Resolve-MonitorQuality -Http $http -Https $https -PortalUrl 'https://portal.example/login' -CheckedAt (Get-Date)
    Assert-True ($q.Kind -eq 'PossibleAuth' -and $q.Detail -match '不能确认|尚未确认') '任意跳转被断言为认证'
    $http.Location='https://portal.example/login'
    $q = Resolve-MonitorQuality -Http $http -Https $https -PortalUrl 'https://portal.example/login' -CheckedAt (Get-Date)
    Assert-True ($q.Kind -eq 'NeedsAuth') '已知门户目标没有形成认证证据'
}
Test-Case '代理读取失败保留未知与具体错误' {
    Assert-Api 'Get-MonitorProxyState'
    function Get-ItemProperty { throw 'fixture registry denied' }
    $p = Get-MonitorProxyState
    Assert-True (-not $p.Known -and $p.Error -match 'fixture registry denied') '代理读取失败变成代理关闭'
}
Test-Case '代理配置读取不连接未验证的远端端点' {
    Assert-Api 'Get-MonitorProxyState'
    function Get-ItemProperty { return [pscustomobject]@{ ProxyEnable=1; ProxyServer='proxy.example:8080'; AutoConfigURL='' } }
    $p = Get-MonitorProxyState
    Assert-True ($p.Known -and -not $p.TargetKnown -and $p.Endpoint -eq 'proxy.example:8080') '远端代理未测却被确认失效'
}
Test-Case '后台采集合并重复请求且接收不会等待探测' {
    Assert-Api 'New-NetworkMonitor'
    $collector = {
        param($ProjectRoot, $DataRoot, $Previous, [switch]$Full, [switch]$Heartbeat, [switch]$ProxyOnly, $Signal)
        Start-Sleep -Milliseconds 450
        return [pscustomobject]@{ CheckedAt=(Get-Date); Info=[ordered]@{ Adapter='fixture' }; Connection=[pscustomobject]@{ Known=$true; Connected=$true; CheckedAt=(Get-Date) }; Proxy=[pscustomobject]@{ Known=$true; Enabled=$false }; Quality=[pscustomobject]@{ Kind='Unknown'; Known=$false; CheckedAt=(Get-Date); Detail='fixture' }; Errors=@() }
    }
    $m = New-NetworkMonitor -ProjectRoot $root -DataRoot $script:DataRoot -Collector $collector -HeartbeatSeconds 30 -QualitySeconds 60 -ProxyPollSeconds 5
    try {
        Start-Sleep -Milliseconds 100
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $pending = Receive-NetworkMonitorSnapshot $m
        $clock.Stop()
        Assert-True ($null -eq $pending -and $clock.ElapsedMilliseconds -lt 100) '接收快照阻塞了调用线程'
        for ($n=0; $n -lt 10; $n++) { Request-NetworkMonitorRefresh $m -Full }
        $first = Wait-FixtureSnapshot $m
        $second = Wait-FixtureSnapshot $m
        Assert-True ($first.Counters.ProbeCount -eq 1 -and $second.Counters.ProbeCount -eq 2) '重复事件没有合并成一轮后续采集'
        Start-Sleep -Milliseconds 600
        Assert-True ($null -eq (Receive-NetworkMonitorSnapshot $m)) '短时间内发生多余并行或重复采集'
    } finally { Stop-NetworkMonitor $m }
    Assert-True ($m.Stopped -and -not $m.Signal.Subscribed -and $m.Handle.IsCompleted) '停止后仍保留后台工作或事件订阅'
}
Test-Case '慢探测在停止时取消并释放runspace' {
    Assert-Api 'New-NetworkMonitor'
    $collector = { param($ProjectRoot, $DataRoot, $Previous, [switch]$Full, [switch]$Heartbeat, [switch]$ProxyOnly, $Signal) Start-Sleep -Seconds 10 }
    $m = New-NetworkMonitor -ProjectRoot $root -DataRoot $script:DataRoot -Collector $collector
    Start-Sleep -Milliseconds 200
    $clock = [Diagnostics.Stopwatch]::StartNew()
    Stop-NetworkMonitor $m
    $clock.Stop()
    Stop-NetworkMonitor $m
    Assert-True ($clock.ElapsedMilliseconds -lt 2000 -and $m.Stopped -and -not $m.Signal.Subscribed) ('慢探测未及时取消：' + $clock.ElapsedMilliseconds + 'ms')
}
Test-Case '代理轻读轮独立更新且不触发完整网卡采集' {
    Assert-Api 'New-NetworkMonitor'
    $collector = {
        param($ProjectRoot, $DataRoot, $Previous, [switch]$Full, [switch]$Heartbeat, [switch]$ProxyOnly, $Signal)
        return [pscustomobject]@{ CheckedAt=(Get-Date); Info=[ordered]@{ Adapter='fixture' }; Connection=[pscustomobject]@{ Known=$true; Connected=$true; CheckedAt=(Get-Date) }; Proxy=[pscustomobject]@{ Known=$true; Enabled=$ProxyOnly }; Quality=[pscustomobject]@{ Kind='Unknown'; Known=$false; CheckedAt=(Get-Date); Detail='fixture' }; ProxyOnly=[bool]$ProxyOnly; Errors=@() }
    }
    $m = New-NetworkMonitor -ProjectRoot $root -DataRoot $script:DataRoot -Collector $collector -ProxyPollSeconds 1
    try {
        $first = Wait-FixtureSnapshot $m
        $next = Wait-FixtureSnapshot $m
        Assert-True ($next.ProxyOnly -and $next.Counters.FullCount -eq 1 -and $next.Counters.ConnectionCount -eq 1 -and $next.Counters.ProxyCount -eq 2) '代理轻读轮重新采集了完整网卡/质量'
    } finally { Stop-NetworkMonitor $m }
}

Test-Case '后台首次采集失败仍返回完整Info与实际尝试次数' {
    Assert-Api 'New-NetworkMonitor'
    $collector = { param($ProjectRoot, $DataRoot, $Previous, [switch]$Full, [switch]$Heartbeat, [switch]$ProxyOnly, $Signal) throw 'fixture collector failed' }
    $m = New-NetworkMonitor -ProjectRoot $root -DataRoot $script:DataRoot -Collector $collector
    try {
        $s = Wait-FixtureSnapshot $m
        $required=@('SSID','Band','Channel','Signal','Rssi','IP','Gateway','DNS','Adapter','Link','ProxyOn','ProxyPort','ProxyNum','ProxyKnown','ProxyEndpoint','PacUrl','ConnectionType','InterfaceIndex','LinkSpeedMbps')
        $missing=@($required | Where-Object { -not $s.Info.Contains($_) })
        Assert-True ($s.Conclusion.State -eq 'Unknown' -and $s.Errors[0] -match 'fixture collector failed' -and $missing.Count -eq 0 -and $s.Counters.ProbeCount -eq 1) ('失败快照缺字段/计数：' + ($missing -join ','))
    } finally { Stop-NetworkMonitor $m }
}
Test-Case '取消真实等待中的本机HTTP请求无需等到请求超时' {
    Assert-Api 'New-NetworkMonitor'
    $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
    $listener.Start()
    $port=$listener.LocalEndpoint.Port
    $text=@'
param($ProjectRoot, $DataRoot, $Previous, [switch]$Full, [switch]$Heartbeat, [switch]$ProxyOnly, $Signal)
Invoke-MonitorHttpProbe -Url 'http://127.0.0.1:__PORT__/' -Signal $Signal -TimeoutMs 10000
'@
    $collector=[scriptblock]::Create($text.Replace('__PORT__',[string]$port))
    $m=New-NetworkMonitor -ProjectRoot $root -DataRoot $script:DataRoot -Collector $collector
    $client=$null
    try {
        $until=[datetime]::UtcNow.AddSeconds(4)
        while (-not $listener.Pending() -and [datetime]::UtcNow -lt $until) { Start-Sleep -Milliseconds 20 }
        Assert-True $listener.Pending() '后台未建立本机HTTP请求'
        $client=$listener.AcceptTcpClient()
        $clock=[Diagnostics.Stopwatch]::StartNew()
        Stop-NetworkMonitor $m
        $clock.Stop()
        Assert-True ($clock.ElapsedMilliseconds -lt 2000 -and $m.Stopped -and -not $m.Signal.Subscribed) ('取消HTTP耗时：' + $clock.ElapsedMilliseconds + 'ms')
        Write-Host ('    实际HTTP取消：{0}ms' -f $clock.ElapsedMilliseconds)
    } finally {
        Stop-NetworkMonitor $m
        if ($client) { $client.Close() }
        $listener.Stop()
    }
}
Test-Case '无SSID的有线连接可确认在线且保留有线失败结论' {
    Assert-Api 'Resolve-NetworkConclusion'
    $s=New-FixtureSnapshot (Get-Date)
    $s.Info.SSID='—'; $s.Info['ConnectionType']='Ethernet'; $s.Info['InterfaceIndex']=12; $s.Info['LinkSpeedMbps']=1000
    $s.Connection | Add-Member ConnectionType 'Ethernet'
    $s.Quality.Kind='Online'; $s.Quality.Known=$true; $s.Quality.Detail='HTTP预期文本与HTTPS均通过'
    $r=Resolve-NetworkConclusion $s
    Assert-True ($r.State -eq 'Online' -and $r.Title -notmatch 'WiFi|无线') '无SSID有线网络被当作断网'
    $s.Quality.Kind='Failed'; $s.Quality.Detail='有线连接仍Up，外网探测失败'
    Assert-True ((Resolve-NetworkConclusion $s).State -eq 'ExternalFailure') '有线Up被当作外网在线'
    $s.Connection.Connected=$false
    Assert-True ((Resolve-NetworkConclusion $s).Title -match '有线') '有线未连接仍显示无线关联文案'
}

Test-Case '物理有线断开时虚拟Ethernet的Up不能证明物理连接' {
    Assert-Api 'Resolve-MonitorPhysicalConnection'
    $adapters=@(
        [pscustomobject]@{ InterfaceIndex=12; OperationalStatus='Down'; ConnectionType='Ethernet' },
        [pscustomobject]@{ InterfaceIndex=112; OperationalStatus='Up'; ConnectionType='Ethernet' }
    )
    $physical=@([pscustomobject]@{ InterfaceIndex=12; ConnectionType='Ethernet' })
    $r=Resolve-MonitorPhysicalConnection -Adapters $adapters -PhysicalAdapters $physical -PhysicalKnown $true
    Assert-True ($r.Known -and -not $r.Connected -and $r.ConnectionType -eq 'Ethernet') '虚拟网卡Up掩盖了真实有线断开'
    $r=Resolve-MonitorPhysicalConnection -Adapters $adapters -PhysicalAdapters @() -PhysicalKnown $false
    Assert-True (-not $r.Known) '无法区分物理网卡时仍确认在线'
    $adapters[0].OperationalStatus='Up'
    $r=Resolve-MonitorPhysicalConnection -Adapters $adapters -PhysicalAdapters $physical -PhysicalKnown $true
    Assert-True ($r.Known -and $r.Connected) '实际有线Up没有被识别'
}
Test-Case '完整检测先发连接证据并使旧在线质量失效' {
    Assert-Api 'Get-NetworkProbeSnapshot'
    $queue=New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $script:earlySnapshot=$null
    function Get-MonitorConfiguration { return [pscustomobject]@{ PortalUrl=''; HttpsProbe='https://probe.example/'; ProxyPort=7897; Errors=@() } }
    function Get-MonitorConnectionState {
        $s=New-FixtureSnapshot (Get-Date)
        $s.Info['ConnectionType']='Ethernet'
        return [pscustomobject]@{ Info=$s.Info; Connection=$s.Connection; Errors=@() }
    }
    function Get-MonitorProxyState { return [pscustomobject]@{ Known=$true; Enabled=$false; Alive=$false; Port=7897; Endpoint=''; PacUrl=''; Error='' } }
    function Invoke-MonitorHttpProbe {
        param($Url, [switch]$ReadBody, [switch]$HttpsOnly, $Signal)
        if ($ReadBody) {
            $item=$null
            Assert-True ($queue.TryDequeue([ref]$item)) 'HTTP等待前没有发连接快照'
            Assert-True (-not $item.Quality.Known -and $item.Conclusion.State -ne 'Online') '换网后复用了旧Online'
            $script:earlySnapshot=$item
        }
        return [pscustomobject]@{ Known=$true; Code=200; Location=''; Body='Microsoft Connect Test'; Error='' }
    }
    $previous=New-FixtureSnapshot (Get-Date).AddSeconds(-20)
    $previous.Quality.Known=$true; $previous.Quality.Kind='Online'
    $snapshot=Get-NetworkProbeSnapshot -ProjectRoot $root -DataRoot $script:DataRoot -Previous $previous -Full -ProgressQueue $queue -Counters ([pscustomobject]@{ ProbeCount=1 })
    Assert-True ($snapshot.Quality.Kind -eq 'Online' -and $script:earlySnapshot.Counters.ProbeCount -eq 1 -and -not $script:earlySnapshot.Quality.Known) '连接与最终质量快照互相覆盖或计数失配'
}
Test-Case 'HTTPS验证入口拒绝普通HTTP地址' {
    Assert-Api 'Invoke-MonitorHttpProbe'
    $r=Invoke-MonitorHttpProbe -Url 'http://127.0.0.1:9/' -HttpsOnly
    Assert-True (-not $r.Known -and $r.Error -match 'HTTPS') '普通HTTP被作为HTTPS验证执行'
}
Test-Case '相同采样时间的维护信号也清除待定自然断链' {
    Assert-Api 'Update-LinkObservationTracker'
    $at=Get-Date
    $tracker=New-LinkObservationTracker
    $tracker=(Update-LinkObservationTracker $tracker (New-FixtureSnapshot $at $true)).Tracker
    $down=New-FixtureSnapshot $at.AddSeconds(30) $false
    $tracker=(Update-LinkObservationTracker $tracker $down).Tracker
    $tracker=(Update-LinkObservationTracker $tracker $down -Ignored).Tracker
    $r=Update-LinkObservationTracker $tracker (New-FixtureSnapshot $at.AddSeconds(60) $true)
    Assert-True ($null -eq $r.Event) '同一连接采样时间的维护没有中断断链记录'
}

Test-Case '旧断链记录兼容读取并保留来源与时长未知性' {
    Assert-Api 'Get-LinkEventStore'
    Write-FixtureJson 'runtime\link-events.json' @([ordered]@{ at=(Get-Date).ToString('o'); kind='断链'; seconds=15 })
    $read = Get-LinkEventStore -Result
    Assert-True ($read.Known -and $read.Records.Count -eq 1 -and $read.Records[0].Source -eq 'watchdog') '旧格式记录丢失'
    Assert-True (-not $read.Records[0].DurationKnown -and $read.Records[0].Estimate) '旧采样时长被当作精确实测'
}
Test-Case '坏记录读取必须可见且不能被追加覆盖' {
    Assert-Api 'Get-LinkEventStore'
    $path = Join-Path $script:DataRoot 'runtime\link-events.json'
    [IO.File]::WriteAllText($path, '{broken', (New-Object Text.UTF8Encoding($true)))
    $before = [IO.File]::ReadAllText($path)
    $read = Get-LinkEventStore -Result
    Assert-True (-not $read.Known -and $read.Error) '坏JSON被当作零记录'
    $thrown=$false
    try { Add-LinkEvent '断链' 30 'observer' } catch { $thrown=$true }
    Assert-True ($thrown -and [IO.File]::ReadAllText($path) -ceq $before) '追加静默覆盖坏历史'
}
Test-Case '新增记录通过原子保存并保留采样标志' {
    Assert-Api 'Add-LinkEvent'
    Write-FixtureJson 'runtime\link-events.json' @()
    $at = Get-Date
    Add-LinkEvent '断链' 30 'observer' -At $at -Start $at.AddSeconds(-30) -Estimate -LowerBoundSeconds 0
    $read = Get-LinkEventStore -Result
    Assert-True ($read.Known -and $read.Records.Count -eq 1 -and $read.Records[0].Estimate -and -not $read.Records[0].DurationKnown) '采样记录没有保留未知时长'
    Assert-True (@(Get-ChildItem (Join-Path $script:DataRoot 'runtime') -Filter '*.tmp').Count -eq 0) '原子保存遗留临时文件'
}
Test-Case '维护窗口统一排除工具、观察和WLAN会话' {
    Assert-Api 'Merge-LinkHistory'
    $now = Get-Date
    $events = @(
        [pscustomobject]@{ At=$now.AddSeconds(-20); Start=$now.AddSeconds(-40); Kind='断链'; Seconds=20; Source='watchdog'; DurationKnown=$false; Estimate=$true; LowerBoundSeconds=0 },
        [pscustomobject]@{ At=$now.AddSeconds(-300); Start=$now.AddSeconds(-330); Kind='断链'; Seconds=30; Source='observer'; DurationKnown=$false; Estimate=$true; LowerBoundSeconds=0 }
    )
    $windows = @([pscustomobject]@{ Start=$now.AddSeconds(-35); End=$now.AddSeconds(-25) }, [pscustomobject]@{ Start=$now.AddSeconds(-315); End=$now.AddSeconds(-310) })
    $r = Merge-LinkHistory -ToolRecords $events -SystemTimes @($now.AddSeconds(-30),$now.AddSeconds(-320)) -IgnoreWindows $windows -Since $now.AddDays(-1)
    Assert-True ($r.Sessions.Count -eq 0 -and $r.Ignored -eq 4) '某类来源或跨维护边界的会话未排除'
}
Test-Case '系统与工具同一会话合并且不补造系统持续时间' {
    Assert-Api 'Merge-LinkHistory'
    $now = Get-Date
    $tool = @([pscustomobject]@{ At=$now.AddSeconds(-100); Start=$now.AddSeconds(-130); Kind='断链'; Seconds=30; Source='observer'; DurationKnown=$false; Estimate=$true; LowerBoundSeconds=0 })
    $r = Merge-LinkHistory -ToolRecords $tool -SystemTimes @($now.AddSeconds(-125),$now.AddSeconds(-120),$now.AddSeconds(-600)) -IgnoreWindows @() -Since $now.AddDays(-1)
    Assert-True ($r.Sessions.Count -eq 2 -and $r.Merged -eq 1) '同一断开事件被重复计数'
    $withTool = @($r.Sessions | Where-Object { $_.Source -match 'observer' })[0]
    $systemOnly = @($r.Sessions | Where-Object { $_.Source -eq 'wlan' })[0]
    Assert-True ($withTool.Seconds -eq 30 -and $withTool.Estimate -and -not $systemOnly.DurationKnown -and $systemOnly.Seconds -eq 0) '合并伪造或覆盖持续时间'
}
Test-Case '系统日志拒绝读取时统计状态为未知' {
    Assert-Api 'Get-UnifiedLinkEvents'
    Write-FixtureJson 'runtime\link-events.json' @()
    Write-FixtureJson 'runtime\link-events-ignore.json' @()
    function Get-WinEvent { throw 'fixture event access denied' }
    $r = Get-UnifiedLinkEvents -Days 7
    Assert-True (-not $r.Known -and $r.Error -match 'fixture event access denied') '日志读取失败变成未记录或稳定'
}
Test-Case 'WLAN日志没有匹配事件属于已知空集' {
    Assert-Api 'Get-SystemDisconnectTimes'
    function Get-WinEvent {
        [CmdletBinding()]param($FilterHashtable)
        Write-Error 'No events were found' -ErrorId 'NoMatchingEventsFound'
    }
    $r=Get-SystemDisconnectTimes -Result
    Assert-True ($r.Known -and $r.Times.Count -eq 0 -and -not $r.Error) '正常无事件变成读取失败'
}
Test-Case '维护窗口读取失败时统计状态为未知' {
    Assert-Api 'Get-UnifiedLinkEvents'
    Write-FixtureJson 'runtime\link-events.json' @()
    [IO.File]::WriteAllText((Join-Path $script:DataRoot 'runtime\link-events-ignore.json'), '{broken')
    function Get-WinEvent { return @() }
    $r = Get-UnifiedLinkEvents -Days 7
    Assert-True (-not $r.Known -and $r.Error -match '维护') '维护窗口损坏被当作没有维护记录'
}
Test-Case '已知零记录只显示未记录' {
    Assert-Api 'Get-UnifiedLinkEvents'
    Write-FixtureJson 'runtime\link-events.json' @()
    Write-FixtureJson 'runtime\link-events-ignore.json' @()
    function Get-WinEvent { return @() }
    $r = Get-UnifiedLinkEvents -Days 7
    Assert-True ($r.Known -and $r.Sessions.Count -eq 0 -and $r.Detail -match '未记录' -and $r.Detail -notmatch '稳定') '零记录被描述为持续稳定'
}
foreach ($seconds in @(9,10,11)) {
    Test-Case ('采样估计' + $seconds + '秒分类并标记真实时长未知') {
        Assert-Api 'Update-LinkObservationTracker'
        $at = Get-Date
        $tracker = New-LinkObservationTracker
        $tracker = (Update-LinkObservationTracker $tracker (New-FixtureSnapshot $at $true)).Tracker
        $tracker = (Update-LinkObservationTracker $tracker (New-FixtureSnapshot $at.AddSeconds(1) $false)).Tracker
        $result = Update-LinkObservationTracker $tracker (New-FixtureSnapshot $at.AddSeconds(1+$seconds) $true)
        $expected = if ($seconds -ge 10) { '断链' } else { '抖动' }
        Assert-True ($result.Event.Kind -eq $expected -and $result.Event.Seconds -eq $seconds -and $result.Event.Estimate -and -not $result.Event.DurationKnown -and $result.Event.LowerBoundSeconds -eq 0) '10秒分界或采样精度标志错误'
    }
}
Test-Case 'Ping超时和两次在线采样之间的故障不补造断链' {
    Assert-Api 'Update-LinkObservationTracker'
    $at = Get-Date
    $tracker = New-LinkObservationTracker
    $tracker = (Update-LinkObservationTracker $tracker (New-FixtureSnapshot $at $true)).Tracker
    $snapshot = New-FixtureSnapshot $at.AddSeconds(30) $true
    $snapshot | Add-Member GatewayPing ([pscustomobject]@{ Known=$true; Success=$false })
    $result = Update-LinkObservationTracker $tracker $snapshot
    Assert-True ($null -eq $result.Event) 'Ping失败被记录为物理断链'
}
Test-Case '维护或休眠造成的观测空隙不记录自然断链' {
    Assert-Api 'Update-LinkObservationTracker'
    $at = Get-Date
    $tracker = New-LinkObservationTracker
    $tracker = (Update-LinkObservationTracker $tracker (New-FixtureSnapshot $at $true)).Tracker
    $tracker = (Update-LinkObservationTracker $tracker (New-FixtureSnapshot $at.AddSeconds(30) $false)).Tracker
    $result = Update-LinkObservationTracker $tracker (New-FixtureSnapshot $at.AddSeconds(150) $true)
    Assert-True ($null -eq $result.Event -and $result.Detail -match '空隙|覆盖') '休眠后伪造连续断链'
    $tracker = (Update-LinkObservationTracker $result.Tracker (New-FixtureSnapshot $at.AddSeconds(180) $false) -Ignored).Tracker
    $result = Update-LinkObservationTracker $tracker (New-FixtureSnapshot $at.AddSeconds(210) $true)
    Assert-True ($null -eq $result.Event) '工具维护被计入自然断链'
}
Test-Case '代理轻读的重复连接证据不抬高断链观察精度' {
    Assert-Api 'Update-LinkObservationTracker'
    $at = Get-Date
    $tracker = New-LinkObservationTracker
    $tracker = (Update-LinkObservationTracker $tracker (New-FixtureSnapshot $at $true)).Tracker
    $s = New-FixtureSnapshot $at.AddSeconds(30) $false
    $tracker = (Update-LinkObservationTracker $tracker $s).Tracker
    $s.CheckedAt=$at.AddSeconds(35)
    $result = Update-LinkObservationTracker $tracker $s
    Assert-True ($result.Tracker.LastObservedAt -eq $at.AddSeconds(30) -and $null -eq $result.Event) '代理轮被当作新网卡观测'
}

Write-Host ('后台与断链回归：{0} 项，{1} 个失败' -f $script:total,$script:fail)
if ($script:fail) { exit 1 }
exit 0
