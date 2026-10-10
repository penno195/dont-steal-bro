# Store icons for the limited-edition cosmetics: the item's outlined
# picture (assets/seasonpass/wear-*.png) on the store's purple sunburst,
# with a gold LIMITED tag. 512x512, opaque, the important part inside the
# middle ~70% (Roblox crops product icons to a circle).
# Run: python assets/store/make-limited-icons.py  (needs Pillow)
import math
import os
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
WEAR = os.path.join(HERE, "..", "seasonpass")
S = 512
ITEMS = {
    "limited-diamond-heist-crown": "wear-hat-diamond-heist-crown.png",
    "limited-vault-door-shield": "wear-back-vault-door-shield.png",
}


def background():
    img = Image.new("RGB", (S, S))
    px = img.load()
    for y in range(S):
        for x in range(S):
            t = (x + y) / (2 * S)
            px[x, y] = (int(0x8A - 0x50 * t), int(0x3F - 0x25 * t), int(0xE0 - 0x70 * t))
    rays = Image.new("RGBA", (S, S))
    d = ImageDraw.Draw(rays)
    c = S / 2
    for i in range(16):
        a = i * math.pi / 8
        d.polygon(
            [(c, c), (c + 800 * math.cos(a), c + 800 * math.sin(a)), (c + 800 * math.cos(a + 0.2), c + 800 * math.sin(a + 0.2))],
            fill=(255, 255, 255, 22),
        )
    img = img.convert("RGBA")
    img.alpha_composite(rays)
    return img


def tag(img):
    d = ImageDraw.Draw(img)
    font = ImageFont.truetype("segoeuib.ttf", 44)
    text = "LIMITED"
    w = d.textlength(text, font=font)
    x0, y0, x1, y1 = (S - w) / 2 - 26, 404, (S + w) / 2 + 26, 462
    d.rounded_rectangle((x0, y0 + 5, x1, y1 + 5), 18, fill=(0x1A, 0x10, 0x30))
    d.rounded_rectangle((x0, y0, x1, y1), 18, fill=(0xFF, 0xC9, 0x3C), outline=(0x1A, 0x10, 0x30), width=5)
    d.text((S / 2, (y0 + y1) / 2 + 1), text, font=font, fill=(0x2A, 0x11, 0x00), anchor="mm")


for key, wear in ITEMS.items():
    img = background()
    item = Image.open(os.path.join(WEAR, wear)).convert("RGBA").resize((380, 380), Image.LANCZOS)
    img.alpha_composite(item, ((S - 380) // 2, 30))
    tag(img)
    out = os.path.join(HERE, key + ".png")
    img.convert("RGB").save(out)
    print("wrote", out)
