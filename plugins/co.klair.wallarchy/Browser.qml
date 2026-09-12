import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Fullscreen browser overlay: search, category and tag filters, a thumbnail
// grid, and the rotation controls.
//
// Thumbnails are loaded straight from Wallhaven's CDN by QML's Image loader.
// Only a wallpaper the user actually applies gets downloaded to disk.
Item {
  id: root

  // Injected by omarchy-shell when the overlay is summoned.
  property var shell: null
  property var manifest: null

  property bool opened: false
  property bool loading: false
  property bool applying: false
  property string errorText: ""

  property string filterText: ""
  property string query: ""
  property string categories: "100"
  property string sorting: "toplist"
  property string atleast: "1920x1080"
  property int rotateMinutes: 0
  property int page: 1
  property int selectedIndex: 0

  // Signature of the config values that determine what the grid shows. The
  // config file is a shared surface — the CLI and the bar widget write it too
  // — so the watcher, not the click handler, is what decides to re-query.
  property string filterSignature: ""

  readonly property string cliPath: Qt.resolvedUrl("wallarchy").toString().replace(/^file:\/\//, "")
  readonly property string pluginId: (manifest && manifest.id) || "co.klair.wallarchy"

  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color borderColor: Color.menu.border
  readonly property color scrim: Color.menu.scrim
  readonly property color accent: Color.accent

  readonly property int cardWidth: Math.min(Style.space(1100), panel.width - Style.gapsOut * 4)
  readonly property int cardHeight: Math.min(Style.space(760), panel.height - Style.gapsOut * 4)

  // ------------------------------------------------------------- lifecycle

  function open(payloadJson) {
    opened = true
    errorText = ""
    selectedIndex = 0
    if (photoModel.count === 0) loadPage()
    Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  function close() {
    opened = false
  }

  function dismiss() {
    close()
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
  }

  // ------------------------------------------------------------- config io

  function applyConfig(raw) {
    var config = Model.parseJson(raw, {}, 65536)
    query = typeof config.query === "string" ? config.query : ""
    categories = Model.normalizeBits(config.categories || "100")
    sorting = typeof config.sorting === "string" && config.sorting !== "" ? config.sorting : "toplist"
    atleast = typeof config.atleast === "string" ? config.atleast : ""
    var minutes = Number(config.rotateMinutes)
    rotateMinutes = isFinite(minutes) && minutes > 0 ? Math.round(minutes) : 0

    // Toggling rotation must not throw away a grid the user is scrolling, so
    // only a change to the query-shaping values counts as a reason to reload.
    var signature = [query, categories, sorting, atleast].join("|")
    var changed = filterSignature !== "" && filterSignature !== signature
    filterSignature = signature

    // Don't yank the field out from under someone mid-type; the config file
    // is only authoritative for the search box while it is unfocused.
    if (!searchField.activeFocus) {
      filterText = query
      searchField.text = query
    }

    if (changed) reload()
  }

  // Config changes are written through the CLI rather than edited in place, so
  // the file has exactly one writer and the service's watcher sees a complete
  // document instead of a half-written one.
  property var configQueue: []

  function setConfig(key, value) {
    configQueue.push({ key: key, value: String(value) })
    drainConfigQueue()
  }

  function drainConfigQueue() {
    if (configProcess.running || configQueue.length === 0) return
    var job = configQueue.shift()
    configProcess.command = [root.cliPath, "config", "set", job.key, job.value]
    configProcess.running = true
  }

  // --------------------------------------------------------------- loading

  function reload() {
    page = 1
    photoModel.clear()
    selectedIndex = 0
    loadPage()
  }

  function loadPage() {
    if (photoProcess.running) return
    loading = true
    errorText = ""
    photoProcess.command = [root.cliPath, "photos", String(page)]
    photoProcess.running = true
  }

  function loadMore() {
    if (loading || photoModel.count === 0 || page >= 30) return
    page += 1
    loadPage()
  }

  function applyPhotos(raw) {
    var rows = Model.photoRows(Model.parseJson(raw, [], 4194304))
    if (rows.length === 0 && photoModel.count === 0) {
      errorText = "Nothing matched. Try a broader search, another category, or a smaller minimum size."
      return
    }
    for (var i = 0; i < rows.length; i++) photoModel.append(rows[i])
  }

  // ---------------------------------------------------------------- acting

  function search(value) {
    var next = Model.singleLine(value, 120)
    root.query = next
    setConfig("query", next)
  }

  function selectTag(tag) {
    root.query = tag
    root.filterText = tag
    searchField.text = tag
    setConfig("query", tag)
  }

  function toggleCategory(index) {
    var next = Model.toggleBit(root.categories, index)
    if (next === root.categories) return
    root.categories = next
    setConfig("categories", next)
  }

  function cycleSorting() {
    var next = Model.nextIn(Model.SORTINGS, root.sorting)
    root.sorting = next
    setConfig("sorting", next)
  }

  function cycleResolution() {
    var next = Model.nextIn(Model.RESOLUTIONS, root.atleast)
    root.atleast = next
    setConfig("atleast", next)
  }

  function cycleInterval() {
    var next = Model.nextInterval(root.rotateMinutes)
    root.rotateMinutes = next
    setConfig("rotateMinutes", next)
  }

  function applySelected() {
    if (applying || selectedIndex < 0 || selectedIndex >= photoModel.count) return
    applyPhoto(photoModel.get(selectedIndex).json)
  }

  function applyPhoto(photoJson) {
    if (applying || !photoJson) return
    applying = true
    applyProcess.command = [root.cliPath, "apply", photoJson]
    applyProcess.running = true
  }

  function randomNow() {
    if (applying) return
    applying = true
    applyProcess.command = [root.cliPath, "next"]
    applyProcess.running = true
  }

  // ------------------------------------------------------------ data + ipc

  ListModel { id: photoModel }

  FileView {
    id: configView
    path: Quickshell.env("HOME") + "/.config/omarchy/wallarchy.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.applyConfig(text())
    // Qualified: root has a reload() of its own that re-queries the grid.
    onFileChanged: configView.reload()
    onLoadFailed: root.applyConfig("{}")
  }

  Process {
    id: photoProcess
    command: []
    stdout: StdioCollector { id: photoOutput; waitForEnd: true }
    stderr: StdioCollector { id: photoError; waitForEnd: true }
    onExited: function(code) {
      root.loading = false
      if (code !== 0) {
        root.errorText = Model.singleLine(photoError.text, 160) || "Wallhaven request failed."
        return
      }
      root.applyPhotos(photoOutput.text)
    }
  }

  Process {
    id: applyProcess
    command: []
    stderr: StdioCollector { id: applyError; waitForEnd: true }
    onExited: function(code) {
      root.applying = false
      if (code !== 0) root.errorText = Model.singleLine(applyError.text, 160) || "Could not set the wallpaper."
    }
  }

  Process {
    id: configProcess
    command: []
    onExited: root.drainConfigQueue()
  }

  IpcHandler {
    target: "wallarchy"
    function next(): string { root.randomNow(); return "ok" }
    function browse(): string { root.open("{}"); return "ok" }
  }

  // ------------------------------------------------------------------ view

  PanelWindow {
    id: panel
    visible: root.opened
    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }
    WlrLayershell.namespace: "wallarchy"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim

      MouseArea {
        anchors.fill: parent
        onClicked: root.dismiss()
      }
    }

    Rectangle {
      id: card
      anchors.centerIn: parent
      width: root.cardWidth
      height: root.cardHeight
      radius: Style.cornerRadius
      color: root.background
      border.color: root.borderColor
      border.width: 1

      // Swallow clicks so they don't reach the dismiss layer behind the card.
      MouseArea { anchors.fill: parent }

      Keys.onEscapePressed: root.dismiss()

      Column {
        anchors.fill: parent
        anchors.margins: Style.space(20)
        spacing: Style.space(14)

        // ---------------------------------------------------- search + row

        Row {
          width: parent.width
          spacing: Style.space(10)

          TextField {
            id: searchField
            width: parent.width - controls.width - Style.space(10)
            placeholderText: "Search Wallhaven — or pick a tag below"
            onTextChanged: root.filterText = text
            onAccepted: root.search(text)
            Keys.onDownPressed: grid.forceActiveFocus()
            Keys.onEscapePressed: root.dismiss()
          }

          Row {
            id: controls
            spacing: Style.space(8)

            Button {
              text: Model.labelFor(Model.SORTINGS, root.sorting, "Top")
              tooltipText: "Sort order"
              bordered: true
              onClicked: root.cycleSorting()
            }

            Button {
              text: Model.labelFor(Model.RESOLUTIONS, root.atleast, "Any size")
              tooltipText: "Minimum resolution"
              bordered: true
              onClicked: root.cycleResolution()
            }

            Button {
              text: root.rotateMinutes > 0 ? "Every " + Model.intervalLabel(root.rotateMinutes) : "Rotation off"
              tooltipText: "How often the wallpaper changes on its own"
              bordered: true
              selected: root.rotateMinutes > 0
              onClicked: root.cycleInterval()
            }

            Button {
              text: "Surprise me"
              tooltipText: "Apply a random wallpaper matching the current filters"
              bordered: true
              enabled: !root.applying
              onClicked: root.randomNow()
            }
          }
        }

        // ------------------------------------------------ categories + tags

        Flickable {
          width: parent.width
          height: chipRow.height
          contentWidth: chipRow.width
          flickableDirection: Flickable.HorizontalFlick
          clip: true

          Row {
            id: chipRow
            spacing: Style.space(8)

            Repeater {
              model: Model.CATEGORY_LABELS

              Button {
                required property int index
                required property string modelData
                text: modelData
                tooltipText: "Wallhaven category"
                bordered: true
                selected: Model.bitAt(root.categories, index)
                onClicked: root.toggleCategory(index)
              }
            }

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: 1
              height: Style.space(18)
              color: root.borderColor
            }

            Button {
              text: "All"
              bordered: true
              selected: root.query === ""
              onClicked: root.selectTag("")
            }

            Repeater {
              model: Model.TAGS

              Button {
                required property string modelData
                text: modelData
                bordered: true
                selected: root.query === modelData
                onClicked: root.selectTag(modelData)
              }
            }
          }
        }

        // ------------------------------------------------------------ grid

        Item {
          width: parent.width
          // The Column hands out `y`; clamping keeps the grid from taking a
          // negative height on a very short card.
          height: Math.max(0, parent.height - y)

          GridView {
            id: grid
            anchors.fill: parent
            clip: true
            focus: root.opened
            model: photoModel
            cellWidth: Math.floor(width / Math.max(1, Math.floor(width / Style.space(260))))
            cellHeight: Math.round(cellWidth * 0.6)
            currentIndex: root.selectedIndex
            onCurrentIndexChanged: root.selectedIndex = currentIndex
            onAtYEndChanged: if (atYEnd) root.loadMore()

            Keys.onReturnPressed: root.applySelected()
            Keys.onEnterPressed: root.applySelected()
            Keys.onEscapePressed: root.dismiss()

            delegate: Item {
              id: cell
              required property int index
              required property string thumb
              required property string color
              required property string label
              required property string json

              width: grid.cellWidth
              height: grid.cellHeight

              Rectangle {
                anchors.fill: parent
                anchors.margins: Style.space(4)
                radius: Style.cornerRadius
                // The API hands back a dominant colour per wallpaper; using it
                // as the placeholder means the grid never flashes empty boxes.
                color: cell.color
                border.width: grid.currentIndex === cell.index ? 2 : 0
                border.color: root.accent
                clip: true

                Image {
                  anchors.fill: parent
                  source: cell.thumb
                  asynchronous: true
                  cache: true
                  fillMode: Image.PreserveAspectCrop
                  sourceSize.width: Math.round(parent.width * 2)
                  opacity: status === Image.Ready ? 1 : 0

                  Behavior on opacity { NumberAnimation { duration: 160 } }
                }

                Rectangle {
                  anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                  height: labelText.implicitHeight + Style.space(10)
                  visible: cellArea.containsMouse || grid.currentIndex === cell.index
                  color: Qt.rgba(0, 0, 0, 0.6)

                  Text {
                    id: labelText
                    anchors.fill: parent
                    anchors.margins: Style.space(5)
                    text: cell.label
                    color: "#ffffff"
                    elide: Text.ElideRight
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                MouseArea {
                  id: cellArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: grid.currentIndex = cell.index
                  onClicked: {
                    grid.currentIndex = cell.index
                    root.applyPhoto(cell.json)
                  }
                }
              }
            }
          }

          BusyIndicator {
            anchors.centerIn: parent
            running: root.loading && photoModel.count === 0
            visible: running
          }
        }

        // ---------------------------------------------------------- footer

        Text {
          width: parent.width
          visible: root.errorText !== ""
          text: root.errorText
          color: Color.urgent
          wrapMode: Text.WordWrap
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
      }
    }
  }
}
