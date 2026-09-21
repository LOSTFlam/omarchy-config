import QtQuick
import qs.Commons
import qs.Ui

// Keep Outfit's confirmation actions on the same themed Button component as
// the rest of the app. The host dialog currently hard-codes square actions.
Item {
  id: root
  property bool opened: false
  property string message: ""
  property string cancelText: "Cancel"
  property string confirmText: "Confirm"
  property int selectedIndex: 0
  property color background: Color.background
  property color foreground: Color.foreground
  property real cornerRadius: Style.cornerRadius
  signal canceled()
  signal confirmed()
  visible: opened
  onOpenedChanged: if (opened) selectedIndex = 0

  function handleKey(event) {
    if (!opened) return false
    if (event.key === Qt.Key_Escape) canceled()
    else if ([Qt.Key_Left,Qt.Key_Right,Qt.Key_Tab,Qt.Key_Backtab].indexOf(event.key) >= 0)
      selectedIndex = selectedIndex === 0 ? 1 : 0
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      if (selectedIndex === 0) canceled()
      else confirmed()
    } else return false
    return true
  }

  Rectangle {
    anchors.fill: parent
    color: Qt.rgba(Color.background.r,Color.background.g,Color.background.b,0.7)
    MouseArea { anchors.fill: parent; onClicked: root.canceled() }
  }
  BorderSurface {
    anchors.centerIn: parent
    width: Math.min(parent.width - Style.space(32),Math.max(Style.space(370),buttons.implicitWidth + Style.space(36)))
    height: content.implicitHeight + Style.space(36)
    color: root.background
    radius: root.cornerRadius
    borderSpec: Border.controlSpec("focus",root.foreground,Color.accent)
    MouseArea { anchors.fill: parent; onClicked: {} }
    Column {
      id: content
      x: Style.space(18); y: x
      width: parent.width - x * 2
      spacing: Style.space(20)
      Text {
        width: parent.width
        text: root.message
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: root.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.title
      }
      Row {
        id: buttons
        anchors.right: parent.right
        spacing: Style.space(10)
        Repeater {
          model: [root.cancelText,root.confirmText]
          Button {
            required property int index
            required property string modelData
            objectName: index === 0 ? "confirmationCancel" : "confirmationAccept"
            text: modelData
            width: Math.max(Style.space(88),implicitWidth)
            height: Math.max(Style.space(34),implicitHeight)
            radius: root.cornerRadius
            bordered: true
            selected: root.selectedIndex === index
            foreground: index === 1 ? Color.urgent : root.foreground
            accent: index === 1 ? Color.urgent : Color.accent
            fontFamily: Style.font.family
            fontSize: Style.font.caption
            onHotChanged: if (hot) root.selectedIndex = index
            onClicked: index === 0 ? root.canceled() : root.confirmed()
            Accessible.role: Accessible.Button
            Accessible.name: text
            Accessible.onPressAction: clicked()
          }
        }
      }
    }
  }
}
