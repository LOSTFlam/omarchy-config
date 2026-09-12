.pragma library

var STATE_PATH_SUFFIX = "/.local/state/omarchy/settings/theme-modes.json"
var MAX_OUTPUT_CHARS = 524288
var MAX_CATALOG_OUTPUT_CHARS = 524288
var MAX_BACKGROUND_OUTPUT_CHARS = 524288
var MAX_CATALOG_RECORDS = 256
var MAX_BACKGROUND_RECORDS = 256
var MAX_INPUT_LINE_CHARS = 256
var MAX_FIELD_CHARS = 4096
var MAX_STATE_CHARS = 65536

function statePath(home) {
  return String(home || "") + STATE_PATH_SUFFIX
}

function clampText(raw, max) {
  var text = String(raw || "")
  return text.length > max ? text.slice(0, max) : text
}

function isValidSlug(slug) {
  var key = String(slug || "")
  if (!key || key === "." || key === "..") return false
  return /^[a-z0-9]+$/.test(key) || /^[a-z0-9]+(?:[-_][a-z0-9]+)*$/.test(key)
}

function slugFromName(name) {
  var raw = String(name || "")
  if (/[/\\]|\.\./.test(raw)) return ""
  var cleaned = raw
    .replace(/<[^>]+>/g, "")
    .toLowerCase()
    .trim()
    .replace(/\s+/g, "-")
    .replace(/[^a-z0-9_-]+/g, "")
    .replace(/^[-_]+|[-_]+$/g, "")
    .replace(/[-_]{2,}/g, function(match) { return match.charAt(0) })
  return isValidSlug(cleaned) ? cleaned : ""
}

function isSafeLocalPath(path) {
  var text = String(path || "").trim()
  if (!text || text.indexOf("\0") >= 0) return false
  if (text.indexOf("..") >= 0) return false
  return text.charAt(0) === "/"
}

function defaultState(currentThemeSlug) {
  var slug = slugFromName(currentThemeSlug)
  return {
    lightTheme: slug || "flexoki-light",
    darkTheme: slug || "catppuccin",
    lightBackground: "",
    darkBackground: "",
    mode: "dark",
    manualOverride: true,
    autoEnabled: false,
    autoSource: "time",
    lightStart: "07:00",
    darkStart: "19:00",
    batteryDarkOnBattery: true
  }
}

function parseStateFile(raw, currentThemeSlug) {
  var base = defaultState(currentThemeSlug)
  var text = clampText(raw, MAX_STATE_CHARS)
  if (!text.trim()) return base

  try {
    var parsed = JSON.parse(text)
    if (!parsed || typeof parsed !== "object") return base
    if (parsed.lightTheme) {
      var light = slugFromName(parsed.lightTheme)
      if (light) base.lightTheme = light
    }
    if (parsed.darkTheme) {
      var dark = slugFromName(parsed.darkTheme)
      if (dark) base.darkTheme = dark
    }
    if (parsed.lightBackground && isSafeLocalPath(parsed.lightBackground))
      base.lightBackground = String(parsed.lightBackground)
    if (parsed.darkBackground && isSafeLocalPath(parsed.darkBackground))
      base.darkBackground = String(parsed.darkBackground)
    if (parsed.mode === "light" || parsed.mode === "dark") base.mode = parsed.mode
    if (typeof parsed.manualOverride === "boolean") base.manualOverride = parsed.manualOverride
    if (typeof parsed.autoEnabled === "boolean") base.autoEnabled = parsed.autoEnabled
    if (parsed.autoSource === "time" || parsed.autoSource === "battery") base.autoSource = parsed.autoSource
    if (parsed.lightStart) base.lightStart = normalizeTime(parsed.lightStart, base.lightStart)
    if (parsed.darkStart) base.darkStart = normalizeTime(parsed.darkStart, base.darkStart)
    if (typeof parsed.batteryDarkOnBattery === "boolean") base.batteryDarkOnBattery = parsed.batteryDarkOnBattery
  } catch (e) {
    return base
  }

  return base
}

function serializeState(state) {
  return JSON.stringify({
    lightTheme: slugFromName(state.lightTheme) || defaultState("").lightTheme,
    darkTheme: slugFromName(state.darkTheme) || defaultState("").darkTheme,
    lightBackground: isSafeLocalPath(state.lightBackground) ? String(state.lightBackground) : "",
    darkBackground: isSafeLocalPath(state.darkBackground) ? String(state.darkBackground) : "",
    mode: state.mode === "light" ? "light" : "dark",
    manualOverride: !!state.manualOverride,
    autoEnabled: !!state.autoEnabled,
    autoSource: state.autoSource === "battery" ? "battery" : "time",
    lightStart: normalizeTime(state.lightStart, "07:00"),
    darkStart: normalizeTime(state.darkStart, "19:00"),
    batteryDarkOnBattery: state.batteryDarkOnBattery !== false
  }, null, 2) + "\n"
}

function normalizeTime(value, fallback) {
  var text = String(value || fallback || "00:00").trim()
  var match = text.match(/^(\d{1,2}):(\d{2})$/)
  if (!match) return fallback
  var hour = Math.max(0, Math.min(23, parseInt(match[1], 10)))
  var minute = Math.max(0, Math.min(59, parseInt(match[2], 10)))
  return (hour < 10 ? "0" : "") + hour + ":" + (minute < 10 ? "0" : "") + minute
}

function parseTimeMinutes(value, fallbackMinutes) {
  var normalized = normalizeTime(value, minutesToTime(fallbackMinutes))
  var parts = normalized.split(":")
  return parseInt(parts[0], 10) * 60 + parseInt(parts[1], 10)
}

function minutesToTime(totalMinutes) {
  var mins = Math.max(0, Math.min(23 * 60 + 59, totalMinutes | 0))
  var hour = Math.floor(mins / 60)
  var minute = mins % 60
  return (hour < 10 ? "0" : "") + hour + ":" + (minute < 10 ? "0" : "") + minute
}

function parseThemeList(raw) {
  var lines = clampText(raw, MAX_OUTPUT_CHARS).split("\n")
  var themes = []
  var seen = {}
  for (var i = 0; i < lines.length; i++) {
    var name = String(lines[i] || "").trim()
    if (!name) continue
    var slug = slugFromName(name)
    if (!slug || seen[slug]) continue
    seen[slug] = true
    themes.push({ name: name, slug: slug, previewPath: "" })
  }
  return themes
}

function parseThemeCatalog(raw) {
  var text = clampText(raw, MAX_CATALOG_OUTPUT_CHARS)
  if (!text.trim()) return []
  try {
    var parsed = JSON.parse(text)
    if (!Array.isArray(parsed)) return []
    var themes = []
    var seen = {}
    var limit = Math.min(parsed.length, MAX_CATALOG_RECORDS)
    for (var i = 0; i < limit; i++) {
      var entry = parsed[i]
      if (!entry || typeof entry !== "object") continue
      var name = String(entry.name || "").trim()
      if (name.length > MAX_INPUT_LINE_CHARS) name = name.slice(0, MAX_INPUT_LINE_CHARS)
      var slug = slugFromName(entry.slug || name)
      if (!name || !slug || seen[slug]) continue
      var previewPath = String(entry.previewPath || "").trim()
      if (previewPath && (!isSafeLocalPath(previewPath) || previewPath.length > MAX_FIELD_CHARS))
        previewPath = ""
      seen[slug] = true
      themes.push({
        name: name,
        slug: slug,
        previewPath: previewPath
      })
    }
    return themes
  } catch (e) {
    return []
  }
}

function displayNameForSlug(slug, themes) {
  var key = slugFromName(slug)
  for (var i = 0; i < themes.length; i++) {
    if (themes[i].slug === key) return themes[i].name
  }
  return key.replace(/-/g, " ").replace(/\b\w/g, function(c) { return c.toUpperCase() })
}

function themeForMode(state) {
  return state.mode === "light" ? slugFromName(state.lightTheme) : slugFromName(state.darkTheme)
}

function backgroundForMode(state) {
  var path = state.mode === "light" ? String(state.lightBackground || "") : String(state.darkBackground || "")
  return isSafeLocalPath(path) ? path : ""
}

function backgroundInList(path, backgrounds) {
  var target = String(path || "")
  if (!isSafeLocalPath(target)) return false
  for (var i = 0; i < backgrounds.length; i++) {
    if (backgrounds[i] && backgrounds[i].path === target) return true
  }
  return false
}

function parseBackgroundCatalog(raw) {
  var text = clampText(raw, MAX_BACKGROUND_OUTPUT_CHARS)
  if (!text.trim()) return []
  try {
    var parsed = JSON.parse(text)
    if (!Array.isArray(parsed)) return []
    var items = []
    var seen = {}
    var limit = Math.min(parsed.length, MAX_BACKGROUND_RECORDS)
    for (var i = 0; i < limit; i++) {
      var entry = parsed[i]
      if (!entry || typeof entry !== "object") continue
      var path = String(entry.path || "").trim()
      if (!isSafeLocalPath(path) || path.length > MAX_FIELD_CHARS || seen[path]) continue
      var thumbnailPath = String(entry.thumbnailPath || path).trim()
      if (!isSafeLocalPath(thumbnailPath) || thumbnailPath.length > MAX_FIELD_CHARS)
        thumbnailPath = path
      seen[path] = true
      items.push({
        path: path,
        name: String(entry.name || ""),
        thumbnailPath: thumbnailPath
      })
    }
    return items
  } catch (e) {
    return []
  }
}

function parseBootstrapPayload(raw) {
  var text = clampText(raw, MAX_STATE_CHARS + 512)
  if (!text.trim()) return { state: "", currentTheme: "" }
  try {
    var parsed = JSON.parse(text)
    if (!parsed || typeof parsed !== "object") return { state: "", currentTheme: "" }
    return {
      state: clampText(parsed.state, MAX_STATE_CHARS),
      currentTheme: clampText(parsed.currentTheme, 256)
    }
  } catch (e) {
    return { state: "", currentTheme: "" }
  }
}

function computeAutoMode(state, onBattery, date) {
  if (!state.autoEnabled) return state.mode
  if (state.autoSource === "battery") {
    return onBattery ? "dark" : "light"
  }

  var now = date instanceof Date ? date : new Date()
  var current = now.getHours() * 60 + now.getMinutes()
  var lightStart = parseTimeMinutes(state.lightStart, 7 * 60)
  var darkStart = parseTimeMinutes(state.darkStart, 19 * 60)
  if (lightStart === darkStart) return state.mode

  if (lightStart < darkStart) {
    return (current >= lightStart && current < darkStart) ? "light" : "dark"
  }
  return (current >= lightStart || current < darkStart) ? "light" : "dark"
}

function statusLabel(state, onBattery) {
  if (state.manualOverride) return "Manual"
  if (!state.autoEnabled) return "Manual"
  if (state.autoSource === "battery") return onBattery ? "Auto · battery" : "Auto · AC"
  return "Auto · schedule"
}

function modeIcon(mode) {
  return mode === "light" ? "󰖙" : "󰖔"
}
