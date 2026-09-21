import QtQuick

// Reused from QuickshellSpotify. Quickshell's default wheel step feels
// glacial in long lists, so both pixel and angle deltas use a 4x multiplier
// and are clamped to the Flickable's real bounds. Mouse-wheel notches are
// eased toward the target so lyric lines stay trackable.
Item {
  id: root

  required property var flickable
  property real speedMultiplier: 4
  property real mouseWheelStep: Math.max(1,
    Number(Application.styleHints.wheelScrollLines) || 3) * 24
  property int notchAnimationMs: 180
  property real pendingTargetY: 0
  readonly property bool animating: wheelAnim.running

  signal scrolled()

  x: 0
  y: 0
  width: flickable.width
  height: flickable.height
  z: 1000

  function scrollDistance(pixelDeltaY, angleDeltaY) {
    var distance = Number(pixelDeltaY) || 0
    if (distance === 0)
      distance = (Number(angleDeltaY) || 0) / 120 * mouseWheelStep
    return distance * speedMultiplier
  }

  function boundedContentY(value) {
    var minimum = Number(flickable.originY) || 0
    var maximum = Math.max(minimum,
      minimum + Math.max(0, Number(flickable.contentHeight) || 0)
        - Math.max(0, Number(flickable.height) || 0))
    return Math.max(minimum, Math.min(maximum, value))
  }

  function stopAnimation() {
    if (wheelAnim.running) wheelAnim.stop()
  }

  function applyContentY(value) {
    var previous = flickable.contentY
    stopAnimation()
    flickable.cancelFlick()
    flickable.contentY = boundedContentY(value)
    if (Math.abs(flickable.contentY - previous) > 0.01) scrolled()
    return flickable.contentY
  }

  function scrollByDeltas(pixelDeltaY, angleDeltaY) {
    var distance = scrollDistance(pixelDeltaY, angleDeltaY)
    if (distance === 0 || !flickable.interactive) return flickable.contentY
    return applyContentY(flickable.contentY - distance)
  }

  // Pixel deltas already arrive as a stream, so they stay 1:1. Discrete
  // mouse-wheel notches jump a large fraction of the lyric viewport; those
  // are interpolated so the current line stays readable while it moves.
  function scrollByDeltasAnimated(pixelDeltaY, angleDeltaY) {
    var distance = scrollDistance(pixelDeltaY, angleDeltaY)
    if (distance === 0 || !flickable.interactive) return flickable.contentY
    if ((Number(pixelDeltaY) || 0) !== 0 || notchAnimationMs <= 0)
      return applyContentY(flickable.contentY - distance)

    var origin = wheelAnim.running ? pendingTargetY : flickable.contentY
    var target = boundedContentY(origin - distance)
    if (Math.abs(target - flickable.contentY) <= 0.01) return flickable.contentY

    pendingTargetY = target
    flickable.cancelFlick()
    wheelAnim.stop()
    wheelAnim.from = flickable.contentY
    wheelAnim.to = target
    wheelAnim.start()
    scrolled()
    return target
  }

  NumberAnimation {
    id: wheelAnim
    target: flickable
    property: "contentY"
    duration: Math.max(0, root.notchAnimationMs)
    easing.type: Easing.OutCubic
  }

  Connections {
    target: root.flickable
    function onMovementStarted() { root.stopAnimation() }
  }

  WheelHandler {
    target: null
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
    blocking: true

    onWheel: function(event) {
      var distance = root.scrollDistance(event.pixelDelta.y, event.angleDelta.y)
      if (distance === 0 || !root.flickable.interactive) {
        event.accepted = false
        return
      }
      var previous = root.flickable.contentY
      var current = root.scrollByDeltasAnimated(event.pixelDelta.y,
        event.angleDelta.y)
      event.accepted = root.animating
        || Math.abs(current - previous) > 0.01
    }
  }
}
