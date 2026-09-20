"""One channel's RSS feed: download it and pick the newest video."""
import http.client
import socket
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

from .errors import NETWORK, FreshTubeError
from .limits import FEED_MAX_BYTES, read_capped

FEED_URL = "https://www.youtube.com/feeds/videos.xml?channel_id={}"
USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36"
NS = {"atom": "http://www.w3.org/2005/Atom",
      "yt": "http://www.youtube.com/xml/schemas/2015",
      "media": "http://search.yahoo.com/mrss/"}

urlopen = urllib.request.urlopen  # module-level so tests can replace it


def feed_url(channel_id):
    return FEED_URL.format(channel_id)


def fetch_url(url, timeout, max_bytes):
    """The body at `url`, or a network error saying why; a body over max_bytes is an error (see limits)."""
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept-Language": "en"})
    try:
        with urlopen(request, timeout=timeout) as response:
            return read_capped(response, max_bytes, f"Answer from {url}")
    except urllib.error.HTTPError as e:
        e.close()  # the error carries the response body; drop it now, not at garbage collection
        raise FreshTubeError(f"HTTP {e.code} from {url}", NETWORK)
    except (urllib.error.URLError, socket.timeout, TimeoutError, OSError, http.client.HTTPException) as e:
        reason = getattr(e, "reason", e)
        raise FreshTubeError(f"Could not reach {url}: {reason}", NETWORK)


def _text(element, path):
    found = element.find(path, NS)
    return (found.text or "").strip() if found is not None else ""


def parse_feed(data):
    """{"name", "latest", "recent"} from the Atom document; latest is the newest by date, not by position."""
    try:
        root = ET.fromstring(data)
    except ET.ParseError as e:
        raise FreshTubeError(f"Feed is not valid XML: {e}", NETWORK)
    entries = []
    for entry in root.findall("atom:entry", NS):
        video_id = _text(entry, "yt:videoId")
        if not video_id:
            continue
        thumbnail = entry.find("media:group/media:thumbnail", NS)
        entries.append({"videoId": video_id, "title": _text(entry, "atom:title"),
                        "published": _text(entry, "atom:published"),
                        "thumbnail": thumbnail.get("url", "") if thumbnail is not None else ""})
    latest = max(entries, key=lambda e: e["published"]) if entries else None
    return {"name": _text(root, "atom:title"), "latest": latest, "recent": [e["videoId"] for e in entries]}


def fetch_feed(channel_id, timeout=10):
    return parse_feed(fetch_url(feed_url(channel_id), timeout, FEED_MAX_BYTES))
