import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar widget: a download queue for yt-dlp. Paste a link, pick video or audio,
// and watch the queue work through it.
//
// The queue belongs to the ytdlp-queue script beside this file, not to this
// widget. A download outlives a restart of the shell; a job owned by this
// process would not. So the widget asks and draws, and nothing more.
Panel {
  id: root
  moduleName: "alexzeitler.ytdlp"
  ipcTarget: "alexzeitler.ytdlp"

  // What the queue reported when it was last asked.
  property var jobs: []
  property string failure: ""
  property int cursor: 0

  // The three choices a download is made of. They survive a restart in
  // shell.json, so the next link needs no setup.
  property string mode: "video"
  property string quality: "best"
  property string audioFormat: "keep"
  property string dest: ""

  // Where the yt-dlp checkout sits. That differs from machine to machine, so it
  // is a setting rather than a fixed path, and the panel can fetch it.
  property string checkoutDir: ""

  // The setup area is folded away by default. It is maintenance, and it would
  // otherwise sit between someone and the link they came to paste.
  property bool setupOpen: false
  property var checkoutState: null

  // Which yt-dlp answers, shown at the foot of the panel. The package and the
  // checkout differ by weeks, and weeks decide whether YouTube works.
  property string binaryVersion: ""
  property string binarySource: ""

  // As an escape rather than the glyph itself: a literal private-use character
  // does not survive every editor and pipe it passes through.
  readonly property string barIcon: "\uf019"

  // The panel paints on its own opaque surface, so it takes the theme's
  // foreground. `barForeground` is a different colour: a see-through bar shifts
  // it to stay legible against the wallpaper, and that colour is unreadable
  // here.
  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.45)
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  readonly property string runner: pathFromUrl(Qt.resolvedUrl("ytdlp-queue"))

  // Only the starting point for the setting. Once someone edits it, this value
  // is never consulted again.
  readonly property string defaultCheckoutDir: {
    var home = String(Quickshell.env("HOME") || "")
    return home === "" ? "" : home + "/src/github.com/yt-dlp"
  }

  readonly property var modeOptions: [
    { value: "video", label: "Video" },
    { value: "audio", label: "Audio only" }
  ]
  readonly property var qualityOptions: [
    { value: "best", label: "Best" },
    { value: "1080", label: "1080p" },
    { value: "720", label: "720p" },
    { value: "480", label: "480p" }
  ]
  readonly property var audioFormatOptions: [
    { value: "keep", label: "Keep original" },
    { value: "mp3", label: "mp3" },
    { value: "m4a", label: "m4a" },
    { value: "opus", label: "opus" },
    { value: "flac", label: "flac" },
    { value: "wav", label: "wav" }
  ]


  readonly property var runningJob: {
    for (var i = 0; i < root.jobs.length; i++) {
      if (root.jobs[i].status === "running") return root.jobs[i]
    }
    return null
  }

  readonly property int waitingCount: {
    var count = 0
    for (var i = 0; i < root.jobs.length; i++) {
      if (root.jobs[i].status === "queued") count++
    }
    return count
  }

  readonly property bool busy: root.runningJob !== null || root.waitingCount > 0

  // The bar carries the one number worth carrying: how far the running download
  // has come. Nothing running, nothing but the icon.
  readonly property string barText: {
    if (!root.busy) return root.barIcon
    var job = root.runningJob
    if (job && typeof job.percent === "number") {
      return root.barIcon + "  " + Math.round(job.percent) + "%"
    }
    return root.barIcon + "  " + root.waitingCount
  }

  function pathFromUrl(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0) return decodeURIComponent(value.substring(7))
    return value
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function loadSettings() {
    root.mode = String(root.setting("mode", "video"))
    root.quality = String(root.setting("quality", "best"))
    root.audioFormat = String(root.setting("audioFormat", "keep"))
    root.dest = String(root.setting("dest", ""))
    root.checkoutDir = String(root.setting("checkoutDir", root.defaultCheckoutDir))
    if (root.dest === "") destProcess.running = true
  }

  function persistSettings() {
    var next = {
      mode: root.mode,
      quality: root.quality,
      audioFormat: root.audioFormat,
      dest: root.dest,
      checkoutDir: root.checkoutDir
    }
    root.settings = next
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function") {
      root.bar.shell.updateEntryInline(root.moduleName, next)
    }
  }

  function refresh() {
    if (listProcess.running) return
    listProcess.running = true
  }

  function takeJobs(raw) {
    var text = (raw || "").trim()
    if (text === "") {
      root.failure = "the queue said nothing"
      return
    }
    try {
      var parsed = JSON.parse(text)
      root.jobs = Array.isArray(parsed) ? parsed : []
      root.failure = ""
    } catch (error) {
      root.failure = "cannot read what the queue printed"
    }
    root.cursor = Math.min(root.cursor, Math.max(0, root.jobs.length - 1))
  }

  function addUrl() {
    var url = urlField.text.trim()
    if (url === "") return
    // What stands in the folder fields counts, whether or not anyone pressed
    // Enter first. Reading the stored setting instead would quietly download
    // into the folder that was set before the last edit.
    destFolder.commit()
    checkoutFolder.commit()
    var command = [root.runner, "add", url, "--mode", root.mode,
      "--quality", root.quality, "--audio-format", root.audioFormat,
      "--checkout", root.checkoutDir]
    if (root.dest !== "") command = command.concat(["--dest", root.dest])
    root.failure = ""
    addProcess.command = command
    addProcess.running = true
    urlField.text = ""
  }

  function cancelJob(id) {
    if (!id) return
    cancelProcess.command = [root.runner, "cancel", String(id)]
    cancelProcess.running = true
  }

  function clearFinished() {
    clearProcess.command = [root.runner, "clear"]
    clearProcess.running = true
  }

  function openFolder(path) {
    if (!path || path === "") destFolder.commit()
    var target = path && path !== "" ? path : root.dest
    if (!target || target === "") return
    openProcess.command = ["xdg-open", target]
    openProcess.running = true
  }

  // `guarded` means: only fill the field while it is still empty. That is the
  // automatic read when the panel opens, which must not overwrite what someone
  // typed a moment ago.
  property bool pasteGuarded: false

  function pasteClipboard(guarded) {
    root.pasteGuarded = guarded
    if (pasteProcess.running) return
    pasteProcess.running = true
  }

  function takePaste(raw) {
    var text = (raw || "").trim()
    if (root.pasteGuarded && urlField.text.trim() !== "") return
    if (text.indexOf("http://") !== 0 && text.indexOf("https://") !== 0) return
    urlField.text = text
  }

  // Deliberately without committing the field: the poll runs while someone may
  // still be typing, and every half-finished path would land in shell.json.
  // Whoever needs the typed value commits it themselves before asking.
  function requestCheckoutState() {
    if (checkoutProcess.running) return
    checkoutProcess.command = [root.runner, "checkout", "status", "--dir", root.checkoutDir]
    checkoutProcess.running = true
  }

  function takeCheckoutState(raw) {
    try {
      root.checkoutState = JSON.parse((raw || "").trim())
    } catch (error) {
      root.checkoutState = null
    }
  }

  // Cloning and pulling both take a while and both can fail in ways worth
  // reading, so they run in a terminal rather than silently in the background.
  function syncCheckout() {
    checkoutFolder.commit()
    syncProcess.command = ["omarchy-launch-tui", "--app-id=org.omarchy.ytdlp-checkout",
      root.runner, "checkout", "sync", "--dir", root.checkoutDir]
    syncProcess.running = true
  }

  // The short hash says which yt-dlp is on disk. What it cannot say is what
  // else exists by now, so the way out leads to yt-dlp's releases.
  function openReleases() {
    if (!root.checkoutState || !root.checkoutState.releasesUrl) return
    releasesProcess.command = ["xdg-open", root.checkoutState.releasesUrl]
    releasesProcess.running = true
  }

  // Nobody but the plugin can raise the pinned commit, so the panel hands the
  // finder a prepared issue rather than leaving them to describe it themselves.
  function reportNewerVersion() {
    if (!root.checkoutState || !root.checkoutState.reportUrl) return
    reportProcess.command = ["xdg-open", root.checkoutState.reportUrl]
    reportProcess.running = true
  }

  function pinnedShort() {
    if (!root.checkoutState || !root.checkoutState.pinned) return ""
    return root.checkoutState.pinned.substring(0, 7)
  }

  function toggleSetup() {
    root.setupOpen = !root.setupOpen
    if (root.setupOpen) {
      root.requestCheckoutState()
      binaryProcess.running = true
    }
  }

  function checkoutSummary() {
    var state = root.checkoutState
    if (!state) return "Looking at the folder"
    if (state.isRepo) {
      var head = state.head !== "" ? state.head : "an unknown commit"
      var when = state.headDate !== "" ? state.headDate : "an unknown date"
      var line = "At " + head + " from " + when
      if (!state.atPinned) line = line + ", not the commit this plugin ships"
      return state.runnable ? line : line + ", but yt-dlp.sh is missing"
    }
    if (state.exists) return "That folder holds something else. Clone refuses to touch it."
    return "Not there yet. Clone puts it here."
  }

  function labelOf(job) {
    if (job.title && job.title !== "") return job.title
    return job.url
  }

  function statusOf(job) {
    if (job.status === "running") {
      var parts = []
      if (typeof job.percent === "number") parts.push(job.percent.toFixed(1) + "%")
      if (job.speed && job.speed !== "" && job.speed.indexOf("Unknown") !== 0) parts.push(job.speed)
      if (job.eta && job.eta !== "" && job.eta !== "NA" && job.eta !== "Unknown") parts.push("ETA " + job.eta)
      return parts.length > 0 ? parts.join("  ·  ") : "Starting"
    }
    if (job.status === "queued") return "Waiting"
    if (job.status === "done") return "Done"
    if (job.status === "cancelled") return "Cancelled"
    if (job.status === "failed") return job.error && job.error !== "" ? job.error : "Failed"
    return job.status
  }

  function isActive(job) {
    return job.status === "running" || job.status === "queued"
  }

  function hasFinished() {
    for (var i = 0; i < root.jobs.length; i++) {
      if (!root.isActive(root.jobs[i])) return true
    }
    return false
  }

  function moveCursor(delta) {
    if (root.jobs.length === 0) return
    root.cursor = Math.max(0, Math.min(root.jobs.length - 1, root.cursor + delta))
  }

  function activateCursor() {
    var job = root.jobs[root.cursor]
    if (job && job.status === "done") root.openFolder(job.dest)
  }

  onSettingsChanged: root.loadSettings()

  onOpenedChanged: {
    if (opened) {
      root.cursor = 0
      root.refresh()
      root.pasteClipboard(true)
      binaryProcess.running = true
    }
  }

  Component.onCompleted: {
    root.loadSettings()
    root.refresh()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // While something runs the bar wants a fresh number every second. While
  // nothing runs only this panel can change the queue, so a slow beat is enough.
  Timer {
    interval: root.busy ? 1000 : 5000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Process {
    id: listProcess
    command: [root.runner, "list"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.takeJobs(text)
    }
  }

  Process {
    id: addProcess
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") root.failure = text.trim()
    }
    onExited: root.refresh()
  }

  Process {
    id: cancelProcess
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") root.failure = text.trim()
    }
    onExited: root.refresh()
  }

  Process {
    id: clearProcess
    onExited: root.refresh()
  }

  Process {
    id: openProcess
  }

  Process {
    id: pasteProcess
    command: ["wl-paste", "-n"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.takePaste(text)
    }
  }

  Process {
    id: destProcess
    command: [root.runner, "default-dest"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var value = (text || "").trim()
        if (value !== "" && root.dest === "") root.dest = value
      }
    }
  }

  Process {
    id: checkoutProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.takeCheckoutState(text)
    }
  }

  Process {
    id: syncProcess
  }

  Process {
    id: releasesProcess
  }

  Process {
    id: reportProcess
  }

  // The terminal owns the clone, so the panel cannot be told when it is done.
  // While the setup area is open it simply looks again every few seconds.
  Timer {
    interval: 3000
    running: root.setupOpen
    repeat: true
    onTriggered: {
      root.requestCheckoutState()
      binaryProcess.running = true
    }
  }

  Process {
    id: binaryProcess
    command: [root.runner, "binary", "--dir", root.checkoutDir]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var reported = JSON.parse(text)
          root.binaryVersion = reported.version || ""
          root.binarySource = reported.source || ""
        } catch (error) {
          root.binaryVersion = ""
          root.binarySource = ""
        }
      }
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText
    tooltipText: root.busy
      ? (root.waitingCount > 0 ? "yt-dlp — " + root.waitingCount + " waiting" : "yt-dlp — downloading")
      : "yt-dlp"
    onPressed: function(which) {
      if (root.opened) root.close()
      else root.open()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: urlField
    contentWidth: panel.fittedContentWidth(Style.space(560))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: urlField.activeFocus || destFolder.editing || checkoutFolder.editing
        || modeDropdown.popupOpen || qualityDropdown.popupOpen
        || audioFormatDropdown.popupOpen
      onCloseRequested: root.close()
      onMoveRequested: function(dx, dy) { root.moveCursor(dy) }
      onActivateRequested: root.activateCursor()

      ColumnLayout {
        id: contentColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(10)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Text {
            textFormat: Text.PlainText
            text: root.busy
              ? (root.waitingCount > 0 ? "Downloading, " + root.waitingCount + " waiting" : "Downloading")
              : "yt-dlp"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
          }

          Button {
            text: "Folder"
            foreground: root.fg
            tooltipText: "Open the target folder"
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.openFolder(root.dest)
          }

          Button {
            visible: root.hasFinished()
            text: "Clear"
            foreground: root.fg
            tooltipText: "Forget everything that is no longer running"
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.clearFinished()
          }
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          TextField {
            id: urlField
            Layout.fillWidth: true
            foreground: root.fg
            placeholderText: "Paste a link"
            font.family: root.fontFamily
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.addUrl(); event.accepted = true
              } else if (event.key === Qt.Key_Escape) {
                root.close(); event.accepted = true
              }
            }
          }

          Button {
            text: "Paste"
            foreground: root.fg
            tooltipText: "Take the link from the clipboard"
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.pasteClipboard(false)
          }

          Button {
            text: "Add"
            foreground: root.fg
            active: urlField.text.trim() !== ""
            tooltipText: "Put this link at the end of the queue"
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.addUrl()
          }
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Dropdown {
            id: modeDropdown
            Layout.fillWidth: true
            label: "Mode"
            value: root.mode
            options: root.modeOptions
            foreground: root.fg
            fontFamily: root.fontFamily
            onChanged: function(value) {
              root.mode = value
              root.persistSettings()
            }
          }

          // A height means nothing for audio and a container means nothing for
          // video, so the second column shows whichever of the two applies.
          Dropdown {
            id: qualityDropdown
            Layout.fillWidth: true
            visible: root.mode === "video"
            label: "Quality"
            value: root.quality
            options: root.qualityOptions
            foreground: root.fg
            fontFamily: root.fontFamily
            onChanged: function(value) {
              root.quality = value
              root.persistSettings()
            }
          }

          Dropdown {
            id: audioFormatDropdown
            Layout.fillWidth: true
            visible: root.mode === "audio"
            label: "Format"
            value: root.audioFormat
            options: root.audioFormatOptions
            foreground: root.fg
            fontFamily: root.fontFamily
            onChanged: function(value) {
              root.audioFormat = value
              root.persistSettings()
            }
          }
        }

        FolderField {
          id: destFolder
          Layout.fillWidth: true
          runner: root.runner
          placeholder: "Target folder"
          value: root.dest
          foreground: root.fg
          dim: root.dim
          fontFamily: root.fontFamily
          onCommitted: function(path) {
            root.dest = path
            root.persistSettings()
          }
          onEscaped: root.close()
        }


        PanelSeparator {
          Layout.fillWidth: true
          foreground: root.fg
        }

        Text {
          textFormat: Text.PlainText
          visible: root.failure !== ""
          Layout.fillWidth: true
          text: root.failure
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Text {
          textFormat: Text.PlainText
          visible: root.jobs.length === 0 && root.failure === ""
          Layout.fillWidth: true
          text: "Nothing in the queue."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Repeater {
          model: root.jobs

          delegate: CursorSurface {
            id: row
            required property var modelData
            required property int index

            Layout.fillWidth: true
            implicitHeight: rowBody.implicitHeight + Style.space(16)
            foreground: root.fg
            hasCursor: root.cursor === row.index

            RowLayout {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(8)

              ColumnLayout {
                id: rowBody
                Layout.fillWidth: true
                spacing: Style.space(3)

                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: root.labelOf(row.modelData)
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }

                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: root.statusOf(row.modelData)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }

                // The bar walks back when yt-dlp moves from the video stream to
                // the audio stream: each stream counts from zero. That is what
                // yt-dlp reports, and inventing a smooth number here would hide
                // that a second file is on its way.
                Rectangle {
                  visible: row.modelData.status === "running"
                    && typeof row.modelData.percent === "number"
                  Layout.fillWidth: true
                  Layout.topMargin: Style.space(2)
                  implicitHeight: Math.max(2, Style.space(3))
                  radius: implicitHeight / 2
                  color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.22)

                  Rectangle {
                    width: parent.width * Math.max(0, Math.min(1, (row.modelData.percent || 0) / 100))
                    height: parent.height
                    radius: parent.radius
                    color: root.fg
                  }
                }
              }

              Button {
                visible: root.isActive(row.modelData)
                text: "Cancel"
                foreground: root.fg
                tooltipText: row.modelData.status === "running"
                  ? "Stop this download"
                  : "Take this link out of the queue"
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.cancelJob(row.modelData.id)
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.LeftButton
              propagateComposedEvents: true
              cursorShape: row.modelData.status === "done"
                ? Qt.PointingHandCursor
                : Qt.ArrowCursor
              onContainsMouseChanged: if (containsMouse) root.cursor = row.index
              onClicked: function(mouse) {
                if (row.modelData.status === "done") root.openFolder(row.modelData.dest)
                else mouse.accepted = false
              }
            }
          }
        }

        PanelSeparator {
          Layout.fillWidth: true
          Layout.topMargin: Style.space(2)
          foreground: root.fg
        }

        // The foot doubles as the way in: it already names the yt-dlp in use,
        // which is what the setup below is about.
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            text: root.binaryVersion !== ""
              ? "yt-dlp " + root.binaryVersion + "  ·  " + root.binarySource
              : "no yt-dlp found"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Button {
            text: root.setupOpen ? "Close Setup" : "Setup"
            foreground: root.fg
            tooltipText: "Where the yt-dlp checkout lives, and how to fetch it"
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            onClicked: root.toggleSetup()
          }
        }

        ColumnLayout {
          visible: root.setupOpen
          Layout.fillWidth: true
          spacing: Style.space(6)

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: "yt-dlp checkout"
            color: Qt.darker(root.fg, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          FolderField {
            id: checkoutFolder
            Layout.fillWidth: true
            runner: root.runner
            placeholder: "Checkout folder"
            value: root.checkoutDir
            foreground: root.fg
            dim: root.dim
            fontFamily: root.fontFamily
            onCommitted: function(path) {
              root.checkoutDir = path
              root.persistSettings()
              root.requestCheckoutState()
              binaryProcess.running = true
            }
            onEscaped: root.close()
          }

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              Layout.alignment: Qt.AlignVCenter
              text: root.checkoutSummary()
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Button {
              visible: root.pinnedShort() !== ""
              text: root.pinnedShort()
              foreground: root.fg
              tooltipText: "The yt-dlp this plugin ships. Opens yt-dlp's releases."
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: root.openReleases()
            }

            Button {
              visible: root.checkoutState && root.checkoutState.reportUrl !== undefined
              text: "Report"
              foreground: root.fg
              tooltipText: "Open an issue asking this plugin to ship a newer yt-dlp"
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: root.reportNewerVersion()
            }

            Button {
              text: root.checkoutState && root.checkoutState.isRepo ? "Update" : "Clone"
              foreground: root.fg
              active: true
              tooltipText: root.checkoutState && root.checkoutState.isRepo
                ? "Set the checkout to the commit this plugin ships"
                : "Clone yt-dlp into this folder and park it on that commit"
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              onClicked: root.syncCheckout()
            }
          }
        }
      }
    }
  }
}
