import json
import sys
from pathlib import Path

repo = Path(__file__).resolve().parent.parent.parent
keys = ["notifUpdateTitle", "notifUpdateText", "updateYes", "updateLater"]
lines = []
for f in sorted((repo / "i18n" / "translations").glob("*.json")):
    ui = json.loads(f.read_text(encoding="utf-8"))["ui"]
    for k in keys:
        if k in ui:
            lines.append(f"{f.stem}\t{k}\t{ui[k].replace(chr(9), ' ').replace(chr(10), ' ')}")
Path(sys.argv[1]).write_text("\n".join(lines) + "\n", encoding="utf-8")
