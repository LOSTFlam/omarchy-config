pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import QtQuick.Controls as C
import Quickshell
import qs.Commons
import qs.Ui
import qs.Ui as Ui
import "Typography.js" as Typography
import "BrowseState.js" as BrowseState
import "InspectorState.js" as InspectorState
import "MediaPaths.js" as MediaPaths
import "Presentation.js" as Presentation
import "Navigation.js" as Navigation

Item {
  id: root

  property var shell: null
  property var manifest: null
  property var service: null
  readonly property bool sleeping: Boolean(service && service.sleeping === true)
  readonly property bool uiAwake: opened && !sleeping
  readonly property bool canBrowse: Boolean(service && (service.canBrowse === true
    || (service.canBrowse === undefined && service.cacheLoaded)))
  readonly property bool canManagePlugins: Boolean(service && (service.canManagePlugins === true
    || (service.canManagePlugins === undefined && service.inventoryReady)))
  // The detail redesign is a fixture-only review surface until its controls
  // and capability model have been approved for production integration.
  readonly property bool detailPrototypeSession: Boolean(service && service.demoRoot)
    && String(Quickshell.env("OUTFIT_DEMO_SCENARIO") || Quickshell.env("OMAFIT_DEMO_SCENARIO") || "") === "details"
  property bool detailPrototypeOpen: true
  property Item detailPrototypeInvoker: null
  property bool opened: false
  property bool closingFromHost: false
  property bool draftWatchHardware: true
  property bool draftReadmes: true
  property bool draftThumbnails: true
  property bool settingsTouched: false
  property bool settingsOpen: false
  property bool interestsOpen: false
  property bool interestsFromSettings: false
  property Item interestsInvoker: null
  property var pendingViewportRestore: null
  property int pageScrollSerial: -1
  property int pageScrollTarget: 0
  property string pendingPanelToken: ""
  property string activeView: "setup"
  property string setupStage: "browse"
  property string setupDetailId: ""
  property var inspectorSnapshot: null
  property Item inspectorInvoker: null
  property bool draftInstallEnabled: true
  property string draftInstallSection: "right"
  property bool pendingInstallEnabled: true
  property string pendingInstallSection: ""
  property string inspectorActionError: ""
  property var cachedDiscoveryRows: []
  property bool setupReadmeExpanded: false
  property bool setupDetailFocusPending: false
  property var serviceDraft: []
  property bool serviceDraftTouched: false
  property var pendingServiceChoices: null
  property bool servicePickerEditing: false
  property var pendingSetupRestore: null
  property string pendingSelectedId: ""
  property bool batchConfirmOpen: false
  property bool updateReviewOpen: false
  property bool updateBatchReview: false
  property var reviewedUpdates: []
  property string updateReviewError: ""
  readonly property bool updateBatch: Boolean(service && service.batchKind === "update")
  readonly property bool updatesIdle: Boolean(service && canManagePlugins && service.inventoryReady
    && !service.mutationBusy && !service.batchRunning && !service.selfUpdateBusy && !service.updatesBusy)
  property int selectedIndex: -1
  property string selectedId: ""
  property bool narrowDetailOpen: false
  property bool readmeExpanded: false
  property string chosenCategory: ""
  property bool actionConfirmOpen: false
  property string pendingAction: ""
  property var actionTarget: null
  property var activeHelpTip: null
  property real badgeClock: Date.now()
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.badgeClock = Date.now()
  }
  function listingIsNew(row) {
    var until = Number(row.newUntil || 0) * 1000
    return until > badgeClock && badgeClock >= until - 12 * 60 * 60 * 1000
  }
  signal dismissHelpTips()
  signal pointerHelpInput(var scenePosition)
  signal keyboardHelpInput()
  property int helpInputSerial: 0

  function notePointerHelpInput(scenePosition) {
    ++helpInputSerial
    pointerHelpInput(scenePosition || null)
  }
  function noteKeyboardHelpInput(event) {
    if ([Qt.Key_Tab, Qt.Key_Backtab, Qt.Key_Left, Qt.Key_Right, Qt.Key_Up,
         Qt.Key_Down, Qt.Key_F2, Qt.Key_F6].indexOf(event.key) < 0) return
    var serial = ++helpInputSerial
    // ShortcutOverride observes navigation before either a child or Shortcut
    // consumes it. Arm the resulting focus after navigation/scroll dismissal.
    Qt.callLater(function() {
      if (serial === root.helpInputSerial && root.opened && focusScope.Window.window.active)
        root.keyboardHelpInput()
    })
  }
  onOpenedChanged: if (!opened) { notePointerHelpInput(); dismissTooltips(); backgroundActivity.close() }
  onBrowseDensityChanged: dismissTooltips()
  onWorkspaceViewChanged: dismissTooltips()

  readonly property bool confirmationOpen: actionConfirmOpen || batchConfirmOpen || updateReviewOpen
  readonly property bool headerNavigationEnabled: !confirmationOpen
  readonly property bool filtersExpanded: !service || service.filtersExpanded !== false
  readonly property string browseDensity: Presentation.densityName(service ? service.browseDensity : "comfortable")
  readonly property var densityProfile: Presentation.densityProfile(browseDensity)
  property int densityReflowSerial: 0
  FontMetrics {
    id: browseMetricFont
    font.family: root.fontFamily
    font.pixelSize: root.browseReadingSize
    font.bold: true
  }
  function browseMetricWidth(metric, value) {
    var number = value === null || value === undefined ? "—" : String(Number(value) || 0)
    return browseMetricFont.advanceWidth(number) + root.browseIconSize + Style.space(4)
  }
  readonly property var metricMinimums: {
    var measuredFont = browseMetricFont.font // Track font changes as well as result changes.
    var left = 0, right = 0, rowWidth = 0
    for (var i = 0; i < setupRows.length; i++) {
      var row = setupRows[i]
      left = Math.max(left, browseMetricWidth("likes", row.likes), browseMetricWidth("views", row.views))
      right = Math.max(right, browseMetricWidth("stars", row.stars), browseMetricWidth("copies", row.copies))
      rowWidth = Math.max(rowWidth, browseMetricWidth("stars", row.stars) + browseMetricWidth("likes", row.likes)
        + browseMetricWidth("views", row.views) + browseMetricWidth("copies", row.copies))
    }
    return {left:left, right:right, row:rowWidth}
  }
  readonly property real minimumBrowseCardWidth: Math.max(Style.space(densityProfile.minimumWidth),
    Math.ceil(metricMinimums.row) + Style.space(6 + densityProfile.padding * 2))

  function browseCards() {
    var cards = []
    for (var g = 0; g < setupGroupRepeater.count; g++) {
      var group = setupGroupRepeater.itemAt(g)
      if (group && group.visible) cards = cards.concat(group.cards())
    }
    return cards
  }
  property string rovingResultId: ""
  property Item rovingFilter: null
  property Item cardContentsOwner: null
  readonly property Item keyboardFocus: focusScope.Window.window ? focusScope.Window.window.activeFocusItem : null
  readonly property bool browseNavigation: opened && activeView === "setup" && setupStage === "browse"
    && workspaceView === "browse" && !settingsOpen && !interestsOpen && !setupDetailId
    && !confirmationOpen && !detailPrototypeLoader.active
  readonly property bool filterFocus: Navigation.contains(setupFilterSidebar, keyboardFocus)
    || keyboardFocus === setupSearchField || Navigation.contains(setupSearchField, keyboardFocus)
    || Navigation.contains(setupSortPicker, keyboardFocus) || Navigation.contains(groupingControls, keyboardFocus)
    || Navigation.contains(searchSuggestion, keyboardFocus)
  readonly property bool resultFocus: Navigation.contains(setupCatalogScroll, keyboardFocus)
  onKeyboardFocusChanged: {
    if (cardContentsOwner && !Navigation.contains(cardContentsOwner, keyboardFocus)) cardContentsOwner = null
  }

  function focusResults() {
    var cards = browseCards()
    if (!cards.length) return
    var target = cards[0]
    for (var card of cards) if (String(card.pluginRow.id) === rovingResultId) target = card
    cardContentsOwner = null
    focusCardInView(target, setupCatalogScroll)
  }
  function focusFilters() {
    cardContentsOwner = null
    if (rovingFilter && rovingFilter.visible && rovingFilter.enabled) {
      if (Navigation.contains(setupSidebarContent, rovingFilter)) focusCardInView(rovingFilter, setupFilterScroll)
      else rovingFilter.forceActiveFocus()
    } else setupSearchField.forceActiveFocus()
  }
  function switchBrowseGroup() {
    if (filterFocus) { rovingFilter = keyboardFocus; focusResults() }
    else focusFilters()
  }
  function moveFilterFocus(key) {
    var controls = [setupSearchField, setupSortPicker, searchSuggestion].concat(Navigation.focusableChildren(groupingControls))
    if (filtersExpanded) controls = controls.concat([sidebarCollapseButton], Navigation.focusableChildren(setupSidebarContent))
    controls = controls.filter(function(item) { return item.visible && item.enabled })
    if (!controls.length) return
    var index = controls.findIndex(function(item) { return Navigation.contains(item, root.keyboardFocus) })
    var direction = key === Qt.Key_Up || key === Qt.Key_Left ? -1 : 1
    var target = controls[Math.max(0, Math.min(controls.length - 1, index + direction))]
    rovingFilter = target
    if (Navigation.contains(setupSidebarContent, target)) focusCardInView(target, setupFilterScroll)
    else target.forceActiveFocus()
  }
  function moveCardFocus(card, key) {
    if (cardContentsOwner) {
      moveCardContents(key === Qt.Key_Up || key === Qt.Key_Left ? -1 : 1)
      return
    }
    var cards = browseCards()
    var rects = cards.map(function(item) {
      var point = item.mapToItem(setupGroupsColumn, item.width / 2, 0)
      return {x:point.x, y:point.y, width:item.width, height:item.height}
    })
    var next = Navigation.adjacent(rects, cards.indexOf(card), key)
    if (next >= 0) focusCardInView(cards[next], setupCatalogScroll)
  }
  function enterCardContents(card) {
    var controls = Navigation.focusableChildren(card)
    if (!controls.length) return
    cardContentsOwner = card
    focusCardInView(controls[0], setupCatalogScroll)
  }
  function moveCardContents(direction) {
    var controls = Navigation.focusableChildren(cardContentsOwner)
    var index = controls.indexOf(keyboardFocus)
    var next = index + direction
    if (next < 0 || next >= controls.length) {
      var card = cardContentsOwner
      cardContentsOwner = null
      focusCardInView(card, setupCatalogScroll)
    } else focusCardInView(controls[next], setupCatalogScroll)
  }
  function goBack() {
    if (detailPrototypeLoader.active) { detailPrototypeOpen = false; return }
    if (interestsOpen) leaveInterests()
    else if (setupDetailId) closeSetupDetail()
    else if (settingsOpen) leaveSettings()
    else if (setupStage === "services" && servicePickerEditing) cancelServicePicker()
    else if (setupStage === "updates") leaveUpdates()
    else if (setupStage === "progress") setupStage = updateBatch ? "updates" : "browse"
    else if (setupStage === "review") setupStage = "browse"
    else if (narrowDetailOpen) narrowDetailOpen = false
  }
  function chooseDensity(value) {
    if (!service || typeof service.setBrowseDensity !== "function") return
    dismissTooltips()
    var cards = browseCards()
    var flickable = setupCatalogScroll.contentItem
    var anchor = null
    for (var i = 0; i < cards.length; i++) {
      var position = cards[i].mapToItem(flickable, 0, 0)
      if (position.y + cards[i].height > 0 && (!anchor || position.y < anchor.offset))
        anchor = {id:String(cards[i].pluginRow.id), offset:position.y}
    }
    var serial = ++densityReflowSerial
    service.setBrowseDensity(value)
    Qt.callLater(function() {
      if (serial !== root.densityReflowSerial || !root.opened || root.workspaceView !== "browse") return
      for (var g = 0; g < setupGroupRepeater.count; g++) {
        var group = setupGroupRepeater.itemAt(g)
        if (group) group.relayout()
      }
      setupGroupsColumn.forceLayout()
      if (anchor) {
        var updated = root.browseCards()
        for (var j = 0; j < updated.length; j++) {
          if (String(updated[j].pluginRow.id) !== anchor.id) continue
          var offset = updated[j].mapToItem(flickable, 0, 0).y
          // A compact/list card may be shorter than the old clipped portion.
          // Keep at least its last pixel visible instead of skipping the ID.
          var retainedOffset = Math.max(anchor.offset, 1 - updated[j].height)
          flickable.contentY = Presentation.anchoredScroll(flickable.contentY, retainedOffset,
            offset, flickable.contentHeight, flickable.height)
          break
        }
      }
    })
  }
  function moveDensityFocus(mode, direction) {
    var modes = Presentation.viewModes()
    var index = (modes.indexOf(mode) + direction + modes.length) % modes.length
    chooseDensity(modes[index])
    densityRepeater.itemAt(index).forceActiveFocus()
  }

  function setFiltersExpanded(expanded) {
    dismissTooltips()
    if (service) service.filtersExpanded = expanded
    Qt.callLater(function() {
      if (!root.opened) return
      if (expanded) sidebarCollapseButton.forceActiveFocus()
      else filtersToggle.forceActiveFocus()
    })
  }

  readonly property string pluginId: manifest && manifest.id
    ? String(manifest.id) : "io.github.ctl0v0.outfit"
  readonly property color foreground: Color.foreground
  readonly property color background: Color.background
  readonly property color secondary: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.64)
  readonly property color faint: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.055)
  readonly property string fontFamily: Style.font.family
  readonly property real readingSize: Typography.reading(Style.font)
  readonly property real supportingSize: Typography.supporting(Style.font)
  readonly property real valueSize: Typography.value(Style.font)
  readonly property real iconSize: Typography.icon(Style.font)
  readonly property real targetSize: Typography.target(Style.font)
  readonly property real browseReadingSize: Style.font.body
  readonly property real browseMetadataSize: Style.font.bodySmall
  readonly property real browseIconSize: Math.round(Style.font.body * 16 / 12)
  component Button: Ui.Button { fontSize: root.readingSize }
  component FilterButton: C.AbstractButton {
    property bool selected: false
    property bool bordered: false
    property bool focusable: true
    property color foreground: root.foreground
    focusPolicy: focusable ? Qt.StrongFocus : Qt.NoFocus
    hoverEnabled: true
    font.family: root.fontFamily
    font.pixelSize: root.browseReadingSize
    font.bold: selected
    leftPadding: Style.space(10)
    rightPadding: Style.space(10)
    topPadding: Style.space(5)
    bottomPadding: Style.space(5)
    implicitWidth: contentItem.implicitWidth + leftPadding + rightPadding
    implicitHeight: Math.max(Style.space(30), contentItem.implicitHeight + topPadding + bottomPadding)
    opacity: enabled ? 1 : 0.45
    Accessible.name: text
    contentItem: Text {
      text: parent.text
      textFormat: Text.PlainText
      font: parent.font
      color: parent.foreground
      wrapMode: Text.Wrap
      verticalAlignment: Text.AlignVCenter
    }
    background: BorderSurface {
      radius: Style.cornerRadius
      color: parent.selected || parent.hovered || parent.activeFocus
        ? Style.selectedFillFor(parent.foreground, Color.accent) : "transparent"
      borderSpec: parent.activeFocus ? Border.controlSpec("focus", parent.foreground, Color.accent)
        : parent.bordered ? Border.controlSpec("normal", parent.foreground, Color.accent) : Border.none()
    }
    Keys.onReturnPressed: if (enabled) clicked()
    Keys.onEnterPressed: if (enabled) clicked()
  }
  component TextField: Ui.TextField { font.pixelSize: root.readingSize }
  readonly property var resultRows: service && Array.isArray(service.rows) ? service.rows : []
  readonly property var selectedRow: selectedIndex >= 0 && selectedIndex < resultRows.length
    ? resultRows[selectedIndex] : null
  readonly property bool narrowWorkspace: workspace.width < Style.space(900)
  readonly property var categoryOptions: {
    var output = [{ value: "", label: "All categories" }]
    var values = service && Array.isArray(service.categories) ? service.categories : []
    for (var index = 0; index < values.length; index++)
      output.push({ value: String(values[index]), label: String(values[index]) })
    return output
  }
  readonly property bool preferencesDirty: {
    var current = service && service.preferences ? service.preferences : ({})
    return draftWatchHardware !== (current.watchHardware !== false)
      || draftReadmes !== (current.readmeEnrichment !== false)
      || draftThumbnails !== (current.marketplaceThumbnails !== false)
  }
  readonly property var setupRows: service && Array.isArray(service.setupRows)
    ? service.setupRows : []
  readonly property var setupGroups: service && Array.isArray(service.setupGroups)
    ? service.setupGroups : []
  readonly property var serviceOptions: service && Array.isArray(service.serviceOptions)
    ? service.serviceOptions : []
  readonly property int serviceDraftCount: serviceDraft.length
  readonly property var setupSelectedRows: service && typeof service.selectedSetupRows === "function"
    ? service.selectedSetupRows() : []
  readonly property int setupSelectedCount: setupSelectedRows.length
  readonly property bool discoveryEnabled: service !== null && service.discoveryEnabled === true
  readonly property string workspaceView: discoveryEnabled && service && service.workspaceView === "discover" ? "discover" : "browse"
  readonly property string discoverTab: service && service.discoverTab === "matches" ? "matches" : "ideas"
  readonly property var matchRows: service && service.matches ? service.matches.rows || [] : []
  readonly property var discoveryRows: cachedDiscoveryRows
  readonly property var setupDetailRow: setupDetailId && inspectorSnapshot
    && String(inspectorSnapshot.id || "") === setupDetailId ? inspectorSnapshot : null
  readonly property bool setupDetailInline: false

  onSettingsOpenChanged: {
    dismissTooltips()
    maintenanceMenu.close()
    flushPanel()
    if (!settingsOpen) return
    closeSetupDetail()
    setThumbnailRows([])
  }
  onSetupStageChanged: {
    dismissTooltips()
    flushPanel()
    if (setupStage === "browse") {
      Qt.callLater(function() {
        if (!root || !root.opened || typeof root.restoreSetupDetailFocus !== "function") return
        if (!root.restoreSetupDetailFocus() && !root.setupDetailId) root.focusWorkspace()
      })
      return
    }
    closeSetupDetail()
    setThumbnailRows([])
    if (setupStage === "updates") Qt.callLater(function() {
      if (!root.setupDetailId) root.focusWorkspace()
    })
  }
  onSetupDetailRowChanged: {
    ensureSetupPreview(setupDetailRow)
    if (opened && setupDetailRow) Qt.callLater(function() {
      if (root && root.opened && typeof root.restoreSetupDetailFocus === "function") root.restoreSetupDetailFocus()
    })
  }

  onConfirmationOpenChanged: {
    dismissTooltips()
    maintenanceMenu.close()
  }
  onActiveViewChanged: dismissTooltips()
  onSetupRowsChanged: captureRestoredInspector()
  onInterestsOpenChanged: rememberPanel()
  onSettingsTouchedChanged: rememberPanel()
  onSetupDetailIdChanged: rememberPanel()
  onServiceChanged: { thumbnailDemandKey = ""; updateDiscoveryCache() }

  function updateDiscoveryCache() {
    if (service && Array.isArray(service.discoveryRows))
      cachedDiscoveryRows = JSON.parse(JSON.stringify(service.discoveryRows.slice(0, 3)))
    captureRestoredInspector()
  }

  function ensureDiscovery() {
    if (!discoveryEnabled) return
    updateDiscoveryCache()
    if (opened && !interestsOpen && discoverTab === "ideas" && service && typeof service.ensureDiscovery === "function") service.ensureDiscovery()
  }

  function chooseDiscoverTab(tab) {
    if (!discoveryEnabled) return
    if (!service) return
    closeSetupDetail(false)
    service.discoverTab = tab === "matches" ? "matches" : "ideas"
    if (discoverTab === "matches") service.scheduleMatches(false)
    else ensureDiscovery()
    rememberPanel()
  }
  function matchReasons(row) {
    return (row && Array.isArray(row.matchedInterests) ? row.matchedInterests : []).map(function(interest) {
      return String(interest.label || interest.id) + ": " + String(interest.reason
        || ('“' + String(interest.term || "") + '” in ' + String(interest.field || "listing")))
    }).join("\n")
  }
  function matchCause(row) {
    return row && row.matchCause === "new-listing" ? "New listing"
      : row && row.matchCause === "baseline" ? "Saved-interest match" : "Newly relevant to your saved interests"
  }
  function openInterests(invoker) {
    if (!service) return
    flushPanel()
    dismissTooltips()
    maintenanceMenu.close()
    setupSearchDebounce.stop()
    searchDebounce.stop()
    service.interestsReturnPayload = editorResumePayload(setupDetailId)
    interestsFromSettings = settingsOpen
    interestsInvoker = invoker || null
    interestsOpen = true
    setupDetailPanel.stopMedia()
    service.cancelPendingReadme(setupDetailId)
    setThumbnailRows([])
    service.beginInterests()
    Qt.callLater(function() { interestsManager.takeFocus(); root.rememberPanel() })
  }
  function leaveInterests() {
    interestsOpen = false
    settingsOpen = interestsFromSettings
    var saved = service ? service.interestsReturnPayload : null
    if (saved) {
      // Views stay mounted, preserving filters, text drafts and inspector identity.
      pendingViewportRestore = saved
      Qt.callLater(function() { root.restoreViewport() })
    }
    Qt.callLater(function() {
      if (!root.opened) return
      if (root.interestsInvoker && root.interestsInvoker.visible) root.interestsInvoker.forceActiveFocus()
      else if (root.settingsOpen) settingsInterestsButton.forceActiveFocus()
      else if (saved && saved.selectedId && root.setupDetailId)
        setupDetailPanel.restorePosition(saved.inspectorScroll, saved.inspectorFocus)
      else root.focusWorkspace()
      root.rememberPanel()
    })
  }
  function currentScroll() {
    return workspaceView === "discover" ? (discoverTab === "matches" ? matchesScroll : discoveryScroll) : setupCatalogScroll
  }
  function viewportAnchor() {
    var scroll = currentScroll()
    var flickable = scroll.contentItem
    var anchor = {id:"", offset:0, y:Number(flickable.contentY || 0)}
    var cards = workspaceView === "browse" ? browseCards() : []
    var repeater = discoverTab === "matches" ? matchesRepeater : discoveryRepeater
    if (workspaceView === "discover") {
      for (var c = 0; c < repeater.count; c++) {
        var item = repeater.itemAt(c)
        if (item) cards.push(item)
      }
    }
    for (var i = 0; i < cards.length; i++) {
      var pos = cards[i].mapToItem(flickable, 0, 0)
      if (pos.y + cards[i].height > 0 && (!anchor.id || pos.y < anchor.offset))
        anchor = {id:String((cards[i].pluginRow || cards[i].modelData).id), offset:pos.y, y:anchor.y}
    }
    return anchor
  }
  function restoreViewport() {
    if (!opened || !pendingViewportRestore) return
    var payload = pendingViewportRestore
    if (payload.setupStage === "updates" && service && !service.updatesLoaded && service.updatesBusy) return
    var anchor = payload.scrollAnchor
    var scroll = currentScroll()
    var flickable = scroll.contentItem
    if (anchor && flickable) {
      var cards = workspaceView === "browse" ? browseCards() : []
      var repeater = discoverTab === "matches" ? matchesRepeater : discoveryRepeater
      if (workspaceView === "discover")
        for (var c = 0; c < repeater.count; c++) if (repeater.itemAt(c)) cards.push(repeater.itemAt(c))
      if (anchor.id && !cards.length && !interestsOpen && !settingsOpen && service
          && (service.queryBusy || service.pendingSetup || service.matchesBusy)) return
      flickable.contentY = Math.max(0, Math.min(Number(anchor.y) || 0, flickable.contentHeight - flickable.height))
      for (var i = 0; i < cards.length; i++) {
        if (String((cards[i].pluginRow || cards[i].modelData).id) !== anchor.id) continue
        flickable.contentY = Presentation.anchoredScroll(flickable.contentY, anchor.offset,
          cards[i].mapToItem(flickable, 0, 0).y, flickable.contentHeight, flickable.height)
        break
      }
    }
    if (payload.updatesContext) updatesPage.restoreContext(payload.updatesContext)
    else updatesPage.restorePosition(payload.updatesScroll)
    setupDetailPanel.restorePosition(payload.inspectorScroll, payload.inspectorFocus)
    pendingViewportRestore = null
    if (pendingPanelToken && service) {
      service.acknowledgeEditorRestore(pendingPanelToken)
      pendingPanelToken = ""
    }
  }
  function rememberPanel() {
    if (opened && !sleeping && !panelRememberTimer.running) panelRememberTimer.start()
  }
  function flushPanel() {
    panelRememberTimer.stop()
    if (opened && service && !pendingViewportRestore && typeof service.rememberEditor === "function")
      service.rememberEditor(editorResumePayload(setupDetailId))
  }
  Timer {
    id: panelRememberTimer
    objectName: "panelRememberTimer"
    interval: 120
    onTriggered: root.flushPanel()
  }

  function chooseWorkspace(view) {
    if (!service) return
    flushPanel()
    if (root.detailPrototypeSession) root.detailPrototypeOpen = false
    dismissTooltips()
    closeSetupDetail(false)
    service.workspaceView = discoveryEnabled && view === "discover" ? "discover" : "browse"
    setupStage = "browse"
    if (workspaceView === "discover") ensureDiscovery()
    Qt.callLater(function() { root.focusWorkspace() })
    rememberPanel()
  }

  function openUpdates() {
    if (!headerNavigationEnabled) return
    flushPanel()
    if (interestsOpen) leaveInterests()
    settingsOpen = false
    detailPrototypeOpen = false
    setupSearchDebounce.stop()
    searchDebounce.stop()
    closeSetupDetail(false)
    setupStage = "updates"
    activeView = "setup"
    Qt.callLater(function() { updatesPage.takeFocus(); root.rememberPanel() })
  }
  function leaveUpdates() {
    flushPanel()
    closeSetupDetail(false)
    setupStage = "browse"
    Qt.callLater(function() { updatesButton.forceActiveFocus(); root.rememberPanel() })
  }
  function openOutfitUpdate() {
    if (!headerNavigationEnabled || !service) return
    maintenanceMenu.close()
    openUpdates()
    var info = updateInfo({id:"io.github.ctl0v0.outfit"})
      || {id:"io.github.ctl0v0.outfit", name:"Outfit"}
    openSetupDetail(updateDetailRow(info), moreActionsButton)
    if (typeof service.checkUpdates === "function") service.checkUpdates(false)
  }
  function updateInfo(row) {
    // Explicitly observe replacement of the service array as well as its lookup.
    var rows = service ? service.updates : []
    return row && service && typeof service.updateInfo === "function" ? service.updateInfo(row.id) : null
  }
  function updateContext() {
    return {inventoryReady:canManagePlugins && Boolean(service && service.inventoryReady),
      mutationBusy:service && service.mutationBusy, batchRunning:service && service.batchRunning,
      selfUpdateBusy:service && service.selfUpdateBusy, updatesBusy:service && service.updatesBusy,
      updatesLoaded:service && service.updatesLoaded, updatesError:service ? service.updatesError : "",
      interestsDirty:service && service.interestsDirty, settingsTouched:settingsTouched}
  }
  function checkUpdates() {
    if (updatesIdle && typeof service.checkUpdates === "function") service.checkUpdates(true)
  }
  function updateDetailRow(row) {
    var listing = InspectorState.snapshotFor(String(row.id), setupRows.concat(resultRows, matchRows, discoveryRows), null)
    return Object.assign({}, canonicalEntry(row) || {}, listing || {}, {id:row.id, name:row.name || row.id})
  }
  function requestUpdate(row) {
    var info = updateInfo(row)
    if (!info || !InspectorState.updatePresentation(canonicalEntry(row), info, updateContext()).canUpdate) return
    reviewedUpdates = [JSON.parse(JSON.stringify(info))]
    updateBatchReview = false
    updateReviewError = ""
    updateReviewOpen = true
  }
  function reviewAllUpdates() {
    if (!updatesIdle) return
    var rows = (service.updates || []).filter(InspectorState.eligibleUpdate)
    if (!rows.length) return
    reviewedUpdates = JSON.parse(JSON.stringify(rows))
    updateBatchReview = true
    updateReviewError = ""
    updateReviewOpen = true
  }
  function confirmUpdates() {
    if (!updateReviewOpen || !reviewedUpdates.length) return false
    var valid = updatesIdle && reviewedUpdates.every(function(row) {
      var entry = root.canonicalEntry(row)
      return InspectorState.sameUpdate(row, root.updateInfo(row))
        && InspectorState.updatePresentation(entry, row, root.updateContext()).canUpdate
        && String(entry.installedVersion || "") === String(row.installedVersion || "")
        && String(entry.installedRevision || "") === String(row.installedRevision || "")
        && (!root.updateBatchReview || InspectorState.eligibleUpdate(row))
    })
    if (!valid) {
      updateReviewError = "Plugin versions or availability changed. Cancel and review the current updates before continuing."
      return false
    }
    var resume = editorResumePayload(setupDetailId)
    var started = updateBatchReview
      ? service.startUpdateBatch(reviewedUpdates.map(function(row) { return row.id }), resume)
      : reviewedUpdates[0].selfUpdate === true ? service.beginSelfUpdate(reviewedUpdates[0], resume)
        : service.updatePlugin(reviewedUpdates[0], resume)
    if (!started) {
      updateReviewError = "The update could not start. Review the current plugin state and try again."
      return false
    }
    updateReviewOpen = false
    return true
  }

  function focusWorkspace() {
    if (!opened || settingsOpen || interestsOpen) return
    if (setupStage === "updates") { updatesPage.takeFocus(); return }
    if (setupStage !== "browse") return
    if (workspaceView === "discover") (discoverTab === "matches" ? matchesTabButton : ideasTabButton).forceActiveFocus()
    else setupSearchField.forceActiveFocus()
  }

  function changeDiscovery(back) {
    if (!discoveryEnabled) return
    if (!service || service.discoveryBusy) return
    closeSetupDetail(false)
    if (back && service.discoveryCanGoBack) service.discoverBack()
    else if (!back) service.discoverNext()
  }

  function dismissTooltips() {
    var hadTip = activeHelpTip !== null
    dismissHelpTips()
    activeHelpTip = null
    return hadTip
  }

  function normalizedGrouping(value) {
    return String(value || "") === "category" ? "category" : "none"
  }

  function chooseGrouping(value) {
    if (!service || service.queryBusy) return
    service.setupGrouping = normalizedGrouping(value)
    requestSetup(setupSearchField.text.trim(), service.setupGroup, service.setupSort, 1)
  }

  function leaveSettings() {
    settingsOpen = false
    Qt.callLater(function() { if (root.opened) settingsButton.forceActiveFocus() })
  }

  function cleanPayload(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(String(payloadJson || "{}")) || ({}) }
    catch (error) { payload = ({}) }
    if (typeof payload !== "object" || Array.isArray(payload)) payload = ({})
    var browse = BrowseState.restore(payload, service || ({}))
    var rawDraft = payload.draft && typeof payload.draft === "object" ? payload.draft : null
    var view = String(payload.view || "setup")
    var setupStage = String(payload.setupStage || "browse")
    var setupServices = null
    if (Array.isArray(payload.setupServices)) {
      setupServices = []
      for (var serviceIndex = 0; serviceIndex < payload.setupServices.length
           && serviceIndex < 64; serviceIndex++)
        setupServices.push(String(payload.setupServices[serviceIndex] || "").slice(0, 64))
    }
    return {
      view: ["fit", "setup"].indexOf(view) >= 0 ? view : "setup",
      setupStage: ["services", "browse", "updates", "review", "progress"].indexOf(setupStage) >= 0
        ? setupStage : "browse",
      setupQuery: String(payload.setupQuery || "").slice(0, 160),
      setupGroup: browse.group,
      setupGrouping: browse.grouping,
      setupSort: browse.sort,
      browseSort: browse.browseSort,
      setupPage: browse.page,
      workspaceView: browse.workspaceView,
      discoverTab: ("discoverTab" in payload ? payload.discoverTab : service ? service.discoverTab : "ideas") === "matches" ? "matches" : "ideas",
      restoreToken: String(payload.restoreToken || "").slice(0, 80),
      settingsOpen: payload.settingsOpen === true,
      interestsOpen: payload.interestsOpen === true || setupStage === "services",
      interestsFromSettings: payload.interestsFromSettings === true,
      scrollAnchor: payload.scrollAnchor || null,
      updatesQuery: String(payload.updatesQuery || "").slice(0, 160),
      updatesScroll: Math.max(0, Math.min(1000000, Number(payload.updatesScroll) || 0)),
      updatesContext: payload.updatesContext && typeof payload.updatesContext === "object" ? payload.updatesContext : null,
      inspectorScroll: Math.max(0, Number(payload.inspectorScroll) || 0),
      inspectorFocus: String(payload.inspectorFocus || "close"),
      installDraft: payload.installDraft || null,
      windowWidth: Math.max(0, Math.min(10000, Number(payload.windowWidth) || 0)),
      windowHeight: Math.max(0, Math.min(10000, Number(payload.windowHeight) || 0)),
      setupVerification: browse.verification,
      setupServices: setupServices,
      setupInterestCriteria: Array.isArray(payload.setupInterestCriteria) ? payload.setupInterestCriteria.slice(0, 64) : null,
      setupServiceFilter: String(payload.setupServiceFilter || "").slice(0, 64),
      setupInstallFilter: ["all", "installed", "available"].indexOf(
        String(payload.setupInstallFilter || "")) >= 0
        ? String(payload.setupInstallFilter) : "",
      setupPartyFilter: ["all", "first-party", "third-party"].indexOf(
        String(payload.setupPartyFilter || "")) >= 0
        ? String(payload.setupPartyFilter) : "",
      setupHardwareOnly: payload.setupHardwareOnly === true,
      setupCategory: String(payload.setupCategory || "").slice(0, 80),
      query: String(payload.query || "").slice(0, 160),
      category: String(payload.category || "").slice(0, 80),
      installFilter: ["all", "installed", "available"].indexOf(String(payload.installFilter || "")) >= 0
        ? String(payload.installFilter) : "",
      partyFilter: ["all", "first-party", "third-party"].indexOf(String(payload.partyFilter || "")) >= 0
        ? String(payload.partyFilter) : "",
      selectedId: String(payload.selectedId || "").slice(0, 160),
      hasQuery: "query" in payload,
      hasSetupStage: "setupStage" in payload,
      hasCategory: "category" in payload,
      hasInstallFilter: "installFilter" in payload,
      hasPartyFilter: "partyFilter" in payload,
      hasSetupQuery: "setupQuery" in payload,
      hasSetupInstallFilter: "setupInstallFilter" in payload,
      hasSetupPartyFilter: "setupPartyFilter" in payload,
      hasSetupHardwareOnly: "setupHardwareOnly" in payload,
      hasSetupCategory: "setupCategory" in payload,
      restoreDraft: payload.restoreDraft === true && rawDraft !== null,
      settingsTouched: payload.settingsTouched === true,
      draft: rawDraft ? {
        watchHardware: rawDraft.watchHardware !== false,
        readmeEnrichment: rawDraft.readmeEnrichment !== false,
        marketplaceThumbnails: rawDraft.marketplaceThumbnails !== false
      } : null
    }
  }

  function open(payloadJson) {
    if (root.detailPrototypeSession) root.detailPrototypeOpen = true
    badgeClock = Date.now()
    dismissTooltips()
    maintenanceMenu.close()
    var payload = cleanPayload(payloadJson)
    if (payload.restoreToken && (!service || !service.acceptsEditorRestore(payload.restoreToken))) return
    pendingPanelToken = payload.restoreToken
    closingFromHost = false
    settingsOpen = false
    narrowDetailOpen = false
    root.closeSetupDetail()
    setupReadmeExpanded = false
    activeView = "setup"
    var hasBatch = service && service.batchRunning
    setupStage = payload.hasSetupStage ? payload.setupStage : hasBatch ? "progress"
      : (payload.hasSetupStage ? payload.setupStage : setupStage)
    if (setupStage === "services") setupStage = "browse"
    servicePickerEditing = setupStage === "services"
    opened = true
    updatesPage.query = payload.updatesQuery
    syncDraft()
    syncServiceDraft()
    if (payload.restoreDraft && payload.draft) {
      draftWatchHardware = payload.draft.watchHardware
      draftReadmes = payload.draft.readmeEnrichment
      draftThumbnails = payload.draft.marketplaceThumbnails
      settingsTouched = payload.settingsTouched
    }
    searchField.text = payload.hasQuery ? payload.query
      : (service ? String(service.currentQuery || "") : "")
    chosenCategory = payload.hasCategory ? payload.category
      : (service ? String(service.currentCategory || "") : "")
    categoryPicker.value = chosenCategory
    setupSearchField.text = payload.hasSetupQuery ? payload.setupQuery
      : (service ? String(service.setupQuery || "") : "")
    if (service) {
      service.restoreSetupSearch({setupQuery:setupSearchField.text,
        setupSort:payload.setupSort, browseSort:payload.browseSort})
      service.discoverTab = payload.discoverTab
      service.workspaceView = payload.workspaceView
      if (payload.setupInterestCriteria) service.setupInterestCriteria = payload.setupInterestCriteria
      service.setupVerification = payload.setupVerification
      service.setupGrouping = payload.setupGrouping
      if ("currentQuery" in service) service.currentQuery = searchField.text
      if ("currentCategory" in service) service.currentCategory = chosenCategory
      if (payload.hasInstallFilter && "currentInstallFilter" in service)
        service.currentInstallFilter = payload.installFilter
      if (payload.hasPartyFilter && "currentPartyFilter" in service)
        service.currentPartyFilter = payload.partyFilter
      if (payload.hasSetupInstallFilter && "setupInstallFilter" in service)
        service.setupInstallFilter = payload.setupInstallFilter
      if (payload.hasSetupPartyFilter && "setupPartyFilter" in service)
        service.setupPartyFilter = payload.setupPartyFilter
      if (payload.hasSetupHardwareOnly && "setupHardwareOnly" in service)
        service.setupHardwareOnly = payload.setupHardwareOnly
      if (payload.hasSetupCategory && "setupCategory" in service)
        service.setupCategory = payload.setupCategory
      if (!payload.restoreToken && typeof service.panelOpened === "function") service.panelOpened()
      if (typeof service.editorOpened === "function") service.editorOpened()
      if (activeView === "setup" && !service.batchRunning && !payload.restoreToken) {
        var openingServices = Array.isArray(payload.setupServices)
          ? payload.setupServices
          : (service.setupServicesInitialized && Array.isArray(service.setupServiceIds)
            ? service.setupServiceIds : [])
        if (service.cacheLoaded) {
          service.quickSetup(
            payload.hasSetupQuery ? payload.setupQuery : service.setupQuery,
            payload.setupGroup, payload.setupSort,
            payload.setupPage, openingServices, payload.setupServiceFilter)
        } else {
          pendingSetupRestore = {
            query: payload.hasSetupQuery ? payload.setupQuery : service.setupQuery,
            group: payload.setupGroup,
            sort: payload.setupSort,
            page: payload.setupPage,
            services: openingServices,
            serviceFilter: payload.setupServiceFilter,
            installFilter: payload.hasSetupInstallFilter
              ? payload.setupInstallFilter : undefined,
            partyFilter: payload.hasSetupPartyFilter
              ? payload.setupPartyFilter : undefined,
            hardwareOnly: payload.hasSetupHardwareOnly
              ? payload.setupHardwareOnly : undefined,
            category: payload.hasSetupCategory ? payload.setupCategory : undefined
          }
        }
      }
    }
    selectedIndex = -1
    selectedId = payload.selectedId
    pendingSelectedId = payload.selectedId
    setupDetailId = payload.selectedId
    captureRestoredInspector()
    if (payload.installDraft) {
      draftInstallEnabled = payload.installDraft.enable === true
      draftInstallSection = InspectorState.section(payload.installDraft.section) || "right"
    }
    setupDetailFocusPending = Boolean(payload.selectedId && activeView === "setup")
    if (service && "setupDetailId" in service) service.setupDetailId = setupDetailId
    if (payload.selectedId) {
      for (var index = 0; index < resultRows.length; index++) {
        if (String(resultRows[index].id || "") === payload.selectedId) {
          selectedIndex = index
          selectedId = payload.selectedId
          pendingSelectedId = ""
          break
        }
      }
    }
    clampSelection()
    settingsOpen = payload.settingsOpen
    interestsOpen = payload.interestsOpen
    interestsFromSettings = payload.interestsFromSettings
    if (interestsOpen && service) service.beginInterests()
    if (payload.windowWidth) window.implicitWidth = Math.max(Style.space(760), payload.windowWidth)
    if (payload.windowHeight) window.implicitHeight = Math.max(Style.space(540), payload.windowHeight)
    pendingViewportRestore = payload
    if (workspaceView === "discover") ensureDiscovery()
    Qt.callLater(function() {
      if (!root.opened) return
      if (root.interestsOpen) interestsManager.takeFocus()
      else if (!root.restoreSetupDetailFocus()) focusScope.forceActiveFocus()
      root.restoreViewport()
    })
  }

  function close() {
    flushPanel()
    pendingPanelToken = ""
    dismissTooltips()
    maintenanceMenu.close()
    helpScrollPause.stop()
    setupDetailPanel.stopMedia()
    if (service && typeof service.cancelPendingReadme === "function")
      service.cancelPendingReadme(setupDetailId)
    closingFromHost = true
    opened = false
    thumbnailDemandTimer.stop()
    setThumbnailRows([])
    searchDebounce.stop()
    setupSearchDebounce.stop()
    settingsOpen = false
    actionConfirmOpen = false
    updateReviewOpen = false
    pendingAction = ""
    actionTarget = null
    setupDetailFocusPending = false
    if (service && typeof service.editorClosed === "function") service.editorClosed()
    closingFromHost = false
  }

  Component.onDestruction: {
    closingFromHost = true
    if (service) {
      flushPanel()
      if (typeof service.editorClosed === "function") service.editorClosed()
    }
  }

  function requestClose() {
    flushPanel()
    if (service && typeof service.userClosedEditor === "function") service.userClosedEditor()
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
    else close()
  }

  function requestSetup(query, group, sort, page) {
    if (!service) return
    setupSearchDebounce.stop()
    setupStage = "browse"
    dismissTooltips()
    service.quickSetup(
      query, group, sort, page, service.setupServiceIds, service.setupServiceFilter)
  }
  function changeSetupPage(page) {
    if (!service || service.queryBusy || page < 1 || page > service.setupPageCount || page === service.setupPage) return false
    if (pendingViewportRestore) pendingViewportRestore.scrollAnchor = {id:"",offset:0,y:0}
    requestSetup(setupSearchField.text.trim(), service.setupGroup, service.setupSort, page)
    pageScrollSerial = service.setupSearchSerial
    pageScrollTarget = page
    rovingResultId = ""
    // Move focus off the footer before it can pull the new results back down.
    setupSearchField.forceActiveFocus()
    setupCatalogScroll.contentItem.cancelFlick()
    setupCatalogScroll.contentItem.contentY = 0
    return true
  }
  function finishPageScroll() {
    if (pageScrollSerial < 0 || !service || service.queryBusy || service.pendingSetup) return
    var current = pageScrollSerial === service.setupSearchSerial && pageScrollTarget === service.setupPage
    pageScrollSerial = -1
    pageScrollTarget = 0
    if (!current || !browseNavigation || service.error) return
    setupCatalogScroll.contentItem.cancelFlick()
    setupCatalogScroll.contentItem.contentY = 0
    focusResults()
    setupCatalogScroll.contentItem.contentY = 0
    rememberPanel()
  }

  function editSetupSearch() {
    if (!service) return
    service.prepareSetupSearch(setupSearchField.text, service.setupSort, false)
    setupSearchDebounce.restart()
  }

  function chooseSetupSort(value) {
    if (!service) return
    service.prepareSetupSearch(setupSearchField.text, value, true)
    requestSetup(setupSearchField.text, service.setupGroup, service.setupSort, 1)
  }

  function acceptSearchSuggestion() {
    var suggestion = service ? service.setupSearch.suggestion : null
    if (!suggestion) return
    setupSearchField.text = suggestion.query
    requestSetup(suggestion.query, service.setupGroup, service.setupSort, 1)
    setupSearchField.forceActiveFocus()
  }

  function queueCurrentSetup() {
    if (!service || activeView !== "setup") return
    service.quickSetup(
      setupSearchField.text.trim(), service.setupGroup, service.setupSort,
      service.setupPage, service.setupServiceIds, service.setupServiceFilter)
  }

  function savedServiceOptions() {
    var output = []
    var criteria = null
    if (service && service.interestsDirty && service.interestsDraft)
      criteria = service.interestsDraft.criteria
    else if (service && service.inputsLoaded && service.inputs)
      criteria = service.inputs.criteria
    var saved = []
    var labels = ({})
    if (Array.isArray(criteria)) {
      for (var c = 0; c < criteria.length; c++) {
        var criterion = criteria[c]
        var identity = service.interestFilterKey(criterion)
        if (criterion.enabled === false || !identity || saved.indexOf(identity) >= 0) continue
        saved.push(identity)
        labels[identity] = String(criterion.label || identity)
      }
    } else {
      // Startup compatibility only. Once context is loaded, an empty criteria
      // list is authoritative and must never resurrect old preference entries.
      saved = service && service.preferences && Array.isArray(service.preferences.services)
        ? service.preferences.services : []
    }
    for (var index = 0; index < saved.length; index++) {
      var option = serviceOption(saved[index])
      output.push(option ? Object.assign({}, option, {name:labels[saved[index]] || option.name})
        : ({ id: saved[index], name: labels[saved[index]] || saved[index], total: null }))
    }
    return output
  }

  function shortcutSaveNeedsReview() {
    var editor = service ? service.interestEditor : null
    if (!editor) return false
    var criterion = editor.criterion || ({})
    return editor.index >= 0 || Boolean(criterion.serviceId || criterion.featureId
      || String(criterion.label || "").trim() || String(editor.termText || "").trim()
      || (Array.isArray(criterion.terms) && criterion.terms.length))
  }

  function setupServiceActive(serviceId) {
    return service && Array.isArray(service.setupServiceIds)
      && service.setupServiceIds.indexOf(String(serviceId || "")) >= 0
  }

  function toggleSetupService(serviceId) {
    if (!service || service.queryBusy) return
    dismissTooltips()
    var identity = String(serviceId || "")
    var selected = Array.isArray(service.setupServiceIds)
      ? service.setupServiceIds.slice() : []
    var index = selected.indexOf(identity)
    if (index >= 0) selected.splice(index, 1)
    else if (identity && selected.length < 64) selected.push(identity)
    service.quickSetup(
      setupSearchField.text.trim(), service.setupGroup, service.setupSort, 1,
      selected, "", service.setupInstallFilter,
      service.setupPartyFilter, service.setupHardwareOnly)
  }

  function chooseSetupHardware(enabled) {
    if (!service || service.queryBusy) return
    dismissTooltips()
    service.quickSetup(
      setupSearchField.text.trim(), service.setupGroup, service.setupSort, 1,
      service.setupServiceIds, "", service.setupInstallFilter,
      service.setupPartyFilter, enabled === true)
  }

  function chooseSetupCategory(category) {
    if (!service || service.queryBusy) return
    dismissTooltips()
    service.quickSetup(
      setupSearchField.text.trim(), service.setupGroup, service.setupSort, 1,
      service.setupServiceIds, "", service.setupInstallFilter,
      service.setupPartyFilter, service.setupHardwareOnly, category)
  }

  function browseAll() {
    if (!service || service.queryBusy) return
    setupSearchDebounce.stop()
    setupSearchField.text = ""
    dismissTooltips()
    service.setupVerification = "all"
    service.quickSetup("", "", service.setupSort, 1, [], "", "all", "all", false, "")
  }

  function setupHasActiveFilters() {
    return Boolean(setupSearchField.text.trim()) || (service && (
      service.setupGroup || service.setupServiceIds.length
      || service.setupInstallFilter !== "all" || service.setupPartyFilter !== "all"
      || service.setupHardwareOnly || service.setupCategory
      || BrowseState.verificationFilter(service.setupVerification) !== "all"))
  }

  function chooseVerification(value) {
    if (!service || service.queryBusy) return
    service.setupVerification = BrowseState.verificationFilter(value)
    requestSetup(setupSearchField.text.trim(), service.setupGroup, service.setupSort, 1)
  }

  function chooseSetupFilters(installFilter, partyFilter) {
    if (!service) return
    dismissTooltips()
    service.quickSetup(
      setupSearchField.text.trim(), service.setupGroup, service.setupSort, 1,
      service.setupServiceIds, service.setupServiceFilter,
      installFilter || service.setupInstallFilter,
      partyFilter || service.setupPartyFilter)
  }

  function syncServiceDraft() {
    var values = service && service.preferences && Array.isArray(service.preferences.services)
      ? service.preferences.services : []
    serviceDraft = values.slice(0, 64)
    serviceDraftTouched = false
  }

  function serviceDraftSelected(serviceId) {
    return serviceDraft.indexOf(String(serviceId || "")) >= 0
  }

  function toggleServiceDraft(serviceId) {
    var identity = String(serviceId || "")
    if (!identity) return
    var next = serviceDraft.slice()
    var index = next.indexOf(identity)
    if (index >= 0) next.splice(index, 1)
    else if (next.length < 64) next.push(identity)
    serviceDraft = next
    serviceDraftTouched = true
  }

  function serviceCategories() {
    var output = []
    for (var index = 0; index < serviceOptions.length; index++) {
      var option = serviceOptions[index]
      if (!serviceOptionVisible(option)) continue
      var category = String(option.category || "Other")
      if (output.indexOf(category) < 0) output.push(category)
    }
    return output
  }

  function serviceOptionVisible(option) {
    var query = String(servicePickerSearch.text || "").trim().toLowerCase()
    if (!query) return true
    return (String(option.name || "") + " " + String(option.category || ""))
      .toLowerCase().indexOf(query) >= 0
  }

  function servicesForCategory(category) {
    var output = []
    for (var index = 0; index < serviceOptions.length; index++) {
      var option = serviceOptions[index]
      if (String(option.category || "") === String(category || "")
          && serviceOptionVisible(option)) output.push(option)
    }
    return output
  }

  function serviceOption(serviceId) {
    for (var index = 0; index < serviceOptions.length; index++) {
      if (String(serviceOptions[index].id || "") === String(serviceId || ""))
        return serviceOptions[index]
    }
    return null
  }

  function openServicesPicker() {
    openInterests(null)
  }

  function finishServices(ids) {
    if (!service || service.busy) return
    var selected = Array.isArray(ids) ? ids.slice(0, 64) : []
    if (!service.saveServiceChoices(selected, true)) return
    pendingServiceChoices = selected
  }

  function cancelServicePicker() {
    if (!servicePickerEditing) return
    syncServiceDraft()
    setupStage = "browse"
    servicePickerEditing = false
  }

  function captureRestoredInspector() {
    if (!setupDetailId || inspectorSnapshot) return
    var rows = matchRows.concat(discoveryRows).concat(setupRows).concat(resultRows)
    var frozen = service ? service.inspectorSnapshot : null
    var restored = frozen && frozen.id === setupDetailId ? frozen : InspectorState.snapshotFor(setupDetailId, rows, null)
    if (!restored && setupStage === "updates") {
      var info = updateInfo({id:setupDetailId})
      if (info) restored = updateDetailRow(info)
    }
    if (restored) setInspectorSnapshot(restored)
  }

  function setInspectorSnapshot(row) {
    inspectorSnapshot = JSON.parse(JSON.stringify(row))
    if (service) service.inspectorSnapshot = JSON.parse(JSON.stringify(row))
    var defaults = InspectorState.installDefaults(row, service && service.placementChoices
      ? service.placementChoices[row.id] : "")
    draftInstallEnabled = defaults.enable
    draftInstallSection = defaults.section
    inspectorActionError = ""
  }

  function openSetupDetail(row, invoker) {
    if (!row) return
    flushPanel()
    if (setupStage === "updates") {
      updatesPage.focusedId = String(row.id)
      updatesPage.focusedAction = "details"
    }
    if (root.detailPrototypeSession) {
      root.detailPrototypeInvoker = invoker || null
      root.detailPrototypeOpen = true
      return
    }
    dismissTooltips()
    setupDetailPanel.stopMedia()
    if (service && typeof service.cancelPendingReadme === "function")
      service.cancelPendingReadme("")
    setupDetailId = String(row.id || "")
    inspectorInvoker = invoker || null
    setInspectorSnapshot(row)
    if (service && "setupDetailId" in service) service.setupDetailId = setupDetailId
    setupReadmeExpanded = false
    setupDetailFocusPending = false
    ensureSetupPreview(row)
    Qt.callLater(function() { setupDetailPanel.takeFocus() })
  }

  function closeSetupDetail(restoreFocus) {
    flushPanel()
    var closingId = setupDetailId
    var invoker = inspectorInvoker
    dismissTooltips()
    setupDetailPanel.stopMedia()
    if (service && typeof service.cancelPendingReadme === "function")
      service.cancelPendingReadme(closingId)
    setupDetailId = ""
    inspectorSnapshot = null
    inspectorInvoker = null
    if (service && "setupDetailId" in service) service.setupDetailId = ""
    setupReadmeExpanded = false
    setupDetailFocusPending = false
    if (restoreFocus !== false && closingId && opened && setupStage === "updates" && !settingsOpen) {
      Qt.callLater(function() {
        if (!root.opened || root.setupDetailId || root.setupStage !== "updates") return
        updatesPage.restoreFocus()
      })
    }
    if (restoreFocus !== false && closingId && opened && setupStage === "browse" && !settingsOpen)
      Qt.callLater(function() {
        if (root.opened && !root.setupDetailId && root.setupStage === "browse"
            && !root.settingsOpen && !root.confirmationOpen) {
          if (invoker && invoker.visible && invoker.enabled)
            root.focusCardInView(invoker, root.currentScroll())
          else if (!root.focusInvokingCard(closingId)) root.focusWorkspace()
        }
      })
  }

  function focusInvokingCard(identity) {
    if (workspaceView === "discover") {
      if (discoverTab === "matches") {
        for (var m = 0; m < matchesRepeater.count; m++) {
          var match = matchesRepeater.itemAt(m)
          if (match && String(match.modelData.id) === identity) {
            focusCardInView(match.reviewButton, matchesScroll)
            return true
          }
        }
        return false
      }
      for (var d = 0; d < discoveryRepeater.count; d++) {
        var pick = discoveryRepeater.itemAt(d)
        if (pick && String(pick.pluginRow.id) === identity) {
          focusCardInView(pick, discoveryScroll)
          return true
        }
      }
    } else {
      for (var g = 0; g < setupGroupRepeater.count; g++) {
        var group = setupGroupRepeater.itemAt(g)
        if (group && group.focusCard(identity)) return true
      }
    }
    return false
  }

  function focusCardInView(card, scroll) {
    var flickable = scroll.contentItem
    if (flickable && "contentY" in flickable) {
      var point = card.mapToItem(flickable, 0, 0)
      var next = flickable.contentY
      if (point.y < 0 || card.height > scroll.height) next += point.y
      else if (point.y + card.height > scroll.height) next += point.y + card.height - scroll.height
      flickable.contentY = Math.max(0, Math.min(next, flickable.contentHeight - flickable.height))
    }
    card.forceActiveFocus()
  }

  function ensureSetupPreview(row) {
    if (!opened || settingsOpen || interestsOpen || ["browse", "updates"].indexOf(setupStage) < 0) return
    if (service && row && row.readmeAvailable === true
        && service.preferences.readmeEnrichment !== false
        && (String(service.readmePluginId || "") !== String(row.id || "")
          || service.readmeMediaIndexed !== true)
        && typeof service.loadReadme === "function") service.loadReadme(row)
  }

  function restoreSetupDetailFocus() {
    if (!setupDetailFocusPending || !opened || activeView !== "setup"
        || ["browse", "updates"].indexOf(setupStage) < 0 || !setupDetailRow || !setupDetailPanel.visible)
      return false
    setupDetailFocusPending = false
    setupDetailPanel.takeFocus()
    return true
  }

  function setupRowsForGroup(groupId) {
    if (!service || normalizedGrouping(service.setupAppliedGrouping) === "none")
      return setupRows
    var output = []
    for (var index = 0; index < setupRows.length; index++) {
      if (String(setupRows[index].displayGroup || setupRows[index].setupGroup || "") === String(groupId || ""))
        output.push(setupRows[index])
    }
    return output
  }

  function setupGroupLabel(groupId) {
    for (var index = 0; index < setupGroups.length; index++) {
      if (String(setupGroups[index].id || "") === String(groupId || ""))
        return String(setupGroups[index].label || groupId)
    }
    return "All plugins"
  }

  function setupTagsText(row) {
    var values = row && row.tags
    if (!values || typeof values.length !== "number") return ""
    var output = []
    for (var index = 0; index < values.length && index < 16; index++)
      output.push(String(values[index]))
    return output.join("  /  ")
  }

  function visibleSetupGroups() {
    if (service && normalizedGrouping(service.setupAppliedGrouping) === "category")
      return Array.isArray(service.setupSections) ? service.setupSections : []
    return [{ id: "", label: "All plugins", total: setupRows.length }]
  }

  function setupRowInstalled(row) {
    return Boolean(canonicalEntry(row))
  }

  function toggleSetupSelection(row) {
    if (!service || !row || service.batchRunning || !inspectorState(row).canQueue) return
    var selected = service.setupSelected(row.id)
    if (!selected && setupSelectedCount >= 50) return
    var candidate = JSON.parse(JSON.stringify(row))
    candidate.selectable = candidate.installAvailable === true
    candidate.exclusiveActivation = InspectorState.exclusive(candidate)
    if (service.setSetupSelected(candidate, !selected) && !selected
        && setupDetailId === String(row.id) && typeof service.updateSetupOption === "function") {
      if (candidate.barWidget === true) service.updateSetupOption(row.id, "barSection", draftInstallSection)
      if (candidate.exclusiveActivation === true) service.updateSetupOption(row.id, "activate", draftInstallEnabled)
    }
  }

  function setupResumePayload(stage) {
    var payload = editorResumePayload("")
    payload.view = "setup"
    payload.setupStage = stage || setupStage
    payload.setupQuery = setupSearchField.text.trim()
    payload.setupGroup = service ? service.setupGroup : ""
    payload.setupSort = service ? service.setupSort : "likes"
    payload.setupGrouping = normalizedGrouping(service ? service.setupGrouping : "none")
    payload.setupPage = service ? service.setupPage : 1
    payload.setupServices = service && Array.isArray(service.setupServiceIds)
      ? service.setupServiceIds.slice(0, 64) : []
    payload.setupServiceFilter = service ? service.setupServiceFilter : ""
    payload.setupInstallFilter = service ? service.setupInstallFilter : "all"
    payload.setupPartyFilter = service ? service.setupPartyFilter : "all"
    payload.setupHardwareOnly = service ? service.setupHardwareOnly : false
    payload.setupCategory = service ? service.setupCategory : ""
    payload.setupVerification = service ? BrowseState.verificationFilter(service.setupVerification) : "all"
    payload.workspaceView = workspaceView
    return payload
  }

  function confirmSetupBatch() {
    batchConfirmOpen = false
    if (!service || service.selfUpdateBusy || service.mutationBusy || service.batchRunning) return
    if (!service || !service.startSetupBatch(setupResumePayload("progress"))) return
    setupStage = "progress"
  }

  function setupStatusLabel(status) {
    if (status === "running") return "IN PROGRESS"
    if (status === "completed") return updateBatch ? "UPDATED" : "INSTALLED"
    if (status === "partial") return "NEEDS ATTENTION"
    if (status === "failed") return "NEEDS ATTENTION"
    if (status === "skipped") return updateBatch ? "SKIPPED" : "ALREADY PRESENT"
    return "WAITING"
  }

  function batchStatusCount(statuses) {
    var count = 0
    var values = service && Array.isArray(service.batchItems) ? service.batchItems : []
    for (var index = 0; index < values.length; index++) {
      if (statuses.indexOf(String(values[index].status || "")) >= 0) count++
    }
    return count
  }

  function syncDraft() {
    var current = service && service.preferences ? service.preferences : ({})
    draftWatchHardware = current.watchHardware !== false
    draftReadmes = current.readmeEnrichment !== false
    draftThumbnails = current.marketplaceThumbnails !== false
    settingsTouched = false
  }

  function saveSettings() {
    if (!service || typeof service.savePreferences !== "function") return
    var current = service.preferences && typeof service.preferences === "object"
      ? service.preferences : ({})
    var saved = JSON.parse(JSON.stringify(current))
    saved.watchHardware = draftWatchHardware
    saved.readmeEnrichment = draftReadmes
    saved.marketplaceThumbnails = draftThumbnails
    service.savePreferences(saved, "settings")
  }

  function resetSettings() {
    if (!service || service.busy) return
    draftWatchHardware = true
    draftReadmes = true
    draftThumbnails = true
    settingsTouched = true
    saveSettings()
  }

  function applyFilters() {
    if (canBrowse && typeof service.search === "function")
      service.search(
        searchField.text.trim(), chosenCategory,
        service.currentInstallFilter, service.currentPartyFilter)
  }

  function chooseFilters(installFilter, partyFilter) {
    if (!canBrowse) return
    service.search(
      searchField.text.trim(), chosenCategory,
      installFilter || service.currentInstallFilter,
      partyFilter || service.currentPartyFilter)
  }

  function filterCount(key) {
    var values = service && service.filterCounts ? service.filterCounts : ({})
    return Math.max(0, Number(values[key]) || 0)
  }

  function setupFilterCount(key) {
    var values = service && service.setupFilterCounts ? service.setupFilterCounts : ({})
    return Math.max(0, Number(values[key]) || 0)
  }

  function evidenceRows(channel) {
    return evidenceRowsFor(selectedRow, channel)
  }

  function evidenceRowsFor(row, channel) {
    var evidence = row && row.evidence ? row.evidence : ({})
    return Array.isArray(evidence[channel]) ? evidence[channel] : []
  }

  function evidenceText(row) {
    if (!row) return ""
    var text = String(row.signal || "Signal")
    if (row.detail) text += " / " + String(row.detail)
    text += "\nMatched \"" + String(row.term || "") + "\" in "
      + String(row.field || "listing") + " / evidence " + Number(row.contribution || 0)
    return text
  }

  function selectResult(index) {
    if (index < 0 || index >= resultRows.length) {
      selectedIndex = -1
      selectedId = ""
      narrowDetailOpen = false
      return
    }
    selectedIndex = index
    selectedId = String(resultRows[index].id || "")
  }

  function detailStatuses(row) {
    if (!row) return []
    var installed = effectiveInstalled(row)
    var enabled = effectiveEnabled(row)
    var section = barSection(row)
    var output = [service && !service.inventoryReady ? "Inventory pending" : (installed ? "Installed" : "Available")]
    output.push(row.firstParty === true ? "First party" : "Third party")
    if (installed) output.push(enabled ? "Enabled" : "Disabled")
    if (row.barWidget === true && section)
      output.push("Bar: " + section.charAt(0).toUpperCase() + section.slice(1))
    return output
  }

  function readmeExcerpt(row) {
    if (!row) return ""
    var summary = String(row.readmeSummary || "").trim()
    var description = String(row.description || "").trim()
    var compactSummary = summary.toLowerCase().replace(/\s+/g, " ")
    var compactDescription = description.toLowerCase().replace(/\s+/g, " ")
    return compactSummary && compactSummary !== compactDescription ? summary : ""
  }

  function currentReadmeContent() {
    return readmeContentFor(selectedRow)
  }

  function readmeContentFor(row) {
    if (!service || !row
        || service.preferences.readmeEnrichment === false
        || String(service.readmePluginId || "") !== String(row.id || "")) return ""
    return String(service.readmeContent || "")
  }

  function readmeBlocksFor(row) {
    if (!service || !row || service.preferences.readmeEnrichment === false
        || String(service.readmePluginId || "") !== String(row.id || "")) return []
    return Array.isArray(service.readmeBlocks) ? service.readmeBlocks : []
  }

  function readmeMediaFor(row) {
    if (!row || !service) return []
    if (String(service.readmePluginId || "") === String(row.id || "")
        && service.readmeMediaIndexed === true)
      return Array.isArray(service.readmeMedia) ? service.readmeMedia : []
    return Array.isArray(row.readmeMedia) ? row.readmeMedia : []
  }

  function detailThumbnail(row) {
    if (!row || !service || service.preferences.marketplaceThumbnails === false) return ""
    var image = service.thumbnails ? service.thumbnails[row.id] : null
    var url = String(row.previewThumbnail || row.previewImage || "")
    return image && image.url === url && (image.source !== "readme" || (service.preferences.readmeEnrichment !== false
      && image.repo === row.repo && image.listingCommit === row.listingCommit))
      && trustedLocalThumbnailUrl(image.localSource) ? String(image.localSource) : ""
  }

  function detailMetadata(row) {
    if (!row) return ({})
    var match = root.matchReasons(row) || row.searchReason || row.discoveryReason || row.serviceReason || row.reason || ""
    var evidence = root.evidenceRowsFor(row, "hardware").map(function(item) { return root.evidenceText(item) })
    return Object.assign({}, row, {
      summary:readmeExcerpt(row), requirements:row.discoverySetup || row.editorialSetup || row.installNote || "",
      matchReason:String(match) + (evidence.length ? "\n\n" + evidence.join("\n\n") : ""),
      readmeText:readmeContentFor(row), readmeLoading:readmeLoading(row),
      readmeBlocks:readmeBlocksFor(row), readmeEnrichment:service && service.preferences.readmeEnrichment !== false,
      sourceAvailable:Boolean(InspectorState.projectUrl({repo:row.snapshotUrl || row.repo})),
      marketplaceAvailable:Boolean(InspectorState.projectUrl({marketplaceUrl:row.marketplaceUrl})),
      matchUnread:Boolean(service && service.matchUnread(row)),
      matchLabel:discoveryEnabled && Array.isArray(row.matchedInterests) && row.matchedInterests.length ? matchCause(row) : "",
      reviewText:sourceReviewText(row),
      recommendationScore:service && service.hasAnalyzed ? row.recommendationScore : null,
      score:service && service.hasAnalyzed ? row.score : null
    })
  }

  function detailPresentation(row) {
    var state = inspectorState(row)
    var opening = service && service.pluginOpenPending(row.id)
    return Object.assign({}, state, InspectorState.updatePresentation(canonicalEntry(row), updateInfo(row), updateContext()), {
      primaryAction:state.action,
      primaryLabel:opening ? "Opening…" : state.action === "install" ? "Install" : state.primaryLabel,
      primaryEnabled:primaryEnabled(row),
      selected:Boolean(service && service.setupSelected(row.id)),
      section:state.installed ? state.selectedSection : draftInstallSection,
      canPlace:state.installed ? state.canPlace : state.canInstall && draftInstallEnabled,
      showRemove:!state.included && String(row.id) !== pluginId,
      showToggle:String(row.id) !== pluginId,
      message:inspectorActionError || (service ? service.pluginOpenError(row.id) : "") || state.message,
      openHint:state.openHint
    })
  }

  function readmeMediaLoading(row) {
    if (!row || !service) return false
    var identity = String(row.id || "")
    return (service.queryBusy && service.activeAction === "readme-plugin"
      && service.activeRequest && String(service.activeRequest.pluginId || "") === identity)
      || String(service.pendingReadmeId || "") === identity
  }

  function trustedPreviewUrl(value) {
    var url = String(value || "")
    return /^https:\/\/raw\.githubusercontent\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/[0-9a-f]{40}\/[^\s?#]+$/.test(url)
      || /^https:\/\/github\.com\/user-attachments\/assets\/[A-Za-z0-9-]{20,}$/.test(url)
      || /^https:\/\/user-images\.githubusercontent\.com\/[^\s?#]+$/.test(url)
  }

  function trustedLocalPreviewUrl(value) {
    if (!service) return false
    return MediaPaths.trustedFile(value, service.cacheRoot,
      /^preview-[0-3]-[0-9a-f]{12}\.(?:png|jpg|webp|gif)$/)
  }

  function trustedLocalThumbnailUrl(value) {
    if (!service || !service.cacheRoot) return false
    return MediaPaths.trustedFile(value, service.cacheRoot,
      /^thumb-[0-9a-f]{32}-[0-9a-f]{16}\.(?:png|jpg|webp|gif)$/)
  }

  property string thumbnailDemandKey: ""
  property var thumbnailDemandIds: ({})
  readonly property bool thumbnailDemandActive: uiAwake && !settingsOpen && !interestsOpen
    && (setupStage === "browse" || (setupStage === "updates" && Boolean(setupDetailRow)))
    && service && service.preferences.marketplaceThumbnails !== false
  // Observe semantic inputs, not thumbnail completion: completion must not
  // request the same work again. Geometry is observed by HelpScrollView below.
  readonly property var thumbnailInputs: [thumbnailDemandActive, setupDetailRow, workspaceView,
    discoverTab, setupRows, matchRows, discoveryRows, browseDensity, filtersExpanded,
    service ? service.preferences.readmeEnrichment : false]
  onThumbnailInputsChanged: scheduleThumbnailDemand()
  function scheduleThumbnailDemand() {
    if (!thumbnailDemandTimer) return
    if (!thumbnailDemandActive) {
      thumbnailDemandTimer.stop()
      setThumbnailRows([])
    } else if (!thumbnailDemandTimer.running) thumbnailDemandTimer.start()
  }
  function setThumbnailRows(rows) {
    if (!service || typeof service.setThumbnailRows !== "function") return
    var key = JSON.stringify([service.preferences.readmeEnrichment !== false, rows.map(function(row) {
      return [row.id, row.previewThumbnail || row.previewImage || "", row.repo || "", row.listingCommit || ""]
    })])
    if (key === thumbnailDemandKey) return
    thumbnailDemandKey = key
    var ids = ({})
    for (var row of rows) ids[String(row.id)] = true
    thumbnailDemandIds = ids
    service.setThumbnailRows(rows)
  }
  function refreshThumbnailDemand() {
    if (!thumbnailDemandActive) { setThumbnailRows([]); return }
    if (setupDetailRow) { setThumbnailRows([setupDetailRow]); return }
    var rows = []
    if (workspaceView === "discover") {
      var repeater = discoverTab === "matches" ? matchesRepeater : discoveryRepeater
      var viewport = currentScroll()
      for (var c = 0; c < repeater.count; c++) {
        var item = repeater.itemAt(c)
        if (!item) continue
        var point = item.mapToItem(viewport, 0, 0)
        if (point.y + item.height > -100 && point.y < viewport.height + 100)
          rows.push(item.pluginRow || item.modelData)
      }
    } else {
      for (var i = 0; i < setupGroupRepeater.count; i++) {
        var group = setupGroupRepeater.itemAt(i)
        if (group && group.visible) rows = rows.concat(group.visibleThumbnailRows())
      }
    }
    setThumbnailRows(rows)
  }
  Timer {
    id: thumbnailDemandTimer
    objectName: "thumbnailDemandTimer"
    interval: 40
    onTriggered: root.refreshThumbnailDemand()
  }
  function invalidateThumbnail(id, source) {
    if (!source || !service || typeof service.invalidateThumbnail !== "function") return
    var cached = service.thumbnails ? service.thumbnails[String(id)] : null
    if (cached && String(cached.localSource || "") === String(source))
      service.invalidateThumbnail(String(id), String(source))
  }
  function imageBucket(size, dpr) {
    return Math.max(128, Math.min(4096, Math.ceil(Math.max(1, size) * Math.max(1, dpr) / 128) * 128))
  }

  function trustedDemoUrl(value) {
    var url = String(value || "")
    return trustedPreviewUrl(url)
      || /^https:\/\/www\.youtube\.com\/watch\?v=[A-Za-z0-9_-]{6,20}$/.test(url)
  }

  function openReadmeMedia(media) {
    if (!media || !trustedDemoUrl(media.url)) return
    Qt.openUrlExternally(String(media.url))
  }

  function toggleReadme() {
    if (!selectedRow || selectedRow.readmeAvailable !== true || !service) return
    if (readmeExpanded) {
      readmeExpanded = false
      return
    }
    readmeExpanded = true
    if (!currentReadmeContent() && typeof service.loadReadme === "function")
      service.loadReadme(selectedRow)
  }

  function toggleSetupReadme() {
    if (!setupDetailRow || setupDetailRow.readmeAvailable !== true || !service) return
    if (setupReadmeExpanded) {
      setupReadmeExpanded = false
      return
    }
    setupReadmeExpanded = true
    if (!readmeContentFor(setupDetailRow) && typeof service.loadReadme === "function")
      service.loadReadme(setupDetailRow)
  }

  function readmeLoading(row) {
    return Boolean(row && service && service.preferences.readmeEnrichment !== false
      && ((service.queryBusy && service.activeAction === "readme-plugin" && service.activeRequest
        && String(service.activeRequest.pluginId || "") === String(row.id || ""))
        || String(service.pendingReadmeId || "") === String(row.id || "")))
  }

  function canToggle(row) {
    return inspectorState(row).canToggle
  }

  function canonicalEntry(row) {
    return row && service && typeof service.inventoryEntry === "function"
      ? service.inventoryEntry(row.id) : null
  }

  function inspectorState(row) {
    var operation = row && service && typeof service.pluginOperation === "function"
      ? service.pluginOperation(row.id) : ({})
    var batchFailure = false
    var batch = service && Array.isArray(service.batchItems) ? service.batchItems : []
    for (var i = 0; row && i < batch.length; i++) {
      if (String(batch[i].id) === String(row.id)
          && ["failed", "partial"].indexOf(String(batch[i].status)) >= 0)
        batchFailure = true
    }
    return InspectorState.resolve(row, canonicalEntry(row), {
      inventoryReady: root.canManagePlugins,
      operation: operation,
      selected: row && service && service.setupSelected(row.id),
      batchRunning: service && service.batchRunning,
      mutationBusy: service && service.mutationBusy,
      selfUpdateBusy: service && service.selfUpdateBusy,
      batchKind: service ? service.batchKind : "install",
      batchFailure: batchFailure,
      selfId: pluginId,
      rememberedSection: row && service && service.placementChoices ? service.placementChoices[row.id] : ""
    })
  }

  function mutationRow(row) {
    var result = JSON.parse(JSON.stringify(row))
    var state = inspectorState(row)
    result.barWidget = state.widget
    result.removable = state.canRemove
    return result
  }

  function inspectorPrimary(row) {
    if (!row || !service) return
    if (service.selfUpdateBusy) return
    var state = inspectorState(row)
    inspectorActionError = ""
    if (state.action === "install") requestAction("install", row)
    else if (state.action === "activate") requestAction("activate", row)
    else if (state.action === "enable") {
      if (!service.enablePlugin(mutationRow(row), barSection(row), editorResumePayload(row.id)))
        inspectorActionError = "The plugin could not be enabled. Check its current state and try again."
    }
    else if (state.action === "open") {
      setupDetailPanel.stopMedia()
      service.cancelEditorRestore()
      if (!service.openPlugin(row)) inspectorActionError = "Open is not currently available for this plugin."
    }
    else if (state.action === "review") setupStage = "review"
    else if (state.action === "progress") setupStage = "progress"
    else if (state.action === "project" && state.projectUrl) Qt.openUrlExternally(state.projectUrl)
    else if (state.action === "retry" && !state.pending && !service.batchRunning) {
      var lastAction = String(service.pluginOperation(row.id).lastAction || "")
      if (lastAction === "update-plugin" && !updatesIdle) return
      if (state.known && ((!state.installed && lastAction === "install-plugin")
          || (state.installed && lastAction === "remove-plugin"))) {
        requestAction(lastAction === "install-plugin" ? "install" : "remove", row, true)
        return
      }
      if (typeof service.retryPluginOperation !== "function"
          || !service.retryPluginOperation(mutationRow(row), editorResumePayload(row.id)))
        inspectorActionError = "The action could not start. Wait for the current operation or rescan system, then try again."
    }
  }

  function primaryEnabled(row) {
    if (service && service.selfUpdateBusy) return false
    var state = inspectorState(row)
    if (state.action === "open") return state.canOpen && service && !service.pluginOpenBusy
    if (state.action === "enable") return state.canToggle
    if (state.action === "activate") return state.canActivateBar
    if (state.action === "project") return Boolean(state.projectUrl)
    if (state.action === "review" || state.action === "progress") return true
    if (state.action === "retry") return !state.pending && service && !service.batchRunning
      && (String(service.pluginOperation(row.id).lastAction || "") !== "update-plugin" || updatesIdle)
    return state.action === "install" && state.canInstall
  }

  function sourceReviewText(row) {
    var state = inspectorState(row)
    var verification = String(row.verification || "unknown")
    return (state.included ? "Included with Omarchy" : row.localOnly ? "Local installation" : "Community") + " · "
      + (verification === "verified" ? "Verified" : verification === "unverified" ? "Unverified"
        : verification === "not-applicable" ? "Marketplace verification not applicable" : "Verification not reported")
      + (row.reviewState ? "\n" + String(row.reviewState) : "")
  }

  function operationPending(row) {
    return row && service && typeof service.pluginPending === "function"
      && service.pluginPending(row.id)
  }

  function operationError(row) {
    return row && service && typeof service.pluginError === "function"
      ? service.pluginError(row.id) : ""
  }

  function operationProgress(row) {
    return row && service && typeof service.pluginProgress === "function"
      ? service.pluginProgress(row.id) : ""
  }

  function effectiveInstalled(row) {
    return Boolean(canonicalEntry(row))
  }

  function effectiveEnabled(row) {
    var entry = canonicalEntry(row)
    return Boolean(entry && entry.enabled === true)
  }

  function barSection(row) {
    var state = inspectorState(row)
    return state.widget ? state.selectedSection : ""
  }

  function rememberBarSection(row, section) {
    if (!row || !inspectorState(row).widget
        || ["left", "center", "right"].indexOf(section) < 0) return
    if (!service) return
    var next = ({})
    for (var key in service.placementChoices) next[key] = service.placementChoices[key]
    next[String(row.id || "")] = section
    service.placementChoices = next
  }

  function chooseBarSection(row, section) {
    if (!row || !service) return
    var state = inspectorState(row)
    if (!state.canPlace || !InspectorState.section(section)) return
    rememberBarSection(row, section)
    if (!state.enabled || state.actualSection === section) return
    service.placePlugin(mutationRow(row), section, editorResumePayload(row.id))
  }

  function togglePlugin(row) {
    if (!canToggle(row) || !service || operationPending(row)) return
    var resume = editorResumePayload(row.id)
    if (effectiveEnabled(row)) {
      if (row.barWidget === true) rememberBarSection(row, barSection(row))
      service.disablePlugin(mutationRow(row), resume)
    } else service.enablePlugin(mutationRow(row), barSection(row), resume)
  }

  property bool pendingRecovery: false

  function canConfirmAction(action, row, recovery) {
    var state = inspectorState(row)
    if (action === "activate") return state.canActivateBar
    if (action === "install") return state.canInstall || (recovery && state.canChange
      && !state.installed && row.installAvailable === true && !state.batchOwned)
    if (action === "remove") return state.canRemove || (recovery && state.canChange
      && state.installed && !state.included && !state.batchOwned)
    return false
  }

  function requestAction(action, row, recovery) {
    if (!row || !service || operationPending(row) || service.batchRunning) return
    var state = inspectorState(row)
    if (!canConfirmAction(action, row, recovery === true)) return
    if (action !== "install" && action !== "remove" && action !== "activate") return
    pendingAction = action
    pendingRecovery = recovery === true
    actionTarget = mutationRow(row)
    if (action === "remove" && pendingRecovery) actionTarget.removable = true
    var defaults = InspectorState.installDefaults(row, barSection(row))
    pendingInstallEnabled = setupDetailId === String(row.id) ? draftInstallEnabled : defaults.enable
    pendingInstallSection = state.widget && pendingInstallEnabled
      ? (setupDetailId === String(row.id) ? draftInstallSection : defaults.section) : ""
    if (pendingRecovery && action === "install") {
      var previous = service.pluginOperation(row.id).lastRequest || ({})
      if (typeof previous.enableAfter === "boolean") pendingInstallEnabled = previous.enableAfter
      pendingInstallSection = state.widget && pendingInstallEnabled
        ? InspectorState.section(previous.barSection) || defaults.section : ""
    }
    actionConfirm.selectedIndex = 0
    actionConfirmOpen = true
    focusScope.forceActiveFocus()
  }

  function cancelAction() {
    actionConfirmOpen = false
    pendingAction = ""
    actionTarget = null
    actionConfirm.selectedIndex = 0
    Qt.callLater(function() {
      if (root.activeView === "setup" && root.setupDetailId && setupDetailPanel.visible)
        setupDetailPanel.takeFocus()
      else focusScope.forceActiveFocus()
    })
  }

  function confirmAction() {
    var action = pendingAction
    var row = actionTarget
    var resume = editorResumePayload(row ? row.id : "")
    actionConfirmOpen = false
    pendingAction = ""
    actionTarget = null
    if (!row || !service) return
    var state = inspectorState(row)
    var started = false
    if (action === "install" && canConfirmAction(action, row, pendingRecovery))
      started = service.installPlugin(row, pendingInstallSection, resume, pendingInstallEnabled)
    else if (action === "remove" && canConfirmAction(action, row, pendingRecovery)) started = service.removePlugin(row, resume)
    else if (action === "activate" && canConfirmAction(action, row, false)) started = service.enablePlugin(mutationRow(row), "", resume)
    if (!started) inspectorActionError = "The plugin state changed or another operation is active. Review its current state and try again."
    Qt.callLater(function() { if (root.opened && setupDetailPanel.visible) setupDetailPanel.takeFocus() })
  }

  function editorResumePayload(selectedId) {
    return {
      view: "setup",
      workspaceView: workspaceView,
      discoverTab: discoverTab,
      settingsOpen: settingsOpen,
      interestsOpen: interestsOpen,
      interestsFromSettings: interestsFromSettings,
      scrollAnchor: viewportAnchor(),
      updatesQuery: updatesPage.query,
      updatesScroll: updatesPage.scrollPosition(),
      updatesContext: updatesPage.context(),
      inspectorScroll: setupDetailPanel.scrollPosition(),
      inspectorFocus: setupDetailPanel.focusName(),
      installDraft: {enable:draftInstallEnabled, section:draftInstallSection},
      windowWidth: window.width,
      windowHeight: window.height,
      setupStage: setupStage,
      setupQuery: setupSearchField.text,
      setupGroup: service ? service.setupGroup : "",
      setupSort: service ? service.setupSort : "likes",
      browseSort: service ? service.browseSort : "likes",
      setupPage: service ? service.setupPage : 1,
      setupServices: service ? service.setupServiceIds.slice() : [],
      setupInterestCriteria: service ? JSON.parse(JSON.stringify(service.setupInterestCriteria)) : [],
      setupVerification: service ? BrowseState.verificationFilter(service.setupVerification) : "all",
      setupGrouping: normalizedGrouping(service ? service.setupGrouping : "none"),
      query: searchField.text,
      category: chosenCategory,
      installFilter: service ? service.currentInstallFilter : "all",
      partyFilter: service ? service.currentPartyFilter : "all",
      selectedId: selectedId || setupDetailId || "",
      restoreDraft: true,
      settingsTouched: settingsTouched,
      draft: {
        watchHardware: draftWatchHardware,
        readmeEnrichment: draftReadmes,
        marketplaceThumbnails: draftThumbnails
      }
    }
  }

  function clampSelection() {
    if (!resultRows.length) {
      selectedIndex = -1
      narrowDetailOpen = false
      return
    }
    var targetId = selectedId || pendingSelectedId
    if (targetId) {
      for (var index = 0; index < resultRows.length; index++) {
        if (String(resultRows[index].id || "") === targetId) {
          selectedIndex = index
          selectedId = targetId
          pendingSelectedId = ""
          return
        }
      }
      pendingSelectedId = ""
      selectResult(-1)
    }
    if (selectedIndex < 0 && !narrowWorkspace) selectResult(0)
  }

  function statusText() {
    if (!service) return "Starting the Outfit service."
    if (service.error) return service.error
    if (service.notice) return service.notice
    if (service.mutationActive) {
      if (service.mutationAction === "install-plugin") return "Installing the selected plugin in the background."
      if (service.mutationAction === "update-plugin") return "Updating the selected plugin in the background."
      if (service.mutationAction === "enable-plugin") return "Enabling the selected plugin in the background."
      if (service.mutationAction === "disable-plugin") return "Disabling the selected plugin in the background."
      if (service.mutationAction === "place-plugin") return "Moving the selected bar widget in the background."
      if (service.mutationAction === "remove-plugin") return "Removing the selected plugin in the background."
    }
    if (service.queryBusy) {
      if (service.activeAction === "analyze") return "Reading local signals and matching marketplace listings."
      if (service.activeAction === "rescan") return "Checking local hardware signals without network access."
      if (service.activeAction === "verify-inventory") return "Checking the resulting plugin state."
      if (service.activeAction === "save-preferences") return "Saving settings to your private local config."
      if (service.activeAction === "readme-plugin") return "Loading the selected plugin's README."
      if (service.activeAction === "refresh") return "Refreshing marketplace metadata."
      return "Searching listings and selected README content."
    }
    if (service.batchRunning) return updateBatch ? "Batch update is updating plugins in sequence." : "Batch install is installing plugins in sequence."
    if (!service.hasAnalyzed) return "Browse now — catalog search is ready. Local fit checks are optional."
    return resultRows.length + " matches using this system's hardware and capabilities."
  }

  function busySubtitle() {
    if (!service) return "Starting Outfit…"
    if (service.selfUpdateBusy) return String((service.selfUpdateState || {}).message || "Updating Outfit & reopening…")
    if (service.batchRunning) return updateBatch ? "Batch update in progress…" : "Batch install in progress…"
    if (service.mutationActive) return service.pluginProgress(service.activeMutation.pluginId)
    if (service.hasCheckingOperations()) return "Checking plugin state…"
    if (service.mutationBusy) return "Updating plugin…"
    if (service.startupBannerVisible) return String(service.startupSummary || "")
    if (service.backgroundBusy) {
      if (service.startupQuiet || service.startupDismissed) return ""
      if (service.backgroundAction === "analyze") return "Checking system…"
      if (service.backgroundAction === "rescan")
        return service.backgroundAutomatic ? String(service.updateStatus || "") : "Checking system…"
      return "Refreshing catalog…"
    }
    if (service.backgroundError) return "Update needs attention · More actions"
    if (service.queryBusy) {
      if (service.activeAction === "save-preferences") return "Saving…"
      if (service.activeAction === "diagnostics") return "Checking diagnostics…"
    }
    return String(service.updateStatus || "")
  }

  function timeLabel(seconds) {
    var value = Number(seconds) || 0
    return value > 0 ? new Date(value * 1000).toLocaleString() : "Not yet available"
  }

  onResultRowsChanged: { clampSelection(); captureRestoredInspector() }
  onNarrowWorkspaceChanged: clampSelection()
  onSelectedIdChanged: readmeExpanded = false

  component BarSectionButton: Button {
    required property var pluginRow
    required property string section
    property int resultIndex: -1
    text: section.charAt(0).toUpperCase() + section.slice(1)
    foreground: root.foreground
    bordered: true
    focusable: true
    selected: root.barSection(pluginRow) === section
    enabled: root.inspectorState(pluginRow).canPlace
    onClicked: {
      if (resultIndex >= 0) root.selectResult(resultIndex)
      root.chooseBarSection(pluginRow, section)
    }
  }

  component StatusBadge: Rectangle {
    required property string label
    property real labelSize: root.supportingSize
    property bool emphasized: false
    property bool filled: label === "Installed"
    property bool compactPadding: false
    width: badgeLabel.implicitWidth + Style.space(compactPadding ? 10 : 16)
    height: badgeLabel.implicitHeight + Style.space(compactPadding ? 4 : 8)
    radius: filled ? Style.cornerRadius : height / 2
    color: filled ? root.foreground : emphasized
      ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.13)
      : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.065)
    Accessible.role: Accessible.StaticText
    Accessible.name: label

    Text {
      id: badgeLabel
      anchors.centerIn: parent
      text: parent.label
      textFormat: Text.PlainText
      color: parent.filled ? root.background : (parent.emphasized ? Color.accent : root.secondary)
      font.family: root.fontFamily
      font.pixelSize: parent.labelSize
      font.bold: parent.filled || parent.emphasized
    }
  }

  // Passive thumbnail decoration: clicks still belong to the containing card.
  component NewListingTag: Rectangle {
    objectName: "newListingOverlay"
    property real labelSize: root.browseMetadataSize
    anchors.top: parent.top
    anchors.right: parent.right
    anchors.margins: Style.space(3)
    width: newLabel.implicitWidth + Style.space(6)
    height: newLabel.implicitHeight + Style.space(2)
    radius: Style.space(2)
    color: root.background
    Text {
      id: newLabel
      objectName: "newListingText"
      anchors.centerIn: parent
      text: "New"
      color: Color.accent
      font.family: root.fontFamily
      font.pixelSize: parent.labelSize
      font.bold: true
    }
  }

  component CardFooter: Item {
    id: footer
    required property var pluginRow
    property real labelSize: root.browseMetadataSize
    property bool uppercaseKinds: false
    property real minimumHeight: 0
    readonly property string kindsText: {
      // Repeater rows can expose QVariant sequences rather than JS Arrays.
      // Normalize here so every kind participates in the footer's wrap decision.
      var values = pluginRow.kinds
      var kinds = []
      if (values && typeof values !== "string")
        for (var i = 0; i < values.length; i++) kinds.push(String(values[i]))
      return Presentation.pluginKinds({kinds:kinds, kind:pluginRow.kind})
    }
    readonly property bool wrapRow: verification.visible
      && kind.implicitWidth + verification.implicitWidth + Style.space(8) > width
    height: Math.max(minimumHeight, wrapRow ? kind.height + Style.space(4) + verification.height
      : Math.max(kind.height, verification.visible ? verification.height : 0))
    Text {
      id: kind
      objectName: "cardKindLabel"
      y: footer.wrapRow ? 0 : (parent.height - height) / 2
      width: Math.max(1, parent.width - (!footer.wrapRow && verification.visible ? verification.width + Style.space(8) : 0))
      text: footer.uppercaseKinds ? footer.kindsText.toUpperCase() : footer.kindsText
      textFormat: Text.PlainText
      color: root.secondary
      font.family: root.fontFamily
      font.pixelSize: footer.labelSize
      wrapMode: Text.Wrap
    }
    Text {
      id: verification
      objectName: "cardVerificationLabel"
      anchors.right: parent.right
      y: footer.wrapRow ? parent.height - height : (parent.height - height) / 2
      width: Math.min(implicitWidth, parent.width)
      visible: ["verified", "unverified"].indexOf(footer.pluginRow.verification) >= 0
      text: footer.pluginRow.verification === "verified" ? "Verified" : "Unverified"
      textFormat: Text.PlainText
      color: kind.color
      font: kind.font
      wrapMode: Text.Wrap
    }
  }

  component ServiceChoiceCard: BorderSurface {
    id: serviceChoice
    required property var serviceOption
    readonly property bool chosen: root.serviceDraftSelected(serviceOption.id)

    height: Style.space(68)
    radius: Style.cornerRadius
    color: chosen
      ? Style.selectedFillFor(root.foreground, Color.accent) : root.faint
    borderSpec: activeFocus ? Border.controlSpec("focus", root.foreground, Color.accent)
      : (chosen ? Border.controlSpec("selected", root.foreground, Color.accent) : Border.none())
    activeFocusOnTab: true
    Keys.onReturnPressed: root.toggleServiceDraft(serviceOption.id)
    Keys.onEnterPressed: root.toggleServiceDraft(serviceOption.id)
    Keys.onSpacePressed: root.toggleServiceDraft(serviceOption.id)
    Accessible.role: Accessible.CheckBox
    Accessible.name: String(serviceOption.name || serviceOption.id)
    Accessible.checkable: true
    Accessible.checked: chosen
    Accessible.onToggleAction: root.toggleServiceDraft(serviceOption.id)

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        serviceChoice.forceActiveFocus()
        root.toggleServiceDraft(serviceChoice.serviceOption.id)
      }
    }

    Row {
      anchors.fill: parent
      anchors.margins: Style.space(10)
      spacing: Style.space(9)

      Rectangle {
        width: Style.space(22)
        height: width
        anchors.verticalCenter: parent.verticalCenter
        radius: Style.space(5)
        color: serviceChoice.chosen ? Color.accent : "transparent"
        border.width: 1
        border.color: serviceChoice.chosen ? Color.accent : root.secondary

        Text {
          anchors.centerIn: parent
          text: serviceChoice.chosen ? "X" : ""
          textFormat: Text.PlainText
          color: root.background
          font.family: root.fontFamily
          font.pixelSize: root.supportingSize
          font.bold: true
        }
      }

      Column {
        width: parent.width - Style.space(31)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          width: parent.width
          text: serviceChoice.serviceOption.name || serviceChoice.serviceOption.id
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: root.readingSize
          font.bold: serviceChoice.chosen
          elide: Text.ElideRight
        }
        Text {
          width: parent.width
          text: Number(serviceChoice.serviceOption.total || 0) + " plugin"
            + (Number(serviceChoice.serviceOption.total || 0) === 1 ? "" : "s")
            + (Number(serviceChoice.serviceOption.installable || 0) > 0
              ? " / " + Number(serviceChoice.serviceOption.installable) + " installable" : "")
          textFormat: Text.PlainText
          color: root.secondary
          font.family: root.fontFamily
          font.pixelSize: root.supportingSize
          elide: Text.ElideRight
        }
      }
    }
  }

  component CardCopy: Column {
    id: cardCopy
    required property var pluginRow
    property bool searchActive: false
    property int lines: 4
    property real copySize: root.browseReadingSize
    readonly property string snippet: searchActive ? String(pluginRow.searchSnippet || "").slice(0, 240) : ""
    readonly property string sourceLabel: snippet && /readme/i.test(String(pluginRow.searchReason || "")) ? "README match" : ""
    Text {
      objectName: "searchExcerptLabel"
      visible: Boolean(cardCopy.sourceLabel)
      width: parent.width
      text: cardCopy.sourceLabel
      textFormat: Text.PlainText
      color: root.secondary
      font.family: root.fontFamily
      font.pixelSize: cardCopy.copySize
      maximumLineCount: 1
      elide: Text.ElideRight
      Accessible.name: text
    }
    Text {
      objectName: "cardDescription"
      width: parent.width
      text: cardCopy.snippet || cardCopy.pluginRow.description || "No description supplied."
      textFormat: Text.PlainText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: cardCopy.copySize
      wrapMode: Text.WordWrap
      maximumLineCount: Math.max(1, cardCopy.lines - (cardCopy.sourceLabel ? 1 : 0))
      elide: Text.ElideRight
      Accessible.name: text
    }
  }

  component SetupPluginCard: BorderSurface {
    id: setupPluginCard
    required property var pluginRow
    property bool discoveryCard: false
    property bool matchCard: false
    readonly property bool browseCard: !discoveryCard && !matchCard
    readonly property bool searchCopyActive: browseCard && Boolean(setupSearchField.text.trim())
      && root.service && root.service.setupSearch.active
    readonly property real copySize: browseCard ? root.browseReadingSize : root.readingSize
    readonly property real metadataSize: browseCard ? root.browseMetadataSize : root.supportingSize
    readonly property var density: matchCard ? Presentation.densityProfile("list") : discoveryCard ? Presentation.densityProfile("comfortable") : root.densityProfile
    readonly property bool listRow: density.name === "list"
    readonly property var listLayout: Presentation.listLayout(width, Style.space(640), Style.space(1000))
    readonly property bool inspected: root.setupDetailId === String(pluginRow.id || "")
    readonly property bool chosen: root.service && root.service.setupSelected(pluginRow.id)
    readonly property string thumbnailUrl: String(pluginRow.previewThumbnail || pluginRow.previewImage || "")
    readonly property var thumbnail: root.service && root.service.thumbnails
      ? root.service.thumbnails[pluginRow.id] : null
    readonly property bool thumbnailMatches: Boolean(thumbnail && thumbnail.url === thumbnailUrl
      && (thumbnail.source !== "readme" || (root.service.preferences.readmeEnrichment !== false
        && thumbnail.repo === pluginRow.repo && thumbnail.listingCommit === pluginRow.listingCommit)))
    readonly property bool canLoadThumbnail: Boolean(thumbnailUrl || (root.service
      && root.service.preferences.readmeEnrichment !== false && pluginRow.repo
      && /^[0-9a-f]{40}$/.test(String(pluginRow.listingCommit || ""))))
    readonly property string localThumbnail: thumbnailMatches
      ? String(thumbnail.localSource || "") : ""
    function previewStatus(status) {
      if (status === Image.Error || (thumbnailMatches && thumbnail.state === "failed")) return "Preview unavailable"
      if (canLoadThumbnail && (!thumbnailMatches || thumbnail.state === "deferred" || status === Image.Loading)) return "Loading preview…"
      return "No preview available"
    }
    readonly property bool showThumbnail: root.service
      && root.service.preferences.marketplaceThumbnails !== false
    readonly property bool imageDemand: root.uiAwake && visible && showThumbnail && !root.setupDetailId
      && root.thumbnailDemandIds[String(pluginRow.id)] === true
    FontMetrics { id: descriptionMetrics; font.family: root.fontFamily; font.pixelSize: setupPluginCard.copySize }
    FontMetrics { id: captionMetrics; font.family: root.fontFamily; font.pixelSize: setupPluginCard.metadataSize }
    FontMetrics { id: headingMetrics; font.family: root.fontFamily; font.pixelSize: Style.font.subtitle }

    height: listRow ? Math.max(Style.space(listLayout.minimumHeight), cardLayout.implicitHeight + Style.space(16))
      : Math.max(Style.space(176), cardLayout.implicitHeight + Style.space(density.padding * 2))
    radius: Style.cornerRadius
    color: inspected ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.11)
      : (chosen ? Style.selectedFillFor(root.foreground, Color.accent) : root.faint)
    borderSpec: inspected || activeFocus ? Border.controlSpec("focus", root.foreground, Color.accent)
      : (chosen ? Border.controlSpec("selected", root.foreground, Color.accent) : Border.none())
    activeFocusOnTab: true
    onActiveFocusChanged: if (activeFocus && !discoveryCard && !matchCard) root.rovingResultId = String(pluginRow.id)
    Accessible.description: "Arrow keys move between plugins. Enter opens details. F2 explores metric information with arrows; Enter or Space shows help. Tab returns to filters. F6 focuses the toolbar."
    Keys.onTabPressed: function(event) {
      if (root.browseNavigation) root.focusFilters()
      else event.accepted = false
    }
    Keys.onBacktabPressed: function(event) {
      if (root.browseNavigation) root.focusFilters()
      else event.accepted = false
    }
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_F2 && !discoveryCard && !matchCard) {
        root.enterCardContents(setupPluginCard)
        event.accepted = true
      } else if ((event.key === Qt.Key_Left || event.key === Qt.Key_Right)
                 && event.modifiers === Qt.NoModifier && !discoveryCard && !matchCard) {
        root.moveCardFocus(setupPluginCard, event.key)
        event.accepted = true
      }
    }
    Keys.onReturnPressed: root.openSetupDetail(pluginRow, setupPluginCard)
    Keys.onEnterPressed: root.openSetupDetail(pluginRow, setupPluginCard)
    Keys.onSpacePressed: root.openSetupDetail(pluginRow, setupPluginCard)
    Keys.onUpPressed: function(event) {
      if (!discoveryCard && !matchCard && event.modifiers === Qt.NoModifier) root.moveCardFocus(setupPluginCard, Qt.Key_Up)
      else event.accepted = false
    }
    Keys.onDownPressed: function(event) {
      if (!discoveryCard && !matchCard && event.modifiers === Qt.NoModifier) root.moveCardFocus(setupPluginCard, Qt.Key_Down)
      else event.accepted = false
    }
    Accessible.role: Accessible.Button
    Accessible.name: "Inspect " + String(pluginRow.name || pluginRow.id)
    Accessible.onPressAction: root.openSetupDetail(pluginRow, setupPluginCard)

    function relayoutContent() {
      if (cardLayout.item) cardLayout.item.relayout()
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        setupPluginCard.forceActiveFocus()
        root.openSetupDetail(setupPluginCard.pluginRow, setupPluginCard)
      }
    }

    Loader {
      id: cardLayout
      anchors.fill: parent
      anchors.margins: Style.space(setupPluginCard.listRow ? 8 : setupPluginCard.density.padding)
      sourceComponent: setupPluginCard.listRow ? listCardLayout : gridCardLayout
      onLoaded: root.scheduleThumbnailDemand()
    }
    Component {
      id: listCardLayout
    Item {
      id: listContent
      function relayout() {
        listBadges.forceLayout()
        listMetrics.forceLayout()
        listCopy.forceLayout()
        listStatus.forceLayout()
      }
      readonly property bool sideStatus: setupPluginCard.listLayout.sideStatus
        && usableWidth - listCopy.x - statusWidth - Style.space(12) >= listMetrics.minimumRowWidth
      readonly property real usableWidth: Math.max(1, width)
      readonly property real statusWidth: Math.max(Style.space(144), listPrimary.width)
      readonly property var status: Presentation.listStatus(Boolean(root.service && root.service.inventoryReady),
        root.setupRowInstalled(setupPluginCard.pluginRow), root.effectiveEnabled(setupPluginCard.pluginRow),
        setupPluginCard.chosen, setupPluginCard.pluginRow.firstParty === true, Presentation.pluginKinds(setupPluginCard.pluginRow))
      implicitHeight: Math.max(listPreview.visible ? listPreview.height : 0,
        listCopy.implicitHeight + (sideStatus ? 0 : listStatus.implicitHeight + Style.space(4)),
        sideStatus ? listStatus.implicitHeight : 0) + listFooter.height + Style.space(4)

      Rectangle {
        id: listPreview
        visible: setupPluginCard.showThumbnail
        anchors.left: parent.left
        y: Math.max(0, (parent.height - listFooter.height - Style.space(4) - height) / 2)
        width: Style.space(setupPluginCard.listLayout.thumbnailWidth)
        height: width * 9 / 16
        radius: Style.space(5)
        color: root.faint
        clip: true
        Accessible.role: Accessible.Graphic
        Accessible.name: listImage.status === Image.Ready ? "Marketplace preview" : "Preview unavailable"
        Image {
          id: listImage
          anchors.fill: parent
          source: setupPluginCard.imageDemand && visible
            && root.trustedLocalThumbnailUrl(setupPluginCard.localThumbnail) ? setupPluginCard.localThumbnail : ""
          asynchronous: true
          fillMode: Image.PreserveAspectFit
          sourceSize.width: root.imageBucket(width, Screen.devicePixelRatio)
          sourceSize.height: root.imageBucket(height, Screen.devicePixelRatio)
          onStatusChanged: if (status === Image.Error) root.invalidateThumbnail(setupPluginCard.pluginRow.id, source)
        }
        OutfitIcon {
          anchors.centerIn: parent
          visible: listImage.status !== Image.Ready
          width: Style.space(24)
          height: width
          kind: "toolbox"
          tint: root.secondary
          opacity: 0.65
        }
        MouseArea {
          id: listPreviewHover
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.NoButton
        }
        HelpTip {
          target: listPreview
          hoverRequested: listPreviewHover.containsMouse && listImage.status !== Image.Ready
          helpText: setupPluginCard.previewStatus(listImage.status)
        }
        NewListingTag {
          labelSize: setupPluginCard.metadataSize
          visible: root.listingIsNew(setupPluginCard.pluginRow)
        }
      }

      Column {
        id: listCopy
        x: listPreview.visible ? listPreview.width + Style.space(12) : 0
        width: Math.max(1, listContent.usableWidth - x
          - (listContent.sideStatus ? listContent.statusWidth + Style.space(12) : 0))
        spacing: Style.space(2)
        Item {
          width: parent.width
          height: Math.max(listName.implicitHeight, listNew.visible ? listNew.height : 0)
          Text {
            id: listName
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(1, Math.min(implicitWidth, parent.width
              - (listBadges.width ? listBadges.width + Style.space(8) : 0)))
            text: setupPluginCard.pluginRow.name || setupPluginCard.pluginRow.id
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: root.readingSize
            font.bold: true
            elide: Text.ElideRight
          }
          Row {
            id: listBadges
            anchors.left: listName.right
            anchors.leftMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)
            // With thumbnails disabled, keep New as plain text beside the name.
            Text {
              id: listNew
              objectName: "newListingFallback"
              visible: !setupPluginCard.showThumbnail && root.listingIsNew(setupPluginCard.pluginRow)
              text: "New"
              color: Color.accent
              font.family: root.fontFamily
              font.pixelSize: setupPluginCard.metadataSize
            }
          }
        }
        CardCopy {
          objectName: "listCardCopy"
          width: parent.width
          pluginRow: setupPluginCard.pluginRow
          searchActive: setupPluginCard.searchCopyActive
          copySize: setupPluginCard.copySize
          lines: setupPluginCard.browseCard ? 4 : setupPluginCard.listLayout.descriptionLines
        }
        Text {
          visible: setupPluginCard.matchCard
          width: parent.width
          text: (setupPluginCard.matchCard ? root.matchReasons(setupPluginCard.pluginRow) : "") || setupPluginCard.pluginRow.searchReason || setupPluginCard.pluginRow.serviceReason
            || setupPluginCard.pluginRow.reason || "An option to explore from the marketplace."
          textFormat: Text.PlainText
          color: root.secondary
          font.family: root.fontFamily
          font.pixelSize: root.supportingSize
          wrapMode: Text.WordWrap
          maximumLineCount: setupPluginCard.listLayout.reasonLines
          elide: Text.ElideRight
        }
        NaturalMetricGrid {
          id: listMetrics
          width: parent.width
          MetricLabel {
            visible: !setupPluginCard.browseCard
            metric: "recommended"; visualLabel: "Rec"; minimumHeight: Style.space(20)
            value: root.service && root.service.hasAnalyzed ? setupPluginCard.pluginRow.recommendationScore : null
          }
          MetricLabel {
            visible: !setupPluginCard.browseCard
            metric: "fit"; visualLabel: "Fit"; minimumHeight: Style.space(20)
            value: root.service && root.service.hasAnalyzed ? setupPluginCard.pluginRow.score : null
          }
          MetricLabel { browseSmall: setupPluginCard.browseCard; metric: "likes"; value: setupPluginCard.pluginRow.likes }
          MetricLabel { browseSmall: setupPluginCard.browseCard; metric: "stars"; value: setupPluginCard.pluginRow.stars }
          MetricLabel { browseSmall: setupPluginCard.browseCard; metric: "views"; value: setupPluginCard.pluginRow.views }
          MetricLabel { browseSmall: setupPluginCard.browseCard; metric: "copies"; value: setupPluginCard.pluginRow.copies }
        }
        Text {
          visible: root.service && ["added", "activity"].indexOf(root.service.setupSort) >= 0
          width: parent.width
          text: (root.service && root.service.setupSort === "activity" ? "Activity: " : "Listed: ")
            + (String((root.service && root.service.setupSort === "activity"
              ? setupPluginCard.pluginRow.activityAt : setupPluginCard.pluginRow.listedAt) || "").slice(0, 10) || "Not reported")
          textFormat: Text.PlainText
          color: root.secondary
          font.family: root.fontFamily
          font.pixelSize: setupPluginCard.metadataSize
          wrapMode: Text.WordWrap
        }
      }

      Column {
        id: listStatus
        objectName: "listInstallationStatus"
        x: listContent.sideStatus ? listContent.usableWidth - width : listCopy.x
        y: listContent.sideStatus ? 0 : listCopy.implicitHeight + Style.space(4)
        width: listContent.sideStatus ? listContent.statusWidth : listCopy.width
        spacing: Style.space(4)
        StatusBadge {
          id: listPrimary
          objectName: "listInstalledBadge"
          x: listContent.sideStatus ? parent.width - width : 0
          labelSize: setupPluginCard.metadataSize
          visible: Boolean(label)
          label: listContent.status.primary
          compactPadding: setupPluginCard.browseCard && label === "Installed"
          emphasized: setupPluginCard.chosen
        }
        Text {
          objectName: "listEnabledLabel"
          visible: Boolean(text)
          width: listContent.sideStatus ? listStatus.width : Math.min(implicitWidth, listStatus.width)
          text: listContent.status.secondary
          horizontalAlignment: listContent.sideStatus ? Text.AlignRight : Text.AlignLeft
          textFormat: Text.PlainText
          color: root.secondary
          font.family: root.fontFamily
          font.pixelSize: setupPluginCard.metadataSize
          wrapMode: Text.WordWrap
        }
      }
      CardFooter {
        id: listFooter
        width: parent.width
        anchors.bottom: parent.bottom
        pluginRow: setupPluginCard.pluginRow
        labelSize: setupPluginCard.metadataSize
      }
    }
    }

    Component {
      id: gridCardLayout
    Column {
      id: setupCardContent
      function relayout() { forceLayout() }
      spacing: Style.space(setupPluginCard.density.spacing)

      Text {
        visible: setupPluginCard.discoveryCard
        width: parent.width
        height: Math.ceil(headingMetrics.height) * 2 + Style.space(4)
        text: String(setupPluginCard.pluginRow.discoveryHeading || "Something useful to try")
        textFormat: Text.PlainText
        color: Color.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        elide: Text.ElideRight
      }
      Rectangle {
        width: parent.width
        height: setupPluginCard.showThumbnail ? Math.min(Style.space(setupPluginCard.density.previewHeight),
          (setupPluginCard.density.name === "comfortable" ? setupPluginCard.width : width) * 9 / 16) : 0
        visible: setupPluginCard.showThumbnail
        radius: Style.space(5)
        color: root.faint
        clip: true
        Image {
          id: cardThumbnail
          anchors.fill: parent
          source: setupPluginCard.imageDemand && visible
            && root.trustedLocalThumbnailUrl(setupPluginCard.localThumbnail)
            ? setupPluginCard.localThumbnail : ""
          asynchronous: true
          fillMode: Image.PreserveAspectFit
          sourceSize.width: root.imageBucket(width, Screen.devicePixelRatio)
          sourceSize.height: root.imageBucket(height, Screen.devicePixelRatio)
          onStatusChanged: if (status === Image.Error) root.invalidateThumbnail(setupPluginCard.pluginRow.id, source)
        }
        Column {
          anchors.centerIn: parent
          visible: cardThumbnail.status !== Image.Ready
          spacing: Style.space(setupPluginCard.density.name === "comfortable" ? 10 : 6)
          OutfitIcon {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Style.space(setupPluginCard.density.name === "comfortable" ? 42 : 30)
            height: width
            kind: "toolbox"
            tint: root.secondary
            opacity: 0.65
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: setupPluginCard.previewStatus(cardThumbnail.status)
            textFormat: Text.PlainText
            color: root.secondary
            font.family: root.fontFamily
            font.pixelSize: setupPluginCard.metadataSize
          }
        }
        NewListingTag {
          labelSize: setupPluginCard.metadataSize
          visible: root.listingIsNew(setupPluginCard.pluginRow)
        }
      }

      Row {
        width: parent.width
        height: Math.max(cardName.implicitHeight, setupCardInstalled.visible ? setupCardInstalled.height : 0,
          cardQueued.visible ? cardQueued.height : 0)
        spacing: Style.space(7)

        Text {
          id: cardName
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - (setupCardInstalled.visible ? setupCardInstalled.width + parent.spacing : 0)
            - (cardQueued.visible ? cardQueued.width + parent.spacing : 0)
          text: setupPluginCard.pluginRow.name || setupPluginCard.pluginRow.id
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: root.readingSize
          font.bold: true
          elide: Text.ElideRight
        }
        StatusBadge {
          id: setupCardInstalled
          labelSize: setupPluginCard.metadataSize
          anchors.verticalCenter: parent.verticalCenter
          compactPadding: setupPluginCard.browseCard
          visible: root.setupRowInstalled(setupPluginCard.pluginRow)
          label: root.effectiveEnabled(setupPluginCard.pluginRow) ? "Installed" : "Installed · Disabled"
        }
        StatusBadge {
          id: cardQueued
          anchors.verticalCenter: parent.verticalCenter
          labelSize: setupPluginCard.metadataSize
          visible: !setupCardInstalled.visible && setupPluginCard.chosen
          label: "In batch"
          emphasized: true
        }
      }
      Flow {
        width: parent.width
        spacing: Style.space(6)
        // No image means no overlay: retain a small plain New just below the name.
        Text {
          objectName: "newListingFallback"
          visible: !setupPluginCard.showThumbnail && root.listingIsNew(setupPluginCard.pluginRow)
          text: "New"
          color: Color.accent
          font.family: root.fontFamily
          font.pixelSize: setupPluginCard.metadataSize
        }
        StatusBadge { labelSize: setupPluginCard.metadataSize; visible: root.service && !root.service.inventoryReady; label: "Inventory pending" }
      }
      NaturalMetricGrid {
        id: cardMetrics
        visible: !setupPluginCard.discoveryCard
        width: parent.width
        MetricLabel { visible: !setupPluginCard.browseCard; metric: "recommended"; value: root.service && root.service.hasAnalyzed ? setupPluginCard.pluginRow.recommendationScore : null }
        MetricLabel { visible: !setupPluginCard.browseCard; metric: "fit"; value: root.service && root.service.hasAnalyzed ? setupPluginCard.pluginRow.score : null }
        MetricLabel { browseSmall: setupPluginCard.browseCard; metric: "likes"; value: setupPluginCard.pluginRow.likes }
        MetricLabel { browseSmall: setupPluginCard.browseCard; metric: "stars"; value: setupPluginCard.pluginRow.stars }
        MetricLabel { browseSmall: setupPluginCard.browseCard; metric: "views"; value: setupPluginCard.pluginRow.views }
        MetricLabel { browseSmall: setupPluginCard.browseCard; metric: "copies"; value: setupPluginCard.pluginRow.copies }
      }
      Text {
        visible: !setupPluginCard.discoveryCard && root.service
          && ["added", "activity"].indexOf(root.service.setupSort) >= 0
        width: parent.width
        text: (root.service && root.service.setupSort === "activity" ? "Activity: " : "Listed: ")
          + (String((root.service && root.service.setupSort === "activity"
            ? setupPluginCard.pluginRow.activityAt : setupPluginCard.pluginRow.listedAt) || "").slice(0, 10) || "Not reported")
        textFormat: Text.PlainText
        color: root.secondary
        font.family: root.fontFamily
        font.pixelSize: setupPluginCard.metadataSize
      }
      CardCopy {
        objectName: "gridCardCopy"
        width: parent.width
        height: Math.ceil(descriptionMetrics.height) * setupPluginCard.density.descriptionLines + Style.space(4)
        pluginRow: setupPluginCard.pluginRow
        searchActive: setupPluginCard.searchCopyActive
        copySize: setupPluginCard.copySize
        lines: setupPluginCard.density.descriptionLines
      }
      Text {
        visible: setupPluginCard.discoveryCard
        width: parent.width
        height: Math.ceil(captionMetrics.height) * (setupPluginCard.discoveryCard ? 5 : 2) + Style.space(4)
        text: setupPluginCard.pluginRow.searchReason || setupPluginCard.pluginRow.discoveryReason || setupPluginCard.pluginRow.serviceReason
          || setupPluginCard.pluginRow.reason || "An option to explore from the marketplace."
        textFormat: Text.PlainText
        color: root.secondary
        font.family: root.fontFamily
        font.pixelSize: root.supportingSize
        wrapMode: Text.WordWrap
        maximumLineCount: setupPluginCard.discoveryCard ? 5 : 2
        elide: Text.ElideRight
      }
      Text {
        visible: setupPluginCard.discoveryCard && Boolean(setupPluginCard.pluginRow.discoverySetup)
        width: parent.width
        text: "Before you start: " + String(setupPluginCard.pluginRow.discoverySetup || "")
        textFormat: Text.PlainText
        color: root.secondary
        font.family: root.fontFamily
        font.pixelSize: root.readingSize
        wrapMode: Text.WordWrap
      }
      CardFooter {
        width: parent.width
        pluginRow: setupPluginCard.pluginRow
        labelSize: setupPluginCard.metadataSize
        uppercaseKinds: true
        minimumHeight: Style.space(setupPluginCard.density.footerHeight)
      }
    }
    }
  }

  function metricHelp(metric) {
    if (metric === "fit")
      return "Hardware fit: how strongly your detected devices and capabilities match the plugin listing and enabled README text. A heuristic score from 0 to 100, not a compatibility guarantee."
    if (metric === "recommended")
      return "Recommended: combines GitHub popularity and hardware fit. Display grouping does not change this score."
    if (metric === "views")
      return "Views: the cached marketplace view count. These are visits, not unique-user ratings. An em dash means no count was reported. Refresh catalog to update."
    if (metric === "copies")
      return "Copies: the cached marketplace copy count. This does not confirm an installation. An em dash means no count was reported. Refresh catalog to update."
    if (metric === "likes")
      return "Likes: anonymous marketplace hearts, separate from GitHub stars. They are reactions, not unique-user ratings. An em dash means no count was reported; 0 means a reported zero. Refresh catalog to update."
    return "Stars: the repository's GitHub star count reported by the cached marketplace catalog. It measures popularity, not hardware compatibility or review status. An em dash means no count was reported. Refresh catalog to update it."
  }

  // Explicit target parenting keeps popup coordinates independent of a Flow,
  // delegate, or ScrollView's content item. Use the actual wrapped popup size.
  component HelpTip: C.ToolTip {
    id: helpTip
    required property Item target
    property Item focusTarget: target
    property Item verticalTarget: target
    required property string helpText
    property bool hoverRequested: false
    property bool keyboardHelp: false
    property bool clickedHelp: false
    readonly property bool requested: hoverRequested || clickedHelp || (keyboardHelp && focusTarget.activeFocus)
    property bool preferBelow: false
    property bool dismissed: false
    property point origin: Qt.point(0, 0)
    property point verticalOrigin: Qt.point(0, 0)
    readonly property real edge: Style.space(8)
    readonly property real gap: Style.space(6)

    function reposition() {
      origin = target.mapToItem(focusScope, 0, 0)
      verticalOrigin = verticalTarget.mapToItem(focusScope, 0, 0)
    }

    parent: target
    popupType: C.Popup.Item
    focus: false
    closePolicy: C.Popup.NoAutoClose
    visible: requested && !dismissed && target.visible && target.enabled
      && root.opened && !root.confirmationOpen && !maintenanceMenu.visible
      && focusScope.Window.window && focusScope.Window.window.active
      && !helpScrollPause.running
    delay: 350
    padding: Style.space(10)
    margins: edge
    width: Math.max(1, Math.min(Style.space(360), implicitContentWidth + leftPadding + rightPadding,
      focusScope.width - edge * 2))
    x: Math.max(edge, Math.min(origin.x + target.width / 2 - width / 2,
      focusScope.width - edge - width)) - origin.x
    y: {
      var above = verticalOrigin.y - height - gap
      var below = verticalOrigin.y + verticalTarget.height + gap
      var desired = preferBelow ? below : above
      if (preferBelow && below + height > focusScope.height - edge) desired = above
      if (!preferBelow && above < edge) desired = below
      return Math.max(edge, Math.min(desired, focusScope.height - edge - height)) - origin.y
    }
    onRequestedChanged: {
      if (!requested) dismissed = false
      else reposition()
    }
    onHoverRequestedChanged: {
      if (hoverRequested) dismissed = false
      else clickedHelp = false
    }
    onAboutToShow: reposition()
    onVisibleChanged: {
      if (visible) {
        if (root.activeHelpTip && root.activeHelpTip !== helpTip)
          root.activeHelpTip.dismissed = true
        root.activeHelpTip = helpTip
      } else if (root.activeHelpTip === helpTip) root.activeHelpTip = null
    }
    Component.onDestruction: {
      if (root.activeHelpTip === helpTip) root.activeHelpTip = null
    }
    Connections {
      target: root
      function onDismissHelpTips() { helpTip.dismissed = helpTip.requested; helpTip.clickedHelp = false }
      function onPointerHelpInput(scenePosition) {
        helpTip.keyboardHelp = false
        // Check the explicit click against the actual pointer position as well
        // as hover exit (press/touch delivery can precede a hover transition).
        if (helpTip.clickedHelp && scenePosition
            && !helpTip.target.contains(helpTip.target.mapFromItem(null, scenePosition.x, scenePosition.y))) {
          helpTip.dismissed = true
          helpTip.clickedHelp = false
        }
        if (!helpTip.hoverRequested) helpTip.clickedHelp = false
      }
      function onKeyboardHelpInput() {
        if (!helpTip.focusTarget.activeFocus) return
        helpTip.keyboardHelp = true
        helpTip.dismissed = false
      }
    }
    Connections {
      target: helpTip.focusTarget
      function onActiveFocusChanged() {
        if (!helpTip.focusTarget.activeFocus) helpTip.keyboardHelp = false
      }
    }
    contentItem: Text {
      text: helpTip.helpText
      textFormat: Text.PlainText
      wrapMode: Text.Wrap
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: root.readingSize
    }
    background: BorderSurface {
      color: root.background
      radius: Style.cornerRadius
      borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
    }
  }

  component HelpScrollView: ContentScrollView {
    id: helpScroll
    onWidthChanged: root.scheduleThumbnailDemand()
    onHeightChanged: root.scheduleThumbnailDemand()
    Connections {
      target: helpScroll.contentItem
      ignoreUnknownSignals: true
      function onContentXChanged() { root.dismissTooltips(); helpScrollPause.restart(); root.scheduleThumbnailDemand() }
      function onContentYChanged() {
        root.dismissTooltips(); helpScrollPause.restart()
        root.rememberPanel()
        root.scheduleThumbnailDemand()
      }
      function onContentHeightChanged() { root.scheduleThumbnailDemand() }
    }
  }

  Timer {
    id: helpScrollPause
    interval: 180
  }

  component HeaderButton: Button {
    id: headerButton
    required property string iconKind
    required property string accessibleLabel
    width: Math.max(Style.space(38), root.targetSize)
    height: width
    foreground: root.foreground
    focusable: true
    opacity: enabled ? 1 : 0.45
    Accessible.role: Accessible.Button
    Accessible.name: accessibleLabel
    Accessible.onPressAction: clicked()
    Keys.onEscapePressed: function(event) { event.accepted = root.dismissTooltips() }

    OutfitIcon {
      anchors.centerIn: parent
      width: root.iconSize
      height: width
      kind: headerButton.iconKind
      tint: headerButton.selected
        ? Style.selectedStateColor(headerButton.foreground, headerButton.accent) : headerButton.foreground
    }
    HelpTip {
      target: headerButton
      helpText: headerButton.accessibleLabel
      // Native Ui.Button is an Item, not a Control with focusReason. Its
      // mouse/programmatic forceActiveFocus must not request keyboard help.
      hoverRequested: headerButton.hot
      preferBelow: true
    }
  }

  component MaintenanceAction: Button {
    id: maintenanceAction
    required property string label
    required property string description
    required property string iconKind
    foreground: Color.popups.text
    focusable: true
    opacity: enabled ? 1 : 0.5
    implicitHeight: maintenanceCopy.implicitHeight + Style.space(20)
    Accessible.role: Accessible.MenuItem
    Accessible.name: label + ". " + description
    Accessible.onPressAction: if (enabled) clicked()
    Row {
      anchors.fill: parent
      anchors.margins: Style.space(10)
      spacing: Style.space(10)
      OutfitIcon {
        width: Style.space(20)
        height: width
        kind: maintenanceAction.iconKind
        tint: Color.popups.text
      }
      Column {
        id: maintenanceCopy
        width: parent.width - Style.space(30)
        spacing: Style.space(4)
        Text {
          width: parent.width
          text: maintenanceAction.label
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: Color.popups.text
          font.family: root.fontFamily
          font.pixelSize: root.readingSize
          font.bold: true
        }
        Text {
          width: parent.width
          text: maintenanceAction.description
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: Color.popups.text
          opacity: 0.7
          font.family: root.fontFamily
          font.pixelSize: root.readingSize
        }
      }
    }
  }

  component DensityButton: HeaderButton {
    required property string mode
    iconKind: "density-" + mode
    accessibleLabel: "Browse view: " + mode.charAt(0).toUpperCase() + mode.slice(1)
    selected: root.browseDensity === mode
    bordered: true
    Accessible.role: Accessible.RadioButton
    Accessible.checkable: true
    Accessible.checked: selected
    onClicked: root.chooseDensity(mode)
    Keys.onLeftPressed: root.moveDensityFocus(mode, -1)
    Keys.onRightPressed: root.moveDensityFocus(mode, 1)
  }

  component NaturalMetricGrid: Grid {
    readonly property var naturalWidths: {
      var widths = []
      for (var child of children)
        if (child.metric !== undefined && child.visible) widths.push(child.implicitWidth)
      return widths
    }
    readonly property real minimumRowWidth: naturalWidths.reduce(function(sum, value) { return sum + value }, 0)
      + Style.space(2) * Math.max(0, naturalWidths.length - 1)
    readonly property var layout: Presentation.naturalMetricLayout(width, naturalWidths, Style.space(8), Style.space(2))
    columns: layout.columns
    columnSpacing: layout.gap
    rowSpacing: Style.space(4)
  }

  component MetricLabel: Item {
    id: metricLabel
    required property string metric
    property var value: 0
    property bool tile: false
    property bool browseSmall: false
    readonly property real textSize: browseSmall ? root.browseReadingSize : root.readingSize
    readonly property real metricIconSize: browseSmall ? root.browseIconSize : root.iconSize
    readonly property string label: metric.toUpperCase()
    property string visualLabel: browseSmall ? (metric === "views" ? "Views" : metric === "copies" ? "Copies" : label) : label
    property real minimumHeight: Style.space(20)
    readonly property string number: value === null || value === undefined ? "—" : String(Number(value) || 0)
    readonly property bool iconMetric: ["stars", "likes", "views", "copies"].indexOf(metric) >= 0
    readonly property bool helpVisible: metricHelp.requested
    implicitWidth: browseSmall ? compactNumber.implicitWidth + metricIconSize + Style.space(4)
      : (tile ? tileContent.implicitWidth : compactContent.implicitWidth) + metricIconSize + Style.space(4)
    // Center the column's widest group, then align every row to that same
    // inset. Short counts must not shift each row's left edge independently.
    readonly property real columnInset: {
      if (browseSmall) return 0
      var siblings = []
      if (parent) for (var child of parent.children)
        if (child.metric !== undefined && child.visible) siblings.push(child)
      var columns = parent ? Math.max(1, Number(parent.columns) || 1) : 1
      var index = siblings.indexOf(metricLabel)
      var widest = implicitWidth
      for (var i = 0; i < siblings.length; i++)
        if (index >= 0 && i % columns === index % columns)
          widest = Math.max(widest, siblings[i].implicitWidth)
      return Math.max(0, (width - widest) / 2)
    }
    implicitHeight: tile ? Math.max(Style.space(58), tileContent.implicitHeight) : Math.max(minimumHeight, metricIconSize, compactContent.implicitHeight)
    width: browseSmall && parent ? Math.min(implicitWidth, parent.width) : implicitWidth
    height: implicitHeight
    activeFocusOnTab: true
    // Static information targets do not take mouse focus. Keep explicit focus
    // accessible, but relinquish its help as soon as the pointer is used.
    onActiveFocusChanged: metricHelp.keyboardHelp = activeFocus
    Accessible.role: browseSmall ? Accessible.Button : Accessible.StaticText
    Accessible.name: label + " " + (value === null || value === undefined ? "not reported" : number)
      + ". " + root.metricHelp(metric)
    Accessible.onPressAction: revealHelp(false)
    function revealHelp(pointer) {
      if (pointer) {
        root.notePointerHelpInput()
        metricHelp.clickedHelp = true
      } else {
        forceActiveFocus()
        metricHelp.keyboardHelp = true
      }
      metricHelp.dismissed = false
      metricHelp.reposition()
    }
    Keys.onReturnPressed: function(event) { if (browseSmall) revealHelp(false); else event.accepted = false }
    Keys.onEnterPressed: function(event) { if (browseSmall) revealHelp(false); else event.accepted = false }
    Keys.onSpacePressed: function(event) { if (browseSmall) revealHelp(false); else event.accepted = false }
    Keys.onEscapePressed: function(event) { event.accepted = root.dismissTooltips() }

    Row {
      id: compactContent
      objectName: "metricContent"
      visible: !metricLabel.tile
      x: metricLabel.columnInset
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)
      OutfitIcon {
        visible: metricLabel.iconMetric
        anchors.verticalCenter: parent.verticalCenter
        width: metricLabel.metricIconSize
        height: width
        kind: metricLabel.metric
        tint: Color.accent
      }
      Text {
        objectName: "metricCaption"
        visible: metricLabel.browseSmall && !metricLabel.iconMetric
        text: metricLabel.visualLabel
        color: root.secondary
        font.family: root.fontFamily
        font.pixelSize: metricLabel.textSize
      }
      Text {
        id: compactNumber
        objectName: "metricNumber"
        width: metricLabel.browseSmall ? Math.max(1, metricLabel.width - metricLabel.metricIconSize - Style.space(4)) : implicitWidth
        wrapMode: metricLabel.browseSmall ? Text.WrapAnywhere : Text.NoWrap
        text: (metricLabel.browseSmall || metricLabel.iconMetric ? "" : metricLabel.visualLabel + " ") + metricLabel.number
        textFormat: Text.PlainText
        color: Color.accent
        font.family: root.fontFamily
        font.pixelSize: metricLabel.textSize
        font.bold: true
      }
    }
    Column {
      id: tileContent
      objectName: "metricTileContent"
      visible: metricLabel.tile
      x: (metricLabel.width - implicitWidth - metricLabel.metricIconSize - Style.space(4)) / 2
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(5)
        OutfitIcon {
          visible: metricLabel.iconMetric
          anchors.verticalCenter: parent.verticalCenter
          width: root.iconSize
          height: width
          kind: metricLabel.metric
          tint: Color.accent
        }
        Text {
          text: metricLabel.number
          textFormat: Text.PlainText
          color: Color.accent
          font.family: root.fontFamily
          font.pixelSize: root.valueSize
          font.bold: true
        }
      }
      Text {
        text: metricLabel.label
        textFormat: Text.PlainText
        color: root.secondary
        font.family: root.fontFamily
        font.pixelSize: root.supportingSize
      }
    }
    Item {
      id: metricInfoTarget
      objectName: "metricInfoTarget"
      visible: !metricLabel.browseSmall
      x: (metricLabel.tile ? tileContent.x + tileContent.width : compactContent.x + compactContent.width) + Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      width: metricLabel.metricIconSize
      height: metricLabel.metricIconSize
      OutfitIcon {
        objectName: "metricInfoIcon"
        anchors.centerIn: parent
        width: metricLabel.metricIconSize
        height: width
        kind: "info"
        tint: Color.accent
      }
    }
    MouseArea {
      id: metricHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: metricLabel.browseSmall ? Qt.LeftButton : Qt.NoButton
      cursorShape: metricLabel.browseSmall ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: metricLabel.revealHelp(true)
    }
    HelpTip {
      id: metricHelp
      target: metricLabel.browseSmall ? metricLabel : metricInfoTarget
      focusTarget: metricLabel
      verticalTarget: metricLabel
      hoverRequested: metricHover.containsMouse
      helpText: root.metricHelp(metricLabel.metric)
    }
  }

  component ReadmeMediaPreview: Item {
    id: mediaPreview
    objectName: "readmeMediaPreview"

    required property var pluginRow
    property real maximumStageHeight: Style.space(220)
    readonly property var mediaItems: {
      var items = root.readmeMediaFor(pluginRow)
      var thumbnail = root.detailThumbnail(pluginRow)
      return items.length ? items : thumbnail ? [{kind:"image", localSource:thumbnail, label:"Marketplace preview", url:""}] : []
    }
    readonly property bool loading: root.readmeMediaLoading(pluginRow)
    readonly property var selectedMedia: selectedIndex >= 0 && selectedIndex < mediaItems.length
      ? mediaItems[selectedIndex] : ({})
    readonly property string selectedKind: String(selectedMedia.kind || "")
    readonly property string selectedLocalSource: String(selectedMedia.localSource || "")
    readonly property string displayError: selectedKind === "video" ? videoError : imageError
    readonly property string mediaIdentity: String(pluginRow.id || "") + "|"
      + JSON.stringify(mediaItems)
    property int selectedIndex: 0
    property bool videoRequested: false
    property string imageError: ""
    property string videoError: ""
    property bool componentReady: false

    visible: loading || mediaItems.length > 0
    implicitHeight: visible ? previewColumn.implicitHeight : 0
    height: implicitHeight

    function stopMedia() {
      if (componentReady) previewVideo.stop()
      videoRequested = false
      fullPreview.close()
    }

    function resetMedia() {
      stopMedia()
      selectedIndex = 0
      imageError = ""
      videoError = ""
    }

    function selectMedia(index) {
      stopMedia()
      selectedIndex = Math.max(0, Math.min(Number(index) || 0, mediaItems.length - 1))
      imageError = ""
      videoError = ""
    }

    Component.onCompleted: {
      componentReady = true
      resetMedia()
    }
    onMediaIdentityChanged: if (componentReady) resetMedia()

    Column {
      id: previewColumn
      width: parent.width
      spacing: Style.space(7)

      Text {
        visible: mediaPreview.mediaItems.length > 0
        width: parent.width
        text: "PREVIEW"
        textFormat: Text.PlainText
        color: root.secondary
        font.family: root.fontFamily
        font.pixelSize: root.supportingSize
        font.bold: true
        font.letterSpacing: 1.1
      }

      BorderSurface {
        visible: mediaPreview.loading && mediaPreview.mediaItems.length === 0
        width: parent.width
        height: visible ? Style.space(76) : 0
        radius: Style.cornerRadius
        color: root.faint

        Text {
          anchors.centerIn: parent
          text: "Looking for a useful screenshot or demo..."
          textFormat: Text.PlainText
          color: root.secondary
          font.family: root.fontFamily
          font.pixelSize: root.supportingSize
        }
      }

      BorderSurface {
        id: mediaStage
        visible: mediaPreview.mediaItems.length > 0
        width: parent.width
        height: visible ? Math.min(mediaPreview.maximumStageHeight, width * 9 / 16) : 0
        radius: Style.cornerRadius
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.035)
        borderSpec: previewImage.activeFocus ? Border.controlSpec("focus", root.foreground, Color.accent) : Border.none()
        clip: true

        Image {
          id: previewImage
          visible: Boolean(mediaPreview.selectedLocalSource)
            && !mediaPreview.videoRequested
          anchors.fill: parent
          anchors.margins: Style.space(5)
          source: root.uiAwake && visible && (root.trustedLocalPreviewUrl(mediaPreview.selectedLocalSource) || root.trustedLocalThumbnailUrl(mediaPreview.selectedLocalSource))
            ? mediaPreview.selectedLocalSource : ""
          asynchronous: true
          cache: true
          fillMode: Image.PreserveAspectFit
          autoTransform: true
          sourceSize.width: root.imageBucket(width, Screen.devicePixelRatio)
          sourceSize.height: root.imageBucket(height, Screen.devicePixelRatio)
          readonly property bool expandable: mediaPreview.selectedKind === "image" && status === Image.Ready
          activeFocusOnTab: expandable || activeFocus
          Accessible.role: Accessible.Button
          Accessible.name: "Expand preview image"
          Accessible.onPressAction: if (expandable) fullPreview.open()
          Keys.onReturnPressed: if (expandable) fullPreview.open()
          Keys.onEnterPressed: if (expandable) fullPreview.open()
          Keys.onSpacePressed: if (expandable) fullPreview.open()

          onStatusChanged: {
            if (mediaPreview.selectedKind !== "image") return
            if (status === Image.Error) {
              mediaPreview.imageError = "This preview could not be displayed here."
              root.invalidateThumbnail(mediaPreview.pluginRow.id, source)
            }
            else if (status === Image.Ready) mediaPreview.imageError = ""
          }

          MouseArea {
            visible: mediaPreview.selectedKind === "image" && parent.status === Image.Ready
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: { previewImage.forceActiveFocus(); fullPreview.open() }
          }
        }

        OptionalVideo {
          id: previewVideo
          visible: mediaPreview.selectedKind === "video" && mediaPreview.videoRequested
          anchors.fill: parent
          anchors.margins: Style.space(5)
          requested: root.uiAwake && visible && mediaPreview.videoRequested && root.trustedPreviewUrl(mediaPreview.selectedMedia.url)
          mediaSource: requested && root.trustedPreviewUrl(mediaPreview.selectedMedia.url)
            ? String(mediaPreview.selectedMedia.url) : ""

          onPlaybackFailed: function(message) {
            mediaPreview.videoError = message
            mediaPreview.videoRequested = false
          }
        }

        Text {
          visible: (mediaPreview.selectedKind === "video"
            || mediaPreview.selectedKind === "external-video"
            || (mediaPreview.selectedKind === "image"
              && !mediaPreview.selectedLocalSource))
            && !mediaPreview.videoRequested && !previewImage.visible
          anchors.centerIn: parent
          anchors.verticalCenterOffset: -Style.space(26)
          text: mediaPreview.selectedKind === "image" ? "IMAGE PREVIEW" : "VIDEO DEMO"
          textFormat: Text.PlainText
          color: root.secondary
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
          font.letterSpacing: 1.1
        }

        Button {
          visible: mediaPreview.selectedKind === "external-video"
            || (mediaPreview.selectedKind === "video" && !mediaPreview.videoRequested
              && !mediaPreview.videoError)
            || (mediaPreview.selectedKind === "image" && !mediaPreview.selectedLocalSource)
          anchors.centerIn: parent
          text: mediaPreview.selectedKind === "external-video" ? "Watch demo"
            : (mediaPreview.selectedKind === "image" ? "Open preview" : "Play demo")
          foreground: root.foreground
          bordered: true
          focusable: true
          onClicked: {
            if (mediaPreview.selectedKind === "external-video"
                || mediaPreview.selectedKind === "image")
              root.openReadmeMedia(mediaPreview.selectedMedia)
            else {
              mediaPreview.videoError = ""
              mediaPreview.videoRequested = true
            }
          }
        }

        Row {
          visible: mediaPreview.selectedKind === "video" && mediaPreview.videoRequested
            && !mediaPreview.videoError
          anchors.right: parent.right
          anchors.rightMargin: Style.space(8)
          anchors.bottom: parent.bottom
          anchors.bottomMargin: Style.space(8)
          spacing: Style.space(6)

          Button {
            text: previewVideo.playing ? "Pause" : "Play"
            foreground: root.foreground
            bordered: true
            focusable: true
            onClicked: previewVideo.togglePlayback()
          }
          Button {
            text: previewVideo.muted ? "Muted" : "Sound on"
            foreground: root.foreground
            bordered: true
            focusable: true
            onClicked: previewVideo.toggleMuted()
          }
          Button {
            text: "Open"
            foreground: root.foreground
            bordered: true
            focusable: true
            onClicked: root.openReadmeMedia(mediaPreview.selectedMedia)
          }
        }

        Column {
          visible: Boolean(mediaPreview.displayError)
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.margins: Style.space(8)
          spacing: Style.space(5)

          Text {
            width: parent.width
            text: mediaPreview.displayError
            textFormat: Text.PlainText
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: root.supportingSize
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }
          Button {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Open externally"
            foreground: root.foreground
            bordered: true
            focusable: true
            onClicked: root.openReadmeMedia(mediaPreview.selectedMedia)
          }
        }
      }

      Text {
        visible: mediaPreview.mediaItems.length > 0
          && Boolean(mediaPreview.selectedMedia.label)
        width: parent.width
        text: String(mediaPreview.selectedMedia.label || "")
        textFormat: Text.PlainText
        color: root.secondary
        font.family: root.fontFamily
        font.pixelSize: root.supportingSize
        wrapMode: Text.WordWrap
      }

      HelpScrollView {
        visible: mediaPreview.mediaItems.length > 1
        contentWidth: mediaThumbnailRow.implicitWidth
        width: parent.width
        height: visible ? Style.space(58) : 0
        clip: true
        C.ScrollBar.vertical.policy: C.ScrollBar.AlwaysOff
        C.ScrollBar.horizontal.policy: C.ScrollBar.AsNeeded

        Row {
          id: mediaThumbnailRow
          height: Style.space(48)
          spacing: Style.space(6)

          Repeater {
            model: mediaPreview.mediaItems

            BorderSurface {
              required property var modelData
              required property int index
              width: Style.space(78)
              height: Style.space(46)
              radius: Style.space(5)
              color: index === mediaPreview.selectedIndex
                ? Style.selectedFillFor(root.foreground, Color.accent) : root.faint
              borderSpec: index === mediaPreview.selectedIndex
                ? Border.controlSpec("selected", root.foreground, Color.accent) : Border.none()
              clip: true
              activeFocusOnTab: true
              Accessible.role: Accessible.Button
              Accessible.name: String(modelData.label || "Preview " + (index + 1))
              Accessible.onPressAction: mediaPreview.selectMedia(index)

              Keys.onEnterPressed: mediaPreview.selectMedia(index)
              Keys.onReturnPressed: mediaPreview.selectMedia(index)

              Image {
                visible: Boolean(modelData.localSource)
                anchors.fill: parent
                anchors.margins: Style.space(3)
                source: root.uiAwake && visible && root.trustedLocalPreviewUrl(modelData.localSource)
                  ? String(modelData.localSource) : ""
                asynchronous: true
                cache: true
                fillMode: Image.PreserveAspectCrop
                sourceSize.width: 180
                sourceSize.height: 110
              }
              Text {
                visible: !modelData.localSource
                anchors.centerIn: parent
                text: modelData.kind === "external-video" ? "LINK"
                  : (modelData.kind === "image" ? "IMAGE" : "VIDEO")
                textFormat: Text.PlainText
                color: root.secondary
                font.family: root.fontFamily
                font.pixelSize: root.supportingSize
                font.bold: true
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  parent.forceActiveFocus()
                  mediaPreview.selectMedia(index)
                }
              }
            }
          }
        }
      }
    }
    C.Popup {
      id: fullPreview
      parent: focusScope
      popupType: C.Popup.Item
      x: Style.space(16); y: Style.space(16)
      width: focusScope.width - Style.space(32)
      height: focusScope.height - Style.space(32)
      padding: Style.space(16)
      modal: true; focus: true
      closePolicy: C.Popup.CloseOnEscape | C.Popup.CloseOnPressOutside
      onOpened: fullPreviewClose.forceActiveFocus()
      onClosed: if (root.opened && mediaPreview.visible && previewImage.expandable) previewImage.forceActiveFocus()
      background: BorderSurface { color: root.background; radius: Style.cornerRadius }
      contentItem: Item {
        Button {
          id: fullPreviewClose
          text: "Close preview"; bordered:true; focusable:true
          anchors.right: parent.right
          onClicked: fullPreview.close()
        }
        Image {
          objectName: "nativeFullSizeImage"
          anchors.top: fullPreviewClose.bottom
          anchors.topMargin: Style.space(12)
          anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
          source: root.uiAwake && mediaPreview.visible && fullPreview.visible && (root.trustedLocalPreviewUrl(mediaPreview.selectedLocalSource)
            || root.trustedLocalThumbnailUrl(mediaPreview.selectedLocalSource)) ? mediaPreview.selectedLocalSource : ""
          fillMode: Image.PreserveAspectFit
          asynchronous: true
          sourceSize.width: root.imageBucket(width, Screen.devicePixelRatio)
          sourceSize.height: root.imageBucket(height, Screen.devicePixelRatio)
          onStatusChanged: if (status === Image.Error) root.invalidateThumbnail(mediaPreview.pluginRow.id, source)
        }
      }
    }
  }

  component SetupDetailPanel: Item {
    id: liveInspector
    required property var pluginRow
    readonly property var row: pluginRow || ({})
    function stopMedia() { detailPage.stopMedia() }
    function takeFocus() { detailPage.takeFocus() }
    function scrollPosition() { return detailPage.scrollPosition() }
    function focusName() { return detailPage.focusName() }
    function restorePosition(y, focus) {
      if (root.interestsOpen || root.settingsOpen) return
      detailPage.restorePosition(y, focus)
    }
    PluginDetailPage {
      id: detailPage
      anchors.fill: parent
      active: root.uiAwake && visible
      service: root.service
      pluginRow: root.detailMetadata(liveInspector.row)
      presentation: root.detailPresentation(liveInspector.row)
      installEnabled: root.draftInstallEnabled
      installSection: root.draftInstallSection
      backLabel: root.setupStage === "updates" ? "Back to Updates"
        : root.workspaceView === "discover" ? (root.discoverTab === "matches" ? "Back to Matches" : "Back to Discover") : "Back to Browse"
      mediaAvailable: root.readmeMediaFor(liveInspector.row).length > 0
        || root.readmeMediaLoading(liveInspector.row) || Boolean(root.detailThumbnail(liveInspector.row))
      mediaComponent: Component {
        ReadmeMediaPreview {
          pluginRow: liveInspector.row
          maximumStageHeight: detailPage.previewMaximumHeight
        }
      }
      onBackRequested: root.closeSetupDetail()
      onPrimaryRequested: root.inspectorPrimary(liveInspector.row)
      onEnabledRequested: root.togglePlugin(liveInspector.row)
      onInstallEnabledRequested: root.draftInstallEnabled = !root.draftInstallEnabled
      onSectionRequested: function(section) {
        if (presentation.installed) root.chooseBarSection(liveInspector.row, section)
        else { root.draftInstallSection = section; root.rememberBarSection(liveInspector.row, section) }
      }
      onQueueRequested: root.toggleSetupSelection(liveInspector.row)
      onRemoveRequested: root.requestAction("remove", liveInspector.row)
      onUpdateRequested: root.requestUpdate(liveInspector.row)
      onUpdateCheckRequested: root.checkUpdates()
      onSourceRequested: if (root.service) root.service.openSource(liveInspector.row)
      onMarketplaceRequested: if (root.service) root.service.openMarketplace(liveInspector.row)
      onDocumentationRequested: if (root.service) root.service.loadReadme(liveInspector.row)
      onReviewRequested: if (root.service) root.service.reviewMatches([String(liveInspector.row.id)], false)
    }
  }

  // Source-level fallback retained for the first live rollout. Only the full
  // SetupDetailPanel above is instantiated; the pre-rollout archive is separate.
  component LegacySetupDetailPanel: BorderSurface {
    id: setupInspector
    required property var pluginRow
    readonly property var row: pluginRow || ({})
    readonly property bool chosen: root.service && root.service.setupSelected(row.id)
    readonly property var presentation: root.inspectorState(row)
    property bool matchingExpanded: false
    onPluginRowChanged: matchingExpanded = false
    onPresentationChanged: if (pluginActionsMenu && !presentation.canRemove) pluginActionsMenu.close()

    function stopMedia() {
      setupMediaPreview.stopMedia()
    }

    function takeFocus() {
      if (visible) setupInspectorClose.forceActiveFocus()
    }
    function scrollPosition() { return Number(setupInspectorScroll.contentItem.contentY || 0) }
    function focusName() {
      return setupInspectorPrimary.activeFocus ? "primary" : inspectorMenuButton.activeFocus ? "actions" : "close"
    }
    function restorePosition(y, focus) {
      setupInspectorScroll.contentItem.contentY = Math.max(0, Math.min(Number(y) || 0,
        setupInspectorScroll.contentItem.contentHeight - setupInspectorScroll.height))
      if (!visible || root.interestsOpen || root.settingsOpen) return
      if (focus === "primary" && setupInspectorPrimary.visible && setupInspectorPrimary.enabled) setupInspectorPrimary.forceActiveFocus()
      else if (focus === "actions" && inspectorMenuButton.visible) inspectorMenuButton.forceActiveFocus()
      else setupInspectorClose.forceActiveFocus()
    }

    radius: Style.cornerRadius
    color: root.background
    borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.AllButtons
      onWheel: function(wheel) { wheel.accepted = true }
    }

    Item {
      id: setupInspectorHeader
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.margins: Style.space(16)
      height: Math.max(setupInspectorTitle.implicitHeight, setupInspectorClose.implicitHeight)

      Text {
        id: setupInspectorTitle
        anchors.left: parent.left
        anchors.right: inspectorHeaderActions.left
        anchors.rightMargin: Style.space(8)
        text: setupInspector.row.name || setupInspector.row.id || "Plugin details"
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        wrapMode: Text.WordWrap
      }
      Row {
        id: inspectorHeaderActions
        anchors.top: parent.top
        anchors.right: parent.right
        spacing: Style.space(6)
        HeaderButton {
          id: inspectorMenuButton
          visible: setupInspector.presentation.installed && !setupInspector.presentation.included
            && String(setupInspector.row.id || "") !== root.pluginId
          enabled: setupInspector.presentation.canRemove
          iconKind: "more"
          accessibleLabel: "Plugin actions"
          onClicked: pluginActionsMenu.visible ? pluginActionsMenu.close() : pluginActionsMenu.open()
          Keys.onDownPressed: pluginActionsMenu.open()
        }
        Button {
          id: setupInspectorClose
          text: "Close"
          foreground: root.foreground
          bordered: true
          focusable: true
          onClicked: root.closeSetupDetail()
        }
      }
      C.Popup {
        id: pluginActionsMenu
        parent: inspectorMenuButton
        popupType: C.Popup.Item
        width: Math.min(Style.space(250), setupInspector.width - Style.space(24))
        x: parent.width - width
        y: parent.height + Style.space(6)
        padding: Style.space(8)
        margins: Style.space(8)
        focus: true
        closePolicy: C.Popup.CloseOnEscape | C.Popup.CloseOnPressOutside
        onAboutToShow: root.dismissTooltips()
        onOpened: uninstallAction.forceActiveFocus()
        background: BorderSurface {
          color: Color.popups.background
          radius: Style.cornerRadius
          borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
        }
        contentItem: Button {
          id: uninstallAction
          text: "Uninstall plugin…"
          foreground: Color.urgent
          focusable: true
          enabled: setupInspector.presentation.canRemove
          Accessible.role: Accessible.MenuItem
          Accessible.name: text
          Accessible.onPressAction: if (enabled) clicked()
          Keys.onEscapePressed: { pluginActionsMenu.close(); inspectorMenuButton.forceActiveFocus() }
          Keys.onTabPressed: { pluginActionsMenu.close(); setupInspectorClose.forceActiveFocus() }
          Keys.onBacktabPressed: { pluginActionsMenu.close(); inspectorMenuButton.forceActiveFocus() }
          onClicked: {
            pluginActionsMenu.close()
            root.requestAction("remove", setupInspector.row)
          }
        }
      }
    }

    HelpScrollView {
      id: setupInspectorScroll
      anchors.top: setupInspectorHeader.bottom
      anchors.topMargin: Style.space(12)
      anchors.left: parent.left
      anchors.leftMargin: Style.space(16)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(16)
      anchors.bottom: setupInspectorAction.visible ? setupInspectorAction.top : parent.bottom
      anchors.bottomMargin: Style.space(10)
      clip: true
      contentWidth: availableWidth
      C.ScrollBar.horizontal.policy: C.ScrollBar.AlwaysOff

      Column {
        id: setupInspectorContent
        width: setupInspectorScroll.availableWidth
        spacing: Style.space(11)

        Flow {
          width: parent.width
          spacing: Style.space(6)
          visible: root.listingIsNew(setupInspector.row) || setupInspector.row.verification === "verified"
          StatusBadge { visible: root.listingIsNew(setupInspector.row); label: "New" }
          StatusBadge { visible: setupInspector.row.verification === "verified"; label: "Verified" }
        }

        Text {
          width: parent.width
          text: root.service ? root.service.pluginOutcome(setupInspector.row.id) : "Inventory pending"
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: setupInspector.presentation.failed ? Color.urgent : Color.accent
          font.family: root.fontFamily
          font.pixelSize: root.readingSize
          font.bold: true
        }

        Text {
          width: parent.width
          text: setupInspector.row.description || "No description supplied."
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: root.readingSize
          wrapMode: Text.WordWrap
        }
        Text {
          width: parent.width
          text: "WHY THIS IS SHOWN"
          textFormat: Text.PlainText
          color: root.secondary
          font.family: root.fontFamily
          font.pixelSize: root.supportingSize
          font.bold: true
        }
        Text {
          width: parent.width
          text: root.matchReasons(setupInspector.row) || (setupInspector.row.discoveryHeading ? String(setupInspector.row.discoveryHeading) + "\n" : "")
            + (setupInspector.row.searchReason || setupInspector.row.discoveryReason || setupInspector.row.serviceReason
              || setupInspector.row.reason || "An option to explore from the marketplace.")
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: root.readingSize
          wrapMode: Text.WordWrap
        }
        Flow {
          visible: root.discoveryEnabled && Array.isArray(setupInspector.row.matchedInterests)
          width: parent.width
          spacing: Style.space(7)
          StatusBadge { label: root.matchCause(setupInspector.row) }
          Button {
            text: root.service && root.service.matchUnread(setupInspector.row) ? "Mark reviewed" : "Reviewed"
            foreground: root.foreground
            bordered: true; focusable: true
            enabled: root.service && root.service.matchUnread(setupInspector.row) && !root.service.matchesBusy
            onClicked: root.service.reviewMatches([String(setupInspector.row.id)], false)
          }
        }
        ReadmeMediaPreview {
          id: setupMediaPreview
          width: parent.width
          pluginRow: setupInspector.row
        }
        Text {
          visible: Boolean(setupInspector.row.discoverySetup || setupInspector.row.editorialSetup)
          width: parent.width
          text: "Before you start: " + String(setupInspector.row.discoverySetup || setupInspector.row.editorialSetup || "")
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: root.readingSize
        }
        Text {
          visible: Boolean(root.setupTagsText(setupInspector.row))
          width: parent.width
          text: root.setupTagsText(setupInspector.row)
          textFormat: Text.PlainText
          color: root.secondary
          font.family: root.fontFamily
          font.pixelSize: root.supportingSize
          wrapMode: Text.WordWrap
        }

        Button {
          text: setupInspector.matchingExpanded ? "Hide metrics and matching details" : "Metrics and matching details"
          foreground: root.secondary
          focusable: true
          onClicked: {
            root.dismissTooltips()
            setupInspector.matchingExpanded = !setupInspector.matchingExpanded
          }
        }
        Column {
          visible: setupInspector.matchingExpanded
          width: parent.width
          spacing: Style.space(11)
        Grid {
          id: setupInspectorMetrics
          width: parent.width
          columns: 2
          spacing: Style.space(7)

          Repeater {
            model: [
              { label: "RECOMMENDED", value: root.service && root.service.hasAnalyzed ? Number(setupInspector.row.recommendationScore || 0) : null },
              { label: "FIT", value: root.service && root.service.hasAnalyzed ? Number(setupInspector.row.score || 0) : null },
              { label: "STARS", value: setupInspector.row.stars },
              { label: "LIKES", value: setupInspector.row.likes },
              { label: "VIEWS", value: setupInspector.row.views },
              { label: "COPIES", value: setupInspector.row.copies }
            ]

            BorderSurface {
              required property var modelData
              width: (setupInspectorMetrics.width - setupInspectorMetrics.spacing) / 2
              height: Style.space(58)
              radius: Style.cornerRadius
              color: root.faint

              MetricLabel {
                anchors.fill: parent
                metric: String(modelData.label).toLowerCase()
                value: modelData.value
                tile: true
              }
            }
          }
        }

        PanelSeparator { width: parent.width; foreground: root.foreground }
        Text {
          width: parent.width
          text: "MATCHING DETAILS"
          textFormat: Text.PlainText
          color: root.secondary
          font.family: root.fontFamily
          font.pixelSize: root.supportingSize
          font.bold: true
          font.letterSpacing: 1.1
        }
        Text {
          width: parent.width
          text: setupInspector.row.serviceReason || setupInspector.row.reason
            || "No hardware-specific match; ranked by marketplace popularity."
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: root.readingSize
          wrapMode: Text.WordWrap
        }
        Repeater {
          model: root.evidenceRowsFor(setupInspector.row, "hardware")

          BorderSurface {
            required property var modelData
            width: setupInspectorContent.width
            height: setupInspectorEvidence.implicitHeight + Style.space(12)
            radius: Style.space(6)
            color: root.faint

            Text {
              id: setupInspectorEvidence
              anchors.fill: parent
              anchors.margins: Style.space(6)
              text: root.evidenceText(modelData)
              textFormat: Text.PlainText
              color: root.secondary
              font.family: root.fontFamily
              font.pixelSize: root.supportingSize
              wrapMode: Text.WordWrap
            }
          }
        }
        }

        PanelSeparator { width: parent.width; foreground: root.foreground }
        Text {
          width: parent.width
          text: "SOURCE & REVIEW"
          textFormat: Text.PlainText
          color: root.secondary
          font.family: root.fontFamily
          font.pixelSize: root.supportingSize
          font.bold: true
          font.letterSpacing: 1.1
        }
        Text {
          width: parent.width
          text: root.sourceReviewText(setupInspector.row)
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: root.readingSize
          wrapMode: Text.WordWrap
        }
        Text {
          visible: Boolean(setupInspector.row.author || setupInspector.row.version)
          width: parent.width
          text: (setupInspector.row.author ? "By " + setupInspector.row.author : "")
            + (setupInspector.row.author && setupInspector.row.version ? "  /  " : "")
            + (setupInspector.row.version ? "Version " + setupInspector.row.version : "")
          textFormat: Text.PlainText
          color: root.secondary
          font.family: root.fontFamily
          font.pixelSize: root.readingSize
          wrapMode: Text.WordWrap
        }
        Flow {
          width: parent.width
          spacing: Style.space(7)
          Button {
            visible: Boolean(InspectorState.projectUrl({repo: setupInspector.row.snapshotUrl || setupInspector.row.repo}))
            text: "Review source"
            foreground: root.foreground
            focusable: true
            onClicked: root.service.openSource(setupInspector.row)
          }
          Button {
            visible: Boolean(InspectorState.projectUrl({marketplaceUrl: setupInspector.row.marketplaceUrl}))
            text: "Marketplace listing"
            foreground: root.foreground
            focusable: true
            onClicked: root.service.openMarketplace(setupInspector.row)
          }
        }

        Column {
          visible: setupInspector.presentation.installed
          width: parent.width
          spacing: Style.space(10)
          PanelSeparator { width: parent.width; foreground: root.foreground }
          Text {
            text: "ON THIS COMPUTER"
            textFormat: Text.PlainText
            color: root.secondary
            font.family: root.fontFamily
            font.pixelSize: root.supportingSize
            font.bold: true
          }
          StatusBadge { label: "Installed" }
          Toggle {
            width: parent.width
            label: "Enabled in Omarchy"
            description: !setupInspector.presentation.known ? "Last confirmed state; inventory is unavailable."
              : setupInspector.presentation.pending ? "Showing the confirmed state while the operation finishes."
              : !setupInspector.presentation.canToggle ? "This plugin cannot be toggled here." : ""
            checked: setupInspector.presentation.enabled
            enabled: setupInspector.presentation.canToggle
            foreground: root.foreground
            accent: Color.accent
            Accessible.role: Accessible.CheckBox
            Accessible.checkable: true
            Accessible.name: label
            Accessible.checked: checked
            Accessible.onToggleAction: if (enabled) root.togglePlugin(setupInspector.row)
            onClicked: root.togglePlugin(setupInspector.row)
          }
          Text {
            visible: setupInspector.presentation.widget
            width: parent.width
            text: setupInspector.presentation.enabled
              ? (setupInspector.presentation.actualSection ? "Bar location" : "Bar location is not confirmed.")
              : "Location when enabled (changing this does not enable the widget)"
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.secondary
            font.family: root.fontFamily
            font.pixelSize: root.supportingSize
          }
          Flow {
            visible: setupInspector.presentation.widget
            width: parent.width
            spacing: Style.space(6)
            BarSectionButton { pluginRow: setupInspector.row; section: "left" }
            BarSectionButton { pluginRow: setupInspector.row; section: "center" }
            BarSectionButton { pluginRow: setupInspector.row; section: "right" }
          }
        }

        Column {
          visible: !setupInspector.presentation.installed && setupInspector.row.installAvailable === true
            && !setupInspector.chosen && !setupInspector.presentation.failed
          width: parent.width
          spacing: Style.space(9)
          PanelSeparator { width: parent.width; foreground: root.foreground }
          Toggle {
            width: parent.width
            label: setupInspector.presentation.exclusive ? "Activate this shell replacement" : "Enable after installation"
            description: setupInspector.presentation.exclusive
              ? "Opt in to replace the active shell role. Leave off to install without activating."
              : "Install and enable in Omarchy. Turn off to install without enabling."
            checked: root.draftInstallEnabled
            enabled: setupInspector.presentation.canInstall
            foreground: root.foreground
            accent: Color.accent
            Accessible.role: Accessible.CheckBox
            Accessible.checkable: true
            Accessible.name: label
            Accessible.checked: checked
            Accessible.onToggleAction: if (enabled) root.draftInstallEnabled = !root.draftInstallEnabled
            onClicked: root.draftInstallEnabled = !root.draftInstallEnabled
          }
          Text {
            visible: setupInspector.presentation.widget
            text: "Widget location when enabled"
            textFormat: Text.PlainText
            color: root.secondary
            font.family: root.fontFamily
            font.pixelSize: root.supportingSize
          }
          Flow {
            visible: setupInspector.presentation.widget
            width: parent.width
            spacing: Style.space(6)
            Repeater {
              model: ["left", "center", "right"]
              Button {
                required property string modelData
                text: modelData.charAt(0).toUpperCase() + modelData.slice(1)
                foreground: root.foreground
                bordered: true
                focusable: true
                enabled: setupInspector.presentation.canInstall && root.draftInstallEnabled
                selected: root.draftInstallSection === modelData
                onClicked: {
                  root.draftInstallSection = modelData
                  root.rememberBarSection(setupInspector.row, modelData)
                }
              }
            }
          }
          Text {
            visible: Boolean(setupInspector.row.installNote)
            width: parent.width
            text: String(setupInspector.row.installNote || "")
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.secondary
            font.family: root.fontFamily
            font.pixelSize: root.supportingSize
          }
        }

        PanelSeparator {
          visible: setupInspector.row.readmeAvailable === true
          width: parent.width
          foreground: root.foreground
        }
        Text {
          visible: setupInspector.row.readmeAvailable === true
          width: parent.width
          text: "FROM README"
          textFormat: Text.PlainText
          color: root.secondary
          font.family: root.fontFamily
          font.pixelSize: root.supportingSize
          font.bold: true
          font.letterSpacing: 1.1
        }
        Text {
          visible: Boolean(setupInspector.row.readmeSummary)
          width: parent.width
          text: setupInspector.row.readmeSummary || ""
          textFormat: Text.PlainText
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: root.readingSize
          wrapMode: Text.WordWrap
          maximumLineCount: 4
          elide: Text.ElideRight
        }
        Text {
          visible: setupInspector.row.readmeAvailable === true
          width: parent.width
          text: setupInspector.row.listingCommit
            ? "Exact marketplace revision " + String(setupInspector.row.listingCommit).slice(0, 10)
            : "Exact marketplace revision"
          textFormat: Text.PlainText
          color: root.secondary
          font.family: root.fontFamily
          font.pixelSize: root.supportingSize
        }
        Button {
          visible: setupInspector.row.readmeAvailable === true
          text: root.setupReadmeExpanded ? "Hide README text"
            : (root.readmeLoading(setupInspector.row)
              ? "Loading README" : "Show README text")
          iconText: root.setupReadmeExpanded ? "^" : "v"
          foreground: root.foreground
          bordered: true
          focusable: true
          enabled: root.service && (!root.service.queryBusy
            || root.readmeLoading(setupInspector.row))
          onClicked: root.toggleSetupReadme()
        }
        Text {
          visible: root.setupReadmeExpanded && !root.readmeContentFor(setupInspector.row)
            && root.readmeLoading(setupInspector.row)
          width: parent.width
          text: "Loading sanitized README text from GitHub..."
          textFormat: Text.PlainText
          color: root.secondary
          font.family: root.fontFamily
          font.pixelSize: root.readingSize
          wrapMode: Text.WordWrap
        }
        Text {
          visible: root.setupReadmeExpanded && Boolean(root.readmeContentFor(setupInspector.row))
          width: parent.width
          text: root.readmeContentFor(setupInspector.row)
          textFormat: Text.PlainText
          color: root.secondary
          font.family: root.fontFamily
          font.pixelSize: root.readingSize
          wrapMode: Text.WordWrap
        }
      }
    }

    BorderSurface {
      id: setupInspectorAction
      visible: !setupInspector.presentation.installed || setupInspector.presentation.pending
        || setupInspector.presentation.failed || !setupInspector.presentation.known || Boolean(root.inspectorActionError)
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.margins: Style.space(12)
      height: inspectorFooterContent.implicitHeight + Style.space(18)
      radius: Style.cornerRadius
      color: Style.selectedFillFor(root.foreground, Color.accent)

      Column {
        id: inspectorFooterContent
        x: Style.space(9)
        y: Style.space(9)
        width: parent.width - Style.space(18)
        spacing: Style.space(8)

        Text {
          visible: Boolean(text)
          width: parent.width
          text: root.inspectorActionError || setupInspector.presentation.message
            || (setupInspector.presentation.state === "manual" ? "This plugin uses manual setup." : "")
          textFormat: Text.PlainText
          color: setupInspector.presentation.failed || root.inspectorActionError ? Color.urgent : root.secondary
          font.family: root.fontFamily
          font.pixelSize: root.supportingSize
          wrapMode: Text.WordWrap
        }
        Flow {
          width: parent.width
          spacing: Style.space(7)
          Button {
            id: setupInspectorPrimary
            visible: Boolean(setupInspector.presentation.action)
            text: setupInspector.presentation.action === "install" ? "Install" : setupInspector.presentation.primaryLabel
            foreground: root.foreground
            bordered: true
            focusable: true
            enabled: root.primaryEnabled(setupInspector.row)
            onClicked: root.inspectorPrimary(setupInspector.row)
          }
          Button {
            visible: setupInspector.presentation.state === "selected" || setupInspector.presentation.state === "available"
            text: setupInspector.chosen ? "Remove from batch" : "Add to batch install"
            foreground: root.secondary
            bordered: true
            focusable: true
            enabled: setupInspector.presentation.canQueue && (setupInspector.chosen || root.setupSelectedCount < 50)
            onClicked: root.toggleSetupSelection(setupInspector.row)
          }
        }
      }
    }
  }

  Connections {
    target: root.service
    ignoreUnknownSignals: true
    function onDiscoveryRowsChanged() { root.updateDiscoveryCache() }
    function onMatchesChanged() { root.captureRestoredInspector(); Qt.callLater(function() { root.restoreViewport() }) }
    function onSetupRowsChanged() { Qt.callLater(function() { root.restoreViewport(); root.finishPageScroll() }) }
    function onUpdatesChanged() { root.captureRestoredInspector(); Qt.callLater(function() { root.restoreViewport() }) }
    function onUpdatesLoadedChanged() { Qt.callLater(function() { root.restoreViewport() }) }
    function onUpdatesBusyChanged() { Qt.callLater(function() { root.restoreViewport() }) }
    function onWorkspaceViewChanged() {
      root.dismissTooltips()
      if (root.opened && root.workspaceView === "discover") root.ensureDiscovery()
    }
    function onPreferencesChanged() {
      if (BrowseState.shouldSyncSettings(root.opened, root.settingsTouched,
          root.service.activeAction, String(root.service.activeRequest.preferenceScope || "settings")))
        root.syncDraft()
      if (root.service.activeAction === "save-preferences"
          && root.pendingServiceChoices !== null) {
        var selected = root.pendingServiceChoices.slice()
        var activeServices = []
        var currentServices = Array.isArray(root.service.setupServiceIds)
          ? root.service.setupServiceIds : []
        for (var serviceIndex = 0; serviceIndex < currentServices.length; serviceIndex++) {
          if (selected.indexOf(currentServices[serviceIndex]) >= 0)
            activeServices.push(currentServices[serviceIndex])
        }
        root.pendingServiceChoices = null
        root.servicePickerEditing = false
        root.setupStage = "browse"
        root.service.quickSetup(
          setupSearchField.text.trim(), root.service.setupGroup,
          root.service.setupSort, 1, activeServices, "",
          root.service.setupInstallFilter, root.service.setupPartyFilter,
          root.service.setupHardwareOnly)
      }
      if (root.setupStage === "services" && !root.serviceDraftTouched) {
        root.syncServiceDraft()
        if (root.service.activeAction === "load"
            && root.service.preferences.servicesOnboardingComplete === true)
          root.setupStage = "browse"
      }
    }
    function onCurrentCategoryChanged() {
      root.chosenCategory = String(root.service.currentCategory || "")
      categoryPicker.value = root.chosenCategory
    }
    function onCacheLoadedChanged() {
      if (root.opened && root.workspaceView === "discover") root.ensureDiscovery()
      if (root.opened && root.activeView === "setup" && root.service.cacheLoaded) {
        var restore = root.pendingSetupRestore
        root.pendingSetupRestore = null
        var savedServices = restore && Array.isArray(restore.services)
          ? restore.services
          : (root.service.setupServicesInitialized
            && Array.isArray(root.service.setupServiceIds)
            ? root.service.setupServiceIds : [])
        root.service.quickSetup(
          root.service.setupQuery, restore ? restore.group : "",
          root.service.setupSort,
          restore ? restore.page : 1, savedServices,
          restore ? restore.serviceFilter : "",
          restore ? restore.installFilter : undefined,
          restore ? restore.partyFilter : undefined,
          restore ? restore.hardwareOnly : undefined,
          restore ? restore.category : undefined)
      }
    }
    function onBatchRunningChanged() {
      if (root.service.batchRunning) root.setupStage = "progress"
    }
    function onQueryBusyChanged() {
      if (!root.service.queryBusy) Qt.callLater(function() { root.finishPageScroll() })
      if (!root.service.queryBusy && root.pendingServiceChoices !== null
          && root.service.error) root.pendingServiceChoices = null
    }
  }

  Timer {
    id: searchDebounce
    interval: 100
    onTriggered: root.applyFilters()
  }

  Timer {
    id: setupSearchDebounce
    interval: 100
    onTriggered: root.requestSetup(
      setupSearchField.text.trim(), root.service ? root.service.setupGroup : "",
      root.service ? root.service.setupSort : "likes", 1)
  }

  FloatingWindow {
    id: window
    visible: root.opened
    title: "Outfit - Plugin Manager"
    color: root.background
    implicitWidth: Style.space(1180)
    implicitHeight: Style.space(760)
    minimumSize: Qt.size(Style.space(760), Style.space(540))
    maximized: false
    onWidthChanged: { root.dismissTooltips(); root.rememberPanel() }
    onHeightChanged: { root.dismissTooltips(); root.rememberPanel() }

    onVisibleChanged: {
      if (!visible && root.opened && !root.closingFromHost) root.requestClose()
    }

    FocusScope {
      id: focusScope
      anchors.fill: parent
      focus: true

      // Observe input without a MouseArea overlay or an exclusive pointer grab;
      // buttons, card clicks, wheel scrolling and modal dismissal keep ownership.
      HoverHandler {
        property point lastPosition: Qt.point(-1, -1)
        onPointChanged: {
          // Qt also refreshes hover after layout/popup changes with a stationary
          // pointer. Only actual movement changes the input modality.
          if (point.scenePosition.x === lastPosition.x && point.scenePosition.y === lastPosition.y) return
          lastPosition = point.scenePosition
          root.notePointerHelpInput(point.scenePosition)
        }
        onHoveredChanged: if (!hovered) root.notePointerHelpInput()
      }
      PointHandler {
        acceptedButtons: Qt.AllButtons
        grabPermissions: PointerHandler.TakeOverForbidden
        onActiveChanged: if (active) { root.notePointerHelpInput(); root.dismissTooltips() }
      }
      WheelHandler {
        target: null
        onWheel: function(event) {
          root.notePointerHelpInput()
          root.dismissTooltips()
          event.accepted = false
        }
      }
      Connections {
        target: focusScope.Window.window
        function onActiveChanged() {
          if (!focusScope.Window.window.active) {
            root.notePointerHelpInput()
            root.dismissTooltips()
          }
        }
      }
      Keys.onShortcutOverride: function(event) { root.noteKeyboardHelpInput(event) }

      Shortcut {
        sequences: ["Tab", "Shift+Tab"]
        enabled: root.browseNavigation && root.setupRows.length > 0 && (root.filterFocus || root.resultFocus)
        onActivated: root.switchBrowseGroup()
      }
      Shortcut {
        sequence: "Backspace"
        enabled: root.opened && !root.confirmationOpen && !Navigation.textEditing(root.keyboardFocus)
          && Navigation.contains(workspace, root.keyboardFocus) && !maintenanceMenu.visible
        onActivated: root.goBack()
      }
      Shortcut {
        sequence: "Ctrl+Down"
        enabled: root.browseNavigation && root.filterFocus
        onActivated: root.moveFilterFocus(Qt.Key_Down)
      }
      Shortcut {
        sequence: "F6"
        enabled: root.browseNavigation && Navigation.contains(workspace, root.keyboardFocus)
        onActivated: {
          root.cardContentsOwner = null
          settingsButton.forceActiveFocus()
        }
      }
      Shortcut {
        sequence: "Up"
        enabled: root.browseNavigation && root.filterFocus && !Navigation.textEditing(root.keyboardFocus)
        onActivated: root.moveFilterFocus(Qt.Key_Up)
      }
      Shortcut {
        sequence: "Down"
        enabled: root.browseNavigation && root.filterFocus && !Navigation.textEditing(root.keyboardFocus)
        onActivated: root.moveFilterFocus(Qt.Key_Down)
      }
      Shortcut {
        sequence: "Left"
        enabled: root.browseNavigation && root.filterFocus && !Navigation.textEditing(root.keyboardFocus)
          && !Navigation.contains(densityButtons, root.keyboardFocus)
        onActivated: root.moveFilterFocus(Qt.Key_Left)
      }
      Shortcut {
        sequence: "Right"
        enabled: root.browseNavigation && root.filterFocus && !Navigation.textEditing(root.keyboardFocus)
          && !Navigation.contains(densityButtons, root.keyboardFocus)
        onActivated: root.moveFilterFocus(Qt.Key_Right)
      }

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (detailPrototypeLoader.active) return
        if (root.updateReviewOpen) return
        if (root.actionConfirmOpen) {
          if (actionConfirm.handleKey(event)) event.accepted = true
          return
        }
        if (root.batchConfirmOpen) {
          if (batchConfirm.handleKey(event)) event.accepted = true
          return
        }
        if (Navigation.textEditing(root.keyboardFocus)
            && [Qt.Key_Backspace, Qt.Key_Delete, Qt.Key_Left, Qt.Key_Right, Qt.Key_Up, Qt.Key_Down].indexOf(event.key) >= 0)
          return
        if (event.key === Qt.Key_Escape && root.dismissTooltips()) {
          event.accepted = true
          return
        }
        if (event.key !== Qt.Key_Escape) root.dismissTooltips()
        if (event.key === Qt.Key_Escape) {
          if (root.interestsOpen) root.leaveInterests()
          else if (root.activeView === "setup" && root.setupDetailId)
            root.closeSetupDetail()
          else if (root.settingsOpen) root.leaveSettings()
          else if (root.activeView === "setup" && root.setupStage === "services"
                   && root.servicePickerEditing) root.cancelServicePicker()
          else if (root.activeView === "setup" && root.setupStage === "review")
            root.setupStage = "browse"
          else if (root.setupStage === "updates") root.leaveUpdates()
          else if (root.activeView === "setup" && root.setupStage === "progress"
                   && root.service && !root.service.batchRunning) {
             root.setupStage = root.updateBatch ? "updates" : "browse"
          }
          else if (root.narrowWorkspace && root.narrowDetailOpen) root.narrowDetailOpen = false
          else root.requestClose()
          event.accepted = true
        } else if (root.activeView === "fit" && searchField.activeFocus && event.key === Qt.Key_Down
                   && (event.modifiers & Qt.ControlModifier) && root.resultRows.length) {
          focusScope.forceActiveFocus()
          root.selectResult(0)
          resultList.positionViewAtIndex(0, ListView.Contain)
          event.accepted = true
        } else if (root.activeView === "fit" && !root.settingsOpen && !root.narrowDetailOpen
                   && !searchField.activeFocus
                   && event.key === Qt.Key_Down && root.resultRows.length) {
          root.selectResult(Math.min(root.resultRows.length - 1, root.selectedIndex + 1))
          resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
          event.accepted = true
        } else if (root.activeView === "fit" && !root.settingsOpen && !root.narrowDetailOpen
                   && !searchField.activeFocus
                   && event.key === Qt.Key_Up && root.resultRows.length) {
          root.selectResult(Math.max(0, root.selectedIndex < 0 ? 0 : root.selectedIndex - 1))
          resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
          event.accepted = true
        } else if (root.activeView === "fit" && !root.settingsOpen && root.narrowWorkspace && !root.narrowDetailOpen
                   && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                   && root.selectedRow) {
          root.narrowDetailOpen = true
          event.accepted = true
        } else if (root.activeView === "fit" && event.key === Qt.Key_Delete && !searchField.activeFocus
                   && !root.narrowDetailOpen
                   && root.selectedRow
                   && root.selectedRow.removable === true && root.service
                   && !root.operationPending(root.selectedRow)) {
          root.requestAction("remove", root.selectedRow)
          event.accepted = true
        } else if (root.activeView === "fit"
                   && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                   && !searchField.activeFocus
                   && root.service && !root.service.hasAnalyzed
                   && !root.service.queryBusy && !root.service.mutationBusy) {
          root.service.analyze()
          event.accepted = true
        } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_S) {
          if (root.interestsOpen && root.service) root.service.saveInterests()
          else if (root.preferencesDirty && root.service && !root.service.busy) root.saveSettings()
          event.accepted = true
        } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_F) {
          if (root.interestsOpen) { event.accepted = true; return }
          if (root.setupStage === "updates" && !root.settingsOpen) {
            root.closeSetupDetail(false)
            updatesPage.takeFocus()
            event.accepted = true
            return
          }
          root.settingsOpen = false
          if (root.setupStage === "browse" && root.workspaceView !== "browse") root.chooseWorkspace("browse")
          if (root.activeView === "setup" && !root.setupDetailInline
              && (root.setupDetailId || root.setupDetailFocusPending))
            root.closeSetupDetail()
          Qt.callLater(function() {
            var field = root.activeView === "setup"
              ? (root.setupStage === "services" ? servicePickerSearch : setupSearchField)
              : searchField
            field.forceActiveFocus()
            field.selectAll()
          })
          event.accepted = true
        }
      }

      Item {
        id: workspace
        enabled: !root.confirmationOpen
        anchors.fill: parent
        anchors.margins: Style.space(16)

        Item {
          id: workspaceHeader
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: Math.max(Style.space(38), workspaceTabs.visible ? workspaceTabs.implicitHeight : 0)
            + Style.space(26)
          objectName: "workspaceHeader"

          Button {
            id: settingsBack
            visible: root.settingsOpen && !root.interestsOpen
            anchors.left: parent.left
            anchors.top: parent.top
            text: "Back"
            foreground: root.foreground
            bordered: true
            focusable: true
            onClicked: root.leaveSettings()
          }

          Row {
            id: headerBrand
            anchors.left: settingsBack.visible ? settingsBack.right : parent.left
            anchors.leftMargin: settingsBack.visible ? Style.space(14) : 0
            anchors.top: parent.top
            height: Style.space(38)
            spacing: Style.space(8)

            OutfitIcon {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(25)
              height: width
              kind: "toolbox"
              tint: Color.accent
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.settingsOpen && !root.interestsOpen ? "OUTFIT SETTINGS"
                : "OUTFIT"
              textFormat: Text.PlainText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
            }
          }
            Text {
              id: headerStatus
              objectName: "startupBanner"
              anchors.left: parent.left
              anchors.right: startupBannerActions.visible ? startupBannerActions.left : parent.right
              anchors.rightMargin: Style.space(8)
              anchors.bottom: parent.bottom
              anchors.bottomMargin: Style.space(4)
              visible: Boolean(text)
              text: root.busySubtitle()
              textFormat: Text.PlainText
              color: root.service && root.service.backgroundError && !root.service.backgroundBusy
                ? Color.urgent : root.secondary
              font.family: root.fontFamily
              font.pixelSize: root.readingSize
              elide: Text.ElideRight
            }
            Rectangle {
              objectName: "startupProgress"
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              height: Style.space(2)
              readonly property real fraction: root.service && root.service.startupBannerVisible
                ? root.service.measuredProgress(root.service.startupProgress) : -1
              visible: fraction >= 0
              color: root.faint
              Rectangle { height: parent.height; width: parent.width * Math.max(0, parent.fraction); color: Color.accent }
            }
            Row {
              id: startupBannerActions
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              anchors.bottomMargin: Style.space(3)
              visible: Boolean(root.service && root.service.startupBannerVisible)
              spacing: Style.space(8)
              FilterButton {
                objectName: "startupDetails"
                text: "Details"
                implicitHeight: Style.space(22)
                topPadding: 0; bottomPadding: 0
                onClicked: { backgroundActivity.invoker = this; backgroundActivity.open() }
              }
              FilterButton {
                objectName: "startupDismiss"
                text: "Dismiss"
                implicitHeight: Style.space(22)
                topPadding: 0; bottomPadding: 0
                onClicked: root.service.startupDismissed = true
              }
            }
            BackgroundActivity {
              id: backgroundActivity
              parent: focusScope
              boundsItem: focusScope
              anchorItem: workspaceHeader
              service: root.service
            }

          Row {
            id: headerActions
            anchors.right: parent.right
            anchors.top: parent.top
            spacing: Style.space(7)

            Button {
              id: updatesButton
              objectName: "updatesButton"
              text: "Updates (" + (root.service ? Number(root.service.availableUpdateCount || 0) : 0) + ")"
              foreground: root.foreground
              bordered: true
              focusable: true
              selected: root.setupStage === "updates" && !root.settingsOpen && !root.interestsOpen
              enabled: root.headerNavigationEnabled
              Accessible.role: Accessible.Button
              Accessible.name: text
              Accessible.onPressAction: if (enabled) clicked()
              onClicked: root.openUpdates()
            }
            HeaderButton {
              id: moreActionsButton
              objectName: "moreActionsButton"
              iconKind: "more"
              accessibleLabel: "More actions"
              enabled: root.headerNavigationEnabled
              selected: maintenanceMenu.visible
              onClicked: maintenanceMenu.visible ? maintenanceMenu.dismiss(true) : maintenanceMenu.open()
              Keys.onDownPressed: maintenanceMenu.open()
            }
            HeaderButton {
              id: settingsButton
              iconKind: "settings"
              accessibleLabel: "Settings"
              selected: root.settingsOpen
              enabled: root.headerNavigationEnabled
              onClicked: {
                if (root.interestsOpen) root.leaveInterests()
                root.settingsOpen = true
                Qt.callLater(function() { if (root.opened) settingsBack.forceActiveFocus() })
              }
            }
            HeaderButton {
              iconKind: "close"
              accessibleLabel: "Close Outfit"
              enabled: !root.confirmationOpen
              onClicked: root.requestClose()
            }
          }

          C.Popup {
            id: maintenanceMenu
            property real clockNow: Date.now()
            parent: moreActionsButton
            popupType: C.Popup.Item
            width: Math.min(Style.space(330), focusScope.width - Style.space(16))
            x: moreActionsButton.width - width
            y: moreActionsButton.height + Style.space(6)
            padding: Style.space(8)
            margins: Style.space(8)
            implicitHeight: maintenanceActions.implicitHeight + topPadding + bottomPadding
            focus: true
            closePolicy: C.Popup.CloseOnEscape | C.Popup.CloseOnPressOutside

            function dismiss(restoreFocus) {
              close()
              root.dismissTooltips()
              if (restoreFocus && root.opened && moreActionsButton.enabled)
                moreActionsButton.forceActiveFocus()
            }
            function moveFocus(direction) {
              var buttons = [activityAction, rescanAction, refreshAction, outfitUpdateAction, menuIndexStatus.toggleButton]
              var current = buttons.findIndex(function(button) { return button.activeFocus })
              if (current < 0 && direction < 0) current = 0
              for (var step = 1; step <= buttons.length; step++) {
                var index = (current + direction * step + buttons.length * 2) % buttons.length
                if (buttons[index].enabled) {
                  buttons[index].forceActiveFocus()
                  return
                }
              }
              maintenanceActions.forceActiveFocus()
            }
            onAboutToShow: {
              root.dismissTooltips()
              clockNow = Date.now()
            }
            Timer {
              interval: 30000
              repeat: true
              running: maintenanceMenu.visible
              onTriggered: maintenanceMenu.clockNow = Date.now()
            }
            onOpened: moveFocus(1)
            background: BorderSurface {
              color: Color.popups.background
              radius: Style.cornerRadius
              borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
            }
            contentItem: Column {
              id: maintenanceActions
              spacing: Style.space(4)
              Keys.priority: Keys.BeforeItem
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) maintenanceMenu.dismiss(true)
                else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                  var forward = event.key !== Qt.Key_Backtab && !(event.modifiers & Qt.ShiftModifier)
                  maintenanceMenu.dismiss(true)
                  if (forward) settingsButton.forceActiveFocus()
                } else if (event.key === Qt.Key_Down)
                  maintenanceMenu.moveFocus(1)
                else if (event.key === Qt.Key_Up)
                  maintenanceMenu.moveFocus(-1)
                else if (event.key === Qt.Key_Home) {
                  maintenanceActions.forceActiveFocus()
                  maintenanceMenu.moveFocus(1)
                } else if (event.key === Qt.Key_End) {
                  maintenanceActions.forceActiveFocus()
                  maintenanceMenu.moveFocus(-1)
                } else return
                event.accepted = true
              }
              MaintenanceAction {
                id: activityAction
                objectName: "backgroundActivityAction"
                width: parent.width
                label: "Background activity"
                description: "Preparation details and progress."
                iconKind: "scan"
                Keys.forwardTo: [maintenanceActions]
                onClicked: {
                  maintenanceMenu.close()
                  backgroundActivity.invoker = moreActionsButton
                  backgroundActivity.open()
                }
              }
              MaintenanceAction {
                id: rescanAction
                width: parent.width
                label: "Rescan system"
                iconKind: "scan"
                description: "Local hardware and plugins."
                Keys.forwardTo: [maintenanceActions]
                enabled: root.service && !root.service.backgroundBusy && !root.service.mutationBusy
                onClicked: {
                  maintenanceMenu.dismiss(true)
                  root.service.rescan(false)
                }
              }
              MaintenanceAction {
                id: refreshAction
                width: parent.width
                label: "Refresh catalog"
                iconKind: "refresh"
                description: "Marketplace listings and counts."
                Keys.forwardTo: [maintenanceActions]
                enabled: root.service && !root.service.backgroundBusy && !root.service.catalogBusy && !root.service.mutationBusy
                onClicked: {
                  maintenanceMenu.dismiss(true)
                  root.service.refresh(root.service.currentQuery, root.service.currentCategory)
                }
              }
              MaintenanceAction {
                id: outfitUpdateAction
                objectName: "outfitUpdateAction"
                width: parent.width
                label: "Update Outfit…"
                iconKind: "refresh"
                description: "Check versions and update this app."
                Keys.forwardTo: [maintenanceActions]
                enabled: Boolean(root.service) && !root.service.selfUpdateBusy
                onClicked: root.openOutfitUpdate()
              }
              Text {
                visible: Boolean(root.busySubtitle())
                width: parent.width
                text: root.busySubtitle()
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: root.secondary
                font.family: root.fontFamily
                font.pixelSize: root.supportingSize
              }
              PanelSeparator { width: parent.width; foreground: Color.popups.text }
              ReadmeIndexStatus {
                id: menuIndexStatus
                width: parent.width
                service: root.service
                foreground: Color.popups.text
                navigationTarget: maintenanceActions
              }
              PanelSeparator { width: parent.width; foreground: Color.popups.text }
              Repeater {
                model: [
                  {label:"Catalog", time:root.service ? root.service.fetchedAt : 0},
                  {label:"Popularity", time:root.service ? root.service.likesFetchedAt : 0},
                  {label:"System", time:root.service ? root.service.lastHardwareCheckAt / 1000 : 0}
                ]
                Text {
                  required property var modelData
                  width: parent.width
                  text: modelData.label + " · " + Presentation.relativeAge(modelData.time, maintenanceMenu.clockNow)
                  textFormat: Text.PlainText
                  color: Color.popups.text
                  opacity: 0.7
                  font.family: root.fontFamily
                  font.pixelSize: root.supportingSize
                  wrapMode: Text.WordWrap
                }
              }
              Text {
                width: parent.width
                visible: Boolean(text)
                text: root.service ? String(root.service.dataWarning || "") : ""
                textFormat: Text.PlainText
                color: Color.popups.text
                font.family: root.fontFamily
                font.pixelSize: root.supportingSize
                wrapMode: Text.WordWrap
              }
              Text {
                width: parent.width
                visible: Boolean(text)
                text: root.service ? String(root.service.backgroundError || root.service.error || "") : ""
                textFormat: Text.PlainText
                color: Color.urgent
                font.family: root.fontFamily
                font.pixelSize: root.supportingSize
                wrapMode: Text.WordWrap
              }
            }
          }
        }

        Column {
          id: filters
          visible: !root.settingsOpen && root.activeView === "fit"
            && (!root.narrowWorkspace || !root.narrowDetailOpen)
          anchors.top: workspaceHeader.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          height: visible ? Style.space(120) : 0
          spacing: Style.space(7)

          Row {
            id: searchRow
            width: parent.width
            height: Style.space(42)
            spacing: Style.space(8)

            TextField {
              id: searchField
              width: parent.width - categoryPicker.width - parent.spacing
              foreground: root.foreground
              placeholderText: "Search tasks, hardware, or plugins"
              maximumLength: 160
              enabled: root.canBrowse
              onTextEdited: searchDebounce.restart()
              onAccepted: root.applyFilters()
            }
            Dropdown {
              id: categoryPicker
              width: Style.space(180)
              showLabel: false
              foreground: root.foreground
              fontFamily: root.fontFamily
              options: root.categoryOptions
              value: root.chosenCategory
              enabled: root.canBrowse
              onChanged: function(value) {
                root.chosenCategory = value
                root.applyFilters()
              }
            }
          }

          Row {
            width: parent.width
            height: Style.space(32)
            spacing: Style.space(6)

            Button {
              text: "Any status"
              foreground: root.foreground
              selected: root.service && root.service.currentInstallFilter === "all"
              enabled: root.canBrowse
              onClicked: root.chooseFilters("all", "")
            }
            Button {
              text: "Installed " + root.filterCount("installed")
              foreground: root.foreground
              selected: root.service && root.service.currentInstallFilter === "installed"
              enabled: root.canBrowse && root.canManagePlugins
              onClicked: root.chooseFilters("installed", "")
            }
            Button {
              text: "Available " + root.filterCount("available")
              foreground: root.foreground
              selected: root.service && root.service.currentInstallFilter === "available"
              enabled: root.canBrowse && root.canManagePlugins
              onClicked: root.chooseFilters("available", "")
            }
          }

          Row {
            width: parent.width
            height: Style.space(32)
            spacing: Style.space(6)

            Button {
              text: "Any source"
              foreground: root.foreground
              selected: root.service && root.service.currentPartyFilter === "all"
              enabled: root.canBrowse
              onClicked: root.chooseFilters("", "all")
            }
            Button {
              text: "First party " + root.filterCount("firstParty")
              foreground: root.foreground
              selected: root.service && root.service.currentPartyFilter === "first-party"
              enabled: root.canBrowse
              onClicked: root.chooseFilters("", "first-party")
            }
            Button {
              text: "Third party " + root.filterCount("thirdParty")
              foreground: root.foreground
              selected: root.service && root.service.currentPartyFilter === "third-party"
              enabled: root.canBrowse
              onClicked: root.chooseFilters("", "third-party")
            }
          }
        }

        BorderSurface {
          id: statusSurface
          visible: !root.settingsOpen && root.activeView === "fit"
            && (!root.narrowWorkspace || !root.narrowDetailOpen)
          anchors.top: filters.bottom
          anchors.topMargin: Style.space(10)
          anchors.left: parent.left
          anchors.right: parent.right
          implicitHeight: visible ? statusLabel.implicitHeight + Style.space(14) : 0
          radius: Style.space(7)
          color: root.service && root.service.error
            ? Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.09) : root.faint

          Text {
            id: statusLabel
            anchors.fill: parent
            anchors.margins: Style.space(7)
            text: root.statusText()
            textFormat: Text.PlainText
            color: root.service && root.service.error ? Color.urgent : root.secondary
            font.family: root.fontFamily
            font.pixelSize: root.supportingSize
            wrapMode: Text.WordWrap
          }
        }

        BorderSurface {
          id: consentSurface
          visible: !root.settingsOpen && root.setupStage !== "updates" && (!root.service || !root.service.cacheLoaded)
          anchors.top: statusSurface.bottom
          anchors.topMargin: Style.space(14)
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          radius: Style.cornerRadius
          color: root.faint

          Column {
            anchors.centerIn: parent
            width: Math.min(parent.width - Style.space(60), Style.space(540))
            spacing: Style.space(12)

            Text {
              width: parent.width
              text: root.service && root.service.queryBusy
                ? "OPENING OUTFIT" : "STARTUP NEEDS ATTENTION"
              textFormat: Text.PlainText
              horizontalAlignment: Text.AlignHCenter
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              font.letterSpacing: 1.1
            }
            Text {
              width: parent.width
              text: "Opening saved marketplace listings. Plugin checks and optional documentation preparation continue in the background."
              textFormat: Text.PlainText
              horizontalAlignment: Text.AlignHCenter
              color: root.secondary
              font.family: root.fontFamily
              font.pixelSize: root.readingSize
              wrapMode: Text.WordWrap
            }
            Text {
              visible: root.service && Boolean(root.service.error)
              width: parent.width
              text: root.service ? root.service.error : ""
              textFormat: Text.PlainText
              horizontalAlignment: Text.AlignHCenter
              color: Color.urgent
              font.family: root.fontFamily
              font.pixelSize: root.readingSize
              wrapMode: Text.WordWrap
            }
            Button {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "Retry startup"
              iconText: "*"
              iconSpinning: root.service && root.service.activeAction === "analyze"
              foreground: root.foreground
              bordered: true
              focusable: true
              enabled: root.service && !root.service.queryBusy && !root.service.mutationBusy && !root.service.backgroundBusy
              onClicked: root.service.retryStartup()
            }
          }
        }

        Item {
          visible: !root.settingsOpen && root.activeView === "fit"
            && root.canBrowse
          anchors.top: root.narrowWorkspace && root.narrowDetailOpen
            ? workspaceHeader.bottom : statusSurface.bottom
          anchors.topMargin: Style.space(14)
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom

          ListView {
            id: resultList
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            width: root.narrowWorkspace || !root.selectedRow
              ? parent.width : Math.max(Style.space(340), parent.width * 0.40)
            visible: !root.narrowWorkspace || !root.narrowDetailOpen
            clip: true
            model: root.sleeping ? [] : root.resultRows
            spacing: Style.space(8)
            currentIndex: root.selectedIndex
            boundsBehavior: Flickable.StopAtBounds
            onContentYChanged: { root.dismissTooltips(); helpScrollPause.restart() }
            C.ScrollBar.vertical: C.ScrollBar {}

            delegate: BorderSurface {
              id: resultCard
              required property var modelData
              required property int index
              width: resultList.width - Style.space(12)
              height: cardContent.implicitHeight + Style.space(20)
              radius: Style.cornerRadius
              color: index === root.selectedIndex
                ? Style.selectedFillFor(root.foreground, Color.accent) : root.faint
              borderSpec: index === root.selectedIndex
                ? Border.controlSpec("selected", root.foreground, Color.accent) : Border.none()

              TapHandler { onTapped: root.selectResult(resultCard.index) }

              Column {
                id: cardContent
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Style.space(10)
                spacing: Style.space(5)

                Row {
                  width: parent.width
                  spacing: Style.space(8)

                  Text {
                    width: parent.width - fitLabel.width - parent.spacing
                    text: resultCard.modelData.name || resultCard.modelData.id
                    textFormat: Text.PlainText
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: root.readingSize
                    font.bold: true
                    elide: Text.ElideRight
                  }
                  Text {
                    id: fitLabel
                    text: "FIT " + Number(resultCard.modelData.score || 0)
                    textFormat: Text.PlainText
                    color: Color.accent
                    font.family: root.fontFamily
                    font.pixelSize: root.supportingSize
                    font.bold: true
                  }
                }
                Text {
                  width: parent.width
                  text: (root.effectiveInstalled(resultCard.modelData) ? "INSTALLED / " : "")
                    + (resultCard.modelData.firstParty ? "FIRST PARTY / " : "THIRD PARTY / ")
                    + String(resultCard.modelData.category || "Other").toUpperCase()
                  textFormat: Text.PlainText
                  color: root.effectiveInstalled(resultCard.modelData) ? Color.accent : root.secondary
                  font.family: root.fontFamily
                  font.pixelSize: root.supportingSize
                  font.bold: root.effectiveInstalled(resultCard.modelData)
                  elide: Text.ElideRight
                }
                Text {
                  width: parent.width
                  text: resultCard.modelData.reason || "Marketplace match"
                  textFormat: Text.PlainText
                  color: root.secondary
                  font.family: root.fontFamily
                  font.pixelSize: root.readingSize
                  maximumLineCount: 2
                  wrapMode: Text.WordWrap
                  elide: Text.ElideRight
                }

                Column {
                  width: parent.width
                  spacing: Style.space(7)
                  visible: resultCard.index === root.selectedIndex

                  PanelSeparator { width: parent.width; foreground: root.foreground }

                  Text {
                    visible: resultCard.modelData.barWidget === true
                      && (root.effectiveInstalled(resultCard.modelData)
                        || resultCard.modelData.installAvailable === true)
                    width: parent.width
                    text: root.effectiveInstalled(resultCard.modelData)
                      ? "MOVE WIDGET TO" : "INSTALL LOCATION"
                    textFormat: Text.PlainText
                    color: root.secondary
                    font.family: root.fontFamily
                    font.pixelSize: root.supportingSize
                    font.bold: true
                  }
                  Flow {
                    width: parent.width
                    spacing: Style.space(6)
                    visible: resultCard.modelData.barWidget === true
                      && (root.effectiveInstalled(resultCard.modelData)
                        || resultCard.modelData.installAvailable === true)

                    BarSectionButton {
                      pluginRow: resultCard.modelData
                      section: "left"
                      resultIndex: resultCard.index
                    }
                    BarSectionButton {
                      pluginRow: resultCard.modelData
                      section: "center"
                      resultIndex: resultCard.index
                    }
                    BarSectionButton {
                      pluginRow: resultCard.modelData
                      section: "right"
                      resultIndex: resultCard.index
                    }
                  }

                  Flow {
                    width: parent.width
                    spacing: Style.space(7)

                    Button {
                      visible: !root.effectiveInstalled(resultCard.modelData)
                        && resultCard.modelData.installAvailable === true
                      text: root.operationPending(resultCard.modelData)
                        ? root.operationProgress(resultCard.modelData) : "Install plugin"
                      iconText: "+"
                      foreground: root.foreground
                      bordered: true
                      focusable: true
                      enabled: root.service && !root.operationPending(resultCard.modelData)
                        && !root.service.batchRunning && !root.service.selfUpdateBusy
                      onClicked: root.requestAction("install", resultCard.modelData)
                    }
                    Text {
                      visible: root.canToggle(resultCard.modelData)
                      height: toggleControl.implicitHeight
                      verticalAlignment: Text.AlignVCenter
                      text: root.effectiveEnabled(resultCard.modelData) ? "ENABLED" : "DISABLED"
                      textFormat: Text.PlainText
                      color: root.effectiveEnabled(resultCard.modelData) ? Color.accent : root.secondary
                      font.family: root.fontFamily
                      font.pixelSize: root.supportingSize
                      font.bold: true
                    }
                    ToggleSwitch {
                      id: toggleControl
                      visible: root.canToggle(resultCard.modelData)
                      checked: root.effectiveEnabled(resultCard.modelData)
                      busy: root.operationPending(resultCard.modelData)
                      foreground: root.foreground
                      accent: Color.accent
                      onToggled: root.togglePlugin(resultCard.modelData)
                    }
                    Text {
                      visible: root.effectiveInstalled(resultCard.modelData)
                        && !root.canToggle(resultCard.modelData)
                      height: Math.max(implicitHeight, Style.space(28))
                      verticalAlignment: Text.AlignVCenter
                      text: root.effectiveEnabled(resultCard.modelData) ? "ENABLED" : "INSTALLED"
                      textFormat: Text.PlainText
                      color: root.secondary
                      font.family: root.fontFamily
                      font.pixelSize: root.supportingSize
                    }
                    Button {
                      visible: root.narrowWorkspace
                      text: "View details"
                      iconText: ">"
                      foreground: root.foreground
                      focusable: true
                      onClicked: root.narrowDetailOpen = true
                    }
                  }

                  Flow {
                    width: parent.width
                    spacing: Style.space(7)

                    Button {
                      visible: resultCard.modelData.removable === true
                        && root.effectiveInstalled(resultCard.modelData)
                      text: root.operationPending(resultCard.modelData)
                        ? root.operationProgress(resultCard.modelData) : "Remove plugin"
                      iconText: "X"
                      foreground: Color.urgent
                      focusable: true
                      enabled: root.service && !root.operationPending(resultCard.modelData)
                        && !root.service.batchRunning && !root.service.selfUpdateBusy
                      onClicked: root.requestAction("remove", resultCard.modelData)
                    }
                  }

                  Text {
                    visible: root.operationPending(resultCard.modelData)
                      || Boolean(root.operationError(resultCard.modelData))
                    width: parent.width
                    text: root.operationPending(resultCard.modelData)
                      ? root.operationProgress(resultCard.modelData)
                      : root.operationError(resultCard.modelData)
                    textFormat: Text.PlainText
                    color: root.operationPending(resultCard.modelData) ? Color.accent : Color.urgent
                    font.family: root.fontFamily
                    font.pixelSize: root.supportingSize
                    wrapMode: Text.WordWrap
                  }
                }
              }
            }
          }

          BorderSurface {
            id: detailSurface
            visible: root.selectedRow !== null
              && (!root.narrowWorkspace || root.narrowDetailOpen)
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.left: root.narrowWorkspace ? parent.left : resultList.right
            anchors.leftMargin: root.narrowWorkspace ? 0 : Style.space(14)
            anchors.right: parent.right
            radius: Style.cornerRadius
            color: root.faint

            HelpScrollView {
              id: legacyDetailScroll
              anchors.fill: parent
              anchors.margins: Style.space(18)
              clip: true
              C.ScrollBar.horizontal.policy: C.ScrollBar.AlwaysOff

              Column {
                width: legacyDetailScroll.availableWidth
                spacing: Style.space(12)

                Button {
                  visible: root.narrowWorkspace
                  text: "Back to results"
                  iconText: "<"
                  foreground: root.foreground
                  bordered: true
                  focusable: true
                  onClicked: root.narrowDetailOpen = false
                }

                Text {
                  width: parent.width
                  text: root.selectedRow ? root.selectedRow.name || root.selectedRow.id : ""
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                  wrapMode: Text.WordWrap
                }

                Flow {
                  width: parent.width
                  spacing: Style.space(6)
                  layoutDirection: Qt.RightToLeft

                  Button {
                    visible: root.selectedRow && Boolean(root.selectedRow.snapshotUrl || root.selectedRow.repo)
                    text: "Review source"
                    foreground: root.foreground
                    focusable: true
                    onClicked: root.service.openSource(root.selectedRow)
                  }
                  Button {
                    visible: root.selectedRow && Boolean(root.selectedRow.marketplaceUrl)
                    text: "Marketplace"
                    foreground: root.foreground
                    focusable: true
                    onClicked: root.service.openMarketplace(root.selectedRow)
                  }

                  Repeater {
                    model: root.detailStatuses(root.selectedRow)
                    StatusBadge {
                      required property var modelData
                      label: String(modelData)
                      emphasized: label === "Installed" || label === "Enabled"
                    }
                  }
                }

                Text {
                  width: parent.width
                  text: root.selectedRow
                    ? String(root.selectedRow.category || "Other").toUpperCase()
                      + " / " + String(root.selectedRow.reviewState || "not reviewed").toUpperCase()
                    : ""
                  textFormat: Text.PlainText
                  color: root.secondary
                  font.family: root.fontFamily
                  font.pixelSize: root.supportingSize
                  font.letterSpacing: 0.7
                  wrapMode: Text.WordWrap
                }
                Text {
                  width: parent.width
                  text: root.selectedRow ? root.selectedRow.description || "No description supplied." : ""
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: root.readingSize
                  wrapMode: Text.WordWrap
                }
                Text {
                  width: parent.width
                  text: root.selectedRow
                    ? "FIT " + Number(root.selectedRow.score || 0)
                      + " / BASE " + Number(root.selectedRow.baseScore || 0)
                    : ""
                  textFormat: Text.PlainText
                  color: Color.accent
                  font.family: root.fontFamily
                  font.pixelSize: root.readingSize
                  font.bold: true
                  wrapMode: Text.WordWrap
                }
                Text {
                  width: parent.width
                  text: "Fit is a deterministic match to detected capabilities and listing text, not a compatibility or security guarantee."
                  textFormat: Text.PlainText
                  color: root.secondary
                  font.family: root.fontFamily
                  font.pixelSize: root.readingSize
                  wrapMode: Text.WordWrap
                }
                PanelSeparator { width: parent.width; foreground: root.foreground }
                Text {
                  width: parent.width
                  text: "WHY IT FITS"
                  textFormat: Text.PlainText
                  color: root.secondary
                  font.family: root.fontFamily
                  font.pixelSize: root.supportingSize
                  font.bold: true
                  font.letterSpacing: 1.1
                }
                Text {
                  width: parent.width
                  text: root.selectedRow ? root.selectedRow.reason || "Marketplace match" : ""
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: root.readingSize
                  wrapMode: Text.WordWrap
                }
                Repeater {
                  model: [
                    { key: "hardware", label: "HARDWARE" }
                  ]

                  Column {
                    id: channelRow
                    required property var modelData
                    readonly property int channelValue: root.selectedRow && root.selectedRow.scores
                      ? Number(root.selectedRow.scores[modelData.key] || 0) : 0
                    width: parent.width
                    spacing: Style.space(4)

                    Item {
                      width: parent.width
                      height: channelLabel.implicitHeight
                      Text {
                        id: channelLabel
                        anchors.left: parent.left
                        text: modelData.label
                        textFormat: Text.PlainText
                        color: root.secondary
                        font.family: root.fontFamily
                        font.pixelSize: root.supportingSize
                        font.bold: true
                      }
                      Text {
                        anchors.right: parent.right
                        text: channelRow.channelValue
                        textFormat: Text.PlainText
                        color: Color.accent
                        font.family: root.fontFamily
                        font.pixelSize: root.supportingSize
                        font.bold: true
                      }
                    }
                    Rectangle {
                      width: parent.width
                      height: Style.space(5)
                      radius: height / 2
                      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)
                      Rectangle {
                        width: parent.width * Math.max(0, Math.min(100, channelRow.channelValue)) / 100
                        height: parent.height
                        radius: height / 2
                        color: Color.accent
                      }
                    }

                    Repeater {
                      model: root.evidenceRows(channelRow.modelData.key)

                      Rectangle {
                        id: evidenceRow
                        required property var modelData
                        width: channelRow.width
                        height: evidenceLabel.implicitHeight + Style.space(12)
                        radius: Style.space(6)
                        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.045)

                        Text {
                          id: evidenceLabel
                          anchors.fill: parent
                          anchors.margins: Style.space(6)
                          text: root.evidenceText(evidenceRow.modelData)
                          textFormat: Text.PlainText
                          color: root.secondary
                          font.family: root.fontFamily
                          font.pixelSize: root.supportingSize
                          wrapMode: Text.WordWrap
                        }
                      }
                    }
                  }
                }

                PanelSeparator {
                  visible: root.selectedRow && root.selectedRow.readmeAvailable === true
                  width: parent.width
                  foreground: root.foreground
                }
                Text {
                  visible: root.selectedRow && root.selectedRow.readmeAvailable === true
                  width: parent.width
                  text: "FROM README"
                  textFormat: Text.PlainText
                  color: root.secondary
                  font.family: root.fontFamily
                  font.pixelSize: root.supportingSize
                  font.bold: true
                  font.letterSpacing: 1.1
                }
                Text {
                  visible: Boolean(root.readmeExcerpt(root.selectedRow))
                  width: parent.width
                  text: root.readmeExcerpt(root.selectedRow)
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: root.readingSize
                  wrapMode: Text.WordWrap
                }
                Text {
                  visible: root.selectedRow && root.selectedRow.readmeAvailable === true
                  width: parent.width
                  text: root.selectedRow && root.selectedRow.listingCommit
                    ? "Exact marketplace revision " + String(root.selectedRow.listingCommit).slice(0, 10)
                    : "Exact marketplace revision"
                  textFormat: Text.PlainText
                  color: root.secondary
                  font.family: root.fontFamily
                  font.pixelSize: root.supportingSize
                }
                Button {
                  visible: root.selectedRow && root.selectedRow.readmeAvailable === true
                  text: root.readmeExpanded ? "Hide full README"
                    : (root.readmeLoading(root.selectedRow)
                      ? "Loading README" : "Show full README")
                  iconText: root.readmeExpanded ? "^" : "v"
                  foreground: root.foreground
                  bordered: true
                  focusable: true
                  enabled: root.service && (!root.service.queryBusy
                    || root.readmeLoading(root.selectedRow))
                  onClicked: root.toggleReadme()
                }
                Text {
                  visible: root.readmeExpanded && !root.currentReadmeContent()
                    && root.readmeLoading(root.selectedRow)
                  width: parent.width
                  text: "Loading sanitized README text from GitHub..."
                  textFormat: Text.PlainText
                  color: root.secondary
                  font.family: root.fontFamily
                  font.pixelSize: root.readingSize
                  wrapMode: Text.WordWrap
                }
                Text {
                  visible: root.readmeExpanded && Boolean(root.currentReadmeContent())
                  width: parent.width
                  text: root.currentReadmeContent()
                  textFormat: Text.PlainText
                  color: root.secondary
                  font.family: root.fontFamily
                  font.pixelSize: root.readingSize
                  wrapMode: Text.WordWrap
                }

              }
            }
          }

          Column {
            anchors.centerIn: parent
            visible: !root.resultRows.length
            width: Math.min(parent.width - Style.space(40), Style.space(440))
            spacing: Style.space(7)

            Text {
              width: parent.width
              text: root.service && root.service.queryBusy ? "UPDATING RESULTS"
                : (searchField.text.trim() || root.chosenCategory
                  || (root.service && (root.service.currentInstallFilter !== "all"
                    || root.service.currentPartyFilter !== "all"))
                  ? "NO RESULTS MATCH" : "NO STRONG FIT YET")
              textFormat: Text.PlainText
              horizontalAlignment: Text.AlignHCenter
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Text {
              width: parent.width
              text: searchField.text.trim() || root.chosenCategory
                || (root.service && (root.service.currentInstallFilter !== "all"
                  || root.service.currentPartyFilter !== "all"))
                ? "Try a broader search or reset the active filters."
                : "Search for a task or refresh the marketplace catalog."
              textFormat: Text.PlainText
              horizontalAlignment: Text.AlignHCenter
              color: root.secondary
              font.family: root.fontFamily
              font.pixelSize: root.readingSize
              wrapMode: Text.WordWrap
            }
          }
        }

        InterestsManager {
          id: interestsManager
          objectName: "interestsManager"
          visible: root.interestsOpen
          service: root.service
          anchors.top: workspaceHeader.bottom
          anchors.topMargin: Style.space(10)
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          onBack: root.leaveInterests()
        }

        BorderSurface {
          id: settingsPage
          visible: root.settingsOpen && !root.interestsOpen
          anchors.top: workspaceHeader.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          radius: Style.cornerRadius
          color: root.faint

          HelpScrollView {
            id: settingsScroll
            anchors.fill: parent
            anchors.margins: Style.space(22)
            clip: true
            C.ScrollBar.horizontal.policy: C.ScrollBar.AlwaysOff

            Column {
              width: settingsScroll.availableWidth
              spacing: Style.space(16)

              Button {
                id: settingsInterestsButton
                text: "Setup & interests…"
                foreground: root.foreground
                bordered: true
                focusable: true
                onClicked: root.openInterests(settingsInterestsButton)
              }
              Text {
                width: parent.width
                text: "Manage detected inputs and saved interests. Reset settings keeps interests and match review history."
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: root.secondary
                font.family: root.fontFamily
                font.pixelSize: root.readingSize
              }

              Text {
                width: parent.width
                text: "SYSTEM SCANNING"
                textFormat: Text.PlainText
                color: root.secondary
                font.family: root.fontFamily
                font.pixelSize: root.supportingSize
                font.bold: true
                font.letterSpacing: 1.1
              }

              Toggle {
                id: watcherSetting
                width: parent.width
                label: "Watch hardware every 60 seconds"
                description: "Run local-only follow-up scans after the automatic opening scan."
                checked: root.draftWatchHardware
                foreground: root.foreground
                accent: Color.accent
                onClicked: {
                  root.draftWatchHardware = !root.draftWatchHardware
                  root.settingsTouched = true
                }
              }

              PanelSeparator { width: parent.width; foreground: root.foreground }

              Text {
                width: parent.width
                text: "RECOMMENDATION SOURCES"
                textFormat: Text.PlainText
                color: root.secondary
                font.family: root.fontFamily
                font.pixelSize: root.supportingSize
                font.bold: true
                font.letterSpacing: 1.1
              }

              Toggle {
                id: readmeSetting
                width: parent.width
                label: "Use GitHub READMEs and previews"
                description: "Index exact-revision GitHub README text in the background while Outfit is open. Search uses local text; inspector previews load on demand."
                checked: root.draftReadmes
                foreground: root.foreground
                accent: Color.accent
                onClicked: {
                  root.draftReadmes = !root.draftReadmes
                  root.settingsTouched = true
                }
              }

              Toggle {
                width: parent.width
                label: "Show marketplace thumbnails"
                description: "Load small previews for visible browse cards from plugins.omarchy.org. Cached separately from GitHub README media."
                checked: root.draftThumbnails
                foreground: root.foreground
                accent: Color.accent
                onClicked: {
                  root.draftThumbnails = !root.draftThumbnails
                  root.settingsTouched = true
                }
              }

              Row {
                width: parent.width
                spacing: Style.space(8)

                Button {
                  text: root.service && root.service.activeAction === "save-preferences"
                    ? "Saving" : "Save settings"
                  iconText: "S"
                  foreground: root.foreground
                  bordered: true
                  focusable: true
                  enabled: root.preferencesDirty && root.service && !root.service.busy
                  onClicked: root.saveSettings()
                }
                Button {
                  text: "Reset settings"
                  foreground: root.foreground
                  focusable: true
                  enabled: root.service
                  onClicked: root.resetSettings()
                }
              }

              Text {
                width: parent.width
                text: root.preferencesDirty
                  ? "Unsaved settings are applied only after saving."
                  : "Settings are saved in Outfit's private local configuration."
                textFormat: Text.PlainText
                color: root.preferencesDirty ? Color.accent : root.secondary
                font.family: root.fontFamily
                font.pixelSize: root.supportingSize
                wrapMode: Text.WordWrap
              }

              PanelSeparator { width: parent.width; foreground: root.foreground }
              DiagnosticsPane { width: parent.width; service: root.service }
              PanelSeparator { width: parent.width; foreground: root.foreground }
              ReadmeIndexStatus { width: parent.width; service: root.service }
              Text {
                visible: root.service && Boolean(root.service.error)
                width: parent.width
                text: root.service ? root.service.error : ""
                textFormat: Text.PlainText
                color: Color.urgent
                font.family: root.fontFamily
                font.pixelSize: root.supportingSize
                wrapMode: Text.WordWrap
              }
            }
          }
        }

        BorderSurface {
          id: quickSetupStatus
          visible: !root.settingsOpen && !root.interestsOpen && root.activeView === "setup"
            && root.service && root.service.cacheLoaded
            && root.setupStage !== "browse" && root.setupStage !== "updates"
            && Boolean(root.service.error)
          anchors.top: workspaceHeader.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          implicitHeight: visible ? quickSetupStatusText.implicitHeight + Style.space(14) : 0
          radius: Style.space(7)
          color: root.service && root.service.error
            ? Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.09) : root.faint

          Text {
            id: quickSetupStatusText
            anchors.fill: parent
            anchors.margins: Style.space(7)
            text: root.statusText()
            textFormat: Text.PlainText
            color: root.service && root.service.error ? Color.urgent : root.secondary
            font.family: root.fontFamily
            font.pixelSize: root.supportingSize
            wrapMode: Text.WordWrap
          }
        }

        Item {
          id: quickSetupPage
          visible: !root.settingsOpen && !root.interestsOpen && root.activeView === "setup"
            && root.service && (root.service.cacheLoaded || root.setupStage === "updates")
          anchors.top: quickSetupStatus.visible ? quickSetupStatus.bottom : workspaceHeader.bottom
          anchors.topMargin: Style.space(10)
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom

          UpdatesPage {
            id: updatesPage
            anchors.fill: parent
            visible: root.setupStage === "updates"
            active: root.uiAwake && visible && !setupDetailPanel.visible
            enabled: !setupDetailPanel.visible
            service: root.service
            inventoryReady: root.canManagePlugins && Boolean(root.service && root.service.inventoryReady)
            settingsTouched: root.settingsTouched
            onBackRequested: root.leaveUpdates()
            onCheckRequested: root.checkUpdates()
            onUpdateRequested: function(row) { root.requestUpdate(row) }
            onUpdateAllRequested: root.reviewAllUpdates()
            onDetailRequested: function(row, invoker) { root.openSetupDetail(root.updateDetailRow(row), invoker) }
            onProgressRequested: root.setupStage = "progress"
            onPositionChanged: root.rememberPanel()
          }

          Item {
            id: setupServicesPage
            visible: root.setupStage === "services"
            anchors.fill: parent

            Column {
              id: servicePickerHeader
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.right: parent.right
              spacing: Style.space(7)

              Text {
                width: parent.width
                text: "Service watchlist"
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                font.letterSpacing: 1
              }
              Text {
                width: parent.width
                text: "Choose services to personalize recommendations and pin Browse filters."
                textFormat: Text.PlainText
                color: root.secondary
                font.family: root.fontFamily
                font.pixelSize: root.readingSize
                wrapMode: Text.WordWrap
              }
              TextField {
                id: servicePickerSearch
                width: Math.min(parent.width, Style.space(560))
                foreground: root.foreground
                placeholderText: "Search apps and services"
                maximumLength: 80
              }
              Text {
                visible: root.service && Boolean(root.service.error)
                  && root.pendingServiceChoices === null
                width: parent.width
                text: root.service ? root.service.error : ""
                textFormat: Text.PlainText
                color: Color.urgent
                font.family: root.fontFamily
                font.pixelSize: root.supportingSize
                wrapMode: Text.WordWrap
              }
            }

            HelpScrollView {
              id: servicePickerScroll
              anchors.top: servicePickerHeader.bottom
              anchors.topMargin: Style.space(14)
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: servicePickerFooter.top
              anchors.bottomMargin: Style.space(12)
              clip: true
              contentWidth: availableWidth
              C.ScrollBar.horizontal.policy: C.ScrollBar.AlwaysOff

              Column {
                width: servicePickerScroll.availableWidth
                spacing: Style.space(16)

                Repeater {
                  model: root.serviceCategories()

                  Column {
                    id: serviceCategory
                    required property string modelData
                    width: parent.width
                    spacing: Style.space(7)

                    Text {
                      width: parent.width
                      text: serviceCategory.modelData.toUpperCase()
                      textFormat: Text.PlainText
                      color: root.secondary
                      font.family: root.fontFamily
                      font.pixelSize: root.supportingSize
                      font.bold: true
                      font.letterSpacing: 1.1
                    }

                    Grid {
                      id: serviceChoiceGrid
                      readonly property int gridColumns: width >= Style.space(1100) ? 3 : 2
                      readonly property real cardWidth: (width
                        - columnSpacing * (gridColumns - 1)) / gridColumns
                      width: parent.width
                      columns: gridColumns
                      columnSpacing: Style.space(8)
                      rowSpacing: Style.space(8)

                      Repeater {
                        model: root.servicesForCategory(serviceCategory.modelData)

                        ServiceChoiceCard {
                          required property var modelData
                          width: serviceChoiceGrid.cardWidth
                          serviceOption: modelData
                        }
                      }
                    }
                  }
                }

                Text {
                  visible: !root.serviceCategories().length
                  width: parent.width
                  text: root.service && root.service.activeAction === "quick-setup"
                    ? "Loading common apps and services..."
                    : "No apps or services match this search."
                  textFormat: Text.PlainText
                  horizontalAlignment: Text.AlignHCenter
                  color: root.secondary
                  font.family: root.fontFamily
                  font.pixelSize: root.readingSize
                }
              }
            }

            BorderSurface {
              id: servicePickerFooter
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              height: Style.space(62)
              radius: Style.cornerRadius
              color: root.faint

              Row {
                anchors.fill: parent
                anchors.margins: Style.space(10)
                spacing: Style.space(8)

                Text {
                  width: parent.width - skipServicesButton.width
                    - continueServicesButton.width - parent.spacing * 2
                  height: parent.height
                  verticalAlignment: Text.AlignVCenter
                  text: root.serviceDraftCount + " service"
                    + (root.serviceDraftCount === 1 ? "" : "s") + " selected"
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: root.readingSize
                  font.bold: true
                  elide: Text.ElideRight
                }
                Button {
                  id: skipServicesButton
                  text: "Cancel"
                  foreground: root.secondary
                  focusable: true
                  enabled: root.service && !root.service.busy
                  onClicked: root.cancelServicePicker()
                }
                Button {
                  id: continueServicesButton
                  text: root.pendingServiceChoices !== null ? "Saving..."
                    : "Save watchlist"
                  foreground: root.foreground
                  bordered: true
                  focusable: true
                  enabled: root.service && !root.service.busy
                  onClicked: root.finishServices(root.serviceDraft)
                }
              }
            }
          }

          Item {
            id: setupBrowsePage
            visible: root.setupStage === "browse" && !detailPrototypeLoader.active
            anchors.fill: parent

            Flow {
              id: workspaceTabs
              parent: workspaceHeader
              visible: !root.settingsOpen && !root.interestsOpen && root.setupStage === "browse"
                && root.service && root.service.cacheLoaded
              anchors.top: parent.top
              anchors.left: headerBrand.right
              anchors.leftMargin: Style.space(18)
              anchors.right: headerActions.left
              anchors.rightMargin: Style.space(12)
              spacing: Style.space(6)
              enabled: root.headerNavigationEnabled
              Button {
                id: browseViewButton
                visible: root.discoveryEnabled
                text: "Browse"
                foreground: root.foreground
                bordered: true
                focusable: true
                selected: root.workspaceView === "browse"
                Accessible.role: Accessible.RadioButton
                Accessible.name: "Browse plugins"
                Accessible.checkable: true
                Accessible.checked: selected
                Accessible.onPressAction: if (enabled) clicked()
                KeyNavigation.right: root.discoveryEnabled ? discoverViewButton : null
                onClicked: root.chooseWorkspace("browse")
              }
              Button {
                id: discoverViewButton
                objectName: "discoverViewButton"
                visible: root.discoveryEnabled
                enabled: root.discoveryEnabled
                text: "Discover" + (root.service && root.service.unreadMatches ? " (" + root.service.unreadMatches + ")" : "")
                foreground: root.foreground
                bordered: true
                focusable: true
                selected: root.workspaceView === "discover"
                Accessible.role: Accessible.RadioButton
                Accessible.name: "Discover ideas and matches, " + (root.service ? root.service.unreadMatches : 0) + " unread"
                Accessible.checkable: true
                Accessible.checked: selected
                Accessible.onPressAction: if (enabled) clicked()
                KeyNavigation.left: browseViewButton
                onClicked: root.chooseWorkspace("discover")
              }
              Button {
                visible: root.workspaceView === "browse" && !root.filtersExpanded
                text: "Setup & interests…"
                foreground: root.secondary
                focusable: true
                onClicked: root.openInterests(this)
              }
              Button {
                visible: root.setupSelectedCount > 0
                text: "Review batch install (" + root.setupSelectedCount + ")"
                foreground: root.foreground
                focusable: true
                onClicked: root.setupStage = "review"
              }
              Button {
                visible: root.service && root.service.batchItems && root.service.batchItems.length > 0
                text: root.updateBatch ? "Batch update progress" : "Batch install progress"
                foreground: root.foreground
                focusable: true
                onClicked: root.setupStage = "progress"
              }
            }

            Flow {
              id: discoverTabs
              visible: root.workspaceView === "discover"
              enabled: root.setupDetailInline || !setupDetailPanel.visible
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.right: root.setupDetailInline && setupDetailPanel.visible ? setupDetailPanel.left : parent.right
              spacing: Style.space(8)
              Button {
                id: ideasTabButton
                text: "Ideas"
                foreground: root.foreground
                bordered: true; focusable: true
                selected: root.discoverTab === "ideas"
                onClicked: root.chooseDiscoverTab("ideas")
                KeyNavigation.right: matchesTabButton
              }
              Button {
                id: matchesTabButton
                text: "Matches" + (root.service && root.service.unreadMatches ? " (" + root.service.unreadMatches + ")" : "")
                foreground: root.foreground
                bordered: true; focusable: true
                selected: root.discoverTab === "matches"
                onClicked: root.chooseDiscoverTab("matches")
                KeyNavigation.left: ideasTabButton
              }
              Button {
                id: discoverInterestsButton
                text: "Setup & interests…"
                foreground: root.secondary; focusable: true
                onClicked: root.openInterests(discoverInterestsButton)
              }
            }

            HelpScrollView {
              id: discoveryScroll
              visible: root.workspaceView === "discover" && root.discoverTab === "ideas"
              enabled: root.setupDetailInline || !setupDetailPanel.visible
              anchors.top: discoverTabs.bottom
              anchors.topMargin: Style.space(12)
              anchors.left: parent.left
              anchors.bottom: parent.bottom
              anchors.right: root.setupDetailInline && setupDetailPanel.visible ? setupDetailPanel.left : parent.right
              anchors.rightMargin: root.setupDetailInline && setupDetailPanel.visible ? Style.space(14) : 0
              clip: true
              contentWidth: availableWidth
              C.ScrollBar.horizontal.policy: C.ScrollBar.AlwaysOff
              Column {
                width: discoveryScroll.availableWidth
                spacing: Style.space(16)
                Text {
                  width: parent.width
                  text: "Three things you could try"
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                  wrapMode: Text.WordWrap
                }
                Text {
                  width: parent.width
                  text: "Pick something useful. Explore more when you're ready."
                  textFormat: Text.PlainText
                  color: root.secondary
                  font.family: root.fontFamily
                  font.pixelSize: root.readingSize
                  wrapMode: Text.WordWrap
                }
                Text {
                  visible: Boolean(text)
                  width: parent.width
                  text: root.service && root.service.discoveryBusy
                    ? (root.discoveryRows.length ? "Finding more ideas — your current picks are still here…" : "Finding a few ideas…")
                    : root.service && root.service.discoveryError
                      ? String(root.service.discoveryError) + (root.discoveryRows.length ? " Your saved picks are still available." : " Browse the cached catalog or try again.")
                      : !root.discoveryRows.length ? "No discovery picks are available yet. Browse the catalog or try again." : ""
                  textFormat: Text.PlainText
                  color: root.secondary
                  font.family: root.fontFamily
                  font.pixelSize: root.readingSize
                  wrapMode: Text.WordWrap
                }
                Grid {
                  id: discoveryGrid
                  width: parent.width
                  columns: width >= Style.space(900) ? 3 : 1
                  spacing: Style.space(12)
                  Repeater {
                    id: discoveryRepeater
                    model: root.sleeping ? [] : root.discoveryRows
                    SetupPluginCard {
                      required property var modelData
                      width: (discoveryGrid.width - discoveryGrid.spacing * (discoveryGrid.columns - 1)) / discoveryGrid.columns
                      pluginRow: modelData
                      discoveryCard: true
                    }
                  }
                }
                Flow {
                  width: parent.width
                  spacing: Style.space(8)
                  Button {
                    text: "Back"
                    foreground: root.foreground
                    bordered: true
                    focusable: true
                    enabled: root.service && root.service.discoveryCanGoBack && !root.service.discoveryBusy
                    onClicked: root.changeDiscovery(true)
                  }
                  Button {
                    text: root.discoveryRows.length ? "Show me another three" : "Try discovery again"
                    foreground: root.foreground
                    bordered: true
                    focusable: true
                    enabled: root.service && !root.service.discoveryBusy
                    onClicked: root.changeDiscovery(false)
                  }
                  Button {
                    text: "Browse all plugins"
                    foreground: root.foreground
                    focusable: true
                    onClicked: root.chooseWorkspace("browse")
                  }
                  Button {
                    text: "Setup & interests…"
                    foreground: root.secondary
                    focusable: true
                    enabled: root.service && !root.service.batchRunning
                    onClicked: root.openInterests(this)
                  }
                }
              }
            }

            HelpScrollView {
              id: matchesScroll
              visible: root.workspaceView === "discover" && root.discoverTab === "matches"
              enabled: root.setupDetailInline || !setupDetailPanel.visible
              anchors.top: discoverTabs.bottom
              anchors.topMargin: Style.space(12)
              anchors.left: parent.left
              anchors.bottom: parent.bottom
              anchors.right: root.setupDetailInline && setupDetailPanel.visible ? setupDetailPanel.left : parent.right
              anchors.rightMargin: root.setupDetailInline && setupDetailPanel.visible ? Style.space(14) : 0
              clip: true
              contentWidth: availableWidth
              C.ScrollBar.horizontal.policy: C.ScrollBar.AlwaysOff
              Column {
                width: matchesScroll.availableWidth
                spacing: Style.space(12)
                Text {
                  width: parent.width
                  text: "Matches from your saved interests"
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                  wrapMode: Text.WordWrap
                }
                Text {
                  width: parent.width
                  text: "Review a listing in the inspector. Only Mark reviewed or Mark all reviewed clears unread matches."
                  textFormat: Text.PlainText
                  color: root.secondary
                  font.family: root.fontFamily
                  font.pixelSize: root.readingSize
                  wrapMode: Text.WordWrap
                }
                Flow {
                  width: parent.width; spacing: Style.space(7)
                  Button {
                    text: "New matches (" + (root.service ? root.service.unreadMatches : 0) + ")"
                    selected: root.service && root.service.matchesUnreadOnly
                    foreground: root.foreground; bordered: true; focusable: true
                    onClicked: root.service.chooseMatches(true, 1)
                  }
                  Button {
                    text: "All matches"
                    selected: root.service && !root.service.matchesUnreadOnly
                    foreground: root.foreground; bordered: true; focusable: true
                    onClicked: root.service.chooseMatches(false, 1)
                  }
                  Button {
                    text: "Mark all reviewed"
                    enabled: root.service && root.service.unreadMatches > 0 && !root.service.matchesBusy
                    foreground: root.foreground; focusable: true
                    onClicked: root.service.reviewMatches([], true)
                  }
                  Button {
                    text: "Check cached matches"
                    enabled: root.service && !root.service.matchesBusy
                    foreground: root.secondary; focusable: true
                    onClicked: root.service.scheduleMatches(true)
                  }
                }
                Text {
                  width: parent.width
                  text: root.service && root.service.matchesBusy ? "Checking cached matches…"
                    : root.service && root.service.matchesError ? root.service.matchesError
                    : root.service && root.service.matches.partial ? "Partial results: some cached README text is unavailable. Matches update as the index completes."
                    : "Last checked: " + root.timeLabel(root.service ? root.service.matches.lastCheckedAt : 0)
                  textFormat: Text.PlainText
                  color: root.service && root.service.matchesError ? Color.urgent : root.secondary
                  font.family: root.fontFamily
                  font.pixelSize: root.supportingSize
                  wrapMode: Text.WordWrap
                }
                Repeater {
                  id: matchesRepeater
                  model: root.sleeping ? [] : root.matchRows
                  Column {
                    id: matchItem
                    required property var modelData
                    property alias reviewButton: matchReviewButton
                    width: parent.width
                    spacing: Style.space(6)
                    SetupPluginCard { width: parent.width; pluginRow: matchItem.modelData; matchCard: true }
                    Text {
                      width: parent.width
                      text: (matchItem.modelData.unread ? "Unread · " : "Reviewed · ") + root.matchCause(matchItem.modelData)
                        + "\n" + root.matchReasons(matchItem.modelData)
                      textFormat: Text.PlainText
                      color: root.secondary
                      font.family: root.fontFamily
                      font.pixelSize: root.supportingSize
                      wrapMode: Text.WordWrap
                    }
                    Flow {
                      width: parent.width; spacing: Style.space(7)
                      Button {
                        id: matchReviewButton
                        text: "Review listing"
                        foreground: root.foreground; bordered: true; focusable: true
                        onClicked: root.openSetupDetail(matchItem.modelData, matchReviewButton)
                      }
                      Button {
                        text: matchItem.modelData.unread ? "Mark reviewed" : "Reviewed"
                        enabled: matchItem.modelData.unread === true && root.service && !root.service.matchesBusy
                        foreground: root.secondary; focusable: true
                        onClicked: root.service.reviewMatches([String(matchItem.modelData.id)], false)
                      }
                    }
                    PanelSeparator { width: parent.width; foreground: root.foreground }
                  }
                }
                Text {
                  visible: !root.matchRows.length && root.service && !root.service.matchesBusy
                  width: parent.width
                  text: root.service && !(root.service.inputs.criteria || []).some(function(item) { return item.enabled !== false })
                    ? "No active saved interests yet. Add one in Setup & interests to start watching."
                    : root.service && root.service.matchesUnreadOnly ? "No new matches. Your interests remain saved; All matches includes reviewed listings."
                      : "No cached listings match your saved interests yet. Interests stay saved even with zero matches."
                  textFormat: Text.PlainText
                  color: root.secondary
                  font.family: root.fontFamily
                  font.pixelSize: root.readingSize
                  wrapMode: Text.WordWrap
                }
                Flow {
                  width: parent.width; spacing: Style.space(7)
                  Button {
                    text: "Previous"
                    enabled: root.service && root.service.matchesPage > 1 && !root.service.matchesBusy
                    foreground: root.foreground; bordered: true; focusable: true
                    onClicked: root.service.chooseMatches(root.service.matchesUnreadOnly, root.service.matchesPage - 1)
                  }
                  Text {
                    text: "Page " + (root.service ? root.service.matchesPage : 1) + " of " + (root.service ? root.service.matches.pageCount : 1)
                      + " · " + (root.service ? root.service.matches.total : 0) + " matches"
                    textFormat: Text.PlainText
                    color: root.secondary
                    font.family: root.fontFamily
                    font.pixelSize: root.readingSize
                  }
                  Button {
                    text: "Next"
                    enabled: root.service && root.service.matchesPage < root.service.matches.pageCount && !root.service.matchesBusy
                    foreground: root.foreground; bordered: true; focusable: true
                    onClicked: root.service.chooseMatches(root.service.matchesUnreadOnly, root.service.matchesPage + 1)
                  }
                }
              }
            }

            BorderSurface {
              id: setupFilterSidebar
              visible: root.workspaceView === "browse" && root.filtersExpanded
              enabled: root.setupDetailInline || !setupDetailPanel.visible
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.bottom: parent.bottom
              width: Math.min(Style.space(304), Math.max(Style.space(224), parent.width * 0.26))
              radius: Style.cornerRadius
              color: root.faint

              Row {
                id: sidebarHeading
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: Style.space(8)
                height: Style.space(38)
                spacing: Style.space(4)
                Text {
                  width: parent.width - sidebarCollapseButton.width - parent.spacing
                  height: parent.height
                  verticalAlignment: Text.AlignVCenter
                  text: "Filters"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: root.readingSize
                  font.bold: true
                }
                HeaderButton {
                  id: sidebarCollapseButton
                  iconKind: "collapse"
                  accessibleLabel: "Collapse filters"
                  onClicked: root.setFiltersExpanded(false)
                }
              }

              HelpScrollView {
                id: setupFilterScroll
                anchors.top: sidebarHeading.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: Style.space(12)
                anchors.topMargin: Style.space(4)
                clip: true
                contentWidth: availableWidth
                C.ScrollBar.horizontal.policy: C.ScrollBar.AlwaysOff

                Column {
                  id: setupSidebarContent
                  width: setupFilterScroll.availableWidth
                  spacing: Style.space(5)

                  FilterButton {
                    width: parent.width
                    text: "Browse all"
                    foreground: root.foreground
                    bordered: true
                    selected: !root.setupHasActiveFilters()
                    focusable: true
                    enabled: root.service && !root.service.queryBusy
                    onClicked: root.browseAll()
                  }

                  PanelSeparator { width: parent.width; foreground: root.foreground }
                  Text {
                    objectName: "serviceShortcutsHeading"
                    width: parent.width
                    text: "SELECT A FILTER"
                    textFormat: Text.PlainText
                    color: root.secondary
                    font.family: root.fontFamily
                    font.pixelSize: root.supportingSize
                    font.bold: true
                    font.letterSpacing: 1.1
                  }
                  Text {
                    visible: root.savedServiceOptions().length === 0
                    width: parent.width
                    text: root.service && root.service.interestsDirty ? "No interests in this draft." : "No saved interests."
                    textFormat: Text.PlainText
                    color: root.secondary
                    font.family: root.fontFamily
                    font.pixelSize: root.supportingSize
                    wrapMode: Text.WordWrap
                  }
                  Repeater {
                    objectName: "serviceShortcuts"
                    model: root.savedServiceOptions()

                    FilterButton {
                      required property var modelData
                      width: setupSidebarContent.width
                      text: Presentation.countLabel(modelData.name || modelData.id, modelData.total,
                        Boolean(root.service && root.service.cacheLoaded))
                      foreground: root.foreground
                      selected: root.setupServiceActive(modelData.id)
                      focusable: true
                      enabled: root.service && !root.service.queryBusy
                      onClicked: root.toggleSetupService(modelData.id)
                    }
                  }
                  Text {
                    objectName: "serviceShortcutsSaveNotice"
                    visible: root.service && root.service.interestsDirty
                    width: parent.width
                    text: "Unsaved changes. Save to update recommendations."
                    textFormat: Text.PlainText
                    color: Color.accent
                    font.family: root.fontFamily
                    font.pixelSize: root.supportingSize
                    wrapMode: Text.WordWrap
                  }
                  FilterButton {
                    objectName: "saveShortcutChanges"
                    visible: root.service && root.service.interestsDirty
                    width: parent.width
                    text: root.shortcutSaveNeedsReview() ? "Review changes…" : "Save interests"
                    foreground: root.foreground
                    bordered: true
                    focusable: true
                    enabled: root.service && !root.service.busy
                    opacity: enabled ? 1 : 0.45
                    onClicked: {
                      if (root.shortcutSaveNeedsReview()) {
                        root.service.interestsSection = "added"
                        root.openInterests(this)
                      } else {
                        // An untouched New interest form contains nothing to
                        // apply and should not block saving existing removals.
                        if (root.service.interestEditor) {
                          root.service.interestEditor = null
                          root.service.clearInterestPreview()
                        }
                        root.service.saveInterests()
                      }
                    }
                  }
                  Text {
                    visible: root.service && root.service.interestsDirty && Boolean(root.service.interestsError)
                    width: parent.width
                    text: root.service ? root.service.interestsError : ""
                    textFormat: Text.PlainText
                    color: Color.urgent
                    font.family: root.fontFamily
                    font.pixelSize: root.supportingSize
                    wrapMode: Text.WordWrap
                  }
                  FilterButton {
                    width: parent.width
                    text: "Setup & interests…"
                    foreground: root.foreground
                    bordered: true
                    focusable: true
                    enabled: root.service && !root.service.batchRunning
                    onClicked: root.openInterests(this)
                  }

                  PanelSeparator { width: parent.width; foreground: root.foreground }
                  Text {
                    width: parent.width
                    text: "STATUS"
                    textFormat: Text.PlainText
                    color: root.secondary
                    font.family: root.fontFamily
                    font.pixelSize: root.supportingSize
                    font.bold: true
                    font.letterSpacing: 1.1
                  }
                  FilterButton {
                    width: parent.width
                    text: "Any status"
                    foreground: root.foreground
                    focusable: true
                    selected: root.service && root.service.setupInstallFilter === "all"
                    enabled: root.service && !root.service.queryBusy
                    onClicked: root.chooseSetupFilters("all", "")
                  }
                  FilterButton {
                    width: parent.width
                    text: Presentation.countLabel("Installed", root.setupFilterCount("installed"),
                      Boolean(root.service && root.service.inventoryReady))
                    foreground: root.foreground
                    focusable: true
                    selected: root.service && root.service.setupInstallFilter === "installed"
                    enabled: root.service && !root.service.queryBusy
                    onClicked: root.chooseSetupFilters("installed", "")
                  }
                  FilterButton {
                    width: parent.width
                    text: Presentation.countLabel("Available", root.setupFilterCount("available"),
                      Boolean(root.service && root.service.inventoryReady))
                    foreground: root.foreground
                    focusable: true
                    selected: root.service && root.service.setupInstallFilter === "available"
                    enabled: root.service && !root.service.queryBusy
                    onClicked: root.chooseSetupFilters("available", "")
                  }

                  PanelSeparator { width: parent.width; foreground: root.foreground }
                  Text {
                    width: parent.width
                    text: "SOURCE"
                    textFormat: Text.PlainText
                    color: root.secondary
                    font.family: root.fontFamily
                    font.pixelSize: root.supportingSize
                    font.bold: true
                    font.letterSpacing: 1.1
                  }
                  FilterButton {
                    width: parent.width
                    text: "Any source"
                    foreground: root.foreground
                    focusable: true
                    selected: root.service && root.service.setupPartyFilter === "all"
                    enabled: root.service && !root.service.queryBusy
                    onClicked: root.chooseSetupFilters("", "all")
                  }
                  FilterButton {
                    width: parent.width
                    text: Presentation.countLabel("First party", root.setupFilterCount("firstParty"),
                      Boolean(root.service && root.service.inventoryReady))
                    foreground: root.foreground
                    focusable: true
                    selected: root.service && root.service.setupPartyFilter === "first-party"
                    enabled: root.service && !root.service.queryBusy
                    onClicked: root.chooseSetupFilters("", "first-party")
                  }
                  FilterButton {
                    width: parent.width
                    text: Presentation.countLabel("Third party", root.setupFilterCount("thirdParty"),
                      Boolean(root.service && root.service.inventoryReady))
                    foreground: root.foreground
                    focusable: true
                    selected: root.service && root.service.setupPartyFilter === "third-party"
                    enabled: root.service && !root.service.queryBusy
                    onClicked: root.chooseSetupFilters("", "third-party")
                  }

                  PanelSeparator { width: parent.width; foreground: root.foreground }
                  Text {
                    width: parent.width
                    text: "VERIFICATION"
                    textFormat: Text.PlainText
                    color: root.secondary
                    font.family: root.fontFamily
                    font.pixelSize: root.supportingSize
                    font.bold: true
                    font.letterSpacing: 1.1
                  }
                  Repeater {
                    model: [
                      { value: "all", label: "All" },
                      { value: "verified", label: "Verified" },
                      { value: "unverified", label: "Unverified" }
                    ]
                    FilterButton {
                      required property var modelData
                      width: setupSidebarContent.width
                      text: modelData.label
                      foreground: root.foreground
                      focusable: true
                      selected: root.service && BrowseState.verificationFilter(root.service.setupVerification) === modelData.value
                      enabled: root.service && !root.service.queryBusy
                      onClicked: root.chooseVerification(modelData.value)
                    }
                  }

                  PanelSeparator { width: parent.width; foreground: root.foreground }
                  Text {
                    width: parent.width
                    text: "MARKETPLACE CATEGORY"
                    wrapMode: Text.WordWrap
                    textFormat: Text.PlainText
                    color: root.secondary
                    font.family: root.fontFamily
                    font.pixelSize: root.supportingSize
                    font.bold: true
                    font.letterSpacing: 1.1
                  }
                  Dropdown {
                    id: setupCategoryPicker
                    width: parent.width
                    label: "Marketplace category"
                    showLabel: false
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    options: root.categoryOptions
                    enabled: root.service && !root.service.queryBusy
                    onChanged: function(value) { root.chooseSetupCategory(value) }
                    Binding {
                      target: setupCategoryPicker
                      property: "value"
                      value: root.service ? root.service.setupCategory : ""
                    }
                  }

                  PanelSeparator { width: parent.width; foreground: root.foreground }
                  Text {
                    width: parent.width
                    text: "PURPOSES"
                    textFormat: Text.PlainText
                    color: root.secondary
                    font.family: root.fontFamily
                    font.pixelSize: root.supportingSize
                    font.bold: true
                    font.letterSpacing: 1.1
                  }
                  FilterButton {
                    width: parent.width
                    text: "All purposes"
                    foreground: root.foreground
                    focusable: true
                    selected: root.service && !root.service.setupGroup
                    enabled: root.service && !root.service.queryBusy
                    onClicked: root.requestSetup(
                      setupSearchField.text.trim(), "", root.service.setupSort, 1)
                  }
                  Repeater {
                    model: root.setupGroups

                    FilterButton {
                      required property var modelData
                      objectName: "purposeFilter." + modelData.id
                      visible: Number(modelData.total || 0) > 0
                        || (root.service && root.service.setupGroup === modelData.id)
                      width: setupSidebarContent.width
                      text: Presentation.countLabel(modelData.label || modelData.id, modelData.total)
                      foreground: root.foreground
                      selected: root.service && root.service.setupGroup === modelData.id
                      focusable: true
                      enabled: root.service && !root.service.queryBusy
                      onClicked: root.requestSetup(
                        setupSearchField.text.trim(), modelData.id,
                        root.service.setupSort, 1)
                    }
                  }

                  PanelSeparator { width: parent.width; foreground: root.foreground }
                  Text {
                    width: parent.width
                    text: "SYSTEM FIT"
                    textFormat: Text.PlainText
                    color: root.secondary
                    font.family: root.fontFamily
                    font.pixelSize: root.supportingSize
                    font.bold: true
                    font.letterSpacing: 1.1
                  }
                  FilterButton {
                    width: parent.width
                    text: Presentation.countLabel("Hardware match", root.service ? root.service.setupHardwareMatchCount : null,
                      Boolean(root.service && root.service.hasAnalyzed))
                    foreground: root.foreground
                    selected: root.service && root.service.setupHardwareOnly
                    focusable: true
                    enabled: root.service && !root.service.queryBusy
                    onClicked: root.chooseSetupHardware(
                      !(root.service && root.service.setupHardwareOnly))
                  }
                }
              }
            }

            Item {
              id: setupCatalogPane
              visible: root.workspaceView === "browse"
              enabled: root.setupDetailInline || !setupDetailPanel.visible
              anchors.top: parent.top
              anchors.left: root.filtersExpanded ? setupFilterSidebar.right : parent.left
              anchors.leftMargin: root.filtersExpanded ? Style.space(12) : 0
              anchors.bottom: parent.bottom
              anchors.right: root.setupDetailInline && setupDetailPanel.visible
                ? setupDetailPanel.left : parent.right
              anchors.rightMargin: root.setupDetailInline && setupDetailPanel.visible
                ? Style.space(14) : 0

              Column {
              id: setupBrowseControls
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.right: parent.right
              spacing: Style.space(7)

              Text {
                visible: root.service && root.service.startupActivity
                  && root.service.startupActivity.inventory.state === "error" && !root.canManagePlugins
                width: parent.width
                text: "Plugin checks need attention. Open Background activity in More actions to retry."
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: root.secondary
                font.family: root.fontFamily
                font.pixelSize: root.supportingSize
              }

              Row {
                id: searchSortRow
                width: parent.width
                height: Math.max(Style.space(42), setupSearchField.implicitHeight)
                spacing: Style.space(8)

                TextField {
                  id: setupSearchField
                  objectName: "browseSearchField"
                  height: searchSortRow.height
                  width: parent.width - setupSortPicker.width - parent.spacing
                  foreground: root.foreground
                  placeholderText: "Search plugins"
                  Accessible.description: "Tab switches to plugins. Control+Down explores filters with arrows. F6 focuses the toolbar."
                  maximumLength: 160
                  enabled: root.service
                  onTextEdited: root.editSetupSearch()
                  onAccepted: root.requestSetup(
                    text.trim(), root.service ? root.service.setupGroup : "",
                    root.service ? root.service.setupSort : "likes", 1)
                }
                Dropdown {
                  id: setupSortPicker
                  objectName: "browseSortPicker"
                  rowHeight: searchSortRow.height
                  height: searchSortRow.height
                  label: "Sort plugins"
                  width: Style.space(210)
                  showLabel: false
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  options: (setupSearchField.text.trim() ? [{value:"relevance", label:"Best match"}] : []).concat([
                    { value: "recommended", label: "Recommended" },
                    { value: "stars", label: "Most starred" },
                    { value: "fit", label: "Hardware fit" },
                    { value: "name", label: "A-Z" },
                    { value: "added", label: "Recently added" },
                    { value: "likes", label: "Most liked" },
                    { value: "activity", label: "Recent activity" },
                    { value: "views", label: "Most viewed" },
                    { value: "copies", label: "Most copied" }
                  ])
                  enabled: root.service
                  onChanged: function(value) {
                    root.chooseSetupSort(value)
                  }
                  Binding {
                    target: setupSortPicker
                    property: "value"
                    value: root.service ? root.service.setupSort : "likes"
                  }
                }
              }

              Text {
                objectName: "partialSearchStatus"
                visible: root.service && root.service.setupSearch.active && root.service.setupSearch.mode === "partial"
                width: parent.width
                text: "Partial matches · no plugins matched all search terms."
                textFormat: Text.PlainText
                color: root.secondary
                font.family: root.fontFamily
                font.pixelSize: root.supportingSize
                wrapMode: Text.WordWrap
              }
              Button {
                id: searchSuggestion
                objectName: "searchSuggestion"
                visible: root.service && root.service.setupSearch.suggestion !== null
                text: root.service && root.service.setupSearch.suggestion
                  ? root.service.setupSearch.suggestion.label : ""
                foreground: root.foreground
                focusable: true
                onClicked: root.acceptSearchSuggestion()
              }

              Item {
                id: groupingControls
                width: parent.width
                readonly property bool controlsStacked: width < groupingButtons.width + densityButtons.width + Style.space(12)
                readonly property bool countFits: width >= groupingButtons.width + densityButtons.width
                  + resultCount.implicitWidth + Style.space(24)
                readonly property bool countBesideViews: controlsStacked
                  && width >= densityButtons.width + resultCount.implicitWidth + Style.space(12)
                readonly property real rowHeight: controlsStacked ? groupingButtons.height + densityButtons.height + Style.space(4)
                  : Math.max(groupingButtons.height, densityButtons.height)
                height: rowHeight
                  + (countFits || countBesideViews ? 0 : resultCount.height + Style.space(4))

                Row {
                id: groupingButtons
                anchors.left: parent.left
                y: groupingControls.controlsStacked ? 0 : (groupingControls.rowHeight - height) / 2
                spacing: Style.space(6)
                Button {
                  id: filtersToggle
                  visible: !root.filtersExpanded
                  text: "Filters"
                  foreground: root.foreground
                  bordered: true
                  focusable: true
                  Accessible.name: "Expand filters"
                  onClicked: root.setFiltersExpanded(true)
                }
                Button {
                  id: noGroupingButton
                  text: "No grouping"
                  foreground: root.foreground
                  bordered: true
                  focusable: true
                  selected: root.normalizedGrouping(root.service ? root.service.setupGrouping : "none") === "none"
                  enabled: root.service && !root.service.queryBusy
                  Accessible.role: Accessible.RadioButton
                  Accessible.name: "No grouping"
                  Accessible.checkable: true
                  Accessible.checked: selected
                  Accessible.onPressAction: clicked()
                  onClicked: root.chooseGrouping("none")
                  KeyNavigation.right: categoryGroupingButton
                }
                Button {
                  id: categoryGroupingButton
                  text: "Group by category"
                  foreground: root.foreground
                  bordered: true
                  focusable: true
                  selected: root.service && root.service.setupGrouping === "category"
                  enabled: root.service && !root.service.queryBusy
                  Accessible.role: Accessible.RadioButton
                  Accessible.name: text
                  Accessible.checkable: true
                  Accessible.checked: selected
                  Accessible.onPressAction: clicked()
                  onClicked: root.chooseGrouping("category")
                  KeyNavigation.left: noGroupingButton
                }
                }
                Row {
                  id: densityButtons
                  anchors.right: parent.right
                  y: groupingControls.controlsStacked ? groupingButtons.height + Style.space(4) : 0
                  spacing: Style.space(4)
                  Repeater {
                    id: densityRepeater
                    model: Presentation.viewModes()
                    DensityButton {
                      required property string modelData
                      mode: modelData
                    }
                  }
                }
                Text {
                  id: resultCount
                  x: groupingControls.countFits ? groupingButtons.width + Style.space(10) : 0
                  y: groupingControls.countFits ? (groupingControls.rowHeight - height) / 2
                    : groupingControls.countBesideViews ? densityButtons.y + (densityButtons.height - height) / 2
                      : groupingControls.rowHeight + Style.space(4)
                  height: noGroupingButton.height
                  verticalAlignment: Text.AlignVCenter
                  text: root.service && (root.service.activeAction === "quick-setup" || root.service.pendingSetup)
                    ? "Searching…" : String(root.service ? root.service.setupTotal : 0) + " plugins"
                  color: root.secondary
                  font.family: root.fontFamily
                  font.pixelSize: root.supportingSize
                }
              }

              Text {
                width: parent.width
                visible: Boolean(text)
                text: root.service ? String(root.service.densitySaveError || "") : ""
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: Color.urgent
                font.family: root.fontFamily
                font.pixelSize: root.supportingSize
              }

              HelpScrollView {
                id: setupActiveFilters
                contentWidth: activeFilterRow.implicitWidth
                visible: root.setupHasActiveFilters()
                width: parent.width
                height: visible ? Style.space(32) : 0
                clip: true
                C.ScrollBar.vertical.policy: C.ScrollBar.AlwaysOff
                C.ScrollBar.horizontal.policy: C.ScrollBar.AsNeeded

                Row {
                  id: activeFilterRow
                  height: Style.space(30)
                  spacing: Style.space(6)

                  Repeater {
                    model: root.service && Array.isArray(root.service.setupServiceIds)
                      ? root.service.setupServiceIds : []

                    Button {
                      required property string modelData
                      readonly property var option: root.serviceOption(modelData)
                      text: (modelData.indexOf("interest-") === 0 ? "Interest: " : "Service: ")
                        + (option ? String(option.name || modelData) : modelData) + "  x"
                      foreground: root.foreground
                      bordered: true
                      focusable: true
                      enabled: root.service && !root.service.queryBusy
                      onClicked: root.toggleSetupService(modelData)
                    }
                  }
                  Button {
                    visible: root.service && root.service.setupInstallFilter !== "all"
                    text: (root.service && root.service.setupInstallFilter === "installed"
                      ? "Installed" : "Available") + "  x"
                    foreground: root.foreground
                    bordered: true
                    focusable: true
                    onClicked: root.chooseSetupFilters("all", "")
                  }
                  Button {
                    visible: root.service && root.service.setupPartyFilter !== "all"
                    text: (root.service && root.service.setupPartyFilter === "first-party"
                      ? "First party" : "Third party") + "  x"
                    foreground: root.foreground
                    bordered: true
                    focusable: true
                    onClicked: root.chooseSetupFilters("", "all")
                  }
                  Button {
                    visible: root.service && Boolean(root.service.setupGroup)
                    text: "Purpose: "
                      + root.setupGroupLabel(root.service ? root.service.setupGroup : "") + "  x"
                    foreground: root.foreground
                    bordered: true
                    focusable: true
                    onClicked: root.requestSetup(
                      setupSearchField.text.trim(), "", root.service.setupSort, 1)
                  }
                  Button {
                    visible: root.service && Boolean(root.service.setupCategory)
                    text: "Category: "
                      + String(root.service ? root.service.setupCategory : "") + "  x"
                    foreground: root.foreground
                    bordered: true
                    focusable: true
                    onClicked: root.chooseSetupCategory("")
                  }
                  Button {
                    visible: root.service && BrowseState.verificationFilter(root.service.setupVerification) !== "all"
                    text: (root.service && root.service.setupVerification === "verified" ? "Verified" : "Unverified") + "  x"
                    foreground: root.foreground
                    bordered: true
                    focusable: true
                    enabled: root.service && !root.service.queryBusy
                    onClicked: root.chooseVerification("all")
                  }
                  Button {
                    visible: root.service && root.service.setupHardwareOnly
                    text: "Hardware match  x"
                    foreground: root.foreground
                    bordered: true
                    focusable: true
                    onClicked: root.chooseSetupHardware(false)
                  }
                  Button {
                    text: "Clear all"
                    foreground: root.secondary
                    focusable: true
                    onClicked: root.browseAll()
                  }
                }
              }

              BorderSurface {
                visible: root.service
                  && Boolean(root.service.error)
                width: parent.width
                implicitHeight: setupStatusMessage.implicitHeight + Style.space(14)
                radius: Style.space(7)
                color: root.service && root.service.error
                  ? Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.09)
                  : root.faint

                Text {
                  id: setupStatusMessage
                  anchors.fill: parent
                  anchors.margins: Style.space(7)
                  text: root.statusText()
                  textFormat: Text.PlainText
                  color: root.service && root.service.error ? Color.urgent : root.secondary
                  font.family: root.fontFamily
                  font.pixelSize: root.supportingSize
                  wrapMode: Text.WordWrap
                }
              }

            }

            HelpScrollView {
              id: setupCatalogScroll
              objectName: "browseResultsScroll"
              anchors.top: setupBrowseControls.bottom
              anchors.topMargin: Style.space(10)
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: setupSelectionBar.visible ? setupSelectionBar.top : parent.bottom
              anchors.bottomMargin: setupSelectionBar.visible ? Style.space(10) : 0
              clip: true
              C.ScrollBar.horizontal.policy: C.ScrollBar.AlwaysOff

              Column {
                id: setupGroupsColumn
                width: setupCatalogScroll.availableWidth
                spacing: Style.space(14)
                onPositioningComplete: root.scheduleThumbnailDemand()

                Repeater {
                  id: setupGroupRepeater
                  model: root.sleeping ? [] : root.visibleSetupGroups()

                  Column {
                    id: setupGroupCard
                    onPositioningComplete: root.scheduleThumbnailDemand()
                    required property var modelData
                    readonly property var groupRows: root.setupRowsForGroup(modelData.id)
                    function cards() {
                      var output = []
                      for (var c = 0; c < setupCardRepeater.count; c++) {
                        var card = setupCardRepeater.itemAt(c)
                        if (card && card.visible) output.push(card)
                      }
                      return output
                    }
                    function relayout() {
                      var rows = cards()
                      for (var c = 0; c < rows.length; c++) rows[c].relayoutContent()
                      setupCandidateGrid.forceLayout()
                      setupGroupCard.forceLayout()
                    }
                    function focusCard(identity) {
                      for (var c = 0; c < setupCardRepeater.count; c++) {
                        var card = setupCardRepeater.itemAt(c)
                        if (card && String(card.pluginRow.id) === identity && card.visible) {
                          root.focusCardInView(card, setupCatalogScroll)
                          return true
                        }
                      }
                      return false
                    }
                    function visibleThumbnailRows() {
                      var rows = []
                      for (var i = 0; i < setupCardRepeater.count; i++) {
                        var card = setupCardRepeater.itemAt(i)
                        if (!card) continue
                        var point = card.mapToItem(setupCatalogScroll, 0, 0)
                        if (point.y + card.height > -100
                            && point.y < setupCatalogScroll.height + 100)
                          rows.push(card.pluginRow)
                      }
                      return rows
                    }
                    visible: groupRows.length > 0
                    width: parent.width
                    spacing: Style.space(7)

                    Row {
                      visible: root.service && root.service.setupAppliedGrouping === "category"
                      width: parent.width
                      height: visible ? Style.space(34) : 0
                      spacing: Style.space(8)

                      Text {
                        width: parent.width
                        height: parent.height
                        verticalAlignment: Text.AlignVCenter
                        objectName: "browseGroupHeading"
                        text: Presentation.countLabel(String(setupGroupCard.modelData.label || "Other").toUpperCase(), setupGroupCard.modelData.total)
                        textFormat: Text.PlainText
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: root.readingSize
                        font.bold: true
                        font.letterSpacing: 0.8
                        elide: Text.ElideRight
                      }
                    }

                    Grid {
                      id: setupCandidateGrid
                      // Nested reflow can change which card tails intersect the
                      // viewport without changing this grid's total height.
                      onPositioningComplete: root.scheduleThumbnailDemand()
                      readonly property int gridColumns: root.browseDensity === "list" ? 1
                        : Presentation.cardColumns(width, root.minimumBrowseCardWidth, columnSpacing)
                      readonly property real cardWidth: (width
                        - columnSpacing * (gridColumns - 1)) / gridColumns
                      width: setupGroupCard.width
                      columns: gridColumns
                      columnSpacing: Style.space(root.densityProfile.gridGap)
                      rowSpacing: Style.space(root.densityProfile.gridGap)

                      Repeater {
                        id: setupCardRepeater
                        model: setupGroupCard.groupRows

                        SetupPluginCard {
                          required property var modelData
                          width: setupCandidateGrid.cardWidth
                          pluginRow: modelData
                        }
                      }
                    }
                  }
                }

                Row {
                  visible: root.service && !root.service.setupOverview
                    && root.service.setupPageCount > 1
                  width: parent.width
                  height: Style.space(38)
                  spacing: Style.space(8)

                  Button {
                    text: "Previous"
                    objectName: "browsePreviousPage"
                    foreground: root.foreground
                    bordered: true
                    focusable: true
                    enabled: root.service && !root.service.queryBusy && root.service.setupPage > 1
                    onClicked: root.changeSetupPage(root.service.setupPage - 1)
                  }
                  Text {
                    height: parent.height
                    verticalAlignment: Text.AlignVCenter
                    text: "Page " + Number(root.service ? root.service.setupPage : 1)
                      + " of " + Number(root.service ? root.service.setupPageCount : 1)
                    textFormat: Text.PlainText
                    color: root.secondary
                    font.family: root.fontFamily
                    font.pixelSize: root.supportingSize
                  }
                  Button {
                    text: "Next"
                    objectName: "browseNextPage"
                    foreground: root.foreground
                    bordered: true
                    focusable: true
                    enabled: root.service && !root.service.queryBusy
                      && root.service.setupPage < root.service.setupPageCount
                    onClicked: root.changeSetupPage(root.service.setupPage + 1)
                  }
                }

                Text {
                  visible: root.service && root.service.activeAction !== "quick-setup"
                    && !root.service.pendingSetup
                    && !root.setupRows.length
                  width: parent.width
                  text: root.setupHasActiveFilters()
                    ? "No plugins match these filters. Clear filters or broaden the search."
                    : "No plugins are available in the local inventory or marketplace catalog."
                  textFormat: Text.PlainText
                  horizontalAlignment: Text.AlignHCenter
                  color: root.secondary
                  font.family: root.fontFamily
                  font.pixelSize: root.readingSize
                }
              }
            }

              BorderSurface {
              id: setupSelectionBar
              visible: root.setupSelectedCount > 0
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              height: Style.space(58)
              radius: Style.cornerRadius
              color: Style.selectedFillFor(root.foreground, Color.accent)

              Row {
                anchors.fill: parent
                anchors.margins: Style.space(10)
                spacing: Style.space(8)

                Text {
                  width: parent.width - reviewSelectionButton.width - clearSelectionButton.width
                    - parent.spacing * 2
                  height: parent.height
                  verticalAlignment: Text.AlignVCenter
                  text: root.setupSelectedCount + " plugin"
                    + (root.setupSelectedCount === 1 ? "" : "s") + " selected"
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: root.readingSize
                  font.bold: true
                  elide: Text.ElideRight
                }
                Button {
                  id: clearSelectionButton
                  text: "Clear"
                  foreground: root.secondary
                  focusable: true
                  onClicked: root.service.clearSetupSelection()
                }
                Button {
                  id: reviewSelectionButton
                  text: "Review batch install >"
                  foreground: root.foreground
                  bordered: true
                  focusable: true
                  onClicked: root.setupStage = "review"
                }
              }
              }
            }

            Rectangle {
              visible: setupDetailPanel.visible && !root.setupDetailInline
              anchors.fill: parent
              color: Qt.rgba(0, 0, 0, 0.58)
              z: 20

              MouseArea {
                anchors.fill: parent
                onClicked: root.closeSetupDetail()
              }
            }

            SetupDetailPanel {
              id: setupDetailPanel
              parent: quickSetupPage
              visible: root.setupDetailRow !== null && ["browse", "updates"].indexOf(root.setupStage) >= 0
              pluginRow: root.setupDetailRow
              width: parent.width
              anchors.top: parent.top
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              z: 21
            }
          }

          Loader {
            id: detailPrototypeLoader
            objectName: "detailPrototypeLoader"
            anchors.fill: parent
            active: root.detailPrototypeSession && root.detailPrototypeOpen && root.opened
              && !root.settingsOpen && !root.interestsOpen
            visible: active
            source: active ? "../demo/DetailPrototype.qml" : ""
            onLoaded: {
              item.initialState = String(Quickshell.env("OUTFIT_DETAIL_STATE") || Quickshell.env("OMAFIT_DETAIL_STATE") || "available")
              item.backLabel = root.workspaceView === "discover" ? "Back to Discover" : "Back to Browse"
              item.takeFocus()
            }
          }
          Connections {
            target: detailPrototypeLoader.item
            function onBackRequested() {
              root.detailPrototypeOpen = false
              Qt.callLater(function() {
                if (root.detailPrototypeInvoker && root.detailPrototypeInvoker.visible)
                  root.focusCardInView(root.detailPrototypeInvoker, root.currentScroll())
                else root.focusWorkspace()
              })
            }
          }

          Item {
            id: setupReviewPage
            visible: root.setupStage === "review"
            anchors.fill: parent

            Row {
              id: setupReviewHeader
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.right: parent.right
              height: Style.space(44)
              spacing: Style.space(8)

              Button {
                text: "< Keep choosing"
                foreground: root.foreground
                bordered: true
                focusable: true
                onClicked: root.setupStage = "browse"
              }
              Text {
                height: parent.height
                verticalAlignment: Text.AlignVCenter
                text: "Review " + root.setupSelectedCount + " selected plugin"
                  + (root.setupSelectedCount === 1 ? "" : "s")
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: root.readingSize
                font.bold: true
              }
            }

            HelpScrollView {
              id: reviewScroll
              anchors.top: setupReviewHeader.bottom
              anchors.topMargin: Style.space(8)
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: setupReviewActions.top
              anchors.bottomMargin: Style.space(8)
              clip: true
              C.ScrollBar.horizontal.policy: C.ScrollBar.AlwaysOff

              Column {
                width: reviewScroll.availableWidth
                spacing: Style.space(8)

                Repeater {
                  model: root.sleeping ? [] : root.setupSelectedRows

                  BorderSurface {
                    id: setupReviewCard
                    required property var modelData
                    width: parent.width
                    height: setupReviewContent.implicitHeight + Style.space(20)
                    radius: Style.cornerRadius
                    color: root.faint

                    Column {
                      id: setupReviewContent
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      anchors.margins: Style.space(10)
                      spacing: Style.space(7)

                      Row {
                        width: parent.width
                        spacing: Style.space(8)

                        Column {
                          width: parent.width - removeSetupChoice.width - parent.spacing
                          spacing: Style.space(2)
                          Text {
                            width: parent.width
                            text: setupReviewCard.modelData.name
                            textFormat: Text.PlainText
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: root.readingSize
                            font.bold: true
                            elide: Text.ElideRight
                          }
                          Text {
                            width: parent.width
                            text: String(setupReviewCard.modelData.category || "Other")
                              + " / " + Number(setupReviewCard.modelData.stars || 0) + " stars / "
                              + String(setupReviewCard.modelData.reviewState || "not reviewed")
                            textFormat: Text.PlainText
                            color: root.secondary
                            font.family: root.fontFamily
                            font.pixelSize: root.supportingSize
                            elide: Text.ElideRight
                          }
                        }
                        Button {
                          id: removeSetupChoice
                          text: "Remove from batch"
                          foreground: Color.urgent
                          focusable: true
                          onClicked: root.service.setSetupSelected(setupReviewCard.modelData, false)
                        }
                      }

                      Row {
                        visible: setupReviewCard.modelData.barWidget === true
                        width: parent.width
                        spacing: Style.space(7)

                        Text {
                          height: parent.height
                          verticalAlignment: Text.AlignVCenter
                          text: "BAR LOCATION"
                          textFormat: Text.PlainText
                          color: root.secondary
                          font.family: root.fontFamily
                          font.pixelSize: root.supportingSize
                          font.bold: true
                        }
                        Repeater {
                          model: ["left", "center", "right"]
                          Button {
                            required property var modelData
                            text: String(modelData).charAt(0).toUpperCase() + String(modelData).slice(1)
                            foreground: root.foreground
                            bordered: true
                            selected: setupReviewCard.modelData.barSection === modelData
                            focusable: true
                            onClicked: root.service.updateSetupOption(
                              setupReviewCard.modelData.id, "barSection", modelData)
                          }
                        }
                      }

                      Toggle {
                        visible: setupReviewCard.modelData.exclusiveActivation === true
                        width: parent.width
                        label: "Activate this replacement"
                        description: "This plugin replaces a shared shell role. Leave off to install without switching."
                        checked: setupReviewCard.modelData.activate === true
                        foreground: root.foreground
                        accent: Color.accent
                        onClicked: root.service.updateSetupOption(
                          setupReviewCard.modelData.id, "activate",
                          setupReviewCard.modelData.activate !== true)
                      }

                      Text {
                        visible: Boolean(setupReviewCard.modelData.installNote)
                        width: parent.width
                        text: "ADDITIONAL REQUIREMENTS  " + setupReviewCard.modelData.installNote
                        textFormat: Text.PlainText
                        color: root.secondary
                        font.family: root.fontFamily
                        font.pixelSize: root.supportingSize
                        wrapMode: Text.WordWrap
                      }

                      Row {
                        width: parent.width
                        spacing: Style.space(8)
                        Text {
                          height: parent.height
                          verticalAlignment: Text.AlignVCenter
                          text: setupReviewCard.modelData.exclusiveActivation === true
                            && setupReviewCard.modelData.activate !== true
                            ? "INSTALL ONLY" : "INSTALL AND ENABLE"
                          textFormat: Text.PlainText
                          color: Color.accent
                          font.family: root.fontFamily
                          font.pixelSize: root.supportingSize
                          font.bold: true
                        }
                        Button {
                          visible: Boolean(setupReviewCard.modelData.snapshotUrl)
                          text: "Review source"
                          foreground: root.foreground
                          focusable: true
                          onClicked: root.service.openSource(setupReviewCard.modelData)
                        }
                      }
                    }
                  }
                }
              }
            }

            BorderSurface {
              id: setupReviewActions
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              height: Style.space(68)
              radius: Style.cornerRadius
              color: root.faint

              Row {
                anchors.fill: parent
                anchors.margins: Style.space(10)
                spacing: Style.space(8)

                Text {
                  width: parent.width - startSetupButton.width - parent.spacing
                  height: parent.height
                  verticalAlignment: Text.AlignVCenter
                  text: "Plugins run unsandboxed inside Omarchy. Review sources before continuing."
                  textFormat: Text.PlainText
                  color: root.secondary
                  font.family: root.fontFamily
                  font.pixelSize: root.supportingSize
                  wrapMode: Text.WordWrap
                }
                Button {
                  id: startSetupButton
                  text: "Install " + root.setupSelectedCount + " plugins"
                  foreground: root.foreground
                  bordered: true
                  focusable: true
                  enabled: root.setupSelectedCount > 0 && root.service
                    && !root.service.mutationBusy && !root.service.selfUpdateBusy && !root.service.batchRunning
                  onClicked: root.batchConfirmOpen = true
                }
              }
            }
          }

          Item {
            id: setupProgressPage
            visible: root.setupStage === "progress"
            anchors.fill: parent

            Column {
              id: setupProgressHeader
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.right: parent.right
              spacing: Style.space(7)

              Text {
                width: parent.width
                objectName: "batchProgressHeading"
                text: (root.updateBatch ? "BATCH UPDATE " : "BATCH INSTALL ") + (root.service && root.service.batchRunning
                  ? "IN PROGRESS"
                  : (root.batchStatusCount(["queued"]) > 0
                    ? "PAUSED"
                    : (root.batchStatusCount(["failed", "partial"]) > 0
                      ? "FINISHED WITH ATTENTION NEEDED" : "COMPLETE")))
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                font.letterSpacing: 1
              }
              Text {
                width: parent.width
                text: root.batchStatusCount(["completed", "partial", "failed", "skipped"])
                  + " of " + Number(root.service && root.service.batchItems
                    ? root.service.batchItems.length : 0) + " processed"
                textFormat: Text.PlainText
                color: root.secondary
                font.family: root.fontFamily
                font.pixelSize: root.readingSize
              }
              Rectangle {
                width: parent.width
                height: Style.space(6)
                radius: height / 2
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.1)
                Rectangle {
                  width: parent.width * root.batchStatusCount(
                    ["completed", "partial", "failed", "skipped"])
                    / Math.max(1, Number(root.service && root.service.batchItems
                      ? root.service.batchItems.length : 0))
                  height: parent.height
                  radius: height / 2
                  color: Color.accent
                }
              }
            }

            HelpScrollView {
              id: progressScroll
              anchors.top: setupProgressHeader.bottom
              anchors.topMargin: Style.space(12)
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: setupProgressActions.top
              anchors.bottomMargin: Style.space(8)
              clip: true
              C.ScrollBar.horizontal.policy: C.ScrollBar.AlwaysOff

              Column {
                width: progressScroll.availableWidth
                spacing: Style.space(8)

                Repeater {
                  model: !root.sleeping && root.service && Array.isArray(root.service.batchItems)
                    ? root.service.batchItems : []

                  BorderSurface {
                    id: setupProgressRow
                    required property var modelData
                    width: parent.width
                    height: setupProgressContent.implicitHeight + Style.space(18)
                    radius: Style.cornerRadius
                    color: modelData.status === "failed" || modelData.status === "partial"
                      ? Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.08) : root.faint

                    Column {
                      id: setupProgressContent
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      anchors.margins: Style.space(9)
                      spacing: Style.space(3)

                      Row {
                        width: parent.width
                        spacing: Style.space(8)
                        Text {
                          width: parent.width - setupProgressStatus.width - parent.spacing
                          text: String(setupProgressRow.modelData.name || setupProgressRow.modelData.id)
                          textFormat: Text.PlainText
                          color: root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: root.readingSize
                          font.bold: true
                          elide: Text.ElideRight
                        }
                        Text {
                          id: setupProgressStatus
                          text: root.updateBatch ? root.setupStatusLabel(setupProgressRow.modelData.status)
                            : root.service && (setupProgressRow.modelData.status === "running"
                            || setupProgressRow.modelData.status === "completed")
                            ? root.service.pluginOutcome(setupProgressRow.modelData.id) : root.setupStatusLabel(setupProgressRow.modelData.status)
                          textFormat: Text.PlainText
                          color: setupProgressRow.modelData.status === "failed"
                            || setupProgressRow.modelData.status === "partial"
                            ? Color.urgent : Color.accent
                          font.family: root.fontFamily
                          font.pixelSize: root.supportingSize
                          font.bold: true
                        }
                      }
                      Text {
                        width: parent.width
                        text: setupProgressRow.modelData.message || "Waiting"
                        textFormat: Text.PlainText
                        color: root.secondary
                        font.family: root.fontFamily
                        font.pixelSize: root.supportingSize
                        wrapMode: Text.WordWrap
                      }
                      Text {
                        visible: setupProgressRow.modelData.kind === "update"
                        width: parent.width
                        text: InspectorState.updateTransition(setupProgressRow.modelData)
                        textFormat: Text.PlainText
                        color: root.secondary
                        font.family: root.fontFamily
                        font.pixelSize: root.supportingSize
                        wrapMode: Text.Wrap
                      }
                      Text {
                        visible: Boolean(setupProgressRow.modelData.installedRevision)
                        width: parent.width
                        text: "Installed revision "
                          + String(setupProgressRow.modelData.installedRevision).slice(0, 10)
                          + (setupProgressRow.modelData.reviewedRevision
                            && setupProgressRow.modelData.reviewedRevision
                              !== setupProgressRow.modelData.installedRevision
                            ? " / reviewed "
                              + String(setupProgressRow.modelData.reviewedRevision).slice(0, 10)
                            : "")
                        textFormat: Text.PlainText
                        color: root.secondary
                        font.family: root.fontFamily
                        font.pixelSize: root.supportingSize
                        elide: Text.ElideRight
                      }
                    }
                  }
                }
              }
            }

            BorderSurface {
              id: setupProgressActions
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              height: Style.space(60)
              radius: Style.cornerRadius
              color: root.faint

              Row {
                anchors.centerIn: parent
                spacing: Style.space(8)

                Button {
                  visible: root.service && root.service.batchRunning
                  text: (root.service.batchStopRequested ? "Stopping after current " : "Stop after current ")
                    + (root.updateBatch ? "update" : "install")
                  foreground: Color.urgent
                  bordered: true
                  focusable: true
                  enabled: !root.service.batchStopRequested
                  onClicked: root.service.stopSetupBatch()
                }
                Button {
                  visible: root.service && !root.service.batchRunning
                    && root.batchStatusCount(["queued"]) > 0
                  text: root.updateBatch ? "Resume batch update" : "Resume batch install"
                  foreground: root.foreground
                  bordered: true
                  focusable: true
                  enabled: !root.service.mutationActive && !root.service.mutationQueue.length
                    && !root.service.hasCheckingOperations() && !root.service.selfUpdateBusy
                    && (!root.updateBatch || root.updatesIdle)
                  onClicked: root.service.resumeSetupBatch()
                }
                Button {
                  visible: root.service && !root.service.batchRunning
                    && root.batchStatusCount(["failed", "partial"]) > 0
                  text: root.updateBatch ? "Retry failed updates" : "Retry failed installs"
                  foreground: root.foreground
                  bordered: true
                  focusable: true
                  enabled: !root.service.mutationActive && !root.service.mutationQueue.length
                    && !root.service.hasCheckingOperations() && !root.service.selfUpdateBusy
                    && (!root.updateBatch || root.updatesIdle)
                  onClicked: root.service.retrySetupBatch()
                }
                Button {
                  visible: root.service && !root.service.batchRunning
                  text: "Back to " + (root.updateBatch ? "Updates" : root.workspaceView === "discover" ? "Discover" : "Browse")
                  objectName: "batchBack"
                  foreground: root.foreground
                  focusable: true
                  enabled: !root.service.mutationActive && !root.service.mutationQueue.length
                    && !root.service.hasCheckingOperations()
                  onClicked: {
                    var updates = root.updateBatch
                    if (root.service.resetSetupBatch()) {
                      root.setupStage = updates ? "updates" : "browse"
                      if (!updates) root.queueCurrentSetup()
                    }
                  }
                }
              }
            }
          }
        }
      }

      C.Popup {
        id: updateReview
        objectName: "updateReview"
        parent: focusScope
        popupType: C.Popup.Item
        visible: root.updateReviewOpen
        x: (parent.width - width) / 2
        y: (parent.height - height) / 2
        width: Math.min(Style.space(640), parent.width - Style.space(32))
        height: Math.min(Style.space(540), parent.height - Style.space(32))
        padding: Style.space(20)
        modal: true
        focus: true
        closePolicy: C.Popup.CloseOnEscape
        onOpened: cancelUpdateReview.forceActiveFocus()
        onClosed: {
          root.updateReviewOpen = false
          Qt.callLater(function() {
            if (!root.opened) return
            if (setupDetailPanel.visible) setupDetailPanel.restorePosition(setupDetailPanel.scrollPosition(), "update")
            else if (root.setupStage === "updates") updatesPage.takeFocus()
          })
        }
        background: BorderSurface {
          color: root.background
          radius: Style.cornerRadius
          borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
        }
        contentItem: Item {
          Column {
            id: updateReviewHeading
            width: parent.width
            spacing: Style.space(8)
            Text {
              width: parent.width
              text: root.updateBatchReview ? "Review " + root.reviewedUpdates.length + " eligible plugin updates"
                : root.reviewedUpdates.length && root.reviewedUpdates[0].selfUpdate ? "Update Outfit & reopen" : "Review plugin update"
              textFormat: Text.PlainText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              wrapMode: Text.Wrap
            }
            Text {
              width: parent.width
              text: root.updateBatchReview ? "These plugins will update one at a time. Outfit is updated separately."
                : root.reviewedUpdates.length && root.reviewedUpdates[0].selfUpdate
                  ? "Outfit will close for its update and reopen with your current view."
                  : "Update this installed plugin to the reviewed revision."
              textFormat: Text.PlainText
              color: root.secondary
              font.family: root.fontFamily
              font.pixelSize: root.readingSize
              wrapMode: Text.Wrap
            }
          }
          ContentScrollView {
            id: updateReviewScroll
            anchors.top: updateReviewHeading.bottom
            anchors.topMargin: Style.space(16)
            anchors.left: parent.left; anchors.right: parent.right
            anchors.bottom: updateReviewFooter.top
            anchors.bottomMargin: Style.space(16)
            contentWidth: availableWidth
            clip: true
            C.ScrollBar.horizontal.policy: C.ScrollBar.AlwaysOff
            Column {
              width: updateReviewScroll.availableWidth
              spacing: Style.space(16)
              Repeater {
                model: root.reviewedUpdates
                Text {
                  required property var modelData
                  width: parent.width
                  text: String(modelData.name || modelData.id) + "\n" + InspectorState.updateTransition(modelData)
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: root.readingSize
                  wrapMode: Text.Wrap
                }
              }
            }
          }
          Column {
            id: updateReviewFooter
            anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
            spacing: Style.space(12)
            Text {
              objectName: "updateReviewError"
              width: parent.width
              visible: Boolean(text)
              text: root.updateReviewError
              textFormat: Text.PlainText
              color: Color.urgent
              font.family: root.fontFamily
              font.pixelSize: root.readingSize
              wrapMode: Text.Wrap
            }
            Flow {
              width: parent.width
              spacing: Style.space(12)
              Button {
                id: cancelUpdateReview
                objectName: "cancelUpdateReview"
                text: "Cancel"
                foreground: root.foreground
                bordered: true; focusable: true
                onClicked: root.updateReviewOpen = false
              }
              Button {
                objectName: "confirmUpdates"
                text: root.updateBatchReview ? "Update all (" + root.reviewedUpdates.length + ")"
                  : root.reviewedUpdates.length && root.reviewedUpdates[0].selfUpdate ? "Update Outfit & reopen" : "Update"
                foreground: root.foreground
                bordered: true; focusable: true
                enabled: root.updatesIdle && !root.updateReviewError
                  && !(root.reviewedUpdates.length && root.reviewedUpdates[0].selfUpdate
                    && (root.settingsTouched || (root.service && root.service.interestsDirty)))
                onClicked: root.confirmUpdates()
              }
            }
          }
        }
      }

      ConfirmationDialog {
        id: actionConfirm
        anchors.fill: parent
        opened: root.actionConfirmOpen
        z: 100
        message: root.actionTarget
          ? (root.pendingAction === "install"
            ? "Install " + String(root.actionTarget.name || root.actionTarget.id)
              + " from its marketplace repository? "
              + (!root.pendingInstallEnabled ? "It will remain disabled."
                : root.actionTarget.barWidget === true ? "Enable its widget in the " + root.pendingInstallSection + " section."
                  : InspectorState.exclusive(root.actionTarget) ? "Activate it and replace the current shell role."
                    : "Enable it in Omarchy after installation.")
            : root.pendingAction === "activate" ? "Use " + String(root.actionTarget.name || root.actionTarget.id)
              + " as your bar? This replaces the currently active bar."
            : "Uninstall " + String(root.actionTarget.name || root.actionTarget.id)
              + " from this system? If it is enabled, Omarchy disables it first.")
          : ""
        confirmText: root.pendingAction === "install" ? "Install" : root.pendingAction === "activate" ? "Use this bar" : "Uninstall"
        background: root.background
        foreground: root.foreground
        onCanceled: root.cancelAction()
        onConfirmed: root.confirmAction()
      }

      ConfirmationDialog {
        id: batchConfirm
        anchors.fill: parent
        opened: root.batchConfirmOpen
        z: 101
        message: "Install " + root.setupSelectedCount
          + " selected plugins one at a time? Ordinary plugins will be enabled and bar widgets will use their selected locations."
        confirmText: "Install all"
        background: root.background
        foreground: root.foreground
        onCanceled: root.batchConfirmOpen = false
        onConfirmed: root.confirmSetupBatch()
      }
    }
  }
}
