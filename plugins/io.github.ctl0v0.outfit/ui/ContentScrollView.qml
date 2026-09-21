import QtQuick
import QtQuick.Controls as C
import qs.Commons

// Standard ScrollView API. Content should use availableWidth, which excludes
// this stable gutter even when the vertical bar is not needed.
C.ScrollView {
  id: root
  readonly property real scrollbarWidth: Math.max(Style.space(10), verticalBar.implicitWidth)
  readonly property real scrollbarGap: Style.space(6)
  readonly property real scrollbarGutter: scrollbarWidth + scrollbarGap
  rightPadding: scrollbarGutter
  contentWidth: availableWidth
  C.ScrollBar.horizontal.policy: C.ScrollBar.AlwaysOff
  C.ScrollBar.vertical: C.ScrollBar {
    id: verticalBar
    parent: root
    x: root.width - width
    y: root.topPadding
    width: root.scrollbarWidth
    height: root.availableHeight
  }
}
