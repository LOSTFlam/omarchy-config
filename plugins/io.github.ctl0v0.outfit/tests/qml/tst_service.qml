import QtQuick
import QtTest
import "../.." as Plugin

TestCase {
  id: testCase
  name: "ServiceLifecycle"
  when: windowShown
  Component { id: serviceComponent; Plugin.Service {} }

  function service() { return createTemporaryObject(serviceComponent, testCase) }
  function respond(object, result) {
    result.generation = object.activeRequest.generation
    result.action = object.activeRequest.action
    result.ok = true
    object.receiveOutput(JSON.stringify(result))
  }
  function finishJob(object, fields, jobName) {
    var jobs = findChild(object, jobName || "backgroundJobs")
    var process = findChild(jobs, "backgroundWorker")
    var result = fields
    result.ok = true
    result.action = jobs.activeRequest.action
    result.generation = jobs.activeRequest.generation
    jobs.receiveLine(JSON.stringify(result))
    process.running = false
    process.exited(0, 0)
  }
  function test_local_scan_does_not_occupy_interactive_query_lane() {
    var object = service()
    verify(object.requestActive)
    verify(object.analyze())
    verify(object.backgroundBusy)
    compare(object.activeAction, "load")
    respond(object, {setup: {rows: [{id:"example.cached"}], groups:[], sections:[], total:1}})
    verify(object.cacheLoaded)
    compare(object.setupRows.length, 1)
    verify(!object.hasAnalyzed)
    verify(object.quickSetup("search while scanning", "", "likes", 1))
    compare(object.activeAction, "quick-setup")
    verify(object.backgroundBusy)
    finishJob(object, {profile: [], inventory: [{id:"example.local"}], installed:["example.local"],
      unavailable: [], inventoryAuthoritative:true, fetchedAt:100})
    verify(object.hasAnalyzed)
    verify(object.inventoryReady)
    compare(object.inventory[0].id, "example.local")
    verify(object.boardRefreshPending)
    // This old response was made before the authoritative scan completed.
    respond(object, {inventory:[], installed:[], setup:{rows:[{id:"obsolete"}]}})
    compare(object.inventory[0].id, "example.local")
    verify(object.setupRows[0].id !== "obsolete")
  }
  function test_saved_density_restores_and_early_choice_wins_over_startup() {
    var restored = service()
    respond(restored, {preferences:{browseDensity:"compact"}})
    compare(restored.browseDensity, "compact")
    var early = service()
    early.setBrowseDensity("dense")
    verify(!early.flushDensitySave())
    respond(early, {preferences:{browseDensity:"comfortable"}})
    compare(early.browseDensity, "dense")
    verify(early.flushDensitySave())
    compare(early.activeAction, "save-density")
    respond(early, {browseDensity:"dense"})
    verify(!early.densitySavePending)
  }
  function test_list_choice_restores_and_switches_back_to_grid_without_losing_selection() {
    var object = service()
    respond(object, {preferences:{browseDensity:"list"}})
    compare(object.browseDensity, "list")
    object.setupGrouping = "category"
    object.setupDetailId = "example.selected"
    object.setBrowseDensity("dense")
    verify(object.flushDensitySave())
    respond(object, {browseDensity:"dense"})
    object.setBrowseDensity("list")
    verify(object.flushDensitySave())
    respond(object, {browseDensity:"list"})
    compare(object.setupGrouping, "category")
    compare(object.setupDetailId, "example.selected")
    verify(!object.requestActive)
  }
  function test_density_saves_coalesce_and_do_not_requery_or_replace_view_state() {
    var object = service()
    respond(object, {preferences:{browseDensity:"comfortable"}})
    object.setupRows = [{id:"example.kept"}]
    object.setupPage = 3
    object.setupGrouping = "category"
    object.setupDetailId = "example.kept"
    object.inspectorSnapshot = {id:"example.kept"}
    object.setBrowseDensity("compact")
    object.setBrowseDensity("dense")
    verify(object.flushDensitySave())
    compare(object.activeRequest.browseDensity, "dense")
    respond(object, {browseDensity:"dense"})
    verify(!object.requestActive)
    verify(!object.boardRefreshPending)
    compare(object.setupPage, 3)
    compare(object.setupGrouping, "category")
    compare(object.setupRows[0].id, "example.kept")
    compare(object.inspectorSnapshot.id, "example.kept")
  }
  function test_older_density_ack_does_not_revert_latest_choice() {
    var object = service()
    respond(object, {})
    object.setBrowseDensity("compact")
    verify(object.flushDensitySave())
    object.setBrowseDensity("dense")
    respond(object, {browseDensity:"compact"})
    compare(object.browseDensity, "dense")
    verify(object.densitySavePending)
    verify(object.flushDensitySave())
    respond(object, {browseDensity:"dense"})
    verify(!object.densitySavePending)
  }
  function test_failed_density_save_retains_live_choice_and_can_retry() {
    var object = service()
    respond(object, {})
    object.error = "Earlier inventory error"
    object.setBrowseDensity("dense")
    verify(object.flushDensitySave())
    object.receiveOutput(JSON.stringify({action:"save-density", generation:object.activeGeneration,
      ok:false, error:"Storage unavailable"}))
    compare(object.browseDensity, "dense")
    verify(Boolean(object.densitySaveError))
    compare(object.error, "Earlier inventory error")
    object.setBrowseDensity("dense")
    verify(object.flushDensitySave())
    respond(object, {browseDensity:"dense"})
    compare(object.densitySaveError, "")
  }
  function test_indexing_is_separate_from_interactive_search_and_stops_on_close() {
    var object = service()
    respond(object, {catalogCount:100})
    object.hasAnalyzed = true
    object.startupStarted = true
    object.searchPreparationSettled = true
    object.editorOpened()
    verify(object.filtersExpanded)
    verify(object.tryIndexReadmes())
    verify(object.indexingBusy)
    verify(!object.backgroundBusy)
    verify(object.quickSetup("README term", "", "stars", 1))
    compare(object.activeAction, "quick-setup")
    object.editorClosed()
    verify(!object.indexingBusy)
    compare(object.readmeIndexError, "")
    verify(!object.tryIndexReadmes())
  }
  function test_index_pause_is_persisted_and_does_not_disable_cached_search() {
    var object = service()
    respond(object, {catalogCount:100})
    object.hasAnalyzed = true
    object.startupStarted = true
    object.searchPreparationSettled = true
    object.editorOpened()
    verify(object.tryIndexReadmes())
    verify(object.setIndexingPaused(true))
    verify(!object.indexingBusy)
    compare(object.activeRequest.preferences.readmeIndexing, false)
    var saved = object.activeRequest.preferences
    respond(object, {preferences:saved})
    verify(!object.indexingEnabled)
    compare(object.preferences.readmeEnrichment, true)
    verify(!object.tryIndexReadmes())
  }
  function test_index_results_only_update_index_state_and_failures_back_off() {
    var object = service()
    respond(object, {catalogCount:100})
    object.hasAnalyzed = true
    object.startupStarted = true
    object.searchPreparationSettled = true
    object.editorOpened()
    object.discoveryRows = [{id:"example.frozen"}]
    verify(object.tryIndexReadmes())
    finishJob(object, {readmeIndex:{indexed:12, eligible:100, due:88}}, "readmeIndexJobs")
    compare(object.readmeIndex.indexed, 12)
    compare(object.discoveryRows[0].id, "example.frozen")
    compare(object.notice, "")
    object.finishIndexing({ok:false, error:"Fixture storage unavailable"}, {})
    verify(object.nextIndexAt > Date.now() + 290000)
    compare(object.error, "")
    verify(!object.tryIndexReadmes())
    verify(object.quickSetup("still searchable", "", "name", 1))
  }
  function test_missing_inventory_blocks_mutation_and_preserves_last_known_state() {
    var object = service()
    respond(object, {})
    verify(!object.startPluginAction("enable-plugin", "example.plugin", {}, "", false, false, ""))
    compare(object.mutationQueue.length, 0)
    object.inventory = [{id:"example.existing"}]
    verify(object.analyze())
    finishJob(object, {profile:[], inventory:[], installed:[], unavailable:["installed plugins"], inventoryAuthoritative:false})
    verify(!object.inventoryReady)
    compare(object.inventory[0].id, "example.existing")
  }
  function test_reopening_fresh_session_does_not_rescan() {
    var object = service()
    respond(object, {})
    object.hasAnalyzed = true
    object.lastHardwareCheckAt = Date.now()
    object.panelOpened()
    verify(!object.backgroundBusy)
    object.lastHardwareCheckAt = Date.now() - 61000
    object.panelOpened()
    verify(object.backgroundBusy)
  }
  function test_late_startup_reply_cannot_clear_fresh_inventory() {
    var object = service()
    verify(object.analyze())
    finishJob(object, {profile:[{id:"fictional-device"}], inventory:[{id:"example.installed"}],
      installed:["example.installed"], unavailable:[], inventoryAuthoritative:true})
    respond(object, {profile:[], inventory:[], installed:[], unavailable:[]})
    compare(object.profile[0].id, "fictional-device")
    compare(object.inventory[0].id, "example.installed")
    verify(object.inventoryReady)
  }
  function test_settings_ack_survives_concurrent_inventory_change() {
    var object = service()
    respond(object, {})
    verify(object.savePreferences({readmeEnrichment:false}, "settings"))
    object.inventory = [{id:"example.fresh"}]
    object.inventoryRevision++
    respond(object, {profile:[], inventory:[], installed:[], preferences:{readmeEnrichment:false}})
    compare(object.preferences.readmeEnrichment, false)
    compare(object.inventory[0].id, "example.fresh")
  }
  function test_missing_background_executable_leaves_retryable_state() {
    var object = service()
    respond(object, {})
    verify(object.analyze())
    var jobs = findChild(object, "backgroundJobs")
    findChild(jobs, "backgroundLaunchDeadline").triggered()
    verify(!object.backgroundBusy)
    verify(object.error.indexOf("could not start") >= 0)
    verify(object.analyze())
  }

  function test_discovery_freezes_has_back_and_keeps_cards_on_failure() {
    var object = service()
    object.discoveryEnabled = true
    respond(object, {})
    object.hasAnalyzed = true
    verify(object.ensureDiscovery())
    compare(object.activeAction, "discover")
    respond(object, {discovery:{rows:[{id:"example.first"}]}})
    verify(object.ensureDiscovery())
    verify(!object.requestActive)
    compare(object.discoveryRows[0].id, "example.first")
    verify(object.discoverNext())
    respond(object, {discovery:{rows:[{id:"example.second"}]}})
    verify(object.discoveryCanGoBack)
    verify(object.discoverBack())
    compare(object.discoveryRows[0].id, "example.first")
    verify(object.discoverNext())
    object.receiveOutput(JSON.stringify({ok:false, action:"discover", generation:object.activeRequest.generation, error:"offline"}))
    compare(object.discoveryRows[0].id, "example.first")
    compare(object.discoveryError, "offline")
  }
  function test_direct_install_and_enable_defaults_are_explicit_and_replacements_opt_in() {
    var object = service()
    respond(object, {})
    object.inventoryReady = true
    var row = {id:"example.ordinary",installAvailable:true,listingCommit:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
    verify(object.installPlugin(row, "", {}))
    tryCompare(object, "mutationActive", true)
    compare(object.activeMutation.enableAfter, true)
    compare(object.pluginOperation(row.id).lastAction, "install-plugin")
    var replacement = service()
    respond(replacement, {})
    replacement.inventoryReady = true
    row = {id:"example.replacement",installAvailable:true,kinds:["bar"],listingCommit:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
    verify(replacement.installPlugin(row, "", {}))
    tryCompare(replacement, "mutationActive", true)
    verify(replacement.activeMutation.enableAfter !== true)
  }
  function test_partial_install_recovery_enables_without_reinstalling() {
    var object = service()
    respond(object, {})
    object.inventoryReady = true
    object.inventory = [{id:"example.widget",enabled:false,canDisable:true,kinds:["bar-widget"],installedRevision:"a".repeat(40)}]
    object.setPluginOperation("example.widget", {pending:false,status:"partial",lastAction:"install-plugin",
      lastRequest:{enableAfter:true,barSection:"left",reviewedRevision:"a".repeat(40)}})
    verify(object.retryPluginOperation({id:"example.widget",barWidget:true}, {}))
    tryCompare(object, "mutationActive", true)
    compare(object.activeMutation.action, "enable-plugin")
    compare(object.activeMutation.barSection, "left")
    compare(object.activeMutation.reviewedRevision, "a".repeat(40))
  }
  function test_install_recovery_never_accepts_or_activates_a_different_revision() {
    var object = service()
    respond(object, {})
    object.inventoryReady = true
    object.inventory = [{id:"example.widget",enabled:true,installedRevision:"b".repeat(40)}]
    object.installed = ["example.widget"]
    object.setPluginOperation("example.widget", {pending:false,status:"failed",lastAction:"install-plugin",
      lastRequest:{enableAfter:true,reviewedRevision:"a".repeat(40)}})
    object.reconcileTerminalOutcomes()
    compare(object.pluginOperation("example.widget").status, "failed")
    verify(!object.retryPluginOperation({id:"example.widget"}, {}))
    verify(!object.mutationActive)
    object.beginPluginOperation("install-plugin", "example.widget", "", true)
    object.setPluginOperation("example.widget", {desiredRevision:"a".repeat(40)})
    verify(!object.desiredPluginStateObserved("example.widget"))
    object.inventory = [{id:"example.widget",enabled:true,installedRevision:"a".repeat(40)}]
    verify(object.desiredPluginStateObserved("example.widget"))
  }
  function test_batch_retry_retains_revision_and_refuses_mismatched_installation() {
    var object = service()
    respond(object, {})
    object.inventoryReady = true
    object.inventory = [{id:"example.widget",enabled:false,installedRevision:"b".repeat(40)}]
    object.batchItems = [{id:"example.widget",status:"queued",activate:true,reviewedRevision:"a".repeat(40)}]
    object.batchRunning = true
    object.dispatchNextBatchItem()
    compare(object.batchItems[0].status, "failed")
    verify(!object.mutationActive)
    object.inventory = [{id:"example.widget",enabled:false,installedRevision:"a".repeat(40)}]
    object.batchItems = [{id:"example.widget",status:"queued",activate:true,reviewedRevision:"a".repeat(40)}]
    object.dispatchNextBatchItem()
    tryCompare(object, "mutationActive", true)
    compare(object.activeMutation.action, "enable-plugin")
    compare(object.activeMutation.reviewedRevision, "a".repeat(40))
  }
  function test_diagnostics_does_not_replace_browse_or_inventory() {
    var object = service()
    respond(object, {})
    object.setupRows = [{id:"example.row"}]
    object.inventory = [{id:"example.installed"}]
    verify(object.loadDiagnostics())
    respond(object, {diagnostics:{schema:1},notice:"ready"})
    compare(object.diagnostics.schema, 1)
    compare(object.setupRows[0].id, "example.row")
    compare(object.inventory[0].id, "example.installed")
  }
  function test_verification_clears_a_satisfied_terminal_failure() {
    var object = service()
    respond(object, {})
    object.hasAnalyzed = true
    object.inventoryReady = true
    object.inventory = [{id:"example.widget",enabled:true,canDisable:true,kinds:["bar-widget"],barSectionKnown:true,barSection:"left"}]
    object.setPluginOperation("example.widget", {pending:false,status:"failed",error:"late result",lastAction:"enable-plugin",
      lastRequest:{enableAfter:true,barSection:"left"}})
    verify(object.retryPluginOperation({id:"example.widget",barWidget:true}, {}))
    compare(object.activeAction, "verify-inventory")
    respond(object, {inventoryAuthoritative:true, inventory:object.inventory, installed:["example.widget"], unavailable:[]})
    compare(object.pluginOperation("example.widget").status, "completed")
    compare(object.pluginOperation("example.widget").error, "")
  }
  function test_reset_batch_detaches_failed_operation_recovery() {
    var object = service()
    respond(object, {})
    object.batchItems = [{id:"example.widget",status:"failed"}]
    object.setPluginOperation("example.widget", {pending:false,status:"failed",lastAction:"install-plugin",
      lastRequest:{batchItem:true,enableAfter:true}})
    verify(object.resetSetupBatch())
    compare(object.batchItems.length, 0)
    compare(object.pluginOperation("example.widget").lastRequest.batchItem, false)
    compare(object.pluginOperation("example.widget").lastAction, "install-plugin")
  }
  function test_replacement_activation_recovery_respects_previous_opt_in() {
    var object = service()
    respond(object, {})
    object.inventoryReady = true
    object.inventory = [{id:"example.bar",enabled:false,canDisable:false,kinds:["bar"],installedRevision:"a".repeat(40)}]
    object.setPluginOperation("example.bar", {pending:false,status:"partial",lastAction:"install-plugin",
      lastRequest:{enableAfter:true,reviewedRevision:"a".repeat(40)}})
    verify(object.retryPluginOperation({id:"example.bar",kinds:["bar"]}, {}))
    tryCompare(object, "mutationActive", true)
    compare(object.activeMutation.action, "enable-plugin")
  }
  function test_queue_change_invalidates_in_flight_discovery() {
    var object = service()
    object.discoveryEnabled = true
    respond(object, {})
    object.hasAnalyzed = true
    verify(object.ensureDiscovery())
    var serial = object.activeRequest.discoverySerial
    verify(object.setSetupSelected({id:"example.queued",selectable:true,name:"Queued"}, true))
    verify(object.discoverySerial > serial)
    respond(object, {discovery:{rows:[{id:"example.queued"}]}})
    compare(object.discoveryRows.length, 0)
    tryCompare(object, "activeAction", "discover")
    verify(object.activeRequest.queuedIds.indexOf("example.queued") >= 0)
    respond(object, {discovery:{rows:[{id:"example.fresh"}]}})
    compare(object.discoveryRows[0].id, "example.fresh")
  }
  function test_watchlist_change_invalidates_old_discovery_reply() {
    var object = service()
    object.discoveryEnabled = true
    respond(object, {})
    object.hasAnalyzed = true
    object.editorOpen = true
    object.workspaceView = "discover"
    verify(object.ensureDiscovery())
    object.preferences = {services:["spotify"],watchHardware:false}
    wait(0)
    respond(object, {discovery:{rows:[{id:"example.old-watchlist"}]}})
    compare(object.discoveryRows.length, 0)
    tryCompare(object, "activeAction", "discover")
    respond(object, {discovery:{rows:[{id:"example.spotify"}]}})
    compare(object.discoveryRows[0].id, "example.spotify")
  }
  function test_enabled_widget_with_wrong_requested_location_retries_placement() {
    var object = service()
    respond(object, {})
    object.inventoryReady = true
    object.inventory = [{id:"example.widget",enabled:true,canDisable:true,kinds:["bar-widget"],barSection:"right",barSectionKnown:true}]
    object.setPluginOperation("example.widget", {pending:false,status:"failed",lastAction:"enable-plugin",
      lastRequest:{barSection:"left"}})
    verify(object.retryPluginOperation({id:"example.widget",barWidget:true}, {}))
    tryCompare(object, "mutationActive", true)
    compare(object.activeMutation.action, "place-plugin")
    compare(object.activeMutation.barSection, "left")
  }
  function test_install_only_failure_does_not_accept_unexpected_enabled_state() {
    var object = service()
    respond(object, {})
    object.hasAnalyzed = true
    object.inventoryReady = true
    object.inventory = [{id:"example.widget",enabled:true,canDisable:true,kinds:["bar-widget"],installedRevision:"a".repeat(40)}]
    object.setPluginOperation("example.widget", {pending:false,status:"failed",lastAction:"install-plugin",
      lastRequest:{enableAfter:false,barSection:"",reviewedRevision:"a".repeat(40)}})
    object.reconcileTerminalOutcomes()
    compare(object.pluginOperation("example.widget").status, "failed")
    verify(object.retryPluginOperation({id:"example.widget",barWidget:true}, {}))
    tryCompare(object, "mutationActive", true)
    compare(object.activeMutation.action, "disable-plugin")
  }
  function test_obsolete_management_failure_does_not_trap_the_inspector() {
    var object = service()
    respond(object, {})
    object.inventoryReady = true
    object.setPluginOperation("example.gone", {pending:false,status:"failed",lastAction:"enable-plugin",lastRequest:{}})
    object.inventory = [{id:"example.disabled",enabled:false,kinds:["bar-widget"]}]
    object.setPluginOperation("example.disabled", {pending:false,status:"failed",lastAction:"place-plugin",lastRequest:{barSection:"left"}})
    object.reconcileTerminalOutcomes()
    compare(object.pluginOperation("example.gone").status, "superseded")
    compare(object.pluginOperation("example.disabled").status, "superseded")
    verify(!object.mutationActive)
  }
  function test_default_view_is_browse_and_explicit_discover_restores() {
    var object = service()
    object.discoveryEnabled = true
    compare(object.workspaceView, "browse")
    compare(object.safeEditorPayload({}, "").workspaceView, "browse")
    object.workspaceView = "discover"
    compare(object.safeEditorPayload({}, "").workspaceView, "discover")
    compare(object.safeEditorPayload({workspaceView:"browse"}, "").workspaceView, "browse")
  }
  function test_automatic_scan_does_not_create_a_results_notice() {
    var object = service()
    respond(object, {})
    object.hasAnalyzed = true
    object.setupRequested = true
    verify(object.rescan(true))
    verify(object.backgroundAutomatic)
    finishJob(object, {profile:[], inventory:[], installed:[], inventoryAuthoritative:true,
      unavailable:[], changes:{added:[],removed:[]}, notice:"Hardware check complete; no changes detected."})
    compare(object.notice, "")
    compare(object.setupRefreshNotice, "")
    compare(object.updateStatus, "")
    verify(object.lastHardwareCheckAt > 0)
    respond(object, {setup:{rows:[],groups:[],sections:[]}})
    compare(object.notice, "")
  }
  function test_manual_scan_completion_is_brief_header_state_not_results_notice() {
    var object = service()
    respond(object, {})
    object.hasAnalyzed = true
    object.setupRequested = true
    verify(object.rescan(false))
    finishJob(object, {profile:[], inventory:[], installed:[], inventoryAuthoritative:true,
      unavailable:[], notice:"Hardware check complete; no changes detected."})
    compare(object.updateStatus, "System updated")
    compare(object.notice, "")
    compare(object.setupRefreshNotice, "")
    respond(object, {setup:{rows:[]}})
    compare(object.updateStatus, "System updated")
    findChild(object, "updateStatusExpiry").triggered()
    compare(object.updateStatus, "")
  }
  function test_hardware_completion_does_not_replace_newer_inventory() {
    var object = service()
    respond(object, {})
    verify(object.rescan(false))
    object.inventoryRevision++
    object.inventory = [{id:"example.newer"}]
    finishJob(object, {profile:[],inventory:[],installed:[],inventoryAuthoritative:true,unavailable:[]})
    compare(object.updateStatus, "System updated")
    verify(object.lastHardwareCheckAt > 0)
    verify(object.hasAnalyzed)
    compare(object.inventoryRevision, 1)
    compare(object.inventory[0].id, "example.newer")
  }
  function test_background_error_remains_visible_after_query_and_optional_warning_is_retained() {
    var object = service()
    respond(object, {})
    object.hasAnalyzed = true
    verify(object.refresh("", ""))
    compare(object.startupActivity.catalog.state, "running")
    verify(object.quickSetup("", "", "stars", 1))
    findChild(object, "backgroundJobs").stop("Fixture network failure")
    compare(object.backgroundError, "Fixture network failure")
    compare(object.startupActivity.catalog.state, "error")
    compare(object.updateStatus, "")
    respond(object, {setup:{rows:[]}})
    compare(object.error, "Fixture network failure")
    compare(object.backgroundError, "Fixture network failure")
    verify(object.refresh("", ""))
    finishJob(object, {dataWarning:"Popularity unavailable; using saved totals.", fetchedAt:123,
      notice:"Marketplace catalog refreshed."})
    compare(object.backgroundError, "")
    compare(object.updateStatus, "Catalog updated")
    compare(object.startupActivity.catalog.state, "complete")
    compare(object.dataWarning, "Popularity unavailable; using saved totals.")
    compare(object.setupRefreshNotice, "")
  }
  function test_closing_during_refresh_does_not_create_an_update_error() {
    var object = service()
    respond(object, {})
    object.editorOpen = true
    verify(object.refresh("", ""))
    object.editorClosed()
    verify(!object.backgroundBusy)
    compare(object.backgroundError, "")
    compare(object.startupActivity.catalog.state, "waiting")
    compare(object.error, "")
    compare(object.updateStatus, "")
  }
}
