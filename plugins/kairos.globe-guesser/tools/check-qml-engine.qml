// Confirms GeoMath.js, Sanitise.js and the two generated data files load and
// behave correctly under Qt's V4 engine -- the one that actually runs inside
// omarchy-shell.
//
// tools/check-geomath.js proves the same properties under Node. V4 is a
// different engine with a different JavaScript subset, and "it worked in Node"
// has never been evidence about the shell. This file closes that gap: same
// libraries, same expectations, V4 doing the arithmetic and running the regexes.
//
// Run it with:
//
//     tools/run-checks.sh
//
// The result is communicated through the exit code rather than console output,
// because Qt's `qml` runner suppresses console messages on some builds -- and an
// assertion that fails loudly is worth more than a number nobody reads. Exit 0
// means every check passed; any other value is the number of the first check
// that did not.

import QtQuick
import "../GeoMath.js" as GeoMath
import "../Sanitise.js" as Sanitise
import "../data/WorldOutline.js" as WorldOutline
import "../data/Places.js" as Places

QtObject {
  function fail(code) {
    Qt.exit(code)
    return false
  }

  Component.onCompleted: {
    // 1-9: the bundled data loaded, completely, and inside its own ceilings.
    if (!WorldOutline.RINGS || WorldOutline.RINGS.length === 0) return fail(1)
    if (WorldOutline.RINGS.length > WorldOutline.MAX_RINGS) return fail(2)
    var points = 0
    for (var r = 0; r < WorldOutline.RINGS.length; r++) points += WorldOutline.RINGS[r].length / 2
    if (points > WorldOutline.MAX_POINTS) return fail(3)
    if (!Places.PLACES || Places.PLACES.length === 0) return fail(4)
    if (Places.PLACES.length > Places.MAX_PLACES) return fail(5)
    if (Places.TIER_EASY > Places.TIER_NORMAL) return fail(6)
    if (Places.TIER_NORMAL > Places.PLACES.length) return fail(7)

    // 8: every place is a well-formed coordinate. A single bad row would put a
    // round somewhere that is not on Earth.
    for (var p = 0; p < Places.PLACES.length; p++) {
      var place = Places.PLACES[p]
      if (place.length !== 4) return fail(8)
      if (!isFinite(place[2]) || Math.abs(place[2]) > 90) return fail(8)
      if (!isFinite(place[3]) || Math.abs(place[3]) > 180) return fail(8)
    }

    // 10-19: projections round-trip under V4.
    var modes = ["map", "globe"]
    var zooms = [1, 1.7, 4, 12]
    var centres = [[0, 0], [45, -120], [-33.9, 151.2], [89, 180], [0, 179.5]]
    var samples = [[0, 0], [51.5074, -0.1278], [35.687, 139.7495], [-33.87, 151.21],
                   [90, 0], [-90, 0], [0, 180], [0, -180], [64.14, -21.9]]

    for (var m = 0; m < modes.length; m++) {
      for (var z = 0; z < zooms.length; z++) {
        for (var c = 0; c < centres.length; c++) {
          var view = { mode: modes[m], width: 900, height: 520, zoom: zooms[z],
                       centreLat: centres[c][0], centreLon: centres[c][1] }
          for (var s = 0; s < samples.length; s++) {
            var projected = GeoMath.project(view, samples[s][0], samples[s][1])
            if (!isFinite(projected.x) || !isFinite(projected.y)) return fail(10)
            if (!projected.visible) continue
            // Mercator sends the poles to infinity and is cut off at 85.05
            // degrees instead, so a point beyond that is clamped on the way out
            // and cannot come back as itself. That is the projection working.
            if (modes[m] === "map" && Math.abs(samples[s][0]) > GeoMath.MERCATOR_MAX_LAT) continue
            if (projected.x < 0 || projected.x > view.width) continue
            if (projected.y < 0 || projected.y > view.height) continue
            var back = GeoMath.unproject(view, projected.x, projected.y)
            if (!back) return fail(11)
            if (GeoMath.haversineKm(samples[s][0], samples[s][1], back.lat, back.lon) > 1.0)
              return fail(12)
          }
        }
      }
    }

    // 13: the back of the globe reports itself hidden. Without this the far
    // hemisphere paints mirrored over the near one.
    var globe = { mode: "globe", width: 900, height: 520, zoom: 1, centreLat: 0, centreLon: 0 }
    if (GeoMath.project(globe, 0, 180).visible) return fail(13)
    if (!GeoMath.project(globe, 0, 0).visible) return fail(13)

    // 14: a click outside the disc is not a guess.
    if (GeoMath.unproject(globe, 0, 0) !== null) return fail(14)
    var radius = GeoMath.globeRadius(globe)
    if (GeoMath.unproject(globe, 450 + radius * 1.02, 260) !== null) return fail(14)
    if (GeoMath.unproject(globe, 450 + radius * 0.98, 260) === null) return fail(14)

    // 15: and the limb itself still is one. This is the case an exact
    // comparison gets wrong: 90 degrees from centre lands a few ULPs outside
    // the radius it should equal.
    var limb = GeoMath.project(globe, 0, 90)
    if (!limb.visible) return fail(15)
    if (GeoMath.unproject(globe, limb.x, limb.y) === null) return fail(15)

    // 16: past the edge of the sheet is not a guess either -- neither above the
    // top of the world nor out in the background beside it.
    var flat = { mode: "map", width: 900, height: 520, zoom: 1, centreLat: 80, centreLon: 0 }
    if (GeoMath.unproject(flat, 450, -400) !== null) return fail(16)
    var wide = { mode: "map", width: 940, height: 330, zoom: 1, centreLat: 0, centreLon: 0 }
    if (GeoMath.unproject(wide, 10, 165) !== null) return fail(16)
    if (GeoMath.unproject(wide, 930, 165) !== null) return fail(16)
    if (GeoMath.unproject(wide, 470, 165) === null) return fail(16)

    // 17: Mercator, which the flat map and every tile are cut to. Checked here
    // as well as under Node because sinh is hand-rolled -- V4 cannot be relied
    // on to provide Math.sinh -- and because Math.log and Math.LN2 decide which
    // level of the tile pyramid gets asked for.
    if (Math.abs(GeoMath.latToWorldY(0) - 0.5) > 1e-12) return fail(17)
    if (Math.abs(GeoMath.lonToWorldX(0) - 0.5) > 1e-12) return fail(17)
    if (Math.abs(GeoMath.latToWorldY(GeoMath.MERCATOR_MAX_LAT)) > 1e-9) return fail(17)
    if (Math.abs(GeoMath.latToWorldY(-GeoMath.MERCATOR_MAX_LAT) - 1) > 1e-9) return fail(17)
    for (var ml = -85; ml <= 85; ml += 5) {
      if (Math.abs(GeoMath.worldYToLat(GeoMath.latToWorldY(ml)) - ml) > 1e-9) return fail(17)
    }
    for (var sx = -3; sx <= 3; sx += 1) {
      if (Math.abs(GeoMath.sinh(sx) - (Math.exp(sx) - Math.exp(-sx)) / 2) > 1e-12) return fail(18)
    }

    // 19: the tile grid. Every index must be an integer inside the pyramid, and
    // every tile's own corner must land where the projection puts that corner's
    // coordinate -- that identity is the only thing keeping the tiles and the
    // pin from drifting apart, and a guess is only as accurate as it holds.
    var mapView = { mode: "map", width: 940, height: 330, zoom: 1, centreLat: 0, centreLon: 0 }
    var grid = GeoMath.tileGrid(mapView, 64)
    if (!grid || grid.length === 0 || grid.length > 64) return fail(19)
    for (var t = 0; t < grid.length; t++) {
      var tile = grid[t]
      var span = Math.pow(2, tile.z)
      if (tile.z !== Math.floor(tile.z) || tile.z < 0 || tile.z > 19) return fail(19)
      if (tile.x !== Math.floor(tile.x) || tile.x < 0 || tile.x >= span) return fail(19)
      if (tile.y !== Math.floor(tile.y) || tile.y < 0 || tile.y >= span) return fail(19)
      if (!isFinite(tile.sx) || !isFinite(tile.sy) || !(tile.size > 0)) return fail(19)
      var corner = GeoMath.project(mapView,
          GeoMath.worldYToLat(tile.y / span), GeoMath.worldXToLon(tile.x / span))
      if (Math.abs(corner.x - tile.sx) > 0.001) return fail(19)
      if (Math.abs(corner.y - tile.sy) > 0.001) return fail(19)
    }
    if (GeoMath.tileGrid(mapView, 3).length > 3) return fail(19)

    // 19b: the two guards standing in front of Image.source. Checked under V4
    // as well as Node because both are regex- and Number()-driven, and V4 is the
    // engine that actually decides whether the shell fetches something.
    if (GeoMath.tileUrl(5, 16, 10) !== "https://basemaps.cartocdn.com/dark_all/5/16/10.png")
      return fail(190)
    if (GeoMath.tileUrl(-1, 0, 0) !== "") return fail(191)
    if (GeoMath.tileUrl(20, 0, 0) !== "") return fail(191)
    if (GeoMath.tileUrl(5, 32, 0) !== "") return fail(191)
    if (GeoMath.tileUrl(5, 0, 32) !== "") return fail(191)
    if (GeoMath.tileUrl(NaN, 0, 0) !== "") return fail(192)
    if (GeoMath.tileUrl(5, "0/../../evil", 0) !== "") return fail(192)
    if (GeoMath.tileUrl(5, 16, 10).indexOf("..") >= 0) return fail(192)

    // 19c: tileBase, and that it still agrees with tileUrl. The fetch helper is
    // handed the base and rebuilds the rest from the three numbers, so a host
    // changed in one place and not the other would send the shell somewhere the
    // check suites never looked. Also that a "z-x-y" name splits back to the
    // numbers it was built from, which is the same round trip the shell does.
    if (GeoMath.tileBase() !== "https://basemaps.cartocdn.com/dark_all") return fail(195)
    if (GeoMath.tileBase().indexOf("https://") !== 0) return fail(195)
    for (var tb = 0; tb < 3; tb++) {
      var tz = [1, 5, 19][tb], tx = [1, 16, 300][tb], ty = [0, 10, 400][tb]
      if (GeoMath.tileUrl(tz, tx, ty)
          !== GeoMath.tileBase() + "/" + tz + "/" + tx + "/" + ty + ".png") return fail(196)
      var nm = tz + "-" + tx + "-" + ty
      if (!/^[0-9]+-[0-9]+-[0-9]+$/.test(nm)) return fail(197)
      var pieces = nm.split("-")
      if (pieces.length !== 3) return fail(197)
      if (Number(pieces[0]) !== tz || Number(pieces[1]) !== tx
          || Number(pieces[2]) !== ty) return fail(197)
    }

    // 19d: tileKey. The one value a PLAYER types that reaches a URL, so it is
    // checked under V4 too -- V4 is the engine that decides what the shell
    // actually fetches, and this guard is a regex and a typeof.
    if (GeoMath.tileKey("aB3-x_y.z~") !== "aB3-x_y.z~") return fail(198)
    var badKeys = ["", " ", "a b", "k&style=dark", "k?z=1", "k#frag", "a/b",
                   "../../etc/passwd", "k=x", "k;x", "k|x", "k%26x", "k+x"]
    for (var bk = 0; bk < badKeys.length; bk++) {
      if (GeoMath.tileKey(badKeys[bk]) !== "") return fail(198)
    }
    // Non-strings, which coercion would otherwise turn into usable keys.
    var badTypes = [NaN, Infinity, 0, false, null, undefined, {}, []]
    for (var bt = 0; bt < badTypes.length; bt++) {
      if (GeoMath.tileKey(badTypes[bt]) !== "") return fail(198)
    }
    if (GeoMath.tileKey(new Array(258).join("x")) !== "") return fail(198)

    // A refused key must leave the url unkeyed rather than injecting it, and a
    // good one must compose exactly as the fetch helper rebuilds it.
    if (GeoMath.tileUrl(5, 16, 10, "k&evil=1")
        !== "https://basemaps.cartocdn.com/dark_all/5/16/10.png") return fail(199)
    if (GeoMath.tileUrl(5, 16, 10, "aB3-x_y.z~")
        !== GeoMath.tileBase() + "/5/16/10.png?key=aB3-x_y.z~") return fail(199)

    if (Sanitise.localFileUrl("/run/user/1000/omarchy-globe-guesser/photo.aB3xY9zQ")
        !== "file:///run/user/1000/omarchy-globe-guesser/photo.aB3xY9zQ") return fail(193)
    if (Sanitise.localFileUrl("image://provider/x") !== "") return fail(194)
    if (Sanitise.localFileUrl("http://example.invalid/x.png") !== "") return fail(194)
    if (Sanitise.localFileUrl("file:///etc/passwd") !== "") return fail(194)
    if (Sanitise.localFileUrl("relative/x.jpg") !== "") return fail(194)
    if (Sanitise.localFileUrl("/a/../../etc/passwd") !== "") return fail(194)
    if (Sanitise.localFileUrl("/x" + String.fromCharCode(10) + "/y") !== "") return fail(194)
    if (Sanitise.localFileUrl("") !== "") return fail(194)
    if (Sanitise.localFileUrl(null) !== "") return fail(194)

    // 20-29: distance and scoring.
    if (Math.abs(GeoMath.haversineKm(0, 0, 0, 0)) > 1e-9) return fail(20)
    if (Math.abs(GeoMath.haversineKm(51.5074, -0.1278, 40.7128, -74.006) - 5570) > 15) return fail(21)
    // Across the antimeridian two neighbours must not read as half a planet.
    if (Math.abs(GeoMath.haversineKm(0, 179.5, 0, -179.5) - 111.2) > 1) return fail(22)
    if (GeoMath.scoreFor(0) !== 5000) return fail(23)
    if (GeoMath.scoreFor(-1) !== 0) return fail(24)
    if (GeoMath.scoreFor(NaN) !== 0) return fail(25)
    if (GeoMath.scoreFor(20000) > 5) return fail(26)
    for (var km = 0; km < 20000; km += 500) {
      if (GeoMath.scoreFor(km) < GeoMath.scoreFor(km + 500)) return fail(27)
      if (GeoMath.scoreFor(km) < 0 || GeoMath.scoreFor(km) > 5000) return fail(28)
    }
    if (GeoMath.formatNumber(25000) !== "25,000") return fail(29)

    // 30: nearest place, against the real bundled list.
    var near = GeoMath.nearestPlace(Places.PLACES, 35.02, 135.77)
    if (!near || near.distanceKm > 40) return fail(30)

    // 40-49: sanitising, under V4's regex engine rather than Node's. These are
    // the payloads marketplace reviewers use, pushed through every ingest helper
    // and through the boundary helper the bar label and tooltip actually use.
    var NUL = String.fromCharCode(0)
    var LF = String.fromCharCode(10)
    var payloads = [
      '<img src="http://127.0.0.1:1/x.png" width="300" height="40">',
      '<img' + LF + 'src=x onerror=alert(1)>',
      '&lt;img src="http://example.invalid/x.png"&gt;',
      '&#60;img src=x&#62;',
      '<!DOCTYPE html><html><body>',
      '<script>fetch("http://example.invalid")</scr' + 'ipt>',
      '<a href="//commons.wikimedia.org/wiki/User:Someone">Someone</a>',
      'line one' + LF + 'line two' + NUL
    ]

    for (var i = 0; i < payloads.length; i++) {
      var outputs = [
        Sanitise.plainOneLine(payloads[i], 200),
        Sanitise.creditText(payloads[i], 120),
        Sanitise.titleText(payloads[i], 90),
        Sanitise.licenceText(payloads[i]),
        // The boundary: whatever an ingest helper produced, wrapped again on
        // the way out, which is how label and tooltip are built.
        Sanitise.plainOneLine(Sanitise.creditText(payloads[i], 120), 200)
      ]
      for (var o = 0; o < outputs.length; o++) {
        if (outputs[o].indexOf("<") >= 0) return fail(40)
        if (outputs[o].indexOf(">") >= 0) return fail(41)
        if (outputs[o].indexOf("&") >= 0) return fail(42)
        if (/[\x00-\x1f\x7f]/.test(outputs[o])) return fail(43)
        if (outputs[o].length > 201) return fail(44)
      }
    }

    // 45-49: and real data still renders.
    if (Sanitise.plainOneLine("Quebec City, Canada", 80) !== "Quebec City, Canada") return fail(45)
    if (Sanitise.creditText('<a href="#">Cedric Bonhomme</a>', 120) !== "Cedric Bonhomme") return fail(46)
    if (Sanitise.titleText("File:Kyoto_City_Government_-_panoramio.jpg", 90)
        !== "Kyoto City Government - panoramio") return fail(47)
    if (Sanitise.licenceText("CC BY-SA 4.0") !== "CC BY-SA 4.0") return fail(48)
    if (Sanitise.plainOneLine(null, 80) !== "") return fail(49)

    // 50: the URL allowlist, which is the only gate between an API response and
    // curl's argv. Kept in step with the copy in Panel.qml by hand; if that one
    // changes, this must too.
    var allowed = /^https:\/\/upload\.wikimedia\.org\/wikipedia\/commons\/[A-Za-z0-9._~:\/?#\[\]@!$&'()*+,;=%-]{1,700}$/
    if (!allowed.test("https://upload.wikimedia.org/wikipedia/commons/thumb/d/d4/A.jpg/1280px-A.jpg"))
      return fail(50)
    if (allowed.test("https://evil.invalid/wikipedia/commons/x.jpg")) return fail(51)
    if (allowed.test("http://upload.wikimedia.org/wikipedia/commons/x.jpg")) return fail(52)
    if (allowed.test("https://upload.wikimedia.org.evil.invalid/wikipedia/commons/x.jpg")) return fail(53)
    if (allowed.test("https://upload.wikimedia.org/wikipedia/commons/x.jpg" + LF + "-o/etc/passwd"))
      return fail(54)
    if (allowed.test("-https://upload.wikimedia.org/wikipedia/commons/x.jpg")) return fail(55)
    if (allowed.test("https://upload.wikimedia.org/wikipedia/other/x.jpg")) return fail(56)

    Qt.exit(0)
  }
}
