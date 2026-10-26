#Requires -RunAsAdministrator
<#
    Fix-WifiStability.ps1  —  校园网 WiFi 频繁掉线修复（<UNIVERSITY> <SSID>）
    用法：右键“以管理员身份运行”，或在管理员 PowerShell 中执行 .\Fix-WifiStability.ps1

    做的事情：
      1. 漫游主动性 -> 1（最低），阻止网卡在两三个 AP 之间反复横跳
      2. 首选频带 -> 2.4GHz（实测此处 2.4G 信号 -67dBm 优于 5G 边缘覆盖）
      3. 关闭 uAPSD / 数据包合并 / 断开时睡眠（这三项是掉线常见元凶）
      4. 关闭“允许计算机关闭此设备以节约电源”
      5. 电源计划：无线适配器节能 = 最高性能（交流+电池）
      6. 重启网卡使设置生效，并打印结果

    可回滚：脚本会把原值备份到同目录 wifi-backup-<时间>.json
#>

$ErrorActionPreference = 'Stop'
$adapter = 'WLAN'
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$dir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$backup  = Join-Path $dir "wifi-backup-$stamp.json"

function Write-Step($msg) { Write-Host "`n[$(Get-Date -Format 'HH:mm:ss')] $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "  √ $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "  ! $msg" -ForegroundColor Yellow }

# ---------- 0. 备份 ----------
Write-Step "备份当前网卡参数"
$keys = 'RoamAggressiveness','RoamingPreferredBandType','uAPSDSupport',
        'MIMOPowerSaveMode','PacketCoalescing','DeviceSleepOnDisconnect',
        'ChannelWidth24','ChannelWidth52'
$current = Get-NetAdapterAdvancedProperty -Name $adapter -RegistryKeyword $keys -ErrorAction SilentlyContinue |
    Select-Object RegistryKeyword, RegistryValue
$current | ConvertTo-Json | Set-Content -Path $backup -Encoding UTF8
Write-Ok "已备份到 $backup"

# ---------- 1. 网卡高级参数 ----------
Write-Step "调整网卡高级参数"
$targets = [ordered]@{
    'RoamAggressiveness'      = 0   # 0 = 最低值（Intel 驱动 0 基）；1 是"中低"，更激进
    'RoamingPreferredBandType'= 2   # 2 = 首选 2.4GHz
    'uAPSDSupport'            = 0   # 关闭 U-APSD
    'PacketCoalescing'        = 0   # 关闭数据包合并
    'DeviceSleepOnDisconnect' = 0   # 断开连接时不睡眠
    'MIMOPowerSaveMode'       = 3   # 3 = 无 SMPS
}
foreach ($kv in $targets.GetEnumerator()) {
    try {
        Set-NetAdapterAdvancedProperty -Name $adapter -RegistryKeyword $kv.Key -RegistryValue $kv.Value -NoRestart
        Write-Ok "$($kv.Key) = $($kv.Value)"
    } catch {
        Write-Warn2 "$($kv.Key) 设置失败：$($_.Exception.Message)"
    }
}

# ---------- 2. 设备电源管理 ----------
Write-Step "关闭设备节能（允许计算机关闭此设备）"
try {
    Set-NetAdapterPowerManagement -Name $adapter -AllowComputerToTurnOffDevice Disabled
    Write-Ok "已禁止系统关闭无线网卡"
} catch {
    Write-Warn2 "该驱动不支持此项：$($_.Exception.Message)"
}

# ---------- 3. 电源计划 ----------
Write-Step "电源计划：无线适配器 -> 最高性能"
$subWifi = '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1'
$setWifi = '12bbebe6-58d6-4636-95bb-3217ef867c1a'
powercfg /setacvalueindex SCHEME_CURRENT $subWifi $setWifi 0 | Out-Null
powercfg /setdcvalueindex SCHEME_CURRENT $subWifi $setWifi 0 | Out-Null
powercfg /setactive SCHEME_CURRENT | Out-Null
Write-Ok "交流/电池均设为最高性能"

# ---------- 4. 生效 ----------
Write-Step "重启无线网卡使设置生效（会短暂断网约 10 秒）"
if ([Console]::IsInputRedirected) {
    Write-Warn2 '非交互环境，跳过网卡重启'
} else {
    $ans = Read-Host '即将重启无线网卡（会断网约 10 秒），继续？(y/N)'
    if ($ans -match '^(y|yes)$') { Restart-NetAdapter -Name $adapter }
    else { Write-Warn2 '已跳过网卡重启' }
}
Start-Sleep -Seconds 10

Write-Step "当前链路状态"
netsh wlan show interfaces |
    Select-String 'SSID|BSSID|Band|Channel|Signal|Rssi|Receive rate|Transmit rate|State'

Write-Host "`n完成。若仍频繁掉线，说明是 AP 侧强制踢人/负载均衡，需向网络中心报修并附上本脚本输出。" -ForegroundColor Green
Write-Host "回滚命令：设置 -RegistryKeyword <键> -RegistryValue <备份值>，备份见 $backup" -ForegroundColor DarkGray
