# router-diagnose.ps1 - find what's slowing down your home network (Windows).
# Run on a Windows PC connected to the router, in PowerShell:
#   powershell -ExecutionPolicy Bypass -File .\router-diagnose.ps1
# Read-only: it only pings, resolves names and downloads a test file.

$ErrorActionPreference = 'SilentlyContinue'
$PublicHost = '1.1.1.1'
$LoadUrl    = 'https://speed.cloudflare.com/__down?bytes=100000000'

function Hr($t)   { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Warn($t) { Write-Host "  [!] $t" -ForegroundColor Yellow }
function Ok($t)   { Write-Host "  [ok] $t" -ForegroundColor Green }

# Returns Loss (%), Avg (ms), Jitter (ms, mean change between consecutive pings)
function Get-PingStats([string]$Target, [int]$Count = 30) {
    $p = New-Object System.Net.NetworkInformation.Ping
    $times = @(); $lost = 0
    for ($i = 0; $i -lt $Count; $i++) {
        try {
            $r = $p.Send($Target, 1000)
            if ($r.Status -eq 'Success') { $times += [double]$r.RoundtripTime } else { $lost++ }
        } catch { $lost++ }
        Start-Sleep -Milliseconds 200
    }
    $loss = [math]::Round(100 * $lost / $Count, 1)
    if ($times.Count -eq 0) { return [pscustomobject]@{ Loss = 100; Avg = 9999; Jitter = 0 } }
    $avg = [math]::Round(($times | Measure-Object -Average).Average, 1)
    $jit = 0
    if ($times.Count -gt 1) {
        $d = @(); for ($i = 1; $i -lt $times.Count; $i++) { $d += [math]::Abs($times[$i] - $times[$i - 1]) }
        $jit = [math]::Round(($d | Measure-Object -Average).Average, 1)
    }
    [pscustomobject]@{ Loss = $loss; Avg = $avg; Jitter = $jit }
}

# --- Find the router (default gateway) --------------------------------------
$route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' |
    Where-Object { $_.NextHop -ne '0.0.0.0' } |
    Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | Select-Object -First 1
if (-not $route) { Write-Host 'Could not find a default gateway. Are you connected?'; exit 1 }
$GW = $route.NextHop; $Iface = $route.InterfaceAlias
Hr 'Router'
Write-Host "  Gateway: $GW   Interface: $Iface"

# --- 1. Local link: you -> router -------------------------------------------
Hr '1. Your PC -> router (Wi-Fi/Ethernet link)'
$L = Get-PingStats $GW 30
Write-Host "  loss=$($L.Loss)%  avg=$($L.Avg)ms  jitter=$($L.Jitter)ms"
if ($L.Loss -gt 1)   { Warn 'Packet loss to the router: weak Wi-Fi signal, interference, or a bad cable.' }
if ($L.Avg -gt 10)   { Warn 'Slow to reach the router (>10ms): usually a Wi-Fi problem (distance, walls, crowded channel).' }
if ($L.Jitter -gt 5) { Warn 'High jitter on the local link: interference or the router CPU is overloaded.' }
if ($L.Loss -le 1 -and $L.Avg -le 10) { Ok 'Local link looks healthy.' }

# --- 2. Wi-Fi details ---------------------------------------------------------
Hr '2. Wi-Fi signal and channel'
$wlan = netsh wlan show interfaces 2>$null
if ($wlan -and ($wlan -match '^\s*SSID\s*:')) {
    $wlan | Where-Object { $_ -match '^\s*(SSID|Radio type|Band|Channel|Signal|Receive rate|Transmit rate)\s' } |
        ForEach-Object { Write-Host "  $($_.Trim())" }
    $sigLine = $wlan | Where-Object { $_ -match '^\s*Signal\s*:' } | Select-Object -First 1
    $chLine  = $wlan | Where-Object { $_ -match '^\s*Channel\s*:' } | Select-Object -First 1
    if ($sigLine -match '(\d+)%') {
        $sig = [int]$Matches[1]
        if ($sig -lt 60) { Warn "Signal $sig% is weak (want 70%+). Move closer to the router or add a mesh node." }
        else { Ok "Signal $sig% is good." }
    }
    if ($chLine -match ':\s*(\d+)') {
        $myCh = $Matches[1]
        $nets = netsh wlan show networks mode=bssid 2>$null
        $chs  = $nets | Where-Object { $_ -match '^\s*Channel\s*:\s*(\d+)' } | ForEach-Object { ($_ -split ':')[1].Trim() }
        if ($chs) {
            $same = @($chs | Where-Object { $_ -eq $myCh }).Count - 1
            Write-Host "  Other access points on your channel ($myCh): $same"
            Write-Host '  Busiest channels nearby:'
            $chs | Group-Object | Sort-Object Count -Descending | Select-Object -First 5 |
                ForEach-Object { Write-Host "    channel $($_.Name): $($_.Count) access points" }
            if ($same -ge 4) { Warn 'Your channel is crowded. Pick a less busy channel in the router settings (or use 5 GHz).' }
        } else {
            Write-Host '  (Nearby scan unavailable. On Windows 11, allow Location access for desktop apps to enable it.)'
        }
    }
} else {
    Write-Host '  (Wired connection or no Wi-Fi adapter; skipped.)'
}

# --- 3. Router -> internet ----------------------------------------------------
Hr '3. Router -> internet (ISP link)'
$W = Get-PingStats $PublicHost 30
$extra = [math]::Round($W.Avg - $L.Avg, 1)
Write-Host "  loss=$($W.Loss)%  avg=$($W.Avg)ms  jitter=$($W.Jitter)ms  (to $PublicHost)"
Write-Host "  Latency added beyond the router: ${extra}ms"
if ($W.Loss -gt ($L.Loss + 1)) { Warn 'Loss appears past the router: likely the ISP line or modem. Call the ISP if it persists.' }
if ($extra -gt 60)             { Warn 'High latency past the router: ISP congestion or a long route.' }
if ($W.Loss -le 1 -and $extra -le 60) { Ok 'ISP link looks healthy at idle.' }

# --- 4. DNS -------------------------------------------------------------------
Hr '4. DNS lookup speed'
function Get-DnsMs([string]$Server) {
    $name = "test-$(Get-Random).example.com"
    $t = Measure-Command {
        if ($Server) { Resolve-DnsName $name -Server $Server -DnsOnly -NoHostsFile -QuickTimeout 2>$null | Out-Null }
        else         { Resolve-DnsName $name -DnsOnly -NoHostsFile -QuickTimeout 2>$null | Out-Null }
    }
    [math]::Round($t.TotalMilliseconds)
}
$dLocal = Get-DnsMs ''; $dCf = Get-DnsMs '1.1.1.1'
$dnsServers = (Get-DnsClientServerAddress -InterfaceAlias $Iface -AddressFamily IPv4).ServerAddresses -join ', '
Write-Host "  Current DNS ($dnsServers): ${dLocal}ms   Cloudflare 1.1.1.1: ${dCf}ms"
if ($dLocal -gt 100 -and $dLocal -gt (2 * $dCf)) {
    Warn "Your DNS is slow. Point the router's DNS at 1.1.1.1 / 8.8.8.8, which makes every page start loading sooner."
} else { Ok 'DNS speed is fine.' }

# --- 5. Bufferbloat: latency while the line is busy --------------------------
Hr '5. Bufferbloat (latency under load, takes ~15s)'
$dl = Start-Process -FilePath 'curl.exe' -ArgumentList @('-s', '-o', 'NUL', '--max-time', '15', $LoadUrl) -WindowStyle Hidden -PassThru
if ($dl) {
    Start-Sleep -Seconds 2
    $B = Get-PingStats $PublicHost 50
    if (-not $dl.HasExited) { $dl.WaitForExit(15000) | Out-Null }
    $bloat = [math]::Round($B.Avg - $W.Avg, 1)
    Write-Host "  idle=$($W.Avg)ms  loaded=$($B.Avg)ms  increase=${bloat}ms"
    if     ($bloat -gt 100) { Warn 'Severe bufferbloat: calls and games lag whenever someone downloads. Turn on SQM / Smart Queue / QoS in the router.' }
    elseif ($bloat -gt 30)  { Warn 'Moderate bufferbloat. Turning on SQM/QoS (if your router has it) would help.' }
    else                    { Ok 'Little bufferbloat (grade A/B).' }
} else {
    Write-Host '  (curl.exe not found; skipped. Use speed.cloudflare.com and compare idle vs loaded latency.)'
}

# --- 6. Devices on your network ----------------------------------------------
Hr '6. Devices on your network'
$neigh = Get-NetNeighbor -AddressFamily IPv4 -InterfaceAlias $Iface |
    Where-Object { $_.State -in 'Reachable', 'Stale', 'Delay', 'Probe' -and
                   $_.LinkLayerAddress -notmatch '^(FF-FF|00-00|01-00-5E)' -and
                   $_.IPAddress -notmatch '\.255$' }
$n = @($neigh).Count
Write-Host "  Devices recently seen: $n"
if ($n -gt 30) { Warn 'Lots of devices. Check the router client list for unknown ones or heavy users (backups, torrents, game updates).' }

# --- 7. Router admin page -----------------------------------------------------
Hr '7. Router admin page'
try {
    $resp = Invoke-WebRequest -Uri "http://$GW/" -UseBasicParsing -TimeoutSec 4 -ErrorAction Stop
    Write-Host "  http://$GW/ responded with HTTP $($resp.StatusCode)"
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    if ($code) { Write-Host "  http://$GW/ responded with HTTP $code" } else { Write-Host "  http://$GW/ did not answer (try https://$GW/ in a browser)" }
}
Write-Host '  Log in there and check: firmware updates, CPU/memory load, uptime, connected clients, QoS/SQM settings.'

Hr 'Done'
Write-Host 'Paste this output back to Claude to get a diagnosis.'
