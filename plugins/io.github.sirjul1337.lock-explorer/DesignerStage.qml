import QtQuick
import "designs"
import "Designer.js" as D

// The designer's canvas, and the preview behind every component thumbnail:
// a real DesignBase with the layout's nodes inside it, at the screen's own
// size. Everything it renders is what the lock screen renders.
DesignBase {
  id: board

  // LayoutNode objects. Reassign the array when pieces are added, removed or
  // restacked; editing a piece needs nothing here, the canvas binds to it.
  property var nodes: []
  property bool editing: false
  property var selection: []
  property real viewScale: 1

  // Nothing here may take the keyboard: the designer owns it.
  inputEnabled: false
  flashOnFail: false

  signal nodePressed(string id, bool additive)
  signal nodeDragged(string id, real x, real y)
  signal nodeResized(string id, real w, real h)
  signal nodeDragEnded()

  // Where a node ended up, which is what the designer needs to turn a drag
  // into an offset and to work out what a component's pieces look like.
  function rectOf(index) {
    var it = repeater.itemAt(index)
    if (!it) return { x: 0, y: 0, w: 0, h: 0 }
    return { x: it.x, y: it.y, w: it.width, h: it.height }
  }

  Repeater {
    id: repeater
    model: board.nodes
    delegate: DesignerNode {
      required property var modelData
      // `board`, not `stage`: a delegate property named the same as the id it
      // is bound to would just bind to itself.
      stage: board
      node: modelData
    }
  }
}
