#!/usr/bin/env python3
"""Real helper request-path benchmark in disposable storage, with live I/O blocked."""
import argparse
from contextlib import ExitStack
import hashlib
import importlib.util
import json
from pathlib import Path
import statistics
import tempfile
import time
from unittest import mock

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("outfit", root / "scripts/outfit.py")
app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(app)
parser = argparse.ArgumentParser()
parser.add_argument("--rows", type=int, default=10000, choices=range(1, 10001), metavar="1..10000")
parser.add_argument("--iterations", type=int, default=5, choices=range(1, 21))
parser.add_argument("--readmes", action="store_true", help="Populate a separate revision-keyed search corpus")
parser.add_argument("--readme-chars", type=int, default=12000, choices=range(1000, 24001), metavar="1000..24000")
parser.add_argument("--sort", choices=("recommended", "relevance", "stars"), default="recommended")
parser.add_argument("--queries", nargs="+", default=["", "dock", "orbitalwidget", "calendar"])
args = parser.parse_args()
fixture = json.loads((root / "demo/fixtures/example.json").read_text())
raw = fixture["catalog"]["plugins"]
catalog = {"plugins": [{**raw[i % len(raw)], "id": f"example.fixture-{i}",
                         "name": f"{raw[i % len(raw)]['name']} {i}", "stars": i % 200,
                         "listingValidatedCommit": f"{i + 1:040x}"}
                       for i in range(args.rows)]}
items, generated = app.normalize_catalog(catalog)
profile = fixture["profile"] + [
    app._signal("battery", "System battery", {"battery": 15, "charge limit": 12, "power management": 10}),
    app._signal("touchpad", "Touchpad", {"touchpad": 22, "trackpad": 18, "gesture": 7}),
    app._signal("bluetooth-airpods", "AirPods", {"airpods": 30, "apple headphones": 18, "bluetooth codec": 8}),
    app._signal("capability-docker", "Docker", {"docker": 12, "container": 6}, source="software"),
]
criteria = [{"kind": "hardware", "featureId": feature} for feature in ("hardware-dock", "multi-monitor")]
criteria += [{"kind": "service", "serviceId": service} for service in ("spotify", "github")]
criteria += [{"kind": "topic", "label": term.title(), "terms": [term]} for term in
             ("orbitalwidget", "backup schedule", "calendar agenda", "audio interface")]
inventory = [{"id": item["id"], "enabled": True, "canDisable": True, "kinds": ["bar-widget"]}
             for item in items[:20]]
queries = args.queries
samples, memory = [], []
with tempfile.TemporaryDirectory(prefix="outfit-benchmark-") as directory, ExitStack() as stack:
    store = app.Store(Path(directory) / "cache")
    preferences = app.Store(Path(directory) / "config")
    stack.callback(store.close)
    stack.callback(preferences.close)
    for name in ("fetch_bytes", "fetch_catalog", "scan_profile", "scan_inventory", "run_command"):
        stack.enter_context(mock.patch.object(app, name, side_effect=AssertionError("Live I/O forbidden: " + name)))
    app.save_catalog(store, items, generated, 100)
    app.save_preferences(preferences, {**app.DEFAULT_PREFERENCES, "readmeEnrichment": args.readmes})
    if args.readmes:
        endings = ["orbitalwidget", "spotify", "github notifications", "charge limit", "airpods",
                   "backup schedule", "calendar agenda", "audio interface", "touchpad", "docker"]
        with app.ReadmeIndex(store, create=True) as search_index:
            for i, item in enumerate(items):
                text = ("Fictional documentation with commands, installation and configuration. " * 500)[:args.readme_chars - 80]
                text += "\nSupported integration: " + endings[i % len(endings)]
                search_index.put(app.readme_key(item), {"ok": True, "searchText": text}, 100)
    saved = app.run({"action": "save-interests", "revision": 0, "criteria": criteria, "ignoredSignals": []},
                    store, now=100, preferences_store=preferences)
    store.memory.clear()
    preferences.memory.clear()
    for iteration in range(args.iterations + 1):
        for query in queries:
            raw_request = json.dumps({"action": "quick-setup", "localOnly": True, "generation": len(samples) + 1,
                "profile": profile, "inventory": inventory, "setupQuery": query, "setupSort": args.sort,
                "setupGrouping": "none", "setupPage": 1 + iteration % 2})
            protocol_start = time.perf_counter()
            request = json.loads(raw_request)
            started = time.perf_counter()
            result = app.run(request, store, now=200 + iteration, preferences_store=preferences)
            run_ms = (time.perf_counter() - started) * 1000
            json.dumps(result, ensure_ascii=False, separators=(",", ":"))
            protocol_ms = (time.perf_counter() - protocol_start) * 1000
            assert result["ok"] and not result["error"] and result["generation"] == request["generation"]
            assert result["criteriaRevision"] == saved["criteriaRevision"]
            assert len(result["setup"]["rows"]) <= app.MAX_SETUP_PAGE_SIZE
            if args.readmes:
                assert result["readmeIndex"]["indexed"] == args.rows and not result["readmeIndex"]["error"]
            samples.append({"iteration": iteration, "query": query, "run_ms": round(run_ms, 2),
                            "protocol_ms": round(protocol_ms, 2), "total": result["setup"]["total"]})
            status = Path("/proc/self/status").read_text()
            memory.append(next(int(line.split()[1]) for line in status.splitlines() if line.startswith("VmRSS:")))
    warm = [sample for sample in samples if sample["iteration"] > 0]
    print(json.dumps({"path": "app.run quick-setup + JSON request/response", "rows": args.rows,
        "sort": args.sort,
        "profile_signals": len(profile), "saved_criteria": len(criteria), "criteria_revision": saved["criteriaRevision"],
        "helper_sha256": hashlib.sha256((root / "scripts/outfit.py").read_bytes()).hexdigest(),
        "readme_chars": args.readme_chars if args.readmes else 0,
        "index_bytes": (store.base / "readme-search.sqlite").stat().st_size if args.readmes else 0,
        "interest_state_bytes": (preferences.base / "interests.json").stat().st_size,
        "cold_ms": samples[0]["run_ms"],
        "warm_median_ms": round(statistics.median(sample["run_ms"] for sample in warm), 2),
        "warm_max_ms": max(sample["run_ms"] for sample in warm),
        "warm_protocol_median_ms": round(statistics.median(sample["protocol_ms"] for sample in warm), 2),
        "warm_by_query_ms": {query: round(statistics.median(sample["run_ms"] for sample in warm if sample["query"] == query), 2)
                             for query in queries},
        "sampled_peak_rss_kib": max(memory), "samples": samples}, indent=2))
