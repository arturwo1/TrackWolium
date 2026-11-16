import json
import os
import socket
import sqlite3
import struct
import subprocess
import sys
import tempfile
import threading
import time

core = sys.argv[1]
pid = os.getpid()
failed = []


def run_case(name, setup, extra_env):
  root = tempfile.mkdtemp()
  data = root + "/data"
  runtime = root + "/rt"
  os.makedirs(data)
  os.makedirs(runtime + "/wolium")
  open(data + "/consent", "w").write("1")
  env = {k: v for k, v in os.environ.items() if k not in ("DISPLAY", "SWAYSOCK", "HYPRLAND_INSTANCE_SIGNATURE")}
  env.update(XDG_RUNTIME_DIR=runtime, WAYLAND_DISPLAY="wayland-1")
  env.update(setup(runtime))
  proc = subprocess.Popen([core, "--data-dir", data, "--runtime-dir", runtime + "/wolium", "--interval", "500"], env=env)
  try:
    time.sleep(5)
    open(runtime + "/wolium/flush", "w").close()
    time.sleep(3)
  finally:
    proc.terminate()
    proc.wait()
  rows = sqlite3.connect(data + "/usage.db").execute("select app, state, ms from usage").fetchall()
  focused = [r for r in rows if r[1] == 0 and r[2] > 0]
  if not focused:
    failed.append(name + ": no focused rows " + str(rows))


def serve_forever(path, handler):
  srv = socket.socket(socket.AF_UNIX)
  srv.bind(path)
  srv.listen(8)

  def loop():
    while True:
      conn, _ = srv.accept()
      try:
        handler(conn)
      finally:
        conn.close()

  threading.Thread(target=loop, daemon=True).start()


def hyprland(runtime):
  sig = "test"
  os.makedirs(runtime + "/hypr/" + sig)
  clients = json.dumps([{"address": "0x1", "mapped": True, "hidden": False, "pid": pid, "class": "firefox"}])

  def handle(conn):
    cmd = conn.recv(64).decode()
    conn.sendall((clients if cmd == "j/clients" else json.dumps({"address": "0x1"})).encode())

  serve_forever(runtime + "/hypr/" + sig + "/.socket.sock", handle)
  return {"HYPRLAND_INSTANCE_SIGNATURE": sig}


def sway(runtime):
  path = runtime + "/sway.sock"
  tree = json.dumps({"type": "root", "nodes": [{"type": "workspace", "name": "1", "nodes": [{"type": "con", "pid": pid, "app_id": "foot", "focused": True, "nodes": []}]}]}).encode()

  def handle(conn):
    conn.recv(14)
    conn.sendall(b"i3-ipc" + struct.pack("=II", len(tree), 4) + tree)

  serve_forever(path, handle)
  return {"SWAYSOCK": path}


run_case("hyprland", hyprland, {})
run_case("sway", sway, {})
if failed:
  print("FAIL", failed)
  sys.exit(1)
print("OK")
