import QtQuick
import QtQuick.Controls as C
import QtTest
import "../.." as Plugin
import "../../ui" as Ui

TestCase {
  id: testCase
  name: "Tooltips"
  when: windowShown
  width: 1600; height: 1000
  Component { id: serviceComponent; Plugin.Service {} }
  Component { id: appComponent; Ui.OutfitApp {} }
  Component {
    id: popupComponent
    C.Popup {
      id: modal
      width: 220; height: 100
      modal: true; focus: true
      closePolicy: C.Popup.CloseOnEscape | C.Popup.CloseOnPressOutside
      contentItem: C.Button { text: "Close"; onClicked: modal.close() }
      onOpened: contentItem.forceActiveFocus()
    }
  }
  Component { id: otherWindowComponent; Window { width: 200; height: 100; transientParent: null } }
  property var service
  property var view
  property var surface
  property var compact
  property var settings
  property int leaveX: 2

  function descendants(item, predicate) {
    var result = []
    for (var child of item.children || []) {
      if (!child.visible) continue
      if (predicate(child)) result.push(child)
      result = result.concat(descendants(child, predicate))
    }
    return result
  }
  function init() {
    failOnWarning(/(TypeError|ReferenceError|Binding loop|Cannot read property|Cannot assign)/)
    service = createTemporaryObject(serviceComponent, testCase)
    service.receiveOutput(JSON.stringify({ok:true,action:"load",generation:service.activeRequest.generation,
      preferences:{watchHardware:false,readmeEnrichment:false,readmeIndexing:false,marketplaceThumbnails:false,services:[]}}))
    service.inventoryReady = true
    var rows = []
    for (var i = 0; i < 24; i++) rows.push({id:"fixture.tip." + i,name:"Tooltip fixture " + i,
      kind:"panel",description:"Pointer and keyboard help",stars:3,likes:2,views:5,copies:1})
    service.setupRows = rows
    view = createTemporaryObject(appComponent, testCase, {service:service})
    view.open(JSON.stringify({setupStage:"browse"}))
    // Acknowledge Process stub launches. Otherwise the real two-second query
    // or startup-scan watchdog inserts an unrelated error banner mid-hover.
    for (var child of service.children)
      if (child.command && child.command.indexOf("--serve") >= 0) child.started()
    var scanWorker = findChild(findChild(service, "backgroundJobs"), "backgroundWorker")
    if (scanWorker.running) scanWorker.started()
    wait(80)
    surface = view.browseCards()[0]
    while (surface.parent) surface = surface.parent
    compact = descendants(surface, function(item) { return item.accessibleLabel === "Browse view: Compact" })[0]
    settings = descendants(surface, function(item) { return item.accessibleLabel === "Settings" })[0]
    verify(compact && settings)
    // The native Ui.Button explicitly enables MouseArea hover. Our C.Button
    // stub inherits a platform default, which is false in bare offscreen CI.
    // Match the native input contract before exercising real pointer events.
    compact.hoverEnabled = true
    surface.Window.window.requestActivate()
    tryCompare(surface.Window.window, "active", true)
    leave()
    view.dismissTooltips()
  }
  function cleanup() { if (view) view.close() }
  function leave() { leaveX = leaveX === 2 ? 3 : 2; mouseMove(surface, leaveX, surface.height - 2); wait(30) }
  function hover(item) { mouseMove(item, item.width / 2, item.height / 2) }
  function shown(text, context) {
    tryVerify(function() { return view.activeHelpTip !== null && view.activeHelpTip.visible
      && view.activeHelpTip.helpText.indexOf(text) >= 0 }, 1200, (context || "Visible help") + ": " + text)
    return view.activeHelpTip
  }
  function hidden() { tryCompare(view, "activeHelpTip", null); wait(400); compare(view.activeHelpTip, null) }
  function enterMetricHelp(card) {
    card.forceActiveFocus()
    keyClick(Qt.Key_F2)
    for (var i = 0; i < 8 && view.keyboardFocus.metric === undefined; i++) keyClick(Qt.Key_Right)
    verify(view.keyboardFocus.metric !== undefined, "F2/arrows reach a metric information target")
    return view.keyboardFocus
  }

  function test_mouse_click_leave_and_unchanged_focus_rehover() {
    hover(compact)
    shown("Browse view: Compact")
    mouseClick(compact, compact.width / 2, compact.height / 2)
    compare(service.browseDensity, "compact", "Passive handlers do not take button clicks")
    verify(compact.activeFocus, "Mouse click gives the button focus")
    // The host calls forceActiveFocus() without a reason, unlike the Control
    // stub's MouseFocusReason. Reproduce that exact focus path as well.
    compact.forceActiveFocus()
    verify(compact.activeFocus)
    leave()
    hidden()
    verify(compact.activeFocus, "Help dismissal must not steal button focus")
    hover(compact)
    shown("Browse view: Compact")
    leave()
    hidden()
  }
  function test_programmatic_header_focus_does_not_request_help() {
    compact.forceActiveFocus()
    hidden()
    settings.forceActiveFocus(Qt.OtherFocusReason)
    hidden()
  }
  function test_keyboard_toolbar_tab_arrows_and_rearm() {
    view.focusResults()
    keyClick(Qt.Key_F6)
    tryVerify(function() { return settings.activeFocus })
    var oldTip = shown("Settings")
    keyClick(Qt.Key_Tab)
    shown("Close Outfit")
    verify(!oldTip.visible, "Focus change dismisses the previous target")
    keyClick(Qt.Key_Tab, Qt.ShiftModifier)
    shown("Settings")
    keyClick(Qt.Key_Escape)
    hidden()
    verify(view.opened)
    keyClick(Qt.Key_Tab)
    shown("Close Outfit")
    compact.forceActiveFocus()
    keyClick(Qt.Key_Right)
    shown("Browse view: Dense")
    view.dismissTooltips()
    hidden()
    keyClick(Qt.Key_Left)
    shown("Browse view: Compact")
    // Pointer movement ends keyboard help even though keyboard focus remains.
    leave()
    hidden()
    verify(compact.activeFocus)
  }
  function test_f2_metric_focus_pointer_and_rearm() {
    var card = view.browseCards()[0]
    var metric = enterMetricHelp(card)
    var tip = shown(view.metricHelp(metric.metric), "F2 enters metrics")
    keyClick(Qt.Key_Escape)
    hidden()
    verify(metric.activeFocus)
    keyClick(Qt.Key_Right)
    shown(view.metricHelp(view.keyboardFocus.metric), "Arrow selects next metric")
    verify(!tip.visible)
    leave()
    hidden()
    hover(metric)
    shown(view.metricHelp(metric.metric), "Hover after keyboard dismissal")
    compare(service.error, "", "The fixture worker must not fail to launch during pointer checks")
    leave()
    hidden()
    enterMetricHelp(card)
    shown(view.metricHelp(view.keyboardFocus.metric), "F2 rearms after pointer leave")
  }
  function test_explicit_metric_click_lifecycle_data() {
    return ["leave", "outside", "scroll", "wheel", "view", "density", "escape", "inactive"].map(function(change) {
      return {tag:change, change:change}
    })
  }
  function test_explicit_metric_click_lifecycle(data) {
    var card = view.browseCards()[0]
    var metric = enterMetricHelp(card)
    shown(view.metricHelp(metric.metric))
    // Pointer activation while the metric keeps keyboard focus exercises the
    // sticky-focus regression as well as the explicit click request.
    hover(metric)
    mouseClick(metric, metric.width / 2, metric.height / 2)
    var tip = shown(view.metricHelp(metric.metric))
    verify(tip.clickedHelp && !tip.keyboardHelp)
    compare(view.setupDetailId, "")
    if (data.change === "leave") leave()
    else if (data.change === "outside") mouseClick(surface, 2, surface.height - 2)
    else if (data.change === "scroll") view.currentScroll().contentItem.contentY += 40
    else if (data.change === "wheel") mouseWheel(metric, metric.width / 2, metric.height / 2, 0, -120)
    else if (data.change === "view") view.chooseWorkspace("browse")
    else if (data.change === "density") view.chooseDensity("compact")
    else if (data.change === "escape") keyClick(Qt.Key_Escape)
    else {
      var other = createTemporaryObject(otherWindowComponent, testCase)
      other.show()
      other.requestActivate()
      tryCompare(surface.Window.window, "active", false)
      hidden()
      surface.Window.window.requestActivate()
      tryCompare(surface.Window.window, "active", true)
    }
    hidden()
    verify(!tip.clickedHelp, "Dismissal clears explicit click state")
    compare(view.setupDetailId, "")
    leave()
    view.currentScroll().contentItem.contentY = 0
    wait(220)
    metric = descendants(view.browseCards()[0], function(item) { return item.metric === "stars" })[0]
    hover(metric)
    shown(view.metricHelp(metric.metric))
    leave()
    hidden()
    // A new click rearms even after Escape with no intervening hover exit.
    mouseClick(metric, metric.width / 2, metric.height / 2)
    shown(view.metricHelp(metric.metric))
    view.dismissTooltips()
    hidden()
    mouseClick(metric, metric.width / 2, metric.height / 2)
    shown(view.metricHelp(metric.metric))
    leave()
    hidden()
  }
  function test_scroll_density_dismiss_until_fresh_hover_data() {
    return [{tag:"scroll",change:"scroll"}, {tag:"density",change:"density"}, {tag:"view",change:"view"}]
  }
  function test_scroll_density_dismiss_until_fresh_hover(data) {
    hover(compact)
    shown("Browse view: Compact")
    if (data.change === "scroll") view.currentScroll().contentItem.contentY += 40
    else if (data.change === "density") view.chooseDensity("dense")
    else view.chooseWorkspace("browse")
    hidden()
    leave()
    hover(compact)
    shown("Browse view: Compact")
  }
  function test_wheel_dismisses_without_consuming_scroll() {
    hover(compact)
    shown("Browse view: Compact")
    mouseWheel(compact, compact.width / 2, compact.height / 2, 0, -120)
    hidden()
    leave()
    hover(compact)
    shown("Browse view: Compact")
    var scroll = view.currentScroll()
    var y = scroll.contentItem.contentY
    mouseWheel(scroll, scroll.width / 2, scroll.height / 2, 0, -120)
    tryVerify(function() { return scroll.contentItem.contentY > y }, 1000, "Wheel still reaches Browse")
    hidden()
  }
  function test_window_inactive_and_close() {
    hover(compact)
    shown("Browse view: Compact")
    var other = createTemporaryObject(otherWindowComponent, testCase)
    other.show()
    wait(30)
    other.requestActivate()
    tryCompare(surface.Window.window, "active", false)
    hidden()
    surface.Window.window.requestActivate()
    tryCompare(surface.Window.window, "active", true)
    hidden()
    leave()
    hover(compact)
    shown("Browse view: Compact")
    view.close()
    hidden()
  }
  function test_modal_escape_and_pointer_close_keep_priority() {
    view.focusResults()
    keyClick(Qt.Key_F6)
    shown("Settings")
    var popup = createTemporaryObject(popupComponent, settings)
    popup.open()
    tryCompare(popup, "opened", true)
    hidden()
    keyClick(Qt.Key_Tab)
    keyClick(Qt.Key_Escape)
    tryCompare(popup, "visible", false)
    verify(view.opened, "Escape closes only the modal")
    popup.open()
    tryCompare(popup, "opened", true)
    mouseClick(popup.contentItem, popup.contentItem.width / 2, popup.contentItem.height / 2)
    tryCompare(popup, "visible", false)
    verify(view.opened, "Pointer observers preserve modal button delivery")
  }
}
