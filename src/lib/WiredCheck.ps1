#Requires -Version 5.1
# 有线连接只读报告；连接与认证证据由同一轮后台快照提供。
$ErrorActionPreference = 'Stop'
if ([Console]::IsOutputRedirected) {
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
}

function Get-WiredConnectionReport {
    param([Parameter(Mandatory=$true)]$Snapshot)
    $info = $Snapshot.Info
    if ($info.ConnectionType -ne 'Ethernet') {
        return [pscustomobject]@{ Applicable=$false; Known=$true; StatisticsKnown=$false; Lines=@('当前 IPv4 出口未识别为有线以太网。请在连接网线后重新检测。'); Recommendations=@(); Statistics=$null }
    }
    $lines = New-Object Collections.Generic.List[string]
    $recommendations = New-Object Collections.Generic.List[string]
    $lines.Add('有线网卡：' + [string]$info.Adapter)
    $lines.Add('当前协商链路速率：' + [string]$info.Link)
    $lines.Add('IPv4 出口地址：' + [string]$info.IP)
    $lines.Add('默认网关：' + [string]$info.Gateway)
    $lines.Add('DNS：' + [string]$info.DNS)
    $lines.Add('认证与外网：' + [string]$Snapshot.Conclusion.Title + '；' + [string]$Snapshot.Quality.Detail)
    if ($Snapshot.Connection.Known -and -not $Snapshot.Connection.Connected) {
        $recommendations.Add('未观察到物理连接。检查网线两端和端口指示灯，再重新检测。')
    } elseif (-not $Snapshot.Connection.HasDefaultRoute) {
        $recommendations.Add('未发现可用的 IPv4 默认出口。核对自动获取地址、网关和学校提供的接入方式；可查看网络急救。')
    }
    if ($info.LinkSpeedMbps -gt 0 -and $info.LinkSpeedMbps -le 100) {
        $recommendations.Add('当前协商为 ' + [string]$info.Link + '。如预期更高，请核对网卡、交换机端口和网线的能力；此值本身不能确定故障原因。')
    }
    if ($Snapshot.Conclusion.State -eq 'NeedsAuth') { $recommendations.Add('连接已建立，但需要网页认证。使用「打开登录页」，在浏览器中自行完成认证。') }
    if ($Snapshot.Conclusion.State -eq 'ProxyIssue') { $recommendations.Add('检测到手动代理目标异常。进入「逐项修复」查看证据并选择处理。') }
    if ($Snapshot.Conclusion.State -eq 'ExternalFailure') { $recommendations.Add('物理连接与外网质量分别核对。可查看 DNS 设置，按需恢复自动 DNS（执行前备份），或使用网络急救。') }
    $statistics = $null
    $statisticsKnown = $false
    try {
        $statistics = Get-NetAdapterStatistics -Name $info.Adapter -ErrorAction Stop
        $statisticsKnown = $true
        $lines.Add(('网卡累计计数：接收错误 {0}，发送错误 {1}，接收丢弃 {2}，发送丢弃 {3}。' -f $statistics.ReceivedPacketErrors, $statistics.OutboundPacketErrors, $statistics.ReceivedDiscardedPackets, $statistics.OutboundDiscardedPackets))
        $lines.Add('计数从驱动或系统最近重置起累计，不能代表本次检测的网络质量。')
        if ([long]$statistics.ReceivedPacketErrors + [long]$statistics.OutboundPacketErrors -gt 0) { $recommendations.Add('存在历史累计错误。可在同一工作时段复查是否增长，再核对网线与端口；不能仅凭累计值断言当前故障。') }
    } catch {
        $lines.Add('网卡累计计数未知：' + $_.Exception.Message)
    }
    if ($recommendations.Count -eq 0) { $recommendations.Add('当前未发现需要修改的有线参数。遇到间歇问题时保留检测时间与报告，供网络中心核对。') }
    return [pscustomobject]@{
        Applicable=$true; Known=[bool]$Snapshot.Connection.Known; StatisticsKnown=$statisticsKnown
        Lines=@($lines); Recommendations=@($recommendations); Statistics=$statistics
    }
}
