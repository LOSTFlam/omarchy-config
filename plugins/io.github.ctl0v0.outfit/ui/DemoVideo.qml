import QtQuick
import QtMultimedia

Item {
  id: root
  property url mediaSource: ""
  readonly property bool playing: video.playbackState === MediaPlayer.PlayingState
  property alias muted: video.muted
  signal playbackFailed(string message)
  function stop() { video.stop(); video.source = "" }
  function togglePlayback() { playing ? video.pause() : video.play() }
  Video {
    id: video
    anchors.fill: parent
    source: root.mediaSource
    autoPlay: true
    muted: true
    fillMode: VideoOutput.PreserveAspectFit
    onErrorOccurred: root.playbackFailed("Inline playback is unavailable for this demo. Open it externally.")
  }
  Component.onDestruction: video.stop()
}
