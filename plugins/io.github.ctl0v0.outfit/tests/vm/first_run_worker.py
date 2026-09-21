#!/usr/bin/env python3
"""VM-only transport/hardware seam; executes the real backend and stores.

The capture runner copies this over demo/fixture_worker.py in its private guest
checkout. Production QML uses its existing demo helper path; it is not edited.
Only fixed release artifacts are served, through the production bounded reader.
Every other HTTP request fails locally. Native inventory is genuinely read-only.
"""
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import time
import urllib.error

if os.environ.get("OUTFIT_TEST_VM") != "1" or subprocess.run(
        ["systemd-detect-virt", "--vm"], stdout=subprocess.DEVNULL).returncode:
    raise SystemExit("Disposable VM only")
ROOT = Path(__file__).resolve().parents[1]
STATE = Path(os.environ["OUTFIT_DEMO_ROOT"])
PACK = Path(os.environ["OUTFIT_VM_PACK"])
SCENARIO = os.environ.get("OUTFIT_VM_SCENARIO", "cold")
os.environ.update(XDG_CONFIG_HOME=str(STATE / "config"), XDG_CACHE_HOME=str(STATE / "cache"))
spec = importlib.util.spec_from_file_location("production_outfit", ROOT / "scripts/outfit.py")
backend = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backend)

def event(kind, **values):
    raw = (json.dumps({"at": time.monotonic(), "pid": os.getpid(), "kind": kind, **values}) + "\n").encode()
    fd = os.open(STATE / "transport.jsonl", os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(fd, raw)
    finally:
        os.close(fd)

def blocked(*args, **kwargs):
    raise urllib.error.URLError("VM fixture: external network disabled")

# Fail closed even if a new production network path is added later.
socket.create_connection = blocked
backend.urllib.request.urlopen = blocked
manifest = json.loads((PACK / "latest.json").read_text())

class Response(io.BytesIO):
    def __init__(self, raw, asset):
        super().__init__(raw)
        self.headers = {"Content-Length": str(len(raw))}
        self.asset = asset

    def read1(self, size=-1):
        if self.asset:
            time.sleep(0.12)  # Deliberately paced fixture bytes, NOT network timing.
        return super().read(min(size, 65536))

class Opener:
    def open(self, request, timeout=20):
        url = request.full_url
        if url not in {backend.SEARCH_PACK_URL, manifest["assetUrl"]}:
            event("blocked-url", url=url)
            return blocked()
        event("pack-request", url=url, scenario=SCENARIO)
        if SCENARIO == "offline":
            return blocked()
        asset = url == manifest["assetUrl"]
        raw = (PACK / (url.rsplit("/", 1)[1] if asset else "latest.json")).read_bytes()
        if SCENARIO == "corrupt" and asset:
            raw = raw[:-1] + bytes([raw[-1] ^ 1])
        return Response(raw, asset)

backend.urllib.request.build_opener = lambda *args: Opener()

def fetch_bytes(url, *args, **kwargs):
    event("blocked-public-request", url=url)
    return blocked()

backend.fetch_bytes = fetch_bytes
original_inventory = backend.scan_inventory

def inventory():
    value = original_inventory()
    event("native-inventory", authoritative=not value[1], count=len(value[0]))
    return value

backend.scan_inventory = inventory

def hardware(progress=None):
    event("hardware-start")
    for index in range(20):
        time.sleep(1)
        if progress:
            progress("scan", "Fictional local check", processed=index + 1, total=20)
    rows, unavailable = inventory()
    event("hardware-finish")
    return backend.ScanResult([], ["installed plugins"] if unavailable else [], rows, [])

backend.scan_profile = hardware
original_run = backend.run

def run(request, *args, **kwargs):
    action = request.get("action")
    event("request", action=action, generation=request.get("generation"), query=request.get("setupQuery", request.get("query", "")))
    if action in backend.PLUGIN_MUTATIONS or action == "open-plugin":
        raise ValueError("VM first-run fixture forbids plugin mutations and Open")
    return original_run(request, *args, **kwargs)

backend.run = run
original_write = backend.write_response

def write(result):
    event("response", **{key: result[key] for key in (
        "action", "generation", "responseKind", "final", "phase", "sequence", "ok",
        "bytesReceived", "bytesTotal", "processed", "total", "error") if key in result})
    if isinstance(result.get("setup"), dict):
        rows = result["setup"].get("rows", [])
        event("search-evidence", generation=result.get("generation"), rows=len(rows),
              readmePrimary=sum("README" in row.get("searchReason", "") for row in rows),
              indexed=sum(bool(row.get("searchSnippet")) for row in rows))
    original_write(result)

backend.write_response = write
signal.signal(signal.SIGTERM, backend._terminate_all)
signal.signal(signal.SIGINT, backend._terminate_all)
raise SystemExit(backend.serve() if "--serve" in sys.argv else backend.main())
