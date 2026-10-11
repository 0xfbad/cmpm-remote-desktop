#!/bin/bash
set -Eeuo pipefail

set_wallpaper() {
  local file index wallpaper
  local -a wallpapers=()
  shopt -s nullglob
  for file in /usr/share/backgrounds/remote-desktop/*; do
    [[ -f $file && -r $file ]] || continue
    case "${file,,}" in
    *.png | *.jpg | *.jpeg | *.svg) wallpapers+=("$file") ;;
    esac
  done
  if ((${#wallpapers[@]} == 0)); then
    echo "no readable images in the remote desktop wallpaper pool" >&2
    return 1
  fi
  index=$(shuf -i "0-$((${#wallpapers[@]} - 1))" -n 1)
  wallpaper=${wallpapers[$index]}

  local backdrop=/backdrop/screen0/monitorVNC-0/workspace0
  xfconf-query --channel xfce4-desktop --property "$backdrop/last-image" \
    --create --type string --set "$wallpaper"
  xfconf-query --channel xfce4-desktop --property "$backdrop/image-style" \
    --create --type int --set 5
  xfconf-query --channel xfce4-desktop --property "$backdrop/backdrop-cycle-enable" \
    --create --type bool --set false
  xfconf-query --channel xfce4-desktop --property /backdrop/single-workspace-mode \
    --create --type bool --set true
  xfconf-query --channel xfce4-desktop --property /backdrop/single-workspace-number \
    --create --type int --set 0
  printf 'session wallpaper: %s\n' "$wallpaper"
}

if [[ ${1:-} == --set-wallpaper ]]; then
  set_wallpaper
  exit 0
fi

if ! timeout --kill-after=1s 5s /bin/bash "$0" --set-wallpaper; then # xfdesktop reads background settings during startup
  echo "wallpaper setup failed; continuing with the XFCE background settings" >&2
fi
exec xfce4-session
