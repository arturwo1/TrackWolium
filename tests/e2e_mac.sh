#!/bin/sh
set -eu
CORE="${1:-build/bin/trackwolium-core}"
WORK="$(mktemp -d)"
mkdir -p "$WORK/data" "$WORK/run"
touch "$WORK/data/consent"
open -a TextEdit || true
sleep 4
(while :; do touch "$WORK/run/ui.alive"; sleep 2; done) &
KEEP=$!
"$CORE" --data-dir "$WORK/data" --runtime-dir "$WORK/run" --interval 300 &
CORE_PID=$!
sleep 8
touch "$WORK/run/flush"
sleep 1
cat "$WORK/run/live" || true
kill -TERM "$CORE_PID"
wait "$CORE_PID" || true
kill "$KEEP" 2>/dev/null || true
osascript -e 'tell application "TextEdit" to quit' >/dev/null 2>&1 || true
python3 - "$WORK/data/usage.db" "$WORK/data/icons" <<'PY'
import os, sqlite3, sys
rows = {(a, s): ms for a, s, ms in sqlite3.connect(sys.argv[1]).execute("select app, state, sum(ms) from usage group by app, state")}
print(rows)
visible = [a for (a, s), ms in rows.items() if s < 3 and ms >= 1000]
print("visible apps:", visible)
failures = []
if not any(a.lower() == "textedit" for a in visible): failures.append("TextEdit was never seen with a window")
if not any(s == 0 and ms >= 1000 for (a, s), ms in rows.items()): failures.append("no app was ever focused")
print("icons:", os.listdir(sys.argv[2]) if os.path.isdir(sys.argv[2]) else "none")
if failures:
    print("FAIL:", "; ".join(failures))
    sys.exit(1)
print("e2e ok")
PY
