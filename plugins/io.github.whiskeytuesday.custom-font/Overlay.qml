// Overlay.qml
//
// User-visible face of the plugin. Two panes:
//   left  — inline directory browser (Qt.labs.folderlistmodel), path field
//   right — pangram preview, GTK scope, action row
//
// Deliberately keyboard-friendly: type/paste a path OR click through the
// listing; Enter installs; Escape dismisses.
//
// Colors, font family, and sizing come from `qs.Commons` singletons (Color,
// Style, Util) so the overlay follows the user's shell theme. Only two
// exceptions: the pangram preview itself uses `previewLoader.name` — that's
// the whole point of a font preview — and the fixed pixel radii on inner
// panels, which stay small so a Hyprland `rounding=0` theme still looks
// legible.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Wayland
import qs.Commons

Item {
  id: root

  property var shell: null
  property var manifest: null
  property var service: null

  property bool opened: false

  // ---- draft state (not applied until Install) ----
  property string draftPath: ""
  property string draftGnomeScope: "none"   // "none" | "font" | "mono" | "both"
  property bool draftSetAsDefault: true

  // ---- picker state ----
  // Read-only view onto the service — the service owns the last-dir. Nav
  // clicks call `service.rememberDir()` and this binding updates.
  readonly property string browseDir: root.service ? root.service.lastDir : "/"
  property bool confirmingReset: false

  readonly property bool applying: !!(root.service && root.service.busy)
  readonly property bool pathLooksLikeFontFile: /\.(ttf|otf)$/i.test(root.draftPath)
  readonly property bool canInstall: root.draftPath.length > 0 && !applying

  // ---- lifecycle ----

  function open(payloadJson) {
    root.opened = true
    root.confirmingReset = false
    errorBanner.text = ""
    if (root.service) root.service.refresh()
    Qt.callLater(function() { pathField.forceActiveFocus() })
  }

  function close() { root.opened = false }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "io.github.whiskeytuesday.custom-font")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function navigateInto(dir) {
    if (root.service) root.service.rememberDir(dir)
  }

  // Single dispatch point for both the Install button and Enter. If these
  // ever drift, the wrong action fires on Enter and nobody notices until a
  // bug report — so both callers go through here.
  function submit() {
    if (!root.canInstall) return
    errorBanner.text = ""
    if (root.draftSetAsDefault)
      root.service.installAndSet(root.draftPath, root.draftGnomeScope)
    else
      root.service.installOnly(root.draftPath)
  }

  function parentOf(dir) {
    var s = String(dir || "")
    if (s.length <= 1) return "/"
    var i = s.lastIndexOf("/")
    return i <= 0 ? "/" : s.slice(0, i)
  }

  // ---- service wiring ----

  Connections {
    target: root.service
    function onApplied() { root.dismiss() }
    function onReset()   { root.dismiss() }
    function onErrored(msg) { errorBanner.text = msg }
  }

  // ---- preview font loader ----
  //
  // Only load when the path looks like a font file that exists on disk;
  // FontLoader on a bad path is harmless (status becomes Error) but noisy.
  FontLoader {
    id: previewLoader
    source: root.pathLooksLikeFontFile ? "file://" + root.draftPath : ""
  }

  // ---- picker model ----
  FolderListModel {
    id: dirModel
    folder: "file://" + root.browseDir
    nameFilters: ["*.ttf", "*.otf", "*.TTF", "*.OTF"]
    showDirs: true
    showFiles: true
    showDotAndDotDot: false
    sortField: FolderListModel.Name
  }

  // ---- layout ----
  //
  // A Wayland layer surface hosts the overlay; without this the Rectangle
  // has no scene to paint into and the toggle appears to do nothing.
  // ExclusionMode.Ignore keeps the bar's exclusive zones untouched;
  // keyboardFocus Exclusive so Enter/Escape work without the compositor
  // routing keys elsewhere.
  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "custom-font"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    // Click-outside-card scrim; also darkens the desktop behind us.
    Rectangle {
      anchors.fill: parent
      color: Util.alpha(Color.background, 0.5)
      MouseArea {
        anchors.fill: parent
        onClicked: root.dismiss()
      }
    }

    Rectangle {
      id: card
      anchors.centerIn: parent
      // Cap the ideal size against the viewport so smaller displays and
      // fractional-scale setups don't clip.
      width: Math.min(760, parent.width - Style.spacing.xxl * 2)
      height: Math.min(520, parent.height - Style.spacing.xxl * 2)
      radius: Style.cornerRadius
      color: Color.background
      border.color: Util.alpha(Color.foreground, 0.15)
      // The scrim above catches outside clicks; this MouseArea stops the
      // click from bubbling to it when the user clicks *on* the card.
      // Stacking-order contract: the card must be declared AFTER the scrim
      // so it wins z-order. Don't reorder these siblings.
      MouseArea { anchors.fill: parent; preventStealing: true }

    ColumnLayout {
      anchors.fill: parent
      anchors.margins: Style.spacing.xxl
      spacing: Style.spacing.lg

      // Header: current family + stale flag.
      RowLayout {
        Layout.fillWidth: true
        Label {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          text: {
            if (!root.service) return "Current: …"
            var cf = root.service.currentFont
            var s = "Current: " + (cf.family || "?")
            if (cf.stale) s += "   [stale Omarchy 3 override]"
            return s
          }
        }
      }

      // Body: picker | details
      RowLayout {
        Layout.fillWidth: true
        Layout.fillHeight: true
        spacing: Style.spacing.lg

        // ---- LEFT: inline directory browser ----
        ColumnLayout {
          Layout.preferredWidth: 340
          Layout.fillHeight: true
          spacing: Style.spacing.xs

          RowLayout {
            Layout.fillWidth: true
            Button {
              text: "↑"
              ToolTip.text: "Parent directory"
              ToolTip.visible: hovered
              onClicked: root.navigateInto(root.parentOf(root.browseDir))
            }
            Label {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideLeft
              text: root.browseDir
            }
          }

          Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: Util.alpha(Color.foreground, 0.03)
            border.color: Util.alpha(Color.foreground, 0.1)
            radius: 6

            ListView {
              id: listing
              anchors.fill: parent
              anchors.margins: Style.spacing.sm
              clip: true
              model: dirModel
              delegate: Rectangle {
                width: listing.width
                height: 24
                color: hover.hovered ? Util.alpha(Color.foreground, 0.08) : "transparent"
                radius: 4

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.spacing.md
                  anchors.rightMargin: Style.spacing.md
                  spacing: Style.spacing.md

                  Label {
                    textFormat: Text.PlainText
                    text: fileIsDir ? "📁" : "🅰"
                    color: Color.muted
                    font.pixelSize: Style.font.caption
                  }
                  Label {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: fileName
                    color: Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }
                }

                HoverHandler { id: hover }
                TapHandler {
                  onTapped: {
                    if (fileIsDir) root.navigateInto(filePath)
                    else root.draftPath = filePath
                  }
                }
              }
            }
          }

          TextField {
            id: pathField
            Layout.fillWidth: true
            placeholderText: "…or type/paste a path"
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            text: root.draftPath
            onTextChanged: if (text !== root.draftPath) root.draftPath = text
            // TextField eats Return before the card's Keys.onReturnPressed
            // sees it, so wire Enter directly. Without this, the most common
            // path — paste, Enter — silently does nothing.
            onAccepted: root.submit()
          }
        }

        // ---- RIGHT: preview + options ----
        ColumnLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: Style.spacing.md

          // Pangram preview panel — hidden when nothing to preview. The
          // preview labels use `previewLoader.name` for `font.family` on
          // purpose: this is the one place we DON'T want the shell theme's
          // font, because the whole point is to see the picked font.
          // Word-wrap rather than elide: the pangram at Style.font.display
          // rarely fits the right column on one line, and half a pangram
          // does not preview a font.
          Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: previewColumn.implicitHeight + Style.spacing.lg * 2
            color: Util.alpha(Color.foreground, 0.03)
            border.color: Util.alpha(Color.foreground, 0.1)
            radius: 6
            visible: root.pathLooksLikeFontFile

            ColumnLayout {
              id: previewColumn
              anchors.fill: parent
              anchors.margins: Style.spacing.lg
              spacing: Style.spacing.xxs

              Label {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: "Sphinx of black quartz, judge my vow."
                color: Color.foreground
                font.pixelSize: Style.font.display
                font.family: previewLoader.status === FontLoader.Ready
                             ? previewLoader.name : "sans-serif"
                wrapMode: Text.WordWrap
              }
              Label {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: "1234567890 — {[(#$&@?)]}"
                color: Color.muted
                font.pixelSize: Style.font.heading
                font.family: previewLoader.status === FontLoader.Ready
                             ? previewLoader.name : "sans-serif"
                wrapMode: Text.WordWrap
              }
              Label {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                visible: previewLoader.status === FontLoader.Error
                text: "(font failed to load)"
                color: Color.urgent
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }

          // Install-as-default checkbox.
          CheckBox {
            text: "Set as shell default"
            checked: root.draftSetAsDefault
            onToggled: root.draftSetAsDefault = checked
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          // GTK scope. One question up front — "should GTK apps follow?" —
          // with an Advanced disclosure for the split "UI only / mono only"
          // case. Semantically: "none" = off, "both" = the checkbox default,
          // "font"/"mono" only reachable via Advanced.
          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.xxs
            enabled: root.draftSetAsDefault

            CheckBox {
              id: gtkCheck
              text: "Also apply to GTK apps (file dialogs, GTK apps)"
              checked: root.draftGnomeScope !== "none"
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              onToggled: {
                root.draftGnomeScope = checked ? "both" : "none"
                if (!checked) gtkAdvanced.expanded = false
              }
            }

            // Advanced disclosure — a plain clickable Label, since Controls
            // has no expander widget.
            Label {
              textFormat: Text.PlainText
              id: gtkAdvancedToggle
              Layout.leftMargin: 22
              visible: gtkCheck.checked
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              text: gtkAdvanced.expanded ? "▾ Advanced" : "▸ Advanced"
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: gtkAdvanced.expanded = !gtkAdvanced.expanded
              }
            }

            ColumnLayout {
              id: gtkAdvanced
              property bool expanded: false
              Layout.leftMargin: 22
              visible: gtkCheck.checked && expanded
              spacing: Style.spacing.hairline

              RadioButton { text: "UI + monospace (default)"; checked: root.draftGnomeScope === "both"; font.family: Style.font.family; font.pixelSize: Style.font.body; onToggled: if (checked) root.draftGnomeScope = "both" }
              RadioButton { text: "UI font only";             checked: root.draftGnomeScope === "font"; font.family: Style.font.family; font.pixelSize: Style.font.body; onToggled: if (checked) root.draftGnomeScope = "font" }
              RadioButton { text: "Monospace only";           checked: root.draftGnomeScope === "mono"; font.family: Style.font.family; font.pixelSize: Style.font.body; onToggled: if (checked) root.draftGnomeScope = "mono" }
            }
          }

          Item { Layout.fillHeight: true }

          // Error banner.
          Label {
            textFormat: Text.PlainText
            id: errorBanner
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            visible: text.length > 0
            text: ""
          }

          // Action row: reset (with inline confirm) on the left, cancel +
          // install on the right.
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.md

            // Inline confirm: single button flips into a Yes/No pair.
            Button {
              visible: !root.confirmingReset
              text: "Reset to Omarchy defaults"
              enabled: !root.applying
              onClicked: root.confirmingReset = true
            }
            RowLayout {
              visible: root.confirmingReset
              spacing: Style.spacing.sm
              // Two-line confirm: primary asks, secondary spells out scope
              // and points at the surgical alternative so users who only
              // want to remove one font don't reach for this hammer.
              ColumnLayout {
                spacing: 0
                Layout.maximumWidth: 380
                Label {
                  textFormat: Text.PlainText
                  text: "Really reset?"
                  color: Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                }
                Label {
                  textFormat: Text.PlainText
                  text: "Wipes every .ttf/.otf in ~/.local/share/fonts. Delete a file there to remove one individually."
                  color: Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                  Layout.fillWidth: true
                }
              }
              Button {
                text: "Yes, reset"
                enabled: !root.applying
                onClicked: {
                  root.confirmingReset = false
                  if (root.service) root.service.resetAll()
                }
              }
              Button {
                text: "No"
                onClicked: root.confirmingReset = false
              }
            }

            Item { Layout.fillWidth: true }

            Button {
              text: "Cancel"
              onClicked: root.dismiss()
            }
            Button {
              text: root.applying ? "Installing…" : "Install"
              enabled: root.canInstall
              highlighted: true
              onClicked: root.submit()
            }
          }
        }
      }
    }

      // Enter installs, Escape dismisses (when the card owns focus).
      Keys.onReturnPressed: root.submit()
      Keys.onEscapePressed: root.dismiss()
    }
  }
}
