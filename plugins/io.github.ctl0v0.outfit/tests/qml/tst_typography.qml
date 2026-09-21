import QtQuick
import QtTest
import qs.Commons
import "../.." as Plugin
import "../../ui" as Ui
import "../../ui/InspectorState.js" as InspectorState

TestCase {
  id: testCase
  name: "Typography"
  when: windowShown
  width: 900; height: 1000
  property var savedFont
  Component {
    id: fontComponent
    QtObject {
      property string family: "monospace"
      property real caption: 10
      property real bodySmall: 11
      property real body: 12
      property real heading: 16
      property real subtitle: 14
      property real title: 22
    }
  }
  Component { id: appComponent; Ui.OutfitApp {} }
  Component { id: serviceComponent; Plugin.Service {} }
  Component { id: interestsComponent; Ui.InterestsManager {} }
  Component { id: detailComponent; Ui.PluginDetailPage { presentation: InspectorState.resolve({}, null, {}) } }
  Component { id: diagnosticsComponent; Ui.DiagnosticsPane {} }
  Component { id: indexComponent; Ui.ReadmeIndexStatus {} }
  function init() {
    savedFont = Style.font
    failOnWarning(/(TypeError|ReferenceError|Binding loop|Cannot read property|Cannot assign)/)
  }
  function cleanup() { Style.font = savedFont }
  function texts(item) {
    var result = []
    for (var child of item.children || []) {
      if (child.text !== undefined && child.font !== undefined) result.push(child)
      result = result.concat(texts(child))
    }
    return result
  }
  function test_live_family_and_individual_role_changes() {
    // A QObject models the host's independently notifying font roles. Replacing
    // a whole JS map alone would not catch lost dependencies inside JS helpers.
    var font = createTemporaryObject(fontComponent, testCase)
    Style.font = font
    var service = createTemporaryObject(serviceComponent, testCase)
    service.setupRows = [{id:"example.font",stars:123,likes:0,views:4567,copies:null,score:42,recommendationScore:70}]
    var surfaces = []
    for (var component of [appComponent, interestsComponent, detailComponent, diagnosticsComponent, indexComponent]) {
      var props = {width:760,height:540}
      if (component !== detailComponent) props.service = service
      surfaces.push(createTemporaryObject(component, testCase, props))
    }
    for (var surface of surfaces) {
      verify(surface !== null)
      compare(surface.readingSize, 13)
      compare(surface.supportingSize, 12)
    }
    compare(surfaces[0].browseReadingSize, 12)
    compare(surfaces[0].browseMetadataSize, 11)
    compare(surfaces[0].browseIconSize, 16)
    var initialMetricWidth = surfaces[0].metricMinimums.left
    font.bodySmall = 18
    for (var surface of surfaces) compare(surface.readingSize, 21)
    compare(surfaces[0].browseReadingSize, 12, "Browse body is independent of the enlarged shared reading role")
    compare(surfaces[0].browseMetadataSize, 18)
    compare(surfaces[0].metricMinimums.left, initialMetricWidth)
    font.body = 24
    compare(surfaces[0].browseReadingSize, 24)
    compare(surfaces[0].browseIconSize, 32)
    verify(surfaces[0].metricMinimums.left > initialMetricWidth)
    for (var surface of surfaces) {
      compare(surface.readingSize, 24)
      compare(surface.supportingSize, 24)
    }
    font.caption = 26
    for (var surface of surfaces) compare(surface.supportingSize, 26)
    font.heading = 30
    compare(surfaces[0].valueSize, 30)
    compare(surfaces[2].valueSize, 30)
    var oldMetricWidth = surfaces[0].metricMinimums.left
    font.family = "serif"
    wait(0)
    compare(surfaces[0].fontFamily, "serif")
    verify(Math.abs(surfaces[0].metricMinimums.left - oldMetricWidth) > 1,
      "Changing family alone remeasures metric columns")
    var checked = 0
    for (var surface of surfaces.slice(1))
      for (var text of texts(surface)) {
        compare(text.font.family, "serif", "Live family on " + text.text)
        checked++
      }
    verify(checked > 10, "Exercise rendered copy and controls across all supporting surfaces")
    // Restoring a theme must shrink as well as grow, with no double scaling.
    font.bodySmall = 11; font.body = 12; font.caption = 10; font.heading = 16
    for (var surface of surfaces) compare(surface.readingSize, 13)
    compare(surfaces[0].iconSize, 18)
    compare(surfaces[0].targetSize, 36)
    compare(surfaces[0].browseIconSize, 16)
  }
}
