# Draws the placeholder cosmetics' art (next-stages step 10) into
# assets/cosmetics/, ready to upload in Creator Hub. Re-run to regenerate:
#   powershell -ExecutionPolicy Bypass -File scripts/make-cosmetic-art.ps1
#
# Tinted textures (trail, podium, nameplate, reveal, burst) are drawn white
# on transparent: the game multiplies them by the item's colour, so any hue
# drawn here would muddy it. The card, flair and clothing are full colour.

Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = 'Stop'

$out = Join-Path $PSScriptRoot '..\assets\cosmetics'
New-Item -ItemType Directory -Force $out | Out-Null

function New-Canvas([int]$w, [int]$h) {
	$bmp = New-Object System.Drawing.Bitmap $w, $h, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
	$g = [System.Drawing.Graphics]::FromImage($bmp)
	$g.SmoothingMode = 'AntiAlias'
	$g.TextRenderingHint = 'AntiAliasGridFit'
	$g.Clear([System.Drawing.Color]::Transparent)
	return @($bmp, $g)
}

function Save-Canvas($canvas, [string]$name) {
	$canvas[1].Dispose()
	$canvas[0].Save((Join-Path $out $name), [System.Drawing.Imaging.ImageFormat]::Png)
	$canvas[0].Dispose()
	Write-Output "wrote $name"
}

function Rgb([int]$r, [int]$g, [int]$b, [int]$a = 255) { [System.Drawing.Color]::FromArgb($a, $r, $g, $b) }

function Rounded-Path([float]$x, [float]$y, [float]$w, [float]$h, [float]$r) {
	$p = New-Object System.Drawing.Drawing2D.GraphicsPath
	$d = $r * 2
	$p.AddArc($x, $y, $d, $d, 180, 90)
	$p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
	$p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
	$p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
	$p.CloseFigure()
	return $p
}

# A four-point sparkle centred on (cx, cy).
function Star-Points([float]$cx, [float]$cy, [float]$long, [float]$short) {
	$pts = @()
	for ($i = 0; $i -lt 8; $i++) {
		$a = [Math]::PI / 4 * $i - [Math]::PI / 2
		$r = if ($i % 2 -eq 0) { $long } else { $short }
		$pts += New-Object System.Drawing.PointF ([float]($cx + [Math]::Cos($a) * $r)), ([float]($cy + [Math]::Sin($a) * $r))
	}
	return [System.Drawing.PointF[]]$pts
}

function Soft-Glow($g, [float]$cx, [float]$cy, [float]$r, [int]$alpha) {
	$path = New-Object System.Drawing.Drawing2D.GraphicsPath
	$path.AddEllipse($cx - $r, $cy - $r, $r * 2, $r * 2)
	$brush = New-Object System.Drawing.Drawing2D.PathGradientBrush $path
	$brush.CenterColor = Rgb 255 255 255 $alpha
	$brush.SurroundColors = [System.Drawing.Color[]]@((Rgb 255 255 255 0))
	$g.FillPath($brush, $path)
}

$white = New-Object System.Drawing.SolidBrush (Rgb 255 255 255)

# ===== FounderTrail: trailTextureAssetId (256x64, white) =====================
# U runs along the trail, V across it: a soft-edged band with sparkles.
$c = New-Canvas 256 64; $g = $c[1]
$band = New-Object System.Drawing.Drawing2D.LinearGradientBrush (New-Object System.Drawing.Rectangle 0, 0, 256, 64), (Rgb 255 255 255 0), (Rgb 255 255 255 0), 90
$blend = New-Object System.Drawing.Drawing2D.ColorBlend 5
$blend.Colors = [System.Drawing.Color[]]@((Rgb 255 255 255 0), (Rgb 255 255 255 120), (Rgb 255 255 255 230), (Rgb 255 255 255 120), (Rgb 255 255 255 0))
$blend.Positions = [single[]]@(0, 0.25, 0.5, 0.75, 1)
$band.InterpolationColors = $blend
$g.FillRectangle($band, 0, 0, 256, 64)
$rng = New-Object System.Random 7
for ($i = 0; $i -lt 14; $i++) {
	$x = $rng.Next(8, 248); $y = $rng.Next(10, 54); $s = $rng.Next(4, 9)
	Soft-Glow $g $x $y ($s * 1.6) 160
	$g.FillPolygon($white, (Star-Points $x $y $s ($s / 4)))
}
Save-Canvas $c 'founder-trail.png'

# ===== ChampionPodiumFlare: podiumTextureAssetId (128x128, white) ============
$c = New-Canvas 128 128; $g = $c[1]
Soft-Glow $g 64 64 60 170
$g.FillPolygon($white, (Star-Points 64 64 58 9))
$g.FillPolygon($white, (Star-Points 64 64 26 6))
Save-Canvas $c 'podium-sparkle.png'

# ===== GildedNameplate: nameplateFrameAssetId (400x64, white) ================
# The billboard is 200x32 with text inset 16x6, so this is 2x. The dark fill
# survives the gold tint and keeps the title readable.
$c = New-Canvas 400 64; $g = $c[1]
$outer = Rounded-Path 3 3 394 58 14
$g.FillPath((New-Object System.Drawing.SolidBrush (Rgb 0 0 0 120)), $outer)
$g.DrawPath((New-Object System.Drawing.Pen (Rgb 255 255 255), 4), $outer)
$g.DrawPath((New-Object System.Drawing.Pen (Rgb 255 255 255 170), 1.5), (Rounded-Path 10 10 380 44 9))
foreach ($x in 15, 385) {
	$diamond = [System.Drawing.PointF[]]@(
		(New-Object System.Drawing.PointF $x, 18), (New-Object System.Drawing.PointF ($x + 12), 32),
		(New-Object System.Drawing.PointF $x, 46), (New-Object System.Drawing.PointF ($x - 12), 32))
	$g.FillPolygon($white, $diamond)
}
foreach ($x in 120, 280) { $g.FillPolygon($white, (Star-Points $x 3 7 2)); $g.FillPolygon($white, (Star-Points $x 61 7 2)) }
Save-Canvas $c 'gilded-nameplate.png'

# ===== SorryNotSorryCard: cardImageAssetId (256x256, full colour) ============
$c = New-Canvas 256 256; $g = $c[1]
$card = Rounded-Path 6 6 244 244 28
$bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush (New-Object System.Drawing.Rectangle 0, 0, 256, 256), (Rgb 255 92 92), (Rgb 150 20 40), 60
$g.FillPath($bg, $card)
$g.DrawPath((New-Object System.Drawing.Pen (Rgb 255 255 255), 6), $card)
# Smirking face.
$g.FillEllipse((New-Object System.Drawing.SolidBrush (Rgb 255 206 60)), 68, 62, 120, 120)
$g.DrawEllipse((New-Object System.Drawing.Pen (Rgb 120 60 0), 4), 68, 62, 120, 120)
$ink = New-Object System.Drawing.Pen (Rgb 70 35 0), 7
$ink.StartCap = 'Round'; $ink.EndCap = 'Round'
$g.DrawLine($ink, 94, 106, 116, 104)   # half-lidded eyes
$g.DrawLine($ink, 142, 102, 164, 100)
$g.DrawBezier($ink, 100, 146, 120, 152, 146, 150, 164, 132)   # one-sided smirk
$font = New-Object System.Drawing.Font 'Arial Black', 26, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
$centre = New-Object System.Drawing.StringFormat
$centre.Alignment = 'Center'
$shadow = New-Object System.Drawing.SolidBrush (Rgb 60 0 10 160)
foreach ($line in @(@('SORRY', 18), @('NOT SORRY', 194))) {
	$g.DrawString($line[0], $font, $shadow, (New-Object System.Drawing.RectangleF 2, ($line[1] + 3), 256, 40), $centre)
	$g.DrawString($line[0], $font, $white, (New-Object System.Drawing.RectangleF 0, $line[1], 256, 40), $centre)
}
Save-Canvas $c 'sorry-not-sorry-card.png'

# ===== VaultDoorReveal: revealTextureAssetId (128x128, white) ================
# A vault door's face: rim, bolts and spoked handle wheel.
$c = New-Canvas 128 128; $g = $c[1]
$g.DrawEllipse((New-Object System.Drawing.Pen (Rgb 255 255 255), 9), 10, 10, 108, 108)
for ($i = 0; $i -lt 12; $i++) {
	$a = [Math]::PI / 6 * $i
	$g.FillEllipse($white, 64 + [Math]::Cos($a) * 46 - 4, 64 + [Math]::Sin($a) * 46 - 4, 8, 8)
}
$spoke = New-Object System.Drawing.Pen (Rgb 255 255 255), 6
$spoke.StartCap = 'Round'; $spoke.EndCap = 'Round'
for ($i = 0; $i -lt 3; $i++) {
	$a = [Math]::PI / 3 * $i + 0.3
	$dx = [Math]::Cos($a) * 30; $dy = [Math]::Sin($a) * 30
	$g.DrawLine($spoke, 64 - $dx, 64 - $dy, 64 + $dx, 64 + $dy)
	$g.FillEllipse($white, 64 + $dx - 6, 64 + $dy - 6, 12, 12)
	$g.FillEllipse($white, 64 - $dx - 6, 64 - $dy - 6, 12, 12)
}
$g.FillEllipse($white, 52, 52, 24, 24)
Save-Canvas $c 'vault-door.png'

# ===== RubberDuckProjectile: explosionTextureAssetId (128x128, white) ========
# A little duck silhouette; the burst tints it the power-up's role colour.
$c = New-Canvas 128 128; $g = $c[1]
Soft-Glow $g 64 70 62 90
$g.FillEllipse($white, 22, 58, 84, 50)     # body
$g.FillEllipse($white, 62, 22, 42, 42)     # head
$g.FillPolygon($white, [System.Drawing.PointF[]]@(
	(New-Object System.Drawing.PointF 100, 38), (New-Object System.Drawing.PointF 122, 46), (New-Object System.Drawing.PointF 100, 54)))   # beak
$g.FillPolygon($white, [System.Drawing.PointF[]]@(
	(New-Object System.Drawing.PointF 26, 76), (New-Object System.Drawing.PointF 8, 56), (New-Object System.Drawing.PointF 30, 64)))   # tail
$eye = New-Object System.Drawing.SolidBrush (Rgb 0 0 0 0)
$g.CompositingMode = 'SourceCopy'
$g.FillEllipse($eye, 84, 34, 8, 8)
Save-Canvas $c 'duck-burst.png'

# ===== WildfireStreakFlair: flairTextureAssetId (640x96, full colour) ========
# Fills the 160x24 streak tag (4x). Flames lick round a dark pill so the
# orange number on top stays readable.
$c = New-Canvas 640 96; $g = $c[1]
$rng = New-Object System.Random 11
$fire = New-Object System.Drawing.Drawing2D.LinearGradientBrush (New-Object System.Drawing.Rectangle 0, 0, 640, 96), (Rgb 255 230 90), (Rgb 200 30 0), 90
for ($i = 0; $i -lt 26; $i++) {
	$x = 12 + $i * 24 + $rng.Next(-6, 6)
	$h = if ($x -lt 140 -or $x -gt 500) { $rng.Next(60, 90) } else { $rng.Next(26, 44) }
	$w = $rng.Next(26, 40)
	$p = New-Object System.Drawing.Drawing2D.GraphicsPath
	$p.AddBezier([float]($x - $w / 2), 96, [float]($x - $w / 2), [float](96 - $h * 0.6), [float]($x + $w / 3), [float](96 - $h * 0.7), [float]$x, [float](96 - $h))
	$p.AddBezier([float]$x, [float](96 - $h), [float]($x + $w / 2), [float](96 - $h * 0.55), [float]($x + $w / 2), [float](96 - $h * 0.3), [float]($x + $w / 2), 96)
	$p.CloseFigure()
	$g.FillPath($fire, $p)
}
$g.FillPath((New-Object System.Drawing.SolidBrush (Rgb 30 8 0 230)), (Rounded-Path 150 14 340 68 34))
$g.DrawPath((New-Object System.Drawing.Pen (Rgb 255 140 30 220), 3), (Rounded-Path 150 14 340 68 34))
Save-Canvas $c 'wildfire-flair.png'

# ===== FounderSkin: shirtAssetId / pantsAssetId (585x559 classic templates) ==
# The whole sheet is filled so a misjudged face edge never shows skin.
$ink = Rgb 22 22 28
$gold = New-Object System.Drawing.SolidBrush (Rgb 212 175 55)
$goldPen = New-Object System.Drawing.Pen (Rgb 212 175 55), 5

function Crown($g, [float]$cx, [float]$cy, [float]$s) {
	$pts = [System.Drawing.PointF[]]@(
		(New-Object System.Drawing.PointF ($cx - $s), ($cy + $s * 0.6)), (New-Object System.Drawing.PointF ($cx - $s), ($cy - $s * 0.5)),
		(New-Object System.Drawing.PointF ($cx - $s * 0.5), $cy), (New-Object System.Drawing.PointF $cx, ($cy - $s * 0.8)),
		(New-Object System.Drawing.PointF ($cx + $s * 0.5), $cy), (New-Object System.Drawing.PointF ($cx + $s), ($cy - $s * 0.5)),
		(New-Object System.Drawing.PointF ($cx + $s), ($cy + $s * 0.6)))
	$g.FillPolygon($gold, $pts)
}

# Shirt: torso faces y 74-202 (R 165, F 231, L 361, B 427); arm rows y 355-483.
$c = New-Canvas 585 559; $g = $c[1]
$g.Clear($ink)
$g.DrawLines($goldPen, [System.Drawing.PointF[]]@(
	(New-Object System.Drawing.PointF 263, 74), (New-Object System.Drawing.PointF 295, 108), (New-Object System.Drawing.PointF 327, 74)))   # V collar
Crown $g 295 148 26
$tiny = New-Object System.Drawing.Font 'Arial Black', 11, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
$g.DrawString('FOUNDER', $tiny, $gold, (New-Object System.Drawing.RectangleF 231, 172, 128, 20), $centre)
Crown $g 491 120 18                                        # back
$g.FillRectangle($gold, 165, 192, 390, 8)                  # hem, all four faces
$g.FillRectangle($gold, 19, 468, 256, 8)                   # right arm cuff
$g.FillRectangle($gold, 308, 468, 262, 8)                  # left arm cuff
Save-Canvas $c 'founder-shirt.png'

# Pants: belt along the torso faces' top; a stripe down each leg's outside
# (right leg's R face at 151, left leg's L face at 374).
$c = New-Canvas 585 559; $g = $c[1]
$g.Clear($ink)
$g.FillRectangle($gold, 165, 74, 390, 10)
$g.FillRectangle((New-Object System.Drawing.SolidBrush $ink), 285, 76, 20, 6)
$g.DrawRectangle((New-Object System.Drawing.Pen (Rgb 212 175 55), 2), 284, 73, 22, 12)   # buckle
$g.FillRectangle($gold, 178, 355, 10, 128)
$g.FillRectangle($gold, 401, 355, 10, 128)
Save-Canvas $c 'founder-pants.png'

# ===== RubberDuckProjectile: projectileMeshAssetId (OBJ) =====================
# Ellipsoids for body, head, beak and tail. Y up, beak toward -Z (Roblox's
# LookVector), so a projectile aimed along its velocity flies beak-first.
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# Rubber duck projectile, generated by scripts/make-cosmetic-art.ps1')
$script:base = 0
function Add-Ellipsoid([double]$cx, [double]$cy, [double]$cz, [double]$rx, [double]$ry, [double]$rz) {
	$rings = 12; $segs = 16
	for ($i = 0; $i -le $rings; $i++) {
		$phi = [Math]::PI * $i / $rings
		for ($j = 0; $j -lt $segs; $j++) {
			$th = 2 * [Math]::PI * $j / $segs
			$x = $cx + $rx * [Math]::Sin($phi) * [Math]::Cos($th)
			$y = $cy + $ry * [Math]::Cos($phi)
			$z = $cz + $rz * [Math]::Sin($phi) * [Math]::Sin($th)
			$lines.Add(('v {0:F4} {1:F4} {2:F4}' -f $x, $y, $z).Replace(',', '.'))
		}
	}
	for ($i = 0; $i -lt $rings; $i++) {
		for ($j = 0; $j -lt $segs; $j++) {
			$a = $script:base + $i * $segs + $j + 1
			$b = $script:base + $i * $segs + (($j + 1) % $segs) + 1
			# Counter-clockwise seen from outside: Roblox culls back faces.
			$lines.Add("f $a $b $($b + $segs) $($a + $segs)")
		}
	}
	$script:base += ($rings + 1) * $segs
}
Add-Ellipsoid 0 0 0 1.0 0.7 1.3        # body
Add-Ellipsoid 0 0.9 -0.75 0.55 0.55 0.55   # head
Add-Ellipsoid 0 0.82 -1.3 0.3 0.1 0.28    # beak
Add-Ellipsoid 0 0.4 1.15 0.4 0.3 0.3      # tail
[System.IO.File]::WriteAllLines((Join-Path $out 'rubber-duck.obj'), $lines)
Write-Output 'wrote rubber-duck.obj'
