#!/usr/bin/env python3
"""VM-only close -> Apps summon -> standalone inspector uninstall regression.

The packaged and targeted hosts are selected only in process environments. No
dev-link or packaged-file changes occur. The app uses its production worker with
isolated XDG stores seeded with one fictional, already-installed fixture listing.
No external summon is permitted after uninstall confirmation until measurement
has finished. --restore recovers a stopped/interrupted run from its private marker.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
APP = "io.github.ctl0v0.outfit"
FIXTURE = "org.example.omafit-release-fixture"
TITLE = "Outfit - Plugin Manager"
PANEL_TITLE = "Outfit VM Fixture Panel"
HOSTS = {"packaged": "/usr/share/omarchy", "targeted": "/home/tester/omarchy-host"}
ENV_KEYS = ("OMARCHY_PATH", "PATH", "XDG_CONFIG_HOME", "XDG_CACHE_HOME",
            "OUTFIT_DEMO_ROOT", "OUTFIT_DEMO_SCENARIO", "OMAFIT_DEMO_ROOT", "OMAFIT_DEMO_SCENARIO")
GUI_TOOLS = {name: shutil.which(name) for name in ("hyprctl", "wlrctl", "wtype", "grim", "quickshell")}


def run(*argv, check=True, timeout=30, env=None):
    if argv[0] in GUI_TOOLS and GUI_TOOLS[argv[0]]:
        argv = (GUI_TOOLS[argv[0]], *argv[1:])
    result = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, env=env)
    if check and result.returncode:
        raise RuntimeError(f"{Path(argv[0]).name} failed (exit {result.returncode})")
    return result.stdout.strip()


def require(value, message):
    if not value:
        raise RuntimeError(message)


def wait(predicate, message, timeout=40):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            result = predicate()
        except (ValueError, RuntimeError, StopIteration):
            result = None
        if result:
            return result
        time.sleep(0.12)
    raise RuntimeError("Timeout: " + message)


def ipc(method, *args):
    return run("omarchy-shell", "shell", method, *args)


def inventory():
    return json.loads(ipc("listPlugins"))


def status():
    raw = json.loads(run("omarchy-shell", APP, "status"))
    # Never persist device profiles or opaque restore/lease tokens.
    return {key: raw[key] for key in ("demo", "opened", "ready", "selectedPlugin", "inventoryReady",
            "batchRunning", "batchSelected", "batchItems", "hostLifecycle", "panelRecovery", "openAction") if key in raw}


def host_status():
    text = run("omarchy-shell", "shell", "pluginLifecycle", check=False)
    try:
        value = json.loads(text)
        return {key: value[key] for key in ("version", "generation", "settledGeneration", "scanning",
                "reconciling", "pending", "held", "leaseCount", "scanError")}
    except (ValueError, KeyError):
        return {"supported": False}


def stable_host():
    value = host_status()
    return value.get("supported") is False or (not any(value[k] for k in ("held", "pending", "scanning", "reconciling"))
                                                and not value["scanError"])


def window():
    return next((row for row in json.loads(run("hyprctl", "clients", "-j"))
                 if row.get("title") == TITLE and row.get("mapped") and not row.get("hidden")), None)


def surfaces():
    app = window()
    layers = json.loads(run("hyprctl", "layers", "-j"))
    rows = [r for monitor in layers.values() for level in monitor.get("levels", {}).values() for r in level]
    return {"windows": [app["address"]] if app else [], "pids": [app["pid"]] if app else [],
            "backgrounds": sorted(r["address"] for r in rows if r.get("namespace") == "omarchy-background"),
            "bars": sorted(r["address"] for r in rows if r.get("namespace") == "omarchy-bar")}


def capture_instance_diagnostics(output, pid):
    # Read the exact Quickshell instance, not journal records from a reused PID
    # in an older boot. Keep only the two relevant static message patterns.
    try:
        result = subprocess.run([GUI_TOOLS["quickshell"], "log", "--pid", str(pid), "--no-color", "--log-times"],
                                capture_output=True, text=True, timeout=15)
        messages = [line for line in result.stdout.splitlines()
                    if ("Local plugin changed, reloading: " + FIXTURE) in line
                    or (APP in line and "Object or context destroyed during incubation" in line)
                    or any(name in line for name in ("PluginDetailPage.qml", "TypeError", "ReferenceError", "Unable to assign", "Binding loop"))]
        data = {"pid": pid, "exitCode": result.returncode, "messages": messages}
    except subprocess.SubprocessError:
        data = {"pid": pid, "unavailable": True}
    (output / "instance-diagnostics.json").write_text(json.dumps(data, indent=2))


def apply_environment(values):
    for key in ENV_KEYS:
        os.environ.pop(key, None)
    os.environ.update({key: value for key, value in values.items() if value is not None})


def launch(root, environment, saved, marker):
    current_root = saved["activeRoot"]
    run("quickshell", "kill", "-p", current_root + "/shell", "--any-display", check=False)
    wait(lambda: not run("omarchy-shell", "shell", "ping", check=False), "previous shell shutdown", 15)
    apply_environment(environment)
    saved["activeRoot"] = root
    marker.write_text(json.dumps(saved))
    command = ["env"]
    for key in ENV_KEYS:
        command += ["-u", key]
    command += [key + "=" + value for key, value in environment.items() if value is not None]
    command += [root + "/bin/omarchy-launch-shell"]
    run("hyprctl", "eval", "hl.dispatch(hl.dsp.exec_cmd(" + json.dumps(shlex.join(command)) + "))")
    wait(lambda: status().get("demo") is False, "production service in selected host")


def create_fixture(state):
    source = state / "fixture"
    shutil.copytree(ROOT / "tests/vm/fixture-plugin", source)
    manifest = json.loads((source / "manifest.json").read_text())
    manifest["kinds"] = ["bar-widget", "panel"]
    manifest["entryPoints"]["panel"] = "Panel.qml"
    (source / "manifest.json").write_text(json.dumps(manifest, indent=2))
    # Generated only inside this private temporary Git fixture. The Open action
    # must summon a genuine declared panel through the production worker/host.
    (source / "Panel.qml").write_text('''import QtQuick
import Quickshell
Item {
  id: root
  property var shell: null
  property var manifest: null
  property bool opened: false
  function open(payloadJson) { opened = true }
  function close() { opened = false }
  FloatingWindow {
    title: "Outfit VM Fixture Panel"
    visible: root.opened
    implicitWidth: 300
    implicitHeight: 180
    minimumSize: Qt.size(300, 180)
    maximumSize: Qt.size(300, 180)
    color: "#202432"
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      y: 40
      text: "Harmless native fixture panel"
      textFormat: Text.PlainText
      color: "#cad3f5"
    }
    Rectangle {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: 16
      width: 180
      height: 36
      color: "#41485e"
      Text { anchors.centerIn: parent; text: "Close fixture"; textFormat: Text.PlainText; color: "#cad3f5" }
      MouseArea { anchors.fill: parent; onClicked: root.close() }
    }
  }
}
''')
    env = dict(os.environ, GIT_AUTHOR_NAME="Outfit recovery fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
               GIT_COMMITTER_NAME="Outfit recovery fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid")
    for args in (("init", "-b", "main"), ("add", "."), ("commit", "-m", "Disposable standalone uninstall fixture")):
        run("git", "-C", str(source), *args, env=env)
    return source, run("git", "-C", str(source), "rev-parse", "HEAD")


def seed_stores(state, revision):
    spec = importlib.util.spec_from_file_location("outfit_recovery_backend", ROOT / "scripts/outfit.py")
    backend = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(backend)
    raw = json.loads((ROOT / "demo/fixtures/example.json").read_text())["catalog"]
    row = dict(raw["plugins"][0])
    row.update(id=FIXTURE, name="Uninstall Recovery Fixture", description="Harmless fictional widget for VM recovery testing.",
               repo="https://github.com/omafit-vm-fixture/uninstall-recovery", listingValidatedCommit=revision, verificationCommit=revision)
    items, generated = backend.normalize_catalog({**raw, "plugins": [row]})
    cache, prefs = backend.Store(state / "cache" / APP), backend.Store(state / "config" / APP)
    try:
        now = time.time()
        backend.save_catalog(cache, items, generated, now)
        cache.write("engagement.json", {"schemaVersion": 1, "fetchedAt": now, "plugins": {FIXTURE: {"hearts": 0}}}, backend.MAX_ENGAGEMENT_BYTES)
        backend.save_preferences(prefs, {**backend.DEFAULT_PREFERENCES, "watchHardware": False,
            "readmeEnrichment": False, "readmeIndexing": False, "marketplaceThumbnails": False,
            "servicesOnboardingComplete": True})
    finally:
        cache.close()
        prefs.close()


def prepare(host, output, marker):
    require(not marker.exists(), "Existing uninstall recovery marker; use --restore")
    runtime = Path(os.environ["XDG_RUNTIME_DIR"])
    require(not any((runtime / name).exists() for name in ("omafit-mutation-recovery.json", "omafit-demo-recovery-1000.json")), "Another VM harness requires recovery")
    require(not any(row["id"] == FIXTURE for row in inventory()), "Fixture is already installed")
    require(stable_host(), "Original host is busy or held")
    config = Path.home() / ".config/omarchy/shell.json"
    require(config.is_file(), "Original shell config missing")
    state = Path(tempfile.mkdtemp(prefix="omafit-uninstall-", dir=runtime))
    (state / "shell.json.backup").write_bytes(config.read_bytes())
    (state / "shell.json.backup").chmod(0o600)
    saved = {"state": str(state), "output": str(output), "config": str(config), "host": host,
             "originalEnvironment": {key: os.environ.get(key) for key in ENV_KEYS}, "activeRoot": os.environ["OMARCHY_PATH"],
             "opened": status().get("opened", False), "workspace": json.loads(run("hyprctl", "activeworkspace", "-j"))["id"],
             "cursor": json.loads(run("hyprctl", "cursorpos", "-j"))}
    marker.write_text(json.dumps(saved))
    marker.chmod(0o600)
    output.mkdir()
    source, revision = create_fixture(state)
    seed_stores(state, revision)
    selected = HOSTS[host]
    environment = {**saved["originalEnvironment"], "OMARCHY_PATH": selected, "PATH": selected + "/bin:/usr/bin:/bin",
                   "XDG_CONFIG_HOME": str(state / "config"), "XDG_CACHE_HOME": str(state / "cache"),
                   "OUTFIT_DEMO_ROOT": None, "OUTFIT_DEMO_SCENARIO": None,
                   "OMAFIT_DEMO_ROOT": None, "OMAFIT_DEMO_SCENARIO": None}
    launch(selected, environment, saved, marker)
    run("omarchy", "plugin", "add", str(source), "--enable", "--yes", timeout=90)
    wait(lambda: any(row["id"] == FIXTURE and row["enabled"] for row in inventory()), "fixture installed and enabled")
    wait(stable_host, "fixture setup settled")
    time.sleep(2)
    service = (Path.home() / ".config/omarchy/plugins" / APP / "Service.qml").read_text()
    start = service.index("  function panelOpened(")
    stop = service.index("\n  }", start) + 4
    provenance = {"hostRoot": selected, "hostLifecycle": host_status(), "productionWorker": True,
                  "fixtureRevision": revision, "serviceSha256": hashlib.sha256(service.encode()).hexdigest(),
                  "panelOpenedSource": service[start:stop],
                  "candidateRevision": run("git", "-C", str(Path.home() / ".config/omarchy/plugins" / APP), "rev-parse", "HEAD"),
                  "sourceSha256": {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
                                   for name in ("Service.qml", "ui/OutfitApp.qml", "ui/PluginDetailPage.qml", "ui/InspectorState.js", "scripts/outfit.py")},
                  "fixtureManifest": json.loads((source / "manifest.json").read_text())}
    (output / "provenance.json").write_text(json.dumps(provenance, indent=2))
    return saved


def restore(saved, marker):
    state, output = Path(saved["state"]), Path(saved["output"])
    # session_exec restores the manager environment on a separate recovery call;
    # select the marker's active process root before talking to its IPC socket.
    os.environ["OMARCHY_PATH"] = saved["activeRoot"]
    os.environ["PATH"] = saved["activeRoot"] + "/bin:/usr/bin:/bin"
    if any(row["id"] == FIXTURE for row in inventory()):
        run("omarchy", "plugin", "remove", FIXTURE, "--yes", timeout=60)
    wait(lambda: not any(row["id"] == FIXTURE for row in inventory()) and stable_host(), "fixture cleanup", 65)
    config, backup = Path(saved["config"]), state / "shell.json.backup"
    require(json.loads(config.read_bytes()) == json.loads(backup.read_bytes()), "Unexpected config changes; preserve backup and marker")
    if config.read_bytes() != backup.read_bytes():
        config.write_bytes(backup.read_bytes())
    original = saved["originalEnvironment"]
    launch(original["OMARCHY_PATH"], original, saved, marker)
    run("hyprctl", "eval", "hl.dispatch(hl.dsp.focus({workspace=" + json.dumps(str(saved["workspace"])) + "}))")
    if saved["opened"]:
        ipc("summon", APP, "{}")
    wait(stable_host, "normal host restored")
    cursor = saved["cursor"]
    run("hyprctl", "eval", f'hl.dispatch(hl.dsp.cursor.move({{x={int(cursor["x"])},y={int(cursor["y"])}}}))')
    result = {"hostRootRestored": os.environ["OMARCHY_PATH"] == original["OMARCHY_PATH"],
              "configByteIdentical": config.read_bytes() == backup.read_bytes(),
              "configBeforeSha256": hashlib.sha256(backup.read_bytes()).hexdigest(),
              "configAfterSha256": hashlib.sha256(config.read_bytes()).hexdigest(),
              "fixtureAbsent": not any(row["id"] == FIXTURE for row in inventory()),
              "workspaceRestored": json.loads(run("hyprctl", "activeworkspace", "-j"))["id"] == saved["workspace"],
              "cursorRestored": json.loads(run("hyprctl", "cursorpos", "-j")) == cursor, "settled": stable_host()}
    (output / "restoration.json").write_text(json.dumps(result, indent=2))
    require(all(result[k] for k in ("hostRootRestored", "configByteIdentical", "fixtureAbsent", "workspaceRestored", "cursorRestored", "settled")), "Restoration verification failed")
    marker.unlink()


def exercise(saved, observe_seconds, expect):
    output = Path(saved["output"])
    events, samples = [], []
    def capture(name):
        run("grim", str(output / (name + ".png")))
    def click(x, y, label):
        events.append({"interaction": "click", "label": label, "time": time.monotonic()})
        run("hyprctl", "eval", f'hl.dispatch(hl.dsp.cursor.move({{x={int(x)},y={int(y)}}}))')
        run("wlrctl", "pointer", "move", "1", "0")
        run("wlrctl", "pointer", "click")
        time.sleep(0.2)
    def summon(payload, label):
        events.append({"interaction": "summon", "label": label, "time": time.monotonic(), "payload": payload})
        ipc("summon", APP, json.dumps(payload))
        wait(lambda: window() and status().get("ready"), label)
    def resize(width, height):
        current = window()
        address = json.dumps("address:" + current["address"])
        if not current.get("floating"):
            run("hyprctl", "dispatch", 'hl.dsp.window.float({window=' + address + ',action="toggle"})')
        run("hyprctl", "dispatch", 'hl.dsp.window.resize({window=' + address + f',x={width},y={height}' + '})')
        run("hyprctl", "dispatch", 'hl.dsp.window.center({window=' + address + '})')
        wait(lambda: window() if window()["size"] == [width, height] else None, "fixture window geometry", 8)
        # Hyprland exposes the target rectangle before its resize animation has
        # reached it; wait before screenshots and coordinate-based interaction.
        time.sleep(0.6)
        return window()
    def fixture_panel():
        return next((r for r in json.loads(run("hyprctl", "clients", "-j"))
                     if r.get("title") == PANEL_TITLE and r.get("mapped") and not r.get("hidden")), None)
    selected = {"workspaceView": "browse", "setupStage": "browse", "selectedId": FIXTURE}
    summon(selected, "initial fixture inspector")
    w = resize(1180, 760)
    environment = Path(f'/proc/{w["pid"]}/environ').read_bytes().split(b"\0")
    require(("OMARCHY_PATH=" + HOSTS[saved["host"]]).encode() in environment
            and ("XDG_CONFIG_HOME=" + saved["state"] + "/config").encode() in environment,
            "Shell environment does not match selected runtime and isolated app stores")
    require(not status().get("batchRunning") and not status().get("batchItems"), "Standalone test must not follow an app batch")
    capture("01-before-user-close")
    click(w["at"][0] + w["size"][0] - 35, w["at"][1] + 35, "Outfit window X: user close")
    wait(lambda: window() is None and not status().get("opened"), "actual user close")
    capture("02-user-closed")
    summon({}, "Apps-style standard shell summon")
    capture("03-apps-reopened")
    # Select only before the mutation. This still enters panelOpened via the
    # standard host path, never the BarWidget/service.openEditor path.
    summon(selected, "pre-uninstall inspector selection")
    w = resize(1180, 760)
    capture("04a-production-detail-normal")
    resize(760, 540)
    capture("04b-production-detail-compact")
    w = resize(1180, 760)
    require(fixture_panel() is None, "Fixture panel unexpectedly already open")
    click(w["at"][0] + w["size"][0] - 160, w["at"][1] + 296, "Production detail Open")
    panel = wait(fixture_panel, "real declared fixture panel after Open", 15)
    time.sleep(0.4)
    panel = fixture_panel()
    require(panel["pid"] == w["pid"], "Fixture panel must be hosted by the same native shell")
    (output / "open-evidence.json").write_text(json.dumps({"productionOpenVerified": True, "panelTitle": panel["title"],
        "panelAddress": panel["address"], "panelPid": panel["pid"], "omafitAddress": w["address"],
        "omafitPid": w["pid"], "inventory": next(row for row in inventory() if row["id"] == FIXTURE)}, indent=2))
    capture("04c-real-open-panel")
    run("hyprctl", "eval", "hl.dispatch(hl.dsp.focus({window=" + json.dumps("address:" + panel["address"]) + "}))")
    time.sleep(0.2)
    click(panel["at"][0] + panel["size"][0] // 2, panel["at"][1] + panel["size"][1] - 34, "Close native fixture panel")
    wait(lambda: fixture_panel() is None, "native panel dismissed", 8)
    run("hyprctl", "eval", "hl.dispatch(hl.dsp.focus({window=" + json.dumps("address:" + w["address"]) + "}))")
    wait(lambda: status().get("ready"), "production detail ready after Open")
    baseline = surfaces()
    capture("04-standalone-inspector")
    click(w["at"][0] + w["size"][0] - 160, w["at"][1] + 461, "Visible production Uninstall button")
    time.sleep(0.2)
    capture("05-uninstall-confirmation")
    started = time.monotonic()
    events.append({"interaction": "keyboard", "keys": ["Right", "Return"], "label": "Confirm standalone uninstall",
                   "time": started, "wallTime": time.time()})
    stop = threading.Event()
    def sample():
        while not stop.is_set():
            row = {"time": time.monotonic()}
            try:
                row.update(surfaces())
                row["status"] = status()
            except Exception:
                row["probeError"] = True
            samples.append(row)
            stop.wait(0.06)
    thread = threading.Thread(target=sample, daemon=True)
    thread.start()
    failure = None
    try:
        run("wtype", "-k", "Right", "-k", "Return")
        wait(lambda: not any(row["id"] == FIXTURE for row in inventory()), "confirmed native uninstall", 40)
        capture("06-after-native-removal")
        # Deliberately no summon/focus/window manipulation in this interval.
        while time.monotonic() - started < observe_seconds:
            time.sleep(0.15)
        capture("07-recovery-observation")
    except Exception as error:
        failure = str(error)
        capture("failure")
    finally:
        stop.set()
        thread.join(timeout=10)
    changed = [row for row in samples if any(row.get(k) != v for k, v in baseline.items())]
    final = status()
    reopened = bool(window()) and final.get("opened") is True
    removed = not any(row["id"] == FIXTURE for row in inventory())
    acceptable = removed and reopened and (saved["host"] != "targeted" or not changed)
    passed = (not failure and acceptable) if expect == "pass" else (not failure and removed and not reopened)
    missing = [row for row in samples if not row.get("windows") and not row.get("probeError")]
    report = {"pass": passed, "expectation": expect, "failure": failure, "host": saved["host"],
              "standaloneNoPriorBatch": True, "productionOpenVerified": True, "removed": removed, "autoReopenedWithoutExternalSummon": reopened,
              "finalVisibleWithoutExternalSummon": reopened, "windowMissingSamples": len(missing),
              "recoveredAfterObservedWindowLoss": bool(missing) and reopened,
              "continuouslySameSurfaces": not changed,
              "observationSeconds": round(time.monotonic() - started, 3), "baseline": baseline,
              "samples": len(samples), "discontinuousSamples": len(changed),
              "probeErrors": sum(bool(row.get("probeError")) for row in samples), "finalStatus": final,
              "externalSummonsAfterConfirmation": sum(e["interaction"] == "summon" and e["time"] > started for e in events)}
    (output / "report.json").write_text(json.dumps(report, indent=2))
    (output / "surfaces.json").write_text(json.dumps(samples, indent=2))
    (output / "interactions.json").write_text(json.dumps(events, indent=2))
    capture_instance_diagnostics(output, baseline["pids"][0])
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", choices=tuple(HOSTS), default="targeted")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--observe-seconds", type=float, default=20)
    parser.add_argument("--expect", choices=("pass", "closed"), default="pass")
    parser.add_argument("--restore", action="store_true")
    args = parser.parse_args()
    require((os.environ.get("OUTFIT_TEST_VM") or os.environ.get("OMAFIT_TEST_VM")) == "1" and run("systemd-detect-virt", "--vm") == "kvm", "Disposable KVM VM required")
    require(os.environ.get("OMARCHY_PATH") == HOSTS["targeted"], "Enter via session_exec.py with the original VM runtime")
    require(all(GUI_TOOLS.values()), "VM GUI test tools must be present before switching runtime PATH")
    require(subprocess.run(["omarchy-hyprland-session-locked"], stdout=subprocess.DEVNULL).returncode != 0, "Unlock VM before testing")
    require(8 <= args.observe_seconds <= 60, "Bound observation to 8-60 seconds")
    marker = Path(os.environ["XDG_RUNTIME_DIR"]) / "omafit-uninstall-recovery.json"
    saved = None
    def interrupted(*_args):
        raise RuntimeError("Uninstall regression interrupted")
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, interrupted)
    try:
        if args.restore:
            require(marker.is_file() and not marker.is_symlink(), "No recovery marker")
            saved = json.loads(marker.read_text())
            return 0
        require(args.output and args.output.parent.resolve() == ROOT / "test-results" and not args.output.exists(), "Choose new VM test-results directory")
        saved = prepare(args.host, args.output.resolve(), marker)
        report = exercise(saved, args.observe_seconds, args.expect)
        print(json.dumps(report))
        return 0 if report["pass"] else 1
    except Exception as error:
        if saved:
            output = Path(saved["output"])
            (output / "harness-failure.json").write_text(json.dumps({"error": str(error)}, indent=2))
            run("grim", str(output / "harness-failure.png"), check=False)
            current = window()
            if current:
                capture_instance_diagnostics(output, current["pid"])
        raise
    finally:
        if saved is None and marker.is_file():
            saved = json.loads(marker.read_text())
        if saved:
            restore(saved, marker)
            print("Original VM host/runtime/config/workspace/cursor restored; fixture removed.")


if __name__ == "__main__":
    raise SystemExit(main())
