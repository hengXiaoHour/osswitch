<#
    Probe what bcdedit will actually do on this machine's firmware boot manager.

    Ends by putting the machine back exactly as it was found: the original
    displayorder is re-applied and any bootsequence element created during the
    probe is deleted.
#>
$LogPath = Join-Path $env:TEMP 'opencode\osswitch-probe.log'
New-Item -ItemType Directory -Path (Split-Path -Parent $LogPath) -Force | Out-Null
Start-Transcript -Path $LogPath -Force | Out-Null

$MANJARO = '{dc32beeb-ca95-11f1-8cd8-806e6f6e6963}'
$BOOTMGR = '{bootmgr}'
$PM9A1 = '{aeccae1b-c6df-11f1-b787-a5e08443f1ab}'
$HTTPS = '{aeccae17-c6df-11f1-b787-a5e08443f1ab}'
$ORIGINAL = "$MANJARO,$BOOTMGR,$PM9A1,$HTTPS"

function Show-Order {
    param([string] $Label)
    $txt = bcdedit /enum '{fwbootmgr}' 2>&1 | Out-String
    $seq = ($txt -split "`r?`n" | Where-Object { $_ -match '^\s*(displayorder|bootsequence)\s' }) -join ' | '
    Write-Host ("  [{0}] {1}" -f $Label, $seq.Trim())
}

function Try-Set {
    param([string] $Element, [string] $Value)
    Write-Host ''
    Write-Host ("--- bcdedit /set {{fwbootmgr}} {0} {1}" -f $Element, $Value)
    $out = bcdedit /set '{fwbootmgr}' $Element $Value 2>&1 | Out-String
    Write-Host ("    exit={0} output: {1}" -f $LASTEXITCODE, $out.Trim())
    Show-Order -Label "after $Element"
}

Write-Host 'PROBE: what can bcdedit actually write here?'
Write-Host ''
Write-Host 'original displayorder:'
Show-Order -Label 'start'

Write-Host ''
Write-Host '=== probe 1: write displayorder ==='
Try-Set -Element 'displayorder' -Value "$BOOTMGR,$MANJARO,$PM9A1,$HTTPS"

Write-Host ''
Write-Host '=== probe 2: write bootsequence ==='
Try-Set -Element 'bootsequence' -Value $BOOTMGR

Write-Host ''
Write-Host '=== probe 3: does bootsequence persist across a re-enum? ==='
Show-Order -Label 're-read'

Write-Host ''
Write-Host '=== cleanup: delete the bootsequence value we created ==='
$out = bcdedit /deletevalue '{fwbootmgr}' bootsequence 2>&1 | Out-String
Write-Host ("    exit={0} output: {1}" -f $LASTEXITCODE, $out.Trim())
Show-Order -Label 'after delete bootsequence'

Write-Host ''
Write-Host '=== cleanup: restore the original displayorder ==='
$out = bcdedit /set '{fwbootmgr}' displayorder $ORIGINAL 2>&1 | Out-String
Write-Host ("    exit={0} output: {1}" -f $LASTEXITCODE, $out.Trim())
Show-Order -Label 'final'

Write-Host ''
Write-Host '--- full final firmware enum ---'
bcdedit /enum firmware

Stop-Transcript | Out-Null
Write-Host ("probe transcript: " + $LogPath)