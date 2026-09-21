import QtQuick
import QtTest
import "../.." as Plugin
import "../../ui" as Ui

TestCase {
  id: testCase
  name: "AppRoutes"
  when: windowShown
  Component { id: serviceComponent; Plugin.Service {} }
  Component { id: appComponent; Ui.OutfitApp {} }
  function app(discoveryEnabled) {
    var service = createTemporaryObject(serviceComponent, testCase, {discoveryEnabled:discoveryEnabled === true})
    service.receiveOutput(JSON.stringify({ok:true,action:"load",generation:service.activeRequest.generation,
      preferences:{watchHardware:false,readmeEnrichment:false,readmeIndexing:false,marketplaceThumbnails:false,services:[],browseDensity:"list"}}))
    service.hasAnalyzed = true
    service.inventoryReady = true
    service.setupRows = [{id:"example.browse",name:"Browse fixture",description:"A fixture",kind:"panel",readmeAvailable:false,installAvailable:true}]
    service.matches = {rows:[{id:"example.match",name:"Match fixture",description:"A saved interest match",kind:"panel",
      matchedInterests:[{id:"interest.fixture",label:"Drawing tablet",reason:"stylus in README"}],matchCause:"new-listing",
      unread:true,readmeAvailable:false,installAvailable:true}],total:1,unread:1,page:1,pageCount:1,partial:false,lastCheckedAt:100}
    service.inputs = {revision:1,criteria:[{id:"interest.fixture",kind:"topic",label:"Drawing tablet",terms:["stylus"],enabled:true}],
      detected:[],probes:[],ignoredSignals:[],serviceChoices:[],featureChoices:[]}
    service.inputsLoaded = true
    service.criteriaRevision = 1
    service.resetInterestsDraft()
    var view = createTemporaryObject(appComponent, testCase, {service:service})
    verify(view !== null)
    view.open(JSON.stringify({setupStage:"browse"}))
    wait(0)
    return view
  }
  function cleanup() {
    // Temporary services use process/file stubs; no helper or live preference access.
  }
  function finishSearch(view, metadata, rows) {
    var service = view.service
    compare(service.activeAction, "quick-setup")
    var request = service.activeRequest
    service.receiveOutput(JSON.stringify({ok:true,action:"quick-setup",generation:service.activeGeneration,
      setup:{rows:rows || [],total:rows ? rows.length : 0,search:metadata,query:request.setupQuery,
        sort:request.setupSort,group:request.setupGroup,grouping:request.setupGrouping,
        selectedServices:request.setupServices,installFilter:request.setupInstallFilter,
        partyFilter:request.setupPartyFilter,hardwareOnly:request.setupHardwareOnly,
        category:request.setupCategory,verification:request.setupVerification}}))
  }
  function searchView() {
    var view = app()
    finishSearch(view, {active:false,mode:"none",suggestion:null}, view.service.setupRows)
    return view
  }
  function editSearch(view, text) {
    var field = findChild(view, "browseSearchField")
    field.text = text
    field.textEdited()
    return field
  }
  function test_page_buttons_reset_results_after_loading_but_detail_back_keeps_position() {
    var view = searchView(), service = view.service
    function rows(page) {
      var result = []
      for (var i = 0; i < 24; i++) result.push({id:"example.page" + page + "row" + i,
        name:"Page " + page + " plugin " + i, description:"A fictional plugin",kind:"panel",installAvailable:true})
      return result
    }
    function finishPage(page) {
      service.receiveOutput(JSON.stringify({ok:true,action:"quick-setup",generation:service.activeGeneration,
        setup:{rows:rows(page),total:72,page:page,pageCount:3,grouping:"none",selectedServices:[],
          installFilter:"all",partyFilter:"all",hardwareOnly:false,category:"",verification:"all"}}))
      wait(0)
    }
    view.requestSetup("","",service.setupSort,1)
    finishPage(1)
    var scroll = findChild(view,"browseResultsScroll")
    verify(scroll !== null)
    scroll.contentItem.contentY = 600
    verify(scroll.contentItem.contentY > 0)
    findChild(view,"browseNextPage").clicked()
    compare(service.activeRequest.setupPage,2)
    compare(scroll.contentItem.contentY,0)
    verify(!findChild(view,"browseNextPage").enabled)
    // Simulate late layout/focus adjustment while old content is still present.
    scroll.contentItem.contentY = 350
    finishPage(2)
    compare(scroll.contentItem.contentY,0)
    compare(view.pageScrollSerial,-1)
    scroll.contentItem.contentY = 600
    findChild(view,"browsePreviousPage").clicked()
    compare(service.activeRequest.setupPage,1)
    finishPage(1)
    compare(scroll.contentItem.contentY,0)
    var card = view.browseCards()[5]
    scroll.contentItem.contentY = card.mapToItem(scroll.contentItem,0,0).y
    var saved = scroll.contentItem.contentY
    view.openSetupDetail(card.pluginRow,card)
    wait(0)
    view.goBack()
    wait(0)
    compare(scroll.contentItem.contentY,saved)
    view.close()
  }
  function test_search_controls_auto_manual_clear_browse_all_and_resume() {
    var view = searchView(), service = view.service
    var picker = findChild(view, "browseSortPicker")
    picker.changed("likes")
    finishSearch(view)
    var field = editSearch(view, "midi")
    compare(picker.value, "relevance")
    compare(picker.options[0].label, "Best match")
    verify(picker.options.some(function(option) { return option.value === "recommended" }))
    field.accepted()
    compare(service.activeRequest.setupSort, "relevance")
    finishSearch(view)
    picker.changed("name")
    finishSearch(view)
    field = editSearch(view, "midi controller")
    field.accepted()
    compare(service.activeRequest.setupSort, "name")
    finishSearch(view)
    var resume = view.editorResumePayload("")
    compare(resume.browseSort, "likes")
    view.close()
    view.open(JSON.stringify(resume))
    compare(service.activeRequest.setupSort, "name")
    finishSearch(view)
    view.browseAll()
    compare(service.activeRequest.setupQuery, "")
    compare(service.activeRequest.setupSort, "likes")
    finishSearch(view)
    field = editSearch(view, "midi")
    field.accepted()
    finishSearch(view)
    field = editSearch(view, "")
    field.accepted()
    compare(service.activeRequest.setupSort, "likes")
    verify(!picker.options.some(function(option) { return option.value === "relevance" }))
    compare(findChild(view, "serviceShortcutsHeading").text, "SELECT A FILTER")
    view.close()
  }
  function test_search_enter_stops_debounce_and_old_payload_retains_explicit_sort() {
    var view = searchView(), service = view.service
    view.close()
    view.open(JSON.stringify({setupQuery:"midi",setupSort:"activity"}))
    compare(service.activeRequest.setupSort, "activity")
    finishSearch(view)
    var field = editSearch(view, "midi controller")
    field.forceActiveFocus()
    keyClick(Qt.Key_Return)
    compare(service.activeRequest.setupQuery, "midi controller")
    compare(service.activeRequest.setupSort, "activity")
    var generation = service.activeGeneration
    wait(130)
    compare(service.activeGeneration, generation)
    compare(service.pendingSetup, null)
    view.close()
  }
  function test_startup_load_keeps_search_edited_after_open() {
    var service = createTemporaryObject(serviceComponent, testCase)
    var view = createTemporaryObject(appComponent, testCase, {service:service})
    view.open(JSON.stringify({setupQuery:"old",setupSort:"name"}))
    var field = editSearch(view, "new query")
    service.receiveOutput(JSON.stringify({ok:true,action:"load",generation:service.activeGeneration,
      preferences:{watchHardware:false,readmeEnrichment:false,marketplaceThumbnails:false}}))
    tryCompare(service, "activeAction", "quick-setup")
    compare(service.activeRequest.setupQuery, "new query")
    compare(service.activeRequest.setupSort, "name")
    compare(field.text, "new query")
    view.close()
  }
  function test_typo_suggestion_data() {
    return [{tag:"click", keyboard:false}, {tag:"enter", keyboard:true}]
  }
  function test_typo_suggestion(data) {
    var view = searchView(), service = view.service
    service.setupVerification = "verified"
    service.quickSetup("midii", "media", "stars", 1, ["spotify"], "",
      "installed", "third-party", true, "Music", "category")
    findChild(view, "browseSearchField").text = "midii"
    finishSearch(view, {active:true,mode:"none",suggestion:{query:"midi",label:"Did you mean MIDI?"}})
    wait(0)
    var suggestion = findChild(view, "searchSuggestion")
    verify(suggestion.visible)
    compare(suggestion.text, "Did you mean MIDI?")
    compare(service.setupQuery, "midii")
    compare(findChild(view, "partialSearchStatus").visible, false)
    if (data.keyboard) {
      findChild(view, "browseSortPicker").forceActiveFocus()
      view.moveFilterFocus(Qt.Key_Down)
      verify(suggestion.activeFocus)
      keyClick(Qt.Key_Return)
    } else mouseClick(suggestion)
    compare(findChild(view, "browseSearchField").text, "midi")
    var request = service.activeRequest
    compare(request.setupQuery, "midi")
    compare(request.setupSort, "relevance")
    compare(request.setupServices, ["spotify"])
    compare(request.setupGroup, "media")
    compare(request.setupInstallFilter, "installed")
    compare(request.setupPartyFilter, "third-party")
    compare(request.setupHardwareOnly, true)
    compare(request.setupCategory, "Music")
    compare(request.setupVerification, "verified")
    compare(request.setupGrouping, "category")
    compare(request.setupPage, 1)
    verify(!suggestion.visible)
    finishSearch(view, {active:true,mode:"partial",suggestion:null}, [{id:"example.partial",name:"Partial fixture"}])
    verify(findChild(view, "partialSearchStatus").visible)
    editSearch(view, "midi controller")
    verify(!findChild(view, "partialSearchStatus").visible)
    verify(!suggestion.visible)
    view.close()
  }
  function test_search_excerpt_data() {
    return ["comfortable", "compact", "dense", "list"].map(function(mode) { return {tag:mode,mode:mode} })
  }
  function test_search_excerpt(data) {
    var view = searchView(), service = view.service
    service.browseDensity = data.mode
    var field = editSearch(view, "midi")
    field.accepted()
    var row = {id:"example.excerpt",name:"Excerpt fixture",description:"Normal catalog description",
      searchReason:"README match",searchSnippet:"<b>MIDI</b> & controller support",kind:"panel",stars:42}
    finishSearch(view, {active:true,mode:"complete",suggestion:null}, [row])
    wait(0)
    var cards = view.browseCards()
    compare(cards.length, 1)
    var copy = findChild(cards[0], data.mode === "list" ? "listCardCopy" : "gridCardCopy")
    verify(copy.visible)
    var label = findChild(copy, "searchExcerptLabel"), text = findChild(copy, "cardDescription")
    compare(label.text, "README match")
    verify(label.visible)
    compare(text.text, row.searchSnippet)
    compare(text.textFormat, Text.PlainText)
    compare(label.textFormat, Text.PlainText)
    compare(text.Accessible.name, row.searchSnippet)
    verify(!findChild(view, "partialSearchStatus").visible)
    var height = cards[0].height
    editSearch(view, "")
    compare(text.text, row.description)
    verify(!label.visible)
    if (data.mode !== "list") compare(cards[0].height, height)
    // Old search fields on cached rows cannot keep excerpts visible after clear.
    field.accepted()
    finishSearch(view, {active:false,mode:"none",suggestion:null}, [row])
    wait(0)
    copy = findChild(view.browseCards()[0], data.mode === "list" ? "listCardCopy" : "gridCardCopy")
    compare(findChild(copy, "cardDescription").text, row.description)
    verify(!findChild(copy, "searchExcerptLabel").visible)
    view.close()
  }
  function test_production_routes_hide_discover_and_coerce_legacy_summons() {
    var view = app()
    verify(!view.discoveryEnabled)
    var entry = findChild(view, "discoverViewButton")
    verify(entry !== null && !entry.visible && !entry.enabled)
    view.chooseWorkspace("discover")
    view.chooseDiscoverTab("matches")
    compare(view.workspaceView, "browse")
    compare(view.service.discoverTab, "ideas")
    view.close()
    view.open(JSON.stringify({workspaceView:"discover",discoverTab:"matches",discoveryEnabled:true}))
    compare(view.workspaceView, "browse")
    compare(view.service.workspaceView, "browse")
    compare(view.editorResumePayload("").workspaceView, "browse")
    compare(view.service.unreadMatches, 0)
    compare(view.detailMetadata(view.service.matches.rows[0]).matchLabel, "")
    view.openInterests(null)
    verify(view.interestsOpen)
    view.leaveInterests()
    compare(view.workspaceView, "browse")
    view.close()
  }
  function test_apps_reopen_rearms_standalone_uninstall_recovery_data() {
    return [{tag:"closed-panel", closedDuringBatch:false},
      {tag:"finished-closed-batch", closedDuringBatch:true}]
  }
  function test_apps_reopen_rearms_standalone_uninstall_recovery(data) {
    var view = app()
    var service = view.service
    service.batchRunning = data.closedDuringBatch
    view.requestClose()
    verify(service.editorRestoreSuppressed)
    verify(!service.editorOpen)
    service.batchRunning = false
    // The Apps launcher goes straight through the panel's open(), unlike the
    // bar widget's Service.openEditor(). Both must begin a fresh open session.
    view.open("{}")
    verify(service.editorOpen)
    service.inventory = [{id:"example.browse",enabled:true,firstParty:false}]
    verify(service.removePlugin({id:"example.browse"}, view.editorResumePayload("example.browse")))
    verify(service.editorRestorePayload !== null)
    compare(service.editorRestorePayload.selectedId, "example.browse")
    compare(service.editorRestoreState, "armed")
    // An intentional close during this operation must still cancel recovery.
    view.requestClose()
    compare(service.editorRestorePayload, null)
    verify(service.editorRestoreSuppressed)
  }
  function test_apps_reopen_during_a_closed_batch_keeps_batch_suppression() {
    var view = app()
    var service = view.service
    service.batchRunning = true
    view.requestClose()
    view.open("{}")
    verify(service.batchCloseSuppressed)
    verify(!service.prepareEditorRestore(view.editorResumePayload("example.next"), "example.next"))
    view.requestClose()
  }
  function test_settings_and_browse_routes_share_manager_and_restore_drafts() {
    var view = app()
    view.draftReadmes = true
    view.settingsTouched = true
    view.settingsOpen = true
    view.openInterests(null)
    verify(view.interestsOpen && view.interestsFromSettings)
    view.service.editInterest(0, view.service.interestsDraft.criteria[0])
    view.service.updateInterestEditor("label", "Draft label")
    view.leaveInterests()
    wait(0)
    verify(view.settingsOpen && view.settingsTouched && view.draftReadmes)
    compare(view.service.interestEditor.criterion.label, "Draft label")
    view.leaveSettings()
    view.openServicesPicker()
    verify(view.interestsOpen && !view.interestsFromSettings)
    compare(view.service.interestEditor.criterion.label, "Draft label")
    view.leaveInterests()
    compare(view.workspaceView, "browse")
    compare(view.browseDensity, "list")
    view.close()
  }
  function serviceShortcutsFixture() {
    var view = app()
    var service = view.service
    if (service.requestActive) service.receiveOutput(JSON.stringify({ok:true,
      action:service.activeAction, generation:service.activeGeneration,
      setup:{rows:service.setupRows, services:[]}}))
    service.preferences = Object.assign({}, service.preferences, {services:["tailscale", "sonos", "spotify"]})
    service.serviceOptions = [{id:"tailscale",name:"Tailscale",total:19},
      {id:"sonos",name:"Sonos",total:2}, {id:"spotify",name:"Spotify",total:14}]
    service.inputs = Object.assign({}, service.inputs, {criteria:service.serviceOptions.map(function(row) {
      return {id:"service." + row.id,kind:"service",serviceId:row.id,label:row.name,terms:[row.id],enabled:true}
    })})
    service.resetInterestsDraft()
    return view
  }
  function shortcutIds(view) {
    return view.savedServiceOptions().map(function(row) { return row.id })
  }
  function interestShortcutsFixture() {
    var view = serviceShortcutsFixture(), service = view.service
    service.inputs = Object.assign({}, service.inputs, {criteria:[
      {id:"interest.midi",kind:"topic",label:"MIDI",terms:["midi"],enabled:true},
      {id:"interest.airpods",kind:"hardware",featureId:"bluetooth-airpods",label:"AirPods",
        terms:["airpods", "apple headphones"],enabled:true},
      {id:"service.spotify",kind:"service",serviceId:"spotify",label:"Spotify",terms:[],enabled:true}]})
    service.resetInterestsDraft()
    return view
  }
  function finishSetup(view, services) {
    var service = view.service
    compare(service.activeAction, "quick-setup")
    service.receiveOutput(JSON.stringify({ok:true,action:service.activeAction,generation:service.activeGeneration,
      setup:{rows:service.setupRows,services:services || [],selectedServices:service.setupServiceIds,
        query:service.setupQuery,installFilter:service.setupInstallFilter,partyFilter:service.setupPartyFilter,
        category:service.setupCategory}}))
  }
  function test_sidebar_custom_hardware_and_service_clicks_send_mappings_without_search_injection() {
    var view = interestShortcutsFixture(), service = view.service
    var options = view.savedServiceOptions(), midi = options[0].id, airpods = options[1].id
    compare(options.map(function(row) { return row.name }), ["MIDI", "AirPods", "Spotify"])
    compare(options[0].total, null)
    compare(options[1].total, null)
    compare(options[2].total, 14)
    var shortcuts = findChild(view, "serviceShortcuts")
    tryCompare(shortcuts, "count", 3)
    shortcuts.itemAt(0).clicked()
    compare(service.activeAction, "quick-setup")
    compare(service.activeRequest.setupServices, [midi])
    compare(service.activeRequest.setupQuery, "")
    compare(service.activeRequest.setupInterestCriteria.map(function(row) { return row.key }), [midi, airpods])
    compare(service.activeRequest.setupInterestCriteria[0].criterion.terms, ["midi"])
    compare(service.setupInterestCriteria.map(function(row) { return row.key }), [midi])
    compare(service.pendingInterestPreview, null)
    compare(service.mutationQueue, [])
    verify(!service.backgroundBusy)
    finishSetup(view, [{id:midi,name:"MIDI",total:2},{id:airpods,name:"AirPods",total:1},
      {id:"spotify",name:"Spotify",total:14}])
    compare(view.savedServiceOptions()[0].total, 2)
    compare(view.savedServiceOptions()[1].total, 1)
    shortcuts.itemAt(1).clicked()
    compare(service.activeRequest.setupServices, [midi, airpods])
    finishSetup(view)
    shortcuts.itemAt(2).clicked()
    compare(service.activeRequest.setupServices, [midi, airpods, "spotify"])
    compare(service.activeRequest.setupQuery, "")
    compare(service.activeRequest.setupInterestCriteria.length, 2)
    view.close()
  }
  function test_custom_and_hardware_draft_pause_remove_keep_active_filter_snapshots() {
    var view = interestShortcutsFixture(), service = view.service
    var ids = shortcutIds(view)
    service.quickSetup("keyboard", "", "stars", 1, ids, "", "installed", "third-party", false, "Utility")
    finishSetup(view)
    var snapshot = JSON.stringify(service.setupInterestCriteria)
    verify(service.changeInterest(0, false))
    verify(service.changeInterest(1, true))
    compare(shortcutIds(view), ["spotify"])
    compare(service.setupServiceIds, ids)
    view.queueCurrentSetup()
    compare(service.activeRequest.setupServices, ids)
    compare(JSON.stringify(service.activeRequest.setupInterestCriteria), snapshot)
    compare(service.activeRequest.setupInstallFilter, "installed")
    compare(service.activeRequest.setupCategory, "Utility")
    var payload = view.editorResumePayload("")
    compare(payload.setupInterestCriteria.length, 2)
    finishSetup(view)
    view.close()
    service.setupInterestCriteria = []
    service.setupServiceIds = []
    view.open(JSON.stringify(payload))
    compare(service.setupServiceIds, ids)
    compare(JSON.stringify(service.activeRequest.setupInterestCriteria), snapshot)
    compare(shortcutIds(view), ["spotify"])
    finishSetup(view)
    view.toggleSetupService(ids[0])
    compare(service.setupInterestCriteria.map(function(row) { return row.key }), [ids[1]])
    finishSetup(view)
    service.resetInterestsDraft()
    compare(shortcutIds(view), ids)
    view.close()
  }
  function test_draft_filter_semantic_keys_and_selection_survive_save_generated_ids() {
    var view = serviceShortcutsFixture(), service = view.service
    verify(service.addCustomInterest("MIDI"))
    verify(service.selectInterestChoice("feature", {id:"pen-tablet",label:"Pen or tablet",terms:["stylus", "tablet"]}, true))
    var ids = shortcutIds(view), midi = ids[3], tablet = ids[4]
    verify(/^interest-[0-9a-f]{32}$/.test(midi))
    verify(/^interest-[0-9a-f]{32}$/.test(tablet))
    service.quickSetup("", "", "stars", 1, [midi, tablet])
    finishSetup(view)
    verify(service.saveInterests())
    var saved = JSON.parse(JSON.stringify(service.inputs))
    saved.revision = 2
    saved.criteria = JSON.parse(JSON.stringify(service.activeRequest.criteria))
    saved.criteria[3].id = "interest.generated-midi"
    saved.criteria[3].terms = ["midi"]
    saved.criteria[4].id = "interest.generated-tablet"
    // The backend expands curated features to their canonical matching aliases.
    saved.criteria[4].terms = ["stylus", "active pen", "wacom", "tablet"]
    service.receiveOutput(JSON.stringify({ok:true,action:"save-interests",generation:service.activeGeneration,
      inputs:saved,criteriaRevision:2}))
    verify(!service.interestsDirty)
    compare(shortcutIds(view), ids)
    compare(service.setupServiceIds, [midi, tablet])
    view.queueCurrentSetup()
    var request = service.pendingSetup || service.activeRequest
    compare(request.setupServices, [midi, tablet])
    compare(request.setupInterestCriteria.map(function(row) { return row.key }), [midi, tablet])
    compare(request.setupInterestCriteria[0].criterion.id, "interest.generated-midi")
    view.close()
  }
  function test_sidebar_tracks_draft_removal_and_pause_and_discard_restores_saved_shortcuts() {
    var view = serviceShortcutsFixture()
    var service = view.service
    service.setupServiceIds = ["tailscale"]
    compare(shortcutIds(view), ["tailscale", "sonos", "spotify"])
    verify(service.changeInterest(0, true))
    compare(shortcutIds(view), ["sonos", "spotify"])
    verify(service.changeInterest(0, false))
    compare(shortcutIds(view), ["spotify"])
    var shortcuts = findChild(view, "serviceShortcuts")
    tryCompare(shortcuts, "count", 1)
    verify(findChild(view, "serviceShortcutsSaveNotice").visible)
    compare(service.preferences.services, ["tailscale", "sonos", "spotify"])
    compare(service.setupServiceIds, ["tailscale"])
    service.resetInterestsDraft()
    compare(shortcutIds(view), ["tailscale", "sonos", "spotify"])
    tryCompare(shortcuts, "count", 3)
    verify(!findChild(view, "serviceShortcutsSaveNotice").visible)
    view.close()
  }
  function test_sidebar_save_uses_canonical_empty_list_despite_stale_preference_mirror() {
    var view = serviceShortcutsFixture()
    var service = view.service
    while (service.interestsDraft.criteria.length) verify(service.changeInterest(0, true))
    compare(shortcutIds(view), [])
    var save = findChild(view, "saveShortcutChanges")
    verify(save.visible && save.enabled)
    compare(save.text, "Save interests")
    save.clicked()
    compare(service.activeAction, "save-interests")
    compare(service.activeRequest.criteria, [])
    var saved = Object.assign({}, service.inputs, {revision:2, criteria:[]})
    service.receiveOutput(JSON.stringify({ok:true,action:"save-interests",generation:service.activeGeneration,
      inputs:saved, criteriaRevision:2, preferences:service.preferences}))
    verify(!service.interestsDirty)
    compare(shortcutIds(view), [])
    compare(findChild(view, "serviceShortcuts").count, 0)
    verify(!save.visible)
    view.close()
    view.open(JSON.stringify({setupStage:"browse"}))
    compare(shortcutIds(view), [])
    view.close()
  }
  function test_sidebar_review_keeps_editor_and_removed_interest_draft() {
    var view = serviceShortcutsFixture()
    var service = view.service
    service.editInterest(-1, null)
    service.updateInterestEditor("label", "Unsaved new topic")
    service.changeInterest(0, true)
    var review = findChild(view, "saveShortcutChanges")
    compare(review.text, "Review changes…")
    verify(review.enabled)
    review.clicked()
    verify(view.interestsOpen)
    compare(service.interestsSection, "added")
    compare(service.interestEditor.criterion.label, "Unsaved new topic")
    compare(shortcutIds(view), ["sonos", "spotify"])
    view.leaveInterests()
    compare(shortcutIds(view), ["sonos", "spotify"])
    view.close()
  }
  function test_sidebar_can_save_removals_when_new_editor_is_completely_empty() {
    var view = serviceShortcutsFixture()
    var service = view.service
    service.editInterest(-1, null)
    service.changeInterest(0, true)
    verify(!view.shortcutSaveNeedsReview())
    var save = findChild(view, "saveShortcutChanges")
    compare(save.text, "Save interests")
    verify(save.enabled)
    save.clicked()
    compare(service.interestEditor, null)
    compare(service.activeAction, "save-interests")
    compare(service.activeRequest.criteria.map(function(row) { return row.serviceId }), ["sonos", "spotify"])
    view.close()
  }
  function test_sidebar_preference_fallback_is_only_used_before_context_loads() {
    var view = serviceShortcutsFixture()
    var service = view.service
    service.inputsLoaded = false
    compare(shortcutIds(view), ["tailscale", "sonos", "spotify"])
    service.inputs = Object.assign({}, service.inputs, {criteria:[]})
    service.inputsLoaded = true
    compare(shortcutIds(view), [])
    view.close()
  }
  function test_matches_inspector_never_replaces_browse_rows_or_marks_reviewed() {
    var view = app(true)
    view.chooseWorkspace("discover")
    view.chooseDiscoverTab("matches")
    var before = JSON.stringify(view.service.setupRows)
    view.openSetupDetail(view.matchRows[0], null)
    wait(0)
    compare(view.setupDetailId, "example.match")
    compare(view.setupDetailRow.matchedInterests[0].label, "Drawing tablet")
    compare(JSON.stringify(view.service.setupRows), before)
    compare(view.service.unreadMatches, 1)
    compare(view.service.pendingMatchReview, null)
    compare(Object.keys(view.service.setupSelection).length, 0)
    view.closeSetupDetail()
    view.openInterests(null)
    view.leaveInterests()
    compare(view.workspaceView, "discover")
    compare(view.discoverTab, "matches")
    view.close()
  }
  function test_finished_batch_does_not_force_progress_on_open_and_restore_token_is_acknowledged() {
    var view = app(true)
    view.service.batchItems = [{id:"example.done",status:"completed"}]
    view.close()
    view.open(JSON.stringify({setupStage:"browse",workspaceView:"discover",discoverTab:"matches"}))
    compare(view.setupStage, "browse")
    view.openSetupDetail(view.matchRows[0], null)
    var payload = view.editorResumePayload("example.match")
    view.service.prepareEditorRestore(payload, "")
    view.service.editorRestoreToken = "test-restore"
    view.service.editorRestoreAckDeadline = Date.now() + 5000
    view.close()
    payload.restoreToken = "test-restore"
    view.open(JSON.stringify(payload))
    wait(0)
    compare(view.service.editorRestoreToken, "")
    compare(view.setupDetailId, "example.match")
    compare(view.discoverTab, "matches")
    view.close()
  }
  function test_all_density_modes_remain_available_after_manager_round_trip() {
    var view = app()
    for (var i = 0; i < 4; i++) {
      var density = ["comfortable", "compact", "dense", "list"][i]
      view.chooseDensity(density)
      view.openInterests(null)
      view.leaveInterests()
      wait(0)
      compare(view.browseDensity, density)
      compare(view.setupRows[0].id, "example.browse")
      verify(view.browseCards().length > 0)
    }
    view.close()
  }
  function test_curated_feature_direct_selection_uses_hardware_contract_and_toggles_membership() {
    var view = app()
    var manager = findChild(view, "interestsManager")
    view.openInterests(null)
    manager.choose("feature", {id:"pen-tablet",label:"Pen or tablet",terms:["stylus", "tablet"]})
    compare(view.service.interestEditor, null)
    compare(view.service.interestsDraft.criteria[1].kind, "hardware")
    compare(view.service.interestsDraft.criteria[1].featureId, "pen-tablet")
    compare(view.service.interestsDraft.criteria.length, 2)
    manager.choose("feature", {id:"pen-tablet",label:"Pen or tablet",terms:["stylus", "tablet"]})
    compare(view.service.interestsDraft.criteria.length, 1)
    manager.choose("feature", {id:"pen-tablet",label:"Pen or tablet",terms:["stylus", "tablet"]})
    compare(view.service.interestsDraft.criteria.length, 2)
    compare(view.service.inputs.criteria.length, 1)
    compare(view.service.pendingInterestPreview, null)
    view.close()
  }
  function test_legacy_service_link_opens_canonical_manager_and_reset_keeps_interests() {
    var view = app()
    view.close()
    // Closing retires an in-flight read-only helper; model its real exit before
    // asking the next session to perform a settings write.
    findChild(view.service,"queryWorker").exited(0,0)
    view.open(JSON.stringify({setupStage:"services"}))
    verify(view.interestsOpen)
    var before = JSON.stringify(view.service.interestsDraft)
    view.leaveInterests()
    // Finish the stubbed opening query, then reset only display/scanning settings.
    view.service.receiveOutput(JSON.stringify({ok:true,action:view.service.activeAction,
      generation:view.service.activeGeneration,setup:{rows:view.service.setupRows}}))
    view.resetSettings()
    compare(view.service.activeAction, "save-preferences")
    compare(JSON.stringify(view.service.interestsDraft), before)
    compare(view.service.matches.unread, 1)
    compare(view.service.unreadMatches, 0)
    verify(view.service.activeRequest.preferences.watchHardware)
    view.close()
  }
  function test_grouped_detected_toggle_only_changes_ignored_inputs_and_info_is_readonly() {
    var view = app()
    var inputs = JSON.parse(JSON.stringify(view.service.inputs))
    inputs.detected = [{id:"pen-tablet",label:"Tablet",domain:"hardware",method:"sysfs",freshness:"stale",detail:"Last confirmed tablet",
      terms:["stylus"],enabled:true}]
    inputs.probes = [{id:"input devices",state:"unavailable",reason:"Fixture probe unavailable"}]
    view.service.inputs = inputs
    view.openInterests(null)
    wait(0)
    var manager = findChild(view, "interestsManager")
    var repeater = findChild(manager, "detectedGroups")
    verify(repeater !== null)
    compare(repeater.count, 1)
    var toggle = findChild(repeater.itemAt(0), "detectedUse.pen-tablet")
    verify(toggle !== null)
    verify(toggle.selected)
    toggle.clicked()
    verify(!view.service.detectedEnabled("pen-tablet"))
    compare(view.service.inputs.ignoredSignals.length, 0)
    compare(findChild(manager, "keepWatching.pen-tablet"), null)
    var before = JSON.stringify(view.service.interestsDraft)
    var info = findChild(manager, "detectedInfo.pen-tablet")
    verify(info !== null && info.enabled)
    info.clicked()
    verify(info.selected)
    compare(JSON.stringify(view.service.interestsDraft), before)
    compare(view.service.interestEditor, null)
    compare(view.service.inputs.criteria.length, 1)
    compare(view.service.interestsDraft.criteria.length, 1)
    compare(Object.keys(view.service.setupSelection).length, 0)
    view.close()
  }

  function test_picker_service_choices_update_sidebar_without_changing_browse_filters() {
    var view = serviceShortcutsFixture(), service = view.service
    service.setupServiceIds = ["tailscale"]
    service.useDetected("device.ignored", false)
    view.openInterests(null)
    var manager = findChild(view, "interestsManager")
    manager.choose("service", {id:"tailscale",name:"Tailscale"})
    manager.choose("service", {id:"calendar",name:"Calendar"})
    compare(shortcutIds(view), ["sonos", "spotify", "calendar"])
    compare(service.setupServiceIds, ["tailscale"])
    compare(service.preferences.services, ["tailscale", "sonos", "spotify"])
    compare(service.interestsDraft.ignoredSignals, ["device.ignored"])
    compare(service.interestEditor, null)
    view.leaveInterests()
    compare(shortcutIds(view), ["sonos", "spotify", "calendar"])
    view.openInterests(null)
    compare(shortcutIds(view), ["sonos", "spotify", "calendar"])
    service.resetInterestsDraft()
    compare(shortcutIds(view), ["tailscale", "sonos", "spotify"])
    compare(service.setupServiceIds, ["tailscale"])
    view.close()
  }
}
