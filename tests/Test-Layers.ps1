#Requires -Version 5.1
# tests/Test-Layers.ps1 — 分层结论合成的纯函数回归
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src\lib\NetLayers.ps1')

$script:total = 0
$script:fail = 0

function Assert-True([bool]$Condition, [string]$Name) {
    $script:total++
    if ($Condition) { Write-Host "  PASS $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL $Name" -ForegroundColor Red }
}

function New-Layers([string]$Link, [string]$Dns, [string]$Dom, [string]$Intl, [bool]$ProxyOn = $false, [bool]$ProxyAlive = $false, [bool]$AuthRedirect = $false, [string]$Portal = '') {
    [pscustomobject]@{
        Link     = New-LayerState -State $Link -Detail '链路详情'
        Dns      = New-LayerState -State $Dns -Detail 'DNS 详情'
        Domestic = New-LayerState -State $Dom -Detail '国内详情' -Passed 0 -Total 3
        Intl     = New-LayerState -State $Intl -Detail '国际详情'
        Proxy    = [pscustomobject]@{ Enabled = $ProxyOn; Alive = $ProxyAlive; Protocol = 'HTTP'; Exit = '' }
        Auth     = [pscustomobject]@{ Redirect = $AuthRedirect; PortalUrl = $Portal }
    }
}

Write-Host "分层结论合成" -ForegroundColor Cyan

$r = Resolve-LayerConclusion (New-Layers 'Fail' 'Unknown' 'Unknown' 'Unknown')
Assert-True ($r.Severity -eq 'Down' -and $r.Title -eq '未连接') '链路断开优先于其它层'

$r = Resolve-LayerConclusion (New-Layers 'Ok' 'Fail' 'Ok' 'Ok')
Assert-True ($r.Title -eq '链路正常 · DNS 异常') 'DNS 失败先于出口判定'

$r = Resolve-LayerConclusion (New-Layers 'Ok' 'Ok' 'Fail' 'Unknown' $true $false $true 'http://10.0.0.1/0.htm')
Assert-True ($r.Title -match '需要网页认证') '国内失败 + 重定向 → 认证'
Assert-True ($r.Detail -match '10\.0\.0\.1') '认证结论带出门户地址'

$r = Resolve-LayerConclusion (New-Layers 'Ok' 'Ok' 'Fail' 'Unknown')
Assert-True ($r.Title -match '国内出口不通') '国内失败且无重定向 → 出口不通'
Assert-True ($r.Severity -eq 'Degraded') '出口不通属于降级而非断开'

$r = Resolve-LayerConclusion (New-Layers 'Ok' 'Ok' 'Ok' 'Fail')
Assert-True ($r.Title -match '国际不通') '国际失败单独表达'
Assert-True ($r.Suggest -match '代理') '国际失败给出开启代理的建议'

$r = Resolve-LayerConclusion (New-Layers 'Ok' 'Ok' 'Ok' 'Ok')
Assert-True ($r.Title -eq '国内可达 · 国际可达' -and $r.Severity -eq 'Ok') '全通'

$r = Resolve-LayerConclusion (New-Layers 'Ok' 'Ok' 'Ok' 'Ok' $true $true)
Assert-True ($r.Proxy -match '端口在监听' -and $r.Proxy -match '出口未验证') '代理独立成句且不污染主结论'
Assert-True ($r.Title -eq '国内可达 · 国际可达') '代理开启不改变主结论'

$r = Resolve-LayerConclusion (New-Layers 'Ok' 'Ok' 'Ok' 'Ok' $true $false)
Assert-True ($r.Proxy -match '端口未监听') '代理开启但端口没监听'
Assert-True ($r.Severity -eq 'Degraded') '代理异常会降级'

$r = Resolve-LayerConclusion (New-Layers 'Unknown' 'Ok' 'Ok' 'Ok')
Assert-True ($r.Title -eq '未连接') '链路未知按未连接处理'

$r = Resolve-LayerConclusion (New-Layers 'Ok' 'Ok' 'Ok' 'Fail')
$marks = ($r.Badges | ForEach-Object { $_.Mark }) -join ''
Assert-True ($marks.Length -eq 5) '始终输出五枚徽章'
Assert-True ($r.Badges[3].State -eq 'Fail') '国际徽章为失败态'
Assert-True ($r.Badges[4].State -eq 'Unknown') '代理未启用时徽章为未知'

$r = Resolve-LayerConclusion (New-Layers 'Ok' 'Ok' 'Partial' 'Ok')
Assert-True ($r.Title -match '国内出口部分可用') '国内部分通过不冒充全通'
Assert-True ($r.Severity -eq 'Degraded') '国内部分通过属于降级'

$r = Resolve-LayerConclusion (New-Layers 'Ok' 'Ok' 'Ok' 'Partial')
Assert-True ($r.Title -match '国际部分可达') '国际部分通过单独表达'
Assert-True ($r.Badges[3].State -eq 'Partial' -and $r.Badges[3].Mark -eq [char]0x25D0) '国际部分通过徽章为半通过'

Write-Host ("分层结论：{0} 项，{1} 个失败" -f $script:total, $script:fail)
if ($script:fail) { exit 1 }
exit 0
