import QtQuick
import QtTest
import qs.Commons
import "../.." as Plugin
import "../../ui" as Ui

TestCase {
  id: testCase
  name: "BrowseCards"
  when: windowShown
  width: 1600; height: 1000
  Component { id: serviceComponent; Plugin.Service {} }
  Component { id: appComponent; Ui.OutfitApp {} }
  readonly property var originalFont: ({family:"monospace",caption:12,bodySmall:14,body:16,subtitle:18,title:22})
  property color savedAccent
  function cleanup() { Style.font = originalFont; Color.accent = savedAccent }
  function init() {
    savedAccent = Color.accent
    failOnWarning(/(TypeError|ReferenceError|Binding loop|Cannot read property|Cannot assign)/)
  }
  function test_window_metric_geometry_data() {
    var rows = []
    for (var size of [[760, 540], [900, 1000]])
      for (var large of [false, true])
        for (var density of ["comfortable", "compact", "dense", "list"])
          for (var grouping of ["none", "category"])
            rows.push({tag:size.join("x") + "-" + density + (large ? "-large" : "-default") + "-" + grouping,
              width:size[0],height:size[1],large:large,density:density,grouping:grouping})
    return rows
  }
  function test_window_metric_geometry(data) {
    Style.font = data.large
      ? {family:"serif",caption:14,bodySmall:18,body:20,heading:26,subtitle:24,title:30}
      : {family:"monospace",caption:10,bodySmall:11,body:12,heading:16,subtitle:14,title:22}
    var service = createTemporaryObject(serviceComponent, testCase)
    service.receiveOutput(JSON.stringify({ok:true,action:"load",generation:service.activeRequest.generation,
      preferences:{watchHardware:false,readmeEnrichment:false,readmeIndexing:false,marketplaceThumbnails:false,
        services:[],browseDensity:data.density}}))
    service.hasAnalyzed = true
    service.setupAppliedGrouping = data.grouping
    service.setupSections = [{id:"tools",label:"Tools",total:1}]
    service.setupRows = [{id:"example.geometry",name:"Geometry fixture",kind:"panel",displayGroup:"tools",
      description:"Readable description with full metric counts. ".repeat(20),
      stars:1234567890,likes:0,views:9876543210,copies:null,score:42,recommendationScore:70}]
    var view = createTemporaryObject(appComponent, testCase, {service:service})
    view.open(JSON.stringify({setupStage:"browse",windowWidth:data.width,windowHeight:data.height}))
    wait(50)
    var card = view.browseCards()[0]
    var metrics = descendants(card, function(item) { return item.metric !== undefined })
    compare(metrics.length, 4)
    var grid = metrics[0].parent
    var description = descendants(card, function(item) { return item.text === card.pluginRow.description })[0]
    compare(description.maximumLineCount, 4)
    compare(description.font.pixelSize, Style.font.body)
    verify(description.paintedHeight <= description.height + 1, "Four-line description fits at this font and width")
    verify(grid.rowSpacing >= 2 && grid.rowSpacing <= 4)
    compare(grid.columns === 4, grid.width >= grid.minimumRowWidth)
    if (!data.large) compare(view.browseIconSize, 16)
    for (var metric of metrics) {
      var content = findChild(metric, "metricContent")
      var info = findChild(metric, "metricInfoTarget")
      verify(metric.width + 0.5 >= metric.implicitWidth, metric.metric + " full count fits")
      verify(metric.x + metric.width <= grid.width + 0.5, "Metric inside grid")
      var p = metric.mapToItem(card, 0, 0)
      verify(p.x >= 0 && p.x + metric.width <= card.width + 0.5, "Metric inside card width")
      verify(p.y >= 0 && p.y + metric.height <= card.height + 0.5, "Card grows to metric height")
      verify(!info.visible, "Browse has no info icon")
      verify(metric.height >= content.height)
      if (!data.large) verify(metric.height >= 20 && metric.height <= 24, "Default metric is dense")
      else verify(metric.height > 24, "Larger font grows the row")
    }
    view.close()
  }
  function test_metrics_reflow_with_font_and_width_data() { return test_metrics_and_card_interaction_data() }
  function test_metrics_reflow_with_font_and_width(data) {
    Style.font = {family:"monospace",caption:10,bodySmall:11,body:12,heading:16,subtitle:14,title:22}
    var service = createTemporaryObject(serviceComponent, testCase)
    service.receiveOutput(JSON.stringify({ok:true,action:"load",generation:service.activeRequest.generation,
      preferences:{watchHardware:false,readmeEnrichment:false,readmeIndexing:false,marketplaceThumbnails:false,
        services:[],browseDensity:data.density}}))
    service.hasAnalyzed = true
    service.inventoryReady = true
    service.setupAppliedGrouping = data.grouping
    service.setupSections = [{id:"tools",label:"Tools",total:1}]
    service.setupRows = [{id:"example.font",name:"Readable name",kind:"panel",displayGroup:"tools",description:"Readable description",
      stars:1234567890,likes:0,views:9876543210,copies:null,score:42,recommendationScore:70}]
    var view = createTemporaryObject(appComponent, testCase, {service:service})
    view.open(JSON.stringify({setupStage:"browse"}))
    wait(50)
    compare(view.readingSize, 13, "Shared reading role remains enlarged outside Browse")
    compare(view.browseReadingSize, 12)
    var card = view.browseCards()[0]
    var metrics = descendants(card, function(item) { return item.metric !== undefined })
    compare(metrics.length, 4)
    var grid = metrics[0].parent
    compare(grid.minimumRowWidth,
      metrics.reduce(function(total, metric) { return total + metric.implicitWidth }, 0) + 2 * 3,
      "Four natural-width groups have exactly three gaps")
    var originalIcon = metrics[0].metricIconSize
    for (var font of [Style.font,
      {family:"serif",caption:14,bodySmall:18,body:20,heading:26,subtitle:24,title:30}]) {
      Style.font = font
      for (var width of [1900, 700]) {
        card.width = width
        wait(40)
        compare(grid.columns === 4, grid.width >= grid.minimumRowWidth, "Wrap only after reducing the gaps")
        for (var metric of metrics) {
          verify(metric.width >= metric.implicitWidth, metric.metric + " retains full count after font/width change")
          verify(metric.x + metric.width <= grid.width + 0.5)
          verify(metric.y + metric.height <= grid.height + 0.5)
          var text = descendants(metric, function(item) { return item.font !== undefined && item.text !== undefined })[0]
          compare(text.font.family, font.family)
          compare(text.font.pixelSize, font.body)
          if (width === 1900) {
            compare(metric.y, 0, "All four metrics share one row")
            compare(metric.width, metric.implicitWidth, "Single-row cells never stretch")
            var index = metrics.indexOf(metric)
            if (index > 0)
              compare(metric.x - metrics[index - 1].x - metrics[index - 1].width, grid.columnSpacing)
          }
        }
        compare(metrics[1].number, "1234567890")
        compare(metrics[2].number, "9876543210")
      }
    }
    verify(metrics[0].metricIconSize > originalIcon)
    // Test the measured threshold, not a nominal breakpoint or card width.
    var threshold = grid.minimumRowWidth
    grid.width = threshold + 9
    wait(40)
    compare(grid.columns, 4)
    compare(grid.columnSpacing, 5, "Gaps adapt before wrapping")
    grid.width = threshold
    wait(40)
    compare(grid.columns, 4, "Exact actual-width fit stays on one row")
    compare(grid.columnSpacing, 2)
    grid.width = threshold - 1
    wait(40)
    verify(grid.columns < 4, "One pixel below the fit threshold wraps")
    // Even a single count wider than an absolute narrow cell retains every digit.
    grid.width = 85
    wait(40)
    compare(grid.columns, 1)
    var number = findChild(metrics[1], "metricNumber")
    compare(number.text, "1234567890")
    verify(number.paintedWidth <= number.width + 1 && number.lineCount > 1)
    verify(metrics[1].height >= number.height)
    view.close()
  }
  function descendants(item, predicate) {
    var result = []
    for (var child of item.children || []) {
      if (child.visible && predicate(child)) result.push(child)
      if (child.visible) result = result.concat(descendants(child, predicate))
    }
    return result
  }
  function test_metrics_and_card_interaction_data() {
    var rows = []
    for (var density of ["comfortable", "compact", "dense", "list"])
      for (var grouping of ["none", "category"])
        rows.push({tag:density + "-" + grouping, density:density, grouping:grouping})
    return rows
  }
  function test_metrics_and_card_interaction(data) {
    var service = createTemporaryObject(serviceComponent, testCase)
    service.receiveOutput(JSON.stringify({ok:true,action:"load",generation:service.activeRequest.generation,
      preferences:{watchHardware:false,readmeEnrichment:false,readmeIndexing:false,marketplaceThumbnails:false,
        services:[],browseDensity:data.density}}))
    service.hasAnalyzed = true
    service.inventoryReady = true
    service.setupSort = "recommended"
    service.setupAppliedGrouping = data.grouping
    service.setupSections = [{id:"tools",label:"Tools",total:1}]
    service.setupRows = [{id:"example.card",name:"Fixture",kind:"panel",displayGroup:"tools",verification:"verified",
      description:"A longer description with room to read.",reason:"DETECTED REASON MUST NOT APPEAR",
      stars:1234567890,likes:0,views:9876543210,copies:null,score:42,recommendationScore:70}]
    var view = createTemporaryObject(appComponent, testCase, {service:service})
    view.open(JSON.stringify({setupStage:"browse"}))
    wait(50)
    var cards = view.browseCards()
    compare(cards.length, 1)
    var card = cards[0]
    var surface = card
    while (surface.parent) surface = surface.parent
    var scrolls = descendants(surface, function(item) { return item.scrollbarGutter !== undefined })
    verify(scrolls.length >= 2, "Browse filters and results share the gutter")
    for (var scroll of scrolls) {
      compare(scroll.availableWidth, scroll.width - scroll.leftPadding - scroll.rightPadding)
      verify(scroll.rightPadding >= scroll.scrollbarGutter)
    }
    var metrics = descendants(card, function(item) { return item.metric !== undefined })
    compare(metrics.length, 4)
    compare(metrics.map(function(metric) { return metric.metric }).join(","), "likes,stars,views,copies")
    compare(metrics[0].y, 0, "No blank score row")
    var expected = {stars:"1234567890",likes:"0",views:"9876543210",copies:"—"}
    verify(Math.abs(view.metricMinimums.left - Math.max(metrics[0].implicitWidth, metrics[2].implicitWidth)) < 0.5,
      "Left minimum comes only from Stars and Views")
    verify(Math.abs(view.metricMinimums.right - Math.max(metrics[1].implicitWidth, metrics[3].implicitWidth)) < 0.5,
      "Right minimum comes only from Likes and Copies")
    card.forceActiveFocus()
    mouseMove(card, 1, 1)
    wait(30)
    verify(view.activeHelpTip === null || !view.activeHelpTip.visible, "No tooltip without hover or metric focus")
    for (var metric of metrics) {
      compare(metric.number, expected[metric.metric])
      var number = findChild(metric, "metricNumber")
      compare(number.text, expected[metric.metric])
      compare(number.font.pixelSize, Style.font.body)
      compare(number.color, Color.accent)
      var caption = findChild(metric, "metricCaption")
      if (metric.metric === "views" || metric.metric === "copies") {
        compare(caption.text, metric.metric === "views" ? "Views" : "Copies")
        verify(!caption.font.bold && caption.color !== number.color, "Quieter normal-weight label")
      }
      verify(metric.width >= metric.implicitWidth, metric.metric + " full count fits")
      var content = findChild(metric, "metricContent")
      var info = findChild(metric, "metricInfoIcon")
      verify(info && !info.visible, metric.metric + " Browse info icon removed")
      verify(!metric.helpVisible, metric.metric + " help idle")
      var column = metrics.indexOf(metric) % metric.parent.columns
      var widest = 0
      for (var j = column; j < metrics.length; j += metric.parent.columns)
        widest = Math.max(widest, metrics[j].implicitWidth)
      verify(Math.abs(content.x - Math.max(0, (metric.width - widest) / 2)) < 0.5,
        metric.metric + " shares the column inset, independent of text length")
      for (var k = column; k < metrics.length; k += metric.parent.columns)
        compare(findChild(metrics[k], "metricContent").x, content.x, "Rows share a left edge")
      verify(content.x >= 0 && content.x + content.width <= metric.width + 0.5)
      verify(metric.x + metric.width <= metric.parent.width + 0.5, "Cell fits metric grid")
      metric.forceActiveFocus(Qt.TabFocusReason)
      verify(metric.activeFocus && metric.helpVisible)
      tryVerify(function() { return view.activeHelpTip !== null && view.activeHelpTip.visible }, 1000, "keyboard " + metric.metric)
      verify(view.activeHelpTip.helpText.indexOf(view.metricHelp(metric.metric)) >= 0)
      keyClick(Qt.Key_Escape)
      card.forceActiveFocus()
      mouseMove(card, 1, 1)
      wait(30)
      mouseMove(metric, metric.width - 8, metric.height / 2)
      tryVerify(function() { return view.activeHelpTip !== null && view.activeHelpTip.visible }, 1000, "hover " + metric.metric)
      mouseMove(card, 1, 1)
      wait(30)
      view.dismissTooltips()
      verify(!info.visible)
    }
    var texts = descendants(card, function(item) { return item.text !== undefined }).map(function(item) { return item.text })
    verify(texts.indexOf("DETAILS >") < 0 && texts.indexOf("Details") < 0 && texts.indexOf("›") < 0,
      "No redundant details controls")
    verify(texts.indexOf("DETECTED REASON MUST NOT APPEAR") < 0)
    verify(texts.indexOf("Available") < 0 && texts.indexOf("AVAILABLE") < 0)
    verify(texts.indexOf("Community") < 0 && texts.indexOf("COMMUNITY") < 0)
    verify(texts.indexOf("panel") >= 0 || texts.indexOf("PANEL") >= 0)
    verify(!texts.some(function(text) { return /^(RECOMMENDED|FIT|Rec)\b/.test(text) }), "No visual scores in Browse")
    var description = descendants(card, function(item) { return item.text === card.pluginRow.description })[0]
    compare(description.font.pixelSize, Style.font.body)
    compare(description.maximumLineCount, 4)
    verify(description.paintedHeight <= description.height + 1, "Description height fits its rendered lines")
    var title = descendants(card, function(item) { return item.text === card.pluginRow.name })[0]
    verify(title.font.bold && title.font.pixelSize > description.font.pixelSize)
    var badge = descendants(card, function(item) { return item.objectName === "cardVerificationLabel" })[0]
    compare(badge.text, "Verified")
    compare(badge.font.pixelSize, Style.font.bodySmall)
    var kind = descendants(card, function(item) { return item.text === "panel" || item.text === "PANEL" })[0]
    compare(kind.font.pixelSize, Style.font.bodySmall)
    compare(badge.font, kind.font)
    compare(badge.color, kind.color)
    verify(badge.radius === undefined && badge.parent.color === undefined, "Verification is plain footer text, not a pill")
    var badgePosition = badge.mapToItem(card, 0, 0)
    var kindPosition = kind.mapToItem(card, 0, 0)
    verify(Math.abs(badgePosition.y + badge.height / 2 - kindPosition.y - kind.height / 2) < 1,
      "Verification is opposite plugin type in the footer")
    compare(Math.round(badgePosition.x + badge.width), Math.round(card.width - (data.density === "comfortable" ? 10 : 8)))
    verify(badgePosition.y > metrics[3].mapToItem(card, 0, 0).y)
    var picker = descendants(surface, function(item) { return item.label === "Sort plugins" })[0]
    // Clicking either the icon or count deliberately requests help, never details.
    for (var metric of metrics) {
      var count = findChild(metric, "metricNumber")
      var countCenter = count.mapToItem(metric, count.width / 2, count.height / 2)
      for (var x of [metric.metricIconSize / 2, countCenter.x]) {
        mouseMove(metric, x, metric.height / 2)
        wait(30) // Flush pointer movement, still well before the hover-help delay.
        mouseClick(metric, x, metric.height / 2)
        compare(view.setupDetailId, "")
        tryVerify(function() { return view.activeHelpTip !== null && view.activeHelpTip.visible }, 1000,
          "Explicit click help: " + metric.metric + " x=" + x)
        compare(view.activeHelpTip.helpText, view.metricHelp(metric.metric))
        mouseMove(card, 1, 1)
        tryCompare(view, "activeHelpTip", null)
        wait(30)
      }
    }
    mouseClick(title, 2, title.height / 2)
    compare(view.setupDetailId, "example.card")
    wait(20)
    var detail = findChild(view, "pluginDetailPage")
    verify(detail !== null)
    compare(detail.metrics.length + detail.scores.length, 6)
    compare(detail.scores[0].value, 70)
    compare(detail.scores[1].value, 42)
    compare(detail.readingSize, view.readingSize, "Detail retains the enlarged reading role")
    // Sorting by either score still requests that score, without score tiles.
    // Do this after pointer checks: the query status legitimately reflows cards.
    for (var sort of ["recommended", "fit"]) {
      verify(picker.options.some(function(option) { return option.value === sort }))
      picker.changed(sort)
      compare(service.setupSort, sort)
      compare((service.pendingSetup || service.activeRequest).setupSort, sort)
    }
    service.setupHardwareOnly = true
    picker.changed("fit")
    verify((service.pendingSetup || service.activeRequest).setupHardwareOnly, "Hardware filter remains in the score query")
    view.close()
  }
  function test_status_badges_and_typical_single_row_data() { return test_metrics_and_card_interaction_data() }
  function test_status_badges_and_typical_single_row(data) {
    Style.font = {family:"monospace",caption:10,bodySmall:11,body:12,heading:16,subtitle:14,title:22}
    var service = createTemporaryObject(serviceComponent, testCase)
    service.receiveOutput(JSON.stringify({ok:true,action:"load",generation:service.activeRequest.generation,
      preferences:{watchHardware:false,readmeEnrichment:false,readmeIndexing:false,marketplaceThumbnails:true,
        services:[],browseDensity:data.density}}))
    service.inventoryReady = true
    service.setupAppliedGrouping = data.grouping
    service.setupSections = [{id:"tools",label:"Tools",total:1}]
    service.setupRows = [{id:"example.status",name:"Installed fixture",kind:"panel",displayGroup:"tools",
      verification:"unverified",newUntil:Date.now() / 1000 + 3600,description:"Short readable copy",
      stars:1234,likes:22,views:56789,copies:432}]
    var view = createTemporaryObject(appComponent, testCase, {service:service})
    view.open(JSON.stringify({setupStage:"browse",windowWidth:760,windowHeight:540}))
    wait(50)
    var card = view.browseCards()[0]
    var metrics = descendants(card, function(item) { return item.metric !== undefined })
    compare(metrics.length, 4)
    compare(metrics[0].parent.columns, 4, "Typical counts stay on one line in every mode/grouping")
    for (var metric of metrics) compare(metric.y, 0)
    for (var enabled of [true, false]) {
      service.inventory = [{id:"example.status",enabled:enabled,kinds:["panel"]}]
      wait(30)
      var badges = descendants(card, function(item) { return item.label !== undefined && item.labelSize !== undefined })
      var installed = badges.filter(function(item) { return item.label.indexOf("Installed") === 0 })[0]
      verify(installed !== undefined)
      verify(installed.compactPadding)
      var label = descendants(installed, function(item) { return item.text === installed.label })[0]
      compare(installed.width - label.implicitWidth, 10)
      compare(installed.height - label.implicitHeight, 4)
      var verification = descendants(card, function(item) { return item.objectName === "cardVerificationLabel" })[0]
      var fresh = descendants(card, function(item) { return item.objectName === "newListingOverlay" })[0]
      verify(verification && fresh)
      compare(verification.text, "Unverified")
      var kind = descendants(card, function(item) { return item.text === "panel" || item.text === "PANEL" })[0]
      var kindPosition = kind.mapToItem(card, 0, 0)
      compare(Math.round(kindPosition.x), data.density === "comfortable" ? 10 : 8)
      var badgePosition = verification.mapToItem(card, 0, 0)
      verify(Math.abs(badgePosition.y + verification.height / 2 - kindPosition.y - kind.height / 2) < 1)
      var texts = descendants(card, function(item) { return item.text !== undefined }).map(function(item) { return item.text })
      verify(enabled ? texts.indexOf("Disabled") < 0 && texts.indexOf("Installed · Disabled") < 0
        : texts.indexOf("Disabled") >= 0 || texts.indexOf("Installed · Disabled") >= 0)
      verify(texts.indexOf("Details") < 0)
      // Footer never collides with copy/metrics/status or the thumbnail.
      verify(badgePosition.y >= metrics[3].mapToItem(card, 0, metrics[3].height).y)
    }
    service.inventory = []
    service.setupSelection = {"example.status":{id:"example.status",name:"Installed fixture"}}
    wait(30)
    verify(descendants(card, function(item) { return item.label === "In batch" }).length > 0,
      "Queue status survives removal of the Details action")
    service.inventoryReady = false
    wait(30)
    verify(descendants(card, function(item) { return item.label === "Inventory pending" }).length > 0)
    view.close()
  }
  function test_new_overlay_fallback_expiry_and_click_data() { return test_metrics_and_card_interaction_data() }
  function test_new_overlay_fallback_expiry_and_click(data) {
    Style.font = {family:"monospace",caption:10,bodySmall:11,body:12,heading:16,subtitle:14,title:22}
    var service = createTemporaryObject(serviceComponent, testCase)
    service.receiveOutput(JSON.stringify({ok:true,action:"load",generation:service.activeRequest.generation,
      preferences:{watchHardware:false,readmeEnrichment:false,readmeIndexing:false,marketplaceThumbnails:true,
        services:[],browseDensity:data.density}}))
    service.inventoryReady = true
    service.setupAppliedGrouping = data.grouping
    service.setupSections = [{id:"tools",label:"Tools",total:1}]
    var until = Math.floor(Date.now() / 1000) + 3600
    service.setupRows = [{id:"example.new",name:"New fixture",kind:"bar-widget",displayGroup:"tools",
      verification:"verified",newUntil:until,description:"Thumbnail decoration fixture",
      stars:12,likes:3,views:45,copies:6}]
    var view = createTemporaryObject(appComponent, testCase, {service:service})
    view.open(JSON.stringify({setupStage:"browse",windowWidth:760,windowHeight:540}))
    wait(50)
    var card = view.browseCards()[0]
    var tag = descendants(card, function(item) { return item.objectName === "newListingOverlay" })[0]
    verify(tag !== undefined)
    var thumbnail = tag.parent
    var image = thumbnail.children.filter(function(item) { return item.sourceSize !== undefined })[0]
    verify(image !== undefined, "New is a direct child of the thumbnail frame")
    compare(descendants(card, function(item) { return item.text === "New" }).length, 1)
    compare(Math.round(tag.x + tag.width), Math.round(thumbnail.width - 3))
    compare(tag.y, 3)
    verify(tag.x >= 0 && tag.y + tag.height <= thumbnail.height)
    verify(tag.width < thumbnail.width * 0.6 && tag.height < thumbnail.height * 0.5,
      "The corner tag leaves most of even a tiny List thumbnail visible")
    var label = findChild(tag, "newListingText")
    compare(tag.color, Color.background, "Opaque theme background keeps text readable on any image")
    verify(tag.color.a === 1 && tag.color !== label.color)
    for (var accent of ["#d8733e", "#9fe870"]) {
      Color.accent = accent
      compare(label.color, Color.accent, "Overlay follows live theme accent")
    }
    // The same corner decoration remains readable on a decoded image, not just
    // the loading/missing-image placeholder. This local asset stays in QtTest.
    image.source = Qt.resolvedUrl("../../assets/io.github.ctl0v0.outfit.svg")
    tryCompare(image, "status", Image.Ready)
    verify(tag.visible)
    mouseClick(tag, tag.width / 2, tag.height / 2)
    compare(view.setupDetailId, "example.new", "Overlay never intercepts the card click")
    view.closeSetupDetail()
    wait(30)
    service.preferences = Object.assign({}, service.preferences, {marketplaceThumbnails:false})
    wait(30)
    compare(descendants(card, function(item) { return item.objectName === "newListingOverlay" }).length, 0)
    var fallback = descendants(card, function(item) { return item.objectName === "newListingFallback" })[0]
    verify(fallback !== undefined && !thumbnail.visible)
    compare(fallback.text, "New")
    compare(fallback.font.pixelSize, Style.font.bodySmall)
    verify(fallback.radius === undefined && fallback.parent.color === undefined, "No-thumbnail fallback is plain text")
    Color.accent = "#bda2ee"
    compare(fallback.color, Color.accent)
    var title = descendants(card, function(item) { return item.text === "New fixture" })[0]
    var position = fallback.mapToItem(card, 0, 0)
    verify(position.x >= 0 && position.x + fallback.width <= card.width)
    verify(Math.abs(position.y - title.mapToItem(card, 0, 0).y) < title.height + 10,
      "No-thumbnail fallback stays near the name")
    mouseClick(fallback, fallback.width / 2, fallback.height / 2)
    compare(view.setupDetailId, "example.new", "Plain New also leaves card activation intact")
    view.closeSetupDetail()
    wait(30)
    for (var images of [false, true]) {
      service.preferences = Object.assign({}, service.preferences, {marketplaceThumbnails:images})
      for (var clock of [until * 1000 - 12 * 60 * 60 * 1000 - 1,
        until * 1000 - 12 * 60 * 60 * 1000, until * 1000 - 1, until * 1000]) {
        view.badgeClock = clock
        wait(10)
        var expected = clock >= until * 1000 - 12 * 60 * 60 * 1000 && clock < until * 1000
        compare(descendants(card, function(item) { return item.text === "New" }).length, expected ? 1 : 0,
          "Both presentations keep the existing twelve-hour bounds")
      }
    }
    view.close()
  }
  function test_long_kinds_wrap_verification_without_overlap_data() { return test_metrics_and_card_interaction_data() }
  function test_long_kinds_wrap_verification_without_overlap(data) {
    var service = createTemporaryObject(serviceComponent, testCase)
    service.receiveOutput(JSON.stringify({ok:true,action:"load",generation:service.activeRequest.generation,
      preferences:{watchHardware:false,readmeEnrichment:false,readmeIndexing:false,marketplaceThumbnails:false,
        services:[],browseDensity:data.density}}))
    service.setupAppliedGrouping = data.grouping
    service.setupSections = [{id:"tools",label:"Tools",total:1}]
    service.setupRows = [{id:"example.kinds",name:"Kinds fixture",displayGroup:"tools",verification:"unverified",
      kinds:["bar-widget", "service", "overlay", "menu", "panel", "long-kind-name-without-spaces"],
      description:"Long kinds fixture",stars:12,likes:3,views:45,copies:6}]
    var view = createTemporaryObject(appComponent, testCase, {service:service})
    view.open(JSON.stringify({setupStage:"browse"}))
    wait(50)
    var card = view.browseCards()[0]
    card.width = 240
    for (var font of [originalFont, {family:"serif",caption:14,bodySmall:18,body:20,subtitle:24,title:30}]) {
      Style.font = font
      wait(40)
      var kind = descendants(card, function(item) { return item.objectName === "cardKindLabel" })[0]
      var verification = descendants(card, function(item) { return item.objectName === "cardVerificationLabel" })[0]
      compare(verification.text, "Unverified")
      compare(verification.font, kind.font)
      compare(verification.color, kind.color)
      compare(kind.text.toLowerCase(), "bar-widget · service · overlay · menu · panel · long-kind-name-without-spaces")
      verify(verification.y >= kind.y + kind.height + 4, "Long kinds put verification on the next row")
      compare(Math.round(verification.x + verification.width), Math.round(kind.parent.width))
      for (var text of [kind, verification]) {
        verify(text.paintedWidth <= text.width + 1)
        var p = text.mapToItem(card, 0, 0)
        verify(p.x >= 0 && p.x + text.width <= card.width + 1)
        verify(p.y >= 0 && p.y + text.height <= card.height + 1, "Card grows for the wrapped footer")
      }
    }
    view.close()
  }
}
