import QtQuick
import Quickshell
import Quickshell.Io
import "ui/MediaPaths.js" as MediaPaths
import "ui/Presentation.js" as Presentation
import "ui/InspectorState.js" as InspectorState
import "ui/BrowseState.js" as BrowseState

Item {
  id: root

  visible: false
  width: 0
  height: 0

  property var shell: null
  property var manifest: null

  readonly property string demoRootEnv: String(Quickshell.env("OUTFIT_DEMO_ROOT") || Quickshell.env("OMAFIT_DEMO_ROOT") || "")
  readonly property string demoRoot: demoRootEnv.charAt(0) === "/" ? demoRootEnv : ""
  readonly property string helperPath: decodeURIComponent(
    Qt.resolvedUrl(demoRoot ? "demo/fixture_worker.py" : "scripts/outfit.py").toString().replace(/^file:\/\//, ""))
  readonly property string configRoot: (demoRoot ? demoRoot + "/config" : MediaPaths.xdg(Quickshell.env("XDG_CONFIG_HOME"), Quickshell.env("HOME"), ".config")) + "/io.github.ctl0v0.outfit"
  readonly property string cacheRoot: (demoRoot ? demoRoot + "/cache" : MediaPaths.xdg(Quickshell.env("XDG_CACHE_HOME"), Quickshell.env("HOME"), ".cache")) + "/io.github.ctl0v0.outfit"
  readonly property string batchJournalPath: configRoot + "/quick-setup.json"
  property bool sleeping: false
  property bool presentationPaused: false
  property int sleepDelay: 30000
  property real closedAt: 0
  property bool queryStopping: false
  property bool wakeRequested: false
  property bool startupResumeNeeded: false
  property int queryOutputSize: 0
  property int queryOutputLines: 0
  property string thumbnailDemandKey: ""
  readonly property bool sleepBlocked: root.mutationBusy || root.hasCheckingOperations()
    || root.pluginOpenBusy || Boolean(root.editorRestorePayload) || root.hostLeaseCleanup.length > 0
    || hostLifecycleWorker.active || root.hostLeaseToken !== "" || root.hostPollDeadline > 0
    || (root.requestActive && !root.presentationAction(root.activeAction))
    || (root.densitySavePending && !root.densitySaveError)
  function presentationAction(action) {
    return ["load", "search", "quick-setup", "readme-plugin", "context", "preview-interest", "matches", "discover"].indexOf(action) >= 0
  }
  function scheduleSleep() {
    if (root.editorOpen || root.sleeping || root.sleepBlocked) { idleSleep.stop(); return }
    idleSleep.interval = Math.max(1, root.closedAt + root.sleepDelay - Date.now())
    idleSleep.restart()
  }
  function stopQueryForIdle() {
    if (root.requestActive && !root.presentationAction(root.activeAction)) return false
    deadline.stop()
    queryLaunchDeadline.stop()
    queryEofGrace.stop()
    root.queryStopping = worker.running || worker.processId > 0 || root.queryLaunching
    root.queryLaunching = false
    root.requestActive = false
    root.activeAction = ""
    root.activeRequest = ({})
    root.response = null
    root.streamFinished = false
    root.generation++
    worker.running = false
    if (root.queryStopping) hardStop.restart()
    return true
  }
  function enterSleep() {
    if (root.editorOpen || root.sleepBlocked) return false
    root.presentationPaused = true
    root.sleeping = true
    root.pendingSearch = null
    root.pendingSetup = null
    root.pendingReadmeId = ""
    root.pendingDiscovery = null
    root.pendingAnalyze = false
    root.stopQueryForIdle()
    thumbnailLoader.clear()
    root.thumbnailRows = []
    root.thumbnailDemandKey = ""
    root.rows = []
    root.setupRows = []
    root.setupSections = []
    root.discoveryRows = []
    root.discoveryHistory = []
    root.matches = {rows:[],total:0,unread:0,page:1,pageCount:1,partial:false}
    root.matchesLoaded = false
    root.readmeContent = ""
    root.readmeBlocks = []
    root.readmeMedia = []
    root.readmeMediaIndexed = false
    root.readmePluginId = ""
    root.readmeIdentity = ""
    root.diagnostics = ({})
    root.cacheLoaded = false
    root.inventoryReady = false
    root.hasAnalyzed = false
    root.startupStarted = false
    root.startupResumeNeeded = false
    root.searchPreparationAttempted = false
    root.searchPreparationSettled = false
    root.response = null
    root.mutationResponse = null
    root.persistBatchJournal()
    return true
  }
  function resumeQueries() {
    if (root.queryStopping || !root.editorOpen) return
    if (!root.cacheLoaded) {
      root.wakeRequested = false
      root.request("load", {})
    } else if (!root.requestActive) {
      root.wakeRequested = false
      if (root.pendingSetup) {
        var pending = root.pendingSetup
        root.pendingSetup = null
        root.request("quick-setup", pending)
      } else if (root.pendingSearch) {
        var search = root.pendingSearch
        root.pendingSearch = null
        root.search(search.query,search.category,search.installFilter,search.partyFilter)
      } else if (root.pendingReadmeId) {
        root.startReadme(root.pendingReadmeId)
      } else root.queueBoardRefresh()
      root.startStartup()
    }
  }
  onSleepBlockedChanged: root.scheduleSleep()
  Timer { id: idleSleep; objectName: "idleSleep"; interval: root.sleepDelay; onTriggered: root.enterSleep() }

  property var rows: []
  property var profile: []
  // Keep probe provenance independently of the legacy scoring profile.
  property var scan: ({state:"unavailable", checkedAt:0, probes:[], observations:[]})
  property string scanError: ""
  property var installed: []
  property var inventory: []
  property var updates: []
  property bool updatesLoaded: false
  property real updatesCheckedAt: 0
  property real nextUpdatesCheckAt: 0
  property string updatesError: ""
  readonly property bool updatesBusy: updatesWorker.active
  readonly property int updatesUnavailableCount: updates.filter(function(row) {
    return row.state === "unavailable" || Boolean(row.checkError)
  }).length
  readonly property int availableUpdateCount: updates.filter(function(row) {
    return row.state === "available" && (row.canUpdate === true || row.selfUpdate === true)
  }).length
  property var selfUpdateState: ({state:"idle", message:""})
  readonly property bool selfUpdatePending: ["queued", "validating", "checking", "updating", "verified", "restarting", "reopening", "unconfirmed"].indexOf(String(selfUpdateState.state)) >= 0
  readonly property bool selfUpdateBusy: selfUpdatePending || (selfUpdateWorker.active && selfUpdateWorker.activeRequest.action === "self-update")
  property real selfUpdatePollDeadline: 0
  property bool selfUpdateStatusLoaded: false

  function updateInfo(identity) {
    for (var row of root.updates) if (row.id === String(identity)) return row
    return null
  }
  function checkUpdates(force) {
    if (!root.inventoryReady || root.mutationBusy || root.hasCheckingOperations() || root.updatesBusy) return false
    if (force !== true && Date.now() < root.nextUpdatesCheckAt) return false
    return updatesWorker.submit("check-updates", {force:force === true,
      inventoryRevision:root.inventoryRevision, mutationGeneration:root.mutationGeneration})
  }
  function finishUpdates(result, request) {
    if (result && result.cancelled) return
    if (request.inventoryRevision !== root.inventoryRevision
        || request.mutationGeneration !== root.mutationGeneration || root.mutationBusy) {
      root.nextUpdatesCheckAt = 0
      return
    }
    if (!result || result.ok !== true || result.inventoryAuthoritative !== true || !Array.isArray(result.updates)) {
      root.updatesError = String(result && (result.updatesError || result.error) || "Could not check plugin updates.").slice(0, 300)
      root.nextUpdatesCheckAt = Date.now() + 300000
      return
    }
    root.updates = result.updates.slice(0, 2000)
    root.updatesLoaded = true
    root.updatesCheckedAt = Number(result.updatesCheckedAt) || 0
    root.updatesError = String(result.updatesError || "").slice(0, 300)
    // Merge only version facts from this generation; do not publish an older
    // inventory over a management operation or a newer scan.
    if (Array.isArray(result.inventory)) root.inventory = result.inventory
    var oldest = root.updates.reduce(function(value, row) {
      return Math.min(value, Number(row.checkedAt) || value)
    }, Date.now() / 1000)
    root.nextUpdatesCheckAt = root.updatesError || root.updatesUnavailableCount > 0 ? Date.now() + 300000
      : Math.max(Date.now() + 60000, oldest * 1000 + 21600000)
  }
  function invalidateUpdate(identity) {
    root.updates = root.updates.map(function(row) {
      if (row.id !== identity) return row
      return Object.assign({}, row, {state:"unavailable", canUpdate:false,
        reason:"Plugin state changed. Check for updates again."})
    })
    root.nextUpdatesCheckAt = 0
  }
  function updatePlugin(row, resumeState) {
    if (!row || root.mutationBusy || root.updatesBusy || root.hasCheckingOperations()
        || !root.inventoryReady || !InspectorState.eligibleUpdate(row)
        || !InspectorState.sameUpdate(row, root.updateInfo(row.id))) return false
    return root.startPluginAction("update-plugin", row.id, resumeState, "", false, false, "", row)
  }
  function startUpdateBatch(ids, resumeState) {
    if (root.mutationBusy || root.updatesBusy || root.hasCheckingOperations() || !root.inventoryReady) return false
    var wanted = Array.isArray(ids) ? ids : []
    var selected = root.updates.filter(function(row) {
      return InspectorState.eligibleUpdate(row) && (!wanted.length || wanted.indexOf(row.id) >= 0)
    })
    if (!selected.length || selected.length > 2000 || (wanted.length && selected.length !== wanted.length)) return false
    root.batchKind = "update"
    root.batchItems = selected.map(function(row) {
      return {id:row.id, name:row.name, kind:"update", expectedRevision:row.availableRevision,
        expectedInstalledRevision:row.installedRevision, installedVersion:row.installedVersion,
        availableVersion:row.availableVersion, status:"queued", message:"Waiting", attempts:0}
    })
    root.batchCurrentIndex = -1
    root.batchStopRequested = false
    root.batchRecovered = false
    root.batchCloseSuppressed = false
    root.editorRestoreSuppressed = false
    root.batchResumePayload = root.safeEditorPayload(resumeState, "")
    root.beginBatchLifecycle(selected.map(function(item) { return String(item.id) }))
    root.batchRunning = true
    root.prepareEditorRestore(root.batchResumePayload, "")
    root.scheduleBatchAdvance(600)
    return true
  }
  function beginSelfUpdate(row, resumeState) {
    if (!row || row.selfUpdate !== true || row.state !== "available" || root.interestsDirty
        || (resumeState && resumeState.settingsTouched) || root.mutationBusy || root.updatesBusy
        || root.hasCheckingOperations() || !root.inventoryReady || selfUpdateWorker.active
        || !InspectorState.sameUpdate(row, root.updateInfo(row.id))) return false
    var started = selfUpdateWorker.submit("self-update", {expectedRevision:row.availableRevision,
      expectedInstalledRevision:row.installedRevision, resumePayload:root.safeEditorPayload(resumeState, "")})
    if (started) {
      root.selfUpdateState = {state:"validating", message:"Preparing Outfit update. The shell will restart and Outfit will reopen."}
      root.selfUpdatePollDeadline = Date.now() + 310000
    }
    return started
  }
  function finishSelfUpdate(result, request) {
    root.selfUpdateStatusLoaded = true
    if (result && result.responseKind === "self-update" && result.state) {
      root.selfUpdateState = result.state === "idle" ? {state:"idle", message:""} : result
      if (root.selfUpdatePending && !root.selfUpdatePollDeadline) root.selfUpdatePollDeadline = Date.now() + 310000
    } else if (request.action === "self-update") {
      root.selfUpdateState = {state:"unconfirmed", message:"Self-update launch was not confirmed. Checking its independent worker…"}
    }
  }
  BackgroundWorker {
    id: updatesWorker
    objectName: "updatesJobs"
    helperPath: root.helperPath
    lowPriority: true
    onFinished: function(result, request) { root.finishUpdates(result, request) }
  }
  BackgroundWorker {
    id: selfUpdateWorker
    objectName: "selfUpdateJobs"
    helperPath: root.helperPath
    onFinished: function(result, request) { root.finishSelfUpdate(result, request) }
  }
  Timer {
    interval: Math.max(3000,Math.min(21600000,root.nextUpdatesCheckAt - Date.now()))
    repeat: true
    running: root.editorOpen && root.cacheLoaded && root.inventoryReady && !root.updatesBusy && !root.mutationBusy
    onTriggered: {
      if (!root.selfUpdateStatusLoaded && !selfUpdateWorker.active)
        selfUpdateWorker.submit("self-update-status", {})
      root.checkUpdates(false)
    }
  }
  Timer {
    interval: 1500
    repeat: true
    running: root.selfUpdatePending
    onTriggered: {
      if (root.selfUpdatePollDeadline > 0 && Date.now() > root.selfUpdatePollDeadline) {
        root.selfUpdateState = {state:"expired", message:"Self-update could not be confirmed. Check the installed version before retrying."}
      } else if (!selfUpdateWorker.active) selfUpdateWorker.submit("self-update-status", {})
    }
  }
  property var unavailable: []
  property var categories: []
  property var preferences: ({
    schema: 1,
    goals: [],
    software: [],
    services: [],
    servicesOnboardingComplete: false,
    notes: "",
    watchHardware: true,
    readmeEnrichment: true,
    notFit: []
  })
  property var changes: ({ added: [], removed: [] })
  property var filterCounts: ({ all: 0, installed: 0, available: 0, firstParty: 0, thirdParty: 0 })
  property int catalogCount: 0
  property real fetchedAt: 0
  property string generatedAt: ""
  property int readmesFetched: 0
  property var readmeIndex: ({eligible:0, indexed:0, pending:0, unavailable:0, failed:0, due:0})
  property string readmeIndexError: ""
  property real nextIndexAt: 0
  property string indexedCatalogRevision: ""
  readonly property bool indexingBusy: readmeIndexer.active
  readonly property bool indexingEnabled: root.preferences.readmeEnrichment !== false
    && root.preferences.readmeIndexing !== false && !root.indexingPauseRequested
  property bool indexingPauseRequested: false
  onIndexingEnabledChanged: if (!root.indexingEnabled) {
    readmeIndexer.stop("README indexing disabled.", true)
    searchPreparationWorker.stop("Documentation preparation disabled.", true)
  }

  readonly property bool canBrowse: cacheLoaded && catalogCount > 0
  readonly property bool canManagePlugins: inventoryReady
  property string catalogSource: "none"
  property string catalogBuiltAt: ""
  property string sourceDate: ""
  property var searchPack: ({state:"unknown"})
  // Last seed failure is independent of the currently running local index batch.
  property bool searchPreparationFailed: false
  property real searchPreparationRetryAt: 0
  readonly property bool searchPackReceiptFailed: Boolean(searchPack.error)
    || ["failed", "error", "unavailable"].indexOf(String(searchPack.state)) >= 0
  readonly property bool searchPackFailed: searchPreparationFailed || searchPackReceiptFailed
  readonly property real searchPackRetryAt: {
    var receipt = Number(root.searchPack.nextCheckAt) * 1000
    return Math.max(root.searchPreparationRetryAt,
      root.searchPackReceiptFailed && isFinite(receipt) ? receipt : 0)
  }
  property bool startupStarted: false
  property bool startupQuiet: false
  property bool startupDismissed: false
  property bool searchPreparationAttempted: false
  property bool searchPreparationSettled: false
  property int searchPreparationBusyRetries: 0
  property var startupReceipt: null
  property real nextSearchPreparationAt: 0
  readonly property bool inventoryBusy: inventoryWorker.active
  readonly property bool catalogBusy: catalogWorker.active
  readonly property bool preparingSearch: searchPreparationWorker.active
  property var startupActivity: ({
    catalog:{state:"waiting"}, inventory:{state:"waiting"},
    hardware:{state:"waiting"}, documentation:{state:"waiting"}
  })
  readonly property var documentCounts: root.documentCoverage(root.readmeIndex.documents)
  function documentCoverage(raw) {
    if (!raw || typeof raw !== "object") return ({})
    var counts = ({})
    for (var key of ["total", "indexed", "processed", "pending", "unavailable", "failed", "skipped"]) {
      var value = Number(raw[key])
      counts[key] = isFinite(value) && value >= 0 ? Math.floor(value) : 0
    }
    // Seed-excluded documents still require local upstream checks. Older helper
    // summaries included them in processed/skipped while keeping them due.
    counts.processed = Math.min(counts.total, counts.processed,
      counts.indexed + counts.unavailable + counts.failed)
    counts.pending = Math.max(counts.pending, counts.total - counts.processed)
    return counts
  }
  readonly property bool libraryPrepared: Number(documentCounts.total) > 0
    && Number(documentCounts.pending) === 0 && Number(documentCounts.failed) === 0
    && Number(documentCounts.processed) >= Number(documentCounts.total)
  readonly property bool startupBannerVisible: cacheLoaded && !startupQuiet && !startupDismissed
  readonly property string startupSummary: !canBrowse ? (startupActivity.catalog.state === "error"
    ? "Catalog unavailable — open Details to retry." : "Preparing the plugin catalog…")
    : !inventoryReady ? (startupActivity.inventory.state === "error"
      ? "Browse now — plugin checks need attention." : "Browse now — checking installed plugins…")
    : preparingSearch ? "Browse now — preparing documentation search…"
    : preferences.readmeEnrichment === false ? "Browse now — documentation updates are disabled."
    : !indexingEnabled ? "Browse now — documentation updates are paused."
    : libraryPrepared ? "Library prepared — available documentation is searchable."
    : searchPackFailed ? (indexingBusy ? "Browse now — adding local documentation; search library unavailable."
      : "Browse now — search library unavailable. Local search is retained.")
    : startupActivity.documentation.state === "error" ? "Browse now — documentation will retry later."
    : indexingBusy ? "Browse now — adding searchable documentation…"
    : "Browse now — catalog search is ready."
  readonly property var startupProgress: preparingSearch ? startupActivity.documentation
    : indexingBusy ? startupActivity.documentation : ({})

  function setActivity(lane, values) {
    var state = JSON.parse(JSON.stringify(root.startupActivity))
    state[lane] = values
    root.startupActivity = state
  }
  function activityProgress(lane, event) {
    // Never expose helper messages, probe names or device addresses in progress.
    var phase = String(event.phase || "")
    var value = {state:"running", phase:["manifest", "download", "import", "commit", "catalog",
      "inventory", "scan", "index", "documentation"].indexOf(phase) >= 0 ? phase : "working"}
    for (var key of ["processed", "total", "bytesReceived", "bytesTotal"]) {
      var count = Number(event[key])
      if (event[key] !== undefined && isFinite(count) && count >= 0) value[key] = count
    }
    if (lane === "documentation" && phase === "index" && event.documents) {
      value.documents = root.documentCoverage(event.documents)
      value.processed = value.documents.processed
      value.total = value.documents.total
    }
    root.setActivity(lane, value)
  }
  function measuredProgress(value) {
    if (!value) return -1
    var total = Number(value.bytesTotal), done = Number(value.bytesReceived)
    if (!(total > 0 && isFinite(done))) { total = Number(value.total); done = Number(value.processed) }
    return total > 0 && isFinite(done) && done >= 0 ? Math.min(1, done / total) : -1
  }
  function startStartup() {
    if (!root.cacheLoaded || !root.editorOpen || root.mutationBusy) return false
    if (!root.startupStarted) {
      root.startupStarted = true
      root.startInventoryCheck()
      root.refreshCatalog(true)
      if (root.preferences.watchHardware !== false && !root.hasAnalyzed) root.analyze()
      else root.setActivity("hardware", {state:root.hasAnalyzed ? "complete" : "disabled"})
    } else if (root.startupResumeNeeded) {
      root.startupResumeNeeded = false
      if (!root.inventoryReady && !inventoryWorker.active) root.startInventoryCheck()
      if (root.startupActivity.catalog.state === "waiting" && !catalogWorker.active) root.refreshCatalog(true)
      if (root.startupActivity.hardware.state === "waiting" && !root.backgroundBusy
          && root.preferences.watchHardware !== false) root.analyze()
    }
    return true
  }
  function resumeStartupLater() {
    root.startupResumeNeeded = true
    if (root.editorOpen) Qt.callLater(root.startStartup)
  }
  function startInventoryCheck() {
    if (root.mutationBusy || inventoryWorker.active) return false
    var started = inventoryWorker.submit("verify-inventory", {inventoryRevision:root.inventoryRevision,
      mutationGeneration:root.mutationGeneration, streamProgress:true})
    if (started) root.setActivity("inventory", {state:"running"})
    return started
  }
  function finishStartupInventory(result, request) {
    if (result && result.cancelled) {
      root.setActivity("inventory", {state:root.inventoryReady ? "complete" : "waiting"})
      root.resumeStartupLater()
      return
    }
    if (root.mutationBusy || request.inventoryRevision !== root.inventoryRevision
        || request.mutationGeneration !== root.mutationGeneration) {
      root.setActivity("inventory", {state:root.inventoryReady ? "complete" : "waiting"})
      return
    }
    if (!result || result.ok !== true || result.inventoryAuthoritative !== true) {
      root.setActivity("inventory", {state:"error"})
      return
    }
    root.inventory = Array.isArray(result.inventory) ? result.inventory : []
    root.installed = Array.isArray(result.installed) ? result.installed : []
    root.unavailable = Array.isArray(result.unavailable) ? result.unavailable : []
    root.inventoryReady = true
    root.inventoryRevision++
    root.setActivity("inventory", {state:"complete"})
    root.reconcilePluginOperations()
    root.reconcileTerminalOutcomes()
    root.boardRefreshPending = true
    root.queueBoardRefresh()
    root.requestContext()
    root.maybeSaveStartupReceipt()
  }
  function refreshCatalog(automatic) {
    if (root.mutationBusy || catalogWorker.active || ["refresh", "enrich"].indexOf(root.backgroundAction) >= 0) return false
    var started = catalogWorker.submit("catalog-refresh", {automatic:automatic === true, streamProgress:true})
    if (started) root.setActivity("catalog", {state:"running"})
    return started
  }
  function finishCatalog(result, request) {
    if (result && result.cancelled) { root.setActivity("catalog", {state:"waiting"}); root.resumeStartupLater(); return }
    if (!result || result.ok !== true) { root.setActivity("catalog", {state:"error"}); return }
    if ("catalogCount" in result) root.catalogCount = Math.max(0, Number(result.catalogCount) || 0)
    if (Array.isArray(result.categories)) root.categories = result.categories
    if ("catalogSource" in result) root.catalogSource = String(result.catalogSource)
    if ("catalogBuiltAt" in result) root.catalogBuiltAt = String(result.catalogBuiltAt || "")
    if ("sourceDate" in result) root.sourceDate = String(result.sourceDate || "")
    if (result.searchPack) root.searchPack = result.searchPack
    if ("fetchedAt" in result) root.fetchedAt = Number(result.fetchedAt) || 0
    if ("generatedAt" in result) root.generatedAt = String(result.generatedAt || "")
    if ("likesFetchedAt" in result) root.likesFetchedAt = Number(result.likesFetchedAt) || 0
    if (result.readmeIndex) root.readmeIndex = result.readmeIndex
    root.setActivity("catalog", {state:result.error ? "error" : "complete"})
    root.catalogMatchesChanged()
    root.boardRefreshPending = true
    root.queueBoardRefresh()
    root.maybeSaveStartupReceipt()
  }
  function tryPrepareSearch() {
    if (!root.editorOpen || !root.canBrowse || !root.indexingEnabled || root.mutationBusy
        || root.preparingSearch || root.indexingBusy || root.searchPreparationSettled
        || root.searchPreparationAttempted || root.catalogBusy || Date.now() < root.nextSearchPreparationAt
        || ["refresh", "enrich"].indexOf(root.backgroundAction) >= 0) return false
    root.searchPreparationAttempted = true
    // A current receipt already tells us no seed check is due. Keep local
    // indexing independent of the pack's network retry/check deadline.
    var nextCheck = Number(root.searchPack.nextCheckAt) * 1000
    var completedReceipt = root.searchPack.state === "ready" || root.searchPackReceiptFailed
    if ((completedReceipt && root.searchPack.due === false && isFinite(nextCheck) && nextCheck > Date.now())
        || Date.now() < root.searchPackRetryAt) {
      root.searchPreparationSettled = true
      root.indexedCatalogRevision = root.generatedAt
      var deferredError = root.searchPackFailed
      root.nextIndexAt = Math.max(root.nextIndexAt, Date.now() + (deferredError ? 30000 : 3000))
      root.setActivity("documentation", {state:deferredError ? "error" : root.libraryPrepared ? "complete" : "waiting"})
      root.maybeSaveStartupReceipt()
      return true
    }
    var started = searchPreparationWorker.submit("prepare-search", {streamProgress:true, catalogEpoch:root.catalogEpoch})
    if (started) root.setActivity("documentation", {state:"running"})
    return started
  }
  function finishSearchPreparation(result, request) {
    if (result && result.cancelled) {
      root.searchPreparationAttempted = false
      root.searchPreparationSettled = false
      root.searchPreparationBusyRetries = 0
      root.nextSearchPreparationAt = 0
      root.setActivity("documentation", {state:root.indexingEnabled ? "waiting" : "paused"})
      return
    }
    if (result && result.searchPack && result.searchPack.busy === true) {
      if (++root.searchPreparationBusyRetries <= 3) {
        root.searchPreparationAttempted = false
        root.nextSearchPreparationAt = Date.now() + 3000
        root.setActivity("documentation", {state:"waiting"})
        return
      }
      result = {ok:false, error:"Documentation preparation is busy; local indexing will retry later."}
    }
    root.searchPreparationSettled = true
    if (result && result.searchPack) root.searchPack = result.searchPack
    if (result && result.ok === true && request.catalogEpoch === root.catalogEpoch) {
      if ("catalogCount" in result) root.catalogCount = Math.max(0, Number(result.catalogCount) || 0)
      if ("catalogSource" in result) root.catalogSource = String(result.catalogSource)
      if ("catalogBuiltAt" in result) root.catalogBuiltAt = String(result.catalogBuiltAt || "")
      if ("sourceDate" in result) root.sourceDate = String(result.sourceDate || "")
      if ("fetchedAt" in result) root.fetchedAt = Number(result.fetchedAt) || 0
      if ("generatedAt" in result) root.generatedAt = String(result.generatedAt || "")
    }
    if (result && result.readmeIndex) {
      root.readmeIndex = result.readmeIndex
      root.indexedCatalogRevision = root.generatedAt
    }
    var failed = !result || result.ok !== true || Boolean(result.error) || Boolean(root.searchPack.error)
      || ["failed", "error", "unavailable"].indexOf(String(root.searchPack.state)) >= 0
    root.searchPreparationFailed = failed
    var retryAt = Number(root.searchPack.nextCheckAt) * 1000
    root.searchPreparationRetryAt = failed ? Math.max(Date.now() + 300000, isFinite(retryAt) ? retryAt : 0) : 0
    root.nextIndexAt = Date.now() + (failed ? 30000 : 3000)
    root.setActivity("documentation", {state:failed ? "error" : root.libraryPrepared ? "complete" : "waiting"})
    root.catalogMatchesChanged()
    root.boardRefreshPending = true
    root.queueBoardRefresh()
    root.maybeSaveStartupReceipt()
  }
  function retryStartupLane(lane) {
    if (lane === "inventory") return root.startInventoryCheck()
    if (lane === "catalog") return root.refreshCatalog(false)
    if (lane === "hardware") return root.rescan(false)
    if (lane !== "documentation" || !root.indexingEnabled || root.preparingSearch
        || root.indexingBusy || Date.now() < root.searchPackRetryAt) return false
    root.searchPreparationSettled = false
    root.searchPreparationAttempted = false
    root.searchPreparationBusyRetries = 0
    root.nextSearchPreparationAt = 0
    root.nextIndexAt = 0
    return root.tryPrepareSearch()
  }
  function maybeSaveStartupReceipt() {
    if (!root.startupStarted || !root.inventoryReady || !root.canBrowse
        || (!root.libraryPrepared && root.indexingEnabled)) return
    if (root.startupReceipt && root.startupReceipt.catalogRevision === root.generatedAt) return
    root.startupReceipt = {schema:1, completedAt:Date.now(), catalogRevision:root.generatedAt}
    startupReceiptFile.setText(JSON.stringify(root.startupReceipt))
  }
  // Only a completion receipt, never hardware profiles or probe observations.
  // Kept separate from preferences so older helpers cannot discard it.
  FileView {
    id: startupReceiptFile
    objectName: "startupReceiptFile"
    path: root.configRoot + "/startup.json"
    atomicWrites: true
    watchChanges: false
    printErrors: false
    onLoaded: {
      try {
        var raw = text()
        if (raw.length > 4096) return
        var receipt = JSON.parse(raw)
        if (receipt.schema !== 1 || !(Number(receipt.completedAt) > 0)) return
        root.startupReceipt = {schema:1, completedAt:Number(receipt.completedAt),
          catalogRevision:String(receipt.catalogRevision || "").slice(0, 128)}
        root.startupQuiet = true
      } catch (error) { /* Missing or obsolete receipts do not block startup. */ }
    }
  }
  Timer {
    id: searchPreparationDelay
    objectName: "searchPreparationDelay"
    interval: Math.max(750,Math.min(300000,root.nextSearchPreparationAt - Date.now()))
    repeat: true
    running: root.editorOpen && root.startupStarted && root.indexingEnabled && !root.searchPreparationSettled
      && !root.preparingSearch && !root.catalogBusy && !root.mutationBusy
    onTriggered: root.tryPrepareSearch()
  }
  BackgroundWorker {
    id: inventoryWorker
    objectName: "inventoryJobs"
    helperPath: root.helperPath
    onProgress: function(event, request) { root.activityProgress("inventory", event) }
    onFinished: function(result, request) { root.finishStartupInventory(result, request) }
  }
  BackgroundWorker {
    id: catalogWorker
    objectName: "catalogJobs"
    helperPath: root.helperPath
    onProgress: function(event, request) { root.activityProgress("catalog", event) }
    onFinished: function(result, request) { root.finishCatalog(result, request) }
  }
  BackgroundWorker {
    id: searchPreparationWorker
    objectName: "searchPreparationJobs"
    helperPath: root.helperPath
    lowPriority: true
    onProgress: function(event, request) { root.activityProgress("documentation", event) }
    onFinished: function(result, request) { root.finishSearchPreparation(result, request) }
  }

  BackgroundWorker {
    id: readmeIndexer
    objectName: "readmeIndexJobs"
    helperPath: root.helperPath
    lowPriority: true
    onProgress: function(event, request) { root.activityProgress("documentation", event) }
    onFinished: function(result, request) { root.finishIndexing(result, request) }
  }
  Timer {
    id: indexingDelay
    objectName: "indexingDelay"
    interval: Math.max(3000,Math.min(21600000,root.nextIndexAt - Date.now()))
    repeat: true
    running: root.editorOpen && root.indexingEnabled && root.searchPreparationSettled
      && !root.indexingBusy && !root.preparingSearch && !root.mutationBusy && !root.backgroundBusy
      && (root.indexedCatalogRevision !== root.generatedAt || !root.readmeIndex.eligible
        || root.readmeIndex.due > 0 || root.readmeIndex.pending > 0 || root.readmeIndex.failed > 0)
    onTriggered: root.tryIndexReadmes()
  }
  function tryIndexReadmes() {
    if (!root.editorOpen || !root.indexingEnabled || !root.cacheLoaded
         || root.preparingSearch || !root.searchPreparationSettled
         || root.backgroundBusy || root.requestActive || root.mutationBusy
        || root.indexingBusy || Date.now() < root.nextIndexAt || !root.catalogCount) return false
    if (root.indexedCatalogRevision === root.generatedAt && root.readmeIndex.eligible > 0
        && root.readmeIndex.due === 0 && !root.readmeIndex.pending
        && !root.readmeIndex.failed) return false
    if (Number(root.readmeIndex.retryAt || 0) * 1000 > Date.now()) return false
    var started = readmeIndexer.submit("index-readmes", {automatic:true, streamProgress:true})
    if (started) root.setActivity("documentation", {state:"running"})
    return started
  }
  function finishIndexing(result, request) {
    if (!result || result.cancelled === true) {
      root.setActivity("documentation", {state:root.indexingEnabled ? "waiting" : "paused"})
      return
    }
    if (result.ok !== true) {
      root.readmeIndexError = String(result.error || "README indexing failed. Retry when ready.")
      root.nextIndexAt = Date.now() + 300000
      root.setActivity("documentation", {state:"error"})
      return
    }
    root.readmeIndex = result.readmeIndex || root.readmeIndex
    root.indexedCatalogRevision = root.generatedAt
    root.readmeIndexError = String(result.error || root.readmeIndex.error || "")
    root.nextIndexAt = Math.max(Number(root.readmeIndex.retryAt || 0) * 1000,
      Date.now() + (root.readmeIndexError ? 300000 : root.readmeIndex.due > 0 ? 3000 : 60000))
    root.catalogMatchesChanged()
    root.setActivity("documentation", {state:root.readmeIndexError ? "error" : root.libraryPrepared ? "complete" : "waiting"})
    root.maybeSaveStartupReceipt()
    if (root.editorOpen && root.setupQuery && !root.queryBusy && !root.mutationBusy)
      root.quickSetup(root.setupQuery, root.setupGroup, root.setupSort, root.setupPage)
  }
  function setIndexingPaused(paused) {
    var value = JSON.parse(JSON.stringify(root.preferences))
    value.readmeIndexing = !paused
    if (!root.savePreferences(value, "indexing")) return false
    root.indexingPauseRequested = paused
    if (paused) {
      readmeIndexer.stop("README indexing paused.", true)
      searchPreparationWorker.stop("Documentation preparation paused.", true)
    }
    root.nextIndexAt = 0
    root.readmeIndexError = ""
    return true
  }
  onMutationBusyChanged: if (root.mutationBusy) {
    updatesWorker.stop("Update check yielded to plugin changes.", true)
    readmeIndexer.stop("README indexing yielded to plugin changes.", true)
    searchPreparationWorker.stop("Documentation preparation yielded to plugin changes.", true)
    inventoryWorker.stop("Inventory check yielded to plugin changes.", true)
  } else if (root.editorOpen && root.startupResumeNeeded) Qt.callLater(root.startStartup)
  onBackgroundBusyChanged: if (root.backgroundBusy) readmeIndexer.stop("README indexing yielded to maintenance.", true)
  onGeneratedAtChanged: { root.nextIndexAt = 0; root.catalogMatchesChanged() }
  property string readmePluginId: ""
  property string readmeIdentity: ""
  property string requestedReadmeIdentity: ""
  property string readmeContent: ""
  property var readmeBlocks: []
  property var readmeMedia: []
  property var thumbnailRows: []
  readonly property var thumbnails: thumbnailLoader.images
  property bool readmeMediaIndexed: false
  function setThumbnailRows(rows) {
    var next = Array.isArray(rows) && !root.sleeping ? rows.slice(0,72) : []
    var key = JSON.stringify(next.map(function(row) { return [row.id, row.previewThumbnail || row.previewImage || "", row.repo || "", row.listingCommit || ""] }))
    if (key === root.thumbnailDemandKey) return
    root.thumbnailDemandKey = key
    root.thumbnailRows = next
  }
  function invalidateThumbnail(identity, source) { return thumbnailLoader.invalidateImage(identity, source) }

  ThumbnailLoader {
    id: thumbnailLoader
    helperPath: root.helperPath
    readmeFallbackEnabled: root.preferences.readmeEnrichment !== false
    revision: root.generatedAt
    rows: root.thumbnailRows
    enabled: root.editorOpen && root.preferences.marketplaceThumbnails !== false
  }
  property string error: ""
  property string notice: ""
  property string updateStatus: ""
  property string dataWarning: ""
  property string backgroundError: ""
  Timer {
    id: updateStatusExpiry
    objectName: "updateStatusExpiry"
    interval: 3000
    onTriggered: root.updateStatus = ""
  }
  property string setupRefreshNotice: ""
  property string setupRefreshError: ""
  property bool hasAnalyzed: false
  property bool cacheLoaded: false
  property bool inventoryReady: false
  property var diagnostics: ({})
  readonly property bool previewBusy: thumbnailLoader.active
  // Launch gate, deliberately not persisted or read from summon payloads.
  // Future-feature tests may inject true when constructing the service.
  property bool discoveryEnabled: false
  property string workspaceView: "browse"
  onWorkspaceViewChanged: if (!root.discoveryEnabled && root.workspaceView !== "browse") root.workspaceView = "browse"
  onDiscoveryEnabledChanged: {
    if (root.discoveryEnabled) return
    root.workspaceView = "browse"
    root.discoverySerial++
    root.matchesSerial++
    root.pendingDiscovery = null
    root.pendingMatches = false
    root.pendingMatchReview = null
  }
  property string discoverTab: "ideas"
  property var inputs: ({revision:0, criteria:[], ignoredSignals:[], detected:[], probes:[],
    featureChoices:[], serviceChoices:[], scanState:"unavailable", checkedAt:0})
  property bool inputsLoaded: false
  property var criteriaRevision: 0
  property var interestsDraft: null
  property int interestsDraftSerial: 0
  property bool interestsDirty: false
  property var interestEditor: null
  property string interestsSection: "detected"
  // Explicit edit intent, separate from keystrokes and asynchronous context data.
  property int interestEditSerial: 0
  property var interestsReturnPayload: null
  property string interestsError: ""
  property string interestsNotice: ""
  property var interestPreview: null
  property string interestPreviewError: ""
  property int interestPreviewSerial: 0
  property var pendingInterestPreview: null
  property bool pendingContext: false
  property bool pendingMatches: false
  property var pendingMatchReview: null
  property int matchesSerial: 0
  property int catalogEpoch: 0
  property var matches: ({rows:[], total:0, unread:0, page:1, pageCount:1, partial:false, lastCheckedAt:0})
  property bool matchesLoaded: false
  property int matchesPage: 1
  property bool matchesUnreadOnly: true
  property string matchesError: ""
  property var reviewedMatchIds: ({})
  readonly property int unreadMatches: discoveryEnabled ? Math.max(0, Number(matches.unread) || 0) : 0
  readonly property bool interestsBusy: pendingContext || (requestActive
    && ["context", "save-interests"].indexOf(activeAction) >= 0)
  readonly property bool interestPreviewBusy: pendingInterestPreview !== null
    || (requestActive && activeAction === "preview-interest")
  readonly property bool matchesBusy: pendingMatches || pendingMatchReview !== null
    || (requestActive && ["matches", "review-matches"].indexOf(activeAction) >= 0)

  function contextPayload() {
    return {profile:root.profile, scan:root.scan, unavailable:root.unavailable,
      hasAnalyzed:root.hasAnalyzed, inventory:root.inventory,
      criteriaRevision:root.criteriaRevision, catalogEpoch:root.catalogEpoch}
  }
  function requestContext() {
    root.pendingContext = true
    interestsDelay.restart()
  }
  function scheduleMatches(invalidate) {
    if (!root.discoveryEnabled) return false
    if (invalidate !== false) root.matchesSerial++
    root.pendingMatches = true
    if (root.editorOpen) interestsDelay.restart()
  }
  function catalogMatchesChanged() {
    root.catalogEpoch++
    root.scheduleMatches(true)
  }
  function chooseMatches(unreadOnly, page) {
    if (!root.discoveryEnabled) return false
    root.matchesUnreadOnly = unreadOnly === true
    root.matchesPage = Math.max(1, Number(page) || 1)
    root.scheduleMatches(true)
  }
  function reviewMatches(ids, all) {
    if (!root.discoveryEnabled) return false
    if (root.pendingMatchReview || (root.requestActive && root.activeAction === "review-matches")) return false
    var values = Array.isArray(ids) ? ids.filter(function(id) {
      return typeof id === "string" && /^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/.test(id)
    }).slice(0, 100) : []
    if (all !== true && !values.length) return false
    root.pendingMatchReview = all === true ? {all:true} : {pluginIds:values}
    root.matchesSerial++
    interestsDelay.restart()
    return true
  }
  function matchUnread(row) {
    if (!root.discoveryEnabled) return false
    if (!row || !row.matchedInterests) return false
    var rows = root.matches.rows || []
    for (var i = 0; i < rows.length; i++) if (rows[i].id === row.id) return rows[i].unread === true
    return root.unreadMatches > 0 && row.unread === true && root.reviewedMatchIds[row.id] !== true
  }
  function flushInterestsRequests() {
    if (!root.discoveryEnabled) {
      root.pendingMatches = false
      root.pendingMatchReview = null
    }
    if (!root.editorOpen || !root.cacheLoaded) return false
    if (root.queryBusy || root.mutationBusy) { interestsDelay.restart(); return false }
    var payload = root.contextPayload()
    if (root.pendingContext || !root.inputsLoaded) {
      root.pendingContext = false
      return root.request("context", payload)
    }
    if (root.pendingMatchReview || root.pendingMatches) {
      payload.page = root.matchesPage
      payload.unreadOnly = root.matchesUnreadOnly
      payload.matchesSerial = root.matchesSerial
      if (root.pendingMatchReview) {
        for (var key in root.pendingMatchReview) payload[key] = root.pendingMatchReview[key]
        root.pendingMatchReview = null
        root.pendingMatches = false
        return root.request("review-matches", payload)
      }
      root.pendingMatches = false
      return root.request("matches", payload)
    }
    if (root.pendingInterestPreview) {
      payload.criterion = root.pendingInterestPreview.criterion
      payload.previewSerial = root.pendingInterestPreview.serial
      root.pendingInterestPreview = null
      return root.request("preview-interest", payload)
    }
    return false
  }
  Timer {
    id: interestsDelay
    objectName: "interestsDelay"
    interval: 180
    onTriggered: root.flushInterestsRequests()
  }
  function beginInterests() {
    if (!root.interestsDraft && root.inputsLoaded) root.resetInterestsDraft()
    root.requestContext()
  }
  function resetInterestsDraft() {
    if (!root.inputsLoaded || root.activeAction === "save-interests") return false
    root.interestsDraft = JSON.parse(JSON.stringify({revision:root.inputs.revision,
      criteria:root.inputs.criteria || [], ignoredSignals:root.inputs.ignoredSignals || []}))
    root.interestsDirty = false
    root.interestsDraftSerial++
    root.interestEditor = null
    root.interestsError = ""
    root.interestsNotice = ""
    root.clearInterestPreview()
    return true
  }
  function changeInterests(criteria, ignoredSignals) {
    if (!root.interestsDraft || root.activeAction === "save-interests") return false
    root.interestsDraft = {revision:root.interestsDraft.revision,
      criteria:JSON.parse(JSON.stringify(criteria)), ignoredSignals:ignoredSignals.slice()}
    root.interestsDirty = true
    root.interestsDraftSerial++
    root.interestsNotice = ""
    return true
  }
  function useDetected(id, enabled) {
    if (!root.interestsDraft) return false
    var ignored = root.interestsDraft.ignoredSignals.filter(function(value) { return value !== id })
    if (!enabled) ignored.push(id)
    return root.changeInterests(root.interestsDraft.criteria, ignored)
  }
  function detectedEnabled(id) {
    var ignored = root.interestsDraft ? root.interestsDraft.ignoredSignals : root.inputs.ignoredSignals || []
    return ignored.indexOf(id) < 0
  }
  function editInterest(index, criterion) {
    if (!root.interestsDraft || root.activeAction === "save-interests") return false
    root.interestEditor = {index:index, criterion:JSON.parse(JSON.stringify(criterion
      || {id:"", kind:"topic", label:"", terms:[], enabled:true, origin:"user"})),
      termText:criterion && Array.isArray(criterion.terms) ? criterion.terms.join(", ") : ""}
    root.clearInterestPreview()
    root.interestsSection = "added"
    root.interestEditSerial++
    return true
  }
  function interestTermsKey(terms) {
    return JSON.stringify((Array.isArray(terms) ? terms : []).map(function(term) {
      return String(term).trim().replace(/\s+/g, " ").toLowerCase()
    }).filter(function(term, index, values) { return term && values.indexOf(term) === index }).sort())
  }
  function editOrAddInterest(criterion) {
    if (!root.interestsDraft || !criterion) return false
    var criteria = root.interestsDraft.criteria
    for (var i = 0; i < criteria.length; i++) {
      var current = criteria[i]
      var matches = criterion.serviceId ? current.serviceId === criterion.serviceId
        : criterion.featureId ? current.featureId === criterion.featureId
        : !current.serviceId && !current.featureId && current.kind === criterion.kind
          && root.interestTermsKey(current.terms) === root.interestTermsKey(criterion.terms)
      if (matches) return root.editInterest(i, current)
    }
    return root.editInterest(-1, criterion)
  }
  function chooseInterest(kind, choice) {
    if (!choice) return false
    var criterion = {id:"", kind:kind === "service" ? "service" : "hardware",
      label:String(choice.name || choice.label || ""),
      terms:Array.isArray(choice.terms) ? choice.terms.slice(0, 4) : [], enabled:true, origin:"user"}
    if (kind === "service") criterion.serviceId = choice.id
    else criterion.featureId = choice.id
    return root.editOrAddInterest(criterion)
  }
  // Direct picker APIs mutate only the shared draft. Legacy editor APIs above
  // remain available to callers outside the manager.
  function interestChoiceCriterion(kind, choice) {
    if (!choice || !choice.id) return null
    var criterion = {id:"", kind:kind === "service" ? "service" : "hardware",
      label:String(choice.name || choice.label || ""),
      terms:Array.isArray(choice.terms) ? choice.terms.slice(0, 4) : [], enabled:true, origin:"user"}
    if (kind === "service") criterion.serviceId = choice.id
    else criterion.featureId = choice.id
    return criterion
  }
  function draftInterestIndex(criterion) {
    if (!root.interestsDraft || !criterion) return -1
    var criteria = root.interestsDraft.criteria
    for (var i = 0; i < criteria.length; i++) {
      var current = criteria[i]
      if (criterion.serviceId ? current.serviceId === criterion.serviceId
          : criterion.featureId ? current.featureId === criterion.featureId
          : !current.serviceId && !current.featureId && current.kind === criterion.kind
            && root.interestTermsKey(current.terms) === root.interestTermsKey(criterion.terms)) return i
    }
    return -1
  }
  function interestChoiceSelected(kind, choice) {
    return root.draftInterestIndex(root.interestChoiceCriterion(kind, choice)) >= 0
  }
  function interestFilterKey(criterion) {
    if (criterion.serviceId) return String(criterion.serviceId)
    // A semantic key is stable across saved UUIDs and canonical feature aliases.
    return "interest-" + Qt.md5(JSON.stringify([criterion.kind, criterion.featureId || "",
      criterion.featureId ? "" : root.interestTermsKey(criterion.terms)]))
  }
  function browseInterestFilters(selected) {
    var criteria = root.interestsDirty && root.interestsDraft ? root.interestsDraft.criteria
      : root.inputsLoaded ? root.inputs.criteria || [] : []
    var filters = criteria.filter(function(c) { return c.enabled !== false && !c.serviceId }).map(function(c) {
      return {key:root.interestFilterKey(c), criterion:JSON.parse(JSON.stringify(c))}
    })
    // Removing or pausing a shortcut must not silently change an active filter.
    for (var old of root.setupInterestCriteria) {
      if (selected.indexOf(old.key) >= 0 && !filters.some(function(f) { return f.key === old.key }))
        filters.push(old)
    }
    root.setupInterestCriteria = filters.filter(function(f) { return selected.indexOf(f.key) >= 0 })
    return filters.slice(0, 128)
  }
  function addDraftInterest(criterion) {
    if (!root.interestsDraft || !criterion || root.activeAction === "save-interests") return false
    root.interestsError = root.interestValidation(criterion)
    if (root.interestsError) return false
    var index = root.draftInterestIndex(criterion)
    if (index >= 0) {
      root.interestsNotice = "Already selected" + (root.interestsDraft.criteria[index].enabled === false
        ? " · still paused. Use Resume to enable it." : ".")
      return true
    }
    if (root.interestsDraft.criteria.length >= 64) {
      root.interestsError = "Up to 64 saved interests are supported."
      return false
    }
    return root.changeInterests(root.interestsDraft.criteria.concat([criterion]), root.interestsDraft.ignoredSignals)
  }
  function selectInterestChoice(kind, choice, selected) {
    var criterion = root.interestChoiceCriterion(kind, choice)
    if (!criterion) return false
    if (selected) return root.addDraftInterest(criterion)
    var index = root.draftInterestIndex(criterion)
    return index < 0 || root.changeInterest(index, true)
  }
  function addCustomInterest(query) {
    var label = String(query || "").trim()
    return root.addDraftInterest({id:"", kind:"topic", label:label, terms:label ? [label] : [],
      enabled:true, origin:"user"})
  }
  function updateInterestEditor(field, value) {
    if (!root.interestEditor) return
    var editor = JSON.parse(JSON.stringify(root.interestEditor))
    if (field === "termText") {
      editor.termText = String(value)
      editor.criterion.terms = String(value).split(",").map(function(term) { return term.trim() }).filter(Boolean)
    } else editor.criterion[field] = value
    root.interestEditor = editor
    root.clearInterestPreview()
  }
  function interestValidation(criterion) {
    if (!criterion || !String(criterion.label || "").trim()) return "Give this interest a name."
    if (String(criterion.label).length > 80) return "Names can contain up to 80 characters."
    var terms = Array.isArray(criterion.terms) ? criterion.terms : []
    if (!criterion.serviceId && !criterion.featureId && !terms.length) return "Add at least one literal matching term."
    if (terms.length > 4 || terms.some(function(term) { return !term.trim() || term.length > 64 }))
      return "Use up to four terms, each no longer than 64 characters."
    return ""
  }
  function applyInterestEditor() {
    if (!root.interestEditor || !root.interestsDraft || root.activeAction === "save-interests") return false
    root.interestsError = root.interestValidation(root.interestEditor.criterion)
    if (root.interestsError) return false
    var criteria = root.interestsDraft.criteria.slice()
    if (root.interestEditor.index < 0) {
      if (root.draftInterestIndex(root.interestEditor.criterion) >= 0) {
        root.interestsError = "This pending interest is already selected. Remove the duplicate or dismiss the pending edit."
        return false
      }
      if (criteria.length >= 64) { root.interestsError = "Up to 64 saved interests are supported."; return false }
      criteria.push(root.interestEditor.criterion)
    } else criteria[root.interestEditor.index] = root.interestEditor.criterion
    if (!root.changeInterests(criteria, root.interestsDraft.ignoredSignals)) return false
    root.interestEditor = null
    root.clearInterestPreview()
    return true
  }
  function changeInterest(index, remove) {
    if (!root.interestsDraft || root.activeAction === "save-interests") return false
    var criteria = JSON.parse(JSON.stringify(root.interestsDraft.criteria))
    if (index < 0 || index >= criteria.length) return false
    if (remove) criteria.splice(index, 1)
    else criteria[index].enabled = criteria[index].enabled === false
    if (!root.changeInterests(criteria, root.interestsDraft.ignoredSignals)) return false
    if (root.interestEditor && root.interestEditor.index >= 0) {
      var editor = JSON.parse(JSON.stringify(root.interestEditor))
      if (remove && editor.index === index) {
        // Explicitly removing the edited item also ends that edit. An old
        // editor must never overwrite its successor or resurrect the item.
        root.interestEditor = null
        root.clearInterestPreview()
      } else if (remove && editor.index > index) {
        editor.index--
        root.interestEditor = editor
      } else if (!remove && editor.index === index) {
        // Applying the text draft later must not undo Pause/Resume.
        editor.criterion.enabled = criteria[index].enabled
        root.interestEditor = editor
      }
    }
    return true
  }
  function keepWatching(signal) {
    if (!signal) return false
    var features = root.inputs.featureChoices || []
    for (var i = 0; i < features.length; i++)
      if (features[i].id === signal.id) return root.chooseInterest("feature", features[i])
    var identity = String(signal.id || "")
    if (identity.indexOf("capability-") === 0) {
      var serviceId = identity.slice("capability-".length)
      var services = root.inputs.serviceChoices || []
      for (var j = 0; j < services.length; j++)
        if (services[j].id === serviceId) return root.chooseInterest("service", services[j])
    }
    return root.editOrAddInterest({id:"", kind:signal.domain === "hardware" ? "hardware" : "topic",
      label:String(signal.label || ""), terms:(signal.terms || []).slice(0, 4), enabled:true, origin:"user"})
  }
  function clearInterestPreview() {
    root.interestPreviewSerial++
    root.pendingInterestPreview = null
    root.interestPreview = null
    root.interestPreviewError = ""
  }
  function previewInterest() {
    if (!root.interestEditor) return false
    root.interestPreviewError = root.interestValidation(root.interestEditor.criterion)
    if (root.interestPreviewError) return false
    root.interestPreviewSerial++
    root.pendingInterestPreview = {serial:root.interestPreviewSerial,
      criterion:JSON.parse(JSON.stringify(root.interestEditor.criterion))}
    interestsDelay.restart()
    return true
  }
  function saveInterests() {
    if (!root.interestsDraft || root.busy) return false
    // The preserved inline editor participates in the same single Save action.
    if (root.interestEditor && !root.applyInterestEditor()) return false
    if (!root.interestsDirty) return false
    root.interestsError = ""
    root.interestsNotice = ""
    var payload = JSON.parse(JSON.stringify(root.interestsDraft))
    var context = root.contextPayload()
    for (var key in context) payload[key] = context[key]
    payload.draftSerial = root.interestsDraftSerial
    return root.request("save-interests", payload)
  }
  function applyInterestsResponse(result, request) {
    var action = request.action
    if (action === "preview-interest") {
      if (request.previewSerial !== root.interestPreviewSerial || request.catalogEpoch !== root.catalogEpoch) return true
      root.interestPreviewError = result.ok === true ? "" : String(result.error || "Local preview could not load.").slice(0, 400)
      if (result.ok === true) root.interestPreview = result.preview || {rows:[],total:0,partial:true}
      return true
    }
    if (action === "matches" || action === "review-matches") {
      if (!root.discoveryEnabled) return true
      if (request.matchesSerial !== root.matchesSerial || request.catalogEpoch !== root.catalogEpoch
          || request.criteriaRevision !== root.criteriaRevision) return true
      if (result.ok !== true) {
        root.matchesError = String(result.error || "Matches could not load. Try again.").slice(0, 400)
        return false
      }
      if (result.criteriaRevision !== root.criteriaRevision) {
        root.requestContext()
        root.scheduleMatches(true)
        return true
      }
      root.matches = result.matches || {rows:[],total:0,unread:0,page:1,pageCount:1,partial:true}
      root.matchesPage = Math.max(1, Number(root.matches.page) || 1)
      root.matchesLoaded = true
      root.matchesError = ""
      if (action === "review-matches") {
        var reviewed = JSON.parse(JSON.stringify(root.reviewedMatchIds))
        var ids = request.all === true ? (root.inspectorSnapshot ? [root.inspectorSnapshot.id] : []) : request.pluginIds || []
        for (var i = 0; i < ids.length; i++) reviewed[ids[i]] = true
        root.reviewedMatchIds = reviewed
      }
      return true
    }
    if (action === "context" && (request.criteriaRevision !== root.criteriaRevision
        || request.inventoryRevision !== root.inventoryRevision)) { root.requestContext(); return true }
    if (result.ok !== true) {
      // Revision conflicts deliberately retain the original revision and every draft field.
      root.interestsError = String(result.error || "Interests could not be saved. Try again.").slice(0, 400)
      if (action === "context" && !root.inputsLoaded) root.pendingMatches = false
      if (action === "save-interests") root.requestContext()
      return false
    }
    if (result.inputs) {
      var changed = root.criteriaRevision !== result.inputs.revision
      root.inputs = result.inputs
      root.inputsLoaded = true
      root.criteriaRevision = result.inputs.revision
      if (action === "context" && !root.interestsDirty && !root.interestEditor) root.interestsError = ""
      if (!root.interestsDraft || (!root.interestsDirty && !root.interestEditor)
          || (action === "save-interests" && request.draftSerial === root.interestsDraftSerial)) {
        root.interestsDraft = JSON.parse(JSON.stringify({revision:root.inputs.revision,
          criteria:root.inputs.criteria || [], ignoredSignals:root.inputs.ignoredSignals || []}))
        root.interestsDirty = false
      }
      if (changed || action === "save-interests") root.scheduleMatches(true)
    }
    if (result.preferences) root.preferences = result.preferences
    if (action === "save-interests") {
      root.interestsError = ""
      root.interestsNotice = "Interests saved for recommendations, including interests with no current results."
      root.boardRefreshPending = true
    }
    return true
  }
  property bool filtersExpanded: true
  property string browseDensity: "comfortable"
  property bool densityTouched: false
  property bool densitySavePending: false
  property int densitySerial: 0
  property string densitySaveError: ""
  Timer {
    id: densitySaveDelay
    objectName: "densitySaveDelay"
    interval: 250
    onTriggered: root.flushDensitySave()
  }
  function setBrowseDensity(value) {
    root.browseDensity = Presentation.densityName(value)
    root.densityTouched = true
    root.densitySerial++
    root.densitySavePending = true
    root.densitySaveError = ""
    densitySaveDelay.restart()
  }
  function flushDensitySave() {
    if (!root.densitySavePending || root.densitySaveError) return false
    if (!root.cacheLoaded && root.presentationPaused) {
      root.densitySaveError = "Browse view is applied but could not be saved. Select it again to retry."
      return false
    }
    if (!root.cacheLoaded || root.queryBusy || root.mutationBusy || root.pendingSetup
        || root.pendingSearch || root.pendingReadmeId || root.boardRefreshPending) {
      densitySaveDelay.restart()
      return false
    }
    return root.request("save-density", {browseDensity:root.browseDensity, densitySerial:root.densitySerial})
  }
  function finishDensitySave(result, request) {
    if (Number(request.densitySerial) !== root.densitySerial) {
      densitySaveDelay.restart()
      return
    }
    if (!result || result.ok !== true || result.browseDensity !== root.browseDensity) {
      root.densitySaveError = "Browse view is applied but could not be saved. Select it again to retry."
      return
    }
    root.densitySavePending = false
    root.densitySaveError = ""
    var current = JSON.parse(JSON.stringify(root.preferences))
    current.browseDensity = root.browseDensity
    root.preferences = current
  }
  property string setupVerification: "all"
  property var discoveryRows: []
  property var discoveryHistory: []
  property int discoveryHistoryIndex: -1
  property int discoveryRotation: 0
  property int discoverySerial: 0
  property string discoveryServicesKey: ""
  property var pendingDiscovery: null
  property var inspectorSnapshot: null
  property string discoveryError: ""
  readonly property bool discoveryCanGoBack: discoveryHistoryIndex > 0
  readonly property bool discoveryBusy: discoveryEnabled && (pendingDiscovery !== null
    || (root.requestActive && root.activeAction === "discover")
    || (!root.hasAnalyzed && root.backgroundAction === "analyze"))

  function loadDiagnostics() { return request("diagnostics", {}) }
  function clearPreviewCache() {
    if (root.busy || root.backgroundBusy || root.previewBusy) return false
    thumbnailLoader.images = ({})
    thumbnailLoader.attempts = ({})
    root.readmeMedia = []
    root.readmeBlocks = []
    root.readmeMediaIndexed = false
    root.readmePluginId = ""
    return request("clear-previews", {})
  }
  function retryStartup() {
    if (!root.cacheLoaded) return root.request("load", {})
    if (!root.inventoryReady) root.startInventoryCheck()
    if (!root.canBrowse || root.startupActivity.catalog.state === "error") root.refreshCatalog(false)
    return root.startStartup()
  }

  function ensureDiscovery() {
    if (!root.discoveryEnabled) return false
    if (!root.cacheLoaded || (!root.hasAnalyzed && root.backgroundBusy)) return false
    if (root.discoveryRows.length || root.discoveryBusy) return true
    return root.requestDiscovery()
  }
  function requestDiscovery() {
    if (!root.discoveryEnabled) return false
    if (!root.cacheLoaded || (!root.hasAnalyzed && root.backgroundBusy)) return false
    root.discoverySerial++
    root.discoveryError = ""
    var seen = []
    for (var i = 0; i < root.discoveryHistory.length; i++) {
      var rows = root.discoveryHistory[i].rows
      for (var j = 0; j < rows.length; j++) if (seen.indexOf(rows[j].id) < 0) seen.push(rows[j].id)
    }
    var payload = {profile:root.profile, inventory:root.inventory, installed:root.installed,
      unavailable:root.unavailable, queuedIds:Object.keys(root.setupSelection).slice(0, 50),
      selectionKey:JSON.stringify(Object.keys(root.setupSelection).sort()),
      seenIds:seen.slice(-36), rotation:root.discoveryRotation, discoverySerial:root.discoverySerial}
    if (root.requestActive) { root.pendingDiscovery = payload; return true }
    root.pendingDiscovery = null
    return request("discover", payload)
  }
  function discoverNext() {
    if (!root.discoveryEnabled) return false
    if (root.discoveryBusy || !root.cacheLoaded) return false
    root.discoveryRotation++
    return root.requestDiscovery()
  }
  function discoverBack() {
    if (!root.discoveryEnabled) return false
    if (root.discoveryBusy || !root.discoveryCanGoBack) return false
    root.discoverySerial++
    root.discoveryHistoryIndex--
    root.discoveryRows = root.discoveryHistory[root.discoveryHistoryIndex].rows
    return true
  }
  property bool pendingEnrichment: false
  property real likesFetchedAt: 0
  readonly property bool backgroundBusy: backgroundWorker.active
  readonly property string backgroundAction: backgroundBusy ? String(backgroundWorker.activeRequest.action || "") : ""
  readonly property bool backgroundAutomatic: backgroundBusy && backgroundWorker.activeRequest.automatic === true

  BackgroundWorker {
    id: backgroundWorker
    objectName: "backgroundJobs"
    helperPath: root.helperPath
    onProgress: function(event, request) { root.activityProgress(
      ["analyze", "rescan"].indexOf(request.action) >= 0 ? "hardware" : "catalog", event) }
    onFinished: function(result, request) { root.finishBackground(result, request) }
  }

  function backgroundRequest(action, extra) {
    if (root.mutationBusy || (root.catalogBusy && ["refresh", "enrich"].indexOf(action) >= 0)) return false
    var values = {profile: root.profile, installed: root.installed, inventory: root.inventory,
      unavailable: root.unavailable, inventoryRevision: root.inventoryRevision,
      scan:root.scan, previousScan:root.scan, streamProgress:true}
    for (var key in (extra || {})) values[key] = extra[key]
    var started = backgroundWorker.submit(action, values)
    if (started && ["refresh", "enrich"].indexOf(action) >= 0) {
      searchPreparationWorker.stop("Documentation preparation yielded to maintenance.", true)
      root.setActivity("catalog", {state:"running"})
    }
    if (started && ["analyze", "rescan"].indexOf(action) >= 0) root.setActivity("hardware", {state:"running"})
    if (started && (action !== "rescan" || values.automatic !== true)) {
      root.updateStatus = ""
      root.backgroundError = ""
      updateStatusExpiry.stop()
    }
    return started
  }

  function finishBackground(result, request) {
    var scanning = request.action === "analyze" || request.action === "rescan"
    if (result && result.cancelled === true) {
      root.setActivity(scanning ? "hardware" : "catalog", {state:"waiting"})
      root.resumeStartupLater()
      return
    }
    if (!result || result.ok !== true) {
      root.updateStatus = ""
      updateStatusExpiry.stop()
      root.error = String(result && result.error || "Background request failed. Retry from More actions.")
      root.backgroundError = root.error
      root.setupRefreshError = root.error
      if (scanning) {
        root.scanError = root.error
        root.setActivity("hardware", {state:"error"})
      } else root.setActivity("catalog", {state:"error"})
      if (root.editorOpen && root.workspaceView === "discover") root.ensureDiscovery()
      return
    }
    if (scanning) {
      root.scanError = ""
      root.profile = Array.isArray(result.profile) ? result.profile : []
      if (result.scan) root.scan = result.scan
      // Optional hardware may finish after inventory or a native mutation. Only
      // an authoritative, current inventory snapshot may change plugin state.
      if (!root.mutationBusy && Number(request.inventoryRevision) === root.inventoryRevision
          && result.inventoryAuthoritative === true) {
        root.inventoryReady = true
        root.inventory = Array.isArray(result.inventory) ? result.inventory : []
        root.installed = Array.isArray(result.installed) ? result.installed : []
        root.unavailable = Array.isArray(result.unavailable) ? result.unavailable : []
        root.inventoryRevision++
        root.setActivity("inventory", {state:"complete"})
      }
      root.changes = result.changes || ({added: [], removed: []})
      root.lastHardwareCheckAt = Date.now()
      root.hasAnalyzed = true
      root.setActivity("hardware", {state:result.error ? "error" : "complete"})
      root.reconcilePluginOperations()
      root.reconcileTerminalOutcomes()
      root.requestContext()
      root.scheduleMatches(true)
    }
    if (!scanning && "fetchedAt" in result) root.fetchedAt = Number(result.fetchedAt) || 0
    if (!scanning && "generatedAt" in result) root.generatedAt = String(result.generatedAt || "")
    if (!scanning && "likesFetchedAt" in result) root.likesFetchedAt = Number(result.likesFetchedAt) || 0
    if (!scanning && result.readmeIndex) root.readmeIndex = result.readmeIndex
    root.error = String(result.error || "")
    root.backgroundError = root.error
    root.setupRefreshError = root.error
    if (!scanning) root.dataWarning = String(result.dataWarning || "")
    if (!scanning) {
      root.setActivity("catalog", {state:root.error ? "error" : "complete"})
      root.catalogMatchesChanged()
    }
    var completion = Presentation.completion(request.action, request.automatic,
      Boolean(root.error))
    if (completion) {
      root.updateStatus = completion
      updateStatusExpiry.restart()
    }
    if (root.setupRequested || root.editorOpen) {
      root.boardRefreshPending = true
      if (!root.presentationPaused) root.queueBoardRefresh()
    }
    if (root.editorOpen && root.workspaceView === "discover") root.ensureDiscovery()
  }

  property string currentQuery: ""
  property string currentCategory: ""
  property string currentInstallFilter: "all"
  property string currentPartyFilter: "all"
  property var setupRows: []
  property var setupGroups: []
  property var setupSections: []
  property string setupGrouping: "none"
  property string setupAppliedGrouping: "none"
  property string setupQuery: ""
  property string setupGroup: ""
  property string setupSort: "likes"
  property string browseSort: "likes"
  property int setupSearchSerial: 0
  property var setupSearch: ({active:false, mode:"none", suggestion:null})
  property int setupPage: 1
  property int setupPageCount: 1
  property int setupTotal: 0
  property bool setupOverview: true
  property bool setupRequested: false
  property var setupFilterCounts: ({ all: 0, installed: 0, available: 0, firstParty: 0, thirdParty: 0 })
  property string setupInstallFilter: "all"
  property string setupPartyFilter: "all"
  property bool setupHardwareOnly: false
  property int setupHardwareMatchCount: 0
  property string setupCategory: ""
  property var serviceOptions: []
  property var setupServiceIds: []
  property var setupInterestCriteria: []
  property string setupServiceFilter: ""
  property bool setupServiceMode: false
  property bool setupServicesInitialized: false
  property var setupSelection: ({})
  property var batchItems: []
  property string batchKind: "install"
  property int batchCurrentIndex: -1
  property bool batchRunning: false
  property bool batchStopRequested: false
  property var batchResumePayload: null
  property bool batchJournalLoaded: false
  property bool batchRecovered: false

  // Optional host IPC v1. This lane never occupies the interactive worker or
  // cancels native mutations. Tokens live only here and in the transient worker.
  property int hostLeaseEpoch: 0
  property bool hostLeaseAttempted: false
  property string hostLeaseState: "idle"
  property string hostLeaseToken: ""
  property string hostLeaseEndingToken: ""
  property real hostLeaseDeadline: 0
  property real hostLeaseExpiresAt: 0
  property real hostLeaseRenewAt: 0
  property real hostLeaseAcquireDeadline: 0
  property bool hostLeaseBeginPending: false
  property bool hostLeaseEndRequested: false
  property bool hostLeaseEndConfirmed: false
  property var hostLeaseCleanup: []
  property string hostLifecycleSupport: "unknown"
  readonly property bool hostLifecycleSupported: hostLifecycleSupport === "supported"
  readonly property bool hostLifecycleBusy: hostLifecycleWorker.active
  property string hostLifecycleState: "idle"
  property string hostLifecycleError: ""
  property var hostLifecycleSnapshot: ({})
  property var hostRuntimeResults: ({})
  property var hostLifecycleAffectedIds: []
  property int hostMutationSerial: 0
  property int hostSnapshotMutationSerial: -1
  property real hostTargetGeneration: 0
  property real hostPollDeadline: 0
  property real hostPollNextAt: 0
  property int hostPollMutationSerial: -1
  property bool hostLifecycleShuttingDown: false
  readonly property bool hostRuntimeReady: root.hostLifecycleSupported
    && root.hostLifecycleState === "settled" && !root.batchRunning && !root.mutationActive
    && root.mutationQueue.length === 0 && !root.hostRuntimeOperationIncomplete()
    && root.hostSnapshotMutationSerial === root.hostMutationSerial
    && root.hostSnapshotSettled(root.hostLifecycleSnapshot, root.hostTargetGeneration)

  BackgroundWorker {
    id: hostLifecycleWorker
    objectName: "hostLifecycleJobs"
    helperPath: root.helperPath
    onFinished: function(result, request) { root.finishHostLifecycle(result, request) }
  }
  Timer {
    id: hostLifecycleRequestDeadline
    objectName: "hostLifecycleRequestDeadline"
    // End may include the backend's optional follow-up status call (two 3s IPC
    // budgets). Acquisition and renewals still have their short watchdog.
    interval: hostLifecycleWorker.activeRequest.operation === "end" ? 8000 : 4000
    onTriggered: hostLifecycleWorker.stop("Optional lifecycle request timed out.")
  }
  Timer {
    id: hostLifecycleTick
    objectName: "hostLifecycleTick"
    interval: 250
    repeat: true
    running: !root.hostLifecycleShuttingDown && (root.hostLeaseState === "acquiring"
      || Boolean(root.hostLeaseToken) || root.hostLeaseCleanup.length > 0
      || root.hostLifecycleBusy || root.hostPollDeadline > 0)
    onTriggered: root.pumpHostLifecycle()
  }

  function validHostToken(value) {
    return typeof value === "string" && value.length > 0 && value.length <= 256
      && value.charAt(0) !== "-" && !/[\s\x00-\x1f\x7f]/.test(value)
  }
  function hostSnapshotSettled(snapshot, target) {
    return snapshot && typeof snapshot.generation === "number" && isFinite(snapshot.generation)
      && snapshot.generation >= 0 && Math.floor(snapshot.generation) === snapshot.generation
      && typeof snapshot.settledGeneration === "number" && isFinite(snapshot.settledGeneration)
      && snapshot.settledGeneration >= Math.max(Number(target) || 0, snapshot.generation)
      && snapshot.pending === false && snapshot.held === false
      && snapshot.scanning === false && snapshot.reconciling === false
  }
  function hostRuntimeOperationIncomplete() {
    for (var i = 0; i < root.hostLifecycleAffectedIds.length; i++) {
      var operation = root.pluginOperation(root.hostLifecycleAffectedIds[i])
      if (operation.pending || ["failed", "partial"].indexOf(operation.status) >= 0) return true
    }
    return false
  }
  function queueHostLeaseEnd(token, epoch, expiresAt, attempts) {
    if (!root.validHostToken(token)) return
    if (hostLifecycleWorker.active && hostLifecycleWorker.activeRequest.operation === "end"
        && hostLifecycleWorker.activeRequest.token === token) return
    var queue = root.hostLeaseCleanup.slice()
    for (var i = 0; i < queue.length; i++) if (queue[i].token === token) return
    // One worker and one lease per batch normally bound this to two entries.
    if (queue.length < 16) queue.push({token:token, epoch:epoch,
      expiresAt:Number(expiresAt) || Date.now() + 10000, attempts:Number(attempts) || 0})
    root.hostLeaseCleanup = queue
  }
  function beginBatchLifecycle(ids) {
    if (root.hostLeaseToken)
      root.queueHostLeaseEnd(root.hostLeaseToken, root.hostLeaseEpoch, root.hostLeaseExpiresAt, 0)
    root.hostLeaseEpoch++
    root.hostLeaseAttempted = true
    root.hostLeaseToken = ""
    root.hostLeaseEndingToken = ""
    root.hostLeaseState = "acquiring"
    root.hostLeaseBeginPending = true
    root.hostLeaseEndRequested = false
    root.hostLeaseEndConfirmed = false
    root.hostLeaseAcquireDeadline = Date.now() + 4000
    root.hostLeaseDeadline = Date.now() + 60000
    root.hostLeaseExpiresAt = 0
    root.hostLeaseRenewAt = 0
    root.hostLifecycleSupport = "unknown"
    root.hostLifecycleState = "acquiring"
    root.hostLifecycleError = ""
    root.hostLifecycleSnapshot = ({})
    root.hostRuntimeResults = ({})
    root.hostLifecycleAffectedIds = ids.slice(0, root.batchKind === "update" ? 2000 : 50)
    root.hostMutationSerial++
    root.hostSnapshotMutationSerial = -1
    root.hostTargetGeneration = 0
    root.hostPollDeadline = 0
    root.hostPollMutationSerial = -1
    Qt.callLater(function() { root.pumpHostLifecycle() })
  }
  function startHostRuntimePoll() {
    if (!root.hostLeaseAttempted || root.hostLifecycleSupport === "unsupported") return
    if (!root.hostPollDeadline || root.hostPollMutationSerial !== root.hostMutationSerial) {
      // More than a scanner timeout plus another client's maximum lease.
      root.hostPollDeadline = Date.now() + 90000
      root.hostPollMutationSerial = root.hostMutationSerial
    }
    root.hostPollNextAt = Date.now()
    root.hostLifecycleState = "settling"
  }
  function endBatchLifecycle() {
    if (!root.hostLeaseAttempted) return
    root.hostLeaseEndRequested = true
    root.hostLeaseBeginPending = false
    if (root.hostLeaseToken) {
      root.hostLeaseEndingToken = root.hostLeaseToken
      root.queueHostLeaseEnd(root.hostLeaseToken, root.hostLeaseEpoch, root.hostLeaseExpiresAt, 0)
      root.hostLeaseToken = ""
      root.hostLeaseState = "ending"
    } else if (root.hostLeaseState === "acquiring") root.hostLeaseState = "fallback"
    root.hostLeaseRenewAt = 0
    root.startHostRuntimePoll()
    Qt.callLater(function() { root.pumpHostLifecycle() })
  }
  function submitHostLifecycle(operation, extra) {
    if (hostLifecycleWorker.active || root.hostLifecycleShuttingDown) return false
    var values = {operation:operation, leaseMs:10000, epoch:root.hostLeaseEpoch,
      mutationSerial:root.hostMutationSerial, requestedAt:Date.now()}
    for (var key in (extra || {})) values[key] = extra[key]
    var started = hostLifecycleWorker.submit("host-lifecycle", values)
    if (started) hostLifecycleRequestDeadline.restart()
    return started
  }
  function pumpHostLifecycle() {
    if (root.hostLifecycleShuttingDown) return
    var now = Date.now()
    if (root.hostLeaseState === "acquiring" && now >= root.hostLeaseAcquireDeadline) {
      root.endBatchLifecycle()
      // Release only the optional acquisition gate, never an actual mutation.
      if (root.batchRunning) root.scheduleBatchAdvance(100)
    }
    if (root.hostLeaseToken && (now >= root.hostLeaseDeadline || now >= root.hostLeaseExpiresAt))
      root.endBatchLifecycle()
    if (root.hostPollDeadline && now >= root.hostPollDeadline) {
      root.hostPollDeadline = 0
      root.hostLifecycleState = "unconfirmed"
      root.hostLifecycleError = "Omarchy runtime settlement was not confirmed before the deadline."
      root.publishHostRuntime({state:"unconfirmed", message:root.hostLifecycleError})
    }
    if (hostLifecycleWorker.active) return
    if (root.hostLeaseCleanup.length) {
      var queue = root.hostLeaseCleanup.slice()
      var cleanup = queue.shift()
      root.hostLeaseCleanup = queue
      root.submitHostLifecycle("end", {token:cleanup.token, epoch:cleanup.epoch,
        expiresAt:cleanup.expiresAt, attempts:cleanup.attempts})
    } else if (root.hostLeaseBeginPending && root.batchRunning && !root.hostLeaseEndRequested) {
      root.hostLeaseBeginPending = false
      root.submitHostLifecycle("begin", {})
    } else if (root.hostLeaseToken && !root.hostLeaseEndRequested && now >= root.hostLeaseRenewAt) {
      root.submitHostLifecycle("renew", {token:root.hostLeaseToken})
    } else if (root.hostPollDeadline && now >= root.hostPollNextAt) {
      root.hostPollNextAt = now + 750
      root.submitHostLifecycle("status", {})
    }
  }
  function finishHostLifecycle(result, request) {
    if (!hostLifecycleWorker.active || hostLifecycleWorker.activeRequest.generation === request.generation) {
      hostLifecycleRequestDeadline.stop()
      hostLifecycleWorker.response = null
    }
    if (root.hostLifecycleShuttingDown) return
    var envelope = result && result.ok === true && result.action === "host-lifecycle"
      && Number(result.generation) === Number(request.generation)
    var host = envelope && result.host && typeof result.host === "object" ? result.host : ({})
    var supported = envelope && host.supported === true && host.version === 1
    var current = request.epoch === root.hostLeaseEpoch
    var operation = request.operation
    // A stopped/superseded acquisition may still have reached native IPC. Release
    // that token without adopting it or touching a newer batch's lease.
    if (operation === "begin" && supported && root.validHostToken(host.token)
        && (!current || root.hostLeaseEndRequested || root.hostLeaseState !== "acquiring")) {
      if (host.token !== root.hostLeaseToken)
        root.queueHostLeaseEnd(host.token, request.epoch, host.expiresAt, 0)
      if (current) {
        root.hostLifecycleSupport = "supported"
        root.hostLeaseEndingToken = host.token
        root.hostLeaseState = "ending"
        root.startHostRuntimePoll()
      }
      Qt.callLater(function() { root.pumpHostLifecycle() })
      return
    }
    if (!current) {
      if (operation === "end" && (!envelope || host.supported !== true) && Number(request.attempts || 0) < 1
          && Number(request.expiresAt) > Date.now())
        root.queueHostLeaseEnd(request.token, request.epoch, request.expiresAt, 1)
      Qt.callLater(function() { root.pumpHostLifecycle() })
      return
    }
    if (operation === "renew" && (request.token !== root.hostLeaseToken || root.hostLeaseEndRequested)) {
      Qt.callLater(function() { root.pumpHostLifecycle() })
      return
    }
    if (envelope && host.supported === false) root.hostLifecycleSupport = "unsupported"
    else if (supported) root.hostLifecycleSupport = "supported"
    if (supported && typeof host.generation === "number" && isFinite(host.generation))
      root.hostTargetGeneration = Math.max(root.hostTargetGeneration, host.generation)
    if (operation === "begin") {
      var deadline = Math.min(root.hostLeaseDeadline, Number(host.deadline) || 0)
      var expiry = Math.min(deadline, Number(host.expiresAt) || 0)
      if (supported && host.ok === true && root.validHostToken(host.token) && expiry > Date.now()) {
        root.hostLeaseToken = host.token
        root.hostLeaseDeadline = deadline
        root.hostLeaseExpiresAt = expiry
        root.hostLeaseRenewAt = Date.now() + 3000
        root.hostLeaseState = "held"
        root.hostLifecycleState = "held"
      } else {
        if (supported && root.validHostToken(host.token)) {
          root.hostLeaseEndingToken = host.token
          root.queueHostLeaseEnd(host.token, request.epoch, host.expiresAt, 0)
          root.startHostRuntimePoll()
        }
        root.hostLeaseEndRequested = true
        root.hostLeaseState = "fallback"
        root.hostLifecycleState = root.hostLifecycleSupport === "unsupported" ? "unsupported" : "unconfirmed"
      }
      if (root.batchRunning) root.scheduleBatchAdvance(100)
    } else if (operation === "renew") {
      var renewed = Math.min(root.hostLeaseDeadline, Number(host.deadline) || 0, Number(host.expiresAt) || 0)
      if (supported && host.ok === true && renewed > Date.now()) {
        root.hostLeaseExpiresAt = renewed
        root.hostLeaseRenewAt = Date.now() + 3000
      } else root.endBatchLifecycle()
    } else if (operation === "end") {
      var retryEnd = (!envelope || host.supported !== true)
        && Number(request.attempts || 0) < 1 && Number(request.expiresAt) > Date.now()
      if (request.token === root.hostLeaseEndingToken) {
        root.hostLeaseEndConfirmed = supported && host.ok === true
        root.hostLeaseState = retryEnd ? "ending" : root.hostLeaseEndConfirmed ? "ended" : "unconfirmed"
        if (!retryEnd) root.hostLeaseEndingToken = ""
      }
      // A transport failure can have lost only the reply. Retry once, with the
      // same token, while the original lease could still be alive.
      if (retryEnd)
        root.queueHostLeaseEnd(request.token, request.epoch, request.expiresAt, 1)
      root.startHostRuntimePoll()
    } else if (operation === "status" && root.hostPollDeadline) {
      if (root.hostLifecycleSupport === "unsupported") {
        root.hostPollDeadline = 0
        root.hostLifecycleState = "unsupported"
        root.hostLifecycleError = ""
      } else if (supported && request.mutationSerial === root.hostMutationSerial) {
        root.acceptHostRuntimeSnapshot(host)
      }
    }
    if (root.hostLifecycleSupport === "unsupported") {
      root.hostPollDeadline = 0
      root.hostLifecycleState = "unsupported"
      root.hostLifecycleError = ""
    }
    Qt.callLater(function() { root.pumpHostLifecycle() })
  }
  function acceptHostRuntimeSnapshot(host) {
    if (!host.plugins || typeof host.plugins !== "object" || Array.isArray(host.plugins)
        || typeof host.scanError !== "string") return
    // Retain structural status only. Do not retain/log global diagnostics or the
    // registry dump; only bounded affected-plugin failure kinds are published.
    root.hostLifecycleSnapshot = {generation:host.generation, settledGeneration:host.settledGeneration,
      scanning:host.scanning, reconciling:host.reconciling, pending:host.pending, held:host.held,
      scanFailed:Boolean(host.scanError)}
    if (host.scanError) root.hostLifecycleError = "Omarchy plugin discovery failed. Runtime state needs attention."
    root.hostSnapshotMutationSerial = root.hostMutationSerial
    if (!root.hostSnapshotSettled(root.hostLifecycleSnapshot, root.hostTargetGeneration)) return
    if (root.mutationActive || root.hasCheckingOperations()) return
    root.hostPollDeadline = 0
    var results = ({})
    var scanFailed = Boolean(host.scanError)
    var failed = scanFailed
    var plugins = host.plugins && typeof host.plugins === "object" ? host.plugins : ({})
    var kinds = ["service", "barWidget", "panel", "overlay", "menu", "bar"]
    for (var i = 0; i < root.hostLifecycleAffectedIds.length; i++) {
      var identity = root.hostLifecycleAffectedIds[i]
      var plugin = plugins[identity] || ({})
      var errors = kinds.filter(function(kind) { return plugin.loadErrors && Boolean(plugin.loadErrors[kind]) })
      var local = root.inventoryEntry(identity)
      var missing = Boolean(local && local.enabled && plugin.enabled !== true)
      var restart = plugin.restartRequired === true
      var attention = scanFailed || errors.length > 0 || restart || missing
      var message = host.scanError ? "Omarchy plugin discovery failed; runtime state is unconfirmed."
        : errors.length ? "Omarchy could not load: " + errors.join(", ") + "."
        : restart ? "A kept service has changed; a shell restart is required to run its new code."
        : missing ? "The enabled plugin is not confirmed in Omarchy's runtime registry."
        : "Omarchy finished applying this plugin's changes."
      results[identity] = {state:attention ? "needs-attention" : "settled", loadErrors:errors,
        restartRequired:restart, missing:missing, message:message}
      if (attention) failed = true
    }
    root.hostRuntimeResults = results
    root.hostLifecycleError = host.scanError ? "Omarchy plugin discovery failed. Runtime state needs attention."
      : failed ? "One or more affected plugins need runtime attention." : ""
    root.hostLifecycleState = failed ? "needs-attention" : root.batchRunning ? "awaiting-operations" : "settled"
    root.publishHostRuntime(null)
  }
  function publishHostRuntime(fallback) {
    var results = JSON.parse(JSON.stringify(root.hostRuntimeResults))
    var items = root.batchItems.slice(), byId = ({}), changed = false
    for (var itemIndex = 0; itemIndex < items.length; itemIndex++) byId[items[itemIndex].id] = itemIndex
    for (var i = 0; i < root.hostLifecycleAffectedIds.length; i++) {
      var identity = root.hostLifecycleAffectedIds[i]
      if (fallback) results[identity] = fallback
      var runtime = results[identity]
      if (!runtime) continue
      var j = byId[identity]
      if (j !== undefined) {
        var item = items[j]
        if (["completed", "skipped"].indexOf(item.status) < 0) continue
        var message = String(item.message || "").split("\nRuntime:")[0]
        var nextMessage = (message + "\nRuntime: " + runtime.message).slice(0,240)
        if (nextMessage !== item.message) { items[j] = Object.assign({},item,{message:nextMessage}); changed = true }
      }
    }
    if (changed) { root.batchProgressOnly = true; root.batchItems = items; root.batchProgressOnly = false }
    root.hostRuntimeResults = results
  }
  function noteHostMutation(identity) {
    if (!root.hostLeaseAttempted) return
    if (identity && root.hostLifecycleAffectedIds.indexOf(identity) < 0)
      root.hostLifecycleAffectedIds = root.hostLifecycleAffectedIds.concat([identity]).slice(-64)
    root.hostMutationSerial++
    root.hostLifecycleState = root.hostLifecycleSupport === "unsupported" ? "unsupported"
      : root.hostLeaseToken ? "held" : "awaiting-operations"
  }
  property real lastHardwareCheckAt: 0
  property var pendingSearch: null
  property var pendingSetup: null
  property string pendingReadmeId: ""
  property string requestedReadmeId: ""
  property bool pendingAnalyze: false
  property bool boardRefreshPending: false
  property bool editorOpen: false
  property string setupDetailId: ""
  property var placementChoices: ({})
  property var editorRestorePayload: null
  property int editorRestoreTicks: 0
  property int editorRestorePostRequestTicks: 0
  property string editorRestoreState: "idle"
  property string editorRestoreToken: ""
  property int editorRestoreSerial: 0
  property real editorRestoreDeadline: 0
  property real editorRestoreRetryAt: 0
  property real editorRestoreAckDeadline: 0
  property bool editorRestoreSuppressed: false
  property bool batchCloseSuppressed: false
  property var editorSessionPayload: null
  property var pluginOperations: ({})
  property var mutationQueue: []
  property int mutationGeneration: 0
  property int activeMutationGeneration: 0
  property string mutationAction: ""
  property var activeMutation: ({})
  property bool mutationActive: false
  property bool mutationLaunching: false
  property bool mutationStreamFinished: false
  property bool mutationProcessExited: false
  property bool mutationTimedOut: false
  property int mutationProcessExitCode: 0
  property var mutationResponse: null
  property int mutationProgressEvents: 0
  property int mutationProgressSequence: 0
  property int inventoryRevision: 0

  property int generation: 0
  property int activeGeneration: 0
  property string activeAction: ""
  property var activeRequest: ({})
  property bool requestActive: false
  property bool queryLaunching: false
  property bool streamFinished: false
  property bool processExited: false
  property bool timedOut: false
  property int processExitCode: 0
  property var response: null
  readonly property bool queryBusy: requestActive || queryStopping
  readonly property bool mutationBusy: mutationActive || mutationQueue.length > 0 || batchRunning || selfUpdateBusy
  readonly property bool busy: queryBusy || mutationBusy
  readonly property string visibleAction: mutationActive ? mutationAction : activeAction

  function request(action, values) {
    if (!root.discoveryEnabled && ["discover", "matches", "review-matches"].indexOf(action) >= 0) return false
    if (root.requestActive || root.queryStopping || (root.sleeping && action !== "load")) return false
    var payload = values ? JSON.parse(JSON.stringify(values)) : ({})
    root.generation++
    payload.action = String(action || "")
    payload.generation = root.generation
    payload.inventoryRevision = root.inventoryRevision
    payload.catalogEpoch = root.catalogEpoch
    root.activeGeneration = root.generation
    root.activeAction = payload.action
    root.activeRequest = payload
    root.streamFinished = false
    root.processExited = false
    root.timedOut = false
    root.processExitCode = 0
    root.response = null
    root.queryOutputSize = 0
    root.queryOutputLines = 0
    queryParser.reset()
    if (["save-density", "context", "save-interests", "preview-interest", "matches", "review-matches"].indexOf(action) < 0) {
      root.error = ""
      root.notice = ""
    }
    root.requestActive = true
    if (worker.running) {
      worker.write(JSON.stringify(root.activeRequest) + "\n")
      deadline.restart()
    } else {
      worker.stdinEnabled = true
      root.queryLaunching = true
      queryLaunchDeadline.restart()
      worker.running = true
    }
    return true
  }

  function analyze() {
    root.pendingAnalyze = false
    return root.backgroundRequest("analyze", ({
      localOnly: true,
      previousProfile: root.profile,
      query: root.currentQuery,
      category: root.currentCategory,
      installFilter: root.currentInstallFilter,
      partyFilter: root.currentPartyFilter
    }))
  }

  function search(query, category, installFilter, partyFilter) {
    root.currentQuery = String(query || "").slice(0, 160)
    root.currentCategory = String(category || "").slice(0, 80)
    var nextInstallFilter = String(installFilter || root.currentInstallFilter || "all")
    var nextPartyFilter = String(partyFilter || root.currentPartyFilter || "all")
    root.currentInstallFilter = ["all", "installed", "available"].indexOf(nextInstallFilter) >= 0
      ? nextInstallFilter : "all"
    root.currentPartyFilter = ["all", "first-party", "third-party"].indexOf(nextPartyFilter) >= 0
      ? nextPartyFilter : "all"
    if (root.requestActive || root.queryStopping) {
      root.pendingSearch = ({
        query: root.currentQuery,
        category: root.currentCategory,
        installFilter: root.currentInstallFilter,
        partyFilter: root.currentPartyFilter
      })
      return true
    }
    return request("search", ({
      profile: root.profile,
      installed: root.installed,
      inventory: root.inventory,
      unavailable: root.unavailable,
      query: root.currentQuery,
      category: root.currentCategory,
      installFilter: root.currentInstallFilter,
      partyFilter: root.currentPartyFilter
    }))
  }

  function prepareSetupSearch(query, sort, explicit) {
    var state = BrowseState.searchState(query, sort, root, explicit === true)
    if (state.query !== root.setupQuery || state.sort !== root.setupSort) {
      root.setupSearchSerial++
      root.pendingSetup = null
      root.setupSearch = ({active:false, mode:"none", suggestion:null})
    }
    root.browseSort = state.browseSort
    root.setupQuery = state.query
    root.setupSort = state.sort
  }

  function restoreSetupSearch(payload) {
    var state = BrowseState.restore(payload, root)
    // A panel recovery with unchanged intent may reuse its current results or
    // in-flight request; it does not necessarily issue another Browse query.
    if (state.query !== root.setupQuery || state.sort !== root.setupSort) {
      root.setupSearchSerial++
      root.pendingSetup = null
      root.setupSearch = ({active:false, mode:"none", suggestion:null})
    }
    root.browseSort = state.browseSort
    root.setupQuery = state.query
    root.setupSort = state.sort
  }

  function quickSetup(
      query, group, sort, page, serviceIds, serviceFilter,
      installFilter, partyFilter, hardwareOnly, category, grouping) {
    root.setupRequested = true
    root.prepareSetupSearch(query, sort, false)
    root.setupSearchSerial++
    root.setupSearch = ({active:false, mode:"none", suggestion:null})
    root.setupGroup = String(group || "").slice(0, 40)
    root.setupPage = Math.max(1, Number(page) || 1)
    if (grouping !== undefined)
      root.setupGrouping = String(grouping) === "category" ? "category" : "none"
    var serviceValues = Array.isArray(serviceIds)
      ? serviceIds : (root.setupServicesInitialized ? root.setupServiceIds : [])
    var selectedServices = []
    for (var serviceIndex = 0; serviceIndex < serviceValues.length
         && serviceIndex < 64; serviceIndex++) {
      var serviceId = String(serviceValues[serviceIndex] || "").slice(0, 64)
      if (serviceId && selectedServices.indexOf(serviceId) < 0)
        selectedServices.push(serviceId)
    }
    var selectedServiceFilter = String(serviceFilter === undefined
      ? root.setupServiceFilter : (serviceFilter || "")).slice(0, 64)
    if (selectedServiceFilter && selectedServices.indexOf(selectedServiceFilter) >= 0)
      selectedServices = [selectedServiceFilter]
    selectedServiceFilter = ""
    root.setupServiceIds = selectedServices
    root.setupServiceFilter = ""
    root.setupServiceMode = selectedServices.length > 0
    var selectedInstallFilter = String(
      installFilter || root.setupInstallFilter || "all")
    var selectedPartyFilter = String(partyFilter || root.setupPartyFilter || "all")
    root.setupInstallFilter = ["all", "installed", "available"].indexOf(
      selectedInstallFilter) >= 0 ? selectedInstallFilter : "all"
    root.setupPartyFilter = ["all", "first-party", "third-party"].indexOf(
      selectedPartyFilter) >= 0 ? selectedPartyFilter : "all"
    root.setupHardwareOnly = hardwareOnly === undefined
      ? root.setupHardwareOnly : hardwareOnly === true
    root.setupCategory = String(category === undefined
      ? root.setupCategory : (category || "")).slice(0, 80)
    var payload = ({
      profile: root.profile,
      installed: root.installed,
      inventory: root.inventory,
      unavailable: root.unavailable,
      setupQuery: root.setupQuery,
      setupGroup: root.setupGroup,
      setupSort: root.setupSort,
      setupSearchSerial: root.setupSearchSerial,
      setupPage: root.setupPage,
      setupGrouping: root.setupGrouping,
      setupPageSize: 36,
      setupServices: selectedServices,
      setupInterestCriteria: root.browseInterestFilters(selectedServices),
      setupServiceFilter: selectedServiceFilter,
      setupInstallFilter: root.setupInstallFilter,
      setupPartyFilter: root.setupPartyFilter,
      setupHardwareOnly: root.setupHardwareOnly,
      setupCategory: root.setupCategory,
      setupVerification: root.setupVerification,
      boardKey: root.boardRevisionKey()
    })
    if (root.requestActive || root.queryStopping) {
      root.pendingSetup = payload
      return true
    }
    root.pendingSetup = null
    return request("quick-setup", payload)
  }

  function refresh(query, category) {
    if (root.catalogBusy) return false
    return root.backgroundRequest("refresh", ({
      profile: root.profile,
      installed: root.installed,
      inventory: root.inventory,
      unavailable: root.unavailable,
      query: root.currentQuery,
      category: root.currentCategory,
      installFilter: root.currentInstallFilter,
      partyFilter: root.currentPartyFilter
    }))
  }

  function rescan(automatic) {
    if (root.backgroundBusy || root.mutationBusy) return false
    if (automatic === true && Date.now() - root.lastHardwareCheckAt < 60000) return false
    return root.startRescan(automatic)
  }

  function startRescan(automatic) {
    return root.backgroundRequest("rescan", ({
      previousProfile: root.profile,
      query: root.currentQuery,
      category: root.currentCategory,
      installFilter: root.currentInstallFilter,
      partyFilter: root.currentPartyFilter,
      automatic: automatic === true
    }))
  }

  function verifyMutationState() {
    if (root.requestActive || root.mutationActive
        || root.mutationQueue.length) return false
    return request("verify-inventory", ({
      profile: root.profile,
      installed: root.installed,
      inventory: root.inventory,
      unavailable: root.unavailable
    }))
  }

  function panelOpened() {
    // Apps/IPC opens bypass openEditor(). A deliberate new open must release
    // the previous close's suppression so later mutations can restore the panel.
    root.editorRestoreSuppressed = false
    if (root.batchRunning) return
    root.batchCloseSuppressed = false
    if (!root.startupStarted && !root.hasAnalyzed) { root.startStartup(); return }
    if (!root.editorOpen && root.preferences.watchHardware !== false) root.rescan(true)
  }

  function savePreferences(value, scope) {
    if (root.busy || !value || typeof value !== "object") return false
    return request("save-preferences", ({
      profile: root.profile,
      installed: root.installed,
      inventory: root.inventory,
      unavailable: root.unavailable,
      query: root.currentQuery,
      category: root.currentCategory,
      installFilter: root.currentInstallFilter,
      partyFilter: root.currentPartyFilter,
      preferenceScope: String(scope || "settings").slice(0, 20),
      preferences: JSON.parse(JSON.stringify(value))
    }))
  }

  function saveServiceChoices(serviceIds, complete) {
    if (root.busy) return false
    var current = root.preferences && typeof root.preferences === "object"
      ? JSON.parse(JSON.stringify(root.preferences)) : ({})
    current.services = Array.isArray(serviceIds) ? serviceIds.slice(0, 64) : []
    current.servicesOnboardingComplete = complete === true
    return root.savePreferences(current, "services")
  }

  function setNotFit(pluginId, rejected) {
    root.error = "Not a fit feedback has been retired. Legacy values no longer change scores."
    return false
  }

  function isNotFit(pluginId) {
    return false
  }

  function inventoryEntry(pluginId) {
    var identity = String(pluginId || "")
    for (var index = 0; index < root.inventory.length; index++) {
      if (String(root.inventory[index].id || "") === identity) return root.inventory[index]
    }
    return null
  }

  function isInstalled(pluginId) {
    return root.inventoryEntry(pluginId) !== null
  }

  // Native Open has its own bounded, one-shot lane. It never participates in
  // mutation reconciliation, panel restoration, or shared notices/errors.
  readonly property bool pluginOpenBusy: pluginOpenWorker.active
  property int pluginOpenSelectionSerial: 0
  property var pluginOpenRequest: null
  property var pluginOpenResult: null
  onSetupDetailIdChanged: { root.pluginOpenSelectionSerial++; root.pluginOpenResult = null }
  onEditorOpenChanged: {
    root.pluginOpenSelectionSerial++
    root.pluginOpenResult = null
    if (root.editorOpen) idleSleep.stop()
    else { root.closedAt = Date.now(); root.scheduleSleep() }
  }

  BackgroundWorker {
    id: pluginOpenWorker
    objectName: "pluginOpenJobs"
    helperPath: root.helperPath
    onFinished: function(result, request) { root.finishPluginOpen(result, request) }
  }
  Timer {
    id: pluginOpenDeadline
    objectName: "pluginOpenDeadline"
    // 5s inventory + 3s summon + helper startup/termination grace.
    interval: 11000
    onTriggered: pluginOpenWorker.stop("Open was not confirmed before the timeout. The request may have reached Omarchy; it was not retried.")
  }
  function pluginOpenInventoryKey(identity) {
    var entry = root.inventoryEntry(identity)
    return entry ? JSON.stringify([entry.id, entry.enabled, entry.kinds]) : ""
  }
  function pluginOpenContextCurrent(request) {
    return request && request.selectionSerial === root.pluginOpenSelectionSerial
      && request.selectedId === root.setupDetailId && request.inventoryRevision === root.inventoryRevision
      && request.mutationGeneration === root.mutationGeneration && root.inventoryReady && !root.mutationBusy
      && request.inventoryKey === root.pluginOpenInventoryKey(request.pluginId)
  }
  function pluginOpenPending(id) {
    return root.pluginOpenBusy && pluginOpenWorker.activeRequest.pluginId === String(id || "")
  }
  function pluginOpenError(id) {
    var value = root.pluginOpenResult
    return value && value.pluginId === String(id || "") && root.pluginOpenContextCurrent(value.request)
      ? value.error : ""
  }
  function openPlugin(row) {
    if (!row || root.pluginOpenBusy || root.mutationBusy) return false
    var identity = String(row.id || "")
    var batchFailure = root.batchItems.some(function(item) {
      return item.id === identity && ["failed", "partial"].indexOf(item.status) >= 0
    })
    var state = InspectorState.resolve(row, root.inventoryEntry(identity), {
      inventoryReady:root.inventoryReady, operation:root.pluginOperation(identity),
      batchRunning:root.batchRunning, batchFailure:batchFailure, selfId:"io.github.ctl0v0.outfit"
    })
    if (!state.canOpen) return false
    var started = pluginOpenWorker.submit("open-plugin", {pluginId:identity,
      selectionSerial:root.pluginOpenSelectionSerial, selectedId:root.setupDetailId,
      inventoryRevision:root.inventoryRevision, inventoryKey:root.pluginOpenInventoryKey(identity),
      mutationGeneration:root.mutationGeneration})
    if (started) {
      root.pluginOpenRequest = pluginOpenWorker.activeRequest
      root.pluginOpenResult = null
      pluginOpenDeadline.restart()
    }
    return started
  }
  function finishPluginOpen(result, request) {
    var owner = root.pluginOpenRequest
    if (!owner || !request || request.action !== "open-plugin" || request.generation !== owner.generation
        || request.pluginId !== owner.pluginId) return
    pluginOpenDeadline.stop()
    root.pluginOpenRequest = null
    if (!root.pluginOpenContextCurrent(owner)) return
    var envelope = result && result.action === "open-plugin" && result.generation === owner.generation
      && result.pluginId === owner.pluginId
    var accepted = envelope && result.ok === true && result.openState === "accepted"
      && !result.error && pluginOpenWorker.exitCode === 0 && !pluginOpenWorker.failure
    var rejected = envelope && result.ok === false && ["unavailable", "unconfirmed"].indexOf(result.openState) >= 0
    root.pluginOpenResult = {pluginId:owner.pluginId, request:owner,
      openState:accepted ? "accepted" : rejected ? result.openState : "unconfirmed",
      error:accepted ? "" : rejected && typeof result.error === "string" && result.error
        ? result.error.slice(0, 400)
        : "Open was not confirmed. The request may have reached Omarchy; it was not retried."}
  }

  function pluginOperation(pluginId) {
    var value = root.pluginOperations[String(pluginId || "")]
    return value && typeof value === "object" ? value : ({})
  }

  function pluginPending(pluginId) {
    return root.pluginOperation(pluginId).pending === true
  }

  function pluginError(pluginId) {
    return String(root.pluginOperation(pluginId).error || "")
  }

  function pluginProgress(pluginId) {
    var operation = root.pluginOperation(pluginId)
    if (operation.pending !== true) return ""
    if (operation.status === "checking") return String(operation.message || "Checking the resulting plugin state…")
    if (operation.message && operation.status !== "queued") return String(operation.message)
    var action = String(operation.action || "")
    var verb = action === "install-plugin" ? "Installing"
      : (action === "enable-plugin" ? "Enabling"
        : (action === "disable-plugin" ? "Disabling"
          : (action === "place-plugin" ? "Moving widget"
            : (action === "remove-plugin" ? "Removing" : "Updating"))))
    return verb + (operation.status === "queued" ? " (queued)" : "...")
  }
  function pluginOutcome(pluginId) {
    var operation = root.pluginOperation(pluginId)
    if (operation.pending) return operation.status === "checking" ? "Checking" : root.pluginProgress(pluginId)
    if (["failed", "partial"].indexOf(operation.status) >= 0) return "Needs attention"
    if (root.hostLifecycleSupported && root.hostLifecycleAffectedIds.indexOf(String(pluginId)) >= 0) {
      if (root.hostLifecycleState === "unconfirmed") return "Runtime unconfirmed"
      if (root.hostSnapshotMutationSerial !== root.hostMutationSerial || root.hostPollDeadline > 0)
        return root.hostLeaseToken ? "Applying visuals" : "Checking runtime"
      var runtime = root.hostRuntimeResults[String(pluginId)] || ({})
      if (runtime.restartRequired) return "Restart required"
      if (runtime.state === "needs-attention") return "Needs attention"
    }
    if (!root.inventoryReady) return "Inventory pending"
    var entry = root.inventoryEntry(pluginId)
    if (entry) return entry.enabled ? "Enabled" : "Installed"
    return operation.status === "completed" && operation.lastAction === "remove-plugin" ? "Removed" : "Available"
  }

  function effectiveInstalled(pluginId) {
    var operation = root.pluginOperation(pluginId)
    if (operation.pending === true && typeof operation.desiredInstalled === "boolean")
      return operation.desiredInstalled === true
    return root.isInstalled(pluginId)
  }

  function effectiveEnabled(pluginId) {
    var operation = root.pluginOperation(pluginId)
    if (operation.pending === true && typeof operation.desiredEnabled === "boolean")
      return operation.desiredEnabled === true
    var local = root.inventoryEntry(pluginId)
    return Boolean(local && local.enabled === true)
  }

  function effectiveBarSection(pluginId) {
    var operation = root.pluginOperation(pluginId)
    if (operation.pending === true && operation.desiredSection)
      return String(operation.desiredSection)
    var local = root.inventoryEntry(pluginId)
    return local ? String(local.barSection || "") : ""
  }

  function setPluginOperation(pluginId, values) {
    var identity = String(pluginId || "")
    if (!identity) return
    var current = root.pluginOperation(identity)
    var operation = ({})
    for (var field in current) operation[field] = current[field]
    for (var key in values) operation[key] = values[key]
    var next = ({})
    for (var existing in root.pluginOperations) next[existing] = root.pluginOperations[existing]
    next[identity] = operation
    root.pluginOperations = next
  }

  function beginPluginOperation(action, pluginId, barSection, enableAfter) {
    var identity = String(pluginId || "")
    if (!identity || root.pluginPending(identity)) return false
    var values = {
      action: action,
      status: "queued",
      pending: true,
      error: "",
      message: "",
      desiredInstalled: null,
      desiredEnabled: null,
      desiredSection: "",
      desiredRevision: "",
      commandFailed: false,
      commandError: "",
      partialOutcome: false,
      partialError: "",
      reconcileAttempts: 0,
      batchIndex: -1
    }
    if (action === "install-plugin") {
      values.desiredInstalled = true
      values.desiredEnabled = Boolean(barSection) || enableAfter === true
      if (barSection) values.desiredSection = barSection
    } else if (action === "enable-plugin") {
      values.desiredEnabled = true
      if (barSection) values.desiredSection = barSection
    } else if (action === "disable-plugin") values.desiredEnabled = false
    else if (action === "place-plugin") {
      values.desiredEnabled = true
      values.desiredSection = barSection
    } else if (action === "remove-plugin") {
      values.desiredInstalled = false
      values.desiredEnabled = false
    }
    root.setPluginOperation(identity, values)
    return true
  }

  function clearPluginIntent(pluginId, status, message, error) {
    root.setPluginOperation(pluginId, {
      pending: false,
      status: status,
      action: "",
      desiredInstalled: null,
      desiredEnabled: null,
      desiredSection: "",
      desiredRevision: "",
      commandFailed: false,
      commandError: "",
      partialOutcome: false,
      partialError: "",
      reconcileAttempts: 0,
      batchIndex: -1,
      message: String(message || "").slice(0, 240),
      error: String(error || "").slice(0, 300)
    })
  }

  function desiredPluginStateObserved(pluginId) {
    var operation = root.pluginOperation(pluginId)
    if (operation.action === "install-plugin" && !operation.desiredRevision) return false
    if (operation.desiredRevision && (!root.inventoryEntry(pluginId)
        || root.inventoryEntry(pluginId).installedRevision !== operation.desiredRevision)) return false
    if (typeof operation.desiredInstalled === "boolean"
        && operation.desiredInstalled !== root.isInstalled(pluginId)) return false
    if (typeof operation.desiredEnabled === "boolean"
        && operation.desiredEnabled !== root.effectiveCanonicalEnabled(pluginId)) return false
    if (operation.desiredSection
        && operation.desiredSection !== root.effectiveCanonicalSection(pluginId)) return false
    return true
  }

  function effectiveCanonicalEnabled(pluginId) {
    var local = root.inventoryEntry(pluginId)
    return Boolean(local && local.enabled === true)
  }

  function effectiveCanonicalSection(pluginId) {
    var local = root.inventoryEntry(pluginId)
    return local ? String(local.barSection || "") : ""
  }

  function reconcilePluginOperations() {
    var unavailableInventory = root.unavailable.indexOf("installed plugins") >= 0
    var unavailableSections = root.unavailable.indexOf("bar sections") >= 0
    for (var identity in root.pluginOperations) {
      var operation = root.pluginOperation(identity)
      if (operation.pending !== true || operation.status !== "checking") continue
      var unavailable = unavailableInventory
        || (Boolean(operation.desiredSection) && unavailableSections)
      var batchIndex = Number(operation.batchIndex)
      if (!unavailable && root.desiredPluginStateObserved(identity)) {
        var completedMessage = operation.commandFailed === true
          ? "Requested plugin state confirmed after the command reported an error."
          : (operation.partialOutcome === true
            ? "Requested plugin state confirmed after a partial response."
            : operation.message)
        root.clearPluginIntent(identity, "completed", completedMessage, "")
        root.finishBatchReconciliation(batchIndex, "completed", completedMessage)
      } else {
        var attempts = Math.max(0, Number(operation.reconcileAttempts) || 0) + 1
        var failure = operation.commandFailed === true
          ? String(operation.commandError
            || "Outfit could not complete the plugin operation.")
          : (operation.partialOutcome === true
            ? String(operation.partialError || "The plugin operation needs attention.")
            : (unavailable
              ? "Could not verify the resulting plugin state."
              : "Omarchy did not reach the requested plugin state."))
        if (attempts >= 3) {
          var failureStatus = operation.partialOutcome === true ? "partial" : "failed"
          root.clearPluginIntent(identity, failureStatus, "", failure)
          root.finishBatchReconciliation(batchIndex, failureStatus, failure)
        } else {
          root.setPluginOperation(identity, {
            reconcileAttempts: attempts,
            message: unavailable
              ? "Still waiting for authoritative plugin inventory."
              : "Waiting for Omarchy to reach the requested plugin state."
          })
        }
      }
    }
  }

  function reconciliationRequestFailed(message) {
    for (var identity in root.pluginOperations) {
      var operation = root.pluginOperation(identity)
      if (operation.pending !== true || operation.status !== "checking") continue
      var attempts = Math.max(0, Number(operation.reconcileAttempts) || 0) + 1
      var batchIndex = Number(operation.batchIndex)
      if (attempts >= 3) {
        var failureStatus = operation.partialOutcome === true ? "partial" : "failed"
        root.clearPluginIntent(identity, failureStatus, "", message)
        root.finishBatchReconciliation(batchIndex, failureStatus, message)
      } else {
        root.setPluginOperation(identity, {
          reconcileAttempts: attempts,
          message: "Retrying authoritative plugin inventory."
        })
      }
    }
  }

  function reconcileTerminalOutcomes() {
    if (!root.inventoryReady || root.mutationBusy) return
    for (var identity in root.pluginOperations) {
      var operation = root.pluginOperation(identity)
      if (operation.pending || ["failed", "partial"].indexOf(operation.status) < 0) continue
      var previous = operation.lastRequest || ({})
      var local = root.inventoryEntry(identity)
      var enabled = Boolean(local && local.enabled)
      var sectionMatches = !previous.barSection || (local && local.barSectionKnown !== false
        && local.barSection === previous.barSection)
      var action = operation.lastAction
      if ((action === "install-plugin" || previous.reviewedRevision)
          && (!/^[0-9a-f]{40}$/.test(String(previous.reviewedRevision || ""))
            || !local || local.installedRevision !== previous.reviewedRevision)) continue
      if (!previous.batchItem && ((!local && ["enable-plugin", "disable-plugin", "place-plugin"].indexOf(action) >= 0)
          || (action === "place-plugin" && local && !enabled))) {
        root.clearPluginIntent(identity, "superseded", local
          ? "Widget is disabled; its location choice can be applied when enabling."
          : "The plugin is no longer installed; the previous action no longer applies.", "")
        continue
      }
      var observed = action === "remove-plugin" ? !local
        : action === "update-plugin" ? Boolean(local && local.installedRevision === previous.expectedRevision
          && enabled === previous.wasEnabled && sectionMatches)
        : action === "disable-plugin" ? !enabled
        : action === "install-plugin" ? Boolean(local && enabled === (previous.enableAfter === true || Boolean(previous.barSection)) && sectionMatches)
        : action === "enable-plugin" || action === "place-plugin" ? enabled && sectionMatches : false
      if (!observed) continue
      root.clearPluginIntent(identity, "completed", "Requested state confirmed by current inventory.", "")
      if (previous.batchItem) {
        for (var index = 0; index < root.batchItems.length; index++)
          if (root.batchItems[index].id === identity)
            root.replaceBatchItem(index, {status:"completed", message:"Requested state confirmed by current inventory."})
      }
    }
  }

  function finishBatchReconciliation(index, status, message) {
    if (index < 0 || index >= root.batchItems.length) return
    root.replaceBatchItem(index, {
      status: status,
      message: String(message || (status === "completed" ? "Completed" : "Needs attention"))
    })
    if (root.batchCurrentIndex === index) root.batchCurrentIndex = -1
    if (status !== "completed") root.endBatchLifecycle()
    if (!root.batchRunning) return
    if (root.batchStopRequested) {
      root.batchRunning = false
      return
    }
    root.scheduleBatchAdvance(status === "completed" ? 150 : 1000)
  }

  function scheduleOperationReconcile() {
    if (!root.hasCheckingOperations() || root.mutationActive || root.mutationQueue.length)
      return
    var attempts = 0
    for (var identity in root.pluginOperations)
      attempts = Math.max(attempts, Number(root.pluginOperation(identity).reconcileAttempts) || 0)
    operationReconcile.interval = Math.min(5000, 500 * Math.pow(2, attempts))
    operationReconcile.restart()
  }

  function selectedSetupRows() {
    var output = []
    for (var identity in root.setupSelection) output.push(root.setupSelection[identity])
    output.sort(function(left, right) {
      return String(left.name || left.id).localeCompare(String(right.name || right.id))
    })
    return output
  }

  function setSetupSelected(row, selected) {
    if (root.batchRunning || !row) return false
    var identity = String(row.id || "")
    if (!identity) return false
    var next = ({})
    for (var key in root.setupSelection) next[key] = root.setupSelection[key]
    if (selected === true && row.selectable === true && !root.effectiveInstalled(identity)) {
      next[identity] = {
        id: identity,
        name: String(row.name || identity).slice(0, 120),
        category: String(row.setupGroup || row.category || "Other").slice(0, 80),
        barWidget: row.barWidget === true,
        barSection: row.barWidget === true ? "right" : "",
        exclusiveActivation: row.exclusiveActivation === true,
        activate: row.exclusiveActivation !== true,
        reviewState: String(row.reviewState || "not reviewed").slice(0, 40),
        stars: Math.max(0, Number(row.stars) || 0),
        recommendationScore: Math.max(0, Number(row.recommendationScore) || 0),
        snapshotUrl: String(row.snapshotUrl || "").slice(0, 500),
        installNote: String(row.installNote || "").slice(0, 500),
        reviewedRevision: String(row.listingCommit || "").slice(0, 40)
      }
    } else delete next[identity]
    root.setupSelection = next
    return true
  }

  function setupSelected(pluginId) {
    return Object.prototype.hasOwnProperty.call(
      root.setupSelection, String(pluginId || ""))
  }

  function updateSetupOption(pluginId, key, value) {
    if (root.batchRunning) return false
    var identity = String(pluginId || "")
    var current = root.setupSelection[identity]
    if (!current) return false
    var item = JSON.parse(JSON.stringify(current))
    if (key === "barSection" && item.barWidget === true
        && ["left", "center", "right"].indexOf(String(value || "")) >= 0)
      item.barSection = String(value)
    else if (key === "activate" && item.exclusiveActivation === true)
      item.activate = value === true
    else return false
    var next = ({})
    for (var selectedId in root.setupSelection) next[selectedId] = root.setupSelection[selectedId]
    next[identity] = item
    root.setupSelection = next
    return true
  }

  function clearSetupSelection() {
    if (root.batchRunning) return false
    root.setupSelection = ({})
    return true
  }

  function safeBatchItem(value, withStatus) {
    if (!value || typeof value !== "object") return null
    var identity = String(value.id || "")
    if (!/^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/.test(identity) || identity.indexOf("..") >= 0)
      return null
    var section = String(value.barSection || "")
    if (["left", "center", "right"].indexOf(section) < 0) section = ""
    var item = {
      id: identity,
      name: String(value.name || identity).slice(0, 120),
      category: String(value.category || "Other").slice(0, 80),
      barWidget: value.barWidget === true,
      barSection: value.barWidget === true ? (section || "right") : "",
      exclusiveActivation: value.exclusiveActivation === true,
      activate: value.activate === true,
      reviewState: String(value.reviewState || "not reviewed").slice(0, 40),
      stars: Math.max(0, Number(value.stars) || 0),
      recommendationScore: Math.max(0, Number(value.recommendationScore) || 0),
      snapshotUrl: String(value.snapshotUrl || "").slice(0, 500),
      installNote: String(value.installNote || "").slice(0, 500),
      reviewedRevision: /^[0-9a-f]{40}$/.test(String(value.reviewedRevision || ""))
        ? String(value.reviewedRevision) : ""
    }
    item.kind = value.kind === "update" ? "update" : "install"
    if (item.kind === "update") {
      if (identity === "io.github.ctl0v0.outfit" || identity === "io.github.ctl0v0.omafit"
          || !/^[0-9a-f]{40}$/.test(String(value.expectedRevision || ""))
          || !/^[0-9a-f]{40}$/.test(String(value.expectedInstalledRevision || ""))) return null
      item.expectedRevision = String(value.expectedRevision)
      item.expectedInstalledRevision = String(value.expectedInstalledRevision)
      item.installedVersion = String(value.installedVersion || "").slice(0, 64)
      item.availableVersion = String(value.availableVersion || "").slice(0, 64)
    }
    if (withStatus === true) {
      var status = String(value.status || "queued")
      if (["queued", "running", "completed", "partial", "failed", "skipped"].indexOf(status) < 0)
        status = "queued"
      item.status = status
      item.message = String(value.message || "Waiting").slice(0, 240)
      item.attempts = Math.max(0, Math.min(3, Number(value.attempts) || 0))
      item.installedRevision = /^[0-9a-f]{40}$/.test(String(value.installedRevision || ""))
        ? String(value.installedRevision) : ""
    }
    return item
  }

  function persistBatchJournal() {
    if (!root.batchJournalLoaded) return
    journalWriteDelay.stop()
    var selection = []
    var selected = root.selectedSetupRows()
    for (var selectedIndex = 0; selectedIndex < selected.length && selectedIndex < 50; selectedIndex++) {
      var safeSelection = root.safeBatchItem(selected[selectedIndex], false)
      if (safeSelection) selection.push(safeSelection)
    }
    var items = []
    for (var itemIndex = 0; itemIndex < root.batchItems.length && itemIndex < (root.batchKind === "update" ? 2000 : 50); itemIndex++) {
      var safeItem = root.safeBatchItem(root.batchItems[itemIndex], true)
      if (safeItem) items.push(safeItem)
    }
    var text = JSON.stringify({
      schema: 1,
      kind: root.batchKind,
      selection: selection,
      items: items,
      running: root.batchRunning,
      resumePayload: root.batchResumePayload
    })
    if (text === root.lastBatchJournalText) return
    root.lastBatchJournalText = text
    batchJournal.setText(text)
    journalPermissionDelay.restart()
  }

  function restoreBatchJournal(raw) {
    var parsed = null
    try {
      var text = String(raw || "")
        if (text.length > 2 * 1024 * 1024) throw new Error("journal too large")
      parsed = JSON.parse(text)
    } catch (error) {
      parsed = null
    }
    var selection = ({})
    var items = []
    var wasRunning = false
    if (parsed && parsed.schema === 1) {
      var savedSelection = Array.isArray(parsed.selection) ? parsed.selection : []
      for (var selectedIndex = 0; selectedIndex < savedSelection.length && selectedIndex < 50; selectedIndex++) {
        var safeSelection = root.safeBatchItem(savedSelection[selectedIndex], false)
        if (safeSelection) selection[safeSelection.id] = safeSelection
      }
      var savedItems = Array.isArray(parsed.items) ? parsed.items : []
      wasRunning = parsed.running === true
      for (var itemIndex = 0; itemIndex < savedItems.length && itemIndex < (parsed.kind === "update" ? 2000 : 50); itemIndex++) {
        var safeItem = root.safeBatchItem(savedItems[itemIndex], true)
        if (!safeItem || safeItem.kind !== (parsed.kind === "update" ? "update" : "install")) continue
        if (wasRunning && safeItem.status === "running") {
          safeItem.status = "partial"
          safeItem.message = "Interrupted by a shell restart; verify the result and retry."
        }
        items.push(safeItem)
      }
    }
    root.setupSelection = selection
    root.batchKind = parsed && parsed.kind === "update" ? "update" : "install"
    root.batchItems = items
    root.batchCurrentIndex = -1
    root.batchRunning = false
    root.batchStopRequested = false
    root.batchResumePayload = parsed && parsed.resumePayload
      ? root.safeEditorPayload(parsed.resumePayload, "") : null
    if (parsed && parsed.resumePayload && Array.isArray(parsed.resumePayload.setupInterestCriteria))
      root.setupInterestCriteria = parsed.resumePayload.setupInterestCriteria.slice(0, 64)
    root.batchRecovered = wasRunning && items.length > 0
    root.batchJournalLoaded = true
    journalPermissionDelay.restart()
  }

  function requestMutation(action, values) {
    if (root.mutationQueue.length >= 50) return false
    var payload = values ? JSON.parse(JSON.stringify(values)) : ({})
    root.mutationGeneration++
    payload.action = String(action || "")
    payload.generation = root.mutationGeneration
    payload.streamProgress = true
    var queue = root.mutationQueue.slice()
    queue.push(payload)
    root.mutationQueue = queue
    Qt.callLater(function() { root.dispatchMutation() })
    return true
  }

  function dispatchMutation() {
    if (root.mutationActive || !root.mutationQueue.length) return
    if (root.requestActive
        && ["load", "analyze", "rescan", "verify-inventory"].indexOf(root.activeAction) >= 0)
      return
    var queue = root.mutationQueue.slice()
    var payload = queue.shift()
    root.mutationQueue = queue
    root.activeMutation = payload
    root.noteHostMutation(String(payload.pluginId || ""))
    root.activeMutationGeneration = Number(payload.generation) || 0
    root.mutationAction = String(payload.action || "")
    root.mutationStreamFinished = false
    root.mutationProcessExited = false
    root.mutationTimedOut = false
    root.mutationProcessExitCode = 0
    root.mutationResponse = null
    mutationParser.reset()
    root.mutationProgressEvents = 0
    root.mutationProgressSequence = 0
    mutationEofGrace.stop()
    root.mutationActive = true
    root.setPluginOperation(payload.pluginId, { status: "active" })
    mutationWorker.stdinEnabled = true
    root.mutationLaunching = true
    mutationLaunchDeadline.restart()
    mutationWorker.running = true
  }

  function startPluginAction(
      action, identity, resumeState, barSection, enableAfter, batchItem, reviewedRevision, update) {
    if (!root.inventoryReady) { root.error = "Wait for a successful inventory scan before changing plugins."; return false }
    if (root.selfUpdateBusy) return false
    if (root.batchRunning && batchItem !== true) return false
    var values = ({
      profile: root.profile,
      installed: root.installed,
      inventory: root.inventory,
      unavailable: root.unavailable,
      query: root.currentQuery,
      category: root.currentCategory,
      installFilter: root.currentInstallFilter,
      partyFilter: root.currentPartyFilter,
      pluginId: identity
    })
    if (["left", "center", "right"].indexOf(String(barSection || "")) >= 0)
      values.barSection = String(barSection)
    if (enableAfter === true) values.enableAfter = true
    if (batchItem === true) values.batchItem = true
    if (/^[0-9a-f]{40}$/.test(String(reviewedRevision || "")))
      values.reviewedRevision = String(reviewedRevision)
    if (action === "update-plugin") {
      var localUpdate = root.inventoryEntry(identity)
      if (!localUpdate || !update || identity === "io.github.ctl0v0.outfit"
          || !/^[0-9a-f]{40}$/.test(String(update.availableRevision || update.expectedRevision || ""))
          || !/^[0-9a-f]{40}$/.test(String(update.installedRevision || update.expectedInstalledRevision || ""))) return false
      values.expectedRevision = String(update.availableRevision || update.expectedRevision)
      values.expectedInstalledRevision = String(update.expectedInstalledRevision || update.installedRevision)
      values.wasEnabled = localUpdate.enabled === true
      values.barSection = String(localUpdate.barSection || "")
    }
    if (!root.beginPluginOperation(action, identity, values.barSection || "", enableAfter))
      return false
    root.setPluginOperation(identity, {lastAction:action, lastRequest:{action:action, pluginId:identity,
      barSection:String(values.barSection || ""), enableAfter:enableAfter === true,
      batchItem:batchItem === true, reviewedRevision:String(reviewedRevision || ""),
      expectedRevision:String(values.expectedRevision || ""), expectedInstalledRevision:String(values.expectedInstalledRevision || ""),
      wasEnabled:values.wasEnabled === true}})
    if (action === "update-plugin") {
      root.setPluginOperation(identity, {desiredInstalled:true, desiredRevision:values.expectedRevision,
        desiredEnabled:values.wasEnabled, desiredSection:values.barSection})
      root.invalidateUpdate(identity)
    }
    if (values.reviewedRevision)
      root.setPluginOperation(identity, {desiredRevision:values.reviewedRevision})
    if (batchItem === true)
      root.setPluginOperation(identity, { batchIndex: root.batchCurrentIndex })
    var started = root.requestMutation(action, values)
    if (!started)
      root.clearPluginIntent(identity, "failed", "", "Outfit's action queue is full.")
    if (started) root.prepareEditorRestore(batchItem === true && root.editorSessionPayload
      ? root.editorSessionPayload : resumeState, identity)
    return started
  }

  function installPlugin(row, barSection, resumeState, enableAfter) {
    if (!row || root.batchRunning || row.installAvailable !== true) return false
    var identity = String(row.id || "")
    if (!identity || root.effectiveInstalled(identity) || root.pluginPending(identity)) return false
    var exclusive = row.exclusiveActivation === true || String(row.kind || "").toLowerCase() === "bar"
      || (Array.isArray(row.kinds) && row.kinds.indexOf("bar") >= 0)
    var activate = enableAfter === undefined ? !exclusive : enableAfter === true
    return startPluginAction("install-plugin", identity, resumeState,
      row.barWidget === true && activate ? barSection : "", activate, false, row.listingCommit)
  }

  function retryPluginOperation(row, resumeState) {
    if (!row || root.pluginPending(row.id) || root.batchRunning) return false
    if (!root.inventoryReady) return root.rescan(false)
    var operation = root.pluginOperation(row.id)
    var previous = operation.lastRequest || ({})
    var local = root.inventoryEntry(row.id)
    if (previous.batchItem === true) return false
    var action = String(operation.lastAction || "")
    if (action === "update-plugin") {
      root.updatesError = "Check for updates and review the current version before retrying."
      return root.checkUpdates(true)
    }
    if (!local || !action) return root.verifyMutationState()
    if (previous.reviewedRevision && local.installedRevision !== previous.reviewedRevision) return false
    if (action === "install-plugin") {
      if (!previous.reviewedRevision || local.installedRevision !== previous.reviewedRevision) {
        root.error = "The installed revision does not match the reviewed installation. Review it again before enabling."
        return false
      }
      var wantedEnabled = previous.enableAfter === true || Boolean(previous.barSection)
      if (wantedEnabled && !local.enabled)
        return root.startPluginAction("enable-plugin", row.id, resumeState, previous.barSection || "", true, false, previous.reviewedRevision)
      if (!wantedEnabled && local.enabled)
        return root.disablePlugin(row, resumeState)
      if (previous.barSection && local.enabled && local.barSection !== previous.barSection)
        return root.startPluginAction("place-plugin", row.id, resumeState, previous.barSection, true, false, previous.reviewedRevision)
    } else if (action === "enable-plugin") {
      if (previous.reviewedRevision)
        return root.startPluginAction("enable-plugin", row.id, resumeState, previous.barSection || "", true, false, previous.reviewedRevision)
      if (!local.enabled) return root.enablePlugin(row, previous.barSection || "", resumeState)
      if (previous.barSection && local.barSection !== previous.barSection)
        return root.placePlugin(row, previous.barSection, resumeState)
    }
    else if (action === "disable-plugin" && local.enabled)
      return root.disablePlugin(row, resumeState)
    else if (action === "place-plugin" && local.enabled && previous.barSection)
      return previous.reviewedRevision
        ? root.startPluginAction("place-plugin", row.id, resumeState, previous.barSection, true, false, previous.reviewedRevision)
        : root.placePlugin(row, previous.barSection, resumeState)
    // Installation and removal retries require a fresh inspector confirmation.
    return root.verifyMutationState()
  }

  function replaceBatchItem(index, values) {
    if (index < 0 || index >= root.batchItems.length) return
    var next = root.batchItems.slice()
    var item = JSON.parse(JSON.stringify(next[index]))
    for (var key in values) item[key] = values[key]
    next[index] = item
    root.batchProgressOnly = Object.keys(values).every(function(key) { return key === "message" || key === "phase" })
    root.batchItems = next
    root.batchProgressOnly = false
  }

  function startSetupBatch(resumeState) {
    if (root.mutationBusy || !root.inventoryReady) return false
    var selected = root.selectedSetupRows()
    if (!selected.length || selected.length > 50) return false
    root.batchKind = "install"
    root.batchCloseSuppressed = false
    root.editorRestoreSuppressed = false
    root.batchItems = selected.map(function(row) {
      var item = JSON.parse(JSON.stringify(row))
      item.status = "queued"
      item.message = "Waiting"
      item.attempts = 0
      return item
    })
    root.batchCurrentIndex = -1
    root.batchStopRequested = false
    root.batchRecovered = false
    root.beginBatchLifecycle(selected.map(function(item) { return String(item.id) }))
    root.batchRunning = true
    root.batchResumePayload = root.safeEditorPayload(resumeState, "")
    root.prepareEditorRestore(root.batchResumePayload, "")
    root.scheduleBatchAdvance(600)
    return true
  }

  function scheduleBatchAdvance(delay) {
    batchAdvance.interval = Math.max(100, Number(delay) || 600)
    batchAdvance.restart()
  }

  function dispatchNextBatchItem() {
    if (!root.batchRunning || root.mutationActive || root.mutationQueue.length) return
    if (root.batchStopRequested) {
      root.batchRunning = false
      root.batchCurrentIndex = -1
      return
    }
    var index = -1
    for (var candidate = 0; candidate < root.batchItems.length; candidate++) {
      if (root.batchItems[candidate].status === "queued") {
        index = candidate
        break
      }
    }
    if (index < 0) {
      root.batchRunning = false
      root.batchCurrentIndex = -1
      Qt.callLater(function() { root.reconcileAfterMutations() })
      return
    }
    if (root.hostLeaseState === "acquiring") {
      root.pumpHostLifecycle()
      root.scheduleBatchAdvance(100)
      return
    }

    root.batchCurrentIndex = index
    root.replaceBatchItem(index, { status: "running", message: root.batchKind === "update" ? "Updating" : "Installing" })
    var item = root.batchItems[index]
    var local = root.inventoryEntry(item.id)
    if (item.kind === "update") {
      if (!local) {
        root.replaceBatchItem(index, {status:"skipped", message:"Plugin is no longer installed"})
        root.batchCurrentIndex = -1
        root.scheduleBatchAdvance(100)
        return
      }
      if (local.installedRevision === item.expectedRevision) {
        root.replaceBatchItem(index, {status:"completed", installedRevision:local.installedRevision,
          message:"Reviewed revision is already installed"})
        root.batchCurrentIndex = -1
        root.scheduleBatchAdvance(100)
        return
      }
      if (!root.startPluginAction("update-plugin", item.id, root.batchResumePayload, "", false, true, "", item)) {
        root.replaceBatchItem(index, {status:"failed", message:"Could not start update. Check for updates and review again."})
        root.batchCurrentIndex = -1
        root.scheduleBatchAdvance(1000)
      }
      return
    }
    if (local && (!item.reviewedRevision || local.installedRevision !== item.reviewedRevision)) {
      root.replaceBatchItem(index, {status:"failed", message:"Installed revision differs from the reviewed installation. Review it again."})
      root.batchCurrentIndex = -1
      root.endBatchLifecycle()
      root.scheduleBatchAdvance(1000)
      return
    }
    var placementSatisfied = item.barWidget !== true || item.activate !== true
      || String(local && local.barSection || "") === String(item.barSection || "")
    if (local && (item.activate !== true || local.enabled === true) && placementSatisfied) {
      root.replaceBatchItem(index, {
        status: "skipped",
        message: local.enabled === true ? "Already installed and enabled" : "Already installed"
      })
      root.batchCurrentIndex = -1
      root.scheduleBatchAdvance(100)
      return
    }

    var action = "install-plugin"
    if (local) action = item.barWidget === true ? "place-plugin" : "enable-plugin"
    var started = root.startPluginAction(
      action, item.id, root.batchResumePayload,
      item.barWidget === true ? item.barSection : "",
      item.activate === true, true, item.reviewedRevision)
    if (!started) {
      root.endBatchLifecycle()
      root.replaceBatchItem(index, { status: "failed", message: "Could not start installation" })
      root.batchCurrentIndex = -1
      root.scheduleBatchAdvance(1000)
    }
  }

  function finishBatchItem(result) {
    var index = root.batchCurrentIndex
    if (index < 0 || index >= root.batchItems.length) return
    var operation = result && result.operation && typeof result.operation === "object"
      ? result.operation : ({})
    var resultError = String(result && result.error || "")
    var currentItem = root.batchItems[index]
    var attempts = Math.max(0, Number(currentItem.attempts) || 0)
    if (result && result.ok !== true && result.retryable === true
        && result.errorCode === "inventory-unavailable"
        && attempts < 3) {
      root.clearPluginIntent(currentItem.id, "queued", "", "")
      root.replaceBatchItem(index, {
        status: "queued",
        message: "Waiting for Omarchy to finish reloading plugin inventory",
        attempts: attempts + 1
      })
      root.batchCurrentIndex = -1
      root.scheduleBatchAdvance(5000)
      return
    }
    var pendingOperation = root.pluginOperation(currentItem.id)
    if (pendingOperation.pending === true && pendingOperation.status === "checking") {
      root.replaceBatchItem(index, {
        status: "running",
        message: String(pendingOperation.message
          || "Checking the resulting plugin state.")
      })
      root.scheduleOperationReconcile()
      return
    }
    var status = result && result.ok === true
      ? String(operation.status || (result.error ? "partial" : "completed")) : "failed"
    if (result && result.ok === true && !result.error
        && (result.inventoryAuthoritative !== true || operation.observed !== true)) {
      root.replaceBatchItem(index, {
        status: "running",
        message: "Command completed; checking the resulting plugin state."
      })
      root.scheduleOperationReconcile()
      return
    }
    if (["completed", "partial"].indexOf(status) < 0) status = "failed"
    var message = String(operation.message || (result && (result.error || result.notice))
      || (status === "completed" ? "Installed and enabled" : "Installation failed")).slice(0, 240)
    var operationRevision = operation.installedRevision
    root.replaceBatchItem(index, {
      status: status,
      message: message,
      installedRevision: /^[0-9a-f]{40}$/.test(String(operationRevision || ""))
        ? String(operationRevision) : ""
    })
    root.batchCurrentIndex = -1
    if (root.batchStopRequested) {
      root.batchRunning = false
      Qt.callLater(function() { root.reconcileAfterMutations() })
    } else root.scheduleBatchAdvance(status === "completed" ? 150 : 1000)
  }

  function stopSetupBatch() {
    if (!root.batchRunning) return false
    root.batchStopRequested = true
    root.endBatchLifecycle()
    if (!root.mutationActive && !root.hasCheckingOperations()) {
      root.batchRunning = false
      root.batchCurrentIndex = -1
      Qt.callLater(function() { root.reconcileAfterMutations() })
    }
    return true
  }

  function retrySetupBatch() {
    if (root.mutationActive || root.mutationQueue.length || root.batchRunning
        || root.hasCheckingOperations() || !root.batchItems.length) return false
    var next = root.batchItems.slice()
    var retries = 0
    for (var index = 0; index < next.length; index++) {
      if (["failed", "partial"].indexOf(next[index].status) < 0) continue
      var item = JSON.parse(JSON.stringify(next[index]))
      item.status = "queued"
      item.message = "Waiting to retry"
      item.attempts = 0
      next[index] = item
      retries++
    }
    if (!retries) return false
    root.batchItems = next
    root.batchStopRequested = false
    root.batchRunning = true
    root.scheduleBatchAdvance(600)
    return true
  }

  function resumeSetupBatch() {
    if (root.mutationActive || root.mutationQueue.length || root.batchRunning
        || root.hasCheckingOperations() || !root.batchItems.length) return false
    var queued = root.batchItems.some(function(item) { return item.status === "queued" })
    if (!queued) return false
    root.batchStopRequested = false
    root.batchRunning = true
    root.scheduleBatchAdvance(600)
    return true
  }

  function resetSetupBatch() {
    if (root.batchRunning || root.mutationActive || root.mutationQueue.length
        || root.hasCheckingOperations()) return false
    root.endBatchLifecycle()
    for (var identity in root.pluginOperations) {
      var operation = root.pluginOperation(identity)
      if (operation.lastRequest && operation.lastRequest.batchItem === true) {
        var detached = JSON.parse(JSON.stringify(operation.lastRequest))
        detached.batchItem = false
        root.setPluginOperation(identity, {batchIndex:-1, lastRequest:detached})
      }
    }
    root.batchItems = []
    root.batchCurrentIndex = -1
    root.batchStopRequested = false
    root.batchResumePayload = null
    root.batchRecovered = false
    if (root.batchKind !== "update") root.setupSelection = ({})
    return true
  }

  function enablePlugin(row, barSection, resumeState) {
    if (!row || root.batchRunning) return false
    var identity = String(row.id || "")
    var local = inventoryEntry(identity)
    var replacement = local && Array.isArray(local.kinds) && local.kinds.indexOf("bar") >= 0
    if (!local || identity === "io.github.ctl0v0.outfit" || identity === "io.github.ctl0v0.omafit"
        || (local.canDisable !== true && !replacement) || root.effectiveEnabled(identity)
        || root.pluginPending(identity)) return false
    return startPluginAction("enable-plugin", identity, resumeState,
      row.barWidget === true ? barSection : "")
  }

  function disablePlugin(row, resumeState) {
    if (!row || root.batchRunning) return false
    var identity = String(row.id || "")
    var local = inventoryEntry(identity)
    if (!local || identity === "io.github.ctl0v0.outfit" || identity === "io.github.ctl0v0.omafit"
        || local.canDisable !== true || !root.effectiveEnabled(identity)
        || root.pluginPending(identity)) return false
    return startPluginAction("disable-plugin", identity, resumeState)
  }

  function placePlugin(row, barSection, resumeState) {
    if (!row || root.batchRunning || !root.effectiveInstalled(row.id)
        || row.barWidget !== true || root.pluginPending(row.id)) return false
    var identity = String(row.id || "")
    var local = inventoryEntry(identity)
    var section = String(barSection || "")
    if (!local || !Array.isArray(local.kinds) || local.kinds.indexOf("bar-widget") < 0
        || ["left", "center", "right"].indexOf(section) < 0) return false
    return startPluginAction("place-plugin", identity, resumeState, section)
  }

  function removePlugin(row, resumeState) {
    if (!row || root.batchRunning) return false
    var identity = String(row.id || "")
    var local = inventoryEntry(identity)
    if (!local || identity === "io.github.ctl0v0.outfit" || identity === "io.github.ctl0v0.omafit" || local.firstParty === true
        || root.pluginPending(identity)) return false
    return startPluginAction("remove-plugin", identity, resumeState)
  }

  function loadReadme(row) {
    if (!row || row.readmeAvailable !== true
        || root.preferences.readmeEnrichment === false) return false
    var identity = String(row.id || "")
    if (!identity) return false
    if (root.pendingReadmeId && root.pendingReadmeId !== identity)
      root.pendingReadmeId = ""
    root.requestedReadmeId = identity
    root.requestedReadmeIdentity = identity + "|" + String(row.repo || "") + "|" + String(row.listingCommit || "")
    if (root.readmeIdentity && root.readmeIdentity !== root.requestedReadmeIdentity) {
      root.readmePluginId = ""
      root.readmeContent = ""
      root.readmeBlocks = []
      root.readmeMedia = []
      root.readmeMediaIndexed = false
    }
    if (root.requestActive && root.activeAction === "readme-plugin"
        && String(root.activeRequest.pluginId || "") === identity
        && root.activeRequest.readmeIdentity === root.requestedReadmeIdentity) return true
    if (!root.requestActive && root.readmePluginId === identity
        && root.readmeMediaIndexed === true && root.readmeIdentity === root.requestedReadmeIdentity) return true
    if (root.pendingReadmeId === identity) return true
    root.pendingReadmeId = identity
    if (root.queryBusy) return true
    return root.startReadme(identity)
  }

  function startReadme(identity) {
    identity = String(identity || "")
    if (!identity || identity !== root.requestedReadmeId || root.queryBusy) return false
    root.pendingReadmeId = ""
    return request("readme-plugin", ({
      readmeIdentity:root.requestedReadmeIdentity,
      profile: root.profile,
      installed: root.installed,
      inventory: root.inventory,
      unavailable: root.unavailable,
      query: root.currentQuery,
      category: root.currentCategory,
      installFilter: root.currentInstallFilter,
      partyFilter: root.currentPartyFilter,
      pluginId: identity
    }))
  }

  function cancelPendingReadme(identity) {
    var selected = String(identity || "")
    var cancelActive = root.requestActive && root.activeAction === "readme-plugin"
      && (!selected || String(root.activeRequest.pluginId || "") === selected)
    if (!selected || root.pendingReadmeId === selected) root.pendingReadmeId = ""
    if (!selected || root.requestedReadmeId === selected) root.requestedReadmeId = ""
    if (!cancelActive) return
    queryLaunchDeadline.stop()
    deadline.stop()
    root.queryLaunching = false
    root.timedOut = true
    root.response = null
    root.streamFinished = true
    if (worker.running) {
      worker.running = false
      hardStop.restart()
    } else {
      root.processExited = true
      root.finishRequestIfReady()
    }
  }

  function safeUpdatesContext(value) {
    if (!value || typeof value !== "object" || Array.isArray(value)) return null
    var expanded = ({})
    var values = value.expanded && typeof value.expanded === "object" ? value.expanded : ({})
    for (var key of Object.keys(values).slice(0,64))
      if (/^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/.test(key) && ["constructor","prototype"].indexOf(key) < 0 && values[key] === true)
        expanded[key] = true
    return {y:Math.max(0,Math.min(1000000,Number(value.y) || 0)),
      x:Math.max(0,Math.min(1000000,Number(value.x) || 0)), expanded:expanded,
      id:String(value.id || "").slice(0,128), action:["details","update","explain"].indexOf(value.action) >= 0 ? value.action : "details",
      anchor:value.anchor ? {id:String(value.anchor.id || "").slice(0,128),
        offset:Math.max(-10000,Math.min(10000,Number(value.anchor.offset) || 0))} : null}
  }
  function safeEditorPayload(value, selectedId) {
    var input = value && typeof value === "object"
      ? JSON.parse(JSON.stringify(value)) : ({})
    var installFilter = String(input.installFilter || root.currentInstallFilter || "all")
    var partyFilter = String(input.partyFilter || root.currentPartyFilter || "all")
    var view = String(input.view || "setup")
    var setupStage = String(input.setupStage || "browse")
    var draft = input.draft && typeof input.draft === "object" ? input.draft : null
    var setupQuery = "setupQuery" in input ? input.setupQuery : root.setupQuery
    var setupGroup = "setupGroup" in input ? input.setupGroup : root.setupGroup
    var setupServiceFilter = "setupServiceFilter" in input
      ? input.setupServiceFilter : root.setupServiceFilter
    var setupInstallFilter = String(
      input.setupInstallFilter || root.setupInstallFilter || "all")
    var setupPartyFilter = String(input.setupPartyFilter || root.setupPartyFilter || "all")
    var setupHardwareOnly = "setupHardwareOnly" in input
      ? input.setupHardwareOnly === true : root.setupHardwareOnly
    var setupCategory = "setupCategory" in input ? input.setupCategory : root.setupCategory
    var query = "query" in input ? input.query : root.currentQuery
    var category = "category" in input ? input.category : root.currentCategory
    return {
      view: ["fit", "setup"].indexOf(view) >= 0 ? view : "setup",
      setupStage: ["services", "browse", "review", "progress", "updates"].indexOf(setupStage) >= 0
        ? setupStage : "browse",
      updatesQuery: String(input.updatesQuery || "").slice(0, 160),
      updatesScroll: Math.max(0, Math.min(1000000, Number(input.updatesScroll) || 0)),
      updatesContext: root.safeUpdatesContext(input.updatesContext),
      setupQuery: String(setupQuery || "").slice(0, 160),
      setupGroup: String(setupGroup || "").slice(0, 40),
      setupGrouping: String(input.setupGrouping || root.setupGrouping) === "category" ? "category" : "none",
      workspaceView: root.discoveryEnabled && String(input.workspaceView || root.workspaceView) === "discover" ? "discover" : "browse",
      discoverTab: String(input.discoverTab || root.discoverTab) === "matches" ? "matches" : "ideas",
      restoreToken: String(input.restoreToken || "").slice(0, 80),
      settingsOpen: input.settingsOpen === true,
      interestsOpen: input.interestsOpen === true,
      interestsFromSettings: input.interestsFromSettings === true,
      scrollAnchor: input.scrollAnchor && typeof input.scrollAnchor === "object" ? {
        id:String(input.scrollAnchor.id || "").slice(0, 160),
        offset:Math.max(-10000, Math.min(10000, Number(input.scrollAnchor.offset) || 0)),
        y:Math.max(0, Math.min(1000000, Number(input.scrollAnchor.y) || 0))} : null,
      inspectorScroll: Math.max(0, Math.min(1000000, Number(input.inspectorScroll) || 0)),
      inspectorFocus: String(input.inspectorFocus || "close").slice(0, 40),
      installDraft: input.installDraft ? {enable:input.installDraft.enable === true,
        section:["left", "center", "right"].indexOf(input.installDraft.section) >= 0 ? input.installDraft.section : "right"} : null,
      windowWidth: Math.max(0, Math.min(10000, Number(input.windowWidth) || 0)),
      windowHeight: Math.max(0, Math.min(10000, Number(input.windowHeight) || 0)),
      setupVerification: ["all", "verified", "unverified"].indexOf(String(input.setupVerification || root.setupVerification)) >= 0
        ? String(input.setupVerification || root.setupVerification) : "all",
      setupSort: BrowseState.restore(input, root).sort,
      browseSort: BrowseState.restore(input, root).browseSort,
      setupPage: Math.max(1, Number(input.setupPage || root.setupPage) || 1),
      setupServices: Array.isArray(input.setupServices)
        ? input.setupServices.slice(0, 64) : root.setupServiceIds.slice(0, 64),
      setupInterestCriteria: JSON.parse(JSON.stringify((Array.isArray(input.setupInterestCriteria)
        ? input.setupInterestCriteria : root.setupInterestCriteria).slice(0, 64))),
      setupServiceFilter: String(setupServiceFilter || "").slice(0, 64),
      setupInstallFilter: ["all", "installed", "available"].indexOf(
        setupInstallFilter) >= 0 ? setupInstallFilter : "all",
      setupPartyFilter: ["all", "first-party", "third-party"].indexOf(
        setupPartyFilter) >= 0 ? setupPartyFilter : "all",
      setupHardwareOnly: setupHardwareOnly,
      setupCategory: String(setupCategory || "").slice(0, 80),
      query: String(query || "").slice(0, 160),
      category: String(category || "").slice(0, 80),
      installFilter: ["all", "installed", "available"].indexOf(installFilter) >= 0
        ? installFilter : "all",
      partyFilter: ["all", "first-party", "third-party"].indexOf(partyFilter) >= 0
        ? partyFilter : "all",
      selectedId: String(input.selectedId || selectedId
        || (view === "setup" ? root.setupDetailId : "") || "").slice(0, 160),
      restoreDraft: input.restoreDraft === true && draft !== null,
      settingsTouched: input.settingsTouched === true,
      draft: draft ? {
        watchHardware: draft.watchHardware !== false,
        readmeEnrichment: draft.readmeEnrichment !== false,
        marketplaceThumbnails: draft.marketplaceThumbnails !== false
      } : null
    }
  }

  function prepareEditorRestore(payload, selectedId) {
    if (root.editorRestoreSuppressed || root.batchCloseSuppressed || !root.editorOpen) return false
    root.editorRestorePayload = safeEditorPayload(payload, selectedId)
    root.editorSessionPayload = root.editorRestorePayload
    root.editorRestoreTicks = 0
    root.editorRestorePostRequestTicks = 0
    root.editorRestoreDeadline = Date.now() + 260000
    if (!root.editorRestoreToken) root.editorRestoreState = "armed"
    editorRestoreTimer.restart()
    return true
  }

  function cancelEditorRestore() {
    editorRestoreTimer.stop()
    root.editorRestorePayload = null
    root.editorRestoreTicks = 0
    root.editorRestorePostRequestTicks = 0
    root.editorRestoreToken = ""
    root.editorRestoreDeadline = 0
    root.editorRestoreAckDeadline = 0
    root.editorRestoreRetryAt = 0
    root.editorRestoreState = "idle"
  }

  function rememberEditor(payload) {
    root.editorSessionPayload = root.safeEditorPayload(payload, "")
    if (root.editorRestorePayload) root.editorRestorePayload = root.editorSessionPayload
  }
  function userClosedEditor() {
    root.editorRestoreSuppressed = true
    if (root.batchRunning) root.batchCloseSuppressed = true
    root.cancelEditorRestore()
  }
  function acceptsEditorRestore(token) {
    return Boolean(token) && token === root.editorRestoreToken && !root.editorRestoreSuppressed
      && !root.batchCloseSuppressed && Date.now() < root.editorRestoreDeadline
  }
  function acknowledgeEditorRestore(token) {
    if (!root.acceptsEditorRestore(token)) return false
    root.editorOpen = true
    root.editorRestoreToken = ""
    root.editorRestoreState = "armed"
    return true
  }
  function coordinateEditorRestore() {
    if (!root.editorRestorePayload || root.editorRestoreSuppressed || root.batchCloseSuppressed
        || Date.now() >= root.editorRestoreDeadline) { root.cancelEditorRestore(); return }
    if (root.editorRestoreToken) {
      if (Date.now() >= root.editorRestoreAckDeadline) {
        // A second legacy host reload can discard an accepted summon during
        // incubation. Retire its token before retrying; late opens with the old
        // token are rejected, and explicit user close still cancels everything.
        root.editorRestoreToken = ""
        root.editorRestoreAckDeadline = 0
        root.editorRestoreState = "armed"
        root.editorRestoreRetryAt = Date.now() + 500
      }
      return
    }
    if (Date.now() < root.editorRestoreRetryAt) return
    if (!root.shell || typeof root.shell.isPluginOpen !== "function" || typeof root.shell.summon !== "function") return
    // Some hosts report their queued open intent while no panel exists yet.
    // Our panel must also have reported open before treating it as restored.
    if (root.editorOpen && root.shell.isPluginOpen("io.github.ctl0v0.outfit") === true) return
    var payload = root.safeEditorPayload(root.editorRestorePayload, "")
    root.editorRestoreToken = "outfit-" + (++root.editorRestoreSerial)
    root.editorRestoreAckDeadline = Math.min(root.editorRestoreDeadline, Date.now() + 5000)
    payload.restoreToken = root.editorRestoreToken
    root.editorRestoreState = "summoning"
    // An accepted summon owns one token until our panel acknowledges it or the
    // acknowledgement times out. At most one token is valid while reloading.
    if (root.shell.summon("io.github.ctl0v0.outfit", JSON.stringify(payload)) !== true) {
      root.editorRestoreToken = ""
      root.editorRestoreState = "armed"
      root.editorRestoreRetryAt = Date.now() + 500
    }
  }
  function editorOpened() {
    var waking = root.sleeping || root.queryStopping || !root.cacheLoaded
    root.editorOpen = true
    root.presentationPaused = false
    root.sleeping = false
    if (waking) { root.wakeRequested = true; root.resumeQueries() }
    root.startStartup()
    root.requestContext()
    root.scheduleMatches(true)
  }

  function editorClosed() {
    root.startupResumeNeeded = root.startupResumeNeeded || inventoryWorker.active || catalogWorker.active || backgroundWorker.active
    root.presentationPaused = true
    root.pendingSearch = null
    root.pendingSetup = null
    root.pendingDiscovery = null
    root.pendingReadmeId = ""
    root.pendingAnalyze = false
    root.pendingInterestPreview = null
    root.pendingMatches = false
    root.pendingMatchReview = null
    updatesWorker.stop("Update checks paused while Outfit is closed.",true)
    catalogWorker.stop("Catalog work paused while Outfit is closed.",true)
    inventoryWorker.stop("Startup inventory paused while Outfit is closed.",true)
    backgroundWorker.stop("Optional work paused while Outfit is closed.",true)
    readmeIndexer.stop("README indexing paused while Outfit is closed.", true)
    searchPreparationWorker.stop("Documentation preparation paused while Outfit is closed.", true)
    root.editorOpen = false
    if (root.requestActive && root.presentationAction(root.activeAction)) root.stopQueryForIdle()
    if (root.canBrowse && root.inventoryReady) root.startupQuiet = true
    root.thumbnailRows = []
    root.thumbnailDemandKey = ""
    root.updateStatus = ""
    updateStatusExpiry.stop()
    root.pendingEnrichment = false
    interestsDelay.stop()
    root.boardRefreshPending = false
    if (root.densitySavePending) root.flushDensitySave()
    root.persistBatchJournal()
    root.scheduleSleep()
    if (["enrich", "refresh"].indexOf(root.backgroundAction) >= 0)
      backgroundWorker.stop("Marketplace refresh cancelled; cached results remain available.", true)
  }

  function openEditor(payload) {
    if (!root.shell || typeof root.shell.summon !== "function") return false
    root.editorRestoreSuppressed = false
    var safePayload = safeEditorPayload(payload || root.editorSessionPayload, "")
    return root.shell.summon("io.github.ctl0v0.outfit", JSON.stringify(safePayload)) === true
  }

  function closeEditor() {
    root.userClosedEditor()
    if (!root.shell || typeof root.shell.hide !== "function") return false
    return root.shell.hide("io.github.ctl0v0.outfit") === true
  }

  function receiveOutput(raw) {
    if (!root.requestActive || root.streamFinished || root.queryStopping) return
    var text = String(raw || "")
    root.queryOutputSize += text.length
    root.queryOutputLines++
    if (text.length > 8 * 1024 * 1024 || root.queryOutputSize > 16 * 1024 * 1024 || root.queryOutputLines > 128) {
      root.rejectQueryOutput("Local helper output exceeded its limit.")
      return
    }
    try {
      var parsed = JSON.parse(text)
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)
          || Number(parsed.generation) !== root.activeGeneration || parsed.action !== root.activeAction
          || parsed.final === false || parsed.responseKind === "progress" || typeof parsed.ok !== "boolean") return
      root.response = parsed
    } catch (exception) {
      return
    }
    root.streamFinished = true
    root.finishRequestIfReady()
  }

  function rejectQueryOutput(message) {
    if (!root.requestActive || root.queryStopping) return
    root.error = message
    root.timedOut = true
    root.streamFinished = true
    root.response = null
    worker.running = false
    hardStop.restart()
  }

  function applyResponse(result, completedRequest) {
    // Invalidate on edit, before the debounce sends its next request. Also reject
    // obsolete errors and missing/old response fields without changing user intent.
    if (completedRequest.action === "quick-setup"
        && completedRequest.setupSearchSerial !== root.setupSearchSerial) return true
    if (!result
        || Number(result.generation) !== Number(completedRequest.generation)
        || String(result.action || "") !== String(completedRequest.action || "")) {
      if (["context", "save-interests", "preview-interest", "matches", "review-matches"].indexOf(completedRequest.action) >= 0)
        return root.applyInterestsResponse({ok:false,error:"Outfit returned a mismatched local result. Try again."}, completedRequest)
      root.error = "Outfit returned a mismatched query result."
      if (completedRequest.action === "verify-inventory") root.reconciliationRequestFailed(root.error)
      return false
    }
    if (completedRequest.action === "readme-plugin"
        && (String(completedRequest.pluginId || "") !== root.requestedReadmeId
          || String(completedRequest.readmeIdentity || "") !== root.requestedReadmeIdentity))
      return true
    if (completedRequest.action === "readme-plugin") root.readmeIdentity = String(completedRequest.readmeIdentity || "")
    if (["context", "save-interests", "preview-interest", "matches", "review-matches"].indexOf(completedRequest.action) >= 0)
      return root.applyInterestsResponse(result, completedRequest)
    if (completedRequest.action === "discover") {
      if (!root.discoveryEnabled) return true
      if (Number(completedRequest.discoverySerial) !== root.discoverySerial) return true
      if (result.ok !== true) {
        root.discoveryError = String(result.error || "Discovery could not load. Try again or browse cached listings.")
        return false
      }
      if (Number(completedRequest.inventoryRevision) !== root.inventoryRevision
          || completedRequest.selectionKey !== JSON.stringify(Object.keys(root.setupSelection).sort())) {
        root.requestDiscovery()
        return true
      }
      var picks = result.discovery && Array.isArray(result.discovery.rows) ? result.discovery.rows.slice(0, 3) : []
      root.discoveryRows = picks
      root.discoveryError = String(result.error || "")
      var history = root.discoveryHistory.slice(0, root.discoveryHistoryIndex + 1)
      history.push({rows:picks, rotation:completedRequest.rotation})
      root.discoveryHistory = history.slice(-12)
      root.discoveryHistoryIndex = root.discoveryHistory.length - 1
      return true
    }
    if (result.ok !== true) {
      root.error = result && result.error
        ? String(result.error) : "Outfit returned an unreadable response."
      if (completedRequest.action === "verify-inventory")
        root.reconciliationRequestFailed(root.error)
      return false
    }
    var currentCatalog = completedRequest.action === "load" || completedRequest.catalogEpoch === root.catalogEpoch
    if (currentCatalog && result.readmeIndex) root.readmeIndex = result.readmeIndex
    if (["diagnostics", "clear-previews"].indexOf(completedRequest.action) >= 0) {
      root.diagnostics = result.diagnostics || ({})
      root.notice = String(result.notice || "")
      root.error = String(result.error || "")
      return true
    }
    var staleInventory = Number(completedRequest.inventoryRevision) !== root.inventoryRevision
      && ["load", "analyze", "rescan", "save-preferences"]
        .indexOf(String(completedRequest.action || "")) < 0
    if (staleInventory) {
      if (completedRequest.action === "readme-plugin") {
        root.readmePluginId = String(result.readmePluginId || "")
        root.readmeContent = String(result.readmeContent || "")
        root.readmeBlocks = Array.isArray(result.readmeBlocks) ? result.readmeBlocks : []
        root.readmeMedia = Array.isArray(result.readmeMedia) ? result.readmeMedia : []
        root.readmeMediaIndexed = result.readmeMediaIndexed === true
      }
      return true
    }

    var localAcknowledgement = ["load", "save-preferences"].indexOf(result.action) >= 0
    if (!localAcknowledgement && Array.isArray(result.profile)) root.profile = result.profile
    var acceptInventory = !localAcknowledgement && (result.action !== "verify-inventory"
      || result.inventoryAuthoritative === true)
    if (acceptInventory && Array.isArray(result.installed)) root.installed = result.installed
    if (acceptInventory && Array.isArray(result.inventory)) root.inventory = result.inventory
    if (!localAcknowledgement && Array.isArray(result.unavailable)) root.unavailable = result.unavailable
    if (result.action === "verify-inventory") {
      root.inventoryReady = acceptInventory
      root.setActivity("inventory", {state:acceptInventory ? "complete" : "error"})
      if (acceptInventory) root.inventoryRevision++
      root.notice = String(result.notice || "")
      root.error = String(result.error || "")
      if (acceptInventory) root.boardRefreshPending = true
      root.reconcilePluginOperations()
      root.reconcileTerminalOutcomes()
    } else if (result.action === "save-preferences") {
      // Preference acknowledgements do not replace discovery results.
      if (String(completedRequest.preferenceScope || "settings") !== "services")
        root.boardRefreshPending = true
      root.scheduleMatches(true)
    } else if (result.action === "load") {
      if (!root.setupRequested && result.setup) {
        root.setupRows = result.setup.rows || []
        root.setupGroups = result.setup.groups || []
        root.setupSections = result.setup.sections || []
        root.setupAppliedGrouping = result.setup.grouping || "none"
        root.setupTotal = result.setup.total || 0
        root.setupPageCount = result.setup.pageCount || 1
        root.setupOverview = false
        root.serviceOptions = result.setup.services || []
      }
      root.cacheLoaded = true
      root.rows = Array.isArray(result.rows) ? result.rows : []
      root.categories = Array.isArray(result.categories) ? result.categories : []
      root.changes = result.changes && typeof result.changes === "object"
        ? result.changes : ({ added: [], removed: [] })
      root.filterCounts = result.filterCounts && typeof result.filterCounts === "object"
        ? result.filterCounts : ({ all: 0, installed: 0, available: 0, firstParty: 0, thirdParty: 0 })
    } else if (result.action === "quick-setup") {
      var setup = result.setup && typeof result.setup === "object" ? result.setup : ({})
      if (!root.pendingSetup) {
        root.setupRows = Array.isArray(setup.rows) ? setup.rows : []
        root.setupGroups = Array.isArray(setup.groups) ? setup.groups : []
        root.setupSections = Array.isArray(setup.sections) ? setup.sections : []
        root.setupAppliedGrouping = String(setup.grouping) === "category" ? "category" : "none"
        root.setupGroup = String(setup.group || "")
        root.setupPage = Math.max(1, Number(setup.page) || 1)
        root.setupPageCount = Math.max(1, Number(setup.pageCount) || 1)
        root.setupTotal = Math.max(0, Number(setup.total) || 0)
        root.setupSearch = BrowseState.searchResponse(setup.search, root.setupQuery, root.setupTotal)
        root.setupOverview = setup.overview === true
        root.serviceOptions = Array.isArray(setup.services) ? setup.services : []
        root.setupServiceIds = Array.isArray(setup.selectedServices)
          ? setup.selectedServices : []
        root.setupServiceFilter = String(setup.serviceFilter || "")
        root.setupServiceMode = setup.serviceMode === true
        root.setupServicesInitialized = true
        root.setupFilterCounts = setup.filterCounts && typeof setup.filterCounts === "object"
          ? setup.filterCounts : ({ all: 0, installed: 0, available: 0, firstParty: 0, thirdParty: 0 })
        root.setupInstallFilter = String(setup.installFilter || "all")
        root.setupPartyFilter = String(setup.partyFilter || "all")
        root.setupHardwareOnly = setup.hardwareOnly === true
        root.setupHardwareMatchCount = Math.max(0, Number(setup.hardwareMatchCount) || 0)
        root.setupCategory = String(setup.category || "")
        root.setupVerification = String(setup.verification || "all")
      }
    } else {
      root.rows = Array.isArray(result.rows) ? result.rows : []
      root.categories = Array.isArray(result.categories) ? result.categories : []
      root.changes = result.changes && typeof result.changes === "object"
        ? result.changes : ({ added: [], removed: [] })
      root.filterCounts = result.filterCounts && typeof result.filterCounts === "object"
        ? result.filterCounts : ({ all: 0, installed: 0, available: 0, firstParty: 0, thirdParty: 0 })
      root.currentQuery = String(result.query || "")
      root.currentCategory = String(result.category || "")
      root.currentInstallFilter = String(result.installFilter || "all")
      root.currentPartyFilter = String(result.partyFilter || "all")
      root.readmesFetched = Math.max(0, Number(result.readmesFetched) || 0)
      root.readmePluginId = String(result.readmePluginId || "")
      root.readmeContent = String(result.readmeContent || "")
      root.readmeBlocks = Array.isArray(result.readmeBlocks) ? result.readmeBlocks : []
      root.readmeMedia = Array.isArray(result.readmeMedia) ? result.readmeMedia : []
      root.readmeMediaIndexed = result.readmeMediaIndexed === true
    }
    if (result.preferences && typeof result.preferences === "object")
      root.preferences = result.preferences
    if (currentCatalog) {
      if ("catalogCount" in result) root.catalogCount = Math.max(0, Number(result.catalogCount) || 0)
      if ("fetchedAt" in result) root.fetchedAt = Math.max(0, Number(result.fetchedAt) || 0)
      if ("generatedAt" in result) root.generatedAt = String(result.generatedAt || "")
      if ("likesFetchedAt" in result) root.likesFetchedAt = Number(result.likesFetchedAt) || 0
    }
    if (result.action === "load") {
      root.catalogSource = String(result.catalogSource || (root.catalogCount ? "cache" : "none"))
      root.catalogBuiltAt = String(result.catalogBuiltAt || "")
      root.sourceDate = String(result.sourceDate || "")
      if (result.searchPack) root.searchPack = result.searchPack
      root.startupQuiet = Boolean(root.startupReceipt || root.preferences.startupReceipt)
        || (root.catalogSource === "cache" && ["ready", "imported", "cached"].indexOf(String(root.searchPack.state)) >= 0)
      root.setActivity("catalog", {state:root.canBrowse ? "cached" : "waiting"})
      Qt.callLater(function() { root.startStartup() })
    }
    var carriedSetupNotice = completedRequest.action === "quick-setup"
      ? root.setupRefreshNotice : ""
    var carriedSetupError = completedRequest.action === "quick-setup"
      ? root.setupRefreshError : ""
    var automaticRescan = completedRequest.action === "rescan"
      && completedRequest.automatic === true
    var changed = (Array.isArray(root.changes.added) && root.changes.added.length > 0)
      || (Array.isArray(root.changes.removed) && root.changes.removed.length > 0)
    root.notice = automaticRescan && !changed ? "" : String(result.notice || "")
    root.error = String(result.error || "")
    if (completedRequest.action === "quick-setup" && carriedSetupNotice) {
      if (!root.error) root.notice = carriedSetupNotice
      root.setupRefreshNotice = ""
    }
    if (completedRequest.action === "quick-setup" && carriedSetupError) {
      if (!root.error) root.error = carriedSetupError
      root.setupRefreshError = ""
    }
    if (completedRequest.action === "analyze") root.hasAnalyzed = true
    if (completedRequest.action === "analyze" && root.setupRequested && root.error)
      root.setupRefreshError = root.error
    if (completedRequest.action === "analyze" || completedRequest.action === "rescan") {
      if (result.scan) root.scan = result.scan
      root.inventoryRevision++
      root.lastHardwareCheckAt = Date.now()
      root.reconcilePluginOperations()
      if (completedRequest.action === "rescan" && root.setupRequested && !root.error) {
        root.setupRefreshNotice = root.notice
        root.quickSetup(root.setupQuery, root.setupGroup, root.setupSort, root.setupPage)
      }
    }
    if (["refresh", "readme-plugin"].indexOf(
        completedRequest.action) >= 0 && root.setupRequested && !root.error) {
      root.catalogMatchesChanged()
      if (root.workspaceView === "browse") root.boardRefreshPending = true
    }
    if (completedRequest.action === "save-preferences"
        && String(completedRequest.preferenceScope || "") === "services"
        && root.setupRequested && !root.error)
      root.setupRefreshNotice = root.notice
    return true
  }

  function finishRequestIfReady() {
    if (!root.requestActive || !root.streamFinished
        || (root.timedOut && !root.processExited)) return
    var completedRequest = root.activeRequest
    var completedResponse = root.response
    deadline.stop()
    hardStop.stop()
    queryEofGrace.stop()
    if (completedRequest.action === "save-density") {
      var validDensityResult = !root.timedOut && completedResponse
        && completedResponse.action === "save-density"
        && Number(completedResponse.generation) === Number(completedRequest.generation)
      root.finishDensitySave(validDensityResult ? completedResponse : null, completedRequest)
    } else if (["context", "save-interests", "preview-interest", "matches", "review-matches"].indexOf(completedRequest.action) >= 0
        && (root.timedOut || !completedResponse)) {
      root.applyInterestsResponse({ok:false, error:root.timedOut ? "The local request timed out. Try again." : "The local helper could not complete the request."}, completedRequest)
    } else if (!root.timedOut) {
      if (root.response) root.applyResponse(root.response, completedRequest)
      else if (root.processExitCode !== 0)
        root.error = "Outfit's helper could not complete the request. Python 3 is required."
      else root.error = "Outfit returned an unreadable response."
    }
    if (completedRequest.action === "verify-inventory" && (root.timedOut || !root.response))
      root.reconciliationRequestFailed(root.error)
    root.requestActive = false
    if (completedRequest.action === "save-preferences" && completedRequest.preferenceScope === "indexing")
      root.indexingPauseRequested = false
    root.activeAction = ""
    root.activeRequest = ({})
    root.response = null
    root.scheduleSleep()
    if (root.editorOpen && (root.pendingContext || root.pendingMatches || root.pendingMatchReview || root.pendingInterestPreview))
      interestsDelay.restart()
    root.dispatchMutation()
    if (root.hasCheckingOperations()) {
      root.scheduleOperationReconcile()
    } else if (root.presentationPaused && !root.editorOpen) {
      root.pendingSearch = null
      root.pendingSetup = null
      root.pendingReadmeId = ""
      root.pendingAnalyze = false
      if (root.densitySavePending) root.flushDensitySave()
      return
    } else if (root.pendingAnalyze && !root.hasAnalyzed) {
      root.pendingAnalyze = false
      Qt.callLater(function() { root.analyze() })
    } else if (root.pendingSearch) {
      var pending = root.pendingSearch
      root.pendingSearch = null
      Qt.callLater(function() {
        root.search(pending.query, pending.category, pending.installFilter, pending.partyFilter)
      })
    } else if (root.pendingSetup) {
      var setup = root.pendingSetup
      root.pendingSetup = null
      root.boardRefreshPending = false
      Qt.callLater(function() {
        if (setup.setupSearchSerial !== root.setupSearchSerial) return
        root.quickSetup(
          setup.setupQuery, setup.setupGroup, setup.setupSort, setup.setupPage,
          setup.setupServices, setup.setupServiceFilter,
          setup.setupInstallFilter, setup.setupPartyFilter,
          setup.setupHardwareOnly, setup.setupCategory, setup.setupGrouping)
      })
    } else if (root.pendingDiscovery) {
      var discovery = root.pendingDiscovery
      root.pendingDiscovery = null
      Qt.callLater(function() { if (discovery.discoverySerial === root.discoverySerial)
        root.requestDiscovery() })
    } else if (root.pendingReadmeId) {
      var readmeId = root.pendingReadmeId
      root.pendingReadmeId = ""
      Qt.callLater(function() { root.startReadme(readmeId) })
    } else if (root.boardRefreshPending && !root.batchRunning && !root.mutationBusy) {
      Qt.callLater(function() { root.queueBoardRefresh() })
    }
  }

  function receiveMutationOutput(raw) {
    if (!root.mutationActive || root.mutationStreamFinished) return
    try {
      var text = String(raw || "")
      if (text.length > 4 * 1024 * 1024) return
      var parsed = JSON.parse(text)
      if (!parsed || typeof parsed !== "object") return
      if (parsed.responseKind === "progress") {
        if (text.length > 4096 || root.mutationProgressEvents >= 128
            || parsed.action !== root.activeMutation.action
            || Number(parsed.generation) !== root.activeMutationGeneration
            || (parsed.pluginId && parsed.pluginId !== root.activeMutation.pluginId)
            || (parsed.sequence !== undefined && (Number(parsed.sequence) <= root.mutationProgressSequence
              || !isFinite(Number(parsed.sequence))))
            || ["checking", "validating", "downloading", "installing", "enabling", "disabling", "removing",
              "placing", "reloading", "verifying", "inventory", "install", "enable", "disable", "remove", "place", "updating"].indexOf(parsed.phase) < 0) return
        root.mutationProgressEvents++
        if (parsed.sequence !== undefined) root.mutationProgressSequence = Number(parsed.sequence)
        var phaseLabels = {checking:"Checking plugin state…", validating:"Validating plugin…", downloading:"Downloading plugin…",
          updating:"Updating plugin…", installing:"Installing plugin…", enabling:"Enabling plugin…", disabling:"Disabling plugin…", removing:"Removing plugin…",
          placing:"Moving widget…", reloading:"Waiting for Omarchy…", verifying:"Verifying plugin state…", inventory:"Checking installed plugins…"}
        var message = String(parsed.message || phaseLabels[parsed.phase] || "Updating plugin…").replace(/[\x00-\x1f\x7f]/g, " ").slice(0, 240)
        root.setPluginOperation(root.activeMutation.pluginId, {phase:parsed.phase, message:message})
        if (root.activeMutation.batchItem === true)
          root.replaceBatchItem(root.batchCurrentIndex, {message:message})
        return
      }
      root.mutationResponse = parsed
      root.mutationStreamFinished = true
    } catch (exception) {
      // Non-protocol lines never replace a valid final response or finish a job.
      return
    }
    root.finishMutationIfReady()
  }

  function failPluginMutation(request, message) {
    if (request.batchItem === true) root.endBatchLifecycle()
    var identity = String(request.pluginId || "")
    root.setPluginOperation(identity, {
      pending: true,
      status: "checking",
      commandFailed: true,
      commandError: String(message || "Outfit could not complete the plugin operation."),
      message: "Command failed; checking the resulting plugin state.",
      reconcileAttempts: 0
    })
  }

  function applyMutationResponse(result, completedRequest) {
    if (!result
        || Number(result.generation) !== Number(completedRequest.generation)
        || String(result.action || "") !== String(completedRequest.action || "")) {
      root.failPluginMutation(completedRequest, "Outfit returned a mismatched operation result.")
      return false
    }
    if (result.ok !== true) {
      root.failPluginMutation(
        completedRequest, String(result.error || "Outfit could not complete the operation."))
      return true
    }

    var authoritative = result.inventoryAuthoritative === true
    if (authoritative && Array.isArray(result.inventory)) {
      root.inventory = result.inventory
      root.installed = Array.isArray(result.installed) ? result.installed : []
      root.inventoryRevision++
    }
    if (Array.isArray(result.unavailable)) root.unavailable = result.unavailable
    if (result.preferences && typeof result.preferences === "object")
      root.preferences = result.preferences
    root.notice = ""

    var operation = result.operation && typeof result.operation === "object"
      ? result.operation : ({})
    var identity = String(completedRequest.pluginId || operation.pluginId || "")
    var message = String(operation.message || result.notice || "")
    if (result.error) {
      if (authoritative) {
        root.clearPluginIntent(identity, "partial", message, String(result.error))
      } else {
        root.setPluginOperation(identity, {
          pending: true,
          status: "checking",
          message: "Operation needs attention; checking the resulting plugin state.",
          error: "",
          partialOutcome: true,
          partialError: String(result.error),
          reconcileAttempts: 0
        })
      }
    } else if (authoritative && operation.observed === true
        && root.desiredPluginStateObserved(identity)) {
      root.clearPluginIntent(identity, "completed", message, "")
    } else {
      root.setPluginOperation(identity, {
        pending: true,
        status: "checking",
        message: "Command completed; checking the resulting plugin state.",
        error: "",
        reconcileAttempts: 0
      })
    }
    return true
  }

  function hasCheckingOperations() {
    for (var identity in root.pluginOperations) {
      var operation = root.pluginOperation(identity)
      if (operation.pending === true && operation.status === "checking") return true
    }
    return false
  }

  function queueBoardRefresh() {
    if (!root.cacheLoaded || root.sleeping || (root.presentationPaused && !root.editorOpen)) return
    if (root.requestActive && root.activeAction === "quick-setup"
        && root.activeRequest.boardKey === root.boardRevisionKey() && !root.pendingSetup) {
      root.boardRefreshPending = false
      return
    }
    if (root.requestActive || root.mutationBusy) { root.boardRefreshPending = true; return }
    root.boardRefreshPending = false
    root.pendingSearch = null
    if (root.workspaceView === "browse" && (root.setupRequested || root.editorOpen)) {
      root.pendingSetup = null
      root.quickSetup(root.setupQuery, root.setupGroup, root.setupSort, root.setupPage)
    }
  }

  function boardRevisionKey() {
    return JSON.stringify([root.inventoryRevision, root.catalogEpoch, root.criteriaRevision])
  }

  function reconcileAfterMutations() {
    if (root.mutationActive || root.mutationQueue.length) return
    if (root.hasCheckingOperations()) {
      root.scheduleOperationReconcile()
      return
    }
    if (root.batchRunning) return
    root.queueBoardRefresh()
  }

  function finishMutationIfReady() {
    if (!root.mutationActive || !root.mutationStreamFinished
        || !root.mutationProcessExited) return
    var completedRequest = root.activeMutation
    var completedResponse = root.mutationResponse
    var responseAccepted = false
    mutationDeadline.stop()
    mutationHardStop.stop()
    mutationEofGrace.stop()
    if (!root.mutationTimedOut) {
      if (completedResponse)
        responseAccepted = root.applyMutationResponse(completedResponse, completedRequest)
      else if (root.mutationProcessExitCode !== 0)
        root.failPluginMutation(
          completedRequest, "Outfit's helper could not complete the plugin operation.")
      else root.failPluginMutation(
        completedRequest, "Outfit returned an unreadable plugin operation result.")
    }
    root.mutationActive = false
    root.mutationAction = ""
    root.activeMutation = ({})
    root.invalidateUpdate(String(completedRequest.pluginId || ""))
    root.boardRefreshPending = true
    root.scheduleMatches(true)
    // Once runtime support is known, later individual actions must invalidate
    // the old batch snapshot too. They get a status check, never a new lease.
    if (completedRequest.batchItem !== true && root.hostLeaseAttempted)
      root.startHostRuntimePoll()
    if (root.editorRestorePayload && !root.batchRunning)
      root.editorRestoreDeadline = Math.min(root.editorRestoreDeadline, Date.now() + 15000)
    if (completedRequest.batchItem === true) {
      if (!responseAccepted || !completedResponse || completedResponse.ok !== true || completedResponse.error)
        root.endBatchLifecycle()
      else if (root.hostLeaseEndRequested) root.startHostRuntimePoll()
      var batchResult = responseAccepted ? completedResponse : (root.mutationTimedOut ? ({
        ok: true,
        action: completedRequest.action,
        generation: completedRequest.generation,
        inventoryAuthoritative: false,
        operation: {
          pluginId: completedRequest.pluginId,
          status: "completed",
          observed: false,
          message: "The command timed out; checking the resulting plugin state."
        },
        error: ""
      }) : ({
        ok: false,
        action: completedRequest.action,
        generation: completedRequest.generation,
        error: root.pluginError(completedRequest.pluginId)
      }))
    root.finishBatchItem(batchResult)
    } else if (root.mutationQueue.length) {
      Qt.callLater(function() { root.dispatchMutation() })
    } else {
      Qt.callLater(function() { root.reconcileAfterMutations() })
    }
    root.mutationResponse = null
    root.scheduleSleep()
  }

  function validRepoUrl(value) {
    return /^https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+(?:\/tree\/[0-9a-f]{40})?$/.test(String(value || ""))
  }

  function openSource(row) {
    if (!row) return
    var target = String(row.snapshotUrl || row.repo || "")
    if (validRepoUrl(target)) Qt.openUrlExternally(target)
  }

  function openMarketplace(row) {
    if (!row) return
    var target = String(row.marketplaceUrl || "")
    if (/^https:\/\/plugins\.omarchy\.org\/plugin\.html\?id=[A-Za-z0-9._~%-]+$/.test(target))
      Qt.openUrlExternally(target)
  }

  Timer {
    id: batchAdvance
    objectName: "batchAdvance"
    interval: 600
    onTriggered: root.dispatchNextBatchItem()
  }

  Timer {
    id: operationReconcile
    interval: 500
    onTriggered: {
      if (!root.hasCheckingOperations()) return
      if (!root.verifyMutationState()) root.scheduleOperationReconcile()
    }
  }

  FileView {
    id: batchJournal
    objectName: "batchJournal"
    path: root.batchJournalPath
    atomicWrites: true
    watchChanges: false
    printErrors: false
    onLoaded: root.restoreBatchJournal(text())
    onLoadFailed: root.batchJournalLoaded = true
  }

  Timer {
    id: journalPermissionDelay
    interval: 100
    onTriggered: if (!journalPermissions.running) journalPermissions.running = true
  }

  Process {
    id: journalPermissions
    command: ["/usr/bin/chmod", "600", root.batchJournalPath]
  }

  Timer {
    id: hardwareWatcher
    interval: 60000
    repeat: true
    running: root.editorOpen && !root.sleeping && root.hasAnalyzed && root.preferences.watchHardware !== false
    onTriggered: root.rescan(true)
  }

  Timer {
    id: editorRestoreTimer
    objectName: "editorRestoreTimer"
    interval: 100
    repeat: true
    onTriggered: root.coordinateEditorRestore()
  }

  Timer {
    id: queryLaunchDeadline
    objectName: "queryLaunchDeadline"
    interval: 2000
    onTriggered: {
      if (!root.queryLaunching || !root.requestActive) return
      root.queryLaunching = false
      root.processExitCode = -1
      root.streamFinished = true
      root.response = null
      root.error = "Outfit's local helper could not start. Retry the action."
      if (worker.running) worker.running = false
      if (worker.processId > 0) { root.timedOut = true; hardStop.restart() }
      else { root.processExited = true; root.finishRequestIfReady() }
    }
  }

  Timer {
    id: deadline
    interval: root.activeAction === "save-density" ? 5000 : 120000
    onTriggered: {
      root.timedOut = true
      if (["save-density", "context", "save-interests", "preview-interest", "matches", "review-matches"].indexOf(root.activeAction) < 0)
        root.error = "Outfit timed out while checking local data or marketplace metadata."
      if (worker.running) {
        worker.running = false
        hardStop.restart()
      }
    }
  }

  Timer {
    id: hardStop
    interval: 2000
    onTriggered: {
      if (worker.processId > 0) worker.signal(9)
      else if (root.queryStopping) {
        root.queryStopping = false
        if (root.editorOpen) root.resumeQueries()
      } else if (root.requestActive && root.timedOut) {
        root.processExited = true
        root.streamFinished = true
        root.finishRequestIfReady()
      }
    }
  }

  Timer {
    id: mutationLaunchDeadline
    interval: 2000
    onTriggered: {
      if (!root.mutationLaunching || !root.mutationActive) return
      root.mutationLaunching = false
      root.mutationProcessExitCode = -1
      root.mutationStreamFinished = true
      root.mutationResponse = null
      if (mutationWorker.running) mutationWorker.running = false
      if (mutationWorker.processId > 0) {
        root.mutationTimedOut = true
        root.failPluginMutation(root.activeMutation,"The plugin helper did not acknowledge startup; checking the result.")
        mutationHardStop.restart()
      } else { root.mutationProcessExited = true; root.finishMutationIfReady() }
    }
  }

  Timer {
    id: mutationDeadline
    interval: 240000
    onTriggered: {
      root.mutationTimedOut = true
      root.setPluginOperation(root.activeMutation.pluginId, {
        pending: true,
        status: "checking",
        message: "The command timed out; checking the resulting plugin state.",
        error: ""
      })
      if (mutationWorker.running) {
        mutationWorker.running = false
        mutationHardStop.restart()
      }
    }
  }

  Timer {
    id: mutationHardStop
    interval: 2000
    onTriggered: if (mutationWorker.processId > 0) mutationWorker.signal(9)
  }

  Timer {
    id: mutationEofGrace
    objectName: "mutationEofGrace"
    interval: 100
    onTriggered: {
      if (!root.mutationActive || !root.mutationProcessExited) return
      var owner = root.activeMutationGeneration
      mutationParser.flush()
      if (!root.mutationActive || root.activeMutationGeneration !== owner) return
      root.mutationStreamFinished = true
      root.finishMutationIfReady()
    }
  }

  Process {
    id: worker
    objectName: "queryWorker"
    command: ["/usr/bin/python3", "-I", "-B", root.helperPath, "--serve"]
    stdinEnabled: true

    onStarted: {
      if (root.queryStopping || root.timedOut || !root.requestActive) { running = false; hardStop.restart(); return }
      root.queryLaunching = false
      queryLaunchDeadline.stop()
      write(JSON.stringify(root.activeRequest) + "\n")
      deadline.restart()
    }

    stdout: BoundedJsonParser {
      id: queryParser
      objectName: "queryParser"
      accepting: root.requestActive && !root.queryStopping
      maxFrames: 128
      onFrame: function(line) { root.receiveOutput(line) }
      onFailed: function(message) { root.rejectQueryOutput(message) }
    }

    onExited: function(exitCode) {
      var stopping = root.queryStopping
      root.queryStopping = false
      root.queryLaunching = false
      queryLaunchDeadline.stop()
      hardStop.stop()
      root.processExitCode = exitCode
      root.processExited = true
      if (stopping) {
        if (root.editorOpen) Qt.callLater(function() { root.resumeQueries() })
      } else if (root.requestActive) {
        if (root.streamFinished || root.timedOut) { root.streamFinished = true; root.finishRequestIfReady() }
        else queryEofGrace.restart()
      }
    }
  }

  Process {
    id: mutationWorker
    objectName: "mutationWorker"
    command: ["/usr/bin/python3", "-I", "-B", root.helperPath]
    stdinEnabled: true

    onStarted: {
      if (!root.mutationActive || root.mutationTimedOut) { running = false; mutationHardStop.restart(); return }
      root.mutationLaunching = false
      mutationLaunchDeadline.stop()
      write(JSON.stringify(root.activeMutation) + "\n")
      stdinEnabled = false
      mutationDeadline.restart()
    }

    stdout: BoundedJsonParser {
      id: mutationParser
      objectName: "mutationParser"
      accepting: root.mutationActive && !root.mutationTimedOut
      maxFrameBytes: 4194304
      maxFrames: 256
      onFrame: function(line) { root.receiveMutationOutput(line) }
      onFailed: function(message) {
        if (!root.mutationActive) return
        root.mutationTimedOut = true
        root.failPluginMutation(root.activeMutation,message)
        mutationWorker.running = false
        mutationHardStop.restart()
      }
    }

    onExited: function(exitCode) {
      root.mutationLaunching = false
      mutationLaunchDeadline.stop()
      root.mutationProcessExitCode = exitCode
      root.mutationProcessExited = true
      stdinEnabled = true
      if (root.mutationStreamFinished || root.mutationTimedOut) {
        root.mutationStreamFinished = true
        root.finishMutationIfReady()
      } else mutationEofGrace.restart()
    }
  }

  onSetupSelectionChanged: {
    root.persistBatchJournal()
    if (root.pendingDiscovery || (root.requestActive && root.activeAction === "discover"))
      root.requestDiscovery()
  }
  onPreferencesChanged: {
    if (!root.densityTouched) root.browseDensity = Presentation.densityName(root.preferences.browseDensity)
    var key = JSON.stringify(root.preferences.services || [])
    if (key === root.discoveryServicesKey) return
    root.discoveryServicesKey = key
    root.discoverySerial++
    root.pendingDiscovery = null
    root.discoveryRows = []
    root.discoveryHistory = []
    root.discoveryHistoryIndex = -1
    if (root.editorOpen && root.workspaceView === "discover")
      Qt.callLater(function() {
        if (root.activeAction === "discover") root.requestDiscovery()
        else root.ensureDiscovery()
      })
  }
  property bool batchProgressOnly: false
  property string lastBatchJournalText: ""
  Timer { id: journalWriteDelay; objectName: "journalWriteDelay"; interval: 250; onTriggered: root.persistBatchJournal() }
  Timer {
    id: queryEofGrace
    objectName: "queryEofGrace"
    interval: 100
    onTriggered: {
      var owner = root.activeGeneration
      queryParser.flush()
      if (root.requestActive && root.activeGeneration === owner) { root.streamFinished = true; root.finishRequestIfReady() }
    }
  }
  onBatchItemsChanged: {
    if (root.batchProgressOnly) journalWriteDelay.restart()
    else root.persistBatchJournal()
  }
  onBatchKindChanged: root.persistBatchJournal()
  onBatchRunningChanged: {
    root.persistBatchJournal()
    if (!root.batchRunning) root.endBatchLifecycle()
    if (!root.batchRunning && root.editorRestorePayload)
      root.editorRestoreDeadline = Math.min(root.editorRestoreDeadline, Date.now() + 15000)
  }
  onBatchResumePayloadChanged: root.persistBatchJournal()

  Component.onCompleted: {
    batchJournal.reload()
    startupReceiptFile.reload()
    root.request("load", {})
    root.closedAt = Date.now()
    root.scheduleSleep()
  }

  IpcHandler {
    objectName: "serviceIpc"
    target: "io.github.ctl0v0.outfit"
    function status(): string {
      return JSON.stringify({ demo: Boolean(root.demoRoot), opened: root.editorOpen,
        sleeping:root.sleeping, queryWorkerRunning:worker.running || worker.processId > 0,
        optionalWorkers:[updatesWorker,catalogWorker,inventoryWorker,backgroundWorker,readmeIndexer,searchPreparationWorker].filter(function(job) { return job.active }).length,
        thumbnailWorkerActive:thumbnailLoader.active,
        ready: root.cacheLoaded && root.hasAnalyzed && !root.queryBusy && !root.backgroundBusy
          && !root.pendingEnrichment && !root.discoveryBusy && !root.mutationBusy
          && !root.hasCheckingOperations() && (!root.hostLifecycleSupported || root.hostRuntimeReady),
        view: root.workspaceView, discoveryCount: root.discoveryRows.length,
        queryBusy: root.queryBusy, backgroundBusy: root.backgroundBusy,
        canBrowse:root.canBrowse, canManagePlugins:root.canManagePlugins,
        catalogSource:root.catalogSource, catalogBuiltAt:root.catalogBuiltAt, sourceDate:root.sourceDate,
        catalogBusy:root.catalogBusy, inventoryBusy:root.inventoryBusy, preparingSearch:root.preparingSearch,
        searchPack:root.searchPack, startupActivity:root.startupActivity, libraryPrepared:root.libraryPrepared,
        searchPackFailed:root.searchPackFailed, searchPackRetryAt:root.searchPackRetryAt,
        indexingBusy: root.indexingBusy, readmeIndex: root.readmeIndex, documentCounts:root.documentCounts,
        filtersExpanded: root.filtersExpanded, browseDensity: root.browseDensity,
        selectedPlugin: root.setupDetailId,
        densitySavePending: root.densitySavePending, densitySaveError: root.densitySaveError,
        discoveryEnabled: root.discoveryEnabled,
        inputsLoaded: root.inputsLoaded, matchesLoaded: root.matchesLoaded,
        criteriaRevision: root.criteriaRevision, unreadMatches: root.unreadMatches,
        interestsDirty: root.interestsDirty, interestPreviewTotal: root.interestPreview ? root.interestPreview.total : null,
        panelRecovery: {state:root.editorRestoreState, armed:Boolean(root.editorRestorePayload),
          awaitingAcknowledgement:Boolean(root.editorRestoreToken),
          suppressed:root.editorRestoreSuppressed || root.batchCloseSuppressed},
        batchRunning: root.batchRunning, batchSelected: root.selectedSetupRows().length,
        batchItems: root.batchItems.map(function(item) { return {id:item.id, status:item.status} }),
        inventoryReady: root.inventoryReady, results: root.setupTotal,
        updatesLoaded:root.updatesLoaded, updatesBusy:root.updatesBusy, updatesCheckedAt:root.updatesCheckedAt,
        availableUpdates:root.availableUpdateCount, updatesError:root.updatesError,
        updatesUnavailableCount:root.updatesUnavailableCount, batchKind:root.batchKind,
        selfUpdateState:root.selfUpdateState.state, selfUpdateBusy:root.selfUpdateBusy,
        hostLifecycle: {support:root.hostLifecycleSupport, state:root.hostLifecycleState,
          runtimeReady:root.hostRuntimeReady, endConfirmed:root.hostLeaseEndConfirmed,
          error:root.hostLifecycleError, snapshot:root.hostLifecycleSnapshot, plugins:root.hostRuntimeResults} })
    }
  }
  Component.onDestruction: {
    root.pluginOpenRequest = null
    pluginOpenDeadline.stop()
    pluginOpenWorker.stop("Open worker shutting down.", true)
    root.hostLifecycleShuttingDown = true
    hostLifecycleTick.stop()
    hostLifecycleRequestDeadline.stop()
    // The host's short lease expiry covers process/service teardown, where an
    // asynchronous end cannot be awaited. Normal batch cleanup explicitly ends.
    hostLifecycleWorker.stop("Lifecycle worker shutting down.", true)
    hardwareWatcher.stop()
    batchAdvance.stop()
    operationReconcile.stop()
    journalPermissionDelay.stop()
    editorRestoreTimer.stop()
    deadline.stop()
    hardStop.stop()
    queryLaunchDeadline.stop()
    mutationDeadline.stop()
    mutationHardStop.stop()
    mutationLaunchDeadline.stop()
    mutationEofGrace.stop()
    if (worker.running) worker.running = false
    if (mutationWorker.running) mutationWorker.running = false
  }
}
