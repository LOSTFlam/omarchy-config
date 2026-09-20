"""Fallback source: a channel's newest uploads through yt-dlp, for when the RSS feed is down."""
import re
import subprocess

from .errors import NETWORK, FreshTubeError
from .limits import YTDLP_MAX_BYTES, run_capped

VIDEOS_URL = "https://www.youtube.com/channel/{}/videos"
THUMBNAIL_URL = "https://i.ytimg.com/vi/{}/hqdefault.jpg"
MAX_ENTRIES = 15
YTDLP_TIMEOUT = 40
NAME_MARK = "#name"
# "[youtube:tab] UC...: message" -> "message"
ERROR_PREFIX_RE = re.compile(r"^\[[^\]]*\]\s*(?:[^\s:]+:\s*)?")


def ytdlp_args(channel_id):
    # Flat listing of the videos tab: one line per upload (newest first) and,
    # once the listing is done, one marked line with the channel's name.
    return ["yt-dlp", "--flat-playlist", "-I", f"1:{MAX_ENTRIES}",
            "--extractor-args", "youtubetab:approximate_date",
            "--print", f"playlist:{NAME_MARK}\t%(channel)s",
            "--print", "%(id)s\t%(title)s\t%(upload_date)s",
            VIDEOS_URL.format(channel_id)]


def _published(upload_date):
    """An ISO timestamp from yt-dlp's YYYYMMDD (a day, not a time), or "" when it has none."""
    day = (upload_date or "").strip()
    if len(day) == 8 and day.isdigit():
        return f"{day[:4]}-{day[4:6]}-{day[6:]}T00:00:00+00:00"
    return ""


def _field(value):
    value = value.strip()
    return "" if value == "NA" else value


def parse_output(stdout):
    """{"name", "latest", "recent"}: the same shape feed.parse_feed returns. yt-dlp lists newest first."""
    name = ""
    entries = []
    for line in stdout.splitlines():
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        if parts[0] == NAME_MARK:
            name = _field(parts[1])
            continue
        if len(parts) < 3:
            continue
        video_id = _field(parts[0])
        if not video_id:
            continue
        entries.append({"videoId": video_id, "title": _field(parts[1]),
                        "published": _published(parts[2]), "thumbnail": THUMBNAIL_URL.format(video_id)})
    return {"name": name, "latest": entries[0] if entries else None, "recent": [e["videoId"] for e in entries]}


def last_error(stderr):
    for line in reversed((stderr or "").splitlines()):
        if line.startswith("ERROR:"):
            return ERROR_PREFIX_RE.sub("", line[len("ERROR:"):].strip())
    return ""


def fetch_via_ytdlp(channel_id, timeout=YTDLP_TIMEOUT):
    """The channel's newest uploads, or a network error saying why yt-dlp could not tell."""
    try:
        done = run_capped(ytdlp_args(channel_id), timeout=timeout, max_bytes=YTDLP_MAX_BYTES)
    except FileNotFoundError:
        raise FreshTubeError("not installed", NETWORK)
    except subprocess.TimeoutExpired:
        raise FreshTubeError("timed out", NETWORK)
    except OSError as e:
        raise FreshTubeError(str(e), NETWORK)
    if done.returncode != 0:
        raise FreshTubeError(last_error(done.stderr) or f"exit code {done.returncode}", NETWORK)
    return parse_output(done.stdout)
