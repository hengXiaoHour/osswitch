<#
.SYNOPSIS
    Creates the two osswitch desktop shortcuts.

.DESCRIPTION
    Writes "Switch to Manjaro" and "Switch to Windows 11" to the desktop, each
    pointing at tools\osswitch-launch.ps1 with its own icon from assets\.

    The launcher asks for confirmation and re-launches itself elevated, so the
    shortcut itself needs no special flags.

.EXAMPLE
    powershell -File .\tools\install_shortcuts.ps1
#>
[CmdletBinding()]
param(
    [string] $Desktop = '',
    [switch] $Remove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$proj = Split-Path -Parent $PSScriptRoot
$wrapper = Join-Path $proj 'tools\osswitch-shortcut.cmd'
$launcher = Join-Path $proj 'tools\osswitch-launch.ps1'
$bootManjaro = Join-Path $proj 'tools\boot-manjaro.ps1'
$assets = Join-Path $proj 'assets'

if (-not (Test-Path $wrapper)) { throw "wrapper not found: $wrapper" }
if (-not (Test-Path $launcher)) { throw "launcher not found: $launcher" }
# The manjaro shortcut dispatches to this instead: a plain restart, no admin.
if (-not (Test-Path $bootManjaro)) { throw "boot-manjaro.ps1 not found: $bootManjaro" }
foreach ($n in @('manjaro.ico', 'windows.ico')) {
    if (-not (Test-Path (Join-Path $assets $n))) {
        throw "icon not found: $n - run .\tools\make_icon.ps1 first"
    }
}

# Windows PowerShell 5.1 does not populate $PSScriptRoot in parameter defaults.
if (-not $Desktop) { $Desktop = [Environment]::GetFolderPath('Desktop') }
if (-not (Test-Path $Desktop)) { New-Item -ItemType Directory -Path $Desktop -Force | Out-Null }
Write-Host "desktop: $Desktop"

$psExe = (Get-Process -Id $PID).Path
if (-not $psExe) { $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }

$links = @(
    @{ Name = 'Switch to Manjaro.lnk'; Target = 'manjaro'; Icon = 'manjaro.ico' }
    # Named "Restart to" because that is what it honestly does: it points the NEXT
    # boot at Windows and restarts. The override is one-shot, so Windows is used
    # once and the machine returns to Manjaro on its own after that.
    @{ Name = 'Restart to Windows 11.lnk'; Target = 'windows'; Icon = 'windows.ico' }
)

$shell = New-Object -ComObject WScript.Shell
try {
    foreach ($l in $links) {
        $path = Join-Path $Desktop $l.Name
        if ($Remove) {
            if (Test-Path $path) { Remove-Item $path -Force; Write-Host "removed $($l.Name)" }
            continue
        }

        $sc = $shell.CreateShortcut($path)
        # The wrapper leaves a breadcrumb on disk before PowerShell starts, so a
        # silent double-click can be told apart from a crash inside the script.
        $sc.TargetPath = $wrapper
        $sc.Arguments = $l.Target
        $sc.WorkingDirectory = $proj
        $sc.IconLocation = (Join-Path $assets $l.Icon) + ',0'
        $sc.Description = $(if ($l.Target -eq 'manjaro') {
            'Restart into Manjaro (asks before restarting)'
        } else {
            'Restart into Windows 11 this once (asks before restarting)'
        })
        $sc.WindowStyle = 1   # normal
        $sc.Save()

        if (-not (Test-Path $path)) { throw "shortcut was not written: $path" }
        Write-Host ("created {0}" -f $path)
    }
}
finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }

# Read every shortcut back and prove the wiring, rather than trusting the write.
Write-Host ''
$shell2 = New-Object -ComObject WScript.Shell
try {
    foreach ($l in $links) {
        $path = Join-Path $Desktop $l.Name
        if (-not (Test-Path $path)) { Write-Host ("  MISSING: {0}" -f $path); continue }
        $sc = $shell2.CreateShortcut($path)
        $okTarget = $sc.TargetPath -eq $wrapper
        $okArgs = $sc.Arguments.Trim() -eq $l.Target
        $okLauncher = (Test-Path $sc.TargetPath)
        # Contains, not -like: the icon path is compared literally, and -like
        # treats wildcard characters in a path as patterns.
        $okIcon = $sc.IconLocation.ToLowerInvariant().Contains($l.Icon.ToLowerInvariant())
        Write-Host ("  {0}" -f $l.Name)
        Write-Host ("     target   : {0}" -f $sc.TargetPath)
        Write-Host ("     arguments: {0}" -f $sc.Arguments)
        Write-Host ("     icon     : {0}" -f $sc.IconLocation)
        Write-Host ("     wiring   : wrapper={0} target={1} exists={2} icon={3}" -f $okTarget, $okArgs, $okLauncher, $okIcon)
        if (-not ($okTarget -and $okArgs -and $okLauncher -and $okIcon)) { throw "shortcut wiring is wrong: $path" }
    }
}
finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell2) }

# ---- Start menu entries ----
# Windows 11 removed drag-to-pin, and it refuses to offer "Pin to taskbar" for a
# shortcut whose target is a bare SCRIPT (.cmd): such an item has no Windows app
# identity, so the shell treats it as a file, not an app. Pointing the same
# wrapper at cmd.exe - a real program - is what can make the pin option appear,
# while keeping the on-disk breadcrumb that proves a click reached PowerShell.
$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
if (-not (Test-Path $startMenu)) { New-Item -ItemType Directory -Path $startMenu -Force | Out-Null }
Write-Host ''
Write-Host "start menu: $startMenu"
$shell3 = New-Object -ComObject WScript.Shell
try {
    foreach ($l in $links) {
        $dest = Join-Path $startMenu $l.Name
        $sc = $shell3.CreateShortcut($dest)
        $sc.TargetPath = Join-Path $env:SystemRoot 'System32\cmd.exe'
        # /c ""<wrapper>" <target>" - the outer quotes keep the inner path intact.
        $sc.Arguments = ('/c ""{0}" {1}"' -f $wrapper, $l.Target)
        $sc.WorkingDirectory = $proj
        $sc.IconLocation = (Join-Path $assets $l.Icon) + ',0'
        $sc.WindowStyle = 1
        $sc.Save()
        if (-not (Test-Path $dest)) { throw "start menu entry was not written: $dest" }

        # Read it back: pointing at a real program is what can make pinning
        # possible, so assert that rather than trusting the write.
        $chk = $shell3.CreateShortcut($dest)
        if ($chk.TargetPath -ne (Join-Path $env:SystemRoot 'System32\cmd.exe')) {
            throw "start menu entry does not point at cmd.exe: $dest"
        }
        if ($chk.Arguments -notmatch [regex]::Escape($l.Target)) {
            throw "start menu entry lost its target argument: $dest"
        }
        Write-Host ("  created {0}" -f $dest)
        Write-Host ("     {0} {1}" -f (Split-Path $chk.TargetPath -Leaf), $chk.Arguments)
    }
}
finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell3) }

Write-Host ''
Write-Host 'shortcuts ready'