import QtQuick
import QtTest
import "../.." as Plugin
import "../../ui" as Ui

TestCase {
  id: testCase
  name: "FirstRunStartup"
  when: windowShown
  Component { id: component; Plugin.Service {} }
  Component { id: appComponent; Ui.OutfitApp {} }
  Component { id: activityComponent; Ui.BackgroundActivity {} }
  function visualChild(item, name) {
    if (item.objectName === name) return item
    for (var child of item.children || []) {
      var found = visualChild(child, name)
      if (found) return found
    }
    return null
  }
  function respond(object, fields) {
    var result = {ok:true,action:object.activeAction,generation:object.activeGeneration}
    for (var key in (fields || {})) result[key] = fields[key]
    object.receiveOutput(JSON.stringify(result))
  }
  function service(preferences, extra) {
    var object = createTemporaryObject(component, testCase)
    object.editorOpened()
    verify(!object.backgroundBusy && !object.inventoryBusy && !object.catalogBusy)
    var fields = {preferences:preferences || {watchHardware:true,readmeEnrichment:true,readmeIndexing:true},
      catalogCount:10,catalogSource:"bundled",generatedAt:"fixture-v1",catalogBuiltAt:"fixture-date",
      setup:{rows:[{id:"fixture.one",name:"One",installAvailable:true}],total:10},searchPack:{state:"missing"}}
    for (var key in (extra || {})) fields[key] = extra[key]
    respond(object, fields)
    object.startStartup()
    return object
  }
  function finish(object, name, fields) {
    var job = findChild(object, name)
    verify(job.active, name)
    var request = JSON.parse(JSON.stringify(job.activeRequest))
    var result = {ok:true,action:request.action,generation:request.generation}
    for (var key in fields) result[key] = fields[key]
    job.receiveLine(JSON.stringify(result))
    var process = findChild(job, "backgroundWorker")
    process.running = false
    process.exited(0, 0)
    return request
  }
  function inventory(object) {
    return finish(object, "inventoryJobs", {inventoryAuthoritative:true,
      inventory:[{id:"fixture.installed",enabled:true}],installed:["fixture.installed"],unavailable:[]})
  }
  function catalog(object) { finish(object, "catalogJobs", {catalogCount:10,catalogSource:"cache",generatedAt:"fixture-v1"}) }
  function progress(object, name, phase, counts) {
    var job = findChild(object, name)
    var event = {responseKind:"progress",final:false,action:job.activeRequest.action,
      generation:job.generation,sequence:1,phase:phase,message:"Untrusted probe detail"}
    for (var key in counts) event[key] = counts[key]
    findChild(job, "backgroundParser").read(JSON.stringify(event) + "\n")
  }
  function completeCoverage() {
    return {eligible:100,indexed:93,pending:0,failed:0,unavailable:7,due:0,
      documents:{total:100,indexed:93,processed:100,pending:0,unavailable:7,failed:0,skipped:0}}
  }
  function test_catalog_source_does_not_gate_browsing_data() {
    return [{tag:"bundled",source:"bundled"}, {tag:"builtin-alias",source:"builtin"}, {tag:"cached",source:"cache"}]
  }
  function test_catalog_source_does_not_gate_browsing(data) {
    var object = service({watchHardware:false,readmeEnrichment:false}, {catalogSource:data.source})
    verify(object.canBrowse)
    compare(object.catalogSource, data.source)
    verify(!object.hasAnalyzed)
    verify(object.search("metadata", "", "all", "all"))
    compare(object.activeAction, "search")
  }
  function test_actual_primary_install_and_query_work_during_optional_hardware() {
    var object = service()
    var view = createTemporaryObject(appComponent, testCase, {service:object})
    var row = {id:"fixture.available",name:"Available",installAvailable:true,listingCommit:"a".repeat(40)}
    verify(!view.primaryEnabled(row))
    inventory(object)
    verify(object.backgroundBusy && object.catalogBusy && !object.hasAnalyzed)
    verify(view.primaryEnabled(row))
    verify(view.detailPresentation(row).primaryEnabled)
    view.requestSetup("metadata", "", "relevance", 1)
    verify(object.queryBusy)
    verify(view.primaryEnabled(row), "Even an interactive query must not gate installation")
    verify(object.installPlugin(row, "", {}, false))
    object.dispatchMutation()
    verify(object.mutationActive)
    verify(object.backgroundBusy && object.catalogBusy)
  }
  function test_every_startup_worker_routes_correlated_progress_and_source_metadata() {
    var object = service()
    progress(object, "inventoryJobs", "inventory", {processed:1,total:4})
    progress(object, "catalogJobs", "catalog", {bytesReceived:512,bytesTotal:1024})
    progress(object, "backgroundJobs", "scan", {processed:2,total:8})
    compare(object.measuredProgress(object.startupActivity.inventory), 0.25)
    compare(object.measuredProgress(object.startupActivity.catalog), 0.5)
    compare(object.measuredProgress(object.startupActivity.hardware), 0.25)
    finish(object, "catalogJobs", {catalogCount:10,catalogSource:"cache",generatedAt:"fixture-v2",
      catalogBuiltAt:"2026-09-18T00:00:00Z",sourceDate:"2026-09-17T00:00:00Z"})
    compare(object.catalogBuiltAt, "2026-09-18T00:00:00Z")
    compare(object.sourceDate, "2026-09-17T00:00:00Z")
    verify(object.tryPrepareSearch())
    progress(object, "searchPreparationJobs", "download", {bytesReceived:10,bytesTotal:40})
    compare(object.measuredProgress(object.startupProgress), 0.25)
    finish(object, "searchPreparationJobs", {searchPack:{state:"ready",schemaVersion:1,version:"20260918T000000Z",
      docCount:100,assetUrl:"https://example.invalid/seed",due:false,nextCheckAt:Date.now()/1000+86400},
      catalogSource:"cache",catalogBuiltAt:"2026-09-18T01:00:00Z",sourceDate:"2026-09-18T01:00:00Z",
      readmeIndex:{eligible:100,indexed:93,pending:7,due:7,documents:{total:100,indexed:93,processed:93,pending:7,skipped:7}}})
    compare(object.searchPack.docCount, 100)
    compare(object.searchPack.version, "20260918T000000Z")
    compare(object.sourceDate, "2026-09-18T01:00:00Z")
    finish(object, "backgroundJobs", {profile:[],inventoryAuthoritative:false})
    if (object.requestActive) respond(object, {})
    object.nextIndexAt = 0
    verify(object.tryIndexReadmes())
    progress(object, "readmeIndexJobs", "index", {processed:100,total:100,
      documents:{total:100,indexed:94,processed:100,pending:0,failed:0,unavailable:0,skipped:6}})
    compare(object.measuredProgress(object.startupProgress), 0.94)
    var popup = createTemporaryObject(activityComponent, testCase, {service:object})
    verify(popup.coverage().indexOf("94 / 100 checked") >= 0)
    verify(JSON.stringify(object.startupActivity).indexOf("Untrusted") < 0)
  }
  function test_seed_exclusions_remain_pending_until_local_indexing_finishes_data() {
    return [{tag:"older-summary",processed:100,pending:0}, {tag:"pending-summary",processed:93,pending:7}]
  }
  function test_seed_exclusions_remain_pending_until_local_indexing_finishes(data) {
    var object = service({watchHardware:false,readmeEnrichment:true})
    inventory(object)
    catalog(object)
    verify(object.tryPrepareSearch())
    finish(object, "searchPreparationJobs", {searchPack:{state:"ready",docCount:100},
      readmeIndex:{eligible:100,indexed:93,pending:7,unavailable:0,failed:0,due:7,documents:{
        total:100,indexed:93,processed:data.processed,pending:data.pending,unavailable:0,failed:0,skipped:7}}})
    verify(!object.libraryPrepared)
    compare(object.documentCounts.processed, 93)
    compare(object.documentCounts.pending, 7)
    verify(!object.preparingSearch && !object.indexingBusy)
    if (object.requestActive) respond(object, {})
    object.nextIndexAt = 0
    verify(object.tryIndexReadmes())
    finish(object, "readmeIndexJobs", {readmeIndex:completeCoverage()})
    verify(object.libraryPrepared)
    object.nextIndexAt = 0
    for (var i = 0; i < 5; i++) {
      verify(!object.tryPrepareSearch())
      verify(!object.tryIndexReadmes())
    }
  }
  function test_paused_disabled_and_warm_receipts_never_force_busy_or_fake_legacy_ready_data() {
    return [{tag:"paused",prefs:{watchHardware:false,readmeEnrichment:true,readmeIndexing:false}},
      {tag:"disabled",prefs:{watchHardware:false,readmeEnrichment:false}},
      {tag:"warm-ready",prefs:{watchHardware:false,readmeEnrichment:true}}]
  }
  function test_paused_disabled_and_warm_receipts_never_force_busy_or_fake_legacy_ready(data) {
    var object = service(data.prefs, {catalogSource:"cache",readmeIndex:completeCoverage(),
      searchPack:{state:"ready",due:false,nextCheckAt:Date.now()/1000+86400}})
    inventory(object)
    catalog(object)
    if (object.requestActive) respond(object, {})
    if (object.indexingEnabled) verify(object.tryPrepareSearch())
    object.nextIndexAt = 0
    for (var i = 0; i < 5; i++) {
      verify(!object.tryPrepareSearch())
      verify(!object.tryIndexReadmes())
      findChild(object, "searchPreparationDelay").triggered()
      findChild(object, "indexingDelay").triggered()
    }
    verify(object.libraryPrepared)
    verify(!object.preparingSearch && !object.indexingBusy && !object.backgroundBusy)
    verify(!object.startupBannerVisible)
    var status = JSON.parse(findChild(object, "serviceIpc").status())
    verify(status.canBrowse && status.canManagePlugins)
    verify(!status.ready && !object.hasAnalyzed)
  }
  function test_deferred_seed_retry_allows_local_indexing_and_lock_contention_is_bounded() {
    var object = service({watchHardware:false,readmeEnrichment:true})
    catalog(object)
    object.searchPack = {state:"error",due:false,nextCheckAt:Date.now()/1000+86400}
    verify(object.tryPrepareSearch())
    verify(!object.preparingSearch)
    verify(object.searchPreparationSettled)
    if (object.requestActive) respond(object, {})
    object.nextIndexAt = 0
    verify(object.tryIndexReadmes())
    object.editorClosed()
    object.editorOpened()
    object.searchPack = {state:"none",due:true}
    object.searchPreparationSettled = false
    object.searchPreparationAttempted = false
    for (var i = 0; i < 4; i++) {
      object.nextSearchPreparationAt = 0
      verify(object.tryPrepareSearch())
      finish(object, "searchPreparationJobs", {searchPack:{state:"none",busy:true}})
    }
    verify(object.searchPreparationSettled)
    verify(!object.preparingSearch)
    verify(!object.tryPrepareSearch())
    verify(object.nextIndexAt > Date.now()+29000)
  }
  function test_load_publishes_before_checks_and_all_lanes_are_independent() {
    var object = service()
    verify(object.canBrowse)
    verify(!object.canManagePlugins)
    verify(!object.hasAnalyzed)
    compare(object.setupRows[0].id, "fixture.one")
    verify(object.inventoryBusy && object.catalogBusy && object.backgroundBusy)
    compare(findChild(object, "inventoryJobs").activeRequest.action, "verify-inventory")
    compare(findChild(object, "catalogJobs").activeRequest.action, "catalog-refresh")
    verify(!object.queryBusy)
    verify(object.quickSetup("typing immediately", "", "relevance", 1))
    inventory(object)
    verify(object.canManagePlugins)
    verify(!object.hasAnalyzed)
    compare(object.activeAction, "quick-setup")
    var revision = object.inventoryRevision
    finish(object, "backgroundJobs", {profile:[],inventoryAuthoritative:false,inventory:[],installed:[],unavailable:["inventory"]})
    verify(object.inventoryReady)
    compare(object.inventoryRevision, revision)
    compare(object.inventory[0].id, "fixture.installed")
    verify(object.hasAnalyzed)
    verify(!object.pendingEnrichment)
    verify(object.catalogBusy)
    verify(!object.refresh("", ""))
  }
  function test_optional_failure_and_late_scan_cannot_downgrade_mutation_inventory() {
    var object = service()
    inventory(object)
    object.inventoryRevision++
    object.inventory = [{id:"fixture.mutated"}]
    var revision = object.inventoryRevision
    finish(object, "backgroundJobs", {ok:false,error:"Fixture optional probe failed"})
    verify(object.canBrowse && object.canManagePlugins)
    compare(object.inventoryRevision, revision)
    compare(object.inventory[0].id, "fixture.mutated")
    compare(object.startupActivity.hardware.state, "error")
    verify(object.retryStartupLane("hardware"))
    object.inventoryRevision++
    finish(object, "backgroundJobs", {profile:[],inventoryAuthoritative:true,inventory:[],installed:[]})
    compare(object.inventory[0].id, "fixture.mutated")
    compare(object.inventoryRevision, revision + 1)
  }
  function test_seed_precedes_crawl_and_network_never_occupies_query_lane() {
    var object = service({watchHardware:false,readmeEnrichment:true})
    verify(!object.backgroundBusy)
    verify(!object.tryIndexReadmes())
    catalog(object)
    verify(object.tryPrepareSearch())
    verify(object.preparingSearch)
    verify(!object.tryIndexReadmes())
    verify(object.quickSetup("metadata still works", "", "relevance", 1))
    compare(findChild(object, "searchPreparationJobs").activeRequest.streamProgress, true)
    finish(object, "searchPreparationJobs", {ok:false,error:"Fixture offline"})
    verify(object.searchPreparationSettled)
    verify(object.nextIndexAt > Date.now() + 29000)
    verify(!object.tryIndexReadmes())
    respond(object, {})
    object.nextIndexAt = 0
    verify(object.tryIndexReadmes())
    verify(object.canBrowse)
  }
  function test_seed_failure_survives_local_fallback_and_retry_is_not_hammered_data() {
    return [{tag:"offline",state:"error"}, {tag:"unavailable",state:"unavailable"},
      {tag:"error-field",state:"none"}, {tag:"transport-failure",state:"transport"}]
  }
  function test_seed_failure_survives_local_fallback_and_retry_is_not_hammered(data) {
    var object = service({watchHardware:false,readmeEnrichment:true})
    inventory(object)
    catalog(object)
    verify(object.tryPrepareSearch())
    var fields = data.state === "transport" ? {ok:false,error:"Transport unavailable"}
      : {searchPack:{state:data.state,error:"Fixture failure",due:false,nextCheckAt:Date.now()/1000+300}}
    finish(object, "searchPreparationJobs", fields)
    var job = findChild(object, "searchPreparationJobs")
    var generation = job.generation
    var deadline = object.searchPackRetryAt
    verify(deadline > Date.now()+299000)
    var popup = createTemporaryObject(activityComponent, testCase, {service:object})
    verify(popup.description("documentation").indexOf("Public search library unavailable") >= 0)
    if (object.requestActive) respond(object, {})
    object.nextIndexAt = 0
    verify(object.tryIndexReadmes())
    verify(popup.description("documentation").indexOf("Adding searchable documentation") >= 0)
    verify(popup.description("documentation").indexOf("Public search library unavailable") >= 0)
    finish(object, "readmeIndexJobs", {readmeIndex:{eligible:100,indexed:0,pending:88,failed:12,due:88,
      documents:{total:100,indexed:0,processed:12,pending:88,failed:12,unavailable:0,skipped:0}}})
    compare(object.startupActivity.documentation.state, "waiting")
    verify(object.searchPackFailed)
    verify(!object.preparingSearch && !object.indexingBusy)
    verify(popup.description("documentation").indexOf("Public search library unavailable") >= 0)
    verify(object.startupSummary.indexOf("search library unavailable") >= 0)
    var retry = visualChild(popup.contentItem, "activityRetry-documentation")
    verify(!retry.enabled)
    for (var i = 0; i < 5; i++) {
      verify(!object.retryStartupLane("documentation"))
      findChild(object, "searchPreparationDelay").triggered()
    }
    object.editorClosed()
    object.editorOpened()
    verify(!object.tryPrepareSearch())
    compare(job.generation, generation)
    compare(object.searchPackRetryAt, deadline)
    verify(object.canBrowse && object.canManagePlugins)
    object.searchPreparationRetryAt = Date.now() - 1
    object.searchPack = {state:"error",error:"Fixture failure",due:true,nextCheckAt:Date.now()/1000-1}
    verify(object.retryStartupLane("documentation"))
    finish(object, "searchPreparationJobs", {searchPack:{state:"ready",error:"",due:false,nextCheckAt:Date.now()/1000+86400},
      readmeIndex:completeCoverage()})
    verify(!object.searchPackFailed)
    compare(popup.seedFailureText(), "")
  }
  function test_interrupted_receipt_and_close_resume_do_not_create_failure_backoff_data() {
    return [{tag:"legacy-unfinished",state:"none",priorFailure:false},
      {tag:"preparing-receipt",state:"preparing",priorFailure:false},
      {tag:"preparing-after-old-failure",state:"preparing",priorFailure:true}]
  }
  function test_interrupted_receipt_and_close_resume_do_not_create_failure_backoff(data) {
    var object = service({watchHardware:false,readmeEnrichment:true},
      {searchPack:{state:data.state,due:false,nextCheckAt:Date.now()/1000+300,lastAttemptAt:Date.now()/1000}})
    catalog(object)
    object.searchPreparationFailed = data.priorFailure
    verify(object.tryPrepareSearch(), "An unfinished receipt is not a successful check or real failure")
    verify(object.preparingSearch)
    progress(object, "searchPreparationJobs", "download", {bytesReceived:409600,bytesTotal:7662590})
    var job = findChild(object, "searchPreparationJobs")
    var generation = job.generation
    object.editorClosed()
    compare(object.searchPackFailed, data.priorFailure)
    compare(object.searchPackRetryAt, 0)
    object.editorOpened()
    verify(object.tryPrepareSearch())
    verify(object.preparingSearch)
    compare(job.generation, generation + 1)
  }
  function test_pause_disable_close_and_mutation_cancel_seed_without_losing_search() {
    var object = service({watchHardware:false,readmeEnrichment:true,unknownSetting:{kept:true}})
    catalog(object)
    respond(object, {})
    verify(object.tryPrepareSearch())
    verify(object.setIndexingPaused(true))
    verify(!object.preparingSearch)
    verify(!object.tryPrepareSearch())
    verify(object.activeRequest.preferences.unknownSetting.kept)
    respond(object, {preferences:object.activeRequest.preferences})
    verify(!object.indexingEnabled)
    verify(object.setIndexingPaused(false))
    respond(object, {preferences:object.activeRequest.preferences})
    verify(object.tryPrepareSearch())
    object.editorClosed()
    verify(!object.preparingSearch)
    verify(!object.tryPrepareSearch())
    object.editorOpened()
    verify(object.tryPrepareSearch())
    object.mutationActive = true
    verify(!object.preparingSearch)
    verify(!object.tryPrepareSearch())
    object.mutationActive = false
    verify(object.tryPrepareSearch())
    object.preferences = {readmeEnrichment:false}
    verify(!object.preparingSearch)
    verify(!object.tryIndexReadmes())
    verify(object.canBrowse)
  }
  function test_unavailable_documents_are_finished_and_receipt_contains_no_profile() {
    var object = service({watchHardware:false,readmeEnrichment:true})
    inventory(object)
    catalog(object)
    verify(object.tryPrepareSearch())
    object.profile = [{name:"PRIVATE DEVICE"}]
    finish(object, "searchPreparationJobs", {searchPack:{state:"ready"},readmeIndex:{documents:{
      total:100,indexed:93,processed:100,pending:0,unavailable:7,failed:0,skipped:0}}})
    verify(object.libraryPrepared)
    verify(object.startupSummary.indexOf("Library prepared") >= 0)
    var receipt = JSON.parse(findChild(object, "startupReceiptFile").contents)
    compare(receipt.catalogRevision, "fixture-v1")
    verify(receipt.completedAt > 0)
    compare(Object.keys(receipt).length, 3)
    var popup = createTemporaryObject(activityComponent, testCase, {service:object})
    verify(popup.coverage().indexOf("7 unavailable") >= 0)
    verify(popup.description("documentation").indexOf("Library prepared") >= 0)
  }
  function test_measured_progress_only_and_no_private_probe_details() {
    var object = service()
    compare(object.measuredProgress({}), -1)
    compare(object.measuredProgress({total:0,processed:1}), -1)
    compare(object.measuredProgress({total:10,processed:3}), 0.3)
    compare(object.measuredProgress({bytesTotal:100,bytesReceived:50}), 0.5)
    object.activityProgress("hardware", {phase:"scan",message:"PRIVATE DEVICE AA:BB:CC:DD:EE:FF",total:4,processed:2})
    verify(JSON.stringify(object.startupActivity).indexOf("PRIVATE") < 0)
    verify(object.startupSummary.indexOf("PRIVATE") < 0)
  }
  function test_retry_is_lane_specific_and_inventory_can_verify_before_analysis() {
    var object = service({watchHardware:false,readmeEnrichment:false})
    finish(object, "inventoryJobs", {ok:false})
    verify(!object.canManagePlugins)
    verify(object.canBrowse)
    verify(object.retryStartupLane("inventory"))
    verify(!object.backgroundBusy)
    inventory(object)
    verify(object.canManagePlugins)
    respond(object, {})
    verify(object.verifyMutationState())
    compare(object.activeAction, "verify-inventory")
    verify(!object.hasAnalyzed)
  }
  function test_old_query_metadata_cannot_undo_catalog_or_seed_completion() {
    var object = service({watchHardware:false,readmeEnrichment:true})
    verify(object.quickSetup("fixture", "", "relevance", 1))
    finish(object, "catalogJobs", {catalogCount:20,generatedAt:"fixture-v2",fetchedAt:200})
    verify(object.tryPrepareSearch())
    finish(object, "searchPreparationJobs", {searchPack:{state:"ready"},readmeIndex:{documents:{
      total:20,indexed:20,processed:20,pending:0,unavailable:0,failed:0}}})
    respond(object, {catalogCount:10,generatedAt:"fixture-v1",fetchedAt:100,readmeIndex:{documents:{total:0}}})
    compare(object.catalogCount, 20)
    compare(object.generatedAt, "fixture-v2")
    compare(object.fetchedAt, 200)
    verify(object.libraryPrepared)
  }
  function test_activity_constrains_height_and_keyboard_reveals_controls() {
    var object = service()
    for (var lane of ["catalog", "inventory", "hardware", "documentation"])
      object.setActivity(lane, {state:"error"})
    var popup = createTemporaryObject(activityComponent, testCase,
      {service:object,width:300,maximumHeight:260})
    popup.open()
    wait(0)
    verify(popup.height <= 260)
    var close = findChild(popup, "activityClose")
    close.forceActiveFocus()
    wait(0)
    var scroll = findChild(popup, "activityScroll")
    verify(scroll.contentItem.contentY > 0)
    var point = close.mapToItem(scroll, 0, 0)
    verify(point.y >= -1 && point.y + close.height <= scroll.height + 1)
    popup.close()
  }
  function test_header_height_is_fixed_dismiss_does_not_stop_jobs_and_warm_open_is_quiet() {
    var object = service()
    var view = createTemporaryObject(appComponent, testCase, {service:object})
    view.open("{}")
    wait(0)
    var header = findChild(view, "workspaceHeader")
    var height = header.height
    verify(object.startupBannerVisible)
    var activity = findChild(view, "backgroundActivity")
    verify(!activity.visible)
    var details = findChild(view, "startupDetails")
    verify(details.visible && details.enabled)
    details.clicked()
    tryCompare(activity, "visible", true)
    verify(activity.contentItem.visible && activity.width > 0 && activity.height > 0)
    verify(!activity.modal)
    keyClick(Qt.Key_Escape)
    tryCompare(activity, "visible", false)
    verify(view.opened)
    compare(header.height, height)
    findChild(view, "startupDismiss").clicked()
    verify(object.startupDismissed)
    findChild(view, "moreActionsButton").clicked()
    var activityAction = findChild(view, "backgroundActivityAction")
    verify(activityAction.visible && activityAction.enabled)
    activityAction.clicked()
    tryCompare(activity, "visible", true)
    findChild(activity, "activityClose").clicked()
    tryCompare(activity, "visible", false)
    verify(object.inventoryBusy && object.catalogBusy && object.backgroundBusy)
    compare(header.height, height)
    verify(view.canBrowse)
    verify(!view.canManagePlugins)
    inventory(object)
    verify(view.canManagePlugins)
    compare(header.height, height)
    view.close()
    var warm = service({watchHardware:false,readmeEnrichment:true}, {catalogSource:"cache",searchPack:{state:"ready"}})
    verify(!warm.startupBannerVisible)
    verify(!warm.hasAnalyzed)
    verify(warm.canBrowse)
  }
  function test_actual_app_popup_fits_minimum_window_without_header_jump() {
    var object = service()
    var view = createTemporaryObject(appComponent, testCase, {service:object})
    view.open(JSON.stringify({windowWidth:760,windowHeight:540}))
    wait(30)
    var header = findChild(view, "workspaceHeader")
    var frame = header.Window.window
    compare(frame.width, 760)
    compare(frame.height, 540)
    var headerHeight = header.height
    findChild(view, "startupDetails").clicked()
    var popup = findChild(view, "backgroundActivity")
    wait(0)
    var point = popup.background.mapToItem(frame.contentItem, 0, 0)
    verify(point.x >= 0 && point.y >= 0)
    verify(point.x + popup.width <= frame.width + 0.5)
    verify(point.y + popup.height <= frame.height + 0.5)
    findChild(popup, "activityClose").forceActiveFocus()
    keyClick(Qt.Key_End)
    var scroll = findChild(popup, "activityScroll")
    var close = findChild(popup, "activityClose")
    var buttonPoint = close.mapToItem(scroll.contentItem, 0, 0)
    verify(buttonPoint.y >= -0.5 && buttonPoint.y + close.height <= scroll.availableHeight + 0.5)
    close.clicked()
    tryCompare(popup, "visible", false)
    compare(header.height, headerHeight)
    verify(view.opened)
    view.close()
  }
}
