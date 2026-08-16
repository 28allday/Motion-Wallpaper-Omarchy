# Motion Wallpaper - Omarchy

[![Video Title](https://img.youtube.com/vi/GpdS_jyW9kU/maxresdefault.jpg)](https://youtu.be/GpdS_jyW9kU)

Animated video wallpapers for [Omarchy 4](https://omarchy.com) (Arch Linux + Hyprland + Quickshell).

On Omarchy 4 the desktop shell is **omarchy-shell** (Quickshell/QML) and the wallpaper is painted by a QML plugin. Motion Wallpaper plugs straight into that model: a native **omarchy-shell plugin** renders a looping, muted video on the Wayland background layer, above the first-party static wallpaper, with native fullscreen auto-pause and persistent state. It ships a **bar widget + dropdown panel** (click the film icon in the bar) to play/pause/stop, pick a clip, choose the screen, and toggle auto-pause — all native, themed to match the rest of the shell. A thin `motion-wallpaper` CLI covers keybinds and scripting.

The shell plugin does the rendering, the controls, pausing and state itself — there is no external daemon, watcher, systemd unit or terminal UI.

> **Omarchy 4+ only.** It needs the Quickshell-based `omarchy-shell`; the installer checks for it and stops if it is missing.

## Quick Start

This repo is an Omarchy shell plugin, so Omarchy's own plugin command installs it:

```bash
omarchy plugin add https://github.com/28allday/Motion-Wallpaper-Omarchy.git --enable
```

That clones it into `~/.config/omarchy/plugins/`, enables it, and asks which bar section to put the film icon in — left, center or right (right is pre-selected). Click the icon and pick a video: that is the whole install.

To also get the `motion-wallpaper` CLI (for keybinds and scripting), the Walker entry and the icon, run the installer script as well:

```bash
git clone https://github.com/28allday/Motion-Wallpaper-Omarchy.git
cd Motion-Wallpaper-Omarchy
./wallpaper.sh
```

`wallpaper.sh` checks dependencies, installs the plugin if it isn't already there (asking where to put the bar icon, same as above), installs the CLI and icon, and restarts the shell. If you already have the plugin, it leaves it alone and just adds the CLI.

To update later:

```bash
omarchy plugin update nosignal.motion-wallpaper
```

## Requirements

- **OS**: [Omarchy 4](https://omarchy.com)+ (Arch Linux) with **omarchy-shell** (Quickshell)
- **Compositor**: Hyprland
- **Packages**: `qt6-multimedia` (video decode), `jq`, `python`, `hyprland` — installed automatically if missing (no AUR helper needed)

## What It Installs

| Path | Purpose |
|------|---------|
| `~/.config/omarchy/plugins/nosignal.motion-wallpaper/` | the plugin (service + bar widget + panel) |
| `~/.local/bin/motion-wallpaper` | CLI control (keybinds / scripting) |
| `~/.local/share/applications/motion-wallpaper.desktop` | Walker entry (toggles the wallpaper) |
| `~/.local/share/icons/hicolor/scalable/apps/motion-wallpaper.svg` | icon |

In your `shell.json`, enabling adds a single bar-widget entry in the section you chose. Out of the box the plugin starts with no video selected, so your normal static wallpaper is what you see until you pick a clip.

### Setting defaults in `shell.json`

Optional. Add an entry for this plugin id under `plugins[]` to choose what it starts with:

```json
{ "id": "nosignal.motion-wallpaper", "videoPath": "~/Videos/Wallpapers/clip.mp4",
  "enabled": true, "output": "all", "pauseOnFullscreen": true }
```

## Usage

### The bar widget + panel

Click the **film icon** in the bar to open the control panel. From there you can:

- **Play / Pause / Stop** the video
- **Pick a clip** from a list of videos in `~/Videos/Wallpapers` and `~/Videos` — clips cross-fade into each other, so the desktop never flashes through mid-switch
- **Choose the screen** — all monitors or a specific output (applies instantly)
- **Toggle auto-pause** when a fullscreen window covers the wallpaper

The bar icon reflects state at a glance: accent when playing, amber when paused, dim when stopped.

### From the terminal

```bash
motion-wallpaper                 # print current state (default)
motion-wallpaper play ~/Videos/Wallpapers/clip.mp4
motion-wallpaper stop            # stop; static wallpaper shows through
motion-wallpaper toggle          # flip on/off
motion-wallpaper pause           # pause / resume
motion-wallpaper resume
motion-wallpaper screen HDMI-A-1 # or: screen all
motion-wallpaper autopause off   # or: on
```

### With a keybind

Add to `~/.config/hypr/bindings.conf` (or your Omarchy Lua bindings). Avoid `SUPER+W` — that's *Close window* in Omarchy:

```
bindd = SUPER ALT, W, Motion wallpaper, exec, motion-wallpaper toggle
```

### Video library folder

Drop clips in **`~/Videos/Wallpapers/`** and they appear in the panel's list. To play a file from anywhere else, use `motion-wallpaper play <path>`.

### Multiple monitors

The panel's **screen** dropdown (or `motion-wallpaper screen <name|all>`) targets a single output or all of them, applied live with no shell restart. The video plays only on the targeted monitor(s); the rest keep the normal static wallpaper.

### Persistence

A playing wallpaper **resumes automatically after a reboot** — the plugin persists its state to `~/.local/state/motion-wallpaper/state.json` and the shell loads it on login. There's no separate autostart step: `stop` means it stays off next boot, `play` means it comes back.

## How It Works

- **Rendering** — the plugin creates one `PanelWindow` per targeted monitor on the Wayland **background layer** (namespace `omarchy-motion-background`), using QtMultimedia `MediaPlayer` + `VideoOutput` (looped, muted, `PreserveAspectCrop`). It loads after the first-party static-wallpaper surface, so it stacks above it. When no video is set or the file is missing, no surface is created at all — so the static wallpaper shows through (never a black or frozen frame).
- **Auto-pause on fullscreen** — the plugin listens to Hyprland's event stream (`Quickshell.Hyprland`) and, on any fullscreen-affecting event, reads per-monitor ground truth from `hyprctl` to pause the video on exactly the monitor whose visible workspace has a fullscreen window. Toggle it from the panel (or `motion-wallpaper autopause on|off`).
- **Theme changes** — nothing to do: switch themes freely, the first-party static wallpaper updates underneath. The video keeps playing until you stop it.
- **Controls** — the bar widget and panel talk to the plugin's service instance in-process. The `motion-wallpaper` CLI is a thin client over the same shell IPC target (`play` / `stop` / `toggle` / `pause` / `resume` / `status` / `setOutput` / `setPauseOnFullscreen`), reachable directly as `omarchy-shell motion-wallpaper <fn>`. State (video, enabled, screen, auto-pause) persists to `~/.local/state/motion-wallpaper/state.json`.

## Supported Video Formats

Anything QtMultimedia's FFmpeg backend can decode — `.mp4`, `.mkv`, `.webm`, `.mov`, `.avi`. H.264/H.265 MP4 is the safest bet for smooth looping.

## Finding Video Wallpapers

- [MoeWalls](https://moewalls.com) — large library of looping anime/aesthetic clips
- Any short, seamlessly-looping video works well; keep it at your display resolution to avoid needless GPU scaling.

## Performance

Video wallpaper decodes continuously on the GPU, so it uses more power than a static image. The fullscreen auto-pause keeps games and full-screen video from paying that cost. For laptops on battery, consider `motion-wallpaper stop` or a shorter/lower-bitrate clip.

## Troubleshooting

- **No bar icon / "plugin isn't loaded"** — make sure it is enabled (`omarchy plugin enable nosignal.motion-wallpaper`), then restart the shell with `omarchy-restart-shell`. Confirm the IPC target answers with `omarchy-shell motion-wallpaper status`.
- **No video appears** — check `motion-wallpaper status`: `videoFileExists: false` means the saved path is gone; pick a new file. Watch for QML errors in the shell's journal.
- **Edited the plugin QML** — plugin code changes need a full `omarchy-restart-shell`; `ipc call shell rescanPlugins` only *discovers* newly-added plugins, it doesn't reload edited code. Don't use `omarchy-refresh-shell` — it resets `shell.json`.
- **Logs** — `~/.cache/motion-wallpaper.log` (CLI) and the shell's own stderr/journal (plugin).

## Uninstalling

```bash
motion-wallpaper stop
omarchy plugin remove nosignal.motion-wallpaper

# The extras the plugin command doesn't own:
rm -f  ~/.local/bin/motion-wallpaper \
       ~/.local/share/applications/motion-wallpaper.desktop \
       ~/.local/share/icons/hicolor/scalable/apps/motion-wallpaper.svg
rm -rf ~/.local/state/motion-wallpaper
```

## Credits

Built for [Omarchy](https://omarchy.com) by DHH and the Omarchy community. Video playback via [Qt Multimedia](https://doc.qt.io/qt-6/qtmultimedia-index.html); shell integration via [Quickshell](https://quickshell.outfoxxed.me/).

## License

MIT
