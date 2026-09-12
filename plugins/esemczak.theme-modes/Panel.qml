import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "esemczak.theme-modes"
  ipcTarget: "esemczak.theme-modes"
  manageIpc: false

  property string activeTab: "general"
  property string focusSection: "tabs"
  property int lightThemeIndex: 0
  property int darkThemeIndex: 0
  property bool cursorActive: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color panelBackground: Color.popups.background
  readonly property string themeTabBackgroundPath: {
    if (activeTab === "light") {
      if (Model.isSafeLocalPath(themeModes.state.lightBackground)) return themeModes.state.lightBackground
      if (lightTab.centerTheme && Model.isSafeLocalPath(lightTab.centerTheme.previewPath))
        return lightTab.centerTheme.previewPath
    }
    if (activeTab === "dark") {
      if (Model.isSafeLocalPath(themeModes.state.darkBackground)) return themeModes.state.darkBackground
      if (darkTab.centerTheme && Model.isSafeLocalPath(darkTab.centerTheme.previewPath))
        return darkTab.centerTheme.previewPath
    }
    var activeBg = Model.backgroundForMode(themeModes.state)
    if (activeBg) return activeBg
    return previewPathForSlug(themeModes.activeThemeSlug)
  }
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property var tabOptions: [
    { value: "general", label: "General" },
    { value: "light", label: "Light themes" },
    { value: "dark", label: "Dark themes" }
  ]

  function themeIndexForSlug(slug, themes) {
    var key = Model.slugFromName(slug)
    for (var i = 0; i < themes.length; i++) {
      if (themes[i].slug === key) return i
    }
    return 0
  }

  function safeImagePath(path) {
    return Model.isSafeLocalPath(path) ? String(path) : ""
  }

  function previewPathForSlug(slug) {
    var key = Model.slugFromName(slug)
    for (var i = 0; i < themeModes.themes.length; i++) {
      if (themeModes.themes[i].slug === key) {
        var path = String(themeModes.themes[i].previewPath || "")
        return Model.isSafeLocalPath(path) ? path : ""
      }
    }
    return ""
  }

  function syncThemeIndices() {
    lightThemeIndex = themeIndexForSlug(themeModes.state.lightTheme, themeModes.themes)
    darkThemeIndex = themeIndexForSlug(themeModes.state.darkTheme, themeModes.themes)
    if (lightTab.visible && !lightTab.isAdjusting()) lightTab.syncFromSlug(false)
    if (darkTab.visible && !darkTab.isAdjusting()) darkTab.syncFromSlug(false)
  }

  function tabIndexFor(value) {
    for (var i = 0; i < tabOptions.length; i++) {
      if (tabOptions[i].value === value) return i
    }
    return 0
  }

  function setActiveTab(tab) {
    activeTab = tab
    cursorActive = false
    if (tab === "general") focusSection = "mode"
    else {
      focusSection = "themes"
      Qt.callLater(function() {
        if (tab === "light") lightTab.syncFromSlug(false)
        else if (tab === "dark") darkTab.syncFromSlug(false)
      })
    }
  }

  function selectedLightTheme() {
    if (themeModes.themes.length === 0) return null
    return themeModes.themes[Math.max(0, Math.min(lightThemeIndex, themeModes.themes.length - 1))]
  }

  function selectedDarkTheme() {
    if (themeModes.themes.length === 0) return null
    return themeModes.themes[Math.max(0, Math.min(darkThemeIndex, themeModes.themes.length - 1))]
  }

  function activateCursor() {
    cursorActive = true
    if (focusSection === "tabs") return
    if (activeTab === "general") {
      if (focusSection === "mode") return
      if (focusSection === "switching") return
      return
    }
    if (activeTab === "light" || activeTab === "dark") return
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    if (dx !== 0 && focusSection === "tabs") {
      var idx = tabIndexFor(activeTab) + dx
      idx = Math.max(0, Math.min(tabOptions.length - 1, idx))
      setActiveTab(tabOptions[idx].value)
      focusSection = "tabs"
      return
    }
    if (activeTab === "general") {
      if (dy < 0) {
        if (focusSection === "mode") focusSection = "tabs"
        else if (focusSection === "switching") focusSection = "mode"
        return
      }
      if (dy > 0) {
        if (focusSection === "tabs") focusSection = "mode"
        else if (focusSection === "mode") focusSection = "switching"
        return
      }
      return
    }
    if (dx !== 0 && themeModes.themes.length > 0 && (activeTab === "light" || activeTab === "dark")) {
      focusSection = "themes"
      if (activeTab === "light") lightTab.stepCenter(dx)
      else darkTab.stepCenter(dx)
      return
    }
    if (dy !== 0) {
      if (dy < 0 && focusSection === "themes") focusSection = "tabs"
      else if (dy > 0 && focusSection === "tabs") focusSection = "themes"
    }
  }

  Service {
    id: themeModes
    settings: root.settings
  }

  Connections {
    target: themeModes
    function onThemesChanged() { root.syncThemeIndices() }
    function onStateChanged() { root.syncThemeIndices() }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function toggleMode(): string { themeModes.toggleModeManual(); return themeModes.state.mode }
    function followAutomatic(): string { themeModes.followAutomatic(); return "ok" }
    function refreshThemes(): string { themeModes.refreshThemes(); return "ok" }
    function status(): string {
      return JSON.stringify({
        mode: themeModes.state.mode,
        manualOverride: themeModes.state.manualOverride,
        autoEnabled: themeModes.state.autoEnabled,
        autoSource: themeModes.state.autoSource,
        lightTheme: themeModes.state.lightTheme,
        darkTheme: themeModes.state.darkTheme,
        lightBackground: themeModes.state.lightBackground,
        darkBackground: themeModes.state.darkBackground,
        activeTheme: themeModes.activeThemeSlug,
        status: themeModes.statusText
      })
    }
  }

  onOpenedChanged: if (opened) {
    themeModes.refreshThemes()
    syncThemeIndices()
    setActiveTab("general")
    focusSection = "tabs"
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.modeIcon(themeModes.state.mode)
    tooltipText: "Theme modes · " + themeModes.statusText + " · Right-click toggles light/dark"
    onPressed: function(b) {
      if (b === Qt.RightButton) {
        themeModes.toggleModeManual()
        return
      }
      if (b === Qt.MiddleButton) {
        themeModes.followAutomatic()
        return
      }
      root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ThemePanelBackground {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.topMargin: -panel.padding
        anchors.rightMargin: -panel.padding
        anchors.bottomMargin: -panel.padding
        anchors.leftMargin: -panel.padding
        visible: root.themeTabBackgroundPath !== ""
        previewPath: root.themeTabBackgroundPath
        fadeColor: root.panelBackground
        cornerRadius: Math.max(0, Style.cornerRadius - Border.top(panel.borderSpec))
      }

      Column {
        id: column
        z: 1
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        Row {
          width: parent.width
          spacing: Style.space(12)

          Text {
            text: Model.modeIcon(themeModes.state.mode)
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            width: parent.width - parent.children[0].width - parent.spacing
            spacing: Style.space(2)

            Text {
              text: "Theme modes"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              width: parent.width
            }

            Text {
              text: (themeModes.statusText + " · " + Model.displayNameForSlug(themeModes.activeThemeSlug, themeModes.themes)).toUpperCase()
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.0
              width: parent.width
              elide: Text.ElideRight
            }
          }
        }

        PanelTabBar {
          width: parent.width
          foreground: root.foreground
          dim: root.dim
          accent: Color.accent
          fontFamily: root.fontFamily
          value: root.activeTab
          cursorIndex: root.cursorActive && root.focusSection === "tabs" ? root.tabIndexFor(root.activeTab) : -1
          options: root.tabOptions
          onChanged: function(value) { root.setActiveTab(value) }
          onHovered: function(index, hovered) {
            if (hovered) {
              root.cursorActive = true
              root.focusSection = "tabs"
            }
          }
        }

        Item {
          width: parent.width
          height: activeTab === "general" ? generalTab.implicitHeight
            : (activeTab === "light" ? lightTab.implicitHeight : darkTab.implicitHeight)

          GeneralTab {
            id: generalTab
            anchors.top: parent.top
            width: parent.width
            visible: root.activeTab === "general"
          }

          ThemePicker {
            id: lightTab
            anchors.top: parent.top
            width: parent.width
            visible: root.activeTab === "light"
            title: "Choose light theme"
            themes: themeModes.themes
            selectedSlug: themeModes.state.lightTheme
            selectedBackground: themeModes.state.lightBackground
            onPick: function(slug) { themeModes.setLightTheme(slug) }
            onPickBackground: function(path) { themeModes.setLightBackground(path) }
          }

          ThemePicker {
            id: darkTab
            anchors.top: parent.top
            width: parent.width
            visible: root.activeTab === "dark"
            title: "Choose dark theme"
            themes: themeModes.themes
            selectedSlug: themeModes.state.darkTheme
            selectedBackground: themeModes.state.darkBackground
            onPick: function(slug) { themeModes.setDarkTheme(slug) }
            onPickBackground: function(path) { themeModes.setDarkBackground(path) }
          }
        }

        Text {
          width: parent.width
          visible: themeModes.lastError !== ""
          text: themeModes.lastError
          color: root.bar ? root.bar.urgent : Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  component PanelTabBar: Item {
    id: tabs

    property var options: []
    property string value: ""
    property color foreground: Color.foreground
    property color dim: Color.foreground
    property color accent: Color.accent
    property string fontFamily: Style.font.family
    property int cursorIndex: -1

    signal changed(string value)
    signal hovered(int index, bool isHovered)

    implicitWidth: tabRow.implicitWidth
    implicitHeight: tabRow.height + Style.space(1)

    function optionValue(option) {
      return (option && typeof option === "object") ? String(option.value) : String(option)
    }

    function optionLabel(option) {
      return (option && typeof option === "object" && option.label !== undefined) ? String(option.label) : String(option)
    }

    Row {
      id: tabRow
      width: parent.width
      spacing: Style.space(18)

      Repeater {
        model: tabs.options

        delegate: Item {
          id: tabItem

          required property var modelData
          required property int index

          readonly property bool selected: tabs.optionValue(modelData) === tabs.value
          readonly property bool hot: tabs.cursorIndex === index || tabMouse.containsMouse

          implicitWidth: tabLabel.implicitWidth + Style.space(4)
          implicitHeight: Style.space(34)

          Text {
            id: tabLabel
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: tabIndicator.top
            anchors.bottomMargin: Style.space(6)
            text: tabs.optionLabel(modelData)
            color: tabItem.selected ? tabs.foreground : tabs.dim
            opacity: tabItem.selected ? 1.0 : (tabItem.hot ? 0.92 : 0.72)
            font.family: tabs.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: tabItem.selected
          }

          Rectangle {
            id: tabIndicator
            anchors.bottom: parent.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width
            height: tabItem.selected ? Style.space(2) : Style.space(1)
            radius: Style.space(1)
            color: tabItem.selected
              ? tabs.accent
              : (tabItem.hot ? Qt.rgba(tabs.accent.r, tabs.accent.g, tabs.accent.b, 0.45) : "transparent")
          }

          MouseArea {
            id: tabMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: tabs.changed(tabs.optionValue(modelData))
            onContainsMouseChanged: tabs.hovered(index, containsMouse)
          }
        }
      }
    }

    Rectangle {
      anchors.bottom: parent.bottom
      width: parent.width
      height: 1
      color: Qt.rgba(tabs.foreground.r, tabs.foreground.g, tabs.foreground.b, 0.12)
    }
  }

  component GeneralTab: Column {
    id: page

    width: parent.width
    spacing: Style.space(10)

    PanelSectionHeader {
      text: "MODE"
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    ButtonGroup {
      width: parent.width
      foreground: root.foreground
      background: root.bar ? root.bar.background : Color.background
      accent: Color.accent
      fontFamily: root.fontFamily
      value: themeModes.state.mode
      cursorIndex: root.cursorActive && root.activeTab === "general" && root.focusSection === "mode"
        ? (themeModes.state.mode === "light" ? 0 : 1) : -1
      options: [
        { value: "light", label: "Light", icon: "󰖙" },
        { value: "dark", label: "Dark", icon: "󰖔" }
      ]
      onChanged: function(value) { themeModes.setModeManual(value) }
      onHovered: function(index, hovered) {
        if (hovered) {
          root.cursorActive = true
          root.focusSection = "mode"
        }
      }
    }

    PanelSectionHeader {
      text: "SWITCHING"
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Text {
      width: parent.width
      text: "Manual keeps the mode you pick above. Automatic switches light/dark using the rules below."
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    ButtonGroup {
      width: parent.width
      foreground: root.foreground
      background: root.bar ? root.bar.background : Color.background
      accent: Color.accent
      fontFamily: root.fontFamily
      value: themeModes.state.manualOverride || !themeModes.state.autoEnabled ? "manual" : "automatic"
      cursorIndex: root.cursorActive && root.activeTab === "general" && root.focusSection === "switching"
        ? (themeModes.state.manualOverride || !themeModes.state.autoEnabled ? 0 : 1) : -1
      options: [
        { value: "manual", label: "Manual", icon: "󰒋" },
        { value: "automatic", label: "Automatic", icon: "󰥔" }
      ]
      onChanged: function(value) {
        if (value === "automatic") themeModes.enableAutomaticSwitching()
        else themeModes.enableManualSwitching()
      }
      onHovered: function(index, hovered) {
        if (hovered) {
          root.cursorActive = true
          root.focusSection = "switching"
        }
      }
    }

    PanelSeparator {
      foreground: root.foreground
      visible: !themeModes.state.manualOverride && themeModes.state.autoEnabled
    }

    PanelSectionHeader {
      text: "RULES"
      foreground: root.foreground
      fontFamily: root.fontFamily
      visible: !themeModes.state.manualOverride && themeModes.state.autoEnabled
    }

    ButtonGroup {
      width: parent.width
      visible: !themeModes.state.manualOverride && themeModes.state.autoEnabled
      foreground: root.foreground
      background: root.bar ? root.bar.background : Color.background
      accent: Color.accent
      fontFamily: root.fontFamily
      value: themeModes.state.autoSource
      options: [
        { value: "time", label: "Schedule", icon: "󰥔" },
        { value: "battery", label: "Battery", icon: "󰁹" }
      ]
      onChanged: function(value) { themeModes.setAutoSource(value) }
    }

    Row {
      width: parent.width
      spacing: Style.space(8)
      visible: !themeModes.state.manualOverride && themeModes.state.autoEnabled && themeModes.state.autoSource === "time"

      Column {
        width: (parent.width - parent.spacing) / 2
        spacing: Style.spacing.labelGap
        Text {
          text: "Light from"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
        TextField {
          width: parent.width
          text: themeModes.state.lightStart
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          onEditingFinished: themeModes.setLightStart(text)
        }
      }

      Column {
        width: (parent.width - parent.spacing) / 2
        spacing: Style.spacing.labelGap
        Text {
          text: "Dark from"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
        TextField {
          width: parent.width
          text: themeModes.state.darkStart
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          onEditingFinished: themeModes.setDarkStart(text)
        }
      }
    }

    BatteryAutoInfo {
      width: parent.width
      visible: !themeModes.state.manualOverride && themeModes.state.autoEnabled && themeModes.state.autoSource === "battery"
      foreground: root.foreground
      dim: root.dim
      accent: Color.accent
      fontFamily: root.fontFamily
      lightThemeName: Model.displayNameForSlug(themeModes.state.lightTheme, themeModes.themes)
      darkThemeName: Model.displayNameForSlug(themeModes.state.darkTheme, themeModes.themes)
      onBattery: themeModes.onBattery
    }
  }

  component BatteryAutoInfo: Item {
    id: info

    property color foreground: Color.foreground
    property color dim: Color.foreground
    property color accent: Color.accent
    property string fontFamily: Style.font.family
    property string lightThemeName: ""
    property string darkThemeName: ""
    property bool onBattery: false

    implicitWidth: card.width
    implicitHeight: card.implicitHeight

    Rectangle {
      id: card
      width: parent.width
      implicitHeight: content.implicitHeight + Style.space(24)
      radius: Style.cornerRadius + 1
      color: Qt.rgba(info.foreground.r, info.foreground.g, info.foreground.b, 0.05)
      border.width: 1
      border.color: Qt.rgba(info.foreground.r, info.foreground.g, info.foreground.b, 0.12)

      Column {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.space(12)
        spacing: Style.space(10)

        Row {
          width: parent.width
          spacing: Style.space(8)

          Text {
            text: "󰁹"
            color: info.accent
            font.family: info.fontFamily
            font.pixelSize: Style.font.title
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            width: parent.width - parent.children[0].width - parent.spacing
            spacing: Style.space(2)

            Text {
              text: "Battery switching"
              color: info.foreground
              font.family: info.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
              width: parent.width
            }

            Text {
              text: "Omarchy picks your light or dark theme pair based on power source."
              color: info.dim
              font.family: info.fontFamily
              font.pixelSize: Style.font.caption
              width: parent.width
              wrapMode: Text.WordWrap
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(6)

          BatteryAutoRuleRow {
            width: parent.width
            icon: "󰂄"
            label: "On battery"
            modeLabel: "Dark"
            themeName: info.darkThemeName
            active: info.onBattery
            foreground: info.foreground
            dim: info.dim
            accent: info.accent
            fontFamily: info.fontFamily
          }

          BatteryAutoRuleRow {
            width: parent.width
            icon: "󰚥"
            label: "On power"
            modeLabel: "Light"
            themeName: info.lightThemeName
            active: !info.onBattery
            foreground: info.foreground
            dim: info.dim
            accent: info.accent
            fontFamily: info.fontFamily
          }
        }

        Rectangle {
          width: parent.width
          height: 1
          color: Qt.rgba(info.foreground.r, info.foreground.g, info.foreground.b, 0.1)
        }

        Text {
          width: parent.width
          text: info.onBattery
            ? "Right now: unplugged · using dark theme"
            : "Right now: plugged in · using light theme"
          color: info.accent
          font.family: info.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }
    }
  }

  component BatteryAutoRuleRow: Rectangle {
    id: row

    property string icon: ""
    property string label: ""
    property string modeLabel: ""
    property string themeName: ""
    property bool active: false
    property color foreground: Color.foreground
    property color dim: Color.foreground
    property color accent: Color.accent
    property string fontFamily: Style.font.family

    radius: Style.cornerRadius
    color: row.active
      ? Qt.rgba(row.accent.r, row.accent.g, row.accent.b, 0.12)
      : Qt.rgba(row.foreground.r, row.foreground.g, row.foreground.b, 0.04)
    border.width: row.active ? 1 : 0
    border.color: Qt.rgba(row.accent.r, row.accent.g, row.accent.b, 0.45)
    implicitHeight: inner.implicitHeight + Style.space(12)

    Row {
      id: inner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(10)

      Text {
        text: row.icon
        color: row.active ? row.accent : row.dim
        font.family: row.fontFamily
        font.pixelSize: Style.font.body
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        width: parent.width - parent.children[0].width - parent.children[2].width - parent.spacing * 2
        spacing: Style.space(1)
        anchors.verticalCenter: parent.verticalCenter

        Text {
          text: row.label
          color: row.active ? row.foreground : row.dim
          font.family: row.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: row.active
        }

        Text {
          text: row.themeName || row.modeLabel.toLowerCase() + " theme"
          color: row.foreground
          opacity: row.active ? 1.0 : 0.82
          font.family: row.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
          width: parent.width
        }
      }

      Text {
        text: row.modeLabel
        color: row.active ? row.accent : row.dim
        font.family: row.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        anchors.verticalCenter: parent.verticalCenter
      }
    }
  }

  component CarouselNavOrb: Item {
    id: orbHost

    property string iconText: ""
    property string fontFamily: Style.font.family
    property color foreground: Color.foreground
    property color backdrop: Color.popups.background
    property bool enabled: true
    property real laneHeight: Style.space(128)
    property real size: Style.space(38)

    signal clicked()

    width: size
    height: laneHeight

    readonly property bool hot: mouse.containsMouse && orbHost.enabled

    Item {
      anchors.centerIn: parent
      width: orbHost.size
      height: orbHost.size
      opacity: orbHost.enabled ? 1.0 : 0.34
      scale: orbHost.hot ? 1.07 : 1.0

      Behavior on scale {
        NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
      }

      Behavior on opacity {
        NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
      }

      Rectangle {
        anchors.centerIn: parent
        anchors.verticalCenterOffset: Style.space(2)
        width: orbHost.size
        height: orbHost.size
        radius: width / 2
        color: Util.alpha(Qt.black, orbHost.hot ? 0.28 : 0.18)
        z: -1
      }

      BorderSurface {
        id: orb
        anchors.fill: parent
        radius: width / 2
        color: orbHost.hot
          ? Style.hoverFillFor(orbHost.foreground, Color.accent)
          : Util.alpha(orbHost.backdrop, 0.82)
        borderSpec: orbHost.hot
          ? Border.controlSpec("hover-cursor", orbHost.foreground, Color.accent)
          : Border.controlSpec("normal", orbHost.foreground, Color.accent)

        Behavior on color {
          ColorAnimation { duration: 100; easing.type: Easing.OutCubic }
        }

        Rectangle {
          anchors.fill: parent
          anchors.margins: 1
          radius: width / 2
          color: "transparent"
          border.width: 1
          border.color: Util.alpha(orbHost.foreground, orbHost.hot ? 0.34 : 0.14)
        }

        Text {
          anchors.centerIn: parent
          text: orbHost.iconText
          color: orbHost.hot ? Color.accent : orbHost.foreground
          font.family: orbHost.fontFamily
          font.pixelSize: Style.font.title
        }

        MouseArea {
          id: mouse
          anchors.fill: parent
          enabled: orbHost.enabled
          hoverEnabled: true
          cursorShape: orbHost.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: orbHost.clicked()
        }
      }
    }
  }

  component ThemePicker: Column {
    id: picker

    property string title: ""
    property var themes: []
    property string selectedSlug: ""
    property string selectedBackground: ""
    property int centerIndex: 0
    property int ghostIndex: 0
    property bool suppressPick: false

    readonly property bool backgroundsReady: picker.centerTheme
      && themeModes.backgroundsSlug === Model.slugFromName(picker.centerTheme.slug)
    readonly property var availableBackgrounds: picker.backgroundsReady ? themeModes.backgrounds : []

    readonly property int loopCopies: 3

    readonly property int cardWidth: Style.space(84)
    readonly property int cardHeight: Style.space(68)
    readonly property int cardSpacing: Style.space(8)
    readonly property int itemStep: cardWidth + cardSpacing
    readonly property real centerScale: 1.34
    readonly property real neighborScale: 0.92
    readonly property real nearScale: 0.80
    readonly property real farScale: 0.68
    readonly property int carouselHeight: Style.space(128)
    readonly property int trackPad: carouselViewport
      ? Math.max(0, Math.floor((carouselViewport.width - cardWidth) / 2))
      : 0
    readonly property var centerTheme: {
      if (picker.themes.length === 0) return null
      var idx = Math.max(0, Math.min(picker.centerIndex, picker.themes.length - 1))
      return picker.themes[idx]
    }

    signal pick(string slug)
    signal pickBackground(string path)

    function indexForSlug(slug) {
      var key = Model.slugFromName(slug)
      for (var i = 0; i < picker.themes.length; i++) {
        if (Model.slugFromName(picker.themes[i].slug) === key) return i
      }
      return 0
    }

    function scaleForDistance(distance) {
      if (distance === 0) return picker.centerScale
      if (distance === 1) return picker.neighborScale
      if (distance === 2) return picker.nearScale
      return picker.farScale
    }

    function syncGhostFromCenter() {
      if (picker.themes.length === 0) {
        picker.ghostIndex = 0
        return
      }
      picker.ghostIndex = picker.themes.length + picker.centerIndex
    }

    function normalizeGhost() {
      var n = picker.themes.length
      if (n <= 1 || !carouselViewport) return
      while (picker.ghostIndex >= picker.loopCopies * n - n) {
        picker.ghostIndex -= n
        themeTrack.x += n * picker.itemStep
      }
      while (picker.ghostIndex < n) {
        picker.ghostIndex += n
        themeTrack.x -= n * picker.itemStep
      }
    }

    function syncFromSlug(applyPick) {
      if (picker.themes.length === 0) return
      pickDebounceTimer.stop()
      picker.suppressPick = true
      picker.centerIndex = picker.indexForSlug(picker.selectedSlug)
      picker.syncGhostFromCenter()
      picker.scrollToGhost(true)
      picker.suppressPick = false
      if (applyPick) picker.applyCenterSelection()
    }

    function applyCenterSelection() {
      var theme = picker.centerTheme
      if (!theme) return
      picker.pick(theme.slug)
    }

    function schedulePick() {
      if (picker.suppressPick) return
      pickDebounceTimer.restart()
    }

    function isAdjusting() {
      return pickDebounceTimer.running || scrollAnimation.running
    }

    function commitPick() {
      if (picker.suppressPick) return
      pickDebounceTimer.stop()
      picker.applyCenterSelection()
    }

    function stepCenter(delta) {
      if (picker.themes.length === 0 || delta === 0) return
      if (picker.themes.length === 1) {
        picker.commitPick()
        return
      }
      var n = picker.themes.length
      picker.centerIndex = (picker.centerIndex + delta + n) % n
      picker.ghostIndex += delta
      picker.scrollToGhost(false)
      picker.schedulePick()
    }

    function scrollToGhost(immediate) {
      if (!carouselViewport || picker.themes.length === 0) return
      var offset = picker.trackPad + picker.ghostIndex * picker.itemStep + picker.cardWidth / 2 - carouselViewport.width / 2
      scrollSettleTimer.stop()
      if (immediate) {
        scrollAnimation.stop()
        themeTrack.x = -offset
        picker.normalizeGhost()
        return
      }
      scrollAnimation.stop()
      scrollAnimation.from = themeTrack.x
      scrollAnimation.to = -offset
      scrollAnimation.start()
      scrollSettleTimer.restart()
    }

    function settleScroll() {
      if (scrollAnimation.running) {
        scrollSettleTimer.restart()
        return
      }
      picker.normalizeGhost()
    }

    Connections {
      target: carouselViewport
      function onWidthChanged() { picker.scrollToGhost(true) }
    }

    onThemesChanged: if (picker.visible) Qt.callLater(function() { picker.syncFromSlug(false) })
    onSelectedSlugChanged: {
      if (!picker.visible || picker.suppressPick || pickDebounceTimer.running) return
      Qt.callLater(function() { picker.syncFromSlug(false) })
    }
    onVisibleChanged: {
      if (picker.visible) {
        Qt.callLater(function() { picker.syncFromSlug(false) })
        if (picker.centerTheme) backgroundsLoader.restart()
        return
      }
      if (pickDebounceTimer.running) picker.commitPick()
    }

    Timer {
      id: backgroundsLoader
      interval: 120
      repeat: false
      onTriggered: {
        if (picker.centerTheme) themeModes.loadBackgroundsForSlug(picker.centerTheme.slug)
      }
    }

    onCenterIndexChanged: backgroundsLoader.restart()

    Timer {
      id: pickDebounceTimer
      interval: 450
      repeat: false
      onTriggered: picker.commitPick()
    }

    Timer {
      id: scrollSettleTimer
      interval: 60
      repeat: false
      onTriggered: picker.settleScroll()
    }

    width: parent.width
    spacing: Style.space(8)

    PanelSectionHeader {
      text: picker.title
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Text {
      width: parent.width
      visible: themeModes.loadingThemes
      text: "Loading theme previews…"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Item {
      width: parent.width
      height: picker.carouselHeight

      Item {
        id: carouselViewport
        anchors.fill: parent
        clip: true

        Item {
          id: themeTrack
          height: parent.height
          width: picker.themes.length > 0
            ? picker.trackPad + picker.loopCopies * picker.themes.length * picker.itemStep - picker.cardSpacing
            : 0
          y: (parent.height - picker.cardHeight) / 2

          Row {
            x: picker.trackPad
            spacing: picker.cardSpacing

            Repeater {
              model: picker.themes.length > 0 ? picker.themes.length * picker.loopCopies : 0
              delegate: ThemeCarouselCard {
                required property int index
                property int themeIndex: index % picker.themes.length
                property var themeData: picker.themes[themeIndex]
                name: themeData.name
                previewPath: root.safeImagePath(themeData.previewPath || "")
                distance: Math.abs(index - picker.ghostIndex)
                cardScale: picker.scaleForDistance(Math.abs(index - picker.ghostIndex))
                foreground: root.foreground
                fontFamily: root.fontFamily
                cardWidth: picker.cardWidth
                cardHeight: picker.cardHeight
              }
            }
          }
        }

      }

      CarouselNavOrb {
        id: prevButton
        anchors.left: parent.left
        anchors.leftMargin: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        laneHeight: picker.carouselHeight
        iconText: "󰅁"
        foreground: root.foreground
        fontFamily: root.fontFamily
        backdrop: root.panelBackground
        enabled: picker.themes.length > 1
        z: 2
        onClicked: picker.stepCenter(-1)
      }

      CarouselNavOrb {
        id: nextButton
        anchors.right: parent.right
        anchors.rightMargin: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        laneHeight: picker.carouselHeight
        iconText: "󰅂"
        foreground: root.foreground
        fontFamily: root.fontFamily
        backdrop: root.panelBackground
        enabled: picker.themes.length > 1
        z: 2
        onClicked: picker.stepCenter(1)
      }
    }

    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      text: picker.centerTheme ? picker.centerTheme.name : "No theme"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      elide: Text.ElideRight
    }

    PanelSectionHeader {
      text: "BACKGROUND"
      foreground: root.foreground
      fontFamily: root.fontFamily
      visible: picker.centerTheme
    }

    Text {
      width: parent.width
      visible: picker.centerTheme && themeModes.loadingBackgrounds && !picker.backgroundsReady
      text: "Loading backgrounds…"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      width: parent.width
      visible: picker.centerTheme && picker.backgroundsReady && picker.availableBackgrounds.length === 0
      text: "No backgrounds bundled with this theme"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Flow {
      width: parent.width
      spacing: Style.space(6)
      visible: picker.availableBackgrounds.length > 0

      Repeater {
        model: picker.availableBackgrounds
        delegate: BackgroundThumb {
          required property var modelData
          name: modelData.name
          imagePath: root.safeImagePath(modelData.thumbnailPath || modelData.path)
          selected: modelData.path === picker.selectedBackground
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: picker.pickBackground(modelData.path)
        }
      }
    }

    NumberAnimation {
      id: scrollAnimation
      target: themeTrack
      property: "x"
      duration: 420
      easing.type: Easing.OutCubic
      onStopped: scrollSettleTimer.restart()
    }
  }

  component BackgroundThumb: Item {
    id: thumb

    property string name: ""
    property string imagePath: ""
    property bool selected: false
    property color foreground: Color.foreground
    property string fontFamily: Style.font.family

    signal clicked()

    readonly property int size: Style.space(56)

    width: size
    height: size + Style.space(14)

    Rectangle {
      anchors.top: parent.top
      width: thumb.size
      height: thumb.size
      radius: Style.cornerRadius
      color: Qt.rgba(thumb.foreground.r, thumb.foreground.g, thumb.foreground.b, 0.08)
      border.width: thumb.selected ? 2 : 1
      border.color: thumb.selected ? Color.accent : Qt.rgba(thumb.foreground.r, thumb.foreground.g, thumb.foreground.b, 0.18)
      clip: true

      Image {
        anchors.fill: parent
        anchors.margins: 1
        source: thumb.imagePath ? Util.fileUrl(thumb.imagePath) : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        visible: status === Image.Ready
      }
    }

    Text {
      anchors.top: parent.top
      anchors.topMargin: thumb.size + Style.space(2)
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      text: thumb.name
      color: thumb.foreground
      opacity: thumb.selected ? 1.0 : 0.72
      font.family: thumb.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }

    MouseArea {
      anchors.top: parent.top
      width: thumb.size
      height: thumb.size
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: thumb.clicked()
    }
  }

  component ThemePanelBackground: Item {
    id: bg

    property string previewPath: ""
    property color fadeColor: Color.popups.background
    property real cornerRadius: Style.cornerRadius

    clip: true

    property real wallpaperOpacity: 0
    readonly property real maxViewZoom: 1.45
    property real viewPanX: 0
    property real viewPanY: 0
    property real viewZoom: 1.0
    property real imgWidth: 0
    property real imgHeight: 0
    property real imgX: 0
    property real imgY: 0
    property int activePaneIndex: -1
    property bool comicMotionActive: false

    readonly property var comicPaneDefs: [
      { px: 0.14, py: 0.10, z: 1.10 },
      { px: 0.28, py: 0.18, z: 1.18 },
      { px: 0.20, py: 0.26, z: 1.12 },
      { px: 0.34, py: 0.14, z: 1.24 },
      { px: 0.10, py: 0.22, z: 1.08 },
      { px: 0.24, py: 0.30, z: 1.16 }
    ]

    function overviewView() {
      return { viewPanX: 0, viewPanY: 0, viewZoom: 1.0 }
    }

    function clamp01(value) {
      return Math.max(0, Math.min(1, value))
    }

    function clampZoom(value) {
      return Math.max(1.0, Math.min(bg.maxViewZoom, value))
    }

    function syncImageLayout() {
      var panelW = motionStage.width
      var panelH = motionStage.height
      if (panelW <= 0 || panelH <= 0) return

      var zoom = bg.clampZoom(bg.viewZoom)
      var w = panelW * zoom
      var h = panelH * zoom
      var maxPanX = Math.max(0, w - panelW)
      var maxPanY = Math.max(0, h - panelH)

      bg.imgWidth = w
      bg.imgHeight = h
      bg.imgX = -(maxPanX * bg.clamp01(bg.viewPanX))
      bg.imgY = maxPanY * bg.clamp01(bg.viewPanY)
    }

    function viewFromDef(def) {
      return {
        viewPanX: bg.clamp01(def.px),
        viewPanY: bg.clamp01(def.py),
        viewZoom: bg.clampZoom(def.z)
      }
    }

    function jitterView(view, panSpread, zoomSpread) {
      return {
        viewPanX: bg.clamp01(view.viewPanX + panSpread * (Math.random() - 0.5)),
        viewPanY: bg.clamp01(view.viewPanY + panSpread * (Math.random() - 0.5)),
        viewZoom: bg.clampZoom(view.viewZoom + zoomSpread * (Math.random() - 0.5))
      }
    }

    function applyView(view) {
      bg.viewPanX = view.viewPanX
      bg.viewPanY = view.viewPanY
      bg.viewZoom = view.viewZoom
      bg.syncImageLayout()
    }

    function setAmbientTargets(view, duration) {
      var moveMs = duration || (5500 + Math.floor(Math.random() * 1700))
      ambientPanX.from = bg.viewPanX
      ambientPanY.from = bg.viewPanY
      ambientZoom.from = bg.viewZoom
      ambientPanX.to = view.viewPanX
      ambientPanY.to = view.viewPanY
      ambientZoom.to = view.viewZoom
      ambientPanX.duration = moveMs
      ambientPanY.duration = moveMs + 400
      ambientZoom.duration = moveMs + 200
    }

    function resetMotion() {
      bg.applyView(bg.overviewView())
      bg.activePaneIndex = -1
    }

    function pickNextPaneIndex() {
      if (bg.comicPaneDefs.length === 0) return 0
      if (bg.comicPaneDefs.length <= 1) return 0
      var next = bg.activePaneIndex
      var guard = 0
      while (next === bg.activePaneIndex && guard < 12) {
        next = Math.floor(Math.random() * bg.comicPaneDefs.length)
        guard++
      }
      return next
    }

    function runAmbientBeat() {
      if (!bg.comicMotionActive) return
      var index = bg.pickNextPaneIndex()
      var target = bg.jitterView(bg.viewFromDef(bg.comicPaneDefs[index]), 0.04, 0.05)
      bg.activePaneIndex = index
      bg.setAmbientTargets(target)
      ambientAnim.start()
    }

    function scheduleAmbientBeat() {
      if (!bg.comicMotionActive) return
      beatTimer.interval = 700 + Math.floor(Math.random() * 600)
      beatTimer.start()
    }

    function stopComicMotion() {
      bg.comicMotionActive = false
      introTimer.stop()
      beatTimer.stop()
      ambientAnim.stop()
    }

    function startComicMotion() {
      if (bg.comicMotionActive) return
      if (!bg.previewPath || bg.wallpaperOpacity <= 0 || wallpaper.status !== Image.Ready || wallpaperFade.running)
        return
      if (motionStage.width <= 0 || motionStage.height <= 0) {
        Qt.callLater(bg.startComicMotion)
        return
      }
      bg.comicMotionActive = true
      bg.applyView(bg.overviewView())
      bg.activePaneIndex = -1
      introTimer.restart()
    }

    function startAmbientIfReady() {
      Qt.callLater(bg.startComicMotion)
    }

    onViewPanXChanged: bg.syncImageLayout()
    onViewPanYChanged: bg.syncImageLayout()
    onViewZoomChanged: bg.syncImageLayout()

    Rectangle {
      anchors.fill: parent
      radius: bg.cornerRadius
      clip: true
      color: "transparent"

      Item {
        id: motionStage
        anchors.fill: parent

        onWidthChanged: bg.syncImageLayout()
        onHeightChanged: bg.syncImageLayout()

        Image {
          id: wallpaper
          anchors.top: motionStage.top
          anchors.right: motionStage.right
          width: bg.imgWidth > 0 ? bg.imgWidth : motionStage.width
          height: bg.imgHeight > 0 ? bg.imgHeight : motionStage.height
          x: bg.imgX
          y: bg.imgY
          source: bg.previewPath ? Util.fileUrl(bg.previewPath) : ""
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          visible: bg.previewPath !== "" && status === Image.Ready
          opacity: bg.wallpaperOpacity

          Behavior on opacity {
            NumberAnimation { duration: 280; easing.type: Easing.OutCubic }
          }
        }
      }

      Shape {
        id: fadeOverlay
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
          fillRule: ShapePath.WindingFill
          strokeWidth: 0
          fillGradient: LinearGradient {
            x1: fadeOverlay.width
            y1: 0
            x2: fadeOverlay.width * 0.66
            y2: fadeOverlay.height * 0.66
            GradientStop { position: 0.0; color: "transparent" }
            GradientStop { position: 0.42; color: Qt.rgba(bg.fadeColor.r, bg.fadeColor.g, bg.fadeColor.b, 0.72) }
            GradientStop { position: 1.0; color: bg.fadeColor }
          }

          PathSvg {
            path: "M 0 0 L " + fadeOverlay.width + " 0 L " + fadeOverlay.width + " " + fadeOverlay.height + " L 0 " + fadeOverlay.height + " Z"
          }
        }
      }
    }

    ParallelAnimation {
      id: ambientAnim
      running: false
      onStopped: {
        if (bg.comicMotionActive)
          bg.scheduleAmbientBeat()
      }

      NumberAnimation {
        id: ambientPanX
        target: bg
        property: "viewPanX"
        easing.type: Easing.InOutSine
      }

      NumberAnimation {
        id: ambientPanY
        target: bg
        property: "viewPanY"
        easing.type: Easing.InOutSine
      }

      NumberAnimation {
        id: ambientZoom
        target: bg
        property: "viewZoom"
        easing.type: Easing.InOutSine
      }
    }

    Timer {
      id: introTimer
      running: false
      repeat: false
      interval: 300
      onTriggered: {
        if (bg.comicMotionActive)
          bg.runAmbientBeat()
      }
    }

    Timer {
      id: beatTimer
      running: false
      repeat: false
      onTriggered: {
        if (bg.comicMotionActive)
          bg.runAmbientBeat()
      }
    }

    Connections {
      target: wallpaper
      function onStatusChanged() {
        if (wallpaper.status !== Image.Ready) return
        bg.syncImageLayout()
        if (bg.wallpaperOpacity > 0 && !wallpaperFade.running)
          bg.startAmbientIfReady()
      }
    }

    SequentialAnimation {
      id: wallpaperFade
      running: false
      onStarted: bg.stopComicMotion()
      onStopped: {
        if (bg.previewPath && bg.wallpaperOpacity > 0)
          bg.startAmbientIfReady()
      }

      PropertyAnimation { target: bg; property: "wallpaperOpacity"; to: 0; duration: 140; easing.type: Easing.OutCubic }
      ScriptAction { script: bg.resetMotion() }
      PropertyAction { target: wallpaper; property: "source" }
      PropertyAnimation { target: bg; property: "wallpaperOpacity"; to: 0.62; duration: 280; easing.type: Easing.OutCubic }
    }

    onPreviewPathChanged: {
      bg.stopComicMotion()
      if (bg.previewPath) {
        bg.wallpaperOpacity = 0
        bg.resetMotion()
        wallpaperFade.restart()
      } else {
        bg.wallpaperOpacity = 0
        bg.resetMotion()
      }
    }

    Component.onCompleted: {
      bg.syncImageLayout()
      if (bg.previewPath)
        wallpaperFade.restart()
    }
  }

  component ThemeCarouselCard: Item {
    id: card

    property string name: ""
    property string previewPath: ""
    property int distance: 0
    property real cardScale: 1.0
    property color foreground: Color.foreground
    property string fontFamily: Style.font.family
    property int cardWidth: Style.space(84)
    property int cardHeight: Style.space(68)

    property real cardOpacity: distance <= 2 ? 1.0 : (distance === 3 ? 0.55 : 0.3)

    width: cardWidth
    height: cardHeight
    opacity: cardOpacity
    z: 100 - Math.min(distance, 50)

    Behavior on cardScale { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
    Behavior on opacity { NumberAnimation { duration: 180 } }

    transform: Scale {
      origin.x: card.width / 2
      origin.y: card.height / 2
      xScale: card.cardScale
      yScale: card.cardScale
    }

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: Qt.rgba(card.foreground.r, card.foreground.g, card.foreground.b, 0.1)
      clip: true

      Image {
        id: cardImage
        anchors.fill: parent
        anchors.margins: 1
        source: card.previewPath ? Util.fileUrl(card.previewPath) : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        visible: status === Image.Ready
      }

      Rectangle {
        anchors.fill: parent
        visible: !card.previewPath || cardImage.status !== Image.Ready
        color: Qt.rgba(card.foreground.r, card.foreground.g, card.foreground.b, 0.12)

        Text {
          anchors.centerIn: parent
          text: card.name ? card.name.charAt(0) : "?"
          color: card.foreground
          opacity: 0.35
          font.family: card.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }
      }
    }
  }
}
