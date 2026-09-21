import QtQuick
import QtQuick.Window
import QtTest
import qs.Commons
import "../.." as Plugin
import "../../ui" as Ui

TestCase {
  id: testCase
  name: "InterestsNavigation"
  when: windowShown
  width: 1200
  height: 800
  visible: true
  Component { id: serviceComponent; Plugin.Service {} }
  Component { id: managerComponent; Ui.InterestsManager {} }
  SignalSpy { id: clickSpy; signalName: "clicked" }
  Item { id: focusSentinel; width:1; height:1; activeFocusOnTab:true }
  readonly property var originalFont: ({family:"monospace",caption:12,bodySmall:14,body:16,subtitle:18,title:22})
  function cleanup() { Style.font = originalFont }
  function test_font_changes_grow_icons_rows_and_keep_save_reachable_data() {
    return [{tag:"minimum",width:760,height:540}, {tag:"tall",width:900,height:1000}]
  }
  function test_font_changes_grow_icons_rows_and_keep_save_reachable(data) {
    Style.font = {family:"monospace",caption:10,bodySmall:11,body:12,heading:16,subtitle:14,title:22}
    var manager = fixture(data)
    var use = child(manager, "detectedUse.device-0")
    var rowHeight = use.parent.height
    var icon = null
    for (var item of use.children) if (item.kind !== undefined) icon = item
    verify(icon !== null)
    compare(icon.width, 18)
    compare(use.width, 36)
    var info = child(manager, "detectedInfo.device-0")
    info.forceActiveFocus()
    keyClick(Qt.Key_Return)
    verify(info.selected, "Vector info remains keyboard operable")
    keyClick(Qt.Key_Return)
    Style.font = {family:"serif",caption:14,bodySmall:18,body:20,heading:26,subtitle:24,title:30}
    settle()
    verify(icon.width > 18 && use.width > 36 && use.parent.height > rowHeight)
    compare(child(manager, "saveInterestsButton").fontSize, manager.readingSize)
    within(child(manager, "saveInterestsButton"), manager, "Save with enlarged font")
    manager.addInterest()
    settle()
    var choice = reveal(manager, "serviceInterest.service-0", "interestsAddedScroll")
    verify(choice.height >= manager.targetSize)
    var field = child(manager, "interestChoiceSearch")
    compare(field.font.family, "serif")
    compare(field.font.pixelSize, manager.readingSize)
    within(child(manager, "saveInterestsButton"), manager, "Added Save with enlarged font")
  }

  function init() { failOnWarning(/(TypeError|ReferenceError|Binding loop|Cannot read property|Cannot call method)/) }
  function settle() { wait(0); verify(waitForPolish(testCase.Window.window)) }
  function sizes() { return [{tag:"compact",width:728,height:430}, {tag:"minimum",width:760,height:540}, {tag:"wide",width:1180,height:740}] }
  function fixture(size) {
    size = size || sizes()[0]
    var object = createTemporaryObject(serviceComponent, testCase)
    object.receiveOutput(JSON.stringify({ok:true, action:"load", generation:object.activeGeneration}))
    object.editorOpen = true
    var criteria = [], detected = [], services = []
    for (var i = 0; i < 20; i++) {
      criteria.push({id:"interest.fixture"+i,kind:"topic",label:"Saved fixture " + i,terms:["term " + i],enabled:true})
      detected.push({id:"device-"+i,label:"Detected fixture " + i,domain:"hardware",probeId:"input-devices",
        method:"sysfs",freshness:i === 0 ? "stale" : "current",detail:"Last confirmed fictional device",terms:["device " + i]})
    }
    detected.push({id:"capability-radio",label:"Radio capability",domain:"software",probeId:"software-capabilities",
      method:"inferred",freshness:"current",terms:["radio"]})
    for (var j = 0; j < 38; j++) services.push({id:"service-"+j,name:"Service " + j,category:j % 2 ? "Network" : "Media"})
    object.inputs = {revision:1,criteria:criteria,ignoredSignals:["device-19"],detected:detected,
      probes:[{id:"input-devices",state:"partial",reason:"One device unavailable"},
        {id:"software-capabilities",state:"success",reason:""}],
      serviceChoices:services,featureChoices:[
        {id:"pen-tablet",label:"Pen or tablet",category:"Drawing",terms:["stylus", "tablet"]},
        {id:"gamepad",label:"Game controller",category:"Gaming",terms:["controller"]}],
      scanState:"partial",checkedAt:100}
    object.inputsLoaded = true
    object.criteriaRevision = 1
    object.resetInterestsDraft()
    var manager = createTemporaryObject(managerComponent, testCase,
      {service:object, width:size.width, height:size.height})
    verify(manager !== null)
    settle()
    return manager
  }
  function child(manager, name) {
    var item = findChild(manager, name)
    verify(item !== null, "Missing " + name)
    return item
  }
  function within(item, container, label) {
    var p = item.mapToItem(container, 0, 0)
    var context = label + " [" + p.x + "," + p.y + "," + item.width + "," + item.height
      + "] in " + container.width + "x" + container.height
    verify(item.visible && item.width > 0 && item.height > 0, context)
    verify(p.x >= -1 && p.y >= -1 && p.x + item.width <= container.width + 1
      && p.y + item.height <= container.height + 1, context)
  }
  function reveal(manager, name, viewName) {
    settle()
    var item = child(manager, name), view = child(manager, viewName), flick = view.contentItem
    var position = item.mapToItem(flick.contentItem, 0, 0)
    flick.contentX = Math.max(0, Math.min(position.x - Math.max(0, (view.availableWidth - item.width) / 2), flick.contentWidth - view.availableWidth))
    flick.contentY = Math.max(0, Math.min(position.y - Math.max(0, (view.availableHeight - item.height) / 2), flick.contentHeight - view.availableHeight))
    settle()
    within(item, view, name)
    return item
  }
  function click(item) {
    settle()
    verify(item.visible && item.enabled, item.objectName)
    clickSpy.target = item
    clickSpy.clear()
    mouseClick(item, item.width / 2, item.height / 2)
    compare(clickSpy.count, 1, "Pointer must reach " + item.objectName)
    settle()
  }
  function search(manager, query) {
    manager.addInterest()
    settle()
    var field = child(manager, "interestChoiceSearch")
    verify(field.activeFocus)
    field.text = query
    settle()
  }
  function choose(manager, name) { click(reveal(manager, name, "interestsAddedScroll")) }
  function reply(object, fields) {
    fields.action = object.activeAction
    fields.generation = object.activeGeneration
    if (fields.ok === undefined) fields.ok = true
    object.receiveOutput(JSON.stringify(fields))
    settle()
  }

  function test_compact_and_wide_keep_search_choices_and_save_accessible_data() { return sizes() }
  function test_compact_and_wide_keep_search_choices_and_save_accessible(data) {
    var manager = fixture(data)
    var detected = child(manager, "interestsDetectedScroll")
    within(detected, manager, "detected viewport")
    verify(detected.contentItem.contentHeight > detected.height)
    compare(manager.detectedGroups.length, 2)
    verify(manager.detectedGroups[0].hardware)
    var use = reveal(manager, "detectedUse.device-0", "interestsDetectedScroll")
    within(child(manager, "detectedInfo.device-0"), detected, "compact info action")
    compare(use.height, manager.targetSize)
    verify(use.parent.height >= use.height && use.parent.height <= use.height + 12,
      "Detected rows follow the reading font and preserve compact padding")
    compare(findChild(manager, "keepWatching.device-0"), null)
    manager.addInterest()
    settle()
    compare(manager.editor, null)
    var picker = child(manager, "interestsAddedScroll")
    within(child(manager, "interestChoiceSearch"), manager, "always-visible search")
    within(child(manager, "selectedInterestsScroll"), manager, "selected interests")
    within(picker, manager, "choice viewport")
    verify(picker.height >= 36, "At least one choice must fit in the compact picker")
    verify(!detected.visible, "Detected must stay hidden on the Added tab even at wide widths")
    var save = child(manager, "saveInterestsButton")
    var before = save.mapToItem(manager, 0, 0)
    picker.contentItem.contentY = picker.contentItem.contentHeight - picker.height
    settle()
    within(save, manager, "fixed Save")
    within(child(manager, "discardInterestsButton"), manager, "fixed Discard")
    compare(save.mapToItem(manager, 0, 0).y, before.y)
    verify(picker.mapToItem(manager, 0, picker.height).y <= before.y)
    verify(picker.contentItem.contentWidth <= picker.availableWidth + 1)
    search(manager, "Media")
    within(child(manager, "customInterestButton"), manager, "custom query action")
    verify(picker.height >= 36, "Entering a query must leave usable choices")
    choose(manager, "serviceInterest.service-0")
    verify(manager.service.interestsDirty)
  }

  function test_tabs_are_exclusive_and_section_grids_stay_in_bounds_data() { return sizes() }
  function test_tabs_are_exclusive_and_section_grids_stay_in_bounds(data) {
    var manager = fixture(data)
    var detected = child(manager, "interestsDetectedScroll")
    var picker = child(manager, "interestsAddedScroll")
    var searchField = child(manager, "interestChoiceSearch")
    var grid = child(manager, "detectedSectionsGrid")
    var groups = child(manager, "detectedGroups")
    compare(grid.columns, data.tag === "wide" ? 2 : 1)
    compare(detected.width, manager.width)
    verify(detected.visible && !picker.visible && !searchField.visible)
    for (var i = 0; i < groups.count; i++) within(groups.itemAt(i), grid, "detected group " + i)
    var first = groups.itemAt(0), second = groups.itemAt(1)
    if (data.tag === "wide") {
      compare(first.y, second.y)
      verify(first.x + first.width < second.x)
    } else {
      compare(first.x, second.x)
      verify(first.y + first.height < second.y)
    }
    var use = child(manager, "detectedUse.device-0")
    compare(use.width, manager.targetSize)
    verify(first.width <= 540, "Sections keep names and controls close")
    verify(use.text.indexOf("Use for suggestions") < 0)
    compare(use.Accessible.role, Accessible.CheckBox)
    verify(use.Accessible.name.indexOf("Use for suggestions") >= 0)
    manager.chooseSection("added", true)
    settle()
    verify(!detected.visible && picker.visible && searchField.visible)
    compare(picker.width, manager.width)
    var choices = child(manager, "interestChoiceGroups")
    var choicesGrid = child(manager, "interestChoicesGrid")
    compare(choicesGrid.columns, data.tag === "wide" ? 2 : 1)
    for (var j = 0; j < choices.count; j++) within(choices.itemAt(j), choicesGrid, "choice category " + j)
    var a = child(manager, "serviceInterest.service-0"), b = child(manager, "serviceInterest.service-2")
    verify(a.width <= 540 && a.height >= manager.targetSize, "Bounded choices have font-scaled targets")
    compare(a.x, b.x)
    verify(a.y + a.height < b.y, "Choices stay in readable rows within adaptive category columns")
    manager.chooseSection("detected", true)
    settle()
    verify(detected.visible && !picker.visible && !searchField.visible)
  }

  function test_partial_scan_warning_is_visible_without_details_and_bounds_error_copy() {
    var manager = fixture({width:760,height:540}), object = manager.service
    var warning = child(manager, "interestScanError")
    verify(!manager.scanDetailsExpanded)
    within(warning, child(manager, "interestsDetectedScroll"), "inline partial scan warning")
    verify(warning.text.indexOf("Partial scan") >= 0)
    verify(warning.text.indexOf("Input devices") >= 0)
    verify(warning.text.indexOf("One device unavailable") >= 0)
    verify(!child(manager, "visibleProbeStatuses").itemAt(0).visible)
    object.scanError = "Very long failure detail. ".repeat(40)
    settle()
    verify(warning.text.indexOf("failed") >= 0)
    verify(warning.text.indexOf("Very long failure detail") < 0)
    verify(warning.text.length < 400, "Full errors belong only in the details disclosure")
    var context = JSON.parse(JSON.stringify(object.inputs))
    context.scanState = "success"
    context.probes[0].state = "success"
    object.inputs = context
    object.scanError = ""
    settle()
    verify(!warning.visible)
  }

  function test_multi_select_survives_search_and_category_changes_data() { return sizes() }
  function test_multi_select_survives_search_and_category_changes(data) {
    var manager = fixture(data), object = manager.service
    object.setupServiceIds = ["unrelated-browse-filter"]
    var saved = JSON.stringify(object.inputs.criteria)
    search(manager, "Media")
    choose(manager, "serviceInterest.service-0")
    choose(manager, "serviceInterest.service-2")
    search(manager, "Network")
    choose(manager, "serviceInterest.service-1")
    search(manager, "stylus")
    choose(manager, "featureInterest.pen-tablet")
    compare(object.interestsDraft.criteria.length, 24)
    compare(object.interestEditor, null)
    compare(object.pendingInterestPreview, null)
    verify(!object.requestActive, "Selection must not launch preview, save, or review work")
    compare(JSON.stringify(object.inputs.criteria), saved)
    compare(object.interestsDraft.ignoredSignals, ["device-19"])
    compare(object.setupServiceIds, ["unrelated-browse-filter"])
    search(manager, "Media")
    verify(child(manager, "serviceInterest.service-0").selected)
    verify(child(manager, "serviceInterest.service-2").selected)
    choose(manager, "serviceInterest.service-0")
    compare(object.interestsDraft.criteria.length, 23)
    search(manager, "Drawing")
    verify(child(manager, "featureInterest.pen-tablet").selected)
    search(manager, "Network")
    verify(child(manager, "serviceInterest.service-1").selected)
    click(child(manager, "discardInterestsButton"))
    compare(object.interestsDraft.criteria.length, 20)
    compare(child(manager, "interestChoiceSearch").text, "")
    verify(!object.interestsDirty && !object.requestActive)
  }

  function test_custom_query_deduplicates_without_resuming_paused_interest() {
    var manager = fixture(), object = manager.service
    object.discoveryEnabled = true
    search(manager, "Harbor   notes")
    click(child(manager, "customInterestButton"))
    compare(object.interestsDraft.criteria.length, 21)
    compare(object.interestsDraft.criteria[20].terms, ["Harbor   notes"])
    compare(child(manager, "interestChoiceSearch").text, "")
    click(reveal(manager, "pauseInterest.20", "selectedInterestsScroll"))
    verify(!object.interestsDraft.criteria[20].enabled)
    search(manager, "  HARBOR notes  ")
    click(child(manager, "customInterestButton"))
    compare(object.interestsDraft.criteria.length, 21)
    compare(object.interestsDraft.criteria[20].label, "Harbor   notes")
    verify(!object.interestsDraft.criteria[20].enabled)
    verify(object.interestsNotice.indexOf("still paused") >= 0)
    var resume = reveal(manager, "pauseInterest.20", "selectedInterestsScroll")
    compare(resume.text, "Resume")
    click(resume)
    verify(object.interestsDraft.criteria[20].enabled)
    compare(object.inputs.criteria.length, 20)
    compare(object.interestEditor, null)
  }

  function test_single_save_combines_picker_and_ignored_inputs_and_blocks_double_submit() {
    var manager = fixture(), object = manager.service
    click(reveal(manager, "detectedUse.device-0", "interestsDetectedScroll"))
    search(manager, "Media")
    choose(manager, "serviceInterest.service-0")
    search(manager, "Drawing")
    choose(manager, "featureInterest.pen-tablet")
    verify(!object.requestActive)
    var save = child(manager, "saveInterestsButton")
    click(save)
    compare(object.activeAction, "save-interests")
    compare(object.activeRequest.criteria.length, 22)
    compare(object.activeRequest.ignoredSignals, ["device-19", "device-0"])
    var request = JSON.parse(JSON.stringify(object.activeRequest))
    verify(!save.enabled)
    mouseClick(save, save.width / 2, save.height / 2)
    compare(object.activeGeneration, request.generation)
    compare(object.mutationQueue.length, 0)
    verify(!child(manager, "discardInterestsButton").enabled)
    var saved = JSON.parse(JSON.stringify(object.inputs))
    saved.revision = 2
    saved.criteria = request.criteria
    saved.ignoredSignals = request.ignoredSignals
    reply(object, {inputs:saved, criteriaRevision:2})
    verify(!object.interestsDirty)
    compare(object.inputs.criteria.length, 22)
    compare(object.interestsDraft.ignoredSignals, ["device-19", "device-0"])
    verify(!save.enabled, "One successful save must leave no second Apply/Save step")
  }

  function test_detected_info_is_readonly_and_scan_details_are_optional() {
    var manager = fixture(), object = manager.service
    var before = JSON.stringify(object.interestsDraft)
    verify(!manager.scanDetailsExpanded)
    var probes = child(manager, "visibleProbeStatuses")
    verify(!probes.itemAt(0).visible)
    click(child(manager, "scanDetailsButton"))
    verify(probes.itemAt(0).visible && probes.itemAt(1).visible)
    click(child(manager, "scanDetailsButton"))
    var info = reveal(manager, "detectedInfo.device-0", "interestsDetectedScroll")
    var row = info.parent.parent
    var collapsed = row.height
    click(info)
    verify(row.height > collapsed)
    compare(JSON.stringify(object.interestsDraft), before)
    compare(object.interestEditor, null)
    click(reveal(manager, "detectedInfo.device-0", "interestsDetectedScroll"))
    compare(row.height, collapsed)
    click(reveal(manager, "detectedUse.device-0", "interestsDetectedScroll"))
    compare(object.interestsDraft.criteria.length, 20)
    verify(!object.detectedEnabled("device-0"))
    compare(object.inputs.ignoredSignals, ["device-19"])
  }

  function test_save_restores_tab_focus_and_keyboard_shortcuts_after_response() {
    var manager = fixture(), object = manager.service
    search(manager, "Media")
    choose(manager, "serviceInterest.service-0")
    var save = child(manager, "saveInterestsButton")
    click(save)
    compare(object.activeAction, "save-interests")
    verify(!save.enabled)
    verify(child(manager, "interestsAddedTab").activeFocus, "Successful save must move focus off the disabled button")
    var saved = JSON.parse(JSON.stringify(object.inputs))
    saved.revision = 2
    saved.criteria = object.activeRequest.criteria
    saved.ignoredSignals = object.activeRequest.ignoredSignals
    reply(object, {inputs:saved, criteriaRevision:2})
    verify(!save.enabled)
    keyClick(Qt.Key_1, Qt.AltModifier)
    settle()
    compare(manager.section, "detected")
    verify(child(manager, "interestsDetectedTab").activeFocus)
    keyClick(Qt.Key_2, Qt.AltModifier)
    settle()
    compare(manager.section, "added")
    verify(child(manager, "interestsAddedTab").activeFocus)
  }

  function test_invalid_save_does_not_redirect_focus_to_tab() {
    var manager = fixture(), object = manager.service
    object.editInterest(-1, {id:"",kind:"topic",label:"",terms:[],enabled:true})
    settle()
    var label = child(manager, "interestLabel")
    verify(label.activeFocus)
    // Exercise the handler without a pointer focus transfer to ensure failure
    // preserves the current field rather than forcing tab focus.
    child(manager, "saveInterestsButton").clicked()
    settle()
    verify(!object.requestActive)
    verify(Boolean(object.interestsError))
    verify(label.activeFocus)
    verify(object.interestEditor !== null)
  }

  function test_tabs_retain_three_independent_scroll_positions() {
    var manager = fixture()
    var detected = child(manager, "interestsDetectedScroll").contentItem
    var added = child(manager, "interestsAddedScroll").contentItem
    var selected = child(manager, "selectedInterestsScroll").contentItem
    detected.contentY = 240
    manager.chooseSection("added", true)
    settle()
    added.contentY = 360
    selected.contentX = 180
    manager.chooseSection("detected", true)
    settle()
    compare(detected.contentY, 240)
    manager.chooseSection("added", true)
    settle()
    compare(added.contentY, 360)
    compare(selected.contentX, 180)
  }

  function test_selected_chips_keep_picker_position_at_zero_one_ten_and_limit_data() { return sizes() }
  function test_selected_chips_keep_picker_position_at_zero_one_ten_and_limit(data) {
    var manager = fixture(data), object = manager.service
    object.discoveryEnabled = true
    manager.chooseSection("added", true)
    var picker = child(manager, "interestsAddedScroll")
    var selected = child(manager, "selectedInterestsScroll")
    settle()
    var y = picker.mapToItem(manager, 0, 0).y, height = picker.height
    var stripHeight = selected.height
    for (var count of [0, 1, 10, 64]) {
      var criteria = []
      for (var i = 0; i < count; i++) criteria.push({id:"interest.chip"+i,kind:"topic",
        label:"A long selected topic " + i,terms:["chip " + i],enabled:true})
      object.changeInterests(criteria, [])
      settle()
      compare(picker.mapToItem(manager, 0, 0).y, y, count + " selected: picker y")
      compare(picker.height, height, count + " selected: picker height")
      compare(selected.height, stripHeight)
      if (count) {
        click(reveal(manager, "pauseInterest.interest.chip" + (count - 1), "selectedInterestsScroll"))
        verify(!object.interestsDraft.criteria[count - 1].enabled)
        click(reveal(manager, "removeInterest.interest.chip" + (count - 1), "selectedInterestsScroll"))
        compare(object.interestsDraft.criteria.length, count - 1)
        compare(picker.mapToItem(manager, 0, 0).y, y)
      }
    }
  }

  function test_keyboard_focus_reveals_horizontal_chips_in_both_directions() {
    var manager = fixture(), object = manager.service
    object.discoveryEnabled = true
    manager.addInterest()
    settle()
    var strip = child(manager, "selectedInterestsScroll")
    var searchField = child(manager, "interestChoiceSearch")
    var picker = child(manager, "interestsAddedScroll")
    var y = picker.mapToItem(manager, 0, 0).y
    searchField.forceActiveFocus()
    for (var i = 0; i < 20; i++) {
      keyClick(Qt.Key_Tab); settle()
      var pause = child(manager, "pauseInterest.interest.fixture" + i)
      verify(pause.activeFocus, "Tab reaches pause " + i)
      within(pause, strip, "focused pause " + i)
      keyClick(Qt.Key_Tab); settle()
      var remove = child(manager, "removeInterest.interest.fixture" + i)
      verify(remove.activeFocus, "Tab reaches remove " + i)
      within(remove, strip, "focused remove " + i)
    }
    verify(strip.contentItem.contentX > 0)
    for (var j = 19; j >= 0; j--) {
      keyClick(Qt.Key_Backtab); settle()
      var previous = child(manager, "pauseInterest.interest.fixture" + j)
      verify(previous.activeFocus)
      within(previous, strip, "reverse pause " + j)
      if (j) { keyClick(Qt.Key_Backtab); settle() }
    }
    compare(picker.mapToItem(manager, 0, 0).y, y)
    keyClick(Qt.Key_Space); settle()
    verify(!object.interestsDraft.criteria[0].enabled)
    verify(searchField.activeFocus)
  }

  function test_launch_hides_pause_and_highlights_unsaved_changes_without_moving_picker() {
    var manager = fixture(), object = manager.service
    manager.addInterest()
    settle()
    verify(!object.discoveryEnabled)
    var pause = child(manager, "pauseInterest.interest.fixture0")
    verify(!pause.visible)
    var bar = child(manager, "interestsSaveBar")
    var save = child(manager, "saveInterestsButton")
    var status = child(manager, "interestsSaveStatus")
    var picker = child(manager, "interestsAddedScroll")
    var initialHeight = picker.height
    verify(!save.enabled && !save.selected)
    compare(status.text, "All changes saved")
    click(reveal(manager, "removeInterest.interest.fixture0", "selectedInterestsScroll"))
    verify(object.interestsDirty && manager.unsaved)
    verify(save.enabled && save.selected)
    verify(bar.color.a > 0)
    compare(status.text, "Unsaved changes")
    compare(picker.height, initialHeight)
    object.interestsError = "Could not save. Your draft is retained."
    verify(save.selected && manager.unsaved)
    object.interestsError = ""
    object.resetInterestsDraft()
    object.interestsNotice = "Interests saved for recommendations, including interests with no current results."
    settle()
    compare(picker.height, initialHeight)
    verify(!save.selected && !save.enabled)
    compare(status.text, "All changes saved")
    verify(!child(manager, "pauseInterest.interest.fixture0").visible)
    object.discoveryEnabled = true
    settle()
    verify(child(manager, "pauseInterest.interest.fixture0").visible)
  }

  function test_header_scan_actions_align_right_and_stack_before_overlap_data() {
    return [{tag:"wide",width:1180,height:740}, {tag:"compact-large-font",width:728,height:540,large:true}]
  }
  function test_header_scan_actions_align_right_and_stack_before_overlap(data) {
    if (data.large) Style.font = {family:"monospace",caption:14,bodySmall:18,body:20,subtitle:24,title:30}
    var manager = fixture(data)
    var tab = child(manager, "interestsAddedTab"), rescan = child(manager, "interestsRescanButton")
    var details = child(manager, "scanDetailsButton")
    within(tab, manager, "Added tab")
    within(rescan, manager, "Rescan")
    within(details, manager, "Scan details")
    var t = tab.mapToItem(manager, 0, 0), r = rescan.mapToItem(manager, 0, 0)
    verify(r.y >= t.y + tab.height || r.x >= t.x + tab.width, "Scan actions never overlap tabs")
    if (!data.large) compare(details.mapToItem(manager, details.width, 0).x, manager.width)
  }

  function test_keyboard_tabs_add_and_multiselect_need_no_editor() {
    var manager = fixture()
    manager.takeFocus()
    keyClick(Qt.Key_2, Qt.AltModifier)
    compare(manager.section, "added")
    verify(child(manager, "interestsAddedTab").activeFocus)
    keyClick(Qt.Key_Left)
    compare(manager.section, "detected")
    keyClick(Qt.Key_A, Qt.AltModifier)
    settle()
    var field = child(manager, "interestChoiceSearch")
    verify(field.activeFocus)
    keyClick(Qt.Key_M)
    settle()
    compare(field.text.toLowerCase(), "m")
    keyClick(Qt.Key_Tab)
    verify(child(manager, "customInterestButton").activeFocus)
    var choice = child(manager, "serviceInterest.service-0")
    var steps = 0
    while (!choice.activeFocus && steps++ < 70) { keyClick(Qt.Key_Tab); settle() }
    verify(choice.activeFocus, "Tab must reach a picker choice through the selected list")
    within(choice, child(manager, "interestsAddedScroll"), "keyboard-focused choice")
    keyClick(Qt.Key_Space)
    settle()
    verify(child(manager, "serviceInterest.service-0").selected)
    compare(manager.editor, null)
    compare(manager.service.interestsDraft.criteria.length, 21)
  }

  function test_pending_legacy_editor_is_retained_and_included_in_one_save() {
    var manager = fixture(), object = manager.service
    object.discoveryEnabled = true
    object.editInterest(-1, {id:"",kind:"topic",label:"Legacy draft",terms:["legacy literal"],enabled:true})
    settle()
    verify(child(manager, "interestLabel").activeFocus)
    search(manager, "Drawing")
    choose(manager, "featureInterest.pen-tablet")
    compare(object.interestEditor.criterion.label, "Legacy draft")
    click(reveal(manager, "removeInterest.interest.fixture0", "selectedInterestsScroll"))
    click(reveal(manager, "pauseInterest.interest.fixture1", "selectedInterestsScroll"))
    compare(object.interestEditor.termText, "legacy literal")
    click(child(manager, "saveInterestsButton"))
    compare(object.activeAction, "save-interests")
    compare(object.interestEditor, null)
    compare(object.activeRequest.criteria.length, 21)
    compare(object.activeRequest.criteria[0].id, "interest.fixture1")
    verify(!object.activeRequest.criteria[0].enabled)
    compare(object.activeRequest.criteria[19].featureId, "pen-tablet")
    compare(object.activeRequest.criteria[20].label, "Legacy draft")
  }

  function test_typing_and_late_context_never_reveal_or_scroll_pending_editor() {
    var manager = fixture(), object = manager.service
    object.editInterest(-1, {id:"",kind:"topic",label:"Original",terms:["original"],enabled:true})
    settle()
    var added = child(manager, "interestsAddedScroll").contentItem
    added.contentY = 150
    var serial = object.interestEditSerial
    object.updateInterestEditor("label", "Untouched by late input data")
    var context = JSON.parse(JSON.stringify(object.inputs))
    context.revision = 2
    object.requestContext()
    verify(object.flushInterestsRequests())
    reply(object, {inputs:context})
    compare(manager.section, "added")
    compare(added.contentY, 150)
    compare(object.interestEditSerial, serial)
    manager.chooseSection("detected", true)
    var detected = child(manager, "interestsDetectedScroll").contentItem
    detected.contentY = 220
    object.updateInterestEditor("termText", "saved draft term")
    settle()
    compare(manager.section, "detected")
    compare(detected.contentY, 220)
    compare(object.interestEditor.criterion.label, "Untouched by late input data")
  }

  function test_close_and_destroy_cancel_deferred_focus_without_losing_pending_edit() {
    var manager = fixture(), object = manager.service
    object.editInterest(-1, {id:"",kind:"topic",label:"Keep me",terms:["draft"],enabled:true})
    settle()
    focusSentinel.forceActiveFocus()
    manager.addInterest()
    manager.visible = false
    settle()
    verify(focusSentinel.activeFocus)
    verify(object.interestEditor !== null)
    manager.visible = true
    manager.takeFocus()
    settle()
    verify(child(manager, "interestsBackButton").activeFocus)
    compare(manager.section, "added")
    manager.visible = false
    var temporary = managerComponent.createObject(testCase, {service:object,width:728,height:430})
    verify(temporary !== null)
    var guard = temporary.navigationGuard
    temporary.revealEditor()
    temporary.destroy()
    wait(1)
    verify(!guard.alive)
    compare(object.interestEditor.criterion.label, "Keep me")
  }
}
