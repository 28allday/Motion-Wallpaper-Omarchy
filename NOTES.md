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
| `icons/` | the project mark; kept as artwork, nothing installs it |
| `preview.jpg` | listing image; the marketplace only reads it at the ROOT |
| `LICENSE` | MIT, matching the manifest and README |

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
- **There is no `service` block in the manifest vocabulary.** The shell reads
  `defaults`/`schema`/`settingsForm` off **`barWidget`** only (`shell.qml`'s
  bar-widget registration), and hands a service nothing but `omarchyPath`,
  `shell`, `manifest`, `barWidgetRegistry` and `pluginRegistry` (`ensureService`).
  A `service: { defaults, schema }` block validates, installs and is then read by
  nothing — this plugin carried one for a while. Settings for a service kind come
  from its own read of the `plugins[]` entry, which is why `pluginConfig` in
  `Service.qml` parses `shell.shellConfig` itself. `plugins/services/media` is
  the first-party plugin with this exact shape; copy that.
- **Do not hand-write a `plugins[]` entry to enable the plugin.**
  `PluginRegistry.isEnabled()` → `findEntryLocation()` searches the bar layout
  *before* `plugins[]`, so the bar entry written by `omarchy plugin enable`
  already enables both the bar widget and the service. A duplicate only makes
  `omarchy plugin disable` take two runs to clear. The `plugins[]` entry remains
  the place for *settings*, which is a separate thing.
- **The marketplace preview asset must be `preview.*` at the repo ROOT.** The
  catalog builder matches `preview.png|webp|jpg|jpeg|avif` there and nowhere
  else — a `docs/` or `screenshots/` folder is not detected, however the README
  links it. Ship exactly one: when several match, the extension order above
  decides, so a stale `preview.png` would quietly outrank a newer `.jpg`. The
  card renders at 720px and the detail view at 1600px, which is why the source
  screenshot is downscaled to 1600 wide rather than shipped full size.

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

### Large video libraries

The shell is long-lived, so nothing the panel does may scale with the size of
`~/Videos`. Two things used to:

- the scan's `StdioCollector` buffered the **entire** `find` output;
- a `Repeater` instantiated **one row per result** — a `Repeater` builds every
  delegate, so the enclosing `Flickable` bounded what you could *see* and not
  what existed.

Bounding what the scan **emits** is not the same as bounding what it **does**,
and that distinction cost two review rounds. `head` can only kill the producer
once the producer has emitted enough lines, so a folder holding a million
non-videos never reaches the cap and gets walked in full. Three separate bounds
are needed, and the walker is no longer `find`:

- **entries examined** — `ls -U` streams in directory order and is cut off by
  `head -n entryLimit` (20,000), so the count of entries *looked at* is capped,
  not just the count matched;
- **work per match** — the extension filter runs before any `stat`, so at most
  `scanLimit` files per directory are ever tested with `[ -f ]`;
- **wall-clock** — `timeout` wraps the whole process, the only bound that helps
  when it is blocked in a syscall on a dead network mount. An in-loop check
  never runs if nothing is being produced.

Measured on a deliberately sparse directory — 60,003 entries, only 3 of them
videos, which is the case a match-cap cannot touch:

| pipeline | entries examined | wall |
|---|---|---|
| `find \| head \| sort \| head` | **60,003 — all of them** | 41 ms |
| `ls -U \| head \| grep \| head` | **20,000, capped** | 25 ms |

Hitting the entry cap **exits 0**, so it would truncate silently — which reads
as "there was nothing else", a worse lie than a cap. The script reports it on
**stderr**, and a non-zero exit (deadline fired) sets the same flag. Arguments
go in as positional parameters, never interpolated into the script text.

Asking for one line past the cap is what makes "there are more" detectable
without a second scan. The list is a `ListView`, which recycles delegates, so
live objects track the height of the list rather than the library. The "off"
row rides along as the ListView `header`.

Measured on this box with 3000 clips in `~/Videos`, RSS of the `quickshell`
process before and after opening the panel:

| build | RSS delta on open |
|---|---|
| `Repeater`, uncapped scan | **+57 MB**, retained by the shell |
| `ListView`, capped scan | **+6 MB** |

`scanLimit` is 500. Capping the *browser* costs nothing in reach, because the
CLI takes an arbitrary path — `motion-wallpaper play <path>` plays a clip the
list never showed, which is what the truncation note tells the user. Reset
`videosTruncated` at the top of every scan or the note outlives the library that
earned it.

### A byte cap is not a deadline

Bounding *how much* a helper reads says nothing about *how long* it takes.
Point a user-writable path at a **FIFO** and the open blocks until a peer
attaches — forever, in practice — so the helper and whatever it was
initialising stay alive for the life of the session. Measured, with a FIFO in
place of each path:

| call | unguarded | guarded |
|---|---|---|
| `head -c` on the state path | **hangs** (killed at 6 s) | 2 ms |
| the CLI's `2>>"$LOG_FILE"` | **hangs** (killed at 6 s) | 44 ms |

Two guards, because neither is enough alone:

- **`[ -f ]` refuses anything that is not a regular file.** It stats rather
  than opens, so on a FIFO it answers immediately where the open would block.
  The CLI refuses a symlink too, rather than following one out of the cache
  directory.
- **`timeout` wraps every helper** — that is the only thing that helps when the
  block is in the syscall itself, as on a dead network mount, before any test
  of ours gets to run.

`_stateLoaded` gates the whole service, so a killed state read must still
initialise it on defaults or the plugin sits dead. There is a deferred fallback
on `onExited` for that — but **measured, it is not load-bearing**: when
`timeout` kills the helper the stream closes and `onStreamFinished` fires
anyway, and a control build with the fallback removed still initialises. It is
insurance against an ordering Quickshell does not document, not a fix for an
observed hang. Do not claim otherwise.

**Every** helper is wrapped via `timeoutPrefix`, not only the one that prompted
it: the state read and write, the `mkdir`, the stat probe and the fullscreen
watcher. A subprocess in a long-lived shell must never be able to outlive its
job. The atomic write also self-heals a hostile path — `mv -f` puts a regular
file back over the FIFO, verified live.

### Reading state.json without loading it

A `FileView` reads the **whole file into the shell before any handler of ours
runs**, so checking the size inside `applyStateText` rejected an oversized file
only after it had already been allocated in the long-lived process — and the
allocation was the thing being prevented. Quickshell's `FileView` has no
size-bound property, so the read goes through `head -c <cap + 1>` in a helper
instead, and `FileView` is gone from this plugin entirely.

Two rules that shaped it:

- **Read one byte past the cap.** That is what separates "exactly at the limit"
  from "truncated" without looking at the file twice.
- **Never size-then-reopen.** A `stat` describes a file the reopen may not get,
  and the reopen is the unbounded one. One bounded read, then validate what is
  held.

Writes are atomic without `FileView` too: a `mktemp` in the same directory then
`mv -f` over the target, with the payload passed as a positional parameter. A
write arriving while one is in flight is held in `_pendingState` and issued on
exit, so concurrent saves cannot interleave.

### state.json is untrusted input

`~/.local/state/motion-wallpaper/state.json` is writable by anything running as
this user, and the shell that reads it never exits. So it is untrusted in
*size* as much as in content: a path out of it becomes a process argument, and
a `screenVideos` key is deliberately retained for a disconnected monitor
indefinitely. Neither may be unbounded. Four limits, in `Service.qml`:

| limit | value | why |
|---|---|---|
| `maxStateBytes` | 256 KB | checked **before** `JSON.parse`, which would otherwise build the whole tree in the shell's heap before any per-field limit could apply |
| `maxPathLength` | 4096 | `PATH_MAX`; anything longer is not a path |
| `maxScreenVideos` | 64 | far above any real monitor count |
| `maxNameLength` | 256 | connector names are short |

The same limits apply to values arriving over IPC, not just from the file, and
to the `shell.json` config seed. **Clamp at every assignment site, not just the
one that prompted the fix** — `videoPath` and `output` are each written from
five places (state file, config seed twice, `play`, `playAll`/`setOutput`), and
bounding only the file leaves the IPC path wide open. They now all go through
`safePath()` / `safeName()`. `applySetScreenVideo` is the call that can grow the
map, so it refuses a **new** key at the cap while still allowing an existing one
to be overwritten.

Confirmed against hostile IPC as well as a hostile file: a 20,005-char path to
`play` leaves `videoPath` untouched, a 9,000-char `setOutput` lands as `"all"`,
and a `playOn` with a 9,000-char connector name adds no entry.

Verified by pointing the shell at a hostile file rather than by reading the
code. A 1.1 MB `state.json` is refused whole (`videoPath` `""`, `output`
`"all"`, `screenVideos` `{}`). One crafted to sit *under* the byte cap, so the
per-field limits have to do the work, lands as: `videoPath` 10,005 chars → 0,
`output` 5,000 chars → `"all"`, `screenVideos` 3,000 entries → 64.

### Hostile clip names

Clip names come off disk, so they are attacker-controlled — a file dropped in
`~/Videos` (or arriving on someone else's camera card) can be named anything.
QML `Text` defaults to `Text.AutoText`, which runs Qt's `mightBeRichText()`
heuristic and silently switches to rich text when the string looks like markup;
an `<img src="http://host/x.png">` in a filename is then **parsed and fetched
as a resource**. Measured on a name carrying `width="300" height="120"`:

| rendering | resolved format | `contentHeight` |
|---|---|---|
| `AutoText` (default) | rich text | 120 — the attacker's own value |
| `textFormat: Text.PlainText` | plain | 19 — one line of literal characters |
| angle brackets stripped | plain | 19 |

Two defences, because there are two kinds of sink:

- **Every `Text` in this plugin sets `textFormat: Text.PlainText`** — all of
  them, not just the ones that currently take a filename, so anything added
  later inherits the safe default.
- **`plainName()` strips `<` and `>`** from the name before it is handed to
  `PanelHero.meta` or a `Dropdown` label. Those are drawn by the shell's own
  kit, whose `Text` elements are bare `AutoText` and are not ours to change, so
  the string has to be safe before it crosses over.

No tool catches this: it passes `omarchy plugin validate`, the marketplace
security baseline and `qmllint`. Reproduce it with
`QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1 /usr/lib/qt6/bin/qml t.qml`
— without `QT_FORCE_STDERR_LOGGING=1`, `console.log` prints nothing and the run
looks silently broken.

### What Omarchy 4 removed

The plugin predates Omarchy 4 and carried three things that no longer hold.
Worth knowing, because the same drift catches anything ported from Omarchy 3:

- **Walker is not the launcher any more.** Omarchy 4 ships a native `menu`
  shell plugin, which enumerates apps through Quickshell's `DesktopEntries`
  (standard XDG paths, watched directly). The only two `walker` strings left
  under `/usr/share/omarchy/shell` are the *word* in comments — a TOML walker,
  i.e. a parser.
- **`elephant.service` is gone with it.** It was Walker's data provider, and
  the installer used to restart it so a new `.desktop` file showed up without a
  re-login. There is no such unit on Omarchy 4, so the call was dead code —
  harmless only because it was guarded by `is-active`. Dropping it also removed
  the `service-management` capability from the marketplace security baseline.
- **`bindd = …` in a `.conf` is dead.** Omarchy 4 reads `hyprland.lua`; user
  keybinds go in `~/.config/hypr/bindings.lua` as
  `o.bind("SUPER + ALT + W", "…", "…")`.

**The installer no longer creates a `.desktop` entry or installs an icon.** The
UI is the bar widget and its panel, so a launcher entry only duplicated the icon
already sitting in the bar, and the hicolor icon had no other consumer — the
widget draws a font glyph (`󰕧`), not the SVG. Both are deleted on upgrade
rather than left to linger in the menu.

### The CLI log is rotated

`~/.cache/motion-wallpaper.log` collects stderr from every IPC call. A keybind
pressed against a shell that is not running appends on **every press**, so
unrotated it grows without limit. `rotate_log` moves it aside at 256 KB, giving
a hard ceiling of two files. One rotation is enough — the log is only ever read
for the most recent failure.

## Known limitations

- Decoding runs continuously on the GPU. Auto-pause covers fullscreen windows;
  on battery, stopping or using a shorter, lower-bitrate clip is the bigger win.
