<#
    ModeCtl.ps1  —  三种使用模式的一键切换

      模式 1「国内直连」：关系统代理、DNS 回自动、检查有没有 TUN/VPN 抢路由
      模式 2「开启代理」：验证代理 → 开系统代理 → 可一键打开客户端界面
      模式 3「游戏优化」：停后台更新、高性能电源、关网卡省电、避免代理绕路

    设计原则：每一步都返回「做了什么 / 成功没有 / 为什么」，
    失败不静默；所有改动记录到 mode-state.json，支持一键还原。

    用法：
      .\ModeCtl.ps1 direct
      .\ModeCtl.ps1 proxy
      .\ModeCtl.ps1 game
      .\ModeCtl.ps1 restore
      .\ModeCtl.ps1 status
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('direct', 'proxy', 'game', 'restore', 'status', 'open-client')]
    [string]$Action = 'status',
    [switch]$Yes
)

$ErrorActionPreference = 'Continue'
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ProjRoot = Split-Path -Parent $script:Root

# 共享工具函数（文本宽度、输出、Ping、维护窗口）
. (Join-Path $PSScriptRoot 'lib\Common.ps1')
$script:StatePath = Join-Path $script:DataRoot 'runtime\mode-state.json'

# 复用代理探测/验证能力（-NoRun 表示只加载函数、不执行动作）
# 注意：点源的脚本会把它自己的 param 写进当前作用域，必须先存后恢复，
# 否则 ProxyCtl 的 $Action='verify' 会覆盖本脚本的 $Action。
$__savedAction = $Action
$__proxyScript = Join-Path $script:Root 'ProxyCtl.ps1'
if (-not (Test-Path $__proxyScript)) { throw "缺少依赖：$__proxyScript" }
. $__proxyScript -NoRun
$Action = $__savedAction

$script:isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ============================ 状态存取 ============================
function Get-ModeState {
    $s = $null
    if (Test-Path $script:StatePath) {
        try { $s = Get-Content $script:StatePath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
        catch { throw '模式记录无法解析，已停止操作并保留原文件；请先检查数据目录中的 mode-state.json' }
    }
    # JSON 顶层是数组、或是字符串/数字时也按"无有效记录"处理
    if ($s -is [array] -or $s -is [string] -or $s -is [ValueType]) { throw '模式记录不是 JSON 对象，已停止操作并保留原文件' }
    if (-not $s) {
        $s = [pscustomobject]@{ activeMode = ''; savedServices = [pscustomobject]@{}; savedPowerPlan = ''; savedPac = ''; savedTime = '' }
    }
    # 手改/旧版文件可能缺键；直接赋值会抛 "property cannot be found"，还原流程必须能容错
    foreach ($k in 'activeMode', 'savedPowerPlan', 'savedPac', 'savedTime') {
        if (-not $s.PSObject.Properties[$k]) { $s | Add-Member -NotePropertyName $k -NotePropertyValue '' -Force }
    }
    # savedServices 可能是 hashtable 也可能是 PSCustomObject，统一成对象，避免 .PSObject.Properties 取到字典自身属性
    if ($null -eq $s.savedServices) { $s | Add-Member -NotePropertyName savedServices -NotePropertyValue ([pscustomobject]@{}) -Force }
    elseif ($s.savedServices -is [hashtable]) {
        $s | Add-Member -NotePropertyName savedServices -NotePropertyValue ($s.savedServices | ConvertTo-Json -Depth 3 | ConvertFrom-Json) -Force
    }
    if ($s.savedServices -is [array]) { $s | Add-Member -NotePropertyName savedServices -NotePropertyValue ([pscustomobject]@{}) -Force }
    # activeMode 只接受三个合法值；损坏/手改的值按"未设置"处理，避免后续逻辑误判
    if ($s.activeMode -and $s.activeMode -notin 'direct', 'proxy', 'game') {
        Write-Warning "mode-state.json 的 activeMode 非法（$($s.activeMode)），按未设置处理"
        $s.activeMode = ''
    }
    if (-not $s.PSObject.Properties['savedWifi']) { $s | Add-Member -NotePropertyName savedWifi -NotePropertyValue @() }
    return $s
}

function Save-ModeState($s) { Save-ToolkitJson $s $script:StatePath }

# ============================ 小工具 ============================
function New-Step($name, $ok, $note) {
    [pscustomobject]@{ Step = $name; Ok = $ok; Note = $note }
}

function Write-Report($title, $steps) {
    Write-Host ""
    Write-Host "===== $title =====" -ForegroundColor Cyan
    foreach ($s in $steps) {
        $mark = if ($s.Ok) { '  √' } else { '  ×' }
        Write-MarkLine $mark $s.Ok ((Pad-Display $s.Step 26) + $s.Note)
    }
}

function Get-RouteCost($r) {
    # 真实优先级 = 路由度量 + 接口度量，光看有没有路由会误报
    return [int]$r.RouteMetric + [int]$r.InterfaceMetric
}

function Test-VpnRouteConflict {
    $routes = @(Get-DefaultRoutes)
    if ($routes.Count -eq 0) { return [pscustomobject]@{ Conflict = $false; Note = '没有默认路由' } }
    $primary = $routes[0]
    $vpn = @($routes | Where-Object { $_.InterfaceAlias -match '(?i)radmin|tailscale|wireguard|openvpn|vpn' })
    if ($vpn.Count -eq 0) {
        return [pscustomobject]@{ Conflict = $false; Note = "主链路 $($primary.InterfaceAlias)" }
    }
    $vpnBest = $vpn | Sort-Object { Get-RouteCost $_ } | Select-Object -First 1
    $pc = Get-RouteCost $primary
    $vc = Get-RouteCost $vpnBest
    if ($vc -le $pc) {
        return [pscustomobject]@{
            Conflict = $true
            Note = ("VPN 优先于主链路：{0}(成本 {1}) vs {2}(成本 {3})" -f $vpnBest.InterfaceAlias, $vc, $primary.InterfaceAlias, $pc)
        }
    }
    return [pscustomobject]@{
        Conflict = $false
        Note = ("有 VPN 路由但不抢占：{0}(成本 {1}) > 主链路 {2}(成本 {3})" -f $vpnBest.InterfaceAlias, $vc, $primary.InterfaceAlias, $pc)
    }
}
function Get-DefaultRoutes {
    $up = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' | Select-Object -ExpandProperty ifIndex)
    return @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
             Where-Object { $up -contains $_.ifIndex -and $_.NextHop -and $_.NextHop -ne '0.0.0.0' } |
             Sort-Object { [long]$_.RouteMetric + [long]$_.InterfaceMetric })
}

# ============================ 模式 1：国内直连 ============================
function Restore-PendingGameState {
    $state=Get-ModeState
    if ($state.savedPowerPlan -or @($state.savedWifi | Where-Object { $_ }).Count -gt 0 -or @($state.savedServices.PSObject.Properties).Count -gt 0) {
        $results=@(Invoke-Restore)
        if (@($results | Where-Object { -not $_.Ok }).Count -gt 0) { throw '上次游戏设置尚未完全还原，已停止模式切换；原记录仍保留' }
    }
}

function Invoke-ModeDirect {
    Restore-PendingGameState
    Add-IgnoreWindow '国内直连模式切换' 20
    $steps = New-Object System.Collections.ArrayList
    $cfg = Get-Config

    Save-ProxySnapshot
    # 1 关闭系统代理
    $wi = Get-WinInetProxy
    if ($wi.Enabled) {
        Set-SystemProxyOff
        [void]$steps.Add((New-Step '关闭系统代理' $true '已关闭，浏览器走直连'))
    } else {
        [void]$steps.Add((New-Step '关闭系统代理' $true '本来就是关的'))
    }

    # 2 PAC 也要关掉，否则等于没关；原值记进 state，还原时放回去
    $pacBackup = $wi.PacUrl
    if ($wi.PacUrl) {
        try {
            Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name AutoConfigURL -Value '' -ErrorAction Stop
            Send-ProxySettingsChanged
            [void]$steps.Add((New-Step '清除 PAC 脚本' $true "原来的 $($wi.PacUrl)"))
        } catch {
            [void]$steps.Add((New-Step '清除 PAC 脚本' $false $_.Exception.Message))
        }
    }

    # 3 DNS 恢复自动（跟随当前网络）
    if ($script:isAdmin) {
        $ad = (Get-DefaultRoutes | Select-Object -First 1).InterfaceAlias
        if ($ad) {
            try {
                # 先备份原 DNS，供「还原模式」写回
                $dnsBak = Join-Path $script:DataRoot 'runtime\dns-backup.json'
                if (-not (Test-Path $dnsBak)) {
                    Save-ToolkitJson (Get-DnsSnapshot $ad) $dnsBak
                }
                Set-DnsClientServerAddress -InterfaceAlias $ad -ResetServerAddresses -ErrorAction Stop
                [void]$steps.Add((New-Step "恢复 $ad 的 DNS" $true '改为自动获取'))
            } catch {
                [void]$steps.Add((New-Step "恢复 $ad 的 DNS" $false $_.Exception.Message))
            }
        }
    } else {
        [void]$steps.Add((New-Step '恢复 DNS' $false '需要管理员'))
    }

    ipconfig /flushdns | Out-Null
    [void]$steps.Add((New-Step '刷新 DNS 缓存' $true ''))

    # 4 检查 TUN 劫持
    $tun = Get-TunAdapters
    if ($tun.Count -gt 0) {
        [void]$steps.Add((New-Step '代理 TUN 网卡' $false ("仍在运行：" + (($tun | ForEach-Object { $_.Name }) -join ', ') + ' —— 直连模式需要关掉它的 TUN')))
    } else {
        [void]$steps.Add((New-Step '代理 TUN 网卡' $true '无'))
    }

    # 5 检查虚拟网卡抢默认路由
    $rc = Test-VpnRouteConflict
    [void]$steps.Add((New-Step '默认路由检查' (-not $rc.Conflict) $rc.Note))

    # 6 环境变量残留
    $envP = Get-EnvProxy
    $proxyVars = @($envP.Keys | Where-Object { $_ -notmatch '(?i)^no_proxy$' })
    if ($proxyVars.Count -gt 0) {
        [void]$steps.Add((New-Step '环境变量代理' $false ("存在：" + ($proxyVars -join ', ') + ' —— git/npm/pip 仍会走代理')))
    } else {
        [void]$steps.Add((New-Step '环境变量代理' $true '干净'))
    }

    $st = Get-ModeState
    $st.activeMode = 'direct'
    if ($pacBackup) { $st.savedPac = $pacBackup }
    $st.savedTime = (Get-Date).ToString('s')
    Save-ModeState $st

    Write-Report '模式 1：国内直连' $steps
    Write-Host "`n提示：这个模式下国外网站会打不开，这是预期行为。" -ForegroundColor DarkGray
    return $steps
}

# ============================ 模式 2：开启代理 ============================
function Invoke-ModeProxy {
    Restore-PendingGameState
    $steps = New-Object System.Collections.ArrayList
    $cfg = Get-Config

    # 0 内核没跑时，用「设置」里配置的客户端把它拉起来（不猜路径、不写死）
    if (-not (Test-Tcp -h $cfg.host -p ([int]$cfg.port) -TimeoutMs 600)) {
        $client = [string]$cfg.clientExe
        if ($client -and (Test-Path -LiteralPath $client)) {
            Add-IgnoreWindow '启动代理客户端' 45
            [void]$steps.Add((New-Step '启动代理软件' $true ('正在启动 ' + [IO.Path]::GetFileName($client))))
            try {
                # UseShellExecute=true 才能真正脱离当前控制台，否则 GUI 进程会继承句柄，
                # 把调用方（cmd / 子进程捕获）一直挂住。
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = $client
                $psi.UseShellExecute = $true
                $psi.WorkingDirectory = Split-Path -Parent $client
                [void][System.Diagnostics.Process]::Start($psi)
            }
            catch { [void]$steps.Add((New-Step '启动代理软件' $false $_.Exception.Message)) }

            $ready = $false
            for ($n = 0; $n -lt 60; $n++) {
                Start-Sleep -Milliseconds 750
                if (Test-Tcp -h $cfg.host -p ([int]$cfg.port) -TimeoutMs 400) { $ready = $true; break }
            }
            $note = if ($ready) { "$($cfg.host):$($cfg.port) 已就绪" } else { '45 秒内端口未就绪，请打开客户端确认' }
            [void]$steps.Add((New-Step '等待内核监听' $ready $note))
        } else {
            [void]$steps.Add((New-Step '启动代理软件' $false '设置里没有配置客户端路径（⚙ 设置）'))
        }
    }

    # 1 找到并验证代理
    $r = Invoke-Verify -PortOverride ([int]$cfg.port) -Quiet -Json
    if (-not $r.Capable -and -not $r.Alive) {
        # 配置端口不通就自动扫一遍
        $found = @()
        foreach ($p in @(7897, 7890, 10809, 2080, 7891, 10808)) {
            if (Test-Tcp -h '127.0.0.1' -p $p -TimeoutMs 400) {
                $proto = Detect-Protocol -h '127.0.0.1' -p $p -TimeoutMs 1500
                if ($proto -in 'HTTP', 'SOCKS5') { $found += $p }
            }
        }
        if ($found.Count -gt 0) {
            $cfg.port = $found[0]
            Save-Config $cfg
            $r = Invoke-Verify -PortOverride ([int]$cfg.port) -Quiet -Json
            [void]$steps.Add((New-Step '自动发现代理端口' $true "找到 $($cfg.port)（$($r.Protocol)）并已保存"))
        }
    }

    # 端口刚起来时内核可能还没准备好转发：只要端口通、转发不通，就再等几秒重试
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        if (-not $r.Alive -or $r.Capable) { break }
        [void]$steps.Add((New-Step '等待代理就绪' $true ("第 $attempt 次重试，端口已通但转发未就绪")))
        Start-Sleep -Seconds 4
        $r = Invoke-Verify -PortOverride ([int]$cfg.port) -Quiet -Json
    }
    Add-IgnoreWindow '启动代理客户端' 45
    [void]$steps.Add((New-Step '端口监听' $r.Alive $(if ($r.Alive) { "$($cfg.host):$($cfg.port)" } else { '没有进程监听' })))
    [void]$steps.Add((New-Step '协议识别' ($r.Protocol -in 'HTTP', 'SOCKS5') $r.Protocol))

    if (-not $r.Capable) {
        [void]$steps.Add((New-Step '代理可用性' $false $r.Verdict))
        Write-Report '模式 2：开启代理（失败）' $steps
        Write-Host "`n请先在代理软件里确认端口，或用 -Port 指定端口重试。" -ForegroundColor Yellow
        return $steps
    }

    [void]$steps.Add((New-Step '代理可用性' $true ("{0} 端口可用" -f $r.Protocol)))

    # 2 开启系统代理
    Set-SystemProxyOn -p ([int]$cfg.port)
    [void]$steps.Add((New-Step '设置系统代理' $true "127.0.0.1:$($cfg.port)"))

    # 客户端（Clash Verge 等）启动后常会按自己的开关重新写一遍系统代理，
    # 所以设置完等两秒复核，被改回去就再设一次，并告知用户是谁改的。
    Start-Sleep -Seconds 2
    $wi = Get-WinInetProxy
    if (-not $wi.Enabled) {
        Set-SystemProxyOn -p ([int]$cfg.port)
        Start-Sleep -Milliseconds 600
        $wi2 = Get-WinInetProxy
        [void]$steps.Add((New-Step '系统代理复核' $wi2.Enabled $(if ($wi2.Enabled) { '客户端曾把它关掉，已重新开启' } else { '反复被客户端改回，请在客户端里关闭"自动设置系统代理"' })))
    } else {
        [void]$steps.Add((New-Step '系统代理复核' $true '2 秒后仍为开启'))
    }

    # 3 环境变量不一致提醒
    $envP = Get-EnvProxy
    $proxyVars = @($envP.Keys | Where-Object { $_ -notmatch '(?i)^no_proxy$' })
    if ($proxyVars.Count -gt 0) {
        [void]$steps.Add((New-Step '环境变量' $false ("存在 " + ($proxyVars -join ', ') + "，可能与系统代理不一致")))
    } else {
        [void]$steps.Add((New-Step '环境变量' $true '未设置'))
    }

    # 4 出口验证
    $g = Test-ProxyHttp -h $cfg.host -p ([int]$cfg.port) -Url 'https://www.google.com' -Kind $(if ($r.Protocol -eq 'SOCKS5') { 'socks5' } else { 'http' })
    if ($g -and $g.Code -eq 200) {
        [void]$steps.Add((New-Step '出口验证' $true "Google 200 / $($g.Ms)ms"))
    } else {
        [void]$steps.Add((New-Step '出口验证' $false '代理已开但出口不通，检查节点/订阅'))
    }

    $st = Get-ModeState
    $st.activeMode = 'proxy'
    $st.savedTime = (Get-Date).ToString('s')
    Save-ModeState $st

    Write-Report '模式 2：开启代理' $steps
    Write-Host "`n提示：需要改节点/规则，点「打开代理软件」进客户端界面。" -ForegroundColor DarkGray
    return $steps
}

# ============================ 模式 3：游戏优化 ============================
function Invoke-ModeGame {
    $steps = New-Object Collections.ArrayList
    if (-not $script:isAdmin) { Write-Report '游戏优化未执行' @((New-Step '管理员权限' $false '需要管理员权限')); return }
    $confirmed = [bool]$Yes
    if (-not $confirmed -and -not [Console]::IsInputRedirected) { $confirmed = (Read-Host '将停止更新服务、调整电源和无线参数、关闭代理。可能短暂断网。继续？(y/N)') -match '^(y|yes)$' }
    if (-not $confirmed) { Write-Report '游戏优化未执行' @((New-Step '操作确认' $false '未确认，未修改系统；非交互运行需显式 -Yes')); return }
    $state = Get-ModeState
    if (-not $state.PSObject.Properties['savedWifi']) { $state | Add-Member -NotePropertyName savedWifi -NotePropertyValue @() }
    $state.activeMode = 'game'
    $state.savedTime = (Get-Date).ToString('s')
    Save-ModeState $state
    Add-IgnoreWindow '游戏模式切换' 40
    foreach ($name in 'wuauserv','DoSvc') {
        # DoSvc 是受保护服务：连"设置成原值"都会被拒绝访问，改不动也就还原不了，直接不碰
        if ($name -eq 'DoSvc') {
            [void]$steps.Add((New-Step "暂停 $name" $true '系统保护服务，跳过（Windows 不允许修改）'))
            continue
        }
        $service = Get-Service $name -ErrorAction SilentlyContinue
        if (-not $service) { continue }
        try {
            if (-not $state.savedServices.PSObject.Properties[$name]) {
                $state.savedServices | Add-Member -NotePropertyName $name -NotePropertyValue ("$($service.StartType)|$($service.Status)")
                Save-ModeState $state
            }
            if ($service.Status -eq 'Running') { Stop-Service $name -Force -ErrorAction Stop }
            [void]$steps.Add((New-Step "暂停 $name" $true '仅停止本次运行，不更改开机启动类型'))
        } catch {
            # 改不动（受保护服务等）就不要留下还原记录，否则以后每次切换都会被它挡住
            if ($state.savedServices.PSObject.Properties[$name]) {
                $state.savedServices.PSObject.Properties.Remove($name)
                Save-ModeState $state
            }
            [void]$steps.Add((New-Step "暂停 $name" $false $_.Exception.Message))
        }
    }
    try {
        if (-not $state.savedPowerPlan) {
            $current = (powercfg /getactivescheme) -join ' '
            if ($LASTEXITCODE -ne 0 -or $current -notmatch '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { throw '无法备份原电源方案，未修改电源' }
            $state.savedPowerPlan = $Matches[1]
            Save-ModeState $state
        }
        powercfg /setactive SCHEME_MIN | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "powercfg 退出码 $LASTEXITCODE" }
        [void]$steps.Add((New-Step '高性能电源' $true '耗电可能增加；请在使用后还原'))
    } catch { [void]$steps.Add((New-Step '高性能电源' $false $_.Exception.Message)) }
    $wifi = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.PhysicalMediaType -eq 'Native 802.11' } | Select-Object -First 1
    if ($wifi) {
        foreach ($setting in @(@{Key='uAPSDSupport'; Value=0},@{Key='RoamAggressiveness'; Value=0},@{Key='MIMOPowerSaveMode'; Value=3})) {
            $property = Get-NetAdapterAdvancedProperty -Name $wifi.Name -RegistryKeyword $setting.Key -ErrorAction SilentlyContinue
            if (-not $property -or [string]$property.RegistryValue -eq [string]$setting.Value) { continue }
            try {
                $saved = @($state.savedWifi | Where-Object { $_.Interface -eq $wifi.Name -and $_.RegistryKeyword -eq $setting.Key })
                if ($saved.Count -eq 0) {
                    $state.savedWifi = @($state.savedWifi) + @([pscustomobject]@{ Interface=$wifi.Name; RegistryKeyword=$setting.Key; RegistryValue=@($property.RegistryValue) })
                    Save-ModeState $state
                }
                Add-IgnoreWindow ('调整无线参数 ' + $setting.Key) 25
                Set-NetAdapterAdvancedProperty -Name $wifi.Name -RegistryKeyword $setting.Key -RegistryValue $setting.Value -NoRestart -ErrorAction Stop
                [void]$steps.Add((New-Step $setting.Key $true '已保存原值；驱动可能短暂重新关联'))
            } catch { [void]$steps.Add((New-Step $setting.Key $false $_.Exception.Message)) }
        }
    }
    try {
        Set-SystemProxyOff
        [void]$steps.Add((New-Step '关闭系统代理' $true '原值已备份；不改变代理软件 TUN 设置'))
    } catch { [void]$steps.Add((New-Step '关闭系统代理' $false $_.Exception.Message)) }
    Write-Report '游戏使用设置' $steps
    Write-Host '请在使用结束后点击「还原模式」。本功能不保证降低延迟，弱信号和 AP 故障请交由网络中心处理。' -ForegroundColor DarkGray
    return $steps
}

# ============================ 还原 ============================
function Invoke-Restore {
    $steps = New-Object Collections.ArrayList
    $state = Get-ModeState
    foreach ($property in @($state.savedServices.PSObject.Properties)) {
        try {
            $service = Get-Service $property.Name -ErrorAction Stop
            $parts = [string]$property.Value -split '\|'
            $targetType = $parts[0]
            $targetRunning = ($parts.Count -lt 2) -or ($parts[1] -eq 'Running')
            $typeOk = ([string]$service.StartType -eq $targetType)
            $stateOk = (($service.Status -eq 'Running') -eq $targetRunning)
            if ($typeOk -and $stateOk) {
                # 已经是目标值，不要再去写一次——受保护服务连写回原值都会拒绝访问
                $state.savedServices.PSObject.Properties.Remove($property.Name)
                [void]$steps.Add((New-Step ('恢复服务 ' + $property.Name) $true '当前已与记录一致，未改动'))
                continue
            }
            Set-Service $property.Name -StartupType $targetType -ErrorAction Stop
            if ($targetRunning) { Start-Service $property.Name -ErrorAction Stop }
            elseif ($service.Status -eq 'Running') { Stop-Service $property.Name -ErrorAction Stop }
            $state.savedServices.PSObject.Properties.Remove($property.Name)
            [void]$steps.Add((New-Step ('恢复服务 ' + $property.Name) $true '已恢复原启动类型与运行状态'))
        } catch {
            # 还原失败：保留记录以便权限修复后重试（策略与测试一致）
            [void]$steps.Add((New-Step ('恢复服务 ' + $property.Name) $false $_.Exception.Message))
        }
    }
    if ($state.savedPowerPlan) {
        try {
            if ($state.savedPowerPlan -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { throw '备份中的电源方案 GUID 无效，保留记录' }
            powercfg /setactive $state.savedPowerPlan | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "powercfg 退出码 $LASTEXITCODE" }
            $state.savedPowerPlan = ''
            [void]$steps.Add((New-Step '恢复电源方案' $true '已恢复'))
        } catch { [void]$steps.Add((New-Step '恢复电源方案' $false $_.Exception.Message)) }
    }
    $pendingWifi = @()
    foreach ($saved in @($state.savedWifi | Where-Object { $_ })) {
        try {
            Add-IgnoreWindow ('还原无线参数 ' + $saved.RegistryKeyword) 25
            Set-NetAdapterAdvancedProperty -Name $saved.Interface -RegistryKeyword $saved.RegistryKeyword -RegistryValue $saved.RegistryValue -NoRestart -ErrorAction Stop
            [void]$steps.Add((New-Step ('恢复 ' + $saved.RegistryKeyword) $true '已恢复原值'))
        } catch {
            $pendingWifi += $saved
            [void]$steps.Add((New-Step ('恢复 ' + $saved.RegistryKeyword) $false $_.Exception.Message))
        }
    }
    if (-not $state.PSObject.Properties['savedWifi']) { $state | Add-Member -NotePropertyName savedWifi -NotePropertyValue @() }
    $state.savedWifi = $pendingWifi
    $proxyBackup = Join-Path $script:DataRoot 'runtime\proxy-backup.json'
    if (Test-Path -LiteralPath $proxyBackup) {
        try {
            Restore-ProxySnapshot (Get-Content -LiteralPath $proxyBackup -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
            Move-RestoredBackup $proxyBackup
            $state.savedPac = ''
            [void]$steps.Add((New-Step '恢复系统代理' $true '已恢复开关、地址、绕过列表与 PAC'))
        } catch { [void]$steps.Add((New-Step '恢复系统代理' $false $_.Exception.Message)) }
    } elseif ($state.savedPac) {
        try {
            Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name AutoConfigURL -Value $state.savedPac -ErrorAction Stop
            Send-ProxySettingsChanged
            $state.savedPac = ''
            [void]$steps.Add((New-Step '恢复旧版 PAC 记录' $true '已恢复'))
        } catch { [void]$steps.Add((New-Step '恢复旧版 PAC 记录' $false $_.Exception.Message)) }
    }
    $dnsBackup = Join-Path $script:DataRoot 'runtime\dns-backup.json'
    if (Test-Path -LiteralPath $dnsBackup) {
        try {
            Restore-DnsSnapshot (Get-Content -LiteralPath $dnsBackup -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
            Move-RestoredBackup $dnsBackup
            [void]$steps.Add((New-Step '恢复 DNS' $true '已恢复原获取方式与地址'))
        } catch { [void]$steps.Add((New-Step '恢复 DNS' $false $_.Exception.Message)) }
    }
    $failed = @($steps | Where-Object { -not $_.Ok })
    if ($failed.Count -eq 0) { $state.activeMode = '' }
    $state.savedTime = (Get-Date).ToString('s')
    Save-ModeState $state
    Write-Report '还原模式' $steps
    if ($failed.Count -gt 0) { Write-Host '部分还原失败，原记录仍保留；修复权限或设备后再次执行还原。' -ForegroundColor Yellow }
    else { Write-Host '还原完成；已消费的备份移入 runtime\history。' -ForegroundColor DarkGray }
    return $steps
}

# ============================ 打开客户端界面 ============================
function Invoke-OpenClient {
    $cfg = Get-Config
    if ($cfg.clientExe -and (Test-Path $cfg.clientExe)) {
        Start-Process $cfg.clientExe
        Write-Host "已启动：$($cfg.clientExe)" -ForegroundColor Green
        return
    }
    # 猜：先看代理端口是谁在监听
    $o = Get-PortOwner ([int]$cfg.port)
    if ($o -and $o.Path -and (Test-Path $o.Path)) {
        Write-Host "代理内核是 $($o.Name)，但它通常没有独立界面。" -ForegroundColor Yellow
    }
    # 常见 GUI
    $candidates = @(
        'D:\Program Files\Clash Verge\clash-verge.exe',
        "$env:LOCALAPPDATA\Programs\Clash Verge\clash-verge.exe",
        "$env:ProgramFiles\Clash Verge\clash-verge.exe",
        'C:\Program Files\Clash Verge\clash-verge.exe',
        "$env:ProgramFiles\v2rayN\v2rayN.exe",
        "$env:LOCALAPPDATA\Programs\v2rayN\v2rayN.exe",
        "$env:ProgramFiles\FlClash\FlClash.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) {
            Start-Process $c
            Write-Host "已启动：$c" -ForegroundColor Green
            Write-Host "提示：把这个路径填进 proxy-config.json 的 clientExe，以后就能直接打开。" -ForegroundColor DarkGray
            return
        }
    }
    Write-Host "没找到代理软件的可执行文件。" -ForegroundColor Red
    Write-Host "请在 proxy-config.json 里设置 `"clientExe`": `"你的客户端路径`"" -ForegroundColor DarkGray
}

function Show-ModeStatus {
    $st = Get-ModeState
    $wi = Get-WinInetProxy
    $cfg = Get-Config
    Write-Host ""
    Write-Host ("当前模式   : {0}" -f $(if ($st.activeMode) { $st.activeMode } else { '未设置' }))
    Write-Host ("系统代理   : {0}" -f $(if ($wi.Enabled) { "开启 -> $($wi.Server)" } else { '关闭' }))
    Write-Host ("配置端口   : {0}:{1}  监听 {2}" -f $cfg.host, $cfg.port, $(if (Test-Tcp -h $cfg.host -p ([int]$cfg.port)) { '是' } else { '否' }))
    if ($st.savedServices) {
        $s = ($st.savedServices.PSObject.Properties | ForEach-Object { $_.Name }) -join ', '
        Write-Host ("已暂停服务 : {0}" -f $s)
    }
}

try {
switch ($Action) {
    'direct'      { if (@(Invoke-ModeDirect | Where-Object { -not $_.Ok }).Count -gt 0) { exit 2 } }
    'proxy'       { if (@(Invoke-ModeProxy | Where-Object { -not $_.Ok }).Count -gt 0) { exit 2 } }
    'game'        { if (@(Invoke-ModeGame | Where-Object { -not $_.Ok }).Count -gt 0) { exit 2 } }
    'restore'     { if (@(Invoke-Restore | Where-Object { -not $_.Ok }).Count -gt 0) { exit 1 } }
    'status'      { Show-ModeStatus }
    'open-client' { Invoke-OpenClient }
}
} catch { Write-Host ('操作未完成：'+$_.Exception.Message) -ForegroundColor Red; exit 1 }
