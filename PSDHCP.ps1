# Minimal DHCP server for a single isolated link (Ethernet 3 -> Raspberry Pi).
# Hands out addresses from a small pool, remembers them per MAC in leases.json,
# and gives no router/DNS so the client keeps its own default route.
param(
    [string]$ServerIp     = '192.168.50.1',
    [string]$SubnetMask   = '255.255.255.0',
    [string]$PoolStart    = '192.168.50.100',
    [string]$PoolEnd      = '192.168.50.150',
    [int]   $LeaseSeconds = 86400,
    [string]$LeaseFile    = "$PSScriptRoot\leases.json",
    [string]$LogFile      = "$PSScriptRoot\PSDHCP.log",
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

function Write-Log([string]$msg) {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $msg
    Write-Host $line
    if (-not $SelfTest) { Add-Content -Path $LogFile -Value $line }
}

function ConvertTo-UInt([string]$ip) {
    $b = [Net.IPAddress]::Parse($ip).GetAddressBytes(); [Array]::Reverse($b)
    [BitConverter]::ToUInt32($b, 0)
}

function ConvertTo-Ip([uint32]$n) {
    $b = [BitConverter]::GetBytes($n); [Array]::Reverse($b)
    [Net.IPAddress]::new($b).ToString()
}

function Get-BigEndian32([uint32]$n) {
    $b = [BitConverter]::GetBytes($n); [Array]::Reverse($b)
    , $b
}

$serverBytes = [Net.IPAddress]::Parse($ServerIp).GetAddressBytes()
$maskBytes   = [Net.IPAddress]::Parse($SubnetMask).GetAddressBytes()
$poolLo      = ConvertTo-UInt $PoolStart
$poolHi      = ConvertTo-UInt $PoolEnd

# --- Leases (MAC -> IP), persisted so the Pi keeps the same address ---------
$leases = @{}
if (-not $SelfTest -and (Test-Path $LeaseFile)) {
    (Get-Content $LeaseFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $leases[$_.Name] = $_.Value }
}

function Save-Leases {
    if (-not $SelfTest) { $leases | ConvertTo-Json | Set-Content -Path $LeaseFile -Encoding UTF8 }
}

function Get-LeaseFor([string]$mac, [string]$preferred) {
    if ($leases.ContainsKey($mac)) { return $leases[$mac] }
    $used = @($leases.Values)
    $candidates = @()
    if ($preferred) {
        $p = ConvertTo-UInt $preferred
        if ($p -ge $poolLo -and $p -le $poolHi) { $candidates += $preferred }
    }
    for ($n = $poolLo; $n -le $poolHi; $n++) { $candidates += ConvertTo-Ip $n }
    foreach ($ip in $candidates) {
        if ($used -notcontains $ip) { $leases[$mac] = $ip; Save-Leases; return $ip }
    }
    $null
}

# --- Packet parsing / building ---------------------------------------------
function Get-DhcpOptions([byte[]]$p) {
    $o = @{}; $i = 240
    while ($i -lt $p.Length) {
        $code = $p[$i]
        if ($code -eq 255) { break }
        if ($code -eq 0) { $i++; continue }
        if ($i + 1 -ge $p.Length) { break }
        $len = $p[$i + 1]
        if ($i + 2 + $len -gt $p.Length) { break }
        $v = New-Object byte[] $len
        [Array]::Copy($p, $i + 2, $v, 0, $len)
        $o[[int]$code] = $v
        $i += 2 + $len
    }
    $o
}

function New-DhcpReply([byte[]]$req, [byte]$msgType, [string]$yiaddr) {
    $r = New-Object byte[] 240
    $r[0] = 2; $r[1] = $req[1]; $r[2] = $req[2]       # BOOTREPLY, htype, hlen
    [Array]::Copy($req, 4, $r, 4, 4)                   # xid
    [Array]::Copy($req, 10, $r, 10, 2)                 # flags
    if ($msgType -eq 5) { [Array]::Copy($req, 12, $r, 12, 4) }   # ciaddr (ACK only)
    if ($yiaddr) { [Array]::Copy([Net.IPAddress]::Parse($yiaddr).GetAddressBytes(), 0, $r, 16, 4) }
    [Array]::Copy($req, 24, $r, 24, 4)                 # giaddr
    [Array]::Copy($req, 28, $r, 28, 16)                # chaddr
    $r[236] = 99; $r[237] = 130; $r[238] = 83; $r[239] = 99   # magic cookie

    $out = New-Object 'Collections.Generic.List[byte]'
    $out.AddRange($r)
    $out.AddRange([byte[]](53, 1, $msgType))
    $out.AddRange([byte[]](54, 4)); $out.AddRange($serverBytes)
    if ($msgType -ne 6) {
        $out.AddRange([byte[]](51, 4)); $out.AddRange((Get-BigEndian32 $LeaseSeconds))
        $out.AddRange([byte[]](58, 4)); $out.AddRange((Get-BigEndian32 ([uint32]($LeaseSeconds / 2))))
        $out.AddRange([byte[]](59, 4)); $out.AddRange((Get-BigEndian32 ([uint32]($LeaseSeconds * 7 / 8))))
        $out.AddRange([byte[]](1, 4)); $out.AddRange($maskBytes)
    }
    $out.Add(255)
    while ($out.Count -lt 300) { $out.Add(0) }
    , $out.ToArray()
}

# Returns the reply bytes to broadcast, or $null.
function Invoke-DhcpPacket([byte[]]$p) {
    if ($p.Length -lt 240 -or $p[0] -ne 1 -or $p[2] -lt 1 -or $p[2] -gt 16) { return $null }
    if ($p[236] -ne 99 -or $p[237] -ne 130 -or $p[238] -ne 83 -or $p[239] -ne 99) { return $null }
    $o = Get-DhcpOptions $p
    if (-not $o.ContainsKey(53)) { return $null }

    $mac  = ($p[28..(27 + $p[2])] | ForEach-Object { $_.ToString('x2') }) -join ':'
    $host_ = if ($o.ContainsKey(12)) { ' (' + [Text.Encoding]::ASCII.GetString($o[12]) + ')' } else { '' }
    $requested = if ($o.ContainsKey(50) -and $o[50].Length -eq 4) { [Net.IPAddress]::new($o[50]).ToString() } else { $null }

    switch ($o[53][0]) {
        1 { # DISCOVER
            $ip = Get-LeaseFor $mac $requested
            if (-not $ip) { Write-Log "DISCOVER from $mac$host_ -> pool exhausted"; return $null }
            Write-Log "DISCOVER from $mac$host_ -> OFFER $ip"
            return , (New-DhcpReply $p 2 $ip)
        }
        3 { # REQUEST
            if ($o.ContainsKey(54) -and [Net.IPAddress]::new($o[54]).ToString() -ne $ServerIp) {
                Write-Log "REQUEST from $mac$host_ for another server, ignored"; return $null
            }
            if (-not $requested) { $requested = [Net.IPAddress]::new([byte[]]$p[12..15]).ToString() }
            $ip = Get-LeaseFor $mac $requested
            if ($ip -and $ip -eq $requested) {
                Write-Log "REQUEST from $mac$host_ for $requested -> ACK"
                return , (New-DhcpReply $p 5 $ip)
            }
            Write-Log "REQUEST from $mac$host_ for $requested -> NAK (lease is $ip)"
            return , (New-DhcpReply $p 6 $null)
        }
        7 { Write-Log "RELEASE from $mac$host_"; return $null }
        default { return $null }
    }
}

# --- Self test: fake DISCOVER + REQUEST, no network ------------------------
if ($SelfTest) {
    function New-TestRequest([byte]$type, [byte[]]$reqIp) {
        $p = New-Object 'Collections.Generic.List[byte]'
        $hdr = New-Object byte[] 240
        $hdr[0] = 1; $hdr[1] = 1; $hdr[2] = 6
        $hdr[4] = 0xde; $hdr[5] = 0xad; $hdr[6] = 0xbe; $hdr[7] = 0xef
        [Array]::Copy([byte[]](0xb8, 0x27, 0xeb, 0x12, 0x34, 0x56), 0, $hdr, 28, 6)
        $hdr[236] = 99; $hdr[237] = 130; $hdr[238] = 83; $hdr[239] = 99
        $p.AddRange($hdr)
        $p.AddRange([byte[]](53, 1, $type))
        $p.AddRange([byte[]](12, 11)); $p.AddRange([Text.Encoding]::ASCII.GetBytes('raspberrypi'))
        if ($reqIp) { $p.AddRange([byte[]](50, 4)); $p.AddRange($reqIp); $p.AddRange([byte[]](54, 4)); $p.AddRange($serverBytes) }
        $p.Add(255)
        , $p.ToArray()
    }
    $offer = Invoke-DhcpPacket (New-TestRequest 1 $null)
    $yi = [Net.IPAddress]::new([byte[]]$offer[16..19])
    $ack = Invoke-DhcpPacket (New-TestRequest 3 $yi.GetAddressBytes())
    $nak = Invoke-DhcpPacket (New-TestRequest 3 ([byte[]](192, 168, 50, 200)))
    "offer: {0} bytes, type {1}, yiaddr {2}" -f $offer.Length, (Get-DhcpOptions $offer)[53][0], $yi
    "ack:   {0} bytes, type {1}, yiaddr {2}, mask {3}" -f $ack.Length, (Get-DhcpOptions $ack)[53][0], [Net.IPAddress]::new([byte[]]$ack[16..19]), [Net.IPAddress]::new((Get-DhcpOptions $ack)[1])
    "nak:   type {0}" -f (Get-DhcpOptions $nak)[53][0]
    return
}

# --- Main loop: (re)bind whenever the interface address is available -------
Write-Log "PSDHCP starting: server $ServerIp, pool $PoolStart-$PoolEnd"
$broadcast = [Net.IPEndPoint]::new([Net.IPAddress]::Broadcast, 68)
while ($true) {
    $sock = $null
    try {
        $sock = New-Object Net.Sockets.UdpClient
        $sock.EnableBroadcast = $true
        $sock.Client.ReceiveTimeout = 30000
        $sock.Client.Bind([Net.IPEndPoint]::new([Net.IPAddress]::Parse($ServerIp), 67))
        Write-Log "listening on ${ServerIp}:67"
        $lastError = $null
        while ($true) {
            $remote = [Net.IPEndPoint]::new([Net.IPAddress]::Any, 0)
            try { $p = $sock.Receive([ref]$remote) }
            catch {
                $e = $_.Exception.GetBaseException()
                if ($e -is [Net.Sockets.SocketException] -and $e.SocketErrorCode -eq 'TimedOut') { continue }
                throw
            }
            try {
                $reply = Invoke-DhcpPacket $p
                if ($reply) { [void]$sock.Send($reply, $reply.Length, $broadcast) }
            }
            catch { Write-Log "error handling packet: $($_.Exception.Message)" }
        }
    }
    catch {
        $msg = $_.Exception.GetBaseException().Message
        if ($msg -ne $lastError) {
            Write-Log "waiting for $ServerIp to become active (is the cable to the Pi connected?): $msg"
            $lastError = $msg
        }
        if ($sock) { $sock.Close() }
        Start-Sleep -Seconds 10
    }
}
