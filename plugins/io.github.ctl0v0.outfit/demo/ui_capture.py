#!/usr/bin/env python3
"""Capture the real hosted UI with fictional data, only in a disposable VM."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import struct
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
ID = "io.github.ctl0v0.outfit"
VIEWS = ["comfortable", "compact", "dense", "list"]
DETAIL_STATES = ["available", "installed", "disabled", "service", "pending", "failed", "manual", "replacement", "long", "missing"]
parser = argparse.ArgumentParser()
parser.add_argument("--output", type=Path)
parser.add_argument("--scenario", choices=["ready", "empty", "offline", "slow", "failed-inventory", "installed", "disabled", "cards", "density", "interests", "matches", "preview", "details"], default="ready")
parser.add_argument("--detail-state", choices=DETAIL_STATES, help="Fictional details prototype state (details only; default: available)")
parser.add_argument("--detail-interactions", action="store_true", help="Capture pointer/keyboard demo-only flows for installed, disabled, or pending details")
parser.add_argument("--verify-interests", action="store_true", help="Verify the fictional multi-select picker, draft navigation, and a single Save changes")
parser.add_argument("--verify-save-footer", action="store_true", help="Capture dirty normal/compact and saved normal footers using one real Save")
parser.add_argument("--verify-search-scroll", action="store_true", help="One fictional cards session for real search/sort and detail keyboard scrolling")
parser.add_argument("--verify-markdown", action="store_true", help="Verify the production README cache/parser and capture expanded documentation (cards with --plugin)")
parser.add_argument("--check-metrics", choices=["card", "detail", "gutter"],
                    help="Capture fictional production metric help or scrollbar-gutter interactions")
parser.add_argument("--verify-navigation", choices=["preview", "browse", "tooltips", "card-help"],
                    help="Exercise production preview/Backspace/Escape or Browse keyboard zones with fictional data")
parser.add_argument("--interactive", action="store_true", help="Keep the fictional details preview open until Outfit is closed (VM only)")
parser.add_argument("--interactive-timeout", type=int, default=None, metavar="SECONDS",
                    help="Interactive preview lifetime, 60–7200 seconds (default: 7200)")
parser.add_argument("--density", choices=VIEWS)
parser.add_argument("--sort", choices=["recommended", "fit", "stars", "added", "activity", "views", "copies"], default="fit")
parser.add_argument("--no-thumbnails", action="store_true", help="Exercise text-only rows in isolated fixture preferences")
parser.add_argument("--recent-listings", action="store_true",
                    help="Temporarily timestamp fictional Dock Helper/Quiet Hours listings one hour ago; restore fixture bytes")
parser.add_argument("--grouping", choices=["none", "category"], default="none")
parser.add_argument("--verify-density-restart", action="store_true")
parser.add_argument("--remove-saved", action="store_true", help="Verify removing a saved fixture while the new-interest editor is open")
parser.add_argument("--view", choices=["discover", "browse"], help="Optional view override; otherwise use the app default")
parser.add_argument("--plugin", default="", help="Optional fictional fixture ID to open in the inspector")
parser.add_argument("--narrow", action="store_true", help="Use 760-pixel width (details: 760x540; other scenarios: 760x620)")
parser.add_argument("--window-size", metavar="WIDTHxHEIGHT", help="Explicit VM window size in logical pixels (minimum 760x540)")
parser.add_argument("--shell-font-size", type=int, choices=range(12, 21), metavar="12..20",
                    help="Temporarily override the disposable VM shell font base size; restore original bytes afterward")
parser.add_argument("--surface", choices=["main", "actions", "settings", "collapsed", "expanded", "inputs", "saved", "picker", "new-interest", "matches"], default="main")
parser.add_argument("--restore", action="store_true", help="Restore after an interrupted demo using its recovery marker")
args = parser.parse_args()
if args.verify_search_scroll and (args.scenario != "cards" or args.surface != "main" or args.narrow
        or args.window_size or args.plugin or args.density or args.verify_navigation or args.verify_markdown):
    parser.error("--verify-search-scroll requires normal cards/main without other interaction modes")
if args.verify_save_footer and (args.scenario != "interests" or args.surface != "picker"
                               or args.narrow or args.window_size or args.verify_interests):
    parser.error("--verify-save-footer requires the normal interests/picker fixture")
if args.verify_markdown and (args.scenario != "cards" or not args.plugin or args.narrow
                            or args.window_size or args.surface != "main"):
    parser.error("--verify-markdown requires normal-size cards with --plugin")
if args.recent_listings and args.scenario not in {"cards", "density", "ready"}:
    parser.error("--recent-listings supports only the ordinary read-only catalog fixtures")
if args.window_size:
    try:
        requested_size = tuple(int(part) for part in args.window_size.lower().split("x"))
        if len(requested_size) != 2 or not (760 <= requested_size[0] <= 3840 and 540 <= requested_size[1] <= 2160):
            raise ValueError()
    except ValueError:
        parser.error("--window-size requires WIDTHxHEIGHT within 760x540..3840x2160 logical pixels")
    if args.narrow or args.detail_interactions or args.verify_interests or args.interactive:
        parser.error("--window-size cannot combine with fixed-geometry interactions, --narrow, or --interactive")
else:
    requested_size = None
if args.surface == "new-interest":
    # The redesigned manager has no separate new-interest editor. Keep the
    # former capture spelling as an alias for its always-open Added picker.
    args.surface = "picker"
if args.remove_saved:
    args.verify_interests = True
    args.remove_saved = False
if args.verify_interests and (args.scenario != "interests" or args.surface != "picker" or args.narrow):
    parser.error("--verify-interests requires the normal-size interests/picker fixture")
interests_capture = args.scenario == "interests" and args.surface in {"inputs", "saved", "picker"}
tracked_capture = args.scenario == "details" or interests_capture or bool(args.density or args.plugin or args.check_metrics or requested_size or args.verify_navigation or args.recent_listings or args.verify_search_scroll)
if args.verify_navigation and (args.scenario not in {"cards", "density"} or args.surface != "main"
                              or args.narrow or requested_size or args.check_metrics or args.detail_interactions
                              or (args.verify_navigation == "preview") != bool(args.plugin)):
    parser.error("Navigation checks use a normal-size fictional production main view; preview requires --plugin, browse does not")
if args.verify_navigation == "tooltips" and (args.density != "comfortable" or args.sort != "stars" or args.grouping != "none" or args.shell_font_size):
    parser.error("Tooltip checks require comfortable ungrouped Browse sorted by stars at the default font")
if args.verify_navigation == "card-help" and (args.scenario != "cards" or args.density != "comfortable" or args.sort != "stars" or not args.recent_listings or args.no_thumbnails):
    parser.error("Card help checks require comfortable cards sorted by stars with --recent-listings and thumbnails")
if args.check_metrics and (args.scenario not in {"cards", "density", "ready"} or args.surface != "main"
                          or (args.check_metrics == "detail") != bool(args.plugin)):
    parser.error("Metric checks require a fictional production main view; only detail checks take --plugin")
if args.interactive and (args.scenario != "details" or args.detail_interactions or args.restore):
    parser.error("--interactive requires --scenario details and cannot run capture interactions or --restore")
if args.interactive_timeout is not None and not args.interactive:
    parser.error("--interactive-timeout requires --interactive")
if args.interactive and not 60 <= (args.interactive_timeout if args.interactive_timeout is not None else 7200) <= 7200:
    parser.error("--interactive-timeout must be between 60 and 7200 seconds")
if args.detail_state and args.scenario != "details":
    parser.error("--detail-state requires --scenario details")
if args.detail_interactions and (args.scenario != "details" or args.detail_state not in {"installed", "disabled", "pending"}):
    parser.error("--detail-interactions requires details with installed, disabled, or pending state")
if args.scenario == "details":
    args.detail_state = args.detail_state or "available"
    if (args.surface != "main" or args.density or args.plugin or args.verify_density_restart
            or args.remove_saved or args.view == "discover"):
        parser.error("Details capture uses only its fictional full-page state; omit inspector, density, and other surface options")
if args.remove_saved and (args.surface != "new-interest" or args.scenario != "interests" or args.narrow):
    parser.error("--remove-saved requires the stock-width interests/new-interest fixture")
if args.density and (args.view == "discover" or args.surface in {"actions", "settings", "inputs", "saved", "picker", "new-interest", "matches"}):
    parser.error("Browse view interaction requires Browse with the main/expanded/collapsed surface")
def run(*command, check=True):
    return subprocess.run(command, check=check, capture_output=True, text=True, timeout=20).stdout.strip()

def wait_for_detail_close(timeout, query, clock=time.monotonic, sleep=time.sleep):
    """Observe the existing service; resizing/Back/popup dismissal are not exit.

    Two consecutive closed observations avoid ending on a transient false value.
    Broken IPC is bounded too; recovery retains its marker if it cannot finish.
    """
    deadline = clock() + timeout
    closed_samples = 0
    unavailable_since = None
    while clock() < deadline:
        try:
            current = query()
            if not isinstance(current, dict) or type(current.get("demo")) is not bool or type(current.get("opened")) is not bool:
                raise ValueError("Incomplete fixture status")
            unavailable_since = None
            if current["demo"] is False:
                return "fixture-ended"
            closed_samples = closed_samples + 1 if current["opened"] is False else 0
            if closed_samples >= 2:
                return "user-closed"
        except (OSError, ValueError, subprocess.SubprocessError):
            closed_samples = 0
            if unavailable_since is None:
                unavailable_since = clock()
            if clock() - unavailable_since >= 30:
                return "status-unavailable"
        sleep(min(0.5, max(0, deadline - clock())))
    return "timeout"

if (os.environ.get("OUTFIT_TEST_VM") or os.environ.get("OMAFIT_TEST_VM")) != "1" or subprocess.run(
        ["systemd-detect-virt", "--vm"], stdout=subprocess.DEVNULL).returncode:
    raise SystemExit("This capture harness requires the disposable VM and OUTFIT_TEST_VM=1.")
if tracked_capture and (ROOT != Path("/home/tester/omafit")
        or os.environ.get("OMARCHY_PATH") != "/home/tester/omarchy-host"):
    raise SystemExit("Details captures require the density-pass VM candidate and session_exec.py runtime.")
for tool in ("omarchy", "omarchy-shell", "hyprctl", "quickshell", "grim", "omarchy-hyprland-session-locked"):
    if not shutil.which(tool): raise SystemExit(f"Missing prerequisite: {tool}")
if (args.surface != "main" or args.density or args.detail_interactions or args.check_metrics or args.verify_navigation or args.verify_markdown or args.verify_search_scroll) and not shutil.which("wlrctl"):
    raise SystemExit("wlrctl is required for fixture toolbar interaction")
if (args.detail_interactions or args.verify_interests or interests_capture or args.check_metrics or args.verify_navigation or args.verify_search_scroll) and not shutil.which("wtype"):
    raise SystemExit("wtype is required for detail keyboard interaction")
if args.verify_navigation == "tooltips" and not shutil.which("foot"):
    raise SystemExit("foot is required for the temporary VM tooltip focus probe")
if subprocess.run(["omarchy-hyprland-session-locked"], stdout=subprocess.DEVNULL).returncode == 0:
    raise SystemExit("Unlock the session before capture or restoration.")
runtime = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp"))
marker = runtime / f"omafit-demo-recovery-{os.getuid()}.json"
config = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "omarchy/shell.json"

def restore(saved):
    run("omarchy-shell", "shell", "hide", ID, check=False)
    if saved.get("fixtureOverride"):
        fixture_path = config.parent / "plugins" / ID / "demo/fixtures/example.json"
        current_hash = hashlib.sha256(fixture_path.read_bytes()).hexdigest()
        if current_hash not in {saved["fixtureOverride"]["originalSha256"], saved["fixtureOverride"]["captureSha256"]}:
            raise RuntimeError("Fictional fixture changed unexpectedly; recovery backup retained")
        fixture_path.write_bytes((Path(saved["state"]) / "example.json.backup").read_bytes())
    if saved.get("fontOverride"):
        font_path = config.with_suffix(".toml")
        if saved["fontOverride"]["existed"]:
            font_path.write_bytes((Path(saved["state"]) / "shell.toml.backup").read_bytes())
        else:
            font_path.unlink(missing_ok=True)
    run("omarchy", "restart", "shell")
    normal = None
    if saved.get("evidencePath"):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            try:
                normal = json.loads(run("omarchy-shell", ID, "status", check=False))
            except ValueError:
                normal = None
            if normal is not None and normal.get("demo") is False:
                break
            time.sleep(0.15)
        else:
            raise RuntimeError("Normal shell did not return after details capture; recovery marker retained")
        # Service IPC can answer while other shell components are still being
        # incubated. Do not immediately resize/restart that new engine in the
        # next capture. Older hosts without lifecycle IPC retain the old path.
        deadline = time.monotonic() + 30
        settled_samples = 0
        while time.monotonic() < deadline:
            try:
                lifecycle_status = json.loads(run("omarchy-shell", "shell", "pluginLifecycle", check=False))
            except ValueError:
                break
            if lifecycle_status.get("version") != 1:
                break
            pending = any(lifecycle_status.get(k) for k in ("pending", "held", "scanning", "reconciling"))
            settled_samples = settled_samples + 1 if not pending and not lifecycle_status.get("scanError") else 0
            if settled_samples >= 2:
                break
            time.sleep(0.2)
        else:
            raise RuntimeError("Normal host did not settle after capture; recovery marker retained")
    run("hyprctl", "eval", "hl.dispatch(hl.dsp.focus({workspace=" + json.dumps(str(saved["workspace"])) + "}))")
    if saved.get("evidencePath") and saved.get("opened"):
        run("omarchy-shell", "shell", "summon", ID, "{}")
    run("hyprctl", "eval", f'hl.dispatch(hl.dsp.cursor.move({{x={int(saved["cursor"]["x"])},y={int(saved["cursor"]["y"])}}}))')
    if config.read_bytes() != (Path(saved["state"]) / "shell.json.backup").read_bytes():
        raise RuntimeError("Shell configuration changed during capture; recovery backup retained for inspection")
    if saved.get("evidencePath"):
        checks = {"normalShell": normal.get("demo") is False,
                  "configByteIdentical": True,
                  "runtimeUnchanged": os.environ.get("OMARCHY_PATH") == saved["omarchyPath"],
                  "workspaceRestored": json.loads(run("hyprctl", "activeworkspace", "-j"))["id"] == saved["workspace"],
                  "cursorRestored": json.loads(run("hyprctl", "cursorpos", "-j")) == saved["cursor"]}
        if saved.get("fontOverride"):
            font_path = config.with_suffix(".toml")
            checks["fontConfigRestored"] = (font_path.read_bytes() == (Path(saved["state"]) / "shell.toml.backup").read_bytes()
                if saved["fontOverride"]["existed"] else not font_path.exists())
        if saved.get("fixtureOverride"):
            fixture_path = config.parent / "plugins" / ID / "demo/fixtures/example.json"
            checks["fixtureRestored"] = hashlib.sha256(fixture_path.read_bytes()).hexdigest() == saved["fixtureOverride"]["originalSha256"]
        evidence_path = Path(saved["evidencePath"])
        if evidence_path.is_file():
            evidence = json.loads(evidence_path.read_text())
            evidence["restoration"] = {**checks, "configSha256": hashlib.sha256(config.read_bytes()).hexdigest()}
            evidence_path.write_text(json.dumps(evidence, indent=2))
        if not all(checks.values()):
            raise RuntimeError("Details capture restoration check failed; recovery marker retained")
    marker.unlink()
    print("Normal shell, workspace and cursor restored. Fixture evidence retained:", saved["state"])

if args.restore:
    if not marker.is_file() or marker.is_symlink(): raise SystemExit("No unambiguous recovery marker")
    restore(json.loads(marker.read_text()))
    raise SystemExit(0)
if marker.exists(): raise SystemExit(f"Stale recovery marker: {marker}. Inspect it and use --restore first.")
for other in ("omafit-mutation-recovery.json", "omafit-uninstall-recovery.json"):
    if (runtime / other).exists():
        raise SystemExit("Another VM harness requires recovery first: " + str(runtime / other))
if not args.output or args.output.exists() or not args.output.parent.is_dir():
    raise SystemExit("--output must name a new image in an existing directory")
detail_evidence = args.output.with_suffix(".json") if tracked_capture else None
if detail_evidence and (detail_evidence == args.output or detail_evidence.exists()):
    raise SystemExit("Choose a new screenshot path with an unused .json evidence sidecar")
plugin = config.parent / "plugins" / ID
if not config.is_file():
    raise SystemExit("The normal shell configuration is missing")
required_files = ["manifest.json", "Service.qml", "scripts/outfit.py", "ui/OutfitApp.qml", "demo/fixture_worker.py", "demo/fixtures/example.json", "demo/fixtures/README.md"]
if tracked_capture:
    required_files += ["ui/ContentScrollView.qml", "ui/Presentation.js", "ui/PluginDetailPage.qml", "ui/Navigation.js"]
    required_files += [str(path.relative_to(ROOT)) for path in sorted((ROOT / "ui").iterdir())
                       if path.suffix in {".qml", ".js"}]
if args.scenario == "details":
    required_files += ["ui/PluginDetailPage.qml", "demo/DetailPrototype.qml", "demo/details-fixtures.js",
                       "demo/assets/detail-dockside-overview.svg", "demo/assets/detail-dockside-workspaces.svg",
                        "demo/assets/detail-dockside-focus.svg"]
if interests_capture:
    required_files += ["ui/InterestsManager.qml", "data/services.json"]
validated_hashes = {}
if args.verify_search_scroll:
    required_files.append("demo/search_scroll_checks.py")
for relative in required_files:
    source, installed = ROOT / relative, plugin / relative
    if not source.is_file() or not installed.is_file() or hashlib.sha256(source.read_bytes()).digest() != hashlib.sha256(installed.read_bytes()).digest():
        raise SystemExit("Install/update this exact candidate in the VM before capturing: " + relative)
    validated_hashes[relative] = hashlib.sha256(source.read_bytes()).hexdigest()
monitors = json.loads(run("hyprctl", "monitors", "-j"))
if any(m.get("transform", 0) != 0 for m in monitors): raise SystemExit("Use untransformed VM monitors")
state = Path(tempfile.mkdtemp(prefix="omafit-demo-", dir=runtime))
shutil.copyfile(config, state / "shell.json.backup")
os.chmod(state / "shell.json.backup", 0o600)
saved = {"state": str(state), "workspace": json.loads(run("hyprctl", "activeworkspace", "-j"))["id"],
          "cursor": json.loads(run("hyprctl", "cursorpos", "-j"))}
recent_fixture_bytes = None
if args.recent_listings:
    fixture_path = plugin / "demo/fixtures/example.json"
    original = fixture_path.read_bytes()
    (state / "example.json.backup").write_bytes(original)
    fictional = json.loads(original)
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 3600))
    changed_ids = []
    for row in fictional["catalog"]["plugins"]:
        if row["id"] in {"example.dock-helper", "example.quiet-hours"}:
            row["listedAt"] = stamp
            changed_ids.append(row["id"])
    recent_fixture_bytes = (json.dumps(fictional, indent=2) + "\n").encode()
    saved["fixtureOverride"] = {"path": "demo/fixtures/example.json", "fictionalOnly": True,
        "listedAt": stamp, "ids": changed_ids,
        "originalSha256": hashlib.sha256(original).hexdigest(),
        "captureSha256": hashlib.sha256(recent_fixture_bytes).hexdigest()}
if args.shell_font_size:
    font_path = config.with_suffix(".toml")
    if font_path.is_symlink():
        raise SystemExit("Refusing to replace a symlinked shell font configuration")
    if font_path.exists():
        shutil.copyfile(font_path, state / "shell.toml.backup")
    saved["fontOverride"] = {"existed": font_path.exists(), "baseSize": args.shell_font_size}
if tracked_capture:
    original_status = json.loads(run("omarchy-shell", ID, "status"))
    if original_status.get("demo"):
        raise SystemExit("A fixture shell is already running; restore it before a new details capture")
    if args.interactive:
        if original_status.get("interestsDirty") or original_status.get("batchRunning"):
            raise SystemExit("Finish the current VM draft/batch before opening an interactive preview")
        real_inventory = json.loads(run("omarchy-shell", "shell", "listPlugins"))
        if any(str(row.get("id", "")).startswith("org.example.") for row in real_inventory):
            raise SystemExit("Remove existing native fictional fixtures before the interactive design preview")
    saved.update(scenario=args.scenario, opened=original_status.get("opened", False),
                  omarchyPath=os.environ["OMARCHY_PATH"], evidencePath=str(detail_evidence.resolve()))
    if args.interactive:
        saved.update(interactive=True, harnessPid=os.getpid(), interactiveTimeout=args.interactive_timeout or 7200)
with marker.open("x") as stream: json.dump(saved, stream)
os.chmod(marker, 0o600)
interactive_exit = "interrupted-before-ready"
def interrupted(_signal, _frame):
    global interactive_exit
    interactive_exit = "signal-" + signal.Signals(_signal).name
    raise SystemExit("Capture interrupted")
for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP): signal.signal(sig, interrupted)

def exercise_details(window):
    # Only enter after the VM, source hashes, scenario and process environment
    # were verified. No host call/summon is used for simulated page operations.
    x, y = window["at"]
    width, height = window["size"]
    compact = args.narrow
    steps = []
    def inventory_state():
        rows = json.loads(run("omarchy-shell", "shell", "listPlugins"))
        return sorted((row["id"], row.get("enabled"), row.get("active")) for row in rows)
    before = inventory_state()
    if any(identity.startswith("org.example.") for identity, _enabled, _active in before):
        raise RuntimeError("Detail interactions require no installed fictional fixture plugins")
    def snapshot(label):
        path = args.output.with_name(args.output.stem + "--" + label + ".png")
        if path.exists(): raise RuntimeError("Refusing to overwrite interaction evidence: " + str(path))
        run("grim", "-g", f"{x},{y} {width}x{height}", str(path))
        steps.append({"capture": label, "image": str(path)})
    def click(px, py, label):
        run("hyprctl", "eval", f"hl.dispatch(hl.dsp.cursor.move({{x={int(x + px)},y={int(y + py)}}}))")
        run("wlrctl", "pointer", "move", "1", "0")
        run("wlrctl", "pointer", "click")
        steps.append({"pointer": label, "relativePosition": [px, py]})
        time.sleep(0.2)
    def keys(*names):
        run("wtype", *sum((["-k", name] for name in names), []))
        steps.append({"keyboard": list(names)})
        time.sleep(0.2)
    if args.detail_state == "installed":
        if compact:
            raise RuntimeError("Installed interaction coordinates are for the normal-size fixture; use normal for this flow")
        click(width - 160, 296, "simulated Open")
        snapshot("open-popup")
        keys("Escape")
        snapshot("open-dismissed")
        click(75, 685, "Open full size")
        snapshot("full-size")
        keys("Escape")
        snapshot("full-size-escape")
        click(width - 160, 461, "simulated Uninstall")
        snapshot("uninstall-cancel-default")
        keys("Return")
        snapshot("uninstall-cancelled")
        click(width - 160, 461, "simulated Uninstall again")
        keys("Tab", "Return")
        snapshot("uninstall-pending")
        time.sleep(1.8)
        snapshot("uninstall-complete-detail-retained")
        click(80, 105, "Back to Browse")
        snapshot("back-browse")
        click(410, 280, "fictional Browse card")
        snapshot("card-reopened-prototype")
    elif args.detail_state == "disabled":
        click(239 if compact else width - 230, height - 47 if compact else 410, "position Left while disabled")
        snapshot("left-still-disabled")
        click(313 if compact else width - 145, height - 67 if compact else 410, "position Center while disabled")
        snapshot("center-still-disabled")
    else:
        click(width - 88 if compact else width - 160, height - 120 if compact else 296, "pending primary disabled")
        click(139 if compact else width - 155, height - 77 if compact else 345, "pending toggle disabled")
        click(383 if compact else width - 145, height - 63 if compact else 410, "pending position disabled")
        time.sleep(1.8)
        snapshot("pending-still-held")
    after = inventory_state()
    native_status = json.loads(run("omarchy-shell", ID, "status"))
    clients = json.loads(run("hyprctl", "clients", "-j"))
    intact = any(row.get("address") == window["address"] and row.get("pid") == window["pid"]
                 and row.get("title") == "Outfit - Plugin Manager" and row.get("mapped") for row in clients)
    if before != after or not intact or not native_status.get("demo") or not native_status.get("opened"):
        raise RuntimeError("Prototype interaction changed native inventory or closed/replaced the app")
    return {"steps": steps, "nativeInventoryUnchanged": True, "noFictionalPluginInstalled": True,
            "sameWindowAndPid": True, "verification": "Pointer/keyboard execution and native-state invariants; inspect attached images for simulated-state outcomes."}

def exercise_save_footer(window):
    """Small visual check of the production footer; isolated fictional criteria."""
    document_path = state / "config" / ID / "interests.json"
    original = document_path.read_bytes()
    revision = json.loads(original)["revision"]
    before = json.loads(run("omarchy-shell", "shell", "listPlugins"))
    address = json.dumps("address:" + window["address"])
    def current():
        return json.loads(run("omarchy-shell", ID, "status"))
    def wait_for(predicate, message):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if predicate(): return
            time.sleep(0.1)
        raise RuntimeError("Save footer: " + message)
    def click(px, py):
        x, y = window["at"]
        run("hyprctl", "eval", f"hl.dispatch(hl.dsp.cursor.move({{x={x+px},y={y+py}}}))")
        run("wlrctl", "pointer", "move", "1", "0")
        run("wlrctl", "pointer", "click")
    def capture(path):
        x, y = window["at"]
        width, height = window["size"]
        run("hyprctl", "eval", f"hl.dispatch(hl.dsp.cursor.move({{x={x+width//2},y={y+70}}}))")
        run("wlrctl", "pointer", "move", "1", "0")
        time.sleep(0.2)
        run("grim", "-g", f"{x},{y} {width}x{height}", str(path))
    def resize(width, height):
        nonlocal window
        run("hyprctl", "dispatch", 'hl.dsp.window.resize({window=' + address + f',x={width},y={height}' + '})')
        run("hyprctl", "dispatch", 'hl.dsp.window.center({window=' + address + '})')
        time.sleep(0.4)
        window = next(row for row in json.loads(run("hyprctl", "clients", "-j")) if row["address"] == window["address"])
        if window["size"] != [width, height]: raise RuntimeError("Footer resize failed")
    click(292, 412)  # YouTube Music; no direct draft mutation.
    wait_for(lambda: current()["interestsDirty"], "selection did not dirty draft")
    if document_path.read_bytes() != original: raise RuntimeError("Footer selection saved prematurely")
    capture(args.output)
    compact = args.output.with_name(args.output.stem + "--compact-dirty.png")
    saved_image = args.output.with_name(args.output.stem + "--saved.png")
    if compact.exists() or saved_image.exists(): raise RuntimeError("Refusing footer evidence overwrite")
    resize(760, 540)
    capture(compact)
    resize(1180, 760)
    click(1095, 720)  # Right-aligned Save changes in the new fixed footer.
    wait_for(lambda: current()["criteriaRevision"] == revision + 1 and not current()["interestsDirty"], "real Save click did not persist")
    saved = json.loads(document_path.read_text())
    if len(saved["criteria"]) != 3 or not any(row.get("serviceId") == "youtube-music" for row in saved["criteria"]):
        raise RuntimeError("Save footer persisted unexpected criteria")
    capture(saved_image)
    audit = [json.loads(line) for line in (state / "interests-actions.jsonl").read_text().splitlines()]
    if sum(row["action"] == "save-interests" for row in audit) != 1:
        raise RuntimeError("Expected exactly one Save request")
    if json.loads(run("omarchy-shell", "shell", "listPlugins")) != before:
        raise RuntimeError("Footer check changed native plugin inventory")
    return {"pass": True, "singleSaveRequests": 1, "revisionBefore": revision,
        "revisionAfter": saved["revision"], "draftNotSavedBeforeClick": True,
        "nativeInventoryUnchanged": True, "images": [str(args.output), str(compact), str(saved_image)],
        "savePointer": [1095, 720], "savedCriteria": saved["criteria"],
        "visualVerdict": "Inspect the three frames for contrast and clipping"}

def exercise_interests(window):
    """Current normal-size fictional picker; all draft changes use real controls."""
    x, y = window["at"]
    width, height = window["size"]
    document_path = state / "config" / ID / "interests.json"
    original_bytes = document_path.read_bytes()
    original = json.loads(original_bytes)
    steps = []
    inventory_before = json.loads(run("omarchy-shell", "shell", "listPlugins"))
    def current():
        return json.loads(run("omarchy-shell", ID, "status"))
    def wait_for(predicate, description):
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            if predicate(): return
            time.sleep(0.1)
        raise RuntimeError("Interests verification: " + description)
    def snapshot(label):
        path = args.output.with_name(args.output.stem + "--" + label + ".png")
        if path.exists(): raise RuntimeError("Refusing to overwrite interests evidence")
        run("grim", "-g", f"{x},{y} {width}x{height}", str(path))
        steps.append({"capture": label, "path": str(path)})
    def click(px, py, label):
        run("hyprctl", "eval", f"hl.dispatch(hl.dsp.cursor.move({{x={int(x+px)},y={int(y+py)}}}))")
        run("wlrctl", "pointer", "move", "1", "0")
        run("wlrctl", "pointer", "click")
        steps.append({"click": label, "relativePosition": [px, py]})
        time.sleep(0.25)
    def tab(number):
        run("wtype", "-M", "alt", "-k", str(number), "-m", "alt")
        steps.append({"keyboard": "Alt+" + str(number)})
        time.sleep(0.2)
    def search(text):
        click(830, 216, "Picker search")
        run("wtype", "-M", "ctrl", "a", "-m", "ctrl", "-k", "BackSpace", text)
        steps.append({"search": text})
        time.sleep(0.25)
    try:
        # No selector helper invokes the service's draft mutation methods.
        click(292, 412, "YouTube Music from Music & video category")
        wait_for(lambda: current()["interestsDirty"], "category selection did not dirty the draft")
        click(426, 286, "Remove saved Spotify chip")
        search("GitHub")
        click(106, 408, "Select GitHub from Development & AI")
        search("Slack")
        click(106, 408, "Select Slack from Chat & meetings")
        search("")
        click(602, 286, "Pause GitHub chip")
        search("Workspace research")
        click(880, 256, "Add custom Workspace research")
        search("MIDI")
        click(880, 256, "Add custom MIDI")
        search("Temporary topic")
        click(880, 256, "Add temporary chip for horizontal removal")
        click(830, 216, "Search anchors chip keyboard traversal")
        run("wtype", *(["-k", "Tab"] * 14), "-k", "Return")
        steps.append({"keyboard": "14 Tabs then Return: reveal and remove last temporary chip"})
        time.sleep(0.3)
        run("grim", "-g", f"{x},{y} {width}x{height}", str(args.output))
        steps.append({"capture": "horizontal-chips-draft", "path": str(args.output)})
        tab(1)
        tab(2)
        if document_path.read_bytes() != original_bytes:
            raise RuntimeError("Draft changes unexpectedly persisted before Save")
        click(40, 105, "Back preserves draft")
        if not current()["interestsDirty"]:
            raise RuntimeError("Back discarded unsaved picker draft")
        # Public page navigation only; no selection, save, or service mutation.
        run("omarchy-shell", "shell", "call", ID, "openInterests", "")
        steps.append({"navigation": "public panel openInterests; no draft mutation"})
        time.sleep(0.3)
        tab(2)
        if not current()["interestsDirty"] or document_path.read_bytes() != original_bytes:
            raise RuntimeError("Reopening manager failed to retain the unsaved draft")
        click(width - 85, height - 40, "Single Save changes")
        wait_for(lambda: current()["criteriaRevision"] > original["revision"] and not current()["interestsDirty"], "Save did not persist")
        saved_bytes = document_path.read_bytes()
        saved_document = json.loads(saved_bytes)
        services = {row.get("serviceId") for row in saved_document["criteria"] if row.get("serviceId")}
        expected = {"youtube-music", "github", "slack"}
        criteria = saved_document["criteria"]
        if services != expected or len(criteria) != 6 or not all(any(row["label"] == label and row["terms"] == [term] for row in criteria)
                for label, term in [("Workspace research", "workspace research"), ("MIDI", "midi")]):
            raise RuntimeError("Persisted multi-select/custom/removal criteria differ: " + json.dumps(saved_document))
        if not any(row.get("serviceId") == "github" and row["enabled"] is False for row in criteria):
            raise RuntimeError("GitHub chip pause was not persisted")
        if not any(row["kind"] == "hardware" and row["label"] == "Dock accessories" and row["enabled"] for row in criteria):
            raise RuntimeError("Saved hardware interest was lost")
        if saved_document["revision"] != original["revision"] + 1:
            raise RuntimeError("Expected exactly one persisted revision")
        # No pointer focus repair: successful Save must leave Alt+1/Alt+2 usable
        # immediately after its button becomes disabled.
        tab(1)
        tab(2)
        search("Discarded topic")
        click(880, 256, "Unsaved custom topic before Discard")
        wait_for(lambda: current()["interestsDirty"], "test toggle did not dirty draft")
        click(width - 191, height - 40, "Discard unsaved change")
        wait_for(lambda: not current()["interestsDirty"], "Discard did not clear draft")
        if document_path.read_bytes() != saved_bytes:
            raise RuntimeError("Discard changed persisted criteria")
        click(40, 105, "Back after removing saved Spotify")
        click(100, 159, "Browse all clears prior Spotify filter")
        wait_for(lambda: current()["ready"] and current()["results"] == 3, "Browse all did not return three fictional rows")
        # Sidebar sequence: Browse all, Dock accessories, YouTube Music, Slack,
        # Workspace research, MIDI. Paused GitHub is intentionally absent.
        click(100, 345, "MIDI sidebar shortcut")
        wait_for(lambda: current()["ready"] and current()["results"] == 1, "MIDI filter did not return one exact match")
        snapshot("midi-sidebar-filter")
        audit = [json.loads(line) for line in (state / "interests-actions.jsonl").read_text().splitlines()]
        saves = [row for row in audit if row["action"] == "save-interests"]
        queries = [row for row in audit if row["action"] == "quick-setup"]
        if len(saves) != 1 or any(row["action"] == "preview-interest" for row in audit):
            raise RuntimeError("Picker did not use exactly one save without preview requests")
        responses = [json.loads(line) for line in (state / "interests-results.jsonl").read_text().splitlines()]
        latest = responses[-1]["setup"]
        midi = next(row for row in latest["services"] if row["name"] == "MIDI")
        hardware = next(row for row in latest["services"] if row["name"] == "Dock accessories")
        if (queries[-1].get("setupServices") != [midi["id"]] or not midi["id"].startswith("interest-")
                or midi["total"] != 1 or hardware["total"] != 1
                or [row["id"] for row in latest["rows"]] != ["example.dock-helper"]):
            raise RuntimeError("Semantic MIDI/hardware sidebar counts or exact filter rows differ: " + json.dumps(latest))
        if json.loads(run("omarchy-shell", "shell", "listPlugins")) != inventory_before:
            raise RuntimeError("Fictional interests verification changed native plugin inventory")
        report = {"pass": True, "steps": steps, "curatedServices": sorted(services), "customTopics": ["Workspace research", "MIDI"],
                  "singleSaveRequests": len(saves), "previewRequests": 0, "revisionBefore": original["revision"],
                  "revisionAfter": saved_document["revision"], "draftPreservedAcrossBackAndTabs": True,
                   "discardPreservedSavedDocument": True, "pausedGitHubPersisted": True,
                   "midiFilter": midi, "hardwareFilter": hardware, "filteredRows": [row["id"] for row in latest["rows"]],
                  "nativeInventoryUnchanged": True, "savedCriteria": saved_document}
        args.output.with_suffix(".verification.json").write_text(json.dumps(report, indent=2))
        args.output.with_suffix(".actions.json").write_text(json.dumps(audit, indent=2))
        return report
    except Exception as error:
        snapshot("verification-failure")
        args.output.with_suffix(".verification.json").write_text(json.dumps({"pass": False, "error": str(error), "steps": steps}, indent=2))
        raise

def exercise_metrics(window):
    """Record real hover/Tab help and gutter behavior; no native mutations."""
    x, y = window["at"]
    width, height = window["size"]
    steps = []
    before_inventory = json.loads(run("omarchy-shell", "shell", "listPlugins"))
    def image(label):
        target = args.output.with_name(args.output.stem + "--" + label + ".png")
        if target.exists(): raise RuntimeError("Refusing metric evidence overwrite")
        run("grim", "-g", f"{x},{y} {width}x{height}", str(target))
        steps.append({"image": str(target), "label": label})
    def move(px, py):
        run("hyprctl", "eval", f"hl.dispatch(hl.dsp.cursor.move({{x={int(x+px)},y={int(y+py)}}}))")
        run("wlrctl", "pointer", "move", "1", "0")
    def tab_frames(count):
        move(width // 2, 70)
        for index in range(count):
            run("wtype", "-k", "Tab")
            time.sleep(0.45)
            image("keyboard-tab-%02d" % (index + 1))
    if args.check_metrics == "detail":
        compact_detail = width < 1000
        beside_preview = compact_detail and height < 640 and args.scenario in {"cards", "density"} and not args.no_thumbnails
        move(420 if beside_preview else 109, 272 if compact_detail else 295)
        time.sleep(0.65)
        image("metric-hover")
        # Re-enter the same fictional detail through the normal panel route to
        # establish its Back-button focus, then use only Tab for metric help.
        run("omarchy-shell", "shell", "summon", ID, json.dumps(payload))
        time.sleep(0.5)
        tab_frames(8)
        run("omarchy-shell", "shell", "summon", ID, json.dumps(payload))
        time.sleep(0.4)
        move(440 if not args.narrow else 220, height - 120)
        run("wlrctl", "pointer", "scroll", "1200", "0")
        time.sleep(0.5)
        image("why-recommended-default-expanded")
    else:
        if args.check_metrics == "card":
            if args.density not in {None, "comfortable"} or args.grouping != "none":
                raise RuntimeError("Card help targeting requires comfortable ungrouped fixture")
            move(375, 435)
            time.sleep(0.65)
            image("metric-hover")
            # Clicking the already-selected density establishes a known keyboard
            # start without opening a card or changing its data.
            move(width - 161, 158)
            run("wlrctl", "pointer", "click")
            time.sleep(0.2)
            tab_frames(13)
        move(100, height - 80)
        run("wlrctl", "pointer", "scroll", "1200", "0")
        time.sleep(0.5)
        image("filters-scrolled-bottom")
        move(223, height - 28)
        time.sleep(0.5)
        image("filter-scrollbar-bottom-hover")
        move(190, height - 35)
        time.sleep(0.5)
        image("adjacent-filter-control-hover")
    after_inventory = json.loads(run("omarchy-shell", "shell", "listPlugins"))
    current = json.loads(run("omarchy-shell", ID, "status"))
    if before_inventory != after_inventory or not current.get("demo") or not current.get("opened"):
        raise RuntimeError("Metric evidence run changed native state or closed the fixture")
    return {"kind": args.check_metrics, "steps": steps, "nativeInventoryUnchanged": True,
            "verification": "Inspect hover and keyboard frames for actual tooltip visibility and gutter geometry."}

def exercise_tooltips(window):
    """Pointer/keyboard evidence, with an owned blank window for deactivation.

    IPC asserts navigation and isolation. Tooltip visibility verdicts require
    inspection of the recorded frames; no production-only test hooks are used.
    """
    x, y = window["at"]
    width, height = window["size"]
    steps = []
    probe = None
    before_inventory = json.loads(run("omarchy-shell", "shell", "listPlugins"))
    def status(): return json.loads(run("omarchy-shell", ID, "status"))
    def wait_for(predicate, message):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if predicate(): return
            time.sleep(0.1)
        raise RuntimeError("Tooltip check: " + message)
    def move(px, py):
        run("hyprctl", "eval", f"hl.dispatch(hl.dsp.cursor.move({{x={int(x+px)},y={int(y+py)}}}))")
        run("wlrctl", "pointer", "move", "1", "0")
    def key(name, modifier=None):
        run("wtype", *((["-M", modifier] if modifier else []) + ["-k", name] + (["-m", modifier] if modifier else [])))
        time.sleep(0.3)
        steps.append({"key": name, "modifier": modifier})
    def image(label, expected):
        time.sleep(0.7)
        target = args.output.with_name(args.output.stem + "--" + label + ".png")
        if target.exists(): raise RuntimeError("Refusing tooltip evidence overwrite")
        run("grim", "-g", f"{x},{y} {width}x{height}", str(target))
        steps.append({"image": str(target), "label": label, "expectedTooltip": expected})
    try:
        move(width // 2, 70)
        image("no-hover", "none")
        move(497, 376)
        run("wlrctl", "pointer", "click")
        wait_for(lambda: bool(status()["selectedPlugin"]), "fresh Details pointer click failed")
        key("BackSpace")
        wait_for(lambda: not status()["selectedPlugin"], "fresh pointer detail did not return to Browse")
        move(width - 119, 158)
        image("compact-hover", "Compact")
        run("wlrctl", "pointer", "click")
        wait_for(lambda: status()["browseDensity"] == "compact" and not status()["densitySavePending"], "Compact click failed")
        move(width // 2, 70)  # Do not click: Compact retains native mouse focus.
        image("compact-click-leave", "none; Compact still focused")
        move(width - 119, 158)
        image("compact-rehover", "Compact")
        move(width // 2, 70)
        image("compact-rehover-leave", "none")
        key("Right")
        wait_for(lambda: status()["browseDensity"] == "dense", "density keyboard Right failed")
        image("density-keyboard-right", "Dense")
        key("Left")
        wait_for(lambda: status()["browseDensity"] == "compact", "density keyboard Left failed")
        key("F6")
        image("f6-toolbar", "keyboard toolbar help")
        move(width // 2 + 20, 70)
        image("pointer-after-keyboard", "none")
        move(width - 161, 158)
        run("wlrctl", "pointer", "click")
        wait_for(lambda: status()["browseDensity"] == "comfortable" and not status()["densitySavePending"], "Comfortable restoration failed")
        move(width // 2, 70)
        key("f", "ctrl")
        key("Tab")
        key("F2")
        key("Right")  # F2 first enters the card's Details action, then metrics.
        image("f2-metric", "keyboard metric help")
        key("Right")
        image("metric-arrow", "keyboard help for next metric")
        move(375, 435)
        image("metric-hover-before-scroll", "metric help")
        run("wlrctl", "pointer", "scroll", "700", "0")
        image("after-scroll", "none; no stale tooltip after content moves")
        run("wlrctl", "pointer", "scroll", "-2400", "0")
        # Let the large reverse-wheel scroll and edge rebound finish; a press
        # during Flickable motion can stop scrolling rather than activate.
        time.sleep(1.5)
        move(497, 376)
        run("wlrctl", "pointer", "click")
        wait_for(lambda: bool(status()["selectedPlugin"]), "settled post-scroll Details pointer activation failed")
        selected = status()["selectedPlugin"]
        move(127, 300)
        image("detail-metric-hover", "detail metric help")
        key("BackSpace")
        wait_for(lambda: not status()["selectedPlugin"] and status()["opened"], "Backspace view change failed")
        image("after-view-change", "none")
        key("Return")
        wait_for(lambda: status()["selectedPlugin"] == selected, "result focus did not return after detail Backspace")
        key("BackSpace")
        wait_for(lambda: not status()["selectedPlugin"], "second Backspace failed")
        move(width - 119, 158)
        image("before-deactivate", "Compact")
        probe = subprocess.Popen(["foot", "--app-id=outfit-tooltip-focus-probe",
                                  "--title=Tooltip focus probe", "--window-size-pixels=240x100", "sleep", "60"],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        def probe_window():
            return next((w for w in json.loads(run("hyprctl", "clients", "-j"))
                         if w.get("pid") == probe.pid and w.get("class") == "outfit-tooltip-focus-probe"), None)
        wait_for(lambda: probe_window() is not None, "owned focus probe did not open")
        other = probe_window()
        address = json.dumps("address:" + other["address"])
        if not other.get("floating"):
            run("hyprctl", "dispatch", 'hl.dsp.window.float({window=' + address + ',action="toggle"})')
        run("hyprctl", "dispatch", 'hl.dsp.window.resize({window=' + address + ',x=240,y=100})')
        run("hyprctl", "dispatch", 'hl.dsp.window.center({window=' + address + '})')
        run("hyprctl", "eval", 'hl.dispatch(hl.dsp.focus({window=' + address + '}))')
        wait_for(lambda: json.loads(run("hyprctl", "activewindow", "-j")).get("address") == other["address"], "probe did not take focus")
        image("window-inactive", "none; owned blank focus probe is active")
        probe.terminate()
        probe.wait(timeout=10)
        probe = None
        wait_for(lambda: json.loads(run("hyprctl", "activewindow", "-j")).get("address") == window["address"], "Outfit focus did not return after probe closed")
        image("window-focus-return", "none until fresh input")
        move(width // 2, 70)
        move(width - 119, 158)
        image("focus-return-rehover", "Compact")
        move(width // 2, 70)
        image("final-leave", "none")
        if json.loads(run("omarchy-shell", "shell", "listPlugins")) != before_inventory:
            raise RuntimeError("Tooltip checks changed native plugin inventory")
        if not status()["opened"] or not status()["demo"]:
            raise RuntimeError("Tooltip checks lost the fixture app")
        report = {"interactionChecksPassed": True, "visualVerdict": "requires screenshot inspection",
                  "nativeInventoryUnchanged": True, "focusReturned": True, "steps": steps}
        args.output.with_suffix(".tooltips.json").write_text(json.dumps(report, indent=2))
        return report
    except Exception as error:
        image("failure", "inspect failure")
        args.output.with_suffix(".tooltips.json").write_text(json.dumps({"interactionChecksPassed": False, "error": str(error), "steps": steps}, indent=2))
        raise
    finally:
        if probe is not None:
            probe.terminate()
            probe.wait(timeout=10)

def exercise_card_help(window):
    """Check clickable metrics, card/overlay activation and Escape precedence."""
    x, y = window["at"]
    width, height = window["size"]
    steps = []
    before = json.loads(run("omarchy-shell", "shell", "listPlugins"))
    def current(): return json.loads(run("omarchy-shell", ID, "status"))
    def wait_for(predicate, message):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if predicate(): return
            time.sleep(0.1)
        raise RuntimeError("Card-help check: " + message)
    def move(px, py):
        run("hyprctl", "eval", f"hl.dispatch(hl.dsp.cursor.move({{x={int(x+px)},y={int(y+py)}}}))")
        run("wlrctl", "pointer", "move", "1", "0")
    def key(name, modifier=None):
        run("wtype", *((["-M", modifier] if modifier else []) + ["-k", name] + (["-m", modifier] if modifier else [])))
        time.sleep(0.3)
        steps.append({"key": name, "modifier": modifier})
    def click(px, py):
        move(px, py)
        run("wlrctl", "pointer", "click")
        time.sleep(0.25)
    def image(label):
        time.sleep(0.6)
        target = args.output.with_name(args.output.stem + "--" + label + ".png")
        if target.exists(): raise RuntimeError("Refusing card-help evidence overwrite")
        run("grim", "-g", f"{x},{y} {width}x{height}", str(target))
        steps.append({"image": str(target), "label": label})
    def remains_browse():
        if not current()["opened"] or current()["selectedPlugin"]:
            raise RuntimeError("Metric interaction opened detail or closed Browse")
    try:
        move(width // 2, 70)
        image("browse-no-help")
        for metric, px in [("stars", 305), ("likes", 379), ("views", 411), ("copies", 447)]:
            move(px, 395)
            image("browse-" + metric + "-hover")
            run("wlrctl", "pointer", "click")
            remains_browse()
            image("browse-" + metric + "-click")
            key("Escape")
            remains_browse()
            image("browse-" + metric + "-escape")
            move(width // 2, 70)
        click(305, 395)
        click(width - 40, height - 30)
        remains_browse()
        image("outside-click-dismissed")
        key("f", "ctrl")
        key("Tab")
        key("F2")
        image("browse-keyboard-first-metric")
        key("Return")
        remains_browse()
        image("browse-keyboard-enter-help")
        key("Right")
        image("browse-keyboard-next-metric")
        key("Escape")
        remains_browse()
        key("f", "ctrl")
        key("Tab")
        key("Return")
        wait_for(lambda: current()["selectedPlugin"] == "example.quiet-hours", "whole-card keyboard activation failed")
        image("detail-six-metrics")
        move(80, 279)
        image("detail-stars-hover")
        run("wlrctl", "pointer", "click")
        image("detail-stars-click")
        key("Escape")
        if current()["selectedPlugin"] != "example.quiet-hours":
            raise RuntimeError("Escape dismissed detail instead of metric help")
        image("detail-help-escape-keeps-page")
        move(width // 2, 70)
        for _ in range(3): key("Tab")
        for index, metric in enumerate(["stars", "likes", "views", "copies", "recommended", "fit"]):
            if index: key("Tab")
            image("detail-keyboard-" + metric)
        key("Return")
        image("detail-keyboard-enter-help")
        key("Escape")
        if current()["selectedPlugin"] != "example.quiet-hours":
            raise RuntimeError("Keyboard-help Escape left detail")
        image("detail-keyboard-escape-keeps-page")
        key("Escape")
        wait_for(lambda: not current()["selectedPlugin"] and current()["opened"], "second Escape did not return to Browse")
        image("second-escape-browse")
        click(519, 208)
        wait_for(lambda: current()["selectedPlugin"] == "example.quiet-hours", "New overlay intercepted first card click")
        image("new-overlay-click-opens-card")
        key("BackSpace")
        wait_for(lambda: not current()["selectedPlugin"], "Backspace failed")
        click(820, 208)
        wait_for(lambda: current()["selectedPlugin"] == "example.dock-helper", "loaded-thumbnail New overlay intercepted card click")
        image("loaded-new-overlay-click-opens-card")
        key("BackSpace")
        wait_for(lambda: not current()["selectedPlugin"], "second Backspace failed")
        click(280, 373)
        wait_for(lambda: current()["selectedPlugin"] == "example.quiet-hours", "card name/body pointer click failed")
        key("BackSpace")
        wait_for(lambda: not current()["selectedPlugin"], "final Backspace failed")
        move(width // 2, 70)
        image("final-browse")
        if json.loads(run("omarchy-shell", "shell", "listPlugins")) != before:
            raise RuntimeError("Card-help checks changed native plugin inventory")
        report = {"interactionChecksPassed": True, "nativeInventoryUnchanged": True,
                  "visualVerdict": "requires screenshot inspection", "steps": steps}
        args.output.with_suffix(".card-help.json").write_text(json.dumps(report, indent=2))
        return report
    except Exception as error:
        image("failure")
        args.output.with_suffix(".card-help.json").write_text(json.dumps({"interactionChecksPassed": False, "error": str(error), "steps": steps}, indent=2))
        raise

def exercise_navigation(window):
    """Real keyboard/pointer routes only; never confirms plugin mutations."""
    if args.verify_navigation == "tooltips":
        return exercise_tooltips(window)
    if args.verify_navigation == "card-help":
        return exercise_card_help(window)
    x, y = window["at"]
    width, height = window["size"]
    steps = []
    native_before = json.loads(run("omarchy-shell", "shell", "listPlugins"))
    def current(): return json.loads(run("omarchy-shell", ID, "status"))
    def wait_for(predicate, message):
        end = time.monotonic() + 10
        while time.monotonic() < end:
            if predicate(): return
            time.sleep(0.1)
        raise RuntimeError("Navigation check: " + message)
    def image(label):
        path = args.output.with_name(args.output.stem + "--" + label + ".png")
        if path.exists(): raise RuntimeError("Refusing navigation evidence overwrite")
        run("grim", "-g", f"{x},{y} {width}x{height}", str(path))
        steps.append({"image": str(path), "label": label})
    def move(px, py):
        run("hyprctl", "eval", f"hl.dispatch(hl.dsp.cursor.move({{x={int(x+px)},y={int(y+py)}}}))")
        run("wlrctl", "pointer", "move", "1", "0")
    def key(name, modifier=None):
        command = (["-M", modifier] if modifier else []) + ["-k", name] + (["-m", modifier] if modifier else [])
        run("wtype", *command)
        steps.append({"key": name, "modifier": modifier})
        time.sleep(0.25)
    def search(text):
        key("f", "ctrl")
        key("a", "ctrl")
        if text: run("wtype", text)
        else: key("BackSpace")
        time.sleep(0.5)
    try:
        if args.verify_navigation == "preview":
            # Native ReadmeMediaPreview's loaded image is in this left-hand stage.
            move(425, 535)
            run("wlrctl", "pointer", "click")
            steps.append({"pointer": "Click loaded production preview image"})
            time.sleep(0.4)
            image("preview-pointer-open")
            key("Escape")
            if not current()["opened"] or current()["selectedPlugin"] != args.plugin:
                raise RuntimeError("Escape propagated from preview and dismissed detail/app")
            image("preview-escape-keeps-detail")
            # Popup close restores actual image focus. No focus-repair call.
            key("Return")
            image("preview-enter-open")
            key("Escape")
            if current()["selectedPlugin"] != args.plugin: raise RuntimeError("Enter-preview Escape lost detail")
            key("space")
            image("preview-space-open")
            key("Escape")
            if current()["selectedPlugin"] != args.plugin: raise RuntimeError("Space-preview Escape lost detail")
            key("BackSpace")
            wait_for(lambda: not current()["selectedPlugin"] and current()["opened"], "Backspace did not return detail to Browse")
            image("backspace-detail-to-browse")
        else:
            if args.sort == "stars":
                # Exercise the real dropdown, then restore the initial sort.
                # Stars sits between Recommended and Hardware fit.
                for label, keys in (("recommended", ["Up"]),
                                    ("hardware-fit", ["Down", "Down"]),
                                    ("most-starred-restored", ["Up"])):
                    move(width - 120, 105)
                    run("wlrctl", "pointer", "click")
                    time.sleep(0.2)
                    for name in keys:
                        key(name)
                    key("Return")
                    wait_for(lambda: current()["ready"] and current()["results"] > 0
                             and current()["opened"], "sort did not return ready results: " + label)
                    move(width // 2, 70)
                    time.sleep(0.4)
                    image("sort-" + label)
                    steps.append({"sortSelected": label, "readyResults": current()["results"]})
            move(width // 2, 70)
            time.sleep(0.5)
            image("metrics-no-hover")
            move(495, 246) if args.density == "list" else move(375, 435)
            time.sleep(0.7)
            image("metrics-hover")
            move(width // 2, 70)
            search("dockx")
            wait_for(lambda: current()["ready"] and current()["results"] == 0, "search query not applied")
            key("BackSpace")
            wait_for(lambda: current()["ready"] and current()["results"] > 0 and current()["opened"], "Backspace did not edit search text safely")
            image("backspace-edits-search")
            search("")
            wait_for(lambda: current()["ready"] and current()["results"] > 3, "full fictional result set not restored")
            key("Tab")
            image("tab-filters-to-results")
            key("Return")
            wait_for(lambda: bool(current()["selectedPlugin"]), "Enter did not open focused result")
            first = current()["selectedPlugin"]
            image("enter-first-result")
            key("BackSpace")
            wait_for(lambda: not current()["selectedPlugin"], "Backspace did not return to results")
            key("Down" if args.density == "list" else "Right")
            image("arrow-next-result")
            key("Return")
            wait_for(lambda: bool(current()["selectedPlugin"]) and current()["selectedPlugin"] != first, "arrow/Enter did not select another plugin")
            steps.append({"firstOpenedId": first, "nextOpenedId": current()["selectedPlugin"]})
            image("enter-next-result")
            key("BackSpace")
            wait_for(lambda: not current()["selectedPlugin"], "second detail Backspace failed")
            key("Tab", "shift")
            image("shift-tab-results-to-filters")
            key("Tab")
            key("F2")
            key("Right")
            key("Right")
            move(width // 2, 70)
            time.sleep(0.5)
            image("f2-nested-metric-focus")
            key("F6")
            image("f6-toolbar-focus")
            # A non-text filter owns plain arrows. Enter applies the moved-to
            # Installed filter, proving focus movement rather than text editing.
            move(110, 335)
            run("wlrctl", "pointer", "click")
            time.sleep(0.2)
            key("Down")
            image("filter-arrow-focus")
            key("Return")
            wait_for(lambda: current()["ready"] and current()["results"] == 1, "filter arrow+Enter did not apply Installed")
            image("filter-enter-applied")
        move(width // 2, 70)
        time.sleep(0.4)
        key("Escape")
        wait_for(lambda: current()["opened"] is False, "Escape from main did not intentionally close app")
        image("escape-main-closed")
        if json.loads(run("omarchy-shell", "shell", "listPlugins")) != native_before:
            raise RuntimeError("Navigation changed native plugin inventory")
        report = {"pass": True, "mode": args.verify_navigation, "steps": steps,
                  "nativeInventoryUnchanged": True, "appClosedIntentionallyAtEnd": True,
                  "previewImplementation": "Production internal image popup" if args.verify_navigation == "preview" else None}
        args.output.with_suffix(".navigation.json").write_text(json.dumps(report, indent=2))
        return report
    except Exception as error:
        image("navigation-failure")
        args.output.with_suffix(".navigation.json").write_text(json.dumps({"pass": False, "error": str(error), "steps": steps}, indent=2))
        raise

try:
    used = {w["id"] for w in json.loads(run("hyprctl", "workspaces", "-j"))}
    workspace = next(value for value in range(1000, 2000) if value not in used)
    run("hyprctl", "eval", f'hl.dispatch(hl.dsp.focus({{workspace="{workspace}"}}))')
    shell_path = str(Path(os.environ.get("OMARCHY_PATH", "/usr/share/omarchy")) / "shell")
    for _ in range(5):
        stopped = subprocess.run(["quickshell", "kill", "-p", shell_path, "--any-display"],
                                 capture_output=True, timeout=10)
        if stopped.returncode: break
    if recent_fixture_bytes is not None:
        (plugin / "demo/fixtures/example.json").write_bytes(recent_fixture_bytes)
        validated_hashes["demo/fixtures/example.json"] = saved["fixtureOverride"]["captureSha256"]
    if args.shell_font_size:
        # This override belongs only to the isolated capture lifetime. The
        # recovery marker and restore() retain the original file exactly.
        config.with_suffix(".toml").write_text("[font]\nbase-size = " + str(args.shell_font_size) + "\n")
        if args.density:
            # Stock-font pointer coordinates do not describe enlarged controls.
            # Seed only the private fixture preference for font stress captures;
            # ordinary captures still exercise the real density buttons/keys.
            preferences_dir = state / "config" / ID
            preferences_dir.mkdir(parents=True, exist_ok=True)
            (preferences_dir / "preferences.json").write_text(json.dumps({
                "schema": 1, "browseDensity": args.density, "watchHardware": False,
                "readmeEnrichment": False, "readmeIndexing": False,
                "marketplaceThumbnails": not args.no_thumbnails}))
    environment_args = ["env"]
    # Clear both exact control sets so inherited legacy flags cannot leak into a capture.
    for prefix in ("OUTFIT_", "OMAFIT_"):
        for suffix in ("DETAIL_STATE", "VERIFY_INTERESTS", "VERIFY_SEARCH_SCROLL",
                       "DEMO_ROOT", "DEMO_SCENARIO", "DEMO_THUMBNAILS"):
            environment_args += ["-u", prefix + suffix]
    environment_args += ["OUTFIT_DEMO_ROOT=" + str(state),
                         "OUTFIT_DEMO_SCENARIO=" + args.scenario,
                         "OUTFIT_DEMO_THUMBNAILS=" + str(int(not args.no_thumbnails and args.scenario != "details"))]
    if args.scenario == "details":
        environment_args.append("OUTFIT_DETAIL_STATE=" + args.detail_state)
    if args.verify_interests or args.verify_save_footer:
        environment_args.append("OUTFIT_VERIFY_INTERESTS=1")
    if args.verify_search_scroll:
        environment_args.append("OUTFIT_VERIFY_SEARCH_SCROLL=1")
    command = shlex.join(environment_args + ["omarchy-launch-shell"])
    run("hyprctl", "eval", "hl.dispatch(hl.dsp.exec_cmd(" + json.dumps(command) + "))")
    deadline = time.monotonic() + 40
    while time.monotonic() < deadline:
        raw = run("omarchy-shell", ID, "status", check=False)
        try: status = json.loads(raw)
        except ValueError: status = {}
        if status.get("demo"):
            payload = {"setupStage":"browse", "setupSort":args.sort, "setupGrouping":args.grouping,
                       "selectedId":"" if args.density or args.scenario == "details" else args.plugin}
            if args.scenario == "details":
                payload["workspaceView"] = "browse"
            if args.view:
                payload["workspaceView"] = args.view
            if args.surface in {"inputs", "saved", "picker", "new-interest"}:
                payload["interestsOpen"] = True
            if args.verify_interests:
                payload.update(workspaceView="browse", setupServices=["spotify"], setupServiceFilter="spotify")
            if args.surface == "matches":
                payload.update(workspaceView="discover", discoverTab="matches")
            run("omarchy-shell", "shell", "summon", ID, json.dumps(payload))
            break
        time.sleep(0.15)
    startup_status_retries = 0
    while time.monotonic() < deadline:
        try:
            status = json.loads(run("omarchy-shell", ID, "status", check=False))
        except (ValueError, subprocess.SubprocessError):
            startup_status_retries += 1
            time.sleep(0.15)
            continue
        if (status.get("ready") and status.get("demo") and status.get("inputsLoaded")
                and (not status.get("discoveryEnabled", True) or status.get("matchesLoaded"))): break
        time.sleep(0.15)
    else: raise RuntimeError("Demo did not reach a ready fixture state")
    if args.scenario in {"cards", "density"} and args.grouping == "none" and args.sort == "fit" and not args.no_thumbnails:
        image = state / "cache" / ID / ("thumb-" + "0" * 32 + "-" + "1" * 16 + ".png")
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and not image.exists():
            time.sleep(0.1)
        if not image.exists():
            raise RuntimeError("The mixed-preview fixture did not load its local image")
        time.sleep(0.2)
    window = next(w for w in json.loads(run("hyprctl", "clients", "-j")) if w["title"] == "Outfit - Plugin Manager")
    environment = Path(f'/proc/{window["pid"]}/environ').read_bytes().split(b"\0")
    if ("OUTFIT_DEMO_ROOT=" + str(state)).encode() not in environment:
        raise RuntimeError("Shell did not inherit fixture isolation")
    if args.scenario == "details" and (b"OUTFIT_DEMO_SCENARIO=details" not in environment
            or ("OUTFIT_DETAIL_STATE=" + args.detail_state).encode() not in environment):
        raise RuntimeError("Shell did not inherit the requested details prototype state")
    run("hyprctl", "eval", "hl.dispatch(hl.dsp.focus({window=" + json.dumps("address:" + window["address"]) + "}))")
    if args.narrow or tracked_capture:
        target_width = requested_size[0] if requested_size else 760 if args.narrow else 1180
        target_height = requested_size[1] if requested_size else (540 if args.narrow else 760) if tracked_capture else 620
        address = json.dumps("address:" + window["address"])
        if not window.get("floating"):
            run("hyprctl", "dispatch", 'hl.dsp.window.float({window=' + address + ',action="toggle"})')
        run("hyprctl", "dispatch", 'hl.dsp.window.resize({window=' + address + f',x={target_width},y={target_height}' + '})')
        run("hyprctl", "dispatch", 'hl.dsp.window.center({window=' + address + '})')
        time.sleep(0.6)
        window = next(w for w in json.loads(run("hyprctl", "clients", "-j")) if w["address"] == window["address"])
        if window["size"][0] != target_width or (tracked_capture and window["size"][1] != target_height):
            raise RuntimeError(f"Could not establish requested fixture geometry {target_width}x{target_height}; got {window['size']}")
    run("omarchy-shell", "notifications", "dismissAll")
    time.sleep(0.15)  # Let the dismissed toast surfaces leave the next rendered frame.
    x, y = window["at"]
    width, height = window["size"]
    if args.surface in {"actions", "settings", "collapsed", "expanded"}:
        # This harness targets the fresh VM's stock 1x UI, never a personal
        # desktop. Keep interactions inside the known fixture toolbar only.
        offset = 125 if args.surface == "actions" else 80
        target_x, target_y = x + width - offset, y + 35
        if args.surface in {"collapsed", "expanded"}:
            target_x, target_y = x + 212, y + 91
        run("hyprctl", "eval", f"hl.dispatch(hl.dsp.cursor.move({{x={target_x},y={target_y}}}))")
        run("wlrctl", "pointer", "move", "1", "0")
        run("wlrctl", "pointer", "click")
        time.sleep(0.15)
        if args.surface in {"collapsed", "expanded"}:
            status = json.loads(run("omarchy-shell", ID, "status"))
            if status.get("filtersExpanded") is not False:
                raise RuntimeError("Fixture click did not collapse filters")
        if args.surface == "expanded":
            run("wtype", "-k", "Return")  # Collapse returns focus to Expand filters.
            time.sleep(0.15)
            if not json.loads(run("omarchy-shell", ID, "status")).get("filtersExpanded"):
                raise RuntimeError("Keyboard activation did not expand filters")
    if args.surface in {"saved", "picker", "new-interest"}:
        run("wtype", "-M", "alt", "-k", "2", "-m", "alt")
        time.sleep(0.15)
    if args.surface == "new-interest":
        run("wtype", "-M", "alt", "a", "-m", "alt")
        time.sleep(0.15)
        run("wtype", "Workspace tools", "-k", "Tab", "-k", "Tab", "workspace", "-k", "Tab", "-k", "Return")
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            status = json.loads(run("omarchy-shell", ID, "status"))
            if status.get("interestPreviewTotal") is not None: break
            time.sleep(0.1)
        else: raise RuntimeError("Interest editor did not preview local matches")
    if args.scenario == "preview":
        payload["inspectorScroll"] = 190
        run("omarchy-shell", "shell", "summon", ID, json.dumps(payload))
        time.sleep(0.6)
    if args.density and args.shell_font_size:
        if json.loads(run("omarchy-shell", ID, "status")).get("browseDensity") != args.density:
            raise RuntimeError("Enlarged-font fixture density was not restored from its private preferences")
    if args.density and not args.shell_font_size:
        index = VIEWS.index(args.density)
        first_icon_x = x + width - 16 - (len(VIEWS) * 38 + (len(VIEWS) - 1) * 4) + 19
        run("hyprctl", "eval", f"hl.dispatch(hl.dsp.cursor.move({{x={first_icon_x + index * 42},y={y + 158}}}))")
        run("wlrctl", "pointer", "move", "1", "0")
        run("wlrctl", "pointer", "click")
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            status = json.loads(run("omarchy-shell", ID, "status"))
            if status.get("browseDensity") == args.density and not status.get("densitySavePending"):
                break
            time.sleep(0.1)
        else:
            raise RuntimeError("Density control did not apply and save the requested mode")
        stored = json.loads((state / "config" / ID / "preferences.json").read_text())
        if stored.get("browseDensity") != args.density:
            raise RuntimeError("Density preference was not persisted")
        # Arrow selection is immediate and uses the same mutually exclusive control.
        run("wtype", "-k", "Right")
        time.sleep(0.15)
        expected = VIEWS[(index + 1) % len(VIEWS)]
        if json.loads(run("omarchy-shell", ID, "status")).get("browseDensity") != expected:
            raise RuntimeError("Density keyboard selection failed")
        run("wtype", "-k", "Left")
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            status = json.loads(run("omarchy-shell", ID, "status"))
            if status.get("browseDensity") == args.density and not status.get("densitySavePending"):
                break
            time.sleep(0.1)
        else:
            raise RuntimeError("Density keyboard restoration failed")
        # Move off the control, then dismiss its focus tooltip without closing the app.
        run("hyprctl", "eval", f"hl.dispatch(hl.dsp.cursor.move({{x={x + width // 2},y={y + height - 20}}}))")
        run("wlrctl", "pointer", "move", "1", "0")
        run("wtype", "-k", "Tab")
        if args.density == "list" and args.scenario == "density" and args.sort == "fit" and not args.check_metrics:
            expected_id = "example.density-09" if args.grouping == "none" else "example.density-03"
            run("wtype", "-k", "Down", "-k", "Up", "-k", "Down")
            time.sleep(0.1)
            if json.loads(run("omarchy-shell", ID, "status")).get("selectedPlugin"):
                raise RuntimeError("Moving list focus unexpectedly opened the inspector")
            for _ in range(2):
                run("wtype", "-k", "Return")
                time.sleep(0.15)
                if json.loads(run("omarchy-shell", ID, "status")).get("selectedPlugin") != expected_id:
                    raise RuntimeError("List navigation or inspector focus restoration failed")
                run("wtype", "-k", "Escape")
                time.sleep(0.15)
        if args.plugin:
            payload["selectedId"] = args.plugin
            run("omarchy-shell", "shell", "summon", ID, json.dumps(payload))
        time.sleep(0.2)
    if args.remove_saved:
        run("hyprctl", "eval", f"hl.dispatch(hl.dsp.cursor.move({{x={x + 170},y={y + 622}}}))")
        run("wlrctl", "pointer", "move", "1", "0")
        run("wlrctl", "pointer", "click")
        time.sleep(0.2)
        if not json.loads(run("omarchy-shell", ID, "status")).get("interestsDirty"):
            raise RuntimeError("Remove did not update the draft with an editor open")
    if args.verify_markdown:
        markdown_inventory = json.loads(run("omarchy-shell", "shell", "listPlugins"))
        deadline = time.monotonic() + 12
        cached = {}
        while time.monotonic() < deadline:
            cache_path = state / "cache" / ID / "readmes.json"
            if cache_path.exists():
                cached = json.loads(cache_path.read_text())
                if args.plugin in cached.get("entries", {}) and (state / "readme-response.json").exists(): break
            time.sleep(0.1)
        else:
            raise RuntimeError("Production detail did not fetch/cache its README automatically")
        args.output.with_suffix(".readme-cache.json").write_text(json.dumps(cached, indent=2))
        response = json.loads((state / "readme-response.json").read_text())
        args.output.with_suffix(".readme-response.json").write_text(json.dumps(response, indent=2))
        if not response.get("ok") or not response.get("readmeBlocks"):
            raise RuntimeError("Production README response has no parsed document blocks")
        kinds = {block["kind"] for block in response["readmeBlocks"]}
        document = json.dumps(response["readmeBlocks"])
        if (not {"heading", "paragraph", "code", "list", "quote"}.issubset(kinds)
                or '"kind": "link"' not in document or '"kind": "image"' in document
                or "<img" in document or "example.invalid" in document):
            raise RuntimeError("README blocks do not contain the expected safe Markdown fixture")
        run("hyprctl", "eval", f"hl.dispatch(hl.dsp.cursor.move({{x={x+500},y={y+600}}}))")
        run("wlrctl", "pointer", "scroll", "500", "0")
        time.sleep(0.6)
    if not args.verify_interests and not args.verify_save_footer and not args.verify_search_scroll:
        run("grim", "-g", f"{x},{y} {width}x{height}", str(args.output.resolve()))
    markdown_checks = None
    if args.verify_markdown:
        run("hyprctl", "eval", f"hl.dispatch(hl.dsp.cursor.move({{x={x+95},y={y+106}}}))")
        run("wlrctl", "pointer", "move", "1", "0")
        run("wlrctl", "pointer", "click")
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            current = json.loads(run("omarchy-shell", ID, "status"))
            if not current["selectedPlugin"] and current["opened"]: break
            time.sleep(0.1)
        else:
            raise RuntimeError("Bordered detail Back did not return to Browse")
        if json.loads(run("omarchy-shell", "shell", "listPlugins")) != markdown_inventory:
            raise RuntimeError("README/Back check changed native plugin inventory")
        markdown_checks = {"pass": True, "productionFetchCacheAndParser": True,
            "blockKinds": sorted(kinds), "noInlineImages": True, "backPointerReturnedToBrowse": True,
            "nativeInventoryUnchanged": True, "documentationDisclosureNeverClicked": True}
    if detail_evidence:
        capture_status = json.loads(run("omarchy-shell", ID, "status"))
        search_checks = None
        if args.verify_search_scroll:
            from search_scroll_checks import verify
            search_checks = verify(run, window, state, args.output, args.sort)
        interaction_evidence = (exercise_details(window) if args.detail_interactions else
                                exercise_save_footer(window) if args.verify_save_footer else
                                exercise_interests(window) if args.verify_interests else
                                exercise_metrics(window) if args.check_metrics else
                                exercise_navigation(window) if args.verify_navigation else search_checks or markdown_checks)
        log = run("quickshell", "log", "--pid", str(window["pid"]), "--no-color", "--log-times", check=False)
        relevant = [line for line in log.splitlines() if any(name in line for name in
                    ("PluginDetailPage.qml", "DetailPrototype.qml", "details-fixtures.js", "OutfitApp.qml", "InterestsManager.qml",
                     "TypeError", "ReferenceError", "Binding loop", "Unable to assign"))]
        with args.output.with_suffix(".qml.log").open("x") as stream:
            stream.write("\n".join(relevant) + ("\n" if relevant else ""))
        evidence = {"scenario": args.scenario, "surface": args.surface, "detailState": args.detail_state, "windowSize": [width, height],
                    "requestedWindowSize": list(requested_size) if requested_size else None,
                    "floating": window.get("floating"),
                    "monitors": [{key: monitor.get(key) for key in ("name", "width", "height", "scale", "transform")}
                                 for monitor in json.loads(run("hyprctl", "monitors", "-j"))],
                    "qtScaleEnvironment": [part.decode() for part in environment if part.startswith(
                        (b"QT_SCALE_FACTOR=", b"QT_SCREEN_SCALE_FACTORS=", b"QT_FONT_DPI="))],
                    "imagePixelSize": list(struct.unpack(">II", args.output.read_bytes()[16:24])),
                    "windowAddress": window["address"], "shellPid": window["pid"],
                    "omarchyPath": os.environ.get("OMARCHY_PATH", ""), "fixtureEnvironmentVerified": True,
                    "simulatedControlsOnly": True, "sha256": validated_hashes, "image": str(args.output.resolve()),
                    "qmlDiagnostics": relevant, "interactions": interaction_evidence,
                     "startupStatusRetries": startup_status_retries,
                     "shellFontBaseSizeOverride": args.shell_font_size,
                     "fixtureOverride": saved.get("fixtureOverride"),
                     "densitySelection": "fixture-preference" if args.density and args.shell_font_size else "pointer-and-keyboard" if args.density else None,
                     "captureStatus": {key: capture_status.get(key) for key in
                         ("discoveryEnabled", "view", "ready", "queryBusy", "backgroundBusy",
                          "indexingBusy", "matchesLoaded", "interestsDirty")},
                    "captureHarnessSha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
        with detail_evidence.open("x") as stream:
            json.dump(evidence, stream, indent=2)
    print("Captured fictional hosted UI:", args.output)
    if args.interactive:
        # The owning foreground process remains alive (normally in a guest user
        # service). The existing finally path restores the shell on every exit.
        lifetime = args.interactive_timeout or 7200
        started_at = time.time()
        saved["interactiveDeadline"] = started_at + lifetime
        marker.write_text(json.dumps(saved))
        evidence = json.loads(detail_evidence.read_text())
        evidence["interactive"] = {"running": True, "startedAt": started_at,
                                   "deadlineAt": started_at + lifetime, "timeoutSeconds": lifetime}
        detail_evidence.write_text(json.dumps(evidence, indent=2))
        print("Interactive fictional preview ready. Close the Outfit window to restore the VM; automatic timeout:", lifetime, "seconds.", flush=True)
        interactive_exit = wait_for_detail_close(lifetime, lambda: json.loads(run("omarchy-shell", ID, "status")))
        print("Interactive preview ended:", interactive_exit, flush=True)
    if args.surface == "new-interest":
        original_revision = json.loads(run("omarchy-shell", ID, "status"))["criteriaRevision"]
        if args.remove_saved:
            run("hyprctl", "eval", f"hl.dispatch(hl.dsp.cursor.move({{x={x + 280},y={y + 437}}}))")
            run("wlrctl", "pointer", "move", "1", "0")
            run("wlrctl", "pointer", "click")
        else:
            run("wtype", "-k", "Tab", "-k", "Return")
        time.sleep(0.15)
        run("wtype", "-M", "ctrl", "s", "-m", "ctrl")
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            status = json.loads(run("omarchy-shell", ID, "status"))
            if status.get("criteriaRevision", 0) > original_revision and not status.get("interestsDirty"):
                break
            time.sleep(0.1)
        else: raise RuntimeError("The UI did not save the new interest")
        document = json.loads((state / "config" / ID / "interests.json").read_text())
        if not any(c["label"] == "Workspace tools" and c["terms"] == ["workspace"] for c in document["criteria"]):
            raise RuntimeError("The saved custom criterion did not match the editor")
        if args.remove_saved and (any(c["label"] == "Dock accessories" for c in document["criteria"])
                or not any(c.get("serviceId") == "spotify" for c in document["criteria"])):
            raise RuntimeError("Removal failed to persist or removed the wrong interest")
        print("Native editor preview, draft and persisted save passed.")
    if args.surface == "matches":
        before = json.loads(run("omarchy-shell", ID, "status")).get("unreadMatches")
        if before != 1: raise RuntimeError("Expected one fictional new match")
        run("hyprctl", "eval", f"hl.dispatch(hl.dsp.cursor.move({{x={x + width // 2},y={y + 300}}}))")
        run("wlrctl", "pointer", "move", "1", "0")
        run("wlrctl", "pointer", "click")
        time.sleep(0.2)
        if json.loads(run("omarchy-shell", ID, "status")).get("unreadMatches") != before:
            raise RuntimeError("Inspecting a match incorrectly acknowledged it")
        run("wtype", "-k", "Escape")
        time.sleep(0.15)
        run("hyprctl", "eval", f"hl.dispatch(hl.dsp.cursor.move({{x={x + 330},y={y + 205}}}))")
        run("wlrctl", "pointer", "move", "1", "0")
        run("wlrctl", "pointer", "click")
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if json.loads(run("omarchy-shell", ID, "status")).get("unreadMatches") == 0: break
            time.sleep(0.1)
        else: raise RuntimeError("Explicit review did not clear the unread match")
        print("Native match inspection and explicit acknowledgement passed.")
    if args.verify_density_restart:
        if not args.density:
            raise RuntimeError("--verify-density-restart requires --density")
        run("quickshell", "kill", "-p", shell_path, "--any-display")
        # IPC acknowledges shutdown before Qt has always released the instance
        # lock. Wait for the observed fixture process to exit before relaunching.
        deadline = time.monotonic() + 10
        while Path(f'/proc/{window["pid"]}').exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        if Path(f'/proc/{window["pid"]}').exists():
            raise RuntimeError("Fixture shell did not finish shutting down")
        run("hyprctl", "eval", "hl.dispatch(hl.dsp.exec_cmd(" + json.dumps(command) + "))")
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            raw = run("omarchy-shell", ID, "status", check=False)
            try: status = json.loads(raw)
            except ValueError: status = {}
            if status.get("demo") and status.get("browseDensity") == args.density:
                print("Saved density restored after shell restart:", args.density)
                break
            time.sleep(0.15)
        else:
            raise RuntimeError("Saved density did not restore after shell restart: " + json.dumps(status))
    if args.surface == "actions":
        run("wtype", "-k", "Escape")
        time.sleep(0.15)
        if not json.loads(run("omarchy-shell", ID, "status")).get("opened"):
            raise RuntimeError("Escape dismissed Outfit instead of its popup")
    if args.surface == "expanded" and not args.density:
        run("wtype", "-k", "Return")  # Expand returns focus to Collapse filters.
        time.sleep(0.15)
        if json.loads(run("omarchy-shell", ID, "status")).get("filtersExpanded") is not False:
            raise RuntimeError("Keyboard activation did not collapse filters")
    if args.surface == "collapsed" and not args.density:
        run("wtype", "-M", "ctrl", "-k", "f", "-m", "ctrl", "dock")
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            status = json.loads(run("omarchy-shell", ID, "status"))
            if status.get("ready") and status.get("results") == 1:
                break
            time.sleep(0.1)
        else:
            raise RuntimeError("Ctrl+F search did not work with collapsed filters")
finally:
    if args.interactive and detail_evidence and detail_evidence.is_file():
        try:
            evidence = json.loads(detail_evidence.read_text())
            interactive = evidence.get("interactive", {})
            interactive.update(running=False, endedAt=time.time(), exitReason=interactive_exit)
            evidence["interactive"] = interactive
            detail_evidence.write_text(json.dumps(evidence, indent=2))
        except (OSError, ValueError):
            print("Could not update interactive evidence; continuing VM restoration.", flush=True)
    try: restore(saved)
    except Exception as error:
        print(f"RESTORATION NEEDS ATTENTION: {error}. Marker: {marker}")
        raise
