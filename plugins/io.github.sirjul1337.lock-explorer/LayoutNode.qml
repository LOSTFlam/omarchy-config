import QtQuick

// One piece of a design, as a real QML object rather than a plain JS record.
//
// That is the whole point of it: the canvas binds straight to these
// properties, so moving, resizing or restyling a piece repaints it without
// anything having to be told to look again. Designer.js turns them into plain
// objects for the file and back.
QtObject {
  // Not `id`, which QML keeps for itself. It only has to be unique inside one
  // design; it becomes the object's id in the generated QML.
  property string nodeId: ""
  property string kind: "label"

  // Which corner, edge or centre of the screen it holds on to, and how far it
  // sits from there (positive is right and down).
  property string anchor: "center"
  property int dx: 0
  property int dy: 0

  // 0 means "size yourself from your content".
  property int w: 0
  property int h: 0

  // The kind's own settings. Always assign a fresh object; the pieces watch
  // this property, not the keys inside it.
  property var spec: ({})
}
