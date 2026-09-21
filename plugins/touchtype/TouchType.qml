import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "Curriculum.js" as Curriculum
import "Corpus.js" as Corpus
import "ProgressStore.js" as Progress

// Touch Type — guided touch-typing trainer overlay.
//
// Screens: "menu" (level select + streak/stats), "lesson" (live typing
// session with keyboard hint), "results" (accuracy/wpm/time + pass/fail +
// weak-key summary). All colors come from the Color singleton so the whole
// UI follows whatever Omarchy theme is active; only the typing font is
// forced to monospace for legibility of the target text.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property bool opened: false
  property string screen: "menu"   // "menu" | "lesson" | "results"

  // ---- theme surface -------------------------------------------------
  property color background: Color.popups.background
  property color foreground: Color.popups.text
  property color border: Color.popups.border
  property var borderSpec: Border.surfaceSpec("popups", "border", root.border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  readonly property int cornerRadius: Style.cornerRadius
  property string monoFont: "monospace"

  property int cardWidth: Math.min(Style.space(920), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(640), panel.height - Style.gapsOut * 2)

  // ---- progress persistence -------------------------------------------
  property string progressPath: Quickshell.env("HOME") + "/.local/state/omarchy/touchtype-progress.json"
  property var progress: Progress.defaultProgress()
  readonly property var levelList: Curriculum.levels(Corpus.punctuationChars)
  readonly property var fingerList: Curriculum.fingerLevels()

  // Board keys shown in Keyboard.qml, mapped to finger ids for zone tinting.
  readonly property var boardKeys: ["`", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "=",
    "q", "w", "e", "r", "t", "y", "u", "i", "o", "p", "[", "]", "\\",
    "a", "s", "d", "f", "g", "h", "j", "k", "l", ";", "'",
    "z", "x", "c", "v", "b", "n", "m", ",", ".", "/"]
  readonly property var keyFingerMap: {
    var map = {}
    for (var i = 0; i < root.boardKeys.length; i++) {
      var f = Curriculum.fingerForKey(root.boardKeys[i])
      if (f !== "") map[root.boardKeys[i]] = f
    }
    return map
  }
  readonly property var fingerColors: ({
    "index": Curriculum.fingerMeta.index.color,
    "middle": Curriculum.fingerMeta.middle.color,
    "ring": Curriculum.fingerMeta.ring.color,
    "pinky": Curriculum.fingerMeta.pinky.color
  })

  function saveProgress() {
    progressFile.setText(Progress.toJsonText(root.progress))
  }

  // ---- level select state (two independent tracks) ----------------------
  property string selectedTrack: "finger" // "finger" | "classic"
  property int selectedIndex: 0

  function trackLevels(track) {
    return track === "finger" ? root.fingerList : root.levelList
  }

  function switchTrack(track) {
    if (track !== "finger" && track !== "classic") return
    root.selectedTrack = track
    var list = root.trackLevels(track)
    root.selectedIndex = Math.max(0, Math.min(root.selectedIndex, list.length - 1))
  }

  function passedCount(track) {
    var list = root.trackLevels(track)
    var n = 0
    for (var i = 0; i < list.length; i++) {
      var entry = root.progress.levels[list[i].id]
      if (entry && entry.passed) n++
    }
    return n
  }

  // ---- admin menu state -------------------------------------------------
  property bool adminOpen: false
  property int adminIndex: 0
  property bool resetConfirmOpen: false

  readonly property var adminActions: {
    root.progress.unlockAll // reactive: label follows the persisted unlock-all flag
    return [
      { id: "unlock", label: root.progress.unlockAll ? "Lock all stages" : "Open all stages" },
      { id: "reset", label: "Reset progress", danger: true }
    ]
  }

  function toggleUnlockAll() {
    var next = JSON.parse(JSON.stringify(root.progress))
    next.unlockAll = !next.unlockAll
    root.progress = next
    root.saveProgress()
    root.adminOpen = false
  }

  function resetProgress() {
    root.progress = Progress.defaultProgress()
    root.saveProgress()
    root.resetConfirmOpen = false
    root.adminOpen = false
  }

  function runAdminAction(index) {
    var action = root.adminActions[index]
    if (!action) return
    if (action.id === "unlock") root.toggleUnlockAll()
    else if (action.id === "reset") {
      root.adminOpen = false
      root.resetConfirmOpen = true
    }
  }

  // ---- session state ----------------------------------------------------
  property string currentTrack: "classic" // track of the running lesson
  property string currentFinger: ""       // finger id for Finger Gym lessons
  property int currentLevelIndex: -1
  property string targetText: ""
  property var typedResults: []   // true/false per typed position, undefined = not yet typed
  property int typedIndex: 0
  property var sessionKeyResults: ({})
  property double sessionStart: 0
  property bool sessionStarted: false
  property bool sessionFinished: false
  property double liveNow: Date.now()
  property int renderTick: 0

  // ---- last result (for the results screen) ---------------------------
  property var lastResult: null

  readonly property var currentLevel: root.currentLevelIndex >= 0 ? root.trackLevels(root.currentTrack)[root.currentLevelIndex] : null
  readonly property string currentFingerLabel: root.currentFinger !== "" && Curriculum.fingerMeta[root.currentFinger] ? Curriculum.fingerMeta[root.currentFinger].label : ""
  readonly property color currentFingerColor: root.currentFinger !== "" && Curriculum.fingerMeta[root.currentFinger] ? Curriculum.fingerMeta[root.currentFinger].color : Color.accent

  function open(payloadJson) {
    root.opened = true
    root.screen = "menu"
    root.selectedIndex = 0
    // Re-read progress from disk each time the overlay is summoned so an
    // external change (e.g. the "Reset progress" menu action, or another
    // instance) is reflected immediately instead of showing stale state.
    progressFile.reload()
    Qt.callLater(function() { menuKeyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "touchtype")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // ---- level helpers (per-track independent unlock chains) --------------
  function unlocked(track, index) {
    return Progress.isUnlocked(root.progress, root.trackLevels(track), index)
  }

  function levelEntry(track, index) {
    return Progress.levelEntry(root.progress, root.trackLevels(track)[index].id)
  }

  function wordListFn(name) {
    return Corpus.wordList(name)
  }

  function startLevel(track, index) {
    var list = root.trackLevels(track)
    if (index < 0 || index >= list.length || !root.unlocked(track, index)) return
    var level = list[index]
    root.currentTrack = track
    root.currentFinger = level.finger || ""
    root.currentLevelIndex = index
    root.targetText = Curriculum.buildDrill(level, Math.random, root.wordListFn, Corpus.sentences)
    root.typedResults = []
    root.typedIndex = 0
    root.sessionKeyResults = {}
    root.sessionStarted = false
    root.sessionFinished = false
    root.liveNow = Date.now()
    root.renderTick++
    root.screen = "lesson"
    Qt.callLater(function() { lessonKeyCatcher.forceActiveFocus() })
  }

  function restartLevel() {
    if (root.currentLevelIndex >= 0) root.startLevel(root.currentTrack, root.currentLevelIndex)
  }

  function backToMenu() {
    root.screen = "menu"
    Qt.callLater(function() { menuKeyCatcher.forceActiveFocus() })
  }

  function recordKeyResult(expected, correct) {
    var stat = root.sessionKeyResults[expected] || { hits: 0, misses: 0 }
    if (correct) stat.hits++; else stat.misses++
    root.sessionKeyResults[expected] = stat
  }

  function handleTypedChar(ch) {
    if (root.sessionFinished || root.typedIndex >= root.targetText.length) return
    if (!root.sessionStarted) {
      root.sessionStarted = true
      root.sessionStart = Date.now()
      liveTimer.start()
    }
    var expected = root.targetText.charAt(root.typedIndex)
    var correct = ch === expected
    root.typedResults[root.typedIndex] = correct
    root.recordKeyResult(expected, correct)
    root.typedIndex++
    root.renderTick++
    if (root.typedIndex >= root.targetText.length) root.finishSession()
  }

  function handleBackspace() {
    if (root.typedIndex <= 0 || root.sessionFinished) return
    root.typedIndex--
    root.typedResults[root.typedIndex] = undefined
    root.renderTick++
  }

  function finishSession() {
    liveTimer.stop()
    root.sessionFinished = true
    var elapsedMs = Math.max(1, Date.now() - root.sessionStart)
    var correctCount = 0
    for (var i = 0; i < root.typedResults.length; i++) if (root.typedResults[i] === true) correctCount++
    var accuracy = Progress.computeAccuracy(correctCount, root.typedResults.length)
    var wpm = Progress.computeWpm(correctCount, elapsedMs)
    var result = { accuracy: accuracy, wpm: wpm, timeMs: elapsedMs, keyResults: root.sessionKeyResults }
    var outcome = Progress.recordAttempt(root.progress, root.currentLevel, result)
    root.progress = outcome.progress
    root.saveProgress()
    root.lastResult = { accuracy: accuracy, wpm: wpm, timeMs: elapsedMs, passed: outcome.passed }
    root.screen = "results"
    Qt.callLater(function() { resultsKeyCatcher.forceActiveFocus() })
  }

  function nextLevelAvailable() {
    var list = root.trackLevels(root.currentTrack)
    return root.currentLevelIndex >= 0
      && root.currentLevelIndex + 1 < list.length
      && root.unlocked(root.currentTrack, root.currentLevelIndex + 1)
  }

  function goToNextLevel() {
    if (root.nextLevelAvailable()) root.startLevel(root.currentTrack, root.currentLevelIndex + 1)
  }

  // ---- rich-text rendering of the typed/target text ---------------------
  function toHex2(n) {
    var h = Math.round(Util.clamp(n, 0, 1) * 255).toString(16)
    return h.length < 2 ? "0" + h : h
  }

  function colorHex(c) {
    return "#" + root.toHex2(c.r) + root.toHex2(c.g) + root.toHex2(c.b)
  }

  function escapeHtml(ch) {
    if (ch === "&") return "&amp;"
    if (ch === "<") return "&lt;"
    if (ch === ">") return "&gt;"
    if (ch === "'") return "&#39;"
    if (ch === "\"") return "&quot;"
    return ch
  }

  readonly property string renderedHtml: {
    root.renderTick // reactive dependency: bumped manually on every keystroke
    var target = root.targetText
    var out = ""
    var correctColor = root.colorHex(Color.foreground)
    var errorColor = root.colorHex(Color.urgent)
    var pendingColor = root.colorHex(Color.muted)
    var caretColor = root.colorHex(Color.accent)
    for (var i = 0; i < target.length; i++) {
      var ch = root.escapeHtml(target.charAt(i))
      var style
      if (i < root.typedIndex) {
        style = root.typedResults[i] === true
          ? ("color:" + correctColor)
          : ("color:" + errorColor + ";text-decoration:underline")
      } else if (i === root.typedIndex) {
        style = "color:" + caretColor + ";text-decoration:underline"
      } else {
        style = "color:" + pendingColor
      }
      out += "<span style='" + style + "'>" + ch + "</span>"
    }
    return out
  }

  readonly property string nextChar: root.targetText.length > root.typedIndex ? root.targetText.charAt(root.typedIndex) : ""

  // ---- live stats (lesson screen) ---------------------------------------
  readonly property double elapsedMs: {
    root.liveNow // reactive dependency
    return root.sessionStarted ? Math.max(0, root.liveNow - root.sessionStart) : 0
  }
  readonly property int liveCorrectCount: {
    root.renderTick
    var n = 0
    for (var i = 0; i < root.typedResults.length; i++) if (root.typedResults[i] === true) n++
    return n
  }
  readonly property real liveAccuracy: Progress.computeAccuracy(root.liveCorrectCount, root.typedIndex)
  readonly property int liveWpm: Progress.computeWpm(root.liveCorrectCount, root.elapsedMs)

  Timer {
    id: liveTimer
    interval: 200
    repeat: true
    onTriggered: root.liveNow = Date.now()
  }

  FileView {
    id: progressFile
    path: root.progressPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.progress = Progress.parse(text())
    onLoadFailed: root.progress = Progress.defaultProgress()
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-touchtype"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: content
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset

        // ================= MENU SCREEN =================
        Item {
          id: menuScreen
          anchors.fill: parent
          visible: root.screen === "menu"

          Item {
            id: menuKeyCatcher
            anchors.fill: parent
            focus: root.screen === "menu"

            Keys.onPressed: function(event) {
              if (root.resetConfirmOpen) {
                if (resetConfirm.handleKey(event)) event.accepted = true
                return
              }
              if (root.adminOpen) {
                if (event.key === Qt.Key_Escape) { root.adminOpen = false; event.accepted = true }
                else if (event.key === Qt.Key_Up) { root.adminIndex = Math.max(0, root.adminIndex - 1); event.accepted = true }
                else if (event.key === Qt.Key_Down) { root.adminIndex = Math.min(root.adminActions.length - 1, root.adminIndex + 1); event.accepted = true }
                else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.runAdminAction(root.adminIndex); event.accepted = true }
                else { event.accepted = true }
                return
              }
              if (event.key === Qt.Key_Escape) { root.dismiss(); event.accepted = true }
              else if (event.key === Qt.Key_Left || event.key === Qt.Key_Right || event.key === Qt.Key_Tab) {
                root.switchTrack(root.selectedTrack === "finger" ? "classic" : "finger")
                event.accepted = true
              }
              else if (event.key === Qt.Key_Up) { root.selectedIndex = Math.max(0, root.selectedIndex - 1); event.accepted = true }
              else if (event.key === Qt.Key_Down) { root.selectedIndex = Math.min(root.trackLevels(root.selectedTrack).length - 1, root.selectedIndex + 1); event.accepted = true }
              else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.startLevel(root.selectedTrack, root.selectedIndex); event.accepted = true }
              else if (event.text >= "1" && event.text <= "9") {
                var pickIdx = event.text.charCodeAt(0) - "1".charCodeAt(0)
                if (pickIdx < root.trackLevels(root.selectedTrack).length) root.selectedIndex = pickIdx
                event.accepted = true
              }
              else if (event.text === "0") {
                if (9 < root.trackLevels(root.selectedTrack).length) root.selectedIndex = 9
                event.accepted = true
              }
            }
          }

          Column {
            anchors.fill: parent
            spacing: Style.spacing.lg

            Item {
              id: headerItem
              width: parent.width
              height: Math.max(closeButton.height, adminButton.height, streakBadge.height, titleText.height)

              Text {
                id: titleText
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "Touch Type"
                color: root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.display
                font.bold: true
              }

              Rectangle {
                id: closeButton
                width: Style.space(28); height: Style.space(28)
                radius: width / 2
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                color: closeArea.containsMouse ? Util.alpha(Color.urgent, 0.2) : "transparent"
                Text { anchors.centerIn: parent; text: "✕"; color: root.foreground; font.pixelSize: Style.font.body }
                MouseArea { id: closeArea; anchors.fill: parent; hoverEnabled: true; onClicked: root.dismiss() }
              }

              Rectangle {
                id: adminButton
                height: Style.space(28)
                width: adminButtonText.implicitWidth + Style.spacing.lg * 2
                radius: height / 2
                anchors.right: closeButton.left
                anchors.rightMargin: Style.spacing.lg
                anchors.verticalCenter: parent.verticalCenter
                color: adminArea.containsMouse ? Util.alpha(Color.accent, 0.2) : Util.alpha(root.foreground, 0.05)
                border.width: root.adminOpen ? 1 : 0
                border.color: Color.accent

                Text {
                  id: adminButtonText
                  text: "⚙ Admin"
                  anchors.centerIn: parent
                  color: root.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }

                MouseArea {
                  id: adminArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.adminIndex = 0
                    root.adminOpen = !root.adminOpen
                  }
                }
              }

              Row {
                id: streakBadge
                spacing: Style.spacing.xs
                anchors.right: adminButton.left
                anchors.rightMargin: Style.spacing.lg
                anchors.verticalCenter: parent.verticalCenter
                Text { text: "🔥"; font.pixelSize: Style.font.heading }
                Text {
                  text: (root.progress.streak.count || 0) + " day streak"
                  color: root.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
            }

            Text {
              text: "Train each finger pair, or run the classic course. Use ←/→ to switch tracks, ↑↓ + Enter, number keys, or click."
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            Rectangle { width: parent.width; height: 1; color: Util.alpha(root.foreground, 0.1) }

            Row {
              width: parent.width
              spacing: Style.spacing.sm

              Repeater {
                model: [
                  { track: "finger", label: "🖐 Finger Gym", count: root.passedCount("finger"), total: root.fingerList.length },
                  { track: "classic", label: "⌨ Classic Course", count: root.passedCount("classic"), total: root.levelList.length }
                ]

                Rectangle {
                  required property var modelData
                  required property int index
                  readonly property bool isActive: modelData.track === root.selectedTrack

                  width: (parent.width - Style.spacing.sm) / 2
                  height: Style.space(38)
                  radius: Math.min(root.cornerRadius, 8)
                  color: isActive ? Util.alpha(Color.accent, 0.14) : Util.alpha(root.foreground, 0.04)
                  border.width: isActive ? 1 : 0
                  border.color: Color.accent

                  Text {
                    anchors.centerIn: parent
                    text: modelData.label + "  " + modelData.count + "/" + modelData.total
                    color: isActive ? Color.accent : root.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: isActive
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.switchTrack(modelData.track)
                  }
                }
              }
            }

            Column {
              width: parent.width
              spacing: Style.spacing.sm

              Repeater {
                model: root.trackLevels(root.selectedTrack)

                Rectangle {
                  id: levelRow
                  required property var modelData
                  required property int index
                  readonly property bool isSelected: index === root.selectedIndex
                  readonly property bool isUnlocked: root.unlocked(root.selectedTrack, index)
                  readonly property var entry: root.levelEntry(root.selectedTrack, index)
                  readonly property string finger: modelData.finger || ""
                  readonly property color fingerColor: finger !== "" ? root.fingerColors[finger] : "transparent"

                  width: parent.width
                  height: Style.space(52)
                  radius: Math.min(root.cornerRadius, 10)
                  color: isSelected ? Util.alpha(Color.accent, 0.14) : "transparent"
                  border.width: isSelected ? 1 : 0
                  border.color: Color.accent
                  opacity: isUnlocked ? 1 : 0.5

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: levelRow.isUnlocked ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onEntered: { root.selectedIndex = levelRow.index }
                    onClicked: root.startLevel(root.selectedTrack, levelRow.index)
                  }

                  Row {
                    anchors.fill: parent
                    anchors.leftMargin: Style.spacing.md
                    anchors.rightMargin: Style.spacing.md
                    spacing: Style.spacing.md

                    Text {
                      width: Style.space(28)
                      anchors.verticalCenter: parent.verticalCenter
                      text: levelRow.isUnlocked ? String(levelRow.index + 1) : "🔒"
                      color: levelRow.finger !== "" ? levelRow.fingerColor : (levelRow.entry.passed ? Color.accent : root.foreground)
                      font.family: Style.font.family
                      font.pixelSize: Style.font.heading
                      horizontalAlignment: Text.AlignHCenter
                    }

                    Column {
                      width: parent.width - Style.space(28) - statsCol.width - Style.spacing.md * 2
                      anchors.verticalCenter: parent.verticalCenter
                      Text {
                        text: (levelRow.entry.passed ? "✓ " : "") + levelRow.modelData.title
                        color: root.foreground
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        font.bold: true
                      }
                      Text {
                        text: levelRow.modelData.subtitle
                        color: Color.muted
                        font.family: root.monoFont
                        font.pixelSize: Style.font.bodySmall
                      }
                    }

                    Column {
                      id: statsCol
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(140)
                      Text {
                        visible: levelRow.entry.attempts > 0
                        text: "Best: " + levelRow.entry.bestWpm + " wpm · " + levelRow.entry.bestAccuracy + "%"
                        color: Color.muted
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        horizontalAlignment: Text.AlignRight
                        anchors.right: parent.right
                      }
                    }
                  }
                }
              }
            }
          }

          // Admin popup: a full-screen click-catcher layer so the popup
          // dismisses when clicking outside of it, with the menu card
          // anchored to the top-right corner just below the header.
          Item {
            id: adminPopupLayer
            anchors.fill: parent
            visible: root.adminOpen
            z: 10

            MouseArea {
              anchors.fill: parent
              onClicked: root.adminOpen = false
            }

            BorderSurface {
              id: adminCard
              width: Style.space(240)
              height: adminCard.contentTopInset + adminCard.contentBottomInset
                + root.adminActions.length * Style.space(38)
                + (root.adminActions.length - 1) * Style.spacing.xs
              anchors.top: parent.top
              anchors.topMargin: headerItem.height + Style.spacing.sm
              anchors.right: parent.right
              color: root.background
              borderSpec: root.borderSpec
              radius: root.cornerRadius
              padding: Style.spacing.xs

              MouseArea { anchors.fill: parent; onClicked: {} }

              Item {
                anchors.fill: parent
                anchors.topMargin: adminCard.contentTopInset
                anchors.rightMargin: adminCard.contentRightInset
                anchors.bottomMargin: adminCard.contentBottomInset
                anchors.leftMargin: adminCard.contentLeftInset

                Column {
                  anchors.fill: parent
                  spacing: Style.spacing.xs

                  Repeater {
                    model: root.adminActions

                    Rectangle {
                      required property var modelData
                      required property int index
                      readonly property bool isSelected: index === root.adminIndex
                      readonly property bool isDanger: modelData.danger === true
                      readonly property bool isHovered: adminHover.containsMouse

                      width: parent.width
                      height: Style.space(38)
                      radius: Math.min(root.cornerRadius, 8)
                      color: isSelected || isHovered
                        ? Util.alpha(isDanger ? Color.urgent : Color.accent, 0.14)
                        : "transparent"

                      Text {
                        anchors.left: parent.left
                        anchors.leftMargin: Style.spacing.md
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.label
                        color: isDanger && (isSelected || isHovered) ? Color.urgent
                          : ((isSelected || isHovered) ? Color.accent : root.foreground)
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        font.bold: isSelected || isHovered
                      }

                      MouseArea {
                        id: adminHover
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onEntered: root.adminIndex = index
                        onClicked: root.runAdminAction(index)
                      }
                    }
                  }
                }
              }
            }
          }
        }

        // ================= LESSON SCREEN =================
        Item {
          id: lessonScreen
          anchors.fill: parent
          visible: root.screen === "lesson"

          Item {
            id: lessonKeyCatcher
            anchors.fill: parent
            focus: root.screen === "lesson"

            Keys.priority: Keys.BeforeItem
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) { root.backToMenu(); event.accepted = true }
              else if (event.key === Qt.Key_Backspace) { root.handleBackspace(); event.accepted = true }
              else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
                root.handleTypedChar(event.text)
                event.accepted = true
              }
            }
          }

          Column {
            anchors.fill: parent
            spacing: Style.spacing.lg

            Item {
              width: parent.width
              height: lessonTitle.height

              Text {
                id: lessonTitle
                anchors.left: parent.left
                text: root.currentLevel ? ((root.currentTrack === "finger" ? "🖐 " : "") + (root.currentLevelIndex + 1) + ". " + root.currentLevel.title) : ""
                color: root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.heading
                font.bold: true
              }
              Text {
                anchors.right: parent.right
                anchors.verticalCenter: lessonTitle.verticalCenter
                text: "Esc: menu"
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            Row {
              width: parent.width
              spacing: Style.spacing.xxl

              Text {
                text: "⏱ " + (Math.floor(root.elapsedMs / 1000)) + "s"
                color: Color.muted
                font.family: root.monoFont
                font.pixelSize: Style.font.body
              }
              Text {
                text: "⌨ " + root.liveWpm + " wpm"
                color: Color.muted
                font.family: root.monoFont
                font.pixelSize: Style.font.body
              }
              Text {
                text: "🎯 " + root.liveAccuracy + "%"
                color: root.currentLevel && root.liveAccuracy >= root.currentLevel.passAccuracy ? Color.accent : Color.urgent
                font.family: root.monoFont
                font.pixelSize: Style.font.body
              }
            }

            Rectangle {
              width: parent.width
              height: Style.space(4)
              radius: height / 2
              color: Util.alpha(root.foreground, 0.1)
              Rectangle {
                width: parent.width * (root.targetText.length > 0 ? root.typedIndex / root.targetText.length : 0)
                height: parent.height
                radius: height / 2
                color: Color.accent
                Behavior on width { NumberAnimation { duration: 120 } }
              }
            }

            Rectangle {
              width: parent.width
              height: Style.space(150)
              radius: Math.min(root.cornerRadius, 10)
              color: Util.alpha(root.foreground, 0.04)
              border.width: 1
              border.color: Util.alpha(root.foreground, 0.12)

              Text {
                anchors.fill: parent
                anchors.margins: Style.spacing.lg
                text: root.renderedHtml
                textFormat: Text.RichText
                wrapMode: Text.WordWrap
                verticalAlignment: Text.AlignVCenter
                font.family: root.monoFont
                font.pixelSize: Style.font.heading
                lineHeight: 1.5
              }
            }

            Item { width: 1; height: Style.spacing.md }

            // Finger Gym banner: which finger(s) to use for this drill.
            Row {
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.spacing.sm
              visible: root.currentTrack === "finger"
              height: visible ? implicitHeight : 0

              Rectangle {
                visible: root.currentFinger !== ""
                width: Style.space(10); height: Style.space(10)
                radius: width / 2
                color: root.currentFingerColor
                anchors.verticalCenter: parent.verticalCenter
              }
              Text {
                visible: root.currentFinger !== ""
                text: root.currentFingerLabel + " — press the tinted keys"
                color: root.currentFingerColor
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                visible: root.currentFinger === ""
                text: "Keys tinted by finger:"
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                anchors.verticalCenter: parent.verticalCenter
              }
              Repeater {
                visible: root.currentFinger === ""
                model: [
                  { id: "index", abbr: "I" },
                  { id: "middle", abbr: "M" },
                  { id: "ring", abbr: "R" },
                  { id: "pinky", abbr: "P" }
                ]
                Row {
                  required property var modelData
                  spacing: Style.spacing.xs
                  Rectangle {
                    width: Style.space(10); height: Style.space(10)
                    radius: width / 2
                    color: root.fingerColors[modelData.id]
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    text: modelData.abbr
                    color: Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }
            }

            Keyboard {
              anchors.horizontalCenter: parent.horizontalCenter
              nextChar: root.nextChar
              keyFingerMap: root.currentTrack === "finger" ? root.keyFingerMap : ({})
              fingerColors: root.fingerColors
              activeFinger: root.currentTrack === "finger" ? root.currentFinger : ""
            }
          }
        }

        // ================= RESULTS SCREEN =================
        Item {
          id: resultsScreen
          anchors.fill: parent
          visible: root.screen === "results"

          Item {
            id: resultsKeyCatcher
            anchors.fill: parent
            focus: root.screen === "results"

            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) { root.backToMenu(); event.accepted = true }
              else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.restartLevel(); event.accepted = true }
              else if (event.text === "n" || event.text === "N") { root.goToNextLevel(); event.accepted = true }
            }
          }

          Column {
            anchors.centerIn: parent
            spacing: Style.spacing.lg
            width: Math.min(parent.width * 0.8, Style.space(560))

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: root.lastResult && root.lastResult.passed ? "✓ Level passed!" : "Keep practicing"
              color: root.lastResult && root.lastResult.passed ? Color.accent : root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.displayLarge
              font.bold: true
            }

            Row {
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.spacing.xxxl

              Column {
                spacing: Style.spacing.xs
                Text { text: root.lastResult ? root.lastResult.accuracy + "%" : ""; color: root.foreground; font.family: root.monoFont; font.pixelSize: Style.font.display; anchors.horizontalCenter: parent.horizontalCenter }
                Text { text: "accuracy"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption; anchors.horizontalCenter: parent.horizontalCenter }
              }
              Column {
                spacing: Style.spacing.xs
                Text { text: root.lastResult ? root.lastResult.wpm : ""; color: root.foreground; font.family: root.monoFont; font.pixelSize: Style.font.display; anchors.horizontalCenter: parent.horizontalCenter }
                Text { text: "wpm"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption; anchors.horizontalCenter: parent.horizontalCenter }
              }
              Column {
                spacing: Style.spacing.xs
                Text { text: root.lastResult ? Math.round(root.lastResult.timeMs / 1000) + "s" : ""; color: root.foreground; font.family: root.monoFont; font.pixelSize: Style.font.display; anchors.horizontalCenter: parent.horizontalCenter }
                Text { text: "time"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption; anchors.horizontalCenter: parent.horizontalCenter }
              }
            }

            Rectangle { width: parent.width; height: 1; color: Util.alpha(root.foreground, 0.1) }

            Column {
              width: parent.width
              spacing: Style.spacing.sm
              visible: weakKeysRepeater.count > 0

              Text {
                text: "Weakest keys"
                color: root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: true
              }

              Repeater {
                id: weakKeysRepeater
                model: Progress.weakestKeys(root.progress, 5)

                Row {
                  required property var modelData
                  width: parent.width
                  spacing: Style.spacing.sm

                  Text {
                    text: "'" + modelData.key + "'"
                    color: root.foreground
                    font.family: root.monoFont
                    font.pixelSize: Style.font.bodySmall
                    width: Style.space(36)
                  }
                  Rectangle {
                    width: parent.width - Style.space(36) - Style.space(50) - Style.spacing.sm * 2
                    height: Style.space(10)
                    radius: height / 2
                    color: Util.alpha(root.foreground, 0.1)
                    anchors.verticalCenter: parent.verticalCenter
                    Rectangle {
                      width: parent.width * modelData.missRate
                      height: parent.height
                      radius: height / 2
                      color: Color.urgent
                    }
                  }
                  Text {
                    text: Math.round(modelData.missRate * 100) + "%"
                    color: Color.muted
                    font.family: root.monoFont
                    font.pixelSize: Style.font.caption
                    width: Style.space(50)
                  }
                }
              }
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "Enter: retry" + (root.nextLevelAvailable() ? "   ·   N: next level" : "") + "   ·   Esc: menu"
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }
      }

      ConfirmDialog {
        id: resetConfirm
        anchors.fill: parent
        opened: root.resetConfirmOpen
        z: 50
        message: "Reset all progress? Streaks, best scores, and weak-key stats will be cleared."
        cancelText: "Cancel"
        confirmText: "Reset"
        background: root.background
        foreground: root.foreground
        scrim: root.scrim
        cornerRadius: root.cornerRadius
        onCanceled: root.resetConfirmOpen = false
        onConfirmed: root.resetProgress()
      }
    }
  }
}
