pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls as C
import qs.Commons
import "Typography.js" as Typography
import "SafeReadme.js" as SafeReadme

Column {
  id: root
  objectName: "readmeDocument"
  property var blocks: []
  property string plainText: ""
  property bool loading: false
  property bool enrichmentEnabled: true
  readonly property real readingSize: Typography.reading(Style.font)
  readonly property color foreground: Color.foreground
  readonly property color muted: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.68)
  readonly property color faint: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.055)
  readonly property bool hasBlocks: enrichmentEnabled && SafeReadme.isList(blocks) && blocks.length > 0
  signal linkRequested(string url)
  // The owner scrolls its existing ScrollView and accepts only supported keys.
  signal scrollRequested(var event)
  spacing: Style.space(12)
  Keys.priority: Keys.AfterItem
  Keys.onPressed: function(event) {
    // TextEdit may leave PageUp/Down unhandled (it has no internal viewport).
    // Keep those caret/selection gestures from falling through to ScrollView.
    if ([Qt.Key_Up, Qt.Key_Down, Qt.Key_PageUp, Qt.Key_PageDown, Qt.Key_Home, Qt.Key_End].indexOf(event.key) >= 0)
      event.accepted = true
  }

  function activateLink(value) {
    var url = SafeReadme.safeUrl(value)
    if (url) linkRequested(url)
  }

  component Selectable: TextEdit {
    id: selectable
    readOnly: true
    selectByMouse: true
    selectByKeyboard: true
    activeFocusOnTab: true
    persistentSelection: true
    wrapMode: TextEdit.Wrap
    textFormat: TextEdit.RichText
    color: root.foreground
    selectionColor: Color.accent
    selectedTextColor: Color.background
    font.family: Style.font.family
    font.pixelSize: root.readingSize
    height: implicitHeight
    // This narrow BeforeItem exception lets reading scroll rather than move
    // TextEdit's invisible caret. Selection, modified keys and horizontal caret
    // movement still go through the native editor.
    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function(event) {
      if (readOnly && selectionStart === selectionEnd && event.modifiers === Qt.NoModifier) {
        root.scrollRequested(event)
        if (event.accepted) linkTip.close()
      }
      if (event.key === Qt.Key_Backspace || event.key === Qt.Key_Delete) event.accepted = true
    }
    onLinkActivated: function(link) { root.activateLink(link) }
    C.ToolTip {
      id: linkTip
      objectName: "readmeLinkTip"
      visible: selectable.hoveredLink !== "" && root.visible
      delay: 450
      text: SafeReadme.safeUrl(selectable.hoveredLink)
      width: Math.min(Style.space(460), root.width)
      contentItem: Text {
        text: linkTip.text
        textFormat: Text.PlainText
        wrapMode: Text.WrapAnywhere
        color: root.foreground
        font.family: Style.font.family
        font.pixelSize: Typography.supporting(Style.font)
      }
      background: Rectangle { color: Color.background; border.color: Color.accent; radius: Style.cornerRadius }
    }
  }

  Selectable {
    objectName: "readmeFallback"
    visible: !root.hasBlocks
    width: parent.width
    textFormat: TextEdit.PlainText
    text: !root.enrichmentEnabled ? "README enrichment is disabled in settings."
      : root.plainText || (root.loading ? "Loading documentation…" : "Documentation is not currently available.")
    color: root.plainText && root.enrichmentEnabled ? root.foreground : root.muted
  }

  Repeater {
    model: root.hasBlocks ? root.blocks : []
    delegate: Column {
      id: block
      required property var modelData
      required property int index
      objectName: "readmeBlock." + index
      readonly property string kind: String(modelData.kind || "paragraph")
      readonly property bool code: kind === "code"
      readonly property real inset: kind === "quote" || code ? Style.space(12) : 0
      readonly property real indent: kind === "list" ? Math.min(root.width * 0.2, Style.space(16) * Number(modelData.depth || 0)) : 0
      width: root.width
      spacing: Style.space(6)

      Text {
        visible: block.code && Boolean(block.modelData.language)
        text: String(block.modelData.language || "")
        textFormat: Text.PlainText
        font.family: Style.font.family
        font.pixelSize: Typography.supporting(Style.font)
        color: root.muted
        width: parent.width
        wrapMode: Text.WrapAnywhere
      }
      Item {
        visible: block.kind !== "rule" && block.kind !== "table"
        width: parent.width
        height: prose.height + block.inset * 2
        Rectangle {
          anchors.fill: parent
          color: block.code || block.kind === "quote" ? root.faint : "transparent"
          radius: Style.cornerRadius
        }
        Rectangle {
          visible: block.kind === "quote"
          width: Style.space(3); height: parent.height
          color: Color.accent
        }
        Text {
          id: marker
          visible: block.kind === "list"
          x: block.indent
          width: visible ? Math.max(implicitWidth, Style.space(20)) : 0
          text: String(block.modelData.marker || "•")
          textFormat: Text.PlainText
          color: Color.accent
          font.family: Style.font.family
          font.pixelSize: root.readingSize
        }
        Selectable {
          id: prose
          objectName: "readmeText." + block.index
          x: block.inset + block.indent + marker.width
          y: block.inset
          width: Math.max(1, parent.width - x - block.inset)
          textFormat: block.code ? TextEdit.PlainText : TextEdit.RichText
          text: block.code ? String(block.modelData.text || "") : SafeReadme.rich(block.modelData.inlines, Color.accent)
          font.family: block.code ? (Style.font.monoFamily || "monospace") : Style.font.family
          font.pixelSize: block.kind === "heading"
            ? root.readingSize * (Number(block.modelData.level) === 1 ? 1.65 : Number(block.modelData.level) === 2 ? 1.35 : 1.12)
            : root.readingSize
          font.bold: block.kind === "heading"
          topPadding: block.kind === "heading" ? Style.space(6) : 0
          bottomPadding: block.kind === "heading" ? Style.space(3) : 0
        }
      }
      Rectangle {
        visible: block.kind === "rule" || (block.kind === "heading" && Number(block.modelData.level) <= 2)
        width: parent.width
        height: Style.space(1)
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.14)
      }
      Column {
        visible: block.kind === "table"
        width: parent.width
        Repeater {
          model: block.kind === "table" && SafeReadme.isList(block.modelData.rows) ? block.modelData.rows : []
          delegate: Rectangle {
            id: tableRow
            required property var modelData
            required property int index
            width: block.width
            height: cells.implicitHeight
            color: index === 0 || index % 2 === 0 ? root.faint : "transparent"
            Row {
              id: cells
              width: parent.width
              Repeater {
                model: SafeReadme.isList(tableRow.modelData) ? tableRow.modelData : []
                delegate: Selectable {
                  required property var modelData
                  width: cells.width / Math.max(1, tableRow.modelData.length)
                  padding: Style.space(8)
                  font.bold: tableRow.index === 0
                  text: SafeReadme.rich(modelData, Color.accent)
                }
              }
            }
          }
        }
      }
    }
  }
}
