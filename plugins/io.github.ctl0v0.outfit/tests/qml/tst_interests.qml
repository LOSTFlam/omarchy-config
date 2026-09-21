import QtQuick
import QtTest
import "../.." as Plugin

TestCase {
  id: testCase
  name: "InterestsAndMatches"
  when: windowShown
  // This suite retains coverage of the future saved-interest inbox.
  Component { id: component; Plugin.Service { discoveryEnabled: true } }
  function reply(object, fields) {
    fields.action = object.activeRequest.action
    fields.generation = object.activeRequest.generation
    if (!("ok" in fields)) fields.ok = true
    object.receiveOutput(JSON.stringify(fields))
  }
  function inputs(revision, criteria) {
    return {revision:revision, criteria:criteria || [], ignoredSignals:[], detected:[], probes:[],
      featureChoices:[], serviceChoices:[], scanState:"current", checkedAt:100}
  }
  function interest() { return {id:"topic.pen",kind:"hardware",label:"Drawing tablet",terms:["stylus"],enabled:true} }
  function service() {
    var object = createTemporaryObject(component, testCase)
    reply(object, {})
    object.editorOpen = true
    object.requestContext()
    verify(object.flushInterestsRequests())
    reply(object, {inputs:inputs(1, [interest()])})
    object.pendingMatches = false
    return object
  }
  function matchResult(revision) {
    return {criteriaRevision:revision, matches:{rows:[{id:"example.pen",name:"Pen",unread:true,
      matchCause:"newly-relevant", matchedInterests:[{id:"topic.pen",label:"Drawing tablet",reason:"stylus in README"}]}],
      total:1,unread:1,page:1,pageCount:1,lastCheckedAt:100,partial:false}}
  }
  function test_context_migrated_services_are_saved_without_activating_filters() {
    var object = service()
    object.setupServiceIds = ["github"]
    object.setupQuery = "unsent browse query"
    object.requestContext()
    verify(object.flushInterestsRequests())
    reply(object, {inputs:inputs(2,[{id:"service.spotify",kind:"service",label:"Spotify",serviceId:"spotify",terms:[],enabled:true}])})
    compare(object.interestsDraft.criteria[0].id, "service.spotify")
    compare(object.setupServiceIds, ["github"])
    compare(object.setupQuery, "unsent browse query")
    compare(object.mutationQueue.length, 0)
  }
  function test_context_refresh_preserves_dirty_draft_editor_and_original_revision() {
    var object = service()
    verify(object.useDetected("hardware.tablet", false))
    verify(object.editInterest(0, object.interestsDraft.criteria[0]))
    object.updateInterestEditor("label", "My unsaved label")
    object.requestContext()
    verify(object.flushInterestsRequests())
    reply(object, {inputs:inputs(2, [])})
    compare(object.criteriaRevision, 2)
    compare(object.interestsDraft.revision, 1)
    compare(object.interestsDraft.ignoredSignals, ["hardware.tablet"])
    compare(object.interestEditor.criterion.label, "My unsaved label")
    object.editorClosed()
    object.beginInterests()
    compare(object.interestEditor.criterion.label, "My unsaved label")
    verify(object.interestsDirty)
  }
  function test_strict_save_conflict_does_not_rebase_or_erase_draft() {
    var object = service()
    object.changeInterest(0, false)
    verify(object.saveInterests())
    compare(object.activeRequest.revision, 1)
    reply(object, {ok:false,errorCode:"revision-conflict",error:"Saved interests changed. Reload before saving."})
    verify(object.interestsDirty)
    compare(object.interestsDraft.revision, 1)
    compare(object.interestsDraft.criteria[0].enabled, false)
    verify(object.interestsError.indexOf("changed") >= 0)
    compare(object.mutationQueue.length, 0)
  }
  function test_zero_match_preview_and_save_preserve_density_board_and_queue() {
    var object = service()
    object.browseDensity = "list"
    object.setupRows = [{id:"example.board"}]
    object.setupPage = 4
    object.setupSelection = {"example.batch":{id:"example.batch"}}
    object.inspectorSnapshot = {id:"example.inspected",name:"Frozen"}
    object.editInterest(-1, {id:"",kind:"topic",label:"Future device",terms:["future stylus"],enabled:true})
    verify(object.previewInterest())
    verify(object.flushInterestsRequests())
    compare(object.activeAction, "preview-interest")
    reply(object, {preview:{rows:[],total:0,partial:true}})
    compare(object.interestPreview.total, 0)
    verify(object.applyInterestEditor())
    verify(object.saveInterests())
    var saved = object.activeRequest.criteria
    saved[1].id = "topic.generated"
    reply(object, {inputs:inputs(2,saved),preferences:{services:[],browseDensity:"list"},criteriaRevision:2})
    verify(!object.interestsDirty)
    compare(object.interestsDraft.criteria[1].id, "topic.generated")
    compare(object.browseDensity, "list")
    compare(object.setupPage, 4)
    compare(object.setupRows[0].id, "example.board")
    compare(object.inspectorSnapshot.name, "Frozen")
    verify(object.setupSelected("example.batch"))
    compare(object.mutationQueue.length, 0)
  }
  function test_preview_rejects_previous_editor_and_catalog_results() {
    var object = service()
    object.editInterest(0, interest())
    verify(object.previewInterest())
    verify(object.flushInterestsRequests())
    object.updateInterestEditor("termText", "new literal")
    reply(object, {preview:{rows:[{id:"obsolete"}],total:1}})
    compare(object.interestPreview, null)
    verify(object.previewInterest())
    verify(object.flushInterestsRequests())
    object.catalogMatchesChanged()
    reply(object, {preview:{rows:[{id:"old-catalog"}],total:1}})
    compare(object.interestPreview, null)
  }
  function test_stale_criteria_and_catalog_match_replies_never_clear_unread() {
    var object = service()
    object.matches = matchResult(1).matches
    object.scheduleMatches(true)
    verify(object.flushInterestsRequests())
    object.criteriaRevision = 2
    object.scheduleMatches(true)
    var stale = matchResult(1)
    stale.matches.unread = 0
    reply(object, stale)
    compare(object.unreadMatches, 1)
    verify(object.flushInterestsRequests())
    object.catalogMatchesChanged()
    stale.criteriaRevision = 2
    reply(object, stale)
    compare(object.unreadMatches, 1)
    verify(object.pendingMatches)
  }
  function test_fetch_and_inspection_do_not_acknowledge_but_explicit_review_does() {
    var object = service()
    object.setupRows = [{id:"example.board"}]
    object.setupSelection = {"example.batch":{id:"example.batch"}}
    object.scheduleMatches(true)
    verify(object.flushInterestsRequests())
    compare(object.activeAction, "matches")
    verify(!("pluginIds" in object.activeRequest))
    reply(object, matchResult(1))
    object.inspectorSnapshot = JSON.parse(JSON.stringify(object.matches.rows[0]))
    object.setupDetailId = "example.pen"
    verify(object.matchUnread(object.inspectorSnapshot))
    compare(object.unreadMatches, 1)
    verify(object.reviewMatches(["example.pen"], false))
    verify(object.flushInterestsRequests())
    compare(object.activeAction, "review-matches")
    compare(object.activeRequest.pluginIds, ["example.pen"])
    compare(object.unreadMatches, 1)
    var reviewed = matchResult(1)
    reviewed.matches.rows = []
    reviewed.matches.unread = 0
    reviewed.matches.total = 0
    reply(object, reviewed)
    verify(!object.matchUnread(object.inspectorSnapshot))
    compare(object.setupDetailId, "example.pen")
    compare(object.setupRows[0].id, "example.board")
    verify(object.setupSelected("example.batch"))
    compare(object.inspectorSnapshot.name, "Pen")
  }
  function test_failed_ack_is_retryable_and_all_review_is_explicit() {
    var object = service()
    object.matches = matchResult(1).matches
    verify(object.reviewMatches([], true))
    verify(object.flushInterestsRequests())
    verify(object.activeRequest.all)
    verify(!object.reviewMatches([], true))
    reply(object, {ok:false,error:"Local history is unavailable"})
    compare(object.unreadMatches, 1)
    verify(object.matchesError.length > 0)
    verify(object.reviewMatches([], true))
  }
  function test_pagination_has_separate_query_and_stale_page_cannot_win() {
    var object = service()
    object.setupPage = 5
    object.chooseMatches(false, 2)
    verify(object.flushInterestsRequests())
    compare(object.activeRequest.page, 2)
    compare(object.activeRequest.unreadOnly, false)
    object.chooseMatches(true, 1)
    reply(object, matchResult(1))
    compare(object.matches.rows.length, 0)
    verify(object.flushInterestsRequests())
    compare(object.activeRequest.page, 1)
    compare(object.activeRequest.unreadOnly, true)
    compare(object.setupPage, 5)
  }
  function test_open_catalog_index_and_save_evaluation_coalesce_and_stop_on_close() {
    var object = service()
    object.editorOpened()
    object.catalogMatchesChanged()
    object.finishIndexing({ok:true,readmeIndex:{indexed:4,eligible:4,due:0}}, {})
    verify(object.pendingMatches)
    verify(object.flushInterestsRequests())
    compare(object.activeAction, "context")
    reply(object, {inputs:inputs(1,[interest()])})
    verify(object.flushInterestsRequests())
    compare(object.activeAction, "matches")
    reply(object, matchResult(1))
    verify(!object.pendingMatches)
    object.editorClosed()
    object.catalogMatchesChanged()
    verify(!object.flushInterestsRequests())
    verify(!object.requestActive)
  }
  function test_scan_provenance_is_carried_separately_and_failed_probe_data_survives() {
    var object = service()
    object.scan = {state:"partial",checkedAt:50,probes:[{id:"usb",state:"unavailable"}],observations:[{id:"hardware.pen",freshness:"stale"}]}
    object.profile = [{id:"compatible.profile"}]
    verify(object.rescan(false))
    var job = findChild(object, "backgroundJobs")
    compare(job.activeRequest.previousScan.probes[0].state, "unavailable")
    compare(job.activeRequest.profile[0].id, "compatible.profile")
  }
  function test_literal_term_limits_and_keep_watching_are_drafts() {
    var object = service()
    verify(object.keepWatching({id:"usb.pen",label:"Tablet",domain:"hardware",terms:["precision stylus"]}))
    compare(object.interestEditor.criterion.id, "")
    verify(object.applyInterestEditor())
    compare(object.interestsDraft.criteria.length, 2)
    compare(object.inputs.criteria.length, 1)
    verify(object.interestsDirty)
    verify(object.interestValidation({label:"Topic",terms:["one","two","three","four","five"]}).length > 0)
    verify(object.interestValidation({label:"Topic",terms:["x".repeat(65)]}).length > 0)
    compare(object.interestValidation({label:"Literal",terms:["[literal.*]"]}), "")
  }
  function test_removing_a_preceding_interest_keeps_edit_attached_to_its_original_item() {
    var object = service()
    object.inputs = inputs(1, [
      {id:"topic.first",kind:"topic",label:"First",terms:["first"],enabled:true},
      {id:"topic.second",kind:"topic",label:"Second",terms:["second"],enabled:true},
      {id:"topic.third",kind:"topic",label:"Third",terms:["third"],enabled:true}])
    object.resetInterestsDraft()
    object.editInterest(2, object.interestsDraft.criteria[2])
    object.updateInterestEditor("label", "Edited third")
    object.updateInterestEditor("termText", "unsaved third phrase")
    var editSerial = object.interestEditSerial
    verify(object.changeInterest(0, true))
    compare(object.interestEditor.index, 1)
    compare(object.interestEditSerial, editSerial)
    compare(object.interestEditor.termText, "unsaved third phrase")
    verify(object.applyInterestEditor())
    compare(object.interestsDraft.criteria.length, 2)
    compare(object.interestsDraft.criteria[0].id, "topic.second")
    compare(object.interestsDraft.criteria[1].id, "topic.third")
    compare(object.interestsDraft.criteria[1].label, "Edited third")
    verify(object.saveInterests())
    compare(object.activeRequest.criteria.map(function(row) { return row.id }), ["topic.second", "topic.third"])
  }
  function test_removing_the_edited_interest_cannot_resurrect_it_or_overwrite_its_successor() {
    var object = service()
    object.inputs = inputs(1, [interest(), {id:"topic.other",kind:"topic",label:"Other",terms:["other"],enabled:true}])
    object.resetInterestsDraft()
    object.editInterest(0, interest())
    object.updateInterestEditor("label", "Unsaved edit to removed item")
    object.previewInterest()
    var previewSerial = object.interestPreviewSerial
    verify(object.changeInterest(0, true))
    compare(object.interestEditor, null)
    compare(object.pendingInterestPreview, null)
    verify(object.interestPreviewSerial > previewSerial)
    verify(!object.applyInterestEditor())
    compare(object.interestsDraft.criteria.length, 1)
    compare(object.interestsDraft.criteria[0].label, "Other")
  }
  function test_pausing_the_edited_interest_is_not_undone_by_applying_text_changes() {
    var object = service()
    object.editInterest(0, interest())
    object.updateInterestEditor("label", "Edited tablet")
    verify(object.changeInterest(0, false))
    compare(object.interestEditor.criterion.enabled, false)
    verify(object.applyInterestEditor())
    compare(object.interestsDraft.criteria[0].label, "Edited tablet")
    compare(object.interestsDraft.criteria[0].enabled, false)
  }
  function test_saved_interest_actions_remain_blocked_during_an_active_save() {
    var object = service()
    object.changeInterest(0, false)
    verify(object.saveInterests())
    verify(!object.changeInterest(0, true))
    verify(!object.changeInterest(0, false))
    compare(object.interestsDraft.criteria.length, 1)
    compare(object.interestsDraft.criteria[0].enabled, false)
  }
  function test_keep_watching_reuses_known_hardware_identity_and_existing_paused_criterion() {
    var object = service()
    var context = inputs(1, [interest()])
    context.featureChoices = [{id:"pen-tablet",label:"Pen or tablet",terms:["stylus", "tablet"]}]
    object.inputs = context
    var signal = {id:"pen-tablet",label:"Detected tablet",domain:"hardware",terms:["stylus"]}
    verify(object.keepWatching(signal))
    compare(object.interestEditor.criterion.featureId, "pen-tablet")
    compare(object.interestEditor.criterion.terms, ["stylus", "tablet"])
    compare(object.interestEditor.criterion.origin, "user")
    verify(object.applyInterestEditor())
    verify(object.changeInterest(1, false))
    verify(object.keepWatching(signal))
    compare(object.interestEditor.index, 1)
    verify(!object.interestEditor.criterion.enabled)
    verify(object.applyInterestEditor())
    compare(object.interestsDraft.criteria.length, 2)
    compare(object.inputs.criteria.length, 1)
  }
  function test_keep_watching_registered_capability_reuses_curated_service_criterion() {
    var object = service()
    var context = inputs(1, [])
    context.serviceChoices = [{id:"spotify",name:"Spotify",category:"Media"}]
    object.inputs = context
    object.resetInterestsDraft()
    var signal = {id:"capability-spotify",label:"Spotify executable",domain:"software",terms:["media player"]}
    verify(object.keepWatching(signal))
    compare(object.interestEditor.criterion.kind, "service")
    compare(object.interestEditor.criterion.serviceId, "spotify")
    verify(!object.interestEditor.criterion.featureId)
    verify(object.applyInterestEditor())
    verify(object.chooseInterest("service", context.serviceChoices[0]))
    compare(object.interestEditor.index, 0)
    verify(object.applyInterestEditor())
    compare(object.interestsDraft.criteria.length, 1)
    compare(object.setupServiceIds, [])
    compare(object.mutationQueue.length, 0)
  }
  function test_unknown_capability_keeps_user_literal_terms_and_reuses_equivalent_draft() {
    var object = service()
    var signal = {id:"capability-unlisted",label:"My device tools",domain:"software",terms:["[literal.*]", "Device tool"]}
    verify(object.keepWatching(signal))
    var criterion = object.interestEditor.criterion
    compare(criterion.kind, "topic")
    compare(criterion.origin, "user")
    compare(criterion.terms, signal.terms)
    verify(!criterion.featureId && !criterion.serviceId)
    verify(object.applyInterestEditor())
    signal.label = "Updated scan description"
    signal.terms = [" device   TOOL ", "[literal.*]"]
    verify(object.keepWatching(signal))
    compare(object.interestEditor.index, 1)
    compare(object.interestEditor.criterion.label, "My device tools")
    verify(object.applyInterestEditor())
    compare(object.interestsDraft.criteria.length, 2)
  }
  function test_explicit_edit_serial_does_not_change_for_typing_preview_or_context_refresh() {
    var object = service()
    object.editInterest(0, interest())
    var serial = object.interestEditSerial
    compare(object.interestsSection, "added")
    object.updateInterestEditor("label", "A draft")
    object.previewInterest()
    object.requestContext()
    object.flushInterestsRequests()
    reply(object, {inputs:inputs(2, [])})
    compare(object.interestEditSerial, serial)
    compare(object.interestEditor.criterion.label, "A draft")
    object.interestsSection = "detected"
    object.updateInterestEditor("termText", "another literal")
    compare(object.interestsSection, "detected")
    compare(object.interestEditSerial, serial)
  }

  function test_direct_choices_accumulate_without_an_editor_or_backend_request() {
    var object = service()
    object.setupServiceIds = ["browse-only"]
    object.setupSelection = {"example.queued":{id:"example.queued"}}
    verify(object.useDetected("device.ignored", false))
    var radio = {id:"radio",name:"Harbor Radio",category:"Media"}
    var network = {id:"mesh",name:"Quay Mesh",category:"Network"}
    var tablet = {id:"pen-tablet",label:"Pen or tablet",terms:["stylus", "tablet"]}
    verify(object.selectInterestChoice("service", radio, true))
    verify(object.selectInterestChoice("service", network, true))
    verify(object.selectInterestChoice("feature", tablet, true))
    compare(object.interestsDraft.criteria.length, 4)
    compare(object.interestsDraft.criteria[3].kind, "hardware")
    compare(object.interestsDraft.criteria[3].featureId, "pen-tablet")
    compare(object.interestsDraft.criteria[3].origin, "user")
    compare(object.interestEditor, null)
    compare(object.pendingInterestPreview, null)
    verify(!object.requestActive)
    verify(object.selectInterestChoice("service", radio, true))
    compare(object.interestsDraft.criteria.length, 4, "Selecting an existing choice must be idempotent")
    verify(object.selectInterestChoice("service", network, false))
    verify(object.interestChoiceSelected("service", radio))
    verify(!object.interestChoiceSelected("service", network))
    verify(object.interestChoiceSelected("feature", tablet))
    compare(object.inputs.criteria.length, 1)
    compare(object.interestsDraft.ignoredSignals, ["device.ignored"])
    compare(object.setupServiceIds, ["browse-only"])
    verify(object.setupSelected("example.queued"))
  }

  function test_direct_custom_dedupe_preserves_identity_paused_state_and_literal_terms() {
    var object = service()
    object.inputs = inputs(1, [{id:"topic.saved",kind:"topic",label:"Original name",
      terms:["Harbor   notes"],enabled:false,origin:"user"}])
    object.resetInterestsDraft()
    verify(object.addCustomInterest("  HARBOR notes  "))
    compare(object.interestsDraft.criteria.length, 1)
    compare(object.interestsDraft.criteria[0].id, "topic.saved")
    compare(object.interestsDraft.criteria[0].label, "Original name")
    verify(!object.interestsDraft.criteria[0].enabled)
    verify(object.interestsNotice.indexOf("still paused") >= 0)
    verify(!object.interestsDirty)
    verify(object.addCustomInterest("[literal.*], not a regex"))
    compare(object.interestsDraft.criteria[1].terms, ["[literal.*], not a regex"])
    verify(!object.addCustomInterest(" "))
    verify(!object.addCustomInterest("x".repeat(65)))
    compare(object.interestsDraft.criteria.length, 2)
    compare(object.inputs.criteria.length, 1)
  }

  function test_reselecting_paused_predefined_choice_does_not_resume_it() {
    var object = service()
    var choice = {id:"radio",name:"Harbor Radio"}
    object.inputs = inputs(1, [{id:"service.radio",kind:"service",label:"My radio",serviceId:"radio",terms:[],enabled:false}])
    object.resetInterestsDraft()
    verify(object.interestChoiceSelected("service", choice), "Selected is membership, not enabled state")
    verify(object.selectInterestChoice("service", choice, true))
    compare(object.interestsDraft.criteria.length, 1)
    verify(!object.interestsDraft.criteria[0].enabled)
    compare(object.interestsDraft.criteria[0].id, "service.radio")
    verify(object.changeInterest(0, false))
    verify(object.interestsDraft.criteria[0].enabled)
  }

  function test_single_save_includes_pending_edit_choices_and_ignored_inputs_once() {
    var object = service()
    object.setupServiceIds = ["browse-only"]
    object.browseDensity = "list"
    object.setupPage = 4
    object.editInterest(0, object.interestsDraft.criteria[0])
    object.updateInterestEditor("label", "Edited tablet")
    verify(object.addCustomInterest("New topic"))
    verify(object.selectInterestChoice("service", {id:"radio",name:"Harbor Radio"}, true))
    verify(object.useDetected("hardware.ignored", false))
    verify(object.saveInterests(), "Save must apply a valid pending edit without a separate Apply action")
    compare(object.interestEditor, null)
    compare(object.activeAction, "save-interests")
    compare(object.activeRequest.criteria.length, 3)
    compare(object.activeRequest.criteria[0].label, "Edited tablet")
    compare(object.activeRequest.criteria[0].id, "topic.pen")
    compare(object.activeRequest.ignoredSignals, ["hardware.ignored"])
    var generation = object.activeGeneration
    verify(!object.saveInterests())
    verify(!object.addCustomInterest("While saving"))
    verify(!object.selectInterestChoice("service", {id:"radio",name:"Harbor Radio"}, false))
    verify(!object.useDetected("another-device", false))
    compare(object.activeGeneration, generation)
    compare(object.mutationQueue.length, 0)
    var saved = inputs(2, object.activeRequest.criteria)
    saved.ignoredSignals = ["hardware.ignored"]
    reply(object, {inputs:saved, criteriaRevision:2})
    verify(!object.interestsDirty)
    compare(object.interestsDraft.criteria.length, 3)
    compare(object.setupServiceIds, ["browse-only"])
    compare(object.browseDensity, "list")
    compare(object.setupPage, 4)
    verify(!object.saveInterests(), "No second save is required after success")
  }

  function test_combined_save_conflict_preserves_edit_content_and_original_revision() {
    var object = service()
    object.editInterest(0, object.interestsDraft.criteria[0])
    object.updateInterestEditor("label", "Uncommitted tablet name")
    object.updateInterestEditor("termText", "my literal term")
    verify(object.addCustomInterest("A selected custom topic"))
    verify(object.useDetected("device.ignored", false))
    verify(object.saveInterests())
    var submitted = JSON.stringify(object.interestsDraft)
    reply(object, {ok:false,errorCode:"revision-conflict",error:"Saved interests changed. Reload before saving."})
    verify(object.interestsDirty)
    compare(JSON.stringify(object.interestsDraft), submitted)
    compare(object.interestsDraft.revision, 1)
    compare(object.interestsDraft.criteria[0].label, "Uncommitted tablet name")
    compare(object.interestsDraft.criteria[0].terms, ["my literal term"])
    verify(object.flushInterestsRequests())
    compare(object.activeAction, "context")
    reply(object, {inputs:inputs(2, [])})
    compare(JSON.stringify(object.interestsDraft), submitted, "A conflict refresh must not silently rebase or replace the draft")
    verify(object.interestsError.indexOf("changed") >= 0)
  }

  function test_invalid_or_duplicate_pending_editor_blocks_save_without_losing_selections() {
    var object = service()
    verify(object.addCustomInterest("Selected topic"))
    object.editInterest(-1, null)
    verify(!object.saveInterests())
    compare(object.interestsDraft.criteria.length, 2)
    verify(object.interestEditor !== null)
    verify(!object.requestActive)
    object.updateInterestEditor("label", "Duplicate of the selected topic")
    object.updateInterestEditor("termText", "selected TOPIC")
    verify(!object.saveInterests())
    verify(object.interestsError.indexOf("already selected") >= 0)
    compare(object.interestsDraft.criteria.length, 2)
    compare(object.interestEditor.termText, "selected TOPIC")
    object.updateInterestEditor("termText", "A different topic")
    verify(object.saveInterests())
    compare(object.activeRequest.criteria.length, 3)
  }
}
