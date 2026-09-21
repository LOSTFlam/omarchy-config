import QtQuick
import qs.Commons

// Compact on-screen QWERTY keyboard that highlights the next key the user
// needs to press. Colors are fully derived from the Color/Style singletons
// so it matches whatever Omarchy theme is active. Purely visual — it does
// not read real keyboard events itself.
Item {
  id: root

  // Next character the drill expects, exactly as it appears in the target
  // text (may be uppercase, a digit, punctuation, or a single space).
  property string nextChar: ""
  // Finger color-coding (set by the lesson screen for Finger Gym levels):
  // keyFingerMap maps a board key ("q", ";", "1", "-", ...) to a finger id
  // ("index" | "middle" | "ring" | "pinky"), fingerColors maps each finger
  // id to its display color, and activeFinger restricts the zone tint to a
  // single finger pair ("" = tint every mapped key, for combined levels).
  property var keyFingerMap: ({})
  property var fingerColors: ({})
  property string activeFinger: ""
  property real keySize: Style.space(34)
  property real keyGap: Style.spacing.xs

  // Shifted symbols map back to their base key; everything else matches the
  // board directly (board rows are lowercase, digits, or literal symbols).
  readonly property var shiftMap: ({ "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "?": "/", ":": ";", "\"": "'" })
  readonly property string baseKey: {
    if (root.nextChar === "" || root.nextChar === " ") return root.nextChar
    if (root.shiftMap[root.nextChar] !== undefined) return root.shiftMap[root.nextChar]
    var lower = root.nextChar.toLowerCase()
    return lower
  }
  readonly property bool isUpperLetter: root.nextChar !== "" && root.nextChar !== root.nextChar.toLowerCase() && root.nextChar === root.nextChar.toUpperCase()
  readonly property bool needsShift: root.isUpperLetter || root.shiftMap[root.nextChar] !== undefined

  // Full-size layout modeled on a real keyboard: staggered rows via wide
  // edge keys (Tab / Caps / Shift on the left, Backspace / Enter / Shift on
  // the right), "`" and "\" included, and Ctrl/Win/Alt on both sides of a
  // wide spacebar. Every row is 15 units wide. Modifier keys are purely
  // visual (drills never expect them) except Shift, which lights up on both
  // sides whenever the next character needs it, and Space, which lights up
  // for word gaps. Purely visual — reads no real keyboard events itself.
  readonly property var rows: [
    ["`", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "=", "backspace"],
    ["tab", "q", "w", "e", "r", "t", "y", "u", "i", "o", "p", "[", "]", "\\"],
    ["caps", "a", "s", "d", "f", "g", "h", "j", "k", "l", ";", "'", "enter"],
    ["shiftL", "z", "x", "c", "v", "b", "n", "m", ",", ".", "/", "shiftR"],
    ["ctrl", "win", "alt", "space", "alt", "win", "menu", "ctrl"]
  ]

  // Widths in key units; anything unlisted is a standard 1-unit key.
  readonly property var keyWidths: ({ "backspace": 2, "tab": 1.5, "\\": 1.5, "caps": 1.75, "enter": 2.25, "shiftL": 2.25, "shiftR": 2.75, "space": 8 })
  // Display labels; anything unlisted shows as its uppercase self.
  readonly property var keyLabels: ({ "tab": "Tab", "caps": "Caps", "enter": "Enter", "shiftL": "⇧", "shiftR": "⇧", "backspace": "⌫", "ctrl": "Ctrl", "alt": "Alt", "win": "Win", "menu": "Menu", "space": "space" })

  implicitWidth: column.implicitWidth
  implicitHeight: column.implicitHeight

  Column {
    id: column
    anchors.centerIn: parent
    spacing: root.keyGap

    Repeater {
      model: root.rows

      Row {
        required property var modelData
        required property int index
        spacing: root.keyGap

        Repeater {
          model: parent.modelData

          Rectangle {
            id: keyCap
            required property string modelData
            readonly property bool isShiftKey: modelData === "shiftL" || modelData === "shiftR"
            readonly property bool isSpaceKey: modelData === "space"
            readonly property bool isHome: modelData === "f" || modelData === "j"
            readonly property bool active: isShiftKey ? root.needsShift
              : (isSpaceKey ? root.baseKey === " " : (modelData === root.baseKey && root.baseKey !== ""))
            // Finger zone membership: tinted when this key belongs to the
            // trained finger (or to any mapped finger on combined levels).
            readonly property string finger: root.keyFingerMap[modelData] || ""
            readonly property bool inZone: finger !== "" && (root.activeFinger === "" || root.activeFinger === finger)
            readonly property color fingerColor: root.fingerColors[finger] || "transparent"

            width: (root.keyWidths[modelData] || 1) * root.keySize
            height: root.keySize
            radius: Style.cornerRadius > 0 ? Math.min(Style.cornerRadius, 6) : 4
            color: active ? (finger !== "" ? Util.alpha(fingerColor, 0.38) : Util.alpha(Color.accent, 0.28))
              : (inZone ? Util.alpha(fingerColor, 0.16) : Util.alpha(Color.foreground, 0.05))
            border.width: active || inZone ? Math.max(1, Style.space(2)) : 1
            border.color: active ? (finger !== "" ? fingerColor : Color.accent)
              : (inZone ? Util.alpha(fingerColor, 0.55) : Util.alpha(Color.foreground, 0.18))

            Behavior on color { ColorAnimation { duration: 90 } }
            Behavior on border.color { ColorAnimation { duration: 90 } }

            Text {
              anchors.centerIn: parent
              text: root.keyLabels[keyCap.modelData] || keyCap.modelData.toUpperCase()
              color: keyCap.active ? (keyCap.finger !== "" ? keyCap.fingerColor : Color.accent) : Color.muted
              font.family: Style.font.family
              font.pixelSize: keyCap.modelData.length > 1 ? Style.font.bodySmall : Style.font.body
              font.bold: keyCap.active
            }

            // Small tactile bump under F/J, same as a physical keyboard —
            // a constant visual anchor for finding home row by feel.
            Rectangle {
              visible: keyCap.isHome
              width: parent.width * 0.4
              height: Math.max(2, Style.space(2))
              radius: height / 2
              color: keyCap.active ? Color.accent : Util.alpha(Color.foreground, 0.4)
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.bottom: parent.bottom
              anchors.bottomMargin: parent.height * 0.14
            }
          }
        }
      }
    }
  }
}
