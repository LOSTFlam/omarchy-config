// Progress persistence and stat calculations for the Touch Type trainer.
// Pure JS, no imports — operates on plain JSON-shaped objects so it can be
// round-tripped straight to/from FileView.setText()/text().
.pragma library

function defaultProgress() {
  return {
    version: 1,
    levels: {},
    keyStats: {},
    streak: { count: 0, lastDay: "" },
    totals: { sessions: 0, timeMs: 0 },
    unlockAll: false
  }
}

function todayString(date) {
  date = date || new Date()
  var y = date.getFullYear()
  var m = String(date.getMonth() + 1).padStart(2, "0")
  var d = String(date.getDate()).padStart(2, "0")
  return y + "-" + m + "-" + d
}

function daysBetween(a, b) {
  var da = new Date(a + "T00:00:00")
  var db = new Date(b + "T00:00:00")
  return Math.round((db.getTime() - da.getTime()) / 86400000)
}

// Safely merges a possibly-partial/legacy JSON blob onto the defaults so a
// corrupt or missing progress file never crashes the plugin.
function parse(raw) {
  var base = defaultProgress()
  if (!raw) return base
  var data
  try { data = JSON.parse(raw) } catch (e) { return base }
  if (!data || typeof data !== "object") return base

  if (data.levels && typeof data.levels === "object") base.levels = data.levels
  if (data.keyStats && typeof data.keyStats === "object") base.keyStats = data.keyStats
  if (data.streak && typeof data.streak === "object") {
    base.streak.count = Number(data.streak.count) || 0
    base.streak.lastDay = typeof data.streak.lastDay === "string" ? data.streak.lastDay : ""
  }
  if (data.totals && typeof data.totals === "object") {
    base.totals.sessions = Number(data.totals.sessions) || 0
    base.totals.timeMs = Number(data.totals.timeMs) || 0
  }
  if (data.unlockAll !== undefined) base.unlockAll = !!data.unlockAll
  return base
}

function toJsonText(progress) {
  return JSON.stringify(progress, null, 2) + "\n"
}

function isUnlocked(progress, levelList, index) {
  if (progress.unlockAll) return true
  if (index <= 0) return true
  var prev = levelList[index - 1]
  var entry = progress.levels[prev.id]
  return !!(entry && entry.passed)
}

function levelEntry(progress, levelId) {
  return progress.levels[levelId] || { passed: false, bestAccuracy: 0, bestWpm: 0, attempts: 0 }
}

function computeWpm(correctChars, elapsedMs) {
  if (elapsedMs <= 0) return 0
  var minutes = elapsedMs / 60000
  return Math.round((correctChars / 5) / minutes)
}

function computeAccuracy(correct, total) {
  if (total <= 0) return 100
  return Math.round((correct / total) * 1000) / 10
}

// Records one completed session against a level. `result` is
// { accuracy, wpm, timeMs, keyResults: { char: { hits, misses } } }.
// Returns a NEW progress object (shallow-cloned where mutated) — callers
// should reassign their bound property to it so QML bindings refresh.
function recordAttempt(progress, level, result) {
  var next = JSON.parse(JSON.stringify(progress))

  var entry = next.levels[level.id] || { passed: false, bestAccuracy: 0, bestWpm: 0, attempts: 0 }
  entry.attempts = (entry.attempts || 0) + 1
  entry.bestAccuracy = Math.max(entry.bestAccuracy || 0, result.accuracy)
  entry.bestWpm = Math.max(entry.bestWpm || 0, result.wpm)
  var passesAccuracy = result.accuracy >= level.passAccuracy
  var passesWpm = level.passWpm <= 0 || result.wpm >= level.passWpm
  if (passesAccuracy && passesWpm) entry.passed = true
  next.levels[level.id] = entry

  for (var key in result.keyResults) {
    var stat = next.keyStats[key] || { hits: 0, misses: 0 }
    stat.hits += result.keyResults[key].hits || 0
    stat.misses += result.keyResults[key].misses || 0
    next.keyStats[key] = stat
  }

  next.totals.sessions += 1
  next.totals.timeMs += result.timeMs || 0

  var today = todayString()
  if (next.streak.lastDay !== today) {
    var gap = next.streak.lastDay ? daysBetween(next.streak.lastDay, today) : null
    next.streak.count = gap === 1 ? (next.streak.count || 0) + 1 : 1
    next.streak.lastDay = today
  }

  return { progress: next, passed: entry.passed, entry: entry }
}

// Returns up to `limit` keys sorted by miss rate (highest first), skipping
// keys with too little data to be meaningful.
function weakestKeys(progress, limit) {
  var out = []
  for (var key in progress.keyStats) {
    var stat = progress.keyStats[key]
    var total = stat.hits + stat.misses
    if (total < 4) continue
    out.push({ key: key, hits: stat.hits, misses: stat.misses, missRate: stat.misses / total })
  }
  out.sort(function(a, b) { return b.missRate - a.missRate })
  return out.slice(0, limit || 6)
}
