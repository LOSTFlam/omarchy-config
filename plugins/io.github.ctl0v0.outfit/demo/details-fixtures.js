.pragma library

// Deterministic, fictional data and in-memory transitions only. Each create()
// returns a fresh model; nothing is shared between prototype instances.
function states() {
  return ["available", "installed", "disabled", "service", "pending", "failed",
    "manual", "replacement", "long", "missing"]
}

function stateName(value) {
  return states().indexOf(value) >= 0 ? value : "available"
}

function create(value) {
  var name = stateName(value)
  var row = {
    id: "org.example.dockside", name: "Dockside", author: "North Quay Studio",
    version: "1.4.2", kind: "Bar widget · Panel",
    description: "Keep your current project, pinned notes, and focus timer one click from the bar.",
    summary: "A quiet home for the things you reach for all day.",
    stars: 1284, likes: 86, views: 18420, copies: 2367,
    recommendationScore: 94, score: 92, verification: "verified",
    requirements: "Omarchy 4 · A horizontal bar · No account required",
    matchReason: "Matches your interest in workspace tools and a quieter desktop.",
    readmeText: "# Dockside\n\nKeep a small set of useful things close without leaving your workspace. Dockside pairs a compact bar widget with a project popover.\n\n## A place to return to\n\nPin a project, keep three short notes, and start a focus session from one panel. The bar shows your current project and the remaining focus time.\n\n## Make it yours\n\nChoose the left, center, or right bar section. Placement and enabled state are independent: moving a disabled widget keeps it disabled.\n\n## About this preview\n\nDockside, its author, metrics, and screenshots are fictional. Every action in this design preview stays in memory.",
    sourceAvailable: true, marketplaceAvailable: true,
    matchUnread: true, matchLabel: "New interest match",
    reviewText: "Demo review · The fictional 1.4.2 release was checked for manifest structure, local entry points, and a working enable/disable lifecycle. This illustrates review copy; it is not a review of a real plugin."
  }
  var model = {
    scenario: name, row: row, hasMedia: true, known: true,
    installed: false, enabled: false, widget: true, exclusive: false,
    manual: false, selected: false, section: "right",
    installEnabled: true, installSection: "right",
    pending: false, operation: "", failed: false, error: "", notice: ""
  }
  if (name === "installed" || name === "disabled" || name === "failed") {
    model.installed = true
    model.enabled = name === "installed"
    model.installEnabled = model.enabled
  }
  if (name === "pending") {
    model.pending = true
    model.operation = "install"
  }
  if (name === "failed") {
    model.failed = true
    model.error = "Files installed; panel entry point was not registered (entry-point-not-found). Retry to finish installation."
  }
  if (name === "service") {
    row.id = "org.example.quiet-index"
    row.name = "Quiet Index"
    row.author = "Mossbank Collective"
    row.version = "0.9.3"
    row.kind = "Service"
    row.description = "Keep a lightweight index of your pinned project names ready for other shell tools."
    row.summary = "A background helper with no window or panel to open."
    row.requirements = "Omarchy 4 · No external service required"
    row.matchReason = "Matches your interest in local project tools."
    row.readmeText = "# Quiet Index\n\nA fictional background service for project-name lookups. It has no panel, widget, or Open action.\n\n## Controls\n\nEnable or disable the service, or remove it from this preview. All state is held in memory."
    row.stars = 214
    row.likes = 17
    row.views = 3206
    row.copies = 409
    row.matchUnread = false
    row.matchLabel = ""
    row.reviewText = "Demo review · This fictional service has no visual entry point. Its toggle and removal controls are illustrated here."
    model.hasMedia = false
    model.widget = false
    model.installed = true
    model.enabled = true
  }
  if (name === "manual") {
    row.id = "org.example.paper-route"
    row.name = "Paper Route"
    row.author = "Sundial Workshop"
    row.version = "0.3.0"
    row.kind = "Project"
    row.description = "Turn a short daily note into a tidy workspace checklist."
    row.summary = "An experimental project with manual setup instructions."
    row.verification = "unverified"
    row.requirements = "Manual setup · See the fictional project guide"
    row.matchReason = "Matches your interest in simple planning tools."
    row.readmeText = "# Paper Route\n\nThis fictional listing illustrates a project that cannot be installed directly.\n\n## Setup\n\nThe project page would explain manual setup. In this preview, the button displays a demo notice."
    row.stars = 38
    row.likes = 0
    row.views = 706
    row.copies = 19
    row.matchUnread = false
    row.matchLabel = ""
    row.reviewText = "Demo review · No review is available for this fictional manual-setup project."
    model.hasMedia = false
    model.widget = false
    model.manual = true
  }
  if (name === "replacement") {
    row.id = "org.example.tideline-bar"
    row.name = "Tideline"
    row.author = "North Quay Studio"
    row.version = "2.0.1"
    row.kind = "Bar"
    row.description = "A spare, full-width bar with room for your workspaces and the essentials."
    row.summary = "A complete bar with an explicit activation step."
    row.requirements = "Omarchy 4 · Replaces the entire bar"
    row.matchReason = "Matches your interest in minimal desktop layouts."
    row.readmeText = "# Tideline\n\nA fictional full-bar replacement, rather than an individual widget.\n\n## Activation\n\nUse this bar simulates selecting Tideline as the active bar. It has no widget position or ordinary enabled toggle. No desktop bar is changed by this preview."
    row.stars = 592
    row.likes = 43
    row.views = 8104
    row.copies = 1120
    row.matchUnread = false
    row.matchLabel = ""
    row.reviewText = "Demo review · A fictional full-bar replacement with explicit activation."
    model.hasMedia = false
    model.widget = false
    model.exclusive = true
    model.installed = true
    model.installEnabled = false
  }
  if (name === "long") {
    row.id = "org.example.dockside-extended"
    row.name = "Dockside — the deliberately unhurried workspace companion for projects, pinned notes, and everything you meant to come back to"
    row.author = "North Quay Interface Research and Everyday Tools Collective"
    row.version = "1.5.0-preview.12"
    row.stars = 1234567890
    row.likes = null
    row.views = 9876543210
    row.copies = 2147483647
    row.matchReason = "Matches workspace organization, focused writing, and project navigation, including unusually long project names that should wrap without hiding the controls."
  }
  if (name === "missing") {
    row = {
      id: "org.example.unlisted", name: "Unlisted plugin", author: "", version: "", kind: "",
      description: "", summary: "", stars: null, likes: null, views: null, copies: null,
      recommendationScore: null, score: null, verification: "unknown", requirements: "",
      matchReason: "", readmeText: "", sourceAvailable: false, marketplaceAvailable: false,
      matchUnread: false, matchLabel: "", reviewText: ""
    }
    model.row = row
    model.hasMedia = false
    model.widget = false
    model.known = false
  }
  if (!model.widget) {
    model.section = ""
    model.installSection = ""
  }
  return model
}

// Exactly the page's presentation contract. selected only drives the secondary
// batch control; it never replaces the primary install action.
function presentation(model) {
  var changeable = model.known && !model.pending
  var action = ""
  var label = ""
  if (model.pending) {
    label = model.operation === "remove" ? "Removing…"
      : model.operation === "retry" ? "Finishing installation…" : "Installing…"
  } else if (model.failed) {
    action = "retry"
    label = "Retry installation"
  } else if (model.exclusive) {
    action = model.enabled ? "" : "activate"
    label = model.enabled ? "Bar selected" : "Use this bar"
  } else if (model.manual) {
    action = "project"
    label = "Open project page"
  } else if (model.known && !model.installed) {
    action = "install"
    label = "Install"
  } else if (model.installed && !model.enabled) {
    action = "enable"
    label = "Enable"
  } else if (model.installed && model.widget) {
    action = "open"
    label = "Open"
  }
  return {
    installed: model.installed, enabled: model.enabled, known: model.known,
    widget: model.widget, exclusive: model.exclusive,
    canToggle: changeable && model.installed && !model.failed && !model.exclusive,
    canPlace: changeable && model.widget && !model.failed,
    canRemove: changeable && model.installed && !model.exclusive,
    canQueue: changeable && !model.installed && !model.manual && !model.exclusive && !model.failed,
    primaryLabel: label, primaryEnabled: changeable && action !== "", primaryAction: action,
    pending: model.pending, failed: model.failed, selected: model.selected,
    section: model.installed ? model.section : model.installSection,
    message: model.pending ? (label + " Demo operation; no files are changed.")
      : model.failed ? model.error : !model.known ? "Listing details and plugin state are unavailable."
      : model.exclusive && !model.enabled ? "Installed · Inactive full-bar replacement" : "",
    openHint: action === "open" ? "Show a fictional Dockside panel inside this preview." : ""
  }
}

function copy(model) {
  var result = {}
  Object.keys(model).forEach(function(key) { result[key] = model[key] })
  return result
}

// Returns a new object for QML bindings; review replaces rather than mutates
// row metadata so existing snapshots and other instances remain unchanged.
// UI-only effects (panel and confirmation) belong to DetailPrototype.qml.
function transition(model, event, value) {
  var p = presentation(model)
  var next = copy(model)
  if (event === "notice") {
    next.notice = String(value || "")
    return next
  }
  if (event === "review" && model.row.matchUnread) {
    next.row = copy(model.row)
    next.row.matchUnread = false
    next.row.matchLabel = "Reviewed"
    next.notice = "Demo · Interest match marked reviewed."
    return next
  }
  if (event === "section" && p.canPlace && ["left", "center", "right"].indexOf(value) >= 0) {
    next.installSection = value
    if (model.installed) next.section = value
    next.notice = "Demo · Position set to " + value + (model.installed && !model.enabled ? "; Dockside is still disabled." : ".")
  } else if (event === "install-enabled" && !model.installed && model.known
      && !model.pending && !model.manual && !model.exclusive) {
    next.installEnabled = !model.installEnabled
    next.notice = "Demo · Will install " + (next.installEnabled ? "enabled." : "disabled.")
  } else if (event === "toggle" && p.canToggle) {
    next.enabled = !model.enabled
    next.installEnabled = next.enabled
    next.notice = "Demo · " + model.row.name + (next.enabled ? " enabled." : " disabled.")
  } else if (event === "enable" && p.primaryAction === "enable" && p.primaryEnabled) {
    next.enabled = true
    next.installEnabled = true
    next.notice = "Demo · Enabled in this preview."
  } else if (event === "queue" && p.canQueue) {
    next.selected = !model.selected
    next.notice = next.selected ? "Demo · Added to the in-memory install selection." : "Demo · Removed from the install selection."
  } else if (event === "activate" && p.primaryAction === "activate" && p.primaryEnabled) {
    next.enabled = true
    next.notice = "Demo · Tideline selected in memory. Your desktop bar has not changed."
  } else if ((event === "install" || event === "retry") && p.primaryAction === event && p.primaryEnabled) {
    next.pending = true
    next.operation = event
    next.failed = false
    next.error = ""
    next.notice = ""
  } else if (event === "remove" && p.canRemove) {
    next.pending = true
    next.operation = "remove"
    next.notice = ""
  }
  return next
}

// Called only by the prototype's one-shot timer. Retry preserves the enabled
// and position state of a partial install; Enable remains an explicit action.
function complete(model) {
  if (!model.pending) return model
  var next = copy(model)
  if (model.operation === "remove") {
    next.installEnabled = model.enabled
    next.installSection = model.section
    next.installed = false
    next.enabled = false
    next.notice = "Demo · Removed from the preview. Install preferences are remembered for this session."
  } else if (model.operation === "install" || model.operation === "retry") {
    if (!model.installed) {
      next.enabled = model.installEnabled
      next.section = model.installSection
    }
    next.installed = true
    next.notice = "Demo · Installation complete" + (next.enabled ? "." : "; plugin remains disabled.")
  }
  next.pending = false
  next.operation = ""
  next.failed = false
  next.error = ""
  next.selected = false
  return next
}
