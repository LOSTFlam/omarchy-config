import QtQuick
Window {
  property real implicitWidth: 1180
  property real implicitHeight: 760
  property size minimumSize: Qt.size(760, 540)
  property bool maximized: false
  width: implicitWidth
  height: implicitHeight
  minimumWidth: minimumSize.width
  minimumHeight: minimumSize.height
}
