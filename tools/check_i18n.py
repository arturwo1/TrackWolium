import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TRANSLATIONS = ROOT / "i18n" / "translations"
DYNAMIC_UI = ["now", "focused", "open", "minimized", "background", "total"]
SKIP_DART = {"lang_data.g.dart"}
CPP_DIRS = ["app", "app_win", "app_linux", "ui_console", "platform", "capi", "core", "ipc", "storage", "installer"]


def balanced(text, start):
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return text[start : i + 1]
    return text[start:]


def dart_keys():
    found = {}
    for f in sorted((ROOT / "ui" / "lib").glob("*.dart")):
        if f.name in SKIP_DART:
            continue
        text = f.read_text(encoding="utf-8")
        for m in re.finditer(r"(?<![A-Za-z0-9_])tr\(", text):
            call = balanced(text, m.end() - 1)
            for lit in re.findall(r"""['"]([A-Za-z][A-Za-z0-9_]*)['"]""", call):
                found.setdefault(lit, f.name)
        if f.name == "updater.dart":
            for lit in re.findall(r":\s*'(us[A-Za-z0-9_]+)'", text):
                found.setdefault(lit, f.name)
    for k in DYNAMIC_UI:
        found.setdefault(k, "dynamic")
    return found


def cpp_keys():
    found = {}
    for d in CPP_DIRS:
        base = ROOT / d
        if not base.exists():
            continue
        for f in base.rglob("*"):
            if f.suffix not in (".cpp", ".hpp", ".mm", ".h") or "build" in f.parts:
                continue
            text = f.read_text(encoding="utf-8", errors="ignore")
            for lit in re.findall(r"\bKey::([A-Za-z][A-Za-z0-9_]*)", text):
                found.setdefault(lit, str(f.relative_to(ROOT)))
    return found


def main():
    langs = {f.stem: json.loads(f.read_text(encoding="utf-8")) for f in sorted(TRANSLATIONS.glob("*.json"))}
    errors = []
    en = langs["en"]
    for code, d in langs.items():
        for section in ("ui", "native"):
            for k in en[section]:
                if k not in d.get(section, {}):
                    errors.append(f"{code}.json: section {section} lacks key {k}")
            for k in d.get(section, {}):
                if k not in en[section]:
                    errors.append(f"{code}.json: section {section} has unknown key {k}")
        for k in d:
            if k not in ("name", "primary", "native", "ui"):
                errors.append(f"{code}.json: stray top-level key {k}")
        for section in ("ui", "native"):
            for k, v in d.get(section, {}).items():
                if not isinstance(v, str) or not v.strip():
                    errors.append(f"{code}.json: empty value {section}.{k}")
    for key, where in dart_keys().items():
        for code, d in langs.items():
            if key not in d["ui"]:
                errors.append(f"{where}: tr('{key}') missing in {code}.json ui")
    for key, where in cpp_keys().items():
        for code, d in langs.items():
            if key not in d["native"]:
                errors.append(f"{where}: Key::{key} missing in {code}.json native")
    gen = (ROOT / "ui" / "lib" / "lang_data.g.dart")
    if gen.exists():
        gtext = gen.read_text(encoding="utf-8")
        for code, d in langs.items():
            for k in d["ui"]:
                if f"'{k}':" not in gtext:
                    errors.append(f"lang_data.g.dart is stale: {k} (run tools/lang.py sync)")
                    break
    if errors:
        print("\n".join(sorted(set(errors))))
        print(f"{len(set(errors))} translation problem(s)")
        sys.exit(1)
    print("translations ok:", ", ".join(langs))


main()
