import QtQuick
import qs.Commons
import qs.Ui

// Add and remove channels. Adding asks the panel, which runs the script; this
// view only shows the list and the error under the field.
Item {
  id: view

  property var host: null
  property string error: ""

  readonly property Item focusItem: input
  readonly property color fg: host ? host.foreground : Color.foreground
  readonly property color dim: host ? host.dim : Qt.darker(Color.foreground, 1.55)
  readonly property color urgent: host ? host.urgent : Color.urgent
  readonly property string family: host ? host.fontFamily : Style.font.family
  readonly property var rows: host ? host.channels : []
  readonly property bool adding: host ? host.adding : false
  readonly property real gap: Style.space(8)

  function clearInput() {
    input.text = ""
    error = ""
  }

  function submit() {
    if (adding) return
    host.addChannel(input.text)
  }

  function handleKey(event) {
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      submit()
    } else if (event.key === Qt.Key_Escape) {
      host.showVideos()
    } else {
      return
    }
    event.accepted = true
  }

  Column {
    id: upper
    width: parent.width
    spacing: view.gap

    Item {
      width: parent.width
      height: Math.max(back.implicitHeight, heading.implicitHeight)

      Button {
        id: back
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        iconText: "󰁍"
        text: "Back"
        tooltipText: "Back to the videos (Esc)"
        foreground: view.fg
        fontFamily: view.family
        onClicked: view.host.showVideos()
      }

      Text {
        id: heading
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: "Channels"
        textFormat: Text.PlainText
        color: view.fg
        font.family: view.family
        font.pixelSize: Style.font.title
        font.bold: true
      }
    }

    Row {
      width: parent.width
      spacing: Style.space(6)

      TextField {
        id: input
        width: parent.width - addButton.implicitWidth - parent.spacing
        enabled: !view.adding
        placeholderText: view.adding ? "Looking up channel…" : "Paste a channel URL or @handle"
        foreground: view.fg
        font.family: view.family
        Keys.onPressed: function(event) { view.handleKey(event) }
      }

      Button {
        id: addButton
        anchors.verticalCenter: parent.verticalCenter
        text: "Add"
        bordered: true
        enabled: !view.adding && input.text.trim() !== ""
        opacity: enabled ? 1 : 0.55
        foreground: view.fg
        fontFamily: view.family
        onClicked: view.submit()
      }
    }

    Text {
      width: parent.width
      visible: text !== ""
      text: view.error
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: view.urgent
      font.family: view.family
      font.pixelSize: Style.font.bodySmall
    }
  }

  ListView {
    id: list
    anchors.top: upper.bottom
    anchors.topMargin: view.gap
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(4)
    width: parent.width
    visible: view.rows.length > 0
    clip: true
    spacing: Style.space(2)
    boundsBehavior: Flickable.StopAtBounds
    model: view.rows

    delegate: Rectangle {
      id: channelRow
      required property var modelData
      width: list.width
      implicitHeight: Math.max(labels.implicitHeight, remove.implicitHeight) + Style.space(8)
      radius: Style.cornerRadius
      color: rowHover.hovered ? Style.hoverFillFor(view.fg, Color.accent) : "transparent"

      HoverHandler { id: rowHover }

      Column {
        id: labels
        anchors.left: parent.left
        anchors.leftMargin: Style.space(8)
        anchors.right: remove.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          width: parent.width
          text: channelRow.modelData.name || channelRow.modelData.id
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: view.fg
          font.family: view.family
          font.pixelSize: Style.font.body
        }

        Text {
          width: parent.width
          visible: text !== ""
          text: channelRow.modelData.lastError
                || (channelRow.modelData.source === "yt-dlp" ? "via yt-dlp (feed unavailable)" : "")
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: view.dim
          font.family: view.family
          font.pixelSize: Style.font.caption
        }
      }

      Button {
        id: remove
        anchors.right: parent.right
        anchors.rightMargin: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        iconText: "󰅖"
        tooltipText: "Remove channel"
        foreground: view.fg
        fontFamily: view.family
        onClicked: view.host.removeChannel(channelRow.modelData.id)
      }
    }
  }

  Text {
    anchors.top: upper.bottom
    anchors.topMargin: view.gap
    width: parent.width
    visible: view.rows.length === 0
    text: "No channels yet. Paste a channel URL above."
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: view.dim
    font.family: view.family
    font.pixelSize: Style.font.bodySmall
  }
}
