# Prints "ROOKIE" across the front panel of the Rookie Cap's Meshy texture.
# Meshy can't spell, so the lettering is painted in afterwards: every texel
# on the forward-facing crown (the peak points +z) is mapped back to its 3D
# point, and the word is projected straight on along z, so it reads level.
# Writes models/RookieCapHat/texture-lettered.png, and thumb-lettered.png (a
# simple render that make-wear-pictures.py uses in place of Meshy's thumb).
# Run: python add-cap-lettering.py  (needs numpy + Pillow)
import json, os, struct
import numpy as np
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
DIR = os.path.join(HERE, "models", "RookieCapHat")
WORD, FONT = "ROOKIE", "C:/Windows/Fonts/ariblk.ttf"
TEXT_W, TEXT_CY = 0.74, 0.04  # model units: word width, and its centre height
INK = (255, 255, 255)

# --- mesh -------------------------------------------------------------------
raw = open(os.path.join(DIR, "model.glb"), "rb").read()
jlen = struct.unpack("<I", raw[12:16])[0]
gltf, binary = json.loads(raw[20 : 20 + jlen]), raw[20 + jlen + 8 :]

def accessor(i):
    a = gltf["accessors"][i]
    view = gltf["bufferViews"][a["bufferView"]]
    width = {"VEC3": 3, "VEC2": 2, "SCALAR": 1}[a["type"]]
    dtype = np.float32 if a["componentType"] == 5126 else np.uint32
    offset = view.get("byteOffset", 0) + a.get("byteOffset", 0)
    return np.frombuffer(binary, dtype, a["count"] * width, offset).reshape(-1, width)

attrs = gltf["meshes"][0]["primitives"][0]
P = accessor(attrs["attributes"]["POSITION"]).astype(np.float64)
N = accessor(attrs["attributes"]["NORMAL"]).astype(np.float64)
UV = accessor(attrs["attributes"]["TEXCOORD_0"]).astype(np.float64)
TRI = accessor(attrs["indices"]).reshape(-1, 3)

# --- the word, as a mask over the model's xy plane ---------------------------
font = ImageFont.truetype(FONT, 200)
box = font.getbbox(WORD)
mask = Image.new("L", (box[2] - box[0] + 40, box[3] - box[1] + 40))
ImageDraw.Draw(mask).text((20 - box[0], 20 - box[1]), WORD, font=font, fill=255)
mask = np.asarray(mask, np.float64) / 255
mh, mw = mask.shape
units_per_px = TEXT_W / mw
x0, y0 = -TEXT_W / 2, TEXT_CY + mh * units_per_px / 2  # top-left of the mask

def word_alpha(xy):
    col = ((xy[:, 0] - x0) / units_per_px).astype(int)  # seen from +z, +x is right
    row = ((y0 - xy[:, 1]) / units_per_px).astype(int)
    ok = (col >= 0) & (col < mw) & (row >= 0) & (row < mh)
    out = np.zeros(len(xy))
    out[ok] = mask[row[ok], col[ok]]
    return out

# --- paint it into the texture, triangle by triangle in UV space --------------
tex = np.asarray(Image.open(os.path.join(DIR, "texture.png")).convert("RGB"), np.float64)
H, W = tex.shape[:2]
front = (N[TRI].mean(1)[:, 2] > 0.3) & (P[TRI].mean(1)[:, 2] > 0) & (P[TRI].min(1)[:, 1] > -0.32)
for t in TRI[front]:
    uv = UV[t] * [W, H]
    lo = np.floor(uv.min(0)).astype(int) - 1
    hi = np.ceil(uv.max(0)).astype(int) + 1
    xs, ys = np.meshgrid(np.arange(lo[0], hi[0]) + 0.5, np.arange(lo[1], hi[1]) + 0.5)
    pts = np.stack([xs.ravel(), ys.ravel()], 1)
    (ax, ay), (bx, by), (cx, cy) = uv
    det = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
    if abs(det) < 1e-9:
        continue
    l1 = ((by - cy) * (pts[:, 0] - cx) + (cx - bx) * (pts[:, 1] - cy)) / det
    l2 = ((cy - ay) * (pts[:, 0] - cx) + (ax - cx) * (pts[:, 1] - cy)) / det
    bary = np.stack([l1, l2, 1 - l1 - l2], 1)
    inside = (bary > -0.05).all(1)  # a little bleed so UV seams don't show
    pts, bary = pts[inside], bary[inside]
    a = word_alpha(bary @ P[t][:, :2])
    px = np.clip(pts.astype(int), 0, [W - 1, H - 1])
    hit = a > 0
    px, a = px[hit], a[hit, None]
    tex[px[:, 1], px[:, 0]] = tex[px[:, 1], px[:, 0]] * (1 - a) + np.array(INK) * a
Image.fromarray(tex.astype(np.uint8)).save(os.path.join(DIR, "texture-lettered.png"))
print("wrote texture-lettered.png")

# --- a quick render for the tile picture (orthographic, front three-quarter) --
S = 1024
yaw, pitch = np.radians(-30), np.radians(22)
Ry = np.array([[np.cos(yaw), 0, np.sin(yaw)], [0, 1, 0], [-np.sin(yaw), 0, np.cos(yaw)]])
Rx = np.array([[1, 0, 0], [0, np.cos(pitch), -np.sin(pitch)], [0, np.sin(pitch), np.cos(pitch)]])
R = Rx @ Ry
V, VN = P @ R.T, N @ R.T
scale = S * 0.42
sx, sy = S / 2 + V[:, 0] * scale, S / 2 - V[:, 1] * scale
img = np.zeros((S, S, 4))
zbuf = np.full((S, S), -np.inf)
light = np.array([-0.4, 0.6, 0.7]) / np.linalg.norm([-0.4, 0.6, 0.7])
for t in TRI:
    X, Y = sx[t], sy[t]
    lo = np.maximum(np.floor([X.min(), Y.min()]).astype(int), 0)
    hi = np.minimum(np.ceil([X.max(), Y.max()]).astype(int) + 1, S)
    if (hi <= lo).any():
        continue
    xs, ys = np.meshgrid(np.arange(lo[0], hi[0]) + 0.5, np.arange(lo[1], hi[1]) + 0.5)
    det = (Y[1] - Y[2]) * (X[0] - X[2]) + (X[2] - X[1]) * (Y[0] - Y[2])
    if abs(det) < 1e-9:
        continue
    l1 = ((Y[1] - Y[2]) * (xs - X[2]) + (X[2] - X[1]) * (ys - Y[2])) / det
    l2 = ((Y[2] - Y[0]) * (xs - X[2]) + (X[0] - X[2]) * (ys - Y[2])) / det
    l3 = 1 - l1 - l2
    inside = (l1 >= 0) & (l2 >= 0) & (l3 >= 0)
    if not inside.any():
        continue
    b = np.stack([l1[inside], l2[inside], l3[inside]], 1)
    z = b @ V[t][:, 2]
    iy, ix = ys[inside].astype(int), xs[inside].astype(int)
    near = z > zbuf[iy, ix]
    if not near.any():
        continue
    b, z, iy, ix = b[near], z[near], iy[near], ix[near]
    zbuf[iy, ix] = z
    uv = b @ UV[t]
    colour = tex[np.clip((uv[:, 1] * H).astype(int), 0, H - 1), np.clip((uv[:, 0] * W).astype(int), 0, W - 1)]
    n = b @ VN[t]
    n /= np.linalg.norm(n, axis=1, keepdims=True) + 1e-9
    n[n[:, 2] < 0] *= -1  # double-sided: light the inside too
    shade = 0.55 + 0.5 * np.clip(n @ light, 0, 1)
    img[iy, ix, :3] = np.clip(colour * shade[:, None], 0, 255)
    img[iy, ix, 3] = 255
Image.fromarray(img.astype(np.uint8), "RGBA").resize((512, 512), Image.LANCZOS).save(
    os.path.join(DIR, "thumb-lettered.png")
)
print("wrote thumb-lettered.png")
