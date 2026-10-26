#Requires -Version 5.1
[CmdletBinding()]
param([string]$ExecutablePath)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $ExecutablePath) { $ExecutablePath = Join-Path $root '网络优化器.exe' }
try {
    $exe = [IO.Path]::GetFullPath($ExecutablePath)
    $asm = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($exe))
    $payload = $asm.GetManifestResourceStream('Toolkit.Payload.zip')
    if (-not $payload) { throw 'EXE 没有内置程序文件，仍然依赖旁边的源码目录' }
    $payload.Dispose()
    $manifestStream = $asm.GetManifestResourceStream('Toolkit.Manifest.json')
    if (-not $manifestStream) { throw '缺少可验证的发布清单' }
    $reader = New-Object IO.StreamReader($manifestStream)
    $manifest = $reader.ReadToEnd() | ConvertFrom-Json
    $reader.Dispose()
    if (@($manifest.files).Count -lt 6) { throw '发布清单不完整' }
    $bad = @($manifest.files | Where-Object { $_.path -match '(^runtime/|\.lnk$|^legacy/)' -or ($_.path -match '^config/' -and $_.path -notmatch '\.example\.json$') })
    if ($bad.Count) { throw '发布包包含个人配置、运行数据或旧入口' }
    $expected=Get-Content -LiteralPath (Join-Path $root 'tools\package-files.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if (@(Compare-Object @($expected) @($manifest.files.path)).Count -gt 0) { throw 'EXE 资源与发布白名单不一致' }
    foreach ($file in $manifest.files) {
        $source=Join-Path $root $file.path
        if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -ne $file.sha256) { throw ('EXE 与源码不一致，需重建：'+$file.path) }
    }
    if ($manifest.version -ne ([IO.File]::ReadAllText((Join-Path $root 'VERSION')).Trim())) { throw 'EXE 版本与 VERSION 不一致' }
    Write-Host "  PASS EXE 内置资源、发布清单、源码一致性和数据隔离"
    exit 0
} catch { Write-Host "  FAIL $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
