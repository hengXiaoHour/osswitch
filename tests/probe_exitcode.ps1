$LogPath = Join-Path $env:TEMP 'opencode\osswitch-exitcode.log'
New-Item -ItemType Directory -Path (Split-Path -Parent $LogPath) -Force | Out-Null
Start-Transcript -Path $LogPath -Force | Out-Null

$MANJARO = '{dc32beeb-ca95-11f1-8cd8-806e6f6e6963}'
$BOOTMGR = '{bootmgr}'
$PM9A1 = '{aeccae1b-c6df-11f1-b787-a5e08443f1ab}'
$HTTPS = '{aeccae17-c6df-11f1-b787-a5e08443f1ab}'
$list = "$BOOTMGR,$MANJARO,$PM9A1,$HTTPS"

Write-Host '=== replicate the script call exactly, via the call operator ==='
$out = & 'bcdedit' @('/set', '{fwbootmgr}', 'displayorder', $list) 2>&1
$code = $LASTEXITCODE
Write-Host ("  LASTEXITCODE = [{0}]" -f $code)
Write-Host ("  is null      = {0}" -f ($null -eq $code))
Write-Host ("  -ne 0        = {0}" -f ($code -ne 0))
Write-Host ("  output: {0}" -f (($out | Out-String).Trim()))

Write-Host ''
Write-Host '=== same call, but piped (what the script actually does) ==='
$out2 = & 'bcdedit' @('/set', '{fwbootmgr}', 'displayorder', $list) 2>&1 | Out-String
$code2 = $LASTEXITCODE
Write-Host ("  LASTEXITCODE = [{0}]  -ne 0 = {1}" -f $code2, ($code2 -ne 0))
Write-Host ("  output: {0}" -f $out2.Trim())

Write-Host ''
Write-Host '=== confirm nothing changed ==='
bcdedit /enum '{fwbootmgr}' 2>&1 | Out-String

Stop-Transcript | Out-Null
Write-Host 'exitcode probe done'