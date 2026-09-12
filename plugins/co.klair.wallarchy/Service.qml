import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Headless rotation timer.
//
// It owns no UI and no state the other surfaces need to ask it for: the
// config file is the input, the CLI is the output, and the rotation stamp it
// writes is what the bar widget reads to show a countdown. That keeps the
// three plugin surfaces decoupled — the shell injects `settings` into bar
// widgets only, so a service that depended on injected config would have no
// way to see it.
Item {
  id: root

  // Injected by omarchy-shell's service loader.
  property var shell: null
  property var manifest: null

  readonly property string cliPath: Qt.resolvedUrl("wallarchy").toString().replace(/^file:\/\//, "")
  readonly property string statePath: Quickshell.env("HOME") + "/.local/state/wallarchy/rotation.json"

  property int rotateMinutes: 0
  property double lastRotatedMs: 0
  property bool configLoaded: false
  property bool stateLoaded: false

  readonly property double intervalMs: rotateMinutes > 0 ? rotateMinutes * 60000 : 0
  readonly property double dueAtMs: lastRotatedMs > 0 && intervalMs > 0
    ? lastRotatedMs + intervalMs
    : 0

  function applyConfig(raw) {
    var config = Model.parseJson(raw, {}, 65536)
    var minutes = Number(config.rotateMinutes)
    rotateMinutes = isFinite(minutes) && minutes > 0 ? Math.round(minutes) : 0
    configLoaded = true
    reschedule()
  }

  function applyState(raw) {
    var state = Model.parseJson(raw, {}, 65536)
    var stamp = Number(state.lastRotatedMs)
    lastRotatedMs = isFinite(stamp) && stamp > 0 ? stamp : 0
    stateLoaded = true
    reschedule()
  }

  // A single timer that is always re-armed to the *remaining* time rather than
  // a fresh full interval. Without this, restarting the shell (or saving a
  // plugin file, which hot-reloads it) would silently postpone every rotation.
  function reschedule() {
    if (!configLoaded || !stateLoaded) return

    if (intervalMs <= 0) {
      rotateTimer.stop()
      return
    }

    var now = Date.now()
    if (lastRotatedMs <= 0 || lastRotatedMs > now) {
      // No stamp yet, or a clock that moved backwards: start the clock now
      // instead of firing immediately and surprising the user.
      stamp(now)
      return
    }

    var remaining = dueAtMs - now
    if (remaining <= 0) {
      rotate()
      return
    }

    rotateTimer.stop()
    // QML's int interval tops out around 24 days; clamp so a long interval
    // wraps into a negative value instead of never firing.
    rotateTimer.interval = Math.min(remaining, 2073600000)
    rotateTimer.start()
  }

  function rotate() {
    if (rotateProcess.running) return
    rotateProcess.command = [root.cliPath, "next"]
    rotateProcess.running = true
  }

  function stamp(whenMs) {
    stampProcess.command = ["sh", "-c",
      'mkdir -p "$(dirname "$1")" && printf \'{"lastRotatedMs": %s}\\n\' "$2" > "$1"',
      "sh", root.statePath, String(Math.round(whenMs))]
    stampProcess.running = true
  }

  FileView {
    path: Quickshell.env("HOME") + "/.config/omarchy/wallarchy.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.applyConfig(text())
    onFileChanged: reload()
    // A missing config file is the fresh-install state, not an error: fall
    // back to rotation-off so the service settles instead of retrying.
    onLoadFailed: root.applyConfig("{}")
  }

  FileView {
    path: root.statePath
    watchChanges: true
    printErrors: false
    onLoaded: root.applyState(text())
    onFileChanged: reload()
    onLoadFailed: root.applyState("{}")
  }

  Timer {
    id: rotateTimer
    repeat: false
    onTriggered: root.rotate()
  }

  Process {
    id: rotateProcess
    command: []
    stdout: StdioCollector { waitForEnd: true }
    // Stamp on both success and failure. A rate-limited or offline run should
    // wait out the next full interval, not retry in a tight loop.
    onExited: root.stamp(Date.now())
  }

  Process {
    id: stampProcess
    command: []
  }
}
