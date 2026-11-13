#!/bin/sh
dest="${XDG_DATA_HOME:-$HOME/.local/share}/wolium-app"
pkill -f "$dest/trackwolium-core" 2>/dev/null || true
rm -rf "$dest" "${XDG_DATA_HOME:-$HOME/.local/share}/applications/wolium.desktop" "$HOME/.local/bin/wolium"
rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/autostart/wolium.desktop"
echo "Wolium removed. Data kept in ${XDG_DATA_HOME:-$HOME/.local/share}/DTSys/Wolium"
