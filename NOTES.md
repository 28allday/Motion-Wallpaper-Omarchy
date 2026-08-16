# Implementation notes

How Motion Wallpaper is put together, and the non-obvious things worth knowing
before changing it. For installing and using it, see the [README](README.md).

## Layout

The repo root *is* the plugin — that is what Omarchy clones and validates.

| Path | What it is |
|---|---|
| `manifest.json` | plugin manifest (`kinds`: `service`, `bar-widget`) |
| `Service.qml` | the service: rendering, auto-pause, state, IPC target |
| `BarWidget.qml` | bar icon; owns the dropdown's open state |
| `Panel.qml` | the dropdown's contents, loaded by the widget |
| `motion-wallpaper` | CLI, a thin client over the shell IPC target |
| `wallpaper.sh` | installer for the CLI, icon and desktop entry |
| `icons/` | the scalable app icon |

## Architecture

The plugin renders one `PanelWindow` per targeted monitor on the Wayland
background layer (namespace `omarchy-motion-background`), using QtMultimedia
`MediaPlayer` + `VideoOutput`. It loads after the first-party static-wallpaper
surface (`omarchy-background`), so it stacks above it. When a monitor has no
video set, its file is missing, or the plugin is stopped, **no surface is
created there at all** — the static wallpaper simply shows through, which is why
a broken state never leaves a black or frozen rectangle on the desktop.

Each surface resolves **its own** clip rather than sharing one, so monitors can
differ. See "Per-monitor clips" below.

Auto-pause listens to Hyprland's event stream via `Quickshell.Hyprland` and, on
any fullscreen-affecting event, reads per-monitor ground truth back from
`hyprctl` rather than trusting the event payload — so it pauses on exactly the
monitor whose visible workspace has a fullscreen window.

### State model

Two sources, with a deliberate split:

- an optional **`plugins[]` entry in `shell.json`** for this plugin id is the
  config seed — `videoPath`, `enabled`, `output`, `pauseOnFullscreen`,
  `screenVideos`.
  `Service.qml`'s `pluginConfig` falls back to `{}` when there is no entry, so
  every setting has a working default and the plugin runs without one.
- **`~/.local/state/motion-wallpaper/state.json`** is the runtime truth. IPC
  mutations (play/stop/toggle, screen, auto-pause) write it, so they survive a
  shell restart and a reboot. Editing the config entry re-seeds the state file.

That split is why there is no autostart step: `play` means it returns after a
reboot, `stop` means it stays off.

### Per-monitor clips

`pathForScreen(name)` is the single rule that decides what a monitor shows,
resolved most-specific-first:

1. `screenVideos[name]` — that monitor's own clip. **Present-but-empty means
   "stay static"**, which is distinct from absent; that distinction is what lets
   one screen be blanked while the others play, and it is why the map is read
   with `hasOwnProperty` rather than truthiness.
2. `videoPath`, if `output` is `"all"` or names this monitor.
3. nothing.

`output` therefore survives as coarse, CLI-facing targeting for monitors with
*no* clip of their own; per-monitor entries always win. Keys for disconnected
monitors are deliberately kept, so a screen gets its clip back when it returns.

Three consequences worth remembering when editing:

- **`activeScreens` must keep returning the same `ScreenInfo` objects.**
  `Variants` diffs by identity, so rebuilding the array on a clip change adds
  and removes nothing and the surface survives — which is what lets the
  cross-fade run. Returning freshly-built wrapper objects (`{screen, url}`)
  instead would destroy and recreate the surface on every clip change and take
  the cross-fade with it. Each `PanelWindow` reads its own url from
  `root.urlForScreen(monName)`; QML tracks the property reads inside that call,
  so it stays reactive without going through the model.
- **File existence is a map, not a bool.** Several clips can be in play at once,
  so one batched process (`for p in "$@"; do [ -f "$p" ]`) fills
  `existingPaths`, keyed by *resolved* path. `videoFileExists` remains as a
  derived property because the panel, the bar icon and the CLI still read it.
- **The bar icon keys off `rendering`** (`activeScreens.length > 0`), not
  "enabled and the default file exists" — with per-monitor clips the wallpaper
  can be running with `videoPath` empty, or every monitor can have been blanked
  individually.

The panel's SCREEN dropdown is **panel-local scope**, not service state: it aims
the video list at one monitor (or all) and picking a screen there changes
nothing on its own. Only "All screens" writes globally — `applyPlayAll()` sets
`videoPath`, drops every override and resets `output` to `"all"`, so that choice
means what it says (and self-heals a stale `output` left by the CLI).

`resetScope()` runs on every open, and deliberately does **not** always land on
"All screens": once the screens disagree, that default is destructive — one
click would flatten a per-screen setup — so the panel opens aimed at its own
monitor instead. The bar mounts one widget per screen, so "its own monitor" is
`button.QsWindow.window.screen.name`, surfaced as `screenName` on the widget.

### Cross-fade on clip change

A single `MediaPlayer` per surface cannot change clips cleanly: assigning a new
`source` clears its `VideoOutput` while the new file opens, so for a few hundred
milliseconds nothing paints the background layer and the desktop shows through.

So each monitor surface carries an **A/B pair** of `VideoOutput` + `MediaPlayer`:

- the incoming clip loads into whichever pair is idle and **plays there
  off-screen** — it has to actually run to produce a frame;
- the back pair's **`videoSink` delivering its first `videoFrameChanged`** is the
  cue to cross over — a 220ms opacity fade, then `frontIsA` flips;
- the outgoing player is stopped and its source cleared after the fade, so
  **steady state is still one active decoder**.

The frame-arrival cue is the whole point. Waiting on `mediaStatus`, or on a fixed
delay, still races the decoder.

Three guards are load-bearing:

- a **bad incoming clip abandons the swap** and keeps whatever is showing — a
  broken file must never take the wallpaper down;
- a **4s timeout** crosses over anyway if the new clip never delivers a frame
  *and* never errors, so a swap cannot hang forever;
- **re-picking the clip already showing** cancels an in-flight swap instead of
  stacking a second one.

### Verifying the cross-fade

"Does it blink?" is not answerable by reading QML, so measure it. The method,
if you touch the swap:

1. `motion-wallpaper stop`, then capture a **wallpaper-only strip** as the static
   reference. Read `hyprctl -j clients` geometry to find one: with tiled windows
   the bottom gap is full-width and pure wallpaper, e.g.
   `grim -g "0,<gap-y> <width>x12"`. This avoids needing an empty workspace.
2. Play clip A and confirm the strip is *far* from the reference. If the distance
   is small, the clip is indistinguishable from the wallpaper and the test proves
   nothing.
3. Sample the strip in a tight `grim` loop (~30/s) while switching to clip B, and
   report the **closest approach** to the static reference.

**Always measure a single-player build as a control**, or you cannot tell a
passing test from an insensitive one. A single-player build scores 0.0 — a
pixel-exact match with the static wallpaper, i.e. the desktop fully exposed.
The A/B build stays far from it throughout; the dip mid-swap is the two clips
blending, never the wallpaper.

## Packaging

The plugin follows Omarchy's third-party plugin conventions, and a few of them
are easy to get wrong:

- **`manifest.json` must be at the repo root.** `omarchy plugin add` clones the
  repo and validates the *clone root*. A plugin kept in a subdirectory validates
  fine when you point at that subdirectory but cannot be installed the supported
  way. Check with `omarchy plugin validate .` from the repo root.
- **Installs are git clones**, so `omarchy plugin update` is `git fetch` +
  `merge --ff-only`. Never install by copying files in: a copy can never be
  updated. `wallpaper.sh` delegates to `omarchy plugin add` for this reason.
- **`barWidget.defaultSection`** decides where the icon lands and which option is
  pre-selected in the placement prompt. Omitting it silently means `center`.
- **Do not hand-write a `plugins[]` entry to enable the plugin.**
  `PluginRegistry.isEnabled()` → `findEntryLocation()` searches the bar layout
  *before* `plugins[]`, so the bar entry written by `omarchy plugin enable`
  already enables both the bar widget and the service. A duplicate only makes
  `omarchy plugin disable` take two runs to clear. The `plugins[]` entry remains
  the place for *settings*, which is a separate thing.
- **The panel is not a `panel` kind.** It is a `Loader` inside the bar widget,
  the same mechanism the first-party audio and bluetooth widgets use. The `panel`
  kind is for independently summoned floating windows.
- **The CLI talks to the shell through `omarchy-shell <target> <method>`**, never
  a hardcoded `qs -p /usr/share/omarchy/shell ipc call`. The wrapper resolves
  `$OMARCHY_PATH`, recovers `WAYLAND_DISPLAY` for callers outside the session
  (ssh, a TTY), applies a timeout, and turns IPC-level failures into a nonzero
  exit — which is what the CLI's "not running" vs "not loaded" messages key off.

## Working on it

- **The installed plugin is a git clone of this repo**, so it does not track your
  working tree. For development, symlink
  `~/.config/omarchy/plugins/nosignal.motion-wallpaper` at your checkout;
  `wallpaper.sh` detects a symlink and leaves it alone. Note that
  `omarchy plugin validate` refuses symlinks *inside* a plugin folder, but a
  symlinked plugin *folder* is fine.
- **Reload after a QML edit is `omarchy-restart-shell`.** `rescanPlugins` only
  discovers plugins and manifest changes; it does not reload edited QML. Never
  use `omarchy-refresh-shell` — it resets `shell.json`.
- **The panel can be opened without a mouse:**
  `omarchy-shell shell toggle nosignal.motion-wallpaper`. `Bar.findPanelWidget`
  routes that to whichever per-monitor bar instance should own it, and it only
  finds widgets exposing `open()`, `close()` and `opened` on the widget root —
  which is why those three stay on `BarWidget.qml` even though the panel state
  lives below them. It is also the only way to screenshot the panel from a
  script, and the keybinding users get for free.
- **Styling comes from the shell's own kit**, not from re-drawn lookalikes:
  `PanelHero` for the header (title + `detail` pill + uppercase `meta` line),
  `Dropdown`, `Toggle`, `Button`, `PanelSectionHeader`, `PanelSeparator`, and
  `Style.hoverFillFor` / `selectedFillFor` / `selectedStateColor` for list rows —
  the same helpers the first-party audio, bluetooth and clock panels use. A
  hand-rolled header drifts from the rest of the shell the first time the kit's
  metrics change.
- **`hyprctl dispatch workspace N` does not work on Omarchy 4.** Dispatch is a
  Lua shorthand for `hl.dispatch(...)` and wants a dispatcher object under
  `hl.dsp.*`; the plain form and every quoted variant fail. Use the screenshot
  method above rather than switching workspaces to see the wallpaper.
- **The PipeWire `spaVisitChoice` warning is benign.** It fires whenever a
  `MediaPlayer` with an `AudioOutput` is created — zero occurrences with motion
  stopped, one after a clip starts. The muted `AudioOutput` is deliberate.
- **`omarchy plugin add --yes` can place the widget in the wrong section.** It
  enables through the running shell, whose registry may not have rescanned the
  freshly-cloned manifest yet, so `defaultSection` reads as unset and the widget
  lands in `center`; a later disable/enable places it correctly. `wallpaper.sh`
  re-places it once after an unattended install. The interactive path is
  unaffected — the placement prompt reads the manifest file directly.

## Known limitations

- Per-monitor clips and the `output` selector beyond `"all"` are implemented and
  applied live, but the dev box has one output — the multi-monitor paths
  (a different clip per screen, blanking one screen, hot-plug) still want a
  hardware pass on a two-monitor setup.
- Decoding runs continuously on the GPU. Auto-pause covers fullscreen windows;
  on battery, stopping or using a shorter, lower-bitrate clip is the bigger win.
