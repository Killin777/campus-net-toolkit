#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script:ProjRoot = $root
$script:DataRoot = Join-Path $root '_qa\product-tests'
New-Item -ItemType Directory -Path $script:DataRoot -Force | Out-Null
. (Join-Path $root 'src\lib\Common.ps1')
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
    $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    if (-not $fn) { throw "Missing function: $name" }
    return [scriptblock]::Create($fn.Extent.Text)
}
. (Import-Function (Join-Path $root 'src\网络优化器.ps1') 'Measure-DnsLatency')
Test-Case 'DNS 快速失败不能被选为最快服务器' {
    function Resolve-DnsName { throw '模拟 DNS 拒绝响应' }
    Assert-True ((Measure-DnsLatency -Server '127.0.0.1') -ge 9999) '失败响应被计入测速结果'
}
Test-Case 'DNS 成功响应才计入结果' {
    function Resolve-DnsName { [pscustomobject]@{ IPAddress = '192.0.2.1'; Type = 'A' } }
    Assert-True ((Measure-DnsLatency -Server '127.0.0.1') -lt 9999) '成功结果没有参与测速'
}
Test-Case '含空格、中文、引号与末尾反斜线的参数能往返子进程' {
    Assert-True ([bool](Get-Command ConvertTo-WindowsArgument -ErrorAction SilentlyContinue)) '缺少可靠的 Windows 参数编码器'
    $values = @('', '普通参数', 'C:\中文 目录\', 'a"b', 'x\" y', 'a&b')
    $probe = Join-Path $script:DataRoot '参数 回显.exe'
    if (-not (Test-Path -LiteralPath $probe)) {
        Add-Type -TypeDefinition 'using System; using System.Text; using System.Web.Script.Serialization; public static class ArgumentProbe { public static void Main(string[] args) { Console.OutputEncoding = new UTF8Encoding(false); Console.Write(new JavaScriptSerializer().Serialize(args)); } }' -ReferencedAssemblies 'System.Web.Extensions.dll' -OutputAssembly $probe -OutputType ConsoleApplication
    }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $probe
    $allArgs = $values
    $psi.Arguments = ($allArgs | ForEach-Object { ConvertTo-WindowsArgument ([string]$_) }) -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $process = [Diagnostics.Process]::Start($psi)
    $json = $process.StandardOutput.ReadToEnd()
    $process.WaitForExit()
    Assert-True ($process.ExitCode -eq 0) '回显进程失败'
    $actual = $json | ConvertFrom-Json
    Assert-True ($actual.Count -eq $values.Count) '参数数量改变'
    for ($i = 0; $i -lt $values.Count; $i++) { Assert-True ($actual[$i] -ceq $values[$i]) "第 $i 个参数被破坏" }
    $process.Dispose()
}
Test-Case '还原失败后保留原模式与服务恢复记录' {
    . (Import-Function (Join-Path $root 'src\ModeCtl.ps1') 'Invoke-Restore')
    $script:testState = [pscustomobject]@{ activeMode='game'; savedServices=[pscustomobject]@{ wuauserv='Automatic|Running' }; savedPowerPlan=''; savedPac=''; savedTime='' }
    function Get-ModeState { return $script:testState }
    function Get-Service { [pscustomobject]@{ Name='wuauserv'; Status='Stopped' } }
    function Set-Service { throw '模拟权限不足' }
    function Save-ModeState($s) { $script:testState = $s }
    function Write-Report { }
    function New-Step($name, $ok, $note) { [pscustomobject]@{ Step=$name; Ok=$ok; Note=$note } }
    Invoke-Restore | Out-Null
    Assert-True ($script:testState.savedServices.PSObject.Properties.Count -gt 0) '失败后的服务记录被清空'
    Assert-True ($script:testState.activeMode -eq 'game') '失败后错误标记为已还原'
}
Test-Case 'DNS 自动获取恢复为自动，而非固定 DHCP 下发的地址' {
    $module = Join-Path $root 'src\lib\NetworkState.ps1'
    Assert-True (Test-Path -LiteralPath $module) '缺少可独立验证的网络状态模块'
    . $module
    $script:resetDns = $false
    function Set-DnsClientServerAddress { param($InterfaceAlias, $ServerAddresses, [switch]$ResetServerAddresses) $script:resetDns = [bool]$ResetServerAddresses }
    Restore-DnsSnapshot ([pscustomobject]@{ Interface='test'; Automatic=$true; Servers=@('192.0.2.53') })
    Assert-True $script:resetDns '自动 DNS 被恢复为固定地址'
}
Test-Case '代理写入失败向调用方抛出，不能报告成功' {
    . (Import-Function (Join-Path $root 'src\ProxyCtl.ps1') 'Set-SystemProxyOn')
    $ErrorActionPreference='Continue'
    function Get-Config { @{host='127.0.0.1'; bypass='<local>'} }
    function Save-ProxySnapshot { }
    function Set-ItemProperty { [CmdletBinding()]param($Name,$Value) Write-Error '模拟注册表拒绝写入' }
    $thrown=$false
    try { Set-SystemProxyOn 7897 } catch { $thrown=$true }
    Assert-True $thrown '代理写入失败仍返回成功'
}
Test-Case '游戏设置还原失败时停止切换' {
    . (Import-Function (Join-Path $root 'src\ModeCtl.ps1') 'Restore-PendingGameState')
    function Get-ModeState { [pscustomobject]@{ savedPowerPlan='original'; savedWifi=@(); savedServices=[pscustomobject]@{} } }
    function Invoke-Restore { [pscustomobject]@{ Ok=$false; Step='模拟还原失败' } }
    $thrown=$false
    try { Restore-PendingGameState } catch { $thrown=$true }
    Assert-True $thrown '待还原的游戏设置被模式切换忽略'
}
Test-Case '损坏模式记录不会被静默重置覆盖' {
    . (Import-Function (Join-Path $root 'src\ModeCtl.ps1') 'Get-ModeState')
    $script:StatePath=Join-Path $script:DataRoot 'corrupt-mode.json'
    [IO.File]::WriteAllText($script:StatePath,'invalid-json')
    $thrown=$false
    try { Get-ModeState | Out-Null } catch { $thrown=$true }
    Assert-True $thrown '损坏模式记录被当作空记录'
    Assert-True ([IO.File]::ReadAllText($script:StatePath) -eq 'invalid-json') '损坏记录被覆盖'
}
Test-Case 'JSON 状态原子更新可覆盖并保留正确内容' {
    $file=Join-Path $script:DataRoot 'atomic-state.json'
    Save-ToolkitJson @{value=1} $file
    Save-ToolkitJson @{value=2} $file
    Assert-True ((Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json).value -eq 2) '原子更新没有写入第二次值'
}
Test-Case '单个接口读不到跃点不会中断整轮备份' {
    $module = Join-Path $root 'src\lib\NetworkState.ps1'
    . $module
    $script:backupAdapters = @(
        [pscustomobject]@{ Name='WLAN'; Status='Up'; InterfaceGuid='{11111111-1111-1111-1111-111111111111}' },
        [pscustomobject]@{ Name='vEthernet (Test)'; Status='Up'; InterfaceGuid='{22222222-2222-2222-2222-222222222222}' }
    )
    function Get-NetAdapter {
        param($Name)
        if ($Name) { return @($script:backupAdapters | Where-Object Name -eq $Name) }
        return $script:backupAdapters
    }
    function Get-ItemProperty {
        param($LiteralPath)
        if ($LiteralPath -like '*DeliveryOptimization*') { return $null }
        return [pscustomobject]@{ NameServer='192.0.2.53' }
    }
    function Get-DnsClientServerAddress {
        param($InterfaceAlias,$AddressFamily)
        if ($InterfaceAlias -eq 'vEthernet (Test)') { throw '没有 DNS 记录' }
        return [pscustomobject]@{ ServerAddresses=@('192.0.2.53') }
    }
    function Get-NetIPInterface {
        param($InterfaceAlias,$AddressFamily)
        if ($InterfaceAlias -eq 'vEthernet (Test)') { throw 'CIM 查询找不到任何匹配的 MSFT_NetIPInterface 对象' }
        return [pscustomobject]@{ InterfaceMetric=25; AutomaticMetric='Enabled' }
    }
    $path = New-NetBackup
    Assert-True (Test-Path -LiteralPath $path) '备份文件没有生成'
    $saved = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($saved.跃点.WLAN -eq 25) '可读接口的跃点没有写入备份'
    Assert-True (@($saved.无法读取跃点) -contains 'vEthernet (Test)') '读不到跃点的接口没有被记录'
    Assert-True (-not $saved.跃点.PSObject.Properties['vEthernet (Test)']) '读不到跃点的接口被写进了跃点表'
}
Test-Case '校园网已联网时登录立即结束且不改代理和 DNS' {
    . (Import-Function (Join-Path $root 'src\网络优化器.ps1') 'Open-CampusLogin')
    $script:lastSnapshot = [pscustomobject]@{ Conclusion=[pscustomobject]@{ State='Online' }; Info=[pscustomobject]@{ ConnectionType='WiFi'; SSID='test-campus'; ProxyOn=$true }; Quality=[pscustomobject]@{ Known=$true; Kind='Online' } }
    $script:loginSideEffects = 0
    function Get-CampusConfig { [pscustomobject]@{ portalUrl='http://portal.test/'; ssid='test-campus' } }
    function Get-CurrentWifiSsid { 'test-campus' }
    function Connect-CampusWifi { $true }
    function Test-NetworkQuality { [pscustomobject]@{ Usable=$true; Kind='在线' } }
    function Test-PortalReachable { $true }
    function Get-NetInfo { [pscustomobject]@{ ConnectionType='WiFi'; SSID='test-campus'; ProxyOn=$true } }
    function Invoke-ModeFile { $script:loginSideEffects++ }
    function Start-Process { $script:loginSideEffects++ }
    function Set-DnsClientServerAddress { $script:loginSideEffects++ }
    function Write-Log { }
    Open-CampusLogin
    Assert-True ($script:loginSideEffects -eq 0) '已联网仍打开浏览器或改变网络设置'
}
Test-Case '无 SSID 的有线认证不会切换 WiFi' {
    . (Import-Function (Join-Path $root 'src\网络优化器.ps1') 'Open-CampusLogin')
    $script:lastSnapshot = [pscustomobject]@{ Conclusion=[pscustomobject]@{ State='NeedsAuth' }; Info=[pscustomobject]@{ ConnectionType='Ethernet'; SSID='—'; ProxyOn=$false }; Quality=[pscustomobject]@{ Known=$true; Kind='NeedsAuth' } }
    $script:loginWifiCalls = 0; $script:loginBrowserCalls = 0
    function Get-CampusConfig { [pscustomobject]@{ portalUrl='http://portal.test/'; ssid='test-campus' } }
    function Get-CurrentWifiSsid { '' }
    function Connect-CampusWifi { $script:loginWifiCalls++; $true }
    function Test-NetworkQuality { [pscustomobject]@{ Usable=$false; Kind='需认证' } }
    function Test-PortalReachable { $true }
    function Get-NetInfo { [pscustomobject]@{ ConnectionType='Ethernet'; SSID='—'; ProxyOn=$false } }
    function Start-Process { $script:loginBrowserCalls++ }
    function Write-Log { }
    Open-CampusLogin
    Assert-True ($script:loginWifiCalls -eq 0) '有线认证切换了 WiFi'
    Assert-True ($script:loginBrowserCalls -eq 1) '有线认证未打开已配置门户'
}
Test-Case '无线频段备份失败时不写入驱动' {
    . (Import-Function (Join-Path $root 'src\网络优化器.ps1') 'Set-BandPreference')
    $script:bandWrites = 0
    function Get-WirelessAdapter { [pscustomobject]@{ Name='test-wifi' } }
    function Get-NetAdapterAdvancedProperty { [pscustomobject]@{ RegistryKeyword='RoamingPreferredBandType'; RegistryValue=@('0') } }
    function New-WifiBandBackup { throw '模拟备份失败' }
    function Set-NetAdapterAdvancedProperty { $script:bandWrites++ }
    function Add-IgnoreWindow { }
    $thrown=$false
    try { Set-BandPreference 2 } catch { $thrown=$true }
    Assert-True ($thrown -and $script:bandWrites -eq 0) '备份失败仍写入频段偏好'
}
Test-Case '相同无线频段偏好不重复写入或备份' {
    . (Import-Function (Join-Path $root 'src\网络优化器.ps1') 'Set-BandPreference')
    $script:bandWrites = 0; $script:bandBackups = 0
    function Get-WirelessAdapter { [pscustomobject]@{ Name='test-wifi' } }
    function Get-NetAdapterAdvancedProperty { [pscustomobject]@{ RegistryKeyword='RoamingPreferredBandType'; RegistryValue=@('2') } }
    function New-WifiBandBackup { $script:bandBackups++; 'test-backup.json' }
    function Set-NetAdapterAdvancedProperty { $script:bandWrites++ }
    function Add-IgnoreWindow { }
    Set-BandPreference 2 | Out-Null
    Assert-True ($script:bandWrites -eq 0 -and $script:bandBackups -eq 0) '同值重复修改或产生无用备份'
}
Test-Case '无线频段写后必须复检而非直接报成功' {
    . (Import-Function (Join-Path $root 'src\网络优化器.ps1') 'Set-BandPreference')
    function Get-WirelessAdapter { [pscustomobject]@{ Name='test-wifi' } }
    function Get-NetAdapterAdvancedProperty { [pscustomobject]@{ RegistryKeyword='RoamingPreferredBandType'; RegistryValue=@('0') } }
    function New-WifiBandBackup { 'test-backup.json' }
    function Set-NetAdapterAdvancedProperty { }
    function Add-IgnoreWindow { }
    $thrown=$false
    try { Set-BandPreference 2 } catch { $thrown=$true }
    Assert-True $thrown '驱动忽略写入时仍报告成功'
}
Test-Case '版本比较只认更高版本' {
    . (Import-Function (Join-Path $root 'src\网络优化器.ps1') 'Test-NewerVersion')
    Assert-True (Test-NewerVersion '1.4.1' 'v1.4.2') '更高的版本没有被识别'
    Assert-True (-not (Test-NewerVersion '1.4.1' 'v1.4.1')) '相同版本被判定为更新'
    Assert-True (-not (Test-NewerVersion '1.4.2' 'v1.4.1')) '更低版本被判定为更新'
    Assert-True (-not (Test-NewerVersion '1.4.1' 'not-a-version')) '非法版本被当成更新'
}
Test-Case '崩溃报告包含版本、异常类型和消息' {
    . (Import-Function (Join-Path $root 'src\网络优化器.ps1') 'Format-CrashReport')
    $script:AppVersion = '9.9.9'
    $exception = New-Object System.InvalidOperationException('模拟崩溃')
    $text = Format-CrashReport $exception
    Assert-True ($text -match '9\.9\.9' -and $text -match 'InvalidOperationException' -and $text -match '模拟崩溃') '崩溃报告缺少关键信息'
    $record = New-Object System.Management.Automation.ErrorRecord($exception,'test','NotSpecified',$null)
    Assert-True ((Format-CrashReport $record) -match '模拟崩溃') 'ErrorRecord 没有被拆出异常'
}
Write-Host ("产品回归：{0} 项，{1} 个失败" -f $script:total, $script:fail)
if ($script:fail) { exit 1 }
exit 0
