#Requires -Version 5.1
<#
    统一断链历史。调用方先加载 Common.ps1 并定义 $script:DataRoot。
    点源只声明函数，不读取日志、不写文件、不更改网络。
    默认数组接口保持旧调用；-Result 返回 Known/Error，读取失败不伪造空集。
#>

function Get-LinkEventStore {
    param([switch]$Result)
    $path = Join-Path $script:DataRoot 'runtime\link-events.json'
    $records = New-Object 'System.Collections.Generic.List[object]'
    $errorText = ''
    if ([IO.File]::Exists($path)) {
        try {
            $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
            if ([string]::IsNullOrWhiteSpace($text)) { throw '文件内容为空，无法确认是否丢失记录' }
            $raw = ConvertFrom-Json -InputObject $text -ErrorAction Stop
            foreach ($entry in @($raw)) {
                if ($null -eq $entry -or -not $entry.at -or -not $entry.kind) { throw '记录缺少 at/kind 字段' }
                $at = [datetime]$entry.at
                $seconds = [int]$entry.seconds
                if ($seconds -lt 0) { throw '记录的 seconds 不能小于零' }
                $start = if ($entry.start) { [datetime]$entry.start } else { $at.AddSeconds(-$seconds) }
                if ($start -gt $at) { throw '记录开始时间晚于结束时间' }
                $durationKnown = ($entry.durationKnown -eq $true)
                $estimate = if ($entry.PSObject.Properties['estimate']) { [bool]$entry.estimate } else { -not $durationKnown }
                $lowerBound = if ($entry.PSObject.Properties['lowerBoundSeconds']) { [int]$entry.lowerBoundSeconds } else { 0 }
                $records.Add([pscustomobject]@{
                    At = $at; Start = $start; Kind = [string]$entry.kind; Seconds = $seconds
                    Source = $(if ($entry.source) { [string]$entry.source } else { 'watchdog' })
                    DurationKnown = $durationKnown; Estimate = $estimate; LowerBoundSeconds = $lowerBound
                })
            }
        } catch { $errorText = '断链记录读取失败：' + $_.Exception.Message }
    }
    $read = [pscustomobject]@{ Records = @($records.ToArray()); Known = ($errorText -eq ''); Error = $errorText }
    if ($Result) { return $read }
    if (-not $read.Known) { throw $read.Error }
    return $read.Records
}

function Add-LinkEvent {
    param(
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$Kind,
        [Parameter(Mandatory=$true)][ValidateRange(0,2147483647)][int]$Seconds,
        [ValidateNotNullOrEmpty()][string]$Source = 'watchdog',
        [datetime]$At,
        [datetime]$Start,
        [switch]$DurationKnown,
        [switch]$Estimate,
        [ValidateRange(0,2147483647)][int]$LowerBoundSeconds = 0,
        [switch]$PassThru
    )
    if (-not $PSBoundParameters.ContainsKey('At')) { $At = Get-Date }
    if (-not $PSBoundParameters.ContainsKey('Start')) { $Start = $At.AddSeconds(-$Seconds) }
    if ($Start -gt $At -or $LowerBoundSeconds -gt $Seconds) { throw '断链记录的时间范围或采样下界无效' }
    $read = Get-LinkEventStore -Result
    if (-not $read.Known) { throw $read.Error }
    $record = [pscustomobject]@{
        At = $At; Start = $Start; Kind = $Kind; Seconds = $Seconds; Source = $Source
        DurationKnown = [bool]$DurationKnown; Estimate = ([bool]$Estimate -or -not $DurationKnown)
        LowerBoundSeconds = $LowerBoundSeconds
    }
    $cut = (Get-Date).AddDays(-30)
    $list = @(@($read.Records) + @($record) | Where-Object { $_.At -ge $cut })
    $doc = @($list | ForEach-Object {
        [ordered]@{
            at=$_.At.ToString('o'); start=$_.Start.ToString('o'); kind=$_.Kind; seconds=$_.Seconds; source=$_.Source
            durationKnown=$_.DurationKnown; estimate=$_.Estimate; lowerBoundSeconds=$_.LowerBoundSeconds
        }
    })
    if ($doc.Count -eq 0) { throw '新增记录不在最近30天范围内，未改写历史文件' }
    Save-ToolkitJson -Value $doc -Path (Join-Path $script:DataRoot 'runtime\link-events.json')
    if ($PassThru) { return $record }
}

function Get-SystemDisconnectTimes {
    param([ValidateRange(1,3650)][int]$Days = 7, [switch]$Result)
    $errorText = ''
    $times = @()
    try {
        $events = @(Get-WinEvent -FilterHashtable @{
            LogName='Microsoft-Windows-WLAN-AutoConfig/Operational'; StartTime=(Get-Date).AddDays(-$Days); Id=11004
        } -ErrorAction Stop)
        $times = @($events | Sort-Object TimeCreated | ForEach-Object { [datetime]$_.TimeCreated })
    } catch {
        if ($_.FullyQualifiedErrorId -notmatch 'NoMatchingEventsFound') { $errorText = 'WLAN事件读取失败：' + $_.Exception.Message }
    }
    $read = [pscustomobject]@{ Times = $times; Known = ($errorText -eq ''); Error = $errorText }
    if ($Result) { return $read }
    if (-not $read.Known) { throw $read.Error }
    return $read.Times
}

function Get-LinkIgnoreWindows {
    $path = Join-Path $script:DataRoot 'runtime\link-events-ignore.json'
    $windows = New-Object 'System.Collections.Generic.List[object]'
    $errorText = ''
    if ([IO.File]::Exists($path)) {
        try {
            $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
            if ([string]::IsNullOrWhiteSpace($text)) { throw '维护窗口内容为空' }
            $raw = ConvertFrom-Json -InputObject $text -ErrorAction Stop
            foreach ($entry in @($raw)) {
                if ($null -eq $entry -or -not $entry.start -or -not $entry.end) { throw '维护窗口缺少 start/end 字段' }
                $start = [datetime]$entry.start
                $end = [datetime]$entry.end
                if ($end -lt $start) { throw '维护窗口结束时间早于开始时间' }
                $windows.Add([pscustomobject]@{ Start=$start; End=$end; Reason=[string]$entry.reason })
            }
        } catch { $errorText = '维护窗口读取失败：' + $_.Exception.Message }
    }
    return [pscustomobject]@{ Windows=@($windows.ToArray()); Known=($errorText -eq ''); Error=$errorText }
}

function Test-LinkIgnoreWindow {
    param([datetime]$Start,[datetime]$End)
    $ignore = Get-LinkIgnoreWindows
    if (-not $ignore.Known) { return $false }
    foreach ($window in $ignore.Windows) {
        if ($Start -le $window.End -and $End -ge $window.Start) { return $true }
    }
    return $false
}

function Merge-LinkHistory {
    param(
        [object[]]$ToolRecords = @(),
        [datetime[]]$SystemTimes = @(),
        [object[]]$IgnoreWindows = @(),
        [datetime]$Since = [datetime]::MinValue
    )
    $all = New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in $ToolRecords) {
        if ($entry.At -lt $Since -or $entry.Kind -ne '断链') { continue }
        $all.Add([pscustomobject]@{
            Start=$entry.Start; End=$entry.At; Seconds=[int]$entry.Seconds; Source=[string]$entry.Source; Events=1
            Kind='断链'; DurationKnown=[bool]$entry.DurationKnown; Estimate=[bool]$entry.Estimate
            LowerBoundSeconds=[int]$entry.LowerBoundSeconds
            Precision=$(if ($entry.DurationKnown) { 'measured' } else { 'sampling-estimate' })
        })
    }
    $times = @($SystemTimes | Where-Object { $_ -ge $Since } | Sort-Object)
    $systemSessions = New-Object 'System.Collections.Generic.List[object]'
    $current = $null
    foreach ($time in $times) {
        if ($null -eq $current -or ($time - $current.End).TotalSeconds -gt 180) {
            $current = [pscustomobject]@{
                Start=$time; End=$time; Seconds=0; Source='wlan'; Events=1; Kind='断链'
                DurationKnown=$false; Estimate=$false; LowerBoundSeconds=0; Precision='event-only'
            }
            $systemSessions.Add($current)
        } else { $current.End=$time; $current.Events++ }
    }
    $merged = 0
    foreach ($session in $systemSessions) {
        $hit = $null
        foreach ($candidate in $all) {
            if ($candidate.Source -eq 'wlan') { continue }
            if ($session.Start -le $candidate.End.AddSeconds(90) -and $session.End -ge $candidate.Start.AddSeconds(-90)) {
                $hit = $candidate
                break
            }
        }
        if ($hit) {
            $hit.Events += $session.Events
            $hit.Source += '+wlan'
            # 保存原采样区间和时长，系统事件只补充来源与会话过滤范围。
            $hit | Add-Member -NotePropertyName SystemStart -NotePropertyValue $session.Start -Force
            $hit | Add-Member -NotePropertyName SystemEnd -NotePropertyValue $session.End -Force
            $merged++
        } else { $all.Add($session) }
    }
    $kept = New-Object 'System.Collections.Generic.List[object]'
    $ignored = 0
    foreach ($session in $all) {
        $start = $session.Start
        $end = $session.End
        if ($session.PSObject.Properties['SystemStart'] -and $session.SystemStart -lt $start) { $start=$session.SystemStart }
        if ($session.PSObject.Properties['SystemEnd'] -and $session.SystemEnd -gt $end) { $end=$session.SystemEnd }
        $intersects = $false
        foreach ($window in $IgnoreWindows) {
            if ($start -le $window.End -and $end -ge $window.Start) { $intersects=$true; break }
        }
        if ($intersects) { $ignored += $session.Events } else { $kept.Add($session) }
    }
    return [pscustomobject]@{
        Sessions=@($kept.ToArray() | Sort-Object Start); SystemN=$times.Count; Ignored=$ignored
        Merged=$merged; RawMerged=($times.Count-$systemSessions.Count)
    }
}

function Get-UnifiedLinkEvents {
    param([ValidateRange(1,3650)][int]$Days = 7)
    $tool = Get-LinkEventStore -Result
    $system = Get-SystemDisconnectTimes -Days $Days -Result
    $ignore = Get-LinkIgnoreWindows
    $merged = Merge-LinkHistory -ToolRecords $tool.Records -SystemTimes $system.Times -IgnoreWindows $ignore.Windows -Since (Get-Date).AddDays(-$Days)
    $errors = @($tool.Error,$system.Error,$ignore.Error | Where-Object { $_ })
    $known = ($tool.Known -and $system.Known -and $ignore.Known)
    $detail = if (-not $known) { '记录未完整读取；当前次数不能代表完整观察范围。' }
    elseif ($merged.Sessions.Count -eq 0) { '该范围内未记录断链；两次观察之间的短暂中断可能未被记录。' }
    else { 'WLAN事件与工具观察已合并并统一排除维护窗口；采样时长为估计。' }
    $merged | Add-Member -NotePropertyMembers @{
        Known=$known; Error=($errors -join '；'); Detail=$detail; ObservedAt=(Get-Date); ObservationGapSeconds=30
    }
    return $merged
}

function New-LinkObservationTracker {
    return [pscustomobject]@{
        LastObservedAt=$null; Ready=$false; DownSince=$null; LastDownAt=$null; MaximumGapSeconds=75
    }
}

function Update-LinkObservationTracker {
    param(
        [Parameter(Mandatory=$true)]$Tracker,
        [Parameter(Mandatory=$true)]$Snapshot,
        [switch]$Ignored,
        [switch]$Suspended
    )
    $next = [pscustomobject]@{
        LastObservedAt=$Tracker.LastObservedAt; Ready=$Tracker.Ready; DownSince=$Tracker.DownSince
        LastDownAt=$Tracker.LastDownAt; MaximumGapSeconds=$Tracker.MaximumGapSeconds
    }
    $at = [datetime]$Snapshot.Connection.CheckedAt
    $result = [pscustomobject]@{ Tracker=$next; Event=$null; Detail='约30秒连接状态观察，无法覆盖两次采样之间的所有中断。' }
    if ($Ignored -or $Suspended) {
        $next.Ready=$false; $next.DownSince=$null; $next.LastDownAt=$null
        $result.Detail='维护或暂停已中断观察，不计入自然断链。'
        return $result
    }
    if ($null -ne $next.LastObservedAt -and $at -le $next.LastObservedAt) { return $result }
    $gap = ($null -ne $next.LastObservedAt -and ($at-$next.LastObservedAt).TotalSeconds -gt $next.MaximumGapSeconds)
    $next.LastObservedAt=$at
    if ($gap -or -not $Snapshot.Connection.Known) {
        $next.Ready=($Snapshot.Connection.Known -and $Snapshot.Connection.Connected)
        $next.DownSince=$null; $next.LastDownAt=$null
        $result.Detail='维护、未知状态或观察空隙已中断覆盖，不计入自然断链。'
        return $result
    }
    if (-not $Snapshot.Connection.Connected) {
        if ($next.Ready) {
            if ($null -eq $next.DownSince) { $next.DownSince=$at }
            $next.LastDownAt=$at
        }
        return $result
    }
    if ($null -ne $next.DownSince) {
        $seconds=[int][Math]::Floor(($at-$next.DownSince).TotalSeconds)
        $lower=[int][Math]::Floor(($next.LastDownAt-$next.DownSince).TotalSeconds)
        $result.Event=[pscustomobject]@{
            At=$at; Start=$next.DownSince; Kind=$(if ($seconds -ge 10) { '断链' } else { '抖动' })
            Seconds=$seconds; Source='observer'; DurationKnown=$false; Estimate=$true; LowerBoundSeconds=$lower
        }
    }
    $next.Ready=$true; $next.DownSince=$null; $next.LastDownAt=$null
    return $result
}
