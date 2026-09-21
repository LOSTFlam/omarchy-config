import QtQuick
import QtQuick.Window
import QtQuick.Controls as C
import QtTest
import qs.Commons
import "../../demo" as Demo
import "../../ui/InspectorState.js" as InspectorState
import "../../ui/Typography.js" as Typography

// Exercise the real page through its fixture-only owner. No Service, shell,
// registry, backend, or native-action mock is supplied to either component.
TestCase {
  id: testCase
  name: "DetailPage"
  when: windowShown
  visible: true
  width: 1200
  height: 800

  Component { id: prototypeComponent; Demo.DetailPrototype {} }
  Component { id: spyComponent; SignalSpy {} }
  Component { id: otherWindowComponent; Window { width: 200; height: 100; transientParent: null } }
  Component { id: editorComponent; C.TextField { text: "Editable text"; width: 200 } }
  Component { id: dropdownComponent; C.ComboBox { model: ["One", "Two", "Three"]; width: 200 } }
  SignalSpy { id: clickSpy; signalName: "clicked" }
  FontMetrics { id: toggleMetrics; font.family: Style.font.family; font.pixelSize: Typography.reading(Style.font); font.bold: true }
  readonly property var originalFont: ({family:"monospace",caption:12,bodySmall:14,body:16,subtitle:18,title:22})
  function cleanup() { Style.font = originalFont }
  function test_theme_font_changes_preserve_controls_data() {
    return [{tag:"minimum",width:760,height:540}, {tag:"tall",width:900,height:1000}]
  }
  function test_theme_font_changes_preserve_controls(data) {
    Style.font = {family:"monospace",caption:10,bodySmall:11,body:12,heading:16,subtitle:14,title:22}
    var driver = make("available", data)
    var surface = page(driver)
    compare(surface.readingSize, 13)
    checkControls(driver)
    var info = child(driver, "detailMetric.stars")
    var size = info.width
    Style.font = {family:"serif",caption:14,bodySmall:18,body:20,heading:26,subtitle:24,title:30}
    settle()
    verify(info.width > size, "Metadata target grows with the reading font")
    checkControls(driver)
    noTextOverflow(surface)
    compare(child(driver, "detailInstallEnabled").titleSize, surface.readingSize)
    reveal(driver, info)
    info.forceActiveFocus(Qt.TabFocusReason)
    var tip = child(info, "detailMetricTip.stars")
    tryCompare(tip, "visible", true)
    within(info, scroll(driver), "Enlarged-font keyboard information target")
  }

  function init() {
    failOnWarning(/(TypeError|ReferenceError|Binding loop|Cannot read property|Cannot call method|Cannot assign)/)
  }

  function settle() {
    // A binding can change a Flow or popup's size before its children receive
    // their final coordinates. Flush deferred work, then wait for *all* items
    // in the window (including popup overlays), not just the clicked control.
    wait(0)
    verify(waitForPolish(testCase.Window.window), "Window layout did not settle")
  }

  function sizes() {
    return [{tag:"wide", width:1180, height:740}, {tag:"compact", width:728, height:430}]
  }

  function responsiveSizes() {
    var rows = []
    ;[[760,1000], [900,1000], [999,1100], [1000,700], [760,540]].forEach(function(size) {
      // Test the component breakpoint itself and the smaller area available
      // after the window's outer gutters and header/navigation allowance.
      rows.push({tag:size.join("x") + "-page", width:Style.space(size[0]), height:Style.space(size[1])})
      rows.push({tag:size.join("x") + "-inset", width:Style.space(size[0] - 32), height:Style.space(size[1] - 110)})
    })
    return rows
  }

  function make(state, size) {
    size = size || sizes()[1]
    var driver = createTemporaryObject(prototypeComponent, testCase,
      {initialState:state, width:size.width, height:size.height})
    verify(driver !== null, "Fixture must load without a Service or host context")
    settle()
    verify(child(driver, "pluginDetailPage") !== null)
    driver.Window.window.requestActivate()
    tryCompare(driver.Window.window, "active", true)
    settle()
    driver.takeFocus()
    return driver
  }

  function child(owner, name) {
    var result = findChild(owner, name)
    if (!result) result = visualChild(owner, name)
    verify(result !== null, "Missing item: " + name)
    return result
  }

  function visualChild(owner, name) {
    if (owner.objectName === name) return owner
    var children = owner.children || []
    for (var i = 0; i < children.length; ++i) {
      var result = visualChild(children[i], name)
      if (result) return result
    }
    return null
  }

  function page(driver) { return child(driver, "pluginDetailPage") }
  function scroll(driver) { return child(driver, "detailContentScroll") }

  function within(item, container, label, horizontalOnly) {
    var point = item.mapToItem(container, 0, 0)
    var bounds = label + ": [" + point.x + ", " + point.y + ", " + item.width + ", " + item.height
      + "] in [" + container.width + ", " + container.height + "]"
    verify(item.width > 0 && item.height > 0, "Nonpositive size: " + bounds)
    verify(point.x >= -1 && point.x + item.width <= container.width + 1, "Horizontal overflow: " + bounds)
    if (!horizontalOnly)
      verify(point.y >= -1 && point.y + item.height <= container.height + 1, "Vertical overflow: " + bounds)
  }

  function checkControls(driver) {
    var surface = page(driver)
    var controls = child(driver, "detailControls")
    within(controls, surface, "control tray")
    var names = ["detailLocalState", "detailPrimary", "detailBatch", "detailEnabled", "detailInstallEnabled",
      "detailPosition.left", "detailPosition.center", "detailPosition.right", "detailUninstall"]
    for (var i = 0; i < names.length; ++i) {
      var item = child(driver, names[i])
      if (!item.visible) continue
      within(item, surface, names[i])
      within(item, controls, names[i] + " in tray")
      var a = item.mapToItem(controls, 0, 0)
      for (var k = 0; k < i; ++k) {
        var other = child(driver, names[k])
        if (!other.visible) continue
        var b = other.mapToItem(controls, 0, 0)
        verify(a.x + item.width <= b.x + 1 || b.x + other.width <= a.x + 1
          || a.y + item.height <= b.y + 1 || b.y + other.height <= a.y + 1,
          names[i] + " overlaps " + names[k])
      }
    }
    for (var j = 0; j < 3; ++j) {
      var name = ["detailBack", "detailSource", "detailMarketplace"][j]
      within(child(driver, name), surface, name)
    }
  }

  function noTextOverflow(item) {
    if (!item.visible) return
    // Text.paintedWidth measures what is actually drawn, including labels in
    // fixed-width position buttons. Do not equate elided text with overflow.
    if (item.paintedWidth !== undefined && item.text !== undefined)
      verify(item.paintedWidth <= item.width + 1,
        "Text overflows its item: " + item.text + " (" + item.paintedWidth + " > " + item.width + ")")
    var children = item.children || []
    for (var i = 0; i < children.length; ++i) noTextOverflow(children[i])
  }

  function reveal(driver, item) {
    settle()
    var view = scroll(driver)
    var recommendation = child(driver, "detailRecommendationScroll")
    for (var ancestor = item.parent; ancestor; ancestor = ancestor.parent)
      if (ancestor === recommendation.contentItem) { view = recommendation; break }
    var flick = view.contentItem
    var position = item.mapToItem(flick, 0, 0)
    var target = flick.contentY + position.y - Math.max(0, (flick.height - item.height) / 2)
    flick.contentY = Math.max(0, Math.min(target, flick.contentHeight - flick.height))
    settle()
    within(item, view, item.objectName || item.text)
  }

  function click(item) {
    settle()
    verify(item.visible && item.enabled, "Action must be visible and enabled: " + (item.objectName || item.text))
    clickSpy.target = item
    clickSpy.clear()
    mouseClick(item, item.width / 2, item.height / 2)
    compare(clickSpy.count, 1, "Pointer click did not reach " + (item.objectName || item.text))
    settle()
  }

  function clickBody(driver, name) {
    var item = child(driver, name)
    reveal(driver, item)
    click(item)
  }

  function clickPageAction(driver, item) {
    var ancestor = item
    while (ancestor && ancestor !== scroll(driver)) ancestor = ancestor.parent
    if (ancestor) reveal(driver, item)
    else within(item, page(driver), item.objectName || item.text)
    click(item)
  }

  function actionWithText(item, text) {
    if (item.text === text && item.clicked !== undefined) return item
    var children = item.children || []
    for (var i = 0; i < children.length; ++i) {
      var found = actionWithText(children[i], text)
      if (found) return found
    }
    return null
  }

  function texts(item) {
    var values = item.text !== undefined ? [String(item.text)] : []
    var children = item.children || []
    for (var i = 0; i < children.length; ++i) values = values.concat(texts(children[i]))
    return values
  }

  function waitForOperation(driver) {
    verify(driver.presentation.pending, "Mock operation must start before waiting for completion")
    tryVerify(function() { return !driver.presentation.pending }, 3000, "Mock operation should finish")
    settle()
  }

  function test_all_states_fit_and_controls_survive_body_scroll_data() {
    var states = ["available", "installed", "disabled", "service", "pending", "failed",
      "manual", "replacement", "long", "missing"]
    var rows = []
    sizes().concat(responsiveSizes()).forEach(function(size) {
      states.forEach(function(state) {
        rows.push({tag:size.tag + "-" + state, state:state, width:size.width, height:size.height})
      })
    })
    return rows
  }

  function test_all_states_fit_and_controls_survive_body_scroll(data) {
    var driver = make(data.state, data)
    var surface = page(driver)
    var view = scroll(driver)
    compare(surface.width, data.width)
    compare(surface.height, data.height)
    verify(view.height >= 48, "Body must retain room to read at least three text lines; height=" + view.height)
    checkControls(driver)
    noTextOverflow(surface)
    var batch = child(driver, "detailBatch")
    verify(batch.bordered, "Batch action must have an outline in every layout")
    if (surface.compact) {
      var state = child(driver, "detailLocalState")
      var primary = child(driver, "detailPrimary")
      if (primary.visible) {
        var statusPoint = state.mapToItem(surface, 0, 0)
        var primaryPoint = primary.mapToItem(surface, 0, 0)
        compare(primaryPoint.x, statusPoint.x, "Status belongs to the action column")
        var actionGap = Style.space(surface.shortWindow ? 6 : 8)
        fuzzyCompare(primaryPoint.y - statusPoint.y - state.height, actionGap, 1)
        if (batch.visible) {
          var batchPoint = batch.mapToItem(surface, 0, 0)
          compare(batchPoint.x, primaryPoint.x)
          compare(batch.width, primary.width)
          fuzzyCompare(batchPoint.y - primaryPoint.y - primary.height, actionGap, 1)
        }
        var toggle = child(driver, surface.installOptions ? "detailInstallEnabled" : "detailEnabled")
        var placement = child(driver, "detailPlacement")
        if (toggle.visible && placement.visible) {
          var togglePoint = toggle.mapToItem(surface, 0, 0)
          var placementPoint = placement.mapToItem(surface, 0, 0)
          compare(placementPoint.x, togglePoint.x, "Placement belongs directly below enable")
          compare(placement.width, toggle.width)
          compare(togglePoint.y, statusPoint.y, "The two functional sections start together")
          verify(placementPoint.y >= togglePoint.y + toggle.height)
          fuzzyCompare(statusPoint.x - togglePoint.x - toggle.width,
            Style.space(surface.shortWindow ? 12 : 20), 1, "Bounded gap between settings and actions")
        }
      }
    }
    ;["detailEnabled", "detailInstallEnabled"].forEach(function(name) {
      var toggle = child(driver, name)
      if (!toggle.visible) return
      // The portable CheckBox stub does not model native Toggle chrome.
      // Reserve the real host's track + three 12px paddings + borders too.
      verify(toggle.width >= toggleMetrics.advanceWidth(toggle.label) + Style.space(80),
        "Native toggle label budget: " + name + " width=" + toggle.width + " minimum=" + toggle.minimumLabelWidth
          + " label=" + toggleMetrics.advanceWidth(toggle.label) + " chrome=" + surface.toggleChromeWidth)
    })
    verify(!surface.matchingExpanded)
    var metrics = child(driver, "detailMetrics")
    verify(metrics.visible, "Metrics are independent of the matching disclosure")
    var keys = ["stars", "likes", "views", "copies", "recommended", "fit"]
    for (var i = 0; i < keys.length; ++i)
      within(child(driver, "detailMetric." + keys[i]), view, keys[i], true)
    within(child(driver, "detailScores"), view, "setup scores", true)
    verify(view.contentItem.contentWidth <= view.availableWidth + 1, "Body must not scroll horizontally")
    var controls = child(driver, "detailControls")
    if (data.tag === "compact-available") {
      compare(view.contentItem.contentY, 0, "Check the opening view before any body scroll")
      var preview = child(driver, "detailPreview")
      verify(preview.visible)
      within(preview, view, "initial preview image")
      var imageBottom = preview.mapToItem(surface, 0, preview.height).y
      verify(imageBottom <= controls.mapToItem(surface, 0, 0).y,
        "The initial preview image must be entirely above the controls")
      within(metrics, view, "metrics area", true)
    }
    var before = controls.mapToItem(surface, 0, 0)
    view.contentItem.contentY = Math.max(0, view.contentItem.contentHeight - view.height)
    wait(0)
    var after = controls.mapToItem(surface, 0, 0)
    compare(after.x, before.x)
    compare(after.y, before.y)
    checkControls(driver)
    noTextOverflow(surface)
  }

  function test_metrics_are_readable_with_matching_collapsed_data() { return sizes() }
  function test_metrics_are_readable_with_matching_collapsed(data) {
    var driver = make("long", data)
    var metrics = child(driver, "detailMetrics")
    verify(!page(driver).matchingExpanded)
    verify(!child(driver, "detailMatchingContent").visible)
    verify(metrics.color.a > 0, "Metrics need a distinct theme-aware background")
    var expected = {stars:"1,234,567,890", likes:"—", views:"9,876,543,210", copies:"2,147,483,647", recommended:"94", fit:"92"}
    for (var key in expected) {
      var metric = child(driver, "detailMetric." + key)
      reveal(driver, metric)
      within(metric, scroll(driver), key)
      within(metric, metrics, key + " inside surface")
      var point = metric.mapToItem(metrics, 0, 0)
      verify(point.x >= metrics.padding - 1 && point.y >= metrics.padding - 1)
      verify(point.x + metric.width <= metrics.width - metrics.padding + 1)
      verify(point.y + metric.height <= metrics.height - metrics.padding + 1)
      verify(texts(metric).indexOf(expected[key]) >= 0, "Missing readable count for " + key)
      verify(metric.Accessible.name.indexOf(expected[key]) >= 0, "Full count must be accessible")
    }
    var scores = child(driver, "detailScores")
    verify(scores.visible)
  }

  function test_metrics_share_one_content_sized_flow_data() {
    return [{tag:"wide",width:1180,height:740,state:"available",oneRow:true},
      {tag:"compact",width:728,height:430,state:"available",oneRow:false},
      {tag:"compact-tall-one-row",width:900,height:1000,state:"available",oneRow:true},
      {tag:"wide-large-font",width:1180,height:740,state:"available",oneRow:false,largeFont:true},
      {tag:"wide-full-counts",width:1180,height:740,state:"long",oneRow:false},
      {tag:"compact-full-counts",width:728,height:430,state:"long",oneRow:false}]
  }
  function test_metrics_share_one_content_sized_flow(data) {
    if (data.largeFont) Style.font = {family:"monospace",caption:14,bodySmall:18,body:20,heading:26,subtitle:24,title:30}
    var driver = make(data.state, data)
    var flow = child(driver, "detailScores")
    compare(flow.flow, Flow.LeftToRight)
    var keys = ["likes", "stars", "views", "copies", "recommended", "fit"]
    var x = 0, y = 0, rowHeight = 0, icons = 0
    for (var i = 0; i < keys.length; i++) {
      var metric = child(driver, "detailMetric." + keys[i])
      compare(metric.parent, flow, "All six metrics must be direct children of one Flow")
      compare(metric.width, metric.implicitWidth, "Never squeeze a metric to fit")
      if (x > 0 && x + metric.width > flow.width) {
        x = 0
        y += rowHeight + flow.spacing
        rowHeight = 0
      }
      compare(metric.x, x, "Compact content-sized horizontal spacing")
      compare(metric.y, y, "Wrap only when the actual text/font requires it")
      x += metric.width + flow.spacing
      rowHeight = Math.max(rowHeight, metric.height)
      var info = child(driver, "detailMetricInfo." + keys[i])
      compare(info.visible, i >= 4, "Only Recommended and Hardware fit retain info icons")
      if (info.visible) icons++
      verify(!info.activeFocusOnTab, "One keyboard target per entire metric")
      compare(metric.Accessible.name, metric.modelData.label + " " + page(driver).count(metric.modelData.value))
      compare(info.item !== null, i >= 4, "Only the score icons are instantiated")
      var value = child(metric, "detailMetricValue." + keys[i])
      compare(value.color, i >= 4 ? Color.accent : Color.foreground, "Scores retain semantic accent")
      compare(value.text, page(driver).count(metric.modelData.value))
      compare(value.font.pixelSize, page(driver).valueSize, "Use the theme font without shrinking")
      var label = child(metric, "detailMetricLabel." + keys[i])
      compare(label.text, metric.modelData.label, "Full labels are visible, not abbreviated")
      verify(!label.truncated && !value.truncated)
    }
    compare(icons, 2)
    compare(y === 0, data.oneRow, "Six metrics on one row at wide size; content-driven wrapping otherwise")
    noTextOverflow(child(driver, "detailMetrics"))
  }

  function test_metric_flow_wraps_at_measured_width_boundary() {
    var driver = make("available", {width:900,height:1000})
    var flow = child(driver, "detailScores")
    var metrics = ["stars", "likes", "views", "copies", "recommended", "fit"].map(function(key) {
      return child(driver, "detailMetric." + key)
    })
    var required = metrics.reduce(function(sum, metric) { return sum + metric.width }, 5 * flow.spacing)
    var chrome = driver.width - flow.width
    driver.width = required + chrome - 1
    settle()
    verify(metrics[5].y > 0, "One pixel short requires wrapping the last metric")
    driver.width += 1
    settle()
    metrics.forEach(function(metric) { compare(metric.y, 0, "Exact content width fits all six") })
  }

  function test_every_metric_has_hover_click_and_keyboard_help_data() { return sizes() }
  function test_every_metric_has_hover_click_and_keyboard_help(data) {
    var driver = make("available", data)
    var back = createTemporaryObject(spyComponent, testCase, {target:driver, signalName:"backRequested"})
    var keys = ["stars", "likes", "views", "copies", "recommended", "fit"]
    var meanings = ["GitHub stars", "marketplace hearts", "listing visits", "does not confirm an installation",
      "GitHub popularity and local hardware fit", "heuristic score from 0 to 100"]
    for (var i = 0; i < keys.length; ++i) {
      var info = child(driver, "detailMetric." + keys[i])
      var tip = child(info, "detailMetricTip." + keys[i])
      reveal(driver, info)
      mouseMove(info, 2, 2) // The value, well away from any score info icon.
      tryCompare(tip, "opened", true)
      var popupPosition = tip.parent.mapToItem(page(driver), tip.x, tip.y)
      verify(popupPosition.x >= 0 && popupPosition.x + tip.width <= page(driver).width)
      verify(popupPosition.y >= 0 && popupPosition.y + tip.height <= page(driver).height)
      verify(tip.text.indexOf(meanings[i]) >= 0)
      compare(tip.contentItem.textFormat, Text.PlainText)
      compare(info.Accessible.description, tip.text)
      mouseMove(child(driver, "detailBack"), 1, 1)
      tryCompare(tip, "visible", false)
      mouseClick(info, info.width - 2, info.height - 2) // Entire label block is a helper.
      tryCompare(tip, "opened", true, 250)
      verify(!info.activeFocus, "Helper click must not acquire sticky mouse focus")
      compare(back.count, 0)
      keyClick(Qt.Key_Escape)
      tryCompare(tip, "visible", false)
      wait(400)
      verify(!tip.visible, "Unchanged hover must not reopen dismissed help")
      compare(back.count, 0, "Escape dismisses help before page back")
      mouseClick(info, 2, 2)
      tryCompare(tip, "opened", true, 250)
      mouseMove(child(driver, "detailBack"), 1, 1)
      tryCompare(tip, "visible", false)
      info.forceActiveFocus(Qt.TabFocusReason)
      tryCompare(tip, "opened", true)
      verify(info.activeFocusOnTab)
      compare(info.Accessible.name, info.modelData.label + " " + page(driver).count(info.modelData.value))
      keyClick(Qt.Key_Escape)
      tryCompare(tip, "visible", false)
      verify(info.activeFocus)
      compare(back.count, 0)
      ;[Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space].forEach(function(key) {
        keyClick(key)
        tryCompare(tip, "opened", true)
        keyClick(Qt.Key_Escape)
        tryCompare(tip, "visible", false)
        compare(back.count, 0)
      })
      keyClick(Qt.Key_Return)
      keyClick(Qt.Key_Tab)
      verify(!info.activeFocus, "Keyboard traversal must leave the metric block")
      tryCompare(tip, "visible", false)
      driver.takeFocus()
    }
    verify(driver.pluginRow.matchUnread, "Metric help must not mark a match reviewed")
    keyClick(Qt.Key_Escape)
    compare(back.count, 1, "Escape navigates when no tooltip is open")
  }

  function test_metric_help_dismissal_lifecycle_data() {
    return ["leave", "outside-page", "outside", "scroll", "wheel", "view", "identity", "inactive"].map(function(change) {
      return {tag:change, change:change}
    })
  }
  function test_metric_help_dismissal_lifecycle(data) {
    var driver = make("available", sizes()[0])
    var surface = page(driver)
    var metric = child(driver, "detailMetric.stars")
    var tip = child(metric, "detailMetricTip.stars")
    var back = createTemporaryObject(spyComponent, testCase, {target:driver, signalName:"backRequested"})
    reveal(driver, metric)
    metric.forceActiveFocus(Qt.TabFocusReason)
    tryCompare(tip, "opened", true)
    mouseMove(metric, 2, 2)
    mouseClick(metric, 2, 2)
    tryCompare(tip, "opened", true)
    var beforeY = scroll(driver).contentItem.contentY
    if (data.change === "leave") mouseMove(child(driver, "detailBack"), 1, 1)
    else if (data.change === "outside-page") mouseMove(testCase, testCase.width - 1, testCase.height - 1)
    else if (data.change === "outside") mouseClick(surface, surface.width - 2, surface.height - 2)
    else if (data.change === "scroll") scroll(driver).contentItem.contentY += 20
    else if (data.change === "wheel") mouseWheel(metric, 2, 2, 0, -120)
    else if (data.change === "view") surface.visible = false
    else if (data.change === "identity") surface.pluginRow = Object.assign({}, surface.pluginRow, {id:"example.other-listing"})
    else {
      var other = createTemporaryObject(otherWindowComponent, testCase)
      other.show()
      other.requestActivate()
      tryCompare(surface.Window.window, "active", false)
    }
    settle()
    if (data.change === "wheel")
      tryVerify(function() { return scroll(driver).contentItem.contentY > beforeY }, 1000, "Help dismissal must not consume scrolling")
    tip = child(child(driver, "detailMetric.stars"), "detailMetricTip.stars")
    tryCompare(tip, "visible", false)
    verify(!surface.activeMetricHelp, "No tooltip request remains after dismissal or delegate replacement")
    compare(back.count, 0)
    if (data.change === "view") surface.visible = true
    if (data.change === "inactive") {
      surface.Window.window.requestActivate()
      tryCompare(surface.Window.window, "active", true)
    }
    wait(400)
    verify(!tip.visible, "Dismissal survives unchanged focus/hover and window/view restoration")
    if (data.change === "leave") verify(metric.activeFocus, "Pointer leave must close help even with retained keyboard focus")
    driver.takeFocus()
    metric = child(driver, "detailMetric.stars")
    tip = child(metric, "detailMetricTip.stars")
    reveal(driver, metric)
    mouseMove(child(driver, "detailBack"), 1, 1)
    mouseMove(metric, 2, 2)
    tryCompare(tip, "opened", true)
  }

  function test_pending_metric_hover_outside_click_still_reaches_control() {
    var driver = make("available", sizes()[0])
    var metric = child(driver, "detailMetric.stars")
    var tip = child(metric, "detailMetricTip.stars")
    reveal(driver, metric)
    mouseMove(child(driver, "detailBack"), 1, 1)
    mouseMove(metric, 2, 2)
    compare(page(driver).activeMetricHelp, metric)
    verify(!tip.visible, "Exercise the pending hover delay")
    click(child(driver, "detailSource"))
    wait(400)
    verify(!tip.visible)
    compare(page(driver).activeMetricHelp, null)
    verify(driver.notice.indexOf("Source preview") >= 0, "Outside helper dismissal does not consume the intended action")
  }

  function test_metric_pending_hover_escape_and_single_current_tip() {
    var driver = make("available", sizes()[0])
    var back = createTemporaryObject(spyComponent, testCase, {target:driver, signalName:"backRequested"})
    var stars = child(driver, "detailMetric.stars")
    var likes = child(driver, "detailMetric.likes")
    var starTip = child(stars, "detailMetricTip.stars")
    var likeTip = child(likes, "detailMetricTip.likes")
    reveal(driver, stars)
    mouseMove(child(driver, "detailBack"), 1, 1)
    mouseMove(stars, 2, 2)
    keyClick(Qt.Key_Escape)
    wait(400)
    verify(!starTip.visible, "Escape also cancels the delayed hover request")
    compare(back.count, 0)
    stars.forceActiveFocus(Qt.TabFocusReason)
    tryCompare(starTip, "opened", true)
    mouseClick(likes, 2, 2)
    tryCompare(likeTip, "opened", true)
    verify(!starTip.visible, "There is only one current tooltip, even with focus on the previous metric")
    keyClick(Qt.Key_Escape)
    tryCompare(likeTip, "visible", false)
    compare(back.count, 0)
    keyClick(Qt.Key_Escape)
    compare(back.count, 1)
  }

  function test_matching_disclosure_keeps_keyboard_control() {
    var driver = make("available")
    var disclosure = child(driver, "detailMatchingDisclosure")
    reveal(driver, disclosure)
    disclosure.forceActiveFocus(Qt.TabFocusReason)
    verify(!page(driver).matchingExpanded)
    keyClick(Qt.Key_Space)
    verify(page(driver).matchingExpanded)
    keyClick(Qt.Key_Return)
    verify(!page(driver).matchingExpanded)
    verify(driver.pluginRow.matchUnread)
  }

  function test_matching_uses_right_column_below_outlined_uninstall() {
    var driver = make("installed", {width:1180,height:740})
    var surface = page(driver)
    verify(surface.dockRecommendation)
    var inlineSection = child(driver, "inlineRecommendationLoader")
    verify(!inlineSection.visible)
    compare(inlineSection.height, 0, "Docked recommendations leave no blank space in the body")
    var controls = child(driver, "detailControls")
    var recommendation = child(driver, "detailRecommendationScroll")
    var disclosure = child(driver, "detailMatchingDisclosure")
    verify(recommendation.visible)
    verify(child(driver, "detailUninstall").bordered)
    var point = recommendation.mapToItem(surface, 0, 0)
    verify(point.y >= controls.y + controls.height)
    compare(point.x, controls.x)
    reveal(driver, disclosure)
    within(disclosure, recommendation, "Matching disclosure in right column")
    driver.width = 728
    settle()
    verify(!surface.dockRecommendation && !recommendation.visible)
    verify(inlineSection.visible && inlineSection.height > 0)
    disclosure = child(driver, "detailMatchingDisclosure")
    reveal(driver, disclosure)
    within(disclosure, scroll(driver), "Narrow matching stays in scrollable content")
  }

  function test_gallery_selection_and_fullsize_dismissal_data() { return sizes() }
  function test_gallery_selection_and_fullsize_dismissal(data) {
    var driver = make("available", data)
    var back = createTemporaryObject(spyComponent, testCase, {target:driver, signalName:"backRequested"})
    var preview = child(driver, "detailPreview")
    tryCompare(preview, "status", Image.Ready, 5000)
    compare(driver.mediaItems.length, 3)
    clickBody(driver, "detailMedia.2")
    compare(page(driver).selectedMedia, 2)
    tryCompare(preview, "status", Image.Ready, 5000)
    verify(String(preview.source).indexOf("detail-dockside-focus.svg") >= 0)
    verify(child(driver, "detailMedia.2").selected)
    verify(!child(driver, "detailMedia.0").selected)
    verify(findChild(driver, "detailFullSize") === null, "Preview replaces the separate full-size button")
    clickBody(driver, "detailPreview")
    var popup = child(driver, "detailFullSizePopup")
    tryCompare(popup, "visible", true)
    compare(popup.width, data.width)
    compare(popup.height, data.height)
    keyClick(Qt.Key_Escape)
    tryCompare(popup, "visible", false)
    compare(back.count, 0, "Dismissing an image must not navigate away")
    verify(preview.activeFocus)
    verify(preview.Accessible.description.indexOf("Escape") >= 0)
    keyClick(Qt.Key_Return)
    tryCompare(popup, "visible", true)
    var close = actionWithText(popup.contentItem, "Close preview")
    verify(close !== null)
    click(close)
    tryCompare(popup, "visible", false)
    compare(back.count, 0)
    verify(preview.activeFocus)
    keyClick(Qt.Key_Space)
    tryCompare(popup, "visible", true)
    keyClick(Qt.Key_Escape)
    tryCompare(popup, "visible", false)
    verify(preview.activeFocus)
    compare(back.count, 0)
  }

  function test_open_is_an_explicit_small_fictional_panel_data() { return sizes() }
  function test_open_is_an_explicit_small_fictional_panel(data) {
    var driver = make("installed", data)
    var popup = child(driver, "detailPrototypePopup")
    verify(!popup.visible, "Opening details must not simulate Open automatically")
    compare(child(driver, "detailPrimary").text, "Open")
    click(child(driver, "detailPrimary"))
    tryCompare(popup, "visible", true)
    verify(popup.width < driver.width && popup.height <= driver.height)
    var copy = texts(popup.contentItem).join("\n")
    verify(copy.indexOf("FICTIONAL PANEL") >= 0 && copy.indexOf("No plugin is running") >= 0)
    var dismiss = child(driver, "detailPrototypeDismiss")
    tryVerify(function() { return dismiss.activeFocus })
    click(dismiss)
    tryCompare(popup, "visible", false)
    click(child(driver, "detailPrimary"))
    keyClick(Qt.Key_Escape)
    tryCompare(popup, "visible", false)
    verify(driver.presentation.installed && driver.presentation.enabled)
  }

  function test_remove_requires_confirmation_and_defaults_to_cancel_data() { return sizes() }
  function test_remove_requires_confirmation_and_defaults_to_cancel(data) {
    var driver = make("installed", data)
    var popup = child(driver, "detailPrototypePopup")
    var remove = child(driver, "detailUninstall")
    click(remove)
    tryCompare(popup, "visible", true)
    var cancel = child(driver, "detailPrototypeDismiss")
    compare(cancel.text, "Cancel")
    tryVerify(function() { return cancel.activeFocus })
    keyClick(Qt.Key_Return)
    tryCompare(popup, "visible", false)
    verify(driver.presentation.installed && !driver.presentation.pending)
    click(remove)
    keyClick(Qt.Key_Escape)
    tryCompare(popup, "visible", false)
    verify(driver.presentation.installed && !driver.presentation.pending)
    click(remove)
    tryVerify(function() { return cancel.activeFocus })
    keyClick(Qt.Key_Tab)
    var confirm = child(driver, "detailPrototypeConfirmRemove")
    tryVerify(function() { return confirm.activeFocus })
    keyClick(Qt.Key_Space)
    tryCompare(popup, "visible", false)
    verify(driver.presentation.pending && driver.presentation.installed)
    waitForOperation(driver)
    verify(!driver.presentation.installed)
    compare(child(driver, "detailPrimary").text, "Install")
  }

  function test_position_never_enables_and_preferences_survive_reinstall() {
    var driver = make("disabled")
    click(child(driver, "detailPosition.left"))
    verify(!driver.presentation.enabled)
    compare(driver.presentation.section, "left")
    compare(child(driver, "detailPrimary").text, "Enable")
    click(child(driver, "detailPrimary"))
    verify(driver.presentation.enabled)
    compare(driver.presentation.section, "left")
    click(child(driver, "detailEnabled"))
    verify(!driver.presentation.enabled)
    compare(driver.presentation.section, "left")
    click(child(driver, "detailUninstall"))
    click(child(driver, "detailPrototypeConfirmRemove"))
    waitForOperation(driver)
    verify(!driver.installEnabled)
    compare(driver.installSection, "left")
    click(child(driver, "detailPrimary"))
    waitForOperation(driver)
    verify(driver.presentation.installed && !driver.presentation.enabled)
    compare(driver.presentation.section, "left")
    compare(child(driver, "detailPrimary").text, "Enable")
  }

  function test_install_choices_and_batch_selection_are_independent() {
    var driver = make("available")
    click(child(driver, "detailInstallEnabled"))
    verify(!driver.installEnabled)
    click(child(driver, "detailPosition.center"))
    verify(!driver.installEnabled)
    compare(driver.installSection, "center")
    click(child(driver, "detailBatch"))
    verify(driver.presentation.selected)
    compare(child(driver, "detailPrimary").text, "Install")
    compare(child(driver, "detailBatch").text, "Remove from batch")
    click(child(driver, "detailPrimary"))
    verify(driver.presentation.pending)
    verify(!child(driver, "detailPrimary").enabled)
    verify(!child(driver, "detailPosition.left").enabled)
    waitForOperation(driver)
    verify(driver.presentation.installed && !driver.presentation.enabled && !driver.presentation.selected)
    compare(driver.presentation.section, "center")
  }

  function test_service_and_replacement_expose_only_applicable_controls() {
    var driver = make("service")
    verify(!child(driver, "detailPrimary").visible, "Enabled background services have no Open")
    verify(!child(driver, "detailGallery").visible)
    verify(!child(driver, "detailPosition.left").visible)
    verify(child(driver, "detailEnabled").enabled && child(driver, "detailUninstall").enabled)
    click(child(driver, "detailEnabled"))
    verify(!driver.presentation.enabled)
    compare(child(driver, "detailPrimary").text, "Enable")
    click(child(driver, "detailPrimary"))
    verify(!child(driver, "detailPrimary").visible)
    driver.initialState = "replacement"
    wait(0)
    compare(child(driver, "detailPrimary").text, "Use this bar")
    verify(!child(driver, "detailEnabled").visible && !child(driver, "detailPosition.left").visible)
    verify(!child(driver, "detailUninstall").visible && !child(driver, "detailBatch").visible)
    click(child(driver, "detailPrimary"))
    verify(driver.notice.indexOf("Demo") >= 0 && driver.notice.indexOf("desktop bar has not changed") >= 0)
    verify(!child(driver, "detailPrimary").enabled)
  }

  function test_pending_is_held_and_switching_cancels_old_operation() {
    var driver = make("pending")
    verify(driver.presentation.pending)
    verify(!child(driver, "detailPrimary").enabled)
    wait(1750)
    verify(driver.presentation.pending, "The initial pending fixture must stay deterministic")
    driver.initialState = "available"
    wait(0)
    click(child(driver, "detailPrimary"))
    verify(driver.presentation.pending)
    driver.initialState = "manual"
    wait(1750)
    verify(!driver.presentation.pending && !driver.presentation.installed)
    compare(child(driver, "detailPrimary").text, "Open project page")
  }

  function test_retry_preserves_partial_install_disabled_state() {
    var driver = make("failed")
    verify(driver.presentation.installed && driver.presentation.failed && !driver.presentation.enabled)
    verify(child(driver, "detailOperationMessage").text.indexOf("entry-point-not-found") >= 0)
    compare(child(driver, "detailPrimary").text, "Retry installation")
    click(child(driver, "detailPrimary"))
    verify(driver.presentation.pending)
    waitForOperation(driver)
    verify(driver.presentation.installed && !driver.presentation.failed && !driver.presentation.enabled)
    compare(child(driver, "detailPrimary").text, "Enable")
  }

  function test_project_source_and_marketplace_only_show_demo_notices() {
    var driver = make("manual")
    click(child(driver, "detailPrimary"))
    verify(driver.notice.indexOf("Demo") >= 0 && driver.notice.indexOf("project page") >= 0)
    click(child(driver, "detailSource"))
    verify(driver.notice.indexOf("Demo") >= 0 && driver.notice.indexOf("Source preview") >= 0)
    click(child(driver, "detailMarketplace"))
    verify(driver.notice.indexOf("Demo") >= 0 && driver.notice.indexOf("Marketplace preview") >= 0)
    verify(!driver.presentation.installed && !driver.presentation.pending)
    verify(!child(driver, "detailPrototypePopup").visible)
    driver.initialState = "missing"
    wait(0)
    verify(!child(driver, "detailPrimary").visible)
    verify(!child(driver, "detailSource").enabled && !child(driver, "detailMarketplace").enabled)
    verify(!child(driver, "detailGallery").visible)
    for (var i = 0; i < 4; ++i)
      verify(texts(child(driver, "detailMetric." + ["stars", "likes", "views", "copies"][i])).indexOf("—") >= 0)
  }

  function test_review_is_explicit_outside_matching_and_clones_the_row() {
    var driver = make("available")
    var originalRow = driver.pluginRow
    verify(originalRow.matchUnread, "Opening details must not mark the match reviewed")
    verify(!page(driver).matchingExpanded)
    clickBody(driver, "detailMatchingDisclosure")
    verify(page(driver).matchingExpanded && child(driver, "detailMatchingContent").visible)
    verify(driver.pluginRow.matchUnread, "Reading match evidence is not a mark-reviewed action")
    clickBody(driver, "detailDocumentationDisclosure")
    verify(driver.pluginRow.matchUnread)
    clickBody(driver, "detailMatchingDisclosure")
    verify(!page(driver).matchingExpanded)
    var mark = actionWithText(page(driver), "Mark reviewed")
    verify(mark !== null, "An explicit Mark reviewed action must exist outside the disclosure")
    verify(mark.visible && mark.enabled, "Mark reviewed must work with matching collapsed")
    clickPageAction(driver, mark)
    verify(!driver.pluginRow.matchUnread)
    compare(driver.pluginRow.matchLabel, "Reviewed")
    verify(driver.pluginRow !== originalRow && originalRow.matchUnread, "Review must replace the row, not mutate a snapshot")
    verify(!page(driver).matchingExpanded && !page(driver).documentationExpanded,
      "Reviewing the same listing must preserve reading state")
    var fresh = make("available")
    verify(fresh.pluginRow.matchUnread, "Review state must not leak to another prototype instance")
  }

  function test_fixture_switch_resets_reading_state_data() {
    return [{tag:"same-product", state:"installed"}, {tag:"different-product", state:"service"}]
  }

  function test_valid_initial_state_changes_never_report_unknown_fixture() {
    var driver = make("available")
    var states = ["installed", "disabled", "service", "pending", "failed",
      "manual", "replacement", "long", "missing", "available"]
    for (var i = 0; i < states.length; ++i) {
      driver.initialState = states[i]
      // Check immediately as well as after polish: the change handler must
      // validate the new value without relying on a not-yet-updated binding.
      compare(driver.notice, "", "Valid fixture incorrectly warned on change: " + states[i])
      settle()
      compare(driver.notice, "", "Valid fixture retained a warning: " + states[i])
      compare(driver.fixtureState, states[i])
    }
    driver.initialState = "not-a-fixture"
    settle()
    verify(driver.notice.indexOf("Unknown fixture state") >= 0,
      "An actually invalid selection should still explain its fallback")
    driver.initialState = "installed"
    compare(driver.notice, "", "A valid selection must clear the previous fallback warning")
    settle()
    compare(driver.notice, "")
  }
  function test_interactive_picker_switches_state_and_reset_discards_only_mock_changes() {
    var driver = make("installed")
    click(child(driver, "detailPrototypePicker"))
    var popup = child(driver, "detailPrototypeStatePicker")
    tryCompare(popup, "visible", true)
    click(child(popup.contentItem, "detailPrototypeState.disabled"))
    compare(driver.initialState, "disabled")
    verify(driver.presentation.installed && !driver.presentation.enabled)
    tryCompare(popup, "visible", false)
    click(child(driver, "detailPosition.left"))
    compare(driver.presentation.section, "left")
    click(child(driver, "detailPrototypePicker"))
    click(child(driver, "detailPrototypeReset"))
    compare(driver.presentation.section, "right")
    verify(driver.presentation.installed && !driver.presentation.enabled)
    driver.takeFocus()
    keyClick(Qt.Key_F6)
    tryCompare(popup, "visible", true)
    keyClick(Qt.Key_Escape)
    tryCompare(popup, "visible", false)
  }
  function test_fixture_switch_resets_reading_state(data) {
    var driver = make("available")
    clickBody(driver, "detailMatchingDisclosure")
    clickBody(driver, "detailDocumentationDisclosure")
    clickBody(driver, "detailMedia.1")
    var view = scroll(driver)
    view.contentItem.contentY = view.contentItem.contentHeight - view.height
    verify(view.contentItem.contentY > 0)
    verify(page(driver).matchingExpanded && !page(driver).documentationExpanded)
    driver.initialState = data.state
    wait(0)
    verify(!page(driver).matchingExpanded && page(driver).documentationExpanded && !page(driver).descriptionExpanded)
    compare(page(driver).selectedMedia, 0)
    compare(scroll(driver).contentItem.contentY, 0)
    verify(!child(driver, "detailFullSizePopup").visible)
  }

  function test_switch_closes_overlays_and_back_keeps_browse_contract() {
    var driver = make("available")
    var back = createTemporaryObject(spyComponent, testCase, {target:driver, signalName:"backRequested"})
    tryCompare(child(driver, "detailPreview"), "status", Image.Ready, 5000)
    clickBody(driver, "detailPreview")
    verify(child(driver, "detailFullSizePopup").visible)
    driver.initialState = "installed"
    wait(0)
    verify(!child(driver, "detailFullSizePopup").visible)
    click(child(driver, "detailPrimary"))
    verify(child(driver, "detailPrototypePopup").visible)
    driver.initialState = "available"
    wait(0)
    verify(!child(driver, "detailPrototypePopup").visible)
    driver.backLabel = "Back to interest matches"
    verify(child(driver, "detailBack").text.indexOf("Back to interest matches") >= 0)
    driver.takeFocus()
    verify(child(driver, "detailBack").activeFocus)
    keyClick(Qt.Key_Return)
    compare(back.count, 1)
  }

  function test_changing_selected_id_resets_reading_state() {
    var driver = make("available")
    clickBody(driver, "detailMatchingDisclosure")
    clickBody(driver, "detailDocumentationDisclosure")
    clickBody(driver, "detailMedia.1")
    var view = scroll(driver)
    view.contentItem.contentY = view.contentItem.contentHeight - view.height
    // Simulate a new selection supplied by a fixture host without changing the
    // scenario. This catches owners that reset only on initialState changes.
    var next = JSON.parse(JSON.stringify(driver.fixtureModel))
    next.row.id = "org.example.another-fictional-selection"
    driver.fixtureModel = next
    wait(0)
    compare(page(driver).identity, next.row.id)
    verify(!page(driver).matchingExpanded && page(driver).documentationExpanded)
    compare(page(driver).selectedMedia, 0)
    compare(scroll(driver).contentItem.contentY, 0)
  }

  function test_native_install_label_is_direct() {
    var state = InspectorState.resolve({id:"org.example.fixture", installAvailable:true}, null, {inventoryReady:true})
    compare(state.primaryLabel, "Install")
  }

  function test_keyboard_body_scroll_from_back_data() {
    return sizes().concat(responsiveSizes()).concat([{tag:"large-font",width:1180,height:740,largeFont:true}])
  }
  function test_keyboard_body_scroll_from_back(data) {
    if (data.largeFont) Style.font = {family:"serif",caption:17,bodySmall:19,body:23,subtitle:25,title:31}
    var driver = make("long", data)
    var surface = page(driver)
    surface.pluginRow = Object.assign({}, surface.pluginRow, {readmeText:new Array(200).join("A readable line.\n")})
    settle()
    var flick = scroll(driver).contentItem
    var back = child(driver, "detailBack")
    verify(back.activeFocus, "Initial Back focus must support scrolling without Tab")
    var primary = createTemporaryObject(spyComponent, testCase, {target:surface, signalName:"primaryRequested"})
    var end = flick.contentHeight - flick.height
    keyClick(Qt.Key_Down)
    fuzzyCompare(flick.contentY, Math.round(toggleMetrics.height * 2.5), 0.1)
    verify(back.activeFocus, "Scrolling must not move focus")
    keyClick(Qt.Key_Up)
    compare(flick.contentY, 0)
    keyClick(Qt.Key_Up)
    compare(flick.contentY, 0, "Clamp at top")
    keyClick(Qt.Key_PageDown)
    fuzzyCompare(flick.contentY, flick.height, 0.1)
    keyClick(Qt.Key_PageDown)
    fuzzyCompare(flick.contentY, flick.height * 2, 0.1)
    keyClick(Qt.Key_PageUp)
    fuzzyCompare(flick.contentY, flick.height, 0.1)
    keyClick(Qt.Key_End)
    fuzzyCompare(flick.contentY, end, 0.1)
    keyClick(Qt.Key_Down)
    keyClick(Qt.Key_PageDown)
    fuzzyCompare(flick.contentY, end, 0.1, "Clamp at bottom")
    keyClick(Qt.Key_Home)
    compare(flick.contentY, 0)
    keyClick(Qt.Key_Down, Qt.ShiftModifier)
    keyClick(Qt.Key_End, Qt.ControlModifier)
    compare(flick.contentY, 0, "Modified keys do not scroll the page")
    compare(primary.count, 0)
    keyClick(Qt.Key_Tab)
    verify(!back.activeFocus, "Normal Tab traversal survives scrolling")
  }

  function test_keyboard_scroll_right_pane_and_inline_recommendations_data() { return sizes() }
  function test_keyboard_scroll_right_pane_and_inline_recommendations(data) {
    var driver = make("installed", data)
    var surface = page(driver)
    surface.pluginRow = Object.assign({}, surface.pluginRow, {matchReason:new Array(150).join("Evidence line.\n")})
    surface.matchingExpanded = true
    settle()
    var body = scroll(driver).contentItem
    var right = child(driver, "detailRecommendationScroll").contentItem
    var own = surface.dockRecommendation ? right : body
    var other = surface.dockRecommendation ? body : right
    var disclosure = child(driver, "detailMatchingDisclosure")
    disclosure.forceActiveFocus()
    own.contentY = 0
    var otherY = other.contentY
    keyClick(Qt.Key_Down)
    fuzzyCompare(own.contentY, Math.round(toggleMetrics.height * 2.5), 0.1)
    compare(other.contentY, otherY)
    keyClick(Qt.Key_PageDown)
    fuzzyCompare(own.contentY, Math.round(toggleMetrics.height * 2.5) + own.height, 0.1)
    keyClick(Qt.Key_End)
    fuzzyCompare(own.contentY, own.contentHeight - own.height, 0.1)
    keyClick(Qt.Key_Down)
    keyClick(Qt.Key_PageDown)
    compare(other.contentY, otherY, "Boundary keys must not escape into the other pane")
    keyClick(Qt.Key_Home)
    compare(own.contentY, 0)
    // The collapsed right pane is shorter than its viewport and must stay put.
    if (surface.dockRecommendation) {
      surface.matchingExpanded = false
      settle()
      verify(own.contentHeight < own.height)
      keyClick(Qt.Key_End)
      keyClick(Qt.Key_Down)
      keyClick(Qt.Key_PageUp)
      compare(own.contentY, 0)
      compare(other.contentY, otherY)
    }
  }

  function test_keyboard_scroll_preserves_controls_and_editors() {
    var driver = make("available", sizes()[0])
    var surface = page(driver)
    var flick = scroll(driver).contentItem
    var position = child(driver, "detailPosition.left")
    position.forceActiveFocus()
    keyClick(Qt.Key_Down)
    verify(flick.contentY > 0, "Action buttons without arrow semantics allow page scrolling")
    compare(driver.installSection, "right")
    keyClick(Qt.Key_Right)
    compare(driver.installSection, "right", "Arrow scrolling never invokes a position action")
    var y = flick.contentY
    var editor = createTemporaryObject(editorComponent, surface)
    editor.forceActiveFocus()
    ;[Qt.Key_Up, Qt.Key_Down, Qt.Key_PageUp, Qt.Key_PageDown, Qt.Key_Home, Qt.Key_End].forEach(function(key) {
      keyClick(key)
      compare(flick.contentY, y, "Editable text owns navigation")
    })
    var combo = createTemporaryObject(dropdownComponent, surface)
    combo.forceActiveFocus()
    keyClick(Qt.Key_Down)
    compare(combo.currentIndex, 1)
    compare(flick.contentY, y, "Closed dropdown consumes its arrows")
    combo.popup.open()
    tryCompare(combo.popup, "opened", true)
    keyClick(Qt.Key_Down)
    compare(combo.highlightedIndex, 2)
    compare(flick.contentY, y, "Open dropdown owns navigation")
    keyClick(Qt.Key_Escape)
    tryCompare(combo.popup, "visible", false)
    // Repeat inside the ScrollView: its native fallback must not steal an
    // unhandled editor key or a modified arrow from a body control.
    var body = child(driver, "detailMetrics").parent.parent
    editor.parent = body
    editor.forceActiveFocus()
    keyClick(Qt.Key_Down)
    compare(flick.contentY, y, "An editor inside the pane retains its arrows")
    combo.parent = body
    combo.forceActiveFocus()
    keyClick(Qt.Key_Up)
    compare(flick.contentY, y)
    var metric = child(driver, "detailMetric.stars")
    metric.forceActiveFocus()
    y = flick.contentY
    keyClick(Qt.Key_Down, Qt.ShiftModifier)
    keyClick(Qt.Key_Up, Qt.ControlModifier)
    compare(flick.contentY, y, "Modified body-control arrows must not trigger ScrollView's fallback")
  }

  function test_keyboard_scroll_dismisses_help_without_reopening() {
    var driver = make("available", sizes()[0])
    var metric = child(driver, "detailMetric.stars")
    var tip = child(metric, "detailMetricTip.stars")
    metric.forceActiveFocus()
    mouseMove(metric, 2, 2)
    tryCompare(tip, "opened", true)
    var flick = scroll(driver).contentItem
    var y = flick.contentY
    keyClick(Qt.Key_Down)
    fuzzyCompare(flick.contentY, y + Math.round(toggleMetrics.height * 2.5), 0.1)
    tryCompare(tip, "visible", false)
    wait(400)
    verify(!tip.visible, "Unchanged keyboard focus/pointer must not reopen help")
    verify(metric.activeFocus)
  }

  function test_keyboard_scroll_short_body_stays_at_origin() {
    var driver = make("missing", sizes()[0])
    var flick = scroll(driver).contentItem
    verify(flick.contentHeight < flick.height)
    ;[Qt.Key_Down, Qt.Key_Up, Qt.Key_End, Qt.Key_Home, Qt.Key_PageDown, Qt.Key_PageUp].forEach(function(key) {
      keyClick(key)
      compare(flick.contentY, 0)
    })
  }
}
