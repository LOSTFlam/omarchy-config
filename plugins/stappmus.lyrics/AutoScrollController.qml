import QtQuick

// Time-based rather than frame-based: changing refresh rate does not change
// reading speed. boundsHelper is the same FastScrollHandler used for manual
// scrolling, so wheel and automatic movement agree on the exact limits.
Item {
  id: root

  required property var flickable
  required property var boundsHelper
  property real linesPerSecond: 1
  property real pixelsPerLine: 28
  property bool running: false
  property bool clockEnabled: true
  property double lastTickMs: 0
  property real maximumFrameMs: 250
  property bool playbackSeekPending: false
  property int playbackSeekAttempts: 0
  property int maximumPlaybackSeekAttempts: 12
  property real pendingPositionSeconds: 0
  property real pendingDurationSeconds: 0
  property real playbackContextViewportFraction: 0.4
  property real pendingContextViewportFraction: playbackContextViewportFraction

  signal reachedEnd()

  visible: false
  width: 0
  height: 0

  function maximumContentY() {
    return boundsHelper.boundedContentY(Number.MAX_VALUE)
  }

  function playbackFraction(positionSeconds, durationSeconds) {
    var duration = Number(durationSeconds)
    if (!isFinite(duration) || duration <= 0) return 0
    var position = Number(positionSeconds)
    if (!isFinite(position)) position = 0
    return Math.max(0, Math.min(1, Math.max(0, position) / duration))
  }

  function contextFraction(value) {
    var fraction = Number(value)
    if (!isFinite(fraction)) fraction = playbackContextViewportFraction
    return Math.max(0, Math.min(1, fraction))
  }

  // Express the visual context above the estimated current line as time. A
  // dense lyric sheet has more rendered pixels per second, so it needs fewer
  // seconds of lead; a sparse one needs more. This keeps the current line at a
  // stable place in the viewport instead of letting long lyrics push it down.
  function playbackSafetySeconds(durationSeconds, contentHeight,
      viewportHeight, contextViewportFraction) {
    var duration = Number(durationSeconds)
    var content = Number(contentHeight)
    var viewport = Number(viewportHeight)
    if (!isFinite(duration) || duration <= 0 || !isFinite(content)
        || content <= 0 || !isFinite(viewport) || viewport <= 0) return 0
    var contextPixels = Math.min(content, viewport
      * contextFraction(contextViewportFraction))
    return duration * contextPixels / content
  }

  function playbackTargetContentY(positionSeconds, durationSeconds,
      contextViewportFraction) {
    var minimum = Number(flickable.originY) || 0
    var content = Math.max(0, Number(flickable.contentHeight) || 0)
    var viewport = Math.max(0, Number(flickable.height) || 0)
    var estimatedLineY = content
      * playbackFraction(positionSeconds, durationSeconds)
    var contextPixels = viewport * contextFraction(contextViewportFraction)
    return boundsHelper.boundedContentY(minimum + estimatedLineY - contextPixels)
  }

  function seekToPlaybackPosition(positionSeconds, durationSeconds,
      contextViewportFraction) {
    pause()
    pendingPositionSeconds = Number(positionSeconds) || 0
    pendingDurationSeconds = Number(durationSeconds) || 0
    pendingContextViewportFraction = contextFraction(contextViewportFraction)
    playbackSeekAttempts = 0
    playbackSeekPending = true
    return applyPlaybackSeek()
  }

  function applyPlaybackSeek() {
    if (!playbackSeekPending) return flickable.contentY
    var minimum = Number(flickable.originY) || 0
    var maximum = maximumContentY()
    var fraction = playbackFraction(pendingPositionSeconds,
      pendingDurationSeconds)
    if (fraction > 0 && maximum <= minimum
        && playbackSeekAttempts < maximumPlaybackSeekAttempts) {
      playbackSeekAttempts++
      deferredPlaybackSeek.restart()
      return flickable.contentY
    }
    stopManualMotion()
    flickable.contentY = playbackTargetContentY(pendingPositionSeconds,
      pendingDurationSeconds, pendingContextViewportFraction)
    playbackSeekPending = false
    return flickable.contentY
  }

  function stopManualMotion() {
    if (flickable && flickable.cancelFlick) flickable.cancelFlick()
    if (boundsHelper && boundsHelper.stopAnimation) boundsHelper.stopAnimation()
  }

  function start() {
    playbackSeekPending = false
    deferredPlaybackSeek.stop()
    if (!flickable || maximumContentY() <= (Number(flickable.originY) || 0)) {
      running = false
      return false
    }
    stopManualMotion()
    lastTickMs = Date.now()
    running = true
    return true
  }

  function pause() {
    running = false
    lastTickMs = 0
    playbackSeekPending = false
    deferredPlaybackSeek.stop()
  }

  function advanceTo(nowMs) {
    if (!running) return flickable.contentY
    var now = Number(nowMs) || 0
    if (lastTickMs <= 0) {
      lastTickMs = now
      return flickable.contentY
    }
    var elapsed = Math.max(0, Math.min(maximumFrameMs, now - lastTickMs))
    lastTickMs = now
    if (elapsed <= 0) return flickable.contentY

    if (flickable.flicking || flickable.dragging) flickable.cancelFlick()
    var maximum = maximumContentY()
    var next = boundsHelper.boundedContentY(flickable.contentY
      + Math.max(0, Number(linesPerSecond) || 0)
        * Math.max(0, Number(pixelsPerLine) || 0) * elapsed / 1000)
    flickable.contentY = next
    if (next >= maximum - 0.01) {
      pause()
      reachedEnd()
    }
    return next
  }

  // Display-clock ticks keep subpixel motion continuous on high-refresh
  // screens. Distance is still computed from elapsed time, not frame count.
  FrameAnimation {
    running: root.running && root.clockEnabled
    onTriggered: root.advanceTo(Date.now())
  }

  Timer {
    id: deferredPlaybackSeek
    interval: 16
    repeat: false
    onTriggered: root.applyPlaybackSeek()
  }

  Connections {
    target: root.flickable
    function onContentHeightChanged() {
      if (root.playbackSeekPending) Qt.callLater(root.applyPlaybackSeek)
    }
    function onHeightChanged() {
      if (root.playbackSeekPending) Qt.callLater(root.applyPlaybackSeek)
    }
  }
}
