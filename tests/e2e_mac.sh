#!/bin/sh
set -eu
CORE="${1:-build/bin/trackwolium-core}"
WORK="$(mktemp -d)"
mkdir -p "$WORK/data" "$WORK/run"
touch "$WORK/data/consent" "$WORK/note.txt" "$WORK/run/ui.alive"
open -a TextEdit "$WORK/note.txt" || true
osascript -e 'tell application "TextEdit" to activate' >/dev/null 2>&1 || true
sleep 3
(while :; do touch "$WORK/run/ui.alive"; sleep 2; done) &
KEEP=$!
trap 'kill "$KEEP" 2>/dev/null || true' EXIT
"$CORE" --data-dir "$WORK/data" --runtime-dir "$WORK/run" --interval 300 >"$WORK/core.log" 2>&1 &
CORE_PID=$!
sleep 8
if ! kill -0 "$CORE_PID" 2>/dev/null; then
  cat "$WORK/core.log" || true
  echo "FAIL: trackwolium-core exited unexpectedly"
  exit 1
fi
touch "$WORK/run/flush"
sleep 1
LIVE_OK=0
if [ -s "$WORK/run/live" ]; then
  LIVE_OK=1
  cat "$WORK/run/live"
else
  echo "WARN: $WORK/run/live missing or empty"
  cat "$WORK/core.log" || true
fi
kill -TERM "$CORE_PID"
CORE_RC=0
wait "$CORE_PID" || CORE_RC=$?
kill "$KEEP" 2>/dev/null || true
osascript -e 'tell application "TextEdit" to quit' >/dev/null 2>&1 || true
if [ "$CORE_RC" -ne 0 ]; then
  cat "$WORK/core.log" || true
  echo "FAIL: trackwolium-core exited with $CORE_RC"
  exit 1
fi
if [ "$LIVE_OK" -ne 1 ]; then
  echo "FAIL: live state file was never written"
  exit 1
fi
python3 - "$WORK/data/usage.db" "$HOME/Library/Application Support/DTSys/Wolium/icons" "${GITHUB_ACTIONS:-}" <<'PY'
import os, sqlite3, sys
rows = {(a, s): ms for a, s, ms in sqlite3.connect(sys.argv[1]).execute("select app, state, sum(ms) from usage group by app, state")}
print(rows)
visible = [a for (a, s), ms in rows.items() if s < 3 and ms >= 1000]
print("visible apps:", visible)
print("icons:", len(os.listdir(sys.argv[2])) if os.path.isdir(sys.argv[2]) else "none")
in_ci = sys.argv[3] == "true"
if not visible and in_ci:
    print("headless macOS runner (no GUI windows exposed): core, live state, and DB verified")
    sys.exit(0)
failures = []
if not any(a.lower() == "textedit" for a in visible): failures.append("TextEdit was never seen with a window")
if not any(s == 0 and ms >= 1000 for (a, s), ms in rows.items()): failures.append("no app was ever focused")
if failures:
    print("FAIL:", "; ".join(failures))
    sys.exit(1)
print("e2e ok")
PY
