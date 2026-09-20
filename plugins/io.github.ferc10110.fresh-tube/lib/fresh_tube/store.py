"""channels.json and state.json: where Fresh Tube keeps what it knows."""
import contextlib
import datetime
import fcntl
import json
import os
import tempfile

from .errors import DUPLICATE, GENERAL, PIN_LIMIT, UNKNOWN, USAGE, FreshTubeError

APP = "fresh-tube"
CHANNELS_VERSION = 1
STATE_VERSION = 1
CHANNEL_URL = "https://www.youtube.com/channel/{}"


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")


def _xdg(var, fallback_parts):
    base = os.environ.get(var, "")
    if not base:
        base = os.path.join(os.path.expanduser("~"), *fallback_parts)
    return os.path.join(base, APP)


def config_dir():
    return _xdg("XDG_CONFIG_HOME", [".config"])


def state_dir():
    return _xdg("XDG_STATE_HOME", [".local", "state"])


def channels_path():
    return os.path.join(config_dir(), "channels.json")


def state_path():
    return os.path.join(state_dir(), "state.json")


def read_json(path, empty):
    """The parsed file, `empty` when it does not exist. A file that is not JSON is an error."""
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        return empty
    except (OSError, ValueError) as e:
        raise FreshTubeError(f"Could not read {os.path.basename(path)}: {e}", GENERAL)
    if not isinstance(data, dict):
        raise FreshTubeError(f"Could not read {os.path.basename(path)}: not an object", GENERAL)
    return data


def write_json(path, data):
    """Write through a temp file in the same directory so a crash never leaves half a file."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write("\n")
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


# --- channels ---------------------------------------------------------------

def load_channels():
    data = read_json(channels_path(), {"version": CHANNELS_VERSION, "channels": []})
    channels = data.get("channels")
    if not isinstance(channels, list):
        return []
    return [c for c in channels if isinstance(c, dict) and c.get("id")]


def save_channels(channels):
    write_json(channels_path(), {"version": CHANNELS_VERSION, "channels": channels})


def find_channel(channels, channel_id):
    for c in channels:
        if c.get("id") == channel_id:
            return c
    return None


def add_channel(channels, channel_id, name, name_pending=False):
    if find_channel(channels, channel_id):
        raise FreshTubeError("Already added", DUPLICATE)
    channel = {"id": channel_id, "name": name, "url": CHANNEL_URL.format(channel_id), "addedAt": now_iso()}
    if name_pending:
        # A placeholder until some source tells us the real name (see fill_pending_names).
        channel["namePending"] = True
    channels.append(channel)
    return channel


def fill_pending_names(channels, names):
    """Replace placeholder names with the ones in `names` ({channel_id: name}); True when anything changed."""
    changed = False
    for channel in channels:
        name = names.get(channel.get("id"), "")
        if channel.get("namePending") and name:
            channel["name"] = name
            del channel["namePending"]
            changed = True
    return changed


def remove_channel(channels, channel_id):
    if not find_channel(channels, channel_id):
        raise FreshTubeError("No such channel", UNKNOWN)
    channels[:] = [c for c in channels if c.get("id") != channel_id]
    return channels


# --- state -------------------------------------------------------------------

DEFAULT_PREFS = {"width": 420, "height": 520, "pinned": False}
PREF_LIMITS = {"width": (300, 4000), "height": (220, 4000),
               "playerWidth": (200, 8000), "playerHeight": (200, 8000),
               "browserWidth": (200, 8000), "browserHeight": (200, 8000)}
MAX_PINS = 3
WATCH_URL = "https://www.youtube.com/watch?v={}"


def empty_state():
    return {"version": STATE_VERSION, "seen": [], "feeds": {}, "fetchedAt": "",
            "prefs": dict(DEFAULT_PREFS), "pins": [], "queue": []}


def _valid_pref(key, value):
    """Check if a saved pref value is valid; return True to keep it, False to use the default."""
    if key in PREF_LIMITS:
        # width and height: must be int (not bool, which is a subclass of int) within limits.
        if isinstance(value, bool) or not isinstance(value, int):
            return False
        low, high = PREF_LIMITS[key]
        return low <= value <= high
    elif key == "pinned":
        # pinned: must be a real bool.
        return isinstance(value, bool)
    return False


def _valid_pin(entry):
    """A saved pin is usable when it is an object with a non-empty videoId."""
    return isinstance(entry, dict) and isinstance(entry.get("videoId"), str) and entry["videoId"] != ""


def _valid_queue_entry(entry):
    return isinstance(entry, dict) and isinstance(entry.get("videoId"), str) and entry["videoId"] != ""


def load_state():
    data = read_json(state_path(), None)
    state = empty_state()
    if data is None:
        return state
    if isinstance(data.get("seen"), list):
        state["seen"] = [str(s) for s in data["seen"]]
    if isinstance(data.get("feeds"), dict):
        state["feeds"] = data["feeds"]
    if isinstance(data.get("fetchedAt"), str):
        state["fetchedAt"] = data["fetchedAt"]
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


def save_state(state):
    write_json(state_path(), state)


@contextlib.contextmanager
def state_transaction():
    """Load the state, hand it out, save it — under a lock, so two commands cannot lose each other's write."""
    path = os.path.join(state_dir(), "state.lock")
    os.makedirs(state_dir(), exist_ok=True)
    with open(path, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = load_state()
        yield state
        save_state(state)


def set_pref(state, key, value):
    if key in PREF_LIMITS:
        low, high = PREF_LIMITS[key]
        try:
            number = int(str(value).strip())
        except ValueError:
            raise FreshTubeError(f"{key} must be a whole number", USAGE)
        if not low <= number <= high:
            raise FreshTubeError(f"{key} must be between {low} and {high}", USAGE)
        state["prefs"][key] = number
    elif key == "pinned":
        text = str(value).strip().lower()
        if text not in ("true", "false"):
            raise FreshTubeError("pinned must be true or false", USAGE)
        state["prefs"]["pinned"] = text == "true"
    else:
        raise FreshTubeError(f"Unknown preference: {key}", USAGE)
    return state["prefs"]


def set_prefs(state, pairs):
    """Apply several (key, value) pairs; nothing changes unless every pair is valid."""
    trial = {"prefs": dict(state["prefs"])}
    for key, value in pairs:
        set_pref(trial, key, value)
    state["prefs"] = trial["prefs"]
    return state["prefs"]


def mark_seen(state, video_id):
    if video_id not in state["seen"]:
        state["seen"].append(video_id)


def prune_seen(state):
    """Forget seen ids that no cached feed lists any more, unless they are pinned."""
    keep = set()
    for feed in state["feeds"].values():
        keep.update(feed.get("recent") or [])
    keep.update(pinned_ids(state))
    state["seen"] = [s for s in state["seen"] if s in keep]


def update_feed(state, channel_id, parsed, fetched_at, source="feed"):
    state["feeds"][channel_id] = {"fetchedAt": fetched_at, "lastError": "", "source": source,
                                  "latest": parsed.get("latest"), "recent": list(parsed.get("recent") or [])}


def set_feed_error(state, channel_id, message):
    """Remember why a channel failed while keeping whatever it had cached."""
    feed = state["feeds"].setdefault(channel_id, {"fetchedAt": "", "lastError": "", "latest": None, "recent": []})
    feed["lastError"] = message


def drop_feed(state, channel_id):
    state["feeds"].pop(channel_id, None)


def video_record(channel, latest):
    """The public shape of a video, shared by the new-video list and the pins."""
    return {"videoId": latest["videoId"], "title": latest.get("title", ""),
            "channelId": channel["id"], "channel": channel.get("name", ""),
            "published": latest.get("published", ""), "thumbnail": latest.get("thumbnail", ""),
            "url": WATCH_URL.format(latest["videoId"])}


def unseen_videos(state, channels):
    """The newest video of every channel whose newest video was not seen or pinned, newest first."""
    skip = set(state["seen"]) | pinned_ids(state)
    videos = []
    for channel in channels:
        feed = state["feeds"].get(channel["id"]) or {}
        latest = feed.get("latest")
        if not latest or latest.get("videoId") in skip:
            continue
        videos.append(video_record(channel, latest))
    videos.sort(key=lambda v: v["published"], reverse=True)
    return videos


def find_latest(state, channels, video_id):
    """The full record of a video that is currently some channel's newest, or None."""
    for channel in channels:
        latest = (state["feeds"].get(channel["id"]) or {}).get("latest")
        if latest and latest.get("videoId") == video_id:
            return video_record(channel, latest)
    return None


def pinned_ids(state):
    return {p["videoId"] for p in state.get("pins", [])}


def pinned_videos(state):
    return [dict(p) for p in state.get("pins", [])]


def pin_video(state, video):
    """Keep a video around regardless of seen/newest; at most MAX_PINS, re-pinning is a no-op."""
    pins = state.setdefault("pins", [])
    if any(p["videoId"] == video["videoId"] for p in pins):
        return pins
    if len(pins) >= MAX_PINS:
        raise FreshTubeError(f"Pin limit reached ({MAX_PINS})", PIN_LIMIT)
    pins.append(dict(video))
    return pins


def unpin_video(state, video_id):
    pins = state.setdefault("pins", [])
    kept = [p for p in pins if p["videoId"] != video_id]
    if len(kept) == len(pins):
        raise FreshTubeError("That video is not pinned", UNKNOWN)
    state["pins"] = kept
    return kept


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
