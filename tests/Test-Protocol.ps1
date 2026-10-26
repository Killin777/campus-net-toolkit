#Requires -Version 5.1
<#
    tests/Test-Protocol.ps1 — 协议识别测试

    在 127.0.0.1 上起临时假服务，模拟四种对端：
      · HTTP 200  → 应识别为 HTTP
      · HTTP 407  → 应识别为 HTTP-AUTH（要求认证）
      · SOCKS5    → 应识别为 SOCKS5
      · 非代理    → 应识别为 UNKNOWN（不能误判成代理）

    只监听本地端口，不修改任何系统设置。
#>
$root = Split-Path -Parent $PSScriptRoot
$proxyScript = Join-Path $root 'src\ProxyCtl.ps1'

if (-not (Test-Path $proxyScript)) { Write-Host "找不到 $proxyScript" -ForegroundColor Red; exit 1 }

$script:ProjRoot = $root
. $proxyScript -NoRun

function Start-FakePeer {
    param([string]$Mode)
    $job = Start-Job -ScriptBlock {
        param($m)
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
        Write-Output "READY $port"
        for ($n = 0; $n -lt 3; $n++) {
            $client = $listener.AcceptTcpClient()
            $st = $client.GetStream()
            $buf = New-Object byte[] 256
            try { [void]$st.Read($buf, 0, 256) } catch { }
            switch ($m) {
                'http200' {
                    $msg = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 Connection Established`r`n`r`n")
                    $st.Write($msg, 0, $msg.Length)
                }
                'http407' {
                    $msg = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 407 Proxy Authentication Required`r`n`r`n")
                    $st.Write($msg, 0, $msg.Length)
                }
                'socks5' {
                    $st.Write([byte[]]@(0x05, 0x00), 0, 2)
                }
                default {
                    $msg = [System.Text.Encoding]::ASCII.GetBytes("SSH-2.0-OpenSSH_9.0`r`n")
                    $st.Write($msg, 0, $msg.Length)
                }
            }
            $st.Flush()
            Start-Sleep -Milliseconds 150
            $client.Close()
        }
        $listener.Stop()
    } -ArgumentList $Mode

    $port = 0
    for ($i = 0; $i -lt 80; $i++) {
        Start-Sleep -Milliseconds 100
        foreach ($line in @(Receive-Job $job -Keep 2>$null)) {
            if ("$line" -match 'READY (\d+)') { $port = [int]$Matches[1]; break }
        }
        if ($port -gt 0) { break }
    }
    return [pscustomobject]@{ Job = $job; Port = $port }
}

$cases = @(
    @{ Mode = 'http200';  Expect = 'HTTP';      Desc = 'HTTP 代理（200）' },
    @{ Mode = 'http407';  Expect = 'HTTP-AUTH'; Desc = 'HTTP 代理要求认证' },
    @{ Mode = 'socks5';   Expect = 'SOCKS5';    Desc = 'SOCKS5 代理' },
    @{ Mode = 'nonproxy'; Expect = 'UNKNOWN';   Desc = '普通服务（SSH banner）' }
)

$fail = 0
foreach ($c in $cases) {
    $peer = Start-FakePeer -Mode $c.Mode
    if ($peer.Port -le 0) {
        Write-Host ("  × {0}：模拟服务未启动" -f $c.Desc) -ForegroundColor Red
        $fail++
        Remove-Job $peer.Job -Force -ErrorAction SilentlyContinue
        continue
    }
    $got = 'ERROR'
    try {
        $got = Detect-Protocol -h '127.0.0.1' -p $peer.Port -TimeoutMs 2000
    } catch {
        $got = "ERROR: $($_.Exception.Message)"
    }
    Stop-Job $peer.Job -ErrorAction SilentlyContinue
    Remove-Job $peer.Job -Force -ErrorAction SilentlyContinue

    if ($got -eq $c.Expect) {
        Write-Host ("  √ {0,-22} 识别为 {1}" -f $c.Desc, $got) -ForegroundColor Gray
    } else {
        $fail++
        Write-Host ("  × {0,-22} 期望 {1}，实际 {2}" -f $c.Desc, $c.Expect, $got) -ForegroundColor Red
    }
}

Write-Host ("协议识别：{0} 项，{1} 个失败" -f $cases.Count, $fail) -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
exit $(if ($fail) { 1 } else { 0 })
