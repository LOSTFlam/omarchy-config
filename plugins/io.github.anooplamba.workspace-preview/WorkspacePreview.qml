pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Services.Pipewire
import qs.Commons
import qs.Ui

BarWidget {
  id: root

  moduleName: "io.github.anooplamba.workspace-preview"

  property int refreshSerial: 0
  property Item pendingAnchor: null
  property int pendingWorkspaceId: -1
  property Item hoveredAnchor: null
  property Item activeAnchor: null
  property int activeWorkspaceId: -1
  // Capture state keeps the asynchronous screencopy lifecycle explicit.
  readonly property int captureIdle: 0
  readonly property int capturePending: 1
  readonly property int captureReadyState: 2
  readonly property int captureFallback: 3
  property int captureState: captureIdle
  readonly property bool captureReady: captureState === captureReadyState || captureState === captureFallback
  readonly property bool captureTimedOut: captureState === captureFallback
  property bool popupWasShown: false
  property int transitionDirection: 0
  property bool temporaryScreenShareOverride: false
  property bool recorderDetected: false
  property int privacySerial: 0
  property string wallpaperPath: ""

  readonly property var activeWorkspace: root.workspaceById(root.activeWorkspaceId)
  readonly property var activeWindows: root.windowsForWorkspace(root.activeWorkspace)
  readonly property var activeMonitor: root.monitorFor(root.activeWorkspace, root.activeAnchor)
  readonly property real workspaceWidth: root.monitorLogicalWidth(root.activeMonitor)
  readonly property real workspaceHeight: root.monitorLogicalHeight(root.activeMonitor)
  readonly property real workspaceAspect: root.workspaceHeight > 0 ? root.workspaceWidth / root.workspaceHeight : 16 / 9
  readonly property real previewWidth: Style.space(340)
  readonly property real previewHeight: root.previewWidth / root.workspaceAspect
  // Keep the snapshot close to its border; the shell's normal popup padding
  // is deliberately roomier for menus and settings panels.
  readonly property real previewPadding: Style.space(6)
  readonly property real popupInset: root.previewPadding * 2 + Style.space(2)
  readonly property bool screenSharingDetected: {
    root.privacySerial
    if (root.recorderDetected) return true

    var nodes = Pipewire.nodes ? Pipewire.nodes.values : []
    for (var i = 0; i < nodes.length; i++) {
      var node = nodes[i]
      if (!node || !node.properties) continue
      var props = node.properties
      var mediaClass = String(props["media.class"] || "").toLowerCase()
      if (mediaClass.indexOf("video") === -1) continue

      var marker = [
        props["media.role"],
        props["media.name"],
        props["node.name"],
        props["node.description"],
        props["application.name"],
        props["pipewire.access.portal.app_id"]
      ].join(" ").toLowerCase()

      // A portal name alone is not enough: portals also back non-sharing
      // operations. Limit detection to a video node with a screen/desktop
      // capture marker.
      if (/(screen[ _.-]?(cast|shar|captur)|desktop[ _.-]?(cast|shar|captur)|monitor[ _.-]?captur|xdg[ _.-]?desktop[ _.-]?portal.*(screen|cast|captur))/.test(marker))
        return true
    }
    return false
  }
  readonly property bool privacyBlocked: root.screenSharingDetected && !root.temporaryScreenShareOverride

  function workspaceById(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (Number(values[i].id) === Number(id)) return values[i]
    }
    return null
  }

  function workspaceIds() {
    var ids = [1, 2, 3, 4, 5]
    var values = Hyprland.workspaces.values

    for (var i = 0; i < values.length; i++) {
      var id = Number(values[i].id)
      if (id > 0 && id <= 10 && ids.indexOf(id) === -1) ids.push(id)
    }

    ids.sort(function(left, right) { return left - right })
    return ids
  }

  function windowsForWorkspace(workspace) {
    return workspace && workspace.toplevels ? workspace.toplevels.values : []
  }

  function focusWorkspace(id) {
    if (!root.bar) return
    root.bar.run("hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ workspace = \"" + id + "\" })"))
  }

  function monitorFor(workspace, anchor) {
    if (workspace && workspace.monitor) return workspace.monitor
    if (anchor && anchor.QsWindow && anchor.QsWindow.window && anchor.QsWindow.window.screen) {
      var screens = Hyprland.monitors ? Hyprland.monitors.values : []
      var screenName = String(anchor.QsWindow.window.screen.name || "")
      for (var i = 0; i < screens.length; i++) {
        if (String(screens[i].name || "") === screenName) return screens[i]
      }
    }
    return Hyprland.focusedMonitor
  }

  function reservedFor(monitor) {
    if (monitor && monitor.lastIpcObject && monitor.lastIpcObject.reserved)
      return monitor.lastIpcObject.reserved
    return [0, 0, 0, 0]
  }

  function monitorScaleFor(monitor) {
    var scale = monitor ? Number(monitor.scale) : 1
    return Number.isFinite(scale) && scale > 0 ? scale : 1
  }

  function reservedValue(reserved, index) {
    var value = Number(reserved[index])
    return Number.isFinite(value) ? value : 0
  }

  function monitorLogicalWidth(monitor) {
    if (!monitor) return 1920
    var reserved = root.reservedFor(monitor)
    return Math.max(1, Number(monitor.width) / root.monitorScaleFor(monitor)
      - root.reservedValue(reserved, 0) - root.reservedValue(reserved, 2))
  }

  function monitorLogicalHeight(monitor) {
    if (!monitor) return 1080
    var reserved = root.reservedFor(monitor)
    return Math.max(1, Number(monitor.height) / root.monitorScaleFor(monitor)
      - root.reservedValue(reserved, 1) - root.reservedValue(reserved, 3))
  }

  function windowGeometry(toplevel, monitor) {
    var ipc = toplevel && toplevel.lastIpcObject ? toplevel.lastIpcObject : null
    var reserved = root.reservedFor(monitor)
    var width = root.monitorLogicalWidth(monitor)
    var height = root.monitorLogicalHeight(monitor)

    if (!ipc || !ipc.at || !ipc.size) {
      return { x: width * 0.1, y: height * 0.1, width: width * 0.8, height: height * 0.8 }
    }

    return {
      x: Number(ipc.at[0]) - (monitor ? Number(monitor.x) : 0) - Number(reserved[0]),
      y: Number(ipc.at[1]) - (monitor ? Number(monitor.y) : 0) - Number(reserved[1]),
      width: Math.max(1, Number(ipc.size[0])),
      height: Math.max(1, Number(ipc.size[1]))
    }
  }

  function appIdFor(toplevel) {
    if (!toplevel) return ""
    if (toplevel.wayland && toplevel.wayland.appId)
      return String(toplevel.wayland.appId)
    var ipc = toplevel.lastIpcObject
    return ipc ? String(ipc.class || ipc.initialClass || "") : ""
  }

  function desktopEntryFor(toplevel) {
    var appId = root.appIdFor(toplevel)
    if (!appId) return null

    var candidates = [appId, appId.replace(/\.desktop$/i, "")]
    for (var i = 0; i < candidates.length; i++) {
      var entry = DesktopEntries.byId(candidates[i])
      if (entry) return entry
    }
    return null
  }

  function iconSourceFor(toplevel) {
    var entry = root.desktopEntryFor(toplevel)
    var icon = entry ? String(entry.icon || "") : root.appIdFor(toplevel)
    var library = root.bar && root.bar.shell ? root.bar.shell.appLibrary : null
    if (library && library.iconSource) return library.iconSource(icon)
    return Quickshell.iconPath(icon || "application-x-executable", true)
  }

  function windowTitleFor(toplevel) {
    return toplevel && toplevel.title ? String(toplevel.title) : root.appIdFor(toplevel)
  }

  function requestPreview(anchor, workspaceId) {
    root.bar.hideTooltip(anchor)
    closeTimer.stop()
    root.hoveredAnchor = anchor
    root.pendingAnchor = anchor
    root.pendingWorkspaceId = workspaceId
    openTimer.restart()
  }

  function leavePreview(anchor) {
    if (root.hoveredAnchor === anchor)
      root.hoveredAnchor = null

    if (root.pendingAnchor === anchor) {
      root.pendingAnchor = null
      root.pendingWorkspaceId = -1
      openTimer.stop()
    }

    if (!root.hoveredAnchor && root.activeAnchor && !root.popupContainsMouse)
      closeTimer.restart()
  }

  function activatePendingPreview() {
    if (!root.pendingAnchor) {
      root.closePreview()
      return
    }

    var previousAnchor = root.activeAnchor
    if (previousAnchor && root.pendingAnchor !== previousAnchor) {
      var previousCenter = previousAnchor.x + previousAnchor.width / 2
      var nextCenter = root.pendingAnchor.x + root.pendingAnchor.width / 2
      root.transitionDirection = nextCenter >= previousCenter ? 1 : -1
    } else {
      root.transitionDirection = 0
    }

    root.activeAnchor = root.pendingAnchor
    root.activeWorkspaceId = root.pendingWorkspaceId
    root.pendingAnchor = null
    root.pendingWorkspaceId = -1
    root.captureState = root.capturePending
    wallpaperProbe.running = true
    captureTimeout.restart()

    if (root.privacyBlocked) return
    Qt.callLater(function() { root.prepareCapture() })
  }

  function prepareCapture() {
    if (!root.activeAnchor) return
    if (root.privacyBlocked) return

    if (root.activeWindows.length === 0) {
      captureTimeout.stop()
      root.captureState = root.captureReadyState
      return
    }

    root.captureState = root.capturePending
    captureTimeout.restart()

    if (previewLoader.item && previewLoader.item.recapture)
      previewLoader.item.recapture()
    root.checkCaptureReadiness()
  }

  function checkCaptureReadiness() {
    if (root.privacyBlocked || !root.activeAnchor) return
    if (root.activeWindows.length === 0) {
      captureTimeout.stop()
      root.captureState = root.captureReadyState
      return
    }
    if (!previewLoader.item || !previewLoader.item.capturesReady) return
    if (previewLoader.item.capturesReady()) {
      captureTimeout.stop()
      root.captureState = root.captureReadyState
    }
  }

  function closePreview() {
    openTimer.stop()
    closeTimer.stop()
    captureTimeout.stop()
    root.pendingAnchor = null
    root.pendingWorkspaceId = -1
    root.hoveredAnchor = null
    root.activeAnchor = null
    root.activeWorkspaceId = -1
    root.captureState = root.captureIdle
    root.popupWasShown = false
  }

  function popupContainsMouseValue() {
    return previewLoader.item && previewLoader.item.containsMouse === true
  }

  readonly property bool popupContainsMouse: root.popupContainsMouseValue()

  function handlePopupHover(hovered) {
    if (hovered) closeTimer.stop()
    else if (!root.hoveredAnchor) closeTimer.restart()
  }

  function sharingProbeTick() {
    root.privacySerial++
    if (!root.screenSharingDetected) root.temporaryScreenShareOverride = false
  }

  onCaptureReadyChanged: {
    if (root.captureReady) root.popupWasShown = true
  }

  onScreenSharingDetectedChanged: {
    if (!root.screenSharingDetected) root.temporaryScreenShareOverride = false
    if (root.privacyBlocked) {
      captureTimeout.stop()
      root.captureState = root.captureIdle
    } else if (root.activeAnchor) {
      root.prepareCapture()
    }
  }

  onPrivacyBlockedChanged: {
    if (root.privacyBlocked) {
      captureTimeout.stop()
      root.captureState = root.captureIdle
    } else if (root.activeAnchor) {
      root.prepareCapture()
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      // Keep empty workspaces previewable: they intentionally render the
      // current wallpaper without window tiles.
      root.refreshSerial++
    }
  }

  Connections {
    target: Hyprland.workspaces
    function onValuesChanged() {
      // An empty workspace may have no Hyprland object yet, so do not treat a
      // missing/empty model as a reason to close its wallpaper preview.
      root.refreshSerial++
    }
  }

  Timer {
    id: openTimer
    interval: 100
    onTriggered: root.activatePendingPreview()
  }

  Timer {
    id: closeTimer
    interval: 200
    onTriggered: root.closePreview()
  }

  Timer {
    id: captureTimeout
    interval: 800
    onTriggered: {
      if (!root.activeAnchor || root.privacyBlocked) return
      root.captureState = root.captureFallback
    }
  }

  Timer {
    interval: 1000
    running: true
    repeat: true
    onTriggered: root.sharingProbeTick()
  }

  Process {
    id: recorderProbe
    // `pgrep -x` only checks a short process name on some systems. Match the
    // executable in the full command line so long recorder names are reliable.
    command: ["pgrep", "-f", "(^|/)(gpu-screen-recorder(-gtk)?|wf-recorder|wl-screenrec|kooha|obs)([[:space:]]|$)"]
    running: true
    onExited: function(exitCode) { root.recorderDetected = exitCode === 0 }
  }

  Timer {
    interval: 1000
    running: true
    repeat: true
    onTriggered: if (!recorderProbe.running) recorderProbe.running = true
  }

  Process {
    id: wallpaperProbe
    command: ["readlink", "-f", Quickshell.env("HOME") + "/.local/state/omarchy/current/background"]
    stdout: StdioCollector {
      onStreamFinished: root.wallpaperPath = String(text).trim()
    }
  }

  Loader {
    id: previewLoader
    active: root.activeAnchor !== null
    onLoaded: {
      if (root.activeAnchor && !root.privacyBlocked) root.prepareCapture()
    }

    sourceComponent: PopupCard {
      id: popup

      property var captureModel: root.activeWindows

      anchorItem: root.activeAnchor
      bar: root.bar
      owner: root
      triggerMode: "hover"
      padding: root.previewPadding
      contentWidth: root.privacyBlocked ? Style.space(320) : root.previewWidth + root.popupInset
      contentHeight: root.privacyBlocked ? Style.space(150) : root.previewHeight + popup.verticalContentInset
      open: root.activeAnchor !== null
        && (root.privacyBlocked || root.captureReady || root.popupWasShown)

      function capturesReady() {
        if (root.privacyBlocked) return false
        if (captureRepeater.count !== root.activeWindows.length) return false
        for (var i = 0; i < captureRepeater.count; i++) {
          var delegate = captureRepeater.itemAt(i)
          if (!delegate) return false
          if (delegate.captureSourceAvailable && !delegate.captureView.hasContent) return false
        }
        return true
      }

      function recapture() {
        for (var i = 0; i < captureRepeater.count; i++) {
          var delegate = captureRepeater.itemAt(i)
          if (delegate && delegate.captureView && delegate.captureView.hasContent
              && delegate.captureView.captureFrame)
            delegate.captureView.captureFrame()
        }
      }

      // PopupCard registers open popups with the bar, which normally draws an
      // accent-coloured "open panel" underline. A workspace peek is a passive
      // hover preview, not a panel, so release that registration after its
      // normal popup coordination has completed.
      onOpenChanged: {
        if (open) Qt.callLater(function() {
          if (root.bar && root.bar.activePopout === popup.coordinatorKey)
            root.bar.releasePopout(popup.coordinatorKey)
        })
      }

      onContainsMouseChanged: root.handlePopupHover(containsMouse)

      Item {
        id: previewSurface
        anchors.fill: parent
        visible: !root.privacyBlocked
        opacity: root.captureReady ? 1 : 0
        clip: true

        Behavior on opacity {
          NumberAnimation { duration: 100; easing.type: Easing.OutCubic }
        }

        Item {
          id: previewMotion
          width: parent.width
          height: parent.height
          x: 0
          opacity: 1

          Behavior on x {
            NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
          }

          Behavior on opacity {
            NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
          }

          function animateIn() {
            var distance = Style.space(26)
            previewMotion.x = root.transitionDirection * distance
            previewMotion.opacity = 0
            Qt.callLater(function() {
              if (!popup.open || root.privacyBlocked) return
              previewMotion.x = 0
              previewMotion.opacity = 1
            })
          }

        Rectangle {
          anchors.fill: parent
          color: Color.popups.background
        }

        Image {
          anchors.fill: parent
          source: root.wallpaperPath ? Util.fileUrl(root.wallpaperPath) : ""
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          smooth: true
        }

        Repeater {
          id: captureRepeater
          model: root.activeWindows

          delegate: WorkspaceWindowTile {
            required property var modelData

            toplevel: modelData
            geometry: root.windowGeometry(toplevel, root.activeMonitor)
            workspaceWidth: root.workspaceWidth
            workspaceHeight: root.workspaceHeight
            iconSource: root.iconSourceFor(toplevel)
            windowTitle: root.windowTitleFor(toplevel)
            captureTimedOut: root.captureTimedOut
            onCaptureContentChanged: root.checkCaptureReadiness()
          }
        }

        MouseArea {
          anchors.fill: parent
          z: 100
          hoverEnabled: true
          acceptedButtons: Qt.LeftButton
          cursorShape: Qt.PointingHandCursor
          onClicked: root.focusWorkspace(root.activeWorkspaceId)
        }

        Connections {
          target: popup
          function onOpenChanged() {
            if (popup.open && !root.privacyBlocked) previewMotion.animateIn()
          }
        }

        Connections {
          target: root
          function onCaptureReadyChanged() {
            if (root.captureReady && !root.privacyBlocked && popup.open)
              previewMotion.animateIn()
          }
        }
      }
      }

      Column {
        anchors.centerIn: parent
        width: parent.width - Style.space(24)
        spacing: Style.space(12)
        visible: root.privacyBlocked

        Text {
          width: parent.width
          text: "Workspace previews are hidden while screen sharing"
          textFormat: Text.PlainText
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          text: "Allow them temporarily for this screen-sharing session?"
          textFormat: Text.PlainText
          color: Color.popups.text
          opacity: 0.7
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
        }

        Rectangle {
          anchors.horizontalCenter: parent.horizontalCenter
          width: Math.min(parent.width, Style.space(190))
          height: Style.space(32)
          radius: Style.cornerRadius
          color: Style.selectedFillFor(Color.popups.text, Color.accent)

          Text {
            anchors.centerIn: parent
            text: "Show temporarily"
            textFormat: Text.PlainText
            color: Style.hoverStateColor(Color.popups.text, Color.accent)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            onClicked: {
              root.temporaryScreenShareOverride = true
              root.prepareCapture()
            }
          }
        }
      }
    }
  }

  implicitWidth: grid.implicitWidth + trailingGap
  implicitHeight: grid.implicitHeight

  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)

  GridLayout {
    id: grid
    anchors.fill: parent
    anchors.rightMargin: root.trailingGap
    columns: root.vertical ? 1 : root.workspaceIds().length
    columnSpacing: root.vertical ? 0 : Style.space(1)
    rowSpacing: root.vertical ? Style.space(2) : 0

    Repeater {
      model: root.workspaceIds()

      WidgetButton {
        id: workspaceButton
        required property int modelData

        readonly property var workspace: { root.refreshSerial; return root.workspaceById(modelData) }
        readonly property bool occupied: workspace !== null && workspace.toplevels.values.length > 0
        readonly property bool focused: Hyprland.focusedWorkspace !== null && Hyprland.focusedWorkspace.id === modelData

        bar: root.bar
        text: focused ? "\uDB85\uDCFB" : (modelData === 10 ? "0" : String(modelData))
        opacity: occupied || focused ? 1 : 0.5
        horizontalMargin: 6
        verticalPadding: 6
        fixedWidth: root.vertical ? root.barSize : Style.space(20)
        fixedHeight: root.barSize
        onPressed: function() { root.focusWorkspace(modelData) }

        Connections {
          target: workspaceButton
          function onTooltipHoveredChanged() {
            if (workspaceButton.tooltipHovered)
              root.requestPreview(workspaceButton, workspaceButton.modelData)
            else
              root.leavePreview(workspaceButton)
          }
        }
      }
    }
  }
}
