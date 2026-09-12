import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

BarWidget {
  id: root
  moduleName: "prusso.bisaiko"

  readonly property int defaultOpenDelayMs: 50
  readonly property int defaultPollMs: 80
  readonly property string defaultPopupPosition: "top-center"
  readonly property string defaultBarSection: "center"
  readonly property var positionOptions: [
    { label: "Upper left", value: "top-left" },
    { label: "Top middle", value: "top-center" },
    { label: "Upper right", value: "top-right" },
    { label: "Left middle", value: "middle-left" },
    { label: "Center", value: "center" },
    { label: "Right middle", value: "middle-right" },
    { label: "Lower left", value: "bottom-left" },
    { label: "Bottom middle", value: "bottom-center" },
    { label: "Lower right", value: "bottom-right" }
  ]

  property bool settingsOpen: false
  property bool hintShown: false
  property int clickState: 0 // 0 closed, 1 open, 2 pinned, 3 unpinned
  property bool hoverPinned: false
  property string actualBarSection: ""
  readonly property string controlsHint: persisted.hoverEnabled
    ? (root.hoverPinned
      ? "Click again to close · Right-click for settings"
      : "Click to pin · Right-click for settings")
    : (root.clickState === 0
      ? "Right-click for settings"
      : root.clickState === 1
        ? "Click again to pin · Right-click for settings"
        : root.clickState === 2
          ? "Click to unpin · Right-click for settings"
          : "Click to close · Right-click for settings")

  readonly property string helperPath: decodeURIComponent(
    Qt.resolvedUrl("bisaiko").toString().replace(/^file:\/\//, "")
  )

  function invoke(action) {
    if (root.bar) root.bar.run("'" + helperPath.replace(/'/g, "'\\''") + "' " + action)
  }

  function invokeWithSettings(action) {
    root.invoke(action + " " + persisted.popupPosition + " " + persisted.pollMs)
  }

  function close() {
    settingsOpen = false
  }

  function refreshBarSection() {
    if (!barSectionProcess.running) barSectionProcess.running = true
  }

  function moveIcon(section) {
    settingsOpen = false
    if (section === root.actualBarSection || !root.bar) return
    actualBarSection = section
    root.bar.run("omarchy bar move " + root.moduleName + " --section " + section)
    // Confirm against the layout Omarchy actually wrote, in case the move
    // was rejected (e.g. the shell was not ready to answer).
    barSectionConfirmTimer.restart()
  }

  function resetDefaults() {
    persisted.popupPosition = defaultPopupPosition
    persisted.openDelayMs = defaultOpenDelayMs
    persisted.pollMs = defaultPollMs
    persisted.hoverEnabled = true
    persisted.tooltipEnabled = true
    settingsFile.writeAdapter()
    root.invoke("close")
    root.hoverPinned = false
    Qt.callLater(function() { root.moveIcon(defaultBarSection) })
  }

  // Migrations only run once real disk state has loaded (or once a fresh
  // file has been confirmed missing), so a mid-load default value never
  // gets mistaken for a genuinely old setting.
  function applySettingsMigrations() {
    if (persisted.settingsVersion < 1) {
      if (persisted.pollMs === 78) persisted.pollMs = defaultPollMs
    }
    if (persisted.settingsVersion < 2 && persisted.popupPosition === "top-right")
      persisted.popupPosition = defaultPopupPosition
    if (persisted.settingsVersion < 3) {
      persisted.tooltipEnabled = true
    }
    persisted.settingsVersion = 3
    settingsFile.writeAdapter()
  }

  function toggleSettings() {
    hoverOpenTimer.stop()
    hintTimer.stop()
    hintDismissTimer.stop()
    hintShown = false
    if (root.bar) root.bar.hideTooltip(button)
    root.invoke("close")
    root.hoverPinned = false
    root.clickState = 0
    root.refreshBarSection()
    root.settingsOpen = !root.settingsOpen
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onDestruction: root.invoke("close")
  Component.onCompleted: root.refreshBarSection()

  // Settings live in their own JSON file rather than Quickshell's
  // PersistentProperties: that mechanism only survives Quickshell's own live
  // config hot-reload (it shares the Reloadable base with LazyLoader/Scope),
  // not a plugin disable/enable cycle or a full shell restart. FileView +
  // JsonAdapter is genuine disk-backed persistence, so settings now survive
  // both.
  readonly property string settingsPath:
    Quickshell.env("HOME") + "/.config/omarchy/prusso.bisaiko-settings.json"

  FileView {
    id: settingsFile
    path: root.settingsPath
    watchChanges: true
    preload: true

    onLoaded: root.applySettingsMigrations()
    onLoadFailed: function(error) {
      // No settings file yet (first run on this machine): apply migrations
      // against the built-in defaults above, then create the file.
      if (error === FileViewError.FileNotFound) root.applySettingsMigrations()
    }

    JsonAdapter {
      id: persisted
      property string popupPosition: root.defaultPopupPosition
      property int openDelayMs: root.defaultOpenDelayMs
      property int pollMs: root.defaultPollMs
      property bool hoverEnabled: true
      property bool tooltipEnabled: true
      property int settingsVersion: 0
    }
  }

  Process {
    id: barSectionProcess
    running: false
    command: [root.helperPath, "bar-section", root.moduleName]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var section = text.trim()
        if (["left", "center", "right"].indexOf(section) !== -1)
          root.actualBarSection = section
      }
    }
  }

  Timer {
    id: barSectionConfirmTimer
    interval: 600
    repeat: false
    onTriggered: root.refreshBarSection()
  }

  Timer {
    id: hoverOpenTimer
    interval: persisted.openDelayMs
    repeat: false
    onTriggered: root.invokeWithSettings("enter")
  }

  Timer {
    id: hintTimer
    // Keep the hint unobtrusive: require a sustained hover before showing it.
    interval: 1200
    repeat: false
    onTriggered: {
      if (button.tooltipHovered && persisted.tooltipEnabled) {
        root.hintShown = true
        hintDismissTimer.restart()
      }
    }
  }

  Timer {
    id: hintDismissTimer
    interval: 1200
    repeat: false
    onTriggered: root.hintShown = false
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰍛"
    tooltipText: ""

    onTooltipHoveredChanged: {
      if (tooltipHovered) {
        if (persisted.hoverEnabled && !root.settingsOpen) hoverOpenTimer.restart()
        hintTimer.restart()
      } else {
        hoverOpenTimer.stop()
        hintTimer.stop()
        hintDismissTimer.stop()
        root.hintShown = false
        if (root.clickState !== 2) root.clickState = 0
        root.invoke("leave")
      }
    }

    onPressed: function(mouseButton) {
      hintTimer.stop()
      hintDismissTimer.stop()
      root.hintShown = false
      if (mouseButton === Qt.LeftButton) {
        hoverOpenTimer.stop()
        root.settingsOpen = false
        if (persisted.hoverEnabled) {
          root.invokeWithSettings("toggle")
          root.hoverPinned = !root.hoverPinned
          root.clickState = 0
        } else if (root.clickState === 1) {
          root.clickState = 2
          root.invokeWithSettings("pin")
        } else if (root.clickState === 2) {
          root.clickState = 3
          root.invokeWithSettings("unpin")
        } else if (root.clickState === 3) {
          root.clickState = 0
          root.invoke("close")
        } else {
          root.clickState = 1
          root.invokeWithSettings("open")
        }
      } else if (mouseButton === Qt.RightButton) {
        root.toggleSettings()
      }
    }
  }

  PopupWindow {
    id: hintWindow

    visible: root.hintShown && button.tooltipHovered && root.bar !== null
    color: "transparent"
    implicitWidth: Math.ceil(hintBubble.implicitWidth)
    implicitHeight: Math.ceil(hintBubble.implicitHeight)

    anchor {
      id: hintAnchor
      window: root.bar ? root.bar.targetWindow(button) : null
      adjustment: PopupAdjustment.Slide
      edges: Edges.Top | Edges.Left
      gravity: Edges.Bottom | Edges.Right
      rect.width: 1
      rect.height: 1

      onAnchoring: {
        if (!root.bar) return

        var popupWidth = hintWindow.implicitWidth
        var popupHeight = hintWindow.implicitHeight
        var localX = button.width / 2 - popupWidth / 2
        var localY = button.height + 6

        if (root.bar.position === "bottom") {
          localY = -popupHeight - 6
        } else if (root.bar.position === "left") {
          localX = button.width + 6
          localY = button.height / 2 - popupHeight / 2
        } else if (root.bar.position === "right") {
          localX = -popupWidth - 6
          localY = button.height / 2 - popupHeight / 2
        }

        var barWindow = root.bar.targetWindow(button)
        if (!barWindow) return
        var point = barWindow.contentItem.mapFromItem(button, localX, localY)

        // Keep the hint fully on-screen for every bar orientation. Horizontal
        // bars need horizontal clamping; vertical bars need vertical clamping.
        if (root.bar.position === "top" || root.bar.position === "bottom") {
          point.x = Math.max(0, Math.min(point.x, barWindow.width - popupWidth))
        } else {
          point.y = Math.max(0, Math.min(point.y, barWindow.height - popupHeight))
        }

        hintAnchor.rect.x = Math.round(point.x)
        hintAnchor.rect.y = Math.round(point.y)
      }
    }

    BorderSurface {
      id: hintBubble
      implicitWidth: hintLabel.implicitWidth + 20
      // Match Omarchy's standard tooltip typography while reducing its total
      // height by exactly 25 percent for Bisaikō only.
      implicitHeight: Math.ceil((hintLabel.implicitHeight + 14) * 0.6075)
      color: Color.tooltip.background
      borderSpec: Border.surfaceSpec("tooltip", "border", Color.tooltip.border, 1)
      radius: Style.cornerRadius

      Text {
        id: hintLabel
        anchors.centerIn: parent
        text: root.controlsHint
        color: Color.tooltip.text
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
      }
    }
  }

  PopupCard {
    id: settingsPopup
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.settingsOpen
    contentWidth: settingsPopup.fittedContentWidth(Style.space(390))
    contentHeight: settingsPopup.fittedContentHeight(settingsColumn.implicitHeight, Style.space(620))

    Column {
      id: settingsColumn
      anchors.fill: parent
      spacing: Style.space(10)

      Text {
        text: "Bisaikō settings"
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      Button {
        width: parent.width
        text: "Hover preview: " + (persisted.hoverEnabled ? "On" : "Off")
        selected: persisted.hoverEnabled
        foreground: root.bar.foreground
        onClicked: {
          persisted.hoverEnabled = !persisted.hoverEnabled
          settingsFile.writeAdapter()
          if (!persisted.hoverEnabled) {
            hoverOpenTimer.stop()
            hintTimer.stop()
            hintDismissTimer.stop()
            root.hintShown = false
            root.invoke("leave")
          }
        }
      }

      Button {
        width: parent.width
        text: "Tooltip: " + (persisted.tooltipEnabled ? "On" : "Off")
        selected: persisted.tooltipEnabled
        foreground: root.bar.foreground
        onClicked: {
          persisted.tooltipEnabled = !persisted.tooltipEnabled
          settingsFile.writeAdapter()
          if (!persisted.tooltipEnabled) {
            hintTimer.stop()
            hintDismissTimer.stop()
            root.hintShown = false
          }
        }
      }

      Text {
        text: "Window position"
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }

      Grid {
        id: positionGrid
        width: parent.width
        columns: 3
        spacing: Style.space(5)

        Repeater {
          model: root.positionOptions

          Button {
            required property var modelData
            width: (positionGrid.width - positionGrid.spacing * 2) / 3
            text: modelData.label
            selected: persisted.popupPosition === modelData.value
            foreground: root.bar.foreground
            fontSize: Style.font.caption
            horizontalPadding: Style.space(5)
            onClicked: {
              persisted.popupPosition = modelData.value
              settingsFile.writeAdapter()
              root.invoke("close")
            }
          }
        }
      }

      Text {
        text: "Icon placement"
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }

      Row {
        width: parent.width
        spacing: Style.space(6)

        Button {
          width: (parent.width - parent.spacing * 2) / 3
          text: "Left side"
          selected: root.actualBarSection === "left"
          foreground: root.bar.foreground
          onClicked: root.moveIcon("left")
        }

        Button {
          width: (parent.width - parent.spacing * 2) / 3
          text: "Middle"
          selected: root.actualBarSection === "center"
          foreground: root.bar.foreground
          onClicked: root.moveIcon("center")
        }

        Button {
          width: (parent.width - parent.spacing * 2) / 3
          text: "Right side"
          selected: root.actualBarSection === "right"
          foreground: root.bar.foreground
          onClicked: root.moveIcon("right")
        }
      }

      Text {
        text: "Timing"
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }

      Row {
        width: parent.width
        spacing: Style.space(6)

        Text {
          width: parent.width - openLess.width - openValue.width - openMore.width - parent.spacing * 3
          anchors.verticalCenter: parent.verticalCenter
          text: "Opening delay"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        Button {
          id: openLess
          text: "−"
          foreground: root.bar.foreground
          onClicked: {
            persisted.openDelayMs = Math.max(0, persisted.openDelayMs - 5)
            settingsFile.writeAdapter()
          }
        }
        Text {
          id: openValue
          width: Style.space(58)
          anchors.verticalCenter: parent.verticalCenter
          horizontalAlignment: Text.AlignHCenter
          text: persisted.openDelayMs + " ms"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        Button {
          id: openMore
          text: "+"
          foreground: root.bar.foreground
          onClicked: {
            persisted.openDelayMs = Math.min(500, persisted.openDelayMs + 5)
            settingsFile.writeAdapter()
          }
        }
      }

      Row {
        width: parent.width
        spacing: Style.space(6)

        Text {
          width: parent.width - pollLess.width - pollValue.width - pollMore.width - parent.spacing * 3
          anchors.verticalCenter: parent.verticalCenter
          text: "Dismissal polling"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        Button {
          id: pollLess
          text: "−"
          foreground: root.bar.foreground
          onClicked: {
            persisted.pollMs = Math.max(10, persisted.pollMs - 1)
            settingsFile.writeAdapter()
          }
        }
        Text {
          id: pollValue
          width: Style.space(58)
          anchors.verticalCenter: parent.verticalCenter
          horizontalAlignment: Text.AlignHCenter
          text: persisted.pollMs + " ms"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        Button {
          id: pollMore
          text: "+"
          foreground: root.bar.foreground
          onClicked: {
            persisted.pollMs = Math.min(500, persisted.pollMs + 1)
            settingsFile.writeAdapter()
          }
        }
      }

      Button {
        width: parent.width
        text: "Reset Bisaikō defaults"
        foreground: root.bar.foreground
        bordered: true
        onClicked: root.resetDefaults()
      }
    }
  }
}
