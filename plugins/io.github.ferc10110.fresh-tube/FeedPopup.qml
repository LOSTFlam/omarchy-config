import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Layer-shell popup hanging from the bar icon, with two things the stock
// KeyboardPanel does not have: a pinned mode that survives clicks elsewhere
// and other panels opening, and a grip in the corner farthest from the bar
// to resize it, so the card always grows toward the cursor. Adapted from
// Omarchy's Ui/KeyboardPanel.qml (MIT, David Heinemeier Hansson) and the
// pinned mode of yani.camera's CameraPopup.qml (MIT, Yani); see
// THIRD_PARTY_NOTICES.md.
//
// The card's leading edge lines up with the icon's leading edge along the
// bar, so growing it from the corner farthest from the bar never moves the
// anchored edge. The popup never assigns its own contentWidth/contentHeight:
// it asks the owner through resizeRequested and the owner's binding feeds
// the new size back.
PanelWindow {
  id: root

  required property Item anchorItem
  required property QtObject bar
  property var owner: null
  property int margin: Style.gapsOut
  property int padding: Style.spacing.popupPadding
  property int contentWidth: Style.space(280)
  property int contentHeight: Style.space(200)
  property int minContentWidth: 300
  property int minContentHeight: 220
  property var borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
  property bool open: false
  property bool pinned: false
  property bool resizable: true
  property color gripColor: Color.foreground
  property int gap: Style.gapsOut
  property bool popoutSwitching: false
  property bool popoutSwitchClosing: false
  property bool focusPrimed: false

  // Item that takes keyboard focus once the panel maps.
  property Item focusTarget: null

  signal resizeRequested(int width, int height)
  signal resized(int width, int height)

  default property alias contentItem: contentHolder.children

  readonly property var coordinatorKey: owner || root
  readonly property var anchorWindow: anchorItem ? anchorItem.QsWindow.window : null
  readonly property string barPos: bar ? bar.position : "top"
  readonly property bool growsUp: barPos === "bottom"
  readonly property bool growsLeft: barPos === "right"
  readonly property bool containsMouse: cardHover.hovered

  function close() {
    if (owner && "close" in owner) owner.close()
    else root.open = false
  }

  function beginFocusPrime() {
    if (open && backingWindowVisible) focusPrimeTimer.restart()
  }

  function clamp(value, low, high) {
    return Math.max(low, Math.min(high, value))
  }

  // --- screen + lifetime ---------------------------------------------------

  screen: anchorWindow ? anchorWindow.screen : null
  visible: open || card.opacity > 0 || popoutSwitching
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore

  WlrLayershell.namespace: "fresh-tube-popup"
  WlrLayershell.layer: WlrLayer.Overlay
  // Exclusive for a moment so a keyboard summon gets focus, then OnDemand so
  // clicks reach other outputs. Pinned goes straight to OnDemand: it must
  // never steal focus from the window the user is working in.
  WlrLayershell.keyboardFocus: open
    ? (pinned || focusPrimed ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive)
    : WlrKeyboardFocus.None

  onBackingWindowVisibleChanged: beginFocusPrime()

  anchors {
    top: true
    bottom: true
    left: true
    right: true
  }

  readonly property real _barStripSize: {
    if (!bar) return 0
    var actual = (root.barPos === "top" || root.barPos === "bottom") ? root.barH : root.barW
    return Math.max(bar.barSize, actual) + root.gap
  }

  // Unpinned: the whole screen is ours so a click anywhere dismisses.
  // Pinned: only the card takes input; everything else reaches the apps below.
  mask: Region {
    x: root.pinned ? root.cardOrigin.x : 0
    y: root.pinned ? root.cardOrigin.y : 0
    width: root.pinned ? root.contentWidth : root.screenW
    height: root.pinned ? root.contentHeight : root.screenH
  }

  TransformWatcher {
    id: anchorWatcher
    a: anchorWindow ? anchorWindow.contentItem : null
    b: anchorItem
  }

  readonly property point anchorScreenPos: {
    anchorWatcher.transform  // reactive dependency
    if (!anchorItem || !anchorWindow) return Qt.point(0, 0)
    return anchorItem.mapToItem(anchorWindow.contentItem, 0, 0)
  }
  readonly property real screenW: screen ? screen.width : 0
  readonly property real screenH: screen ? screen.height : 0
  readonly property real barW: anchorWindow ? anchorWindow.width : screenW
  readonly property real barH: anchorWindow ? anchorWindow.height : 0
  readonly property real availableCardWidth: screenW > 0
    ? Math.max(120, screenW - ((barPos === "left" || barPos === "right") ? barW + gap + margin : margin * 2))
    : 0
  readonly property real availableCardHeight: screenH > 0
    ? Math.max(120, screenH - ((barPos === "top" || barPos === "bottom") ? barH + gap + margin : margin * 2))
    : 0
  readonly property real verticalContentInset: padding * 2 + Border.top(borderSpec) + Border.bottom(borderSpec)

  function fittedContentWidth(width, cap) {
    var desired = Math.max(1, Number(width) || 1)
    var maxWidth = root.availableCardWidth > 0 ? root.availableCardWidth : desired
    if (cap !== undefined && Number(cap) > 0) maxWidth = Math.min(maxWidth, Number(cap))
    return Math.round(Math.min(desired, maxWidth))
  }

  function cappedContentHeight(height) {
    var desired = Math.max(root.padding * 2, Number(height) || root.padding * 2)
    var maxHeight = root.availableCardHeight > 0 ? root.availableCardHeight : desired
    return Math.round(Math.min(desired, maxHeight))
  }

  // Top-left of the card on screen: flush with the icon's leading edge along
  // the bar, one gap away from the bar across it, kept inside the screen.
  readonly property point cardOrigin: {
    if (!anchorItem || !bar) return Qt.point(margin, margin)
    var x = 0, y = 0
    if (barPos === "bottom") {
      x = anchorScreenPos.x
      y = screenH - barH - contentHeight - gap
    } else if (barPos === "left") {
      x = barW + gap
      y = anchorScreenPos.y
    } else if (barPos === "right") {
      x = screenW - barW - contentWidth - gap
      y = anchorScreenPos.y
    } else {
      x = anchorScreenPos.x
      y = barH + gap
    }
    x = clamp(x, margin, Math.max(margin, screenW - contentWidth - margin))
    y = clamp(y, margin, Math.max(margin, screenH - contentHeight - margin))
    return Qt.point(Math.round(x), Math.round(y))
  }

  // --- popout coordination ---------------------------------------------------

  // A pinned popup steps out of the bar's one-popout-at-a-time model: it
  // gives the slot back so other panels open without closing it, and takes
  // it again when unpinned while open.
  onPinnedChanged: {
    if (!bar || !open) return
    if (pinned) {
      if (bar.activePopout === coordinatorKey) bar.releasePopout(coordinatorKey)
    } else {
      bar.requestPopout(coordinatorKey)
    }
  }

  onOpenChanged: {
    if (open) {
      focusPrimed = false
      beginFocusPrime()
      if (focusTarget) Qt.callLater(function() {
        if (root.open && root.focusTarget) root.focusTarget.forceActiveFocus()
      })
    } else {
      focusPrimeTimer.stop()
      focusPrimed = false
    }
    if (!bar || pinned) return
    if (open) {
      popoutSwitchClosing = false
      popoutSwitching = bar.activePopout && bar.activePopout !== coordinatorKey
      bar.requestPopout(coordinatorKey)
      if (popoutSwitching) popoutSwitchTimer.restart()
    } else {
      popoutSwitchClosing = !!(owner && owner.popoutSwitchClosing)
      popoutSwitching = false
      if (bar.activePopout === coordinatorKey) bar.releasePopout(coordinatorKey)
      if (popoutSwitchClosing) closeSwitchTimer.restart()
    }
  }

  Timer {
    id: focusPrimeTimer
    interval: 75
    onTriggered: if (root.open) root.focusPrimed = true
  }

  Timer {
    id: popoutSwitchTimer
    interval: 150
    onTriggered: root.popoutSwitching = false
  }

  Timer {
    id: closeSwitchTimer
    interval: 1
    onTriggered: root.popoutSwitchClosing = false
  }

  // --- outside-click dismissal (unpinned only) ------------------------------

  MouseArea {
    id: dismissArea
    anchors.fill: parent
    enabled: root.open && !root.pinned
    acceptedButtons: Qt.AllButtons
    hoverEnabled: true
    property bool hoveringBar: false
    cursorShape: hoveringBar ? Qt.PointingHandCursor : Qt.ArrowCursor

    function inBarRegion(px, py) {
      if (root.barPos === "bottom") return py >= root.screenH - root._barStripSize
      if (root.barPos === "left") return px <= root._barStripSize
      if (root.barPos === "right") return px >= root.screenW - root._barStripSize
      return py <= root._barStripSize
    }

    function barPoint(px, py) {
      if (root.barPos === "bottom") return Qt.point(px, py - (root.screenH - root.barH))
      if (root.barPos === "right") return Qt.point(px - (root.screenW - root.barW), py)
      return Qt.point(px, py)
    }

    function pressTargetAt(px, py) {
      if (!root.anchorWindow || !root.anchorWindow.contentItem || !root.bar || !root.bar.clickTargets) return null
      var p = barPoint(px, py)
      var targets = root.bar.clickTargets
      for (var i = targets.length - 1; i >= 0; i--) {
        var target = targets[i]
        if (!target || !target.triggerPress || target.visible === false || target.opacity === 0 || !target.mapToItem) continue
        if (root.bar.targetBelongsToWindow && !root.bar.targetBelongsToWindow(target, root.anchorWindow)) continue
        var pos = root.anchorWindow.itemPosition(target)
        if (p.x >= pos.x && p.x <= pos.x + target.width && p.y >= pos.y && p.y <= pos.y + target.height) return target
      }
      return null
    }

    function forwardBarClick(px, py, button) {
      if (button !== Qt.LeftButton && button !== Qt.RightButton && button !== Qt.MiddleButton) return false
      var target = pressTargetAt(px, py)
      if (!target) return false
      target.triggerPress(button)
      return true
    }

    onPositionChanged: function(mouse) { hoveringBar = inBarRegion(mouse.x, mouse.y) }
    onExited: hoveringBar = false
    onClicked: function(mouse) {
      if (root.focusPrimed && inBarRegion(mouse.x, mouse.y) && forwardBarClick(mouse.x, mouse.y, mouse.button)) return
      root.close()
    }
  }

  // Other monitors get a transparent twin whose only job is to catch the
  // dismissing click. Not needed while pinned.
  Variants {
    model: root.open && !root.pinned ? Quickshell.screens : []

    delegate: Component {
      PanelWindow {
        required property var modelData

        screen: modelData
        visible: root.open && !!root.screen && modelData.name !== root.screen.name
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore

        WlrLayershell.namespace: "fresh-tube-popup-dismiss"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        anchors {
          top: true
          bottom: true
          left: true
          right: true
        }

        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.AllButtons
          onPressed: root.close()
        }
      }
    }
  }

  // --- card ----------------------------------------------------------------

  BorderSurface {
    id: card
    x: root.cardOrigin.x
    y: root.cardOrigin.y
    width: root.contentWidth
    height: root.contentHeight
    color: Color.popups.background
    borderSpec: root.borderSpec
    padding: root.padding
    radius: Style.cornerRadius
    opacity: root.open || root.popoutSwitching ? 1.0 : 0

    Behavior on opacity {
      enabled: !root.popoutSwitching && !root.popoutSwitchClosing
      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }

    HoverHandler { id: cardHover }

    // Clicks on the card stay on the card.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.AllButtons
    }

    Item {
      id: contentHolder
      anchors.fill: parent
      anchors.topMargin: card.contentTopInset
      anchors.rightMargin: card.contentRightInset
      anchors.bottomMargin: card.contentBottomInset
      anchors.leftMargin: card.contentLeftInset
      opacity: root.popoutSwitching ? (root.open ? 1.0 : 0) : 1.0

      Behavior on opacity {
        enabled: root.popoutSwitching
        NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
      }
    }

    // The resize grip, declared last so it sits above the content. The size
    // is computed from the press point in window coordinates, so it stays
    // stable while the card (and the grip with it) grows under the cursor.
    MouseArea {
      id: grip
      visible: root.resizable
      width: Style.space(18)
      height: Style.space(18)
      anchors.right: root.growsLeft ? undefined : parent.right
      anchors.left: root.growsLeft ? parent.left : undefined
      anchors.bottom: root.growsUp ? undefined : parent.bottom
      anchors.top: root.growsUp ? parent.top : undefined
      hoverEnabled: true
      preventStealing: true
      acceptedButtons: Qt.LeftButton
      cursorShape: (!root.growsUp && !root.growsLeft) ? Qt.SizeFDiagCursor : Qt.SizeBDiagCursor

      property point start
      property int startWidth
      property int startHeight

      onPressed: function(mouse) {
        start = mapToItem(null, mouse.x, mouse.y)
        startWidth = root.contentWidth
        startHeight = root.contentHeight
      }
      onPositionChanged: function(mouse) {
        if (!pressed) return
        var p = mapToItem(null, mouse.x, mouse.y)
        var dx = root.growsLeft ? (start.x - p.x) : (p.x - start.x)
        var dy = root.growsUp ? (start.y - p.y) : (p.y - start.y)
        var maxW = root.growsLeft
          ? Math.max(root.minContentWidth, card.x + card.width - root.margin)
          : Math.max(root.minContentWidth, root.screenW - card.x - root.margin)
        var maxH = root.growsUp
          ? Math.max(root.minContentHeight, card.y + card.height - root.margin)
          : Math.max(root.minContentHeight, root.screenH - card.y - root.margin)
        root.resizeRequested(
          Math.round(root.clamp(startWidth + dx, root.minContentWidth, maxW)),
          Math.round(root.clamp(startHeight + dy, root.minContentHeight, maxH)))
      }
      onReleased: root.resized(root.contentWidth, root.contentHeight)

      Text {
        anchors.right: root.growsLeft ? undefined : parent.right
        anchors.left: root.growsLeft ? parent.left : undefined
        anchors.bottom: root.growsUp ? undefined : parent.bottom
        anchors.top: root.growsUp ? parent.top : undefined
        anchors.rightMargin: Style.space(3)
        anchors.leftMargin: Style.space(3)
        anchors.bottomMargin: Style.space(2)
        anchors.topMargin: Style.space(2)
        text: root.growsUp ? (root.growsLeft ? "◤" : "◥") : (root.growsLeft ? "◣" : "◢")
        textFormat: Text.PlainText
        color: root.gripColor
        opacity: grip.containsMouse || grip.pressed ? 0.9 : 0.35
        font.pixelSize: Style.font.caption

        Behavior on opacity { NumberAnimation { duration: 120 } }
      }
    }
  }
}
