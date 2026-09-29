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
  If a plain log reset is not enough (service-specific error 3221229584 /
  0xC0001010, MSDTC events 4163 + 4185 LogInit 0x2), the script automatically
  applies the documented deep repair: msdtc -uninstall, removal of stale
  registry leftovers (HKCR\CID, HKLM\SOFTWARE\Microsoft\MSDTC,
  Services\MSDTC -- each backed up to .reg first), msdtc -install,
  msdtc -resetlog, then start.

.PARAMETER InstallerPath
  Optional full path to virtio-win-guest-tools.exe. If given, launches it
  elevated after the repair succeeds. If not given, the script auto-discovers
  virtio-win-guest-tools.exe on any drive root (the mounted virtio-win ISO).

.EXAMPLE
  .\fix-vritio.ps1
  .\fix-vritio.ps1 -InstallerPath D:\virtio-win-guest-tools.exe
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
#    Check the result instead of assuming it worked.
& msdtc -resetlog
if ($LASTEXITCODE -eq 0) {
    Write-Host "MS DTC log reset." -ForegroundColor Green
} else {
    Write-Host "msdtc -resetlog failed (exit code $LASTEXITCODE)." -ForegroundColor Yellow
}

# 3. Start MSDTC
net start msdtc
Start-Sleep -Seconds 2

$svc = Get-Service MSDTC -ErrorAction SilentlyContinue
Write-Host ("MSDTC status: {0}" -f $(if ($svc) { $svc.Status } else { 'not found' })) -ForegroundColor Cyan

if (-not $svc -or $svc.Status -ne 'Running') {
    # Retry once -- the SCM can briefly report an invalid service name right
    # after a service has been registered.
    Start-Sleep -Seconds 2
    net start msdtc 2> $null
    Start-Sleep -Seconds 2
    $svc = Get-Service MSDTC -ErrorAction SilentlyContinue
}

if (-not $svc -or $svc.Status -ne 'Running') {
    # 4. Deep repair -- documented MS DTC recovery for service-specific error
    #    3221229584 (0xC0001010) / MSDTC events 4163 + 4185 (LogInit 0x2):
    #    uninstall, remove stale registry leftovers (.reg backup first),
    #    reinstall, reset log, start.
    Write-Host "MS DTC did not start cleanly -- applying deep repair automatically..." -ForegroundColor Yellow

    $backupDir = Join-Path (Split-Path -Parent $PSCommandPath) 'msdtc-registry-backups'
    if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    if (Test-Path 'Registry::HKEY_CLASSES_ROOT\CID') {
        reg.exe export "HKCR\CID" (Join-Path $backupDir "CID-$stamp.reg") /y | Out-Null
    }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\MSDTC') {
        reg.exe export "HKLM\SOFTWARE\Microsoft\MSDTC" (Join-Path $backupDir "SW-MSDTC-$stamp.reg") /y | Out-Null
    }

    try { net stop msdtc /y *> $null } catch { }
    msdtc -uninstall
    Write-Host ("  msdtc -uninstall exit code: {0}" -f $LASTEXITCODE) -ForegroundColor DarkGray

    # Remove leftovers the uninstaller can leave behind (documented recovery).
    if (Test-Path 'Registry::HKEY_CLASSES_ROOT\CID') { Remove-Item 'Registry::HKEY_CLASSES_ROOT\CID' -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\MSDTC') { Remove-Item 'HKLM:\SOFTWARE\Microsoft\MSDTC' -Recurse -Force -ErrorAction SilentlyContinue }
    foreach ($cs in @('CurrentControlSet', 'ControlSet001', 'ControlSet002')) {
        $svcKey = "HKLM:\SYSTEM\$cs\Services\MSDTC"
        if (Test-Path $svcKey) { Remove-Item $svcKey -Recurse -Force -ErrorAction SilentlyContinue }
    }

    msdtc -install
    Write-Host ("  msdtc -install exit code: {0}" -f $LASTEXITCODE) -ForegroundColor DarkGray
    msdtc -resetlog
    Write-Host ("  msdtc -resetlog exit code: {0}" -f $LASTEXITCODE) -ForegroundColor DarkGray

    Start-Sleep -Seconds 2
    net start msdtc
    Start-Sleep -Seconds 3
    $svc = Get-Service MSDTC -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -ne 'Running') {
        Start-Sleep -Seconds 2
        net start msdtc
        Start-Sleep -Seconds 3
        $svc = Get-Service MSDTC -ErrorAction SilentlyContinue
    }
    Write-Host ("MSDTC status after deep repair: {0}" -f $(if ($svc) { $svc.Status } else { 'not found' })) -ForegroundColor Cyan
}

if ($svc -and $svc.Status -eq 'Running') {
    Write-Host "MS DTC is running. COM+ ready for QEMU Guest Agent VSS registration." -ForegroundColor Green
    if (-not $InstallerPath) {
        # Auto-discover virtio-win-guest-tools.exe on any drive root (the
        # mounted virtio-win ISO).
        $discovered = Get-PSDrive -PSProvider FileSystem |
            Where-Object { $_.Root } |
            ForEach-Object { Join-Path $_.Root 'virtio-win-guest-tools.exe' } |
            Where-Object { Test-Path $_ } |
            Select-Object -First 1
        if ($discovered) {
            $InstallerPath = $discovered
            Write-Host "Installer auto-discovered: $InstallerPath" -ForegroundColor Cyan
        }
    }
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
} else {
    Write-Host "MS DTC is still not running. Check Event Viewer -> Applications -> MSDTC." -ForegroundColor Red
    Write-Host "If the deep repair just reinstalled it, reboot once and re-run this script." -ForegroundColor Yellow
}

# Pause only for a human at a real console. Skip when stdin is redirected
# (automation / piping / remote sessions) so the script never hangs.
if (-not [Console]::IsInputRedirected) {
    Write-Host "`nPress Enter to close..." -ForegroundColor DarkGray
    [void](Read-Host)
}
