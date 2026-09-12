import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.Commons
import qs.Ui

// A path field that completes folder names.
//
// Tab fills in as far as the candidates agree, which is where typing has to
// take over anyway. The candidates that do not fit the list are counted rather
// than dropped in silence, so a shortened list never passes for a complete one.
ColumnLayout {
  id: root

  // The ytdlp-queue script. It answers `complete-dir`, so this component needs
  // no knowledge of the filesystem itself.
  property string runner: ""
  property string placeholder: ""
  property string value: ""
  property color foreground: Color.foreground
  property color dim: Qt.darker(foreground, 1.45)
  property string fontFamily: Style.font.family
  property int shownCount: 6

  readonly property bool editing: field.activeFocus

  signal committed(string path)
  signal escaped()

  property var matches: []
  property int total: 0
  property string common: ""
  property bool pending: false

  // Enter and Escape both put the list away, Enter keeping the typed path and
  // Escape leaving it alone. Only a second Escape reaches the panel. Dismissing
  // hides the list without throwing the answer away, so the next keystroke has
  // something to show again right away.
  property bool dismissed: false

  readonly property var shown: root.matches.slice(0, root.shownCount)
  readonly property int hidden: Math.max(0, root.total - root.shown.length)
  readonly property bool listVisible: field.activeFocus && !root.dismissed
    && root.shown.length > 0

  // A trailing slash helps while typing a path but has no place in a stored
  // setting, where it would show up in every command line built from it.
  function normalizedPath(path) {
    var text = String(path || "").trim()
    if (text.length > 1 && text.charAt(text.length - 1) === "/") {
      return text.substring(0, text.length - 1)
    }
    return text
  }

  function request() {
    if (root.runner === "") return
    if (completeProcess.running) {
      root.pending = true
      return
    }
    root.pending = false
    completeProcess.command = [root.runner, "complete-dir", field.text]
    completeProcess.running = true
  }

  function take(raw) {
    try {
      var parsed = JSON.parse((raw || "").trim())
      root.matches = Array.isArray(parsed.matches) ? parsed.matches : []
      root.total = typeof parsed.total === "number" ? parsed.total : 0
      root.common = parsed.common || ""
    } catch (error) {
      root.matches = []
      root.total = 0
      root.common = ""
    }
  }

  function completeToCommon() {
    root.dismissed = false
    if (root.common === "" || root.common === field.text) return
    field.text = root.common
    field.cursorPosition = field.text.length
    root.request()
  }

  function choose(path) {
    field.text = path
    root.commit()
    field.forceActiveFocus()
    field.cursorPosition = field.text.length
    root.request()
  }

  function commit() {
    var next = root.normalizedPath(field.text)
    if (next === root.value) return
    root.value = next
    root.committed(next)
  }

  spacing: Style.space(4)

  // Not a binding on `value`: typing would break it on the first keystroke.
  // The value is carried over by hand, and only while nobody is editing.
  Component.onCompleted: field.text = root.value
  onValueChanged: if (!field.activeFocus) field.text = root.value

  // Typing outruns the process that answers it, so wait for a pause.
  Timer {
    id: debounce
    interval: 150
    onTriggered: root.request()
  }

  Process {
    id: completeProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.take(text)
    }
    onExited: if (root.pending) root.request()
  }

  TextField {
    id: field
    Layout.fillWidth: true
    foreground: root.foreground
    placeholderText: root.placeholder
    font.family: root.fontFamily

    onActiveFocusChanged: {
      if (activeFocus) {
        root.dismissed = false
        root.request()
      } else {
        root.commit()
      }
    }
    onTextEdited: {
      root.dismissed = false
      debounce.restart()
    }
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Tab) {
        root.completeToCommon()
        event.accepted = true
      } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        // Enter means "this is the path": take it and put the list away.
        root.commit()
        root.dismissed = true
        event.accepted = true
      } else if (event.key === Qt.Key_Escape) {
        if (root.listVisible) root.dismissed = true
        else root.escaped()
        event.accepted = true
      }
    }
  }

  // Only while the field is being edited. A list of folders under a path
  // nobody is typing is noise.
  Repeater {
    model: root.listVisible ? root.shown : []

    delegate: CursorSurface {
      id: suggestion
      required property var modelData

      Layout.fillWidth: true
      implicitHeight: suggestionText.implicitHeight + Style.space(8)
      foreground: root.foreground

      Text {
        textFormat: Text.PlainText
        id: suggestionText
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(10)
        anchors.rightMargin: Style.space(10)
        text: suggestion.modelData
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideLeft
      }

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onContainsMouseChanged: suggestion.hasCursor = containsMouse
        onClicked: root.choose(suggestion.modelData)
      }
    }
  }

  Text {
    textFormat: Text.PlainText
    visible: root.listVisible && root.hidden > 0
    Layout.fillWidth: true
    Layout.leftMargin: Style.space(10)
    text: root.hidden + " more. Tab completes as far as they agree."
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    elide: Text.ElideRight
  }
}
