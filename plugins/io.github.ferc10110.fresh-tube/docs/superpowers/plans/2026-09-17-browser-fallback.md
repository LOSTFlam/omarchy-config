# Fresh Tube 1.3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When mpv cannot open a video, open it in the user's Chromium-family browser in app mode (own profile, placed below the bar, size remembered), plus a `login` command to sign in to that profile.

**Architecture:** `play.py` learns to recognise browsers and build their app-mode command line; `fresh-tube play` gains `--fallback`, which mpv's companion script uses to relaunch `play` with the browser when the file never loaded; the hidden `place-window` helper gains `--resize` and `--watch` so browser windows get sized and their last size saved. The panel only passes the new `fallbackCommand` setting through.

**Tech Stack:** Python 3 stdlib, `unittest`; mpv Lua API; `hyprctl` JSON; QML (one property, one function edit).

**Spec:** `docs/superpowers/specs/2026-09-17-browser-fallback-design.md` (extends the 2026-09-16 and 2026-09-17 watch-later specs).

## Global Constraints

- Python stdlib only; tests never run mpv, a browser or hyprctl (they patch `fresh_tube.play.popen`, `hyprctl`, `dispatch`, `sleep`, `pid_alive`, `find_window`, `place_window`, `resize_window`, `watch_window`).
- Never `datetime.utcnow()`. UI strings, README, comments and commit messages in English; the spec is in Spanish.
- Exit codes: 0 ok, 1 general, 2 usage, 3 network. Errors print as `fresh-tube: <message>` on stderr.
- Browsers recognised by the basename of the command's first token: `chromium`, `chromium-browser`, `google-chrome`, `google-chrome-stable`, `brave`, `brave-browser`, `vivaldi`, `vivaldi-stable`, `microsoft-edge`, `microsoft-edge-stable`, `helium`, `opera`.
- Browser argv (after the user's tokens): `--user-data-dir=$XDG_STATE_HOME/fresh-tube/browser`, `--no-first-run`, `--no-default-browser-check`, `--autoplay-policy=no-user-gesture-required`, `--window-size=W,H`, `--app=https://www.youtube.com/embed/<id>?autoplay=1`. `login` argv: user's tokens + the profile flags + `https://www.youtube.com/` (no `--app`).
- Sizes: mpv keeps `playerWidth`/`playerHeight` (physical pixels, quarter of the monitor's `width`); browsers use `browserWidth`/`browserHeight` (ints 200–8000, logical pixels: quarter of `width / scale`); fallback 860×484 without hyprctl.
- mpv gets `--script-opt=fresh_tube-fallback=<CMD>` only when `play` was given `--fallback` and the player is mpv. The Lua relaunches `<bin> play --player <CMD> -- <id>` once, only on `end-file` with `reason == "error"` before `file-loaded`; it records the window size only after `file-loaded`.
- `place-window <pid> [--resize WxH] [--watch]`: resize via `hyprctl dispatch resizewindowpixel exact W H,address:<addr>` after placing; `--watch` polls `hyprctl clients -j` every second until the window disappears or the pid dies and saves the last non-zero `size` as `browserWidth`/`browserHeight` through `store.state_transaction()`. `play` adds `--resize`/`--watch` to the helper only for browsers.
- Exact strings: `<name> is not a browser I know how to open` (exit 2), `Could not start <name>: <reason>` (exit 1), `{"login": "<command>"}`.
- Test command: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v` (never `-m unittest tests.x`), warning-free (`… 2>&1 | grep -ciE warning` → 0); `node --test tests/model.test.js` fail 0; `omarchy plugin validate .` exit 0; `luac -p mpv/fresh-tube.lua` silent; no `__pycache__` (`find . -name __pycache__ -not -path './.git/*'` empty). Currently 134 Python tests pass.
- The plugin is live in the user's bar and hot-reloads on save: every saved QML must parse; after QML edits check `quickshell log -p /usr/share/omarchy/shell -t 80 | grep -v qt.qpa.services | grep -iE 'error|warn|fresh|unable|undefined'`. Never run mpv, a browser, `hyprctl dispatch`, IPC commands, `omarchy bar set`, or the CLI against the real `~/.config/fresh-tube` / `~/.local/state/fresh-tube`.
- Every commit ends with exactly these two lines (they override any attribution line a tool environment suggests):
  `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_011DPqvBbwQCc2wPWRZoVQkC`.
  Identity fallback: `git -c user.name="Fernando Cancro" -c user.email="fernando.cancro@gmail.com" commit ...`.

---

## File Structure

- Modify `lib/fresh_tube/store.py`: `PREF_LIMITS` gains `browserWidth`/`browserHeight`.
- Modify `lib/fresh_tube/play.py`: `BROWSERS`, `EMBED_URL`, `YOUTUBE_URL`, `WATCH_POLL_SECONDS`, `is_browser`, `browser_flags`, `build_argv(..., fallback=None)`, `login_argv`, `_monitor_width`, `_quarter`, `default_size`, `default_logical_size`, `size_for`, `start(..., fallback=None)`, `resize_window`, `window_size`, `watch_window`.
- Modify `lib/fresh_tube/cli.py`: `size_arg`, `cmd_play` (`--fallback`, `play.size_for`), `cmd_place_window` (`--resize`, `--watch`), `cmd_login`, parser entries.
- Modify `mpv/fresh-tube.lua`: `fresh_tube-fallback`, `file-loaded`, fallback on load error, size only once loaded.
- Modify `Panel.qml` (`fallbackCommand`, `play()`), `manifest.json` (setting + 1.3.0), `README.md`.
- Tests: `tests/test_store.py`, `tests/test_play.py`.

## Model plan

Task 1 sonnet · Task 2 sonnet · Task 3 haiku · Task 4 sonnet. Reviews sonnet. Final review fable.

---

### Task 1: browser prefs, browser argv, logical size, login argv

**Files:**
- Modify: `lib/fresh_tube/store.py` (`PREF_LIMITS`, line ~129)
- Modify: `lib/fresh_tube/play.py` (imports, constants, `build_argv`, `default_size`)
- Test: `tests/test_store.py`, `tests/test_play.py`

**Interfaces:**
- Consumes: `store.state_dir()` (→ `$XDG_STATE_HOME/fresh-tube`), `store.set_pref/set_prefs` validation, `play.player_argv`, `play.is_mpv`, `play.DEFAULT_SIZE`.
- Produces: `play.BROWSERS`, `play.EMBED_URL`, `play.YOUTUBE_URL`, `play.is_browser(argv) -> bool`, `play.browser_flags() -> list[str]`, `play.build_argv(player_command, video_id, size, fallback=None)`, `play.login_argv(player_command)` (raises USAGE), `play.default_size(monitors)` (unchanged behaviour), `play.default_logical_size(monitors)`; prefs `browserWidth`/`browserHeight` in `store.PREF_LIMITS`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_store.py`:

```python
class BrowserPrefs(StoreTest):
    def test_browser_size_limits(self):
        state = store.load_state()
        store.set_prefs(state, [("browserWidth", "640"), ("browserHeight", "360")])
        store.save_state(state)
        prefs = store.load_state()["prefs"]
        self.assertEqual((prefs["browserWidth"], prefs["browserHeight"]), (640, 360))
        with self.assertRaises(FreshTubeError) as caught:
            store.set_pref(state, "browserHeight", "9999")
        self.assertIn("between 200 and 8000", str(caught.exception))
        self.assertEqual(caught.exception.code, USAGE)
```

In `tests/test_play.py`, add to `DefaultSize`:

```python
    def test_logical_size_divides_by_scale(self):
        self.assertEqual(play.default_logical_size(MONITORS), (480, 270))
        self.assertEqual(play.default_logical_size([dict(MONITORS[1], focused=True)]), (320, 180))
        self.assertEqual(play.default_logical_size(None), play.DEFAULT_SIZE)
        self.assertEqual(play.default_logical_size([{"width": 1000, "scale": "x"}]), play.DEFAULT_SIZE)
```

and append a new class after `DefaultSize`:

```python
class Browser(unittest.TestCase):
    def test_known_browsers(self):
        for name in ("chromium", "chromium-browser", "google-chrome", "google-chrome-stable", "brave", "brave-browser",
                     "vivaldi", "vivaldi-stable", "microsoft-edge", "microsoft-edge-stable", "helium", "opera"):
            self.assertTrue(play.is_browser([name]), name)
            self.assertTrue(play.is_browser(["/usr/bin/" + name, "--flag"]), name)
        for name in ("mpv", "vlc", "firefox", "chromium2"):
            self.assertFalse(play.is_browser([name]), name)

    def test_browser_gets_app_mode_and_its_own_profile(self):
        with mock.patch.dict(os.environ, {"XDG_STATE_HOME": "/tmp/xdg-state"}):
            argv = play.build_argv("chromium", VID, (480, 270))
        self.assertEqual(argv[0], "chromium")
        self.assertIn("--user-data-dir=/tmp/xdg-state/fresh-tube/browser", argv)
        self.assertIn("--no-first-run", argv)
        self.assertIn("--no-default-browser-check", argv)
        self.assertIn("--autoplay-policy=no-user-gesture-required", argv)
        self.assertIn("--window-size=480,270", argv)
        self.assertEqual(argv[-1], "--app=https://www.youtube.com/embed/4_fM3Nv8BB0?autoplay=1")
        self.assertNotIn(URL, argv)

    def test_browser_options_come_first(self):
        argv = play.build_argv("brave --incognito", VID, (480, 270))
        self.assertEqual(argv[:2], ["brave", "--incognito"])

    def test_fallback_is_handed_to_mpv_only(self):
        flag = "--script-opt=fresh_tube-fallback=chromium"
        self.assertIn(flag, play.build_argv("mpv", VID, (860, 484), fallback="chromium"))
        self.assertNotIn(flag, play.build_argv("mpv", VID, (860, 484)))
        self.assertEqual(play.build_argv("vlc", VID, (860, 484), fallback="chromium"), ["vlc", URL])
        self.assertNotIn(flag, play.build_argv("chromium", VID, (480, 270), fallback="chromium"))

    def test_login_opens_youtube_in_a_normal_window_of_the_profile(self):
        with mock.patch.dict(os.environ, {"XDG_STATE_HOME": "/tmp/xdg-state"}):
            argv = play.login_argv("chromium")
        self.assertEqual(argv[0], "chromium")
        self.assertIn("--user-data-dir=/tmp/xdg-state/fresh-tube/browser", argv)
        self.assertEqual(argv[-1], "https://www.youtube.com/")
        self.assertFalse(any(a.startswith("--app") for a in argv))

    def test_login_refuses_non_browsers(self):
        with self.assertRaises(FreshTubeError) as caught:
            play.login_argv("mpv")
        self.assertEqual(str(caught.exception), "mpv is not a browser I know how to open")
        self.assertEqual(caught.exception.code, USAGE)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_play.py' 2>&1 | grep -E '^(ERROR|FAIL|Ran|FAILED)' | head` and the same with `test_store.py`.
Expected: `AttributeError: module 'fresh_tube.play' has no attribute 'default_logical_size'` / `is_browser` / `login_argv`, `TypeError … unexpected keyword argument 'fallback'`; the store test fails with `Unknown preference browserWidth`.

- [ ] **Step 3: Store limits**

In `lib/fresh_tube/store.py` replace `PREF_LIMITS`:

```python
PREF_LIMITS = {"width": (300, 4000), "height": (220, 4000),
               "playerWidth": (200, 8000), "playerHeight": (200, 8000),
               "browserWidth": (200, 8000), "browserHeight": (200, 8000)}
```

- [ ] **Step 4: `play.py` — browsers, argv, sizes**

Change the imports/constants block at the top of `lib/fresh_tube/play.py` to:

```python
from .errors import GENERAL, USAGE, FreshTubeError
from .store import state_dir
from .videos import WATCH_URL

DEFAULT_SIZE = (860, 484)
WINDOW_WAIT_SECONDS = 10
WINDOW_POLL_SECONDS = 0.1
HYPRCTL_TIMEOUT = 5
PLUGIN_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPT_PATH = os.path.join(PLUGIN_DIR, "mpv", "fresh-tube.lua")
BIN_PATH = os.path.join(PLUGIN_DIR, "bin", "fresh-tube")
# Chromium-family browsers that accept --app and --user-data-dir.
BROWSERS = frozenset(["chromium", "chromium-browser", "google-chrome", "google-chrome-stable", "brave", "brave-browser",
                      "vivaldi", "vivaldi-stable", "microsoft-edge", "microsoft-edge-stable", "helium", "opera"])
EMBED_URL = "https://www.youtube.com/embed/{}?autoplay=1"
YOUTUBE_URL = "https://www.youtube.com/"
```

Replace `is_mpv` … `default_size` (keep `player_argv` as it is) with:

```python
def is_mpv(argv):
    return os.path.basename(argv[0]) == "mpv"


def is_browser(argv):
    return os.path.basename(argv[0]) in BROWSERS


def browser_flags():
    """A profile of our own: a separate browser process (so its window can be found by pid) that keeps its own login."""
    return [f"--user-data-dir={os.path.join(state_dir(), 'browser')}", "--no-first-run", "--no-default-browser-check"]


def build_argv(player_command, video_id, size, fallback=None):
    """The full command line: mpv gets the companion script, the size and resume; a browser gets app mode; others only the URL."""
    argv = player_argv(player_command)
    if is_mpv(argv):
        argv += ["--save-position-on-quit", "--force-window=immediate",
                 f"--geometry={size[0]}x{size[1]}", f"--script={SCRIPT_PATH}",
                 f"--script-opt=fresh_tube-id={video_id}", f"--script-opt=fresh_tube-bin={BIN_PATH}"]
        if fallback:
            argv.append(f"--script-opt=fresh_tube-fallback={fallback}")
        return argv + [WATCH_URL.format(video_id)]
    if is_browser(argv):
        return argv + browser_flags() + ["--autoplay-policy=no-user-gesture-required",
                                         f"--window-size={size[0]},{size[1]}", f"--app={EMBED_URL.format(video_id)}"]
    return argv + [WATCH_URL.format(video_id)]


def login_argv(player_command):
    """A normal browser window on YouTube, in our profile, so the user can sign in there."""
    argv = player_argv(player_command)
    if not is_browser(argv):
        raise FreshTubeError(f"{os.path.basename(argv[0])} is not a browser I know how to open", USAGE)
    return argv + browser_flags() + [YOUTUBE_URL]


def _monitor_width(monitors, logical):
    """The focused (else first) monitor's width, in logical pixels when asked; None when it cannot be known."""
    if not monitors:
        return None
    focused = next((m for m in monitors if isinstance(m, dict) and m.get("focused")), None)
    monitor = focused or (monitors[0] if isinstance(monitors[0], dict) else None)
    if not monitor:
        return None
    try:
        width = float(int(monitor.get("width")))
        if logical:
            width = width / (float(monitor.get("scale") or 1) or 1.0)
    except (TypeError, ValueError):
        return None
    return width if width > 0 else None


def _quarter(width):
    """A quarter of `width`, 16:9; DEFAULT_SIZE without a usable width."""
    if width is None:
        return DEFAULT_SIZE
    quarter = int(round(width / 4))
    if quarter <= 0:
        return DEFAULT_SIZE
    return quarter, int(round(quarter * 9 / 16))


def default_size(monitors):
    """mpv's first-run size: mpv measures --geometry in physical pixels."""
    return _quarter(_monitor_width(monitors, logical=False))


def default_logical_size(monitors):
    """A browser's first-run size: browsers measure --window-size in logical pixels."""
    return _quarter(_monitor_width(monitors, logical=True))
```

- [ ] **Step 5: Run the whole suite**

Run: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests 2>&1 | tail -3`
Expected: `OK`, no warnings (134 + 8 new).

- [ ] **Step 6: Commit**

```bash
git add lib/fresh_tube/store.py lib/fresh_tube/play.py tests/test_store.py tests/test_play.py
git commit -F - <<'EOF'
Teach play about browsers: app mode, own profile, logical size

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_011DPqvBbwQCc2wPWRZoVQkC
EOF
```

---

### Task 2: resize and watch the window; `play --fallback`, `place-window --resize/--watch`, `login`

**Files:**
- Modify: `lib/fresh_tube/play.py` (`start`, new Hyprland helpers, `size_for`)
- Modify: `lib/fresh_tube/cli.py` (`cmd_play`, `cmd_place_window`, `cmd_login`, `size_arg`, parser)
- Test: `tests/test_play.py`

**Interfaces:**
- Consumes (Task 1): `play.is_browser`, `play.build_argv(..., fallback)`, `play.login_argv`, `play.default_size`, `play.default_logical_size`; `store.state_transaction`, `store.set_prefs`, `store.mark_seen`; existing `play.launch`, `play.find_window`, `play.place_window`, `play.dispatch`, `play.hyprctl`, `play.pid_alive`, `play.sleep`.
- Produces: `play.size_for(player_command, prefs) -> (w, h)`, `play.start(player_command, video_id, size, fallback=None) -> pid`, `play.resize_window(client, size)`, `play.window_size(client) -> (w, h) | None`, `play.watch_window(client, pid) -> (w, h) | None`, `play.WATCH_POLL_SECONDS`; CLI `play [--player CMD] [--fallback CMD] <id>`, `place-window <pid> [--resize WxH] [--watch]`, `login [--player CMD]` → `{"login": "<cmd>"}`.
- The Lua (Task 3) calls `<bin> play --player <fallback> -- <id>`; the panel (Task 4) calls `play --player <cmd> --fallback <cmd> -- <id>`.

- [ ] **Step 1: Write the failing tests**

In `tests/test_play.py`, add to `Placement`:

```python
    def test_resize_dispatches_an_exact_size(self):
        play.resize_window(client(7), (640, 360))
        self.assertEqual(self.dispatches, [("resizewindowpixel", "exact 640 360,address:0x55aa")])

    def test_watch_returns_the_last_size_once_the_window_is_gone(self):
        polls = [[dict(client(7), size=[640, 360])], [dict(client(7), size=[700, 400])], [client(8)]]
        with mock.patch("fresh_tube.play.hyprctl", side_effect=polls):
            self.assertEqual(play.watch_window(client(7), 7), (700, 400))

    def test_watch_ignores_bad_sizes_and_stops_when_the_player_dies(self):
        polls = [[dict(client(7), size=[640, 360])], [dict(client(7), size=[0, 0])], [dict(client(7), size="x")]]
        alive = iter([True, True, False])
        with mock.patch("fresh_tube.play.hyprctl", side_effect=polls), \
             mock.patch("fresh_tube.play.pid_alive", side_effect=lambda pid: next(alive)):
            self.assertEqual(play.watch_window(client(7), 7), (640, 360))

    def test_watch_without_hyprland_or_a_size_gives_none(self):
        with mock.patch("fresh_tube.play.hyprctl", return_value=None):
            self.assertIsNone(play.watch_window(client(7), 7))
        with mock.patch("fresh_tube.play.hyprctl", side_effect=[[client(8)]]):
            self.assertIsNone(play.watch_window(client(7), 7))
```

Add to `PlayCommand`:

```python
    def test_a_browser_gets_the_embed_and_a_watching_placer(self):
        code, out, err = self.run_play("--player", "chromium", "--", VID)
        self.assertEqual(code, 0, err)
        player, placer = self.spawned
        self.assertEqual(player[0][0], "chromium")
        self.assertEqual(player[0][-1], "--app=https://www.youtube.com/embed/4_fM3Nv8BB0?autoplay=1")
        self.assertIn("--window-size=480,270", player[0])
        self.assertEqual(placer[0], [play.BIN_PATH, "place-window", "4242", "--resize", "480x270", "--watch"])
        self.assertIn(VID, self.box.read_json(self.box.state_file)["seen"])

    def test_browser_uses_its_own_remembered_size(self):
        state = store.load_state()
        store.set_prefs(state, [("browserWidth", "700"), ("browserHeight", "400"),
                                ("playerWidth", "1000"), ("playerHeight", "560")])
        store.save_state(state)
        self.run_play("--player", "chromium", "--", VID)
        self.assertIn("--window-size=700,400", self.spawned[0][0])
        self.assertEqual(self.spawned[1][0][-3:], ["--resize", "700x400", "--watch"])
        self.spawned.clear()
        self.run_play("--", VID)
        self.assertIn("--geometry=1000x560", self.spawned[0][0])

    def test_fallback_reaches_mpv_and_the_placer_stays_plain(self):
        self.run_play("--fallback", "chromium", "--", VID)
        player, placer = self.spawned
        self.assertIn("--script-opt=fresh_tube-fallback=chromium", player[0])
        self.assertEqual(placer[0], [play.BIN_PATH, "place-window", "4242"])
```

Replace the whole `PlaceWindowCommand` class with:

```python
class PlaceWindowCommand(unittest.TestCase):
    def setUp(self):
        self.box = support.Sandbox()
        self.box.apply()
        self.addCleanup(self.box.cleanup)
        self.addCleanup(mock.patch.stopall)
        self.find = mock.patch("fresh_tube.play.find_window", return_value=client(7)).start()
        self.place = mock.patch("fresh_tube.play.place_window").start()
        self.resize = mock.patch("fresh_tube.play.resize_window").start()
        self.watch = mock.patch("fresh_tube.play.watch_window", return_value=None).start()

    def test_places_the_window_of_the_given_pid(self):
        with support.captured():
            self.assertEqual(cli.main(["place-window", "7"]), 0)
        self.find.assert_called_once_with(7)
        self.place.assert_called_once_with(client(7))
        self.resize.assert_not_called()
        self.watch.assert_not_called()

    def test_no_window_means_nothing_happens(self):
        self.find.return_value = None
        with support.captured():
            self.assertEqual(cli.main(["place-window", "7", "--resize", "640x360", "--watch"]), 0)
        self.place.assert_not_called()
        self.watch.assert_not_called()

    def test_resize_and_watch_save_the_browser_size(self):
        self.watch.return_value = (700, 400)
        with support.captured():
            self.assertEqual(cli.main(["place-window", "7", "--resize", "640x360", "--watch"]), 0)
        self.resize.assert_called_once_with(client(7), (640, 360))
        self.watch.assert_called_once_with(client(7), 7)
        prefs = store.load_state()["prefs"]
        self.assertEqual((prefs["browserWidth"], prefs["browserHeight"]), (700, 400))

    def test_watch_without_a_size_saves_nothing(self):
        with support.captured():
            self.assertEqual(cli.main(["place-window", "7", "--watch"]), 0)
        self.assertNotIn("browserWidth", store.load_state()["prefs"])

    def test_bad_pid_or_size_is_a_usage_error(self):
        with support.captured():
            self.assertEqual(cli.main(["place-window", "x"]), 2)
            self.assertEqual(cli.main(["place-window", "7", "--resize", "big"]), 2)


class LoginCommand(unittest.TestCase):
    def setUp(self):
        self.spawned = []
        self.addCleanup(mock.patch.stopall)
        mock.patch("fresh_tube.play.popen",
                   side_effect=lambda argv, **kw: self.spawned.append(argv) or mock.Mock(pid=1)).start()

    def test_opens_youtube_in_the_profile(self):
        with support.captured() as (out, err):
            self.assertEqual(cli.main(["login"]), 0)
        self.assertEqual(json.loads(out.getvalue()), {"login": "chromium"})
        self.assertEqual(self.spawned[0][0], "chromium")
        self.assertEqual(self.spawned[0][-1], "https://www.youtube.com/")

    def test_refuses_a_non_browser(self):
        with support.captured() as (out, err):
            self.assertEqual(cli.main(["login", "--player", "mpv"]), 2)
        self.assertIn("mpv is not a browser I know how to open", err.getvalue())
        self.assertEqual(self.spawned, [])

    def test_launch_failure(self):
        mock.patch("fresh_tube.play.popen", side_effect=FileNotFoundError(2, "No such file or directory")).start()
        with support.captured() as (out, err):
            self.assertEqual(cli.main(["login"]), 1)
        self.assertIn("Could not start chromium", err.getvalue())
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_play.py' 2>&1 | grep -E '^(ERROR|FAIL|Ran|FAILED)' | head -20`
Expected: `AttributeError` for `resize_window`/`watch_window`, usage errors (exit 2) for `--fallback`, `--resize`, `--watch`, `login`, and the placer argv assertions failing.

- [ ] **Step 3: `play.py` — `size_for`, `start`, resize and watch**

Add after `default_logical_size`:

```python
def size_for(player_command, prefs):
    """The remembered size for this kind of player, else a quarter of the focused monitor."""
    if is_browser(player_argv(player_command)):
        keys, measure = ("browserWidth", "browserHeight"), default_logical_size
    else:
        keys, measure = ("playerWidth", "playerHeight"), default_size
    if all(key in prefs for key in keys):
        return prefs[keys[0]], prefs[keys[1]]
    return measure(hyprctl("monitors"))
```

Replace `start`:

```python
def start(player_command, video_id, size, fallback=None):
    """Launch the player, then a detached helper that places its window; returns the player's pid."""
    argv = build_argv(player_command, video_id, size, fallback)
    process = launch(argv)
    helper = [BIN_PATH, "place-window", str(process.pid)]
    if is_browser(argv):
        # Browsers do not keep --window-size once floated, and have no script to remember their size.
        helper += ["--resize", f"{size[0]}x{size[1]}", "--watch"]
    try:
        popen(helper, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
              start_new_session=True)
    except OSError:
        pass  # the video plays anyway, just not placed
    return process.pid
```

Add `WATCH_POLL_SECONDS = 1` next to `WINDOW_POLL_SECONDS`, and append at the end of the file:

```python
def resize_window(client, size):
    dispatch("resizewindowpixel", f"exact {size[0]} {size[1]},address:{client.get('address')}")


def window_size(client):
    """The client's (width, height) when hyprctl reports a usable one."""
    size = client.get("size")
    try:
        width, height = int(size[0]), int(size[1])
    except (TypeError, ValueError, IndexError):
        return None
    return (width, height) if width > 0 and height > 0 else None


def watch_window(client, pid):
    """Follow the window until it closes or its process dies; the last size seen after placement, or None."""
    address = client.get("address")
    last = None
    while True:
        sleep(WATCH_POLL_SECONDS)
        clients = hyprctl("clients")
        if clients is None:
            return last
        current = next((c for c in clients if isinstance(c, dict) and c.get("address") == address), None)
        if current is None:
            return last
        last = window_size(current) or last
        if not pid_alive(pid):
            return last
```

- [ ] **Step 4: `cli.py` — commands and parser**

Replace `cmd_play` and `cmd_place_window`, and add `size_arg` and `cmd_login`:

```python
def cmd_play(args):
    """Launch the player for a video; seen only once the player is running."""
    if not videos.VIDEO_ID_RE.match(args.video_id or ""):
        raise FreshTubeError("That doesn't look like a YouTube video id", USAGE)
    with store.state_transaction() as state:
        size = play.size_for(args.player, state["prefs"])
        play.start(args.player, args.video_id, size, args.fallback)
        store.mark_seen(state, args.video_id)
    emit({"played": args.video_id})
    return 0


def size_arg(text):
    parts = text.lower().split("x")
    if len(parts) != 2 or not all(part.isdigit() for part in parts):
        raise argparse.ArgumentTypeError("expected WIDTHxHEIGHT")
    return int(parts[0]), int(parts[1])


def cmd_place_window(args):
    """Hidden helper spawned by `play`: wait for the player's window, put it below the bar, and for browsers
    size it and remember the size it closes with."""
    window = play.find_window(args.pid)
    if window is None:
        return 0
    play.place_window(window)
    if args.resize:
        play.resize_window(window, args.resize)
    if args.watch:
        size = play.watch_window(window, args.pid)
        if size:
            with store.state_transaction() as state:
                store.set_prefs(state, [("browserWidth", str(size[0])), ("browserHeight", str(size[1]))])
    return 0


def cmd_login(args):
    """Open the fallback browser's profile on YouTube so the user can sign in (and add an ad blocker)."""
    play.launch(play.login_argv(args.player))
    emit({"login": args.player})
    return 0
```

In `build_parser`, replace the `play` and `place-window` blocks with:

```python
    p = sub.add_parser("play", help="play a video in the configured player and mark it seen")
    p.add_argument("--player", default="mpv", help="player command line (default: mpv)")
    p.add_argument("--fallback", default=None, help="player to open when mpv cannot open the video")
    p.add_argument("video_id")
    p.set_defaults(func=cmd_play)

    p = sub.add_parser("place-window", help=argparse.SUPPRESS)
    p.add_argument("pid", type=int)
    p.add_argument("--resize", type=size_arg, default=None)
    p.add_argument("--watch", action="store_true")
    p.set_defaults(func=cmd_place_window)

    p = sub.add_parser("login", help="open the fallback browser on YouTube so you can sign in")
    p.add_argument("--player", default="chromium", help="browser command line (default: chromium)")
    p.set_defaults(func=cmd_login)
```

- [ ] **Step 5: Run the whole suite**

Run: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests 2>&1 | tail -3`
Expected: `OK`, no warnings.

- [ ] **Step 6: Commit**

```bash
git add lib/fresh_tube/play.py lib/fresh_tube/cli.py tests/test_play.py
git commit -F - <<'EOF'
Add play --fallback, browser window sizing and the login command

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_011DPqvBbwQCc2wPWRZoVQkC
EOF
```

---

### Task 3: the mpv script — fallback on load failure, size only once loaded

**Files:**
- Modify: `mpv/fresh-tube.lua`

**Interfaces:**
- Consumes: `--script-opt=fresh_tube-fallback=<CMD>` (Task 1), CLI `play --player <CMD> -- <id>` (Task 2).

- [ ] **Step 1: Rewrite the script**

Replace the whole file with:

```lua
-- Fresh Tube's mpv companion. Loaded by `fresh-tube play` with
--   --script-opt=fresh_tube-id=<videoId> --script-opt=fresh_tube-bin=<path to bin/fresh-tube>
--   [--script-opt=fresh_tube-fallback=<player to use when the video cannot be opened>]
-- It tells the plugin when the video reaches its end (so the video leaves the
-- Watch later list), remembers the window size when mpv closes, and hands the
-- video to the fallback player when mpv could not open it at all.
local mp = require("mp")

local video_id = mp.get_opt("fresh_tube-id")
local bin = mp.get_opt("fresh_tube-bin")
local fallback = mp.get_opt("fresh_tube-fallback")
if not video_id or video_id == "" or not bin or bin == "" then
  return
end

local loaded = false
local done_sent = false
local fallback_sent = false
local last_w, last_h = 0, 0

-- Fire and forget: detached, and never tied to the playback lifetime, so a
-- call made while mpv is shutting down still runs.
local function run(args)
  mp.command_native({
    name = "subprocess",
    args = args,
    detach = true,
    playback_only = false,
  })
end

local function mark_done()
  if done_sent then
    return
  end
  done_sent = true
  run({ bin, "done", "--", video_id })
end

local function open_fallback()
  if fallback_sent or not fallback or fallback == "" then
    return
  end
  fallback_sent = true
  run({ bin, "play", "--player", fallback, "--", video_id })
end

mp.register_event("file-loaded", function()
  loaded = true
end)

mp.register_event("end-file", function(event)
  if event.reason == "eof" then
    mark_done()
  elseif event.reason == "error" and not loaded then
    -- mpv could not open the video at all (yt-dlp refused, private video...):
    -- a browser with the user's session usually can.
    open_fallback()
  end
end)

-- With keep-open=yes in the user's mpv.conf, mpv pauses at the end instead of
-- unloading the file; eof-reached covers that.
mp.observe_property("eof-reached", "bool", function(_, reached)
  if reached then
    mark_done()
  end
end)

-- Only sizes of a window that shows a video count: the black window of a
-- video that never loaded is not the size the user chose.
mp.observe_property("osd-dimensions", "native", function(_, dims)
  if loaded and dims and dims.w and dims.h and dims.w > 0 and dims.h > 0 then
    last_w, last_h = math.floor(dims.w), math.floor(dims.h)
  end
end)

mp.register_event("shutdown", function()
  if last_w > 0 and last_h > 0 then
    run({ bin, "prefs", "set", "playerWidth", tostring(last_w), "playerHeight", tostring(last_h) })
  end
end)
```

- [ ] **Step 2: Checks**

Run: `luac -p mpv/fresh-tube.lua && echo "syntax ok"; omarchy plugin validate . ; echo "exit=$?"`
Expected: `syntax ok`, `exit=0`. Do not run mpv.

- [ ] **Step 3: Commit**

```bash
git add mpv/fresh-tube.lua
git commit -F - <<'EOF'
Hand the video to the fallback player when mpv cannot open it

Also stop remembering the size of a window whose video never loaded.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_011DPqvBbwQCc2wPWRZoVQkC
EOF
```

---

### Task 4: panel setting, manifest 1.3.0, README

**Files:**
- Modify: `Panel.qml` (property near `playerCommand`, `play()`), `manifest.json`, `README.md`

**Interfaces:**
- Consumes: CLI `play --player <cmd> --fallback <cmd> -- <id>` (Task 2), `login` (Task 2).

- [ ] **Step 1: `Panel.qml`**

After `readonly property string playerCommand: String(setting("playerCommand", "mpv") || "mpv")` add:

```qml
  // Empty disables the fallback; the CLI only gets --fallback when there is one.
  readonly property string fallbackCommand: String(setting("fallbackCommand", "chromium") || "")
```

Replace the last line of `function play(video)` (`playCmd.start(["play", "--player", playerCommand, "--", video.videoId])`) with:

```qml
    var args = ["play", "--player", playerCommand]
    if (fallbackCommand !== "") args.push("--fallback", fallbackCommand)
    args.push("--", video.videoId)
    playCmd.start(args)
```

Check the shell log after saving (see Global Constraints); only reload lines are acceptable.

- [ ] **Step 2: `manifest.json`**

Version `1.2.0` → `1.3.0`. Defaults: `{ "playerCommand": "mpv", "fallbackCommand": "chromium", "refreshMinutes": 15 }`. Schema: add `{ "key": "fallbackCommand", "type": "string", "label": "Fallback player when mpv fails" }` after the `playerCommand` entry.

- [ ] **Step 3: `README.md`**

In "Use", after the bullet that starts `- Playing opens mpv as a small floating window below the bar` (ends with `mpv opens wherever it likes.`), add:

```markdown
- When mpv cannot open a video at all (YouTube sometimes blocks yt-dlp with a
  "sign in to confirm you're not a bot" check), the video opens in Chromium
  instead: app mode, no address bar, just YouTube's player, in a profile of
  its own, placed and sized like the mpv window. Run `fresh-tube login` once
  to sign in to YouTube in that profile (and, if you like, add an ad blocker
  there). In the browser the video starts from the beginning and does not
  leave Watch later by itself: use ✕ or `Delete`.
```

In the "Settings" table, after the `playerCommand` row, add:

```markdown
| `fallbackCommand` | `chromium` | Browser opened when mpv cannot open a video; empty disables it. |
```

In "Development", extend the CLI list with `login` (after `play`) and keep the rest of the sentence as it is.

- [ ] **Step 4: Everything green**

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v 2>&1 | tail -3   # OK, no warnings
node --test tests/model.test.js 2>&1 | grep -E '^ℹ (pass|fail)'                   # fail 0
omarchy plugin validate . ; echo "exit=$?"                                        # 0
quickshell log -p /usr/share/omarchy/shell -t 60 | grep -v qt.qpa.services | grep -iE 'error|warn|fresh' | tail -5
git status --short                                                                 # clean after commit
find . -name __pycache__ -not -path './.git/*'                                     # nothing
```

- [ ] **Step 5: Commit**

```bash
git add Panel.qml manifest.json README.md
git commit -F - <<'EOF'
Pass the fallback player from the panel; release 1.3.0

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_011DPqvBbwQCc2wPWRZoVQkC
EOF
```

- [ ] **Step 6: Manual checklist (for the user)**

The spec's five-item checklist under "Checklist manual".
