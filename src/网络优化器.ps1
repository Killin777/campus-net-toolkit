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
    [switch]$Details,
    [switch]$Repairs,
    [switch]$Tools,
    [ValidateSet('','Online','NeedsAuth','ProxyIssue','Offline','ExternalFailure','Unknown')]
    [string]$PreviewScenario = '',
    [switch]$Settings,
    [switch]$EndpointEditor,
    [switch]$CrashDemo,
    [switch]$Help,
    [switch]$DnsList,
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
. (Join-Path $PSScriptRoot 'lib\NetLayers.ps1')
. (Join-Path $PSScriptRoot 'lib\NetProbe.ps1')
. (Join-Path $PSScriptRoot 'lib\NetworkMonitor.ps1')
. (Join-Path $PSScriptRoot 'lib\LinkHistory.ps1')
# RouteGuard 以函数方式点源：逐项处理要拿到结构化报告对象，不能再走子进程
$prevNoRun = $NoRun
. (Join-Path $PSScriptRoot 'lib\RouteGuard.ps1') -NoRun
$NoRun = $prevNoRun
. (Join-Path $PSScriptRoot 'lib\RouteRepair.ps1')
. (Join-Path $PSScriptRoot 'lib\WiredCheck.ps1')
$ErrorActionPreference = 'Stop'
if ($PreviewScenario -and -not ($Screenshot -or $Details -or $Repairs)) { throw 'PreviewScenario 仅用于截图预览。' }

# ============================ 提权 ============================
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
# 未处理异常交给自己的处理器（记录 + 提供上报入口），不弹系统默认对话框
try { [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException) } catch { }

# ============================ 主题 ============================
$C = @{
    Bg      = [System.Drawing.Color]::FromArgb(0x17, 0x19, 0x1D)
    Card    = [System.Drawing.Color]::FromArgb(0x22, 0x25, 0x2B)
    Card2   = [System.Drawing.Color]::FromArgb(0x2A, 0x2E, 0x36)
    Btn     = [System.Drawing.Color]::FromArgb(0x2E, 0x33, 0x3C)
    BtnHover= [System.Drawing.Color]::FromArgb(0x3B, 0x42, 0x4E)
    Accent  = [System.Drawing.Color]::FromArgb(0x25, 0x63, 0xEB)
    Text    = [System.Drawing.Color]::FromArgb(0xE6, 0xE8, 0xEB)
    Dim     = [System.Drawing.Color]::FromArgb(0x9A, 0xA1, 0xAE)
    Ok      = [System.Drawing.Color]::FromArgb(0x4A, 0xDE, 0x80)
    Warn    = [System.Drawing.Color]::FromArgb(0xFB, 0xBF, 0x24)
    Err     = [System.Drawing.Color]::FromArgb(0xF8, 0x71, 0x71)
}

$script:useDarkTheme = $true
try {
    $themeSettings = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop
    $script:useDarkTheme = $themeSettings.AppsUseLightTheme -eq 0
} catch { $script:useDarkTheme = $true }
if (-not $script:useDarkTheme) {
    $C.Bg=[Drawing.ColorTranslator]::FromHtml('#F4F6F8'); $C.Card=[Drawing.Color]::White
    $C.Card2=[Drawing.ColorTranslator]::FromHtml('#E8EDF3'); $C.Btn=$C.Card
    $C.BtnHover=[Drawing.ColorTranslator]::FromHtml('#E8EDF3'); $C.Text=[Drawing.ColorTranslator]::FromHtml('#182230')
    $C.Dim=[Drawing.ColorTranslator]::FromHtml('#4B5563'); $C.Ok=[Drawing.ColorTranslator]::FromHtml('#166534')
    $C.Warn=[Drawing.ColorTranslator]::FromHtml('#92400E'); $C.Err=[Drawing.ColorTranslator]::FromHtml('#B91C1C')
}

# DNS 优选候选（国内公共 DNS，按运营商自选）
function Get-DnsListDefaults {
    return @(
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
}

function Get-DnsListPath {
    return (Join-Path $script:DataRoot 'config\dns-list.json')
}

function Read-DnsList {
    # 用户自定义优先；没有配置文件时用内置默认（10 家）
    $path = Get-DnsListPath
    if (Test-Path -LiteralPath $path) {
        try {
            $j = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            $list = @()
            foreach ($s in @($j.servers)) {
                if (-not $s -or [string]::IsNullOrWhiteSpace([string]$s.ip)) { continue }
                $nm = if ([string]::IsNullOrWhiteSpace([string]$s.name)) { [string]$s.ip } else { [string]$s.name }
                $list += [pscustomobject]@{ Ip = [string]$s.ip; Name = $nm }
            }
            if ($list.Count -gt 0) { return $list }
        } catch { }
    }
    return (Get-DnsListDefaults)
}

function Save-DnsList($Servers) {
    $path = Get-DnsListPath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $doc = [ordered]@{ servers = @($Servers | ForEach-Object { [ordered]@{ ip = [string]$_.Ip; name = [string]$_.Name } }) }
    [IO.File]::WriteAllText($path, ($doc | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

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
$form = New-Object Windows.Forms.Form
$appIconPath = Join-Path $script:ProjRoot 'assets\lingzhi.ico'
if (Test-Path -LiteralPath $appIconPath) { $form.Icon = New-Object Drawing.Icon($appIconPath,32,32) }
$script:AppVersion = [IO.File]::ReadAllText((Join-Path $script:ProjRoot 'VERSION')).Trim()
$form.Text = '校园网工具箱 v' + $script:AppVersion
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object Drawing.Size(760,580)
$form.AutoScaleMode = 'Dpi'
$screenArea = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Size = New-Object Drawing.Size([Math]::Min(1000,$screenArea.Width),[Math]::Min(760,$screenArea.Height))
$form.BackColor = $C.Bg
$form.ForeColor = $C.Text
$form.Font = New-Object Drawing.Font([Drawing.SystemFonts]::MessageBoxFont.FontFamily,10)

function New-AppButton {
    param($Parent,[string]$Text,[bool]$Primary=$false,[int]$Width=160)
    $button = New-Object Windows.Forms.Button
    $button.Text = $Text
    $button.Size = New-Object Drawing.Size($Width,42)
    $button.Margin = New-Object Windows.Forms.Padding(0,0,12,10)
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderSize = 1
    $button.FlatAppearance.BorderColor = $C.Dim
    $button.BackColor = if ($Primary) { $C.Accent } else { $C.Btn }
    $button.ForeColor = if ($Primary) { [Drawing.Color]::White } else { $C.Text }
    $button.Cursor = 'Hand'
    $Parent.Controls.Add($button)
    return $button
}

function New-TextLabel {
    param($Parent,[string]$Text,[int]$Size=10,[bool]$Bold=$false)
    $label = New-Object Windows.Forms.Label
    $label.AutoSize = $true
    $label.Text = $Text
    $label.ForeColor = $C.Text
    $label.Font = New-Object Drawing.Font($form.Font.FontFamily,$Size,$(if ($Bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }))
    $label.Margin = New-Object Windows.Forms.Padding(0,0,0,10)
    $Parent.Controls.Add($label)
    return $label
}

$rootLayout = New-Object Windows.Forms.TableLayoutPanel
$rootLayout.Dock = 'Fill'
$rootLayout.Padding = New-Object Windows.Forms.Padding(20,16,20,10)
$rootLayout.ColumnCount = 1
$rootLayout.RowCount = 3
[void]$rootLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',76)))
[void]$rootLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
[void]$rootLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',36)))
$form.Controls.Add($rootLayout)
$header = New-Object Windows.Forms.TableLayoutPanel
$header.Dock = 'Fill'
$header.ColumnCount = 3
[void]$header.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)))
[void]$header.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',140)))
[void]$header.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',115)))
$rootLayout.Controls.Add($header,0,0)
$heading = New-Object Windows.Forms.FlowLayoutPanel
$heading.Dock = 'Fill'
$heading.FlowDirection = 'TopDown'
$heading.WrapContents = $false
$header.Controls.Add($heading,0,0)
$title = New-TextLabel $heading '校园网工具箱' 20 $true
$title.Margin = New-Object Windows.Forms.Padding(0,0,0,3)
$sub = New-TextLabel $heading '检测连接、认证和代理，按证据处理问题' 10
$sub.ForeColor = $C.Dim
$badge = New-Object Windows.Forms.LinkLabel
$badge.Text = if ($isAdmin) { '管理员权限' } else { '普通权限 · 提权' }
$badge.Dock = 'Fill'
$badge.TextAlign = 'MiddleCenter'
$badge.LinkColor = $C.Text
$badge.ActiveLinkColor = $C.Accent
$badge.VisitedLinkColor = $C.Text
$header.Controls.Add($badge,1,0)
$bSettings = New-AppButton $header '设置' $false 105
$bSettings.Anchor = 'Right'
$header.SetCellPosition($bSettings,(New-Object Windows.Forms.TableLayoutPanelCellPosition(2,0)))

# 内容宿主用 Panel：TabControl 会在内容区外圈画 1px 边框，Region 裁切盖不住
$pages = New-Object Windows.Forms.Panel
$pages.Dock = 'Fill'
$pages.BackColor = $C.Bg
    # ---- macOS 风格：左侧导航 + 右侧内容（隐藏原生 Tab 头） ----
    $shell = New-Object Windows.Forms.TableLayoutPanel
    $shell.Dock = 'Fill'
    $shell.ColumnCount = 2
    $shell.RowCount = 1
    [void]$shell.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',172)))
    [void]$shell.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)))
    $rootLayout.Controls.Add($shell,0,1)

    $nav = New-Object Windows.Forms.FlowLayoutPanel
    $nav.Dock = 'Fill'
    $nav.FlowDirection = 'TopDown'
    $nav.WrapContents = $false
    $nav.BackColor = $C.Bg
    $nav.Padding = New-Object Windows.Forms.Padding(0,4,12,0)
    $shell.Controls.Add($nav,0,0)

    $shell.Controls.Add($pages,1,0)

    $script:navItems = @()
    $script:navNames = @('当前网络','检测详情','逐项处理','更多工具')
    for ($ni = 0; $ni -lt 4; $ni++) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $script:navNames[$ni]
        $b.Tag = $ni
        $b.Width = 160
        $b.Height = 40
        $b.Margin = New-Object Windows.Forms.Padding(0,0,0,4)
        $b.FlatStyle = 'Flat'
        $b.FlatAppearance.BorderSize = 0
        $b.TextAlign = 'MiddleLeft'
        $b.Padding = New-Object Windows.Forms.Padding(14,0,0,0)
        $b.BackColor = $C.Bg
        $b.ForeColor = $C.Dim
        $b.Cursor = 'Hand'
        $b.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
        $nav.Controls.Add($b)
        $script:navItems += $b
    }

    $script:navIndex = 0
    $script:UpdateNav = {
        for ($k = 0; $k -lt $script:navItems.Count; $k++) {
            $item = $script:navItems[$k]
            if ($k -eq $script:navIndex) {
                $item.BackColor = $C.Card; $item.ForeColor = $C.Text
                $item.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
            } else {
                $item.BackColor = $C.Bg; $item.ForeColor = $C.Dim
                $item.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
            }
            # 圆角 6px：用 Region 裁切，避免自绘
            try {
                $path = New-Object System.Drawing.Drawing2D.GraphicsPath
                $r = 6; $w = $item.Width; $h = $item.Height
                $path.AddArc(0,0,$r*2,$r*2,180,90); $path.AddArc($w-$r*2,0,$r*2,$r*2,270,90)
                $path.AddArc($w-$r*2,$h-$r*2,$r*2,$r*2,0,90); $path.AddArc(0,$h-$r*2,$r*2,$r*2,90,90)
                $path.CloseFigure()
                $item.Region = New-Object System.Drawing.Region($path)
                $path.Dispose()
            } catch { }
        }
    }
    $script:pageViews = @()
    function Show-Page {
        param([int]$Index)
        if ($Index -lt 0 -or $Index -ge $script:pageViews.Count) { return }
        for ($pageIndex = 0; $pageIndex -lt $script:pageViews.Count; $pageIndex++) {
            $script:pageViews[$pageIndex].Visible = ($pageIndex -eq $Index)
        }
        $script:navIndex = $Index
        & $script:UpdateNav
    }
    foreach ($item in $script:navItems) {
        $item.Add_Click({ Show-Page ([int]$this.Tag) })
    }
$homePage = New-Object Windows.Forms.Panel
$detailsPage = New-Object Windows.Forms.Panel
$repairsPage = New-Object Windows.Forms.Panel
$toolsPage = New-Object Windows.Forms.Panel
$script:pageViews = @($homePage,$detailsPage,$repairsPage,$toolsPage)
foreach ($page in $script:pageViews) {
    $page.Dock = 'Fill'
    $page.BackColor = $C.Bg
    $page.ForeColor = $C.Text
    $page.Padding = New-Object Windows.Forms.Padding(20)
    $page.Visible = $false
    $pages.Controls.Add($page)
}
Show-Page 0
$homePage.AutoScroll = $true
$homePanel = New-Object Windows.Forms.TableLayoutPanel
$homePanel.Dock = 'Top'
$homePanel.AutoSize = $true
$homePanel.ColumnCount = 1
$homePanel.GrowStyle = 'AddRows'
$homePage.Controls.Add($homePanel)
$lbConclusion = New-TextLabel $homePanel '正在检测当前网络…' 23 $true
$lbConclusion.Margin = New-Object Windows.Forms.Padding(0,12,0,14)
$lbConclusionDetail = New-TextLabel $homePanel '正在后台读取连接与代理证据，界面可继续使用。' 11
$lbConclusionDetail.Margin = New-Object Windows.Forms.Padding(0,0,0,16)
$lbCheckedAt = New-TextLabel $homePanel '检测证据：尚未取得' 10

    # 五枚状态徽章：● 通过 / ○ 失败 / — 未验证，点击跳到检测详情
    $badgeBar = New-Object Windows.Forms.FlowLayoutPanel
    $badgeBar.AutoSize = $true
    $badgeBar.Dock = 'Fill'
    $badgeBar.Margin = New-Object Windows.Forms.Padding(0,0,0,12)
    $homePanel.Controls.Add($badgeBar)
    $script:badgeLabels = @{}
    foreach ($key in @('链路','DNS','国内','国际','代理')) {
        $bl = New-TextLabel $badgeBar ([string]([char]0x2014) + ' ' + $key) 10
        $bl.Margin = New-Object Windows.Forms.Padding(0,0,18,0)
        $bl.Cursor = 'Hand'
        $bl.Add_Click({ Show-Page 1 })
        $script:badgeLabels[$key] = $bl
    }
$lbCheckedAt.ForeColor = $C.Dim
$primaryActions = New-Object Windows.Forms.FlowLayoutPanel
$primaryActions.AutoSize = $true
$primaryActions.Dock = 'Fill'
$primaryActions.Margin = New-Object Windows.Forms.Padding(0,5,0,16)
$homePanel.Controls.Add($primaryActions)
$bPrimary = New-AppButton $primaryActions '重新检测' $true 190
$bRefresh = New-AppButton $primaryActions '刷新状态' $false 145
$bDetails = New-AppButton $primaryActions '查看检测详情' $false 165
$evidenceBox = New-Object Windows.Forms.FlowLayoutPanel
$evidenceBox.FlowDirection = 'TopDown'
$evidenceBox.WrapContents = $false
$evidenceBox.Dock = 'Fill'
$evidenceBox.AutoSize = $true
$evidenceBox.BackColor = $C.Card
$evidenceBox.Padding = New-Object Windows.Forms.Padding(16)
$evidenceBox.Margin = New-Object Windows.Forms.Padding(0,0,0,14)
$homePanel.Controls.Add($evidenceBox)
$lbConnectionEvidence = New-TextLabel $evidenceBox '连接与认证：等待证据' 11 $true
$lbNetworkEvidence = New-TextLabel $evidenceBox '外网质量：等待检测' 10
$script:proxyStateLabel = New-TextLabel $evidenceBox '系统代理：等待证据' 11 $true
$script:proxyStateDetail = New-TextLabel $evidenceBox '手动代理与外网可用性分别验证。' 10
$script:proxyStateDetail.ForeColor = $C.Dim
$lbHomeHistory = New-TextLabel $homePanel '断链历史：尚未读取' 10
$historyActions = New-Object Windows.Forms.FlowLayoutPanel
$historyActions.AutoSize = $true
$historyActions.Dock = 'Fill'
$homePanel.Controls.Add($historyActions)
$bTimeline = New-AppButton $historyActions '查看断链时间线' $false 190
$bWiredHome = New-AppButton $historyActions '检查有线连接' $false 180

# ---------------- 检测详情：五段证据（链路 / DNS / 国内 / 国际 / 代理） ----------------
$detailScroll = New-Object Windows.Forms.Panel
$detailScroll.Dock = 'Fill'
$detailScroll.AutoScroll = $true
$detailScroll.BackColor = $C.Bg
$detailsPage.Controls.Add($detailScroll)
$detailStack = New-Object Windows.Forms.TableLayoutPanel
$detailStack.Dock = 'Top'
$detailStack.AutoSize = $true
$detailStack.AutoSizeMode = 'GrowAndShrink'
$detailStack.ColumnCount = 1
$detailStack.RowCount = 0
$detailStack.GrowStyle = 'AddRows'
$detailStack.BackColor = $C.Bg
$detailScroll.Controls.Add($detailStack)

$script:detailSections = [ordered]@{}
function New-DetailSection {
    param($Parent,[string]$Key,[string]$Title)
    $section = New-Object Windows.Forms.TableLayoutPanel
    $section.Dock = 'Top'
    $section.AutoSize = $true
    $section.AutoSizeMode = 'GrowAndShrink'
    $section.ColumnCount = 2
    $section.RowCount = 4
    [void]$section.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)))
    [void]$section.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',64)))
    [void]$section.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',24)))
    [void]$section.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',20)))
    [void]$section.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize')))
    [void]$section.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize')))
    $section.Margin = New-Object Windows.Forms.Padding(0)
    $titleLabel = New-Object Windows.Forms.Label
    $titleLabel.AutoSize = $false
    $titleLabel.Dock = 'Fill'
    $titleLabel.TextAlign = 'MiddleLeft'
    $titleLabel.Margin = New-Object Windows.Forms.Padding(0)
    $titleLabel.Font = New-Object Drawing.Font('Microsoft YaHei UI',11,[Drawing.FontStyle]::Bold)
    $section.Controls.Add($titleLabel,0,0)
    $timeLabel = New-Object Windows.Forms.Label
    $timeLabel.AutoSize = $false
    $timeLabel.Dock = 'Fill'
    $timeLabel.TextAlign = 'MiddleRight'
    $timeLabel.Margin = New-Object Windows.Forms.Padding(0)
    $timeLabel.Font = New-Object Drawing.Font('Microsoft YaHei UI',9)
    $timeLabel.ForeColor = [System.Drawing.Color]::FromArgb(0x9A,0xA1,0xAE)
    $section.Controls.Add($timeLabel,1,0)
    $evidenceLabel = New-Object Windows.Forms.Label
    $evidenceLabel.AutoSize = $false
    $evidenceLabel.Dock = 'Fill'
    $evidenceLabel.AutoEllipsis = $true
    $evidenceLabel.TextAlign = 'MiddleLeft'
    $evidenceLabel.Margin = New-Object Windows.Forms.Padding(0)
    $evidenceLabel.Font = New-Object Drawing.Font('Microsoft YaHei UI',10)
    $evidenceLabel.ForeColor = [System.Drawing.Color]::FromArgb(0x9A,0xA1,0xAE)
    $section.SetColumnSpan($evidenceLabel,2)
    $section.Controls.Add($evidenceLabel,0,1)
    $endpointLabel = New-Object Windows.Forms.Label
    $endpointLabel.AutoSize = $true
    $endpointLabel.MaximumSize = New-Object Drawing.Size([Math]::Max(320, $detailScroll.ClientSize.Width - 24), 0)
    $endpointLabel.Margin = New-Object Windows.Forms.Padding(0,4,0,0)
    $endpointLabel.Font = New-Object Drawing.Font('Microsoft YaHei UI',9)
    $endpointLabel.ForeColor = [System.Drawing.Color]::FromArgb(0x9A,0xA1,0xAE)
    $endpointLabel.Visible = $false
    $section.SetColumnSpan($endpointLabel,2)
    $section.Controls.Add($endpointLabel,0,2)
    $suggestLabel = New-Object Windows.Forms.Label
    $suggestLabel.AutoSize = $false
    $suggestLabel.Dock = 'Fill'
    $suggestLabel.AutoEllipsis = $true
    $suggestLabel.TextAlign = 'MiddleLeft'
    $suggestLabel.Margin = New-Object Windows.Forms.Padding(0)
    $suggestLabel.Font = New-Object Drawing.Font('Microsoft YaHei UI',10)
    $suggestLabel.ForeColor = [System.Drawing.Color]::FromArgb(0xFB,0xBF,0x24)
    $suggestLabel.Visible = $false
    $section.SetColumnSpan($suggestLabel,2)
    $section.Controls.Add($suggestLabel,0,3)
    [void]$Parent.Controls.Add($section)
    $expandable = ($Key -eq 'Domestic' -or $Key -eq 'Intl')
    if ($expandable) {
        $titleLabel.Cursor = 'Hand'
        $titleLabel.Add_MouseEnter({ $item = $script:detailSections[$Key]; if ($item) { $item.Hover = $true; Update-DetailSectionHeader $Key } })
        $titleLabel.Add_MouseLeave({ $item = $script:detailSections[$Key]; if ($item) { $item.Hover = $false; Update-DetailSectionHeader $Key } })
        $titleLabel.Add_Click({
            $item = $script:detailSections[$Key]
            if (-not $item) { return }
            $item.Expanded = -not $item.Expanded
            $item.Endpoints.Visible = $item.Expanded
            Update-DetailSectionHeader $Key
        })
    }
    $script:detailSections[$Key] = [pscustomobject]@{
        Title = $titleLabel; Time = $timeLabel; Evidence = $evidenceLabel; Suggest = $suggestLabel
        Endpoints = $endpointLabel; Caption = $Title; Mark = ''
        Expandable = $expandable; Expanded = $false; Hover = $false
    }
}

$sectionDefs = @(
    @{ Key = 'Link';     Title = '链路' }
    @{ Key = 'Dns';      Title = 'DNS' }
    @{ Key = 'Domestic'; Title = '国内' }
    @{ Key = 'Intl';     Title = '国际' }
    @{ Key = 'Proxy';    Title = '代理' }
)
for ($si = 0; $si -lt $sectionDefs.Count; $si++) {
    New-DetailSection $detailStack $sectionDefs[$si].Key $sectionDefs[$si].Title
    if ($si -lt $sectionDefs.Count - 1) {
        $divider = New-Object Windows.Forms.Panel
        $divider.Dock = 'Fill'
        $divider.Height = 1
        $divider.BackColor = [System.Drawing.Color]::FromArgb(0x2A,0x2D,0x34)
        $divider.Margin = New-Object Windows.Forms.Padding(0,10,0,10)
        [void]$detailStack.Controls.Add($divider)
    }
}

function Set-DetailSection {
    param([string]$Key,[string]$State,[string]$Evidence,[string]$At = '',[string]$Suggest = '')
    $entry = $script:detailSections[$Key]
    if (-not $entry) { return }
    if ($State -eq 'Ok') {
        $mark = [string][char]0x25CF
        $entry.Title.ForeColor = [System.Drawing.Color]::FromArgb(52,211,153)
    } elseif ($State -eq 'Partial') {
        $mark = [string][char]0x25D0
        $entry.Title.ForeColor = [System.Drawing.Color]::FromArgb(251,191,36)
    } elseif ($State -eq 'Fail') {
        $mark = [string][char]0x25CB
        $entry.Title.ForeColor = [System.Drawing.Color]::FromArgb(248,113,113)
    } else {
        $mark = [string][char]0x2014
        $entry.Title.ForeColor = [System.Drawing.Color]::FromArgb(156,163,175)
    }
    $entry.Mark = $mark
    Update-DetailSectionHeader $Key
    $entry.Time.Text = $At
    $entry.Evidence.Text = $Evidence
    if ($Suggest) {
        $entry.Suggest.Text = [string][char]0x2192 + ' 建议：' + $Suggest
        $entry.Suggest.Visible = $true
    } else {
        $entry.Suggest.Text = ''
        $entry.Suggest.Visible = $false
    }
}

function Update-DetailSectionHeader {
    param([string]$Key)
    $entry = $script:detailSections[$Key]
    if (-not $entry) { return }
    $mark = if ($entry.Mark) { $entry.Mark } else { [string][char]0x2014 }
    $suffix = ''
    if ($entry.Expandable) {
        if ($entry.Expanded) { $suffix = '  ' + [string][char]0x25B4 }
        elseif ($entry.Hover) { $suffix = '  ' + [string][char]0x25BE }
    }
    $entry.Title.Text = $mark + ' ' + $entry.Caption + $suffix
}

function Set-DetailEndpoints {
    param([string]$Key,$Endpoints)
    $entry = $script:detailSections[$Key]
    if (-not $entry -or -not $entry.Expandable) { return }
    $lines = @()
    foreach ($endpoint in @($Endpoints)) {
        if (-not $endpoint) { continue }
        $mark = if ($endpoint.Ok) { [string][char]0x221A } else { [string][char]0x00D7 }
        $status = ''
        if ($endpoint.Ok) {
            if ([int]$endpoint.Ms -ge 0) { $status = '  ' + [string]$endpoint.Ms + 'ms' }
        } else {
            $status = '  未通过'
        }
        $lines += ($mark + ' ' + [string]$endpoint.Name + $status + "`r`n    " + [string]$endpoint.Url)
    }
    if ($lines.Count -eq 0) { $lines = @('还没有端点结果') }
    $entry.Endpoints.Text = ($lines -join "`r`n")
}

$detailScroll.Add_Resize({
    $wrapWidth = [Math]::Max(320, $detailScroll.ClientSize.Width - 24)
    foreach ($entry in @($script:detailSections.Values)) {
        if ($entry -and $entry.Endpoints) { $entry.Endpoints.MaximumSize = New-Object Drawing.Size($wrapWidth,0) }
    }
})

$repairLayout = New-Object Windows.Forms.TableLayoutPanel
$repairLayout.Dock = 'Fill'
$repairLayout.ColumnCount = 1
$repairLayout.RowCount = 4
[void]$repairLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',68)))
[void]$repairLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',55)))
[void]$repairLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
[void]$repairLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',128)))
$repairsPage.Controls.Add($repairLayout)
    $lbRepairSummary = New-TextLabel $repairLayout '逐项处理只改一处：先写备份，改完读回复检，可单独撤销。点上方「检测可处理项」开始扫描（只读，约 2 秒）；修改接口跃点需要管理员权限。' 11
    $lbRepairSummary.ForeColor = $C.Dim
    $lbRepairSummary.AutoSize = $false
    $lbRepairSummary.Dock = 'Fill'
$repairLayout.SetCellPosition($lbRepairSummary,(New-Object Windows.Forms.TableLayoutPanelCellPosition(0,0)))
$repairActions = New-Object Windows.Forms.FlowLayoutPanel
$repairActions.Dock = 'Fill'
$repairLayout.Controls.Add($repairActions,0,1)
$bScanRepairs = New-AppButton $repairActions '检测可处理项' $false 160
$bApplyRepairs = New-AppButton $repairActions '应用已选项' $true 160
$bApplyRepairs.Enabled = $false
$bApplyRepairs.BackColor = [System.Drawing.Color]::FromArgb(0x2E,0x33,0x3C)
$bApplyRepairs.ForeColor = [System.Drawing.Color]::FromArgb(0x9A,0xA1,0xAE)
$script:repairChecks = @()
$script:repairTexts = @()
$repairRows = New-Object Windows.Forms.TableLayoutPanel
$repairRows.Dock = 'Fill'
$repairRows.ColumnCount = 1
$repairRows.RowCount = 0
$repairRows.GrowStyle = 'AddRows'
$repairRows.AutoScroll = $true
$repairRows.BackColor = $C.Bg
$repairLayout.Controls.Add($repairRows,0,2)
$repairRows.Add_Resize({
    $wrapWidth = [Math]::Max(320, $repairRows.ClientSize.Width - 48)
    foreach ($repairLabel in @($script:repairTexts)) {
        if ($repairLabel) { $repairLabel.MaximumSize = New-Object Drawing.Size($wrapWidth,0) }
    }
})
$repairHistoryBox = New-Object Windows.Forms.TableLayoutPanel
$repairHistoryBox.Dock = 'Fill'
$repairHistoryBox.ColumnCount = 2
[void]$repairHistoryBox.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)))
[void]$repairHistoryBox.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',164)))
$repairLayout.Controls.Add($repairHistoryBox,0,3)
$repairHistoryList = New-Object Windows.Forms.ListBox
$repairHistoryList.Dock = 'Fill'
$repairHistoryList.BackColor = $C.Card
$repairHistoryList.ForeColor = $C.Text
$repairHistoryList.BorderStyle = 'None'
$repairHistoryList.Font = New-Object Drawing.Font('Microsoft YaHei UI',9)
$repairHistoryList.DisplayMember = 'Display'
$historyLeft = New-Object Windows.Forms.TableLayoutPanel
$historyLeft.Dock = 'Fill'
$historyLeft.ColumnCount = 1
$historyLeft.RowCount = 2
[void]$historyLeft.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',20)))
[void]$historyLeft.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
$historyLeft.Margin = New-Object Windows.Forms.Padding(0)
$historyLabel = New-Object Windows.Forms.Label
$historyLabel.Text = '处理记录（选中一条可撤销，只恢复这一项）'
$historyLabel.Dock = 'Fill'
$historyLabel.TextAlign = 'MiddleLeft'
$historyLabel.Margin = New-Object Windows.Forms.Padding(0)
$historyLabel.Font = New-Object Drawing.Font('Microsoft YaHei UI',9)
$historyLabel.ForeColor = [System.Drawing.Color]::FromArgb(0x9A,0xA1,0xAE)
$historyLeft.Controls.Add($historyLabel,0,0)
$historyLeft.Controls.Add($repairHistoryList,0,1)
$repairHistoryBox.Controls.Add($historyLeft,0,0)
$historyButtons = New-Object Windows.Forms.FlowLayoutPanel
$historyButtons.Dock = 'Fill'
$historyButtons.FlowDirection = 'TopDown'
$repairHistoryBox.Controls.Add($historyButtons,1,0)
$bUndoRepair = New-AppButton $historyButtons '撤销所选记录' $false 150
$bViewBackup = New-AppButton $historyButtons '打开记录文件' $false 150
$bUndoRepair.Enabled = $false
$bViewBackup.Enabled = $false
$repairHistoryList.Add_SelectedIndexChanged({ $bUndoRepair.Enabled = $repairHistoryList.SelectedIndex -ge 0 -and -not $script:busy; $bViewBackup.Enabled = $repairHistoryList.SelectedIndex -ge 0 })

$toolsLayout = New-Object Windows.Forms.TableLayoutPanel
$toolsLayout.Dock = 'Fill'
$toolsLayout.ColumnCount = 1
$toolsLayout.RowCount = 3
[void]$toolsLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',40)))
[void]$toolsLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
[void]$toolsLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',110)))
$toolsPage.Controls.Add($toolsLayout)
$toolsHint = New-TextLabel $toolsLayout '按「检查 → 连接 → 修复」分组：检查类只读；写入类动作会先备份并二次确认。' 11
$toolsHint.Dock = 'Fill'
$btnPanel = New-Object Windows.Forms.FlowLayoutPanel
$btnPanel.Dock = 'Fill'
$btnPanel.AutoScroll = $true
$toolsLayout.Controls.Add($btnPanel,0,1)

function New-ToolGroupLabel {
    param([string]$Text)
    $label = New-Object Windows.Forms.Label
    $label.Text = $Text
    $label.AutoSize = $true
    $label.Margin = New-Object Windows.Forms.Padding(0,6,0,0)
    $label.Font = New-Object Drawing.Font('Microsoft YaHei UI',9,[Drawing.FontStyle]::Bold)
    $label.ForeColor = [System.Drawing.Color]::FromArgb(0x9A,0xA1,0xAE)
    $btnPanel.Controls.Add($label)
    $btnPanel.SetFlowBreak($label,$true)
    return $label
}

[void](New-ToolGroupLabel '检查')
$bCheck = New-AppButton $btnPanel '详细连接体检' $false 220
$bOpt = New-AppButton $btnPanel '校园网体检' $false 220
$bDns = New-AppButton $btnPanel 'DNS 优选（备份后应用）' $false 220
$bLatency = New-AppButton $btnPanel '延迟采样测试' $false 220
$bReport = New-AppButton $btnPanel '导出诊断报告' $false 220
$btnPanel.SetFlowBreak($bReport,$true)
[void](New-ToolGroupLabel '连接')
$bSystemProxy = New-AppButton $btnPanel '系统代理 ▾' $false 220
$bProxy = New-AppButton $btnPanel '打开校园网登录页' $false 220
$btnPanel.SetFlowBreak($bProxy,$true)
[void](New-ToolGroupLabel '修复')
$bRescue = New-AppButton $btnPanel '网络急救 ▾' $false 220
$bRestore = New-AppButton $btnPanel '还原与备份 ▾' $false 220

# 结果区：日志与曲线跟按钮同页，点完立刻能看到输出
$outputRow = New-Object Windows.Forms.TableLayoutPanel
$outputRow.Dock = 'Fill'
$outputRow.ColumnCount = 2
$outputRow.RowCount = 1
[void]$outputRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',42)))
[void]$outputRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',58)))
$outputRow.Margin = New-Object Windows.Forms.Padding(0)
$toolsLayout.Controls.Add($outputRow,0,2)

$chart = New-Object Windows.Forms.Panel
$chart.Dock = 'Fill'
$chart.BackColor = $C.Card
$chart.Margin = New-Object Windows.Forms.Padding(0,0,12,0)
$outputRow.Controls.Add($chart,0,0)
$chart.Add_Paint({
    param($sender,$paintArgs)
    $graphics = $paintArgs.Graphics
    $graphics.Clear($C.Card)
    $brush = New-Object Drawing.SolidBrush($C.Dim)
    $graphics.DrawString('延迟采样曲线 · 点「延迟采样测试」后显示', $form.Font, $brush, 8, 6)
    $values = @($script:samples | Where-Object { $_ -ge 0 })
    if ($values.Count -ge 2) {
        $maximum = [Math]::Max(($values | Measure-Object -Maximum).Maximum,30)
        $points = @()
        for ($sampleIndex=0; $sampleIndex -lt $values.Count; $sampleIndex++) {
            $points += New-Object Drawing.PointF([single]($sampleIndex * ($chart.Width-16) / ($values.Count-1)+8),[single]($chart.Height-8-($values[$sampleIndex]/$maximum)*($chart.Height-35)))
        }
        $pen = New-Object Drawing.Pen($C.Accent,2)
        $graphics.DrawLines($pen,[Drawing.PointF[]]$points)
        $pen.Dispose()
    }
    $brush.Dispose()
})

$logGroup = New-Object Windows.Forms.TableLayoutPanel
$logGroup.Dock = 'Fill'
$logGroup.ColumnCount = 1
$logGroup.RowCount = 2
[void]$logGroup.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',20)))
[void]$logGroup.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
$logGroup.Margin = New-Object Windows.Forms.Padding(0)
$outputRow.Controls.Add($logGroup,1,0)
$logTitle = New-Object Windows.Forms.Label
$logTitle.Text = '运行日志'
$logTitle.Dock = 'Fill'
$logTitle.TextAlign = 'MiddleLeft'
$logTitle.Margin = New-Object Windows.Forms.Padding(0)
$logTitle.Font = New-Object Drawing.Font('Microsoft YaHei UI',9,[Drawing.FontStyle]::Bold)
$logTitle.ForeColor = [System.Drawing.Color]::FromArgb(0x9A,0xA1,0xAE)
$logGroup.Controls.Add($logTitle,0,0)
$log = New-Object Windows.Forms.RichTextBox
$log.Dock = 'Fill'
$log.BackColor = $C.Card
$log.ForeColor = $C.Text
$log.Font = New-Object Drawing.Font($form.Font.FontFamily,9)
$log.ReadOnly = $true
$log.BorderStyle = 'None'
$log.DetectUrls = $false
$log.ScrollBars = 'Vertical'
$logGroup.Controls.Add($log,0,1)
$tip = New-Object Windows.Forms.ToolTip
$tip.AutoPopDelay = 15000
$tip.SetToolTip($bSystemProxy,'验证端口、协议、转发与出口后再设系统代理；关闭只动手动代理，保留 PAC 与 DNS。')
$tip.SetToolTip($bRescue,'一键急救在菜单里：清理死代理 / 刷 DNS / 续租；重连 Wi-Fi 与恢复自动 DNS 单独执行。')
$tip.SetToolTip($bDns,'手动测试 DNS 后，确认才应用；应用前保存原值。')
$foot = New-Object Windows.Forms.LinkLabel
$foot.Text = '使用说明 · DNS、接口优先级与无线频段原值见网络备份；逐项处理可单独撤销。'
$foot.Dock = 'Fill'
$foot.LinkColor = $C.Dim
$foot.ActiveLinkColor = $C.Text
$foot.VisitedLinkColor = $C.Dim
$foot.TextAlign = 'MiddleLeft'
$foot.Add_LinkClicked({ Show-HelpWindow })
$rootLayout.Controls.Add($foot,0,2)
$homePage.Add_Resize({
    $width = [Math]::Max(200,$homePage.ClientSize.Width-62)
    foreach ($wrappingLabel in @($lbConclusion,$lbConclusionDetail,$lbCheckedAt,$lbHomeHistory)) { $wrappingLabel.MaximumSize = New-Object Drawing.Size($width,0) }
    foreach ($wrappingLabel in @($lbConnectionEvidence,$lbNetworkEvidence,$script:proxyStateLabel,$script:proxyStateDetail)) { $wrappingLabel.MaximumSize = New-Object Drawing.Size([Math]::Max(160,$width-40),0) }
})

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
    foreach ($button in @($bCheck,$bOpt,$bDns,$bLatency,$bProxy,$bRescue,$bReport,$bRestore,$bTimeline,$bSystemProxy,$bSettings,$bScanRepairs)) {
        if ($button) { $button.Enabled = -not $On }
    }
    $badge.Enabled = -not $On
    [Windows.Forms.Application]::DoEvents()
}

# ============================ 状态刷新 ============================
function Update-Status {
    $i = Get-NetInfo
    # 代理三态：绿=已连接且真的生效 / 灰=直连 / 红=异常
    $proxyAlive = [bool]$i.ProxyPort
    $proxyOn    = [bool]$i.ProxyOn
    $stateColor = $C.Text   # 兜底：分支全部不命中时也不能把 null 赋给 ForeColor
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
    if ($script:proxyStateLabel) {
        $script:proxyStateLabel.Text = $stateText
        $script:proxyStateLabel.ForeColor = $stateColor
        $script:proxyStateDetail.Text = $stateDetail
    }
    # 系统代理按钮文字跟随实际状态
    if ($bSystemProxy) {
        if ($proxyOn) {
            $bSystemProxy.Text = '系统代理：已开启 ▾'
            $bSystemProxy.ForeColor = [System.Drawing.Color]::FromArgb(52,211,153)
        } else {
            $bSystemProxy.Text = '系统代理：已关闭 ▾'
            $bSystemProxy.ForeColor = [System.Drawing.Color]::FromArgb(0xE6,0xE8,0xEB)
        }
    }

    # 弱信号持续提示：5 秒刷新一次，连续 6 次（约 30 秒）都弱才提示，且 10 分钟内只提示一次
    if ($i.Rssi -match '-(\d+)') {
        if ([int]$Matches[1] -ge 70) {
            $script:weakHits = [int]$script:weakHits + 1
            $dueHint = (-not $script:weakHintAt) -or (((Get-Date) - $script:weakHintAt).TotalMinutes -ge 10)
            if ($script:weakHits -eq 6 -and $dueHint) {
                $script:weakHintAt = Get-Date
                Write-Log ('信号持续偏弱（-' + [int]$Matches[1] + ' dBm）。建议靠近路由器，或改用有线。') 'warn'
            }
        } else { $script:weakHits = 0 }
    }
    # 页脚时间戳
$foot.Text = ('最后更新 {0}  ·  点击此处查看使用说明' -f (Get-Date).ToString('HH:mm:ss'))
    return $i
}

# ============================ 操作 ============================
function Show-FirstRunHints {
    # 配置不全时给一次引导，不阻断任何操作
    $tips = @()

    $wl = $null
    try { $wl = Read-WifiList } catch { }
    $nets = if ($wl) { @($wl.networks) } else { @() }
    $campus = $null
    try { if ($wl) { $campus = Get-CampusFromList $wl } } catch { }

    if ($nets.Count -eq 0) {
        $tips += '还没有网络列表：⚙ 设置 → 网络列表… → 添加…  加入你常用的 WiFi（断网自动重连依赖它）'
    }
    if (-not $campus) {
        $tips += '还没有校园网条目：在网络列表里选中学校 WiFi → 「设为校园网」→ 填认证网址（之后「校园网登录」才可用）'
    } elseif ([string]::IsNullOrWhiteSpace([string]$campus.portalUrl)) {
        $tips += '校园网条目缺少认证网址：编辑该条目，填学校认证页地址'
    }

    $ps = $null
    try { $ps = Read-ProxySettings } catch { }
    if (-not $ps -or [string]::IsNullOrWhiteSpace([string]$ps.clientExe)) {
        $tips += '还没有配置代理客户端：⚙ 设置 → 代理软件主程序（开启代理时用来自动拉起内核）'
    }

    if ($tips.Count -eq 0) { return }
    Write-Log '首次使用引导：' 'info'
    foreach ($t in $tips) { Write-Log ('  · ' + $t) 'dim' }
}

function Invoke-Check {
    Set-Busy $true
    try {
        Write-Log '开始体检 ...' 'dim'
        $i = Update-Status
        $wireless = if ($i.SSID -ne '—') { $i.SSID + ' · ' + $i.Band + ' ch' + $i.Channel + ' · ' + $i.Rssi } else { '未连接无线' }
        Write-Log ("无线: {0}" -f $wireless)
        Write-Log ("地址: {0}   ({1}, {2})" -f $i.IP, $i.Adapter, $i.Link)
        Write-Log ("网关: {0}    DNS: {1}" -f $i.Gateway, $i.DNS)

        if ($i.Gateway -and $i.Gateway -ne '—') {
            Write-Log '测试到网关的延迟 ...' 'dim'
            $m = Measure-Latency -Target $i.Gateway -Count 14
            $script:samples.Clear()
            foreach ($s in $m.Samples) { [void]$script:samples.Add($s) }
            $chart.Invalidate()
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
    foreach ($d in (Read-DnsList)) { $cands += $d }

    Write-Log ("开始实测 " + $cands.Count + " 个 DNS（每家 2 次查询，约 5~15 秒）...") 'dim'
    $results = @()
    foreach ($cand in $cands) {
        $ms = Measure-DnsLatency -Server $cand.Ip -Fast
        $results += [pscustomobject]@{ Server = $cand.Ip; Name = $cand.Name; Ms = $ms }
        # 边测边出结果，避免十几秒没有反馈
        $isGw = ($cand.Ip -eq $i.Gateway)
        if ($ms -ge 9999) {
            $tag = if ($isGw) { '网关不提供 DNS（正常）' } else { '超时 / 不可用' }
            $lvl = if ($isGw) { 'dim' } else { 'err' }
        } else {
            $tag = ("{0,4} ms" -f $ms)
            $lvl = if ($ms -le 30) { 'ok' } elseif ($ms -le 80) { 'dim' } else { 'warn' }
        }
        Write-Log ("     {0,-16} {1,-20} {2}" -f $cand.Ip, $cand.Name, $tag) $lvl
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
        Write-Log ('结果：平均 {0}ms · 抖动 {1}ms · 最大 {2}ms · 丢包 {3}%' -f $m.Avg, $m.Jitter, $m.Max, $m.Loss) $(if ($m.Loss -gt 0 -or $m.Jitter -gt 30) { 'err' } elseif ($m.Jitter -gt 12) { 'warn' } else { 'ok' })
        if ($m.Jitter -gt 30) {
            Write-Log '抖动偏大：多半是无线链路或热点拥塞，建议换 5GHz 热点 / 用有线' 'warn'
        }
        Write-Log ('原始采样: ' + (($m.Samples | ForEach-Object { if ($_ -lt 0) { 'X' } else { $_ } }) -join ' ')) 'dim'
    } catch {
        Write-Log "延迟测试出错：$($_.Exception.Message)" 'err'
    } finally { Set-Busy $false }
}



function Invoke-ResetCurrentDns {
    if (-not (Test-AdminAccess)) { return }
    $info = Get-NetInfo
    if (-not $info.Adapter -or $info.Adapter -eq '—') { Write-Log '没有识别到当前网卡，无法恢复自动 DNS。' 'warn'; return }
    $answer = [Windows.Forms.MessageBox]::Show(('将把「' + $info.Adapter + '」的 DNS 改为自动获取（DHCP）。会先保存当前网络设置备份。继续？'), '恢复自动 DNS', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }
    Set-Busy $true
    try {
        $backup = New-NetBackup
        Write-Log ('已备份当前网络设置：' + [IO.Path]::GetFileName($backup)) 'dim'
        Set-DnsClientServerAddress -InterfaceAlias $info.Adapter -ResetServerAddresses -ErrorAction Stop
        ipconfig /flushdns | Out-Null
        Write-Log ('已把「' + $info.Adapter + '」的 DNS 恢复为自动获取') 'ok'
        Update-Status | Out-Null
    } catch {
        Write-Log ('恢复自动 DNS 失败：' + $_.Exception.Message) 'err'
    } finally {
        Set-Busy $false
    }
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

function Format-Span([int]$Seconds) {
    if ($Seconds -lt 60) { return ("{0} 秒" -f $Seconds) }
    if ($Seconds -lt 3600) { return ("{0} 分 {1} 秒" -f [int]($Seconds / 60), ($Seconds % 60)) }
    return ("{0} 小时 {1} 分" -f [int]($Seconds / 3600), [int](($Seconds % 3600) / 60))
}

function Get-DisconnectCount {
    # 今日断链"会话"数（不是事件条数），并累计中断时长
    if (((Get-Date) - $script:dropCache.Time).TotalSeconds -lt 60) { return $script:dropCache.Count }
    $u = Get-UnifiedLinkEvents -Days 2
    $today = (Get-Date).Date
    $todaySessions = @($u.Sessions | Where-Object { $_.Start -ge $today -or $_.End -ge $today })
    $totalSeconds = 0
    foreach ($s in $todaySessions) { $totalSeconds += [int]$s.Seconds }
    $script:dropCache = @{
        Time    = (Get-Date)
        Count   = $todaySessions.Count
        Seconds = $totalSeconds
        Ignored = $u.Ignored
        Merged  = $u.Merged
    }
    return $todaySessions.Count
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
    $u = Get-UnifiedLinkEvents -Days 7
    $sessions = @($u.Sessions)
    $times = @($sessions | ForEach-Object { $_.Start })
    $totalSec = 0; foreach ($s in $sessions) { $totalSec += [int]$s.Seconds }
    $excluded = $u.Ignored
    $mergedCount = $u.Merged
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
    if ($totalSec -gt 0) { $sumText += (" · 累计中断 {0}" -f (Format-Span $totalSec)) }
    if ($excluded -gt 0) { $sumText += (" · 已排除 {0} 次工具操作" -f $excluded) }
    if ($mergedCount -gt 0) { $sumText += (" · 已合并 {0} 次重复记录" -f $mergedCount) }
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
        $dur = ''
        $secOfSession = [int]$sessions[$i].Seconds
        if ($secOfSession -gt 0) { $dur = ('  中断 {0}' -f (Format-Span $secOfSession)) }
        $items += ('{0}{1}{2}' -f $times[$i].ToString('MM-dd HH:mm:ss'), $dur, $gap)
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
    $property = Get-NetAdapterAdvancedProperty -Name $wifi.Name -RegistryKeyword 'RoamingPreferredBandType' -ErrorAction Stop
    if ([int](@($property.RegistryValue)[0]) -eq $Value) { return }
    $backupPath = New-WifiBandBackup -InterfaceAlias $wifi.Name -RegistryKeyword 'RoamingPreferredBandType'
    Add-IgnoreWindow '修改无线频段偏好' 30
    Set-NetAdapterAdvancedProperty -Name $wifi.Name -RegistryKeyword 'RoamingPreferredBandType' -RegistryValue $Value -NoRestart -ErrorAction Stop
    $after = Get-NetAdapterAdvancedProperty -Name $wifi.Name -RegistryKeyword 'RoamingPreferredBandType' -ErrorAction Stop
    if ([int](@($after.RegistryValue)[0]) -ne $Value) { throw ('频段偏好写后复检未达到目标；原值备份：' + $backupPath) }
    return $backupPath
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

function Request-StatusRefresh {
    # 旧调用点沿用这个名字：请求后台监测器尽快给一份新快照，不阻塞界面
    try {
        if ($script:monitor) { Request-NetworkMonitorRefresh -Monitor $script:monitor }
    } catch { }
}

function Confirm-Prompt {
    param([string]$Text,[string]$Title)
    try {
        return ([Windows.Forms.MessageBox]::Show($Text, $Title, 'YesNo', 'Question') -eq 'Yes')
    } catch {
        return $false
    }
}

function Open-CampusLogin {
    $snapshot = $script:lastSnapshot
    if (-not $snapshot) {
        Write-Log '请等待本轮检测完成，再打开登录页。' 'warn'
        Request-StatusRefresh
        return
    }
    if ($snapshot.Conclusion.State -eq 'Online') {
        Write-Log '外网已验证可用，无需再次认证。' 'ok'
        return
    }
    if ($snapshot.Conclusion.State -eq 'Unknown') {
        Write-Log '当前连接状态未知，正在重新检测；取得证据后再打开登录页。' 'warn'
        Request-StatusRefresh
        return
    }
    $cfg = Get-CampusConfig
    if (-not $cfg -or [string]::IsNullOrWhiteSpace([string]$cfg.portalUrl)) {
        Write-Log '尚未配置认证网址，已打开设置；有线连接可直接填写校园认证网址。' 'warn'
        Show-SettingsWindow
        return
    }
    $portalUri = $null
    if (-not [uri]::TryCreate([string]$cfg.portalUrl, [UriKind]::Absolute, [ref]$portalUri) -or $portalUri.Scheme -notin @('http','https')) {
        Write-Log '认证网址需为完整的 http:// 或 https:// 地址，请在设置中更正。' 'warn'
        Show-SettingsWindow
        return
    }
    if ($snapshot.Info.ProxyOn) {
        # 认证页在校内网段，手动系统代理开着通常打不开：先确认是否关闭
        if (Confirm-Prompt '检测到手动系统代理已开启。校园认证页通常只能在校内直连下打开，是否先关闭手动系统代理，再打开登录页？' '校园网登录') {
            try {
                Set-ProxyState -Enable $false
                Start-Sleep -Milliseconds 400
                $afterProxy = Get-NetInfo
                if ($afterProxy.ProxyOn) {
                    Write-Log '关闭手动系统代理未生效，已停止打开登录页；请先在「系统代理 ▾」里确认。' 'err'
                    return
                }
                Write-Log '已关闭手动系统代理，正在打开登录页；登录完成后可在「系统代理 ▾」里重新开启。' 'ok'
                if ($afterProxy.PacUrl) { Write-Log ('另有 PAC 自动代理：' + $afterProxy.PacUrl + '；如果认证页仍打不开，需要一并检查。') 'warn' }
            } catch {
                Write-Log ('关闭手动系统代理失败：' + $_.Exception.Message + '；已停止打开登录页。') 'err'
                return
            }
        } else {
            Write-Log '保持系统代理开启；如果登录页打不开，可在「系统代理 ▾」里关闭后再试。' 'warn'
        }
    }
    try {
        Start-Process $portalUri.AbsoluteUri
        Write-Log ('已用默认浏览器打开认证页：' + $portalUri.AbsoluteUri) 'ok'
    } catch {
        Write-Log ('调用浏览器失败：' + $_.Exception.Message) 'err'
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

function Test-NetworkQuality {
    # 判断"连上了但能不能真的上网"，区分三种情况：
    #   在线     HTTP 直连正常
    #   需认证   被劫持到认证页（校园网属正常）
    #   假联网   网关通但 DNS/HTTP 都不行
    $reach = Get-NetworkReachability
    if (-not $reach.Up) {
        return [pscustomobject]@{ Usable = $false; Kind = '无网关'; Detail = $reach.Reason }
    }

    $dnsOk = $false
    try {
        $dnsOk = [bool](Resolve-DnsName 'www.baidu.com' -Type A -ErrorAction Stop)
    } catch { $dnsOk = $false }

    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path $curl)) {
        return [pscustomobject]@{ Usable = $dnsOk; Kind = $(if ($dnsOk) { '在线（未验证 HTTP）' } else { '假联网' }); Detail = '缺少 curl.exe' }
    }

    $out = & $curl --noproxy '*' -s -o NUL -w '%{http_code}|%{redirect_url}' --max-time 6 'http://www.baidu.com' 2>$null
    $parts = ("$out").Trim() -split '\|'
    $code = 0
    [void][int]::TryParse($parts[0], [ref]$code)
    $redirect = if ($parts.Count -gt 1) { [string]$parts[1] } else { '' }

    if ($code -ge 200 -and $code -lt 400 -and [string]::IsNullOrWhiteSpace($redirect)) {
        return [pscustomobject]@{ Usable = $true; Kind = '在线'; Detail = "HTTP $code" }
    }
    if (-not [string]::IsNullOrWhiteSpace($redirect) -and $redirect -notmatch 'baidu\.com') {
        return [pscustomobject]@{ Usable = $false; Kind = '需认证'; Detail = ('被重定向到 ' + $redirect) }
    }
    if ($dnsOk) {
        return [pscustomobject]@{ Usable = $false; Kind = '假联网'; Detail = 'DNS 能解析，但 HTTP 出不去了' }
    }
    return [pscustomobject]@{ Usable = $false; Kind = '假联网'; Detail = 'DNS 与 HTTP 都不通' }
}

function Get-StatusColor([string]$State) {
    $fallback = [System.Drawing.Color]::FromArgb(0xE5, 0xE7, 0xEB)
    $pick = $null
    if ($State -eq 'Ok') { $pick = $C.Ok }
    elseif ($State -eq 'Degraded' -or $State -eq 'Warn') { $pick = $C.Warn }
    elseif ($State -eq 'NeedsAuth') { $pick = $C.Warn }
    elseif ($State -eq 'Fail' -or $State -eq 'Down' -or $State -eq 'Error') { $pick = $C.Err }
    elseif ($State -eq 'Ok' -or $State -eq 'Unknown') { $pick = $C.Text }
    if ($pick -is [System.Drawing.Color]) { return $pick }
    return $fallback   # 任何情况下都返回有效颜色
}

function Update-NetworkMonitorUi {
    # 由 1 秒 UI 定时器调用；只消费后台线程产出的快照，不做任何阻塞探测
    if (-not $script:monitor -or $script:monitorBusy) { return }
    $script:monitorBusy = $true
    try {
        $snap = Receive-NetworkMonitorSnapshot -Monitor $script:monitor
        if (-not $snap) { return }
        $script:lastSnapshot = $snap

        # 代理开关一变，结论就要立刻重算，否则会停留在切换前的「外网已验证」
        $proxyNow = if ($snap.Proxy) { [bool]$snap.Proxy.Enabled } else { $false }
        if ($null -ne $script:lastProxyEnabled -and $proxyNow -ne $script:lastProxyEnabled) {
            try { Request-NetworkMonitorRefresh -Monitor $script:monitor -Full } catch { }
        }
        $script:lastProxyEnabled = $proxyNow
        $c = Resolve-NetworkConclusion -Snapshot $snap
        $script:lastConclusion = $c

        if ($lbConclusion) {
        # 分层判定已经产出了标题时，不再由旧结论覆盖（保证单一数据源）
        if (-not $script:layerCache) {
            $headline = [string]$c.Title
            if ($snap.Proxy) {
                $headline += if ($snap.Proxy.Enabled) { "　·　系统代理已开启" } else { "　·　系统代理已关闭" }
            }
            $lbConclusion.Text = $headline
        }
            $qColor = $C.Text
            switch ([string]$c.State) {
                'Online'          { if ($C.Ok)   { $qColor = $C.Ok } }
                'NeedsAuth'       { if ($C.Warn) { $qColor = $C.Warn } }
                'ProxyIssue'      { if ($C.Warn) { $qColor = $C.Warn } }
                'Offline'         { if ($C.Dim)  { $qColor = $C.Dim } }
                'ExternalFailure' { if ($C.Err)  { $qColor = $C.Err } }
            }
            if ($qColor) { $lbConclusion.ForeColor = $qColor }
        }
        if ($lbConclusionDetail) { $lbConclusionDetail.Text = [string]$c.Detail }
        if ($lbCheckedAt) {
            $at = if ($c.CheckedAt) { ([datetime]$c.CheckedAt).ToString('HH:mm:ss') } else { '尚未取得' }
            $known = if ($c.Known) { '证据完整' } else { '证据不完整' }
            $lbCheckedAt.Text = "检测证据：$at  ·  $known"
        }

        $info = $snap.Info
        if ($lbConnectionEvidence) {
            $ssid = '未识别'
            if ($info) {
                foreach ($key in @('SSID','ssid')) {
                    if ($info.Contains($key) -and $info[$key] -and [string]$info[$key] -ne '—') { $ssid = [string]$info[$key]; break }
                }
            }
            $lbConnectionEvidence.Text = "连接与认证：$ssid"
        }
        if ($lbNetworkEvidence -and $snap.Quality) {
            $lbNetworkEvidence.Text = '外网质量：' + [string]$snap.Quality.Detail
        }
        if ($script:proxyStateLabel -and $snap.Proxy) {
            $script:proxyStateLabel.Text = if ($snap.Proxy.Enabled) { '系统代理已开启' } else { '系统代理已关闭' }
            if ($script:proxyStateDetail) { $script:proxyStateDetail.Text = [string]$snap.Proxy.Detail }
        }

        # 断链历史读取较重，60 秒一次即可
        if ($lbHomeHistory -and ((Get-Date) - $script:historyAt).TotalSeconds -ge 60) {
            $script:historyAt = Get-Date
            $u = Get-UnifiedLinkEvents -Days 1
            $today = (Get-Date).Date
            $n = @($u.Sessions | Where-Object { $_.Start -ge $today -or $_.End -ge $today }).Count
            $lbHomeHistory.Text = "断链历史：今日 $n 次  ·  " + [string]$u.Detail
        }
    } catch {
        # 监测器异常不能影响界面
        if (((Get-Date) - $script:monitorErrAt).TotalSeconds -gt 60) {
            $script:monitorErrAt = Get-Date
            try { [IO.File]::AppendAllText((Join-Path $script:DataRoot 'runtime\monitor-error.txt'), ((Get-Date).ToString('HH:mm:ss') + ' UI刷新: ' + $_.Exception.ToString() + "`r`n")) } catch { }
        }
    } finally {
        $script:monitorBusy = $false
    }
}

# ---------- 分层探测（后台 runspace，60 秒一次） ----------
$script:layerCache = $null
$script:layerWork = $null
$script:layerAt = [datetime]::MinValue
$script:layerRuns = 0

function Start-LayerProbe {
    if ($script:layerWork) { return }
    $root = $script:ProjRoot
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript("& { . '$root\src\lib\NetLayers.ps1'; . '$root\src\lib\NetProbe.ps1'; Get-LayerProbes }")
    $script:layerWork = [pscustomobject]@{ PowerShell = $ps; Handle = $ps.BeginInvoke() }
}

function Receive-LayerProbe {
    if (-not $script:layerWork) { return }
    if (-not $script:layerWork.Handle.IsCompleted) { return }
    try {
        $out = $script:layerWork.PowerShell.EndInvoke($script:layerWork.Handle)
        if ($out -and $out.Count -gt 0 -and $out[-1]) { $script:layerCache = $out[-1] }
    } catch {
    } finally {
        try { $script:layerWork.PowerShell.Dispose() } catch { }
        $script:layerWork = $null
        $script:layerAt = Get-Date
    }
}

function Update-LayerUi {
    Receive-LayerProbe
    if (((Get-Date) - $script:layerAt).TotalSeconds -ge 60) { Start-LayerProbe }

    $cache = $script:layerCache
    if (-not $cache) { return }

    $snap = $script:lastSnapshot
    $linkOk = $snap -and $snap.Connection -and $snap.Connection.Connected
    $proxyOn = $snap -and $snap.Proxy -and $snap.Proxy.Enabled
    $proxyAlive = $snap -and $snap.Proxy -and $snap.Proxy.Alive

    $layers = [pscustomobject]@{
        Link     = (New-LayerState -State $(if ($linkOk) { 'Ok' } else { 'Fail' }) -Detail '网卡连接状态')
        Dns      = $cache.Dns
        Domestic = $cache.Domestic
        Intl     = $cache.Intl
        Proxy    = [pscustomobject]@{ Enabled = [bool]$proxyOn; Alive = [bool]$proxyAlive; Protocol = ''; Exit = '' }
        Auth     = [pscustomobject]@{ Redirect = $false; PortalUrl = '' }
    }
    $c = Resolve-LayerConclusion -Layers $layers

    if ($lbConclusion) {
        $lbConclusion.Text = $c.Title
        if ($c.Severity -eq 'Ok') { $lbConclusion.ForeColor = [System.Drawing.Color]::FromArgb(52,211,153) }
        elseif ($c.Severity -eq 'Degraded' -or $c.Severity -eq 'NeedsAuth') { $lbConclusion.ForeColor = [System.Drawing.Color]::FromArgb(251,191,36) }
        else { $lbConclusion.ForeColor = [System.Drawing.Color]::FromArgb(156,163,175) }
    }
    if ($lbConclusionDetail -and $c.Detail) { $lbConclusionDetail.Text = $c.Detail }
    if ($script:badgeLabels) {
        foreach ($b in $c.Badges) {
            $label = $script:badgeLabels[$b.Key]
            if (-not $label) { continue }
            $label.Text = ([string]$b.Mark) + ' ' + $b.Key
            if ($b.State -eq 'Ok') { $label.ForeColor = [System.Drawing.Color]::FromArgb(52,211,153) }
            elseif ($b.State -eq 'Partial') { $label.ForeColor = [System.Drawing.Color]::FromArgb(251,191,36) }
            elseif ($b.State -eq 'Fail') { $label.ForeColor = [System.Drawing.Color]::FromArgb(248,113,113) }
            else { $label.ForeColor = [System.Drawing.Color]::FromArgb(156,163,175) }
            $label.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
        }
    }
}

# ---------- 检测详情五段：链路 / DNS / 国内 / 国际 / 代理 ----------
$script:detailSuggest = @{
    Link     = '检查无线是否连接到目标网络，或插好网线。'
    Dns      = '在「更多工具」里运行「DNS 优选」，或手动换一组 DNS。'
    Domestic = '先运行「校园网体检」，若在校园网再确认是否需要认证。'
    Intl     = '需要访问境外服务时开启代理；直连状态下这是预期结果。'
    Proxy    = '启动代理客户端，或关闭手动系统代理。'
}

function Update-DetailUi {
    if (-not $script:detailSections) { return }
    $snap = $script:lastSnapshot
    $cache = $script:layerCache

    # 链路：直接用后台快照，不额外发请求
    $linkState = 'Unknown'
    $linkAt = ''
    $linkEvidence = '— 未验证'
    if ($snap) {
        $conn = $snap.Connection
        $info = $snap.Info
        if ($conn) {
            if ($conn.CheckedAt) { $linkAt = ([datetime]$conn.CheckedAt).ToString('HH:mm:ss') }
            if ($conn.Known) {
                if ($conn.Connected) { $linkState = 'Ok' } else { $linkState = 'Fail' }
            }
        }
        if ($conn -and $conn.Known -and -not $conn.Connected) {
            $linkEvidence = [string]$conn.Detail
        } elseif ($conn -and $conn.Connected) {
            $parts = @()
            $adapterName = [string]$info.Adapter
            if ([string]::IsNullOrWhiteSpace($adapterName) -or $adapterName -eq '—') { $adapterName = '未识别网卡' }
            $parts += '网卡 ' + $adapterName
            if ([string]$info.SSID -and [string]$info.SSID -ne '—') { $parts += [string]$info.SSID }
            if ([string]$info.Rssi -and [string]$info.Rssi -ne '—') { $parts += [string]$info.Rssi }
            if ([string]$info.Gateway -and [string]$info.Gateway -ne '—') { $parts += '网关 ' + [string]$info.Gateway }
            $ping = $snap.GatewayPing
            if ($ping -and $ping.Known) {
                if ($ping.Success) { $parts += ([string]$ping.Milliseconds + 'ms') } else { $parts += '网关未回应 ICMP' }
            }
            $linkEvidence = $parts -join ' · '
        }
    }
    $linkSuggest = if ($linkState -eq 'Fail') { $script:detailSuggest.Link } else { '' }
    Set-DetailSection 'Link' $linkState $linkEvidence $linkAt $linkSuggest

    foreach ($layerKey in @('Dns','Domestic','Intl')) {
        $layer = $null
        if ($cache) { $layer = $cache.$layerKey }
        if ($layer) {
            $layerAt = ''
            if ($layer.At) { $layerAt = ([datetime]$layer.At).ToString('HH:mm:ss') }
            $layerSuggest = if ($layer.State -eq 'Fail' -or $layer.State -eq 'Partial') { $script:detailSuggest[$layerKey] } else { '' }
            Set-DetailSection $layerKey ([string]$layer.State) ([string]$layer.Detail) $layerAt $layerSuggest
            Set-DetailEndpoints $layerKey $layer.Endpoints
        } else {
            Set-DetailSection $layerKey 'Unknown' '— 未验证'
            Set-DetailEndpoints $layerKey @()
        }
    }

    # 代理：系统代理状态与端口监听
    $proxyState = 'Unknown'
    $proxyAt = ''
    $proxyEvidence = '— 未验证'
    if ($snap -and $snap.Proxy) {
        $p = $snap.Proxy
        if ($p.CheckedAt) { $proxyAt = ([datetime]$p.CheckedAt).ToString('HH:mm:ss') }
        $portText = '端口 ' + [string]$p.Port
        if ($p.Known) {
            if ($p.Enabled) {
                if ($p.Alive) { $proxyState = 'Ok'; $proxyEvidence = $portText + ' 正在监听 · 出口未验证' }
                else { $proxyState = 'Fail'; $proxyEvidence = $portText + ' 未监听' }
            } else {
                $proxyEvidence = $portText + ' · 未启用，未检查监听'
            }
        }
    }
    $proxySuggest = if ($proxyState -eq 'Fail') { $script:detailSuggest.Proxy } else { '' }
    Set-DetailSection 'Proxy' $proxyState $proxyEvidence $proxyAt $proxySuggest
}

# ---------- 检查新版本（可选、只读；连不上 GitHub 就静默跳过） ----------
$script:updateWork = $null
$script:updateChecked = $false

function Test-NewerVersion {
    param([string]$Current,[string]$Latest)
    $c = $null
    $l = $null
    if (-not [version]::TryParse(([string]$Current).TrimStart([char[]]@('v','V')), [ref]$c)) { return $false }
    if (-not [version]::TryParse(([string]$Latest).TrimStart([char[]]@('v','V')), [ref]$l)) { return $false }
    return ($l -gt $c)
}

function Start-UpdateCheck {
    if ($script:updateWork -or $script:updateChecked) { return }
    $script:updateChecked = $true
    $code = {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
        try {
            $request = [Net.HttpWebRequest]::Create('https://api.github.com/repos/Killin777/campus-net-toolkit/releases/latest')
            $request.Timeout = 5000
            $request.ReadWriteTimeout = 5000
            $request.UserAgent = 'CampusNetToolkit/update-check'
            $response = $request.GetResponse()
            $reader = New-Object IO.StreamReader($response.GetResponseStream())
            $body = $reader.ReadToEnd()
            $reader.Dispose()
            $response.Close()
            $doc = $body | ConvertFrom-Json
            [pscustomobject]@{ Ok = $true; Tag = [string]$doc.tag_name; Url = [string]$doc.html_url; Error = '' }
        } catch {
            [pscustomobject]@{ Ok = $false; Tag = ''; Url = ''; Error = $_.Exception.Message }
        }
    }
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($code.ToString())
    $script:updateWork = [pscustomobject]@{ PowerShell = $ps; Handle = $ps.BeginInvoke() }
}

function Receive-UpdateCheck {
    if (-not $script:updateWork) { return }
    if ($script:busy) { return }
    if (-not $script:updateWork.Handle.IsCompleted) { return }
    $work = $script:updateWork
    $script:updateWork = $null
    $result = $null
    try {
        $out = @($work.PowerShell.EndInvoke($work.Handle))
        if ($out.Count -gt 0) { $result = $out[$out.Count - 1] }
    } catch { } finally { try { $work.PowerShell.Dispose() } catch { } }
    if (-not $result) { return }
    if (-not $result.Ok) {
        Write-Log ('检查更新：连不上 GitHub（' + [string]$result.Error + '）') 'dim'
        return
    }
    $latestText = [string]$result.Tag
    if (-not (Test-NewerVersion ([string]$script:AppVersion) $latestText)) {
        if ($latestText) { Write-Log ('检查更新：已是最新版本 v' + $script:AppVersion) 'dim' }
        return
    }
    $shown = $latestText.TrimStart([char[]]@('v','V'))
    Write-Log ('检查更新：发现新版本 v' + $shown + '（当前 v' + $script:AppVersion + '）') 'warn'
    $url = [string]$result.Url
    if ([string]::IsNullOrWhiteSpace($url)) { $url = 'https://github.com/Killin777/campus-net-toolkit/releases/latest' }
    $answer = [Windows.Forms.MessageBox]::Show(
        ('发现新版本 v' + $shown + '（当前 v' + $script:AppVersion + "）。`n`n是否打开下载页面？`n" + $url),
        '检查更新', 'YesNo', 'Question')
    if ($answer -eq 'Yes') {
        try { Start-Process $url } catch { Write-Log ('无法打开浏览器：' + $_.Exception.Message) 'warn' }
    }
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
                $now = Get-Date
                $secs = [int]($now - $script:wifiDownSince).TotalSeconds
                $toolHealed = [bool]$script:wifiDownByTool
                $inWindow = $false
                if (-not $toolHealed) { $inWindow = Test-LinkIgnoreWindow -Start $script:wifiDownSince -End $now }
                if ($toolHealed -or $inWindow) {
                    Write-Log ("网络已恢复（中断约 $secs 秒；期间在工具维护窗口内，不计入断链）") 'dim'
                } elseif ($secs -ge 10) {
                    Add-LinkEvent '断链' $secs -Estimate -LowerBoundSeconds $secs
                    Write-Log ("网络已恢复（中断约 $secs 秒，按 15 秒采样估计，记为断链）") 'warn'
                } else {
                    Add-LinkEvent '抖动' $secs
                    Write-Log ("网络短暂中断约 $secs 秒（抖动，不计入断链）") 'dim'
                }
                $script:wifiDownSince = $null
                $script:wifiDownByTool = $false
            }
            return
        }

        if (-not $script:wifiDownSince) {
            $now = Get-Date
            # 工具自己的操作（重连/登录/急救）本来就会短暂断网，窗口内不新建断链会话
            if (Test-LinkIgnoreWindow -Start $now.AddSeconds(-15) -End $now) { return }
            $script:wifiDownSince = $now
            $script:wifiDownByTool = $false
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
        $script:wifiDownByTool = $true
        Write-Log ("已断网约 " + [int]$downFor + " 秒，按列表尝试重连 ...") 'warn'
        foreach ($n in $order) {
            if (-not (Test-WifiInRange $n.ssid)) { continue }
            Write-Log ("  尝试 " + $n.ssid) 'dim'
            $ok = Connect-CampusWifi $n.ssid ([bool]$n.campus)
            if (-not $ok) { Write-Log ("  连不上 " + $n.ssid) 'dim'; continue }

            # 连上不等于能上网：判一次质量，假联网就继续找下一个
            $q = Test-NetworkQuality
            if ($q.Usable) {
                Write-Log ("  已重连到 " + $n.ssid + "（" + $q.Kind + "）") 'ok'
                if ($script:wifiDownSince) {
                    $secs = [int]((Get-Date) - $script:wifiDownSince).TotalSeconds
                    Write-Log ("网络已恢复（中断约 $secs 秒；由工具重连，不计入断链）") 'dim'
                    $script:wifiDownSince = $null
                    $script:wifiDownByTool = $false
                }
                return
            }
            if ($q.Kind -eq '需认证' -and $n.campus) {
                Write-Log ("  已连上 " + $n.ssid + "，但需要校园网认证（" + $q.Detail + "）") 'warn'
                Write-Log '  点「校园网登录」完成认证' 'dim'
                if ($script:wifiDownSince) {
                    $secs = [int]((Get-Date) - $script:wifiDownSince).TotalSeconds
                    Write-Log ("网络已恢复（中断约 $secs 秒；由工具重连，不计入断链）") 'dim'
                    $script:wifiDownSince = $null
                    $script:wifiDownByTool = $false
                }
                return
            }
            Write-Log ("  " + $n.ssid + " 是假联网（" + $q.Kind + "：" + $q.Detail + "），继续下一个") 'warn'
        }
        $script:wifiDownByTool = $false
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
    $hint.Text = '断网时按优先级重连（1 最先）；选中某行后点右侧 ▲▼ 调整顺序'
    $hint.ForeColor = $C.Dim
    $hint.Location = New-Object System.Drawing.Point(18, 14)
    $hint.Size = New-Object System.Drawing.Size(750, 20)
    $w.Controls.Add($hint)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.Location = New-Object System.Drawing.Point(18, 40)
    $lv.Size = New-Object System.Drawing.Size(706, 320)
    $lv.View = 'Details'
    $lv.FullRowSelect = $true
    $lv.GridLines = $false
    $lv.MultiSelect = $false
    $lv.BackColor = $C.Card
    $lv.ForeColor = $C.Text
    $lv.BorderStyle = 'FixedSingle'
    [void]$lv.Columns.Add('优先级', 60)
    [void]$lv.Columns.Add('网络名称', 150)
    [void]$lv.Columns.Add('类型', 70)
    [void]$lv.Columns.Add('认证网址 / 密码', 336)
    [void]$lv.Columns.Add('自动重连', 90)
    $w.Controls.Add($lv)

    function Refresh-WifiList {
        $lv.Items.Clear()
        foreach ($n in @($data.networks)) {
            $kind = if ($n.campus) { '校园网' } else { '普通' }
            $detail = if ($n.campus) { [string]$n.portalUrl } else { '系统已保存密码' }
            $item = New-Object System.Windows.Forms.ListViewItem([string](@($data.networks).IndexOf($n) + 1))
            [void]$item.SubItems.Add([string]$n.ssid)
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

    # 选中某行时，行右侧出现上下箭头，用来调整重连优先级
    $btnUp = New-Object System.Windows.Forms.Button
    $btnUp.Text = [char]0x25B2
    $btnUp.Size = New-Object System.Drawing.Size(30, 24)
    $btnUp.FlatStyle = 'Flat'
    $btnUp.FlatAppearance.BorderSize = 0
    $btnUp.BackColor = $C.Card2
    $btnUp.ForeColor = $C.Text
    $btnUp.Visible = $false
    $btnUp.Cursor = 'Hand'
    $w.Controls.Add($btnUp)
    $btnUp.BringToFront()

    $btnDown = New-Object System.Windows.Forms.Button
    $btnDown.Text = [char]0x25BC
    $btnDown.Size = New-Object System.Drawing.Size(30, 24)
    $btnDown.FlatStyle = 'Flat'
    $btnDown.FlatAppearance.BorderSize = 0
    $btnDown.BackColor = $C.Card2
    $btnDown.ForeColor = $C.Text
    $btnDown.Visible = $false
    $btnDown.Cursor = 'Hand'
    $w.Controls.Add($btnDown)
    $btnDown.BringToFront()

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
    # 选中行时把上下箭头贴到该行右侧；点箭头交换顺序（顺序即重连优先级）

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

    # 事件处理器拿不到函数内的局部变量，所以这里统一挂到 $script: 作用域
    $script:wifiLv = $lv
    $script:wifiUp = $btnUp
    $script:wifiDown = $btnDown
    $script:wifiData = $data

    $script:UpdateWifiArrows = {
        $lv2 = $script:wifiLv
        $up = $script:wifiUp
        $down = $script:wifiDown
        if (-not $lv2 -or -not $up -or -not $down) { return }
        if ($lv2.SelectedItems.Count -eq 0) { $up.Visible = $false; $down.Visible = $false; return }
        $idx = $lv2.SelectedItems[0].Index
        $rect = $lv2.GetItemRect($idx)
        if ($rect.Height -le 0) { $up.Visible = $false; $down.Visible = $false; return }
        $x = $lv2.Right + 6
        $y = $lv2.Top + $rect.Top + [int](($rect.Height - 24) / 2)
        $up.Location = New-Object System.Drawing.Point($x, ($y - 26))
        $down.Location = New-Object System.Drawing.Point($x, $y)
        $up.Visible = ($idx -gt 0)
        $down.Visible = ($idx -lt ($lv2.Items.Count - 1))
        $up.BringToFront(); $down.BringToFront()
    }

    $script:MoveWifiItem = {
        param([int]$Delta)
        $lv2 = $script:wifiLv
        if (-not $lv2 -or $lv2.SelectedItems.Count -eq 0) { return }
        $idx = $lv2.SelectedItems[0].Index
        $newIdx = $idx + $Delta
        $list = @($script:wifiData.networks)
        if ($newIdx -lt 0 -or $newIdx -ge $list.Count) { return }
        $tmp = $list[$idx]
        $list[$idx] = $list[$newIdx]
        $list[$newIdx] = $tmp
        $script:wifiData.networks = $list
        Refresh-WifiList
        if ($newIdx -lt $lv2.Items.Count) {
            $lv2.Items[$newIdx].Selected = $true
            $lv2.Items[$newIdx].Focused = $true
        }
        & $script:UpdateWifiArrows
    }

    $lv.Add_SelectedIndexChanged({ & $script:UpdateWifiArrows })
    $lv.Add_Click({ & $script:UpdateWifiArrows })
    $btnUp.Add_Click({ & $script:MoveWifiItem -1 })
    $btnDown.Add_Click({ & $script:MoveWifiItem 1 })

    if ($script:captureWifiList) {
        $w.Show()
        if ($lv.Items.Count -gt 0) {
            $lv.Items[0].Selected = $true
            $lv.Items[0].Focused = $true
            & $script:UpdateWifiArrows
        }
        [System.Windows.Forms.Application]::DoEvents()
        $waitMs = if ($env:CAMPUS_NET_CAPTURE_WAIT) { [int]$env:CAMPUS_NET_CAPTURE_WAIT } else { 600 }
        $deadline = (Get-Date).AddMilliseconds($waitMs)
        while ((Get-Date) -lt $deadline) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
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

function Show-DnsListWindow {
    $servers = Read-DnsList

    $w = New-Object System.Windows.Forms.Form
    $w.Icon = $form.Icon
    $w.Text = 'DNS 候选列表'
    $w.Size = New-Object System.Drawing.Size(560, 520)
    $w.StartPosition = 'CenterParent'
    $w.FormBorderStyle = 'FixedDialog'
    $w.MaximizeBox = $false
    $w.MinimizeBox = $false
    $w.BackColor = $C.Bg
    $w.ForeColor = $C.Text
    $w.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = '每行一个，格式：IP 空格 名称（名称可省略）。「DNS 优选」会逐个实测这些服务器。'
    $hint.ForeColor = $C.Dim
    $hint.Location = New-Object System.Drawing.Point(18, 14)
    $hint.Size = New-Object System.Drawing.Size(520, 20)
    $w.Controls.Add($hint)

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Location = New-Object System.Drawing.Point(18, 40)
    $txt.Size = New-Object System.Drawing.Size(516, 360)
    $txt.Multiline = $true
    $txt.ScrollBars = 'Vertical'
    $txt.AcceptsReturn = $true
    $txt.BackColor = $C.Card
    $txt.ForeColor = $C.Text
    $txt.BorderStyle = 'FixedSingle'
    $txt.Font = New-Object System.Drawing.Font('Consolas', 10)
    $txt.Text = (($servers | ForEach-Object { "$($_.Ip) $($_.Name)" }) -join "`r`n")
    $w.Controls.Add($txt)

    $btnDefault = New-DialogButton $w '恢复默认' 18 412 110
    $btnSave    = New-DialogButton $w '保存'    330 412 100
    $btnSave.BackColor = $C.Accent
    $btnSave.Tag = $C.Accent
    $btnCancel  = New-DialogButton $w '取消'    436 412 100

    $btnDefault.Add_Click({
        $txt.Text = ((Get-DnsListDefaults | ForEach-Object { "$($_.Ip) $($_.Name)" }) -join "`r`n")
    })

    $btnSave.Add_Click({
        $parsed = @()
        $bad = 0
        foreach ($line in ($txt.Text -split "`r?`n")) {
            $t = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($t)) { continue }
            $parts = $t -split '\s+', 2
            $ip = $parts[0]
            $name = if ($parts.Count -gt 1) { $parts[1].Trim() } else { $ip }
            $ok = ($ip -match '^\d{1,3}(\.\d{1,3}){3}$') -or ($ip -match '^[0-9A-Fa-f:]{3,}$' -and $ip -match ':')
            if (-not $ok) { $bad++; continue }
            $parsed += [pscustomobject]@{ Ip = $ip; Name = $name }
        }
        if ($parsed.Count -eq 0) {
            [void][System.Windows.Forms.MessageBox]::Show('至少要有一个有效的 IP 地址。', '提示')
            return
        }
        if ($bad -gt 0) {
            [void][System.Windows.Forms.MessageBox]::Show("已忽略 $bad 行无法识别的地址。", '提示')
        }
        try {
            [void](Save-DnsList $parsed)
            Write-Log ("DNS 列表已保存：$($parsed.Count) 个服务器") 'ok'
            $w.DialogResult = 'OK'
            $w.Close()
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show("保存失败：$($_.Exception.Message)", '错误')
        }
    })
    $btnCancel.Add_Click({ $w.DialogResult = 'Cancel'; $w.Close() })

    if ($script:captureDnsList) {
        $w.Show()
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 500
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

function ConvertTo-EndpointList {
    param([string]$Text)
    $list = @()
    foreach ($line in ($Text -split "`r?`n")) {
        $value = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        $name = $value
        $url = $value
        $pipe = $value.IndexOf('|')
        if ($pipe -ge 0) {
            $name = $value.Substring(0,$pipe).Trim()
            $url = $value.Substring($pipe + 1).Trim()
        }
        if ([string]::IsNullOrWhiteSpace($name)) { $name = $url }
        $uri = $null
        if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -or @('http','https') -notcontains $uri.Scheme) {
            throw ('不是有效的 http/https 地址：' + $url)
        }
        $list += @{ name = $name; url = $url }
    }
    return $list
}

function Format-EndpointList {
    param($List)
    return ((@($List) | ForEach-Object { [string]$_.Name + '|' + [string]$_.Url }) -join "`r`n")
}

function Show-EndpointEditor {
    $w = New-Object System.Windows.Forms.Form
    $w.Icon = $form.Icon
    $w.Text = '检测端点'
    $w.Size = New-Object System.Drawing.Size(680, 560)
    $w.StartPosition = 'CenterParent'
    $w.FormBorderStyle = 'FixedDialog'
    $w.MaximizeBox = $false
    $w.MinimizeBox = $false
    $w.BackColor = $C.Bg
    $w.ForeColor = $C.Text
    $w.Font = New-Object System.Drawing.Font('Microsoft YaHei UI',9)

    $lHint = New-Object System.Windows.Forms.Label
    $lHint.Text = '每行一个端点，格式：名称|URL。只支持 http/https；留空行忽略。保存后下一次分层探测生效。'
    $lHint.ForeColor = $C.Dim
    $lHint.Location = New-Object System.Drawing.Point(16, 14)
    $lHint.Size = New-Object System.Drawing.Size(640, 20)
    $w.Controls.Add($lHint)

    $lDom = New-Object System.Windows.Forms.Label
    $lDom.Text = '国内端点'
    $lDom.ForeColor = $C.Text
    $lDom.Location = New-Object System.Drawing.Point(16, 44)
    $lDom.Size = New-Object System.Drawing.Size(200, 20)
    $w.Controls.Add($lDom)
    $tbDom = New-Object System.Windows.Forms.TextBox
    $tbDom.Multiline = $true
    $tbDom.ScrollBars = 'Vertical'
    $tbDom.AcceptsReturn = $true
    $tbDom.Location = New-Object System.Drawing.Point(16, 66)
    $tbDom.Size = New-Object System.Drawing.Size(632, 170)
    $tbDom.BackColor = $C.Card
    $tbDom.ForeColor = $C.Text
    $tbDom.BorderStyle = 'FixedSingle'
    $tbDom.Font = New-Object System.Drawing.Font('Consolas',10)
    $tbDom.Text = Format-EndpointList (Get-ProbeEndpoints -Layer Domestic)
    $w.Controls.Add($tbDom)

    $lIntl = New-Object System.Windows.Forms.Label
    $lIntl.Text = '国际端点'
    $lIntl.ForeColor = $C.Text
    $lIntl.Location = New-Object System.Drawing.Point(16, 246)
    $lIntl.Size = New-Object System.Drawing.Size(200, 20)
    $w.Controls.Add($lIntl)
    $tbIntl = New-Object System.Windows.Forms.TextBox
    $tbIntl.Multiline = $true
    $tbIntl.ScrollBars = 'Vertical'
    $tbIntl.AcceptsReturn = $true
    $tbIntl.Location = New-Object System.Drawing.Point(16, 268)
    $tbIntl.Size = New-Object System.Drawing.Size(632, 170)
    $tbIntl.BackColor = $C.Card
    $tbIntl.ForeColor = $C.Text
    $tbIntl.BorderStyle = 'FixedSingle'
    $tbIntl.Font = New-Object System.Drawing.Font('Consolas',10)
    $tbIntl.Text = Format-EndpointList (Get-ProbeEndpoints -Layer Intl)
    $w.Controls.Add($tbIntl)

    $btnReset = New-DialogButton $w '恢复默认' 16 460 110
    $btnSave = New-DialogButton $w '保存' 430 460 100
    $btnSave.BackColor = $C.Accent
    $btnSave.Tag = $C.Accent
    $btnCancel = New-DialogButton $w '取消' 540 460 100

    $btnReset.Add_Click({
        $tbDom.Text = Format-EndpointList (Get-DefaultProbeEndpoints -Layer Domestic)
        $tbIntl.Text = Format-EndpointList (Get-DefaultProbeEndpoints -Layer Intl)
    })
    $btnCancel.Add_Click({ $w.DialogResult = 'Cancel'; $w.Close() })
    $btnSave.Add_Click({
        try {
            $domList = @(ConvertTo-EndpointList $tbDom.Text)
            $intlList = @(ConvertTo-EndpointList $tbIntl.Text)
            if ($domList.Count -eq 0 -or $intlList.Count -eq 0) { throw '国内与国际至少要各保留一个端点' }
            if ($domList.Count -gt 8 -or $intlList.Count -gt 8) { throw '每层最多 8 个端点' }
            $path = Join-Path $script:DataRoot 'config\probe-endpoints.json'
            $doc = [ordered]@{ Domestic = @($domList); Intl = @($intlList) }
            Save-ToolkitJson $doc $path
            $script:layerAt = [datetime]::MinValue
            Write-Log ('检测端点已保存：国内 ' + [string]$domList.Count + ' 个，国际 ' + [string]$intlList.Count + ' 个') 'ok'
            $w.DialogResult = 'OK'
            $w.Close()
        } catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '检测端点', 'OK', 'Warning') | Out-Null
        }
    })
    if ($script:captureEndpoints) {
        if (-not ('W2.Gdi' -as [type])) {
            Add-Type -Namespace W2 -Name Gdi -MemberDefinition '[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint f);'
        }
        $w.Show()
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 500
        [System.Windows.Forms.Application]::DoEvents()
        $bmp = New-Object System.Drawing.Bitmap($w.Width, $w.Height)
        $gfx = [System.Drawing.Graphics]::FromImage($bmp)
        $hdc = $gfx.GetHdc()
        $ok = [W2.Gdi]::PrintWindow($w.Handle, $hdc, 2)
        $gfx.ReleaseHdc($hdc)
        $gfx.Dispose()
        if (-not $ok) { $w.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $w.Width, $w.Height))) }
        $bmp.Save($script:capturePath, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        $w.Close()
        $w.Dispose()
        Write-Host "已保存: $($script:capturePath) (PrintWindow=$ok)"
        return
    }
    [void]$w.ShowDialog()
}

function Show-SettingsWindow {
    $cfgFile = Join-Path $script:DataRoot 'runtime\proxy-settings.json'
    $curExe = ''
    $curPort = 7897
    $j = Read-ProxySettings
    if ($j.clientExe) { $curExe = [string]$j.clientExe }
    $parsedPort = 0
    if ([int]::TryParse([string]$j.port,[ref]$parsedPort) -and $parsedPort -ge 1 -and $parsedPort -le 65535) { $curPort=$parsedPort }
    $curCheckUpdates = $true
    if ($j -and $j.ContainsKey('checkUpdates')) { $curCheckUpdates = [bool]$j['checkUpdates'] }

    $w = New-Object System.Windows.Forms.Form
    $w.Icon = $form.Icon
    $w.Text = '设置'
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

    $btnWifi = New-DialogButton $w '网络列表…' 18 258 125
    $btnDns = New-DialogButton $w 'DNS 列表…' 150 258 115
    $btnDns.Add_Click({ Show-DnsListWindow })
    $btnWifi.Add_Click({ Show-WifiListWindow })

    $lWifiSummary = New-Object System.Windows.Forms.Label
    $lWifiSummary.ForeColor = $C.Dim
    $lWifiSummary.Location = New-Object System.Drawing.Point(274, 264)
    $lWifiSummary.Size = New-Object System.Drawing.Size(360, 20)
    $w.Controls.Add($lWifiSummary)

    $chk5g = New-Object System.Windows.Forms.CheckBox
    $chk5g.Text = '优先使用 5GHz（关闭后由 Windows 按信号强度选频段）'
    $chk5g.ForeColor = $C.Text
    $chk5g.Location = New-Object System.Drawing.Point(18, 300)
    $chk5g.Size = New-Object System.Drawing.Size(520, 24)
    $chk5g.FlatStyle = 'Flat'
    try { $chk5g.Checked = ((Get-BandPreference) -eq 2) } catch { $chk5g.Enabled = $false }
    $w.Controls.Add($chk5g)

    $l5gHint = New-Object System.Windows.Forms.Label
    $l5gHint.Text = '5GHz 更快但穿透差；2.4GHz 信号强但容易拥塞。改这项会让网卡短暂重连。'
    $l5gHint.ForeColor = $C.Dim
    $l5gHint.Location = New-Object System.Drawing.Point(38, 326)
    $l5gHint.Size = New-Object System.Drawing.Size(580, 20)
    $w.Controls.Add($l5gHint)

    $chkUpdates = New-Object System.Windows.Forms.CheckBox
    $chkUpdates.Text = '启动时检查新版本（需要能访问 GitHub，可随时关闭）'
    $chkUpdates.ForeColor = $C.Text
    $chkUpdates.Location = New-Object System.Drawing.Point(18, 350)
    $chkUpdates.Size = New-Object System.Drawing.Size(560, 24)
    $chkUpdates.FlatStyle = 'Flat'
    $chkUpdates.Checked = [bool]$curCheckUpdates
    $w.Controls.Add($chkUpdates)

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
    $btnEndpoints = New-DialogButton $w '检测端点…' 170 380 130
    $btnEndpoints.Add_Click({ Show-EndpointEditor })
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
        $ht['checkUpdates'] = [bool]$chkUpdates.Checked
        try {
            $cfgDir = Split-Path -Parent $cfgFile
            if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null }
            Save-ToolkitJson $ht $cfgFile
            # 频段偏好：改了才写，且先确认（网卡会短暂重连）
            try {
                $curBand = Get-BandPreference
                $wantBand = if ($chk5g.Checked) { 2 } else { 0 }
                if ($null -ne $curBand -and $curBand -ne $wantBand) {
                    $ans = [System.Windows.Forms.MessageBox]::Show(
                        '修改频段偏好会让无线网卡短暂断开重连，继续吗？', '频段偏好', 'YesNo', 'Question')
                    if ($ans -eq 'Yes') {
                        Set-BandPreference $wantBand
                        Write-Log ('频段偏好已改为：' + $(if ($wantBand -eq 2) { '优先 5GHz' } else { '按信号强度' })) 'ok'
                    }
                }
            } catch { Write-Log ('频段偏好未改动：' + $_.Exception.Message) 'dim' }
            $tail = if ($exe) { "，客户端 " + [System.IO.Path]::GetFileName($exe) } else { '，未设置客户端' }
            Write-Log ("设置已保存：端口 $p$tail") 'ok'
            if ($chkUpdates.Checked) { Start-UpdateCheck }
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
        # 检查结果写在检测详情页的日志面板，先切过去，否则用户看不到任何反应
        try { Show-Page 1 } catch { }
    try {
        Write-Log ($Title + '（约 10~20 秒）...') 'dim'
        $res = Invoke-ChildCapture -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $path, 'check')
        Write-Log ($Title + (' 完成，共 ' + @($res.Lines).Count + ' 行')) 'ok'
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

# ============================ 逐项处理 ============================
function New-RepairRow {
    param($Item)
    $row = New-Object Windows.Forms.TableLayoutPanel
    $row.Dock = 'Top'
    $row.AutoSize = $true
    $row.ColumnCount = 2
    $row.RowCount = 1
    [void]$row.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',28)))
    [void]$row.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)))
    $row.Margin = New-Object Windows.Forms.Padding(0)
    $row.BackColor = $C.Bg
    $check = New-Object Windows.Forms.CheckBox
    $check.Text = ''
    $check.Dock = 'Top'
    $check.Width = 20
    $check.Height = 20
    $check.Margin = New-Object Windows.Forms.Padding(2,4,0,0)
    $check.Tag = $Item
    $row.Controls.Add($check,0,0)

    $target = ''
    if ($Item.Type -eq 'InterfaceMetric') {
        $target = '接口跃点 ' + [string]$Item.Before.InterfaceMetric + ' → ' + [string]$Item.Desired.InterfaceMetric + '，关闭自动跃点'
    } elseif ($Item.Type -eq 'ManualProxyDisable') {
        $target = '关闭手动系统代理开关（代理地址与 PAC 保持原值）'
    }
    $perm = if ($Item.RequiresAdmin) { '需要管理员权限' } else { '不需要管理员权限' }
    $text = $Item.Title + "`r`n证据：" + $Item.Evidence + "`r`n改动：" + $target + '（' + $perm + '）' + "`r`n影响：" + $Item.Impact
    $label = New-Object Windows.Forms.Label
    $label.AutoSize = $true
    $label.MaximumSize = New-Object Drawing.Size([Math]::Max(320, $repairRows.ClientSize.Width - 48), 0)
    $label.Margin = New-Object Windows.Forms.Padding(0,2,8,12)
    $label.Text = $text
    $label.ForeColor = $C.Text
    $label.Font = New-Object Drawing.Font('Microsoft YaHei UI',10)
    $label.Cursor = 'Hand'
    $label.Add_Click({ $check.Checked = -not $check.Checked })
    $row.Controls.Add($label,1,0)

    $check.Add_CheckedChanged({ Set-RepairApplyState })
    $repairRows.RowCount++
    [void]$repairRows.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize')))
    [void]$repairRows.Controls.Add($row,0,$repairRows.RowCount - 1)
    $script:repairChecks += $check
    $script:repairTexts += $label
}

function New-RepairSectionLabel {
    param([string]$Text,[int]$TopGap = 10)
    $label = New-Object Windows.Forms.Label
    $label.AutoSize = $true
    $label.MaximumSize = New-Object Drawing.Size([Math]::Max(320, $repairRows.ClientSize.Width - 48), 0)
    $label.Margin = New-Object Windows.Forms.Padding(0,$TopGap,8,4)
    $label.Text = $Text
    $label.ForeColor = [System.Drawing.Color]::FromArgb(0x9A,0xA1,0xAE)
    $label.Font = New-Object Drawing.Font('Microsoft YaHei UI',9,[Drawing.FontStyle]::Bold)
    $repairRows.RowCount++
    [void]$repairRows.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize')))
    [void]$repairRows.Controls.Add($label,0,$repairRows.RowCount - 1)
    $script:repairTexts += $label
}

function New-RepairFindingRow {
    param($Finding)
    $severity = [string]$Finding.Severity
    if ($severity -eq 'ok') {
        $mark = [string][char]0x221A
        $color = [System.Drawing.Color]::FromArgb(0x9A,0xA1,0xAE)
    } elseif ($severity -eq 'warn') {
        $mark = '!'
        $color = [System.Drawing.Color]::FromArgb(0xFB,0xBF,0x24)
    } else {
        $mark = [string][char]0x00D7
        $color = [System.Drawing.Color]::FromArgb(0xF8,0x71,0x71)
    }
    $text = $mark + ' ' + [string]$Finding.Title
    if ($severity -ne 'ok') {
        if ($Finding.Detail) { $text += "`r`n   " + [string]$Finding.Detail }
        if ($Finding.Fix) { $text += "`r`n   " + [string][char]0x2192 + ' ' + [string]$Finding.Fix }
    }
    $label = New-Object Windows.Forms.Label
    $label.AutoSize = $true
    $label.MaximumSize = New-Object Drawing.Size([Math]::Max(320, $repairRows.ClientSize.Width - 48), 0)
    $label.Margin = New-Object Windows.Forms.Padding(0,2,8,6)
    $label.Text = $text
    $label.ForeColor = $color
    $label.Font = New-Object Drawing.Font('Microsoft YaHei UI',9)
    $repairRows.RowCount++
    [void]$repairRows.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize')))
    [void]$repairRows.Controls.Add($label,0,$repairRows.RowCount - 1)
    $script:repairTexts += $label
}

function Update-RepairItems {
    param($Report,[int]$ElapsedMs = -1)
    $repairRows.SuspendLayout()
    try {
        $repairRows.Controls.Clear()
        $repairRows.RowStyles.Clear()
        $repairRows.RowCount = 0
        $script:repairChecks = @()
        $script:repairTexts = @()
        $items = @(Get-RouteRepairItems -Report $Report)
        $findings = @($Report.Findings)
        $notable = @($findings | Where-Object { $_.Severity -ne 'ok' })
        if ($items.Count -gt 0) {
            New-RepairSectionLabel '可处理项（勾选后点「应用已选项」）' 0
            foreach ($item in $items) { New-RepairRow $item }
        }
        New-RepairSectionLabel '检查结果（只读，不会修改任何设置）' $(if ($items.Count -gt 0) { 14 } else { 0 })
        foreach ($finding in $findings) { New-RepairFindingRow $finding }
        if ($findings.Count -eq 0) { New-RepairSectionLabel '没有可显示的检查结果' 0 }

        $stamp = (Get-Date).ToString('HH:mm:ss')
        $cost = if ($ElapsedMs -ge 0) { '（' + ([math]::Round($ElapsedMs / 1000, 1)).ToString('0.0') + ' 秒）' } else { '' }
        if ($items.Count -gt 0) {
            $summary = '扫描完成 ' + $stamp + $cost + '：' + [string]$items.Count + ' 项可处理。每项先备份、改完复检，默认不勾选。'
            if ($notable.Count -gt 0) { $summary += '另有 ' + [string]$notable.Count + ' 条检查项需要留意。' }
            $lbRepairSummary.ForeColor = [System.Drawing.Color]::FromArgb(0xE6,0xE8,0xEB)
        } elseif ($notable.Count -gt 0) {
            $summary = '扫描完成 ' + $stamp + $cost + '：没有可自动处理的项，但有 ' + [string]$notable.Count + ' 条检查项需要留意（见下方）。'
            $lbRepairSummary.ForeColor = [System.Drawing.Color]::FromArgb(0xFB,0xBF,0x24)
        } else {
            $summary = '扫描完成 ' + $stamp + $cost + '：没有可自动处理的项，' + [string]$findings.Count + ' 条检查结果均正常。'
            $lbRepairSummary.ForeColor = [System.Drawing.Color]::FromArgb(0x9A,0xA1,0xAE)
        }
        $lbRepairSummary.Text = $summary
    } finally {
        $repairRows.ResumeLayout()
    }
    Set-RepairApplyState
}

function Set-RepairApplyState {
    $enabled = (@($script:repairChecks | Where-Object { $_.Checked }).Count -gt 0)
    $bApplyRepairs.Enabled = $enabled
    if ($enabled) {
        $bApplyRepairs.BackColor = [System.Drawing.Color]::FromArgb(0x25,0x63,0xEB)
        $bApplyRepairs.ForeColor = [System.Drawing.Color]::White
    } else {
        $bApplyRepairs.BackColor = [System.Drawing.Color]::FromArgb(0x2E,0x33,0x3C)
        $bApplyRepairs.ForeColor = [System.Drawing.Color]::FromArgb(0x9A,0xA1,0xAE)
    }
}

function Update-RepairHistory {
    $repairHistoryList.BeginUpdate()
    try {
        $repairHistoryList.Items.Clear()
        $records = @()
        try { $records = @(Get-RouteRepairHistory) } catch { Write-Log ('读取处理记录失败：' + $_.Exception.Message) 'warn' }
        foreach ($record in $records) {
            $state = if ($record.Restored) { '已撤销' } elseif ($record.Verified) { '已应用' } elseif ($record.Applied) { '部分生效' } else { '未生效' }
            $typeName = switch ([string]$record.Type) { 'InterfaceMetric' { '接口跃点' } 'ManualProxyDisable' { '手动代理' } default { [string]$record.Type } }
            $when = [string]$record.SavedAt
            try { $when = ([datetime]$record.SavedAt).ToString('MM-dd HH:mm:ss') } catch { }
            $record | Add-Member NoteProperty Display ($when + ' · ' + $typeName + ' · ' + $state) -Force
            [void]$repairHistoryList.Items.Add($record)
        }
    } finally {
        $repairHistoryList.EndUpdate()
    }
    $bUndoRepair.Enabled = $false
    $bViewBackup.Enabled = ($repairHistoryList.Items.Count -gt 0)
}

function Invoke-RepairScan {
    if ($script:busy) { return }
    Set-Busy $true
    $lbRepairSummary.Text = '正在扫描（只读，约 2 秒）…'
    $lbRepairSummary.ForeColor = [System.Drawing.Color]::FromArgb(0xE6,0xE8,0xEB)
    [Windows.Forms.Application]::DoEvents()
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        Write-Log '扫描逐项处理项 …' 'dim'
        $report = Get-RouteGuardReport
        $watch.Stop()
        Update-RepairItems $report $watch.ElapsedMilliseconds
        Update-RepairHistory
        Write-Log ('扫描完成：' + [string]@($script:repairChecks).Count + ' 项可处理，' + [string]$repairHistoryList.Items.Count + ' 条历史记录') 'ok'
    } catch {
        $watch.Stop()
        Write-Log ('扫描失败：' + $_.Exception.Message) 'err'
        $lbRepairSummary.Text = '扫描失败：' + $_.Exception.Message + '（详细原因见「更多工具」的运行日志）'
        $lbRepairSummary.ForeColor = [System.Drawing.Color]::FromArgb(0xF8,0x71,0x71)
    } finally {
        Set-Busy $false
    }
}

function Invoke-ApplyRepairs {
    $selected = @($script:repairChecks | Where-Object { $_.Checked })
    if ($selected.Count -eq 0) { Write-Log '先勾选要处理的项。' 'warn'; return }
    $needAdmin = (@($selected | Where-Object { $_.Tag.RequiresAdmin }).Count -gt 0)
    if ($needAdmin -and -not (Test-AdminAccess)) { return }
    $confirm = [Windows.Forms.MessageBox]::Show(('将处理 ' + [string]$selected.Count + ' 项。每项先写备份再写入，改完读回复检。继续？'), '逐项处理', 'YesNo', 'Question')
    if ($confirm -ne 'Yes') { return }
    Set-Busy $true
    $okCount = 0
    $failCount = 0
    try {
        foreach ($check in $selected) {
            $item = $check.Tag
            Write-Log ('处理：' + $item.Title) 'dim'
            $res = Invoke-RouteRepairItem -Item $item
            if ($res.Ok) {
                $okCount++
                Write-Log '  已应用并复检通过。' 'ok'
            } else {
                $failCount++
                $msg = if ($res.Error) { $res.Error } else { '写入后复检未通过' }
                Write-Log ('  未完成：' + $msg) 'err'
            }
            if ($res.RecordPath) { Write-Log ('  记录：' + $res.RecordPath) 'dim' }
        }
    } catch {
        Write-Log ('处理失败：' + $_.Exception.Message) 'err'
    } finally {
        Set-Busy $false
    }
    Write-Log ('处理结束：成功 ' + [string]$okCount + ' 项，未完成 ' + [string]$failCount + ' 项') $(if ($failCount -gt 0) { 'warn' } else { 'ok' })
    Update-RepairHistory
    try { Update-RepairItems (Get-RouteGuardReport) } catch { }
}

function Invoke-UndoRepair {
    if ($repairHistoryList.SelectedIndex -lt 0) { Write-Log '先在下方记录里选中一条。' 'warn'; return }
    $record = $repairHistoryList.SelectedItem
    if (-not $record -or -not $record.RecordPath) { return }
    if ($record.Restored) { Write-Log '这条记录已经撤销过。' 'warn'; return }
    if ([Windows.Forms.MessageBox]::Show('按这条记录把该项恢复到修改前的值？只影响这一项。', '撤销逐项处理', 'YesNo', 'Question') -ne 'Yes') { return }
    Set-Busy $true
    try {
        $res = Undo-RouteRepairItem -RecordPath $record.RecordPath
        if ($res.Ok) { Write-Log '已恢复并复检通过。' 'ok' }
        else { Write-Log ('撤销未完成：' + $res.Error) 'err' }
    } catch {
        Write-Log ('撤销失败：' + $_.Exception.Message) 'err'
    } finally {
        Set-Busy $false
    }
    Update-RepairHistory
}

function Invoke-OpenRepairRecord {
    $record = $repairHistoryList.SelectedItem
    $path = if ($record -and $record.RecordPath) { [string]$record.RecordPath } else { Join-Path $script:DataRoot 'runtime' }
    if (-not (Test-Path -LiteralPath $path)) { Write-Log ('找不到：' + $path) 'warn'; return }
    try { Start-Process -FilePath $path } catch { Write-Log ('无法打开：' + $_.Exception.Message) 'err' }
}

function Format-CrashReport {
    param($Exception)
    $ex = $Exception
    if ($ex -is [System.Management.Automation.ErrorRecord]) { $ex = $ex.Exception }
    $versionText = if ($script:AppVersion) { [string]$script:AppVersion } else { '未知' }
    $lines = @()
    $lines += '校园网工具箱 崩溃报告'
    $lines += ('版本: v' + $versionText)
    $lines += ('时间: ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))
    $lines += ('系统: ' + [Environment]::OSVersion.VersionString)
    try { $lines += ('PowerShell: ' + $PSVersionTable.PSVersion.ToString()) } catch { }
    $lines += ''
    if (-not $ex) {
        $lines += '异常对象为空，可能是脚本层错误（见运行日志）。'
        return ($lines -join "`r`n")
    }
    $current = $ex
    $depth = 0
    while ($current -and $depth -lt 4) {
        if ($depth -gt 0) { $lines += '--- 内部异常 ---' }
        $lines += ('类型: ' + $current.GetType().FullName)
        $lines += ('消息: ' + [string]$current.Message)
        if ($current.StackTrace) {
            $lines += '堆栈:'
            $lines += [string]$current.StackTrace
        }
        $current = $current.InnerException
        $depth++
    }
    return ($lines -join "`r`n")
}

function Write-CrashReport {
    param($Exception)
    $text = Format-CrashReport $Exception
    $path = ''
    try {
        $dir = Join-Path $script:DataRoot 'runtime\crash'
        [void][IO.Directory]::CreateDirectory($dir)
        $path = Join-Path $dir ('crash-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,4) + '.txt')
        [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($true)))
    } catch { }
    return [pscustomobject]@{ Text = $text; Path = $path }
}

function Show-CrashDialog {
    param($Report)
    if (-not $Report) { return }
    if ($script:crashDialogOpen) { return }
    $script:crashDialogOpen = $true
    try {
        $w = New-Object System.Windows.Forms.Form
        $w.Icon = $form.Icon
        $w.Text = '程序遇到错误'
        $w.Size = New-Object System.Drawing.Size(660, 520)
        $w.StartPosition = 'CenterParent'
        $w.FormBorderStyle = 'FixedDialog'
        $w.MaximizeBox = $false
        $w.MinimizeBox = $false
        $w.BackColor = $C.Bg
        $w.ForeColor = $C.Text
        $w.Font = New-Object System.Drawing.Font('Microsoft YaHei UI',9)

        $lInfo = New-Object System.Windows.Forms.Label
        $lInfo.Text = '程序遇到未处理的错误。报告只包含版本、异常和堆栈，不含网络配置。' + "`r`n" + '已保存到：' + $Report.Path
        $lInfo.ForeColor = [System.Drawing.Color]::FromArgb(0xFB,0xBF,0x24)
        $lInfo.Location = New-Object System.Drawing.Point(16, 12)
        $lInfo.Size = New-Object System.Drawing.Size(612, 44)
        $w.Controls.Add($lInfo)

        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Multiline = $true
        $tb.ReadOnly = $true
        $tb.ScrollBars = 'Vertical'
        $tb.WordWrap = $false
        $tb.Location = New-Object System.Drawing.Point(16, 60)
        $tb.Size = New-Object System.Drawing.Size(612, 340)
        $tb.BackColor = $C.Card
        $tb.ForeColor = $C.Text
        $tb.BorderStyle = 'FixedSingle'
        $tb.Font = New-Object System.Drawing.Font('Consolas',9)
        $tb.Text = $Report.Text
        $w.Controls.Add($tb)

        $bCopy = New-DialogButton $w '复制详情' 16 418 120
        $bSend = New-DialogButton $w '上报给开发者' 148 418 140
        $bSend.BackColor = $C.Accent
        $bSend.Tag = $C.Accent
        $bClose = New-DialogButton $w '关闭' 540 418 88

        $bCopy.Add_Click({
            try { [Windows.Forms.Clipboard]::SetText($Report.Text); $bCopy.Text = '已复制' } catch { }
        })
        $bSend.Add_Click({
            try { [Windows.Forms.Clipboard]::SetText($Report.Text) } catch { }
            $bodyText = $Report.Text
            if ($bodyText.Length -gt 700) { $bodyText = $bodyText.Substring(0,700) + "`r`n…（完整报告已复制到剪贴板）" }
            $firstLine = ''
            foreach ($line in ($Report.Text -split "`r?`n")) {
                if ($line -like '消息:*') { $firstLine = $line.Substring(3).Trim(); break }
            }
            if ($firstLine.Length -gt 60) { $firstLine = $firstLine.Substring(0,60) }
            $titleText = '[崩溃] v' + [string]$script:AppVersion + ' ' + $firstLine
            $url = 'https://github.com/Killin777/campus-net-toolkit/issues/new?title=' + [Uri]::EscapeDataString($titleText) + '&body=' + [Uri]::EscapeDataString($bodyText)
            try { Start-Process $url; $bSend.Text = '已打开浏览器' } catch { }
        })
        $bClose.Add_Click({ $w.Close() })
        if ($script:captureCrash) {
            if (-not ('W2.Gdi' -as [type])) {
                Add-Type -Namespace W2 -Name Gdi -MemberDefinition '[DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint f);'
            }
            $w.Show()
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 500
            [System.Windows.Forms.Application]::DoEvents()
            $bmp = New-Object System.Drawing.Bitmap($w.Width, $w.Height)
            $gfx = [System.Drawing.Graphics]::FromImage($bmp)
            $hdc = $gfx.GetHdc()
            $ok = [W2.Gdi]::PrintWindow($w.Handle, $hdc, 2)
            $gfx.ReleaseHdc($hdc)
            $gfx.Dispose()
            if (-not $ok) { $w.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $w.Width, $w.Height))) }
            $bmp.Save($script:capturePath, [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
            $w.Close()
            $w.Dispose()
            Write-Host "已保存: $($script:capturePath) (PrintWindow=$ok)"
            return
        }
        [void]$w.ShowDialog()
    } finally {
        $script:crashDialogOpen = $false
    }
}

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
        $waitMs = if ($env:CAMPUS_NET_CAPTURE_WAIT) { [int]$env:CAMPUS_NET_CAPTURE_WAIT } else { 600 }
        $deadline = (Get-Date).AddMilliseconds($waitMs)
        while ((Get-Date) -lt $deadline) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
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

# ---------- 后台任务：耗时操作不阻塞界面 ----------
$script:uiWork = $null

function Start-UiTask {
    param(
        [Parameter(Mandatory=$true)][string]$Title,
        [Parameter(Mandatory=$true)][scriptblock]$Code,
        [scriptblock]$Completed
    )
    # 同一时刻只允许一个写操作任务，避免并发修改互相打架
    if ($script:uiWork) { return }
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($Code.ToString())
    $handle = $ps.BeginInvoke()
    $script:uiWork = [pscustomobject]@{
        Title      = $Title
        PowerShell = $ps
        Handle     = $handle
        Completed  = $Completed
        Started    = Get-Date
    }
    try { Set-Busy $true } catch { }
    try { Write-Log ("开始后台任务：" + $Title) 'dim' } catch { }
}

function Receive-UiTask {
    if (-not $script:uiWork) { return }
    $work = $script:uiWork
    if (-not $work.Handle.IsCompleted) { return }
    $result = $null
    try {
        $out = $work.PowerShell.EndInvoke($work.Handle)
        if ($out -and $out.Count -gt 0) { $result = $out[-1] }
    } catch {
    } finally {
        try { $work.PowerShell.Dispose() } catch { }
    }
    $script:uiWork = $null
    try { Set-Busy $false } catch { }
    try { Write-Log ("后台任务完成：" + $work.Title) 'ok' } catch { }
    try { if ($work.Completed) { & $work.Completed $result } } catch { }
    try { Request-StatusRefresh } catch { }
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

    # ---- 后台监测器：1 秒读一次快照，探测都在后台 runspace 里做 ----
    $script:monitor = $null
    $script:monitorBusy = $false
    $script:historyAt = [datetime]::MinValue
    $script:monitorErrAt = [datetime]::MinValue
    $script:monitorUiTimer = New-Object System.Windows.Forms.Timer
    $script:monitorUiTimer.Interval = 1000
    $script:monitorUiTimer.Add_Tick({ Update-NetworkMonitorUi; Update-LayerUi; Update-DetailUi; Receive-UpdateCheck })
    $script:monitorUiTimer.Start()

    $bPrimary.Add_Click({
        try { Request-NetworkMonitorRefresh -Monitor $script:monitor -Full } catch { }
        if ($lbConclusion) { $lbConclusion.Text = '正在完整检测…' }
        if ($lbConclusionDetail) { $lbConclusionDetail.Text = '已请求完整检测，结果会自动更新，界面可继续使用。' }
    })
    $bRefresh.Add_Click({ try { Request-NetworkMonitorRefresh -Monitor $script:monitor } catch { } })
    $bDetails.Add_Click({ Show-Page 1 })

    # 有线检查：复用最近一次后台快照，点击时不重新探测
    $bWiredHome.Add_Click({
        if (-not $script:lastSnapshot) { Write-Log '还没有网络快照，先点「重新检测」。' 'warn'; return }
        try {
            $report = Get-WiredConnectionReport -Snapshot $script:lastSnapshot
            foreach ($line in @($report.Lines)) { Write-Log ('  ' + $line) 'dim' }
            if (-not $report.Applicable) { Write-Log '当前出口不是有线以太网，报告仅作说明。' 'warn' }
            elseif ($report.StatisticsKnown) { Write-Log '有线统计已读取。' 'ok' }
        } catch { Write-Log ('有线检查失败：' + $_.Exception.Message) 'err' }
    })
$bOpt.Add_Click({ Invoke-CampusCheck })
$bDns.Add_Click({ if (Test-AdminAccess) { Set-Busy $true; try { Invoke-DnsOptimize } catch { Write-Log $_.Exception.Message 'err' } finally { Set-Busy $false } } })
$bLatency.Add_Click({ Invoke-LatencyTest })
$bScanRepairs.Add_Click({ Invoke-RepairScan })
$bApplyRepairs.Add_Click({ Invoke-ApplyRepairs })
$bUndoRepair.Add_Click({ Invoke-UndoRepair })
$bViewBackup.Add_Click({ Invoke-OpenRepairRecord })
    $bProxy.Add_Click({ Open-CampusLogin })
$bReport.Add_Click({ Invoke-ExportReport })
$restoreMenu=New-Object Windows.Forms.ContextMenuStrip
$restoreModeItem=$restoreMenu.Items.Add('还原代理 / 使用模式')
$restoreModeItem.Add_Click({ if ([Windows.Forms.MessageBox]::Show('将按保存的记录还原代理、DNS、服务、电源与无线参数。继续？','还原代理 / 使用模式','YesNo','Question') -eq 'Yes') { Invoke-ModeFile 'restore' } })
$restoreNetworkItem=$restoreMenu.Items.Add('恢复网络备份…')
$restoreNetworkItem.Add_Click({ Invoke-RestoreBackup })
$bRestore.Add_Click({ $restoreMenu.Show($bRestore,(New-Object Drawing.Point(0,$bRestore.Height))) })
$bTimeline.Add_Click({ Show-TimelineWindow })
$bSettings.Add_Click({ Show-SettingsWindow })

# 系统代理：一个按钮 + 菜单，状态写在按钮文字上
$proxyMenu = New-Object Windows.Forms.ContextMenuStrip
$proxyOnItem = $proxyMenu.Items.Add('验证并开启系统代理')
$proxyOnItem.Add_Click({ Invoke-ModeFile 'proxy' })
$proxyOffItem = $proxyMenu.Items.Add('只关闭手动系统代理')
$proxyOffItem.Add_Click({ Invoke-ModeFile 'direct' })
$proxyClientItem = $proxyMenu.Items.Add('打开代理软件')
$proxyClientItem.Add_Click({ Invoke-ModeFile 'open-client' })
$bSystemProxy.Add_Click({ $proxyMenu.Show($bSystemProxy,(New-Object Drawing.Point(0,$bSystemProxy.Height))) })

# 网络急救：一键急救 / 只重连 Wi-Fi / 恢复自动 DNS
$rescueMenu = New-Object Windows.Forms.ContextMenuStrip
$rescueRunItem = $rescueMenu.Items.Add('一键急救…（清理代理 / 刷 DNS / 续租）')
$rescueRunItem.Add_Click({ if (Test-AdminAccess) { Invoke-Rescue } })
$rescueWifiItem = $rescueMenu.Items.Add('只重连当前 Wi-Fi')
$rescueWifiItem.Add_Click({ Invoke-ReconnectWifi })
$rescueDnsItem = $rescueMenu.Items.Add('恢复当前网卡自动 DNS…')
$rescueDnsItem.Add_Click({ Invoke-ResetCurrentDns })
$bRescue.Add_Click({ $rescueMenu.Show($bRescue,(New-Object Drawing.Point(0,$bRescue.Height))) })

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
    foreach ($activeTimer in @($timer,$script:wifiTimer,$script:monitorUiTimer,$script:autoCloseTimer)) { if ($activeTimer) { $activeTimer.Stop(); $activeTimer.Dispose() } }
    try { if ($script:monitor) { Stop-NetworkMonitor -Monitor $script:monitor } } catch { }
    $restoreMenu.Dispose()
    try { $proxyMenu.Dispose() } catch { }
    try { $rescueMenu.Dispose() } catch { }
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
    try { Update-RepairHistory } catch { }

    # 启动后台监测器（只读；失败时记录到日志，不影响界面）
    try {
        $script:monitor = New-NetworkMonitor -ProjectRoot $script:ProjRoot -DataRoot $script:DataRoot
        Request-NetworkMonitorRefresh -Monitor $script:monitor -Full
    } catch {
        try { Write-Log ('后台监测启动失败：' + $_.Exception.Message) 'err' } catch { }
    }
    try { Show-FirstRunHints } catch { }

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
    # 检查新版本（默认开启，可在设置里关闭；只读，连不上 GitHub 就跳过）
    try {
        $updateSettings = Read-ProxySettings
        $checkUpdates = $true
        if ($updateSettings -and $updateSettings.ContainsKey('checkUpdates')) { $checkUpdates = [bool]$updateSettings['checkUpdates'] }
        if ($checkUpdates) { Start-UpdateCheck }
    } catch { }
    # 不再自动探测校园网：登录交给默认浏览器（点「校园网登录」按钮）
    if ($AutoClose) {
        # 自测用：1.2 秒后自动关窗，用于验证关闭后进程是否退出
        $script:autoCloseTimer = New-Object System.Windows.Forms.Timer
        $script:autoCloseTimer.Interval = 1200
        $script:autoCloseTimer.Add_Tick({ $script:autoCloseTimer.Stop(); $form.Close() })
        $script:autoCloseTimer.Start()
    }
})

# 预览数据：只给 -Screenshot 出图用，不发请求、不改系统
function New-PreviewState {
    param([string]$Scenario)
    $now = Get-Date
    $connected = ($Scenario -ne 'Offline')
    $info = [ordered]@{
        SSID = 'CampusNet'; Band = '5 GHz'; Channel = '149'; Signal = '82%'; Rssi = '-58 dBm'
        IP = '192.0.2.88'; Gateway = '192.0.2.1'; DNS = '192.0.2.53, 223.5.5.5'
        Adapter = 'WLAN'; Link = '866 Mbps'; ProxyOn = $false; ProxyPort = $false
        ProxyNum = 7897; ProxyKnown = $true; ProxyEndpoint = ''; PacUrl = ''
        ConnectionType = 'Wireless'; InterfaceIndex = 12; LinkSpeedMbps = 866
    }
    $connection = [pscustomobject]@{
        Known = $true; Connected = $connected; CheckedAt = $now; ConnectionType = 'Wireless'
        Detail = $(if ($connected) { '已识别的物理网卡处于连接状态；这不证明外网可用。' } else { '已识别的物理接口均未连接；虚拟网卡状态未用于证明物理在线。' })
    }
    $proxyEnabled = ($Scenario -eq 'ProxyIssue')
    $proxy = [pscustomobject]@{
        Known = $true; Enabled = $proxyEnabled; Alive = $false; IsLocal = $true; TargetKnown = $true
        Port = 7897; Host = '127.0.0.1'; CheckedAt = $now
        Detail = $(if ($proxyEnabled) { '实际本机代理目标端口没有监听。' } else { '手动系统代理已关闭；不代表所有应用均为直连。' })
    }
    $ping = [pscustomobject]@{
        Known = $connected; Success = $connected; Milliseconds = 4; CheckedAt = $now
        Detail = '网关回应ICMP；不代表互联网可用。'
    }
    $script:lastSnapshot = [pscustomobject]@{
        Info = $info; Connection = $connection; Proxy = $proxy; GatewayPing = $ping
        CheckedAt = $now; Errors = @(); Quality = $null
    }
    $dnsState = 'Ok'; $domState = 'Ok'; $intlState = 'Ok'
    if ($Scenario -in @('NeedsAuth','Unknown','Offline')) { $dnsState = 'Unknown'; $domState = 'Unknown' }
    if ($Scenario -in @('ExternalFailure','Unknown','Offline')) { $intlState = 'Unknown' }
    if ($Scenario -eq 'NeedsAuth') { $dnsState = 'Ok'; $domState = 'Fail' }
    if ($Scenario -eq 'ExternalFailure') { $intlState = 'Fail' }
    $script:layerCache = [pscustomobject]@{
        Dns = New-LayerState -State $dnsState -Detail $(if ($dnsState -eq 'Ok') { '国内外域名均可解析' } else { '域名解析失败' }) -At $now
        Domestic = New-LayerState -State $domState -Detail $(if ($domState -eq 'Fail') { '国内 2/3 通过（腾讯 失败）' } else { '国内 3/3 通过' }) -At $now -Passed 3 -Total 3 -Endpoints @(
            [pscustomobject]@{ Name='小米'; Url='http://connect.rom.miui.com/generate_204'; Ok=$true; Ms=12 }
            [pscustomobject]@{ Name='百度'; Url='https://www.baidu.com'; Ok=$true; Ms=15 }
            [pscustomobject]@{ Name='腾讯'; Url='http://www.qq.com'; Ok=($domState -ne 'Fail'); Ms=$(if ($domState -eq 'Fail') { -1 } else { 18 }) }
        )
        Intl = New-LayerState -State $intlState -Detail $(if ($intlState -eq 'Fail') { '国际探测点全部失败' } else { '国际 2/2 通过' }) -At $now -Endpoints @(
            [pscustomobject]@{ Name='cloudflare'; Url='https://www.cloudflare.com/cdn-cgi/trace'; Ok=($intlState -eq 'Ok'); Ms=$(if ($intlState -eq 'Ok') { 210 } else { -1 }) }
            [pscustomobject]@{ Name='google'; Url='https://www.google.com/generate_204'; Ok=($intlState -eq 'Ok'); Ms=$(if ($intlState -eq 'Ok') { 305 } else { -1 }) }
        )
        At = $now
    }
}

# 预览用路由报告：只给 -Repairs -Screenshot 出图用，不读取也不修改系统
function New-PreviewRepairReport {
    [pscustomobject]@{
        MetricCandidates = @([pscustomobject]@{
            InterfaceIndex = 11; InterfaceAlias = 'VPN 虚拟网卡'
            InterfaceMetric = 5; AutomaticMetric = 'Enabled'
            HardwareVirtual = $true; HasRoute = $true; Competing = $true
            RouteMetric = 1; RouteCost = 6
            PhysicalInterfaceIndex = 22; PhysicalInterfaceAlias = 'WLAN'; PhysicalCost = 26
        })
        ProxyEvidence = [pscustomobject]@{ ManualDisableSupported = $true }
        SystemProxy = [pscustomobject]@{ ProxyEnableExists = $true; ProxyEnableValue = 1; Enabled = $true; Server = '127.0.0.1:7897' }
    }
}

if ($Screenshot) {
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    # -Details / -Repairs / -Tools 与 -Screenshot 组合，用于抓取非首页的界面
    if ($PreviewScenario) {
        $script:monitorUiTimer.Stop()
        New-PreviewState $PreviewScenario
    }
    if ($Details) { Show-Page 1 }
    elseif ($Repairs) {
        Show-Page 2
        if ($PreviewScenario) { Update-RepairItems (New-PreviewRepairReport) }
        else { Invoke-RepairScan }
    }
    elseif ($Tools) { Show-Page 3 }
    Update-Status | Out-Null
    if ($PreviewScenario) { Update-LayerUi }
    Update-DetailUi
    if ($PreviewScenario -and $Details) {
        # 出图时展开国际段，方便核对端点列表
        $script:detailSections['Intl'].Expanded = $true
        $script:detailSections['Intl'].Endpoints.Visible = $true
        Update-DetailSectionHeader 'Intl'
    }
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

if ($DnsList) {
    $script:captureDnsList = $true
    $script:capturePath = $Out
    Show-DnsListWindow
    return
}

if ($EndpointEditor) {
    $script:captureEndpoints = $true
    $script:capturePath = $Out
    Show-EndpointEditor
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

# 未处理异常：写报告 + 给「复制 / 上报」入口；后台线程只落盘
$script:crashDialogOpen = $false
try {
    $script:threadExceptionHandler = [System.Windows.Forms.ThreadExceptionEventHandler]{
        param($sender, $eventArgs)
        try { Show-CrashDialog (Write-CrashReport $eventArgs.Exception) } catch { }
    }
    [System.Windows.Forms.Application]::add_ThreadException($script:threadExceptionHandler)
    [AppDomain]::CurrentDomain.add_UnhandledException({
        param($sender, $eventArgs)
        try { [void](Write-CrashReport $eventArgs.ExceptionObject) } catch { }
    })
} catch { }

if ($CrashDemo) {
    $script:captureCrash = $true
    $script:capturePath = $Out
    Show-CrashDialog (Write-CrashReport (New-Object System.InvalidOperationException('演示：未处理的异常（截图用，不是真实错误）')))
    return
}

try {
    [void]$form.ShowDialog()
} catch {
    Show-CrashDialog (Write-CrashReport $_.Exception)
}
