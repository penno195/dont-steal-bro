# Cuts the Meshy source art (make-level-art.js -> meshy/) into the three
# level-reward cosmetics' game textures and Locker pictures.
# Run: python assets/cosmetics/make-level-art.py  (needs Pillow)
#
# Trail and nameplate are white on transparent: the game tints them by
# the item's colour (see make-cosmetic-art.ps1). The flair and the
# pictures are full colour.

from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageOps

HERE = Path(__file__).parent
SRC = HERE / "meshy"


def load(name: str) -> Image.Image:
    im = Image.open(SRC / f"{name}.png").convert("RGBA")
    return im.crop(im.getchannel("A").point(lambda a: 255 if a > 24 else 0).getbbox())


def fit_height(im: Image.Image, h: int) -> Image.Image:
    return im.resize((round(im.width * h / im.height), h), Image.LANCZOS)


def white_mask(im: Image.Image) -> Image.Image:
    # Keeps the bright metal and drops the dark grooves and outline, so
    # the stripes stay apart once the game tints them.
    lum = im.convert("L").point(lambda v: 0 if v < 70 else 255 if v > 110 else (v - 70) * 6)
    alpha = ImageChops.multiply(im.getchannel("A"), lum)
    out = Image.new("RGBA", im.size, (255, 255, 255, 0))
    out.putalpha(alpha)
    return out


def rounded(draw: ImageDraw.ImageDraw, box, r, **kw):
    draw.rounded_rectangle(box, r, **kw)


# ===== ClimberTrail: trailTextureAssetId (256x64, white) =====================
# U runs along the trail, V across it: a soft band with chevrons pointing
# the way the player runs, like switchbacks up a slope.
W, H = 256, 64
trail = Image.new("RGBA", (W, H), (255, 255, 255, 0))
band = Image.new("L", (1, H))
for y in range(H):
    d = abs(y - (H - 1) / 2) / ((H - 1) / 2)
    band.putpixel((0, y), round(200 * max(0.0, 1 - d) ** 1.4))
trail.putalpha(band.resize((W, H)))
chev = Image.new("L", (W * 4, H * 4), 0)
cd = ImageDraw.Draw(chev)
for i in range(4):
    x = (i * 64 + 20) * 4
    cd.line([(x, 14 * 4), (x + 22 * 4, 32 * 4), (x, 50 * 4)], fill=255, width=7 * 4, joint="curve")
chev = chev.resize((W, H), Image.LANCZOS).filter(ImageFilter.GaussianBlur(0.6))
trail.putalpha(ImageChops.lighter(trail.getchannel("A"), chev))
trail.save(HERE / "climber-trail.png")

# ===== VeteranNameplate: nameplateFrameAssetId (400x64, white) ===============
# Same 2x layout as gilded-nameplate.png (billboard 200x32, text inset
# 16x6); the Meshy chevron shield (its Locker picture) sits at each end.
S = 4
plate = Image.new("RGBA", (400 * S, 64 * S), (0, 0, 0, 0))
pd = ImageDraw.Draw(plate)
rounded(pd, (3 * S, 3 * S, 397 * S, 61 * S), 10 * S, fill=(0, 0, 0, 120), outline=(255, 255, 255, 255), width=4 * S)
rounded(pd, (10 * S, 10 * S, 390 * S, 54 * S), 6 * S, outline=(255, 255, 255, 150), width=round(1.5 * S))
for x in (130, 270):
    pd.line([(x * S, 3 * S), ((x + 6) * S, 9 * S), ((x + 12) * S, 3 * S)], fill=(255, 255, 255, 255), width=3 * S)
plate = plate.resize((400, 64), Image.LANCZOS)
badge = fit_height(white_mask(load("pic-veteran-frame")), 50)
plate.alpha_composite(badge, (14, 7))
plate.alpha_composite(badge, (400 - 14 - badge.width, 7))
plate.save(HERE / "veteran-nameplate.png")

# ===== OldHandStreakFlair: flairTextureAssetId (640x96, full colour) =========
# Fills the 160x24 streak tag (4x), like wildfire-flair.png: a dark pill
# keeps the counter readable, laurel sprigs reach out from each end.
flair = Image.new("RGBA", (640, 96), (0, 0, 0, 0))
sprig = fit_height(load("old-hand-laurel"), 92)
sprig = sprig.resize((min(sprig.width, 230), 92), Image.LANCZOS)
flair.alpha_composite(sprig, (0, 2))
flair.alpha_composite(ImageOps.mirror(sprig), (640 - sprig.width, 2))
pill = Image.new("RGBA", (640 * 2, 96 * 2), (0, 0, 0, 0))
rounded(ImageDraw.Draw(pill), (300, 28, 980, 164), 68, fill=(28, 10, 44, 235), outline=(192, 132, 252, 230), width=6)
flair.alpha_composite(pill.resize((640, 96), Image.LANCZOS))
flair.save(HERE / "old-hand-flair.png")

# ===== Locker pictures (512x512, full colour) ================================
for src, out in (
    ("pic-climber-trail", "climber-trail-picture.png"),
    ("pic-veteran-frame", "veteran-nameplate-picture.png"),
    ("pic-old-hand", "old-hand-flair-picture.png"),
):
    im = load(src)
    # Background removal also takes any enclosed bright gap (the flame's
    # white-hot core); fill holes the outside can't reach.
    outside = ImageOps.expand(im.getchannel("A").point(lambda a: 0 if a > 24 else 255), 1, 255)
    ImageDraw.floodfill(outside, (0, 0), 128)
    outside = outside.crop((1, 1, im.width + 1, im.height + 1))
    holes = outside.point(lambda v: 255 if v == 255 else 0)
    core = Image.new("RGBA", im.size, (255, 236, 252, 255))
    core.alpha_composite(im)
    im = Image.composite(core, im, holes.filter(ImageFilter.MaxFilter(5)))
    im.thumbnail((472, 472), Image.LANCZOS)
    pic = Image.new("RGBA", (512, 512), (0, 0, 0, 0))
    pic.alpha_composite(im, ((512 - im.width) // 2, (512 - im.height) // 2))
    pic.save(HERE / out)

print("wrote 6 images")
