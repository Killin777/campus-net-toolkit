#Requires -Version 5.1
<#
    诊断回归：仅从 AST 装载函数，所有系统、网络和浏览器依赖均使用替身。
    不运行模块主入口，不读取用户配置，不修改系统，也不访问外部网络。
#>
$ErrorActionPreference = 'Stop'
if ([Console]::IsOutputRedirected) {
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
}
$root = Split-Path -Parent $PSScriptRoot
$portalPath = Join-Path $root 'src\lib\CampusPortal.ps1'
$campusPath = Join-Path $root 'src\lib\CampusCheck.ps1'
$routePath = Join-Path $root 'src\lib\RouteGuard.ps1'
$script:fail = 0
$script:total = 0

function Assert-True($condition, [string]$message) {
    if (-not $condition) { throw $message }
}
function Test-Case([string]$name, [scriptblock]$test) {
    $script:total++
    try { & $test; Write-Host ("  PASS {0}" -f $name) }
    catch { $script:fail++; Write-Host ("  FAIL {0} : {1}" -f $name, $_.Exception.Message) -ForegroundColor Red }
}
function Import-DiagnosticFunctions([string]$path) {
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
    if ($errors.Count -gt 0) { throw ("诊断模块解析失败：" + $path) }
    $definitions = @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] })
    return [scriptblock]::Create(($definitions | ForEach-Object { $_.Extent.Text }) -join "`r`n")
}
. (Import-DiagnosticFunctions $portalPath)
. (Import-DiagnosticFunctions $campusPath)
. (Import-DiagnosticFunctions $routePath)

# 未被每个用例显式替换的系统依赖应立即失败，防止测试意外触网或改配置。
function Get-NetAdapter { throw '测试禁止读取真实网卡' }
function Get-NetRoute { throw '测试禁止读取真实路由' }
function Get-NetIPAddress { throw '测试禁止读取真实 IP 配置' }
function Get-NetIPInterface { throw '测试禁止读取真实接口配置' }
function Get-NetTCPConnection { throw '测试禁止读取真实监听端口' }
function Get-ItemProperty { throw '测试禁止读取真实注册表' }
function Resolve-DnsName { throw '测试禁止真实 DNS 查询' }
function Invoke-NoRedirect { throw '测试禁止真实 HTTP 探测' }
function Start-Process { throw '测试禁止启动真实浏览器' }
function netsh { throw '测试禁止调用真实 netsh' }
function Set-Content { throw '测试禁止写入配置' }
function Add-Content { throw '测试禁止写入配置' }
function Out-File { throw '测试禁止写入配置' }

Test-Case '门户配置使用 EXE 数据根并优先读取用户手工配置' {
    $previousDataRoot = $env:CAMPUS_NET_DATA_ROOT
    try {
        $env:CAMPUS_NET_DATA_ROOT = 'C:\CampusNetDiagnosticsFixture'
        . $portalPath -NoRun
        $imported = Join-Path $env:CAMPUS_NET_DATA_ROOT 'runtime\imported-campus-config.json'
        $manual = Join-Path $env:CAMPUS_NET_DATA_ROOT 'config\campus-config.json'
        $fixture = @{}
        $fixture[$imported] = '{"portalUrl":"https://imported.example/login","httpsProbe":"https://probe.example/","internalDomains":["campus.example"]}'
        $fixture[$manual] = '{"portalUrl":"https://manual.example/login"}'
        $readPaths = New-Object System.Collections.ArrayList
        function Test-Path { param($Path, $LiteralPath) if ($LiteralPath) { $Path = $LiteralPath }; return $fixture.ContainsKey([string]$Path) }
        function Get-Content {
            param($Path, $LiteralPath, [switch]$Raw, $Encoding)
            if ($LiteralPath) { $Path = $LiteralPath }
            if (-not $fixture.ContainsKey([string]$Path)) { throw '尝试读取非测试配置' }
            [void]$readPaths.Add([string]$Path)
            return $fixture[[string]$Path]
        }
        $cfg = Get-CampusConfig
        Assert-True ($script:CampusConfigPath -eq $manual) '门户配置仍指向安装根目录'
        Assert-True ($cfg.portalUrl -eq 'https://manual.example/login') '手工配置没有覆盖导入配置'
        Assert-True ($cfg.httpsProbe -eq 'https://probe.example/') '导入配置没有用作后备值'
        Assert-True ($readPaths.Count -eq 2 -and $readPaths[0] -eq $imported -and $readPaths[1] -eq $manual) '配置读取顺序不正确'
    } finally { $env:CAMPUS_NET_DATA_ROOT = $previousDataRoot }
}
Test-Case '未指定数据根时门户配置仍从项目根读取' {
    $previousDataRoot = $env:CAMPUS_NET_DATA_ROOT
    try {
        $env:CAMPUS_NET_DATA_ROOT = $null
        . $portalPath -NoRun
        Assert-True ($script:CampusConfigPath -eq (Join-Path $root 'config\campus-config.json')) '项目根配置路径回退错误'
    } finally { $env:CAMPUS_NET_DATA_ROOT = $previousDataRoot }
}

foreach ($unsafeUrl in @('ms-settings:network', 'file:///C:/Windows/win.ini', 'javascript:alert(1)', 'data:text/html,test', 'http:///missing-host')) {
    Test-Case ("门户拒绝非网页或无效地址：{0}" -f $unsafeUrl.Split(':')[0]) {
        $resolved = Resolve-PortalUrl -ProbeUrl 'http://probe.example/check' -Location $unsafeUrl
        Assert-True ([string]::IsNullOrEmpty($resolved)) '危险地址被作为登录页返回'
        $script:openedPortal = $false
        function Start-Process { param($FilePath) $script:openedPortal = $true }
        $opened = Open-Portal ([pscustomobject]@{ Authenticated = $false; PortalUrl = $unsafeUrl; Detail = '测试' })
        Assert-True (-not $opened -and -not $script:openedPortal) '危险地址被传给浏览器启动器'
    }
    Test-Case ("直接打开门户也拒绝无效地址：{0}" -f $unsafeUrl.Split(':')[0]) {
        $script:openedPortal = $false
        function Start-Process { param($FilePath) $script:openedPortal = $true }
        $opened = Open-Portal ([pscustomobject]@{ Authenticated = $false; PortalUrl = $unsafeUrl; Detail = '测试' })
        Assert-True (-not $opened -and -not $script:openedPortal) '危险地址被传给浏览器启动器'
    }
}
Test-Case '门户相对跳转解析为绝对 HTTP 地址' {
    Assert-True ((Resolve-PortalUrl 'http://probe.example/check' '/login') -eq 'http://probe.example/login') '相对门户跳转解析错误'
}
Test-Case '无效探测基址不能使相对登录地址通过验证' {
    Assert-True ([string]::IsNullOrEmpty((Resolve-PortalUrl 'file:///C:/probe' '/login'))) '非 HTTP 基址生成了登录地址'
}
Test-Case '有效 HTTPS 门户可以打开一次' {
    $script:openedPortal = @()
    function Start-Process { param($FilePath) $script:openedPortal += $FilePath }
    $opened = Open-Portal ([pscustomobject]@{ Authenticated = $false; PortalUrl = 'https://portal.example/login'; Detail = '测试' })
    Assert-True ($opened -and $script:openedPortal.Count -eq 1 -and $script:openedPortal[0] -eq 'https://portal.example/login') '合法 HTTPS 登录页没有按原地址打开'
}
Test-Case '缺少 curl 不能冒充 HTTPS 实测成功' {
    function Test-Path { return $false }
    $real = Test-RealReach 'https://probe.example/'
    Assert-True (-not $real.Ok -and $real.Known -eq $false -and $real.Skipped -eq $true) '未测量被错误报告为成功'
    Assert-True ($real.Detail -match 'curl|未完成|未验证') '缺少未测量原因'
}
Test-Case 'HTTPS 地址无效时不能执行或宣称完成实测' {
    function Test-Path { return $true }
    function Join-Path { return 'Invoke-TestCurl' }
    function Invoke-TestCurl { throw '无效地址不应调用 curl' }
    $real = Test-RealReach 'file:///C:/probe'
    Assert-True (-not $real.Ok -and $real.Known -eq $false) '非 HTTPS 地址被当作 HTTPS 测量'
}
Test-Case '成功的 HTTPS HTTP 状态码保留测量成功状态' {
    function Test-Path { return $true }
    function Join-Path { return 'Invoke-TestCurl' }
    function Invoke-TestCurl { $global:LASTEXITCODE = 0; return '200' }
    $real = Test-RealReach 'https://probe.example/'
    Assert-True ($real.Ok -and $real.Known -eq $true -and $real.Skipped -eq $false) '实测成功的结构化状态不完整'
}
Test-Case '只有连通性探测通过时联网状态仍为未确认' {
    function Get-CampusConfig { return @{ portalUrl = ''; httpsProbe = 'https://probe.example/' } }
    function Get-CampusAuthState { [pscustomobject]@{ Authenticated = $true; PortalUrl = ''; Probe = 'fixture'; Code = 204; Detail = '探测返回 204，已联网' } }
    function Test-RealReach { [pscustomobject]@{ Ok = $false; Known = $false; Skipped = $true; Detail = '缺少系统 curl.exe' } }
    $state = Get-CampusState
    Assert-True (-not $state.Authenticated -and $state.VerificationKnown -eq $false -and $state.HttpsVerified -eq $false) '跳过 HTTPS 后仍宣称认证通过'
    Assert-True ($state.Detail -match '未完成|未验证|未确认' -and $state.Detail -notmatch 'HTTPS.*均通过') '未确认状态文案仍宣称通过'
    Assert-True (-not $state.Suspicious) '无法测量被错误判定为门户拦截'
}
Test-Case '探测和 HTTPS 实测都通过才确认联网' {
    function Get-CampusConfig { return @{ portalUrl = ''; httpsProbe = 'https://probe.example/' } }
    function Get-CampusAuthState { [pscustomobject]@{ Authenticated = $true; PortalUrl = ''; Probe = 'fixture'; Code = 204; Detail = '探测通过' } }
    function Test-RealReach { [pscustomobject]@{ Ok = $true; Known = $true; Skipped = $false; Detail = 'HTTP 200' } }
    $state = Get-CampusState
    Assert-True ($state.Authenticated -and $state.HttpsVerified -eq $true) '完整验证后没有确认 HTTPS 通过'
}

Test-Case 'ICMP 完全无响应时 MTU 返回未知' {
    function Test-MtuPayload { return $false }
    Assert-True ($null -eq (Get-PathMtu 'mtu.example')) '所有探测失败仍返回伪造 MTU 值'
}
Test-Case '标准 MTU 探测成功时返回 1500' {
    function Test-MtuPayload { return $true }
    Assert-True ((Get-PathMtu 'mtu.example') -eq 1500) '标准 MTU 结果错误'
}
Test-Case 'MTU 二分包含 1499 上边界' {
    function Test-MtuPayload { param($Target, [int]$Payload) return ($Payload -le 1471) }
    Assert-True ((Get-PathMtu 'mtu.example') -eq 1499) '二分区间丢失了 1499 边界'
}
Test-Case 'MTU 二分必须有已成功的下界' {
    function Test-MtuPayload { param($Target, [int]$Payload) return ($Payload -le 1400) }
    Assert-True ((Get-PathMtu 'mtu.example') -eq 1428) '已确认下界后的二分结果错误'
}

$script:campusReportDependencies = {
    $script:PortalScript = {
        param([switch]$NoRun)
        function Get-CampusState { return $script:fixtureAuth }
    }
    function Test-Path { return $true }
    function Get-PrimaryAdapter { return $null }
    function Get-NetIPAddress { return @() }
    function Measure-DnsOnce { return 20 }
    function Get-ItemProperty { return [pscustomobject]@{ ProxyEnable = 0; ProxyOverride = '' } }
    function netsh { return '' }
    function Get-PathMtu { return $null }
}
Test-Case '无法测量 MTU 的报告不建议伪造数值' {
    . $script:campusReportDependencies
    $script:fixtureAuth = [pscustomobject]@{ Authenticated = $false; Detail = '测试未认证' }
    $finding = (Get-CampusReport).Findings | Where-Object Id -eq 'mtu'
    Assert-True ($finding.Severity -eq 'warn' -and $finding.Detail -match '无法测量|未知') '未知 MTU 未清楚报告为无法测量'
    Assert-True ($finding.Detail -notmatch '1228|偏小' -and $finding.Fix -notmatch '按此值|调整.*MTU') '无法测量时仍建议按虚假数值修改网卡'
}
Test-Case '体检保留 HTTPS 未完成说明，不误导用户重新登录' {
    . $script:campusReportDependencies
    $script:fixtureAuth = [pscustomobject]@{ Authenticated = $false; VerificationKnown = $false; HttpsVerified = $false; Detail = '连通性探测通过；HTTPS 实测未完成（缺少 curl.exe）' }
    $finding = (Get-CampusReport).Findings | Where-Object Id -eq 'auth'
    Assert-True ($finding.Severity -eq 'warn' -and $finding.Detail -match '未完成' -and [string]::IsNullOrWhiteSpace($finding.Fix)) '无法完成验证时仍指示用户登录'
}

$script:routeReportDependencies = {
    $script:VirtualPattern = '(?i)vpn|virtual|tun'
    function Get-WinInetState { return $script:fixtureProxy }
    function Get-DefaultRouteTable { return @() }
    function Get-NetAdapter { return @() }
    function Get-NetTCPConnection {
        param($State, $LocalPort)
        if (-not $PSBoundParameters.ContainsKey('LocalPort')) { return @($script:fixtureListeners) }
        return @($script:fixtureListeners | Where-Object { $_.LocalPort -eq $LocalPort })
    }
}
Test-Case '远端代理无本地同端口监听时状态为未知' {
    . $script:routeReportDependencies
    $script:fixtureProxy = [pscustomobject]@{ Enabled = $true; Server = 'proxy.example:8080'; Override = ''; PacUrl = '' }
    $script:fixtureListeners = @()
    $finding = (Get-RouteGuardReport).Findings | Where-Object Id -eq 'stale-proxy'
    Assert-True ($finding.Severity -eq 'warn' -and $finding.Detail -match '未验证|未知|未检测|无法') '远端代理被本机端口未监听误报为残留'
    Assert-True ($finding.Detail -notmatch '没有进程监听|所有网页都会') '仍使用本机监听推断远端代理死亡'
}
Test-Case '本机同端口监听也不能证明远端代理存活' {
    . $script:routeReportDependencies
    $script:fixtureProxy = [pscustomobject]@{ Enabled = $true; Server = 'proxy.example:8080'; Override = ''; PacUrl = '' }
    $script:fixtureListeners = @([pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 8080 })
    $finding = (Get-RouteGuardReport).Findings | Where-Object Id -eq 'stale-proxy'
    Assert-True ($finding.Severity -eq 'warn' -and $finding.Detail -notmatch '端口存活') '本机监听被误当作远端端点存活'
}
Test-Case '无法解析的系统代理地址返回未知' {
    . $script:routeReportDependencies
    $script:fixtureProxy = [pscustomobject]@{ Enabled = $true; Server = 'not-an-endpoint'; Override = ''; PacUrl = '' }
    $script:fixtureListeners = @()
    $finding = (Get-RouteGuardReport).Findings | Where-Object Id -eq 'stale-proxy'
    Assert-True ($finding.Severity -eq 'warn' -and $finding.Detail -match '无法|未知') '无法解析的代理配置被断言为残留'
}
Test-Case '本地代理未监听仍能识别残留' {
    . $script:routeReportDependencies
    $script:fixtureProxy = [pscustomobject]@{ Enabled = $true; Server = '127.0.0.1:7897'; Override = ''; PacUrl = '' }
    $script:fixtureListeners = @()
    $finding = (Get-RouteGuardReport).Findings | Where-Object Id -eq 'stale-proxy'
    Assert-True ($finding.Severity -eq 'err') '本地代理残留没有被识别'
}
Test-Case '没有匹配端口时不能把查询空结果混同为读取失败' {
    . $script:routeReportDependencies
    $script:fixtureProxy = [pscustomobject]@{ Enabled = $true; Server = '127.0.0.1:7897'; Override = ''; PacUrl = '' }
    function Get-NetTCPConnection {
        param($State, $LocalPort)
        if ($PSBoundParameters.ContainsKey('LocalPort')) { throw '模拟 CIM 按端口查询没有匹配对象' }
        return @()
    }
    $finding = (Get-RouteGuardReport).Findings | Where-Object Id -eq 'stale-proxy'
    Assert-True ($finding.Severity -eq 'err') '按端口查询空结果异常使残留被误判为未知'
}
Test-Case '无法读取本地监听表时只报告状态未知' {
    . $script:routeReportDependencies
    $script:fixtureProxy = [pscustomobject]@{ Enabled = $true; Server = '127.0.0.1:7897'; Override = ''; PacUrl = '' }
    function Get-NetTCPConnection { throw '模拟 CIM 不可用' }
    $finding = (Get-RouteGuardReport).Findings | Where-Object Id -eq 'stale-proxy'
    Assert-True ($finding.Severity -eq 'warn' -and $finding.Detail -match '无法|未知') '查询失败被错误判定为端口死亡'
}
Test-Case '本地其他地址的监听不能证明目标环回地址存活' {
    . $script:routeReportDependencies
    $script:fixtureProxy = [pscustomobject]@{ Enabled = $true; Server = '127.0.0.1:7897'; Override = ''; PacUrl = '' }
    $script:fixtureListeners = @([pscustomobject]@{ LocalAddress = '192.0.2.44'; LocalPort = 7897 })
    $finding = (Get-RouteGuardReport).Findings | Where-Object Id -eq 'stale-proxy'
    Assert-True ($finding.Severity -eq 'err') '无关本地地址监听使目标代理被误判存活'
}
Test-Case 'IPv6 环回地址监听可以证明对应本地代理端口存活' {
    . $script:routeReportDependencies
    $script:fixtureProxy = [pscustomobject]@{ Enabled = $true; Server = '[::1]:7897'; Override = ''; PacUrl = '' }
    $script:fixtureListeners = @([pscustomobject]@{ LocalAddress = '::1'; LocalPort = 7897 })
    $finding = (Get-RouteGuardReport).Findings | Where-Object Id -eq 'stale-proxy'
    Assert-True ($finding.Severity -eq 'ok') '对应 IPv6 环回代理监听被错误判定为残留'
}
foreach ($listenAddress in @('0.0.0.0', '::', '192.0.2.44', '2001:db8::44')) {
    Test-Case ("代理监听非环回地址应提示暴露：{0}" -f $listenAddress) {
        . $script:routeReportDependencies
        $script:fixtureProxy = [pscustomobject]@{ Enabled = $false; Server = '127.0.0.1:7897'; Override = ''; PacUrl = '' }
        $script:fixtureListeners = @([pscustomobject]@{ LocalAddress = $listenAddress; LocalPort = 7897 })
        $finding = (Get-RouteGuardReport -ProxyPort 7897).Findings | Where-Object Id -eq 'lan-expose'
        Assert-True ($finding.Severity -eq 'warn' -and $finding.Detail -notmatch '仅本机') '明确网卡地址被误报为仅本机可用'
    }
}
foreach ($listenAddress in @('127.0.0.1', '127.0.0.2', '::1')) {
    Test-Case ("代理环回监听仍标记为仅本机：{0}" -f $listenAddress) {
        . $script:routeReportDependencies
        $script:fixtureProxy = [pscustomobject]@{ Enabled = $false; Server = '127.0.0.1:7897'; Override = ''; PacUrl = '' }
        $script:fixtureListeners = @([pscustomobject]@{ LocalAddress = $listenAddress; LocalPort = 7897 })
        $finding = (Get-RouteGuardReport -ProxyPort 7897).Findings | Where-Object Id -eq 'lan-expose'
        Assert-True ($finding.Severity -eq 'ok' -and $finding.Detail -match '仅本机') '环回监听被错误提示为局域网暴露'
    }
}
Test-Case '无效代理端口不能使报告抛异常或被当作有效端点' {
    Assert-True ((Get-ProxyPortFromRegistry 'proxy.example:999999999999999999999') -eq 0) '越界代理端口没有返回未知'
    Assert-True ((Get-ProxyPortFromRegistry 'proxy.example:65536') -eq 0) '无效 TCP 端口仍被接受'
}

Write-Host ("诊断回归：{0} 项，{1} 个失败" -f $script:total, $script:fail)
if ($script:fail) { exit 1 }
exit 0
