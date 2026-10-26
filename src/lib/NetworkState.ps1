#Requires -Version 5.1
# 可独立测试的状态采集与恢复。不在加载时修改系统。
function Test-TcpEndpoint([string]$Server, [int]$Port) {
    $client = New-Object Net.Sockets.TcpClient
    $pending = $null
    try {
        $pending = $client.BeginConnect($Server, $Port, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne(400)) { return $false }
        $client.EndConnect($pending)
        return $true
    } catch { return $false }
    finally { if ($pending) { $pending.AsyncWaitHandle.Close() }; $client.Close() }
}

function Get-SystemProxyStatus([int]$ConfiguredPort = 7897) {
    if ($ConfiguredPort -lt 1 -or $ConfiguredPort -gt 65535) { $ConfiguredPort=7897 }
    $reg = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    $on = $reg.ProxyEnable -eq 1
    $server = '127.0.0.1'
    $port = $ConfiguredPort
    $known = $true
    $endpoint = [string]$reg.ProxyServer
    if ($on) {
        $entry = @($endpoint -split ';' | Where-Object { $_ -match '^\s*http=' }) | Select-Object -First 1
        if (-not $entry) { $entry = @($endpoint -split ';' | Where-Object { $_ }) | Select-Object -First 1 }
        $entry = $entry -replace '^\s*\w+=', ''
        if ($entry -match '^\s*(\[[^\]]+\]|[^:;\s]+):(\d+)\s*$') {
            $server=$Matches[1].Trim('[',']'); $port=[int]$Matches[2]
            if ($port -lt 1 -or $port -gt 65535) { $known=$false }
        } else { $known=$false }
    }
    $alive = $false
    if ($known) { $alive = Test-TcpEndpoint $server $port }
    return [pscustomobject]@{ Enabled=$on; Alive=$alive; Known=$known; Host=$server; Port=$port; Endpoint=$(if ($on) { $endpoint } else { '127.0.0.1:' + $ConfiguredPort }); PacUrl=[string]$reg.AutoConfigURL }
}

function Get-DnsSnapshot([string]$InterfaceAlias) {
    $adapter = Get-NetAdapter -Name $InterfaceAlias -ErrorAction Stop
    $guid = '{' + ([guid]$adapter.InterfaceGuid).ToString() + '}'
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\' + $guid
    $reg = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
    $dns = @(Get-DnsClientServerAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ErrorAction Stop | Select-Object -ExpandProperty ServerAddresses)
    return [pscustomobject]@{
        Interface = $InterfaceAlias; InterfaceGuid = [string]$adapter.InterfaceGuid
        Automatic = [string]::IsNullOrWhiteSpace([string]$reg.NameServer)
        Servers = $dns
    }
}

function Restore-DnsSnapshot($Snapshot) {
    $name = [string]$Snapshot.Interface
    if ($Snapshot.InterfaceGuid) {
        $adapter = Get-NetAdapter -ErrorAction Stop | Where-Object { [string]$_.InterfaceGuid -eq [string]$Snapshot.InterfaceGuid } | Select-Object -First 1
        if (-not $adapter) { throw '备份中的网卡不存在，保留记录，待网卡恢复后重试' }
        $name = $adapter.Name
    }
    $servers = @($Snapshot.Servers | Where-Object { $_ })
    if ($Snapshot.Automatic -eq $true -or $servers.Count -eq 0) {
        Set-DnsClientServerAddress -InterfaceAlias $name -ResetServerAddresses -ErrorAction Stop
    } else {
        Set-DnsClientServerAddress -InterfaceAlias $name -ServerAddresses $servers -ErrorAction Stop
    }
}

function Save-ProxySnapshot {
    $path = Join-Path $script:DataRoot 'runtime\proxy-backup.json'
    if (Test-Path -LiteralPath $path) {
        $existing = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if (-not $existing.PSObject.Properties['Enabled']) { throw '现有代理备份无效，已中止修改，请先检查备份' }
        return
    }
    $reg = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
    $snapshot = [ordered]@{ Enabled=($reg.ProxyEnable -eq 1); Server=[string]$reg.ProxyServer; Override=[string]$reg.ProxyOverride; PacUrl=[string]$reg.AutoConfigURL; Exists=@{}; savedAt=(Get-Date).ToString('s') }
    foreach ($name in 'ProxyEnable','ProxyServer','ProxyOverride','AutoConfigURL') { $snapshot.Exists[$name] = [bool]$reg.PSObject.Properties[$name] }
    Save-ToolkitJson $snapshot $path
}

function Send-ProxySettingsChanged {
    if (-not ('CampusNet.WinInet' -as [type])) {
        Add-Type -Namespace CampusNet -Name WinInet -MemberDefinition '[DllImport("wininet.dll")] public static extern bool InternetSetOption(IntPtr h, int o, IntPtr b, int l);'
    }
    [void][CampusNet.WinInet]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
    [void][CampusNet.WinInet]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)
}

function Restore-ProxySnapshot($Snapshot) {
    $reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $values = @{ ProxyEnable=[int]([bool]$Snapshot.Enabled); ProxyServer=[string]$Snapshot.Server; ProxyOverride=[string]$Snapshot.Override; AutoConfigURL=[string]$Snapshot.PacUrl }
    foreach ($name in $values.Keys) {
        if ($Snapshot.Exists -and $Snapshot.Exists.$name -eq $false) {
            $current = Get-ItemProperty -LiteralPath $reg -ErrorAction Stop
            if ($current.PSObject.Properties[$name]) { Remove-ItemProperty -LiteralPath $reg -Name $name -ErrorAction Stop }
        } else { Set-ItemProperty -LiteralPath $reg -Name $name -Value $values[$name] -ErrorAction Stop }
    }
    Send-ProxySettingsChanged
}

function New-NetBackup {
    $dir = Join-Path $script:DataRoot 'runtime'
    $path = Join-Path $dir ('network-backup-' + (Get-Date).ToString('yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6) + '.json')
    $snap = [ordered]@{ SchemaVersion=2; 时间=(Get-Date).ToString('s'); DNS=@{}; 跃点=@{}; 自动跃点=@{}; 传递优化=$null; 传递优化原存在=$false }
    $do = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config' -ErrorAction SilentlyContinue
    if ($do -and $do.PSObject.Properties['DODownloadMode']) { $snap.传递优化原存在=$true; $snap.传递优化=$do.DODownloadMode }
    foreach ($adapter in @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' -or $_.Name -match '^(Radmin VPN|Tailscale)$' })) {
        $snap.DNS[$adapter.Name] = Get-DnsSnapshot $adapter.Name
        $metric = Get-NetIPInterface -InterfaceAlias $adapter.Name -AddressFamily IPv4 -ErrorAction Stop | Select-Object -First 1
        if ($metric) { $snap.跃点[$adapter.Name]=$metric.InterfaceMetric; $snap.自动跃点[$adapter.Name]=[string]$metric.AutomaticMetric }
    }
    Save-ToolkitJson $snap $path
    return $path
}

function Restore-NetBackup([string]$Path) {
    $snap = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if (-not $snap.DNS -and -not $snap.跃点) { throw '文件不包含网络备份' }
    foreach ($p in $snap.DNS.PSObject.Properties) {
        $dns = if ($p.Value.PSObject.Properties['Servers']) { $p.Value } else { [pscustomobject]@{ Interface=$p.Name; Servers=@($p.Value); Automatic=(@($p.Value).Count -eq 0) } }
        Restore-DnsSnapshot $dns
    }
    foreach ($p in $snap.跃点.PSObject.Properties) {
        Set-NetIPInterface -InterfaceAlias $p.Name -AddressFamily IPv4 -InterfaceMetric ([int]$p.Value) -ErrorAction Stop
        if ($snap.自动跃点 -and $snap.自动跃点.($p.Name)) {
            Set-NetIPInterface -InterfaceAlias $p.Name -AddressFamily IPv4 -AutomaticMetric $snap.自动跃点.($p.Name) -ErrorAction Stop
        }
    }
    $doPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config'
    if ($null -ne $snap.传递优化) {
        if (-not (Test-Path -LiteralPath $doPath)) { New-Item -Path $doPath -Force -ErrorAction Stop | Out-Null }
        Set-ItemProperty -LiteralPath $doPath -Name DODownloadMode -Value ([int]$snap.传递优化) -Type DWord -ErrorAction Stop
    } elseif ($snap.SchemaVersion -ge 2 -and -not $snap.传递优化原存在) {
        $current = Get-ItemProperty -LiteralPath $doPath -ErrorAction SilentlyContinue
        if ($current -and $current.PSObject.Properties['DODownloadMode']) { Remove-ItemProperty -LiteralPath $doPath -Name DODownloadMode -ErrorAction Stop }
    }
}

function Move-RestoredBackup([string]$Path) {
    $history = Join-Path (Split-Path -Parent $Path) 'history'
    [void][IO.Directory]::CreateDirectory($history)
    $destination = Join-Path $history ((Get-Date).ToString('yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6) + '-' + [IO.Path]::GetFileName($Path))
    Move-Item -LiteralPath $Path -Destination $destination -ErrorAction Stop
}
