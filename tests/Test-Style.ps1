#Requires -Version 5.1
<#
    tests/Test-Style.ps1 — 代码格式检查（只检查，不修改文件）

    规则（对应 docs/SYSTEM-PROMPT.md）：
      1. .ps1 必须 UTF-8 带 BOM
      2. .ps1 换行必须是 CRLF
      3. 禁止 Tab
      4. 禁止行尾空白
      5. 缩进为 4 的倍数（续行、对齐行除外）
      6. .cmd / .bat 必须是 GBK（不能是 UTF-8 BOM）
      7. .ps1 文件末尾必须有换行

    修正手段：tools/Format.ps1 -Fix
    退出码：0 通过，1 有失败
#>
[CmdletBinding()]
param([string]$Root)

$ErrorActionPreference = 'Continue'
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }

$script:count = 0
$script:fail = 0

function Test-Case($name, [scriptblock]$test) {
    $script:count++
    try { & $test; Write-Host "  PASS $name" -ForegroundColor DarkGray }
    catch { $script:fail++; Write-Host "  FAIL $name : $($_.Exception.Message)" -ForegroundColor Red }
}

$files = @(Get-ChildItem $Root -Recurse -File -Include '*.ps1', '*.cmd', '*.bat' -ErrorAction SilentlyContinue |
           Where-Object { $_.FullName -notmatch '[\\/]_qa[\\/]' -and $_.FullName -notmatch '[\\/]app[\\/]' })

Write-Host ("  检查 {0} 个文件" -f $files.Count) -ForegroundColor DarkGray

Test-Case '所有 .ps1 带 UTF-8 BOM' {
    $bad = @()
    foreach ($f in $files | Where-Object Extension -eq '.ps1') {
        $b = [IO.File]::ReadAllBytes($f.FullName)
        if (-not ($b.Length -ge 3 -and $b[0] -eq 239 -and $b[1] -eq 187 -and $b[2] -eq 191)) { $bad += $f.Name }
    }
    if ($bad.Count) { throw ("缺 BOM: " + ($bad -join ', ')) }
}

Test-Case '所有 .ps1 使用 CRLF 换行' {
    $bad = @()
    foreach ($f in $files | Where-Object Extension -eq '.ps1') {
        $text = [IO.File]::ReadAllText($f.FullName)
        if ($text -match "(?<!`r)`n") { $bad += $f.Name }
    }
    if ($bad.Count) { throw ("含 LF: " + ($bad -join ', ')) }
}

Test-Case '没有制表符' {
    $bad = @()
    foreach ($f in $files) {
        $text = [IO.File]::ReadAllText($f.FullName)
        if ($text -match "`t") { $bad += $f.Name }
    }
    if ($bad.Count) { throw ("含 Tab: " + ($bad -join ', ')) }
}

Test-Case '没有行尾空白' {
    $bad = @()
    foreach ($f in $files | Where-Object Extension -eq '.ps1') {
        $lines = [IO.File]::ReadAllLines($f.FullName)
        $n = 0
        foreach ($ln in $lines) { if ($ln -match '[ \t]+$') { $n++ } }
        if ($n -gt 0) { $bad += ("{0}({1})" -f $f.Name, $n) }
    }
    if ($bad.Count) { throw ("行尾空白: " + ($bad -join ', ')) }
}

Test-Case '缩进为 4 的倍数（续行与块注释除外）' {
    $bad = @()
    foreach ($f in $files | Where-Object Extension -eq '.ps1') {
        $lines = [IO.File]::ReadAllLines($f.FullName)
        $n = 0
        $inComment = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $cur = $lines[$i]
            # 维护块注释状态：<# 进入，#> 退出（同一行进出也算）
            $opens = ($cur -match '<#')
            $closes = ($cur -match '#>')
            $wasInComment = $inComment
            if ($opens -and -not $closes) { $inComment = $true }
            elseif ($closes) { $inComment = $false }

            if ($wasInComment -or $opens) { continue }   # 注释内容不参与缩进检查
            if ($cur -notmatch '^( +)\S') { continue }
            if ($Matches[1].Length % 4 -eq 0) { continue }
            $prev = if ($i -gt 0) { $lines[$i - 1].TrimEnd() } else { '' }
            if ($prev -match '[(,\|=+})\]]$|@\{$|@\($') { continue }
            $n++
        }
        if ($n -gt 0) { $bad += ("{0}({1})" -f $f.Name, $n) }
    }
    if ($bad.Count) { throw ("缩进不符: " + ($bad -join ', ')) }
}

Test-Case '.cmd/.bat 为 GBK 编码' {
    $bad = @()
    foreach ($f in $files | Where-Object { $_.Extension -in '.cmd', '.bat' }) {
        $b = [IO.File]::ReadAllBytes($f.FullName)
        if ($b.Length -ge 3 -and $b[0] -eq 239 -and $b[1] -eq 187 -and $b[2] -eq 191) { $bad += ("{0}(BOM)" -f $f.Name); continue }
        $isAscii = $true
        foreach ($x in $b) { if ($x -gt 127) { $isAscii = $false; break } }
        if ($isAscii) { continue }
        try {
            $strict = New-Object System.Text.UTF8Encoding($false, $true)
            [void]$strict.GetString($b)
            $bad += ("{0}(UTF-8)" -f $f.Name)
        } catch { }
    }
    if ($bad.Count) { throw ("非 GBK: " + ($bad -join ', ')) }
}

Test-Case '.ps1 文件末尾有换行' {
    $bad = @()
    foreach ($f in $files | Where-Object Extension -eq '.ps1') {
        $text = [IO.File]::ReadAllText($f.FullName)
        if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { $bad += $f.Name }
    }
    if ($bad.Count) { throw ("末尾缺换行: " + ($bad -join ', ')) }
}

Write-Host ("  格式：{0} 项，{1} 个失败" -f $script:count, $script:fail) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
if ($script:fail) { exit 1 }
exit 0
