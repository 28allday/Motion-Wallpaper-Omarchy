# Motion Wallpaper - Omarchy

[![Video Title](https://img.youtube.com/vi/GpdS_jyW9kU/maxresdefault.jpg)](https://youtu.be/GpdS_jyW9kU)

Animated video wallpapers for [Omarchy](https://omarchy.com) (Arch Linux + Hyprland).

Uses [mpvpaper](https://github.com/GhostNaN/mpvpaper) to play any video file as your desktop wallpaper. Features a [gum](https://github.com/charmbracelet/gum)-powered TUI that follows your active Omarchy theme and launches as a floating window, a quick-pick library folder, a systemd autostart unit so the wallpaper survives reboots, an auto-pause watcher that subscribes to Hyprland's event socket and pauses the video whenever a fullscreen window covers the wallpaper, and a theme watcher that cleanly stops the wallpaper when you cycle Omarchy themes so the new theme's background takes over.

## Quick Start

```bash
git clone https://git.no-signal.uk/nosignal/Motion-Wallpaper-Omarchy.git
cd Motion-Wallpaper-Omarchy
chmod +x wallpaper.sh
./wallpaper.sh
```

The installer handles all dependencies automatically.

## Requirements

- **OS**: [Omarchy](https://omarchy.com) (Arch Linux)
- **Compositor**: Hyprland
- **AUR Helper**: yay or paru (for mpvpaper)

## What It Installs

### Packages

| Package | Source | Purpose |
|---------|--------|---------|
| `mpv` | Official repos | Video player engine (decodes and renders video) |
| `jq` | Official repos | Parses monitor info from Hyprland |
| `gum` | Official repos | TUI toolkit (action menus, monitor picker, file browser) |
| `socat` | Official repos | UNIX-socket bridge used by the auto-pause watcher |
| `libnotify` | Official repos | `notify-send` for post-action desktop notifications |
| `mpvpaper` | AUR | Wayland wallpaper daemon that uses mpv as its backend |

### Files Created

| Path | Purpose |
|------|---------|
| `~/.local/bin/motion-wallpaper-toggle` | Runtime TUI (toggle / start / stop / change / status) |
| `~/.local/bin/motion-wallpaper-watcher` | Auto-pause watcher — pauses mpv on fullscreen |
| `~/.local/bin/motion-wallpaper-theme-watcher` | Theme watcher — stops the wallpaper when the Omarchy theme changes |
| `~/.local/share/applications/motion-wallpaper-toggle.desktop` | App launcher entry — opens as a floating terminal via `xdg-terminal-exec --app-id=TUI.float` |
| `~/.local/share/icons/hicolor/scalable/apps/motion-wallpaper.svg` | Launcher icon |
| `~/.config/systemd/user/motion-wallpaper.service` | Autostart unit (not enabled by default) |
| `~/.config/motion-wallpaper/state` | Last video, target monitor, and last-used directory |
| `~/.cache/motion-wallpaper.log` | Runtime log |

## Usage

### From App Launcher

Search for **"Motion Wallpaper"** in Walker or your app launcher. The `.desktop` entry launches via `xdg-terminal-exec --app-id=TUI.float`, so Hyprland's existing floating-window rule renders it as a centered floating terminal (the same treatment given to TUIs like btop and impala) instead of a tiled fullscreen one. The window closes automatically when you exit. The TUI itself reads `~/.config/omarchy/current/theme/colors.toml` and recolours its menu cursor, headers, and prompts to match the active theme (Catppuccin fallback if the file is missing).

### From Terminal

```bash
motion-wallpaper-toggle            # interactive — toggle, or Stop/Change if running
motion-wallpaper-toggle change     # pick a new video without stopping first
motion-wallpaper-toggle stop       # stop and restore the normal wallpaper
motion-wallpaper-toggle status     # print current state
motion-wallpaper-toggle start      # non-interactive start from saved state (used by systemd)
```

### With a Keybind

Add this to `~/.config/hypr/bindings.conf`:

```
bind = SUPER ALT, W, exec, ~/.local/bin/motion-wallpaper-toggle
```

> **Note**: `SUPER+W` is already bound to "Close window" in Omarchy. Use `SUPER ALT+W` or another free combination.

### Video library folder

Drop videos in `~/Videos/Wallpapers/` and the picker shows that folder as a quick list instead of opening the full filesystem browser. A **Browse…** entry is always available for picking something outside the library. The last directory you picked from is remembered (`LAST_DIR` in the state file) — next time you **Browse…**, `gum file` opens there instead of `$HOME`.

### Persist across reboots (autostart)

The first time you start a wallpaper, the TUI asks whether to enable autostart. Say yes and the bundled systemd user unit is enabled — on next login it calls `motion-wallpaper-toggle start`, which loads the saved video + target and starts mpvpaper non-interactively.

You can flip autostart any time from the running-state menu (**Turn autostart ON / OFF**). The header always shows the current state. If you click **Stop** while autostart is still on, the TUI offers to disable it too so "stop" really means stop. If you disable autostart while the wallpaper is running, it offers to stop the current instance.

CLI alternative:
```bash
systemctl --user enable --now motion-wallpaper.service
systemctl --user disable --now motion-wallpaper.service
```
If no state has been saved yet, the unit exits cleanly without error.

## How It Works

### Toggle — not running

1. Detects monitors via `hyprctl monitors -j`.
2. If multiple monitors, offers a picker with an **All monitors** option (passes `*` to mpvpaper).
3. Shows the video library (if any) or a `gum file` browser starting at `LAST_DIR`.
4. Stops the current wallpaper daemon (`swaybg` on Omarchy, or `hyprpaper` on generic Hyprland) so mpvpaper is visible, then runs `setsid uwsm-app -- mpvpaper -o "..."` with `--loop --no-audio --mute=yes --vo=gpu --profile=high-quality --input-ipc-server=…` and spawns the watcher. `setsid` + `uwsm-app` detaches mpvpaper from the TUI terminal so it survives the window closing.
5. Verifies mpvpaper is alive after 0.8s; surfaces failures inline and holds the terminal open until you press enter.
6. Saves video, target, and last-used directory to `~/.config/motion-wallpaper/state` (atomic write, parsed back without `source` so it can't execute code from the state file).
7. If autostart isn't already enabled, asks whether to enable it.

### Toggle — already running

Shows a menu with four entries:

- **Stop motion wallpaper** — kill the watchers + mpvpaper and restore the previous static wallpaper. On Omarchy this respawns `swaybg -i ~/.config/omarchy/current/background -m fill` via `uwsm-app`, matching how Omarchy autostarts it; on generic Hyprland it re-execs `hyprpaper`. Stop is `flock`-guarded, so the TUI path and systemd's `ExecStop` can't race.
- **Change video** — pick a new video and target monitor, swap in place (`LAST_DIR` updates if you browsed).
- **Turn autostart ON / OFF** — toggles the systemd unit. Label reflects current state.
- **Cancel** — bail without changes.

After every action the TUI loops back to the main menu — only Cancel or Esc closes the window. Saved targets are validated against `hyprctl monitors` on each start, so if the monitor you last targeted has been unplugged the wallpaper falls back to **All monitors** instead of erroring.

### Auto-pause (the watcher)

`motion-wallpaper-watcher` subscribes to Hyprland's event socket (`$XDG_RUNTIME_DIR/hypr/<instance>/.socket2.sock`) and, on `fullscreen>>1`, sends `{"command":["set_property","pause",true]}` to mpv's IPC socket (`--input-ipc-server`). On `fullscreen>>0` it resumes. The watcher is started and killed alongside mpvpaper by the toggle script. mpvpaper's own `-p` flag was flaky on Hyprland 0.54.x, hence this external approach.

Both the toggle and the watcher self-recover `HYPRLAND_INSTANCE_SIGNATURE` if the launcher strips it from the env or carries a stale value across a Hyprland restart — they cross-check the signature against `hyprctl instances` (the live source of truth) and rewrite it before any `hyprctl` call.

### Theme change (the theme-watcher)

`motion-wallpaper-theme-watcher` polls `~/.config/omarchy/current/background` every 2 seconds and, when the symlink target changes, runs `motion-wallpaper-toggle stop`. That tears down mpvpaper and respawns `swaybg` against the new symlink so the new theme's static wallpaper takes over cleanly — without it, mpvpaper would keep playing on top of the new theme's background. Spawned and killed alongside mpvpaper by the toggle script; exits silently on non-Omarchy systems where the symlink doesn't exist.

## Supported Video Formats

Any format mpv supports, including:

- `.mp4` (H.264, H.265)
- `.mkv` (Matroska)
- `.webm` (VP9, AV1)
- `.mov` (QuickTime)
- `.avi`

## Finding Video Wallpapers

Search for "live wallpaper" or "motion desktop" videos. Good sources include:

- [MoeWalls](https://moewalls.com/) — large free library of live/animated wallpapers (anime, landscape, gaming, minimal); direct `.mp4` downloads, no signup
- Free stock video sites (Pexels, Pixabay)

**Tips for best results:**

- Match your monitor resolution (e.g. 3840x2160 for 4K)
- Seamless loops look best (no visible cut at the loop point)
- Shorter videos (10-30 seconds) use less memory
- H.264 `.mp4` has the best hardware decode support

## Performance

mpvpaper uses GPU-accelerated rendering (`--vo=gpu`) so CPU usage is minimal. The watcher also pauses playback whenever a fullscreen window covers the wallpaper, so games and full-screen video don't pay the decode cost.

- Higher resolution videos use more VRAM.
- Shorter seamless loops (10–30s) use less memory.
- If you still notice impact, toggle the wallpaper off or disable autostart.

## Troubleshooting

First stop: `~/.cache/motion-wallpaper.log` — both the toggle script and mpvpaper write there.

**Video wallpaper doesn't appear / shows black**
- Check the log. Codec issues and "no such monitor" errors both show up there.
- Make sure hyprpaper and swaybg are not running: `pgrep hyprpaper && pkill hyprpaper`

**TUI fails with "gum is not installed"**
- `sudo pacman -S gum`

**Launcher runs it but no terminal opens**
- Make sure your default terminal is XDG-registered. Omarchy's alacritty works out of the box.
- As a fallback, run `motion-wallpaper-toggle` directly from any terminal.

**"No monitors detected" error**
- Make sure you're running Hyprland: `echo $XDG_CURRENT_DESKTOP`
- Check hyprctl works: `hyprctl monitors`

**Autostart unit fails**
- `journalctl --user -u motion-wallpaper.service`
- If the saved video was moved or deleted, the unit exits non-zero. Run the toggle interactively once to save fresh state.

**Auto-pause isn't pausing on fullscreen**
- Make sure the window is truly fullscreen (`hyprctl activewindow -j | jq '.fullscreen'` should be non-zero). On Omarchy, **SUPER+F** is true fullscreen; **SUPER+ALT+F** is only "full width" and won't trigger pause.
- `grep watcher: ~/.cache/motion-wallpaper.log` should show `fullscreen entered — pause` / `fullscreen left — resume` lines.
- If the watcher isn't running: `pgrep -af motion-wallpaper-watcher`. If missing, the toggle script failed to spawn it — check the log around the start time.

**Normal wallpaper doesn't come back after toggling off**
- Omarchy: `pkill -x swaybg; setsid uwsm-app -- swaybg -i ~/.config/omarchy/current/background -m fill &`
- Or just cycle the background: `omarchy-theme-bg-next` then back with `SUPER CTRL SPACE`.
- Generic Hyprland: `hyprctl dispatch exec hyprpaper`.

## Uninstalling

```bash
# Stop and disable autostart if enabled
systemctl --user disable --now motion-wallpaper.service 2>/dev/null || true

# Remove installed files
rm -f ~/.local/bin/motion-wallpaper-toggle
rm -f ~/.local/bin/motion-wallpaper-watcher
rm -f ~/.local/bin/motion-wallpaper-theme-watcher
rm -f ~/.local/share/applications/motion-wallpaper-toggle.desktop
rm -f ~/.local/share/icons/hicolor/scalable/apps/motion-wallpaper.svg
rm -f ~/.config/systemd/user/motion-wallpaper.service
rm -rf ~/.config/motion-wallpaper
rm -f ~/.cache/motion-wallpaper.log
systemctl --user daemon-reload

# Optionally remove packages (skip any you want to keep for other uses)
sudo pacman -Rns mpvpaper gum socat
```

## Credits

- [Omarchy](https://omarchy.com) - The Arch Linux distribution this was built for
- [mpvpaper](https://github.com/GhostNaN/mpvpaper) - Wayland video wallpaper daemon
- [mpv](https://mpv.io/) - The video player engine
- [Hyprland](https://hyprland.org/) - Wayland compositor

## License

This project is provided as-is for the Omarchy community.
