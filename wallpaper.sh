#!/usr/bin/env bash
# ==============================================================================
# Motion Wallpaper Installer for Omarchy / Hyprland
#
# This script sets up animated video wallpapers on an Omarchy (Arch Linux +
# Hyprland) desktop. It uses mpvpaper, which is a Wayland wallpaper program
# that plays a video file on the desktop background layer using mpv.
#
# What this installer does:
#   1. Installs dependencies (mpv, jq, zenity, mpvpaper)
#   2. Creates a toggle script at ~/.local/bin/motion-wallpaper-toggle
#   3. Creates a .desktop entry so it appears in your app launcher
#
# The toggle script works as an on/off switch:
#   - If no video wallpaper is running: opens a file picker, starts playback
#   - If a video wallpaper IS running: stops it, restores normal wallpaper
#
# Dependencies:
#   - mpv:       Video player engine (does the actual video decoding/rendering)
#   - mpvpaper:  Wayland-native wallpaper daemon that uses mpv as its backend
#                (AUR package — renders video on the wl_surface background layer)
#   - jq:        JSON parser — used to read monitor info from hyprctl
#   - zenity:    GTK dialog toolkit — provides the file picker and confirmation
#                dialogs so the script works without a terminal
#   - hyprctl:   Hyprland's CLI tool — used to detect connected monitors
#                (comes with Hyprland, no separate install needed)
# ==============================================================================

set -euo pipefail

echo "=== Motion wallpaper installer for Omarchy / Hyprland ==="

# Sanity check — this script uses pacman for package installation, so it
# only works on Arch-based systems. Omarchy is built on Arch Linux.
if ! command -v pacman >/dev/null 2>&1; then
  echo "This script expects a pacman-based system (Arch/Omarchy). Aborting."
  exit 1
fi

# Install core dependencies from the official Arch repos.
# --needed skips packages that are already installed, so this is safe
# to run multiple times without reinstalling anything unnecessarily.
#   - mpv: the video player that mpvpaper uses under the hood
#   - jq: parses the JSON output from "hyprctl monitors -j"
#   - zenity: provides GUI dialogs (file picker, yes/no prompts)
echo "Installing required packages: mpv jq zenity"
sudo pacman -S --needed mpv jq zenity

# Install mpvpaper from the AUR (Arch User Repository).
# mpvpaper is not in the official repos because it's a smaller community
# project. It needs an AUR helper (yay or paru) to build and install.
echo
echo "Installing mpvpaper from AUR..."

# Look for an AUR helper — yay and paru are the two most common ones.
# Omarchy ships with yay by default.
AUR_HELPER=""
if command -v yay >/dev/null 2>&1; then
  AUR_HELPER="yay"
elif command -v paru >/dev/null 2>&1; then
  AUR_HELPER="paru"
fi

if [ -n "$AUR_HELPER" ]; then
  echo "Using $AUR_HELPER to install mpvpaper..."
  $AUR_HELPER -S --needed mpvpaper
else
  echo "⚠️  No AUR helper (yay/paru) found."
  echo
  echo "Please install mpvpaper manually:"
  echo "  1. Install an AUR helper first:"
  echo "     sudo pacman -S --needed base-devel git"
  echo "     git clone https://aur.archlinux.org/yay.git"
  echo "     cd yay && makepkg -si"
  echo
  echo "  2. Then install mpvpaper:"
  echo "     yay -S mpvpaper"
  echo
  read -p "Press Enter after installing mpvpaper to continue..."
fi

# Final check — if mpvpaper still isn't installed at this point (e.g. user
# skipped the AUR step or the build failed), we can't continue because the
# toggle script depends on it.
if ! command -v mpvpaper >/dev/null 2>&1; then
  echo "ERROR: mpvpaper is not installed. Cannot continue."
  exit 1
fi

# Create the directory for user scripts. ~/.local/bin is the standard
# location for user-installed scripts on Linux (follows the XDG spec).
mkdir -p "$HOME/.local/bin"

# Create the toggle script — this is the main script users interact with.
# It's a self-contained on/off switch for video wallpapers.
# When toggled ON:  picks a video file via GUI, stops hyprpaper, starts mpvpaper
# When toggled OFF: stops mpvpaper, restarts hyprpaper to restore normal wallpaper
cat << 'EOF' > "$HOME/.local/bin/motion-wallpaper-toggle"
#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Motion Wallpaper"

# Zenity helper functions — these wrap zenity dialogs so the script can
# show GUI pop-ups for errors, info, and yes/no questions. If zenity isn't
# available (shouldn't happen since we install it), they fall back to
# plain text output in the terminal.
zen_err() {
  if command -v zenity >/dev/null 2>&1; then
    zenity --error --title="$APP_NAME" --text="$1" || true
  else
    echo "ERROR: $1" >&2
  fi
}

zen_info() {
  if command -v zenity >/dev/null 2>&1; then
    zenity --info --title="$APP_NAME" --text="$1" || true
  else
    echo "$1"
  fi
}

zen_question() {
  if command -v zenity >/dev/null 2>&1; then
    zenity --question --title="$APP_NAME" --text="$1"
    return $?
  else
    # No zenity, default to "yes"
    return 0
  fi
}

# Toggle logic — check if mpvpaper is already running.
# If it is, this is a "toggle OFF" action: stop the video wallpaper
# and bring back the normal static wallpaper by restarting hyprpaper.
if pgrep -x mpvpaper >/dev/null 2>&1; then
  if zen_question "Motion wallpaper is currently running.\n\nDo you want to stop it and return to your normal wallpaper?"; then
    pkill mpvpaper || true
    # Restart hyprpaper/swaybg so the normal wallpaper comes back
    hyprctl dispatch exec hyprpaper >/dev/null 2>&1 || true
    zen_info "Motion wallpaper stopped.\nNormal wallpaper restored."
  fi
  exit 0
fi

# If we get here, mpvpaper is NOT running — this is a "toggle ON" action.
# We need to: detect monitors → let user pick one → let user pick a video
# → stop hyprpaper → start mpvpaper.

# Make sure we're actually running inside Hyprland — hyprctl is how we
# talk to the compositor to find out which monitors are connected.
if ! command -v hyprctl >/dev/null 2>&1; then
  zen_err "hyprctl not found. Are you running Hyprland?"
  exit 1
fi

# Get monitor list from Hyprland as JSON. The -j flag outputs structured
# JSON data which we parse with jq to extract monitor names (e.g. HDMI-A-1,
# DP-1, eDP-1). mpvpaper needs the exact monitor name to know where to
# render the wallpaper.
MON_JSON="$(hyprctl monitors -j 2>/dev/null || true)"
if [ -z "$MON_JSON" ]; then
  zen_err "Could not get monitor info from hyprctl."
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  zen_err "jq is not installed. Please install jq and try again."
  exit 1
fi

MONITORS="$(printf '%s\n' "$MON_JSON" | jq -r '.[].name')"
if [ -z "$MONITORS" ]; then
  zen_err "No monitors detected."
  exit 1
fi

MON_COUNT="$(printf '%s\n' "$MONITORS" | wc -l)"

# If there's only one monitor, use it automatically. If there are multiple
# monitors, show a selection dialog so the user can pick which one gets
# the video wallpaper.
SELECTED_MON=""
if [ "$MON_COUNT" -eq 1 ]; then
  SELECTED_MON="$MONITORS"
else
  # Build a list for Zenity
  MON_LIST=$(printf '%s\n' "$MONITORS" | awk '{print NR, $1}')
  SELECTED_MON=$(echo "$MON_LIST" | zenity --list \
    --title="$APP_NAME - Select monitor" \
    --column="ID" --column="Monitor" \
    --height=300 \
    --print-column=2)
fi

if [ -z "${SELECTED_MON:-}" ]; then
  # User cancelled
  exit 0
fi

# Open a file picker dialog for the user to choose their video wallpaper.
# Filters to common video formats. If the user clicks Cancel, exit cleanly.
if ! command -v zenity >/dev/null 2>&1; then
  zen_err "Zenity is not installed but is required for file selection."
  exit 1
fi

VIDEO="$(zenity --file-selection \
  --title="$APP_NAME - Choose motion wallpaper video" \
  --file-filter="Video files | *.mp4 *.mkv *.webm *.mov *.avi")" || exit 0

if [ -z "$VIDEO" ]; then
  # User cancelled
  exit 0
fi

if [ ! -f "$VIDEO" ]; then
  zen_err "Selected file does not exist:\n$VIDEO"
  exit 1
fi

# 2e) Stop existing wallpaper daemons so mpvpaper is visible
# Omarchy runs hyprpaper (and sometimes swaybg) which render on the same
# background layer as mpvpaper. They must be stopped or mpvpaper will be
# hidden behind them.
pkill -x hyprpaper 2>/dev/null || true
pkill -x swaybg 2>/dev/null || true
sleep 0.3

# Start mpvpaper with optimised playback settings:
#   --loop:            Loop the video forever (it's a wallpaper, not a movie)
#   --no-audio:        Don't play audio (you don't want wallpaper sounds)
#   --vo=gpu:          Use GPU-accelerated rendering for minimal CPU usage
#   --profile=high-quality: Use mpv's high quality rendering profile
#   --keep-open=yes:   Keep the window open when video reaches end (before loop)
#
# nohup + & runs it in the background detached from the terminal, so
# closing the terminal won't kill the wallpaper.
nohup mpvpaper -o "--loop --no-audio --vo=gpu --profile=high-quality --keep-open=yes" \
  "$SELECTED_MON" "$VIDEO" >/dev/null 2>&1 &

zen_info "Motion wallpaper started on $SELECTED_MON."
EOF

chmod +x "$HOME/.local/bin/motion-wallpaper-toggle"

# Create a .desktop entry so "Motion Wallpaper" appears in app launchers
# (Walker, Elephant, etc.). This follows the freedesktop.org Desktop Entry
# spec. The Categories and Keywords fields help the launcher index it
# properly so users can find it by searching "wallpaper", "video", etc.
mkdir -p "$HOME/.local/share/applications"

cat << EOF > "$HOME/.local/share/applications/motion-wallpaper-toggle.desktop"
[Desktop Entry]
Version=1.0
Type=Application
Name=Motion Wallpaper
Comment=Toggle animated video wallpaper on/off
Exec=$HOME/.local/bin/motion-wallpaper-toggle
Icon=preferences-desktop-wallpaper
Terminal=false
Categories=Utility;Settings;DesktopSettings;
Keywords=wallpaper;video;animated;background;
EOF

echo
echo "=== Install complete ==="
echo
echo "✓ Motion Wallpaper has been added to your application menu"
echo "  Search for 'Motion Wallpaper' in your app launcher"

# Check if ~/.local/bin is in PATH — if it's not, the user won't be able
# to run "motion-wallpaper-toggle" directly from the terminal. The .desktop
# entry uses the full path so the app launcher will always work regardless.
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
  echo
  echo "⚠️  NOTE: ~/.local/bin is not in your PATH."
  echo "Add this to your ~/.bashrc or ~/.zshrc:"
  echo
  echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
  echo
  echo "Then reload your shell with: source ~/.bashrc"
  echo
  echo "For now, run with full path:"
  echo "  ~/.local/bin/motion-wallpaper-toggle"
else
  echo
  echo "Run this to toggle motion wallpaper on/off:"
  echo
  echo "  motion-wallpaper-toggle"
fi

echo
echo "Optional Hyprland keybind (add to ~/.config/hypr/bindings.conf):"
echo
echo "  NOTE: SUPER+W is already bound to 'Close window' in Omarchy."
echo "  Use a different keybind to avoid conflicts, for example:"
echo
echo "  bind = SUPER ALT, W, exec, ~/.local/bin/motion-wallpaper-toggle"
echo
