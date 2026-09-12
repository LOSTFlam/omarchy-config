pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Wayland
import qs.Commons

Item {
  id: root

  required property var toplevel
  required property var geometry
  required property real workspaceWidth
  required property real workspaceHeight
  required property var iconSource
  required property string windowTitle
  property bool captureTimedOut: false

  readonly property bool captureSourceAvailable: !!toplevel.wayland
  readonly property var captureView: view
  readonly property real sx: workspaceWidth > 0 ? parent.width / workspaceWidth : 1
  readonly property real sy: workspaceHeight > 0 ? parent.height / workspaceHeight : 1

  signal captureContentChanged()

  function recapture() {
    if (view.hasContent && view.captureFrame) view.captureFrame()
  }

  x: geometry.x * sx
  y: geometry.y * sy
  width: Math.max(2, geometry.width * sx)
  height: Math.max(2, geometry.height * sy)
  clip: true

  Rectangle {
    anchors.fill: parent
    color: Color.popups.background
    border.color: Color.popups.border
    border.width: Math.max(1, Style.space(1))
    radius: Style.cornerRadius / 2
    clip: true

    ScreencopyView {
      id: view
      anchors.fill: parent
      captureSource: root.captureSourceAvailable ? root.toplevel.wayland : null
      live: false
      onHasContentChanged: root.captureContentChanged()
    }

    Column {
      anchors.centerIn: parent
      width: Math.max(1, parent.width - Style.space(12))
      spacing: Style.space(4)
      visible: !view.hasContent && (root.captureTimedOut || !root.captureSourceAvailable)

      Image {
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(Style.space(32), parent.width)
        height: width
        source: root.iconSource
        fillMode: Image.PreserveAspectFit
        smooth: true
      }

      Text {
        width: parent.width
        text: root.windowTitle
        textFormat: Text.PlainText
        color: Color.popups.text
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
        maximumLineCount: 2
      }
    }
  }
}
