import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The Spotify panel: a now-playing hero (cover, progress, transport, volume,
// heart), a device switcher, and four tabs — Search, Playlists, Books,
// Podcasts — that all render into one flat row list so a single keyboard
// cursor walks whichever is showing. Playlists, albums, podcasts and
// audiobooks drill into a detail page with their items.
//
// IPC lives on BarWidget.qml; this component only needs moduleName so the
// shell can inject bar/settings/anchorItem/hostWidget into it.
Panel {
  id: root
  moduleName: "ninepointlabs.spotify"

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // One service per shell — every bar widget and every open panel reads the
  // same instance. A shell without service support gets a local one.
  readonly property var sharedService: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(moduleName) : null
  readonly property var service: sharedService || localService

  function pushSettings() { if (service) service.settings = settings }
  onSettingsChanged: pushSettings()
  onServiceChanged: pushSettings()
  Component.onCompleted: pushSettings()

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color faint: Qt.darker(foreground, 2.1)

  // ---------------------------------------------------------------- state --

  property string currentTab: setting("defaultTab", "search")
  property string searchText: ""
  property int cursorIndex: -1
  property bool deviceMenuOpen: false
  property bool countedOpen: false
  property bool _returnFired: false

  readonly property bool authenticated: service ? service.authenticated === true : false
  readonly property bool needsSetup: service && service.probed && !authenticated
  readonly property var detail: service ? service.detail : null
  readonly property bool detailOpen: detail !== null && detail !== undefined
  readonly property var player: service ? service.player : ({ active: false })
  readonly property bool playerActive: service ? service.playerActive : false
  readonly property bool isPlaying: service ? service.isPlaying : false
  readonly property var nowItem: service ? service.nowItem : null
  readonly property string nowUri: service ? service.nowUri : ""
  readonly property int durationMs: service ? service.durationMs : 0
  readonly property int progressMs: service ? service.localProgressMs : 0
  readonly property string heroArt: Model.artSource(nowItem) || Model.artSource(service ? service.lastPlayed : null)

  readonly property var rows: computeRows()

  function computeRows() {
    if (!service || !authenticated) return []
    if (detailOpen) return Model.detailRows(detail)
    if (currentTab === "search") return Model.searchRows(service.searchResults, service.recent, searchText, service.searching, service.searchError)
    if (currentTab === "playlists") return Model.libraryRows(service.playlists, service.playlistsLoading, service.playlistsError, "No playlists yet — make one in Spotify and it shows up here.")
    if (currentTab === "books") return Model.libraryRows(service.audiobooks, service.audiobooksLoading, service.audiobooksError, "No audiobooks saved. Search for one and save it in Spotify to see it here.")
    if (currentTab === "podcasts") return Model.libraryRows(service.shows, service.showsLoading, service.showsError, "No podcasts followed. Search for a show and follow it in Spotify.")
    return []
  }

  // Keep the keyboard cursor on a real row: land on the first item whenever
  // the list changes under it (tab switch, results arriving, detail opening).
  onRowsChanged: {
    if (cursorIndex < 0 || cursorIndex >= rows.length || rows[cursorIndex].kind !== "item") cursorIndex = Model.firstItemIndex(rows, 0, 1)
  }

  readonly property string statusText: {
    if (!service) return ""
    if (service.actionError !== "") return service.actionError
    if (service.actionStatus !== "") return service.actionStatus
    if (service.playerError !== "") return service.playerError
    if (service.lastError !== "") return service.lastError
    if (!authenticated) return ""
    if (service.premiumRequired) return "Spotify Premium is required for playback control"
    if (playerActive && service.deviceName !== "") return (isPlaying ? "Playing on " : "Paused on ") + service.deviceName
    if (service.daemonExpired) return "Soloist build expired — update it with your package manager"
    if (service.daemonInstalled && !service.daemonUnit) return "Soloist is installed — it needs a soloist.service to run under"
    if (service.daemonReady && !service.daemonRunning) return "Soloist isn't running — start it to play here"
    if (service.daemonRunning && !service.daemonPaired) return "Pick “Omarchy” once in the Spotify app to pair Soloist"
    if (service.noDevice) return "No active device — pick one or start a player"
    if (service.user && service.user.name) return "Connected as " + service.user.name
    return "Connected"
  }
  readonly property bool statusIsError: service && (service.actionError !== "" || service.playerError !== "" || service.lastError !== "" || service.premiumRequired)

  // ------------------------------------------------------------ actions --

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function setTab(name) {
    if (service) service.closeDetail()
    if (currentTab !== name) {
      currentTab = name
      persistSettings({ defaultTab: name })
    }
    if (service) service.loadTab(name, false)
    cursorIndex = Model.firstItemIndex(rows, 0, 1)
    Qt.callLater(function() { if (listFlick) listFlick.contentY = 0 })
  }

  function stepTab(delta) {
    setTab(Model.tabAt(Model.tabIndex(currentTab) + delta))
  }

  function moveCursor(delta) {
    if (!Model.hasItems(rows)) return
    var from = cursorIndex < 0 ? (delta > 0 ? 0 : rows.length - 1) : cursorIndex + delta
    // Stop at the ends rather than wrapping, so a long list can't surprise you.
    if (cursorIndex >= 0) {
      var probe = cursorIndex + delta
      var found = -1
      while (probe >= 0 && probe < rows.length) {
        if (rows[probe].kind === "item") { found = probe; break }
        probe += delta
      }
      if (found < 0) return
      cursorIndex = found
    } else {
      cursorIndex = Model.firstItemIndex(rows, from, delta)
    }
    ensureCursorVisible()
  }

  function ensureCursorVisible() {
    if (cursorIndex < 0 || !listFlick) return
    var delegate = rowsRepeater.itemAt(cursorIndex)
    if (!delegate) return
    var top = delegate.y
    var bottom = delegate.y + delegate.height
    if (top < listFlick.contentY) listFlick.contentY = Math.max(0, top - Style.space(4))
    else if (bottom > listFlick.contentY + listFlick.height) listFlick.contentY = Math.min(Math.max(0, listFlick.contentHeight - listFlick.height), bottom - listFlick.height + Style.space(4))
  }

  function activateRow(index) {
    if (index < 0 || index >= rows.length || rows[index].kind !== "item" || !service) return
    var item = rows[index].item
    if (Model.opensDetail(item)) {
      service.openDetail(item)
      Qt.callLater(function() { if (listFlick) listFlick.contentY = 0 })
      return
    }
    playRowItem(item)
  }

  // Playing from a detail list starts the whole context at that item so
  // next/previous walk the list; elsewhere a track plays inside its album.
  function playRowItem(item) {
    if (!service || !item) return
    if (detailOpen && detail.contextUri) service.playItem(item, detail.contextUri)
    else if (detailOpen && detail.kind === "liked") service.playUris(likedUrisFrom(item))
    else service.playItem(item)
  }

  function likedUrisFrom(item) {
    var uris = []
    var started = false
    var items = detail && detail.items ? detail.items : []
    for (var i = 0; i < items.length; i++) {
      if (items[i].uri === item.uri) started = true
      if (started && items[i].uri) uris.push(items[i].uri)
    }
    return uris.length > 0 ? uris : [item.uri]
  }

  function playDetail(shuffle) {
    if (!service || !detailOpen) return
    if (detail.kind === "liked") { service.playLiked(); return }
    if (!detail.contextUri) return
    if (shuffle) service.shuffleContext(detail.contextUri)
    else service.playContext(detail.contextUri)
  }

  function queueRow(index) {
    if (index < 0 || index >= rows.length || rows[index].kind !== "item" || !service) return
    var item = rows[index].item
    if (item.type === "track" || item.type === "episode" || item.type === "chapter") service.queueAdd(item)
  }

  function goBack() {
    if (!service) return false
    if (detailOpen) {
      service.closeDetail()
      cursorIndex = Model.firstItemIndex(rows, 0, 1)
      return true
    }
    return false
  }

  function focusSearch() {
    if (currentTab !== "search") setTab("search")
    searchField.forceActiveFocus()
    searchField.selectAll()
  }

  function refresh() {
    if (!service) return
    service.refresh()
    service.loadTab(currentTab, true)
    if (detailOpen && detail.item) service.openDetail(detail.item)
    if (deviceMenuOpen) service.loadDevices()
  }

  function toggleDevices() {
    deviceMenuOpen = !deviceMenuOpen
    if (deviceMenuOpen && service) service.loadDevices()
  }

  function connectSpotify() {
    if (!service) return
    var id = String(clientIdField.text || "").trim()
    if (id === "") { service.authError = "Paste your Spotify app's Client ID first."; return }
    if (id !== String(setting("clientId", "") || "")) persistSettings({ clientId: id })
    service.startAuth(id)
  }

  // Started as an absolute argv with a closed environment by the service,
  // never as shell text through bar.run.
  function launchInstall() {
    if (!service) return
    if (service.launchInstall()) close()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function noteOpen(isOpen) {
    if (!service) return
    if (isOpen && !countedOpen) { service.openPanels += 1; countedOpen = true }
    else if (!isOpen && countedOpen) { service.openPanels = Math.max(0, service.openPanels - 1); countedOpen = false }
  }

  Component.onDestruction: noteOpen(false)

  implicitWidth: 1
  implicitHeight: 1

  onOpenedChanged: {
    noteOpen(opened)
    if (!opened) {
      deviceMenuOpen = false
      if (service) service.closeDetail()
      return
    }
    if (service) {
      service.refreshIfStale()
      service.loadTab(currentTab, false)
    }
    cursorIndex = Model.firstItemIndex(rows, 0, 1)
    if (listFlick) listFlick.contentY = 0
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Service {
    id: localService
    active: root.sharedService === null
  }

  // Search as you type, a beat after the last keystroke.
  Timer {
    id: searchDebounce
    interval: 350
    repeat: false
    onTriggered: if (root.service) root.service.search(root.searchText)
  }
  onSearchTextChanged: {
    if (searchText.trim() === "") { if (service) service.search(""); return }
    searchDebounce.restart()
  }

  // While the setup card shows, re-probe so finishing the login in the
  // browser flips the panel over on its own.
  Timer {
    interval: 3000
    repeat: true
    running: root.opened && root.needsSetup && !(root.service && root.service.authRunning)
    onTriggered: if (root.service) root.service.refresh()
  }

  // ------------------------------------------------------------- pieces --

  // Cover art with rounded corners and a glyph placeholder. Reads root for
  // colors so callers only ever set `source` and `placeholder`.
  component RoundedArt: Item {
    id: art
    property string source: ""
    property string placeholder: Model.glyph.note
    property real cornerRadius: Style.cornerRadius > 0 ? Math.max(3, Math.round(width * 0.12)) : 0
    readonly property bool showsImage: source !== "" && image.status === Image.Ready

    Rectangle {
      anchors.fill: parent
      radius: art.cornerRadius
      color: Style.normalFillFor(root.foreground, root.accent)
      border.width: Style.spacing.hairline
      border.color: Style.normalBorderFor(root.foreground, root.accent)
      visible: !art.showsImage
    }

    Text {
      textFormat: Text.PlainText
      anchors.centerIn: parent
      visible: !art.showsImage
      text: art.placeholder
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Math.max(Style.font.body, Math.round(art.width * 0.42))
    }

    Image {
      id: image
      anchors.fill: parent
      source: art.source
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      smooth: true
      mipmap: true
      sourceSize.width: 320
      sourceSize.height: 320
      visible: false
      layer.enabled: true
    }

    Rectangle {
      id: mask
      anchors.fill: parent
      radius: art.cornerRadius
      visible: false
      layer.enabled: true
    }

    MultiEffect {
      anchors.fill: parent
      visible: art.showsImage
      source: image
      maskEnabled: true
      maskSource: mask
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(470))
    contentHeight: panel.fittedContentHeight(
      fixedContent.implicitHeight + content.spacing + (root.needsSetup ? 0 : Math.max(Style.space(180), listColumn.implicitHeight + Style.space(6))),
      Style.space(760))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: searchField.activeFocus || clientIdField.activeFocus
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
        else if (dx < 0 && root.detailOpen) root.goBack()
        else if (dx !== 0 && !root.detailOpen) root.stepTab(dx)
      }
      onReturnRequested: { root._returnFired = true; root.activateRow(root.cursorIndex) }
      onActivateRequested: {
        if (root._returnFired) { root._returnFired = false; return }
        if (root.service) root.service.playPause()
      }
      onCloseRequested: {
        if (root.deviceMenuOpen) { root.deviceMenuOpen = false; return }
        if (root.goBack()) return
        if (root.currentTab === "search" && root.searchText !== "") { root.searchText = ""; return }
        root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (!root.service) return
        if (t === "/") root.focusSearch()
        else if (t === "1") root.setTab("search")
        else if (t === "2") root.setTab("playlists")
        else if (t === "3") root.setTab("books")
        else if (t === "4") root.setTab("podcasts")
        else if (t === "n") root.service.next()
        else if (t === "p") root.service.previous()
        else if (t === "s") root.service.toggleShuffle()
        else if (t === "r") root.refresh()
        else if (t === "q") root.queueRow(root.cursorIndex)
        else if (t === "d") root.toggleDevices()
        else if (t === "f") root.service.toggleSaved()
        else if (t === "+" || t === "=") root.service.nudgeVolume(5)
        else if (t === "-") root.service.nudgeVolume(-5)
      }

      ColumnLayout {
        id: content
        anchors.fill: parent
        spacing: Style.space(10)

        Column {
          id: fixedContent
          Layout.fillWidth: true
          spacing: Style.space(10)

          // ---------------------------------------------------- header --
          Item {
            width: parent.width
            implicitHeight: Math.max(titleColumn.implicitHeight, headerActions.implicitHeight)

            Column {
              id: titleColumn
              anchors.left: parent.left
              anchors.right: headerActions.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Row {
                spacing: Style.space(6)
                Text {
                  textFormat: Text.PlainText
                  text: Model.glyph.spotify
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                  textFormat: Text.PlainText
                  text: "SPOTIFY"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                  font.letterSpacing: 1
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              Text {
                visible: text !== ""
                width: parent.width
                text: root.statusText
                textFormat: Text.PlainText
                color: root.statusIsError ? root.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
            }

            Row {
              id: headerActions
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)

              Button {
                visible: root.authenticated
                iconText: root.playerActive && root.player.device ? Model.deviceGlyph(root.player.device.kind) : Model.glyph.device
                text: {
                  var name = root.service ? root.service.deviceName : ""
                  if (name === "") return "Devices"
                  return name.length > 16 ? name.substring(0, 15) + "…" : name
                }
                selected: root.deviceMenuOpen
                tooltipText: "Playback device (d)"
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                iconSize: Style.font.body
                horizontalPadding: Style.space(8)
                verticalPadding: Style.space(3)
                onClicked: root.toggleDevices()
              }

              PanelActionButton {
                iconText: root.service && root.service.busy ? Model.glyph.refreshing : Model.glyph.refresh
                tooltipText: "Refresh (r)"
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: !root.service || !root.service.busy
                onClicked: root.refresh()
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          // ------------------------------------------------- setup card --
          Column {
            visible: root.needsSetup
            width: parent.width
            spacing: Style.space(10)
            topPadding: Style.space(6)
            bottomPadding: Style.space(8)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.service && root.service.needsReauth ? "Your Spotify session expired" : "Connect your Spotify account"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
              wrapMode: Text.Wrap
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: root.service && root.service.needsReauth
              text: "Spotify limits a login to six months. Connect again and everything picks up where it left off."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
            }

            Column {
              width: parent.width
              spacing: Style.space(4)
              visible: !(root.service && root.service.needsReauth)

              Repeater {
                model: Model.setupSteps(root.service ? root.service.redirectPort : 8888)

                Row {
                  required property var modelData
                  required property int index
                  width: parent.width
                  spacing: Style.space(8)

                  Text {
                    textFormat: Text.PlainText
                    text: String(index + 1)
                    color: root.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                    width: Style.space(12)
                  }
                  Text {
                    textFormat: Text.PlainText
                    width: parent.width - Style.space(20)
                    text: modelData
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.Wrap
                  }
                }
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              TextField {
                id: clientIdField
                width: parent.width - connectButton.width - parent.spacing
                placeholderText: "Spotify app Client ID"
                text: String(root.setting("clientId", "") || (root.service ? root.service.storedClientId : "") || "")
                foreground: root.foreground
                accent: root.accent
                font.family: root.fontFamily
                enabled: !(root.service && root.service.authRunning)
                Keys.onReturnPressed: root.connectSpotify()
                Keys.onEscapePressed: keyCatcher.forceActiveFocus()
              }

              Button {
                id: connectButton
                text: root.service && root.service.authRunning ? "Cancel" : "Connect…"
                bordered: true
                foreground: root.foreground
                background: Color.popups.background
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.body
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                anchors.verticalCenter: parent.verticalCenter
                onClicked: {
                  if (root.service && root.service.authRunning) root.service.cancelAuth()
                  else root.connectSpotify()
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.service && root.service.authRunning
              width: parent.width
              text: "Waiting for you to approve in the browser… this closes on its own once Spotify redirects back."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
            }

            Text {
              visible: root.service && root.service.authError !== ""
              width: parent.width
              textFormat: Text.PlainText
              text: root.service ? root.service.authError : ""
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
            }

            Column {
              visible: root.service && !root.service.hasLocalDevice
              width: parent.width
              spacing: Style.space(6)
              topPadding: Style.space(4)

              PanelSeparator { foreground: root.foreground }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: "This panel needs a player to drive: the Spotify desktop app, or the headless Spotify Soloist daemon (install either one yourself — see the README). Neither is installed yet."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.Wrap
              }

              Row {
                spacing: Style.space(8)
                Button {
                  text: "Install Spotify…"
                  bordered: true
                  foreground: root.foreground
                  background: Color.popups.background
                  accent: root.accent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  horizontalPadding: Style.spacing.controlPaddingX
                  verticalPadding: Style.space(4)
                  onClicked: root.launchInstall()
                }
                Text {
                  textFormat: Text.PlainText
                  text: "or run: " + Model.installCommand
                  color: root.faint
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
            }
          }

          // -------------------------------------------------------- hero --
          Column {
            visible: root.authenticated
            width: parent.width
            spacing: Style.space(8)

            Row {
              width: parent.width
              spacing: Style.space(12)

              RoundedArt {
                id: heroArt
                width: Style.space(84)
                height: Style.space(84)
                source: root.heroArt
                placeholder: Model.glyph.spotify
                opacity: root.playerActive ? 1.0 : 0.55

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: if (root.service) root.service.playPause()
                }
              }

              Column {
                width: parent.width - heroArt.width - parent.spacing
                spacing: Style.space(3)
                anchors.verticalCenter: parent.verticalCenter

                Item {
                  width: parent.width
                  height: heroTitle.implicitHeight

                  Text {
                    id: heroTitle
                    anchors.left: parent.left
                    anchors.right: heartButton.left
                    anchors.rightMargin: Style.space(6)
                    textFormat: Text.PlainText
                    text: Model.heroTitle(root.player)
                    color: root.playerActive ? root.foreground : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.heading
                    font.bold: true
                    elide: Text.ElideRight
                  }

                  PanelActionButton {
                    id: heartButton
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.nowUri !== ""
                    iconText: root.service && root.service.nowSaved ? Model.glyph.heart : Model.glyph.heartOutline
                    tooltipText: root.service && root.service.nowSaved ? "Remove from your library (f)" : "Save to your library (f)"
                    foreground: root.service && root.service.nowSaved ? root.accent : root.foreground
                    hoverColor: root.accent
                    fontFamily: root.fontFamily
                    onClicked: if (root.service) root.service.toggleSaved()
                  }
                }

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  visible: text !== ""
                  text: root.playerActive ? Model.heroSubtitle(root.player) : (root.service && root.service.lastPlayed && root.service.lastPlayed.name ? "Last played: " + root.service.lastPlayed.name : "")
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }

                Item { width: 1; height: Style.space(2) }

                PanelSlider {
                  id: progressSlider
                  width: parent.width
                  bar: root.bar
                  minimum: 0
                  maximum: Math.max(1, root.durationMs)
                  value: root.progressMs
                  step: 5000
                  integer: true
                  enabled: root.playerActive && root.durationMs > 0
                  opacity: enabled ? 1.0 : 0.4
                  implicitHeight: Style.space(18)
                  knobSize: Style.space(12)
                  trackHeight: Style.space(4)
                  onReleased: function(v) { if (root.service) root.service.seek(v) }
                }

                Item {
                  width: parent.width
                  height: elapsed.implicitHeight

                  Text {
                    textFormat: Text.PlainText
                    id: elapsed
                    anchors.left: parent.left
                    text: Model.fmtTime(progressSlider.dragging ? progressSlider.liveValue : root.progressMs)
                    color: root.faint
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    textFormat: Text.PlainText
                    anchors.right: parent.right
                    text: root.durationMs > 0 ? Model.fmtTime(root.durationMs) : "–:––"
                    color: root.faint
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }

            // Transport on the left, volume on the right.
            Item {
              width: parent.width
              height: transport.implicitHeight

              Row {
                id: transport
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Button {
                  iconText: Model.glyph.shuffle
                  tooltipText: "Shuffle (s)"
                  selected: root.playerActive && root.player.shuffle === true
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  horizontalPadding: Style.space(8)
                  verticalPadding: Style.space(5)
                  enabled: root.playerActive
                  opacity: enabled ? 1.0 : 0.4
                  onClicked: if (root.service) root.service.toggleShuffle()
                }

                Button {
                  iconText: Model.glyph.previous
                  tooltipText: "Previous (p)"
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  horizontalPadding: Style.space(8)
                  verticalPadding: Style.space(5)
                  enabled: root.playerActive
                  opacity: enabled ? 1.0 : 0.4
                  onClicked: if (root.service) root.service.previous()
                }

                Button {
                  iconText: root.isPlaying ? Model.glyph.pause : Model.glyph.play
                  tooltipText: root.isPlaying ? "Pause (space)" : "Play (space)"
                  bordered: true
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  iconSize: Style.font.iconLarge
                  horizontalPadding: Style.space(14)
                  verticalPadding: Style.space(4)
                  onClicked: if (root.service) root.service.playPause()
                }

                Button {
                  iconText: Model.glyph.next
                  tooltipText: "Next (n)"
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  horizontalPadding: Style.space(8)
                  verticalPadding: Style.space(5)
                  enabled: root.playerActive
                  opacity: enabled ? 1.0 : 0.4
                  onClicked: if (root.service) root.service.next()
                }

                Button {
                  iconText: Model.repeatGlyph(root.playerActive ? root.player.repeat : "off")
                  tooltipText: "Repeat: " + (root.playerActive ? root.player.repeat : "off")
                  selected: root.playerActive && root.player.repeat !== "off"
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  horizontalPadding: Style.space(8)
                  verticalPadding: Style.space(5)
                  enabled: root.playerActive
                  opacity: enabled ? 1.0 : 0.4
                  onClicked: if (root.service) root.service.cycleRepeat()
                }
              }

              Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)
                readonly property bool volumeAvailable: root.playerActive && root.service && root.service.volume >= 0
                opacity: volumeAvailable ? 1.0 : 0.4

                Text {
                  textFormat: Text.PlainText
                  text: Model.volumeGlyph(root.service ? root.service.volume : -1)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.icon
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(18)
                  horizontalAlignment: Text.AlignHCenter

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: if (root.service) root.service.setVolume(root.service.volume === 0 ? 50 : 0)
                  }
                }

                PanelSlider {
                  width: Style.space(110)
                  bar: root.bar
                  minimum: 0
                  maximum: 100
                  step: 5
                  integer: true
                  value: root.service && root.service.volume >= 0 ? root.service.volume : 0
                  enabled: parent.volumeAvailable
                  implicitHeight: Style.space(18)
                  knobSize: Style.space(12)
                  trackHeight: Style.space(4)
                  anchors.verticalCenter: parent.verticalCenter
                  onMoved: function(v) { if (root.service) root.service.setVolume(v) }
                  onReleased: function(v) { if (root.service) root.service.setVolume(v) }
                }
              }
            }

            // Idle hint: nothing is driving Spotify yet.
            Row {
              visible: !root.playerActive
              spacing: Style.space(8)

              Button {
                visible: root.service && root.service.daemonReady && !root.service.daemonRunning
                text: "Start Soloist"
                iconText: Model.glyph.play
                bordered: true
                foreground: root.foreground
                background: Color.popups.background
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                iconSize: Style.font.body
                horizontalPadding: Style.space(10)
                verticalPadding: Style.space(4)
                onClicked: if (root.service) root.service.startDaemon()
              }

              Button {
                visible: root.service && root.service.appInstalled
                text: root.service && root.service.appRunning ? "Focus Spotify app" : "Launch Spotify app"
                iconText: Model.glyph.external
                bordered: true
                foreground: root.foreground
                background: Color.popups.background
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                iconSize: Style.font.body
                horizontalPadding: Style.space(10)
                verticalPadding: Style.space(4)
                onClicked: {
                  if (root.service && root.service.appRunning) root.service.focusApp()
                  else if (root.service) root.service.launchApp()
                }
              }

              Button {
                visible: root.service && !root.service.hasLocalDevice
                text: "Install Spotify app…"
                bordered: true
                foreground: root.foreground
                background: Color.popups.background
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                horizontalPadding: Style.space(10)
                verticalPadding: Style.space(4)
                onClicked: root.launchInstall()
              }

              Button {
                visible: root.service && !root.service.daemonRunning
                text: root.service && root.service.daemonInstalled ? "Headless player…" : "Play without a window…"
                bordered: true
                foreground: root.foreground
                background: Color.popups.background
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                horizontalPadding: Style.space(10)
                verticalPadding: Style.space(4)
                onClicked: { if (!root.deviceMenuOpen) root.toggleDevices() }
              }

              Button {
                text: "Pick a device"
                bordered: true
                foreground: root.foreground
                background: Color.popups.background
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                horizontalPadding: Style.space(10)
                verticalPadding: Style.space(4)
                onClicked: { if (!root.deviceMenuOpen) root.toggleDevices() }
              }
            }
          }

          // ------------------------------------------------ device menu --
          Column {
            visible: root.authenticated && root.deviceMenuOpen
            width: parent.width
            spacing: Style.space(4)

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: root.service && root.service.devicesLoading ? "DEVICES · LOADING…" : "DEVICES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              visible: root.service && !root.service.devicesLoading && root.service.devices.length === 0
              width: parent.width
              text: "Spotify sees no devices. Open the Spotify app on this machine or your phone and it appears here."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
            }

            Repeater {
              model: root.service ? root.service.devices : []

              Button {
                required property var modelData
                width: parent.width
                leftAlign: true
                iconText: Model.deviceGlyph(modelData.kind)
                text: modelData.name + (modelData.isActive ? "   ·   active" : "")
                selected: modelData.isActive
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                horizontalPadding: Style.space(8)
                verticalPadding: Style.space(4)
                onClicked: {
                  if (root.service && !modelData.isActive) root.service.transferTo(modelData.id)
                  root.deviceMenuOpen = false
                }
              }
            }

            Row {
              spacing: Style.space(6)
              topPadding: Style.space(2)

              Button {
                visible: root.service && root.service.daemonReady
                text: root.service && root.service.daemonRunning ? "Restart Soloist" : "Start Soloist"
                iconText: Model.glyph.play
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                iconSize: Style.font.bodySmall
                horizontalPadding: Style.space(8)
                verticalPadding: Style.space(3)
                onClicked: if (root.service) root.service.startDaemon()
              }
              Button {
                visible: root.service && root.service.appInstalled
                text: "Launch app"
                iconText: Model.glyph.external
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                iconSize: Style.font.bodySmall
                horizontalPadding: Style.space(8)
                verticalPadding: Style.space(3)
                onClicked: if (root.service) root.service.launchApp()
              }
              Button {
                text: "Rescan"
                iconText: Model.glyph.refresh
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                iconSize: Style.font.bodySmall
                horizontalPadding: Style.space(8)
                verticalPadding: Style.space(3)
                onClicked: if (root.service) root.service.loadDevices()
              }
              Button {
                text: root.service && root.service.user && root.service.user.name ? "Sign out " + root.service.user.name : "Sign out"
                iconText: Model.glyph.signOut
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                iconSize: Style.font.bodySmall
                horizontalPadding: Style.space(8)
                verticalPadding: Style.space(3)
                onClicked: { root.deviceMenuOpen = false; if (root.service) root.service.signOut() }
              }
            }

            // ---- Headless player: Spotify Soloist. Both the binary and the
            //      service around it are the user's to install. The panel
            //      never fetches an executable (Spotify publishes no checksum
            //      or signature for its Soloist builds) and never writes a
            //      unit or stores the API key: Soloist reads that key only
            //      from --api-key on the command line, so any unit generated
            //      here would have to expand the secret into a command line
            //      that ps, systemctl status and crash reports can read. The
            //      panel finds Soloist, starts and stops it, warns when the
            //      running command line carries the key, and removes the
            //      key-bearing unit older versions of this plugin wrote.
            PanelSectionHeader {
              topPadding: Style.space(8)
              text: "HEADLESS PLAYER"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              width: parent.width
              wrapMode: Text.Wrap
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              text: {
                if (!root.service) return ""
                if (!root.service.daemonInstalled) return "Spotify Soloist plays with no window: Spotify's own headless Connect device, run as a background service. Premium required. Install it yourself first — this panel does not download it."
                if (!root.service.daemonUnit) return "Found soloist at " + root.service.daemonPath + ", but no soloist.service to run it. Install the service from your package, or write your own unit — this plugin no longer generates one. See “Running Soloist yourself” in the README."
                if (root.service.daemonExpired) return "The Soloist build expired after 90 days. Update it the way you installed it, then start it again."
                if (!root.service.daemonRunning) return "Soloist is installed but stopped."
                if (!root.service.daemonPaired) return "Soloist is running as “Omarchy”. Pick it once in the Spotify app's device picker to pair; after that it appears above."
                return "Soloist is running as “Omarchy”."
              }
            }

            // Where to get it. Deliberately text only: the panel points at a
            // trusted install source instead of fetching anything itself.
            Text {
              visible: root.service && !root.service.daemonInstalled
              width: parent.width
              wrapMode: Text.Wrap
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              text: "Get the binary from a source you trust, not from this panel:\n  ·  your package manager — on Arch/Omarchy the AUR package spotify-soloist-bin\n  ·  or Spotify's own instructions at developer.spotify.com/documentation/soloist\nOnce a package has put soloist in /usr/bin, or you have unpacked it into ~/.local/bin, come back here. Your PATH is not searched."
            }

            // The API key on the running command line. Nothing this plugin
            // writes can cause this, but a unit from a package — or one an
            // older version of this plugin wrote — still can, and the user is
            // the only one who can fix it, so say so plainly.
            Text {
              visible: root.service && root.service.daemonKeyInCommandLine
              width: parent.width
              wrapMode: Text.Wrap
              textFormat: Text.PlainText
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              text: (root.service && root.service.daemonLegacyUnit
                     ? "The soloist.service an older version of this plugin wrote passes your API key as --api-key on the command line, where ps, systemctl status and crash reports can read it. This version writes no unit at all. Remove the old one below, then install Soloist's service from your package or write your own."
                     : "The soloist.service running here passes your API key as --api-key on the command line, where ps, systemctl status and crash reports can read it. It did not come from this plugin, so the plugin leaves it alone — Soloist accepts no other way of taking the key, so treat that key as exposed to anything that can read /proc.")
            }

            // A weekly auto-updater that an older version of this plugin
            // installed: offer to take it off, since nothing re-creates it.
            Text {
              visible: root.service && root.service.legacyUpdater
              width: parent.width
              wrapMode: Text.Wrap
              textFormat: Text.PlainText
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              text: "An older version of this plugin left a weekly timer here that re-downloaded the Soloist binary. This version does not do that. Remove the leftover timer:"
            }

            Button {
              visible: root.service && root.service.legacyUpdater
              text: root.service && root.service.soloistBusy ? "Removing…" : "Remove the old auto-updater"
              bordered: true
              foreground: root.foreground
              background: Color.popups.background
              accent: root.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.space(10)
              verticalPadding: Style.space(4)
              enabled: !(root.service && root.service.soloistBusy)
              onClicked: if (root.service) root.service.dropSoloistUpdater()
            }

            Text {
              visible: root.service && root.service.soloistError !== ""
              width: parent.width
              wrapMode: Text.Wrap
              textFormat: Text.PlainText
              text: root.service ? root.service.soloistError : ""
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Row {
              spacing: Style.space(6)

              Button {
                visible: root.service && root.service.daemonLegacyUnit
                text: root.service && root.service.soloistBusy ? "Removing…" : "Remove the old plugin service"
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.space(8)
                verticalPadding: Style.space(3)
                enabled: !(root.service && root.service.soloistBusy)
                onClicked: if (root.service) root.service.removeSoloist()
              }
            }
          }

          PanelSeparator { visible: root.authenticated; foreground: root.foreground }

          // ---------------------------------------------------- tabs --
          Row {
            visible: root.authenticated && !root.detailOpen
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: Model.tabs

              Button {
                required property var modelData
                iconText: modelData.icon
                text: modelData.label
                selected: root.currentTab === modelData.key
                tooltipText: modelData.hint
                foreground: root.foreground
                background: "transparent"
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                iconSize: Style.font.bodySmall
                horizontalPadding: Style.space(8)
                verticalPadding: Style.space(3)
                onClicked: root.setTab(modelData.key)
              }
            }
          }

          // --------------------------------------------- search field --
          Item {
            visible: root.authenticated && !root.detailOpen && root.currentTab === "search"
            width: parent.width
            height: searchField.implicitHeight

            TextField {
              id: searchField
              anchors.fill: parent
              placeholderText: "Search Spotify   ·   press /"
              foreground: root.foreground
              accent: root.accent
              font.family: root.fontFamily
              verticalPadding: Style.space(5)
              rightPadding: Style.space(28)
              text: root.searchText
              onTextEdited: root.searchText = text
              Keys.onEscapePressed: function(event) {
                if (text !== "") { root.searchText = ""; text = "" }
                keyCatcher.forceActiveFocus()
                event.accepted = true
              }
              Keys.onDownPressed: function(event) {
                keyCatcher.forceActiveFocus()
                root.cursorIndex = Model.firstItemIndex(root.rows, 0, 1)
                event.accepted = true
              }
              Keys.onReturnPressed: function(event) {
                searchDebounce.stop()
                if (root.service) root.service.search(root.searchText)
                keyCatcher.forceActiveFocus()
                root.cursorIndex = Model.firstItemIndex(root.rows, 0, 1)
                event.accepted = true
              }
            }

            PanelActionButton {
              anchors.right: parent.right
              anchors.rightMargin: Style.space(4)
              anchors.verticalCenter: parent.verticalCenter
              visible: root.searchText !== ""
              iconText: Model.glyph.close
              tooltipText: "Clear"
              foreground: root.foreground
              fontFamily: root.fontFamily
              size: Style.space(20)
              fontSize: Style.font.bodySmall
              onClicked: { root.searchText = ""; searchField.text = ""; keyCatcher.forceActiveFocus() }
            }
          }

          // -------------------------------------------- detail header --
          Item {
            visible: root.authenticated && root.detailOpen
            width: parent.width
            implicitHeight: detailRow.implicitHeight

            Row {
              id: detailRow
              width: parent.width
              spacing: Style.space(10)

              PanelActionButton {
                iconText: Model.glyph.back
                tooltipText: "Back (esc / h)"
                foreground: root.foreground
                fontFamily: root.fontFamily
                anchors.verticalCenter: parent.verticalCenter
                onClicked: root.goBack()
              }

              RoundedArt {
                id: detailArt
                width: Style.space(52)
                height: Style.space(52)
                source: root.detailOpen ? Model.artSource(root.detail.item) : ""
                placeholder: root.detailOpen ? Model.typeGlyph(root.detail.item.type) : Model.glyph.note
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                width: parent.width - detailArt.width - detailActions.width - Style.space(22) - parent.spacing * 3
                spacing: Style.space(2)
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: root.detailOpen && root.detail.item ? root.detail.item.name : ""
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                  elide: Text.ElideRight
                }
                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: root.detailOpen && root.detail.item ? Model.subtitle(root.detail.item) : ""
                  visible: text !== ""
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              Row {
                id: detailActions
                spacing: Style.space(4)
                anchors.verticalCenter: parent.verticalCenter

                Button {
                  iconText: Model.glyph.play
                  text: "Play"
                  bordered: true
                  foreground: root.foreground
                  background: Color.popups.background
                  accent: root.accent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  iconSize: Style.font.bodySmall
                  horizontalPadding: Style.space(8)
                  verticalPadding: Style.space(3)
                  onClicked: root.playDetail(false)
                }
                Button {
                  visible: root.detailOpen && (root.detail.kind === "playlist" || root.detail.kind === "album" || root.detail.kind === "liked")
                  iconText: Model.glyph.shuffle
                  tooltipText: "Shuffle play"
                  bordered: true
                  foreground: root.foreground
                  background: Color.popups.background
                  accent: root.accent
                  fontFamily: root.fontFamily
                  iconSize: Style.font.bodySmall
                  horizontalPadding: Style.space(7)
                  verticalPadding: Style.space(3)
                  onClicked: root.playDetail(true)
                }
              }
            }
          }
        }

        // ---------------------------------------------------------- list --
        Flickable {
          id: listFlick
          visible: root.authenticated
          Layout.fillWidth: true
          Layout.fillHeight: true
          contentWidth: width
          contentHeight: listColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          Column {
            id: listColumn
            width: listFlick.width
            spacing: Style.space(2)

            Repeater {
              id: rowsRepeater
              model: root.rows

              Item {
                id: rowItem
                required property var modelData
                required property int index
                readonly property bool isItem: modelData.kind === "item"
                readonly property var item: isItem ? modelData.item : null
                readonly property bool hasCursor: isItem && root.cursorIndex === index
                readonly property bool isNow: isItem && item.uri !== "" && item.uri === root.nowUri
                readonly property bool queueable: isItem && (item.type === "track" || item.type === "episode" || item.type === "chapter")
                readonly property real progress: isItem ? Model.progressFraction(item) : 0

                width: listColumn.width
                height: modelData.kind === "header" ? headerText.implicitHeight + Style.space(10)
                      : modelData.kind === "note" ? noteText.implicitHeight + Style.space(12)
                      : Style.space(46)

                // Section header
                PanelSectionHeader {
                  id: headerText
                  visible: rowItem.modelData.kind === "header"
                  anchors.left: parent.left
                  anchors.bottom: parent.bottom
                  anchors.bottomMargin: Style.space(3)
                  text: rowItem.modelData.kind === "header" ? rowItem.modelData.label : ""
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                // Inert copy (empty states, loading, errors)
                Text {
                  id: noteText
                  visible: rowItem.modelData.kind === "note"
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(4)
                  textFormat: Text.PlainText
                  text: rowItem.modelData.kind === "note" ? rowItem.modelData.text : ""
                  color: rowItem.modelData.kind === "note" && rowItem.modelData.dim === false ? root.urgent : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.Wrap
                }

                // Item row
                Rectangle {
                  visible: rowItem.isItem
                  anchors.fill: parent
                  radius: Style.cornerRadius
                  color: rowItem.hasCursor ? Style.hoverFillFor(root.foreground, root.accent)
                       : (rowItem.isNow ? Style.normalFillFor(root.foreground, root.accent) : "transparent")

                  Row {
                    anchors.left: parent.left
                    anchors.right: rowActions.left
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.space(6)
                    anchors.rightMargin: Style.space(6)
                    spacing: Style.space(10)

                    RoundedArt {
                      id: rowArt
                      width: Style.space(36)
                      height: Style.space(36)
                      source: rowItem.isItem ? (rowItem.item.liked ? "" : Model.artSource(rowItem.item)) : ""
                      placeholder: rowItem.isItem ? (rowItem.item.liked ? Model.glyph.heart : Model.typeGlyph(rowItem.item.type)) : Model.glyph.note
                      cornerRadius: rowItem.isItem && rowItem.item.type === "artist" ? width / 2 : (Style.cornerRadius > 0 ? Style.space(4) : 0)
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Column {
                      width: parent.width - rowArt.width - parent.spacing
                      spacing: Style.space(2)
                      anchors.verticalCenter: parent.verticalCenter

                      Row {
                        width: parent.width
                        spacing: Style.space(6)

                        Text {
                          textFormat: Text.PlainText
                          text: rowItem.isItem ? rowItem.item.name : ""
                          width: Math.min(implicitWidth, parent.width - (nowGlyph.visible ? nowGlyph.width + parent.spacing : 0))
                          color: rowItem.isNow ? root.accent : root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.body
                          font.bold: rowItem.hasCursor || rowItem.isNow
                          elide: Text.ElideRight
                        }
                        Text {
                          textFormat: Text.PlainText
                          id: nowGlyph
                          visible: rowItem.isNow
                          text: root.isPlaying ? Model.glyph.volumeHigh : Model.glyph.pause
                          color: root.accent
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                          anchors.verticalCenter: parent.verticalCenter
                        }
                      }

                      Text {
                        width: parent.width
                        textFormat: Text.PlainText
                        text: rowItem.isItem ? Model.subtitle(rowItem.item) : ""
                        visible: text !== ""
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }

                      // Resume progress for episodes and chapters.
                      Rectangle {
                        visible: rowItem.isItem && (rowItem.item.type === "episode" || rowItem.item.type === "chapter") && rowItem.progress > 0
                        width: parent.width
                        height: Style.space(2)
                        radius: 1
                        color: Style.selectedFillFor(root.foreground, root.accent)

                        Rectangle {
                          width: parent.width * rowItem.progress
                          height: parent.height
                          radius: parent.radius
                          color: rowItem.progress >= 1 ? root.dim : root.accent
                        }
                      }
                    }
                  }

                  Row {
                    id: rowActions
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(4)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(2)
                    visible: rowItem.hasCursor
                    width: visible ? implicitWidth : 0

                    PanelActionButton {
                      visible: rowItem.queueable
                      iconText: Model.glyph.queue
                      tooltipText: "Add to queue (q)"
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onClicked: if (root.service) root.service.queueAdd(rowItem.item)
                    }
                    PanelActionButton {
                      iconText: Model.glyph.play
                      tooltipText: Model.opensDetail(rowItem.item) ? "Play all" : "Play"
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onClicked: if (rowItem.isItem) root.playRowItem(rowItem.item)
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    anchors.rightMargin: rowActions.visible ? rowActions.width + Style.space(6) : 0
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                    onEntered: root.cursorIndex = rowItem.index
                    onClicked: function(mouse) {
                      if (mouse.button === Qt.RightButton || mouse.button === Qt.MiddleButton) {
                        if (rowItem.queueable && root.service) root.service.queueAdd(rowItem.item)
                        else if (rowItem.isItem) root.playRowItem(rowItem.item)
                        return
                      }
                      root.activateRow(rowItem.index)
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
