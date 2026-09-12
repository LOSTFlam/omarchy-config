.pragma library

// Shared helpers for the Wallarchy plugin surfaces. Anything that is pure
// data shaping lives here so BarWidget, Browser, and Service agree on it.

// Wallhaven has no topics endpoint, so the chips are a curated list rather
// than something fetched. They are ordinary tag searches — anything typed
// into the search box works the same way.
var TAGS = [
  "nature", "landscape", "minimal", "space", "mountains", "ocean",
  "forest", "city", "abstract", "dark", "sunset", "cyberpunk",
  "architecture", "aerial", "animals", "cars"
]

// Wallhaven's `categories` and `purity` parameters are three-character
// bitfields. For categories the positions are general / anime / people.
var CATEGORY_LABELS = ["General", "Anime", "People"]

var SORTINGS = [
  { label: "Top", value: "toplist" },
  { label: "Newest", value: "date_added" },
  { label: "Views", value: "views" },
  { label: "Favorites", value: "favorites" }
]

var RESOLUTIONS = [
  { label: "Any size", value: "" },
  { label: "1080p+", value: "1920x1080" },
  { label: "1440p+", value: "2560x1440" },
  { label: "4K+", value: "3840x2160" }
]

// Rotation choices, in minutes. 0 is "off" and is what a fresh config gets.
var INTERVALS = [
  { label: "Off", minutes: 0 },
  { label: "15m", minutes: 15 },
  { label: "30m", minutes: 30 },
  { label: "1h", minutes: 60 },
  { label: "3h", minutes: 180 },
  { label: "6h", minutes: 360 },
  { label: "Daily", minutes: 1440 }
]

// Process output is untrusted input as far as the shell process is concerned:
// a wedged curl or an API error page must not be able to blow up the parse.
function parseJson(raw, fallback, limit) {
  try {
    if (typeof raw !== "string") return fallback
    if (raw.length > (limit || 2097152)) return fallback
    var trimmed = raw.trim()
    if (trimmed === "") return fallback
    var parsed = JSON.parse(trimmed)
    return parsed === null || parsed === undefined ? fallback : parsed
  } catch (error) {
    return fallback
  }
}

function singleLine(value, max) {
  if (typeof value !== "string") return ""
  var flat = value.replace(/\s+/g, " ").trim()
  var limit = max || 200
  return flat.length > limit ? flat.slice(0, limit - 1) + "…" : flat
}

function isPhoto(row) {
  return !!row && typeof row.id === "string" && typeof row.thumb === "string"
}

function photoRows(parsed) {
  if (!Array.isArray(parsed)) return []
  var rows = []
  for (var i = 0; i < parsed.length; i++) {
    if (!isPhoto(parsed[i])) continue
    rows.push({
      id: parsed[i].id,
      thumb: parsed[i].thumb,
      preview: parsed[i].preview || parsed[i].thumb,
      color: parsed[i].color || "#222222",
      label: singleLine(parsed[i].label, 60),
      link: parsed[i].link || "https://wallhaven.cc",
      json: JSON.stringify(parsed[i])
    })
  }
  return rows
}

// ------------------------------------------------------------- bitfields

function normalizeBits(value) {
  var bits = typeof value === "string" ? value : ""
  bits = bits.replace(/[^01]/g, "")
  while (bits.length < 3) bits += "0"
  return bits.slice(0, 3)
}

function bitAt(value, index) {
  return normalizeBits(value).charAt(index) === "1"
}

// Turning every category off makes the API return nothing at all, which reads
// as a broken plugin rather than an empty filter — so the last one on stays on.
function toggleBit(value, index) {
  var bits = normalizeBits(value).split("")
  if (bits[index] === "1" && bits.join("").replace(/0/g, "").length <= 1) return bits.join("")
  bits[index] = bits[index] === "1" ? "0" : "1"
  return bits.join("")
}

// ---------------------------------------------------------------- labels

function labelFor(list, value, fallback) {
  for (var i = 0; i < list.length; i++)
    if (list[i].value === value) return list[i].label
  return fallback
}

function nextIn(list, value) {
  for (var i = 0; i < list.length; i++)
    if (list[i].value === value) return list[(i + 1) % list.length].value
  return list[0].value
}

function intervalLabel(minutes) {
  for (var i = 0; i < INTERVALS.length; i++)
    if (INTERVALS[i].minutes === minutes) return INTERVALS[i].label
  return minutes + "m"
}

function nextInterval(minutes) {
  var index = 0
  for (var i = 0; i < INTERVALS.length; i++)
    if (INTERVALS[i].minutes === minutes) index = i
  return INTERVALS[(index + 1) % INTERVALS.length].minutes
}

function categoryLabel(bits) {
  var on = []
  for (var i = 0; i < CATEGORY_LABELS.length; i++)
    if (bitAt(bits, i)) on.push(CATEGORY_LABELS[i])
  return on.length === CATEGORY_LABELS.length ? "All categories" : on.join(" + ")
}

function barTooltip(state) {
  var lines = []
  lines.push(state.photo && state.photo.id
    ? "Wallhaven " + state.photo.id + (state.photo.label ? " · " + state.photo.label : "")
    : "Wallarchy")
  lines.push(state.query ? "Search: " + state.query : "Filter: " + categoryLabel(state.categories))
  lines.push(state.rotateMinutes > 0
    ? "Rotating every " + intervalLabel(state.rotateMinutes)
    : "Rotation off")
  lines.push("Left: browse · Middle: next · Right: toggle rotation")
  return lines.join("\n")
}
