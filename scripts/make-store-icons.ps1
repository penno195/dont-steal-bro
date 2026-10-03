# Draws the store products' icons (next-stages step 11) into assets/store/,
# ready to upload as each product's or pass's icon in the Creator Dashboard.
# Re-run to regenerate:
#   powershell -ExecutionPolicy Bypass -File scripts/make-store-icons.ps1
#
# 512x512, full colour on an opaque background. Roblox crops pass icons to
# a circle, so everything that matters stays inside the middle ~70%.

Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = 'Stop'

$out = Join-Path $PSScriptRoot '..\assets\store'
New-Item -ItemType Directory -Force $out | Out-Null

$S = 512

function Rgb([int]$r, [int]$g, [int]$b, [int]$a = 255) { [System.Drawing.Color]::FromArgb($a, $r, $g, $b) }
function Brush($color) { New-Object System.Drawing.SolidBrush $color }
function Pen($color, [float]$w) {
	$p = New-Object System.Drawing.Pen $color, $w
	$p.StartCap = 'Round'; $p.EndCap = 'Round'; $p.LineJoin = 'Round'
	return $p
}
function Pt([float]$x, [float]$y) { New-Object System.Drawing.PointF $x, $y }

# A canvas pre-filled with a diagonal gradient and a soft centre glow.
function New-Icon($top, $bottom) {
	$bmp = New-Object System.Drawing.Bitmap $S, $S, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
	$g = [System.Drawing.Graphics]::FromImage($bmp)
	$g.SmoothingMode = 'AntiAlias'
	$g.TextRenderingHint = 'AntiAliasGridFit'
	$bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush (New-Object System.Drawing.Rectangle 0, 0, $S, $S), $top, $bottom, 60
	$g.FillRectangle($bg, 0, 0, $S, $S)
	$glow = New-Object System.Drawing.Drawing2D.GraphicsPath
	$glow.AddEllipse(56, 40, 400, 400)
	$gb = New-Object System.Drawing.Drawing2D.PathGradientBrush $glow
	$gb.CenterColor = Rgb 255 255 255 90
	$gb.SurroundColors = [System.Drawing.Color[]]@((Rgb 255 255 255 0))
	$g.FillPath($gb, $glow)
	return @($bmp, $g)
}

function Save-Icon($canvas, [string]$name) {
	$canvas[1].Dispose()
	$canvas[0].Save((Join-Path $out $name), [System.Drawing.Imaging.ImageFormat]::Png)
	$canvas[0].Dispose()
	Write-Output "wrote $name"
}

# Big outlined label, centred on cy.
function Draw-Label($g, [string]$text, [float]$cy, [float]$size, $fill) {
	$path = New-Object System.Drawing.Drawing2D.GraphicsPath
	$fmt = New-Object System.Drawing.StringFormat
	$fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
	$path.AddString($text, (New-Object System.Drawing.FontFamily 'Arial Black'), 0, $size, (New-Object System.Drawing.RectangleF 0, ($cy - $size), $S, ($size * 2)), $fmt)
	$g.DrawPath((Pen (Rgb 30 20 40) ($size / 5)), $path)
	$g.FillPath((Brush $fill), $path)
}

# A gold coin, slightly tilted by squashing it vertically.
function Draw-Coin($g, [float]$cx, [float]$cy, [float]$r) {
	$h = $r * 0.86
	$g.FillEllipse((Brush (Rgb 176 112 10)), $cx - $r, $cy - $h + $r * 0.16, $r * 2, $h * 2)
	$g.FillEllipse((Brush (Rgb 255 204 50)), $cx - $r, $cy - $h, $r * 2, $h * 2)
	$g.DrawEllipse((Pen (Rgb 200 130 10) ($r * 0.1)), $cx - $r * 0.72, $cy - $h * 0.72, $r * 1.44, $h * 1.44)
	$g.FillEllipse((Brush (Rgb 255 245 190 200)), $cx - $r * 0.55, $cy - $h * 0.6, $r * 0.35, $h * 0.3)
}

function Bolt-Points([float]$cx, [float]$cy, [float]$k) {
	$raw = @(@(10, -100), @(-55, 10), @(-5, 10), @(-20, 100), @(55, -15), @(5, -15), @(25, -100))
	return [System.Drawing.PointF[]]($raw | ForEach-Object { Pt ($cx + $_[0] * $k) ($cy + $_[1] * $k) })
}

$ink = Rgb 30 20 40

# ===== currency-small: Small Coin Pouch ====================================
$c = New-Icon (Rgb 80 200 120) (Rgb 20 110 70); $g = $c[1]
$pouch = New-Object System.Drawing.Drawing2D.GraphicsPath
$pouch.AddBezier((Pt 200 190), (Pt 90 260), (Pt 110 400), (Pt 256 400))
$pouch.AddBezier((Pt 256 400), (Pt 402 400), (Pt 422 260), (Pt 312 190))
$pouch.CloseFigure()
$g.FillPath((Brush (Rgb 170 100 50)), $pouch)
$g.DrawPath((Pen $ink 10), $pouch)
$g.FillEllipse((Brush (Rgb 140 80 40)), 196, 150, 120, 56)
$g.DrawEllipse((Pen $ink 10), 196, 150, 120, 56)
$g.DrawLine((Pen (Rgb 255 210 80) 14), 200, 205, 312, 205)
Draw-Coin $g 256 300 62
Draw-Coin $g 330 128 40
Draw-Coin $g 180 120 32
Draw-Label $g '75' 440 64 (Rgb 255 255 255)
Save-Icon $c 'currency-small.png'

# ===== currency-large: Large Coin Chest ====================================
$c = New-Icon (Rgb 170 110 255) (Rgb 70 30 150); $g = $c[1]
# Coin pile spilling out of the open chest.
Draw-Coin $g 196 190 44; Draw-Coin $g 316 190 44; Draw-Coin $g 256 160 50
Draw-Coin $g 150 222 38; Draw-Coin $g 362 222 38
$g.FillRectangle((Brush (Rgb 150 85 40)), 116, 230, 280, 150)
$g.DrawRectangle((Pen $ink 10), 116, 230, 280, 150)
$g.FillRectangle((Brush (Rgb 255 200 60)), 116, 270, 280, 22)
$g.DrawRectangle((Pen $ink 6), 116, 270, 280, 22)
$g.FillRectangle((Brush (Rgb 255 200 60)), 230, 262, 52, 66)
$g.DrawRectangle((Pen $ink 8), 230, 262, 52, 66)
$g.FillEllipse((Brush $ink), 249, 284, 14, 18)
Draw-Label $g '250' 440 64 (Rgb 255 230 90)
Save-Icon $c 'currency-large.png'

# ===== stock-sprint-boost-10: Sprint Boost x10 =============================
$c = New-Icon (Rgb 70 200 255) (Rgb 20 80 190); $g = $c[1]
# Speed lines behind the bolt.
foreach ($y in 170, 230, 290) { $g.DrawLine((Pen (Rgb 255 255 255 150) 14), 90, $y, 170, $y) }
$bolt = Bolt-Points 266 230 1.5
$g.FillPolygon((Brush (Rgb 255 230 60)), $bolt)
$g.DrawPolygon((Pen $ink 12), $bolt)
Draw-Label $g 'x10' 420 74 (Rgb 255 255 255)
Save-Icon $c 'stock-sprint-boost-10.png'

# ===== bundle-starter-loadout: Starter Loadout Bundle ======================
$c = New-Icon (Rgb 255 170 70) (Rgb 210 70 40); $g = $c[1]
$badges = @(
	@(150, 230, (Rgb 40 140 230)),  # Sprint Boost
	@(256, 170, (Rgb 130 80 220)),  # Slow Field
	@(362, 230, (Rgb 230 60 90))    # Push-Trip
)
foreach ($b in $badges) {
	$g.FillEllipse((Brush $b[2]), $b[0] - 72, $b[1] - 72, 144, 144)
	$g.DrawEllipse((Pen $ink 10), $b[0] - 72, $b[1] - 72, 144, 144)
}
$bolt = Bolt-Points 150 230 0.55
$g.FillPolygon((Brush (Rgb 255 230 60)), $bolt); $g.DrawPolygon((Pen $ink 6), $bolt)
foreach ($r in 18, 34, 50) { $g.DrawEllipse((Pen (Rgb 255 255 255) 7), 256 - $r, 170 - $r, $r * 2, $r * 2) }
$arrow = Pen (Rgb 255 255 255) 14
$g.DrawLine($arrow, 324, 230, 394, 230)
$g.DrawLine($arrow, 368, 204, 396, 230); $g.DrawLine($arrow, 368, 256, 396, 230)
Draw-Label $g 'x5 EACH' 410 52 (Rgb 255 255 255)
Save-Icon $c 'bundle-starter-loadout.png'

# ===== season-1-pass: Season 1 Pass ========================================
$c = New-Icon (Rgb 60 50 120) (Rgb 15 10 40); $g = $c[1]
# A ticket: rounded card with notches bitten out of both sides.
$ticket = New-Object System.Drawing.Drawing2D.GraphicsPath
$ticket.AddRectangle((New-Object System.Drawing.RectangleF 96, 150, 320, 212))
$notches = New-Object System.Drawing.Drawing2D.GraphicsPath
$notches.AddEllipse(70, 230, 52, 52); $notches.AddEllipse(390, 230, 52, 52)
$region = New-Object System.Drawing.Region $ticket
$region.Exclude($notches)
$gold = New-Object System.Drawing.Drawing2D.LinearGradientBrush (New-Object System.Drawing.Rectangle 96, 150, 320, 212), (Rgb 255 225 110), (Rgb 220 150 20), 90
$g.FillRegion($gold, $region)
$dash = Pen (Rgb 150 90 10) 6
$dash.DashStyle = 'Dash'
$g.DrawRectangle($dash, 122, 172, 268, 168)
Draw-Label $g 'S1' 256 78 (Rgb 255 255 255)
foreach ($p in @(@(150, 110, 22), @(372, 104, 16), @(256, 92, 12), @(400, 400, 18), @(118, 404, 14))) {
	$x = $p[0]; $y = $p[1]; $r = $p[2]
	$pts = @()
	for ($i = 0; $i -lt 8; $i++) {
		$a = [Math]::PI / 4 * $i - [Math]::PI / 2
		$rr = if ($i % 2 -eq 0) { $r } else { $r / 4 }
		$pts += Pt ($x + [Math]::Cos($a) * $rr) ($y + [Math]::Sin($a) * $rr)
	}
	$g.FillPolygon((Brush (Rgb 255 235 150)), [System.Drawing.PointF[]]$pts)
}
Draw-Label $g 'PASS' 430 46 (Rgb 255 220 90)
Save-Icon $c 'season-1-pass.png'
