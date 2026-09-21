import QtQuick
import QtTest
import "../../ui/BrowseState.js" as BrowseState

TestCase {
  name: "BrowseState"

  function test_partial_payload_preserves_latest_browse_choices() {
    for (var i = 0; i < 2; i++) {
      var sort = i ? "likes" : "added"
      var result = BrowseState.restore({}, { setupSort: sort, setupGroup: "messaging",
        setupGrouping: "category", setupPage: 3 })
      compare(result.sort, sort)
      compare(result.group, "messaging")
      compare(result.grouping, "category")
      compare(result.page, 3)
    }
  }
  function test_search_restore_preserves_legacy_explicit_sort_and_browse_sort() {
    var current = {setupQuery:"", setupSort:"likes", browseSort:"likes"}
    var automatic = BrowseState.restore({setupQuery:"midi"}, current)
    compare(automatic.sort, "relevance")
    compare(automatic.browseSort, "likes")
    var legacy = BrowseState.restore({setupQuery:"midi", setupSort:"name"}, current)
    compare(legacy.sort, "name")
    compare(legacy.browseSort, "likes")
    var resume = BrowseState.restore({setupQuery:"midi", setupSort:"relevance", browseSort:"activity"}, {})
    compare(resume.sort, "relevance")
    compare(resume.browseSort, "activity")
    compare(BrowseState.restore({setupQuery:"", setupSort:"relevance", browseSort:"activity"}, {}).sort, "activity")
    compare(BrowseState.restore({}, {setupQuery:"midi", setupSort:"copies", browseSort:"likes"}).sort, "copies")
  }
  function test_explicit_empty_filter_and_page_reset_win() {
    var result = BrowseState.restore({setupGroup: "", setupGrouping: "none", setupPage: 1},
      {setupGroup: "messaging", setupGrouping: "category", setupPage: 3})
    compare(result.group, "")
    compare(result.grouping, "none")
    compare(result.page, 1)
  }
  function test_legacy_grouping_and_invalid_sort_have_safe_defaults() {
    var result = BrowseState.restore({setupGrouping: "purpose", setupSort: "invalid"}, {})
    compare(result.grouping, "none")
    compare(result.sort, "likes")
  }
  function test_watchlist_save_preserves_touched_settings_draft() {
    verify(!BrowseState.shouldSyncSettings(true, true, "save-preferences", "services"))
    verify(!BrowseState.shouldSyncSettings(true, true, "quick-setup", ""))
    verify(!BrowseState.shouldSyncSettings(true, true, "save-density", ""))
    verify(BrowseState.shouldSyncSettings(true, true, "save-preferences", "settings"))
    verify(BrowseState.shouldSyncSettings(true, false, "save-preferences", "services"))
    verify(BrowseState.shouldSyncSettings(false, true, "load", ""))
  }
  function test_discover_and_marketplace_options_restore_explicitly() {
    var result = BrowseState.restore({workspaceView:"browse", setupSort:"copies", setupVerification:"verified"}, {})
    compare(result.workspaceView, "browse")
    compare(result.sort, "copies")
    compare(result.verification, "verified")
    var defaults = BrowseState.restore({}, {})
    compare(defaults.workspaceView, "browse")
    compare(defaults.verification, "all")
  }
  function test_explicit_discover_and_last_view_override_browse_default() {
    compare(BrowseState.restore({workspaceView:"discover"}, {discoveryEnabled:true}).workspaceView, "discover")
    compare(BrowseState.restore({}, {workspaceView:"discover",discoveryEnabled:true}).workspaceView, "discover")
    compare(BrowseState.restore({workspaceView:"browse"}, {workspaceView:"discover"}).workspaceView, "browse")
    compare(BrowseState.restore({workspaceView:"invalid"}, {}).workspaceView, "browse")
  }
  function test_disabled_launch_coerces_old_routes_and_ignores_payload_flag() {
    compare(BrowseState.restore({workspaceView:"discover",discoveryEnabled:true}, {}).workspaceView, "browse")
    compare(BrowseState.restore({}, {workspaceView:"discover",discoveryEnabled:false}).workspaceView, "browse")
  }
}
