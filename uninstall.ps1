# Removes the PSDHCP startup task and firewall rule.
# -RestoreDhcp puts the adapter back to "obtain an IP address automatically".
param(
    [string]$InterfaceAlias = 'Ethernet 3',
    [switch]$RestoreDhcp
)

$ErrorActionPreference = 'Stop'
$TaskName = 'PSDHCP'
$RuleName = "PSDHCP ($InterfaceAlias)"

$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated (Administrator) PowerShell.'
}

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Write-Host "Removing scheduled task '$TaskName'"
    Stop-ScheduledTask -TaskName $TaskName
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

if (Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue) {
    Write-Host "Removing firewall rule '$RuleName'"
    Remove-NetFirewallRule -DisplayName $RuleName
}

if ($RestoreDhcp) {
    Write-Host "Switching $InterfaceAlias back to DHCP"
    netsh interface ipv4 set address name="$InterfaceAlias" dhcp | Out-Null
}

Write-Host 'Done. leases.json and PSDHCP.log in this folder were left in place.'
