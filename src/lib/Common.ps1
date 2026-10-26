#Requires -Version 5.1
<#
    src/lib/Common.ps1 — 共享工具函数

    调用约定：
      调用方必须先定义 $script:ProjRoot（项目根目录），再点源本文件：
          $script:ProjRoot = Split-Path -Parent $PSScriptRoot
          . (Join-Path $PSScriptRoot 'lib\Common.ps1')

    注意：本文件不要定义 param()，否则点源时会覆盖调用方的同名变量。
#>

if (-not $script:ProjRoot) {
    throw 'Common.ps1 需要调用方先定义 $script:ProjRoot'
}

# 程序代码和可写数据分离。源码运行沿用项目目录，EXE 通过环境变量传入用户目录。
if (-not $script:DataRoot) {
    $script:DataRoot = if ($env:CAMPUS_NET_DATA_ROOT) { $env:CAMPUS_NET_DATA_ROOT } else { $script:ProjRoot }
}
$script:DataRoot = [IO.Path]::GetFullPath($script:DataRoot)
$env:CAMPUS_NET_DATA_ROOT = $script:DataRoot

function ConvertTo-WindowsArgument([AllowEmptyString()][string]$Value) {
    $result = New-Object Text.StringBuilder
    [void]$result.Append('"')
    $slashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') { $slashes++; continue }
        if ($ch -eq '"') {
            [void]$result.Append(('\' * (2 * $slashes + 1)))
        } else { [void]$result.Append(('\' * $slashes)) }
        [void]$result.Append($ch)
        $slashes = 0
    }
    [void]$result.Append(('\' * (2 * $slashes)))
    [void]$result.Append('"')
    return $result.ToString()
}

function Save-ToolkitJson($Value, [string]$Path, [int]$Depth = 8) {
    $dir = Split-Path -Parent $Path
    [void][IO.Directory]::CreateDirectory($dir)
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth $Depth), (New-Object Text.UTF8Encoding($true)))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

. (Join-Path $PSScriptRoot 'NetworkState.ps1')

function Read-ProxySettings {
    $settings = @{}
    foreach ($relative in @('runtime\imported-proxy-config.json','config\proxy-config.json','runtime\proxy-settings.json')) {
        $path = Join-Path $script:DataRoot $relative
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try {
            $value = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($value -is [array] -or $value -is [string] -or $value -is [ValueType]) { throw '配置必须是 JSON 对象' }
            foreach ($property in $value.PSObject.Properties) { $settings[$property.Name] = $property.Value }
        } catch { Write-Warning ('无法读取配置 ' + $relative + '：' + $_.Exception.Message) }
    }
    return $settings
}

function Read-ChildOutput([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    try { $decoded = (New-Object Text.UTF8Encoding($false,$true)).GetString($bytes) }
    catch { $decoded = [Text.Encoding]::GetEncoding(936).GetString($bytes) }
    return $decoded.TrimStart([char]0xFEFF)
}

# 输出被重定向到文件/管道时统一用 UTF-8，否则 5.1 会按控制台 OEM 代码页（中文系统 GBK）写，
# 下游按 UTF-8 读就是乱码。只影响重定向，不影响 cmd 窗口里的正常显示。
if ([Console]::IsOutputRedirected) {
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
}

# ============================ 文本宽度 / 输出 ============================
function Get-DisplayWidth([string]$s) {
    # 中日韩字符占两列；PowerShell 的 -f 对齐按字符数算，会把中文列撑歪
    $w = 0
    foreach ($ch in $s.ToCharArray()) {
        $c = [int]$ch
        if (($c -ge 0x1100 -and $c -le 0x115F) -or ($c -ge 0x2E80 -and $c -le 0xA4CF) -or
            ($c -ge 0xAC00 -and $c -le 0xD7A3) -or ($c -ge 0xF900 -and $c -le 0xFAFF) -or
            ($c -ge 0xFE30 -and $c -le 0xFE6F) -or ($c -ge 0xFF00 -and $c -le 0xFF60) -or
            ($c -ge 0xFFE0 -and $c -le 0xFFE6)) { $w += 2 } else { $w += 1 }
    }
    return $w
}

function Pad-Display([string]$s, [int]$width) {
    $cur = Get-DisplayWidth $s
    if ($cur -ge $width) { return $s }
    return $s + (' ' * ($width - $cur))
}

function Write-MarkLine([string]$mark, [bool]$ok, [string]$text) {
    # 只用一次 Write-Host 输出整行：
    #   · -NoNewline 在被重定向时会被信息流拆成两行
    #   · [Console]::Write 在没有控制台窗口（隐藏启动/GUI）时会静默丢失
    # 注意：else 必须与 if 的右花括号同行。本文件若无 BOM，5.1 会按 ANSI 解码，
    # 中文注释行尾的多字节序列可能吞掉换行，把下一行代码并进注释。
    $color = if ($ok) { 'Gray' } else { 'Red' }
    Write-Host ("{0} {1}" -f $mark, $text) -ForegroundColor $color
}

# ============================ 网络探测 ============================
function Send-PingOnce {
    param([string]$Target, [int]$Timeout = 1200)
    try {
        $p = New-Object System.Net.NetworkInformation.Ping
        $r = $p.Send($Target, $Timeout)
        $p.Dispose()
        if ($r.Status -eq 'Success') { return [int]$r.RoundtripTime }
        return -1
    } catch { return -1 }
}

# ============================ 维护窗口（排除工具自身造成的中断） ============================
$script:CommonIgnoreFile = Join-Path $script:DataRoot 'runtime\link-events-ignore.json'
$script:CommonIgnoreCache = @{ Time = [datetime]::MinValue; Windows = @() }

function Get-JsonList([string]$Path) {
    # 读 JSON 列表。不要写成 @(Get-Content | ConvertFrom-Json)：
    # PowerShell 5.1 把 JSON 数组当成"一个对象"输出，@() 会再套一层，
    # 结果 Count 恒为 1，for-each 拿到的是整个数组 —— 维护窗口会全部失效，
    # 后续 Add 还会写出 [[...],{...}] 这种嵌套结构。7 与 5.1 行为不同，必须两边都对。
    $out = @()
    if (-not (Test-Path $Path)) { return $out }
    try { $raw = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $out }
    if ($null -eq $raw) { return $out }
    if ($raw -is [array]) {
        foreach ($x in $raw) { if ($null -ne $x) { $out += $x } }
    } else {
        $out = @($raw)
    }
    return $out
}

function Get-IgnoreWindows {
    if (((Get-Date) - $script:CommonIgnoreCache.Time).TotalSeconds -lt 15) {
        return $script:CommonIgnoreCache.Windows
    }
    $w = @(Get-JsonList $script:CommonIgnoreFile)
    $script:CommonIgnoreCache = @{ Time = (Get-Date); Windows = $w }
    return $w
}

function Test-IgnoredTime([datetime]$t) {
    foreach ($w in (Get-IgnoreWindows)) {
        try {
            if ($t -ge [datetime]$w.start -and $t -le [datetime]$w.end) { return $true }
        } catch { }
    }
    return $false
}

function Add-IgnoreWindow([string]$reason, [int]$seconds = 30) {
    # 本工具会触发的短暂断链（改网卡参数、重启网卡）记进维护窗口，统计时排除
    $list = @(Get-JsonList $script:CommonIgnoreFile)
    $now = Get-Date
    $list += [pscustomobject]@{
        start  = $now.AddSeconds(-3).ToString('s')
        end    = $now.AddSeconds($seconds).ToString('s')
        reason = $reason
    }
    $list = @($list | Where-Object { $_ } | Select-Object -Last 200)
    $dir = Split-Path -Parent $script:CommonIgnoreFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    try { $list | ConvertTo-Json -Depth 3 | Set-Content -Path $script:CommonIgnoreFile -Encoding UTF8 } catch { }
    $script:CommonIgnoreCache = @{ Time = [datetime]::MinValue; Windows = @() }
}
