<#
.SYNOPSIS
    Restarts into Manjaro.

.DESCRIPTION
    Manjaro is already the first boot choice on this machine, so there is no boot
    order to rearrange - the machine restarts and lands in Manjaro anyway.

    The one thing that IS worth clearing first is a pending one-shot override. If
    the "Switch to Windows 11" icon was used and the machine has not restarted
    since, that override is still queued and a plain restart would boot Windows
    instead. So this script deletes {fwbootmgr} bootsequence, then restarts. That
    needs administrator rights, hence the single UAC prompt.

    Everything else the full launcher does is unnecessary for this icon, so none
    of it runs here.

.EXAMPLE
    powershell -File .\tools\boot-manjaro.ps1
#>
[CmdletBinding()]
param(
    # NOT '' - an empty FilePath makes Start-Process throw. Every test that
    # injected a stub would hide a broken default.
    [string] $ShutdownPath = 'shutdown.exe',
    [string] $BcdeditPath = 'bcdedit.exe'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$logDir = Join-Path $env:LOCALAPPDATA 'osswitch'
$logFile = Join-Path $logDir 'launcher.log'

function Write-Log {
    param([string] $Message)
    try {
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
        Add-Content -Path $logFile -Value ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message)
    }
    catch { }
}

# ---- elevate ----
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$alreadyElevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $alreadyElevated -and $env:OSSWITCH_TEST_BYPASS_ELEVATION -ne '1') {
    Write-Log 'not elevated - requesting elevation'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'))
    $argList += @('-ShutdownPath', ('"' + $ShutdownPath + '"'))
    $argList += @('-BcdeditPath', ('"' + $BcdeditPath + '"'))
    $child = Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -PassThru -ArgumentList $argList
    exit $child.ExitCode
}

Write-Log 'BOOT-MANJARO START (elevated)'

# ---- no confirmation ----
# Single click = immediate restart. The button promises "Switch to Manjaro",
# so it just does it. Any pending Windows override is cleared first.
$proceed = $true

# ---- clear any pending one-shot override ----
# This is the only boot-store write this icon needs. An override left behind by
# the Windows icon is consumed by the next boot, so without this the restart
# could go to Windows - which is exactly what this button promises not to do.
$cleared = 'nothing to clear'
try {
    if (-not (Get-Command $BcdeditPath -ErrorAction SilentlyContinue)) {
        throw "cannot find '$BcdeditPath' on PATH"
    }
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $null = & $BcdeditPath '/deletevalue' '{fwbootmgr}' 'bootsequence' 2>&1
    $delCode = $LASTEXITCODE
    $ErrorActionPreference = $prevPref
    # 0 = an override existed and was removed. Non-zero simply means there was
    # none, which is the normal case and must not look like a failure.
    if ($delCode -eq 0) { $cleared = 'a pending Windows override was cleared' }
    else { $cleared = 'no override was pending' }
    Write-Log "bootsequence: $cleared (exit $delCode)"
}
catch {
    Write-Log ('BOOTSTORE CLEAR FAILED: ' + $_.Exception.Message)
    Write-Host ''
    Write-Host ('  COULD NOT CHECK THE BOOT ORDER: ' + $_.Exception.Message)
    Write-Host '  Restarting anyway.'
    exit 1
}

Write-Host ''
Write-Host '  Manjaro is already the first boot choice.'
if ($cleared -like 'a pending*') { Write-Host "  Note: $cleared." }
Write-Host '  Restarting now...'

# Detached on purpose. shutdown.exe with /t blocks for the whole countdown and is
# killed by the restart it just scheduled, so calling it inline made this script
# die mid-call: exit code 1, no message, and it looked like the click did
# nothing. Started without -Wait, this script finishes its own output first and
# is not around when the machine goes down.
Write-Log 'issuing the restart (detached)'
try {
    if (-not (Get-Command $ShutdownPath -ErrorAction SilentlyContinue)) {
        throw "cannot find '$ShutdownPath' on PATH"
    }
    # Immediate restart (/t 0), no countdown.
    $shutArgs = @('/r', '/t', '0', '/c', '"Switch to Manjaro"')
    $null = Start-Process -FilePath $ShutdownPath -ArgumentList $shutArgs -WindowStyle Hidden
    Write-Log 'restart scheduled'
}
catch {
    Write-Log ('RESTART FAILED: ' + $_.Exception.Message)
    Write-Host ''
    Write-Host ('  THE RESTART COULD NOT BE STARTED: ' + $_.Exception.Message)
    Write-Host '  Nothing has changed.'
    exit 1
}

exit 0
