#Requires -Version 5.1
<#
    tools/Format.ps1 — 按项目规范规范化文件编码与换行

    做四件事（幂等，可反复运行）：
      1. .ps1 → UTF-8 带 BOM
      2. .ps1 → CRLF 换行
      3. 去掉行尾空白
      4. 去掉 Tab（替换为 4 空格）

    不做：重排缩进、改命名、改逻辑。

    用法：
      powershell -NoProfile -ExecutionPolicy Bypass -File tools\Format.ps1 -Check
      powershell -NoProfile -ExecutionPolicy Bypass -File tools\Format.ps1 -Fix
#>
[CmdletBinding()]
param(
    [string]$Root,
    [switch]$Fix,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
if (-not $Check -and -not $Fix) { $Check = $true }

$utf8Bom = New-Object System.Text.UTF8Encoding($true)

$files = @(Get-ChildItem $Root -Recurse -File -Include '*.ps1' -ErrorAction SilentlyContinue |
           Where-Object { $_.FullName -notmatch '[\\/]_qa[\\/]' -and $_.FullName -notmatch '[\\/]app[\\/]' })

$changed = 0
foreach ($f in $files) {
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)
    $raw = [IO.File]::ReadAllText($f.FullName)

    $text = $raw -replace "`r`n", "`n"
    $text = $text -replace "`t", '    '
    $text = ($text -split "`n" | ForEach-Object { $_ -replace '[ ]+$', '' }) -join "`n"
    $text = $text -replace "`n", "`r`n"

    $needsFix = (-not $hasBom) -or ($text -ne $raw)
    if (-not $needsFix) { continue }

    if ($Fix) {
        [IO.File]::WriteAllText($f.FullName, $text, $utf8Bom)
        Write-Host ("  已修正: {0}" -f $f.FullName.Substring($Root.Length + 1)) -ForegroundColor Yellow
        $changed++
    } else {
        Write-Host ("  需要修正: {0}" -f $f.FullName.Substring($Root.Length + 1)) -ForegroundColor Yellow
        $changed++
    }
}

if ($changed -eq 0) { Write-Host "  全部符合规范" -ForegroundColor Green }
elseif ($Fix) { Write-Host ("  共修正 {0} 个文件" -f $changed) -ForegroundColor Green }
else { Write-Host ("  共 {0} 个文件需要修正，运行 -Fix 处理" -f $changed) -ForegroundColor Yellow }

exit $(if ($Check -and $changed -gt 0) { 1 } else { 0 })
