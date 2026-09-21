import QtQuick

// Small theme-tinted icons without an icon-font or image-effect dependency.
Canvas {
  id: icon
  required property string kind
  required property color tint
  implicitWidth: 18
  implicitHeight: 18
  onKindChanged: requestPaint()
  onTintChanged: requestPaint()
  onWidthChanged: requestPaint()
  onHeightChanged: requestPaint()
  Accessible.ignored: true

  onPaint: {
    var ctx = getContext("2d")
    ctx.reset()
    ctx.scale(width / 24, height / 24)
    ctx.fillStyle = tint
    ctx.strokeStyle = tint
    ctx.lineWidth = 1.8
    ctx.lineCap = "round"
    ctx.lineJoin = "round"
    ctx.beginPath()
    if (kind === "checked" || kind === "unchecked") {
      ctx.rect(3, 3, 18, 18)
      ctx.stroke()
      if (kind === "checked") {
        ctx.beginPath()
        ctx.moveTo(6, 12); ctx.lineTo(10, 16); ctx.lineTo(18, 8)
        ctx.lineWidth = 2.5
        ctx.stroke()
      }
    } else if (kind === "info") {
      ctx.arc(12, 12, 9, 0, Math.PI * 2)
      ctx.stroke()
      ctx.beginPath()
      ctx.moveTo(12, 11); ctx.lineTo(12, 17)
      ctx.stroke()
      ctx.beginPath()
      ctx.arc(12, 7, 1.2, 0, Math.PI * 2)
      ctx.fill()
    } else if (kind === "density-list") {
      for (var line = 0; line < 3; line++) {
        var top = 3 + line * 7
        ctx.rect(2, top, 4, 4)
        ctx.moveTo(10, top + 2)
        ctx.lineTo(22, top + 2)
      }
      ctx.stroke()
    } else if (kind.indexOf("density-") === 0) {
      var columns = kind === "density-comfortable" ? 2 : 3
      var rows = kind === "density-dense" ? 3 : 2
      var gap = kind === "density-comfortable" ? 4 : 2
      var cellWidth = (20 - gap * (columns - 1)) / columns
      var cellHeight = (18 - gap * (rows - 1)) / rows
      for (var row = 0; row < rows; row++)
        for (var column = 0; column < columns; column++)
          ctx.rect(2 + column * (cellWidth + gap), 3 + row * (cellHeight + gap), cellWidth, cellHeight)
      ctx.fill()
    } else if (kind === "toolbox") {
      // Raised handle, wide case, split lid seam, and one central latch.
      ctx.moveTo(8, 7)
      ctx.lineTo(8, 5)
      ctx.quadraticCurveTo(8, 3, 10, 3)
      ctx.lineTo(14, 3)
      ctx.quadraticCurveTo(16, 3, 16, 5)
      ctx.lineTo(16, 7)
      ctx.moveTo(4, 7)
      ctx.lineTo(20, 7)
      ctx.quadraticCurveTo(22, 7, 22, 9)
      ctx.lineTo(22, 19)
      ctx.quadraticCurveTo(22, 21, 20, 21)
      ctx.lineTo(4, 21)
      ctx.quadraticCurveTo(2, 21, 2, 19)
      ctx.lineTo(2, 9)
      ctx.quadraticCurveTo(2, 7, 4, 7)
      ctx.closePath()
      ctx.moveTo(2, 12)
      ctx.lineTo(10, 12)
      ctx.moveTo(14, 12)
      ctx.lineTo(22, 12)
      ctx.rect(10, 11, 4, 4)
      ctx.stroke()
    } else if (kind === "compass") {
      ctx.arc(12, 12, 9, 0, Math.PI * 2)
      ctx.stroke()
      ctx.beginPath()
      ctx.moveTo(16.5, 7.5)
      ctx.lineTo(13.5, 13.5)
      ctx.lineTo(7.5, 16.5)
      ctx.closePath()
      ctx.stroke()
      ctx.beginPath()
      ctx.moveTo(16.5, 7.5)
      ctx.lineTo(10.5, 10.5)
      ctx.lineTo(13.5, 13.5)
      ctx.closePath()
      ctx.fill()
    } else if (kind === "sidebar" || kind === "collapse") {
      ctx.rect(3, 4, 18, 16)
      ctx.moveTo(9, 4)
      ctx.lineTo(9, 20)
      ctx.moveTo(16, 9)
      ctx.lineTo(kind === "collapse" ? 13 : 19, 12)
      ctx.lineTo(16, 15)
      ctx.stroke()
    } else if (kind === "stars") {
      for (var point = 0; point < 10; point++) {
        var angle = -Math.PI / 2 + point * Math.PI / 5
        var radius = point % 2 === 0 ? 10 : 4.5
        var x = 12 + Math.cos(angle) * radius
        var y = 12 + Math.sin(angle) * radius
        if (point === 0) ctx.moveTo(x, y)
        else ctx.lineTo(x, y)
      }
      ctx.closePath()
      ctx.fill()
    } else if (kind === "likes") {
      ctx.moveTo(12, 21)
      ctx.bezierCurveTo(9, 18, 2, 13, 2, 7.5)
      ctx.bezierCurveTo(2, 1.5, 9, 1, 12, 6)
      ctx.bezierCurveTo(15, 1, 22, 1.5, 22, 7.5)
      ctx.bezierCurveTo(22, 13, 15, 18, 12, 21)
      ctx.closePath()
      ctx.fill()
    } else if (kind === "views") {
      ctx.moveTo(2, 12)
      ctx.bezierCurveTo(7, 3, 17, 3, 22, 12)
      ctx.bezierCurveTo(17, 21, 7, 21, 2, 12)
      ctx.closePath()
      ctx.stroke()
      ctx.beginPath()
      ctx.arc(12, 12, 3, 0, Math.PI * 2)
      ctx.stroke()
    } else if (kind === "copies") {
      ctx.rect(8, 8, 12, 13)
      ctx.moveTo(5, 16)
      ctx.lineTo(3, 16)
      ctx.lineTo(3, 3)
      ctx.lineTo(15, 3)
      ctx.lineTo(15, 5)
      ctx.stroke()
    } else if (kind === "more") {
      for (var dot = 0; dot < 3; dot++) {
        ctx.moveTo(6 + dot * 6, 12)
        ctx.arc(4 + dot * 6, 12, 2, 0, Math.PI * 2)
      }
      ctx.fill()
    } else if (kind === "settings") {
      for (var tooth = 0; tooth < 32; tooth++) {
        var toothAngle = tooth * Math.PI / 16
        var toothRadius = tooth % 4 < 2 ? 10 : 7.5
        var tx = 12 + Math.cos(toothAngle) * toothRadius
        var ty = 12 + Math.sin(toothAngle) * toothRadius
        if (tooth === 0) ctx.moveTo(tx, ty)
        else ctx.lineTo(tx, ty)
      }
      ctx.closePath()
      ctx.stroke()
      ctx.beginPath()
      ctx.arc(12, 12, 3, 0, Math.PI * 2)
      ctx.stroke()
    } else if (kind === "close") {
      ctx.moveTo(6, 6)
      ctx.lineTo(18, 18)
      ctx.moveTo(18, 6)
      ctx.lineTo(6, 18)
      ctx.stroke()
    } else if (kind === "scan") {
      ctx.rect(3, 3, 18, 13)
      ctx.moveTo(12, 16)
      ctx.lineTo(12, 21)
      ctx.moveTo(7, 21)
      ctx.lineTo(17, 21)
      ctx.moveTo(7, 10)
      ctx.lineTo(10, 10)
      ctx.lineTo(12, 6)
      ctx.lineTo(14, 13)
      ctx.lineTo(16, 10)
      ctx.lineTo(18, 10)
      ctx.stroke()
    } else if (kind === "refresh") {
      ctx.arc(12, 12, 8, Math.PI / 3, Math.PI * 1.85)
      ctx.moveTo(20, 4)
      ctx.lineTo(20, 9)
      ctx.lineTo(15, 9)
      ctx.stroke()
    }
  }
}
