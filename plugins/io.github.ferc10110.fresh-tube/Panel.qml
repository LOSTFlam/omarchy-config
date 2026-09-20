import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "FreshTubeModel.js" as Model

// The panel is a thin face over bin/fresh-tube: every fetch and every write
// happens in that script, and the panel only shows the JSON it prints.
Panel {
  id: root
  moduleName: "io.github.ferc10110.fresh-tube"
  ipcTarget: "io.github.ferc10110.fresh-tube"
  // Its own IpcHandler below adds refresh and togglePin to open/close/toggle.
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  property string view: "videos"
  property var videos: []
  property var errors: []
  property string fetchedAt: ""
  property bool offline: false
  property int channelCount: 0
  property string notice: ""
  property bool noticeIsError: false
  property bool pinned: false
  property int popupWidth: 420
  property int popupHeight: 520
  property bool playerFound: true
  // The video playCmd is launching; only play() writes it and only playCmd reads it.
  property var pendingPlay: null
  property var prefsQueue: []
  property var channels: []

  property var pinnedVideos: []

  property string tab: "new"
  property var queueVideos: []

  readonly property int maxPins: 3
  readonly property bool pinsFull: pinnedVideos.length >= maxPins

  readonly property bool refreshing: refreshCmd.running
  readonly property bool adding: addCmd.running
  readonly property bool addingVideo: queueAddCmd.running
  readonly property string program: pluginPath("bin/fresh-tube")
  readonly property string playerCommand: String(setting("playerCommand", "mpv") || "mpv")
  // Empty disables the fallback; the CLI only gets --fallback when there is one.
  readonly property string fallbackCommand: String(setting("fallbackCommand", "chromium") || "")
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property Item currentFocus: view === "channels" ? channelsView.focusItem : videosView.focusItem

  // Absolute path of a file shipped inside this plugin, wherever it is installed.
  function pluginPath(relative) {
    var url = String(Qt.resolvedUrl(relative))
    return url.indexOf("file://") === 0 ? decodeURIComponent(url.substring(7)) : url
  }

  function parseJson(out) {
    try {
      var data = JSON.parse(String(out || ""))
      return data && typeof data === "object" ? data : null
    } catch (e) {
      return null
    }
  }

  function lastLine(err) {
    var lines = String(err || "").trim().split("\n")
    return lines[lines.length - 1].replace(/^fresh-tube: /, "")
  }

  function setNotice(message, isError) {
    notice = message || ""
    noticeIsError = isError === true
  }

  function focusCurrent() {
    Qt.callLater(function() {
      if (root.opened && root.currentFocus) root.currentFocus.forceActiveFocus()
    })
  }

  function applyPayload(data) {
    videos = Array.isArray(data.videos) ? data.videos : []
    pinnedVideos = Array.isArray(data.pinned) ? data.pinned : []
    queueVideos = Array.isArray(data.queue) ? data.queue : []
    errors = Array.isArray(data.errors) ? data.errors : []
    fetchedAt = String(data.fetchedAt || "")
    offline = data.offline === true
    channelCount = Number(data.channelCount) || 0
  }

  function loadCached() {
    cachedCmd.start(["refresh", "--json", "--cached"])
  }

  function reloadCached() { loadCached() }

  function refresh() {
    refreshCmd.start(["refresh", "--json"])
  }

  function checkPlayer() {
    playerCheckCmd.start(["-c", "command -v -- \"$0\"", Model.playerName(root.playerCommand)])
  }

  function removeVideo(videoId) {
    videos = videos.filter(function(v) { return v.videoId !== videoId })
  }

  // Every play goes through the script: it launches the player, places its
  // window and marks the video seen only once the player is running.
  function play(video) {
    if (!video || playCmd.running) return
    if (!playerFound) {
      setNotice(Model.playerName(playerCommand) + " not found. Set playerCommand in shell.json.", true)
      return
    }
    pendingPlay = video
    var args = ["play", "--player", playerCommand]
    if (fallbackCommand !== "") args.push("--fallback", fallbackCommand)
    args.push("--", video.videoId)
    playCmd.start(args)
  }

  function dismiss(video) {
    if (!video || seenCmd.running) return
    seenCmd.start(["seen", "--", video.videoId])
  }

  // Finished with a saved video: out of the Watch later list, and seen.
  function finish(video) {
    if (!video || doneCmd.running) return
    doneCmd.start(["done", "--", video.videoId])
  }

  function toggleTab() {
    tab = tab === "new" ? "later" : "new"
  }

  function addToQueue(text) {
    var value = String(text || "").trim()
    if (value === "" || queueAddCmd.running) return
    videosView.laterView.error = ""
    queueAddCmd.start(["queue", "add", "--", value])
  }

  function moveQueued(video, index) {
    if (!video || queueMoveCmd.running) return
    queueMoveCmd.start(["queue", "move", "--", video.videoId, String(Math.max(0, index))])
  }

  function isPinned(video) {
    if (!video) return false
    for (var i = 0; i < pinnedVideos.length; i++) {
      if (pinnedVideos[i].videoId === video.videoId) return true
    }
    return false
  }

  function pin(video) {
    if (!video || pinCmd.running) return
    if (pinsFull) {
      setNotice("Pin limit reached (" + maxPins + ")", true)
      return
    }
    pinCmd.start(["pin", "--", video.videoId])
  }

  function unpin(video) {
    if (!video || pinCmd.running) return
    pinCmd.start(["unpin", "--", video.videoId])
  }

  function togglePinVideo(video) {
    if (isPinned(video)) unpin(video)
    else pin(video)
  }

  // Every `prefs set` rewrites the whole state file, so writes go one at a
  // time through a queue; two in parallel would drop one of the values.
  function queuePref(key, value) {
    prefsQueue = prefsQueue.concat([[key, String(value)]])
    pumpPrefs()
  }

  function pumpPrefs() {
    if (prefsCmd.running || prefsQueue.length === 0) return
    var next = prefsQueue[0]
    prefsQueue = prefsQueue.slice(1)
    prefsCmd.start(["prefs", "set", next[0], next[1]])
  }

  function setPinned(value) {
    var next = value === true
    if (pinned === next) return
    pinned = next
    queuePref("pinned", next ? "true" : "false")
  }

  function togglePin() { setPinned(!pinned) }

  function loadChannels() {
    channelsCmd.start(["channels", "--json"])
  }

  function showChannels() {
    channelsView.error = ""
    view = "channels"
    loadChannels()
  }

  function showVideos() {
    view = "videos"
  }

  function addChannel(text) {
    var value = String(text || "").trim()
    if (value === "" || addCmd.running) return
    if (!Model.looksLikeChannelInput(value)) {
      channelsView.error = "That doesn't look like a YouTube channel"
      return
    }
    channelsView.error = ""
    addCmd.start(["add", "--", value])
  }

  function removeChannel(channelId) {
    if (!channelId || removeCmd.running) return
    removeCmd.start(["remove", "--", channelId])
  }

  function saveSize(w, h) {
    popupWidth = w
    popupHeight = h
    queuePref("width", w)
    queuePref("height", h)
  }

  onOpenedChanged: {
    if (opened) {
      setNotice("", false)
      view = "videos"
      loadCached()
      refresh()
      focusCurrent()
    }
  }

  onViewChanged: focusCurrent()
  onTabChanged: focusCurrent()

  onPlayerCommandChanged: checkPlayer()

  Component.onCompleted: {
    prefsGetCmd.start(["prefs", "get"])
    checkPlayer()
    loadCached()
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
    function togglePin(): void { root.togglePin() }
  }

  FreshTubeCommand {
    id: prefsGetCmd
    program: root.program
    onFinished: function(code, out, err) {
      var data = root.parseJson(out)
      if (!data) return
      root.popupWidth = Number(data.width) || 420
      root.popupHeight = Number(data.height) || 520
      root.pinned = data.pinned === true
    }
  }

  FreshTubeCommand {
    id: prefsCmd
    program: root.program
    onFinished: function(code, out, err) {
      if (code !== 0) root.setNotice(root.lastLine(err) || "Could not save preferences", true)
      root.pumpPrefs()
    }
  }

  FreshTubeCommand {
    id: cachedCmd
    program: root.program
    queueLatest: true
    onFinished: function(code, out, err) {
      var data = root.parseJson(out)
      if (code !== 0 || !data) {
        root.setNotice(root.lastLine(err) || "Could not read the cache", true)
        return
      }
      root.applyPayload(data)
    }
  }

  FreshTubeCommand {
    id: refreshCmd
    program: root.program
    timeoutMs: 60000
    onFinished: function(code, out, err) {
      var data = root.parseJson(out)
      if (code !== 0 || !data) {
        root.setNotice(root.lastLine(err) || "Could not refresh", true)
        return
      }
      root.applyPayload(data)
      if (data.offline === true && root.channelCount > 0) {
        var when = Model.formatClock(root.fetchedAt)
        root.setNotice("Offline, showing videos from " + (when !== "" ? when : "the last time"), false)
      } else if (root.errors.length > 0) {
        root.setNotice(root.errors.length + (root.errors.length === 1 ? " channel" : " channels") + " failed to update", false)
      } else if (!root.noticeIsError) {
        root.setNotice("", false)
      }
      if (root.hostWidget && typeof root.hostWidget.broadcast === "function") root.hostWidget.broadcast("reloadCached")
    }
  }

  FreshTubeCommand {
    id: seenCmd
    program: root.program
    onFinished: function(code, out, err) {
      if (code !== 0) {
        root.setNotice(root.lastLine(err) || "Could not mark it as seen", true)
        return
      }
      if (root.noticeIsError) root.setNotice("", false)
      var data = root.parseJson(out)
      var id = data ? String(data.seen || "") : ""
      if (id !== "") root.removeVideo(id)
    }
  }

  // The player is up once this returns 0; a failed launch leaves every list as it was.
  FreshTubeCommand {
    id: playCmd
    program: root.program
    timeoutMs: 15000
    onFinished: function(code, out, err) {
      var video = root.pendingPlay
      root.pendingPlay = null
      if (code !== 0) {
        root.setNotice(root.lastLine(err) || "Could not start the player", true)
        return
      }
      if (root.noticeIsError) root.setNotice("", false)
      if (video) root.removeVideo(video.videoId)
      root.loadCached()
      if (!root.pinned) root.close()
    }
  }

  FreshTubeCommand {
    id: doneCmd
    program: root.program
    onFinished: function(code, out, err) {
      if (code !== 0) {
        root.setNotice(root.lastLine(err) || "Could not remove that video", true)
        return
      }
      if (root.noticeIsError) root.setNotice("", false)
      root.loadCached()
    }
  }

  // Looking a video up can chain oEmbed and yt-dlp.
  FreshTubeCommand {
    id: queueAddCmd
    program: root.program
    timeoutMs: 60000
    onFinished: function(code, out, err) {
      var later = videosView.laterView
      if (code !== 0) {
        later.error = root.lastLine(err) || "Could not add that video"
        root.focusCurrent()
        return
      }
      later.clearInput()
      root.loadCached()
      root.focusCurrent()
    }
  }

  // The list already shows the dragged order; a failure rereads the saved one.
  FreshTubeCommand {
    id: queueMoveCmd
    program: root.program
    onFinished: function(code, out, err) {
      if (code !== 0) root.setNotice(root.lastLine(err) || "Could not reorder the list", true)
      root.loadCached()
    }
  }

  // Pinning moves a video between the two lists, so the cache is reread
  // instead of patching them by hand; other screens get told the same way.
  FreshTubeCommand {
    id: pinCmd
    program: root.program
    onFinished: function(code, out, err) {
      var data = root.parseJson(out)
      if (code !== 0 || !data) {
        root.setNotice(root.lastLine(err) || "Could not change the pin", true)
        return
      }
      if (root.noticeIsError) root.setNotice("", false)
      root.loadCached()
      if (root.hostWidget && typeof root.hostWidget.broadcast === "function") root.hostWidget.broadcast("reloadCached")
    }
  }

  FreshTubeCommand {
    id: playerCheckCmd
    program: "/bin/sh"
    queueLatest: true
    onFinished: function(code, out, err) { root.playerFound = code === 0 }
  }

  FreshTubeCommand {
    id: channelsCmd
    program: root.program
    onFinished: function(code, out, err) {
      var data = root.parseJson(out)
      if (code !== 0 || !data) {
        channelsView.error = root.lastLine(err) || "Could not read the channels"
        return
      }
      root.channels = Array.isArray(data.channels) ? data.channels : []
    }
  }

  // Resolving a channel can chain a page fetch, a yt-dlp fallback and the
  // feed, so this one gets a longer leash.
  FreshTubeCommand {
    id: addCmd
    program: root.program
    timeoutMs: 60000
    onFinished: function(code, out, err) {
      if (code !== 0) {
        channelsView.error = root.lastLine(err) || "Could not add that channel"
        root.focusCurrent()
        return
      }
      channelsView.clearInput()
      root.loadChannels()
      root.loadCached()
      root.refresh()
      root.focusCurrent()
    }
  }

  FreshTubeCommand {
    id: removeCmd
    program: root.program
    onFinished: function(code, out, err) {
      if (code !== 0) channelsView.error = root.lastLine(err) || "Could not remove that channel"
      root.loadChannels()
      root.loadCached()
      root.focusCurrent()
    }
  }

  FeedPopup {
    id: popup
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    pinned: root.pinned
    focusTarget: root.currentFocus
    gripColor: root.foreground
    contentWidth: popup.fittedContentWidth(root.popupWidth)
    contentHeight: popup.cappedContentHeight(root.popupHeight)
    onResizeRequested: function(w, h) {
      root.popupWidth = w
      root.popupHeight = h
    }
    onResized: function(w, h) { root.saveSize(w, h) }

    VideosView {
      id: videosView
      anchors.fill: parent
      visible: root.view === "videos"
      host: root
    }

    ChannelsView {
      id: channelsView
      anchors.fill: parent
      visible: root.view === "channels"
      host: root
    }
  }
}
