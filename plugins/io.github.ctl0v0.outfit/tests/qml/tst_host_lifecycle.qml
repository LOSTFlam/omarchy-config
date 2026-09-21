import QtQuick
import QtTest
import "../.." as Plugin

TestCase {
  id: testCase
  name: "NativeBatchLifecycle"
  when: windowShown
  Component { id: component; Plugin.Service {} }
  Component {
    id: shellComponent
    QtObject {
      property int summons: 0
      function summon(id, payload) { summons++; return true }
      function hide(id) { return true }
      function isPluginOpen(id) { return false }
    }
  }
  function service() {
    var object = createTemporaryObject(component, testCase)
    object.receiveOutput(JSON.stringify({ok:true, action:"load", generation:object.activeGeneration,
      preferences:{watchHardware:false,readmeIndexing:false,readmeEnrichment:false,services:[]}}))
    object.inventoryReady = true
    object.shell = createTemporaryObject(shellComponent, testCase)
    object.setupSelection = {"example.alpha":{id:"example.alpha",name:"Alpha",activate:true,reviewedRevision:"a".repeat(40)},
      "example.beta":{id:"example.beta",name:"Beta",activate:true,reviewedRevision:"a".repeat(40)}}
    return object
  }
  function jobs(object) { return findChild(object, "hostLifecycleJobs") }
  function pauseAdvance(object) { findChild(object, "batchAdvance").stop() }
  function start(object) {
    verify(object.startSetupBatch({setupStage:"progress"}))
    pauseAdvance(object)
    object.pumpHostLifecycle()
    compare(jobs(object).activeRequest.operation, "begin")
    compare(jobs(object).activeRequest.leaseMs, 10000)
  }
  function begun(token) {
    return {supported:true,version:1,ok:true,token:token || "lease.fixture-alpha",generation:4,
      expiresAt:Date.now() + 10000,deadline:Date.now() + 60000}
  }
  function snapshot(extra) {
    var host = {supported:true,version:1,generation:8,settledGeneration:8,
      scanning:false,reconciling:false,pending:false,held:false,scanError:"",plugins:{}}
    for (var key in (extra || {})) host[key] = extra[key]
    return host
  }
  function finish(object, host, ok) {
    var worker = jobs(object)
    verify(worker.active)
    var request = JSON.parse(JSON.stringify(worker.activeRequest))
    var process = findChild(worker, "backgroundWorker")
    worker.receiveLine(JSON.stringify({ok:ok !== false,action:"host-lifecycle",generation:request.generation,
      host:host, error:ok === false ? "Fixture transport failure /private/should-not-be-published" : ""}))
    process.running = false
    process.exited(0, 0)
    pauseAdvance(object)
    return request
  }
  function completeMutation(object, success) {
    var request = object.activeMutation
    var inventory = object.inventory.slice()
    if (success) inventory.push({id:request.pluginId,enabled:true,installedRevision:request.reviewedRevision})
    object.receiveMutationOutput(JSON.stringify({ok:success, action:request.action,generation:request.generation,
      inventoryAuthoritative:success,inventory:inventory,installed:inventory.map(function(item) { return item.id }),
      unavailable:[],operation:{observed:success,status:success ? "completed" : "failed"},
      error:success ? "" : "Fixture native failure"}))
    var process = findChild(object, "mutationWorker")
    process.running = false
    process.exited(success ? 0 : 1, 0)
    pauseAdvance(object)
  }
  function endAndPoll(object) {
    object.batchRunning = false
    object.pumpHostLifecycle()
    compare(jobs(object).activeRequest.operation, "end")
    finish(object, {supported:true,version:1,ok:true,generation:8})
    object.pumpHostLifecycle()
    compare(jobs(object).activeRequest.operation, "status")
  }

  function test_acquire_precedes_native_dispatch_without_blocking_search() {
    var object = service()
    start(object)
    object.dispatchNextBatchItem()
    compare(object.mutationQueue.length, 0)
    verify(!object.mutationActive)
    verify(object.quickSetup("search during lease acquisition", "", "name", 1))
    compare(object.activeAction, "quick-setup")
    verify(!object.backgroundBusy)
    verify(object.hostLifecycleBusy)
    finish(object, begun())
    compare(object.hostLeaseState, "held")
    object.dispatchNextBatchItem()
    tryCompare(object, "mutationActive", true)
    compare(object.activeMutation.pluginId, "example.alpha")
    compare(object.activeAction, "quick-setup")
    verify(object.hostLeaseRenewAt > Date.now())
    verify(object.hostLeaseRenewAt <= Date.now() + 3000)
  }
  function test_unsupported_host_is_quiet_fallback_and_native_batch_continues() {
    var object = service()
    start(object)
    finish(object, {supported:false})
    compare(object.hostLifecycleState, "unsupported")
    compare(object.hostLeaseToken, "")
    compare(object.hostLifecycleError, "")
    compare(object.error, "")
    object.dispatchNextBatchItem()
    tryCompare(object, "mutationActive", true)
    verify(!object.hostRuntimeReady)
    object.stopSetupBatch()
    object.pumpHostLifecycle()
    verify(!jobs(object).active)
    verify(object.mutationActive)
  }
  function test_acquisition_timeout_unblocks_only_optional_gate() {
    var object = service()
    start(object)
    object.hostLeaseAcquireDeadline = Date.now() - 1
    object.pumpHostLifecycle()
    compare(object.hostLeaseState, "fallback")
    object.dispatchNextBatchItem()
    tryCompare(object, "mutationActive", true)
    // A successful begin arriving after timeout is cleaned up, never adopted.
    finish(object, begun("lease.late"))
    object.pumpHostLifecycle()
    compare(jobs(object).activeRequest.operation, "end")
    compare(jobs(object).activeRequest.token, "lease.late")
    compare(object.hostLeaseToken, "")
    verify(object.mutationActive)
  }
  function test_stop_during_renew_ends_after_reply_and_close_stays_respected() {
    var object = service()
    start(object)
    finish(object, begun())
    object.dispatchNextBatchItem()
    tryCompare(object, "mutationActive", true)
    object.hostLeaseRenewAt = Date.now() - 1
    object.pumpHostLifecycle()
    compare(jobs(object).activeRequest.operation, "renew")
    verify(object.closeEditor())
    object.editorClosed()
    verify(object.batchCloseSuppressed)
    verify(object.stopSetupBatch())
    compare(object.hostLeaseCleanup.length, 1)
    compare(jobs(object).activeRequest.operation, "renew")
    finish(object, {supported:true,version:1,ok:true,expiresAt:Date.now()+10000,deadline:Date.now()+60000})
    object.pumpHostLifecycle()
    compare(jobs(object).activeRequest.operation, "end")
    compare(jobs(object).activeRequest.token, "lease.fixture-alpha")
    compare(object.hostLeaseToken, "")
    verify(object.mutationActive)
    finish(object, {supported:true,version:1,ok:true,generation:8})
    verify(object.hostLeaseEndConfirmed)
    completeMutation(object, true)
    verify(!object.batchRunning)
    object.pumpHostLifecycle()
    compare(jobs(object).activeRequest.operation, "status")
    finish(object, snapshot({plugins:{"example.alpha":{enabled:true,loadErrors:{},restartRequired:false}}}))
    verify(object.hostRuntimeReady)
    verify(object.batchCloseSuppressed)
    compare(object.shell.summons, 0)
    verify(!object.editorOpen)
  }
  function test_renew_failure_releases_hold_without_cancelling_native_operation() {
    var object = service()
    start(object)
    finish(object, begun())
    object.dispatchNextBatchItem()
    tryCompare(object, "mutationActive", true)
    var native = findChild(object, "mutationWorker")
    object.hostLeaseRenewAt = 0
    object.pumpHostLifecycle()
    finish(object, {supported:true,version:1,ok:false,error:"unknown or expired lease"})
    object.pumpHostLifecycle()
    compare(jobs(object).activeRequest.operation, "end")
    verify(object.mutationActive && native.running)
    compare(native.lastSignal, 0)
    verify(object.batchRunning)
    compare(object.error, "")
  }
  function test_absolute_deadline_ends_once_and_later_items_use_normal_targeted_changes() {
    var object = service()
    start(object)
    finish(object, begun())
    object.dispatchNextBatchItem()
    tryCompare(object, "mutationActive", true)
    object.hostLeaseDeadline = Date.now() - 1
    object.hostLeaseRenewAt = Date.now() - 1
    object.pumpHostLifecycle()
    compare(jobs(object).activeRequest.operation, "end")
    finish(object, {supported:true,version:1,ok:false,error:"unknown or expired lease"})
    verify(!object.hostLeaseEndConfirmed)
    completeMutation(object, true)
    object.dispatchNextBatchItem()
    tryCompare(object, "mutationActive", true)
    compare(object.activeMutation.pluginId, "example.beta")
    verify(object.hostLeaseAttempted && object.hostLeaseEndRequested)
    verify(!object.hostLeaseBeginPending)
    compare(object.hostLeaseToken, "")
    object.pumpHostLifecycle()
    compare(jobs(object).activeRequest.operation, "status")
  }
  function test_renew_never_extends_original_deadline() {
    var object = service()
    start(object)
    finish(object, begun())
    var original = object.hostLeaseDeadline
    object.hostLeaseRenewAt = 0
    object.pumpHostLifecycle()
    finish(object, {supported:true,version:1,ok:true,expiresAt:original+100000,deadline:original+100000})
    compare(object.hostLeaseDeadline, original)
    compare(object.hostLeaseExpiresAt, original)
  }
  function test_superseded_begin_is_ended_and_stale_renew_cannot_touch_new_token() {
    var object = service()
    start(object)
    var old = JSON.parse(JSON.stringify(jobs(object).activeRequest))
    object.stopSetupBatch()
    verify(!object.batchRunning)
    verify(object.startSetupBatch({}))
    pauseAdvance(object)
    finish(object, begun("lease.old"))
    object.pumpHostLifecycle()
    compare(jobs(object).activeRequest.operation, "end")
    compare(jobs(object).activeRequest.token, "lease.old")
    finish(object, {supported:true,version:1,ok:true,generation:8})
    object.pumpHostLifecycle()
    compare(jobs(object).activeRequest.operation, "begin")
    finish(object, begun("lease.new"))
    var deadline = object.hostLeaseDeadline
    old.operation = "renew"
    old.token = "lease.old"
    object.finishHostLifecycle({ok:true,action:"host-lifecycle",generation:old.generation,
      host:{supported:true,version:1,ok:false,error:"expired"}}, old)
    compare(object.hostLeaseToken, "lease.new")
    compare(object.hostLeaseState, "held")
    compare(object.hostLeaseDeadline, deadline)
    verify(!object.hostLeaseEndRequested)
  }
  function test_finish_and_failure_both_end_the_lease() {
    var object = service()
    start(object)
    finish(object, begun())
    object.dispatchNextBatchItem()
    tryCompare(object, "mutationActive", true)
    completeMutation(object, false)
    object.pumpHostLifecycle()
    compare(jobs(object).activeRequest.operation, "end")
    compare(object.pluginOperation("example.alpha").status, "checking")
    verify(object.batchRunning)
    var success = service()
    start(success)
    finish(success, begun())
    endAndPoll(success)
    finish(success, snapshot())
    verify(success.hostRuntimeReady)
  }
  function test_transport_end_failure_retries_once_then_polls_without_claiming_release() {
    var object = service()
    start(object)
    finish(object, begun())
    object.batchRunning = false
    object.pumpHostLifecycle()
    finish(object, null, false)
    object.pumpHostLifecycle()
    compare(jobs(object).activeRequest.operation, "end")
    compare(jobs(object).activeRequest.attempts, 1)
    finish(object, null, false)
    object.pumpHostLifecycle()
    compare(jobs(object).activeRequest.operation, "status")
    verify(!object.hostLeaseEndConfirmed)
    finish(object, snapshot({held:true}))
    verify(!object.hostRuntimeReady)
  }
  function test_readiness_requires_latest_generation_and_every_documented_flag() {
    var object = service()
    start(object)
    finish(object, begun())
    endAndPoll(object)
    var states = [{generation:12,settledGeneration:8}, {held:true}, {pending:true},
      {scanning:true}, {reconciling:true}]
    for (var i = 0; i < states.length; i++) {
      var host = snapshot(states[i])
      host.generation = 12
      if (i > 0) host.settledGeneration = 12
      finish(object, host)
      verify(!object.hostRuntimeReady)
      object.hostPollNextAt = 0
      object.pumpHostLifecycle()
      compare(jobs(object).activeRequest.operation, "status")
    }
    finish(object, snapshot({generation:12,settledGeneration:12}))
    verify(object.hostRuntimeReady)
    compare(object.hostPollDeadline, 0)
    verify(!object.hostSnapshotSettled({generation:12,settledGeneration:12}, 12))
  }
  function test_runtime_errors_and_restart_are_reported_without_private_diagnostics_or_tokens() {
    var object = service()
    start(object)
    finish(object, begun())
    object.inventory = [{id:"example.alpha",enabled:true},{id:"example.beta",enabled:true}]
    endAndPoll(object)
    finish(object, snapshot({plugins:{
      "example.alpha":{enabled:true,loadErrors:{panel:"/private/lease.fixture-alpha.qml"},restartRequired:false},
      "example.beta":{enabled:true,loadErrors:{},restartRequired:true},
      "unrelated.private":{enabled:true,loadErrors:{service:"private diagnostic"}}}}))
    verify(!object.hostRuntimeReady)
    compare(object.hostRuntimeResults["example.alpha"].loadErrors, ["panel"])
    verify(object.hostRuntimeResults["example.beta"].restartRequired)
    compare(object.pluginOutcome("example.alpha"), "Needs attention")
    compare(object.pluginOutcome("example.beta"), "Restart required")
    var published = JSON.stringify({snapshot:object.hostLifecycleSnapshot,plugins:object.hostRuntimeResults,
      error:object.hostLifecycleError,batch:object.batchItems})
    verify(published.indexOf("/private/") < 0)
    verify(published.indexOf("lease.fixture-alpha") < 0)
    verify(published.indexOf("unrelated.private") < 0)
    object.persistBatchJournal()
    verify(findChild(object, "batchJournal").contents.indexOf("lease.fixture-alpha") < 0)
    verify(findChild(object, "batchJournal").contents.indexOf("/private/") < 0)
    compare(jobs(object).response, null)
  }
  function test_global_scan_failure_is_a_redacted_runtime_failure_and_polling_is_bounded() {
    var object = service()
    start(object)
    finish(object, begun())
    endAndPoll(object)
    finish(object, snapshot({scanError:"/private/path token lease.fixture-alpha"}))
    verify(!object.hostRuntimeReady)
    verify(object.hostLifecycleSnapshot.scanFailed)
    verify(object.hostLifecycleError.indexOf("/private/") < 0)
    verify(object.hostLifecycleError.indexOf("lease.fixture-alpha") < 0)
    var slow = service()
    start(slow)
    finish(slow, begun())
    endAndPoll(slow)
    finish(slow, snapshot({scanning:true,pending:true}))
    slow.hostPollDeadline = Date.now() - 1
    slow.pumpHostLifecycle()
    compare(slow.hostLifecycleState, "unconfirmed")
    verify(!slow.hostRuntimeReady)
    verify(!jobs(slow).active)
  }
  function test_stale_status_cannot_claim_runtime_ready_after_another_native_mutation() {
    var object = service()
    start(object)
    finish(object, begun())
    object.endBatchLifecycle()
    object.pumpHostLifecycle()
    finish(object, {supported:true,version:1,ok:true,generation:8})
    object.pumpHostLifecycle()
    compare(jobs(object).activeRequest.operation, "status")
    object.dispatchNextBatchItem()
    tryCompare(object, "mutationActive", true)
    finish(object, snapshot())
    verify(!object.hostRuntimeReady)
    compare(object.hostSnapshotMutationSerial, -1)
    verify(object.mutationActive)
  }
  function test_short_watchdog_never_signals_native_worker_and_end_has_followup_budget() {
    var object = service()
    start(object)
    finish(object, begun())
    object.dispatchNextBatchItem()
    tryCompare(object, "mutationActive", true)
    object.hostLeaseRenewAt = 0
    object.pumpHostLifecycle()
    var deadline = findChild(object, "hostLifecycleRequestDeadline")
    compare(deadline.interval, 4000)
    deadline.triggered()
    object.pumpHostLifecycle()
    compare(jobs(object).activeRequest.operation, "end")
    compare(deadline.interval, 8000)
    verify(object.mutationActive)
    verify(findChild(object, "mutationWorker").running)
    compare(findChild(object, "mutationWorker").lastSignal, 0)
  }
  function test_transient_unsupported_end_retries_token_then_uses_read_only_status() {
    var object = service()
    start(object)
    finish(object, begun())
    object.batchRunning = false
    object.pumpHostLifecycle()
    finish(object, {supported:false})
    object.pumpHostLifecycle()
    compare(jobs(object).activeRequest.operation, "end")
    compare(jobs(object).activeRequest.token, "lease.fixture-alpha")
    finish(object, {supported:true,version:1,ok:true,generation:8})
    verify(object.hostLeaseEndConfirmed)
    object.pumpHostLifecycle()
    compare(jobs(object).activeRequest.operation, "status")
  }
  function test_unknown_tokens_and_incomplete_status_cannot_claim_a_lease_or_readiness() {
    var object = service()
    verify(!object.validHostToken("-flag"))
    verify(!object.validHostToken("x".repeat(257)))
    verify(!object.validHostToken("token\nargument"))
    verify(!object.validHostToken("token\u00a0argument"))
    start(object)
    var host = begun("x".repeat(257))
    finish(object, host)
    compare(object.hostLeaseToken, "")
    compare(object.hostLeaseState, "fallback")
    object.batchRunning = false
    object.pumpHostLifecycle()
    compare(jobs(object).activeRequest.operation, "status")
    var malformed = snapshot()
    delete malformed.plugins
    finish(object, malformed)
    verify(!object.hostRuntimeReady)
    verify(object.hostPollDeadline > Date.now())
  }
  function test_later_individual_action_invalidates_batch_runtime_snapshot_without_reacquiring() {
    var object = service()
    start(object)
    finish(object, begun())
    endAndPoll(object)
    finish(object, snapshot())
    verify(object.hostRuntimeReady)
    verify(object.startPluginAction("install-plugin", "example.individual", {}, "", true, false, "a".repeat(40)))
    tryCompare(object, "mutationActive", true)
    verify(!object.hostRuntimeReady)
    completeMutation(object, true)
    object.pumpHostLifecycle()
    compare(jobs(object).activeRequest.operation, "status")
    verify(!object.hostLeaseBeginPending)
    compare(object.hostLeaseToken, "")
    finish(object, snapshot({generation:9,settledGeneration:9,
      plugins:{"example.individual":{enabled:true,loadErrors:{},restartRequired:false}}}))
    verify(object.hostRuntimeReady)
    object.clearPluginIntent("example.individual", "partial", "", "Requested placement was not confirmed")
    verify(!object.hostRuntimeReady)
  }
}
