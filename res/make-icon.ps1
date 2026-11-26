# Draws the Ter icon (blue rounded square with a ">_" prompt) and writes res\ter.ico.
# Run once, or again after changing the design:  powershell -File res\make-icon.ps1
Add-Type -AssemblyName System.Drawing

function New-IconPng([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)

    # rounded square with a top-to-bottom blue gradient
    $m = [single]($size * 0.04)
    $d = [single]($size - 2 * $m)
    $r = [single]($size * 0.23)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc($m, $m, 2 * $r, 2 * $r, 180, 90)
    $path.AddArc($m + $d - 2 * $r, $m, 2 * $r, 2 * $r, 270, 90)
    $path.AddArc($m + $d - 2 * $r, $m + $d - 2 * $r, 2 * $r, 2 * $r, 0, 90)
    $path.AddArc($m, $m + $d - 2 * $r, 2 * $r, 2 * $r, 90, 90)
    $path.CloseFigure()
    $rect = New-Object System.Drawing.RectangleF 0, 0, $size, $size
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush $rect,
        ([System.Drawing.Color]::FromArgb(255, 72, 164, 255)),
        ([System.Drawing.Color]::FromArgb(255, 10, 92, 214)), 90
    $g.FillPath($brush, $path)

    # white ">" chevron and "_" cursor
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), ([single]($size * 0.105))
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $pen.LineJoin = 'Round'
    $pts = [System.Drawing.PointF[]]@(
        (New-Object System.Drawing.PointF ($size * 0.27), ($size * 0.31)),
        (New-Object System.Drawing.PointF ($size * 0.48), ($size * 0.50)),
        (New-Object System.Drawing.PointF ($size * 0.27), ($size * 0.69)))
    $g.DrawLines($pen, $pts)
    $g.DrawLine($pen, [single]($size * 0.56), [single]($size * 0.70), [single]($size * 0.75), [single]($size * 0.70))

    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    return ,$ms.ToArray()
}

$sizes = 16, 20, 24, 32, 40, 48, 64, 256
$pngs = $sizes | ForEach-Object { ,(New-IconPng $_) }

# .ico = header + one directory entry per size + the PNG images
$out = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter $out
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]
    $bw.Write([byte]($s % 256)); $bw.Write([byte]($s % 256))   # 256 is stored as 0
    $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32)
    $bw.Write([uint32]$pngs[$i].Length); $bw.Write([uint32]$offset)
    $offset += $pngs[$i].Length
}
foreach ($p in $pngs) { $bw.Write($p) }
[System.IO.File]::WriteAllBytes((Join-Path $PSScriptRoot 'ter.ico'), $out.ToArray())
"wrote ter.ico ($($out.Length) bytes)"
