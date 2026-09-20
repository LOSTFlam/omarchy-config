import QtQuick
import Quickshell.Io

// One run of bin/fresh-tube at a time. It keeps what the command printed,
// reports once the process is gone, and stops a command that runs past its
// deadline so a stuck network call cannot leave the panel waiting.
Item {
  id: command

  property string program: ""
  property int timeoutMs: 30000
  property bool pending: false
  readonly property bool running: pending
  property bool queueLatest: false

  signal finished(int code, string out, string err)

  property string _out: ""
  property string _err: ""
  property int _code: 0
  property bool _exited: false
  property bool _outDone: false
  property bool _errDone: false
  property bool _timedOut: false
  property var _pending: null

  function start(args) {
    if (pending) {
      if (queueLatest) {
        _pending = args
        return true
      }
      return false
    }
    _out = ""
    _err = ""
    _code = 0
    _exited = false
    _outDone = false
    _errDone = false
    _timedOut = false
    pending = true
    proc.command = [program].concat(args)
    proc.running = true
    watchdog.restart()
    return true
  }

  function _finish() {
    if (!pending) return
    pending = false
    watchdog.stop()
    settle.stop()
    if (_timedOut) finished(1, _out, "fresh-tube: took too long and was stopped")
    else finished(_code, _out, _err)
    if (_pending !== null) {
      var next = _pending
      _pending = null
      start(next)
    }
  }

  function _maybeFinish() {
    if (_exited && _outDone && _errDone) _finish()
  }

  Process {
    id: proc

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        command._out = String(text || "")
        command._outDone = true
        command._maybeFinish()
      }
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        command._err = String(text || "")
        command._errDone = true
        command._maybeFinish()
      }
    }

    onExited: function(exitCode) {
      command._code = exitCode
      command._exited = true
      command._maybeFinish()
      // The streams close with the process; this only covers one that never says so.
      settle.restart()
    }
  }

  Timer {
    id: settle
    interval: 250
    onTriggered: command._finish()
  }

  Timer {
    id: watchdog
    interval: command.timeoutMs
    onTriggered: {
      command._timedOut = true
      proc.running = false
      settle.restart()
    }
  }
}
