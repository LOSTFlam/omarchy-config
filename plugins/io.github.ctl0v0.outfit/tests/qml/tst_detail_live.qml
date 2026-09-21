import QtQuick
import QtQuick.Window
import QtTest
import "../.." as Plugin
import "../../ui" as Ui

// Production app + Service, with the suite's inert process/file/host stubs.
// ConfirmDialog is the existing signal-only stub: exercise its Cancel/Confirm
// callbacks and default selection, without claiming native dialog key coverage.
TestCase {
  id: testCase
  name: "LiveDetailWiring"
  when: windowShown
  Component { id: serviceComponent; Plugin.Service {} }
  Component { id: appComponent; Ui.OutfitApp {} }
  Component {
    id: shellComponent
    QtObject {
      property int summons: 0
      property int hides: 0
      function summon(id, payload) { summons++; return true }
      function hide(id) { hides++; return true }
      function isPluginOpen(id) { return true }
    }
  }
  function init() {
    failOnWarning(/(TypeError|ReferenceError|Binding loop|Cannot read property|Cannot call method|Cannot assign)/)
  }
  function listing(extra) {
    return Object.assign({id:"example.live",name:"Live wiring fixture",description:"A fictional plugin for real app wiring.",
      kind:"bar-widget",kinds:["bar-widget", "panel"],barWidget:true,installAvailable:true,
      installed:true,enabled:true,readmeAvailable:false,listingCommit:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      repo:"https://github.com/example/live",marketplaceUrl:"https://plugins.omarchy.org/plugin.html?id=example.live",
      recommendationScore:83,score:72,stars:12,likes:7,views:90,copies:3,
      readmeSummary:"A distinct cached README summary with enough words to describe this fictional integration.",
      discoverySetup:"A fictional prerequisite",matchedInterests:[{id:"interest.fixture",label:"Drawing tablet",reason:"stylus in README"}],
      matchCause:"new-listing",unread:true}, extra || {})
  }
  function entry(extra) {
    return Object.assign({id:"example.live",enabled:true,kinds:["bar-widget", "panel"],
      canDisable:true,firstParty:false,barSection:"right",barSectionKnown:true,active:false}, extra || {})
  }
  function child(owner, name) {
    var value = findChild(owner, name)
    // Bound inline-component repeater delegates belong to the page's visual
    // tree, rather than the outer app's QObject ownership tree.
    if (!value) {
      var detail = findChild(owner, "pluginDetailPage")
      if (detail) value = walk(detail, function(item) { return item.objectName === name })
    }
    verify(value !== null, "Missing " + name)
    return value
  }
  function page(view) { return child(view, "pluginDetailPage") }
  function settle(view) {
    wait(0)
    verify(waitForPolish(page(view).Window.window))
  }
  function walk(item, predicate) {
    if (predicate(item)) return item
    var children = item.children || []
    for (var i = 0; i < children.length; i++) {
      var found = walk(children[i], predicate)
      if (found) return found
    }
    return null
  }
  function dialog(view) {
    var result = walk(page(view).Window.window.contentItem, function(item) {
      return item.opened === true && item.confirmed !== undefined && item.canceled !== undefined
    })
    verify(result !== null, "A production confirmation must be open")
    compare(result.selectedIndex, 0, "Cancel is the default")
    return result
  }
  function click(view, name) {
    settle(view)
    var item = child(view, name)
    verify(item.visible && item.enabled, name + " must be actionable")
    mouseClick(item, item.width / 2, item.height / 2)
    settle(view)
  }
  function bodyClick(view, name) {
    var item = child(view, name)
    var scroll = child(view, "detailContentScroll")
    var flick = scroll.contentItem
    var position = item.mapToItem(flick, 0, 0)
    flick.contentY = Math.max(0, Math.min(flick.contentY + position.y - 20, flick.contentHeight - flick.height))
    click(view, name)
  }
  function make(local, row, payload, discoveryEnabled) {
    row = row || listing()
    var service = createTemporaryObject(serviceComponent, testCase, {discoveryEnabled:discoveryEnabled === true})
    service.receiveOutput(JSON.stringify({ok:true,action:"load",generation:service.activeGeneration,
      preferences:{watchHardware:false,readmeEnrichment:true,readmeIndexing:false,marketplaceThumbnails:false,
        services:[],browseDensity:"list"}}))
    service.hasAnalyzed = true
    service.inventoryReady = true
    service.inventory = local ? [local] : []
    service.installed = local ? [local.id] : []
    service.setupRows = [row]
    service.setupTotal = 1
    service.shell = createTemporaryObject(shellComponent, testCase)
    service.matches = {rows:[row],total:1,unread:1,page:1,pageCount:1,partial:false,lastCheckedAt:100}
    service.matchesLoaded = true
    service.inputsLoaded = true
    service.inputs = {revision:1,criteria:[{id:"interest.fixture",kind:"topic",label:"Drawing tablet",terms:["stylus"],enabled:true}],
      detected:[],probes:[],ignoredSignals:[],serviceChoices:[],featureChoices:[]}
    service.criteriaRevision = 1
    service.readmePluginId = row.id
    service.readmeContent = "Fixture documentation.\n\n" + new Array(40).join("A long cached paragraph for scroll and persistent-control checks.\n\n")
    var view = createTemporaryObject(appComponent, testCase, {service:service})
    verify(view !== null)
    view.open(JSON.stringify(Object.assign({setupStage:"browse",workspaceView:"browse",setupSort:"name",setupPage:3}, payload || {})))
    // Keep the opening query in flight: no invented backend response may alter
    // search/page state during this focused UI interaction.
    settle(view)
    return view
  }
  function inspect(view, row, invoker) {
    view.openSetupDetail(row || view.service.setupRows[0], invoker || null)
    settle(view)
    verify(page(view).visible)
    compare(page(view).parent.row.id, view.setupDetailId)
    compare(page(view).width, page(view).parent.parent.width)
  }
  function test_async_media_slot_grows_after_initial_empty_selection() {
    var row = listing({matchedInterests:[]})
    var view = make(entry(), row)
    inspect(view, row)
    compare(page(view).pluginRow.matchLabel, "")
    verify(!page(view).mediaAvailable)
    view.service.pendingReadmeId = row.id
    settle(view)
    verify(page(view).mediaAvailable)
    var media = walk(page(view), function(item) { return item.objectName === "readmeMediaPreview" })
    verify(media !== null)
    verify(media.implicitHeight > 0 && media.height > 0, "Loading media must reserve space after an empty initial selection")
    verify(child(view, "detailGallery").height >= media.height)
    view.close()
  }
  function finishMutation(view, inventory) {
    var service = view.service
    verify(service.mutationActive)
    var request = service.activeMutation
    service.receiveMutationOutput(JSON.stringify({ok:true,action:request.action,generation:request.generation,
      responseKind:"mutation",inventoryAuthoritative:true,inventory:inventory,installed:inventory.map(function(item) { return item.id }),
      unavailable:[],operation:{pluginId:request.pluginId,status:"completed",observed:true},error:"",notice:"Fixture completed"}))
    var process = child(service, "mutationWorker")
    process.running = false
    process.exited(0, 0)
    settle(view)
  }

  function test_canonical_state_wins_over_frozen_listing_data() {
    return [
      {tag:"enabled window", local:entry(), action:"open", widget:true},
      {tag:"disabled window", local:entry({enabled:false}), action:"enable", widget:true},
      {tag:"inactive full bar", local:entry({enabled:false,kinds:["bar", "bar-widget"],canDisable:false}), action:"activate", widget:false},
      {tag:"service only", local:entry({kinds:["service"]}), action:"", widget:false},
      {tag:"widget only", local:entry({kinds:["bar-widget"]}), action:"", widget:true},
      {tag:"builtin unconfirmed window", local:entry({firstParty:true,enabled:false,canDisable:false}), action:"", widget:true},
      {tag:"not installed despite listing", local:null, action:"install", widget:true}
    ]
  }
  function test_canonical_state_wins_over_frozen_listing(data) {
    var view = make(data.local)
    inspect(view)
    var state = view.detailPresentation(view.setupDetailRow)
    compare(state.primaryAction, data.action)
    compare(state.installed, data.local !== null)
    compare(state.widget, data.widget)
    compare(page(view).presentation.primaryAction, data.action)
    compare(child(view, "detailPrimary").visible, data.action !== "")
    compare(child(view, "detailPosition.left").visible, data.widget)
    if (data.action === "activate") {
      verify(state.exclusive && state.canActivateBar)
      verify(!child(view, "detailEnabled").visible)
    }
    compare(view.setupDetailRow.installed, true, "Listing snapshot stays frozen")
    var metadata = view.detailMetadata(view.setupDetailRow)
    compare(metadata.summary, listing().readmeSummary)
    compare(metadata.requirements, "A fictional prerequisite")
    compare(metadata.readmeText, view.service.readmeContent)
    verify(metadata.sourceAvailable && metadata.marketplaceAvailable)
    compare(page(view).pluginRow.stars, 12)
    view.close()
  }
  function test_open_acceptance_is_separate_and_never_mutates_or_refocuses() {
    var view = make(entry())
    inspect(view)
    var service = view.service
    var inventory = JSON.stringify(service.inventory)
    var snapshot = JSON.stringify(view.setupDetailRow)
    service.error = "Existing query error"
    service.notice = "Existing query notice"
    service.prepareEditorRestore(view.editorResumePayload(view.setupDetailId), view.setupDetailId)
    click(view, "detailPrimary")
    var jobs = child(service, "pluginOpenJobs")
    verify(jobs.active)
    compare(jobs.activeRequest.action, "open-plugin")
    compare(jobs.activeRequest.pluginId, view.setupDetailId)
    compare(service.editorRestorePayload, null, "Explicit Open cancels old restoration")
    verify(!service.mutationActive && !service.mutationQueue.length)
    compare(child(view, "detailPrimary").text, "Opening…")
    verify(!child(view, "detailPrimary").enabled)
    var back = child(view, "detailBack")
    back.forceActiveFocus()
    var owner = jobs.activeRequest
    jobs.receiveLine(JSON.stringify({ok:true,action:"open-plugin",generation:owner.generation,
      pluginId:owner.pluginId,openState:"accepted",error:""}))
    var process = child(jobs, "backgroundWorker")
    process.running = false
    process.exited(0, 0)
    settle(view)
    compare(child(view, "detailPrimary").text, "Open")
    verify(back.activeFocus, "Acceptance must not take focus")
    compare(JSON.stringify(service.inventory), inventory)
    compare(JSON.stringify(view.setupDetailRow), snapshot)
    compare(service.error, "Existing query error")
    compare(service.notice, "Existing query notice")
    compare(service.shell.summons, 0)
    compare(service.shell.hides, 0)
    compare(service.editorRestorePayload, null)
    compare(service.mutationGeneration, 0)
    view.close()
  }
  function test_enable_and_full_bar_activation_dispatch_native_actions() {
    var view = make(entry({enabled:false}))
    inspect(view)
    click(view, "detailPosition.left")
    verify(!view.service.mutationActive, "Choosing a disabled widget's position must not enable it")
    click(view, "detailPrimary")
    compare(view.service.activeMutation.action, "enable-plugin")
    compare(view.service.activeMutation.barSection, "left")
    view.close()
    var bar = make(entry({enabled:false,kinds:["bar", "bar-widget"],canDisable:false}))
    inspect(bar)
    click(bar, "detailPrimary")
    compare(bar.pendingAction, "activate")
    verify(!bar.service.mutationActive)
    verify(dialog(bar).message.indexOf("replaces") >= 0)
    dialog(bar).canceled()
    verify(!bar.actionConfirmOpen && !bar.service.mutationActive)
    click(bar, "detailPrimary")
    dialog(bar).confirmed()
    settle(bar)
    compare(bar.service.activeMutation.action, "enable-plugin")
    verify(!bar.service.activeMutation.barSection, "A full bar must never receive widget placement")
    bar.close()
  }
  function test_install_draft_maps_to_confirmed_service_request_data() {
    return [{tag:"enabled at left", enable:true, section:"left"}, {tag:"install disabled", enable:false, section:"center"}]
  }
  function test_install_draft_maps_to_confirmed_service_request(data) {
    var view = make(null, listing(), {selectedId:"example.live",installDraft:{enable:data.enable,section:data.section}})
    compare(page(view).installEnabled, data.enable)
    compare(page(view).installSection, data.section)
    click(view, "detailPrimary")
    compare(view.pendingAction, "install")
    compare(view.pendingInstallEnabled, data.enable)
    compare(view.pendingInstallSection, data.enable ? data.section : "")
    verify(!view.service.mutationActive)
    dialog(view).confirmed()
    settle(view)
    compare(view.service.activeMutation.action, "install-plugin")
    compare(view.service.activeMutation.pluginId, "example.live")
    compare(view.service.activeMutation.enableAfter === true, data.enable)
    compare(view.service.activeMutation.barSection || "", data.enable ? data.section : "")
    compare(view.service.activeMutation.reviewedRevision, listing().listingCommit)
    compare(view.service.editorRestorePayload.installDraft.enable, data.enable)
    compare(view.service.editorRestorePayload.installDraft.section, data.section)
    view.close()
  }
  function test_remove_cancel_confirm_and_completed_remove_keep_selected_detail() {
    var view = make(entry())
    inspect(view)
    click(view, "detailUninstall")
    compare(view.pendingAction, "remove")
    verify(!view.service.mutationActive)
    dialog(view).canceled()
    verify(!view.actionConfirmOpen && !view.service.mutationActive)
    compare(view.setupDetailId, "example.live")
    click(view, "detailUninstall")
    dialog(view).confirmed()
    settle(view)
    compare(view.service.activeMutation.action, "remove-plugin")
    verify(!child(view, "detailUninstall").enabled)
    finishMutation(view, [])
    compare(view.setupDetailId, "example.live")
    compare(view.service.setupDetailId, "example.live")
    verify(page(view).visible)
    verify(!page(view).presentation.installed)
    compare(page(view).presentation.primaryAction, "install")
    verify(child(view, "detailPrimary").enabled)
    verify(!child(view, "detailUninstall").visible)
    compare(view.setupDetailRow.installed, true)
    view.close()
  }
  function test_protected_uninstall_hidden_and_revalidated_at_confirmation_data() {
    return [{tag:"builtin", id:"example.live", firstParty:true}, {tag:"self", id:"io.github.ctl0v0.outfit", firstParty:false}]
  }
  function test_protected_uninstall_hidden_and_revalidated_at_confirmation(data) {
    var row = listing({id:data.id})
    var view = make(entry({id:data.id,firstParty:data.firstParty}), row)
    inspect(view)
    verify(!child(view, "detailUninstall").visible)
    view.requestAction("remove", row)
    verify(!view.actionConfirmOpen && !view.service.mutationActive)
    // A stale/forged confirmation must still pass the canonical checks.
    view.pendingAction = "remove"
    view.actionTarget = row
    view.confirmAction()
    verify(!view.service.mutationActive)
    if (data.firstParty) {
      view.service.inventory = [entry()]
      view.inspectorActionError = ""
      click(view, "detailUninstall")
      view.service.inventory = [entry({firstParty:true})]
      dialog(view).confirmed()
      verify(!view.service.mutationActive)
    }
    view.close()
  }
  function test_pending_recovery_and_batch_ownership_use_real_service_state() {
    var view = make(entry({enabled:false,installedRevision:"a".repeat(40)}))
    inspect(view)
    view.service.setPluginOperation("example.live", {pending:true,status:"checking",action:"enable-plugin",message:"Checking native state"})
    settle(view)
    verify(!child(view, "detailEnabled").enabled && !child(view, "detailUninstall").enabled)
    verify(!child(view, "detailPrimary").visible || !child(view, "detailPrimary").enabled)
    compare(page(view).statusMessage, "Checking native state")
    view.service.setPluginOperation("example.live", {pending:false,status:"partial",error:"Enable failed",lastAction:"install-plugin",
      lastRequest:{action:"install-plugin",enableAfter:true,barSection:"left",reviewedRevision:"a".repeat(40)}})
    settle(view)
    compare(page(view).presentation.primaryAction, "retry")
    compare(page(view).statusMessage, "Enable failed")
    click(view, "detailPrimary")
    compare(view.service.activeMutation.action, "enable-plugin", "Partial install recovery must not reinstall")
    view.close()
    var batch = make(entry({enabled:false}))
    inspect(batch)
    batch.service.batchItems = [{id:"example.live",status:"partial"}]
    settle(batch)
    compare(page(batch).presentation.primaryAction, "progress")
    click(batch, "detailPrimary")
    compare(batch.setupStage, "progress")
    verify(!batch.service.mutationActive)
    batch.close()
  }
  function test_unknown_inventory_disables_mutating_and_open_controls() {
    var view = make(entry())
    inspect(view)
    view.service.inventoryReady = false
    settle(view)
    verify(!child(view, "detailPrimary").visible || !child(view, "detailPrimary").enabled)
    for (var i = 0; i < 3; i++) verify(!child(view, "detailPosition." + ["left", "center", "right"][i]).enabled)
    verify(!child(view, "detailEnabled").enabled && !child(view, "detailUninstall").enabled)
    verify(page(view).statusMessage.indexOf("not confirmed") >= 0)
    verify(!view.service.mutationActive && !view.service.pluginOpenBusy)
    view.close()
  }
  function test_controls_stay_visible_without_scrolling_and_do_not_move_with_body_data() {
    return [{tag:"normal", width:1180,height:760}, {tag:"minimum",width:760,height:540}]
  }
  function test_controls_stay_visible_without_scrolling_and_do_not_move_with_body(data) {
    var view = make(entry(), listing(), {windowWidth:data.width,windowHeight:data.height})
    inspect(view)
    var surface = page(view)
    var controls = child(view, "detailControls")
    var scroll = child(view, "detailContentScroll")
    compare(scroll.contentItem.contentY, 0)
    var names = ["detailPrimary", "detailUninstall", "detailEnabled", "detailPosition.left", "detailPosition.center", "detailPosition.right"]
    for (var i = 0; i < names.length; i++) {
      var item = child(view, names[i])
      var point = item.mapToItem(surface, 0, 0)
      verify(item.visible && item.width > 0 && item.height > 0)
      verify(point.x >= -1 && point.y >= -1 && point.x + item.width <= surface.width + 1
        && point.y + item.height <= surface.height + 1, names[i] + " is clipped")
    }
    var before = controls.mapToItem(surface, 0, 0)
    verify(surface.documentationExpanded, "Documentation is expanded on open")
    scroll.contentItem.contentY = Math.max(0, scroll.contentItem.contentHeight - scroll.height)
    settle(view)
    verify(scroll.contentItem.contentY > 0)
    var after = controls.mapToItem(surface, 0, 0)
    compare(after.x, before.x)
    compare(after.y, before.y)
    view.close()
  }
  function test_matches_review_is_explicit_and_back_preserves_origin_and_focus_data() {
    return [{tag:"browse",workspace:"browse",tab:"ideas"}, {tag:"matches",workspace:"discover",tab:"matches"}]
  }
  function test_matches_review_is_explicit_and_back_preserves_origin_and_focus(data) {
    var view = make(null, listing(), {workspaceView:data.workspace,discoverTab:data.tab,setupQuery:"stylus",setupSort:"name",setupPage:3}, true)
    var surface = page(view)
    var invoker = data.workspace === "browse" ? view.browseCards()[0]
      : walk(surface.Window.window.contentItem, function(item) { return item.text === "Review listing" && item.clicked !== undefined })
    verify(invoker !== null && invoker !== undefined)
    var saved = view.editorResumePayload("")
    compare(saved.setupQuery, "stylus")
    compare(saved.setupSort, "name")
    compare(saved.setupPage, 3)
    var rows = JSON.stringify(view.service.setupRows)
    inspect(view, view.service.setupRows[0], invoker)
    verify(surface.pluginRow.matchUnread)
    bodyClick(view, "detailMatchingDisclosure")
    bodyClick(view, "detailDocumentationDisclosure")
    compare(view.service.unreadMatches, 1)
    compare(view.service.pendingMatchReview, null)
    compare(JSON.stringify(view.service.setupRows), rows)
    click(view, "detailBack")
    compare(view.setupDetailId, "")
    compare(view.workspaceView, data.workspace)
    compare(view.discoverTab, data.tab)
    var returned = view.editorResumePayload("")
    compare(returned.setupQuery, saved.setupQuery)
    compare(returned.setupSort, saved.setupSort)
    compare(returned.setupPage, saved.setupPage)
    tryVerify(function() { return invoker.activeFocus }, 1000, "Back must return focus to its invoking control")
    inspect(view, view.service.setupRows[0], invoker)
    bodyClick(view, "detailReview")
    compare(view.service.pendingMatchReview.pluginIds, ["example.live"])
    compare(view.service.unreadMatches, 1, "A request alone must not fake a review acknowledgement")
    view.close()
  }
}
