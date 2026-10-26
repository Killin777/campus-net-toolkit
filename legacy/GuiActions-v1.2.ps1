#Requires -Version 5.1
# 旧主界面操作，仅保留参考。当前 GUI 已由只读校园网检查替代这些入口。
# 替代入口与维护方法见 ../docs/architecture.md。

function Invoke-Optimize {
    Set-Busy $true
    try {
        Write-Log '=== 一键优化开始 ===' 'dim'

        try {
            $bk = New-NetBackup
            Write-Log ("已备份当前网络设置：{0}" -f [System.IO.Path]::GetFileName($bk)) 'dim'
        } catch {
            Write-Log ("备份失败，放弃优化：$($_.Exception.Message)") 'err'
            return
        }

        Invoke-DnsOptimize -FromOptimize

        Write-Log '整理虚拟网卡跃点 ...' 'dim'
        foreach ($pair in @(@{N = 'Radmin VPN'; M = 9000 }, @{N = 'Tailscale'; M = 5000 })) {
            if (Get-NetAdapter -Name $pair.N -ErrorAction SilentlyContinue) {
                try {
                    Set-NetIPInterface -InterfaceAlias $pair.N -AddressFamily IPv4 -InterfaceMetric $pair.M -ErrorAction Stop
                    Write-Log ("  {0} 跃点 → {1}" -f $pair.N, $pair.M) 'ok'
                } catch { Write-Log ("  {0} 设置失败" -f $pair.N) 'warn' }
            }
        }

        Write-Log '限制 Windows 更新 P2P 上传 ...' 'dim'
        try {
            $doPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config'
            if (-not (Test-Path $doPath)) { New-Item -Path $doPath -Force | Out-Null }
            Set-ItemProperty -Path $doPath -Name DODownloadMode -Value 1 -Type DWord -ErrorAction Stop
            Write-Log '  传递优化 → 仅 LAN' 'ok'
        } catch { Write-Log '  传递优化设置失败' 'warn' }

        Write-Log '刷新 DNS 与 ARP 缓存 ...' 'dim'
        ipconfig /flushdns | Out-Null
        Write-Log '  完成' 'ok'

        Write-Log '=== 一键优化完成 ===' 'ok'
        Update-Status | Out-Null
    } catch {
        Write-Log "优化出错：$($_.Exception.Message)" 'err'
    } finally { Set-Busy $false }
}

function Invoke-LowLatency {
    $svcs = @('wuauserv', 'DoSvc')
    if (-not $script:lowLatOn) {
        foreach ($s in $svcs) {
            $svc = Get-Service $s -ErrorAction SilentlyContinue
            if ($svc) {
                $script:savedSvc[$s] = $svc.StartType
                try {
                    if ($svc.Status -eq 'Running') { Stop-Service $s -Force -ErrorAction SilentlyContinue }
                    Set-Service $s -StartupType Manual -ErrorAction SilentlyContinue
                    Write-Log ("  暂停 {0}" -f $s) 'ok'
                } catch { Write-Log ("  {0} 处理失败" -f $s) 'warn' }
            }
        }
        $script:lowLatOn = $true
        Write-Log '低延迟模式已开启：Windows 更新与传递优化暂时不再抢带宽' 'ok'
        Write-Log '（重启后自动恢复，也可再点一次本按钮恢复）' 'dim'
    } else {
        foreach ($s in $svcs) {
            $svc = Get-Service $s -ErrorAction SilentlyContinue
            if ($svc) {
                $orig = if ($script:savedSvc.ContainsKey($s)) { $script:savedSvc[$s] } else { 'Manual' }
                try {
                    Set-Service $s -StartupType $orig -ErrorAction SilentlyContinue
                    if ($s -eq 'wuauserv') { Start-Service $s -ErrorAction SilentlyContinue }
                    Write-Log ("  恢复 {0}" -f $s) 'ok'
                } catch { Write-Log ("  {0} 恢复失败" -f $s) 'warn' }
            }
        }
        $script:lowLatOn = $false
        Write-Log '低延迟模式已关闭，服务恢复原状' 'ok'
    }
    Update-Status | Out-Null
}

function New-GuiNetBackup { return (New-NetBackup) }
