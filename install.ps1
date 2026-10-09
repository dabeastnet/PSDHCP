# Installs PSDHCP: static IP on the adapter, firewall rule, and a startup task
# that runs PSDHCP.ps1 from this folder as SYSTEM. Run from an elevated PowerShell.
param(
    [string]$InterfaceAlias = 'Ethernet 3',
    [string]$ServerIp       = '192.168.50.1',
    [string]$SubnetMask     = '255.255.255.0',
    [string]$PoolStart      = '192.168.50.100',
    [string]$PoolEnd        = '192.168.50.150',
    [int]   $LeaseSeconds   = 86400,
    [switch]$NoTask
)

$ErrorActionPreference = 'Stop'
$TaskName = 'PSDHCP'
$RuleName = "PSDHCP ($InterfaceAlias)"
$Server   = Join-Path $PSScriptRoot 'PSDHCP.ps1'

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated (Administrator) PowerShell.'
}

$adapter = Get-NetAdapter -Name $InterfaceAlias

# 1. Static IP on the adapter. netsh works even while the cable is unplugged;
#    the registry write makes sure the Windows DHCP client is really off.
Write-Host "Setting $InterfaceAlias to $ServerIp / $SubnetMask"
netsh interface ipv4 set address name="$InterfaceAlias" static $ServerIp $SubnetMask | Out-Null
Set-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($adapter.InterfaceGuid)" -Name EnableDHCP -Value 0

# 2. Firewall: allow DHCP requests in on this adapter only.
if (-not (Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue)) {
    Write-Host "Adding firewall rule '$RuleName'"
    New-NetFirewallRule -DisplayName $RuleName -Direction Inbound -Protocol UDP -LocalPort 67 `
        -InterfaceAlias $InterfaceAlias -Profile Any -Action Allow | Out-Null
}

if ($NoTask) {
    Write-Host "Done. Start the server manually with:"
    Write-Host "  powershell -ExecutionPolicy Bypass -File `"$Server`""
    return
}

# 3. Startup task running as SYSTEM, restarted if it ever exits.
$serverArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Server`" " +
              "-ServerIp $ServerIp -SubnetMask $SubnetMask -PoolStart $PoolStart -PoolEnd $PoolEnd -LeaseSeconds $LeaseSeconds"
$action   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $serverArgs
$trigger  = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
$runAs    = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

Write-Host "Registering scheduled task '$TaskName'"
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $runAs -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName

Write-Host "Done. Log: $(Join-Path $PSScriptRoot 'PSDHCP.log')"
