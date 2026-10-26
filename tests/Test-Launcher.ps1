#Requires -Version 5.1
[CmdletBinding()]
param([string]$ExecutablePath)
$ErrorActionPreference='Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $ExecutablePath) { $ExecutablePath = Join-Path $root '网络优化器.exe' }
Add-Type -AssemblyName System.Windows.Forms
$assembly=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes([IO.Path]::GetFullPath($ExecutablePath)))
$launcher=$assembly.GetType('Launcher',$true)
$sandbox=Join-Path $root ('_qa\launcher-tests\'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($sandbox)
$script:count=0; $script:fail=0
function Invoke-LauncherMethod($name,[object[]]$arguments) {
    $method=$launcher.GetMethod($name,[Reflection.BindingFlags]'Public,Static')
    if (-not $method) { throw "缺少可验证的启动器接口：$name" }
    $parameters=$method.GetParameters()
    $converted=New-Object object[] $arguments.Count
    for ($index=0;$index -lt $arguments.Count;$index++) { $converted[$index]=[Management.Automation.LanguagePrimitives]::ConvertTo($arguments[$index],$parameters[$index].ParameterType) }
    return $method.Invoke($null,$converted)
}
function Test-Case($name,[scriptblock]$test) {
    $script:count++
    try { & $test; Write-Host "  PASS $name" }
    catch { $script:fail++; Write-Host "  FAIL $name : $($_.Exception.GetBaseException().Message)" -ForegroundColor Red }
}
function Assert-True($value,$message) { if (-not $value) { throw $message } }
$preference=Join-Path $sandbox 'runtime\launcher.json'
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $preference))
Test-Case '首次没有权限偏好时需要询问' {
    Assert-True ($null -eq (Invoke-LauncherMethod 'LoadPreference' @($preference))) '无记录却自动选择权限'
}
Test-Case '选择管理员后保存并可重读' {
    Invoke-LauncherMethod 'ApplyPreferenceChoice' @($preference,[Windows.Forms.DialogResult]::Yes) | Out-Null
    Assert-True ((Invoke-LauncherMethod 'LoadPreference' @($preference)) -eq $true) '管理员偏好未保存'
}
Test-Case '修改为普通权限后覆盖原选择' {
    Invoke-LauncherMethod 'ApplyPreferenceChoice' @($preference,[Windows.Forms.DialogResult]::No) | Out-Null
    Assert-True ((Invoke-LauncherMethod 'LoadPreference' @($preference)) -eq $false) '普通权限偏好未保存'
}
Test-Case '取消不保存新偏好，也不覆盖已有偏好' {
    $emptyPath=Join-Path $sandbox 'cancelled\launcher.json'
    Invoke-LauncherMethod 'ApplyPreferenceChoice' @($emptyPath,[Windows.Forms.DialogResult]::Cancel) | Out-Null
    Assert-True (-not [IO.File]::Exists($emptyPath)) '取消后仍生成了偏好文件'
    $before=[IO.File]::ReadAllText($preference)
    Invoke-LauncherMethod 'ApplyPreferenceChoice' @($preference,[Windows.Forms.DialogResult]::Cancel) | Out-Null
    Assert-True ([IO.File]::ReadAllText($preference) -ceq $before) '取消覆盖了旧偏好'
}
Test-Case '偏好损坏时重新询问' {
    [IO.File]::WriteAllText($preference,'{invalid-json')
    Assert-True ($null -eq (Invoke-LauncherMethod 'LoadPreference' @($preference))) '损坏记录被当成有效选择'
}
Test-Case '旧版白名单导入保留备份、忽略日志和启动偏好' {
    $legacy=Join-Path $sandbox 'old'; $data=Join-Path $sandbox 'new'
    [void][IO.Directory]::CreateDirectory((Join-Path $legacy 'runtime'))
    [void][IO.Directory]::CreateDirectory((Join-Path $legacy 'config'))
    [IO.File]::WriteAllText((Join-Path $legacy 'runtime\mode-state.json'),'{"activeMode":"game"}')
    [IO.File]::WriteAllText((Join-Path $legacy 'config\proxy-config.json'),'{"port":12345}')
    [IO.File]::WriteAllText((Join-Path $legacy 'runtime\old.log'),'not copied')
    [IO.File]::WriteAllText((Join-Path $legacy 'runtime\launcher.json'),'not copied')
    Invoke-LauncherMethod 'ImportLegacyData' @($legacy,$data) | Out-Null
    Assert-True ([IO.File]::Exists((Join-Path $data 'runtime\mode-state.json'))) '旧还原记录未导入'
    Assert-True ([IO.File]::Exists((Join-Path $data 'runtime\imported-proxy-config.json'))) '手工配置未导入'
    Assert-True (-not [IO.Directory]::Exists((Join-Path $data 'config'))) '迁移程序写入了只读 config 目录'
    Assert-True (-not [IO.File]::Exists((Join-Path $data 'runtime\old.log'))) '旧日志被夹带'
    Assert-True (-not [IO.File]::Exists((Join-Path $data 'runtime\launcher.json'))) '启动偏好被旧文件覆盖'
}
Test-Case '导入旧版数据不覆盖新状态，也不重复导入' {
    $legacy=Join-Path $sandbox 'old'; $data=Join-Path $sandbox 'new'
    $state=Join-Path $data 'runtime\mode-state.json'
    [IO.File]::WriteAllText($state,'{"activeMode":"direct"}')
    Invoke-LauncherMethod 'ImportLegacyData' @($legacy,$data) | Out-Null
    Assert-True ([IO.File]::ReadAllText($state) -ceq '{"activeMode":"direct"}') '旧数据覆盖新状态'
}
Write-Host ("启动器回归：{0} 项，{1} 个失败" -f $script:count,$script:fail)
if ($script:fail) { exit 1 }; exit 0
