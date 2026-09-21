pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls as C
import qs.Commons
import qs.Ui
import "../ui" as OutfitUi
import "details-fixtures.js" as Fixtures

// Hosted by the existing window. No shell, service, IPC, or persistent state.
Item {
  id: root

  property string initialState: "available"
  property string backLabel: "Back to Browse"
  signal backRequested()
  function takeFocus() { if (pageLoader.item) pageLoader.item.takeFocus() }

  property var fixtureModel: Fixtures.create("available")
  property bool ready: false
  readonly property string fixtureState: Fixtures.stateName(initialState)
  readonly property var fixtureLabels: ({available:"Available", installed:"Installed", disabled:"Disabled",
    service:"Background service", pending:"In progress", failed:"Needs attention", manual:"Manual setup",
    replacement:"Bar replacement", long:"Long names & metrics", missing:"Missing information"})
  readonly property var pluginRow: fixtureModel.row
  readonly property string selectedPluginId: String(pluginRow.id)
  readonly property var presentation: Fixtures.presentation(fixtureModel)
  readonly property bool installEnabled: fixtureModel.installEnabled
  readonly property string installSection: fixtureModel.installSection
  readonly property string notice: fixtureModel.notice
  readonly property var sources: [
    Qt.resolvedUrl("assets/detail-dockside-overview.svg"),
    Qt.resolvedUrl("assets/detail-dockside-workspaces.svg"),
    Qt.resolvedUrl("assets/detail-dockside-focus.svg")
  ]
  readonly property var mediaItems: fixtureModel.hasMedia ? [
    {source: sources[0], title: "A home in your bar", caption: "Fictional desktop · A compact widget opens your project, notes, and focus controls."},
    {source: sources[1], title: "Pick up where you left off", caption: "Fictional desktop · Switch between pinned projects without leaving your workspace."},
    {source: sources[2], title: "A little room to focus", caption: "Fictional desktop · A quiet timer stays in the bar while your work takes the foreground."}
  ] : []

  function resetPage() {
    // Recreate the page even when two fixtures use the same product id. This
    // resets its own disclosures, scroll position, and full-size media overlay.
    if (!ready || !pageLoader.active) return
    demoPopup.close()
    pageLoader.active = false
    pageLoader.active = true
  }

  function loadFixture() {
    if (!ready) return
    demoPopup.close()
    statePicker.close()
    operationTimer.stop()
    pageLoader.active = false
    fixtureModel = Fixtures.create(initialState)
    if (initialState !== Fixtures.stateName(initialState))
      fixtureModel = Fixtures.transition(fixtureModel, "notice", "Demo · Unknown fixture state; showing available.")
    pageLoader.active = true
    syncTimer()
  }

  function syncTimer() {
    if (!ready) return
    operationTimer.stop()
    // The pending screenshot is a deterministic held state. User-triggered
    // operations in all other fixtures still complete after the short timer.
    if (visible && fixtureModel.pending && initialState !== "pending") operationTimer.start()
  }

  function dispatch(event, value) {
    var wasPending = fixtureModel.pending
    fixtureModel = Fixtures.transition(fixtureModel, event, value)
    if (!wasPending && fixtureModel.pending) syncTimer()
  }

  function showNotice(text) {
    dispatch("notice", "Demo · " + text)
  }

  function requestPrimary() {
    if (!presentation.primaryEnabled) return
    var action = presentation.primaryAction
    if (action === "open") {
      demoPopup.mode = "panel"
      demoPopup.open()
    } else if (action === "project") {
      showNotice("The fictional project page would open here. No browser is opened.")
    } else {
      dispatch(action)
    }
  }

  function requestRemove() {
    if (!presentation.canRemove) return
    demoPopup.mode = "remove"
    demoPopup.open()
  }

  onInitialStateChanged: loadFixture()
  onSelectedPluginIdChanged: resetPage()
  onVisibleChanged: {
    if (!visible) demoPopup.close()
    if (!visible) statePicker.close()
    syncTimer()
  }
  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_F6) {
      statePicker.open()
      event.accepted = true
    }
  }
  Component.onCompleted: {
    ready = true
    loadFixture()
  }

  Timer {
    id: operationTimer
    interval: 1600
    repeat: false
    onTriggered: root.fixtureModel = Fixtures.complete(root.fixtureModel)
  }

  Loader {
    id: pageLoader
    anchors.fill: parent
    active: false
    sourceComponent: Component {
      OutfitUi.PluginDetailPage {
        anchors.fill: parent
        pluginRow: root.pluginRow
        presentation: root.presentation
        mediaItems: root.mediaItems
        installEnabled: root.installEnabled
        installSection: root.installSection
        backLabel: root.backLabel
        notice: root.notice
        prototypeLabel: "Preview: " + root.fixtureLabels[root.fixtureState] + " ▾"
        onPrototypeRequested: statePicker.open()
        onBackRequested: {
          demoPopup.close()
          root.backRequested()
        }
        onPrimaryRequested: root.requestPrimary()
        onEnabledRequested: root.dispatch("toggle")
        onInstallEnabledRequested: root.dispatch("install-enabled")
        onSectionRequested: function(section) { root.dispatch("section", section) }
        onQueueRequested: root.dispatch("queue")
        onRemoveRequested: root.requestRemove()
        onSourceRequested: {
          if (root.pluginRow.sourceAvailable)
            root.showNotice("Source preview for " + root.pluginRow.name + ". This fictional project has no external destination.")
        }
        onMarketplaceRequested: {
          if (root.pluginRow.marketplaceAvailable)
            root.showNotice("Marketplace preview for " + root.pluginRow.name + ". Listing data is fictional; no browser is opened.")
        }
        onReviewRequested: root.dispatch("review")
      }
    }
  }

  component PopupCopy: Text {
    textFormat: Text.PlainText
    color: Color.popups.text
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.Wrap
  }

  C.Popup {
    id: statePicker
    objectName: "detailPrototypeStatePicker"
    parent: root
    popupType: C.Popup.Item
    x: Math.min(Style.space(140), root.width - width)
    y: Style.space(38)
    width: Math.min(Style.space(300), root.width - Style.space(24))
    height: Math.min(stateList.implicitHeight + Style.space(24), root.height - Style.space(50))
    padding: Style.space(12)
    modal: true
    focus: true
    closePolicy: C.Popup.CloseOnEscape | C.Popup.CloseOnPressOutside
    onOpened: stateReset.forceActiveFocus()
    background: BorderSurface {
      color: Color.popups.background
      radius: Style.cornerRadius
      borderSpec: Border.controlSpec("normal", Color.popups.text, Color.accent)
    }
    contentItem: C.ScrollView {
      id: stateScroll
      clip: true
      contentWidth: availableWidth
      C.ScrollBar.horizontal.policy: C.ScrollBar.AlwaysOff
      Column {
        id: stateList
        width: stateScroll.availableWidth
        spacing: Style.space(4)
        PopupCopy {
          width: parent.width
          text: "Fictional examples · No real changes"
          font.pixelSize: Style.font.caption
          color: Color.accent
        }
        Button {
          id: stateReset
          objectName: "detailPrototypeReset"
          width: parent.width
          text: "Reset this example"
          foreground: Color.popups.text
          bordered: true
          focusable: true
          onClicked: { root.loadFixture(); root.takeFocus() }
        }
        Repeater {
          model: Fixtures.states()
          Button {
            required property string modelData
            objectName: "detailPrototypeState." + modelData
            width: parent.width
            text: root.fixtureLabels[modelData]
            fontSize: Style.font.bodySmall
            verticalPadding: Style.space(5)
            foreground: Color.popups.text
            focusable: true
            selected: root.fixtureState === modelData
            onClicked: {
              statePicker.close()
              if (root.initialState === modelData) root.loadFixture()
              else root.initialState = modelData
              root.takeFocus()
            }
          }
        }
      }
    }
  }

  // An item popup stays in the existing window. Its fictional panel is small,
  // dismissible, and explicitly different from launching a real plugin.
  C.Popup {
    id: demoPopup
    objectName: "detailPrototypePopup"
    property string mode: "panel"
    readonly property bool confirming: mode === "remove"
    parent: root
    popupType: C.Popup.Item
    modal: true
    focus: true
    width: Math.max(1, Math.min(Style.space(480), root.width - Style.space(32)))
    height: Math.max(1, Math.min(implicitContentHeight + topPadding + bottomPadding, root.height - Style.space(32)))
    x: (root.width - width) / 2
    y: (root.height - height) / 2
    padding: Style.space(20)
    margins: Style.space(16)
    closePolicy: C.Popup.CloseOnEscape | C.Popup.CloseOnPressOutside
    onOpened: dismissButton.forceActiveFocus()
    background: BorderSurface {
      color: Color.popups.background
      radius: Style.cornerRadius
      borderSpec: Border.controlSpec("normal", Color.popups.text, Color.accent)
    }
    contentItem: C.ScrollView {
      id: popupScroll
      implicitHeight: popupBody.implicitHeight
      contentWidth: availableWidth
      clip: true
      C.ScrollBar.horizontal.policy: C.ScrollBar.AlwaysOff
      Column {
        id: popupBody
        width: popupScroll.availableWidth
        spacing: Style.space(16)
        PopupCopy {
          width: parent.width
          text: demoPopup.confirming ? "DEMO · REMOVE PLUGIN" : "DEMO · FICTIONAL PANEL"
          color: Color.accent
          font.pixelSize: Style.font.caption
          font.bold: true
        }
        PopupCopy {
          width: parent.width
          text: demoPopup.confirming ? "Remove " + root.pluginRow.name + "?" : "Dockside"
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }
        PopupCopy {
          width: parent.width
          text: demoPopup.confirming
            ? "This only removes the fictional installation from this preview. You can install it again; your enable and position choices are remembered for this session."
            : "A small panel mockup. No plugin is running."
        }
        BorderSurface {
          visible: !demoPopup.confirming
          width: parent.width
          implicitHeight: panelBody.implicitHeight + Style.space(28)
          radius: Style.cornerRadius
          color: Color.popups.background
          borderSpec: Border.controlSpec("normal", Color.popups.text, Color.accent)
          Column {
            id: panelBody
            anchors.fill: parent
            anchors.margins: Style.space(14)
            spacing: Style.space(12)
            PopupCopy {
              width: parent.width
              text: "CURRENT PROJECT"
              color: Color.accent
              font.pixelSize: Style.font.caption
            }
            PopupCopy { width: parent.width; text: "Harbor atlas · Workspace 02"; font.bold: true }
            PopupCopy { width: parent.width; text: "Pinned note\nLeave room for the next good idea." }
            PopupCopy { width: parent.width; text: "Focus · 25:00 ready"; color: Color.accent }
          }
        }
        Flow {
          width: parent.width
          spacing: Style.space(10)
          Button {
            id: dismissButton
            objectName: "detailPrototypeDismiss"
            text: demoPopup.confirming ? "Cancel" : "Dismiss"
            foreground: Color.popups.text
            bordered: true
            focusable: true
            Accessible.role: Accessible.Button
            Accessible.name: text
            Accessible.onPressAction: clicked()
            onClicked: demoPopup.close()
            Keys.onEscapePressed: demoPopup.close()
            Keys.onTabPressed: demoPopup.confirming ? confirmRemoveButton.forceActiveFocus() : forceActiveFocus()
            Keys.onBacktabPressed: demoPopup.confirming ? confirmRemoveButton.forceActiveFocus() : forceActiveFocus()
          }
          Button {
            id: confirmRemoveButton
            objectName: "detailPrototypeConfirmRemove"
            visible: demoPopup.confirming
            enabled: visible && root.presentation.canRemove
            text: "Remove in demo"
            foreground: Color.urgent
            bordered: true
            focusable: true
            Accessible.role: Accessible.Button
            Accessible.name: text
            Accessible.onPressAction: if (enabled) clicked()
            onClicked: {
              demoPopup.close()
              root.dispatch("remove")
            }
            Keys.onEscapePressed: demoPopup.close()
            Keys.onTabPressed: dismissButton.forceActiveFocus()
            Keys.onBacktabPressed: dismissButton.forceActiveFocus()
          }
        }
      }
    }
  }
}
