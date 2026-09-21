pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls as C
import qs.Commons
import qs.Ui
import "Typography.js" as Typography
import "Presentation.js" as Presentation

Item {
  id: root
  readonly property real readingSize: Typography.reading(Style.font)
  readonly property real supportingSize: Typography.supporting(Style.font)
  readonly property real iconSize: Typography.icon(Style.font)
  readonly property real targetSize: Typography.target(Style.font)
  property var service: null
  readonly property var inputs: service ? service.inputs : ({})
  readonly property var draft: service ? service.interestsDraft : null
  readonly property var editor: service ? service.interestEditor : null
  readonly property bool saving: service && service.activeAction === "save-interests"
  readonly property bool unsaved: editor !== null || Boolean(service && service.interestsDirty)
  readonly property bool compactSaveBar: height < Style.space(500)
  readonly property bool active: visible && service !== null && service.editorOpen === true
  readonly property string section: service && service.interestsSection === "added" ? "added" : "detected"
  readonly property color foreground: Color.foreground
  readonly property color secondary: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.65)
  property bool scanDetailsExpanded: false
  property double now: Date.now()
  property var navigationGuard: ({alive:true, serial:0})
  readonly property var detectedGroups: groupDetected(inputs.detected || [])
  readonly property var choiceGroups: groupChoices(inputs.serviceChoices || [], inputs.featureChoices || [], choiceSearch.text)
  readonly property var failedProbes: (inputs.probes || []).filter(function(probe) { return probe.state !== "success" })
  readonly property string scanWarning: scanWarningText()
  signal back()

  onActiveChanged: {
    navigationGuard.serial++
    if (active) {
      now = Date.now()
      if (editor) chooseSection("added", false)
    }
  }
  Component.onDestruction: { navigationGuard.alive = false; navigationGuard.serial++ }
  Timer { interval: 60000; repeat: true; running: root.active; onTriggered: root.now = Date.now() }
  Connections {
    target: root.service
    function onInterestEditSerialChanged() { root.revealEditor() }
  }
  function takeFocus() {
    if (editor) chooseSection("added", false)
    backButton.forceActiveFocus()
  }
  function chooseSection(value, focusTab) {
    navigationGuard.serial++
    if (service) service.interestsSection = value === "added" ? "added" : "detected"
    if (active && focusTab) (section === "added" ? addedTab : detectedTab).forceActiveFocus()
  }
  function focusLater(target) {
    var guard = navigationGuard
    var serial = ++guard.serial
    Qt.callLater(function() {
      if (!guard.alive || serial !== guard.serial || !root.active) return
      if (target === "editor" && root.editor) {
        pickerScroll.contentItem.contentY = 0
        editorLabel.forceActiveFocus()
      } else choiceSearch.forceActiveFocus()
    })
  }
  function revealEditor() {
    if (!active || !editor) return
    chooseSection("added", false)
    focusLater("editor")
  }
  function addInterest() { chooseSection("added", false); focusLater("search") }
  function revealFocusedControl(control) {
    if (!active || !control.visible) return
    var views = [detectedScroll, selectedScroll, pickerScroll]
    for (var i = 0; i < views.length; i++) {
      var view = views[i]
      if (!view || !view.visible || !view.contentItem || !view.contentItem.contentItem) continue
      var content = view.contentItem.contentItem
      var ancestor = control.parent
      while (ancestor && ancestor !== content) ancestor = ancestor.parent
      if (!ancestor) continue
      if (view === selectedScroll) {
        var x = control.mapToItem(content, 0, 0).x
        var horizontal = view.contentItem
        if (x < horizontal.contentX) horizontal.contentX = Math.max(0, x)
        else if (x + control.width > horizontal.contentX + view.availableWidth)
          horizontal.contentX = Math.max(0, x + control.width - view.availableWidth)
        return
      }
      var y = control.mapToItem(content, 0, 0).y
      var flickable = view.contentItem
      if (y < flickable.contentY) flickable.contentY = Math.max(0, y)
      else if (y + control.height > flickable.contentY + view.height)
        flickable.contentY = Math.max(0, y + control.height - view.height)
      return
    }
  }
  function choose(kind, choice) {
    if (service) service.selectInterestChoice(kind, choice, !service.interestChoiceSelected(kind, choice))
  }
  function dismissPendingEdit() {
    if (!service || saving) return
    service.interestEditor = null
    service.interestsError = ""
    focusLater("search")
  }
  function probeLabel(value) {
    var names = {"displays":"Displays", "input-devices":"Input devices", "bluetooth":"Bluetooth",
      "usb-devices":"USB devices", "system-model":"Computer model", "graphics":"Graphics",
      "audio-devices":"Audio devices", "power":"Power", "software-capabilities":"Installed capabilities",
      "installed-plugins":"Installed plugins", "bar-sections":"Bar locations"}
    var key = String(value || "local-probe").toLowerCase().replace(/[ _]/g, "-")
    var label = key.replace(/-/g, " ")
    return names[key] || label.charAt(0).toUpperCase() + label.slice(1)
  }
  function probeState(value) {
    return value === "success" ? "Checked" : value === "partial" ? "Partial"
      : value === "stale" ? "Stale" : "Unavailable"
  }
  function scanAge() {
    if (!inputs.checkedAt) return "Not checked yet"
    var minutes = Math.max(0, Math.floor((now - Number(inputs.checkedAt) * 1000) / 60000))
    return minutes < 1 ? "Checked just now" : minutes < 60 ? "Checked " + minutes + "m ago"
      : minutes < 1440 ? "Checked " + Math.floor(minutes / 60) + "h ago"
      : "Checked " + Math.floor(minutes / 1440) + "d ago"
  }
  function scanWarningText() {
    var failed = Boolean(service && service.scanError) || ["failed", "error", "unavailable"].indexOf(String(inputs.scanState)) >= 0
    if (!failed && !failedProbes.length && ["partial", "stale"].indexOf(String(inputs.scanState)) < 0) return ""
    var summary = failed ? "Scan unavailable or failed." : "Partial scan · available results are shown; stale items are labelled."
    var reasons = failedProbes.slice(0, 3).map(function(probe) {
      var reason = String(probe.reason || root.probeState(probe.state)).replace(/\s+/g, " ").trim()
      return root.probeLabel(probe.id) + ": " + (reason.length > 80 ? reason.slice(0, 79) + "…" : reason)
    })
    if (reasons.length) summary += "\n" + reasons.join(" · ")
    if (failedProbes.length > 3) summary += " · +" + (failedProbes.length - 3) + " more in Scan details"
    if (failed && !reasons.length) summary += " Rescan to try again; see Scan details."
    return summary
  }
  function groupDetected(values) {
    var groups = []
    values.forEach(function(value) {
      var hardware = value.domain === "hardware"
      var label = (hardware ? "Hardware" : "Capabilities")
        + (value.probeId ? " · " + root.probeLabel(value.probeId) : "")
      var group = groups.filter(function(item) { return item.label === label })[0]
      if (!group) { group = {label:label, hardware:hardware, rows:[]}; groups.push(group) }
      group.rows.push(value)
    })
    return groups.sort(function(a, b) { return Number(b.hardware) - Number(a.hardware) || a.label.localeCompare(b.label) })
  }
  function groupChoices(services, features, query) {
    var groups = []
    var needle = query.trim().toLowerCase()
    function append(values, kind) {
      values.forEach(function(value) {
        var label = String(value.name || value.label || value.id)
        var category = String(value.category || (kind === "service" ? "Apps & services" : "Features"))
        if (needle && (label + " " + category + " " + (value.terms || []).join(" ")).toLowerCase().indexOf(needle) < 0) return
        var title = (kind === "service" ? "Apps & services" : "Features")
        if (category !== title) title += " · " + category
        var group = groups.filter(function(item) { return item.label === title })[0]
        if (!group) { group = {label:title, rows:[]}; groups.push(group) }
        group.rows.push({kind:kind, choice:value, label:label})
      })
    }
    append(services, "service")
    append(features, "feature")
    return groups
  }
  Keys.onPressed: function(event) {
    if (!root.active || !(event.modifiers & Qt.AltModifier)) return
    if (event.key === Qt.Key_1) root.chooseSection("detected", true)
    else if (event.key === Qt.Key_2) root.chooseSection("added", true)
    else if (event.key === Qt.Key_A) root.addInterest()
    else return
    event.accepted = true
  }
  component Copy: Text {
    width: parent.width
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: root.foreground
    font.family: Style.font.family
    font.pixelSize: root.readingSize
  }
  component Action: Button {
    id: action
    fontSize: root.readingSize
    foreground: root.foreground
    bordered: true
    focusable: true
    opacity: enabled ? 1 : 0.45
    Accessible.role: Accessible.Button
    Accessible.name: text
    Accessible.onPressAction: if (enabled) clicked()
    onActiveFocusChanged: if (activeFocus) root.revealFocusedControl(action)
  }
  component CheckAction: Action {
    id: checkAction
    property bool showCheck: true
    implicitHeight: Math.max(root.targetSize, root.readingSize + Style.space(16))
    OutfitIcon {
      visible: checkAction.showCheck
      anchors.centerIn: parent
      width: root.iconSize; height: width
      kind: checkAction.selected ? "checked" : "unchecked"
      tint: root.foreground
    }
    Accessible.role: Accessible.CheckBox
    Accessible.checkable: true
    Accessible.checked: selected
    Accessible.onToggleAction: if (enabled) clicked()
  }
  Column {
    id: heading
    width: parent.width
    spacing: Style.space(8)
    Flow {
      width: parent.width; spacing: Style.space(8)
      Action { id: backButton; objectName: "interestsBackButton"; text: "Back"; onClicked: root.back() }
      Text { text: "Setup & interests"; color: root.foreground; font.family: Style.font.family; font.pixelSize: Style.font.title; font.bold: true }
    }
    Item {
      id: navigationRow
      width: parent.width
      readonly property bool stacked: scanActions.visible && tabs.width + scanActions.width + Style.space(20) > width
      height: stacked ? tabs.height + scanActions.height + Style.space(6) : Math.max(tabs.height, scanActions.visible ? scanActions.height : 0)
      Row {
        id: tabs
        spacing: Style.space(8)
      Action {
        id: detectedTab; objectName: "interestsDetectedTab"; text: "Hardware detected"
        selected: root.section === "detected"
        Accessible.role: Accessible.RadioButton; Accessible.name: "Hardware detected on this computer"
        Accessible.checkable: true; Accessible.checked: selected
        onClicked: root.chooseSection("detected", true)
        Keys.onRightPressed: root.chooseSection("added", true)
      }
      Action {
        id: addedTab; objectName: "interestsAddedTab"
        text: "Added by you" + (root.draft ? " (" + root.draft.criteria.length + ")" : "")
        selected: root.section === "added"
        Accessible.role: Accessible.RadioButton; Accessible.name: "Added by you"
        Accessible.checkable: true; Accessible.checked: selected
        onClicked: root.chooseSection("added", true)
        Keys.onLeftPressed: root.chooseSection("detected", true)
      }
      }
      Row {
        id: scanActions
        visible: root.section === "detected"
        x: navigationRow.stacked ? 0 : navigationRow.width - width
        y: navigationRow.stacked ? tabs.height + Style.space(6) : 0
        spacing: Style.space(6)
        Copy {
          width: implicitWidth
          height: rescanButton.height
          verticalAlignment: Text.AlignVCenter
          text: root.scanAge()
          color: root.secondary
        }
        Action {
          id: rescanButton
          objectName: "interestsRescanButton"
          text: root.service && root.service.backgroundBusy ? "Checking…" : "Rescan"
          enabled: root.service && !root.service.backgroundBusy && !root.service.mutationBusy
          onClicked: root.service.rescan(false)
        }
        Action {
          objectName: "scanDetailsButton"; text: root.scanDetailsExpanded ? "Hide details" : "Scan details"
          selected: root.scanDetailsExpanded
          onClicked: root.scanDetailsExpanded = !root.scanDetailsExpanded
        }
      }
    }
    Copy {
      text: root.section === "detected" ? "Use checked inputs for recommendations."
        : "Select multiple interests, then save your changes once."
      color: root.secondary
    }
  }
  Item {
    id: body
    anchors.top: heading.bottom; anchors.topMargin: Style.space(12)
    anchors.bottom: footer.top; anchors.bottomMargin: Style.space(12)
    width: parent.width
    ContentScrollView {
      id: detectedScroll; objectName: "interestsDetectedScroll"
      visible: root.section === "detected"
      width: parent.width
      height: parent.height
      clip: true; contentWidth: availableWidth
      C.ScrollBar.horizontal.policy: C.ScrollBar.AlwaysOff
      Column {
        width: detectedScroll.availableWidth; spacing: Style.space(8)
        Copy {
          objectName: "interestScanError"
          visible: Boolean(root.scanWarning)
          text: root.scanWarning
          color: root.service && root.service.scanError || ["failed", "error", "unavailable"].indexOf(String(root.inputs.scanState)) >= 0 ? Color.urgent : root.secondary
        }
        Column {
          width: parent.width; spacing: Style.space(5); visible: root.scanDetailsExpanded
          Copy { text: root.inputs.checkedAt ? "Last checked: " + new Date(Number(root.inputs.checkedAt) * 1000).toLocaleString() : "No completed scan"; color: root.secondary }
          Copy { text: "Selected suggestion inputs, not a complete hardware inventory."; color: root.secondary }
          Copy { visible: Boolean(text); text: root.service ? root.service.scanError : ""; color: Color.urgent }
          Repeater {
            objectName: "visibleProbeStatuses"; model: root.inputs.probes || []
            Copy {
              required property var modelData
              text: root.probeLabel(modelData.id) + " · " + root.probeState(modelData.state) + (modelData.reason ? " · " + modelData.reason : "")
              color: modelData.state === "success" ? root.secondary : Color.urgent
            }
          }
        }
        Copy {
          visible: !(root.inputs.detected || []).length
          text: root.service && root.service.interestsBusy ? "Loading detected inputs…" : "No detected inputs. Add interests in Added by you."
          color: root.secondary
        }
        Grid {
          id: detectedGrid
          objectName: "detectedSectionsGrid"
          width: detectedScroll.availableWidth
          columns: Presentation.sectionColumns(width, Style.space(480), columnSpacing)
          columnSpacing: Style.space(20); rowSpacing: Style.space(12)
          Repeater {
            objectName: "detectedGroups"; model: root.detectedGroups
            Column {
              id: detectedGroup
              required property var modelData
              width: Math.min(Style.space(540), (detectedGrid.width - detectedGrid.columnSpacing * (detectedGrid.columns - 1)) / detectedGrid.columns)
              spacing: Style.space(2)
              Copy { text: detectedGroup.modelData.label; color: root.secondary; font.bold: true; topPadding: Style.space(8) }
              Repeater {
                model: detectedGroup.modelData.rows
                Column {
                  id: detected
                  required property var modelData
                  property bool expanded: false
                  width: detectedGroup.width
                  Item {
                    width: parent.width; height: Math.max(root.targetSize + Style.space(4), detectedLabel.implicitHeight + Style.space(12))
                    Copy {
                      id: detectedLabel
                      anchors.left: parent.left; anchors.right: provenance.left; anchors.rightMargin: Style.space(6)
                      anchors.verticalCenter: parent.verticalCenter
                      text: String(detected.modelData.label || detected.modelData.id)
                    }
                    Copy {
                      id: provenance
                      readonly property bool stale: detected.modelData.freshness === "stale" || detected.modelData.stale === true
                      width: implicitWidth
                      anchors.right: detectedUse.left; anchors.rightMargin: Style.space(6)
                      anchors.verticalCenter: parent.verticalCenter
                      text: (stale ? "Stale" : "")
                        + (detected.modelData.method === "inferred" ? (stale ? " · " : "") + "Inferred" : "")
                      color: root.secondary
                    }
                    CheckAction {
                      id: detectedUse; objectName: "detectedUse." + String(detected.modelData.id)
                      anchors.right: info.left; anchors.rightMargin: Style.space(5); anchors.verticalCenter: parent.verticalCenter
                      width: root.targetSize; height: root.targetSize
                      selected: root.service && root.service.detectedEnabled(detected.modelData.id)
                      enabled: root.draft !== null && !root.saving
                      Accessible.name: String(detected.modelData.label || detected.modelData.id) + ": Use for suggestions"
                      onClicked: root.service.useDetected(detected.modelData.id, !selected)
                    }
                    Action {
                      id: info; objectName: "detectedInfo." + String(detected.modelData.id)
                      anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                      width: root.targetSize; height: root.targetSize
                      selected: detected.expanded
                      OutfitIcon {
                        anchors.centerIn: parent
                        width: root.iconSize; height: width
                        kind: "info"; tint: root.foreground
                      }
                      Accessible.name: (detected.expanded ? "Hide details for " : "Show details for ") + String(detected.modelData.label || detected.modelData.id)
                      onClicked: detected.expanded = !detected.expanded
                    }
                  }
                  Copy {
                    visible: detected.expanded; bottomPadding: Style.space(8); color: root.secondary
                    text: String(detected.modelData.label || detected.modelData.id) + "\n"
                      + root.probeLabel(detected.modelData.probeId) + " · " + String(detected.modelData.method || "local probe")
                      + " · " + String(detected.modelData.freshness || "unavailable")
                      + (detected.modelData.detail ? "\n" + detected.modelData.detail : "")
                      + "\nMatching terms: " + (detected.modelData.terms || []).join(", ")
                  }
                }
              }
            }
          }
        }
      }
    }
    Item {
      id: addedPane
      visible: root.section === "added"
      anchors.right: parent.right
      width: parent.width
      height: parent.height
      Column {
        id: pickerHeader
        width: parent.width; spacing: Style.space(6)
        TextField {
          id: choiceSearch; objectName: "interestChoiceSearch"
          font.pixelSize: root.readingSize
          width: parent.width; maximumLength: 256; foreground: root.foreground
          placeholderText: "Search apps, features or a custom topic"
          Accessible.name: "Search interests"
        }
        Action {
          objectName: "customInterestButton"
          width: parent.width
          visible: choiceSearch.text.trim().length > 0
          text: "Add ‘" + (choiceSearch.text.trim().length > 36 ? choiceSearch.text.trim().slice(0, 35) + "…" : choiceSearch.text.trim()) + "’ custom topic"
          Accessible.name: "Add ‘" + choiceSearch.text.trim() + "’ custom topic"
          enabled: root.draft !== null && !root.saving
          onClicked: { if (root.service.addCustomInterest(choiceSearch.text)) choiceSearch.text = "" }
        }
        Copy {
          visible: choiceSearch.text.trim().length > 64
          text: "Custom topics use the search text as one term (up to 64 characters). Shorten it to add."
          color: Color.urgent
        }
        Copy {
          objectName: "selectedInterestCount"
          text: (root.draft ? root.draft.criteria.length : 0) + " selected"
            + (root.editor ? " · Pending edit below" : "")
          font.bold: true
        }
        ContentScrollView {
          id: selectedScroll; objectName: "selectedInterestsScroll"
          width: parent.width
          height: root.targetSize + Style.space(22)
          rightPadding: 0
          clip: true; contentWidth: selectedContent.implicitWidth
          contentHeight: selectedContent.height
          C.ScrollBar.vertical.policy: C.ScrollBar.AlwaysOff
          C.ScrollBar.horizontal.policy: C.ScrollBar.AsNeeded
          Row {
            id: selectedContent
            height: root.targetSize + Style.space(8)
            spacing: Style.space(8)
            Repeater {
              objectName: "savedInterests"; model: root.draft ? root.draft.criteria : []
              BorderSurface {
                id: saved
                required property var modelData
                required property int index
                width: Math.min(selectedScroll.availableWidth,
                  Math.min(savedLabel.implicitWidth, Style.space(220)) + savedActions.implicitWidth + Style.space(26))
                height: selectedContent.height
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.055)
                radius: Style.cornerRadius
                Copy {
                  id: savedLabel
                  anchors.left: parent.left; anchors.right: savedActions.left; anchors.rightMargin: Style.space(6)
                  anchors.leftMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  text: String(saved.modelData.label) + (saved.modelData.enabled === false ? " · Paused" : "")
                  wrapMode: Text.NoWrap
                  elide: Text.ElideRight
                  Accessible.name: text
                }
                Row {
                  id: savedActions; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                  anchors.rightMargin: Style.space(4)
                  spacing: Style.space(4); enabled: !root.saving
                  Action {
                    objectName: "pauseInterest." + String(saved.modelData.id || saved.index)
                    visible: root.service && root.service.discoveryEnabled === true
                    text: saved.modelData.enabled === false ? "Resume" : "Pause"
                    Accessible.name: text + " " + saved.modelData.label
                    onClicked: { choiceSearch.forceActiveFocus(); root.service.changeInterest(saved.index, false) }
                  }
                  Action {
                    objectName: "removeInterest." + String(saved.modelData.id || saved.index); text: "×"
                    Accessible.name: "Remove " + saved.modelData.label
                    onClicked: { choiceSearch.forceActiveFocus(); root.service.changeInterest(saved.index, true) }
                  }
                }
              }
            }
            Copy {
              visible: root.draft && !root.draft.criteria.length
              width: selectedScroll.availableWidth
              height: selectedContent.height
              verticalAlignment: Text.AlignVCenter
              text: "Select apps, features or custom topics below."
              color: root.secondary
            }
          }
        }
      }
      ContentScrollView {
        id: pickerScroll; objectName: "interestsAddedScroll"
        anchors.top: pickerHeader.bottom; anchors.topMargin: Style.space(8)
        anchors.bottom: parent.bottom; width: parent.width
        clip: true; contentWidth: availableWidth
        C.ScrollBar.horizontal.policy: C.ScrollBar.AlwaysOff
        Column {
          width: pickerScroll.availableWidth; spacing: Style.space(8)
          Column {
            id: pendingEditor; objectName: "interestEditor"
            visible: root.editor !== null; width: parent.width; spacing: Style.space(6)
            enabled: !root.saving
            Copy { text: "Pending edit · preserved from your previous session"; font.bold: true }
            Copy { text: "Included when you Save changes. Your existing fields are retained."; color: root.secondary }
            TextField {
              id: editorLabel; objectName: "interestLabel"
              font.pixelSize: root.readingSize
              width: parent.width; foreground: root.foreground; maximumLength: 80
              Accessible.name: "Pending interest name"
              text: root.editor ? String(root.editor.criterion.label || "") : ""
              onTextEdited: if (root.editor) root.service.updateInterestEditor("label", text)
              onActiveFocusChanged: if (activeFocus) root.revealFocusedControl(editorLabel)
            }
            Copy {
              text: root.editor ? String(root.editor.criterion.kind || "topic")
                + (root.editor.criterion.serviceId ? " · " + root.editor.criterion.serviceId : "")
                + (root.editor.criterion.featureId ? " · " + root.editor.criterion.featureId : "") : ""
              color: root.secondary
            }
            TextField {
              id: editorTerms
              font.pixelSize: root.readingSize
              objectName: "interestTerms"; width: parent.width; foreground: root.foreground; maximumLength: 270
              Accessible.name: "Pending matching terms, separated by commas"
              placeholderText: "Matching terms, separated by commas"
              text: root.editor ? String(root.editor.termText || "") : ""
              onTextEdited: if (root.editor) root.service.updateInterestEditor("termText", text)
              onActiveFocusChanged: if (activeFocus) root.revealFocusedControl(editorTerms)
            }
            Action { objectName: "cancelInterestButton"; text: "Dismiss pending edit"; onClicked: root.dismissPendingEdit() }
          }
          Copy {
            visible: !root.choiceGroups.length
            text: root.service && root.service.interestsBusy ? "Loading choices…" : "No predefined choices match. Add a custom topic from the search above."
            color: root.secondary
          }
          Grid {
            id: choicesGrid
            objectName: "interestChoicesGrid"
            width: pickerScroll.availableWidth
            columns: Presentation.sectionColumns(width, Style.space(480), columnSpacing)
            columnSpacing: Style.space(20); rowSpacing: Style.space(12)
            Repeater {
              objectName: "interestChoiceGroups"; model: root.choiceGroups
              Column {
                id: choiceGroup
                required property var modelData
                width: Math.min(Style.space(540), (choicesGrid.width - choicesGrid.columnSpacing * (choicesGrid.columns - 1)) / choicesGrid.columns)
                spacing: Style.space(4)
                Copy { text: choiceGroup.modelData.label; color: root.secondary; font.bold: true }
                Flow {
                  id: choiceFlow
                  width: choiceGroup.width; spacing: Style.space(6)
                  Repeater {
                    model: choiceGroup.modelData.rows
                    CheckAction {
                      id: choiceButton
                      required property var modelData
                      objectName: (modelData.kind === "service" ? "serviceInterest." : "featureInterest.") + String(modelData.choice.id)
                      showCheck: false
                      width: choiceFlow.width
                      height: Math.max(root.targetSize, choiceLabel.implicitHeight + Style.space(16))
                      OutfitIcon {
                        id: choiceIcon
                        anchors.left: parent.left; anchors.leftMargin: Style.space(10)
                        anchors.verticalCenter: parent.verticalCenter
                        width: root.iconSize; height: width
                        kind: choiceButton.selected ? "checked" : "unchecked"
                        tint: root.foreground
                      }
                      Copy {
                        id: choiceLabel
                        anchors.left: choiceIcon.right; anchors.right: parent.right
                        anchors.margins: Style.space(10); anchors.verticalCenter: parent.verticalCenter
                        text: choiceButton.modelData.label
                      }
                      selected: root.service && root.service.interestChoiceSelected(modelData.kind, modelData.choice)
                      enabled: root.draft !== null && !root.saving
                      Accessible.name: modelData.label
                      onClicked: root.choose(modelData.kind, modelData.choice)
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
  BorderSurface {
    id: footer
    objectName: "interestsSaveBar"
    anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
    height: footerContent.implicitHeight + Style.space(12)
    radius: Style.cornerRadius
    color: root.unsaved || root.saving ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.10)
      : "transparent"
    borderSpec: root.unsaved || root.saving ? Border.controlSpec("normal", Color.accent, Color.accent) : Border.none()
    Rectangle {
      anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
      width: Style.space(3)
      visible: root.unsaved || root.saving
      color: Color.accent
    }
    Column {
      id: footerContent
      x: Style.space(12); y: Style.space(6)
      width: parent.width - Style.space(24)
      spacing: Style.space(6)
      Copy { visible: Boolean(text); text: root.service ? root.service.interestsError : ""; color: Color.urgent }
      Copy {
        visible: Boolean(text) && (root.unsaved || text.indexOf("Interests saved") !== 0)
        text: root.service ? root.service.interestsNotice : ""
        color: root.secondary
      }
      Item {
        width: parent.width
        readonly property bool stacked: width < saveActions.width + Style.space(280)
        height: stacked ? saveMessage.height + saveActions.height + Style.space(8)
          : Math.max(saveMessage.height, saveActions.height)
        Column {
          id: saveMessage
          width: parent.stacked ? parent.width : parent.width - saveActions.width - Style.space(16)
          anchors.verticalCenter: parent.stacked ? undefined : parent.verticalCenter
          spacing: Style.space(2)
          Copy {
            objectName: "interestsSaveStatus"
            text: root.saving ? "Saving changes…" : root.unsaved ? "Unsaved changes" : "All changes saved"
            color: root.unsaved || root.saving ? Color.accent : root.secondary
            font.bold: root.unsaved || root.saving
            Accessible.name: text
          }
          Copy {
            visible: !root.compactSaveBar
            text: root.saving ? "Applying your selections…" : root.unsaved
              ? "Save to apply your selections." : "Your selections are up to date."
            color: root.foreground
            font.pixelSize: root.supportingSize
          }
        }
        Row {
          id: saveActions
          anchors.right: parent.right
          y: parent.stacked ? saveMessage.height + Style.space(8) : (parent.height - height) / 2
          spacing: Style.space(8)
          Action {
            objectName: "discardInterestsButton"; text: "Discard"
            enabled: root.draft !== null && root.unsaved && !root.saving
            onClicked: { root.service.resetInterestsDraft(); choiceSearch.text = "" }
          }
          Action {
            objectName: "saveInterestsButton"; text: root.saving ? "Saving…" : "Save changes"
            selected: root.unsaved || root.saving
            foreground: root.unsaved || root.saving ? Color.accent : root.foreground
            enabled: root.draft !== null && root.service && root.unsaved && !root.service.busy
            onClicked: {
              if (root.service.saveInterests()) root.chooseSection(root.section, true)
            }
          }
        }
      }
    }
  }
}
