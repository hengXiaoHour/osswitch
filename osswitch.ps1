<#
.SYNOPSIS
    osswitch - switch this laptop's default boot OS between Windows 11 and Manjaro.

.DESCRIPTION
    Windows half of the osswitch pair. The Linux half lives at ~/.local/bin/osswitch
    and uses efibootmgr -n to set a one-time UEFI BootNext.

    This does the same thing with bcdedit: it writes a one-shot override on the
    firmware boot manager, so the next power-on goes to the OS you asked for and
    the override is consumed by that boot. Nothing else about the boot order is
    touched, so a switch that goes wrong simply falls through to the machine's own
    firmware order on the following boot.

    Windows needs administrator rights because bcdedit only opens the boot
    configuration data store for an elevated process.

.PARAMETER Action
    status    Show entries, current default and safety notes. Default.
    list      Show the firmware boot entries only.
    windows   Boot Windows Boot Manager next.
    manjaro   Boot Manjaro next.
    restore   Remove the pending one-shot override (or put back the previous one).

.PARAMETER DryRun
    Apply and verify the change, but do NOT reboot. Mirrors the Linux half's
    OSSWITCH_DRY_RUN=1 gate, which writes and verifies BootNext and then returns
    before the reboot.

.PARAMETER Force
    Allow a switch that changes nothing. No reboot is scheduled in that case.

.PARAMETER BcdeditPath
    Test seam. Point this at a stub bcdedit to exercise the script without ever
    touching the real boot store.

.PARAMETER ShutdownPath
    Test seam for the reboot command.

.PARAMETER StatePath
    Where the previous override is remembered for -Action restore.

.EXAMPLE
    osswitch status

.EXAMPLE
    osswitch manjaro -DryRun

.EXAMPLE
    osswitch windows
#>
[CmdletBinding()]
param(
    [ValidateSet('status', 'list', 'windows', 'manjaro', 'restore')]
    [string] $Action = 'status',

    [switch] $DryRun,
    [switch] $Force,

    [string] $BcdeditPath = 'bcdedit',
    [string] $ShutdownPath = 'shutdown.exe',
    [string] $StatePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$LASTEXITCODE = 0

# The GUID every UEFI firmware entry shares. It is never a valid switch target:
# bcdedit accepts it and changes nothing, which looks like a silent success.
# This is the exact trap the Linux handoff warns about.
$script:VendorGuid = '8be4df61-93ca-11d2-aa0d-00e098032b8c'

$script:Targets = @{
    'windows' = @{ Label = 'Windows 11'; Pattern = 'windows boot manager'; Identifier = '{bootmgr}' }
    'manjaro' = @{ Label = 'Manjaro';    Pattern = 'manjaro';           Identifier = '' }
}

function Write-Line {
    param([string] $Text = '')
    Write-Output $Text
}

function Test-Elevated {
    # Test seam only. OSSWITCH_TEST_BYPASS_ELEVATION lets the stub suite run the
    # switch logic without an admin prompt. It grants nothing: bcdedit still
    # refuses to open the boot store for an unelevated process, so this only
    # skips the friendly pre-check, never a real permission.
    if ($env:OSSWITCH_TEST_BYPASS_ELEVATION -eq '1') { return $true }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Bcd {
    param([string[]] $BcdArgs, [string] $Path = $BcdeditPath)

    $out = & $Path @BcdArgs 2>&1 | Out-String
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        # bcdedit's own words matter: on this machine /set displayorder fails
        # with "The entry list data is not valid as specified."
        throw ("bcdedit {0} FAILED (exit {1}): {2}" -f ($BcdArgs -join ' '), $code, $out.Trim())
    }
    return $out
}

function Split-GuidList {
    param([string] $Text)
    if (-not $Text) { return @() }
    return @($Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

<#
    Turns bcdedit enum text into the firmware boot order plus one object per boot
    entry.

    Two shapes are handled, because bcdedit emits both:

      Legacy Boot#### objects          Newer firmware applications
      ------------------              ------------------------------
      Boot0003      Manjaro            Firmware Application (101fffff)
      -------------                    -------------------------------
      identifier    {guid}             identifier    {guid}
      description   Manjaro            path         \EFI\Manjaro\grubx64.efi
                                       description  Manjaro

    Blocks are separated by blank lines and each is "header, dashed rule, keys".
    Long lists wrap onto indented continuation lines that each hold one more
    identifier, so those are appended to the key above rather than dropped.

    Only the {fwbootmgr} block's keys count. Per-entry blocks carry their own
    displayorder (for example {current}) which is not the machine's boot order.
#>
function ConvertFrom-BcdEnum {
    param([string] $Text)

    $blocks = New-Object System.Collections.Generic.List[object]
    $header = $null
    $body = New-Object System.Collections.Generic.List[string]

    foreach ($line in ($Text -split "`r?`n")) {
        if ($line.Trim() -eq '') {
            if ($null -ne $header) {
                $blocks.Add([pscustomobject]@{ Header = $header; Lines = @($body.ToArray()) })
            }
            $header = $null
            $body = New-Object System.Collections.Generic.List[string]
            continue
        }
        if ($null -eq $header) { $header = $line.Trim(); continue }
        if ($line -match '^\s*-{3,}\s*$') { continue }
        $body.Add($line)
    }
    if ($null -ne $header) {
        $blocks.Add([pscustomobject]@{ Header = $header; Lines = @($body.ToArray()) })
    }

    $firmwareOrder = @()
    $override = @()
    $entries = New-Object System.Collections.Generic.List[object]

    foreach ($block in $blocks) {
        $fields = [ordered]@{}
        $lastKey = $null
        foreach ($line in $block.Lines) {
            if ($line -match '^\s*([A-Za-z]+)\s{2,}(\S.*?)\s*$') {
                $lastKey = $Matches[1]
                $fields[$lastKey] = $Matches[2]
            }
            elseif ($line -match '^\s+(\{[^}]+\})\s*$' -and $null -ne $lastKey) {
                $fields[$lastKey] = $fields[$lastKey] + ',' + $Matches[1]
            }
        }

        if (-not $fields.Contains('identifier')) { continue }
        $id = $fields['identifier']

        if ($id -eq '{fwbootmgr}') {
            if ($fields.Contains('displayorder') -and $fields['displayorder'] -ne '{current}') {
                $firmwareOrder = Split-GuidList $fields['displayorder']
            }
            if ($fields.Contains('bootsequence')) {
                $override = Split-GuidList $fields['bootsequence']
            }
            continue
        }

        $desc = $block.Header
        if ($fields.Contains('description')) { $desc = $fields['description'] }
        $entries.Add([pscustomobject]@{
            Header      = $block.Header
            Description = $desc
            Identifier  = $id
            Path        = $(if ($fields.Contains('path')) { $fields['path'] } else { '' })
        })
    }

    # .ToArray(), not @($entries): in Windows PowerShell 5.1 the array
    # subexpression around a List[object] holding PSObject-wrapped items throws
    # "Argument types do not match".
    return [pscustomobject]@{
        FirmwareOrder = @($firmwareOrder)
        Override      = @($override)
        Entries       = @($entries.ToArray())
    }
}

function Get-CurrentBoot {
    # '/enum firmware', NOT '/enum {fwbootmgr}': on this machine the object form
    # returns the manager block alone, with no entry blocks, so every entry would
    # look missing.
    $raw = Invoke-Bcd -BcdArgs @('/enum', 'firmware')
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw 'bcdedit returned nothing for /enum firmware; cannot read the boot order.'
    }
    return ConvertFrom-BcdEnum -Text $raw
}

function Resolve-TargetEntry {
    param($Entries, [string] $Key)

    $target = $script:Targets[$Key]
    if ($null -eq $target) { throw ("No target definition for '{0}'." -f $Key) }

    $summary = (@($Entries | ForEach-Object { $_.Description }) -join ', ')

    # Prefer an exact identifier match when the target names one: descriptions
    # can repeat ("Manjaro", "Manjaro (backup)"), identifiers cannot.
    $hits = @()
    if ($target.Identifier) {
        $hits = @($Entries | Where-Object { $_.Identifier -eq $target.Identifier })
    }
    if ($hits.Count -eq 0) {
        $hits = @($Entries | Where-Object { $_.Description -match $target.Pattern })
    }

    if ($hits.Count -eq 0) {
        throw ("No firmware entry matches {0} (pattern '{1}'). Entries are: {2}" -f $target.Label, $target.Pattern, $summary)
    }
    if ($hits.Count -gt 1) {
        $names = (@($hits | ForEach-Object { "$($_.Header) '$($_.Description)'" }) -join ', ')
        throw ("{0} is ambiguous - {1} entries matched: {2}" -f $target.Label, $hits.Count, $names)
    }

    $entry = $hits[0]
    if ($null -eq $entry.Identifier) {
        throw ("Entry {0} '{1}' has no identifier; refusing to guess." -f $entry.Header, $entry.Description)
    }
    if (($entry.Identifier -replace '[{}]', '').ToLowerInvariant() -eq $script:VendorGuid) {
        throw ("Refusing to switch to '{0}': its identifier is the shared UEFI vendor GUID {1}, which bcdedit accepts and silently ignores." -f $entry.Description, $script:VendorGuid)
    }
    return $entry
}

<#
    Sets the one-shot override, then reads it back.

    bootsequence is the only order element bcdedit will actually write on this
    machine: /set {fwbootmgr} displayorder fails with "The entry list data is not
    valid as specified." So the override is written there and verified there.

    Verification reads bcdedit back out of the store, never out of the request,
    so a write that silently did nothing is caught before anything reboots.
#>
function Set-Override {
    param([string] $Identifier)

    Invoke-Bcd -BcdArgs @('/set', '{fwbootmgr}', 'bootsequence', $Identifier) | Out-Null

    $after = Get-CurrentBoot
    $now = @($after.Override)
    if ($now.Count -ne 1 -or $now[0] -ne $Identifier) {
        throw ("Verification failed: bootsequence is '{0}', expected '{1}'." -f ($now -join ','), $Identifier)
    }
    return $after
}

function Clear-Override {
    param([string[]] $Previous)

    Invoke-Bcd -BcdArgs @('/deletevalue', '{fwbootmgr}', 'bootsequence') | Out-Null

    $after = Get-CurrentBoot
    $now = @($after.Override)
    if ($Previous -and $Previous.Count -gt 0) {
        if ($now.Count -eq 0 -or $now[0] -ne $Previous[0]) {
            throw ("Verification failed: expected the previous override '{0}', found '{1}'." -f ($Previous -join ','), ($now -join ','))
        }
    }
    elseif ($now.Count -ne 0) {
        throw ("Verification failed: expected no override, found '{0}'." -f ($now -join ','))
    }
    return $after
}

function Get-DefaultStatePath {
    if ($PSScriptRoot) { return (Join-Path $PSScriptRoot '.osswitch-state.json') }
    return (Join-Path ([IO.Path]::GetTempPath()) '.osswitch-state.json')
}

function Save-PreviousOverride {
    param([string] $Path, $Boot)

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $record = [pscustomobject]@{
        savedAt  = (Get-Date).ToString('o')
        override = @($Boot.Override)
    }
    $record | ConvertTo-Json -Depth 5 | Set-Content -Path $Path -Encoding UTF8
}

function Get-HibernateNote {
    try {
        $out = & powercfg.exe /a 2>&1 | Out-String
        if ($out -match '(?im)^\s*Hibernation\s+is not available') {
            return 'Hibernate is already off, so Manjaro can mount the Windows NTFS partition.'
        }
        if ($out -match '(?im)^\s*Hibernate') {
            return 'Hibernate is ON. Run "powercfg /h off" before letting Manjaro write to the Windows partition, or Linux will see a hibernated volume.'
        }
    }
    catch {
        return 'Could not read powercfg; check hibernation yourself with "powercfg /a".'
    }
    return 'Could not read powercfg; check hibernation yourself with "powercfg /a".'
}

function Invoke-Reboot {
    param([string] $Note)
    $out = & $ShutdownPath '/r' '/t' '0' '/c' $Note 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw ("reboot request failed with exit code {0}: {1}" -f $LASTEXITCODE, $out.Trim())
    }
}

function Show-Entries {
    param($Boot)

    # With no override pending, the firmware's own order decides. With one, that
    # entry wins for the next boot.
    $sequence = @($Boot.FirmwareOrder)
    $pending = $false
    if (@($Boot.Override).Count -gt 0) {
        $sequence = @($Boot.Override) + @($Boot.FirmwareOrder | Where-Object { $_ -notin $Boot.Override })
        $pending = $true
    }

    Write-Line 'Firmware boot entries:'
    foreach ($entry in $Boot.Entries) {
        $pos = [array]::IndexOf($sequence, $entry.Identifier)
        if ($pos -ge 0) {
            $mark = if ($pos -eq 0) { '>' } else { ' ' }
            $rank = if ($pending -and $pos -eq 0) { '#1 (one-shot override)' } else { '#{0}' -f ($pos + 1) }
        }
        else {
            $mark = ' '
            $rank = 'not in boot order'
        }
        Write-Line ("  {0} {1,-30} {2}" -f $mark, $entry.Description, $rank)
        if ($entry.Path) { Write-Line ("      {0}" -f $entry.Path) }
    }
    if ($sequence.Count -gt 0) {
        $first = $sequence[0]
        $hit = @($Boot.Entries | Where-Object { $_.Identifier -eq $first })
        $name = if ($hit.Count -eq 1) { $hit[0].Description } else { '(unknown entry)' }
        Write-Line ("Boots next: {0}" -f $name)
    }
}

function Show-Status {
    $boot = Get-CurrentBoot
    Write-Line 'osswitch - Windows half'
    Write-Line ("Elevated: {0}" -f (Test-Elevated))
    Write-Line ''
    Show-Entries -Boot $boot
    Write-Line ''
    if (@($boot.Override).Count -gt 0) {
        Write-Line 'A one-shot override is pending. Clear it with: osswitch restore'
        Write-Line ''
    }
    Write-Line (Get-HibernateNote)
    Write-Line ''
    Write-Line 'To switch:  osswitch windows    osswitch manjaro    (add -DryRun first)'
}

function Invoke-Switch {
    param([string] $Key)

    $target = $script:Targets[$Key]
    if (-not (Test-Elevated)) {
        throw ("Changing the boot order needs an elevated PowerShell. Start one with 'Run as administrator' and run: osswitch {0}" -f $Key)
    }

    $boot = Get-CurrentBoot
    Show-Entries -Boot $boot
    Write-Line ''

    $entry = Resolve-TargetEntry -Entries $boot.Entries -Key $Key
    $already = (@($boot.Override).Count -gt 0 -and @($boot.Override)[0] -eq $entry.Identifier)
    $isFirst = (@($boot.FirmwareOrder).Count -gt 0 -and @($boot.FirmwareOrder)[0] -eq $entry.Identifier)

    if (($already -or $isFirst) -and -not $Force) {
        Write-Line ("Already set to {0} ({1}). Nothing to do." -f $target.Label, $entry.Description)
        return
    }

    Write-Line ("Switching to {0}: {1} -> {2}" -f $target.Label, $entry.Description, $entry.Identifier)

    $state = if ($StatePath) { $StatePath } else { Get-DefaultStatePath }
    Save-PreviousOverride -Path $state -Boot $boot

    $after = Set-Override -Identifier $entry.Identifier
    Write-Line 'Verified: the one-shot override is set and reads back correctly.'
    Show-Entries -Boot $after

    if ($DryRun) {
        Write-Line ''
        Write-Line 'Dry run: override applied and verified, reboot NOT scheduled.'
        Write-Line ("Undo with: oswitch restore   (or just reboot - the override is consumed once)")
        return
    }

    Write-Line ''
    Write-Line ("Rebooting into {0}." -f $target.Label)
    Invoke-Reboot -Note ("osswitch: booting {0}" -f $target.Label)
}

function Invoke-Restore {
    if (-not (Test-Elevated)) {
        throw 'Restoring the boot order needs an elevated PowerShell.'
    }
    $state = if ($StatePath) { $StatePath } else { Get-DefaultStatePath }
    if (-not (Test-Path $state)) {
        # Nothing remembered: clearing any pending override is still the right move.
        $boot = Get-CurrentBoot
        if (@($boot.Override).Count -eq 0) {
            throw ("No saved override at {0} and none is pending; there is nothing to restore." -f $state)
        }
        $previous = @()
    }
    else {
        $saved = Get-Content -Path $state -Raw | ConvertFrom-Json
        $previous = @($saved.override)
        Write-Line ("Clearing the override saved at {0}" -f $saved.savedAt)
    }

    $after = Clear-Override -Previous $previous
    Write-Line 'Verified: the machine is back to its own firmware boot order.'
    Show-Entries -Boot $after

    if ($DryRun) {
        Write-Line 'Dry run: override cleared and verified, reboot NOT scheduled.'
    }
    else {
        Write-Line ''
        Write-Host 'Rebooting into the firmware default order.'
        Invoke-Reboot -Note 'osswitch: clearing the one-shot boot override'
    }
}

try {
    switch ($Action) {
        'status'  { Show-Status }
        'list'    { Show-Entries -Boot (Get-CurrentBoot) }
        'restore' { Invoke-Restore }
        default   { Invoke-Switch -Key $Action }
    }
}
catch {
    Write-Output ("osswitch: {0}" -f $_.Exception.Message)
    # Set OSSWITCH_DEBUG=1 to see where it failed; the message alone hides the line.
    if ($env:OSSWITCH_DEBUG -eq '1') {
        Write-Output ("  at {0}" -f $_.InvocationInfo.PositionMessage)
        Write-Output $_.ScriptStackTrace
    }
    exit 1
}

exit 0