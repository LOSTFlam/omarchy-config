import Quickshell.Io

// Empty splitMarker delivers chunks without native unbounded line buffering.
// Helpers emit ASCII-escaped JSON so chunk boundaries cannot split UTF-8 text.
SplitParser {
  id: parser
  splitMarker: ""
  property string pending: ""
  property int bytes: 0
  property int frames: 0
  property bool rejected: false
  property bool accepting: true
  onAcceptingChanged: if (!accepting) reset()
  property int maxFrameBytes: 8388608
  property int maxStreamBytes: 16777216
  property int maxFrames: 8192
  signal frame(string text)
  signal failed(string message)
  function reset() { pending = ""; bytes = 0; frames = 0; rejected = false }
  function reject(message) {
    if (rejected) return
    rejected = true
    pending = ""
    failed(message)
  }
  function deliver() {
    frames++
    if (frames > maxFrames) { reject("Helper output exceeded its frame limit."); return }
    var text = pending
    pending = ""
    frame(text)
  }
  function push(chunk) {
    if (rejected || !accepting) return
    var text = String(chunk || "")
    bytes += text.length
    if (bytes > maxStreamBytes) { reject("Helper output exceeded its size limit."); return }
    if (/[^\x00-\x7f]/.test(text)) { reject("Helper output was not ASCII-escaped JSON."); return }
    var parts = text.split("\n")
    for (var i = 0; i < parts.length && !rejected && accepting; i++) {
      if (pending.length + parts[i].length > maxFrameBytes) {
        reject("Helper output exceeded its line limit.")
        return
      }
      pending += parts[i]
      if (i < parts.length - 1) deliver()
    }
  }
  function flush() { if (!rejected && pending.length) deliver() }
  onRead: function(chunk) { push(chunk) }
}
