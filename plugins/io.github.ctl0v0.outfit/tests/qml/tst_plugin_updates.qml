import QtQuick
import QtTest
import "../.." as Plugin

TestCase {
  id: testCase
  name: "PluginUpdates"
  when: windowShown
  Component { id: component; Plugin.Service {} }
  readonly property string oldRevision: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  readonly property string newRevision: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  function update(id) {
    return {id:id || "example.plugin", name:"Example", state:"available", canUpdate:true,
      selfUpdate:false, installedVersion:"1.0", availableVersion:"1.0", checkedAt:100,
      installedRevision:oldRevision, availableRevision:newRevision}
  }
  function entry(row) {
    return {id:row.id, name:row.name, installedVersion:"1.0", installedRevision:oldRevision,
      enabled:false, firstParty:false, canDisable:true, kinds:["bar-widget"], barSection:"left", barSectionKnown:true}
  }
  function service(rows) {
    var object = createTemporaryObject(component, testCase)
    verify(object !== null)
    object.receiveOutput(JSON.stringify({ok:true, action:"load", generation:object.activeGeneration,
      preferences:{watchHardware:false, readmeEnrichment:false}}))
    object.updates = rows || [update()]
    object.inventory = object.updates.map(entry)
    object.installed = object.inventory.map(function(row) { return row.id })
    object.inventoryReady = true
    object.updatesLoaded = true
    object.batchJournalLoaded = true
    object.hostLifecycleSupport = "unsupported"
    return object
  }
  function test_checks_have_independent_lane_and_stale_results_are_rejected() {
    var object = service()
    verify(object.checkUpdates(true))
    var jobs = findChild(object, "updatesJobs")
    var request = jobs.activeRequest
    verify(!object.requestActive && !object.mutationBusy)
    object.inventoryRevision++
    object.finishUpdates({ok:true, inventoryAuthoritative:true, updates:[update("example.stale")]}, request)
    compare(object.updates[0].id,"example.plugin")
    jobs.stop("Fixture cancelled",true)
    var generation = {inventoryRevision:object.inventoryRevision,mutationGeneration:object.mutationGeneration}
    object.finishUpdates({ok:false,error:"Offline"},generation)
    compare(object.updatesError,"Offline")
    compare(object.updates[0].state,"available")
    verify(object.nextUpdatesCheckAt > Date.now())
    object.finishUpdates({ok:true,inventoryAuthoritative:true,updates:[update()],updatesCheckedAt:Date.now()/1000},generation)
    compare(object.updatesError,"")
    compare(object.availableUpdateCount,1)
    verify(!object.checkUpdates(false))
    var older = update("example.older")
    older.checkedAt = Date.now()/1000 - 21500
    object.finishUpdates({ok:true,inventoryAuthoritative:true,updates:[update(),older],updatesCheckedAt:Date.now()/1000},generation)
    verify(object.nextUpdatesCheckAt < Date.now() + 300000, "Old cached checks must not receive six more hours on reopen")
  }
  function test_individual_update_preserves_disabled_state_and_requires_revision() {
    var object = service()
    verify(object.updatePlugin(update(),{setupStage:"updates",updatesQuery:"Example",updatesScroll:100}))
    object.dispatchMutation()
    compare(object.activeMutation.action,"update-plugin")
    compare(object.activeMutation.expectedRevision,newRevision)
    compare(object.activeMutation.expectedInstalledRevision,oldRevision)
    compare(object.pluginOperation("example.plugin").desiredEnabled,false)
    compare(object.pluginOperation("example.plugin").desiredSection,"left")
    verify(!object.desiredPluginStateObserved("example.plugin"))
    var current = entry(update())
    current.installedRevision = newRevision
    object.inventory = [current]
    verify(object.desiredPluginStateObserved("example.plugin"))
    current = Object.assign({},current,{enabled:true})
    object.inventory = [current]
    verify(!object.desiredPluginStateObserved("example.plugin"))
    compare(object.availableUpdateCount,0)
  }
  function test_customizations_are_not_errors_and_partial_checks_keep_retrying() {
    var object = service()
    var customized = Object.assign(update(),{state:"customized",canUpdate:false,checkedAt:Date.now()/1000})
    var request = {inventoryRevision:object.inventoryRevision,mutationGeneration:object.mutationGeneration}
    object.finishUpdates({ok:true,inventoryAuthoritative:true,updates:[customized],updatesCheckedAt:Date.now()/1000,updatesError:""},request)
    compare(object.availableUpdateCount,0)
    compare(object.updatesError,"")
    verify(object.nextUpdatesCheckAt > Date.now()+3600000)
    customized = Object.assign({},customized,{checkError:"Temporary network failure"})
    object.finishUpdates({ok:true,inventoryAuthoritative:true,updates:[customized],updatesCheckedAt:Date.now()/1000,updatesError:""},request)
    compare(object.updatesError,"")
    verify(object.nextUpdatesCheckAt <= Date.now()+300000)
    verify(!object.updatePlugin(customized,{}))
    verify(!object.startUpdateBatch([],{}))
  }
  function test_batch_is_sequential_keeps_install_selection_and_excludes_self() {
    var self = Object.assign(update("io.github.ctl0v0.outfit"),{selfUpdate:true,canUpdate:false})
    var object = service([update(),update("example.second"),self])
    object.setSetupSelected({id:"example.later",name:"Later",installAvailable:true,selectable:true},true)
    verify(object.startUpdateBatch([],{setupStage:"updates"}))
    findChild(object,"batchAdvance").stop()
    compare(object.batchKind,"update")
    compare(object.batchItems.length,2)
    compare(object.selectedSetupRows()[0].id,"example.later")
    object.hostLeaseState = "fallback"
    object.hostLeaseBeginPending = false
    object.dispatchNextBatchItem()
    object.dispatchMutation()
    compare(object.activeMutation.pluginId,"example.plugin")
    compare(object.activeMutation.action,"update-plugin")
    object.dispatchNextBatchItem()
    compare(object.batchCurrentIndex,0)
    compare(object.batchItems[1].status,"queued")
    verify(object.stopSetupBatch())
    verify(object.batchStopRequested)
    compare(object.activeMutation.pluginId,"example.plugin")
  }
  function test_update_journal_keeps_more_than_fifty_and_restores_reviewed_targets() {
    var rows = []
    for (var i = 0; i < 60; i++) rows.push(update("example.plugin" + i))
    var object = service(rows)
    verify(object.startUpdateBatch([],{setupStage:"updates",updatesQuery:"Example",updatesScroll:80}))
    findChild(object,"batchAdvance").stop()
    var journal = JSON.stringify({schema:1,kind:object.batchKind,items:object.batchItems,selection:[],running:true,
      resumePayload:object.batchResumePayload})
    var restored = service([])
    restored.restoreBatchJournal(journal)
    compare(restored.batchKind,"update")
    compare(restored.batchItems.length,60)
    compare(restored.batchItems[59].expectedRevision,newRevision)
    compare(restored.batchItems[59].expectedInstalledRevision,oldRevision)
    compare(restored.batchResumePayload.setupStage,"updates")
    compare(restored.batchResumePayload.updatesQuery,"Example")
    compare(restored.batchResumePayload.updatesScroll,80)
    verify(!restored.batchRunning && restored.batchRecovered)
    restored.restoreBatchJournal(JSON.stringify({schema:1,items:[{id:"example.legacy",status:"queued"}]}))
    compare(restored.batchKind,"install")
    compare(restored.batchItems[0].kind,"install")
  }
  function test_self_update_is_separate_and_all_worker_phases_gate_mutations() {
    var row = Object.assign(update("io.github.ctl0v0.outfit"),{selfUpdate:true,canUpdate:false})
    var object = service([row])
    verify(!object.updatePlugin(row,{}))
    verify(!object.startUpdateBatch([],{}))
    object.interestsDirty = true
    verify(!object.beginSelfUpdate(row,{}))
    object.interestsDirty = false
    verify(!object.beginSelfUpdate(row,{settingsTouched:true}))
    verify(object.beginSelfUpdate(row,{setupStage:"updates"}))
    var jobs = findChild(object,"selfUpdateJobs")
    compare(jobs.activeRequest.action,"self-update")
    compare(jobs.activeRequest.expectedRevision,newRevision)
    compare(jobs.activeRequest.resumePayload.setupStage,"updates")
    jobs.stop("Fixture cancelled",true)
    ;["queued","checking","updating","verified","restarting","reopening"].forEach(function(state) {
      object.finishSelfUpdate({responseKind:"self-update",state:state,message:state},{action:"self-update-status"})
      verify(object.selfUpdateBusy && object.mutationBusy,state)
      verify(!object.checkUpdates(true))
    })
    object.finishSelfUpdate({responseKind:"self-update",state:"failed",message:"Fixture failure"},{action:"self-update-status"})
    verify(!object.selfUpdateBusy && !object.mutationBusy)
    compare(object.selfUpdateState.message,"Fixture failure")
  }
}
