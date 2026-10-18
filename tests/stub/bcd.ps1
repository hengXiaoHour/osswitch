<#
    Stub bcdedit for the osswitch test suite.

    Emulates the two calls osswitch makes:
      bcdedit /enum {fwbootmgr}
      bcdedit /set {fwbootmgr} bootsequence <guid>[,<guid>...]

    State lives in %OSSWITCH_STUB_DIR%\state.json and every call is appended to
    bcd.log, so tests can prove what was written and, just as importantly, what
    was not.

    Fault injection:
      OSSWITCH_STUB_IGNORE_SET=1  accept /set but do not persist it
      OSSWITCH_STUB_GARBAGE=1      /enum fails like an unreadable boot store

    Deliberately no param block: powershell.exe -File passes /enum through as a
    plain argument, and a named parameter would try to bind it as a parameter name.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$BcdArgs = @($args)
$dir = $env:OSSWITCH_STUB_DIR
if (-not $dir) { Write-Output 'stub: OSSWITCH_STUB_DIR not set'; exit 1 }

$statePath = Join-Path $dir 'state.json'
$logPath = Join-Path $dir 'bcd.log'
$state = Get-Content -Path $statePath -Raw | ConvertFrom-Json

Add-Content -Path $logPath -Value ($BcdArgs -join ' ')

function Write-Enum {
    $out = New-Object System.Collections.Generic.List[string]
    $order = @($state.order)

    if ($state.style -eq 'classic') {
        # Older shape: Boot#### objects and a bootsequence key.
        $out.Add('Firmware Boot Manager')
        $out.Add('---------------------')
        $out.Add('identifier              {fwbootmgr}')
        $out.Add('bootsequence            ' + ($order -join ','))
        $out.Add('timeout                 5')
        $out.Add('')
        foreach ($e in $state.entries) {
            $out.Add(('{0,-24}{1}' -f $e.name, $e.description))
            $out.Add('------------------------')
            $out.Add('identifier              ' + $e.id)
            $out.Add('device                  ' + $e.device)
            $out.Add('description             ' + $e.description)
            $out.Add('')
        }
        Write-Output (($out -join "`r`n") + "`r`n")
        return
    }

    # This is what the real machine emits: no Boot#### objects, the order lives
    # in displayorder, and long lists wrap onto indented continuation lines.
    $out.Add('Firmware Boot Manager')
    $out.Add('---------------------')
    $out.Add('identifier              {fwbootmgr}')
    $out.Add(('displayorder            {0}' -f $order[0]))
    for ($i = 1; $i -lt $order.Count; $i++) { $out.Add(('                        {0}' -f $order[$i])) }
    $out.Add('timeout                 0')
    $override = @()
    if ($state.PSObject.Properties.Name -contains 'override') { $override = @($state.override) }
    if ($override.Count -gt 0) { $out.Add('bootsequence            ' + ($override -join ',')) }
    $out.Add('')
    foreach ($e in $state.entries) {
        $header = 'Firmware Application (101fffff)'
        if ($e.PSObject.Properties.Name -contains 'header' -and $e.header) { $header = $e.header }
        $out.Add($header)
        $out.Add(('-' * $header.Length))
        $out.Add('identifier              ' + $e.id)
        if ($e.device) { $out.Add('device                  ' + $e.device) }
        if ($e.path)   { $out.Add('path                    ' + $e.path) }
        $out.Add('description             ' + $e.description)
        $out.Add('')
    }
    Write-Output (($out -join "`r`n") + "`r`n")
}

if ($BcdArgs.Count -eq 0) { Write-Output 'stub: no arguments'; exit 1 }

if ($BcdArgs[0] -eq '/enum') {
    if ($env:OSSWITCH_STUB_GARBAGE -eq '1') {
        Write-Output 'An error occurred while attempting to open the boot configuration data store.'
        exit 1
    }
    # Replay real bcdedit output captured from this machine, so the parser is
    # exercised against the genuine shape rather than only what we assumed.
    if ($env:OSSWITCH_STUB_FIXTURE) {
        if (-not (Test-Path $env:OSSWITCH_STUB_FIXTURE)) {
            Write-Output ('stub: fixture not found: ' + $env:OSSWITCH_STUB_FIXTURE)
            exit 1
        }
        Write-Output (Get-Content -Path $env:OSSWITCH_STUB_FIXTURE -Raw)
        exit 0
    }
    Write-Enum
    exit 0
}

if ($BcdArgs[0] -eq '/deletevalue') {
    if ($BcdArgs.Count -ne 3 -or $BcdArgs[1] -ne '{fwbootmgr}' -or $BcdArgs[2] -ne 'bootsequence') {
        Write-Output 'stub: unsupported /deletevalue form'
        exit 1
    }
    if ($env:OSSWITCH_STUB_IGNORE_SET -ne '1') {
        $state.override = @()
        $state | ConvertTo-Json -Depth 6 | Set-Content -Path $statePath -Encoding UTF8
    }
    Write-Output 'The operation completed successfully.'
    exit 0
}

if ($BcdArgs[0] -eq '/set') {
    # Real bcdedit refuses /set {fwbootmgr} displayorder with
    # "The entry list data is not valid as specified." on this machine, so the
    # stub refuses it too instead of pretending every element is writable.
    if ($BcdArgs.Count -ne 4 -or $BcdArgs[1] -ne '{fwbootmgr}') {
        Write-Output 'stub: unsupported /set form'
        exit 1
    }
    $key = $BcdArgs[2]
    if ($key -eq 'displayorder') {
        Write-Output 'The entry list data is not valid as specified.'
        exit 1
    }
    if ($key -ne 'bootsequence') {
        Write-Output 'stub: unsupported element ' + $key
        exit 1
    }

    $requested = @($BcdArgs[3] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    $known = @($state.entries | ForEach-Object { $_.id })
    if ('{bootmgr}' -notin $known) { $known += '{bootmgr}' }
    foreach ($id in $requested) {
        if ($known -notcontains $id) {
            Write-Output ("The boot entry with identifier {0} could not be found." -f $id)
            exit 1
        }
    }
    if ($env:OSSWITCH_STUB_IGNORE_SET -ne '1') {
        $state.override = $requested
        $state | ConvertTo-Json -Depth 6 | Set-Content -Path $statePath -Encoding UTF8
    }
    Write-Output 'The operation completed successfully.'
    exit 0
}

Write-Output ('stub: unknown command ' + $BcdArgs[0])
exit 1