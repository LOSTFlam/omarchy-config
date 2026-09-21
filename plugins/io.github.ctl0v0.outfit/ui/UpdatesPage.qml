pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls as C
import qs.Commons
import qs.Ui
import "Typography.js" as Typography
import "InspectorState.js" as InspectorState

FocusScope {
  id: root
  objectName: "updatesPage"
  property var service: null
  property bool active: true
  readonly property bool running: active && !(service && service.sleeping === true)
  property bool inventoryReady: false
  property bool settingsTouched: false
  property bool showSelfUpdate: false // Temporarily hide Outfit's own update card.
  property string notice: ""
  property alias query: search.text
  readonly property var rows: service && service.updates && typeof service.updates.length === "number"
    ? Array.from(service.updates) : []
  // Sorting is independent of query and activation. A replacement from Service
  // invalidates this cache once; both the list and empty state share one filter.
  readonly property var sortedRows: {
    var rank = {available:0, unavailable:1, customized:2, blocked:3, manual:3, current:4, development:5, managed:6}
    return rows.slice().sort(function(left, right) {
      if ((left.selfUpdate === true) !== (right.selfUpdate === true)) return left.selfUpdate === true ? -1 : 1
      var difference = (rank[left.state] === undefined ? 2 : rank[left.state])
        - (rank[right.state] === undefined ? 2 : rank[right.state])
      return difference || String(left.name || left.id).localeCompare(String(right.name || right.id))
    })
  }
  readonly property var filteredRows: {
    var term = query.trim().toLowerCase()
    return sortedRows.filter(function(row) {
      return (root.showSelfUpdate || row.selfUpdate !== true)
        && (!term || (String(row.name || "") + " " + row.id).toLowerCase().indexOf(term) >= 0)
    })
  }
  onFilteredRowsChanged: if (list && running && list.activeFocus) Qt.callLater(restoreFocus)
  property var expandedIds: ({})
  property string focusedId: ""
  property string focusedAction: "details"
  property real savedY: 0
  property real savedX: 0
  property var savedAnchor: null
  property bool restoring: false
  property var pendingFocus: null
  // Includes the reuse pool as well as rows attached to the visible content.
  property int instantiatedRowCount: 0
  readonly property var eligibleRows: rows.filter(InspectorState.eligibleUpdate)
  readonly property int failedCheckCount: rows.filter(function(row) {
    return (root.showSelfUpdate || row.selfUpdate !== true)
      && (row.state === "unavailable" || Boolean(row.checkError))
  }).length
  readonly property bool idle: Boolean(service && inventoryReady && !service.mutationBusy
    && !service.batchRunning && !service.selfUpdateBusy && !service.updatesBusy)
  readonly property real readingSize: Typography.reading(Style.font)
  readonly property real columnGap: Style.space(12)
  readonly property real rowPadding: Style.space(10)
  readonly property real versionWidth: Math.max(Style.space(92), textMetrics.advanceWidth("0123456789") + Style.space(4))
  readonly property real minimumPluginWidth: Math.max(Style.space(140), textMetrics.advanceWidth("Plugin") + Style.space(24))
  readonly property real minimumStatusWidth: Math.max(Style.space(150), textMetrics.advanceWidth("Locally customized"))
  readonly property real expandWidth: explainMeasure.implicitWidth
  readonly property real actionsWidth: updateMeasure.implicitWidth + detailsMeasure.implicitWidth + Style.space(8)
  readonly property real minimumTableWidth: rowPadding * 2 + columnGap * 5
    + expandWidth + minimumPluginWidth + versionWidth * 2 + minimumStatusWidth + actionsWidth
  readonly property real tableWidth: Math.max(scroll.availableWidth, minimumTableWidth)
  readonly property real extraWidth: tableWidth - minimumTableWidth
  readonly property real pluginWidth: minimumPluginWidth + extraWidth * 0.55
  readonly property real statusWidth: minimumStatusWidth + extraWidth * 0.45
  readonly property var columnWidths: [expandWidth, pluginWidth, versionWidth, versionWidth, statusWidth, actionsWidth]
  FontMetrics { id: textMetrics; font.family: Style.font.family; font.pixelSize: root.readingSize }
  signal backRequested()
  signal checkRequested()
  signal updateRequested(var row)
  signal updateAllRequested()
  signal detailRequested(var row, var invoker)
  signal progressRequested()
  signal positionChanged()

  function takeFocus() { search.forceActiveFocus() }
  function scrollPosition() { return savedY }
  function restorePosition(y) {
    savedAnchor = null
    savedY = Math.max(0, Number(y) || 0)
    if (running) applyPosition()
  }
  function context() {
    return {y:savedY, x:savedX, anchor:savedAnchor, expanded:expandedIds, id:focusedId, action:focusedAction}
  }
  function restoreContext(value) {
    if (!value) return
    expandedIds = value.expanded || ({})
    focusedId = String(value.id || "")
    focusedAction = String(value.action || "details")
    savedY = Math.max(0, Number(value.y) || 0)
    savedX = Math.max(0, Number(value.x) || 0)
    savedAnchor = value.anchor || null
    if (running) Qt.callLater(applyPosition)
  }
  function capturePosition() {
    if (!running || restoring || !list.count) return
    savedY = Math.max(0, list.contentY - list.originY)
    savedX = Math.max(0, list.contentX)
    var index = list.indexAt(root.rowPadding, list.contentY + 1)
    var item = list.itemAtIndex(index)
    savedAnchor = item ? {id:String(item.modelData.id), offset:item.y - list.contentY} : null
    positionChanged()
  }
  function applyPosition() {
    if (!running) return
    restoring = true
    list.forceLayout()
    var index = savedAnchor ? filteredRows.findIndex(function(row) { return String(row.id) === root.savedAnchor.id }) : -1
    if (index >= 0) {
      list.positionViewAtIndex(index, ListView.Beginning)
      list.forceLayout()
      var item = list.itemAtIndex(index)
      if (item) list.contentY = item.y - Number(savedAnchor.offset || 0)
    } else list.contentY = list.originY + Math.min(savedY, Math.max(0, list.contentHeight - list.height))
    list.contentX = Math.min(savedX, Math.max(0, list.contentWidth - list.width))
    restoring = false
  }
  onRunningChanged: if (running) Qt.callLater(applyPosition)
  function toggleExpanded(id) {
    var next = Object.assign({}, expandedIds)
    if (next[id]) delete next[id]
    else next[id] = true
    expandedIds = next
    positionChanged()
  }
  function revealRow(id) {
    var index = filteredRows.findIndex(function(row) { return String(row.id) === String(id) })
    if (!running || index < 0) return false
    list.positionViewAtIndex(index, ListView.Contain)
    list.forceLayout()
    return true
  }
  function focusRow(id, action) {
    if (!revealRow(id)) return false
    pendingFocus = {id:String(id), action:action || "details"}
    finishFocus()
    if (pendingFocus) Qt.callLater(finishFocus)
    return true
  }
  function finishFocus() {
    if (!pendingFocus || !running) return
    var index = filteredRows.findIndex(function(row) { return String(row.id) === root.pendingFocus.id })
    var item = list.itemAtIndex(index)
    if (!item) return
    var action = pendingFocus.action
    pendingFocus = null
    item.focusAction(action)
  }
  function restoreFocus() {
    if (!focusRow(focusedId, focusedAction)) takeFocus()
  }
  function navigate(id, action, event) {
    if (event.modifiers !== Qt.NoModifier && event.modifiers !== Qt.ShiftModifier) return
    var index = filteredRows.findIndex(function(row) { return String(row.id) === id })
    var next = index
    if (event.key === Qt.Key_Down) next++
    else if (event.key === Qt.Key_Up) next--
    else if (event.key === Qt.Key_Home) next = 0
    else if (event.key === Qt.Key_End) next = filteredRows.length - 1
    else if (event.key === Qt.Key_PageDown || event.key === Qt.Key_PageUp)
      next += (event.key === Qt.Key_PageUp ? -1 : 1) * Math.max(1, Math.floor(list.height / Style.space(68)))
    else if (event.key === Qt.Key_Tab && action === "details") { next++; action = "explain" }
    else if (event.key === Qt.Key_Backtab && action === "explain") { next--; action = "details" }
    else return
    if (next < 0 || next >= filteredRows.length) {
      if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) return
      next = Math.max(0, Math.min(next, filteredRows.length - 1))
    }
    if (next >= 0) focusRow(String(filteredRows[next].id), action)
    event.accepted = true
  }
  function canUpdate(row) {
    return idle && (row.selfUpdate === true
      ? row.state === "available" && !settingsTouched && !service.interestsDirty
      : InspectorState.eligibleUpdate(row))
  }
  function statusLabel(row) {
    if (row.state === "available") return row.installedVersion && row.installedVersion === row.availableVersion
      && row.installedRevision !== row.availableRevision ? "New changes" : "Update available"
    return ({current:"Up to date", customized:"Locally customized", blocked:"Needs review",
      manual:"Manual update", unavailable:"Couldn’t check", managed:"System managed",
      development:"Development"})[row.state] || "Not checked"
  }
  function revealTableItem(item) {
    if (!item || !scroll.contentItem) return
    var viewport = scroll.contentItem
    var point = item.mapToItem(viewport, 0, 0)
    var x = viewport.contentX, y = viewport.contentY
    if (point.x < 0) x += point.x - root.rowPadding
    else if (point.x + item.width > scroll.availableWidth) x += point.x + item.width - scroll.availableWidth + root.rowPadding
    if (point.y < 0) y += point.y - root.rowPadding
    else if (point.y + item.height > scroll.availableHeight) y += point.y + item.height - scroll.availableHeight + root.rowPadding
    viewport.contentX = Math.max(0, Math.min(x, viewport.contentWidth - scroll.availableWidth))
    viewport.contentY = Math.max(viewport.originY, Math.min(y, viewport.originY + viewport.contentHeight - scroll.availableHeight))
  }
  component Copy: Text {
    textFormat: Text.PlainText
    color: Color.foreground
    font.family: Style.font.family
    font.pixelSize: root.readingSize
    wrapMode: Text.Wrap
    Accessible.name: text
  }
  component Action: Button {
    id: action
    property bool tableAction: false
    property string rowId: ""
    property string actionKind: "details"
    fontSize: root.readingSize
    foreground: Color.foreground
    bordered: true
    focusable: true
    opacity: enabled ? 1 : 0.45
    Accessible.role: Accessible.Button
    Accessible.name: text
    Accessible.onPressAction: if (enabled) clicked()
    function reveal() { if (activeFocus && root.running) root.revealTableItem(action) }
    onActiveFocusChanged: if (activeFocus && tableAction) {
      root.focusedId = rowId
      root.focusedAction = actionKind
      Qt.callLater(reveal)
    }
    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function(event) { if (tableAction) root.navigate(rowId, actionKind, event) }
  }
  Action { id: updateMeasure; visible: false; text: root.showSelfUpdate ? "Update Outfit & reopen" : "Update"; horizontalPadding: Style.space(8) }
  Action { id: detailsMeasure; visible: false; text: "Details"; horizontalPadding: Style.space(8) }
  Action { id: explainMeasure; visible: false; text: "+"; horizontalPadding: Style.space(5) }
  component VersionCell: Column {
    property string version: ""
    property string revision: ""
    property string label: ""
    width: root.versionWidth
    spacing: Style.space(2)
    Copy {
      width: parent.width
      text: parent.version || "—"
      maximumLineCount: 2
      elide: Text.ElideRight
      Accessible.name: parent.label + ": " + (parent.version || "Not available")
    }
    Copy {
      visible: Boolean(parent.revision)
      width: parent.width
      text: parent.revision.slice(0, 10)
      opacity: 0.6
      maximumLineCount: 1
      elide: Text.ElideRight
      Accessible.name: parent.label + " revision " + parent.revision
    }
  }
  component UpdateRow: Item {
    id: card
    required property var modelData
    required property int index
    Component.onCompleted: ++root.instantiatedRowCount
    Component.onDestruction: --root.instantiatedRowCount
    readonly property bool expanded: root.expandedIds[String(modelData.id)] === true
    function focusAction(kind) {
      var target = kind === "explain" ? explain : kind === "update" && updateButton.visible && updateButton.enabled ? updateButton : detailsButton
      target.forceActiveFocus()
      root.revealTableItem(target)
    }
    objectName: "updateRow." + modelData.id
    width: root.tableWidth
    height: Math.max(Style.space(48), cells.height + root.rowPadding * 2)
      + (expanded ? explanation.implicitHeight + root.rowPadding : 0)
    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, card.index % 2 === 0 ? 0.035 : 0)
    }
    Rectangle {
      anchors.bottom: parent.bottom
      width: parent.width; height: 1
      color: Color.foreground; opacity: 0.12
    }
    Row {
      id: cells
      x: root.rowPadding; y: root.rowPadding
      spacing: root.columnGap
      Action {
        id: explain
        objectName: "updateExplain." + card.modelData.id
        tableAction: true
        rowId: String(card.modelData.id)
        actionKind: "explain"
        width: root.expandWidth
        text: card.expanded ? "−" : "+"
        horizontalPadding: Style.space(5)
        bordered: false
        Accessible.name: (card.expanded ? "Hide" : "Show") + " status details for " + String(card.modelData.name || card.modelData.id)
        onClicked: root.toggleExpanded(String(card.modelData.id))
      }
      Copy {
        objectName: "updatePluginCell." + card.modelData.id
        width: root.pluginWidth
        text: String(card.modelData.name || card.modelData.id)
        font.bold: true
        maximumLineCount: 2
        elide: Text.ElideRight
      }
      VersionCell {
        objectName: "updateInstalledCell." + card.modelData.id
        label: "Installed"
        version: String(card.modelData.installedVersion || "")
        revision: String(card.modelData.installedRevision || "")
      }
      VersionCell {
        objectName: "updateUpstreamCell." + card.modelData.id
        label: "Upstream"
        version: String(card.modelData.availableVersion || "")
        revision: String(card.modelData.availableRevision || "")
      }
      Copy {
        objectName: "updateStatusCell." + card.modelData.id
        width: root.statusWidth
        text: root.statusLabel(card.modelData)
        color: InspectorState.eligibleUpdate(card.modelData) ? Color.accent : Color.foreground
        maximumLineCount: 2
        elide: Text.ElideRight
      }
      Item {
        objectName: "updateActionsCell." + card.modelData.id
        width: root.actionsWidth
        height: Math.max(updateButton.visible ? updateButton.implicitHeight : 0, detailsButton.implicitHeight)
        Action {
          id: updateButton
          objectName: "updateAction." + card.modelData.id
          tableAction: true
          rowId: String(card.modelData.id)
          actionKind: "update"
          horizontalPadding: Style.space(8)
          visible: card.modelData.selfUpdate === true ? card.modelData.state === "available"
            : InspectorState.eligibleUpdate(card.modelData)
          text: card.modelData.selfUpdate === true ? "Update Outfit & reopen" : "Update"
          enabled: root.canUpdate(card.modelData)
          onClicked: root.updateRequested(card.modelData)
        }
        Action {
          id: detailsButton
          objectName: "updateDetails." + card.modelData.id
          tableAction: true
          rowId: String(card.modelData.id)
          horizontalPadding: Style.space(8)
          anchors.right: parent.right
          text: "Details"
          Accessible.name: "Details for " + String(card.modelData.name || card.modelData.id)
          onClicked: {
            root.focusedId = String(card.modelData.id)
            root.focusedAction = "details"
            root.capturePosition()
            root.detailRequested(card.modelData, this)
          }
        }
      }
    }
    Copy {
      id: explanation
      objectName: "updateExplanation." + card.modelData.id
      x: root.rowPadding + (scroll.contentItem ? scroll.contentItem.contentX : 0)
      y: cells.y + cells.height + root.rowPadding
      width: Math.min(card.width, scroll.availableWidth) - root.rowPadding * 2
      visible: card.expanded
      opacity: 0.75
      text: !card.expanded ? "" : InspectorState.updateTransition(card.modelData) + "\n" + InspectorState.updateStatus(card.modelData, true, "")
        + (card.modelData.selfUpdate === true ? "\n" + (root.settingsTouched || (root.service && root.service.interestsDirty)
          ? "Save or discard your settings and interest changes before updating Outfit."
          : "Outfit updates separately and reopens this window when finished.") : "")
    }
  }

  Column {
    id: header
    width: parent.width
    spacing: Style.space(8)
    Item {
      id: toolbar
      objectName: "updatesToolbar"
      width: parent.width
      readonly property real gap: Style.space(8)
      readonly property real leftWidth: back.implicitWidth + (progress.visible ? progress.implicitWidth + gap : 0)
      readonly property real rightWidth: check.implicitWidth + updateAll.implicitWidth + gap
      readonly property bool stacked: leftWidth + rightWidth + gap > width
      height: stacked ? leftActions.height + gap + rightActions.height : Math.max(leftActions.height,rightActions.height)
      Flow {
        id: leftActions
        width: Math.min(toolbar.width,toolbar.leftWidth)
        spacing: toolbar.gap
        Action { id: back; objectName: "updatesBack"; text: "‹ Back"; onClicked: root.backRequested() }
        Action {
          id: progress
          visible: Boolean(root.service && root.service.batchItems && root.service.batchItems.length)
          text: root.service && root.service.batchKind === "update" ? "Batch update progress" : "Batch install progress"
          onClicked: root.progressRequested()
        }
      }
      Flow {
        id: rightActions
        objectName: "updatesRightActions"
        width: Math.min(toolbar.width,toolbar.rightWidth)
        x: toolbar.width - width
        y: toolbar.stacked ? leftActions.height + toolbar.gap : 0
        spacing: toolbar.gap
        layoutDirection: toolbar.rightWidth > width ? Qt.RightToLeft : Qt.LeftToRight
        Action {
          id: check
          objectName: "updatesCheck"
          text: root.service && root.service.updatesBusy ? "Checking for updates…" : "Check for updates"
          enabled: root.idle
          onClicked: root.checkRequested()
        }
        Action {
          id: updateAll
          objectName: "updatesAll"
          text: "Update all (" + root.eligibleRows.length + ")…"
          enabled: root.idle && root.eligibleRows.length > 0
          onClicked: root.updateAllRequested()
        }
      }
    }
    Copy { text: "Updates"; font.pixelSize: Style.font.title; font.bold: true }
    Copy {
      objectName: "updatesLastChecked"
      width: parent.width
      text: "Last checked: " + (root.service && root.service.updatesCheckedAt > 0
        ? Qt.formatDateTime(new Date(root.service.updatesCheckedAt * 1000), "MMM d, HH:mm") : "Not yet checked")
    }
    TextField {
      id: search
      objectName: "updatesSearch"
      width: parent.width
      foreground: Color.foreground
      font.pixelSize: root.readingSize
      placeholderText: "Search installed plugins"
      maximumLength: 160
      onTextEdited: root.positionChanged()
    }
    Copy {
      width: parent.width
      visible: !root.inventoryReady
      text: "Plugin inventory is unavailable. Updates are paused until plugin checks succeed."
    }
    Copy {
      objectName: "updatesError"
      width: parent.width
      visible: Boolean(text)
      color: Color.urgent
      text: root.notice || (root.service ? String(root.service.updatesError || "") : "")
    }
    Copy {
      objectName: "selfUpdateStatus"
      width: parent.width
      visible: Boolean(text)
      text: root.service && root.service.selfUpdateState ? String(root.service.selfUpdateState.message || "") : ""
    }
    Copy {
      objectName: "updatesPartialStatus"
      width: parent.width
      visible: root.failedCheckCount > 0
      opacity: 0.7
      text: "Couldn’t check " + root.failedCheckCount + " plugin" + (root.failedCheckCount === 1 ? "" : "s")
        + ". See their status below."
    }
    Copy {
      width: parent.width
      text: (root.eligibleRows.length ? root.eligibleRows.length + " update" + (root.eligibleRows.length === 1 ? "" : "s") + " available"
        : "No automatic updates available")
        + (root.showSelfUpdate ? " · Outfit is updated separately." : "")
    }
    Item {
      objectName: "updatesTableHeader"
      width: parent.width
      height: textMetrics.height + root.rowPadding * 2
      clip: true
      Row {
        id: tableHeading
        x: root.rowPadding - (scroll.contentItem ? scroll.contentItem.contentX : 0)
        y: root.rowPadding
        spacing: root.columnGap
        Repeater {
          model: ["", "Plugin", "Installed", "Upstream", "Status", "Actions"]
          Copy {
            required property string modelData
            required property int index
            objectName: "updateHeading." + index
            width: root.columnWidths[index]
            height: textMetrics.height
            text: modelData
            font.bold: true
            opacity: 0.7
          }
        }
      }
      Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Color.foreground; opacity: 0.2 }
    }
  }
  ContentScrollView {
    id: scroll
    objectName: "updatesScroll"
    anchors.top: header.bottom
    anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
    contentWidth: root.tableWidth
    bottomPadding: effectiveScrollBarHeight
    clip: true
    C.ScrollBar.horizontal.policy: C.ScrollBar.AsNeeded
    ListView {
      id: list
      objectName: "updatesList"
      contentWidth: root.tableWidth
      flickableDirection: Flickable.AutoFlickDirection
      boundsBehavior: Flickable.StopAtBounds
      reuseItems: root.running
      cacheBuffer: Style.space(100)
      currentIndex: -1
      spacing: 0
      model: root.running ? root.filteredRows : []
      delegate: root.running ? updateRowDelegate : null
      Component { id: updateRowDelegate; UpdateRow {} }
      onContentYChanged: root.capturePosition()
      onContentXChanged: root.capturePosition()
      onCountChanged: if (root.running) Qt.callLater(root.applyPosition)
      Copy {
        objectName: "updatesEmpty"
        width: parent.width
        visible: !root.filteredRows.length
        text: root.service && root.service.updatesBusy ? "Checking installed plugins…"
          : !root.service || !root.service.updatesLoaded ? "Check for updates to see installed plugin versions."
          : root.query.trim() ? "No installed plugins match this search." : "No installed plugin update records."
      }
    }
  }
}
