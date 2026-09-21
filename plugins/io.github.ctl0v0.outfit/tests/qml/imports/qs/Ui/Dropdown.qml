import QtQuick
import QtQuick.Controls as C
C.ComboBox {
  property string label: ""
  property bool showLabel: true
  property real rowHeight: implicitHeight
  property color foreground: "white"
  property string fontFamily: "Sans Serif"
  property var options: []
  property string value: ""
  model: options
  textRole: "label"
  valueRole: "value"
  signal changed(string value)
  onActivated: changed(String(currentValue))
}
