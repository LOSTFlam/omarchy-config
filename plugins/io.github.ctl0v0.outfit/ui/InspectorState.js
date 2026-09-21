.pragma library

// Presentation only. A listing (including a frozen discovery pick) is metadata;
// only the canonical inventory entry establishes installed/enabled/location state.
function section(value) {
  return ["left", "center", "right"].indexOf(String(value || "")) >= 0 ? String(value) : ""
}

function exclusive(row) {
  var kinds = Array.isArray(row.kinds) ? row.kinds : []
  return row.exclusiveActivation === true || kinds.indexOf("bar") >= 0
    || String(row.kind || "").toLowerCase() === "bar"
}

function installDefaults(row, rememberedSection) {
  return { enable: !exclusive(row), section: section(rememberedSection) || "right" }
}

function projectUrl(row) {
  var values = [row.repo, row.snapshotUrl]
  for (var i = 0; i < values.length; i++) {
    var url = String(values[i] || "")
    if (/^https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+(?:\/tree\/[0-9a-f]{40})?$/.test(url)) return url
  }
  var listing = String(row.marketplaceUrl || "")
  return /^https:\/\/plugins\.omarchy\.org\/plugin\.html\?id=[A-Za-z0-9._~%-]+$/.test(listing) ? listing : ""
}

function snapshotFor(identity, rows, saved) {
  for (var i = 0; i < rows.length; i++)
    if (String(rows[i].id || "") === identity) return rows[i]
  return saved && String(saved.id || "") === identity ? saved : null
}

function standardWindow(entry) {
  var kinds = entry && entry.kinds
  var known = ["bar", "bar-widget", "service", "panel", "overlay", "menu"]
  return Array.isArray(kinds) && kinds.length > 0 && kinds.length <= 8
    && kinds.every(function(kind) { return typeof kind === "string" && known.indexOf(kind) >= 0 })
    && kinds.some(function(kind) { return ["panel", "overlay", "menu"].indexOf(kind) >= 0 })
}

function eligibleUpdate(row) {
  return !!row && row.state === "available" && row.canUpdate === true && row.selfUpdate !== true
}

function sameUpdate(reviewed, current) {
  if (!reviewed || !current) return false
  return ["id", "name", "installedVersion", "availableVersion", "installedRevision", "availableRevision",
    "state", "canUpdate", "selfUpdate", "reason", "checkError"].every(function(key) {
      return reviewed[key] === current[key]
    })
}

function versionLabel(version, revision) {
  return String(version || "Unknown") + (revision ? " · " + String(revision).slice(0, 10) : "")
}

function updateTransition(row) {
  row = row || {}
  if (row.state === "customized") {
    return "Installed: " + versionLabel(row.installedVersion, row.installedRevision) + " · Local edits"
      + (row.availableVersion || row.availableRevision
        ? "\nUpstream: " + versionLabel(row.availableVersion, row.availableRevision)
        : "\nUpstream version unavailable")
  }
  if (row.state === "current" || !(row.availableVersion || row.availableRevision || row.expectedRevision))
    return "Installed: " + versionLabel(row.installedVersion, row.installedRevision)
  return versionLabel(row.installedVersion, row.expectedInstalledRevision || row.installedRevision)
    + " → " + versionLabel(row.availableVersion, row.expectedRevision || row.availableRevision)
    + (row.installedVersion && row.installedVersion === row.availableVersion
      && (row.expectedInstalledRevision || row.installedRevision) !== (row.expectedRevision || row.availableRevision)
      ? " · New changes" : "")
}

function updateStatus(row, loaded, error) {
  if (error && !row) return "Update check failed: " + error
  if (!row) return loaded ? "Update status unknown" : "Not checked for updates"
  var labels = {available:"Update available", current:"Up to date", blocked:"Manual review needed",
    customized:"Locally customized — automatic update unavailable", manual:"Manual update",
    unavailable:"Update status unavailable", managed:"Managed by Omarchy · Update with your system",
    development:"Development checkout · Update manually"}
  return (labels[row.state] || "Update status unknown")
    + (row.reason && row.state !== "customized" ? " · " + row.reason : "")
    + (row.checkError ? "\n" + row.checkError : "")
    + (error ? "\nLatest check could not refresh: " + error : "")
}

function updatePresentation(entry, info, context) {
  context = context || {}
  var ready = !!entry && context.inventoryReady === true
  var idle = ready && !context.mutationBusy && !context.batchRunning && !context.selfUpdateBusy && !context.updatesBusy
  var self = !!info && info.selfUpdate === true
  var available = !!info && info.state === "available"
  var ordinary = !!entry && entry.firstParty !== true && (!info || ["managed", "development"].indexOf(info.state) < 0)
  return {
    showVersions:!!entry,
    // The catalog's version must never stand in for the installed version.
    installedVersion:entry ? String(entry.installedVersion || "") : "",
    installedRevision:entry ? String(entry.installedRevision || "") : "",
    availableVersion:info ? String(info.availableVersion || "") : "",
    availableRevision:info ? String(info.availableRevision || "") : "",
    updateState:info ? String(info.state || "") : "",
    updateStatus:updateStatus(info, context.updatesLoaded, context.updatesError)
      + (self && (context.interestsDirty || context.settingsTouched)
        ? " · Save or discard settings and interest changes before updating Outfit." : ""),
    showUpdate:!!entry && available && (self || info.canUpdate === true),
    updateLabel:self ? "Update Outfit & reopen" : "Update",
    canUpdate:idle && available && (self ? !context.interestsDirty && !context.settingsTouched : info.canUpdate === true),
    showUpdateCheck:ordinary,
    canCheckUpdates:idle,
    updatesBusy:context.updatesBusy === true
  }
}

function resolve(row, entry, context) {
  row = row || {}
  context = context || {}
  var operation = context.operation || {}
  var installed = !!entry
  var known = context.inventoryReady === true
  var enabled = installed && entry.enabled === true
  var kinds = installed ? (Array.isArray(entry.kinds) ? entry.kinds : []) : (Array.isArray(row.kinds) ? row.kinds : [])
  var fullBar = installed ? kinds.indexOf("bar") >= 0 : exclusive(row)
  var widget = !fullBar && (installed ? kinds.indexOf("bar-widget") >= 0 : row.barWidget === true)
  var pending = operation.pending === true
  var checking = pending && operation.status === "checking"
  var failed = !pending && (operation.status === "failed" || operation.status === "partial"
    || Boolean(operation.error) || context.batchFailure === true)
  var batchOwned = (typeof operation.batchIndex === "number" && operation.batchIndex >= 0)
    || !!(operation.lastRequest && operation.lastRequest.batchItem)
    || context.batchFailure === true
  var protectedPlugin = String(row.id || "") === String(context.selfId || "io.github.ctl0v0.outfit") || String(row.id || "") === "io.github.ctl0v0.omafit"
  var canChange = known && !pending && !context.batchRunning && !context.selfUpdateBusy && !protectedPlugin
  var canToggle = canChange && installed && entry.canDisable === true && !failed
  var canActivateBar = canChange && installed && fullBar && entry.enabled === false && entry.active !== true && !failed
  var identity = String(row.id || "")
  var validIdentity = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/.test(identity) && identity.indexOf("..") < 0
  var supportedWindow = installed && entry.id === identity && validIdentity && standardWindow(entry)
  var canOpen = known && supportedWindow && enabled && !protectedPlugin && !pending && !failed
    && !context.batchRunning && !context.mutationBusy && !context.selfUpdateBusy
  var openHint = !installed ? "" : protectedPlugin ? "Outfit is already open."
    : !known ? "Open is unavailable until plugin inventory is confirmed."
    : !supportedWindow ? "This plugin has no confirmed standard panel, overlay, or menu to open."
    : !enabled ? "Open requires Omarchy to confirm that this plugin is enabled."
    : pending || context.batchRunning || context.mutationBusy || context.selfUpdateBusy ? "Wait for plugin changes to finish before opening."
    : failed ? "Resolve the previous plugin action before opening." : ""
  var actualSection = installed && entry.barSectionKnown !== false ? section(entry.barSection) : ""
  var draftSection = section(context.rememberedSection) || actualSection || "right"
  var direct = row.installAvailable === true
  var state = pending ? (checking ? "checking" : "pending")
    : failed ? "recovery" : !known ? "unknown" : installed ? "installed"
    : context.selected ? "selected" : direct ? "available" : "manual"
  var action = batchOwned && (pending || failed) ? "progress" : state === "recovery" ? "retry"
    : state === "selected" ? "review" : state === "available" ? "install"
    : state === "manual" ? "project" : state === "installed"
      ? (canActivateBar ? "activate" : entry.enabled === false && canToggle && !fullBar ? "enable" : canOpen ? "open" : "") : ""
  var lastAction = String(operation.lastAction || operation.action || "")
  var retryLabel = { "update-plugin": "Retry update", "install-plugin": "Retry installation", "enable-plugin": "Retry enabling",
    "disable-plugin": "Retry disabling", "place-plugin": "Retry placement", "remove-plugin": "Retry uninstall" }
  if (installed) retryLabel["install-plugin"] = "Finish installation"
  else retryLabel["remove-plugin"] = "Check plugin status"
  if (enabled) retryLabel["enable-plugin"] = "Check plugin status"
  else retryLabel["disable-plugin"] = "Check plugin status"
  var label = action === "progress" ? (context.batchKind === "update" ? "View batch update progress" : "View batch install progress") : action === "retry"
    ? (known ? retryLabel[lastAction] || "Check plugin status" : "Check plugin status") : action === "review" ? "Review batch install"
    : action === "install" ? "Install" : action === "project" ? "Open project page"
    : action === "activate" ? "Activate…" : action === "enable" ? "Enable" : action === "open" ? "Open" : ""
  var progress = { "update-plugin": "Updating plugin…", "install-plugin": "Installing plugin…", "enable-plugin": "Enabling plugin…",
    "disable-plugin": "Disabling plugin…", "place-plugin": "Moving widget…", "remove-plugin": "Uninstalling plugin…" }
  var message = checking ? String(operation.message || "Checking the resulting plugin state…")
    : pending ? String(operation.message || progress[lastAction] || "Updating plugin…")
    : failed ? String(operation.error || operation.partialError || operation.commandError
      || operation.message || "The previous action needs attention.") : ""
  if (!known && !pending) message += (message ? "\n" : "")
    + "Plugin inventory is not confirmed. Plugin changes are paused until a successful status check."
  return {
    state: state, action: action, primaryLabel: label, message: message,
    installed: installed, enabled: enabled, known: known, widget: widget,
    pending: pending, checking: checking, failed: failed, batchOwned: batchOwned,
    canChange: canChange, canInstall: canChange && !installed && direct && !failed,
    canToggle: canToggle, canOpen: canOpen, openHint: openHint, canActivateBar: canActivateBar,
    canRemove: canChange && installed && entry.firstParty !== true,
    canPlace: known && !pending && !context.batchRunning && !context.selfUpdateBusy && installed && widget && !failed,
    canQueue: canChange && !installed && (direct || context.selected === true) && !failed,
    actualSection: actualSection, selectedSection: enabled ? actualSection : draftSection,
    included: installed ? entry.firstParty === true : row.firstParty === true,
    exclusive: fullBar, projectUrl: projectUrl(row)
  }
}
