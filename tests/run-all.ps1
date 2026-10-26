#Requires -Version 5.1
<#
    tests/run-all.ps1 — 跑全部无界面测试

    用法：  .\tests\run-all.ps1
    退出码：0 全通过，1 有失败

    说明：语法解析会分别用 Windows PowerShell 5.1 和 PowerShell 7（若已安装）各跑一遍。
          5.1 是实际交付环境（.cmd 调的就是它），7 用来提前发现版本差异。
#>
[CmdletBinding()]
param([string]$ExecutablePath)
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
if (-not $ExecutablePath) { $ExecutablePath = Join-Path $root '网络优化器.exe' }
Write-Host "`n===== 网络优化器 测试套件 =====" -ForegroundColor Cyan
Write-Host ("项目根: {0}" -f $root) -ForegroundColor DarkGray
Write-Host ("PowerShell: {0}" -f $PSVersionTable.PSVersion) -ForegroundColor DarkGray

$hasPwsh = [bool](Get-Command pwsh -ErrorAction SilentlyContinue)
$suites = @(
    @{ Name = '语法解析 (PowerShell 5.1)'; Script = 'Test-Syntax.ps1';   Engine = 'powershell.exe' },
    @{ Name = '语法解析 (PowerShell 7)';   Script = 'Test-Syntax.ps1';   Engine = 'pwsh' },
    @{ Name = '编码 (BOM/GBK)';            Script = 'Test-Encoding.ps1'; Engine = 'powershell.exe' },
    @{ Name = '格式规范';                Script = 'Test-Style.ps1';      Engine = 'powershell.exe' },
    @{ Name = '协议识别';                  Script = 'Test-Protocol.ps1'; Engine = 'powershell.exe' },
    @{ Name = '产品逻辑';                  Script = 'Test-Product.ps1'; Engine = 'powershell.exe' },
    @{ Name = '诊断边界';                  Script = 'Test-Diagnostics.ps1'; Engine = 'powershell.exe' },
    @{ Name = '启动权限与升级';            Script = 'Test-Launcher.ps1'; Engine = 'powershell.exe'; Package=$true },
    @{ Name = '发布包隔离';                Script = 'Test-Package.ps1'; Engine = 'powershell.exe'; Package=$true }
)

$failed = @()
$ran = 0
foreach ($s in $suites) {
    if ($s.Engine -eq 'pwsh' -and -not $hasPwsh) {
        Write-Host ("`n--- {0} --- 跳过（未安装 pwsh）" -f $s.Name) -ForegroundColor DarkGray
        continue
    }
    Write-Host ("`n--- {0} ---" -f $s.Name) -ForegroundColor Cyan
    $path = Join-Path $PSScriptRoot $s.Script
    if (-not (Test-Path $path)) { Write-Host "  缺少 $($s.Script)" -ForegroundColor Red; $failed += $s.Name; continue }
    if ($s.Package) { & $s.Engine -NoProfile -ExecutionPolicy Bypass -File $path -ExecutablePath $ExecutablePath }
    else { & $s.Engine -NoProfile -ExecutionPolicy Bypass -File $path }
    if ($LASTEXITCODE -ne 0) { $failed += $s.Name }
    $ran++
}

Write-Host "`n===== 汇总 =====" -ForegroundColor Cyan
if ($failed.Count -eq 0) {
    Write-Host ("全部通过（{0} 个套件）" -f $ran) -ForegroundColor Green
    exit 0
} else {
    Write-Host ("失败套件: {0}" -f ($failed -join ', ')) -ForegroundColor Red
    exit 1
}
