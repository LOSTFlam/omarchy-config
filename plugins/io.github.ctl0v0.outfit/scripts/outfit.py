#!/usr/bin/env python3
"""Bounded local profiling and marketplace matching for Outfit."""

from __future__ import annotations

from bisect import bisect_left
from contextlib import contextmanager
from datetime import datetime, timezone
import concurrent.futures
import errno
import fcntl
import functools
import gzip
import hashlib
import html
import importlib.util
import io
import json
import math
import os
from pathlib import Path
import re
import selectors
import signal
import socket
import sqlite3
import stat
import subprocess
import sys
import tempfile
import threading
import time
import types
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zlib
from typing import Any, Iterable


APP_ID = "io.github.ctl0v0.outfit"
LEGACY_APP_ID = "io.github.ctl0v0.omafit"  # Protected until explicit identity migration.
SERVICE_REGISTRY_PATH = Path(__file__).resolve().parents[1] / "data" / "services.json"
DISCOVERY_REGISTRY_PATH = Path(__file__).resolve().parents[1] / "data" / "discovery.json"
BOOTSTRAP_CATALOG_PATH = Path(__file__).resolve().parents[1] / "data" / "bootstrap-catalog.json"
SEARCH_PACK_URL = "https://github.com/ctl0v0/outfit/releases/download/search-pack/latest.json"
MAX_PACK_BYTES = 64 * 1024 * 1024
MAX_PACK_EXPANDED = 256 * 1024 * 1024
MAX_PACK_RECORD_BYTES = 1024 * 1024
MAX_PACK_LEGAL_BYTES = 128 * 1024
MAX_PACK_COMBINED_LEGAL_BYTES = 512 * 1024
SEARCH_PACK_INTERVAL = 86400
SEARCH_PACK_INTERRUPTED_RETRIES = 3
SEARCH_PACK_INTERRUPTION_WINDOW = 60
CATALOG_URL = "https://plugins.omarchy.org/catalog.json"
ENGAGEMENT_URL = "https://api.omarchyplugins.com/v1/stats"
MAX_ENGAGEMENT_BYTES = 2 * 1024 * 1024
ENGAGEMENT_MAX_AGE = 15 * 60
CATALOG_SCHEMA = 3
README_SCHEMA = 1
README_CONTENT_VERSION = 4
README_DOCUMENT_VERSION = 1  # Presentation only; never invalidates the plain search index.
PREFERENCES_SCHEMA = 1
MAX_REQUEST_BYTES = 8 * 1024 * 1024
MAX_OUTPUT_BYTES = 8 * 1024 * 1024
MAX_CATALOG_BYTES = 16 * 1024 * 1024
MAX_CACHE_BYTES = 20 * 1024 * 1024
MAX_README_BYTES = 256 * 1024
MAX_README_TEXT = 24_000
MAX_README_SUMMARY = 900
MAX_README_MEDIA = 4
MAX_MEDIA_URL = 1_200
MAX_MEDIA_LABEL = 120
MAX_PREVIEW_IMAGE_BYTES = 2 * 1024 * 1024
MAX_PREVIEW_PIXELS = 4_000_000
MAX_CATALOG_ROWS = 10_000
MAX_README_ENTRIES = 320
README_FETCH_LIMIT = 12
CATALOG_MAX_AGE = 24 * 60 * 60
README_WORKERS = 4
SEARCH_INDEX_VERSION = 1
MAX_SEARCH_INDEX_BYTES = 256 * 1024 * 1024
MAX_PREFERENCES_BYTES = 64 * 1024
MAX_INVENTORY_ROWS = 2_000
MAX_FEEDBACK_ROWS = 500
MAX_SERVICE_CHOICES = 64
MAX_INTERESTS = 64
MAX_INTEREST_STATE = 4 * 1024 * 1024
INTEREST_SCHEMA = 1
MAX_HOST_STATUS_BYTES = 1024 * 1024
MAX_HOST_TOKEN = 256
HOST_LEASE_DEFAULT_MS = 5_000
HOST_LEASE_MAX_MS = 15_000
HOST_IPC_TIMEOUT = 3
OPEN_WINDOW_KINDS = {"panel", "overlay", "menu"}
OPEN_KNOWN_KINDS = OPEN_WINDOW_KINDS | {"bar-widget", "bar", "service"}
MAX_OPEN_REPLY_BYTES = 4096
SETUP_PAGE_SIZE = 36
MAX_SETUP_PAGE_SIZE = 60
SETUP_OVERVIEW_LIMIT = 6
PREVIEW_FILENAME = re.compile(r"preview-([0-3])-[0-9a-f]{12}\.(?:png|jpg|webp|gif)")
LEGACY_PREVIEW_FILENAME = re.compile(r"preview-([0-3])\.(?:png|jpg|webp|gif)")
THUMBNAIL_FILENAME = re.compile(r"thumb-[0-9a-f]{32}-[0-9a-f]{16}\.(?:png|jpg|webp|gif)")
MAX_THUMBNAIL_BATCH = 12
MAX_THUMBNAIL_FILES = 256
MAX_THUMBNAIL_CACHE_BYTES = 64 * 1024 * 1024
UPDATES_MAX_AGE = 6 * 60 * 60
UPDATES_RETRY_AGE = 5 * 60
MAX_UPDATE_HEAD_BYTES = 4096
MAX_UPDATES_CACHE_BYTES = 4 * 1024 * 1024
MAX_UPDATE_MANIFEST_BYTES = 128 * 1024
UPDATES_WORKERS = 4
UPDATES_TIMEOUT = 60

SETUP_GROUPS = (
    ("desktop-navigation", "Desktop & Navigation"),
    ("appearance", "Appearance & Themes"),
    ("audio-media", "Audio & Media"),
    ("messaging", "Messaging"),
    ("files-backup", "Files, Sync & Backup"),
    ("email-calendar", "Email & Calendars"),
    ("news-weather", "News & Weather"),
    ("productivity", "Productivity"),
    ("hardware", "Hardware & Devices"),
    ("power-system", "Power & System"),
    ("network-privacy", "Network & Privacy"),
    ("development-ai", "Development & AI"),
    ("games-learning", "Games & Learning"),
    ("other", "Other"),
)
SETUP_GROUP_IDS = {identity for identity, _label in SETUP_GROUPS}

WORKFLOW_GOALS = {
    "development": ("Development", {"developer": 18, "development": 16, "coding": 15, "terminal": 10, "git": 9}),
    "gaming": ("Gaming", {"gaming": 18, "games": 15, "steam": 12, "gamepad": 9, "performance": 7}),
    "meetings": ("Meetings", {"meeting": 18, "video call": 16, "microphone": 12, "camera": 10, "headset": 10}),
    "audio": ("Audio", {"audio": 16, "headphones": 14, "equalizer": 12, "mixer": 10, "pipewire": 8}),
    "creative": ("Creative work", {"creative": 16, "design": 12, "photo": 11, "video editing": 11, "drawing": 9}),
    "remote-work": ("Remote work", {"remote work": 18, "focus": 10, "meeting": 9, "vpn": 8, "productivity": 8}),
    "privacy": ("Privacy and networking", {"privacy": 17, "network": 13, "vpn": 12, "firewall": 10, "security": 9}),
    "smart-home": ("Smart home", {"smart home": 18, "home assistant": 16, "iot": 12, "automation": 10}),
    "mobility": ("Laptop mobility", {"laptop": 15, "battery": 14, "power management": 12, "travel": 8}),
}
SOFTWARE_CHOICES = {
    "docker": ("Docker or Podman", {"docker": 20, "podman": 20, "container": 14}),
    "steam": ("Steam", {"steam": 22, "gaming": 12, "games": 10}),
    "obs": ("OBS", {"obs": 24, "streaming": 16, "camera": 8, "microphone": 8}),
    "discord": ("Discord", {"discord": 22, "voice chat": 14, "headset": 8}),
    "editors": ("Code editors", {"neovim": 18, "vscode": 18, "jetbrains": 16, "editor": 9, "developer": 8}),
    "creative-tools": ("Creative tools", {"blender": 18, "kdenlive": 18, "gimp": 16, "creative": 8}),
    "home-assistant": ("Home Assistant", {"home assistant": 24, "smart home": 14}),
    "tailscale": ("Tailscale", {"tailscale": 24, "vpn": 12, "network": 8}),
}
DEFAULT_PREFERENCES = {
    "schema": PREFERENCES_SCHEMA,
    "goals": [],
    "software": [],
    "services": [],
    "servicesOnboardingComplete": False,
    "notes": "",
    "watchHardware": True,
    "readmeEnrichment": True,
    "readmeIndexing": True,
    "marketplaceThumbnails": True,
    "browseDensity": "comfortable",
    "notFit": [],
}

SAFE_ENV_KEYS = (
    "HOME",
    "XDG_CACHE_HOME",
    "XDG_CONFIG_HOME",
    "XDG_RUNTIME_DIR",
    "DBUS_SESSION_BUS_ADDRESS",
    "HYPRLAND_INSTANCE_SIGNATURE",
    "WAYLAND_DISPLAY",
    "OMARCHY_PATH",
    "LANG",
    "LC_ALL",
)
COMMANDS = {
    "pacman": "/usr/bin/pacman",
    "hyprctl": "/usr/bin/hyprctl",
    "bluetoothctl": "/usr/bin/bluetoothctl",
    "wpctl": "/usr/bin/wpctl",
    "omarchy": "/usr/bin/omarchy",
    "omarchy-shell": "/usr/bin/omarchy-shell",
    "git": "/usr/bin/git",
}
SYSTEM_COMMAND_PATH = "/usr/bin:/bin"
MAX_RUNTIME_PATH_BYTES = 4096
CAPABILITIES = {
    "docker": ("/usr/bin/docker", "Docker", {"docker": 12, "container": 6}),
    "tailscale": ("/usr/bin/tailscale", "Tailscale", {"tailscale": 14, "vpn": 4}),
    "steam": ("/usr/bin/steam", "Steam", {"steam": 12, "gaming": 5, "games": 4}),
    "nvidia": ("/usr/bin/nvidia-smi", "NVIDIA graphics", {"nvidia": 14, "gpu": 5}),
    "asusctl": ("/usr/bin/asusctl", "ASUS controls", {"asus": 12, "g14": 10, "aura": 7}),
    "solaar": ("/usr/bin/solaar", "Logitech receiver", {"logitech": 12, "solaar": 12}),
    "bolt": ("/usr/bin/boltctl", "Thunderbolt", {"thunderbolt": 12, "dock": 6}),
}
FEATURES = {
    "multi-monitor": ("Multiple displays", ["multi-monitor", "multiple monitors", "per-monitor"]),
    "touchpad": ("Touchpad", ["touchpad", "trackpad", "gesture"]),
    "touchscreen": ("Touchscreen", ["touchscreen", "touch input"]),
    "pen-tablet": ("Pen or tablet", ["stylus", "active pen", "wacom", "tablet"]),
    "hardware-dock": ("Hardware dock", ["usb-c dock", "thunderbolt dock", "docking station"]),
    "displaylink": ("DisplayLink", ["displaylink"]),
    "camera": ("Camera", ["camera", "webcam", "camera effects"]),
    "razer": ("Razer peripheral", ["razer", "openrazer"]),
    "logitech": ("Logitech peripheral", ["logitech", "solaar"]),
    "elgato": ("Elgato device", ["elgato", "key light", "stream deck"]),
    "framework": ("Framework computer", ["framework"]),
    "asus-gaming": ("ASUS ROG laptop", ["asus", "g14", "rog", "aura"]),
    "thinkpad": ("ThinkPad", ["thinkpad", "lenovo"]),
    "dell": ("Dell computer", ["dell"]),
    "graphics-nvidia": ("NVIDIA graphics", ["nvidia", "nvidia gpu"]),
    "graphics-amd": ("AMD graphics", ["amd gpu", "radeon"]),
    "graphics-intel": ("Intel graphics", ["intel graphics", "intel gpu"]),
    "battery": ("System battery", ["battery", "charge limit", "power management"]),
    "audio-focusrite": ("Focusrite audio", ["focusrite", "scarlett", "audio interface"]),
    "audio-goxlr": ("GoXLR", ["goxlr", "audio interface"]),
    "audio-stream-deck": ("Stream Deck", ["stream deck", "elgato"]),
    "audio-steelseries": ("SteelSeries audio", ["steelseries", "arctis"]),
    "bluetooth-headphones": ("Bluetooth headphones", ["bluetooth headphones", "headset", "bluetooth audio", "bluetooth codec"]),
    "bluetooth-airpods": ("AirPods", ["airpods", "apple headphones"]),
    "bluetooth-galaxy-buds": ("Galaxy Buds", ["galaxy buds", "samsung buds"]),
    "bluetooth-momentum": ("Sennheiser Momentum", ["momentum", "sennheiser"]),
    "bluetooth-wh-1000": ("Sony WH-1000X", ["wh-1000", "sony headphones"]),
    "bluetooth-wf-1000": ("Sony WF-1000X", ["wf-1000", "sony earbuds"]),
    "bluetooth-pixel-buds": ("Pixel Buds", ["pixel buds", "google earbuds"]),
    "bluetooth-bose": ("Bose audio", ["bose"]),
    "bluetooth-beats": ("Beats audio", ["beats"]),
    "bluetooth-dualsense": ("DualSense controller", ["dualsense", "playstation controller", "gamepad"]),
}
PROBE_IDS = ("displays", "input devices", "Bluetooth", "USB devices", "system model",
             "graphics", "audio devices", "power", "software capabilities", "installed plugins", "bar sections")


def signal_metadata(identity: str) -> tuple[str, str, str]:
    if identity.startswith("capability-"):
        return "software capabilities", "software", "installed-executable"
    if identity.startswith("bluetooth-"):
        return "Bluetooth", "hardware", "bluetooth"
    if identity.startswith("audio-"):
        return "audio devices", "hardware", "audio"
    if identity.startswith("graphics-"):
        return "graphics", "hardware", "sysfs"
    probe = ("displays" if identity == "multi-monitor" else
             "input devices" if identity in {"touchpad", "touchscreen", "pen-tablet"} else
             "system model" if identity in {"framework", "asus-gaming", "thinkpad", "dell"} else
             "power" if identity == "battery" else "USB devices")
    return probe, "hardware", "inferred" if identity == "dock-like" else (
        "hyprland" if probe in {"displays", "input devices"} else "sysfs")
STOP_WORDS = {
    "a", "an", "and", "are", "for", "from", "in", "is", "it", "of", "on",
    "or", "the", "this", "to", "with", "your",
}
FORBIDDEN_FORMAT = {
    "\u200b", "\u200c", "\u200d", "\u2060", "\ufeff", "\u202a", "\u202b",
    "\u202c", "\u202d", "\u202e", "\u2066", "\u2067", "\u2068", "\u2069",
}

_children: set[subprocess.Popen[bytes]] = set()
_service_registry: list[dict[str, Any]] | None = None


def clean(value: Any, limit: int = 500) -> str:
    if not isinstance(value, str):
        return ""
    value = unicodedata.normalize("NFKC", value)
    value = "".join(
        char for char in value
        if char not in FORBIDDEN_FORMAT
        and (char in "\n\t" or (ord(char) >= 32 and ord(char) != 127))
    )
    value = re.sub(r"[ \t\r\f\v]+", " ", value)
    value = re.sub(r"\n{3,}", "\n\n", value)
    return value.strip()[:limit]


def one_line(value: Any, limit: int = 500) -> str:
    return re.sub(r"\s+", " ", clean(value, limit * 2)).strip()[:limit]


def normalized(value: Any) -> str:
    return one_line(value, 50_000).casefold()


def full_sha(value: Any) -> str:
    text = one_line(value, 100).lower()
    return text if re.fullmatch(r"[0-9a-f]{40}", text) else ""


def plugin_id(value: Any) -> str:
    text = one_line(value, 500)
    if len(text) > 128 or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", text) or ".." in text:
        return ""
    return text


def github_repo(value: Any) -> tuple[str, str, str] | None:
    text = one_line(value, 2_000)
    if len(text) > 300:
        return None
    try:
        parsed = urllib.parse.urlsplit(text)
        port = parsed.port
    except ValueError:
        return None
    if (
        parsed.scheme != "https"
        or parsed.hostname != "github.com"
        or port not in (None, 443)
        or parsed.username
        or parsed.password
        or parsed.query
        or parsed.fragment
    ):
        return None
    match = re.fullmatch(r"/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?/?", parsed.path)
    if not match or match.group(1).startswith("-") or match.group(2).startswith("-"):
        return None
    owner, repository = match.groups()
    return owner, repository, f"https://github.com/{owner}/{repository}"


def safe_json_loads(raw: bytes, label: str) -> Any:
    try:
        return json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError, RecursionError) as error:
        raise ValueError(f"{label} returned invalid JSON.") from error


def service_id(value: Any) -> str:
    text = one_line(value, 80).lower()
    return text if re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}", text) else ""


def load_service_registry() -> list[dict[str, Any]]:
    global _service_registry
    if _service_registry is not None:
        return _service_registry
    try:
        raw = safe_json_loads(SERVICE_REGISTRY_PATH.read_bytes(), "Outfit service registry")
    except OSError as error:
        raise ValueError("Outfit's bundled service registry is unavailable.") from error
    values = raw.get("services") if isinstance(raw, dict) and raw.get("schema") == 1 else None
    if not isinstance(values, list) or not values or len(values) > MAX_SERVICE_CHOICES:
        raise ValueError("Outfit's bundled service registry is invalid.")

    output: list[dict[str, Any]] = []
    seen: set[str] = set()
    for value in values:
        if not isinstance(value, dict):
            raise ValueError("Outfit's bundled service registry is invalid.")
        identity = service_id(value.get("id"))
        name = one_line(value.get("name"), 80)
        category = one_line(value.get("category"), 80)
        terms = value.get("terms") if isinstance(value.get("terms"), list) else []
        name_terms = value.get("nameTerms") if isinstance(value.get("nameTerms"), list) else []
        includes = value.get("includePluginIds") if isinstance(value.get("includePluginIds"), list) else []
        excludes = value.get("excludePluginIds") if isinstance(value.get("excludePluginIds"), list) else []
        normalized_terms = list(dict.fromkeys(
            normalized(term) for term in terms[:16] if normalized(term)
        ))
        normalized_name_terms = list(dict.fromkeys(
            normalized(term) for term in name_terms[:16] if normalized(term)
        ))
        include_ids = list(dict.fromkeys(
            valid for item in includes[:64] if (valid := plugin_id(item))
        ))
        exclude_ids = list(dict.fromkeys(
            valid for item in excludes[:64] if (valid := plugin_id(item))
        ))
        if (
            not identity or identity in seen or not name or not category
            or not (normalized_terms or normalized_name_terms or include_ids)
        ):
            raise ValueError("Outfit's bundled service registry is invalid.")
        seen.add(identity)
        output.append({
            "id": identity,
            "name": name,
            "category": category,
            "terms": normalized_terms,
            "nameTerms": normalized_name_terms,
            "includePluginIds": include_ids,
            "excludePluginIds": exclude_ids,
        })
    _service_registry = output
    return output


class Store:
    """Owner-only JSON storage rooted at one non-symlinked cache directory."""

    def __init__(self, base: Path) -> None:
        base.mkdir(parents=True, exist_ok=True, mode=0o700)
        metadata = base.lstat()
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
            raise ValueError("Outfit cache path is not a private directory.")
        if metadata.st_uid != os.getuid():
            raise ValueError("Outfit cache belongs to another user.")
        self.base = base
        self.fd = os.open(base, os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0))
        opened = os.fstat(self.fd)
        if opened.st_uid != os.getuid():
            os.close(self.fd)
            raise ValueError("Outfit cache belongs to another user.")
        try:
            if stat.S_IMODE(opened.st_mode) != 0o700:
                os.fchmod(self.fd, 0o700)
            self.cleanup_temporary_writes()
        except Exception:
            os.close(self.fd)
            raise
        self.memory: dict[str, Any] = {}

    def stamp(self, name: str) -> tuple[int, ...] | None:
        try:
            info = os.stat(name, dir_fd=self.fd, follow_symlinks=False)
            return (info.st_ino, info.st_mtime_ns, info.st_ctime_ns, info.st_size, info.st_mode, info.st_uid)
        except FileNotFoundError:
            return None

    def cleanup_temporary_writes(self) -> None:
        cutoff = time.time() - 3600
        for name in os.listdir(self.fd):
            modern = bool(re.fullmatch(r"\.write-v2-[0-9a-f]{32}", name))
            if not modern and not re.fullmatch(r"\.write-[0-9a-f]{32}", name):
                continue
            descriptor = None
            try:
                descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=self.fd)
                info = os.fstat(descriptor)
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                if stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and (modern or info.st_mtime < cutoff):
                    os.unlink(name, dir_fd=self.fd)
            except OSError:
                pass
            finally:
                if descriptor is not None:
                    os.close(descriptor)

    def close(self) -> None:
        os.close(self.fd)

    @contextmanager
    def scoped_lock(self):
        """Serialize read/modify/replace across independent helper processes."""
        fd = os.open(".state.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK,
                     0o600, dir_fd=self.fd)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
                raise ValueError("Unsafe Outfit state lock.")
            deadline = time.monotonic() + 5
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise ValueError("Outfit settings are busy; retry the save.")
                    time.sleep(0.02)
            yield
        finally:
            os.close(fd)

    def read(self, name: str, maximum: int, fallback: Any) -> Any:
        try:
            descriptor = os.open(
                name,
                os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0),
                dir_fd=self.fd,
            )
        except FileNotFoundError:
            return fallback
        with os.fdopen(descriptor, "rb") as stream:
            metadata = os.fstat(stream.fileno())
            if (
                not stat.S_ISREG(metadata.st_mode)
                or metadata.st_uid != os.getuid()
                or metadata.st_size > maximum
            ):
                raise ValueError("Outfit cache file is unsafe or too large.")
            data = stream.read(maximum + 1)
        if len(data) > maximum:
            raise ValueError("Outfit cache file is too large.")
        try:
            return json.loads(data)
        except (UnicodeDecodeError, json.JSONDecodeError, RecursionError) as error:
            raise ValueError("Outfit cache is invalid; refresh it to rebuild.") from error

    def read_state(self, name: str, maximum: int, fallback: Any) -> Any:
        """Read-only snapshots, invalidated by atomic replacement or in-place edits.

        Writers still read the latest file under scoped_lock. Never mutate these
        internal snapshots or expose their nested objects in public responses.
        """
        if name not in {"preferences.json", "interests.json"}:
            raise ValueError("Unsupported state snapshot.")
        stamp = self.stamp(name)
        if stamp is not None and stamp[3] > maximum:
            raise ValueError("Outfit cache file is too large.")
        snapshots = self.memory.setdefault("stateSnapshots", {})
        cached = snapshots.get(name)
        if cached is not None and cached[0] == stamp:
            return cached[1] if stamp is not None else fallback
        value = self.read(name, maximum, fallback)
        if self.stamp(name) == stamp:
            snapshots[name] = (stamp, value)
        else:
            snapshots.pop(name, None)
        return value

    def write(self, name: str, value: Any, maximum: int) -> None:
        data = json.dumps(value, ensure_ascii=True, separators=(",", ":")).encode("utf-8")
        if len(data) > maximum:
            raise ValueError("Outfit cache exceeds its size limit.")
        temporary = f".write-v2-{uuid.uuid4().hex}"
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(temporary, flags, 0o600, dir_fd=self.fd)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        try:
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
                os.replace(temporary, name, src_dir_fd=self.fd, dst_dir_fd=self.fd)
            os.fsync(self.fd)
            memory = getattr(self, "memory", {})
            if name == "catalog.json":
                # Keep the previous rows solely as bounded memo containers. The
                # loader must still validate and normalize the replacement file.
                memory.pop("catalogStamp", None)
            elif name == "readmes.json":
                memory.pop("readmes", None)
            elif name == "engagement.json":
                memory.pop("engagement", None)
            if name in {"preferences.json", "interests.json"}:
                memory.get("stateSnapshots", {}).pop(name, None)
                if name == "interests.json":
                    memory.pop("validatedInterests", None)
        finally:
            try:
                os.unlink(temporary, dir_fd=self.fd)
            except FileNotFoundError:
                pass

    def write_blob(self, name: str, data: bytes, maximum: int) -> str:
        if not (PREVIEW_FILENAME.fullmatch(name) or THUMBNAIL_FILENAME.fullmatch(name)):
            raise ValueError("Outfit preview filename is invalid.")
        if not isinstance(data, bytes) or not data or len(data) > maximum:
            raise ValueError("Outfit preview data is invalid or too large.")
        temporary = f".write-v2-{uuid.uuid4().hex}"
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(temporary, flags, 0o600, dir_fd=self.fd)
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        try:
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
                os.replace(temporary, name, src_dir_fd=self.fd, dst_dir_fd=self.fd)
            os.fsync(self.fd)
        finally:
            try:
                os.unlink(temporary, dir_fd=self.fd)
            except FileNotFoundError:
                pass
        return (self.base / name).as_uri()

    def read_thumbnail(self, name: str) -> bytes:
        if not THUMBNAIL_FILENAME.fullmatch(name):
            raise ValueError("Invalid thumbnail filename.")
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=self.fd)
        with os.fdopen(fd, "rb") as stream:
            metadata = os.fstat(stream.fileno())
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid() \
                    or metadata.st_size > MAX_PREVIEW_IMAGE_BYTES:
                raise ValueError("Unsafe thumbnail cache file.")
            data = stream.read(MAX_PREVIEW_IMAGE_BYTES + 1)
        validate_preview_image(data, thumbnail=True)
        return data

    def clear_preview_slot(self, slot: int) -> None:
        if slot not in range(MAX_README_MEDIA):
            return
        for name in os.listdir(self.fd):
            match = PREVIEW_FILENAME.fullmatch(name) or LEGACY_PREVIEW_FILENAME.fullmatch(name)
            if not match or int(match.group(1)) != slot:
                continue
            try:
                os.unlink(name, dir_fd=self.fd)
            except FileNotFoundError:
                pass


class RestrictedRedirect(urllib.request.HTTPRedirectHandler):
    def __init__(self, host: str) -> None:
        self.host = host
        super().__init__()

    def redirect_request(self, request: Any, response: Any, code: int, message: str,
                         headers: Any, new_url: str) -> Any:
        parsed = urllib.parse.urlsplit(new_url)
        if (
            parsed.scheme != "https"
            or parsed.hostname != self.host
            or parsed.port not in (None, 443)
            or parsed.username
            or parsed.password
        ):
            raise ValueError("Remote content redirected outside its approved host.")
        return super().redirect_request(request, response, code, message, headers, new_url)


def read_bounded_response(response: Any, maximum: int, deadline: float, progress: Any = None) -> bytes:
    announced = response.headers.get("Content-Length")
    try:
        announced_size = int(announced) if announced else 0
    except (ValueError, TypeError):
        announced_size = 0
    if announced_size > maximum:
        raise ValueError("Remote content exceeds its size limit.")
    output = bytearray()
    # HTTPResponse.read(n) may wait for all n bytes while a peer drip-feeds data.
    # read1 makes progress observable; the socket timeout is also capped to the
    # remaining total budget, so a final stalled read cannot renew the deadline.
    reader = response.read1 if callable(getattr(type(response), "read1", None)) else response.read
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("Remote request exceeded its deadline.")
        raw = getattr(getattr(response, "fp", None), "raw", None)
        transport = getattr(raw, "_sock", None)
        if isinstance(transport, socket.socket):
            transport.settimeout(remaining)
        chunk = reader(min(64 * 1024, maximum + 1 - len(output)))
        if time.monotonic() > deadline:
            raise TimeoutError("Remote request exceeded its deadline.")
        if not isinstance(chunk, bytes):
            raise ValueError("Remote content returned invalid bytes.")
        output.extend(chunk)
        if len(output) > maximum:
            raise ValueError("Remote content exceeds its size limit.")
        if chunk and progress is not None:
            progress(bytesReceived=len(output), **({"bytesTotal": announced_size} if announced_size > 0 else {}))
        if not chunk:
            return bytes(output)


class RestrictedMediaRedirect(urllib.request.HTTPRedirectHandler):
    def __init__(self, host: str) -> None:
        self.allowed_hosts = {host}
        super().__init__()

    def redirect_request(self, request: Any, response: Any, code: int, message: str,
                         headers: Any, new_url: str) -> Any:
        parsed = urllib.parse.urlsplit(new_url)
        host = (parsed.hostname or "").lower()
        original = (urllib.parse.urlsplit(request.full_url).hostname or "").lower()
        github_asset = original == "github.com" and bool(re.fullmatch(
            r"github-production-user-asset-[0-9a-f]+\.s3\.amazonaws\.com", host,
        ))
        if (
            parsed.scheme != "https" or parsed.port not in (None, 443)
            or parsed.username or parsed.password
            or (host not in self.allowed_hosts and not github_asset)
        ):
            raise ValueError("Preview media redirected outside its approved host.")
        self.allowed_hosts.add(host)
        return super().redirect_request(request, response, code, message, headers, new_url)


def fetch_bytes(url: str, host: str, maximum: int, timeout: float = 12, progress: Any = None) -> bytes:
    parsed = urllib.parse.urlsplit(url)
    if (
        parsed.scheme != "https"
        or parsed.hostname != host
        or parsed.port not in (None, 443)
        or parsed.username
        or parsed.password
    ):
        raise ValueError("Remote URL is outside its approved HTTPS host.")
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "Outfit/0.1", "Accept": "application/json,text/plain"},
    )
    opener = urllib.request.build_opener(RestrictedRedirect(host))
    deadline = time.monotonic() + timeout
    with opener.open(request, timeout=timeout) as response:
        return read_bounded_response(response, maximum, deadline, progress)


def marketplace_image_url(value: Any) -> str:
    if not isinstance(value, str) or len(value) > MAX_MEDIA_URL:
        return ""
    path = value.removeprefix("https://plugins.omarchy.org/")
    if not re.fullmatch(r"assets/img/plugins/[A-Za-z0-9_.-]+\.(?:webp|png|jpg|jpeg)", path):
        return ""
    return "https://plugins.omarchy.org/" + path


def preview_metadata(raw: dict[str, Any]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for field in ("previewThumbnail", "previewImage"):
        result[field] = marketplace_image_url(raw.get(field))
    for field in ("previewThumbnailWidth", "previewThumbnailHeight", "previewWidth", "previewHeight"):
        value = raw.get(field)
        result[field] = value if type(value) is int and 0 < value <= 5_000 else 0
    return result


def listing_date(value: Any) -> str:
    if not isinstance(value, str) or not re.fullmatch(
        r"\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2}))?", value,
    ):
        return ""
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        parsed = parsed.replace(tzinfo=timezone.utc) if parsed.tzinfo is None else parsed.astimezone(timezone.utc)
        return parsed.isoformat(timespec="seconds").replace("+00:00", "Z") if parsed.year >= 1970 else ""
    except (ValueError, OverflowError):
        return ""


@functools.lru_cache(maxsize=MAX_CATALOG_ROWS)
def listing_time(value: str) -> float:
    valid = listing_date(value)
    return datetime.fromisoformat(valid.replace("Z", "+00:00")).timestamp() if valid else 0


def _normalize_catalog_rows(values: Any, cached: bool = False) -> list[dict[str, Any]]:
    if not isinstance(values, list):
        raise ValueError("Marketplace catalog has an unsupported format.")
    if len(values) > MAX_CATALOG_ROWS:
        raise ValueError("Marketplace catalog has too many entries.")
    rows: list[dict[str, Any]] = []
    seen: set[str] = set()
    for raw in values:
        if not isinstance(raw, dict) or (not cached and raw.get("sourceType") != "community"):
            continue
        identity = plugin_id(raw.get("id"))
        repository = github_repo(raw.get("repo"))
        if not identity or identity in seen or repository is None:
            continue
        seen.add(identity)
        owner, repo_name, canonical_repo = repository
        tags = raw.get("tags") if isinstance(raw.get("tags"), list) else []
        kinds = raw.get("kinds") if isinstance(raw.get("kinds"), list) else []
        stars = raw.get("stars")
        rows.append({
            **preview_metadata(raw),
            "_recommendationCache": {},
            "_purposeCache": {},
            "_interestMatchCache": {},
            "_readmeFieldsCache": {},
            "id": identity,
            "name": one_line(raw.get("name"), 120) or identity,
            "description": one_line(raw.get("description"), 1_000),
            "installNote": one_line(raw.get("installNote"), 500),
            "author": one_line(raw.get("author"), 120),
            "version": one_line(raw.get("version"), 64),
            "category": one_line(raw.get("category"), 80),
            "tags": [one_line(tag, 50) for tag in tags[:12] if one_line(tag, 50)],
            "kind": one_line(raw.get("kind"), 80),
            "kinds": [one_line(kind, 40) for kind in kinds[:8] if one_line(kind, 40)],
            "status": one_line(raw.get("status"), 80),
            "repo": canonical_repo,
            "owner": owner,
            "repoName": repo_name,
            "listingCommit": full_sha(raw.get("listingCommit") if cached else raw.get("listingValidatedCommit")),
            "verificationCommit": full_sha(raw.get("verificationCommit")),
            "verificationStatus": one_line(raw.get("verificationStatus"), 32),
            "verificationSnapshotStatus": one_line(raw.get("verificationSnapshotStatus"), 32),
            "verificationCoverage": one_line(raw.get("verificationCoverage"), 64),
            "verificationMethod": one_line(raw.get("verificationMethod"), 64),
            "repositoryLayout": one_line(raw.get("repositoryLayout"), 32),
            "installAvailable": raw.get("installAvailable") is True,
            "stars": stars if type(stars) is int and 0 <= stars <= 2_147_483_647 else None,
            "listedAt": listing_date(raw.get("listedAt")) or listing_date(raw.get("addedAt")),
            "versionUpdatedAt": listing_date(raw.get("versionUpdatedAt")),
            "repositoryUpdatedAt": listing_date(raw.get("repositoryUpdatedAt")),
            "party": "third-party",
            "enabled": raw.get("enabled") is True,
            "active": raw.get("active") is True,
            "canDisable": False,
            "localOnly": False,
        })
    if not rows:
        raise ValueError("Marketplace catalog contains no usable community plugins.")
    return rows


def normalize_catalog(data: Any) -> tuple[list[dict[str, Any]], str]:
    if not isinstance(data, dict):
        raise ValueError("Marketplace catalog has an unsupported format.")
    rows = _normalize_catalog_rows(data.get("plugins"))
    return rows, one_line(data.get("generatedAt"), 64)


def fetch_catalog(progress: Any = None) -> tuple[list[dict[str, Any]], str]:
    return normalize_catalog(safe_json_loads(
        fetch_bytes(CATALOG_URL, "plugins.omarchy.org", MAX_CATALOG_BYTES, 20,
                    **({"progress": progress} if progress is not None else {})),
        "Marketplace",
    ))


def validate_engagement(value: Any) -> dict[str, dict[str, int | None]]:
    if not isinstance(value, dict) or type(value.get("schemaVersion")) is not int or value.get("schemaVersion") != 1 \
            or not isinstance(value.get("plugins"), dict) \
            or len(value["plugins"]) > MAX_CATALOG_ROWS:
        raise ValueError("Marketplace likes have an unsupported format.")
    counts = {}
    for identity, entry in value["plugins"].items():
        if not plugin_id(identity) or identity.lower() in {"constructor", "prototype", "__proto__"}:
            continue
        if not isinstance(entry, dict):
            continue
        metrics = {}
        for metric in ("hearts", "views", "copies"):
            count = entry.get(metric)
            metrics[metric] = count if type(count) is int and 0 <= count <= 9_007_199_254_740_991 else None
        if any(count is not None for count in metrics.values()):
            counts[identity] = metrics
    return counts


def load_engagement(store: Store) -> tuple[dict[str, dict[str, int | None]], float]:
    stamp = store.stamp("engagement.json")
    cached = store.memory.get("engagement")
    if cached is not None and stamp == store.memory.get("engagementStamp"):
        return cached
    raw = store.read("engagement.json", MAX_ENGAGEMENT_BYTES,
                     {"schemaVersion": 1, "plugins": {}, "fetchedAt": 0})
    counts = validate_engagement(raw)
    fetched = raw.get("fetchedAt", 0)
    fetched = fetched if type(fetched) in (int, float) and math.isfinite(fetched) and fetched >= 0 else 0
    result = (counts, fetched)
    store.memory["engagement"] = result
    store.memory["engagementStamp"] = stamp
    return result


def update_engagement(store: Store, action: str, now: float) -> tuple[dict[str, dict[str, int | None]], float, str]:
    try:
        counts, fetched = load_engagement(store)
    except (OSError, ValueError):
        counts, fetched = {}, 0
    if action == "refresh" or (action == "analyze" and (
        not fetched or now - fetched > ENGAGEMENT_MAX_AGE or fetched > now + 60
    )):
        try:
            fresh = validate_engagement(safe_json_loads(
                fetch_bytes(ENGAGEMENT_URL, "api.omarchyplugins.com", MAX_ENGAGEMENT_BYTES, 10),
                "Marketplace likes",
            ))
            store.write("engagement.json", {
                "schemaVersion": 1, "fetchedAt": now,
                "plugins": fresh,
            }, MAX_ENGAGEMENT_BYTES)
            counts, fetched = fresh, now
        except (OSError, TimeoutError, urllib.error.URLError, ValueError):
            return counts, fetched, "Marketplace counts unavailable; using saved totals." if fetched else "Marketplace counts unavailable."
    return counts, fetched, ""


def markdown_text(value: str) -> str:
    value = clean(value, MAX_README_BYTES)
    value = re.sub(r"```.*?```", " ", value, flags=re.DOTALL)
    value = re.sub(r"`([^`\r\n]{0,2000})`", r" \1 ", value)
    value = re.sub(
        r"!\[([^\]\r\n]{0,300})\]\([^\)\r\n]{0,2000}\)", r" \1 ", value,
    )
    value = re.sub(
        r"\[([^\]\r\n]{1,300})\]\([^\)\r\n]{0,2000}\)", r" \1 ", value,
    )
    value = re.sub(r"<[^>]{0,500}>", " ", value)
    value = re.sub(r"https?://\S+", " ", value)
    value = re.sub(r"[#>*_|~=-]+", " ", value)
    return one_line(value, MAX_README_TEXT)


def strip_html_comments(value: str) -> str:
    output: list[str] = []
    offset = 0
    while True:
        start = value.find("<!--", offset)
        if start < 0:
            output.append(value[offset:])
            break
        output.append(value[offset:start])
        end = value.find("-->", start + 4)
        if end < 0:
            break
        offset = end + 3
    return "".join(output)


def markdown_content(value: str) -> str:
    value = clean(value, MAX_README_BYTES)
    value = "".join(char for char in value if unicodedata.category(char) != "Co")
    value = re.sub(r"\A---\s*\n.*?\n---\s*(?:\n|\Z)", "", value, flags=re.DOTALL)
    value = strip_html_comments(value)
    value = re.sub(
        r"\[!\[[^\]\r\n]{0,300}\]\([^\)\r\n]{0,2000}\)\]"
        r"\([^\)\r\n]{0,2000}\)", "", value,
    )
    value = re.sub(
        r"!\[[^\]\r\n]{0,300}\]\([^\)\r\n]{0,2000}\)", "", value,
    )
    value = re.sub(
        r"\[([^\]\r\n]{1,300})\]\([^\)\r\n]{0,2000}\)", r"\1", value,
    )
    value = re.sub(r"<https?://[^>]+>", "", value)
    value = re.sub(r"<[^>]{0,500}>", "", value)

    output: list[str] = []
    in_code = False
    for raw_line in value.splitlines():
        line = raw_line.strip()
        if re.match(r"^(```|~~~)", line):
            in_code = not in_code
            continue
        if in_code:
            line = one_line(raw_line, 500)
            if line:
                output.append("$ " + line)
            continue
        if re.fullmatch(r"[-*_]{3,}", line):
            continue
        line = re.sub(r"^#{1,6}\s*", "", line)
        line = re.sub(r"^>\s?", "", line)
        line = re.sub(r"https?://\S+", "", line)
        line = re.sub(r"[*_~`]", "", line)
        line = re.sub(r"\s+", " ", line).strip()
        if line and re.fullmatch(r"(?:\[[^\]]*\]\s*)+", line):
            continue
        output.append(line)

    content = "\n".join(output)
    content = re.sub(r"\n{3,}", "\n\n", content)
    return clean(content, MAX_README_TEXT)


def readme_summary(content: str, plugin_name: str = "") -> str:
    name = normalized(plugin_name)
    selected: list[str] = []
    total = 0
    for block in re.split(r"\n\s*\n", clean(content, MAX_README_TEXT)):
        lines = [line.strip() for line in block.splitlines() if line.strip()]
        if any(re.match(r"^(?:[-+*]|\d+[.)])\s+", line) for line in lines):
            continue
        paragraph = one_line(block, MAX_README_SUMMARY)
        lowered = normalized(paragraph)
        if paragraph.count("|") >= 3 or paragraph.count(":") >= 3:
            continue
        if not paragraph or lowered == name:
            continue
        if len(paragraph) < 50 or len(re.findall(r"[A-Za-z]{2,}", paragraph)) < 7:
            continue
        if re.match(r"^(install|installation|requirements?|configuration|license|development)\b", lowered):
            if selected:
                break
            continue
        remaining = MAX_README_SUMMARY - total - (2 if selected else 0)
        if remaining <= 0:
            break
        excerpt = paragraph[:remaining].rstrip()
        if len(paragraph) > remaining:
            boundary = max(excerpt.rfind(". "), excerpt.rfind("! "), excerpt.rfind("? "))
            if boundary >= 120:
                excerpt = excerpt[:boundary + 1]
            else:
                word = excerpt.rfind(" ")
                excerpt = (excerpt[:word] if word >= 60 else excerpt).rstrip(" ,;:") + "..."
        selected.append(excerpt)
        total += len(selected[-1]) + (2 if len(selected) > 1 else 0)
        if len(selected) >= 3 or total >= MAX_README_SUMMARY:
            break
    return clean("\n\n".join(selected), MAX_README_SUMMARY)


IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".webp", ".gif", ".avif"}
VIDEO_EXTENSIONS = {".mp4", ".webm", ".mov", ".m4v"}
MEDIA_NOISE_TERMS = {
    "badge", "shield", "logo", "icon", "build status", "coverage", "license badge",
    "version badge", "download badge", "sponsor",
}
MEDIA_VALUE_TERMS = {
    "preview", "screenshot", "screen shot", "demo", "showcase", "interface", "panel",
    "widget", "window", "dashboard", "gallery",
}


def _media_extension(path: str) -> str:
    lowered = urllib.parse.unquote(path).lower()
    return next((extension for extension in IMAGE_EXTENSIONS | VIDEO_EXTENSIONS
                 if lowered.endswith(extension)), "")


def _youtube_url(parsed: urllib.parse.SplitResult) -> str:
    host = (parsed.hostname or "").lower()
    video_id = ""
    if host == "youtu.be":
        video_id = parsed.path.strip("/").split("/", 1)[0]
    elif host in {"youtube.com", "www.youtube.com", "m.youtube.com"}:
        if parsed.path == "/watch":
            video_id = urllib.parse.parse_qs(parsed.query).get("v", [""])[0]
        else:
            match = re.fullmatch(r"/(?:shorts|embed)/([A-Za-z0-9_-]{6,20})/?", parsed.path)
            video_id = match.group(1) if match else ""
    if not re.fullmatch(r"[A-Za-z0-9_-]{6,20}", video_id):
        return ""
    return f"https://www.youtube.com/watch?v={video_id}"


def _trusted_cached_media_url(value: Any, kind: str) -> str:
    url = one_line(value, MAX_MEDIA_URL)
    try:
        parsed = urllib.parse.urlsplit(url)
        port = parsed.port
    except ValueError:
        return ""
    if (
        parsed.scheme != "https" or port not in (None, 443)
        or parsed.username or parsed.password or parsed.fragment
    ):
        return ""
    host = (parsed.hostname or "").lower()
    if kind == "external-video":
        return _youtube_url(parsed)
    if parsed.query:
        return ""
    if host == "raw.githubusercontent.com" and re.fullmatch(
        r"/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/[0-9a-f]{40}/[^\s?#]+", parsed.path,
    ):
        return url
    if host == "github.com" and re.fullmatch(
        r"/user-attachments/assets/[A-Za-z0-9-]{20,}", parsed.path,
    ):
        return url
    if host == "user-images.githubusercontent.com" and re.fullmatch(r"/[^\s?#]+", parsed.path):
        return url if kind == "image" else ""
    return ""


def validate_readme_media(values: Any) -> list[dict[str, str]]:
    if not isinstance(values, list):
        return []
    output: list[dict[str, str]] = []
    seen: set[str] = set()
    for value in values[:MAX_README_MEDIA]:
        if not isinstance(value, dict):
            continue
        kind = one_line(value.get("kind"), 30)
        if kind not in {"image", "video", "external-video"}:
            continue
        url = _trusted_cached_media_url(value.get("url"), kind)
        if not url or url in seen:
            continue
        poster = _trusted_cached_media_url(value.get("poster"), "image")
        label = one_line(value.get("label"), MAX_MEDIA_LABEL)
        output.append({
            "kind": kind,
            "url": url,
            "poster": poster,
            "label": label or ("Plugin preview" if kind == "image" else "Demo video"),
        })
        seen.add(url)
    return output


def _decoded_media_parts(values: Iterable[str]) -> list[str]:
    output: list[str] = []
    for value in values:
        decoded = urllib.parse.unquote(value)
        if not decoded or decoded in {".", ".."} or "/" in decoded or "\\" in decoded:
            return []
        output.append(decoded)
    return output


def _readme_media_url(
    value: Any, item: dict[str, Any], kind_hint: str = "",
) -> tuple[str, str] | None:
    raw = html.unescape(one_line(value, MAX_MEDIA_URL)).strip(" <>\"'")
    if not raw or raw.startswith(("#", "//")) or "\\" in raw:
        return None
    owner = item.get("owner", "")
    repository = item.get("repoName", "")
    commit = full_sha(item.get("listingCommit"))
    if not owner or not repository or not commit:
        return None
    try:
        parsed = urllib.parse.urlsplit(raw)
        port = parsed.port
    except ValueError:
        return None
    if parsed.username or parsed.password or port not in (None, 443):
        return None

    extension = _media_extension(parsed.path)
    kind = kind_hint
    if not kind:
        kind = "image" if extension in IMAGE_EXTENSIONS else (
            "video" if extension in VIDEO_EXTENSIONS else ""
        )

    if not parsed.scheme:
        decoded_path = urllib.parse.unquote(parsed.path).lstrip("/")
        parts = [part for part in decoded_path.split("/") if part not in {"", "."}]
        if not parts or ".." in parts:
            return None
        extension = _media_extension("/".join(parts))
        if kind == "image" and extension not in IMAGE_EXTENSIONS:
            return None
        if kind == "video" and extension not in VIDEO_EXTENSIONS:
            return None
        if kind not in {"image", "video"}:
            return None
        path = urllib.parse.quote("/".join(parts), safe="/-._~")
        return kind, f"https://raw.githubusercontent.com/{owner}/{repository}/{commit}/{path}"

    if parsed.scheme != "https":
        return None
    host = (parsed.hostname or "").lower()
    youtube = _youtube_url(parsed)
    if youtube:
        return "external-video", youtube
    if host == "github.com" and re.fullmatch(
        r"/user-attachments/assets/[A-Za-z0-9-]{20,}", parsed.path,
    ):
        if kind not in {"image", "video"}:
            kind = "video"
        return kind, f"https://github.com{parsed.path}"
    if host == "user-images.githubusercontent.com" and kind == "image" \
            and re.fullmatch(r"/[^\s?#]+", parsed.path):
        return kind, f"https://user-images.githubusercontent.com{parsed.path}"

    encoded_parts = [part for part in parsed.path.split("/") if part]
    parts = _decoded_media_parts(encoded_parts)
    if not parts:
        return None
    media_path: list[str] = []
    if host == "raw.githubusercontent.com" and len(parts) >= 4 \
            and parts[0].casefold() == owner.casefold() \
            and parts[1].casefold() == repository.casefold():
        if len(parts) >= 6 and parts[2:4] == ["refs", "heads"] \
                and parts[4] in {"main", "master"}:
            media_path = parts[5:]
        elif len(parts) >= 6 and parts[2:4] == ["refs", "tags"]:
            media_path = parts[5:]
        elif parts[2] == "refs":
            return None
        else:
            media_path = parts[3:]
    elif host == "github.com" and len(parts) >= 5 \
            and parts[0].casefold() == owner.casefold() \
            and parts[1].casefold() == repository.casefold() \
            and parts[2] in {"blob", "raw"}:
        media_path = parts[4:]
    if not media_path or ".." in media_path:
        return None
    extension = _media_extension("/".join(media_path))
    if kind == "image" and extension not in IMAGE_EXTENSIONS:
        return None
    if kind == "video" and extension not in VIDEO_EXTENSIONS:
        return None
    if kind not in {"image", "video"}:
        kind = "image" if extension in IMAGE_EXTENSIONS else (
            "video" if extension in VIDEO_EXTENSIONS else ""
        )
    if not kind:
        return None
    path = urllib.parse.quote("/".join(media_path), safe="/-._~")
    return kind, f"https://raw.githubusercontent.com/{owner}/{repository}/{commit}/{path}"


def _html_attributes(value: str) -> dict[str, str]:
    attributes: dict[str, str] = {}
    for match in re.finditer(
        r"([A-Za-z_:][A-Za-z0-9_.:-]*)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))",
        value,
    ):
        attributes[match.group(1).lower()] = html.unescape(
            next(group for group in match.groups()[1:] if group is not None)
        )
    return attributes


def _html_blocks(value: str, tag: str) -> Iterable[tuple[str, str, int]]:
    lowered = value.lower()
    opening = "<" + tag.lower()
    closing = "</" + tag.lower()
    offset = 0
    while True:
        start = lowered.find(opening, offset)
        if start < 0:
            return
        name_end = start + len(opening)
        if name_end < len(lowered) and (lowered[name_end].isalnum() or lowered[name_end] in "_-:"):
            offset = name_end
            continue
        opening_end = lowered.find(">", name_end)
        if opening_end < 0:
            return
        close_start = lowered.find(closing, opening_end + 1)
        if close_start < 0:
            yield value[name_end:opening_end], "", start
            return
        close_end = lowered.find(">", close_start + len(closing))
        yield value[name_end:opening_end], value[opening_end + 1:close_start], start
        offset = len(value) if close_end < 0 else close_end + 1


def _html_tags(value: str, tag: str) -> Iterable[tuple[str, int]]:
    lowered = value.lower()
    opening = "<" + tag.lower()
    offset = 0
    while True:
        start = lowered.find(opening, offset)
        if start < 0:
            return
        name_end = start + len(opening)
        if name_end < len(lowered) and (lowered[name_end].isalnum() or lowered[name_end] in "_-:"):
            offset = name_end
            continue
        opening_end = lowered.find(">", name_end)
        if opening_end < 0:
            return
        yield value[name_end:opening_end], start
        offset = opening_end + 1


def _markdown_destination(
    value: str, opening: int, closing_parens: list[int],
) -> tuple[str, int] | None:
    if opening >= len(value) or value[opening] != "(":
        return None
    candidate = bisect_left(closing_parens, opening + 1)
    if candidate >= len(closing_parens):
        return None
    closing = closing_parens[candidate]
    if closing - opening > 2_200:
        return None
    destination = value[opening + 1:closing].strip()
    if not destination:
        return None
    if destination.startswith("<"):
        angle = destination.find(">", 1)
        if angle < 0:
            return None
        target = destination[:angle + 1]
    else:
        target = destination.split(None, 1)[0]
    return target, closing + 1


def _markdown_links(
    value: str, image: bool, closing_brackets: list[int], closing_parens: list[int],
) -> Iterable[tuple[str, str, int, int]]:
    marker = "![" if image else "["
    offset = 0
    while True:
        start = value.find(marker, offset)
        if start < 0:
            return
        label_start = start + len(marker)
        offset = label_start
        if not image and start > 0 and value[start - 1] == "!":
            continue
        candidate = bisect_left(closing_brackets, label_start)
        if candidate >= len(closing_brackets):
            return
        label_end = closing_brackets[candidate]
        if label_end - label_start > 200:
            continue
        destination = _markdown_destination(value, label_end + 1, closing_parens)
        if not destination:
            continue
        target, end = destination
        yield value[label_start:label_end], target, start, end
        offset = end


def readme_media(source: str, item: dict[str, Any]) -> list[dict[str, str]]:
    source = clean(source, MAX_README_BYTES)
    candidates: list[tuple[int, int, dict[str, str]]] = []
    seen: set[str] = set()
    closing_brackets = [index for index, char in enumerate(source) if char == "]"]
    closing_parens = [index for index, char in enumerate(source) if char == ")"]
    image_links = list(_markdown_links(
        source, True, closing_brackets, closing_parens,
    ))
    regular_links = list(_markdown_links(
        source, False, closing_brackets, closing_parens,
    ))
    linked_image_starts: set[int] = set()
    linked_outer_starts: set[int] = set()

    def add(value: Any, label: Any, hint: str, position: int, poster: Any = "") -> bool:
        resolved = _readme_media_url(value, item, hint)
        if not resolved:
            return False
        kind, url = resolved
        if url in seen:
            return False
        media_label = one_line(label, MAX_MEDIA_LABEL)
        nearby = normalized(source[max(0, position - 240):position + 120])
        identity_text = normalized(" ".join((media_label, value)))
        if any(term in identity_text for term in MEDIA_NOISE_TERMS):
            return False
        descriptor = identity_text + " " + nearby
        poster_url = ""
        if poster:
            resolved_poster = _readme_media_url(poster, item, "image")
            poster_url = resolved_poster[1] if resolved_poster else ""
        score = sum(25 for term in MEDIA_VALUE_TERMS if term in descriptor)
        score += 12 if kind in {"video", "external-video"} else 6
        score += 5 if poster_url else 0
        score += 4 if position < max(1_500, len(source) // 4) else 0
        candidates.append((score, position, {
            "kind": kind,
            "url": url,
            "poster": poster_url,
            "label": media_label or ("Plugin preview" if kind == "image" else "Demo video"),
        }))
        seen.add(url)
        return True

    for label, poster, start, end in image_links:
        if start < 1 or source[start - 1] != "[" or end + 1 >= len(source) \
                or source[end] != "]" or source[end + 1] != "(":
            continue
        destination = _markdown_destination(source, end + 1, closing_parens)
        if not destination:
            continue
        target, _outer_end = destination
        if add(target, label, "video", start - 1, poster):
            linked_image_starts.add(start)
            linked_outer_starts.add(start - 1)

    for attributes_text, body, position in _html_blocks(source, "video"):
        attributes = _html_attributes(attributes_text)
        source_match = re.search(r"<source\b([^>]*)>", body, re.IGNORECASE)
        source_attributes = _html_attributes(source_match.group(1)) if source_match else {}
        add(
            attributes.get("src") or source_attributes.get("src"),
            attributes.get("title") or attributes.get("aria-label") or "Demo video",
            "video", position, attributes.get("poster", ""),
        )
    for attributes_text, position in _html_tags(source, "video"):
        attributes = _html_attributes(attributes_text)
        add(
            attributes.get("src"), attributes.get("title") or "Demo video",
            "video", position, attributes.get("poster", ""),
        )
    for attributes_text, position in _html_tags(source, "img"):
        attributes = _html_attributes(attributes_text)
        width = int(attributes.get("width", "0")) if attributes.get("width", "").isdigit() else 0
        height = int(attributes.get("height", "0")) if attributes.get("height", "").isdigit() else 0
        if (width and width < 180) or (height and height < 100):
            continue
        add(
            attributes.get("src"), attributes.get("alt") or attributes.get("title"),
            "image", position,
        )

    for label, target, start, _end in image_links:
        if start in linked_image_starts:
            continue
        add(target, label, "image", start)

    for label, target, start, _end in regular_links:
        if start in linked_outer_starts:
            continue
        add(target, label, "video", start)

    attachment_pattern = re.compile(
        r"https://github\.com/user-attachments/assets/[A-Za-z0-9-]{20,}", re.IGNORECASE,
    )
    for match in attachment_pattern.finditer(source):
        add(match.group(0), "Demo video", "video", match.start())

    candidates.sort(key=lambda candidate: (-candidate[0], candidate[1], candidate[2]["url"]))
    return validate_readme_media([candidate[2] for candidate in candidates[:MAX_README_MEDIA]])


def readme_link(value: str, item: dict[str, Any]) -> str:
    """Explicit-click HTTPS links only, with relative links pinned to the listing."""
    value = html.unescape(value).strip()
    if not value or len(value) > 1200:
        return ""
    decoded = urllib.parse.unquote(value)
    if any(ord(c) <= 32 or ord(c) == 127 or c in '\\<>"\'' for c in decoded):
        return ""
    owner, repo, commit = item.get("owner", ""), item.get("repoName", ""), item.get("listingCommit", "")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", owner) or not re.fullmatch(r"[A-Za-z0-9_.-]+", repo) or not full_sha(commit):
        return ""
    base = f"https://github.com/{owner}/{repo}/blob/{commit}/"
    try:
        parts = urllib.parse.urlsplit(value)
        if not parts.scheme:
            if value.startswith("//"):
                return ""
            value = urllib.parse.urljoin(base + "README.md", value if not value.startswith("/") else value[1:])
            if not value.startswith(base) or any(p == ".." for p in urllib.parse.unquote(urllib.parse.urlsplit(value).path).split("/")):
                return ""
            parts = urllib.parse.urlsplit(value)
        if (parts.scheme != "https" or parts.username is not None or parts.password is not None
                or parts.port not in (None, 443) or not parts.hostname
                or not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?", parts.hostname)):
            return ""
    except ValueError:
        return ""
    return value


def _readme_pairs(text: str, opening: str, closing: str) -> dict[int, int]:
    """Pair delimiters in one pass, including adversarial unmatched nesting."""
    stack: list[int] = []
    pairs: dict[int, int] = {}
    i, quote = 0, ""
    while i < len(text):
        char = text[i]
        if char == "\\":
            i += 2
            continue
        if opening == "(" and stack and char in "\"'" and (quote or (i and text[i - 1].isspace())):
            quote = "" if quote == char else char if not quote else quote
        elif not quote:
            if char == opening:
                stack.append(i)
            elif char == closing and stack:
                pairs[stack.pop()] = i
        i += 1
    return pairs


def _readme_destination(value: str) -> str:
    value = value.strip()
    if value.startswith("<"):
        end = value.find(">")
        return value[1:end] if end >= 0 else ""
    # Optional Markdown link titles are discarded, not interpreted as attributes.
    return re.sub(r"\\([!\"#$%&'()*+,\-./:;<=>?@\[\]\\^_`{|}~])", r"\1", value.split()[0]) if value else ""


def readme_inline(text: str, item: dict[str, Any], references: dict[str, str], depth: int = 0,
                  link_budget: list[int] | None = None) -> list[dict[str, Any]]:
    """Small structural parser. Only data tokens leave this function, never HTML.

    Balanced brackets/parentheses consume nested images and linked badges as a
    unit. Unsupported/malformed markup is inert text; recursion is bounded.
    """
    if depth >= 12:
        return [{"kind": "text", "text": text}]
    if link_budget is None:
        link_budget = [64_000]
    tokens: list[dict[str, Any]] = []
    plain: list[str] = []
    brackets = _readme_pairs(text, "[", "]")
    parentheses = _readme_pairs(text, "(", ")")

    def flush() -> None:
        if plain:
            tokens.append({"kind": "text", "text": html.unescape("".join(plain))})
            plain.clear()

    def link(value: str) -> str:
        url = readme_link(value, item)
        # Repeated reference links must not amplify a 24k README into MBs of URLs.
        if len(url) > link_budget[0]:
            return ""
        link_budget[0] -= len(url)
        return url

    i = 0
    while i < len(text):
        char = text[i]
        if char == "\\" and i + 1 < len(text):
            plain.append(text[i + 1])
            i += 2
            continue
        if char == "`":
            end = i
            while end < len(text) and text[end] == "`":
                end += 1
            close = text.find(text[i:end], end)
            if close >= 0:
                flush()
                tokens.append({"kind": "code", "text": text[end:close].replace("\n", " ")})
                i = close + end - i
                continue
        image = text.startswith("![", i)
        if char == "[" or image:
            start = i + int(image)
            close = brackets.get(start, -1)
            if close >= 0:
                label, end, destination = text[start + 1:close], close + 1, ""
                if end < len(text) and text[end] == "(":
                    finish = parentheses.get(end, -1)
                    if finish >= 0:
                        destination, end = _readme_destination(text[end + 1:finish]), finish + 1
                    elif image:
                        end = len(text)
                elif end < len(text) and text[end] == "[":
                    finish = brackets.get(end, -1)
                    if finish >= 0:
                        key = " ".join((text[end + 1:finish] or label).lower().split())
                        destination, end = references.get(key, ""), finish + 1
                else:
                    destination = references.get(" ".join(label.lower().split()), "")
                if image or destination or end > close + 1:
                    flush()
                    if not image:
                        children = readme_inline(label, item, references, depth + 1, link_budget)
                        url = link(destination)
                        # Empty image-only badges don't leave invisible clickable links.
                        if children:
                            tokens.append({"kind": "link", "url": url, "children": children} if url else
                                          {"kind": "span", "children": children})
                    i = end
                    continue
        if char == "<":
            # Consume tags with quoted '>' correctly. No repository HTML is emitted.
            end, quote = i + 1, ""
            while end < len(text):
                c = text[end]
                if c in "\"'":
                    quote = "" if quote == c else c if not quote else quote
                if c == ">" and not quote:
                    break
                end += 1
            if end < len(text):
                inside = text[i + 1:end]
                url = link(inside) if inside.startswith("https://") else ""
                flush()
                if url:
                    tokens.append({"kind": "link", "url": url, "children": [{"kind": "text", "text": inside}]})
                elif re.match(r"/?(?:script|style|iframe)\b", inside, re.I) and not inside.startswith("/"):
                    closing = re.search(r"</(?:script|style|iframe)\s*>", text[end + 1:], re.I)
                    end = end + 1 + closing.end() - 1 if closing else len(text) - 1
                i = end + 1
                continue
            plain.append(text[i:])
            break
        if char in "*_~":
            marker = char * 2 if text.startswith(char * 2, i) else char
            # Underscores inside identifiers are literal, as in GitHub Markdown.
            close = text.find(marker, i + len(marker))
            if close > i + len(marker) and not (char == "_" and i and text[i - 1].isalnum()) and marker != "~":
                flush()
                tokens.append({"kind": "strong" if len(marker) == 2 and char != "~" else "strike" if char == "~" else "em",
                               "children": readme_inline(text[i + len(marker):close], item, references, depth + 1, link_budget)})
                i = close + len(marker)
                continue
        plain.append(char)
        i += 1
    flush()
    return tokens


def readme_source(value: Any) -> str:
    # Unlike search's clean(), indentation and code whitespace are significant.
    if not isinstance(value, str):
        return ""
    return "".join(c for c in value[:MAX_README_TEXT].replace("\r\n", "\n").replace("\r", "\n")
                   if c not in FORBIDDEN_FORMAT and (c in "\n\t" or (ord(c) >= 32 and ord(c) != 127)))


def readme_document(source: str, item: dict[str, Any]) -> list[dict[str, Any]]:
    """Bounded common-Markdown block model, separate from search/plain content."""
    lines = readme_source(source).splitlines()
    references: dict[str, str] = {}
    fence = ""
    # Definitions are document-wide, but fenced code is always literal.
    for line in lines:
        stripped = line.lstrip()
        mark = re.match(r"(`{3,}|~{3,})", stripped)
        if mark:
            if not fence:
                fence = mark[0]
            elif mark[0][0] == fence[0] and len(mark[0]) >= len(fence):
                fence = ""
        if not fence:
            match = re.match(r"^ {0,3}\[([^\]]+)\]:\s*(.+)$", line)
            if match:
                references[" ".join(match[1].lower().split())] = _readme_destination(match[2])
    blocks: list[dict[str, Any]] = []
    paragraph: list[str] = []
    link_budget = [64_000]

    def inline(value: str) -> list[dict[str, Any]]:
        return readme_inline(value, item, references, link_budget=link_budget)

    def flush() -> None:
        if paragraph:
            tokens = inline(" ".join(paragraph))
            if tokens:
                blocks.append({"kind": "paragraph", "inlines": tokens})
            paragraph.clear()

    def cells(line: str) -> list[str]:
        # Escaped pipes and pipes inside code spans do not split a cell.
        values, value, code, j = [], [], "", 0
        line = line.strip().strip("|")
        while j < len(line):
            if line[j] == "\\" and j + 1 < len(line):
                value.extend(line[j:j + 2])
                j += 2
                continue
            if line[j] == "`":
                end = j + 1
                while end < len(line) and line[end] == "`":
                    end += 1
                marker = line[j:end]
                code = "" if code == marker else marker if not code else code
                value.extend(marker)
                j = end
                continue
            if line[j] == "|" and not code:
                values.append("".join(value).strip())
                value = []
            else:
                value.append(line[j])
            j += 1
        return values + ["".join(value).strip()]

    i = 0
    while i < len(lines):
        line, stripped = lines[i], lines[i].strip()
        if len(blocks) >= 800:
            flush()
            blocks.append({"kind": "code", "text": "\n".join(lines[i:])})
            break
        mark = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", line)
        if mark:
            flush()
            code = []
            i += 1
            while i < len(lines) and not re.fullmatch(r" {0,3}" + re.escape(mark[1][0]) + "{" + str(len(mark[1])) + r",}\s*", lines[i]):
                code.append(lines[i])
                i += 1
            blocks.append({"kind": "code", "text": "\n".join(code), "language": one_line(mark[2], 40)})
        elif not stripped or re.match(r"^ {0,3}\[[^\]]+\]:\s*.+$", line):
            flush()
        elif i + 1 < len(lines) and "|" in line and all(re.fullmatch(r":?-{3,}:?", c) for c in cells(lines[i + 1])):
            flush()
            start = i
            rows = [cells(line)]
            i += 2
            while i < len(lines) and "|" in lines[i] and lines[i].strip():
                rows.append(cells(lines[i]))
                i += 1
            if len(rows) > 128 or max(map(len, rows)) > 12:
                blocks.append({"kind": "code", "text": "\n".join(lines[start:i])})
            else:
                columns = len(rows[0])
                blocks.append({"kind": "table", "rows": [[inline(cell) for cell in (row + [""] * columns)[:columns]] for row in rows]})
            continue
        elif re.fullmatch(r" {0,3}(?:\*\s*){3,}| {0,3}(?:-\s*){3,}| {0,3}(?:_\s*){3,}", line) and not paragraph:
            flush()
            blocks.append({"kind": "rule"})
        elif i + 1 < len(lines) and re.fullmatch(r" {0,3}(?:=+|-+)\s*", lines[i + 1]) and stripped:
            flush()
            blocks.append({"kind": "heading", "level": 1 if "=" in lines[i + 1] else 2, "inlines": inline(stripped)})
            i += 1
        else:
            heading = re.match(r"^ {0,3}(#{1,6})\s+(.+?)(?:\s+#+)?$", line)
            listing = re.match(r"^(\s*)([-+*]|\d+[.)])\s+(.+)$", line)
            if heading:
                flush()
                blocks.append({"kind": "heading", "level": len(heading[1]), "inlines": inline(heading[2])})
            elif listing:
                flush()
                blocks.append({"kind": "list", "depth": min(8, len(listing[1].expandtabs(4)) // 2),
                               "marker": "•" if listing[2] in "-+*" else listing[2], "inlines": inline(listing[3])})
            elif stripped.startswith(">"):
                flush()
                blocks.append({"kind": "quote", "inlines": inline(stripped.lstrip("> "))})
            else:
                paragraph.append(stripped)
        i += 1
    flush()
    return blocks


def fetch_readme(item: dict[str, Any], timeout: float = 10) -> dict[str, Any]:
    commit = item.get("listingCommit", "")
    if not commit:
        return {"ok": False, "text": "", "content": "", "summary": "", "media": []}
    owner = urllib.parse.quote(item["owner"], safe="")
    repository = urllib.parse.quote(item["repoName"], safe="")
    url = f"https://raw.githubusercontent.com/{owner}/{repository}/{commit}/README.md"
    try:
        body = fetch_bytes(url, "raw.githubusercontent.com", MAX_README_BYTES, min(10, timeout))
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, ValueError):
        return {"ok": False, "text": "", "content": "", "summary": "", "media": []}
    source = body.decode("utf-8", errors="replace")
    content = markdown_content(source)
    return {
        "ok": True,
        "text": markdown_text(source),
        "content": content,
        "documentSource": readme_source(source),
        "documentVersion": README_DOCUMENT_VERSION,
        "summary": readme_summary(content, item.get("name", "")),
        "media": readme_media(source, item),
    }


def image_dimensions(data: bytes) -> tuple[str, int, int] | None:
    if data.startswith(b"\x89PNG\r\n\x1a\n") and len(data) >= 24:
        return "png", int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")
    if data[:6] in {b"GIF87a", b"GIF89a"} and len(data) >= 10:
        return "gif", int.from_bytes(data[6:8], "little"), int.from_bytes(data[8:10], "little")
    if data.startswith(b"\xff\xd8"):
        offset = 2
        while offset + 9 < len(data):
            if data[offset] != 0xFF:
                offset += 1
                continue
            marker = data[offset + 1]
            offset += 2
            if marker in {0xD8, 0xD9} or 0xD0 <= marker <= 0xD7:
                continue
            if offset + 2 > len(data):
                break
            length = int.from_bytes(data[offset:offset + 2], "big")
            if length < 2 or offset + length > len(data):
                break
            if marker in {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
                          0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF} and length >= 7:
                return (
                    "jpg",
                    int.from_bytes(data[offset + 5:offset + 7], "big"),
                    int.from_bytes(data[offset + 3:offset + 5], "big"),
                )
            offset += length
    if data.startswith(b"RIFF") and data[8:12] == b"WEBP" and len(data) >= 30:
        chunk = data[12:16]
        if chunk == b"VP8X":
            width = 1 + int.from_bytes(data[24:27], "little")
            height = 1 + int.from_bytes(data[27:30], "little")
            return "webp", width, height
        if chunk == b"VP8L" and len(data) >= 25 and data[20] == 0x2F:
            bits = int.from_bytes(data[21:25], "little")
            return "webp", (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
        frame = data.find(b"\x9d\x01\x2a", 20, 64)
        if frame >= 0 and frame + 7 <= len(data):
            width = int.from_bytes(data[frame + 3:frame + 5], "little") & 0x3FFF
            height = int.from_bytes(data[frame + 5:frame + 7], "little") & 0x3FFF
            return "webp", width, height
    return None


def fetch_preview_image(url: str, timeout: float = 10) -> tuple[bytes, str]:
    trusted = _trusted_cached_media_url(url, "image") or marketplace_image_url(url)
    if not trusted:
        raise ValueError("Preview image URL is not approved.")
    parsed = urllib.parse.urlsplit(trusted)
    host = (parsed.hostname or "").lower()
    request = urllib.request.Request(
        trusted,
        headers={"User-Agent": "Outfit/0.1", "Accept": "image/png,image/jpeg,image/webp,image/gif"},
    )
    opener = urllib.request.build_opener(RestrictedMediaRedirect(host))
    timeout = max(0.1, min(10, timeout))
    deadline = time.monotonic() + timeout
    with opener.open(request, timeout=timeout) as response:
        data = read_bounded_response(response, MAX_PREVIEW_IMAGE_BYTES, deadline)
    extension = validate_preview_image(data, thumbnail=host == "plugins.omarchy.org")
    return data, extension


def validate_preview_image(data: bytes, thumbnail: bool = False) -> str:
    if len(data) > MAX_PREVIEW_IMAGE_BYTES:
        raise ValueError("Preview image exceeds its size limit.")
    image = image_dimensions(data)
    if not image:
        raise ValueError("Preview media is not a supported image.")
    extension, width, height = image
    if width < (1 if thumbnail else 160) or height < (1 if thumbnail else 90) \
            or width > 5_000 or height > 5_000 \
            or width * height > MAX_PREVIEW_PIXELS:
        raise ValueError("Preview image dimensions are outside the supported range.")
    return extension


def prune_thumbnails(store: Store, protected: set[str]) -> None:
    files = []
    for name in os.listdir(store.fd):
        if THUMBNAIL_FILENAME.fullmatch(name):
            metadata = os.stat(name, dir_fd=store.fd, follow_symlinks=False)
            files.append((name, metadata.st_size, metadata.st_mtime))
    total = sum(size for _name, size, _mtime in files)
    count = len(files)
    for name, size, _mtime in sorted(files, key=lambda item: item[2]):
        if count <= MAX_THUMBNAIL_FILES and total <= MAX_THUMBNAIL_CACHE_BYTES:
            break
        if name in protected:
            continue
        os.unlink(name, dir_fd=store.fd)
        count -= 1
        total -= size


def thumbnail_readme_cache(store: Store) -> dict[str, Any]:
    try:
        raw = store.read("thumbnail-readmes.json", 2 * 1024 * 1024, {})
        if not isinstance(raw, dict) or raw.get("schema") != 1 or not isinstance(raw.get("entries"), dict):
            return {}
        output = {}
        for key, entry in list(raw["entries"].items())[:256]:
            if not re.fullmatch(r"[0-9a-f]{64}", key) or not isinstance(entry, dict):
                continue
            checked = entry.get("checkedAt")
            urls = entry.get("urls")
            if (type(checked) not in (float, int) or not math.isfinite(checked) or checked < 0
                    or type(entry.get("ok")) is not bool or not isinstance(urls, list)):
                continue
            output[key] = {"checkedAt": checked, "ok": entry["ok"],
                           "urls": [url for value in urls[:3]
                                    if (url := _trusted_cached_media_url(value, "image"))]}
        return output
    except (OSError, ValueError):
        return {}


def thumbnail_screenshots(media: Any, item: dict[str, Any]) -> list[str]:
    """Use the existing README media resolver, excluding decorative artwork."""
    images = []
    for entry in validate_readme_media(media):
        if entry["kind"] != "image":
            continue
        words = (entry["url"] + " " + entry["label"]).lower()
        if re.search(r"(?:^|[^a-z0-9])(?:badge|shield|logo|icon|banner|brand|mark|sponsor)(?:[^a-z0-9]|$)", words):
            continue
        resolved = _readme_media_url(entry["url"], item, "image")
        if resolved and resolved[0] == "image":
            images.append(resolved[1])
    return list(dict.fromkeys(images))[:3]


def thumbnail_failures(store: Store) -> dict[str, Any]:
    """Bounded URL/revision transport backoff, independent of README discovery."""
    try:
        raw = store.read("thumbnail-failures.json", 128 * 1024, {})
        if not isinstance(raw, dict) or raw.get("schema") != 1 or not isinstance(raw.get("entries"), dict):
            return {}
        return {key: entry for key, entry in list(raw["entries"].items())[:512]
                if isinstance(key, str) and re.fullmatch(r"[0-9a-f]{64}", key)
                and isinstance(entry, dict) and type(entry.get("failures")) is int
                and 1 <= entry["failures"] <= 10
                and type(entry.get("checkedAt")) in (int, float)
                and math.isfinite(entry["checkedAt"]) and 0 <= entry["checkedAt"] <= 253402300799}
    except (OSError, ValueError):
        return {}


def materialize_thumbnails(store: Store, items: list[dict[str, Any]], revision: str,
                           allow_readme: bool = False) -> dict[str, Any]:
    deadline = time.monotonic() + 32
    now = time.time()
    preview_generation = store.stamp("preview-generation.json")
    metadata = thumbnail_readme_cache(store) if allow_readme else {}
    metadata_updates: dict[str, Any] = {}
    failures = thumbnail_failures(store)
    failure_updates: dict[str, Any] = {}
    readmes = None
    readmes_lock = threading.Lock()
    # os.listdir(fd) duplicates a descriptor with a shared directory offset.
    # Concurrent worker enumerations can miss cached files; snapshot once.
    thumbnail_files = []
    for name in os.listdir(store.fd):
        if THUMBNAIL_FILENAME.fullmatch(name):
            try:
                thumbnail_files.append((name, os.stat(name, dir_fd=store.fd, follow_symlinks=False).st_mtime))
            except FileNotFoundError:
                pass
    thumbnail_files.sort(key=lambda entry: entry[1], reverse=True)

    def inspector_document(identity: str) -> dict[str, Any]:
        nonlocal readmes
        with readmes_lock:
            if readmes is None:
                try:
                    readmes = load_readmes(store)
                except (OSError, ValueError):
                    readmes = {}
            return readmes.get(identity, {})

    def image_file(url: str, image_revision: str) -> str:
        failure_key = hashlib.sha256(json.dumps([url, image_revision]).encode()).hexdigest()
        prefix = "thumb-" + hashlib.sha256(url.encode()).hexdigest()[:32] + "-"
        key = prefix + hashlib.sha256(image_revision.encode()).hexdigest()[:16]
        candidates = [name for name, _mtime in thumbnail_files if name.startswith(prefix)]
        fallback = ""
        for name in candidates:
            try:
                store.read_thumbnail(name)
                if name.startswith(key + "."):
                    os.utime(name, None, dir_fd=store.fd, follow_symlinks=False)
                    return (store.base / name).as_uri()
                fallback = fallback or (store.base / name).as_uri()
            except (OSError, ValueError):
                continue
        failure = failures.get(failure_key, {})
        if failure and 0 <= now - failure["checkedAt"] < min(86400, 300 * 2 ** (failure["failures"] - 1)):
            return fallback
        try:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return fallback
            data, extension = fetch_preview_image(url, timeout=remaining) if allow_readme else fetch_preview_image(url)
            local = store.write_blob(key + "." + extension, data, MAX_PREVIEW_IMAGE_BYTES)
            failure_updates[failure_key] = None
        except (OSError, ValueError, urllib.error.URLError):
            failure_updates[failure_key] = {"checkedAt": now, "failures": min(10, failure.get("failures", 0) + 1)}
            local = fallback
        return local

    def load(item: dict[str, Any]) -> tuple[str, dict[str, str]]:
        original = marketplace_image_url(item.get("previewThumbnail")) or marketplace_image_url(item.get("previewImage"))
        result = {"url": original, "localSource": "", "source": "", "state": "missing"}
        if original:
            local = image_file(original, revision)
            if local:
                return item["id"], {**result, "localSource": local, "source": "marketplace", "state": "ready"}
            result["state"] = "failed"
        document_key = readme_key(item)
        if not allow_readme or not document_key:
            return item["id"], result
        if time.monotonic() >= deadline:
            return item["id"], {**result, "state": "deferred"}
        cached = metadata.get(document_key)
        if cached and 0 <= now - cached["checkedAt"] < (86400 if cached["ok"] else 300):
            urls = cached["urls"]
            found = cached["ok"]
        else:
            document = inspector_document(item["id"])
            if (document.get("commit") == item.get("listingCommit")
                    and document.get("contentVersion") == README_CONTENT_VERSION
                    and document.get("media")):
                media, found = document["media"], True
            else:
                document = fetch_readme(item, timeout=max(0.1, min(10, deadline - time.monotonic())))
                media, found = document.get("media", []), document.get("ok") is True
            if not found and time.monotonic() >= deadline:
                return item["id"], {**result, "state": "deferred"}
            urls = thumbnail_screenshots(media, item)
            metadata_updates[document_key] = {"urls": urls, "ok": found, "checkedAt": now}
        for url in urls:
            # Revalidate persisted candidates against this repository/revision.
            resolved = _readme_media_url(url, item, "image")
            if not resolved or resolved[0] != "image":
                continue
            local = image_file(resolved[1], document_key)
            if local:
                return item["id"], {**result, "localSource": local, "source": "readme", "state": "ready",
                                     "repo": item["repo"], "listingCommit": item["listingCommit"]}
            if time.monotonic() >= deadline:
                return item["id"], {**result, "state": "deferred"}
        if not found or urls:
            result["state"] = "failed"
        return item["id"], result

    output = {}
    grouped: dict[str, list[dict[str, Any]]] = {}
    for item in items[:MAX_THUMBNAIL_BATCH]:
        url = marketplace_image_url(item.get("previewThumbnail")) or marketplace_image_url(item.get("previewImage"))
        # An empty marketplace URL must never combine unrelated repositories.
        group = url if url and not allow_readme else url + "|" + readme_key(item)
        grouped.setdefault(group, []).append(item)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        futures = {executor.submit(load, group[0]): group for group in grouped.values()}
        for future in concurrent.futures.as_completed(futures):
            try:
                _identity, result = future.result()
            except Exception:
                item = futures[future][0]
                result = {"url": marketplace_image_url(item.get("previewThumbnail")) or marketplace_image_url(item.get("previewImage")),
                          "localSource": "", "source": "", "state": "failed"}
            for item in futures[future]:
                output[item["id"]] = dict(result)
    if metadata_updates:
        with store.scoped_lock():
            if store.stamp("preview-generation.json") == preview_generation:
                entries = thumbnail_readme_cache(store)
                previous = dict(entries)
                for key, entry in metadata_updates.items():
                    if entries.get(key, {}).get("checkedAt", 0) <= entry["checkedAt"]:
                        entries[key] = entry
                retained = dict(sorted(entries.items(), key=lambda pair: pair[1]["checkedAt"], reverse=True)[:256])
                if retained != previous:
                    store.write("thumbnail-readmes.json", {"schema": 1, "entries": retained}, 2 * 1024 * 1024)
    if failure_updates:
        with store.scoped_lock():
            entries = thumbnail_failures(store)
            previous = dict(entries)
            for key, entry in failure_updates.items():
                if entries.get(key, {}).get("checkedAt", 0) > now:
                    continue
                if entry is None:
                    entries.pop(key, None)
                else:
                    entries[key] = entry
            entries = dict(sorted(entries.items(), key=lambda pair: pair[1]["checkedAt"], reverse=True)[:512])
            if entries != previous and store.stamp("preview-generation.json") == preview_generation:
                store.write("thumbnail-failures.json", {"schema": 1, "entries": entries}, 128 * 1024)
    protected = {Path(urllib.parse.urlsplit(item["localSource"]).path).name
                 for item in output.values() if item["localSource"]}
    prune_thumbnails(store, protected)
    return output


def materialize_readme_media(
    store: Store, values: Any,
) -> list[dict[str, str]]:
    media = [dict(item) for item in validate_readme_media(values)]
    targets: dict[int, str] = {}
    for index, item in enumerate(media):
        candidate = item["url"] if item["kind"] == "image" else item.get("poster", "")
        if candidate:
            targets[index] = candidate

    downloads: dict[int, tuple[bytes, str]] = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_README_MEDIA) as executor:
        futures = {
            executor.submit(fetch_preview_image, url): index for index, url in targets.items()
        }
        for future in concurrent.futures.as_completed(futures):
            try:
                downloads[futures[future]] = future.result()
            except Exception:
                pass

    for index in range(MAX_README_MEDIA):
        store.clear_preview_slot(index)
    generation = uuid.uuid4().hex[:12]
    for index, item in enumerate(media):
        item["localSource"] = ""
        if index not in downloads:
            continue
        data, extension = downloads[index]
        try:
            item["localSource"] = store.write_blob(
                f"preview-{index}-{generation}.{extension}", data, MAX_PREVIEW_IMAGE_BYTES,
            )
        except (OSError, ValueError):
            pass
    return media


def _terminate_process(process: subprocess.Popen[bytes]) -> None:
    # Do not poll/reap before signalling the process group: an exited leader may
    # still have descendants holding stdout open. Its unreaped PID pins identity.
    if process.returncode is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    # Keep the leader unreaped for the grace period, including when it exited
    # before its descendants. Reaping it first could both orphan descendants and
    # allow its numeric process-group identity to be reused before escalation.
    time.sleep(0.4)
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        pass


def _terminate_all(_signum: int | None = None, _frame: Any = None) -> None:
    for process in list(_children):
        _terminate_process(process)
    if _signum is not None:
        raise SystemExit(128 + _signum)


def _wait_command(process: subprocess.Popen[bytes], deadline: float) -> None:
    """Observe exit without reaping a failed group leader before cleanup.

    Descendants may close stdout and outlive a failed parent. WNOWAIT keeps its
    identity pinned so the exceptional path can safely signal the entire group.
    """
    while True:
        status = os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
        if status is not None:
            if status.si_code != os.CLD_EXITED or status.si_status != 0:
                raise ValueError("Probe was unavailable.")
            process.wait(timeout=max(0.01, deadline - time.monotonic()))
            return
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("Probe timed out.")
        time.sleep(min(0.01, remaining))


def command_launch(argv: list[str]) -> tuple[list[str], dict[str, str]]:
    """Resolve fixed native commands against the trusted session runtime.

    Call sites and audits retain their declared COMMANDS paths. Only this launch
    boundary substitutes the two native entry points; requests/catalog metadata
    cannot supply a runtime root, executable name, or inherited search path.
    """
    if (not isinstance(argv, (list, tuple)) or not argv or argv[0] not in COMMANDS.values()
            or any(not isinstance(argument, str) for argument in argv)):
        raise ValueError("Probe command is not allowlisted.")
    effective = list(argv)
    environment = {key: os.environ[key] for key in SAFE_ENV_KEYS if key in os.environ}
    environment["PATH"] = SYSTEM_COMMAND_PATH
    configured = environment.get("OMARCHY_PATH", "")
    if configured:
        if (len(configured) > MAX_RUNTIME_PATH_BYTES or ":" in configured
                or any(not character.isprintable() for character in configured)
                or len(os.fsencode(configured)) > MAX_RUNTIME_PATH_BYTES or not Path(configured).is_absolute()):
            raise ValueError("OMARCHY_PATH must be a bounded absolute runtime path without colons or control characters.")
        root = Path(configured)
        bindir = root / "bin"
        if not root.is_dir() or not bindir.is_dir():
            raise ValueError("The configured OMARCHY_PATH runtime or its bin directory is unavailable.")
        environment["PATH"] = str(bindir) + ":" + SYSTEM_COMMAND_PATH
        native_names = ("omarchy", "omarchy-shell")
        selected = next((name for name in native_names if argv[0] == COMMANDS[name]), None)
        if selected is not None:
            # An incomplete explicitly configured tree must not silently mix new
            # and packaged native entry points (or invoke old disruptive helpers).
            for name in native_names:
                executable = bindir / name
                try:
                    regular = stat.S_ISREG(executable.stat().st_mode)
                except OSError as error:
                    raise ValueError("The configured Omarchy runtime is missing a native entry point.") from error
                if not regular or not os.access(executable, os.X_OK):
                    raise ValueError("The configured Omarchy runtime has an unusable native entry point.")
            effective[0] = str(bindir / selected)
    else:
        environment.pop("OMARCHY_PATH", None)
    # Plugin rescans can exceed omarchy-shell's interactive two-second IPC limit.
    environment["OMARCHY_SHELL_IPC_TIMEOUT"] = "30s"
    if argv[:3] == [COMMANDS["omarchy"], "plugin", "update"]:
        # These settings also apply to Git subprocesses launched by the native
        # updater. Never invoke credential helpers, askpass, hooks or submodules.
        environment.update(GIT_TERMINAL_PROMPT="0", GIT_ASKPASS="/bin/false",
                           SSH_ASKPASS="/bin/false", GIT_CONFIG_NOSYSTEM="1",
                           GIT_CONFIG_GLOBAL="/dev/null")
        settings = {"credential.helper": "", "core.askPass": "/bin/false",
                    "core.hooksPath": "/dev/null", "core.fsmonitor": "false",
                    "protocol.allow": "never", "protocol.https.allow": "always",
                    "http.followRedirects": "false", "fetch.recurseSubmodules": "false",
                    "submodule.recurse": "false"}
        environment["GIT_CONFIG_COUNT"] = str(len(settings))
        for index, (key, value) in enumerate(settings.items()):
            environment[f"GIT_CONFIG_KEY_{index}"] = key
            environment[f"GIT_CONFIG_VALUE_{index}"] = value
    return effective, environment


def run_command(argv: list[str], timeout: float, maximum: int) -> bytes:
    effective, environment = command_launch(argv)
    return run_bounded_process(effective, environment, timeout, maximum)


def run_bounded_process(effective: list[str], environment: dict[str, str],
                        timeout: float, maximum: int, cwd: str | None = None) -> bytes:
    """Internal launch boundary; callers supply fixed commands and sanitized environments."""
    process = subprocess.Popen(
        effective,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        env=environment,
        start_new_session=True,
        cwd=cwd,
    )
    _children.add(process)
    chunks: list[bytes] = []
    total = 0
    deadline = time.monotonic() + timeout
    selector = None
    try:
        selector = selectors.DefaultSelector()
        assert process.stdout is not None
        selector.register(process.stdout, selectors.EVENT_READ)
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("Probe timed out.")
            events = selector.select(min(0.1, remaining))
            for key, _mask in events:
                chunk = os.read(key.fd, min(64 * 1024, maximum + 1 - total))
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                chunks.append(chunk)
                total += len(chunk)
                if total > maximum:
                    raise ValueError("Probe output exceeded its limit.")
        _wait_command(process, deadline)
        return b"".join(chunks)
    except BaseException as error:
        _terminate_process(process)
        if isinstance(error, subprocess.TimeoutExpired):
            raise TimeoutError("Probe timed out.") from None
        raise
    finally:
        try:
            if selector is not None:
                selector.close()
        finally:
            try:
                if process.stdout is not None:
                    process.stdout.close()
            finally:
                _children.discard(process)


def install_git_environment(home: Path, protocol: str) -> dict[str, str]:
    """No caller config, templates, hooks, filters, helpers or ambient credentials.

    HTTPS is used only to fetch the catalog commit. The native handoff permits
    only file transport, so it cannot silently refetch the moving remote HEAD.
    """
    environment = {"PATH": SYSTEM_COMMAND_PATH, "HOME": str(home), "XDG_CONFIG_HOME": str(home),
                   "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_SYSTEM": "/dev/null",
                   "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0",
                   "GIT_ASKPASS": "/bin/false", "SSH_ASKPASS": "/bin/false",
                   "GIT_NO_REPLACE_OBJECTS": "1", "GIT_ATTR_NOSYSTEM": "1"}
    settings = {"credential.helper": "", "core.askPass": "/bin/false",
                "core.hooksPath": "/dev/null", "core.fsmonitor": "false",
                "core.attributesFile": "/dev/null", "core.autocrlf": "false",
                "init.templateDir": "", "protocol.allow": "never",
                "protocol." + protocol + ".allow": "always", "http.followRedirects": "false",
                "http.sslVerify": "true", "http.extraHeader": "", "http.cookieFile": "",
                "http.saveCookies": "false", "fetch.recurseSubmodules": "false",
                "submodule.recurse": "false", "maintenance.auto": "false", "gc.auto": "0"}
    environment["GIT_CONFIG_COUNT"] = str(len(settings))
    for index, (key, value) in enumerate(settings.items()):
        environment[f"GIT_CONFIG_KEY_{index}"] = key
        environment[f"GIT_CONFIG_VALUE_{index}"] = value
    return environment


def install_git(path: Path, arguments: list[str], timeout: float = 5,
                maximum: int = 128 * 1024) -> bytes:
    return run_bounded_process([COMMANDS["git"], "-C", str(path), *arguments],
                               install_git_environment(path, "https"), timeout, maximum, cwd=str(path))


def verify_install_checkout(path: Path, identity: str, revision: str) -> None:
    if (path.is_symlink() or path.resolve() != path.absolute() or not path.is_dir()
            or (path / ".git").is_symlink() or not (path / ".git").is_dir()):
        raise ValueError("The reviewed installation is not an ordinary Git checkout.")
    if install_git(path, ["rev-parse", "--show-toplevel"]).decode().strip() != str(path):
        raise ValueError("The reviewed installation's Git worktree is not confirmed.")
    actual = install_git(path, ["rev-parse", "--verify", "HEAD^{commit}"], maximum=256).decode("ascii").strip()
    if actual != revision:
        raise ValueError("The installed checkout does not match the reviewed catalog commit.")
    if install_git(path, ["status", "--porcelain=v1", "--untracked-files=all", "--ignore-submodules=none"]):
        raise ValueError("The reviewed installation has unexpected local changes.")
    descriptor = os.open(path / "manifest.json", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        metadata = os.fstat(stream.fileno())
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > MAX_UPDATE_MANIFEST_BYTES:
            raise ValueError("The reviewed plugin manifest is unavailable.")
        update_manifest(stream.read(MAX_UPDATE_MANIFEST_BYTES + 1), identity)


def verify_reviewed_install(identity: str, revision: str, repository: str) -> None:
    target = plugin_install_path(identity)
    if target != Path.home() / ".config/omarchy/plugins" / identity:
        raise ValueError("The native installer does not support this plugin configuration directory.")
    verify_install_checkout(target, identity, revision)
    origin = install_git(target, ["config", "--get-all", "remote.origin.url"]).decode().strip()
    if origin != repository + ".git":
        raise ValueError("The reviewed installation's upstream origin is not confirmed.")


@contextmanager
def reviewed_repository(identity: str, repository: str, revision: str):
    """Private, verified snapshot shared by install, update and self-update."""
    parsed = github_repo(repository)
    if (not isinstance(revision, str) or not re.fullmatch(r"[0-9a-f]{40}", revision)
            or not parsed or parsed[2] != repository
            or any(part in {".", ".."} for part in parsed[:2])
            or not identity or plugin_id(identity) != identity):
        raise ValueError("The exact reviewed source and full commit SHA are required.")
    # Ignore TMPDIR: a caller-controlled location might itself be watched by the shell.
    with tempfile.TemporaryDirectory(prefix="outfit-reviewed-", dir="/tmp") as directory:
        stage = Path(directory)
        install_git(stage, ["init", "--template=", "-b", "outfit-reviewed"])
        install_git(stage, ["fetch", "--no-tags", "--no-recurse-submodules", "--",
                            repository + ".git", revision], timeout=45)
        fetched = install_git(stage, ["rev-parse", "--verify", "FETCH_HEAD^{commit}"], maximum=256).decode("ascii").strip()
        if fetched != revision:
            raise ValueError("The fetched commit does not match the reviewed catalog commit.")
        install_git(stage, ["checkout", "--detach", revision])
        verify_install_checkout(stage, identity, revision)
        run_command([COMMANDS["omarchy"], "plugin", "validate", str(stage)], 15, 32 * 1024)
        verify_install_checkout(stage, identity, revision)
        yield stage


def install_reviewed_plugin(item: dict[str, Any], revision: str) -> bytes:
    """Never install moving HEAD and reset it afterwards."""
    identity, repository = item.get("id"), item.get("repo")
    if not revision or revision != item.get("listingCommit"):
        raise ValueError("Installation requires the exact reviewed catalog source and full commit SHA.")
    target = plugin_install_path(identity)
    if (target != Path.home() / ".config/omarchy/plugins" / identity
            or target.parent.resolve() != target.parent.absolute()):
        raise ValueError("The native installer does not support this plugin configuration directory.")
    if os.path.lexists(target):
        raise ValueError("The selected plugin is already installed.")
    with reviewed_repository(identity, repository, revision) as stage:
        # Keep Git hardening in the environment for the native installer's children.
        # Only our generated absolute path is handed off; request URLs/paths never are.
        argv, environment = command_launch([COMMANDS["omarchy"], "plugin", "add", str(stage), "--yes"])
        safe_git = install_git_environment(stage, "file")
        environment.update({key: value for key, value in safe_git.items()
                            if key.startswith("GIT_") or key == "SSH_ASKPASS"})
        output = b""
        native_error = None
        try:
            output = run_bounded_process(argv, environment, 60, 128 * 1024, cwd=str(stage))
        except (OSError, TimeoutError, ValueError) as error:
            native_error = error
        # Native IPC may time out after the clone has committed. Finalize only an
        # exact, clean result whose origin is still our private staging repository.
        verify_install_checkout(target, identity, revision)
        origin = install_git(target, ["config", "--get-all", "remote.origin.url"]).decode().strip()
        if origin != str(stage):
            raise ValueError("The native installation source could not be confirmed.")
        install_git(target, ["remote", "set-url", "origin", repository + ".git"])
        verify_reviewed_install(identity, revision, repository)
        if native_error is not None:
            raise ValueError("The reviewed commit was installed, but native completion needs verification.") from native_error
        return output


def update_reviewed_plugin(item: dict[str, Any], local: dict[str, Any],
                           expected: str, version: str) -> bytes:
    """Give the native updater an immutable, prevalidated local origin for this process only.

    No installed config rewrite or post-execution reset: fetch origin HEAD can
    reach only the staged reviewed commit. This also serves the detached worker.
    Callers own the mutation lock and final inventory/revision reconciliation.
    """
    item, local = dict(item), dict(local)
    identity, repository = item["id"], local["repository"]
    before = full_sha(local.get("installedRevision"))
    if not before or before != local.get("installedRevision") or not local.get("sourceKey"):
        raise ValueError("The reviewed installed source is unavailable.")
    target = plugin_install_path(identity)
    if target != Path.home() / ".config/omarchy/plugins" / identity:
        raise ValueError("The native updater does not support this plugin configuration directory.")
    with reviewed_repository(identity, repository, expected) as stage:
        manifest = update_manifest(install_git(stage, ["show", f"{expected}:manifest.json"],
                                               maximum=MAX_UPDATE_MANIFEST_BYTES), identity)
        if manifest["version"] != version:
            raise ValueError("The staged manifest differs from the reviewed update.")
        # The fetched history, rather than only remote compare metadata, must
        # prove that this is a fast-forward from the approved installed commit.
        install_git(stage, ["merge-base", "--is-ancestor", before, expected])
        inventory, unavailable = scan_inventory(include_versions=False)
        current_item = next((row for row in inventory if row["id"] == identity), None)
        if (unavailable or not current_item or current_item.get("firstParty")
                or current_item.get("enabled") != item.get("enabled")
                or current_item.get("barSectionKnown") is not True
                or current_item.get("barSection") != item.get("barSection")):
            raise ValueError("Plugin state changed while preparing the reviewed update.")
        current = inspect_update_target(current_item)
        if (current["state"] != "ready" or current["sourceKey"] != local["sourceKey"]
                or current["repository"] != repository or current["installedRevision"] != before):
            raise ValueError("The installed source changed while preparing the reviewed update.")
        origin = update_git(target, ["config", "--get-all", "remote.origin.url"]).decode().strip()
        argv, environment = command_launch([COMMANDS["omarchy"], "plugin", "update", identity, "--yes"])
        safe_git = install_git_environment(stage, "file")
        # remote.origin.url is multi-valued in Git: appending a command-scope URL
        # does NOT safely replace its first local value. Use an exact, verified
        # process-only insteadOf mapping, with every network transport denied.
        index = int(safe_git["GIT_CONFIG_COUNT"])
        safe_git.update(GIT_CONFIG_COUNT=str(index + 1))
        safe_git[f"GIT_CONFIG_KEY_{index}"] = f"url.{stage}.insteadOf"
        safe_git[f"GIT_CONFIG_VALUE_{index}"] = origin
        environment.update({key: value for key, value in safe_git.items()
                            if key.startswith("GIT_") or key == "SSH_ASKPASS"})
        resolved = run_bounded_process([COMMANDS["git"], "-C", str(target), "remote", "get-url", "--all", "origin"],
                                       environment, 5, 4096, cwd=str(stage)).decode().strip()
        if resolved != str(stage):
            raise ValueError("The native updater could not be bound to the reviewed local source.")
        return run_bounded_process(argv, environment, 90, 128 * 1024, cwd=str(stage))


def run_activation_command(argv: list[str], observed: dict[str, Any] | None = None) -> bytes:
    identity = argv[3]
    desired = {"barSection": argv[4]} if len(argv) == 5 else {}
    if observed is not None and mutation_observed("enable-plugin", desired, identity, [observed]):
        return b""
    last_error: OSError | TimeoutError | ValueError | None = None
    for delay in (1.0, 2.0, None):
        try:
            return run_command(argv, 35, 32 * 1024)
        except (OSError, TimeoutError, ValueError) as command_error:
            last_error = command_error
            inventory, unavailable = scan_inventory(include_versions=False)
            if not unavailable and mutation_observed("enable-plugin", desired, identity, inventory):
                return b""
            target = next((item for item in inventory if item["id"] == identity), None)
            if unavailable or (desired and target is not None and target.get("barSectionKnown") is not True):
                # A timeout can mean the command committed successfully. Never
                # repeat placement until authoritative inventory says it is needed.
                raise command_error
            if delay is not None:
                time.sleep(delay)
    assert last_error is not None
    raise last_error


def valid_host_token(value: Any) -> bool:
    # Opaque IPC argument: preserve it exactly, never normalize or interpolate it.
    return (isinstance(value, str) and 0 < len(value) <= MAX_HOST_TOKEN
            and not value.startswith("-") and all(char.isprintable() and not char.isspace() for char in value))


def host_status_document(raw: dict[str, Any]) -> dict[str, Any]:
    """Keep native lifecycle/error evidence; never infer rendering or readiness."""
    numbers = ("generation", "settledGeneration", "leaseCount")
    flags = ("scanning", "reconciling", "pending", "held")
    if (any(type(raw.get(key)) is not int or raw[key] < 0 for key in numbers)
            or any(type(raw.get(key)) is not bool for key in flags)
            or not isinstance(raw.get("scanError"), str)
            or not isinstance(raw.get("plugins"), dict) or len(raw["plugins"]) > 2048):
        raise ValueError("Invalid native lifecycle status.")
    output = {key: raw[key] for key in ("version",) + numbers + flags}
    output["scanError"] = clean(raw["scanError"], 4096)
    plugins = {}
    for identity, value in raw["plugins"].items():
        if (not plugin_id(identity) or plugin_id(identity) != identity or not isinstance(value, dict)
                or not isinstance(value.get("revision"), str) or len(value["revision"]) > 128
                or type(value.get("enabled")) is not bool or type(value.get("restartRequired")) is not bool
                or not isinstance(value.get("loadErrors"), dict) or len(value["loadErrors"]) > 16
                or any(not isinstance(key, str) or len(key) > 64 or not isinstance(error, str)
                       for key, error in value["loadErrors"].items())):
            raise ValueError("Invalid native plugin lifecycle state.")
        plugin = {"revision": value["revision"], "enabled": value["enabled"],
                  "restartRequired": value["restartRequired"],
                  "loadErrors": {one_line(key, 64): clean(error, 4096) for key, error in value["loadErrors"].items()}}
        # Optional native renderer extensions are evidence only. Their absence
        # never becomes ready=true, and they never alter settledGeneration.
        for key in ("rendererInfo", "renderers"):
            if key in value:
                extension = value[key]
                if not isinstance(extension, (dict, list)) or len(json.dumps(extension, allow_nan=False)) > 16 * 1024:
                    raise ValueError("Invalid native renderer information.")
                plugin[key] = extension
        plugins[identity] = plugin
    output["plugins"] = plugins
    return output


def native_host_lifecycle(method: str, args: list[str], status: bool = False) -> dict[str, Any]:
    maximum = MAX_HOST_STATUS_BYTES if status else 16 * 1024
    raw = run_command([COMMANDS["omarchy-shell"], "shell", method, *args], HOST_IPC_TIMEOUT, maximum)
    if len(raw) > maximum:
        raise ValueError("Native lifecycle response exceeded its limit.")
    document = safe_json_loads(raw, "Native plugin lifecycle")
    if not isinstance(document, dict) or type(document.get("version")) is not int or document["version"] != 1:
        raise ValueError("Native lifecycle API is unavailable or incompatible.")
    if status:
        return host_status_document(document)
    if type(document.get("ok")) is not bool:
        raise ValueError("Native lifecycle acknowledgement is invalid.")
    result = {"version": 1, "ok": document["ok"]}
    if not result["ok"]:
        if not isinstance(document.get("error"), str) or not document["error"]:
            raise ValueError("Native lifecycle rejection is invalid.")
        result["error"] = one_line(document["error"], 300)
    for key in ("generation", "expiresAt", "deadline"):
        if key in document:
            if type(document[key]) is not int or document[key] < 0:
                raise ValueError("Native lifecycle acknowledgement is invalid.")
            result[key] = document[key]
    if result["ok"]:
        required = ("generation",) if method == "endPluginChanges" else ("expiresAt", "deadline")
        if any(key not in result for key in required):
            raise ValueError("Native lifecycle acknowledgement is incomplete.")
        if method != "endPluginChanges" and result["expiresAt"] > result["deadline"]:
            raise ValueError("Native lifecycle lease exceeds its absolute deadline.")
        if method == "beginPluginChanges":
            if not valid_host_token(document.get("token")) or "generation" not in result:
                raise ValueError("Native lifecycle lease is invalid.")
            result["token"] = document["token"]
    return result


def host_lifecycle(request: dict[str, Any], generation: int) -> dict[str, Any]:
    operation = request.get("operation")
    if operation not in ("status", "begin", "renew", "end"):
        raise ValueError("Choose host lifecycle operation status, begin, renew, or end.")
    token = request.get("token", "")
    if token != "" and not valid_host_token(token):
        raise ValueError("Host lifecycle token must be a bounded printable token.")
    if operation in ("renew", "end") and not valid_host_token(token):
        raise ValueError("Host lifecycle renewal/end requires a valid token.")
    lease = request.get("leaseMs", HOST_LEASE_DEFAULT_MS)
    if type(lease) is not int or not 250 <= lease <= HOST_LEASE_MAX_MS:
        raise ValueError("Host lifecycle leaseMs must be an integer from 250 to 15000 milliseconds.")
    methods = {"status": "pluginLifecycle", "begin": "beginPluginChanges",
               "renew": "renewPluginChanges", "end": "endPluginChanges"}
    args = ([str(lease)] if operation == "begin" else [token, str(lease)] if operation == "renew"
            else [token] if operation == "end" else [])
    try:
        host = {**native_host_lifecycle(methods[operation], args, status=operation == "status"), "supported": True}
    except (OSError, TimeoutError, subprocess.TimeoutExpired, ValueError, RecursionError):
        # Do not reflect subprocess output, tokens, exception text or environment.
        host = {"supported": False, "reason": "Native plugin lifecycle API unavailable or incompatible; ordinary plugin commands remain available."}
    if operation == "end" and host["supported"]:
        try:
            snapshot = native_host_lifecycle("pluginLifecycle", [], status=True)
            # Preserve the end acknowledgement's generation and ok, including a
            # rejected/expired end. This is a snapshot, not a readiness barrier.
            host.update({key: value for key, value in snapshot.items() if key not in {"generation", "version"}})
            host.update(statusGeneration=snapshot["generation"], statusAvailable=True)
        except (OSError, TimeoutError, subprocess.TimeoutExpired, ValueError, RecursionError):
            host.update(statusAvailable=False, statusReason="Lifecycle snapshot unavailable; poll status to check the resulting state.")
    return {"ok": True, "action": "host-lifecycle", "generation": generation, "host": host}


def open_plugin(request: dict[str, Any], generation: int) -> dict[str, Any]:
    """One standard-window summon, using fresh native capability evidence only."""
    identity = request.get("pluginId")
    if not isinstance(identity, str) or not plugin_id(identity) or plugin_id(identity) != identity:
        raise ValueError("Opening a plugin requires a valid plugin ID.")

    def result(state: str, error: str = "") -> dict[str, Any]:
        return {"ok": state == "accepted", "action": "open-plugin", "generation": generation,
                "pluginId": identity, "openState": state, "error": error}

    if identity in {APP_ID, LEGACY_APP_ID}:
        return result("unavailable", "Outfit cannot open itself from plugin details.")
    try:
        # Do not use the display normalizer or filesystem fallback: either can
        # lose evidence about malformed/unknown canonical capabilities. Bar
        # placement and cached listing flags do not establish window eligibility.
        inventory = safe_json_loads(run_command(
            [COMMANDS["omarchy"], "plugin", "list", "--json"], 5, 2 * 1024 * 1024,
        ), "Plugin inventory")
        if not isinstance(inventory, list) or len(inventory) > MAX_INVENTORY_ROWS:
            raise ValueError("Invalid inventory.")
        seen: set[str] = set()
        target = None
        for entry in inventory:
            if not isinstance(entry, dict):
                raise ValueError("Invalid inventory entry.")
            entry_id = entry.get("id")
            if (not isinstance(entry_id, str) or not plugin_id(entry_id)
                    or plugin_id(entry_id) != entry_id or entry_id in seen):
                raise ValueError("Invalid inventory identity.")
            seen.add(entry_id)
            if entry_id == identity:
                target = entry
    except (OSError, TimeoutError, subprocess.TimeoutExpired, ValueError, RecursionError):
        return result("unavailable", "Open is unavailable because authoritative plugin inventory could not be verified.")
    if target is None:
        return result("unavailable", "The selected plugin is no longer installed.")
    kinds = target.get("kinds")
    if (not isinstance(kinds, list) or not kinds or len(kinds) > 8
            or any(not isinstance(kind, str) or kind not in OPEN_KNOWN_KINDS for kind in kinds)
            or type(target.get("enabled")) is not bool):
        return result("unavailable", "Open is unavailable because this plugin's native capabilities are not confirmed.")
    if not OPEN_WINDOW_KINDS.intersection(kinds):
        return result("unavailable", "This plugin has no standard panel, overlay, or menu to open.")
    if target["enabled"] is not True:
        return result("unavailable", "Open requires Omarchy to confirm that this plugin is enabled.")
    try:
        # The host owns lifecycle/focus. Never accept a caller's payload, command,
        # route or executable, and never retry a possibly delivered summon.
        reply = run_command([COMMANDS["omarchy-shell"], "shell", "summon", identity, "{}"],
                            HOST_IPC_TIMEOUT, MAX_OPEN_REPLY_BYTES)
    except (TimeoutError, subprocess.TimeoutExpired):
        return result("unconfirmed", "Open was not confirmed before the timeout. The request may have reached Omarchy; it was not retried.")
    except (OSError, ValueError):
        return result("unavailable", "Omarchy's native Open command is unavailable or did not acknowledge the request.")
    if reply.strip() == b"ok":
        # Accepted is not proof of rendering; do not report 'opened' or restore
        # Outfit over the summoned surface.
        return result("accepted")
    return result("unavailable", "Omarchy did not accept the Open request; the native window may be unavailable.")


def _read_small(path: Path, maximum: int = 256) -> str:
    try:
        with path.open("rb") as stream:
            return one_line(stream.read(maximum + 1).decode("utf-8", errors="replace"), maximum)
    except OSError:
        return ""


def _tokens(*values: str) -> list[str]:
    output: list[str] = []
    for value in values:
        for token in re.findall(r"[a-z0-9][a-z0-9+.-]{1,30}", normalized(value)):
            if token not in STOP_WORDS and token not in output:
                output.append(token)
    return output[:16]


def _signal(
    identity: str,
    label: str,
    terms: dict[str, int],
    detail: str = "",
    source: str = "hardware",
) -> dict[str, Any]:
    probe, domain, method = signal_metadata(identity)
    return {
        "id": identity,
        "label": one_line(label, 80),
        "detail": one_line(detail, 140),
        "source": source if source in {"hardware", "workflow", "software"} else "hardware",
        "probeId": probe, "domain": domain, "method": method,
        "stale": False,
        "terms": [
            {"value": one_line(term, 50), "weight": max(1, min(30, int(weight)))}
            for term, weight in terms.items()
            if one_line(term, 50)
        ][:16],
    }


def _known_bluetooth(name: str, info: str = "") -> dict[str, Any]:
    text = normalized(name + " " + info)
    mappings = (
        ("airpods", "AirPods", {"airpods": 30, "apple headphones": 18, "bluetooth codec": 8}),
        ("galaxy buds", "Galaxy Buds", {"galaxy buds": 30, "samsung buds": 22, "bluetooth codec": 8}),
        ("momentum", "Sennheiser Momentum", {"momentum": 28, "sennheiser": 22, "bluetooth codec": 8}),
        ("wh-1000", "Sony WH-1000X", {"wh-1000": 28, "sony headphones": 20, "bluetooth codec": 8}),
        ("wf-1000", "Sony WF-1000X", {"wf-1000": 28, "sony earbuds": 20, "bluetooth codec": 8}),
        ("pixel buds", "Pixel Buds", {"pixel buds": 28, "google earbuds": 18, "bluetooth codec": 8}),
        ("bose", "Bose audio", {"bose": 24, "bluetooth codec": 8}),
        ("beats", "Beats audio", {"beats": 24, "bluetooth codec": 8}),
        ("dualsense", "DualSense controller", {"dualsense": 30, "playstation controller": 20, "gamepad": 8}),
    )
    for needle, label, terms in mappings:
        if needle in text:
            return _signal(f"bluetooth-{needle.replace(' ', '-')}", label, terms, "Connected over Bluetooth")
    audio_words = (
        "headphone", "headset", "earbud", "speaker", "audio-head", "audio-card",
        "audio sink", "handsfree", "0000110b", "0000111e", "0000111f",
    )
    if any(word in text for word in audio_words):
        return _signal(
            "bluetooth-headphones",
            one_line(name, 60) or "Bluetooth headphones",
            {"bluetooth headphones": 24, "headset": 18, "bluetooth audio": 16, "bluetooth codec": 12},
            "Connected Bluetooth audio device",
        )
    return {}


def density_name(value: Any) -> str:
    return value if value in ("comfortable", "compact", "dense", "list") else "comfortable"


def validate_preferences(value: Any) -> dict[str, Any]:
    raw = value if isinstance(value, dict) else {}
    goals = raw.get("goals") if isinstance(raw.get("goals"), list) else []
    software = raw.get("software") if isinstance(raw.get("software"), list) else []
    services = raw.get("services") if isinstance(raw.get("services"), list) else []
    not_fit = raw.get("notFit") if isinstance(raw.get("notFit"), list) else []
    known_services = {item["id"] for item in load_service_registry()}
    return {
        "schema": PREFERENCES_SCHEMA,
        "goals": list(dict.fromkeys(
            one_line(item, 40) for item in goals[:16]
            if one_line(item, 40) in WORKFLOW_GOALS
        )),
        "software": list(dict.fromkeys(
            one_line(item, 40) for item in software[:16]
            if one_line(item, 40) in SOFTWARE_CHOICES
        )),
        "services": list(dict.fromkeys(
            identity for item in services[:MAX_SERVICE_CHOICES]
            if (identity := service_id(item)) in known_services
        )),
        "servicesOnboardingComplete": raw.get("servicesOnboardingComplete") is True,
        "notes": one_line(raw.get("notes"), 500),
        "watchHardware": raw.get("watchHardware") is not False,
        "readmeEnrichment": raw.get("readmeEnrichment") is not False,
        "readmeIndexing": raw.get("readmeIndexing") is not False,
        "marketplaceThumbnails": raw.get("marketplaceThumbnails") is not False,
        "browseDensity": density_name(raw.get("browseDensity")),
        "notFit": list(dict.fromkeys(
            identity for item in not_fit[:MAX_FEEDBACK_ROWS]
            if (identity := plugin_id(item))
        )),
    }


def load_preferences(store: Store) -> dict[str, Any]:
    raw = store.read_state("preferences.json", MAX_PREFERENCES_BYTES, DEFAULT_PREFERENCES)
    if not isinstance(raw, dict) or raw.get("schema") != PREFERENCES_SCHEMA:
        raise ValueError("Outfit preferences are invalid; reset or save them to rebuild.")
    preferences = validate_preferences(raw)
    interests = store.read_state("interests.json", MAX_INTEREST_STATE, None)
    if isinstance(interests, dict) and interests.get("schema") == INTEREST_SCHEMA:
        if not isinstance(interests.get("criteria"), list):
            raise ValueError("Saved interests are invalid; existing state was preserved.")
        preferences["services"] = [item["serviceId"] for item in interests.get("criteria", [])
                                   if isinstance(item, dict) and item.get("enabled") and item.get("serviceId")]
    return preferences


def save_preferences(store: Store, preferences: dict[str, Any]) -> None:
    with store.scoped_lock():
        latest = store.read("preferences.json", MAX_PREFERENCES_BYTES, DEFAULT_PREFERENCES)
        if not isinstance(latest, dict) or latest.get("schema") != PREFERENCES_SCHEMA:
            raise ValueError("Unsupported preferences schema; existing settings were preserved.")
        store.write("preferences.json", {**latest, **preferences}, MAX_PREFERENCES_BYTES)


def criterion_id(value: Any) -> str:
    return value if isinstance(value, str) and re.fullmatch(r"(?:service\.[a-z0-9-]{1,64}|interest\.[0-9a-f]{32})", value) else ""


def validate_criterion(raw: Any, existing: set[str] | None = None) -> dict[str, Any]:
    if not isinstance(raw, dict) or raw.get("kind") not in ("hardware", "service", "topic"):
        raise ValueError("An interest must have kind hardware, service, or topic.")
    identity = raw.get("id", "")
    if not isinstance(identity, str):
        raise ValueError("Interest IDs must be strings; use an empty ID for a new interest.")
    if identity and (not criterion_id(identity) or (existing is not None and identity not in existing)):
        # New curated choices have a stable, public identity.
        if not (identity == "service." + str(raw.get("serviceId", "")) and
                raw.get("serviceId") in {item["id"] for item in load_service_registry()}):
            raise ValueError("Unknown interest ID; use an empty ID for a new interest.")
    label = raw.get("label", "")
    terms = raw.get("terms", [])
    if not isinstance(label, str) or len(label) > 80 or not isinstance(terms, list) or len(terms) > 4:
        raise ValueError("Use a label of at most 80 characters and at most four literal phrases.")
    if any(not isinstance(term, str) or not term.strip() or len(term) > 64 for term in terms):
        raise ValueError("Each literal phrase must contain 1–64 characters.")
    if "enabled" in raw and type(raw["enabled"]) is not bool:
        raise ValueError("Interest enabled must be a boolean.")
    service = raw.get("serviceId", "")
    feature = raw.get("featureId", "")
    if not isinstance(service, str) or not isinstance(feature, str):
        raise ValueError("Service and feature IDs must be strings.")
    if service and feature:
        raise ValueError("Choose one curated service or hardware feature.")
    if service:
        choice = next((item for item in load_service_registry() if item["id"] == service), None)
        if choice is None or raw["kind"] != "service":
            raise ValueError("Unknown curated service.")
        if identity and identity != "service." + service:
            raise ValueError("Curated service ID does not match its service.")
        identity, label, terms = "service." + service, choice["name"], choice["terms"][:4]
    elif feature:
        if not isinstance(feature, str) or feature not in FEATURES or raw["kind"] != "hardware":
            raise ValueError("Unknown hardware feature.")
        label, terms = FEATURES[feature]
    elif identity and identity.startswith("service."):
        raise ValueError("Curated service IDs require a serviceId.")
    label = one_line(label, 80)
    terms = list(dict.fromkeys(normalized(term) for term in terms))
    if any(not term or len(term) > 64 for term in terms):
        raise ValueError("Each normalized literal phrase must contain 1–64 characters.")
    if not label or (not terms and not service):
        raise ValueError("Give the interest a label and at least one literal phrase.")
    return {"id": identity or "interest." + uuid.uuid4().hex, "kind": raw["kind"],
            "label": label, "terms": terms, "serviceId": service, "featureId": feature,
            "enabled": raw.get("enabled") is not False, "origin": "user"}


def validate_interest_document(raw: Any) -> dict[str, Any]:
    if (not isinstance(raw, dict) or raw.get("schema") != INTEREST_SCHEMA
            or type(raw.get("revision")) is not int or raw["revision"] < 0
            or not isinstance(raw.get("criteria"), list) or len(raw["criteria"]) > MAX_INTERESTS
            or not isinstance(raw.get("ignoredSignals"), list)):
        raise ValueError("Unsupported or invalid interests schema; saved interests were preserved.")
    criteria = []
    for item in raw["criteria"]:
        # Empty IDs are for explicit new drafts only, never a reason to silently
        # regenerate persisted identities without advancing the revision.
        if not isinstance(item, dict) or not criterion_id(item.get("id")) or type(item.get("enabled")) is not bool:
            raise ValueError("Invalid saved interest identity or enabled state; existing data was preserved.")
        criteria.append({**item, **validate_criterion(item)})
    known = set(FEATURES) | {"dock-like"} | {"capability-" + key for key in CAPABILITIES}
    if (len({item["id"] for item in criteria}) != len(criteria) or len(raw["ignoredSignals"]) > 64
            or any(not isinstance(value, str) or value not in known for value in raw["ignoredSignals"])):
        raise ValueError("Invalid interest identities; saved interests were preserved.")
    validate_review(raw.get("review", {}))
    return {**raw, "criteria": criteria}


def load_interests(store: Store, preferences: dict[str, Any]) -> dict[str, Any]:
    """Only active curated services migrate. Legacy personalization stays inert."""
    stamp = store.stamp("interests.json")
    cached = store.memory.get("validatedInterests")
    if stamp is not None and cached is not None and cached[0] == stamp:
        return cached[1]
    raw = store.read_state("interests.json", MAX_INTEREST_STATE, None)
    if raw is not None:
        document = validate_interest_document(raw)
        if stamp is not None and store.stamp("interests.json") == stamp:
            store.memory["validatedInterests"] = (stamp, document)
        return document
    with store.scoped_lock():
        # Migration is a writer: recheck under the lock, without a stale snapshot.
        raw = store.read("interests.json", MAX_INTEREST_STATE, None)
        if raw is not None:
            return validate_interest_document(raw)
        latest = store.read("preferences.json", MAX_PREFERENCES_BYTES, preferences)
        if not isinstance(latest, dict) or latest.get("schema") != PREFERENCES_SCHEMA:
            raise ValueError("Unsupported preferences schema; interests were not migrated.")
        criteria = [validate_criterion({"kind": "service", "serviceId": identity})
                    for identity in validate_preferences(latest).get("services", [])]
        result = {"schema": INTEREST_SCHEMA, "revision": 1 if criteria else 0,
                  "criteria": criteria, "ignoredSignals": [], "review": {}}
        if criteria:
            store.write("interests.json", result, MAX_INTEREST_STATE)
        return result


def supplied_scan(request: dict[str, Any], fallback: Any = None, previous: bool = False) -> dict[str, Any]:
    names = ("previousScan", "scan") if previous else ("scan", "previousScan")
    candidates = [request.get(name) for name in names] + [fallback]
    # An empty placeholder or null must not hide an accepted detailed scan.
    for value in candidates:
        if isinstance(value, dict) and isinstance(value.get("observations"), list):
            return value
    return next((value for value in candidates if isinstance(value, dict) and value), {})


def context_inputs(document: dict[str, Any], request: dict[str, Any]) -> dict[str, Any]:
    scan = supplied_scan(request)
    profile = detected_profile(request.get("profile", scan.get("observations", [])))
    ignored = set(document["ignoredSignals"])
    detected = [{"id": item["id"], "label": item["label"], "detail": item["detail"],
                 "domain": item["domain"], "method": item["method"], "probeId": item["probeId"],
                  "freshness": "stale" if item["stale"] else "current", "stale": item["stale"],
                 "checkedAt": item["checkedAt"],
                 "terms": [term["value"] for term in item["terms"]], "enabled": item["id"] not in ignored,
                 "origin": "detected"} for item in profile]
    probes = []
    for probe in (scan.get("probes") or [])[:len(PROBE_IDS)] if isinstance(scan.get("probes", []), list) else []:
        if isinstance(probe, dict) and probe.get("id") in PROBE_IDS:
            state = probe.get("state") if probe.get("state") in (
                "success", "partial", "failed", "unavailable", "stale") else "unavailable"
            probes.append({"id": probe["id"], "state": state, "reason": one_line(probe.get("reason"), 160),
                           **({"checkState": probe["checkState"]} if probe.get("checkState") in
                              ("success", "partial", "failed", "unavailable") else {})})
    if not probes:
        unavailable = request.get("unavailable") if isinstance(request.get("unavailable"), list) else []
        probes = [{"id": identity, "state": "unavailable" if identity in unavailable else
                   "success" if request.get("hasAnalyzed") else "unavailable", "reason": ""}
                  for identity in PROBE_IDS]
    checked = scan.get("checkedAt", 0)
    checked = checked if type(checked) in (int, float) and math.isfinite(checked) and checked >= 0 else 0
    scan_state = scan.get("state")
    if scan_state not in ("success", "partial", "failed", "unavailable", "stale"):
        scan_state = "partial" if request.get("unavailable") else "success" if request.get("hasAnalyzed") else "unavailable"
    return {"revision": document["revision"],
            "criteria": [{**item, "terms": list(item["terms"])} for item in document["criteria"]],
            "ignoredSignals": list(document["ignoredSignals"]), "detected": detected, "probes": probes,
            "scanState": scan_state, "checkedAt": checked,
            "featureChoices": [{"id": key, "label": value[0], "terms": value[1]} for key, value in FEATURES.items()],
            "serviceChoices": [{key: item[key] for key in ("id", "name", "category")} for item in load_service_registry()]}


def profile_changes(previous: list[dict[str, Any]], current: list[dict[str, Any]]) -> dict[str, list[str]]:
    before = {
        item["id"]: item["label"]
        for item in previous
        if item.get("source", "hardware") == "hardware"
    }
    after = {
        item["id"]: item["label"]
        for item in current
        if item.get("source", "hardware") == "hardware"
    }
    changed = {identity for identity in before.keys() & after.keys() if before[identity] != after[identity]}
    return {
        "added": [after[identity] for identity in sorted((after.keys() - before.keys()) | changed)][:16],
        "removed": [before[identity] for identity in sorted((before.keys() - after.keys()) | changed)][:16],
    }


def validate_inventory(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list):
        return []
    output: list[dict[str, Any]] = []
    seen: set[str] = set()
    for raw in value[:MAX_INVENTORY_ROWS]:
        if not isinstance(raw, dict):
            continue
        identity = plugin_id(raw.get("id"))
        if not identity or identity in seen:
            continue
        seen.add(identity)
        kinds = raw.get("kinds") if isinstance(raw.get("kinds"), list) else []
        output.append({
            "id": identity,
            "name": one_line(raw.get("name"), 120) or identity,
            "kinds": list(dict.fromkeys(one_line(kind, 40) for kind in kinds[:8] if one_line(kind, 40))),
            "enabled": raw.get("enabled") is True,
            "active": raw.get("active") is True,
            "canDisable": raw.get("canDisable") is True,
            "firstParty": raw.get("firstParty") is True,
            "installedVersion": one_line(raw.get("installedVersion", raw.get("version")), 64),
            "installedRevision": full_sha(raw.get("installedRevision")),
            "barSection": raw.get("barSection")
                if raw.get("barSection") in {"left", "center", "right"} else "",
            "barSectionKnown": raw.get("barSectionKnown") is not False,
        })
    return output


def merge_inventory(items: list[dict[str, Any]], inventory: list[dict[str, Any]]) -> list[dict[str, Any]]:
    local = {item["id"]: item for item in inventory}
    merged: list[dict[str, Any]] = []
    catalog_ids: set[str] = set()
    for item in items:
        row = dict(item)
        catalog_ids.add(row["id"])
        local_item = local.get(row["id"])
        if local_item:
            row["party"] = "first-party" if local_item["firstParty"] else "third-party"
            row["enabled"] = local_item["enabled"]
            row["active"] = local_item["active"]
            row["canDisable"] = local_item["canDisable"]
            row["kinds"] = local_item["kinds"]
            row["barSection"] = local_item["barSection"]
            row["installedVersion"] = local_item.get("installedVersion", "")
            row["installedRevision"] = local_item.get("installedRevision", "")
        merged.append(row)
    for identity in sorted(local.keys() - catalog_ids):
        local_item = local[identity]
        first_party = local_item["firstParty"]
        kinds = local_item["kinds"]
        merged.append({
            "id": identity,
            "name": local_item["name"],
            "description": "Built into Omarchy." if first_party else "Installed locally; no marketplace listing is cached.",
            "installNote": "",
            "author": "Omarchy" if first_party else "",
            "version": local_item.get("installedVersion", ""),
            "installedVersion": local_item.get("installedVersion", ""),
            "installedRevision": local_item.get("installedRevision", ""),
            "category": "First party" if first_party else "Installed",
            "tags": kinds,
            "kind": ", ".join(kinds[:3]),
            "kinds": kinds,
            "status": "active" if local_item["active"] else ("enabled" if local_item["enabled"] else "installed"),
            "repo": "",
            "owner": "",
            "repoName": "",
            "listingCommit": "",
            "verificationCommit": "",
            "verificationStatus": "",
            "verificationSnapshotStatus": "",
            "verificationCoverage": "",
            "installAvailable": False,
            "stars": None,
            "party": "first-party" if first_party else "third-party",
            "enabled": local_item["enabled"],
            "active": local_item["active"],
            "canDisable": local_item["canDisable"],
            "localOnly": True,
            "barSection": local_item["barSection"],
        })
    return merged


def scan_bar_sections() -> dict[str, str] | None:
    try:
        config = safe_json_loads(
            run_command([COMMANDS["omarchy-shell"], "shell", "listShellConfig"], 5, 2 * 1024 * 1024),
            "Shell configuration",
        )
    except (OSError, TimeoutError, ValueError):
        return None
    if not isinstance(config, dict) or not isinstance(config.get("bar"), dict):
        return None
    bar = config["bar"]
    if not isinstance(bar.get("layout"), dict):
        return None
    layout = bar["layout"]
    sections: dict[str, str] = {}
    for section in ("left", "center", "right"):
        entries = layout.get(section, [])
        if not isinstance(entries, list):
            return None
        for entry in entries[:MAX_INVENTORY_ROWS]:
            identity = plugin_id(entry.get("id") if isinstance(entry, dict) else entry)
            if identity and identity not in sections:
                sections[identity] = section
    return sections


def scan_inventory(include_versions: bool = True) -> tuple[list[dict[str, Any]], bool]:
    """Fresh host presence/state/placement; optional display-only disk enrichment.

    Update safety always uses inspect_update_target on the selected target.
    The default retains the complete inventory contract for ordinary UI loads.
    """
    try:
        plugins = safe_json_loads(
            run_command([COMMANDS["omarchy"], "plugin", "list", "--json"], 5, 2 * 1024 * 1024),
            "Plugin inventory",
        )
        if (not isinstance(plugins, list) or len(plugins) > MAX_INVENTORY_ROWS
                or any(not isinstance(item, dict) or not plugin_id(item.get("id")) for item in plugins)):
            raise ValueError("Plugin inventory returned an invalid root or entry.")
        inventory = validate_inventory(plugins)
        sections = scan_bar_sections()
        for item in inventory:
            item["barSection"] = sections.get(item["id"], "") if sections is not None else ""
            item["barSectionKnown"] = sections is not None
        if include_versions:
            metadata_deadline = time.monotonic() + 20
            with concurrent.futures.ThreadPoolExecutor(max_workers=UPDATES_WORKERS) as executor:
                inventory = list(executor.map(lambda item: inventory_version_metadata(item, metadata_deadline), inventory))
        return inventory, False
    except (OSError, TimeoutError, ValueError):
        plugin_root = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "omarchy/plugins"
        try:
            inventory = validate_inventory([
                {
                    "id": entry.name, "name": entry.name, "firstParty": False,
                    "barSectionKnown": False,
                }
                for entry in list(plugin_root.iterdir())[:MAX_INVENTORY_ROWS]
                if plugin_id(entry.name)
            ])
        except OSError:
            inventory = []
        return inventory, True


def wait_for_plugin_inventory(identity: str, timeout: float = 30) -> dict[str, Any] | None:
    deadline = time.monotonic() + timeout
    while True:
        inventory, unavailable = scan_inventory(include_versions=False)
        if not unavailable:
            target = next((item for item in inventory if item["id"] == identity), None)
            if target is not None:
                return target
        if time.monotonic() >= deadline:
            return None
        time.sleep(0.25)


def installed_revision(identity: str, deadline: float | None = None) -> str:
    """Read the installed checkout revision without following a plugin-root symlink."""
    identity = plugin_id(identity)
    if not identity:
        return ""
    target = (
        Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config")))
        / "omarchy/plugins" / identity
    )
    try:
        metadata = target.lstat()
        if (stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode) or target.resolve() != target.absolute()
                or (target / ".git").is_symlink() or not (target / ".git").is_dir()):
            return ""
        remaining = 5 if deadline is None else min(5, deadline - time.monotonic())
        if remaining <= 0:
            return ""
        revision = run_command(
            [COMMANDS["git"], "--no-optional-locks", "-C", str(target), "rev-parse", "--verify", "HEAD"],
            remaining,
            256,
        ).decode("ascii", "replace")
    except (OSError, TimeoutError, ValueError):
        return ""
    return full_sha(revision)


def plugin_install_path(identity: str) -> Path:
    if not plugin_id(identity) or plugin_id(identity) != identity:
        raise ValueError("Plugin updates require a valid plugin ID.")
    return Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "omarchy/plugins" / identity


def installed_manifest(identity: str) -> dict[str, Any]:
    """Bounded manifest metadata, including development links; no code execution."""
    descriptor = os.open(plugin_install_path(identity) / "manifest.json",
                         os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        metadata = os.fstat(stream.fileno())
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > MAX_UPDATE_MANIFEST_BYTES:
            raise ValueError("Installed plugin manifest is unavailable.")
        raw = stream.read(MAX_UPDATE_MANIFEST_BYTES + 1)
    return update_manifest(raw, identity)


def update_manifest(raw: bytes, identity: str) -> dict[str, str]:
    if len(raw) > MAX_UPDATE_MANIFEST_BYTES:
        raise ValueError("Plugin manifest exceeds its size limit.")
    value = safe_json_loads(raw, "Plugin manifest")
    if not isinstance(value, dict) or value.get("id") != identity:
        raise ValueError("Plugin manifest identity does not match the installed plugin.")
    version = value.get("version")
    if not isinstance(version, str) or not version or len(version) > 64 or one_line(version, 64) != version:
        raise ValueError("Plugin manifest version is unavailable or invalid.")
    return {"id": identity, "version": version, "name": one_line(value.get("name"), 120) or identity}


def inventory_version_metadata(item: dict[str, Any], deadline: float | None = None) -> dict[str, Any]:
    result = dict(item)
    result["installedRevision"] = "" if item.get("firstParty") else installed_revision(item["id"], deadline)
    try:
        result["installedVersion"] = installed_manifest(item["id"])["version"]
    except (OSError, ValueError):
        # First-party manifests are owned by the host, whose list may supply a
        # version. Third-party metadata must come from the installed directory.
        if not item.get("firstParty"):
            result["installedVersion"] = ""
    return result


def update_git(target: Path, arguments: list[str], deadline: float | None = None,
               maximum: int = 64 * 1024) -> bytes:
    remaining = 5 if deadline is None else min(5, deadline - time.monotonic())
    if remaining <= 0:
        raise TimeoutError("Plugin update check exceeded its time limit.")
    return run_command([COMMANDS["git"], "--no-optional-locks", "-c", "core.fsmonitor=false",
                        "-c", "core.untrackedCache=false", "-c", "core.hooksPath=/dev/null",
                        "-C", str(target), *arguments], remaining, maximum)


def inspect_update_target(item: dict[str, Any], deadline: float | None = None) -> dict[str, Any]:
    """Read-only local snapshot. sourceKey is private review evidence, not UI data.

    Input is an authoritative inventory row. Returns installedVersion/Revision,
    state/reason, canonical repository (or empty), and a sourceKey binding the
    directory, origin, effective Git configuration, manifest and clean HEAD.
    state='ready' is internal; all other states can be shown directly.
    """
    identity = item["id"]
    target = plugin_install_path(identity)
    result = {"installedVersion": item.get("installedVersion", ""), "installedRevision": "",
              "state": "unavailable", "reason": "Installed repository is unavailable.",
              "repository": "", "sourceKey": ""}
    if item.get("firstParty"):
        return {**result, "state": "managed", "reason": "First-party plugin updates are managed by Omarchy."}
    try:
        if target.is_symlink() or target.resolve() != target.absolute() or (target / ".git").is_file() \
                or (target / ".git").is_symlink():
            result.update(state="blocked" if identity == APP_ID else "development",
                          reason="Development-linked plugins must be updated in their source checkout.")
            result["installedVersion"] = installed_manifest(identity)["version"]
            return result
        manifest = installed_manifest(identity)
        result["installedVersion"] = manifest["version"]
        if not (target / ".git").is_dir():
            return {**result, "state": "manual", "reason": "This plugin is not a Git installation. Update it using its original installation method."}
        if any(os.path.lexists(target / ".git" / name) for name in
               ("commondir", "worktrees", "objects/info/alternates", "info/grafts")):
            return {**result, "state": "blocked", "reason": "Automatic updates require a self-contained Git checkout."}
        # Check executable Git configuration BEFORE status can invoke a clean
        # filter. Native pinning relies on this source/config digest remaining
        # unchanged during staging. Installed local config is not fetched data.
        config = update_git(target, ["config", "--null", "--list"], deadline)
        for entry in config.split(b"\0"):
            key = entry.split(b"\n", 1)[0].lower()
            if (key.startswith((b"filter.", b"merge.", b"include.", b"includeif.", b"url.", b"submodule.", b"extensions."))
                    or key in {b"core.worktree", b"core.sshcommand", b"core.gitproxy", b"core.alternaterefscommand"}
                    or (key.startswith(b"remote.") and key.rsplit(b".", 1)[-1]
                        in {b"vcs", b"uploadpack", b"receivepack", b"proxy", b"promisor", b"partialclonefilter"})):
                return {**result, "state": "manual" if key.startswith(b"url.") else "blocked",
                        "reason": "This checkout uses Git configuration unsupported by automatic updates."}
        if update_git(target, ["for-each-ref", "--format=%(refname)", "refs/replace/"], deadline):
            return {**result, "state": "blocked", "reason": "Git replacement objects are unsupported for automatic updates."}
        top = update_git(target, ["rev-parse", "--show-toplevel"], deadline).decode().strip()
        if top != str(target):
            return {**result, "state": "blocked", "reason": "Plugin repository layout is unsupported."}
        revision = full_sha(update_git(target, ["rev-parse", "--verify", "HEAD"], deadline).decode())
        if not revision:
            return result
        result["installedRevision"] = revision
        if target != Path.home() / ".config/omarchy/plugins" / identity:
            return {**result, "state": "blocked",
                    "reason": "The native updater does not support this plugin configuration directory."}
        origin = update_git(target, ["config", "--get-all", "remote.origin.url"], deadline).decode().strip()
        effective = update_git(target, ["remote", "get-url", "--all", "origin"], deadline).decode().strip()
        repository = github_repo(origin)
        if not repository or origin != effective or "\n" in origin or origin != one_line(origin, 300):
            return {**result, "state": "manual", "reason": "This source needs a manual update. Automatic checks support public GitHub HTTPS origins without URL rewrites."}
        result["repository"] = repository[2]
        dirty = update_git(target, ["status", "--porcelain=v1", "--untracked-files=normal",
                                    "--ignore-submodules=none"], deadline)
        tracked = update_git(target, ["ls-files", "-v", "-z"], deadline)
        if any(entry[:1].islower() or entry[:1] == b"S" for entry in tracked.split(b"\0") if entry):
            return {**result, "state": "blocked", "reason": "The checkout uses hidden worktree changes or sparse-checkout flags."}
        # A whole effective-config digest catches source/configuration changes
        # without persisting credentials or arbitrary Git configuration text.
        info = target.stat()
        evidence = json.dumps([str(target), info.st_dev, info.st_ino, revision,
                                manifest, origin], sort_keys=True).encode() + config + dirty
        result.update(state="customized" if dirty else "ready",
                      reason="Automatic updates are unavailable while local edits or added files are present." if dirty else "",
                      sourceKey=hashlib.sha256(evidence).hexdigest())
        return result
    except (OSError, UnicodeError, TimeoutError, ValueError):
        return result


def update_remote_json(url: str, deadline: float, maximum: int = 256 * 1024) -> Any:
    remaining = min(10, deadline - time.monotonic())
    if remaining <= 0:
        raise TimeoutError("Plugin update check exceeded its time limit.")
    return safe_json_loads(fetch_bytes(url, "api.github.com", maximum, remaining), "GitHub update check")


class PublicUpdateUnavailable(ValueError):
    """Anonymous remote evidence failed; never carry subprocess output to UI."""


def public_update_head(repository: str, deadline: float) -> bytes:
    """Bounded, anonymous ls-remote outside all installed repositories.

    No inherited environment, Git configuration, netrc, proxy, askpass or
    credential helpers. Unlike fetch, this never writes refs or Git objects.
    The raw advertisement is private parser input, never a UI error message.
    """
    parsed = github_repo(repository)
    if (not parsed or repository != one_line(repository, 300)
            or any(part in {".", ".."} for part in parsed[:2])):
        raise ValueError("Unsupported plugin update source.")
    remaining = min(10, deadline - time.monotonic())
    if remaining <= 0:
        raise TimeoutError("Plugin update check exceeded its time limit.")
    # '/' provides a stable, write-free location outside the installed source.
    # Refuse the unusual case where it could contribute repository config.
    if os.path.lexists("/.git"):
        raise ValueError("An isolated public Git check is unavailable.")
    environment = {"PATH": SYSTEM_COMMAND_PATH, "HOME": "/dev/null", "XDG_CONFIG_HOME": "/dev/null",
                   "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_SYSTEM": "/dev/null",
                   "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0",
                   "GIT_ASKPASS": "/bin/false", "SSH_ASKPASS": "/bin/false",
                   "GIT_CEILING_DIRECTORIES": "/", "GIT_OPTIONAL_LOCKS": "0"}
    argv = [COMMANDS["git"], "--no-optional-locks",
            "-c", "credential.helper=", "-c", "core.askPass=/bin/false",
            "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
            "-c", "protocol.allow=never", "-c", "protocol.https.allow=always",
            "-c", "http.followRedirects=false", "-c", "http.sslVerify=true",
            "-c", "http.extraHeader=", "-c", "http.cookieFile=", "-c", "http.saveCookies=false",
            "ls-remote", "--symref", "--exit-code", "--", parsed[2] + ".git", "HEAD"]
    stop = time.monotonic() + remaining
    process = subprocess.Popen(argv, cwd="/", env=environment, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
    _children.add(process)
    selector = None
    output = bytearray()
    try:
        selector = selectors.DefaultSelector()
        assert process.stdout is not None
        selector.register(process.stdout, selectors.EVENT_READ)
        while selector.get_map():
            remaining = stop - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("Public Git HEAD check timed out.")
            for key, _mask in selector.select(min(0.1, remaining)):
                chunk = os.read(key.fd, min(4096, MAX_UPDATE_HEAD_BYTES + 1 - len(output)))
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                output.extend(chunk)
                if len(output) > MAX_UPDATE_HEAD_BYTES:
                    raise ValueError("Public Git HEAD response exceeds its size limit.")
        _wait_command(process, stop)
        return bytes(output)
    except BaseException as error:
        _terminate_process(process)
        if isinstance(error, (OSError, TimeoutError, subprocess.TimeoutExpired, ValueError)):
            raise PublicUpdateUnavailable("Public Git HEAD could not be checked anonymously within its limits.") from None
        raise
    finally:
        try:
            if selector is not None:
                selector.close()
        finally:
            try:
                if process.stdout is not None:
                    process.stdout.close()
            finally:
                _children.discard(process)


def parse_update_head(raw: bytes) -> dict[str, str]:
    """Accept exactly one symbolic HEAD and its full SHA, with no extra refs."""
    error = "The public remote HEAD advertisement is missing, ambiguous or invalid."
    if not isinstance(raw, bytes) or len(raw) > MAX_UPDATE_HEAD_BYTES:
        raise ValueError(error)
    try:
        text = raw.decode("utf-8", "strict")
    except UnicodeError:
        raise ValueError(error) from None
    lines = text.removesuffix("\n").split("\n")
    if len(lines) != 2:
        raise ValueError(error)
    revision = branch = ""
    for line in lines:
        if line.startswith("ref: refs/heads/") and line.endswith("\tHEAD") and not branch:
            branch = line[len("ref: refs/heads/"):-len("\tHEAD")]
        elif re.fullmatch(r"[0-9a-f]{40}\tHEAD", line) and not revision:
            revision = line[:40]
        else:
            raise ValueError(error)
    # Git ref-format rules, with a small display-safe bound. Branch is metadata
    # only: it is never interpolated into a command or used to fetch the manifest.
    if (not revision or revision == "0" * 40 or not branch or len(branch) > 256 or ".." in branch or "@{" in branch
            or branch.endswith(".") or any(ord(char) < 33 or ord(char) == 127 or char in "~^:?*[\\" for char in branch)
            or one_line(branch, 256) != branch
            or any(not part or part.startswith(".") or part.endswith(".lock") for part in branch.split("/"))):
        raise ValueError(error)
    return {"revision": revision, "branch": branch}


def remote_update_target(repository: str, identity: str, deadline: float | None = None) -> dict[str, str]:
    """Resolve public origin's default-branch HEAD and identity at that exact SHA.

    Returns {revision, version, branch}. Anonymous Git HEAD plus a pinned raw
    manifest uses no GitHub REST quota. Does not fetch into any installed repo.
    Raises a bounded ValueError/transport error when evidence is unavailable.
    """
    parsed = github_repo(repository)
    if not parsed or not plugin_id(identity) or plugin_id(identity) != identity:
        raise ValueError("Unsupported plugin update source.")
    deadline = time.monotonic() + 35 if deadline is None else deadline
    owner, name, _canonical = parsed
    head = parse_update_head(public_update_head(repository, deadline))
    revision, branch = head["revision"], head["branch"]
    remaining = min(10, deadline - time.monotonic())
    if remaining <= 0:
        raise TimeoutError("Plugin update check exceeded its time limit.")
    raw = fetch_bytes(f"https://raw.githubusercontent.com/{owner}/{name}/{revision}/manifest.json",
                      "raw.githubusercontent.com", MAX_UPDATE_MANIFEST_BYTES, remaining)
    manifest = update_manifest(raw, identity)
    return {"revision": revision, "version": manifest["version"], "branch": branch}


def check_plugin_update(item: dict[str, Any], now: float | None = None,
                        snapshot: dict[str, Any] | None = None,
                        deadline: float | None = None) -> dict[str, Any]:
    """Return one public update record; failures are unavailable, never updateable.

    Optional snapshot must come from inspect_update_target, never a request.
    Ordinary available records alone have canUpdate; Outfit uses selfUpdate.
    """
    deadline = time.monotonic() + 45 if deadline is None else deadline
    local = inspect_update_target(item, deadline) if snapshot is None else snapshot
    identity = item["id"]
    result = {"id": identity, "name": one_line(item.get("name"), 120) or identity,
              "installedVersion": local["installedVersion"], "availableVersion": "",
              "installedRevision": local["installedRevision"], "availableRevision": "",
              "state": local["state"], "canUpdate": False, "selfUpdate": identity == APP_ID,
              "reason": local["reason"], "checkError": "", "checkedAt": time.time() if now is None else now}
    customized = local["state"] == "customized"
    if local["state"] not in {"ready", "customized"}:
        return result
    if not customized:
        result.update(state="unavailable", reason="Public update information is unavailable; try again later.")
    failure = "Upstream version could not be checked. Try again later."
    try:
        remote = remote_update_target(local["repository"], identity, deadline)
        result.update(availableVersion=remote["version"], availableRevision=remote["revision"])
        # Upstream metadata is useful even when the installed tree is customized.
        # It is informational, not a proposed upgrade/downgrade or permission to mutate.
        if customized:
            return result
        if remote["revision"] == local["installedRevision"]:
            result.update(state="current", reason="Installed at the remote default-branch revision.")
            return result
        parsed = github_repo(local["repository"])
        assert parsed is not None
        comparison = update_remote_json(
            f"https://api.github.com/repos/{parsed[0]}/{parsed[1]}/compare/"
            f"{local['installedRevision']}...{remote['revision']}?per_page=1", deadline, 1024 * 1024)
        if not isinstance(comparison, dict):
            return result
        base = comparison.get("base_commit")
        ancestor = comparison.get("merge_base_commit")
        if (comparison.get("status") != "ahead" or type(comparison.get("behind_by")) is not int
                or comparison.get("behind_by") != 0
                or type(comparison.get("ahead_by")) is not int or comparison["ahead_by"] <= 0
                or not isinstance(base, dict) or base.get("sha") != local["installedRevision"]
                or not isinstance(ancestor, dict) or ancestor.get("sha") != local["installedRevision"]):
            result.update(state="blocked", reason="Local history is ahead, diverged, or cannot be verified as a fast-forward.")
            return result
        if identity == LEGACY_APP_ID:
            result.update(state="blocked", reason="The legacy Outfit installation requires identity migration.")
        else:
            result.update(state="available", canUpdate=identity != APP_ID,
                          reason="Outfit requires its dedicated self-update flow." if identity == APP_ID else
                          "A fast-forward update is available on the remote default branch.")
    except PublicUpdateUnavailable:
        failure = "The upstream repository is private or unavailable without credentials. Try again later."
    except urllib.error.HTTPError as error:
        # Never expose an HTTP body, URL or exception text (including credentials).
        headers = error.headers or {}
        error.close()
        if error.code == 429 or (error.code == 403 and (
                (headers.get("X-RateLimit-Remaining") or headers.get("x-ratelimit-remaining")) == "0"
                or headers.get("Retry-After") or headers.get("retry-after"))):
            failure = "GitHub is rate-limiting public update checks. Retry after the limit resets; failed checks expire after five minutes."
        elif error.code == 403:
            failure = "GitHub denied or rate-limited this public update request. Retry later."
        elif error.code == 404:
            failure = "The public update source, manifest or history is missing or inaccessible without credentials."
    except (OSError, TimeoutError, ValueError, urllib.error.URLError):
        pass
    if customized:
        result["checkError"] = failure
    elif result["state"] == "unavailable":
        result["reason"] = failure
    return result


def load_plugin_updates(store: Store) -> dict[str, Any]:
    try:
        cached = store.read("plugin-updates.json", MAX_UPDATES_CACHE_BYTES, {})
        entries = cached.get("entries") if isinstance(cached, dict) and cached.get("schema") == 1 else None
        if isinstance(entries, dict) and len(entries) <= MAX_INVENTORY_ROWS + 1:
            output = {}
            for identity, entry in entries.items():
                if not identity or plugin_id(identity) != identity or not isinstance(entry, dict):
                    continue
                row = entry.get("record")
                if not isinstance(row, dict) or row.get("id") != identity:
                    continue
                checked = row.get("checkedAt")
                if (type(checked) not in (int, float) or not 0 <= checked <= 253402300799
                        or not isinstance(row.get("state"), str)
                        or row["state"] not in {"available", "current", "blocked", "unavailable", "managed", "development", "customized", "manual"}
                        or type(row.get("canUpdate")) is not bool or type(row.get("selfUpdate")) is not bool
                        or row["selfUpdate"] != (identity == APP_ID)
                        or (row["canUpdate"] and (row["state"] != "available" or identity in {APP_ID, LEGACY_APP_ID}))
                        or not isinstance(entry.get("sourceKey"), str)
                        or (entry["sourceKey"] and not re.fullmatch(r"[0-9a-f]{64}", entry["sourceKey"]))):
                    continue
                fields = {"id": identity, "checkedAt": checked, "state": row["state"],
                          "canUpdate": row["canUpdate"], "selfUpdate": row["selfUpdate"]}
                for key, limit in (("name", 120), ("reason", 300), ("checkError", 300), ("installedVersion", 64), ("availableVersion", 64)):
                    fields[key] = one_line(row.get(key), limit)
                for key in ("installedRevision", "availableRevision"):
                    fields[key] = full_sha(row.get(key))
                output[identity] = {"record": fields, "sourceKey": entry["sourceKey"]}
            return output
    except (OSError, ValueError):
        pass
    return {}


def cached_update_matches(entry: Any, local: dict[str, Any], now: float) -> bool:
    if not isinstance(entry, dict) or not isinstance(entry.get("record"), dict):
        return False
    checked = entry["record"].get("checkedAt")
    maximum_age = UPDATES_RETRY_AGE if entry["record"].get("state") == "unavailable" or entry["record"].get("checkError") else UPDATES_MAX_AGE
    return (type(checked) in (int, float) and math.isfinite(checked) and 0 <= now - checked < maximum_age
            and local["state"] in {"ready", "customized"} and bool(local["sourceKey"])
            and (local["state"] == "customized") == (entry["record"].get("state") == "customized")
            and entry.get("sourceKey") == local["sourceKey"]
            and entry["record"].get("installedRevision") == local["installedRevision"]
            and entry["record"].get("installedVersion") == local["installedVersion"])


def check_plugin_updates(request: dict[str, Any], store: Store, now: float, generation: int) -> dict[str, Any]:
    if "force" in request and type(request["force"]) is not bool:
        raise ValueError("Update refresh force must be a boolean.")
    selected = request.get("pluginId", "")
    if not isinstance(selected, str) or (selected and (not plugin_id(selected) or plugin_id(selected) != selected)):
        raise ValueError("Plugin updates require a valid plugin ID.")
    inventory, unavailable = scan_inventory(include_versions=False)
    items = list(inventory)
    # The shell can omit its own development-linked service during discovery.
    if not any(item["id"] == APP_ID for item in items):
        items.append({"id": APP_ID, "name": "Outfit", "firstParty": False})
    if selected and not any(item["id"] == selected for item in items):
        raise ValueError("The selected plugin is no longer installed.")
    cached = load_plugin_updates(store)
    deadline = time.monotonic() + UPDATES_TIMEOUT

    def check(item: dict[str, Any]) -> tuple[str, dict[str, Any]]:
        local = inspect_update_target(item, deadline)
        previous = cached.get(item["id"])
        if not unavailable and request.get("force") is not True and cached_update_matches(previous, local, now):
            return item["id"], previous
        if unavailable:
            local.update(state="unavailable", reason="Authoritative plugin inventory is unavailable.")
        record = check_plugin_update(item, now, local, deadline)
        return item["id"], {"record": record, "sourceKey": local["sourceKey"]}

    with concurrent.futures.ThreadPoolExecutor(max_workers=UPDATES_WORKERS) as executor:
        fresh = dict(executor.map(check, [item for item in items if not selected or item["id"] == selected]))
    ids = {item["id"] for item in items}
    with store.scoped_lock():
        merged = load_plugin_updates(store)
        merged.update(fresh)
        merged = {identity: entry for identity, entry in merged.items() if identity in ids}
        store.write("plugin-updates.json", {"schema": 1, "entries": merged}, MAX_UPDATES_CACHE_BYTES)
    # Targeted responses include the refreshed record only. Unrelated reviews
    # remain in the per-ID cache, without presenting stale inventory as current.
    records = [entry["record"] for entry in fresh.values()]
    inventory = inventory_display_metadata(inventory, request, merged)
    return {"ok": True, "action": "check-updates", "generation": generation, "responseKind": "updates",
            "updates": records, "updatesCheckedAt": max((row["checkedAt"] for row in records), default=0),
            "updatesError": "Authoritative plugin inventory is unavailable." if unavailable else "",
            "updatesUnavailableCount": sum(row["state"] == "unavailable" or bool(row.get("checkError")) for row in records),
            "inventory": inventory, "inventoryAuthoritative": not unavailable,
            "installed": sorted(item["id"] for item in inventory)}


@contextmanager
def plugin_update_lock(store: Store):
    """Serialize native updates across helper processes, independently of cache IO."""
    descriptor = os.open(".plugin-update.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK,
                         0o600, dir_fd=store.fd)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise ValueError("Unsafe plugin update lock.")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ValueError("Another plugin update is running; try again after it finishes.") from error
        yield
    finally:
        os.close(descriptor)


def inventory_display_metadata(inventory: list[dict[str, Any]], request: dict[str, Any],
                               reviews: dict[str, Any], observed: dict[str, Any] | None = None,
                               identity: str = "") -> list[dict[str, Any]]:
    """Carry advisory display metadata without re-probing unrelated repositories.

    Never use these rows as mutation evidence. Host state stays authoritative;
    fresh selected-target inspection wins over reviews and prior UI metadata.
    """
    previous = {row["id"]: row for row in validate_inventory(request.get("inventory"))}
    result = []
    for item in inventory:
        fields = previous.get(item["id"], {})
        fields = {**fields, **reviews.get(item["id"], {}).get("record", {})}
        if observed is not None and item["id"] == identity:
            fields = observed
        result.append({**item, **{key: fields.get(key, item.get(key, ""))
                                  for key in ("installedVersion", "installedRevision")}})
    return result


def execute_plugin_update(request: dict[str, Any], store: Store, now: float,
                          generation: int, preferences: dict[str, Any], phase: Any) -> dict[str, Any]:
    identity = plugin_id(request.get("pluginId"))
    expected = full_sha(request.get("expectedRevision"))
    installed = full_sha(request.get("expectedInstalledRevision"))
    if not identity or identity != request.get("pluginId") or not expected or not installed \
            or expected != request.get("expectedRevision") or installed != request.get("expectedInstalledRevision"):
        raise ValueError("Plugin updates require an ID and the reviewed installed and available revisions.")
    if identity in {APP_ID, LEGACY_APP_ID}:
        raise ValueError("Outfit cannot use the ordinary plugin updater for itself.")
    if "batchItem" in request and type(request["batchItem"]) is not bool:
        raise ValueError("Plugin update batchItem must be a boolean.")
    # Native omarchy-plugin-update currently uses HOME/.config, not XDG_CONFIG_HOME.
    if plugin_install_path(identity) != Path.home() / ".config/omarchy/plugins" / identity:
        raise ValueError("The native updater does not support this plugin configuration directory.")
    with plugin_update_lock(store):
        phase("checking")
        inventory, unavailable = scan_inventory(include_versions=False)
        if unavailable:
            raise ValueError("Outfit could not verify authoritative plugin inventory.")
        target = next((item for item in inventory if item["id"] == identity), None)
        if target is None:
            raise ValueError("The selected plugin is no longer installed.")
        local = inspect_update_target(target)
        reviewed = load_plugin_updates(store).get(identity)
        if (not cached_update_matches(reviewed, local, now) or local["installedRevision"] != installed
                or reviewed["record"].get("availableRevision") != expected
                or reviewed["record"].get("state") != "available"
                or reviewed["record"].get("canUpdate") is not True):
            raise ValueError("The installed source or reviewed update changed; check updates and review again.")
        if target.get("barSectionKnown") is not True:
            raise ValueError("Plugin bar placement could not be verified; retry after inventory is available.")
        fresh = check_plugin_update(target, now, local)
        if (fresh["state"] != "available" or not fresh["canUpdate"]
                or fresh["availableRevision"] != expected
                or fresh["availableVersion"] != reviewed["record"].get("availableVersion")):
            raise ValueError("The remote target changed or could not be verified; check updates and review again.")
        # Re-read source/cleanliness after network IO. The shared pinned helper
        # checks again after staging, before native fetch can reach any code.
        latest_inventory, latest_unavailable = scan_inventory(include_versions=False)
        latest_target = next((item for item in latest_inventory if item["id"] == identity), None)
        if (latest_unavailable or latest_target is None or latest_target.get("firstParty")
                or latest_target.get("enabled") != target.get("enabled")
                or latest_target.get("barSectionKnown") is not True
                or latest_target.get("barSection") != target.get("barSection")):
            raise ValueError("Plugin enabled state or placement changed during verification; review the update again.")
        latest = inspect_update_target(latest_target)
        if latest["state"] != "ready" or latest["sourceKey"] != local["sourceKey"]:
            raise ValueError("The installed checkout changed during verification; review the update again.")
        phase("updating")
        command_failed = False
        try:
            update_reviewed_plugin(latest_target, latest, expected, fresh["availableVersion"])
        except (OSError, TimeoutError, ValueError):
            command_failed = True
        phase("verifying")
        inventory, unavailable = scan_inventory(include_versions=False)
        after = next((item for item in inventory if item["id"] == identity), None)
        observed = inspect_update_target(after) if after is not None and not unavailable else None
        verified = bool(not command_failed and observed and observed["state"] == "ready"
                        and observed["repository"] == local["repository"]
                        and observed["installedRevision"] == expected
                        and observed["installedVersion"] == fresh["availableVersion"]
                        and after.get("enabled") == target.get("enabled")
                        and after.get("barSectionKnown") is True
                        and after.get("barSection") == target.get("barSection"))
        notice = "Plugin updated; enabled state and bar placement preserved." if verified else ""
        error = ""
        if not verified:
            if command_failed and observed and observed["installedRevision"] == installed:
                error = "Omarchy did not complete the update; the original revision remains installed (the update may have been rolled back)."
            elif observed and observed["installedRevision"] and observed["installedRevision"] not in {installed, expected}:
                error = "The installed revision differs from the pinned target; the native result is not verified. Check updates again."
            elif command_failed:
                error = "The native update failed or timed out; its final result is not verified. Check inventory and updates again."
            else:
                error = "The resulting revision, version, enabled state or placement could not be verified. Check inventory and updates again."
        operation = {"pluginId": identity, "expectedRevision": expected,
                     "expectedInstalledRevision": installed, "expectedVersion": fresh["availableVersion"],
                     "installedRevision": "", "installedVersion": "",
                     "batchItem": request.get("batchItem") is True,
                     "status": "completed" if verified else "partial", "verified": verified,
                     "message": notice or error}
        if observed:
            operation.update(installedRevision=observed["installedRevision"], installedVersion=observed["installedVersion"])
        # Invalidate this review after every attempted native update, including
        # failure/rollback. Other IDs' independently reviewed targets survive.
        with store.scoped_lock():
            entries = load_plugin_updates(store)
            entries.pop(identity, None)
            store.write("plugin-updates.json", {"schema": 1, "entries": entries}, MAX_UPDATES_CACHE_BYTES)
        inventory = inventory_display_metadata(inventory, request, entries, observed, identity)
        profile = [item for item in validate_profile(request.get("profile"))
                   if item.get("source", "hardware") == "hardware" or item["id"].startswith("capability-")]
        return plugin_mutation_response(request, "update-plugin", generation, identity, profile, [],
                                        inventory, unavailable, preferences, operation, notice, error)


def is_bar_widget(item: dict[str, Any]) -> bool:
    kinds = item.get("kinds") if isinstance(item.get("kinds"), list) else []
    if "bar-widget" in kinds:
        return True
    kind = normalized(item.get("kind", "")).replace("-", " ")
    return kind == "bar widget" or "bar widget" in kind.split(",")


class ScanResult(tuple):
    """Tuple-three compatibility, with optional detailed probe results."""
    def __new__(cls, signals, unavailable, inventory, probes):
        result = super().__new__(cls, (signals, unavailable, inventory))
        result.probes = probes
        return result


def scan_profile(progress: Any = None) -> tuple[list[dict[str, Any]], list[str], list[dict[str, Any]]]:
    signals: list[dict[str, Any]] = []
    seen: set[str] = set()
    unavailable: list[str] = []
    inventory: list[dict[str, Any]] = []
    partial: set[str] = set()
    finished = 0

    def completed() -> None:
        nonlocal finished
        finished += 1
        if progress is not None:
            progress("scan", "Local check finished", processed=finished, total=len(PROBE_IDS),
                     checksFinished=finished, checksTotal=len(PROBE_IDS))

    def read(path: Path, maximum: int, probe: str) -> str:
        value = _read_small(path, maximum)
        if not value or len(value) >= maximum:
            partial.add(probe)
        return value

    def add(item: dict[str, Any]) -> None:
        identity = item.get("id", "")
        if identity and identity not in seen:
            seen.add(identity)
            signals.append(item)

    monitor_count = 0
    try:
        monitors = safe_json_loads(
            run_command([COMMANDS["hyprctl"], "-j", "monitors"], 3, 2 * 1024 * 1024),
            "Monitor probe",
        )
        if not isinstance(monitors, list) or any(not isinstance(item, dict) for item in monitors):
            raise ValueError("Monitor probe returned an invalid root or entry.")
        if isinstance(monitors, list):
            monitor_count = len(monitors)
            if monitor_count > 1:
                add(_signal(
                    "multi-monitor",
                    f"{monitor_count} displays",
                    {"multi-monitor": 20, "multiple monitors": 20, "per-monitor": 16,
                     "display": 6, "workspace": 5, "screen": 4},
                    "Active Hyprland outputs",
                ))
    except (OSError, TimeoutError, ValueError):
        unavailable.append("displays")
    completed()

    try:
        devices = safe_json_loads(
            run_command([COMMANDS["hyprctl"], "-j", "devices"], 3, 4 * 1024 * 1024),
            "Input probe",
        )
        if not isinstance(devices, dict) or not devices or any(not isinstance(value, list) for value in devices.values()):
            raise ValueError("Input probe returned an invalid root.")
        device_text = normalized(json.dumps(devices, ensure_ascii=True)) if isinstance(devices, dict) else ""
        if len(device_text) >= 50_000:
            partial.add("input devices")
        if "touchpad" in device_text or "trackpad" in device_text:
            add(_signal("touchpad", "Touchpad", {"touchpad": 22, "trackpad": 18, "gesture": 7}, "Input device"))
        if "touchscreen" in device_text or '"touch"' in device_text:
            add(_signal("touchscreen", "Touchscreen", {"touchscreen": 24, "touch input": 16, "gesture": 5}, "Input device"))
        if any(term in device_text for term in ("wacom", "stylus", "tablet")):
            add(_signal("pen-tablet", "Pen or tablet", {"stylus": 22, "active pen": 20, "wacom": 18, "tablet": 8}, "Input device"))
    except (OSError, TimeoutError, ValueError):
        unavailable.append("input devices")
    completed()

    try:
        bluetooth = run_command(
            [COMMANDS["bluetoothctl"], "--timeout", "3", "devices", "Connected"],
            4,
            128 * 1024,
        ).decode("utf-8", errors="replace")
        # bluetoothctl may interleave hundreds of [NEW]/[CHG] controller and
        # device notifications with this command's actual Device rows.
        bluetooth_rows = {}
        for line in bluetooth.splitlines():
            clean = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", line).strip()
            if "no default controller" in clean.lower():
                raise ValueError("Bluetooth controller unavailable.")
            match = re.match(r"^Device\s+((?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2})\s+(.+)$", clean)
            if match:
                bluetooth_rows[match.group(1).upper()] = match.group(2)
        if len(bluetooth_rows) > 8:
            partial.add("Bluetooth")
        for address, name in list(bluetooth_rows.items())[:8]:
                info = ""
                try:
                    info = run_command(
                        [COMMANDS["bluetoothctl"], "--timeout", "2", "info", address],
                        3,
                        64 * 1024,
                    ).decode("utf-8", errors="replace")
                except (OSError, TimeoutError, ValueError):
                    partial.add("Bluetooth")
                add(_known_bluetooth(name, info))
    except (OSError, TimeoutError, ValueError):
        unavailable.append("Bluetooth")
    completed()

    usb_hub = False
    usb_support = False
    try:
        usb = Path("/sys/bus/usb/devices")
        if not usb.is_dir() or not os.access(usb, os.R_OK | os.X_OK):
            raise OSError("USB devices unavailable")
        products: list[str] = []
        paths = sorted(usb.glob("*/product"))
        if len(paths) > 128:
            partial.add("USB devices")
        for path in paths[:128]:
            product = read(path, 160, "USB devices")
            if product:
                products.append(product)
        text = normalized(" ".join(products))
        usb_hub = "hub" in text
        usb_support = any(term in text for term in ("ethernet", "displaylink", "billboard", "thunderbolt"))
        if "dock" in text or "docking" in text:
            add(_signal("hardware-dock", "Hardware dock", {"usb-c dock": 28, "thunderbolt dock": 28, "docking station": 28, "display": 6}, "Attached USB product"))
        if "displaylink" in text:
            add(_signal("displaylink", "DisplayLink", {"displaylink": 28, "display": 6, "monitor": 6}, "Attached USB display device"))
        if any(term in text for term in ("webcam", "camera")):
            add(_signal("camera", "Camera", {"camera": 14, "webcam": 18, "camera effects": 10}, "Attached USB device"))
        if "razer" in text:
            add(_signal("razer", "Razer peripheral", {"razer": 28, "openrazer": 20, "rgb": 6}, "Attached USB device"))
        if "logitech" in text:
            add(_signal("logitech", "Logitech peripheral", {"logitech": 24, "solaar": 18}, "Attached USB device"))
        if "elgato" in text:
            add(_signal("elgato", "Elgato device", {"elgato": 26, "key light": 18, "stream deck": 18}, "Attached USB device"))
    except OSError:
        unavailable.append("USB devices")
    completed()

    if "hardware-dock" not in seen and monitor_count > 1 and usb_hub and usb_support:
        add(_signal(
            "dock-like",
            "Dock-like setup (inferred)",
            {"usb-c dock": 20, "thunderbolt dock": 20, "docking station": 20,
             "multi-monitor": 8, "display": 5},
            "Multiple displays plus USB hub capabilities",
        ))

    vendor = read(Path("/sys/class/dmi/id/sys_vendor"), 100, "system model")
    model = read(Path("/sys/class/dmi/id/product_name"), 100, "system model")
    system_text = normalized(vendor + " " + model)
    if "framework" in system_text:
        add(_signal("framework", "Framework computer", {"framework": 28, "laptop": 4, "power": 3}, "System vendor"))
    elif "g14" in system_text or ("asus" in system_text and "rog" in system_text):
        add(_signal("asus-gaming", "ASUS ROG laptop", {"asus": 20, "g14": 24, "rog": 18, "aura": 7}, "System model"))
    elif "thinkpad" in system_text:
        add(_signal("thinkpad", "ThinkPad", {"thinkpad": 26, "lenovo": 12, "laptop": 4}, "System model"))
    elif "dell" in system_text:
        add(_signal("dell", "Dell computer", {"dell": 22, "laptop": 4, "power": 3}, "System vendor"))
    completed()

    try:
        if not Path("/sys/class/drm").is_dir() or not os.access("/sys/class/drm", os.R_OK | os.X_OK):
            raise OSError("Graphics unavailable")
        paths = sorted(Path("/sys/class/drm").glob("card[0-9]*/device/vendor"))
        if len(paths) > 16:
            partial.add("graphics")
        gpu_vendors = {
            normalized(read(path, 20, "graphics"))
            for path in paths[:16]
        }
        gpu_mappings = {
            "0x10de": ("graphics-nvidia", "NVIDIA graphics", {"nvidia": 28, "nvidia gpu": 24, "gpu": 4}),
            "0x1002": ("graphics-amd", "AMD graphics", {"amd gpu": 24, "radeon": 22, "gpu": 4}),
            "0x8086": ("graphics-intel", "Intel graphics", {"intel graphics": 24, "intel gpu": 20, "gpu": 4}),
        }
        for gpu_vendor in sorted(gpu_vendors):
            if gpu_vendor in gpu_mappings:
                identity, label, terms = gpu_mappings[gpu_vendor]
                add(_signal(identity, label, terms, "DRM device"))
    except OSError:
        unavailable.append("graphics")
    completed()

    audio_text = read(Path("/proc/asound/cards"), 32 * 1024, "audio devices")
    try:
        pipewire = run_command([COMMANDS["wpctl"], "status", "--name"], 3, 512 * 1024)
        audio_text += " " + pipewire.decode("utf-8", errors="replace")
    except (OSError, TimeoutError, ValueError):
        partial.add("audio devices")
        if not audio_text:
            unavailable.append("audio devices")
    normalized_audio = normalized(audio_text)
    audio_mappings = (
        ("focusrite", "audio-focusrite", "Focusrite audio", {"focusrite": 28, "scarlett": 22, "audio interface": 8}),
        ("scarlett", "audio-focusrite", "Focusrite Scarlett", {"scarlett": 28, "focusrite": 22, "audio interface": 8}),
        ("goxlr", "audio-goxlr", "GoXLR", {"goxlr": 30, "audio interface": 8}),
        ("stream deck", "audio-stream-deck", "Stream Deck", {"stream deck": 28, "elgato": 20}),
        ("steelseries", "audio-steelseries", "SteelSeries audio", {"steelseries": 26, "arctis": 18, "headset": 6}),
    )
    for needle, identity, label, terms in audio_mappings:
        if needle in normalized_audio:
            add(_signal(identity, label, terms, "Audio device"))
    completed()

    try:
        battery_found = False
        if not Path("/sys/class/power_supply").is_dir() or not os.access("/sys/class/power_supply", os.R_OK | os.X_OK):
            raise OSError("Power supplies unavailable")
        supplies = sorted(Path("/sys/class/power_supply").glob("*"))
        if len(supplies) > 64:
            partial.add("power")
        for supply in supplies[:64]:
            if normalized(read(supply / "type", 40, "power")) == "battery":
                battery_found = True
                break
        if battery_found:
            add(_signal("battery", "System battery", {"battery": 15, "charge limit": 12, "power management": 10}, "Power supply"))
    except OSError:
        unavailable.append("power")
    completed()

    for identity, (path, label, terms) in CAPABILITIES.items():
        if os.path.isfile(path) and os.access(path, os.X_OK):
            if identity == "nvidia" and "graphics-nvidia" in seen:
                continue
            add(_signal(f"capability-{identity}", label, terms, "Installed executable; device presence not confirmed", "software"))
    completed()

    inventory, inventory_unavailable = scan_inventory()
    if inventory_unavailable:
        unavailable.append("installed plugins")
    elif any(item.get("barSectionKnown") is False for item in inventory):
        unavailable.append("bar sections")
    completed()
    completed()

    probes = [{"id": identity, "state": "failed" if identity in unavailable else
               "partial" if identity in partial else "success",
               "reason": "Probe unavailable" if identity in unavailable else
               "Some observations could not be checked" if identity in partial else ""}
              for identity in PROBE_IDS]
    return ScanResult(signals, sorted(set(unavailable) | partial), inventory, probes)


def validate_profile(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list) or len(value) > 64:
        return []
    output: list[dict[str, Any]] = []
    for raw in value:
        if not isinstance(raw, dict):
            continue
        identity = plugin_id(raw.get("id"))
        terms = raw.get("terms") if isinstance(raw.get("terms"), list) else []
        if not identity:
            continue
        clean_terms = []
        for term in terms[:16]:
            if not isinstance(term, dict):
                continue
            phrase = one_line(term.get("value"), 50)
            weight = term.get("weight")
            if phrase and type(weight) is int:
                clean_terms.append({"value": phrase, "weight": max(1, min(30, weight))})
        output.append({
            "id": identity,
            "label": one_line(raw.get("label"), 80),
            "detail": one_line(raw.get("detail"), 140),
            "source": "software" if identity.startswith("capability-") else
                raw.get("source") if raw.get("source") in {"hardware", "workflow", "software"} else "hardware",
            "probeId": signal_metadata(identity)[0],
            "domain": signal_metadata(identity)[1],
            "method": signal_metadata(identity)[2],
            "stale": raw.get("stale") is True,
            "checkedAt": raw.get("checkedAt", 0) if type(raw.get("checkedAt", 0)) in (int, float)
                and math.isfinite(raw.get("checkedAt", 0)) and raw.get("checkedAt", 0) >= 0 else 0,
            "terms": clean_terms,
        })
    return output


def detected_profile(value: Any) -> list[dict[str, Any]]:
    return [item for item in validate_profile(value)
            if item["source"] == "hardware" or item["id"].startswith("capability-")]


def accepted_scan(result: tuple, previous: Any, previous_profile: Any, now: float) -> dict[str, Any]:
    current, unavailable, _inventory = result
    observations = detected_profile(current)
    probes = getattr(result, "probes", None) or [
        {"id": identity, "state": "failed" if identity in unavailable else "success",
         "reason": "Probe unavailable" if identity in unavailable else ""} for identity in PROBE_IDS]
    states = {probe["id"]: probe["state"] for probe in probes}
    previous = previous if isinstance(previous, dict) else {}
    before = detected_profile(previous.get("observations", previous_profile))
    ids = {item["id"] for item in observations}
    for item in before:
        relevant = [item["probeId"]] + (["displays"] if item["id"] == "dock-like" else [])
        if item["id"] not in ids and any(states.get(probe) != "success" for probe in relevant):
            observations.append({**item, "stale": True})
    observations = observations[:64]
    for item in observations:
        if not item["stale"]:
            item["checkedAt"] = now
    stale_probes = {item["probeId"] for item in observations if item["stale"]}
    if any(item["id"] == "dock-like" and item["stale"] for item in observations):
        stale_probes.add("displays")
    probes = [{**probe, "state": "stale" if probe["state"] == "failed" else probe["state"],
               "checkState": probe["state"], "reason": probe["reason"] + "; last confirmed observations retained"}
              if probe["id"] in stale_probes and probe["state"] != "success" else probe for probe in probes]
    failed = any(probe["state"] != "success" for probe in probes)
    return {"state": "failed" if all(value == "failed" for value in states.values()) else
            "partial" if failed else "success", "checkedAt": now,
            "probes": probes, "observations": observations}


def readme_key(item: dict[str, Any]) -> str:
    if item.get("localOnly") or item.get("party") == "first-party":
        return ""
    repo, commit = item.get("repo"), item.get("listingCommit")
    if not isinstance(repo, str) or not isinstance(commit, str):
        return ""
    return _readme_identity(repo, commit)


@functools.lru_cache(maxsize=MAX_CATALOG_ROWS * 2)
def _readme_identity(repository: str, revision: str) -> str:
    repo, commit = github_repo(repository), full_sha(revision)
    if not repo or not commit:
        return ""
    return hashlib.sha256((repo[2].lower() + "\0" + commit).encode()).hexdigest()


class ReadmeIndex:
    """Transactional, revision-keyed search corpus; reads never initiate downloads."""
    def __init__(self, store: Store, create: bool = False) -> None:
        self.db = None
        name = "readme-search.sqlite"
        for suffix in ("", "-wal", "-shm", "-journal"):
            try:
                info = os.stat(name + suffix, dir_fd=store.fd, follow_symlinks=False)
            except FileNotFoundError:
                continue
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or info.st_size > MAX_SEARCH_INDEX_BYTES + 4 * 1024 * 1024):
                raise ValueError("README search storage is unsafe or exceeds its limit.")
        if not create and store.stamp(name) is None:
            return
        if create:
            fd = os.open(name, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600, dir_fd=store.fd)
            os.fchmod(fd, 0o600)
            os.close(fd)
        uri = (store.base / name).as_uri() + ("?mode=rw" if create else "?mode=ro")
        self.db = sqlite3.connect(uri, uri=True, timeout=0.25)
        try:
            self.db.execute("PRAGMA trusted_schema=OFF")
            self.db.execute("PRAGMA cache_size=-8192")
            if create:
                self.db.execute("PRAGMA journal_mode=WAL")
                self.db.execute("PRAGMA wal_autocheckpoint=256")
                self.db.execute("PRAGMA journal_size_limit=4194304")
                page_size = self.db.execute("PRAGMA page_size").fetchone()[0]
                self.db.execute(f"PRAGMA max_page_count={MAX_SEARCH_INDEX_BYTES // page_size}")
                with self.db:
                    self.db.execute("""CREATE TABLE IF NOT EXISTS documents (
                        key TEXT PRIMARY KEY, body TEXT NOT NULL DEFAULT '',
                        state TEXT NOT NULL DEFAULT 'pending', version INTEGER NOT NULL DEFAULT 0,
                        attempts INTEGER NOT NULL DEFAULT 0, retry_at REAL NOT NULL DEFAULT 0,
                        truncated INTEGER NOT NULL DEFAULT 0, path TEXT NOT NULL DEFAULT '')""")
                    self.db.execute("""CREATE VIRTUAL TABLE IF NOT EXISTS readme_fts USING fts5(
                        body, content='documents', content_rowid='rowid', tokenize='trigram', detail='none')""")
                    self.db.execute("CREATE TABLE IF NOT EXISTS index_control (name TEXT PRIMARY KEY, value REAL)")
        except Exception:
            self.close()
            raise

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.close()

    def close(self) -> None:
        if self.db is not None:
            self.db.close()
            self.db = None

    def document_rows(self, sql: str, parameters: tuple = (), keys: set[str] | None = None):
        """Bounded current-key queries even when retained historical seeds grow.

        SQL is application-owned and uses the document alias d. Batches stay
        below SQLite's portable variable limit; no imported SQL is accepted.
        """
        if self.db is None:
            return
        if keys is None:
            yield from self.db.execute(sql + " LIMIT 10000", parameters)
            return
        ordered = sorted(keys)
        for offset in range(0, len(ordered), 256):
            batch = ordered[offset:offset + 256]
            yield from self.db.execute(sql + " AND d.key IN (" + ",".join("?" for _ in batch) + ")",
                                       (*parameters, *batch))

    def states(self, keys: set[str] | None = None) -> dict[str, tuple]:
        return {row[0]: row[1:] for row in self.document_rows(
            "SELECT d.key,d.state,d.version,d.attempts,d.retry_at,length(d.body)>0,d.truncated FROM documents d WHERE 1",
            keys=keys)}

    def put(self, key: str, document: dict[str, Any], now: float) -> None:
        text = normalized(document.get("searchText") or document.get("content") or document.get("text"))
        body = text[:MAX_README_TEXT]
        with self.db:
            old = self.db.execute("SELECT rowid,body,attempts FROM documents WHERE key=?", (key,)).fetchone()
            attempts = (old[2] if old else 0) + 1
            if document.get("ok") and body:
                if old and old[1]:
                    self.db.execute("INSERT INTO readme_fts(readme_fts,rowid,body) VALUES('delete',?,?)", old[:2])
                self.db.execute("""INSERT INTO documents(key,body,state,version,attempts,truncated,path)
                    VALUES(?,?,'indexed',?,?,?,?) ON CONFLICT(key) DO UPDATE SET
                    body=excluded.body,state='indexed',version=excluded.version,attempts=excluded.attempts,
                    retry_at=0,truncated=excluded.truncated,path=excluded.path""",
                    (key, body, SEARCH_INDEX_VERSION, attempts, int(bool(document.get("truncated")) or len(text) > MAX_README_TEXT),
                     one_line(document.get("path"), 80)))
                rowid = self.db.execute("SELECT rowid FROM documents WHERE key=?", (key,)).fetchone()[0]
                self.db.execute("INSERT INTO readme_fts(rowid,body) VALUES(?,?)", (rowid, body))
            else:
                unavailable = document.get("unavailable") is True or document.get("ok") is True
                delay = 7 * 86400 if unavailable else min(86400, 300 * 2 ** min(attempts - 1, 8))
                self.db.execute("""INSERT INTO documents(key,state,attempts,retry_at)
                    VALUES(?,?,?,?) ON CONFLICT(key) DO UPDATE SET
                    state=excluded.state,attempts=excluded.attempts,retry_at=excluded.retry_at""",
                    (key, "unavailable" if unavailable else "failed", attempts, now + delay))

    def sync(self, items: list[dict[str, Any]], cached: dict[str, Any], now: float, prune: bool = True) -> None:
        keys = {readme_key(item) for item in items} - {""}
        states = self.states()
        states.update(self.states(keys))
        with self.db:
            for key in (states.keys() - keys) if prune else ():
                row = self.db.execute("SELECT rowid,body FROM documents WHERE key=?", (key,)).fetchone()
                if row[1]:
                    self.db.execute("INSERT INTO readme_fts(readme_fts,rowid,body) VALUES('delete',?,?)", row)
                self.db.execute("DELETE FROM documents WHERE key=?", (key,))
            if prune and self.db.execute("SELECT 1 FROM sqlite_master WHERE name='search_pack_sources'").fetchone():
                self.db.execute("DELETE FROM search_pack_sources WHERE key NOT IN (SELECT key FROM documents)")
            self.db.executemany("INSERT OR IGNORE INTO documents(key) VALUES(?)", ((key,) for key in keys))
        # Existing inspector documents provide immediate useful coverage.
        for item in items:
            key = readme_key(item)
            entry = cached.get(item["id"], {})
            if key and key not in states and entry.get("commit") == item.get("listingCommit") and entry.get("content"):
                self.put(key, {**entry, "ok": True, "truncated": len(entry["content"]) >= MAX_README_TEXT, "path": "README.md"}, now)
                states[key] = ("indexed", SEARCH_INDEX_VERSION, 1, 0, True, True)

    def evidence(self, query: str, keys: set[str] | None = None) -> dict[str, dict[str, Any]]:
        _phrase, words = _search_parts(query)
        if self.db is None or not words:
            return {}
        # detail=none only supports individual trigrams. OR nomination matters:
        # the other query words may be in listing metadata, not this document.
        # A short term anywhere requires the bounded scan, including mixed queries.
        if all(len(word) >= 3 for word in words):
            expression = " OR ".join('"' + word[:3].replace('"', '""') + '"' for word in dict.fromkeys(words))
            rows = self.document_rows("""SELECT d.key,d.body FROM readme_fts f
                JOIN documents d ON d.rowid=f.rowid WHERE readme_fts MATCH ?""", (expression,), keys)
        else:
            rows = self.document_rows("SELECT d.key,d.body FROM documents d WHERE d.body<>''", keys=keys)
        result = {}
        for key, body in rows:
            evidence = _search_text_evidence(body, query)
            if evidence["matchedTokens"]:
                result[key] = evidence
        return result

    def matches(self, query: str) -> dict[str, int]:
        """Compatibility for consumers interested only in README membership."""
        return {key: len(value["matchedTokens"]) * 11 + value["boost"]
                for key, value in self.evidence(query).items()}


def _readme_sidecar_stamp(store: Store, suffix: str) -> tuple[Any, ...] | None:
    name = "readme-search.sqlite" + suffix
    stamp = store.stamp(name)
    if (stamp is None or not stat.S_ISREG(stamp[4]) or stamp[5] != os.getuid()
            or stamp[3] > MAX_SEARCH_INDEX_BYTES + 4 * 1024 * 1024):
        return stamp
    cache = store.memory.setdefault("indexSidecarStamps", {})
    cached = cache.get(suffix)
    if cached is not None and cached[0] == stamp:
        return cached[1]
    # SQLite's Unix VFS fchowns WAL/journal files on open when running as
    # root, even for read-only connections and unchanged ownership. Preserve
    # identity, permissions, owner, size and mtime, but verify bytes on ctime
    # changes instead of treating that no-op as a new corpus. This also detects
    # same-size content edits whose mtime was restored. Hash only on stat misses.
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=store.fd)
        with os.fdopen(fd, "rb") as stream:
            info = os.fstat(stream.fileno())
            opened = (info.st_ino, info.st_mtime_ns, info.st_ctime_ns, info.st_size, info.st_mode, info.st_uid)
            if opened != stamp:
                return stamp
            digest = hashlib.sha256()
            remaining = stamp[3]
            while remaining:
                chunk = stream.read(min(remaining, 65536))
                if not chunk:
                    return stamp
                digest.update(chunk)
                remaining -= len(chunk)
            if stream.read(1) or store.stamp(name) != stamp:
                return stamp
    except OSError:
        # A checkpoint may remove the WAL between stat and open. Keep the
        # conservative raw stamp on races/errors; never memoize an unread file.
        return stamp
    verified = stamp[:2] + (digest.digest(),) + stamp[3:]
    cache[suffix] = (stamp, verified)
    return verified


def pack_release_url(value: Any) -> bool:
    if not isinstance(value, str) or len(value) > 1000:
        return False
    return bool(re.fullmatch(
        r"https://github\.com/ctl0v0/outfit/releases/download/[A-Za-z0-9][A-Za-z0-9._-]{0,127}/[A-Za-z0-9][A-Za-z0-9._-]{0,127}", value))


class SearchPackRedirect(urllib.request.HTTPRedirectHandler):
    """Release redirects only; signed asset query parameters are opaque data."""
    def redirect_request(self, request, response, code, message, headers, new_url):
        parsed = urllib.parse.urlsplit(new_url)
        origin = urllib.parse.urlsplit(request.full_url).hostname
        if (len(new_url) > 16384 or parsed.scheme != "https" or parsed.port not in (None, 443)
                or parsed.username or parsed.password or parsed.fragment
                or origin not in {"github.com", "release-assets.githubusercontent.com"}
                or not (pack_release_url(new_url) or (
                    parsed.hostname == "release-assets.githubusercontent.com"
                    and parsed.path.startswith("/github-production-release-asset/")))):
            raise ValueError("Search pack redirected outside the approved release hosts.")
        return super().redirect_request(request, response, code, message, headers, new_url)


def fetch_search_pack(url: str, maximum: int, progress: Any = None) -> bytes:
    if not pack_release_url(url):
        raise ValueError("Search pack URL is outside the fixed project releases.")
    request = urllib.request.Request(url, headers={"User-Agent": "Outfit/0.1", "Accept": "application/octet-stream"})
    opener = urllib.request.build_opener(SearchPackRedirect())
    deadline = time.monotonic() + 60
    with opener.open(request, timeout=20) as response:
        return read_bounded_response(response, maximum, deadline, progress)


def validate_pack_manifest(raw: Any) -> dict[str, Any]:
    if (not isinstance(raw, dict) or type(raw.get("schemaVersion")) is not int or raw["schemaVersion"] != 1
            or type(raw.get("dataVersion")) is not int or raw["dataVersion"] != SEARCH_INDEX_VERSION
            or not isinstance(raw.get("version"), str) or not re.fullmatch(r"[0-9]{8}T[0-9]{6}Z", raw["version"])
            or raw.get("format") != "jsonl-gzip"
            or raw.get("assetUrl") != "https://github.com/ctl0v0/outfit/releases/download/"
                + f"search-pack-{raw['version']}/search-pack-{raw['version']}.jsonl.gz"
            or not isinstance(raw.get("sha256"), str) or not re.fullmatch(r"[0-9a-f]{64}", raw["sha256"])):
        raise ValueError("Search pack manifest is invalid or incompatible.")
    for field, maximum in (("docCount", MAX_CATALOG_ROWS), ("compressedBytes", MAX_PACK_BYTES),
                           ("uncompressedBytes", MAX_PACK_EXPANDED)):
        if type(raw.get(field)) is not int or not 0 <= raw[field] <= maximum:
            raise ValueError("Search pack manifest exceeds its limits.")
    for field in ("generatedAt", "catalogGeneratedAt"):
        if not listing_date(raw.get(field)) or "T" not in raw[field] or not raw[field].endswith("Z"):
            raise ValueError("Search pack manifest requires ISO source timestamps.")
    if datetime.fromisoformat(raw["generatedAt"].replace("Z", "+00:00")).strftime("%Y%m%dT%H%M%SZ") != raw["version"]:
        raise ValueError("Search pack version does not match its build timestamp.")
    for field in ("complete", "publishable"):
        if field in raw and type(raw[field]) is not bool:
            raise ValueError("Search pack completion flags are invalid.")
    for field in ("catalogCount", "candidateCount", "unpinnedCount"):
        if field in raw and (type(raw[field]) is not int or not 0 <= raw[field] <= MAX_CATALOG_ROWS):
            raise ValueError("Search pack catalog counters are invalid.")
    if "candidateCount" in raw and (raw["docCount"] > raw["candidateCount"] or (
            raw.get("complete") is True and raw["docCount"] != raw["candidateCount"])):
        raise ValueError("Search pack completeness counters do not agree.")
    for field in ("stateCounts", "reasonCounts"):
        if field not in raw:
            continue
        counts = raw[field]
        if (not isinstance(counts, dict) or len(counts) > 100
                or any(not isinstance(key, str) or not key or len(key) > 128
                       or type(value) is not int or not 0 <= value <= MAX_CATALOG_ROWS
                       for key, value in counts.items()) or sum(counts.values()) != raw["docCount"]
                or (field == "stateCounts" and set(counts) - {"indexed", "excluded", "unavailable"})):
            raise ValueError("Search pack coverage counters are invalid.")
    if "provenance" in raw:
        provenance = raw["provenance"]
        if (not isinstance(provenance, dict)
                or provenance.get("sourceRepository") != "https://github.com/ctl0v0/outfit"
                or not full_sha(provenance.get("sourceCommit"))
                or provenance.get("catalogUrl") != CATALOG_URL
                or type(provenance.get("licensePolicyVersion")) is not int or provenance["licensePolicyVersion"] != 1
                or type(provenance.get("sourceDirty")) is not bool
                or not listing_date(provenance.get("catalogFetchedAt"))
                or any(not isinstance(provenance.get(field), str)
                       or not re.fullmatch(r"[0-9a-f]{64}", provenance[field]) for field in (
                           "builderSha256", "normalizerSha256", "catalogSha256", "catalogSnapshotSha256", "policyFingerprint"))):
            raise ValueError("Search pack source provenance is invalid.")
    return {key: raw[key] for key in ("schemaVersion", "version", "dataVersion", "format", "assetUrl", "sha256",
                                     "docCount", "compressedBytes", "uncompressedBytes", "generatedAt", "catalogGeneratedAt",
                                     "complete", "publishable", "catalogCount", "candidateCount", "unpinnedCount",
                                     "stateCounts", "reasonCounts", "provenance") if key in raw}


# Only explicit redistribution grants enter the public seed. Uncertain licenses
# remain excluded; the normal local-only upstream fetcher can still fill them.
PACK_LICENSES = {"MIT", "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause", "ISC"}


def validate_pack_legal(record: dict[str, Any], repo: tuple[str, str, str], commit: str) -> None:
    """Validate preserved attribution as bounded data, never fetched/executed."""
    legal = record.get("sourceLicenseText")
    path = record.get("sourceLicensePath")
    notices = record.get("sourceNotices")
    if (record["license"] not in PACK_LICENSES or not record["body"]
            or record["path"] not in {"README.md", "readme.md", "README.MD", "README.rst", "README"}
            or not re.fullmatch(r"[0-9a-f]{64}", record["sourceSha256"])
            or not isinstance(legal, str) or not legal.strip()
            or not isinstance(path, str) or not re.fullmatch(r"(?i)(?:licen[sc]e|copying)(?:[._-][a-z0-9.-]+)?", path)
            or not isinstance(record.get("sourceLicenseSha256"), str)
            or not re.fullmatch(r"[0-9a-f]{64}", record["sourceLicenseSha256"])
            or not isinstance(notices, list) or len(notices) > 1000
            or record.get("licenseEvidenceUrl") != f"https://api.github.com/repos/{repo[0]}/{repo[1]}/license?ref={commit}"
            or not isinstance(record.get("modifications"), str) or not record["modifications"]
            or len(record["modifications"]) > 1000):
        raise ValueError("Search pack document lacks redistribution provenance.")
    combined = len(legal.encode("utf-8"))
    if combined > MAX_PACK_LEGAL_BYTES:
        raise ValueError("Search pack license exceeds its limit.")
    paths = set()
    for notice in notices:
        if (not isinstance(notice, dict) or not isinstance(notice.get("text"), str)
                or not isinstance(notice.get("path"), str)
                or not re.fullmatch(r"(?i)(?:notice|authors|copyright)(?:[._-][a-z0-9.-]+)?", notice["path"])
                or notice["path"] in paths or not isinstance(notice.get("sha256"), str)
                or not re.fullmatch(r"[0-9a-f]{64}", notice["sha256"])):
            raise ValueError("Search pack contains an invalid preserved notice.")
        paths.add(notice["path"])
        size = len(notice["text"].encode("utf-8"))
        if size > MAX_PACK_LEGAL_BYTES:
            raise ValueError("Search pack notice exceeds its limit.")
        combined += size
    if combined > MAX_PACK_COMBINED_LEGAL_BYTES:
        raise ValueError("Search pack combined attribution exceeds its limit.")


def pack_records(packed: bytes, manifest: dict[str, Any]):
    manifest = validate_pack_manifest(manifest)
    if (len(packed) != manifest["compressedBytes"] or len(packed) > MAX_PACK_BYTES
            or hashlib.sha256(packed).hexdigest() != manifest["sha256"]):
        raise ValueError("Search pack checksum or compressed size does not match.")
    expanded = count = 0
    seen = set()
    states, reasons = {}, {}
    try:
        with gzip.GzipFile(fileobj=io.BytesIO(packed), mode="rb") as stream:
            while True:
                line = stream.readline(min(MAX_PACK_RECORD_BYTES, MAX_PACK_EXPANDED - expanded) + 1)
                if not line:
                    break
                expanded += len(line)
                count += 1
                if (expanded > MAX_PACK_EXPANDED or expanded > manifest["uncompressedBytes"]
                        or len(line) > MAX_PACK_RECORD_BYTES or count > MAX_CATALOG_ROWS
                        or count > manifest["docCount"] or not line.endswith(b"\n")):
                    raise ValueError("Search pack expanded data exceeds its limits.")
                record = safe_json_loads(line, "Search pack record")
                if (not isinstance(record, dict) or not isinstance(record.get("state"), str)
                        or record["state"] not in {"indexed", "unavailable", "excluded"}
                        or not isinstance(record.get("body"), str) or len(record["body"]) > MAX_README_TEXT
                        or normalized(record["body"]) != record["body"]
                        or type(record.get("truncated")) is not bool
                        or not isinstance(record.get("license"), str) or len(record["license"]) > 100
                        or not isinstance(record.get("sourceSha256"), str)
                        or not isinstance(record.get("reason"), str) or not record["reason"] or len(record["reason"]) > 128
                        or not isinstance(record.get("path"), str) or len(record["path"]) > 256
                        or "\\" in record["path"] or record["path"].startswith("/")
                        or ".." in record["path"].split("/")):
                    raise ValueError("Search pack contains a malformed record.")
                states[record["state"]] = states.get(record["state"], 0) + 1
                reasons[record["reason"]] = reasons.get(record["reason"], 0) + 1
                repo = github_repo(record.get("repo"))
                commit = full_sha(record.get("commit"))
                key = record.get("key")
                compatible = (type(record.get("version")) is int and record["version"] == SEARCH_INDEX_VERSION
                              and repo is not None and repo[2] == record.get("repo")
                              and commit == record.get("commit") and bool(commit)
                              and key == readme_key({"repo": repo[2], "listingCommit": commit}))
                if not compatible:
                    yield None
                    continue
                if key in seen:
                    raise ValueError("Search pack contains duplicate document keys.")
                seen.add(key)
                if record["state"] != "indexed":
                    if record["body"] or record["sourceSha256"]:
                        raise ValueError("Excluded or unavailable search records must contain no README text.")
                else:
                    validate_pack_legal(record, repo, commit)
                yield record
    except (OSError, EOFError, zlib.error, UnicodeError) as error:
        raise ValueError("Search pack gzip data is invalid.") from error
    if expanded != manifest["uncompressedBytes"] or count != manifest["docCount"]:
        raise ValueError("Search pack expanded size or record count does not match.")
    if any(field in manifest and manifest[field] != counts
           for field, counts in (("stateCounts", states), ("reasonCounts", reasons))):
        raise ValueError("Search pack coverage counters do not match its records.")


def search_pack_state(store: Store, now: float | None = None) -> dict[str, Any]:
    now = time.time() if now is None else now
    result = {"state": "none", "generatedAt": "", "catalogGeneratedAt": "", "importedAt": 0,
              "lastAttemptAt": 0, "nextCheckAt": 0, "failures": 0, "docCount": 0, "documentCount": 0,
              "imported": 0, "skipped": 0, "interruptedAttempts": 0, "error": ""}
    try:
        with ReadmeIndex(store) as index:
            if index.db is not None and index.db.execute(
                    "SELECT 1 FROM sqlite_master WHERE name='search_pack_state'").fetchone():
                row = index.db.execute("SELECT value FROM search_pack_state WHERE id=1").fetchone()
                if row:
                    result.update(safe_json_loads(row[0].encode(), "Search pack receipt"))
    except (OSError, ValueError, sqlite3.Error):
        result.update(state="unavailable", error="Search pack state unavailable.")
    result["due"] = result["nextCheckAt"] <= now
    return result


def pack_coverage(index: ReadmeIndex, keys: set[str]) -> tuple[str, str]:
    """Proof of which catalog keys were considered and their retained index state.

    A matching asset alone is insufficient: an unchanged pack may contain a key
    that only became relevant after our previous import, or a pruned document.
    """
    catalog = hashlib.sha256(json.dumps(sorted(keys)).encode()).hexdigest()
    states = index.states(keys)
    coverage = hashlib.sha256(json.dumps(sorted(states.items())).encode()).hexdigest()
    return catalog, coverage


def prepare_search(store: Store, now: float, progress: Any = None) -> dict[str, Any]:
    emit = progress or (lambda *args, **kwargs: None)
    lock = os.open(".readme-index.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK,
                   0o600, dir_fd=store.fd)
    try:
        info = os.fstat(lock)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise ValueError("README index lock is not a private regular file.")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return {**search_pack_state(store, now), "busy": True}
        state = search_pack_state(store, now)
        # Only the exclusive lock proves that the previous preparer is gone.
        # Read-only status calls must not convert a live attempt into a retry.
        interrupted = state["state"] == "preparing" or (
            # Recover the old cold-start marker written before preparing existed.
            state["state"] == "none" and state["lastAttemptAt"] > 0
            and not state["importedAt"] and not state["failures"] and not state["error"])
        if not interrupted and not state["due"]:
            return state
        interruptions = (state["interruptedAttempts"] + 1
                         if interrupted and 0 <= now - state["lastAttemptAt"] <= SEARCH_PACK_INTERRUPTION_WINDOW
                         else 1 if interrupted else 0)
        with ReadmeIndex(store, create=True) as index:
            def receipt(value):
                index.db.execute("INSERT OR REPLACE INTO search_pack_state VALUES(1,?)",
                                 (json.dumps(value, separators=(",", ":")),))
            with index.db:
                index.db.execute("CREATE TABLE IF NOT EXISTS search_pack_state (id INTEGER PRIMARY KEY, value TEXT NOT NULL)")
                if interruptions > SEARCH_PACK_INTERRUPTED_RETRIES:
                    # Bound repeated abrupt worker crashes without hiding them as
                    # successful preparation or spinning through immediate retries.
                    state.update(state="error", interruptedAttempts=interruptions, due=False,
                                 nextCheckAt=now + 300,
                                 error="Public search preparation was repeatedly interrupted; retry in five minutes. Local search is retained.")
                else:
                    state.update(state="preparing", lastAttemptAt=now, nextCheckAt=now + 300,
                                 interruptedAttempts=interruptions, error="", due=False)
                receipt(state)
            if state["state"] == "error":
                return state
            try:
                emit("manifest", "Checking public search pack")
                manifest = validate_pack_manifest(safe_json_loads(
                    fetch_search_pack(SEARCH_PACK_URL, 64 * 1024), "Search pack manifest"))
                if state["generatedAt"] and listing_time(manifest["generatedAt"]) < listing_time(state["generatedAt"]):
                    raise ValueError("Search pack is older than the installed seed.")
                with store.scoped_lock(), index.db:
                    current = {readme_key(item) for item in load_catalog(store)[0]} - {""}
                    catalog_proof, coverage_proof = pack_coverage(index, current)
                    if (all(state.get(key) == value for key, value in manifest.items())
                            and state.get("packCatalogKeys") == catalog_proof
                            and state.get("packCoverage") == coverage_proof):
                        state.update(manifest, state="ready", lastAttemptAt=now,
                                     nextCheckAt=now + SEARCH_PACK_INTERVAL, failures=0,
                                     interruptedAttempts=0, error="", due=False)
                        receipt(state)
                        return state
                emit("download", "Downloading public search pack", bytesReceived=0,
                     bytesTotal=manifest["compressedBytes"])
                packed = fetch_search_pack(manifest["assetUrl"], MAX_PACK_BYTES,
                                           lambda **counts: emit("download", "Downloading public search pack",
                                                                 **{"bytesTotal": manifest["compressedBytes"], **counts}))
                imported = skipped = processed = 0
                emit("import", "Validating and staging search documents", processed=0,
                     total=manifest["docCount"], committed=0)
                # Gzip/checksum/legal validation runs outside the general cache
                # lock. A connection-private, disk-backed staging table bounds
                # memory and keeps malformed tails away from the live index.
                index.db.execute("PRAGMA temp_store=FILE")
                index.db.execute("CREATE TEMP TABLE pack_stage (record TEXT)")
                with index.db:
                    for record in pack_records(packed, manifest):
                        index.db.execute("INSERT INTO pack_stage VALUES(?)", (json.dumps(record, separators=(",", ":")),))
                # Serialize with catalog replacement, and re-read current keys only
                # after downloading. Never sync/prune against a seed's old catalog.
                with store.scoped_lock(), index.db:
                    current = {readme_key(item) for item in load_catalog(store)[0]} - {""}
                    states = index.states(current)
                    index.db.execute("CREATE TABLE IF NOT EXISTS search_pack_sources (key TEXT PRIMARY KEY, attribution TEXT NOT NULL)")
                    for staged in index.db.execute("SELECT record FROM pack_stage"):
                        record = json.loads(staged[0])
                        processed += 1
                        old = states.get(record["key"]) if record else None
                        if (record is None or record["key"] not in current
                                or (old and (old[1] > SEARCH_INDEX_VERSION
                                             or (old[1] == SEARCH_INDEX_VERSION and old[4])))):
                            skipped += 1
                        else:
                            key = record["key"]
                            existing = index.db.execute("SELECT rowid,body FROM documents WHERE key=?", (key,)).fetchone()
                            if existing and existing[1]:
                                index.db.execute("INSERT INTO readme_fts(readme_fts,rowid,body) VALUES('delete',?,?)", existing)
                            body = normalized(record["body"])[:MAX_README_TEXT]
                            kind = record["state"] if body or record["state"] != "indexed" else "unavailable"
                            index.db.execute("""INSERT INTO documents(key,body,state,version,truncated,path,retry_at)
                                VALUES(?,?,?,?,?,?,?) ON CONFLICT(key) DO UPDATE SET body=excluded.body,
                                state=excluded.state,version=excluded.version,truncated=excluded.truncated,
                                path=excluded.path,retry_at=excluded.retry_at""",
                                (key, body, kind, SEARCH_INDEX_VERSION, int(record["truncated"]), record["path"],
                                 now + 7 * 86400 if kind == "unavailable" else 0))
                            if body:
                                rowid = index.db.execute("SELECT rowid FROM documents WHERE key=?", (key,)).fetchone()[0]
                                index.db.execute("INSERT INTO readme_fts(rowid,body) VALUES(?,?)", (rowid, body))
                                index.db.execute("INSERT OR REPLACE INTO search_pack_sources VALUES(?,?)",
                                                 (key, json.dumps({field: value for field, value in record.items() if field != "body"},
                                                                  ensure_ascii=False, separators=(",", ":"))))
                            else:
                                index.db.execute("DELETE FROM search_pack_sources WHERE key=?", (key,))
                            imported += 1
                        if processed % 100 == 0:
                            emit("import", "Validating and staging search documents", processed=processed,
                                 total=manifest["docCount"], committed=0)
                    state.update(manifest, state="ready", importedAt=now, nextCheckAt=now + SEARCH_PACK_INTERVAL,
                                 documentCount=manifest["docCount"], imported=imported, skipped=skipped, failures=0,
                                 interruptedAttempts=0, error="", due=False)
                    state["packCatalogKeys"], state["packCoverage"] = pack_coverage(index, current)
                    receipt(state)
                emit("commit", "Search pack imported", processed=processed, total=manifest["docCount"],
                     committed=imported, skipped=skipped)
            except Exception:
                # The import transaction rolled back; the previous receipt remains
                # truthful even if a malformed final line cancelled a large import.
                # Ordinary unexpected failures also back off. Process cancellation
                # (SystemExit/KeyboardInterrupt) leaves preparing for lock-proven resume.
                state = search_pack_state(store, now)
                failures = min(10, state.get("failures", 0) + 1)
                state.update(state="error", failures=failures, error="Public search pack unavailable; local search is retained.",
                             interruptedAttempts=0, nextCheckAt=now + min(86400, 300 * 2 ** (failures - 1)), due=False)
                with index.db:
                    receipt(state)
        return search_pack_state(store, now)
    finally:
        os.close(lock)


def readme_index_stamp(store: Store) -> tuple[Any, ...]:
    # SHM is reader/writer coordination, not content: even read-only connections
    # update its lock metadata. Still invalidate if it becomes unsafe to open.
    shm = store.stamp("readme-search.sqlite-shm")
    unsafe_shm = shm if shm and (not stat.S_ISREG(shm[4]) or shm[5] != os.getuid()
                                or shm[3] > MAX_SEARCH_INDEX_BYTES + 4 * 1024 * 1024) else None
    return (SEARCH_INDEX_VERSION, unsafe_shm, store.stamp("readme-search.sqlite"),
            _readme_sidecar_stamp(store, "-wal"), _readme_sidecar_stamp(store, "-journal"))


def readme_index_snapshot(store: Store, keys: set[str] | None = None) -> tuple[dict[str, tuple], float]:
    stamp = readme_index_stamp(store)
    selection = frozenset(keys) if keys is not None else None
    cached = store.memory.get("indexSnapshot")
    if cached is not None and cached[0] == (stamp, selection):
        return cached[1], cached[2]
    with ReadmeIndex(store) as index:
        states = index.states(keys)
        retry = 0
        if index.db is not None:
            exists = index.db.execute("SELECT 1 FROM sqlite_master WHERE name='index_control'").fetchone()
            row = index.db.execute("SELECT value FROM index_control WHERE name='retry_after'").fetchone() if exists else None
            retry = row[0] if row else 0
    if readme_index_stamp(store) == stamp:
        store.memory["indexSnapshot"] = ((stamp, selection), states, retry)
    return states, retry


def lru_hit(cache: dict, key: Any) -> Any:
    value = cache.pop(key)
    cache[key] = value
    return value


def lru_put(cache: dict, key: Any, value: Any, capacity: int = 4) -> None:
    cache.pop(key, None)
    while len(cache) >= capacity:
        del cache[next(iter(cache))]
    cache[key] = value


def indexed_search_matches(store: Store, query: str, keys: set[str] | None = None) -> dict[str, dict[str, Any]]:
    stamp = readme_index_stamp(store)
    cache = store.memory.setdefault("indexQueries", {})
    key = (stamp, query, frozenset(keys) if keys is not None else None)
    if key in cache:
        return lru_hit(cache, key)
    with ReadmeIndex(store) as index:
        result = index.evidence(query, keys)
    if readme_index_stamp(store) == stamp:
        lru_put(cache, key, result)
    return result


def readme_index_data(store: Store, items: list[dict[str, Any]], query: str = "", now: float | None = None) -> dict[str, Any]:
    summary = {"eligible": 0, "indexed": 0, "pending": 0, "unavailable": 0,
               "failed": 0, "truncated": 0, "due": 0, "retryAt": 0, "error": ""}
    keys = {readme_key(item) for item in items} - {""}
    documents = {"total": len(keys), "indexed": 0, "processed": 0, "pending": len(keys),
                 "unavailable": 0, "failed": 0, "skipped": 0}
    summary["documents"] = documents
    for item in items:
        item.pop("_indexSearch", None)
    try:
        states, summary["retryAt"] = readme_index_snapshot(store, keys)
        for key in keys:
            kind, version, _attempts, _retry, has_text, _truncated = states.get(key, ("pending", 0, 0, 0, False, False))
            terminal = ("indexed" if has_text and version == SEARCH_INDEX_VERSION else
                        kind if kind in {"unavailable", "failed"} else "")
            # A seed exclusion is not a completed local check. It remains pending
            # and due; skipped is an informational subset of pending documents.
            if kind == "excluded" and not terminal:
                documents["skipped"] += 1
            if terminal:
                documents[terminal] += 1
                documents["processed"] += 1
                documents["pending"] -= 1
        matches = indexed_search_matches(store, query, keys) if query else {}
        now = time.time() if now is None else now
        for item in items:
            key = readme_key(item)
            if not key:
                continue
            summary["eligible"] += 1
            state = states.get(key, ("pending", 0, 0, 0, False, False))
            kind, version, _attempts, retry, has_text, truncated = state
            summary["indexed"] += int(bool(has_text))
            summary["truncated"] += int(bool(has_text and truncated))
            needs_update = kind != "indexed" or version != SEARCH_INDEX_VERSION
            if needs_update:
                summary[kind if kind in {"failed", "unavailable"} else "pending"] += 1
                summary["due"] += int(retry <= now)
            if query and has_text:
                item["_indexSearch"] = (query, matches.get(key))
    except (OSError, sqlite3.Error, ValueError):
        summary["error"] = "README search index unavailable. Cached listing search still works; retry indexing from More actions."
    return summary


@functools.lru_cache(maxsize=2048)
def literal_pattern(term: str) -> re.Pattern[str]:
    # Literal phrases, not substring searches or English stemming. Unicode word
    # boundaries also prevent e.g. "air" claiming "airpods" as an exact hit.
    return re.compile(r"(?<!\w)" + re.escape(normalized(term)) + r"(?!\w)")


def criteria_semantics(criteria: list[dict[str, Any]], revision: int | None = None) -> bytes:
    """Stable across validation/JSON round trips, including edits under the same ID."""
    if not criteria and revision is None:
        return b""
    selected = {item.get("serviceId") for item in criteria if item.get("enabled")}
    payload = (revision, [(item.get("id"), item.get("kind"), item.get("label"), item.get("terms", []),
                          item.get("serviceId", ""), item.get("featureId", ""), item.get("enabled") is True)
                         for item in criteria],
               [service for service in load_service_registry() if service["id"] in selected])
    return hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()).digest()


def interest_evidence_key(item: dict[str, Any], include_readme: bool) -> tuple[Any, ...]:
    criteria = item.get("_criteriaKey")
    if criteria is None:
        criteria = criteria_semantics(item.get("_interestCriteria", []))
    return (criteria, item.get("listingCommit", ""), readme_key(item) if include_readme else "",
            frozenset(item.get("_literalReadme", ())) if include_readme else frozenset())


def attach_interest_evidence(store: Store, items: list[dict[str, Any]], criteria: list[dict[str, Any]],
                             profile: list[dict[str, Any]], include_readme: bool,
                             criteria_revision: int | None = None) -> bool:
    criteria_key = criteria_semantics(criteria, criteria_revision)
    terms = {normalized(term["value"]) for signal in profile for term in signal.get("terms", [])}
    for criterion in criteria:
        if not criterion["enabled"]:
            continue
        if criterion["serviceId"]:
            choice = next(item for item in load_service_registry() if item["id"] == criterion["serviceId"])
            terms.update(choice["terms"])
        else:
            terms.update(criterion["terms"])
    terms.discard("")
    terms = set(sorted(terms)[:2048])
    keys = {readme_key(item) for item in items} - {""}
    found, states = {}, {}
    failed = False
    if include_readme and terms:
        cache_key = (readme_index_stamp(store),
                     tuple(sorted(keys)), tuple(sorted(terms)))
        cache = store.memory.setdefault("interestReadmes", {})
        cached = cache.get(cache_key)
        if cached is not None:
            found, states = lru_hit(cache, cache_key)
        else:
            # One bounded corpus pass, with a single compiled matcher rather than
            # 64 interests x 4 phrases x every complete README. Overlapping phrases
            # at the same offset are expanded from their longest literal match.
            ordered = sorted(terms, key=lambda value: (-len(value), value))
            matcher = re.compile(r"(?=(?<!\w)(" + "|".join(re.escape(term) for term in ordered) + r")(?!\w))")
            expansions = {term: tuple(other for other in terms if literal_pattern(other).match(term))
                          for term in terms}
            try:
                states, _retry = readme_index_snapshot(store, keys)
                with ReadmeIndex(store) as index:
                    if index.db is not None:
                        if all(len(term) >= 3 for term in terms):
                            expression = " OR ".join('"' + trigram.replace('"', '""') + '"'
                                                     for trigram in sorted({term[:3] for term in terms}))
                            rows = index.document_rows("""SELECT d.key,d.body,d.version FROM readme_fts f
                                JOIN documents d ON d.rowid=f.rowid WHERE readme_fts MATCH ?""", (expression,), keys)
                        else:
                            rows = index.document_rows("SELECT d.key,d.body,d.version FROM documents d WHERE d.body<>''", keys=keys)
                        for key, body, version in rows:
                            if key not in keys or version != SEARCH_INDEX_VERSION:
                                continue
                            hits = {term for match in matcher.finditer(body[:MAX_README_TEXT])
                                    for term in expansions[match[1]]}
                            if hits:
                                found[key] = sorted(hits)
            except (ValueError, OSError, sqlite3.Error):
                failed = True
            # A transient lock/error is not a stable empty corpus. A write racing
            # this snapshot must also be observed by the very next query.
            if not failed and readme_index_stamp(store) == cache_key[0]:
                lru_put(cache, cache_key, (found, states))
    partial = failed
    for item in items:
        key = readme_key(item)
        state = states.get(key)
        complete = not terms or not key or bool(include_readme and state and (
            (state[0] == "indexed" and state[1] == SEARCH_INDEX_VERSION and not state[5]) or
            (state[0] == "unavailable" and not state[4])))
        item["_literalReadme"] = frozenset(found.get(key, ())) if include_readme else frozenset()
        item["_interestCriteria"] = criteria
        item["_criteriaKey"] = criteria_key
        item["_readmeComplete"] = complete and not failed
        item["_interestReadmeFailed"] = failed
        item["_interestReadmeRetry"] = bool(key and (not include_readme or (state and state[0] == "failed")))
        if include_readme and key and not complete:
            partial = True
    return partial


def matched_interests(item: dict[str, Any], include_readme: bool = True) -> list[dict[str, Any]]:
    fields = _normalized_item_fields(item, include_readme)
    source = (include_readme, item.get("_normalizedSource"), item.get("_readme", "") if include_readme else "",
              interest_evidence_key(item, include_readme))
    cache = item.setdefault("_interestMatchCache", {})
    if source in cache:
        return cache[source]
    readme_terms = item.get("_literalReadme", set()) if include_readme else set()
    registry = {choice["id"]: choice for choice in load_service_registry()}
    output = []
    for criterion in item.get("_interestCriteria", []):
        if not criterion["enabled"]:
            continue
        service = registry.get(criterion["serviceId"])
        hit = None
        if service:
            if item["id"] in service["excludePluginIds"]:
                continue
            if item["id"] in service["includePluginIds"]:
                hit = ("curated", service["name"], "curated")
            else:
                # Name-only aliases never leak into descriptions or README text.
                for term in service["nameTerms"]:
                    if literal_pattern(term).search(fields["name"]):
                        hit = ("name", term, "exact")
                        break
        terms = service["terms"] if service else criterion["terms"]
        allowed_fields = ("name", "tags", "description", "readme") if service else tuple(fields)
        if hit is None:
            for field in allowed_fields:
                for term in terms:
                    haystacks = [normalized(tag) for tag in item.get("tags", [])] if field == "tags" and not service else [fields.get(field, "")]
                    if any(literal_pattern(term).search(text) for text in haystacks) or (field == "readme" and term in readme_terms):
                        hit = ("README" if field == "readme" else field, term, "exact")
                        break
                if hit:
                    break
        if hit:
            field, term, kind = hit
            reason = (f"Saved interest: {criterion['label']}; curated integration" if kind == "curated" else
                      f"Saved interest: {criterion['label']}; {field} contains exact phrase “{term}”")
            output.append({"id": criterion["id"], "label": criterion["label"], "reason": reason,
                           "field": field, "term": term, "origin": "user", "matchType": kind,
                           "revision": item.get("listingCommit", "")})
    if len(cache) >= 4:
        cache.clear()
    cache[source] = output
    return output


def listing_fingerprint(item: dict[str, Any]) -> str:
    # Popularity counters and cached README enrichment are not listing changes.
    values = [item.get(key) for key in ("id", "name", "description", "tags", "category", "kind", "repo", "listingCommit")]
    return hashlib.sha256(json.dumps(values, sort_keys=True).encode()).hexdigest()[:24]


def criterion_fingerprint(item: dict[str, Any]) -> str:
    return hashlib.sha256(json.dumps(validate_criterion(item), sort_keys=True).encode()).hexdigest()[:24]


def validate_review(review: Any) -> None:
    if not isinstance(review, dict):
        raise ValueError("Invalid match review state; existing state was preserved.")
    ids, rows = review.get("ids", []), review.get("rows", {})
    if (not isinstance(ids, list) or len(ids) > MAX_INTERESTS or any(not criterion_id(value) for value in ids)
            or len(set(ids)) != len(ids)
            or not isinstance(rows, dict) or len(rows) > MAX_CATALOG_ROWS
            or not isinstance(review.get("signatures", {}), dict)):
        raise ValueError("Invalid match review state; existing state was preserved.")
    for identity, row in rows.items():
        if (not plugin_id(identity) or not isinstance(row, dict)
                or any(not isinstance(row.get(key), str) or not re.fullmatch(r"[0-9a-f]{1,16}", row[key]) for key in ("m", "u"))
                or type(row.get("t")) not in (int, float) or not math.isfinite(row["t"])):
            raise ValueError("Invalid match review entry; existing state was preserved.")
        if "p" in row and (not isinstance(row["p"], str) or not re.fullmatch(r"[0-9a-f]{1,16}", row["p"])):
            raise ValueError("Invalid pending match baseline; existing state was preserved.")


def evaluate_inbox(document: dict[str, Any], items: list[dict[str, Any]], now: float,
                   catalog_ready: bool) -> dict[str, Any]:
    """Compact per-listing bitsets; no profile, README text, or browsing history."""
    prior = document.get("review") if isinstance(document.get("review"), dict) else {}
    if not catalog_ready or any(item.get("_interestReadmeFailed") for item in items):
        return prior
    criteria = document["criteria"]
    signatures = {item["id"]: criterion_fingerprint(item) for item in criteria}
    old_ids = prior.get("ids", [])
    same = {identity for identity in signatures if prior.get("signatures", {}).get(identity) == signatures[identity]}
    positions = {item["id"]: index for index, item in enumerate(criteria)}
    def remap(mask):
        mask = int(mask or "0", 16)
        return sum(1 << positions[identity] for index, identity in enumerate(old_ids)
                   if mask & (1 << index) and identity in same)
    baseline = prior.get("baseline") is True
    unchanged_mask = sum(1 << positions[identity] for identity in same)
    changed_mask = ((1 << len(criteria)) - 1) & ~unchanged_mask
    rows = {}
    old_rows = prior.get("rows", {})
    for item in items[:MAX_CATALOG_ROWS]:
        if item.get("localOnly"):
            continue
        identity = item["id"]
        old = old_rows.get(identity, {})
        before = remap(old.get("m"))
        unread = remap(old.get("u"))
        pending = remap(old.get("p"))
        actual = sum(1 << positions[match["id"]] for match in matched_interests(item, item.get("_showReadme") is True))
        # Failed/missing/truncated README checks cannot prove disappearance.
        current = actual | (before if not item.get("_readmeComplete") else 0)
        fresh = (actual & ~before & unchanged_mask & ~pending) if baseline else 0
        if item.get("_interestReadmeRetry"):
            # A failed initial document check is not an empty baseline. Its
            # first successful result establishes the baseline for new/edited
            # criteria, while already-confirmed criteria keep their history.
            pending |= changed_mask & ~actual
        pending &= ~actual
        if item.get("_readmeComplete"):
            pending = 0
        fingerprint = listing_fingerprint(item)
        cause = old.get("c", "")
        when = old.get("t", 0)
        if fresh:
            cause = "new-listing" if not old else "listing-changed" if old.get("l") != fingerprint else "readme-match"
            unread |= fresh
            when = now
        unread &= current
        rows[identity] = {**old, "l": fingerprint, "m": format(current, "x"), "u": format(unread, "x"),
                          "p": format(pending, "x"), "c": cause if unread or old.get("c") else "", "t": when}
    return {**prior, "baseline": True, "ids": list(positions), "signatures": signatures,
            "rows": rows, "lastCheckedAt": now}


def inbox_response(items: list[dict[str, Any]], document: dict[str, Any], request: dict[str, Any],
                   installed: set[str], partial: bool, profile: list[dict[str, Any]]) -> dict[str, Any]:
    review = document.get("review", {})
    entries = review.get("rows", {})
    selected = []
    unread_count = 0
    group_max_stars: dict[str, int] = {}
    for item in items:
        # Use the unfiltered Browse reference population, not the current inbox
        # page/unread subset. Reviewing an entry must not renormalize its Rec.
        group = setup_group(item, item.get("_showReadme") is True)
        stars = item.get("stars") if type(item.get("stars")) is int else 0
        group_max_stars[group] = max(group_max_stars.get(group, 0), stars)
        matches = matched_interests(item, item.get("_showReadme") is True)
        entry = entries.get(item["id"], {})
        unread = bool(int(entry.get("u", "0"), 16))
        # Do not render a vanished/failed match as fresh evidence.
        if not matches:
            continue
        unread_count += int(unread)
        if request.get("unreadOnly") is True and not unread:
            continue
        selected.append((item, matches, entry, unread, group, stars))
    selected.sort(key=lambda row: (-int(row[3]), -row[2].get("t", 0), normalized(row[0]["name"]), row[0]["id"]))
    total = len(selected)
    page_count = max(1, math.ceil(total / 50))
    page = request.get("page", 1)
    page = min(page_count, max(1, page)) if type(page) is int else 1
    rows = []
    profile_key = _profile_key(profile)
    for item, matches, entry, unread, group, stars in selected[(page - 1) * 50:page * 50]:
        details = recommendation_details(item, profile, item.get("_showReadme") is True, profile_key)
        popularity, recommendation = recommendation_metrics(stars, group_max_stars[group], details)
        row = public_row(item, details["score"], details["reason"] or matches[0]["reason"], installed, details)
        row.update(matchCause=entry.get("c") or "baseline", unread=unread, setupGroup=group,
                   popularityScore=popularity, recommendationScore=recommendation)
        rows.append(row)
    return {"rows": rows, "total": total, "unread": unread_count, "lastCheckedAt": review.get("lastCheckedAt", 0),
            "partial": partial, "page": page, "pageCount": page_count}


def interest_action(request: dict[str, Any], store: Store, preferences_store: Store,
                    preferences: dict[str, Any], now: float, generation: int) -> dict[str, Any]:
    action = request["action"]
    document = load_interests(preferences_store, preferences)
    # A save contains only its scoped draft. Retain the last supplied context in
    # this worker's memory so its response does not clear detected setup rows.
    context = dict(store.memory.get("interestContext", {}))
    for key in ("profile", "scan", "unavailable", "hasAnalyzed", "inventory"):
        if key in request:
            context[key] = request[key]
    context["scan"] = supplied_scan(request, context.get("scan"))
    if "profile" not in request and "observations" in context["scan"]:
        context["profile"] = context["scan"]["observations"]
    context["profile"] = validate_profile(context.get("profile", []))
    context["inventory"] = validate_inventory(context.get("inventory", []))
    context["unavailable"] = [one_line(value, 80) for value in context.get("unavailable", [])[:32]] \
        if isinstance(context.get("unavailable", []), list) else []
    inputs = context_inputs(document, context)
    context["scan"] = {"state": inputs["scanState"], "checkedAt": inputs["checkedAt"], "probes": inputs["probes"]}
    store.memory["interestContext"] = context
    request = {**request, **context}
    base = {"ok": True, "action": action, "generation": generation, "criteriaRevision": document["revision"]}
    if action == "context":
        return {**base, "inputs": context_inputs(document, request), "preferences": load_preferences(preferences_store)}
    try:
        items, fetched, _generated = load_catalog(store)
        catalog_ready = bool(fetched and store.stamp("catalog.json"))
    except (OSError, ValueError):
        items, catalog_ready = [], False
    inventory = validate_inventory(request.get("inventory"))
    items = merge_inventory(items, inventory)
    installed = {item["id"] for item in inventory}
    try:
        readmes = load_readmes(store)
    except (OSError, ValueError):
        readmes = {}
    attach_cached_readmes(items, readmes)
    include_readme = preferences["readmeEnrichment"]
    for item in items:
        item["_showReadme"] = include_readme
    if action == "preview-interest":
        criterion = validate_criterion(request.get("criterion"), {item["id"] for item in document["criteria"]})
        criterion["enabled"] = True
        partial = attach_interest_evidence(store, items, [criterion], [], include_readme) or not catalog_ready
        rows = [{"id": item["id"], "name": item["name"], "reason": matches[0]["reason"], "matchedInterests": matches}
                for item in items if (matches := matched_interests(item, include_readme))]
        rows.sort(key=lambda row: (normalized(row["name"]), row["id"]))
        return {**base, "preview": {"rows": rows[:50], "total": len(rows), "partial": partial}}
    # The authoritative revision and review baseline are written in ONE atomic
    # replace under the same lock. Preferences/settings cannot overwrite this file.
    with preferences_store.scoped_lock():
        latest = preferences_store.read("interests.json", MAX_INTEREST_STATE, document)
        document = validate_interest_document(latest)
        if action == "save-interests":
            if type(request.get("revision")) is not int or request["revision"] != document["revision"]:
                raise ValueError("Interests changed in another window. Reload context before saving (stale revision).")
            values, ignored = request.get("criteria"), request.get("ignoredSignals")
            if not isinstance(values, list) or len(values) > MAX_INTERESTS:
                raise ValueError("Save at most 64 interests.")
            known = set(FEATURES) | {"dock-like"} | {"capability-" + key for key in CAPABILITIES}
            if (not isinstance(ignored, list) or len(ignored) > 64 or
                    any(not isinstance(value, str) or value not in known for value in ignored)):
                raise ValueError("Unknown detected signal override.")
            existing = {item["id"] for item in document["criteria"]}
            criteria = [validate_criterion(value, existing) for value in values]
            if len({item["id"] for item in criteria}) != len(criteria):
                raise ValueError("Interest IDs must be unique.")
            previous = {item["id"]: item for item in document["criteria"]}
            criteria = [{**previous.get(item["id"], {}), **item} for item in criteria]
            document = {**document, "criteria": criteria, "ignoredSignals": sorted(set(ignored)),
                        "revision": document["revision"] + 1}
        profile = [item for item in detected_profile(request.get("profile"))
                   if item["id"] not in document["ignoredSignals"]]
        # Context terms nominate README evidence for row metrics. Inbox eligibility
        # and event bitsets still consult only matched_interests (saved criteria).
        partial = attach_interest_evidence(store, items, document["criteria"], profile, include_readme, document["revision"]) or not catalog_ready
        if action != "review-matches":
            document = {**document, "review": evaluate_inbox(document, items, now, catalog_ready)}
        else:
            ids = request.get("pluginIds")
            if request.get("all") is not True and (not isinstance(ids, list) or len(ids) > MAX_CATALOG_ROWS or
                    any(not isinstance(value, str) or plugin_id(value) != value for value in ids)):
                raise ValueError("Choose active match IDs to acknowledge.")
            active = {item["id"] for item in items if matched_interests(item, include_readme)}
            acknowledge = active if request.get("all") is True else active & set(ids)
            review = document.get("review", {})
            document = {**document, "review": {**review, "rows": {
                identity: {**entry, "u": "0"} if identity in acknowledge else entry
                for identity, entry in review.get("rows", {}).items()}}}
        preferences_store.write("interests.json", document, MAX_INTEREST_STATE)
    result = {**base, "criteriaRevision": document["revision"],
              "matches": inbox_response(items, document, request, installed, partial, profile)}
    if action == "save-interests":
        result.update(inputs=context_inputs(document, request), preferences=load_preferences(preferences_store))
    return result


def fetch_search_readme(item: dict[str, Any]) -> dict[str, Any]:
    repository = github_repo(item.get("repo"))
    commit = full_sha(item.get("listingCommit"))
    if not repository or not commit:
        return {"ok": False, "unavailable": True}
    deadline = time.monotonic() + 20
    for path in ("README.md", "readme.md", "README.MD", ".github/README.md", "docs/README.md", "README.rst"):
        budget = min(10, deadline - time.monotonic())
        if budget <= 0:
            break
        url = f"https://raw.githubusercontent.com/{repository[0]}/{repository[1]}/{commit}/{path}"
        try:
            body = fetch_bytes(url, "raw.githubusercontent.com", MAX_README_BYTES, budget)
        except urllib.error.HTTPError as error:
            if error.code == 404:
                error.close()
                continue
            delay = 900 if error.code in {403, 429} else 0
            raw_delay = error.headers.get("Retry-After", "") if error.headers else ""
            if raw_delay.isdigit():
                delay = max(delay, min(86400, int(raw_delay[:8])))
            error.close()
            return {"ok": False, "cooldown": delay}
        except (OSError, TimeoutError, urllib.error.URLError, ValueError):
            return {"ok": False}
        source = body.decode("utf-8", errors="replace")
        content = markdown_content(source)
        return {"ok": True, "searchText": content, "path": path,
                "truncated": len(content) >= MAX_README_TEXT}
    else:
        return {"ok": False, "unavailable": True}
    return {"ok": False}


def index_readmes(store: Store, items: list[dict[str, Any]], now: float, progress: Any = None) -> dict[str, Any]:
    lock = os.open(".readme-index.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600, dir_fd=store.fd)
    try:
        info = os.fstat(lock)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise ValueError("README index lock is not a private regular file.")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return readme_index_data(store, items, now=now)
        with ReadmeIndex(store, create=True) as index:
            try:
                cached = load_readmes(store)
            except ValueError:
                cached = {}
            index.sync(items, cached, now, prune=store.memory.get("catalogSource") != "bundled")
            control = index.db.execute("SELECT value FROM index_control WHERE name='retry_after'").fetchone()
            if control and control[0] > now:
                return readme_index_data(store, items, now=now)
            states = index.states({readme_key(item) for item in items} - {""})
            selected = {}
            for item in sorted(items, key=lambda value: states.get(readme_key(value), ("", 0, 0))[2]):
                key = readme_key(item)
                if key not in states:
                    continue
                kind, version, _attempts, retry, _text, _truncated = states[key]
                if (kind != "indexed" or version != SEARCH_INDEX_VERSION) and retry <= now:
                    selected.setdefault(key, item)
                if len(selected) >= README_FETCH_LIMIT:
                    break
            failed = 0
            cooldown = 0
            completed = 0
            documents = readme_index_data(store, items, now=now)["documents"] if progress is not None else None

            def progress_state(state):
                kind, version, _attempts, _retry, has_text, _truncated = state
                terminal = ("indexed" if has_text and version == SEARCH_INDEX_VERSION else
                            kind if kind in {"unavailable", "failed"} else "")
                return terminal or "pending", bool(kind == "excluded" and not terminal)

            with concurrent.futures.ThreadPoolExecutor(max_workers=README_WORKERS) as executor:
                futures = {executor.submit(fetch_search_readme, item): key for key, item in selected.items()}
                for future in concurrent.futures.as_completed(futures):
                    try:
                        document = future.result()
                    except Exception:
                        document = {"ok": False}
                    # Commit each finished document, so interruption retains progress.
                    index.put(futures[future], document, now)
                    completed += 1
                    if progress is not None:
                        key = futures[future]
                        latest = index.states({key})[key]
                        for state, delta in ((states[key], -1), (latest, 1)):
                            kind, skipped = progress_state(state)
                            documents[kind] += delta
                            documents["processed"] += delta * int(kind != "pending")
                            documents["skipped"] += delta * int(skipped)
                        states[key] = latest
                        progress("index", "README document checked", processed=documents["processed"],
                                 total=documents["total"], indexed=documents["indexed"], committed=completed,
                                 batchProcessed=completed, batchTotal=len(selected), documents=dict(documents))
                    failed += int(not document.get("ok") and not document.get("unavailable"))
                    cooldown = max(cooldown, min(86400, max(0, int(document.get("cooldown", 0)))))
                    if cooldown:
                        with index.db:
                            index.db.execute("INSERT OR REPLACE INTO index_control VALUES('retry_after',?)", (now + cooldown,))
            if selected and failed == len(selected):
                cooldown = max(cooldown, 300)
            with index.db:
                index.db.execute("INSERT OR REPLACE INTO index_control VALUES('retry_after',?)", (now + cooldown if cooldown else 0,))
        return readme_index_data(store, items, now=now)
    except sqlite3.Error as error:
        if getattr(error, "sqlite_errorcode", 0) == sqlite3.SQLITE_FULL:
            raise ValueError("README index storage is full or reached its 256 MiB limit. Free space before resuming.") from error
        if getattr(error, "sqlite_errorcode", 0) in {sqlite3.SQLITE_CORRUPT, sqlite3.SQLITE_NOTADB}:
            raise ValueError("README search database is damaged. Close Outfit and remove readme-search.sqlite from its cache to rebuild.") from error
        raise ValueError("README indexing could not access its search database. Retry when storage is available.") from error
    finally:
        os.close(lock)


def load_readmes(store: Store) -> dict[str, dict[str, Any]]:
    memory = getattr(store, "memory", {})
    stamp = store.stamp("readmes.json")
    if isinstance(memory.get("readmes"), dict) and stamp == memory.get("readmesStamp"):
        return dict(memory["readmes"])
    raw = store.read("readmes.json", MAX_CACHE_BYTES, {"schema": README_SCHEMA, "entries": {}})
    if not isinstance(raw, dict) or raw.get("schema") != README_SCHEMA or not isinstance(raw.get("entries"), dict):
        raise ValueError("Outfit README index is invalid; refresh it to rebuild.")
    entries: dict[str, dict[str, Any]] = {}
    for identity, entry in list(raw["entries"].items())[:MAX_README_ENTRIES]:
        if not plugin_id(identity) or not isinstance(entry, dict):
            continue
        commit = full_sha(entry.get("commit"))
        content = clean(entry.get("content"), MAX_README_TEXT)
        text = one_line(entry.get("text"), MAX_README_TEXT) or one_line(content, MAX_README_TEXT)
        summary = clean(entry.get("summary"), MAX_README_SUMMARY)
        media = validate_readme_media(entry.get("media"))
        content_version = entry.get("contentVersion")
        fetched = entry.get("fetchedAt")
        if commit and type(fetched) in (int, float):
            entries[identity] = {
                "commit": commit,
                "text": text,
                "content": content or text,
                "summary": summary or readme_summary(content or text),
                "media": media,
                "contentVersion": content_version if type(content_version) is int else 0,
                "documentVersion": entry.get("documentVersion", 0),
                "documentSource": readme_source(entry.get("documentSource")),
                "fetchedAt": fetched,
            }
    memory["readmes"] = entries
    memory["readmesStamp"] = stamp
    return dict(entries)


def save_readmes(store: Store, entries: dict[str, dict[str, Any]]) -> dict[str, dict[str, Any]]:
    """Merge fetched entries into fresh disk state; callers fetch outside the lock.

    Older snapshots cannot overwrite a newer fetch, even for the same ID.
    Returns the merged cache for callers that need to attach display metadata.
    """
    with store.scoped_lock():
        store.memory.pop("readmes", None)
        try:
            latest = load_readmes(store)
        except ValueError:
            latest = {}
        for identity, entry in entries.items():
            if entry.get("fetchedAt", 0) >= latest.get(identity, {}).get("fetchedAt", 0):
                latest[identity] = entry
        _write_readmes(store, latest)
        return load_readmes(store)


def _write_readmes(store: Store, entries: dict[str, dict[str, Any]]) -> None:
    retained = sorted(entries.items(), key=lambda item: item[1].get("fetchedAt", 0), reverse=True)[:MAX_README_ENTRIES]
    compact: dict[str, dict[str, Any]] = {}
    for identity, entry in retained:
        version = entry.get("contentVersion", 0)
        stored = {
            "commit": entry.get("commit", ""),
            "summary": entry.get("summary", ""),
            "media": validate_readme_media(entry.get("media")),
            "contentVersion": version,
            "documentVersion": entry.get("documentVersion", 0),
            "documentSource": readme_source(entry.get("documentSource")),
            "fetchedAt": entry.get("fetchedAt", 0),
        }
        if version == README_CONTENT_VERSION:
            stored["content"] = entry.get("content", "")
            stored["text"] = entry.get("text", "")
        else:
            stored["text"] = entry.get("text", "")
        compact[identity] = stored
    # The independently versioned presentation adds bounded data to each entry.
    # Retain the newest documents within the existing total cache budget too.
    budget = MAX_CACHE_BYTES - 1024
    for identity in list(compact):
        size = len(json.dumps({identity: compact[identity]}, ensure_ascii=True).encode("utf-8")) + 2
        if size > budget:
            del compact[identity]
        else:
            budget -= size
    value = {"schema": README_SCHEMA, "entries": compact}
    try:
        previous = store.read("readmes.json", MAX_CACHE_BYTES, None)
    except ValueError:
        previous = None
    if value != previous:
        store.write("readmes.json", value, MAX_CACHE_BYTES)


def attach_cached_readmes(items: list[dict[str, Any]], entries: dict[str, dict[str, Any]]) -> None:
    for item in items:
        cached = entries.get(item["id"])
        current = bool(cached and cached.get("commit") == item.get("listingCommit"))
        item["_readme"] = cached["text"] if current else ""
        item["_readmeSummary"] = cached.get("summary", "") if current else ""
        item["_readmeContent"] = cached.get("content", "") if current else ""
        item["_readmeContentVersion"] = cached.get("contentVersion", 0) if current else 0
        item["_readmeIndexed"] = current
        item["_readmeMedia"] = validate_readme_media(cached.get("media")) if current else []
        item["_readmeMediaIndexed"] = bool(
            current and cached.get("contentVersion", 0) >= README_CONTENT_VERSION
        )


def enrich_readmes(store: Store, candidates: list[dict[str, Any]], entries: dict[str, dict[str, Any]]) -> int:
    missing = [
        item for item in candidates
        if item.get("listingCommit")
        and not (
            entries.get(item["id"], {}).get("commit") == item.get("listingCommit")
            and entries.get(item["id"], {}).get("contentVersion") == README_CONTENT_VERSION
        )
    ][:README_FETCH_LIMIT]
    if not missing:
        return 0
    now = time.time()
    fetched = 0
    updates = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=README_WORKERS) as executor:
        futures = {executor.submit(fetch_readme, item): item for item in missing}
        for future in concurrent.futures.as_completed(futures):
            item = futures[future]
            try:
                document = future.result()
            except Exception:
                document = {"ok": False}
            if not document or document.get("ok") is not True:
                continue
            updates[item["id"]] = {
                "commit": item["listingCommit"],
                "text": document["text"],
                "content": document["content"],
                "summary": document["summary"],
                "media": validate_readme_media(document.get("media")),
                "contentVersion": README_CONTENT_VERSION,
                "documentVersion": document.get("documentVersion", 0),
                "documentSource": readme_source(document.get("documentSource")),
                "fetchedAt": now,
            }
            fetched += 1
    if updates:
        merged = save_readmes(store, updates)
        entries.clear()
        entries.update(merged)
    return fetched


@functools.lru_cache(maxsize=4096)
def _term_patterns(phrase: str) -> tuple[re.Pattern[str], tuple[re.Pattern[str], ...]]:
    exact = re.compile(r"(?<![a-z0-9])" + re.escape(phrase) + r"(?:s|es)?(?![a-z0-9])")
    tokens = tuple(
        re.compile(r"(?<![a-z0-9])" + re.escape(token) + r"(?:s|es|ing|ed)?(?![a-z0-9])")
        for token in _tokens(phrase)
    )
    return exact, tokens


def _normalized_item_fields(item: dict[str, Any], include_readme: bool) -> dict[str, str]:
    source = (
        item.get("name", ""), item.get("id", ""), tuple(item.get("tags", [])),
        item.get("category", ""), item.get("description", ""),
    )
    cached = item.get("_normalizedFields")
    base_changed = not isinstance(cached, dict) or item.get("_normalizedSource") != source
    if base_changed:
        cached = {
            "name": normalized(source[0]),
            "id": normalized(source[1]),
            "tags": normalized(" ".join(source[2])),
            "category": normalized(source[3]),
            "description": normalized(source[4]),
        }
        item["_normalizedFields"] = cached
        item["_normalizedSource"] = source
    if not include_readme:
        return cached
    readme_source = item.get("_readme", "")
    shared = item.setdefault("_readmeFieldsCache", {})
    key = (source, readme_source)
    readme_fields = shared.get("fields") if shared.get("key") == key else None
    if readme_fields is None:
        readme_fields = dict(cached)
        readme_fields["readme"] = normalized(readme_source)
        shared.update(key=key, fields=readme_fields)
    return readme_fields


@functools.lru_cache(maxsize=512)
def _service_term_pattern(term: str) -> re.Pattern[str]:
    return re.compile(r"(?<![a-z0-9])" + re.escape(term) + r"(?![a-z0-9])")


def service_matches(item: dict[str, Any]) -> list[dict[str, str]]:
    fields = _normalized_item_fields(item, False)
    source = item.get("_normalizedSource")
    cached = item.get("_serviceMatches")
    if item.get("_serviceMatchesSource") == source and isinstance(cached, list):
        return cached

    identity = item.get("id", "")
    output: list[dict[str, str]] = []
    for service in load_service_registry():
        if identity in service["excludePluginIds"]:
            continue
        reason = ""
        if identity in service["includePluginIds"]:
            reason = f"Curated {service['name']} integration"
        elif any(_service_term_pattern(term).search(fields["name"]) for term in service["nameTerms"]):
            reason = f"{service['name']} integration"
        else:
            for term in service["terms"]:
                pattern = _service_term_pattern(term)
                if pattern.search(fields["name"]):
                    reason = f"{service['name']} integration"
                elif pattern.search(fields["tags"]):
                    reason = f"Tagged for {service['name']}"
                elif pattern.search(fields["description"]):
                    reason = f"Mentions {service['name']} support"
                if reason:
                    break
        if reason:
            output.append({
                "id": service["id"],
                "name": service["name"],
                "reason": reason,
            })
    item["_serviceMatchesSource"] = source
    item["_serviceMatches"] = output
    return output


@functools.lru_cache(maxsize=8192)
def _normalized_phrase(value: str) -> str:
    return normalized(value)


@functools.lru_cache(maxsize=512)
def _search_parts(query: str) -> tuple[str, tuple[str, ...]]:
    phrase = _normalized_phrase(query)
    tokens = tuple(dict.fromkeys(re.findall(r"[^\W_]+(?:\+{1,2})?", phrase)))
    # Stopword-only queries remain literal searches, never an unfiltered browse.
    return phrase, tuple(word for word in tokens if word not in STOP_WORDS) or tokens


@functools.lru_cache(maxsize=2048)
def _search_word_pattern(word: str, prefix: bool = False) -> re.Pattern[str]:
    return re.compile(r"(?<!\w)" + re.escape(word) + (r"\w*" if prefix else r"(?!\w)"))


def _search_text_evidence(text: str, query: str) -> dict[str, Any]:
    """Small evidence records, never retained README bodies or HTML excerpts."""
    phrase, words = _search_parts(query)
    positions = []
    matched = []
    token_windows = []
    for word in words:
        pattern = _search_word_pattern(word)
        first = pattern.search(text)
        if first:
            matched.append(word)
            token_windows.append((word, first.start(), first.end()))
            # Bound proximity work in repetitive documents; membership is exact.
            for index, match in enumerate(pattern.finditer(text)):
                positions.append((match.start(), match.end(), word))
                if index >= 31:
                    break
    positions.sort()
    window = (positions[0][0], positions[0][1]) if positions else (0, 0)
    counts, left, width = {}, 0, len(text) + 1
    for right, (start, end, word) in enumerate(positions):
        counts[word] = counts.get(word, 0) + 1
        while len(counts) == len(matched) and left <= right:
            if end - positions[left][0] < width:
                width = end - positions[left][0]
                window = (positions[left][0], end)
            old = positions[left][2]
            counts[old] -= 1
            if not counts[old]:
                del counts[old]
            left += 1
    phrase_match = _search_word_pattern(phrase).search(text) if phrase else None
    if phrase_match:
        window = phrase_match.span()
    proximity = max(0, 30 - max(0, width - sum(map(len, matched)) - len(matched) + 1)) if len(matched) > 1 else 0
    return {"matchedTokens": tuple(matched), "boost": 40 * bool(phrase_match) + proximity,
            "window": window, "phrase": bool(phrase_match), "tokenWindows": tuple(token_windows)}


def _term_match_strength(haystack: str, phrase: str) -> float:
    exact, token_patterns = _term_patterns(phrase)
    if exact.search(haystack):
        return 1.0
    if len(token_patterns) < 2:
        return 0.0
    matched = sum(bool(pattern.search(haystack)) for pattern in token_patterns)
    if matched == len(token_patterns):
        return 0.7
    return 0.35 if matched else 0.0


def _profile_key(profile: list[dict[str, Any]]) -> tuple[Any, ...]:
    return tuple(
        (
            feature.get("id", ""), feature.get("label", ""), feature.get("detail", ""),
            feature.get("source", "hardware"),
            feature.get("stale") is True,
            tuple((term.get("value", ""), term.get("weight", 1)) for term in feature.get("terms", [])),
        )
        for feature in profile
    )


def recommendation_details(
    item: dict[str, Any], profile: list[dict[str, Any]], include_readme: bool = True,
    profile_key: tuple[Any, ...] | None = None,
) -> dict[str, Any]:
    cache = item.setdefault("_recommendationCache", {})
    fields = _normalized_item_fields(item, include_readme)
    cache_key = (profile_key if profile_key is not None else _profile_key(profile),
                 item.get("_normalizedSource"), include_readme,
                 item.get("_readme", "") if include_readme else "", interest_evidence_key(item, include_readme))
    cached = cache.get(cache_key)
    if isinstance(cached, dict):
        return cached
    multipliers = {"name": 5, "id": 4, "tags": 3, "category": 2, "description": 2, "readme": 1}
    raw_scores = {"hardware": 0, "workflow": 0, "software": 0}
    evidence: dict[str, tuple[int, str, str, str]] = {}
    evidence_rows: dict[str, list[dict[str, Any]]] = {
        "hardware": [], "workflow": [], "software": [],
    }
    used_detected: dict[tuple[str, str], int] = {}
    for feature in profile:
        matches: list[tuple[int, str, str]] = []
        for term in feature.get("terms", []):
            phrase = _normalized_phrase(str(term.get("value", "")))
            weight = int(term.get("weight", 1))
            if not phrase:
                continue
            strongest: tuple[int, str, str] | None = None
            for field, haystack in fields.items():
                strength = _term_match_strength(haystack, phrase) if haystack else 0
                if strength:
                    candidate = (round(weight * multipliers[field] * strength), phrase, field)
                    if strongest is None or candidate > strongest:
                        strongest = candidate
            if include_readme and phrase in item.get("_literalReadme", set()):
                candidate = (weight, phrase, "readme")
                if strongest is None or candidate > strongest:
                    strongest = candidate
            if strongest is not None:
                matches.append(strongest)
        matches.sort(reverse=True)
        if matches:
            feature_score = min(240, sum(score for score, _term, _field in matches[:2]))
            source_key = feature.get("source", "hardware")
            if source_key not in raw_scores:
                source_key = "hardware"
            incremental = 0
            for points, term, _field in matches[:2]:
                key = (source_key, term)
                incremental += max(0, points - used_detected.get(key, 0))
                used_detected[key] = max(points, used_detected.get(key, 0))
            raw_scores[source_key] += min(240, incremental)
            top = matches[0]
            candidate = (feature_score, feature["label"], top[1], top[2])
            if source_key not in evidence or candidate > evidence[source_key]:
                evidence[source_key] = candidate
            evidence_rows[source_key].append({
                "id": feature.get("id", ""), "origin": "detected",
                "signal": one_line(feature.get("label"), 80),
                "detail": one_line(feature.get("detail"), 140),
                "term": one_line(top[1], 50),
                "field": "README" if top[2] == "readme" else top[2],
                "contribution": min(100, round(feature_score / 2)),
                "matchType": "exact" if literal_pattern(top[1]).search(fields.get(top[2], "")) or
                    (top[2] == "readme" and top[1] in item.get("_literalReadme", set())) else "related",
                "revision": item.get("listingCommit", ""),
                "stale": feature.get("stale") is True,
            })

    scores = {key: min(100, round(value / 2)) for key, value in raw_scores.items()}
    effects: dict[str, int] = {}
    for (_source, term), points in used_detected.items():
        effects[term] = max(effects.get(term, 0), points)
    reasons = []
    for source_key in ("hardware", "workflow", "software"):
        if source_key not in evidence:
            continue
        _score, label, phrase, field = evidence[source_key]
        source = "README" if field == "readme" else "listing"
        exact = literal_pattern(phrase).search(fields.get(field, "")) or (field == "readme" and phrase in item.get("_literalReadme", set()))
        reasons.append(f"Detected {source_key}: {label}; {source} {'exact phrase' if exact else 'related terms for'} {phrase}")
    interests = matched_interests(item, include_readme)
    user_terms: dict[str, int] = {}
    for match in interests:
        term = normalized(match["term"])
        user_terms[term] = max(user_terms.get(term, 0), 24 * multipliers.get(match["field"].lower(), 5))
    interest_score = min(100, round(sum(user_terms.values()) / 2))
    for term, points in user_terms.items():
        effects[term] = max(effects.get(term, 0), points)
    total = min(100, round(sum(effects.values()) / 2))
    scores["interests"] = interest_score
    evidence_rows["interests"] = [{**match, "signal": match["label"], "detail": "Saved by you",
                                  "contribution": min(100, round(user_terms[normalized(match["term"])] / 2))}
                                 for match in interests]
    if interests:
        reasons = reasons[:1] + [interests[0]["reason"]]
    matched_channels = sum(1 for score in scores.values() if score > 0)
    confidence = "high" if matched_channels >= 2 else ("medium" if total >= 50 else "exploratory")
    for source_key in evidence_rows:
        evidence_rows[source_key].sort(
            key=lambda row: (-row["contribution"], _normalized_phrase(row["signal"])),
        )
        evidence_rows[source_key] = evidence_rows[source_key][:4]
    result = {
        # Internal recommendation relevance, not the public Hardware Fit metric.
        "score": total,
        "baseScore": total,
        "adjustment": 0,
        "notFit": False,
        "reason": "; ".join(reasons[:2]),
        "scores": scores,
        "confidence": confidence,
        "evidence": evidence_rows,
        "matchedInterests": interests,
    }
    if len(cache) >= 4:
        cache.clear()
    cache[cache_key] = result
    return result


def recommendation_score(
    item: dict[str, Any], profile: list[dict[str, Any]], include_readme: bool = True,
    profile_key: tuple[Any, ...] | None = None,
) -> tuple[int, str]:
    details = recommendation_details(item, profile, include_readme, profile_key)
    return details["score"], details["reason"]


def search_evidence(item: dict[str, Any], query: str, include_readme: bool = True) -> dict[str, Any]:
    """Tiered query relevance; popularity is deliberately absent from this score."""
    phrase, words = _search_parts(query)
    fields = _normalized_item_fields(item, include_readme)
    indexed = item.get("_indexSearch") if include_readme else None
    indexed = (indexed[1] or _search_text_evidence("", query)) if indexed and indexed[0] == query else None
    key = (query, item.get("_normalizedSource"), include_readme, fields.get("readme", ""),
           None if indexed is None else (indexed["matchedTokens"], indexed["boost"], indexed["window"], indexed["tokenWindows"]))
    cache = item.setdefault("_searchEvidenceCache", {})
    if key in cache:
        return lru_hit(cache, key)
    metadata = {field: _search_text_evidence(text, query) for field, text in fields.items() if field != "readme"}
    readme = indexed if indexed is not None else _search_text_evidence(fields.get("readme", ""), query)
    covered = {word for evidence in metadata.values() for word in evidence["matchedTokens"]}
    name_match = False
    # Only the final typed token may be unfinished, and only in a name/ID.
    # Neither README nor arbitrary description substrings get prefix semantics.
    if words:
        last = words[-1]
        allow_prefix = phrase.endswith(last)
        for field in ("name", "id"):
            text = fields[field]
            hits = set(metadata[field]["matchedTokens"])
            if allow_prefix and _search_word_pattern(last, prefix=True).search(text):
                hits.add(last)
                covered.add(last)
            ordered = r"(?<!\w)" + r"\W+".join(re.escape(word) for word in words)
            ordered += r"\w*" if allow_prefix else r"(?!\w)"
            if hits.issuperset(words) and (metadata[field]["phrase"] or re.search(ordered, text)):
                name_match = True
    exact = bool(words and phrase in (fields["name"], fields["id"]))
    if exact:
        # An exact identifier can contain underscores or other punctuation whose
        # components are intentionally not standalone README word matches.
        covered.update(words)
    matched = covered | set(readme["matchedTokens"])
    complete = bool(words and matched.issuperset(words))
    metadata_complete = bool(words and covered.issuperset(words))
    tier = 5 if exact else 4 if name_match else 3 if metadata_complete else 2 if complete else 1 if matched else 0
    best_field = max(metadata, key=lambda field: (len(metadata[field]["matchedTokens"]), metadata[field]["boost"]))
    # Show README evidence only when it contributes missing coverage, or is the
    # strongest evidence of an incomplete result. Repetition never beats metadata.
    readme_primary = bool(readme["matchedTokens"] and not metadata_complete and
                          (complete or len(readme["matchedTokens"]) > len(covered)))
    if exact:
        reason = "Exact name or ID match"
    elif name_match:
        reason = "Name or ID matches your search"
    elif readme_primary:
        reason = "README matches your search" if not covered else "Listing and README match your search"
    else:
        reason = f"{best_field} matches your search" if matched else ""
    if matched and not complete:
        reason = f"Partial match ({len(matched)}/{len(words)} words); " + reason
    boosts = [value["boost"] for value in metadata.values()]
    if not metadata_complete:
        boosts.append(readme["boost"])
    snippet_window = readme["window"]
    if snippet_window[1] - snippet_window[0] > 160:
        snippet_window = next(((start, end) for word, start, end in readme["tokenWindows"] if word not in covered),
                              snippet_window)
    result = {"score": tier * 100000 + len(matched) * 100 + max(boosts) if tier else 0,
              "tier": tier, "complete": complete, "matchedTokens": tuple(word for word in words if word in matched),
              "reason": reason, "readmePrimary": readme_primary, "snippetWindow": snippet_window,
              "indexed": indexed is not None}
    lru_put(cache, key, result)
    return result


def search_score(item: dict[str, Any], query: str, include_readme: bool = True) -> tuple[int, str]:
    """Legacy callers retain the (score, reason) API."""
    evidence = search_evidence(item, query, include_readme)
    return evidence["score"], evidence["reason"]


def _search_excerpt(body: str, window: tuple[int, int]) -> str:
    start = max(0, window[0] - 65)
    # Strip markup after slicing so work is bounded even for a full indexed body.
    text = html.unescape(body[start:start + 360])
    text = re.sub(r"<[^>]*>", " ", text).replace("<", " ").replace(">", " ")
    text = one_line(text, 236)
    return ("… " if start else "") + text + (" …" if start + 236 < len(body) else "")


def search_snippets(selected: list[dict[str, Any]], query: str, store: Store | None) -> dict[str, str]:
    """Materialize excerpts only for displayed rows, using local revision-keyed text."""
    output, pending = {}, []
    stamp = readme_index_stamp(store) if store is not None else None
    cache = store.memory.setdefault("searchSnippets", {}) if store is not None else {}
    for candidate in selected:
        item, evidence = candidate["item"], candidate["searchEvidence"]
        if not evidence["readmePrimary"]:
            continue
        if evidence["indexed"] and store is not None:
            key = (stamp, readme_key(item), query, evidence["snippetWindow"])
            if key in cache:
                output[item["id"]] = lru_hit(cache, key)
            else:
                pending.append((item, evidence, key))
        elif not evidence["indexed"]:
            output[item["id"]] = _search_excerpt(normalized(item.get("_readme", "")), evidence["snippetWindow"])
    if pending:
        try:
            with ReadmeIndex(store) as index:
                if index.db is not None:
                    for item, evidence, key in pending:
                        row = index.db.execute("SELECT body FROM documents WHERE key=?", (key[1],)).fetchone()
                        if row:
                            output[item["id"]] = _search_excerpt(row[0], evidence["snippetWindow"])
                            lru_put(cache, key, output[item["id"]], MAX_SETUP_PAGE_SIZE * 4)
        except (OSError, ValueError, sqlite3.Error):
            pass
    return output


def _search_edit_distance(left: str, right: str, limit: int) -> int:
    if abs(len(left) - len(right)) > limit:
        return limit + 1
    previous, before = list(range(len(right) + 1)), None
    for i, char in enumerate(left, 1):
        current = [i]
        for j, other in enumerate(right, 1):
            distance = min(current[-1] + 1, previous[j] + 1, previous[j - 1] + (char != other))
            if before is not None and j > 1 and char == right[j - 2] and left[i - 2] == other:
                distance = min(distance, before[j - 2] + 1)
            current.append(distance)
        if min(current) > limit:
            return limit + 1
        before, previous = previous, current
    return previous[-1]


def search_suggestion(query: str, items: list[dict[str, Any]]) -> dict[str, str] | None:
    phrase, words = _search_parts(query)
    if not 4 <= len(phrase) <= 64 or not 1 <= len(words) <= 3 or len(phrase.split()) > 3:
        return None
    names = {one_line(item.get("name"), 160) for item in items}
    names.update(service["name"] for service in load_service_registry())
    limit = 2 if len(phrase) >= 8 else 1
    choices = []
    for name in sorted(names):
        target = normalized(name)
        if not 4 <= len(target) <= 64 or len(target.split()) > 3 or len(_search_parts(target)[1]) > 3:
            continue
        distance = _search_edit_distance(phrase, target, limit)
        if 0 < distance <= limit:
            choices.append((distance, target, name))
    for _distance, _target, name in sorted(choices):
        # Suggestions respect the same hard-filtered universe and must lead to
        # a complete metadata result; no speculative README scans or rewrites.
        if any(search_evidence(item, name, False)["complete"] for item in items):
            return {"query": name, "label": f"Did you mean {name}?"}
    return None


def review_state(item: dict[str, Any]) -> str:
    if item.get("party") == "first-party":
        return "first-party local"
    if item.get("localOnly") is True:
        return "local install"
    if (
        item.get("verificationStatus") == "verified"
        and item.get("verificationSnapshotStatus") == "verified"
        and item.get("verificationCommit")
        and item.get("verificationCommit") == item.get("listingCommit")
    ):
        return "reviewed snapshot"
    if item.get("verificationCommit") and item.get("verificationCommit") != item.get("listingCommit"):
        return "reviewed revision differs"
    if item.get("verificationCommit"):
        return "snapshot checks not confirmed"
    return "not reviewed"


def marketplace_verification(item: dict[str, Any]) -> str:
    if item.get("party") == "first-party" or item.get("localOnly") or item.get("repositoryLayout") == "suite":
        return "not-applicable"
    value = item.get("verificationStatus")
    return value if value in {"verified", "unverified"} else "unknown"


def listing_badges(item: dict[str, Any], now: float | None = None) -> dict[str, Any]:
    """Marketplace New is a rolling 12-hour listing window, not repository activity."""
    now = time.time() if now is None else now
    listed = listing_time(item.get("listedAt", ""))
    eligible = not item.get("localOnly") and item.get("party") != "first-party"
    until = listed + 12 * 60 * 60 if eligible and listed > 0 else 0
    return {"isNew": bool(until and listed <= now < until), "newUntil": until}


def hardware_fit(details: dict[str, Any]) -> int:
    """The sole source for the public Hardware Fit metric, sort, and filter."""
    return int(details.get("scores", {}).get("hardware", 0))


def public_row(
    item: dict[str, Any],
    score: int,
    reason: str,
    installed: set[str],
    details: dict[str, Any] | None = None,
) -> dict[str, Any]:
    identity = item["id"]
    editorial = discovery_notes().get(identity, {})
    if editorial.get("commit") != item.get("listingCommit"):
        editorial = {}
    details = details or {
        "scores": {"hardware": 0, "workflow": 0, "software": 0, "interests": 0},
        "confidence": "exploratory",
        "baseScore": score,
        "adjustment": 0,
        "notFit": False,
        "evidence": {"hardware": [], "workflow": [], "software": [], "interests": []},
    }
    local_only = item.get("localOnly") is True
    repository = item.get("repo", "")
    return {
        "id": identity,
        "name": item["name"],
        "description": item["description"],
        "editorialSetup": editorial.get("setup", ""),
        "installNote": item.get("installNote", ""),
        "author": item["author"],
        "version": item["version"],
        "category": item["category"],
        "tags": item["tags"],
        "kind": item["kind"],
        "kinds": item.get("kinds", []),
        "barWidget": is_bar_widget(item),
        "barSection": item.get("barSection")
            if item.get("barSection") in {"left", "center", "right"} else "",
        "repo": item["repo"],
        "marketplaceUrl": "" if local_only else "https://plugins.omarchy.org/plugin.html?id=" + urllib.parse.quote(identity, safe=""),
        "snapshotUrl": repository + "/tree/" + item["listingCommit"] if repository and item["listingCommit"] else repository,
        "installAvailable": item["installAvailable"],
        "installed": identity in installed,
        "enabled": item.get("enabled") is True,
        "active": item.get("active") is True,
        "canDisable": item.get("canDisable") is True,
        "removable": identity in installed
            and item.get("party", "third-party") == "third-party"
            and identity not in {APP_ID, LEGACY_APP_ID},
        "party": item.get("party", "third-party"),
        "firstParty": item.get("party") == "first-party",
        "localOnly": local_only,
        "reviewState": review_state(item),
        "stars": item["stars"],
        "likes": item.get("_likes"),
        "views": item.get("_views"),
        "copies": item.get("_copies"),
        "verification": marketplace_verification(item),
        "verificationMethod": item.get("verificationMethod", ""),
        "verificationCoverage": item.get("verificationCoverage", ""),
        "verificationSnapshotStatus": item.get("verificationSnapshotStatus", ""),
        "verificationCommit": item.get("verificationCommit", ""),
        **listing_badges(item),
        "activityAt": max(item.get("versionUpdatedAt", ""), item.get("repositoryUpdatedAt", "")),
        "likesFetchedAt": item.get("_likesFetchedAt", 0),
        "listedAt": item.get("listedAt", ""),
        "reason": one_line(reason, 180),
        "score": hardware_fit(details),
        "baseScore": details["baseScore"],
        "adjustment": details["adjustment"],
        "notFit": details["notFit"],
        "scores": dict(details["scores"]),
        "confidence": details["confidence"],
        "evidence": {channel: [dict(row) for row in rows] for channel, rows in details["evidence"].items()},
        "matchedInterests": [dict(row) for row in details.get("matchedInterests", [])],
        "readmeIndexed": item.get("_readmeIndexed") is True,
        "readmeAvailable": bool(item.get("_showReadme") and item.get("listingCommit")),
        **preview_metadata(item),
        "readmeSummary": clean(item.get("_readmeSummary"), MAX_README_SUMMARY)
            if item.get("_showReadme") else "",
        "readmeMedia": validate_readme_media(item.get("_readmeMedia"))
            if item.get("_showReadme") else [],
        "readmeMediaIndexed": bool(
            item.get("_showReadme") and item.get("_readmeMediaIndexed") is True
        ),
        "listingCommit": item["listingCommit"],
    }


def _matches_filters(
    item: dict[str, Any], installed: set[str], install_filter: str, party_filter: str
) -> bool:
    is_installed = item["id"] in installed
    if install_filter == "installed" and not is_installed:
        return False
    if install_filter == "available" and is_installed:
        return False
    return party_filter == "all" or item.get("party", "third-party") == party_filter


def filter_counts(items: list[dict[str, Any]], installed: set[str]) -> dict[str, int]:
    installed_count = sum(item["id"] in installed for item in items)
    return {
        "all": len(items),
        "installed": installed_count,
        "available": len(items) - installed_count,
        "firstParty": sum(item.get("party") == "first-party" for item in items),
        "thirdParty": sum(item.get("party", "third-party") == "third-party" for item in items),
    }


def apply_feedback(details: dict[str, Any], identity: str, not_fit: set[str]) -> dict[str, Any]:
    """Legacy call boundary: retained stored feedback is inert, including old queues."""
    output = dict(details)
    base_score = int(details.get("baseScore", details.get("score", 0)))
    output["adjustment"] = 0
    output["notFit"] = False
    output["score"] = base_score
    return output


def _purpose_terms(text: str, terms: tuple[str, ...]) -> bool:
    return any(_term_patterns(term)[0].search(text) for term in terms)


def specific_purpose(name: str, description: str, category: str, tags: set[str]) -> str:
    """Use primary listing intent, never incidental README/support mentions."""
    if category == "appearance" or _purpose_terms(name, ("wallpaper", "wallpapers", "theme", "themes")):
        return "appearance"
    if category in {"kids", "games"} or tags & {"kids", "education", "games"}:
        return "games-learning"
    if _purpose_terms(name, ("emoji", "notification center", "notification sounds")):
        return ""
    if _purpose_terms(name, (
        "messaging", "messenger", "whatsapp", "whatsmarchy", "omawhatsapp", "telegram",
        "omargram", "blueferry", "beeper", "zulip", "slack", "microsoft teams", "omabond", "omaq", "irc", "quick reply",
    )):
        return "messaging"
    if "ai" not in tags and not _purpose_terms(name, ("agent", "assistant", "llm")) and _purpose_terms(description, (
        "imessage", "sms", "web messaging", "group chat", "irc client", "matrix client",
        "matrix messenger", "slack client", "teams client", "instant messaging", "chat with friends",
    )):
        return "messaging"
    if _purpose_terms(name, ("weather", "forecast", "rss", "news", "omanews", "newsboat", "substack")) \
            or _purpose_terms(description, ("rss reader", "atom reader", "news reader", "weather forecast", "metar and taf")):
        return "news-weather"
    if not _purpose_terms(name, ("password", "theme sync", "agent skills", "mcp", "config backup")):
        if _purpose_terms(name, (
            "file manager", "file browser", "file transfer", "file shelf", "files", "backup", "backups",
            "syncthing", "rclone", "restic", "borg", "kopia", "localsend", "omasend", "synology drive",
            "proton drive", "google drive", "onedrive", "omaonedrive", "cloud drives", "dropbox",
            "transfer manager", "file sync", "folder sync",
        )) or _purpose_terms(description, (
            "file synchronization", "file synchronisation", "file transfers", "file manager",
            "file browser", "backup jobs", "backup repositories", "cloud storage",
        )):
            return "files-backup"
    if not _purpose_terms(name, ("sports", "football", "fixtures", "task", "tasks")):
        if _purpose_terms(name, (
            "email", "e-mail", "mail", "omamail", "omafmail", "gmail", "outlook", "calendar", "agenda", "omameet",
        )) or _purpose_terms(description, (
            "email client", "mail client", "mailbox", "icalendar", "caldav", "calendar agenda",
            "meeting scheduler", "calendar events",
        )):
            return "email-calendar"
    return ""


def setup_group(item: dict[str, Any], include_readme: bool = False) -> str:
    """Map broad marketplace taxonomy to one stable newcomer-facing purpose."""
    fields = _normalized_item_fields(item, include_readme)
    key = tuple(fields.get(field, "") for field in ("name", "description", "category", "tags", "readme"))
    cache = item.setdefault("_purposeCache", {})
    if cache.get("key") == key:
        return cache["value"]
    result = _classify_setup_fields(fields)
    cache.update(key=key, value=result)
    return result


def _classify_setup_fields(fields: dict[str, str]) -> str:
    category = fields["category"]
    tags = set(fields["tags"].split())
    specific = specific_purpose(fields["name"], fields["description"], category, tags)
    if specific:
        return specific
    text = " ".join((
        fields["name"], fields["description"], fields["tags"],
        fields.get("readme", ""),
    ))

    if category == "kids" or tags & {"kids", "education", "games"}:
        return "games-learning"
    if "media" in tags or any(term in text for term in (
        "audio", "music", "podcast", "spotify", "microphone", "volume",
    )):
        return "audio-media"
    if "ai" in tags or category == "developer tools":
        return "development-ai"
    if "security" in tags or any(term in text for term in (
        "network", "vpn", "tailscale", "firewall", "privacy",
    )):
        return "network-privacy"
    if category == "hardware":
        return "hardware"
    if category == "appearance":
        return "appearance"
    if category == "desktop" or tags & {"launcher", "workspaces"}:
        return "desktop-navigation"
    if category == "system" or "power-management" in tags:
        return "power-system"
    if category == "productivity":
        return "productivity"
    return "other"


def recommendation_metrics(stars: int, maximum: int, details: dict[str, Any]) -> tuple[int, int]:
    popularity = round(100 * math.log1p(stars) / math.log1p(maximum)) if maximum else 0
    recommendation = max(0, round(popularity * 0.6 + int(details.get("baseScore", 0)) * 0.4)
                         + int(details.get("adjustment", 0)))
    return popularity, recommendation


def setup_catalog(
    items: list[dict[str, Any]],
    profile: list[dict[str, Any]],
    installed: set[str],
    query: str = "",
    group: str = "",
    sort: str = "likes",
    page: int = 1,
    page_size: int = SETUP_PAGE_SIZE,
    not_fit: set[str] | None = None,
    service_ids: list[str] | None = None,
    service_filter: str = "",
    install_filter: str = "all",
    party_filter: str = "all",
    hardware_only: bool = False,
    category: str = "",
    grouping: str = "none",
    verification: str = "all",
    interest_choices: list[dict[str, Any]] | None = None,
    interest_matches: dict[str, list[dict[str, Any]]] | None = None,
    search_store: Store | None = None,
) -> dict[str, Any]:
    grouping = grouping if grouping in {"none", "category"} else "none"
    group = group if group in SETUP_GROUP_IDS else ""
    category = one_line(category, 80)
    sort = sort if sort in {"relevance", "recommended", "stars", "fit", "name", "added", "likes", "activity", "views", "copies"} else "likes"
    query = one_line(query, 160)
    verification = verification if verification in {"all", "verified", "unverified"} else "all"
    install_filter = install_filter if install_filter in {
        "all", "installed", "available",
    } else "all"
    party_filter = party_filter if party_filter in {
        "all", "first-party", "third-party",
    } else "all"
    page = page if type(page) is int and page > 0 else 1
    page_size = page_size if type(page_size) is int else SETUP_PAGE_SIZE
    page_size = max(12, min(MAX_SETUP_PAGE_SIZE, page_size))
    not_fit = not_fit or set()
    profile_key = _profile_key(profile)
    registry = list(load_service_registry())
    registry.extend(interest_choices or [])
    requested_services = {
        identity for value in (service_ids or [])[:MAX_SERVICE_CHOICES]
        if (identity := service_id(value))
    }
    # An unavailable saved filter must yield no matches, not silently broaden
    # the result set to every plugin after a stale resume or removed interest.
    known_filters = {entry["id"] for entry in registry}
    registry.extend({"id": identity, "name": "Unavailable interest", "category": "Interests"}
                    for identity in sorted(requested_services - known_filters)
                    if re.fullmatch(r"interest-[0-9a-f]{32}", identity))
    selected_services = [
        service["id"] for service in registry if service["id"] in requested_services
    ]
    selected_service_set = set(selected_services)
    service_filter = service_id(service_filter)
    if service_filter in selected_service_set:
        # Older restore payloads used a focused service chip. Treat it as the
        # one active service filter in the unified browser.
        selected_services = [service_filter]
        selected_service_set = {service_filter}
    service_filter = ""

    prepared: list[dict[str, Any]] = []
    for item in items:
        include_readme = item.get("_showReadme") is True
        details = apply_feedback(
            recommendation_details(item, profile, include_readme, profile_key),
            item["id"], not_fit,
        )
        matches = service_matches(item) + (interest_matches or {}).get(item["id"], [])
        search = search_evidence(item, query, include_readme)
        prepared.append({
            "item": item,
            "group": setup_group(item, include_readme),
            "details": details,
            "matches": matches,
            "matchIds": {match["id"] for match in matches},
            "search": search["score"],
            "searchReason": search["reason"],
            "searchEvidence": search,
            "hardwareMatch": hardware_fit(details) > 0,
            "installed": item["id"] in installed,
            "installable": item.get("installAvailable") is True,
        })

    complete_only = False

    def matches_context(entry: dict[str, Any], ignore: str = "", search: bool = True) -> bool:
        item = entry["item"]
        if verification != "all" and marketplace_verification(item) != verification:
            return False
        if search and query and (entry["search"] <= 0 or (complete_only and not entry["searchEvidence"]["complete"])):
            return False
        if ignore != "service" and selected_service_set \
                and not selected_service_set.intersection(entry["matchIds"]):
            return False
        if ignore != "group" and group and entry["group"] != group:
            return False
        if category and item["category"] != category:
            return False
        if ignore != "install":
            if install_filter == "installed" and not entry["installed"]:
                return False
            if install_filter == "available" and entry["installed"]:
                return False
        if ignore != "party" and party_filter != "all" \
                and item.get("party", "third-party") != party_filter:
            return False
        if ignore != "hardware" and hardware_only and not entry["hardwareMatch"]:
            return False
        return True

    # All sidebar constraints apply before deciding whether partial fallback is
    # necessary. Selected services/interests retain their existing OR semantics.
    context = [entry for entry in prepared if matches_context(entry, search=False)]
    complete_only = bool(query and any(entry["searchEvidence"]["complete"] for entry in context))
    has_partial = bool(query and any(entry["search"] > 0 for entry in context))
    search_state = {"active": bool(query),
                    "mode": "complete" if complete_only else "partial" if has_partial else "none",
                    "suggestion": search_suggestion(query, [entry["item"] for entry in context])
                        if query and not has_partial else None}

    groups_by_id = {
        identity: {"id": identity, "label": label, "total": 0, "installable": 0}
        for identity, label in SETUP_GROUPS
    }
    service_counts = {
        service["id"]: {"total": 0, "installable": 0}
        for service in registry
    }
    setup_filter_counts = {
        "all": 0, "installed": 0, "available": 0,
        "firstParty": 0, "thirdParty": 0,
    }
    hardware_match_count = 0
    for entry in prepared:
        item = entry["item"]
        if matches_context(entry, "install"):
            setup_filter_counts["all"] += 1
            setup_filter_counts["installed" if entry["installed"] else "available"] += 1
        if matches_context(entry, "party"):
            setup_filter_counts[
                "firstParty" if item.get("party") == "first-party" else "thirdParty"
            ] += 1
        if matches_context(entry, "group"):
            group_row = groups_by_id[entry["group"]]
            group_row["total"] += 1
            if entry["installable"] and not entry["installed"]:
                group_row["installable"] += 1
        if matches_context(entry, "service"):
            for match in entry["matches"]:
                count = service_counts[match["id"]]
                count["total"] += 1
                if entry["installable"] and not entry["installed"]:
                    count["installable"] += 1
        if matches_context(entry, "hardware") and entry["hardwareMatch"]:
            hardware_match_count += 1

    services = [
        {
            "id": service["id"],
            "name": service["name"],
            "category": service["category"],
            "total": service_counts[service["id"]]["total"],
            "installable": service_counts[service["id"]]["installable"],
        }
        for service in registry
    ]

    candidates: list[dict[str, Any]] = []
    for entry in prepared:
        if not matches_context(entry):
            continue
        item = entry["item"]
        selected_matches = [
            match for match in entry["matches"] if match["id"] in selected_service_set
        ]
        candidates.append({
            "item": item,
            "group": entry["group"],
            "details": entry["details"],
            "services": selected_matches,
            "fit": hardware_fit(entry["details"]),
            "relevance": entry["details"]["baseScore"],
            "search": entry["search"],
            "searchReason": entry["searchReason"],
            "searchEvidence": entry["searchEvidence"],
            "stars": item.get("stars") if type(item.get("stars")) is int else 0,
            "starsReported": type(item.get("stars")) is int,
            "likes": item.get("_likes"),
            "views": item.get("_views"),
            "copies": item.get("_copies"),
            "activity": listing_time(max(item.get("versionUpdatedAt", ""), item.get("repositoryUpdatedAt", ""))),
            "listed": listing_time(item.get("listedAt", "")),
            "installable": entry["installable"],
            "installed": entry["installed"],
        })

    group_max_stars: dict[str, int] = {}
    for candidate in candidates:
        purpose = candidate["group"]
        group_max_stars[purpose] = max(group_max_stars.get(purpose, 0), candidate["stars"])
    for candidate in candidates:
        maximum = group_max_stars.get(candidate["group"], 0)
        candidate["popularity"], candidate["recommendation"] = recommendation_metrics(
            candidate["stars"], maximum, candidate["details"])

    def setup_sort_key(candidate: dict[str, Any]) -> tuple[Any, ...]:
        include_readme = candidate["item"].get("_showReadme") is True
        name_key = _normalized_item_fields(candidate["item"], include_readme)["name"]
        id_key = _normalized_item_fields(candidate["item"], include_readme)["id"]
        if sort == "relevance":
            # Popularity only resolves equal strong relevance; weak README-only
            # and partial matches use deterministic lexical ties.
            return (-candidate["search"],
                    -candidate["stars"] if candidate["searchEvidence"]["tier"] >= 3 else 0,
                    name_key, id_key)
        if sort == "stars":
            return (
                -int(candidate["starsReported"]), -candidate["stars"],
                name_key, id_key,
            )
        if sort == "fit":
            return (
                -candidate["fit"], -candidate["stars"], name_key, id_key,
            )
        if sort == "name":
            return (name_key, id_key)
        if sort == "added":
            return (-candidate["listed"], name_key, id_key)
        if sort == "activity":
            return (-candidate["activity"], name_key, id_key)
        if sort in {"likes", "views", "copies"}:
            return (-int(candidate[sort] is not None), -(candidate[sort] or 0), name_key, id_key)
        return (
            -candidate["recommendation"],
            -candidate["relevance"], -candidate["stars"], name_key, id_key,
        )

    candidates.sort(key=setup_sort_key)

    groups = [groups_by_id[identity] for identity, _label in SETUP_GROUPS]

    overview = False
    total = len(candidates)
    page_count = max(1, math.ceil(total / page_size))
    page = min(page, page_count)
    offset = (page - 1) * page_size
    selected = candidates[offset:offset + page_size]
    snippets = search_snippets(selected, query, search_store) if query else {}

    rows = []
    for candidate in selected:
        details = candidate["details"]
        reason = details["reason"] or (
            "Installed plugin; no hardware-specific match yet."
            if candidate["installed"] else
            "No hardware-specific match; ranked by marketplace popularity."
        )
        row = public_row(
            candidate["item"], candidate["fit"], reason, installed, details,
        )
        row.update({
            "setupGroup": candidate["group"],
            "displayGroup": ("all" if grouping == "none" else
                             candidate["item"]["category"] or "Uncategorized"),
            "recommendationScore": candidate["recommendation"],
            "popularityScore": candidate["popularity"],
            "selectable": candidate["installable"] and not candidate["installed"],
            "exclusiveActivation": normalized(candidate["item"].get("kind", "")) == "bar",
            "matchedServices": candidate["services"],
            "serviceReason": "; ".join(match["reason"] for match in candidate["services"]),
            "searchReason": candidate["searchReason"],
            "searchSnippet": snippets.get(candidate["item"]["id"], ""),
        })
        rows.append(row)

    section_counts: dict[str, int] = {}
    for candidate in candidates:
        key = "all" if grouping == "none" else candidate["item"]["category"] or "Uncategorized"
        section_counts[key] = section_counts.get(key, 0) + 1
    sections = [{"id": key, "label": "All plugins" if grouping == "none" else key, "total": count}
                for key, count in sorted(section_counts.items())]

    return {
        "rows": rows,
        "groups": groups,
        "sections": sections,
        "grouping": grouping,
        "query": query,
        "search": search_state,
        "group": group,
        "sort": sort,
        "page": page,
        "pageCount": page_count,
        "total": total,
        "overview": overview,
        "services": services,
        "selectedServices": selected_services,
        "serviceFilter": service_filter,
        "serviceMode": bool(selected_services),
        "filterCounts": setup_filter_counts,
        "installFilter": install_filter,
        "partyFilter": party_filter,
        "hardwareOnly": hardware_only,
        "hardwareMatchCount": hardware_match_count,
        "category": category,
        "verification": verification,
    }


@functools.lru_cache(maxsize=1)
def discovery_notes() -> dict[str, dict[str, Any]]:
    try:
        with DISCOVERY_REGISTRY_PATH.open("rb") as stream:
            raw = stream.read(64 * 1024 + 1)
        if len(raw) > 64 * 1024:
            return {}
        document = safe_json_loads(raw, "Discovery notes")
        if not isinstance(document, dict) or document.get("schema") != 1 or not isinstance(document.get("entries"), list):
            return {}
        output = {}
        for entry in document["entries"][:64]:
            if not isinstance(entry, dict):
                continue
            identity, commit = plugin_id(entry.get("id")), full_sha(entry.get("commit"))
            if identity and commit:
                output[identity] = {"commit": commit, "heading": one_line(entry.get("heading"), 120),
                    "setup": one_line(entry.get("setup"), 300), "family": one_line(entry.get("family"), 60),
                    "signals": [one_line(value, 60) for value in entry.get("signals", [])[:12]]
                        if isinstance(entry.get("signals"), list) else [],
                    "everyday": entry.get("everyday") is True}
        return output
    except (OSError, ValueError):
        return {}


def discovery_catalog(items: list[dict[str, Any]], profile: list[dict[str, Any]], installed: set[str],
                      preferences: dict[str, Any], request: dict[str, Any], now: float) -> dict[str, Any]:
    """Small, deterministic editorial/context/exploration mix; no personal history on disk."""
    def ids(key: str, maximum: int) -> set[str]:
        values = request.get(key)
        return {identity for value in values[:maximum] if (identity := plugin_id(value))} if isinstance(values, list) else set()
    excluded = installed | ids("queuedIds", 50)
    seen = ids("seenIds", 36)
    rotation = request.get("rotation", 0)
    rotation = max(0, min(100000, rotation)) if type(rotation) is int else 0
    day = time.strftime("%Y-%m-%d", time.gmtime(now))
    notes = discovery_notes()
    signals = {feature["id"]: feature for feature in profile}
    saved = set(preferences.get("services", []))
    candidates = []
    for item in items:
        if item["id"] in excluded or item.get("installAvailable") is not True or not full_sha(item.get("listingCommit")):
            continue
        if "bar" in item.get("kinds", []) or normalized(item.get("kind")) == "bar":
            continue
        note = notes.get(item["id"], {})
        if note.get("commit") != item.get("listingCommit"):
            note = {}
        details = recommendation_details(item, profile, item.get("_showReadme") is True)
        detected_evidence = details["evidence"]["hardware"] + details["evidence"]["software"]
        candidates.append({"item":item, "note":note, "group":setup_group(item, item.get("_showReadme") is True),
            "signal":next((signals[key] for key in note.get("signals", []) if key in signals), None)
                or ({"label": detected_evidence[0]["signal"]} if detected_evidence else None),
            "interests": matched_interests(item, item.get("_showReadme") is True),
            "services":[match for match in service_matches(item) if match["id"] in saved]})
    all_candidates = candidates
    unseen_candidates = [candidate for candidate in candidates if candidate["item"]["id"] not in seen]
    if len(unseen_candidates) >= min(3, len(candidates)):
        candidates = unseen_candidates
    chosen = []
    owners, families, purposes = set(), set(), set()
    def pick(pool: list[dict[str, Any]], slot: str) -> bool:
        pool = [candidate for candidate in pool
                if candidate["item"].get("owner", "") not in owners
                and (candidate["note"].get("family") or candidate["item"]["id"]) not in families]
        if not pool:
            return False
        unseen = [candidate for candidate in pool if candidate["item"]["id"] not in seen]
        pool = unseen or pool
        varied = [candidate for candidate in pool if candidate["group"] not in purposes]
        pool = varied or pool
        pool.sort(key=lambda candidate: hashlib.sha256(
            (day + "|" + slot + "|" + candidate["item"]["id"]).encode()).digest())
        candidate = pool[rotation % len(pool)]
        chosen.append((candidate, slot))
        owners.add(candidate["item"].get("owner", ""))
        families.add(candidate["note"].get("family") or candidate["item"]["id"])
        purposes.add(candidate["group"])
        return True
    everyday = [candidate for candidate in candidates if candidate["note"].get("everyday")]
    if not pick([candidate for candidate in candidates if candidate["signal"]], "setup"):
        if not pick(everyday, "everyday"):
            pick(candidates, "everyday")
    if not pick([candidate for candidate in candidates if candidate["interests"] or candidate["services"]], "service"):
        if not pick(everyday, "everyday"):
            pick(candidates, "everyday")
    recent = [candidate for candidate in candidates
              if 0 <= now - listing_time(candidate["item"].get("listedAt", "")) <= 7 * 86400]
    if not pick(recent, "different"):
        pick(candidates, "different")
    maxima = {}
    for candidate in all_candidates:
        purpose = candidate["group"]
        maxima[purpose] = max(maxima.get(purpose, 0), candidate["item"].get("stars") or 0)
    rows = []
    profile_key = _profile_key(profile)
    for candidate, slot in chosen:
        item, note = candidate["item"], candidate["note"]
        details = recommendation_details(item, profile, item.get("_showReadme") is True, profile_key)
        row = public_row(item, details["score"], details["reason"], installed, details)
        if slot == "setup":
            reason = "Shown for a detected capability: " + one_line(candidate["signal"].get("label"), 80) + ". Check the setup note below."
        elif slot == "service":
            names = ", ".join(match["label"] for match in candidate["interests"][:2])
            reason = ("Matches " + names + " in your saved interests." if names else
                      "Matches " + ", ".join(match["name"] for match in candidate["services"][:2]) + " in your saved service watchlist.")
        elif slot == "different":
            reason = "Recently listed: a different task to explore." if candidate in recent else "A different task to explore, independent of star count."
        else:
            reason = "An everyday starting point for your desktop." if note else "An option to explore while you get to know Omarchy."
        maximum = maxima.get(candidate["group"], 0)
        popularity = round(100 * math.log1p(item.get("stars") or 0) / math.log1p(maximum)) if maximum else 0
        row.update({"setupGroup":candidate["group"], "selectable":True, "exclusiveActivation":False,
            "recommendationScore":round(popularity * .6 + details["baseScore"] * .4),
            "discoverySlot":slot, "discoveryHeading":note.get("heading") or item["name"],
            "discoveryReason":reason, "discoverySetup":note.get("setup")
                or "Automatic installation is available; extra setup has not been checked. Read the project instructions.",
            "discoveryCurated":bool(note), "discoveryEvidence":item["repo"] + "/blob/" + item["listingCommit"] + "/README.md" if note else "",
            "matchedServices":candidate["services"], "serviceReason":"; ".join(match["reason"] for match in candidate["services"])})
        rows.append(row)
    return {"rows":rows, "rotation":rotation, "day":day, "eligible":len(all_candidates)}


def ranked_rows(
    items: list[dict[str, Any]],
    profile: list[dict[str, Any]],
    installed: set[str],
    query: str,
    category: str,
    include_readme: bool = True,
    install_filter: str = "all",
    party_filter: str = "all",
    not_fit: set[str] | None = None,
) -> list[dict[str, Any]]:
    scored: list[tuple[int, int, str, dict[str, Any], dict[str, Any]]] = []
    not_fit = not_fit or set()
    profile_key = _profile_key(profile)
    items = [item for item in items if (not category or item["category"] == category)
             and _matches_filters(item, installed, install_filter, party_filter)]
    evidence = {item["id"]: search_evidence(item, query, include_readme) for item in items} if query else {}
    complete_only = any(value["complete"] for value in evidence.values())
    for item in items:
        if category and item["category"] != category:
            continue
        if not _matches_filters(item, installed, install_filter, party_filter):
            continue
        matched_search = False
        if query:
            match = evidence[item["id"]]
            if complete_only and not match["complete"]:
                continue
            search_points, search_reason = match["score"], match["reason"]
            matched_search = search_points > 0
            if not matched_search:
                continue
            details = apply_feedback(
                recommendation_details(item, profile, include_readme, profile_key),
                item["id"], not_fit,
            )
            score = details["score"] if search_points > 0 else 0
            rank_score = search_points
            reason = search_reason + ("; " + details["reason"] if details["reason"] else "")
        else:
            details = apply_feedback(
                recommendation_details(item, profile, include_readme, profile_key),
                item["id"], not_fit,
            )
            score, reason = details["score"], details["reason"]
            rank_score = score
        explicitly_browsing_installed = not query and item["id"] in installed and (
            install_filter == "installed" or party_filter == "first-party")
        if score > 0 or matched_search or explicitly_browsing_installed:
            scored.append((rank_score, score, reason, item, details))
    scored.sort(key=lambda row: (normalized(row[3]["name"]), normalized(row[3]["id"])))
    if query:
        scored.sort(key=lambda row: (row[3].get("stars") or 0)
                    if evidence[row[3]["id"]]["tier"] >= 3 else 0, reverse=True)
    scored.sort(key=lambda row: row[0], reverse=True)
    return [
        public_row(item, score, reason or "Installed plugin; no fit evidence yet.", installed, details)
        for _rank, score, reason, item, details in scored[:60]
    ]


def broad_candidates(
    items: list[dict[str, Any]],
    profile: list[dict[str, Any]],
    query: str,
    category: str,
    include_readme: bool = True,
    installed: set[str] | None = None,
    install_filter: str = "all",
    party_filter: str = "all",
) -> list[dict[str, Any]]:
    scored: list[tuple[int, dict[str, Any]]] = []
    installed = installed or set()
    profile_key = _profile_key(profile)
    for item in items:
        if category and item["category"] != category:
            continue
        if not _matches_filters(item, installed, install_filter, party_filter):
            continue
        score = search_score(item, query, include_readme=False)[0] if query else recommendation_score(
            item, profile, include_readme=False, profile_key=profile_key,
        )[0]
        if score > 0:
            scored.append((score, item))
    scored.sort(key=lambda row: (normalized(row[1]["name"]), normalized(row[1]["id"])))
    scored.sort(key=lambda row: row[0], reverse=True)
    return [item for _score, item in scored[:40]]


def browse_rows(
    items: list[dict[str, Any]],
    installed: set[str],
    category: str,
    install_filter: str = "all",
    party_filter: str = "all",
) -> list[dict[str, Any]]:
    selected = [
        item for item in items
        if (not category or item["category"] == category)
        and _matches_filters(item, installed, install_filter, party_filter)
    ]
    selected.sort(key=lambda item: (item["stars"] is not None, item["stars"] or 0, normalized(item["name"])), reverse=True)
    return [public_row(item, 0, "Popular marketplace listing", installed) for item in selected[:60]]


def carry_catalog_memos(items: list[dict[str, Any]], previous: Any) -> None:
    if not isinstance(previous, tuple) or len(previous) != 3:
        return
    before = {item["id"]: item for item in previous[0]}
    for item in items:
        old = before.get(item["id"])
        if old is None:
            continue
        # Every memo has a semantic key: carrying it across a refresh does not
        # carry listing values, inventory, or old README evidence into new rows.
        for key in ("_recommendationCache", "_interestMatchCache", "_readmeFieldsCache", "_purposeCache",
                    "_serviceMatchesSource", "_serviceMatches", "_searchEvidenceCache"):
            if key in old:
                item[key] = old[key]


def load_catalog(store: Store) -> tuple[list[dict[str, Any]], float, str]:
    memory = getattr(store, "memory", {})
    stamp = store.stamp("catalog.json")
    cached = memory.get("catalog")
    if isinstance(cached, tuple) and len(cached) == 3 and stamp == memory.get("catalogStamp"):
        return cached
    cache_error = None
    try:
        raw = store.read("catalog.json", MAX_CACHE_BYTES, {"schema": CATALOG_SCHEMA, "plugins": [], "fetchedAt": 0})
        if not isinstance(raw, dict) or raw.get("schema") != CATALOG_SCHEMA or not isinstance(raw.get("plugins"), list):
            raise ValueError("Outfit catalog cache is invalid; refresh it to rebuild.")
        rows = _normalize_catalog_rows(raw["plugins"], cached=True) if raw["plugins"] else []
    except (OSError, ValueError) as error:
        cache_error = error
        rows, raw = [], {}
    source = "cache" if rows else "none"
    if not rows:
        # Packaged public data is read through Path only. Store would chmod a
        # shared/read-only installation directory and is never appropriate here.
        try:
            with BOOTSTRAP_CATALOG_PATH.open("rb") as stream:
                data = stream.read(MAX_CATALOG_BYTES + 1)
            if len(data) > MAX_CATALOG_BYTES:
                raise ValueError("Bundled catalog exceeds its limit.")
            bundled = safe_json_loads(data, "Bundled catalog")
            if (not isinstance(bundled, dict) or not listing_date(bundled.get("generatedAt"))
                    or "T" not in bundled["generatedAt"]):
                raise ValueError("Bundled catalog requires its public source timestamp.")
            rows, generated = normalize_catalog(bundled)
            raw = {"generatedAt": generated, "fetchedAt": 0}
            source = "bundled"
        except (OSError, ValueError):
            rows = []
            if cache_error is not None:
                memory["catalogSource"] = "none"
                raise ValueError("Outfit catalog cache is invalid; refresh it to rebuild.") from cache_error
    for row in rows:
        _normalized_item_fields(row, False)
        row.setdefault("_searchEvidenceCache", {})
    carry_catalog_memos(rows, cached)
    generated = one_line(raw.get("generatedAt"), 64)
    fetched = raw.get("fetchedAt", 0)
    result = (rows, fetched if type(fetched) in (int, float) and math.isfinite(fetched) and fetched >= 0 else 0, generated)
    memory["catalog"] = result
    memory["catalogStamp"] = stamp
    memory["catalogSource"] = source
    return result


def catalog_source_metadata(store: Store, generated: str) -> dict[str, Any]:
    return {"catalogSource": store.memory.get("catalogSource", "none"),
            "catalogBuiltAt": generated, "sourceDate": generated}


def save_catalog(store: Store, items: list[dict[str, Any]], generated: str, now: float) -> None:
    previous = store.memory.get("catalog")
    stored_items = [
        {key: value for key, value in item.items() if not key.startswith("_")}
        for item in items
    ]
    with store.scoped_lock():
        store.write(
            "catalog.json",
            {"schema": CATALOG_SCHEMA, "fetchedAt": now, "generatedAt": generated, "plugins": stored_items},
            MAX_CACHE_BYTES,
        )
        for item in items:
            _normalized_item_fields(item, False)
            item.setdefault("_searchEvidenceCache", {})
            item.setdefault("_recommendationCache", {})
        carry_catalog_memos(items, previous)
        getattr(store, "memory", {})["catalog"] = (items, now, generated)
        store.memory["catalogStamp"] = store.stamp("catalog.json")
        store.memory["catalogSource"] = "cache" if items else "none"


def preview_cache_summary(store: Store, clear: bool = False) -> dict[str, int]:
    if clear:
        with store.scoped_lock():
            # Retire in-flight negative/discovery writes as well as disk state.
            store.write("preview-generation.json", {"generation": uuid.uuid4().hex}, 1024)
            return _preview_cache_summary(store, clear=True)
    return _preview_cache_summary(store)


def _preview_cache_summary(store: Store, clear: bool = False) -> dict[str, int]:
    total = count = removed = 0
    for name in os.listdir(store.fd):
        if not (PREVIEW_FILENAME.fullmatch(name) or LEGACY_PREVIEW_FILENAME.fullmatch(name)
                or THUMBNAIL_FILENAME.fullmatch(name)
                or (clear and name in {"thumbnail-readmes.json", "thumbnail-failures.json"})):
            continue
        try:
            info = os.stat(name, dir_fd=store.fd, follow_symlinks=False)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
                continue
            if clear:
                os.unlink(name, dir_fd=store.fd)
                removed += 1
            else:
                count += 1
                total += info.st_size
        except FileNotFoundError:
            pass
    return {"files": count, "bytes": total, "removed": removed}


def diagnostics(store: Store, preferences_store: Store) -> dict[str, Any]:
    """Explicit allowlist: never report paths, device names, profile, or environment."""
    versions = {"python": ".".join(map(str, sys.version_info[:3])), "omarchy": "unknown", "qt": "unknown"}
    try:
        packages = run_command([COMMANDS["pacman"], "-Q", "omarchy", "qt6-base"], 3, 4096).decode()
        for line in packages.splitlines():
            match = re.fullmatch(r"(omarchy|qt6-base) ([0-9][A-Za-z0-9.+:_-]{0,70})", line)
            if match:
                versions["omarchy" if match[1] == "omarchy" else "qt"] = match[2]
    except (OSError, ValueError, TimeoutError):
        pass
    cache = {}
    for label, loader in (("catalog", load_catalog), ("likes", load_engagement)):
        try:
            result = loader(store)
            cache[label] = {"state": "ready" if result[0] else "empty", "entries": len(result[0]),
                            "fetchedAt": result[1]}
        except (OSError, ValueError):
            cache[label] = {"state": "unavailable", "entries": 0, "fetchedAt": 0}
    try:
        cache["readmes"] = readme_index_data(store, load_catalog(store)[0])
    except (OSError, ValueError):
        cache["readmes"] = {"error": "Catalog unavailable"}
    return {"schema": 1, "plugin": APP_ID, "versions": versions, "cache": cache,
            "previews": preview_cache_summary(store),
            "commands": {name: os.access(path, os.X_OK) for name, path in COMMANDS.items()},
            "storageWritable": {"cache": os.access(store.base, os.W_OK),
                                "config": os.access(preferences_store.base, os.W_OK)},
            "multimediaModule": Path("/usr/lib/qt6/qml/QtMultimedia/qmldir").is_file()}


PLUGIN_MUTATIONS = {
    "install-plugin", "enable-plugin", "disable-plugin", "place-plugin", "remove-plugin", "update-plugin",
}
PROGRESS_ACTIONS = PLUGIN_MUTATIONS | {"catalog-refresh", "prepare-search", "index-readmes", "analyze", "rescan", "refresh"}


def mutation_observed(
    action: str, request: dict[str, Any], identity: str, inventory: list[dict[str, Any]],
) -> bool:
    target = next((item for item in inventory if item["id"] == identity), None)
    if action == "remove-plugin":
        return target is None
    if target is None:
        return False
    if request.get("reviewedRevision") and target.get("installedRevision") != full_sha(request["reviewedRevision"]):
        return False
    if action == "update-plugin":
        expected = full_sha(request.get("expectedRevision"))
        version = request.get("expectedVersion")
        return bool(expected and full_sha(target.get("installedRevision")) == expected
                    and (not version or target.get("installedVersion") == version))
    if action == "disable-plugin":
        return target["enabled"] is False
    if action == "enable-plugin":
        section = one_line(request.get("barSection"), 12)
        return target["enabled"] is True and (
            section not in {"left", "center", "right"}
            or (target.get("barSectionKnown") is True and target.get("barSection") == section)
        )
    if action == "place-plugin":
        return (
            target["enabled"] is True
            and target.get("barSectionKnown") is True
            and target.get("barSection") == one_line(request.get("barSection"), 12)
        )
    if action == "install-plugin":
        if not full_sha(request.get("reviewedRevision")):
            return False
        section = one_line(request.get("barSection"), 12)
        if section in {"left", "center", "right"}:
            return (
                target["enabled"] is True
                and target.get("barSectionKnown") is True
                and target.get("barSection") == section
            )
        if request.get("enableAfter") is True:
            return target["enabled"] is True
        return target["enabled"] is False
    return False


def plugin_mutation_response(
    request: dict[str, Any], action: str, generation: int, identity: str,
    profile: list[dict[str, Any]], unavailable: list[str], inventory: list[dict[str, Any]],
    inventory_unavailable: bool, preferences: dict[str, Any], operation: dict[str, Any],
    notice: str, error: str,
) -> dict[str, Any]:
    operation = dict(operation)
    operation["observed"] = not inventory_unavailable and mutation_observed(
        action, {**request, **({"expectedVersion": operation.get("expectedVersion")} if action == "update-plugin" else {})},
        identity, inventory,
    )
    if action == "update-plugin":
        operation["observed"] = operation["observed"] and operation.get("verified") is True
    if inventory_unavailable:
        unavailable = sorted(set(unavailable + ["installed plugins"]))
    elif any(item.get("barSectionKnown") is False for item in inventory):
        unavailable = sorted(set(unavailable + ["bar sections"]))
    return {
        "ok": True,
        "generation": generation,
        "action": action,
        "responseKind": "mutation",
        "profile": profile,
        "unavailable": unavailable,
        "installed": sorted(item["id"] for item in inventory),
        "inventory": inventory,
        "inventoryAuthoritative": not inventory_unavailable,
        "preferences": preferences,
        "operation": operation,
        "notice": notice,
        "error": error,
    }


def run(
    request: Any,
    store: Store | None,
    now: float | None = None,
    preferences_store: Store | None = None,
    progress: Any = None,
) -> dict[str, Any]:
    if not isinstance(request, dict):
        raise ValueError("Outfit request must be a JSON object.")
    action = one_line(request.get("action"), 20)
    if action not in {
        "load", "analyze", "search", "quick-setup", "refresh", "rescan", "verify-inventory",
        "save-preferences", "set-feedback", "install-plugin", "enable-plugin",
        "disable-plugin", "place-plugin", "remove-plugin", "readme-plugin", "thumbnails", "enrich",
        "diagnostics", "clear-previews", "discover", "index-readmes", "save-density",
        "context", "save-interests", "preview-interest", "matches", "review-matches",
        "host-lifecycle", "open-plugin", "catalog-refresh", "prepare-search",
        "check-updates", "update-plugin", "self-update", "self-update-status",
    }:
        raise ValueError("Outfit request has an unsupported action.")
    generation = request.get("generation")
    generation = generation if type(generation) is int and 0 <= generation <= 2_147_483_647 else 0
    if action in {"self-update", "self-update-status"}:
        if store is None:
            raise ValueError("Self-update requires the Outfit cache store.")
        spec = importlib.util.spec_from_file_location("outfit_self_update", Path(__file__).with_name("self_update.py"))
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        backend = types.SimpleNamespace(**globals())
        result = helper.launch(backend, request, store) if action == "self-update" else helper.status(backend, store)
        return {**result, "action": action, "generation": generation, "responseKind": "self-update"}
    if action == "host-lifecycle":
        return host_lifecycle(request, generation)
    if action == "open-plugin":
        return open_plugin(request, generation)
    progress_count = 0
    if request.get("streamProgress") is not True:
        progress = None
    def emit(name: str, message: str, **counts: Any) -> None:
        nonlocal progress_count
        if progress is not None and action in PROGRESS_ACTIONS:
            progress_count += 1
            progress({"ok": True, "event": "progress", "responseKind": "progress", "final": False,
                      "generation": generation, "action": action, "phase": name,
                      "message": message, "sequence": progress_count, **counts})
    def phase(name: str) -> None:
        if progress is not None and action in PLUGIN_MUTATIONS and progress_count < 12:
            labels = {"checking": "Checking installed plugins", "installing": "Installing plugin",
                      "inventory": "Waiting for Omarchy to discover the installed plugin",
                      "enabling": "Enabling plugin", "disabling": "Disabling plugin",
                      "placing": "Placing bar widget", "removing": "Removing plugin",
                      "verifying": "Verifying the resulting plugin state", "updating": "Updating plugin"}
            emit(name, labels[name], pluginId=plugin_id(request.get("pluginId")))
    current_time = time.time() if now is None else now
    notice = ""
    error = ""
    operation: dict[str, Any] = {}
    preferences_store = preferences_store or store
    if action == "check-updates":
        return check_plugin_updates(request, store, current_time, generation)
    if action in {"diagnostics", "clear-previews"}:
        cleared = preview_cache_summary(store, clear=True) if action == "clear-previews" else None
        return {"ok": True, "action": action, "generation": generation,
                "diagnostics": diagnostics(store, preferences_store),
                "notice": f"Cleared {cleared['removed']} preview files. Preferences and catalog preserved." if cleared else "Diagnostics ready.",
                "error": ""}
    try:
        preferences = load_preferences(preferences_store)
    except ValueError as preferences_error:
        preferences = dict(DEFAULT_PREFERENCES)
        error = str(preferences_error)
    if action == "update-plugin":
        return execute_plugin_update(request, store, current_time, generation, preferences, phase)
    if action in {"context", "save-interests", "preview-interest", "matches", "review-matches"}:
        if error:
            raise ValueError(error)
        return interest_action(request, store, preferences_store, preferences, current_time, generation)
    if action == "save-density":
        value = request.get("browseDensity")
        if value not in ("comfortable", "compact", "dense", "list"):
            raise ValueError("Choose Comfortable, Compact, Dense, or List.")
        if error:
            raise ValueError("Repair or reset Outfit's preferences before saving density.")
        # Patch the latest stored preference, not a stale UI copy of settings.
        save_preferences(preferences_store, {"browseDensity": value})
        return {"ok": True, "action": action, "generation": generation, "browseDensity": value}
    if action == "thumbnails":
        values = request.get("pluginIds")
        ids = {plugin_id(value) for value in values[:MAX_THUMBNAIL_BATCH]} \
            if isinstance(values, list) else set()
        thumbnails = {}
        if preferences["marketplaceThumbnails"] and not error:
            catalog, _fetched, revision = load_catalog(store)
            thumbnails = materialize_thumbnails(
                store, [item for item in catalog if item["id"] in ids], revision,
                allow_readme=preferences["readmeEnrichment"],
            )
        return {"ok": True, "action": action, "generation": generation, "thumbnails": thumbnails}
    if action == "save-preferences":
        if error:
            raise ValueError(error)
        raw_preferences = request.get("preferences") if isinstance(request.get("preferences"), dict) else {}
        scoped = {key: value for key, value in validate_preferences({**preferences, **raw_preferences}).items()
                  if key in raw_preferences and key not in {"schema", "browseDensity"}}
        if preferences_store.stamp("interests.json") is not None:
            scoped.pop("services", None)
        save_preferences(preferences_store, scoped)
        preferences = load_preferences(preferences_store)
        notice = "Your Outfit settings were saved locally."
        error = ""
        profile = [
            item for item in validate_profile(request.get("profile"))
            if item.get("source", "hardware") == "hardware" or item["id"].startswith("capability-")
        ]
        inventory = validate_inventory(request.get("inventory"))
        unavailable_values = request.get("unavailable") if isinstance(request.get("unavailable"), list) else []
        unavailable = [one_line(value, 80) for value in unavailable_values[:32] if one_line(value, 80)]
        return {
            "ok": True,
            "generation": generation,
            "action": action,
            "responseKind": "preferences",
            "profile": profile,
            "unavailable": unavailable,
            "installed": sorted(item["id"] for item in inventory),
            "inventory": inventory,
            "preferences": preferences,
            "notice": notice,
            "error": error,
        }
    elif action == "set-feedback":
        raise ValueError("Not a fit feedback has been retired. Saved legacy feedback no longer changes recommendations.")
    elif action in {"enable-plugin", "disable-plugin", "place-plugin", "remove-plugin"}:
        target_id = plugin_id(request.get("pluginId"))
        if not target_id:
            raise ValueError("Plugin management requires a valid plugin ID.")
        if target_id in {APP_ID, LEGACY_APP_ID} and action != "place-plugin":
            raise ValueError("Outfit cannot change its own running state.")
        phase("checking")
        authoritative_inventory, inventory_unavailable = scan_inventory()
        if inventory_unavailable:
            raise ValueError("Outfit could not verify authoritative plugin inventory.")
        target = next((item for item in authoritative_inventory if item["id"] == target_id), None)
        if target is None:
            raise ValueError("The selected plugin is no longer installed.")
        if "reviewedRevision" in request and action in {"enable-plugin", "place-plugin"}:
            # Retried installation activation retains its original authorization.
            catalog, _fetched, _generated = load_catalog(store)
            listed = next((item for item in catalog if item["id"] == target_id), None)
            reviewed = full_sha(request.get("reviewedRevision"))
            if not listed or not reviewed or reviewed != listed.get("listingCommit"):
                raise ValueError("The marketplace listing changed; review the selected plugin again.")
            verify_reviewed_install(target_id, reviewed, listed["repo"])
        if action == "enable-plugin":
            is_bar_replacement = "bar" in target.get("kinds", [])
            if not target["canDisable"] and not is_bar_replacement:
                raise ValueError("Omarchy does not expose an on/off toggle for this plugin.")
            if not mutation_observed(action, request, target_id, [target]):
                try:
                    command = [COMMANDS["omarchy"], "plugin", "enable", target_id]
                    section = one_line(request.get("barSection"), 12)
                    if is_bar_widget(target) and section in {"left", "center", "right"}:
                        command.append(section)
                    phase("enabling")
                    run_activation_command(command, target)
                except (OSError, TimeoutError, ValueError) as command_error:
                    raise ValueError("Omarchy could not enable the selected plugin.") from command_error
            notice = "Plugin enabled."
            operation = {"pluginId": target_id, "status": "completed", "message": notice}
        elif action == "disable-plugin":
            if not target["canDisable"]:
                raise ValueError("Omarchy does not allow this plugin to be disabled.")
            if target["enabled"]:
                try:
                    phase("disabling")
                    run_command([COMMANDS["omarchy"], "plugin", "disable", target_id], 35, 32 * 1024)
                except (OSError, TimeoutError, ValueError) as command_error:
                    raise ValueError("Omarchy could not disable the selected plugin.") from command_error
            notice = "Plugin disabled. It remains installed."
            operation = {"pluginId": target_id, "status": "completed", "message": notice}
        elif action == "place-plugin":
            section = one_line(request.get("barSection"), 12)
            if not is_bar_widget(target) or section not in {"left", "center", "right"}:
                raise ValueError("Bar placement requires a bar-widget plugin and valid section.")
            try:
                if not mutation_observed(action, request, target_id, [target]):
                    phase("placing")
                    run_activation_command([COMMANDS["omarchy"], "plugin", "enable", target_id, section], target)
            except (OSError, TimeoutError, ValueError) as command_error:
                raise ValueError("Omarchy could not move the selected bar widget.") from command_error
            notice = f"Plugin moved to the {section} section."
            operation = {"pluginId": target_id, "status": "completed", "message": notice}
        else:
            if target["firstParty"]:
                raise ValueError("First-party Omarchy plugins cannot be removed.")
            try:
                phase("removing")
                output = run_command(
                    [COMMANDS["omarchy"], "plugin", "remove", target_id, "--yes"],
                    35, 64 * 1024,
                )
            except (OSError, TimeoutError, ValueError) as command_error:
                raise ValueError("Omarchy could not remove the selected plugin.") from command_error
            notice = one_line(output.decode("utf-8", "replace"), 240) or "Plugin removed."
            operation = {"pluginId": target_id, "status": "completed", "message": notice}
        error = ""
        if action != "remove-plugin":
            revision = installed_revision(target_id)
            if revision:
                operation["installedRevision"] = revision
        hardware_profile = [
            item for item in validate_profile(request.get("profile"))
            if item.get("source", "hardware") == "hardware" or item["id"].startswith("capability-")
        ]
        unavailable_values = request.get("unavailable") if isinstance(request.get("unavailable"), list) else []
        unavailable = [one_line(value, 80) for value in unavailable_values[:32] if one_line(value, 80)]
        phase("verifying")
        inventory, inventory_unavailable = scan_inventory()
        return plugin_mutation_response(
            request, action, generation, target_id, hardware_profile, unavailable,
            inventory, inventory_unavailable, preferences, operation, notice, error,
        )
    if action == "verify-inventory":
        profile = [
            item for item in validate_profile(request.get("profile"))
            if item.get("source", "hardware") == "hardware" or item["id"].startswith("capability-")
        ]
        unavailable_values = request.get("unavailable") if isinstance(request.get("unavailable"), list) else []
        unavailable = [
            one_line(value, 80) for value in unavailable_values[:32]
            if one_line(value, 80) and one_line(value, 80) not in {"installed plugins", "bar sections"}
        ]
        inventory, inventory_unavailable = scan_inventory()
        if inventory_unavailable:
            unavailable.append("installed plugins")
        elif any(item.get("barSectionKnown") is False for item in inventory):
            unavailable.append("bar sections")
        return {
            "ok": True,
            "generation": generation,
            "action": action,
            "responseKind": "inventory",
            "profile": profile,
            "unavailable": sorted(set(unavailable)),
            "installed": sorted(item["id"] for item in inventory),
            "inventory": inventory,
            "inventoryAuthoritative": not inventory_unavailable,
            "preferences": preferences,
            "notice": "Plugin inventory checked." if not inventory_unavailable else "",
            "error": "" if not inventory_unavailable else "Could not verify plugin inventory.",
        }
    try:
        items, fetched_at, generated_at = load_catalog(store)
    except ValueError as cache_error:
        items, fetched_at, generated_at = [], 0, ""
        error = error or str(cache_error)

    local_only = request.get("localOnly") is True
    should_fetch = not local_only and (action in {"refresh", "catalog-refresh"} or (action in {"analyze", "enrich"}
                    and (not items or current_time - fetched_at > CATALOG_MAX_AGE)))
    if should_fetch:
        try:
            emit("catalog", "Downloading marketplace catalog", bytesReceived=0)
            fresh_items, fresh_generated = fetch_catalog(
                **({"progress": lambda **counts: emit("catalog", "Downloading marketplace catalog", **counts)}
                   if progress is not None else {}))
            save_catalog(store, fresh_items, fresh_generated, current_time)
            items, generated_at = fresh_items, fresh_generated
            fetched_at = current_time
            emit("catalog", "Marketplace catalog saved", processed=len(items), total=len(items))
            notice = "Marketplace catalog refreshed."
            error = ""
        except (OSError, TimeoutError, urllib.error.URLError, ValueError):
            error = "Could not refresh the marketplace. " + ("Using the saved catalog." if items else "Check your connection and try again.")

    if action == "catalog-refresh":
        _likes, likes_at, likes_notice = update_engagement(store, "load" if local_only else "refresh", current_time)
        return {"ok": True, "action": action, "generation": generation, "responseKind": "catalog",
                "catalogCount": len(items), "categories": sorted({item["category"] for item in items if item["category"]}),
                "fetchedAt": fetched_at, "generatedAt": generated_at, **catalog_source_metadata(store, generated_at),
                "likesFetchedAt": likes_at, "readmeIndex": readme_index_data(store, items, now=current_time),
                "searchPack": search_pack_state(store, current_time), "notice": " ".join(filter(None, (notice, likes_notice))),
                "error": error}

    if action == "prepare-search":
        enabled = preferences["readmeEnrichment"] and preferences["readmeIndexing"]
        pack = (prepare_search(store, current_time, emit) if enabled and not local_only and not error
                else search_pack_state(store, current_time))
        # Catalog may have advanced while the pack downloaded.
        try:
            items, fetched_at, generated_at = load_catalog(store)
        except (OSError, ValueError):
            error = error or "Catalog unavailable; local search is retained."
        return {"ok": True, "action": action, "generation": generation, "responseKind": "search-prepared",
                "searchPack": {**pack, "enabled": enabled},
                "readmeIndex": readme_index_data(store, items, now=current_time),
                "catalogCount": len(items), "fetchedAt": fetched_at, "generatedAt": generated_at,
                **catalog_source_metadata(store, generated_at), "error": error or pack.get("error", "")}

    if action == "index-readmes":
        if not preferences["readmeEnrichment"] or not preferences["readmeIndexing"] or local_only or error:
            return {"ok": True, "action": action, "generation": generation,
                    "readmeIndex": readme_index_data(store, items, now=current_time), "error": error}
        return {"ok": True, "action": action, "generation": generation,
                "readmeIndex": index_readmes(store, items, current_time, **({"progress": emit} if progress is not None else {})), "error": ""}

    if action == "install-plugin":
        target_id = plugin_id(request.get("pluginId"))
        if not target_id:
            raise ValueError("Plugin installation requires a valid plugin ID.")
        target = next((item for item in items if item["id"] == target_id), None)
        if target is None or target.get("installAvailable") is not True or not target.get("repo"):
            raise ValueError("This marketplace entry is not available for direct installation.")
        reviewed_revision = full_sha(request.get("reviewedRevision"))
        if not reviewed_revision or reviewed_revision != target.get("listingCommit"):
            raise ValueError("The marketplace listing changed; review the selected plugin again.")
        phase("checking")
        authoritative_inventory, inventory_unavailable = scan_inventory()
        if inventory_unavailable:
            raise ValueError("Outfit could not verify authoritative plugin inventory.")
        if any(item["id"] == target_id for item in authoritative_inventory):
            raise ValueError("The selected plugin is already installed.")
        try:
            phase("installing")
            output = install_reviewed_plugin(target, reviewed_revision)
        except (OSError, TimeoutError, ValueError) as command_error:
            raise ValueError("Could not complete installation of the exact reviewed commit. "
                             "No fallback to the repository's latest version was attempted.") from command_error
        error = ""
        section = one_line(request.get("barSection"), 12)
        enable_after = request.get("enableAfter") is True
        should_activate = (is_bar_widget(target) and section in {"left", "center", "right"}) or enable_after
        if should_activate:
            phase("inventory")
        discovered = wait_for_plugin_inventory(target_id) if should_activate else None
        if should_activate and discovered is None:
            error = "The plugin was installed but Omarchy did not finish loading it."
            notice = "Plugin installed; activation needs attention."
            operation = {"pluginId": target_id, "status": "partial", "message": error}
        elif is_bar_widget(target) and section in {"left", "center", "right"}:
            try:
                if not mutation_observed("enable-plugin", {"barSection": section}, target_id, [discovered]):
                    phase("placing")
                run_activation_command(
                    [COMMANDS["omarchy"], "plugin", "enable", target_id, section], discovered,
                )
            except (OSError, TimeoutError, ValueError) as command_error:
                error = "The plugin was installed but Omarchy could not place its bar widget."
                notice = "Plugin installed; activation needs attention."
                operation = {"pluginId": target_id, "status": "partial", "message": error}
            else:
                notice = f"Plugin installed and placed in the {section} section."
                operation = {"pluginId": target_id, "status": "completed", "message": notice}
        elif enable_after:
            try:
                if not discovered["enabled"]:
                    phase("enabling")
                run_activation_command(
                    [COMMANDS["omarchy"], "plugin", "enable", target_id], discovered,
                )
            except (OSError, TimeoutError, ValueError) as command_error:
                error = "The plugin was installed but Omarchy could not enable it."
                notice = "Plugin installed; activation needs attention."
                operation = {"pluginId": target_id, "status": "partial", "message": error}
            else:
                notice = "Plugin installed and enabled."
                operation = {"pluginId": target_id, "status": "completed", "message": notice}
        else:
            notice = one_line(output.decode("utf-8", "replace"), 240) or "Plugin installed. Enable it when ready."
            operation = {"pluginId": target_id, "status": "completed", "message": notice}
        operation["reviewedRevision"] = target.get("listingCommit", "")
        revision = installed_revision(target_id)
        if revision:
            operation["installedRevision"] = revision
        hardware_profile = [
            item for item in validate_profile(request.get("profile"))
            if item.get("source", "hardware") == "hardware" or item["id"].startswith("capability-")
        ]
        unavailable_values = request.get("unavailable") if isinstance(request.get("unavailable"), list) else []
        unavailable = [one_line(value, 80) for value in unavailable_values[:32] if one_line(value, 80)]
        phase("verifying")
        inventory, inventory_unavailable = scan_inventory()
        return plugin_mutation_response(
            request, action, generation, target_id, hardware_profile, unavailable,
            inventory, inventory_unavailable, preferences, operation, notice, error,
        )

    if action == "load":
        interest_document = load_interests(preferences_store, preferences)
        for item in items:
            item["_showReadme"] = preferences["readmeEnrichment"]
        attach_interest_evidence(store, items, interest_document["criteria"], [], preferences["readmeEnrichment"], interest_document["revision"])
        try:
            cached_likes, cached_likes_at = load_engagement(store)
        except (ValueError, OSError):
            cached_likes, cached_likes_at = {}, 0
        for item in items:
            stats = cached_likes.get(item["id"], {})
            item["_likes"] = stats.get("hearts")
            item["_views"] = stats.get("views")
            item["_copies"] = stats.get("copies")
        return {
            "ok": True,
            "generation": generation,
            "action": action,
            "profile": [],
            "unavailable": [],
            "installed": [],
            "inventory": [],
            "rows": [],
            "setup": setup_catalog(items, [], set(), not_fit=set(preferences["notFit"])),
            "likesFetchedAt": cached_likes_at,
            "catalogCount": len(items),
            "categories": sorted({item["category"] for item in items if item["category"]}),
            "fetchedAt": fetched_at,
            "generatedAt": generated_at,
            **catalog_source_metadata(store, generated_at),
            "searchPack": {**search_pack_state(store, current_time),
                           "enabled": preferences["readmeEnrichment"] and preferences["readmeIndexing"]},
            "readmesFetched": 0,
            "readmeIndex": readme_index_data(store, items, now=current_time),
            "readmePluginId": "",
            "readmeContent": "",
            "preferences": preferences,
            "inputs": context_inputs(interest_document, request),
            "criteriaRevision": interest_document["revision"],
            "changes": {"added": [], "removed": []},
            "filterCounts": filter_counts(items, set()),
            "query": "",
            "category": "",
            "installFilter": "all",
            "partyFilter": "all",
            "notice": notice,
            "error": error,
        }

    scan = supplied_scan(request, store.memory.get("scan"), previous=action in {"analyze", "rescan"})
    previous_profile = validate_profile(request.get("previousProfile", request.get("profile", scan.get("observations", []))))
    if action in {"analyze", "rescan"}:
        scanned = scan_profile(**({"progress": emit} if progress is not None else {}))
        hardware_profile, unavailable, inventory = scanned
        scan = accepted_scan(scanned, scan, previous_profile, current_time)
        store.memory["scan"] = scan
        hardware_profile = scan["observations"]
    elif action in {"install-plugin", "enable-plugin", "disable-plugin", "place-plugin", "remove-plugin"}:
        hardware_profile = [
            item for item in validate_profile(request.get("profile"))
            if item.get("source", "hardware") == "hardware"
        ]
        unavailable_values = request.get("unavailable") if isinstance(request.get("unavailable"), list) else []
        unavailable = [one_line(value, 80) for value in unavailable_values[:32] if one_line(value, 80)]
        inventory, inventory_unavailable = scan_inventory()
        if inventory_unavailable:
            unavailable = sorted(set(unavailable + ["installed plugins"]))
    else:
        hardware_profile = [
            item for item in validate_profile(request.get("profile", scan.get("observations", [])))
            if item.get("source", "hardware") == "hardware" or item["id"].startswith("capability-")
        ]
        unavailable_values = request.get("unavailable") if isinstance(request.get("unavailable"), list) else []
        unavailable = [one_line(value, 80) for value in unavailable_values[:32] if one_line(value, 80)]
        inventory = validate_inventory(request.get("inventory"))
        if not inventory:
            installed_values = request.get("installed") if isinstance(request.get("installed"), list) else []
            inventory = validate_inventory([
                {"id": value, "name": value, "firstParty": False}
                for value in installed_values[:MAX_INVENTORY_ROWS]
            ])
    installed = {item["id"] for item in inventory}
    if action in {"quick-setup", "discover"}:
        for item in items:
            service_matches(item)
    items = merge_inventory(items, inventory)
    engagement_action = "quick-setup" if local_only else ("analyze" if action == "enrich" else action)
    likes, likes_fetched, likes_notice = update_engagement(store, engagement_action, current_time)
    for item in items:
        stats = likes.get(item["id"], {})
        item["_likes"] = stats.get("hearts")
        item["_views"] = stats.get("views")
        item["_copies"] = stats.get("copies")
        item["_likesFetchedAt"] = likes_fetched if item["id"] in likes else 0
    if likes_notice:
        notice = " ".join(part for part in (notice, likes_notice) if part)
    interest_document = load_interests(preferences_store, preferences)
    profile = [item for item in hardware_profile if item["id"] not in interest_document["ignoredSignals"]]
    changes = profile_changes(previous_profile, hardware_profile) if action in {"analyze", "rescan"} else {"added": [], "removed": []}
    if action == "rescan":
        change_count = len(changes["added"]) + len(changes["removed"])
        notice = f"Hardware changed: {change_count} signal{'s' if change_count != 1 else ''}." if change_count else "Hardware check complete; no changes detected."
        if scan.get("state") in {"partial", "failed"}:
            notice = "Hardware check partially available; last confirmed observations retained where needed."

    if action in {"quick-setup", "discover"}:
        try:
            setup_readmes = load_readmes(store)
        except ValueError:
            setup_readmes = {}
        attach_cached_readmes(items, setup_readmes)
        for item in items:
            item["_showReadme"] = preferences["readmeEnrichment"]
        attach_interest_evidence(store, items, interest_document["criteria"], profile, preferences["readmeEnrichment"], interest_document["revision"])
        if action == "discover":
            return {"ok":True, "action":action, "generation":generation,
                    "discovery":discovery_catalog(items, profile, installed, preferences, request, current_time),
                    "criteriaRevision": interest_document["revision"],
                    "error":error, "notice":notice}
        query = one_line(request.get("setupQuery"), 160)
        index_summary = readme_index_data(store, items, query if preferences["readmeEnrichment"] else "", current_time)
        group = one_line(request.get("setupGroup"), 40)
        sort = one_line(request.get("setupSort"), 20)
        requested_services = request.get("setupServices")
        if not isinstance(requested_services, list):
            requested_services = []
        selected_services = [
            identity for value in requested_services[:MAX_SERVICE_CHOICES]
            if (identity := service_id(value))
        ]
        selected_service = service_id(request.get("setupServiceFilter"))
        install_filter = one_line(request.get("setupInstallFilter"), 20)
        party_filter = one_line(request.get("setupPartyFilter"), 20)
        hardware_only = request.get("setupHardwareOnly") is True
        category = one_line(request.get("setupCategory"), 80)
        filter_values = request.get("setupInterestCriteria", [])
        if not isinstance(filter_values, list) or len(filter_values) > MAX_INTERESTS * 2:
            raise ValueError("Invalid interest filters.")
        filter_criteria = []
        filter_choices = []
        filter_keys: set[str] = set()
        for value in filter_values:
            key = value.get("key") if isinstance(value, dict) else None
            if not isinstance(key, str) or not re.fullmatch(r"interest-[0-9a-f]{32}", key) or key in filter_keys:
                raise ValueError("Invalid or duplicate interest filter.")
            criterion = validate_criterion(value.get("criterion"))
            if criterion["serviceId"]:
                raise ValueError("Curated services use their existing service filter.")
            filter_keys.add(key)
            if not criterion["enabled"]:
                continue
            filter_criteria.append({**criterion, "id": key})
            filter_choices.append({"id": key, "name": criterion["label"], "category": "Interests"})
        filter_matches = {}
        if filter_criteria:
            # Draft filters are local query inputs only. Use independent item
            # records so draft terms cannot alter saved recommendation scores.
            filter_items = [dict(item) for item in items]
            attach_interest_evidence(store, filter_items, filter_criteria, [], preferences["readmeEnrichment"])
            filter_matches = {item["id"]: matched_interests(item, preferences["readmeEnrichment"])
                              for item in filter_items}
        setup = setup_catalog(
            items,
            profile,
            installed,
            query,
            group,
            sort,
            request.get("setupPage"),
            request.get("setupPageSize"),
            set(preferences["notFit"]),
            selected_services,
            selected_service,
            install_filter,
            party_filter,
            hardware_only,
            category,
            one_line(request.get("setupGrouping"), 20),
            one_line(request.get("setupVerification"), 20),
            filter_choices,
            filter_matches,
            store,
        )
        return {
            "ok": True,
            "generation": generation,
            "action": action,
            "profile": hardware_profile,
            "scan": scan,
            "criteriaRevision": interest_document["revision"],
            "unavailable": unavailable,
            "installed": sorted(installed),
            "inventory": inventory,
            "setup": setup,
            "readmeIndex": index_summary,
            "likesFetchedAt": likes_fetched,
            "dataWarning": likes_notice,
            "catalogCount": len(items),
            "fetchedAt": fetched_at,
            "generatedAt": generated_at,
            "preferences": preferences,
            "notice": notice,
            "error": error,
        }

    query = one_line(request.get("query"), 160)
    category = one_line(request.get("category"), 80)
    install_filter = one_line(request.get("installFilter"), 20)
    party_filter = one_line(request.get("partyFilter"), 20)
    if install_filter not in {"all", "installed", "available"}:
        install_filter = "all"
    if party_filter not in {"all", "first-party", "third-party"}:
        party_filter = "all"
    if category and category not in {item["category"] for item in items}:
        category = ""

    try:
        readmes = load_readmes(store)
    except ValueError:
        readmes = {}
        error = error or "The README index was invalid and has been reset."
    include_readme = preferences["readmeEnrichment"]
    readme_plugin_id = ""
    readme_content = ""
    readme_blocks: list[dict[str, Any]] = []
    readme_media_items: list[dict[str, str]] = []
    readmes_fetched = 0
    if action == "readme-plugin":
        if not include_readme:
            raise ValueError("README content is disabled in Outfit settings.")
        readme_plugin_id = plugin_id(request.get("pluginId"))
        target = next((item for item in items if item["id"] == readme_plugin_id), None)
        if not readme_plugin_id or target is None or not target.get("listingCommit"):
            raise ValueError("The selected plugin has no validated README revision.")
        cached = readmes.get(readme_plugin_id)
        current_content = bool(
            cached
            and cached.get("commit") == target["listingCommit"]
            and cached.get("contentVersion") == README_CONTENT_VERSION
        )
        current_document = current_content and cached.get("documentVersion") == README_DOCUMENT_VERSION
        if not current_document:
            document = fetch_readme(target)
            if not document or document.get("ok") is not True:
                if not (cached and cached.get("commit") == target["listingCommit"]
                        and (cached.get("content") or cached.get("text"))):
                    raise ValueError("GitHub did not return this plugin's README.")
                # Offline upgrade: the old pinned plain document remains useful.
            else:
                readmes[readme_plugin_id] = {
                    "commit": target["listingCommit"],
                    "text": document["text"],
                    "content": document["content"],
                    "summary": document["summary"],
                    "media": validate_readme_media(document.get("media")),
                    "contentVersion": README_CONTENT_VERSION,
                    "documentVersion": document.get("documentVersion", 0),
                    "documentSource": readme_source(document.get("documentSource")),
                    "fetchedAt": current_time,
                }
                # Another helper may have fetched a newer catalog revision while
                # this request was in flight. Keep its disk entry, but render only
                # the document fetched for this request's pinned target.
                cached = readmes[readme_plugin_id]
                readmes = save_readmes(store, {readme_plugin_id: cached})
                readmes_fetched = 1
        readme_content = clean(cached.get("content"), MAX_README_TEXT) if cached else ""
        if cached and cached.get("documentVersion") == README_DOCUMENT_VERSION:
            readme_blocks = readme_document(cached.get("documentSource", ""), target)
        readme_media_items = validate_readme_media(cached.get("media")) if cached else []
        if not readme_content and not readme_media_items:
            raise ValueError("GitHub did not return usable README content or preview media for this plugin.")
        readme_media_items = materialize_readme_media(store, readme_media_items)
        notice = "README loaded from the plugin's validated revision."

    attach_cached_readmes(items, readmes)
    for item in items:
        item["_showReadme"] = include_readme
    attach_interest_evidence(store, items, interest_document["criteria"], profile, include_readme, interest_document["revision"])
    if include_readme and not local_only and action in {"analyze", "enrich"}:
        candidates = broad_candidates(
            items, profile, query, category, include_readme,
            installed, install_filter, party_filter,
        )
        readmes_fetched = enrich_readmes(store, candidates, readmes)
        attach_cached_readmes(items, readmes)
        for item in items:
            item["_showReadme"] = True

    if query:
        index_summary = readme_index_data(store, items, query if include_readme else "", current_time)
        rows = ranked_rows(
            items, profile, installed, query, category, include_readme,
            install_filter, party_filter, set(preferences["notFit"]),
        )
    elif action == "search" and not profile and not interest_document["criteria"]:
        rows = browse_rows(items, installed, category, install_filter, party_filter)
    else:
        rows = ranked_rows(
            items, profile, installed, "", category, include_readme,
            install_filter, party_filter, set(preferences["notFit"]),
        )

    return {
        "ok": True,
        "generation": generation,
        "action": action,
        "profile": hardware_profile,
        "scan": scan,
        "criteriaRevision": interest_document["revision"],
        "unavailable": unavailable,
        "installed": sorted(installed),
        "inventory": inventory,
        "rows": rows,
        "inventoryAuthoritative": "installed plugins" not in unavailable,
        "likesFetchedAt": likes_fetched,
        "dataWarning": likes_notice,
        "catalogCount": len(items),
        "categories": sorted({item["category"] for item in items if item["category"]}),
        "fetchedAt": fetched_at,
        "generatedAt": generated_at,
        "readmesFetched": readmes_fetched,
        "readmeIndex": index_summary if query else readme_index_data(store, items, now=current_time),
        "readmePluginId": readme_plugin_id,
        "readmeContent": readme_content,
        "readmeBlocks": readme_blocks,
        "readmeMedia": readme_media_items,
        "readmeMediaIndexed": bool(readme_plugin_id),
        "preferences": preferences,
        "changes": changes,
        "filterCounts": filter_counts(items, installed),
        "query": query,
        "category": category,
        "installFilter": install_filter,
        "partyFilter": party_filter,
        "operation": operation,
        "notice": notice,
        "error": error,
    }


def error_response(error: Exception, request: Any) -> dict[str, Any]:
    message = str(error) if isinstance(error, ValueError) else "Outfit could not complete the request."
    code = "request-failed"
    if isinstance(error, OSError):
        code = "storage-unavailable" if error.errno in {errno.EACCES, errno.EPERM, errno.EROFS, errno.ENOSPC, errno.EDQUOT} else "io-failed"
        if error.errno in {errno.ENOSPC, errno.EDQUOT}:
            message = "Outfit could not save data: the disk or storage quota is full. Free space and retry."
        elif error.errno in {errno.EACCES, errno.EPERM, errno.EROFS}:
            message = "Outfit cannot access its private storage. Check XDG config/cache permissions and retry."
    if isinstance(error, TimeoutError):
        code, message = "timed-out", "Outfit's request timed out. Cached results remain available; retry when ready."
    if "stale revision" in message:
        code = "stale-revision"
    action = one_line(request.get("action"), 20) if isinstance(request, dict) else ""
    generation = request.get("generation") if isinstance(request, dict) else 0
    generation = generation if type(generation) is int and 0 <= generation <= 2_147_483_647 else 0
    return {
        "ok": False,
        "generation": generation,
        "action": action,
        "error": one_line(message, 300),
        "errorCode": "inventory-unavailable" if "authoritative plugin inventory" in message else code,
        "retryable": "authoritative plugin inventory" in message,
        **({"event": "result", "final": True} if isinstance(request, dict) and
           request.get("streamProgress") is True and action in PROGRESS_ACTIONS else {}),
    }


def process_request(
    raw: bytes, store: Store, preferences_store: Store,
) -> dict[str, Any]:
    request: Any = None
    try:
        if len(raw) > MAX_REQUEST_BYTES:
            raise ValueError("Outfit request exceeds its size limit.")
        request = safe_json_loads(raw, "Outfit request")
        streaming = isinstance(request, dict) and request.get("streamProgress") is True and request.get("action") in PROGRESS_ACTIONS
        result = run(request, store, preferences_store=preferences_store, progress=write_response if streaming else None)
    except Exception as error:
        result = error_response(error, request)
    if isinstance(request, dict) and request.get("streamProgress") is True and request.get("action") in PROGRESS_ACTIONS:
        result.update(event="result", final=True)
    return result


def read_request(stream: Any) -> bytes:
    raw = stream.readline(MAX_REQUEST_BYTES + 1)
    return raw


def write_response(result: dict[str, Any]) -> None:
    output = json.dumps(result, ensure_ascii=True, separators=(",", ":")).encode(
        "utf-8", "backslashreplace",
    )
    if len(output) > MAX_OUTPUT_BYTES:
        fallback = {
            "ok": False,
            "generation": result.get("generation", 0),
            "action": result.get("action", ""),
            "error": "Outfit result exceeded its size limit.",
            **({"event": "result", "final": True} if result.get("final") is True else {}),
        }
        output = json.dumps(fallback, ensure_ascii=False, separators=(",", ":")).encode(
            "utf-8", "backslashreplace",
        )
    sys.stdout.buffer.write(output + b"\n")
    sys.stdout.buffer.flush()


def open_stores() -> tuple[Store, Store]:
    def xdg(name: str, fallback: str) -> Path:
        value = Path(os.environ.get(name, ""))
        return value if value.is_absolute() else Path.home() / fallback
    cache = Store(xdg("XDG_CACHE_HOME", ".cache") / APP_ID)
    try:
        return cache, Store(xdg("XDG_CONFIG_HOME", ".config") / APP_ID)
    except Exception:
        cache.close()
        raise


def serve() -> int:
    store = preferences_store = None
    try:
        while True:
            raw = read_request(sys.stdin.buffer)
            if not raw:
                return 0
            try:
                if store is None:
                    store, preferences_store = open_stores()
                result = process_request(raw, store, preferences_store)
            except Exception as error:
                try:
                    request = safe_json_loads(raw, "Outfit request") if len(raw) <= MAX_REQUEST_BYTES else {}
                except ValueError:
                    request = {}
                result = error_response(error, request)
            _terminate_all()
            write_response(result)
            if len(raw) > MAX_REQUEST_BYTES and not raw.endswith(b"\n"):
                return 1  # Do not drain an unbounded, unterminated request.
    finally:
        _terminate_all()
        if store is not None: store.close()
        if preferences_store is not None: preferences_store.close()


def main() -> int:
    store: Store | None = None
    preferences_store: Store | None = None
    request = {}
    try:
        raw = read_request(sys.stdin.buffer)
        if len(raw) <= MAX_REQUEST_BYTES:
            request = safe_json_loads(raw, "Outfit request")
        if isinstance(request, dict) and request.get("action") == "open-plugin":
            # The one-shot Open lane needs no cache/config directory or writes.
            result = run(request, None)
        else:
            store, preferences_store = open_stores()
            result = process_request(raw, store, preferences_store)
    except Exception as error:
        result = error_response(error, request)
    finally:
        _terminate_all()
        if store is not None:
            store.close()
        if preferences_store is not None:
            preferences_store.close()
    write_response(result)
    return 0 if result.get("ok") else 2


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, _terminate_all)
    signal.signal(signal.SIGINT, _terminate_all)
    raise SystemExit(serve() if "--serve" in sys.argv[1:] else main())
