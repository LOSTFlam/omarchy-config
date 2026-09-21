import QtQuick
import QtTest
import qs.Commons
import "../../ui" as Ui

TestCase {
  id: testCase
  name: "BackgroundActivityGeometry"
  when: windowShown
  property var savedFont: null
  Component {
    id: windowComponent
    Window {
      id: frame
      visible: true
      x: 137; y: 93
      property alias popup: activity
      property alias wrapper: offsetContainer
      property alias anchor: header
      Item {
        id: offsetContainer
        x: 37; y: 41
        width: parent.width - 74
        height: parent.height - 82
        Item { id: header; x:22; y:15; width:parent.width - 44; height:64 }
      }
      Ui.BackgroundActivity {
        id: activity
        parent: offsetContainer
        boundsItem: frame.contentItem
        anchorItem: header
        service: ({canBrowse:true,canManagePlugins:true,inventoryBusy:false,indexingEnabled:true,
          preferences:{readmeEnrichment:true,readmeIndexing:true},indexingBusy:false,preparingSearch:false,
          libraryPrepared:false,busy:false,mutationBusy:false,searchPackFailed:true,searchPackRetryAt:0,
          documentCounts:{total:3464,indexed:3159,processed:3178,pending:286,failed:12,unavailable:7,skipped:286},
          startupActivity:{catalog:{state:"error"},inventory:{state:"error"},hardware:{state:"error"},documentation:{state:"waiting"}},
          measuredProgress:function(value) { return -1 }, retryStartupLane:function(lane) {},setIndexingPaused:function(paused) {}})
      }
    }
  }
  function init() { savedFont = JSON.parse(JSON.stringify(Style.font)) }
  function cleanup() { Style.font = savedFont }
  function visualChild(item, name) {
    if (item.objectName === name) return item
    for (var child of item.children || []) {
      var found = visualChild(child, name)
      if (found) return found
    }
    return null
  }
  // Popup has no mapToItem method: use its actual rendered background Item.
  function mappedPopup(popup, item) {
    var point = popup.background.mapToItem(item, 0, 0)
    return Qt.rect(point.x, point.y, popup.background.width, popup.background.height)
  }
  function contained(frame) {
    var rect = mappedPopup(frame.popup, frame.contentItem)
    verify(rect.x >= -0.5 && rect.y >= -0.5, JSON.stringify(rect))
    verify(rect.x + rect.width <= frame.width + 0.5, JSON.stringify(rect))
    verify(rect.y + rect.height <= frame.height + 0.5, JSON.stringify(rect))
    var global = frame.popup.background.mapToGlobal(0, 0)
    var windowOrigin = frame.contentItem.mapToGlobal(0, 0)
    compare(Math.round(global.x - windowOrigin.x), Math.round(rect.x))
    compare(Math.round(global.y - windowOrigin.y), Math.round(rect.y))
  }
  function visibleControl(control, scroll) {
    var point = control.mapToItem(scroll.contentItem, 0, 0)
    verify(point.x >= -0.5 && point.x + control.width <= scroll.availableWidth + 0.5)
    verify(point.y >= -0.5 && point.y + control.height <= scroll.availableHeight + 0.5,
      "Control must be in the actual clipped viewport: " + JSON.stringify(point))
  }
  function test_mapped_window_bounds_and_footer_keyboard_access_data() {
    return [{tag:"760x540",width:760,height:540,font:12},
      {tag:"1180x760",width:1180,height:760,font:12},
      {tag:"760x540-large-font",width:760,height:540,font:20}]
  }
  function test_mapped_window_bounds_and_footer_keyboard_access(data) {
    Style.font = {family:"monospace",caption:data.font-2,bodySmall:data.font-1,body:data.font,
      heading:data.font+4,subtitle:data.font+2,title:data.font+8}
    var frame = createTemporaryObject(windowComponent, testCase, {width:data.width,height:data.height})
    frame.requestActivate()
    frame.popup.open()
    wait(30)
    contained(frame)
    var scroll = findChild(frame.popup, "activityScroll")
    compare(scroll.availableWidth, scroll.width - scroll.leftPadding - scroll.scrollbarGutter)
    var first = visualChild(frame.popup.contentItem, "activityRetry-catalog")
    first.forceActiveFocus()
    keyClick(Qt.Key_End)
    var close = findChild(frame.popup, "activityClose")
    verify(close.activeFocus)
    visibleControl(close, scroll)
    var pause = findChild(frame.popup, "activityPause")
    pause.forceActiveFocus()
    visibleControl(pause, scroll)
    var retryLibrary = visualChild(frame.popup.contentItem, "activityRetry-documentation")
    retryLibrary.forceActiveFocus()
    visibleControl(retryLibrary, scroll)
    keyClick(Qt.Key_Home)
    verify(first.activeFocus)
    visibleControl(first, scroll)

    // Ancestor/window offsets must not be mistaken for space below the popup.
    frame.wrapper.x += 53
    frame.wrapper.y += 67
    frame.x += 99
    frame.y += 83
    wait(0)
    contained(frame)
    frame.anchor.y = frame.height - 140
    wait(0)
    contained(frame)
    first.forceActiveFocus()
    keyClick(Qt.Key_End)
    verify(close.activeFocus)
    visibleControl(close, scroll)
    close.clicked()
    tryCompare(frame.popup, "visible", false)
    verify(frame.visible)
  }
}
