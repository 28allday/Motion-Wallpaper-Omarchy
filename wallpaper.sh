#!/usr/bin/env bash
# ==============================================================================
# Motion Wallpaper installer for Omarchy 4 (Quickshell / omarchy-shell).
#
# Installs a native omarchy-shell service plugin that renders a looping, muted
# video on the Wayland background layer, plus a gum TUI/CLI to control it.
#
# Installs:
#   ~/.config/omarchy/plugins/nosignal.motion-wallpaper/   the QML service plugin
#   ~/.local/bin/motion-wallpaper                          TUI + CLI control
#   ~/.local/share/applications/motion-wallpaper.desktop   app-menu entry
#   ~/.local/share/icons/hicolor/scalable/apps/motion-wallpaper.svg
#   (enables the plugin id in ~/.config/omarchy/shell.json)
#
# Dependencies: qt6-multimedia (video decode), gum, jq, python3, hyprland.
# There is NO mpvpaper, swaybg, socat or systemd unit any more — the shell
# plugin does the rendering, fullscreen auto-pause, and state persistence.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ID="nosignal.motion-wallpaper"
QS_SHELL="/usr/share/omarchy/shell"
PLUGIN_SRC="$SCRIPT_DIR/plugin/$PLUGIN_ID"
CLI_SRC="$SCRIPT_DIR/motion-wallpaper"
ICON_SRC="$SCRIPT_DIR/icons/motion-wallpaper.svg"
SHELL_JSON="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json"
PLUGINS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins"

echo "=== Motion Wallpaper installer (Omarchy 4 / Quickshell) ==="

if ! command -v pacman >/dev/null 2>&1; then
  echo "This installer expects a pacman-based system (Arch/Omarchy)." >&2
  exit 1
fi

# ----- sanity: this needs the Quickshell-based omarchy-shell -------------------
if [ ! -d "$QS_SHELL" ] || ! command -v qs >/dev/null 2>&1; then
  cat >&2 <<MSG
ERROR: omarchy-shell (Quickshell) not found at $QS_SHELL.
This plugin targets Omarchy 4+. On older Omarchy (Waybar/swaybg) use the
legacy mpvpaper-based release instead.
MSG
  exit 1
fi

# ----- required assets --------------------------------------------------------
for f in "$PLUGIN_SRC/manifest.json" "$PLUGIN_SRC/Service.qml" "$CLI_SRC" "$ICON_SRC"; do
  [ -f "$f" ] || { echo "Missing installer asset: $f" >&2; exit 1; }
done

# ----- dependencies -----------------------------------------------------------
# Package names differ from command names, so probe both.
MISSING_PKGS=()
command -v gum      >/dev/null 2>&1 || MISSING_PKGS+=("gum")
command -v jq       >/dev/null 2>&1 || MISSING_PKGS+=("jq")
command -v python3  >/dev/null 2>&1 || MISSING_PKGS+=("python")
command -v hyprctl  >/dev/null 2>&1 || MISSING_PKGS+=("hyprland")
# qt6-multimedia provides the QML MediaPlayer/VideoOutput used by the plugin.
pacman -Qq qt6-multimedia >/dev/null 2>&1 || MISSING_PKGS+=("qt6-multimedia")

if [ "${#MISSING_PKGS[@]}" -gt 0 ]; then
  echo "Installing required packages: ${MISSING_PKGS[*]}"
  sudo pacman -S --needed "${MISSING_PKGS[@]}"
else
  echo "✓ Dependencies present (qt6-multimedia, gum, jq, python3, hyprland)"
fi

# ----- install the plugin -----------------------------------------------------
mkdir -p "$PLUGINS_DIR"
DEST="$PLUGINS_DIR/$PLUGIN_ID"
# If a previous install left a symlink (dev setup), replace it with a real copy.
[ -L "$DEST" ] && rm -f "$DEST"
rm -rf "$DEST"
mkdir -p "$DEST"
install -D -m 644 "$PLUGIN_SRC/manifest.json" "$DEST/manifest.json"
install -D -m 644 "$PLUGIN_SRC/Service.qml"   "$DEST/Service.qml"
echo "✓ Plugin installed to $DEST"

# ----- enable it in shell.json ------------------------------------------------
# Add the plugin id to .plugins[] if absent, seeded disabled with no video so
# the first launch shows the normal static wallpaper until the user picks a clip.
if [ -f "$SHELL_JSON" ]; then
  BACKUP="$SHELL_JSON.bak.$(date +%s)"
  cp -f "$SHELL_JSON" "$BACKUP"
  TMP="$(mktemp "${SHELL_JSON}.XXXXXX")"
  if jq --arg id "$PLUGIN_ID" '
      .plugins = (.plugins // []) |
      if any(.plugins[]; .id == $id) then .
      else .plugins += [{ "id": $id, "output": "all", "pauseOnFullscreen": true, "enabled": false }]
      end' "$SHELL_JSON" > "$TMP"; then
    mv -f "$TMP" "$SHELL_JSON"
    echo "✓ Plugin enabled in shell.json (backup: $BACKUP)"
  else
    rm -f "$TMP"
    echo "⚠️  Could not edit $SHELL_JSON automatically. Add this to its \"plugins\" array:" >&2
    echo '     { "id": "nosignal.motion-wallpaper", "output": "all", "pauseOnFullscreen": true, "enabled": false }' >&2
  fi
else
  echo "⚠️  $SHELL_JSON not found — is omarchy-shell configured? Skipping auto-enable." >&2
fi

# ----- install the CLI --------------------------------------------------------
install -D -m 755 "$CLI_SRC" "$HOME/.local/bin/motion-wallpaper"
echo "✓ CLI installed to ~/.local/bin/motion-wallpaper"

# ----- icon + desktop entry ---------------------------------------------------
ICON_DIR="$HOME/.local/share/icons/hicolor/scalable/apps"
install -D -m 644 "$ICON_SRC" "$ICON_DIR/motion-wallpaper.svg"
command -v gtk-update-icon-cache >/dev/null 2>&1 && \
  gtk-update-icon-cache -f -q "$HOME/.local/share/icons/hicolor" 2>/dev/null || true

mkdir -p "$HOME/.local/share/applications"
# Launch in a floating terminal via Omarchy's TUI.float app-id (the default
# Hyprland windowrule tags it floating), same pattern omarchy-tui-install uses.
cat > "$HOME/.local/share/applications/motion-wallpaper.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Motion Wallpaper
Comment=Play an animated video wallpaper (TUI)
Exec=xdg-terminal-exec --app-id=TUI.float -e $HOME/.local/bin/motion-wallpaper
Icon=motion-wallpaper
Terminal=false
Categories=Utility;Settings;DesktopSettings;
Keywords=wallpaper;video;animated;background;motion;
EOF
command -v update-desktop-database >/dev/null 2>&1 && \
  update-desktop-database -q "$HOME/.local/share/applications" 2>/dev/null || true

# Nudge Walker's data provider so the entry + icon show without a re-login.
if systemctl --user --quiet is-active elephant.service 2>/dev/null; then
  systemctl --user restart elephant.service || true
fi

# ----- load the plugin now ----------------------------------------------------
echo
if command -v omarchy-restart-shell >/dev/null 2>&1; then
  echo "Restarting omarchy-shell to load the plugin…"
  omarchy-restart-shell >/dev/null 2>&1 || true
  echo "✓ Shell restarted"
else
  echo "⚠️  Restart omarchy-shell manually to load the plugin (omarchy-restart-shell)."
fi

# ----- done -------------------------------------------------------------------
cat <<EOF

=== Install complete ===

✓ 'Motion Wallpaper' added to your application menu
✓ CLI: motion-wallpaper  (run with no args for the TUI)

Quick start:
  motion-wallpaper            # interactive: pick a video and play
  motion-wallpaper status
  motion-wallpaper stop

Tip: drop clips in ~/Videos/Wallpapers/ for one-key quick-pick.

Optional Hyprland keybind (SUPER+W is Close window in Omarchy — avoid it):
  bindd = SUPER ALT, W, Motion wallpaper, exec, motion-wallpaper toggle

A playing wallpaper resumes automatically after reboot — no autostart step.
Logs: ~/.cache/motion-wallpaper.log
EOF

if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
  echo
  echo "⚠️  ~/.local/bin is not in your PATH. Add: export PATH=\"\$HOME/.local/bin:\$PATH\""
fi
