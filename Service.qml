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

  function pathExists(p) {
    var r = resolvePath(p)
    return r !== "" && root.existingPaths[r] === true
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
    return out
  }

  function checkVideoFiles() {
    var paths = candidatePaths()
    if (paths.length === 0) { root.existingPaths = ({}); return }
    if (statProc.running) { statDebounce.restart(); return }
    statProc.command = ["bash", "-c",
      'for p in "$@"; do [ -f "$p" ] && printf "%s\\n" "$p"; done', "_"].concat(paths)
    statProc.running = true
  }

  onVideoPathChanged: checkVideoFiles()
  onScreenVideosChanged: checkVideoFiles()

  Process {
    id: statProc
    stdout: StdioCollector {
      onStreamFinished: {
        var set = ({})
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          var p = lines[i].trim()
          if (p) set[p] = true
        }
        root.existingPaths = set
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

  // --------------------------------------------------------- clip resolution
  // The clip CONFIGURED for a monitor — its own override if it has one,
  // otherwise the default clip when `output` targets it. "" means nothing.
  // Ignores `enabled`, so the panel can show the assignment while stopped.
  function configuredPathForScreen(name) {
    var n = String(name)
    var sv = root.screenVideos || ({})
    if (Object.prototype.hasOwnProperty.call(sv, n)) return String(sv[n] || "")
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
      screenVideos: root.screenVideos || ({})
    }, null, 2) + "\n"
    stateFile.setText(payload)
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
          var ov = String(o.output || "all")
          root.output = (ov.length > root.maxNameLength || ov === "") ? "all" : ov
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
    var vp = String(cfg("videoPath", "") || "")
    var en = cfg("enabled", true) === true || String(cfg("enabled", "true")) === "true"
    var op = String(cfg("output", "all") || "all") || "all"
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

  FileView {
    id: stateFile
    path: root.statePath
    atomicWrites: true
    printErrors: false
    onLoaded: { root.applyStateText(text()); root._stateLoaded = true; root.syncSeedFromConfig() }
    onLoadFailed: function(err) { root._stateLoaded = true; root.syncSeedFromConfig() }
  }

  // Make sure the state dir exists, then (re)load the state file.
  Process {
    id: mkStateDir
    command: ["mkdir", "-p", root.stateDir]
    onExited: stateFile.reload()
  }

  Component.onCompleted: mkStateDir.running = true

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
    command: ["python3", "-c", root.fsScript]
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
        audioOutput: AudioOutput { muted: true; volume: 0 }
        onErrorOccurred: function(err, str) { panel.handleError(playerA, err, str) }
      }

      MediaPlayer {
        id: playerB
        videoOutput: outB
        loops: MediaPlayer.Infinite
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
      fullscreenMonitors: Object.keys(root.fullscreenMonitors)
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
                 && !(root.pauseOnFullscreen && root.fullscreenMonitors[n] === true)
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
    var p = String(path || "").trim()
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
    var p = String(path || "").trim()
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
    var n = String(name || "all").trim()
    root.output = n === "" ? "all" : n
    root.persistState()
    return root.statusObject()
  }

  function applySetPauseOnFullscreen(on) {
    root.pauseOnFullscreen = (on === true || String(on) === "true")
    root.persistState()
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

    function ping(): string { return "ok" }
  }
}
