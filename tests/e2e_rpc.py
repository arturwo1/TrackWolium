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
import urllib.request

core = sys.argv[1]
root = tempfile.mkdtemp()
data = root + "/data"
runtime = root + "/rt"
os.makedirs(data)
os.makedirs(runtime + "/wolium")
for name in ("consent", "localapi", "discordrpc"):
  open(data + "/" + name, "w").write("1")

upstream = socket.socket(socket.AF_UNIX)
upstream.bind(runtime + "/discord-ipc-1")
upstream.listen(1)
received = []


def serve():
  conn, _ = upstream.accept()
  while True:
    chunk = conn.recv(4096)
    if not chunk:
      break
    received.append(chunk)
    conn.sendall(chunk)


threading.Thread(target=serve, daemon=True).start()
env = dict(os.environ, XDG_RUNTIME_DIR=runtime)
proc = subprocess.Popen([core, "--data-dir", data, "--runtime-dir", runtime + "/wolium", "--interval", "500"], env=env)


def frame(op, payload):
  body = json.dumps(payload).encode()
  return struct.pack("<II", op, len(body)) + body


failed = []
try:
  time.sleep(6)
  client = socket.socket(socket.AF_UNIX)
  client.connect(runtime + "/discord-ipc-0")
  client.sendall(frame(0, {"v": 1, "client_id": "123456789012345678"}))
  client.sendall(frame(1, {"cmd": "SET_ACTIVITY", "args": {"pid": 5, "activity": {"details": "Song X", "state": "by Y", "timestamps": {"start": 1700000000}}}}))
  client.settimeout(3)
  if not client.recv(4096):
    failed.append("no echo through proxy")
  if not received:
    failed.append("upstream received nothing")
  body = urllib.request.urlopen("http://127.0.0.1:9095/v1/current", timeout=3).read()
  if b'"apps"' not in body:
    failed.append("local api")
  time.sleep(5)
  if open(data + "/discordrpc.status").read() != "active":
    failed.append("status")
finally:
  proc.terminate()
  proc.wait()

rows = sqlite3.connect(data + "/usage.db").execute("select details, state from presence").fetchall()
if ("Song X", "by Y") not in rows:
  failed.append("presence not stored")
if failed:
  print("FAIL", failed)
  sys.exit(1)
print("OK")
