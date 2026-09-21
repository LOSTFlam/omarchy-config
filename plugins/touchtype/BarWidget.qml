import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "ProgressStore.js" as Progress
import "Curriculum.js" as Curriculum

// Compact bar indicator: keyboard icon plus daily streak.
// Hover shows per-track progress; click opens the Touch Type overlay.
BarWidget {
  id: root

  property string progressPath: Quickshell.env("HOME") + "/.local/state/omarchy/touchtype-progress.json"
  property var progress: Progress.defaultProgress()

  readonly property var fingerList: Curriculum.fingerLevels()
  readonly property var levelList: Curriculum.levels([])

  function countPassed(list) {
    var n = 0
    for (var i = 0; i < list.length; i++) {
      var entry = root.progress.levels[list[i].id]
      if (entry && entry.passed) n++
    }
    return n
  }
  readonly property int fingerPassed: root.countPassed(root.fingerList)
  readonly property int classicPassed: root.countPassed(root.levelList)
  readonly property int streakCount: root.progress.streak.count || 0
  readonly property string displayText: "⌨" + (root.streakCount > 0 ? "  🔥" + root.streakCount : "")

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  FileView {
    id: progressFile
    path: root.progressPath
    watchChanges: true
    printErrors: false
    onLoaded: root.progress = Progress.parse(text())
    onLoadFailed: root.progress = Progress.defaultProgress()
    onFileChanged: reload()
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? "⌨" : root.displayText
    tooltipText: "Touch Type — Finger Gym " + (root.fingerPassed + 1) + "/" + root.fingerList.length + ", Classic " + (root.classicPassed + 1) + "/" + root.levelList.length + ", " + root.streakCount + " day streak"
    horizontalMargin: 8.5

    onPressed: function(b) {
      if (root.bar && root.bar.shell) root.bar.shell.summon(root.moduleName, "{}")
    }
  }
}
