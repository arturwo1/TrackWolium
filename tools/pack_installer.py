import os
import struct
import sys
import zipfile

MAGIC = b"WOLIUMPK"


def main(stub, payload_dir, out):
    zip_path = out + ".payload.zip"
    entries = []
    for root, _, files in os.walk(payload_dir):
        for name in sorted(files):
            full = os.path.join(root, name)
            entries.append((full, os.path.relpath(full, payload_dir).replace(os.sep, "/")))
    entries.sort(key=lambda e: e[1])
    manifest = "\n".join(rel for _, rel in entries if rel != "manifest.txt") + "\n"
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for full, rel in entries:
            z.write(full, rel)
        z.writestr("manifest.txt", manifest)
    size = os.path.getsize(zip_path)
    with open(out, "wb") as o:
        with open(stub, "rb") as s:
            o.write(s.read())
        with open(zip_path, "rb") as z:
            o.write(z.read())
        o.write(struct.pack("<Q", size) + MAGIC)
    os.remove(zip_path)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit("usage: pack_installer.py STUB PAYLOAD_DIR OUT")
    main(*sys.argv[1:])
