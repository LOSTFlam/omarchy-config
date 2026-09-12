// Service.qml
//
// Thin driver around the existing `om-custom-font` bash script. Owns:
//   - shelling out to the CLI for install / reset / revert / current
//   - caching the current font family for the overlay header
//   - persisting a single piece of state: the last directory the user
//     browsed to, so the picker opens where they left off
//
// No font logic lives here; the bash script remains the single source of
// truth and stays runnable standalone from a terminal.

import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  // Load-bearing: `omarchy plugin add` clones plugins into this path. If the
  // plugin loader ever changes that convention, this line breaks and the
  // overlay will report "exit 127" — no other layer of the stack tells us
  // where we live.
  readonly property string pluginDir: home + "/.config/omarchy/plugins/io.github.whiskeytuesday.custom-font"
  readonly property string cli: pluginDir + "/om-custom-font"

  readonly property string configDir: home + "/.config/omarchy"
  readonly property string lastDirFile: configDir + "/custom-font-last-dir"
  readonly property string defaultStartDir: home

  // Current-state cache, refreshed after every mutation and on demand.
  // Populated from `om-custom-font current --json`.
  property var currentFont: ({
    family: "",     // resolved monospace family
    stale: false,   // Omarchy 3 fontconfig override still present
    override: "",   // fontconfig user-override family, or "" if none
    gnomeFont: "",
    gnomeMono: ""
  })

  // Persisted last-used directory for the inline picker.
  property string lastDir: defaultStartDir

  property bool busy: false
  property string lastError: ""

  signal applied()
  signal reset()
  signal errored(string message)

  // ---- public API ----

  function installAndSet(path, gnomeScope) {
    var args = [root.cli, "set", path]
    if (gnomeScope === "font") args.push("--gnome-font")
    else if (gnomeScope === "mono") args.push("--gnome-mono")
    else if (gnomeScope === "both") args.push("--gnome")
    _run(args, "applied")
  }

  function installOnly(path)  { _run([root.cli, "add", path], "applied") }
  function resetAll()         { _run([root.cli, "reset-all"], "reset") }

  function refresh() {
    currentProc.running = false
    currentProc.running = true
  }

  // Called by the overlay when the user navigates into a directory. Written
  // as plain text (one line), not JSON — one key, no reason to parse.
  function rememberDir(dir) {
    if (!dir || dir === root.lastDir) return
    root.lastDir = dir
    lastDirWriteProc.command = ["/usr/bin/bash", "-c",
      "mkdir -p \"$1\" && printf '%s' \"$2\" > \"$3\"",
      "bash", root.configDir, dir, root.lastDirFile]
    lastDirWriteProc.running = false
    lastDirWriteProc.running = true
  }

  // ---- init ----

  Component.onCompleted: {
    lastDirReadProc.running = true
    refresh()
  }

  // ---- processes ----

  Process {
    id: workProc
    property string doneSignal: ""
    running: false
    onExited: function(code, status) {
      root.busy = false
      if (code === 0) {
        if (doneSignal === "applied") root.applied()
        else if (doneSignal === "reset") root.reset()
        root.refresh()
      } else {
        root.lastError = workErr.text || ("exit " + code)
        root.errored(root.lastError)
      }
    }
    stdout: StdioCollector { id: workOut }
    stderr: StdioCollector { id: workErr }
  }

  Process {
    id: currentProc
    command: [root.cli, "current", "--json"]
    running: false
    stdout: StdioCollector {
      id: currentOut
      onStreamFinished: root._parseCurrent(currentOut.text)
    }
    stderr: StdioCollector { }
  }

  Process {
    id: lastDirReadProc
    command: ["/usr/bin/cat", root.lastDirFile]
    running: false
    stdout: StdioCollector {
      id: lastDirOut
      onStreamFinished: {
        var t = String(lastDirOut.text || "").trim()
        if (t.length > 0) root.lastDir = t
      }
    }
    stderr: StdioCollector { }  // absent file → empty stderr matters not
  }

  Process {
    id: lastDirWriteProc
    running: false
    stdout: StdioCollector { }
    stderr: StdioCollector { }
  }

  // ---- helpers ----

  function _run(argv, doneSignal) {
    if (root.busy) return
    root.busy = true
    root.lastError = ""
    workProc.doneSignal = doneSignal
    workProc.command = argv
    workProc.running = true
  }

  // Parse the JSON emitted by `om-custom-font current --json`. Empty on any
  // failure — the overlay treats an empty family as "loading".
  function _parseCurrent(text) {
    var next = { family: "", stale: false, override: "", gnomeFont: "", gnomeMono: "" }
    try {
      var j = JSON.parse(String(text || ""))
      next.family = j.resolved || ""
      next.stale = j.override_stale === true
      next.override = j.override || ""
      if (j.gnome) {
        next.gnomeFont = j.gnome.font_name || ""
        next.gnomeMono = j.gnome.monospace_font_name || ""
      }
    } catch (e) {
      root.lastError = "Failed to parse `current --json`: " + e
    }
    root.currentFont = next
  }
}
