#!/bin/sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
dest="${XDG_DATA_HOME:-$HOME/.local/share}/wolium-app"
if [ "${1:-}" = "--update" ]; then
  pkill -f "$dest/trackwolium-core" 2>/dev/null || true
  sleep 1
fi
apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
rm -rf "$dest"
mkdir -p "$dest" "$apps" "$HOME/.local/bin"
cp -r "$here/app/." "$dest/"
chmod +x "$dest/wolium" "$dest/trackwolium-core" "$dest/update-check.sh"
ln -sf "$dest/wolium" "$HOME/.local/bin/wolium"
cp "$here/wolium.png" "$dest/wolium.png"
cat > "$apps/wolium.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Wolium
Exec=$dest/wolium
Icon=$dest/wolium.png
Categories=Utility;
Terminal=false
DESKTOP
echo "Wolium installed: $dest"
if [ "${1:-}" = "--update" ]; then
  nohup "$dest/trackwolium-core" >/dev/null 2>&1 &
  nohup "$dest/wolium" >/dev/null 2>&1 &
fi
