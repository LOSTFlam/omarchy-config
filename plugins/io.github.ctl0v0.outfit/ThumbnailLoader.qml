import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root
  visible: false
  property string helperPath: ""
  property string revision: ""
  property var rows: []
  property var images: ({})
  // Keep numeric due dates public for existing callers.
  property var attempts: ({})
  property var retryState: ({})
  property int attemptSequence: 0
  property bool readmeFallbackEnabled: false
  property int generation: 0
  property int activeGeneration: 0
  property var activeRows: []
  property bool active: false
  property bool cancelled: false
  property bool received: false
  property bool exited: false
  property bool started: false
  property bool ready: false
  property bool suspended: false
  property string failure: ""
  property int exitCode: 0
  property var response: null
  property int outputBytes: 0
  property int outputLines: 0
  readonly property int maxLineBytes: 131072
  readonly property int maxOutputBytes: 262144
  readonly property int maxOutputLines: 32
  readonly property string identity: JSON.stringify([enabled, revision, readmeFallbackEnabled, helperPath])
  readonly property string demandIdentity: JSON.stringify(rows.map(function(row) { return [row.id, root.rowKey(row)] }))

  function rowKey(row) {
    return JSON.stringify([String(row.previewThumbnail || row.previewImage || ""),
      String(row.repo || ""), String(row.listingCommit || "")])
  }
  function bounded(map) {
    var keys = Object.keys(map)
    for (var i = 0; i < keys.length - 128; i++) delete map[keys[i]]
    return map
  }
  function relevant(requested) {
    return rows.some(function(row) { return row.id === requested.id && root.rowKey(row) === requested.cacheKey })
  }
  function cachedFor(row) {
    var image = images[row.id]
    return image && image.cacheKey === rowKey(row) && image.revision === revision ? image : null
  }
  function needsWork(row) {
    var url = String(row.previewThumbnail || row.previewImage || "")
    if (!url && !(readmeFallbackEnabled && /^https:\/\/github\.com\//.test(String(row.repo || ""))
        && /^[0-9a-f]{40}$/.test(String(row.listingCommit || "")))) return false
    var cached = cachedFor(row)
    if (cached && cached.state === "broken") return false
    // A recovered README image remains visible, but the marketplace asset is
    // periodically retried so a repaired asset can replace it.
    return !cached || !cached.localSource || (url && cached.source === "readme")
  }
  function retryFor(row) {
    var retry = retryState[row.id]
    return retry && retry.cacheKey === rowKey(row) && retry.revision === revision ? retry : null
  }

  onIdentityChanged: {
    if (!ready) return
    clear()
    suspended = false
    scheduleNext()
  }
  onDemandIdentityChanged: {
    if (!ready) return
    suspended = false
    // Invalidate changed sources synchronously, before a view can reuse them.
    // Off-viewport entries survive scrolling/reordering in the bounded cache.
    var nextImages = Object.assign({}, images)
    var nextAttempts = Object.assign({}, attempts)
    var nextRetry = Object.assign({}, retryState)
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      if (!cachedFor(row)) delete nextImages[row.id]
      if (!retryFor(row)) { delete nextAttempts[row.id]; delete nextRetry[row.id] }
    }
    images = bounded(nextImages)
    attempts = bounded(nextAttempts)
    retryState = bounded(nextRetry)
    if (active && !activeRows.some(function(row) { return root.relevant(row) })) stop("Demand changed", true)
    scheduleNext()
  }

  // Sleeping callers can clear even before disabling: completion cannot rearm
  // demand until the next viewport or hard-identity change.
  function clear() {
    suspended = true
    generation++
    schedule.stop()
    images = ({})
    attempts = ({})
    retryState = ({})
    attemptSequence = 0
    stop("Cleared", true)
  }
  function invalidateImage(id, source) {
    var image = images[id]
    if (!image || !source || image.localSource !== String(source) || image.revision !== revision) return false
    var next = Object.assign({}, images)
    next[id] = Object.assign({}, image, {localSource:"", state:"broken", brokenSource:String(source)})
    images = bounded(next)
    var due = Object.assign({}, attempts)
    delete due[id]
    attempts = due
    // Do not repeatedly download/present a URI that Qt cannot decode. A new
    // row identity, revision or clear() permits it again.
    if (active && !activeRows.some(function(row) {
      return root.relevant(row) && (!root.images[row.id] || root.images[row.id].state !== "broken")
    })) stop("Image rejected", true)
    scheduleNext()
    return true
  }

  function scheduleNext() {
    schedule.stop()
    if (!ready || !enabled || suspended || active || !helperPath || !rows.length) return
    var now = Date.now()
    var due = Infinity
    for (var i = 0; i < rows.length; i++) {
      if (!needsWork(rows[i])) continue
      var retry = retryFor(rows[i])
      due = Math.min(due, retry ? Number(attempts[rows[i].id] || 0) : 0)
    }
    if (due === Infinity) return
    schedule.interval = due > now ? Math.min(2147483647, Math.ceil(due - now)) : 180
    schedule.start()
  }
  function startNext() {
    schedule.stop()
    if (!enabled || suspended || active || worker.processId > 0 || !helperPath) return
    var candidates = []
    var now = Date.now()
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      if (!needsWork(row)) continue
      var retry = retryFor(row)
      if (retry && Number(attempts[row.id] || 0) > now) continue
      candidates.push({ id:row.id, url:String(row.previewThumbnail || row.previewImage || ""),
        cacheKey:rowKey(row), repo:String(row.repo || ""), listingCommit:String(row.listingCommit || ""),
        order:retry ? retry.order : 0, index:i })
    }
    // Unattempted rows first, then least recently attempted. Even immediately
    // eligible deferred work cannot monopolize the first twelve slots.
    candidates.sort(function(a, b) { return a.order - b.order || a.index - b.index })
    if (!candidates.length) { scheduleNext(); return }
    activeRows = candidates.slice(0, 12)
    activeGeneration = ++generation
    cancelled = false
    received = false
    exited = false
    started = false
    failure = ""
    response = null
    exitCode = 0
    outputBytes = 0
    outputParser.reset()
    outputLines = 0
    active = true
    worker.stdinEnabled = true
    launchDeadline.restart()
    worker.running = true
  }

  // The chunk parser bounds partial frames before line delivery. These checks
  // also protect callers supplying a completed frame directly.
  function acceptResponse(text) { receiveLine(text) }
  function receiveLine(raw) {
    if (!active || cancelled || failure || activeGeneration !== generation) return
    var line = String(raw)
    var bytes = 0
    for (var i = 0; i < line.length && bytes <= maxLineBytes; i++) {
      var code = line.charCodeAt(i)
      if (code >= 0xd800 && code <= 0xdbff && i + 1 < line.length
          && line.charCodeAt(i + 1) >= 0xdc00 && line.charCodeAt(i + 1) <= 0xdfff) { bytes += 4; i++ }
      else bytes += code < 128 ? 1 : code < 2048 ? 2 : 3
    }
    outputBytes += bytes + 1
    outputLines++
    if (bytes > maxLineBytes || outputBytes > maxOutputBytes || outputLines > maxOutputLines) {
      stop("Thumbnail output exceeded its limit", false)
      return
    }
    if (!line.trim()) return
    var result
    try { result = JSON.parse(line) } catch (error) { stop("Malformed thumbnail response", false); return }
    if (!result || result.action !== "thumbnails" || result.generation !== activeGeneration
        || result.responseKind === "progress" || result.final === false || received) return
    received = true
    if (result.ok !== true || !result.thumbnails || typeof result.thumbnails !== "object") failure = "Invalid thumbnail response"
    else response = result.thumbnails
    finish()
  }

  function stop(reason, intentional) {
    if (!active) return
    cancelled = cancelled || intentional === true
    failure = failure || reason
    received = true
    deadline.stop()
    worker.running = false // termination request, NOT evidence of exit
    if (exited) { finish(); return }
    if (worker.processId > 0) {
      launchDeadline.stop()
      if (!killDeadline.running) killDeadline.start()
    } else if (!launchDeadline.running) launchDeadline.start()
  }
  function launchExpired() {
    if (!active || exited) return
    stop("Thumbnail helper failed to launch", false)
    // After the launch grace period, no PID and a withdrawn launch request
    // confirm failure. Never free the slot merely because running is false.
    if (worker.processId <= 0) { exited = true; finish() }
  }
  function escalate() {
    if (!active || exited) return
    if (worker.processId > 0) {
      worker.signal(9)
      killDeadline.restart()
    } else {
      // Quickshell clears processId when the child is gone. This also covers
      // a missed exit callback; a live PID always retains the slot.
      exited = true
      received = true
      finish()
    }
  }
  function finish() {
    if (!active || !exited || !received) return
    launchDeadline.stop()
    deadline.stop()
    killDeadline.stop()
    drainDeadline.stop()
    if (!cancelled && activeGeneration === generation && enabled && !suspended) {
      var nextImages = Object.assign({}, images)
      var nextAttempts = Object.assign({}, attempts)
      var nextRetry = Object.assign({}, retryState)
      for (var i = 0; i < activeRows.length; i++) {
        var requested = activeRows[i]
        if (!relevant(requested)) continue
        var image = !failure && exitCode === 0 && response ? response[requested.id] : null
        var valid = image && image.url === requested.url
          && (!image.localSource || (typeof image.localSource === "string" && /^file:\/\//.test(image.localSource)))
          && (!image.source || image.source === "marketplace" || image.source === "readme")
          && (requested.url || !image.localSource || image.source === "readme")
          && (image.source !== "readme" || (readmeFallbackEnabled
            && image.repo === requested.repo && image.listingCommit === requested.listingCommit))
        var state = valid ? String(image.state || (image.localSource ? "ready" : "missing")) : "failed"
        if (["ready", "missing", "failed", "deferred"].indexOf(state) < 0) { valid = false; state = "failed" }
        var previous = nextImages[requested.id]
        var local = valid ? String(image.localSource || "") : ""
        if (previous && previous.brokenSource && (!local || local === previous.brokenSource)) {
          delete nextAttempts[requested.id]
          continue
        }
        var value = {url:requested.url, localSource:local, revision:revision, cacheKey:requested.cacheKey,
          source:valid ? String(image.source || "marketplace") : "", state:state,
          repo:requested.repo, listingCommit:requested.listingCommit}
        // A failed repair probe must not blank a usable recovered image.
        if (!local && previous && previous.localSource) value = previous
        delete nextImages[requested.id]
        nextImages[requested.id] = value
        var old = retryState[requested.id]
        var count = old && old.cacheKey === requested.cacheKey ? Math.min(10, old.count + 1) : 1
        delete nextRetry[requested.id]
        nextRetry[requested.id] = {cacheKey:requested.cacheKey, revision:revision, count:count, order:++attemptSequence}
        delete nextAttempts[requested.id]
        if (!value.localSource || (requested.url && value.source === "readme")) {
          var base = state === "deferred" ? 1000 : state === "ready" || state === "missing" ? 60000 : 5000
          var cap = state === "deferred" ? 30000 : base === 60000 ? 300000 : 60000
          nextAttempts[requested.id] = Date.now() + Math.min(cap, base * Math.pow(2, count - 1))
        }
      }
      images = bounded(nextImages)
      attempts = bounded(nextAttempts)
      retryState = bounded(nextRetry)
    }
    active = false
    activeRows = []
    response = null
    scheduleNext()
    outputParser.reset()
  }

  Timer { id: schedule; objectName: "thumbnailSchedule"; onTriggered: root.startNext() }
  Timer { id: launchDeadline; objectName: "thumbnailLaunchDeadline"; interval: 2000; onTriggered: root.launchExpired() }
  Timer { id: deadline; objectName: "thumbnailDeadline"; interval: 45000; onTriggered: root.stop("Thumbnail helper timed out", false) }
  Timer { id: killDeadline; objectName: "thumbnailKillDeadline"; interval: 2000; onTriggered: root.escalate() }
  Timer {
    id: drainDeadline
    objectName: "thumbnailDrainDeadline"
    interval: 100
    onTriggered: {
      var owner = root.activeGeneration
      outputParser.flush()
      if (root.active && root.activeGeneration === owner) { root.received = true; root.finish() }
    }
  }
  Process {
    id: worker
    objectName: "thumbnailWorker"
    command: ["/usr/bin/python3", "-I", "-B", root.helperPath]
    stdinEnabled: true
    onStarted: {
      root.started = true
      launchDeadline.stop()
      if (!root.active) { running = false; if (processId > 0) signal(9); return }
      if (root.cancelled || root.failure) { root.stop("Cancelled before launch", root.cancelled); return }
      write(JSON.stringify({ action:"thumbnails", generation:root.activeGeneration,
        pluginIds:root.activeRows.map(function(row) { return row.id }) }) + "\n")
      stdinEnabled = false
      deadline.restart()
    }
    stdout: BoundedJsonParser {
      id: outputParser
      objectName: "thumbnailParser"
      accepting: root.active && !root.failure && !root.cancelled
      maxFrameBytes: root.maxLineBytes
      maxStreamBytes: root.maxOutputBytes
      maxFrames: root.maxOutputLines
      onFrame: function(line) { root.receiveLine(line) }
      onFailed: function(message) { root.stop(message, false) }
    }
    onExited: function(code) {
      if (!root.active || root.exited) return
      root.exitCode = code
      root.exited = true
      launchDeadline.stop()
      deadline.stop()
      killDeadline.stop()
      if (!root.received) drainDeadline.restart()
      root.finish()
    }
  }
  Component.onCompleted: { ready = true; scheduleNext() }
  Component.onDestruction: {
    worker.running = false
    if (worker.processId > 0) worker.signal(9)
  }
}
