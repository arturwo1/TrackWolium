#!/bin/sh
dir=$(cd "$(dirname "$0")" && pwd)
case "$(uname -s)" in
  Darwin)
    data="$HOME/Library/Application Support/DTSys/Wolium"
    cache="$HOME/Library/Caches/DTSys/Wolium"
    asset="Wolium-macos.zip"
    ;;
  *)
    data="${XDG_DATA_HOME:-$HOME/.local/share}/DTSys/Wolium"
    cache="${XDG_CACHE_HOME:-$HOME/.cache}/DTSys/Wolium"
    asset="Wolium-linux-x86_64.tar.gz"
    ;;
esac
lang=$(cat "$data/lang" 2>/dev/null | tr -d ' \r\n')
[ -n "$lang" ] || lang=en
text() {
  v=$(awk -F'\t' -v l="$lang" -v k="$1" '$1==l && $2==k {print $3; exit}' "$dir/strings.tsv" 2>/dev/null)
  [ -n "$v" ] || v=$(awk -F'\t' -v k="$1" '$1=="en" && $2==k {print $3; exit}' "$dir/strings.tsv" 2>/dev/null)
  printf '%s' "$v"
}
notify() {
  if [ "$(uname -s)" = "Darwin" ]; then
    osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "$1" "$2" >/dev/null 2>&1
  fi
}
if [ "$1" = "--done" ]; then
  version=$(cat "$dir/version.txt" 2>/dev/null | tr -d ' \r\n')
  rm -rf "$cache"
  rm -f "$data/update.ready"
  if [ "$2" = "silent" ] && [ -n "$version" ]; then
    notify "$(text notifUpdatedTitle)" "$(text notifUpdatedText | sed "s/%s/$version/")"
  fi
  exit 0
fi
[ -f "$data/consent" ] || exit 0
[ -f "$data/noupdates" ] && exit 0
current=$(cat "$dir/version.txt" 2>/dev/null | tr -d ' \r\n')
[ -n "$current" ] || exit 0
latest=$(curl -fsSL --max-time 20 -H 'User-Agent: Wolium' https://github.com/arturwo1/trackwolium/releases/latest/download/version.txt | tr -d ' \r\n')
printf '%s' "$latest" | grep -Eq '^[0-9]+(\.[0-9]+)*$' || exit 0
[ "$current" != "$latest" ] || exit 0
top=$(printf '%s\n%s\n' "$current" "$latest" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -n 1)
[ "$top" = "$latest" ] || exit 0
mkdir -p "$cache"
file="$cache/$latest-$asset"
if [ ! -s "$file" ] || [ "$(head -n 1 "$data/update.ready" 2>/dev/null)" != "$latest" ]; then
  find "$cache" -type f -delete 2>/dev/null
  curl -fsSL --max-time 900 -H 'User-Agent: Wolium' -o "$file.part" "https://github.com/arturwo1/trackwolium/releases/latest/download/$asset" || { rm -f "$file.part"; exit 0; }
  size=$(wc -c < "$file.part" | tr -d ' ')
  [ "${size:-0}" -gt 1048576 ] || { rm -f "$file.part"; exit 0; }
  mv "$file.part" "$file"
  printf '%s\n%s\n' "$latest" "$file" > "$data/update.ready"
fi
if pgrep -u "$(id -u)" -ix wolium >/dev/null 2>&1; then
  if [ "$(cat "$data/update_notified" 2>/dev/null)" != "$latest" ]; then
    printf '%s' "$latest" > "$data/update_notified"
    notify "$(text notifReadyTitle)" "$(text notifReadyText | sed "s/%s/$latest/")"
  fi
  exit 0
fi
work=$(mktemp -d)
if [ "$(uname -s)" = "Darwin" ]; then
  ditto -x -k "$file" "$work" || exit 0
  [ -d "$work/Wolium.app" ] || exit 0
  bundle=$(cd "$dir/../.." && pwd)
  case "$bundle" in *.app) ;; *) exit 0 ;; esac
  nohup sh -c 'sleep 1; pkill -f "$2/Contents/MacOS/trackwolium-core"; sleep 1; rm -rf "$2" && mv "$1" "$2" && xattr -dr com.apple.quarantine "$2"; nohup "$2/Contents/MacOS/trackwolium-core" >/dev/null 2>&1 & sleep 3; sh "$2/Contents/MacOS/update-check.sh" --done silent' wolium "$work/Wolium.app" "$bundle" >/dev/null 2>&1 &
else
  tar -xzf "$file" -C "$work" || exit 0
  [ -f "$work/wolium-linux/install.sh" ] || exit 0
  nohup sh "$work/wolium-linux/install.sh" --silent >/dev/null 2>&1 &
fi
exit 0
