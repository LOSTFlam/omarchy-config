import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
BarWidget {
  id: root
  moduleName: "org.example.outfit-continuity-probe"
  property string token: Date.now().toString(36) + Math.random().toString(36)
  implicitWidth: Style.space(60)
  implicitHeight: Style.space(24)
  Text { anchors.centerIn: parent; text: "PROBE"; color: Color.foreground }
  IpcHandler {
    target: "org.example.outfit-continuity-widget"
    function report(): string { return JSON.stringify({token: root.token}) }
  }
}
