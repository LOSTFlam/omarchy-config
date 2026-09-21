import QtQuick
import Quickshell.Io

// Serializes helper processes and drops stale responses. Search can be typed
// faster than the network responds without an old query replacing a new one.
Item {
  id: root

  property bool searching: false
  property string searchState: "idle"
  property string searchMessage: "Search for a song or artist."
  property string requestedQuery: ""
  property string runningQuery: ""
  property var results: []
  property var searchWarnings: []

  property bool loadingLyrics: false
  property string lyricsState: "idle"
  property string lyricsMessage: ""
  property var lyrics: null
  property var lyricsWarnings: []
  property var requestedSong: null
  property var runningSong: null
  property string requestedLyricsKey: ""
  property string runningLyricsKey: ""
  property string loadedLyricsKey: ""

  property string _searchStdout: ""
  property string _searchStderr: ""
  property string _lyricsStdout: ""
  property string _lyricsStderr: ""

  signal searchApplied()
  signal lyricsLoaded(var payload)

  visible: false
  width: 0
  height: 0

  function helperPath() {
    return decodeURIComponent(Qt.resolvedUrl("omasing-lyrics").toString()
      .replace(/^file:\/\//, ""))
  }

  function songKey(song) {
    if (!song) return ""
    return [String(song.id || ""), String(song.title || ""),
      String(song.artist || ""), String(song.album || ""),
      String(song.duration || 0)].join("|")
  }

  function clearSearch() {
    requestedQuery = ""
    results = []
    searchWarnings = []
    searchState = "idle"
    searchMessage = "Search for a song or artist."
    if (!searchProcess.running) searching = false
  }

  function search(query) {
    requestedQuery = String(query || "").trim()
    if (requestedQuery.length < 2) {
      clearSearch()
      return
    }
    searching = true
    searchState = "loading"
    searchMessage = "Searching recordings…"
    if (!searchProcess.running) launchSearch()
  }

  function launchSearch() {
    if (searchProcess.running || requestedQuery.length < 2) return
    runningQuery = requestedQuery
    _searchStdout = ""
    _searchStderr = ""
    searchProcess.command = [helperPath(), "search", runningQuery]
    searchProcess.running = true
  }

  function applySearch(raw, fallback) {
    try {
      var payload = JSON.parse(String(raw || ""))
      searchState = String(payload.state || "error")
      searchMessage = String(payload.message || "Search failed.")
      results = Array.isArray(payload.results) ? payload.results : []
      searchWarnings = Array.isArray(payload.warnings) ? payload.warnings : []
    } catch (error) {
      results = []
      searchWarnings = []
      searchState = "error"
      searchMessage = String(fallback || "The search response was unreadable.").trim()
    }
    searchApplied()
  }

  function fetchLyrics(song) {
    var key = songKey(song)
    if (!song || key === "") return
    requestedSong = song
    requestedLyricsKey = key
    lyricsState = "loading"
    lyricsMessage = "Checking the selected recording…"
    loadingLyrics = true
    lyricsWarnings = []

    if (loadedLyricsKey === key && lyrics) {
      loadingLyrics = false
      lyricsState = String(lyrics.state || "ready")
      lyricsMessage = String(lyrics.message || "Lyrics ready")
      Qt.callLater(function() { root.lyricsLoaded(root.lyrics) })
      return
    }
    lyrics = null
    if (!lyricsProcess.running) launchLyrics()
  }

  function launchLyrics() {
    if (lyricsProcess.running || requestedLyricsKey === "" || !requestedSong) return
    runningLyricsKey = requestedLyricsKey
    runningSong = requestedSong
    _lyricsStdout = ""
    _lyricsStderr = ""
    lyricsProcess.command = [helperPath(), "lyrics", JSON.stringify(runningSong)]
    lyricsProcess.running = true
  }

  function cancelLyrics() {
    requestedLyricsKey = ""
    requestedSong = null
    loadingLyrics = false
    if (lyricsState === "loading") {
      lyricsState = "idle"
      lyricsMessage = ""
    }
  }

  function applyLyrics(raw, fallback) {
    var payload = null
    try {
      payload = JSON.parse(String(raw || ""))
    } catch (error) {
      payload = {
        state: "error",
        message: String(fallback || "The lyrics response was unreadable.").trim(),
        plainLyrics: "",
        verification: {
          level: "unavailable",
          label: "Could not verify",
          detail: "Try this recording again.",
          sources: []
        }
      }
    }
    lyrics = payload
    lyricsState = String(payload.state || "error")
    lyricsMessage = String(payload.message || "Could not load lyrics.")
    lyricsWarnings = Array.isArray(payload.warnings) ? payload.warnings : []
    loadingLyrics = false
    loadedLyricsKey = lyricsState === "ready" || lyricsState === "instrumental"
      ? runningLyricsKey : ""
    lyricsLoaded(payload)
  }

  Process {
    id: searchProcess
    running: false
    command: []

    stdout: StdioCollector {
      id: searchOutput
      waitForEnd: true
      onStreamFinished: root._searchStdout = text
    }
    stderr: StdioCollector {
      id: searchErrors
      waitForEnd: true
      onStreamFinished: root._searchStderr = text
    }
    onExited: function() {
      var completedQuery = root.runningQuery
      var current = completedQuery === root.requestedQuery
      if (current) {
        root.searching = false
        var output = String(searchOutput.text || root._searchStdout || "")
        var fallback = String(searchErrors.text || root._searchStderr || "").trim()
        root.applySearch(output, fallback || "The lyric providers could not be reached.")
      }
      if (root.requestedQuery.length >= 2 && root.requestedQuery !== completedQuery) {
        root.searching = true
        Qt.callLater(root.launchSearch)
      } else if (root.requestedQuery.length < 2) {
        root.searching = false
      }
    }
  }

  Process {
    id: lyricsProcess
    running: false
    command: []

    stdout: StdioCollector {
      id: lyricsOutput
      waitForEnd: true
      onStreamFinished: root._lyricsStdout = text
    }
    stderr: StdioCollector {
      id: lyricsErrors
      waitForEnd: true
      onStreamFinished: root._lyricsStderr = text
    }
    onExited: function() {
      var completedKey = root.runningLyricsKey
      var current = completedKey !== "" && completedKey === root.requestedLyricsKey
      if (current) {
        var output = String(lyricsOutput.text || root._lyricsStdout || "")
        var fallback = String(lyricsErrors.text || root._lyricsStderr || "").trim()
        root.applyLyrics(output, fallback || "The lyric providers could not be reached.")
      }
      if (root.requestedLyricsKey !== "" && root.requestedLyricsKey !== completedKey) {
        root.loadingLyrics = true
        Qt.callLater(root.launchLyrics)
      } else if (root.requestedLyricsKey === "") {
        root.loadingLyrics = false
      }
    }
  }
}
