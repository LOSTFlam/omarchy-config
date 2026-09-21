import QtQuick
QtObject {
  property string path: ""
  property bool atomicWrites: false
  property bool watchChanges: false
  property bool printErrors: false
  property string contents: ""
  signal loaded()
  signal loadFailed()
  function reload() { loadFailed() }
  function text() { return contents }
  function setText(value) { contents = value }
}
