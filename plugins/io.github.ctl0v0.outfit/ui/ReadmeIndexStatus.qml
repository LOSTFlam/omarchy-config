import QtQuick
import qs.Commons
import qs.Ui
import "Typography.js" as Typography

Column {
  id: root
  readonly property real readingSize: Typography.reading(Style.font)
  readonly property real supportingSize: Typography.supporting(Style.font)
  property var service: null
  property var navigationTarget: null
  property color foreground: Color.foreground
  readonly property var counts: service && service.readmeIndex ? service.readmeIndex : ({})
  readonly property var documents: counts.documents ? (service.documentCounts || counts.documents) : null
  readonly property alias toggleButton: indexToggle
  readonly property bool paused: service && service.preferences.readmeIndexing === false
  readonly property bool disabled: service && service.preferences.readmeEnrichment === false
  spacing: Style.space(6)
  Text {
    width: parent.width
    text: root.documents ? "Documentation search · " + Number(root.documents.indexed || 0) + " searchable"
      : "README search · " + Number(root.counts.indexed || 0) + " / " + Number(root.counts.eligible || 0) + " indexed"
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: root.foreground
    font.family: Style.font.family
    font.pixelSize: root.supportingSize
    font.bold: true
  }
  Text {
    width: parent.width
    text: (root.disabled ? "Disabled in Settings." : root.paused ? "Indexing paused; cached text is searchable."
      : root.service && root.service.preparingSearch ? "Preparing the search library in the background…"
      : root.service && root.service.libraryPrepared ? "Library prepared. Available documentation is searchable."
      : root.service && root.service.indexingBusy ? "Indexing in the background…"
      : !root.counts.eligible ? "Waiting for marketplace listings."
      : Number(root.counts.retryAt || 0) * 1000 > Date.now() ? "Waiting before retrying GitHub."
      : Number(root.counts.due || 0) > 0 ? "Continues while Outfit is open." : "Index is up to date for available documents.")
      + ((root.documents || root.counts).pending ? " " + (root.documents || root.counts).pending + " pending." : "")
      + ((root.documents || root.counts).unavailable ? " " + (root.documents || root.counts).unavailable + " unavailable (checked)." : "")
      + ((root.documents || root.counts).failed ? " " + (root.documents || root.counts).failed + " will retry." : "")
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: root.foreground
    opacity: 0.7
    font.family: Style.font.family
    font.pixelSize: root.readingSize
  }
  Text {
    width: parent.width
    visible: Boolean(text)
    text: root.service ? String(root.service.readmeIndexError || root.counts.error || "") : ""
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: Color.urgent
    font.family: Style.font.family
    font.pixelSize: root.readingSize
  }
  Button {
    id: indexToggle
    fontSize: root.readingSize
    visible: !root.disabled
    text: root.paused ? "Resume indexing" : root.service && root.service.readmeIndexError ? "Retry indexing" : "Pause indexing"
    foreground: root.foreground
    bordered: true
    focusable: true
    enabled: root.service && !root.service.busy && !root.disabled
    Keys.forwardTo: root.navigationTarget ? [root.navigationTarget] : []
    onClicked: root.service.setIndexingPaused(!root.paused && !root.service.readmeIndexError)
  }
}
