import os
import sys
from PIL import Image, ImageDraw

BG = (35, 39, 42, 255)
BORDER = (58, 66, 74, 255)
FG = (128, 224, 245, 255)
SIZE = 1024


def render():
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((0, 0, SIZE - 1, SIZE - 1), radius=230, fill=BORDER)
    d.rounded_rectangle((28, 28, SIZE - 29, SIZE - 29), radius=204, fill=BG)
    pts = [(214, 300), (338, 740), (512, 420), (686, 740), (810, 300)]
    w = 92
    d.line(pts, fill=FG, width=w, joint="curve")
    for x, y in (pts[0], pts[-1]):
        d.ellipse((x - w // 2, y - w // 2, x + w // 2, y + w // 2), fill=FG)
    return img


def main(out):
    os.makedirs(out, exist_ok=True)
    big = render()
    big.resize((512, 512), Image.LANCZOS).save(os.path.join(out, "wolium_512.png"))
    big.resize((256, 256), Image.LANCZOS).save(os.path.join(out, "wolium_256.png"))
    big.resize((128, 128), Image.LANCZOS).save(os.path.join(out, "wolium_128.png"))
    sizes = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
    big.save(os.path.join(out, "wolium.ico"), sizes=sizes)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "assets/icon")
