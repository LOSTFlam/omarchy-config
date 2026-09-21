import QtQuick
import qs.Commons
import qs.Ui
import "ui" as OutfitUi

BarWidget {
  id: root
  moduleName: "io.github.ctl0v0.outfit"

  readonly property var fitService: bar && bar.shell
    ? bar.shell.serviceFor(moduleName) : null
  readonly property bool opened: fitService && fitService.editorOpen === true
  readonly property bool popoutSwitchClosing: false

  function editorPayload() {
    if (fitService && fitService.editorSessionPayload) return fitService.editorSessionPayload
    return {
      view: "setup",
      workspaceView: fitService ? fitService.workspaceView : "browse",
      discoverTab: fitService ? fitService.discoverTab : "ideas",
      setupVerification: fitService ? fitService.setupVerification : "all",
      setupQuery: fitService ? fitService.setupQuery : "",
      setupGroup: fitService ? fitService.setupGroup : "",
      setupSort: fitService ? fitService.setupSort : "likes",
      setupGrouping: fitService ? fitService.setupGrouping : "none",
      setupPage: fitService ? fitService.setupPage : 1,
      setupServices: fitService ? fitService.setupServiceIds : [],
      setupInstallFilter: fitService ? fitService.setupInstallFilter : "all",
      setupPartyFilter: fitService ? fitService.setupPartyFilter : "all",
      setupHardwareOnly: fitService ? fitService.setupHardwareOnly : false,
      setupCategory: fitService ? fitService.setupCategory : "",
      selectedId: fitService ? fitService.setupDetailId : ""
    }
  }

  function open() { if (fitService) fitService.openEditor(editorPayload()) }
  function close() { if (fitService) fitService.closeEditor() }
  function togglePanel() { opened ? close() : open() }
  function closeForPopoutSwitch() {}

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      OutfitUi.OutfitIcon {
        kind: "toolbox"
        tint: button.active && button.useActiveColor ? button.activeColor : button.foreground
      }
    }
    active: root.opened || (root.fitService && root.fitService.hasAnalyzed)
    tooltipText: !root.fitService ? "Outfit"
      : root.fitService.batchRunning ? "Outfit — batch install in progress"
      : root.fitService.hasCheckingOperations() ? "Outfit — checking plugin state"
      : root.fitService.mutationBusy ? "Outfit is updating plugins"
      : root.fitService.unreadMatches > 0 ? "Outfit — " + root.fitService.unreadMatches + " unread interest matches"
      : root.fitService.queryBusy || root.fitService.backgroundBusy ? "Outfit is updating recommendations"
      : root.fitService.workspaceView === "discover" ? "Outfit - discover something useful"
      : root.fitService.hasAnalyzed
        ? "Outfit - " + root.fitService.setupTotal + " matching plugins"
        : "Outfit - scan and manage plugins"

    Accessible.name: "Outfit plugin discovery"
    Accessible.role: Accessible.Button
    Accessible.onPressAction: button.triggerPress(Qt.LeftButton)

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.LeftButton) root.togglePanel()
    }
  }

  Rectangle {
    visible: root.fitService && (root.fitService.busy || root.fitService.backgroundBusy)
    anchors.bottom: parent.bottom
    anchors.horizontalCenter: parent.horizontalCenter
    width: parent.width * 0.55
    height: Math.max(1, Style.spacing.hairline)
    radius: height / 2
    color: Color.accent

    SequentialAnimation on opacity {
      running: parent.visible
      loops: Animation.Infinite
      NumberAnimation { from: 0.25; to: 1; duration: 500 }
      NumberAnimation { from: 1; to: 0.25; duration: 500 }
    }
  }
}
