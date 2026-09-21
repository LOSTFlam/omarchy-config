import QtQuick
import QtTest
import "../.." as Plugin

TestCase {
  id: testCase
  name: "ServiceSleep"
  when: windowShown
  Component { id: component; Plugin.Service {} }
  function service() {
    var object = createTemporaryObject(component,testCase)
    var worker = findChild(object,"queryWorker")
    worker.processId = 42
    worker.started()
    object.receiveOutput(JSON.stringify({ok:true,action:"load",generation:object.activeGeneration,
      catalogCount:100,preferences:{watchHardware:false,readmeEnrichment:false,services:[]}}))
    object.startupStarted = true
    object.inventoryReady = true
    object.inputsLoaded = true
    object.editorOpened()
    object.sleepDelay = 80
    return object
  }
  function exited(object) {
    var worker = findChild(object,"queryWorker")
    worker.processId = 0
    worker.running = false
    worker.exited(0,0)
  }
  function test_close_grace_sleep_and_reopen_preserve_user_intent() {
    var object = service()
    object.setupRows = [{id:"example.cached"}]
    object.readmeContent = "Large document".repeat(1000)
    object.setupQuery = "saved query"
    object.interestsDraft = {revision:9,criteria:[{id:"interest.keep",label:"Keep me"}]}
    object.interestsDirty = true
    object.editorClosed()
    verify(findChild(object,"idleSleep").running)
    wait(20)
    verify(!object.sleeping)
    verify(findChild(object,"queryWorker").running)
    tryCompare(object,"sleeping",true,1000)
    verify(!findChild(object,"queryWorker").running)
    exited(object)
    compare(object.setupRows.length,0)
    compare(object.readmeContent,"")
    compare(object.setupQuery,"saved query")
    verify(object.interestsDirty)
    compare(object.interestsDraft.criteria[0].label,"Keep me")
    wait(100)
    verify(!object.requestActive && !object.backgroundBusy && !object.updatesBusy)
    object.editorOpened()
    verify(!object.sleeping)
    compare(object.activeAction,"load")
    verify(findChild(object,"queryWorker").running)
    compare(object.interestsDraft.criteria[0].label,"Keep me")
  }
  function test_fast_reopen_cancels_sleep_and_reuses_warm_worker() {
    var object = service()
    object.editorClosed()
    wait(10)
    object.editorOpened()
    wait(120)
    verify(!object.sleeping)
    verify(!findChild(object,"idleSleep").running)
    verify(findChild(object,"queryWorker").running)
  }
  function test_close_cancels_readonly_queue_and_waits_for_old_process_before_reopen() {
    var object = service()
    verify(object.quickSetup("old","","likes",1))
    var old = object.activeGeneration
    object.editorClosed()
    verify(object.queryStopping)
    verify(object.queryBusy,"A retiring helper must keep interactive writes gated")
    verify(!object.requestActive)
    object.receiveOutput(JSON.stringify({ok:true,action:"quick-setup",generation:old,setup:{rows:[{id:"example.stale"}]}}))
    verify(!object.setupRows.length)
    object.editorOpened()
    object.quickSetup("new","","likes",1)
    verify(object.queryStopping && !object.requestActive)
    exited(object)
    wait(0)
    compare(object.activeAction,"quick-setup")
    compare(object.activeRequest.setupQuery,"new")
    verify(object.activeGeneration > old)
  }
  function test_explicit_save_blocks_sleep_but_does_not_refresh_closed_browse() {
    var object = service()
    verify(object.request("save-preferences",{preferences:{watchHardware:false}}))
    var request = object.activeRequest
    object.editorClosed()
    wait(120)
    verify(!object.sleeping)
    verify(object.requestActive && findChild(object,"queryWorker").running)
    object.receiveOutput(JSON.stringify({ok:true,action:request.action,generation:request.generation,
      preferences:{watchHardware:false}}))
    tryCompare(object,"sleeping",true,1000)
    verify(!object.requestActive)
  }
  function test_active_mutation_and_verification_delay_sleep() {
    var object = service()
    object.mutationActive = true
    object.editorClosed()
    wait(120)
    verify(!object.sleeping)
    object.setPluginOperation("example.plugin",{pending:true,status:"checking"})
    object.mutationActive = false
    wait(100)
    verify(!object.sleeping)
    object.clearPluginIntent("example.plugin","completed","Done","")
    tryCompare(object,"sleeping",true,1000)
  }
  function test_stale_and_malformed_frames_do_not_finish_another_request() {
    var object = service()
    verify(object.quickSetup("current","","likes",1))
    var request = object.activeRequest
    object.receiveOutput("not json")
    object.receiveOutput(JSON.stringify({ok:true,action:request.action,generation:request.generation-1}))
    object.receiveOutput(JSON.stringify({ok:true,action:"search",generation:request.generation}))
    verify(object.requestActive)
    compare(object.response,null)
    object.receiveOutput(JSON.stringify({ok:true,action:request.action,generation:request.generation,
      setup:{rows:[{id:"example.current"}],page:1,total:1}}))
    verify(!object.requestActive)
    compare(object.setupRows[0].id,"example.current")
    compare(object.response,null)
  }
  function test_progress_journal_is_coalesced_but_terminal_state_is_immediate() {
    var object = service()
    object.batchJournalLoaded = true
    object.batchItems = [{id:"example.plugin",name:"Example",status:"running",kind:"install"}]
    var start = object.lastBatchJournalText
    for (var i = 0; i < 50; i++) object.replaceBatchItem(0,{message:"Progress " + i})
    compare(object.lastBatchJournalText,start)
    verify(findChild(object,"journalWriteDelay").running)
    object.replaceBatchItem(0,{status:"completed",message:"Done"})
    verify(!findChild(object,"journalWriteDelay").running)
    compare(JSON.parse(object.lastBatchJournalText).items[0].status,"completed")
  }
  function test_updates_context_is_bounded_and_retained_in_resume_payload() {
    var object = service()
    var context = {x:15,y:200,anchor:{id:"example.a",offset:-20},expanded:{"example.a":true},id:"example.a",action:"explain"}
    var result = object.safeEditorPayload({setupStage:"updates",updatesContext:context},"")
    compare(result.updatesContext,context)
    context.expanded.constructor = true
    for (var i = 0; i < 100; i++) context.expanded["example." + i] = true
    result = object.safeUpdatesContext(context)
    verify(Object.keys(result.expanded).length <= 64)
    verify(!Object.prototype.hasOwnProperty.call(result.expanded,"constructor"))
  }
  function test_fast_reopen_rearms_a_startup_lane_after_cancellation_finishes() {
    var object = service()
    verify(object.refreshCatalog(true))
    var jobs = findChild(object,"catalogJobs")
    var process = findChild(jobs,"backgroundWorker")
    process.processId = 43
    process.started()
    var generation = jobs.generation
    object.editorClosed()
    object.editorOpened()
    compare(jobs.generation,generation,"The old process retains its lane until it exits")
    process.processId = 0
    process.running = false
    process.exited(0,0)
    tryVerify(function() { return jobs.generation > generation })
    verify(jobs.active)
    compare(jobs.activeRequest.action,"catalog-refresh")
  }
}
