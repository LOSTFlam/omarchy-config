# Fresh Tube 1.2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Play videos through a `fresh-tube play` helper that puts mpv's window below the bar at a remembered size, and add a "Watch later" tab: a user-ordered list of pasted videos that leave when they reach the end or are marked seen.

**Architecture:** The Python CLI gains three modules: `videos.py` (video id parsing, oEmbed/yt-dlp metadata), `play.py` (player launch, Hyprland placement) and queue/prefs support in `store.py`, exposed as `queue`, `done`, `play` and a hidden `place-window` command. An mpv Lua script shipped in `mpv/` reports end-of-file and window size back through the CLI. The QML face adds a `tab` to the panel, a `WatchLaterView` with a paste field and a drag-reorderable list, and routes every play through the CLI.

**Tech Stack:** Python 3 stdlib (`argparse`, `json`, `subprocess`, `urllib`), `unittest`; QML/Quickshell (`qs.Ui`, `qs.Commons`, `QtQml.Models.DelegateModel`); mpv Lua API; `hyprctl` JSON.

**Spec:** `docs/superpowers/specs/2026-09-17-watch-later-design.md` (extends `docs/superpowers/specs/2026-09-16-fresh-tube-design.md`).

## Global Constraints

- Python stdlib only; tests never touch the network, mpv or hyprctl (mock `fresh_tube.feed.fetch_url`, `subprocess.run`, `fresh_tube.play.popen`, `fresh_tube.play.hyprctl`, `fresh_tube.play.dispatch`).
- Never `datetime.utcnow()`; only `datetime.datetime.now(datetime.timezone.utc)`.
- UI strings, README, comments and commit messages in English.
- Exit codes: 0 ok, 1 general, 2 usage, 3 network, 4 duplicate, 5 unknown id, 6 pin limit.
- Storage: `$XDG_CONFIG_HOME/fresh-tube/channels.json`, `$XDG_STATE_HOME/fresh-tube/state.json`; `state.json` gains `queue` (ordered list) and prefs `playerWidth` / `playerHeight` (ints 200–8000, absent until set).
- Exact strings: `That doesn't look like a YouTube video` (exit 2), `Already in the list` (exit 4), `Not in the list` (exit 5), `oembed: <e1>; yt-dlp: <e2>` (exit 3), `Could not start <player>: <reason>` (exit 1), `Nothing saved yet. Paste a video link above.`, tab labels `New` / `Watch later`.
- Player: `fresh-tube play [--player CMD] <videoId>` marks the video seen only after the launch succeeds; mpv gets `--save-position-on-quit --force-window=immediate --geometry=WxH --script=<plugin>/mpv/fresh-tube.lua --script-opts=fresh_tube-id=<id>,fresh_tube-bin=<abs bin/fresh-tube>`; other players get only the URL. Placement: `x = monitor.x + reserved[0]`, `y = monitor.y + reserved[1]`, `setfloating` only when not floating, `movewindowpixel exact X Y,address:<addr>`; window waited for up to 10 s in 100 ms steps; no hyprctl → nothing.
- Tests: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v` must print no warnings; `node --test tests/model.test.js` fail 0; `omarchy plugin validate .` exit 0; `find . -name __pycache__ -not -path './.git/*'` prints nothing.
- Every commit ends with the two trailer lines:
  `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_011DPqvBbwQCc2wPWRZoVQkC`.
  Identity fallback: `git -c user.name="Fernando Cancro" -c user.email="fernando.cancro@gmail.com" commit ...`.
- The plugin is live in the user's bar and hot-reloads on save: every saved QML must parse; after QML edits check `quickshell log -p /usr/share/omarchy/shell -t 80` (ignore `qt.qpa.services`). Never run `nmcli`, IPC, `omarchy bar set`, mpv, or the CLI against the real `~/.config/fresh-tube` / `~/.local/state/fresh-tube`.

---

## File Structure

- Create `lib/fresh_tube/videos.py`: `video_id_from(text)`, `parse_oembed(data)`, `fetch_oembed(video_id, fetch=None)`, `fetch_via_ytdlp(video_id, timeout)`, `fetch_metadata(video_id)`.
- Modify `lib/fresh_tube/ytdlp.py`: rename `_last_error` → `last_error` (public, reused by `videos.py`).
- Modify `lib/fresh_tube/store.py`: `queue` in `empty_state`/`load_state`, `queue_ids`, `queue_record`, `queue_add`, `queue_move`, `queue_remove`, `PREF_LIMITS` for `playerWidth`/`playerHeight`, `set_prefs`.
- Modify `lib/fresh_tube/cli.py`: `cmd_queue`, `cmd_done`, `cmd_play`, `cmd_place_window`, `prefs set` pairs, `queue` in the refresh payload.
- Create `lib/fresh_tube/play.py`: `build_argv`, `default_size`, `launch`, `start`, `hyprctl`, `dispatch`, `pid_alive`, `find_window`, `place_window`.
- Create `mpv/fresh-tube.lua`.
- Modify `Panel.qml`: `tab`, `queueVideos`, `addingVideo`, `play` via CLI, `finish`, `addToQueue`, `moveQueued`, `toggleTab`, runners `playCmd`, `doneCmd`, `queueAddCmd`, `queueMoveCmd`.
- Modify `VideoRow.qml`: `pinnable` (hide the pin button on queue rows).
- Modify `VideosView.qml`: tab header, content switch, key routing, `focusItem` per tab.
- Create `WatchLaterView.qml`: paste field, drag-reorderable list.
- Modify `README.md`, `manifest.json` (1.2.0).
- Tests: create `tests/test_videos.py`, `tests/test_play.py`; modify `tests/test_store.py`, `tests/test_cli.py`.

## Model plan

Task 1 sonnet · Task 2 haiku · Task 3 sonnet · Task 4 sonnet · Task 5 haiku · Task 6 sonnet · Task 7 sonnet · Task 8 haiku. Reviews: sonnet (Tasks 4, 6, 7), haiku otherwise. Final review: fable.

---

### Task 1: `videos.py` — video ids and metadata

**Files:**
- Create: `lib/fresh_tube/videos.py`
- Modify: `lib/fresh_tube/ytdlp.py` (rename `_last_error` → `last_error`, both definition and its one call site)
- Test: `tests/test_videos.py`

**Interfaces:**
- Consumes: `feed.fetch_url(url, timeout) -> bytes` (raises `FreshTubeError`), `ytdlp.THUMBNAIL_URL`, `ytdlp.last_error(stderr) -> str`.
- Produces: `videos.video_id_from(text) -> str | None`; `videos.VIDEO_ID_RE`; `videos.fetch_metadata(video_id) -> {"title", "channel", "thumbnail"}` (raises `FreshTubeError(NETWORK)` with `oembed: …; yt-dlp: …`); `videos.WATCH_URL`.

- [ ] **Step 1: Write the failing tests**

`tests/test_videos.py`:

```python
import subprocess
import unittest
from unittest import mock

import support  # noqa: F401  (puts lib/ on sys.path)
from fresh_tube import videos
from fresh_tube.errors import NETWORK, FreshTubeError

ID = "4_fM3Nv8BB0"
OEMBED = (b'{"title": "A title", "author_name": "Some Channel", '
          b'"thumbnail_url": "https://i.ytimg.com/vi/4_fM3Nv8BB0/hqdefault.jpg", "html": "<iframe>"}')


class Ids(unittest.TestCase):
    def test_every_link_shape_gives_the_id(self):
        for text in ("https://www.youtube.com/watch?v=4_fM3Nv8BB0",
                     "youtube.com/watch?v=4_fM3Nv8BB0&t=42s",
                     "https://m.youtube.com/watch?feature=share&v=4_fM3Nv8BB0",
                     "https://youtu.be/4_fM3Nv8BB0",
                     "youtu.be/4_fM3Nv8BB0?si=abc",
                     "https://www.youtube.com/shorts/4_fM3Nv8BB0",
                     "https://www.youtube.com/embed/4_fM3Nv8BB0?autoplay=1",
                     "https://www.youtube.com/live/4_fM3Nv8BB0",
                     "  4_fM3Nv8BB0  "):
            self.assertEqual(videos.video_id_from(text), ID, text)

    def test_channels_and_noise_are_not_videos(self):
        for text in ("https://www.youtube.com/@LinusTechTips",
                     "https://www.youtube.com/channel/UCXuqSBlHAE6Xw-yeJA0Tunw",
                     "UCXuqSBlHAE6Xw-yeJA0Tunw",
                     "https://vimeo.com/12345",
                     "https://www.youtube.com/watch?v=short",
                     "hello world", "", None):
            self.assertIsNone(videos.video_id_from(text), text)


class Oembed(unittest.TestCase):
    def test_parse_picks_title_channel_and_thumbnail(self):
        self.assertEqual(videos.parse_oembed(OEMBED),
                         {"title": "A title", "channel": "Some Channel",
                          "thumbnail": "https://i.ytimg.com/vi/4_fM3Nv8BB0/hqdefault.jpg"})

    def test_parse_rejects_non_json_and_non_objects(self):
        with self.assertRaises(FreshTubeError) as caught:
            videos.parse_oembed(b"<html>")
        self.assertEqual(caught.exception.code, NETWORK)
        with self.assertRaises(FreshTubeError):
            videos.parse_oembed(b"[1, 2]")

    def test_fetch_asks_the_oembed_endpoint_for_the_watch_url(self):
        fetch = mock.Mock(return_value=OEMBED)
        parsed = videos.fetch_oembed(ID, fetch=fetch)
        self.assertEqual(parsed["title"], "A title")
        url, timeout = fetch.call_args.args
        self.assertTrue(url.startswith("https://www.youtube.com/oembed?url="), url)
        self.assertIn("watch%3Fv%3D4_fM3Nv8BB0", url)
        self.assertTrue(url.endswith("&format=json"), url)
        self.assertEqual(timeout, videos.OEMBED_TIMEOUT)


class Ytdlp(unittest.TestCase):
    def test_reads_title_and_channel_and_builds_the_thumbnail(self):
        done = mock.Mock(returncode=0, stdout="A title\tSome Channel\n", stderr="")
        with mock.patch("fresh_tube.videos.subprocess.run", return_value=done) as run:
            parsed = videos.fetch_via_ytdlp(ID)
        self.assertEqual(parsed, {"title": "A title", "channel": "Some Channel",
                                  "thumbnail": "https://i.ytimg.com/vi/4_fM3Nv8BB0/hqdefault.jpg"})
        args = run.call_args.args[0]
        self.assertEqual(args[0], "yt-dlp")
        self.assertIn("--no-download", args)
        self.assertEqual(args[-1], "https://www.youtube.com/watch?v=4_fM3Nv8BB0")

    def test_na_fields_are_empty(self):
        done = mock.Mock(returncode=0, stdout="NA\tNA\n", stderr="")
        with mock.patch("fresh_tube.videos.subprocess.run", return_value=done):
            parsed = videos.fetch_via_ytdlp(ID)
        self.assertEqual((parsed["title"], parsed["channel"]), ("", ""))

    def test_failures_become_network_errors(self):
        cases = [
            (dict(return_value=mock.Mock(returncode=1, stdout="", stderr="ERROR: [youtube] x: Video unavailable")),
             "Video unavailable"),
            (dict(side_effect=FileNotFoundError), "not installed"),
            (dict(side_effect=subprocess.TimeoutExpired("yt-dlp", 40)), "timed out"),
        ]
        for patch_kw, message in cases:
            with mock.patch("fresh_tube.videos.subprocess.run", **patch_kw), \
                 self.assertRaises(FreshTubeError) as caught:
                videos.fetch_via_ytdlp(ID)
            self.assertEqual(str(caught.exception), message)
            self.assertEqual(caught.exception.code, NETWORK)


class Metadata(unittest.TestCase):
    def test_oembed_first(self):
        with mock.patch("fresh_tube.videos.fetch_url", return_value=OEMBED), \
             mock.patch("fresh_tube.videos.subprocess.run", side_effect=AssertionError("yt-dlp not expected")):
            self.assertEqual(videos.fetch_metadata(ID)["channel"], "Some Channel")

    def test_ytdlp_when_oembed_fails(self):
        done = mock.Mock(returncode=0, stdout="A title\tSome Channel\n", stderr="")
        with mock.patch("fresh_tube.videos.fetch_url", side_effect=FreshTubeError("HTTP 404 from oembed", NETWORK)), \
             mock.patch("fresh_tube.videos.subprocess.run", return_value=done):
            self.assertEqual(videos.fetch_metadata(ID)["title"], "A title")

    def test_both_failing_names_both(self):
        with mock.patch("fresh_tube.videos.fetch_url", side_effect=FreshTubeError("HTTP 404 from oembed", NETWORK)), \
             mock.patch("fresh_tube.videos.subprocess.run", side_effect=FileNotFoundError), \
             self.assertRaises(FreshTubeError) as caught:
            videos.fetch_metadata(ID)
        self.assertEqual(str(caught.exception), "oembed: HTTP 404 from oembed; yt-dlp: not installed")
        self.assertEqual(caught.exception.code, NETWORK)

    def test_unexpected_exceptions_are_named(self):
        with mock.patch("fresh_tube.videos.fetch_url", side_effect=ValueError("boom")), \
             mock.patch("fresh_tube.videos.subprocess.run", side_effect=FileNotFoundError), \
             self.assertRaises(FreshTubeError) as caught:
            videos.fetch_metadata(ID)
        self.assertEqual(str(caught.exception), "oembed: ValueError: boom; yt-dlp: not installed")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_videos.py' 2>&1 | tail -5`
Expected: `ImportError`/`AttributeError` mentioning `fresh_tube.videos` (module missing).

- [ ] **Step 3: Rename the yt-dlp error helper**

In `lib/fresh_tube/ytdlp.py` rename `def _last_error(stderr):` to `def last_error(stderr):` and its call in `fetch_via_ytdlp` (`last_error(done.stderr)`). Nothing else changes.

- [ ] **Step 4: Write `lib/fresh_tube/videos.py`**

```python
"""One video: its id from whatever the user pasted, and its title, channel and thumbnail."""
import json
import re
import subprocess
import urllib.parse

from .errors import NETWORK, FreshTubeError
from .feed import fetch_url
from .ytdlp import THUMBNAIL_URL, last_error

VIDEO_ID = r"[0-9A-Za-z_-]{11}"
VIDEO_ID_RE = re.compile(r"^" + VIDEO_ID + r"$")
HOST_RE = re.compile(r"^(?:https?://)?(?:www\.|m\.)?(youtube\.com|youtu\.be)(/\S*)?$", re.IGNORECASE)
QUERY_ID_RE = re.compile(r"[?&]v=(" + VIDEO_ID + r")(?:[&#]|$)")
SHORT_PATH_RE = re.compile(r"^/(" + VIDEO_ID + r")(?:[/?#]|$)")
LONG_PATH_RE = re.compile(r"^/(?:shorts|embed|live|v)/(" + VIDEO_ID + r")(?:[/?#]|$)")
WATCH_URL = "https://www.youtube.com/watch?v={}"
OEMBED_URL = "https://www.youtube.com/oembed?url={}&format=json"
OEMBED_TIMEOUT = 10
YTDLP_TIMEOUT = 40


def video_id_from(text):
    """The 11-character id in a watch, youtu.be, shorts, embed or live link, or a bare id; else None."""
    text = (text or "").strip()
    if VIDEO_ID_RE.match(text):
        return text
    found = HOST_RE.match(text)
    if not found:
        return None
    host, path = found.group(1).lower(), found.group(2) or "/"
    query = QUERY_ID_RE.search(path)
    if query:
        return query.group(1)
    pattern = SHORT_PATH_RE if host == "youtu.be" else LONG_PATH_RE
    found = pattern.match(path)
    return found.group(1) if found else None


def parse_oembed(data):
    """{"title", "channel", "thumbnail"} from the oEmbed JSON bytes."""
    try:
        info = json.loads(data.decode("utf-8", "replace"))
    except ValueError as e:
        raise FreshTubeError(f"oEmbed is not valid JSON: {e}", NETWORK)
    if not isinstance(info, dict):
        raise FreshTubeError("oEmbed is not an object", NETWORK)
    return {"title": str(info.get("title") or ""), "channel": str(info.get("author_name") or ""),
            "thumbnail": str(info.get("thumbnail_url") or "")}


def fetch_oembed(video_id, fetch=None):
    fetch = fetch or fetch_url
    url = OEMBED_URL.format(urllib.parse.quote(WATCH_URL.format(video_id), safe=""))
    return parse_oembed(fetch(url, OEMBED_TIMEOUT))


def _field(value):
    value = value.strip()
    return "" if value == "NA" else value


def fetch_via_ytdlp(video_id, timeout=YTDLP_TIMEOUT):
    args = ["yt-dlp", "--no-download", "--print", "%(title)s\t%(channel)s", WATCH_URL.format(video_id)]
    try:
        done = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError:
        raise FreshTubeError("not installed", NETWORK)
    except subprocess.TimeoutExpired:
        raise FreshTubeError("timed out", NETWORK)
    except OSError as e:
        raise FreshTubeError(str(e), NETWORK)
    if done.returncode != 0:
        raise FreshTubeError(last_error(done.stderr) or f"exit code {done.returncode}", NETWORK)
    lines = done.stdout.strip().splitlines()
    parts = (lines[-1] if lines else "").split("\t")
    title = _field(parts[0]) if parts else ""
    channel = _field(parts[1]) if len(parts) > 1 else ""
    return {"title": title, "channel": channel, "thumbnail": THUMBNAIL_URL.format(video_id)}


def _failure(e):
    return str(e) if isinstance(e, FreshTubeError) else f"{type(e).__name__}: {e}"


def fetch_metadata(video_id):
    """Title, channel and thumbnail: oEmbed first, yt-dlp when it fails, else why both failed."""
    try:
        return fetch_oembed(video_id)
    except Exception as e:
        oembed_error = _failure(e)
    try:
        return fetch_via_ytdlp(video_id)
    except Exception as e:
        raise FreshTubeError(f"oembed: {oembed_error}; yt-dlp: {_failure(e)}", NETWORK)
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests 2>&1 | tail -3`
Expected: `OK`, no warnings, the whole suite (82 existing + 12 new).

- [ ] **Step 6: Commit**

```bash
git add lib/fresh_tube/videos.py lib/fresh_tube/ytdlp.py tests/test_videos.py
git commit -F - <<'EOF'
Add video id parsing and oEmbed metadata

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_011DPqvBbwQCc2wPWRZoVQkC
EOF
```

---

### Task 2: `store.py` — the queue and the player prefs

**Files:**
- Modify: `lib/fresh_tube/store.py`
- Test: `tests/test_store.py`

**Interfaces:**
- Produces: `store.queue_ids(state) -> list[str]`, `store.queue_record(video_id, meta) -> dict`, `store.queue_add(state, video)` (raises `Already in the list` DUPLICATE), `store.queue_move(state, video_id, index)` (clamps; raises `Not in the list` UNKNOWN), `store.queue_remove(state, video_id) -> bool`, `store.set_prefs(state, pairs)` (atomic), prefs keys `playerWidth`/`playerHeight` in `PREF_LIMITS` (200–8000), `empty_state()["queue"] == []`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_store.py`:

```python
META = {"title": "A title", "channel": "Some Channel", "thumbnail": "https://i.ytimg.com/vi/v1/hqdefault.jpg"}


class Queue(StoreTest):
    def record(self, video_id):
        return store.queue_record(video_id, META)

    def test_record_shape(self):
        record = self.record("v1")
        self.assertEqual(record["videoId"], "v1")
        self.assertEqual(record["url"], "https://www.youtube.com/watch?v=v1")
        self.assertEqual((record["title"], record["channel"], record["thumbnail"]),
                         ("A title", "Some Channel", META["thumbnail"]))
        self.assertRegex(record["addedAt"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\+00:00$")

    def test_add_keeps_order_and_rejects_duplicates(self):
        state = store.load_state()
        self.assertEqual(state["queue"], [])
        store.queue_add(state, self.record("v1"))
        store.queue_add(state, self.record("v2"))
        self.assertEqual(store.queue_ids(state), ["v1", "v2"])
        with self.assertRaises(FreshTubeError) as caught:
            store.queue_add(state, self.record("v1"))
        self.assertEqual(str(caught.exception), "Already in the list")
        self.assertEqual(caught.exception.code, DUPLICATE)

    def test_move_clamps_to_the_ends(self):
        state = store.load_state()
        for video_id in ("v1", "v2", "v3"):
            store.queue_add(state, self.record(video_id))
        store.queue_move(state, "v3", 0)
        self.assertEqual(store.queue_ids(state), ["v3", "v1", "v2"])
        store.queue_move(state, "v3", 99)
        self.assertEqual(store.queue_ids(state), ["v1", "v2", "v3"])
        store.queue_move(state, "v2", -5)
        self.assertEqual(store.queue_ids(state), ["v2", "v1", "v3"])
        store.queue_move(state, "v1", 1)
        self.assertEqual(store.queue_ids(state), ["v2", "v1", "v3"])
        with self.assertRaises(FreshTubeError) as caught:
            store.queue_move(state, "nope", 0)
        self.assertEqual(str(caught.exception), "Not in the list")
        self.assertEqual(caught.exception.code, UNKNOWN)

    def test_remove_reports_whether_it_was_there(self):
        state = store.load_state()
        store.queue_add(state, self.record("v1"))
        self.assertTrue(store.queue_remove(state, "v1"))
        self.assertFalse(store.queue_remove(state, "v1"))
        self.assertEqual(state["queue"], [])

    def test_queue_survives_save_and_load_in_order(self):
        state = store.load_state()
        for video_id in ("v2", "v1"):
            store.queue_add(state, self.record(video_id))
        store.save_state(state)
        self.assertEqual(store.queue_ids(store.load_state()), ["v2", "v1"])

    def test_load_drops_bad_entries_and_duplicates(self):
        self.box.write_json(self.box.state_file, {
            "version": 1, "queue": [{"videoId": "v1", "title": "one"}, "junk", {"title": "no id"},
                                    {"videoId": ""}, {"videoId": "v1", "title": "dup"}, {"videoId": "v2"}]})
        self.assertEqual([q["videoId"] for q in store.load_state()["queue"]], ["v1", "v2"])
        self.assertEqual(store.load_state()["queue"][0]["title"], "one")
        self.box.write_json(self.box.state_file, {"version": 1, "queue": "nope"})
        self.assertEqual(store.load_state()["queue"], [])

    def test_queue_does_not_affect_unseen_or_pins(self):
        state = store.load_state()
        store.update_feed(state, "UC1", PARSED, "2026-09-16T10:00:00+00:00")
        store.queue_add(state, self.record(PARSED["latest"]["videoId"]))
        channels = [{"id": "UC1", "name": "One"}]
        self.assertEqual([v["videoId"] for v in store.unseen_videos(state, channels)], [PARSED["latest"]["videoId"]])
        store.mark_seen(state, PARSED["latest"]["videoId"])
        self.assertEqual(store.unseen_videos(state, channels), [])
        self.assertEqual(store.queue_ids(state), [PARSED["latest"]["videoId"]])


class PlayerPrefs(StoreTest):
    def test_player_size_is_absent_until_set(self):
        state = store.load_state()
        self.assertNotIn("playerWidth", state["prefs"])
        store.set_pref(state, "playerWidth", "860")
        store.set_pref(state, "playerHeight", "484")
        store.save_state(state)
        prefs = store.load_state()["prefs"]
        self.assertEqual((prefs["playerWidth"], prefs["playerHeight"]), (860, 484))

    def test_player_size_limits(self):
        state = store.load_state()
        with self.assertRaises(FreshTubeError) as caught:
            store.set_pref(state, "playerWidth", "100")
        self.assertIn("between 200 and 8000", str(caught.exception))
        self.assertEqual(caught.exception.code, USAGE)
        self.box.write_json(self.box.state_file, {"version": 1, "prefs": {"playerWidth": 9999, "playerHeight": "x"}})
        self.assertNotIn("playerWidth", store.load_state()["prefs"])
        self.assertNotIn("playerHeight", store.load_state()["prefs"])

    def test_set_prefs_is_all_or_nothing(self):
        state = store.load_state()
        prefs = store.set_prefs(state, [("playerWidth", "860"), ("playerHeight", "484")])
        self.assertEqual((prefs["playerWidth"], prefs["playerHeight"]), (860, 484))
        with self.assertRaises(FreshTubeError):
            store.set_prefs(state, [("playerWidth", "900"), ("playerHeight", "10")])
        self.assertEqual((state["prefs"]["playerWidth"], state["prefs"]["playerHeight"]), (860, 484))
```

Also in the existing `State` test that compares `store.load_state()` against a literal `{"version": 1, "seen": [], ... "pins": []}` (around `tests/test_store.py:89-92`), add `"queue": []` to the literal.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_store.py' 2>&1 | grep -E '^(ERROR|FAIL|Ran|FAILED)' | head`
Expected: `AttributeError: module 'fresh_tube.store' has no attribute 'queue_record'` (and siblings); the `State` literal test fails on the missing `queue` key.

- [ ] **Step 3: Implement in `lib/fresh_tube/store.py`**

Replace the prefs constants and `empty_state`:

```python
DEFAULT_PREFS = {"width": 420, "height": 520, "pinned": False}
PREF_LIMITS = {"width": (300, 4000), "height": (220, 4000),
               "playerWidth": (200, 8000), "playerHeight": (200, 8000)}
MAX_PINS = 3
WATCH_URL = "https://www.youtube.com/watch?v={}"


def empty_state():
    return {"version": STATE_VERSION, "seen": [], "feeds": {}, "fetchedAt": "",
            "prefs": dict(DEFAULT_PREFS), "pins": [], "queue": []}
```

In `load_state`, replace the prefs loop and add the queue block at the end (before `return state`):

```python
    prefs = data.get("prefs")
    if isinstance(prefs, dict):
        for key in set(DEFAULT_PREFS) | set(PREF_LIMITS):
            if key in prefs and _valid_pref(key, prefs[key]):
                state["prefs"][key] = prefs[key]
    if isinstance(data.get("pins"), list):
        state["pins"] = [dict(p) for p in data["pins"] if _valid_pin(p)][:MAX_PINS]
    if isinstance(data.get("queue"), list):
        seen_ids = set()
        for entry in data["queue"]:
            if _valid_queue_entry(entry) and entry["videoId"] not in seen_ids:
                seen_ids.add(entry["videoId"])
                state["queue"].append(dict(entry))
    return state
```

Add after `_valid_pin`:

```python
def _valid_queue_entry(entry):
    return isinstance(entry, dict) and isinstance(entry.get("videoId"), str) and entry["videoId"] != ""
```

Add after `set_pref`:

```python
def set_prefs(state, pairs):
    """Apply several (key, value) pairs; nothing changes unless every pair is valid."""
    trial = {"prefs": dict(state["prefs"])}
    for key, value in pairs:
        set_pref(trial, key, value)
    state["prefs"] = trial["prefs"]
    return state["prefs"]
```

Append at the end of the file:

```python
# --- watch later --------------------------------------------------------------

def queue_ids(state):
    return [q["videoId"] for q in state.get("queue", [])]


def queue_record(video_id, meta):
    """The public shape of a saved video: what the panel shows and what `play` needs."""
    return {"videoId": video_id, "title": meta.get("title", ""), "channel": meta.get("channel", ""),
            "thumbnail": meta.get("thumbnail", ""), "url": WATCH_URL.format(video_id), "addedAt": now_iso()}


def queue_add(state, video):
    queue = state.setdefault("queue", [])
    if any(q["videoId"] == video["videoId"] for q in queue):
        raise FreshTubeError("Already in the list", DUPLICATE)
    queue.append(dict(video))
    return queue


def queue_move(state, video_id, index):
    """Put the video at `index` (clamped to the list); the others keep their relative order."""
    queue = state.setdefault("queue", [])
    for position, entry in enumerate(queue):
        if entry["videoId"] == video_id:
            queue.pop(position)
            queue.insert(max(0, min(int(index), len(queue))), entry)
            return queue
    raise FreshTubeError("Not in the list", UNKNOWN)


def queue_remove(state, video_id):
    """Drop the video from the list; True when it was there."""
    queue = state.setdefault("queue", [])
    kept = [q for q in queue if q["videoId"] != video_id]
    state["queue"] = kept
    return len(kept) != len(queue)
```

- [ ] **Step 4: Run the whole suite**

Run: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests 2>&1 | tail -3`
Expected: `OK`, no warnings.

- [ ] **Step 5: Commit**

```bash
git add lib/fresh_tube/store.py tests/test_store.py
git commit -F - <<'EOF'
Store the Watch later queue and the player size

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_011DPqvBbwQCc2wPWRZoVQkC
EOF
```

---

### Task 3: CLI — `queue`, `done`, `prefs set` pairs, `queue` in refresh

**Files:**
- Modify: `lib/fresh_tube/cli.py`
- Test: `tests/test_cli.py`

**Interfaces:**
- Consumes: `videos.video_id_from`, `videos.fetch_metadata`, `store.queue_*`, `store.set_prefs`.
- Produces: commands `queue add <url>`, `queue move <id> <pos>`, `queue [--json]`, `done <id>` → `{"done", "removed"}`, `prefs set k v [k v ...]`; `refresh --json` payload key `queue`.

- [ ] **Step 1: Write the failing tests**

In `tests/test_cli.py`, in `Refresh.test_no_channels`, change the expected payload to
`{"videos": [], "pinned": [], "queue": [], "fetchedAt": "", "offline": False, "channelCount": 0, "errors": []}`.

In `Prefs.test_get_and_set` append:

```python
        self.assertEqual(self.json("prefs", "set", "playerWidth", "860", "playerHeight", "484")["playerHeight"], 484)
        self.assertIn("between 200 and 8000", self.fails(2, "prefs", "set", "playerWidth", "900", "playerHeight", "10"))
        self.assertEqual(self.json("prefs", "get")["playerWidth"], 860)
```

Append a new class:

```python
META = {"title": "A title", "channel": "Some Channel", "thumbnail": "https://i.ytimg.com/vi/v/hqdefault.jpg"}
VID = "4_fM3Nv8BB0"


class Queue(CliTest):
    def setUp(self):
        super().setUp()
        self.box.apply()

    def add(self, text, meta=None, error=None):
        kw = {"side_effect": error} if error else {"return_value": meta or META}
        with mock.patch("fresh_tube.videos.fetch_metadata", **kw), support.captured() as (out, err):
            code = cli.main(["queue", "add", "--", text])
        return code, out.getvalue(), err.getvalue()

    def test_add_prints_the_record_and_appends(self):
        code, out, err = self.add("https://youtu.be/" + VID)
        self.assertEqual(code, 0, err)
        record = json.loads(out)
        self.assertEqual((record["videoId"], record["title"], record["channel"]), (VID, "A title", "Some Channel"))
        self.assertEqual(record["url"], "https://www.youtube.com/watch?v=" + VID)
        code, out, err = self.add("abcdefghijk", meta=dict(META, title="Second"))
        self.assertEqual(code, 0, err)
        self.assertEqual([q["videoId"] for q in self.json("queue", "--json")["queue"]], [VID, "abcdefghijk"])

    def test_add_rejects_non_videos_and_duplicates(self):
        with mock.patch("fresh_tube.videos.fetch_metadata", side_effect=AssertionError("no lookup")):
            with support.captured() as (out, err):
                self.assertEqual(cli.main(["queue", "add", "--", "https://www.youtube.com/@LinusTechTips"]), 2)
            self.assertIn("That doesn't look like a YouTube video", err.getvalue())
        self.add(VID)
        with mock.patch("fresh_tube.videos.fetch_metadata", side_effect=AssertionError("no lookup")):
            with support.captured() as (out, err):
                self.assertEqual(cli.main(["queue", "add", "--", VID]), 4)
            self.assertIn("Already in the list", err.getvalue())

    def test_add_without_metadata_is_a_network_error(self):
        code, out, err = self.add(VID, error=FreshTubeError("oembed: HTTP 404; yt-dlp: not installed", NETWORK))
        self.assertEqual(code, 3)
        self.assertIn("oembed: HTTP 404; yt-dlp: not installed", err)
        self.assertEqual(self.json("queue", "--json"), {"queue": []})

    def test_move_and_plain_listing(self):
        self.add("v1v1v1v1v1v")
        self.add("v2v2v2v2v2v", meta=dict(META, title="Two"))
        payload = self.json("queue", "move", "--", "v2v2v2v2v2v", "0")
        self.assertEqual([q["videoId"] for q in payload["queue"]], ["v2v2v2v2v2v", "v1v1v1v1v1v"])
        self.assertIn("Not in the list", self.fails(5, "queue", "move", "--", "nope", "0"))
        self.assertIn("whole number", self.fails(2, "queue", "move", "--", "v1v1v1v1v1v", "x"))
        self.assertEqual(self.ok("queue").splitlines()[0], "Some Channel: Two  https://www.youtube.com/watch?v=v2v2v2v2v2v")

    def test_done_removes_and_marks_seen_idempotently(self):
        self.add(VID)
        self.assertEqual(self.json("done", "--", VID), {"done": VID, "removed": True})
        self.assertEqual(self.json("done", "--", VID), {"done": VID, "removed": False})
        self.assertEqual(self.json("queue", "--json"), {"queue": []})
        self.assertIn(VID, self.box.read_json(self.box.state_file)["seen"])

    def test_refresh_payload_carries_the_queue(self):
        self.add(VID)
        self.box.write_json(self.box.channels_file, {"version": 1, "channels": []})
        with mock.patch("fresh_tube.feed.fetch_feed", side_effect=AssertionError("network")), \
             support.captured() as (out, err):
            self.assertEqual(cli.main(["refresh", "--json", "--cached"]), 0, err.getvalue())
        self.assertEqual([q["videoId"] for q in json.loads(out.getvalue())["queue"]], [VID])
```

Note: `seen` ids that no feed lists are pruned on live refresh; `done` runs no pruning, so the `seen` assertion holds.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_cli.py' 2>&1 | grep -E '^(ERROR|FAIL|Ran|FAILED)' | head`
Expected: usage errors (exit 2, `invalid choice: 'queue'`) in the new tests, plus the two updated assertions failing.

- [ ] **Step 3: Implement in `lib/fresh_tube/cli.py`**

Change the import line to `from . import feed, resolve, store, videos, ytdlp`.

In `refresh_all`, add `"queue": list(state.get("queue", []))` to the returned dict (after `"pinned"`).

Replace `cmd_prefs`:

```python
def cmd_prefs(args):
    state = store.load_state()
    if args.action == "set":
        pairs = args.pairs
        if not pairs or len(pairs) % 2 != 0:
            raise FreshTubeError("prefs set needs a key and a value", USAGE)
        store.set_prefs(state, list(zip(pairs[0::2], pairs[1::2])))
        store.save_state(state)
    emit(state["prefs"])
    return 0
```

Add after `cmd_unpin`:

```python
def queue_payload(state):
    return {"queue": list(state.get("queue", []))}


def cmd_queue(args):
    if args.action == "add":
        if not args.value:
            raise FreshTubeError("queue add needs a video URL or id", USAGE)
        video_id = videos.video_id_from(args.value)
        if not video_id:
            raise FreshTubeError("That doesn't look like a YouTube video", USAGE)
        if video_id in store.queue_ids(store.load_state()):
            raise FreshTubeError("Already in the list", DUPLICATE)
        # Network first, file last, like `add`.
        meta = videos.fetch_metadata(video_id)
        state = store.load_state()
        record = store.queue_record(video_id, meta)
        store.queue_add(state, record)
        store.save_state(state)
        emit(record)
        return 0
    if args.action == "move":
        if not args.value or args.position is None:
            raise FreshTubeError("queue move needs a video id and a position", USAGE)
        try:
            index = int(args.position)
        except ValueError:
            raise FreshTubeError("position must be a whole number", USAGE)
        state = store.load_state()
        store.queue_move(state, args.value, index)
        store.save_state(state)
        emit(queue_payload(state))
        return 0
    state = store.load_state()
    if args.json:
        emit(queue_payload(state))
        return 0
    for q in state["queue"]:
        print(f"{q['channel']}: {q['title']}  {q['url']}")
    return 0


def cmd_done(args):
    """Finished with a video: out of the list, and seen."""
    state = store.load_state()
    removed = store.queue_remove(state, args.video_id)
    store.mark_seen(state, args.video_id)
    store.save_state(state)
    emit({"done": args.video_id, "removed": removed})
    return 0
```

In `build_parser`, replace the `prefs` block and add the two new subparsers before `return parser, sub`:

```python
    p = sub.add_parser("prefs", help="read or change the preferences (width, height, pinned, playerWidth, playerHeight)")
    p.add_argument("action", choices=["get", "set"])
    p.add_argument("pairs", nargs="*", metavar="key value")
    p.set_defaults(func=cmd_prefs)

    p = sub.add_parser("queue", help="the Watch later list: `queue add <url>`, `queue move <id> <pos>`, `queue --json`")
    p.add_argument("action", nargs="?", choices=["add", "move"])
    p.add_argument("value", nargs="?", help="video URL or id")
    p.add_argument("position", nargs="?", help="new index for `move`, from 0")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_queue)

    p = sub.add_parser("done", help="finished with a video: out of the Watch later list, and seen")
    p.add_argument("video_id")
    p.set_defaults(func=cmd_done)
```

- [ ] **Step 4: Run the whole suite**

Run: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests 2>&1 | tail -3`
Expected: `OK`, no warnings.

- [ ] **Step 5: Commit**

```bash
git add lib/fresh_tube/cli.py tests/test_cli.py
git commit -F - <<'EOF'
Add queue, done and multi-pair prefs to the CLI

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_011DPqvBbwQCc2wPWRZoVQkC
EOF
```

---

### Task 4: `play.py` and the `play` / `place-window` commands

**Files:**
- Create: `lib/fresh_tube/play.py`
- Modify: `lib/fresh_tube/cli.py`
- Test: `tests/test_play.py`

**Interfaces:**
- Consumes: `store.load_state`, `store.mark_seen`, `store.save_state`, `videos.VIDEO_ID_RE`, `videos.WATCH_URL`.
- Produces: `play.build_argv(player_command, video_id, size) -> list[str]`, `play.default_size(monitors) -> (w, h)`, `play.start(player_command, video_id, size) -> pid`, `play.find_window(pid) -> dict | None`, `play.place_window(client)`; CLI `play [--player CMD] <videoId>` → `{"played": id}`; hidden CLI `place-window <pid>`.
- The QML (Task 6) calls `play --player <playerCommand> -- <videoId>`.

- [ ] **Step 1: Write the failing tests**

`tests/test_play.py`:

```python
import json
import os
import unittest
from unittest import mock

import support
from fresh_tube import cli, play, store

VID = "4_fM3Nv8BB0"
URL = "https://www.youtube.com/watch?v=" + VID
MONITORS = [{"id": 0, "name": "HDMI-A-1", "x": 0, "y": 0, "width": 1920, "height": 1080, "scale": 1,
             "reserved": [0, 26, 0, 0], "focused": True},
            {"id": 1, "name": "DP-1", "x": 1920, "y": 0, "width": 2560, "height": 1440, "scale": 2,
             "reserved": [0, 0, 0, 40], "focused": False}]


def client(pid, floating=True, monitor=0):
    return {"address": "0x55aa", "pid": pid, "class": "mpv", "floating": floating, "monitor": monitor}


class Argv(unittest.TestCase):
    def test_mpv_gets_the_companion_flags(self):
        argv = play.build_argv("mpv", VID, (860, 484))
        self.assertEqual(argv[0], "mpv")
        self.assertEqual(argv[-1], URL)
        self.assertIn("--save-position-on-quit", argv)
        self.assertIn("--force-window=immediate", argv)
        self.assertIn("--geometry=860x484", argv)
        self.assertIn("--script=" + play.SCRIPT_PATH, argv)
        self.assertIn(f"--script-opts=fresh_tube-id={VID},fresh_tube-bin={play.BIN_PATH}", argv)
        self.assertTrue(play.SCRIPT_PATH.endswith(os.path.join("mpv", "fresh-tube.lua")))
        self.assertTrue(os.path.isabs(play.BIN_PATH))

    def test_mpv_with_options_and_a_path_still_counts_as_mpv(self):
        argv = play.build_argv("/usr/bin/mpv --profile=big", VID, (860, 484))
        self.assertEqual(argv[:2], ["/usr/bin/mpv", "--profile=big"])
        self.assertIn("--save-position-on-quit", argv)

    def test_other_players_get_only_the_url(self):
        self.assertEqual(play.build_argv("vlc --fullscreen", VID, (860, 484)), ["vlc", "--fullscreen", URL])

    def test_empty_command_means_mpv(self):
        self.assertEqual(play.build_argv("", VID, (860, 484))[0], "mpv")


class DefaultSize(unittest.TestCase):
    def test_quarter_of_the_focused_monitor_logical_width(self):
        self.assertEqual(play.default_size(MONITORS), (480, 270))

    def test_scale_is_honoured_and_first_monitor_is_the_fallback(self):
        self.assertEqual(play.default_size([dict(MONITORS[1], focused=True)]), (320, 180))
        self.assertEqual(play.default_size([dict(MONITORS[0], focused=False)]), (480, 270))

    def test_no_or_bad_monitors(self):
        self.assertEqual(play.default_size(None), play.DEFAULT_SIZE)
        self.assertEqual(play.default_size([]), play.DEFAULT_SIZE)
        self.assertEqual(play.default_size([{"width": "x"}]), play.DEFAULT_SIZE)


class Placement(unittest.TestCase):
    def setUp(self):
        self.dispatches = []
        self.addCleanup(mock.patch.stopall)
        mock.patch("fresh_tube.play.dispatch", side_effect=lambda *a: self.dispatches.append(a)).start()
        mock.patch("fresh_tube.play.sleep").start()
        mock.patch("fresh_tube.play.pid_alive", return_value=True).start()

    def test_moves_below_the_bar_of_its_monitor(self):
        with mock.patch("fresh_tube.play.hyprctl", side_effect=lambda what: {"clients": [client(7)], "monitors": MONITORS}[what]):
            play.place_window(play.find_window(7))
        self.assertEqual(self.dispatches, [("movewindowpixel", "exact 0 26,address:0x55aa")])

    def test_floats_first_when_tiled_and_uses_the_monitor_origin(self):
        with mock.patch("fresh_tube.play.hyprctl", side_effect=lambda what: {"clients": [client(7, floating=False, monitor=1)], "monitors": MONITORS}[what]):
            play.place_window(play.find_window(7))
        self.assertEqual(self.dispatches, [("setfloating", "address:0x55aa"),
                                           ("movewindowpixel", "exact 1920 0,address:0x55aa")])

    def test_waits_for_the_window_then_gives_up(self):
        clocks = iter([0.0, 0.0, 5.0, 11.0])
        with mock.patch("fresh_tube.play.hyprctl", return_value=[client(8)]) as hyprctl, \
             mock.patch("fresh_tube.play.monotonic", side_effect=lambda: next(clocks)):
            self.assertIsNone(play.find_window(7))
        self.assertGreaterEqual(hyprctl.call_count, 2)
        self.assertEqual(self.dispatches, [])

    def test_stops_when_the_player_died(self):
        with mock.patch("fresh_tube.play.hyprctl", return_value=[]) as hyprctl, \
             mock.patch("fresh_tube.play.pid_alive", return_value=False):
            self.assertIsNone(play.find_window(7))
        self.assertEqual(hyprctl.call_count, 1)

    def test_no_hyprland_means_no_wait(self):
        with mock.patch("fresh_tube.play.hyprctl", return_value=None) as hyprctl, \
             mock.patch("fresh_tube.play.sleep") as sleep:
            self.assertIsNone(play.find_window(7))
        self.assertEqual(hyprctl.call_count, 1)
        sleep.assert_not_called()

    def test_hyprctl_wrapper_parses_json_and_swallows_failures(self):
        done = mock.Mock(returncode=0, stdout=json.dumps(MONITORS), stderr="")
        with mock.patch("fresh_tube.play.subprocess.run", return_value=done) as run:
            self.assertEqual(play.hyprctl("monitors"), MONITORS)
        self.assertEqual(run.call_args.args[0], ["hyprctl", "monitors", "-j"])
        with mock.patch("fresh_tube.play.subprocess.run", side_effect=FileNotFoundError):
            self.assertIsNone(play.hyprctl("monitors"))
        with mock.patch("fresh_tube.play.subprocess.run", return_value=mock.Mock(returncode=1, stdout="")):
            self.assertIsNone(play.hyprctl("monitors"))
        with mock.patch("fresh_tube.play.subprocess.run", return_value=mock.Mock(returncode=0, stdout="nope")):
            self.assertIsNone(play.hyprctl("monitors"))


class PlayCommand(unittest.TestCase):
    def setUp(self):
        self.box = support.Sandbox()
        self.box.apply()
        self.addCleanup(self.box.cleanup)
        self.spawned = []

        def fake_popen(argv, **kw):
            self.spawned.append((argv, kw))
            return mock.Mock(pid=4242)
        self.addCleanup(mock.patch.stopall)
        mock.patch("fresh_tube.play.popen", side_effect=fake_popen).start()
        mock.patch("fresh_tube.play.hyprctl", side_effect=lambda what: {"monitors": MONITORS}.get(what)).start()

    def run_play(self, *args):
        with support.captured() as (out, err):
            code = cli.main(["play", *args])
        return code, out.getvalue(), err.getvalue()

    def test_launches_mpv_with_the_default_size_then_the_placer_and_marks_seen(self):
        code, out, err = self.run_play("--player", "mpv", "--", VID)
        self.assertEqual(code, 0, err)
        self.assertEqual(json.loads(out), {"played": VID})
        player, placer = self.spawned
        self.assertIn("--geometry=480x270", player[0])
        self.assertEqual(player[0][-1], URL)
        self.assertTrue(player[1]["start_new_session"])
        self.assertEqual(placer[0], [play.BIN_PATH, "place-window", "4242"])
        self.assertIn(VID, self.box.read_json(self.box.state_file)["seen"])

    def test_uses_the_remembered_size(self):
        state = store.load_state()
        store.set_prefs(state, [("playerWidth", "1000"), ("playerHeight", "560")])
        store.save_state(state)
        self.run_play("--", VID)
        self.assertIn("--geometry=1000x560", self.spawned[0][0])

    def test_default_player_is_mpv(self):
        self.run_play("--", VID)
        self.assertEqual(self.spawned[0][0][0], "mpv")

    def test_launch_failure_marks_nothing(self):
        mock.patch("fresh_tube.play.popen", side_effect=FileNotFoundError(2, "No such file or directory")).start()
        code, out, err = self.run_play("--player", "mpv", "--", VID)
        self.assertEqual(code, 1)
        self.assertIn("Could not start mpv", err)
        self.assertNotIn(VID, store.load_state()["seen"])

    def test_a_placer_that_cannot_start_does_not_fail_the_play(self):
        calls = {"n": 0}

        def flaky_popen(argv, **kw):
            calls["n"] += 1
            if calls["n"] == 2:
                raise OSError("no fork for you")
            return mock.Mock(pid=4242)
        mock.patch("fresh_tube.play.popen", side_effect=flaky_popen).start()
        code, out, err = self.run_play("--", VID)
        self.assertEqual(code, 0, err)

    def test_rejects_a_bad_id(self):
        code, out, err = self.run_play("--", "not-an-id")
        self.assertEqual(code, 2)
        self.assertIn("That doesn't look like a YouTube video", err)
        self.assertEqual(self.spawned, [])


class PlaceWindowCommand(unittest.TestCase):
    def test_places_the_window_of_the_given_pid(self):
        with mock.patch("fresh_tube.play.find_window", return_value=client(7)) as find, \
             mock.patch("fresh_tube.play.place_window") as place, support.captured() as (out, err):
            self.assertEqual(cli.main(["place-window", "7"]), 0)
        find.assert_called_once_with(7)
        place.assert_called_once_with(client(7))
        with mock.patch("fresh_tube.play.find_window", return_value=None), \
             mock.patch("fresh_tube.play.place_window") as place, support.captured():
            self.assertEqual(cli.main(["place-window", "7"]), 0)
        place.assert_not_called()
        with support.captured() as (out, err):
            self.assertEqual(cli.main(["place-window", "x"]), 2)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_play.py' 2>&1 | tail -4`
Expected: `ModuleNotFoundError: No module named 'fresh_tube.play'`.

- [ ] **Step 3: Write `lib/fresh_tube/play.py`**

```python
"""Launch the player for one video and, under Hyprland, put its window below the bar."""
import json
import os
import shlex
import subprocess
import time

from .errors import GENERAL, FreshTubeError
from .videos import WATCH_URL

DEFAULT_SIZE = (860, 484)
WINDOW_WAIT_SECONDS = 10
WINDOW_POLL_SECONDS = 0.1
HYPRCTL_TIMEOUT = 5
PLUGIN_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPT_PATH = os.path.join(PLUGIN_DIR, "mpv", "fresh-tube.lua")
BIN_PATH = os.path.join(PLUGIN_DIR, "bin", "fresh-tube")

# Module-level so tests can replace them.
popen = subprocess.Popen
sleep = time.sleep
monotonic = time.monotonic


def player_argv(player_command):
    return shlex.split(player_command or "") or ["mpv"]


def is_mpv(argv):
    return os.path.basename(argv[0]) == "mpv"


def build_argv(player_command, video_id, size):
    """The full command line: mpv gets the companion script, the size and resume; others only the URL."""
    argv = player_argv(player_command)
    if is_mpv(argv):
        argv += ["--save-position-on-quit", "--force-window=immediate",
                 f"--geometry={size[0]}x{size[1]}", f"--script={SCRIPT_PATH}",
                 f"--script-opts=fresh_tube-id={video_id},fresh_tube-bin={BIN_PATH}"]
    return argv + [WATCH_URL.format(video_id)]


def default_size(monitors):
    """A quarter of the focused monitor's logical width, 16:9; DEFAULT_SIZE when that cannot be known."""
    if not monitors:
        return DEFAULT_SIZE
    focused = next((m for m in monitors if isinstance(m, dict) and m.get("focused")), None)
    monitor = focused or (monitors[0] if isinstance(monitors[0], dict) else None)
    if not monitor:
        return DEFAULT_SIZE
    try:
        scale = float(monitor.get("scale") or 1) or 1.0
        width = int(round(int(monitor.get("width")) / scale / 4))
    except (TypeError, ValueError):
        return DEFAULT_SIZE
    if width <= 0:
        return DEFAULT_SIZE
    return width, int(round(width * 9 / 16))


def launch(argv):
    """Start the player in its own session, or say why it could not start."""
    try:
        return popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True)
    except OSError as e:
        reason = e.strerror or str(e)
        raise FreshTubeError(f"Could not start {os.path.basename(argv[0])}: {reason}", GENERAL)


def start(player_command, video_id, size):
    """Launch the player, then a detached helper that places its window; returns the player's pid."""
    process = launch(build_argv(player_command, video_id, size))
    try:
        popen([BIN_PATH, "place-window", str(process.pid)], stdin=subprocess.DEVNULL,
              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        pass  # the video plays anyway, just not placed
    return process.pid


# --- Hyprland ------------------------------------------------------------------

def hyprctl(what):
    """Parsed `hyprctl <what> -j`, or None when hyprctl is missing, fails or prints no JSON."""
    try:
        done = subprocess.run(["hyprctl", what, "-j"], capture_output=True, text=True, timeout=HYPRCTL_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if done.returncode != 0:
        return None
    try:
        return json.loads(done.stdout)
    except ValueError:
        return None


def dispatch(*args):
    try:
        subprocess.run(["hyprctl", "dispatch", *args], capture_output=True, text=True, timeout=HYPRCTL_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired):
        pass


def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def find_window(pid):
    """The hyprctl client of `pid`, waiting up to WINDOW_WAIT_SECONDS; None without Hyprland or a window."""
    deadline = monotonic() + WINDOW_WAIT_SECONDS
    while True:
        clients = hyprctl("clients")
        if clients is None:
            return None
        for client in clients:
            if isinstance(client, dict) and client.get("pid") == pid:
                return client
        if not pid_alive(pid) or monotonic() >= deadline:
            return None
        sleep(WINDOW_POLL_SECONDS)


def place_window(client):
    """Float the window if needed and move it to the top-left of its monitor's usable area."""
    monitors = hyprctl("monitors") or []
    monitor = next((m for m in monitors if isinstance(m, dict) and m.get("id") == client.get("monitor")), None)
    if monitor is None:
        return
    reserved = monitor.get("reserved") or [0, 0, 0, 0]
    try:
        x = int(monitor.get("x", 0)) + int(reserved[0])
        y = int(monitor.get("y", 0)) + int(reserved[1])
    except (TypeError, ValueError, IndexError):
        return
    target = f"address:{client.get('address')}"
    if not client.get("floating"):
        dispatch("setfloating", target)
    dispatch("movewindowpixel", f"exact {x} {y},{target}")
```

- [ ] **Step 4: Add the commands to `lib/fresh_tube/cli.py`**

Change the import line to `from . import feed, play, resolve, store, videos, ytdlp`.

Add after `cmd_done`:

```python
def cmd_play(args):
    """Launch the player for a video; seen only once the player is running."""
    if not videos.VIDEO_ID_RE.match(args.video_id or ""):
        raise FreshTubeError("That doesn't look like a YouTube video id", USAGE)
    state = store.load_state()
    prefs = state["prefs"]
    if "playerWidth" in prefs and "playerHeight" in prefs:
        size = (prefs["playerWidth"], prefs["playerHeight"])
    else:
        size = play.default_size(play.hyprctl("monitors"))
    play.start(args.player, args.video_id, size)
    store.mark_seen(state, args.video_id)
    store.save_state(state)
    emit({"played": args.video_id})
    return 0


def cmd_place_window(args):
    """Hidden helper spawned by `play`: wait for the player's window and put it below the bar."""
    window = play.find_window(args.pid)
    if window is not None:
        play.place_window(window)
    return 0
```

In `build_parser`, before `return parser, sub`:

```python
    p = sub.add_parser("play", help="play a video in the configured player and mark it seen")
    p.add_argument("--player", default="mpv", help="player command line (default: mpv)")
    p.add_argument("video_id")
    p.set_defaults(func=cmd_play)

    p = sub.add_parser("place-window", help=argparse.SUPPRESS)
    p.add_argument("pid", type=int)
    p.set_defaults(func=cmd_place_window)
```

Note: `"That doesn't look like a YouTube video id"` contains the spec's `That doesn't look like a YouTube video` prefix, which the test checks with `assertIn`.

- [ ] **Step 5: Run the whole suite**

Run: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests 2>&1 | tail -3`
Expected: `OK`, no warnings.

- [ ] **Step 6: Commit**

```bash
git add lib/fresh_tube/play.py lib/fresh_tube/cli.py tests/test_play.py
git commit -F - <<'EOF'
Add fresh-tube play: launch the player and place its window

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_011DPqvBbwQCc2wPWRZoVQkC
EOF
```

---

### Task 5: the mpv companion script

**Files:**
- Create: `mpv/fresh-tube.lua`

**Interfaces:**
- Consumes: `--script-opts=fresh_tube-id=<videoId>,fresh_tube-bin=<abs bin/fresh-tube>` (from `play.build_argv`); CLI `done <id>`, `prefs set playerWidth W playerHeight H`.
- Produces: nothing in-process; side effects through the CLI.

- [ ] **Step 1: Write the script**

```lua
-- Fresh Tube's mpv companion. Loaded by `fresh-tube play` with
--   --script-opts=fresh_tube-id=<videoId>,fresh_tube-bin=<path to bin/fresh-tube>
-- It tells the plugin when the video reaches its end (so the video leaves the
-- Watch later list) and remembers the window size when mpv closes.
local mp = require("mp")

local video_id = mp.get_opt("fresh_tube-id")
local bin = mp.get_opt("fresh_tube-bin")
if not video_id or video_id == "" or not bin or bin == "" then
  return
end

local done_sent = false
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

-- Normal end of the file.
mp.register_event("end-file", function(event)
  if event.reason == "eof" then
    mark_done()
  end
end)

-- With keep-open=yes in the user's mpv.conf, mpv pauses at the end instead of
-- unloading the file; eof-reached covers that.
mp.observe_property("eof-reached", "bool", function(_, reached)
  if reached then
    mark_done()
  end
end)

mp.observe_property("osd-dimensions", "native", function(_, dims)
  if dims and dims.w and dims.h and dims.w > 0 and dims.h > 0 then
    last_w, last_h = math.floor(dims.w), math.floor(dims.h)
  end
end)

mp.register_event("shutdown", function()
  if last_w > 0 and last_h > 0 then
    run({ bin, "prefs", "set", "playerWidth", tostring(last_w), "playerHeight", tostring(last_h) })
  end
end)
```

- [ ] **Step 2: Check the syntax without running mpv**

Run: `command -v luac >/dev/null && luac -p mpv/fresh-tube.lua && echo "syntax ok" || echo "no luac; skip"`
Expected: `syntax ok` (or `no luac; skip`). Do not launch mpv.

- [ ] **Step 3: Validate the plugin still passes**

Run: `omarchy plugin validate . ; echo "exit=$?"`
Expected: `exit=0`.

- [ ] **Step 4: Commit**

```bash
git add mpv/fresh-tube.lua
git commit -F - <<'EOF'
Add the mpv companion script

Reports the end of the video and the window size back to fresh-tube.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_011DPqvBbwQCc2wPWRZoVQkC
EOF
```

---

### Task 6: `Panel.qml` — play through the CLI, queue actions, tabs state

**Files:**
- Modify: `Panel.qml`

**Interfaces:**
- Consumes: CLI `play --player <cmd> -- <id>`, `done -- <id>`, `queue add -- <text>`, `queue move -- <id> <index>`, refresh payload `queue`.
- Produces (for Task 7): `tab` ("new" | "later"), `queueVideos`, `addingVideo`, `toggleTab()`, `finish(video)`, `addToQueue(text)`, `moveQueued(video, index)`, `laterView` reference (Task 7 adds the `WatchLaterView` with `id: laterView` inside `VideosView`; until then the panel refers to it through `videosView.laterView`, see Step 2).

- [ ] **Step 1: Properties, payload and functions**

After `property var pinnedVideos: []` add:

```qml
  property string tab: "new"
  property var queueVideos: []
```

After `readonly property bool adding: addCmd.running` add:

```qml
  readonly property bool addingVideo: queueAddCmd.running
```

In `applyPayload`, after the `pinnedVideos` line add:

```qml
    queueVideos = Array.isArray(data.queue) ? data.queue : []
```

Replace the whole `play` function:

```qml
  // Every play goes through the script: it launches the player, places its
  // window and marks the video seen only once the player is running.
  function play(video) {
    if (!video || playCmd.running) return
    if (!playerFound) {
      setNotice(Model.playerName(playerCommand) + " not found. Set playerCommand in shell.json.", true)
      return
    }
    pendingPlay = video
    playCmd.start(["play", "--player", playerCommand, "--", video.videoId])
  }
```

After `dismiss` add:

```qml
  // Finished with a saved video: out of the Watch later list, and seen.
  function finish(video) {
    if (!video || doneCmd.running) return
    doneCmd.start(["done", "--", video.videoId])
  }

  function toggleTab() {
    tab = tab === "new" ? "later" : "new"
  }

  function addToQueue(text) {
    var value = String(text || "").trim()
    if (value === "" || queueAddCmd.running) return
    videosView.laterView.error = ""
    queueAddCmd.start(["queue", "add", "--", value])
  }

  function moveQueued(video, index) {
    if (!video || queueMoveCmd.running) return
    queueMoveCmd.start(["queue", "move", "--", video.videoId, String(Math.max(0, index))])
  }
```

After `onViewChanged: focusCurrent()` add `onTabChanged: focusCurrent()`.

- [ ] **Step 2: Runners**

Replace the `seenCmd` runner's `onFinished` body so it no longer closes the panel (play does that now):

```qml
  FreshTubeCommand {
    id: seenCmd
    program: root.program
    onFinished: function(code, out, err) {
      root.pendingPlay = null
      if (code !== 0) {
        root.setNotice(root.lastLine(err) || "Could not mark it as seen", true)
        return
      }
      if (root.noticeIsError) root.setNotice("", false)
      var data = root.parseJson(out)
      var id = data ? String(data.seen || "") : ""
      if (id !== "") root.removeVideo(id)
    }
  }
```

Add after it:

```qml
  // The player is up once this returns 0; a failed launch leaves every list as it was.
  FreshTubeCommand {
    id: playCmd
    program: root.program
    timeoutMs: 15000
    onFinished: function(code, out, err) {
      var video = root.pendingPlay
      root.pendingPlay = null
      if (code !== 0) {
        root.setNotice(root.lastLine(err) || "Could not start the player", true)
        return
      }
      if (root.noticeIsError) root.setNotice("", false)
      if (video) root.removeVideo(video.videoId)
      root.loadCached()
      if (!root.pinned) root.close()
    }
  }

  FreshTubeCommand {
    id: doneCmd
    program: root.program
    onFinished: function(code, out, err) {
      if (code !== 0) {
        root.setNotice(root.lastLine(err) || "Could not remove that video", true)
        return
      }
      if (root.noticeIsError) root.setNotice("", false)
      root.loadCached()
    }
  }

  // Looking a video up can chain oEmbed and yt-dlp.
  FreshTubeCommand {
    id: queueAddCmd
    program: root.program
    timeoutMs: 60000
    onFinished: function(code, out, err) {
      var later = videosView.laterView
      if (code !== 0) {
        later.error = root.lastLine(err) || "Could not add that video"
        root.focusCurrent()
        return
      }
      later.clearInput()
      root.loadCached()
      root.focusCurrent()
    }
  }

  // The list already shows the dragged order; a failure rereads the saved one.
  FreshTubeCommand {
    id: queueMoveCmd
    program: root.program
    onFinished: function(code, out, err) {
      if (code !== 0) root.setNotice(root.lastLine(err) || "Could not reorder the list", true)
      root.loadCached()
    }
  }
```

- [ ] **Step 3: Keep the file loadable before Task 7**

`videosView.laterView` does not exist until Task 7. Add a temporary alias so the file parses and runs: in `VideosView.qml`, right after `readonly property Item focusItem: keys`, add
`readonly property var laterView: ({ error: "", clearInput: function() {} })`. Task 7 replaces it with the real view.

- [ ] **Step 4: Check the live shell**

Run: `sleep 2; quickshell log -p /usr/share/omarchy/shell -t 60 | grep -v qt.qpa.services | grep -iE 'error|warn|fresh' | tail -8`
Expected: only `Local plugin changed, reloading` lines; no QML errors. Also `omarchy plugin validate .` exit 0, the Python suite still `OK`, `node --test tests/model.test.js` fail 0.

- [ ] **Step 5: Commit**

```bash
git add Panel.qml VideosView.qml
git commit -F - <<'EOF'
Play through the script and wire the queue actions

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_011DPqvBbwQCc2wPWRZoVQkC
EOF
```

---

### Task 7: tabs, `WatchLaterView.qml` and drag reordering

**Files:**
- Create: `WatchLaterView.qml`
- Modify: `VideosView.qml`, `VideoRow.qml`

**Interfaces:**
- Consumes (from Task 6): `host.tab`, `host.queueVideos`, `host.addingVideo`, `host.toggleTab()`, `host.finish(video)`, `host.addToQueue(text)`, `host.moveQueued(video, index)`, `host.play(video)`, `host.close()`, `host.refresh()`.
- Produces: `VideosView.laterView` (the real view), `VideosView.focusItem` per tab, `VideoRow.pinnable`.

- [ ] **Step 1: `VideoRow.qml` — hide the pin on queue rows**

Add `property bool pinnable: true` after `property bool pinsFull: false`, and change
`readonly property bool showPin: pinned || hover.containsMouse || selected` to
`readonly property bool showPin: pinnable && (pinned || hover.containsMouse || selected)`.

After `readonly property bool showDismiss: ...` add the width of the draggable part of the
row (thumbnail plus text, everything left of the buttons):

```qml
  readonly property real bodyWidth: content.x + thumb.width + content.spacing + textColumn.width
```

Queue entries carry `addedAt` instead of `published`, so the caption falls back to it. Change
`Model.relativeTime(row.video.published, row.nowMs)` to
`Model.relativeTime(row.video.published || row.video.addedAt, row.nowMs)`.

- [ ] **Step 2: `WatchLaterView.qml`**

```qml
import QtQuick
import QtQml.Models
import qs.Commons
import qs.Ui
import "FreshTubeModel.js" as Model

// The saved videos in the user's order: a field to paste a link, and rows that
// can be dragged up or down to reorder. Dropping asks the panel to save
// the new order; the panel then rereads the cache.
Item {
  id: view

  property var host: null
  property string error: ""
  property int selected: 0
  property string selectedId: ""
  property real nowMs: Date.now()

  readonly property Item focusItem: input
  readonly property color fg: host ? host.foreground : Color.foreground
  readonly property color dim: host ? host.dim : Qt.darker(Color.foreground, 1.55)
  readonly property color urgent: host ? host.urgent : Color.urgent
  readonly property string family: host ? host.fontFamily : Style.font.family
  readonly property var rows: host ? host.queueVideos : []
  readonly property bool adding: host ? host.addingVideo : false
  readonly property real gap: Style.space(8)

  onRowsChanged: {
    var index = -1
    if (selectedId !== "") {
      for (var i = 0; i < rows.length; i++) {
        if (rows[i].videoId === selectedId) { index = i; break }
      }
    }
    if (index >= 0) selected = index
    else if (selected >= rows.length) selected = Math.max(0, rows.length - 1)
    selectedId = rows[selected] ? rows[selected].videoId : ""
  }
  onVisibleChanged: if (visible) nowMs = Date.now()

  Timer {
    interval: 60000
    running: view.visible
    repeat: true
    onTriggered: view.nowMs = Date.now()
  }

  function clearInput() {
    input.text = ""
    error = ""
  }

  function submit() {
    if (adding) return
    host.addToQueue(input.text)
  }

  function moveSelection(delta) {
    if (rows.length === 0) return
    selected = Math.max(0, Math.min(rows.length - 1, selected + delta))
    selectedId = rows[selected] ? rows[selected].videoId : ""
    list.positionViewAtIndex(selected, ListView.Contain)
  }

  // The field keeps the focus, so list keys only act while it is empty.
  function handleKey(event) {
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    var empty = input.text.trim() === ""
    var current = rows[selected]
    if (ctrl && event.key === Qt.Key_Tab) {
      host.toggleTab()
    } else if (ctrl && event.key === Qt.Key_Down) {
      if (current) host.moveQueued(current, selected + 1)
    } else if (ctrl && event.key === Qt.Key_Up) {
      if (current) host.moveQueued(current, selected - 1)
    } else if (event.key === Qt.Key_Down) {
      moveSelection(1)
    } else if (event.key === Qt.Key_Up) {
      moveSelection(-1)
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      if (!empty) submit()
      else if (current) host.play(current)
    } else if (event.key === Qt.Key_Delete && empty) {
      if (current) host.finish(current)
    } else if (event.key === Qt.Key_Escape) {
      if (!empty) clearInput()
      else host.close()
    } else if (ctrl && event.key === Qt.Key_R) {
      host.refresh()
    } else {
      return
    }
    event.accepted = true
  }

  Column {
    id: upper
    width: parent.width
    spacing: view.gap

    Row {
      width: parent.width
      spacing: Style.space(6)

      TextField {
        id: input
        width: parent.width - addButton.implicitWidth - parent.spacing
        enabled: !view.adding
        placeholderText: view.adding ? "Looking up video…" : "Paste a video link"
        foreground: view.fg
        font.family: view.family
        Keys.onPressed: function(event) { view.handleKey(event) }
      }

      Button {
        id: addButton
        anchors.verticalCenter: parent.verticalCenter
        text: "Add"
        bordered: true
        enabled: !view.adding && input.text.trim() !== ""
        opacity: enabled ? 1 : 0.55
        foreground: view.fg
        fontFamily: view.family
        onClicked: view.submit()
      }
    }

    Text {
      width: parent.width
      visible: text !== ""
      text: view.error
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: view.urgent
      font.family: view.family
      font.pixelSize: Style.font.bodySmall
    }
  }

  ListView {
    id: list
    anchors.top: upper.bottom
    anchors.topMargin: view.gap
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(4)
    width: parent.width
    visible: view.rows.length > 0
    clip: true
    spacing: Style.space(2)
    boundsBehavior: Flickable.StopAtBounds
    model: visualModel
    moveDisplaced: Transition {
      NumberAnimation { properties: "y"; duration: 120 }
    }
  }

  // A DelegateModel so dragging can reorder the visible rows without
  // touching the data: the saved order only changes once the panel says so.
  DelegateModel {
    id: visualModel
    model: view.rows

    delegate: Item {
      id: slot
      required property var modelData
      required property int index
      width: list.width
      height: card.height

      readonly property bool held: grip.drag.active

      VideoRow {
        id: card
        width: slot.width
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        host: view.host
        video: slot.modelData
        selected: slot.index === view.selected
        nowMs: view.nowMs
        pinnable: false
        onActivated: view.host.play(slot.modelData)
        onDismissed: view.host.finish(slot.modelData)

        Drag.active: slot.held
        Drag.source: slot
        Drag.hotSpot.x: width / 2
        Drag.hotSpot.y: height / 2

        // While dragged the row is drawn above its siblings, following the pointer.
        states: State {
          when: slot.held
          ParentChange { target: card; parent: list }
          AnchorChanges {
            target: card
            anchors.horizontalCenter: undefined
            anchors.verticalCenter: undefined
          }
        }
      }

      // Press on the thumbnail or the text and move to drag. A plain click is
      // not accepted here, so it falls through to the row and plays; hover is
      // not enabled here, so the row still highlights. The ✕ column stays
      // uncovered.
      MouseArea {
        id: grip
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: card.bodyWidth
        propagateComposedEvents: true
        cursorShape: slot.held ? Qt.ClosedHandCursor : Qt.PointingHandCursor
        drag.target: card
        drag.axis: Drag.YAxis
        drag.threshold: 6
        onPressed: {
          view.selected = slot.index
          view.selectedId = slot.modelData.videoId
        }
        onClicked: function(mouse) { mouse.accepted = false }
        // Fires once the drop is over, whatever order pressed/released arrive in.
        drag.onActiveChanged: {
          if (drag.active) return
          var target = slot.DelegateModel.itemsIndex
          if (target !== slot.index) view.host.moveQueued(slot.modelData, target)
        }
      }

      DropArea {
        anchors.fill: parent
        anchors.margins: Style.space(6)
        onEntered: function(drag) {
          var from = drag.source.DelegateModel.itemsIndex
          var to = slot.DelegateModel.itemsIndex
          if (from !== to) visualModel.items.move(from, to)
        }
      }
    }
  }

  Text {
    anchors.top: upper.bottom
    anchors.topMargin: view.gap
    width: parent.width
    visible: view.rows.length === 0
    text: "Nothing saved yet. Paste a video link above."
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: view.dim
    font.family: view.family
    font.pixelSize: Style.font.bodySmall
  }
}
```

Note on the drag: `visualModel.items.move` only reorders the visible delegates, so the list already shows the new order while `queue move` runs; the panel's `loadCached` afterwards resets `queueVideos`, which rebuilds the DelegateModel in the saved order (the same order on success, the old one on failure).

- [ ] **Step 3: `VideosView.qml` — tabs and content switch**

Remove the temporary `laterView` alias from Task 6 and add, after `readonly property Item focusItem: keys`:

Replace `readonly property Item focusItem: keys` with:

```qml
  readonly property bool onNew: !host || host.tab === "new"
  readonly property Item focusItem: onNew ? keys : laterView.focusItem
  property alias laterView: laterView
```

In `handleKey`, add as the first branch (before the `Key_Down` check):

```qml
    if (ctrl && event.key === Qt.Key_Tab) {
      host.toggleTab()
    } else if (event.key === Qt.Key_Down) {
```

(the existing `if (event.key === Qt.Key_Down)` becomes that `else if`).

Replace the header `Text { id: heading ... }` block with the tabs:

```qml
      Row {
        id: heading
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Button {
          text: view.host && view.host.videos.length > 0 ? "New (" + view.host.videos.length + ")" : "New"
          selected: view.onNew
          tooltipText: "New videos from your channels (Ctrl+Tab)"
          foreground: view.fg
          fontFamily: view.family
          onClicked: if (view.host) view.host.tab = "new"
        }

        Button {
          text: view.host && view.host.queueVideos.length > 0 ? "Watch later (" + view.host.queueVideos.length + ")" : "Watch later"
          selected: !view.onNew
          tooltipText: "Videos you saved (Ctrl+Tab)"
          foreground: view.fg
          fontFamily: view.family
          onClicked: if (view.host) view.host.tab = "later"
        }
      }
```

Change the `ListView` (`id: list`) `visible` to `visible: view.onNew && view.rows.length > 0`, and the `Column { id: empty ... }` `visible` to `visible: view.onNew && view.rows.length === 0`.

Add, after the `ListView { id: list ... }` block:

```qml
  WatchLaterView {
    id: laterView
    anchors.top: upper.bottom
    anchors.topMargin: view.gap
    anchors.bottom: parent.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    visible: !view.onNew
    host: view.host
  }
```

- [ ] **Step 4: Check the live shell**

Run: `sleep 2; quickshell log -p /usr/share/omarchy/shell -t 80 | grep -v qt.qpa.services | grep -iE 'error|warn|unable|undefined|fresh' | tail -10`
Expected: only reload lines. Fix any QML error the log names before moving on. Also `omarchy plugin validate .` exit 0.

- [ ] **Step 5: Commit**

```bash
git add WatchLaterView.qml VideosView.qml VideoRow.qml
git commit -F - <<'EOF'
Add the Watch later tab with drag reordering

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_011DPqvBbwQCc2wPWRZoVQkC
EOF
```

---

### Task 8: README, manifest 1.2.0, final checks

**Files:**
- Modify: `README.md`, `manifest.json`

- [ ] **Step 1: README**

In the "Use" section, after the bullet about the row pin (`- 󰐃 on a row pins that video ...`), add:

```markdown
- The `Watch later` tab is your own list: paste a video link (watch, youtu.be,
  shorts, embed or live) and it lands at the bottom with its title, channel
  and thumbnail. Drag a row up or down to reorder (press on its thumbnail or title
  and move), or press `Ctrl+↑` / `Ctrl+↓`. A video leaves the list when mpv reaches its end; close mpv early
  and it stays, resuming where you left off next time. `✕` or `Delete` marks
  it seen and removes it. `Ctrl+Tab` switches tabs.
- Playing opens mpv as a small floating window below the bar, left-aligned, a
  quarter of the screen wide. Move or resize it as you like: the size is
  remembered for next time, the position resets. This needs Hyprland
  (`hyprctl`); elsewhere mpv opens wherever it likes.
```

In the "Settings" section, after the table, add:

```markdown
With a player other than `mpv`, videos still play but the end of a video is
not detected and the window size is not remembered.
```

In the "Files" section, extend the `state.json` bullet to end with `..., pinned videos, the Watch later list, popup and player sizes.`

In the "Development" section, extend the CLI list line to:
`` `add`, `remove`, `channels`, `refresh [--cached]`, `seen`, `pin`, `unpin`, `queue add|move`, `done`, `play`, `prefs get|set`. `channels`, `refresh` and `queue` take `--json` for machine output. ``
and add after it: `` `mpv/fresh-tube.lua` is the mpv script `play` loads; it calls `done` and `prefs set` back. ``

- [ ] **Step 2: Manifest**

Change `"version": "1.1.0"` to `"version": "1.2.0"`.

- [ ] **Step 3: Everything green**

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v 2>&1 | tail -3   # OK, no warnings
node --test tests/model.test.js 2>&1 | grep -E '^ℹ (pass|fail)'                   # fail 0
omarchy plugin validate . ; echo "exit=$?"                                        # 0
git status --short                                                                 # clean after commit
find . -name __pycache__ -not -path './.git/*'                                     # nothing
```

- [ ] **Step 4: Commit**

```bash
git add README.md manifest.json
git commit -F - <<'EOF'
Document Watch later and the player window; release 1.2.0

Manual checklist (spec items 1-10) is left to the user: it needs a person
at the screen and a playing video.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_011DPqvBbwQCc2wPWRZoVQkC
EOF
```

- [ ] **Step 5: Manual checklist (for the user, not the implementer)**

The spec's ten-item checklist under "QML, checklist manual sobre la barra real".
