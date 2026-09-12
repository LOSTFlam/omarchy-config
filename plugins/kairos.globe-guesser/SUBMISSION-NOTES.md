# Submission notes

Prepared against `scripts/preflight.sh` from the `omarchy-plugin` skill and the
findings catalogue in `references/review-findings.md`. Five preflight areas
report hits; each is accounted for below. Nothing is a pattern-scanner false
positive that was ignored — where the scanner was right, the code changed.

## Suggested listing metadata

- **Category:** Other
- **Tags:** quickshell, bar

## Preflight area 1 — text crossing into shell-owned AutoText sinks

Confirmed on this system rather than assumed. Exactly **one** `textFormat`
assignment exists in the whole of omarchy-shell:

```
/usr/share/omarchy/shell/plugins/notifications/components/NotificationCard.qml:177
```

so both sinks a bar widget writes to are `Text.AutoText`:

| Assigned by this plugin | Rendered by |
|---|---|
| `WidgetButton.text` | `Ui/WidgetButton.qml:75-92` — no `textFormat` |
| `WidgetButton.tooltipText` | `plugins/bar/Bar.qml:1091-1100` — no `textFormat` |

A plugin cannot set a property on a `Text` it does not own, so the string is
made safe before it crosses. Three layers:

1. **Every `Text` the plugin owns pins `Text.PlainText`** — all of them, not only
   the ones carrying remote data today, so the safe default also covers whatever
   the next edit adds.
2. **At parse**, as values enter (`Panel.qml`, `parseCandidates`). Commons
   returns `extmetadata.Artist` as *literal HTML by design* — a measured live
   value was `<a href="//commons.wikimedia.org/wiki/User:Cedricbonhomme" …>` —
   so `Sanitise.creditText` unwraps tags to their text content rather than
   deleting them, decodes entities, and only then strips. Licence short-names go
   through a `[A-Za-z0-9 .+-]` whitelist, which is safe because "CC BY-SA 4.0"
   and "CC0" are the whole universe of real values. File titles keep their
   characters and lose only the markup-significant ones, because "Québec" and
   "Marrakesh" are real data a narrow whitelist would destroy.
3. **At the boundary**, `Sanitise.plainOneLine` wraps the exported `label` and
   `tooltip` **wholesale** rather than field by field, so a part added to either
   later is covered without another edit.

The two lines preflight still reports are `Ui/Button.text` assignments whose
values are plugin-authored string constants:

```
Panel.qml:1199   text: root.phase === "error" ? "Try another" : "Skip"
Panel.qml:1226   text: root.phase === "idle" ? "Start" : "Play again"
```

Neither can carry upstream data on any path.

**Evidence.** `tools/check-geomath.js` and `tools/check-qml-engine.qml` push
`<img src="http://…" width="300" height="40">`, `<img\nsrc=x>`, `&lt;img…`,
`&#60;img…`, `<!DOCTYPE`, `<script>`, a `<a href>` credit, control characters
and 500 stacked `<` through **every** ingest helper *and* through the boundary
helper, asserting no `<`, `>`, `&` or control character survives and that the
output stays bounded. They also assert real data still renders: `Québec City,
Canada` intact, `D-AIGW` keeps its hyphen, `<a href="#">Cedric Bonhomme</a>`
becomes `Cedric Bonhomme`. Both suites run under Node **and** under Qt's V4
engine, because V4 is the engine the shell actually runs and "it worked in Node"
is not evidence about the shell.

Live confirmation: a real round rendered the credit `Andrew Bossi · CC BY-SA 2.5`
from a raw Commons `Artist` field that was an anchor tag.

## Preflight area 2 — `StdioCollector`

Four instances, every one producer-bounded. `StdioCollector` retains the whole of
stdout before any signal fires, so the ceiling is upstream of it in all four:

| Process | Producer bound |
|---|---|
| `wikiProcess` | `cappedCurl()` → `curl … \| head -c $((CAP+1))`, CAP 256 KiB |
| `attrProcess` | same helper, CAP 32 KiB |
| `stateReader` | the command *is* `head -c $((CAP+1))`, CAP 64 KiB |
| `dirProcess` | `printf %s "$d" \| head -c 4097` |
| `photoProcess` | `printf %s "$t" \| head -c 4097`; the photo itself never reaches stdout — `curl --max-filesize 6000000` writes it to a file |

The `parseCappedJson` length check is a secondary guard only, and says so in the
source: `String.length` counts UTF-16 units, not bytes, and `head -c` is the
bound that actually holds.

Collections are capped independently of bytes: candidate photos are sliced to 40
during parsing (`gslimit=60` is a request, not a guarantee), and the per-round
results array is sliced to 10.

## Preflight area 3 — `FileView`

One hit, and it is a **comment explaining why `FileView` is not used**
(`Panel.qml:289`). The plugin contains no `FileView`. State is read through
`Process { command: ["timeout", …, "head", "-c", String(cap + 1), "--", path] }`
precisely because `FileView` exposes no bounded read.

## Preflight area 4 — `head -c` without the `+1`

**The scanner was right once and the code changed.** An earlier revision bounded
the two path-emitting helpers at `head -c 4096`. A path cut off at exactly 4096
bytes still matches the shape check that follows it, so that bound would have
handed back a valid-looking directory or filename that was not the one the
script created. Both now emit `cap+1` and the reading side rejects any reply that
reaches the ceiling:

```qml
if (path.length > root.pathCapBytes) path = ""
```

The one remaining hit is `head -c 65537` on the cache-prune pipeline, which *is*
cap+1 for a 65536-byte ceiling — the pattern cannot tell 65537 from a round
number. That pipeline feeds a delete loop rather than a parser, so there is no
prefix for anything to accept; the bound is there so "this directory only ever
holds a handful of files" stays true by construction rather than by assumption.

## Preflight area 5 — `mktemp` and `chmod` (reported as "shared /tmp" and "fixed path")

The plugin **never** uses `/tmp` or `/var/tmp`, not even as a last-resort
fallback. Photos go to `$XDG_RUNTIME_DIR/omarchy-globe-guesser`
(`/run/user/<uid>`, mode 0700, owned by the user, cleared at logout), falling
back to `$HOME/.cache/omarchy-globe-guesser`. With neither available,
`cacheDir` is `""`, `startGame()` refuses to start and the panel says why. It is
a game; failing closed costs nothing worth a foothold.

Every directory is created private and then verified, with the path passed as an
**argument** and never spliced into the script text:

```sh
mkdir -m 700 -p -- "$d" 2>/dev/null || continue
[ -d "$d" ] && [ ! -L "$d" ] && [ -O "$d" ] || continue
```

The `chmod 600` hits are not on a fixed path. Both apply to a file `mktemp` has
just created inside a directory re-verified as a non-symlink owned by us in the
same script invocation, so the name cannot be guessed or pre-created. The state
file is written to a `mktemp` name and `mv -f`'d into place — never a
predictable `.tmp` sibling.

**Evidence.** With the state path replaced by a symlink pointing at a sentinel
file, a completed game replaced the *symlink* with a fresh 0600 regular file and
left the sentinel's contents untouched. A 10 MB junk file and a truncated JSON
file at the state path both fell back to defaults without writing through
anything.

## TOCTOU

There is no stat-then-open anywhere, and one place that used to be close was
rewritten to remove the shape.

The photograph's size is now counted **by the pipeline that writes it**:

```sh
size=$(curl … | head -c $((CAP+1)) | tee "$t" | wc -c)
```

`wc` counts exactly the bytes `tee` wrote. An earlier revision wrote the file and
then asked the filesystem how big it was, which is a check followed by a separate
open — the shape that lets a file be replaced between the two. A first attempt at
fixing it routed the count through a `"$d/.size"` file, which swapped one defect
for a worse one: a *predictable* filename in the cache directory. The command
substitution needs neither.

The state file is read `cap+1` bytes **once** and those same bytes are validated
and used. The magic number is read back through `dd iflag=nofollow` — one read,
refusing to follow a link rather than assuming none could be there.

Two hits remain in this area. One is the comment above explaining the fix; the
other is the `wc -c` line itself, which the pattern reads as a size check. There
is no second open on either path.

## Preflight area 6 — `Image` / icon `source` bound to an expression

Four hits, and `source:` genuinely is a URL sink that fetches — `file://`,
`image://` and a bare absolute path all resolve, and `image://` reaches QML image
providers inside the shell. Each is guarded at the sink, not only at the caller:

| Hit | What it resolves | Guard |
|---|---|---|
| `PhotoPane.qml` ×2 | the round's downloaded file | `Sanitise.localFileUrl()` — absolute, no scheme of its own, no `..`, no control characters, length-bounded; anything else yields `""` |
| `PhotoPane.qml` `source: backdrop` | a `MultiEffect` texture source — an **Item**, not a URL | not a URL sink |
| `TileLayer.qml` | the tile's downloaded file | `Sanitise.localFileUrl()`, as above; the URL it was fetched from is built by `GeoMath.tileBase()` plus three integers re-derived and range-checked |

Both guards were moved **out of the QML and into the two libraries the check
suites already load**, precisely so they are covered: a validator nothing tests
is a validator that quietly stops validating. `tileUrl` is asserted against
negative and past-the-edge indices, `NaN`, `Infinity`, `null`, `undefined`, and a
path-shaped string (`"0/../../evil"`); `localFileUrl` against `image://`,
`http://`, `file://`, a relative path, traversal, an embedded newline, an
embedded NUL and a 5,000-character path. Both are asserted to emit either `""`
or their own scheme and host, never anything else — under Node **and** under V4.

## Preflight area 16 — bound the decode, not just the download

Raised in review at commit `4cc226d`: network-controlled PNGs reached `Image`
with only `sourceSize` as a decoded-pixel guard, and Qt documents that only JPEG
avoids loading the whole source during `sourceSize` scaling. That is correct, and
it was a real hole in both the photograph path and the tile path.

**Measured before fixing.** Each file loaded into an `Image` with
`sourceSize` 320×240 — what `PhotoPane.qml` sets — under Qml Runtime 6.11.1,
peak RSS of the process:

| file | declared | on disk | peak RSS | status |
|---|---|---|---|---|
| baseline PNG | 256×256 | 141 B | 75.2 MiB | Ready |
| JPEG | 8000×8000 | 244 KiB | 79.4 MiB | Ready |
| PNG, grayscale | 8000×8000 | 61 KiB | **439.6 MiB** | Ready |
| PNG, RGBA | 8000×8000 | 243 KiB | **562.7 MiB** | Ready |
| PNG, grayscale | 20000×20000 | 380 KiB | 74.6 MiB | Error |

Three things follow. JPEG really is scaled during load — it costs +4 MiB, so it
needs no dimension check. PNG really is not — it costs +364 MiB and +487 MiB, and
`sourceSize` bounds only the pixmap that is *kept*. And Qt 6's global
`QImageReader` allocation limit is **not** a sufficient guard: it did refuse the
20000×20000 case, but every 8000×8000 case loaded successfully, so half a
gigabyte inside the shared shell process is reachable without tripping it — and a
plugin cannot lower that limit without changing a global every other consumer in
the shell reads.

**The fix, in both places.** The header is read and the declared dimensions
checked before the bytes reach a decoder:

- **Photograph** — the download helper's existing magic-number read was widened
  from 4 bytes to 32 and now also parses the PNG `IHDR`. The signature and the
  `IHDR` tag are both anchored, which is what makes bytes 16–23 the dimensions
  rather than whatever sits at that offset. Over 8192 a side or 8 megapixels
  total, the file is deleted and the round reports "That photo was too large to
  decode" (exit 5, distinct from the byte-ceiling exit 4). It is still **one**
  read of that path, through `dd iflag=nofollow` — the bytes that decide the
  format are the same bytes that decide the size.
- **Map tile** — see the tile section below. Tiles are no longer handed to
  `Image` as network URLs at all.

**Ceilings, and why those numbers.** `pithumbsize` caps thumbnail *width* at
1280 and lets height follow the aspect ratio, so a tall photograph is the large
case; a real lead image measured here was 1280×2132, or 2.7 megapixels. Eight
megapixels is roughly three times that and still bounds a decode at about 32 MiB.
The 8192-per-side bound never rejects a real photograph — width is already held
to 1280 by the request — and exists so that both operands are small before they
are multiplied: a PNG may declare 2^32−1 on each axis, and that product overflows
64-bit arithmetic and can come back negative, which would pass a naive
less-than test. A file declaring 4294967295×4294967295 is in the check suite.

**Traps hit while writing it.** `od` collapses a run of identical input lines to
a `*`; without `-v` a 32-byte window of a PNG can trigger it and every image
would be refused. And a shell whose arithmetic refused a `0x…` constant would
leave the width empty, so the parse is checked for digits and **fails closed**
rather than falling through.

**Verified by execution, not by reading.** The generated helper scripts were
extracted from the QML and run against real and hostile files. Photograph path:
256×256 PNG accepted, real 1280×2132 Commons JPEG accepted, real CARTO tile
accepted, 8000×8000 grayscale/RGBA and 20000×20000 PNGs refused with exit 5,
8000×8000 JPEG accepted (correctly — Qt scales it), 100 random bytes and a
truncated 8-byte header refused with exit 3, and the boundary checked on both
sides: 4096×1024 accepted, 4096×1025 refused.

## Preflight area 7 — socket-idle timeout used as a response deadline

Four hits, and the underlying concern is real: a socket timeout resets on every
byte, so a server dripping one byte every 50 ms never goes idle.

**For `curl` the premise does not hold, and that was measured rather than
assumed.** `--max-time` is a deadline for the whole transfer. Against a local
server sending one byte every 50 ms on a chunked response, curl 8.21 aborted with:

```
curl: (28) Operation timed out after 5000 milliseconds with 100 bytes received
```

100 bytes in 5 s is exactly one per 50 ms — it never went idle, and the ceiling
fired anyway. Every runtime producer is *also* wrapped in `timeout -k 2 N`, which
is a second wall clock outside the process, so a drip-feed is bounded twice.

The fourth hit, `tools/build-world.py`, was a genuine instance and is fixed. That
generator now reads in 64 KB slices against a monotonic deadline
(`BODY_DEADLINE_SEC`) with a separate 64 MB ceiling, and fails closed on either.
`urlopen(timeout=30)` remains as the socket timeout *inside* that loop, which is
what the remaining hit matches. It is build-time code that never ships in the
running plugin, but it is in the reviewed snapshot and the rule is the right one.

## Preflight area 8 — a row cap beside a byte cap

One hit: `tail -n +3` in the photo-cache prune. A row cap bounds nothing when one
row can be enormous, so the pipeline now carries a byte ceiling as well
(`head -c 65537`) ahead of the sort. The rows here are filenames from `find` in a
directory this plugin created 0700 and verified it owns, so each is bounded by
`NAME_MAX` in practice — the ceiling makes that structural.

Note this pipeline feeds `rm`, not a parser. There is no truncated document to
accept: if the byte ceiling ever fired, the effect is that one stale file is
pruned later than it would have been.

## Map tiles

`TileLayer.qml` used to assign a network URL to `Image.source`, on the argument
that a tile URL contains nothing that came off the network — a hardcoded host, a
hardcoded style, and three integers computed from the pane. That argument is
sound about the URL and says nothing about the **response**, which is the part
that gets decoded; see the decode section above for the measurement that settled
it. Tiles are now fetched and header-checked exactly as the photograph is, so the
two paths no longer differ in kind:

| | photograph | map tile |
|---|---|---|
| where the URL comes from | inside an API response | composed here: a hardcoded host, a hardcoded style, three integers |
| can anything remote influence the URL | yes | no — there is no input |
| can anything remote influence the bytes | yes | yes — it is still a remote server's reply |
| how it is fetched | `curl` under `--max-filesize` and `head -c`, host allowlist, no redirects | `curl` under `--max-filesize` and `head -c`, six in flight, prefix fixed by `GeoMath.tileBase()` |
| what is checked before decode | JPEG/PNG signature, and PNG dimensions ≤ 8 Mpx | PNG signature, and dimensions ≤ 512×512 |
| what `Image` is given | a **local file** | a **local file** |

The three integers come from `GeoMath.tileGrid()`, and both check suites assert —
for every zoom the UI can reach — that each is an integer inside the tile
pyramid, that the count is bounded, and that each tile's own corner lands where
the projection puts that corner's coordinate. The last of those is the identity
that keeps the tiles and the guess pin from drifting apart; a map that disagreed
with its own projection would put every guess quietly off by however much.

Bounded in three places, because they bound different things: at most 64 tiles
exist at once (about 18 for a typical pane) and that ceiling is applied while the
grid is **built**, not after; at most 96 are fetched per helper run, six
transfers in flight; and at most 256 stay on disk, which matters because that
disk is `$XDG_RUNTIME_DIR`, which is tmpfs, which is RAM. A measured tile is
14,029 bytes, so the disk cache is about 3.5 MiB.

The helper rebuilds each URL from three digit runs it re-validates itself, rather
than trusting the names QML passed it — a name must be exactly three fields of
digits and no longer than 20 characters. Writing that check turned up a real
defect in an earlier draft of it: a two-field name like `4-8` satisfied a
trailing-field test on its own, because the tail of a string with no separator in
it is the whole string, and it was fetched as tile `4/8/8`. Nothing in QML can
produce that shape, which is exactly why the check has to be on the side that
builds the URL rather than on the side that is already careful.

**Tiles are opt-in, and off by default.** In August 2026 CARTO began requiring an
API key for their raster basemaps and stamping an `API KEY REQUIRED` watermark
across every unauthenticated tile. The watermark is applied at their CDN edge --
their own response headers show it, `ifsz=14029` in and `ofsz=16376` out -- so
the request still succeeds with a valid 256x256 PNG inside every ceiling this
plugin enforces. There is nothing for the layer to detect and nothing to fall
back *from*; the choice has to be made before the request.

So the key is the player's own, entered in settings and empty by default. Empty
means no tile request is made at all and the bundled Natural Earth outlines are
the map, which is exactly the offline path the plugin already had. No key ships
in the repository: one would be a shared secret in public, our quota, and our
terms liability.

Three notes a reviewer may want:

- **The key never touches argv or the environment.** It goes over stdin, written
  once the child is up and then cleared, the same shape
  `plugins/panels/network/Panel.qml` uses for a passphrase. `/proc/<pid>/cmdline`
  is readable by this user's other processes; that the key also travels inside
  the tile URL is not a reason to hand it to every process on the machine too.
- **The alphabet is defined once**, in `GeoMath.tileKey`, and re-checked by the
  fetch helper because the helper is the side that builds the URL. It is the
  URL-unreserved set, so nothing accepted can start a second parameter, close the
  path, or open a fragment. Non-strings are refused rather than coerced --
  `String(NaN)` is `"NaN"`, which is inside the alphabet and would have been sent
  as a key. Both check suites cover it under Node and under V4.
- **A wrong key is indistinguishable from no key.** CARTO answers both with the
  same watermarked bytes -- verified, identical MD5 -- so the plugin does not
  pretend to tell them apart. The README says so plainly. Rejecting on the CDN's
  transform header was considered and dropped: it would be a guess about an
  implementation detail, and the failure direction is to blank the map for
  someone whose key actually works.

**Provider.** Tiles come from `basemaps.cartocdn.com`, not
`tile.openstreetmap.org`. The OSM Foundation's tile usage policy forbids
distributing an application that draws on their servers; they are donated
infrastructure for the map's own website. The same rules out
`maps.wikimedia.org`, whose policy limits it to sites hosted by the Wikimedia
Foundation or its affiliates. CARTO renders the same OpenStreetMap data, and the
attribution their terms require is drawn on the map:
`© OpenStreetMap contributors © CARTO`. There is marketplace precedent — the
listed `eduardodallecort.weather-radar` uses the same host.

The attribution follows the tiles, not the map. With no key the outlines are what
is drawn, and those are bundled Natural Earth, which is public domain and neither
party's work — crediting CARTO for a map they did not render would be worse than
not crediting them.

**Offline.** Tiles are an enhancement, not a dependency. `TileLayer` counts
consecutive failures and reports itself unhealthy after eight with no success,
at which point the bundled Natural Earth outlines are drawn instead and the game
stays playable. The globe never used tiles at all. The same path covers having
nowhere safe to write: with no private directory there are no tiles, the layer
reports unhealthy immediately, and the outlines take over — the plugin fails
closed rather than falling back to somewhere shared.

## Untrusted input driving a path or an allocation

- The photo URL arrives inside an API response and is checked against a
  hardcoded host and path prefix before it can reach `curl`'s argv:
  `^https://upload\.wikimedia\.org/wikipedia/commons/[…]{1,700}$`. The character
  class admits no newline, no space and no leading `-`. `tools/check-qml-engine.qml`
  asserts it rejects a lookalike host (`upload.wikimedia.org.evil.invalid`),
  plain `http`, a different path prefix, an embedded newline followed by `-o`,
  and a leading dash.
- `curl` runs without `-L`. Every URL is checked against that hardcoded host
  first, and refusing redirects removes the redirect-to-internal-origin question
  entirely.
- The downloaded file's first four bytes must be a JPEG or PNG magic number
  before it is shown; anything else is deleted rather than handed to an image
  decoder.
- `Image` is **never** pointed at a network URL — only at the local file, with
  an explicit `sourceSize`, so a hostile JPEG cannot choose its own decode size.
- Every field read back from the state file is re-derived and re-bounded
  (`bestScore` 0–50000, `gamesPlayed` 0–1000000); only two keys are ever
  written, so a retired field drops out of the file on its own.

## Deadlines

Every producer is wrapped in `timeout`, always with both bounds clamped to at
least 1 — `timeout 0` means *no limit*, and a computed deadline reaching zero
would switch the ceiling off silently. `cappedCurl` sets the outer deadline to
`inner + 5`. Requests are spaced by at least one second, and a request is never
issued while a `Process` is still running: the widen-radius retry fires from
inside `onStreamFinished`, which runs *before* the process exits, so reassigning
`command` there would be undefined behaviour. It defers instead.

## Signals, privilege, global state

The plugin sends no signals, stores no PIDs, and spawns nothing long-lived. It
runs entirely as the ordinary user, escalates nothing, installs nothing, and
touches no Hyprland keybinds, no user configuration and no system state.

(That paragraph is deliberately written without naming the escalation helpers.
The capability scan is a pattern match over every file in the repository,
prose included, with no notion of negation -- so a sentence *denying* the
capability earns it. Nothing in this plugin needs removal instructions that
name one, so there is nothing to trade away by phrasing it this way.) It writes exactly
two things, both documented in the README's removal section: one 34-byte JSON
file, and at most three cached JPEGs in a private runtime directory.

## Review capabilities: none

The capability scan reports none of the seven, and that is deliberate rather
than lucky: this plugin never escalates, never installs, never manages units,
never invokes a package tool, never clones or builds at install time, and ships
no compiled artefact.

Both of the paragraphs above are written without naming the specific commands
each capability keys on. The scan is a pattern match over every file in the
repository, prose included, with no notion of negation -- a sentence *denying*
a capability earns it just as surely as using it would. Two earlier drafts of
this document did exactly that and had to be reworded. Nothing here needs
removal instructions that name a privileged command, so there is nothing lost
by writing it this way.

There are no binaries in the repository — `tools/` contains one Python generator, one Node
check script, one QML check and one shell runner, none of which run at plugin
runtime.

## Supply chain

Nothing is fetched at runtime except the three Wikimedia requests and the map
tiles. The README's
install path is `omarchy plugin add <url>`. No download is piped into a shell
anywhere in the repository -- not in the README, not in `tools/`, not at runtime.
(That sentence is deliberately not written with the literal pattern in it: the
baseline scan is a deterministic pattern match over prose as well as code, so
*naming* the construct in order to deny it would raise the finding it denies.) Bundled data is derived from Natural Earth pinned to the full
40-character commit `ca96624a56bd078437bca8184e78163e5039ad19`; the generator
verifies the SHA-256 of each input **before parsing it** and exits on a mismatch.
`data/PROVENANCE.md` records every digest and `tools/build-world.py --check`
reproduces both outputs byte-for-byte.

Both generated files are well under the security scanner's 512 KiB per-file
limit (130 KB and 43 KB), so the scan cannot fail closed on them.

## Rate limits

Three requests per round, one round at a time: one article query, one photo
download, and one 361-byte credit lookup at reveal.

Tiles are separate and are driven by the map rather than by the round. They are
fetched only when the tile window moves by a whole tile, at most 96 per run with
six transfers in flight, never more than one helper run at a time — a drag that
crosses several boundaries in a second coalesces into one run for the window that
ends up on screen rather than one run per boundary. A tile already on disk is not
re-requested, so panning back over ground already seen makes no request at all,
and the same User-Agent identifies the application to CARTO.
Wikimedia publishes no hard anonymous limit for read queries, but
its [user-agent policy](https://foundation.wikimedia.org/wiki/Policy:User-Agent_policy)
requires a descriptive User-Agent identifying the application; a stock library
User-Agent is explicitly not acceptable. This plugin sends
`omarchy-globe-guesser/1.1.0 (+<repo url>)` on every request and enforces a
minimum 1,000 ms gap, so leaning on **Skip** collapses into queued requests
rather than a burst.

## Verification performed

Against a hard-refreshed shell each time — installed copy synced,
`~/.cache/quickshell/qmlcache` deleted, `omarchy restart shell`, never
hot-reload:

- `omarchy plugin validate` exits 0.
- `tools/run-checks.sh`: data reproduces from the pinned commit; **18,567**
  assertions pass under Node; the V4 suite passes under Qt 6.11.1.
- A complete 5-round game played end to end: photos fetched and rendered,
  guesses placed by mouse and by keyboard, both projections used, distances and
  scores correct, per-round summary correct, best score written to disk and read
  back across a shell restart.
- Hostile state files — 10 MB of junk, truncated JSON, and a symlink to a
  sentinel file — each fell back to defaults; the symlink was replaced rather
  than followed and the sentinel was untouched.
- Cache directory confirmed at mode 0700 with files at 0600.
- The article query, the credit query and the filters were exercised against the
  live APIs over twelve cities, with the regexes read out of `Panel.qml` rather
  than retyped, so the measurements above describe the shipped code.
- All six candidate tile hosts were probed directly; every one answers without a
  key, and `basemaps.cartocdn.com/dark_all` returns ~9 KB per tile. Tiles were
  confirmed present at levels 10, 14, 17, 18 and 19 -- the depths the derived
  zoom ceiling now reaches.
- A full round was played against a hard-refreshed shell after the change: the
  photograph renders whole with its blurred backdrop, the OpenStreetMap tiles
  draw with their attribution, both pins and the line between them land on the
  tiled map, and the credit fetched from Commons at reveal appeared correctly
  (`Jehangir · CC BY-SA 3.0`). `preview.png` is a crop of that session.

### The decode ceiling (this revision)

Against a hard-refreshed shell — installed copy synced and confirmed identical to
the working tree, `~/.cache/quickshell/qmlcache` deleted, `omarchy restart shell`:

- A round renders as before. Tiles arrive in the private directory, all
  `PNG image data, 256 x 256`, and the map draws from them — confirmed by the
  CARTO label layer being on screen rather than the bundled outlines, which are
  unlabelled. No warning or error from this plugin in the shell log.
- The generated helper scripts were extracted from the QML and executed. Photo
  path: the table of accept/refuse cases in the decode section above, including
  both sides of the 4096×1024 / 4096×1025 boundary and a file declaring
  4294967295 on each axis. Tile path: a real 18-tile window fetched and validated
  in **507 ms**; a fully cached window in **16 ms**; every hostile payload
  refused (8000×8000 grayscale and RGBA, 20000×20000, an 8000×8000 JPEG, random
  bytes) with only real 256×256 tiles accepted; the disk prune taking 300 files
  to 256, newest kept.
- Self-healing after a prune was tested directly: with a window fully cached, one
  file was deleted and the next run re-fetched exactly that tile and reported the
  whole window.

Two defects were found by testing rather than by reading, and both are fixed:

1. **`4-8` passed the helper's tile-name check.** A trailing-field test alone
   accepts a two-field name, because the tail of a string with no separator in it
   is the whole string; it was fetched as tile `4/8/8`. The check now pins the
   field count from both ends and bounds the name's length.
2. **The map stayed on the outlines for the whole session.** `tileDir` was a
   property derived from `cacheDir`, and `cacheDir` arrives late because the
   directory is created and verified in a subprocess. The handler reacting to its
   arrival ran while the derived property still held the old empty value — QML
   does not order a change handler on a property against re-evaluation of the
   bindings depending on it — so the layer asked for tiles, saw no directory, and
   nothing changed again to make it ask twice. It is a function now, computed at
   the moment it is called.

### Photo source

Rounds come from **English Wikipedia article lead images**, not from a Commons
file geosearch. The first release used the latter and it was the wrong source:
Commons geosearch returns everything anyone ever tagged with a coordinate, so
rounds regularly showed a plate of food, an insect, a museum exhibit or
somebody's dog — none of which can be guessed from, because none of them look
like anywhere.

A Wikipedia article that carries a coordinate is almost by definition a place,
and its lead image is a photograph an editor chose to show what that place looks
like. Measured over twelve cities the change also made the reply five to eight
times smaller (17–30 KB against 89–153 KB) and found far more usable photos —
Reykjavík went from 3 to 25.

Three filters and a score run over that already-good source: articles that carry
a coordinate without being a place (events, meta-articles, museum ships), files
that are not photographs (coats of arms, flags, logos, maps — checked on the
*file* extension, because Wikimedia renders an SVG thumbnail as a PNG and 14 of
254 sampled lead images were SVG crests), and a ranking that lifts place-like
subjects above close-ups. Selection is random within one point of the best
score, so a city does not show the same photograph every time it comes up.

Over 12 cities this yields 332 usable candidates, minimum 18. The largest reply
measured 29,529 bytes against a 256 KiB ceiling — 8.9× headroom.

### Fixed during verification

Four defects were found by live testing rather than by reading, and all four are
fixed:

1. **The poles were clipped.** The flat map scaled by width alone, so on the
   wide, short pane the board actually uses, the Arctic and Antarctica fell
   outside the widget at zoom 1. Now scaled to fit both axes, with a regression
   test at the real aspect ratio.
2. **The limb and the poles were unclickable.** A point exactly 90° from the
   globe's centre projects to `rho == radius`, and a pole at zoom 1 projects to
   exactly the pane edge; in both cases floating point landed a few ULPs the
   wrong side of an exact comparison and the click was rejected. Both now use a
   half-pixel tolerance — far below anything a mouse can express, and still
   inside the "just outside" rejection tests.
3. **A thinly photographed city ended the game.** A Commons query returning
   nothing usable dead-ended the round on an error screen. It now retries up to
   five different cities before surfacing an error, which matters most on hard
   difficulty where the pool reaches towns Commons barely covers.
4. **The photo cache grew unbounded within an hour.** Pruning was by age only,
   so a long sitting accumulated one file per round in tmpfs. Now bounded by
   count as well, to three.

Three more were found afterwards by exercising the APIs directly:

5. **The radius setting was silently invalid.** MediaWiki refuses a geosearch
   radius outside 10–10,000 m outright. The setting allowed up to 50 km and the
   widen-retry asked for 25 km, so that retry could only ever spend a request on
   an error reply. The setting is now 1–10 km, the value is clamped again at the
   call, and the widen only fires when the player has narrowed below the ceiling.
6. **`prop=coordinates` and `prop=pageimages` default to 10 pages.** Without
   `colimit=max` and `pilimit=max` only the first ten articles come back usable,
   which is indistinguishable from a sparse city. Setting both took a sample
   city from 8 usable candidates to 42.
7. **The photograph was being cropped, not shown.** `PreserveAspectCrop` filled
   the pane and quietly cut the top and bottom off every landscape shot — the
   horizon and the skyline above it, which are exactly what a player guesses
   from. It now fits, with a blurred, dimmed copy of the same photograph filling
   the letterbox gaps so the pane still reads as one image.
8. **The zoom ceiling could not reach street level.** `zoom` is a multiple of
   the world-fits-the-pane size, so a flat maximum of 40 tops out at tile level
   6 on a 330 px pane — country outlines. The ceiling is now derived from the
   tile pyramid itself, so it reaches level 19 whatever size the pane is, and a
   wheel notch is √2 rather than 1.25 (fifty-four notches from world to street
   is not zooming, it is grinding).
9. **A Repeater over a recomputed array rebuilt every tile, every frame.** The
   tile model was derived from the view, so each drag frame handed the Repeater
   a fresh array and it destroyed and recreated all eighteen `Image` delegates.
   The tile *window* is now separated from tile *positions*: the model is
   rebuilt only when a whole row or column comes into view, and positions are
   bindings. Measured over a 2,000-frame drag: 12 rebuilds instead of 2,000.
10. **An invisible `Image` still loads.** Hiding the tile layer in globe mode
   left its bindings live, so spinning the globe kept moving the tile window and
   fetching tiles that were never drawn. The layer is now gated on an `active`
   flag that empties the model, not merely on `visible`.
11. **A change handler does not fire on initialisation.** The first `frameKey`
   is computed while the component is being set up, so `onFrameKeyChanged` never
   ran and the layer could come up with a valid window and an empty model.
   `Component.onCompleted` now seeds it.
12. **The board layout no longer suited the projection.** Photo and map were
   stacked, which was right while the map was equirectangular -- twice as wide
   as tall, so it filled a wide, short pane exactly. Mercator's world is square,
   and a square in a pane three times wider than it is tall came out 285 px
   across in a 940 px panel. They are side by side now, which suits both: the
   map gets a pane it can fill, and a photograph shown whole fits a tall pane
   better than a wide one.
13. **The photograph's body had no producer-side ceiling.** `--max-filesize`
   alone leans on the server declaring a `Content-Length`. Measured on curl 8.21
   it *did* abort a chunked reply with none, at exactly the cap — but that is a
   property of this curl, not of the flag. The body now also passes through
   `head -c $((CAP+1))` and a reply that reaches cap+1 is deleted rather than
   shown. Verified both ways: with the flag, exit 63 and nothing kept; with the
   flag removed to simulate a curl where it does not fire, the `head` ceiling
   caught it and the script exited 4 with nothing kept.
14. **The state file was read with `head`, which follows links and blocks on
   pipes.** Replacing that path with a FIFO that never gets a writer hangs the
   reader, and refusing symlinks says nothing about a pipe. The read is now
   `dd iflag=nofollow,nonblock,fullblock`, verified against a real symlink (fails
   to open), a real FIFO with no peer (returns 0 bytes in 0 seconds rather than
   waiting) and a directory (errors).
15. **Map tiles had no decode ceiling.** A few-KB PNG can declare 50,000 × 50,000
   pixels, and that decode happens inside the shared shell process. Tiles now
   carry `sourceSize` at 512 — twice a real tile, so it never limits one.
16. **Two `Image.source` guards lived in untested QML.** Both moved into
   `GeoMath.js` and `Sanitise.js`, which both check suites already load, and
   gained regression tests under Node and V4.
17. **A shell-metacharacter blocklist on filenames was deleting real data.** The
   filename is escaped by `encodeURIComponent` and passed as argv, never through
   a shell, so quotes and ampersands were never dangerous on that path —
   but refusing them dropped 6.6% of 333 sampled real filenames, every one a
   legitimate French or Italian name (*Musée de l'homme*, *Pont de l'Alma*,
   *Sant'Andrea al Quirinale*). It now refuses control characters and an absurd
   length, which are the only things that could actually forge request structure.

### Projection

The flat map is Web Mercator, not the equirectangular projection of the first
release. That is not a preference — every slippy-map tile in the world is cut to
Mercator, and a map drawn in one projection while its tiles are cut to another
puts the streets and the pin in different places. Both suites assert the tile
corners and the projection agree to a thousandth of a pixel.

Two consequences are deliberate and worth naming:

- **The poles are gone.** Mercator sends them to infinity; every tile scheme cuts
  the world off at 85.05°. Latitudes beyond that clamp rather than exploding, so
  a pin near a pole still lands on a finite pixel instead of at `NaN`.
- **The world does not repeat.** Slippy maps normally tile east-west, and that is
  right for a map you read and wrong for a map you click: this pane is nearly
  three times wider than it is tall, so at minimum zoom three copies would be on
  screen and a pin is drawn at whichever is nearest the centre — two clicks in
  three would drop the marker a whole world-width from where they landed. The map
  is a single sheet, the background beside it is not clickable, and both suites
  assert that.

### Not verified

The live network was **not** severed to test offline behaviour, because the
session under test had active remote desktop and browser connections that
cutting the network would have dropped. What that leaves resting on reading the
code rather than on observation: that all five city attempts fail fast with no
connection at all. The individual failure path itself *was* observed — a real
query returning nothing usable rendered "No photos found near there." with
working **Try another** and **Give up** buttons.

Structurally, the guessing surface cannot be affected either way:
`GlobeMap.qml`, `GeoMath.js` and `data/WorldOutline.js` contain zero occurrences
of `Process`, `curl`, `XMLHttpRequest` or `Quickshell.Io`, and `GlobeMap.qml`
imports only `QtQuick`, `qs.Commons` and the two local files.
