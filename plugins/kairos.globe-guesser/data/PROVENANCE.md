# Bundled data provenance

Both files in this directory are generated. Nothing here is hand-written, and
nothing here is fetched at runtime — the plugin's map and globe draw entirely
from these bytes, so a machine that has been offline for a week still guesses.

## Upstream

| | |
|---|---|
| Project | [Natural Earth](https://www.naturalearthdata.com/) |
| Repository | <https://github.com/nvkelso/natural-earth-vector> |
| Commit | `ca96624a56bd078437bca8184e78163e5039ad19` |
| Licence | Public domain — see the [Natural Earth terms of use](https://www.naturalearthdata.com/about/terms-of-use/) |

The commit is a full 40-character SHA, never a branch. A branch would let the
bytes the generator produces change without the digests below changing, which
is exactly the provenance gap a reviewer cannot close by reading the diff.

## Inputs

Verified by `tools/build-world.py` before a byte of either is parsed. On a
mismatch the generator exits rather than writing.

| File | SHA-256 | Bytes |
|---|---|---|
| `geojson/ne_110m_admin_0_countries.geojson` | `6866c877d39cba9c357620878839b336d569f8c662d3cfab4cb1dbe2d39c977f` | 838726 |
| `geojson/ne_50m_populated_places.geojson` | `da4662b7bbfeb897d02f228c5839131dce27acff5717630f91ccff4f67828ee7` | 3350885 |

## Outputs

| File | SHA-256 | Bytes | Contents |
|---|---|---|---|
| `WorldOutline.js` | `c4a768154aa85fdb6095442dff63b70523aa4751ca4b6ea1b1c99233f0b95819` | 130391 | 287 rings, 10340 points |
| `Places.js` | `3d2b587974dde763ff8ca5b83cda4539f5767002f76bef8360db80ac05c5dbcd` | 43267 | 1000 places across 183 countries |

Both are comfortably under the marketplace security scanner's 512 KiB
per-file limit. Exceeding it makes the scan fail closed, and a plugin cannot be
approved without a complete scan result.

## Reproducing

```sh
tools/build-world.py --check
```

Re-derives both outputs from the pinned inputs and compares them against the
files on disk. Exit status is 0 only when every digest matches. `--check` never
writes.

To regenerate after changing a ceiling or the simplification threshold:

```sh
tools/build-world.py
```

Then update the Outputs table above with the digests it prints.

## Derivation

**`WorldOutline.js`** — every `Polygon`/`MultiPolygon` ring from the countries
file, flattened to `[lon, lat, lon, lat, …]`, coordinates rounded to two decimal
places (~1.1 km at the equator, well under a pixel at world scale), points within
0.25° of the previously kept point collapsed, and rings left with fewer than 4
points dropped. The final point of each ring is always kept so a closed coastline
stays closed rather than leaving a seam.

The 50m outline set was evaluated and rejected: even simplified at 0.4° it is
310 KB and 24639 points, 2.4× the per-frame drawing work for detail that is
invisible at the only scale this data is ever drawn at.

**`Places.js`** — the 1000 most populous places by `POP_MAX`, as
`[name, country, lat, lon]`. Sorted by population descending and then by name, so
ties break deterministically and the difficulty tiers do not shift when the file
is regenerated. Index position *is* the tier: easy draws from the first 150,
normal from the first 500, hard from all 1000.

## Ceilings

`MAX_RINGS` (400), `MAX_POINTS` (16000) and `MAX_PLACES` (1000) are enforced in
the generator **and** re-checked when the shell loads each file. A cap that only
exists in the generator is a cap the running shell does not have — the shell
loads whatever bytes are on disk, not whatever the generator intended to write.
