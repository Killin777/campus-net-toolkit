#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
if ([Console]::IsOutputRedirected) {
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
}
$root = Split-Path -Parent $PSScriptRoot
$script:fail = 0
$script:total = 0
function Assert-True($condition, $message) { if (-not $condition) { throw $message } }
function Test-Case($name, [scriptblock]$test) {
    $script:total++
    try { & $test; Write-Host "  PASS $name" }
    catch { $script:fail++; Write-Host "  FAIL $name : $($_.Exception.Message)" -ForegroundColor Red }
}
function Import-Function($path, $name) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
    $fn = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $fn) { throw "Missing function: $name" }
    return [scriptblock]::Create($fn.Extent.Text)
}
$main = Join-Path $root 'src\网络优化器.ps1'
Test-Case '未知状态登录先复检，不开页或切网' {
    . (Import-Function $main 'Open-CampusLogin')
    $script:networkSnapshot = [pscustomobject]@{ Conclusion=[pscustomobject]@{ State='Unknown' } }
    $script:refreshCalls = 0; $script:browserCalls = 0
    function Request-StatusRefresh { $script:refreshCalls++ }
    function Start-Process { $script:browserCalls++ }
    function Write-Log { }
    Open-CampusLogin
    Assert-True ($script:refreshCalls -eq 1 -and $script:browserCalls -eq 0) '未知状态仍打开了浏览器'
}
Test-Case '缺少认证网址直接引导设置' {
    . (Import-Function $main 'Open-CampusLogin')
    $script:networkSnapshot = [pscustomobject]@{ Conclusion=[pscustomobject]@{ State='NeedsAuth' } }
    $script:settingsCalls = 0
    function Get-CampusConfig { $null }
    function Show-SettingsWindow { $script:settingsCalls++ }
    function Write-Log { }
    Open-CampusLogin
    Assert-True ($script:settingsCalls -eq 1) '没有引导到设置界面'
}
Test-Case '有线已联网不依赖无线字段' {
    . (Join-Path $root 'src\lib\WiredCheck.ps1')
    function Get-NetAdapterStatistics { [pscustomobject]@{ ReceivedPacketErrors=2; OutboundPacketErrors=0; ReceivedDiscardedPackets=5; OutboundDiscardedPackets=0 } }
    $snapshot = [pscustomobject]@{
        CheckedAt=[datetime]'2026-10-27T12:00:00'
        Info=[pscustomobject]@{ ConnectionType='Ethernet'; Adapter='test-ethernet'; InterfaceIndex=4; LinkSpeedMbps=100; Link='100 Mbps'; IP='192.0.2.2'; Gateway='192.0.2.1'; DNS='192.0.2.53' }
        Connection=[pscustomobject]@{ Known=$true; Connected=$true; HasDefaultRoute=$true }
        Conclusion=[pscustomobject]@{ State='Online'; Title='外网已验证可用' }
        Quality=[pscustomobject]@{ Known=$true; Kind='Online'; Detail='HTTP 200' }
    }
    $report=Get-WiredConnectionReport -Snapshot $snapshot
    Assert-True ($report.Applicable -and $report.Known) '无 SSID 有线未被识别'
    Assert-True (($report.Lines -join ' ') -match '100') '缺少当前协商速率'
    Assert-True (($report.Lines -join ' ') -match '累计') '错误计数未说明累计范围'
    Assert-True (($report.Lines -join ' ') -notmatch '坏网线|丢包率') '累计计数或100Mbps被误判'
}
Test-Case '无线连接的有线检查不误读其他网卡计数' {
    . (Join-Path $root 'src\lib\WiredCheck.ps1')
    $script:statReads=0
    function Get-NetAdapterStatistics { $script:statReads++; throw '不应读取' }
    $report=Get-WiredConnectionReport -Snapshot ([pscustomobject]@{ Info=[pscustomobject]@{ ConnectionType='WiFi' } })
    Assert-True (-not $report.Applicable -and $script:statReads -eq 0) '无线检查误读有线网卡'
}
Test-Case '有线统计读取失败显示未知且保留连接证据' {
    . (Join-Path $root 'src\lib\WiredCheck.ps1')
    function Get-NetAdapterStatistics { throw '模拟驱动不支持统计' }
    $snapshot=[pscustomobject]@{ Info=[pscustomobject]@{ ConnectionType='Ethernet'; Adapter='test-ethernet'; Link='1 Gbps'; IP='192.0.2.2'; Gateway='192.0.2.1'; DNS='192.0.2.53' }; Connection=[pscustomobject]@{ Known=$true; Connected=$true; HasDefaultRoute=$true }; Quality=[pscustomobject]@{ Known=$false; Detail='HTTP 未验证' }; Conclusion=[pscustomobject]@{ State='Unknown'; Title='认证状态未知' } }
    $report=Get-WiredConnectionReport -Snapshot $snapshot
    Assert-True (-not $report.StatisticsKnown -and ($report.Lines -join ' ') -match '模拟驱动不支持统计') '统计失败被当作0错误'
    Assert-True (($report.Lines -join ' ') -match '192.0.2.1') '统计失败丢弃已知网关'
}
Test-Case '耗时任务后台运行且拒绝第二个并发任务' {
    . (Import-Function $main 'Start-UiTask')
    . (Import-Function $main 'Receive-UiTask')
    $script:ProjRoot=$root
    $script:DataRoot=Join-Path $root '_qa\workflow-tests'
    $script:uiWork=$null
    $script:taskCompleted=$false
    function Set-Busy { }
    function Write-Log { }
    function Request-StatusRefresh { }
    $watch=[Diagnostics.Stopwatch]::StartNew()
    Start-UiTask -Title '后台替代任务' -Code { Start-Sleep -Milliseconds 400; 'done' } -Completed { param($result) $script:taskCompleted=($result -eq 'done') }
    Assert-True ($watch.ElapsedMilliseconds -lt 350) '启动任务阻塞界面线程'
    $first=$script:uiWork
    Start-UiTask -Title '重复任务' -Code { throw '不能运行第二个任务' } -Completed { }
    Assert-True ([object]::ReferenceEquals($first,$script:uiWork)) '创建了并发写操作任务'
    while ($script:uiWork -and $watch.Elapsed.TotalSeconds -lt 8) { Start-Sleep -Milliseconds 30; Receive-UiTask }
    Assert-True ($script:taskCompleted -and -not $script:uiWork) '后台任务没有回收并交付结果'
}
Write-Host ("流程回归：{0} 项，{1} 个失败" -f $script:total, $script:fail)
if ($script:fail) { exit 1 }
exit 0
