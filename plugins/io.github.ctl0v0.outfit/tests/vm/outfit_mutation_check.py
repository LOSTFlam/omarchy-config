#!/usr/bin/env python3
"""Actual Outfit batch/uninstall UI against two guarded local repositories in a VM.

--prepare-only leaves a recovery marker for inspection; --resume runs interactions
and restores in finally. --restore recovers an interrupted run. No production IPC
is added: selection uses summon, all mutation decisions use visible UI controls.
"""
import argparse
import hashlib
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

ROOT = Path(__file__).resolve().parents[2]
APP = "io.github.ctl0v0.outfit"
IDS = ("org.example.omafit-release-fixture", "org.example.omafit-release-fixture-two")
TITLE = "Outfit - Plugin Manager"


def run(*command, timeout=30, check=True, env=None, input=None):
    result = subprocess.run(command, capture_output=True, text=True, timeout=timeout, env=env, input=input)
    if check and result.returncode:
        raise RuntimeError(f"{Path(command[0]).name} exited {result.returncode}")
    return result.stdout.strip()


def require(value, message):
    if not value:
        raise RuntimeError(message)


def wait(predicate, message, timeout=40):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            result = predicate()
        except (ValueError, RuntimeError):
            result = None
        if result:
            return result
        time.sleep(0.12)
    raise RuntimeError("Timeout: " + message)


def status():
    return json.loads(run("omarchy-shell", APP, "status"))


def lifecycle():
    return json.loads(run("omarchy-shell", "shell", "pluginLifecycle"))


def settled():
    value = lifecycle()
    return not any(value[k] for k in ("held", "pending", "scanning", "reconciling")) and not value["scanError"]


def window():
    return next((row for row in json.loads(run("hyprctl", "clients", "-j")) if row.get("title") == TITLE), None)


def surfaces():
    clients = json.loads(run("hyprctl", "clients", "-j"))
    layers = json.loads(run("hyprctl", "layers", "-j"))
    rows = [r for monitor in layers.values() for values in monitor.get("levels", {}).values() for r in values]
    app = [c for c in clients if c.get("title") == TITLE and c.get("mapped") and not c.get("hidden")]
    return {"windows": sorted(c["address"] for c in app), "pids": sorted(c["pid"] for c in app),
            "backgrounds": sorted(r["address"] for r in rows if r.get("namespace") == "omarchy-background"),
            "bars": sorted(r["address"] for r in rows if r.get("namespace") == "omarchy-bar")}


def launch(state=None):
    shell_path = str(Path(os.environ["OMARCHY_PATH"]) / "shell")
    run("quickshell", "kill", "-p", shell_path, "--any-display", check=False)
    wait(lambda: not run("omarchy-shell", "shell", "ping", check=False), "shell shutdown", 15)
    command = ["env", "-u", "OUTFIT_DEMO_ROOT", "-u", "OUTFIT_DEMO_SCENARIO",
               "-u", "OMAFIT_DEMO_ROOT", "-u", "OMAFIT_DEMO_SCENARIO"]
    if state:
        command += ["OUTFIT_TEST_VM=1", "OUTFIT_DEMO_ROOT=" + str(state), "OUTFIT_DEMO_SCENARIO=native-lifecycle"]
    command += ["omarchy-launch-shell"]
    run("hyprctl", "eval", "hl.dispatch(hl.dsp.exec_cmd(" + json.dumps(shlex.join(command)) + "))")
    wait(lambda: status().get("demo") is bool(state), "correct shell fixture environment")


def prepare(config, marker, output):
    require(config.is_file() and not marker.exists(), "Missing config or existing recovery marker")
    require(not any(i in lifecycle()["plugins"] for i in IDS), "Fixture plugin already exists")
    for relative in ("Service.qml", "ui/OutfitApp.qml", "scripts/outfit.py", "demo/fixture_worker.py"):
        installed = config.parent / "plugins" / APP / relative
        require(hashlib.sha256((ROOT / relative).read_bytes()).digest() == hashlib.sha256(installed.read_bytes()).digest(),
                "Candidate is not synchronized: " + relative)
    state = Path(tempfile.mkdtemp(prefix="omafit-native-lifecycle-", dir=os.environ["XDG_RUNTIME_DIR"]))
    (state / "shell.json.backup").write_bytes(config.read_bytes())
    (state / "shell.json.backup").chmod(0o600)
    saved = {"state": str(state), "output": str(output), "workspace": json.loads(run("hyprctl", "activeworkspace", "-j"))["id"],
             "cursor": json.loads(run("hyprctl", "cursorpos", "-j")), "opened": status().get("opened", False),
             "configSha256": hashlib.sha256(config.read_bytes()).hexdigest()}
    marker.write_text(json.dumps(saved))
    marker.chmod(0o600)
    output.mkdir()
    env = dict(os.environ, GIT_AUTHOR_NAME="Outfit fictional fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
               GIT_COMMITTER_NAME="Outfit fictional fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid")
    revisions = {}
    for index, identity in enumerate(IDS):
        repo = state / "repos" / identity
        shutil.copytree(ROOT / "tests/vm/fixture-plugin", repo)
        manifest = json.loads((repo / "manifest.json").read_text())
        manifest.update(id=identity, name="Native Lifecycle Fixture " + ("One" if index == 0 else "Two"))
        (repo / "manifest.json").write_text(json.dumps(manifest, indent=2))
        widget = (repo / "Widget.qml").read_text().replace(IDS[0], identity).replace('text: "TEST"', f'text: "TEST{index + 1}"')
        (repo / "Widget.qml").write_text(widget)
        for args in (("init", "-b", "main"), ("add", "."), ("commit", "-m", "Disposable native lifecycle fixture")):
            run("git", "-C", str(repo), *args, env=env)
        revisions[identity] = run("git", "-C", str(repo), "rev-parse", "HEAD")
    (state / "native-fixtures.json").write_text(json.dumps(revisions))
    # Focused fixture-boundary checks: rejected requests cannot reach native mutation.
    checks = []
    for scenario in ("ready", "native-lifecycle"):
        worker_env = dict(os.environ, OUTFIT_DEMO_ROOT=str(state), OUTFIT_DEMO_SCENARIO=scenario)
        request = {"action": "remove-plugin", "pluginId": IDS[0] if scenario == "ready" else "omarchy.clock", "generation": 1}
        result = json.loads(run(sys.executable, str(ROOT / "demo/fixture_worker.py"), env=worker_env, input=json.dumps(request) + "\n"))
        require(result.get("ok") is False, "Fixture mutation boundary failed")
        checks.append({"scenario": scenario, "blockedMutation": True})
    (output / "guard-checks.json").write_text(json.dumps(checks, indent=2))
    launch(state)
    run("omarchy-shell", "shell", "summon", APP, json.dumps({"workspaceView": "browse", "setupStage": "browse", "selectedId": IDS[0]}))
    wait(lambda: status().get("inputsLoaded") and status().get("inventoryReady"), "fixture service initialization")
    return saved


def restore(saved, config, marker):
    for identity in IDS:
        if identity in lifecycle()["plugins"]:
            run("omarchy", "plugin", "remove", identity, "--yes", timeout=60)
    wait(settled, "fixture cleanup and lease expiration", 65)
    backup = Path(saved["state"]) / "shell.json.backup"
    require(json.loads(config.read_bytes()) == json.loads(backup.read_bytes()), "Config differs beyond fixture cleanup; backup retained")
    if config.read_bytes() != backup.read_bytes():
        config.write_bytes(backup.read_bytes())
    launch()
    run("hyprctl", "eval", "hl.dispatch(hl.dsp.focus({workspace=" + json.dumps(str(saved["workspace"])) + "}))")
    if saved["opened"]:
        run("omarchy-shell", "shell", "summon", APP, "{}")
    wait(settled, "normal shell startup and restored panel settlement", 40)
    cursor = saved["cursor"]
    run("hyprctl", "eval", f'hl.dispatch(hl.dsp.cursor.move({{x={int(cursor["x"])},y={int(cursor["y"])}}}))')
    require(not status()["demo"] and config.read_bytes() == backup.read_bytes(), "Normal shell/config restoration failed")
    current = lifecycle()
    restored_cursor = json.loads(run("hyprctl", "cursorpos", "-j"))
    restoration = {"normalShell": not status()["demo"], "configByteIdentical": config.read_bytes() == backup.read_bytes(),
                   "configBeforeSha256": saved["configSha256"], "configAfterSha256": hashlib.sha256(config.read_bytes()).hexdigest(),
                   "workspaceRestored": json.loads(run("hyprctl", "activeworkspace", "-j"))["id"] == saved["workspace"],
                   "cursorRestored": restored_cursor == saved["cursor"],
                   "fixturesAbsent": not any(identity in current["plugins"] for identity in IDS),
                   "noLease": not current["held"] and current["leaseCount"] == 0, "settled": settled()}
    (Path(saved["output"]) / "restoration.json").write_text(json.dumps(restoration, indent=2))
    require(all(restoration[k] for k in ("normalShell", "configByteIdentical", "workspaceRestored", "cursorRestored", "fixturesAbsent", "noLease", "settled")),
            "Restoration verification failed; recovery marker retained")
    marker.unlink()


def exercise(saved):
    output, state = Path(saved["output"]), Path(saved["state"])
    interactions, samples, observed = [], [], []
    phase = "initial"
    stop = threading.Event()
    def capture(name):
        run("grim", str(output / (name + ".png")))
    def select(identity):
        interactions.append({"type": "programmatic-selection", "method": "standard shell summon payload", "id": identity})
        run("omarchy-shell", "shell", "summon", APP, json.dumps({"workspaceView": "browse", "setupStage": "browse", "selectedId": identity}))
        wait(lambda: status().get("selectedPlugin") == identity and status().get("ready"), "selected fixture ready")
        w = wait(window, "Outfit window")
        env = Path(f'/proc/{w["pid"]}/environ').read_bytes().split(b"\0")
        require(("OUTFIT_DEMO_ROOT=" + str(state)).encode() in env and b"OUTFIT_DEMO_SCENARIO=native-lifecycle" in env,
                "Window environment is not the isolated native fixture")
        run("hyprctl", "eval", "hl.dispatch(hl.dsp.focus({window=" + json.dumps("address:" + w["address"]) + "}))")
        address = json.dumps("address:" + w["address"])
        if not w.get("floating"):
            run("hyprctl", "dispatch", 'hl.dsp.window.float({window=' + address + ',action="toggle"})')
        run("hyprctl", "dispatch", 'hl.dsp.window.resize({window=' + address + ',x=1180,y=760})')
        run("hyprctl", "dispatch", 'hl.dsp.window.center({window=' + address + '})')
        w = wait(lambda: window() if window()["size"] == [1180, 760] else None, "normal production detail geometry", 8)
        time.sleep(0.6)
        return window()
    def click(x, y, label):
        interactions.append({"type": "pointer-click", "label": label, "x": int(x), "y": int(y)})
        run("hyprctl", "eval", f"hl.dispatch(hl.dsp.cursor.move({{x={int(x)},y={int(y)}}}))")
        run("wlrctl", "pointer", "move", "1", "0")
        run("wlrctl", "pointer", "click")
        time.sleep(0.2)
    def key(*keys):
        interactions.append({"type": "keyboard", "keys": list(keys)})
        run("wtype", *sum((["-k", name] for name in keys), []))
        time.sleep(0.2)
    w = select(IDS[0])
    baseline = surfaces()
    def monitor():
        while not stop.is_set():
            try:
                samples.append({"time": time.monotonic(), "phase": phase, **surfaces()})
                current = status()
                observed.append({"time": time.monotonic(), "phase": phase, "status": current})
            except Exception:
                samples.append({"time": time.monotonic(), "phase": phase, "probeError": True})
            stop.wait(0.08)
    thread = threading.Thread(target=monitor, daemon=True)
    thread.start()
    failure = None
    try:
        capture("01-first-inspector")
        for index, identity in enumerate(IDS):
            phase = "select-" + str(index + 1)
            w = select(identity)
            click(w["at"][0] + w["size"][0] - 160, w["at"][1] + 335, "Production detail Add to batch install")
            wait(lambda: status().get("batchSelected") == index + 1, "batch selection count", 8)
        capture("02-two-selected")
        phase = "review"
        click(w["at"][0] + w["size"][0] - 160, w["at"][1] + 296, "Production detail Review batch install")
        capture("03-batch-review")
        click(w["at"][0] + w["size"][0] - 110, w["at"][1] + w["size"][1] - 58, "Install 2 plugins")
        capture("04-batch-confirmation")
        phase = "batch-install"
        click(w["at"][0] + w["size"][0] / 2 + 120,
              w["at"][1] + w["size"][1] / 2 + 50, "Visible Install all confirmation")
        wait(lambda: status().get("batchRunning"), "confirmed batch begins", 8)
        capture("05-batch-progress")
        wait(lambda: not status().get("batchRunning") and len(status().get("batchItems", [])) == 2
             and all(row["status"] == "completed" for row in status()["batchItems"]), "both batch items completed", 75)
        wait(lambda: status()["hostLifecycle"]["runtimeReady"] and status()["hostLifecycle"]["endConfirmed"], "host runtime settlement and end acknowledgement", 35)
        require(surfaces() == baseline, "Surface continuity failed after the batch")
        installed = lifecycle()["plugins"]
        require(all(installed.get(identity, {}).get("enabled") for identity in IDS), "Both fixtures must be installed and enabled")
        (output / "batch-outcome.json").write_text(json.dumps(status(), indent=2))
        capture("06-batch-outcome")
        phase = "uninstall"
        w = select(IDS[0])
        capture("07-installed-inspector")
        # This bar-only fixture has no Open action; the visible Uninstall row is
        # higher than for the declared-panel fixture used by the standalone test.
        click(w["at"][0] + w["size"][0] - 160, w["at"][1] + 430, "Visible production Uninstall button")
        capture("09-uninstall-confirmation")
        key("Right", "Return")  # Uninstall confirmation defaults to Cancel.
        wait(lambda: IDS[0] not in lifecycle()["plugins"], "UI uninstall removes first fixture", 45)
        wait(lambda: status()["hostLifecycle"]["runtimeReady"] and status()["hostLifecycle"]["endConfirmed"], "uninstall runtime settled", 35)
        require(IDS[1] in lifecycle()["plugins"], "Uninstall must retain the second fixture")
        (output / "uninstall-outcome.json").write_text(json.dumps(status(), indent=2))
        require(surfaces() == baseline, "Surface continuity failed after UI uninstall")
        capture("10-uninstall-outcome")
    except Exception as error:
        failure = str(error)
        capture("failure")
    finally:
        stop.set()
        thread.join(timeout=10)
        changed = [s for s in samples if any(s.get(k) != v for k, v in baseline.items())]
        audit = state / "native-audit.jsonl"
        if audit.exists():
            shutil.copyfile(audit, output / audit.name)
        launches = [json.loads(line) for line in audit.read_text().splitlines() if json.loads(line).get("event") == "launch"] if audit.exists() else []
        expected_bin = str(Path(os.environ["OMARCHY_PATH"]) / "bin")
        expected_path = expected_bin + ":/usr/bin:/bin"
        native_launches = [row for row in launches if row["declaredArgv"][0] in ("/usr/bin/omarchy", "/usr/bin/omarchy-shell")]
        adds = [row for row in native_launches if row["effectiveArgv"][1:3] == ["plugin", "add"]]
        removals = [row for row in native_launches if row["effectiveArgv"][1:3] == ["plugin", "remove"]]
        routing_pass = (len(adds) == 2 and len(removals) == 1 and all(
            row["effectiveArgv"][0] == expected_bin + "/" + Path(row["declaredArgv"][0]).name
            and row["effectivePath"] == expected_path for row in native_launches)
            and all(row["effectiveArgv"][0] == row["declaredArgv"][0] for row in launches if row not in native_launches))
        routing = {"ok": routing_pass, "expectedNativeBin": expected_bin, "expectedPath": expected_path,
                   "addLaunches": adds, "removeLaunches": removals,
                   "nativeLaunchCount": len(native_launches), "otherLaunchCount": len(launches) - len(native_launches),
                   "targetedHelperEvidence": {name: [line.strip() for line in (Path(expected_bin) / name).read_text().splitlines()
                                                    if "rescanPlugins" in line or "reconcilePlugins" in line]
                                              for name in ("omarchy-plugin-add", "omarchy-plugin-remove")}}
        (output / "routing-summary.json").write_text(json.dumps(routing, indent=2))
        report = {"functionalPass": failure is None, "failure": failure, "continuityPass": not changed,
                  "routingPass": routing_pass,
                  "baseline": baseline, "samples": len(samples), "discontinuousSamples": len(changed),
                  "probeErrors": sum(bool(row.get("probeError")) for row in samples),
                  "interactions": interactions, "commandBoundary": "Only fixture URLs substituted by test hook; actual executable/PATH selected by production command_launch and observed without modification."}
        (output / "report.json").write_text(json.dumps(report, indent=2))
        (output / "surfaces.json").write_text(json.dumps(samples, indent=2))
        (output / "status-samples.json").write_text(json.dumps(observed, indent=2))
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--restore", action="store_true")
    args = parser.parse_args()
    require((os.environ.get("OUTFIT_TEST_VM") or os.environ.get("OMAFIT_TEST_VM")) == "1" and run("systemd-detect-virt", "--vm") == "kvm", "Disposable VM required")
    require(os.environ.get("OMARCHY_PATH") == "/home/tester/omarchy-host", "Use session_exec.py and canonical VM host")
    require(subprocess.run(["omarchy-hyprland-session-locked"], stdout=subprocess.DEVNULL).returncode != 0, "Unlock VM before testing")
    config = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "omarchy/shell.json"
    marker = Path(os.environ["XDG_RUNTIME_DIR"]) / "omafit-mutation-recovery.json"
    saved = None
    prepared = False
    def interrupted(*_args):
        raise RuntimeError("VM mutation test interrupted")
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupted)
    try:
        if args.restore or args.resume:
            require(marker.is_file() and not marker.is_symlink(), "Recovery marker missing")
            saved = json.loads(marker.read_text())
        else:
            require(args.output and not args.output.exists() and args.output.parent.is_dir(), "New output directory required")
            saved = prepare(config, marker, args.output.resolve())
        if args.restore:
            return 0
        if args.prepare_only:
            prepared = True
            print(json.dumps({"prepared": True, "state": saved["state"], "output": saved["output"]}))
            return 0
        report = exercise(saved)
        print(json.dumps(report))
        return 0 if report["functionalPass"] and report["continuityPass"] and report["routingPass"] else 1
    finally:
        if not prepared:
            if saved is None and marker.is_file():
                saved = json.loads(marker.read_text())
            if saved:
                restore(saved, config, marker)
                print("Normal shell, original workspace/cursor/config restored; both fixture plugins absent.")


if __name__ == "__main__":
    raise SystemExit(main())
