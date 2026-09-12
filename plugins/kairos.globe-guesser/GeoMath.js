.pragma library

// Projections, their inverses, and the scoring curve.
//
// Everything here is pure: no QML types, no imports, no I/O. That is what lets
// tools/check-geomath.js run the whole file under plain node as well as under
// Qt's V4 engine, and assert that unproject(project(p)) comes back to p under
// both projections at every zoom and rotation the UI can reach.
//
// Two projections share one interface:
//
//   project(view, lat, lon)  -> { x, y, visible }
//   unproject(view, x, y)    -> { lat, lon } or null
//
// `view` is a plain object the QML side owns:
//
//   { mode, width, height, zoom, centreLat, centreLon }
//
// mode is "map" (equirectangular) or "globe" (orthographic). centreLat and
// centreLon are the point under the middle of the widget: on the map that is
// the pan position, on the globe it is the rotation.
//
// `visible` is false for a point on the far side of the globe. Callers must
// honour it -- an unchecked orthographic projection paints the back hemisphere
// mirrored over the front, which looks like a rendering fault rather than a
// missing check.

var EARTH_RADIUS_KM = 6371.0088

// The diagonal of the world in the standard scoring model. Fixed on purpose:
// the score for a given error must not change when the player zooms in.
var WORLD_SIZE_KM = 14916.862

var MAX_ROUND_SCORE = 5000

// ------------------------------------------------------------------ helpers

function clamp(value, low, high) {
  return value < low ? low : (value > high ? high : value)
}

var DEG = Math.PI / 180
var RAD = 180 / Math.PI

// The width of an edge, in pixels. Used by both projections, for the same
// reason in each: a point that lies exactly ON the edge of the world -- the
// globe's limb, or the top of the Mercator square -- projects to a coordinate
// that the arithmetic bringing it back lands a few ULPs outside. An exact
// comparison rejects precisely the ring of real coordinates the projection is
// least able to reproduce. Half a pixel is far below anything a mouse can
// express, so this widens no click that should have missed.
var LIMB_TOLERANCE_PX = 0.5

// Wraps a longitude difference into (-180, 180]. Used everywhere a longitude
// is compared or drawn: without it a line from Tokyo to San Francisco takes
// the long way round the map, straight through Europe.
function wrapLongitude(degrees) {
  var wrapped = (degrees + 180) % 360
  if (wrapped < 0) wrapped += 360
  return wrapped - 180
}

// --------------------------------------------------------------- mercator
//
// The flat map is Web Mercator, the projection every slippy-map tile in the
// world is cut to. It is not the projection you would choose to look at -- it
// makes Greenland the size of Africa -- but the map is here to be CLICKED, and
// clicking is only as precise as the agreement between where a tile draws a
// street and where the maths thinks that street is. Any other projection puts
// the tiles and the pin in different places.
//
// World coordinates are normalised: x and y both run 0..1 over the whole world,
// with y = 0 at the top. Multiplying by the world size in pixels gives screen
// space, and the same 0..1 space is what tile indices are computed from, so the
// tile grid and the pin cannot drift apart.

// Mercator cannot represent the poles: the projection sends them to infinity.
// This is the latitude at which the world becomes exactly square, and it is the
// same number every tile scheme uses.
var MERCATOR_MAX_LAT = 85.05112877980659

function lonToWorldX(longitude) {
  return (wrapLongitude(longitude) + 180) / 360
}

function latToWorldY(latitude) {
  var phi = clamp(latitude, -MERCATOR_MAX_LAT, MERCATOR_MAX_LAT) * DEG
  return (1 - Math.log(Math.tan(phi) + 1 / Math.cos(phi)) / Math.PI) / 2
}

function worldXToLon(x) {
  return wrapLongitude(x * 360 - 180)
}

function worldYToLat(y) {
  return Math.atan(sinh(Math.PI * (1 - 2 * y))) * RAD
}

// V4 has no Math.sinh in every build the shell might be running, and the
// identity is two exponentials. Cheaper to be certain than to find out from a
// bug report that the map is blank on somebody's machine.
function sinh(x) {
  return (Math.exp(x) - Math.exp(-x)) / 2
}

// The width of the whole world in pixels at the current zoom.
//
// Derived from the SMALLER pane dimension so that at zoom 1 the entire latitude
// range is on screen. Mercator's world is square, so fitting it to the larger
// dimension of a wide pane would push the poles off the top and bottom -- and
// the game draws from cities as far north as Reykjavik, which would then be
// unreachable without panning. Horizontally the world simply repeats, the way
// every slippy map does.
function mapWorldSize(view) {
  return Math.min(view.width, view.height) * view.zoom
}

// ONE world, not a repeating strip.
//
// Slippy maps normally repeat east-west, and that is right for a map you are
// reading. It is wrong for a map you are clicking. This pane is nearly three
// times wider than it is tall, so at minimum zoom three copies of the world
// would be on screen at once -- and a pin is drawn at whichever copy is nearest
// the centre, so two clicks in three would drop the marker a whole world-width
// from where the player actually clicked. A single sheet from -180 to +180 has
// no such ambiguity: what you click is where the pin goes.
//
// The cost is that panning does not continue across the antimeridian; you reach
// the edge of the sheet and stop. That is a smaller price than a pin that lands
// somewhere else.
function projectMap(view, latitude, longitude) {
  var size = mapWorldSize(view)
  return {
    x: view.width / 2 + (lonToWorldX(longitude) - lonToWorldX(view.centreLon)) * size,
    y: view.height / 2 + (latToWorldY(latitude) - latToWorldY(view.centreLat)) * size,
    visible: true
  }
}

function unprojectMap(view, x, y) {
  var size = mapWorldSize(view)
  if (size <= 0) return null

  var worldX = lonToWorldX(view.centreLon) + (x - view.width / 2) / size
  var worldY = latToWorldY(view.centreLat) + (y - view.height / 2) / size

  // Off the edge of the sheet is not a place. At minimum zoom the world is
  // narrower than the pane, so there is real background either side of it, and
  // a click out there has to mean nothing rather than mean the nearest coast.
  //
  // The tolerance is the same half-pixel the globe's limb uses and is there for
  // the same reason: at zoom 1 the edges of the world land exactly on the edges
  // of the pane, and the divisions between here and there put them a few ULPs
  // outside the 0 or 1 they should equal.
  var slack = LIMB_TOLERANCE_PX / size
  if (worldX < -slack || worldX > 1 + slack) return null
  if (worldY < -slack || worldY > 1 + slack) return null

  return {
    lat: worldYToLat(clamp(worldY, 0, 1)),
    lon: worldXToLon(clamp(worldX, 0, 1))
  }
}

// ------------------------------------------------------------------- tiles
//
// The raster tile grid covering the current view.
//
// Computed from the same normalised 0..1 world coordinates the projection uses,
// which is the point: the tiles and the pin are derived from one set of numbers,
// so they cannot drift apart. A tile scheme that agreed with the projection only
// approximately would put every guess quietly off by however much it disagreed.
var TILE_SIZE = 256
var MAX_TILE_ZOOM = 19

// Which integer zoom level of the pyramid is closest to the current continuous
// zoom. Rounding rather than flooring keeps tiles within a factor of root two
// of their native size, so they are never upscaled more than about 41% and
// never wastefully downscaled by more than the same.
function tileZoomFor(view) {
  var size = mapWorldSize(view)
  if (!(size > 0)) return 0
  return clamp(Math.round(Math.log(size / TILE_SIZE) / Math.LN2), 0, MAX_TILE_ZOOM)
}

// The tile window: which level of the pyramid, how big a tile is on screen, and
// where the pane's top-left corner sits in tile units.
//
// Split out from tileGrid deliberately. Panning changes `left` and `top`
// continuously but changes which tiles are needed only when a whole new row or
// column comes into view. Keeping the two apart lets the layer rebuild its model
// on the rare event and merely move what it already has on the common one --
// otherwise every drag frame destroys and recreates every tile Image, which is
// both wasteful and visible as flicker.
function tileFrame(view) {
  var size = mapWorldSize(view)
  if (!(size > 0) || !(view.width > 0) || !(view.height > 0)) return null

  var z = tileZoomFor(view)
  var n = Math.pow(2, z)
  var px = size / n

  var left = lonToWorldX(view.centreLon) * n - (view.width / 2) / px
  var top = latToWorldY(view.centreLat) * n - (view.height / 2) / px

  return {
    z: z,
    n: n,
    px: px,
    left: left,
    top: top,
    iMin: Math.floor(left),
    iMax: Math.floor(left + view.width / px),
    jMin: Math.floor(top),
    jMax: Math.floor(top + view.height / px)
  }
}

function tileGrid(view, maxTiles) {
  var out = []
  var frame = tileFrame(view)
  if (!frame) return out

  var limit = maxTiles > 0 ? maxTiles : 64

  for (var j = frame.jMin; j <= frame.jMax; j++) {
    // Mercator has no tiles above the top of the world or below its bottom, and
    // no copy of the world east or west of it either -- see projectMap.
    if (j < 0 || j >= frame.n) continue
    for (var i = frame.iMin; i <= frame.iMax; i++) {
      if (i < 0 || i >= frame.n) continue
      // The ceiling is on what is BUILT, not on what is drawn afterwards. Each
      // entry becomes an Image that fetches and decodes, so an unbounded grid
      // is an unbounded number of requests into the shared shell process.
      if (out.length >= limit) return out
      out.push({
        z: frame.z,
        x: i,
        y: j,
        // Where this tile sits right now. The layer does not read these -- it
        // binds positions to the frame so panning does not rebuild the model --
        // but the check suites assert they match what project() says the tile's
        // own corner coordinate maps to, which is what proves the tiles and the
        // guess pin cannot drift apart.
        sx: (i - frame.left) * frame.px,
        sy: (j - frame.top) * frame.px,
        size: frame.px
      })
    }
  }
  return out
}

// ------------------------------------------------------------- orthographic
//
// The globe: the view from infinitely far away, so the outline is a true circle
// and the near hemisphere is drawn undistorted at the centre.
//
// The radius is derived from the smaller dimension so the globe fits whatever
// shape the pane is, and zoom scales it about the centre.

function globeRadius(view) {
  return (Math.min(view.width, view.height) / 2) * 0.92 * view.zoom
}

function projectGlobe(view, latitude, longitude) {
  var radius = globeRadius(view)
  var phi = latitude * DEG
  var phi0 = view.centreLat * DEG
  var deltaLambda = wrapLongitude(longitude - view.centreLon) * DEG

  var cosPhi = Math.cos(phi)
  var sinPhi = Math.sin(phi)
  var cosPhi0 = Math.cos(phi0)
  var sinPhi0 = Math.sin(phi0)

  // cos(c) is the cosine of the angular distance from the centre of the disc.
  // Negative means the point is round the back.
  var cosC = sinPhi0 * sinPhi + cosPhi0 * cosPhi * Math.cos(deltaLambda)

  return {
    x: view.width / 2 + radius * cosPhi * Math.sin(deltaLambda),
    y: view.height / 2 - radius * (cosPhi0 * sinPhi - sinPhi0 * cosPhi * Math.cos(deltaLambda)),
    visible: cosC >= 0
  }
}

function unprojectGlobe(view, x, y) {
  var radius = globeRadius(view)
  if (radius <= 0) return null

  var dx = x - view.width / 2
  var dy = view.height / 2 - y
  var rho = Math.sqrt(dx * dx + dy * dy)

  // A click outside the disc is not a point on Earth. Returning null rather
  // than snapping to the limb matters: the limb is where a mis-click lands, and
  // silently scoring it as a guess at the horizon would be worse than ignoring
  // it.
  //
  // The tolerance is not slack, it is the limb itself. A point exactly 90
  // degrees from the centre projects to rho == radius, and the two square
  // roots between here and there land it a few ULPs the wrong side, so an
  // exact comparison rejects the one ring of real coordinates the projection
  // is least able to reproduce. Half a pixel is far below anything a mouse can
  // express, and well inside the 1% margin the "just outside" case tests.
  if (rho > radius + LIMB_TOLERANCE_PX) return null
  if (rho > radius) rho = radius
  if (rho === 0) return { lat: view.centreLat, lon: wrapLongitude(view.centreLon) }

  // clamp guards the floating-point case where rho is a hair over radius after
  // the comparison above passed; asin of 1.0000000001 is NaN.
  var c = Math.asin(clamp(rho / radius, -1, 1))
  var sinC = Math.sin(c)
  var cosC = Math.cos(c)
  var phi0 = view.centreLat * DEG
  var sinPhi0 = Math.sin(phi0)
  var cosPhi0 = Math.cos(phi0)

  var latitude = Math.asin(clamp(cosC * sinPhi0 + (dy * sinC * cosPhi0) / rho, -1, 1)) * RAD
  var longitude = view.centreLon + Math.atan2(
      dx * sinC,
      rho * cosPhi0 * cosC - dy * sinPhi0 * sinC) * RAD

  return { lat: latitude, lon: wrapLongitude(longitude) }
}

// The one URL this plugin hands to Image.source.
//
// The host and the style are literals here; only the three numbers vary, and all
// three are re-derived as integers inside the pyramid before they are used. That
// is deliberate belt-and-braces: tileGrid already produces integers and both
// check suites assert it, but `source:` is a URL sink that fetches, and a sink
// should not depend on a caller elsewhere in the repo continuing to be careful.
//
// Anything that is not a whole number in range yields "" -- and an Image with an
// empty source fetches nothing.
//
// Provider note: CARTO, not tile.openstreetmap.org. The OSM Foundation's tile
// usage policy forbids distributing an application that draws on their servers.
var TILE_HOST = "https://basemaps.cartocdn.com"
var TILE_STYLE = "dark_all"

function tileUrl(z, x, y, key) {
  var level = Math.floor(Number(z))
  var col = Math.floor(Number(x))
  var row = Math.floor(Number(y))
  if (!isFinite(level) || level < 0 || level > MAX_TILE_ZOOM) return ""
  var span = Math.pow(2, level)
  if (!isFinite(col) || col < 0 || col >= span) return ""
  if (!isFinite(row) || row < 0 || row >= span) return ""
  var suffix = tileKey(key)
  return tileBase() + "/" + level + "/" + col + "/" + row + ".png"
       + (suffix === "" ? "" : "?key=" + suffix)
}

// The CARTO basemap key, validated, or "" if it is not one.
//
// In August 2026 CARTO began stamping an "API KEY REQUIRED" watermark across
// every unauthenticated raster tile. The tile bytes were unchanged -- their CDN
// applies the notice at the edge -- so nothing about the request was rejected
// and nothing failed; the map simply came back defaced. There is no free
// keyless raster basemap left that a distributed application may use: the OSM
// Foundation's own servers forbid it, and maps.wikimedia.org is limited to sites
// hosted by the Foundation or its affiliates.
//
// So the key is the player's own, typed into the plugin's settings, and empty by
// default. Empty means no tiles and no request at all -- the bundled Natural
// Earth outlines draw the map instead, which is what the game has always fallen
// back to offline.
//
// This is the one place the alphabet is defined, because the key reaches a URL
// from a settings field the player controls. Unreserved URL characters only:
// nothing here can start a query parameter, close the path, or open a fragment.
// The fetch helper re-checks the same alphabet on its side, since it is the side
// that actually builds the URL.
function tileKey(key) {
  // A string, and only a string. Coercing first would let 0, false, NaN and
  // Infinity through -- String(NaN) is "NaN", which is inside the alphabet below
  // and would be sent as a key. None of those is a key anyone typed, and a
  // setting that arrives as the wrong type is a bug to refuse, not to stringify.
  if (typeof key !== "string") return ""
  return /^[A-Za-z0-9._~-]{1,256}$/.test(key) ? key : ""
}

// The fixed part of a tile URL: everything up to the z/x/y.
//
// Tiles are no longer fetched by Image -- a tile is a PNG from a remote server,
// and Qt loads a PNG's whole source before sourceSize can reduce it, so the
// bytes are fetched and their header checked by a helper first. That helper
// needs the constant half of the URL, and taking it from here rather than
// repeating the host in a shell string is what keeps the two definitions from
// drifting apart. tools/check-geomath.js asserts they agree.
function tileBase() {
  return TILE_HOST + "/" + TILE_STYLE
}

// ------------------------------------------------------------- the interface

function project(view, latitude, longitude) {
  return view.mode === "globe"
    ? projectGlobe(view, latitude, longitude)
    : projectMap(view, latitude, longitude)
}

function unproject(view, x, y) {
  return view.mode === "globe"
    ? unprojectGlobe(view, x, y)
    : unprojectMap(view, x, y)
}

// ---------------------------------------------------------------- distance

// Great-circle distance in kilometres.
//
// Deliberately not QtPositioning.coordinate().distanceTo(): qt6-positioning is
// installed on the development machine but is not an Omarchy dependency, and
// importing it would make the plugin fail to load for everyone who does not
// happen to have it. Six lines of arithmetic is not worth that.
function haversineKm(lat1, lon1, lat2, lon2) {
  var dPhi = (lat2 - lat1) * DEG
  var dLambda = wrapLongitude(lon2 - lon1) * DEG
  var phi1 = lat1 * DEG
  var phi2 = lat2 * DEG

  var a = Math.sin(dPhi / 2) * Math.sin(dPhi / 2)
      + Math.cos(phi1) * Math.cos(phi2) * Math.sin(dLambda / 2) * Math.sin(dLambda / 2)
  return 2 * EARTH_RADIUS_KM * Math.asin(Math.sqrt(clamp(a, 0, 1)))
}

// ----------------------------------------------------------------- scoring

// The standard exponential falloff: 5000 for a perfect guess, halving roughly
// every 1030 km, and effectively zero once the guess is a continent away.
//
// Anchored to WORLD_SIZE_KM rather than to anything about the current view, so
// zooming in cannot inflate a score.
function scoreFor(distanceKm) {
  if (!isFinite(distanceKm) || distanceKm < 0) return 0
  var score = MAX_ROUND_SCORE * Math.exp(-10 * distanceKm / WORLD_SIZE_KM)
  return clamp(Math.round(score), 0, MAX_ROUND_SCORE)
}

// A short human phrase for a distance. Metres under a kilometre, whole
// kilometres up to 100, then thousands separated - "12,480 km" reads faster
// than "12480 km" at a glance.
function formatDistance(distanceKm) {
  if (!isFinite(distanceKm) || distanceKm < 0) return "-"
  if (distanceKm < 1) return Math.round(distanceKm * 1000) + " m"
  if (distanceKm < 100) return distanceKm.toFixed(1) + " km"
  return formatNumber(Math.round(distanceKm)) + " km"
}

function formatNumber(value) {
  var text = String(Math.round(value))
  var out = ""
  var count = 0
  for (var i = text.length - 1; i >= 0; i--) {
    out = text.charAt(i) + out
    count++
    if (count % 3 === 0 && i > 0 && text.charAt(i - 1) !== "-") out = "," + out
  }
  return out
}

// ------------------------------------------------------------ nearest place
//
// Turns the answer coordinates into "12 km from Kyoto, Japan" without a
// reverse-geocoding request. The bundled place list is already in memory for
// picking rounds, so this costs one pass over at most MAX_PLACES entries and
// no network at all.
//
// Compares squared chord distance in a locally-scaled plane rather than calling
// haversineKm 1000 times; the winner is then measured properly.
function nearestPlace(places, latitude, longitude) {
  var best = null
  var bestKey = Infinity
  var cosLat = Math.cos(latitude * DEG)

  for (var i = 0; i < places.length; i++) {
    var place = places[i]
    var dLat = place[2] - latitude
    var dLon = wrapLongitude(place[3] - longitude) * cosLat
    var key = dLat * dLat + dLon * dLon
    if (key < bestKey) {
      bestKey = key
      best = place
    }
  }

  if (!best) return null
  return {
    name: best[0],
    country: best[1],
    lat: best[2],
    lon: best[3],
    distanceKm: haversineKm(latitude, longitude, best[2], best[3])
  }
}
