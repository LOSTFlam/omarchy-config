import QtQuick
import QtQuick.Controls as C
import qs.Commons
C.Button {
  id: root
  property color foreground: "white"
  property color accent: "lightblue"
  property bool bordered: false
  property real radius: Style.cornerRadius
  property bool focusable: false
  property bool selected: false
  readonly property bool hot: hovered
  property string iconText: ""
  property real fontSize: Style.font.body
  horizontalPadding: 12
  verticalPadding: 7
  property bool iconSpinning: false
  property string fontFamily: Style.font.family
  font.family: fontFamily
  font.pixelSize: fontSize
  font.bold: selected
  leftPadding: horizontalPadding + 1
  rightPadding: horizontalPadding + 1
  topPadding: verticalPadding + 1
  bottomPadding: verticalPadding + 1
  // Match the host's text-sized controls rather than the native style's
  // platform-dependent minimum width/height. Keep real pointer/key dispatch.
  implicitWidth: contentItem.implicitWidth + leftPadding + rightPadding
  implicitHeight: contentItem.implicitHeight + topPadding + bottomPadding
  contentItem: Text {
    text: root.text
    textFormat: Text.PlainText
    font: root.font
    color: root.foreground
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
  }
  focusPolicy: focusable ? Qt.StrongFocus : Qt.NoFocus
  Keys.onReturnPressed: if (enabled && focusable) clicked()
  Keys.onEnterPressed: if (enabled && focusable) clicked()
}
