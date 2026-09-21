pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import QtQuick.Controls as C
import qs.Commons
import qs.Ui
import "Typography.js" as Typography
import "Navigation.js" as Navigation
import "InspectorState.js" as InspectorState

// Presentation-only detail surface. Its owner supplies confirmed state and
// handles requests; the fixture owner intentionally never calls native APIs.
FocusScope {
  id: root
  readonly property real readingSize: Typography.reading(Style.font)
  readonly property real supportingSize: Typography.supporting(Style.font)
  readonly property real valueSize: Typography.value(Style.font)
  readonly property real iconSize: Typography.icon(Style.font)
  readonly property real targetSize: Typography.target(Style.font)
  objectName: "pluginDetailPage"
  property bool active: true
  property var service: null
  readonly property bool mediaActive: active && visible && !(service && service.sleeping === true)
  property real savedScroll: 0
  property bool scrollRestorePending: false
  property var pluginRow: ({})
  property var presentation: ({})
  property var mediaItems: []
  property Component mediaComponent: null
  property bool mediaAvailable: false
  readonly property bool hasMedia: mediaComponent ? mediaAvailable : mediaItems.length > 0
  readonly property real previewMaximumHeight: Style.space(compact && shortWindow ? 130 : 310)
  property bool installEnabled: true
  property string installSection: "right"
  property string backLabel: "Back to Browse"
  property string notice: ""
  property string prototypeLabel: ""
  signal backRequested()
  signal primaryRequested()
  signal enabledRequested()
  signal installEnabledRequested()
  signal sectionRequested(string section)
  signal queueRequested()
  signal removeRequested()
  signal sourceRequested()
  signal marketplaceRequested()
  signal reviewRequested()
  signal prototypeRequested()
  signal documentationRequested()
  signal updateRequested()
  signal updateCheckRequested()

  readonly property color foreground: Color.foreground
  readonly property color muted: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.66)
  readonly property color faint: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.045)
  readonly property bool compact: width < Style.space(1000)
  readonly property bool shortWindow: height < Style.space(530)
  readonly property real gutter: Style.space(compact ? 12 : 24)
  readonly property bool tallCompact: compact && !shortWindow
  // Native Toggle reserves two outer paddings, a label/track gap, and a
  // ToggleSwitch track (whose height has a 22px floor even at small themes).
  readonly property real toggleChromeWidth: 3 * (Number(Style.spacing.rowPaddingX) || Style.space(12))
    + Math.round(Math.max(22, Math.round((Number(Style.spacing.controlHeight) || Style.space(28)) * 0.55)) * 1.9)
  readonly property real controlLabelWidth: Math.max(enabledSwitch.minimumLabelWidth, installSwitch.minimumLabelWidth)
  readonly property real placementWidth: Math.max(Style.space(228),
    Math.ceil(controlTextWidth("Center") + Style.space(24)) * 3 + Style.space(8))
  FontMetrics {
    id: controlMetrics
    font.family: Style.font.family
    font.pixelSize: root.readingSize
    font.bold: true
  }
  FontMetrics {
    id: metadataMetrics
    font.family: Style.font.family
    font.pixelSize: root.supportingSize
  }
  property bool matchingExpanded: false
  readonly property bool dockRecommendation: !compact
    && height - controlPanel.y - controlPanel.height - gutter >= Style.space(110)
  property bool documentationExpanded: true
  property bool descriptionExpanded: false
  property int selectedMedia: 0
  readonly property var currentMedia: mediaItems.length ? mediaItems[Math.min(selectedMedia, mediaItems.length - 1)] : ({})
  readonly property string identity: String(pluginRow.id || "")
  readonly property string localState: !presentation.known ? "Status unavailable"
    : presentation.installed ? (presentation.exclusive ? (presentation.enabled ? "Current bar" : "Installed · Inactive")
      : presentation.enabled ? "Installed · Enabled" : "Installed · Disabled")
    : presentation.primaryAction === "project" ? "Manual setup" : presentation.selected ? "In batch install" : "Available to install"
  readonly property bool installOptions: !presentation.installed && presentation.known
    && presentation.primaryAction !== "project" && !presentation.selected && !presentation.failed
  readonly property string statusMessage: String(presentation.message || notice || "")
  readonly property var metrics: [
    {key:"likes", label:"Likes", value:pluginRow.likes, help:"Anonymous marketplace hearts, separate from GitHub stars. Reactions, not unique-user ratings or installations."},
    {key:"stars", label:"GitHub stars", value:pluginRow.stars, help:"GitHub stars on the source repository, reported by the cached marketplace catalog. Popularity, not a user rating or installation count."},
    {key:"views", label:"Views", value:pluginRow.views, help:"Marketplace listing visits. Not unique visitors, active users, or installations."},
    {key:"copies", label:"Command copies", value:pluginRow.copies, help:"Marketplace installation-command copies. Copying a command does not confirm an installation."}
  ]
  readonly property var scores: [
    {key:"recommended", label:"Recommended", value:pluginRow.recommendationScore, help:"Recommended combines GitHub popularity and local hardware fit. Display grouping does not change this score; it is not an installation count or compatibility guarantee."},
    {key:"fit", label:"Hardware fit", value:pluginRow.score, help:"Local hardware fit: how strongly your detected devices and capabilities match the listing and enabled README text. A heuristic score from 0 to 100, not a compatibility guarantee."}
  ]
  property Item activeMetricHelp: null
  property Item hoveredMetricHelp: null
  property point metricPointerPosition: Qt.point(-1, -1)
  property bool metricWindowRestoring: false

  function dismissMetricHelp() {
    if (!activeMetricHelp) return false
    var metric = activeMetricHelp
    activeMetricHelp = null
    metric.closeHelp()
    return true
  }
  function moveMetricPointer(position) {
    // Layout and popup changes also refresh hover. A stationary pointer must
    // not reopen dismissed help after a new listing, view or window activation.
    if (position.x === metricPointerPosition.x && position.y === metricPointerPosition.y) return
    metricPointerPosition = position
    var hovered = null
    if (contentScroll.contains(contentScroll.mapFromItem(null, position.x, position.y))) {
      for (var i = 0; i < metricContent.children.length; i++) {
        var item = metricContent.children[i]
        if (typeof item.showHelp === "function" && item.contains(item.mapFromItem(null, position.x, position.y))) {
          hovered = item
          break
        }
      }
    }
    if (activeMetricHelp && activeMetricHelp !== hovered) dismissMetricHelp()
    if (hoveredMetricHelp === hovered) return
    hoveredMetricHelp = hovered
    if (hovered) hovered.showHelp(false)
  }
  Item {
    anchors.fill: parent
    z: 1
    // Observe before child MouseAreas accept input, using passive handlers so
    // clicks and scrolling still reach the intended metric or page control.
    HoverHandler {
      onPointChanged: root.moveMetricPointer(point.scenePosition)
      onHoveredChanged: if (!hovered) { root.hoveredMetricHelp = null; root.dismissMetricHelp() }
    }
    PointHandler {
      acceptedButtons: Qt.AllButtons
      grabPermissions: PointerHandler.TakeOverForbidden
      // Cancel pending hover too; a metric click explicitly rearms its help.
      onActiveChanged: if (active) root.dismissMetricHelp()
    }
    WheelHandler {
      target: null
      blocking: false
      onWheel: function(event) { root.dismissMetricHelp(); event.accepted = false }
    }
  }

  function count(value) {
    if (value === null || value === undefined || !isFinite(Number(value)) || Number(value) < 0) return "—"
    return String(Math.floor(Number(value))).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
  }
  function controlTextWidth(text) {
    // advanceWidth() alone does not subscribe a caller to font changes.
    var font = controlMetrics.font
    return font.pixelSize > 0 ? controlMetrics.advanceWidth(text) : 0
  }
  function takeFocus() { backButton.forceActiveFocus() }
  function stopMedia() {
    if (mediaSlot.item && typeof mediaSlot.item.stopMedia === "function") mediaSlot.item.stopMedia()
  }
  function scrollPosition() { return active && !scrollRestorePending ? Number(contentScroll.contentItem.contentY || 0) : savedScroll }
  function imageBucket(size) {
    return Math.max(128, Math.min(4096, Math.ceil(Math.max(1, size) * Math.max(1, Screen.devicePixelRatio) / 128) * 128))
  }
  function invalidateImage(source) {
    if (!source || !service || typeof service.invalidateThumbnail !== "function") return
    var cached = service.thumbnails ? service.thumbnails[identity] : null
    if (cached && String(cached.localSource || "") === String(source))
      service.invalidateThumbnail(identity, String(source))
  }
  function restoreScroll() {
    if (!active) return
    if (pluginRow.readmeLoading === true) return
    content.forceLayout()
    contentScroll.contentItem.contentY = Math.max(0, Math.min(savedScroll,
      contentScroll.contentItem.contentHeight - contentScroll.height))
    scrollRestorePending = false
  }
  onActiveChanged: {
    if (!active) scrollRestorePending = true
    else detailScrollRestore.restart()
  }
  onPluginRowChanged: if (active && scrollRestorePending) detailScrollRestore.restart()
  // Recreated document blocks need a polish pass before their height is known.
  Timer { id: detailScrollRestore; interval: 1; onTriggered: root.restoreScroll() }
  onMediaActiveChanged: if (!mediaActive) { stopMedia(); fullSize.close() }
  function isScrollKey(key) {
    return [Qt.Key_Up, Qt.Key_Down, Qt.Key_PageUp, Qt.Key_PageDown, Qt.Key_Home, Qt.Key_End].indexOf(key) >= 0
  }
  function scrollPane(event, view, readmeReading) {
    if (event.modifiers !== Qt.NoModifier || fullSize.visible || operationDetails.visible) return
    var key = event.key
    if (!isScrollKey(key)) return
    // Editors keep selection/caret keys even if Qt leaves one unaccepted.
    // ReadmeDocument explicitly opts in only for unmodified, unselected text.
    if (!readmeReading && Navigation.textEditing(root.Window.window ? root.Window.window.activeFocusItem : null)) return
    var flick = view.contentItem
    var start = Number(flick.originY) || 0
    var end = start + Math.max(0, flick.contentHeight - flick.height)
    var step = key === Qt.Key_PageUp || key === Qt.Key_PageDown ? flick.height : Math.round(controlMetrics.height * 2.5)
    var y = key === Qt.Key_Home ? start : key === Qt.Key_End ? end
      : flick.contentY + (key === Qt.Key_Up || key === Qt.Key_PageUp ? -step : step)
    flick.cancelFlick()
    flick.contentY = Math.max(start, Math.min(y, end))
    dismissMetricHelp()
    // Own the key at the boundary too; it must not scroll another pane.
    event.accepted = true
  }
  function focusTargets() {
    return {close:backButton, primary:primaryButton, actions:removeButton, uninstall:removeButton,
      enabled:enabledSwitch, source:sourceButton, marketplace:marketplaceButton, batch:batchButton,
      update:updateButton, updateCheck:updateCheckButton}
  }
  function focusName() {
    var targets = focusTargets()
    for (var key in targets) if (targets[key].activeFocus) return key
    for (var i = 0; i < positionButtons.count; i++)
      if (positionButtons.itemAt(i).activeFocus) return "position." + positionButtons.itemAt(i).modelData
    return "close"
  }
  function restorePosition(y, focus) {
    savedScroll = Math.max(0, Number(y) || 0)
    if (!active || pluginRow.readmeLoading === true) scrollRestorePending = true
    if (!active) return
    contentScroll.contentItem.contentY = Math.max(0, Math.min(Number(y) || 0,
      contentScroll.contentItem.contentHeight - contentScroll.height))
    if (!visible) return
    var target = focusTargets()[focus]
    if (String(focus).indexOf("position.") === 0)
      target = positionButtons.itemAt(["left", "center", "right"].indexOf(String(focus).slice(9)))
    if (target && target.visible && target.enabled) target.forceActiveFocus()
    else takeFocus()
  }
  function resetView() {
    dismissMetricHelp()
    stopMedia()
    matchingExpanded = false
    documentationExpanded = true
    descriptionExpanded = false
    selectedMedia = 0
    fullSize.close()
    savedScroll = 0
    contentScroll.contentItem.contentY = 0
  }
  onIdentityChanged: resetView()
  onVisibleChanged: if (!visible) { dismissMetricHelp(); stopMedia() }
  Window.onActiveChanged: {
    if (!Window.active) {
      metricWindowRestoring = true
      dismissMetricHelp()
    } else {
      // Window activation restores activeFocus before the next event turn.
      Qt.callLater(function() { root.metricWindowRestoring = !root.Window.active })
    }
  }
  Keys.priority: Keys.AfterItem
  Keys.onEscapePressed: {
    if (root.dismissMetricHelp()) return
    if (fullSize.visible) fullSize.close()
    else root.backRequested()
  }
  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Left && (event.modifiers & Qt.AltModifier)) {
      root.backRequested()
      event.accepted = true
    } else root.scrollPane(event, root.dockRecommendation
      && Navigation.contains(recommendationScroll, root.Window.window ? root.Window.window.activeFocusItem : null)
        ? recommendationScroll : contentScroll, false)
  }

  component Copy: Text {
    textFormat: Text.PlainText
    color: root.foreground
    font.family: Style.font.family
    font.pixelSize: root.readingSize
    wrapMode: Text.WordWrap
  }
  component Caption: Copy {
    color: root.muted
    font.pixelSize: root.supportingSize
  }
  component Metric: Item {
    id: metric
    required property var modelData
    property bool score: false
    objectName: "detailMetric." + modelData.key
    implicitWidth: Math.ceil(Math.max(metricValue.implicitWidth, metricLabel.implicitWidth))
    implicitHeight: metricCopy.implicitHeight
    width: implicitWidth
    height: implicitHeight
    activeFocusOnTab: true
    Accessible.role: Accessible.StaticText
    Accessible.name: modelData.label + " " + root.count(modelData.value)
    Accessible.description: tip.text
    Accessible.onPressAction: showHelp(true)
    function closeHelp() { tip.close() }
    function showHelp(immediate) {
      if (!root.visible || !metric.visible || !root.Window.active) return
      if (root.activeMetricHelp !== metric) root.dismissMetricHelp()
      root.activeMetricHelp = metric
      // Explicit requests, rather than a focus/hover visibility binding, allow
      // Escape and pointer leave to dismiss help while focus stays on the metric.
      tip.delay = immediate ? 0 : 350
      tip.open()
    }
    onActiveFocusChanged: {
      if (!activeFocus) {
        if (root.activeMetricHelp === metric) root.dismissMetricHelp()
        return
      }
      if (root.metricWindowRestoring) return
      var flick = contentScroll.contentItem
      var position = metric.mapToItem(flick, 0, 0)
      if (position.y < 0) flick.contentY += position.y
      else if (position.y + height > flick.height) flick.contentY += position.y + height - flick.height
      showHelp(true)
    }
    Component.onDestruction: {
      if (root.activeMetricHelp === metric) root.activeMetricHelp = null
      if (root.hoveredMetricHelp === metric) root.hoveredMetricHelp = null
    }
    Keys.onReturnPressed: showHelp(true)
    Keys.onEnterPressed: showHelp(true)
    Keys.onSpacePressed: showHelp(true)
    HoverHandler { id: metricHover }
    MouseArea {
      anchors.fill: parent
      onWheel: function(event) { event.accepted = false }
      // Accept the helper click without transferring mouse focus or navigating.
      onClicked: function(mouse) {
        root.metricPointerPosition = metric.mapToItem(null, mouse.x, mouse.y)
        root.hoveredMetricHelp = metric
        metric.showHelp(true)
      }
    }
    Rectangle {
      anchors.fill: parent
      anchors.margins: -Style.space(2)
      color: "transparent"
      border.color: Color.accent
      radius: Style.space(2)
      visible: metric.activeFocus
    }
    Column {
      id: metricCopy
      spacing: Style.space(2)
      Copy {
        id: metricValue
        objectName: "detailMetricValue." + metric.modelData.key
        text: root.count(metric.modelData.value)
        wrapMode: Text.NoWrap
        font.pixelSize: root.valueSize
        font.bold: true
        color: metric.score ? Color.accent : root.foreground
      }
      Row {
        id: metricLabel
        spacing: Style.space(4)
        Caption {
          objectName: "detailMetricLabel." + metric.modelData.key
          text: metric.modelData.label
          wrapMode: Text.NoWrap
          anchors.verticalCenter: parent.verticalCenter
        }
        Loader {
          id: info
          objectName: "detailMetricInfo." + metric.modelData.key
          active: metric.score
          visible: active
          width: root.iconSize; height: root.iconSize
          sourceComponent: OutfitIcon {
            kind: "info"
            tint: metric.activeFocus || metricHover.hovered ? Color.accent : root.muted
          }
        }
      }
    }
    C.ToolTip {
      id: tip
      objectName: "detailMetricTip." + metric.modelData.key
      parent: metric
      popupType: C.Popup.Item
      // Escape is handled by the page before its back action. Outside clicks
      // close this nonmodal popup and still reach the intended page control.
      closePolicy: C.Popup.CloseOnPressOutside
      timeout: -1
      onClosed: if (root.activeMetricHelp === metric) root.activeMetricHelp = null
      property point origin: Qt.point(0, 0)
      onAboutToShow: origin = metric.mapToItem(root, 0, 0)
      x: Math.max(Style.space(12), Math.min(origin.x, root.width - width - Style.space(12))) - origin.x
      y: Math.max(Style.space(12), Math.min(origin.y + metric.height + Style.space(6),
        root.height - height - Style.space(12))) - origin.y
      text: metric.modelData.help + " An em dash means unavailable; 0 means a reported zero."
      width: Math.min(Style.space(340), root.width - Style.space(24))
      padding: Style.space(10)
      margins: Style.space(12)
      contentItem: Caption {
        text: tip.text
        wrapMode: Text.Wrap
        color: root.foreground
      }
      background: BorderSurface {
        color: Color.background
        radius: Style.cornerRadius
        borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
      }
    }
  }
  component Action: Button {
    focusable: true
    foreground: root.foreground
    fontSize: root.readingSize
    horizontalPadding: Style.space(12)
    verticalPadding: Style.space(root.compact && root.shortWindow ? 5 : 7)
    opacity: enabled ? 1 : 0.45
    Accessible.role: Accessible.Button
    Accessible.name: text
    Accessible.onPressAction: if (enabled) clicked()
  }
  component Rule: Rectangle {
    implicitHeight: Style.space(1)
    color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
  }
  component StateSwitch: Toggle {
    id: stateSwitch
    readonly property real minimumLabelWidth: Math.ceil(root.controlTextWidth(stateSwitch.label) + root.toggleChromeWidth
      + Math.max(Style.space(4), (Number(stateSwitch.borderLeft) || 0) + (Number(stateSwitch.borderRight) || 0)))
    titleSize: root.readingSize
    descriptionSize: root.supportingSize
    implicitHeight: Math.max(Style.space(40), controlMetrics.height + Style.space(14))
    foreground: root.foreground
    accent: Color.accent
    opacity: enabled ? 1 : 0.45
    Accessible.role: Accessible.CheckBox
    Accessible.name: label
    Accessible.checkable: true
    Accessible.checked: checked
    Accessible.onToggleAction: if (enabled) clicked()
  }

  Rectangle {
    anchors.fill: parent
    color: Color.background
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.AllButtons
      onWheel: function(event) { event.accepted = true }
    }
  }
  // One centered reading area; related controls stay close on ultrawide screens.
  Item {
    id: frame
    width: Math.min(parent.width, Style.space(1340))
    height: parent.height
    anchors.horizontalCenter: parent.horizontalCenter

    Column {
      id: heading
      width: parent.width
      spacing: Style.space(9)
      Item {
        width: parent.width
        height: Math.max(backButton.height, links.height)
        Action {
          id: backButton
          objectName: "detailBack"
          text: "‹ " + root.backLabel
          bordered: true
          onClicked: root.backRequested()
        }
        Action {
          objectName: "detailPrototypePicker"
          anchors.left: backButton.right
          anchors.leftMargin: Style.space(12)
          anchors.verticalCenter: parent.verticalCenter
          visible: Boolean(root.prototypeLabel)
          text: root.prototypeLabel
          fontSize: root.readingSize
          foreground: Color.accent
          onClicked: root.prototypeRequested()
        }
        Row {
          id: links
          anchors.right: parent.right
          spacing: Style.space(8)
          Action {
            id: sourceButton
            objectName: "detailSource"
            text: "View source ↗"
            bordered: true
            enabled: root.pluginRow.sourceAvailable === true
            onClicked: root.sourceRequested()
          }
          Action {
            id: marketplaceButton
            objectName: "detailMarketplace"
            text: root.compact ? "Marketplace ↗" : "Marketplace listing ↗"
            bordered: true
            enabled: root.pluginRow.marketplaceAvailable === true
            onClicked: root.marketplaceRequested()
          }
        }
      }
      Copy {
        objectName: "detailTitle"
        width: parent.width
        text: root.pluginRow.name || root.pluginRow.id || "Plugin details"
        font.pixelSize: Math.max(Style.font.title, root.readingSize * 1.6)
        font.bold: true
        maximumLineCount: 2
        elide: Text.ElideRight
        Accessible.name: text
      }
      Flow {
        width: parent.width
        spacing: Style.space(12)
        Caption {
          width: Math.min(metadataMetrics.advanceWidth(text) + Style.space(2), heading.width)
          text: [root.pluginRow.author ? "By " + root.pluginRow.author : "",
            root.pluginRow.kind || "Plugin", root.pluginRow.version ? "Catalog v" + root.pluginRow.version : ""].filter(function(v) { return v }).join("  ·  ")
          maximumLineCount: 1
          elide: Text.ElideRight
        }
        Caption {
          text: root.pluginRow.verification === "verified" ? "✓ Marketplace verified"
            : root.pluginRow.verification === "unverified" ? "Not marketplace verified" : "Verification not reported"
          color: root.pluginRow.verification === "verified" ? Color.accent : root.muted
        }
      }
      Rule { width: parent.width }
    }

    ContentScrollView {
      id: contentScroll
      objectName: "detailContentScroll"
      anchors.top: heading.bottom
      anchors.topMargin: root.gutter
      anchors.left: parent.left
      anchors.right: root.compact ? parent.right : controlPanel.left
      anchors.rightMargin: root.compact ? 0 : root.gutter
      anchors.bottom: root.compact ? controlPanel.top : parent.bottom
      anchors.bottomMargin: root.compact ? Style.space(12) : 0
      clip: true
      contentWidth: availableWidth
      C.ScrollBar.horizontal.policy: C.ScrollBar.AlwaysOff
      Connections {
        target: contentScroll.contentItem
        function onContentYChanged() {
          root.dismissMetricHelp()
          if (root.active && !root.scrollRestorePending) root.savedScroll = Number(contentScroll.contentItem.contentY || 0)
        }
        function onContentHeightChanged() {
          if (root.active && root.scrollRestorePending) detailScrollRestore.restart()
        }
      }

      Column {
        id: content
        width: contentScroll.availableWidth
        spacing: Style.space(12)
        // Children get first refusal; handle before ScrollView's built-in
        // percentage-based arrow scrolling so line/page steps stay consistent.
        Keys.priority: Keys.AfterItem
        Keys.onPressed: function(event) {
          root.scrollPane(event, contentScroll, false)
          // Also shield unhandled editor/modified navigation from ScrollView's
          // default key handler. The focused control has already had its turn.
          if (root.isScrollKey(event.key)) event.accepted = true
        }

        Item {
          id: overview
          readonly property bool beside: root.compact && root.shortWindow && root.hasMedia
          width: parent.width
          height: beside ? Math.max(overviewSummary.height, gallery.height)
            : overviewSummary.height + (gallery.visible ? gallery.height + Style.space(18) : 0)
          Column {
            id: overviewSummary
            x: overview.beside ? overview.width * 0.42 + Style.space(12) : 0
            width: overview.beside ? overview.width - x : overview.width
            spacing: Style.space(root.compact ? 12 : 18)
            Column {
              width: parent.width
              spacing: Style.space(5)
              Copy {
                id: description
                objectName: "detailDescription"
                width: parent.width
                text: root.pluginRow.description || "No description has been supplied for this plugin."
                font.pixelSize: root.readingSize
                maximumLineCount: root.descriptionExpanded ? 100 : 3
                elide: Text.ElideRight
              }
              Action {
                visible: description.truncated || root.descriptionExpanded
                text: root.descriptionExpanded ? "Less" : "Read more"
                onClicked: root.descriptionExpanded = !root.descriptionExpanded
              }
            }

            BorderSurface {
              id: metricBlock
              objectName: "detailMetrics"
              width: parent.width
              readonly property real padding: Style.space(12)
              height: metricContent.implicitHeight + padding * 2
              color: root.faint
              radius: Style.cornerRadius
              borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
              Flow {
                id: metricContent
                // Keep the existing lookup name; scores now share this Flow
                // with all four counts, rather than reserving a second row.
                objectName: "detailScores"
                x: metricBlock.padding
                y: metricBlock.padding
                width: parent.width - metricBlock.padding * 2
                spacing: Style.space(12)
                Repeater {
                  model: root.metrics
                  Metric {}
                }
                Repeater {
                  model: root.scores
                  Metric { score: true }
                }
              }
            }
          }

          Column {
            id: gallery
            objectName: "detailGallery"
            visible: root.hasMedia
            width: overview.beside ? overview.width * 0.42 : overview.width
            y: overview.beside ? 0 : overviewSummary.height + Style.space(18)
            spacing: Style.space(8)
            Loader {
              id: mediaSlot
              width: parent.width
              height: item ? item.implicitHeight : 0
              active: root.active && root.mediaComponent !== null
              sourceComponent: root.mediaComponent
            }
            Column {
              width: parent.width
              visible: root.mediaComponent === null
              spacing: Style.space(8)
            BorderSurface {
              width: parent.width
              height: Math.max(0, Math.min(width * 9 / 16, contentScroll.height,
                Style.space(overview.beside ? 130 : root.shortWindow ? 210 : 310)))
              color: root.faint
              radius: Style.cornerRadius
              borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
              Image {
                id: preview
                objectName: "detailPreview"
                anchors.fill: parent
                anchors.margins: Style.space(1)
                source: root.mediaActive && visible ? root.currentMedia.source || "" : ""
                sourceSize.width: root.imageBucket(width)
                sourceSize.height: root.imageBucket(height)
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                onStatusChanged: if (status === Image.Error) root.invalidateImage(source)
                activeFocusOnTab: status === Image.Ready || activeFocus
                onActiveFocusChanged: {
                  if (!activeFocus) return
                  var flick = contentScroll.contentItem
                  var position = preview.mapToItem(flick, 0, 0)
                  if (position.y < 0) flick.contentY += position.y
                  else if (position.y + height > flick.height) flick.contentY += position.y + height - flick.height
                }
                signal clicked()
                onClicked: if (status === Image.Ready) fullSize.open()
                Keys.onReturnPressed: clicked()
                Keys.onEnterPressed: clicked()
                Keys.onSpacePressed: clicked()
                Accessible.role: Accessible.Button
                Accessible.name: String(root.currentMedia.title || "Plugin preview") + ". Open full-size preview"
                Accessible.description: "Click or press Enter or Space to enlarge. Escape closes the preview."
                Accessible.onPressAction: clicked()
                MouseArea {
                  anchors.fill: parent
                  enabled: preview.status === Image.Ready
                  cursorShape: Qt.PointingHandCursor
                  onClicked: preview.clicked()
                }
                HoverHandler { id: previewHover }
                Rectangle {
                  anchors.fill: parent
                  color: "transparent"
                  border.color: Color.accent
                  border.width: Style.space(2)
                  visible: preview.activeFocus
                }
                C.ToolTip {
                  id: previewTip
                  objectName: "detailPreviewTip"
                  visible: root.visible && !fullSize.visible && preview.status === Image.Ready
                    && (previewHover.hovered || preview.activeFocus)
                  delay: preview.activeFocus ? 0 : 350
                  text: "Click or press Enter / Space to enlarge; Escape to close"
                  width: Math.min(Style.space(380), preview.width)
                  contentItem: Caption { text: previewTip.text; wrapMode: Text.Wrap }
                }
              }
              Caption {
                anchors.centerIn: parent
                visible: preview.status === Image.Error
                text: "Preview unavailable"
              }
            }
            Caption {
              width: parent.width
              text: String(root.currentMedia.caption || "")
              maximumLineCount: overview.beside ? 2 : 10
              elide: Text.ElideRight
            }
            Flow {
              width: parent.width
              spacing: Style.space(8)
              Repeater {
                model: root.active ? root.mediaItems : []
                Action {
                  required property var modelData
                  required property int index
                  objectName: "detailMedia." + index
                  text: String(index + 1)
                  selected: index === root.selectedMedia
                  bordered: true
                  Accessible.name: "Preview " + (index + 1) + ": " + modelData.title
                  onClicked: root.selectedMedia = index
                }
              }
            }
            }
          }
        }
        BorderSurface {
          visible: !root.hasMedia
          width: parent.width
          height: emptyPreview.implicitHeight + Style.space(24)
          radius: Style.cornerRadius
          color: root.faint
          Caption {
            id: emptyPreview
            anchors.fill: parent
            anchors.margins: Style.space(12)
            text: root.pluginRow.kind === "Service"
              ? "Background service · This plugin works without a window or panel."
              : "No preview available for this listing."
          }
        }

        Column {
          visible: Boolean(root.pluginRow.summary || root.pluginRow.requirements)
          width: parent.width
          spacing: Style.space(8)
          Copy {
            visible: Boolean(text)
            width: parent.width
            text: root.pluginRow.summary || ""
            maximumLineCount: 4
            elide: Text.ElideRight
          }
          Caption { visible: Boolean(text); width: parent.width; text: root.pluginRow.requirements ? "Requirements: " + root.pluginRow.requirements : "" }
        }

        Rule { width: parent.width }
        Component {
          id: matchingComponent
        Column {
          width: parent.width
          spacing: Style.space(8)
          Column {
            objectName: "detailVersionSection"
            visible: root.presentation.showVersions === true
            width: parent.width
            spacing: Style.space(6)
            Caption { text: "VERSION"; font.bold: true; font.letterSpacing: 1 }
            Copy {
              objectName: "detailVersions"
              width: parent.width
              text: "Installed: " + InspectorState.versionLabel(root.presentation.installedVersion, root.presentation.installedRevision)
                + (root.presentation.updateState === "customized" ? " · Local edits" : "")
                + (root.presentation.availableVersion || root.presentation.availableRevision
                  ? (root.presentation.updateState === "customized" ? "\nUpstream: " : "\nAvailable: ")
                    + InspectorState.versionLabel(root.presentation.availableVersion, root.presentation.availableRevision)
                  : root.presentation.updateState === "customized" ? "\nUpstream version unavailable" : "")
                + (root.presentation.updateState !== "customized" && root.presentation.availableRevision
                  && root.presentation.installedVersion && root.presentation.installedVersion === root.presentation.availableVersion
                  && root.presentation.installedRevision !== root.presentation.availableRevision ? " · New changes" : "")
              Accessible.role: Accessible.StaticText
              Accessible.name: text
            }
            Caption { width: parent.width; text: root.presentation.updateStatus || "Update status unknown" }
            Rule { width: parent.width }
          }
          Flow {
            width: parent.width
            spacing: Style.space(8)
            Action {
              objectName: "detailMatchingDisclosure"
              text: (root.matchingExpanded ? "▾ " : "▸ ") + "Why recommended"
              onClicked: root.matchingExpanded = !root.matchingExpanded
              Accessible.name: text + (root.matchingExpanded ? ", expanded" : ", collapsed")
            }
            Caption {
              visible: Boolean(text)
              text: root.pluginRow.matchLabel || ""
              height: Style.space(32)
              verticalAlignment: Text.AlignVCenter
              color: Color.accent
            }
            Action {
              objectName: "detailReview"
              visible: root.pluginRow.matchUnread === true
              text: "Mark reviewed"
              bordered: true
              onClicked: root.reviewRequested()
            }
          }
          Copy {
            objectName: "detailMatchingContent"
            visible: root.matchingExpanded
            width: parent.width
            text: root.pluginRow.matchReason || "No specific match evidence is available."
          }
        }
        }
        Loader {
          objectName: "inlineRecommendationLoader"
          width: parent.width
          active: !root.dockRecommendation
          visible: active
          height: item ? item.implicitHeight : 0
          sourceComponent: matchingComponent
        }
        Column {
          width: parent.width
          spacing: Style.space(8)
          Action {
            objectName: "detailDocumentationDisclosure"
            text: (root.documentationExpanded ? "▾ " : "▸ ") + "Read documentation"
            enabled: Boolean(root.pluginRow.readmeText) || root.pluginRow.readmeAvailable === true
              || (Array.isArray(root.pluginRow.readmeBlocks) && root.pluginRow.readmeBlocks.length > 0)
            onClicked: {
              root.documentationExpanded = !root.documentationExpanded
              if (root.documentationExpanded) root.documentationRequested()
            }
            Accessible.name: text + (root.documentationExpanded ? ", expanded" : ", collapsed")
          }
          ReadmeDocument {
            visible: root.documentationExpanded
            width: parent.width
            blocks: root.active && root.documentationExpanded ? root.pluginRow.readmeBlocks || [] : []
            plainText: root.active && root.documentationExpanded ? root.pluginRow.readmeText || "" : ""
            loading: root.pluginRow.readmeLoading === true
            enrichmentEnabled: root.pluginRow.readmeEnrichment !== false
            onScrollRequested: function(event) { root.scrollPane(event, contentScroll, true) }
            onLinkRequested: function(url) { Qt.openUrlExternally(url) }
          }
        }
        Caption {
          width: parent.width
          text: root.pluginRow.reviewText || ""
          visible: root.documentationExpanded && Boolean(text)
        }
        Item { width: 1; height: Style.space(12) }
      }
    }

    ContentScrollView {
      id: recommendationScroll
      objectName: "detailRecommendationScroll"
      visible: root.dockRecommendation
      anchors.top: controlPanel.bottom
      anchors.topMargin: root.gutter
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      width: controlPanel.width
      contentHeight: recommendationContent.implicitHeight
      clip: true
      Column {
        id: recommendationContent
        width: recommendationScroll.availableWidth
        spacing: Style.space(8)
        Keys.priority: Keys.AfterItem
        Keys.onPressed: function(event) {
          root.scrollPane(event, recommendationScroll, false)
          if (root.isScrollKey(event.key)) event.accepted = true
        }
        Loader {
          width: parent.width
          active: root.dockRecommendation
          visible: active
          height: item ? item.implicitHeight : 0
          sourceComponent: matchingComponent
        }
      }
    }

    BorderSurface {
      id: controlPanel
      objectName: "detailControls"
      anchors.right: parent.right
      y: root.compact ? parent.height - height : heading.height + root.gutter
      width: root.compact ? parent.width : Math.max(Style.space(288), root.controlLabelWidth + Style.space(32))
      height: controls.implicitHeight + Style.space(root.compact ? 20 : 32)
      color: root.faint
      radius: Style.cornerRadius
      borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)

      Column {
        id: controls
        x: Style.space(root.compact ? 10 : 16)
        y: x
        width: parent.width - x * 2
        spacing: Style.space(root.tallCompact ? 14 : root.compact ? 8 : 14)

        Item {
          id: controlGroups
          width: parent.width
          readonly property real groupGap: Style.space(root.shortWindow ? 12 : 20)
          readonly property bool beside: root.compact && width >= settingsRow.width + primaryRow.width + groupGap
          height: beside ? Math.max(settingsRow.height, primaryRow.height)
            : primaryRow.height + (settingsRow.visible ? groupGap + settingsRow.height : 0)

        Column {
          id: primaryRow
          objectName: "detailPrimaryRow"
          x: controlGroups.beside && settingsRow.visible ? settingsRow.width + controlGroups.groupGap : 0
          width: root.compact ? Math.min(parent.width, Math.max(primaryButton.implicitWidth,
            batchButton.visible ? batchButton.implicitWidth : 0,
            updateCheckButton.visible ? updateCheckButton.implicitWidth : 0,
            updateButton.visible ? updateButton.implicitWidth : 0,
            primaryButton.visible && updateButton.visible ? primaryButton.implicitWidth + updateButton.implicitWidth + Style.space(8) : 0,
            removeButton.visible ? removeButton.implicitWidth : 0,
            root.controlTextWidth(root.localState) + Style.space(4))) : parent.width
          spacing: Style.space(root.compact && root.shortWindow ? 6 : 8)
          Column {
            width: primaryRow.width
            spacing: Style.space(4)
            Caption { visible: !root.compact; text: "ON YOUR COMPUTER"; font.bold: true; font.letterSpacing: 1 }
            Copy {
              objectName: "detailLocalState"
              width: parent.width
              text: root.localState
              color: Color.accent
              font.bold: true
              font.pixelSize: root.readingSize
            }
          }
          Flow {
            id: primaryActions
            width: primaryRow.width
            spacing: Style.space(8)
            readonly property bool beside: root.compact && primaryButton.visible && updateButton.visible
              && width >= primaryButton.implicitWidth + updateButton.implicitWidth + spacing
            Action {
              id: primaryButton
              objectName: "detailPrimary"
              visible: Boolean(root.presentation.primaryLabel)
              width: primaryActions.beside ? implicitWidth : primaryRow.width
              text: root.presentation.primaryLabel || ""
              selected: true
              bordered: true
              enabled: root.presentation.primaryEnabled === true
              onClicked: root.primaryRequested()
            }
            Action {
              id: updateButton
              objectName: "detailUpdate"
              visible: root.presentation.showUpdate === true
              width: primaryActions.beside ? primaryActions.width - primaryButton.width - primaryActions.spacing : primaryRow.width
              text: root.presentation.updateLabel || "Update"
              bordered: true
              enabled: root.presentation.canUpdate === true
              onClicked: root.updateRequested()
            }
          }
          Action {
            id: updateCheckButton
            objectName: "detailUpdateCheck"
            visible: root.presentation.showUpdateCheck === true
            width: primaryRow.width
            text: root.presentation.updatesBusy ? "Checking for updates…" : "Check for updates"
            enabled: root.presentation.canCheckUpdates === true
            bordered: true
            onClicked: root.updateCheckRequested()
          }
          Action {
            id: batchButton
            objectName: "detailBatch"
            visible: root.presentation.canQueue === true
            width: primaryRow.width
            text: root.presentation.selected ? "Remove from batch" : "Add to batch install"
            bordered: true
            enabled: root.presentation.canQueue === true
            onClicked: root.queueRequested()
          }
          Action {
            id: removeButton
            bordered: true
            objectName: "detailUninstall"
            visible: root.presentation.installed && ("showRemove" in root.presentation ? root.presentation.showRemove : !root.presentation.exclusive)
            width: primaryRow.width
            text: "Uninstall plugin…"
            foreground: root.muted
            enabled: root.presentation.canRemove === true
            onClicked: root.removeRequested()
          }
        }

        Column {
          id: settingsRow
          objectName: "detailSettingsRow"
          visible: root.installOptions || root.presentation.widget === true
            || (root.presentation.installed && !root.presentation.exclusive && root.presentation.showToggle !== false)
          y: controlGroups.beside ? 0 : primaryRow.height + controlGroups.groupGap
          width: root.compact ? Math.min(parent.width, Math.max(root.controlLabelWidth, root.placementWidth)) : parent.width
          spacing: Style.space(root.shortWindow ? 6 : 10)
          StateSwitch {
            id: enabledSwitch
            objectName: "detailEnabled"
            visible: root.presentation.installed && !root.presentation.exclusive && root.presentation.showToggle !== false
            width: settingsRow.width
            label: "Enabled"
            checked: root.presentation.enabled === true
            enabled: root.presentation.canToggle === true
            onClicked: if (enabled) root.enabledRequested()
          }
          StateSwitch {
            id: installSwitch
            objectName: "detailInstallEnabled"
            visible: root.installOptions
            width: settingsRow.width
            label: root.presentation.exclusive ? "Activate after install" : "Enable after install"
            checked: root.installEnabled
            enabled: root.presentation.primaryEnabled === true
            onClicked: if (enabled) root.installEnabledRequested()
          }
          Column {
            id: placement
            objectName: "detailPlacement"
            visible: root.presentation.widget === true
            width: settingsRow.width
            spacing: Style.space(4)
            Caption {
              width: parent.width
              text: root.presentation.installed && !root.presentation.enabled
                ? "Position when enabled" : "Bar position"
            }
            Row {
              width: parent.width
              spacing: Style.space(4)
              Repeater {
                id: positionButtons
                model: ["left", "center", "right"]
                Action {
                  required property string modelData
                  objectName: "detailPosition." + modelData
                  width: (parent.width - Style.space(8)) / 3
                  horizontalPadding: Style.space(6)
                  text: modelData.charAt(0).toUpperCase() + modelData.slice(1)
                  selected: String(root.presentation.section || root.installSection) === modelData
                  bordered: true
                  enabled: root.presentation.canPlace === true
                  onClicked: root.sectionRequested(modelData)
                }
              }
            }
          }
        }
        }
        Caption {
          objectName: "detailOperationMessage"
          visible: Boolean(text)
          width: parent.width
          text: root.statusMessage
          color: root.presentation.failed ? Color.urgent : root.muted
          maximumLineCount: root.compact ? 2 : 5
          elide: Text.ElideRight
        }
        Action {
          visible: root.statusMessage && operationCopy.truncated
          text: "Show details"
          onClicked: operationDetails.open()
        }
        // Measure independently so the full diagnostic remains reachable when
        // the compact tray limits the visible status to two lines.
        Caption {
          id: operationCopy
          visible: false
          width: parent.width
          text: root.statusMessage
          maximumLineCount: root.compact ? 2 : 5
          elide: Text.ElideRight
        }
      }
    }
  }

  C.Popup {
    id: fullSize
    objectName: "detailFullSizePopup"
    parent: root
    popupType: C.Popup.Item
    x: 0; y: 0
    width: root.width; height: root.height
    padding: Style.space(16)
    modal: true
    focus: true
    closePolicy: C.Popup.CloseOnEscape
    onOpened: closePreview.forceActiveFocus()
    onClosed: if (root.mediaActive) preview.forceActiveFocus()
    background: BorderSurface { color: Color.background; radius: Style.cornerRadius }
    contentItem: Item {
      Action {
        id: closePreview
        anchors.top: parent.top
        anchors.right: parent.right
        text: "Close preview"
        bordered: true
        onClicked: fullSize.close()
      }
      Image {
        objectName: "detailFullSizeImage"
        anchors.top: closePreview.bottom
        anchors.topMargin: Style.space(12)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        source: root.mediaActive && fullSize.visible ? root.currentMedia.source || "" : ""
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        sourceSize.width: root.imageBucket(width)
        sourceSize.height: root.imageBucket(height)
        onStatusChanged: if (status === Image.Error) root.invalidateImage(source)
      }
    }
  }
  C.Popup {
    id: operationDetails
    parent: root
    popupType: C.Popup.Item
    x: (root.width - width) / 2
    y: (root.height - height) / 2
    width: Math.min(Style.space(480), root.width - Style.space(32))
    padding: Style.space(20)
    modal: true
    focus: true
    closePolicy: C.Popup.CloseOnEscape | C.Popup.CloseOnPressOutside
    background: BorderSurface { color: Color.background; radius: Style.cornerRadius; borderSpec: Border.controlSpec("normal", root.foreground, Color.accent) }
    contentItem: Column {
      spacing: Style.space(16)
      Copy { width: parent.width; text: root.statusMessage }
      Action { text: "Close"; bordered: true; onClicked: operationDetails.close() }
    }
  }
}
