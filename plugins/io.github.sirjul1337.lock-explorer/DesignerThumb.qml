import QtQuick
import "designs"

// A saved component drawn at its real size and scaled into the palette, so
// the thing you drag looks like the thing you get. It borrows the canvas's
// DesignBase as `lock`, which is why it costs nothing but the pieces.
Item {
  id: thumb

  property var lock: null
  property var comp: null
  clip: true

  Item {
    width: Math.max(1, thumb.comp ? thumb.comp.w : 1)
    height: Math.max(1, thumb.comp ? thumb.comp.h : 1)
    scale: Math.min(thumb.width / width, thumb.height / height, 1)
    transformOrigin: Item.TopLeft
    x: (thumb.width - width * scale) / 2
    y: (thumb.height - height * scale) / 2

    Repeater {
      model: thumb.comp ? thumb.comp.nodes : []
      delegate: DesignerItem {
        required property var modelData
        lock: thumb.lock
        kind: modelData.kind
        spec: modelData.spec
        fixedWidth: modelData.w
        fixedHeight: modelData.h
        customQml: modelData.kind === "custom" ? String(modelData.spec.qml || "") : ""
        x: modelData.rx
        y: modelData.ry
      }
    }
  }
}
