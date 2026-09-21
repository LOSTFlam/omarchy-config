import QtQuick
import QtTest
import "../../ui" as Ui

TestCase {
  id: testCase
  name: "RealMediaDecoder"
  when: windowShown
  width: 160
  height: 90
  Component { id: wrapper; Ui.OptionalVideo { width: 160; height: 90 } }
  function test_local_fixture_plays_muted_and_releases() {
    var source = Qt.createComponent("../../ui/DemoVideo.qml")
    if (source.status === Component.Error) {
      skip("Qt Multimedia is unavailable; OptionalMedia suite verifies external fallback")
      return
    }
    var video = createTemporaryObject(wrapper, testCase, {
      mediaSource: Qt.resolvedUrl("../../test-results/media.webm"), requested: true
    })
    var error = ""
    video.playbackFailed.connect(function(message) { error = message })
    tryCompare(video, "loaded", true)
    tryVerify(function() { return video.playing || Boolean(error) }, 5000)
    compare(error, "", "Generate the codec fixture via tests/run (ffmpeg required)")
    verify(video.muted)
    wait(350)
    var image = grabImage(video)
    verify(image.red(80, 45) > 120, "The decoder must render the red fixture frame")
    video.stop()
    tryCompare(video, "playing", false)
    video.requested = false
    tryCompare(video, "loaded", false)
  }
}
