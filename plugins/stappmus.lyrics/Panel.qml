pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root

  moduleName: "stappmus.lyrics"
  ipcTarget: "stappmus.lyrics"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color background: Color.background
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property var spotifyService: bar && bar.shell
    && typeof bar.shell.serviceFor === "function"
      ? bar.shell.serviceFor("quickshell.spotify") : null
  readonly property bool lyricsReady: lyricsService.lyricsState === "ready"
    && lyricsService.lyrics && String(lyricsService.lyrics.plainLyrics || "") !== ""
  readonly property var verification: lyricsService.lyrics
    && lyricsService.lyrics.verification ? lyricsService.lyrics.verification : ({
      level: "unavailable", label: "Checking", detail: "", sources: []
    })
  readonly property color verificationColor:
    verification.level === "conflict" || verification.level === "unavailable"
      ? urgent : foreground
  readonly property real desiredPanelHeight: page === "lyrics"
    ? Style.space(700)
    : (lyricsService.results.length > 0
      ? Style.space(620)
      : (lyricsService.searching ? Style.space(280) : Style.space(240)))
  readonly property real desiredPanelWidth: page === "lyrics"
    || lyricsService.results.length > 0
      ? Style.space(540) : Style.space(440)

  property string page: "search"
  property var selectedSong: null
  property int resultCursor: 0
  property real autoScrollLinesPerSecond: configuredLineRate()
  property int detachedPlacementAttempt: 0
  property bool detachedOpenPending: false
  property real initialPlaybackPositionSeconds: 0
  property real initialPlaybackDurationSeconds: 0
  readonly property real playbackScrollContextFraction: 0.4

  function clampedLineRate(value) {
    var number = Number(value)
    if (!isFinite(number)) number = 1
    return Math.max(0.25, Math.min(3, Math.round(number * 4) / 4))
  }

  function configuredLineRate() {
    var configured = settings ? settings.autoScrollLinesPerSecond : undefined
    if (configured !== undefined && configured !== null
        && String(configured) !== "")
      return clampedLineRate(configured)

    // Releases before 0.1.1 stored pixels per second. Twenty-eight pixels was
    // the old default and is approximately one rendered lyric line here.
    var legacyPixels = settings ? Number(settings.autoScrollSpeed) : NaN
    return isFinite(legacyPixels) ? clampedLineRate(legacyPixels / 28) : 1
  }

  function lineRateSetting(value) {
    return String(clampedLineRate(value))
  }

  function lineRateLabel(value) {
    var rate = clampedLineRate(value)
    return lineRateSetting(rate) + (Math.abs(rate - 1) < 0.001
      ? " line/s" : " lines/s")
  }

  function persistLineRate(value) {
    autoScrollLinesPerSecond = clampedLineRate(value)
    var entry = { id: root.moduleName }
    for (var key in settings) {
      if (key !== "id" && key !== "autoScrollSpeed") entry[key] = settings[key]
    }
    entry.autoScrollLinesPerSecond = lineRateSetting(autoScrollLinesPerSecond)
    settings = entry
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function currentSpotifySong() {
    var service = spotifyService
    if (!service || service.playing !== true || !service.currentLyricsSong)
      return null

    var source = service.currentLyricsSong
    var song = ({})
    for (var key in source) song[key] = source[key]
    song.positionSeconds = Math.max(0, Number(service.positionSeconds) || 0)
    return song
  }

  function showPanel() {
    controller.show()
    Qt.callLater(function() {
      if (root.page === "search") searchField.forceActiveFocus()
      else keyCatcher.forceActiveFocus()
    })
  }

  function open() {
    var spotifySong = currentSpotifySong()
    if (spotifySong) openSong(spotifySong)
    showPanel()
  }

  function close() {
    autoScroll.pause()
    controller.hide()
  }

  function openDetached() {
    if (!lyricsReady) return false
    autoScroll.pause()
    detachedAutoScroll.pause()
    detachedLyricsFlick.contentY = Number(detachedLyricsFlick.originY) || 0
    detachedOpenPending = true
    if (!detachedRuleProcess.running) {
      detachedRuleProcess.command = ["hyprctl", "eval",
        'if stappmus_lyrics_popout_rule == nil then '
        + 'stappmus_lyrics_popout_rule = hl.window_rule({ '
        + 'name = "stappmus-lyrics-popout-pre-map", '
        + 'match = { class = "org[.]quickshell", '
        + 'title = "Popout — Omasing" }, '
        + 'float = true, size = { 560, 760 }, '
        + 'move = { "(monitor_w-window_w)/2", '
        + '"(monitor_h-window_h)/2" } }) '
        + 'else stappmus_lyrics_popout_rule:set_enabled(true) end']
      detachedRuleProcess.running = true
    }
    return true
  }

  function showDetachedWindow() {
    if (!detachedOpenPending || !lyricsReady) {
      detachedOpenPending = false
      return
    }
    detachedOpenPending = false
    detachedWindow.visible = true
    close()
    Qt.callLater(function() {
      detachedAutoScroll.seekToPlaybackPosition(
        root.initialPlaybackPositionSeconds,
        root.initialPlaybackDurationSeconds,
        root.playbackScrollContextFraction)
      detachedFocus.forceActiveFocus()
    })
  }

  function closeDetached() {
    detachedOpenPending = false
    detachedAutoScroll.pause()
    detachedWindow.visible = false
  }

  function placeDetachedWindow() {
    if (!detachedWindow.visible) return
    // The pre-map rule handles initial float, size, and position. Keep this
    // address probe as a fallback and for the recenter IPC action.
    if (detachedPlacementProbe.running || detachedPlacementProcess.running) return
    detachedPlacementProbe.command = ["hyprctl", "clients", "-j"]
    detachedPlacementProbe.running = true
  }

  function runDetachedPlacement() {
    detachedPlacementProcess.command = ["hyprctl", "--batch",
      'dispatch hl.dsp.window.float({ action = "enable", window = "title:.*Omasing" }); '
      + 'dispatch hl.dsp.window.resize({ x = 560, y = 760, window = "title:.*Omasing" }); '
      + 'dispatch hl.dsp.window.center({ window = "title:.*Omasing" })']
    detachedPlacementProcess.running = true
  }

  function showSearch() {
    autoScroll.pause()
    lyricsService.cancelLyrics()
    page = "search"
    Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  function performSearch() {
    var query = String(searchField.text || "").trim()
    if (query.length < 2) {
      lyricsService.clearSearch()
      return
    }
    lyricsService.search(query)
  }

  function openSong(song) {
    if (!song) return
    initialPlaybackDurationSeconds = Math.max(0, Number(song.duration) || 0)
    initialPlaybackPositionSeconds = Math.max(0,
      Number(song.positionSeconds) || 0)
    selectedSong = song
    page = "lyrics"
    autoScroll.pause()
    detachedAutoScroll.pause()
    lyricsFlick.contentY = Number(lyricsFlick.originY) || 0
    lyricsService.fetchLyrics(song)
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function positionLyricsAtPlayback() {
    autoScroll.seekToPlaybackPosition(initialPlaybackPositionSeconds,
      initialPlaybackDurationSeconds, playbackScrollContextFraction)
    if (detachedWindow.visible)
      detachedAutoScroll.seekToPlaybackPosition(initialPlaybackPositionSeconds,
        initialPlaybackDurationSeconds, playbackScrollContextFraction)
  }

  function openLyrics(songJson) {
    var song = null
    try { song = JSON.parse(String(songJson || "")) } catch (error) {}
    if (!song || !String(song.title || "").trim()
        || !String(song.artist || "").trim()) return "invalid-song"
    openSong(song)
    showPanel()
    return "ok"
  }

  function retryLyrics() {
    if (!selectedSong) return
    lyricsService.loadedLyricsKey = ""
    lyricsService.fetchLyrics(selectedSong)
  }

  function moveResult(delta) {
    if (!lyricsService.results.length) return
    resultCursor = Math.max(0, Math.min(lyricsService.results.length - 1,
      resultCursor + Number(delta || 0)))
    resultsList.positionViewAtIndex(resultCursor, ListView.Contain)
  }

  function activateCurrent() {
    if (page === "search") {
      if (lyricsService.results.length > 0)
        openSong(lyricsService.results[Math.max(0, Math.min(resultCursor,
          lyricsService.results.length - 1))])
    } else toggleAutoScroll()
  }

  function toggleAutoScroll() {
    if (!lyricsReady) return
    if (autoScroll.running) {
      autoScroll.pause()
      return
    }
    if (lyricsFlick.contentY >= autoScroll.maximumContentY() - 1)
      lyricsFlick.contentY = Number(lyricsFlick.originY) || 0
    autoScroll.start()
  }

  function nudgeLyrics(direction) {
    if (!lyricsReady) return
    autoScroll.pause()
    lyricsFastScroll.scrollByDeltasAnimated(0, -120 * Number(direction || 0))
  }

  function toggleDetachedAutoScroll() {
    if (!lyricsReady) return
    if (detachedAutoScroll.running) {
      detachedAutoScroll.pause()
      return
    }
    if (detachedLyricsFlick.contentY >= detachedAutoScroll.maximumContentY() - 1)
      detachedLyricsFlick.contentY = Number(detachedLyricsFlick.originY) || 0
    detachedAutoScroll.start()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (!opened) autoScroll.pause()
    else Qt.callLater(function() {
      if (root.page === "search") searchField.forceActiveFocus()
      else keyCatcher.forceActiveFocus()
    })
  }
  onSettingsChanged: {
    if (!speedSlider.dragging && !detachedSpeedSlider.dragging)
      autoScrollLinesPerSecond = configuredLineRate()
  }

  Connections {
    target: lyricsService
    function onSearchApplied() {
      root.resultCursor = 0
      if (resultsList) resultsList.positionViewAtBeginning()
    }
    function onLyricsLoaded(payload) {
      if (payload && payload.song) root.selectedSong = payload.song
      autoScroll.pause()
      detachedAutoScroll.pause()
      Qt.callLater(function() {
        root.positionLyricsAtPlayback()
        keyCatcher.forceActiveFocus()
      })
    }
  }

  Timer {
    id: searchDelay
    interval: 320
    repeat: false
    onTriggered: root.performSearch()
  }

  Timer {
    id: detachedPlacementTimer
    interval: 60
    repeat: false
    onTriggered: root.placeDetachedWindow()
  }

  LyricsService { id: lyricsService }

  Process {
    id: detachedRuleProcess
    running: false
    command: []

    stdout: StdioCollector {
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: detachedRuleErrors
      waitForEnd: true
    }
    onExited: function() {
      var errorText = String(detachedRuleErrors.text || "").trim()
      if (errorText !== "") console.warn("Omasing pop-out rule:", errorText)
      root.showDetachedWindow()
    }
  }

  Process {
    id: detachedPlacementProbe
    running: false
    command: []

    stdout: StdioCollector {
      id: detachedPlacementProbeOutput
      waitForEnd: true
    }
    onExited: function() {
      var found = false
      try {
        var clients = JSON.parse(String(detachedPlacementProbeOutput.text || "[]"))
        for (var i = 0; i < clients.length; ++i) {
          var client = clients[i]
          if (String(client.class || "") === "org.quickshell"
              && /Omasing$/.test(String(client.title || ""))) {
            found = true
            break
          }
        }
      } catch (error) { /* retry below */ }

      root.detachedPlacementAttempt += 1
      if (!detachedWindow.visible) return
      if (found) {
        root.runDetachedPlacement()
      } else if (root.detachedPlacementAttempt < 40) {
        detachedPlacementTimer.restart()
      }
    }
  }

  Process {
    id: detachedPlacementProcess
    running: false
    command: []

    stdout: StdioCollector {
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: detachedPlacementErrors
      waitForEnd: true
    }
    onExited: function() {
      var errorText = String(detachedPlacementErrors.text || "").trim()
      if (errorText !== "") console.warn("Omasing pop-out placement:", errorText)
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function status(): string {
      return root.opened ? "open" : (detachedWindow.visible ? "detached" : "closed")
    }
    function popout(): string { return root.openDetached() ? "ok" : "lyrics-not-ready" }
    function dock(): void { root.closeDetached() }
    function recenter(): void {
      root.detachedPlacementAttempt = 0
      root.placeDetachedWindow()
    }
    function search(query: string): string {
      root.open()
      searchField.text = query
      root.page = "search"
      lyricsService.search(query)
      return "ok"
    }
    function lyrics(songJson: string): string { return root.openLyrics(songJson) }
    function select(index: int): string {
      if (index < 0 || index >= lyricsService.results.length) return "invalid-result"
      root.openSong(lyricsService.results[index])
      return "ok"
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰎈"
    tooltipText: detachedWindow.visible ? "Lyrics · detached" : "Lyrics"
    onPressed: function(buttonCode) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    centerOnBar: true
    contentWidth: panel.fittedContentWidth(root.desiredPanelWidth)
    contentHeight: panel.cappedContentHeight(root.desiredPanelHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: (root.page === "search" && searchField.activeFocus)
        || speedSlider.dragging
      onMoveRequested: function(dx, dy) {
        if (root.page === "search") {
          if (dy !== 0) root.moveResult(dy)
        } else {
          if (dy !== 0) root.nudgeLyrics(dy)
          if (dx !== 0)
            root.persistLineRate(root.autoScrollLinesPerSecond + dx * 0.25)
        }
      }
      onActivateRequested: root.activateCurrent()
      onCloseRequested: {
        if (root.page === "lyrics") root.showSearch()
        else root.close()
      }
      onTabRequested: function(direction) {
        if (root.page === "search") searchField.forceActiveFocus()
        else autoButton.forceActiveFocus()
      }
      onTextKey: function(text) {
        if (text === "/") {
          root.showSearch()
          Qt.callLater(function() { searchField.forceActiveFocus() })
        }
      }

      Item {
        id: searchPage
        anchors.fill: parent
        visible: root.page === "search"

        Column {
          id: searchHeader
          width: parent.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Omasing"
            meta: "LYRICS WITHOUT THE AD MAZE"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: "󰎈"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(8)

            TextField {
              id: searchField
              width: parent.width - searchButton.width - parent.spacing
              placeholderText: "Song, artist, or a lyric fragment…"
              foreground: root.foreground
              accent: root.accent
              onTextEdited: {
                if (String(text || "").trim().length < 2)
                  lyricsService.clearSearch()
                searchDelay.restart()
              }
              onAccepted: {
                searchDelay.stop()
                root.performSearch()
                keyCatcher.forceActiveFocus()
              }
              Keys.onDownPressed: function(event) {
                if (lyricsService.results.length > 0) {
                  root.resultCursor = 0
                  keyCatcher.forceActiveFocus()
                  event.accepted = true
                }
              }
              Keys.onEscapePressed: function(event) {
                if (text !== "") {
                  text = ""
                  lyricsService.clearSearch()
                } else root.close()
                event.accepted = true
              }
            }

            Button {
              id: searchButton
              text: "Search"
              iconText: lyricsService.searching ? "󰑓" : "󰍉"
              iconSpinning: lyricsService.searching
              enabled: String(searchField.text || "").trim().length >= 2
              foreground: root.foreground
              focusable: true
              bordered: true
              onClicked: {
                searchDelay.stop()
                root.performSearch()
                keyCatcher.forceActiveFocus()
              }
            }
          }

          Text {
            width: parent.width
            visible: lyricsService.searching || lyricsService.searchState !== "idle"
            text: lyricsService.searching ? "Checking catalog matches…"
              : lyricsService.searchMessage
            color: lyricsService.searchState === "error" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        ListView {
          id: resultsList
          anchors.top: searchHeader.bottom
          anchors.topMargin: Style.space(12)
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          model: lyricsService.results
          clip: true
          spacing: Style.space(4)
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height
          currentIndex: root.resultCursor

          delegate: Item {
            id: resultRow
            required property var modelData
            required property int index
            property bool selected: index === root.resultCursor
            width: resultsList.width
            height: Style.space(72)

            Rectangle {
              anchors.fill: parent
              radius: Style.cornerRadius
              color: resultRow.selected || rowMouse.containsMouse
                ? Style.hoverFillFor(root.foreground, root.accent) : "transparent"
              border.width: resultRow.selected ? Math.max(1, Style.normalBorderWidth) : 0
              border.color: root.accent
              Behavior on color { ColorAnimation { duration: 90 } }
            }

            Row {
              anchors.fill: parent
              anchors.margins: Style.space(8)
              spacing: Style.space(12)

              Rectangle {
                id: artwork
                width: height
                height: parent.height
                radius: Style.cornerRadius
                color: Style.normalFillFor(root.foreground, root.accent)
                clip: true

                Image {
                  id: cover
                  anchors.fill: parent
                  source: String(resultRow.modelData.coverUrl || "")
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                  cache: true
                  visible: status === Image.Ready
                }
                Text {
                  anchors.centerIn: parent
                  visible: !cover.visible
                  text: "󰎈"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.icon
                }
              }

              Column {
                width: Math.max(0, parent.width - artwork.width
                  - durationText.width - parent.spacing * 2)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(3)

                Text {
                  width: parent.width
                  text: String(resultRow.modelData.title || "Unknown song")
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  elide: Text.ElideRight
                }
                Text {
                  width: parent.width
                  text: String(resultRow.modelData.artist || "Unknown artist")
                    + (resultRow.modelData.album
                      ? " · " + String(resultRow.modelData.album) : "")
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }
                Text {
                  width: parent.width
                  text: resultRow.modelData.hasSynced
                    ? "Timed lyrics available" : String(resultRow.modelData.source || "")
                  color: root.dim
                  opacity: 0.78
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              Text {
                id: durationText
                anchors.verticalCenter: parent.verticalCenter
                text: String(resultRow.modelData.durationLabel || "")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            MouseArea {
              id: rowMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: root.resultCursor = resultRow.index
              onClicked: root.openSong(resultRow.modelData)
            }
          }

          FastScrollHandler {
            parent: resultsList
            flickable: resultsList
          }

          QQC.ScrollBar.vertical: QQC.ScrollBar {
            policy: QQC.ScrollBar.AsNeeded
          }
        }

        Column {
          anchors.centerIn: resultsList
          width: Math.min(resultsList.width, Style.space(380))
          spacing: Style.space(10)
          visible: !lyricsService.searching && lyricsService.results.length === 0

          Text {
            width: parent.width
            text: lyricsService.searchState === "error" ? "󰅚" : "󰎈"
            color: lyricsService.searchState === "error" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            horizontalAlignment: Text.AlignHCenter
          }
          Text {
            width: parent.width
            text: lyricsService.searchMessage
            color: lyricsService.searchState === "error" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }

      Item {
        id: lyricsPage
        anchors.fill: parent
        visible: root.page === "lyrics"

        Column {
          id: lyricsHeader
          width: parent.width
          spacing: Style.space(10)

          Row {
            width: parent.width
            spacing: Style.space(10)

            Button {
              id: backButton
              iconText: "󰁍"
              tooltipText: "Back to search"
              foreground: root.foreground
              focusable: true
              bordered: true
              onClicked: root.showSearch()
            }

            Column {
              width: Math.max(1, parent.width - backButton.width
                - (verificationBadge.visible ? verificationBadge.width : 0)
                - parent.spacing * (verificationBadge.visible ? 2 : 1))
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                width: parent.width
                text: root.selectedSong ? String(root.selectedSong.title || "Lyrics") : "Lyrics"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
              }
              Text {
                width: parent.width
                text: root.selectedSong ? String(root.selectedSong.artist || "")
                  + (root.selectedSong.album ? " · " + String(root.selectedSong.album) : "") : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
            }

            Rectangle {
              id: verificationBadge
              visible: lyricsService.loadingLyrics
                || root.verification.level !== "single"
              anchors.verticalCenter: parent.verticalCenter
              implicitWidth: badgeText.implicitWidth + Style.space(16)
              implicitHeight: badgeText.implicitHeight + Style.space(8)
              radius: Style.cornerRadius
              color: Style.selectedFillFor(root.verificationColor, root.accent)
              border.width: Math.max(1, Style.normalBorderWidth)
              border.color: root.verificationColor

              Text {
                id: badgeText
                anchors.centerIn: parent
                text: lyricsService.loadingLyrics ? "Checking…"
                  : String(root.verification.label || "Unverified")
                color: root.verificationColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(10)
            visible: root.lyricsReady

            Button {
              id: autoButton
              text: autoScroll.running ? "Pause" : "Auto-scroll"
              iconText: autoScroll.running ? "󰏤" : "󰐊"
              foreground: root.foreground
              selected: autoScroll.running
              focusable: true
              bordered: true
              onClicked: root.toggleAutoScroll()
            }

            Text {
              id: speedCaption
              anchors.verticalCenter: parent.verticalCenter
              text: "SPEED"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            PanelSlider {
              id: speedSlider
              width: Math.max(Style.space(120), parent.width - autoButton.width
                - speedLabel.width - speedCaption.width - popoutButton.width
                - parent.spacing * 4)
              anchors.verticalCenter: parent.verticalCenter
              bar: root.bar
              minimum: 1
              maximum: 12
              step: 1
              integer: true
              value: root.autoScrollLinesPerSecond * 4
              onMoved: function(value) {
                root.autoScrollLinesPerSecond = root.clampedLineRate(value / 4)
              }
              onReleased: function(value) { root.persistLineRate(value / 4) }
            }

            Text {
              id: speedLabel
              anchors.verticalCenter: parent.verticalCenter
              text: root.lineRateLabel(root.autoScrollLinesPerSecond)
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Button {
              id: popoutButton
              text: "Pop out"
              iconText: "↗"
              tooltipText: "Open a movable lyrics-only window"
              foreground: root.foreground
              focusable: true
              bordered: true
              onClicked: root.openDetached()
            }
          }

          PanelSeparator { width: parent.width }
        }

        Item {
          id: lyricsViewport
          anchors.top: lyricsHeader.bottom
          anchors.topMargin: Style.space(10)
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom

          Flickable {
            id: lyricsFlick
            anchors.fill: parent
            visible: root.lyricsReady
            clip: true
            contentWidth: width
            contentHeight: lyricContent.height
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.VerticalFlick
            pixelAligned: false
            interactive: contentHeight > height
            onMovementStarted: if (autoScroll.running) autoScroll.pause()

            Item {
              id: lyricContent
              width: lyricsFlick.width
              height: lyricText.implicitHeight + Style.space(36)

              Text {
                id: lyricText
                x: Style.space(12)
                y: Style.space(8)
                width: parent.width - Style.space(28)
                text: lyricsService.lyrics
                  ? String(lyricsService.lyrics.plainLyrics || "") : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Math.max(Style.font.body, Style.space(17))
                lineHeight: 1.42
                lineHeightMode: Text.ProportionalHeight
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
                renderType: Text.QtRendering
              }
            }

            FastScrollHandler {
              id: lyricsFastScroll
              parent: lyricsFlick
              flickable: lyricsFlick
              onScrolled: if (autoScroll.running) autoScroll.pause()
            }

            QQC.ScrollBar.vertical: QQC.ScrollBar {
              policy: QQC.ScrollBar.AsNeeded
            }
          }

          Column {
            anchors.centerIn: parent
            width: Math.min(parent.width, Style.space(410))
            spacing: Style.space(12)
            visible: !root.lyricsReady

            Text {
              width: parent.width
              text: lyricsService.loadingLyrics ? "󰑓"
                : (lyricsService.lyricsState === "instrumental" ? "󰎈" : "󰅚")
              color: lyricsService.lyricsState === "error"
                || lyricsService.lyricsState === "not-found" ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
              horizontalAlignment: Text.AlignHCenter

              RotationAnimation on rotation {
                from: 0
                to: 360
                duration: 900
                loops: Animation.Infinite
                running: lyricsService.loadingLyrics
              }
            }
            Text {
              width: parent.width
              text: lyricsService.lyricsMessage
              color: lyricsService.lyricsState === "error"
                || lyricsService.lyricsState === "not-found" ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.Wrap
              horizontalAlignment: Text.AlignHCenter
            }
            Button {
              anchors.horizontalCenter: parent.horizontalCenter
              visible: !lyricsService.loadingLyrics
                && lyricsService.lyricsState !== "instrumental"
              text: "Try again"
              iconText: "󰑐"
              foreground: root.foreground
              bordered: true
              focusable: true
              onClicked: root.retryLyrics()
            }
          }
        }
      }
    }
  }

  AutoScrollController {
    id: autoScroll
    flickable: lyricsFlick
    boundsHelper: lyricsFastScroll
    linesPerSecond: root.autoScrollLinesPerSecond
    pixelsPerLine: lyricText.lineCount > 0
      ? lyricText.implicitHeight / lyricText.lineCount
      : lyricText.font.pixelSize * lyricText.lineHeight
  }

  FloatingWindow {
    id: detachedWindow
    visible: false
    title: "Popout — Omasing"
    color: root.background
    implicitWidth: Style.space(560)
    implicitHeight: Style.space(760)
    minimumSize: Qt.size(Style.space(380), Style.space(420))

    onVisibleChanged: {
      if (!visible) detachedAutoScroll.pause()
      else {
        root.detachedPlacementAttempt = 0
        detachedPlacementTimer.restart()
        Qt.callLater(function() { detachedFocus.forceActiveFocus() })
      }
    }

    FocusScope {
      id: detachedFocus
      anchors.fill: parent
      focus: true

      Keys.onEscapePressed: function(event) {
        root.closeDetached()
        event.accepted = true
      }
      Keys.onSpacePressed: function(event) {
        root.toggleDetachedAutoScroll()
        event.accepted = true
      }
      Keys.onUpPressed: function(event) {
        detachedAutoScroll.pause()
        detachedFastScroll.scrollByDeltasAnimated(0, 120)
        event.accepted = true
      }
      Keys.onDownPressed: function(event) {
        detachedAutoScroll.pause()
        detachedFastScroll.scrollByDeltasAnimated(0, -120)
        event.accepted = true
      }

      Rectangle {
        anchors.fill: parent
        color: root.background
      }

      Item {
        id: detachedTitleBar
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: Style.space(58)

        Row {
          anchors.fill: parent
          anchors.leftMargin: Style.space(14)
          anchors.rightMargin: Style.space(10)
          spacing: Style.space(10)

          Item {
            id: detachedDragArea
            width: Math.max(1, parent.width - detachedCloseButton.width - parent.spacing)
            height: parent.height

            Row {
              anchors.fill: parent
              spacing: Style.space(10)

              Text {
                id: detachedDragHandle
                anchors.verticalCenter: parent.verticalCenter
                text: "⠿"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
              }

              Column {
                width: Math.max(1, parent.width - detachedDragHandle.width
                  - parent.spacing)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  width: parent.width
                  text: root.selectedSong
                    ? String(root.selectedSong.title || "Lyrics") : "Lyrics"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                  elide: Text.ElideRight
                }
                Text {
                  width: parent.width
                  text: (root.selectedSong ? String(root.selectedSong.artist || "") : "")
                    + (root.verification.level !== "single" && root.verification.label
                      ? " · " + String(root.verification.label) : "")
                  color: root.verification.level === "conflict"
                    ? root.urgent : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.SizeAllCursor
              onPressed: function(mouse) {
                detachedWindow.startSystemMove()
                mouse.accepted = true
              }
            }
          }

          Button {
            id: detachedCloseButton
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰅖"
            tooltipText: "Close detached lyrics"
            foreground: root.foreground
            focusable: true
            bordered: true
            onClicked: root.closeDetached()
          }
        }
      }

      PanelSeparator {
        id: detachedTitleSeparator
        anchors.top: detachedTitleBar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
      }

      Row {
        id: detachedControls
        anchors.top: detachedTitleSeparator.bottom
        anchors.topMargin: Style.space(8)
        anchors.left: parent.left
        anchors.leftMargin: Style.space(14)
        anchors.right: parent.right
        anchors.rightMargin: Style.space(14)
        height: Math.max(detachedAutoButton.implicitHeight, detachedSpeedLabel.height)
        spacing: Style.space(9)

        Button {
          id: detachedAutoButton
          text: detachedAutoScroll.running ? "Pause" : "Auto-scroll"
          iconText: detachedAutoScroll.running ? "󰏤" : "󰐊"
          foreground: root.foreground
          selected: detachedAutoScroll.running
          focusable: true
          bordered: true
          onClicked: root.toggleDetachedAutoScroll()
        }

        Text {
          id: detachedSpeedCaption
          anchors.verticalCenter: parent.verticalCenter
          text: "SPEED"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        PanelSlider {
          id: detachedSpeedSlider
          width: Math.max(Style.space(100), parent.width - detachedAutoButton.width
            - detachedSpeedLabel.width - detachedSpeedCaption.width
            - parent.spacing * 3)
          anchors.verticalCenter: parent.verticalCenter
          bar: root.bar
          minimum: 1
          maximum: 12
          step: 1
          integer: true
          value: root.autoScrollLinesPerSecond * 4
          onMoved: function(value) {
            root.autoScrollLinesPerSecond = root.clampedLineRate(value / 4)
          }
          onReleased: function(value) { root.persistLineRate(value / 4) }
        }

        Text {
          id: detachedSpeedLabel
          anchors.verticalCenter: parent.verticalCenter
          text: root.lineRateLabel(root.autoScrollLinesPerSecond)
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }

      PanelSeparator {
        id: detachedControlsSeparator
        anchors.top: detachedControls.bottom
        anchors.topMargin: Style.space(8)
        anchors.left: parent.left
        anchors.right: parent.right
      }

      Flickable {
        id: detachedLyricsFlick
        anchors.top: detachedControlsSeparator.bottom
        anchors.topMargin: Style.space(8)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: root.lyricsReady
        clip: true
        contentWidth: width
        contentHeight: detachedLyricContent.height
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        pixelAligned: false
        interactive: contentHeight > height
        onMovementStarted: if (detachedAutoScroll.running) detachedAutoScroll.pause()

        Item {
          id: detachedLyricContent
          width: detachedLyricsFlick.width
          height: detachedLyricText.implicitHeight + Style.space(48)

          Text {
            id: detachedLyricText
            x: Style.space(28)
            y: Style.space(14)
            width: parent.width - Style.space(60)
            text: lyricsService.lyrics
              ? String(lyricsService.lyrics.plainLyrics || "") : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Math.max(Style.font.body, Style.space(18))
            lineHeight: 1.5
            lineHeightMode: Text.ProportionalHeight
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
            renderType: Text.QtRendering
          }
        }

        FastScrollHandler {
          id: detachedFastScroll
          parent: detachedLyricsFlick
          flickable: detachedLyricsFlick
          onScrolled: if (detachedAutoScroll.running) detachedAutoScroll.pause()
        }

        QQC.ScrollBar.vertical: QQC.ScrollBar {
          policy: QQC.ScrollBar.AsNeeded
        }
      }

      Text {
        anchors.centerIn: detachedLyricsFlick
        width: Math.min(parent.width - Style.space(48), Style.space(420))
        visible: !root.lyricsReady
        text: lyricsService.lyricsMessage
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
      }
    }
  }

  AutoScrollController {
    id: detachedAutoScroll
    flickable: detachedLyricsFlick
    boundsHelper: detachedFastScroll
    linesPerSecond: root.autoScrollLinesPerSecond
    pixelsPerLine: detachedLyricText.lineCount > 0
      ? detachedLyricText.implicitHeight / detachedLyricText.lineCount
      : detachedLyricText.font.pixelSize * detachedLyricText.lineHeight
  }
}
