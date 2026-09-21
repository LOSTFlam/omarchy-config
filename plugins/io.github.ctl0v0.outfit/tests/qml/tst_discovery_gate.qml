import QtQuick
import QtTest
import "../.." as Plugin

TestCase {
  id: testCase
  name: "DiscoveryLaunchGate"
  when: windowShown
  Component { id: component; Plugin.Service {} }
  function reply(service, fields) {
    service.receiveOutput(JSON.stringify(Object.assign({ok:true,action:service.activeAction,
      generation:service.activeGeneration}, fields || {})))
  }
  function make() {
    var service = createTemporaryObject(component, testCase)
    reply(service, {preferences:{watchHardware:false,readmeEnrichment:false,readmeIndexing:false}})
    service.hasAnalyzed = true
    service.editorOpen = true
    return service
  }
  function test_launch_blocks_all_discovery_entry_points_without_touching_saved_state() {
    var service = make()
    verify(!service.discoveryEnabled)
    service.matches = {rows:[{id:"fixture.pen",unread:true}],unread:4}
    service.reviewedMatchIds = {"fixture.old":true}
    var before = JSON.stringify(service.matches)
    service.workspaceView = "discover"
    compare(service.workspaceView, "browse")
    compare(service.safeEditorPayload({workspaceView:"discover",discoveryEnabled:true}, "").workspaceView, "browse")
    verify(!service.ensureDiscovery())
    verify(!service.requestDiscovery())
    verify(!service.discoverNext())
    verify(!service.discoverBack())
    service.catalogMatchesChanged()
    service.scheduleMatches(true)
    service.chooseMatches(false, 2)
    verify(!service.reviewMatches(["fixture.pen"], false))
    verify(!service.reviewMatches([], true))
    for (var i = 0; i < 3; i++) verify(!service.request(["discover","matches","review-matches"][i], {}))
    compare(service.pendingDiscovery, null)
    verify(!service.pendingMatches && !service.discoveryBusy && !service.matchesBusy)
    compare(service.unreadMatches, 0)
    verify(!service.matchUnread({id:"fixture.pen",matchedInterests:[],unread:true}))
    compare(JSON.stringify(service.matches), before)
    verify(service.reviewedMatchIds["fixture.old"])
    verify(!service.requestActive)
  }
  function test_context_multiselect_save_and_preview_work_without_inbox_requests() {
    var service = make()
    service.requestContext()
    verify(service.flushInterestsRequests())
    compare(service.activeAction, "context")
    var inputs = {revision:1,criteria:[],ignoredSignals:[],detected:[],serviceChoices:[],featureChoices:[]}
    reply(service, {inputs:inputs})
    verify(service.inputsLoaded)
    verify(service.addCustomInterest("stylus"))
    verify(service.selectInterestChoice("service", {id:"spotify",name:"Spotify",terms:["spotify"]}, true))
    compare(service.interestsDraft.criteria.length, 2)
    verify(service.saveInterests())
    var saved = JSON.parse(JSON.stringify(service.activeRequest.criteria))
    reply(service, {inputs:Object.assign({}, inputs, {revision:2,criteria:saved})})
    compare(service.inputs.criteria.length, 2)
    verify(!service.interestsDirty && !service.pendingMatches)
    compare(service.setupServiceIds, [])
    verify(service.editInterest(0, service.inputs.criteria[0]))
    verify(service.previewInterest())
    verify(service.flushInterestsRequests())
    compare(service.activeAction, "preview-interest")
    reply(service, {preview:{rows:[],total:0,partial:false}})
    compare(service.interestPreview.total, 0)
    verify(!service.flushInterestsRequests())
    verify(!service.requestActive && !service.matchesLoaded)
  }
  function test_disabling_rejects_late_results_and_clears_only_pending_work() {
    var service = make()
    service.discoveryEnabled = true
    verify(service.requestDiscovery())
    service.scheduleMatches(true)
    service.discoveryEnabled = false
    reply(service, {discovery:{rows:[{id:"fixture.late"}]}})
    compare(service.discoveryRows, [])
    compare(service.pendingDiscovery, null)
    verify(!service.pendingMatches && !service.requestActive)
    service.discoveryEnabled = true
    service.inputsLoaded = true
    service.pendingContext = false
    service.scheduleMatches(true)
    verify(service.flushInterestsRequests())
    compare(service.activeAction, "matches")
    service.discoveryEnabled = false
    reply(service, {criteriaRevision:service.criteriaRevision,matches:{rows:[],unread:99}})
    compare(service.matches.unread, 0)
    verify(!service.matchesLoaded && !service.requestActive)
  }
}
