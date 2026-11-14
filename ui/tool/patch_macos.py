import plistlib
import sys
from pathlib import Path

root = Path(sys.argv[1])
icon = Path(sys.argv[2])
runner = root / "macos" / "Runner"

for name in ("DebugProfile.entitlements", "Release.entitlements"):
    path = runner / name
    if not path.exists():
        continue
    data = plistlib.loads(path.read_bytes())
    data["com.apple.security.app-sandbox"] = False
    data["com.apple.security.network.client"] = True
    path.write_bytes(plistlib.dumps(data))

xcconfig = runner / "Configs" / "AppInfo.xcconfig"
if xcconfig.exists():
    lines = [l for l in xcconfig.read_text(encoding="utf-8").splitlines() if not l.startswith("PRODUCT_NAME")]
    lines.append("PRODUCT_NAME = Wolium")
    xcconfig.write_text("\n".join(lines) + "\n", encoding="utf-8")

try:
    from PIL import Image

    src = Image.open(icon).convert("RGBA")
    target = runner / "Assets.xcassets" / "AppIcon.appiconset"
    for size in (16, 32, 64, 128, 256, 512, 1024):
        src.resize((size, size), Image.LANCZOS).save(target / f"app_icon_{size}.png")
except ImportError:
    pass
