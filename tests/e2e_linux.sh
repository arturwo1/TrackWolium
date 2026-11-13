#!/bin/sh
set -eu
CORE="${1:-build/bin/trackwolium-core}"
WORK="$(mktemp -d)"
export DISPLAY=:97
Xvfb :97 -screen 0 1024x768x24 >/dev/null 2>&1 &
XVFB=$!
sleep 1
openbox >/dev/null 2>&1 &
sleep 1
xclock >/dev/null 2>&1 &
sleep 0.5
xeyes >/dev/null 2>&1 &
sleep 1
CLOCK_WIN=$(xdotool search --class xclock | head -n 1)
EYES_WIN=$(xdotool search --class xeyes | head -n 1)
xdotool mousemove 100 100 click 1
xdotool windowfocus "$CLOCK_WIN"
sleep 0.5
mkdir -p "$WORK/data" "$WORK/run"
touch "$WORK/data/consent"
"$CORE" --data-dir "$WORK/data" --runtime-dir "$WORK/run" --interval 300 &
CORE_PID=$!
sleep 3
xdotool windowfocus "$EYES_WIN"
sleep 3
xdotool windowminimize "$CLOCK_WIN"
sleep 3
touch "$WORK/run/flush"
sleep 1
cat "$WORK/run/live" || true
kill -TERM "$CORE_PID"
wait "$CORE_PID" || true
kill "$XVFB" 2>/dev/null || true
python3 - "$WORK/data/usage.db" <<'PY'
import sqlite3, sys
rows = {(a, s): ms for a, s, ms in sqlite3.connect(sys.argv[1]).execute("select app, state, sum(ms) from usage group by app, state")}
print(rows)
def has(app, state, minimum=1000):
    return any(a == app and s == state and ms >= minimum for (a, s), ms in rows.items())
failures = []
if not has("xclock", 0): failures.append("xclock was never focused")
if not has("xeyes", 0): failures.append("xeyes was never focused")
if not has("xclock", 1): failures.append("xclock was never open (unfocused)")
if not has("xclock", 2): failures.append("xclock was never minimized")
if failures:
    print("FAIL:", "; ".join(failures))
    sys.exit(1)
print("e2e ok")
PY
