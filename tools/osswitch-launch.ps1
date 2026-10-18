<#
.SYNOPSIS
    Desktop launcher for osswitch. Double-click it from a shortcut.

.DESCRIPTION
    Asks for confirmation, then hands over to osswitch.ps1 to set the one-shot
    boot override and reboot. Defaults to "No", because a mis-click that reboots
    a machine with unsaved work is worse than one extra click.

    Re-launches itself elevated, since bcdedit needs administrator rights.

.EXAMPLE
    .\osswitch-launch.ps1 -Target manjaro

.EXAMPLE
    .\osswitch-launch.ps1 -Target windows -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('windows', 'manjaro')]
    [string] $Target,

    [switch] $DryRun,
    [switch] $NoConfirm,
    # Skips the "press Enter to close" waits. Required for scripted runs, where
    # Read-Host would block forever on a stdin nobody is typing into.
    [switch] $NoPause,

    # Test seams, forwarded to osswitch.ps1 only when set. They exist so the
    # reboot path can be exercised against stubs instead of really restarting the
    # machine. Leave empty in normal use.
    [string] $BcdeditPath = '',
    # NOT '' - an empty FilePath makes Start-Process throw, and every test that
    # injected a stub hid it. This default must stay a real command.
    [string] $ShutdownPath = 'shutdown.exe',
    [string] $StatePath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# A double-click that produces no visible output is impossible to diagnose, so
# every step leaves a breadcrumb. Delete this file whenever it gets noisy.
$logDir = Join-Path $env:LOCALAPPDATA 'osswitch'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir 'launcher.log'
function Write-Log {
    param([string] $Message)
    try { Add-Content -Path $logFile -Value ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message) } catch { }
}
# $label is defined here, at the very top, because the non-elevated branch below
# prints it and under Set-StrictMode using it before assignment is fatal: the
# window opened and died instantly, which looked like "nothing happens".
$label = if ($Target -eq 'manjaro') { 'Manjaro' } else { 'Windows 11' }

# Not $args: under Set-StrictMode an unbound-arguments variable that was never
# populated throws too.
Write-Log ("LAUNCHER START pid={0} target={1} label={2} dryrun={3} noconfirm={4}" -f $PID, $Target, $label, [bool]$DryRun, [bool]$NoConfirm)

$scriptDir = $PSScriptRoot
$osswitch = Join-Path (Split-Path -Parent $scriptDir) 'osswitch.ps1'
Write-Log "scriptDir=$scriptDir"
Write-Log "osswitch path=$osswitch"
if (-not (Test-Path $osswitch)) {
    Write-Log 'FATAL osswitch.ps1 not found'
    Write-Host ("osswitch.ps1 not found next to this launcher (looked in {0})" -f (Split-Path -Parent $scriptDir))
    Start-Sleep -Seconds 6
    exit 1
}

function Test-Admin {
    if ($env:OSSWITCH_TEST_BYPASS_ELEVATION -eq '1') { return $true }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Log 'not elevated - requesting elevation'
    # Say what is happening before the prompt appears, otherwise the window just
    # blinks and it looks like nothing is going on.
    Write-Host ''
    Write-Host ("  osswitch - switching to {0}" -f $label)
    Write-Host '  Requesting administrator permission (a prompt may appear behind this window)...'
    Write-Host ''

    # Start-Process cannot be redirected, so the elevated child owns the window
    # and prints everything there.
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'), '-Target', $Target)
    if ($DryRun) { $argList += '-DryRun' }
    if ($NoConfirm) { $argList += '-NoConfirm' }
    if ($NoPause) { $argList += '-NoPause' }
    if ($BcdeditPath) { $argList += @('-BcdeditPath', ('"' + $BcdeditPath + '"')) }
    if ($ShutdownPath) { $argList += @('-ShutdownPath', ('"' + $ShutdownPath + '"')) }
    if ($StatePath) { $argList += @('-StatePath', ('"' + $StatePath + '"')) }

    Write-Log ('elevation arglist: ' + ($argList -join ' '))
    try {
        Write-Log 'calling Start-Process -Verb RunAs'
        $child = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -Wait -PassThru
        Write-Log ('elevated child finished, exit=' + $child.ExitCode)
        exit $child.ExitCode
    }
    catch {
        Write-Log ('ELEVATION REFUSED/DECLINED: ' + $_.Exception.Message)
        # Almost always a declined UAC prompt. Say so plainly instead of dumping
        # a PowerShell exception at someone who just double-clicked an icon.
        Write-Host ''
        Write-Host '  Administrator permission was not granted.'
        Write-Host ''
        Write-Host '  Windows asks for permission to make this change to the boot'
        Write-Host '  settings. Nothing has been changed. Right-click the shortcut and'
        Write-Host '  choose "Run as administrator" instead.'
        Start-Sleep -Seconds 6
        exit 1
    }
}

Write-Log 'elevated - running in the elevated process'

Write-Host ''
Write-Host ("  osswitch - switch to {0}" -f $label)
Write-Host ("  {0}" -f ('-' * 44))

<#
    Ask before rebooting.

    This used to be $host.UI.PromptForChoice, an arrow-key menu. That was a bad
    fit: someone typing ordinary words just selects the default (No), the window
    closes, and it looks like nothing happened. A normal Yes/No dialog is
    unambiguous, with a plain typed question as the fallback.
#>
if (-not $NoConfirm) {
    Write-Host ''
    Write-Host ("  Restart your computer into {0} now?" -f $label)
    Write-Host '  Save your work first - anything open will close.'
    Write-Host ''

    $proceed = $false
    $askedWith = ''
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $msg = "Restart your computer into $label now?`r`n`r`nSave your work first - anything you have open will close."
        $answer = [System.Windows.Forms.MessageBox]::Show(
            $msg, "Switch to $label",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
        $proceed = ($answer -eq [System.Windows.Forms.DialogResult]::Yes)
        $askedWith = 'dialog'
    }
    catch {
        Write-Log ("dialog unavailable: " + $_.Exception.Message)
        $typed = Read-Host ("  Type Y and press Enter to restart into {0}, anything else to cancel" -f $label)
        $proceed = ($typed -match '^(?i)y(es)?$')
        $askedWith = 'console'
    }
    Write-Log ("confirmation asked with=$askedWith proceed=$proceed")

    if (-not $proceed) {
        Write-Host ''
        Write-Host '  Cancelled - nothing was changed.'
        Start-Sleep -Seconds 6
        exit 0
    }
}

$sshArgs = @{ Action = $Target }
if ($DryRun) { $sshArgs['DryRun'] = $true }
if ($BcdeditPath) { $sshArgs['BcdeditPath'] = $BcdeditPath }
if ($ShutdownPath) { $sshArgs['ShutdownPath'] = $ShutdownPath }
if ($StatePath) { $sshArgs['StatePath'] = $StatePath }

# Stream osswitch's output so progress is visible, but keep a copy: the window
# must not simply vanish because osswitch had nothing to change.
$osswitchOutput = ''
Write-Log ('running: ' + $osswitch + ' ' + (($sshArgs.GetEnumerator() | ForEach-Object { $_.Key + '=' + $_.Value }) -join ' '))
& $osswitch @sshArgs | ForEach-Object {
    $osswitchOutput += ($_ | Out-String)
    Write-Host $_
}
$code = $LASTEXITCODE
Write-Log ('osswitch exit=' + $code + ' output=' + ($osswitchOutput -replace '[\r\n]+', ' | '))

$alreadySet = $osswitchOutput -match 'Nothing to do'
$rebooting = $osswitchOutput -match 'Rebooting into'

Write-Host ''

if ($code -ne 0) {
    Write-Host ("osswitch stopped with exit code {0} - see the message above." -f $code)
    Write-Host 'Nothing was changed. Press Enter to close this window.'
    if (-not $NoPause) { $null = Read-Host } else { Start-Sleep -Milliseconds 200 }
    exit $code
}
elseif ($alreadySet) {
    # The machine already boots this OS, so there was nothing to change - but the
    # user asked to boot it, and they already confirmed the restart. Sitting on a
    # "nothing to do" without rebooting is what made this look broken.
    Write-Host ("Already set to boot {0}, so the boot order was left alone." -f $label)
    if ($DryRun) {
        Write-Host 'Dry run finished. Nothing was rebooted.'
    }
    else {
        Write-Host ("Restarting into {0} in 15 seconds..." -f $label)

        # Detached on purpose. shutdown.exe with /t BLOCKS for the whole countdown
        # and is killed by the shutdown it just scheduled, so calling it inline made
        # this script die mid-call: exit code 1, no message, and it looked like the
        # click did nothing. Started without -Wait, this script finishes its own
        # output first and is not around when the machine goes down.
        Write-Log 'issuing the reboot request (detached)'
        try {
            if (-not (Get-Command $ShutdownPath -ErrorAction SilentlyContinue)) {
                throw "cannot find '$ShutdownPath' on PATH"
            }
            # Quote the comment so it stays ONE argument; unquoted, shutdown.exe
            # takes 'osswitch:' as the message and chokes on the rest.
            $shutArgs = @('/r', '/t', '15', '/c', ('"osswitch: booting {0}"' -f $label))
            $null = Start-Process -FilePath $ShutdownPath -ArgumentList $shutArgs -WindowStyle Hidden
            Write-Log 'reboot scheduled'

            Write-Host ''
            Write-Host '  Close anything you want to keep open.'
            Write-Host '  To cancel the restart, run:  shutdown /a'
            Write-Host ''
            Start-Sleep -Seconds 5
            exit 0
        }
        catch {
            Write-Log ('REBOOT SCHEDULING FAILED: ' + $_.Exception.Message)
            Write-Host ''
            Write-Host ('  THE RESTART COULD NOT BE STARTED: ' + $_.Exception.Message)
            Write-Host '  Nothing has changed. Press Enter to close this window.'
            if (-not $NoPause) { $null = Read-Host } else { Start-Sleep -Milliseconds 200 }
            exit 1
        }
    }
}
elseif ($DryRun) {
    Write-Host 'Dry run finished. Nothing was rebooted.'
}
else {
    Write-Host 'Done - restarting.'
}

# Never let the window disappear while there is something to read. The reboot
# path ends in a restart anyway, so only that one closes on its own.
if (-not $rebooting) {
    Write-Host ''
    Write-Host 'Press Enter to close this window.'
    if (-not $NoPause) { $null = Read-Host } else { Start-Sleep -Milliseconds 200 }
}
exit $code