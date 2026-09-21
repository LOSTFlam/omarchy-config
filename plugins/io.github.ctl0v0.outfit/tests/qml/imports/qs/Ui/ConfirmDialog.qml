import QtQuick
Item {
  property bool opened: false
  property int selectedIndex: 0
  property string message: ""
  property string confirmText: ""
  property color background: "black"
  property color foreground: "white"
  signal canceled()
  signal confirmed()
  function handleKey(event) { return false }
}
