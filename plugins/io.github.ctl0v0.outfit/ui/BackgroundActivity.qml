pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls as C
import qs.Commons
import qs.Ui
import "Typography.js" as Typography

C.Popup {
  id: root
  objectName: "backgroundActivity"
  property var service: null
  property Item invoker: null
  property Item anchorItem: null
  property Item boundsItem: parent && parent.Window.window ? parent.Window.window.contentItem : parent
  readonly property real edgeMargin: Style.space(8)
  readonly property rect popupBounds: mappedRect(boundsItem)
  readonly property rect anchorBounds: mappedRect(anchorItem)
  property real maximumHeight: Math.max(0, popupBounds.y + popupBounds.height - edgeMargin - y)
  property real clockNow: Date.now()
  popupType: C.Popup.Item
  modal: false
  dim: false
  focus: true
  width: Math.min(Style.space(380), Math.max(0, popupBounds.width - edgeMargin * 2))
  x: Math.max(popupBounds.x + edgeMargin, Math.min(
    anchorItem ? anchorBounds.x + anchorBounds.width - width : popupBounds.x + popupBounds.width - edgeMargin - width,
    popupBounds.x + popupBounds.width - edgeMargin - width))
  y: Math.max(popupBounds.y + edgeMargin, Math.min(
    anchorItem ? anchorBounds.y + anchorBounds.height : popupBounds.y + edgeMargin,
    popupBounds.y + popupBounds.height - edgeMargin - Style.space(120)))
  margins: edgeMargin
  padding: Style.space(14)
  closePolicy: C.Popup.CloseOnEscape | C.Popup.CloseOnPressOutside
  implicitHeight: body.implicitHeight + topPadding + bottomPadding
  height: Math.min(implicitHeight, maximumHeight)
  onAboutToShow: clockNow = Date.now()
  onClosed: if (invoker && invoker.visible && invoker.enabled) invoker.forceActiveFocus()

  // Popup is not an Item. Map its anchor and content-area bounds through real
  // Items in the popup parent's coordinate space, including ancestor offsets.
  function mappedRect(item) {
    if (!item || !parent) return Qt.rect(0, 0, Style.space(600), Style.space(600))
    for (var origin of [item, parent]) {
      for (var ancestor = origin; ancestor; ancestor = ancestor.parent) {
        var geometry = [ancestor.x, ancestor.y, ancestor.width, ancestor.height, ancestor.scale, ancestor.rotation]
      }
    }
    var top = item.mapToItem(parent, 0, 0)
    var bottom = item.mapToItem(parent, item.width, item.height)
    return Qt.rect(Math.min(top.x, bottom.x), Math.min(top.y, bottom.y),
      Math.abs(bottom.x - top.x), Math.abs(bottom.y - top.y))
  }
  Timer {
    interval: 1000
    repeat: true
    running: root.visible && root.service && root.service.searchPackFailed === true
    onTriggered: root.clockNow = Date.now()
  }
  function seedFailureText() {
    if (!service || !service.searchPackFailed) return ""
    var remaining = Math.max(0, Number(service.searchPackRetryAt || 0) - clockNow)
    return "Public search library unavailable. Catalog search is retained; local documentation checks continue separately."
      + (remaining > 0 ? " Library retry is available in " + Math.ceil(remaining / 60000) + " min." : " You can retry the library download.")
  }

  function laneState(lane) {
    if (!service) return "waiting"
    if (lane === "inventory" && service.canManagePlugins && !service.inventoryBusy) return "complete"
    if (lane === "documentation" && service.preferences.readmeEnrichment === false) return "disabled"
    if (lane === "documentation" && !service.indexingEnabled) return "paused"
    return service.startupActivity[lane].state
  }
  function description(lane) {
    var current = currentDescription(lane)
    var failure = lane === "documentation" ? seedFailureText() : ""
    return current + (failure ? "\n" + failure : "")
  }
  function currentDescription(lane) {
    if (!service) return "Waiting for Outfit."
    var state = laneState(lane)
    if (lane === "documentation") {
      if (state === "disabled") return "Documentation updates are disabled in Settings."
      if (state === "paused") return "Paused. Cached documentation is still searchable."
      if (service.libraryPrepared) return "Library prepared. Available documentation is searchable."
      if (state === "error") return "Preparation needs attention. Catalog search remains available; retry or allow local indexing to continue."
      if (service.preparingSearch) return "Preparing the search library in the background."
      if (service.indexingBusy) return "Adding searchable documentation."
      if (!service.canBrowse) return "Waiting for marketplace listings."
      return "Catalog search is ready. Documentation is added while Outfit is open."
    }
    if (lane === "inventory") return state === "complete" ? "Plugin management is ready."
      : state === "error" ? "Could not confirm installed plugins. Retry to enable plugin changes."
      : service.canBrowse ? "Checking installed plugins. You can browse now." : "Checking installed plugins."
    if (lane === "hardware") return state === "disabled" ? "Optional checks are disabled in Settings."
      : state === "complete" ? "Optional local fit checks finished."
      : state === "error" ? "Optional checks could not finish. Browsing and plugin checks continue independently."
      : "Optional local fit checks. Browsing does not wait for these."
    return state === "error" ? "Could not refresh. Available cached listings remain browsable."
      : state === "complete" ? "Marketplace listings updated."
      : state === "cached" ? "Saved listings are ready to browse."
      : "Updating marketplace listings and public counts."
  }
  function coverage() {
    var counts = service ? service.documentCounts : ({})
    if (service && service.indexingBusy && service.startupActivity.documentation.documents)
      counts = service.startupActivity.documentation.documents
    if (!(Number(counts.total) > 0)) return ""
    return Number(counts.indexed || 0) + " searchable · " + Number(counts.processed || 0)
      + " / " + Number(counts.total) + " checked"
      + (counts.unavailable ? " · " + counts.unavailable + " unavailable" : "")
      + (counts.failed ? " · " + counts.failed + " will retry" : "")
      + (counts.skipped ? " · " + counts.skipped + " awaiting local checks" : "")
  }
  function reveal(item) {
    var flick = scrolling.contentItem
    var point = item.mapToItem(body, 0, 0)
    var next = flick.contentY
    if (point.y < next) next = point.y
    else if (point.y + item.height > next + flick.height) next = point.y + item.height - flick.height
    flick.contentY = Math.max(0, Math.min(next, flick.contentHeight - flick.height))
  }
  function focusBoundary(last) {
    var target = closeButton
    if (!last) {
      target = pauseButton.visible && pauseButton.enabled ? pauseButton : closeButton
      for (var i = stages.count - 1; i >= 0; i--) {
        var button = stages.itemAt(i).retryButton
        if (button.visible && button.enabled) target = button
      }
    }
    target.forceActiveFocus()
    reveal(target)
  }
  background: BorderSurface {
    color: Color.popups.background
    radius: Style.cornerRadius
    borderSpec: Border.controlSpec("normal", Color.popups.text, Color.accent)
  }
  contentItem: ContentScrollView {
    id: scrolling
    objectName: "activityScroll"
    clip: true
    contentWidth: availableWidth
    Column {
    id: body
    width: scrolling.availableWidth
    spacing: Style.space(12)
    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_End || event.key === Qt.Key_Home) {
        root.focusBoundary(event.key === Qt.Key_End)
        event.accepted = true
      }
    }
    Text {
      width: parent.width
      text: "Background activity"
      color: Color.popups.text
      font.family: Style.font.family
      font.pixelSize: Typography.reading(Style.font)
      font.bold: true
    }
    Repeater {
      id: stages
      model: [{lane:"catalog", title:"Catalog"}, {lane:"inventory", title:"Installed plugins"},
        {lane:"hardware", title:"System fit · optional"}, {lane:"documentation", title:"Documentation · optional"}]
      Column {
        id: stage
        required property var modelData
        readonly property alias retryButton: retryAction
        width: body.width
        spacing: Style.space(4)
        readonly property var progress: root.service ? root.service.startupActivity[modelData.lane] : ({})
        readonly property real fraction: root.service ? root.service.measuredProgress(progress) : -1
        Text {
          text: stage.modelData.title
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Typography.supporting(Style.font)
          font.bold: true
        }
        Text {
          width: parent.width
          text: root.description(stage.modelData.lane)
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Typography.supporting(Style.font)
        }
        Rectangle {
          width: parent.width
          height: Style.space(2)
          visible: stage.progress.state === "running" && stage.fraction >= 0
          color: Qt.alpha(Color.popups.text, 0.15)
          Rectangle { height: parent.height; width: parent.width * Math.max(0, stage.fraction); color: Color.accent }
          Accessible.name: "Measured progress " + Math.round(stage.fraction * 100) + " percent"
        }
        Text {
          width: parent.width
          visible: stage.modelData.lane === "documentation" && Boolean(text)
          text: stage.modelData.lane === "documentation" ? root.coverage() : ""
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Typography.supporting(Style.font)
        }
        Button {
          id: retryAction
          objectName: "activityRetry-" + stage.modelData.lane
          visible: root.laneState(stage.modelData.lane) === "error"
            || (stage.modelData.lane === "documentation" && root.service && root.service.searchPackFailed === true)
          text: stage.modelData.lane === "documentation" && root.service && root.service.searchPackFailed
            ? "Retry search library" : "Retry " + stage.modelData.title.split(" · ")[0].toLowerCase()
          foreground: Color.popups.text
          fontSize: Typography.supporting(Style.font)
          bordered: true
          focusable: true
          enabled: root.service && !root.service.mutationBusy
            && (stage.modelData.lane !== "documentation" || (root.service.indexingEnabled
              && !root.service.preparingSearch && !root.service.indexingBusy
              && root.clockNow >= Number(root.service.searchPackRetryAt || 0)))
          onActiveFocusChanged: if (activeFocus) root.reveal(this)
          onClicked: root.service.retryStartupLane(stage.modelData.lane)
        }
      }
    }
    Button {
      id: pauseButton
      objectName: "activityPause"
      text: root.service && root.service.preferences.readmeIndexing === false ? "Resume documentation" : "Pause documentation"
      visible: root.service && root.service.preferences.readmeEnrichment !== false
      enabled: root.service && !root.service.busy
      foreground: Color.popups.text
      fontSize: Typography.supporting(Style.font)
      bordered: true
      focusable: true
      onActiveFocusChanged: if (activeFocus) root.reveal(this)
      onClicked: root.service.setIndexingPaused(root.service.preferences.readmeIndexing !== false)
    }
    Text {
      width: parent.width
      text: "Unavailable documents count as checked. Cached coverage means searchable text, not that every check has run."
      wrapMode: Text.WordWrap
      color: Color.popups.text
      opacity: 0.7
      font.family: Style.font.family
      font.pixelSize: Typography.supporting(Style.font)
    }
    Button {
      id: closeButton
      objectName: "activityClose"
      text: "Close details"
      foreground: Color.popups.text
      fontSize: Typography.supporting(Style.font)
      focusable: true
      onActiveFocusChanged: if (activeFocus) root.reveal(this)
      onClicked: root.close()
    }
  }
  }
}
