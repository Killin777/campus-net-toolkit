#Requires -Version 5.1
[CmdletBinding()]
param([string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) { $OutputDirectory = $root }
$iconPath = Join-Path $root 'assets\lingzhi.ico'
if (-not (Test-Path -LiteralPath $iconPath)) { throw '缺少应用图标 assets\lingzhi.ico' }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$stage = Join-Path $root ('_qa\build-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$archivePath = Join-Path $stage 'payload.zip'
$files = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'package-files.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$sourceFiles=@(Get-ChildItem -LiteralPath (Join-Path $root 'src') -Recurse -File -Filter '*.ps1' | ForEach-Object { $_.FullName.Substring($root.Length + 1).Replace('\','/') })
foreach ($sourceFile in $sourceFiles) { if ($files -notcontains $sourceFile) { throw "运行依赖不在发布白名单：$sourceFile" } }
$manifest = [ordered]@{ version=([IO.File]::ReadAllText((Join-Path $root 'VERSION')).Trim()); files=@() }
$zip = [IO.Compression.ZipFile]::Open($archivePath, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($relative in ($files | Sort-Object -Unique)) {
        $path = Join-Path $root $relative
        $bytes=[IO.File]::ReadAllBytes($path)
        if ($relative.EndsWith('.ps1')) {
            if ($bytes.Length -lt 3 -or $bytes[0] -ne 239 -or $bytes[1] -ne 187 -or $bytes[2] -ne 191) { throw "脚本缺少 UTF-8 BOM：$relative" }
            $errors=$null
            [void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$null,[ref]$errors)
            if ($errors.Count) { throw "脚本语法错误：$relative" }
        }
        $hasher=[Security.Cryptography.SHA256]::Create()
        try { $digest=[BitConverter]::ToString($hasher.ComputeHash($bytes)).Replace('-','').ToLowerInvariant() } finally { $hasher.Dispose() }
        $manifest.files += [ordered]@{ path=$relative; sha256=$digest }
        $entry=$zip.CreateEntry($relative,[IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime=[DateTimeOffset]'2000-01-01T00:00:00+00:00'
        $stream=$entry.Open()
        try { $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
    }
} finally { $zip.Dispose() }
$manifestPath = Join-Path $stage 'manifest.json'
[IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
$compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw '缺少 Windows .NET Framework 4.x 编译器' }
$output = Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) '网络优化器.exe'
$temporaryExe = Join-Path $stage '网络优化器.exe'
& $compiler /nologo /target:winexe /platform:anycpu /optimize+ /utf8output "/out:$temporaryExe" "/win32icon:$iconPath" `
    /reference:System.Windows.Forms.dll /reference:System.Web.Extensions.dll /reference:System.Core.dll `
    /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll `
    "/resource:$archivePath,Toolkit.Payload.zip" "/resource:$manifestPath,Toolkit.Manifest.json" (Join-Path $PSScriptRoot 'Launcher.cs')
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $temporaryExe)) { throw 'EXE 编译失败' }
Copy-Item -LiteralPath $temporaryExe -Destination $output -Force
$hash = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText(($output + '.sha256'), ($hash + '  网络优化器.exe' + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
Write-Host ("构建成功：{0}（{1:N0} 字节，内置 {2} 个文件）" -f $output, (Get-Item -LiteralPath $output).Length, $manifest.files.Count)
