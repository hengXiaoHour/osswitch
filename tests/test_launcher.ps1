<#
    Tests the desktop launcher end to end against stubs, so the reboot path can
    be exercised without rebooting the machine.
#>
[CmdletBinding()]
param(
    # The non-elevated path calls Start-Process -Verb RunAs, which raises a UAC
    # prompt. It is therefore opt-in, because the default suite must not interrupt
    # anyone. It is still worth running: that branch once used $label before it was
    # assigned, which killed the script on its first line of output, and every
    # bypassed test was blind to it.
    [switch] $IncludeElevation
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$proj = Split-Path -Parent $PSScriptRoot
$launcher = Join-Path $proj 'tools\osswitch-launch.ps1'
$stubSrc = Join-Path $proj 'tests\stub'
if (-not (Test-Path $launcher)) { Write-Host "launcher not found at $launcher"; exit 1 }

$pass = 0
$fails = New-Object System.Collections.Generic.List[string]
function Check {
    param([string] $Label, [bool] $Cond, [string] $Detail = '')
    if ($Cond) { $script:pass++; Write-Host ("[ok  ] {0}" -f $Label) }
    else {
        $script:fails.Add($Label)
        $sfx = if ($Detail) { " -- $Detail" } else { '' }
        Write-Host ("[FAIL] {0}{1}" -f $Label, $sfx)
    }
}

function New-Scenario {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('launch-test-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Copy-Item (Join-Path $stubSrc 'bcd.cmd') $dir -Force
    Copy-Item (Join-Path $stubSrc 'bcd.ps1') $dir -Force
    Copy-Item (Join-Path $stubSrc 'shutdown.cmd') $dir -Force
    $M = '{22222222-2222-2222-2222-222222222222}'
    $W = '{bootmgr}'
    $H = '{33333333-3333-3333-3333-333333333333}'
    $U = '{44444444-4444-4444-4444-444444444444}'
    [ordered]@{
        style    = 'firmware'
        order    = @($M, $W, $H, $U)
        override = @()
        entries  = @(
            [ordered]@{ header = 'Windows Boot Manager'; description = 'Windows Boot Manager'; id = $W; device = 'partition=\Device\HarddiskVolume1'; path = '\EFI\Microsoft\Boot\bootmgfw.efi' }
            [ordered]@{ description = 'Manjaro'; id = $M; device = 'partition=\Device\HarddiskVolume1'; path = '\EFI\Manjaro\grubx64.efi' }
            [ordered]@{ description = 'UEFI HTTPs Boot'; id = $H; device = ''; path = '' }
            [ordered]@{ description = 'UEFI PM9A1 NVMe Samsung'; id = $U; device = 'partition=\Device\HarddiskVolume1'; path = '\EFI\Boot\BootX64.efi' }
        )
    } | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $dir 'state.json') -Encoding UTF8
    return $dir
}

function Run-Launcher {
    param([string] $Dir, [string] $Target, [switch] $DryRun, [switch] $NoConfirm)
    $env:OSSWITCH_STUB_DIR = $Dir
    $env:OSSWITCH_TEST_BYPASS_ELEVATION = '1'
    $env:OSSWITCH_STUB_IGNORE_SET = '0'
    $env:OSSWITCH_STUB_GARBAGE = '0'
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcher,
        '-Target', $Target,
        '-BcdeditPath', (Join-Path $Dir 'bcd.cmd'),
        '-ShutdownPath', (Join-Path $Dir 'shutdown.cmd'),
        # Keep the remembered override inside the scenario. Without this the
        # launcher writes a REAL .osswitch-state.json into the project.
        '-StatePath', (Join-Path $Dir 'saved-override.json'))
    if ($DryRun) { $argv += '-DryRun' }
    if ($NoConfirm) { $argv += '-NoConfirm' }
    $out = & powershell.exe @argv 2>&1 | Out-String
    return [pscustomobject]@{
        Out      = $out
        Exit     = $LASTEXITCODE
        Rebooted = (Test-Path (Join-Path $Dir 'shutdown.log'))
        BcdLog   = $(if (Test-Path (Join-Path $Dir 'bcd.log')) { Get-Content (Join-Path $Dir 'bcd.log') -Raw } else { '' })
        State    = (Get-Content (Join-Path $Dir 'state.json') -Raw | ConvertFrom-Json)
    }
}

Write-Host 'launcher tests'

# ---- 1. a real switch sets the override AND asks for the reboot ----
$d = New-Scenario
$r = Run-Launcher -Dir $d -Target windows -NoConfirm
Check 'plain switch exits 0' ($r.Exit -eq 0) $r.Out
Check 'plain switch set the one-shot override' ((@($r.State.override) -join ',') -eq '{bootmgr}')
Check 'plain switch requested the reboot' $r.Rebooted
Check 'plain switch is a restart' ((Get-Content (Join-Path $d 'shutdown.log') -Raw) -match '/r')
Check 'plain switch confirms it finished' ($r.Out -match 'Done - restarting')
Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue

# ---- 2. -DryRun applies and verifies but must NOT reboot ----
$d = New-Scenario
$r = Run-Launcher -Dir $d -Target windows -DryRun -NoConfirm
Check 'dry run exits 0' ($r.Exit -eq 0) $r.Out
Check 'dry run set the override' ((@($r.State.override) -join ',') -eq '{bootmgr}')
Check 'dry run did NOT reboot' (-not $r.Rebooted)
Check 'dry run says nothing was rebooted' ($r.Out -match 'Nothing was rebooted')
Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue

# ---- 3. already on the target OS: must explain AND still reboot ----
# This is the case the user actually hit: the machine already boots Manjaro, so
# osswitch correctly changes nothing. Sitting on a silent "nothing to do" made
# the shortcut look broken.
$d = New-Scenario
$r = Run-Launcher -Dir $d -Target manjaro -NoConfirm
Check 'already-on-target exits 0' ($r.Exit -eq 0) $r.Out
Check 'already-on-target explains why nothing changed' ($r.Out -match 'Already set to boot Manjaro')
Check 'already-on-target does not claim a dry run' (-not ($r.Out -match 'Nothing was rebooted'))
Check 'already-on-target still reboots (the user asked to boot it)' $r.Rebooted
Check 'already-on-target reboot has a cancellation window' ((Get-Content (Join-Path $d 'shutdown.log') -Raw) -match '/t 15')
# Detached, so the launcher must finish its own output and exit 0 rather than
# being killed by the shutdown it scheduled.
Check 'already-on-target launcher exits cleanly' ($r.Exit -eq 0) $r.Out
Check 'already-on-target tells the user how to cancel' ($r.Out -match 'shutdown /a')
Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue

# ---- 3b. already on target + -DryRun must NOT reboot ----
$d = New-Scenario
$r = Run-Launcher -Dir $d -Target manjaro -DryRun -NoConfirm
Check 'already-on-target dry run exits 0' ($r.Exit -eq 0) $r.Out
Check 'already-on-target dry run does not reboot' (-not $r.Rebooted)
Check 'already-on-target dry run says nothing rebooted' ($r.Out -match 'Nothing was rebooted')
Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue

# ---- 3c. a real switch must NOT schedule a second reboot ----
# osswitch already requested the restart; the launcher must not add another.
$d = New-Scenario
$r = Run-Launcher -Dir $d -Target windows -NoConfirm
$log = @(Get-Content (Join-Path $d 'shutdown.log'))
Check 'a real switch requests the reboot exactly once' ($log.Count -eq 1)
Check 'a real switch confirms it is restarting' ($r.Out -match 'Done - restarting')
Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue

# ---- 3d. a failing shutdown must be reported, not swallowed ----
# A reboot that could not be scheduled must never look like it worked.
$d = New-Scenario
# Replace the shutdown stub with one that fails, the way a blocked or denied
# shutdown.exe behaves.
Set-Content -Path (Join-Path $d 'shutdown.cmd') -Encoding ASCII -Value @(
    '@echo off',
    'echo Unable to initiate system shutdown 1>&2',
    'exit /b 5'
)
$r = Run-Launcher -Dir $d -Target windows -NoConfirm
Check 'a real switch with a failing reboot exits non-zero' ($r.Exit -ne 0)
# On a real switch osswitch itself requests the restart, so it is osswitch that
# reports the failure and the launcher only relays the non-zero exit.
Check 'a real switch with a failing reboot says so' ($r.Out -match 'could NOT be scheduled|osswitch stopped with exit code')
Check 'a real switch with a failing reboot does not claim success' (-not ($r.Out -match 'Done - restarting'))
Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue

# ---- 3e. the restart must NOT block the launcher ----
# This is the bug that made the shortcut look dead: shutdown.exe with /t blocks
# for the whole countdown and is killed by the restart it scheduled, so the
# script died mid-call with exit 1 and never printed a result. A slow shutdown
# stub stands in for that countdown.
$d = New-Scenario
Set-Content -Path (Join-Path $d 'shutdown.cmd') -Encoding ASCII -Value @(
    '@echo off',
    'ping -n 11 127.0.0.1 >nul',
    'exit /b 0'
)
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$r = Run-Launcher -Dir $d -Target manjaro -NoConfirm
$sw.Stop()
Check 'a slow restart does not hold the launcher open' ($sw.Elapsed.TotalSeconds -lt 8) ("took $([math]::Round($sw.Elapsed.TotalSeconds,1))s")
Check 'a slow restart still exits cleanly' ($r.Exit -eq 0) $r.Out
Check 'a slow restart still shows the result' ($r.Out -match 'Already set to boot Manjaro')
Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue

# ---- 4. a bad target is refused by parameter validation ----
# A rejected parameter writes to stderr, which surfaces as a terminating error
# under $ErrorActionPreference='Stop'. Relax it just for this call.
$prev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher -Target 'nonsense' -NoConfirm 2>&1 | Out-String
$badExit = $LASTEXITCODE
$ErrorActionPreference = $prev
Check 'invalid target exits non-zero' ($badExit -ne 0)
Check 'invalid target is rejected by validation' ($out -match 'does not belong|ValidateSet')

# ---- 4c. the DEFAULT ShutdownPath must be a real command ----
# Every other case injects a stub, which hid the fact that the default had been
# set to '' - so the real shortcut called Start-Process with an empty FilePath,
# threw, and died before it could restart anything.
$launcherSrc = [System.IO.File]::ReadAllText($launcher)
$defaultMatch = [regex]::Match($launcherSrc, "\[string\] \`$ShutdownPath = '([^']*)'")
Check 'the launcher declares a default ShutdownPath' $defaultMatch.Success
$defaultValue = if ($defaultMatch.Success) { $defaultMatch.Groups[1].Value } else { '' }
Check 'the default ShutdownPath is not empty' (-not [string]::IsNullOrWhiteSpace($defaultValue)) "got '$defaultValue'"
Check 'the default ShutdownPath exists on this machine' ([bool](Get-Command $defaultValue -ErrorAction SilentlyContinue)) "got '$defaultValue'"
# A bad path must produce a plain message and exit non-zero, not a red crash dump.
$d = New-Scenario
$argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcher,
    '-Target', 'manjaro', '-NoConfirm', '-NoPause',
    '-BcdeditPath', (Join-Path $d 'bcd.cmd'),
    '-ShutdownPath', 'definitely-not-a-real-command.exe',
    '-StatePath', (Join-Path $d 'saved.json'))
$env:OSSWITCH_STUB_DIR = $d
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
$out = & powershell.exe @argv 2>&1 | Out-String
$ErrorActionPreference = $prev
Check 'an unusable ShutdownPath exits non-zero' ($LASTEXITCODE -ne 0)
Check 'an unusable ShutdownPath is reported in plain words' ($out -match 'THE RESTART COULD NOT BE STARTED')
Check 'an unusable ShutdownPath does not print a raw exception' (-not ($out -match 'CategoryInfo|FullyQualifiedErrorId'))
Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue

# ---- 5. the suite must not touch the real project's state file ----
$realState = Join-Path $proj '.osswitch-state.json'
if (Test-Path $realState) { Remove-Item $realState -Force }
$d = New-Scenario
$null = Run-Launcher -Dir $d -Target windows -NoConfirm
Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
Check 'no state file is left in the real project' (-not (Test-Path $realState))

# ---- 6. the NON-elevated path, which every bypassed test skipped ----
# Runs with the bypass env var cleared, so the script really does enter the
# elevation branch. Whatever happens with the UAC prompt, it must never die on an
# undefined variable and must always leave a breadcrumb in the log.
if ($IncludeElevation) {
    $logFile = Join-Path $env:LOCALAPPDATA 'osswitch\launcher.log'
    $before = if (Test-Path $logFile) { (Get-Item $logFile).Length } else { 0 }
    $env:OSSWITCH_TEST_BYPASS_ELEVATION = ''
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher -Target manjaro -NoConfirm 2>&1 | Out-String
    $ErrorActionPreference = $prev
    $env:OSSWITCH_TEST_BYPASS_ELEVATION = '1'
    $after = if (Test-Path $logFile) { (Get-Item $logFile).Length } else { 0 }

    Check 'non-elevated run wrote to the log' ($after -gt $before)
    Check 'non-elevated run did not die on an undefined variable' (-not ($out -match 'cannot be retrieved because it has not been set'))
    Check 'non-elevated run did not die on $args' (-not ($out -match 'variable .\$args'))
    # Whichever way the prompt went, the user must be told something plain.
    Check 'non-elevated run explains itself in plain words' (
        ($out -match 'Administrator permission was not granted') -or ($out -match 'switching to Manjaro'))
    Write-Host '     (non-elevated run said:)'
    foreach ($l in (($out -split "`r?`n") | Where-Object { $_.Trim() })) { Write-Host ("       " + $l.Trim()) }
}

Write-Host ''
Write-Host ("launcher: {0} passed, {1} failed" -f $pass, $fails.Count)
if ($fails.Count -gt 0) { $fails | ForEach-Object { Write-Host ("  - " + $_) }; exit 1 }
Write-Host 'LAUNCHER TESTS PASSED'
exit 0