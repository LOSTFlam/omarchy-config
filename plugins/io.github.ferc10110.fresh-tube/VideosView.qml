import QtQuick
import qs.Commons
import qs.Ui
import "FreshTubeModel.js" as Model

// The pinned videos followed by the new ones, with the header actions.
// Choosing a video asks the panel to play it; nothing here runs the script.
Item {
  id: view

  property var host: null
  property int selected: 0
  property string selectedId: ""
  property real nowMs: Date.now()

  readonly property bool onNew: !host || host.tab === "new"
  readonly property Item focusItem: onNew ? keys : laterView.focusItem
  property alias laterView: laterView
  readonly property color fg: host ? host.foreground : Color.foreground
  readonly property color dim: host ? host.dim : Qt.darker(Color.foreground, 1.55)
  readonly property color urgent: host ? host.urgent : Color.urgent
  readonly property string family: host ? host.fontFamily : Style.font.family
  readonly property int pinnedCount: host ? host.pinnedVideos.length : 0
  readonly property var rows: host ? host.pinnedVideos.concat(host.videos) : []
  readonly property real gap: Style.space(8)

  // Keep the highlight on the same video when the list reorders (a pin moves
  // it to the top); when that video is gone, stay at the same slot so the
  // highlight lands on the next one.
  onRowsChanged: {
    var index = -1
    if (selectedId !== "") {
      for (var i = 0; i < rows.length; i++) {
        if (rows[i].videoId === selectedId) { index = i; break }
      }
    }
    if (index >= 0) selected = index
    else if (selected >= rows.length) selected = Math.max(0, rows.length - 1)
    selectedId = rows[selected] ? rows[selected].videoId : ""
  }
  onVisibleChanged: if (visible) nowMs = Date.now()

  // Ages tick while the list is showing.
  Timer {
    interval: 60000
    running: view.visible
    repeat: true
    onTriggered: view.nowMs = Date.now()
  }

  function moveSelection(delta) {
    if (rows.length === 0) return
    selected = Math.max(0, Math.min(rows.length - 1, selected + delta))
    selectedId = rows[selected] ? rows[selected].videoId : ""
    list.positionViewAtIndex(selected, ListView.Contain)
  }

  function handleKey(event) {
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    if (ctrl && event.key === Qt.Key_Tab) {
      host.toggleTab()
    } else if (event.key === Qt.Key_Down) {
      moveSelection(1)
    } else if (event.key === Qt.Key_Up) {
      moveSelection(-1)
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      if (rows[selected]) host.play(rows[selected])
    } else if (event.key === Qt.Key_Delete) {
      if (rows[selected] && !host.isPinned(rows[selected])) host.dismiss(rows[selected])
    } else if (!ctrl && event.key === Qt.Key_P) {
      if (rows[selected]) host.togglePinVideo(rows[selected])
    } else if (event.key === Qt.Key_Escape) {
      host.close()
    } else if (ctrl && event.key === Qt.Key_R) {
      host.refresh()
    } else {
      return
    }
    event.accepted = true
  }

  // Holds keyboard focus: there is no text field in this view.
  Item {
    id: keys
    focus: true
    Keys.onPressed: function(event) { view.handleKey(event) }
  }

  Column {
    id: upper
    width: parent.width
    spacing: view.gap

    Item {
      width: parent.width
      height: Math.max(heading.implicitHeight, actions.implicitHeight)

      Row {
        id: heading
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Button {
          text: view.host && view.host.videos.length > 0 ? "New (" + view.host.videos.length + ")" : "New"
          selected: view.onNew
          tooltipText: "New videos from your channels (Ctrl+Tab)"
          foreground: view.fg
          fontFamily: view.family
          onClicked: if (view.host) view.host.tab = "new"
        }

        Button {
          text: view.host && view.host.queueVideos.length > 0 ? "Watch later (" + view.host.queueVideos.length + ")" : "Watch later"
          selected: !view.onNew
          tooltipText: "Videos you saved (Ctrl+Tab)"
          foreground: view.fg
          fontFamily: view.family
          onClicked: if (view.host) view.host.tab = "later"
        }
      }

      Row {
        id: actions
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(4)

        Button {
          iconText: "󰑐"
          iconSpinning: view.host ? view.host.refreshing : false
          tooltipText: "Refresh (Ctrl+R)"
          foreground: view.fg
          fontFamily: view.family
          onClicked: view.host.refresh()
        }

        Button {
          iconText: "󰐃"
          selected: view.host ? view.host.pinned : false
          tooltipText: view.host && view.host.pinned ? "Unpin: close when clicking elsewhere" : "Pin: stay open"
          foreground: view.fg
          fontFamily: view.family
          onClicked: view.host.togglePin()
        }

        Button {
          iconText: "󰕲"
          tooltipText: "Channels"
          foreground: view.fg
          fontFamily: view.family
          onClicked: view.host.showChannels()
        }
      }
    }

    Text {
      width: parent.width
      visible: text !== ""
      text: view.host ? view.host.notice : ""
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: view.host && view.host.noticeIsError ? view.urgent : view.dim
      font.family: view.family
      font.pixelSize: Style.font.bodySmall
    }
  }

  ListView {
    id: list
    anchors.top: upper.bottom
    anchors.topMargin: view.gap
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(4)
    width: parent.width
    visible: view.onNew && view.rows.length > 0
    clip: true
    spacing: Style.space(2)
    boundsBehavior: Flickable.StopAtBounds
    model: view.rows

    delegate: VideoRow {
      required property var modelData
      required property int index
      width: list.width
      host: view.host
      video: modelData
      selected: index === view.selected
      nowMs: view.nowMs
      pinned: index < view.pinnedCount
      pinsFull: view.host ? view.host.pinsFull : false
      onPinToggled: view.host.togglePinVideo(modelData)
      onActivated: view.host.play(modelData)
      onDismissed: view.host.dismiss(modelData)
    }
  }

  WatchLaterView {
    id: laterView
    anchors.top: upper.bottom
    anchors.topMargin: view.gap
    anchors.bottom: parent.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    visible: !view.onNew
    host: view.host
  }

  Column {
    id: empty
    anchors.centerIn: parent
    width: parent.width
    visible: view.onNew && view.rows.length === 0
    spacing: Style.space(6)

    readonly property bool noChannels: view.host && view.host.channelCount === 0

    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      text: empty.noChannels ? "Paste a channel URL to start" : "Nothing new"
      textFormat: Text.PlainText
      color: view.fg
      font.family: view.family
      font.pixelSize: Style.font.subtitle
    }

    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      visible: !empty.noChannels && text !== ""
      text: view.host && view.host.fetchedAt !== "" ? "updated " + Model.formatClock(view.host.fetchedAt) : ""
      textFormat: Text.PlainText
      color: view.dim
      font.family: view.family
      font.pixelSize: Style.font.caption
    }

    Button {
      anchors.horizontalCenter: parent.horizontalCenter
      visible: empty.noChannels
      text: "Add channel"
      iconText: "󰐕"
      bordered: true
      foreground: view.fg
      fontFamily: view.family
      onClicked: view.host.showChannels()
    }
  }
}
