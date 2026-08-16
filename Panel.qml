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

  // ---- derived state -----------------------------------------------------
  readonly property bool hasSvc: !!service
  readonly property string videoPath: service ? String(service.videoPath || "") : ""
  readonly property string videoName: videoPath !== "" ? videoPath.split("/").pop() : ""
  readonly property string stateText: {
    if (!service) return "Service unavailable"
    if (videoPath === "") return "No video selected"
    if (!service.videoFileExists) return "File missing"
    if (!service.enabled) return "Stopped"
    if (service.manualPaused) return "Paused"
    return "Playing"
  }
  readonly property bool isPlaying: !!service && service.enabled && service.videoFileExists
                                    && !service.manualPaused && videoPath !== ""
  readonly property bool isPaused: !!service && service.enabled && service.manualPaused

  // ---- screen options ----------------------------------------------------
  readonly property var screenOptions: {
    var o = [{ value: "all", label: "All screens" }]
    var s = Quickshell.screens
    for (var i = 0; i < s.length; i++) o.push({ value: String(s[i].name), label: String(s[i].name) })
    return o
  }

  // ---- video discovery ---------------------------------------------------
  property var videos: []   // [{ path, name }]

  function rescan() { scanProc.running = true }

  Component.onCompleted: rescan()

  Connections {
    target: panel.widget || null
    function onOpenedChanged() { if (panel.widget && panel.widget.opened) panel.rescan() }
  }

  Process {
    id: scanProc
    command: ["bash", "-c",
      "for d in \"$HOME/Videos/Wallpapers\" \"$HOME/Videos\"; do " +
      "[ -d \"$d\" ] && find \"$d\" -maxdepth 1 -type f " +
      "\\( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.webm' -o -iname '*.mov' -o -iname '*.avi' \\); " +
      "done | sort -u"]
    stdout: StdioCollector {
      onStreamFinished: {
        var seen = ({})
        var list = []
        var lines = String(text || "").split("\n")
        for (var i = 0; i < lines.length; i++) {
          var p = lines[i].trim()
          if (!p || seen[p]) continue
          seen[p] = true
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
    Item {
      width: parent.width
      implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

      Text {
        id: heroIcon
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: "󰕧"
        color: panel.widget ? panel.widget.iconColor : panel.fg
        font.family: panel.fontFamily
        font.pixelSize: Style.font.display
      }

      Column {
        id: heroLabels
        anchors.left: heroIcon.right
        anchors.leftMargin: Style.spacing.rowPaddingX
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.xxs

        Text {
          text: "Motion Wallpaper"
          color: panel.fg
          font.family: panel.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
          elide: Text.ElideRight
          width: parent.width
        }
        Text {
          text: panel.stateText.toUpperCase()
              + (panel.videoName !== "" ? "  ·  " + panel.videoName : "")
          color: panel.dim
          font.family: panel.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 0.8
          elide: Text.ElideRight
          width: parent.width
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
    Dropdown {
      id: screenDropdown
      width: parent.width
      label: "SCREEN"
      options: panel.screenOptions
      value: panel.service ? String(panel.service.output) : "all"
      onChanged: function(v) { if (panel.widget) panel.widget.setOutput(v) }
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
      text: "VIDEOS"
      foreground: panel.fg
      fontFamily: panel.fontFamily
    }

    // Empty-dir hint.
    Text {
      visible: panel.videos.length === 0
      width: parent.width
      text: "Drop clips in ~/Videos/Wallpapers"
      color: panel.dim
      font.family: panel.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }

    Flickable {
      id: videoFlick
      visible: panel.videos.length > 0
      width: parent.width
      height: Math.min(videoList.implicitHeight, Style.space(240))
      contentWidth: width
      contentHeight: videoList.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentHeight > height
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: videoList
        width: parent.width
        spacing: Style.spacing.xxs

        Repeater {
          model: panel.videos

          Rectangle {
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
              onClicked: if (panel.widget) panel.widget.playPath(vrow.modelData.path)
            }
          }
        }
      }
    }
  }
}
