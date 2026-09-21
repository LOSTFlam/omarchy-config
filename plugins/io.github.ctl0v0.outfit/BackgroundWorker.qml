import QtQuick
import Quickshell.Io

Item {
  id: root
  visible: false
  property string helperPath: ""
  property bool active: false
  property bool started: false
  property bool exited: false
  property bool received: false
  property int generation: 0
  property int exitCode: 0
  property var activeRequest: ({})
  property var response: null
  property string failure: ""
  property bool cancelled: false
  property bool lowPriority: false
  property int outputBytes: 0
  property int outputLines: 0
  property int progressSequence: 0
  readonly property int maxLineBytes: 4194304
  readonly property int maxOutputBytes: 16777216
  readonly property int maxOutputLines: 8192
  signal finished(var result, var request)
  signal progress(var event, var request)

  // One bounded JSON object per line; old helpers may still send just a final.
  function receiveLine(raw) {
    if (!active || failure) return
    var line = String(raw || "")
    var bytes = 0
    for (var i = 0; i < line.length; i++) {
      var code = line.charCodeAt(i)
      bytes += code < 128 ? 1 : code < 2048 ? 2 : 3
    }
    outputBytes += bytes
    outputLines++
    if (bytes > maxLineBytes || outputBytes > maxOutputBytes || outputLines > maxOutputLines) {
      stop("Background output exceeded its limit. Retry the action.")
      return
    }
    if (!line.trim()) return
    var event
    try { event = JSON.parse(line) } catch (error) {
      stop("The background helper returned unreadable data. Retry the action.")
      return
    }
    if (!event || event.action !== activeRequest.action
        || Number(event.generation) !== activeRequest.generation) return
    if (event.responseKind === "progress" || event.final === false) {
      if (received || event.responseKind !== "progress" || event.final !== false) return
      var sequence = Number(event.sequence)
      if (!isFinite(sequence) || sequence <= progressSequence || Math.floor(sequence) !== sequence) return
      progressSequence = sequence
      progress(event, activeRequest)
      return
    }
    if (received) return
    response = event
    received = true
    finish()
  }

  function submit(action, values) {
    if (active || !helperPath) return false
    generation++
    var request = JSON.parse(JSON.stringify(values || {}))
    request.action = action
    request.generation = generation
    activeRequest = request
    response = null
    failure = ""
    cancelled = false
    received = false
    exited = false
    started = false
    exitCode = 0
    outputBytes = 0
    outputLines = 0
    outputParser.reset()
    progressSequence = 0
    active = true
    worker.stdinEnabled = true
    launchDeadline.restart()
    worker.running = true
    return true
  }

  function stop(message, intentional) {
    if (!active) return
    failure = message || "Background work cancelled."
    cancelled = intentional === true
    launchDeadline.stop()
    deadline.stop()
    worker.running = false
    if (worker.processId > 0) killDeadline.restart()
    else { exited = true; received = true; finish() }
  }

  function finish() {
    if (!active || !exited || !received) return
    launchDeadline.stop()
    deadline.stop()
    killDeadline.stop()
    drain.stop()
    var request = activeRequest
    var result = response
    if (!result || failure || (exitCode !== 0 && result.ok === true) || Number(result.generation) !== request.generation
        || result.action !== request.action) result = {
      ok: false, action: request.action, generation: request.generation,
      error: failure || "Outfit's background helper returned an invalid response. Retry the action.",
      cancelled: root.cancelled
    }
    active = false
    activeRequest = ({})
    response = null
    finished(result, request)
    if (!active) outputParser.reset()
  }

  Timer {
    id: launchDeadline
    objectName: "backgroundLaunchDeadline"
    interval: 2000
    onTriggered: root.stop("Outfit's helper could not start. Check that Python 3 is installed, then retry.")
  }
  Timer {
    id: deadline
    objectName: "backgroundDeadline"
    interval: root.activeRequest.action === "prepare-search" ? 180000
      : ["enrich", "refresh", "index-readmes", "catalog-refresh", "check-updates", "self-update"].indexOf(root.activeRequest.action) >= 0 ? 90000 : 45000
    onTriggered: root.stop("Background work timed out. Cached results remain available; retry the action.")
  }
  Timer { id: killDeadline; interval: 2000; onTriggered: if (worker.processId > 0) worker.signal(9) }
  Timer {
    id: drain
    objectName: "backgroundDrain"
    interval: 100
    onTriggered: {
      var owner = root.generation
      outputParser.flush()
      // EOF can finish this request; its callback may already submit the next.
      if (root.active && root.generation === owner) { root.received = true; root.finish() }
    }
  }
  Process {
    id: worker
    objectName: "backgroundWorker"
    command: root.lowPriority ? ["/usr/bin/nice", "-n", "10", "/usr/bin/python3", "-I", "-B", root.helperPath]
      : ["/usr/bin/python3", "-I", "-B", root.helperPath]
    stdinEnabled: true
    onStarted: {
      if (!root.active || root.failure) { running = false; return }
      root.started = true
      launchDeadline.stop()
      write(JSON.stringify(root.activeRequest) + "\n")
      stdinEnabled = false
      deadline.restart()
    }
    stdout: BoundedJsonParser {
      id: outputParser
      objectName: "backgroundParser"
      accepting: root.active && !root.failure
      maxFrameBytes: root.maxLineBytes
      maxStreamBytes: root.maxOutputBytes
      maxFrames: root.maxOutputLines
      onFrame: function(line) { root.receiveLine(line) }
      onFailed: function(message) { root.stop(message) }
    }
    onExited: function(code) {
      root.exitCode = code
      root.exited = true
      if (!root.received) drain.restart()
      root.finish()
    }
  }
  Component.onDestruction: if (worker.processId > 0) worker.signal(9)
}
