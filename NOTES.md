# Dev notes — Motion Wallpaper (Omarchy 4)

Working notes for picking the project back up. Last updated: 2026-07-31.

## Status

**PARKED 2026-07-31.** Omarchy 4 native plugin, working and installed on this
box. Two commits landed today (`bd1d8f7` cross-fade, `eb48868` Omarchy 3
cleanup), working tree clean.

⚠️ **Both remotes are behind — this is the main open item.**

| Remote | state | tag |
|---|---|---|
| local `master` | `eb48868` | — |
| `github` (28allday, canonical public) | **2 behind** | has `legacy-omarchy3` |
| `origin` (Forgejo, nosignal) | **6 behind** | **missing `legacy-omarchy3`** |

Forgejo is still on `96a9b33`, i.e. the *pre-Omarchy-4 mpvpaper code* — the whole
rewrite plus today's work is absent there. A dual push (plus pushing the tag to
Forgejo) brings them into lockstep.

### Pickup list

1. **Dual push** — see table above. Offered and deferred repeatedly since
   2026-07-20.
2. `legacy-omarchy3` tag: **KEEP** — Gav's explicit call 2026-07-31. It marks the
   last mpvpaper-era commit as a quiet archive. The README no longer advertises
   it, so it is an archive rather than a supported path. Do not delete it.
3. Untested paths: multi-monitor (this box is single-output HDMI-A-1), and the
   `output` selector beyond `"all"`.

## Gotchas that will bite you

- **The plugin installs as a COPY, not a symlink.** `wallpaper.sh` deliberately
  replaces any symlink with a real copy in
  `~/.config/omarchy/plugins/nosignal.motion-wallpaper/`. So **editing the repo
  does not change the running plugin** — re-run `wallpaper.sh`, or copy the files
  over, then restart. Repo and installed copy can silently drift; check with
  `diff -rq plugin/nosignal.motion-wallpaper ~/.config/omarchy/plugins/nosignal.motion-wallpaper`.
- **Reload after QML edits = `omarchy-restart-shell`.** `rescanPlugins` does NOT
  reload edited code. Never `omarchy-refresh-shell` — it resets shell.json.
- **`hyprctl dispatch workspace N` does not work on Omarchy 4.** Dispatch is now a
  Lua shorthand for `hl.dispatch(...)` and wants a dispatcher object under
  `hl.dsp.*`; the plain form, and every quoted variant, fails. `hl.dsp.workspace`
  is a table whose `.go` / `.switch` are nil — the working leaf call was never
  pinned down. Don't burn time on it; see the screenshot trick below.
- **PipeWire `spaVisitChoice` warning is benign and pre-existing.** It fires
  whenever a `MediaPlayer` with an `AudioOutput` is created — verified zero
  occurrences with motion stopped, one after a clip starts. The muted
  `AudioOutput` is deliberate; leave it.

## Cross-fade on clip change (2026-07-31, `bd1d8f7`)

Gav: changing the clip "blinks back to the desktop". Cause was a single
`MediaPlayer` per surface — assigning a new `source` clears its `VideoOutput`
while the new file opens, so nothing painted the background layer for a few
hundred ms and the static wallpaper showed through.

Each monitor surface now carries an **A/B pair** of `VideoOutput` +
`MediaPlayer`:

- the incoming clip loads into whichever pair is idle and **plays there
  off-screen** (it must actually run to produce a frame);
- the back pair's **`videoSink` first `videoFrameChanged`** is the cue to cross
  over — a 220ms opacity fade, `frontIsA` flips;
- the outgoing player is stopped and its source cleared after the fade, so
  **steady state is still one active decoder**.

The frame-arrival cue is the whole point: waiting on `mediaStatus` or a fixed
delay would still race the decoder.

Guards worth keeping:

- a **bad incoming clip abandons the swap** and keeps whatever is showing — a
  broken file must never take the wallpaper down;
- a **4s timeout** crosses over anyway if the new clip never delivers a frame
  *and* never errors (otherwise a swap could hang forever);
- **re-picking the clip already showing** cancels an in-flight swap rather than
  stacking another one.

### How it was verified (repeat this if you touch the swap)

Screenshot comparison, because "does it blink" is not answerable by reading QML:

1. `motion-wallpaper stop`, wait, capture a **wallpaper-only strip** as the
   static reference. Get a strip from `hyprctl -j clients` geometry — with two
   tiled windows the **bottom gap is full-width and pure wallpaper**
   (`grim -g "0,1428 2560x12"` on this box). This avoids needing an empty
   workspace, which the Lua dispatch gotcha above makes awkward.
2. Play clip A, confirm the strip is far from the reference (got 122.2 mean
   per-byte distance — if it is small, the clips are indistinguishable from the
   wallpaper and the test proves nothing).
3. Sample the strip in a tight `grim` loop (~30 samples/s) while issuing the
   switch to clip B; report the **closest approach to the static reference**.

Results — **always run the old code as a control**, or you cannot tell a passing
test from an insensitive one:

| build | closest approach | meaning |
|---|---|---|
| single-player (old) | **0.0** | pixel-exact match — desktop fully exposed |
| A/B (new), SMPTE→win98 | 99.0 | cross-fade blend of the two clips |
| A/B (new), SMPTE→farewell | 82.7 | cross-fade blend |

## Omarchy 3 cleanup (2026-07-31, `eb48868`)

No legacy *code* remained — the tree was already pure Omarchy 4 — but the shipped
files still referenced the mpvpaper/swaybg/socat era, and one reference was an
actual documentation bug:

- **`wallpaper.sh`'s header listed `gum` as a dependency** and called the CLI a
  "gum TUI/CLI", contradicting the dependency probe twenty lines below (which
  installs jq/python/hyprland/qt6-multimedia and correctly notes the UI is
  native). Anyone following the header would have installed a package this
  project has not needed since the rewrite.
- the "not found" error told Omarchy ≤3 users to fetch a legacy mpvpaper release;
- `manifest.json` billed itself as replacing mpvpaper;
- `Service.qml` and the README referenced the retired socat watcher.

Tree now greps clean for `mpvpaper|swaybg|socat|waybar|gum|TUI|omarchy 3`.

## Imported from memory — 2026-08-02 (project_motion_wallpaper.md)

Repo: `~/Projects/Motion-Wallpaper-Omarchy/`
Remotes: `origin` → `git.no-signal.uk/nosignal/Motion-Wallpaper-Omarchy`, `github` → `github.com/28allday/Motion-Wallpaper-Omarchy` (push to both).

**2026-07-31 — cross-fade fix + Omarchy 3 cleanup (commits `bd1d8f7`, `eb48868`; LOCAL ONLY, neither remote pushed).** Gav: changing clip "blinks back to the desktop". Cause: one `MediaPlayer` per surface, so assigning a new `source` cleared its `VideoOutput` while the new file opened and the static wallpaper showed through for a few hundred ms. Fix = **A/B double buffer** per monitor surface: incoming clip loads into the idle `VideoOutput`+`MediaPlayer` pair and plays there off-screen, and the back pair's **`videoSink` delivering its first frame** is the cue to cross over (220ms opacity fade); the outgoing player is then stopped and its source cleared, so steady state is still ONE decoder. Guards: bad incoming clip → abandon the swap and keep what's showing (never take the wallpaper down); 4s timeout crosses over if no frame and no error; re-picking the current clip cancels an in-flight swap. **Measured with a control** (sampler comparing a wallpaper-only screen strip against a static-wallpaper reference): old code closest approach **0.0 = pixel-exact match** (desktop fully exposed), new code 99.0 / 82.7 across two clip pairs (the dip is the cross-fade blend, never the wallpaper). Then stripped the Omarchy 3 archaeology — **real bug found: `wallpaper.sh`'s header listed `gum` as a dependency and called the CLI a "gum TUI/CLI"**, contradicting the dependency probe 20 lines below (installs jq/python/hyprland/qt6-multimedia, no gum); also dropped the "use the legacy mpvpaper release" error text, manifest's "replaces mpvpaper", and the socat-watcher comments. Tree now has ZERO mpvpaper/swaybg/socat/waybar/gum/TUI references. **`legacy-omarchy3` tag KEPT** — Gav's explicit call 2026-07-31 (quiet archive; README no longer advertises it).

⚠️ **Push state (2026-07-31): `github` is 2 commits behind local, `origin`/forgejo is SIX behind and still has NO `legacy-omarchy3` tag** — forgejo holds only the pre-Omarchy-4 mpvpaper code. Dual push still pending/offered.

⚠️ **Testing gotcha:** `hyprctl dispatch workspace N` does NOT work on Omarchy 4 (Lua now) — see [[omarchy-lua-bindings]]. To screenshot the wallpaper without switching workspaces, read `hyprctl -j clients` geometry and sample a gap strip (the bottom gap below tiled windows is full-width and pure wallpaper).

**✅ 2026-07-20 — Rewritten as a native omarchy-shell QML plugin for Omarchy 4 (Option B, DONE; pushed to `github` 28allday master + `legacy-omarchy3` tag. NOT yet pushed to `origin`/forgejo).** Machine is Omarchy **4.0.0.alpha** (quickshell/omarchy-shell; Waybar+Mako+swaybg gone). Why the old tool died: (a) **swaybg uninstalled** — first-party wallpaper is now `/usr/share/omarchy/shell/plugins/background/Background.qml` (`PanelWindow` on `WlrLayer.Background`, ns `omarchy-background`); all `pkill swaybg` restore logic dead. (b) bg symlink moved `~/.config/omarchy/current/background` → **`~/.local/state/omarchy/current/background`** (theme colors.toml too → `~/.local/state/omarchy/current/theme/colors.toml`). (c) there's a `background` IPC target now.

**What shipped:** third-party plugin **`nosignal.motion-wallpaper`** (repo `plugin/nosignal.motion-wallpaper/`). Installed by `wallpaper.sh` as a COPY into `~/.config/omarchy/plugins/` — as of 2026-07-20 this box runs the copy install (was a dev symlink during the build). ⚠️ Copy install means editing the repo does NOT hot-reload the live plugin; for further dev, re-symlink `~/.config/omarchy/plugins/nosignal.motion-wallpaper → repo` then `omarchy-restart-shell`, or just re-run `wallpaper.sh`. Files:
- `Service.qml` — QtMultimedia MediaPlayer+VideoOutput on Background layer (ns `omarchy-motion-background`), one PanelWindow per targeted screen via `Variants{model:activeScreens}`, stacks above static bg (loads later). Native `Quickshell.Hyprland onRawEvent` + `hyprctl` per-monitor fullscreen auto-pause (no socat). State → `~/.local/state/motion-wallpaper/state.json` (videoPath, enabled, output, pauseOnFullscreen — all live/persisted). IPC target **`motion-wallpaper`**: play/stop/toggle/pause/resume/status/setOutput/setPauseOnFullscreen. setOutput is live (no restart).
- `manifest.json` — kinds `["service","bar-widget"]`.
- `BarWidget.qml` + `Panel.qml` — native bar widget (nf-md-video glyph, colour=state) + dropdown panel (play/pause/stop, screen dropdown, autopause toggle, video list from ~/Videos/Wallpapers & ~/Videos), mirrors the panels/audio+bluetooth pattern; reaches service via `bar.shell.serviceFor()`.
- `motion-wallpaper` (CLI, `~/.local/bin`) — thin IPC wrapper (no gum): status/play/stop/toggle/pause/resume/screen/autopause.
- `wallpaper.sh` — installs plugin + CLI + icon + .desktop(toggle); registers plugin in shell.json `plugins[]` AND bar widget in `bar.layout.right`; deps qt6-multimedia/jq/python/hyprland.

**Reload after QML edits = `omarchy-restart-shell`** (rescanPlugins does NOT reload edited code; never `omarchy-refresh-shell` — resets shell.json). DROPPED: mpvpaper, socat watcher, theme-watcher, systemd unit, gum TUI. **Legacy mpvpaper/swaybg version preserved on git tag `legacy-omarchy3`** (Omarchy ≤3), pushed to github. Old bash "Shape" notes below = legacy (those files removed from master, live only on the tag). See [[omarchy-quickshell-migration]], [[reference_omarchy_wallpaper]] (its swaybg claim is now ≤3 only).

**Git state (end of 2026-07-20 session):** github 28allday master @ `71356e6` (4 commits: migration, panel+CLI, installer-copy-fix, README github-URL fix) + `legacy-omarchy3` tag pushed. ⚠️ `origin`/forgejo NOT pushed yet (user's usual dual-push still pending — offered, deferred). README clone URL now → github (canonical per [[feedback_github_canonical_links]]).

**Non-bug noted:** the bar icon looking grey while I thought a video was playing was NOT a bug — the icon correctly reflects state (muted=stopped, accent=playing, amber=paused); it was grey because playback had been stopped. Verified via bar screenshots. Don't re-chase it.

**Shape:**
- `wallpaper.sh` — installer. Only invokes sudo/yay when packages are actually missing. Installs into `~/.local/bin`, `~/.local/share/{applications,icons/hicolor/scalable/apps}`, and `~/.config/systemd/user/`. Refreshes `elephant.service` so Walker picks up the new `.desktop`/icon without logout.
- `motion-wallpaper-toggle` — main gum TUI. Actions: `toggle | start | stop | change | status`. Header shows running state + target + video + autostart state.
- `motion-wallpaper-watcher` — external auto-pause. Subscribes to Hyprland `socket2`, pauses/resumes mpv via `--input-ipc-server` on `fullscreen>>1/0`. Exists because mpvpaper's `-p` is flaky on Hyprland 0.54.x.
- `motion-wallpaper.service` — systemd user unit, `WantedBy=graphical-session.target`. TUI has first-run confirm + menu toggle; enable/disable via `systemctl --user enable|disable motion-wallpaper.service`.
- State file `~/.config/motion-wallpaper/state` holds `LAST_VIDEO`, `LAST_TARGET`, `LAST_DIR`. Atomic tmp+mv write, parsed with `read` (not `source`) to avoid arbitrary code execution from video paths.

**Deps:** mpv, jq, gum, socat, libnotify (repos); mpvpaper (AUR).
**Log:** `~/.cache/motion-wallpaper.log`.

**How to apply:** When touching this repo, keep in mind the Omarchy-specific wallpaper behaviour — see `reference_omarchy_wallpaper.md` for the non-obvious pieces (swaybg not hyprpaper, setsid+uwsm-app, elephant cache).
