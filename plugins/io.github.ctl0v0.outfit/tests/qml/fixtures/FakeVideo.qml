import QtQuick
Item {
  property url mediaSource: ""
  property bool muted: true
  property bool playing: Boolean(mediaSource)
  signal playbackFailed(string message)
  function stop() { playing = false }
  function togglePlayback() { playing = !playing }
}
