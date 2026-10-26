<#
    ClashCtl.ps1  —  为“经常开关 Clash”设计的原子开关

    解决的问题：
      手动点 GUI 开关时，若 Clash 崩溃/被强杀，系统代理会残留指向 127.0.0.1:7897，
      此时 Clash 已死而浏览器仍走这个死端口 —— 表现就是“校园网突然全网打不开”。
      本脚本保证：开 = 内核就绪后才设代理；关 = 先停内核再清代理，绝不残留。

    用法：
      .\ClashCtl.ps1 on       启动 Clash Verge 并设置系统代理
      .\ClashCtl.ps1 off      停止 Clash 并清除系统代理
      .\ClashCtl.ps1 toggle   当前开着就关，关着就开
      .\ClashCtl.ps1 status   查看状态（端口 / 系统代理 / 出口 IP）
      .\ClashCtl.ps1 fix      网络急救：清残留代理 + 刷新 DNS + 检测链路
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('on', 'off', 'toggle', 'status', 'fix')]
    [string]$Action = 'status',

    [string]$VergeExe  = 'D:\Program Files\Clash Verge\clash-verge.exe',
    [int]$MixedPort    = 7897
)

$ErrorActionPreference = 'Continue'
$regPath     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$proxyServer = "127.0.0.1:$MixedPort"

# ---------- WinINET 刷新（让已开的程序立刻感知代理变化） ----------
if (-not ('Win32.WinInet' -as [type])) {
    try {
        Add-Type -Namespace Win32 -Name WinInet -MemberDefinition @'
[DllImport("wininet.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
'@ -ErrorAction Stop
    } catch { }
}
function Update-WinInet {
    if ('Win32.WinInet' -as [type]) {
        [void][Win32.WinInet]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)  # SETTINGS_CHANGED
        [void][Win32.WinInet]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)  # REFRESH
    }
}

# ---------- 基础探测 ----------
function Test-ProxyPort {
    [bool](Get-NetTCPConnection -State Listen -LocalPort $MixedPort -ErrorAction SilentlyContinue)
}
function Get-ProxyState {
    $p = Get-ItemProperty $regPath -ErrorAction SilentlyContinue
    [pscustomobject]@{
        Enabled = ($p.ProxyEnable -eq 1)
        Server  = $p.ProxyServer
    }
}
function Test-CoreAlive {
    param([int]$TimeoutSec = 45)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        if (Test-ProxyPort) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Enable-SystemProxy {
    $bypass = '<local>;localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*;*.example.edu.cn'
    Set-ItemProperty $regPath -Name ProxyServer   -Value $proxyServer
    Set-ItemProperty $regPath -Name ProxyOverride -Value $bypass
    Set-ItemProperty $regPath -Name ProxyEnable   -Value 1
    Update-WinINet
}
function Disable-SystemProxy {
    Set-ItemProperty $regPath -Name ProxyEnable -Value 0
    Update-WinINet
}

# ---------- 动作 ----------
function Invoke-On {
    if (-not (Test-Path $VergeExe)) { Write-Host "找不到 Clash Verge：$VergeExe" -ForegroundColor Red; return }

    if (-not (Test-ProxyPort)) {
        if (-not (Get-Process 'clash-verge' -ErrorAction SilentlyContinue)) {
            Write-Host '启动 Clash Verge ...' -ForegroundColor Cyan
            Start-Process -FilePath $VergeExe -WorkingDirectory (Split-Path $VergeExe) | Out-Null
        }
        Write-Host '等待内核监听 7897 ...' -ForegroundColor Cyan
        if (-not (Test-CoreAlive -TimeoutSec 45)) {
            Write-Host '内核未就绪，为安全起见不设置系统代理。请打开 Clash Verge 检查配置/订阅。' -ForegroundColor Red
            return
        }
    }
    Enable-SystemProxy
    Write-Host "已开启：系统代理 -> $proxyServer" -ForegroundColor Green
    Show-Status
}

function Stop-CoreElevated {
    # Clash Verge 开启“服务模式”时，内核 verge-mihomo.exe 是 clash-verge-service(SYSTEM) 的子进程，
    # 普通权限杀不掉，必须提权。本机 UAC 为“提权不提示”，可静默完成。
    $inner = "Get-Process 'verge-mihomo','verge-mihomo-alpha','mihomo','clash-verge' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue"
    try {
        Start-Process -FilePath 'powershell.exe' `
            -ArgumentList '-NoProfile', '-WindowStyle', 'Hidden', '-Command', $inner `
            -Verb RunAs -Wait -WindowStyle Hidden -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Invoke-Off {
    # 顺序很重要：先停内核，再清代理，绝不留下“代理指向死端口”
    $gui = Get-Process 'clash-verge' -ErrorAction SilentlyContinue
    if ($gui) {
        Write-Host '关闭 Clash Verge 界面 ...' -ForegroundColor Cyan
        $gui | ForEach-Object { [void]$_.CloseMainWindow() }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt 8 -and (Get-Process 'clash-verge' -ErrorAction SilentlyContinue)) {
            Start-Sleep -Milliseconds 300
        }
        Get-Process 'clash-verge' -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 800
    }

    if (Test-ProxyPort) {
        Write-Host '内核由服务托管，提权停止 ...' -ForegroundColor Yellow
        [void](Stop-CoreElevated)
        Start-Sleep -Seconds 1
    }

    Disable-SystemProxy

    if (Test-ProxyPort) {
        Write-Host '警告：内核仍在监听 7897，请在托盘图标右键“退出”后再执行一次' -ForegroundColor Red
    } else {
        Write-Host '已关闭：内核已停止，系统代理已清除' -ForegroundColor Green
    }
}

function Show-Status {
    $st = Get-ProxyState
    $port = Test-ProxyPort
    Write-Host "`n---------- 状态 ----------" -ForegroundColor Cyan
    Write-Host ("内核 7897 监听 : {0}" -f $(if ($port) { '是' } else { '否' })) -ForegroundColor $(if ($port) { 'Green' } else { 'DarkGray' })
    Write-Host ("系统代理       : {0}" -f $(if ($st.Enabled) { "已开启 ($($st.Server))" } else { '未开启' })) -ForegroundColor $(if ($st.Enabled) { 'Yellow' } else { 'DarkGray' })
    if ($st.Enabled -and -not $port) {
        Write-Host '  !! 检测到代理残留：系统代理开着但内核已死，所有网页都会打不开' -ForegroundColor Red
        Write-Host '     执行 .\ClashCtl.ps1 fix 清理' -ForegroundColor Yellow
    }
    if ((Get-Process 'clash-verge' -ErrorAction SilentlyContinue) -and -not $port) {
        Write-Host '  !! Clash GUI 在运行但内核未监听，可能内核启动失败' -ForegroundColor Yellow
    }
}

function Invoke-Fix {
    Write-Host '网络急救 ...' -ForegroundColor Cyan
    $st = Get-ProxyState
    $port = Test-ProxyPort
    if ($st.Enabled -and -not $port) {
        Disable-SystemProxy
        Write-Host '  已清除残留系统代理' -ForegroundColor Green
    } elseif ($st.Enabled -and $port) {
        Write-Host '  系统代理正常，无需清理' -ForegroundColor Green
    } else {
        Write-Host '  系统代理本就关闭' -ForegroundColor Green
    }
    Write-Host '  刷新 DNS 缓存 ...' -ForegroundColor Cyan
    ipconfig /flushdns | Out-Null
    Write-Host '  检查网关 ...' -ForegroundColor Cyan
    $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Where-Object { $_.InterfaceAlias -ne 'Radmin VPN' } |
            Sort-Object RouteMetric | Select-Object -First 1).NextHop
    if ($gw -and (Test-Connection -ComputerName $gw -Count 2 -Quiet -ErrorAction SilentlyContinue)) {
        Write-Host "  网关 $gw 可达" -ForegroundColor Green
    } else {
        Write-Host "  网关不可达，尝试重启 WLAN ..." -ForegroundColor Yellow
            if ([Console]::IsInputRedirected) {
                Write-Host '非交互环境，跳过网卡重启（避免无提示断网）' -ForegroundColor Yellow
            } else {
                $ans = Read-Host '即将重启无线网卡（会断网约 10 秒），继续？(y/N)'
                if ($ans -match '^(y|yes)$') { Restart-NetAdapter -Name 'WLAN' -ErrorAction SilentlyContinue }
                else { Write-Host '已跳过网卡重启' -ForegroundColor Yellow }
            }
    }
    Show-Status
}

switch ($Action) {
    'on'     { Invoke-On }
    'off'    { Invoke-Off }
    'toggle' { if (Test-ProxyPort) { Invoke-Off } else { Invoke-On } }
    'status' { Show-Status }
    'fix'    { Invoke-Fix }
}
