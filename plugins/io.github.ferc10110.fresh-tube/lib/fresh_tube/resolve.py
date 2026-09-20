"""Turn whatever the user pasted into a YouTube channel id."""
import re
import subprocess

from .errors import NETWORK, USAGE, FreshTubeError
from .feed import fetch_url
from .limits import PAGE_MAX_BYTES, YTDLP_MAX_BYTES, run_capped

CHANNEL_ID = r"UC[0-9A-Za-z_-]{22}"
CHANNEL_ID_RE = re.compile(r"^" + CHANNEL_ID + r"$")
CHANNEL_PATH_RE = re.compile(r"youtube\.com/channel/(" + CHANNEL_ID + r")(?:[/?#]|$)")
# The channel page lists other channels' ids in its JSON before its own, so
# only the canonical link and the itemprop metas are trusted.
CANONICAL_RE = re.compile(r'<link\s+rel="canonical"\s+href="https://www\.youtube\.com/channel/(' + CHANNEL_ID + r')"')
ITEMPROP_RE = re.compile(r'<meta\s+itemprop="(?:identifier|channelId)"\s+content="(' + CHANNEL_ID + r')"')
HANDLE_RE = re.compile(r"^@[A-Za-z0-9._-]+$")
HANDLE_IN_TEXT_RE = re.compile(r"@[A-Za-z0-9._-]+")
YOUTUBE_HOST_RE = re.compile(r"^(https?://)?(www\.|m\.)?(youtube\.com|youtu\.be)(/|$)", re.IGNORECASE)
PAGE_TIMEOUT = 20
YTDLP_TIMEOUT = 20


def looks_like_youtube(text):
    text = (text or "").strip()
    if not text or re.search(r"\s", text):
        return False
    return bool(CHANNEL_ID_RE.match(text) or HANDLE_RE.match(text) or YOUTUBE_HOST_RE.match(text))


def normalize_input(text):
    text = (text or "").strip()
    if CHANNEL_ID_RE.match(text):
        return "https://www.youtube.com/channel/" + text
    if HANDLE_RE.match(text):
        return "https://www.youtube.com/" + text
    if not re.match(r"^https?://", text, re.IGNORECASE):
        return "https://" + text
    return text


def handle_of(text):
    """The @handle inside whatever the user pasted, or ""."""
    found = HANDLE_IN_TEXT_RE.search(text or "")
    return found.group(0) if found else ""


def direct_channel_id(url):
    found = CHANNEL_PATH_RE.search(url)
    return found.group(1) if found else None


def channel_id_from_html(html):
    for pattern in (CANONICAL_RE, ITEMPROP_RE):
        found = pattern.search(html)
        if found:
            return found.group(1)
    return None


def ytdlp_channel_id(url):
    """yt-dlp's answer for the channel behind `url`, or None when it is missing or cannot tell."""
    try:
        done = run_capped(["yt-dlp", "--flat-playlist", "-I", "0", "--print", "playlist:channel_id", url],
                          timeout=YTDLP_TIMEOUT, max_bytes=YTDLP_MAX_BYTES)
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError, FreshTubeError):
        return None
    if done.returncode != 0:
        return None
    for line in done.stdout.splitlines():
        if CHANNEL_ID_RE.match(line.strip()):
            return line.strip()
    return None


def resolve_channel_id(text, fetch=None, ytdlp=None):
    # Looked up at call time, not bound as defaults, so tests can patch the module.
    fetch = fetch or fetch_url
    ytdlp = ytdlp or ytdlp_channel_id
    if not looks_like_youtube(text):
        raise FreshTubeError("That doesn't look like a YouTube channel", USAGE)
    url = normalize_input(text)
    direct = direct_channel_id(url)
    if direct:
        return direct
    try:
        html = fetch(url, PAGE_TIMEOUT, PAGE_MAX_BYTES).decode("utf-8", "replace")
    except FreshTubeError:
        html = ""
    found = channel_id_from_html(html) if html else None
    if not found:
        found = ytdlp(url)
    if not found:
        raise FreshTubeError("Couldn't find that channel", NETWORK)
    return found
