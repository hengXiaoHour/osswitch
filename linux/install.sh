#!/usr/bin/env bash
# install.sh - put the osswitch Linux half where GNOME can find it.
#
#   ./install.sh              install the command and both desktop launchers
#   ./install.sh -DryRun      print what would happen, change nothing
#   ./install.sh -Remove      take all of it back out again
#
# Installs into the per-user locations only ($HOME/.local): nothing is written
# system-wide and no privilege is needed to install. The switch itself asks for
# a password at the moment it runs, through pkexec, and only for that.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")
BIN_DIR="$HOME/.local/bin"
APP_DIR="$HOME/.local/share/applications"
ICON_DIR="$HOME/.local/share/icons/hicolor"

DRY=0
REMOVE=0
for arg in "$@"; do
  case "$arg" in
    -DryRun|--dry-run) DRY=1 ;;
    -Remove|--remove)  REMOVE=1 ;;
    -h|--help)         sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'install.sh: unknown option %s\n' "$arg" >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
do_it() {
  if (( DRY )); then printf 'would: %s\n' "$*"; return 0; fi
  "$@"
}

need() {
  command -v "$1" >/dev/null 2>&1 || { printf 'install.sh: %s is required\n' "$1" >&2; exit 1; }
}
need install
need mkdir

FILES=("$BIN_DIR/osswitch"
       "$APP_DIR/osswitch-windows.desktop"
       "$APP_DIR/osswitch-manjaro.desktop"
       "$ICON_DIR/48x48/apps/osswitch-windows.png"
       "$ICON_DIR/256x256/apps/osswitch-windows.png"
       "$ICON_DIR/48x48/apps/osswitch-manjaro.png"
       "$ICON_DIR/256x256/apps/osswitch-manjaro.png")

if (( REMOVE )); then
  say "Removing osswitch:"
  for f in "${FILES[@]}"; do
    if [[ -e $f ]]; then do_it rm -f "$f"; say "  removed $f"; fi
  done
  if (( DRY )); then say "(dry run - nothing was deleted)"; else
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APP_DIR" || true
    command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -f -t "$ICON_DIR" >/dev/null 2>&1 || true
    say "Done. The boot order was never modified by any of this."
  fi
  exit 0
fi

say "Installing the osswitch Linux half:"
do_it mkdir -p "$BIN_DIR" "$APP_DIR" "$ICON_DIR/48x48/apps" "$ICON_DIR/256x256/apps"

# The launcher needs an absolute path, and the spec's own placeholder for the
# home directory (%h) is deprecated - desktop-file-validate rejects it outright.
# So the .desktop.in templates are rendered here instead.
do_it install -m 0755 "$HERE/osswitch" "$BIN_DIR/osswitch"
for which in windows manjaro; do
  do_it install -m 0644 "$HERE/osswitch-$which.desktop.in" \
                "$APP_DIR/osswitch-$which.desktop"
  if (( DRY )); then
    printf 'would: render @HOME@ -> %s in %s\n' "$HOME" "$APP_DIR/osswitch-$which.desktop"
  else
    sed -i "s|@HOME@|$HOME|g" "$APP_DIR/osswitch-$which.desktop"
  fi
done

# Icons come from the artwork the Windows half already uses, so both launchers
# look the same on both systems. ImageMagick is optional: without it the 512px
# originals are installed at both sizes and GNOME scales them.
for which in windows manjaro; do
  src="$REPO/assets/$which-512.png"
  [[ -f $src ]] || { printf 'install.sh: missing artwork %s\n' "$src" >&2; exit 1; }
  for size in 48 256; do
    dest="$ICON_DIR/${size}x${size}/apps/osswitch-$which.png"
    if command -v magick >/dev/null 2>&1; then
      do_it magick "$src" -resize "${size}x${size}" "$dest"
    elif command -v convert >/dev/null 2>&1; then
      do_it convert "$src" -resize "${size}x${size}" "$dest"
    else
      do_it cp "$src" "$dest"
    fi
  done
done

if (( DRY )); then
  say "(dry run - nothing was written)"
  exit 0
fi

command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APP_DIR" || true
command -v gtk-update-icon-cache   >/dev/null 2>&1 && gtk-update-icon-cache -f -t "$ICON_DIR" >/dev/null 2>&1 || true

say ""
say "Installed:"
say "  $BIN_DIR/osswitch"
say "  two launchers: 'Switch to Windows 11' and 'Switch to Manjaro'"
say ""
if command -v zenity >/dev/null 2>&1; then
  say "Dialog tool: zenity"
elif command -v yad >/dev/null 2>&1; then
  say "Dialog tool: yad"
else
  say "WARNING: neither zenity nor yad is installed."
  say "         The launchers need one of them - to ask before rebooting, and to"
  say "         show a failure. With neither, they refuse to switch rather than"
  say "         restart the machine without asking."
  say "         Install one with:  sudo pacman -S zenity"
fi
say ""
say "Try it before you trust it:"
say "  osswitch status"
say "  osswitch windows --dry-run     # applies, verifies, does NOT reboot"
say "  osswitch restore               # drop the pending switch"
