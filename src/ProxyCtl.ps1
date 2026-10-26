<#
    ProxyCtl.ps1  —  代理配置探测 / 验证 / 开关（不绑定任何具体客户端）
    ------------------------------------------------------------------
    设计要点：
      · 不假设你是 Clash、v2rayN 还是 sing-box —— 只认"当前生效的出口"
      · 配置可手填，但必须验证通过才算数
      · 验证分 5 层，每层给出不同结论，而不是笼统的"失败"

    用法：
      .\ProxyCtl.ps1 detect              自动探测候选（只读）
      .\ProxyCtl.ps1 verify              验证配置里的端口（只读）
      .\ProxyCtl.ps1 verify -Port 10809  验证指定端口（只读）
      .\ProxyCtl.ps1 status              简要状态
      .\ProxyCtl.ps1 envcheck            检查 WinHTTP / 环境变量 / PAC / TUN / UWP
      .\ProxyCtl.ps1 on                  开启系统代理（先验证）
      .\ProxyCtl.ps1 off                 关闭系统代理
      .\ProxyCtl.ps1 save -Port 10809    验证通过后写入配置
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('detect', 'verify', 'status', 'envcheck', 'on', 'off', 'save')]
    [string]$Action = 'verify',

    [int]$Port = 0,
    [string]$HostName = '127.0.0.1',
    [switch]$Json,
    [switch]$NoRun
)

$ErrorActionPreference = 'Continue'
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ProjRoot = Split-Path -Parent $script:Root

# 共享工具函数（文本宽度、输出、Ping、维护窗口）
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
$script:ConfigPath = Join-Path $script:DataRoot 'runtime\proxy-settings.json'

# 常见客户端默认端口（按概率排序）
$script:CommonPorts = @(7897, 7890, 10809, 7891, 10808, 2080, 20171, 1080, 8889, 7899)

# ============================ 配置 ============================
function Get-Config {
    $def = [ordered]@{
        port           = 7897
        host           = '127.0.0.1'
        mode           = 'system'          # system | tun
        clientExe      = ''
        coreProcesses  = @('verge-mihomo', 'mihomo', 'clash-meta', 'v2rayN', 'v2ray', 'sing-box', 'FlClash', 'nekobox', 'Throne')
        guiProcesses   = @('clash-verge', 'Clash Verge', 'v2rayN', 'FlClash', 'nekoray', 'Throne')
        serviceName    = ''
        bypass         = '<local>;localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*'
        lastVerified   = ''
    }
    $userSettings = Read-ProxySettings
    foreach ($key in $userSettings.Keys) { if ($def.Contains($key)) { $def[$key] = $userSettings[$key] } }

    # 配置是用户手改的，必须校验：0 / 99999 / "abc" / 负数都会让 [int] 转换或 TcpClient 抛异常
    $validPort = 0
    if (-not [int]::TryParse([string]$def.port, [ref]$validPort) -or $validPort -lt 1 -or $validPort -gt 65535) {
        Write-Warning "配置里的 port 非法（$($def.port)），改用默认值 7897"
        $def.port = 7897
    } else {
        $def.port = $validPort
    }
    if ([string]::IsNullOrWhiteSpace([string]$def.host)) {
        Write-Warning '配置里的 host 为空，改用 127.0.0.1'
        $def.host = '127.0.0.1'
    }
    if ($def.mode -notin 'system', 'tun') { $def.mode = 'system' }
    return $def
}

function Save-Config($cfg) {
    # config 只读；界面/自动探测产生的覆盖值写入 runtime。
    Save-ToolkitJson $cfg $script:ConfigPath
}

# ============================ 探测 ============================
function Get-WinInetProxy {
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $p = Get-ItemProperty $k -ErrorAction SilentlyContinue
    [pscustomobject]@{
        Enabled    = ($p.ProxyEnable -eq 1)
        Server     = $p.ProxyServer
        Override   = $p.ProxyOverride
        PacUrl     = $p.AutoConfigURL
        AutoDetect = ($p.AutoDetect -eq 1)
    }
}

function Split-ProxyServer([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    $v = $s.Trim()
    if ($v -match '=') {
        $http = ($v -split ';' | Where-Object { $_ -match '^\s*http=' } | Select-Object -First 1)
        if ($http) { $v = ($http -replace '^\s*http=', '').Trim() }
        else { $v = (($v -split ';')[0] -replace '^\s*[a-z]+=', '').Trim() }
    }
    if ($v -match '^(?<h>[^:]+):(?<p>\d+)$') {
        return [pscustomobject]@{ Host = $Matches['h']; Port = [int]$Matches['p'] }
    }
    return $null
}

function Get-WinHttpProxy {
    $out = (netsh winhttp show proxy) -join "`n"
    if ($out -match '(?i)direct access|直接访问') { return 'DIRECT' }
    if ($out -match '(?i)Proxy Server\(s\)\s*:\s*(\S+)|代理服务器\s*:\s*(\S+)') {
        return ($Matches[1] + $Matches[2])
    }
    return 'UNKNOWN'
}

function Get-EnvProxy {
    $r = [ordered]@{}
    foreach ($n in 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY',
                     'http_proxy', 'https_proxy', 'all_proxy', 'no_proxy') {
        $v = [Environment]::GetEnvironmentVariable($n, 'Process')
        $u = [Environment]::GetEnvironmentVariable($n, 'User')
        $m = [Environment]::GetEnvironmentVariable($n, 'Machine')
        if ($v -or $u -or $m) {
            $r[$n] = @{ Process = $v; User = $u; Machine = $m }
        }
    }
    return $r
}

function Get-TunAdapters {
    # 只认代理软件创建的 TUN 网卡；Tailscale/Radmin 这类 VPN 不算
    $pat = '(?i)mihomo|sing-?box|clash|wintun|meta'
    return @(Get-NetAdapter -ErrorAction SilentlyContinue |
             Where-Object { $_.Status -eq 'Up' -and $_.Name -match $pat } |
             Select-Object Name, InterfaceDescription, LinkSpeed)
}

function Get-OtherVirtualAdapters {
    # 其他虚拟网卡：不是代理，但会加默认路由，断网时可能吞流量
    $pat = '(?i)tailscale|radmin|wireguard|zerotier|openvpn|vmware|virtualbox|hyper-v|vpn'
    $tunNames = @(Get-TunAdapters | ForEach-Object { $_.Name })
    return @(Get-NetAdapter -ErrorAction SilentlyContinue |
             Where-Object { $_.Status -eq 'Up' -and $_.Name -match $pat -and $tunNames -notcontains $_.Name } |
             Select-Object Name, InterfaceDescription, LinkSpeed)
}

function Get-PortOwner([int]$p) {
    $c = Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $c) { return $null }
    $proc = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
    return [pscustomobject]@{
        Pid      = $c.OwningProcess
        Name     = if ($proc) { $proc.Name } else { '?' }
        Path     = if ($proc) { $proc.Path } else { '' }
        LoopbackOnly = ($c.LocalAddress -in '127.0.0.1', '::1')
        Address  = $c.LocalAddress
    }
}

# ============================ 5 层验证 ============================
function Test-Tcp([string]$h, [int]$p, [int]$TimeoutMs = 2000) {
    $cl = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $cl.ConnectAsync($h, $p)
        if (-not $task.Wait($TimeoutMs)) { return $false }
        return $cl.Connected
    } catch { return $false } finally { $cl.Dispose() }
}

function Detect-Protocol([string]$h, [int]$p, [int]$TimeoutMs = 2500) {
    # 先试 HTTP CONNECT，再试 SOCKS5
    try {
        $cl = New-Object System.Net.Sockets.TcpClient
        $cl.ReceiveTimeout = $TimeoutMs
        $task = $cl.ConnectAsync($h, $p)
        if (-not $task.Wait($TimeoutMs)) { $cl.Dispose(); return 'NONE' }
        $st = $cl.GetStream()
        $req = "CONNECT www.baidu.com:443 HTTP/1.1`r`nHost: www.baidu.com:443`r`nProxy-Connection: keep-alive`r`n`r`n"
        $buf = [System.Text.Encoding]::ASCII.GetBytes($req)
        $st.Write($buf, 0, $buf.Length)
        $st.Flush()
        $rb = New-Object byte[] 64
        $n = 0
        try { $n = $st.Read($rb, 0, $rb.Length) } catch { $n = 0 }
        if ($n -gt 0) {
            $resp = [System.Text.Encoding]::ASCII.GetString($rb, 0, $n)
            $cl.Dispose()
            if ($resp -match '^HTTP/\d\.\d\s+200') { return 'HTTP' }
            if ($resp -match '^HTTP/\d\.\d\s+407') { return 'HTTP-AUTH' }
            if ($resp -match '^HTTP/\d\.\d') { return 'HTTP-ERR' }
        }
        $cl.Dispose()
    } catch { }

    try {
        $cl2 = New-Object System.Net.Sockets.TcpClient
        $cl2.ReceiveTimeout = $TimeoutMs
        $t2 = $cl2.ConnectAsync($h, $p)
        if (-not $t2.Wait($TimeoutMs)) { $cl2.Dispose(); return 'NONE' }
        $s2 = $cl2.GetStream()
        $s2.Write([byte[]]@(0x05, 0x01, 0x00), 0, 3)
        $s2.Flush()
        $rb2 = New-Object byte[] 2
        $n2 = 0
        try { $n2 = $s2.Read($rb2, 0, 2) } catch { $n2 = 0 }
        $cl2.Dispose()
        if ($n2 -eq 2 -and $rb2[0] -eq 0x05) { return 'SOCKS5' }
    } catch { }

    return 'UNKNOWN'
}

function Test-ProxyHttp {
    param([string]$h, [int]$p, [string]$Url, [ValidateSet('http', 'socks5')][string]$Kind = 'http')
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path $curl)) { return $null }
    # 直接把参数数组交给 curl.exe，不经过 cmd.exe 命令行，避免 host 注入
    $argList = @()
    if ($Kind -eq 'socks5') { $argList += @('--socks5-hostname', "$h`:$p") }
    else { $argList += @('-x', "http://$h`:$p") }
    $argList += @('-o', 'NUL', '-s', '-w', '%{http_code}|%{time_total}', '--max-time', '10', $Url)
    $out = & $curl @argList 2>$null
    if (-not $out) { return $null }
    $parts = "$out".Trim() -split '\|'
    return [pscustomobject]@{
        Code  = [int]$parts[0]
        Ms    = if ($parts.Count -gt 1) { [int]([double]$parts[1] * 1000) } else { 0 }
    }
}

function Invoke-Verify {
    param([int]$PortOverride, [switch]$Quiet, [switch]$Json)

    $cfg = Get-Config
    $p = if ($PortOverride -gt 0) { $PortOverride } else { [int]$cfg.port }
    $h = $cfg.host
    $rows = New-Object System.Collections.ArrayList
    $fails = New-Object System.Collections.ArrayList

    function Add-Row($layer, $text, $ok, $note) {
        [void]$rows.Add([pscustomobject]@{ Layer = $layer; Text = $text; Ok = $ok; Note = $note })
        if (-not $ok) { [void]$fails.Add($layer) }
    }

    # L1 端口
    $alive = Test-Tcp -h $h -p $p
    $owner = if ($alive) { Get-PortOwner $p } else { $null }
    $ownerText = if ($owner) { "PID $($owner.Pid) $($owner.Name)" } else { '' }
    Add-Row 'L1' "端口 $p 监听" $alive $(if ($alive) { $ownerText } else { '没有进程在监听' })

    # L2 协议
    $proto = if ($alive) { Detect-Protocol -h $h -p $p } else { 'NONE' }
    $protoOk = $proto -in 'HTTP', 'SOCKS5'
    $protoNote = switch ($proto) {
        'HTTP'       { 'HTTP 代理（CONNECT 成功）' }
        'HTTP-AUTH'  { 'HTTP 代理，但要求认证（407）' }
        'HTTP-ERR'   { '端口回了 HTTP，但 CONNECT 失败' }
        'SOCKS5'     { 'SOCKS5 代理（握手成功）' }
        'NONE'       { '连不上' }
        default      { '端口开着，但不像代理协议' }
    }
    Add-Row 'L2' '协议识别' $protoOk $protoNote

    # L3 / L4 只有在协议识别成功时才做
    $l3 = $null; $l4 = $null
    if ($protoOk) {
        $kind = if ($proto -eq 'SOCKS5') { 'socks5' } else { 'http' }
        $l3 = Test-ProxyHttp -h $h -p $p -Url 'http://connect.rom.miui.com/generate_204' -Kind $kind
        $l3ok = ($l3 -and $l3.Code -eq 204)
        Add-Row 'L3' '经代理访问国内 204' $l3ok $(if ($l3) { "$($l3.Code) / $($l3.Ms)ms" } else { '请求失败' })

        if ($l3ok) {
            $l4 = Test-ProxyHttp -h $h -p $p -Url 'https://www.google.com' -Kind $kind
            $l4ok = ($l4 -and $l4.Code -eq 200)
            Add-Row 'L4' '经代理访问 Google' $l4ok $(if ($l4) { "$($l4.Code) / $($l4.Ms)ms" } else { '请求失败' })
        } else {
            Add-Row 'L4' '经代理访问 Google' $false 'L3 未通过，跳过'
        }
    } else {
        Add-Row 'L3' '经代理访问国内 204' $false '协议未识别，跳过'
        Add-Row 'L4' '经代理访问 Google' $false '协议未识别，跳过'
    }

    # L5 系统代理一致性
    $wi = Get-WinInetProxy
    $parsed = Split-ProxyServer $wi.Server
    $l5ok = $wi.Enabled -and $parsed -and [int]$parsed.Port -eq $p
    $l5note = if (-not $wi.Enabled) { '系统代理未开启，浏览器不会走这个代理' }
              elseif ($wi.PacUrl) { "当前用 PAC：$($wi.PacUrl)，端口由脚本决定" }
              elseif (-not $parsed) { "系统代理值无法解析：$($wi.Server)" }
              elseif ([int]$parsed.Port -ne $p) { "系统代理指向 $($parsed.Port)，与配置的 $p 不一致" }
              else { "指向 $($parsed.Host):$($parsed.Port)" }
    Add-Row 'L5' '系统代理一致性' $l5ok $l5note

    # 结论
    $verdict = ''
    $level = 'err'
    if (-not $alive) {
        $verdict = "端口 $p 没有进程监听：客户端没启动，或端口填错了。"
    } elseif ($proto -eq 'HTTP-AUTH') {
        $verdict = "代理要求认证（407），需要在客户端里允许本地免认证，或填写用户名密码。"
    } elseif (-not $protoOk) {
        $verdict = "端口 $p 能连上，但不像 HTTP/SOCKS 代理：你可能把别的服务端口填进来了。"
    } elseif ($fails -contains 'L3') {
        $verdict = "端口和协议都对，但转发不出去：内核可能还在启动，或规则把流量全 REJECT 了。"
    } elseif ($fails -contains 'L4') {
        $verdict = "代理链路正常，但出口出不去：这是节点/订阅的问题，不是端口问题。"
    } elseif (-not $l5ok) {
        $verdict = "代理本身可用，但系统代理没指向它 —— 浏览器不会走代理。"
        $level = 'warn'
    } else {
        $verdict = "配置正确，代理可用。"
        $level = 'ok'
    }

    # Capable 只表示"这个端口能不能当代理用"（L1-L4）；
    # Ok 还要求系统代理已经指向它（L5）。开代理前应看 Capable。
    $capable = $alive -and $protoOk -and ($fails -notcontains 'L3') -and ($fails -notcontains 'L4')
    if ($Json) {
        return [pscustomobject]@{
            Port = $p; Host = $h; Alive = $alive; Protocol = $proto
            L3 = $l3; L4 = $l4; SystemProxy = $wi.Enabled
            Ok = ($level -eq 'ok'); Capable = $capable; Level = $level; Verdict = $verdict
            Rows = $rows
        }
    }

    if (-not $Quiet) {
        Write-Host ""
        Write-Host "验证目标：$h`:$p" -ForegroundColor White
        Write-Host ("-" * 62) -ForegroundColor DarkGray
        foreach ($r in $rows) {
            $mark = if ($r.Ok) { '  √' } else { '  ×' }
            Write-MarkLine $mark $r.Ok ((Pad-Display $r.Text 30) + $r.Note)
        }
        Write-Host ("-" * 62) -ForegroundColor DarkGray
        $c = switch ($level) { 'ok' { 'Green' } 'warn' { 'Yellow' } default { 'Red' } }
        Write-Host "结论：$verdict" -ForegroundColor $c
    }
    return [pscustomobject]@{ Ok = ($level -eq 'ok'); Capable = $capable; Level = $level; Verdict = $verdict; Port = $p }
}

# ============================ 命令 ============================
function Invoke-Detect {
    $cfg = Get-Config
    $wi = Get-WinInetProxy
    Write-Host "`n===== 当前事实 =====" -ForegroundColor Cyan
    Write-Host ("系统代理 : {0}" -f $(if ($wi.Enabled) { "开启 -> $($wi.Server)" } else { '关闭' }))
    if ($wi.PacUrl) { Write-Host ("PAC 脚本 : {0}" -f $wi.PacUrl) -ForegroundColor Yellow }
    if ($wi.AutoDetect) { Write-Host "自动检测 : 开启（WPAD）" -ForegroundColor Yellow }
    Write-Host ("WinHTTP  : {0}" -f (Get-WinHttpProxy))

    $envP = Get-EnvProxy
    if ($envP.Count -gt 0) {
        Write-Host "环境变量 :" -ForegroundColor Yellow
        foreach ($k in $envP.Keys) { $val = $envP[$k].Process; if (-not $val) { $val = $envP[$k].User }; if (-not $val) { $val = $envP[$k].Machine }; Write-Host ("    {0} = {1}" -f $k, $val) }
    }

    $tun = Get-TunAdapters
    if ($tun.Count -gt 0) {
        Write-Host "`n虚拟网卡（TUN/TAP/VPN）：" -ForegroundColor Yellow
        foreach ($t in $tun) { Write-Host ("    {0,-22} {1}" -f $t.Name, $t.InterfaceDescription) }
    }

    Write-Host "`n===== 端口扫描 =====" -ForegroundColor Cyan
    $found = @()
    foreach ($p in $script:CommonPorts) {
        if (Test-Tcp -h '127.0.0.1' -p $p -TimeoutMs 400) {
            $o = Get-PortOwner $p
            $proto = Detect-Protocol -h '127.0.0.1' -p $p -TimeoutMs 1500
            $found += [pscustomobject]@{ Port = $p; Proto = $proto; Proc = if ($o) { "$($o.Name)($($o.Pid))" } else { '?' } }
            Write-Host ("    {0,-6} {1,-8} {2}" -f $p, $proto, $(if ($o) { "$($o.Name) ($($o.Pid))" } else { '?' })) -ForegroundColor Green
        }
    }
    if ($found.Count -eq 0) { Write-Host "    没有发现常见的代理端口" -ForegroundColor DarkGray }

    Write-Host "`n===== 建议 =====" -ForegroundColor Cyan
    $best = $found | Where-Object { $_.Proto -in 'HTTP', 'SOCKS5' } | Select-Object -First 1
    if ($best) {
        Write-Host ("    用 {0}（{1}）作为代理端口，执行：.\ProxyCtl.ps1 verify -Port {0}" -f $best.Port, $best.Proto) -ForegroundColor Green
    } elseif ($tun.Count -gt 0) {
        Write-Host "    没有系统代理端口，但存在虚拟网卡 —— 你可能是 TUN 模式，不需要设置系统代理" -ForegroundColor Yellow
    } else {
        Write-Host "    没找到可用的代理端口，客户端可能没启动" -ForegroundColor Red
    }
}

function Invoke-Status {
    $cfg = Get-Config
    $wi = Get-WinInetProxy
    $p = [int]$cfg.port
    $alive = Test-Tcp -h $cfg.host -p $p
    $o = if ($alive) { Get-PortOwner $p } else { $null }
    Write-Host ""
    Write-Host ("配置端口   : {0}:{1}" -f $cfg.host, $p)
    Write-Host ("端口监听   : {0}" -f $(if ($alive) { "是  $(if ($o) { "($($o.Name) PID $($o.Pid))" })" } else { '否' }))
    Write-Host ("系统代理   : {0}" -f $(if ($wi.Enabled) { "开启 -> $($wi.Server)" } else { '关闭' }))
    $parsed = Split-ProxyServer $wi.Server
    if ($wi.Enabled -and -not $alive) {
        Write-Host "  !! 代理残留：系统代理开着但内核已死，网页会全部打不开" -ForegroundColor Red
    }
    if ($wi.Enabled -and $parsed -and [int]$parsed.Port -ne $p) {
        Write-Host "  !! 系统代理端口与配置不一致（$($parsed.Port) vs $p）" -ForegroundColor Yellow
    }
    if ($wi.PacUrl) { Write-Host "  !! 正在使用 PAC，端口不可控" -ForegroundColor Yellow }
}

function Invoke-EnvCheck {
    Write-Host "`n===== WinHTTP（服务/部分 CLI 使用） =====" -ForegroundColor Cyan
    Write-Host ("    {0}" -f (Get-WinHttpProxy))
    Write-Host "    说明：系统代理只覆盖 WinINET。用 WinHTTP 的程序不看注册表里的 ProxyServer。" -ForegroundColor DarkGray

    Write-Host "`n===== 环境变量 =====" -ForegroundColor Cyan
    $e = Get-EnvProxy
    $proxyVars = @($e.Keys | Where-Object { $_ -notmatch '(?i)^no_proxy$' })
    if ($e.Count -eq 0) {
        Write-Host "    未设置（干净）" -ForegroundColor Green
    } else {
        foreach ($k in $e.Keys) {
            Write-Host ("    {0,-14} Process={1}  User={2}  Machine={3}" -f $k, $e[$k].Process, $e[$k].User, $e[$k].Machine) -ForegroundColor Gray
        }
        if ($proxyVars.Count -gt 0) {
            Write-Host "    !! 存在 *_PROXY 变量，git/npm/pip 等会优先走它，可能指向已失效的端口" -ForegroundColor Red
        } else {
            Write-Host "    只有 no_proxy（绕过清单），无害" -ForegroundColor Green
        }
    }

    Write-Host "`n===== PAC / 自动检测 =====" -ForegroundColor Cyan
    $wi = Get-WinInetProxy
    Write-Host ("    AutoConfigURL : {0}" -f $(if ($wi.PacUrl) { $wi.PacUrl } else { '无' }))
    Write-Host ("    自动检测(WPAD): {0}" -f $(if ($wi.AutoDetect) { '开启' } else { '关闭' }))

    Write-Host "`n===== TUN / 虚拟网卡 =====" -ForegroundColor Cyan
    $tun = Get-TunAdapters
    if ($tun.Count -eq 0) { Write-Host "    无" -ForegroundColor Green }
    else {
        foreach ($t in $tun) { Write-Host ("    {0,-24} {1}" -f $t.Name, $t.InterfaceDescription) -ForegroundColor Yellow }
        if ($wi.Enabled) {
            Write-Host "    !! TUN 和系统代理同时开着，属于双份劫持，容易出现部分网站异常" -ForegroundColor Red
        }
    }

    Write-Host "`n===== localhost 解析 =====" -ForegroundColor Cyan
    $local = [System.Net.Dns]::GetHostAddresses('localhost') | ForEach-Object { $_.IPAddressToString }
    Write-Host ("    localhost -> {0}" -f ($local -join ', '))
    if ($local -contains '::1') {
        Write-Host "    注意：若客户端只监听 127.0.0.1 而不监听 ::1，用 localhost 会连不上，请直接用 127.0.0.1" -ForegroundColor Yellow
    }

    Write-Host "`n===== UWP 回环限制 =====" -ForegroundColor Cyan
    Write-Host "    商店应用的网络被 WFP 隔离，默认不允许访问 127.0.0.1。" -ForegroundColor DarkGray
    Write-Host "    如果某个商店应用不走代理，需要放行：CheckNetIsolation LoopbackExempt -a -n=<包族名>" -ForegroundColor DarkGray
}

function Set-SystemProxyOn([int]$p) {
    $reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $cfg = Get-Config
    Save-ProxySnapshot
    Set-ItemProperty $reg -Name ProxyServer -Value "$($cfg.host):$p" -ErrorAction Stop
    Set-ItemProperty $reg -Name ProxyOverride -Value $cfg.bypass -ErrorAction Stop
    Set-ItemProperty $reg -Name ProxyEnable -Value 1 -ErrorAction Stop
    try {
        if (-not ('Win32.WinInet3' -as [type])) {
            Add-Type -Namespace Win32 -Name WinInet3 -MemberDefinition '[DllImport("wininet.dll", SetLastError=true)] public static extern bool InternetSetOption(IntPtr h, int o, IntPtr b, int l);'
        }
        [void][Win32.WinInet3]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
        [void][Win32.WinInet3]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)
    } catch { }
}

function Set-SystemProxyOff {
    Save-ProxySnapshot
    $reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    Set-ItemProperty $reg -Name ProxyEnable -Value 0 -ErrorAction Stop
    try {
        if (-not ('Win32.WinInet3' -as [type])) {
            Add-Type -Namespace Win32 -Name WinInet3 -MemberDefinition '[DllImport("wininet.dll", SetLastError=true)] public static extern bool InternetSetOption(IntPtr h, int o, IntPtr b, int l);'
        }
        [void][Win32.WinInet3]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
        [void][Win32.WinInet3]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)
    } catch { }
}

function Invoke-On {
    $cfg = Get-Config
    $p = if ($Port -gt 0) { $Port } else { [int]$cfg.port }
    $r = Invoke-Verify -PortOverride $p -Quiet
    if (-not $r.Capable) {
        Write-Host "`n拒绝开启：$($r.Verdict)" -ForegroundColor Red
        Write-Host "先修好代理，或换一个端口再试。" -ForegroundColor DarkGray
        return
    }
    Set-SystemProxyOn -p $p
    Write-Host "`n已开启系统代理 -> $($cfg.host):$p" -ForegroundColor Green
}

function Invoke-Off {
    Set-SystemProxyOff
    Write-Host "已关闭系统代理" -ForegroundColor Green
}

function Invoke-Save {
    $p = if ($Port -gt 0) { $Port } else { [int](Get-Config).port }
    $r = Invoke-Verify -PortOverride $p -Quiet
    if (-not $r.Ok) {
        Write-Host "验证未通过，不保存：$($r.Verdict)" -ForegroundColor Red
        return
    }
    $cfg = Get-Config
    $cfg.port = $p
    $cfg.lastVerified = (Get-Date).ToString('s')
    Save-Config $cfg
    Write-Host "已保存到 $($script:ConfigPath)（端口 $p）" -ForegroundColor Green
}

if (-not $NoRun) {
switch ($Action) {
    'detect'   { Invoke-Detect }
    'verify'   { [void](Invoke-Verify -PortOverride $Port) }
    'status'   { Invoke-Status }
    'envcheck' { Invoke-EnvCheck }
    'on'       { Invoke-On }
    'off'      { Invoke-Off }
    'save'     { Invoke-Save }
}
}
