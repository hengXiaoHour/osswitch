<#
    Live test for osswitch.ps1 against THIS machine's real boot store.

    Every switching step uses -DryRun, so nothing here reboots. The test writes a
    real boot order, reads it back, and then restores the order it started with,
    ending exactly where it began.

    Run elevated (Run as administrator) - bcdedit refuses otherwise.
#>
$ErrorActionPreference = 'Continue'
$script = Join-Path (Split-Path -Parent $PSScriptRoot) 'osswitch.ps1'

# Start-Process -Verb RunAs cannot also redirect stdout, so write a transcript
# and read that file from the unelevated shell.
$LogPath = Join-Path $env:TEMP 'opencode\osswitch-live.log'
New-Item -ItemType Directory -Path (Split-Path -Parent $LogPath) -Force | Out-Null
Start-Transcript -Path $LogPath -Force | Out-Null

function Step {
    param([string] $Title, [hashtable] $Bound)
    Write-Host ''
    Write-Host ('=' * 70)
    Write-Host "== $Title"
    Write-Host ('=' * 70)
    # Hashtable splat, not array splat: an array splats POSITIONALLY, so
    # '-Action' would arrive as the value of Action.
    & $script @Bound
    Write-Host ("[exit {0}]" -f $LASTEXITCODE)
}

Write-Host 'osswitch live test'
Write-Host ("time: " + (Get-Date).ToString('s'))
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$elev = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host ("elevated: $elev")
if (-not $elev) {
    Write-Host 'STOP: run this from an elevated PowerShell.'
    Stop-Transcript | Out-Null
    exit 1
}

Write-Host ''
Write-Host '--- firmware boot entries, straight from bcdedit ---'
bcdedit /enum firmware

Step -Title '1. status (read-only)' -Bound @{ Action = 'status' }

Step -Title '2. switch to Windows 11, dry run (writes, verifies, does NOT reboot)' -Bound @{ Action = 'windows'; DryRun = $true }

Step -Title '3. status after the dry-run switch' -Bound @{ Action = 'status' }

Step -Title '4. restore the original order, dry run (does NOT reboot)' -Bound @{ Action = 'restore'; DryRun = $true }

Step -Title '5. final status - should match step 1' -Bound @{ Action = 'status' }

Write-Host ''
Write-Host '--- final firmware boot entries, straight from bcdedit ---'
bcdedit /enum firmware

Write-Host ''
Write-Host 'live test finished'
Stop-Transcript | Out-Null
Write-Host ("transcript: " + $LogPath)