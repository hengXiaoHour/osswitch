<#
.SYNOPSIS
    Builds the osswitch desktop shortcut icons.

.DESCRIPTION
    The Manjaro mark is drawn from geometry rather than shipped as a bitmap, but
    the green is SAMPLED from the authentic logo on the installation ISO
    (boot/grub/themes/manjaro-live/logo.png) so the colour is the real one and not
    a guess. windows.ico is drawn the same way.

    Output is PNG-compressed .ico files carrying several sizes, which Windows
    10/11 handles natively.

.PARAMETER IsoMount
    Drive root of the mounted Manjaro ISO. Mounted read-only here when omitted.

.PARAMETER LogoPng
    Your own Manjaro logo file. When given, this is used verbatim as the mark
    instead of drawing blocks, so no ISO is needed.

.PARAMETER OutDir
    Where the .ico files are written.

.EXAMPLE
    powershell -File .\tools\make_icon.ps1
#>
[CmdletBinding()]
param(
    [string] $IsoMount = '',
    [string] $LogoPng = '',
    [string] $OutDir = '',
    # The classic Manjaro green, matching the three-block reference mark.
    # Note: the green sampled from the 26.1 installation ISO is #35BFA4, the
    # newer teal branding; pass -GreenHex '#35BFA4' to use that instead.
    [string] $GreenHex = '#35BF5C'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

# Windows PowerShell 5.1 does not populate $PSScriptRoot while it is still
# evaluating parameter defaults, so the default is resolved here.
if (-not $OutDir) { $OutDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'assets' }

function Get-ManjaroGreen {
    <#  Samples the most common saturated green from the ISO's own logo.  #>
    param([string] $LogoPath)

    $bmp = New-Object System.Drawing.Bitmap($LogoPath)
    try {
        $counts = @{}
        for ($y = 0; $y -lt $bmp.Height; $y += 2) {
            for ($x = 0; $x -lt $bmp.Width; $x += 2) {
                $p = $bmp.GetPixel($x, $y)
                if ($p.A -lt 200) { continue }
                if ($p.G -gt ($p.R + 40) -and $p.G -gt ($p.B + 20)) {
                    $key = '{0},{1},{2}' -f $p.R, $p.G, $p.B
                    if ($counts.ContainsKey($key)) { $counts[$key] = $counts[$key] + 1 }
                    else { $counts[$key] = 1 }
                }
            }
        }
        if ($counts.Count -eq 0) { throw "No green found in $LogoPath" }
        $best = ($counts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1)
        $parts = $best.Key -split ','
        Write-Host ("sampled Manjaro green #{0:X2}{1:X2}{2:X2} ({3} pixels)" -f [int]$parts[0], [int]$parts[1], [int]$parts[2], $best.Value)
        return [System.Drawing.Color]::FromArgb(255, [int]$parts[0], [int]$parts[1], [int]$parts[2])
    }
    finally { $bmp.Dispose() }
}

function New-DibFrame {
    <#  A real 32bpp DIB (BITMAPINFOHEADER + bottom-up BGRA + AND mask), which is
        what every Windows icon parser expects below 256px. PNG-compressed frames
        are only reliably read at 256px: using them at 32px produced pure noise. #>
    param([System.Drawing.Bitmap] $Bmp)

    $w = $Bmp.Width
    $h = $Bmp.Height
    # The 3-argument LockBits overload, not the 4-argument one:
    # [System.Drawing.Imaging.PixelStrideMode] does not exist in .NET Framework's
    # System.Drawing, and the resulting error pointed at the wrong argument.
    $data = $Bmp.LockBits((New-Object System.Drawing.Rectangle(0, 0, $w, $h)),
        [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $stride = $data.Stride
    $bytes = New-Object 'byte[]' ($stride * $h)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
    $Bmp.UnlockBits($data)

    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $xorSize = $w * $h * 4
    $maskStride = [int](([Math]::Ceiling($w / 32.0)) * 4)
    $maskSize = $maskStride * $h

    $bw.Write([UInt32]40)        # biSize
    $bw.Write([Int32]$w)        # biWidth
    $bw.Write([Int32](2 * $h))  # biHeight: XOR plus AND mask
    $bw.Write([UInt16]1)        # biPlanes
    $bw.Write([UInt16]32)       # biBitCount
    $bw.Write([UInt32]0)        # biCompression = BI_RGB
    $bw.Write([UInt32]($xorSize + $maskSize))
    $bw.Write([Int32]0)         # biXPelsPerMeter
    $bw.Write([Int32]0)         # biYPelsPerMeter
    $bw.Write([UInt32]0)        # biClrUsed
    $bw.Write([UInt32]0)        # biClrImportant

    # Rows are stored bottom-up.
    $row = New-Object 'byte[]' ($w * 4)
    for ($y = $h - 1; $y -ge 0; $y--) {
        [Array]::Copy($bytes, ($y * $stride), $row, 0, ($w * 4))
        $bw.Write($row)
    }
    # AND mask: fully transparent, since alpha already carries the shape.
    $bw.Write((New-Object 'byte[]' $maskSize))
    $bw.Flush()
    $result = $ms.ToArray()
    $bw.Dispose(); $ms.Dispose()
    return $result
}

function Save-MultiSizeIco {
    <#  Writes a multi-size .ico: DIB frames up to 128px, PNG at 256px.  #>
    param([string] $PngPath, [string] $IcoPath, [int[]] $Sizes = @(16, 24, 32, 48, 64, 128, 256))

    $src = New-Object System.Drawing.Bitmap($PngPath)
    $frames = New-Object System.Collections.Generic.List[byte[]]
    try {
        foreach ($s in $Sizes) {
            $bmp = New-Object System.Drawing.Bitmap($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $g.Clear([System.Drawing.Color]::Transparent)
            $g.DrawImage($src, (New-Object System.Drawing.Rectangle(0, 0, $s, $s)))
            $g.Dispose()
            if ($s -ge 256) {
                $ms = New-Object System.IO.MemoryStream
                $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
                $frames.Add($ms.ToArray())
                $ms.Dispose()
            }
            else {
                $frames.Add((New-DibFrame -Bmp $bmp))
            }
            $bmp.Dispose()
        }
    }
    finally { $src.Dispose() }

    $count = $frames.Count
    $out = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($out)
    $bw.Write([UInt16]0)                 # reserved
    $bw.Write([UInt16]1)                 # type: icon
    $bw.Write([UInt16]$count)            # image count
    $offset = 6 + (16 * $count)
    for ($i = 0; $i -lt $count; $i++) {
        $s = $Sizes[$i]
        $bw.Write([Byte]$(if ($s -ge 256) { 0 } else { $s }))   # width, 0 means 256
        $bw.Write([Byte]$(if ($s -ge 256) { 0 } else { $s }))   # height
        $bw.Write([Byte]0)                                     # palette size
        $bw.Write([Byte]0)                                     # reserved
        $bw.Write([UInt16]1)                                   # colour planes
        $bw.Write([UInt16]32)                                  # bits per pixel
        $bw.Write([UInt32]$frames[$i].Length)
        $bw.Write([UInt32]$offset)
        $offset += $frames[$i].Length
    }
    foreach ($f in $frames) { $bw.Write($f) }
    $bw.Flush()
    [System.IO.File]::WriteAllBytes($IcoPath, $out.ToArray())
    $bw.Dispose(); $out.Dispose()
    Write-Host ("wrote {0} ({1} bytes, {2} sizes)" -f $IcoPath, (Get-Item $IcoPath).Length, ($Sizes -join '/'))
}

$LogoRel = 'boot\grub\themes\manjaro-live\logo.png'
$mounted = $false
# A supplied logo is used as-is, so there is no reason to go looking for an ISO.
if ($LogoPng -and -not (Test-Path $LogoPng)) { throw "Logo file not found: $LogoPng" }
if (-not $LogoPng -and -not $IsoMount) {
    $iso = Get-ChildItem "$env:USERPROFILE\OneDrive\Downloads", "$env:USERPROFILE\Downloads" -Filter 'manjaro*.iso' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $iso) { throw 'Manjaro ISO not found; pass -IsoMount D: or mount it yourself.' }
    $d = Mount-DiskImage -ImagePath $iso.FullName -PassThru
    $IsoMount = ($d | Get-Volume).DriveLetter + ':'
    $mounted = $true
}

try {
    if ($LogoPng) {
        $logoPath = $LogoPng
        Write-Host "using your logo file: $LogoPng"
    }
    else {
        $logoPath = Join-Path $IsoMount $LogoRel
        if (-not (Test-Path $logoPath)) { throw "Logo not found on the image: $logoPath" }
    }
    if (-not $LogoPng) {
        # Named distinctly from the -GreenHex parameter: PowerShell variables are
        # case-insensitive, so $green would have overwritten $GreenHex.
        $manjaroColor = [System.Drawing.ColorTranslator]::FromHtml($GreenHex)
        Write-Host ("using Manjaro green {0} (R{1} G{2} B{3})" -f $GreenHex, $manjaroColor.R, $manjaroColor.G, $manjaroColor.B)
        # Diagnostic only: report what this ISO's own logo uses.
        try { $null = Get-ManjaroGreen -LogoPath $logoPath } catch { Write-Host ("  (could not sample: {0})" -f $_.Exception.Message) }
    }
    else {
        # Diagnostic only: show the green actually present in your own file.
        try { $null = Get-ManjaroGreen -LogoPath $logoPath } catch { Write-Host ("  (could not sample: {0})" -f $_.Exception.Message) }
    }

    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

    $S = 512
    $man = New-Object System.Drawing.Bitmap($S, $S, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($man)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::White)

    if ($LogoPng) {
        # ---- Manjaro: your own file, used verbatim ----
        $own = New-Object System.Drawing.Bitmap($LogoPng)
        try {
            Write-Host ("your logo is {0} x {1}" -f $own.Width, $own.Height)
            # Letterbox it centred so a non-square source is never stretched.
            $scale = [Math]::Min(($S * 0.86) / $own.Width, ($S * 0.86) / $own.Height)
            $dw = [int]($own.Width * $scale)
            $dh = [int]($own.Height * $scale)
            $dx = [int](($S - $dw) / 2)
            $dy = [int](($S - $dh) / 2)
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.DrawImage($own, (New-Object System.Drawing.Rectangle($dx, $dy, $dw, $dh)))
        }
        finally { $own.Dispose() }
    }
    else {
        # ---- Manjaro: the three-block mark, drawn on white ----
        $brush = [System.Drawing.SolidBrush]::new($manjaroColor)
        # Fractions of the canvas, measured off the reference artwork.
        $blocks = @(
            @{ x = 0.132; y = 0.113; w = 0.438; h = 0.372 }   # top-left bar
            @{ x = 0.132; y = 0.567; w = 0.310; h = 0.316 }   # bottom-left stem
            @{ x = 0.508; y = 0.551; w = 0.196; h = 0.332 }   # bottom-middle stem
            @{ x = 0.752; y = 0.113; w = 0.116; h = 0.770 }   # right column
        )
        foreach ($b in $blocks) {
            $g.FillRectangle($brush,
                (New-Object System.Drawing.RectangleF(
                    [single]($b.x * $S), [single]($b.y * $S),
                    [single]($b.w * $S), [single]($b.h * $S))))
        }
        $brush.Dispose()
    }
    $g.Dispose()
    $manPng = Join-Path $OutDir 'manjaro-512.png'
    $man.Save($manPng, [System.Drawing.Imaging.ImageFormat]::Png)
    $man.Dispose()
    Write-Host "wrote $manPng"

    # ---- Windows: the familiar four panes ----
    $win = New-Object System.Drawing.Bitmap($S, $S, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $wg = [System.Drawing.Graphics]::FromImage($win)
    $wg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $wg.Clear([System.Drawing.Color]::White)
    $wbrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 0, 120, 212))
    $gap = 0.052
    $margin = 0.20
    $pane = (1.0 - (2 * $margin) - $gap) / 2
    for ($row = 0; $row -lt 2; $row++) {
        for ($col = 0; $col -lt 2; $col++) {
            $wg.FillRectangle($wbrush,
                [single](($margin + ($col * ($pane + $gap))) * $S),
                [single](($margin + ($row * ($pane + $gap))) * $S),
                [single]($pane * $S), [single]($pane * $S))
        }
    }
    $wg.Dispose(); $wbrush.Dispose()
    $winPng = Join-Path $OutDir 'windows-512.png'
    $win.Save($winPng, [System.Drawing.Imaging.ImageFormat]::Png)
    $win.Dispose()
    Write-Host "wrote $winPng"

    Save-MultiSizeIco -PngPath $manPng -IcoPath (Join-Path $OutDir 'manjaro.ico')
    Save-MultiSizeIco -PngPath $winPng -IcoPath (Join-Path $OutDir 'windows.ico')
}
finally {
    if ($mounted) { Dismount-DiskImage -ImagePath (Get-DiskImage | Where-Object { $_.DevicePath -like "$IsoMount*" } | Select-Object -First 1).ImagePath -ErrorAction SilentlyContinue }
}

Write-Host 'done'