import QtQuick
import QtTest
import "../.." as Plugin

TestCase {
  id: testCase
  name: "NativePluginOpen"
  when: windowShown
  Component { id: component; Plugin.Service {} }
  Component {
    id: shellComponent
    QtObject {
      property int summons: 0
      property int hides: 0
      function summon(id, payload) { summons++; return true }
      function hide(id) { hides++; return true }
      function isPluginOpen(id) { return false }
    }
  }
  function service() {
    var object = createTemporaryObject(component, testCase)
    object.receiveOutput(JSON.stringify({ok:true, action:"load", generation:object.activeGeneration,
      preferences:{watchHardware:false,readmeIndexing:false,readmeEnrichment:false,services:[]}}))
    object.inventoryReady = true
    object.inventory = [entry("example.alpha"), entry("example.beta")]
    object.setupDetailId = "example.alpha"
    object.shell = createTemporaryObject(shellComponent, testCase)
    return object
  }
  function entry(id) { return {id:id,enabled:true,kinds:["panel"],canDisable:true,firstParty:false} }
  function jobs(object) { return findChild(object, "pluginOpenJobs") }
  function request(object) { return JSON.parse(JSON.stringify(jobs(object).activeRequest)) }
  function finish(object, state, extra, exitCode) {
    var worker = jobs(object)
    verify(worker.active)
    var owner = request(object)
    var result = {ok:state === "accepted",action:"open-plugin",generation:owner.generation,
      pluginId:owner.pluginId,openState:state,error:state === "accepted" ? "" : "Fixture Open " + state}
    for (var key in (extra || {})) result[key] = extra[key]
    worker.receiveLine(JSON.stringify(result))
    var process = findChild(worker, "backgroundWorker")
    process.running = false
    process.exited(exitCode === undefined ? (state === "accepted" ? 0 : 2) : exitCode, 0)
    // A rejected JSONL envelope is ignored until the exit/drain deadline.
    if (worker.active) findChild(worker, "backgroundDrain").triggered()
    return owner
  }
  function test_open_is_a_separate_fixed_worker_lane_with_no_focus_or_mutation_effects() {
    var object = service()
    verify(object.quickSetup("concurrent query", "", "name", 1))
    object.error = "Keep query error"
    object.notice = "Keep query notice"
    object.editorRestoreSuppressed = true
    object.editorSessionPayload = {selectedId:"example.alpha", marker:"unchanged"}
    var restore = JSON.stringify(object.editorSessionPayload)
    var mutationGeneration = object.mutationGeneration
    var queryGeneration = object.activeGeneration
    verify(object.openPlugin({id:"example.alpha",command:"untrusted",payload:{custom:true}}))
    var owner = request(object)
    compare(owner.action, "open-plugin")
    compare(owner.pluginId, "example.alpha")
    verify(!("command" in owner) && !("payload" in owner))
    compare(findChild(jobs(object), "backgroundWorker").command,
      ["/usr/bin/python3", "-I", "-B", object.helperPath])
    verify(object.pluginOpenPending("example.alpha"))
    verify(!object.pluginOpenPending("example.beta"))
    verify(!object.pluginPending("example.alpha"))
    verify(!object.mutationBusy)
    verify(!object.openPlugin({id:"example.alpha"}))
    verify(!object.openPlugin({id:"example.beta"}))
    finish(object, "accepted")
    verify(!object.pluginOpenPending("example.alpha"))
    compare(object.pluginOpenError("example.alpha"), "")
    compare(object.pluginOpenResult.openState, "accepted")
    compare(object.error, "Keep query error")
    compare(object.notice, "Keep query notice")
    compare(object.activeGeneration, queryGeneration)
    compare(object.mutationGeneration, mutationGeneration)
    compare(object.mutationQueue.length, 0)
    compare(Object.keys(object.pluginOperations).length, 0)
    compare(object.editorRestorePayload, null)
    compare(JSON.stringify(object.editorSessionPayload), restore)
    verify(object.editorRestoreSuppressed)
    compare(object.shell.summons, 0)
    compare(object.shell.hides, 0)
    verify(!jobs(object).active)
    verify(!findChild(object, "pluginOpenDeadline").running)
    compare(jobs(object).generation, 1)
  }
  function test_unavailable_and_unconfirmed_errors_are_local_and_explicit_retry_only() {
    var object = service()
    verify(object.openPlugin({id:"example.alpha"}))
    finish(object, "unavailable")
    compare(object.pluginOpenError("example.alpha"), "Fixture Open unavailable")
    compare(object.pluginOpenError("example.beta"), "")
    compare(object.pluginError("example.alpha"), "")
    compare(object.error, "")
    verify(object.openPlugin({id:"example.alpha"}))
    compare(object.pluginOpenError("example.alpha"), "")
    finish(object, "unconfirmed")
    compare(object.pluginOpenResult.openState, "unconfirmed")
    compare(object.pluginOpenError("example.alpha"), "Fixture Open unconfirmed")
    compare(jobs(object).generation, 2)
    verify(!object.pluginOpenBusy)
    compare(object.shell.summons, 0)
  }
  function test_short_deadline_cannot_turn_late_acceptance_into_success_or_retry() {
    var object = service()
    verify(object.openPlugin({id:"example.alpha"}))
    var owner = request(object)
    compare(findChild(object, "pluginOpenDeadline").interval, 11000)
    findChild(object, "pluginOpenDeadline").triggered()
    verify(!object.pluginOpenBusy)
    compare(object.pluginOpenResult.openState, "unconfirmed")
    verify(object.pluginOpenError(owner.pluginId).indexOf("not retried") >= 0)
    object.finishPluginOpen({ok:true,action:"open-plugin",generation:owner.generation,
      pluginId:owner.pluginId,openState:"accepted",error:""}, owner)
    compare(object.pluginOpenResult.openState, "unconfirmed")
    compare(jobs(object).generation, 1)
    compare(object.shell.summons, 0)
  }
  function test_stale_selection_including_away_and_back_drops_old_result() {
    var object = service()
    verify(object.openPlugin({id:"example.alpha"}))
    object.setupDetailId = "example.beta"
    object.setupDetailId = "example.alpha"
    finish(object, "unavailable")
    compare(object.pluginOpenResult, null)
    compare(object.pluginOpenError("example.alpha"), "")
    verify(!object.pluginOpenBusy)
    verify(object.openPlugin({id:"example.alpha"}))
    object.setupDetailId = "example.beta"
    finish(object, "accepted")
    compare(object.setupDetailId, "example.beta")
    compare(object.pluginOpenResult, null)
  }
  function test_changed_inventory_mutation_generation_or_window_session_drops_completion_data() {
    return [{tag:"inventory revision", change:"inventoryRevision"},
      {tag:"mutation generation", change:"mutationGeneration"},
      {tag:"editor session", change:"editorOpen"},
      {tag:"canonical changed", change:"inventory"},
      {tag:"inventory unknown", change:"inventoryReady"}]
  }
  function test_changed_inventory_mutation_generation_or_window_session_drops_completion(data) {
    var object = service()
    verify(object.openPlugin({id:"example.alpha"}))
    if (data.change === "inventory") object.inventory = [{id:"example.alpha",enabled:false,kinds:["panel"]}]
    else if (data.change === "editorOpen") object.editorOpen = !object.editorOpen
    else if (data.change === "inventoryReady") object.inventoryReady = false
    else object[data.change]++
    finish(object, "unavailable")
    compare(object.pluginOpenResult, null)
    verify(!object.pluginOpenBusy)
  }
  function test_old_generation_does_not_clear_new_request_or_deadline() {
    var object = service()
    verify(object.openPlugin({id:"example.alpha"}))
    var old = finish(object, "accepted")
    verify(object.openPlugin({id:"example.alpha"}))
    object.finishPluginOpen({ok:false,action:"open-plugin",generation:old.generation,
      pluginId:old.pluginId,openState:"unavailable",error:"Old failure"}, old)
    verify(object.pluginOpenPending(old.pluginId))
    verify(findChild(object, "pluginOpenDeadline").running)
    compare(object.pluginOpenResult, null)
    finish(object, "accepted")
    compare(object.pluginOpenError(old.pluginId), "")
  }
  function test_malformed_envelope_and_nonzero_exit_never_become_accepted_data() {
    return [{tag:"wrong identity", extra:{pluginId:"example.beta"}},
      {tag:"wrong generation", extra:{generation:99}},
      {tag:"wrong action", extra:{action:"enable-plugin"}},
      {tag:"exit only", extra:{openState:undefined}},
      {tag:"contradictory error", extra:{error:"failed"}},
      {tag:"nonzero exit", extra:{}, code:2}]
  }
  function test_malformed_envelope_and_nonzero_exit_never_become_accepted(data) {
    var object = service()
    verify(object.openPlugin({id:"example.alpha"}))
    finish(object, "accepted", data.extra, data.code)
    compare(object.pluginOpenResult.openState, "unconfirmed")
    verify(object.pluginOpenError("example.alpha").length > 0)
    compare(object.pluginOpenError("example.beta"), "")
  }
  function test_gates_use_canonical_inventory_and_keep_batch_recovery_ownership() {
    var object = service()
    var listing = {id:"example.alpha",installed:true,enabled:true,kinds:["panel"],barWidget:true}
    var cases = [[], [{id:listing.id,enabled:true,kinds:["service"]}],
      [{id:listing.id,enabled:true,kinds:["bar-widget"]}],
      [{id:listing.id,enabled:false,kinds:["panel"],firstParty:true}],
      [{id:listing.id,enabled:"true",kinds:["panel"]}],
      [{id:listing.id,enabled:true,kinds:"panel"}]]
    for (var i = 0; i < cases.length; i++) {
      object.inventory = cases[i]
      verify(!object.openPlugin(listing))
    }
    object.inventory = [entry(listing.id)]
    object.inventoryReady = false
    verify(!object.openPlugin(listing))
    object.inventoryReady = true
    object.mutationActive = true
    verify(!object.openPlugin(listing))
    object.mutationActive = false
    object.batchRunning = true
    verify(!object.openPlugin(listing))
    object.batchRunning = false
    object.batchItems = [{id:listing.id,status:"partial"}]
    verify(!object.openPlugin(listing))
    compare(object.batchItems[0].status, "partial")
    object.batchItems = []
    object.setPluginOperation(listing.id, {pending:true,status:"checking"})
    verify(!object.openPlugin(listing))
    object.setPluginOperation(listing.id, {pending:false,status:"failed",error:"Keep recovery"})
    verify(!object.openPlugin(listing))
    compare(object.pluginError(listing.id), "Keep recovery")
    object.inventory = [entry("io.github.ctl0v0.outfit")]
    verify(!object.openPlugin({id:"io.github.ctl0v0.outfit"}))
    compare(jobs(object).generation, 0)
    compare(object.shell.summons, 0)
  }
}
