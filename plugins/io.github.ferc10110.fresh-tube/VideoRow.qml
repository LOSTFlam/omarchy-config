import QtQuick
import qs.Commons
import qs.Ui
import "FreshTubeModel.js" as Model

// One video: thumbnail, title, channel and age. A click plays it. On hover
// (or on the keyboard-selected row) a pin keeps it listed after watching and,
// unless it is pinned, a ✕ marks it seen instead.
Rectangle {
  id: row

  property var host: null
  property var video: null
  property bool selected: false
  property real nowMs: Date.now()
  property bool pinned: false
  property bool pinsFull: false
  property bool pinnable: true

  signal activated()
  signal dismissed()
  signal pinToggled()

  readonly property color fg: host ? host.foreground : Color.foreground
  readonly property color dim: host ? host.dim : Qt.darker(Color.foreground, 1.55)
  readonly property string family: host ? host.fontFamily : Style.font.family
  readonly property bool showPin: pinnable && (pinned || hover.containsMouse || selected)
  readonly property bool showDismiss: !pinned && (hover.containsMouse || selected)
  readonly property real bodyWidth: content.x + thumb.width + content.spacing + textColumn.width

  implicitHeight: Math.max(thumb.height, textColumn.implicitHeight) + Style.space(12)
  radius: Style.cornerRadius
  color: selected ? Style.selectionFillFor(fg, Color.accent)
    : (hover.containsMouse ? Style.hoverFillFor(fg, Color.accent) : "transparent")

  MouseArea {
    id: hover
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: row.activated()
  }

  Row {
    id: content
    x: Style.space(8)
    y: Style.space(6)
    width: row.width - Style.space(16)
    spacing: Style.space(10)

    Rectangle {
      id: thumb
      width: Style.space(96)
      height: Style.space(54)
      radius: Math.max(2, Style.cornerRadius / 2)
      color: Qt.rgba(row.fg.r, row.fg.g, row.fg.b, 0.08)
      clip: true

      Image {
        anchors.fill: parent
        source: row.video && row.video.thumbnail ? row.video.thumbnail : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        sourceSize.width: Style.space(192)
      }
    }

    Column {
      id: textColumn
      width: content.width - thumb.width - content.spacing
        - (pinButton.visible ? pinButton.implicitWidth + content.spacing : 0)
        - (dismissButton.visible ? dismissButton.implicitWidth + content.spacing : 0)
      spacing: Style.space(3)
      anchors.verticalCenter: parent.verticalCenter

      Text {
        width: parent.width
        text: row.video ? row.video.title : ""
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        elide: Text.ElideRight
        color: row.fg
        font.family: row.family
        font.pixelSize: Style.font.body
        font.bold: true
      }

      Text {
        width: parent.width
        text: row.video ? row.video.channel + " · " + Model.relativeTime(row.video.published || row.video.addedAt, row.nowMs) : ""
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: row.dim
        font.family: row.family
        font.pixelSize: Style.font.caption
      }
    }

    Button {
      id: pinButton
      visible: row.showPin
      anchors.verticalCenter: parent.verticalCenter
      iconText: "󰐃"
      selected: row.pinned
      opacity: !row.pinned && row.pinsFull ? 0.4 : 1
      tooltipText: row.pinned ? "Unpin (P)"
        : (row.pinsFull ? "Pin limit reached (3)" : "Pin: keep it listed after watching (P)")
      foreground: row.fg
      fontFamily: row.family
      onClicked: row.pinToggled()
    }

    Button {
      id: dismissButton
      visible: row.showDismiss
      anchors.verticalCenter: parent.verticalCenter
      iconText: "󰅖"
      tooltipText: row.pinnable ? "Mark as seen (Delete)" : "Remove from the list (Delete)"
      foreground: row.fg
      fontFamily: row.family
      onClicked: row.dismissed()
    }
  }
}
