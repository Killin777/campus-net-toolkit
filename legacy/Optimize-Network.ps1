#Requires -RunAsAdministrator
<#
    Optimize-Network.ps1  —  日常使用不卡顿的系统级网络调优
    右键“以管理员身份运行”，或在管理员 PowerShell 中执行

    调优内容：
      1. WLAN / 以太网 DNS 恢复为 DHCP 自动获取
         （热点下网关 DNS 只要 10ms，而静态的 <IP> 要 139ms；
           以太网上还挂着 <IP> 这种 11 秒才超时的死 DNS，会拖死解析）
      2. Radmin VPN 接口跃点 1 -> 9000，防止它抢占默认路由
      3. 传递优化改为“仅 LAN”，禁止 Windows 更新对公网做 P2P 上传
      4. 关闭 Wi-Fi Sense 的“自动连接建议热点”（减少后台扫描，降低延迟尖峰）
      5. 刷新 DNS 缓存

    所有改动前的值会备份到 network-backup-<时间>.json
#>

$ErrorActionPreference = 'Continue'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$dir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$backup = Join-Path $dir "network-backup-$stamp.json"

function Step($m) { Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  √ $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  ! $m" -ForegroundColor Yellow }

# ---------- 备份 ----------
Step '备份当前配置'
$snapshot = [ordered]@{
    时间 = (Get-Date).ToString('s')
    DNS  = @{}
    跃点 = @{}
    传递优化 = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config' -ErrorAction SilentlyContinue).DODownloadMode
}
foreach ($a in 'WLAN','以太网') {
    $snapshot.DNS[$a]  = (Get-DnsClientServerAddress -InterfaceAlias $a -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
    $snapshot.跃点[$a] = (Get-NetIPInterface -InterfaceAlias $a -AddressFamily IPv4 -ErrorAction SilentlyContinue).InterfaceMetric
}
foreach ($a in 'Radmin VPN','Tailscale') {
    $snapshot.跃点[$a] = (Get-NetIPInterface -InterfaceAlias $a -AddressFamily IPv4 -ErrorAction SilentlyContinue).InterfaceMetric
}
$snapshot | ConvertTo-Json -Depth 5 | Set-Content -Path $backup -Encoding UTF8
Ok "已备份到 $backup"

# ---------- 1. DNS 自动 ----------
Step 'DNS 恢复为 DHCP 自动获取'
foreach ($a in 'WLAN','以太网') {
    if (Get-NetAdapter -Name $a -ErrorAction SilentlyContinue) {
        Set-DnsClientServerAddress -InterfaceAlias $a -ResetServerAddresses -ErrorAction SilentlyContinue
        $now = (Get-DnsClientServerAddress -InterfaceAlias $a -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
        if ($now) { Ok "$a -> $($now -join ', ')" } else { Ok "$a -> 自动（当前无地址）" }
    }
}

# ---------- 2. 路由跃点 ----------
Step '整理虚拟网卡跃点（防止抢默认路由）'
$metric = @{ 'Radmin VPN' = 9000 }
foreach ($k in $metric.Keys) {
    try {
        Set-NetIPInterface -InterfaceAlias $k -AddressFamily IPv4 -InterfaceMetric $metric[$k] -ErrorAction Stop
        Ok "$k 跃点 -> $($metric[$k])"
    } catch {
        Warn "$k 设置失败：$($_.Exception.Message)"
    }
}

# ---------- 3. 传递优化 ----------
Step '传递优化改为“仅 LAN”'
try {
    $doPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config'
    if (-not (Test-Path $doPath)) { New-Item -Path $doPath -Force | Out-Null }
    Set-ItemProperty -Path $doPath -Name DODownloadMode -Value 1 -Type DWord -ErrorAction Stop
    Ok '已限制为仅 LAN 下载（关闭公网 P2P 上传）'
} catch {
    Warn "设置失败：$($_.Exception.Message)"
}

# ---------- 4. Wi-Fi Sense ----------
Step '关闭 Wi-Fi Sense 自动连接建议热点'
$wifiSense = 'HKCU:\Software\Microsoft\WcmSvc\wifinetworkmanager\config'
if (Test-Path $wifiSense) {
    Set-ItemProperty -Path $wifiSense -Name WiFiSenseCredShared -Value 0 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $wifiSense -Name WiFiSenseOpen      -Value 0 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $wifiSense -Name AutoConnectAllowedOEM -Value 0 -Type DWord -ErrorAction SilentlyContinue
    Ok '已关闭（减少后台扫描）'
} else {
    Warn '该系统无此注册表键（Win11 已移除 Wi-Fi Sense），跳过'
}

# ---------- 5. 刷新 ----------
Step '刷新 DNS 缓存'
ipconfig /flushdns | Out-Null
Ok '已刷新'

# ---------- 汇总 ----------
Step '调优后状态'
Get-DnsClientServerAddress -AddressFamily IPv4 |
    Where-Object { $_.InterfaceAlias -in 'WLAN','以太网' } |
    Format-Table InterfaceAlias,ServerAddresses -AutoSize | Out-String -Width 100 | Write-Host
Get-NetIPInterface -AddressFamily IPv4 |
    Where-Object { $_.InterfaceAlias -in 'WLAN','以太网','Radmin VPN','Tailscale' } |
    Sort-Object InterfaceMetric |
    Format-Table InterfaceAlias,InterfaceMetric -AutoSize | Out-String -Width 60 | Write-Host

Write-Host "`n完成。回滚数据见 $backup" -ForegroundColor Green
