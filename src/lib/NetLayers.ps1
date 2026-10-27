#Requires -Version 5.1
<#
    src/lib/NetLayers.ps1 — 分层网络证据的结论合成
    纯函数：输入五层状态，输出主结论 + 徽章 + 建议动作，不发任何请求、不改任何状态。
    调用方先加载 Common.ps1。

    层：
      Link      链路      网卡/默认路由/网关
      Dns       DNS       解析能力
      Domestic  国内出口   多个国内 204 端点
      Intl      国际出口   cloudflare trace / google 204
      Proxy     代理       端口/协议/出口（独立表达，不混进主结论）
      Auth      认证       是否被重定向到登录页
#>

function New-LayerState {
    param(
        [ValidateSet('Ok', 'Fail', 'Unknown')][string]$State = 'Unknown',
        [string]$Detail = '',
        [datetime]$At = (Get-Date),
        [int]$Passed = 0,
        [int]$Total = 0
    )
    [pscustomobject]@{ State = $State; Detail = $Detail; At = $At; Passed = $Passed; Total = $Total }
}

function Get-BadgeMark([string]$State) {
    switch ($State) {
        'Ok' { return [char]0x25CF }    # ●
        'Fail' { return [char]0x25CB }  # ○
        default { return [char]0x2014 } # —
    }
}

function Resolve-LayerConclusion {
    param([Parameter(Mandatory = $true)]$Layers)

    $link = $Layers.Link
    $dns = $Layers.Dns
    $dom = $Layers.Domestic
    $intl = $Layers.Intl
    $proxy = $Layers.Proxy
    $auth = $Layers.Auth

    $title = ''
    $detail = ''
    $suggest = ''
    $severity = 'Unknown'

    # 由最弱环节决定主结论：越靠前优先级越高
    if (-not $link -or $link.State -ne 'Ok') {
        $title = '未连接'
        $detail = if ($link -and $link.Detail) { $link.Detail } else { '没有检测到已连接的网卡。' }
        $suggest = '检查无线是否连接到目标网络，或插好网线。'
        $severity = 'Down'
    } elseif (-not $dns -or $dns.State -ne 'Ok') {
        $title = '链路正常 · DNS 异常'
        $detail = if ($dns -and $dns.Detail) { $dns.Detail } else { '域名解析失败。' }
        $suggest = '在设置里换一组 DNS，或点「DNS 优选」。'
        $severity = 'Degraded'
    } elseif (-not $dom -or $dom.State -ne 'Ok') {
        if ($auth -and $auth.Redirect) {
            $title = '链路正常 · 需要网页认证'
            $detail = if ($auth.PortalUrl) { '探测被重定向到认证页：' + $auth.PortalUrl } else { '探测被重定向，可能需要网页认证。' }
            $suggest = '点「校园网登录」打开认证页完成登录。'
            $severity = 'NeedsAuth'
        } else {
            $title = '链路正常 · 国内出口不通'
            $detail = if ($dom -and $dom.Detail) { $dom.Detail } else { '国内探测点全部失败。' }
            $suggest = '先做「一键体检」看丢包与延迟；若在校园网，确认是否需要认证。'
            $severity = 'Degraded'
        }
    } elseif (-not $intl -or $intl.State -ne 'Ok') {
        $title = '国内可达 · 国际不通（直连受限）'
        $detail = if ($intl -and $intl.Detail) { $intl.Detail } else { '国际探测点不可达。' }
        $suggest = '需要访问境外服务时开启代理；直连状态下这是预期结果。'
        $severity = 'Degraded'
    } else {
        $title = '国内可达 · 国际可达'
        $detail = '链路、DNS、国内与国际探测均通过。'
        $severity = 'Ok'
    }

    # 代理独立成句，不参与主结论
    $proxyText = '代理：未启用'
    if ($proxy -and $proxy.Enabled) {
        if (-not $proxy.Alive) { $proxyText = '代理：已开启但端口未监听' }
        elseif ($proxy.Exit) { $proxyText = '代理：端口在监听 · 出口 ' + $proxy.Exit }
        else { $proxyText = '代理：端口在监听 · 出口未验证' }
    }
    if ($proxy -and $proxy.Enabled -and -not $proxy.Alive -and $severity -eq 'Ok') {
        $severity = 'Degraded'
        $suggest = '系统代理开着但本机端口没监听，开启代理后客户端可能已退出。'
    }

    $badges = @(
        [pscustomobject]@{ Key = '链路'; State = $(if ($link) { $link.State } else { 'Unknown' }); Mark = (Get-BadgeMark $(if ($link) { $link.State } else { 'Unknown' })) }
        [pscustomobject]@{ Key = 'DNS'; State = $(if ($dns) { $dns.State } else { 'Unknown' }); Mark = (Get-BadgeMark $(if ($dns) { $dns.State } else { 'Unknown' })) }
        [pscustomobject]@{ Key = '国内'; State = $(if ($dom) { $dom.State } else { 'Unknown' }); Mark = (Get-BadgeMark $(if ($dom) { $dom.State } else { 'Unknown' })) }
        [pscustomobject]@{ Key = '国际'; State = $(if ($intl) { $intl.State } else { 'Unknown' }); Mark = (Get-BadgeMark $(if ($intl) { $intl.State } else { 'Unknown' })) }
        [pscustomobject]@{ Key = '代理'; State = $(if ($proxy -and $proxy.Enabled -and $proxy.Alive) { 'Ok' } elseif ($proxy -and $proxy.Enabled) { 'Fail' } else { 'Unknown' }); Mark = (Get-BadgeMark $(if ($proxy -and $proxy.Enabled -and $proxy.Alive) { 'Ok' } elseif ($proxy -and $proxy.Enabled) { 'Fail' } else { 'Unknown' })) }
    )

    [pscustomobject]@{
        Title    = $title
        Detail   = $detail
        Suggest  = $suggest
        Severity = $severity
        Proxy    = $proxyText
        Badges   = $badges
        At       = (Get-Date)
    }
}
