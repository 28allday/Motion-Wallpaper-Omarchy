#!/usr/bin/env bash
# ==============================================================================
# Motion Wallpaper installer for Omarchy 4 (Quickshell / omarchy-shell).
#
# The plugin itself is installed the supported way — `omarchy plugin add`, which
# clones this repo into ~/.config/omarchy/plugins/ and registers it. This script
# is a convenience wrapper around that plus the extras a plugin repo cannot
# carry on its own:
#
#   ~/.config/omarchy/plugins/nosignal.motion-wallpaper/   the plugin (git clone)
#   ~/.local/bin/motion-wallpaper                          CLI control
#   ~/.local/share/applications/motion-wallpaper.desktop   app-menu entry
#   ~/.local/share/icons/hicolor/scalable/apps/motion-wallpaper.svg
#
# If you only want the plugin, skip this script entirely:
#   omarchy plugin add https://github.com/28allday/Motion-Wallpaper-Omarchy.git --enable
#
# Dependencies: qt6-multimedia (video decode), jq, python3, hyprland.
# The shell plugin does the rendering, fullscreen auto-pause and state
# persistence itself — no external daemon, watcher or systemd unit.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ID="nosignal.motion-wallpaper"
CLI_SRC="$SCRIPT_DIR/motion-wallpaper"
ICON_SRC="$SCRIPT_DIR/icons/motion-wallpaper.svg"
PLUGINS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins"
PLUGIN_DIR="$PLUGINS_DIR/$PLUGIN_ID"

echo "=== Motion Wallpaper installer (Omarchy 4 / Quickshell) ==="

if ! command -v pacman >/dev/null 2>&1; then
  echo "This installer expects a pacman-based system (Arch/Omarchy)." >&2
  exit 1
fi

# ----- sanity: this needs the Quickshell-based omarchy-shell -------------------
# `omarchy plugin` and `omarchy-shell` both arrived with Omarchy 4; their absence
# is the clearest signal that this is an older release.
if ! command -v omarchy-shell >/dev/null 2>&1 || ! command -v omarchy-plugin-add >/dev/null 2>&1; then
  cat >&2 <<MSG
ERROR: omarchy-shell / omarchy-plugin-add not found on PATH.
Motion Wallpaper requires Omarchy 4+.
MSG
  exit 1
fi

# ----- required assets --------------------------------------------------------
for f in "$SCRIPT_DIR/manifest.json" "$SCRIPT_DIR/Service.qml" \
         "$SCRIPT_DIR/BarWidget.qml" "$SCRIPT_DIR/Panel.qml" "$CLI_SRC" "$ICON_SRC"; do
  [ -f "$f" ] || { echo "Missing installer asset: $f" >&2; exit 1; }
done

# ----- dependencies -----------------------------------------------------------
# Package names differ from command names, so probe both. The UI is native
# (bar widget + panel), so there are no terminal-UI deps — just video decode
# and helpers.
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
# Three cases: already running from inside the plugin directory (someone ran
# `omarchy plugin add` first and is now just fetching the extras); a legacy
# copy-install from an older version of this script; or a fresh install.

# In a terminal, `omarchy plugin add` shows its unsandboxed-code warning and
# asks which bar section to put the widget in (pre-selecting the manifest's
# defaultSection). That prompt is worth keeping, so --yes is only used when
# there is no one to answer it.
interactive() { [ -t 0 ] && [ -t 1 ]; }
PLACEMENT_CHOSEN=0

install_plugin() {
  if [ "$SCRIPT_DIR" = "$PLUGIN_DIR" ]; then
    echo "✓ Running from the installed plugin — leaving it alone"
    omarchy plugin enable "$PLUGIN_ID" >/dev/null 2>&1 || true
    return
  fi

  if [ -e "$PLUGIN_DIR" ] || [ -L "$PLUGIN_DIR" ]; then
    if [ -d "$PLUGIN_DIR/.git" ]; then
      echo "✓ Plugin already installed as a git checkout"
      echo "  Update it with: omarchy plugin update $PLUGIN_ID"
      return
    fi
    if [ -L "$PLUGIN_DIR" ]; then
      echo "✓ Plugin is a dev symlink — leaving it alone"
      return
    fi
    # A pre-0.2 copy install: no .git, so `omarchy plugin update` can never
    # work on it. Replace it, but only once we are sure it is ours.
    if [ -f "$PLUGIN_DIR/manifest.json" ] &&
       [ "$(jq -r '.id // ""' "$PLUGIN_DIR/manifest.json")" = "$PLUGIN_ID" ]; then
      echo "→ Replacing a legacy copy-install with a git checkout (so updates work)"
      rm -rf "$PLUGIN_DIR"
    else
      echo "⚠️  $PLUGIN_DIR exists and is not this plugin — leaving it alone." >&2
      return
    fi
  fi

  # Clone from wherever this checkout came from, so `omarchy plugin update`
  # has a real upstream to fast-forward against; fall back to this directory.
  local url
  url="$(git -C "$SCRIPT_DIR" remote get-url github 2>/dev/null \
      || git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null \
      || echo "$SCRIPT_DIR")"
  echo "→ Adding the plugin from $url"
  if interactive; then
    omarchy plugin add "$url" --enable
    PLACEMENT_CHOSEN=1
  else
    omarchy plugin add "$url" --enable --yes
  fi
}
install_plugin

# ----- put the widget where the manifest asks ---------------------------------
# Only for the unattended path. `omarchy plugin add --yes` enables through the
# running shell, whose plugin registry may not have rescanned the freshly-cloned
# manifest yet; when it has not, barWidget.defaultSection is unreadable and the
# widget lands in the default section (center) instead. If the user was asked
# where to put it, their answer wins and this does nothing.
place_widget() {
  if (( PLACEMENT_CHOSEN )); then return 0; fi
  local want current
  want="$(jq -r '.barWidget.defaultSection // "center"' "$SCRIPT_DIR/manifest.json")"
  current="$(jq -r --arg id "$PLUGIN_ID" '
      .bar.layout // {} | to_entries[]
      | select(.value | any(.id == $id)) | .key' \
      "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json" 2>/dev/null || true)"
  # Not in the bar at all (not enabled, or user removed it) — not ours to fix.
  [ -n "$current" ] || return 0
  [ "$current" != "$want" ] || return 0
  omarchy bar move "$PLUGIN_ID" --section "$want" >/dev/null 2>&1 &&
    echo "✓ Moved the bar widget to the $want section"
}
place_widget

# ----- clean up after the old installer ---------------------------------------
# Versions before 0.2 hand-wrote a plugins[] entry into shell.json alongside the
# bar entry. `omarchy plugin enable` writes only the bar entry, which is enough
# for both the widget and the service (PluginRegistry.isEnabled searches the bar
# layout first), so a leftover duplicate just makes `omarchy plugin disable` take
# two runs. A plugins[] entry carrying real settings is a deliberate config
# choice and is left alone.
SHELL_JSON="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json"
if [ -f "$SHELL_JSON" ] && command -v jq >/dev/null 2>&1; then
  if jq -e --arg id "$PLUGIN_ID" '
        (.plugins // []) | any(.;
          .id == $id
          and (.videoPath // "") == ""
          and (.enabled // false) == false
          and (.output // "all") == "all"
          and (.pauseOnFullscreen // true) == true)' "$SHELL_JSON" >/dev/null 2>&1; then
    TMP="$(mktemp "${SHELL_JSON}.XXXXXX")"
    if jq --arg id "$PLUGIN_ID" '.plugins = ((.plugins // []) | map(select(.id != $id)))' \
         "$SHELL_JSON" > "$TMP"; then
      mv -f "$TMP" "$SHELL_JSON"
      echo "✓ Removed the old hand-written plugins[] entry from shell.json"
    else
      rm -f "$TMP"
    fi
  fi
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
echo "Restarting omarchy-shell to load the plugin…"
omarchy-restart-shell >/dev/null 2>&1 || \
  echo "⚠️  Restart omarchy-shell manually to load the plugin (omarchy-restart-shell)."
echo "✓ Shell restarted"

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

Updating later:  omarchy plugin update $PLUGIN_ID
Removing:        omarchy plugin remove $PLUGIN_ID

A playing wallpaper resumes automatically after reboot — no autostart step.
Logs: ~/.cache/motion-wallpaper.log
EOF

if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
  echo
  echo "⚠️  ~/.local/bin is not in your PATH. Add: export PATH=\"\$HOME/.local/bin:\$PATH\""
fi
