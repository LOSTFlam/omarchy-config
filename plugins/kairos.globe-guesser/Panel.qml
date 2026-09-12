import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "GeoMath.js" as GeoMath
import "Sanitise.js" as Sanitise
import "data/Places.js" as Places

// Globe Guesser: the game, the two network calls it makes, and the one small
// file it keeps.
//
// The map and the globe never touch the network -- they are drawn from bundled
// Natural Earth outlines in GlobeMap.qml -- so the guessing half of the game
// works with the machine offline. Only the photograph needs a connection, and
// it comes from Wikimedia Commons, anonymously and without an API key.
//
// Two requests per round, both described at the Process that issues them:
//
//   1. one api.php query returning candidate photos near a city, each with its
//      own coordinates, licence and author
//   2. one download of the single chosen photo to a private directory
//
// The downloaded file is what Image renders. Image.source is never pointed at a
// network URL: the address arrives inside an API response, so it is
// attacker-influenced, and a remote Image would hand that response an unbounded
// fetch and decode inside the shared, long-lived shell process.
Panel {
  id: root
  moduleName: "kairos.globe-guesser"

  // One panel instance exists per bar, so on a multi-monitor desktop several
  // would race to claim the same IPC name and whichever registered first would
  // win. Only the largest screen's instance claims it, so
  //
  //     omarchy-shell kairos.globe-guesser toggle
  //
  // always acts on a predictable panel -- and is bindable to a key.
  readonly property var panelScreen: anchorItem && anchorItem.QsWindow.window
    ? anchorItem.QsWindow.window.screen : null
  readonly property var mainScreen: {
    var best = null
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (!best || screens[i].width * screens[i].height > best.width * best.height)
        best = screens[i]
    }
    return best
  }
  ipcTarget: panelScreen && panelScreen === mainScreen ? moduleName : ""

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  property bool openedFromHotkey: false

  // ---------------------------------------------------------------- settings
  //
  // Every one of these is clamped here rather than trusted, and every one has a
  // matching entry in manifest.json. The manifest is what the shell's settings
  // UI and a reviewer read, so the two drifting apart is a defect in itself.
  readonly property string difficulty: {
    var value = String(setting("difficulty", "normal"))
    return ["easy", "normal", "hard"].indexOf(value) >= 0 ? value : "normal"
  }
  readonly property int roundsPerGame:
      Math.min(10, Math.max(3, parseInt(setting("roundsPerGame", 5), 10) || 5))
  readonly property string defaultView: setting("defaultView", "map") === "globe" ? "globe" : "map"
  // MediaWiki's geosearch refuses a radius outside 10..10000 metres outright --
  // "The value \"25000\" for parameter \"ggsradius\" must be between 10 and
  // 10,000" -- so 10 km is a hard ceiling, not a preference. An earlier revision
  // allowed up to 50 km here and widened a thin result to 25 km, which meant the
  // widen retry could only ever spend a request on an error reply.
  readonly property int searchRadiusKm:
      Math.min(10, Math.max(1, parseInt(setting("searchRadiusKm", 10), 10) || 10))

  // The player's own CARTO basemap key, or "" for none -- which is the default
  // and the case the game is designed around. Validated by GeoMath.tileKey
  // rather than here, because that is the one place the alphabet is defined and
  // both check suites already cover it; anything that is not a key collapses to
  // "" and the map falls back to the bundled outlines.
  //
  // Why this setting exists at all: in August 2026 CARTO began stamping an
  // "API KEY REQUIRED" watermark across every unauthenticated raster tile. The
  // request still succeeds, so nothing in this plugin could detect it as a
  // failure -- the tiles simply arrived defaced. See GeoMath.tileKey.
  readonly property string cartoApiKey: GeoMath.tileKey(setting("cartoApiKey", ""))

  readonly property int maxRadiusMetres: 10000

  // ---------------------------------------------------------------- ceilings
  //
  // Sized from measured replies. A Commons geosearch page with imageinfo and
  // extmetadata for 60 files measured 89-153 KiB across eight cities; 512 KiB is
  // more than three times the largest of those and is still a hard bound on what
  // the shell can be made to hold. The bound is applied at the producer, by
  // `head -c`, because StdioCollector retains the whole of stdout before any
  // signal fires -- a check inside onStreamFinished is downstream of the
  // allocation it claims to prevent.
  // The place query is small: measured 12.9-21.1 KiB across nine cities at
  // ggslimit=50, and roughly double that at 100. 256 KiB is more than five times
  // the largest of those and is still a hard bound on what the shell can hold.
  readonly property int wikiCapBytes: 262144

  // One file's licence and author. A measured reply was 361 bytes.
  readonly property int attrCapBytes: 32768

  readonly property int stateCapBytes: 65536

  // Both helper scripts emit a filesystem path on stdout. PATH_MAX is 4096, so
  // anything longer is not a path this system can even open.
  //
  // The producer is asked for one byte more than this, and a reply that reaches
  // the ceiling is rejected rather than used. That distinction matters here more
  // than it looks: a path cut off at exactly the ceiling still matches the shape
  // check below, so bounding at the ceiling itself would hand back a
  // valid-looking directory or filename that is not the one the script created.
  readonly property int pathCapBytes: 4096

  // Six megabytes is generous for a 1280px JPEG (a measured one was 418 KiB) and
  // is enforced by curl itself, before the bytes are written.
  readonly property int photoCapBytes: 6000000

  // A ceiling on the DECODE. This is a different quantity from the one above and
  // is not bounded by it.
  //
  // A PNG stores its pixel count in the header and its pixels compressed, so the
  // two numbers are unrelated: a 61 KiB file can declare 8000x8000 and cost
  // hundreds of megabytes the moment anything decodes it. Image.sourceSize does
  // not prevent that. Qt scales DURING load for JPEG only; for every other
  // format it loads the source at full size and scales afterwards, so the peak
  // has already been paid by the time sourceSize applies.
  //
  // Measured under Qml Runtime 6.11.1, each file loaded into an Image with
  // sourceSize 320x240 -- exactly what PhotoPane.qml sets -- peak RSS of the
  // process:
  //
  //     256x256 PNG      141 B     75.2 MiB   the runtime's own floor
  //   8000x8000 JPEG     244 KiB   79.4 MiB   scaled during load, +4 MiB
  //   8000x8000 PNG       61 KiB  439.6 MiB   full source first, +364 MiB
  //   8000x8000 RGBA     243 KiB  562.7 MiB   full source first, +487 MiB
  //
  // Qt 6 does carry a global QImageReader allocation limit, and it is not a
  // substitute for this check. A 20000x20000 grayscale PNG was refused by it,
  // but all three 8000x8000 files above loaded successfully -- the limit sits
  // high enough that half a gigabyte inside the shared shell process is
  // reachable without tripping it, and a plugin cannot lower it without changing
  // a global that every other consumer in the shell also reads.
  //
  // So the header is read and the dimensions checked before the file is handed
  // to a decoder at all.
  //
  // The ceiling is set from measured replies rather than guessed. pithumbsize
  // caps the WIDTH at 1280 and leaves the height to the aspect ratio, so a tall
  // photograph is the large case: a real lead image measured here was 1280x2132,
  // which is 2.7 megapixels. Eight megapixels is roughly three times that and
  // still bounds a decode at about 32 MiB -- against the 562 MiB a hostile file
  // reached above, and well under the point where Qt's own limit would have to
  // catch it.
  //
  // The per-side bound is the looser of the two on purpose. Width is already
  // held to 1280 by the request, so 8192 a side never rejects a real photograph;
  // its job is to keep both operands small enough that the pixel product below
  // cannot overflow, and the pixel count is what actually bounds the memory.
  readonly property int photoMaxDim: 8192
  readonly property int photoMaxPixels: 8388608

  // How many candidate photos are retained from one reply. ggslimit is a
  // request, not a guarantee, so the list is cut before QML holds it.
  //
  // Raised from 40 with the move to article lead images: one larger reply that
  // yields a usable photo first time is faster than three small ones that do
  // not, and each reply is a fifth of the size it used to be anyway.
  readonly property int maxCandidates: 60

  // The Wikimedia user-agent policy requires a request to identify the
  // application; a stock library User-Agent is explicitly not acceptable.
  readonly property string userAgent:
      "omarchy-globe-guesser/1.1.0 (+https://github.com/kairos-tech-oh/omarchy-globe-guesser)"

  // Commons is generous with anonymous read queries and this plugin makes one
  // per round, but a player leaning on Skip should not be able to turn that into
  // a burst. Anything arriving sooner is queued, not dropped and not sent.
  readonly property int minRequestGapMs: 1000
  property real lastRequestMs: 0

  // ------------------------------------------------------------- game state
  //
  // phase drives the whole UI:
  //   idle      the start screen
  //   loading   fetching this round's photo
  //   guessing  photo is up, waiting for a guess
  //   revealed  guess locked in, answer shown
  //   summary   the game is over
  property string phase: "idle"

  // The round on screen. { lat, lon, title, credit, licence, path, city, country }
  property var round: null

  // The next round, fetched while the player reads the reveal so that Next is
  // instant. One slot, discarded when a game ends.
  property var pendingRound: null
  property bool pendingFailed: false

  property var guess: null
  property int roundIndex: 0
  property int totalScore: 0
  property var results: []
  property string mapMode: "map"
  property string statusText: ""

  // Indices into Places.PLACES already used this game, so one game cannot show
  // the same city twice.
  property var usedPlaces: []

  // Set once at construction. "" means there was nowhere private to write, and
  // the game refuses to start rather than falling back to a shared directory.
  property string cacheDir: ""
  property bool cacheChecked: false

  // -------------------------------------------------------------- highscores
  property int bestScore: 0
  property int gamesPlayed: 0
  property bool stateLoaded: false

  // ---------------------------------------------------------------- the pool
  //
  // The ceiling from the generator is re-applied here. A cap that only exists in
  // tools/build-world.py is a cap the running shell does not have: the shell
  // loads whatever bytes are on disk.
  readonly property var places: {
    var all = Places.PLACES
    if (!Array.isArray(all)) return []
    var limit = Math.min(Places.MAX_PLACES || 1000, 1000)
    var out = []
    for (var i = 0; i < all.length && out.length < limit; i++) {
      var place = all[i]
      if (!Array.isArray(place) || place.length < 4) continue
      var latitude = Number(place[2])
      var longitude = Number(place[3])
      if (!isFinite(latitude) || !isFinite(longitude)) continue
      if (Math.abs(latitude) > 90 || Math.abs(longitude) > 180) continue
      out.push([String(place[0]), String(place[1]), latitude, longitude])
    }
    return out
  }

  readonly property int poolSize: {
    if (root.difficulty === "easy") return Math.min(Places.TIER_EASY || 150, root.places.length)
    if (root.difficulty === "normal") return Math.min(Places.TIER_NORMAL || 500, root.places.length)
    return root.places.length
  }

  // ------------------------------------------------------------- bar surface
  //
  // `label` and `tooltip` are the two strings that leave this plugin for text
  // sinks it does not own. The shell renders both through components that set no
  // textFormat and therefore fall back to Qt's Text.AutoText -- Ui/WidgetButton
  // for the label, plugins/bar/Bar.qml for the tooltip. A plugin cannot set a
  // property on a Text it does not own, so the string has to be safe before it
  // goes.
  //
  // Both are wrapped wholesale rather than field by field, so a part added to
  // either later is covered without anyone having to remember. Today every
  // piece is a plugin-authored constant or a formatted number; the point is that
  // the boundary is guarded, not that the current contents happen to be safe.
  readonly property string label: Sanitise.plainOneLine(root.composeLabel(), 40)

  function composeLabel() {
    if (root.phase === "guessing" || root.phase === "revealed" || root.phase === "loading")
      return "GLOBE " + (root.roundIndex + 1) + "/" + root.roundsPerGame
    if (root.bestScore > 0) return "GLOBE " + GeoMath.formatNumber(root.bestScore)
    return "GLOBE"
  }

  readonly property string tooltip: Sanitise.plainOneLine(root.composeTooltip(), 200)

  function composeTooltip() {
    if (root.cacheChecked && root.cacheDir === "")
      return "Globe Guesser: no private directory to cache photos in"
    var parts = ["Globe Guesser"]
    if (root.phase === "guessing") parts.push("round " + (root.roundIndex + 1) + " — make a guess")
    else if (root.phase === "revealed") parts.push("round " + (root.roundIndex + 1) + " — scored")
    else if (root.phase === "loading") parts.push("finding a photo")
    if (root.bestScore > 0) parts.push("best " + GeoMath.formatNumber(root.bestScore))
    if (root.gamesPlayed > 0) parts.push(root.gamesPlayed + (root.gamesPlayed === 1 ? " game" : " games"))
    return parts.join(" · ")
  }

  // ---------------------------------------------------------- panel plumbing

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    setCenterHoverRevealSuppressed(true)
    root.controller.show()
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && root.bar.shell && typeof root.bar.shell.focusAdjacentPanel === "function")
      root.bar.shell.focusAdjacentPanel(root.barIdentity, direction)
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
  }

  // ------------------------------------------------------------ private dir
  //
  // Photos are written to $XDG_RUNTIME_DIR/omarchy-globe-guesser, which is
  // /run/user/<uid>: mode 0700, owned by this user, and cleared at logout. If
  // that is not available the fallback is $HOME/.cache/omarchy-globe-guesser.
  //
  // There is deliberately no /tmp fallback, not even a last-resort one. /tmp is
  // shared and predictable, so another local user can pre-create a path there as
  // a symlink and redirect a write into a file of their choosing. With nowhere
  // private to write, this plugin does nothing and says so -- it is a game, and
  // failing closed costs nothing worth a foothold.
  //
  // The candidates are passed as arguments, never spliced into the script text,
  // and the directory is created private and then verified: a directory, not a
  // symlink, and owned by us.
  readonly property string dirScript:
    'for d in "$@"; do\n' +
    '  [ -n "$d" ] || continue\n' +
    '  mkdir -m 700 -p -- "$d" 2>/dev/null || continue\n' +
    '  [ -d "$d" ] && [ ! -L "$d" ] && [ -O "$d" ] || continue\n' +
    '  printf %s "$d" | head -c ' + (pathCapBytes + 1) + '\n' +
    '  exit 0\n' +
    'done\n' +
    'exit 1\n'

  Process {
    id: dirProcess
    running: true
    command: {
      var runtime = Quickshell.env("XDG_RUNTIME_DIR") || ""
      var home = Quickshell.env("HOME") || ""
      var candidates = []
      if (runtime !== "") candidates.push(runtime + "/omarchy-globe-guesser")
      if (home !== "") candidates.push(home + "/.cache/omarchy-globe-guesser")
      return ["timeout", "-k", "2", "6", "sh", "-c", root.dirScript, "sh"].concat(candidates)
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var path = String(text || "").replace(/[\r\n]+$/, "")
        // At or over the ceiling means the reply was cut off, and a cut-off
        // path still looks like a path. Nothing, rather than the wrong
        // directory.
        if (path.length > root.pathCapBytes) path = ""
        // An absolute path with no surprises in it, or nothing. This is the
        // value every later argv splices a filename onto.
        root.cacheDir = /^\/[A-Za-z0-9._\/-]+$/.test(path) ? path : ""
      }
    }
    onExited: function (exitCode) {
      if (exitCode !== 0) root.cacheDir = ""
      root.cacheChecked = true
    }
  }

  // ------------------------------------------------------------ persistence
  //
  // One small file: the best score and how many games have been finished.
  readonly property string statePath: {
    var stateHome = Quickshell.env("XDG_STATE_HOME") || ""
    if (stateHome === "") {
      var home = Quickshell.env("HOME") || ""
      if (home === "") return ""
      stateHome = home + "/.local/state"
    }
    return stateHome + "/omarchy/globe-guesser-state.json"
  }

  // Read once, bounded, on a descriptor opened with the right flags.
  //
  // Not FileView: it exposes no way to bound a read, so a state file that has
  // been grown to a gigabyte by anything at all is pulled whole into the shell
  // before a size check downstream could refuse it.
  //
  // Not `head` either, which was the previous reader. `head` follows a symlink
  // and blocks on a FIFO, and a state path is exactly where somebody would put
  // one: replacing this file with a pipe that never gets a writer hangs the
  // reader. Refusing links is not enough on its own -- a pipe is not a link, and
  // it is the one that hangs.
  //
  // `dd` is the one coreutils tool that can pass the flags:
  //
  //   iflag=nofollow    a symlink at the path fails to open (ELOOP) rather than
  //                     being followed to whatever it points at
  //   iflag=nonblock    a FIFO with no writer returns immediately with nothing,
  //                     instead of waiting for a peer that never arrives
  //   iflag=fullblock   one dd invocation returns the whole ceiling rather than
  //                     whatever a single read() happened to yield
  //
  // Verified against a real symlink, a real FIFO with no peer, and a directory:
  // symlink and directory both error, the FIFO returns 0 bytes in 0 seconds.
  // `timeout` stays as the outer bound regardless.
  //
  // cap+1 bytes are requested, not cap. `bs=cap` on an oversized file yields a
  // valid-looking JSON prefix, which would be accepted and then written back as
  // permanently truncated state. Asking for one more byte than the ceiling is
  // what makes "exactly at the limit" distinguishable from "cut off".
  //
  // The bytes that arrive are the bytes that are validated and used. There is no
  // second open: a stat followed by a separate read is a window in which the
  // file can be replaced, and what was checked is then not what was loaded.
  Process {
    id: stateReader
    running: root.statePath !== ""
    command: ["timeout", "-k", "2", "6", "dd",
              "if=" + root.statePath,
              "iflag=nofollow,nonblock,fullblock",
              "bs=" + String(root.stateCapBytes + 1),
              "count=1", "status=none"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyState(text)
    }
    onExited: function (exitCode) {
      // A missing file is the normal first run, not an error.
      if (exitCode !== 0) root.stateLoaded = true
    }
  }

  function applyState(raw) {
    root.stateLoaded = true
    try {
      var text = String(raw || "")
      if (text.trim() === "") return
      // Over the ceiling means corrupt or hostile either way. Defaults take
      // over silently: this is a score file, not something worth interrupting
      // anyone over.
      if (text.length > root.stateCapBytes) return

      var parsed = JSON.parse(text)
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return

      // Every field re-derived and re-bounded. Nothing is carried across on
      // trust, and unknown keys simply never make it into a property.
      var best = Number(parsed.bestScore)
      var played = Number(parsed.gamesPlayed)
      root.bestScore = isFinite(best) ? Math.min(50000, Math.max(0, Math.round(best))) : 0
      root.gamesPlayed = isFinite(played) ? Math.min(1000000, Math.max(0, Math.round(played))) : 0
    } catch (error) {
      root.bestScore = 0
      root.gamesPlayed = 0
    }
  }

  // Written through the same hardened-directory discipline as the photo cache:
  // the directory is created 0700 and verified, the payload arrives on stdin
  // rather than in argv, and it lands on a mktemp name that is then renamed into
  // place. A fixed `.tmp` sibling would be predictable, and predictable is what
  // lets someone else decide where a truncating write actually goes.
  readonly property string writeScript:
    'p="$1"; d=$(dirname -- "$p")\n' +
    'mkdir -m 700 -p -- "$d" 2>/dev/null || exit 1\n' +
    '[ -d "$d" ] && [ ! -L "$d" ] && [ -O "$d" ] || exit 1\n' +
    't=$(mktemp "$d/.globe-guesser.XXXXXXXX") || exit 1\n' +
    'chmod 600 -- "$t" || { rm -f -- "$t"; exit 1; }\n' +
    'cat > "$t" || { rm -f -- "$t"; exit 1; }\n' +
    'mv -f -- "$t" "$p" || { rm -f -- "$t"; exit 1; }\n'

  Process {
    id: stateWriter
    property string payload: ""
    stdinEnabled: true

    // Written here rather than straight after `running = true`: assigning
    // running and writing on the next line races the spawn, and a payload
    // written before the child exists is simply dropped -- which would truncate
    // the state file rather than fail visibly.
    onStarted: {
      write(payload)
      payload = ""
      // Closing stdin is what lets `cat` in the script see end of input and
      // finish; without it the write never completes and timeout kills it.
      stdinEnabled = false
    }
  }

  function saveState() {
    if (root.statePath === "" || stateWriter.running) return
    // Only these two keys are ever written, so a field retired from a future
    // version drops out of the file on its own rather than lingering.
    stateWriter.payload = JSON.stringify({
      bestScore: root.bestScore,
      gamesPlayed: root.gamesPlayed
    }) + "\n"
    stateWriter.command = ["timeout", "-k", "2", "6", "sh", "-c", root.writeScript, "sh", root.statePath]
    stateWriter.stdinEnabled = true
    stateWriter.running = true
  }

  // ------------------------------------------------------------- the network

  // Producer-bounded curl. Both bounds are outside QML on purpose:
  //
  //   head -c   closes the pipe at the byte ceiling, at the producer, before
  //             StdioCollector can retain anything
  //   timeout   is the deadline that still applies while curl is blocked in a
  //             syscall; curl's own --max-time is the inner limit
  //
  // timeout 0 means *no limit*, so both bounds are clamped to at least 1: a
  // computed deadline that reached zero would quietly switch the ceiling off.
  // The URL and every option travel as argv entries; nothing is spliced into the
  // script text.
  //
  // On curl\'s --max-time specifically: it is a deadline for the whole transfer,
  // not a socket-idle timer that resets on every byte. Measured on curl 8.21
  // against a server sending one byte every 50ms and never going idle --
  // "Operation timed out after 5000 milliseconds with 100 bytes received". The
  // outer `timeout` is a second wall clock regardless, so a drip-feed is bounded
  // twice over.
  //
  // No -L. Every URL this plugin fetches is checked against a hardcoded host
  // before it is used, and refusing redirects means a compromised or
  // misconfigured endpoint cannot use one to send the request somewhere else.
  function cappedCurl(url, capBytes, maxTimeSec) {
    var innerSec = Math.max(1, Math.round(maxTimeSec))
    var deadlineSec = Math.max(1, innerSec + 5)
    return ["timeout", "-k", "2", String(deadlineSec),
            "sh", "-c", 'cap="$1"; shift; curl "$@" | head -c "$cap"', "sh",
            String(capBytes + 1),
            "-fsS", "--proto=https", "--max-time", String(innerSec),
            // Wikimedia serves these replies gzipped, and the JSON compresses
            // to roughly a fifth. curl inflates before writing to stdout, so
            // `head -c` still bounds the *decompressed* stream -- the ceiling
            // is not weakened by asking for compression, only the wire time is.
            "--compressed",
            "-A", root.userAgent,
            "--", String(url)]
  }

  // curl's exit status does not survive that pipeline -- head exits 0 whether
  // curl succeeded, 404'd or was killed at the deadline -- so an empty body is
  // what reports producer failure. The length check is a secondary guard only:
  // String.length counts UTF-16 units rather than bytes, and head -c is the
  // bound that actually holds.
  function parseCappedJson(raw, capBytes) {
    var text = String(raw || "")
    if (text.trim() === "") throw new Error("empty response")
    if (text.length > capBytes) throw new Error("response exceeded " + capBytes + " bytes")
    return JSON.parse(text)
  }

  // Where a round comes from.
  //
  // This asks *English Wikipedia* for the ARTICLES near a point and their lead
  // images -- not Commons for the FILES near a point, which is what an earlier
  // revision did and what made the game unplayable.
  //
  // The difference is the whole fix for "that photo is not a place". Commons
  // geosearch returns anything anyone ever tagged with a coordinate: a plate of
  // food, a beetle, a gravestone, a museum exhibit, somebody's dog. None of
  // those can be guessed from, because none of them look like anywhere.
  // A Wikipedia article that *has* a coordinate is, almost by definition, a
  // place -- a station, a bridge, a district, a park, a temple -- and its lead
  // image is a photograph of that place, chosen by an editor to show what it
  // looks like.
  //
  // Measured over nine cities it is also five to eight times smaller on the
  // wire (12.9-21.1 KiB against 89-153 KiB) and finds far more usable photos:
  // Reykjavik went from 3 to 37.
  //
  // colimit and pilimit are set to max deliberately. Both default to 10, so
  // without them only the first ten articles come back with the coordinates and
  // the thumbnail that make them usable at all -- which looks exactly like a
  // sparse city and is impossible to tell apart from one.
  function placesUrl(latitude, longitude, radiusMetres) {
    var query = [
      "action=query",
      "format=json",
      "formatversion=2",
      "generator=geosearch",
      "ggscoord=" + encodeURIComponent(latitude.toFixed(5) + "|" + longitude.toFixed(5)),
      "ggsradius=" + String(root.clampRadius(radiusMetres)),
      "ggslimit=100",
      "prop=coordinates|pageimages",
      "colimit=max",
      "piprop=thumbnail|name",
      "pithumbsize=1280",
      "pilimit=max"
    ]
    return "https://en.wikipedia.org/w/api.php?" + query.join("&")
  }

  // 10..10000 metres, enforced here as well as at the setting, because the
  // widen retry computes a radius rather than reading one.
  function clampRadius(metres) {
    var value = Math.round(Number(metres))
    if (!isFinite(value)) return root.maxRadiusMetres
    return Math.min(root.maxRadiusMetres, Math.max(10, value))
  }

  // Licence and author for one file, asked of Commons at reveal time.
  //
  // Wikipedia's pageimages gives a usable thumbnail URL but no licence, and
  // these photographs are almost all CC-licensed, so the credit has to come from
  // somewhere. Fetching it per round rather than per candidate turns what would
  // have been a bulk query for sixty files into a 361-byte one for the single
  // file actually shown -- and it happens while the player is looking at the
  // answer, off the path that decides how fast the photo appears.
  function attributionUrl(fileName) {
    var query = [
      "action=query",
      "format=json",
      "formatversion=2",
      "titles=" + encodeURIComponent("File:" + fileName),
      "prop=imageinfo",
      "iiprop=extmetadata",
      "iiextmetadatafilter=LicenseShortName|Artist"
    ]
    return "https://commons.wikimedia.org/w/api.php?" + query.join("&")
  }

  // ------------------------------------------------------------ what counts
  //
  // Article lead images are already overwhelmingly photographs of places, so
  // these are a second pass over a good source rather than a rescue of a bad
  // one. Three filters and a score.

  // Articles that carry a coordinate without being somewhere you could stand.
  // Overwhelmingly events -- a battle, a siege, a terrorist attack -- which are
  // pinned to where they happened and illustrated with a scroll painting or a
  // memorial plaque. Also the meta-articles ("List of...", "History of...")
  // and vehicles, which get a coordinate when they end up as a museum ship.
  readonly property var rejectArticle: new RegExp(
      "(rebellion|incident|\\bbattle\\b|\\bsiege\\b|\\bwar\\b|massacre|treaty"
    + "|election|disaster|\\bcrash\\b|bombing|\\battack\\b|\\briot|scandal"
    + "|murder|shooting|earthquake|\\bflood|explosion|derailment|hijack"
    + "|protest|\\bstrike\\b|championship|olympic|world cup|tournament"
    + "|^list of|^timeline of|^index of|^outline of|^history of|^culture of"
    + "|^economy of|^demographics of|^politics of|^transport in|^education in"
    + "|\\(disambiguation\\)|^(hms|uss|ss|mv|rms|hmas|hmcs) )", "i")

  // Filenames that are not photographs of anywhere. Coats of arms, flags, logos
  // and maps are what an administrative-division article uses when nobody has
  // photographed the place; the rest are documents and artwork.
  readonly property var rejectFile: new RegExp(
      "(\\bmap\\b|karte|carte|mapa|logo|coat.of.arms|wappen|escudo|\\bflag\\b"
    + "|bandera|blason|blazon|\\bseal\\b|emblem|\\bcrest\\b|\\bbadge\\b"
    + "|diagram|\\bplan\\b|\\bchart\\b|banner|poster|\\bscan\\b|drawing"
    + "|painting|portrait|\\bsvg\\b|screenshot|\\bicon\\b|placeholder"
    + "|no.image|\\bcover\\b|1[0-8]\\d\\d)", "i")

  // A close-up of a thing at a place is not a picture of the place. These do not
  // reject outright -- a detail shot of a famous facade is still guessable --
  // but they push a candidate below anything better in the same reply.
  readonly property var closeUpWords: new RegExp(
      "(interior|inside|\\bdetail|close.?up|macro|plaque|inscription|gravestone"
    + "|\\btomb\\b|\\bgrave\\b|statue of|bust of|\\bsign\\b|signage|\\bmenu\\b"
    + "|exhibit|artifact|artefact)", "i")

  // What a guessable photograph tends to be of. Anything matching gets lifted
  // above the rest of the same reply, which is what turns "a place" into "a
  // place you can actually recognise something in".
  readonly property var placeWords: new RegExp(
      "(\\bview\\b|panorama|skyline|street|avenue|boulevard|\\broad\\b|square"
    + "|plaza|piazza|bridge|castle|cathedral|church|temple|mosque|synagogue"
    + "|station|\\bpark\\b|garden|harbou?r|\\bport\\b|market|tower|palace"
    + "|monument|\\bcity\\b|\\btown\\b|village|district|quarter|beach|river"
    + "|lake|mountain|valley|centre|center|\\bhall\\b|museum|stadium|airport"
    + "|university|cityscape|aerial|waterfront|old.town)", "i")

  // The URL a photo may be downloaded from. Hardcoded host, hardcoded path
  // prefix, and a character set that leaves no room for a newline, a space or a
  // leading dash. This is the only gate between an API response and curl's argv.
  //
  // Every one of 254 thumbnails sampled across six cities was served from this
  // host, including the ones Wikipedia hands back with utm_* query parameters
  // appended -- which is why the character class has to admit ? & and =.
  readonly property var allowedPhotoUrl:
      /^https:\/\/upload\.wikimedia\.org\/wikipedia\/commons\/[A-Za-z0-9._~:\/?#\[\]@!$&'()*+,;=%-]{1,700}$/

  // A Commons filename is about to be spliced into a URL query and handed to
  // curl as argv. encodeURIComponent does the escaping and the value never
  // reaches a shell, so the only things worth refusing here are a length no
  // real filename has and the control characters -- a newline above all --
  // that could forge structure inside the request.
  //
  // Deliberately NOT a shell-metacharacter blocklist. An earlier revision also
  // refused quotes, ampersands and backticks, which sounds prudent and cost
  // 6.6% of real filenames when measured against 333 of them: every one a
  // legitimate French or Italian name -- Musee de l'homme, Pont de l'Alma,
  // Sant'Andrea al Quirinale. Refusing characters that were never dangerous on
  // this path silently deleted the best photographs in some of the best cities.
  function safeFileName(value) {
    var name = String(value === undefined || value === null ? "" : value)
    if (name.length === 0 || name.length > 240) return ""
    if (/[\u0000-\u001f\u007f]/.test(name)) return ""
    return name
  }

  function parseCandidates(raw) {
    var parsed = root.parseCappedJson(raw, root.wikiCapBytes)
    var pages = parsed && parsed.query && Array.isArray(parsed.query.pages)
        ? parsed.query.pages : []

    var out = []
    for (var i = 0; i < pages.length && out.length < root.maxCandidates; i++) {
      var page = pages[i]
      if (!page || typeof page !== "object") continue

      var thumb = page.thumbnail
      var coords = Array.isArray(page.coordinates) && page.coordinates.length > 0
          ? page.coordinates[0] : null
      if (!thumb || !coords) continue

      var fileName = root.safeFileName(page.pageimage)
      if (fileName === "") continue

      // The extension is checked on the FILE, not on the thumbnail URL.
      // Wikimedia renders an SVG thumbnail as a PNG, so a coat of arms arrives
      // with PNG magic bytes and sails through the download check -- 14 of 254
      // sampled lead images were SVG, and every one was a crest or a logo.
      if (!/\.(jpe?g|png)$/i.test(fileName)) continue

      var articleTitle = String(page.title || "")
      if (articleTitle === "") continue
      if (root.rejectArticle.test(articleTitle)) continue
      if (root.rejectFile.test(fileName)) continue

      // The thumbnail is capped at 1280 wide, so a small one means the original
      // was small -- usually a thumbnail-sized upload rather than a photograph.
      var width = Number(thumb.width)
      var height = Number(thumb.height)
      if (!(width >= 640) || !(height >= 400)) continue

      var latitude = Number(coords.lat)
      var longitude = Number(coords.lon)
      if (!isFinite(latitude) || !isFinite(longitude)) continue
      if (Math.abs(latitude) > 90 || Math.abs(longitude) > 180) continue

      var url = String(thumb.source || "")
      if (!root.allowedPhotoUrl.test(url)) continue

      var haystack = articleTitle + " " + fileName
      var score = 0
      if (root.placeWords.test(haystack)) score += 2
      if (root.closeUpWords.test(haystack)) score -= 3
      // Landscape, and large. Both correlate with a photograph taken to show
      // somewhere rather than to document an object.
      if (width > height) score += 1
      if (width >= 1000) score += 1

      out.push({
        lat: latitude,
        lon: longitude,
        url: url,
        file: fileName,
        score: score,
        // Sanitised as it enters, so nothing downstream -- including anything
        // added later -- has to remember to do it.
        title: Sanitise.plainOneLine(articleTitle, 90)
      })
    }
    return out
  }

  // Picks one candidate, preferring the most place-like.
  //
  // Not simply the highest score: taking the single best would make a city show
  // the same photograph every time it came up, because the ranking is
  // deterministic. Everything within one point of the best is eligible, and the
  // choice among those is random -- so the game stays varied while still never
  // reaching for the worst thing in the reply when it has a better option.
  function chooseCandidate(candidates) {
    var best = -Infinity
    var i
    for (i = 0; i < candidates.length; i++)
      if (candidates[i].score > best) best = candidates[i].score

    var shortlist = []
    for (i = 0; i < candidates.length; i++)
      if (candidates[i].score >= best - 1) shortlist.push(candidates[i])

    return shortlist[Math.floor(Math.random() * shortlist.length)]
  }

  // Which slot the reply in flight belongs to: "current" for the round the
  // player is waiting on, "pending" for the one being fetched behind the reveal.
  property string fetchTarget: "current"
  property var fetchPlace: null
  property bool fetchWidened: false

  Process {
    id: wikiProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var candidates = root.parseCandidates(text)
          if (candidates.length < 3 && !root.fetchWidened
              && root.searchRadiusKm * 1000 < root.maxRadiusMetres) {
            // A thin result usually means a tight radius over a quarter nobody
            // has written about. Widening to the API's ceiling is cheaper than
            // throwing the city away -- and it is a genuine widen only when the
            // player has set the radius below that ceiling, which is why it is
            // guarded rather than attempted unconditionally.
            root.fetchWidened = true
            root.requestPlaces(root.fetchPlace, root.maxRadiusMetres)
            return
          }
          if (candidates.length === 0) throw new Error("no usable photos")
          root.beginDownload(root.chooseCandidate(candidates))
        } catch (error) {
          root.fetchFailed("No photos found near there.")
        }
      }
    }
    onExited: function (exitCode) {
      // head masks curl's status, so a non-zero exit here is the outer timeout
      // or a failure to spawn. onStreamFinished has already run for the success
      // path; guard against reporting twice.
      if (exitCode !== 0 && root.phase === "loading" && root.round === null)
        root.fetchFailed("Could not reach Wikimedia Commons.")
    }
  }

  // Download, magic-check and prune, in one script so the bytes that are checked
  // are the bytes that are kept.
  //
  //   $1 the private directory   $2 the URL   $3 the user agent
  //
  // The file is created by mktemp inside a directory that has just been
  // re-verified as ours, so its name cannot be guessed or pre-created. curl
  // enforces the byte ceiling itself with --max-filesize, before anything is
  // written, and the first four bytes are then checked against the two formats
  // this plugin will render. A reply that is not a JPEG or a PNG is deleted
  // rather than handed to an image decoder.
  //
  // Two prunes, because each catches what the other misses.
  //
  // By age, for files an earlier session left behind. By count, for this one:
  // an age bound alone lets a long sitting accumulate a photo per round for an
  // hour, and these live in tmpfs, which is RAM.
  //
  // Two existing files are kept, not one, and the prune runs before mktemp, so
  // the ceiling is three: during a reveal the round on screen and the one being
  // prefetched behind it are both live, and this run is about to add a third.
  // Pruning harder would delete a photo that is about to be shown.
  //
  // LC_ALL=C is pinned on both the find and the sort: %T@ is printed with a dot
  // as its decimal separator, and a numeric sort under a locale that uses a
  // comma would order the timestamps wrongly and delete the newest files. The
  // names come from mktemp, so they hold no whitespace for `read -r` to trip on.
  readonly property string downloadScript:
    'd="$1"; u="$2"; ua="$3"\n' +
    '[ -d "$d" ] && [ ! -L "$d" ] && [ -O "$d" ] || exit 1\n' +
    'find "$d" -maxdepth 1 -type f -name "photo.*" -mmin +60 -delete 2>/dev/null\n' +
    // A byte ceiling beside the row ceiling. `tail -n +3` bounds how many
    // filenames survive, not how many bytes `find` and `sort` had to hold to
    // decide -- and a row cap is not a byte cap. This directory is ours and
    // 0700, so the list is short in practice; the bound is here so that stays
    // true by construction rather than by assumption.
    'LC_ALL=C find "$d" -maxdepth 1 -type f -name "photo.*" -printf "%T@\\t%p\\n" 2>/dev/null \\\n' +
    '  | head -c 65537 \\\n' +
    '  | LC_ALL=C sort -rn | tail -n +3 | cut -f2- \\\n' +
    '  | while IFS= read -r old; do rm -f -- "$old"; done\n' +
    't=$(mktemp "$d/photo.XXXXXXXX") || exit 1\n' +
    'chmod 600 -- "$t" || { rm -f -- "$t"; exit 1; }\n' +
    // Two independent ceilings on the body, because they fail in different
    // places. --max-filesize aborts before the transfer starts when the server
    // declares a Content-Length; `head -c` bounds what is written whatever the
    // server declares, including a chunked reply that declares nothing.
    //
    // Measured on curl 8.21 against a chunked server with no Content-Length:
    // --max-filesize did abort at exactly the cap (exit 63). It is kept as the
    // early bound, and `head -c` is what makes the ceiling independent of which
    // curl the user happens to have.
    //
    // cap+1 is requested so "exactly at the ceiling" stays distinguishable from
    // "cut off", and a body that reaches cap+1 is deleted rather than shown: a
    // truncated JPEG that still has a valid header is worse than no photograph,
    // because it is silently wrong.
    //
    // The size is counted BY the pipeline rather than measured afterwards.
    // Writing the file and then asking the filesystem how big it is would be a
    // check followed by a separate open, which is the shape that lets a file be
    // replaced between the two -- so `wc -c` counts the same bytes `tee` wrote,
    // and there is no second look at the path.
    //
    // The header is read back through `dd iflag=nofollow` for the same reason
    // the state file is: it is the one read of that path, and it refuses to
    // follow a link rather than trusting that nothing could have put one there.
    //
    // Thirty-two bytes, not four. The first four still decide the format, but a
    // PNG's declared width and height live at bytes 16..23 and they are what
    // actually bounds the decode -- see photoMaxPixels for the measurements and
    // for why Image.sourceSize does not. One read covers both questions, so the
    // bytes that decide the format are the same bytes that decide the size.
    //
    // `od -v` matters: without it od collapses a run of identical input lines to
    // a `*`, and a 32-byte window of a PNG can easily hold one. The collapsed
    // output would not match either arm below and every image would be refused.
    'size=$(curl -fsS --proto "=https" --max-time 20 --max-filesize ' + photoCapBytes + ' \\\n' +
    '        -A "$ua" -- "$u" \\\n' +
    '        | head -c ' + (photoCapBytes + 1) + ' | tee "$t" | wc -c)\n' +
    '[ "$size" -gt 0 ] || { rm -f -- "$t"; exit 2; }\n' +
    '[ "$size" -le ' + photoCapBytes + ' ] || { rm -f -- "$t"; exit 4; }\n' +
    'head=$(dd if="$t" iflag=nofollow,nonblock bs=32 count=1 status=none \\\n' +
    '        | od -An -tx1 -v | tr -d " \\n")\n' +
    'case "$head" in\n' +
    // JPEG needs no dimension check: Qt scales it during load, so the source
    // size is never held in full. Measured at +4 MiB for an 8000x8000 JPEG.
    '  ffd8ff??*) ;;\n' +
    // PNG, with the 13-byte IHDR where the signature says it must be. Anchoring
    // on the full 8-byte signature and on the IHDR tag is what makes bytes
    // 16..23 the dimensions rather than whatever happens to sit at that offset.
    '  89504e470d0a1a0a????????49484452*)\n' +
    '    w=$(( 0x$(printf %s "$head" | cut -c33-40) ))\n' +
    '    h=$(( 0x$(printf %s "$head" | cut -c41-48) ))\n' +
    // Fail closed on anything that did not parse to a plain number. A shell
    // whose arithmetic refused the hex constant lands here rather than falling
    // through with an empty value.
    '    case "$w$h" in \'\'|*[!0-9]*) rm -f -- "$t"; exit 5 ;; esac\n' +
    '    [ "$w" -ge 1 ] && [ "$h" -ge 1 ] || { rm -f -- "$t"; exit 5; }\n' +
    // Both sides are bounded BEFORE they are multiplied. A PNG may declare up
    // to 2^32-1 on each axis, and 4294967295 squared overflows a 64-bit
    // arithmetic and can come back negative -- which would pass a naive
    // less-than test. Bounding each side first keeps the product under 2^24.
    '    [ "$w" -le ' + photoMaxDim + ' ] && [ "$h" -le ' + photoMaxDim + ' ] \\\n' +
    '      || { rm -f -- "$t"; exit 5; }\n' +
    '    [ $(( w * h )) -le ' + photoMaxPixels + ' ] || { rm -f -- "$t"; exit 5; }\n' +
    '    ;;\n' +
    '  *) rm -f -- "$t"; exit 3 ;;\n' +
    'esac\n' +
    'printf %s "$t" | head -c ' + (pathCapBytes + 1) + '\n'

  property var downloadCandidate: null

  Process {
    id: photoProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var path = String(text || "").replace(/[\r\n]+$/, "")
        // The path came back out of our own script, but it is still checked --
        // for length first, because a truncated path keeps the prefix that the
        // containment check looks at, and then for containment.
        if (path.length > root.pathCapBytes
            || root.cacheDir === "" || path.indexOf(root.cacheDir + "/photo.") !== 0) {
          root.fetchFailed("The photo did not arrive intact.")
          return
        }
        root.deliverRound(path)
      }
    }
    onExited: function (exitCode) {
      if (exitCode === 0) return
      root.fetchFailed(exitCode === 3 ? "That file was not an image."
                     : exitCode === 4 ? "That photo was too large."
                     // Distinct from 4: the file was small, but its header
                     // declared more pixels than this plugin will decode.
                     : exitCode === 5 ? "That photo was too large to decode."
                                      : "Could not download the photo.")
    }
  }

  // ----------------------------------------------------------- attribution
  //
  // Wikipedia's pageimages gives a usable thumbnail but no licence, and these
  // photographs are almost all CC-licensed, so the credit has to be asked for
  // separately. It is asked for at reveal, not at selection: the player is
  // looking at the answer by then, so a 361-byte round trip costs nothing they
  // can perceive, and keeping it off the selection path is part of what makes
  // the first photo appear quickly.
  //
  // A credit that never arrives is not an error. The photo, the place and the
  // score are all still right; only the by-line is missing, and saying so is
  // better than blocking the reveal on it.
  property string roundCredit: ""
  property string roundLicence: ""

  Process {
    id: attrProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = root.parseCappedJson(text, root.attrCapBytes)
          var pages = parsed && parsed.query && Array.isArray(parsed.query.pages)
              ? parsed.query.pages : []
          if (pages.length === 0 || pages[0].missing) return

          var info = Array.isArray(pages[0].imageinfo) && pages[0].imageinfo.length > 0
              ? pages[0].imageinfo[0] : null
          if (!info) return
          var extra = info.extmetadata || {}

          // The Commons Artist field is literal HTML by design -- a measured
          // value was an anchor tag wrapping the photographer's name -- so
          // creditText unwraps tags to their text rather than deleting them,
          // which is the difference between showing "Nina R" and showing
          // nothing at all.
          root.roundCredit = Sanitise.creditText(extra.Artist ? extra.Artist.value : "", 90)
          root.roundLicence = Sanitise.licenceText(
              extra.LicenseShortName ? extra.LicenseShortName.value : "")
        } catch (error) {
          root.roundCredit = ""
          root.roundLicence = ""
        }
      }
    }
  }

  function requestAttribution() {
    root.roundCredit = ""
    root.roundLicence = ""
    if (!root.round || !root.round.file || attrProcess.running) return
    attrProcess.command = root.cappedCurl(
        root.attributionUrl(root.round.file), root.attrCapBytes, 10)
    attrProcess.running = true
  }

  // ------------------------------------------------------------- round flow

  // Returns { row, index } rather than the row alone, because the index is what
  // records the city as used -- and a round prefetched before a game starts has
  // to be able to carry that record across the reset that starting performs.
  function pickPlace() {
    if (root.poolSize <= 0) return null
    // Every city in the tier is eligible except the ones already seen this
    // game. Sampling with retries rather than building an exclusion list keeps
    // this O(1) in the common case; the pool is at least 150 and a game is at
    // most 10 rounds, so the loop cannot run long.
    for (var attempt = 0; attempt < 60; attempt++) {
      var index = Math.floor(Math.random() * root.poolSize)
      if (root.usedPlaces.indexOf(index) >= 0) continue
      var used = root.usedPlaces.slice(0)
      used.push(index)
      root.usedPlaces = used
      return { row: root.places[index], index: index }
    }
    var fallback = Math.floor(Math.random() * root.poolSize)
    return { row: root.places[fallback], index: fallback }
  }

  function requestPlaces(pick, radiusMetres) {
    if (!pick || !pick.row) {
      root.fetchFailed("No cities available.")
      return
    }
    root.fetchPlace = pick

    var now = Date.now()
    var wait = Math.max(0, root.minRequestGapMs - (now - root.lastRequestMs))

    // Reassigning `command` on a Process that has not exited yet is undefined
    // behaviour, and the widen-radius retry is issued from inside
    // onStreamFinished -- which runs *before* the process exits. Waiting is not
    // an optimisation here; it is what makes that path work on purpose rather
    // than by accident.
    if (wikiProcess.running || photoProcess.running) wait = Math.max(wait, 250)

    if (wait > 0) {
      // Queued, not dropped and not sent early: ten frantic clicks on Skip
      // collapse into one request rather than ten. The timer calls back into
      // this function, so a still-running process simply defers again.
      gapTimer.pendingRadius = radiusMetres
      gapTimer.interval = wait
      gapTimer.restart()
      return
    }
    root.lastRequestMs = now
    wikiProcess.command = root.cappedCurl(
        root.placesUrl(pick.row[2], pick.row[3], radiusMetres), root.wikiCapBytes, 15)
    wikiProcess.running = true
  }

  Timer {
    id: gapTimer
    property real pendingRadius: 10000
    repeat: false
    onTriggered: root.requestPlaces(root.fetchPlace, pendingRadius)
  }

  function beginDownload(candidate) {
    if (root.cacheDir === "") {
      root.fetchFailed("No private directory to cache photos in.")
      return
    }
    root.downloadCandidate = candidate
    photoProcess.command = ["timeout", "-k", "2", "30", "sh", "-c", root.downloadScript, "sh",
                            root.cacheDir, candidate.url, root.userAgent]
    photoProcess.running = true
  }

  function deliverRound(path) {
    var candidate = root.downloadCandidate
    if (!candidate) return
    var nearest = GeoMath.nearestPlace(root.places, candidate.lat, candidate.lon)

    var built = {
      lat: candidate.lat,
      lon: candidate.lon,
      title: candidate.title,
      // Kept so the reveal can ask Commons who took it, and so a round
      // prefetched before the game began can record its city as used.
      file: candidate.file,
      placeIndex: root.fetchPlace && root.fetchPlace.index >= 0
          ? root.fetchPlace.index : -1,
      path: path,
      city: nearest ? Sanitise.plainOneLine(nearest.name, 60) : "",
      country: nearest ? Sanitise.plainOneLine(nearest.country, 60) : "",
      cityKm: nearest ? nearest.distanceKm : NaN
    }

    if (root.fetchTarget === "pending") {
      root.pendingRound = built
      return
    }

    root.round = built
    root.guess = null
    root.statusText = ""
    root.phase = "guessing"
  }

  // How many different cities one round may try before giving up. Wikipedia's
  // coverage is uneven -- a city can have articles whose lead images are all
  // crests, or barely any articles at all -- and on hard difficulty, where the
  // pool runs down to towns of a few hundred thousand, that is common rather
  // than rare. Dead-ending the round on the first miss would make the harder
  // settings feel broken when they are merely thinly written about.
  readonly property int maxFetchAttempts: 5
  property int fetchAttempts: 0

  function fetchFailed(message) {
    if (root.fetchTarget === "pending") {
      // A failed prefetch is not worth telling anyone about: Next simply
      // fetches for itself when it is pressed.
      root.pendingFailed = true
      return
    }

    if (root.fetchAttempts < root.maxFetchAttempts) {
      root.fetchAttempts += 1
      root.fetchWidened = false
      root.statusText = ""
      root.phase = "loading"
      root.requestPlaces(root.pickPlace(), root.searchRadiusKm * 1000)
      return
    }

    root.statusText = message
    root.phase = "error"
  }

  function fetchRound(target) {
    root.fetchTarget = target
    root.fetchWidened = false
    root.fetchAttempts = 0
    if (target === "current") {
      root.round = null
      root.guess = null
      root.statusText = ""
      // Cleared here rather than at each caller, so Skip and the retry path get
      // it too -- otherwise the previous round's photographer stays on screen
      // underneath the next round's photograph.
      root.roundCredit = ""
      root.roundLicence = ""
      root.phase = "loading"
    }
    root.requestPlaces(root.pickPlace(), root.searchRadiusKm * 1000)
  }

  function startGame() {
    if (root.cacheDir === "") {
      root.statusText = "There is nowhere private to cache photos, so the game cannot start. "
          + "Neither XDG_RUNTIME_DIR nor ~/.cache was usable."
      root.phase = "error"
      return
    }
    // A round fetched while the panel sat on the start screen is the whole
    // point of that prefetch: Start should show a photograph, not a spinner.
    // It is taken before the reset and put back afterwards, and its city is
    // seeded into usedPlaces so the reset cannot let the same place come round
    // again later in the game.
    var carried = root.pendingRound

    root.roundIndex = 0
    root.totalScore = 0
    root.results = []
    root.usedPlaces = carried && carried.placeIndex >= 0 ? [carried.placeIndex] : []
    root.pendingRound = null
    root.pendingFailed = false
    root.roundCredit = ""
    root.roundLicence = ""
    root.mapMode = root.defaultView
    if (mapLoader.item) mapLoader.item.resetView()

    if (carried) {
      root.round = carried
      root.guess = null
      root.statusText = ""
      root.phase = "guessing"
      return
    }
    root.fetchRound("current")
  }

  function placeGuess(latitude, longitude) {
    if (root.phase !== "guessing") return
    root.guess = { lat: latitude, lon: longitude }
  }

  // Arrow keys (and hjkl, which PanelKeyCatcher folds into the same signal)
  // nudge the pin, so a round can be played without ever reaching for the
  // mouse. On a desktop driven by the keyboard, a game that demands a pointer
  // is a game half the users cannot play.
  //
  // The first press drops the pin wherever the view is centred, so there is
  // always something to move; after that each press walks it. The step shrinks
  // as the map is zoomed in, so the same key is a coarse sweep at world scale
  // and a fine adjustment close up.
  function nudgeGuess(dx, dy) {
    if (root.phase !== "guessing") return
    if (!mapLoader.item) return

    if (!root.guess) {
      root.guess = { lat: mapLoader.item.centreLat, lon: mapLoader.item.centreLon }
      return
    }

    var step = 5 / Math.max(1, mapLoader.item.zoom)
    root.guess = {
      // Clamped rather than wrapped: walking off the top of the world and
      // reappearing at the bottom is disorienting, and the poles are a real
      // place a guess can legitimately sit.
      lat: GeoMath.clamp(root.guess.lat - dy * step, -90, 90),
      // Wrapped, because east of the antimeridian genuinely is west of it.
      lon: GeoMath.wrapLongitude(root.guess.lon + dx * step)
    }
  }

  function confirmGuess() {
    if (root.phase !== "guessing" || !root.guess || !root.round) return

    var km = GeoMath.haversineKm(root.guess.lat, root.guess.lon, root.round.lat, root.round.lon)
    var score = GeoMath.scoreFor(km)

    var results = root.results.slice(0)
    results.push({ km: km, score: score, city: root.round.city, country: root.round.country })
    // The results list is bounded by roundsPerGame, which is itself clamped to
    // 10, but the slice makes that true of the array rather than of the caller.
    root.results = results.slice(0, 10)
    root.totalScore += score

    root.phase = "revealed"
    root.requestAttribution()
    if (mapLoader.item) mapLoader.item.frameResult()

    // Fetch the next round now, while the reveal is being read, so Next is
    // instant. Skipped on the last round, where there is nothing to fetch.
    if (root.roundIndex + 1 < root.roundsPerGame) {
      root.pendingRound = null
      root.pendingFailed = false
      root.fetchRound("pending")
    }
  }

  function nextRound() {
    if (root.phase !== "revealed") return

    if (root.roundIndex + 1 >= root.roundsPerGame) {
      root.gamesPlayed += 1
      if (root.totalScore > root.bestScore) root.bestScore = root.totalScore
      root.saveState()
      root.phase = "summary"
      return
    }

    root.roundIndex += 1
    root.guess = null
    root.roundCredit = ""
    root.roundLicence = ""
    if (mapLoader.item) mapLoader.item.resetView()

    if (root.pendingRound) {
      root.round = root.pendingRound
      root.pendingRound = null
      root.statusText = ""
      root.phase = "guessing"
      return
    }
    // The prefetch failed or has not landed yet. Either way this is now the
    // request the player is waiting on.
    root.round = null
    root.phase = "loading"
    if (!wikiProcess.running && !photoProcess.running) root.fetchRound("current")
    else root.fetchTarget = "current"
  }

  // Fetches the first round while the player is still looking at the start
  // screen, so pressing Start shows a photograph instead of a spinner.
  //
  // This is the fix for "the first image takes a long time to load". Nothing
  // about that request was slow; it simply had not been made yet. Everything
  // after the first round was already instant, because a reveal starts the next
  // round's fetch behind it -- the first round was the only one with nothing
  // running ahead of it.
  //
  // Deliberately triggered by opening the panel rather than by the shell
  // starting. Opening the game is the player saying they intend to play; the
  // shell mounting this plugin at login is not, and spending a request and a
  // photograph on everyone who never opens it would be rude.
  function warmFirstRound() {
    if (root.phase !== "idle") return
    if (root.pendingRound || root.cacheDir === "") return
    if (wikiProcess.running || photoProcess.running) return

    // A warm belongs to a game that has not started, so the used-city list
    // starts empty. Without this, opening and closing the panel while the
    // network is down would push one more city onto that list every time and
    // eventually leave the pool with nothing it was willing to draw.
    root.usedPlaces = []
    root.fetchRound("pending")
  }

  onOpenedChanged: {
    if (root.opened) Qt.callLater(root.warmFirstRound)
  }

  function skipRound() {
    if (root.phase !== "guessing" && root.phase !== "error") return
    root.fetchRound("current")
  }

  function abandonGame() {
    root.phase = "idle"
    root.round = null
    root.pendingRound = null
    root.guess = null
    root.statusText = ""
    root.roundCredit = ""
    root.roundLicence = ""
  }

  // ---------------------------------------------------------------- the view

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    padding: Style.space(14)
    // fittedContentWidth clamps to the screen, so these are the size the game
    // would like rather than a size it insists on: on a small display the board
    // shrinks instead of overflowing.
    contentWidth: panel.fittedContentWidth(Style.space(940))
    contentHeight: panel.fittedContentHeight(Style.space(660), Style.space(660))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onMoveRequested: function (dx, dy) { root.nudgeGuess(dx, dy) }
      onTextKey: function (key) {
        // One-key view switch, so the map/globe toggle is reachable without the
        // mouse too.
        if (key === "m") root.mapMode = "map"
        else if (key === "g") root.mapMode = "globe"
      }
      onReturnRequested: {
        if (root.phase === "guessing" && root.guess) root.confirmGuess()
        else if (root.phase === "revealed") root.nextRound()
        else if (root.phase === "error") root.skipRound()
        else if (root.phase === "idle" || root.phase === "summary") root.startGame()
      }

      Column {
        anchors.fill: parent
        spacing: Style.space(10)

        // ------------------------------------------------------------ header
        Item {
          width: parent.width
          height: Math.max(titleColumn.implicitHeight, headerControls.implicitHeight)

          Column {
            id: titleColumn
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - headerControls.width - Style.space(12)
            spacing: Style.space(2)

            Text {
              width: parent.width
              text: "GLOBE GUESSER"
              textFormat: Text.PlainText
              color: root.bar ? root.bar.foreground : Color.popups.text
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              text: {
                if (root.phase === "idle")
                  return root.bestScore > 0
                    ? "Best " + GeoMath.formatNumber(root.bestScore) + " · "
                      + root.gamesPlayed + (root.gamesPlayed === 1 ? " game played" : " games played")
                    : "Guess where the photo was taken"
                if (root.phase === "summary") return "Game over"
                return "Round " + (root.roundIndex + 1) + " of " + root.roundsPerGame
                     + " · " + GeoMath.formatNumber(root.totalScore) + " points"
              }
              textFormat: Text.PlainText
              color: Qt.rgba(root.bar ? root.bar.foreground.r : 0.8,
                             root.bar ? root.bar.foreground.g : 0.8,
                             root.bar ? root.bar.foreground.b : 0.8, 0.65)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }
          }

          Row {
            id: headerControls
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)
            visible: root.phase === "guessing" || root.phase === "revealed"

            Button {
              text: "Map"
              selected: root.mapMode === "map"
              onClicked: root.mapMode = "map"
            }

            Button {
              text: "Globe"
              selected: root.mapMode === "globe"
              onClicked: root.mapMode = "globe"
            }
          }
        }

        // -------------------------------------------------------------- board
        Item {
          id: board
          width: parent.width
          height: parent.height - y - footer.height - Style.space(20)

          // ---- start screen, errors, and the summary all share this space
          Column {
            anchors.centerIn: parent
            width: Math.min(parent.width - Style.space(40), Style.space(520))
            spacing: Style.space(12)
            visible: root.phase === "idle" || root.phase === "error" || root.phase === "summary"

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.PlainText
              text: {
                if (root.phase === "error") return root.statusText
                if (root.phase === "summary")
                  return GeoMath.formatNumber(root.totalScore) + " out of "
                       + GeoMath.formatNumber(root.roundsPerGame * 5000)
                return "A photograph, somewhere on Earth. Click the map or spin the globe "
                     + "to say where you think it was taken."
              }
              wrapMode: Text.WordWrap
              color: root.bar ? root.bar.foreground : Color.popups.text
              font.family: Style.font.family
              font.pixelSize: root.phase === "summary" ? Style.font.display : Style.font.body
              font.bold: root.phase === "summary"
            }

            // Per-round breakdown, only on the summary.
            Column {
              width: parent.width
              spacing: Style.space(3)
              visible: root.phase === "summary"

              Repeater {
                model: root.results

                Item {
                  required property var modelData
                  required property int index
                  width: parent.width
                  height: roundLine.implicitHeight + Style.space(4)

                  Text {
                    id: roundLine
                    anchors.left: parent.left
                    width: parent.width - roundScore.width - Style.space(10)
                    textFormat: Text.PlainText
                    text: (index + 1) + ". " + GeoMath.formatDistance(modelData.km)
                        + (modelData.city !== "" ? " — " + modelData.city + ", " + modelData.country : "")
                    color: Qt.rgba(root.bar ? root.bar.foreground.r : 0.8,
                                   root.bar ? root.bar.foreground.g : 0.8,
                                   root.bar ? root.bar.foreground.b : 0.8, 0.75)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }

                  Text {
                    id: roundScore
                    anchors.right: parent.right
                    textFormat: Text.PlainText
                    text: GeoMath.formatNumber(modelData.score)
                    color: root.bar ? root.bar.foreground : Color.popups.text
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                  }
                }
              }
            }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.PlainText
              visible: root.phase === "summary" && root.totalScore >= root.bestScore && root.totalScore > 0
              text: "A new best."
              color: root.bar ? root.bar.foreground : Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
          }

          // ---- the playing board
          //
          // Photo and map side by side, not stacked.
          //
          // Stacking was right while the map was equirectangular: that
          // projection is twice as wide as it is tall, so it filled a wide,
          // short pane exactly. Mercator's world is SQUARE, and a square fitted
          // into a pane three times wider than it is tall can only ever occupy
          // the middle third of it -- the map came out 285 px across in a 940 px
          // panel, with the rest of the width empty.
          //
          // Two nearly-square halves suit both: the map gets a pane it can fill,
          // and a photograph shown whole -- which it now is -- fits a tall pane
          // better than a wide one, because portrait shots stop being reduced to
          // a sliver.
          Row {
            anchors.fill: parent
            spacing: Style.space(8)
            visible: root.phase === "loading" || root.phase === "guessing" || root.phase === "revealed"

            PhotoPane {
              id: photo
              height: parent.height
              width: Math.round((parent.width - parent.spacing) * 0.46)
              photoPath: root.round ? root.round.path : ""
              loading: root.phase === "loading"
              showAttribution: root.phase === "revealed"
              photoTitle: root.round ? root.round.title : ""
              // Fetched separately at reveal, so these fill in a moment after
              // the answer appears rather than arriving with the photograph.
              photoCredit: root.roundCredit
              photoLicence: root.roundLicence
              foreground: root.bar ? root.bar.foreground : Color.popups.text
            }

            Item {
              height: parent.height
              width: parent.width - photo.width - parent.spacing

              // The 130 KiB of country outlines are imported by GlobeMap.qml, so
              // they stay out of the QML engine until someone actually plays.
              // active latches true and never goes back: a game in progress must
              // not lose its map because the panel was closed for a moment.
              Loader {
                id: mapLoader
                anchors.fill: parent
                active: false
                source: Qt.resolvedUrl("GlobeMap.qml")

                onLoaded: {
                  // The map's tiles are downloaded and checked before they are
                  // decoded, so the layer needs the private directory and the
                  // user agent. Bound rather than assigned: cacheDir is filled
                  // in by a subprocess and is usually still "" at this point.
                  item.cacheDir = Qt.binding(function () { return root.cacheDir })
                  item.userAgent = Qt.binding(function () { return root.userAgent })
                  item.apiKey = Qt.binding(function () { return root.cartoApiKey })
                  item.mode = Qt.binding(function () { return root.mapMode })
                  item.guess = Qt.binding(function () { return root.guess })
                  item.answer = Qt.binding(function () {
                    return root.phase === "revealed" && root.round
                        ? { lat: root.round.lat, lon: root.round.lon } : null
                  })
                  item.interactive = Qt.binding(function () { return root.phase === "guessing" })
                  item.landStroke = Qt.binding(function () {
                    return root.bar ? root.bar.foreground : Color.popups.text
                  })
                  item.guessColor = Qt.binding(function () {
                    return root.bar ? root.bar.foreground : Color.popups.text
                  })
                  item.guessPlaced.connect(root.placeGuess)
                }
              }

              // The map is built the moment the panel opens, not when a round
              // starts.
              //
              // Loading it pulls 130 KiB of outlines into the QML engine and
              // paints 10,340 points for the first time, and that work used to
              // land in the same instant as the first photograph's decode --
              // two expensive things competing on the GUI thread at exactly the
              // moment the player is waiting. Opening the panel happens seconds
              // before Start is pressed, and the work is invisible there.
              //
              // active latches true and never goes back: a game in progress
              // must not lose its map because the panel was closed for a moment.
              Connections {
                target: root
                function onOpenedChanged() {
                  if (root.opened && !mapLoader.active) mapLoader.active = true
                }
                function onPhaseChanged() {
                  if (!mapLoader.active
                      && (root.phase === "loading" || root.phase === "guessing"))
                    mapLoader.active = true
                }
              }

              Text {
                anchors.centerIn: parent
                visible: !mapLoader.active
                text: "Loading the world…"
                textFormat: Text.PlainText
                color: Qt.rgba(root.bar ? root.bar.foreground.r : 0.8,
                               root.bar ? root.bar.foreground.g : 0.8,
                               root.bar ? root.bar.foreground.b : 0.8, 0.6)
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }
            }
          }
        }

        // ------------------------------------------------------------ footer
        Item {
          id: footer
          width: parent.width
          height: footerRow.implicitHeight

          Text {
            id: verdict
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - footerRow.width - Style.space(12)
            textFormat: Text.PlainText
            visible: root.phase === "revealed" || root.phase === "guessing"
            text: {
              if (root.phase === "guessing")
                return root.guess
                  ? "Arrow keys nudge the pin · Enter confirms"
                  : "Click the map, or press an arrow key · M map, G globe"
              if (!root.round || root.results.length === 0) return ""
              var last = root.results[root.results.length - 1]
              var where = root.round.city !== ""
                  ? (root.round.cityKm < 5
                      ? root.round.city + ", " + root.round.country
                      : Math.round(root.round.cityKm) + " km from " + root.round.city
                        + ", " + root.round.country)
                  : ""
              return GeoMath.formatDistance(last.km) + " away"
                   + (where !== "" ? " — " + where : "")
                   + " · " + GeoMath.formatNumber(last.score) + " points"
            }
            color: Qt.rgba(root.bar ? root.bar.foreground.r : 0.8,
                           root.bar ? root.bar.foreground.g : 0.8,
                           root.bar ? root.bar.foreground.b : 0.8, 0.8)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          Row {
            id: footerRow
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            Button {
              visible: root.phase === "guessing" || root.phase === "error"
              text: root.phase === "error" ? "Try another" : "Skip"
              onClicked: root.skipRound()
            }

            Button {
              visible: root.phase === "guessing" || root.phase === "revealed"
                       || root.phase === "loading" || root.phase === "error"
              text: "Give up"
              onClicked: root.abandonGame()
            }

            Button {
              visible: root.phase === "guessing"
              text: "Confirm"
              active: root.guess !== null
              onClicked: root.confirmGuess()
            }

            Button {
              visible: root.phase === "revealed"
              text: root.roundIndex + 1 >= root.roundsPerGame ? "Finish" : "Next round"
              active: true
              onClicked: root.nextRound()
            }

            Button {
              visible: root.phase === "idle" || root.phase === "summary"
              text: root.phase === "idle" ? "Start" : "Play again"
              active: true
              onClicked: root.startGame()
            }
          }
        }
      }
    }
  }
}
