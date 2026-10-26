#Requires -Version 5.1
<#
    tests/Test-Syntax.ps1 — 全文件语法解析
    不修改任何东西，纯静态检查。
#>
$root = Split-Path -Parent $PSScriptRoot
$dirs = @('src', 'src\lib', 'legacy', 'tests', 'tools')

$fail = 0
$total = 0
foreach ($d in $dirs) {
    $p = Join-Path $root $d
    if (-not (Test-Path $p)) { continue }
    Get-ChildItem $p -Filter '*.ps1' -File | ForEach-Object {
        $total++
        $err = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$err)
        if ($err.Count -eq 0) {
            Write-Host ("  √ {0}" -f $_.Name) -ForegroundColor Gray
        } else {
            $fail++
            Write-Host ("  × {0}  共 {1} 个错误" -f $_.Name, $err.Count) -ForegroundColor Red
            $err | Select-Object -First 3 | ForEach-Object {
                Write-Host ("      L{0}: {1}" -f $_.Extent.StartLineNumber, $_.Message) -ForegroundColor DarkGray
            }
        }
    }
}
Write-Host ("语法：{0} 个文件，{1} 个失败" -f $total, $fail) -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
exit $(if ($fail) { 1 } else { 0 })
