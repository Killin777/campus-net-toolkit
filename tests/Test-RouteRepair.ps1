#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script:ProjRoot = $root
$script:DataRoot = Join-Path $root ('_qa\route-repair-' + $PID)
. (Join-Path $root 'src\lib\Common.ps1')
. (Join-Path $root 'src\lib\RouteGuard.ps1') -NoRun
$repairPath = Join-Path $root 'src\lib\RouteRepair.ps1'
if (Test-Path -LiteralPath $repairPath) { . $repairPath }
$script:total = 0
$script:fail = 0

function Assert-True($condition, [string]$message) {
    if (-not $condition) { throw $message }
}
function Test-Case([string]$name, [scriptblock]$test) {
    $script:total++
    try { Reset-RepairFixture; & $test; Write-Host ('  PASS ' + $name) }
    catch { $script:fail++; Write-Host ('  FAIL ' + $name + ' : ' + $_.Exception.Message) -ForegroundColor Red }
}
function Reset-RepairFixture {
    $script:DataRoot = Join-Path $root ('_qa\route-repair-' + $PID + '\case-' + $script:total)
    $script:metric = 1
    $script:automatic = 'Enabled'
    $script:proxyValue = 1
    $script:proxyExists = $true
    $script:server = '127.0.0.1:7897'
    $script:pac = 'https://pac.example/proxy.pac'
    $script:metricWrites = 0
    $script:proxyWrites = 0
    $script:wifiWrites = 0
    $script:maintenance = 0
    $script:listenerAlive = $false
    $script:listenerReadFailure = $false
    $script:metricWriteMode = 'normal'
    $script:proxyWriteMode = 'normal'
    $script:wifiValue = @('0')
    $script:haveVirtualRoute = $true
    $script:havePhysicalRoute = $true
    $script:isAdmin = $true
    $script:physicalAlias = 'Fixture Wi-Fi'
}

# 读取仅使用合成对象；未显式允许的真实系统写入立即失败。
function Get-NetAdapter {
    param($Name)
    $adapters = @([pscustomobject]@{ Name = 'Fixture VPN'; ifIndex = 11; Status = 'Up'; HardwareInterface = $false; InterfaceGuid = '00000000-0000-0000-0000-000000000011' },
        [pscustomobject]@{ Name = $script:physicalAlias; ifIndex = 22; Status = 'Up'; HardwareInterface = $true; InterfaceGuid = '00000000-0000-0000-0000-000000000022' })
    if ($Name) { return @($adapters | Where-Object Name -eq $Name) }
    return $adapters
}
function Get-NetRoute {
    param($DestinationPrefix)
    $rows = @()
    if ($script:haveVirtualRoute) { $rows += [pscustomobject]@{ InterfaceAlias = 'Fixture VPN'; ifIndex = 11; NextHop = '192.0.2.1'; RouteMetric = 1; InterfaceMetric = $script:metric } }
    if ($script:havePhysicalRoute) { $rows += [pscustomobject]@{ InterfaceAlias = $script:physicalAlias; ifIndex = 22; NextHop = '192.0.2.2'; RouteMetric = 1; InterfaceMetric = 25 } }
    return $rows
}
function Get-NetIPInterface {
    param($InterfaceIndex, $InterfaceAlias, $AddressFamily)
    if ($InterfaceIndex -eq 11 -or $InterfaceAlias -eq 'Fixture VPN') {
        return [pscustomobject]@{ InterfaceIndex = 11; InterfaceAlias = 'Fixture VPN'; InterfaceMetric = $script:metric; AutomaticMetric = $script:automatic; AddressFamily = 'IPv4' }
    }
    if ($InterfaceIndex -eq 22 -or $InterfaceAlias -eq $script:physicalAlias) {
        return [pscustomobject]@{ InterfaceIndex = 22; InterfaceAlias = $script:physicalAlias; InterfaceMetric = 25; AutomaticMetric = 'Enabled'; AddressFamily = 'IPv4' }
    }
    throw '测试拒绝读取非合成接口'
}
function Get-ItemProperty {
    param($Path, $LiteralPath)
    if ($LiteralPath) { $Path = $LiteralPath }
    if ($Path -ne 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings') { throw '测试禁止读取真实注册表' }
    $state = [pscustomobject]@{ ProxyServer = $script:server; ProxyOverride = '<local>'; AutoConfigURL = $script:pac }
    if ($script:proxyExists) { $state | Add-Member NoteProperty ProxyEnable $script:proxyValue }
    return $state
}
function Get-NetTCPConnection {
    param($State)
    if ($script:listenerReadFailure) { throw '合成监听读取失败' }
    if ($script:listenerAlive) { return [pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 7897 } }
    return @()
}
function Test-RouteRepairAdmin { return $script:isAdmin }
function Add-IgnoreWindow { param($reason, $seconds) $script:maintenance++ }
function Send-ProxySettingsChanged { }
function Set-NetIPInterface {
    param($InterfaceIndex, $InterfaceAlias, $AddressFamily, $InterfaceMetric, $AutomaticMetric)
    if ($InterfaceIndex -ne 11 -and $InterfaceAlias -ne 'Fixture VPN') { throw '测试禁止修改真实接口' }
    $script:metricWrites++
    if ($script:metricWriteMode -eq 'fail') { throw '合成接口拒绝写入' }
    if ($script:metricWriteMode -ne 'nochange' -and $PSBoundParameters.ContainsKey('InterfaceMetric')) { $script:metric = [int]$InterfaceMetric }
    if ($script:metricWriteMode -ne 'nochange' -and $PSBoundParameters.ContainsKey('AutomaticMetric')) { $script:automatic = [string]$AutomaticMetric }
    if ($script:metricWriteMode -eq 'partial') { throw '合成接口部分写入后失败' }
}
function Set-ItemProperty {
    param($Path, $LiteralPath, $Name, $Value)
    if ($LiteralPath) { $Path = $LiteralPath }
    if ($Path -ne 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -or $Name -ne 'ProxyEnable') { throw '测试禁止修改真实注册表或无关字段' }
    $script:proxyWrites++
    if ($script:proxyWriteMode -eq 'fail') { throw '合成注册表拒绝写入' }
    if ($script:proxyWriteMode -ne 'nochange') { $script:proxyValue = $Value; $script:proxyExists = $true }
}
function Remove-ItemProperty {
    param($Path, $LiteralPath, $Name)
    if ($LiteralPath) { $Path = $LiteralPath }
    if ($Path -ne 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -or $Name -ne 'ProxyEnable') { throw '测试禁止删除真实注册表或无关字段' }
    $script:proxyWrites++
    $script:proxyExists = $false
}
function Set-DnsClientServerAddress { throw '测试禁止修改 DNS' }
function Get-NetAdapterAdvancedProperty {
    param($Name, $RegistryKeyword)
    if ($Name -ne 'Fixture Wi-Fi' -or $RegistryKeyword -ne 'RoamingPreferredBandType') { throw '测试禁止读取真实无线属性' }
    return [pscustomobject]@{ Name = $Name; RegistryKeyword = $RegistryKeyword; RegistryValue = @($script:wifiValue) }
}
function Set-NetAdapterAdvancedProperty {
    param($Name, $RegistryKeyword, $RegistryValue, [switch]$NoRestart)
    if ($Name -ne 'Fixture Wi-Fi' -or $RegistryKeyword -ne 'RoamingPreferredBandType') { throw '测试禁止修改真实无线属性' }
    $script:wifiWrites++
    $script:wifiValue = @($RegistryValue)
}
function Get-FixtureItems { return @(Get-RouteRepairItems -Report (Get-RouteGuardReport)) }

Test-Case '新模块仅定义函数且不含顶层参数和执行' {
    Assert-True (Test-Path -LiteralPath $repairPath) '逐项修复模块尚未提供'
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($repairPath, [ref]$null, [ref]$errors)
    Assert-True ($errors.Count -eq 0 -and $null -eq $ast.ParamBlock) '逐项模块语法或顶层参数不符合点源约定'
    $other = @($ast.EndBlock.Statements | Where-Object { $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst] })
    Assert-True ($other.Count -eq 0) '逐项模块加载时有顶层执行'
}
Test-Case '无默认路由和未知端点都不提供动作' {
    $script:haveVirtualRoute = $false
    $script:havePhysicalRoute = $false
    $script:server = 'proxy.example:8080'
    Assert-True ((Get-FixtureItems).Count -eq 0) '没有证据仍生成可执行动作'
}
Test-Case '有竞争证据时生成可说明目标且默认不选' {
    $items = Get-FixtureItems
    Assert-True ($items.Count -eq 2) '两项明确证据没有生成两项动作'
    Assert-True (@($items | Where-Object Selected).Count -eq 0) '写操作被默认勾选'
    $metricItem = $items | Where-Object Type -eq 'InterfaceMetric'
    Assert-True ($metricItem.Desired.InterfaceMetric -gt 25 -and $metricItem.Desired.InterfaceMetric -ne 9000) '目标未按候选成本计算'
    Assert-True ($metricItem.Before.AutomaticMetric -eq 'Enabled' -and $metricItem.RequiresAdmin) '遗漏自动跃点原值或权限提示'
    Assert-True ($metricItem.Impact -match 'VPN|隧道' -and $metricItem.Evidence -match '26') '缺少实际成本和VPN影响'
}
Test-Case '有线物理默认出口与虚拟候选使用相同证据和可撤销修复' {
    $script:physicalAlias = 'Fixture Ethernet'
    $item = Get-FixtureItems | Where-Object Type -eq 'InterfaceMetric'
    Assert-True ($item.Evidence -match 'Fixture Ethernet' -and $item.Desired.InterfaceMetric -eq 26) '有线出口没有作为真实物理候选比较'
    $result = Invoke-RouteRepairItem -Item $item
    Assert-True ($result.Ok -and $script:metric -eq 26) '有线候选下的跃点调整失败'
    Assert-True ((Undo-RouteRepairItem -RecordPath $result.RecordPath).Ok -and $script:metric -eq 1 -and $script:automatic -eq 'Enabled') '有线候选下未恢复自动跃点原值'
}
Test-Case '名字像VPN而无硬件类型证据时不提供跃点动作' {
    function Get-NetAdapter { return @([pscustomobject]@{ Name = 'Fixture VPN'; ifIndex = 11; Status = 'Up' }, [pscustomobject]@{ Name = 'Fixture Wi-Fi'; ifIndex = 22; Status = 'Up'; HardwareInterface = $true }) }
    Assert-True (@(Get-FixtureItems | Where-Object Type -eq 'InterfaceMetric').Count -eq 0) '名称线索被当作可写类型证据'
}
Test-Case '只有虚拟默认路由时没有跃点动作' {
    $script:havePhysicalRoute = $false
    Assert-True (@(Get-FixtureItems | Where-Object Type -eq 'InterfaceMetric').Count -eq 0) '单一路由被当成竞争'
}
Test-Case '无法读取监听表时不提供关闭代理动作' {
    $script:listenerReadFailure = $true
    Assert-True (@(Get-FixtureItems | Where-Object Type -eq 'ManualProxyDisable').Count -eq 0) '未知状态生成关闭代理动作'
}
Test-Case '备份失败时任何系统写入均为零' {
    $item = Get-FixtureItems | Where-Object Type -eq 'InterfaceMetric'
    function Save-ToolkitJson { throw '合成备份失败' }
    $result = Invoke-RouteRepairItem -Item $item
    Assert-True (-not $result.Ok -and $script:metricWrites -eq 0 -and $script:proxyWrites -eq 0) '备份失败后仍修改系统'
    Assert-True ($result.Error -match '备份失败') '没有返回备份失败原因'
}
Test-Case '入口拒绝白名单外类型且零写入' {
    $item = Get-FixtureItems | Where-Object Type -eq 'InterfaceMetric'
    $item.Type = 'StaticRoute'
    $result = Invoke-RouteRepairItem -Item $item
    Assert-True (-not $result.Ok -and $script:metricWrites -eq 0 -and $script:proxyWrites -eq 0) '非白名单类型被执行'
}
Test-Case '管理员权限不足拒绝跃点写入' {
    $item = Get-FixtureItems | Where-Object Type -eq 'InterfaceMetric'
    $script:isAdmin = $false
    $result = Invoke-RouteRepairItem -Item $item
    Assert-True (-not $result.Ok -and $script:metricWrites -eq 0 -and $result.Error -match '管理员') '缺少权限仍开始写入'
}
Test-Case '执行前原值改变则拒绝陈旧修复' {
    $item = Get-FixtureItems | Where-Object Type -eq 'InterfaceMetric'
    $script:metric = 15
    $result = Invoke-RouteRepairItem -Item $item
    Assert-True (-not $result.Ok -and $script:metricWrites -eq 0 -and $result.Error -match '改变|变化|刷新') '陈旧跃点值被覆盖'
}
Test-Case '复核证据期间原值再改变仍拒绝陈旧修复' {
    $item = Get-FixtureItems | Where-Object Type -eq 'InterfaceMetric'
    $script:metricReads = 0
    function Get-NetIPInterface {
        param($InterfaceIndex, $AddressFamily)
        $script:metricReads++
        if ($script:metricReads -gt 1) { $script:metric = 15 }
        return [pscustomobject]@{ InterfaceIndex = 11; InterfaceAlias = 'Fixture VPN'; InterfaceMetric = $script:metric; AutomaticMetric = $script:automatic }
    }
    $result = Invoke-RouteRepairItem -Item $item
    Assert-True (-not $result.Ok -and $script:metricWrites -eq 0) '证据复核期间变化的原值仍被覆盖'
}
Test-Case '代理目标变化时不按旧端口证据关闭' {
    $item = Get-FixtureItems | Where-Object Type -eq 'ManualProxyDisable'
    $script:server = 'proxy.example:8080'
    $result = Invoke-RouteRepairItem -Item $item
    Assert-True (-not $result.Ok -and $script:proxyWrites -eq 0) '代理端点改变后仍关闭'
}
Test-Case '代理端口在应用前恢复监听则不关闭' {
    $item = Get-FixtureItems | Where-Object Type -eq 'ManualProxyDisable'
    $script:listenerAlive = $true
    $result = Invoke-RouteRepairItem -Item $item
    Assert-True (-not $result.Ok -and $script:proxyWrites -eq 0) '端口已恢复仍按旧证据关闭'
}
Test-Case '两项一成一败各有独立记录且不报全成功' {
    $items = Get-FixtureItems
    $a = Invoke-RouteRepairItem -Item ($items | Where-Object Type -eq 'InterfaceMetric')
    $script:proxyWriteMode = 'fail'
    $b = Invoke-RouteRepairItem -Item ($items | Where-Object Type -eq 'ManualProxyDisable')
    Assert-True ($a.Ok -and $a.Verified -and -not $b.Ok -and -not $b.Verified) '部分失败被当作全成功'
    Assert-True ($a.RecordPath -ne $b.RecordPath -and (Test-Path $a.RecordPath) -and (Test-Path $b.RecordPath)) '两项没有独立可重试记录'
    $saved = Get-Content -LiteralPath $b.RecordPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True (-not $saved.Verified -and $saved.Error -match '拒绝写入') '失败原因没有落盘'
}
Test-Case 'setter不抛错也必须读回复检' {
    $item = Get-FixtureItems | Where-Object Type -eq 'InterfaceMetric'
    $script:metricWriteMode = 'nochange'
    $result = Invoke-RouteRepairItem -Item $item
    Assert-True (-not $result.Ok -and -not $result.Verified -and (Test-Path $result.RecordPath)) '未写成功被当作成功'
}
Test-Case '部分写入后抛错仍记录实际After并可撤销' {
    $item = Get-FixtureItems | Where-Object Type -eq 'InterfaceMetric'
    $script:metricWriteMode = 'partial'
    $result = Invoke-RouteRepairItem -Item $item
    Assert-True (-not $result.Ok -and $result.Applied -and (Test-Path $result.RecordPath)) '部分写入的记录丢失'
    Assert-True ($result.After.InterfaceMetric -eq $script:metric) 'After没有记录实际值'
    $script:metricWriteMode = 'normal'
    $undo = Undo-RouteRepairItem -RecordPath $result.RecordPath
    Assert-True ($undo.Ok -and $script:metric -eq 1 -and $script:automatic -eq 'Enabled') '部分写入不能恢复'
}
Test-Case '撤销A只恢复本项并保留B' {
    $items = Get-FixtureItems
    $a = Invoke-RouteRepairItem -Item ($items | Where-Object Type -eq 'InterfaceMetric')
    $b = Invoke-RouteRepairItem -Item ($items | Where-Object Type -eq 'ManualProxyDisable')
    $proxyWriteCount = $script:proxyWrites
    $undo = Undo-RouteRepairItem -RecordPath $a.RecordPath
    Assert-True ($undo.Ok -and $script:metric -eq 1 -and $script:automatic -eq 'Enabled') '跃点原值或自动状态没有恢复'
    Assert-True ($script:proxyValue -eq 0 -and $script:proxyWrites -eq $proxyWriteCount) '撤销跃点误动代理'
    Assert-True ((Get-Content -LiteralPath $a.RecordPath -Raw -Encoding UTF8 | ConvertFrom-Json).Restored) '成功撤销未标记记录'
    Assert-True (-not (Get-Content -LiteralPath $b.RecordPath -Raw -Encoding UTF8 | ConvertFrom-Json).Restored) '另一项误标记撤销'
}
Test-Case '撤销时外部更改值不被覆盖且保留记录' {
    $result = Invoke-RouteRepairItem -Item (Get-FixtureItems | Where-Object Type -eq 'InterfaceMetric')
    $script:metric = 80
    $count = $script:metricWrites
    $undo = Undo-RouteRepairItem -RecordPath $result.RecordPath
    Assert-True (-not $undo.Ok -and $script:metric -eq 80 -and $script:metricWrites -eq $count) '撤销覆盖了外部设置'
    Assert-True ($undo.Error -match '冲突|改变|变化' -and (Test-Path $result.RecordPath)) '冲突没有说明或记录丢失'
}
Test-Case '撤销写失败保留原After供重试' {
    $result = Invoke-RouteRepairItem -Item (Get-FixtureItems | Where-Object Type -eq 'InterfaceMetric')
    $script:metricWriteMode = 'fail'
    $undo = Undo-RouteRepairItem -RecordPath $result.RecordPath
    Assert-True (-not $undo.Ok -and (Test-Path $result.RecordPath)) '撤销失败的记录丢失'
    $script:metricWriteMode = 'normal'
    Assert-True ((Undo-RouteRepairItem -RecordPath $result.RecordPath).Ok) '撤销失败后不能重试'
}
Test-Case '撤销写入后抛错保留实际值并可安全重试' {
    $result = Invoke-RouteRepairItem -Item (Get-FixtureItems | Where-Object Type -eq 'InterfaceMetric')
    $script:metricWriteMode = 'partial'
    $undo = Undo-RouteRepairItem -RecordPath $result.RecordPath
    Assert-True (-not $undo.Ok -and $undo.Verified -and $script:metric -eq 1) '撤销写入后错误未如实报告'
    $script:metricWriteMode = 'normal'
    Assert-True ((Undo-RouteRepairItem -RecordPath $result.RecordPath).Ok) '撤销曾写入实际值后不能安全重试'
}
Test-Case '关闭代理和撤销均不改Server与PAC并兼容首次全量快照' {
    $path = Join-Path $script:DataRoot 'runtime\proxy-backup.json'
    Save-ToolkitJson @{ Enabled = $true; Server = 'original.example:8888' } $path
    $original = [IO.File]::ReadAllText($path)
    $item = Get-FixtureItems | Where-Object Type -eq 'ManualProxyDisable'
    $result = Invoke-RouteRepairItem -Item $item
    Assert-True ($result.Ok -and $script:server -eq '127.0.0.1:7897' -and $script:pac -eq 'https://pac.example/proxy.pac') '关闭代理误动其他字段'
    Assert-True ((Undo-RouteRepairItem -RecordPath $result.RecordPath).Ok -and $script:proxyValue -eq 1 -and $script:proxyExists) '未恢复ProxyEnable原值与存在性'
    Assert-True ([IO.File]::ReadAllText($path) -eq $original) '首次全量代理快照被逐项记录覆盖'
}
Test-Case '代理撤销能恢复原本不存在的开关属性' {
    $script:proxyValue = 0
    $path = Join-Path $script:DataRoot 'runtime\repair-existence-fixture.json'
    Save-ToolkitJson ([pscustomobject]@{
        SchemaVersion = 1; Id = 'manual-proxy-disable'; Type = 'ManualProxyDisable'; SavedAt = (Get-Date).ToString('s')
        Target = [pscustomobject]@{ RegistryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'; Name = 'ProxyEnable'; ProxyServer = $script:server }
        Before = [pscustomobject]@{ Exists = $false; Value = $null }; After = [pscustomobject]@{ Exists = $true; Value = 0 }
        Applied = $true; Verified = $true; Restored = $false; Error = ''
    }) $path
    Assert-True ((Undo-RouteRepairItem -RecordPath $path).Ok -and -not $script:proxyExists) '撤销没有恢复属性原不存在的状态'
    Assert-True ($script:server -eq '127.0.0.1:7897' -and $script:pac -eq 'https://pac.example/proxy.pac') '恢复存在性误改代理其他字段'
}
Test-Case '历史可取得每项记录路径与撤销状态' {
    $result = Invoke-RouteRepairItem -Item (Get-FixtureItems | Where-Object Type -eq 'InterfaceMetric')
    $history = @(Get-RouteRepairHistory)
    Assert-True ($history.Count -eq 1 -and $history[0].RecordPath -eq $result.RecordPath -and $history[0].Verified) '历史不能供GUI逐项撤销'
}
Test-Case '5GHz备份保存真实驱动RegistryValue且只恢复该无线属性' {
    $script:wifiValue = @('2')
    $path = New-WifiBandBackup -InterfaceAlias 'Fixture Wi-Fi' -RegistryKeyword 'RoamingPreferredBandType'
    Assert-True ([IO.Path]::GetFileName($path) -like 'network-backup-*.json') '新备份不被现有选择器识别'
    $saved = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True (@($saved.WifiBand.RegistryValue)[0] -eq '2') '没有保存真实无线原值'
    $script:wifiValue = @('3')
    Restore-NetBackup -Path $path
    Assert-True ($script:wifiValue[0] -eq '2' -and $script:wifiWrites -eq 1 -and $script:metricWrites -eq 0 -and $script:proxyWrites -eq 0) '无线恢复捆绑了其他配置'
}
Test-Case '无线目标已等于原值时恢复不重复写' {
    $path = New-WifiBandBackup -InterfaceAlias 'Fixture Wi-Fi' -RegistryKeyword 'RoamingPreferredBandType'
    Restore-NetBackup -Path $path
    Assert-True ($script:wifiWrites -eq 0) '无线原值未变仍重复写入'
}
Test-Case '无线恢复setter无效时读回失败并保留记录' {
    $path = New-WifiBandBackup -InterfaceAlias 'Fixture Wi-Fi' -RegistryKeyword 'RoamingPreferredBandType'
    $script:wifiValue = @('3')
    function Set-NetAdapterAdvancedProperty { }
    $failed = $false
    try { Restore-NetBackup -Path $path } catch { $failed = $true }
    Assert-True ($failed -and (Test-Path $path)) '无线恢复未生效仍报告成功或丢失备份'
}

Test-Case '无线备份失败时调用方没有可用路径且系统零写入' {
    function Save-ToolkitJson { throw '合成无线备份失败' }
    $failed = $false
    $path = $null
    try { $path = New-WifiBandBackup -InterfaceAlias 'Fixture Wi-Fi' -RegistryKeyword 'RoamingPreferredBandType' } catch { $failed = $true }
    Assert-True ($failed -and -not $path -and $script:wifiWrites -eq 0) '无线备份失败仍返回可写路径或改了系统'
}

Write-Host ('逐项修复回归：{0} 项，{1} 个失败' -f $script:total, $script:fail)
if ($script:fail) { exit 1 }
exit 0
