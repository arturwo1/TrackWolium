import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
icon = Path(sys.argv[2])
here = Path(__file__).resolve().parent
repo = here.parent.parent
main_dir = root / "android" / "app" / "src" / "main"

manifest = main_dir / "AndroidManifest.xml"
text = manifest.read_text(encoding="utf-8")
if "xmlns:tools" not in text:
    text = text.replace("<manifest ", '<manifest xmlns:tools="http://schemas.android.com/tools" ', 1)
perms = [
    '<uses-permission android:name="android.permission.PACKAGE_USAGE_STATS" tools:ignore="ProtectedPermissions"/>',
    '<uses-permission android:name="android.permission.QUERY_ALL_PACKAGES"/>',
    '<uses-permission android:name="android.permission.INTERNET"/>',
    '<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>',
    '<uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES"/>',
]
for p in perms:
    name = re.search(r'android:name="([^"]+)"', p).group(1)
    if name not in text:
        text = re.sub(r"(<manifest[^>]*>)", lambda m: m.group(1) + "\n    " + p, text, count=1)
text = re.sub(r'android:label="[^"]*"', 'android:label="Wolium"', text, count=1)
if "allowBackup" not in text:
    text = text.replace("<application", '<application android:allowBackup="true"', 1)
if "FileProvider" not in text:
    provider = (
        '        <provider android:name="androidx.core.content.FileProvider" android:authorities="${applicationId}.fileprovider" '
        'android:exported="false" android:grantUriPermissions="true">\n'
        '            <meta-data android:name="android.support.FILE_PROVIDER_PATHS" android:resource="@xml/file_paths"/>\n'
        "        </provider>\n"
    )
    text = text.replace("</application>", provider + "    </application>", 1)
manifest.write_text(text, encoding="utf-8")

xml_dir = main_dir / "res" / "xml"
xml_dir.mkdir(parents=True, exist_ok=True)
(xml_dir / "file_paths.xml").write_text(
    '<?xml version="1.0" encoding="utf-8"?>\n<paths>\n    <cache-path name="cache" path="."/>\n</paths>\n',
    encoding="utf-8",
)

kt = next(main_dir.glob("kotlin/**/MainActivity.kt"))
package = re.search(r"^package\s+(\S+)", kt.read_text(encoding="utf-8"), re.M).group(1)
kt.write_text((here / "android" / "MainActivity.kt.tpl").read_text(encoding="utf-8").replace("__PACKAGE__", package), encoding="utf-8")
(kt.parent / "SyncWorker.kt").write_text((here / "android" / "SyncWorker.kt.tpl").read_text(encoding="utf-8").replace("__PACKAGE__", package), encoding="utf-8")

merged = {}
for f in sorted((repo / "i18n" / "translations").glob("*.json")):
    merged[f.stem] = json.loads(f.read_text(encoding="utf-8"))["ui"]
assets = main_dir / "assets"
assets.mkdir(parents=True, exist_ok=True)
(assets / "strings.json").write_text(json.dumps(merged, ensure_ascii=False), encoding="utf-8")

app_gradle = root / "android" / "app" / "build.gradle.kts"
g = app_gradle.read_text(encoding="utf-8")
g = g.replace("versionCode = flutter.versionCode", 'versionCode = (System.getenv("WOLIUM_BUILD") ?: "").toIntOrNull() ?: flutter.versionCode')
g = g.replace("versionName = flutter.versionName", 'versionName = System.getenv("WOLIUM_VERSION") ?: flutter.versionName')
if "WOLIUM_KEYSTORE" not in g:
    signing = (
        "    signingConfigs {\n"
        '        create("wolium") {\n'
        '            val ks = System.getenv("WOLIUM_KEYSTORE")\n'
        "            if (ks != null) {\n"
        "                storeFile = file(ks)\n"
        '                storePassword = System.getenv("WOLIUM_KEYSTORE_PASSWORD")\n'
        '                keyAlias = System.getenv("WOLIUM_KEY_ALIAS")\n'
        '                keyPassword = System.getenv("WOLIUM_KEYSTORE_PASSWORD")\n'
        "            }\n"
        "        }\n"
        "    }\n\n"
    )
    g = g.replace("    buildTypes {", signing + "    buildTypes {", 1)
    g = re.sub(
        r'signingConfig = signingConfigs\.getByName\("debug"\)',
        'signingConfig = if (System.getenv("WOLIUM_KEYSTORE") != null) signingConfigs.getByName("wolium") else signingConfigs.getByName("debug")',
        g,
        count=1,
    )
g += '\ndependencies {\n    implementation("androidx.work:work-runtime-ktx:2.9.1")\n    implementation("androidx.core:core-ktx:1.13.1")\n}\n'
app_gradle.write_text(g, encoding="utf-8")

root_gradle = root / "android" / "build.gradle.kts"
gtext = root_gradle.read_text(encoding="utf-8")
if "lintVital" not in gtext:
    gtext += """
subprojects {
  tasks.configureEach {
    if (name.startsWith("lintVital")) enabled = false
  }
}
"""
    root_gradle.write_text(gtext, encoding="utf-8")

try:
    from PIL import Image

    src = Image.open(icon).convert("RGBA")
    for name, size in (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)):
        target = main_dir / "res" / f"mipmap-{name}"
        target.mkdir(parents=True, exist_ok=True)
        src.resize((size, size), Image.LANCZOS).save(target / "ic_launcher.png")
except ImportError:
    pass
