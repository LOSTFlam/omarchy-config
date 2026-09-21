#!/usr/bin/env python3
"""One exact-base/candidate, four-action native continuity comparison. VM only.

No lease API, batch emulation, development link, login lock, or host edits.
The only native mutations are a fictional guest-local git plugin's lifecycle.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import threading
import time
import traceback

parser = argparse.ArgumentParser()
parser.add_argument("--outfit-root", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--candidate", type=Path, default=Path("/home/tester/omarchy-upstream-continuity"))
parser.add_argument("--baseline", type=Path, default=Path("/home/tester/omarchy-upstream-baseline"))
parser.add_argument("--restore", action="store_true")
parser.add_argument("--hosts", nargs="+", choices=["baseline", "candidate"], default=["baseline", "candidate"])
parser.add_argument("--auth-only", action="store_true", help="Run the isolated auth fixture against an existing candidate evidence directory")
parser.add_argument("--skip-auth", action="store_true", help="Retain prior native auth evidence after verifying unchanged auth source")
parser.add_argument("--previous-host-hashes", type=Path, help="Prior native-auth snapshot's vm-source-hashes.json")
parser.add_argument("--expect-shell-sha256", help="Require the post-fix handoff's shell hash")
args = parser.parse_args()
HOME = Path.home()
if os.environ.get("OUTFIT_TEST_VM") != "1" or HOME != Path("/home/tester") or subprocess.run(
        ["systemd-detect-virt", "--vm"], stdout=subprocess.DEVNULL).returncode:
    raise SystemExit("Existing disposable VM only")
ROOT = args.outfit_root.resolve()
SOURCE = ROOT / "source"
OUTPUT = args.output.resolve()
CONFIG = HOME / ".config/omarchy/shell.json"
PLUGINS = CONFIG.parent / "plugins"
ORIGINAL_HOST = Path(os.environ["OMARCHY_PATH"])
OLD, APP = "io.github.ctl0v0.omafit", "io.github.ctl0v0.outfit"
PROBE, WIDGET = "org.example.outfit-continuity-probe", "org.example.outfit-continuity-widget"
OTHER = "org.example.omafit-release-fixture"
MARKER = OUTPUT / "recovery.json"
BACKUP = OUTPUT / "backup"
env = dict(os.environ)
current_host = ORIGINAL_HOST
shell_process = None
report = {"base": "d174d4aa279ea7393d4fad4a80fed147866106b9", "hosts": {}, "failures": []}

def save():
    (OUTPUT / "report.json").write_text(json.dumps(report, indent=2))

def command(*argv, timeout=40, check=True, environment=None):
    result = subprocess.run(list(map(str, argv)), capture_output=True, text=True,
                            timeout=timeout, env=environment or env)
    if check and result.returncode:
        raise RuntimeError(f"{argv}: {result.stderr.strip() or result.stdout.strip()}")
    return result

def run(*argv, **kwargs):
    return command(*argv, **kwargs).stdout.strip()

def ipc(*argv, **kwargs):
    return run(current_host / "bin/omarchy-shell", *argv, **kwargs)

def json_ipc(*argv):
    try:
        return json.loads(ipc(*argv, check=False))
    except ValueError:
        return None

def wait(predicate, label, timeout=45):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.15)
    raise RuntimeError("Timed out: " + label)

def digest(path):
    if path.is_symlink():
        return {"link": os.readlink(path)}
    if not path.exists():
        return None
    if path.is_file():
        return {"sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "mode": path.stat().st_mode & 0o777}
    return {str(p.relative_to(path)): digest(p) for p in sorted(path.rglob("*")) if p.is_file() or p.is_symlink()}

def remove(path):
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.exists():
        shutil.rmtree(path)

def stop_shell():
    global shell_process
    run("quickshell", "kill", "-p", current_host / "shell", "--any-display", check=False)
    if shell_process:
        shell_process.wait(timeout=15)
        shell_process = None
    time.sleep(1)

def restore(saved):
    global env, current_host
    stop_shell()
    for row in saved["paths"]:
        target, backup = Path(row["path"]), Path(row["backup"])
        remove(target)
        if row["existed"]:
            shutil.move(str(backup), str(target))
        if digest(target) != row["digest"]:
            raise RuntimeError("Restoration hash mismatch: " + str(target))
    CONFIG.write_bytes((BACKUP / "shell.json").read_bytes())
    CONFIG.chmod(saved["configMode"])
    for identity in (OLD, APP):
        for base in (HOME / ".config", HOME / ".cache"):
            key = str(base / identity)
            if digest(Path(key)) != saved["privateState"][key]:
                raise RuntimeError("Original private state changed: " + key)
    report["restoration"] = {"filesHashIdentical": True,
                             "configHashIdentical": CONFIG.read_bytes() == (BACKUP / "shell.json").read_bytes()}
    env = dict(os.environ)
    current_host = Path(saved["host"])
    env["OMARCHY_PATH"] = str(current_host)
    for key in tuple(env):
        if key.startswith(("OUTFIT_", "OMAFIT_")):
            env.pop(key)
    run(current_host / "bin/omarchy-restart-shell")
    wait(lambda: json_ipc(OLD, "status"), "original runtime restoration")
    run("hyprctl", "eval", "hl.dispatch(hl.dsp.focus({workspace=" + json.dumps(str(saved["workspace"])) + "}))")
    cursor = saved["cursor"]
    run("hyprctl", "eval", f'hl.dispatch(hl.dsp.cursor.move({{x={cursor["x"]},y={cursor["y"]}}}))')
    report["restoration"].update(oldIdRuntime=True, newIdAbsent=json_ipc(APP, "status") is None,
                                  canonicalHost=str(current_host))
    MARKER.unlink()
    save()

def inventory():
    return json_ipc("shell", "listPlugins") or []

def settled(candidate):
    if not candidate:
        return bool(inventory())
    value = json_ipc("shell", "pluginReconcileStatus") or {}
    return value.get("version") == 1 and not value.get("pending") and not value.get("scanning") and not value.get("scanError")

def surfaces():
    clients = json.loads(run("hyprctl", "clients", "-j"))
    layers = json.loads(run("hyprctl", "layers", "-j"))
    layer_rows = [r for monitor in layers.values() for rows in monitor.get("levels", {}).values() for r in rows]
    result = {}
    for key, title in (("outfit", "Outfit - Plugin Manager"), ("probe", "Fictional Continuity Probe")):
        result[key] = sorted([{"address": r["address"], "pid": r["pid"]} for r in clients
                              if r.get("title") == title and r.get("mapped") and not r.get("hidden")], key=lambda r: r["address"])
    for key, namespace in (("bars", "omarchy-bar"), ("backgrounds", "omarchy-background")):
        result[key] = sorted(r["address"] for r in layer_rows if r.get("namespace") == namespace)
    return result

def tokens():
    return {"panel": json_ipc("shell", "call", PROBE, "report", ""), "widget": json_ipc(WIDGET, "report")}

def affected_widget():
    return [row for row in (json_ipc("shell", "debugBarGeometry") or []) if row.get("id") == OTHER]

def cleanup_errors(path):
    return [line for line in path.read_text().splitlines() if re.search(
        r"Property ['\"]destroy['\"]|TypeError|ReferenceError|stale.*component|Handler was registered but will not be used", line, re.I)]

def prepare_visible(candidate):
    wait(lambda: settled(candidate), "discovery settled")
    # Decline an incidental startup request; never enter credentials or authorize.
    def polkit_visible():
        layers = json.loads(run("hyprctl", "layers", "-j"))
        return any(row.get("namespace") == "omarchy-polkit" for monitor in layers.values()
                   for rows in monitor.get("levels", {}).values() for row in rows)
    if polkit_visible():
        run("wtype", "-k", "Escape")
        wait(lambda: not polkit_visible(), "startup polkit request dismissed", 10)
    for identity in (APP, PROBE):
        response = ipc("shell", "summon", identity, "{}")
        if response != "ok":
            raise RuntimeError("Summon rejected for " + identity + ": " + response)
    wait(lambda: all(surfaces().get(key) for key in ("outfit", "probe", "bars", "backgrounds")), "both app windows and desktop layers")
    wait(lambda: (json_ipc(APP, "status") or {}).get("canBrowse"), "production Outfit browsable")
    wait(lambda: tokens()["panel"] and tokens()["widget"], "panel and widget token IPC")
    ipc("shell", "call", PROBE, "remember", "continuity-marker")
    # Native windows are floated/placed only between measured operations.
    for client in json.loads(run("hyprctl", "clients", "-j")):
        title = client.get("title")
        if title not in {"Outfit - Plugin Manager", "Fictional Continuity Probe"}:
            continue
        address = json.dumps("address:" + client["address"])
        if not client.get("floating"):
            run("hyprctl", "dispatch", 'hl.dsp.window.float({window=' + address + ',action="toggle"})')
        width, height = (980, 660) if title == "Outfit - Plugin Manager" else (250, 90)
        run("hyprctl", "dispatch", 'hl.dsp.window.resize({window=' + address + f',x={width},y={height}' + '})')
        run("hyprctl", "dispatch", 'hl.dsp.window.center({window=' + address + '})')
    time.sleep(1)

def run_host(host, label):
    global current_host, env, shell_process
    candidate = label == "candidate"
    current_host = host
    destination = OUTPUT / label
    destination.mkdir()
    state = destination / "state"
    (state / "config" / APP).mkdir(parents=True)
    (state / "config" / APP / "preferences.json").write_text(json.dumps({"schema": 1,
        "readmeEnrichment": False, "watchHardware": False, "marketplaceThumbnails": False,
        "servicesOnboardingComplete": True}))
    remove(PLUGINS)
    PLUGINS.mkdir()
    (PLUGINS / APP).symlink_to(OUTPUT / "outfit-fixture")
    shutil.copytree(SOURCE / "tests/vm/continuity-probe", PLUGINS / PROBE)
    config = json.loads((BACKUP / "shell.json").read_text())
    config["plugins"] = [p for p in config.get("plugins", []) if (p.get("id") if isinstance(p, dict) else p) not in {OLD, APP, PROBE, OTHER}]
    for section, values in config["bar"]["layout"].items():
        config["bar"]["layout"][section] = [p for p in values if (p.get("id") if isinstance(p, dict) else p) not in {OLD, APP, PROBE, OTHER}]
    config["bar"]["layout"]["right"] += [{"id": APP}, {"id": PROBE}]
    config["idle"] = {"screensaver": 0, "lock": 0}
    CONFIG.write_text(json.dumps(config, indent=2) + "\n")
    env = dict(os.environ, OMARCHY_PATH=str(host), PATH=f"{host}/bin:{HOME}/.local/bin:/usr/bin:/bin",
               OUTFIT_DEMO_ROOT=str(state), OUTFIT_VM_PACK=str(ROOT / "pack"), OUTFIT_VM_SCENARIO="disabled",
               https_proxy="http://127.0.0.1:9", http_proxy="http://127.0.0.1:9", NO_PROXY="", no_proxy="")
    with (destination / "shell.log").open("w") as log:
        shell_process = subprocess.Popen(["quickshell", "-n", "-p", str(host / "shell")],
                                         env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    wait(lambda: bool(inventory()), label + " host discovery", 60)
    host_report = {"path": str(host), "capabilities": json_ipc("shell", "pluginHostCapabilities"),
                   "discoveryStatus": json_ipc("shell", "pluginReconcileStatus"), "operations": []}
    report["hosts"][label] = host_report
    save()
    if candidate and host_report["capabilities"] != {"version": 1, "continuity": 1, "sourceRevisions": 1, "batchLeases": 0}:
        raise RuntimeError("Unexpected candidate capability contract")
    prepare_visible(candidate)
    spec = importlib.util.spec_from_file_location("video_fixture", SOURCE / "tests/vm/continuity_video.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    recorder = module.Recorder(destination, "software")
    recorder.start()
    try:
        for action, argv, expected in (
                ("add", ["add", str(OUTPUT / "mutation-fixture"), "--yes"], "disabled"),
                ("enable", ["enable", OTHER, "right"], "enabled"),
                ("disable", ["disable", OTHER], "disabled"),
                ("remove", ["remove", OTHER, "--yes"], "absent")):
            prepare_visible(candidate)
            before, before_tokens = surfaces(), tokens()
            run("grim", destination / (action + "-before.png"))
            samples = []
            stop = threading.Event()
            def sample():
                while not stop.is_set():
                    try:
                        samples.append({"time": time.monotonic(), **surfaces()})
                    except Exception as error:
                        samples.append({"time": time.monotonic(), "error": str(error)})
                    stop.wait(0.04)
            thread = threading.Thread(target=sample, daemon=True)
            thread.start()
            started = time.monotonic()
            try:
                result = command(host / "bin/omarchy", "plugin", *argv, timeout=90, check=False)
                def observed():
                    row = next((p for p in inventory() if p.get("id") == OTHER), None)
                    widgets = affected_widget()
                    widget_ok = (len(widgets) == 1 and widgets[0].get("visible") and widgets[0].get("itemVisible")) if expected == "enabled" else not widgets
                    return (row is None if expected == "absent" else row is not None and row.get("enabled") is (expected == "enabled")) and settled(candidate) and widget_ok
                if result.returncode == 0:
                    wait(observed, action + " observed inventory", 60)
                time.sleep(1.2)
                after, after_tokens = surfaces(), tokens()
            finally:
                stop.set()
                thread.join(timeout=10)
            changed = [s for s in samples if any(s.get(key) != before[key] for key in before)]
            outcome = {"action": action, "exitCode": result.returncode, "stdout": result.stdout, "stderr": result.stderr,
                       "seconds": time.monotonic() - started, "before": before, "after": after,
                       "beforeTokens": before_tokens, "afterTokens": after_tokens,
                       "samples": len(samples), "changedSamples": len(changed),
                       "surfacesUnchanged": before == after and not changed,
                       "tokensUnchanged": before_tokens == after_tokens,
                       "affectedWidgetGeometry": affected_widget(),
                       "observedStateCorrect": observed(),
                       "discoveryStatus": json_ipc("shell", "pluginReconcileStatus")}
            host_report["operations"].append(outcome)
            (destination / (action + "-samples.json")).write_text(json.dumps(samples, indent=2))
            run("grim", destination / (action + "-after.png"))
            save()
            if result.returncode:
                raise RuntimeError(label + " native " + action + " failed")
    finally:
        recorder.stop()
        host_report["recording"] = {"path": str(recorder.video), "mechanism": recorder.mechanism,
                                     "frames": len(recorder.frames), "duration": time.monotonic() - recorder.started}
        (destination / "video-frames.json").write_text(json.dumps(recorder.frames))
        save()
    if candidate and not args.skip_auth:
        auth_env = dict(env, PATH=f"{host}/bin:" + os.environ["PATH"])
        result = command("bash", host / "test/shell.d/plugin-auth-boundary-test.sh", timeout=90, check=False, environment=auth_env)
        (destination / "auth-boundary.log").write_text(result.stdout + result.stderr)
        host_report["authBoundary"] = {"exitCode": result.returncode,
            "nativeRuntimePassed": "ok - plugin authentication boundary runtime behavior" in result.stdout,
            "runtimeSkipped": "skipping" in result.stdout, "fixtureOnly": True}
    elif candidate:
        host_report["authBoundary"] = {"rerun": False, "reason": "Requested four-action-only smoke; prior runtime pass retained for unchanged auth sources"}
    final_config = json_ipc("shell", "listShellConfig") or {}
    entries = final_config.get("plugins", []) + [entry for values in final_config.get("bar", {}).get("layout", {}).values() for entry in values]
    host_report["finalFixtureState"] = {
        "inventoryAbsent": not any(row.get("id") == OTHER for row in inventory()),
        "widgetInstanceAbsent": not affected_widget(),
        "installationAbsent": not (PLUGINS / OTHER).exists(),
        "configEntryAbsent": not any((entry.get("id") if isinstance(entry, dict) else entry) == OTHER for entry in entries),
        "discoverySettled": settled(candidate)}
    stop_shell()
    host_report["cleanupErrors"] = cleanup_errors(destination / "shell.log")
    host_report["cleanupLogPassed"] = not host_report["cleanupErrors"]
    save()

if args.auth_only:
    if not (OUTPUT / "report.json").is_file() or not (OUTPUT / "candidate").is_dir():
        raise SystemExit("An existing continuity evidence directory is required")
    log = OUTPUT / "candidate/auth-standalone.log"
    if log.exists():
        raise SystemExit("Choose unused auth evidence")
    before = CONFIG.read_bytes()
    auth_env = dict(os.environ, OMARCHY_PATH=str(args.candidate), PATH=f"{args.candidate}/bin:" + os.environ["PATH"])
    result = command("bash", args.candidate / "test/shell.d/plugin-auth-boundary-test.sh", timeout=90,
                     check=False, environment=auth_env)
    log.write_text(result.stdout + result.stderr)
    details = {"exitCode": result.returncode, "nativeRuntimePassed": "ok - plugin authentication boundary runtime behavior" in result.stdout,
               "runtimeSkipped": "skipping" in result.stdout, "configBytesUnchanged": CONFIG.read_bytes() == before,
               "fixtureOnly": True, "log": str(log)}
    (OUTPUT / "candidate/auth-standalone.json").write_text(json.dumps(details, indent=2))
    print(json.dumps(details, indent=2))
    raise SystemExit(0 if details["nativeRuntimePassed"] and details["configBytesUnchanged"] else 1)
if args.restore:
    report = json.loads((OUTPUT / "report.json").read_text())
    saved = json.loads(MARKER.read_text())
    current_host = Path(saved.get("activeHost", saved["host"]))
    restore(saved)
    raise SystemExit()
if OUTPUT.exists() or not OUTPUT.parent.is_dir():
    raise SystemExit("Choose a new output under an existing guest directory")
source_hashes = json.loads((args.candidate / "vm-source-hashes.json").read_text())
actual_shell_hash = hashlib.sha256((args.candidate / "shell/shell.qml").read_bytes()).hexdigest()
if args.expect_shell_sha256 and actual_shell_hash != args.expect_shell_sha256:
    raise SystemExit("Guest shell source does not match post-fix handoff")
report["testedShellSha256"] = actual_shell_hash
if args.skip_auth:
    if not args.previous_host_hashes:
        raise SystemExit("--skip-auth requires prior source hashes")
    previous = json.loads(args.previous_host_hashes.read_text())["files"]
    auth_files = [name for name in source_hashes["files"] if name in {
        "shell/services/AuthServiceStore.js", "shell/services/PluginShellApi.qml",
        "shell/services/PluginRegistryApi.qml", "test/shell.d/plugin-auth-boundary-test.sh"}
        or name.startswith(("shell/plugins/lock/", "shell/plugins/polkit/", "test/shell.d/fixtures/plugin-auth-boundary/"))]
    changed = [name for name in auth_files if source_hashes["files"][name] != previous.get(name)]
    if changed or len(auth_files) < 7:
        raise SystemExit("Auth source changed or incomplete: " + str(changed))
    report["authSourceComparison"] = {"unchanged": True, "previousManifest": str(args.previous_host_hashes),
                                      "files": {name: source_hashes["files"][name] for name in auth_files}}
for tool in ("quickshell", "hyprctl", "grim", "ffmpeg", "node", "jq"):
    if not shutil.which(tool):
        raise SystemExit("Missing guest prerequisite: " + tool)
original = json_ipc(OLD, "status") or {}
if original.get("opened") or original.get("batchRunning") or original.get("interestsDirty"):
    raise SystemExit("Close original guest Outfit and finish pending work first")
if command("omarchy-hyprland-session-locked", check=False).returncode == 0:
    raise SystemExit("Guest is locked; no authentication/session changes allowed")
OUTPUT.mkdir(mode=0o700)
BACKUP.mkdir(mode=0o700)
report["harnessSource"] = {"runner": digest(Path(__file__)),
                            "probe": digest(SOURCE / "tests/vm/continuity-probe")}
shutil.copy2(CONFIG, BACKUP / "shell.json")
shutil.copyfile(ROOT / "source-hashes.json", OUTPUT / "outfit-source-hashes.json")
shutil.copyfile(args.candidate / "vm-source-hashes.json", OUTPUT / "host-source-hashes.json")
shutil.copytree(SOURCE, OUTPUT / "outfit-fixture")
shutil.copyfile(SOURCE / "tests/vm/first_run_worker.py", OUTPUT / "outfit-fixture/demo/fixture_worker.py")
shutil.copytree(SOURCE / "tests/vm/fixture-plugin", OUTPUT / "mutation-fixture")
fixture_env = dict(os.environ, GIT_AUTHOR_NAME="VM fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
                   GIT_COMMITTER_NAME="VM fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid")
for argv in (["init", "-b", "main"], ["add", "."], ["commit", "-m", "Fictional disposable lifecycle fixture"]):
    run("git", "-C", OUTPUT / "mutation-fixture", *argv, environment=fixture_env)
saved = {"host": str(ORIGINAL_HOST), "paths": [], "configMode": CONFIG.stat().st_mode & 0o777,
         "workspace": json.loads(run("hyprctl", "activeworkspace", "-j"))["id"],
         "cursor": json.loads(run("hyprctl", "cursorpos", "-j")), "privateState": {}}
stop_shell()
for identity in (OLD, APP):
    for base in (HOME / ".config", HOME / ".cache"):
        saved["privateState"][str(base / identity)] = digest(base / identity)
def interrupted(signum, _frame):
    raise SystemExit("VM check interrupted: " + signal.Signals(signum).name)
for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(signum, interrupted)
try:
    for index, path in enumerate((PLUGINS, Path(os.environ["XDG_RUNTIME_DIR"]) / "omarchy-plugin-code")):
        backup = BACKUP / str(index)
        row = {"path": str(path), "backup": str(backup), "existed": path.exists() or path.is_symlink(), "digest": digest(path)}
        if row["existed"]:
            shutil.move(str(path), str(backup))
        saved["paths"].append(row)
        MARKER.write_text(json.dumps(saved, indent=2))
    for host, label in ((args.baseline, "baseline"), (args.candidate, "candidate")):
        if label not in args.hosts:
            continue
        saved["activeHost"] = str(host)
        MARKER.write_text(json.dumps(saved, indent=2))
        try:
            run_host(host, label)
        except Exception as error:
            report["failures"].append({"host": label, "error": str(error), "traceback": traceback.format_exc()})
            report["hosts"].setdefault(label, {})["failureState"] = {
                "surfaces": surfaces(), "tokens": tokens(), "outfit": json_ipc(APP, "status"),
                "clients": json.loads(run("hyprctl", "clients", "-j")),
                "layers": json.loads(run("hyprctl", "layers", "-j"))}
            run("grim", OUTPUT / label / "failure.png")
            stop_shell()
            save()
finally:
    restore(saved)
candidate = report["hosts"].get("candidate", {})
operations = candidate.get("operations", [])
report["candidateContinuityPassed"] = len(operations) == 4 and all(
    r["exitCode"] == 0 and r["surfacesUnchanged"] and r["tokensUnchanged"] and r["observedStateCorrect"] for r in operations)
report["candidateAuthPassed"] = None if args.skip_auth else candidate.get("authBoundary", {}).get("nativeRuntimePassed") is True
report["candidateCleanupPassed"] = candidate.get("cleanupLogPassed") is True and all(candidate.get("finalFixtureState", {}).values())
save()
print(json.dumps(report, indent=2))
raise SystemExit(0 if report["candidateContinuityPassed"] and report["candidateCleanupPassed"]
                 and (report["candidateAuthPassed"] or args.skip_auth) and not report["failures"] else 1)
