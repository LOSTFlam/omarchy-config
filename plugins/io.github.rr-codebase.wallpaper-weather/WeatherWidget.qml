import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar icon plus a popup panel, following the same shape as Omarchy's own
// audio and network panels: one BarIconButton for the bar, a KeyboardPanel
// anchored to it for the body.
//
// The icon reflects whatever is on; the panel holds a switch per mood and
// sliders for intensity and wind. Everything that changes a value lives in the
// panel -- the bar icon only opens it, so there is no way to nudge a dial by
// scrolling past it.
//
// State is read from the file the service watches rather than by shelling out,
// so the panel stays in step with the CLI, the keybindings and the menu.
// Actions go through the bundled CLI by absolute path, so this works whether or
// not `wallpaper-weather` is on the user's PATH.
Panel {
  id: root
  moduleName: "io.github.rr-codebase.wallpaper-weather"
  ipcTarget: "io.github.rr-codebase.wallpaper-weather"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // The bar is transparent on many setups, so bar.barForeground is chosen to
  // contrast with the WALLPAPER. That is right for the icon sitting on it and
  // wrong for anything inside the popup, which sits on Color.popups.background
  // -- pick the wrong one and the labels disappear on half the themes.
  readonly property color panelText: Color.popups.text

  readonly property string cli:
    Qt.resolvedUrl("bin/wallpaper-weather").toString().replace(/^file:\/\//, "")

  property bool fxEnabled: true
  property bool rain: false
  property bool day: false
  property bool night: false
  property real intensity: 1.0
  property real wind: 0.0
  property bool thunder: false
  property bool fog: false
  property bool followSun: false
  property bool followWeather: false
  property bool powerSave: true

  readonly property bool anyMood: fxEnabled && (rain || day || night)

  // Rain wins the icon: if it is raining that is the headline whatever else is
  // on. Then sun, then moon, then a dormant cloud.
  readonly property string glyph: !fxEnabled ? "󰖨"
    : rain ? "󰖗"
    : day ? "󰖙"
    : night ? "󰖔"
    : "󰖐"

  readonly property string moodName: {
    if (!fxEnabled) return "Weather off"
    if (rain && day && night) return "Everything at once"
    if (rain && day) return "Sun shower"
    if (rain && night) return "Night storm"
    if (rain) return "Rain"
    if (day && night) return "Golden hour"
    if (day) return "Sunshine"
    if (night) return "Night"
    return "Clear"
  }

  function run(args) {
    if (root.bar) root.bar.run("'" + root.cli.replace(/'/g, "'\\''") + "' " + args)
  }

  property string pendingCmd: ""

  function queue(cmd) {
    pendingCmd = cmd
    if (!applyTimer.running) applyTimer.restart()
  }

  function flush(cmd) {
    applyTimer.stop()
    pendingCmd = ""
    run(cmd)
  }

  Timer {
    id: applyTimer
    interval: 200
    repeat: false
    onTriggered: {
      if (root.pendingCmd === "") return
      root.run(root.pendingCmd)
      root.pendingCmd = ""
    }
  }

  FileView {
    id: stateFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/wallpaper-weather.json"
    watchChanges: true
    printErrors: false
    onLoaded: {
      try {
        var cfg = JSON.parse(text() || "{}") || {}
        root.fxEnabled = cfg.enabled !== false
        root.rain = cfg.rain === true
        root.day = cfg.day === true
        root.night = cfg.night === true
        var i = Number(cfg.intensity); if (isFinite(i)) root.intensity = i
        var w = Number(cfg.wind); if (isFinite(w)) root.wind = w
        root.thunder = cfg.thunder === true
        root.fog = cfg.fog === true
        root.followSun = cfg.followSun === true
        root.followWeather = cfg.followWeather === true
        root.powerSave = cfg.powerSave !== false
      } catch (error) {
        // A half-written file is transient; keep the last good state.
      }
    }
    onFileChanged: reload()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    active: root.anyMood
    activeColor: Color.accent
    tooltipText: root.moodName + "\nClick for weather"
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.run("clear")
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(320))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(700))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: panelColumn
        width: parent.width
        spacing: Style.spacing.controlGap

        PanelSectionHeader {
          text: root.moodName
          foreground: root.panelText
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }

        // One switch per mood. They are independent and stack, so these are
        // switches rather than a radio group.
        Repeater {
          model: [
            { key: "rain",  glyph: "󰖗", label: "Rain" },
            { key: "day",   glyph: "󰖙", label: "Sunshine" },
            { key: "night", glyph: "󰖔", label: "Night" },
            { key: "thunder", glyph: "󱐋", label: "Thunder", needs: "rain" },
            { key: "fog",     glyph: "󰖑", label: "Fog" }
          ]

          Item {
            required property var modelData
            readonly property bool on: root[modelData.key] === true
            // Thunder without rain shows nothing, so say so rather than
            // letting it read as broken.
            readonly property bool usable: !modelData.needs || root[modelData.needs] === true

            width: panelColumn.width
            height: Style.spacing.controlHeight

            Text {
              id: rowIcon
              text: modelData.glyph
              textFormat: Text.PlainText
              color: parent.on ? Color.accent : root.panelText
              opacity: !parent.usable ? 0.45 : (parent.on ? 1.0 : 0.78)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.icon
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              text: modelData.label
              textFormat: Text.PlainText
              color: root.panelText
              opacity: !parent.usable ? 0.5 : (parent.on ? 1.0 : 0.85)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              anchors.left: rowIcon.right
              anchors.leftMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
            }

            ToggleSwitch {
              checked: parent.on
              interactive: parent.usable
              opacity: parent.usable ? 1.0 : 0.4
              foreground: root.panelText
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              onToggled: root.run(modelData.key)
            }
          }
        }

        PanelSeparator {
          width: panelColumn.width
          foreground: root.panelText
        }

        PanelSectionHeader {
          text: "Intensity  " + root.intensity.toFixed(1)
          foreground: root.panelText
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }

        PanelSlider {
          bar: root.bar
          width: panelColumn.width
          minimum: 0.2
          maximum: 2.0
          step: 0.1
          value: root.intensity
          onMoved: function(v) { root.queue("intensity " + v.toFixed(2)) }
          onReleased: function(v) { root.flush("intensity " + v.toFixed(2)) }
        }

        PanelSectionHeader {
          text: "Wind  " + root.wind.toFixed(2)
          foreground: root.panelText
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }

        PanelSlider {
          bar: root.bar
          width: panelColumn.width
          minimum: -1.0
          maximum: 1.0
          step: 0.05
          value: root.wind
          onMoved: function(v) { root.queue("wind " + v.toFixed(2)) }
          onReleased: function(v) { root.flush("wind " + v.toFixed(2)) }
        }

        PanelSeparator {
          width: panelColumn.width
          foreground: root.panelText
        }

        PanelSectionHeader {
          text: "Automatic"
          foreground: root.panelText
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }

        // Modes rather than actions: they keep tracking until switched off.
        // Toggling a mood by hand releases whichever mode owns it.
        Repeater {
          model: [
            { cmd: "follow-sun", prop: "followSun", glyph: "󰖜",
              label: "Follow the sun" },
            { cmd: "follow-weather", prop: "followWeather", glyph: "󰇧",
              label: "Match real weather" },
            { cmd: "power-save", prop: "powerSave", glyph: "󰒲",
              label: "Rest when covered" }
          ]

          Item {
            required property var modelData
            readonly property bool on: root[modelData.prop] === true

            width: panelColumn.width
            height: Style.spacing.controlHeight

            Text {
              id: modeIcon
              text: modelData.glyph
              textFormat: Text.PlainText
              color: parent.on ? Color.accent : root.panelText
              opacity: parent.on ? 1.0 : 0.858
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.icon
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              text: modelData.label
              textFormat: Text.PlainText
              color: root.panelText
              opacity: parent.on ? 1.0 : 0.85
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              anchors.left: modeIcon.right
              anchors.leftMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
            }

            ToggleSwitch {
              checked: parent.on
              foreground: root.panelText
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              onToggled: root.run(modelData.cmd)
            }
          }
        }

        PanelSeparator {
          width: panelColumn.width
          foreground: root.panelText
        }

        PanelSectionHeader {
          text: "Presets"
          foreground: root.panelText
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }

        // Genuinely one-shot: each sets a whole combination and is done, so
        // these stay buttons rather than joining the toggles above. Glyph and
        // label together -- the glyph is what you aim at once you know the
        // panel, the label is what makes storm and rain tellable apart the
        // first time, since at this size they are the same cloud.
        Flow {
          width: panelColumn.width
          spacing: Style.spacing.controlGap

          Repeater {
            model: [
              { cmd: "clear",      glyph: "󰅖", label: "Clear",  tip: "All moods off" },
              { cmd: "shower",     glyph: "󰖗", label: "Rain",   tip: "Rain, no thunder" },
              { cmd: "storm",      glyph: "󰖓", label: "Storm",  tip: "Heavy rain and thunder at night" },
              { cmd: "goldenhour", glyph: "󰖚", label: "Golden", tip: "Sun and stars at once" },
              { cmd: "noir",       glyph: "󰖔", label: "Night",  tip: "Stars, moonlight and fireflies" }
            ]

            Button {
              required property var modelData
              iconText: modelData.glyph
              text: modelData.label
              tooltipText: modelData.tip
              bordered: true
              foreground: root.panelText
              accent: Color.accent
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              onClicked: { root.run(modelData.cmd); root.close() }
            }
          }
        }
      }
    }
  }
}
