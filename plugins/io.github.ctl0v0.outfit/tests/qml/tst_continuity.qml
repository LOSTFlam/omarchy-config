import QtQuick
import QtTest
import "../.." as Plugin

TestCase {
  id: testCase
  name: "OperationContinuity"
  when: windowShown
  Component { id: component; Plugin.Service {} }
  Component {
    id: shellComponent
    QtObject {
      property bool panelOpen: true
      property bool accepting: true
      property int summons: 0
      property int hides: 0
      property var payload: null
      function isPluginOpen(id) { return panelOpen }
      function summon(id, json) { summons++; payload = JSON.parse(json); return accepting }
      function hide(id) { hides++; panelOpen = false; return true }
    }
  }
  function service() {
    var object = createTemporaryObject(component, testCase)
    object.receiveOutput(JSON.stringify({ok:true,action:"load",generation:object.activeRequest.generation}))
    object.inventoryReady = true
    object.editorOpen = true
    object.shell = createTemporaryObject(shellComponent, testCase)
    return object
  }
  function test_reload_can_restore_before_helper_finishes_and_summons_coalesce_until_ack() {
    var object = service()
    verify(object.startPluginAction("install-plugin", "example.widget", {selectedId:"example.widget",setupStage:"browse"}, "right", true, false, ""))
    tryCompare(object, "mutationActive", true)
    object.shell.panelOpen = false
    object.editorClosed()
    object.coordinateEditorRestore()
    compare(object.shell.summons, 1)
    verify(object.mutationActive)
    var token = object.shell.payload.restoreToken
    verify(token.length > 0)
    object.coordinateEditorRestore()
    object.coordinateEditorRestore()
    compare(object.shell.summons, 1)
    verify(!object.acknowledgeEditorRestore("old-token"))
    object.shell.panelOpen = true
    verify(object.acknowledgeEditorRestore(token))
    object.coordinateEditorRestore()
    compare(object.shell.summons, 1)
    compare(object.editorRestoreToken, "")
    verify(object.editorOpen)
  }
  function test_user_close_invalidates_outstanding_token_and_wins_for_entire_batch() {
    var object = service()
    object.batchRunning = true
    verify(object.prepareEditorRestore({setupStage:"progress"}, ""))
    object.shell.panelOpen = false
    object.coordinateEditorRestore()
    var token = object.editorRestoreToken
    verify(object.closeEditor())
    verify(object.batchCloseSuppressed)
    verify(!object.acceptsEditorRestore(token))
    verify(!object.acknowledgeEditorRestore(token))
    object.editorClosed()
    // The next item must not re-arm restoration, even if an open callback races close.
    object.editorOpen = true
    verify(!object.prepareEditorRestore({setupStage:"progress"}, "example.next"))
    object.coordinateEditorRestore()
    compare(object.shell.summons, 1)
    compare(object.shell.hides, 1)
  }
  function test_restore_has_bounded_deadline_and_rejected_summon_backoff() {
    var object = service()
    object.prepareEditorRestore({}, "")
    object.shell.panelOpen = false
    object.shell.accepting = false
    object.coordinateEditorRestore()
    compare(object.shell.summons, 1)
    compare(object.editorRestoreToken, "")
    object.coordinateEditorRestore()
    compare(object.shell.summons, 1)
    object.editorRestoreRetryAt = 0
    object.shell.accepting = true
    object.coordinateEditorRestore()
    compare(object.shell.summons, 2)
    object.editorRestoreAckDeadline = Date.now() - 1
    object.coordinateEditorRestore()
    compare(object.editorRestoreState, "armed")
    verify(object.editorRestorePayload !== null)
    object.editorRestoreDeadline = Date.now() - 1
    object.coordinateEditorRestore()
    compare(object.editorRestoreState, "idle")
    compare(object.editorRestorePayload, null)
  }
  function test_lost_accepted_summon_retries_despite_host_open_intent_and_rejects_old_token() {
    var object = service()
    verify(object.startPluginAction("remove-plugin", "example.widget", {selectedId:"example.widget"}, "", false, false, ""))
    object.shell.panelOpen = false
    object.editorClosed()
    object.coordinateEditorRestore()
    var lostToken = object.editorRestoreToken
    verify(lostToken.length > 0)
    // The old host reports the queued open intent even when a second rescan
    // destroys the loader and its pending payload before our panel can open.
    object.shell.panelOpen = true
    object.editorRestoreAckDeadline = Date.now() - 1
    object.coordinateEditorRestore()
    verify(!object.acceptsEditorRestore(lostToken))
    object.coordinateEditorRestore()
    compare(object.shell.summons, 1)
    object.editorRestoreRetryAt = 0
    object.coordinateEditorRestore()
    compare(object.shell.summons, 2)
    var retryToken = object.editorRestoreToken
    verify(retryToken !== lostToken && retryToken.length > 0)
    verify(!object.acknowledgeEditorRestore(lostToken))
    verify(object.acknowledgeEditorRestore(retryToken))
    object.coordinateEditorRestore()
    compare(object.shell.summons, 2)
    verify(object.editorOpen)
  }
  function test_user_close_during_restore_backoff_cancels_all_late_opens() {
    var object = service()
    object.prepareEditorRestore({}, "")
    object.shell.panelOpen = false
    object.editorClosed()
    object.coordinateEditorRestore()
    var token = object.editorRestoreToken
    object.editorRestoreAckDeadline = Date.now() - 1
    object.coordinateEditorRestore()
    object.userClosedEditor()
    object.editorRestoreRetryAt = 0
    object.coordinateEditorRestore()
    compare(object.shell.summons, 1)
    verify(!object.acknowledgeEditorRestore(token))
    compare(object.editorRestorePayload, null)
  }
  function test_next_batch_item_preserves_the_latest_panel_location_and_drafts() {
    var object = service()
    object.batchRunning = true
    object.rememberEditor({setupStage:"progress",settingsOpen:true,interestsOpen:true,
      interestsFromSettings:true,windowWidth:1550,windowHeight:930,
      restoreDraft:true,settingsTouched:true,draft:{watchHardware:false}})
    verify(object.startPluginAction("install-plugin", "example.next",
      {setupStage:"progress",windowWidth:1000}, "", false, true, ""))
    compare(object.editorRestorePayload.windowWidth, 1550)
    verify(object.editorRestorePayload.interestsOpen)
    verify(object.editorRestorePayload.settingsTouched)
    verify(!object.editorRestorePayload.draft.watchHardware)
  }
  function test_resume_payload_preserves_view_drafts_anchor_and_size_without_forcing_progress() {
    var object = service()
    object.batchItems = [{id:"example.done",status:"completed"}]
    object.browseDensity = "dense"
    object.setupServiceIds = ["spotify"]
    var payload = object.safeEditorPayload({setupStage:"browse",workspaceView:"discover",discoverTab:"matches",
      selectedId:"example.match",settingsOpen:false,interestsOpen:true,interestsFromSettings:true,
      restoreDraft:true,settingsTouched:true,draft:{readmeEnrichment:false},
      scrollAnchor:{id:"example.anchor",offset:-24,y:850},inspectorScroll:370,inspectorFocus:"primary",
      installDraft:{enable:false,section:"left"},windowWidth:1380,windowHeight:900}, "")
    compare(payload.setupStage, "browse")
    compare(payload.discoverTab, "matches")
    compare(payload.setupServices, ["spotify"])
    compare(payload.scrollAnchor.id, "example.anchor")
    compare(payload.inspectorScroll, 370)
    compare(payload.inspectorFocus, "primary")
    compare(payload.windowWidth, 1380)
    verify(payload.interestsOpen && payload.interestsFromSettings)
    verify(payload.settingsTouched && !payload.draft.readmeEnrichment)
    verify(!payload.installDraft.enable)
    compare(object.browseDensity, "dense")
    object.rememberEditor(payload)
    compare(object.editorSessionPayload.scrollAnchor.y, 850)
  }
  function test_progress_before_final_is_bounded_validated_and_never_finishes_mutation() {
    var object = service()
    verify(object.startPluginAction("install-plugin", "example.widget", {}, "", false, false, "a".repeat(40)))
    tryCompare(object, "mutationActive", true)
    verify(object.activeMutation.streamProgress)
    var event = {responseKind:"progress",action:object.activeMutation.action,
      generation:object.activeMutation.generation,phase:"installing",message:"Installing package"}
    object.receiveMutationOutput(JSON.stringify(event))
    verify(object.mutationActive)
    verify(!object.mutationStreamFinished)
    compare(object.mutationResponse, null)
    compare(object.pluginProgress("example.widget"), "Installing package")
    event.generation--
    event.message = "Stale event"
    object.receiveMutationOutput(JSON.stringify(event))
    compare(object.pluginProgress("example.widget"), "Installing package")
    event.generation++
    event.phase = "invented-percentage"
    object.receiveMutationOutput(JSON.stringify(event))
    compare(object.mutationProgressEvents, 1)
    event.phase = "verifying"
    event.message = "Checking inventory"
    for (var i = 0; i < 150; i++) object.receiveMutationOutput(JSON.stringify(event))
    compare(object.mutationProgressEvents, 128)
    var result = {ok:true,action:object.activeMutation.action,generation:object.activeMutation.generation,
      inventoryAuthoritative:true,inventory:[{id:"example.widget",enabled:false,installedRevision:"a".repeat(40)}],installed:["example.widget"],
      unavailable:[],operation:{observed:true,status:"completed",message:"Installed"},notice:"Ordinary success"}
    object.receiveMutationOutput(JSON.stringify(result))
    verify(object.mutationStreamFinished)
    verify(object.mutationActive)
    object.receiveMutationOutput("unexpected trailing line")
    compare(object.mutationResponse.operation.message, "Installed")
    object.mutationProcessExited = true
    object.finishMutationIfReady()
    verify(!object.mutationActive)
    compare(object.pluginOutcome("example.widget"), "Installed")
    compare(object.notice, "")
  }

  function test_interest_filter_snapshot_survives_sanitizing_journal_and_restore() {
    var object = service()
    var criterion = {id:"",kind:"topic",label:"MIDI",terms:["midi"],enabled:true}
    var key = object.interestFilterKey(criterion)
    var filters = [{key:key,criterion:criterion}]
    var payload = {setupServices:[key],setupInterestCriteria:filters}
    compare(object.safeEditorPayload(payload, "").setupInterestCriteria, filters)
    object.setupInterestCriteria = filters
    compare(object.safeEditorPayload({setupInterestCriteria:[]}, "").setupInterestCriteria, [])
    var fallback = object.safeEditorPayload({}, "")
    fallback.setupInterestCriteria[0].criterion.terms = ["changed externally"]
    compare(object.setupInterestCriteria[0].criterion.terms, ["midi"])
    object.setupInterestCriteria = []
    object.restoreBatchJournal(JSON.stringify({schema:1,selection:[],items:[],resumePayload:payload}))
    compare(object.batchResumePayload.setupInterestCriteria, filters)
    compare(object.setupInterestCriteria, filters)
    verify(object.prepareEditorRestore(object.batchResumePayload, ""))
    object.setupInterestCriteria = []
    object.shell.panelOpen = false
    object.editorClosed()
    object.coordinateEditorRestore()
    compare(object.shell.payload.setupServices, [key])
    compare(object.shell.payload.setupInterestCriteria, filters)
  }
  function test_progress_then_eof_without_final_reconciles_canonical_inventory() {
    var object = service()
    verify(object.startPluginAction("remove-plugin", "example.widget", {}, "", false, false, ""))
    tryCompare(object, "mutationActive", true)
    object.receiveMutationOutput(JSON.stringify({responseKind:"progress",action:"remove-plugin",
      generation:object.activeMutation.generation,phase:"removing",message:"Removing plugin"}))
    var process = findChild(object, "mutationWorker")
    process.running = false
    process.exited(1, 0)
    tryCompare(object, "mutationActive", false)
    compare(object.pluginOperation("example.widget").status, "checking")
    compare(object.pluginOutcome("example.widget"), "Checking")
    verify(object.pluginProgress("example.widget").indexOf("checking") >= 0)
    object.inventory = []
    object.reconcilePluginOperations()
    compare(object.pluginOutcome("example.widget"), "Removed")
  }
  function test_duplicate_board_refreshes_coalesce_and_do_not_search_hidden_legacy_view() {
    var object = service()
    object.hasAnalyzed = true
    object.setupRequested = true
    object.setupQuery = "keep query"
    object.setupPage = 3
    object.queueBoardRefresh()
    compare(object.activeAction, "quick-setup")
    compare(object.activeRequest.setupQuery, "keep query")
    object.queueBoardRefresh()
    object.queueBoardRefresh()
    verify(!object.boardRefreshPending)
    compare(object.pendingSearch, null)
    compare(object.pendingSetup, null)
    object.inventoryRevision++
    object.queueBoardRefresh()
    verify(object.boardRefreshPending)
    object.receiveOutput(JSON.stringify({ok:true,action:object.activeAction,generation:object.activeGeneration,
      setup:{rows:[{id:"stale"}]}}))
    tryCompare(object, "activeAction", "quick-setup")
    compare(object.activeRequest.inventoryRevision, object.inventoryRevision)
    compare(object.setupPage, 3)
  }
  function test_final_line_can_arrive_after_exit_without_becoming_ambiguous_failure() {
    var object = service()
    verify(object.startPluginAction("enable-plugin", "example.widget", {}, "", false, false, ""))
    tryCompare(object, "mutationActive", true)
    var generation = object.activeMutation.generation
    var process = findChild(object, "mutationWorker")
    process.running = false
    process.exited(0, 0)
    verify(object.mutationActive)
    object.receiveMutationOutput(JSON.stringify({ok:true,action:"enable-plugin",generation:generation,
      inventoryAuthoritative:true,inventory:[{id:"example.widget",enabled:true}],installed:["example.widget"],
      operation:{status:"completed",observed:true}}))
    verify(!object.mutationActive)
    compare(object.pluginOutcome("example.widget"), "Enabled")
    verify(!findChild(object, "mutationEofGrace").running)
  }
}
