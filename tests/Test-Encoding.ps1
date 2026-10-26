#Requires -Version 5.1
<#
    tests/Test-Encoding.ps1 — 编码检查（只读）

    规则：
      · .ps1 必须是 UTF-8 with BOM
      · .cmd 必须是 GBK(936)，且不能带 BOM

    为什么重要：无 BOM 的 UTF-8 在 PowerShell 5.1 下按系统 ANSI（中文系统 = GBK）解码。
    GBK 解码时，行尾若落在多字节序列中间，会吞掉换行，把下一行代码并进注释。
    v1.2 的 Write-MarkLine 就是这样在 5.1 下整段失效的：语法解析查不出来，运行时必错。
#>
$root = Split-Path -Parent $PSScriptRoot
$utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$gbk = [System.Text.Encoding]::GetEncoding(936)
$bom = [byte[]](0xEF, 0xBB, 0xBF)

$fail = 0
$total = 0

function Test-HasBom([byte[]]$b) {
    return ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
}

# ---------- .ps1：UTF-8 BOM ----------
foreach ($d in @('src', 'src\lib', 'legacy', 'tests', 'tools')) {
    $p = Join-Path $root $d
    if (-not (Test-Path $p)) { continue }
    foreach ($f in (Get-ChildItem $p -Filter '*.ps1' -File)) {
        $total++
        $b = [System.IO.File]::ReadAllBytes($f.FullName)
        if (-not (Test-HasBom $b)) {
            $fail++
            Write-Host ("  × {0}  缺少 UTF-8 BOM" -f $f.Name) -ForegroundColor Red
            continue
        }
        try {
            [void]$utf8Strict.GetString($b, 3, $b.Length - 3)
            Write-Host ("  √ {0}  UTF-8 BOM" -f $f.Name) -ForegroundColor Gray
        } catch {
            $fail++
            Write-Host ("  × {0}  BOM 之后不是合法 UTF-8" -f $f.Name) -ForegroundColor Red
        }
    }
}

# ---------- .cmd：GBK ----------
foreach ($f in (Get-ChildItem $root -Filter '*.cmd' -File)) {
    $total++
    $b = [System.IO.File]::ReadAllBytes($f.FullName)
    if (Test-HasBom $b) {
        $fail++
        Write-Host ("  × {0}  不应带 UTF-8 BOM（cmd 需要 GBK）" -f $f.Name) -ForegroundColor Red
        continue
    }
    $txt = $gbk.GetString($b)
    if ($txt.IndexOf([char]0xFFFD) -ge 0) {
        $fail++
        Write-Host ("  × {0}  不是合法 GBK" -f $f.Name) -ForegroundColor Red
    } else {
        Write-Host ("  √ {0}  GBK" -f $f.Name) -ForegroundColor Gray
    }
}

Write-Host ("编码：{0} 个文件，{1} 个失败" -f $total, $fail) -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
exit $(if ($fail) { 1 } else { 0 })
