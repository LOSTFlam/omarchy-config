pragma Singleton
import QtQuick
QtObject {
  property var font: ({family:"monospace",caption:12,bodySmall:14,body:16,subtitle:18,title:22})
  readonly property real cornerRadius: 8
  readonly property var spacing: ({hairline:1})
  function space(value) { return value }
  function selectedFillFor(foreground, accent) { return "#303840" }
  function selectedStateColor(foreground, accent) { return accent }
}
