import QtQuick
import qs.Commons
import qs.Ui
BarWidget {
  moduleName: "org.example.omafit-release-fixture"
  implicitWidth: Style.space(40)
  implicitHeight: Style.space(24)
  Text { anchors.centerIn: parent; text: "TEST"; textFormat: Text.PlainText; color: Color.foreground }
}
