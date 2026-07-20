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
for f in "$PLUGIN_SRC/manifest.json" "$PLUGIN_SRC/Service.qml" \
         "$PLUGIN_SRC/BarWidget.qml" "$PLUGIN_SRC/Panel.qml" "$CLI_SRC" "$ICON_SRC"; do
  [ -f "$f" ] || { echo "Missing installer asset: $f" >&2; exit 1; }
done

# ----- dependencies -----------------------------------------------------------
# Package names differ from command names, so probe both. The UI is native
# (bar widget + panel), so no gum/terminal deps — just video decode + helpers.
MISSING_PKGS=()
command -v jq       >/dev/null 2>&1 || MISSING_PKGS+=("jq")
command -v python3  >/dev/null 2>&1 || MISSING_PKGS+=("python")
command -v hyprctl  >/dev/null 2>&1 || MISSING_PKGS+=("hyprland")
# qt6-multimedia provides the QML MediaPlayer/VideoOutput used by the plugin.
pacman -Qq qt6-multimedia >/dev/null 2>&1 || MISSING_PKGS+=("qt6-multimedia")

if [ "${#MISSING_PKGS[@]}" -gt 0 ]; then
  echo "Installing required packages: ${MISSING_PKGS[*]}"
  sudo pacman -S --needed "${MISSING_PKGS[@]}"
else
  echo "✓ Dependencies present (qt6-multimedia, jq, python3, hyprland)"
fi

# ----- install the plugin -----------------------------------------------------
mkdir -p "$PLUGINS_DIR"
DEST="$PLUGINS_DIR/$PLUGIN_ID"
# If a previous install left a symlink (dev setup), replace it with a real copy.
[ -L "$DEST" ] && rm -f "$DEST"
rm -rf "$DEST"
mkdir -p "$DEST"
# Copy every plugin file — manifest plus all QML (service, bar widget, panel).
install -m 644 "$PLUGIN_SRC"/*.json "$PLUGIN_SRC"/*.qml "$DEST"/
echo "✓ Plugin installed to $DEST ($(find "$DEST" -type f | wc -l) files)"

# ----- enable it in shell.json ------------------------------------------------
# Add the plugin to .plugins[] (seeded disabled, no video, so first launch shows
# the normal static wallpaper) AND add its bar widget to bar.layout.right so the
# control panel is reachable from the bar. Both are added only if absent.
if [ -f "$SHELL_JSON" ]; then
  BACKUP="$SHELL_JSON.bak.$(date +%s)"
  cp -f "$SHELL_JSON" "$BACKUP"
  TMP="$(mktemp "${SHELL_JSON}.XXXXXX")"
  if jq --arg id "$PLUGIN_ID" '
      .plugins = (.plugins // []) |
      (if any(.plugins[]; .id == $id) then .
       else .plugins += [{ "id": $id, "output": "all", "pauseOnFullscreen": true, "enabled": false }]
       end) |
      .bar.layout.right = (.bar.layout.right // []) |
      (if any(.bar.layout.right[]; .id == $id) then .
       else .bar.layout.right += [{ "id": $id }]
       end)' "$SHELL_JSON" > "$TMP"; then
    mv -f "$TMP" "$SHELL_JSON"
    echo "✓ Plugin + bar widget registered in shell.json (backup: $BACKUP)"
  else
    rm -f "$TMP"
    echo "⚠️  Could not edit $SHELL_JSON automatically. Add to \"plugins\" and \"bar.layout.right\":" >&2
    echo '     plugins[]:          { "id": "nosignal.motion-wallpaper", "output": "all", "pauseOnFullscreen": true, "enabled": false }' >&2
    echo '     bar.layout.right[]: { "id": "nosignal.motion-wallpaper" }' >&2
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
# The interactive UI is the bar widget + panel. This launcher is a convenience:
# from Walker, "Motion Wallpaper" flips the video on/off (no window — it just
# fires an IPC toggle and exits).
cat > "$HOME/.local/share/applications/motion-wallpaper.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Motion Wallpaper
Comment=Toggle the animated video wallpaper on/off
Exec=$HOME/.local/bin/motion-wallpaper toggle
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

✓ Bar widget added — click the ◐ film icon in the bar for the control panel
✓ CLI: motion-wallpaper  (scripting / keybinds)

Quick start:
  Click the film icon in the bar → pick a video from the panel.
  Or from a terminal:
    motion-wallpaper play ~/Videos/Wallpapers/clip.mp4
    motion-wallpaper status
    motion-wallpaper stop

Tip: drop clips in ~/Videos/Wallpapers/ — they show up in the panel's list.

Optional Hyprland keybind (SUPER+W is Close window in Omarchy — avoid it):
  bindd = SUPER ALT, W, Motion wallpaper, exec, motion-wallpaper toggle

A playing wallpaper resumes automatically after reboot — no autostart step.
Logs: ~/.cache/motion-wallpaper.log
EOF

if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
  echo
  echo "⚠️  ~/.local/bin is not in your PATH. Add: export PATH=\"\$HOME/.local/bin:\$PATH\""
fi
