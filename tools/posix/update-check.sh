#!/bin/sh
dir=$(cd "$(dirname "$0")" && pwd)
case "$(uname -s)" in
  Darwin)
    data="$HOME/Library/Application Support/DTSys/Wolium"
    asset="Wolium-macos.zip"
    ;;
  *)
    data="${XDG_DATA_HOME:-$HOME/.local/share}/DTSys/Wolium"
    asset="Wolium-linux-x86_64.tar.gz"
    ;;
esac
[ -f "$data/consent" ] || exit 0
[ -f "$data/noupdates" ] && exit 0
current=$(tr -d ' \r\n' < "$dir/version.txt" 2>/dev/null)
[ -n "$current" ] || exit 0
json=$(curl -fsS --max-time 20 -H 'User-Agent: Wolium' -H 'Accept: application/vnd.github+json' https://api.github.com/repos/arturwo1/trackwolium/releases/latest) || exit 0
assets=$(printf '%s' "$json" | tr ',' '\n')
printf '%s' "$assets" | grep -q "\"name\": *\"$asset\"" || exit 0
url=$(printf '%s' "$assets" | grep 'browser_download_url' | grep 'version.txt' | head -n 1 | sed 's/.*"\(https[^"]*\)".*/\1/')
[ -n "$url" ] || exit 0
latest=$(curl -fsSL --max-time 20 "$url" | tr -d ' \r\n')
[ -n "$latest" ] || exit 0
[ "$current" != "$latest" ] || exit 0
top=$(printf '%s\n%s\n' "$current" "$latest" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -n 1)
[ "$top" = "$latest" ] || exit 0
[ "$(cat "$data/update_notified" 2>/dev/null)" = "$latest" ] && exit 0
printf '%s' "$latest" > "$data/update_notified"
lang=$(tr -d ' \r\n' < "$data/lang" 2>/dev/null)
[ -n "$lang" ] || lang=en
text() {
  v=$(awk -F'\t' -v l="$lang" -v k="$1" '$1==l && $2==k {print $3; exit}' "$dir/strings.tsv" 2>/dev/null)
  [ -n "$v" ] || v=$(awk -F'\t' -v k="$1" '$1=="en" && $2==k {print $3; exit}' "$dir/strings.tsv" 2>/dev/null)
  printf '%s' "$v"
}
title=$(text notifUpdateTitle)
body=$(text notifUpdateText | sed "s/%s/$latest/")
yes=$(text updateYes)
later=$(text updateLater)
accept=0
if [ "$(uname -s)" = "Darwin" ]; then
  answer=$(osascript -e "display dialog \"$body\" with title \"$title\" buttons {\"$later\", \"$yes\"} default button \"$yes\" giving up after 300" 2>/dev/null)
  case "$answer" in *"button returned:$yes"*) accept=1 ;; esac
elif command -v zenity >/dev/null 2>&1; then
  zenity --question --title "$title" --text "$body" --ok-label "$yes" --cancel-label "$later" --timeout 300 >/dev/null 2>&1 && accept=1
elif command -v kdialog >/dev/null 2>&1; then
  kdialog --title "$title" --yesno "$body" --yes-label "$yes" --no-label "$later" >/dev/null 2>&1 && accept=1
elif command -v notify-send >/dev/null 2>&1; then
  notify-send "$title" "$body" >/dev/null 2>&1
fi
if [ "$accept" = 1 ]; then
  : > "$data/update_request"
  if [ "$(uname -s)" = "Darwin" ]; then
    open "$(cd "$dir/../.." && pwd)" >/dev/null 2>&1
  else
    nohup "$dir/wolium" >/dev/null 2>&1 &
  fi
fi
exit 0
