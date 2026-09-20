import QtQuick
import qs.Commons
import qs.Ui

// Bar entry point for Fresh Tube: the icon, the count of new videos, and the
// timer that keeps that count fresh. The panel owns everything else.
BarWidget {
  id: root
  moduleName: "io.github.ferc10110.fresh-tube"

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool pinned: panelLoader.item ? panelLoader.item.pinned === true : false
  readonly property int count: panelLoader.item && panelLoader.item.videos ? panelLoader.item.videos.length : 0
  // Forwarded so this widget can stand in for the panel as the bar's popout identity.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  readonly property int refreshMs: Math.max(1, Number(setting("refreshMinutes", 15)) || 15) * 60000

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }

  // The bar closes the open popout when another one opens. A pinned panel stays.
  function closeForPopoutSwitch() {
    if (panelLoader.item && !pinned) panelLoader.item.closeForPopoutSwitch()
  }

  function refresh() { if (panelLoader.item) panelLoader.item.refresh() }
  function reloadCached() { if (panelLoader.item) panelLoader.item.reloadCached() }

  // One widget per monitor, but the feeds only need fetching once: the first
  // instance polls and, through broadcast, tells the others to reread the cache.
  function isPoller() {
    var items = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : []
    return items.length === 0 || items[0] === root
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // A first real fetch shortly after the shell starts, then every refreshMinutes.
  Timer {
    interval: 5000
    running: true
    repeat: false
    onTriggered: if (root.isPoller()) root.refresh()
  }

  Timer {
    interval: root.refreshMs
    running: true
    repeat: true
    onTriggered: if (root.isPoller()) root.refresh()
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.count > 0 ? "󰗃 " + root.count : "󰗃"
    fontSize: Style.font.bodySmall
    horizontalMargin: 6
    dimmed: root.count === 0
    tooltipText: root.count === 0 ? "Nothing new" : (root.count === 1 ? "1 new video" : root.count + " new videos")
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }
  }
}
