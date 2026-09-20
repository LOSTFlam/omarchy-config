import QtQuick
import QtQml.Models
import qs.Commons
import qs.Ui
import "FreshTubeModel.js" as Model

// The saved videos in the user's order: a field to paste a link, and rows that
// can be dragged up or down to reorder. Dropping asks the panel to save
// the new order; the panel then rereads the cache.
Item {
  id: view

  property var host: null
  property string error: ""
  property int selected: 0
  property string selectedId: ""
  property real nowMs: Date.now()

  readonly property Item focusItem: input
  readonly property color fg: host ? host.foreground : Color.foreground
  readonly property color dim: host ? host.dim : Qt.darker(Color.foreground, 1.55)
  readonly property color urgent: host ? host.urgent : Color.urgent
  readonly property string family: host ? host.fontFamily : Style.font.family
  readonly property var rows: host ? host.queueVideos : []
  readonly property bool adding: host ? host.addingVideo : false
  readonly property real gap: Style.space(8)

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

  Timer {
    interval: 60000
    running: view.visible
    repeat: true
    onTriggered: view.nowMs = Date.now()
  }

  function clearInput() {
    input.text = ""
    error = ""
  }

  function submit() {
    if (adding) return
    host.addToQueue(input.text)
  }

  function moveSelection(delta) {
    if (rows.length === 0) return
    selected = Math.max(0, Math.min(rows.length - 1, selected + delta))
    selectedId = rows[selected] ? rows[selected].videoId : ""
    list.positionViewAtIndex(selected, ListView.Contain)
  }

  // The field keeps the focus, so list keys only act while it is empty.
  function handleKey(event) {
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    var empty = input.text.trim() === ""
    var current = rows[selected]
    if (ctrl && event.key === Qt.Key_Tab) {
      host.toggleTab()
    } else if (ctrl && event.key === Qt.Key_Down) {
      if (current) host.moveQueued(current, selected + 1)
    } else if (ctrl && event.key === Qt.Key_Up) {
      if (current) host.moveQueued(current, selected - 1)
    } else if (event.key === Qt.Key_Down) {
      moveSelection(1)
    } else if (event.key === Qt.Key_Up) {
      moveSelection(-1)
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      if (!empty) submit()
      else if (current) host.play(current)
    } else if (event.key === Qt.Key_Delete && empty) {
      if (current) host.finish(current)
    } else if (event.key === Qt.Key_Escape) {
      if (!empty) clearInput()
      else host.close()
    } else if (ctrl && event.key === Qt.Key_R) {
      host.refresh()
    } else {
      return
    }
    event.accepted = true
  }

  Column {
    id: upper
    width: parent.width
    spacing: view.gap

    Row {
      width: parent.width
      spacing: Style.space(6)

      TextField {
        id: input
        width: parent.width - addButton.implicitWidth - parent.spacing
        enabled: !view.adding
        placeholderText: view.adding ? "Looking up video…" : "Paste a video link"
        foreground: view.fg
        font.family: view.family
        Keys.onPressed: function(event) { view.handleKey(event) }
      }

      Button {
        id: addButton
        anchors.verticalCenter: parent.verticalCenter
        text: "Add"
        bordered: true
        enabled: !view.adding && input.text.trim() !== ""
        opacity: enabled ? 1 : 0.55
        foreground: view.fg
        fontFamily: view.family
        onClicked: view.submit()
      }
    }

    Text {
      width: parent.width
      visible: text !== ""
      text: view.error
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: view.urgent
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
    visible: view.rows.length > 0
    clip: true
    spacing: Style.space(2)
    boundsBehavior: Flickable.StopAtBounds
    model: visualModel
    moveDisplaced: Transition {
      NumberAnimation { properties: "y"; duration: 120 }
    }
  }

  // A DelegateModel so dragging can reorder the visible rows without
  // touching the data: the saved order only changes once the panel says so.
  DelegateModel {
    id: visualModel
    model: view.rows

    delegate: Item {
      id: slot
      required property var modelData
      required property int index
      width: list.width
      height: card.height

      readonly property bool held: grip.drag.active

      VideoRow {
        id: card
        width: slot.width
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        host: view.host
        video: slot.modelData
        selected: slot.index === view.selected
        nowMs: view.nowMs
        pinnable: false
        onActivated: view.host.play(slot.modelData)
        onDismissed: view.host.finish(slot.modelData)

        Drag.active: slot.held
        Drag.source: slot
        Drag.hotSpot.x: width / 2
        Drag.hotSpot.y: height / 2

        // While dragged the row is drawn above its siblings, following the pointer.
        states: State {
          when: slot.held
          ParentChange { target: card; parent: list }
          AnchorChanges {
            target: card
            anchors.horizontalCenter: undefined
            anchors.verticalCenter: undefined
          }
        }
      }

      // Press on the thumbnail or the text and move to drag. A plain click is
      // not accepted here, so it falls through to the row and plays; hover is
      // not enabled here, so the row still highlights. The ✕ column stays
      // uncovered.
      MouseArea {
        id: grip
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: card.bodyWidth
        propagateComposedEvents: true
        cursorShape: slot.held ? Qt.ClosedHandCursor : Qt.PointingHandCursor
        drag.target: card
        drag.axis: Drag.YAxis
        drag.threshold: 6
        onPressed: {
          view.selected = slot.index
          view.selectedId = slot.modelData.videoId
        }
        onClicked: function(mouse) { mouse.accepted = false }
        // Fires once the drop is over, whatever order pressed/released arrive in.
        drag.onActiveChanged: {
          if (drag.active) return
          var target = slot.DelegateModel.itemsIndex
          if (target !== slot.index) view.host.moveQueued(slot.modelData, target)
        }
      }

      DropArea {
        anchors.fill: parent
        anchors.margins: Style.space(6)
        onEntered: function(drag) {
          var from = drag.source.DelegateModel.itemsIndex
          var to = slot.DelegateModel.itemsIndex
          if (from !== to) visualModel.items.move(from, to)
        }
      }
    }
  }

  Text {
    anchors.top: upper.bottom
    anchors.topMargin: view.gap
    width: parent.width
    visible: view.rows.length === 0
    text: "Nothing saved yet. Paste a video link above."
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: view.dim
    font.family: view.family
    font.pixelSize: Style.font.bodySmall
  }
}
