import QtQuick
import QtTest
import QtQuick.Controls as C
import "../.." as Plugin
import "../../ui" as Ui
import "../../ui/Navigation.js" as Navigation

TestCase {
  id: testCase
  name: "Navigation"
  when: windowShown
  width: 1600; height: 1000
  Component { id: serviceComponent; Plugin.Service {} }
  Component { id: appComponent; Ui.OutfitApp {} }
  Component { id: textComponent; TextEdit { width: 180; height: 80 } }
  Component {
    id: popupComponent
    C.Popup {
      width: 200; height: 100
      modal: true; focus: true
      closePolicy: C.Popup.CloseOnEscape
      contentItem: C.Button { text: "Close"; onClicked: parent.close() }
      onOpened: contentItem.forceActiveFocus()
    }
  }
  property var service
  property var view
  function init() {
    service = createTemporaryObject(serviceComponent, testCase)
    service.receiveOutput(JSON.stringify({ok:true,action:"load",generation:service.activeRequest.generation,
      preferences:{watchHardware:false,readmeEnrichment:false,readmeIndexing:false,marketplaceThumbnails:false,services:[]}}))
    service.inventoryReady = true
    service.setupAppliedGrouping = "category"
    service.setupSections = [{id:"first",label:"First",total:3},{id:"second",label:"Second",total:3}]
    var rows = []
    for (var i = 0; i < 6; i++) rows.push({id:"fixture." + i,name:"Fixture " + i,
      displayGroup:i < 3 ? "first" : "second",kind:"panel",description:"Navigation fixture",
      verification:i === 0 ? "unverified" : i === 1 ? "verified" : i === 2 ? "unknown" : "not-applicable",
      stars:3,likes:2,views:5,copies:1})
    service.setupRows = rows
    view = createTemporaryObject(appComponent, testCase, {service:service})
    view.open(JSON.stringify({setupStage:"browse"}))
    wait(80)
  }
  function cleanup() { view.close() }
  function descendants(item, predicate) {
    var result = []
    for (var child of item.children || []) {
      if (!child.visible) continue
      if (predicate(child)) result.push(child)
      result = result.concat(descendants(child, predicate))
    }
    return result
  }
  function test_text_and_group_navigation() {
    view.focusWorkspace()
    wait(10)
    var editor = view.keyboardFocus
    verify(Navigation.textEditing(editor))
    editor.text = "draft query"
    editor.cursorPosition = 5
    keyClick(Qt.Key_Left)
    compare(editor.cursorPosition, 4)
    keyClick(Qt.Key_Backspace)
    compare(editor.text, "drat query")
    verify(view.opened)
    keyClick(Qt.Key_Tab)
    tryVerify(function() { return view.browseCards()[0].activeFocus })
    keyClick(Qt.Key_Tab, Qt.ShiftModifier)
    tryVerify(function() { return editor.activeFocus })
    compare(editor.text, "drat query")
    keyClick(Qt.Key_Down, Qt.ControlModifier)
    verify(view.filterFocus)
    verify(!Navigation.textEditing(view.keyboardFocus))
    var filter = view.keyboardFocus
    keyClick(Qt.Key_Down)
    verify(view.keyboardFocus !== filter)
    keyClick(Qt.Key_Tab)
    verify(view.resultFocus)
    keyClick(Qt.Key_F, Qt.ControlModifier)
    tryVerify(function() { return editor.activeFocus })
    compare(editor.selectedText, "drat query")
    keyClick(Qt.Key_F6)
    verify(!view.filterFocus && !view.resultFocus, "toolbar remains keyboard accessible")
  }
  function test_back_preserves_settings_draft_and_does_not_close_main() {
    var surface = view.browseCards()[0]
    while (surface.parent) surface = surface.parent
    view.settingsOpen = true
    view.draftReadmes = true
    view.settingsTouched = true
    var back = descendants(surface, function(item) { return item.text === "Back" && item.activeFocusOnTab })[0]
    verify(back !== undefined)
    back.forceActiveFocus()
    keyClick(Qt.Key_Backspace)
    verify(!view.settingsOpen)
    verify(view.draftReadmes && view.settingsTouched)
    view.focusResults()
    keyClick(Qt.Key_Backspace)
    verify(view.opened)
  }
  function test_backspace_at_start_of_nested_editor_never_goes_back() {
    var card = view.browseCards()[0]
    view.openSetupDetail(card.pluginRow, card)
    wait(30)
    var editor = createTemporaryObject(textComponent, view.keyboardFocus, {text:"one\ntwo"})
    editor.forceActiveFocus()
    editor.cursorPosition = 0
    keyClick(Qt.Key_Backspace)
    compare(view.setupDetailId, card.pluginRow.id)
    compare(editor.text, "one\ntwo")
    keyClick(Qt.Key_Down)
    verify(editor.cursorPosition > 0)
    keyClick(Qt.Key_Backspace)
    compare(view.setupDetailId, card.pluginRow.id)
    verify(editor.activeFocus)
  }
  function test_grid_and_list_data() {
    return ["comfortable", "compact", "dense", "list"].map(function(mode) { return {tag:mode, mode:mode} })
  }
  function test_geometry_short_rows_and_variable_heights() {
    var rects = [{x:100,y:0,width:200,height:120}, {x:400,y:0,width:200,height:200},
      {x:100,y:220,width:200,height:120}, {x:100,y:400,width:200,height:120},
      {x:400,y:400,width:200,height:120}]
    compare(Navigation.adjacent(rects, 1, Qt.Key_Down), 2, "do not skip a short row to keep a column")
    compare(Navigation.adjacent(rects, 0, Qt.Key_Right), 1)
    compare(Navigation.adjacent(rects, 2, Qt.Key_Right), 2, "no horizontal jump to another group")
    compare(Navigation.adjacent(rects, 4, Qt.Key_Up), 2)
    compare(Navigation.adjacent(rects, 0, Qt.Key_Up), 0)
  }
  function test_grid_and_list(data) {
    view.chooseDensity(data.mode)
    wait(80)
    var cards = view.browseCards()
    compare(cards.length, 6)
    cards[0].forceActiveFocus()
    if (data.mode !== "list") {
      keyClick(Qt.Key_Right)
      // Some densities have only one column at the minimum window width.
      var p = cards[1].mapToItem(cards[0], 0, 0)
      if (p.x > 0) verify(cards[1].activeFocus)
    }
    cards[2].forceActiveFocus()
    keyClick(Qt.Key_Down)
    verify(cards.slice(3).some(function(card) { return card.activeFocus }), "down crosses category boundary")
    var focused = view.keyboardFocus
    var scroll = view.currentScroll().contentItem
    var point = focused.mapToItem(scroll, 0, 0)
    verify(point.y >= -1 && point.y < scroll.height)
    var y = scroll.contentY
    keyClick(Qt.Key_Return)
    compare(view.setupDetailId, String(focused.pluginRow.id))
    wait(30)
    keyClick(Qt.Key_Backspace)
    compare(view.setupDetailId, "")
    tryVerify(function() { return focused.activeFocus })
    compare(scroll.contentY, y)
    compare(view.rovingResultId, String(focused.pluginRow.id))
    // Explicit states only, in each of the four views.
    var labels = function(card) { return descendants(card, function(item) { return item.objectName === "cardVerificationLabel" }).map(function(item) { return item.text }) }
    verify(labels(cards[0]).indexOf("Unverified") >= 0)
    verify(labels(cards[1]).indexOf("Verified") >= 0)
    verify(labels(cards[2]).indexOf("Unverified") < 0)
    verify(labels(cards[3]).indexOf("Unverified") < 0)
  }
  function test_card_information_access_data() { return test_grid_and_list_data() }
  function test_card_information_access(data) {
    view.chooseDensity(data.mode)
    wait(80)
    var card = view.browseCards()[0]
    card.forceActiveFocus()
    keyClick(Qt.Key_F2)
    compare(view.cardContentsOwner, card)
    var targets = Navigation.focusableChildren(card)
    var metrics = targets.filter(function(item) { return item.metric !== undefined })
    compare(targets.length, 4, "F2 contains only the four metrics, without a redundant Details action")
    compare(metrics.map(function(item) { return item.metric }).join(","), "likes,stars,views,copies")
    compare(view.keyboardFocus, targets[0])
    tryVerify(function() { return view.activeHelpTip !== null && view.activeHelpTip.visible })
    for (var key of [Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space]) {
      keyClick(Qt.Key_Escape)
      tryCompare(view, "activeHelpTip", null)
      keyClick(key)
      compare(view.setupDetailId, "", "Metric activation must not bubble to the card")
      tryVerify(function() { return view.activeHelpTip !== null && view.activeHelpTip.visible })
    }
    for (var i = 1; i < targets.length; i++) {
      keyClick(Qt.Key_Right)
      compare(view.keyboardFocus, targets[i])
      tryVerify(function() { return view.activeHelpTip !== null && view.activeHelpTip.visible
        && view.activeHelpTip.helpText === view.metricHelp(targets[i].metric) })
    }
    keyClick(Qt.Key_Right)
    verify(card.activeFocus, "Arrow past the last metric returns to the card")
    keyClick(Qt.Key_Return)
    compare(view.setupDetailId, card.pluginRow.id, "Enter on the card still opens detail")
    wait(30)
    keyClick(Qt.Key_Backspace)
    tryVerify(function() { return card.activeFocus })
    keyClick(Qt.Key_Tab)
    verify(view.filterFocus)
  }
  function test_confirmation_and_escape() {
    view.focusResults()
    view.batchConfirmOpen = true
    wait(30)
    keyClick(Qt.Key_Backspace)
    verify(view.batchConfirmOpen)
    keyClick(Qt.Key_Return)
    verify(!service.batchRunning, "Enter must not accept the destructive default")
    verify(!view.batchConfirmOpen, "Enter chooses Cancel in the real Outfit confirmation")
    view.batchConfirmOpen = true
    wait(0)
    // The themed dialog also preserves the existing explicit cancel signal.
    var surface = view.browseCards()[0]
    while (surface.parent) surface = surface.parent
    var dialogs = descendants(surface, function(item) { return item.confirmText === "Install all" })
    compare(dialogs.length, 1)
    compare(dialogs[0].selectedIndex, 0)
    dialogs[0].canceled()
    verify(!view.batchConfirmOpen)
    verify(view.opened)
    view.focusResults()
    view.dismissTooltips()
    keyClick(Qt.Key_Escape)
    verify(!view.opened)
  }
  function test_popup_has_priority() {
    var card = view.browseCards()[0]
    card.forceActiveFocus()
    var popup = createTemporaryObject(popupComponent, card)
    popup.open()
    wait(30)
    keyClick(Qt.Key_Tab)
    verify(!view.filterFocus && !view.resultFocus, "Tab stays in the modal")
    keyClick(Qt.Key_Backspace)
    verify(popup.visible && view.opened)
    keyClick(Qt.Key_Escape)
    tryCompare(popup, "visible", false)
    verify(view.opened, "Escape closes only the popup")
  }
}
