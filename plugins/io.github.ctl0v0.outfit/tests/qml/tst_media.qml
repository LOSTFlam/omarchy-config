import QtQuick
import QtTest
import "../../ui" as Ui
import "../../ui/MediaPaths.js" as Paths

TestCase {
  id: testCase
  name: "OptionalMedia"
  when: windowShown
  Component { id: component; Ui.OptionalVideo {} }

  function test_private_cache_uri_encoding_and_boundary() {
    var path = "/cache # 雪/(private)'"
    var prefix = Paths.cachePrefix(path)
    compare(prefix, "file:///cache%20%23%20%E9%9B%AA/%28private%29%27/")
    verify(Paths.trustedFile(prefix + "preview-0.png", path, /^preview-[0-3]\.png$/))
    verify(!Paths.trustedFile(prefix + "../secret", path, /^preview-[0-3]\.png$/))
    verify(!Paths.trustedFile("file:///somewhere/preview-0.png", path, /^preview-[0-3]\.png$/))
    compare(Paths.xdg("relative/path", "/home/example", ".cache"), "/home/example/.cache")
  }
  function test_video_is_lazy_muted_and_released_on_stop() {
    var video = createTemporaryObject(component, testCase, {
      implementationSource: Qt.resolvedUrl("fixtures/FakeVideo.qml"), mediaSource: "file:///fictional/demo.webm"
    })
    verify(!video.loaded)
    video.requested = true
    tryCompare(video, "loaded", true)
    verify(video.muted)
    verify(video.playing)
    video.toggleMuted()
    verify(!video.muted)
    video.stop()
    verify(!video.playing)
    video.requested = false
    tryCompare(video, "loaded", false)
    video.requested = true
    tryCompare(video, "loaded", true)
    verify(video.muted)
  }
  function test_missing_optional_module_has_external_fallback() {
    var video = createTemporaryObject(component, testCase, {
      implementationSource: Qt.resolvedUrl("fixtures/MissingOptionalModule.qml")
    })
    var failed = false
    video.playbackFailed.connect(function(message) { failed = message.indexOf("externally") >= 0 })
    video.requested = true
    tryVerify(function() { return failed })
    verify(!video.loaded)
  }
}
