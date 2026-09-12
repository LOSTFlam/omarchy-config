.pragma library

// Formatting and grouping for the pending-update panel. Kept out of the QML so
// the shapes here stay testable and the Panel stays layout.
//
// This file is also the panel's intake. Everything the scan prints goes
// through parseReport() before any of it reaches a QML model, where it is
// re-capped in rows and in string length and reduced to the exact fields the
// panel renders. The scan already caps both, but the shell has to survive a
// document it did not produce, and a Repeater turns rows into delegates that
// live as long as the shell does.

// Row caps, matching bin/omarchy-update-scan. The scan is the one that can
// still report the true totals, so these should only ever fire on a document
// that came from somewhere else.
var MAX_ROWS = { packages: 250, aur: 100, dev: 50 }

// Package names, versions and repositories are short. Anything longer than
// this is not a name that will be read, it is something trying to be a layout.
var MAX_NAME = 120
var MAX_VERSION = 80
var MAX_REPO = 40
var MAX_ERROR = 240

// The scan caps its own stdout at 512 KiB. A document larger than that did not
// come from the scan, and parsing it would be the shell's problem, not ours.
var MAX_RAW_CHARS = 512 * 1024

// ---------------------------------------------------------------------------
// Intake
// ---------------------------------------------------------------------------

// Strip control characters and cap length. Everything the panel renders passes
// through here and is then drawn by a Text.PlainText item, so a package name
// can neither reflow the panel nor reach Qt's rich-text parser.
function cleanString(value, limit) {
  var text = String(value === undefined || value === null ? "" : value)
  text = text.replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, "")
  var max = limit || MAX_NAME
  return text.length > max ? text.substring(0, max - 1) + "\u2026" : text
}

// For the few strings handed to a shared component whose textFormat this
// plugin does not own (PanelHero, the bar tooltip). Angle brackets are dropped
// so nothing markup-shaped can reach rich-text handling there either.
function plain(value, limit) {
  return cleanString(value, limit).replace(/[<>]/g, "")
}

function counted(value) {
  var n = Number(value)
  return isFinite(n) && n > 0 ? Math.floor(n) : 0
}

// The panel renders exactly two tags and nothing else.
function cleanTag(tag) {
  return tag === "reboot" || tag === "restart" ? tag : ""
}

// One row, reduced to the six fields a ChangeRow draws. Unknown keys are
// dropped rather than carried into the model.
function packageRow(row) {
  if (!row || typeof row !== "object")
    return null
  return {
    name: cleanString(row.name, MAX_NAME),
    from: cleanString(row.from, MAX_VERSION),
    to: cleanString(row.to, MAX_VERSION),
    repo: cleanString(row.repo, MAX_REPO),
    bytes: counted(row.bytes),
    tag: cleanTag(row.tag)
  }
}

function rowList(value, limit) {
  if (!Array.isArray(value))
    return []
  var out = []
  for (var i = 0; i < value.length && out.length < limit; i++) {
    var row = packageRow(value[i])
    if (row && row.name !== "")
      out.push(row)
  }
  return out
}

function devList(value, limit) {
  if (!Array.isArray(value))
    return []
  var out = []
  for (var i = 0; i < value.length && out.length < limit; i++) {
    var c = value[i]
    if (c && typeof c === "object")
      out.push({ hash: cleanString(c.hash, 40), subject: cleanString(c.subject, 200) })
  }
  return out
}

// Turn the scan's stdout into the document the panel renders, or null when it
// is not one this panel understands. Null is the caller's cue to say so rather
// than render half a document.
function parseReport(raw) {
  var text = String(raw === undefined || raw === null ? "" : raw)
  if (text.length === 0 || text.length > MAX_RAW_CHARS)
    return null
  var parsed
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    return null
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed))
    return null

  var doc = {
    ok: parsed.ok === true,
    error: cleanString(parsed.error, MAX_ERROR),
    omarchy: packageRow(parsed.omarchy),
    packages: rowList(parsed.packages, MAX_ROWS.packages),
    aur: rowList(parsed.aur, MAX_ROWS.aur),
    dev: devList(parsed.dev, MAX_ROWS.dev),
    totalBytes: counted(parsed.totalBytes),
    restartCount: counted(parsed.restartCount)
  }
  if (doc.omarchy && doc.omarchy.name === "")
    doc.omarchy = null

  // The scan reports what it saw before its own cap; a document that does not
  // carry counts is assumed to be showing everything it has.
  var reported = parsed.counts && typeof parsed.counts === "object" ? parsed.counts : {}
  doc.counts = {
    packages: Math.max(counted(reported.packages), doc.packages.length),
    aur: Math.max(counted(reported.aur), doc.aur.length),
    dev: Math.max(counted(reported.dev), doc.dev.length)
  }
  doc.omitted = {
    packages: doc.counts.packages - doc.packages.length,
    aur: doc.counts.aur - doc.aur.length,
    dev: doc.counts.dev - doc.dev.length
  }
  return doc
}

function formatBytes(bytes) {
  if (!bytes || bytes <= 0)
    return ""
  var units = ["B", "KiB", "MiB", "GiB"]
  var value = bytes
  var i = 0
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024
    i++
  }
  return (i === 0 || value >= 100 ? Math.round(value) : value.toFixed(1)) + " " + units[i]
}

// The whole update, not the part that fits. A capped list still has to
// summarise honestly, or the header undercounts exactly when the count is the
// thing that should give you pause.
function packageCount(data) {
  if (!data)
    return 0
  var counts = data.counts || {}
  var n = Math.max(counted(counts.packages), (data.packages || []).length)
    + Math.max(counted(counts.aur), (data.aur || []).length)
  return n + (data.omarchy ? 1 : 0)
}

// Said out loud under the list when rows were dropped. Never silently.
function omittedNote(data) {
  if (!data)
    return ""
  var omitted = data.omitted || {}
  var n = counted(omitted.packages) + counted(omitted.aur)
  if (n === 0)
    return ""
  return n + (n === 1 ? " more package is" : " more packages are")
    + " not listed here. Run omarchy-update in a terminal for the full list."
}

// One line of consequence, for the panel header and the bar tooltip. Size is
// what the update will pull down; count is what it will replace.
function summary(data) {
  if (!data)
    return ""
  var parts = []
  var n = packageCount(data)
  parts.push(n + (n === 1 ? " package" : " packages"))
  var size = formatBytes(data.totalBytes)
  if (size !== "")
    parts.push(size)
  return parts.join(" . ")
}

function needsReboot(data) {
  if (!data)
    return false
  return (data.packages || []).some(function (p) {
    return p.tag === "reboot"
  })
}

// The bar tooltip. Says what is waiting and what clicking will do, because the
// icon alone has never been able to say either.
function tooltip(data, loading) {
  if (loading)
    return "Checking what is pending..."
  if (!data)
    return "Pending Omarchy updates. Click to review."
  if (!data.ok)
    return plain(data.error, MAX_ERROR) || "Could not read pending updates."
  var line = summary(data) + " pending"
  if (needsReboot(data))
    line += ", reboot after"
  return line + ". Click to review."
}

// Sections, most consequential first. A package with a tag changes something
// that is currently running; everything else lands quietly on disk.
function sections(data) {
  if (!data || !data.ok)
    return []
  var out = []
  var packages = data.packages || []

  var tagged = packages.filter(function (p) {
    return p.tag
  })
  if (tagged.length > 0)
    out.push({
      title: "NEEDS A RESTART",
      note: "These replace something that is running right now.",
      rows: tagged
    })

  var rest = packages.filter(function (p) {
    return !p.tag
  })
  if (rest.length > 0)
    out.push({
      title: "EVERYTHING ELSE",
      note: "",
      rows: rest
    })

  var aur = (data.aur || []).map(function (p) {
    return {
      name: p.name,
      from: p.from,
      to: p.to,
      repo: "aur",
      bytes: 0,
      tag: ""
    }
  })
  if (aur.length > 0)
    out.push({
      title: "AUR",
      note: "Built on your machine, not downloaded.",
      rows: aur
    })

  return out
}

// Right-hand label on a row. Size when known, otherwise the repo, so a row is
// never blank on the right while its neighbours are filled.
function rowMeta(row) {
  var size = formatBytes(row.bytes)
  if (size !== "")
    return size
  return row.repo || ""
}

// PanelHero is a shared component and sets no textFormat, so what goes into it
// is flattened here instead. Omarchy's own version move is the headline; the
// availability check's one-line summary is the fallback before a scan lands.
function heroTitle(data, availableSummary) {
  // Flattened per part, then joined. Flattening the finished sentence would
  // eat the arrow along with the angle brackets it is guarding against.
  if (data && data.omarchy)
    return "Omarchy " + plain(data.omarchy.from, 60) + " -> " + plain(data.omarchy.to, 60)
  var summary = plain(availableSummary, 160)
  return summary !== "" ? summary : "System update"
}

function tagLabel(tag) {
  if (tag === "reboot")
    return "reboot"
  if (tag === "restart")
    return "restart"
  return ""
}

// Node sees a plain script (the .pragma line is stripped by the test runner);
// QML ignores this because `module` is undefined there.
if (typeof module !== "undefined") {
  module.exports = {
    MAX_ROWS: MAX_ROWS,
    cleanString: cleanString,
    plain: plain,
    parseReport: parseReport,
    formatBytes: formatBytes,
    packageCount: packageCount,
    omittedNote: omittedNote,
    summary: summary,
    needsReboot: needsReboot,
    tooltip: tooltip,
    sections: sections,
    rowMeta: rowMeta,
    tagLabel: tagLabel,
    heroTitle: heroTitle
  }
}
