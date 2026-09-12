import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The bar's update indicator, with the review step the stock widget skips.
//
// Stock behaviour was: icon appears when Omarchy is behind, click runs
// omarchy-update, which upgrades the entire system. The gap is that the icon
// reports one package and the click changes every package. This adds the
// reading between them.
//
//   left click   open the panel and read what would change
//   right click  run omarchy-update straight away, as the stock icon did
//
// The icon still appears only when Omarchy itself is behind. Showing it for
// any pending package would light it up most days on Arch and cost it every
// bit of the meaning it has now.
Panel {
  id: root
  // Kept as the built-in id on purpose: the shell routes IPC for a cloned
  // plugin through its source id, so `omarchy-shell omarchy.system-update ...`
  // keeps working against this copy.
  moduleName: "omarchy.system-update"
  ipcTarget: "omarchy.system-update"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var report: service.report
  readonly property bool hasData: report && report.ok
  readonly property bool reboots: Model.needsReboot(report)

  function runUpdate() {
    if (bar)
      bar.run("omarchy-launch-floating-terminal-with-presentation omarchy-update")
    close()
  }

  function refresh() {
    service.checkAvailable()
  }

  function clear() {
    service.updateAvailable = false
  }

  function scrollBy(steps) {
    if (!panelFlick)
      return
    var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
    panelFlick.contentY = Math.max(0, Math.min(maxY, panelFlick.contentY + steps * Style.space(48)))
  }

  visible: service.updateAvailable
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    if (panelFlick)
      panelFlick.contentY = 0
    // Cached results are shown immediately; a stale cache refreshes behind
    // them. Opening the panel should never be a blank three-second wait.
    service.scanIfStale()
    Qt.callLater(function () {
      keyCatcher.forceActiveFocus()
    })
  }

  Service {
    id: service
    scanPath: String(Qt.resolvedUrl("bin/omarchy-update-scan")).replace(/^file:\/\//, "")
    checkPath: String(Qt.resolvedUrl("bin/omarchy-update-check")).replace(/^file:\/\//, "")
    staleAfterMs: Math.max(1, root.setting("staleAfterMinutes", 10)) * 60000
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void {
      root.open()
    }
    function close(): void {
      root.close()
    }
    function show(): void {
      root.open()
    }
    function hide(): void {
      root.close()
    }
    function toggle(): void {
      root.toggle()
    }
    function refresh(): void {
      root.broadcastAll("refresh")
    }
    function clear(): void {
      root.broadcastAll("clear")
    }
  }

  // Panel has no broadcast() of its own (that lives on BarWidget), but a bar
  // surface still exists per monitor, so a refresh has to reach every copy or
  // the other screens keep a stale icon.
  function broadcastAll(method) {
    var items = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : [root]
    for (var i = 0; i < items.length; i++) {
      if (items[i] && typeof items[i][method] === "function")
        items[i][method]()
    }
  }

  Timer {
    interval: Math.max(1, root.setting("checkIntervalHours", 6)) * 3600000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    active: root.opened
    tooltipText: Model.tooltip(root.report, service.scanning)
    onPressed: function (buttonCode) {
      if (buttonCode === Qt.RightButton)
        root.runUpdate()
      else
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
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(body.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function (dx, dy) {
        if (dy !== 0)
          root.scrollBy(dy)
      }
      // Deliberately no onActivateRequested. Enter and Space both arrive here,
      // and in a panel whose only action upgrades the whole system, neither is
      // a gesture anyone means. The arrows here scroll the list rather than
      // move a cursor between controls, so there is nothing for Enter to
      // activate anyway: reading the list would have been the thing that armed
      // it. `u` stays the keyboard path, it is a deliberate letter and the
      // footer says so.
      onCloseRequested: root.close()
      onTabRequested: function (direction) {
        root.switchPanel(direction)
      }
      onTextKey: function (t) {
        if (t === "r" || t === "R")
          service.scan(true)
        else if (t === "u" || t === "U")
          root.runUpdate()
      }

      ColumnLayout {
        id: body
        anchors.fill: parent
        spacing: Style.space(12)

        // Header and action are pinned; only the change list scrolls. The
        // decision you came here to make should never be scrolled off screen.
        PanelHero {
          Layout.fillWidth: true
          // Built in Model, not here: it is package-controlled version text
          // going into a shared component whose textFormat this plugin does
          // not own, so it is flattened before it gets there.
          title: Model.heroTitle(root.report, service.availableSummary)
          meta: service.scanning && !root.hasData ? "Reading pending changes" : (root.hasData ? Model.summary(root.report) : "")
          detail: root.reboots ? "REBOOT" : ""
          foreground: root.foreground
          fontFamily: root.fontFamily

          iconComponent: Component {
            Text {
              text: ""
              textFormat: Text.PlainText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display

              RotationAnimation on rotation {
                from: 0
                to: 360
                duration: 1400
                loops: Animation.Infinite
                running: service.scanning
              }
            }
          }

          trailingControl: Component {
            PanelActionButton {
              iconText: ""
              tooltipText: "Re-check the mirrors"
              enabled: !service.scanning
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: service.scan(true)
            }
          }
        }

        Text {
          Layout.fillWidth: true
          visible: text !== ""
          text: service.scanError
          textFormat: Text.PlainText
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        // Stated plainly and up front, because it is the one consequence of
        // this update that outlives the update.
        Text {
          Layout.fillWidth: true
          visible: root.reboots
          text: "A new kernel or compositor is in this set. Omarchy will offer a reboot when it finishes."
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        PanelSeparator {
          Layout.fillWidth: true
          visible: root.hasData
          foreground: root.foreground
        }

        Flickable {
          id: panelFlick
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.preferredHeight: column.implicitHeight
          contentWidth: width
          contentHeight: column.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar {
            policy: ScrollBar.AsNeeded
          }

          Column {
            id: column
            width: panelFlick.width
            spacing: Style.space(14)

            Text {
              visible: root.hasData && Model.sections(root.report).length === 0
              width: parent.width
              text: "Nothing else is pending. Only Omarchy itself would change."
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: root.hasData ? Model.sections(root.report) : []

              Column {
                required property var modelData
                width: column.width
                spacing: Style.space(6)

                PanelSectionHeader {
                  text: modelData.title + "  " + modelData.rows.length
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                Text {
                  visible: modelData.note !== ""
                  width: parent.width
                  text: modelData.note
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                  bottomPadding: Style.space(2)
                }

                Repeater {
                  model: modelData.rows
                  ChangeRow {
                    required property var modelData
                    width: parent.width
                    row: modelData
                  }
                }
              }
            }

            // A capped list has to admit it. The header above counts the whole
            // update, so without this line the two quietly disagree.
            Text {
              visible: text !== ""
              width: parent.width
              text: root.hasData ? Model.omittedNote(root.report) : ""
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              topPadding: Style.space(2)
            }
          }
        }

        PanelSeparator {
          Layout.fillWidth: true
          foreground: root.foreground
        }

        Button {
          Layout.fillWidth: true
          text: root.hasData ? "Update now" : "Update now (unreviewed)"
          iconText: ""
          bordered: true
          foreground: root.foreground
          fontFamily: root.fontFamily
          tooltipText: "Runs omarchy-update in a terminal"
          onClicked: root.runUpdate()
        }

        Text {
          Layout.fillWidth: true
          text: "u update  .  r re-check  .  esc close"
          textFormat: Text.PlainText
          color: Qt.darker(root.foreground, 2.0)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
        }
      }
    }
  }

  // One package. Name and where it comes from on the left, the version move
  // and the download on the right, so a column of these reads top to bottom
  // as "what" then "how much".
  component ChangeRow: Item {
    id: changeRow

    property var row: null

    implicitHeight: rowLabels.implicitHeight + Style.space(6)

    Column {
      id: rowLabels
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      RowLayout {
        width: parent.width
        spacing: Style.space(8)

        Text {
          text: changeRow.row ? changeRow.row.name : ""
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          Layout.fillWidth: true
        }

        BorderSurface {
          visible: changeRow.row && changeRow.row.tag !== ""
          implicitWidth: tagText.implicitWidth + Style.space(8)
          implicitHeight: tagText.implicitHeight + Style.space(2)
          color: "transparent"
          radius: Style.cornerRadius
          borderSpec: Border.controlSpec("normal", changeRow.row && changeRow.row.tag === "reboot" ? root.urgent : root.foreground, Color.accent)

          Text {
            id: tagText
            anchors.centerIn: parent
            text: changeRow.row ? Model.tagLabel(changeRow.row.tag) : ""
            textFormat: Text.PlainText
            color: changeRow.row && changeRow.row.tag === "reboot" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          text: changeRow.row ? Model.rowMeta(changeRow.row) : ""
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          Layout.alignment: Qt.AlignVCenter
        }
      }

      Text {
        width: parent.width
        text: changeRow.row ? changeRow.row.from + " -> " + changeRow.row.to : ""
        textFormat: Text.PlainText
        color: Qt.darker(root.foreground, 1.9)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }
}
