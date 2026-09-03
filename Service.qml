import QtQuick
import QtMultimedia
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

// Motion Wallpaper service plugin for omarchy-shell.
//
// Renders a looping, muted video on the Wayland background layer (namespace
// "omarchy-motion-background"), one PanelWindow per targeted monitor, above the
// first-party static wallpaper (namespace "omarchy-background"). Monitors that
// are not targeted get no surface at all, so the static wallpaper shows through.
//
// State model
// -----------
//   * shell.json plugins[] entry (this plugin's id) is authoritative for the
//     config-only options `output` and `pauseOnFullscreen`, and provides the
//     INITIAL seed for `videoPath` + `enabled` + `screenVideos`.
//   * ~/.local/state/motion-wallpaper/state.json is the runtime truth for
//     `videoPath` + `enabled`. IPC mutations (play/stop/toggle) write it, so
//     they survive shell restarts. When the config's videoPath/enabled changes
//     (e.g. edited in shell.json) the state file is re-seeded to match.
//
// Which clip plays where
// ----------------------
// Three layers, most specific first, resolved per monitor by pathForScreen():
//   1. `screenVideos[<connector>]` — a per-monitor clip. An empty string means
//      "this monitor stays static", which is how a single screen is blanked
//      while others keep playing.
//   2. `videoPath`, if `output` is "all" or names this monitor.
//   3. nothing — no surface, static wallpaper shows through.
// So different monitors can run different clips, and `output` remains the
// coarse (legacy, CLI-facing) targeting switch for monitors with no override.
Item {
  id: root

  // ---- injected by shell.qml (_syncServices/ensureService) ----
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null
  property var pluginRegistry: null

  readonly property string pluginId: "nosignal.motion-wallpaper"
  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: home + "/.local/state/motion-wallpaper"
  readonly property string statePath: stateDir + "/state.json"

  // ---------------------------------------------------------------- config
  // Read this plugin's entry out of the live shell config.
  readonly property var pluginConfig: {
    var cfg = shell && shell.shellConfig ? shell.shellConfig : null
    if (!cfg || !Array.isArray(cfg.plugins)) return ({})
    for (var i = 0; i < cfg.plugins.length; i++) {
      var e = cfg.plugins[i]
      if (e && String(e.id).replace(/^@/, "") === pluginId) return e
    }
    return ({})
  }

  function cfg(name, fallback) {
    var v = pluginConfig ? pluginConfig[name] : undefined
    return (v === undefined || v === null) ? fallback : v
  }

  // ------------------------------------------------------------- bounds
  // state.json lives under ~/.local/state, so it is writable by anything
  // running as this user, and the shell that reads it never exits. Every value
  // taken from it (or from the shell.json config entry, or from IPC) is
  // therefore treated as untrusted *size* as well as untrusted content: a
  // path becomes a process argument and a screenVideos key is retained for a
  // disconnected monitor indefinitely, so neither may be unbounded.
  readonly property int maxStateBytes: 262144   // refuse to parse a larger state file
  readonly property int maxPathLength: 4096     // PATH_MAX; longer is not a real path
  readonly property int maxScreenVideos: 64     // far above any real monitor count
  readonly property int maxNameLength: 256      // connector names are short
  readonly property int helperSeconds: 5        // hard deadline on every helper process

  // A byte cap bounds how much is read, NOT how long the read takes. Point the
  // state path at a FIFO and `head -c` blocks forever waiting for a writer,
  // which pins the helper and state initialisation open for the life of the
  // session. Two guards, because neither is sufficient alone:
  //
  //   * `[ -f ]` refuses anything that is not a regular file. It stats rather
  //     than opens, so it answers immediately on a FIFO instead of blocking.
  //   * `timeout` covers what a stat cannot answer quickly — a dead network
  //     mount blocks in the syscall itself, before any test of ours runs.
  //
  // Every helper below is wrapped, not just the one that reads state: a
  // subprocess in a long-lived shell must never be able to outlive its job.
  readonly property var timeoutPrefix: ["timeout", "-k", "1", String(root.helperSeconds)]

  // Clamp a connector/output name, falling back to `fallback` when it cannot
  // be one. Names are short by nature, so an over-long one is never genuine.
  function safeName(v, fallback) {
    var t = String(v === null || v === undefined ? "" : v).trim()
    if (t === "" || t.length > root.maxNameLength) return fallback
    return t
  }

  // Clamp a value to a sane path string, or "" if it cannot be one.
  function safePath(v) {
    if (v === null || v === undefined) return ""
    var t = String(v)
    if (t.length > root.maxPathLength) {
      console.warn("motion-wallpaper: ignoring a path of", t.length, "chars")
      return ""
    }
    return t
  }

  // ---------------------------------------------------------------- state
  // Runtime truth for videoPath + enabled + output + pauseOnFullscreen.
  // Seeded from the shell.json config entry on first run (and re-seeded when
  // that entry is edited), but mutated by IPC / the bar panel thereafter —
  // so the screen selector and auto-pause switch persist and take effect with
  // NO shell restart (the activeScreens binding below re-evaluates live).
  property string videoPath: ""
  property bool enabled: true
  property string output: "all"
  property bool pauseOnFullscreen: true
  property bool manualPaused: false   // set by IPC pause(); cleared by resume()/play()
  // Per-monitor clips: { "HDMI-A-1": "/path/clip.mp4", "DP-2": "" }.
  // A present key wins over videoPath/output for that monitor; "" means the
  // monitor stays on the static wallpaper. Keys for disconnected monitors are
  // kept, so a screen gets its clip back when it is plugged in again.
  property var screenVideos: ({})

  // ------------------------------------------------- speed + rotation state
  // Playback speed multiplier applied to every surface. Free anywhere in the
  // range at 2-decimal precision (0.66, 0.99, 1.37 ...) — clamped rather than
  // snapped, so a hand-edited state.json still cannot drive the decoder
  // somewhere absurd.
  readonly property real minSpeed: 0.25
  readonly property real maxSpeed: 2.0
  property real playbackSpeed: 1.0

  // Rotation is OFF by default: with rotationMode "off" this plugin behaves
  // exactly as it did before — one clip, chosen by hand, until it is changed.
  //   "off"      one clip (videoPath / screenVideos), never changes on its own
  //   "all"      cycle every clip found in the library
  //   "selected" cycle only the clips in `playlist`
  property string rotationMode: "off"
  property string rotationOrder: "shuffle"   // "shuffle" | "sequential"
  property int rotationInterval: 10          // minutes between changes
  property var playlist: []                  // paths, used when mode is "selected"

  readonly property int maxPlaylist: 500     // matches the library scan cap
  readonly property int minInterval: 1
  readonly property int maxInterval: 60

  // Per-monitor rotation position: each screen keeps its own cursor and clip.
  // Ephemeral - not persisted, re-seeded on start.
  // Per-screen overrides: { "DP-1": { mode, order, interval, playlist } }.
  // A screen with no entry follows the globals above.
  property var screenRotation: ({})

  property var rotCurrent: ({})   // connector -> path showing right now
  property var rotCursor: ({})    // connector -> index into rotationPool

  property bool _stateLoaded: false
  property bool _stateHadOutput: false  // state.json carried an explicit output
  property bool _stateHadPause: false   // state.json carried an explicit pauseOnFullscreen
  property bool _stateHadScreens: false // state.json carried an explicit screenVideos

  // Track the config seed so a shell.json edit re-seeds the state file.
  property string _seedSig: ""

  function resolvePath(p) {
    if (!p) return ""
    var s = String(p)
    if (s.charAt(0) === "~") s = home + s.substring(1)
    return s
  }

  function toFileUrl(p) {
    if (!p) return ""
    var s = String(p)
    if (s.indexOf("://") !== -1) return s
    return "file://" + resolvePath(s).replace(/ /g, "%20")
  }

  // ------------------------------------------------------- file existence
  // Which of the configured clips actually exist on disk, keyed by RESOLVED
  // path. Gating each surface on this means a missing file renders NO panel on
  // that monitor, so the first-party static wallpaper shows through there
  // (never a black or frozen frame). With per-monitor clips there can be
  // several paths in play, so one process checks them all in a batch.
  property var existingPaths: ({})
  property var statedPaths: ({})   // paths the stat has actually examined

  // The scan already ran `[ -f ]` on each entry, so these are known-good
  // without waiting on the async stat below - which would otherwise blank the
  // surface for a frame every time rotation swapped in a library clip.
  readonly property var libraryPaths: {
    var set = ({})
    var av = root.availableVideos || []
    for (var i = 0; i < av.length; i++) set[resolvePath(av[i].path)] = true
    return set
  }

  function pathExists(p) {
    var r = resolvePath(p)
    if (r === "") return false
    if (root.existingPaths[r] === true) return true
    // The scan is a fallback for paths the stat has not covered yet. Once the
    // stat has actually looked at a path and not found it, the stat wins —
    // otherwise a clip deleted after the last scan keeps reporting as present
    // for up to the rescan interval.
    return root.libraryPaths[r] === true && root.statedPaths[r] !== true
  }

  // Every path the current state could render, resolved and deduplicated.
  function candidatePaths() {
    var seen = ({})
    var out = []
    function add(p) {
      var r = resolvePath(p)
      if (r === "" || seen[r]) return
      seen[r] = true
      out.push(r)
    }
    add(root.videoPath)
    var sv = root.screenVideos || ({})
    for (var k in sv) add(sv[k])
    // The rotation playlist has to be stat'd as well: rotationPool filters on
    // pathExists(), so leaving these out makes every chosen clip look missing
    // and the pool comes back empty.
    var pl = root.playlist || []
    for (var i = 0; i < pl.length; i++) add(pl[i])
    // ...and every per-screen playlist, for the same reason.
    var sr = root.screenRotation || ({})
    for (var sk in sr) {
      var spl = (sr[sk] && sr[sk].playlist) || []
      for (var si = 0; si < spl.length; si++) add(spl[si])
    }
    // Whatever rotation is showing right now, so a clip deleted mid-cycle is
    // noticed rather than trusted forever from the last scan.
    var rc = root.rotCurrent || ({})
    for (var rk in rc) add(rc[rk])
    return out
  }

  function checkVideoFiles() {
    var paths = candidatePaths()
    if (paths.length === 0) { root.existingPaths = ({}); return }
    if (statProc.running) { statDebounce.restart(); return }
    var asked = ({})
    for (var i = 0; i < paths.length; i++) asked[paths[i]] = true
    statProc.asked = asked
    statProc.command = root.timeoutPrefix.concat(
      ["bash", "-c", 'for p in "$@"; do [ -f "$p" ] && printf "%s\\n" "$p"; done', "_"]).concat(paths)
    statProc.running = true
  }

  onVideoPathChanged: checkVideoFiles()
  onScreenVideosChanged: checkVideoFiles()
  onPlaylistChanged: checkVideoFiles()
  onRotCurrentChanged: checkVideoFiles()

  Process {
    id: statProc
    // What this run was asked about. Published only once the run finishes, so
    // statedPaths means what its name says; setting it at request time made
    // pathExists() reject a path the stat had not looked at yet, dropping the
    // surface for the round trip.
    property var asked: ({})
    stdout: StdioCollector {
      onStreamFinished: {
        var set = ({})
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          var p = lines[i].trim()
          if (p) set[p] = true
        }
        root.existingPaths = set
        root.statedPaths = statProc.asked
      }
    }
  }

  Timer {
    id: statDebounce
    interval: 80
    repeat: false
    onTriggered: root.checkVideoFiles()
  }

  // Kept for the panel, the bar icon and the CLI: does the DEFAULT clip exist.
  readonly property bool videoFileExists: pathExists(videoPath)

  // ------------------------------------------------ speed + rotation helpers
  // Clamp into range and round to 2 decimals. Rounding keeps the persisted
  // value tidy and stops a drag from writing 0.6600000000000001.
  function safeSpeed(v) {
    var n = Number(v)
    if (!isFinite(n) || n <= 0) return 1.0
    n = Math.max(root.minSpeed, Math.min(root.maxSpeed, n))
    return Math.round(n * 100) / 100
  }

  function safeMode(v) {
    var m = String(v || "")
    return (m === "all" || m === "selected") ? m : "off"
  }

  function safeOrder(v) {
    return String(v || "") === "sequential" ? "sequential" : "shuffle"
  }

  function safeInterval(v) {
    var n = Math.round(Number(v))
    if (!isFinite(n)) return 10
    return Math.max(root.minInterval, Math.min(root.maxInterval, n))
  }

  // Same defensive shape as normalizeScreenVideos: a flat array of real paths,
  // capped, deduplicated, anything else dropped rather than trusted.
  function normalizePlaylist(v) {
    var out = []
    if (!v || typeof v !== "object" || typeof v.length !== "number") return out
    var seen = ({})
    for (var i = 0; i < v.length && out.length < root.maxPlaylist; i++) {
      var p = root.safePath(v[i])
      if (p === "" || Object.prototype.hasOwnProperty.call(seen, p)) continue
      seen[p] = true
      out.push(p)
    }
    return out
  }

  // Accept only { connector: { mode, order, interval, playlist } }; every field
  // is run through the same validators as the globals, and anything unexpected
  // is dropped rather than allowed to reach the render rule.
  function normalizeScreenRotation(v) {
    var out = ({})
    if (!v || typeof v !== "object") return out
    var n = 0
    for (var k in v) {
      if (n >= root.maxScreenVideos) break
      var name = root.safeName(k, "")
      if (name === "") continue
      var o = v[k]
      if (!o || typeof o !== "object") continue
      var e = ({})
      if (o.mode !== undefined) e.mode = root.safeMode(o.mode)
      if (o.order !== undefined) e.order = root.safeOrder(o.order)
      if (o.interval !== undefined) e.interval = root.safeInterval(o.interval)
      if (o.playlist !== undefined) e.playlist = root.normalizePlaylist(o.playlist)
      out[name] = e
      n++
    }
    return out
  }

  // ------------------------------------------------------------ the library
  // Lives here rather than in Panel.qml because rotation needs it with the
  // panel shut; the panel reads `availableVideos` instead of scanning again.
  readonly property int scanLimit: 500
  readonly property int entryLimit: 20000
  readonly property int scanSeconds: 5
  property var availableVideos: []      // [{ path, name }]
  property bool videosTruncated: false

  readonly property string scanScript:
    'lim=$1; emax=$2\n' +
    'for d in "$HOME/Videos/Wallpapers" "$HOME/Videos"; do\n' +
    '  [ -d "$d" ] || continue\n' +
    '  entries=$(ls -U -1 -- "$d" 2>/dev/null | head -n "$emax")\n' +
    '  [ -n "$entries" ] || continue\n' +
    '  if [ "$(printf "%s\\n" "$entries" | wc -l)" -ge "$emax" ]; then\n' +
    '    printf "TRUNC\\n" >&2\n' +
    '  fi\n' +
    '  printf "%s\\n" "$entries" |\n' +
    '    grep -iE "\\.(mp4|mkv|webm|mov|avi)$" | head -n "$lim" |\n' +
    '    while IFS= read -r f; do\n' +
    '      [ -f "$d/$f" ] && printf "%s/%s\\n" "$d" "$f"\n' +
    '    done\n' +
    'done | sort -u | head -n "$lim"\n'

  function rescanLibrary() { libraryScan.running = true }

  Process {
    id: libraryScan
    command: ["timeout", "-k", "1", String(root.scanSeconds),
              "bash", "-c", root.scanScript, "_",
              String(root.scanLimit + 1), String(root.entryLimit)]
    onExited: function(code) { if (code !== 0) root.videosTruncated = true }
    stderr: StdioCollector {
      onStreamFinished: if (String(text || "").indexOf("TRUNC") !== -1) root.videosTruncated = true
    }
    stdout: StdioCollector {
      onStreamFinished: {
        var seen = ({})
        var list = []
        root.videosTruncated = false
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          var pth = root.safePath(lines[i])
          if (pth === "" || Object.prototype.hasOwnProperty.call(seen, pth)) continue
          if (list.length >= root.scanLimit) { root.videosTruncated = true; break }
          seen[pth] = true
          var slash = pth.lastIndexOf("/")
          list.push({ path: pth, name: slash >= 0 ? pth.substring(slash + 1) : pth })
        }
        root.availableVideos = list
        root.seedRotation()
      }
    }
  }

  // So clips dropped into ~/Videos join the rotation without opening the panel.
  // Only while something is actually rotating: with rotation off nobody reads
  // the library except the panel, and the panel rescans when it opens.
  Timer {
    interval: 300000
    running: root.anyRotationActive
    repeat: true
    onTriggered: root.rescanLibrary()
  }

  // ----------------------------------------------------------- the rotation
  // The pool of clips rotation draws from, filtered to files that are really
  // there so a deleted clip cannot blank a monitor mid-cycle.
  // ------------------------------------------------- per-screen profiles
  // No entry in screenRotation means the screen follows the globals, which are
  // what the panel edits under "All screens". An entry overrides them.
  //
  // Everything derived is resolved once, here, into a real property. A binding
  // that reads `screenPlans` re-evaluates whenever any input changes -
  // screenRotation, the globals, the library, or the file-existence maps -
  // without anything having to remember to signal it.
  readonly property var screenPlans: {
    var plans = ({})
    var sr = root.screenRotation || ({})
    var gMode = root.rotationMode
    var gOrder = root.rotationOrder
    var gInterval = root.rotationInterval
    var gList = root.playlist || []
    var av = root.availableVideos || []

    // Read explicitly so the binding depends on them: the pool below is
    // filtered by pathExists(), which is a function call and would otherwise
    // leave no trace for QML to track.
    var _ex = root.existingPaths, _lib = root.libraryPaths, _st = root.statedPaths

    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      var n = String(screens[i].name)
      var o = Object.prototype.hasOwnProperty.call(sr, n) ? sr[n] : null

      var mode = root.safeMode(o && o.mode !== undefined ? o.mode : gMode)
      var order = root.safeOrder(o && o.order !== undefined ? o.order : gOrder)
      var interval = root.safeInterval(o && o.interval !== undefined ? o.interval : gInterval)
      var list = (o && o.playlist !== undefined) ? root.normalizePlaylist(o.playlist) : gList

      var pool = []
      if (mode === "selected") {
        for (var j = 0; j < list.length; j++)
          if (root.pathExists(list[j])) pool.push(String(list[j]))
      } else if (mode !== "off") {
        for (var k = 0; k < av.length; k++) pool.push(String(av[k].path))
      }

      plans[n] = {
        mode: mode, order: order, interval: interval,
        playlist: list, pool: pool,
        active: mode !== "off" && pool.length > 0,
        own: o !== null
      }
    }
    return plans
  }

  function planFor(name) {
    var p = root.screenPlans || ({})
    var n = String(name)
    return Object.prototype.hasOwnProperty.call(p, n) ? p[n] : null
  }

  // Thin readers over screenPlans, kept for the IPC/status surface. A screen
  // that is not connected has no plan, so these fall back to the globals.
  function hasOwnProfile(name) { var p = root.planFor(name); return p ? p.own === true : false }
  function rotModeFor(name) { var p = root.planFor(name); return p ? p.mode : root.safeMode(root.rotationMode) }
  function rotOrderFor(name) { var p = root.planFor(name); return p ? p.order : root.safeOrder(root.rotationOrder) }
  function rotIntervalFor(name) { var p = root.planFor(name); return p ? p.interval : root.safeInterval(root.rotationInterval) }
  function rotPlaylistFor(name) { var p = root.planFor(name); return p ? p.playlist : (root.playlist || []) }
  function rotationPoolFor(name) { var p = root.planFor(name); return p ? p.pool : [] }
  function rotationActiveFor(name) { var p = root.planFor(name); return p ? p.active === true : false }

  readonly property bool anyRotationActive: {
    var p = root.screenPlans || ({})
    for (var k in p) if (p[k].active === true) return true
    return false
  }

  function _pickIndex(name, pool, prevIdx) {
    if (pool.length <= 1) return 0
    if (root.rotOrderFor(name) === "sequential")
      return (prevIdx + 1) % pool.length
    var n = prevIdx
    for (var guard = 0; guard < 12 && n === prevIdx; guard++)
      n = Math.floor(Math.random() * pool.length)
    return n
  }

  // Idempotent: only touches a screen that has no clip yet, or whose clip has
  // fallen out of its pool. Safe to run on every screenPlans change, which is
  // what starts rotation the moment a pool becomes usable - the stat that fills
  // it is async, so the mutator that set the playlist ran too early to know.
  // Screens start at different offsets so a two-monitor setup does not open on
  // the same clip on both.
  function seedRotation() {
    var plans = root.screenPlans || ({})
    var cur = ({}), cus = ({})
    for (var a in root.rotCurrent) cur[a] = root.rotCurrent[a]
    for (var b in root.rotCursor) cus[b] = root.rotCursor[b]

    var changed = false
    var i = 0
    for (var n in plans) {
      var pl = plans[n]
      if (!pl.active) {
        if (cur[n] !== undefined) { delete cur[n]; delete cus[n]; changed = true }
      } else if (cur[n] === undefined || pl.pool.indexOf(cur[n]) < 0) {
        var idx = pl.order === "sequential"
                ? (i % pl.pool.length)
                : Math.floor(Math.random() * pl.pool.length)
        cus[n] = idx
        cur[n] = pl.pool[idx]
        changed = true
      }
      i++
    }
    if (changed) { root.rotCursor = cus; root.rotCurrent = cur }
  }

  // Each screen keeps its own cursor, so monitors sharing a playlist still sit
  // at different points in it.
  function advanceRotationFor(name) {
    var n = String(name)
    var pl = root.planFor(n)
    if (!pl || !pl.active) return
    var pool = pl.pool
    var prevCur = root.rotCursor || ({})
    var prev = Object.prototype.hasOwnProperty.call(prevCur, n) ? Number(prevCur[n]) : -1
    if (!isFinite(prev) || prev < 0 || prev >= pool.length) prev = 0
    var nxt = root._pickIndex(n, pool, prev)

    var cur = ({}), cus = ({})
    for (var a in root.rotCurrent) cur[a] = root.rotCurrent[a]
    for (var b in root.rotCursor) cus[b] = root.rotCursor[b]
    cus[n] = nxt
    cur[n] = pool[nxt]
    root.rotCursor = cus
    root.rotCurrent = cur
  }

  // "Next" with no screen advances every rotating screen.
  function advanceRotation(name) {
    if (name !== undefined && String(name) !== "" && String(name) !== "all") {
      root.advanceRotationFor(name)
      return
    }
    var plans = root.screenPlans || ({})
    for (var n in plans) root.advanceRotationFor(n)
  }

  // seedRotation() is idempotent, so hanging it off screenPlans covers every
  // input at once - the globals, per-screen overrides, the library, and the
  // async stat that decides whether a "selected" pool is usable yet.
  onScreenPlansChanged: root.seedRotation()

  // No global rotation timer any more: each monitor's surface owns its own,
  // running at that screen's own interval. See the Timer in the Variants
  // delegate below.

  // --------------------------------------------------------- clip resolution
  // The clip CONFIGURED for a monitor — its own override if it has one,
  // otherwise the default clip when `output` targets it. "" means nothing.
  // Ignores `enabled`, so the panel can show the assignment while stopped.
  function configuredPathForScreen(name) {
    var n = String(name)
    var sv = root.screenVideos || ({})
    var pinned = Object.prototype.hasOwnProperty.call(sv, n)

    // A monitor deliberately BLANKED ("" in screenVideos) stays blank — that is
    // the opt-out, and it is how you keep one screen out of the rotation.
    if (pinned && String(sv[n] || "") === "") return ""

    // Rotation drives every monitor the output targets, including ones with a
    // per-monitor clip. screenVideos is never rewritten, so switching rotation
    // off restores those assignments untouched.
    if (root.rotationActiveFor(n) && (root.output === "all" || root.output === n)) {
      var rc = root.rotCurrent || ({})
      if (Object.prototype.hasOwnProperty.call(rc, n) && String(rc[n] || "") !== "")
        return String(rc[n])
    }

    // Rotation off (or nothing seeded yet): the original behaviour, unchanged.
    if (pinned) return String(sv[n] || "")
    if (root.output === "all" || root.output === n) return String(root.videoPath || "")
    return ""
  }

  // The clip a monitor should show right now. "" means no surface.
  function pathForScreen(name) {
    return root.enabled ? root.configuredPathForScreen(name) : ""
  }

  // Same, as a playable url — empty unless the file is actually there.
  function urlForScreen(name) {
    var p = pathForScreen(name)
    if (p === "" || !pathExists(p)) return ""
    return toFileUrl(p)
  }

  // Screens we actually render a video surface on. Rebuilt whenever any input
  // changes, but always out of the SAME screen objects, so Variants only
  // creates/destroys surfaces that genuinely appeared or went away — a clip
  // change leaves the surface alone and is handled by its cross-fade.
  property var activeScreens: {
    var out = []
    if (!enabled) return out
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      var s = screens[i]
      if (root.urlForScreen(String(s.name)) !== "") out.push(s)
    }
    return out
  }

  // Is anything actually on screen right now? With per-monitor clips this is
  // no longer "enabled && the default file exists" — every monitor can have
  // been blanked individually — so the bar icon keys off this.
  readonly property bool rendering: activeScreens.length > 0

  // ------------------------------------------------------- persistence
  function persistState() {
    var payload = JSON.stringify({
      videoPath: root.videoPath,
      enabled: root.enabled,
      output: root.output,
      pauseOnFullscreen: root.pauseOnFullscreen,
      screenVideos: root.screenVideos || ({}),
      playbackSpeed: root.playbackSpeed,
      rotationMode: root.rotationMode,
      rotationOrder: root.rotationOrder,
      rotationInterval: root.rotationInterval,
      playlist: root.playlist || [],
      screenRotation: root.screenRotation || ({})
    }, null, 2) + "\n"
    root.writeState(payload)
  }

  // Accept only a flat { connector: path } object of strings — anything else in
  // the file or the config entry is ignored rather than allowed to poison the
  // render rule.
  function normalizeScreenVideos(v) {
    var out = ({})
    if (!v || typeof v !== "object" || Array.isArray(v)) return out
    var n = 0
    for (var k in v) {
      var name = String(k).trim()
      if (name === "" || name.length > root.maxNameLength) continue
      if (n >= root.maxScreenVideos) {
        console.warn("motion-wallpaper: screenVideos truncated at", root.maxScreenVideos, "entries")
        break
      }
      out[name] = root.safePath(v[k])
      n++
    }
    return out
  }

  function applyStateText(txt) {
    var t = String(txt || "").trim()
    if (!t) return false
    // Refuse an oversized file rather than handing it to JSON.parse, which
    // would build the whole tree in the shell's heap before any of the
    // per-field limits below could apply.
    if (t.length > root.maxStateBytes) {
      console.warn("motion-wallpaper: state.json is", t.length,
                   "bytes, over the", root.maxStateBytes, "limit - ignoring it")
      return false
    }
    try {
      var o = JSON.parse(t)
      if (o && typeof o === "object") {
        if (o.videoPath !== undefined) root.videoPath = root.safePath(o.videoPath)
        if (o.enabled !== undefined) root.enabled = (o.enabled === true || String(o.enabled) === "true")
        if (o.output !== undefined) {
          root.output = root.safeName(o.output, "all")
          root._stateHadOutput = true
        }
        if (o.pauseOnFullscreen !== undefined) {
          root.pauseOnFullscreen = (o.pauseOnFullscreen === true || String(o.pauseOnFullscreen) === "true")
          root._stateHadPause = true
        }
        if (o.screenVideos !== undefined) {
          root.screenVideos = root.normalizeScreenVideos(o.screenVideos)
          root._stateHadScreens = true
        }
        if (o.playbackSpeed !== undefined) root.playbackSpeed = root.safeSpeed(o.playbackSpeed)
        if (o.rotationMode !== undefined) root.rotationMode = root.safeMode(o.rotationMode)
        if (o.rotationOrder !== undefined) root.rotationOrder = root.safeOrder(o.rotationOrder)
        if (o.rotationInterval !== undefined) root.rotationInterval = root.safeInterval(o.rotationInterval)
        if (o.playlist !== undefined) root.playlist = root.normalizePlaylist(o.playlist)
        if (o.screenRotation !== undefined) root.screenRotation = root.normalizeScreenRotation(o.screenRotation)
        return true
      }
    } catch (e) {
      console.warn("motion-wallpaper: bad state.json:", e)
    }
    return false
  }

  // Seed from config on first run, and re-seed when the config seed changes.
  // videoPath/enabled/output/pauseOnFullscreen all seed from shell.json the
  // first time (unless state.json already carried them) and are re-seeded
  // wholesale when the shell.json entry is edited; between those, runtime
  // (IPC/panel) mutations win.
  function syncSeedFromConfig() {
    var vp = root.safePath(cfg("videoPath", ""))
    var en = cfg("enabled", true) === true || String(cfg("enabled", "true")) === "true"
    var op = root.safeName(cfg("output", "all"), "all")
    var pf = cfg("pauseOnFullscreen", true) === true || String(cfg("pauseOnFullscreen", "true")) === "true"
    var sv = normalizeScreenVideos(cfg("screenVideos", null))
    var sig = JSON.stringify([vp, en, op, pf, sv])
    if (!root._stateLoaded) return           // wait until state file has loaded
    if (root._seedSig === "") {               // first sync after load
      root._seedSig = sig
      if (!root.videoPath && vp) {            // no persisted video yet -> seed
        root.videoPath = vp
        root.enabled = en
      }
      if (!root._stateHadOutput) root.output = op            // no persisted output -> seed
      if (!root._stateHadPause) root.pauseOnFullscreen = pf  // no persisted flag -> seed
      if (!root._stateHadScreens) root.screenVideos = sv     // no persisted map -> seed
      persistState()
      return
    }
    if (sig !== root._seedSig) {              // config edited -> re-seed state
      root._seedSig = sig
      root.videoPath = vp
      root.enabled = en
      root.output = op
      root.pauseOnFullscreen = pf
      root.screenVideos = sv
      persistState()
    }
  }

  onPluginConfigChanged: syncSeedFromConfig()

  // state.json is read through `head -c`, not through a FileView.
  //
  // A FileView loads the WHOLE file into the shell before any handler of ours
  // runs, so checking the size in `applyStateText` rejected an oversized file
  // only after it had already been allocated in the long-lived process — the
  // allocation was the thing to prevent. Quickshell's FileView has no
  // size-bound property, so the read has to go through a helper that stops
  // reading at the limit.
  //
  // Reading one byte past the cap is what distinguishes "exactly at the limit"
  // from "truncated", without a second look at the file. Deliberately NOT
  // size-then-reopen: that describes a file the reopen might not get, and the
  // reopen is the unbounded one. One bounded read, then validate what is held.
  Process {
    id: stateReadProc
    command: root.timeoutPrefix.concat(
      ["bash", "-c",
       'if [ -L "$2" ] || [ ! -f "$2" ]; then exit 0; fi; ' +
       'head -c "$1" -- "$2" 2>/dev/null || true',
       "_", String(root.maxStateBytes + 1), root.statePath])
    stdout: StdioCollector {
      onStreamFinished: {
        stateReadFallback.stop()
        root.finishStateLoad(text)
      }
    }
    // A bail-out still has to answer: `_stateLoaded` gates the whole service,
    // so if nothing ever initialises it, the plugin sits dead rather than
    // falling back to defaults.
    //
    // Measured, that does not currently happen — when `timeout` kills this
    // helper the stream closes and `onStreamFinished` fires anyway, and a
    // build with this fallback removed still initialises on defaults. So it is
    // belt-and-braces against an ordering Quickshell does not actually
    // guarantee, not a fix for an observed hang. Deferred rather than
    // immediate because exit and stream-finish are unordered, and the
    // collector must win on the normal path.
    onExited: stateReadFallback.restart()
  }

  Timer {
    id: stateReadFallback
    interval: 250
    onTriggered: root.finishStateLoad("")
  }

  // Idempotent: whichever of the two paths arrives first initialises, the
  // other becomes a no-op.
  function finishStateLoad(txt) {
    if (root._stateLoaded) return
    root.applyStateText(txt)
    root._stateLoaded = true
    root.syncSeedFromConfig()
  }

  // Atomic write: a temp file in the same directory, then rename over the
  // target. The payload is built from already-clamped values and goes in as a
  // positional parameter, never interpolated into the script.
  Process {
    id: stateWriteProc
    onExited: if (root._pendingState !== "") { var q = root._pendingState; root._pendingState = ""; root.writeState(q) }
  }

  property string _pendingState: ""

  function writeState(payload) {
    if (stateWriteProc.running) { root._pendingState = payload; return }
    stateWriteProc.command = root.timeoutPrefix.concat(["bash", "-c",
      'd=$(dirname -- "$1"); mkdir -p -- "$d" || exit 1; ' +
      't=$(mktemp -- "$1.XXXXXX") || exit 1; ' +
      'printf %s "$2" > "$t" && mv -f -- "$t" "$1" || { rm -f -- "$t"; exit 1; }',
      "_", root.statePath, payload])
    stateWriteProc.running = true
  }

  // Make sure the state dir exists, then (re)load the state file.
  Process {
    id: mkStateDir
    command: root.timeoutPrefix.concat(["mkdir", "-p", root.stateDir])
    onExited: stateReadProc.running = true
  }

  Component.onCompleted: { mkStateDir.running = true; root.rescanLibrary() }

  // ------------------------------------------------------- fullscreen watch
  // Quickshell.Hyprland.rawEvent tells us WHEN to re-check; hyprctl gives us
  // per-monitor ground truth (which monitor's visible workspace has a
  // fullscreen window).
  property var fullscreenMonitors: ({})   // { "HDMI-A-1": true, ... }

  readonly property string fsScript:
    "import json,subprocess\n" +
    "def q(c):\n" +
    "    return json.loads(subprocess.check_output(['hyprctl','-j',c]))\n" +
    "try:\n" +
    "    mons=q('monitors'); wss=q('workspaces')\n" +
    "    fs={w.get('id'): bool(w.get('hasfullscreen')) for w in wss}\n" +
    "    for m in mons:\n" +
    "        aw=m.get('activeWorkspace') or {}\n" +
    "        if fs.get(aw.get('id')):\n" +
    "            print(m.get('name'))\n" +
    "except Exception:\n" +
    "    pass\n"

  function refreshFullscreen() {
    if (fsProc.running) { fsDebounce.restart(); return }
    fsProc.running = true
  }

  Process {
    id: fsProc
    command: root.timeoutPrefix.concat(["python3", "-c", root.fsScript])
    stdout: StdioCollector {
      onStreamFinished: {
        var set = ({})
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          var n = lines[i].trim()
          if (n) set[n] = true
        }
        root.fullscreenMonitors = set
      }
    }
  }

  Timer {
    id: fsDebounce
    interval: 120
    repeat: false
    onTriggered: root.refreshFullscreen()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      switch (event.name) {
        case "fullscreen":
        case "fullscreenv2":
        case "activewindow":
        case "activewindowv2":
        case "openwindow":
        case "closewindow":
        case "movewindowv2":
        case "changefloatingmode":
        case "workspace":
        case "workspacev2":
        case "focusedmon":
        case "focusedmonv2":
          fsDebounce.restart()
          break
      }
    }
  }

  // Initial fullscreen probe once things settle.
  Timer { interval: 400; running: true; repeat: false; onTriggered: root.refreshFullscreen() }

  // ---------------------------------------------------------------- render
  Variants {
    model: root.activeScreens

    PanelWindow {
      id: panel
      required property var modelData

      screen: modelData
      visible: true
      color: "transparent"
      anchors { top: true; bottom: true; left: true; right: true }

      // Keep render updates enabled: parked background surfaces with
      // updatesEnabled=false have been observed to lose their committed buffer
      // and leave a black desktop until the shell restarts.
      updatesEnabled: true

      WlrLayershell.namespace: "omarchy-motion-background"
      WlrLayershell.layer: WlrLayer.Background
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore

      readonly property string monName: String(modelData.name)
      readonly property bool monFullscreen: root.pauseOnFullscreen
                                            && (root.fullscreenMonitors[monName] === true)
      readonly property bool shouldPlay: !root.manualPaused && !monFullscreen

      // One timer per monitor, at that monitor's own interval. Gated on
      // shouldPlay so a fullscreen window does not churn wallpapers behind it.
      Timer {
        readonly property var plan: root.screenPlans[panel.monName] || null
        interval: plan ? plan.interval * 60000 : 600000
        running: root.enabled && panel.shouldPlay && plan !== null && plan.active === true
        repeat: true
        onTriggered: root.advanceRotationFor(panel.monName)
      }

      // ---- A/B double buffer ----
      // A single MediaPlayer per surface cannot change clips cleanly: assigning
      // a new source clears its VideoOutput while the new file opens, blinking
      // the static wallpaper through for a few hundred ms. So the incoming clip
      // loads into whichever pair is idle and plays there off-screen, and we
      // cross over only once it has actually delivered a video frame — leaving
      // something on screen at every moment. The outgoing player is retired
      // after the fade, so steady state is still one decoder.
      property bool frontIsA: true
      readonly property var frontPlayer: frontIsA ? playerA : playerB
      readonly property var backPlayer: frontIsA ? playerB : playerA
      property string frontUrl: ""      // url currently in the front pair
      property string pendingUrl: ""    // non-empty while a cross-over is in flight
      readonly property int fadeMs: 220

      VideoOutput {
        id: outA
        anchors.fill: parent
        fillMode: VideoOutput.PreserveAspectCrop
        opacity: panel.frontIsA ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: panel.fadeMs; easing.type: Easing.InOutQuad } }
      }

      VideoOutput {
        id: outB
        anchors.fill: parent
        fillMode: VideoOutput.PreserveAspectCrop
        opacity: panel.frontIsA ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: panel.fadeMs; easing.type: Easing.InOutQuad } }
      }

      MediaPlayer {
        id: playerA
        videoOutput: outA
        loops: MediaPlayer.Infinite
        playbackRate: root.playbackSpeed
        audioOutput: AudioOutput { muted: true; volume: 0 }
        onErrorOccurred: function(err, str) { panel.handleError(playerA, err, str) }
      }

      MediaPlayer {
        id: playerB
        videoOutput: outB
        loops: MediaPlayer.Infinite
        playbackRate: root.playbackSpeed
        audioOutput: AudioOutput { muted: true; volume: 0 }
        onErrorOccurred: function(err, str) { panel.handleError(playerB, err, str) }
      }

      // The back pair's first frame is the cue to cross over. Gated on a swap
      // being in flight so this is not running JS on every decoded frame.
      Connections {
        target: outA.videoSink
        enabled: panel.pendingUrl !== "" && !panel.frontIsA
        function onVideoFrameChanged() { panel.crossOver() }
      }

      Connections {
        target: outB.videoSink
        enabled: panel.pendingUrl !== "" && panel.frontIsA
        function onVideoFrameChanged() { panel.crossOver() }
      }

      // Safety net: if the incoming clip never delivers a frame AND never
      // errors, don't sit on the old one forever.
      Timer {
        id: swapTimeout
        interval: 4000
        repeat: false
        onTriggered: if (panel.pendingUrl !== "") panel.crossOver()
      }

      // Retire the outgoing player once the fade has finished.
      Timer {
        id: retire
        interval: panel.fadeMs + 60
        repeat: false
        property var victim: null
        onTriggered: {
          if (victim) { victim.stop(); victim.source = "" }
          victim = null
        }
      }

      function crossOver() {
        if (pendingUrl === "") return
        var outgoing = frontPlayer
        swapTimeout.stop()
        frontUrl = pendingUrl
        pendingUrl = ""
        frontIsA = !frontIsA
        retire.victim = outgoing
        retire.restart()
        Qt.callLater(panel.sync)
      }

      function handleError(who, err, str) {
        if (err === MediaPlayer.NoError) return
        console.warn("motion-wallpaper: MediaPlayer error on", panel.monName, ":", str)
        // A bad incoming clip must not take the wallpaper down with it:
        // abandon the swap and keep whatever is already on screen.
        if (who === backPlayer && pendingUrl !== "") {
          swapTimeout.stop()
          pendingUrl = ""
          who.stop()
          who.source = ""
        }
      }

      // Point the pairs at `url`, crossing over if something is already up.
      function requestUrl(url) {
        if (url === "") {
          swapTimeout.stop()
          pendingUrl = ""
          frontUrl = ""
          playerA.stop(); playerB.stop()
          playerA.source = ""; playerB.source = ""
          return
        }
        if (url === pendingUrl) return
        if (url === frontUrl) {          // already showing — cancel any swap back to it
          if (pendingUrl !== "") {
            swapTimeout.stop()
            pendingUrl = ""
            backPlayer.stop()
            backPlayer.source = ""
          }
          sync()
          return
        }
        if (frontUrl === "") {           // nothing on screen yet — load straight in
          frontUrl = url
          frontPlayer.source = url
          Qt.callLater(panel.sync)
          return
        }
        pendingUrl = url
        backPlayer.source = url
        backPlayer.play()                // must run to produce the frame we wait for
        swapTimeout.restart()
      }

      function sync() {
        var p = frontPlayer
        if (frontUrl === "") { p.stop(); return }
        if (shouldPlay) {
          if (p.playbackState !== MediaPlayer.PlayingState) p.play()
        } else {
          if (p.playbackState === MediaPlayer.PlayingState) p.pause()
        }
      }

      // This monitor's own clip — a per-screen override, or the default one.
      readonly property string wantUrl: root.urlForScreen(monName)
      onWantUrlChanged: requestUrl(wantUrl)
      onShouldPlayChanged: sync()
      Component.onCompleted: requestUrl(wantUrl)
    }
  }

  // ---------------------------------------------------------------- IPC
  function statusObject() {
    return {
      enabled: root.enabled,
      videoPath: root.videoPath,
      videoFileExists: root.videoFileExists,
      output: root.output,
      screenVideos: root.screenVideos || ({}),
      screens: root.screensObject(),
      pauseOnFullscreen: root.pauseOnFullscreen,
      manualPaused: root.manualPaused,
      activeScreens: (function () {
        var a = []
        for (var i = 0; i < root.activeScreens.length; i++) a.push(String(root.activeScreens[i].name))
        return a
      })(),
      fullscreenMonitors: Object.keys(root.fullscreenMonitors),
      playbackSpeed: root.playbackSpeed,
      rotationMode: root.rotationMode,
      rotationOrder: root.rotationOrder,
      rotationInterval: root.rotationInterval,
      rotationActive: root.anyRotationActive,
      playlist: root.playlist || [],
      libraryCount: (root.availableVideos || []).length
    }
  }

  // One entry per connected monitor: what it is showing and why. This is what
  // makes a per-screen setup inspectable from the CLI.
  function screensObject() {
    var out = []
    var sv = root.screenVideos || ({})
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      var n = String(screens[i].name)
      var own = Object.prototype.hasOwnProperty.call(sv, n)
      var p = root.pathForScreen(n)
      out.push({
        name: n,
        video: p,
        source: own ? "screen" : (p === "" ? "none" : "default"),
        fileExists: p !== "" && root.pathExists(p),
        paused: root.manualPaused
                || (root.pauseOnFullscreen && root.fullscreenMonitors[n] === true),
        playing: root.urlForScreen(n) !== "" && !root.manualPaused
                 && !(root.pauseOnFullscreen && root.fullscreenMonitors[n] === true),
        rotationMode: root.rotModeFor(n),
        rotationOrder: root.rotOrderFor(n),
        rotationInterval: root.rotIntervalFor(n),
        rotationActive: root.rotationActiveFor(n),
        rotationOwnProfile: root.hasOwnProfile(n),
        playlistCount: root.rotPlaylistFor(n).length
      })
    }
    return out
  }

  // Root-level mutators are the single source of truth. The IpcHandler below
  // delegates to them, and the bar panel (BarWidget.qml) calls them directly
  // on this service instance when it can reach it — so a click updates state
  // reactively in-process with no round-trip.

  // Enable + (optionally) set a new video, then persist.
  function applyPlay(path) {
    var p = root.safePath(String(path || "").trim())
    if (p) root.videoPath = p
    root.enabled = true
    root.manualPaused = false
    root.persistState()
    return root.statusObject()
  }

  // Disable rendering entirely (surfaces destroyed, static wallpaper shows).
  function applyStop() {
    root.enabled = false
    root.manualPaused = false
    root.persistState()
  }

  // Flip enabled on/off. Returns the new enabled state.
  function applyToggle() {
    root.enabled = !root.enabled
    if (root.enabled) root.manualPaused = false
    root.persistState()
    return root.enabled
  }

  function applyPause() { root.manualPaused = true }
  function applyResume() { root.manualPaused = false }

  // Play `path` on every monitor: sets the default clip, drops every
  // per-monitor override and un-targets, so "all screens" really means all of
  // them. This is what the panel's "All screens" scope calls; the plain
  // applyPlay() above leaves overrides and `output` alone.
  function applyPlayAll(path) {
    var p = root.safePath(String(path || "").trim())
    if (p) root.videoPath = p
    root.screenVideos = ({})
    root.output = "all"
    root.enabled = true
    root.manualPaused = false
    root.persistState()
    return root.statusObject()
  }

  // Play `path` on ONE monitor, leaving the others as they are. An empty path
  // blanks that monitor (its static wallpaper shows through) without touching
  // global enabled — that is how you keep video on the other screens.
  function applySetScreenVideo(name, path) {
    var n = String(name || "").trim()
    if (n === "" || n === "all") return root.applyPlayAll(path)
    if (n.length > root.maxNameLength) return root.statusObject()
    var p = root.safePath(String(path || "").trim())
    var m = ({})
    var sv = root.screenVideos || ({})
    for (var k in sv) m[k] = sv[k]
    // Adding a NEW key is what can grow the map without limit; overwriting an
    // existing one cannot, so it stays allowed at the cap.
    if (!m.hasOwnProperty(n) && Object.keys(m).length >= root.maxScreenVideos) {
      console.warn("motion-wallpaper: refusing a new screen entry at the", root.maxScreenVideos, "cap")
      return root.statusObject()
    }
    m[n] = p
    root.screenVideos = m
    if (p !== "") {                 // assigning a clip implies "play it"
      root.enabled = true
      root.manualPaused = false
    }
    root.persistState()
    return root.statusObject()
  }

  // Drop a monitor's override so it follows the default clip again.
  function applyClearScreenVideo(name) {
    var n = String(name || "").trim()
    if (n === "" || n === "all") {
      root.screenVideos = ({})
    } else {
      var m = ({})
      var sv = root.screenVideos || ({})
      for (var k in sv) if (k !== n) m[k] = sv[k]
      root.screenVideos = m
    }
    root.persistState()
    return root.statusObject()
  }

  // Live monitor targeting for monitors with no override of their own.
  // Persists and re-evaluates activeScreens, so the video surfaces
  // move/appear/disappear with NO shell restart.
  function applySetOutput(name) {
    root.output = root.safeName(name, "all")
    root.persistState()
    return root.statusObject()
  }

  function applySetPauseOnFullscreen(on) {
    root.pauseOnFullscreen = (on === true || String(on) === "true")
    root.persistState()
    return root.statusObject()
  }

  function applySetSpeed(v) {
    root.playbackSpeed = root.safeSpeed(v)
    root.persistState()
    return root.statusObject()
  }

  // A new object, so bindings reading the map actually re-evaluate.
  function _cloneScreenRotation() {
    var out = ({})
    var sr = root.screenRotation || ({})
    for (var k in sr) {
      var e = ({})
      for (var f in sr[k]) e[f] = sr[k][f]
      out[k] = e
    }
    return out
  }

  // screen === "" or "all" edits the global defaults; a connector name edits
  // just that monitor's profile, creating one if it had none.
  function applySetRotation(mode, order, minutes, screen) {
    var sc = String(screen === undefined ? "" : screen)
    if (sc === "" || sc === "all") {
      if (mode !== undefined && String(mode) !== "") root.rotationMode = root.safeMode(mode)
      if (order !== undefined && String(order) !== "") root.rotationOrder = root.safeOrder(order)
      if (minutes !== undefined && String(minutes) !== "") root.rotationInterval = root.safeInterval(minutes)
    } else {
      var m = root._cloneScreenRotation()
      var e = m[sc] || ({})
      if (mode !== undefined && String(mode) !== "") e.mode = root.safeMode(mode)
      if (order !== undefined && String(order) !== "") e.order = root.safeOrder(order)
      if (minutes !== undefined && String(minutes) !== "") e.interval = root.safeInterval(minutes)
      m[sc] = e
      root.screenRotation = m
    }
    root.seedRotation()
    root.persistState()
    return root.statusObject()
  }

  function applySetPlaylist(paths, screen) {
    var sc = String(screen === undefined ? "" : screen)
    if (sc === "" || sc === "all") {
      root.playlist = root.normalizePlaylist(paths)
    } else {
      var m = root._cloneScreenRotation()
      var e = m[sc] || ({})
      e.playlist = root.normalizePlaylist(paths)
      m[sc] = e
      root.screenRotation = m
    }
    root.seedRotation()
    root.persistState()
    return root.statusObject()
  }

  // Drop a screen's override so it follows the global settings again.
  function applyClearScreenRotation(screen) {
    var sc = root.safeName(screen, "")
    if (sc === "") return root.statusObject()
    var m = root._cloneScreenRotation()
    delete m[sc]
    root.screenRotation = m
    root.seedRotation()
    root.persistState()
    return root.statusObject()
  }

  // Skip ahead without waiting out the interval. No screen = every screen.
  function applyNextVideo(screen) {
    root.advanceRotation(screen)
    return root.statusObject()
  }

  IpcHandler {
    target: "motion-wallpaper"

    function play(path: string): string {
      return JSON.stringify(root.applyPlay(path))
    }

    function stop(): string {
      root.applyStop()
      return "stopped"
    }

    function toggle(): string {
      return root.applyToggle() ? "on" : "off"
    }

    function pause(): string {
      root.applyPause()
      return "paused"
    }

    function resume(): string {
      root.applyResume()
      return "playing"
    }

    // Play a clip on every monitor, clearing per-monitor overrides.
    function playAll(path: string): string {
      return JSON.stringify(root.applyPlayAll(path))
    }

    // Play a clip on ONE monitor: playOn("HDMI-A-1", "/path/clip.mp4").
    // An empty path blanks that monitor and leaves the others playing.
    function playOn(screen: string, path: string): string {
      return JSON.stringify(root.applySetScreenVideo(screen, path))
    }

    // Drop a monitor's own clip so it follows the default again ("all" clears
    // every override).
    function clearScreen(screen: string): string {
      return JSON.stringify(root.applyClearScreenVideo(screen))
    }

    // Per-monitor readout: what each connected screen is showing, and why.
    function screens(): string {
      return JSON.stringify(root.screensObject())
    }

    // Set targeted monitor: "all" or a connector name (e.g. "HDMI-A-1").
    function setOutput(name: string): string {
      return JSON.stringify(root.applySetOutput(name))
    }

    // Enable/disable auto-pause on fullscreen: "true" / "false".
    function setPauseOnFullscreen(on: string): string {
      return JSON.stringify(root.applySetPauseOnFullscreen(on))
    }

    function status(): string {
      return JSON.stringify(root.statusObject())
    }

    function setSpeed(value: string): string {
      return JSON.stringify(root.applySetSpeed(value))
    }

    function setRotation(mode: string, order: string, minutes: string): string {
      return JSON.stringify(root.applySetRotation(mode, order, minutes, ""))
    }

    // Same, aimed at one monitor: setRotationOn DP-1 all shuffle 5
    function setRotationOn(screen: string, mode: string, order: string, minutes: string): string {
      return JSON.stringify(root.applySetRotation(mode, order, minutes, screen))
    }

    // Drop a screen's own profile; it follows the global settings again.
    function clearRotationOn(screen: string): string {
      return JSON.stringify(root.applyClearScreenRotation(screen))
    }

    function setPlaylist(paths: string): string {
      return JSON.stringify(root.applySetPlaylist(String(paths || "").split(":"), ""))
    }

    function setPlaylistOn(screen: string, paths: string): string {
      return JSON.stringify(root.applySetPlaylist(String(paths || "").split(":"), screen))
    }

    function next(): string {
      return JSON.stringify(root.applyNextVideo(""))
    }

    function nextOn(screen: string): string {
      return JSON.stringify(root.applyNextVideo(screen))
    }

    function ping(): string { return "ok" }
  }
}
