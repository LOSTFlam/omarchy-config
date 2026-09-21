import QtQuick
import QtQuick.Controls as C
import QtTest
import "../../ui" as Ui

TestCase {
  name: "ContentScrollGutter"
  when: windowShown
  width: 600; height: 500
  Component {
    id: scrollComponent
    Ui.ContentScrollView {
      id: scrollRoot
      width: 320; height: 200
      readonly property var verticalBar: C.ScrollBar.vertical
      readonly property int horizontalPolicy: C.ScrollBar.horizontal.policy
      property real bodyHeight: 100
      Rectangle { width: scrollRoot.availableWidth; height: scrollRoot.bodyHeight }
    }
  }
  function test_stable_gutter_and_bar_bounds_data() {
    return [{tag:"normal", width:320}, {tag:"narrow", width:180}]
  }
  function test_stable_gutter_and_bar_bounds(data) {
    var scroll = createTemporaryObject(scrollComponent, testCase, {width:data.width})
    verify(scroll !== null)
    wait(0)
    var width = scroll.availableWidth
    compare(width, scroll.width - scroll.leftPadding - scroll.scrollbarGutter)
    compare(scroll.horizontalPolicy, C.ScrollBar.AlwaysOff)
    for (var height of [100, 1000, 100]) {
      scroll.bodyHeight = height
      wait(0)
      compare(scroll.availableWidth, width)
      var bar = scroll.verticalBar
      var point = bar.mapToItem(scroll, 0, 0)
      verify(point.x >= scroll.leftPadding + width + scroll.scrollbarGap - 0.1)
      verify(point.x + bar.width <= scroll.width + 0.1)
      compare(scroll.contentWidth, width)
    }
  }
  id: testCase
}
