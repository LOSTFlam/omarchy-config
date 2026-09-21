pragma Singleton
import QtQuick
QtObject {
  readonly property color foreground: "#eeeeee"
  readonly property color background: "#202020"
  property color accent: "#99ccff"
  readonly property color urgent: "#ff9988"
  readonly property var popups: ({text:foreground,background:background})
}
