#!/usr/bin/env bash
# ==============================================================================
# Motion Wallpaper Installer for Omarchy / Hyprland
#
# Installs:
#   ~/.local/bin/motion-wallpaper-toggle             runtime script
#   ~/.local/share/applications/motion-wallpaper-toggle.desktop   app entry
#   ~/.config/systemd/user/motion-wallpaper.service  optional autostart unit
#
# Dependencies:
#   mpv, jq, zenity (pacman)
#   mpvpaper (AUR, via yay or paru)
#   libnotify (pacman) — optional, for notify-send
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Motion wallpaper installer for Omarchy / Hyprland ==="

if ! command -v pacman >/dev/null 2>&1; then
  echo "This script expects a pacman-based system (Arch/Omarchy). Aborting." >&2
  exit 1
fi

# ----- source files ------------------------------------------------------------

TOGGLE_SRC="$SCRIPT_DIR/motion-wallpaper-toggle"
WATCHER_SRC="$SCRIPT_DIR/motion-wallpaper-watcher"
UNIT_SRC="$SCRIPT_DIR/motion-wallpaper.service"
ICON_SRC="$SCRIPT_DIR/icons/motion-wallpaper.svg"

for f in "$TOGGLE_SRC" "$WATCHER_SRC" "$UNIT_SRC" "$ICON_SRC"; do
  if [ ! -f "$f" ]; then
    echo "Missing installer asset: $f" >&2
    exit 1
  fi
done

# ----- dependencies ------------------------------------------------------------

# Check what's already there so we don't invoke sudo when nothing needs doing.
MISSING_REPO=()
for cmd in mpv jq gum socat notify-send; do
  command -v "$cmd" >/dev/null 2>&1 || MISSING_REPO+=("$cmd")
done
# notify-send maps to libnotify; translate for the pacman call below.
MISSING_PKGS=()
for cmd in "${MISSING_REPO[@]}"; do
  case "$cmd" in
    notify-send) MISSING_PKGS+=("libnotify") ;;
    *)           MISSING_PKGS+=("$cmd")      ;;
  esac
done

if [ "${#MISSING_PKGS[@]}" -gt 0 ]; then
  echo "Installing required packages: ${MISSING_PKGS[*]}"
  sudo pacman -S --needed "${MISSING_PKGS[@]}"
else
  echo "✓ Repo dependencies already installed (mpv, jq, gum, socat, libnotify)"
fi

if command -v mpvpaper >/dev/null 2>&1; then
  echo "✓ mpvpaper already installed"
else
  echo
  echo "Installing mpvpaper from AUR..."

  AUR_HELPER=""
  if command -v yay  >/dev/null 2>&1; then AUR_HELPER="yay"
  elif command -v paru >/dev/null 2>&1; then AUR_HELPER="paru"
  fi

  if [ -n "$AUR_HELPER" ]; then
    echo "Using $AUR_HELPER to install mpvpaper..."
    "$AUR_HELPER" -S --needed mpvpaper
  else
    cat >&2 <<'MSG'

ERROR: No AUR helper (yay/paru) found.

Install one first, then re-run this installer:

  sudo pacman -S --needed base-devel git
  git clone https://aur.archlinux.org/yay.git
  cd yay && makepkg -si

MSG
    exit 1
  fi

  if ! command -v mpvpaper >/dev/null 2>&1; then
    echo "ERROR: mpvpaper is not installed. Cannot continue." >&2
    exit 1
  fi
fi

# ----- install files -----------------------------------------------------------

install -D -m 755 "$TOGGLE_SRC"  "$HOME/.local/bin/motion-wallpaper-toggle"
install -D -m 755 "$WATCHER_SRC" "$HOME/.local/bin/motion-wallpaper-watcher"

# Install custom SVG icon into the hicolor theme — Walker and other XDG-aware
# launchers will find it by name (Icon=motion-wallpaper) without needing a
# full path in the .desktop entry.
ICON_DIR="$HOME/.local/share/icons/hicolor/scalable/apps"
install -D -m 644 "$ICON_SRC" "$ICON_DIR/motion-wallpaper.svg"

# Refresh the icon cache if gtk-update-icon-cache is available. Harmless if
# not — launchers that read SVGs directly will pick it up regardless.
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -q "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
fi

mkdir -p "$HOME/.local/share/applications"
cat > "$HOME/.local/share/applications/motion-wallpaper-toggle.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Motion Wallpaper
Comment=Toggle animated video wallpaper on/off (TUI)
Exec=$HOME/.local/bin/motion-wallpaper-toggle
Icon=motion-wallpaper
Terminal=true
Categories=Utility;Settings;DesktopSettings;
Keywords=wallpaper;video;animated;background;
EOF

# Poke the desktop database so launchers re-index immediately.
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database -q "$HOME/.local/share/applications" 2>/dev/null || true
fi

install -D -m 644 "$UNIT_SRC" "$HOME/.config/systemd/user/motion-wallpaper.service"
systemctl --user daemon-reload >/dev/null 2>&1 || true

# Walker's data provider (Elephant) caches the desktop index in memory. Nudge
# it so the new entry + icon show up without the user having to log out.
if systemctl --user --quiet is-active elephant.service 2>/dev/null; then
  systemctl --user restart elephant.service || true
fi

# ----- done --------------------------------------------------------------------

echo
echo "=== Install complete ==="
echo
echo "✓ motion-wallpaper-toggle installed to ~/.local/bin/"
echo "✓ 'Motion Wallpaper' added to your application menu"
echo "✓ systemd unit installed (not enabled)"
echo

if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
  cat <<'MSG'
⚠️  ~/.local/bin is not in your PATH. Add to your shell rc:

    export PATH="$HOME/.local/bin:$PATH"

MSG
fi

cat <<EOF
Usage:
  motion-wallpaper-toggle           # interactive (toggle / change video)
  motion-wallpaper-toggle status    # print current state
  motion-wallpaper-toggle stop      # stop and restore normal wallpaper

Tip: drop videos in ~/Videos/Wallpapers/ for quick-pick access.

Optional Hyprland keybind (avoid SUPER+W — that's Close window in Omarchy):
  bind = SUPER ALT, W, exec, \$HOME/.local/bin/motion-wallpaper-toggle

Persist across logins via systemd:
  systemctl --user enable --now motion-wallpaper.service

Logs: ~/.cache/motion-wallpaper.log
EOF
