<#
.SYNOPSIS
  Pre-flight COM+/MS DTC repair so virtio-win-guest-tools installs cleanly on Windows.

.DESCRIPTION
  Fixes this exact failure on a clean install:
    virtio-win-guest-tools.exe rolls back at the "QEMU Guest Agent" step with
    0x80070643. Inner cause (in the vwi.JlI2 MSI log): the RegisterCom custom
    action runs `rundll32 qga-vss.dll,DLLCOMRegister`, which fails with
    0x8004E00F because the MS DTC / COM+ environment is stopped or broken.
  This script repairs MS DTC BEFORE you run the guest-tools installer.
  Idempotent and safe. Auto-elevates. Does NOT use `exit`.

.PARAMETER InstallerPath
  Optional full path to virtio-win-guest-tools.exe. If given, launches it
  elevated after the repair succeeds.

.EXAMPLE
  .\fix-virtio-msdtc.ps1
  .\fix-virtio-msdtc.ps1 -InstallerPath G:\virtio-win-guest-tools.exe
#>
param(
    [string]$InstallerPath
)

$ErrorActionPreference = 'Continue'

# --- auto-elevate so net/msdtc commands succeed ---
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Re-launching elevated..." -ForegroundColor Yellow
    $relaunchArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    if ($InstallerPath) { $relaunchArgs += '-InstallerPath'; $relaunchArgs += $InstallerPath }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $relaunchArgs
    return
}

Write-Host "Repairing MS DTC (COM+) for QEMU Guest Agent VSS registration..." -ForegroundColor Cyan

# 1. Stop MSDTC if it happens to be running (ignore "not started" errors)
try { net stop msdtc /y *> $null } catch { }

# 2. Recreate the MS DTC log -- Microsoft fix for 0x8004E00F COM+ errors
& msdtc -resetlog
Write-Host "MS DTC log reset." -ForegroundColor Green

# 3. Start MSDTC
net start msdtc
Start-Sleep -Seconds 2

$svc = Get-Service MSDTC -ErrorAction SilentlyContinue
Write-Host ("MSDTC status: {0}" -f $(if ($svc) { $svc.Status } else { 'not found' })) -ForegroundColor Cyan

if (-not $svc -or $svc.Status -ne 'Running') {
    Write-Host "MS DTC did not start cleanly. Check Event Viewer -> Applications -> MSDTC." -ForegroundColor Red
    Write-Host "Deeper fallback (run manually if needed):" -ForegroundColor Yellow
    Write-Host "  msdtc -uninstall  ; then  msdtc -install  ; then re-run this script." -ForegroundColor Yellow
} else {
    Write-Host "MS DTC is running. COM+ ready for QEMU Guest Agent VSS registration." -ForegroundColor Green
    if ($InstallerPath) {
        if (Test-Path $InstallerPath) {
            Write-Host "Launching installer: $InstallerPath" -ForegroundColor Cyan
            Start-Process $InstallerPath -Verb RunAs
        } else {
            Write-Host "Installer not found: $InstallerPath" -ForegroundColor Red
        }
    } else {
        Write-Host "Now run virtio-win-guest-tools.exe as Administrator." -ForegroundColor Green
    }
}

Write-Host "`nPress Enter to close..." -ForegroundColor DarkGray
[void](Read-Host)
