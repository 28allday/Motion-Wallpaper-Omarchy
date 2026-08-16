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
  readonly property bool hasVideo: !!service && service.enabled
                                   && service.videoFileExists && service.videoPath !== ""
  readonly property bool isPaused: hasVideo && service.manualPaused === true
  readonly property color warningColor: "#e5c07b"
  readonly property color iconColor: !service ? Color.muted
                                   : hasVideo ? (isPaused ? warningColor : Color.accent)
                                   : Color.muted

  readonly property string glyph: "󰕧"  // nf-md-video

  // ---- control helpers (direct service call, IPC fallback) ---------------
  function playPath(p) {
    if (service) service.applyPlay(p)
    else ipc("play", p)
  }
  function togglePlayPause() {
    if (!service) { ipc("toggle", ""); return }
    if (!service.enabled) { service.applyPlay(""); return }
    if (service.manualPaused) service.applyResume()
    else service.applyPause()
  }
  function stopPlayback() {
    if (service) service.applyStop()
    else ipc("stop", "")
  }
  function setOutput(name) {
    if (service) service.applySetOutput(name)
    else ipc("setOutput", name)
  }
  function setPauseOnFullscreen(on) {
    if (service) service.applySetPauseOnFullscreen(on ? "true" : "false")
    else ipc("setPauseOnFullscreen", on ? "true" : "false")
  }
  function ipc(fn, arg) {
    var cfgPath = (Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy") + "/shell"
    var cmd = ["qs", "-p", cfgPath, "ipc", "call", "motion-wallpaper", fn]
    if (arg !== undefined && arg !== null && String(arg) !== "") cmd.push(String(arg))
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
