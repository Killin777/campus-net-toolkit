#Requires -Version 5.1
<#
    src/lib/WifiList.ps1 — 我的网络列表

    用户在「设置」里维护一份自己信任的网络清单：
      · 每条记录一个 SSID、它是不是校园网
      · 校园网条目要填认证网址；普通条目依赖系统里已保存的密码
      · 断网时按列表顺序尝试重连

    安全边界：
      · 不保存 WiFi 密码。普通网络依赖 Windows 已保存的配置文件
      · 校园网认证网址只用于打开登录页，不涉及凭据

    数据文件：<数据目录>\config\wifi-list.json

    用法（独立运行）：
      .\WifiList.ps1 show    打印当前列表
      .\WifiList.ps1 json    输出 JSON
#>
[CmdletBinding()]
param(
    [ValidateSet('show', 'json')]
    [string]$WifiAction = 'show',
    [switch]$NoRun
)

$ErrorActionPreference = 'Continue'

if ([Console]::IsOutputRedirected) {
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
}

function Get-WifiListDataRoot {
    if ($env:CAMPUS_NET_DATA_ROOT) { return $env:CAMPUS_NET_DATA_ROOT }
    if ($script:DataRoot) { return $script:DataRoot }
    return (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
}

function Get-WifiListPath {
    return (Join-Path (Get-WifiListDataRoot) 'config\wifi-list.json')
}

function New-WifiEntry {
    param([string]$Ssid, [bool]$Campus = $false, [string]$PortalUrl = '', [bool]$AutoReconnect = $true)
    [pscustomobject]@{
        ssid          = $Ssid
        campus        = $Campus
        portalUrl     = $PortalUrl
        autoReconnect = $AutoReconnect
    }
}

function Read-WifiList {
    $path = Get-WifiListPath
    $result = [pscustomobject]@{
        autoReconnect = $true
        networks      = @()
    }

    if (Test-Path -LiteralPath $path) {
        try {
            $j = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $j.PSObject.Properties['autoReconnect']) { $result.autoReconnect = [bool]$j.autoReconnect }
            $list = @()
            foreach ($n in @($j.networks)) {
                if (-not $n -or [string]::IsNullOrWhiteSpace([string]$n.ssid)) { continue }
                $list += [pscustomobject]@{
                    ssid          = [string]$n.ssid
                    campus        = [bool]$n.campus
                    portalUrl     = [string]$n.portalUrl
                    autoReconnect = if ($null -ne $n.PSObject.Properties['autoReconnect']) { [bool]$n.autoReconnect } else { $true }
                }
            }
            $result.networks = @($list)
        } catch { }
    }

    if ($result.networks.Count -eq 0) {
        # 首次使用：从旧的 campus-config.json 迁移一条校园网记录
        $campus = $null
        foreach ($f in @(
                (Join-Path (Get-WifiListDataRoot) 'config\campus-config.json'),
                (Join-Path (Get-WifiListDataRoot) 'runtime\imported-campus-config.json'))) {
            if (-not (Test-Path -LiteralPath $f)) { continue }
            try {
                $c = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($c.ssid) { $campus = $c; break }
            } catch { }
        }
        if ($campus) {
            $result.networks = @((New-WifiEntry -Ssid ([string]$campus.ssid) -Campus $true -PortalUrl ([string]$campus.portalUrl)))
        }
    }

    return $result
}

function Save-WifiList($List) {
    $path = Get-WifiListPath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $networks = @()
    foreach ($n in @($List.networks)) {
        if (-not $n -or [string]::IsNullOrWhiteSpace([string]$n.ssid)) { continue }
        $networks += [ordered]@{
            ssid          = [string]$n.ssid
            campus        = [bool]$n.campus
            portalUrl     = [string]$n.portalUrl
            autoReconnect = [bool]$n.autoReconnect
        }
    }
    $doc = [ordered]@{
        autoReconnect = [bool]$List.autoReconnect
        networks      = $networks
    }
    [IO.File]::WriteAllText($path, ($doc | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

function Get-CampusFromList($List) {
    foreach ($n in @($List.networks)) {
        if ($n.campus -and -not [string]::IsNullOrWhiteSpace([string]$n.portalUrl)) { return $n }
    }
    foreach ($n in @($List.networks)) {
        if ($n.campus) { return $n }
    }
    return $null
}

function Get-ReconnectOrder($List) {
    return @(@($List.networks) | Where-Object { $_.autoReconnect -and -not [string]::IsNullOrWhiteSpace([string]$_.ssid) })
}

if (-not $NoRun) {
    $data = Read-WifiList
    switch ($WifiAction) {
        'json' { $data | ConvertTo-Json -Depth 5 }
        'show' {
            Write-Host ("自动重连：{0}" -f $(if ($data.autoReconnect) { '开' } else { '关' }))
            if (@($data.networks).Count -eq 0) { Write-Host '  （列表为空）'; break }
            foreach ($n in $data.networks) {
                $kind = if ($n.campus) { '校园网' } else { '普通' }
                $extra = if ($n.campus) { $n.portalUrl } else { '依赖系统已保存密码' }
                Write-Host ("  {0,-20} {1,-6} 重连:{2,-2} {3}" -f $n.ssid, $kind, $(if ($n.autoReconnect) { '开' } else { '关' }), $extra)
            }
        }
    }
}
