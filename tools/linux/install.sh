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
data="${XDG_DATA_HOME:-$HOME/.local/share}"
if [ -d "$here/bridge" ] && [ -n "${WAYLAND_DISPLAY:-}" ]; then
  case "${XDG_CURRENT_DESKTOP:-}" in
    *GNOME*)
      ext="$data/gnome-shell/extensions/wolium-bridge@dtsys"
      rm -rf "$ext"
      mkdir -p "$ext"
      cp "$here/bridge/gnome/"* "$ext/"
      gnome-extensions enable wolium-bridge@dtsys 2>/dev/null || true
      echo "GNOME: log out and back in once, then run: gnome-extensions enable wolium-bridge@dtsys"
      ;;
    *KDE*)
      kde="$data/kwin/scripts/wolium-bridge"
      rm -rf "$kde"
      mkdir -p "$kde"
      cp -r "$here/bridge/kde/." "$kde/"
      kwriteconfig6 --file kwinrc --group Plugins --key wolium-bridgeEnabled true 2>/dev/null || true
      dbus-send --session --type=method_call --dest=org.kde.KWin /KWin org.kde.KWin.reconfigure 2>/dev/null || true
      echo "KDE: KWin script installed"
      ;;
  esac
fi
echo "Wolium installed: $dest"
if [ "${1:-}" = "--update" ]; then
  nohup "$dest/trackwolium-core" >/dev/null 2>&1 &
  nohup "$dest/wolium" >/dev/null 2>&1 &
fi
