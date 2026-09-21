#!/usr/bin/env python3
"""Reversible integration checks in the existing density-pass guest only.

Run through session_exec.py. A recovery marker and external byte snapshots are
retained until restoration succeeds. No host installation or dev-link changes.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import subprocess
import time
import traceback

OLD, NEW = "io.github.ctl0v0.omafit", "io.github.ctl0v0.outfit"
HOME = Path.home()
parser = argparse.ArgumentParser()
parser.add_argument("--root", type=Path, required=True)
parser.add_argument("--restore", action="store_true")
parser.add_argument("--only", choices=["all", "migration", "cold"], default="all")
parser.add_argument("--resume-check", action="store_true", help="Interrupt cold transfers instead of testing full import")
parser.add_argument("--regressions", action="store_true", help="Only the migration rerun, resume, compact footer and settled offline regressions")
parser.add_argument("--host", choices=["both", "dev", "stock"], default="both")
parser.add_argument("--scenarios", nargs="+", choices=["cold", "disabled", "offline", "corrupt"],
                    default=["cold", "disabled", "offline", "corrupt"])
args = parser.parse_args()
if (os.environ.get("OUTFIT_TEST_VM") != "1" or HOME != Path("/home/tester")
        or subprocess.run(["systemd-detect-virt", "--vm"], stdout=subprocess.DEVNULL).returncode):
    raise SystemExit("Existing disposable tester VM only")
ROOT = args.root.resolve()
SOURCE, OLD_SOURCE = ROOT / "source", ROOT / "old"
EVIDENCE, BACKUP = ROOT / "evidence", ROOT / "backup"
MARKER = ROOT / "recovery.json"
CONFIG = HOME / ".config/omarchy/shell.json"
PLUGINS = CONFIG.parent / "plugins"
HOST = Path(os.environ["OMARCHY_PATH"])
env = dict(os.environ)
report = {"checks": {}, "failures": [], "fixtureTransport": "paced local bytes; not real network timing"}
shell_process = None

def run(*command, check=True, timeout=30, environment=None):
    result = subprocess.run(list(map(str, command)), capture_output=True, text=True,
                            timeout=timeout, env=environment or env)
    if check and result.returncode:
        raise RuntimeError(f"{command}: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout.strip()

def ipc(*command, check=True):
    return run(env["OMARCHY_PATH"] + "/bin/omarchy-shell", *command, check=check)

def status(identity=NEW):
    try:
        return json.loads(ipc(identity, "status"))
    except (RuntimeError, ValueError):
        return {}

def wait(predicate, label, timeout=45):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.15)
    raise RuntimeError("Timed out: " + label)

def check(name, value, detail=None):
    report["checks"][name] = {"passed": bool(value), "detail": detail}
    save_report()
    return value

def save_report():
    (EVIDENCE / "report.json").write_text(json.dumps(report, indent=2))

def digest(path):
    if path.is_symlink():
        return {"link": os.readlink(path)}
    if not path.exists():
        return None
    if path.is_file():
        return {"sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "mode": path.stat().st_mode & 0o777}
    return {str(p.relative_to(path)): digest(p) for p in sorted(path.rglob("*")) if not p.is_dir() or p.is_symlink()}

def remove(path):
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.exists():
        shutil.rmtree(path)

def stop_shell():
    global shell_process
    # Scope shutdown to this guest's exact shell root, never all quickshells.
    shell_path = Path(env["OMARCHY_PATH"]) / "shell"
    run("quickshell", "kill", "-p", shell_path, "--any-display", check=False)
    if shell_process:
        try:
            shell_process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            shell_process.terminate()
            shell_process.wait(timeout=10)
        shell_process = None
    time.sleep(1)

def start_shell(host, label, state=None, scenario="cold"):
    global shell_process, env
    env = dict(os.environ, OMARCHY_PATH=str(host), PATH=f"{host}/bin:{HOME}/.local/bin:/usr/bin:/bin")
    if label != "restored":
        env.update(https_proxy="http://127.0.0.1:9", http_proxy="http://127.0.0.1:9",
                   HTTPS_PROXY="http://127.0.0.1:9", HTTP_PROXY="http://127.0.0.1:9", NO_PROXY="", no_proxy="")
    for key in ("OUTFIT_DEMO_ROOT", "OMAFIT_DEMO_ROOT", "OUTFIT_DEMO_SCENARIO", "OMAFIT_DEMO_SCENARIO"):
        env.pop(key, None)
    if state:
        env.update(OUTFIT_DEMO_ROOT=str(state), OUTFIT_VM_PACK=str(ROOT / "pack"),
                   OUTFIT_VM_SCENARIO=scenario, OUTFIT_TEST_VM="1")
    log = (EVIDENCE / (label + "-shell.log")).open("w")
    shell_process = subprocess.Popen(["quickshell", "-n", "-p", str(host / "shell")],
                                     env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    log.close()
    wait(lambda: ipc("shell", "listPlugins", check=False).startswith("["), "shell IPC", 35)

def write_config(identity):
    document = json.loads((BACKUP / "shell.json").read_text())
    for owner, key in [(document, "plugins"), *[(document["bar"]["layout"], key) for key in document["bar"]["layout"]]]:
        owner[key] = [item for item in owner.get(key, []) if (item.get("id") if isinstance(item, dict) else item) not in {OLD, NEW}]
    document["bar"]["layout"]["right"].append({"id": identity})
    document["idle"] = {"screensaver": 0, "lock": 0}
    CONFIG.write_text(json.dumps(document, indent=2) + "\n")

def restore(saved):
    global env
    stop_shell()
    for path in CONFIG.parent.glob(".outfit-identity-*"):
        if path.name not in saved["migrationBackups"]:
            shutil.move(str(path), str(EVIDENCE / path.name))
    for row in saved["paths"]:
        path, backup = Path(row["path"]), Path(row["backup"])
        remove(path)
        if row["existed"]:
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(backup), str(path))
        if digest(path) != row["digest"]:
            raise RuntimeError("Restoration hash mismatch: " + str(path))
    CONFIG.write_bytes((BACKUP / "shell.json").read_bytes())
    CONFIG.chmod(saved["configMode"])
    check("restore-original-files", True, "Snapshot hashes and modes match before original runtime resumes")
    # Native restart launches from Hyprland's canonical session environment,
    # rather than retaining the fixture process's restricted PATH/test flags.
    env = dict(os.environ, OMARCHY_PATH=saved["host"])
    for key in ("OUTFIT_TEST_VM", "OMAFIT_TEST_VM", "OUTFIT_DEMO_ROOT", "OUTFIT_VM_PACK", "OUTFIT_VM_SCENARIO"):
        env.pop(key, None)
    run(Path(saved["host"]) / "bin/omarchy-restart-shell")
    wait(lambda: bool(status(OLD)), "restored original old-ID runtime")
    if saved["opened"]:
        ipc("shell", "summon", OLD, "{}")
    cursor = saved["cursor"]
    run("hyprctl", "eval", "hl.dispatch(hl.dsp.focus({workspace=" + json.dumps(str(saved["workspace"])) + "}))")
    run("hyprctl", "eval", f'hl.dispatch(hl.dsp.cursor.move({{x={cursor["x"]},y={cursor["y"]}}}))')
    check("restore-shell-config-bytes", CONFIG.read_bytes() == (BACKUP / "shell.json").read_bytes())
    check("restore-runtime", bool(status(OLD)) and not status(NEW), {"host": saved["host"], "oldId": True, "newId": False})
    MARKER.unlink()

def load_backend(source=SOURCE):
    spec = importlib.util.spec_from_file_location("outfit_vm_backend", source / "scripts/outfit.py")
    backend = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(backend)
    return backend

def migration():
    backend = load_backend(OLD_SOURCE)
    shutil.copytree(OLD_SOURCE, PLUGINS / OLD)
    write_config(OLD)
    cache = backend.Store(HOME / ".cache" / OLD)
    prefs = backend.Store(HOME / ".config" / OLD)
    document = json.loads((SOURCE / "data/bootstrap-catalog.json").read_text())
    items, generated = backend.normalize_catalog(document)
    backend.save_catalog(cache, items, generated, time.time())
    with backend.ReadmeIndex(cache, create=True) as index:
        index.sync(items, {}, time.time())
        document_key = backend.readme_key(items[0])
        index.put(document_key, {"ok": True, "content": "Fictional baseline document", "path": "README.md"}, time.time())
    backend.save_preferences(prefs, {**backend.DEFAULT_PREFERENCES, "readmeEnrichment": False,
                                    "marketplaceThumbnails": False, "watchHardware": True,
                                    "servicesOnboardingComplete": True, "notes": "fictional migration fixture"})
    cache.close()
    prefs.close()
    run("python3", OLD_SOURCE / "scripts/launcher.py")
    start_shell(HOST, "legacy-public")
    wait(lambda: bool(status(OLD)), "old public service")
    report["legacyInitial"] = status(OLD)
    ipc("shell", "summon", OLD, "{}")
    wait(lambda: status(OLD).get("ready"), "old public analysis ready", 100)
    ipc("shell", "hide", OLD)
    wait(lambda: status(OLD).get("ready") and not status(OLD).get("opened"), "old closed idle")
    private = HOME / ".config" / OLD
    (private / "interests.json").write_text('{"schema":1,"revision":0,"criteria":[],"ignoredSignals":[],"review":{},"fixture":"fictional"}\n')
    (private / "quick-setup.json").write_text('{"schema":1,"selection":[],"items":[],"running":false,"resumePayload":null}\n')
    public = HOME / ".cache" / OLD
    (public / "hardware.json").write_text('{"fictional":"do not migrate"}\n')
    wal_store = backend.Store(public)
    wal_index = backend.ReadmeIndex(wal_store, create=True)
    db = wal_index.db
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA wal_autocheckpoint=0")
    db.execute("CREATE TABLE IF NOT EXISTS vm_wal_evidence (value TEXT)")
    db.commit()
    db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    db.execute("INSERT INTO vm_wal_evidence VALUES ('committed only in WAL')")
    db.commit()
    wal_index.put(document_key, {"ok": True, "content": "Fictional walonlyfixture documentation", "path": "README.md"}, time.time())
    check("migration-live-WAL-present", Path(str(public / "readme-search.sqlite") + "-wal").stat().st_size > 0)
    before = {name: digest(private / name) for name in ("preferences.json", "interests.json", "quick-setup.json")}
    old_catalog = digest(public / "catalog.json")
    source_hash = digest(PLUGINS / OLD)
    shell_bytes = CONFIG.read_bytes()
    command = ["python3", "-I", "-B", SOURCE / "scripts/migrate_identity.py", "--source", SOURCE]
    try:
        dry = json.loads(run(*command, "--dry-run", timeout=40))
        check("migration-dry-run-read-only", CONFIG.read_bytes() == shell_bytes and not (PLUGINS / NEW).exists(), dry)
        applied = json.loads(run(*command, "--apply", timeout=100))
        report["migrationApply"] = applied
        registrations = json.loads(ipc("shell", "listPlugins"))
        identities = [row["id"] for row in registrations if row["id"] in {OLD, NEW}]
        check("migration-one-registration", identities == [NEW], identities)
        check("migration-legacy-source-preserved", digest(Path(applied["backup"]) / "legacy-registration") == source_hash)
        after = {name: digest(HOME / ".config" / NEW / name) for name in before}
        check("migration-config-preferences-interests-journal-bytes", all(after[name]["sha256"] == value["sha256"] for name, value in before.items()), {"before": before, "after": after})
        check("migration-private-modes", all(value["mode"] == 0o600 for value in after.values()))
        check("migration-catalog-bytes", digest(HOME / ".cache" / NEW / "catalog.json") == old_catalog)
        target = sqlite3.connect(HOME / ".cache" / NEW / "readme-search.sqlite")
        check("migration-WAL-committed-row", target.execute("SELECT value FROM vm_wal_evidence").fetchall() == [("committed only in WAL",)])
        target.close()
        migrated_store = backend.Store(HOME / ".cache" / NEW)
        try:
            with backend.ReadmeIndex(migrated_store) as migrated_index:
                check("migration-WAL-document-searchable", document_key in migrated_index.evidence("walonlyfixture"))
        finally:
            migrated_store.close()
        check("migration-raw-hardware-excluded", not (HOME / ".cache" / NEW / "hardware.json").exists())
        data = HOME / ".local/share"
        desktop = data / "applications" / (NEW + ".desktop")
        check("migration-launcher-and-icon", desktop.read_bytes() == (SOURCE / "assets" / desktop.name).read_bytes()
              and (data / "icons/hicolor/scalable/apps" / (NEW + ".svg")).is_file()
              and not (data / "applications" / (OLD + ".desktop")).exists())
        # Exercise the immediate rerun exactly as a caller would, before opening.
        wait(lambda: status().get("canBrowse") and not status().get("queryBusy"), "new closed cache load")
        report["migrationClosedSettled"] = status()
        immediate = subprocess.run(list(map(str, [*command, "--apply"])), capture_output=True, text=True, env=env, timeout=100)
        check("migration-immediate-rerun-idempotent", immediate.returncode == 0 and "already-migrated" in immediate.stdout,
              {"stdout": immediate.stdout, "stderr": immediate.stderr, "status": status()})
        if args.regressions:
            return
        ipc("shell", "summon", NEW, "{}")
        wait(lambda: status().get("ready"), "new migrated ready", 100)
        ipc("shell", "hide", NEW)
        wait(lambda: status().get("ready") and not status().get("opened"), "new closed")
        final_bytes = CONFIG.read_bytes()
        rerun = json.loads(run(*command, "--apply", timeout=100))
        check("migration-rerun-idempotent", rerun.get("result") == "already-migrated" and CONFIG.read_bytes() == final_bytes, rerun)
    finally:
        report["migrationFinalStatus"] = status()
        for identity in (OLD, NEW):
            path = HOME / ".config" / identity
            if path.exists():
                shutil.copytree(path, EVIDENCE / ("synthetic-" + identity))
        wal_index.close()
        wal_store.close()
        stop_shell()

def window():
    return next((row for row in json.loads(run("hyprctl", "clients", "-j"))
                 if row.get("title") == "Outfit - Plugin Manager"), None)

def capture(label, width=1180, height=760, activity=False):
    current = wait(window, "Outfit window")
    address = json.dumps("address:" + current["address"])
    if not current.get("floating"):
        run("hyprctl", "dispatch", 'hl.dsp.window.float({window=' + address + ',action="toggle"})')
    run("hyprctl", "dispatch", 'hl.dsp.window.resize({window=' + address + f',x={width},y={height}' + '})')
    run("hyprctl", "dispatch", 'hl.dsp.window.center({window=' + address + '})')
    time.sleep(0.7)
    current = window()
    if current["size"] != [width, height]:
        raise RuntimeError("Unexpected capture geometry: " + str(current["size"]))
    x, y = current["at"]
    if activity:
        # The banner is intentionally quiet after reopening. Use the persistent
        # More menu and pointer activation, independent of menu focus timing.
        run("hyprctl", "eval", f"hl.dispatch(hl.dsp.cursor.move({{x={x+width-126},y={y+35}}}))")
        run("wlrctl", "pointer", "move", "1", "0")
        run("wlrctl", "pointer", "click")
        time.sleep(0.2)
        run("hyprctl", "eval", f"hl.dispatch(hl.dsp.cursor.move({{x={x+width-270},y={y+82}}}))")
        run("wlrctl", "pointer", "move", "1", "0")
        run("wlrctl", "pointer", "click")
        time.sleep(0.3)
    run("grim", "-g", f"{x},{y} {current['size'][0]}x{current['size'][1]}", EVIDENCE / (label + ".png"))
    return current

def cold(host, scenario):
    label = host.name + "-" + scenario
    state = ROOT / label
    state.mkdir()
    fixture_source = ROOT / "fixture-source"
    if not fixture_source.exists():
        shutil.copytree(SOURCE, fixture_source)
        shutil.copyfile(SOURCE / "tests/vm/first_run_worker.py", fixture_source / "demo/fixture_worker.py")
    remove(PLUGINS / OLD)
    remove(PLUGINS / NEW)
    (PLUGINS / NEW).symlink_to(fixture_source)
    write_config(NEW)
    if scenario == "disabled":
        path = state / "config" / NEW
        path.mkdir(parents=True)
        (path / "preferences.json").write_text(json.dumps({"schema": 1, "readmeEnrichment": False}))
    start_shell(host, label, state, scenario)
    wait(lambda: status().get("canBrowse"), "bundled catalog browsable")
    before = status()
    started = time.monotonic()
    ipc("shell", "summon", NEW, "{}")
    samples = []
    resumed = False
    closed = False
    screenshot = False
    progress_capture = False
    reopened_at = None
    deadline = time.monotonic() + (100 if scenario == "cold" else 48)
    try:
        while time.monotonic() < deadline:
            current = status()
            samples.append({"seconds": round(time.monotonic() - started, 3), **current})
            doc = current.get("startupActivity", {}).get("documentation", {})
            if args.resume_check and scenario == "cold" and not closed and doc.get("phase") == "download" and doc.get("bytesReceived", 0) > 400000:
                ipc("shell", "hide", NEW)
                time.sleep(1)
                cancel = status()
                check(label + "-close-cancels", not cancel.get("preparingSearch") and not cancel.get("indexingBusy"), cancel)
                closed = True
                ipc("shell", "summon", NEW, "{}")
                reopened_at = time.monotonic()
            elif closed and current.get("preparingSearch"):
                resumed = True
            if current.get("canManagePlugins") and current.get("backgroundBusy") and not screenshot:
                capture(label + "-cold-catalog")
                screenshot = True
            if not args.resume_check and scenario == "cold" and not progress_capture and doc.get("bytesReceived", 0) > 1000000:
                capture(label + "-download-progress", activity=True)
                run("wtype", "-k", "Escape")
                progress_capture = True
            if scenario == "cold" and current.get("searchPack", {}).get("state") == "ready" and not current.get("indexingBusy") and not current.get("backgroundBusy"):
                # Observe at least one local indexing batch after excluded rows.
                if any(s.get("indexingBusy") for s in samples) or time.monotonic() - started > 65:
                    break
            if scenario != "cold" and time.monotonic() - started > 35 and not current.get("backgroundBusy"):
                if not (args.regressions and scenario == "offline") or (
                        current.get("searchPackFailed") is True and not current.get("indexingBusy")
                        and current.get("documentCounts", {}).get("failed", 0) > 0):
                    break
            time.sleep(0.15)
        (EVIDENCE / (label + "-samples.json")).write_text(json.dumps(samples, indent=2))
        check(label + "-bundled-before-open", before.get("canBrowse") and before.get("catalogSource") == "bundled", before)
        check(label + "-inventory-before-hardware", any(s.get("canManagePlugins") and s.get("backgroundBusy") for s in samples))
        check(label + "-browsing-before-hardware", any(s.get("canBrowse") and s.get("backgroundBusy") for s in samples))
        final = status()
        report[label + "-final"] = final
        report[label + "-timings"] = {name: next((sample["seconds"] for sample in samples if predicate(sample)), None)
            for name, predicate in {
                "browse": lambda s: s.get("canBrowse"),
                "inventory": lambda s: s.get("canManagePlugins"),
                "download": lambda s: s.get("startupActivity", {}).get("documentation", {}).get("bytesReceived", 0) > 0,
                "imported": lambda s: s.get("searchPack", {}).get("state") == "ready",
                "hardwareComplete": lambda s: s.get("startupActivity", {}).get("hardware", {}).get("state") == "complete",
            }.items()}
        report[label + "-first-import-counts"] = next((s.get("documentCounts") for s in samples
            if s.get("searchPack", {}).get("state") == "ready"), None)
        events = [json.loads(line) for line in (state / "transport.jsonl").read_text().splitlines()]
        shutil.copyfile(state / "transport.jsonl", EVIDENCE / (label + "-transport.jsonl"))
        if scenario == "cold":
            if args.resume_check:
                manifest = json.loads((ROOT / "pack/latest.json").read_text())
                requests = [event for event in events if event["kind"] == "pack-request" and event["url"] == manifest["assetUrl"]]
                check(label + "-resume", closed and resumed and len(requests) > 1, requests)
                if args.regressions:
                    resumed_delay = requests[1]["at"] - reopened_at if len(requests) > 1 else None
                    check(label + "-resume-without-backoff", resumed_delay is not None and 0 <= resumed_delay < 15,
                          {"secondAssetRequestAfterReopenSeconds": resumed_delay})
            check(label + "-native-progress", any(s.get("startupActivity", {}).get("documentation", {}).get("bytesReceived", 0) > 0 for s in samples))
            check(label + "-full-import", final.get("documentCounts", {}).get("indexed", 0) >= 3159, final.get("documentCounts"))
            check(label + "-excluded-not-library-prepared", not final.get("libraryPrepared"), final.get("documentCounts"))
            check(label + "-import-progress", any(e.get("phase") == "import" and e.get("processed", 0) > 0 for e in events))
            check(label + "-local-checks-continue", any(e["kind"] == "request" and e.get("action") == "index-readmes" for e in events))
            check(label + "-settled-no-spinner", not final.get("preparingSearch") and not final.get("indexingBusy") and not final.get("backgroundBusy"))
        if scenario == "disabled":
            events = [json.loads(line) for line in (state / "transport.jsonl").read_text().splitlines()]
            check(label + "-no-seed-network", not any(e["kind"] == "pack-request" for e in events))
        if scenario in {"offline", "corrupt"}:
            check(label + "-fallback-and-error", final.get("canBrowse") and final.get("searchPack", {}).get("state") in {"failed", "error", "unavailable"}, final.get("searchPack"))
        if args.regressions and scenario == "offline":
            finished_local = any(e.get("action") == "index-readmes" and e.get("final") is True for e in events)
            check(label + "-seed-error-after-local-batch", finished_local and final.get("searchPackFailed") is True
                  and not final.get("indexingBusy") and final.get("documentCounts", {}).get("failed", 0) > 0,
                  {"finishedLocalBatch": finished_local, "searchPackFailed": final.get("searchPackFailed"),
                   "documentCounts": final.get("documentCounts")})
        if args.resume_check and not args.regressions:
            capture(label + "-resume-result")
            return
        if not args.regressions and scenario == "cold" and final.get("documentCounts", {}).get("indexed", 0) >= 3159:
            # Present in 111 real artifact bodies; the license boilerplate term
            # MERCHANTABILITY is deliberately absent from this artifact.
            run("wtype", "-M", "ctrl", "-k", "f", "-m", "ctrl", "oauth")
            wait(lambda: not status().get("queryBusy"), "native search finished")
            time.sleep(1)
            check(label + "-native-document-search", status().get("results", 0) > 0 and status().get("results", 0) < 3466, status().get("results"))
            search_events = [json.loads(line) for line in (state / "transport.jsonl").read_text().splitlines()]
            check(label + "-search-README-evidence", any(event.get("kind") == "search-evidence" and event.get("readmePrimary", 0) > 0 for event in search_events))
            capture(label + "-document-search", 1180, 760)
            run("wtype", "-M", "ctrl", "-k", "f", "-k", "a", "-m", "ctrl", "-k", "BackSpace")
            time.sleep(1)
        capture(label + "-normal")
        capture(label + "-normal-activity", activity=True)
        run("wtype", "-k", "Escape")
        check(label + "-normal-popup-escape-retains-app", status().get("opened"))
        capture(label + "-compact", 760, 540)
        capture(label + "-compact-activity", 760, 540, activity=True)
        if args.regressions:
            run("wtype", "-k", "Tab", "-k", "End")
            time.sleep(0.3)
            current = window()
            x, y = current["at"]
            run("grim", "-g", f"{x},{y} 760x540", EVIDENCE / (label + "-compact-footer.png"))
            run("wtype", "-k", "Return")
            time.sleep(0.3)
            check(label + "-compact-footer-activation-retains-app", status().get("opened"))
            run("grim", "-g", f"{x},{y} 760x540", EVIDENCE / (label + "-compact-footer-closed.png"))
            return
        run("wtype", "-k", "Escape")
        check(label + "-compact-popup-escape-retains-app", status().get("opened"))
    finally:
        (EVIDENCE / (label + "-samples.json")).write_text(json.dumps(samples, indent=2))
        stop_shell()
        if (state / "transport.jsonl").exists():
            shutil.copyfile(state / "transport.jsonl", EVIDENCE / (label + "-transport.jsonl"))

if args.restore:
    EVIDENCE.mkdir(exist_ok=True)
    restore(json.loads(MARKER.read_text()))
    raise SystemExit()
if MARKER.exists() or EVIDENCE.exists():
    raise SystemExit("Existing run: inspect evidence or use --restore")
EVIDENCE.mkdir()
BACKUP.mkdir(mode=0o700)
shutil.copyfile(ROOT / "source-hashes.json", EVIDENCE / "source-hashes.json")
report["versions"] = {"hostRevision": run("git", "-C", HOST, "rev-parse", "HEAD", check=False),
                      "packages": run("pacman", "-Q", "omarchy", "quickshell", check=False),
                      "legacy": "6db2b90ec980095404d4b004884c070d12e342e9",
                      "artifact": json.loads((ROOT / "pack/latest.json").read_text())}
check("native-plugin-validation", subprocess.run(
    [str(HOST / "bin/omarchy-plugin-validate"), str(SOURCE)], capture_output=True, env=env).returncode == 0)
original_status = status(OLD)
if original_status.get("opened") or original_status.get("batchRunning") or original_status.get("interestsDirty"):
    raise SystemExit("Close the original guest Outfit and finish pending work first")
saved = {"host": str(HOST), "opened": False, "configMode": CONFIG.stat().st_mode & 0o777,
         "workspace": json.loads(run("hyprctl", "activeworkspace", "-j"))["id"],
         "cursor": json.loads(run("hyprctl", "cursorpos", "-j")),
         "migrationBackups": [p.name for p in CONFIG.parent.glob(".outfit-identity-*")], "paths": []}
shutil.copy2(CONFIG, BACKUP / "shell.json")
paths = [base / identity for base in (PLUGINS, HOME / ".config", HOME / ".cache") for identity in (OLD, NEW)]
paths += [HOME / ".local/share" / relative / (identity + suffix)
          for identity in (OLD, NEW) for relative, suffix in (("applications", ".desktop"), ("icons/hicolor/scalable/apps", ".svg"))]
paths.append(CONFIG.parent / ".outfit-identity.lock")
stop_shell()
def interrupted(signum, _frame):
    raise SystemExit("VM check interrupted: " + signal.Signals(signum).name)
for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(signum, interrupted)
try:
    for index, path in enumerate(paths):
        backup = BACKUP / str(index)
        row = {"path": str(path), "backup": str(backup), "existed": path.exists() or path.is_symlink(), "digest": digest(path)}
        if row["existed"]:
            shutil.move(str(path), str(backup))
        saved["paths"].append(row)
        MARKER.write_text(json.dumps(saved, indent=2))
        MARKER.chmod(0o600)
    for label, operation in ([('migration', migration)] if args.only != "cold" else []) + (
            [(str(host) + ":" + scenario, lambda h=host, s=scenario: cold(h, s))
             for host, scenario in [(HOST, "cold"), (Path("/usr/share/omarchy"), "cold"),
                                    (Path("/usr/share/omarchy"), "disabled"),
                                    (Path("/usr/share/omarchy"), "offline"),
                                    (Path("/usr/share/omarchy"), "corrupt")]
             if scenario in args.scenarios and (args.host == "both" or (host == HOST) == (args.host == "dev"))]
            if args.only != "migration" else []):
        try:
            operation()
        except Exception as error:
            report["failures"].append({"phase": label, "error": str(error), "traceback": traceback.format_exc()})
            stop_shell()
        save_report()
finally:
    restore(saved)
    save_report()
print(json.dumps({"evidence": str(EVIDENCE), "checks": len(report["checks"]),
                  "failedChecks": [name for name, value in report["checks"].items() if not value["passed"]],
                  "phaseFailures": report["failures"]}, indent=2))
raise SystemExit(1 if report["failures"] or any(not value["passed"] for value in report["checks"].values()) else 0)
