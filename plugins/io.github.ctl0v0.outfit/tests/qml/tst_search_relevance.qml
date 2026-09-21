import QtQuick
import QtTest
import "../.." as Plugin

TestCase {
  id: testCase
  name: "SearchRelevance"
  when: windowShown
  Component { id: serviceComponent; Plugin.Service {} }
  function respond(service, setup) {
    service.receiveOutput(JSON.stringify({ok:true, action:service.activeAction,
      generation:service.activeGeneration, setup:setup || {}}))
  }
  function service() {
    var object = createTemporaryObject(serviceComponent, testCase)
    respond(object)
    return object
  }
  function test_auto_manual_typing_clear_and_repeated_search() {
    var object = service(), preferences = JSON.stringify(object.preferences)
    object.quickSetup("", "", "likes", 1)
    respond(object)
    object.quickSetup("midi", "", object.setupSort, 1)
    compare(object.activeRequest.setupSort, "relevance")
    compare(object.browseSort, "likes")
    respond(object, {sort:"stars", query:"wrong", search:{active:true,mode:"complete",suggestion:null}})
    compare(object.setupSort, "relevance")
    compare(object.setupQuery, "midi")
    object.prepareSetupSearch("midi", "name", true)
    object.quickSetup("midi controller", "", object.setupSort, 1)
    compare(object.activeRequest.setupSort, "name")
    respond(object)
    object.quickSetup("   ", "", object.setupSort, 1)
    compare(object.activeRequest.setupQuery, "")
    compare(object.activeRequest.setupSort, "likes")
    compare(object.setupSearch.mode, "none")
    respond(object)
    object.quickSetup("tablet", "", object.setupSort, 1)
    compare(object.activeRequest.setupSort, "relevance")
    compare(JSON.stringify(object.preferences), preferences)
    verify(!object.densitySavePending)
  }
  function test_new_session_defaults_to_likes_and_restores_it_after_search() {
    var object = service()
    compare(object.setupSort, "likes")
    compare(object.browseSort, "likes")
    object.quickSetup("midi", "", object.setupSort, 1)
    compare(object.activeRequest.setupSort, "relevance")
    respond(object)
    object.quickSetup("", "", object.setupSort, 1)
    compare(object.activeRequest.setupSort, "likes")
  }
  function test_edit_before_debounce_rejects_obsolete_response_and_error() {
    var object = service()
    object.quickSetup("mid", "", "stars", 1)
    var obsolete = JSON.parse(JSON.stringify(object.activeRequest))
    object.prepareSetupSearch("midi", object.setupSort, false)
    respond(object, {rows:[{id:"obsolete"}], sort:"stars", search:{active:true,mode:"partial",
      suggestion:{query:"wrong", label:"wrong"}}})
    compare(object.setupRows, [])
    compare(object.setupSearch, {active:false,mode:"none",suggestion:null})
    compare(object.setupQuery, "midi")
    compare(object.setupSort, "relevance")
    verify(object.applyResponse({ok:false,error:"obsolete failure"}, obsolete))
    compare(object.error, "")
  }
  function test_queued_request_dispatch_cannot_resurrect_text_after_clear() {
    var object = service()
    object.setupSort = "activity"
    object.quickSetup("m", "", object.setupSort, 1)
    object.quickSetup("mi", "", object.setupSort, 1)
    respond(object)
    // The pending request has moved into Qt.callLater, but has not dispatched.
    object.prepareSetupSearch("", object.setupSort, false)
    wait(0)
    verify(!object.requestActive)
    compare(object.setupQuery, "")
    compare(object.setupSort, "activity")
    object.quickSetup("", "", object.setupSort, 1)
    compare(object.activeRequest.setupSort, "activity")
  }
  function test_response_contract_missing_metadata_and_zero_only_suggestions() {
    var object = service()
    object.quickSetup("typo", "", "stars", 1)
    respond(object, {total:0,search:{active:true,mode:"none",suggestion:{query:"midi",label:"Did you mean MIDI?"}}})
    compare(object.setupSearch.suggestion.query, "midi")
    object.quickSetup("typo", "", object.setupSort, 1)
    compare(object.setupSearch.suggestion, null)
    respond(object, {total:1,search:{active:true,mode:"partial",suggestion:{query:"wrong",label:"wrong"}}})
    compare(object.setupSearch.mode, "partial")
    compare(object.setupSearch.suggestion, null)
    object.quickSetup("typo", "", object.setupSort, 1)
    respond(object, {rows:[]})
    compare(object.setupSearch, {active:false,mode:"none",suggestion:null})
    compare(object.setupSort, "relevance")
    object.quickSetup("", "", object.setupSort, 1)
    respond(object, {search:{active:true,mode:"partial",suggestion:{query:"wrong",label:"wrong"}}})
    compare(object.setupSearch, {active:false,mode:"none",suggestion:null})
  }
  function test_resume_payload_round_trip_manual_sort_and_no_query_relevance_fallback() {
    var object = service()
    object.setupSort = "copies"
    object.quickSetup("midi", "", object.setupSort, 1)
    object.prepareSetupSearch("midi", "name", true)
    var payload = object.safeEditorPayload({}, "")
    compare(payload.setupSort, "name")
    compare(payload.browseSort, "copies")
    var reopened = service()
    reopened.restoreSetupSearch(payload)
    reopened.quickSetup("midi controller", "", reopened.setupSort, 1)
    compare(reopened.activeRequest.setupSort, "name")
    reopened.prepareSetupSearch("", reopened.setupSort, false)
    compare(reopened.setupSort, "copies")
    reopened.prepareSetupSearch("", "relevance", true)
    compare(reopened.setupSort, "copies")
  }
  function test_unchanged_panel_recovery_keeps_search_results_and_pending_response() {
    var object = service()
    object.quickSetup("midi", "", "stars", 1)
    var serial = object.setupSearchSerial
    object.restoreSetupSearch(object.safeEditorPayload({}, ""))
    compare(object.setupSearchSerial, serial)
    respond(object, {total:1,rows:[{id:"example.midi",searchSnippet:"MIDI support"}],
      search:{active:true,mode:"complete",suggestion:null}})
    object.restoreSetupSearch(object.safeEditorPayload({}, ""))
    compare(object.setupSearch.active, true)
    compare(object.setupSearch.mode, "complete")
    compare(object.setupRows[0].searchSnippet, "MIDI support")
  }
}
