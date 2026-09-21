import QtQuick
import QtQuick.Controls as C
import Quickshell
import qs.Commons
import qs.Ui
import "Typography.js" as Typography

Column {
  id: root
  readonly property real readingSize: Typography.reading(Style.font)
  readonly property real supportingSize: Typography.supporting(Style.font)
  property var service: null
  spacing: Style.space(10)
  readonly property string report: service && service.diagnostics && service.diagnostics.schema
    ? JSON.stringify({ diagnostics: service.diagnostics,
        lastLocalScan: service.lastHardwareCheckAt || 0,
        inventoryReady: service.inventoryReady === true }, null, 2) : ""
  function exactTime(seconds) {
    var value = Number(seconds)
    if (!isFinite(value) || value <= 0) return "Not yet available"
    var date = new Date(value * 1000)
    return isFinite(date.getTime()) ? date.toISOString() : "Time unavailable"
  }
  Text {
    text: "DIAGNOSTICS"
    textFormat: Text.PlainText
    color: Color.foreground
    font.family: Style.font.family
    font.pixelSize: root.readingSize
    font.bold: true
  }
  Text {
    width: parent.width
    text: "Versions, storage, and cache status. Personal details excluded."
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: Color.foreground
    font.family: Style.font.family
    font.pixelSize: root.readingSize
  }
  Text {
    width: parent.width
    text: "Catalog: " + root.exactTime(root.service ? root.service.fetchedAt : 0)
      + "\nPopularity: " + root.exactTime(root.service ? root.service.likesFetchedAt : 0)
      + "\nSystem: " + root.exactTime(root.service ? root.service.lastHardwareCheckAt / 1000 : 0)
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: Color.foreground
    font.family: Style.font.family
    font.pixelSize: root.supportingSize
  }
  Flow {
    width: parent.width
    spacing: Style.space(8)
    Button {
      text: "Check diagnostics"
      fontSize: root.readingSize
      focusable: true
      bordered: true
      enabled: root.service && !root.service.queryBusy
      onClicked: root.service.loadDiagnostics()
    }
    Button {
      text: "Copy diagnostics"
      fontSize: root.readingSize
      focusable: true
      enabled: Boolean(root.report)
      onClicked: {
        Quickshell.clipboardText = root.report
        root.service.notice = "Redacted diagnostics copied to clipboard."
      }
    }
    Button {
      text: "Clear preview cache"
      fontSize: root.readingSize
      focusable: true
      enabled: root.service && !root.service.busy && !root.service.backgroundBusy && !root.service.previewBusy
      onClicked: root.service.clearPreviewCache()
    }
  }
  ContentScrollView {
    width: parent.width
    height: visible ? Style.space(200) : 0
    visible: Boolean(root.report)
    clip: true
    C.TextArea {
      text: root.report
      readOnly: true
      selectByMouse: true
      textFormat: TextEdit.PlainText
      wrapMode: TextEdit.Wrap
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: root.supportingSize
      background: Rectangle { color: Color.background }
    }
  }
}
