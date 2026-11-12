import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TRANSLATIONS = ROOT / "i18n" / "translations"
LANG_DIR = ROOT / "i18n" / "include" / "tw" / "lang"
DART_OUT = ROOT / "ui" / "lib" / "lang_data.g.dart"


def load_all():
    data = {}
    for f in sorted(TRANSLATIONS.glob("*.json")):
        data[f.stem] = json.loads(f.read_text(encoding="utf-8"))
    if "en" not in data:
        sys.exit("i18n/translations/en.json is missing")
    return data


def c_escape(text):
    return text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")


def dart_escape(text):
    return text.replace("\\", "\\\\").replace("'", "\\'").replace("$", "\\$").replace("\n", "\\n").replace("\t", "\\t")


def order(data):
    codes = sorted(data, key=lambda c: (c != "en", c != "ru", c))
    return codes


def sync():
    data = load_all()
    en = data["en"]
    codes = order(data)
    LANG_DIR.mkdir(parents=True, exist_ok=True)
    makers = []
    entries = []
    for code in codes:
        d = data[code]
        native = {k: d.get("native", {}).get(k, v) for k, v in en["native"].items()}
        lines = [f'S({k}, L"{c_escape(v)}")' for k, v in native.items()]
        (LANG_DIR / f"{code}.def").write_text("\n".join(lines) + "\n", encoding="utf-8")
        makers.append(
            f"inline Table make_{code}() {{\n  Table x{{}};\n#define S(k, t) x.text[static_cast<int>(Key::k)] = t;\n#include \"{code}.def\"\n#undef S\n  return x;\n}}\n"
        )
        primary = int(d.get("primary", 0))
        entries.append(f'{{"{code}", L"{c_escape(d["name"])}", {primary}u, make_{code}()}},')
    (LANG_DIR / "makers.inc").write_text("\n".join(makers), encoding="utf-8")
    (LANG_DIR / "list.inc").write_text("\n".join(entries) + "\n", encoding="utf-8")
    out = ["const languages = {"]
    for code in codes:
        out.append(f"  '{code}': '{dart_escape(data[code]['name'])}',")
    out.append("};\n")
    out.append("const strings = {")
    for code in codes:
        ui = {k: data[code].get("ui", {}).get(k, v) for k, v in en["ui"].items()}
        out.append(f"  '{code}': {{")
        for k, v in ui.items():
            out.append(f"    '{k}': '{dart_escape(v)}',")
        out.append("  },")
    out.append("};\n")
    DART_OUT.write_text("\n".join(out), encoding="utf-8")
    print("synced:", ", ".join(codes))


def add(code, name, primary):
    if not re.fullmatch(r"[a-z]{2,3}(-[A-Za-z]{2,4})?", code):
        sys.exit("language code must look like de, pt-BR")
    target = TRANSLATIONS / f"{code}.json"
    if target.exists():
        sys.exit(f"{target} already exists")
    en = json.loads((TRANSLATIONS / "en.json").read_text(encoding="utf-8"))
    doc = {"name": name, "primary": primary, "native": en["native"], "ui": en["ui"]}
    target.write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    sync()
    print(f"created {target}")
    print("translate the values in that file, then run: python tools/lang.py sync")


def main(argv):
    if len(argv) >= 2 and argv[1] == "sync":
        sync()
    elif len(argv) >= 4 and argv[1] == "add":
        primary = int(argv[4], 0) if len(argv) > 4 else 0
        add(argv[2], argv[3], primary)
    else:
        print("usage:\n  python tools/lang.py add <code> <Name> [windows_primary_langid]\n  python tools/lang.py sync")
        sys.exit(1)


main(sys.argv)
