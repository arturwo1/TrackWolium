import os
import struct
import sys
import zipfile

MAGIC = b"WOLIUMPK"


def main(stub, payload_dir, out):
    zip_path = out + ".payload.zip"
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for root, _, files in os.walk(payload_dir):
            for name in sorted(files):
                full = os.path.join(root, name)
                z.write(full, os.path.relpath(full, payload_dir).replace(os.sep, "/"))
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
