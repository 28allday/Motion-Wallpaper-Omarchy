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
//     INITIAL seed for `videoPath` + `enabled`.
//   * ~/.local/state/motion-wallpaper/state.json is the runtime truth for
//     `videoPath` + `enabled`. IPC mutations (play/stop/toggle) write it, so
//     they survive shell restarts. When the config's videoPath/enabled changes
//     (e.g. edited in shell.json) the state file is re-seeded to match.
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
  property bool _stateLoaded: false
  property bool _stateHadOutput: false  // state.json carried an explicit output
  property bool _stateHadPause: false   // state.json carried an explicit pauseOnFullscreen

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

  readonly property string effectiveVideoUrl: videoFileExists ? toFileUrl(videoPath) : ""

  // Whether the configured video file actually exists on disk. Gating the
  // surface on this means a missing/unset file renders NO panel at all, so the
  // first-party static wallpaper shows through (never a black or frozen frame).
  property bool videoFileExists: false

  function checkVideoFile() {
    var p = resolvePath(root.videoPath)
    if (!p) { root.videoFileExists = false; return }
    statProc.command = ["test", "-f", p]
    statProc.running = true
  }

  onVideoPathChanged: checkVideoFile()

  Process {
    id: statProc
    onExited: function(code) { root.videoFileExists = (code === 0) }
  }

  // Screens we actually render a video surface on.
  property var activeScreens: {
    if (!enabled || !videoPath || !videoFileExists) return []
    var out = []
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      var s = screens[i]
      if (root.output === "all" || String(s.name) === root.output) out.push(s)
    }
    return out
  }

  // ------------------------------------------------------- persistence
  function persistState() {
    var payload = JSON.stringify({
      videoPath: root.videoPath,
      enabled: root.enabled,
      output: root.output,
      pauseOnFullscreen: root.pauseOnFullscreen
    }, null, 2) + "\n"
    stateFile.setText(payload)
  }

  function applyStateText(txt) {
    var t = String(txt || "").trim()
    if (!t) return false
    try {
      var o = JSON.parse(t)
      if (o && typeof o === "object") {
        if (o.videoPath !== undefined) root.videoPath = String(o.videoPath || "")
        if (o.enabled !== undefined) root.enabled = (o.enabled === true || String(o.enabled) === "true")
        if (o.output !== undefined) {
          root.output = String(o.output || "all") || "all"
          root._stateHadOutput = true
        }
        if (o.pauseOnFullscreen !== undefined) {
          root.pauseOnFullscreen = (o.pauseOnFullscreen === true || String(o.pauseOnFullscreen) === "true")
          root._stateHadPause = true
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
    var sig = JSON.stringify([vp, en, op, pf])
    if (!root._stateLoaded) return           // wait until state file has loaded
    if (root._seedSig === "") {               // first sync after load
      root._seedSig = sig
      if (!root.videoPath && vp) {            // no persisted video yet -> seed
        root.videoPath = vp
        root.enabled = en
      }
      if (!root._stateHadOutput) root.output = op            // no persisted output -> seed
      if (!root._stateHadPause) root.pauseOnFullscreen = pf  // no persisted flag -> seed
      persistState()
      return
    }
    if (sig !== root._seedSig) {              // config edited -> re-seed state
      root._seedSig = sig
      root.videoPath = vp
      root.enabled = en
      root.output = op
      root.pauseOnFullscreen = pf
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
  // Native: Quickshell.Hyprland.rawEvent tells us WHEN to re-check; hyprctl
  // gives us per-monitor ground truth (which monitor's visible workspace has a
  // fullscreen window). Replaces the old external socat watcher.
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

      VideoOutput {
        id: videoOut
        anchors.fill: parent
        fillMode: VideoOutput.PreserveAspectCrop
      }

      MediaPlayer {
        id: player
        source: root.effectiveVideoUrl
        videoOutput: videoOut
        loops: MediaPlayer.Infinite
        audioOutput: AudioOutput { muted: true; volume: 0 }

        onErrorOccurred: function(err, str) {
          if (err !== MediaPlayer.NoError)
            console.warn("motion-wallpaper: MediaPlayer error on", panel.monName, ":", str)
        }
      }

      function sync() {
        if (root.effectiveVideoUrl === "") { player.stop(); return }
        if (shouldPlay) {
          if (player.playbackState !== MediaPlayer.PlayingState) player.play()
        } else {
          if (player.playbackState === MediaPlayer.PlayingState) player.pause()
        }
      }

      onShouldPlayChanged: sync()
      Component.onCompleted: sync()
      Connections {
        target: player
        function onSourceChanged() { Qt.callLater(panel.sync) }
      }
    }
  }

  // ---------------------------------------------------------------- IPC
  function statusObject() {
    return {
      enabled: root.enabled,
      videoPath: root.videoPath,
      videoFileExists: root.videoFileExists,
      output: root.output,
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

  // Live monitor targeting. Persists and re-evaluates activeScreens, so the
  // video surfaces move/appear/disappear with NO shell restart.
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
