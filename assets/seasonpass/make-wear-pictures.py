# Turns each Meshy thumbnail (models/<Name>/thumb.png, transparent) into a
# 512x512 pass tile picture wear-<name>.png next to this file, with the same
# thick ink outline and drop shadow as make-art.js so it reads on both the
# gold and blue tiles. Run: python make-wear-pictures.py  (needs Pillow)
import os
from PIL import Image, ImageFilter, ImageChops

HERE = os.path.dirname(os.path.abspath(__file__))
INK = (0x1A, 0x10, 0x30)
S, PAD, OUTLINE = 512, 40, 10
NAMES = {
    "LootSackBack": "back-loot-sack",
    "BurglarBeanieHat": "hat-burglar-beanie",
    "TrafficConeHat": "hat-traffic-cone",
    "GameShowTopHat": "hat-game-show-top-hat",
    "GoldBarJetpack": "back-gold-bar-jetpack",
    "CorvusCrestPack": "back-corvus-crest-pack",
    "DiamondHeistCrown": "hat-diamond-heist-crown",
    "VaultDoorShield": "back-vault-door-shield",
}

for folder, out in NAMES.items():
    im = Image.open(os.path.join(HERE, "models", folder, "thumb.png")).convert("RGBA")
    a = im.getchannel("A").point(lambda v: 255 if v > 40 else 0)
    im = im.crop(a.getbbox())
    fit = S - 2 * PAD
    k = fit / max(im.size)
    im = im.resize((round(im.width * k), round(im.height * k)), Image.LANCZOS)
    obj = Image.new("RGBA", (S, S))
    obj.paste(im, ((S - im.width) // 2, (S - im.height) // 2))
    alpha = obj.getchannel("A").point(lambda v: 255 if v > 40 else 0)
    ring = alpha.filter(ImageFilter.MaxFilter(2 * OUTLINE + 1))
    shadow = ImageChops.offset(ring, 0, 12).point(lambda v: v * 0.3)
    canvas = Image.new("RGBA", (S, S))
    canvas.paste(Image.new("RGBA", (S, S), (0, 0, 0, 255)), mask=shadow)
    canvas.paste(Image.new("RGBA", (S, S), INK + (255,)), mask=ring)
    canvas.alpha_composite(obj)
    canvas.save(os.path.join(HERE, f"wear-{out}.png"))
    print("wrote", f"wear-{out}.png")
