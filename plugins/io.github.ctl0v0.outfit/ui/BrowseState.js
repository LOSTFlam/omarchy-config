.pragma library

function sortName(value) {
  return ["relevance", "recommended", "stars", "fit", "name", "added", "likes", "activity", "views", "copies"].indexOf(String(value)) >= 0 ? String(value) : "likes"
}

function normalSort(value) {
  return sortName(value) === "relevance" ? "likes" : sortName(value)
}

// Search sort is session state, independent of persisted preferences.
function searchState(query, sort, current, explicit) {
  query = String(query || "").trim().slice(0, 160)
  var wasSearching = Boolean(String(current.setupQuery || "").trim())
  var browseSort = normalSort(wasSearching ? current.browseSort : current.setupSort)
  var selected = sortName(sort === undefined ? current.setupSort : sort)
  if (!query) selected = wasSearching || selected === "relevance" ? browseSort : selected
  else if (!wasSearching && !explicit) selected = "relevance"
  return {query:query, sort:selected, browseSort:query ? browseSort : selected}
}

function restore(payload, current) {
  var search = searchState("setupQuery" in payload ? payload.setupQuery : current.setupQuery,
    "setupSort" in payload ? payload.setupSort : current.setupSort, current, "setupSort" in payload)
  if ("browseSort" in payload) search.browseSort = normalSort(payload.browseSort)
  if (!search.query && (current.setupQuery || payload.setupSort === "relevance")) search.sort = search.browseSort
  var grouping = String("setupGrouping" in payload ? payload.setupGrouping : current.setupGrouping)
  return {
    group: String("setupGroup" in payload ? (payload.setupGroup || "") : (current.setupGroup || "")).slice(0, 40),
    query: search.query,
    sort: search.sort,
    browseSort: search.browseSort,
    grouping: grouping === "category" ? "category" : "none",
    page: Math.max(1, Number("setupPage" in payload ? payload.setupPage : current.setupPage) || 1),
    workspaceView: current.discoveryEnabled === true && ("workspaceView" in payload ? payload.workspaceView : current.workspaceView) === "discover" ? "discover" : "browse",
    verification: verificationFilter("setupVerification" in payload ? payload.setupVerification : current.setupVerification)
  }
}

function searchResponse(value, query, total) {
  var active = Boolean(query) && value && value.active === true
  var suggestion = active && total === 0 && value.suggestion
  var suggestedQuery = suggestion ? String(suggestion.query || "").trim().slice(0, 160) : ""
  return {active:Boolean(active), mode:active && ["complete", "partial"].indexOf(value.mode) >= 0 ? value.mode : "none",
    suggestion:suggestedQuery ? {query:suggestedQuery, label:String(suggestion.label || suggestedQuery).slice(0, 160)} : null}
}

function verificationFilter(value) {
  return ["verified", "unverified"].indexOf(String(value || "")) >= 0 ? String(value) : "all"
}

function shouldSyncSettings(opened, touched, action, scope) {
  return !opened || !touched || (action === "save-preferences" && scope !== "services")
}
