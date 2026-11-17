import os
import sqlite3
import subprocess
import sys
import tempfile
import time

core = os.path.abspath(sys.argv[1])
if len(sys.argv) > 2 and sys.argv[2] == "inner":
  root = tempfile.mkdtemp()
  data = root + "/data"
  runtime = root + "/rt"
  os.makedirs(data)
  os.makedirs(runtime)
  open(data + "/consent", "w").write("1")
  env = {k: v for k, v in os.environ.items() if k != "DISPLAY"}
  env.update(WAYLAND_DISPLAY="wayland-1", XDG_CURRENT_DESKTOP="GNOME")
  proc = subprocess.Popen([core, "--data-dir", data, "--runtime-dir", runtime, "--interval", "500"], env=env)
  payload = '{"windows":[{"pid":%d,"class":"org.test.App","active":true,"minimized":false}]}' % os.getpid()
  end = time.time() + 12
  while time.time() < end:
    subprocess.run(["dbus-send", "--session", "--print-reply", "--dest=org.wolium.Bridge", "/org/wolium/Bridge", "org.wolium.Bridge.Report", "string:" + payload], capture_output=True)
    time.sleep(1)
  open(runtime + "/flush", "w").close()
  time.sleep(3)
  proc.terminate()
  proc.wait()
  rows = sqlite3.connect(data + "/usage.db").execute("select app, state, ms from usage").fetchall()
  focused = [r for r in rows if r[1] == 0 and r[2] > 0]
  if not focused:
    print("FAIL", rows)
    sys.exit(1)
  print("OK")
else:
  sys.exit(subprocess.call(["dbus-run-session", "--", sys.executable, os.path.abspath(__file__), core, "inner"]))
