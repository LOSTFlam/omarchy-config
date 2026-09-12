import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import "Model.js" as Model

Item {
  id: root

  property var settings: ({})
  property var state: Model.defaultState("")
  property var themes: []
  property string appliedTheme: ""
  property var backgrounds: []
  property string backgroundsSlug: ""
  property bool loadingBackgrounds: false
  property int backgroundsRequestId: 0
  property bool loadingThemes: false
  property bool applyingTheme: false
  property bool applyQueued: false
  property string lastError: ""
  property bool stateLoaded: false

  readonly property string stateFilePath: Model.statePath(Quickshell.env("HOME"))
  readonly property string pluginDir: {
    var scriptUrl = Qt.resolvedUrl("catalog.sh")
    if (!scriptUrl)
      return Quickshell.env("HOME") + "/.config/omarchy/plugins/esemczak.theme-modes"
    var path = String(scriptUrl)
    if (path.indexOf("file://") === 0)
      path = path.substring(7)
    var slash = path.lastIndexOf("/")
    return slash >= 0 ? path.substring(0, slash) : path
  }
  readonly property bool onBattery: UPower.onBattery === true
  readonly property string activeThemeSlug: Model.themeForMode(state)
  readonly property string statusText: Model.statusLabel(state, onBattery)

  function saveState(nextState) {
    state = nextState
    scheduleStateSave()
  }

  function patchState(patch) {
    saveState(Object.assign({}, state, patch || {}))
  }

  function setLightTheme(slug) {
    var key = Model.slugFromName(slug)
    if (!Model.isValidSlug(key)) return
    var next = Object.assign({}, state, { lightTheme: key })
    if (Model.slugFromName(state.lightTheme) !== key)
      next.lightBackground = ""
    saveState(next)
    loadBackgroundsForSlug(key)
    if (next.mode === "light") applyCurrentMode(false)
  }

  function setDarkTheme(slug) {
    var key = Model.slugFromName(slug)
    if (!Model.isValidSlug(key)) return
    var next = Object.assign({}, state, { darkTheme: key })
    if (Model.slugFromName(state.darkTheme) !== key)
      next.darkBackground = ""
    saveState(next)
    loadBackgroundsForSlug(key)
    if (next.mode === "dark") applyCurrentMode(false)
  }

  function setLightBackground(path) {
    var nextPath = String(path || "")
    if (nextPath && !Model.backgroundInList(nextPath, backgrounds)) return
    patchState({ lightBackground: nextPath })
    if (state.mode === "light") applyBackground(nextPath)
  }

  function setDarkBackground(path) {
    var nextPath = String(path || "")
    if (nextPath && !Model.backgroundInList(nextPath, backgrounds)) return
    patchState({ darkBackground: nextPath })
    if (state.mode === "dark") applyBackground(nextPath)
  }

  function loadBackgroundsForSlug(slug) {
    var key = Model.slugFromName(slug)
    if (!Model.isValidSlug(key)) {
      backgrounds = []
      backgroundsSlug = ""
      loadingBackgrounds = false
      return
    }
    if (backgroundsProcess.running)
      backgroundsProcess.running = false
    backgroundsRequestId++
    var requestId = backgroundsRequestId
    backgroundsSlug = key
    loadingBackgrounds = true
    backgroundsTimeout.restart()
    backgroundsProcess.command = ["timeout", "20s", "bash", root.pluginDir + "/backgrounds.sh", key]
    backgroundsProcess.running = true
    backgroundsProcess.requestId = requestId
  }

  function validateSavedBackground(mode, items) {
    var key = mode === "light" ? "lightBackground" : "darkBackground"
    var current = String(state[key] || "")
    if (!current || Model.backgroundInList(current, items)) return
    var patch = {}
    patch[key] = ""
    patchState(patch)
  }

  function setModeManual(mode) {
    var nextMode = mode === "light" ? "light" : "dark"
    patchState({ mode: nextMode, manualOverride: true })
    applyCurrentMode(true)
  }

  function toggleModeManual() {
    setModeManual(state.mode === "light" ? "dark" : "light")
  }

  function followAutomatic() {
    enableAutomaticSwitching()
  }

  function enableAutomaticSwitching() {
    patchState({ manualOverride: false, autoEnabled: true })
    evaluateAutomatic(true)
  }

  function enableManualSwitching() {
    patchState({ manualOverride: true })
  }

  function setAutoEnabled(enabled) {
    patchState({ autoEnabled: !!enabled })
    if (!state.manualOverride) evaluateAutomatic(true)
  }

  function setAutoSource(source) {
    patchState({ autoSource: source === "battery" ? "battery" : "time" })
    if (!state.manualOverride && state.autoEnabled) evaluateAutomatic(true)
  }

  function setLightStart(value) {
    patchState({ lightStart: Model.normalizeTime(value, state.lightStart) })
    if (!state.manualOverride && state.autoEnabled && state.autoSource === "time") evaluateAutomatic(true)
  }

  function setDarkStart(value) {
    patchState({ darkStart: Model.normalizeTime(value, state.darkStart) })
    if (!state.manualOverride && state.autoEnabled && state.autoSource === "time") evaluateAutomatic(true)
  }

  function refreshThemes() {
    if (catalogProcess.running) return
    loadingThemes = true
    catalogTimeout.restart()
    catalogProcess.running = true
  }

  function evaluateAutomatic(forceApply) {
    if (state.manualOverride || !state.autoEnabled) return
    var desired = Model.computeAutoMode(state, onBattery, new Date())
    if (desired === state.mode && !forceApply) return
    patchState({ mode: desired })
    applyCurrentMode(true)
  }

  function applyCurrentMode(fromAuto) {
    var slug = Model.themeForMode(state)
    if (!Model.isValidSlug(slug)) return
    if (applyProcess.running) {
      applyQueued = true
      return
    }
    applyingTheme = true
    lastError = ""
    var background = Model.backgroundForMode(state)
    if (background && root.backgroundsSlug === slug && !Model.backgroundInList(background, backgrounds))
      background = ""
    var cmd = "omarchy theme set " + shellQuote(slug)
    if (background) cmd += " && omarchy theme bg set " + shellQuote(background)
    applyProcess.command = ["bash", "-lc", cmd]
    applyProcess.running = true
  }

  function applyBackground(path) {
    var target = String(path || "")
    if (!target || !Model.backgroundInList(target, backgrounds) || backgroundProcess.running) return
    lastError = ""
    backgroundProcess.command = ["bash", "-lc", "omarchy theme bg set " + shellQuote(target)]
    backgroundProcess.running = true
  }

  function shellQuote(value) {
    return "'" + String(value || "").replace(/'/g, "'\\''") + "'"
  }

  function stdoutOverLimit(text, limit) {
    return String(text || "").length > limit
  }

  function abortIfStdoutOverLimit(process, collector, limit, onAbort) {
    if (!process.running) return false
    if (!stdoutOverLimit(collector.text, limit)) return false
    process.running = false
    if (onAbort) onAbort()
    return true
  }

  function loadState(raw, currentThemeSlug) {
    state = Model.parseStateFile(raw, currentThemeSlug)
    stateLoaded = true
    evaluateAutomatic(false)
  }

  function reloadState() {
    if (stateLoader.running) return
    stateLoader.running = true
  }

  function flushState() {
    if (!stateLoaded || stateWriter.running) return
    var payload = Model.serializeState(state)
    stateWriter.command = ["bash", "-lc", "printf '%s' " + shellQuote(payload) + " | " + shellQuote(root.pluginDir + "/safe-write-state.sh")]
    stateWriter.running = true
  }

  function scheduleStateSave() {
    if (!stateLoaded) return
    stateSaveTimer.restart()
  }

  Timer {
    id: stateSaveTimer
    interval: 200
    repeat: false
    onTriggered: root.flushState()
  }

  Timer {
    id: catalogTimeout
    interval: 25000
    repeat: false
    onTriggered: {
      if (catalogProcess.running) {
        catalogProcess.running = false
        root.loadingThemes = false
      }
    }
  }

  Timer {
    id: themeListFallbackTimeout
    interval: 25000
    repeat: false
    onTriggered: {
      if (themeListFallbackProcess.running)
        themeListFallbackProcess.running = false
    }
  }

  Timer {
    id: backgroundsTimeout
    interval: 25000
    repeat: false
    onTriggered: {
      if (backgroundsProcess.running) {
        backgroundsProcess.running = false
        root.backgrounds = []
        root.loadingBackgrounds = false
      }
    }
  }

  Process {
    id: stateLoader
    command: ["bash", root.pluginDir + "/bootstrap-state.sh"]
    stdout: StdioCollector {
      id: stateLoaderStdout
      waitForEnd: true
      onDataChanged: root.abortIfStdoutOverLimit(stateLoader, stateLoaderStdout, Model.MAX_STATE_CHARS + 512, function() {
        if (!root.stateLoaded) root.loadState("", "")
      })
      onStreamFinished: {
        if (root.stdoutOverLimit(stateLoaderStdout.text, Model.MAX_STATE_CHARS + 512)) return
        var payload = Model.parseBootstrapPayload(stateLoaderStdout.text)
        root.loadState(payload.state, payload.currentTheme)
      }
    }
    onExited: function(code) {
      if (code !== 0 && !root.stateLoaded)
        root.loadState("", "")
    }
  }

  Process {
    id: stateWriter
    onExited: function(code) {
      if (code !== 0)
        root.lastError = "Failed to save settings"
    }
  }

  Process {
    id: catalogProcess
    command: ["timeout", "25s", "bash", root.pluginDir + "/catalog.sh"]
    stdout: StdioCollector {
      id: catalogStdout
      waitForEnd: true
      onDataChanged: root.abortIfStdoutOverLimit(catalogProcess, catalogStdout, Model.MAX_CATALOG_OUTPUT_CHARS, function() {
        catalogTimeout.stop()
        root.loadingThemes = false
        root.lastError = "Theme catalog output too large"
      })
      onStreamFinished: {
        if (root.stdoutOverLimit(catalogStdout.text, Model.MAX_CATALOG_OUTPUT_CHARS)) return
        catalogTimeout.stop()
        var parsed = Model.parseThemeCatalog(catalogStdout.text)
        if (parsed.length > 0) {
          root.themes = parsed
        } else {
          themeListFallbackTimeout.restart()
          themeListFallbackProcess.running = true
        }
        root.loadingThemes = false
      }
    }
    onExited: function(code) {
      catalogTimeout.stop()
      if (code !== 0) {
        themeListFallbackTimeout.restart()
        themeListFallbackProcess.running = true
        root.loadingThemes = false
      }
    }
  }

  Process {
    id: themeListFallbackProcess
    command: ["timeout", "25s", "bash", root.pluginDir + "/theme-list-fallback.sh"]
    stdout: StdioCollector {
      id: themeListFallbackStdout
      waitForEnd: true
      onDataChanged: root.abortIfStdoutOverLimit(themeListFallbackProcess, themeListFallbackStdout, Model.MAX_CATALOG_OUTPUT_CHARS, function() {
        themeListFallbackTimeout.stop()
        root.lastError = "Theme list output too large"
      })
      onStreamFinished: {
        if (root.stdoutOverLimit(themeListFallbackStdout.text, Model.MAX_CATALOG_OUTPUT_CHARS)) return
        themeListFallbackTimeout.stop()
        var parsed = Model.parseThemeCatalog(themeListFallbackStdout.text)
        if (parsed.length > 0) root.themes = parsed
      }
    }
    onExited: function() {
      themeListFallbackTimeout.stop()
    }
  }

  Process {
    id: backgroundsProcess
    property int requestId: 0
    stdout: StdioCollector {
      id: backgroundsStdout
      waitForEnd: true
      onDataChanged: root.abortIfStdoutOverLimit(backgroundsProcess, backgroundsStdout, Model.MAX_BACKGROUND_OUTPUT_CHARS, function() {
        backgroundsTimeout.stop()
        root.backgrounds = []
        root.loadingBackgrounds = false
        root.lastError = "Background catalog output too large"
      })
      onStreamFinished: {
        if (root.stdoutOverLimit(backgroundsStdout.text, Model.MAX_BACKGROUND_OUTPUT_CHARS)) return
        backgroundsTimeout.stop()
        if (backgroundsProcess.requestId !== root.backgroundsRequestId) return
        var slug = root.backgroundsSlug
        var items = Model.parseBackgroundCatalog(backgroundsStdout.text)
        root.backgrounds = items
        root.loadingBackgrounds = false
        if (slug === Model.slugFromName(root.state.lightTheme))
          root.validateSavedBackground("light", items)
        if (slug === Model.slugFromName(root.state.darkTheme))
          root.validateSavedBackground("dark", items)
      }
    }
    onExited: function(code) {
      backgroundsTimeout.stop()
      if (code !== 0) {
        root.backgrounds = []
        root.loadingBackgrounds = false
      }
    }
  }

  Process {
    id: backgroundProcess
    onExited: function(code) {
      if (code !== 0) root.lastError = "Failed to apply background"
    }
  }

  Process {
    id: applyProcess
    onExited: function(code) {
      root.applyingTheme = false
      if (code !== 0) {
        root.lastError = "Failed to apply theme"
        root.applyQueued = false
        return
      }
      root.appliedTheme = Model.themeForMode(root.state)
      root.lastError = ""
      if (root.applyQueued) {
        root.applyQueued = false
        root.applyCurrentMode(false)
      }
    }
  }

  Timer {
    interval: 30000
    running: root.stateLoaded && root.state.autoEnabled && !root.state.manualOverride
    repeat: true
    triggeredOnStart: true
    onTriggered: root.evaluateAutomatic(false)
  }

  Connections {
    target: UPower
    function onOnBatteryChanged() {
      if (!root.stateLoaded) return
      if (!root.state.manualOverride && root.state.autoEnabled && root.state.autoSource === "battery")
        root.evaluateAutomatic(false)
    }
  }

  Component.onCompleted: {
    reloadState()
    refreshThemes()
  }
}
