import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Dropdown content for the Motion Wallpaper bar widget. Loaded (by string URL)
// into BarWidget.qml's KeyboardPanel, so this is plain content — the open/close
// lifecycle, IPC, and popout coordination all live in BarWidget.qml. All state
// reads and all mutations go through `widget` (the BarWidget), which owns the
// service handle.
Item {
  id: panel

  // Injected by BarWidget.qml's Loader.onLoaded.
  property var widget: null
  property QtObject bar: null

  readonly property var service: widget ? widget.service : null
  // Tell the PanelKeyCatcher to release keys while the screen dropdown is open.
  readonly property bool keysBlocked: screenDropdown.popupOpen

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(fg, 1.5)

  // ---- screen scope ------------------------------------------------------
  // Which screen the video list acts on: "all", or one connector name. This is
  // panel-local — picking a screen here does NOT turn the others off, it just
  // aims the next click. Assigning a clip to one screen leaves the rest alone,
  // which is how different monitors end up with different wallpapers.
  property string scope: "all"

  readonly property bool multiScreen: Quickshell.screens.length > 1

  // A screen that has been unplugged since the panel was last open.
  function scopeValid() {
    if (panel.scope === "all") return true
    var s = Quickshell.screens
    for (var i = 0; i < s.length; i++) if (String(s[i].name) === panel.scope) return true
    return false
  }

  onScopeChanged: if (!scopeValid()) scope = "all"

  // What the scope should be each time the panel opens. Once the screens have
  // been set individually, "All screens" is a destructive default — one click
  // would flatten the lot — so the panel opens aimed at the monitor it is on,
  // and "All screens" becomes a deliberate choice. Until then it opens global,
  // which is what a one-clip-everywhere user wants.
  function resetScope() {
    var own = panel.widget ? String(panel.widget.screenName || "") : ""
    panel.scope = (panel.multiScreen && panel.screensDiffer && own !== "") ? own : "all"
  }

  // ---- derived state -----------------------------------------------------
  readonly property bool hasSvc: !!service
  // The clip assigned to whatever the scope is — the default clip for "all",
  // otherwise that screen's own (falling back to the default it inherits).
  // Clip names come off disk, so they are hostile input, and Qt's Text
  // defaults to Text.AutoText — a name that looks like markup gets parsed as
  // rich text, and an <img src="…"> in it is fetched as a resource. Our own
  // Text elements all set textFormat: Text.PlainText. These two labels are
  // drawn by the shell's own kit (PanelHero, Dropdown), whose Text we do not
  // control, so the angle brackets are stripped before they reach it.
  function plainName(s) {
    return String(s).replace(/[<>]/g, "")
  }

  readonly property string videoPath: {
    if (!service) return ""
    if (scope === "all") return String(service.videoPath || "")
    return String(service.configuredPathForScreen(scope) || "")
  }
  readonly property string videoName: videoPath !== "" ? plainName(videoPath.split("/").pop()) : ""
  readonly property bool videoExists: !!service && videoPath !== "" && service.pathExists(videoPath)
  readonly property string stateText: {
    if (!service) return "Service unavailable"
    if (videoPath === "") return scope === "all" ? "No video selected" : "Screen off"
    if (!videoExists) return "File missing"
    if (!service.enabled) return "Stopped"
    if (service.manualPaused) return "Paused"
    return "Playing"
  }
  // Naming one clip would be a lie while the screens are showing different
  // ones, so scope "all" says so instead.
  readonly property string metaText: {
    if (scope === "all" && screensDiffer) return stateText + "  ·  set per screen"
    return stateText + (videoName !== "" ? "  ·  " + videoName : "")
  }

  readonly property bool isPlaying: !!service && service.enabled && service.rendering === true
                                    && !service.manualPaused
  readonly property bool isPaused: !!service && service.enabled && service.manualPaused

  // ---- screen options ----------------------------------------------------
  // Each screen is labelled with the clip it is set to, so the dropdown
  // doubles as the per-monitor readout.
  readonly property var screenOptions: {
    var o = [{ value: "all", label: "All screens" }]
    var s = Quickshell.screens
    for (var i = 0; i < s.length; i++) {
      var n = String(s[i].name)
      var p = service ? String(service.configuredPathForScreen(n) || "") : ""
      o.push({ value: n, label: n + " · " + (p === "" ? "off" : plainName(p.split("/").pop())) })
    }
    return o
  }

  // Do the screens disagree about what they are playing?
  readonly property bool screensDiffer: {
    if (!service || !multiScreen) return false
    var s = Quickshell.screens
    var first = null
    for (var i = 0; i < s.length; i++) {
      var p = String(service.configuredPathForScreen(String(s[i].name)) || "")
      if (first === null) first = p
      else if (p !== first) return true
    }
    return false
  }

  // ---- video discovery ---------------------------------------------------
  // Hard cap on how many clips the panel will hold and draw. The CLI takes an
  // arbitrary path, so nothing becomes unreachable by capping the browser.
  readonly property int scanLimit: 500
  property bool videosTruncated: false
  property var videos: []   // [{ path, name }]

  function rescan() { scanProc.running = true }

  Component.onCompleted: { rescan(); resetScope() }

  Connections {
    target: panel.widget || null
    function onOpenedChanged() {
      if (!panel.widget || !panel.widget.opened) return
      panel.rescan()
      panel.resetScope()
    }
  }

  // The shell process is long-lived, so neither this buffer nor the list it
  // feeds may grow with the size of the user's video folder. `head` caps the
  // output and closes the pipe, so `find` is killed rather than walking a
  // huge directory to completion. One extra line is requested so that
  // "more than the cap" is detectable without a second scan.
  Process {
    id: scanProc
    command: ["bash", "-c",
      "for d in \"$HOME/Videos/Wallpapers\" \"$HOME/Videos\"; do " +
      "[ -d \"$d\" ] && find \"$d\" -maxdepth 1 -type f " +
      "\\( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.webm' -o -iname '*.mov' -o -iname '*.avi' \\); " +
      "done | sort -u | head -n " + (panel.scanLimit + 1)]
    stdout: StdioCollector {
      onStreamFinished: {
        var seen = ({})
        var list = []
        panel.videosTruncated = false
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          var p = lines[i].trim()
          if (!p || seen[p]) continue
          seen[p] = true
          if (list.length >= panel.scanLimit) { panel.videosTruncated = true; break }
          list.push({ path: p, name: p.split("/").pop() })
        }
        panel.videos = list
      }
    }
  }

  implicitWidth: Style.space(320)
  implicitHeight: col.implicitHeight

  Column {
    id: col
    width: parent.width
    spacing: Style.spacing.panelGap

    // ---------- header ----------
    // The scoped screen rides in the hero's detail pill, so the meta line stays
    // "<state> · <clip>" whether one screen or all of them are in scope.
    PanelHero {
      width: parent.width
      title: "Motion Wallpaper"
      detail: panel.multiScreen && panel.scope !== "all" ? panel.scope : ""
      meta: panel.metaText
      foreground: panel.fg
      fontFamily: panel.fontFamily
      iconComponent: Component {
        Text {
          textFormat: Text.PlainText
          text: "󰕧"
          color: panel.widget ? panel.widget.iconColor : panel.fg
          font.family: panel.fontFamily
          font.pixelSize: Style.font.display
        }
      }
    }

    // ---------- transport buttons ----------
    Row {
      width: parent.width
      spacing: Style.spacing.controlGap

      Button {
        id: playPauseBtn
        foreground: panel.fg
        fontFamily: panel.fontFamily
        iconText: panel.isPlaying ? "󰏤" : "󰐊"
        text: panel.isPlaying ? "Pause" : (panel.isPaused ? "Resume" : "Play")
        bordered: true
        onClicked: if (panel.widget) panel.widget.togglePlayPause()
      }

      Button {
        id: stopBtn
        foreground: panel.fg
        fontFamily: panel.fontFamily
        iconText: "󰓛"
        text: "Stop"
        bordered: true
        opacity: (panel.service && panel.service.enabled) ? 1.0 : 0.5
        onClicked: if (panel.widget) panel.widget.stopPlayback()
      }
    }

    // ---------- screen selector ----------
    // Aims the video list. "All screens" sets one clip everywhere; picking a
    // screen changes only that one, so each monitor can run its own clip.
    Dropdown {
      id: screenDropdown
      visible: panel.multiScreen
      width: parent.width
      label: "SCREEN"
      options: panel.screenOptions
      value: panel.scope
      onChanged: function(v) { panel.scope = String(v) }
    }

    Text {
      textFormat: Text.PlainText
      visible: panel.multiScreen && panel.scope === "all" && panel.screensDiffer
      width: parent.width
      text: "Screens are set individually — pick one above to change just it."
      color: panel.dim
      font.family: panel.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }

    // ---------- auto-pause switch ----------
    Toggle {
      width: parent.width
      label: "Pause on fullscreen"
      description: "Pause while a window is fullscreen on that monitor"
      foreground: panel.fg
      checked: panel.service ? panel.service.pauseOnFullscreen === true : true
      onClicked: if (panel.widget) panel.widget.setPauseOnFullscreen(!checked)
    }

    // ---------- video library ----------
    PanelSeparator { foreground: panel.fg }

    PanelSectionHeader {
      text: !panel.multiScreen ? "VIDEOS"
          : (panel.scope === "all" ? "VIDEOS · ALL SCREENS" : "VIDEOS · " + panel.scope)
      foreground: panel.fg
      fontFamily: panel.fontFamily
    }

    // Empty-dir hint.
    Text {
      textFormat: Text.PlainText
      visible: panel.videos.length === 0
      width: parent.width
      text: "Drop clips in ~/Videos"
      color: panel.dim
      font.family: panel.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }

    // A ListView, not a Column of Repeater rows: it recycles delegates, so the
    // number of live QML objects tracks the height of this list and not the
    // size of the library. The "off" row rides along as the header so it
    // scrolls with the clips instead of being pinned above them.
    ListView {
      id: videoList
      visible: panel.videos.length > 0 || panel.scope !== "all"
      width: parent.width
      height: Math.min(contentHeight, Style.space(240))
      clip: true
      spacing: Style.spacing.xxs
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentHeight > height
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
      model: panel.videos

      // Blank just this screen. Only offered when one screen is scoped —
      // the global equivalent is the Stop button.
      header: Rectangle {
        id: offRow
        visible: panel.scope !== "all"
        readonly property bool current: panel.videoPath === ""
        width: videoList.width
        height: visible ? Style.spacing.controlHeight + videoList.spacing : 0
        color: "transparent"

        Rectangle {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          height: Style.spacing.controlHeight
          radius: Style.cornerRadius
          color: offRow.current
            ? Style.selectedFillFor(panel.fg, Color.accent)
            : (offMouse.containsMouse ? Style.hoverFillFor(panel.fg, Color.accent) : "transparent")

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.spacing.controlPaddingX
            anchors.rightMargin: Style.spacing.controlPaddingX
            text: "Off — static wallpaper"
            color: offRow.current ? Style.selectedStateColor(panel.fg, Color.accent) : panel.dim
            font.family: panel.fontFamily
            font.pixelSize: Style.font.body
            font.bold: offRow.current
            elide: Text.ElideRight
          }

          MouseArea {
            id: offMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: if (panel.widget) panel.widget.offScreen(panel.scope)
          }
        }
      }

      delegate: Rectangle {
        id: vrow
        required property var modelData
        required property int index
        readonly property bool current: modelData.path === panel.videoPath
        width: videoList.width
        height: Style.spacing.controlHeight
        radius: Style.cornerRadius
        color: current
          ? Style.selectedFillFor(panel.fg, Color.accent)
          : (rowMouse.containsMouse ? Style.hoverFillFor(panel.fg, Color.accent) : "transparent")

        Text {
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.right: playMark.left
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.spacing.controlPaddingX
          anchors.rightMargin: Style.spacing.sm
          text: vrow.modelData.name
          color: vrow.current ? Style.selectedStateColor(panel.fg, Color.accent) : panel.fg
          font.family: panel.fontFamily
          font.pixelSize: Style.font.body
          font.bold: vrow.current
          elide: Text.ElideMiddle
        }

        Text {
          textFormat: Text.PlainText
          id: playMark
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.rightMargin: Style.spacing.controlPaddingX
          visible: vrow.current
          text: panel.isPaused ? "󰏤" : "󰐊"
          color: Style.selectedStateColor(panel.fg, Color.accent)
          font.family: panel.fontFamily
          font.pixelSize: Style.font.body
        }

        MouseArea {
          id: rowMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            if (!panel.widget) return
            if (panel.scope === "all") panel.widget.playAll(vrow.modelData.path)
            else panel.widget.playPathOn(panel.scope, vrow.modelData.path)
          }
        }
      }
    }

    // Says so when the library is larger than the scan cap, rather than
    // silently pretending the extra clips are not there.
    Text {
      textFormat: Text.PlainText
      visible: panel.videosTruncated
      width: parent.width
      text: "Showing the first " + panel.scanLimit + " clips. Play others with: motion-wallpaper play <path>"
      color: panel.dim
      font.family: panel.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }
  }
}
