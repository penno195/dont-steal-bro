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

# ---- restart: a full-colour coin, not a silhouette ----
# It sits in the task header between the pack's close and info coins, so
# it copies their build (a flat face, a darker lip 20px below it, a
# diagonal sheen) in amber, with a white clockwise arrow. Icons.luau marks
# it fullColor.
function Hex([string]$h) { return [System.Drawing.ColorTranslator]::FromHtml($h) }

$bmp, $g = New-Canvas
$face = New-Object System.Drawing.Drawing2D.GraphicsPath
$face.AddEllipse(24, 14, 208, 208)
$g.FillEllipse((New-Object System.Drawing.SolidBrush (Hex '#C2600C')), 24, 34, 208, 208)
$g.FillPath((New-Object System.Drawing.SolidBrush (Hex '#EE8A14')), $face)

# The sheen: a lighter band from lower-left to upper-right, kept on the face.
$g.SetClip($face)
$band = [System.Drawing.PointF[]]@(
	(New-Object System.Drawing.PointF 150, 0), (New-Object System.Drawing.PointF 256, 0),
	(New-Object System.Drawing.PointF 256, 40), (New-Object System.Drawing.PointF 60, 236),
	(New-Object System.Drawing.PointF 0, 236), (New-Object System.Drawing.PointF 0, 150))
$g.FillPolygon((New-Object System.Drawing.SolidBrush (Hex '#FFA53A')), $band)
$g.ResetClip()

# The arrow: a thick ring with a gap at the top, its head closing the gap.
$ink = New-Object System.Drawing.SolidBrush (Hex '#FFF6EA')
$cx = 128; $cy = 118; $r = 56
$pen = New-Object System.Drawing.Pen (Hex '#FFF6EA'), 30
$g.DrawArc($pen, $cx - $r, $cy - $r, 2 * $r, 2 * $r, 330, 270)
$t = 240 * [Math]::PI / 180
$px = $cx + $r * [Math]::Cos($t); $py = $cy + $r * [Math]::Sin($t)
$nx = [Math]::Cos($t); $ny = [Math]::Sin($t) # outward
$tx = -[Math]::Sin($t); $ty = [Math]::Cos($t) # clockwise
$head = [System.Drawing.PointF[]]@(
	(New-Object System.Drawing.PointF ($px + 34 * $nx), ($py + 34 * $ny)),
	(New-Object System.Drawing.PointF ($px - 34 * $nx), ($py - 34 * $ny)),
	(New-Object System.Drawing.PointF ($px + 44 * $tx), ($py + 44 * $ty)))
$g.FillPolygon($ink, $head)

$g.Dispose()
$bmp.Save((Join-Path $out 'restart.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output "wrote assets/ui/restart.png"

# ---- the race HUD's silhouettes (tinted per state, like locker) ----
function Pts([float[]]$xy) {
	$list = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
	for ($i = 0; $i -lt $xy.Length; $i += 2) { $list.Add((New-Object System.Drawing.PointF $xy[$i], $xy[$i + 1])) }
	return $list.ToArray()
}
function Save-Icon($bmp, $g, [string]$name) {
	$g.Dispose()
	$bmp.Save((Join-Path $out "$name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
	$bmp.Dispose()
	Write-Output "wrote assets/ui/$name.png"
}
$fill = New-Object System.Drawing.SolidBrush $white
$hole = New-Object System.Drawing.SolidBrush $clear

# arrow: the objective compass, a navigation pointer. It's rotated in the
# HUD, so it must point straight up.
$bmp, $g = New-Canvas
$g.FillPolygon($fill, (Pts @(128, 16, 226, 232, 128, 184, 30, 232)))
Save-Icon $bmp $g 'arrow'

# chevron: the objective is a floor up (rotated 180 for a floor down).
$bmp, $g = New-Canvas
$g.FillPolygon($fill, (Pts @(128, 52, 240, 164, 196, 208, 128, 140, 60, 208, 16, 164)))
Save-Icon $bmp $g 'chevron'

# down: below the qualification line. A solid arrow, unlike the chevron.
$bmp, $g = New-Canvas
$g.FillPath($fill, (RoundRect 96 16 64 120 12))
$g.FillPolygon($fill, (Pts @(28, 116, 228, 116, 128, 240)))
Save-Icon $bmp $g 'down'

# pending: a task not done yet, an open ring.
$bmp, $g = New-Canvas
$g.DrawEllipse((New-Object System.Drawing.Pen $white, 32), 40, 40, 176, 176)
Save-Icon $bmp $g 'pending'

# boost: any buff, two stacked chevrons.
$bmp, $g = New-Canvas
foreach ($y in @(20, 116)) {
	$g.FillPolygon($fill, (Pts @(128, $y, 232, ($y + 104), 192, ($y + 136), 128, ($y + 72), 64, ($y + 136), 24, ($y + 104))))
}
Save-Icon $bmp $g 'boost'

# warning: a rounded triangle with the "!" cut out of it.
$bmp, $g = New-Canvas
$tri = New-Object System.Drawing.Drawing2D.GraphicsPath
$tri.AddPolygon((Pts @(128, 26, 238, 222, 18, 222)))
$round = New-Object System.Drawing.Pen $white, 28
$round.LineJoin = 'Round'
$g.FillPath($fill, $tri)
$g.DrawPath($round, $tri)
$g.CompositingMode = 'SourceCopy'
$g.FillPath($hole, (RoundRect 112 84 32 86 14))
$g.FillEllipse($hole, 110, 182, 36, 36)
Save-Icon $bmp $g 'warning'

# trash: the power-up discard bin. A lid with a handle, a tapered body
# with three slots cut down it.
$bmp, $g = New-Canvas
$g.FillPath($fill, (RoundRect 92 14 72 40 12))
$g.FillPath($fill, (RoundRect 32 42 192 30 10))
$g.FillPolygon($fill, (Pts @(50, 84, 206, 84, 188, 242, 68, 242)))
$g.CompositingMode = 'SourceCopy'
$g.FillPath($hole, (RoundRect 110 26 36 16 6))
foreach ($x in @(86, 120, 154)) { $g.FillPath($hole, (RoundRect $x 108 16 110 8)) }
Save-Icon $bmp $g 'trash'

# gift: a win's item-drop chance on the Decision Studio's stakes. A box
# and its wider lid, a ribbon gap cut down both, two bow loops on top.
$bmp, $g = New-Canvas
$g.FillPath($fill, (RoundRect 40 128 176 112 12))
$g.FillPath($fill, (RoundRect 24 84 208 40 10))
$bow = New-Object System.Drawing.Pen $white, 22
$g.DrawEllipse($bow, 62, 26, 62, 46)
$g.DrawEllipse($bow, 132, 26, 62, 46)
$g.CompositingMode = 'SourceCopy'
$g.FillRectangle($hole, 116, 84, 24, 160)
$g.FillRectangle($hole, 24, 124, 208, 6)
Save-Icon $bmp $g 'gift'
