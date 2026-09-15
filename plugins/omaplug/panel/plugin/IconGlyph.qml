import QtQuick

Text {
  id: glyph
  // Font bounds are relative to the baseline, not the top of the text item.
  x: (parent.width - metrics.tightBoundingRect.width) / 2 - metrics.tightBoundingRect.x
  y: (parent.height - metrics.tightBoundingRect.height) / 2 - metrics.tightBoundingRect.y - glyph.baselineOffset
  textFormat: Text.PlainText
  color: "white"
  font.bold: true

  TextMetrics {
    id: metrics
    font: glyph.font
    text: glyph.text
    renderType: glyph.renderType
  }
}
