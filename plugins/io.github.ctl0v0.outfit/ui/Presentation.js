.pragma library

function densityName(value) {
  return viewModes().indexOf(value) >= 0 ? value : "comfortable"
}

function viewModes() {
  return ["comfortable", "compact", "dense", "list"]
}

function densityProfile(value) {
  var name = densityName(value)
  if (name === "list")
    return {name:name, minimumWidth:0, previewHeight:63, padding:8, spacing:2, gridGap:4, descriptionLines:2, footerHeight:20}
  if (name === "compact")
    return {name:name, minimumWidth:260, previewHeight:120, padding:8, spacing:4, gridGap:8, descriptionLines:4, footerHeight:20}
  if (name === "dense")
    return {name:name, minimumWidth:240, previewHeight:96, padding:8, spacing:3, gridGap:6, descriptionLines:4, footerHeight:20}
  return {name:name, minimumWidth:290, previewHeight:160, padding:10, spacing:5, gridGap:8, descriptionLines:4, footerHeight:24}
}

function listLayout(width, mediumWidth, wideWidth) {
  var wide = width >= (wideWidth === undefined ? 1000 : wideWidth)
  var side = width >= (mediumWidth === undefined ? 640 : mediumWidth)
  return {sideStatus:side, thumbnailWidth:wide ? 112 : side ? 96 : 80,
    minimumHeight:wide ? 96 : side ? 112 : 136, descriptionLines:wide ? 2 : 3, reasonLines:wide ? 1 : 2}
}

function listStatus(known, installed, enabled, queued, firstParty, kind) {
  return {
    primary: !known ? "Inventory pending" : installed ? "Installed" : queued ? "In batch" : "",
    secondary: known && installed ? (enabled ? "Enabled" : "Disabled") : !known && queued ? "In batch" : "",
    source: String(kind || "Plugin")
  }
}

function pluginKinds(row) {
  return Array.isArray(row.kinds) && row.kinds.length
    ? row.kinds.join(" · ") : String(row.kind || "Plugin")
}

function cardColumns(width, minimum, gap) {
  return Math.max(1, Math.floor((Math.max(0, width) + gap) / (minimum + gap)))
}

// Category sections keep controls near their labels, even on ultrawide windows.
function sectionColumns(width, minimum, gap) {
  return Math.max(1, Math.floor((Math.max(0, width) + gap) / (minimum + gap)))
}

function metricLayout(width, leftMinimum, rightMinimum, gap) {
  // Keep the two groups close, with a small shared inset for each column.
  // Extra card width belongs to the surrounding card, not stretched cells.
  if (width < leftMinimum + rightMinimum + gap)
    return {columns:1, left:width, right:width}
  var inset = Math.min(gap, (width - leftMinimum - rightMinimum - gap) / 4)
  return {columns:2, left:leftMinimum + inset * 2, right:rightMinimum + inset * 2}
}

// Natural icon/count widths; spend the gaps before adding another metric row.
function naturalMetricLayout(width, widths, preferredGap, minimumGap) {
  var total = widths.reduce(function(sum, value) { return sum + value }, 0)
  var gaps = Math.max(0, widths.length - 1)
  if (width >= total + minimumGap * gaps)
    return {columns:Math.max(1, widths.length), gap:gaps ? Math.min(preferredGap, (width - total) / gaps) : 0}
  var left = 0, right = 0
  for (var i = 0; i < widths.length; i++) {
    if (i % 2 === 0) left = Math.max(left, widths[i])
    else right = Math.max(right, widths[i])
  }
  return {columns:width >= left + right + minimumGap ? 2 : 1,
    gap:Math.max(minimumGap, Math.min(preferredGap, width - left - right))}
}

function anchoredScroll(current, oldOffset, newOffset, contentHeight, viewportHeight) {
  return Math.max(0, Math.min(current + newOffset - oldOffset, contentHeight - viewportHeight))
}

function countLabel(label, value, known) {
  var number = Number(value)
  var count = known === false || value === null || value === undefined
    || !isFinite(number) || number < 0 ? "—" : String(Math.floor(number))
  return String(label) + " (" + count + ")"
}

function relativeAge(seconds, nowMilliseconds) {
  var timestamp = Number(seconds)
  var now = Number(nowMilliseconds)
  if (!isFinite(timestamp) || timestamp <= 0 || !isFinite(now)) return "Not yet"
  var elapsed = (now - timestamp * 1000) / 1000
  if (elapsed < -60) return "Time unavailable"
  if (elapsed < 60) return "Just now"
  if (elapsed < 3600) return Math.floor(elapsed / 60) + "m ago"
  if (elapsed < 86400) return Math.floor(elapsed / 3600) + "h ago"
  return Math.floor(elapsed / 86400) + "d ago"
}

function completion(action, automatic, hasError) {
  if (hasError) return ""
  if (action === "rescan" && automatic !== true) return "System updated"
  if (action === "refresh") return "Catalog updated"
  return ""
}
