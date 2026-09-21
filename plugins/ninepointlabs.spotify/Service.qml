import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// The plugin's data layer, instantiated once per shell as its `service`
// entry point. Every bar widget (one per monitor) and every open panel reads
// this one instance, so player polling, library fetches and searches never
// run more than once per shell. All Spotify traffic goes through
// bin/spotify-bridge, which prints one JSON object per call.
Item {
  id: root

  property var shell: null
  property var settings: ({})
  // A widget-local instance, built only under a shell without service
  // support, stays inert once a shared one exists.
  property bool active: true

  readonly property string pluginDir: decodeURIComponent(Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")).replace(/\/$/, "")
  readonly property string bridge: pluginDir + "/bin/spotify-bridge"

  // ---- Trust boundary. Nothing here starts a program through the session
  //      PATH or hands it the session environment. The bridge runs under an
  //      absolute Python found once at startup (`python3 -I`, never the
  //      script's own interpreter line) in a cleared environment; the few
  //      detached launches use absolute paths the bridge resolved from
  //      root-owned directories, re-checked in Model.js. See Model.js's
  //      "Trusted executables and closed environments".
  function sessionValues(names) {
    var values = {}
    for (var i = 0; i < names.length; i++) values[names[i]] = Quickshell.env(names[i])
    return values
  }
  readonly property var bridgeEnvironment: Model.closedEnvironment(sessionValues(Model.bridgeEnvironmentNames), Model.bridgeEnvironmentNames, Model.trustedPathEnvironment)
  readonly property var launchEnvironment: Model.closedEnvironment(sessionValues(Model.launchEnvironmentNames), Model.launchEnvironmentNames, Model.trustedSessionPathEnvironment, Model.launchFixedEnvironment)
  readonly property var pythonProbeEnvironment: Model.closedEnvironment({}, [], Model.trustedPathEnvironment)

  property string python: ""
  property string pythonError: ""
  property bool _pythonProbing: false
  property int _pythonAttempt: 0
  property int _pythonProbeWaits: 0
  property var _pythonProbeObject: null
  property int _pythonCandidate: 0
  property var _queuedCalls: []
  // Absolute launcher paths reported by `spotify-bridge status`.
  property var tools: ({})
  property string appBinary: ""

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  readonly property string configuredClientId: String(setting("clientId", "") || "").trim()
  readonly property int redirectPort: Number(setting("redirectPort", 8888)) || 8888

  // ---- Connection state (from `spotify-bridge status`)
  property bool probed: false
  property bool probing: false
  property bool configured: false
  property bool authenticated: false
  property bool needsReauth: false
  property bool appInstalled: false
  property bool appRunning: false
  // Spotify Soloist: the headless Spotify Connect device, run as a systemd
  // user service. Both the binary and the service are the user's to install —
  // Soloist takes its API key only as a command-line argument, so a unit
  // generated here would have to put that secret into the process command
  // line. The plugin only reports what it finds and drives start/stop.
  property bool daemonInstalled: false
  property string daemonPath: ""
  property bool daemonUnit: false
  // A key-bearing unit an older version of this plugin wrote, still installed.
  property bool daemonLegacyUnit: false
  // The unit (or the running process) passes the API key on the command line,
  // where ps, systemctl status and crash reports can read it. Nothing this
  // plugin writes can cause this; a unit from elsewhere still can.
  property bool daemonKeyInCommandLine: false
  property bool daemonRunning: false
  property bool daemonExpired: false
  property bool daemonPaired: false
  // An old version of this plugin installed a weekly timer that re-downloaded
  // the Soloist binary. It is gone; this flags machines that still carry it so
  // the panel can offer to take it off.
  property bool legacyUpdater: false
  // Ready to start: a binary was found and a soloist.service exists.
  readonly property bool daemonReady: daemonInstalled && daemonUnit
  readonly property bool hasLocalDevice: appInstalled || daemonInstalled
  property string storedClientId: ""
  property var user: ({})
  property string lastError: ""
  // The most recent item that had cover art, remembered by the bridge across
  // shell restarts so the bar chip has a picture before the first poll.
  property var lastPlayed: ({})

  // ---- Login flow
  property bool authRunning: false
  property string authError: ""
  property var authProcess: null

  // ---- Player
  property var player: ({ active: false })
  property bool playerLoading: false
  property string playerError: ""
  property double playerFetchedAt: 0
  property int localProgressMs: 0
  property bool noDevice: false
  property bool premiumRequired: false
  readonly property bool playerActive: player && player.active === true
  readonly property bool isPlaying: playerActive && player.isPlaying === true
  readonly property var nowItem: playerActive && player.item ? player.item : null
  readonly property string nowUri: nowItem && nowItem.uri ? nowItem.uri : ""
  readonly property int durationMs: nowItem && nowItem.durationMs ? nowItem.durationMs : 0
  readonly property int volume: playerActive && player.volume !== undefined ? player.volume : -1
  readonly property string deviceName: playerActive && player.device && player.device.name ? player.device.name : ""
  // Art for the bar chip: what's playing now, else what played last.
  readonly property var chipItem: nowItem && (nowItem.artPath || nowItem.art) ? nowItem : (lastPlayed && (lastPlayed.artPath || lastPlayed.art) ? lastPlayed : null)

  // ---- Saved state of the current item (heart)
  property var savedByUri: ({})
  readonly property bool nowSaved: nowUri !== "" && savedByUri[nowUri] === true

  // ---- Devices
  property var devices: []
  property bool devicesLoading: false

  // ---- Library caches
  property var playlists: []
  property int likedCount: 0
  property bool playlistsLoading: false
  property string playlistsError: ""
  property double playlistsLoadedAt: 0

  property var audiobooks: []
  property bool audiobooksLoading: false
  property string audiobooksError: ""
  property double audiobooksLoadedAt: 0

  property var shows: []
  property bool showsLoading: false
  property string showsError: ""
  property double showsLoadedAt: 0

  property var recent: []
  property bool recentLoading: false
  property double recentLoadedAt: 0

  // ---- Detail page (playlist tracks, album tracks, show episodes, book chapters)
  property var detail: null
  property int _detailSerial: 0

  // ---- Search
  property var searchResults: null
  property bool searching: false
  property string searchError: ""
  property int _searchSerial: 0

  // ---- Short-lived action feedback
  property string actionStatus: ""
  property string actionError: ""

  // Panels tell the service when they're visible so polling can speed up.
  property int openPanels: 0
  readonly property bool panelOpen: openPanels > 0

  readonly property bool ready: probed && authenticated
  readonly property bool busy: probing || playerLoading || searching || playlistsLoading || audiobooksLoading || showsLoading || (detail && detail.loading === true)

  readonly property int staleMs: 600000

  // ------------------------------------------------------------ process --

  // Each bridge call gets its own short-lived Process so a status poll never
  // waits behind a search. The callback receives the parsed JSON envelope.
  Component {
    id: bridgeProcess

    Process {
      id: proc
      property var callback: null
      running: false
      clearEnvironment: true
      environment: root.bridgeEnvironment
      // The bridge is never handed a secret to read: no call passes anything
      // on stdin, and no argument it is given is one.
      stdinEnabled: false
      stdout: StdioCollector { id: outCollector; waitForEnd: true }
      stderr: StdioCollector { id: errCollector; waitForEnd: true }
      onExited: function(exitCode, exitStatus) {
        var text = String(outCollector.text || "")
        var err = String(errCollector.text || "")
        var result
        try {
          result = JSON.parse(text)
        } catch (e) {
          var detail = text.trim() !== "" ? text.trim() : err.trim()
          result = { ok: false, code: exitCode === 0 ? "parse" : "crash", error: Model.conciseError(detail, "spotify-bridge returned nothing") }
        }
        if (result && result.ok === false && result.error) result.error = Model.conciseError(result.error)
        var cb = proc.callback
        proc.callback = null
        if (cb) cb(result)
        proc.destroy()
      }
    }
  }

  function call(args, callback) {
    if (!active) return null
    if (python === "" && pythonError === "") {
      // Calls made before the interpreter is known wait for the probe.
      var queued = _queuedCalls
      queued.push({ args: args, callback: callback })
      _queuedCalls = queued
      resolvePython()
      return null
    }
    var command = python === "" ? [] : Model.bridgeCommand(python, bridge, args)
    if (command.length === 0) {
      // Fail closed: no trusted interpreter means no bridge call at all.
      var failure = { ok: false, code: "no_python", error: pythonError || "Could not build the spotify-bridge command" }
      if (callback) Qt.callLater(function() { callback(failure) })
      return null
    }
    var proc = bridgeProcess.createObject(root, { command: command, callback: callback })
    if (!proc) return null
    proc.running = true
    return proc
  }

  function resolvePython() {
    if (python !== "" || pythonError !== "" || _pythonProbing) return
    _pythonCandidate = 0
    probeNextPython()
  }

  // Walk the absolute candidates in order; the first that starts and reports
  // a usable Python 3 is the bridge's interpreter for the life of the shell.
  // Each attempt is its own Process tagged with its number, so a late exit
  // from an abandoned attempt can never settle a later one.
  function probeNextPython() {
    var command = []
    while (command.length === 0 && _pythonCandidate < Model.pythonCandidates.length) {
      command = Model.pythonProbeCommand(Model.pythonCandidates[_pythonCandidate])
      if (command.length === 0) _pythonCandidate++
    }
    if (command.length === 0) {
      _pythonProbing = false
      pythonError = "No Python 3 found in " + Model.trustedBinaryDirectories.join(", ")
        + " — the Spotify plugin will not run python3 from your PATH"
      flushQueuedCalls()
      return
    }
    _pythonProbing = true
    _pythonAttempt++
    _pythonProbeWaits = 0
    var probe = pythonProbeProcess.createObject(root, { command: command, attempt: _pythonAttempt })
    if (!probe) { settlePythonProbe(_pythonAttempt, false, -1); return }
    _pythonProbeObject = probe
    pythonProbeWatchdog.restart()
    probe.running = true
  }

  function settlePythonProbe(attempt, started, exitCode) {
    if (!_pythonProbing || attempt !== _pythonAttempt) return
    pythonProbeWatchdog.stop()
    _pythonProbeObject = null
    if (started && exitCode === 0) {
      _pythonProbing = false
      python = Model.pythonCandidates[_pythonCandidate]
      flushQueuedCalls()
      return
    }
    _pythonCandidate++
    probeNextPython()
  }

  function flushQueuedCalls() {
    var queued = _queuedCalls
    _queuedCalls = []
    for (var i = 0; i < queued.length; i++) call(queued[i].args, queued[i].callback)
  }

  Component {
    id: pythonProbeProcess

    Process {
      id: probeProc
      property int attempt: 0
      property bool started: false
      running: false
      clearEnvironment: true
      environment: root.pythonProbeEnvironment
      onStarted: started = true
      onExited: function(exitCode) {
        root.settlePythonProbe(probeProc.attempt, probeProc.started, exitCode)
        probeProc.destroy()
      }
    }
  }

  // Quickshell emits no exit at all for a candidate that does not exist, so
  // an attempt that has not even started after three seconds is a miss. One
  // that started (a slow first run at login) gets up to half a minute more.
  Timer {
    id: pythonProbeWatchdog
    interval: 3000
    repeat: false
    onTriggered: {
      var probe = root._pythonProbeObject
      if (probe && probe.started && ++root._pythonProbeWaits < 10) { restart(); return }
      root.settlePythonProbe(root._pythonAttempt, false, -1)
      if (probe) { probe.running = false; probe.destroy() }
    }
  }

  // Detached launches the user clicks for: the Spotify app, Omarchy's
  // launch-or-focus and floating-terminal scripts. The command is an
  // absolute argv; the environment is cleared down to the session handles a
  // GUI program needs with PATH pinned, so no BASH_ENV, exported shell
  // function or user PATH entry reaches those scripts.
  Process {
    id: detachedLauncher
    running: false
    command: []
    clearEnvironment: true
    environment: root.launchEnvironment
  }

  function launchDetached(command, missing) {
    if (!command || command.length === 0) {
      flash(missing, true)
      return false
    }
    detachedLauncher.command = command
    detachedLauncher.startDetached()
    return true
  }

  function focusApp() {
    return launchDetached(Model.focusAppCommand(tools), "omarchy-launch-or-focus was not found in Omarchy's directories")
  }

  function launchInstall() {
    return launchDetached(Model.installLaunchCommand(tools), "Omarchy's floating terminal launcher was not found")
  }

  // Common failure handling: auth-shaped errors flip the connection state so
  // the panel shows the setup card instead of a wall of identical errors.
  function absorbAuthError(result) {
    if (!result || result.ok !== false) return false
    if (result.code === "signed_out") { authenticated = false; return true }
    if (result.code === "reauth") { authenticated = false; needsReauth = true; return true }
    if (result.code === "premium_required") { premiumRequired = true }
    return false
  }

  function flash(text, isError) {
    if (isError) { actionError = text; actionStatus = "" }
    else { actionStatus = text; actionError = "" }
    actionStatusTimer.restart()
  }

  Timer {
    id: actionStatusTimer
    interval: 3000
    repeat: false
    onTriggered: { root.actionStatus = ""; root.actionError = "" }
  }

  // ------------------------------------------------------------- status --

  function refresh() {
    if (!active || probing) return
    probing = true
    call(["status"], function(result) {
      root.probing = false
      root.probed = true
      if (!result.ok) {
        root.lastError = result.error
        return
      }
      root.lastError = ""
      var d = result.data
      root.configured = d.configured === true
      root.storedClientId = d.clientId || ""
      root.needsReauth = d.needsReauth === true
      root.authenticated = d.authenticated === true
      root.appInstalled = d.appInstalled === true
      root.appRunning = d.appRunning === true
      root.appBinary = d.appBinary || ""
      root.tools = d.tools || {}
      root.daemonInstalled = d.daemonInstalled === true
      root.daemonPath = d.daemonPath || ""
      root.daemonUnit = d.daemonUnit === true
      root.daemonLegacyUnit = d.daemonLegacyUnit === true
      root.daemonKeyInCommandLine = d.daemonKeyInCommandLine === true
      root.daemonRunning = d.daemonRunning === true
      root.daemonExpired = d.daemonExpired === true
      root.daemonPaired = d.daemonPaired === true
      root.legacyUpdater = d.legacyUpdater === true
      root.user = d.user || {}
      root.lastPlayed = d.lastPlayed || {}
      if (root.authenticated) {
        root.refreshPlayer()
        root.refreshRecentIfStale()
      }
    })
  }

  function refreshIfStale() {
    if (!probed) { refresh(); return }
    if (authenticated) {
      refreshPlayer()
      refreshRecentIfStale()
    } else {
      refresh()
    }
  }

  // -------------------------------------------------------------- login --

  function startAuth(clientId) {
    var id = String(clientId || configuredClientId || storedClientId || "").trim()
    if (id === "") { authError = "Paste your Spotify app's Client ID first."; return false }
    if (authRunning) return false
    authRunning = true
    authError = ""
    authProcess = call(["auth", "--client-id", id, "--port", String(redirectPort)], function(result) {
      root.authRunning = false
      root.authProcess = null
      if (!result.ok) {
        if (result.code !== "cancelled") root.authError = result.error
        root.refresh()
        return
      }
      root.authError = ""
      root.needsReauth = false
      root.authenticated = true
      root.user = result.data.user || {}
      root.flash("Connected as " + (root.user.name || "Spotify"), false)
      root.playlistsLoadedAt = 0
      root.audiobooksLoadedAt = 0
      root.showsLoadedAt = 0
      root.recentLoadedAt = 0
      root.refresh()
    })
    return authProcess !== null
  }

  function cancelAuth() {
    if (authProcess) authProcess.running = false
  }

  function signOut() {
    call(["logout"], function(result) {
      root.authenticated = false
      root.needsReauth = false
      root.user = ({})
      root.player = ({ active: false })
      root.playlists = []
      root.audiobooks = []
      root.shows = []
      root.recent = []
      root.searchResults = null
      root.detail = null
      root.savedByUri = ({})
      root.playlistsLoadedAt = 0
      root.audiobooksLoadedAt = 0
      root.showsLoadedAt = 0
      root.recentLoadedAt = 0
      root.refresh()
    })
  }

  // ------------------------------------------------------------- player --

  function refreshPlayer() {
    if (!active || !authenticated || playerLoading) return
    playerLoading = true
    call(["player"], function(result) {
      root.playerLoading = false
      if (!result.ok) {
        if (root.absorbAuthError(result)) return
        if (result.code === "rate_limited") pollTimer.interval = Math.max(pollTimer.interval, (Number(result.retryAfter) || 5) * 1000)
        root.playerError = result.error
        return
      }
      root.playerError = ""
      root.applyPlayer(result.data)
    })
  }

  function applyPlayer(next) {
    var previousUri = nowUri
    player = next || { active: false }
    playerFetchedAt = Date.now()
    localProgressMs = playerActive ? (Number(player.progressMs) || 0) : 0
    if (playerActive) noDevice = false
    if (nowItem && nowItem.artPath) {
      lastPlayed = { uri: nowItem.uri, name: nowItem.name, subtitle: nowItem.artists || nowItem.show || nowItem.book || "", art: nowItem.art, artPath: nowItem.artPath }
    }
    if (nowUri !== "" && nowUri !== previousUri) checkSaved(nowUri)
  }

  // Interpolate the progress bar between polls so it moves every second.
  Timer {
    interval: 1000
    repeat: true
    running: root.isPlaying
    onTriggered: {
      var elapsed = Date.now() - root.playerFetchedAt
      var next = (Number(root.player.progressMs) || 0) + elapsed
      root.localProgressMs = root.durationMs > 0 ? Math.min(next, root.durationMs) : next
      // Past the end of the track: Spotify has moved on, catch up quickly.
      if (root.durationMs > 0 && next > root.durationMs + 1500) root.refreshPlayer()
    }
  }

  // Poll cadence: brisk while a panel is open, relaxed when only the bar
  // chip needs the title, and sleepy when nothing is playing.
  Timer {
    id: pollTimer
    interval: root.panelOpen ? 4000 : (root.isPlaying ? 15000 : 60000)
    repeat: true
    running: root.active && root.authenticated
    onTriggered: root.refreshPlayer()
  }

  // Re-poll shortly after an action so the UI settles on Spotify's truth.
  Timer {
    id: settleTimer
    interval: 700
    repeat: false
    onTriggered: root.refreshPlayer()
  }

  function settle() { settleTimer.restart() }

  function optimistic(patch) {
    if (!playerActive) return
    var next = {}
    for (var k in player) next[k] = player[k]
    for (var p in patch) next[p] = patch[p]
    player = next
    playerFetchedAt = Date.now()
  }

  function action(args, onOk, label) {
    call(args, function(result) {
      if (!result.ok) {
        if (root.absorbAuthError(result)) return
        if (result.code === "no_device") root.noDevice = true
        root.flash(result.error, true)
        root.settle()
        return
      }
      root.noDevice = false
      if (onOk) onOk(result.data)
      if (label) root.flash(label, false)
      root.settle()
    })
  }

  function playPause() {
    if (!authenticated) return false
    if (isPlaying) {
      optimistic({ isPlaying: false, progressMs: localProgressMs })
      action(["pause"])
    } else {
      optimistic({ isPlaying: true, progressMs: localProgressMs })
      action(["play"])
    }
    return true
  }

  function next() {
    if (!authenticated) return false
    action(["next"])
    return true
  }

  function previous() {
    if (!authenticated) return false
    // Spotify's own rule of thumb: early in a track, go back; later, restart.
    if (localProgressMs > 4000) { seek(0); return true }
    action(["previous"])
    return true
  }

  function seek(ms) {
    if (!authenticated || !playerActive) return
    var clamped = Math.max(0, Math.min(durationMs > 0 ? durationMs : ms, Math.round(ms)))
    optimistic({ progressMs: clamped })
    localProgressMs = clamped
    action(["seek", String(clamped)])
  }

  function setVolume(pct) {
    if (!authenticated) return
    var v = Math.max(0, Math.min(100, Math.round(pct)))
    optimistic({ volume: v })
    volumeDebounce.pending = v
    volumeDebounce.restart()
  }

  Timer {
    id: volumeDebounce
    property int pending: -1
    interval: 180
    repeat: false
    onTriggered: if (pending >= 0) root.action(["volume", String(pending)])
  }

  function nudgeVolume(delta) {
    var current = volume >= 0 ? volume : 50
    setVolume(current + delta)
  }

  function toggleShuffle() {
    if (!playerActive) return
    var next = !(player.shuffle === true)
    optimistic({ shuffle: next })
    action(["shuffle", next ? "on" : "off"])
  }

  function cycleRepeat() {
    if (!playerActive) return
    var next = Model.nextRepeat(player.repeat || "off")
    optimistic({ repeat: next })
    action(["repeat", next])
  }

  // Play a context (album/playlist/show/audiobook/artist), optionally from a
  // given item inside it.
  function playContext(contextUri, offsetUri) {
    if (!authenticated) return
    var args = ["play", "--context", contextUri]
    if (offsetUri) args.push("--offset-uri", offsetUri)
    optimistic({ isPlaying: true })
    action(args)
  }

  function playUris(uris) {
    if (!authenticated || !uris || uris.length === 0) return
    optimistic({ isPlaying: true })
    action(["play", "--uris"].concat(uris))
  }

  // What "activate" means for a row depends on the item type.
  function playItem(item, contextUri) {
    if (!item) return
    if (item.type === "track") {
      if (contextUri) playContext(contextUri, item.uri)
      else if (item.albumUri) playContext(item.albumUri, item.uri)
      else playUris([item.uri])
    } else if (item.type === "episode") {
      if (contextUri) playContext(contextUri, item.uri)
      else if (item.showUri) playContext(item.showUri, item.uri)
      else playUris([item.uri])
    } else if (item.type === "chapter") {
      if (contextUri) playContext(contextUri, item.uri)
      else if (item.bookUri) playContext(item.bookUri, item.uri)
      else playUris([item.uri])
    } else if (item.type === "artist" || item.type === "album" || item.type === "playlist" || item.type === "show" || item.type === "audiobook") {
      if (item.id === "__liked__") playLiked()
      else playContext(item.uri)
    }
  }

  function shuffleContext(contextUri) {
    if (!authenticated) return
    call(["shuffle", "on"], function(result) {
      root.playContext(contextUri)
    })
  }

  function queueAdd(item) {
    if (!item || !item.uri) return
    action(["queue-add", item.uri], null, "Queued " + (item.name || ""))
  }

  function playLiked() {
    call(["liked", "--limit", "100"], function(result) {
      if (!result.ok) { root.absorbAuthError(result); root.flash(result.error, true); return }
      var uris = []
      var items = result.data.items || []
      for (var i = 0; i < items.length; i++) if (items[i].uri) uris.push(items[i].uri)
      root.playUris(uris)
    })
  }

  // ------------------------------------------------------------ devices --

  function loadDevices() {
    if (!authenticated || devicesLoading) return
    devicesLoading = true
    call(["devices"], function(result) {
      root.devicesLoading = false
      if (!result.ok) { root.absorbAuthError(result); return }
      root.devices = result.data || []
    })
  }

  function transferTo(deviceId) {
    if (!deviceId) return
    action(["transfer", deviceId, "--play"], function() { root.loadDevices() }, "Switched device")
  }

  function launchApp() {
    if (!shell) return
    // uwsm-app keeps the client in its own scope, matching omarchy's installer.
    if (!launchDetached(Model.appLaunchCommand(tools, appBinary),
                        "uwsm-app or the Spotify app was not found in " + Model.trustedBinaryDirectories.join(", "))) return
    flash("Launching Spotify…", false)
    appLaunchTimer.restart()
  }

  // ---- Soloist housekeeping, driven from the panel. Nothing here creates a
  //      service or stores a credential: the only writes left are deletions of
  //      files older versions of this plugin installed. Getting the binary is
  //      the user's job (Spotify ships no checksum or signature to verify a
  //      download against), and so is the unit that runs it, because Soloist
  //      accepts its API key only as a command-line argument.
  property bool soloistBusy: false
  property string soloistError: ""

  function applyDaemonState(d) {
    daemonInstalled = d.daemonInstalled === true
    daemonPath = d.daemonPath || ""
    daemonUnit = d.daemonUnit === true
    daemonLegacyUnit = d.daemonLegacyUnit === true
    daemonKeyInCommandLine = d.daemonKeyInCommandLine === true
    daemonRunning = d.daemonRunning === true
    daemonExpired = d.daemonExpired === true
    daemonPaired = d.daemonPaired === true
    legacyUpdater = d.legacyUpdater === true
    appInstalled = d.appInstalled === true
    appRunning = d.appRunning === true
    if (d.appBinary !== undefined) appBinary = d.appBinary || ""
    if (d.tools !== undefined) tools = d.tools || {}
  }

  // Removes the weekly re-download timer an old version of this plugin left
  // behind. Nothing re-creates it.
  function dropSoloistUpdater() {
    if (soloistBusy) return
    soloistBusy = true
    soloistError = ""
    call(["soloist", "drop-updater"], function(result) {
      root.soloistBusy = false
      if (!result.ok) { root.soloistError = result.error; return }
      root.applyDaemonState(result.data)
      root.flash("Removed the old Soloist auto-updater", false)
    })
  }

  // Deletes a key-bearing soloist.service an older version of this plugin
  // wrote. A unit from a package, or one the user wrote, is refused by the
  // bridge and left alone.
  function removeSoloist() {
    if (soloistBusy) return
    soloistBusy = true
    soloistError = ""
    call(["soloist", "remove"], function(result) {
      root.soloistBusy = false
      if (!result.ok) { root.soloistError = result.error; return }
      root.applyDaemonState(result.data)
      root.flash("Removed the old plugin-written service — the binary itself was left alone", false)
    })
  }

  function startDaemon() {
    call(["daemon", "start"], function(result) {
      if (!result.ok) { root.flash(result.error, true); return }
      root.applyDaemonState(result.data)
      if (root.daemonRunning) root.flash(root.daemonPaired ? "Soloist started" : "Soloist started — pick “Omarchy” once in the Spotify app to pair it", false)
      else root.flash(root.daemonExpired ? "Soloist build expired — update it with your package manager" : "Soloist did not stay up — see journalctl --user -u soloist", true)
      appLaunchTimer.restart()
    })
  }

  Timer {
    id: appLaunchTimer
    interval: 4000
    repeat: false
    onTriggered: { root.refresh(); root.loadDevices() }
  }

  // -------------------------------------------------------------- saved --

  function checkSaved(uri) {
    if (!uri || !authenticated) return
    call(["library-contains", uri], function(result) {
      if (!result.ok) return
      var next = {}
      for (var k in root.savedByUri) next[k] = root.savedByUri[k]
      for (var u in result.data) next[u] = result.data[u] === true
      root.savedByUri = next
    })
  }

  function toggleSaved() {
    var uri = nowUri
    if (!uri) return
    var saved = nowSaved
    var next = {}
    for (var k in savedByUri) next[k] = savedByUri[k]
    next[uri] = !saved
    savedByUri = next
    call([saved ? "library-remove" : "library-save", uri], function(result) {
      if (!result.ok) {
        var revert = {}
        for (var k in root.savedByUri) revert[k] = root.savedByUri[k]
        revert[uri] = saved
        root.savedByUri = revert
        root.flash(result.error, true)
        return
      }
      root.flash(saved ? "Removed from your library" : "Saved to your library", false)
    })
  }

  // ------------------------------------------------------------ library --

  function loadPlaylists(force) {
    if (!authenticated || playlistsLoading) return
    if (!force && playlistsLoadedAt > 0 && Date.now() - playlistsLoadedAt < staleMs) return
    playlistsLoading = true
    playlistsError = ""
    call(["playlists"], function(result) {
      root.playlistsLoading = false
      if (!result.ok) { if (!root.absorbAuthError(result)) root.playlistsError = result.error; return }
      var items = result.data.items || []
      root.likedCount = Number(result.data.likedCount) || 0
      if (root.likedCount > 0) {
        items = [{ type: "playlist", id: "__liked__", uri: "", name: "Liked Songs", owner: "", count: root.likedCount, art: "", artPath: "", liked: true }].concat(items)
      }
      root.playlists = items
      root.playlistsLoadedAt = Date.now()
    })
  }

  function loadAudiobooks(force) {
    if (!authenticated || audiobooksLoading) return
    if (!force && audiobooksLoadedAt > 0 && Date.now() - audiobooksLoadedAt < staleMs) return
    audiobooksLoading = true
    audiobooksError = ""
    call(["audiobooks"], function(result) {
      root.audiobooksLoading = false
      if (!result.ok) { if (!root.absorbAuthError(result)) root.audiobooksError = result.error; return }
      root.audiobooks = result.data || []
      root.audiobooksLoadedAt = Date.now()
    })
  }

  function loadShows(force) {
    if (!authenticated || showsLoading) return
    if (!force && showsLoadedAt > 0 && Date.now() - showsLoadedAt < staleMs) return
    showsLoading = true
    showsError = ""
    call(["shows"], function(result) {
      root.showsLoading = false
      if (!result.ok) { if (!root.absorbAuthError(result)) root.showsError = result.error; return }
      root.shows = result.data || []
      root.showsLoadedAt = Date.now()
    })
  }

  function refreshRecentIfStale() {
    if (recentLoadedAt > 0 && Date.now() - recentLoadedAt < 120000) return
    loadRecent()
  }

  function loadRecent() {
    if (!authenticated || recentLoading) return
    recentLoading = true
    call(["recent", "--limit", "12"], function(result) {
      root.recentLoading = false
      if (!result.ok) { root.absorbAuthError(result); return }
      root.recent = result.data || []
      root.recentLoadedAt = Date.now()
    })
  }

  function loadTab(tab, force) {
    if (tab === "playlists") loadPlaylists(force)
    else if (tab === "books") loadAudiobooks(force)
    else if (tab === "podcasts") loadShows(force)
    else if (tab === "search") { if (force) loadRecent(); else refreshRecentIfStale() }
  }

  // ------------------------------------------------------------- detail --

  function openDetail(item) {
    var kind = Model.detailKindFor(item)
    if (kind === "") return false
    var serial = ++_detailSerial
    detail = { kind: kind, item: item, items: [], total: 0, loading: true, error: "", contextUri: item.uri || "" }
    var args
    if (kind === "playlist") args = ["playlist-items", item.id]
    else if (kind === "liked") args = ["liked", "--limit", "100"]
    else if (kind === "album") args = ["album-tracks", item.id]
    else if (kind === "show") args = ["show-episodes", item.id]
    else args = ["audiobook-chapters", item.id]
    call(args, function(result) {
      if (serial !== root._detailSerial || !root.detail) return
      var next = {}
      for (var k in root.detail) next[k] = root.detail[k]
      next.loading = false
      if (!result.ok) {
        root.absorbAuthError(result)
        next.error = result.error
      } else {
        next.items = result.data.items || []
        next.total = Number(result.data.total) || next.items.length
        var header = result.data.show || result.data.album || result.data.book
        if (header && header.name) next.item = header
      }
      root.detail = next
    })
    return true
  }

  function closeDetail() {
    _detailSerial++
    detail = null
  }

  // ------------------------------------------------------------- search --

  function search(query) {
    var q = String(query || "").trim()
    if (!authenticated) return
    if (q === "") { _searchSerial++; searching = false; searchResults = null; searchError = ""; return }
    if (searchResults && searchResults.query === q) return
    var serial = ++_searchSerial
    searching = true
    searchError = ""
    call(["search", q, "--limit", "6"], function(result) {
      if (serial !== root._searchSerial) return
      root.searching = false
      if (!result.ok) { if (!root.absorbAuthError(result)) root.searchError = result.error; return }
      root.searchResults = result.data
    })
  }

  // ----------------------------------------------------------------- IPC --

  IpcHandler {
    // Only the shared instance answers IPC; the per-panel fallback stays quiet.
    enabled: root.active
    target: "spotify"

    function playPause(): string { return root.playPause() ? "ok" : "unhandled" }
    function next(): string { return root.next() ? "ok" : "unhandled" }
    function previous(): string { return root.previous() ? "ok" : "unhandled" }
    function volumeUp(): string { root.nudgeVolume(5); return "ok" }
    function volumeDown(): string { root.nudgeVolume(-5); return "ok" }
    function refresh(): string { root.refresh(); return "ok" }
    function status(): string {
      return JSON.stringify({
        authenticated: root.authenticated,
        active: root.playerActive,
        playing: root.isPlaying,
        title: root.nowItem ? root.nowItem.name : "",
        artist: root.nowItem ? (root.nowItem.artists || root.nowItem.show || root.nowItem.book || "") : "",
        device: root.deviceName,
        progressMs: root.localProgressMs,
        durationMs: root.durationMs
      })
    }
  }

  Timer {
    interval: 300000
    repeat: true
    running: root.active
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  onActiveChanged: if (active && !probed) refresh()
}
