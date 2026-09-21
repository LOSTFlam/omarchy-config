import QtQuick
import QtTest
import "../../ui/InspectorState.js" as State

TestCase {
  name: "InspectorPresentation"
  function context(extra) {
    var value = { inventoryReady:true, selected:false, batchRunning:false, selfId:"io.github.ctl0v0.outfit" }
    for (var key in (extra || {})) value[key] = extra[key]
    return value
  }
  function row() { return {id:"example.widget", installAvailable:true, barWidget:true, kinds:["bar-widget"]} }
  function entry(enabled) { return {id:"example.widget", enabled:enabled, kinds:["bar-widget"],
    canDisable:true, firstParty:false, barSection:"right", barSectionKnown:true} }
  function test_confirmed_inventory_wins_over_optimistic_and_listing_flags() {
    var pending = State.resolve(row(), null, context({operation:{pending:true,status:"active",action:"install-plugin",desiredInstalled:true}}))
    compare(pending.state, "pending")
    verify(!pending.installed)
    verify(!pending.canInstall)
    var installed = State.resolve({id:"example.widget", installed:false}, entry(true), context())
    compare(installed.state, "installed")
    compare(installed.action, "")
    verify(installed.canToggle)
  }
  function test_unknown_inventory_has_no_mutation_actions() {
    var unknown = State.resolve(row(), null, context({inventoryReady:false}))
    compare(unknown.state, "unknown")
    verify(!unknown.canInstall && !unknown.canRemove && !unknown.canToggle && !unknown.canPlace)
  }
  function test_disabled_location_is_a_draft_and_unknown_active_location_stays_unknown() {
    var disabled = State.resolve(row(), entry(false), context({rememberedSection:"left"}))
    compare(disabled.selectedSection, "left")
    compare(disabled.actualSection, "right")
    var local = entry(true)
    local.barSectionKnown = false
    var active = State.resolve(row(), local, context({rememberedSection:"left"}))
    compare(active.selectedSection, "")
  }
  function test_ordinary_and_replacement_install_defaults() {
    verify(State.installDefaults(row(), "").enable)
    verify(!State.installDefaults({id:"example.bar", kinds:["bar"]}, "").enable)
    compare(State.installDefaults(row(), "left").section, "left")
  }
  function test_self_protection_keeps_widget_placement_available() {
    var self = row()
    self.id = "io.github.ctl0v0.outfit"
    var own = State.resolve(self, entry(true), context())
    verify(!own.canRemove && !own.canToggle)
    verify(own.canPlace)
    var builtIn = entry(true)
    builtIn.firstParty = true
    verify(!State.resolve(row(), builtIn, context()).canRemove)
  }
  function test_queue_manual_and_batch_recovery_have_distinct_actions() {
    compare(State.resolve(row(), null, context({selected:true})).action, "review")
    var manual = {id:"example.manual", installAvailable:false, repo:"https://github.com/example/manual"}
    compare(State.resolve(manual, null, context()).action, "project")
    compare(State.projectUrl({repo:"file:///private"}), "")
    compare(State.resolve(row(), entry(false), context({operation:{status:"failed",error:"activation failed",
      lastAction:"install-plugin",lastRequest:{batchItem:true}}})).action, "progress")
    var partial = State.resolve(row(), entry(false), context({operation:{status:"partial",lastAction:"install-plugin"}}))
    compare(partial.primaryLabel, "Finish installation")
    verify(!partial.canToggle)
  }
  function test_off_list_snapshot_is_restorable_without_changing_identity() {
    var saved = {id:"example.old", name:"Old selection", listingCommit:"original"}
    compare(State.snapshotFor("example.old", [{id:"example.other"}], saved), saved)
    compare(State.snapshotFor("example.missing", [], saved), null)
    var fresh = {id:"example.old", name:"Fresh listing"}
    compare(State.snapshotFor("example.old", [fresh], saved), fresh)
  }
  function test_open_uses_only_confirmed_enabled_standard_window_capabilities_data() {
    return [
      {tag:"panel", kinds:["panel"], enabled:true, canOpen:true},
      {tag:"overlay", kinds:["overlay"], enabled:true, canOpen:true},
      {tag:"menu", kinds:["menu"], enabled:true, canOpen:true},
      {tag:"widget with panel", kinds:["bar-widget", "panel"], enabled:true, canOpen:true},
      {tag:"widget only", kinds:["bar-widget"], enabled:true, canOpen:false},
      {tag:"service only", kinds:["service"], enabled:true, canOpen:false},
      {tag:"bar only", kinds:["bar"], enabled:true, canOpen:false},
      {tag:"disabled", kinds:["panel"], enabled:false, canOpen:false},
      {tag:"unknown enabled", kinds:["panel"], enabled:"true", canOpen:false},
      {tag:"unknown kinds", kinds:null, enabled:true, canOpen:false},
      {tag:"scalar kinds", kinds:"panel", enabled:true, canOpen:false},
      {tag:"malformed kinds", kinds:["panel", {}], enabled:true, canOpen:false},
      {tag:"future kinds", kinds:["panel", "unknown"], enabled:true, canOpen:false}
    ]
  }
  function test_open_uses_only_confirmed_enabled_standard_window_capabilities(data) {
    var local = entry(data.enabled)
    local.kinds = data.kinds
    var listing = row()
    listing.kinds = ["panel"]
    listing.enabled = true
    var state = State.resolve(listing, local, context())
    compare(state.canOpen, data.canOpen)
    if (data.canOpen) { compare(state.action, "open"); compare(state.primaryLabel, "Open") }
    else verify(state.openHint.length > 0)
    if (data.enabled !== true && data.enabled !== false) compare(state.action, "")
  }
  function test_disabled_primary_requires_a_real_toggle_and_never_invents_builtin_open_support() {
    var local = entry(false)
    local.kinds = ["bar-widget", "panel"]
    compare(State.resolve(row(), local, context()).action, "enable")
    local.firstParty = true
    local.canDisable = false
    var state = State.resolve(row(), local, context())
    compare(state.action, "")
    verify(!state.canOpen)
    verify(state.openHint.toLowerCase().indexOf("enable to open") < 0)
    local.enabled = true
    state = State.resolve(row(), local, context())
    verify(state.canOpen)
    verify(!state.canRemove)
    local.id = "io.github.ctl0v0.outfit"
    state = State.resolve({id:local.id}, local, context())
    verify(!state.canOpen && !state.canToggle && !state.canActivateBar)
    compare(state.action, "")
  }
  function test_canonical_full_bar_has_precedence_over_listing_widget_and_exclusive_flags() {
    var local = entry(false)
    local.kinds = ["bar", "bar-widget"]
    local.canDisable = false
    local.active = false
    var state = State.resolve(row(), local, context())
    verify(state.exclusive && state.canActivateBar)
    verify(!state.widget && !state.canPlace && !state.canToggle && !state.canOpen)
    compare(state.action, "activate")
    compare(state.primaryLabel, "Activate…")
    delete local.active
    compare(State.resolve(row(), local, context()).action, "activate")
    local.active = true
    local.enabled = true
    verify(!State.resolve(row(), local, context()).canActivateBar)
    var misleading = {id:local.id, barWidget:true, kinds:["bar"], kind:"bar", exclusiveActivation:true}
    state = State.resolve(misleading, entry(true), context())
    verify(state.widget && state.canPlace && !state.exclusive && !state.canActivateBar)
  }
  function test_open_does_not_override_unknown_pending_recovery_or_selected_review() {
    var local = entry(true)
    local.kinds = ["panel"]
    verify(!State.resolve(row(), local, context({inventoryReady:false})).canOpen)
    verify(!State.resolve(row(), local, context({batchRunning:true})).canOpen)
    verify(!State.resolve(row(), local, context({mutationBusy:true})).canOpen)
    var pending = State.resolve(row(), local, context({operation:{pending:true,status:"checking"}}))
    verify(!pending.canOpen)
    compare(pending.state, "checking")
    var failed = State.resolve(row(), local, context({operation:{error:"Native failure",lastAction:"enable-plugin"}}))
    verify(!failed.canOpen)
    compare(failed.action, "retry")
    compare(failed.message, "Native failure")
    var owned = State.resolve(row(), local, context({batchFailure:true}))
    verify(!owned.canOpen)
    compare(owned.action, "progress")
    compare(State.resolve(row(), null, context({selected:true})).action, "review")
    local.id = "example.other"
    verify(!State.resolve(row(), local, context()).canOpen)
  }
}
