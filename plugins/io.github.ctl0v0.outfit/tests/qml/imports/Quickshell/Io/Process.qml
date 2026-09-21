import QtQuick
Item {
  property var command: []
  property bool running: false
  property bool stdinEnabled: false
  property QtObject stdout: null
  property string written: ""
  property int lastSignal: 0
  property int processId: 0
  signal started()
  signal exited(int exitCode, int exitStatus)
  function write(value) { written += value }
  function signal(number) { lastSignal = number }
}
