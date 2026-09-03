import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Bar widget for the Motion Wallpaper service. A single film glyph whose color
// reflects playback state, and a click-driven dropdown (Panel.qml) anchored to
// the icon — the same KeyboardPanel + BarIconButton mechanism the first-party
// audio/bluetooth widgets use.
//
// State + control both go through the live service instance when reachable
// (bar.shell.serviceFor(pluginId) — the shell hands panels their sibling
// service). We call the service's apply* mutators directly so a click updates
// state reactively in-process. If the instance is ever missing we fall back to
// the motion-wallpaper IPC route.
BarWidget {
  id: root
  moduleName: "nosignal.motion-wallpaper"

  readonly property string pluginId: "nosignal.motion-wallpaper"
  readonly property var service: (bar && bar.shell) ? bar.shell.serviceFor(pluginId) : null

  // Popup open state (owned here; KeyboardPanel mirrors it and coordinates
  // single-popout behavior with the rest of the bar via `owner`/`bar`).
  property bool opened: false
  property bool popoutSwitchClosing: false

  function open() { opened = true }
  function close() { opened = false }
  function toggle() { opened = !opened }

  // ---- state readout (service-first) -------------------------------------
  // `rendering` rather than "the default clip exists": with per-monitor clips
  // the wallpaper can be running off an override while videoPath is unset, or
  // every monitor can have been blanked individually.
  readonly property bool hasVideo: !!service && service.enabled && service.rendering === true
  readonly property bool isPaused: hasVideo && service.manualPaused === true
  readonly property color warningColor: "#e5c07b"
  readonly property color iconColor: !service ? Color.muted
                                   : hasVideo ? (isPaused ? warningColor : Color.accent)
                                   : Color.muted

  readonly property string glyph: "󰕧"  // nf-md-video

  // The monitor this bar instance lives on — the bar mounts one widget per
  // screen, so this is how the panel knows which screen the user is looking at.
  readonly property string screenName: {
    var w = button.QsWindow ? button.QsWindow.window : null
    return w && w.screen ? String(w.screen.name || "") : ""
  }

  // ---- control helpers (direct service call, IPC fallback) ---------------
  function playPath(p) {
    if (service) service.applyPlay(p)
    else ipc("play", p)
  }
  // Play on every monitor, dropping per-monitor clips.
  function playAll(p) {
    if (service) service.applyPlayAll(p)
    else ipc("playAll", p)
  }
  // Play on one monitor only; an empty path blanks that monitor.
  function playPathOn(screen, p) {
    if (service) service.applySetScreenVideo(screen, p)
    else ipc("playOn", screen, p)
  }
  function offScreen(screen) {
    if (service) service.applySetScreenVideo(screen, "")
    else ipc("playOn", screen, "")
  }
  // ---- scoped playback: "" / "all" = global, else one connector ----------
  function togglePlayPauseScoped(scope) {
    var sc = String(scope || "")
    if (sc === "" || sc === "all") { togglePlayPause(); return }
    if (!service) { ipc("toggleOnScreen", sc); return }
    if (service.offFor(sc)) service.applyPlayScreen(sc)
    else if (service.pausedFor(sc)) service.applyResumeScreen(sc)
    else service.applyPauseScreen(sc)
  }
  function stopScoped(scope) {
    var sc = String(scope || "")
    if (sc === "" || sc === "all") { stopPlayback(); return }
    if (service) service.applyStopScreen(sc)
    else ipc("stopOnScreen", sc)
  }
  function setSpeedScoped(v, scope) {
    var sc = String(scope || "")
    if (sc === "" || sc === "all") { setSpeed(v); return }
    if (service) service.applySetSpeedOn(sc, v)
    else ipc("setSpeedOn", sc, String(v))
  }
  function followGlobalPlayback(scope) {
    var sc = String(scope || "")
    if (sc === "" || sc === "all") return
    if (service) service.applyClearScreenPlayback(sc)
    else ipc("followGlobalPlayback", sc)
  }

  function togglePlayPause() {
    if (!service) { ipc("toggle"); return }
    if (!service.enabled) { service.applyPlay(""); return }
    if (service.manualPaused) service.applyResume()
    else service.applyPause()
  }
  function stopPlayback() {
    if (service) service.applyStop()
    else ipc("stop")
  }
  function setOutput(name) {
    if (service) service.applySetOutput(name)
    else ipc("setOutput", name)
  }
  function setSpeed(v) {
    if (service) service.applySetSpeed(v)
    else ipc("setSpeed", String(v))
  }
  // scope is "" / "all" for the global defaults, or a connector name.
  function setRotation(mode, order, minutes, scope) {
    var sc = String(scope || "")
    if (service) service.applySetRotation(mode, order, minutes, sc)
    else if (sc === "" || sc === "all") ipc("setRotation", String(mode), String(order), String(minutes))
    else ipc("setRotationOn", sc, String(mode), String(order), String(minutes))
  }
  function setPlaylist(paths, scope) {
    var sc = String(scope || "")
    if (service) service.applySetPlaylist(paths, sc)
    else if (sc === "" || sc === "all") ipc("setPlaylist", (paths || []).join(":"))
    else ipc("setPlaylistOn", sc, (paths || []).join(":"))
  }
  function clearRotation(scope) {
    var sc = String(scope || "")
    if (sc === "" || sc === "all") return
    if (service) service.applyClearScreenRotation(sc)
    else ipc("clearRotationOn", sc)
  }
  function nextVideo(scope) {
    var sc = String(scope || "")
    if (service) service.applyNextVideo(sc)
    else if (sc === "" || sc === "all") ipc("next")
    else ipc("nextOn", sc)
  }
  function setPauseOnFullscreen(on) {
    if (service) service.applySetPauseOnFullscreen(on ? "true" : "false")
    else ipc("setPauseOnFullscreen", on ? "true" : "false")
  }
  // Fallback path only (no reachable service instance). Every argument passed
  // is forwarded verbatim, empty strings included — "blank this screen" is
  // playOn(<name>, "").
  function ipc(fn) {
    var cfgPath = (Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy") + "/shell"
    var cmd = ["qs", "-p", cfgPath, "ipc", "call", "motion-wallpaper", fn]
    for (var i = 1; i < arguments.length; i++) {
      var a = arguments[i]
      cmd.push(a === undefined || a === null ? "" : String(a))
    }
    Quickshell.execDetached(cmd)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    tooltipText: "Motion Wallpaper"
    useActiveColor: false
    foreground: root.iconColor
    onPressed: function(b) {
      if (b === Qt.RightButton) root.togglePlayPause()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: kpanel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: kpanel.fittedContentWidth(Style.space(320))
    contentHeight: kpanel.fittedContentHeight(contentLoader.item ? contentLoader.item.implicitHeight : Style.space(200))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Let the screen dropdown own keys while its popup is open.
      blocked: contentLoader.item ? contentLoader.item.keysBlocked : false
      onCloseRequested: root.close()

      Loader {
        id: contentLoader
        anchors.fill: parent
        source: "Panel.qml"   // string URL — no type-name resolution, no collision
        onLoaded: {
          if (!item) return
          item.widget = root
          item.bar = root.bar
        }
      }
    }
  }
}
