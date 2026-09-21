#!/usr/bin/env python3
"""Run the real protocol/ranking code with fictional, isolated, read-only inputs."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import struct
import subprocess
import time
import zlib

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("outfit", ROOT / "scripts/outfit.py")
app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(app)
# Keep production entry points before installing any fictional input adapters.
original = {name: getattr(app, name) for name in ("command_launch", "run_command", "scan_inventory", "scan_profile", "run", "write_response", "fetch_readme")}
fixture = json.loads((ROOT / "demo/fixtures/example.json").read_text())
for index, plugin in enumerate(fixture["catalog"]["plugins"]):
    plugin["repo"] = plugin["repo"].replace("github.com/example/", f"github.com/fictional-{index + 1}/")
def demo_env(suffix, default=""):
    # Historical harnesses remain usable; nonempty current controls take priority.
    return os.environ.get("OUTFIT_" + suffix) or os.environ.get("OMAFIT_" + suffix, default)


scenario = demo_env("DEMO_SCENARIO", "ready")
search_verify = demo_env("VERIFY_SEARCH_SCROLL") == "1"
if search_verify:
    if scenario != "cards":
        raise SystemExit("Search/scroll verification requires the cards fixture.")
    fixture["catalog"]["plugins"][0]["description"] = "Controls a MIDI controller through a USB-C dock."
    fixture["catalog"]["plugins"][1]["description"] = "A MIDI monitor for workspaces across multiple displays."
    fixture["catalog"]["plugins"].append({**fixture["catalog"]["plugins"][1],
        "id": "example.nebula", "name": "Nebula", "description": "A fictional star chart.",
        "repo": "https://github.com/fictional-search/nebula", "tags": ["astronomy"], "stars": 3})
if scenario in {"interests", "matches"}:
    fixture["profile"] += [app._signal("dock-like", "Dock-like setup", {"dock": 10}, "Fictional display and USB clues"),
                           app._signal("capability-docker", "Container tools", {"docker": 12}, "Fictional installed executable")]
if scenario in {"cards", "density"}:
    fixture["catalog"]["plugins"][0]["previewThumbnail"] = "https://plugins.omarchy.org/assets/img/plugins/fictional-dock.png"
    fixture["catalog"]["plugins"][1]["verificationStatus"] = "unverified"
    fixture["catalog"]["plugins"][2]["previewThumbnail"] = "https://plugins.omarchy.org/assets/img/plugins/fictional-unavailable.png"
    fixture["catalog"]["plugins"][2]["stars"] = 2147483647
    if scenario == "density":
        originals = fixture["catalog"]["plugins"][:]
        for i in range(15):
            original = originals[i % 3]
            fixture["catalog"]["plugins"].append({**original, "id": f"example.density-{i:02d}",
                "name": original["name"] + f" {i + 2}",
                "category": originals[(i // 3) % 3]["category"],
                "description": original["description"] + " A fictional companion for everyday tasks, with configurable shortcuts and clear status."})
base = Path(demo_env("DEMO_ROOT"))
if not base.is_absolute():
    raise SystemExit("OUTFIT_DEMO_ROOT must be a private absolute temporary directory.")
native_ids = ("org.example.omafit-release-fixture", "org.example.omafit-release-fixture-two")
native_urls = ("https://github.com/omafit-vm-fixture/native-one", "https://github.com/omafit-vm-fixture/native-two")
native_repos = {}
if scenario == "native-lifecycle":
    if (demo_env("TEST_VM") != "1" or subprocess.run(
            ["systemd-detect-virt", "--vm"], stdout=subprocess.DEVNULL).returncode
            or os.environ.get("OMARCHY_PATH") != "/home/tester/omarchy-host"
            or base.is_symlink() or base.resolve().parent != Path(os.environ.get("XDG_RUNTIME_DIR", "/nonexistent"))
            or not base.name.startswith("omafit-native-lifecycle-")
            or base.stat().st_uid != os.getuid() or base.stat().st_mode & 0o077):
        raise SystemExit("Native lifecycle fixtures require the isolated disposable VM environment.")
    marker = json.loads((base / "native-fixtures.json").read_text())
    if set(marker) != set(native_ids):
        raise SystemExit("Native lifecycle fixture identities do not match.")
    rows = []
    for identity, url in zip(native_ids, native_urls):
        repository = base / "repos" / identity
        if (repository.is_symlink() or repository.resolve() != repository
                or json.loads((repository / "manifest.json").read_text())["id"] != identity
                or not app.full_sha(marker[identity])):
            raise SystemExit("Native lifecycle fixture repository is invalid.")
        native_repos[url + ".git"] = (identity, str(repository))
        rows.append({**fixture["catalog"]["plugins"][0], "id": identity,
            "name": "Native Lifecycle Fixture " + ("One" if identity == native_ids[0] else "Two"),
            "repo": url, "description": "Harmless local VM widget for production mutation protocol validation.",
            "installNote": "Fictional local repository; disposable VM only.",
            "listingValidatedCommit": marker[identity], "verificationCommit": marker[identity]})
    fixture["catalog"]["plugins"] = rows
store, preferences = app.Store(base / "cache" / app.APP_ID), app.Store(base / "config" / app.APP_ID)
items, generated = app.normalize_catalog(fixture["catalog"])
if scenario == "empty":
    items = []
app.save_catalog(store, items, generated, 1768478400)
search_documents = {}
if search_verify:
    search_documents = {
        "example.dock-helper": (ROOT / "demo/fixtures/README.md").read_text() + "\n\n" + "\n\n".join(
            f"## Fictional operating note {i}\n\nSection {i}: inspect the local device status before changing a setting. "
            "This deterministic paragraph makes the document long enough for keyboard reading checks. "
            "All controls and devices described here are fictional."
            for i in range(1, 17)),
        "example.workspace-map": "# Workspace Map\n\nA MIDI monitor for desktop workspaces.",
        "example.quiet-hours": "# Quiet Hours\n\nA popular fictional utility. "
            "The optional Dock Helper integration supports a MIDI controller during a recording session. "
            "Orbital latch synchronization is described only in this README.",
        "example.nebula": "# Nebula\n\nA fictional star chart with adjustable colors.",
    }
    with app.ReadmeIndex(store, create=True) as index:
        for item in items:
            index.put(app.readme_key(item), {"ok": True, "searchText": app.markdown_text(search_documents[item["id"]])}, 1768478400)
store.write("engagement.json", {"schemaVersion": 1, "fetchedAt": 1768478400,
    "plugins": {item["id"]: {"hearts": index + 2} for index, item in enumerate(items)}}, app.MAX_ENGAGEMENT_BYTES)
if preferences.stamp("preferences.json") is None:
    app.save_preferences(preferences, {**app.DEFAULT_PREFERENCES, "watchHardware": False,
                                      "readmeEnrichment": scenario in {"preview", "cards", "density"}, "readmeIndexing": False,
                                      "marketplaceThumbnails": scenario in {"cards", "density"}
                                        and demo_env("DEMO_THUMBNAILS", "1") != "0"})
fixture_inventory = app.validate_inventory([{"id":"example.dock-helper", "name":"Dock Helper",
    "enabled":scenario in {"installed", "cards", "density"}, "active":scenario in {"installed", "cards", "density"}, "canDisable":True,
    "firstParty":False, "kinds":["bar-widget"], "barSection":"right", "barSectionKnown":True}]) \
    if scenario in {"installed", "disabled", "cards", "density"} else []
app.scan_profile = lambda: (fixture["profile"], ["installed plugins"] if scenario == "failed-inventory"
                           else ["Bluetooth"] if scenario == "interests" else [], fixture_inventory)
app.scan_inventory = lambda: (fixture_inventory, scenario == "failed-inventory")
app.fetch_catalog = lambda: (items, generated)
app.fetch_readme = original["fetch_readme"]

def blocked(*_args, **_kwargs):
    raise ValueError("Fictional demo: network and real system commands are disabled.")

def fixture_bytes(url, host, *_args, **_kwargs):
    # Exercise production fetching/parsing/cache shape without any network I/O.
    allowed = {f'https://raw.githubusercontent.com/{item["owner"]}/{item["repoName"]}/{item["listingCommit"]}/README.md'
               for item in items if item.get("listingCommit")}
    if host == "raw.githubusercontent.com" and url in allowed:
        if search_verify:
            item = next(item for item in items if url.endswith(f'/{item["repoName"]}/{item["listingCommit"]}/README.md'))
            return search_documents[item["id"]].encode()
        return (ROOT / "demo/fixtures/README.md").read_bytes()
    return blocked()

app.fetch_bytes = fixture_bytes
app.fetch_preview_image = blocked
app.run_command = blocked

if scenario == "native-lifecycle":
    def audit(event, **fields):
        # Only explicitly redacted argv may be recorded; never log lifecycle
        # tokens, raw requests/responses or the full process environment.
        row = {"event": event, "time": time.monotonic(), **fields}
        fd = os.open(base / "native-audit.jsonl", os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            os.write(fd, (json.dumps(row) + "\n").encode())
        finally:
            os.close(fd)

    def redacted_argv(argv):
        values = list(argv)
        if len(values) > 3 and values[1] == "shell" and values[2] in {"renewPluginChanges", "endPluginChanges"}:
            values[3] = "<redacted>"
        return values

    def audited_launch(argv):
        effective, environment = original["command_launch"](argv)
        audit("launch", declaredArgv=redacted_argv(argv), effectiveArgv=redacted_argv(effective),
              effectivePath=environment.get("PATH", ""))
        # Observe the actual production launch boundary without changing either
        # its executable selection or its sanitized environment.
        return effective, environment

    def native_command(argv, timeout, maximum):
        command = list(argv)
        operation, identity = "", ""
        if command == [app.COMMANDS["omarchy"], "plugin", "list", "--json"]:
            operation = "inventory"
        elif len(command) >= 3 and command[:2] == [app.COMMANDS["omarchy-shell"], "shell"]:
            method, arguments = command[2], command[3:]
            valid = (method in {"listPlugins", "listShellConfig", "pluginLifecycle"} and not arguments
                or method == "beginPluginChanges" and len(arguments) == 1 and arguments[0].isdigit() and 250 <= int(arguments[0]) <= 15000
                or method == "renewPluginChanges" and len(arguments) == 2 and app.valid_host_token(arguments[0])
                    and arguments[1].isdigit() and 250 <= int(arguments[1]) <= 15000
                or method == "endPluginChanges" and len(arguments) == 1 and app.valid_host_token(arguments[0]))
            if valid:
                operation = method
        elif command[:3] == [app.COMMANDS["omarchy"], "plugin", "add"] and len(command) == 5 and command[4] == "--yes":
            approved = native_repos.get(command[3])
            if approved:
                identity, command[3] = approved
                operation = "add-local-fixture"
        elif len(command) >= 4 and command[:2] == [app.COMMANDS["omarchy"], "plugin"] and command[3] in native_ids:
            identity = command[3]
            if (command[2] == "enable" and (len(command) == 4 or len(command) == 5 and command[4] in {"left", "center", "right"})
                    or command[2] == "disable" and len(command) == 4
                    or command[2] == "remove" and command[4:] == ["--yes"]):
                operation = command[2]
        elif len(command) == 6 and command[0:2] == [app.COMMANDS["git"], "-C"] and command[3:] == ["rev-parse", "--verify", "HEAD"]:
            for candidate in native_ids:
                target = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "omarchy/plugins" / candidate
                if command[2] == str(target):
                    operation, identity = "installed-revision", candidate
        if not operation:
            audit("blocked-command")
            raise ValueError("Native fixture command is outside the fixed VM allowlist.")
        audit("command", operation=operation, pluginId=identity, declaredArgv=redacted_argv(argv))
        # Only the two exact synthetic URL arguments above are substituted.
        # Production command_launch owns executable/PATH resolution. Timeouts,
        # parsing and mutation logic stay real.
        return original["run_command"](command, timeout, maximum)

    app.run_command = native_command
    app.command_launch = audited_launch
    app.scan_inventory = original["scan_inventory"]
    def native_profile():
        inventory, unavailable = app.scan_inventory()
        return fixture["profile"], ["installed plugins"] if unavailable else [], inventory
    app.scan_profile = native_profile
    def native_response(response):
        if response.get("action") in app.PLUGIN_MUTATIONS:
            operation = response.get("operation", {})
            audit("protocol", action=response.get("action"), kind=response.get("event", ""),
                  phase=response.get("phase", ""), pluginId=response.get("pluginId", operation.get("pluginId", "")),
                  ok=response.get("ok"), final=response.get("final", False))
        original["write_response"](response)
    app.write_response = native_response

def fixture_image():
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    pixels = bytearray()
    for y in range(180):
        pixels.append(0)
        for x in range(320):
            header = 20 <= x < 240 and 24 <= y < 40
            tile = 20 <= x < 300 and 64 <= y < 150 and (x - 20) % 96 < 88
            pixels.extend((137, 175, 224) if header else (49, 66, 93) if tile else (24, 31, 46))
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 320, 180, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(pixels))) + chunk(b"IEND", b"")
    return png

def fixture_thumbnails(cache, rows, _revision):
    png = fixture_image()
    result = {}
    for row in rows:
        local = cache.write_blob("thumb-" + "0" * 32 + "-" + "1" * 16 + ".png", png, app.MAX_PREVIEW_IMAGE_BYTES) \
            if row.get("previewThumbnail", "").endswith("/fictional-dock.png") else ""
        result[row["id"]] = {"url": row.get("previewThumbnail", ""), "localSource": local}
    return result

if scenario in {"cards", "density"}:
    app.materialize_thumbnails = fixture_thumbnails
if scenario == "preview":
    def preview_document(item):
        url = f'https://raw.githubusercontent.com/{item["owner"]}/{item["repoName"]}/{item["listingCommit"]}/preview.png'
        return {"ok":True,"content":"A fictional screenshot used to verify separate preview controls.",
                "text":"Fictional preview","summary":"Fictional preview",
                "media":[{"kind":"image","url":url,"label":"Fictional docking controls with readable status panels. The full-size action belongs below this caption, outside the image."}]}
    app.fetch_readme = preview_document
    app.fetch_preview_image = lambda _url: (fixture_image(), "png")
if (scenario in {"interests", "matches"} or search_verify) and preferences.stamp("interests.json") is None:
    criteria = [app.validate_criterion({"id":"interest." + "d" * 32, "kind":"hardware",
                 "label":"Dock accessories", "terms":["dock"], "enabled":True}),
                app.validate_criterion({"kind":"service", "serviceId":"spotify"})]
    preferences.write("interests.json", {"schema":1,"revision":1,"criteria":criteria,
        "ignoredSignals":["dock-like"],"review":{}}, app.MAX_INTEREST_STATE)
    if scenario == "matches":
        app.save_catalog(store, items[1:], generated, 1768478400)
    app.run({"action":"matches"}, store, now=1768478400, preferences_store=preferences)
    app.save_catalog(store, items, generated, 1768478400)
try:
    while True:
        raw = app.read_request(sys.stdin.buffer)
        if not raw:
            break
        request = {}
        try:
            request = app.safe_json_loads(raw, "Fixture request")
            if scenario == "interests" and demo_env("VERIFY_INTERESTS") == "1":
                # Action names only: establish that the redesigned picker uses
                # one explicit save and never the retired preview/edit workflow.
                fd = os.open(base / "interests-actions.jsonl", os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
                try:
                    record = {"action": request.get("action", ""), "time": time.monotonic()}
                    if request.get("action") == "quick-setup":
                        record.update(setupServices=request.get("setupServices", []),
                                      setupServiceFilter=request.get("setupServiceFilter", ""),
                                      setupInterestCriteria=request.get("setupInterestCriteria", []))
                    os.write(fd, (json.dumps(record) + "\n").encode())
                finally:
                    os.close(fd)
            if scenario == "native-lifecycle" and request.get("action") == "diagnostics":
                raise ValueError("Native lifecycle fixture disables unrelated system diagnostics.")
            if request.get("action") in app.PLUGIN_MUTATIONS and (scenario != "native-lifecycle" or request.get("pluginId") not in native_ids):
                raise ValueError("Fictional demo: plugin mutations are disabled.")
            if scenario == "slow" and request.get("action") in {"analyze", "enrich"}:
                time.sleep(2)
            if scenario == "offline" and request.get("action") in {"enrich", "refresh"}:
                raise ValueError("Fictional offline state: cached listings remain usable.")
            result = (app.process_request(raw, store, preferences) if scenario == "native-lifecycle"
                      else app.run(request, store, now=1768478400, preferences_store=preferences))
        except Exception as error:
            result = app.error_response(error, request)
        if search_verify and request.get("action") == "quick-setup":
            with (base / "search-actions.jsonl").open("a") as stream:
                stream.write(json.dumps({"request": request, "response": result}) + "\n")
        if scenario == "interests" and demo_env("VERIFY_INTERESTS") == "1" and request.get("action") == "quick-setup":
            with (base / "interests-results.jsonl").open("a") as stream:
                stream.write(json.dumps({"action": "quick-setup", "ok": result.get("ok"), "setup": result.get("setup", {})}) + "\n")
        if scenario in {"cards", "density"} and request.get("action") == "readme-plugin":
            (base / "readme-response.json").write_text(json.dumps(result, indent=2))
        app.write_response(result)
        if "--serve" not in sys.argv:
            break
finally:
    store.close()
    preferences.close()
