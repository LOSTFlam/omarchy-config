import QtQuick
import Quickshell
Item {
  id: root
  property var shell: null
  property var manifest: null
  property string token: Date.now().toString(36) + Math.random().toString(36)
  property string draft: ""
  property bool opened: false
  function open(payload) { opened = true }
  function close() { opened = false }
  function remember(value) { draft = value; return report("") }
  function report(unused) { return JSON.stringify({token: token, draft: draft, opened: opened}) }
  FloatingWindow {
    title: "Fictional Continuity Probe"
    implicitWidth: 250
    implicitHeight: 90
    visible: root.opened
    color: "#182331"
    Text {
      anchors.centerIn: parent
      text: "Continuity fixture\n" + root.draft
      color: "#eeeeee"
      horizontalAlignment: Text.AlignHCenter
    }
  }
}
