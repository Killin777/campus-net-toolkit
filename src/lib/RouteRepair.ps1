#Requires -Version 5.1
# 纯点源模块。调用方先加载 Common.ps1 和 RouteGuard.ps1。
# 每次只处理一个白名单目标；系统值与报告不一致时要求重新检测。

function Get-RouteRepairItems {
    param([Parameter(Mandatory = $true)]$Report)
    $items = @()
    foreach ($candidate in @($Report.MetricCandidates)) {
        if (-not $candidate.Competing -or -not $candidate.HardwareVirtual -or -not $candidate.HasRoute -or $null -eq $candidate.PhysicalCost) { continue }
        $desiredMetric = [int]$candidate.PhysicalCost - [int]$candidate.RouteMetric + 1
        if ($desiredMetric -le [int]$candidate.InterfaceMetric) { continue }
        $items += [pscustomobject]@{
            Id = 'interface-metric-' + $candidate.InterfaceIndex; Type = 'InterfaceMetric'
            Title = '降低「' + $candidate.InterfaceAlias + '」的默认出口优先级'
            Evidence = '当前默认路由成本 ' + $candidate.RouteCost + '，物理候选「' + $candidate.PhysicalInterfaceAlias + '」成本 ' + $candidate.PhysicalCost + '；这可能是用户所需的 VPN 路径，未据此认定故障'
            Target = [pscustomobject]@{ InterfaceIndex = [int]$candidate.InterfaceIndex; InterfaceAlias = [string]$candidate.InterfaceAlias; AddressFamily = 'IPv4' }
            Before = [pscustomobject]@{ InterfaceMetric = [int]$candidate.InterfaceMetric; AutomaticMetric = [string]$candidate.AutomaticMetric }
            Desired = [pscustomobject]@{ InterfaceMetric = $desiredMetric; AutomaticMetric = 'Disabled' }
            Impact = '将此接口默认路由成本调到物理候选成本加 1；关闭此接口的自动跃点。VPN/隧道可能不再承担默认流量，专用路由仍可能生效；如正需要 VPN 默认出口，请保留现状。'
            RequiresAdmin = $true; Selected = $false; CanApply = $true
        }
    }
    if ($Report.ProxyEvidence.ManualDisableSupported -and $Report.SystemProxy.ProxyEnableExists -and $Report.SystemProxy.ProxyEnableValue -eq 1) {
        $items += [pscustomobject]@{
            Id = 'manual-proxy-disable'; Type = 'ManualProxyDisable'; Title = '关闭无监听的手动系统代理'
            Evidence = '手动代理指向本机 ' + $Report.SystemProxy.Server + '，对应目标地址和端口没有监听；未据此判断 PAC 或应用自己的代理'
            Target = [pscustomobject]@{ RegistryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'; Name = 'ProxyEnable'; ProxyServer = [string]$Report.SystemProxy.Server }
            Before = [pscustomobject]@{ Exists = [bool]$Report.SystemProxy.ProxyEnableExists; Value = [int]$Report.SystemProxy.ProxyEnableValue }
            Desired = [pscustomobject]@{ Exists = $true; Value = 0 }
            Impact = '仅关闭手动系统代理开关。使用该设置的应用将改用自身默认连接；代理地址、绕过列表和 PAC 保持原值。'
            RequiresAdmin = $false; Selected = $false; CanApply = $true
        }
    }
    return $items
}

function Test-RouteRepairAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-RouteRepairTarget {
    param([string]$Type, $Target)
    switch ($Type) {
        'InterfaceMetric' {
            if ([int]$Target.InterfaceIndex -lt 1 -or [string]::IsNullOrWhiteSpace([string]$Target.InterfaceAlias) -or $Target.AddressFamily -ne 'IPv4') { throw '接口修复目标无效' }
            if (-not (Test-RouteRepairAdmin)) { throw '修改接口跃点需要管理员权限' }
        }
        'ManualProxyDisable' {
            if ($Target.RegistryPath -ne 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -or $Target.Name -ne 'ProxyEnable') { throw '手动代理修复目标无效' }
            $endpoint = Get-RouteProxyEndpoint ([string]$Target.ProxyServer)
            if (-not $endpoint.Known -or -not $endpoint.IsLoopback -or $Target.ProxyServer -match '[=;]') { throw '仅支持有明确本机单一端点证据的手动代理' }
        }
        default { throw '不支持的修复类型；仅允许 InterfaceMetric 和 ManualProxyDisable' }
    }
}

function Get-RouteRepairCurrentValue {
    param([string]$Type, $Target)
    if ($Type -eq 'InterfaceMetric') {
        $value = Get-NetIPInterface -InterfaceIndex $Target.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop | Select-Object -First 1
        if (-not $value -or $value.InterfaceAlias -ne $Target.InterfaceAlias) { throw '接口已改变或不存在，请重新检测' }
        return [pscustomobject]@{ InterfaceMetric = [int]$value.InterfaceMetric; AutomaticMetric = [string]$value.AutomaticMetric }
    }
    $value = Get-ItemProperty -LiteralPath $Target.RegistryPath -ErrorAction Stop
    return [pscustomobject]@{ Exists = [bool]$value.PSObject.Properties['ProxyEnable']; Value = $value.ProxyEnable }
}

function Test-RouteRepairValue {
    param([string]$Type, $Left, $Right)
    if ($null -eq $Left -or $null -eq $Right) { return $false }
    if ($Type -eq 'InterfaceMetric') {
        return ($Left.InterfaceMetric -eq $Right.InterfaceMetric -and [string]$Left.AutomaticMetric -eq [string]$Right.AutomaticMetric)
    }
    return ($Left.Exists -eq $Right.Exists -and (-not $Left.Exists -or $Left.Value -eq $Right.Value))
}

function Set-RouteRepairValue {
    param([string]$Type, $Target, $Value)
    if ($Type -eq 'InterfaceMetric') {
        Set-NetIPInterface -InterfaceIndex $Target.InterfaceIndex -AddressFamily IPv4 -InterfaceMetric ([int]$Value.InterfaceMetric) -AutomaticMetric $Value.AutomaticMetric -ErrorAction Stop
    } else {
        if ($Value.Exists) { Set-ItemProperty -LiteralPath $Target.RegistryPath -Name ProxyEnable -Value ([int]$Value.Value) -ErrorAction Stop }
        else { Remove-ItemProperty -LiteralPath $Target.RegistryPath -Name ProxyEnable -ErrorAction Stop }
        Send-ProxySettingsChanged
    }
}

function Invoke-RouteRepairItem {
    param([Parameter(Mandatory = $true)]$Item)
    $result = [pscustomobject]@{ Id = [string]$Item.Id; Ok = $false; Applied = $false; Verified = $false; RecordPath = ''; Before = $null; After = $null; Error = '' }
    try {
        Assert-RouteRepairTarget -Type $Item.Type -Target $Item.Target
        if (-not $Item.CanApply -or $Item.Id -notmatch '^[a-z0-9][a-z0-9-]*$') { throw '该项目不可执行，请重新检测' }
        if ($Item.Type -eq 'InterfaceMetric') {
            if ([int]$Item.Desired.InterfaceMetric -le [int]$Item.Before.InterfaceMetric -or $Item.Desired.AutomaticMetric -ne 'Disabled' -or $Item.Before.AutomaticMetric -notin @('Enabled', 'Disabled')) { throw '接口目标值或原值无效' }
        } elseif ($Item.Desired.Exists -ne $true -or $Item.Desired.Value -ne 0 -or $Item.Before.Exists -ne $true -or $Item.Before.Value -ne 1) { throw '代理目标值或原值无效' }
        $result.Before = Get-RouteRepairCurrentValue -Type $Item.Type -Target $Item.Target
        if (-not (Test-RouteRepairValue $Item.Type $result.Before $Item.Before)) { throw '当前值已改变，请刷新检测后重新选择' }
        # 不用旧报告覆盖后来恢复的代理；路由也用当前候选重新确认。
        $fresh = Get-RouteGuardReport
        $freshItems = @(Get-RouteRepairItems -Report $fresh)
        $freshItem = $freshItems | Where-Object { $_.Id -eq $Item.Id -and $_.Type -eq $Item.Type } | Select-Object -First 1
        if (-not $freshItem -or -not (Test-RouteRepairValue $Item.Type $freshItem.Before $result.Before) -or -not (Test-RouteRepairValue $Item.Type $freshItem.Desired $Item.Desired)) { throw '修复依据或目标已变化，请刷新检测' }
        if ($Item.Type -eq 'ManualProxyDisable' -and $freshItem.Target.ProxyServer -ne $Item.Target.ProxyServer) { throw '代理目标已改变，请刷新检测' }
        $path = Join-Path $script:DataRoot ('runtime\repair-' + (Get-Date).ToString('yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N') + '.json')
        $record = [pscustomobject]@{
            SchemaVersion = 1; Id = [string]$Item.Id; Type = [string]$Item.Type; SavedAt = (Get-Date).ToString('s')
            Target = $Item.Target; Before = $result.Before; Desired = $Item.Desired; After = $result.Before
            Applied = $false; Verified = $false; Restored = $false; Error = ''
        }
        Save-ToolkitJson $record $path
        $result.RecordPath = $path
    } catch { $result.Error = $_.Exception.Message; return $result }

    # 备份已落盘。写入失败也继续读取实际值，以保留部分写入的恢复依据。
    try {
        Add-IgnoreWindow ('逐项处理：' + $Item.Title) 30
        Set-RouteRepairValue -Type $Item.Type -Target $Item.Target -Value $Item.Desired
    } catch { $record.Error = $_.Exception.Message }
    try {
        $record.After = Get-RouteRepairCurrentValue -Type $Item.Type -Target $Item.Target
        $record.Applied = -not (Test-RouteRepairValue $Item.Type $record.Before $record.After)
        $record.Verified = Test-RouteRepairValue $Item.Type $Item.Desired $record.After
        if (-not $record.Verified) { $record.Error = ($record.Error + '；写入后复检未达到目标值').Trim('；') }
    } catch {
        $record.After = $null
        $record.Error = ($record.Error + '；写入后无法读取实际值：' + $_.Exception.Message).Trim('；')
    }
    try { Save-ToolkitJson $record $path }
    catch { $record.Error = ($record.Error + '；结果保存失败，原始备份仍在：' + $_.Exception.Message).Trim('；') }
    $result.Applied = $record.Applied; $result.Verified = $record.Verified; $result.After = $record.After; $result.Error = $record.Error
    $result.Ok = ($record.Verified -and [string]::IsNullOrEmpty($record.Error))
    return $result
}

function Undo-RouteRepairItem {
    param([Parameter(Mandatory = $true)][string]$RecordPath)
    $result = [pscustomobject]@{ Id = ''; Ok = $false; Applied = $false; Verified = $false; RecordPath = $RecordPath; Before = $null; After = $null; Error = '' }
    try {
        $record = Get-Content -LiteralPath $RecordPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $result.Id = [string]$record.Id
        if ($record.SchemaVersion -ne 1 -or $record.Restored) { throw '该记录格式不受支持或已经撤销' }
        Assert-RouteRepairTarget -Type $record.Type -Target $record.Target
        if ($record.Type -eq 'InterfaceMetric') {
            if ([int]$record.Before.InterfaceMetric -lt 1 -or $record.Before.AutomaticMetric -notin @('Enabled', 'Disabled')) { throw '备份中的接口原值无效' }
        } elseif ($record.Before.Exists -isnot [bool] -or ($record.Before.Exists -and $record.Before.Value -notin @(0, 1))) { throw '备份中的手动代理原值无效' }
        $result.Before = Get-RouteRepairCurrentValue -Type $record.Type -Target $record.Target
        if (-not (Test-RouteRepairValue $record.Type $result.Before $record.After)) { throw '当前值与本工具最后记录的值有冲突，可能已被外部改变；保留记录，请先核对' }
    } catch { $result.Error = $_.Exception.Message; return $result }
    $undoError = ''
    try {
        if (-not (Test-RouteRepairValue $record.Type $result.Before $record.Before)) {
            Add-IgnoreWindow ('撤销逐项处理：' + $record.Id) 30
            Set-RouteRepairValue -Type $record.Type -Target $record.Target -Value $record.Before
        }
    } catch { $undoError = $_.Exception.Message }
    try {
        $result.After = Get-RouteRepairCurrentValue -Type $record.Type -Target $record.Target
        $result.Applied = -not (Test-RouteRepairValue $record.Type $result.Before $result.After)
        $result.Verified = Test-RouteRepairValue $record.Type $record.Before $result.After
        if (-not $result.Verified) { $undoError = ($undoError + '；撤销后复检未达到原值').Trim('；') }
        # 撤销部分写入后，下一次只允许从这次实际值继续恢复。
        if (-not $result.Verified -or $undoError) { $record.After = $result.After }
    } catch { $undoError = ($undoError + '；撤销后无法读取实际值：' + $_.Exception.Message).Trim('；') }
    $record.Restored = ($result.Verified -and [string]::IsNullOrEmpty($undoError))
    $record.Error = $undoError
    try { Save-ToolkitJson $record $RecordPath }
    catch { $undoError = ($undoError + '；撤销结果保存失败：' + $_.Exception.Message).Trim('；') }
    $result.Error = $undoError
    $result.Ok = ($record.Restored -and [string]::IsNullOrEmpty($undoError))
    return $result
}

function Get-RouteRepairHistory {
    $directory = Join-Path $script:DataRoot 'runtime'
    if (-not (Test-Path -LiteralPath $directory)) { return @() }
    $records = foreach ($file in @(Get-ChildItem -LiteralPath $directory -Filter 'repair-*.json' -File -ErrorAction Stop | Sort-Object LastWriteTime -Descending)) {
        $record = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $record | Add-Member NoteProperty RecordPath $file.FullName -Force
        $record
    }
    return @($records)
}
