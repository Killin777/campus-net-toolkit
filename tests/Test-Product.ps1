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
Write-Host ("产品回归：{0} 项，{1} 个失败" -f $script:total, $script:fail)
if ($script:fail) { exit 1 }
exit 0
