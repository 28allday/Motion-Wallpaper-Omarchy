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
  // Read-through to the service's scan rather than a second one.
  readonly property int scanLimit: panel.service ? panel.service.scanLimit : 500
  readonly property bool videosTruncated: panel.service ? panel.service.videosTruncated === true : false
  readonly property var videos: panel.service ? (panel.service.availableVideos || []) : []

  function rescan() { if (panel.service) panel.service.rescanLibrary() }

  Component.onCompleted: { rescan(); resetScope() }

  Connections {
    target: panel.widget || null
    function onOpenedChanged() {
      if (!panel.widget || !panel.widget.opened) return
      panel.rescan()
      panel.resetScope()
    }
  }

  // ---- speed + rotation reads -------------------------------------------
  // All of these read THROUGH the service, so the panel shows live truth even
  // when the CLI changed something while the dropdown was open.
  readonly property real minSpeed: panel.service ? Number(panel.service.minSpeed) : 0.25
  readonly property real maxSpeed: panel.service ? Number(panel.service.maxSpeed) : 2.0

  // Reference marks at the round speeds.
  readonly property var speedMarks: [0.25, 0.5, 0.75, 1.0, 1.5, 2.0]

  // < 0 unless a drag is in flight, so the readout follows the knob.
  property real pendingSpeed: -1

  readonly property real serviceSpeed: {
    var v = panel.service ? Number(panel.service.playbackSpeed) : 1
    return (isFinite(v) && v > 0) ? v : 1
  }

  readonly property real speedValue: panel.pendingSpeed >= 0 ? panel.pendingSpeed
                                                             : panel.serviceSpeed

  function roundSpeed(v) { return Math.round(Number(v) * 100) / 100 }

  // Trailing zeros dropped: 1x, 0.5x, 0.66x — never 1.00x.
  readonly property string speedLabel: {
    var n = panel.roundSpeed(panel.speedValue)
    var t = n.toFixed(2).replace(/0+$/, "").replace(/\.$/, "")
    return t + "x"
  }

  // Rotation reads follow the SCREEN selector: "all" is the global default,
  // a screen is its effective settings (own profile, else inherited). Reading
  // the service's screenPlans is what makes these live.
  readonly property var scopePlan: {
    if (!panel.service || panel.scope === "all") return null
    var plans = panel.service.screenPlans || ({})
    return plans[panel.scope] || null
  }

  readonly property string rotationMode:
    panel.scope === "all" ? (panel.service ? String(panel.service.rotationMode || "off") : "off")
                          : (panel.scopePlan ? String(panel.scopePlan.mode) : "off")

  readonly property string rotationOrder:
    panel.scope === "all" ? (panel.service ? String(panel.service.rotationOrder || "shuffle") : "shuffle")
                          : (panel.scopePlan ? String(panel.scopePlan.order) : "shuffle")

  readonly property int rotationInterval:
    panel.scope === "all" ? (panel.service ? Number(panel.service.rotationInterval || 10) : 10)
                          : (panel.scopePlan ? Number(panel.scopePlan.interval) : 10)

  // True when this screen has been given settings of its own.
  readonly property bool scopeHasOwnProfile: panel.scopePlan ? panel.scopePlan.own === true : false

  readonly property var intervalOptions: [
    { value: "1",  label: "1 minute"   },
    { value: "2",  label: "2 minutes"  },
    { value: "5",  label: "5 minutes"  },
    { value: "10", label: "10 minutes" },
    { value: "15", label: "15 minutes" },
    { value: "30", label: "30 minutes" },
    { value: "60", label: "1 hour"     }
  ]

  // Full path as the value, bare filename as the label.
  readonly property var playlistOptions: {
    var out = []
    var v = panel.videos || []
    for (var i = 0; i < v.length; i++)
      out.push({ value: String(v[i].path), label: String(v[i].name) })
    return out
  }

  readonly property var playlistValues: {
    var out = []
    if (!panel.service) return out
    var pl = panel.scope === "all" ? (panel.service.playlist || [])
                                   : (panel.scopePlan ? panel.scopePlan.playlist : [])
    for (var i = 0; i < pl.length; i++) out.push(String(pl[i]))
    return out
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

    // ---------- playback speed ----------
    PanelSeparator { foreground: panel.fg }

    PanelSectionHeader {
      text: "SPEED"
      foreground: panel.fg
      fontFamily: panel.fontFamily
    }

    // Free over the whole range at 2-decimal precision; the ticks are just
    // visual anchors at the round speeds.
    Row {
      width: parent.width
      spacing: Style.spacing.controlGap

      PanelSlider {
        id: speedSlider
        bar: panel.bar
        width: parent.width - speedReadout.width - Style.spacing.controlGap
        anchors.verticalCenter: parent.verticalCenter
        minimum: panel.minSpeed
        maximum: panel.maxSpeed
        // PanelSlider ignores `step` and only quantises when `integer` is
        // set, so the 2-decimal rounding is applied here.
        integer: false
        tickCount: panel.speedMarks.length
        value: panel.speedValue
        onMoved: function(v) {
          panel.pendingSpeed = panel.roundSpeed(v)
          // Live preview without writing state.json on every pixel; the
          // release below is what persists.
          if (panel.service) panel.service.playbackSpeed = panel.pendingSpeed
        }
        onReleased: function(v) {
          var final = panel.roundSpeed(v)
          panel.pendingSpeed = -1
          if (panel.widget) panel.widget.setSpeed(final)
        }
      }

      Text {
        id: speedReadout
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        // Sized to the widest label so the slack goes back to the slider.
        width: speedMetrics.width
        horizontalAlignment: Text.AlignRight
        text: panel.speedLabel
        color: panel.fg
        font.family: panel.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      TextMetrics {
        id: speedMetrics
        font.family: panel.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
        text: "0.25x"
      }
    }

    // ---------- rotation ----------
    PanelSeparator { foreground: panel.fg }

    PanelSectionHeader {
      text: !panel.multiScreen ? "ROTATION"
          : (panel.scope === "all" ? "ROTATION · ALL SCREENS" : "ROTATION · " + panel.scope)
      foreground: panel.fg
      fontFamily: panel.fontFamily
    }

    // The same controls mean two different things depending on scope.
    Text {
      textFormat: Text.PlainText
      visible: panel.multiScreen
      width: parent.width
      text: panel.scope === "all"
          ? "Shared default. Screens with their own settings ignore this."
          : (panel.scopeHasOwnProfile ? panel.scope + " has its own settings."
                                      : panel.scope + " follows the shared default — changing anything here gives it its own.")
      color: panel.dim
      font.family: panel.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }

    Dropdown {
      id: rotModeDropdown
      width: parent.width
      label: "MODE"
      options: [
        { value: "off",      label: "Off — one video" },
        { value: "all",      label: "Rotate all videos" },
        { value: "selected", label: "Rotate chosen videos" }
      ]
      value: panel.rotationMode
      onChanged: function(v) {
        if (panel.widget) panel.widget.setRotation(String(v), panel.rotationOrder, panel.rotationInterval, panel.scope)
      }
    }

    // Hidden until rotation is on rather than offering settings that do nothing.
    ButtonGroup {
      width: parent.width
      visible: panel.rotationMode !== "off"
      foreground: panel.fg
      fontFamily: panel.fontFamily
      options: [
        { value: "shuffle",    label: "Shuffle" },
        { value: "sequential", label: "In order" }
      ]
      value: panel.rotationOrder
      onChanged: function(v) {
        if (panel.widget) panel.widget.setRotation(panel.rotationMode, String(v), panel.rotationInterval, panel.scope)
      }
    }

    Dropdown {
      id: rotIntervalDropdown
      width: parent.width
      visible: panel.rotationMode !== "off"
      label: "CHANGE EVERY"
      options: panel.intervalOptions
      value: String(panel.rotationInterval)
      onChanged: function(v) {
        if (panel.widget) panel.widget.setRotation(panel.rotationMode, panel.rotationOrder, Number(v), panel.scope)
      }
    }

    MultiSelect {
      id: playlistSelect
      width: parent.width
      visible: panel.rotationMode === "selected"
      label: "VIDEOS IN ROTATION"
      noSelectionText: "None chosen — nothing will rotate"
      emptyText: "Drop clips in ~/Videos"
      foreground: panel.fg
      fontFamily: panel.fontFamily
      options: panel.playlistOptions
      values: panel.playlistValues
      onChanged: function(vals) { if (panel.widget) panel.widget.setPlaylist(vals, panel.scope) }
    }

    Row {
      width: parent.width
      spacing: Style.spacing.controlGap

      Button {
        visible: panel.rotationMode !== "off"
        foreground: panel.fg
        fontFamily: panel.fontFamily
        iconText: "󰒭"
        text: "Next video"
        bordered: true
        onClicked: if (panel.widget) panel.widget.nextVideo(panel.scope)
      }

      Button {
        visible: panel.scopeHasOwnProfile
        foreground: panel.fg
        fontFamily: panel.fontFamily
        iconText: "󰑐"
        text: "Follow default"
        bordered: true
        onClicked: if (panel.widget) panel.widget.clearRotation(panel.scope)
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: panel.rotationMode === "selected" && panel.playlistValues.length === 0
      width: parent.width
      text: "Pick at least one video above, or rotation stays on the current clip."
      color: panel.dim
      font.family: panel.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
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
