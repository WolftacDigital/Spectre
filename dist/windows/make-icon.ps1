# Generates spectre.ico - a dark rounded square with a lavender prompt
# chevron and a mauve cursor block. Pure GDI+, no external tooling.
# Run: powershell -ExecutionPolicy Bypass -File make-icon.ps1
param([string]$OutPath = (Join-Path $PSScriptRoot 'spectre.ico'))

Add-Type -AssemblyName System.Drawing

function New-SpectreFrame([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    # Rounded-square background (catppuccin mocha base #1E1E2E)
    $bg = [System.Drawing.Color]::FromArgb(255, 0x1E, 0x1E, 0x2E)
    $radius = [Math]::Max(2, [int]($size * 0.22))
    $rect = New-Object System.Drawing.Rectangle 0, 0, ($size - 1), ($size - 1)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $radius * 2
    $path.AddArc($rect.X, $rect.Y, $d, $d, 180, 90)
    $path.AddArc($rect.Right - $d, $rect.Y, $d, $d, 270, 90)
    $path.AddArc($rect.Right - $d, $rect.Bottom - $d, $d, $d, 0, 90)
    $path.AddArc($rect.X, $rect.Bottom - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $brush = New-Object System.Drawing.SolidBrush $bg
    $g.FillPath($brush, $path)

    # Prompt chevron '>' (lavender #B4BEFE)
    $lavender = [System.Drawing.Color]::FromArgb(255, 0xB4, 0xBE, 0xFE)
    $penW = [Math]::Max(1.5, $size * 0.10)
    $pen = New-Object System.Drawing.Pen $lavender, $penW
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $pts = @(
        (New-Object System.Drawing.PointF ($size * 0.26), ($size * 0.30)),
        (New-Object System.Drawing.PointF ($size * 0.48), ($size * 0.50)),
        (New-Object System.Drawing.PointF ($size * 0.26), ($size * 0.70))
    )
    $g.DrawLines($pen, $pts)

    # Cursor block (mauve #CBA6F7)
    $mauve = [System.Drawing.Color]::FromArgb(255, 0xCB, 0xA6, 0xF7)
    $cb = New-Object System.Drawing.SolidBrush $mauve
    $cw = $size * 0.22; $ch = [Math]::Max(1.5, $size * 0.085)
    $g.FillRectangle($cb, [single]($size * 0.55), [single]($size * 0.625), [single]$cw, [single]$ch)

    $g.Dispose()
    return $bmp
}

$sizes = 256, 64, 48, 32, 24, 16
$frames = foreach ($s in $sizes) {
    $bmp = New-SpectreFrame $s
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    [pscustomobject]@{ Size = $s; Bytes = $ms.ToArray() }
}

# Assemble ICO: ICONDIR + ICONDIRENTRY[] + PNG payloads (PNG-in-ICO is
# valid for Vista+).
$out = New-Object System.IO.MemoryStream
$w = New-Object System.IO.BinaryWriter $out
$w.Write([uint16]0)            # reserved
$w.Write([uint16]1)            # type: icon
$w.Write([uint16]$frames.Count)
$offset = 6 + 16 * $frames.Count
foreach ($f in $frames) {
    $dim = if ($f.Size -ge 256) { 0 } else { $f.Size }
    $w.Write([byte]$dim)       # width
    $w.Write([byte]$dim)       # height
    $w.Write([byte]0)          # color count
    $w.Write([byte]0)          # reserved
    $w.Write([uint16]1)        # planes
    $w.Write([uint16]32)       # bit count
    $w.Write([uint32]$f.Bytes.Length)
    $w.Write([uint32]$offset)
    $offset += $f.Bytes.Length
}
foreach ($f in $frames) { $w.Write($f.Bytes) }
$w.Flush()
[System.IO.File]::WriteAllBytes($OutPath, $out.ToArray())
"Wrote $OutPath ($($out.Length) bytes, $($frames.Count) frames)"
