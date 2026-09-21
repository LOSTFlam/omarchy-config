import QtQuick

Item {
  id: root
  property url mediaSource: ""
  property bool requested: false
  property url implementationSource: Qt.resolvedUrl("DemoVideo.qml")
  readonly property bool playing: loader.item ? loader.item.playing : false
  readonly property bool muted: loader.item ? loader.item.muted : true
  readonly property bool loaded: loader.status === Loader.Ready
  signal playbackFailed(string message)
  function stop() { if (loader.item) loader.item.stop() }
  function togglePlayback() { if (loader.item) loader.item.togglePlayback() }
  function toggleMuted() { if (loader.item) loader.item.muted = !loader.item.muted }
  Loader {
    id: loader
    anchors.fill: parent
    active: root.requested
    asynchronous: true
    source: root.implementationSource
    onLoaded: item.mediaSource = root.mediaSource
    onStatusChanged: if (status === Loader.Error)
      root.playbackFailed("Optional video support is unavailable. Open this demo externally.")
  }
  Connections {
    target: loader.item
    ignoreUnknownSignals: true
    function onPlaybackFailed(message) { root.playbackFailed(message) }
  }
}
