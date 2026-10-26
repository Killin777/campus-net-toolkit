#Requires -RunAsAdministrator
# 修正漫游参数：Intel 驱动的值是 0 基，0 = 最低值
# 只改注册表、不重启网卡，避免打断正在进行的游戏/下载；下次重连自动生效

$ErrorActionPreference = 'Continue'

Write-Host '修改前：'
Get-NetAdapterAdvancedProperty -Name 'WLAN' |
    Where-Object RegistryKeyword -in 'RoamAggressiveness','RoamingPreferredBandType','ChannelWidth24','uAPSDSupport','MIMOPowerSaveMode' |
    Select-Object DisplayName, RegistryValue, DisplayValue | Format-Table -AutoSize | Out-String -Width 100 | Write-Host

# 0 = 1.最低值（最不激进，减少主动漫游与频段漂移）
Set-NetAdapterAdvancedProperty -Name 'WLAN' -RegistryKeyword 'RoamAggressiveness' -RegistryValue 0 -NoRestart
Write-Host '√ 漫游主动性 -> 0（最低值）' -ForegroundColor Green

# 2.4GHz 固定 20MHz：热点/拥挤频段下 40MHz 会大幅增加重传，稳定优先
Set-NetAdapterAdvancedProperty -Name 'WLAN' -RegistryKeyword 'ChannelWidth24' -RegistryValue 0 -NoRestart
Write-Host '√ 2.4GHz 信道宽度 -> 20MHz（减少重传）' -ForegroundColor Green

Write-Host "`n修改后："
Get-NetAdapterAdvancedProperty -Name 'WLAN' |
    Where-Object RegistryKeyword -in 'RoamAggressiveness','ChannelWidth24' |
    Select-Object DisplayName, RegistryValue, DisplayValue | Format-Table -AutoSize | Out-String -Width 100 | Write-Host

Write-Host '注意：参数在下次无线重连后生效，本次不重启网卡以免断线。' -ForegroundColor Yellow
