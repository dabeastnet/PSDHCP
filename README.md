# PSDHCP

A minimal DHCP server for Windows, written in PowerShell, for giving a Raspberry Pi
(or any other device) an IP address over a direct Ethernet cable.

Windows 11 has no built-in DHCP server, and Internet Connection Sharing forces the
192.168.137.x subnet and shares your internet connection. PSDHCP is a single
readable script with no downloads or dependencies.

## Network layout

```
 Windows PC                                   Raspberry Pi
 ┌──────────────────────────┐   Ethernet     ┌──────────────────────┐
 │ Ethernet 3               │◄──────────────►│ eth0                 │
 │ 192.168.50.1/24 (static) │                │ 192.168.50.100 (DHCP)│
 │ PSDHCP.ps1 on UDP 67     │                │                      │
 └──────────────────────────┘                └──────────────────────┘
```

- The PC has a static address on the adapter and runs the server.
- The Pi gets an address from the pool `192.168.50.100`–`192.168.50.150`.
- **No gateway or DNS is handed out.** This is an isolated link: if the Pi also has
  Wi-Fi, its internet traffic keeps going through Wi-Fi.

## Files

| File            | Purpose                                                                 |
|-----------------|-------------------------------------------------------------------------|
| `PSDHCP.ps1`   | The DHCP server.                                                        |
| `install.ps1`   | Sets the static IP, adds the firewall rule, registers a startup task.   |
| `uninstall.ps1` | Removes the task and firewall rule; optionally restores DHCP on the adapter. |
| `leases.json`   | Created at runtime: MAC address → IP address.                           |
| `PSDHCP.log`   | Created at runtime: activity log.                                       |

## Installation

1. Copy this folder somewhere permanent, e.g. `C:\PSDHCP`. The startup task runs the
   script from that location, and the lease file and log are written there.
2. Open **PowerShell as Administrator** in that folder and run:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install.ps1
   ```

   With a different adapter or subnet:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install.ps1 -InterfaceAlias "Ethernet 2" `
       -ServerIp 10.0.0.1 -SubnetMask 255.255.255.0 -PoolStart 10.0.0.100 -PoolEnd 10.0.0.150
   ```

   Find adapter names with `Get-NetAdapter`. Pick a subnet that is not already in use
   on the PC (`Get-NetIPAddress -AddressFamily IPv4`).

3. Connect and power on the Pi, then check the log:

   ```powershell
   Get-Content .\PSDHCP.log -Tail 10
   ```

   ```
   listening on 192.168.50.1:67
   DISCOVER from 2c:cf:67:b5:1c:55 (dbrpi) -> OFFER 192.168.50.100
   REQUEST from 2c:cf:67:b5:1c:55 (dbrpi) for 192.168.50.100 -> ACK
   ```

4. Connect: `ssh <user>@192.168.50.100`

### install.ps1 parameters

| Parameter         | Default            | Description                                  |
|-------------------|--------------------|----------------------------------------------|
| `-InterfaceAlias` | `Ethernet 3`       | Adapter the Pi is connected to.              |
| `-ServerIp`       | `192.168.50.1`     | Static IP given to the adapter.              |
| `-SubnetMask`     | `255.255.255.0`    | Subnet mask for the adapter and the clients. |
| `-PoolStart`      | `192.168.50.100`   | First address handed out.                    |
| `-PoolEnd`        | `192.168.50.150`   | Last address handed out.                     |
| `-LeaseSeconds`   | `86400`            | Lease time reported to clients.              |
| `-NoTask`         |                    | Skip the startup task; run the server manually. |

## Running manually (without the startup task)

Install with `-NoTask` (sets the IP and firewall rule only), then whenever you need
it, in an Administrator PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\PSDHCP.ps1
```

Stop with Ctrl+C. `PSDHCP.ps1` accepts the same `-ServerIp`, `-SubnetMask`,
`-PoolStart`, `-PoolEnd` and `-LeaseSeconds` parameters as the installer, plus
`-LeaseFile` and `-LogFile`.

## Managing the service

```powershell
Get-ScheduledTask   -TaskName "PSDHCP"     # state
Stop-ScheduledTask  -TaskName "PSDHCP"
Start-ScheduledTask -TaskName "PSDHCP"
Get-Content .\leases.json                          # who has which address
```

To give a device a specific address, stop the task, edit `leases.json`
(`{ "2c:cf:67:b5:1c:55": "192.168.50.100" }`), and start it again.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1               # keep static IP
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1 -RestoreDhcp  # adapter back to automatic
```

## How it works

- Binds UDP port 67 on the server IP only, so it never answers on other adapters
  (Wi-Fi, VMware, VirtualBox, VPN).
- Handles DISCOVER → OFFER, REQUEST → ACK/NAK and logs RELEASE. Replies are broadcast
  to port 68, which is what a client without an address expects.
- Each MAC address is bound permanently to one address in `leases.json`; leases never
  expire, so a device always gets the same IP. If a new client asks for a specific
  free address in the pool, it gets it.
- A REQUEST for an address other than the one on file gets a NAK, which makes the
  client start over and pick up its correct address.
- Options sent: subnet mask (1), lease time (51), renewal/rebinding times (58/59),
  server identifier (54). No router (3) or DNS (6).
- While the adapter has no link, the server address is not active and binding fails.
  The script waits, retries every 10 seconds, and starts serving as soon as the cable
  is connected. It also recovers if the cable is unplugged later.

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| Log says `waiting for 192.168.50.1 to become active` | The adapter has no link. Check the cable and that the Pi is powered on. `Get-NetAdapter -Name "Ethernet 3"` should show `Up`. |
| Adapter is `Up` but has a `169.254.x.x` address | The Windows DHCP client is still enabled on it. Re-run `install.ps1`. |
| No DISCOVER lines in the log | Firewall rule missing or the server is not running. Check `Get-NetFirewallRule -DisplayName "PSDHCP*"` and the task state. |
| `Only one usage of each socket address` | Another DHCP server (e.g. Internet Connection Sharing) is using port 67. Find it with `Get-NetUDPEndpoint -LocalPort 67`. |
| Pi has an IP but no internet | By design: no gateway is handed out. Use the Pi's Wi-Fi, or use Internet Connection Sharing instead. |

## Self-test

Checks the packet handling without using the network:

```powershell
powershell -ExecutionPolicy Bypass -File .\PSDHCP.ps1 -SelfTest
```

```
offer: 300 bytes, type 2, yiaddr 192.168.50.100
ack:   300 bytes, type 5, yiaddr 192.168.50.100, mask 255.255.255.0
nak:   type 6
```
