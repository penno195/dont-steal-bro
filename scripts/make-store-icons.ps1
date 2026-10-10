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

# ===== shared: the season pass's finish (art pass 2026-10-10) ==============
# Sunburst, soft drop shadows, gradients with a gloss band, ink outlines and
# sparkles, so the coin icons sit beside the season pass as one set.
function Draw-Sunburst($g, [float]$cx, [float]$cy) {
	for ($i = 0; $i -lt 16; $i++) {
		$a0 = [Math]::PI / 8 * $i; $a1 = $a0 + [Math]::PI / 16
		$g.FillPolygon((Brush (Rgb 255 255 255 26)), [System.Drawing.PointF[]]@(
			(Pt $cx $cy), (Pt ($cx + [Math]::Cos($a0) * 380) ($cy + [Math]::Sin($a0) * 380)),
			(Pt ($cx + [Math]::Cos($a1) * 380) ($cy + [Math]::Sin($a1) * 380))))
	}
}

function Draw-Sparkles($g, $list) {
	foreach ($p in $list) {
		$x = $p[0]; $y = $p[1]; $r = $p[2]
		$pts = @()
		for ($i = 0; $i -lt 8; $i++) {
			$a = [Math]::PI / 4 * $i - [Math]::PI / 2
			$rr = if ($i % 2 -eq 0) { $r } else { $r / 4 }
			$pts += Pt ($x + [Math]::Cos($a) * $rr) ($y + [Math]::Sin($a) * $rr)
		}
		$g.FillPolygon((Brush (Rgb 255 235 150)), [System.Drawing.PointF[]]$pts)
	}
}

function Star-Points([float]$cx, [float]$cy, [float]$outer, [float]$inner) {
	$pts = @()
	for ($i = 0; $i -lt 10; $i++) {
		$a = [Math]::PI / 5 * $i - [Math]::PI / 2
		$rr = if ($i % 2 -eq 0) { $outer } else { $inner }
		$pts += Pt ($cx + [Math]::Cos($a) * $rr) ($cy + [Math]::Sin($a) * $rr)
	}
	return [System.Drawing.PointF[]]$pts
}

# A thick gold coin, tilted towards you: a dark rim for its edge, a
# gradient face with an inner ring and an embossed star, a gloss spot,
# all inked. $tilt squashes it (1 = face-on).
function Draw-ShinyCoin($g, [float]$cx, [float]$cy, [float]$r, [float]$tilt = 0.82) {
	$h = $r * $tilt; $edge = $r * 0.2
	$w = [Math]::Max(3, $r * 0.13)
	$g.FillEllipse((Brush (Rgb 0 0 0 70)), ($cx - $r + 4), ($cy - $h + $edge + 8), ($r * 2), ($h * 2))
	$g.FillEllipse((Brush (Rgb 190 110 10)), ($cx - $r), ($cy - $h + $edge), ($r * 2), ($h * 2))
	$g.FillRectangle((Brush (Rgb 190 110 10)), ($cx - $r), $cy, ($r * 2), $edge)
	$g.DrawEllipse((Pen $ink $w), ($cx - $r), ($cy - $h + $edge), ($r * 2), ($h * 2))
	$rect = New-Object System.Drawing.RectangleF ($cx - $r), ($cy - $h - 1), ($r * 2), ($h * 2 + 2)
	$face = New-Object System.Drawing.Drawing2D.LinearGradientBrush $rect, (Rgb 255 236 130), (Rgb 240 160 20), 90
	$g.FillEllipse($face, ($cx - $r), ($cy - $h), ($r * 2), ($h * 2))
	$g.DrawEllipse((Pen $ink $w), ($cx - $r), ($cy - $h), ($r * 2), ($h * 2))
	$g.DrawEllipse((Pen (Rgb 205 125 10) ($r * 0.08)), ($cx - $r * 0.72), ($cy - $h * 0.72), ($r * 1.44), ($h * 1.44))
	if ($r -ge 26) {
		$star = Star-Points 0 0 ($r * 0.42) ($r * 0.18)
		$state = $g.Save()
		$g.TranslateTransform($cx, $cy); $g.ScaleTransform(1, $tilt)
		$g.FillPolygon((Brush (Rgb 205 125 10)), $star)
		$g.Restore($state)
	}
	$g.FillEllipse((Brush (Rgb 255 255 230 210)), ($cx - $r * 0.62), ($cy - $h * 0.66), ($r * 0.42), ($h * 0.3))
}

# ===== currency-small: Small Coin Pouch ====================================
$c = New-Icon (Rgb 90 215 140) (Rgb 10 90 60); $g = $c[1]
Draw-Sunburst $g 256 236
# A plump drawstring sack: the body, a frilled neck above a gold cord,
# a big coin on its front, and coins spilling out around it.
$pouch = New-Object System.Drawing.Drawing2D.GraphicsPath
$pouch.AddBezier((Pt 206 196), (Pt 84 250), (Pt 92 396), (Pt 256 396))
$pouch.AddBezier((Pt 256 396), (Pt 420 396), (Pt 428 250), (Pt 306 196))
$pouch.CloseFigure()
$g.TranslateTransform(8, 12); $g.FillPath((Brush (Rgb 0 0 0 90)), $pouch); $g.TranslateTransform(-8, -12)
$sack = New-Object System.Drawing.Drawing2D.LinearGradientBrush (New-Object System.Drawing.Rectangle 90, 190, 340, 210), (Rgb 205 135 70), (Rgb 130 70 30), 90
$g.FillPath($sack, $pouch)
$g.SetClip($pouch)
$g.FillPolygon((Brush (Rgb 255 255 255 55)), [System.Drawing.PointF[]]@((Pt 150 190), (Pt 200 190), (Pt 140 400), (Pt 90 400)))
$g.FillEllipse((Brush (Rgb 0 0 0 40)), 290, 210, 200, 220)
$g.ResetClip()
$g.DrawPath((Pen $ink 12), $pouch)
# The frilled neck.
$neck = New-Object System.Drawing.Drawing2D.GraphicsPath
$neck.AddBezier((Pt 214 200), (Pt 190 170), (Pt 176 140), (Pt 196 128))
$neck.AddBezier((Pt 196 128), (Pt 222 140), (Pt 236 120), (Pt 256 132))
$neck.AddBezier((Pt 256 132), (Pt 276 120), (Pt 290 140), (Pt 316 128))
$neck.AddBezier((Pt 316 128), (Pt 336 140), (Pt 322 170), (Pt 298 200))
$neck.CloseFigure()
$ng = New-Object System.Drawing.Drawing2D.LinearGradientBrush (New-Object System.Drawing.Rectangle 176, 120, 160, 84), (Rgb 215 145 80), (Rgb 150 85 40), 90
$g.FillPath($ng, $neck); $g.DrawPath((Pen $ink 10), $neck)
# The gold cord and its bow's two tails.
$cord = New-Object System.Drawing.Drawing2D.GraphicsPath
$cord.AddArc(200, 186, 112, 30, 180, -180)
$g.DrawPath((Pen $ink 26), $cord); $g.DrawPath((Pen (Rgb 255 210 70) 14), $cord)
foreach ($t in @(@(256, 208, 230, 250), @(256, 208, 284, 252))) {
	$g.DrawLine((Pen $ink 22), $t[0], $t[1], $t[2], $t[3]); $g.DrawLine((Pen (Rgb 255 210 70) 10), $t[0], $t[1], $t[2], $t[3])
}
$g.FillEllipse((Brush (Rgb 255 210 70)), 244, 196, 24, 24); $g.DrawEllipse((Pen $ink 6), 244, 196, 24, 24)
Draw-ShinyCoin $g 256 306 52 0.9
Draw-ShinyCoin $g 128 372 30
Draw-ShinyCoin $g 386 366 34
Draw-ShinyCoin $g 352 132 26
Draw-Sparkles $g @(@(120, 128, 22), @(400, 210, 14), @(96, 270, 12), @(420, 110, 16))
Draw-Label $g '75' 446 54 (Rgb 255 220 90)
Save-Icon $c 'currency-small.png'

# ===== currency-large: Large Coin Chest ====================================
$c = New-Icon (Rgb 140 70 230) (Rgb 30 10 80); $g = $c[1]
Draw-Sunburst $g 256 230
# A treasure chest thrown open: the lid tipped back, a warm glow out of
# it, a heap of coins over the brim and a few spilt in front.
$trim = New-Object System.Drawing.Drawing2D.LinearGradientBrush (New-Object System.Drawing.Rectangle 100, 70, 312, 330), (Rgb 255 236 130), (Rgb 225 145 15), 90
# The lid, behind everything.
$lid = New-Object System.Drawing.Drawing2D.GraphicsPath
$lid.AddLine(118, 214, 140, 110); $lid.AddBezier((Pt 140 110), (Pt 200 70), (Pt 312 70), (Pt 372 110)); $lid.AddLine(372, 110, 394, 214)
$lid.CloseFigure()
$g.FillPath((Brush (Rgb 110 60 25)), $lid); $g.DrawPath((Pen $ink 12), $lid)
$strap = [System.Drawing.PointF[]]@((Pt 236 80), (Pt 276 80), (Pt 284 214), (Pt 228 214))
$g.FillPolygon($trim, $strap); $g.DrawPolygon((Pen $ink 7), $strap)
# The glow out of the open chest.
$glow = New-Object System.Drawing.Drawing2D.GraphicsPath
$glow.AddEllipse(96, 100, 320, 210)
$gb = New-Object System.Drawing.Drawing2D.PathGradientBrush $glow
$gb.CenterColor = Rgb 255 240 150 200
$gb.SurroundColors = [System.Drawing.Color[]]@((Rgb 255 240 150 0))
$g.FillPath($gb, $glow)
# The heap, back row first.
foreach ($k in @(@(166, 208, 34), @(346, 208, 34), @(206, 186, 38), @(306, 186, 38), @(256, 162, 44), @(222, 214, 36), @(292, 214, 36))) {
	Draw-ShinyCoin $g $k[0] $k[1] $k[2]
}
# The body, its shadow first.
$body = New-Object System.Drawing.Drawing2D.GraphicsPath
$body.AddRectangle((New-Object System.Drawing.RectangleF 112, 222, 288, 160))
$g.TranslateTransform(8, 12); $g.FillPath((Brush (Rgb 0 0 0 90)), $body); $g.TranslateTransform(-8, -12)
$bw = New-Object System.Drawing.Drawing2D.LinearGradientBrush (New-Object System.Drawing.Rectangle 112, 220, 288, 164), (Rgb 185 110 55), (Rgb 115 60 25), 90
$g.FillPath($bw, $body)
foreach ($y in 274, 330) { $g.DrawLine((Pen (Rgb 95 50 20) 5), 118, $y, 394, $y) }
$g.SetClip($body)
$g.FillPolygon((Brush (Rgb 255 255 255 45)), [System.Drawing.PointF[]]@((Pt 150 220), (Pt 196 220), (Pt 150 384), (Pt 104 384)))
$g.ResetClip()
$g.DrawPath((Pen $ink 12), $body)
# Gold banding: the brim, two corner straps and the lock plate.
foreach ($r in @(@(106, 210, 300, 24), @(134, 234, 26, 148), @(352, 234, 26, 148))) {
	$g.FillRectangle($trim, $r[0], $r[1], $r[2], $r[3]); $g.DrawRectangle((Pen $ink 7), $r[0], $r[1], $r[2], $r[3])
}
$plate = New-Object System.Drawing.Drawing2D.GraphicsPath
$plate.AddArc(226, 240, 60, 60, 180, 180); $plate.AddLine(286, 270, 286, 318); $plate.AddLine(286, 318, 226, 318)
$plate.CloseFigure()
$g.FillPath($trim, $plate); $g.DrawPath((Pen $ink 8), $plate)
$g.FillEllipse((Brush $ink), 247, 268, 18, 18); $g.FillPolygon((Brush $ink), [System.Drawing.PointF[]]@((Pt 251 280), (Pt 261 280), (Pt 265 302), (Pt 247 302)))
# Spilt coins in front.
Draw-ShinyCoin $g 96 384 30
Draw-ShinyCoin $g 418 380 34
Draw-ShinyCoin $g 380 408 24
Draw-Sparkles $g @(@(100, 120, 22), @(412, 96, 18), @(444, 270, 14), @(70, 300, 12))
Draw-Label $g '250' 446 54 (Rgb 255 220 90)
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

# ===== season-pass: Season Pass ==========================================
$c = New-Icon (Rgb 140 70 230) (Rgb 30 10 80); $g = $c[1]
$purple = Rgb 70 30 150
# Sunburst rays behind the ticket.
for ($i = 0; $i -lt 16; $i++) {
	$a0 = [Math]::PI / 8 * $i; $a1 = $a0 + [Math]::PI / 16
	$g.FillPolygon((Brush (Rgb 255 255 255 26)), [System.Drawing.PointF[]]@(
		(Pt 256 241), (Pt (256 + [Math]::Cos($a0) * 360) (241 + [Math]::Sin($a0) * 360)),
		(Pt (256 + [Math]::Cos($a1) * 360) (241 + [Math]::Sin($a1) * 360))))
}
# A golden ticket, tipped jauntily: rounded card with notches bitten out of
# both sides, a crown in its window and a star on the torn-off stub. No
# season number: seasons are monthly, and a number baked in goes stale.
$g.TranslateTransform(256, 241); $g.RotateTransform(-10); $g.TranslateTransform(-256, -241)
$x0 = 106; $y0 = 146; $x1 = 406; $y1 = 336; $r = 22; $n = 26
$ticket = New-Object System.Drawing.Drawing2D.GraphicsPath
$ticket.AddArc($x0, $y0, 2 * $r, 2 * $r, 180, 90)
$ticket.AddArc($x1 - 2 * $r, $y0, 2 * $r, 2 * $r, 270, 90)
$ticket.AddArc($x1 - $n, 241 - $n, 2 * $n, 2 * $n, 270, -180)
$ticket.AddArc($x1 - 2 * $r, $y1 - 2 * $r, 2 * $r, 2 * $r, 0, 90)
$ticket.AddArc($x0, $y1 - 2 * $r, 2 * $r, 2 * $r, 90, 90)
$ticket.AddArc($x0 - $n, 241 - $n, 2 * $n, 2 * $n, 90, -180)
$ticket.CloseFigure()
$g.TranslateTransform(8, 12); $g.FillPath((Brush (Rgb 0 0 0 90)), $ticket); $g.TranslateTransform(-8, -12)
$gold = New-Object System.Drawing.Drawing2D.LinearGradientBrush (New-Object System.Drawing.Rectangle $x0, $y0, 300, 190), (Rgb 255 232 120), (Rgb 225 145 15), 90
$g.FillPath($gold, $ticket)
# A glossy band across the card.
$g.SetClip($ticket)
$g.FillPolygon((Brush (Rgb 255 255 255 70)), [System.Drawing.PointF[]]@((Pt 150 140), (Pt 210 140), (Pt 130 340), (Pt 70 340)))
$g.ResetClip()
$g.DrawPath((Pen $ink 12), $ticket)
# Perforation between the window and the stub.
$dash = Pen (Rgb 150 85 10) 7
$dash.DashStyle = 'Dot'
$g.DrawLine($dash, 316, ($y0 + 18), 316, ($y1 - 18))
# The window: a purple panel with a gold crown.
$win = New-Object System.Drawing.Drawing2D.GraphicsPath
$win.AddArc(134, 172, 32, 32, 180, 90); $win.AddArc(264, 172, 32, 32, 270, 90)
$win.AddArc(264, 278, 32, 32, 0, 90); $win.AddArc(134, 278, 32, 32, 90, 90)
$win.CloseFigure()
$g.FillPath((Brush $purple), $win); $g.DrawPath((Pen $ink 7), $win)
$crown = [System.Drawing.PointF[]](@(@(-50, 34), @(-58, -26), @(-26, 4), @(0, -42), @(26, 4), @(58, -26), @(50, 34)) |
	ForEach-Object { Pt (215 + $_[0]) (246 + $_[1]) })
$cg = New-Object System.Drawing.Drawing2D.LinearGradientBrush (New-Object System.Drawing.Rectangle 150, 196, 130, 90), (Rgb 255 240 140), (Rgb 240 160 20), 90
$g.FillPolygon($cg, $crown); $g.DrawPolygon((Pen $ink 7), $crown)
foreach ($t in @(@(-58, -26), @(0, -42), @(58, -26))) {
	$g.FillEllipse((Brush (Rgb 255 240 140)), 215 + $t[0] - 10, 246 + $t[1] - 10, 20, 20)
	$g.DrawEllipse((Pen $ink 5), 215 + $t[0] - 10, 246 + $t[1] - 10, 20, 20)
}
$g.FillEllipse((Brush (Rgb 255 80 110)), 203, 252, 24, 20); $g.DrawEllipse((Pen $ink 4), 203, 252, 24, 20)
# The stub's star.
$star = @()
for ($i = 0; $i -lt 10; $i++) {
	$a = [Math]::PI / 5 * $i - [Math]::PI / 2
	$rr = if ($i % 2 -eq 0) { 34 } else { 15 }
	$star += Pt (360 + [Math]::Cos($a) * $rr) (243 + [Math]::Sin($a) * $rr)
}
$g.FillPolygon((Brush $purple), [System.Drawing.PointF[]]$star); $g.DrawPolygon((Pen $ink 5), [System.Drawing.PointF[]]$star)
$g.ResetTransform()
foreach ($p in @(@(132, 118, 22), @(386, 108, 16), @(402, 372, 16), @(112, 356, 12))) {
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
Save-Icon $c 'season-pass.png'

# ===== coin offers: one power-up each, bought with coins (next-stages 14d) ==
# One big badge in the power-up's colour with its glyph, and a gold coin
# on the badge's edge to say "bought with coins". No price on the art:
# the store card prints it, and a price baked into an image goes stale.
function New-CoinOffer($top, $bottom, $badge) {
	$c = New-Icon $top $bottom; $g = $c[1]
	$g.FillEllipse((Brush $badge), 106, 86, 300, 300)
	$g.DrawEllipse((Pen $ink 14), 106, 86, 300, 300)
	return $c
}
function Finish-CoinOffer($c, [string]$name) {
	$g = $c[1]
	$g.FillEllipse((Brush $ink), 318, 318, 116, 116)
	Draw-Coin $g 376 372 50
	Save-Icon $c $name
}
$white = Rgb 255 255 255

# Sprint Boost: the bolt.
$c = New-CoinOffer (Rgb 70 200 255) (Rgb 20 80 190) (Rgb 40 140 230); $g = $c[1]
$bolt = Bolt-Points 256 236 1.15
$g.FillPolygon((Brush (Rgb 255 230 60)), $bolt); $g.DrawPolygon((Pen $ink 10), $bolt)
Finish-CoinOffer $c 'sprint-boost-coins.png'

# Slow Field: rings spreading out.
$c = New-CoinOffer (Rgb 190 140 255) (Rgb 80 40 170) (Rgb 130 80 220); $g = $c[1]
foreach ($r in 30, 64, 98) { $g.DrawEllipse((Pen $white 16), 256 - $r, 236 - $r, $r * 2, $r * 2) }
Finish-CoinOffer $c 'slow-field-coins.png'

# Push-Trip: a shove arrow.
$c = New-CoinOffer (Rgb 255 120 140) (Rgb 170 30 60) (Rgb 230 60 90); $g = $c[1]
$p = Pen $white 30
$g.DrawLine($p, 170, 236, 340, 236); $g.DrawLine($p, 280, 176, 342, 236); $g.DrawLine($p, 280, 296, 342, 236)
Finish-CoinOffer $c 'push-trip-coins.png'

# Freeze: a snowflake.
$c = New-CoinOffer (Rgb 170 240 255) (Rgb 40 140 200) (Rgb 70 190 240); $g = $c[1]
$p = Pen $white 16
for ($i = 0; $i -lt 6; $i++) {
	$a = [Math]::PI / 3 * $i
	$ex = 256 + [Math]::Cos($a) * 108; $ey = 236 + [Math]::Sin($a) * 108
	$g.DrawLine($p, 256, 236, $ex, $ey)
	$mx = 256 + [Math]::Cos($a) * 66; $my = 236 + [Math]::Sin($a) * 66
	foreach ($side in -1, 1) {
		$b = $a + $side * 0.75
		$g.DrawLine($p, $mx, $my, $mx + [Math]::Cos($b) * 34, $my + [Math]::Sin($b) * 34)
	}
}
Finish-CoinOffer $c 'freeze-coins.png'

# Phase-Step: a ghost, half see-through.
$c = New-CoinOffer (Rgb 150 230 210) (Rgb 30 120 120) (Rgb 50 170 160); $g = $c[1]
$ghost = New-Object System.Drawing.Drawing2D.GraphicsPath
$ghost.AddArc(176, 136, 160, 160, 180, 180)
$ghost.AddLine(336, 216, 336, 330)
$ghost.AddLine(336, 330, 309, 304); $ghost.AddLine(309, 304, 283, 330); $ghost.AddLine(283, 330, 256, 304)
$ghost.AddLine(256, 304, 229, 330); $ghost.AddLine(229, 330, 203, 304); $ghost.AddLine(203, 304, 176, 330)
$ghost.CloseFigure()
$g.FillPath((Brush (Rgb 255 255 255 190)), $ghost); $g.DrawPath((Pen $ink 10), $ghost)
$g.FillEllipse((Brush $ink), 218, 196, 26, 34); $g.FillEllipse((Brush $ink), 268, 196, 26, 34)
Finish-CoinOffer $c 'phase-step-coins.png'

# Second Wind: a medic cross.
$c = New-CoinOffer (Rgb 130 230 140) (Rgb 20 120 60) (Rgb 50 180 90); $g = $c[1]
$cross = New-Object System.Drawing.Drawing2D.GraphicsPath
$cross.AddRectangle((New-Object System.Drawing.RectangleF 222, 142, 68, 188))
$cross.AddRectangle((New-Object System.Drawing.RectangleF 162, 202, 188, 68))
$cross.FillMode = 'Winding'
$g.FillPath((Brush $white), $cross)
Finish-CoinOffer $c 'second-wind-coins.png'

# Overclock: a clock face.
$c = New-CoinOffer (Rgb 255 200 110) (Rgb 200 100 20) (Rgb 240 140 40); $g = $c[1]
$g.FillEllipse((Brush $white), 156, 136, 200, 200); $g.DrawEllipse((Pen $ink 12), 156, 136, 200, 200)
for ($i = 0; $i -lt 12; $i++) {
	$a = [Math]::PI / 6 * $i
	$g.DrawLine((Pen $ink 6), 256 + [Math]::Cos($a) * 80, 236 + [Math]::Sin($a) * 80, 256 + [Math]::Cos($a) * 92, 236 + [Math]::Sin($a) * 92)
}
$g.DrawLine((Pen $ink 12), 256, 236, 256, 166); $g.DrawLine((Pen (Rgb 230 60 60) 10), 256, 236, 310, 260)
Finish-CoinOffer $c 'overclock-coins.png'

# Task Scramble: a question mark.
$c = New-CoinOffer (Rgb 255 140 220) (Rgb 160 30 130) (Rgb 210 70 180); $g = $c[1]
Draw-Label $g '?' 236 220 $white
Finish-CoinOffer $c 'task-scramble-coins.png'

# Task Insight: a magnifying glass.
$c = New-CoinOffer (Rgb 255 235 120) (Rgb 200 150 20) (Rgb 240 190 40); $g = $c[1]
$g.DrawLine((Pen $ink 34), 296, 276, 350, 330)
$g.FillEllipse((Brush (Rgb 200 240 255)), 166, 146, 150, 150); $g.DrawEllipse((Pen $ink 20), 166, 146, 150, 150)
$g.FillEllipse((Brush (Rgb 255 255 255 220)), 196, 172, 40, 28)
Finish-CoinOffer $c 'task-insight-coins.png'

# Blind: an eye, struck through.
$c = New-CoinOffer (Rgb 130 130 160) (Rgb 30 30 50) (Rgb 70 70 100); $g = $c[1]
$eye = New-Object System.Drawing.Drawing2D.GraphicsPath
$eye.AddBezier((Pt 150 236), (Pt 200 160), (Pt 312 160), (Pt 362 236))
$eye.AddBezier((Pt 362 236), (Pt 312 312), (Pt 200 312), (Pt 150 236))
$g.FillPath((Brush $white), $eye); $g.DrawPath((Pen $ink 12), $eye)
$g.FillEllipse((Brush $ink), 222, 202, 68, 68)
$g.DrawLine((Pen (Rgb 230 60 60) 22), 170, 150, 342, 322)
Finish-CoinOffer $c 'blind-coins.png'

# ===== navigation: one round, and the Unlimited pass (Q8 "Navigation") =====
# A dotted path winding up to a map pin. The round's art serves its Robux
# product and its coin offer alike; the pass adds the PASS label.
function Draw-Route($g) {
	# Drawn at full size, shrunk about the centre to stay inside the crop.
	$g.TranslateTransform(256, 236); $g.ScaleTransform(0.74, 0.74); $g.TranslateTransform(-256, -246)
	$dots = @(@(118, 404), @(166, 396), @(210, 378), @(244, 350), @(262, 314), @(288, 286), @(322, 270))
	foreach ($d in $dots) {
		$g.FillEllipse((Brush $ink), $d[0] - 19, $d[1] - 19, 38, 38)
		$g.FillEllipse((Brush $white), $d[0] - 13, $d[1] - 13, 26, 26)
	}
	$pin = New-Object System.Drawing.Drawing2D.GraphicsPath
	$pin.AddArc(290, 84, 132, 132, 150, 240)
	$pin.AddLine(413, 183, 356, 262)
	$pin.CloseFigure()
	$g.FillPath((Brush (Rgb 255 90 90)), $pin); $g.DrawPath((Pen $ink 12), $pin)
	$g.FillEllipse((Brush $white), 330, 124, 52, 52)
	$g.ResetTransform()
}

$c = New-Icon (Rgb 120 230 170) (Rgb 20 110 90); $g = $c[1]
Draw-Route $g
Save-Icon $c 'navigation-round.png'

$c = New-Icon (Rgb 120 230 170) (Rgb 20 80 120); $g = $c[1]
Draw-Route $g
Draw-Label $g 'PASS' 430 46 (Rgb 255 220 90)
Save-Icon $c 'navigation-pass.png'

# ===== streak buy-back: one icon per price tier (Q7 "buying back a streak") =
# The streak's flame with a rewind arrow curling round it, and the streak
# the tier saves as a big number. No price: the offer card prints it.
function Draw-Flame($g, [float]$cx, [float]$cy, [float]$k, $outer, $inner) {
	# A flame, not a drop: the tip leans right and two licks rise off its
	# shoulders. Points are in a 200-unit box centred on (cx, cy).
	$shape = @(
		@(25, -115), @(40, -70), @(70, -50), @(62, -95), @(95, -40), @(100, 30),
		@(80, 85), @(0, 105), @(-80, 85), @(-100, 25), @(-85, -35), @(-60, -75),
		@(-50, -30), @(-25, -60), @(-10, -95)
	)
	foreach ($layer in @(@(1.0, $outer, 0), @(0.55, $inner, 30))) {
		$s = $k * $layer[0]; $dy = $layer[2] * $k
		$pts = [System.Drawing.PointF[]]($shape | ForEach-Object { Pt ($cx + $_[0] * $s) ($cy + $dy + $_[1] * $s) })
		$f = New-Object System.Drawing.Drawing2D.GraphicsPath
		$f.AddClosedCurve($pts, 0.45)
		if ($layer[0] -eq 1.0) { $g.DrawPath((Pen $ink 12), $f) }
		$g.FillPath((Brush $layer[1]), $f)
	}
}

function Draw-Rewind($g, [float]$cx, [float]$cy, [float]$r) {
	# An arc most of the way round, anticlockwise, ending in a head: "back".
	$g.DrawArc((Pen $ink 30), $cx - $r, $cy - $r, $r * 2, $r * 2, -60, -270)
	$g.DrawArc((Pen $white 16), $cx - $r, $cy - $r, $r * 2, $r * 2, -60, -270)
	# Head at the arc's end (angle -330 = +30 degrees), pointing along it.
	$a = 30 * [Math]::PI / 180
	$ex = $cx + [Math]::Cos($a) * $r; $ey = $cy + [Math]::Sin($a) * $r
	$tx = [Math]::Sin($a); $ty = -[Math]::Cos($a) # anticlockwise tangent
	$nx = [Math]::Cos($a); $ny = [Math]::Sin($a)
	$head = [System.Drawing.PointF[]]@(
		(Pt ($ex + $tx * 46) ($ey + $ty * 46)),
		(Pt ($ex + $nx * 34 - $tx * 10) ($ey + $ny * 34 - $ty * 10)),
		(Pt ($ex - $nx * 34 - $tx * 10) ($ey - $ny * 34 - $ty * 10))
	)
	$g.FillPolygon((Brush $ink), $head)
	$g.DrawPolygon((Pen $ink 10), $head)
	$inset = [System.Drawing.PointF[]]@(
		(Pt ($ex + $tx * 30) ($ey + $ty * 30)),
		(Pt ($ex + $nx * 20 - $tx * 2) ($ey + $ny * 20 - $ty * 2)),
		(Pt ($ex - $nx * 20 - $tx * 2) ($ey - $ny * 20 - $ty * 2))
	)
	$g.FillPolygon((Brush $white), $inset)
}

foreach ($tier in @('1', '2', '3', '4', '5', '6', '7', '8+')) {
	$c = New-Icon (Rgb 255 170 60) (Rgb 150 30 60); $g = $c[1]
	Draw-Rewind $g 256 200 118
	Draw-Flame $g 256 204 0.66 (Rgb 255 120 30) (Rgb 255 220 80)
	Draw-Label $g $tier 404 $(if ($tier.Length -gt 1) { 66 } else { 74 }) (Rgb 255 255 255)
	$name = if ($tier -eq '8+') { 'streak-buy-back-8-plus.png' } else { "streak-buy-back-$tier.png" }
	Save-Icon $c $name
}
