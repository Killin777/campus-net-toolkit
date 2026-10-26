<#
    网络优化器 v1.2
    ------------------------------------------------------------
    本地网络体检与调优工具。不是"游戏加速器"（那需要代理线路），
    它做的是本地能真正改善延迟与卡顿的事：

      · 一键体检      适配器 / 网关 / DNS / 抖动 / 丢包 / 代理状态
      · 一键优化      DNS 自动优选 + 路由跃点整理 + 关闭 P2P 上传 + 刷新缓存
      · DNS 优选      实测网关 / 阿里 / 腾讯 / 百度 四家 DNS，自动选最快的
      · 延迟测试      连续采样，输出平均 / 抖动 / 丢包，并画曲线
      · 低延迟模式    临时暂停 Windows 更新与传递优化，减少后台抢占（可恢复）
      · 代理开关      原子化开关 Clash 系统代理，杜绝"代理指向死端口"
      · 网络急救      清代理残留 + 刷 DNS + 续租 IP + 必要时重启网卡

    用法：双击「网络优化器.exe」。首次选择并记住启动权限；源码运行保持当前权限。
#>
[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$Screenshot,
    [switch]$Timeline,
    [switch]$Settings,
    [switch]$Help,
[switch]$WifiList,
    [switch]$AutoClose,
    [string]$DataDirectory = '',
    [string]$Out = "$env:TEMP\netopt.png"
)

$ErrorActionPreference = 'Stop'

# 项目根目录（src 的上一级）：config/ 与 runtime/ 都在这里
$script:ProjRoot = Split-Path -Parent $PSScriptRoot

# 网络列表模块（点源，避免 param 覆盖调用方变量）
$prevNoRun = $NoRun
. (Join-Path $PSScriptRoot 'lib\WifiList.ps1') -NoRun -WifiAction 'show'
$NoRun = $prevNoRun

if ($DataDirectory) { $script:DataRoot = $DataDirectory }

# 共享工具函数（文本宽度、输出、Ping、维护窗口）
. (Join-Path $PSScriptRoot 'lib\Common.ps1')

# ============================ 提权 ============================
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ============================ 主题 ============================
$C = @{
    Bg      = [System.Drawing.Color]::FromArgb(0x17, 0x19, 0x1D)
    Card    = [System.Drawing.Color]::FromArgb(0x22, 0x25, 0x2B)
    Card2   = [System.Drawing.Color]::FromArgb(0x2A, 0x2E, 0x36)
    Btn     = [System.Drawing.Color]::FromArgb(0x2E, 0x33, 0x3C)
    BtnHover= [System.Drawing.Color]::FromArgb(0x3B, 0x42, 0x4E)
    Accent  = [System.Drawing.Color]::FromArgb(0x4F, 0x8C, 0xFF)
    Text    = [System.Drawing.Color]::FromArgb(0xE6, 0xE8, 0xEB)
    Dim     = [System.Drawing.Color]::FromArgb(0x9A, 0xA1, 0xAE)
    Ok      = [System.Drawing.Color]::FromArgb(0x4A, 0xDE, 0x80)
    Warn    = [System.Drawing.Color]::FromArgb(0xFB, 0xBF, 0x24)
    Err     = [System.Drawing.Color]::FromArgb(0xF8, 0x71, 0x71)
}

# DNS 优选候选（国内公共 DNS，按运营商自选）
$script:DnsList = @(
    [pscustomobject]@{ Ip = '223.5.5.5';       Name = '阿里 DNS' },
    [pscustomobject]@{ Ip = '223.6.6.6';       Name = '阿里 DNS 备用' },
    [pscustomobject]@{ Ip = '119.29.29.29';    Name = '腾讯 DNSPod' },
    [pscustomobject]@{ Ip = '182.254.116.116'; Name = '腾讯 DNSPod 备用' },
    [pscustomobject]@{ Ip = '180.76.76.76';    Name = '百度 DNS' },
    [pscustomobject]@{ Ip = '114.114.114.114'; Name = '114DNS' },
    [pscustomobject]@{ Ip = '114.114.115.115'; Name = '114DNS 备用' },
    [pscustomobject]@{ Ip = '117.50.10.10';    Name = 'OneDNS' },
    [pscustomobject]@{ Ip = '1.2.4.8';         Name = 'CNNIC sDNS' },
    [pscustomobject]@{ Ip = '210.2.4.8';       Name = 'CNNIC sDNS 备用' }
)

$script:samples   = New-Object System.Collections.ArrayList
$script:lowLatOn  = $false
$script:savedSvc  = @{}
$script:busy      = $false

# ============================ 基础采集 ============================
function Get-NetInfo {
    $info = [ordered]@{
        SSID = '—'; Band = '—'; Channel = '—'; Signal = '—'; Rssi = '—'
        IP = '—'; Gateway = '—'; DNS = '—'; Adapter = '—'; Link = '—'
        ProxyOn = $false; ProxyPort = $false; ProxyNum = 7897; ProxyKnown = $true; ProxyEndpoint = ''; PacUrl = ''
    }

    $wlan = (netsh wlan show interfaces) -join "`n"
    if ($wlan -match '(?m)^\s*SSID\s*:\s*(.+)$')          { $info.SSID    = $Matches[1].Trim() }
    if ($wlan -match '(?:Band|频带)\s*:\s*(.+)')          { $info.Band    = $Matches[1].Trim() }
    if ($wlan -match '(?:Channel|信道)\s*:\s*(\d+)')      { $info.Channel = $Matches[1] }
    if ($wlan -match '(?:Signal|信号)\s*:\s*(\d+)')       { $info.Signal  = "$($Matches[1])%" }
    if ($wlan -match 'Rssi\s+:\s*(-?\d+)')       { $info.Rssi    = "$($Matches[1]) dBm" }

    # 端口从 proxy-config.json 读，不再写死
    $proxyNum = 7897
    $pcj = Read-ProxySettings
    $parsedPort = 0
    if ([int]::TryParse([string]$pcj.port,[ref]$parsedPort) -and $parsedPort -ge 1 -and $parsedPort -le 65535) { $proxyNum=$parsedPort }
    $proxyStatus = Get-SystemProxyStatus $proxyNum
    $info.ProxyPort = $proxyStatus.Alive
    $info.ProxyNum = $proxyStatus.Port
    $info.ProxyOn = $proxyStatus.Enabled
    $info.ProxyKnown = $proxyStatus.Known
    $info.ProxyEndpoint = $proxyStatus.Endpoint
    $info.PacUrl = $proxyStatus.PacUrl
    # 只认"在线"网卡上的默认路由：断开的网卡会残留旧路由，会把网关/DNS 指到死路
    $upIdx = @(Get-NetAdapter -ErrorAction SilentlyContinue |
               Where-Object { $_.Status -eq 'Up' } | Select-Object -ExpandProperty ifIndex)
    $cands = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
               Where-Object { $upIdx -contains $_.ifIndex -and $_.NextHop -and $_.NextHop -ne '0.0.0.0' } |
               Sort-Object { [long]$_.RouteMetric + [long]$_.InterfaceMetric })

    $picked = $cands | Select-Object -First 1
    if ($picked) {
        $info.Gateway = $picked.NextHop
        $info.Adapter = $picked.InterfaceAlias
    }

    $ip = Get-NetIPAddress -InterfaceAlias $info.Adapter -AddressFamily IPv4 -ErrorAction SilentlyContinue |
          Where-Object { $_.IPAddress -notmatch '^169\.254\.' } | Select-Object -First 1
    if ($ip) { $info.IP = $ip.IPAddress }

    $dns = Get-DnsClientServerAddress -InterfaceAlias $info.Adapter -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if ($dns -and $dns.ServerAddresses) { $info.DNS = ($dns.ServerAddresses -join ', ') }

    $ad = Get-NetAdapter -Name $info.Adapter -ErrorAction SilentlyContinue
    if ($ad) {
        # LinkSpeed 可能返回 "287 Mbps" / "100 Gbps" / "0 bps" 这类字符串，统一解析
        $raw = [string]$ad.LinkSpeed
        $bps = 0.0
        if ($raw -match '([\d\.]+)') { $bps = [double]$Matches[1] }
        if     ($raw -match 'Gbps') { $bps *= 1e9 }
        elseif ($raw -match 'Mbps') { $bps *= 1e6 }
        elseif ($raw -match 'Kbps') { $bps *= 1e3 }
        $info.Link = if ($bps -ge 1e9) { '{0:N1} Gbps' -f ($bps / 1e9) }
                     elseif ($bps -ge 1e6) { '{0:N0} Mbps' -f ($bps / 1e6) }
                     elseif ($bps -gt 0) { '{0:N1} Mbps' -f ($bps / 1e6) }
                     else { '—' }
    }

    return $info
}

function Measure-Latency {
    param(
        [string]$Target,
        [int]$Count = 20,
        [scriptblock]$OnProgress
    )
    $vals = New-Object System.Collections.ArrayList
    for ($i = 1; $i -le $Count; $i++) {
        [void]$vals.Add((Send-PingOnce -Target $Target))
        if ($OnProgress) { & $OnProgress $i $Count }
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 220
    }
    $good = @($vals | Where-Object { $_ -ge 0 })
    $loss = [Math]::Round((($Count - $good.Count) / $Count) * 100, 0)
    if ($good.Count -eq 0) {
        return [pscustomobject]@{ Avg = -1; Jitter = -1; Loss = 100; Max = -1; Samples = @($vals) }
    }
    $avg = ($good | Measure-Object -Average).Average
    $max = ($good | Measure-Object -Maximum).Maximum
    # 抖动 = 相邻采样差值的平均绝对值
    $diffs = @()
    for ($i = 1; $i -lt $good.Count; $i++) { $diffs += [Math]::Abs($good[$i] - $good[$i-1]) }
    $jitter = if ($diffs.Count -gt 0) { ($diffs | Measure-Object -Average).Average } else { 0 }
    return [pscustomobject]@{
        Avg = [Math]::Round($avg, 1)
        Jitter = [Math]::Round($jitter, 1)
        Loss = $loss
        Max = [int]$max
        Samples = @($vals)
    }
}

function Measure-DnsLatency {
    param([string]$Server, [string[]]$Domains, [switch]$Fast)
    # 地址必须是 IP 或域名；空值/占位符会让 Resolve-DnsName 抛"不知道这样的主机"，直接判为不可用
    if ([string]::IsNullOrWhiteSpace($Server) -or $Server -notmatch '^[0-9A-Za-z\.\:\-]+$') { return 9999 }
    if (-not $Domains -or $Domains.Count -eq 0) {
        $Domains = if ($Fast) { @('www.baidu.com', 'www.qq.com') } else { @('www.baidu.com', 'www.qq.com', 'www.zhihu.com') }
    }
    $times = @()
    foreach ($d in $Domains) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $ok = $false
        try {
            if ($Fast) { $null = Resolve-DnsName $d -Server $Server -Type A -DnsOnly -QuickTimeout -ErrorAction Stop }
            else { $null = Resolve-DnsName $d -Server $Server -Type A -DnsOnly -ErrorAction Stop }
            $ok = $true
        } catch { }
        $sw.Stop()
        # 只有成功的查询才计入耗时；失败（即使很快）不能当成"最快"
        if ($ok -and $sw.Elapsed.TotalMilliseconds -lt 3000) { $times += $sw.Elapsed.TotalMilliseconds }
    }
    if ($times.Count -eq 0) { return 9999 }
    return [Math]::Round(($times | Measure-Object -Average).Average, 0)
}

function Set-ProxyState {
    param([bool]$Enable)
    Save-ProxySnapshot
    Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name ProxyEnable -Value ([int]$Enable) -ErrorAction Stop
    Send-ProxySettingsChanged
}

# ============================ 自检 / 截图 ============================
if ($SelfTest) {
    Write-Host '=== 自检 ===' -ForegroundColor Cyan
    $i = Get-NetInfo
    $i.GetEnumerator() | ForEach-Object { '  {0,-9} = {1}' -f $_.Key, $_.Value }
    Write-Host "`n--- DNS 测速 ---"
    foreach ($s in @($i.Gateway, '223.5.5.5', '119.29.29.29', '180.76.76.76')) {
        if (-not $s) { continue }
        '  {0,-16} {1,6} ms' -f $s, (Measure-DnsLatency -Server $s)
    }
    Write-Host "`n--- 延迟采样(12) 目标 $($i.Gateway) ---"
    $m = Measure-Latency -Target $i.Gateway -Count 12
    '  平均 {0}ms  抖动 {1}ms  丢包 {2}%  最大 {3}ms' -f $m.Avg, $m.Jitter, $m.Loss, $m.Max
    '  原始: {0}' -f (($m.Samples | ForEach-Object { if ($_ -lt 0) { 'X' } else { $_ } }) -join ' ')
    return
}

# ============================ UI ============================
$form = New-Object System.Windows.Forms.Form
$appIconPath = Join-Path $script:ProjRoot 'assets\lingzhi.ico'
if (Test-Path -LiteralPath $appIconPath) {
    $form.Icon = New-Object System.Drawing.Icon($appIconPath, 32, 32)
}
$script:AppVersion = [IO.File]::ReadAllText((Join-Path $script:ProjRoot 'VERSION')).Trim()
$form.Text = '网络优化器 v' + $script:AppVersion
$form.Size = New-Object System.Drawing.Size(980, 818)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'Sizable'
$form.MaximizeBox = $true
$form.AutoScroll = $true
$form.AutoScrollMinSize = New-Object Drawing.Size(958,770)
$form.MinimumSize = New-Object Drawing.Size(680,480)
$screenArea = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Size = New-Object Drawing.Size([Math]::Min(980,$screenArea.Width),[Math]::Min(818,$screenArea.Height))
$form.BackColor = $C.Bg
$form.ForeColor = $C.Text
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

# --- 顶部标题 ---
$title = New-Object System.Windows.Forms.Label
$title.Text = '网络优化器'
$title.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 17, [System.Drawing.FontStyle]::Bold)
$title.ForeColor = $C.Text
$title.Location = New-Object System.Drawing.Point(22, 14)
$title.Size = New-Object System.Drawing.Size(300, 34)
$form.Controls.Add($title)

$sub = New-Object System.Windows.Forms.Label
$sub.Text = '实测驱动的本地网络体检与调优 · 不是游戏加速器'
$sub.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$sub.ForeColor = $C.Dim
$sub.Location = New-Object System.Drawing.Point(24, 48)
$sub.Size = New-Object System.Drawing.Size(460, 20)
$form.Controls.Add($sub)

$badge = New-Object System.Windows.Forms.Label
$badge.Text = if ($isAdmin) { '● 管理员' } else { '● 普通权限' }
$badge.ForeColor = if ($isAdmin) { $C.Ok } else { $C.Warn }
$badge.TextAlign = 'MiddleRight'
$badge.Location = New-Object System.Drawing.Point(820, 20)
$badge.Size = New-Object System.Drawing.Size(120, 22)
$form.Controls.Add($badge)
# --- 模式条 ---
$modePanel = New-Object System.Windows.Forms.Panel
$modePanel.Location = New-Object System.Drawing.Point(22, 78)
$modePanel.Size = New-Object System.Drawing.Size(936, 52)
$modePanel.BackColor = $C.Bg
$form.Controls.Add($modePanel)

function New-ModeButton($text, $x, $accent, $width = 182) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Size = New-Object System.Drawing.Size($width, 44)
    $b.Location = New-Object System.Drawing.Point($x, 4)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = if ($accent) { $C.Accent } else { $C.Card2 }
    $b.ForeColor = [System.Drawing.Color]::White
    $b.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
    $b.Cursor = 'Hand'
    $b.Tag = $b.BackColor
    $b.Add_MouseEnter({ $this.BackColor = $C.BtnHover })
    $b.Add_MouseLeave({ $this.BackColor = $this.Tag })
    $modePanel.Controls.Add($b)
    return $b
}

$script:proxyStateLabel = New-Object System.Windows.Forms.Label
$script:proxyStateLabel.Text = '检测中 ...'
$script:proxyStateLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 13, [System.Drawing.FontStyle]::Bold)
$script:proxyStateLabel.ForeColor = $C.Dim
$script:proxyStateLabel.Location = New-Object System.Drawing.Point(4, 1)
$script:proxyStateLabel.Size = New-Object System.Drawing.Size(250, 28)
$modePanel.Controls.Add($script:proxyStateLabel)

$script:proxyStateDetail = New-Object System.Windows.Forms.Label
$script:proxyStateDetail.Text = ''
$script:proxyStateDetail.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
$script:proxyStateDetail.ForeColor = $C.Dim
$script:proxyStateDetail.Location = New-Object System.Drawing.Point(6, 30)
$script:proxyStateDetail.Size = New-Object System.Drawing.Size(360, 18)
$modePanel.Controls.Add($script:proxyStateDetail)

$bProxyOn  = New-ModeButton '开启代理' 380  $true  180
$bProxyOff = New-ModeButton '国内直连' 570  $false 180
$bSettings = New-ModeButton '⚙ 设置'   760  $false 170

# --- 状态卡片 ---
$card = New-Object System.Windows.Forms.Panel
$card.Location = New-Object System.Drawing.Point(22, 142)
$card.Size = New-Object System.Drawing.Size(444, 302)
$card.BackColor = $C.Card
$form.Controls.Add($card)

$cardTitle = New-Object System.Windows.Forms.Label
$cardTitle.Text = '当前网络'
$cardTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$cardTitle.ForeColor = $C.Accent
$cardTitle.Location = New-Object System.Drawing.Point(16, 12)
$cardTitle.Size = New-Object System.Drawing.Size(200, 22)
$card.Controls.Add($cardTitle)

function New-InfoRow {
    param($parent, $y, $key)
    $k = New-Object System.Windows.Forms.Label
    $k.Text = $key
    $k.ForeColor = $C.Dim
    $k.Location = New-Object System.Drawing.Point(16, $y)
    $k.Size = New-Object System.Drawing.Size(74, 20)
    $parent.Controls.Add($k)
    $v = New-Object System.Windows.Forms.Label
    $v.Text = '—'
    $v.ForeColor = $C.Text
    $v.Location = New-Object System.Drawing.Point(94, $y)
    $v.Size = New-Object System.Drawing.Size(336, 20)
    $parent.Controls.Add($v)
    return $v
}

$lbSSID  = New-InfoRow $card 44 '无线'
$lbIP    = New-InfoRow $card 70 '地址'
$lbGW    = New-InfoRow $card 96 '网关'
$lbDNS   = New-InfoRow $card 122 'DNS'
$lbLoss  = New-InfoRow $card 148 '延迟'
$lbSignal= New-InfoRow $card 174 '信号'
$lbSignal.Cursor = 'Hand'
$lbSignal.Add_Click({ try { Invoke-ReconnectWifi } catch { Write-Log ('重新关联失败：' + $_.Exception.Message) 'err' } })
$lbDrop  = New-InfoRow $card 200 '断链'
$lbProxy = New-InfoRow $card 226 '代理'
$lbMode  = New-InfoRow $card 252 '模式'

# --- 按钮区 ---
$btnPanel = New-Object System.Windows.Forms.Panel
$btnPanel.Location = New-Object System.Drawing.Point(478, 142)
$btnPanel.Size = New-Object System.Drawing.Size(464, 302)
$btnPanel.BackColor = $C.Bg
$form.Controls.Add($btnPanel)

function New-ActionButton {
    param($text, $x, $y, $w, $h, $accent = $false)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Size = New-Object System.Drawing.Size($w, $h)
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = if ($accent) { $C.Accent } else { $C.Btn }
    $b.ForeColor = [System.Drawing.Color]::White
    $b.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
    $b.Cursor = 'Hand'
    $b.Tag = $b.BackColor
    $b.Add_MouseEnter({ $this.BackColor = $C.BtnHover })
    $b.Add_MouseLeave({ $this.BackColor = $this.Tag })
    $btnPanel.Controls.Add($b)
    return $b
}

$bCheck   = New-ActionButton '一键体检'      0   0   220 50 $true
$bOpt     = New-ActionButton '校园网体检'      232 0   220 50
$bDns     = New-ActionButton 'DNS 优选'      0   60  220 50
$bLatency = New-ActionButton '延迟测试'      232 60  220 50
$bLowLat  = New-ActionButton '路由守卫  '      0   120 220 50
$bProxy   = New-ActionButton '校园网登录  '      232 120 220 50
$bRescue  = New-ActionButton '网络急救'      0   180 220 50
$bFolder  = New-ActionButton '打开代理软件'  232 180 220 50
$bReport  = New-ActionButton '导出诊断报告'  0   240 220 50
$bRestore = New-ActionButton '还原与备份…'      232 240 220 50

    # 悬停提示
    $tip = New-Object System.Windows.Forms.ToolTip
    $tip.AutoPopDelay = 15000
    $tip.InitialDelay = 350
    $tip.ReshowDelay = 80
    $tip.SetToolTip($bProxyOn,  '开启代理：验证代理可用后开启系统代理（端口/协议/转发/出口五层检查）')
    $tip.SetToolTip($bProxyOff, '国内直连：关闭系统代理、恢复自动 DNS、检查 TUN 与 VPN 是否抢路由')
    $tip.SetToolTip($bSettings, '配置代理客户端路径、混合端口，并测试连通性')
    $tip.SetToolTip($bCheck,    '延迟 / 抖动 / 丢包 / 信号 / 断链统计')
    $tip.SetToolTip($bOpt,      '认证状态 / DNS / IPv6 / MTU / 代理绕过 / 信号，约 15 秒')
    $tip.SetToolTip($bDns,      '实测内网与公共 DNS 的响应速度，选最快的')
    $tip.SetToolTip($bLatency,  '连续采样并绘制曲线，看延迟是否稳定')
    $tip.SetToolTip($bLowLat,   '查虚拟网卡抢占 / TUN 双开 / 端口对内网开放 / 代理残留')
    $tip.SetToolTip($bProxy,    '用默认浏览器打开校园网认证页，账号密码由你在浏览器里输入')
    $tip.SetToolTip($bRescue,   '清代理残留 / 刷 DNS / 续租 IP / 必要时重启网卡')
    $tip.SetToolTip($bFolder,   '启动设置里配置的代理客户端')
    $tip.SetToolTip($bReport,   '生成带断链时间点的文本报告，便于报修')
    $tip.SetToolTip($bRestore,  '从 runtime 备份还原 DNS / 跃点 / 传递优化')
    $tip.SetToolTip($script:proxyStateLabel, '当前代理状态；红=系统代理开着但端口没人监听')

# --- 曲线 ---
$chart = New-Object System.Windows.Forms.Panel
$chart.Location = New-Object System.Drawing.Point(22, 462)
$chart.Size = New-Object System.Drawing.Size(444, 160)
$chart.BackColor = $C.Bg
$form.Controls.Add($chart)

# --- 断链时间线按钮 ---
$bTimeline = New-Object System.Windows.Forms.Button
$bTimeline.Text = '查看断链时间线（近 7 天）'
$bTimeline.Location = New-Object System.Drawing.Point(22, 620)
$bTimeline.Size = New-Object System.Drawing.Size(444, 44)
$bTimeline.FlatStyle = 'Flat'
$bTimeline.FlatAppearance.BorderSize = 0
$bTimeline.BackColor = $C.Btn
$bTimeline.ForeColor = [System.Drawing.Color]::White
$bTimeline.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$bTimeline.Cursor = 'Hand'
$bTimeline.Tag = $C.Btn
$bTimeline.Add_MouseEnter({ $this.BackColor = $C.BtnHover })
$bTimeline.Add_MouseLeave({ $this.BackColor = $this.Tag })
$form.Controls.Add($bTimeline)
$tip.SetToolTip($bTimeline, '近 7 天断链分布，判断是否被 AP 周期性踢下线')

$chart.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear($C.Bg)

    $penGrid = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(0x2C, 0x31, 0x3A)), 1
    for ($i = 1; $i -lt 4; $i++) {
        $y = [int]($chart.Height * $i / 4)
        $g.DrawLine($penGrid, 0, $y, $chart.Width, $y)
    }
    $penGrid.Dispose()

    $vals = @($script:samples | Where-Object { $_ -ge 0 })
    $fTitle = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $bDim = New-Object System.Drawing.SolidBrush($C.Dim)
    $g.DrawString('延迟曲线 (ms)', $fTitle, $bDim, 4, 4)
    if ($vals.Count -lt 2) {
        $g.DrawString('运行「延迟测试」后在此显示曲线', $fTitle, $bDim, 10, 60)
        return
    }
    $maxV = [Math]::Max((($vals | Measure-Object -Maximum).Maximum), 30)
    $penLine = New-Object System.Drawing.Pen ($C.Accent), 2
    $pts = @()
    for ($i = 0; $i -lt $vals.Count; $i++) {
        $x = if ($vals.Count -gt 1) { $chart.Width * $i / ($vals.Count - 1) } else { 0 }
        $y = $chart.Height - (($vals[$i] / $maxV) * ($chart.Height - 22)) - 10
        $pts += New-Object System.Drawing.PointF([single]$x, [single]$y)
    }
    if ($pts.Count -ge 2) { $g.DrawLines($penLine, [System.Drawing.PointF[]]$pts) }
    $penLine.Dispose()
    $fMax = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
    $g.DrawString(("{0} ms" -f [int]$maxV), $fMax, $bDim, ($chart.Width - 44), 4)
})

# --- 日志 ---
$log = New-Object System.Windows.Forms.RichTextBox
$log.Location = New-Object System.Drawing.Point(478, 462)
$log.Size = New-Object System.Drawing.Size(464, 268)
$log.BackColor = $C.Card
$log.ForeColor = $C.Text
$log.BorderStyle = 'None'
$log.Font = New-Object System.Drawing.Font('Consolas', 9)
$log.ReadOnly = $true
$log.ScrollBars = 'Vertical'
$log.DetectUrls = $false
$form.Controls.Add($log)

$foot = New-Object System.Windows.Forms.Label
$foot.Text = '所有改动均可回滚 · 备份见 runtime\network-backup-*.json'
$foot.ForeColor = [System.Drawing.Color]::FromArgb(0x6B, 0x72, 0x80)
$foot.Cursor = 'Hand'
$tip.SetToolTip($foot, '点击打开完整使用说明')
$foot.Add_Click({ Show-HelpWindow })
$foot.Location = New-Object System.Drawing.Point(22, 746)
$foot.Size = New-Object System.Drawing.Size(600, 20)
$form.Controls.Add($foot)

function Write-Log {
    param([string]$Msg, [string]$Level = 'info')
    if (-not $log) { return }
    $col = switch ($Level) { 'ok' { $C.Ok } 'warn' { $C.Warn } 'err' { $C.Err } 'dim' { $C.Dim } default { $C.Text } }
    $log.SelectionStart = $log.TextLength
    $log.SelectionColor = [System.Drawing.Color]::FromArgb(0x6B, 0x72, 0x80)
    $log.AppendText(('[{0}] ' -f (Get-Date).ToString('HH:mm:ss')))
    $log.SelectionColor = $col
    $log.AppendText("$Msg`n")
    $log.SelectionStart = $log.TextLength
    $log.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-Busy {
    param([bool]$On)
    $script:busy=$On
    $form.Cursor=if ($On) { [Windows.Forms.Cursors]::WaitCursor } else { [Windows.Forms.Cursors]::Default }
    foreach ($button in @($bCheck,$bOpt,$bDns,$bLatency,$bLowLat,$bProxy,$bRescue,$bReport,$bRestore,$bFolder,$bTimeline,$bProxyOn,$bProxyOff,$bSettings)) {
        if ($button) { $button.Enabled = -not $On }
    }
    $badge.Enabled = -not $On
    [Windows.Forms.Application]::DoEvents()
}

# ============================ 状态刷新 ============================
function Update-Status {
    $i = Get-NetInfo
    $fam = if ($i.Band -ne '—') { ' · {0} ch{1} · {2}' -f $i.Band, $i.Channel, $i.Rssi } else { '' }
    $lbSSID.Text = if ($i.SSID -ne '—') { "$($i.SSID)$fam" } else { '未连接无线' }
    $lbIP.Text = '{0}   ({1}, {2})' -f $i.IP, $i.Adapter, $i.Link
    $lbGW.Text = $i.Gateway
    if ($i.DNS) {
        $servers = @($i.DNS -split ',\s*' | Where-Object { $_ })
        if ($servers.Count -gt 2) {
            $lbDNS.Text = ($servers[0..1] -join ', ') + (" 等 {0} 个" -f $servers.Count)
        } else {
            $lbDNS.Text = $i.DNS
        }
    } else {
        $lbDNS.Text = '自动（DHCP）'
    }
    $lbProxy.Text = if ($i.ProxyOn -and $i.ProxyPort) { '已开启 → ' + $i.ProxyEndpoint }
                   elseif ($i.ProxyOn -and -not $i.ProxyPort) { '代理目标无法连接（待验证）' }
                   elseif (-not $i.ProxyOn -and $i.ProxyPort) { '代理关闭（内核在跑）' }
                   else { '未开启' }
    $lbProxy.ForeColor = if ($i.ProxyOn -and -not $i.ProxyPort) { $C.Err } elseif ($i.ProxyOn) { $C.Ok } else { $C.Text }
    # 代理三态：绿=已连接且真的生效 / 灰=直连 / 红=异常
    $proxyAlive = [bool]$i.ProxyPort
    $proxyOn    = [bool]$i.ProxyOn
    if ($proxyOn -and -not $i.ProxyKnown) {
        $stateText='代理地址待验证'; $stateColor=$C.Warn; $stateDetail='系统代理已开启，地址格式暂无法识别'
    } elseif ($proxyOn -and $proxyAlive) {
        $stateText='系统代理已开启'; $stateColor=$C.Ok; $stateDetail=$i.ProxyEndpoint + ' · TCP 可连接，出口需另行验证'
    } elseif ($proxyOn) {
        $stateText='代理目标连接失败'; $stateColor=$C.Warn; $stateDetail='仅表示此刻 TCP 未连接；请检查代理软件或网络'
    } elseif ($i.PacUrl) {
        $stateText='PAC 自动代理已配置'; $stateColor=$C.Warn; $stateDetail='手动代理已关闭；PAC、TUN 和 VPN 需单独检查'
    } else {
        $stateText='系统代理已关闭'; $stateColor=$C.Dim; $stateDetail='手动代理已关闭；TUN、VPN 与应用代理需单独检查'
    }
    $lbMode.Text = "状态：$stateText"
    $lbMode.ForeColor = $stateColor
    if ($script:proxyStateLabel) {
        $script:proxyStateLabel.Text = $stateText
        $script:proxyStateLabel.ForeColor = $stateColor
        $script:proxyStateDetail.Text = $stateDetail
    }
    # 开关按钮高亮跟随实际状态：点谁谁亮，而不是固定亮一个
    if ($bProxyOn -and $bProxyOff) {
        if ($proxyOn) {
            $bProxyOn.BackColor  = $C.Accent; $bProxyOn.Tag  = $C.Accent
            $bProxyOff.BackColor = $C.Card2;  $bProxyOff.Tag = $C.Card2
        } else {
            $bProxyOn.BackColor  = $C.Card2;  $bProxyOn.Tag  = $C.Card2
            $bProxyOff.BackColor = $C.Accent; $bProxyOff.Tag = $C.Accent
        }
    }

    # 信号质量判定
    if ($i.Rssi -match '-(\d+)') {
        $dbm = [int]$Matches[1]
        $q = if ($dbm -le 55) { '优秀' } elseif ($dbm -le 65) { '良好' } elseif ($dbm -le 72) { '偏弱' } else { '很差' }
        $hint = if ($dbm -gt 70) { '  · 建议换位置或用有线' } else { '' }
        $weak = ($dbm -gt 65)
        $linkHint = if ($weak) { '  ·  点此重连' } else { '' }
        $lbSignal.Text = ('{0} dBm（{1}）{2}{3}' -f (-$dbm), $q, $(if ($weak) { '' } else { $hint }), $linkHint)
        $lbSignal.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, $(if ($weak) { [System.Drawing.FontStyle]::Underline } else { [System.Drawing.FontStyle]::Regular }))
        $lbSignal.ForeColor = if ($dbm -le 65) { $C.Ok } elseif ($dbm -le 72) { $C.Warn } else { $C.Err }
    } else {
        $lbSignal.Text = '无线信号未知，或当前使用有线'
        $lbSignal.ForeColor = $C.Ok
    }

    # 弱信号持续提示：5 秒刷新一次，连续 6 次（约 30 秒）都弱才提示，且 10 分钟内只提示一次
    if ($i.Rssi -match '-(\d+)') {
        if ([int]$Matches[1] -ge 70) {
            $script:weakHits = [int]$script:weakHits + 1
            $dueHint = (-not $script:weakHintAt) -or (((Get-Date) - $script:weakHintAt).TotalMinutes -ge 10)
            if ($script:weakHits -eq 6 -and $dueHint) {
                $script:weakHintAt = Get-Date
                Write-Log ('信号持续偏弱（-' + [int]$Matches[1] + ' dBm）。点上面带下划线的「信号」一行即可重连' ) 'warn'
            }
        } else { $script:weakHits = 0 }
    }
    # 今日断链次数
    $dc = Get-DisconnectCount
    if ($dc -lt 0) {
        $lbDrop.Text = '—'
    } elseif ($dc -eq 0) {
        $lbDrop.Text = '今日 0 次（稳定）'
    } else {
        $txtDrop = '今日 {0} 次 —— 频繁掉线建议报修' -f $dc
        if ($script:dropCache.Ignored -gt 0) { $txtDrop += ('（已排除 {0} 次工具操作）' -f $script:dropCache.Ignored) }
        $lbDrop.Text = $txtDrop
    }
    $lbDrop.ForeColor = if ($dc -eq 0) { $C.Ok } elseif ($dc -le 3) { $C.Warn } else { $C.Err }
    # 页脚时间戳
$foot.Text = ('最后更新 {0}  ·  点击此处查看使用说明' -f (Get-Date).ToString('HH:mm:ss'))
    return $i
}

function Update-LatencyLabel {
    param($m)
    if ($m.Avg -lt 0) {
        $lbLoss.Text = 'ICMP 全部超时（连通性待确认）'
        $lbLoss.ForeColor = $C.Err
        return
    }
    $text = '平均 {0} ms · 抖动 {1} ms · 丢包 {2}%' -f $m.Avg, $m.Jitter, $m.Loss
    $lbLoss.Text = $text
    if ($m.Loss -gt 0 -or $m.Jitter -gt 30) { $lbLoss.ForeColor = $C.Err }
    elseif ($m.Jitter -gt 12 -or $m.Avg -gt 60) { $lbLoss.ForeColor = $C.Warn }
    else { $lbLoss.ForeColor = $C.Ok }
}

# ============================ 操作 ============================
function Invoke-Check {
    Set-Busy $true
    try {
        Write-Log '开始体检 ...' 'dim'
        $i = Update-Status
        Write-Log ("无线: {0}" -f $lbSSID.Text)
        Write-Log ("地址: {0}" -f $lbIP.Text)
        Write-Log ("网关: {0}    DNS: {1}" -f $i.Gateway, $lbDNS.Text)

        if ($i.Gateway -and $i.Gateway -ne '—') {
            Write-Log '测试到网关的延迟 ...' 'dim'
            $m = Measure-Latency -Target $i.Gateway -Count 14
            $script:samples.Clear()
            foreach ($s in $m.Samples) { [void]$script:samples.Add($s) }
            $chart.Invalidate()
            Update-LatencyLabel $m
            Write-Log ('网关延迟: 平均 {0}ms / 抖动 {1}ms / 丢包 {2}%' -f $m.Avg, $m.Jitter, $m.Loss) $(if ($m.Loss -gt 0 -or $m.Jitter -gt 30) { 'err' } elseif ($m.Jitter -gt 12) { 'warn' } else { 'ok' })
        }

        $pub = '223.5.5.5'
        Write-Log '测试到公网 DNS 的延迟 ...' 'dim'
        $mp = Measure-Latency -Target $pub -Count 8
        if ($mp.Avg -lt 0) {
            Write-Log '公网不可达：ICMP 可能被当前网络屏蔽（不代表断网）' 'warn'
        } else {
            Write-Log ('公网延迟: 平均 {0}ms / 抖动 {1}ms / 丢包 {2}%' -f $mp.Avg, $mp.Jitter, $mp.Loss) $(if ($mp.Loss -gt 0) { 'err' } elseif ($mp.Jitter -gt 30) { 'warn' } else { 'ok' })
        }

        if ($i.ProxyOn -and -not $i.ProxyPort) {
            Write-Log '系统代理的实际目标暂时无法连接，可能影响使用系统代理的应用。请先检查代理软件。' 'warn'
            Write-Log '点「网络急救」可一键清理' 'warn'
        }
        if ($i.Signal -ne '—') {
            $sig = [int]($i.Signal -replace '%', '')
            if ($sig -lt 50) { Write-Log ("无线信号偏弱（{0}），容易掉线" -f $i.Signal) 'warn' }
        }
        # 路由守卫：只报异常项，正常不刷屏
        $rg = Join-Path $PSScriptRoot 'lib\RouteGuard.ps1'
        if (Test-Path $rg) {
            $rgRes = Invoke-ChildCapture -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $rg, 'json')
            try {
                $rep = (($rgRes.Lines -join "`r`n") | ConvertFrom-Json)
                $bad = @($rep.Findings | Where-Object { $_.Severity -ne 'ok' })
                if ($bad.Count -eq 0) {
                    Write-Log '路由守卫：未发现异常' 'ok'
                } else {
                    foreach ($fd in $bad) {
                        Write-Log ("[路由守卫] " + $fd.Title + "：" + $fd.Detail) $fd.Severity
                        if ($fd.Fix) { Write-Log ("      建议：" + $fd.Fix) 'dim' }
                    }
                }
            } catch { Write-Log '路由守卫返回无法解析' 'dim' }
        }
        Write-Log '体检完成' 'ok'
    } catch {
        Write-Log "体检出错：$($_.Exception.Message)" 'err'
    } finally { Set-Busy $false }
}

function Get-CurrentMode {
    $mp = Join-Path $script:DataRoot 'runtime\mode-state.json'
    if (Test-Path $mp) {
        try {
            $m = Get-Content $mp -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($m.activeMode) { return $m.activeMode }
        } catch { }
    }
    return ''
}


function Invoke-DnsOptimize {
    param([switch]$FromOptimize)
    $mode = Get-CurrentMode
    if ($FromOptimize -and $mode -eq 'direct') {
        Write-Log '国内直连模式：跳过 DNS 改动，避免覆盖网络自动下发的 DNS（只刷新缓存）' 'dim'
        ipconfig /flushdns | Out-Null
        return
    }
    $i = Get-NetInfo
    # 候选：网关（若提供 DNS）+ 国内公共 DNS 名单
    $cands = @()
    if ($i.Gateway -and $i.Gateway -ne '—') {
        $cands += [pscustomobject]@{ Ip = $i.Gateway; Name = '网关（运营商下发）' }
    }
    foreach ($d in $script:DnsList) { $cands += $d }

    Write-Log ("开始实测 " + $cands.Count + " 个 DNS（每家 2 次查询，约 5~15 秒）...") 'dim'
    $results = @()
    foreach ($c in $cands) {
        $ms = Measure-DnsLatency -Server $c.Ip -Fast
        $results += [pscustomobject]@{ Server = $c.Ip; Name = $c.Name; Ms = $ms }
        # 边测边出结果，避免十几秒没有反馈
        $isGw = ($c.Ip -eq $i.Gateway)
        if ($ms -ge 9999) {
            $tag = if ($isGw) { '网关不提供 DNS（正常）' } else { '超时 / 不可用' }
            $lvl = if ($isGw) { 'dim' } else { 'err' }
        } else {
            $tag = ("{0,4} ms" -f $ms)
            $lvl = if ($ms -le 30) { 'ok' } elseif ($ms -le 80) { 'dim' } else { 'warn' }
        }
        Write-Log ("     {0,-16} {1,-20} {2}" -f $c.Ip, $c.Name, $tag) $lvl
    }

    $usable = @($results | Where-Object { $_.Ms -lt 9999 } | Sort-Object Ms)
    if ($usable.Count -gt 0) {
        $top = @($usable | Select-Object -First 3)
        Write-Log ("最快：" + (($top | ForEach-Object { "$($_.Name) $($_.Server)（$($_.Ms)ms）" }) -join ' > ')) 'ok'
    }
    $best = $results | Where-Object { $_.Ms -lt 9999 } | Sort-Object Ms | Select-Object -First 1
    if (-not $best) { Write-Log '所有 DNS 都不可用，保持原样' 'err'; return }

    try {
        $bk = New-NetBackup
        Write-Log ("已备份当前网络设置：{0}" -f [System.IO.Path]::GetFileName($bk)) 'dim'
    } catch {
        Write-Log ("备份失败，放弃修改 DNS：$($_.Exception.Message)") 'err'
        return
    }

    $adapter = $i.Adapter
    if (-not $FromOptimize -and [Windows.Forms.MessageBox]::Show('将覆盖当前网卡的 DNS。校园内网可能依赖学校 DNS；已保存备份，继续应用测速结果？','应用 DNS 优选','YesNo','Question') -ne 'Yes') { return }
    if ($best.Server -eq $i.Gateway) {
        Set-DnsClientServerAddress -InterfaceAlias $adapter -ResetServerAddresses -ErrorAction Stop
        Write-Log ("网关 DNS 最快（{0} ms），已改为「自动获取」——换网络也能自适应" -f $best.Ms) 'ok'
    } else {
        $second = $results | Where-Object { $_.Ms -lt 9999 -and $_.Server -ne $best.Server } | Sort-Object Ms | Select-Object -First 1
        $servers = @($best.Server)
        if ($second) { $servers += $second.Server }
        Set-DnsClientServerAddress -InterfaceAlias $adapter -ServerAddresses $servers -ErrorAction Stop
        Write-Log ("已设为静态：{0}（{1} ms）" -f ($servers -join ' / '), $best.Ms) 'ok'
    }
    ipconfig /flushdns | Out-Null
    Write-Log 'DNS 缓存已刷新' 'dim'
    Update-Status | Out-Null
}



function Invoke-LatencyTest {
    Set-Busy $true
    try {
        $i = Get-NetInfo
        $target = if ($i.Gateway -and $i.Gateway -ne '—') { $i.Gateway } else { '223.5.5.5' }
        Write-Log ("延迟测试：{0} × 30 次" -f $target) 'dim'
        $script:samples.Clear()
        $m = Measure-Latency -Target $target -Count 30 -OnProgress {
            param($n, $total)
            if ($n % 5 -eq 0) { Write-Log ("  {0}/{1}" -f $n, $total) 'dim' }
        }
        foreach ($s in $m.Samples) { [void]$script:samples.Add($s) }
        $chart.Invalidate()
        Update-LatencyLabel $m
        Write-Log ('结果：平均 {0}ms · 抖动 {1}ms · 最大 {2}ms · 丢包 {3}%' -f $m.Avg, $m.Jitter, $m.Max, $m.Loss) $(if ($m.Loss -gt 0 -or $m.Jitter -gt 30) { 'err' } elseif ($m.Jitter -gt 12) { 'warn' } else { 'ok' })
        if ($m.Jitter -gt 30) {
            Write-Log '抖动偏大：多半是无线链路或热点拥塞，建议换 5GHz 热点 / 用有线' 'warn'
        }
        Write-Log ('原始采样: ' + (($m.Samples | ForEach-Object { if ($_ -lt 0) { 'X' } else { $_ } }) -join ' ')) 'dim'
    } catch {
        Write-Log "延迟测试出错：$($_.Exception.Message)" 'err'
    } finally { Set-Busy $false }
}



function Invoke-ProxyToggle {
    try {
        $info=Get-NetInfo
        if (-not $info.ProxyOn) { Write-Log '手动系统代理已经关闭；PAC、TUN 和 VPN 请单独检查。' 'dim'; return }
        Set-ProxyState -Enable $false
        Write-Log '手动系统代理已关闭，原值已备份。PAC、TUN、VPN 设置未自动修改。' 'ok'
        Update-Status | Out-Null
    } catch { Write-Log ('关闭代理未完成：'+$_.Exception.Message) 'err' }
}

function Invoke-Rescue {
    if ([Windows.Forms.MessageBox]::Show("将清理无法连接的手动代理、刷新 DNS，并尝试续租当前网卡的 DHCP 地址。需要重启网卡时会另行询问。`n`n继续？",'网络急救','YesNo','Question') -ne 'Yes') { return }
    Set-Busy $true
    try {
        $info=Get-NetInfo
        if ($info.ProxyOn -and $info.ProxyKnown -and -not $info.ProxyPort) { Set-ProxyState -Enable $false; Write-Log '已关闭无法连接的手动代理，原值已备份。' 'ok' }
        ipconfig /flushdns | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "DNS 缓存刷新失败，退出码 $LASTEXITCODE" }
        Write-Log 'DNS 缓存已刷新' 'ok'
        if ($info.Adapter -eq '—') { Write-Log '没有可识别的当前网卡，已跳过续租和重启。' 'warn'; return }
        $address=Get-NetIPAddress -InterfaceAlias $info.Adapter -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.PrefixOrigin -eq 'Dhcp' }
        if ($address) {
            $arguments=@('/renew',$info.Adapter) | ForEach-Object { ConvertTo-WindowsArgument $_ }
            $renew=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\ipconfig.exe') -ArgumentList ($arguments -join ' ') -WindowStyle Hidden -PassThru
            try {
                $watch=[Diagnostics.Stopwatch]::StartNew()
                while (-not $renew.WaitForExit(60)) { [Windows.Forms.Application]::DoEvents(); if ($watch.Elapsed.TotalSeconds -gt 30) { $renew.Kill(); throw 'DHCP 续租超时，请稍后重试' } }
                $renew.WaitForExit()
                if ($renew.ExitCode -ne 0) { throw "DHCP 续租失败，退出码 $($renew.ExitCode)" }
                Write-Log ('已续租当前网卡：'+$info.Adapter) 'ok'
            } finally { $renew.Dispose() }
        } else { Write-Log '当前地址不是 DHCP，已跳过续租。' 'dim' }
        $gatewayReplies=$info.Gateway -ne '—' -and (Send-PingOnce -Target $info.Gateway) -ge 0
        if (-not $gatewayReplies) {
            Write-Log '网关没有回应 ICMP，无法据此判断断网。' 'warn'
            $message='是否重启当前网卡「'+$info.Adapter+'」？会中断该网卡连接，重连时间由系统决定。仅在确有需要时继续。'
            if ([Windows.Forms.MessageBox]::Show($message,'重启当前网卡','YesNo','Warning') -eq 'Yes') {
                Add-IgnoreWindow '网络急救：用户确认重启当前网卡' 40
                Restart-NetAdapter -Name $info.Adapter -ErrorAction Stop
                Write-Log '已执行网卡重启，请等待系统重新连接。' 'ok'
            }
        } else { Write-Log '网关已回应，无需重启网卡。' 'ok' }
        Update-Status | Out-Null
    } catch { Write-Log ('急救未完成：'+$_.Exception.Message) 'err' }
    finally { Set-Busy $false }
}

$script:dropCache   = @{ Time = [datetime]::MinValue; Count = -1; Ignored = 0 }
$script:ignoreCache = @{ Time = [datetime]::MinValue; Windows = @() }

function Get-DisconnectCount {
    # 统计今日"真实"断链：排除本工具自己触发的维护窗口
    if (((Get-Date) - $script:dropCache.Time).TotalSeconds -lt 60) { return $script:dropCache.Count }
    $n = 0; $ig = 0
    try {
        $ev = Get-WinEvent -FilterHashtable @{
            LogName   = 'Microsoft-Windows-WLAN-AutoConfig/Operational'
            StartTime = (Get-Date).Date
            Id        = 11004
        } -ErrorAction Stop
        foreach ($e in $ev) {
            if (Test-IgnoredTime $e.TimeCreated) { $ig++ } else { $n++ }
        }
    } catch { }
    $script:dropCache = @{ Time = (Get-Date); Count = $n; Ignored = $ig }
    return $n
}

function Invoke-ExportReport {
    try {
        Write-Log '正在生成诊断报告 ...' 'dim'
        $i  = Get-NetInfo
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('================ 网络诊断报告 ================')
        [void]$sb.AppendLine(('生成时间 : {0}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')))
        [void]$sb.AppendLine(('主机     : {0}  ({1})' -f $env:COMPUTERNAME, (Get-CimInstance Win32_OperatingSystem).Caption))
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('---------- 链路 ----------')
        [void]$sb.AppendLine(('无线     : {0} / {1} ch{2} / 信号 {3} / RSSI {4}' -f $i.SSID, $i.Band, $i.Channel, $i.Signal, $i.Rssi))
        [void]$sb.AppendLine(('承载网卡 : {0}  速率 {1}' -f $i.Adapter, $i.Link))
        [void]$sb.AppendLine(('IP       : {0}' -f $i.IP))
        [void]$sb.AppendLine(('网关     : {0}' -f $i.Gateway))
        [void]$sb.AppendLine(('DNS      : {0}' -f $i.DNS))
        [void]$sb.AppendLine(('系统代理 : {0}' -f $(if ($i.ProxyOn) { '开启' } else { '关闭' }) + $(if ($i.ProxyPort) { '（内核在运行）' } else { '（内核未运行）' })))
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('---------- 延迟 ----------')
        if ($i.Gateway -and $i.Gateway -ne '—') {
            $m = Measure-Latency -Target $i.Gateway -Count 20
            [void]$sb.AppendLine(('网关 : 平均 {0}ms / 抖动 {1}ms / 最大 {2}ms / 丢包 {3}%' -f $m.Avg, $m.Jitter, $m.Max, $m.Loss))
            [void]$sb.AppendLine(('采样 : {0}' -f (($m.Samples | ForEach-Object { if ($_ -lt 0) { 'X' } else { $_ } }) -join ' ')))
        }
        $mp = Measure-Latency -Target '223.5.5.5' -Count 10
        [void]$sb.AppendLine(('公网 : 平均 {0}ms / 抖动 {1}ms / 丢包 {2}%' -f $mp.Avg, $mp.Jitter, $mp.Loss))
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('---------- 稳定性 ----------')
        [void]$sb.AppendLine(('今日无线断链 : {0} 次' -f (Get-DisconnectCount)))
        $evs = Get-WinEvent -FilterHashtable @{ LogName='Microsoft-Windows-WLAN-AutoConfig/Operational'; StartTime=(Get-Date).AddDays(-1); Id=11004 } -ErrorAction SilentlyContinue
        if ($evs) {
            [void]$sb.AppendLine('近 24h 断链时间点：')
            foreach ($e in ($evs | Sort-Object TimeCreated)) { [void]$sb.AppendLine(('  {0}' -f $e.TimeCreated.ToString('MM-dd HH:mm:ss'))) }
        }
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('---------- 路由 ----------')
        foreach ($r in (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric)) {
            [void]$sb.AppendLine(('  {0,-8} -> {1,-16} 路由度量 {2}' -f $r.InterfaceAlias, $r.NextHop, $r.RouteMetric))
        }
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('提示：把本文件连同断链时间点报给网络中心，便于定位 AP 侧问题。')

        $path = Join-Path ([Environment]::GetFolderPath('Desktop')) ('网络诊断-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.txt')
        [System.IO.File]::WriteAllText($path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
        Write-Log ("报告已导出：$path") 'ok'
        Start-Process notepad.exe $path
    } catch {
        Write-Log ("导出失败：$($_.Exception.Message)") 'err'
    }
}

function Invoke-RestoreBackup {
    if (-not (Test-AdminAccess)) { return }
    $dir = Join-Path $script:DataRoot 'runtime'
    [void][IO.Directory]::CreateDirectory($dir)
    $dialog = New-Object Windows.Forms.OpenFileDialog
    $dialog.InitialDirectory = $dir
    $dialog.Filter = '网络备份 (network-backup-*.json)|network-backup-*.json'
    $dialog.Title = '选择要恢复的备份'
    try {
        if ($dialog.ShowDialog() -ne 'OK') { return }
        if ([Windows.Forms.MessageBox]::Show('将恢复此备份中的 DNS、接口跃点和传递优化设置。继续？', '恢复备份', 'YesNo', 'Question') -ne 'Yes') { return }
        Set-Busy $true
        Restore-NetBackup $dialog.FileName
        Write-Log '备份恢复完成；备份文件仍保留，可再次使用。' 'ok'
        Update-Status | Out-Null
    } catch { Write-Log ('恢复未完成，备份仍保留：' + $_.Exception.Message) 'err' }
    finally { $dialog.Dispose(); Set-Busy $false }
}

function Get-WlanTimeline {
    param([int]$Days = 7)
    $since = (Get-Date).AddDays(-$Days)
    try {
        $ev = Get-WinEvent -FilterHashtable @{
            LogName   = 'Microsoft-Windows-WLAN-AutoConfig/Operational'
            StartTime = $since
            Id        = 11004
        } -ErrorAction Stop
        return @($ev | Sort-Object TimeCreated | ForEach-Object { $_.TimeCreated })
    } catch { return @() }
}

function Get-TimelineStats {
    param([datetime[]]$Times)
    $today = (Get-Date).Date
    $todayCount = @($Times | Where-Object { $_ -ge $today }).Count

    # 间隔 <=120 秒的连续断链归为一次"风暴"
    $clusters = New-Object System.Collections.ArrayList
    $cur = New-Object System.Collections.ArrayList
    $prev = $null
    foreach ($t in $Times) {
        if ($null -ne $prev -and ($t - $prev).TotalSeconds -le 120) {
            [void]$cur.Add($t)
        } else {
            if ($cur.Count -gt 0) { [void]$clusters.Add(@($cur)) }
            $cur = New-Object System.Collections.ArrayList
            [void]$cur.Add($t)
        }
        $prev = $t
    }
    if ($cur.Count -gt 0) { [void]$clusters.Add(@($cur)) }

    $worst = $null
    foreach ($c in $clusters) { if ($null -eq $worst -or $c.Count -gt $worst.Count) { $worst = $c } }

    return [pscustomobject]@{
        Today      = $todayCount
        Total      = $Times.Count
        Clusters   = $clusters.Count
        WorstCount = $(if ($worst) { $worst.Count } else { 0 })
        WorstStart = $(if ($worst) { $worst[0] } else { $null })
        WorstEnd   = $(if ($worst) { $worst[-1] } else { $null })
    }
}

function Show-TimelineWindow {
    $allTimes = Get-WlanTimeline -Days 7
    $times = @($allTimes | Where-Object { -not (Test-IgnoredTime $_) })
    $excluded = @($allTimes).Count - @($times).Count
    $st = Get-TimelineStats -Times $times

    $w = New-Object System.Windows.Forms.Form
    $w.Icon = $form.Icon
    $w.Text = '断链时间线'
    $w.Size = New-Object System.Drawing.Size(880, 620)
    $w.StartPosition = 'CenterParent'
    $w.FormBorderStyle = 'FixedSingle'
    $w.MaximizeBox = $false
    $w.BackColor = $C.Bg
    $w.ForeColor = $C.Text
    $w.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

    $h = New-Object System.Windows.Forms.Label
    $h.Text = '断链时间线（近 7 天）'
    $h.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 14, [System.Drawing.FontStyle]::Bold)
    $h.Location = New-Object System.Drawing.Point(20, 14)
    $h.Size = New-Object System.Drawing.Size(420, 30)
    $w.Controls.Add($h)

    $sumText = '今日 {0} 次 · 近 7 天 {1} 次 · 断链风暴 {2} 次' -f $st.Today, $st.Total, $st.Clusters
    if ($excluded -gt 0) { $sumText += (" · 已排除 {0} 次工具操作" -f $excluded) }
    if ($st.WorstCount -ge 3 -and $st.WorstStart) {
        $sumText += (' · 最密集 {0}（{1} 次）' -f $st.WorstStart.ToString('MM-dd HH:mm'), $st.WorstCount)
    }
    $sum = New-Object System.Windows.Forms.Label
    $sum.Text = $sumText
    $sum.ForeColor = if ($st.Today -eq 0) { $C.Ok } elseif ($st.Today -le 3) { $C.Warn } else { $C.Err }
    $sum.Location = New-Object System.Drawing.Point(22, 50)
    $sum.Size = New-Object System.Drawing.Size(820, 20)
    $w.Controls.Add($sum)

    $chartT = New-Object System.Windows.Forms.Label
    $chartT.Text = '近 72 小时分布（每小时断链次数）'
    $chartT.ForeColor = $C.Dim
    $chartT.Location = New-Object System.Drawing.Point(22, 78)
    $chartT.Size = New-Object System.Drawing.Size(400, 18)
    $w.Controls.Add($chartT)

    $cp = New-Object System.Windows.Forms.Panel
    $cp.Location = New-Object System.Drawing.Point(22, 100)
    $cp.Size = New-Object System.Drawing.Size(820, 190)
    $cp.BackColor = $C.Card
    $w.Controls.Add($cp)

    $hours = 72
    $startH = (Get-Date).AddHours(-$hours)
    $buckets = New-Object int[] $hours
    foreach ($t in $times) {
        if ($t -lt $startH) { continue }
        $idx = [int][Math]::Floor(($t - $startH).TotalHours)
        if ($idx -ge 0 -and $idx -lt $hours) { $buckets[$idx]++ }
    }
    $maxB = 1
    foreach ($b in $buckets) { if ($b -gt $maxB) { $maxB = $b } }

    $cp.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $g.Clear($C.Card)
        $barW = [double]$cp.Width / $hours
        for ($i = 0; $i -lt $hours; $i++) {
            $v = $buckets[$i]
            if ($v -le 0) { continue }
            $bh = [int](($v / $maxB) * ($cp.Height - 26))
            $x = [int]($i * $barW)
            $wBar = [Math]::Max(2, [int]($barW - 1))
            $col = if ($v -ge 3) { $C.Err } elseif ($v -eq 2) { $C.Warn } else { $C.Accent }
            $br = New-Object System.Drawing.SolidBrush($col)
            $g.FillRectangle($br, $x, ($cp.Height - 18 - $bh), $wBar, $bh)
            $br.Dispose()
        }
        $f8 = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
        $brD = New-Object System.Drawing.SolidBrush($C.Dim)
        $g.DrawString(($startH.ToString('MM-dd HH:mm')), $f8, $brD, 4, ($cp.Height - 16))
        $g.DrawString('现在', $f8, $brD, ($cp.Width - 34), ($cp.Height - 16))
        $g.DrawString(("峰值 {0} 次/小时" -f $maxB), $f8, $brD, 4, 4)
    })

    $lt = New-Object System.Windows.Forms.Label
    $lt.Text = '每次断链（最近 40 条，含与上次的间隔）'
    $lt.ForeColor = $C.Dim
    $lt.Location = New-Object System.Drawing.Point(22, 300)
    $lt.Size = New-Object System.Drawing.Size(400, 18)
    $w.Controls.Add($lt)

    $lb = New-Object System.Windows.Forms.ListBox
    $lb.Location = New-Object System.Drawing.Point(22, 322)
    $lb.Size = New-Object System.Drawing.Size(820, 230)
    $lb.BackColor = $C.Card
    $lb.ForeColor = $C.Text
    $lb.BorderStyle = 'None'
    $lb.Font = New-Object System.Drawing.Font('Consolas', 9)
    $w.Controls.Add($lb)

    $items = @()
    for ($i = 0; $i -lt $times.Count; $i++) {
        $gap = ''
        if ($i -gt 0) {
            $sec = [int]($times[$i] - $times[$i - 1]).TotalSeconds
            if ($sec -lt 60) { $gap = ('  距上次 {0} 秒' -f $sec) }
            elseif ($sec -lt 3600) { $gap = ('  距上次 {0} 分' -f [int]($sec / 60)) }
            else { $gap = ('  距上次 {0} 小时' -f [int]($sec / 3600)) }
        }
        $items += ('{0}{1}' -f $times[$i].ToString('MM-dd HH:mm:ss'), $gap)
    }
    $items = @($items | Select-Object -Last 40)
    [array]::Reverse($items)
    foreach ($it in $items) { [void]$lb.Items.Add($it) }

    if ($times.Count -eq 0) { [void]$lb.Items.Add('近 7 天没有检测到断链记录（事件日志可能已滚动）') }

    if (-not ('W2.Gdi' -as [type])) {
        Add-Type -Namespace W2 -Name Gdi -MemberDefinition '[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);'
    }
    if ($script:capture) {
        $w.Show()
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 700
        [System.Windows.Forms.Application]::DoEvents()
        $bmp = New-Object System.Drawing.Bitmap($w.Width, $w.Height)
        $gfx = [System.Drawing.Graphics]::FromImage($bmp)
        $hdc = $gfx.GetHdc()
        $ok = [W2.Gdi]::PrintWindow($w.Handle, $hdc, 2)
        $gfx.ReleaseHdc($hdc); $gfx.Dispose()
        $bmp.Save($script:capturePath, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        $w.Close()
        Write-Host "已保存: $($script:capturePath) (PrintWindow=$ok)"
        return
    }
    [void]$w.ShowDialog()
}

function Invoke-ChildCapture {
    param([string[]]$ArgumentList, [int]$TimeoutSeconds = 180)
    $output = Join-Path $env:TEMP ('campus_child_' + [guid]::NewGuid().ToString('N'))
    $errorFile = $output + '.err'
    $process = $null
    try {
        $encoded = ($ArgumentList | ForEach-Object { ConvertTo-WindowsArgument ([string]$_) }) -join ' '
        $process = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $encoded -RedirectStandardOutput $output -RedirectStandardError $errorFile -WindowStyle Hidden -PassThru
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while (-not $process.WaitForExit(60)) {
            [Windows.Forms.Application]::DoEvents()
            if ($watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) { $process.Kill(); throw '操作超时，已停止子进程；请查看备份后重试' }
        }
        $process.WaitForExit()
        $utf8 = New-Object Text.UTF8Encoding($false)
        $lines = @()
        foreach ($file in @($output, $errorFile)) {
            if (Test-Path -LiteralPath $file) { $lines += @((Read-ChildOutput $file) -split "`r?`n") }
        }
        return [pscustomobject]@{ ExitCode=$process.ExitCode; Lines=@($lines | Where-Object { $_ -ne '' }) }
    } finally {
        if ($process) { $process.Dispose() }
        Remove-Item -LiteralPath $output,$errorFile -Force -ErrorAction SilentlyContinue
    }
}
function Get-WirelessAdapter {
    return (Get-NetAdapter -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq 'Up' -and $_.PhysicalMediaType -eq 'Native 802.11' } |
            Select-Object -First 1)
}

function Get-BandPreference {
    $wifi = Get-WirelessAdapter
    if (-not $wifi) { return $null }
    $p = Get-NetAdapterAdvancedProperty -Name $wifi.Name -RegistryKeyword 'RoamingPreferredBandType' -ErrorAction SilentlyContinue
    if (-not $p) { return $null }
    return [int](@($p.RegistryValue)[0])
}

function Set-BandPreference([int]$Value) {
    $wifi = Get-WirelessAdapter
    if (-not $wifi) { throw '没有找到在用的无线网卡' }
    Set-NetAdapterAdvancedProperty -Name $wifi.Name -RegistryKeyword 'RoamingPreferredBandType' -RegistryValue $Value -NoRestart -ErrorAction Stop
}

function Invoke-ReconnectWifi {
    # 断开重连：只能按 SSID 让 Windows 重新选 AP/BSSID，不能指定具体 AP
    $ssid = Get-CurrentWifiSsid
    if ([string]::IsNullOrWhiteSpace($ssid)) {
        Write-Log '当前没有连接无线网络，无法重新关联' 'warn'
        return
    }
    Add-IgnoreWindow '重新关联无线' 30
    Write-Log ("正在重新关联「" + $ssid + "」（Windows 会重新挑选 AP / 频段）...") 'dim'
    & netsh wlan disconnect 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    & netsh wlan connect name="$ssid" ssid="$ssid" 2>&1 | Out-Null
    for ($n = 0; $n -lt 20; $n++) {
        Start-Sleep -Milliseconds 800
        if ((Get-CurrentWifiSsid) -eq $ssid) {
            Start-Sleep -Seconds 2
            Update-Status | Out-Null
            Write-Log ('已重新连接到 ' + $ssid) 'ok'
            return
        }
    }
    Write-Log '重新关联超时，可能不在覆盖范围内' 'err'
}

function Get-CampusConfig {
    # 打包版里"数据目录的导入副本"可能是旧快照（缺 ssid 等新字段），
    # 所以不能取第一个就返回，要把所有候选文件合并，越靠后的优先级越高。
    # 优先级从低到高：程序目录 -> exe 目录 -> 数据目录导入副本 -> 数据目录用户设置
    $paths = New-Object System.Collections.ArrayList
    if ($script:ProjRoot) { [void]$paths.Add((Join-Path $script:ProjRoot 'config\campus-config.json')) }
    if ($env:CAMPUS_NET_LAUNCHER) {
        [void]$paths.Add((Join-Path (Split-Path -Parent $env:CAMPUS_NET_LAUNCHER) 'config\campus-config.json'))
    }
    $roots = @()
    if ($script:DataRoot) { $roots += $script:DataRoot }
    if ($env:CAMPUS_NET_DATA_ROOT) { $roots += $env:CAMPUS_NET_DATA_ROOT }
    foreach ($r in ($roots | Select-Object -Unique)) {
        [void]$paths.Add((Join-Path $r 'runtime\imported-campus-config.json'))
        [void]$paths.Add((Join-Path $r 'config\campus-config.json'))
    }
    $merged = [ordered]@{}
    $found = $false
    foreach ($f in $paths) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        try {
            $j = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($pr in $j.PSObject.Properties) {
                if ($null -ne $pr.Value -and "$($pr.Value)" -ne '') { $merged[$pr.Name] = $pr.Value }
            }
            $found = $true
        } catch { }
    }
    if (-not $found -or -not $merged.Contains('portalUrl')) { return $null }
    return [pscustomobject]$merged
}

function Test-OnCampusNetwork($cfg, $info) {
    # 用配置里的校内网段判断；当前用手机热点时 IP/网关都是 192.168.x，一定不匹配
    $nets = @($cfg.internalNets | Where-Object { $_ })
    if ($nets.Count -eq 0) { return $true }   # 没配网段就不拦，避免误伤
    foreach ($n in $nets) {
        if ($info.IP -like "$n*") { return $true }
        if ($info.Gateway -like "$n*") { return $true }
    }
    return $false
}

function Test-InternetDirect {
    # 绕过系统代理，测"真直连"能不能上网（用于判断是否已通过认证）
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path $curl)) { return $false }
    $code = & $curl --noproxy '*' -s -o NUL -w '%{http_code}' --max-time 5 'http://www.baidu.com' 2>$null
    return ("$code" -match '^(200|30[0-9])$')
}

function Test-PortalReachable([string]$Url) {
    try {
        $u = [Uri]$Url
        $port = if ($u.Port -gt 0) { $u.Port } elseif ($u.Scheme -eq 'https') { 443 } else { 80 }
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($u.Host, $port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(1500)
        if ($ok) { try { $client.EndConnect($iar) } catch { $ok = $false } }
        $client.Close()
        return $ok
    } catch { return $false }
}

function Get-CurrentWifiSsid {
    $w = (netsh wlan show interfaces) -join "`n"
    if ($w -match '(?m)^\s*SSID\s*:\s*(.+)$') { return $Matches[1].Trim() }
    return ''
}

function Test-WifiProfileExists([string]$Ssid) {
    $prof = (netsh wlan show profiles) -join "`n"
    return [bool]($prof -match [regex]::Escape($Ssid))
}

function Test-WifiInRange([string]$Ssid) {
    $nets = (netsh wlan show networks) -join "`n"
    return [bool]($nets -match ('(?m)^\s*SSID\s+\d+\s*:\s*' + [regex]::Escape($Ssid) + '\s*$'))
}

function Add-OpenWifiProfile([string]$Ssid) {
    # 只用开放网络（无密码）的情形：生成最小配置并导入，不涉及任何凭据
    $xml = '<?xml version="1.0"?>' +
           '<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">' +
           '<name>' + $Ssid + '</name>' +
           '<SSIDConfig><SSID><name>' + $Ssid + '</name></SSID></SSIDConfig>' +
           '<connectionType>ESS</connectionType><connectionMode>manual</connectionMode>' +
           '<MSM><security><authEncryption>' +
           '<authentication>open</authentication><encryption>none</encryption><useOneX>false</useOneX>' +
           '</authEncryption></security></MSM></WLANProfile>'

    $tmp = Join-Path $env:TEMP ('wlan-' + [guid]::NewGuid().ToString('N') + '.xml')
    try {
        [IO.File]::WriteAllText($tmp, $xml, (New-Object System.Text.UTF8Encoding($false)))
        $out = & netsh wlan add profile filename="$tmp" user=all 2>&1 | Out-String
        Write-Log ('已为开放网络 ' + $Ssid + ' 创建系统配置') 'dim'
        return [bool]($out -match '已添加|added')
    } catch {
        Write-Log ('创建网络配置失败：' + $_.Exception.Message) 'err'
        return $false
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Connect-CampusWifi([string]$Ssid, [bool]$IsOpen = $false) {
    # 只做"切换到已保存的网络"；开放网络在缺配置时可自动创建，绝不涉及密码
    $current = Get-CurrentWifiSsid
    if ($current -eq $Ssid) {
        Write-Log ("已经连接 " + $Ssid) 'ok'
        return $true
    }

    if (-not (Test-WifiInRange $Ssid)) {
        Write-Log ("当前范围内没有 " + $Ssid + "，你可能不在校园内") 'err'
        return $false
    }

    if (-not (Test-WifiProfileExists $Ssid)) {
        if (-not $IsOpen) {
            Write-Log ("系统里没有 " + $Ssid + " 的已保存配置，无法自动连接；请先手动连一次") 'err'
            return $false
        }
        if (-not (Add-OpenWifiProfile $Ssid)) { return $false }
    }

    Write-Log ("正在从「" + $current + "」切换到「" + $Ssid + "」...") 'dim'
    $out = & netsh wlan connect name="$Ssid" ssid="$Ssid" 2>&1 | Out-String
    if ($out -match '已成功|successfully') { Write-Log '已发出连接请求' 'dim' }

    for ($i = 0; $i -lt 25; $i++) {
        Start-Sleep -Milliseconds 800
        if ((Get-CurrentWifiSsid) -eq $Ssid) {
            Start-Sleep -Seconds 2
            Write-Log ("已连接到 " + $Ssid) 'ok'
            return $true
        }
    }
    Write-Log ("连接 " + $Ssid + " 超时") 'err'
    return $false
}

function Open-CampusLogin {
    $cfg = Get-CampusConfig
    if (-not $cfg) {
        Write-Log '没有找到校园网登录地址' 'warn'
        [void][System.Windows.Forms.MessageBox]::Show(
            "没有找到校园网登录地址。`n`n请在 campus-config.json 的 portalUrl 里填写认证页地址。",
            '校园网登录', 'OK', 'Warning')
        return
    }
    $url = [string]$cfg.portalUrl

    # 1. 先切到校园 WiFi（配置里有 ssid 才做）
    $ssid = [string]$cfg.ssid
    $connected = $true
    if (-not [string]::IsNullOrWhiteSpace($ssid)) {
        $connected = Connect-CampusWifi $ssid ([bool]$cfg.ssidOpen)
        if (-not $connected) {
            $r = [System.Windows.Forms.MessageBox]::Show(
                ("没能连接到 " + $ssid + "。`n`n仍然尝试打开认证页吗？（认证页通常只在校园网内可达）"),
                '校园网登录', 'YesNo', 'Warning')
            if ($r -ne 'Yes') { return }
        }
    }

    # 2. 已在校园网且能直连上网时不需要再认证（只在真的连上校园网时才跳过）
    $onCampusNow = (-not [string]::IsNullOrWhiteSpace($ssid)) -and ((Get-CurrentWifiSsid) -eq $ssid)
    if ($onCampusNow -and (Test-InternetDirect)) {
        Write-Log ('已连接到 ' + $ssid + ' 且能直连上网，无需认证') 'ok'
        return
    }

    # 3. 认证页可达性
    $info = Get-NetInfo
    $reachable = Test-PortalReachable $url
    if (-not $reachable) {
        Write-Log ("认证页 " + $url + " 当前不可达（网络：" + $info.SSID + "，网关 " + $info.Gateway + "）") 'warn'
        $r2 = [System.Windows.Forms.MessageBox]::Show(
            ("认证页 " + $url + " 现在连不上。`n`n当前网络：" + $info.SSID + "（" + $info.Gateway + "）`n`n仍然尝试打开吗？"),
            '校园网登录', 'YesNo', 'Warning')
        if ($r2 -ne 'Yes') { return }
    }

    # 4. 认证页在校内网段，走系统代理一定打不开：先切国内直连
    if ($info.ProxyOn) {
        Write-Log '系统代理开着，认证页走代理会打不开；先切换国内直连' 'warn'
        Invoke-ModeFile 'direct'
        Start-Sleep -Milliseconds 400
    }

    try {
        Start-Process $url
        Write-Log ('已用默认浏览器打开登录页：' + $url) 'ok'
    } catch {
        Write-Log ('调用浏览器失败：' + $_.Exception.Message) 'err'
        try { Start-Process 'explorer.exe' $url } catch { }
    }
}

function Invoke-PortalCheck {
    # 只检测 + 打开登录页；账号密码由用户自己在浏览器输入
    $cp = Join-Path $PSScriptRoot 'lib\CampusPortal.ps1'
    if (-not (Test-Path $cp)) { return }
    $res = Invoke-ChildCapture -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $cp, 'json')
    $st = $null
    try { $st = (($res.Lines -join "`r`n") | ConvertFrom-Json) } catch { return }

    if ($st.Authenticated) {
        Write-Log '校园网：已联网（连通性探测 + HTTPS 实测均通过）' 'ok'
        if ($st.Probe) { Write-Log ('      探测点：' + $st.Probe) 'dim' }
        return
    }

    Write-Log ('校园网：可能需要登录 —— ' + $st.Detail) 'warn'
    if ($st.PortalUrl) { Write-Log ('      登录页：' + $st.PortalUrl) 'dim' }

    # 节流：10 分钟内只提醒一次
    $stateFile = Join-Path $script:DataRoot 'runtime\portal-last.json'
    if (Test-Path $stateFile) {
        try {
            $last = (Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json).last
            if ($last -and ((Get-Date) - [datetime]$last).TotalMinutes -lt 10) { return }
        } catch { }
    }
    $dir = Split-Path -Parent $stateFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [pscustomobject]@{ last = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content $stateFile -Encoding UTF8

    if (-not $st.PortalUrl) { return }
    $r = [System.Windows.Forms.MessageBox]::Show(
        ("检测到可能尚未登录校园网。`n`n" + $st.Detail + "`n`n是否打开登录页面？`n（账号密码请自行输入，浏览器会提示是否记住）"),
        '校园网登录', 'YesNo', 'Question')
    if ($r -eq 'Yes') {
        $portalUri=$null
        if (-not [Uri]::TryCreate([string]$st.PortalUrl,[UriKind]::Absolute,[ref]$portalUri) -or $portalUri.Scheme -notin @('http','https') -or -not $portalUri.Host) { Write-Log '登录页地址无效，仅允许 HTTP/HTTPS 网页。' 'warn'; return }
        Start-Process -FilePath $portalUri.AbsoluteUri
        Write-Log '已打开校园网登录页' 'ok'
    }
}

function Invoke-ModeFile {
    param([string]$act, [switch]$Yes)
    $needsAdmin=$act -in 'direct','game'
    if ($act -eq 'restore') {
        $stateFile=Join-Path $script:DataRoot 'runtime\mode-state.json'
        $state=$null
        if (Test-Path -LiteralPath $stateFile) { try { $state=Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Write-Log '还原记录损坏，请先检查数据目录；原文件已保留。' 'err'; return } }
        $needsAdmin=(Test-Path -LiteralPath (Join-Path $script:DataRoot 'runtime\dns-backup.json')) -or $state.savedPowerPlan -or @($state.savedWifi | Where-Object { $_ }).Count -gt 0 -or @($state.savedServices.PSObject.Properties).Count -gt 0
    }
    if ($needsAdmin -and -not (Test-AdminAccess)) { return }
    $modeScript = Join-Path $PSScriptRoot 'ModeCtl.ps1'
    if (-not (Test-Path $modeScript)) { Write-Log '缺少 ModeCtl.ps1' 'err'; return }
    Set-Busy $true
    try {
        Write-Log ("执行模式：" + $act) 'dim'
        $childArgs = @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$modeScript,$act)
        if ($Yes) { $childArgs += '-Yes' }
        $res = Invoke-ChildCapture -ArgumentList $childArgs
        foreach ($line in $res.Lines) {
            $txt = ([string]$line).TrimEnd()
            if ([string]::IsNullOrWhiteSpace($txt)) { continue }
            $lvl = 'dim'
            if ($txt -match '^\s*×') { $lvl = 'err' }
            elseif ($txt -match '^\s*√') { $lvl = 'ok' }
            elseif ($txt -match '^=====') { $lvl = 'info' }
            Write-Log $txt $lvl
        }
        if ($null -ne $res.ExitCode -and $res.ExitCode -ne 0) {
            $code = [string]$res.ExitCode
            if ($code -eq '1') { Write-Log ('有步骤未完成（退出码 1：还原/关键操作失败），请查看上方结果；备份记录仍保留。') 'warn' }
            else { Write-Log ('有步骤未完成（退出码 ' + $code + '），请查看上方结果；备份记录仍保留。') 'warn' }
        }
        Update-Status | Out-Null
    } catch {
        Write-Log ("执行失败：" + $_.Exception.Message) 'err'
    } finally { Set-Busy $false }
}


function New-DialogButton($form, $text, $x, $y, $width) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size($width, 28)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $C.Btn
    $b.ForeColor = [System.Drawing.Color]::White
    $b.Cursor = 'Hand'
    $b.Tag = $C.Btn
    $b.Add_MouseEnter({ $this.BackColor = $C.BtnHover })
    $b.Add_MouseLeave({ $this.BackColor = $this.Tag })
    $form.Controls.Add($b)
    return $b
}

function Get-NetworkReachability {
    # 只看"有没有默认路由 + 网关通不通"，比 ping 公网更适合校园网（很多学校屏蔽 ICMP 外网）
    $up = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' | Select-Object -ExpandProperty ifIndex)
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
             Where-Object { $up -contains $_.ifIndex -and $_.NextHop -and $_.NextHop -ne '0.0.0.0' } |
             Sort-Object { [int]$_.RouteMetric + [int]$_.InterfaceMetric } | Select-Object -First 1
    if (-not $route) { return [pscustomobject]@{ Up = $false; Gateway = ''; Reason = '没有默认路由' } }
    $gw = [string]$route.NextHop
    $ok = $false
    try {
        $p = New-Object System.Net.NetworkInformation.Ping
        $ok = ($p.Send($gw, 1200).Status -eq 'Success')
        $p.Dispose()
    } catch { $ok = $false }
    return [pscustomobject]@{
        Up      = $ok
        Gateway = $gw
        Reason  = $(if ($ok) { '' } else { "网关 $gw 不可达" })
    }
}

function Add-WifiEvent($Kind, $Seconds) {
    $path = Join-Path $script:DataRoot 'runtime\wifi-events.json'
    $dir = Split-Path -Parent $path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $list = @()
    if (Test-Path $path) {
        try { $list = @(Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $list = @() }
    }
    $list += [pscustomobject]@{ at = (Get-Date).ToString('s'); kind = $Kind; seconds = $Seconds }
    # 只保留最近 500 条
    if ($list.Count -gt 500) { $list = @($list | Select-Object -Last 500) }
    [IO.File]::WriteAllText($path, ($list | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-WifiWatchdog {
    # 断链判定：
    #   连续不可达 >= 10 秒 → 记一次"断链"；< 10 秒自动恢复 → 只记"抖动"
    #   工具自身重连期间记维护窗口，不计入
    if ($script:wifiWatchBusy) { return }
    $script:wifiWatchBusy = $true
    try {
        $reach = Get-NetworkReachability
        if ($reach.Up) {
            if ($script:wifiDownSince) {
                $secs = [int]((Get-Date) - $script:wifiDownSince).TotalSeconds
                if ($secs -ge 10) {
                    Add-WifiEvent '断链' $secs
                    Write-Log ("网络已恢复（中断 $secs 秒，记为断链）") 'warn'
                } else {
                    Add-WifiEvent '抖动' $secs
                    Write-Log ("网络短暂中断 $secs 秒（抖动，不计入断链）") 'dim'
                }
                $script:wifiDownSince = $null
            }
            return
        }

        if (-not $script:wifiDownSince) {
            $script:wifiDownSince = Get-Date
            Write-Log ("检测到断网：" + $reach.Reason) 'warn'
            return
        }

        $downFor = ((Get-Date) - $script:wifiDownSince).TotalSeconds
        if ($downFor -lt 10) { return }

        $list = $null
        try { $list = Read-WifiList } catch { return }
        if (-not $list -or -not $list.autoReconnect) { return }

        $lastTry = $script:wifiLastRetry
        if ($lastTry -and ((Get-Date) - $lastTry).TotalSeconds -lt 60) { return }
        $script:wifiLastRetry = Get-Date

        $order = @(Get-ReconnectOrder $list)
        if ($order.Count -eq 0) { return }

        Add-IgnoreWindow '自动重连' 60
        Write-Log ("已断网 " + [int]$downFor + " 秒，按列表尝试重连 ...") 'warn'
        foreach ($n in $order) {
            if (-not (Test-WifiInRange $n.ssid)) { continue }
            Write-Log ("  尝试 " + $n.ssid) 'dim'
            $ok = Connect-CampusWifi $n.ssid ([bool]$n.campus)
            if ($ok) {
                Write-Log ("  已重连到 " + $n.ssid) 'ok'
                return
            }
        }
        Write-Log '列表里的网络都连不上，等下一轮' 'err'
    } catch {
        # 看门狗自身不能把界面拖垮
    } finally {
        $script:wifiWatchBusy = $false
    }
}

function Show-WifiListWindow {
    $data = Read-WifiList

    $w = New-Object System.Windows.Forms.Form
    $w.Icon = $form.Icon
    $w.Text = '我的网络列表'
    $w.Size = New-Object System.Drawing.Size(800, 580)
    $w.StartPosition = 'CenterParent'
    $w.FormBorderStyle = 'FixedDialog'
    $w.MaximizeBox = $false
    $w.MinimizeBox = $false
    $w.BackColor = $C.Bg
    $w.ForeColor = $C.Text
    $w.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = '断网时按列表顺序尝试重连。校园网条目填认证网址；普通网络依赖 Windows 已保存的密码（本工具不保存密码）。'
    $hint.ForeColor = $C.Dim
    $hint.Location = New-Object System.Drawing.Point(18, 14)
    $hint.Size = New-Object System.Drawing.Size(750, 20)
    $w.Controls.Add($hint)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.Location = New-Object System.Drawing.Point(18, 40)
    $lv.Size = New-Object System.Drawing.Size(750, 320)
    $lv.View = 'Details'
    $lv.FullRowSelect = $true
    $lv.GridLines = $false
    $lv.MultiSelect = $false
    $lv.BackColor = $C.Card
    $lv.ForeColor = $C.Text
    $lv.BorderStyle = 'FixedSingle'
    [void]$lv.Columns.Add('网络名称', 180)
    [void]$lv.Columns.Add('类型', 70)
    [void]$lv.Columns.Add('认证网址 / 密码', 380)
    [void]$lv.Columns.Add('自动重连', 90)
    $w.Controls.Add($lv)

    function Refresh-WifiList {
        $lv.Items.Clear()
        foreach ($n in @($data.networks)) {
            $kind = if ($n.campus) { '校园网' } else { '普通' }
            $detail = if ($n.campus) { [string]$n.portalUrl } else { '系统已保存密码' }
            $item = New-Object System.Windows.Forms.ListViewItem([string]$n.ssid)
            [void]$item.SubItems.Add($kind)
            [void]$item.SubItems.Add($detail)
            [void]$item.SubItems.Add($(if ($n.autoReconnect) { '开' } else { '关' }))
            $item.Tag = $n
            [void]$lv.Items.Add($item)
        }
    }

    $btnAdd    = New-DialogButton $w '添加…'   18  372 100
    $btnEdit   = New-DialogButton $w '编辑…'   128 372 100
    $btnDel    = New-DialogButton $w '删除'    238 372 100
    $btnCampus = New-DialogButton $w '设为校园网' 348 372 120
    $btnNormal = New-DialogButton $w '设为普通'  478 372 110

    $chkAuto = New-Object System.Windows.Forms.CheckBox
    $chkAuto.Text = '断网时自动按列表顺序重连'
    $chkAuto.ForeColor = $C.Text
    $chkAuto.Location = New-Object System.Drawing.Point(18, 414)
    $chkAuto.Size = New-Object System.Drawing.Size(320, 24)
    $chkAuto.FlatStyle = 'Flat'
    $chkAuto.Checked = [bool]$data.autoReconnect
    $w.Controls.Add($chkAuto)

    $btnSave   = New-DialogButton $w '保存'  520 452 110
    $btnSave.BackColor = $C.Accent
    $btnSave.Tag = $C.Accent
    $btnCancel = New-DialogButton $w '取消'  640 452 110

    $syncCampus = {
        # 让「校园网登录」按钮拿到最新配置：把第一条校园网记录写回 campus-config.json
        $campus = Get-CampusFromList $data
        if (-not $campus) { return }
        $cfgPath = Join-Path $script:DataRoot 'config\campus-config.json'
        $doc = [ordered]@{}
        if (Test-Path $cfgPath) {
            try {
                (Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties |
                    ForEach-Object { $doc[$_.Name] = $_.Value }
            } catch { }
        }
        $doc['ssid'] = [string]$campus.ssid
        $doc['portalUrl'] = [string]$campus.portalUrl
        $doc['ssidOpen'] = $true
        $dir = Split-Path -Parent $cfgPath
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Save-ToolkitJson $doc $cfgPath
    }

    $btnAdd.Add_Click({
        $n = Show-WifiEditDialog -Entry $null
        if ($n) { $data.networks = @($data.networks) + $n; Refresh-WifiList }
    })
    $btnEdit.Add_Click({
        if ($lv.SelectedItems.Count -eq 0) { return }
        $old = $lv.SelectedItems[0].Tag
        $n = Show-WifiEditDialog -Entry $old
        if ($n) {
            $idx = [array]::IndexOf(@($data.networks), $old)
            $list = @($data.networks)
            if ($idx -ge 0) { $list[$idx] = $n } else { $list += $n }
            $data.networks = $list
            Refresh-WifiList
        }
    })
    $btnDel.Add_Click({
        if ($lv.SelectedItems.Count -eq 0) { return }
        $old = $lv.SelectedItems[0].Tag
        $data.networks = @(@($data.networks) | Where-Object { $_ -ne $old })
        Refresh-WifiList
    })
    $btnCampus.Add_Click({
        if ($lv.SelectedItems.Count -eq 0) { return }
        $n = $lv.SelectedItems[0].Tag
        $n.campus = $true
        if ([string]::IsNullOrWhiteSpace([string]$n.portalUrl)) {
            $edited = Show-WifiEditDialog -Entry $n
            if ($edited) { $n.portalUrl = $edited.portalUrl }
        }
        Refresh-WifiList
    })
    $btnNormal.Add_Click({
        if ($lv.SelectedItems.Count -eq 0) { return }
        $n = $lv.SelectedItems[0].Tag
        $n.campus = $false
        $n.portalUrl = ''
        Refresh-WifiList
    })

    $btnSave.Add_Click({
        $data.autoReconnect = [bool]$chkAuto.Checked
        try {
            $path = Save-WifiList $data
            & $syncCampus
            Write-Log ("网络列表已保存：{0} 个网络 -> {1}" -f @($data.networks).Count, [IO.Path]::GetFileName($path)) 'ok'
            $w.DialogResult = 'OK'
            $w.Close()
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show("保存失败：$($_.Exception.Message)", '错误')
        }
    })
    $btnCancel.Add_Click({ $w.DialogResult = 'Cancel'; $w.Close() })

    Refresh-WifiList

    if ($script:captureWifiList) {
        $w.Show()
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 600
        [System.Windows.Forms.Application]::DoEvents()
        if (-not ('W2.Gdi' -as [type])) {
            Add-Type -Namespace W2 -Name Gdi -MemberDefinition '[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);'
        }
        $bmp = New-Object System.Drawing.Bitmap($w.Width, $w.Height)
        $gfx = [System.Drawing.Graphics]::FromImage($bmp)
        $hdc = $gfx.GetHdc()
        $ok = [W2.Gdi]::PrintWindow($w.Handle, $hdc, 2)
        $gfx.ReleaseHdc($hdc); $gfx.Dispose()
        $bmp.Save($script:capturePath, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        $w.Close()
        Write-Host "已保存: $($script:capturePath) (PrintWindow=$ok)"
        return
    }

    [void]$w.ShowDialog()
    $w.Dispose()
}

function Show-WifiEditDialog($Entry) {
    $w = New-Object System.Windows.Forms.Form
    $w.Icon = $form.Icon
    $w.Text = if ($Entry) { '编辑网络' } else { '添加网络' }
    $w.Size = New-Object System.Drawing.Size(520, 300)
    $w.StartPosition = 'CenterParent'
    $w.FormBorderStyle = 'FixedDialog'
    $w.MaximizeBox = $false
    $w.MinimizeBox = $false
    $w.BackColor = $C.Bg
    $w.ForeColor = $C.Text
    $w.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

    $l1 = New-Object System.Windows.Forms.Label
    $l1.Text = '网络名称（SSID）'
    $l1.ForeColor = $C.Dim
    $l1.Location = New-Object System.Drawing.Point(18, 18)
    $l1.Size = New-Object System.Drawing.Size(120, 20)
    $w.Controls.Add($l1)

    $txtSsid = New-Object System.Windows.Forms.TextBox
    $txtSsid.Location = New-Object System.Drawing.Point(140, 14)
    $txtSsid.Size = New-Object System.Drawing.Size(330, 26)
    $txtSsid.BackColor = $C.Card
    $txtSsid.ForeColor = $C.Text
    $txtSsid.BorderStyle = 'FixedSingle'
    $w.Controls.Add($txtSsid)

    $chkCampus = New-Object System.Windows.Forms.CheckBox
    $chkCampus.Text = '这是校园网（下方填认证网址，而不是密码）'
    $chkCampus.ForeColor = $C.Text
    $chkCampus.Location = New-Object System.Drawing.Point(140, 50)
    $chkCampus.Size = New-Object System.Drawing.Size(330, 24)
    $chkCampus.FlatStyle = 'Flat'
    $w.Controls.Add($chkCampus)

    $l2 = New-Object System.Windows.Forms.Label
    $l2.Text = '认证网址'
    $l2.ForeColor = $C.Dim
    $l2.Location = New-Object System.Drawing.Point(18, 88)
    $l2.Size = New-Object System.Drawing.Size(120, 20)
    $w.Controls.Add($l2)

    $txtPortal = New-Object System.Windows.Forms.TextBox
    $txtPortal.Location = New-Object System.Drawing.Point(140, 84)
    $txtPortal.Size = New-Object System.Drawing.Size(330, 26)
    $txtPortal.BackColor = $C.Card
    $txtPortal.ForeColor = $C.Text
    $txtPortal.BorderStyle = 'FixedSingle'
    $w.Controls.Add($txtPortal)

    $l3 = New-Object System.Windows.Forms.Label
    $l3.Text = '普通网络不需要填密码：本工具用 Windows 已保存的配置重连。'
    $l3.ForeColor = $C.Dim
    $l3.Location = New-Object System.Drawing.Point(18, 118)
    $l3.Size = New-Object System.Drawing.Size(460, 20)
    $w.Controls.Add($l3)

    $chkReconnect = New-Object System.Windows.Forms.CheckBox
    $chkReconnect.Text = '断网时尝试重连这个网络'
    $chkReconnect.ForeColor = $C.Text
    $chkReconnect.Location = New-Object System.Drawing.Point(140, 146)
    $chkReconnect.Size = New-Object System.Drawing.Size(300, 24)
    $chkReconnect.FlatStyle = 'Flat'
    $chkReconnect.Checked = $true
    $w.Controls.Add($chkReconnect)

    if ($Entry) {
        $txtSsid.Text = [string]$Entry.ssid
        $chkCampus.Checked = [bool]$Entry.campus
        $txtPortal.Text = [string]$Entry.portalUrl
        $chkReconnect.Checked = [bool]$Entry.autoReconnect
    }
    $txtPortal.Enabled = $chkCampus.Checked
    $chkCampus.Add_CheckedChanged({ $txtPortal.Enabled = $chkCampus.Checked })

    $btnOk = New-DialogButton $w '确定' 260 200 100
    $btnOk.BackColor = $C.Accent
    $btnOk.Tag = $C.Accent
    $btnNo = New-DialogButton $w '取消' 370 200 100

    $script:wifiEditResult = $null
    $btnOk.Add_Click({
        $ssid = $txtSsid.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($ssid)) {
            [void][System.Windows.Forms.MessageBox]::Show('网络名称不能为空。', '提示')
            return
        }
        if ($chkCampus.Checked -and [string]::IsNullOrWhiteSpace($txtPortal.Text.Trim())) {
            [void][System.Windows.Forms.MessageBox]::Show('校园网需要填认证网址。', '提示')
            return
        }
        $script:wifiEditResult = New-WifiEntry -Ssid $ssid -Campus ([bool]$chkCampus.Checked) `
            -PortalUrl ([string]$txtPortal.Text.Trim()) -AutoReconnect ([bool]$chkReconnect.Checked)
        $w.DialogResult = 'OK'
        $w.Close()
    })
    $btnNo.Add_Click({ $w.DialogResult = 'Cancel'; $w.Close() })

    [void]$w.ShowDialog()
    $w.Dispose()
    return $script:wifiEditResult
}

function Show-SettingsWindow {
    $cfgFile = Join-Path $script:DataRoot 'runtime\proxy-settings.json'
    $curExe = ''
    $curPort = 7897
    $j = Read-ProxySettings
    if ($j.clientExe) { $curExe = [string]$j.clientExe }
    $parsedPort = 0
    if ([int]::TryParse([string]$j.port,[ref]$parsedPort) -and $parsedPort -ge 1 -and $parsedPort -le 65535) { $curPort=$parsedPort }

    $w = New-Object System.Windows.Forms.Form
    $w.Icon = $form.Icon
    $w.Text = '代理客户端设置'
$w.Size = New-Object System.Drawing.Size(660, 460)
    $w.StartPosition = 'CenterParent'
    $w.FormBorderStyle = 'FixedDialog'
    $w.MaximizeBox = $false
    $w.MinimizeBox = $false
    $w.BackColor = $C.Bg
    $w.ForeColor = $C.Text
    $w.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

    $l1 = New-Object System.Windows.Forms.Label
    $l1.Text = '代理软件主程序（「打开代理软件」按钮会用这个路径）'
    $l1.ForeColor = $C.Dim
    $l1.Location = New-Object System.Drawing.Point(18, 16)
    $l1.Size = New-Object System.Drawing.Size(600, 20)
    $w.Controls.Add($l1)

    $txtExe = New-Object System.Windows.Forms.TextBox
    $txtExe.Location = New-Object System.Drawing.Point(18, 40)
    $txtExe.Size = New-Object System.Drawing.Size(440, 26)
    $txtExe.Text = $curExe
    $txtExe.BackColor = $C.Card
    $txtExe.ForeColor = $C.Text
    $txtExe.BorderStyle = 'FixedSingle'
    $w.Controls.Add($txtExe)


    $btnBrowse = New-DialogButton $w '浏览…' 466 39 82
    $btnAuto   = New-DialogButton $w '自动检测' 552 39 82

    $l2 = New-Object System.Windows.Forms.Label
    $l2.Text = '混合端口'
    $l2.ForeColor = $C.Dim
    $l2.Location = New-Object System.Drawing.Point(18, 88)
    $l2.Size = New-Object System.Drawing.Size(70, 20)
    $w.Controls.Add($l2)

    $txtPort = New-Object System.Windows.Forms.TextBox
    $txtPort.Location = New-Object System.Drawing.Point(92, 84)
    $txtPort.Size = New-Object System.Drawing.Size(80, 26)
    $txtPort.Text = "$curPort"
    $txtPort.BackColor = $C.Card
    $txtPort.ForeColor = $C.Text
    $txtPort.BorderStyle = 'FixedSingle'
    $w.Controls.Add($txtPort)

    $btnTest = New-DialogButton $w '测试连接' 186 83 100

    $txtResult = New-Object System.Windows.Forms.TextBox
    $txtResult.Location = New-Object System.Drawing.Point(18, 122)
$txtResult.Size = New-Object System.Drawing.Size(616, 96)
    $txtResult.Multiline = $true
    $txtResult.ReadOnly = $true
    $txtResult.ScrollBars = 'Vertical'
    $txtResult.BackColor = $C.Card
    $txtResult.ForeColor = $C.Text
    $txtResult.BorderStyle = 'FixedSingle'
    $txtResult.Font = New-Object System.Drawing.Font('Consolas', 9)
    $txtResult.Text = '点「测试连接」验证端口是否真的能当代理用。'
    $w.Controls.Add($txtResult)

    # ---------- 我的网络列表 ----------
    $lWifi = New-Object System.Windows.Forms.Label
    $lWifi.Text = '我的网络列表（断网时按列表顺序重连；校园网条目填认证网址）'
    $lWifi.ForeColor = $C.Accent
    $lWifi.Location = New-Object System.Drawing.Point(18, 234)
    $lWifi.Size = New-Object System.Drawing.Size(600, 20)
    $w.Controls.Add($lWifi)

    $btnWifi = New-DialogButton $w '网络列表…' 18 258 140
    $btnWifi.Add_Click({ Show-WifiListWindow })

    $lWifiSummary = New-Object System.Windows.Forms.Label
    $lWifiSummary.ForeColor = $C.Dim
    $lWifiSummary.Location = New-Object System.Drawing.Point(170, 264)
    $lWifiSummary.Size = New-Object System.Drawing.Size(460, 20)
    $w.Controls.Add($lWifiSummary)

    try {
        $wl = Read-WifiList
        $cnt = @($wl.networks).Count
        $lWifiSummary.Text = ("已配置 {0} 个网络，自动重连：{1}" -f $cnt, $(if ($wl.autoReconnect) { '开' } else { '关' }))
    } catch { $lWifiSummary.Text = '读取网络列表失败' }

    $btnSave   = New-DialogButton $w '保存' 432 380 96
    $btnSave.BackColor = $C.Accent
    $btnSave.Tag = $C.Accent
    $btnCancel = New-DialogButton $w '取消' 540 380 96

    $btnPrivilege = New-DialogButton $w '启动权限…' 18 380 130
    $btnPrivilege.Add_Click({
        if ($env:CAMPUS_NET_LAUNCHER -and (Test-Path -LiteralPath $env:CAMPUS_NET_LAUNCHER)) {
            Start-Process -FilePath $env:CAMPUS_NET_LAUNCHER -ArgumentList '--startup-settings' | Out-Null
        } else { [Windows.Forms.MessageBox]::Show('请通过 EXE 设置下次启动权限。源码运行可右键以管理员打开。','启动权限') | Out-Null }
    })

    $btnBrowse.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = '可执行文件 (*.exe)|*.exe|所有文件 (*.*)|*.*'
        $dlg.Title = '选择代理软件的主程序'
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $txtExe.Text = $dlg.FileName }
    })

    $btnAuto.Add_Click({
        $txtResult.Text = '正在查找已安装的代理客户端 ...'
        [System.Windows.Forms.Application]::DoEvents()
        $sh = New-Object -ComObject WScript.Shell
        $found = @()
        $menus = @("$env:APPDATA\Microsoft\Windows\Start Menu\Programs", "$env:ProgramData\Microsoft\Windows\Start Menu\Programs")
        foreach ($m in $menus) {
            Get-ChildItem $m -Recurse -Filter '*.lnk' -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '(?i)clash|v2ray|sing-?box|flclash|nekoray|throne|mihomo' } |
                ForEach-Object {
                    try {
                        $sc = $sh.CreateShortcut($_.FullName)
                        if ($sc.TargetPath -match '(?i)\.exe$' -and (Test-Path $sc.TargetPath)) { $found += $sc.TargetPath }
                    } catch { }
                }
        }
        $extra = @(
            'D:\Program Files\Clash Verge\clash-verge.exe',
            "$env:ProgramFiles\Clash Verge\clash-verge.exe",
            "$env:LOCALAPPDATA\Programs\Clash Verge\clash-verge.exe",
            "$env:ProgramFiles\v2rayN\v2rayN.exe",
            "$env:ProgramFiles\FlClash\FlClash.exe"
        ) | Where-Object { $_ -and (Test-Path $_) }
        $found = @(@($found) + @($extra) | Select-Object -Unique)
        if ($found.Count -eq 0) {
            $txtResult.Text = '没找到。请点「浏览…」手动选择代理软件的主程序。'
        } elseif ($found.Count -eq 1) {
            $txtExe.Text = $found[0]
            $txtResult.Text = "检测到：`r`n$($found[0])"
        } else {
            $txtExe.Text = $found[0]
            $txtResult.Text = "检测到多个，已填第一个，可手动改：`r`n" + ($found -join "`r`n")
        }
    })

    $btnTest.Add_Click({
        $p = 0
        if (-not [int]::TryParse($txtPort.Text.Trim(), [ref]$p)) { $txtResult.Text = '端口必须是数字。'; return }
        $txtResult.Text = "正在验证 127.0.0.1:$p ..."
        [System.Windows.Forms.Application]::DoEvents()
        $pl = Join-Path $PSScriptRoot 'ProxyCtl.ps1'
        if (-not (Test-Path $pl)) { $txtResult.Text = '缺少 ProxyCtl.ps1'; return }
        $res = Invoke-ChildCapture -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$pl,'verify','-Port',"$p")
        $txtResult.Text = (($res.Lines | ForEach-Object { [string]$_ }) -join "`r`n")
    })

    $btnCancel.Add_Click({ $w.DialogResult = 'Cancel'; $w.Close() })

    $btnSave.Add_Click({
        $exe = $txtExe.Text.Trim()
        if ($exe -and -not (Test-Path $exe)) {
            [System.Windows.Forms.MessageBox]::Show('这个路径不存在，请重新选择。', '路径错误') | Out-Null
            return
        }
        $p = 0
        if (-not [int]::TryParse($txtPort.Text.Trim(), [ref]$p) -or $p -lt 1 -or $p -gt 65535) {
            [System.Windows.Forms.MessageBox]::Show('端口必须是 1-65535 之间的数字。', '端口错误') | Out-Null
            return
        }
        $ht = [ordered]@{}
        if (Test-Path $cfgFile) {
            try {
                $j = Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
                $j.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
            } catch { }
        }
        if (-not $ht['host']) { $ht['host'] = '127.0.0.1' }
        $ht['clientExe'] = $exe
        $ht['port'] = $p
        try {
            $cfgDir = Split-Path -Parent $cfgFile
            if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null }
            Save-ToolkitJson $ht $cfgFile
            $tail = if ($exe) { "，客户端 " + [System.IO.Path]::GetFileName($exe) } else { '，未设置客户端' }
            Write-Log ("设置已保存：端口 $p$tail") 'ok'
            Update-Status | Out-Null
            $w.DialogResult = 'OK'
            $w.Close()
        } catch {
            [System.Windows.Forms.MessageBox]::Show("保存失败：$($_.Exception.Message)", '错误') | Out-Null
        }
    })

    if ($script:captureSettings) {
        # -Settings 冒烟/截图模式：渲染后存图并退出，不能停在 ShowDialog 等用户点关闭
        $w.Show()
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 700
        [System.Windows.Forms.Application]::DoEvents()
        if (-not ('W2.Gdi' -as [type])) {
            Add-Type -Namespace W2 -Name Gdi -MemberDefinition '[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);'
        }
        $bmp = New-Object System.Drawing.Bitmap($w.Width, $w.Height)
        $gfx = [System.Drawing.Graphics]::FromImage($bmp)
        $hdc = $gfx.GetHdc()
        $ok = [W2.Gdi]::PrintWindow($w.Handle, $hdc, 2)
        $gfx.ReleaseHdc($hdc)
        $gfx.Dispose()
        if (-not $ok) {
            $w.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $w.Width, $w.Height)))
        }
        $bmp.Save($script:capturePath, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        $w.Close()
        $w.Dispose()
        Write-Host "已保存: $($script:capturePath) (PrintWindow=$ok)"
        return
    }

    [void]$w.ShowDialog()
    $w.Dispose()
}

function Invoke-LibCheck {
    param([string]$Script, [string]$Title)
    $path = Join-Path $PSScriptRoot $Script
    if (-not (Test-Path $path)) { Write-Log ("缺少 " + $Script) 'err'; return }
    Set-Busy $true
    try {
        Write-Log ($Title + '（约 10~20 秒）...') 'dim'
        $res = Invoke-ChildCapture -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $path, 'check')
        foreach ($line in $res.Lines) {
            $t = ([string]$line).TrimEnd()
            if ([string]::IsNullOrWhiteSpace($t)) { continue }
            $lvl = 'dim'
            if ($t -match '^\s*×') { $lvl = 'err' }
            elseif ($t -match '^\s*!') { $lvl = 'warn' }
            elseif ($t -match '^\s*√') { $lvl = 'ok' }
            Write-Log $t $lvl
        }
    } catch {
        Write-Log ("执行失败：" + $_.Exception.Message) 'err'
    } finally { Set-Busy $false }
}

function Invoke-CampusCheck { Invoke-LibCheck 'lib\CampusCheck.ps1' '校园网体检' }
function Invoke-RouteGuard  { Invoke-LibCheck 'lib\RouteGuard.ps1'  '路由守卫' }

function Show-HelpWindow {
    $w = New-Object System.Windows.Forms.Form
    $w.Icon = $form.Icon
    $w.Text = '使用说明'
    $w.Size = New-Object System.Drawing.Size(760, 640)
    $w.StartPosition = 'CenterParent'
    $w.BackColor = $C.Bg
    $w.ForeColor = $C.Text
    $w.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

    $tb = New-Object System.Windows.Forms.RichTextBox
    $tb.Dock = 'Fill'
    $tb.ReadOnly = $true
    $tb.BorderStyle = 'None'
    $tb.BackColor = $C.Card
    $tb.ForeColor = $C.Text
    $tb.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $tb.DetectUrls = $false

    $usagePath = Join-Path $script:ProjRoot 'docs\usage.txt'
    $tb.Text = [IO.File]::ReadAllText($usagePath)
    $tb.SelectionStart = 0; $tb.ScrollToCaret()
    $w.Controls.Add($tb)
    if ($script:captureHelp) {
        if (-not ('W2.Gdi' -as [type])) {
            Add-Type -Namespace W2 -Name Gdi -MemberDefinition '[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint f);'
        }
        $w.Show()
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 600
        [System.Windows.Forms.Application]::DoEvents()
        $bmp = New-Object System.Drawing.Bitmap($w.Width, $w.Height)
        $gfx = [System.Drawing.Graphics]::FromImage($bmp)
        $hdc = $gfx.GetHdc()
        [void][W2.Gdi]::PrintWindow($w.Handle, $hdc, 2)
        $gfx.ReleaseHdc($hdc); $gfx.Dispose()
        $bmp.Save($script:capturePath, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        $w.Close()
        Write-Host "已保存: $($script:capturePath)"
        return
    }
    [void]$w.ShowDialog()
}

function Test-AdminAccess {
    if ($isAdmin) { return $true }
    Write-Log '此操作需要管理员权限。请点击窗口右上角的权限标记重新打开，再执行操作。' 'warn'
    [Windows.Forms.MessageBox]::Show('此操作需要管理员权限。点击主窗口右上角「普通权限」可请求管理员授权；体检和查看状态仍可继续。','需要管理员权限') | Out-Null
    return $false
}
$badge.Cursor = 'Hand'
$badge.Add_Click({
    if ($isAdmin) { return }
    try {
        if ($env:CAMPUS_NET_LAUNCHER) {
            $ownerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            Start-Process -FilePath $env:CAMPUS_NET_LAUNCHER -ArgumentList ('--admin ' + (ConvertTo-WindowsArgument $ownerSid)) -Verb RunAs | Out-Null
        } else {
            $arguments = @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-DataDirectory',$script:DataRoot)
            Start-Process -FilePath 'powershell.exe' -ArgumentList (($arguments | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' ') -WindowStyle Hidden -Verb RunAs | Out-Null
        }
        $form.Close()
    } catch { Write-Log '管理员启动已取消或失败，当前窗口继续可用。' 'warn' }
})

# ============================ 事件绑定 ============================
$bCheck.Add_Click({ Invoke-Check })
$bOpt.Add_Click({ Invoke-CampusCheck })
$bDns.Add_Click({ if (Test-AdminAccess) { Set-Busy $true; try { Invoke-DnsOptimize } catch { Write-Log $_.Exception.Message 'err' } finally { Set-Busy $false } } })
$bLatency.Add_Click({ Invoke-LatencyTest })
$bLowLat.Add_Click({ Invoke-RouteGuard })
    $bProxy.Add_Click({ Open-CampusLogin })
$bRescue.Add_Click({ if (Test-AdminAccess) { Invoke-Rescue } })
$bReport.Add_Click({ Invoke-ExportReport })
$restoreMenu=New-Object Windows.Forms.ContextMenuStrip
$restoreModeItem=$restoreMenu.Items.Add('还原代理 / 使用模式')
$restoreModeItem.Add_Click({ if ([Windows.Forms.MessageBox]::Show('将按保存的记录还原代理、DNS、服务、电源与无线参数。继续？','还原代理 / 使用模式','YesNo','Question') -eq 'Yes') { Invoke-ModeFile 'restore' } })
$restoreNetworkItem=$restoreMenu.Items.Add('恢复网络备份…')
$restoreNetworkItem.Add_Click({ Invoke-RestoreBackup })
$bRestore.Add_Click({ $restoreMenu.Show($bRestore,(New-Object Drawing.Point(0,$bRestore.Height))) })
$bTimeline.Add_Click({ Show-TimelineWindow })
$bProxyOn.Add_Click({ Invoke-ModeFile 'proxy' })
$bProxyOff.Add_Click({ Invoke-ModeFile 'direct' })
$bSettings.Add_Click({ Show-SettingsWindow })
$bFolder.Add_Click({ Invoke-ModeFile 'open-client' })

# 每 5 秒自动刷新状态（忙碌时跳过），避免窗口开着显示陈旧数据
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$script:residueHits = 0
$timer.Add_Tick({
    if ($script:busy) { return }
    try {
        $snap = Update-Status
        # 连续两次无法连接时只提示，不能根据探测结果自动修改用户代理
        if ($snap.ProxyOn -and $snap.ProxyKnown -and -not $snap.ProxyPort) {
            $script:residueHits++
            if ($script:residueHits -eq 2) {
                Write-Log '系统代理的实际目标连续两次无法连接。请检查代理软件，或主动点击「关闭系统代理」；程序未改动设置。' 'warn'
                Update-Status | Out-Null
            }
        } else {
            $script:residueHits = 0
        }
    } catch { }
})
$form.Add_FormClosing({
    param($sender,$closingArgs)
    if ($script:busy) { $closingArgs.Cancel=$true; Write-Log '请等待当前操作结束后关闭，以免中断状态保存。' 'warn'; return }
    foreach ($activeTimer in @($timer,$script:wifiTimer,$script:portalTimer,$script:autoCloseTimer)) { if ($activeTimer) { $activeTimer.Stop(); $activeTimer.Dispose() } }
    $restoreMenu.Dispose()
})
$timer.Start()

    # 断网看门狗：15 秒检查一次，断链 >=10 秒才计数，恢复后按列表尝试重连
    $script:wifiTimer = New-Object System.Windows.Forms.Timer
    $script:wifiTimer.Interval = 15000
    $script:wifiTimer.Add_Tick({ try { Invoke-WifiWatchdog } catch { } })
    $script:wifiTimer.Start()

$form.Add_Shown({
    try {
        if (-not ('W.Dwm' -as [type])) {
            Add-Type -Namespace W -Name Dwm -MemberDefinition @'
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr h, int a, ref int v, int s);
'@
        }
        $dark = 1
        [void][W.Dwm]::DwmSetWindowAttribute($form.Handle, 20, [ref]$dark, 4)
    } catch { }

    Update-Status | Out-Null
    Write-Log '就绪。建议先点「一键体检」了解现状。' 'dim'
    $i = Get-NetInfo
    if ($i.ProxyOn -and $i.ProxyKnown -and -not $i.ProxyPort) { Write-Log '系统代理目标暂时无法连接；可检查代理软件，或主动关闭手动系统代理。' 'warn' }
    # 焦点给日志框，避免按钮上出现白色焦点框
$log.Focus() | Out-Null

    if ($AutoClose) {
        $script:autoCloseTimer = New-Object System.Windows.Forms.Timer
        $script:autoCloseTimer.Interval = 1200
        $script:autoCloseTimer.Add_Tick({ $script:autoCloseTimer.Stop(); $form.Close() })
        $script:autoCloseTimer.Start()
        return
    }
    if ($Screenshot -or $Settings -or $Timeline -or $Help -or $env:CAMPUS_NET_SMOKE) { return }
    # 不再自动探测校园网：登录交给默认浏览器（点「校园网登录」按钮）
    if ($AutoClose) {
        # 自测用：1.2 秒后自动关窗，用于验证关闭后进程是否退出
        $script:autoCloseTimer = New-Object System.Windows.Forms.Timer
        $script:autoCloseTimer.Interval = 1200
        $script:autoCloseTimer.Add_Tick({ $script:autoCloseTimer.Stop(); $form.Close() })
        $script:autoCloseTimer.Start()
    }
})

if ($Screenshot) {
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    Update-Status | Out-Null
    Write-Log '界面预览' 'dim'
    Write-Log '示例日志行' 'ok'
    Start-Sleep -Milliseconds 700
    [System.Windows.Forms.Application]::DoEvents()

    # 用 PrintWindow 抓真实渲染（DrawToBitmap 画不出 RichTextBox）
    if (-not ('W2.Gdi' -as [type])) {
        Add-Type -Namespace W2 -Name Gdi -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
'@
    }
    $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $gfx.GetHdc()
    $ok = [W2.Gdi]::PrintWindow($form.Handle, $hdc, 2)
    $gfx.ReleaseHdc($hdc)
    $gfx.Dispose()
    if (-not $ok) {
        $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
    }
    $bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $form.Close()
    Write-Host "已保存: $Out (PrintWindow=$ok)"
    return
}

if ($Help) {
    $script:captureHelp = $true
    $script:capturePath = $Out
    Show-HelpWindow
    return
}

if ($WifiList) {
    $script:captureWifiList = $true
    $script:capturePath = $Out
    Show-WifiListWindow
    return
}

if ($Settings) {
    $script:captureSettings = $true
    $script:capturePath = $Out
    Show-SettingsWindow
    return
}

if ($Timeline) {
    $script:capture = $true
    $script:capturePath = $Out
    Show-TimelineWindow
    return
}

[void]$form.ShowDialog()
