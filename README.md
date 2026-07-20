# Motion Wallpaper - Omarchy

[![Video Title](https://img.youtube.com/vi/GpdS_jyW9kU/maxresdefault.jpg)](https://youtu.be/GpdS_jyW9kU)

Animated video wallpapers for [Omarchy 4](https://omarchy.com) (Arch Linux + Hyprland + Quickshell).

On Omarchy 4 the desktop shell moved to **omarchy-shell** (Quickshell/QML) and the old `swaybg` wallpaper daemon is gone — the wallpaper is now painted by a QML plugin. Motion Wallpaper plugs straight into that model: a native **omarchy-shell service plugin** renders a looping, muted video on the Wayland background layer, above the first-party static wallpaper, with native fullscreen auto-pause and persistent state. A [gum](https://github.com/charmbracelet/gum)-powered TUI/CLI (`motion-wallpaper`) that follows your active Omarchy theme drives it over the shell's IPC.

No `mpvpaper`, `swaybg`, `socat` watcher or systemd unit — the shell plugin does the rendering, pausing, and state itself.

> **Older Omarchy (Waybar/swaybg)?** This release targets Omarchy 4+. Use a legacy mpvpaper-based release for Omarchy ≤3.

## Quick Start

```bash
git clone https://git.no-signal.uk/nosignal/Motion-Wallpaper-Omarchy.git
cd Motion-Wallpaper-Omarchy
chmod +x wallpaper.sh
./wallpaper.sh
```

The installer checks dependencies, installs the plugin, enables it in `shell.json`, and restarts the shell. Then run `motion-wallpaper` and pick a video.

## Requirements

- **OS**: [Omarchy 4](https://omarchy.com)+ (Arch Linux) with **omarchy-shell** (Quickshell) at `/usr/share/omarchy/shell`
- **Compositor**: Hyprland
- **Packages**: `qt6-multimedia` (video decode), `gum`, `jq`, `python`, `hyprland` — installed automatically if missing (no AUR helper needed)

## What It Installs

| Path | Purpose |
|------|---------|
| `~/.config/omarchy/plugins/nosignal.motion-wallpaper/` | the QML service plugin (`manifest.json` + `Service.qml`) |
| `~/.local/bin/motion-wallpaper` | TUI + CLI control |
| `~/.local/share/applications/motion-wallpaper.desktop` | app-menu / Walker entry (floating TUI) |
| `~/.local/share/icons/hicolor/scalable/apps/motion-wallpaper.svg` | icon |

It also adds `{ "id": "nosignal.motion-wallpaper", … }` to your `~/.config/omarchy/shell.json` `plugins[]` array (a timestamped backup is written first) and restarts the shell to load it.

## Usage

### From the app launcher

Open Walker (`SUPER`), type **Motion Wallpaper**, hit enter — the TUI opens as a floating window, themed to match your desktop. Pick a video and it plays immediately.

### From the terminal

```bash
motion-wallpaper            # interactive TUI (default)
motion-wallpaper status     # print current state
motion-wallpaper stop       # stop; static wallpaper shows through
motion-wallpaper pause      # pause playback (surface stays up)
motion-wallpaper resume     # resume
motion-wallpaper change     # pick a new video (interactive)
motion-wallpaper play ~/Videos/Wallpapers/clip.mp4   # set + play a file directly
```

### With a keybind

Add to `~/.config/hypr/bindings.conf` (or your Omarchy Lua bindings). Avoid `SUPER+W` — that's *Close window* in Omarchy:

```
bindd = SUPER ALT, W, Motion wallpaper, exec, motion-wallpaper toggle
```

### Video library folder

Drop clips in **`~/Videos/Wallpapers/`** and they appear as a one-key quick-pick list in the TUI. Anything else is reachable via the built-in filesystem browser (confined to your home directory).

### Multiple monitors

The TUI's **Change output monitor** action lets you target a single output or all of them. The video plays only on the targeted monitor(s); the rest keep the normal static wallpaper. (Output is a shell config option, so changing it restarts the shell briefly to apply.)

### Persistence

A playing wallpaper **resumes automatically after a reboot** — the plugin persists its state to `~/.local/state/motion-wallpaper/state.json` and the shell loads it on login. There's no separate autostart step: `stop` means it stays off next boot, `play` means it comes back.

## How It Works

- **Rendering** — the plugin creates one `PanelWindow` per targeted monitor on the Wayland **background layer** (namespace `omarchy-motion-background`), using QtMultimedia `MediaPlayer` + `VideoOutput` (looped, muted, `PreserveAspectCrop`). It loads after the first-party static-wallpaper surface, so it stacks above it. When no video is set or the file is missing, no surface is created at all — so the static wallpaper shows through (never a black or frozen frame).
- **Auto-pause on fullscreen** — the plugin listens to Hyprland's event stream (`Quickshell.Hyprland`) and, on any fullscreen-affecting event, reads per-monitor ground truth from `hyprctl` to pause the video on exactly the monitor whose visible workspace has a fullscreen window. Toggle via the `pauseOnFullscreen` config key. This replaces the old external socat watcher.
- **Theme changes** — nothing to do: switch themes freely, the first-party static wallpaper updates underneath. The video keeps playing until you stop it.
- **Control** — the CLI is a thin client over the shell IPC target `motion-wallpaper` (`play` / `stop` / `toggle` / `pause` / `resume` / `status`), reachable directly as `qs -p /usr/share/omarchy/shell ipc call motion-wallpaper <fn>`.

## Supported Video Formats

Anything QtMultimedia's FFmpeg backend can decode — `.mp4`, `.mkv`, `.webm`, `.mov`, `.avi`. H.264/H.265 MP4 is the safest bet for smooth looping.

## Finding Video Wallpapers

- [MoeWalls](https://moewalls.com) — large library of looping anime/aesthetic clips
- Any short, seamlessly-looping video works well; keep it at your display resolution to avoid needless GPU scaling.

## Performance

Video wallpaper decodes continuously on the GPU, so it uses more power than a static image. The fullscreen auto-pause keeps games and full-screen video from paying that cost. For laptops on battery, consider `motion-wallpaper stop` or a shorter/lower-bitrate clip.

## Troubleshooting

- **TUI says the plugin isn't loaded** — run `./wallpaper.sh` (or restart the shell with `omarchy-restart-shell`). Confirm with `qs -p /usr/share/omarchy/shell ipc show | grep motion-wallpaper`.
- **No video appears** — check `motion-wallpaper status`: `videoFileExists: false` means the saved path is gone; pick a new file. Watch for QML errors in the shell's journal.
- **Edited the plugin QML** — plugin code changes need a full `omarchy-restart-shell`; `ipc call shell rescanPlugins` only *discovers* newly-added plugins, it doesn't reload edited code. Don't use `omarchy-refresh-shell` — it resets `shell.json`.
- **Logs** — `~/.cache/motion-wallpaper.log` (CLI) and the shell's own stderr/journal (plugin).

## Uninstalling

```bash
# Stop it and remove the plugin
motion-wallpaper stop
rm -rf ~/.config/omarchy/plugins/nosignal.motion-wallpaper
rm -f  ~/.local/bin/motion-wallpaper \
       ~/.local/share/applications/motion-wallpaper.desktop \
       ~/.local/share/icons/hicolor/scalable/apps/motion-wallpaper.svg
rm -rf ~/.local/state/motion-wallpaper

# Remove the plugin entry from ~/.config/omarchy/shell.json plugins[], then:
omarchy-restart-shell
```

## Credits

Built for [Omarchy](https://omarchy.com) by DHH and the Omarchy community. Video playback via [Qt Multimedia](https://doc.qt.io/qt-6/qtmultimedia-index.html); shell integration via [Quickshell](https://quickshell.outfoxxed.me/).

## License

MIT
