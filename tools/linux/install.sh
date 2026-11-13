#!/bin/sh
set -e
here=$(cd "$(dirname "$0")" && pwd)
dest="${XDG_DATA_HOME:-$HOME/.local/share}/wolium-app"
apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
rm -rf "$dest"
mkdir -p "$dest" "$apps" "$HOME/.local/bin"
cp -r "$here/app/." "$dest/"
chmod +x "$dest/wolium" "$dest/trackwolium-core"
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
