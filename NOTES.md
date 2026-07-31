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
