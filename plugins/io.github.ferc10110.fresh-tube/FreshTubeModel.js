.pragma library

// Pure helpers for the Fresh Tube panel: no Quickshell, no files, so Node can
// test them (tests/model.test.js).

var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

function text(value) {
  return value === undefined || value === null ? "" : String(value)
}

// "just now", "5 min ago", "3 h ago", "yesterday", "4 d ago", then "Sep 1".
function relativeTime(iso, nowMs) {
  var t = Date.parse(text(iso))
  if (isNaN(t)) return ""
  var now = nowMs === undefined ? Date.now() : nowMs
  var seconds = Math.max(0, Math.round((now - t) / 1000))
  if (seconds < 60) return "just now"
  var minutes = Math.floor(seconds / 60)
  if (minutes < 60) return minutes + " min ago"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + " h ago"
  var days = Math.floor(hours / 24)
  if (days === 1) return "yesterday"
  if (days < 7) return days + " d ago"
  var date = new Date(t)
  return MONTHS[date.getMonth()] + " " + date.getDate()
}

function pad(n) {
  return (n < 10 ? "0" : "") + n
}

// Local wall-clock time of an ISO stamp, "09:05".
function formatClock(iso) {
  var t = Date.parse(text(iso))
  if (isNaN(t)) return ""
  var date = new Date(t)
  return pad(date.getHours()) + ":" + pad(date.getMinutes())
}

// A quick sanity check before the script does the real resolution.
function looksLikeChannelInput(value) {
  var s = text(value).trim()
  if (s === "" || /\s/.test(s)) return false
  return /^UC[0-9A-Za-z_-]{22}$/.test(s) || /^@[A-Za-z0-9._-]+$/.test(s)
    || /^(https?:\/\/)?(www\.|m\.)?(youtube\.com|youtu\.be)(\/|$)/i.test(s)
}

// The playerCommand setting split into argv; the video URL goes last.
function playerArgs(command) {
  var parts = text(command).trim().split(/\s+/).filter(function(p) { return p !== "" })
  return parts.length > 0 ? parts : ["mpv"]
}

function playerName(command) {
  return playerArgs(command)[0]
}
