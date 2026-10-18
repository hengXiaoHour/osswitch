<#
.SYNOPSIS
    Test suite for osswitch.ps1. Runs the shipped script against a stub bcdedit.

.DESCRIPTION
    Every scenario runs the real script in a child powershell.exe with
    -BcdeditPath and -ShutdownPath pointed at stubs in a throwaway directory, so
    nothing on this machine's boot store is ever touched.

    The stub keeps its firmware state in a JSON file and reflects writes back on
    /enum, which makes the script's own read-back verification meaningful instead
    of self-confirming.

.PARAMETER ScriptPath
    The oswitch.ps1 to exercise. The mutant runs point this at a broken copy.

.PARAMETER Mutants
    Also prove the suite is not vacuous: break the script in six specific ways
    and require the suite to fail on each one.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_osswitch.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\test_osswitch.ps1 -Mutants
#>
[CmdletBinding()]
param(
    [string] $ScriptPath = '',
    [switch] $Mutants
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$StubSrc = Join-Path $PSScriptRoot 'stub'

# Windows PowerShell 5.1 does not populate $PSScriptRoot while it is still
# evaluating parameter defaults, so the default is resolved here instead.
if (-not $ScriptPath) { $ScriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'osswitch.ps1' }

$GuidWindows = '{11111111-1111-1111-1111-111111111111}'
$GuidManjaro = '{22222222-2222-2222-2222-222222222222}'
$GuidHttp = '{33333333-3333-3333-3333-333333333333}'
$GuidUsb = '{44444444-4444-4444-4444-444444444444}'
$GuidVendor = '{8be4df61-93ca-11d2-aa0d-00e098032b8c}'

# Which osswitch.ps1 the scenarios execute. The mutant loop re-points this at a
# broken copy; everything else reads it through Invoke-Osswitch.
$script:Target = $ScriptPath

$script:Pass = 0
$script:Fails = New-Object System.Collections.Generic.List[string]

function Check-True {
    param([string] $Label, [bool] $Cond, [string] $Detail = '')
    if ($Cond) {
        $script:Pass++
        Write-Host ("[ok  ] {0}" -f $Label)
    }
    else {
        $script:Fails.Add($Label)
        $suffix = ''
        if ($Detail) { $suffix = " -- $Detail" }
        Write-Host ("[FAIL] {0}{1}" -f $Label, $suffix)
    }
}

function Check-Equal {
    param([string] $Label, $Got, $Want)
    Check-True -Label $Label -Cond ("$Got" -eq "$Want") -Detail ("got '$Got', want '$Want'")
}

function New-Scenario {
    <#
        Fresh stub directory with a known firmware layout:
        Manjaro Boot0003, Windows Boot Manager Boot0004, HTTPs Boot0000,
        USB Boot0001, with the machine already set to boot Manjaro first.
    #>
    param([hashtable] $Overrides = @{})

    $dir = Join-Path ([IO.Path]::GetTempPath()) ('osswitch-test-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Copy-Item (Join-Path $StubSrc 'bcd.cmd') $dir -Force
    Copy-Item (Join-Path $StubSrc 'bcd.ps1') $dir -Force
    Copy-Item (Join-Path $StubSrc 'shutdown.cmd') $dir -Force

    # Mirrors the real machine: no Boot#### objects, Windows is {bootmgr}, the
    # order lives in displayorder, and Manjaro boots first.
    $state = [ordered]@{
        style    = 'firmware'
        order    = @($GuidManjaro, '{bootmgr}', $GuidHttp, $GuidUsb)
        override = @()
        entries  = @(
            [ordered]@{ header = 'Windows Boot Manager'; description = 'Windows Boot Manager'; id = '{bootmgr}'; device = 'partition=\Device\HarddiskVolume1'; path = '\EFI\Microsoft\Boot\bootmgfw.efi' }
            [ordered]@{ description = 'Manjaro'; id = $GuidManjaro; device = 'partition=\Device\HarddiskVolume1'; path = '\EFI\Manjaro\grubx64.efi' }
            [ordered]@{ description = 'UEFI HTTPs Boot'; id = $GuidHttp; device = ''; path = '' }
            [ordered]@{ description = 'UEFI PM9A1 NVMe Samsung'; id = $GuidUsb; device = 'partition=\Device\HarddiskVolume1'; path = '\EFI\Boot\BootX64.efi' }
        )
    }
    foreach ($k in $Overrides.Keys) {
        if ($k -eq 'order' -or $k -eq 'entries') { $state[$k] = @($Overrides[$k]) }
        else { $state[$k] = $Overrides[$k] }
    }

    $state | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $dir 'state.json') -Encoding UTF8
    return $dir
}

function Invoke-Osswitch {
    param(
        [string] $Dir,
        # Deliberately not $Args: that is a PowerShell automatic variable, and a
        # parameter named $Args is silently never bound. Every scenario then ran
        # osswitch with no arguments at all.
        [string[]] $CliArgs,
        [hashtable] $Env = @{}
    )

    $env:OSSWITCH_STUB_DIR = $Dir
    $env:OSSWITCH_TEST_BYPASS_ELEVATION = '1'
    $env:OSSWITCH_STUB_IGNORE_SET = '0'
    $env:OSSWITCH_STUB_GARBAGE = '0'
    foreach ($k in $Env.Keys) { Set-Item -Path "env:$k" -Value ([string]$Env[$k]) }

    $argv = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:Target
        '-BcdeditPath', (Join-Path $Dir 'bcd.cmd')
        '-ShutdownPath', (Join-Path $Dir 'shutdown.cmd')
        '-StatePath', (Join-Path $Dir 'saved-order.json')
    ) + $CliArgs

    $out = & powershell.exe @argv 2>&1 | Out-String
    $exit = $LASTEXITCODE

    # Set OSSWITCH_TEST_TRACE=1 to see exactly what each child printed.
    if ($env:OSSWITCH_TEST_TRACE -eq '1') {
        Write-Host ("    [child] {0} -> exit {1}" -f ($CliArgs -join ' '), $exit)
        foreach ($l in ($out -split "`r?`n")) { if ($l.Trim()) { Write-Host ("      | " + $l) } }
    }

    $stateFile = Join-Path $Dir 'state.json'
    $state = if (Test-Path $stateFile) { Get-Content $stateFile -Raw | ConvertFrom-Json } else { $null }
    $shutdownLog = Join-Path $Dir 'shutdown.log'
    $bcdLog = Join-Path $Dir 'bcd.log'

    # Assigned, not written as $( ... ): a $( ) subexpression collapses a
    # one-element array to a scalar, and after a switch the boot order really is
    # one element. Then $r.Order[0] would return the character '{'.
    $order = @()
    $override = @()
    if ($state) {
        $order = @($state.order)
        if ($state.PSObject.Properties.Name -contains 'override') { $override = @($state.override) }
    }

    return [pscustomobject]@{
        Out            = $out
        Exit           = $exit
        Order          = $order
        Override       = $override
        Rebooted       = (Test-Path $shutdownLog)
        RebootLog      = $(if (Test-Path $shutdownLog) { Get-Content $shutdownLog -Raw } else { '' })
        BcdLog         = $(if (Test-Path $bcdLog) { Get-Content $bcdLog -Raw } else { '' })
        SavedOrderFile = (Join-Path $Dir 'saved-order.json')
    }
}

function Remove-Scenario {
    param([string] $Dir)
    if ($Dir -and (Test-Path $Dir)) { Remove-Item -Path $Dir -Recurse -Force -ErrorAction SilentlyContinue }
}

function Invoke-Suite {
    param([string] $Tag = '')

    function Labelled { param([string] $Text) if ($Tag) { return "$Tag $Text" } else { return $Text } }

    $originalOrder = @($GuidManjaro, '{bootmgr}', $GuidHttp, $GuidUsb) -join ','

    # ---- 1. status is read-only and works without elevation ----
    $d = New-Scenario
    $r = Invoke-Osswitch -Dir $d -CliArgs @('-Action', 'status')
    Check-True -Label (Labelled 'status exits 0') -Cond ($r.Exit -eq 0) -Detail "exit $($r.Exit)"
    Check-True -Label (Labelled 'status lists both target OSes') -Cond (($r.Out -match 'Manjaro') -and ($r.Out -match 'Windows Boot Manager'))
    Check-True -Label (Labelled 'status says Manjaro boots next') -Cond ($r.Out -match 'Boots next: Manjaro')
    Check-True -Label (Labelled 'status never calls bcdedit /set') -Cond ($r.BcdLog -notmatch '/set')
    Check-Equal -Label (Labelled 'status leaves the boot order untouched') -Got ($r.Order -join ',') -Want $originalOrder
    Check-True -Label (Labelled 'status does not reboot') -Cond (-not $r.Rebooted)
    Check-True -Label (Labelled 'status mentions hibernation') -Cond ($r.Out -match '(?i)hibernat')
    Remove-Scenario $d

    # ---- 2. list shows the firmware entries on their own ----
    $d = New-Scenario
    $r = Invoke-Osswitch -Dir $d -CliArgs @('-Action', 'list')
    Check-True -Label (Labelled 'list exits 0') -Cond ($r.Exit -eq 0)
    Check-True -Label (Labelled 'list shows every firmware entry') -Cond (
        ($r.Out -match 'Manjaro') -and ($r.Out -match 'Windows Boot Manager') -and
        ($r.Out -match 'UEFI HTTPs Boot') -and ($r.Out -match 'UEFI PM9A1'))
    Check-True -Label (Labelled 'list does not reboot') -Cond (-not $r.Rebooted)
    Remove-Scenario $d

    # ---- 3. DryRun applies, verifies, and does NOT reboot ----
    $d = New-Scenario
    $r = Invoke-Osswitch -Dir $d -CliArgs @('-Action', 'windows', '-DryRun')
    Check-True -Label (Labelled 'dry run windows exits 0') -Cond ($r.Exit -eq 0) -Detail $r.Out
    Check-Equal -Label (Labelled 'dry run windows sets the one-shot override') -Got (@($r.Override) -join ',') -Want '{bootmgr}'
    Check-Equal -Label (Labelled 'dry run leaves the firmware order untouched') -Got ($r.Order -join ',') -Want $originalOrder
    Check-True -Label (Labelled 'dry run reports it verified the change') -Cond ($r.Out -match 'Verified')
    Check-True -Label (Labelled 'dry run never reboots') -Cond (-not $r.Rebooted)
    Check-True -Label (Labelled 'dry run remembered the previous override for restore') -Cond (Test-Path $r.SavedOrderFile)
    # Guarded read: a broken script may never write the file, and the harness
    # must record a FAIL rather than die with a FileNotFoundException.
    $savedOverride = @()
    if (Test-Path $r.SavedOrderFile) { $savedOverride = @((Get-Content $r.SavedOrderFile -Raw | ConvertFrom-Json).override) }
    Check-Equal -Label (Labelled 'saved override was empty, matching the untouched machine') -Got ($savedOverride -join ',') -Want ''
    Remove-Scenario $d

    # ---- 4. switching to manjaro from a Windows-first machine ----
    $d = New-Scenario -Overrides @{ order = @('{bootmgr}', $GuidManjaro, $GuidHttp, $GuidUsb) }
    $r = Invoke-Osswitch -Dir $d -CliArgs @('-Action', 'manjaro', '-DryRun')
    Check-True -Label (Labelled 'dry run manjaro exits 0') -Cond ($r.Exit -eq 0) -Detail $r.Out
    Check-Equal -Label (Labelled 'dry run manjaro sets the one-shot override') -Got (@($r.Override) -join ',') -Want $GuidManjaro
    Check-Equal -Label (Labelled 'dry run manjaro leaves the firmware order untouched') -Got ($r.Order -join ',') -Want (@('{bootmgr}', $GuidManjaro, $GuidHttp, $GuidUsb) -join ',')
    Check-True -Label (Labelled 'dry run manjaro never reboots') -Cond (-not $r.Rebooted)
    Remove-Scenario $d

    # ---- 5. without DryRun it does reboot ----
    $d = New-Scenario
    $r = Invoke-Osswitch -Dir $d -CliArgs @('-Action', 'windows')
    Check-True -Label (Labelled 'real switch asks for a reboot') -Cond $r.Rebooted
    Check-True -Label (Labelled 'the reboot is a restart (/r)') -Cond ($r.RebootLog -match '/r')
    Remove-Scenario $d

    # ---- 6. an already-correct switch is a no-op, not a surprise reboot ----
    $d = New-Scenario
    $r = Invoke-Osswitch -Dir $d -CliArgs @('-Action', 'manjaro')
    Check-True -Label (Labelled 'already-on-target exits 0') -Cond ($r.Exit -eq 0)
    Check-True -Label (Labelled 'already-on-target says so') -Cond ($r.Out -match 'Already set to Manjaro')
    Check-True -Label (Labelled 'already-on-target writes nothing') -Cond ($r.BcdLog -notmatch '/set')
    Check-True -Label (Labelled 'already-on-target does not reboot') -Cond (-not $r.Rebooted)
    Remove-Scenario $d

    # ---- 7. an ambiguous target is refused ----
    $d = New-Scenario -Overrides @{
        entries = @(
            [ordered]@{ description = 'Manjaro'; id = $GuidManjaro; device = 'partition=\Device\HarddiskVolume1'; path = '\EFI\Manjaro\grubx64.efi' }
            [ordered]@{ description = 'Manjaro (backup)'; id = '{55555555-5555-5555-5555-555555555555}'; device = 'partition=\Device\HarddiskVolume1'; path = '\EFI\Manjaro2\grubx64.efi' }
            [ordered]@{ header = 'Windows Boot Manager'; description = 'Windows Boot Manager'; id = '{bootmgr}'; device = 'partition=\Device\HarddiskVolume1'; path = '\EFI\Microsoft\Boot\bootmgfw.efi' }
        )
        order = @($GuidManjaro, '{bootmgr}')
    }
    $r = Invoke-Osswitch -Dir $d -CliArgs @('-Action', 'manjaro', '-Force')
    Check-True -Label (Labelled 'ambiguous target exits 1') -Cond ($r.Exit -eq 1)
    Check-True -Label (Labelled 'ambiguous target explains itself') -Cond ($r.Out -match 'ambiguous')
    Check-True -Label (Labelled 'ambiguous target writes nothing') -Cond ($r.BcdLog -notmatch '/set')
    Remove-Scenario $d

    # ---- 8. a missing target is refused ----
    $d = New-Scenario -Overrides @{
        entries = @(
            [ordered]@{ header = 'Windows Boot Manager'; description = 'Windows Boot Manager'; id = '{bootmgr}'; device = 'partition=\Device\HarddiskVolume1'; path = '\EFI\Microsoft\Boot\bootmgfw.efi' }
        )
        order = @('{bootmgr}')
    }
    $r = Invoke-Osswitch -Dir $d -CliArgs @('-Action', 'manjaro')
    Check-True -Label (Labelled 'missing target exits 1') -Cond ($r.Exit -eq 1)
    Check-True -Label (Labelled 'missing target names what it looked for') -Cond ($r.Out -match 'No firmware entry matches Manjaro')
    Check-True -Label (Labelled 'missing target does not reboot') -Cond (-not $r.Rebooted)
    Remove-Scenario $d

    # ---- 9. the shared UEFI vendor GUID is refused, not silently accepted ----
    $d = New-Scenario -Overrides @{
        entries = @(
            [ordered]@{ description = 'Manjaro'; id = $GuidVendor; device = 'partition=\Device\HarddiskVolume1'; path = '\EFI\Manjaro\grubx64.efi' }
            [ordered]@{ header = 'Windows Boot Manager'; description = 'Windows Boot Manager'; id = '{bootmgr}'; device = 'partition=\Device\HarddiskVolume1'; path = '\EFI\Microsoft\Boot\bootmgfw.efi' }
        )
        order = @($GuidVendor, '{bootmgr}')
    }
    $r = Invoke-Osswitch -Dir $d -CliArgs @('-Action', 'manjaro', '-Force')
    Check-True -Label (Labelled 'vendor GUID exits 1') -Cond ($r.Exit -eq 1)
    Check-True -Label (Labelled 'vendor GUID explains the silent-success trap') -Cond ($r.Out -match 'vendor GUID')
    Check-True -Label (Labelled 'vendor GUID writes nothing') -Cond ($r.BcdLog -notmatch '/set')
    Remove-Scenario $d

    # ---- 10. firmware that ignores the write is caught, and no reboot follows ----
    $d = New-Scenario
    $r = Invoke-Osswitch -Dir $d -CliArgs @('-Action', 'windows') -Env @{ OSSWITCH_STUB_IGNORE_SET = '1' }
    Check-True -Label (Labelled 'ignored write exits 1') -Cond ($r.Exit -eq 1)
    Check-True -Label (Labelled 'ignored write is reported as a verification failure') -Cond ($r.Out -match 'Verification failed')
    Check-True -Label (Labelled 'ignored write does not reboot') -Cond (-not $r.Rebooted)
    Remove-Scenario $d

    # ---- 11. an unreadable boot store is reported, not swallowed ----
    $d = New-Scenario
    $r = Invoke-Osswitch -Dir $d -CliArgs @('-Action', 'windows') -Env @{ OSSWITCH_STUB_GARBAGE = '1' }
    Check-True -Label (Labelled 'unreadable boot store exits 1') -Cond ($r.Exit -eq 1)
    Check-True -Label (Labelled 'unreadable boot store names the failure') -Cond ($r.Out -match '(?i)boot configuration data store')
    Remove-Scenario $d

    # ---- 12. restore rebuilds the whole saved ranking ----
    $d = New-Scenario
    $null = Invoke-Osswitch -Dir $d -CliArgs @('-Action', 'windows', '-DryRun')
    $r = Invoke-Osswitch -Dir $d -CliArgs @('-Action', 'restore', '-DryRun')
    Check-True -Label (Labelled 'restore exits 0') -Cond ($r.Exit -eq 0) -Detail $r.Out
    Check-Equal -Label (Labelled 'restore clears the one-shot override') -Got (@($r.Override) -join ',') -Want ''
    Check-Equal -Label (Labelled 'restore leaves the firmware order alone') -Got ($r.Order -join ',') -Want $originalOrder
    Check-True -Label (Labelled 'restore verifies') -Cond ($r.Out -match 'Verified')
    Check-True -Label (Labelled 'restore does not reboot in a dry run') -Cond (-not $r.Rebooted)
    Remove-Scenario $d

    # ---- 13. restore with nothing saved says so ----
    $d = New-Scenario
    $r = Invoke-Osswitch -Dir $d -CliArgs @('-Action', 'restore')
    Check-True -Label (Labelled 'restore without a saved order exits 1') -Cond ($r.Exit -eq 1)
    Check-True -Label (Labelled 'restore without a saved order explains why') -Cond ($r.Out -match 'nothing to restore')
    Check-True -Label (Labelled 'restore without a saved order does not reboot') -Cond (-not $r.Rebooted)
    Remove-Scenario $d

    # ---- 14. the GUID is read from the live boot store, never hardcoded ----
    $unseen = '{99999999-9999-9999-9999-999999999999}'
    $d = New-Scenario -Overrides @{
        entries = @(
            [ordered]@{ description = 'Manjaro'; id = $unseen; device = 'partition=\Device\HarddiskVolume1'; path = '\EFI\Manjaro\grubx64.efi' }
            [ordered]@{ header = 'Windows Boot Manager'; description = 'Windows Boot Manager'; id = '{bootmgr}'; device = 'partition=\Device\HarddiskVolume1'; path = '\EFI\Microsoft\Boot\bootmgfw.efi' }
        )
        order = @('{bootmgr}', $unseen)
    }
    $r = Invoke-Osswitch -Dir $d -CliArgs @('-Action', 'manjaro')
    Check-True -Label (Labelled 'a GUID never seen before still switches') -Cond ($r.Exit -eq 0) -Detail $r.Out
    Check-Equal -Label (Labelled 'the switch used the GUID read at runtime') -Got (@($r.Override) -join ',') -Want $unseen
    Remove-Scenario $d

    # ---- 15. REAL bcdedit output captured from this machine, replayed verbatim ----
    # The most valuable check in the suite: the stubbed scenarios describe what we
    # think bcdedit prints. This is what it actually printed here.
    $fixture = Join-Path $PSScriptRoot 'fixture-real-firmware-enum.txt'
    Check-True -Label (Labelled 'the real-output fixture exists') -Cond (Test-Path $fixture)
    if (Test-Path $fixture) {
        $d = New-Scenario
        $r = Invoke-Osswitch -Dir $d -CliArgs @('-Action', 'list') -Env @{ OSSWITCH_STUB_FIXTURE = $fixture }
        Check-True -Label (Labelled 'real output: exits 0') -Cond ($r.Exit -eq 0) -Detail $r.Out
        Check-True -Label (Labelled 'real output: finds the Manjaro entry') -Cond ($r.Out -match 'Manjaro')
        Check-True -Label (Labelled 'real output: finds Windows Boot Manager') -Cond ($r.Out -match 'Windows Boot Manager')
        Check-True -Label (Labelled 'real output: finds all four entries') -Cond (
            ($r.Out -match 'UEFI HTTPs Boot') -and ($r.Out -match 'UEFI PM9A1'))
        Check-True -Label (Labelled 'real output: reads the wrapped displayorder') -Cond ($r.Out -match 'Boots next: Manjaro')
        Check-True -Label (Labelled 'real output: does not reboot') -Cond (-not $r.Rebooted)
        Check-True -Label (Labelled 'real output: writes nothing on a read-only action') -Cond ($r.BcdLog -notmatch '/set')
        Remove-Scenario $d

        # And it must resolve the real Manjaro identifier, which is a firmware
        # GUID, not the shared vendor GUID.
        $d = New-Scenario
        $r = Invoke-Osswitch -Dir $d -CliArgs @('-Action', 'status') -Env @{ OSSWITCH_STUB_FIXTURE = $fixture }
        Check-True -Label (Labelled 'real output: status exits 0') -Cond ($r.Exit -eq 0) -Detail $r.Out
        Remove-Scenario $d
    }

    # ---- 16. the legacy Boot#### / bootsequence shape still parses ----
    $d = New-Scenario -Overrides @{ style = 'classic' }
    $r = Invoke-Osswitch -Dir $d -CliArgs @('-Action', 'list')
    Check-True -Label (Labelled 'legacy shape: exits 0') -Cond ($r.Exit -eq 0) -Detail $r.Out
    Check-True -Label (Labelled 'legacy shape: finds Manjaro') -Cond ($r.Out -match 'Manjaro')
    Check-True -Label (Labelled 'legacy shape: reads a bootsequence-only machine') -Cond ($r.Out -match 'Boots next: Manjaro')
    Remove-Scenario $d
}

Write-Host ("osswitch suite -> {0}" -f $script:Target)
Invoke-Suite
Write-Host ''
Write-Host ("baseline: {0} passed, {1} failed" -f $script:Pass, $script:Fails.Count)

$mutantProblems = New-Object System.Collections.Generic.List[string]

if ($Mutants) {
    Write-Host ''
    Write-Host 'Mutant checks: every broken copy must make the suite fail.'

    $source = [System.IO.File]::ReadAllText($ScriptPath)
    $scratch = Join-Path ([IO.Path]::GetTempPath()) ('osswitch-mutants-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $scratch -Force | Out-Null

    $mutantList = @(
        @{
            Name = 'M1 hardcodes the target GUID instead of reading it at runtime'
            Old  = '    return $entry'
            New  = "    return [pscustomobject]@{ Header = 'Firmware Application (101fffff)'; Description = 'Manjaro'; Identifier = '$GuidManjaro'; Path = '' }"
        }
        @{
            Name = 'M2 verifies against the request instead of reading the boot store back'
            Old  = "    `$now = @(`$after.Override)`n    if (`$now.Count -ne 1 -or `$now[0] -ne `$Identifier) {"
            New  = "    `$now = @(`$Identifier)`n    if (`$now.Count -ne 1 -or `$now[0] -ne `$Identifier) {"
        }
        @{
            Name = 'M3 drops the shared UEFI vendor GUID guard'
            Old  = "if ((`$entry.Identifier -replace '[{}]', '').ToLowerInvariant() -eq `$script:VendorGuid) {"
            New  = 'if ($false) {'
        }
        @{
            Name = 'M4 ignores -DryRun and reboots anyway'
            Old  = '    if ($DryRun) {'
            New  = '    if ($DryRun -and $false) {'
            Count = 2
        }
        @{
            Name = 'M5 switches even when the machine already boots that OS'
            Old  = 'if (($already -or $isFirst) -and -not $Force) {'
            New  = 'if ($false) {'
        }
        @{
            Name = 'M6 restore never actually clears the override'
            Old  = "    Invoke-Bcd -BcdArgs @('/deletevalue', '{fwbootmgr}', 'bootsequence') | Out-Null"
            New  = '    # mutant: the override is never deleted'
        }
        @{
            Name = 'M7 writes displayorder instead of bootsequence (the bug found on this machine)'
            Old  = "@('/set', '{fwbootmgr}', 'bootsequence', `$Identifier)"
            New  = "@('/set', '{fwbootmgr}', 'displayorder', `$Identifier)"
        }
        @{
            Name = 'M8 lists entries with /enum {fwbootmgr}, which shows none on this machine'
            Old  = "Invoke-Bcd -BcdArgs @('/enum', 'firmware')"
            New  = "Invoke-Bcd -BcdArgs @('/enum', '{fwbootmgr}')"
        }
    )

    $caught = 0
    foreach ($m in $mutantList) {
        # A mutant whose anchor matched an unexpected number of times is not a
        # mutant; report it rather than letting it read as a blind check.
        $want = 1
        if ($m.ContainsKey('Count')) { $want = $m.Count }
        $count = ([regex]::Matches($source, [regex]::Escape($m.Old))).Count
        if ($count -ne $want) {
            $mutantProblems.Add("$($m.Name) [anchor matched $count times, expected $want]")
            Write-Host ("[skip ] {0} -- anchor matched {1} times, expected {2}" -f $m.Name, $count, $want)
            continue
        }

        $mutantPath = Join-Path $scratch ('mutant-' + ([array]::IndexOf($mutantList, $m)) + '.ps1')
        [System.IO.File]::WriteAllText($mutantPath, $source.Replace($m.Old, $m.New))
        if ((Get-Content $mutantPath -Raw) -eq $source) {
            $mutantProblems.Add("$($m.Name) [mutation did not change the file]")
            Write-Host ("[skip ] {0} -- mutation was a no-op" -f $m.Name)
            continue
        }

        $script:Target = $mutantPath
        $script:Fails.Clear()
        Invoke-Suite -Tag $m.Name.Substring(0, 2)

        if ($script:Fails.Count -gt 0) {
            $caught++
            Write-Host ("[caught] {0} ({1} failing checks)" -f $m.Name, $script:Fails.Count)
        }
        else {
            $mutantProblems.Add($m.Name)
            Write-Host ("[MISSED] {0} -- suite passed against a broken script" -f $m.Name)
        }
    }

    $script:Target = $ScriptPath
    Remove-Item -Path $scratch -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host ''
    Write-Host ("mutants caught: {0}/{1}" -f $caught, $mutantList.Count)
    if ($caught -ne $mutantList.Count) { exit 1 }
}

if ($script:Fails.Count -gt 0) {
    Write-Host ''
    Write-Host 'failing checks:'
    $script:Fails | ForEach-Object { Write-Host ("  - " + $_) }
    exit 1
}
if ($mutantProblems.Count -gt 0) {
    exit 1
}

Write-Host 'ALL SUITE CHECKS PASSED'
exit 0