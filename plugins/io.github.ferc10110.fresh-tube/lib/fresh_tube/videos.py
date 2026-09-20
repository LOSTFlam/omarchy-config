"""One video: its id from whatever the user pasted, and its title, channel and thumbnail."""
import json
import re
import subprocess
import urllib.parse

from .errors import NETWORK, FreshTubeError
from .feed import fetch_url
from .limits import OEMBED_MAX_BYTES, YTDLP_MAX_BYTES, run_capped
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
    return parse_oembed(fetch(url, OEMBED_TIMEOUT, OEMBED_MAX_BYTES))


def _field(value):
    value = value.strip()
    return "" if value == "NA" else value


def fetch_via_ytdlp(video_id, timeout=YTDLP_TIMEOUT):
    args = ["yt-dlp", "--no-download", "--print", "%(title)s\t%(channel)s", WATCH_URL.format(video_id)]
    try:
        done = run_capped(args, timeout=timeout, max_bytes=YTDLP_MAX_BYTES)
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
