// Pure helpers for the Spotify plugin — formatting, row building, and the
// small bits of shared vocabulary (tabs, glyphs). No state lives here; the
// service owns data and the panel owns UI state.

.pragma library

var glyph = {
  spotify: "󰓇",
  play: "󰐊",
  pause: "󰏤",
  next: "󰒭",
  previous: "󰒮",
  shuffle: "󰒝",
  repeat: "󰑖",
  repeatOne: "󰑘",
  volumeHigh: "󰕾",
  volumeLow: "󰕿",
  volumeMute: "󰸈",
  heart: "󰋑",
  heartOutline: "󰋕",
  device: "󰓃",
  search: "󰍉",
  book: "󰂺",
  podcast: "󰦔",
  playlist: "󰲸",
  back: "󰅁",
  forward: "󰅂",
  refresh: "󰑐",
  refreshing: "󰑓",
  queue: "󰐕",
  check: "󰄬",
  artist: "󰠃",
  album: "󰀥",
  note: "󰝚",
  close: "󰅖",
  signOut: "󰍃",
  external: "󰏌"
}

var tabs = [
  { key: "search", label: "SEARCH", icon: glyph.search, hint: "1" },
  { key: "playlists", label: "PLAYLISTS", icon: glyph.playlist, hint: "2" },
  { key: "books", label: "BOOKS", icon: glyph.book, hint: "3" },
  { key: "podcasts", label: "PODCASTS", icon: glyph.podcast, hint: "4" }
]

function tabIndex(key) {
  for (var i = 0; i < tabs.length; i++) if (tabs[i].key === key) return i
  return 0
}

function tabAt(index) {
  var n = tabs.length
  return tabs[((index % n) + n) % n].key
}

// ---------------------------------------------------------------- formatting

function pad2(n) { return n < 10 ? "0" + n : String(n) }

// 1:05, 12:34, 1:02:03 — clock style for positions and track lengths.
function fmtTime(ms) {
  var total = Math.max(0, Math.floor((Number(ms) || 0) / 1000))
  var h = Math.floor(total / 3600)
  var m = Math.floor((total % 3600) / 60)
  var s = total % 60
  if (h > 0) return h + ":" + pad2(m) + ":" + pad2(s)
  return m + ":" + pad2(s)
}

// 42 min, 1 h 05 min — for episode/chapter lengths in list rows.
function fmtDuration(ms) {
  var total = Math.max(0, Math.round((Number(ms) || 0) / 60000))
  if (total < 1) return "<1 min"
  if (total < 60) return total + " min"
  var h = Math.floor(total / 60)
  var m = total % 60
  return m === 0 ? h + " h" : h + " h " + pad2(m) + " min"
}

var monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

// "2024-03-08" -> "Mar 8, 2024" (or just the year for year-only precision).
function fmtDate(iso) {
  var s = String(iso || "")
  var parts = s.split("-")
  if (parts.length >= 3) {
    var m = parseInt(parts[1], 10)
    var d = parseInt(parts[2], 10)
    var year = parts[0]
    var now = new Date()
    var label = monthNames[Math.max(0, Math.min(11, m - 1))] + " " + d
    return String(now.getFullYear()) === year ? label : label + ", " + year
  }
  return s
}

function fileUrl(path) {
  if (!path) return ""
  return "file://" + String(path).split("/").map(encodeURIComponent).join("/")
}

// Prefer the cached copy on disk; fall back to the CDN URL, which Qt's Image
// element loads over the network on its own.
function artSource(item) {
  if (!item) return ""
  if (item.artPath) return fileUrl(item.artPath)
  return item.art || ""
}

function typeGlyph(type) {
  switch (type) {
    case "track": return glyph.note
    case "album": return glyph.album
    case "artist": return glyph.artist
    case "playlist": return glyph.playlist
    case "show": return glyph.podcast
    case "episode": return glyph.podcast
    case "audiobook": return glyph.book
    case "chapter": return glyph.book
    default: return glyph.note
  }
}

function sectionLabel(type) {
  switch (type) {
    case "track": return "TRACKS"
    case "artist": return "ARTISTS"
    case "album": return "ALBUMS"
    case "playlist": return "PLAYLISTS"
    case "show": return "PODCASTS"
    case "episode": return "EPISODES"
    case "audiobook": return "AUDIOBOOKS"
    default: return String(type || "").toUpperCase()
  }
}

function joinParts(parts) {
  var out = []
  for (var i = 0; i < parts.length; i++) {
    var p = parts[i]
    if (p !== undefined && p !== null && String(p) !== "" && String(p) !== "0") out.push(String(p))
  }
  return out.join("  ·  ")
}

function countLabel(n, singular, plural) {
  var v = Number(n) || 0
  return v + " " + (v === 1 ? singular : (plural || singular + "s"))
}

// One-line secondary text under a row title.
function subtitle(item) {
  if (!item) return ""
  switch (item.type) {
    case "track": return joinParts([item.artists, item.album])
    case "episode": return joinParts([item.show, fmtDate(item.releaseDate), fmtDuration(item.durationMs)])
    case "chapter": {
      // Spotify usually names chapters "Chapter 3"; don't say it twice.
      var named = /^chapter\b/i.test(String(item.name || ""))
      return joinParts([!named && item.chapterNumber > 0 ? "Chapter " + item.chapterNumber : "", fmtDuration(item.durationMs)])
    }
    case "playlist": return joinParts([item.owner ? "by " + item.owner : "", item.count > 0 ? countLabel(item.count, "item") : ""])
    case "album": return joinParts([item.artists, item.year, item.totalTracks > 0 ? countLabel(item.totalTracks, "track") : ""])
    case "artist": return item.genres ? item.genres : "Artist"
    case "show": return joinParts([item.publisher, item.totalEpisodes > 0 ? countLabel(item.totalEpisodes, "episode") : ""])
    case "audiobook": return joinParts([item.authors, item.narrators ? "read by " + item.narrators : "", item.totalChapters > 0 ? countLabel(item.totalChapters, "chapter") : ""])
    default: return ""
  }
}

// Playback progress for episodes/chapters that carry a resume point.
function progressFraction(item) {
  if (!item || !item.durationMs) return 0
  if (item.fullyPlayed) return 1
  var f = (Number(item.resumeMs) || 0) / Number(item.durationMs)
  return Math.max(0, Math.min(1, f))
}

function nextRepeat(mode) {
  if (mode === "off") return "context"
  if (mode === "context") return "track"
  return "off"
}

function repeatGlyph(mode) {
  return mode === "track" ? glyph.repeatOne : glyph.repeat
}

function volumeGlyph(volume) {
  var v = Number(volume)
  if (!isFinite(v) || v < 0) return glyph.volumeHigh
  if (v === 0) return glyph.volumeMute
  if (v < 50) return glyph.volumeLow
  return glyph.volumeHigh
}

function deviceGlyph(kind) {
  var k = String(kind || "").toLowerCase()
  if (k === "computer") return "󰍹"
  if (k === "smartphone") return "󰏲"
  if (k === "speaker") return "󰓃"
  if (k === "tv") return "󰔂"
  if (k === "avr" || k === "stb") return "󰤽"
  if (k === "castaudio" || k === "castvideo") return "󱒵"
  if (k === "automobile") return "󰄋"
  if (k === "game_console") return "󰊴"
  return "󰓃"
}

// Whether opening the item drills into a list (vs. just playing it).
function opensDetail(item) {
  if (!item) return false
  return item.type === "playlist" || item.type === "album" || item.type === "show" || item.type === "audiobook"
}

function detailKindFor(item) {
  if (!item) return ""
  if (item.type === "playlist") return item.id === "__liked__" ? "liked" : "playlist"
  if (item.type === "album") return "album"
  if (item.type === "show") return "show"
  if (item.type === "audiobook") return "audiobook"
  return ""
}

// ------------------------------------------------------------------- rows
//
// Every tab and detail page renders the same flat row list so a single
// keyboard cursor can walk it: `header` rows are skipped by the cursor,
// `item` rows activate, and `note`/`loading` rows are inert copy.

function headerRow(label) { return { kind: "header", label: label } }
function noteRow(text, dim) { return { kind: "note", text: text, dim: dim !== false } }
function itemRow(item, extra) {
  var row = { kind: "item", item: item, key: item.uri || item.id || item.name }
  if (extra) for (var k in extra) row[k] = extra[k]
  return row
}

function searchRows(results, recent, query, searching, error) {
  var rows = []
  if (error) rows.push(noteRow(error, false))
  if (query.trim() === "") {
    if (recent && recent.length > 0) {
      rows.push(headerRow("RECENTLY PLAYED"))
      for (var i = 0; i < recent.length; i++) rows.push(itemRow(recent[i]))
    } else if (!searching) {
      rows.push(noteRow("Type to search tracks, artists, albums, playlists, podcasts, episodes and audiobooks."))
    }
    return rows
  }
  if (searching && (!results || results.query !== query.trim())) {
    rows.push(noteRow("Searching…"))
    return rows
  }
  if (!results || results.query !== query.trim()) return rows
  if (!results.groups || results.groups.length === 0) {
    rows.push(noteRow("No results for “" + query.trim() + "”."))
    return rows
  }
  for (var g = 0; g < results.groups.length; g++) {
    var group = results.groups[g]
    rows.push(headerRow(sectionLabel(group.type)))
    for (var j = 0; j < group.items.length; j++) rows.push(itemRow(group.items[j]))
  }
  return rows
}

function libraryRows(items, loading, error, emptyText) {
  var rows = []
  if (error) rows.push(noteRow(error, false))
  if (loading && (!items || items.length === 0)) {
    rows.push(noteRow("Loading…"))
    return rows
  }
  if (!items || items.length === 0) {
    if (!error) rows.push(noteRow(emptyText))
    return rows
  }
  for (var i = 0; i < items.length; i++) rows.push(itemRow(items[i]))
  return rows
}

function detailRows(detail) {
  var rows = []
  if (!detail) return rows
  if (detail.error) rows.push(noteRow(detail.error, false))
  if (detail.loading && (!detail.items || detail.items.length === 0)) {
    rows.push(noteRow("Loading…"))
    return rows
  }
  if (!detail.items || detail.items.length === 0) {
    if (!detail.error) rows.push(noteRow(detail.kind === "playlist"
      ? "Spotify only lists tracks for playlists you own or collaborate on. Play still works."
      : "Nothing here yet."))
    return rows
  }
  for (var i = 0; i < detail.items.length; i++) rows.push(itemRow(detail.items[i], { index: i }))
  if (detail.total > detail.items.length) rows.push(noteRow("Showing the first " + detail.items.length + " of " + detail.total + "."))
  return rows
}

function firstItemIndex(rows, from, step) {
  if (!rows || rows.length === 0) return -1
  var i = from
  var guard = 0
  while (guard++ < rows.length) {
    i = ((i % rows.length) + rows.length) % rows.length
    if (rows[i].kind === "item") return i
    i += step
  }
  return -1
}

function hasItems(rows) {
  for (var i = 0; i < rows.length; i++) if (rows[i].kind === "item") return true
  return false
}

// -------------------------------------------------------------- misc text

function conciseError(text, fallback) {
  var s = String(text || fallback || "Spotify request failed").replace(/\s+/g, " ").trim()
  return s.length > 160 ? s.substring(0, 157) + "…" : s
}

function heroTitle(player) {
  if (!player || !player.active) return "Nothing playing"
  var item = player.item
  return item && item.name ? item.name : "Nothing playing"
}

function heroSubtitle(player) {
  if (!player || !player.active || !player.item) return ""
  var item = player.item
  switch (item.type) {
    case "track": return joinParts([item.artists, item.album])
    case "episode": return joinParts([item.show, fmtDate(item.releaseDate)])
    case "chapter": return joinParts([item.book, item.chapterNumber > 0 ? "Chapter " + item.chapterNumber : ""])
    default: return subtitle(item)
  }
}

function setupSteps(port) {
  return [
    "Open developer.spotify.com/dashboard and create an app.",
    "Add the redirect URI  http://127.0.0.1:" + port + "/callback  and enable the Web API.",
    "Paste the app's Client ID below, then Connect. Spotify Premium is required."
  ]
}

// The desktop app is the Spotify Connect device the panel drives. Reuse
// Omarchy's own installer so the package choice stays theirs.
var installCommand = "omarchy install service spotify"

// ---------------------------------------------------------------------------
// Trusted executables and closed environments
//
// The shell never starts a program through the session PATH and never hands
// one the session environment:
//  - the bridge runs as `<absolute python3> -I -B bin/spotify-bridge …`. -I
//    ignores every PYTHON* variable and user site-packages and keeps the
//    script's own directory off sys.path. The interpreter is found by a
//    startup probe over pythonCandidates, never via `#!/usr/bin/env`.
//  - its environment is cleared down to bridgeEnvironmentNames and a fixed PATH.
//  - detached launches (the Spotify app, Omarchy's launch-or-focus and
//    floating-terminal scripts) use absolute paths the bridge resolved from
//    root-owned directories, accepted here only inside those directories and
//    only under the expected name, with the environment cleared down to
//    launchEnvironmentNames.
// ---------------------------------------------------------------------------

// /usr/local/bin and anything under $HOME are deliberately absent: those are
// the usual landing spots for a shadow binary.
var trustedBinaryDirectories = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/run/current-system/sw/bin"]
// Omarchy's own scripts ship in its tree.
var trustedOmarchyDirectories = ["/usr/share/omarchy/bin", "/usr/local/share/omarchy/bin"]
var trustedPathEnvironment = trustedBinaryDirectories.join(":")
// Omarchy's launcher scripts name their helpers (uwsm-app, xdg-terminal-exec,
// omarchy-show-logo) bare, so their PATH carries the Omarchy tree as well —
// still no directory a user can write to.
var trustedSessionPathEnvironment = trustedBinaryDirectories.concat(["/usr/share/omarchy/bin"]).join(":")

var pythonCandidates = ["/usr/bin/python3", "/bin/python3", "/run/current-system/sw/bin/python3"]
var pythonVersionCheck = "import sys; sys.exit(0 if sys.version_info >= (3, 8) else 3)"

// The bridge keeps its XDG directories, the session bus for
// `systemctl --user`, and the display handles the one-time login needs to
// open a browser.
var bridgeEnvironmentNames = [
  "HOME", "USER", "LOGNAME", "LANG",
  "XDG_RUNTIME_DIR", "XDG_STATE_HOME", "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME",
  "DBUS_SESSION_BUS_ADDRESS", "WAYLAND_DISPLAY", "DISPLAY",
  "XDG_CURRENT_DESKTOP", "XDG_SESSION_TYPE", "XDG_SESSION_DESKTOP", "HYPRLAND_INSTANCE_SIGNATURE"
]

// A GUI launch additionally keeps the toolkit and input-method switches the
// session sets — which backend, which scale, which input method: names and
// numbers only. Anything that names a file or a program to load (LD_*,
// BASH_ENV, exported shell functions, QT_PLUGIN_PATH, TERMINAL, EDITOR,
// XDG_DATA_DIRS, proxies) is left behind.
var launchEnvironmentNames = bridgeEnvironmentNames.concat([
  "XDG_SESSION_ID", "XDG_SEAT", "XDG_BACKEND", "DESKTOP_SESSION",
  "GDK_BACKEND", "GDK_SCALE", "QT_QPA_PLATFORM", "QT_QPA_PLATFORMTHEME", "QT_IM_MODULE",
  "SDL_IM_MODULE", "XMODIFIERS", "INPUT_METHOD", "MOZ_ENABLE_WAYLAND",
  "ELECTRON_OZONE_PLATFORM_HINT", "OZONE_PLATFORM", "XCURSOR_SIZE", "HYPRCURSOR_SIZE",
  "_JAVA_AWT_WM_NONREPARENTING"
])

// Set to a fixed value rather than inherited: Omarchy's scripts locate their
// own tree through it.
var launchFixedEnvironment = { OMARCHY_PATH: "/usr/share/omarchy" }

// Clean absolute paths only: every component starts with a letter or digit,
// so no `..`, no hidden component, no whitespace or quoting characters.
var trustedExecutablePattern = /^\/[A-Za-z0-9][A-Za-z0-9._+-]*(?:\/[A-Za-z0-9][A-Za-z0-9._+-]*)*$/

function isObjectMap(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

// `value` when it is a clean absolute path directly inside one of
// `directories` (the system directories by default); "" otherwise.
function trustedExecutable(value, directories) {
  var text = typeof value === "string" ? value : ""
  if (text === "" || text.length > 256 || !trustedExecutablePattern.test(text)) return ""
  var allowed = directories || trustedBinaryDirectories
  return allowed.indexOf(text.substring(0, text.lastIndexOf("/"))) >= 0 ? text : ""
}

function basename(path) {
  return String(path).substring(String(path).lastIndexOf("/") + 1)
}

// A complete environment for a Process with clearEnvironment: the listed
// names that hold a bounded single-line value, then any fixed values, then
// PATH, which nothing inherited can override.
function closedEnvironment(inherited, names, path, fixed) {
  var environment = {}
  var source = isObjectMap(inherited) ? inherited : {}
  var list = Array.isArray(names) ? names : []
  for (var i = 0; i < list.length; i++) {
    var value = source[list[i]]
    if (typeof value !== "string" || value === "" || value.length > 4096) continue
    if (/[\x00-\x1f\x7f]/.test(value)) continue
    environment[list[i]] = value
  }
  if (isObjectMap(fixed)) for (var key in fixed) environment[key] = String(fixed[key])
  environment.PATH = String(path || trustedPathEnvironment)
  return environment
}

function pythonProbeCommand(candidate) {
  var python = trustedExecutable(candidate)
  return python === "" ? [] : [python, "-I", "-c", pythonVersionCheck]
}

// Empty (so nothing starts) unless the interpreter is trusted and the script
// path is absolute.
function bridgeCommand(python, bridgePath, args) {
  var interpreter = trustedExecutable(python)
  var script = typeof bridgePath === "string" ? bridgePath : ""
  if (interpreter === "" || script.charAt(0) !== "/" || /[\x00-\x1f\x7f]/.test(script)) return []
  var argv = [interpreter, "-I", "-B", script]
  var rest = Array.isArray(args) ? args : []
  for (var i = 0; i < rest.length; i++) argv.push(String(rest[i]))
  return argv
}

var launchToolDirectories = {
  "uwsm-app": trustedBinaryDirectories,
  "omarchy-launch-or-focus": trustedBinaryDirectories.concat(trustedOmarchyDirectories),
  "omarchy-launch-floating-terminal-with-presentation": trustedBinaryDirectories.concat(trustedOmarchyDirectories)
}

// A launcher path from the bridge's `tools` table, accepted only inside the
// directories allowed for that tool and only under that tool's own name.
function toolPath(tools, name) {
  var directories = launchToolDirectories[name]
  if (!directories || !isObjectMap(tools)) return ""
  var path = trustedExecutable(tools[name], directories)
  return path !== "" && basename(path) === name ? path : ""
}

function appLaunchCommand(tools, appBinary) {
  var uwsm = toolPath(tools, "uwsm-app")
  var app = trustedExecutable(appBinary)
  if (uwsm === "" || app === "" || (basename(app) !== "spotify" && basename(app) !== "spotify-launcher")) return []
  return [uwsm, "--", app]
}

function focusAppCommand(tools) {
  var focus = toolPath(tools, "omarchy-launch-or-focus")
  return focus === "" ? [] : [focus, "spotify"]
}

function installLaunchCommand(tools) {
  var terminal = toolPath(tools, "omarchy-launch-floating-terminal-with-presentation")
  return terminal === "" ? [] : [terminal, installCommand]
}
