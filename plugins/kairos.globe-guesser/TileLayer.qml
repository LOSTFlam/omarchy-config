import QtQuick
import Quickshell.Io
import "GeoMath.js" as GeoMath
import "Sanitise.js" as Sanitise

// OpenStreetMap raster tiles for the flat map.
//
// ---------------------------------------------------------------------------
// Why a tile is downloaded and checked rather than handed straight to Image
// ---------------------------------------------------------------------------
//
// An earlier revision pointed Image.source at the tile URL directly. The
// argument for it was that a tile URL contains nothing that came off the
// network -- a hardcoded host, a hardcoded style, and three integers GeoMath
// computed from the pane geometry -- so there is no input for anything to
// influence, and letting Qt fetch kept its pixmap cache, which is what makes
// panning back over ground already seen cost nothing.
//
// That argument is about the URL. It says nothing about the RESPONSE, and the
// response is the part that gets decoded. A tile is a PNG, and Qt only scales
// during load for JPEG; for a PNG it loads the source at its full declared size
// and scales afterwards, so sourceSize bounds the pixmap that is kept and not
// the allocation on the way to it. Measured under Qml Runtime 6.11.1, a 61 KiB
// PNG declaring 8000x8000 loaded into an Image with sourceSize set still peaked
// at 439.6 MiB -- inside the shared, long-lived shell process, and once per
// tile. Eighteen of those is not a number worth writing down.
//
// So the tile is fetched by the same kind of helper the photograph uses: a byte
// ceiling at the producer, a PNG signature check, and a refusal on the
// dimensions the header declares before anything decodes it. What Image is then
// given is a local file in a private directory whose size is already known.
//
// The pixmap cache is not lost, only moved. Qt still keys on the URL, and the
// URL is now a stable file:// path, so panning back is still free; the disk copy
// makes it free across a panel close as well, which it was not before.
//
// ---------------------------------------------------------------------------
// Why the model and the positions are separate
// ---------------------------------------------------------------------------
//
// Panning moves the map continuously but changes WHICH tiles are needed only
// when a whole new row or column comes into view. If the Repeater's model were
// recomputed from the view, every drag frame would hand it a fresh JS array,
// and a Repeater given a new array destroys and recreates every delegate it
// has -- eighteen Images torn down and rebuilt sixty times a second, visible as
// flicker and paid for in nothing.
//
// So the model is rebuilt only when the tile window changes, and each tile's
// position is a binding on the frame. Panning then moves two numbers.
Item {
  id: root

  // The GeoMath view object the map is currently drawn with.
  property var view: null

  // The private directory Panel.qml created and verified, or "" if there is
  // none. Without it there is nowhere safe to put a tile, so there are no tiles
  // -- see `healthy`, which reports that as unhealthy and lets the caller fall
  // back to the bundled outlines. A game that draws its own coastlines is a
  // better failure than one that writes downloaded bytes somewhere shared.
  property string cacheDir: ""

  // Wikimedia's user-agent policy is about Wikimedia, but identifying the
  // application is good manners to any tile provider. Threaded down from
  // Panel.qml so there is one string.
  property string userAgent: ""

  // The player's own CARTO basemap key, or "" for none -- which is the default.
  //
  // Empty is not a degraded mode, it is the designed one: no key means no tile
  // request is made at all and the bundled Natural Earth outlines are the map,
  // exactly as they are offline. Fetching without a key would not fail, which is
  // the whole problem -- since August 2026 CARTO answers an unauthenticated tile
  // request with a perfectly valid PNG that has "API KEY REQUIRED" stamped
  // across it. There is nothing for this layer to detect and nothing to fall
  // back from, so the choice has to be made before the request, not after it.
  property string apiKey: ""

  // Validated by GeoMath, which is where the alphabet is defined and where both
  // check suites already cover it. Anything that is not a key is "" and no tile
  // is ever requested.
  readonly property string validKey: GeoMath.tileKey(root.apiKey)

  // Whether tiles are wanted at all. Set false for the globe, which cannot use
  // them.
  //
  // This gates the computation, not just the drawing, and the difference
  // matters: an invisible Image still loads. Hiding the layer while leaving its
  // bindings live would mean spinning the globe kept moving the tile window,
  // rebuilding the model and fetching tiles nobody could see -- a steady stream
  // of requests for pixels that are never drawn.
  property bool active: true

  // How many tiles may exist at once. The ceiling is on what is BUILT, not on
  // what is drawn: every entry becomes an Image that decodes inside the shared
  // shell process, so an unbounded grid is an unbounded number of decodes. A
  // 940x330 pane needs about eighteen.
  property int maxTiles: 64

  // How many tiles one helper run may fetch, and how many stay on disk.
  //
  // The fetch cap is above maxTiles so a full window is always satisfiable in
  // one run. The disk cap is what stops a long session panning the world into
  // the cache: these files live in $XDG_RUNTIME_DIR, which is tmpfs, which is
  // RAM. 256 tiles of a measured 14 KiB each is about 3.5 MiB.
  readonly property int maxFetchPerRun: 96
  readonly property int maxTilesOnDisk: 256

  // A tile is 256x256 and nothing enforces that but the server. 512 is twice a
  // real tile, so it never rejects one, and it is the ceiling the helper refuses
  // on -- before the bytes reach a decoder rather than after.
  readonly property int tileMaxDim: 512

  // A tile measured 14029 bytes. 256 KiB is eighteen times that and is enforced
  // at the producer by `head -c`, so it holds for a chunked reply that declares
  // no length at all.
  readonly property int tileCapBytes: 262144

  // False once tiles have failed repeatedly without a single success -- offline,
  // the provider is down, or there is no private directory to put them in. The
  // caller shows the bundled vector outlines instead, so the game stays playable
  // rather than presenting a blank rectangle and no explanation.
  readonly property bool healthy:
      root.validKey !== "" && root.cacheDir !== ""
      && (root.failures < 8 || root.successes > 0)

  property int failures: 0
  property int successes: 0

  // Where the pane sits in tile units, right now. Changes every drag frame.
  readonly property var frame: (root.active && root.view)
      ? GeoMath.tileFrame(root.view) : null

  // Which tiles are needed. Changes only when the window moves by a whole tile,
  // which is what `frameKey` detects.
  readonly property string frameKey: root.frame
      ? root.frame.z + "/" + root.frame.iMin + "," + root.frame.iMax
                    + "/" + root.frame.jMin + "," + root.frame.jMax
      : ""

  property var tiles: []

  // Which tile names are on disk and have passed the header check.
  //
  // This describes the CURRENT window only, and is replaced wholesale each time
  // the helper reports -- it is not a growing record of everything ever fetched.
  // That distinction is load-bearing. The disk cache is pruned to
  // maxTilesOnDisk, so a set that only ever grew would go on claiming tiles that
  // pruning had since deleted; panning back over them would point an Image at a
  // file that is no longer there, and because the name was still listed nothing
  // would ever re-request it. The tile would be blank for the rest of the
  // session. Asking about the whole window every time and believing only the
  // answer is what makes the layer self-healing after a prune.
  //
  // Replaced rather than mutated for a second reason: a QML property change
  // signal fires on assignment, and editing the object in place would leave
  // every `source` binding looking at the old answer.
  property var have: ({})

  // A function, deliberately, and not a `readonly property ... : root.cacheDir + …`.
  //
  // That property was the first version and it did not work. cacheDir arrives
  // late -- Panel.qml has to create and verify the directory in a subprocess --
  // and the handler that reacts to its arrival ran while the derived property
  // was still holding the old empty value, because QML does not order a change
  // handler on a property against the re-evaluation of the bindings that depend
  // on it. The layer asked for tiles, saw no directory, gave up, and nothing
  // changed again to make it ask a second time: the map stayed on the bundled
  // outlines for the whole session.
  //
  // A function is computed at the moment it is called, so there is no stale
  // value to read. Bindings that call it still update, because QML records the
  // properties read during the call as dependencies.
  function tileDirPath() {
    return root.cacheDir === "" ? "" : root.cacheDir + "/tiles"
  }

  // Rebuilt on the rare event, not the common one. Going inactive drives
  // frameKey to "" and empties the model, so the Images are destroyed rather
  // than left loading in the background.
  function rebuild() {
    root.tiles = (root.active && root.view)
        ? GeoMath.tileGrid(root.view, root.maxTiles) : []
    root.requestWindow()
  }

  onFrameKeyChanged: root.rebuild()

  // A change handler only fires on a CHANGE, and the first frameKey is computed
  // during initialisation -- so without this the layer can come up with a valid
  // window and an empty model, and stay that way until the player happens to
  // pan far enough to cross a tile boundary.
  Component.onCompleted: root.rebuild()

  // The directory arrives asynchronously -- Panel.qml has to create and verify
  // it in a subprocess -- so the first rebuild usually runs before there is
  // anywhere to fetch into. Without this the map would stay on the outlines
  // until the next tile boundary was crossed.
  onCacheDirChanged: root.rebuild()

  // A key typed in, corrected, or cleared changes what the map can draw. Cleared
  // means the tiles already on screen are no longer ones this plugin is entitled
  // to show, so they go immediately rather than lingering until the next pan.
  onValidKeyChanged: {
    if (root.validKey === "") root.have = ({})
    root.rebuild()
  }

  function tileName(tile) {
    return tile.z + "-" + tile.x + "-" + tile.y
  }

  // The path a tile occupies once it has passed the check, or "" if it has not.
  //
  // Sanitise.localFileUrl is the guard on this sink, the same one PhotoPane uses
  // and covered by the same check suites: `source:` resolves file://, image://
  // and bare paths alike, and image:// reaches image providers inside the shell.
  function tileSource(tile) {
    var dir = root.tileDirPath()
    var name = root.tileName(tile)
    if (dir === "" || !root.have[name]) return ""
    return Sanitise.localFileUrl(dir + "/" + name + ".png")
  }

  function noteFailure() {
    // Bounded so a long session offline cannot count upwards forever.
    if (root.failures < 1000) root.failures += 1
  }

  function noteSuccess() {
    if (root.successes < 1000) root.successes += 1
    root.failures = 0
  }

  // ------------------------------------------------------------- the fetcher
  //
  //   $1 the private directory   $2 the user agent   $3 the fixed URL prefix
  //   $4.. tile names, each "z-x-y"
  //
  // The URL prefix comes from GeoMath.tileBase() rather than being repeated
  // here, and the three numbers are rebuilt from the name inside the script
  // after being re-checked as digits -- so nothing that is not a run of digits
  // can reach the URL, whatever QML passed.
  readonly property string fetchScript:
    'd="$1"; ua="$2"; base="$3"; shift 3\n' +
    // The key arrives on stdin as one line, not in argv. Read before anything
    // else so a run that was launched without one stops here having made no
    // request, and re-checked against the same alphabet GeoMath.tileKey uses --
    // this is the side that builds the URL, so this is the side that has to be
    // sure nothing in it can start a second parameter or close the path.
    'IFS= read -r key || key=""\n' +
    'case "$key" in\n' +
    '  \'\'|*[!A-Za-z0-9._~-]*) exit 1 ;;\n' +
    'esac\n' +
    '[ ${#key} -le 256 ] || exit 1\n' +
    // The directory is re-verified on every run, not trusted from the run that
    // created it. Same three questions Panel.qml asks: a directory, not a
    // symlink, owned by us.
    '[ -d "$d" ] && [ ! -L "$d" ] && [ -O "$d" ] || exit 1\n' +
    'case "$base" in https://*) ;; *) exit 1 ;; esac\n' +
    'td="$d/tiles"\n' +
    'mkdir -m 700 -p -- "$td" 2>/dev/null || exit 1\n' +
    '[ -d "$td" ] && [ ! -L "$td" ] && [ -O "$td" ] || exit 1\n' +
    // Prune by count, newest kept. A byte ceiling beside the row ceiling for the
    // same reason the photo prune has one: `tail -n +N` bounds how many names
    // survive, not how many bytes find and sort had to hold to decide. LC_ALL=C
    // on both, because %T@ prints a dot and a comma locale would sort the
    // timestamps wrongly and delete the newest tiles.
    'LC_ALL=C find "$td" -maxdepth 1 -type f -name "*.png" -printf "%T@\\t%p\\n" 2>/dev/null \\\n' +
    '  | head -c 262145 \\\n' +
    '  | LC_ALL=C sort -rn | tail -n +' + (maxTilesOnDisk + 1) + ' | cut -f2- \\\n' +
    '  | while IFS= read -r old; do rm -f -- "$old"; done\n' +
    // Leftovers from a run that was killed mid-transfer. They are never read --
    // only a file that passed the check is ever renamed to <name>.png -- but
    // they would otherwise accumulate in RAM.
    'find "$td" -maxdepth 1 -type f -name "tmp.*" -mmin +5 -delete 2>/dev/null\n' +
    //
    // The header check. Signature, then the IHDR tag where the signature says it
    // must be -- anchoring on both is what makes bytes 16..23 the dimensions
    // rather than whatever happens to sit at that offset -- then the two numbers
    // those bytes hold.
    //
    // `od -v` matters: without it od collapses a run of identical input lines to
    // a `*`, and a 32-byte window of a PNG can easily hold one. The collapsed
    // output would match nothing and every tile would be refused.
    // Variable names here are deliberately distinct from the loop's below.
    // POSIX sh has no local scope, so a name reused inside a function is the
    // same variable as the one outside it. These functions happen to run in a
    // background subshell, which hides that -- until someone calls one of them
    // in the foreground and the loop counter changes underneath the loop.
    'check() {\n' +
    '  ch=$(dd if="$1" iflag=nofollow,nonblock bs=32 count=1 status=none 2>/dev/null \\\n' +
    '      | od -An -tx1 -v | tr -d " \\n")\n' +
    '  case "$ch" in\n' +
    '    89504e470d0a1a0a????????49484452*) ;;\n' +
    '    *) return 1 ;;\n' +
    '  esac\n' +
    '  cw=$(( 0x$(printf %s "$ch" | cut -c33-40) ))\n' +
    '  chh=$(( 0x$(printf %s "$ch" | cut -c41-48) ))\n' +
    // Fail closed on anything that did not parse to a plain number. A shell
    // whose arithmetic refused the hex constant lands here rather than falling
    // through with an empty value.
    '  case "$cw$chh" in \'\'|*[!0-9]*) return 1 ;; esac\n' +
    '  [ "$cw" -ge 1 ] && [ "$chh" -ge 1 ] || return 1\n' +
    '  [ "$cw" -le ' + tileMaxDim + ' ] && [ "$chh" -le ' + tileMaxDim + ' ] || return 1\n' +
    '  return 0\n' +
    '}\n' +
    //
    // One tile: fetch under a byte ceiling, check, and only then move it into
    // place under its real name. The move is what publishes it, so a tile that
    // failed any of those steps is never a file QML can point an Image at.
    'one() {\n' +
    '  tn="$1"; tz="$2"; tx="$3"; ty="$4"\n' +
    '  f="$td/tmp.$tn.$$"\n' +
    '  rm -f -- "$f"\n' +
    // Two independent ceilings, as on the photo path and for the same reason:
    // --max-filesize aborts early when the server declares a Content-Length,
    // and `head -c` bounds what is written whatever the server declares --
    // including a chunked reply that declares nothing at all.
    '  curl -fsS --proto "=https" --max-time 15 --max-filesize ' + tileCapBytes + ' \\\n' +
    '    -A "$ua" -- "$base/$tz/$tx/$ty.png?key=$key" 2>/dev/null \\\n' +
    '    | head -c ' + (tileCapBytes + 1) + ' > "$f"\n' +
    '  if check "$f"; then mv -f -- "$f" "$td/$tn.png"; else rm -f -- "$f"; fi\n' +
    '}\n' +
    //
    // Fetched six at a time. Sequentially, eighteen tiles would be eighteen
    // round trips end to end; unbounded, a fast pan could put a hundred curls in
    // flight at once. Six is what a browser allows one host and what Qt was
    // doing here before.
    'n=0\n' +
    'for name in "$@"; do\n' +
    '  [ "$n" -lt ' + maxFetchPerRun + ' ] || break\n' +
    // Digits and hyphens only, then exactly three fields of digits. The names
    // are built from integers in QML, so this is the second check rather than
    // the first -- but this one is on the side that builds the URL.
    '  case "$name" in \'\'|*[!0-9-]*) continue ;; esac\n' +
    // A tile name is at most 2+1+6+1+6 characters at zoom 19, the deepest the
    // UI can reach. The character class above admits a digit run of any length,
    // and a URL should not be built out of one.
    '  [ ${#name} -le 20 ] || continue\n' +
    '  z=${name%%-*}; r=${name#*-}; x=${r%%-*}; y=${r##*-}\n' +
    // Exactly three fields, checked from both ends. The trailing test alone
    // accepts a two-field name -- "4-8" splits to x=8, y=8, and the tail of a
    // string with no hyphen in it is the whole string, so the two agree and it
    // passes. Requiring r to differ from x is what says there was a second
    // hyphen at all; requiring the tail after it to be y is what rejects a
    // fourth field.
    '  [ "$r" != "$x" ] || continue\n' +
    '  [ "${r#*-}" = "$y" ] || continue\n' +
    '  case "$z" in \'\'|*[!0-9]*) continue ;; esac\n' +
    '  case "$x" in \'\'|*[!0-9]*) continue ;; esac\n' +
    '  case "$y" in \'\'|*[!0-9]*) continue ;; esac\n' +
    '  [ -f "$td/$name.png" ] && continue\n' +
    '  one "$name" "$z" "$x" "$y" &\n' +
    '  n=$((n+1))\n' +
    '  [ $((n % 6)) -eq 0 ] && wait\n' +
    'done\n' +
    'wait\n' +
    //
    // Report what is actually on disk, which is not the same question as what
    // was fetched: a tile already present from an earlier run counts, and one
    // that failed its check does not. Capped, because this is stdout and
    // StdioCollector keeps all of it.
    'for name in "$@"; do\n' +
    '  [ -f "$td/$name.png" ] && printf "%s\\n" "$name"\n' +
    'done | head -c 65537\n'

  // Names asked for by the run currently in flight, so the reply can be matched
  // against what was requested rather than trusted on its own.
  property var inFlight: []
  property bool refetchWanted: false

  // Asks about every tile in the current window, not only the ones not already
  // known -- see `have` for why. A tile already on disk costs the helper no
  // network at all: it checks for the file, finds it, and reports it. A full
  // window that is entirely cached measured 16ms end to end against 507ms for
  // one that had to be fetched.
  function requestWindow() {
    if (root.tileDirPath() === "" || !root.active) return
    // No key, no request. See `apiKey` for why this is a precondition rather
    // than a failure the layer could notice afterwards.
    if (root.validKey === "") return

    var wanted = []
    for (var i = 0; i < root.tiles.length; i++) wanted.push(root.tileName(root.tiles[i]))
    if (wanted.length === 0) return

    // One run at a time. A drag that crosses several tile boundaries in a second
    // would otherwise start a helper per boundary, each fetching a window that
    // the next one has already superseded. The latest window is the one worth
    // having, so a run that arrives while another is going sets a flag and the
    // work happens once, afterwards.
    if (fetchProcess.running) {
      root.refetchWanted = true
      return
    }

    root.inFlight = wanted
    // The key goes over stdin, never argv. /proc/<pid>/cmdline is readable by
    // this user's other processes, and a basemap key is the player's own
    // credential against their own quota -- the fact that it also travels inside
    // the tile URL is not a reason to hand it to every process on the machine as
    // well. Same shape the shell's own network panel uses for a passphrase.
    fetchProcess.secret = root.validKey
    fetchProcess.command = ["timeout", "-k", "2", "30", "sh", "-c", root.fetchScript, "sh",
                            root.cacheDir, root.userAgent, GeoMath.tileBase()].concat(wanted)
    fetchProcess.running = true
  }

  Process {
    id: fetchProcess

    // Written once the child is up, then dropped, so the key is not left sitting
    // in a QML property between runs.
    property string secret: ""
    stdinEnabled: true
    onStarted: {
      write(secret + "\n")
      secret = ""
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // The reply is a list of names, and every one of them is checked against
        // the list this run asked for before it becomes a path. A name the shell
        // invented is not a name QML will load.
        var asked = {}
        for (var a = 0; a < root.inFlight.length; a++) asked[root.inFlight[a]] = true

        // Built from this run's answer alone, not merged into what was there
        // before -- a tile the helper did not report is a tile that is not on
        // disk, whether it failed to arrive or was pruned since.
        var next = {}
        var lines = String(text || "").split("\n")
        var added = 0
        for (var i = 0; i < lines.length && added < root.maxFetchPerRun; i++) {
          var name = lines[i]
          // Every name is checked against what this run asked for before it
          // becomes a path. A name the helper invented is not one QML will load.
          if (name === "" || !asked[name]) continue
          if (!/^[0-9]+-[0-9]+-[0-9]+$/.test(name)) continue
          next[name] = true
          added += 1
        }

        if (added > 0) {
          // Assigned, not mutated: the `source` bindings are watching this
          // property, and an in-place edit fires no change signal.
          root.have = next
          root.noteSuccess()
        } else {
          // Nothing came back at all -- the helper was killed, or there is no
          // network and nothing cached. Keeping the previous set means a
          // transient failure does not blank tiles that are still on screen and
          // still on disk; `healthy` is what eventually gives up and hands the
          // map to the bundled outlines.
          root.noteFailure()
        }
      }
    }

    onExited: function (exitCode) {
      if (exitCode !== 0) root.noteFailure()
      if (root.refetchWanted) {
        root.refetchWanted = false
        root.requestWindow()
      }
    }
  }

  Repeater {
    model: root.tiles

    Image {
      required property var modelData

      // Bound to the frame, not read from the model, so panning moves the tile
      // instead of rebuilding it.
      x: root.frame ? (modelData.x - root.frame.left) * root.frame.px : 0
      y: root.frame ? (modelData.y - root.frame.top) * root.frame.px : 0
      width: root.frame ? root.frame.px : 0
      height: root.frame ? root.frame.px : 0

      // A local file that has already been checked, or "" until it has. An Image
      // with an empty source fetches nothing and draws nothing.
      source: root.tileSource(modelData)

      // Still set, and still worth setting: it bounds the pixmap that is kept
      // for a tile whose dimensions passed the check but are not 256. It is no
      // longer doing the security work -- the helper's header check is -- which
      // is the whole point of the change.
      sourceSize.width: root.tileMaxDim
      sourceSize.height: root.tileMaxDim

      // Qt's pixmap cache keys on the URL, and a tile at a given z/x/y is the
      // same bytes forever, so panning back over ground already seen costs
      // nothing the second time. This is the opposite of the round's
      // photograph, which is written once and never revisited.
      cache: true
      asynchronous: true

      // The tile is drawn at whatever size the fractional zoom asks for, which
      // is within about 41% of native either way, so it is always being scaled
      // slightly and always wants the smoothing.
      smooth: true
      fillMode: Image.Stretch

      // A tile that has not arrived stays invisible rather than flashing a
      // placeholder. Underneath is either the previous frame's tiles or the
      // bundled outlines, both of which are better than a hole.
      visible: status === Image.Ready
    }
  }
}
