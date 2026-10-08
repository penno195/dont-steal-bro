# Draws UI icons that have no art pack source into assets/ui/, as white
# silhouettes on transparency, so Icons.luau can tint them per state like
# the game-icons.net ones. Re-run to regenerate:
#   powershell -ExecutionPolicy Bypass -File scripts/make-ui-icons.ps1
# Then upload each PNG as an Image (Studio MCP upload_image, served from
# localhost) and paste the id into Icons.luau.

Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = 'Stop'

$out = Join-Path $PSScriptRoot '..\assets\ui'
New-Item -ItemType Directory -Force $out | Out-Null

$S = 256
$white = [System.Drawing.Color]::White
$clear = [System.Drawing.Color]::Transparent

function New-Canvas {
	$bmp = New-Object System.Drawing.Bitmap $S, $S, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
	$g = [System.Drawing.Graphics]::FromImage($bmp)
	$g.SmoothingMode = 'AntiAlias'
	$g.Clear($clear)
	return @($bmp, $g)
}

function RoundRect([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
	$p = New-Object System.Drawing.Drawing2D.GraphicsPath
	$d = 2 * $r
	$p.AddArc($x, $y, $d, $d, 180, 90)
	$p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
	$p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
	$p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
	$p.CloseFigure()
	return $p
}

# ---- locker: a pair of gym lockers, vents up top, a handle on each door ----
$bmp, $g = New-Canvas
$fill = New-Object System.Drawing.SolidBrush $white
$g.FillPath($fill, (RoundRect 40 20 176 216 18))

# Everything below is cut out of the white body, so it reads at 24px.
$g.CompositingMode = 'SourceCopy'
$hole = New-Object System.Drawing.SolidBrush $clear
# The seam between the two doors.
$g.FillRectangle($hole, 124, 34, 8, 188)
# Door panels' inset edges, as thin cuts around each door.
foreach ($x in @(54, 138)) {
	# Three vent slats per door.
	foreach ($y in @(48, 70, 92)) {
		$g.FillPath($hole, (RoundRect $x $y 64 10 5))
	}
	# The handle: a short vertical slot near the seam.
	$hx = if ($x -lt 128) { $x + 50 } else { $x + 4 }
	$g.FillPath($hole, (RoundRect $hx 132 10 40 5))
}
# The legs gap at the bottom.
$g.FillRectangle($hole, 70, 226, 116, 10)

$g.Dispose()
$bmp.Save((Join-Path $out 'locker.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output "wrote assets/ui/locker.png"
