import math
import os
import re
import sys
from PIL import Image, ImageDraw

BG = (35, 39, 42, 255)
BORDER = (58, 66, 74, 255)
PRIMARY = (128, 224, 245)
WHITE = (255, 255, 255)
RED = (242, 63, 67, 255)
SIZE = 1024
SS = 2

GLYPH = (
    "m 0,4.5 c 0.5,1.3 1.4,2.5 1.7,3.9 0.4,1.1 0.9,2.2 1.1,3.4 0.2,1.9 1.1,3.5 1.2,5.3 0.3,1.3 0.5,2.7 0.8,4 "
    "0.5,1 0,2.7 1.4,2.9 1.1,-0.6 1.3,-2.2 1.8,-3.2 0.3,-1.5 1,-3 1.6,-4.5 1,-1.5 1.1,-3.4 1.8,-5 1.2,-0.5 0.8,1.4 1.2,2.1 "
    "0.1,1.7 0.6,3.2 1.1,4.8 0.3,1.2 0.6,2.6 1.5,3.4 0.7,0.8 1.9,0.8 2.5,-0.2 0.8,-1.2 1,-2.8 1.7,-4 0.6,-1.1 1.1,-2.2 1.4,-3.5 "
    "0.6,-1.8 1.2,-3.6 1.7,-5.4 0,-1 0.3,-1.9 0.6,-2.9 0,-1.1 0.3,-2.3 0.6,-3.4 0,-0.5 0.6,-2 0,-2.2 -0.7,0.8 -1.8,1.5 -2.2,2.6 "
    "-0.3,2 0,4.1 -0.8,6 -0.2,1 -0.7,2 -0.8,3.1 -0.6,1.9 -1.5,3.7 -2.1,5.6 -0.5,0.8 -0.7,2.5 -1.7,2.5 -0.5,-0.9 -0.9,-2 -1,-3 "
    "C 15.2,15.7 14.9,14.6 14.5,13.6 14.2,12.4 13.9,11.1 13.3,9.9 13.1,8.3 11.2,8.5 10.8,9.9 9.9,11 9.7,12.5 8.9,13.6 "
    "8.4,14.9 8.1,16.2 7.6,17.5 7.3,18.1 7,19.8 6.5,19.7 5.7,18.4 5.6,17 5.6,15.7 5.1,14.3 4.4,12.9 4.3,11.3 4.3,9.7 "
    "3.1,8.4 2.5,7 1.8,6 1.3,4.6 0,4.5 Z"
)


def bezier(p0, p1, p2, p3, steps=24):
    out = []
    for i in range(1, steps + 1):
        t = i / steps
        u = 1 - t
        out.append((
            u ** 3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t ** 3 * p3[0],
            u ** 3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t ** 3 * p3[1],
        ))
    return out


def glyph_points():
    tokens = re.findall(r"[mMcCZ]|-?\d+\.?\d*", GLYPH)
    pts = []
    cur = (0.0, 0.0)
    cmd = None
    i = 0
    while i < len(tokens):
        t = tokens[i]
        if t in "mMcCZ":
            cmd = t
            i += 1
            if t == "Z":
                continue
            continue
        if cmd in "mM":
            x, y = float(tokens[i]), float(tokens[i + 1])
            cur = (x, y) if cmd == "M" or not pts else (cur[0] + x, cur[1] + y)
            pts.append(cur)
            i += 2
            cmd = "l" if cmd == "m" else "L"
        elif cmd in "cC":
            v = [float(tokens[i + k]) for k in range(6)]
            if cmd == "c":
                p1 = (cur[0] + v[0], cur[1] + v[1])
                p2 = (cur[0] + v[2], cur[1] + v[3])
                p3 = (cur[0] + v[4], cur[1] + v[5])
            else:
                p1, p2, p3 = (v[0], v[1]), (v[2], v[3]), (v[4], v[5])
            pts.extend(bezier(cur, p1, p2, p3))
            cur = p3
            i += 6
        else:
            i += 1
    return pts


def gradient_glyph(width):
    pts = glyph_points()
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    minx, maxx, miny, maxy = min(xs), max(xs), min(ys), max(ys)
    scale = width / (maxx - minx)
    gh = int((maxy - miny) * scale) + 2
    gw = int(width) + 2
    big = Image.new("L", (gw * SS, gh * SS), 0)
    d = ImageDraw.Draw(big)
    d.polygon([((x - minx) * scale * SS, (y - miny) * scale * SS) for x, y in pts], fill=255)
    mask = big.resize((gw, gh), Image.LANCZOS)
    grad = Image.new("RGBA", (gw, gh))
    gp = grad.load()
    for y in range(gh):
        f = y / max(1, gh - 1)
        k = 0 if f < 0.6 else (f - 0.6) / 0.4 * 0.8
        col = tuple(int(PRIMARY[c] + (WHITE[c] - PRIMARY[c]) * k) for c in range(3))
        for x in range(gw):
            gp[x, y] = col + (255,)
    grad.putalpha(mask)
    return grad


def base():
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((0, 0, SIZE - 1, SIZE - 1), radius=230, fill=BORDER)
    d.rounded_rectangle((28, 28, SIZE - 29, SIZE - 29), radius=204, fill=BG)
    g = gradient_glyph(660)
    img.alpha_composite(g, ((SIZE - g.width) // 2, (SIZE - g.height) // 2 - 10))
    return img


def badge(img, kind):
    cx, cy, r = 790, 790, 190
    d = ImageDraw.Draw(img)
    d.ellipse((cx - r - 26, cy - r - 26, cx + r + 26, cy + r + 26), fill=BG)
    if kind == "error":
        d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=RED)
    elif kind == "paused":
        d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=PRIMARY + (255,))
        d.rounded_rectangle((cx - 78, cy - 90, cx - 22, cy + 90), radius=14, fill=BG)
        d.rounded_rectangle((cx + 22, cy - 90, cx + 78, cy + 90), radius=14, fill=BG)
    elif kind == "updating":
        d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=PRIMARY + (255,))
        box = (cx - 95, cy - 95, cx + 95, cy + 95)
        d.arc(box, 200, 340, fill=BG, width=36)
        d.arc(box, 20, 160, fill=BG, width=36)
        for ang in (340, 160):
            a = math.radians(ang)
            px, py = cx + 95 * math.cos(a), cy + 95 * math.sin(a)
            t = math.radians(ang + 90)
            tip = (px + 52 * math.cos(t), py + 52 * math.sin(t))
            n = math.radians(ang)
            d.polygon([tip, (px + 40 * math.cos(n), py + 40 * math.sin(n)), (px - 40 * math.cos(n), py - 40 * math.sin(n))], fill=BG)
    return img


def save(img, out, name):
    sizes = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
    img.save(os.path.join(out, name + ".ico"), sizes=sizes)


def main(out):
    os.makedirs(out, exist_ok=True)
    normal = base()
    normal.resize((512, 512), Image.LANCZOS).save(os.path.join(out, "wolium_512.png"))
    normal.resize((256, 256), Image.LANCZOS).save(os.path.join(out, "wolium_256.png"))
    normal.resize((128, 128), Image.LANCZOS).save(os.path.join(out, "wolium_128.png"))
    save(normal, out, "wolium")
    for kind in ("paused", "updating", "error"):
        save(badge(base(), kind), out, "wolium_" + kind)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "assets/icon")
