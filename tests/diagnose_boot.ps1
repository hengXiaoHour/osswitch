$ErrorActionPreference = 'Continue'
$LogPath = Join-Path $env:TEMP 'opencode\osswitch-diag.log'
New-Item -ItemType Directory -Path (Split-Path -Parent $LogPath) -Force | Out-Null
Start-Transcript -Path $LogPath -Force | Out-Null

$script = Join-Path (Split-Path -Parent $PSScriptRoot) 'osswitch.ps1'

function Section { param([string] $T) Write-Host ''; Write-Host ('#' * 72); Write-Host "## $T"; Write-Host ('#' * 72) }

Section 'elevation'
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
Write-Host ("elevated: " + (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))

Section 'bcdedit /enum firmware'
bcdedit /enum firmware

Section 'bcdedit /enum all  (Boot#### firmware entries only)'
$all = bcdedit /enum all 2>&1 | Out-String
($all -split "`r?`n") | Select-String -Pattern '^Boot[0-9A-Fa-f]{4}\s|^\s+identifier|^\s+description|^\s+device' | ForEach-Object { $_.Line }

Section 'ESP contents (200MB system partition)'
$sys = Get-Partition -DiskNumber 0 -PartitionNumber 1
Write-Host ("current access paths: " + (($sys.AccessPaths) -join ', '))
if (-not ($sys.AccessPaths | Where-Object { $_ -match '^[A-Z]:\\$' })) {
    Add-PartitionAccessPath -DiskNumber 0 -PartitionNumber 1 -AccessPath 'S:'
    Write-Host 'assigned S: to the ESP'
}
if (Test-Path 'S:\') {
    Write-Host '--- EFI ---'
    Get-ChildItem 'S:\EFI' -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host ("  EFI\" + $_.Name)
        Get-ChildItem $_.FullName -File -ErrorAction SilentlyContinue | ForEach-Object { Write-Host ("      " + $_.Name) }
    }
    Write-Host '--- S:\EFI\Boot ---'
    Get-ChildItem 'S:\EFI\Boot' -File -ErrorAction SilentlyContinue | ForEach-Object { Write-Host ("      " + $_.Name) }
    Remove-PartitionAccessPath -DiskNumber 0 -PartitionNumber 1 -AccessPath 'S:\' -ErrorAction SilentlyContinue
    Write-Host 'removed S: again (left the machine as found)'
}

Section 'osswitch status'
& $script @{ Action = 'status' }
Write-Host ("[exit {0}]" -f $LASTEXITCODE)

Section 'osswitch list'
& $script @{ Action = 'list' }
Write-Host ("[exit {0}]" -f $LASTEXITCODE)

Section 'osswitch manjaro -DryRun   (expected to be REFUSED: no Manjaro entry)'
& $script @{ Action = 'manjaro'; DryRun = $true }
Write-Host ("[exit {0}]" -f $LASTEXITCODE)

Section 'osswitch windows -DryRun'
& $script @{ Action = 'windows'; DryRun = $true }
Write-Host ("[exit {0}]" -f $LASTEXITCODE)

Section 'hibernation'
powercfg /a

Stop-Transcript | Out-Null
Write-Host 'diagnostic finished'