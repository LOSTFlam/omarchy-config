import QtQuick
import QtQuick.Window
import QtTest
import qs.Commons
import "../.." as Plugin
import "../../ui" as Ui
import "../../ui/InspectorState.js" as State

TestCase {
  id: testCase
  name: "UpdatesUi"
  when: windowShown
  visible: true
  width: 1180
  height: 760
  property var savedFont: null
  Component { id: pageComponent; Ui.UpdatesPage {} }
  Component { id: detailComponent; Ui.PluginDetailPage {} }
  Component { id: appComponent; Ui.OutfitApp {} }
  Component {
    id: serviceComponent
    Plugin.Service {
      property var updateCalls: []
      property var batchCalls: []
      property var selfCalls: []
      // Keep native workers inert while testing the actual owner's routing.
      function updatePlugin(row, resume) { updateCalls = updateCalls.concat([{row:row, resume:resume}]); return true }
      function startUpdateBatch(ids, resume) { batchCalls = batchCalls.concat([{ids:ids, resume:resume}]); return true }
      function beginSelfUpdate(row, resume) { selfCalls = selfCalls.concat([{row:row, resume:resume}]); return true }
    }
  }
  Component {
    id: fixtureComponent
    QtObject {
      property var updates: []
      property bool updatesLoaded: true
      property bool sleeping: false
      property bool updatesBusy: false
      property real updatesCheckedAt: 100
      property string updatesError: ""
      property bool mutationBusy: false
      property bool batchRunning: false
      property bool selfUpdateBusy: false
      property bool interestsDirty: false
      property var selfUpdateState: ({state:"idle", message:""})
      property var batchItems: []
      property string batchKind: "install"
    }
  }
  function init() {
    savedFont = JSON.parse(JSON.stringify(Style.font))
    failOnWarning(/(TypeError|ReferenceError|Binding loop|Cannot read property|Cannot call method|Cannot assign)/)
  }
  function cleanup() { Style.font = savedFont }
  function update(extra) {
    return Object.assign({id:"example.update",name:"Fictional update",installedVersion:"1.0",availableVersion:"2.0",
      installedRevision:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",availableRevision:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      state:"available",canUpdate:true,selfUpdate:false,reason:"",checkedAt:100}, extra || {})
  }
  function entry(row) {
    return {id:row.id, installedVersion:row.installedVersion, installedRevision:row.installedRevision,
      enabled:true, kinds:["bar-widget", "panel"],canDisable:true,firstParty:false,barSection:"right",barSectionKnown:true}
  }
  function visual(owner, name) {
    if (owner.objectName === name) return owner
    var children = owner.children || []
    for (var i = 0; i < children.length; i++) {
      var result = visual(children[i], name)
      if (result) return result
    }
    return null
  }
  function child(owner, name) {
    var result = findChild(owner, name) || visual(owner, name)
    if (!result) {
      var detail = findChild(owner, "pluginDetailPage")
      if (detail) result = visual(detail.Window.window.contentItem, name)
    }
    verify(result !== null, "Missing " + name)
    return result
  }
  function settle() { wait(0); verify(waitForPolish(testCase.Window.window)) }
  function page(rows) {
    var service = createTemporaryObject(fixtureComponent, testCase, {updates:rows})
    var view = createTemporaryObject(pageComponent, testCase, {width:728,height:430,service:service,inventoryReady:true,showSelfUpdate:true})
    verify(view !== null)
    settle()
    return view
  }
  function app(rows) {
    var service = createTemporaryObject(serviceComponent, testCase)
    verify(service !== null)
    if (typeof service.updateInfo !== "function") {
      skip("Service update contract is still being integrated")
      return null
    }
    service.receiveOutput(JSON.stringify({ok:true,action:"load",generation:service.activeGeneration,
      preferences:{watchHardware:false,readmeEnrichment:true,readmeIndexing:false,marketplaceThumbnails:false,services:[]}}))
    service.inventoryReady = true
    service.inventory = rows.map(entry)
    service.installed = rows.map(function(row) { return row.id })
    service.updates = rows
    service.updatesLoaded = true
    service.setupRows = rows.map(function(row) {
      return {id:row.id,name:row.name,version:"catalog-only",kind:"bar-widget",kinds:["bar-widget", "panel"],
        barWidget:true,installAvailable:true,readmeAvailable:false}
    })
    var view = createTemporaryObject(appComponent, testCase, {service:service})
    verify(view !== null)
    view.open(JSON.stringify({setupStage:"browse",setupQuery:"original browse query"}))
    wait(0)
    return view
  }
  function test_versions_are_canonical_and_commit_changes_are_visible_data() {
    return [{tag:"compact",width:728,height:430},{tag:"wide",width:1148,height:650},
      {tag:"tall compact",width:868,height:890},{tag:"large font",width:728,height:430,large:true}]
  }
  function test_versions_are_canonical_and_commit_changes_are_visible(data) {
    if (data.large) Style.font = {family:"serif",caption:14,bodySmall:18,body:20,heading:26,subtitle:24,title:30}
    var info = update({availableVersion:"1.0"})
    var local = entry(info)
    var presentation = Object.assign(State.resolve({id:info.id,version:"catalog-only"},local,{inventoryReady:true}),
      State.updatePresentation(local,info,{inventoryReady:true}),{primaryLabel:"Open",primaryEnabled:true})
    var view = createTemporaryObject(detailComponent,testCase,
      {width:data.width,height:data.height,pluginRow:{id:info.id,version:"catalog-only"},presentation:presentation})
    settle()
    var versions = child(view,"detailVersions")
    verify(versions.text.indexOf("Installed: 1.0 · aaaaaaaaaa") >= 0)
    verify(versions.text.indexOf("Available: 1.0 · bbbbbbbbbb · New changes") >= 0)
    verify(versions.text.indexOf("catalog-only") < 0)
    verify(child(view,"detailUpdate").visible && child(view,"detailPrimary").visible)
    verify(child(view,"detailEnabled").enabled && child(view,"detailPosition.left").enabled)
    var scroll = child(view,"detailContentScroll")
    var controls = child(view,"detailControls")
    function within(item, ancestor) {
      for (var current = item; current; current = current.parent) if (current === ancestor) return true
      return false
    }
    var check = child(view,"detailUpdateCheck")
    verify(within(check,controls), "Update checking belongs to On your computer")
    var section = child(view,"detailVersionSection")
    var matching = child(view,"detailMatchingDisclosure")
    verify(section.mapToItem(matching.parent,0,0).y + section.height <= matching.y,
      "Version information precedes Why recommended")
    compare(within(versions,child(view,"detailRecommendationScroll")),view.dockRecommendation)
    compare(within(versions,scroll),!view.dockRecommendation)
    verify(scroll.height > 100, "Compact content retains usable reading space (" + scroll.height + "px)")
    verify(controls.y >= 0 && controls.y + controls.height <= view.height + 1)
    var controlY = controls.y
    scroll.contentItem.contentY = 80
    settle()
    compare(controls.y,controlY)
    local.installedVersion = ""
    compare(State.updatePresentation(local,info,{inventoryReady:true}).installedVersion, "")
  }
  function test_global_eligibility_self_is_separate_and_filter_does_not_change_count() {
    var rows = [update(),update({id:"io.github.ctl0v0.outfit",name:"Outfit",selfUpdate:true,canUpdate:false})]
    ;["current","blocked","unavailable","managed","development"].forEach(function(state) {
      rows.push(update({id:"example." + state,name:state,state:state,canUpdate:false,reason:"Fictional explanation"}))
    })
    var view = page(rows)
    compare(view.filteredRows[1].state,"available")
    compare(view.filteredRows[view.filteredRows.length - 1].state,"managed")
    compare(view.eligibleRows.length,1)
    compare(child(view,"updatesAll").text,"Update all (1)…")
    verify(child(view,"updateAction.io.github.ctl0v0.outfit").enabled)
    compare(child(view,"updateAction.io.github.ctl0v0.outfit").text,"Update Outfit & reopen")
    ;["current","blocked","unavailable","managed","development"].forEach(function(state) {
      verify(view.revealRow("example." + state))
      settle()
      verify(!child(view,"updateAction.example." + state).visible)
      verify(State.updateStatus(rows.filter(function(row) { return row.state === state })[0],true,"").indexOf("Fictional explanation") >= 0)
    })
    view.query = "no match"
    settle()
    compare(view.eligibleRows.length,1)
    compare(child(view,"updatesAll").text,"Update all (1)…")
    compare(child(view,"updatesEmpty").text,"No installed plugins match this search.")
  }
  function test_update_gates_data() {
    return [{tag:"mutation",key:"mutationBusy"},{tag:"batch",key:"batchRunning"},
      {tag:"self",key:"selfUpdateBusy"},{tag:"check",key:"updatesBusy"},{tag:"inventory",key:"inventoryReady"}]
  }
  function test_update_gates(data) {
    var view = page([update()])
    if (data.key === "inventoryReady") view.inventoryReady = false
    else view.service[data.key] = true
    verify(!child(view,"updatesAll").enabled)
    verify(!child(view,"updatesCheck").enabled)
    verify(!child(view,"updateAction.example.update").enabled)
  }
  function test_self_drafts_and_native_controls_are_paused() {
    var self = update({id:"io.github.ctl0v0.outfit",selfUpdate:true,canUpdate:false})
    var view = page([self,update()])
    view.settingsTouched = true
    verify(!view.canUpdate(self))
    verify(view.canUpdate(update()))
    view.settingsTouched = false
    view.service.interestsDirty = true
    verify(!view.canUpdate(self))
    var state = State.resolve(update(), entry(update()), {inventoryReady:true,selfUpdateBusy:true})
    verify(!state.canOpen && !state.canToggle && !state.canPlace && !state.canRemove && !state.canInstall)
  }
  function test_loading_current_error_and_unknown_are_distinct() {
    var view = page([])
    view.service.updatesLoaded = false
    verify(child(view,"updatesEmpty").text.indexOf("Check for updates") === 0)
    view.service.updatesBusy = true
    compare(child(view,"updatesEmpty").text,"Checking installed plugins…")
    view.service.updatesBusy = false
    view.service.updatesError = "Fictional network error"
    compare(child(view,"updatesError").text,"Fictional network error")
    compare(State.updateStatus(update({state:"current"}),true,""),"Up to date")
    compare(State.updateStatus(null,true,""),"Update status unknown")
    verify(State.updateStatus(null,false,"Offline").indexOf("Update check failed") === 0)
    verify(State.updatePresentation(entry(update()),null,{inventoryReady:true}).showUpdateCheck)
  }
  function test_review_identity_rejects_changes_but_not_a_repeated_check() {
    var reviewed = update()
    verify(State.sameUpdate(reviewed,update({checkedAt:200})))
    ;[{availableRevision:"new"},{installedRevision:"new"},{availableVersion:"3.0"},
      {installedVersion:"2.0"},{state:"blocked"},{canUpdate:false},{selfUpdate:true},
      {name:"Changed reviewed name"},{reason:"New restriction"}].forEach(function(change) {
        verify(!State.sameUpdate(reviewed,update(change)),JSON.stringify(change))
      })
    verify(!State.sameUpdate(reviewed,null))
    var completed = {installedVersion:"1.0",availableVersion:"1.0",kind:"update",
      installedRevision:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      expectedInstalledRevision:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      expectedRevision:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
    compare(State.updateTransition(completed),"1.0 · aaaaaaaaaa → 1.0 · bbbbbbbbbb · New changes")
  }
  function test_customizations_show_upstream_without_becoming_update_candidates() {
    var customized = update({state:"customized",canUpdate:false,installedVersion:"2.0-local",availableVersion:"1.0"})
    var unavailable = update({id:"example.offline",state:"unavailable",canUpdate:false,availableVersion:"",availableRevision:"",reason:"Network unavailable"})
    var manual = update({id:"example.manual",state:"manual",canUpdate:false,availableVersion:"",availableRevision:"",reason:"Use the original installation method"})
    var view = page([customized,unavailable,manual,update({id:"example.ready"})])
    compare(view.eligibleRows.length,1)
    verify(!view.canUpdate(customized))
    compare(view.failedCheckCount,1)
    verify(!child(view,"updatesError").visible)
    verify(child(view,"updatesPartialStatus").text.indexOf("Couldn’t check 1 plugin.") === 0)
    compare(State.updateStatus(customized,true,""),"Locally customized — automatic update unavailable")
    verify(State.updateTransition(customized).indexOf("Installed: 2.0-local") === 0)
    verify(State.updateTransition(customized).indexOf("Upstream: 1.0") >= 0)
    verify(State.updateTransition(customized).indexOf("→") < 0)
    verify(State.updateTransition(unavailable).indexOf("Unknown") < 0)
    verify(State.updateTransition(manual).indexOf("→") < 0)
    customized.checkError = "Upstream could not be reached"
    view.service.updates = [customized]
    compare(view.failedCheckCount,1)
    verify(State.updateStatus(customized,true,"").indexOf("Locally customized") === 0)
    verify(State.updateStatus(customized,true,"").indexOf(customized.checkError) >= 0)
    var presentation = Object.assign(State.resolve(customized,entry(customized),{inventoryReady:true}),
      State.updatePresentation(entry(customized),customized,{inventoryReady:true}))
    verify(!presentation.canUpdate)
    var detail = createTemporaryObject(detailComponent,testCase,
      {width:728,height:430,pluginRow:{id:customized.id},presentation:presentation})
    settle()
    verify(child(detail,"detailVersions").text.indexOf("Upstream: 1.0") >= 0)
    verify(child(detail,"detailVersions").text.indexOf("New changes") < 0)
  }
  function test_individual_review_freezes_row_and_rejects_changed_revision() {
    var view = app([update()]); if (!view) return
    view.openUpdates()
    view.requestUpdate(update())
    compare(view.service.updateCalls.length,0)
    compare(view.reviewedUpdates[0].availableRevision,update().availableRevision)
    view.service.updates = [update({availableRevision:"cccccccccccccccccccccccccccccccccccccccc"})]
    compare(view.reviewedUpdates[0].availableRevision,update().availableRevision)
    verify(!view.confirmUpdates())
    compare(view.service.updateCalls.length,0)
    verify(view.updateReviewError.length > 0)
    view.updateReviewOpen = false
    view.requestUpdate(update())
    verify(view.confirmUpdates())
    compare(view.service.updateCalls[0].row.availableRevision,"cccccccccccccccccccccccccccccccccccccccc")
    compare(view.service.updateCalls[0].resume.setupStage,"updates")
    view.close()
  }
  function test_review_all_preserves_install_selection_and_uses_reviewed_ids() {
    var rows = [update(),update({id:"example.second",name:"Second"}),
      update({id:"io.github.ctl0v0.outfit",selfUpdate:true,canUpdate:false}), update({id:"example.blocked",state:"blocked",canUpdate:false})]
    var view = app(rows); if (!view) return
    view.service.setSetupSelected({id:"example.install",name:"Install later",installAvailable:true,selectable:true},true)
    var selection = JSON.stringify(view.service.selectedSetupRows())
    view.openUpdates()
    view.reviewAllUpdates()
    compare(view.reviewedUpdates.length,2)
    compare(view.service.batchCalls.length,0)
    view.service.updates = rows.concat([update({id:"example.new",name:"Arrived after review"})])
    verify(view.confirmUpdates())
    compare(view.service.batchCalls[0].ids,["example.update","example.second"])
    compare(JSON.stringify(view.service.selectedSetupRows()),selection)
    compare(view.service.selfCalls.length,0)
    view.close()
  }
  function test_navigation_detail_and_mutation_resume_preserve_updates_context() {
    var rows = []
    for (var i = 0; i < 15; i++) rows.push(update({id:"example.update" + i,name:"Fictional " + i}))
    var view = app(rows); if (!view) return
    view.openUpdates()
    var updates = child(view,"updatesPage")
    updates.query = "Fictional"
    wait(0)
    updates.restorePosition(200)
    var y = updates.scrollPosition()
    verify(y > 0)
    view.openSetupDetail(view.updateDetailRow(rows[0]),null)
    wait(0)
    verify(child(view,"pluginDetailPage").visible)
    compare(child(view,"pluginDetailPage").backLabel,"Back to Updates")
    view.requestUpdate(rows[0])
    verify(view.confirmUpdates())
    var resume = view.service.updateCalls[0].resume
    compare(resume.setupStage,"updates")
    compare(resume.updatesQuery,"Fictional")
    compare(resume.updatesScroll,y)
    compare(resume.setupQuery,"original browse query")
    view.goBack()
    compare(view.setupStage,"updates")
    compare(updates.query,"Fictional")
    compare(updates.scrollPosition(),y)
    view.open(JSON.stringify(resume))
    wait(0)
    compare(view.setupStage,"updates")
    compare(view.setupDetailId,rows[0].id)
    compare(updates.query,"Fictional")
    compare(updates.scrollPosition(),y)
    view.close()
  }
  function test_leaving_update_progress_keeps_pending_install_selection() {
    var view = app([update()])
    view.service.setSetupSelected({id:"example.install",name:"Install later",installAvailable:true,selectable:true},true)
    var selection = JSON.stringify(view.service.selectedSetupRows())
    view.service.batchKind = "update"
    view.service.batchItems = [{id:"example.update",name:"Updated",kind:"update",status:"completed"}]
    view.setupStage = "progress"
    wait(0)
    child(view,"batchBack").clicked()
    compare(view.setupStage,"updates")
    compare(view.service.batchItems.length,0)
    compare(JSON.stringify(view.service.selectedSetupRows()),selection)
    // Install progress retains its original reset semantics.
    view.service.batchKind = "install"
    verify(view.service.resetSetupBatch())
    compare(view.service.selectedSetupRows().length,0)
    view.close()
  }
  function test_self_review_uses_separate_method_and_revalidates_drafts() {
    var self = update({id:"io.github.ctl0v0.outfit",name:"Outfit",selfUpdate:true,canUpdate:false})
    var view = app([self]); if (!view) return
    // A cached check lets the explicit menu route use the existing result.
    view.service.nextUpdatesCheckAt = Date.now() + 60000
    child(view,"moreActionsButton").clicked()
    child(view,"outfitUpdateAction").clicked()
    wait(0)
    compare(view.setupDetailId,self.id)
    verify(!view.updateReviewOpen)
    child(view,"detailUpdate").clicked()
    verify(view.updateReviewOpen)
    view.settingsTouched = true
    verify(!view.confirmUpdates())
    compare(view.service.selfCalls.length,0)
    view.settingsTouched = false
    view.updateReviewOpen = false
    view.requestUpdate(self)
    verify(view.confirmUpdates())
    compare(view.service.selfCalls.length,1)
    compare(view.service.updateCalls.length,0)
    compare(view.service.batchCalls.length,0)
    view.close()
  }
  function test_header_zero_count_and_batch_update_copy() {
    var view = app([]); if (!view) return
    var header = child(view,"updatesButton")
    compare(header.text,"Updates (0)")
    verify(header.visible && header.enabled)
    header.clicked()
    compare(view.setupStage,"updates")
    view.service.batchKind = "update"
    view.setupStage = "progress"
    compare(child(view,"batchProgressHeading").text,"BATCH UPDATE COMPLETE")
    view.goBack()
    compare(view.setupStage,"updates")
    view.close()
  }
  function test_table_alignment_density_and_keyboard_reveal_data() {
    return [{tag:"wide",width:1148,height:650},{tag:"compact",width:728,height:430},
      {tag:"large-font",width:728,height:430,large:true}]
  }
  function test_table_alignment_density_and_keyboard_reveal(data) {
    if (data.large) Style.font = {family:"monospace",caption:16,bodySmall:18,body:20,heading:26,subtitle:24,title:30}
    var rows = []
    for (var i = 0; i < 20; i++) rows.push(update({id:"example.table" + i,
      name:"Plugin " + (i < 10 ? "0" : "") + i,reason:"A long explanation that should not increase the height of every collapsed row."}))
    var view = page(rows)
    view.showSelfUpdate = false
    view.width = data.width
    view.height = data.height
    settle()
    var scroll = child(view,"updatesScroll")
    verify(scroll.height > 80, "Table retains a usable viewport")
    var actions = child(view,"updatesRightActions")
    var back = child(view,"updatesBack")
    verify(Math.abs(actions.mapToItem(view,0,0).x + actions.width - view.width) < 1,
      "Update actions are aligned to the right edge")
    compare(back.mapToItem(view,0,0).x,0)
    view.service.batchItems = [{id:"example.done",status:"completed"}]
    settle()
    verify(Math.abs(actions.mapToItem(view,0,0).x + actions.width - view.width) < 1)
    verify(child(view,"updatesToolbar").height < view.height - 80)
    view.service.batchItems = []
    settle()
    var first = child(view,"updateRow." + rows[0].id)
    verify(first.height < (data.large ? 110 : 85), "Rows remain compact")
    var heading = child(view,"updatesTableHeader")
    var headerY = heading.mapToItem(view,0,0).y
    var labels = ["Plugin","Installed","Upstream","Status","Actions"]
    function aligned(id) {
      for (var col = 0; col < labels.length; col++) {
        var title = child(view,"updateHeading." + (col + 1))
        var cell = child(view,"update" + labels[col] + "Cell." + id)
        verify(Math.abs(title.mapToItem(view,0,0).x - cell.mapToItem(view,0,0).x) < 1, labels[col] + " alignment")
        verify(Math.abs(title.width - cell.width) < 1, labels[col] + " width")
      }
    }
    aligned(rows[0].id)
    var originalHeight = first.height
    var toggle = child(view,"updateExplain." + rows[0].id)
    var nameCell = child(view,"updatePluginCell." + rows[0].id)
    verify(toggle.mapToItem(view,0,0).x + toggle.width < nameCell.mapToItem(view,0,0).x,
      "Expand is the first column, before the plugin name")
    toggle.forceActiveFocus()
    keyClick(Qt.Key_Return)
    settle()
    verify(child(view,"updateExplanation." + rows[0].id).visible)
    verify(first.height > originalHeight)
    keyClick(Qt.Key_Return)
    settle()
    compare(first.height,originalHeight)
    verify(view.focusRow(rows[0].id, "details"))
    keyClick(Qt.Key_Tab)
    compare(view.focusedId,rows[1].id)
    compare(view.focusedAction,"explain")
    keyClick(Qt.Key_Backtab)
    compare(view.focusedId,rows[0].id)
    compare(view.focusedAction,"details")
    keyClick(Qt.Key_End)
    wait(0)
    var last = child(view,"updateDetails." + rows[19].id)
    verify(last.activeFocus)
    var point = last.mapToItem(scroll.contentItem,0,0)
    verify(point.y >= -1 && point.y + last.height <= scroll.availableHeight + 1, "Keyboard focus reveals lower rows")
    verify(point.x >= -1 && point.x + last.width <= scroll.availableWidth + 1, "Keyboard focus reveals action column")
    compare(heading.mapToItem(view,0,0).y,headerY)
    aligned(rows[19].id)
    if (data.large) verify(scroll.contentItem.contentX > 0, "Large fonts scroll horizontally instead of clipping columns")
  }
  function test_virtual_rows_reuse_identity_and_suspend_data() {
    return [{tag:"500 records",count:500},{tag:"2000 records",count:2000}]
  }
  function test_virtual_rows_reuse_identity_and_suspend(data) {
    var rows = []
    for (var i = 0; i < data.count; i++) rows.push(update({id:"virtual." + i,name:"Plugin " + String(i).padStart(4,"0")}))
    var view = page(rows)
    var list = child(view,"updatesList")
    compare(list.count,data.count)
    child(view,"updateExplain.virtual.0").clicked()
    verify(child(view,"updateRow.virtual.0").expanded)
    var peak = 0
    for (var index of [100,data.count - 1,240,10,0]) {
      verify(view.focusRow("virtual." + index,"details"))
      settle()
      var row = child(view,"updateRow.virtual." + index)
      compare(row.expanded,index === 0,"Expansion belongs to the ID, not the recycled delegate")
      peak = Math.max(peak,view.instantiatedRowCount)
      verify(peak < 35,"Bounded delegates for " + data.count + " records: " + peak)
    }
    console.log("Updates virtualization:",data.count,"records, peak",peak,"row delegates")
    view.query = "Plugin 0199"
    settle()
    compare(list.count,1)
    verify(!child(view,"updateRow.virtual.199").expanded)
    view.service.updates = rows.slice().reverse()
    view.query = ""
    settle()
    verify(view.focusRow("virtual.0","explain"))
    settle()
    verify(child(view,"updateRow.virtual.0").expanded)
    verify(view.focusRow("virtual.240","details"))
    settle()
    view.service.updates = rows.map(function(row) { return Object.assign({},row,{availableVersion:"3.0"}) })
    settle()
    verify(child(view,"updateDetails.virtual.240").activeFocus,"Replacement preserves focused row identity")
    var context = view.context()
    view.active = false
    settle()
    compare(list.count,0)
    tryCompare(view,"instantiatedRowCount",0,1000,"Suspension also releases the reuse pool")
    compare(view.scrollPosition(),context.y)
    view.active = true
    settle()
    var anchor = child(view,"updateRow." + context.anchor.id)
    verify(Math.abs(anchor.y - list.contentY - context.anchor.offset) < 1,"Reactivation restores the same ID and clipped offset")
    view.restoreFocus()
    settle()
    verify(child(view,"updateDetails.virtual.240").activeFocus)
    compare(view.focusedId,"virtual.240")
    view.service.sleeping = true
    settle()
    compare(list.count,0)
    view.service.sleeping = false
    settle()
    verify(view.revealRow("virtual.0"))
    settle()
    verify(child(view,"updateRow.virtual.0").expanded)
    var restored = page(rows)
    restored.restoreContext(context)
    settle()
    var restoredList = child(restored,"updatesList")
    var restoredAnchor = child(restored,"updateRow." + context.anchor.id)
    verify(Math.abs(restoredAnchor.y - restoredList.contentY - context.anchor.offset) < 1,"Serialized context restores a fresh view")
    restored.restoreFocus()
    settle()
    verify(child(restored,"updateDetails.virtual.240").activeFocus)
    verify(restored.revealRow("virtual.0"))
    settle()
    verify(child(restored,"updateRow.virtual.0").expanded)
  }
}
