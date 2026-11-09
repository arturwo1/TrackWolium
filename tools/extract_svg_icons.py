import os
import re
import sys

COLORS = {
    "--rgb-primary": "#80E0F5",
    "--rgb-bg": "#23272A",
    "--rgb-white": "#FFFFFF",
    "--rgb-dnd": "#F23F43",
    "--rgb-online": "#23A559",
    "--rgb-idle": "#F0B232",
    "--rgb-offline": "#80848E",
    "--rgb-border": "#2B3137",
    "--rgb-secondary": "#ADB0B3",
}
SKIP = {"wolium", "wolium-animate"}


def convert(src, out):
    os.makedirs(out, exist_ok=True)
    text = open(src, encoding="utf-8").read()
    count = 0
    for m in re.finditer(r'<symbol id="([^"]+)" viewBox="([^"]+)">(.*?)</symbol>', text, re.S):
        name, box, body = m.groups()
        if name in SKIP:
            continue
        for var, color in COLORS.items():
            body = body.replace("rgb(var(%s))" % var, color)
        body = body.replace("currentColor", COLORS["--rgb-primary"])
        svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="%s">%s</svg>\n' % (box, body.strip())
        open(os.path.join(out, name + ".svg"), "w", encoding="utf-8").write(svg)
        count += 1
    return count


if __name__ == "__main__":
    print(convert(sys.argv[1], sys.argv[2]))
