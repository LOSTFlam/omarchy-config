import QtQuick
import qs.Commons
import "GeoMath.js" as GeoMath
import "data/WorldOutline.js" as WorldOutline

// The guessing surface: a flat world map or a globe, drawn from bundled
// outlines and clicked to place a guess.
//
// Nothing here touches the network. The country rings are the generated
// data/WorldOutline.js, so the map and the globe stay fully interactive on a
// machine that has been offline for a week -- only the photo needs a connection.
//
// Two layers, deliberately:
//
//   the Canvas    paints land, and repaints only when the projection, zoom,
//                 rotation or size actually changes
//   the markers   are plain Items whose x/y are bindings on project(), so
//                 dropping or moving a pin costs no repaint at all
//
// Putting the markers on the Canvas would mean repainting 10,000 points every
// time a pin moves one pixel.
Item {
  id: root

  // Passed straight through to TileLayer, which is the only thing here that
  // touches the network. Nothing else in this file does -- the country rings
  // are the bundled data/WorldOutline.js.
  property string cacheDir: ""
  property string userAgent: ""

  // The player's CARTO basemap key, or "" for none. Empty is the default and
  // means the outlines below are the map, which is exactly what happens offline.
  property string apiKey: ""

  // ------------------------------------------------------------------ inputs

  // "map" (equirectangular) or "globe" (orthographic).
  property string mode: "map"

  // The guess, or null before one is placed. { lat, lon }
  property var guess: null

  // The true position, revealed only after the guess is locked in. { lat, lon }
  property var answer: null

  // While false the surface is inert: the reveal is on screen and a stray click
  // must not move the pin that is being scored.
  property bool interactive: true

  property color landColor: Color.popups.background
  property color landStroke: Color.popups.text
  property color graticuleColor: Color.popups.text
  property color guessColor: Color.popups.text
  property color answerColor: Color.urgent

  signal guessPlaced(real latitude, real longitude)

  // --------------------------------------------------------------- view state

  property real zoom: 1
  property real centreLat: 0
  property real centreLon: 0

  readonly property real minZoom: 1

  // The two projections need wildly different ceilings, and the map's is
  // derived rather than picked.
  //
  // `zoom` is a multiple of the world-fits-the-pane size, so the tile level it
  // reaches is log2(paneSize * zoom / 256). The old flat ceiling of 40 sounds
  // generous and is not: on a 330px-tall pane it tops out at tile level 6,
  // which is country outlines. Street level is 17 or 18. Deriving the ceiling
  // from the pyramid itself means it is right whatever size the pane ends up.
  readonly property real maxZoom: {
    if (root.mode === "globe") return 40
    var pane = Math.max(1, Math.min(root.width, root.height))
    return (GeoMath.TILE_SIZE * Math.pow(2, GeoMath.MAX_TILE_ZOOM)) / pane
  }

  // The plain object GeoMath works in. Rebuilt whenever anything in it moves,
  // which is also exactly when the Canvas needs repainting.
  readonly property var view: ({
    mode: root.mode,
    width: root.width,
    height: root.height,
    zoom: root.zoom,
    centreLat: root.centreLat,
    centreLon: root.centreLon
  })

  // --------------------------------------------------------------- ceilings
  //
  // Re-checked here, not just in tools/build-world.py. A cap that only exists in
  // the generator is a cap the running shell does not have: the shell loads
  // whatever bytes are on disk. A file that has grown past either ceiling is
  // truncated to it rather than trusted.
  readonly property var rings: {
    var all = WorldOutline.RINGS
    if (!Array.isArray(all)) return []
    var maxRings = Math.min(WorldOutline.MAX_RINGS || 400, 400)
    var maxPoints = Math.min(WorldOutline.MAX_POINTS || 16000, 16000)
    var out = []
    var points = 0
    for (var i = 0; i < all.length && out.length < maxRings; i++) {
      var ring = all[i]
      if (!Array.isArray(ring) || ring.length < 8) continue
      points += ring.length / 2
      if (points > maxPoints) break
      out.push(ring)
    }
    return out
  }

  // -------------------------------------------------------------- view moves

  function resetView() {
    root.zoom = 1
    root.centreLat = 0
    root.centreLon = 0
  }

  // Frames the two pins after a reveal, so the answer and the guess are both on
  // screen without the player having to hunt for either.
  function frameResult() {
    if (!root.guess || !root.answer) return
    root.centreLat = GeoMath.clamp((root.guess.lat + root.answer.lat) / 2, -80, 80)
    // Averaged through the wrap, or a guess in Japan and an answer in Alaska
    // centre the view on the Atlantic.
    root.centreLon = GeoMath.wrapLongitude(
        root.answer.lon + GeoMath.wrapLongitude(root.guess.lon - root.answer.lon) / 2)
    root.zoom = 1
  }

  function zoomBy(factor, aroundX, aroundY) {
    var before = GeoMath.unproject(root.view, aroundX, aroundY)
    root.zoom = GeoMath.clamp(root.zoom * factor, root.minZoom, root.maxZoom)
    if (!before) return
    // Keep whatever was under the pointer under the pointer. Without this,
    // zooming always walks toward the centre of the pane and the place you were
    // aiming at slides away.
    var after = GeoMath.unproject(root.view, aroundX, aroundY)
    if (!after) return

    if (root.mode === "globe") {
      root.centreLat = GeoMath.clamp(root.centreLat + (before.lat - after.lat), -89.9, 89.9)
      root.centreLon = GeoMath.wrapLongitude(root.centreLon + (before.lon - after.lon))
      return
    }

    // On the map the correction is applied in world units, not in degrees, for
    // the same reason panning is: a degree of latitude is worth a different
    // number of pixels at every latitude on this projection, so correcting in
    // degrees would leave the anchor drifting the further north you were.
    root.centreLat = GeoMath.worldYToLat(GeoMath.clamp(
        GeoMath.latToWorldY(root.centreLat)
          + (GeoMath.latToWorldY(before.lat) - GeoMath.latToWorldY(after.lat)), 0, 1))
    root.centreLon = GeoMath.worldXToLon(GeoMath.clamp(
        GeoMath.lonToWorldX(root.centreLon)
          + (GeoMath.lonToWorldX(before.lon) - GeoMath.lonToWorldX(after.lon)), 0, 1))
  }

  onModeChanged: {
    // The two projections do not share a sensible zoom: 4x on the flat map is a
    // country, 4x on the globe is off the edge of the disc. Reframing is less
    // surprising than carrying the number across.
    root.zoom = 1
    outline.requestPaint()
  }
  onViewChanged: outline.requestPaint()
  onWidthChanged: outline.requestPaint()
  onHeightChanged: outline.requestPaint()

  // ---------------------------------------------------------------- the land

  // OpenStreetMap tiles, on the flat map only. The globe cannot use them: tiles
  // are cut to Mercator and there is no way to drape a Mercator raster onto an
  // orthographic sphere without resampling every one of them per frame.
  TileLayer {
    id: tiles
    anchors.fill: parent
    clip: true
    // active, not merely visible: an invisible Image still loads, so leaving
    // the bindings live in globe mode would fetch tiles for every frame of a
    // spin and draw none of them.
    active: root.mode === "map"
    visible: root.mode === "map"
    view: root.view
    // Tiles are downloaded and header-checked before anything decodes them, so
    // the layer needs the private directory Panel.qml verified. Without one it
    // reports itself unhealthy and the outlines below take over.
    cacheDir: root.cacheDir
    userAgent: root.userAgent
    apiKey: root.apiKey
  }

  // The bundled outlines. In globe mode they are the map; in map mode they are
  // what is left when the tiles cannot be reached, which is the whole reason
  // this plugin still works on a machine that has been offline for a week.
  Canvas {
    id: outline
    visible: root.mode === "globe" || !tiles.healthy
    anchors.fill: parent

    // Matches the shell's own charting: an image-backed immediate canvas keeps
    // the paint on the render thread's terms rather than the scene graph's.
    renderTarget: Canvas.Image
    renderStrategy: Canvas.Immediate

    // While a drag is in flight every second point is dropped and the smallest
    // rings are skipped. At 10,000 points a full-quality repaint per drag frame
    // is visibly heavy; at half that, with the little islands gone, it is not,
    // and nobody can see the difference on a landmass that is moving. Released,
    // it repaints in full.
    property bool coarse: false
    onCoarseChanged: requestPaint()

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      if (root.width <= 0 || root.height <= 0) return

      var view = root.view
      var step = coarse ? 2 : 1
      var minPoints = coarse ? 16 : 8

      // The globe gets an ocean disc behind the land, so the sphere reads as a
      // sphere rather than as continents floating in the panel.
      if (view.mode === "globe") {
        var radius = GeoMath.globeRadius(view)
        ctx.beginPath()
        ctx.arc(view.width / 2, view.height / 2, radius, 0, Math.PI * 2)
        ctx.fillStyle = Qt.rgba(root.landStroke.r, root.landStroke.g, root.landStroke.b, 0.06)
        ctx.fill()
        ctx.strokeStyle = Qt.rgba(root.landStroke.r, root.landStroke.g, root.landStroke.b, 0.35)
        ctx.lineWidth = 1
        ctx.stroke()
      }

      drawGraticule(ctx, view, step)

      ctx.lineWidth = 1
      ctx.strokeStyle = Qt.rgba(root.landStroke.r, root.landStroke.g, root.landStroke.b, 0.85)
      ctx.fillStyle = Qt.rgba(root.landStroke.r, root.landStroke.g, root.landStroke.b, 0.22)

      var rings = root.rings
      for (var r = 0; r < rings.length; r++) {
        var ring = rings[r]
        if (ring.length / 2 < minPoints) continue
        drawRing(ctx, view, ring, step)
      }
    }

    function drawRing(ctx, view, ring, step) {
      ctx.beginPath()
      var drawing = false
      var lastX = 0
      var lastY = 0
      var count = ring.length / 2

      for (var i = 0; i < count; i += step) {
        var projected = GeoMath.project(view, ring[i * 2 + 1], ring[i * 2])

        if (!projected.visible) {
          // Round the back of the globe. The path has to be broken, not
          // continued, or the coastline is drawn straight across the disc.
          drawing = false
          continue
        }

        if (!drawing) {
          ctx.moveTo(projected.x, projected.y)
          drawing = true
        } else {
          // On the flat map a ring that crosses the antimeridian projects to
          // two points at opposite edges of the pane. Joining them draws a line
          // clean across the world, so the jump breaks the path instead.
          if (view.mode === "map" && Math.abs(projected.x - lastX) > view.width / 2) {
            ctx.moveTo(projected.x, projected.y)
          } else {
            ctx.lineTo(projected.x, projected.y)
          }
        }
        lastX = projected.x
        lastY = projected.y
      }

      ctx.fill()
      ctx.stroke()
    }

    function drawGraticule(ctx, view, step) {
      ctx.lineWidth = 1
      ctx.strokeStyle = Qt.rgba(root.graticuleColor.r, root.graticuleColor.g,
                                root.graticuleColor.b, 0.12)

      var lat, lon
      // Parallels every 30 degrees, sampled every 5 of longitude: on the globe
      // they are ellipses, so they cannot be drawn as straight segments.
      for (lat = -60; lat <= 60; lat += 30) {
        ctx.beginPath()
        strokePath(ctx, view, function (t) { return [lat, -180 + t * 5] }, 73)
        ctx.stroke()
      }
      // Meridians every 30 degrees.
      for (lon = -180; lon < 180; lon += 30) {
        ctx.beginPath()
        strokePath(ctx, view, function (t) { return [-90 + t * 5, lon] }, 37)
        ctx.stroke()
      }
    }

    function strokePath(ctx, view, at, samples) {
      var drawing = false
      var lastX = 0
      for (var t = 0; t < samples; t++) {
        var point = at(t)
        var projected = GeoMath.project(view, point[0], point[1])
        if (!projected.visible) { drawing = false; continue }
        if (!drawing) {
          ctx.moveTo(projected.x, projected.y)
          drawing = true
        } else if (view.mode === "map" && Math.abs(projected.x - lastX) > view.width / 2) {
          ctx.moveTo(projected.x, projected.y)
        } else {
          ctx.lineTo(projected.x, projected.y)
        }
        lastX = projected.x
      }
    }
  }

  // ------------------------------------------------------------- the markers

  // The line from guess to answer. Drawn as a rotated rectangle rather than a
  // second Canvas: it is one straight segment between two points that are
  // already projected, and a Canvas for it would mean a repaint per frame of
  // the reveal animation.
  Rectangle {
    id: link
    visible: root.answer !== null && root.guess !== null
             && guessPin.onScreen && answerPin.onScreen
    color: Qt.rgba(root.answerColor.r, root.answerColor.g, root.answerColor.b, 0.7)
    height: 2
    antialiasing: true
    transformOrigin: Item.Left

    readonly property real dx: answerPin.px - guessPin.px
    readonly property real dy: answerPin.py - guessPin.py

    x: guessPin.px
    y: guessPin.py - height / 2
    width: Math.sqrt(dx * dx + dy * dy)
    rotation: Math.atan2(dy, dx) * 180 / Math.PI
  }

  Item {
    id: guessPin
    visible: root.guess !== null && onScreen

    readonly property var projected: root.guess
        ? GeoMath.project(root.view, root.guess.lat, root.guess.lon)
        : null
    readonly property real px: projected ? projected.x : 0
    readonly property real py: projected ? projected.y : 0
    readonly property bool onScreen: projected !== null && projected.visible

    x: px
    y: py

    Rectangle {
      width: 13; height: 13; radius: 7
      x: -width / 2; y: -height / 2
      color: root.guessColor
      border.color: Qt.rgba(0, 0, 0, 0.55)
      border.width: 2
      antialiasing: true
    }
  }

  Item {
    id: answerPin
    visible: root.answer !== null && onScreen

    readonly property var projected: root.answer
        ? GeoMath.project(root.view, root.answer.lat, root.answer.lon)
        : null
    readonly property real px: projected ? projected.x : 0
    readonly property real py: projected ? projected.y : 0
    readonly property bool onScreen: projected !== null && projected.visible

    x: px
    y: py

    Rectangle {
      width: 15; height: 15; radius: 8
      x: -width / 2; y: -height / 2
      color: root.answerColor
      border.color: Qt.rgba(0, 0, 0, 0.55)
      border.width: 2
      antialiasing: true

      SequentialAnimation on scale {
        running: answerPin.visible
        loops: 3
        NumberAnimation { from: 1; to: 1.5; duration: 320; easing.type: Easing.OutQuad }
        NumberAnimation { from: 1.5; to: 1; duration: 320; easing.type: Easing.InQuad }
      }
    }
  }

  // Required by both OpenStreetMap and CARTO, and shown wherever their tiles
  // are: the data is free, the acknowledgement is the price.
  //
  // It follows the tiles rather than the map. Without a key no tile is fetched
  // and the outlines below are what is drawn -- those are bundled Natural Earth,
  // which is public domain and neither party's work, so crediting CARTO for a
  // map they did not render would be worse than not crediting them at all.
  Text {
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.margins: 4
    visible: root.mode === "map" && tiles.healthy
    text: "© OpenStreetMap contributors © CARTO"
    textFormat: Text.PlainText
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    color: Qt.rgba(root.landStroke.r, root.landStroke.g, root.landStroke.b, 0.55)
  }

  // ---------------------------------------------------------------- pointing

  MouseArea {
    id: pointer
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton
    hoverEnabled: false
    cursorShape: pressed && dragging ? Qt.ClosedHandCursor
                                     : (root.interactive ? Qt.CrossCursor : Qt.ArrowCursor)

    // Click and drag have to be told apart, or panning the map to look around
    // drops a pin every time you let go. The threshold is total travel, not
    // displacement, so a wander that returns to its start still counts as a
    // drag.
    property real lastX: 0
    property real lastY: 0
    property real travel: 0
    property bool dragging: false

    readonly property real dragThreshold: 6

    onPressed: function (mouse) {
      lastX = mouse.x
      lastY = mouse.y
      travel = 0
      dragging = false
    }

    onPositionChanged: function (mouse) {
      if (!pressed) return
      var dx = mouse.x - lastX
      var dy = mouse.y - lastY
      travel += Math.abs(dx) + Math.abs(dy)
      lastX = mouse.x
      lastY = mouse.y

      if (!dragging && travel > dragThreshold) {
        dragging = true
        outline.coarse = true
      }
      if (!dragging) return

      if (root.mode === "globe") {
        // Spin. The scale is set so a drag across the pane turns the globe
        // about half a turn, which feels like pushing a physical thing rather
        // than nudging a slider.
        var perPixel = 180 / Math.max(1, GeoMath.globeRadius(root.view) * 2)
        root.centreLon = GeoMath.wrapLongitude(root.centreLon - dx * perPixel)
        root.centreLat = GeoMath.clamp(root.centreLat + dy * perPixel, -89.9, 89.9)
      } else {
        // Panning happens in Mercator world units, not in degrees. Degrees per
        // pixel is not a constant on this projection -- a pixel near the top of
        // the map is worth several times as much latitude as one at the equator
        // -- so moving the centre by dy/degreesPerPixel would drag the map at a
        // different speed from the one it draws at, and the point under the
        // cursor would slide away as you moved.
        var size = GeoMath.mapWorldSize(root.view)
        if (size <= 0) return
        // Both axes clamped to the sheet, so panning stops at the edge of the
        // world instead of sailing off into empty space and leaving the player
        // to find their way back.
        var worldX = GeoMath.clamp(
            GeoMath.lonToWorldX(root.centreLon) - dx / size, 0, 1)
        var worldY = GeoMath.clamp(
            GeoMath.latToWorldY(root.centreLat) - dy / size, 0, 1)
        root.centreLon = GeoMath.worldXToLon(worldX)
        root.centreLat = GeoMath.worldYToLat(worldY)
      }
    }

    onReleased: function (mouse) {
      if (dragging) {
        dragging = false
        outline.coarse = false
        return
      }
      if (!root.interactive) return

      var point = GeoMath.unproject(root.view, mouse.x, mouse.y)
      // null is a click off the edge of the world -- past the pole on the map,
      // or outside the disc on the globe. Ignoring it is the point: that is
      // exactly where a mis-click lands, and scoring it as a real guess would
      // be worse than doing nothing.
      if (!point) return
      root.guessPlaced(point.lat, point.lon)
    }

    onCanceled: {
      dragging = false
      outline.coarse = false
    }

    onWheel: function (wheel) {
      var steps = wheel.angleDelta.y / 120
      if (steps === 0) return
      // Two notches per tile level on the map. At 1.25 per notch it took
      // fifty-four of them to get from the whole world to a street, which is
      // not zooming, it is grinding.
      var factor = root.mode === "globe" ? 1.25 : Math.SQRT2
      root.zoomBy(Math.pow(factor, steps), wheel.x, wheel.y)
    }
  }
}
