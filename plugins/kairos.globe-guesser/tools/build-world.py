#!/usr/bin/env python3
"""Derive the plugin's two bundled data files from Natural Earth.

    tools/build-world.py            download, derive, write data/*.js
    tools/build-world.py --check    derive into memory, compare against the
                                    digests recorded in data/PROVENANCE.md

Both inputs are fetched at a full 40-character commit, never a branch. A branch
would let the bytes this script produces change without the digests below
changing, which is precisely the provenance gap the marketplace rejects
submissions for. Every input digest is verified before a byte of it is parsed,
and the script refuses to write on a mismatch.

Two ceilings are enforced here AND re-checked when the shell loads the result
(GlobeMap.qml and Panel.qml). A cap that only exists in the generator is a cap
the running shell does not have.
"""

import argparse
import hashlib
import json
import os
import sys
import time
import urllib.request
from pathlib import Path

# ---------------------------------------------------------------- provenance

UPSTREAM = "https://github.com/nvkelso/natural-earth-vector"
COMMIT = "ca96624a56bd078437bca8184e78163e5039ad19"
LICENCE = "Public domain (Natural Earth terms of use)"

INPUTS = {
    "ne_110m_admin_0_countries.geojson":
        "6866c877d39cba9c357620878839b336d569f8c662d3cfab4cb1dbe2d39c977f",
    "ne_50m_populated_places.geojson":
        "da4662b7bbfeb897d02f228c5839131dce27acff5717630f91ccff4f67828ee7",
}

RAW = "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/%s/geojson/%s"

# ------------------------------------------------------------------ ceilings
#
# MAX_RINGS / MAX_POINTS bound what the shell can be made to draw per frame.
# MAX_PLACES bounds the city list. All three are re-checked at load.

MAX_RINGS = 400
MAX_POINTS = 16000
MAX_PLACES = 1000

# Points closer together than this (in degrees, Manhattan) collapse into one.
# 0.25 deg is roughly a third of a pixel on a 1400px-wide world map, so the
# simplification is invisible at the only scale this data is drawn at.
SIMPLIFY_DEG = 0.25

# Rings smaller than this after simplification are dropped: at world scale they
# are a single pixel, and there are hundreds of them.
MIN_RING_POINTS = 4

# Difficulty tiers, by population rank. Easy draws only from the first 150
# cities, normal from the first 500, hard from all of them.
TIER_EASY = 150
TIER_NORMAL = 500

CACHE = Path(os.environ.get("XDG_CACHE_HOME")
                 or (Path.home() / ".cache")) / "omarchy-globe-guesser-build"


# Natural Earth's GeoJSON runs to 3.4 MB; 64 MB is nearly twenty times the
# largest input and still a hard bound.
MAX_INPUT_BYTES = 64 * 1024 * 1024

# Wall clock for the whole body, not a socket timeout.
BODY_DEADLINE_SEC = 180


def _read_bounded(url: str) -> bytes:
    """Fetch one input under a byte ceiling and a wall-clock deadline.

    urlopen's `timeout=` is a SOCKET timeout: it resets on every byte, so a
    server dripping one byte every 50ms never goes idle and holds the connection
    open forever. The deadline here is monotonic and bounds the whole body.

    The byte ceiling is separate, because a timeout bounds duration and not
    bytes -- at line rate three minutes is a great deal of memory. Reaching the
    ceiling fails closed rather than returning a truncated file, which would
    then be measured against the digest and produce a confusing mismatch instead
    of a clear refusal.

    This is build-time code and never ships in the running plugin, but it is in
    the reviewed snapshot and the same rules are the right ones.
    """
    deadline = time.monotonic() + BODY_DEADLINE_SEC
    chunks: list[bytes] = []
    total = 0
    with urllib.request.urlopen(url, timeout=30) as response:
        while True:
            if time.monotonic() > deadline:
                raise SystemExit(f"body deadline exceeded fetching {url}")
            chunk = response.read(65536)
            if not chunk:
                break
            total += len(chunk)
            if total > MAX_INPUT_BYTES:
                raise SystemExit(f"input exceeded {MAX_INPUT_BYTES} bytes: {url}")
            chunks.append(chunk)
    return b"".join(chunks)


def fetch(name: str) -> bytes:
    """Return the verified bytes of one upstream input.

    The digest is checked against INPUTS before the bytes are returned, so a
    caller can never parse something that was not the reviewed input.
    """
    CACHE.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = CACHE / f"{COMMIT}-{name}"
    if path.exists():
        raw = path.read_bytes()
    else:
        url = RAW % (COMMIT, name)
        print(f"  fetching {name} at {COMMIT[:12]}...", file=sys.stderr)
        raw = _read_bounded(url)
        path.write_bytes(raw)

    got = hashlib.sha256(raw).hexdigest()
    if got != INPUTS[name]:
        raise SystemExit(
            f"digest mismatch for {name}\n  expected {INPUTS[name]}\n  got      {got}\n"
            f"Refusing to build. Delete {path} and retry, or the upstream commit moved."
        )
    return raw


def rings_from(geometry) -> list:
    """Flatten a GeoJSON Polygon or MultiPolygon into a list of coordinate rings."""
    kind = geometry["type"]
    coordinates = geometry["coordinates"]
    polygons = [coordinates] if kind == "Polygon" else coordinates
    out = []
    for polygon in polygons:
        for ring in polygon:
            out.append(ring)
    return out


def simplify(ring: list) -> list:
    """Drop points that sit within SIMPLIFY_DEG of the previous kept point.

    The last point is always kept so a closed ring stays closed; without it a
    coastline can end a pixel short of where it started and leave a seam.
    """
    kept = [ring[0]]
    for point in ring[1:]:
        previous = kept[-1]
        if abs(point[0] - previous[0]) + abs(point[1] - previous[1]) >= SIMPLIFY_DEG:
            kept.append(point)
    if kept[-1] != ring[-1]:
        kept.append(ring[-1])
    return kept


def build_outline(raw: bytes) -> tuple:
    """Return (js_source, ring_count, point_count) for the country outlines."""
    collection = json.loads(raw)
    out = []
    for feature in collection["features"]:
        for ring in rings_from(feature["geometry"]):
            kept = simplify(ring)
            if len(kept) < MIN_RING_POINTS:
                continue
            flat = []
            for longitude, latitude in kept:
                # Two decimal places is ~1.1 km at the equator, well under a
                # pixel at world scale, and it halves the file.
                flat.append(round(longitude, 2))
                flat.append(round(latitude, 2))
            out.append(flat)

    if len(out) > MAX_RINGS:
        raise SystemExit(f"ring count {len(out)} exceeds MAX_RINGS {MAX_RINGS}")
    points = sum(len(ring) for ring in out) // 2
    if points > MAX_POINTS:
        raise SystemExit(f"point count {points} exceeds MAX_POINTS {MAX_POINTS}")

    # One ring per line, so a diff of a regenerated file stays readable.
    body = ",\n  ".join(json.dumps(ring, separators=(",", ":")) for ring in out)

    source = f"""// GENERATED FILE - do not edit by hand.
//
// Rebuild:   tools/build-world.py
// Verify:    tools/build-world.py --check
//
// Source:    {UPSTREAM}
//            geojson/ne_110m_admin_0_countries.geojson
// Commit:    {COMMIT}
// Licence:   {LICENCE}
//
// Country and coastline outlines, flattened to [lon, lat, lon, lat, ...] per
// ring at two decimal places, simplified at {SIMPLIFY_DEG} degrees, rings under
// {MIN_RING_POINTS} points dropped.
//
// Ceilings, re-checked at load in GlobeMap.qml because a cap that only exists
// in the generator is a cap the running shell does not have:
//   MAX_RINGS  {MAX_RINGS}
//   MAX_POINTS {MAX_POINTS}
//
// This file contains {len(out)} rings and {points} points.

.pragma library

var MAX_RINGS = {MAX_RINGS}
var MAX_POINTS = {MAX_POINTS}

var RINGS = [
  {body}
]
"""
    return source, len(out), points


def build_places(raw: bytes) -> tuple:
    """Return (js_source, place_count, country_count) for the city list."""
    collection = json.loads(raw)
    rows = []
    for feature in collection["features"]:
        properties = feature["properties"]
        longitude, latitude = feature["geometry"]["coordinates"]
        name = properties.get("NAME")
        country = properties.get("ADM0NAME")
        if not name or not country:
            continue
        population = properties.get("POP_MAX") or 0
        rows.append((int(population), str(name), str(country),
                     round(float(latitude), 4), round(float(longitude), 4)))

    # Sort by population descending, then by name so the ordering - and
    # therefore the difficulty tiers - is stable across regenerations rather
    # than depending on the input's file order for ties.
    rows.sort(key=lambda row: (-row[0], row[1]))
    rows = rows[:MAX_PLACES]

    if len(rows) > MAX_PLACES:
        raise SystemExit(f"place count {len(rows)} exceeds MAX_PLACES {MAX_PLACES}")

    entries = []
    for population, name, country, latitude, longitude in rows:
        entries.append(json.dumps([name, country, latitude, longitude],
                                  separators=(",", ":"), ensure_ascii=False))
    body = ",\n  ".join(entries)
    countries = len({row[2] for row in rows})

    source = f"""// GENERATED FILE - do not edit by hand.
//
// Rebuild:   tools/build-world.py
// Verify:    tools/build-world.py --check
//
// Source:    {UPSTREAM}
//            geojson/ne_50m_populated_places.geojson
// Commit:    {COMMIT}
// Licence:   {LICENCE}
//
// The {MAX_PLACES} most populous places, as [name, country, lat, lon], ordered
// by population descending and then by name so the ordering is stable across
// regenerations. Index position is the difficulty tier: a game draws from the
// first {TIER_EASY} on easy, the first {TIER_NORMAL} on normal, and all of them
// on hard.
//
// Ceiling, re-checked at load in Panel.qml:
//   MAX_PLACES {MAX_PLACES}
//
// This file contains {len(rows)} places across {countries} countries.

.pragma library

var MAX_PLACES = {MAX_PLACES}
var TIER_EASY = {TIER_EASY}
var TIER_NORMAL = {TIER_NORMAL}

var PLACES = [
  {body}
]
"""
    return source, len(rows), countries


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="derive and compare against the files on disk without writing")
    args = parser.parse_args()

    root = Path(__file__).resolve().parent.parent
    data = root / "data"

    outline_source, rings, points = build_outline(fetch("ne_110m_admin_0_countries.geojson"))
    places_source, places, countries = build_places(fetch("ne_50m_populated_places.geojson"))

    outputs = {
        data / "WorldOutline.js": outline_source,
        data / "Places.js": places_source,
    }

    failed = False
    for path, source in outputs.items():
        encoded = source.encode("utf-8")
        digest = hashlib.sha256(encoded).hexdigest()
        if args.check:
            if not path.exists():
                print(f"MISSING  {path.name}")
                failed = True
                continue
            on_disk = hashlib.sha256(path.read_bytes()).hexdigest()
            status = "OK      " if on_disk == digest else "MISMATCH"
            if on_disk != digest:
                failed = True
            print(f"{status} {path.name}  {digest}")
        else:
            data.mkdir(parents=True, exist_ok=True)
            path.write_bytes(encoded)
            print(f"wrote {path.name}  {len(encoded)} bytes  sha256 {digest}")

    print(f"outlines: {rings} rings, {points} points "
          f"(ceilings {MAX_RINGS} / {MAX_POINTS})", file=sys.stderr)
    print(f"places:   {places} across {countries} countries "
          f"(ceiling {MAX_PLACES})", file=sys.stderr)

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
