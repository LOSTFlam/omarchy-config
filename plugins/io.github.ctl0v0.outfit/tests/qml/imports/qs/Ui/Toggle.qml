import QtQuick
import QtQuick.Controls as C
import qs.Commons
C.CheckBox {
  property string label: ""
  property string description: ""
  property color foreground: "white"
  property color accent: "lightblue"
  property string fontFamily: Style.font.family
  property real titleSize: Style.font.subtitle
  property real descriptionSize: Style.font.caption
  font.family: fontFamily
  font.pixelSize: titleSize
  implicitWidth: 240
  implicitHeight: 54
  text: label
  // Host Toggle emits clicked; its owner updates the bound checked value.
  nextCheckState: function() { return checkState }
  Keys.onReturnPressed: if (enabled) clicked()
  Keys.onEnterPressed: if (enabled) clicked()
}
