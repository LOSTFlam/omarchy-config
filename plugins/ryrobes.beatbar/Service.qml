import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire

Item {
  id: root

  property var shell: null

  width: 0
  height: 0
  visible: false

  readonly property int bandCount: 24
  readonly property string configPath: decodeURIComponent(
    String(Qt.resolvedUrl("cava.conf")).replace("file://", ""))
  readonly property var defaultSink: Pipewire.defaultAudioSink

  property var bands: zeroBands()
  property real level: 0
  property real bass: 0
  property real bassAverage: 0
  property bool active: false
  property bool available: false
  property bool componentReady: false
  property bool expectedStop: false
  property bool cavaNoticePending: false
  property bool cavaNoticeShown: false
  property double lastBeatAt: 0
  property int beatCount: 0
  property string lastError: ""

  signal beat(real strength)

  function zeroBands() {
    var values = []
    for (var i = 0; i < bandCount; i++) values.push(0)
    return values
  }

  function clearSpectrum() {
    bands = zeroBands()
    level = 0
    bass = 0
    active = false
  }

  function normalized(value) {
    var raw = Math.max(0, Math.min(1000, Number(value) || 0)) / 1000
    return Math.pow(raw, 0.72)
  }

  function consumeFrame(line) {
    var fields = String(line || "").trim().split(";")
    var values = []
    for (var i = 0; i < fields.length; i++) {
      if (fields[i] !== "") values.push(normalized(fields[i]))
    }
    if (values.length !== bandCount) return

    var peak = 0
    for (var j = 0; j < values.length; j++) peak = Math.max(peak, values[j])

    // CAVA's stereo layout mirrors the channels with the lowest frequencies
    // toward the center, so the middle six bands form a useful beat envelope.
    var center = Math.floor(values.length / 2)
    var bassNow = 0
    for (var k = center - 3; k < center + 3; k++) bassNow += values[k]
    bassNow /= 6

    var previousAverage = bassAverage
    bassAverage = previousAverage <= 0
      ? bassNow
      : previousAverage * 0.94 + bassNow * 0.06

    var now = Date.now()
    var flux = bassNow - previousAverage
    var threshold = Math.max(0.045, previousAverage * 0.32)
    if (bassNow > 0.16 && flux > threshold && now - lastBeatAt > 180) {
      lastBeatAt = now
      beatCount += 1
      beat(Math.min(1, bassNow + flux))
    }

    bands = values
    level = peak
    bass = bassNow
    active = peak > 0.018
    silenceWatchdog.restart()
  }

  function restartAnalyzer() {
    if (!componentReady) return
    if (analyzer.running) {
      expectedStop = true
      analyzer.running = false
    }
    restartTimer.restart()
  }

  function cavaIsUnavailable(message, exitCode) {
    var detail = String(message || "").toLowerCase()
    return Number(exitCode) === 127
      && detail.indexOf("cava") !== -1
      && (detail.indexOf("no such file") !== -1
        || detail.indexOf("not found") !== -1)
  }

  function showCavaUnavailableNotice() {
    if (cavaNoticeShown) return
    cavaNoticePending = true
    if (!shell || typeof shell.summon !== "function") return

    cavaNoticePending = false
    cavaNoticeShown = true
    shell.summon("omarchy.osd", JSON.stringify({
      icon: "media",
      message: "Beatbar paused: CAVA is unavailable. See the plugin README.",
      duration: 6000
    }))
  }

  onDefaultSinkChanged: restartAnalyzer()
  onShellChanged: if (cavaNoticePending) showCavaUnavailableNotice()

  Component.onCompleted: {
    componentReady = true
    analyzer.running = true
  }

  Process {
    id: analyzer
    command: [
      "setpriv",
      "--pdeathsig",
      "TERM",
      "cava",
      "-p",
      root.configPath
    ]

    stdout: SplitParser {
      onRead: function(line) { root.consumeFrame(line) }
    }

    stderr: SplitParser {
      onRead: function(line) {
        var message = String(line || "").trim()
        if (message !== "") root.lastError = message
      }
    }

    onStarted: {
      root.available = true
      root.lastError = ""
    }

    onExited: function(exitCode) {
      root.available = false
      root.clearSpectrum()
      if (root.expectedStop) {
        root.expectedStop = false
      } else {
        if (!root.lastError) root.lastError = "cava exited with status " + exitCode
        if (root.cavaIsUnavailable(root.lastError, exitCode))
          root.showCavaUnavailableNotice()
      }
      if (root.componentReady) restartTimer.restart()
    }
  }

  Timer {
    id: restartTimer
    interval: 1800
    repeat: false
    onTriggered: if (root.componentReady && !analyzer.running) analyzer.running = true
  }

  Timer {
    id: silenceWatchdog
    interval: 650
    repeat: false
    onTriggered: root.clearSpectrum()
  }

  IpcHandler {
    target: "ryrobes.beatbar"

    function status(): string {
      return JSON.stringify({
        available: root.available,
        active: root.active,
        level: root.level,
        bass: root.bass,
        beatCount: root.beatCount,
        lastBeatAt: root.lastBeatAt,
        bands: root.bands,
        error: root.lastError
      })
    }

    function restart(): void {
      root.restartAnalyzer()
    }
  }
}
