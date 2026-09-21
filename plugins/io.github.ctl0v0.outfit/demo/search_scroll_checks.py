"""Real UI checks called only inside ui_capture.py's isolated VM session."""
import json
import time

ID = "io.github.ctl0v0.outfit"


def verify(run, window, state, output, browse_sort):
    before = json.loads(run("omarchy-shell", "shell", "listPlugins"))
    steps = []
    checks = {}
    audit_path = state / "search-actions.jsonl"
    address = json.dumps("address:" + window["address"])

    def status():
        return json.loads(run("omarchy-shell", ID, "status"))

    def wait_for(predicate, message):
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            if predicate(): return
            time.sleep(0.1)
        raise RuntimeError("Search/scroll: " + message)

    def records():
        return [json.loads(line) for line in audit_path.read_text().splitlines()] if audit_path.exists() else []

    def latest():
        rows = records()
        return rows[-1]["response"].get("setup", {}) if rows else {}

    def move(px, py):
        x, y = window["at"]
        run("hyprctl", "eval", f"hl.dispatch(hl.dsp.cursor.move({{x={x+px},y={y+py}}}))")
        run("wlrctl", "pointer", "move", "1", "0")

    def click(px, py):
        move(px, py)
        run("wlrctl", "pointer", "click")
        time.sleep(0.2)

    def keys(*names):
        run("wtype", *sum((["-k", name] for name in names), []))
        steps.append({"keys": list(names)})
        time.sleep(0.2)

    def image(label, primary=False):
        path = output if primary else output.with_name(output.stem + "--" + label + ".png")
        if path.exists(): raise RuntimeError("Refusing search evidence overwrite")
        move(window["size"][0] // 2, 70)
        time.sleep(0.25)
        x, y = window["at"]
        width, height = window["size"]
        run("grim", "-g", f"{x},{y} {width}x{height}", str(path))
        steps.append({"image": str(path), "label": label})

    def resize(width, height):
        nonlocal window
        run("hyprctl", "dispatch", 'hl.dsp.window.resize({window=' + address + f',x={width},y={height}' + '})')
        run("hyprctl", "dispatch", 'hl.dsp.window.center({window=' + address + '})')
        time.sleep(0.4)
        window = next(row for row in json.loads(run("hyprctl", "clients", "-j")) if row["address"] == window["address"])
        if window["size"] != [width, height]: raise RuntimeError("Search window resize failed")

    def query(text):
        run("wtype", "-M", "ctrl", "-k", "f", "-m", "ctrl")
        run("wtype", "-M", "ctrl", "a", "-m", "ctrl", *([text] if text else ["-k", "BackSpace"]))
        wait_for(lambda: latest().get("query") == text and status()["ready"] and not status()["queryBusy"], "query did not settle: " + text)
        result = latest()
        steps.append({"query": text, "sort": result.get("sort"), "search": result.get("search"),
                      "rows": [{k: row.get(k) for k in ("id", "searchReason", "searchSnippet", "stars")} for row in result["rows"]]})
        return result

    def ids(result):
        return [row["id"] for row in result["rows"]]

    try:
        result = query("Dock Helper")
        assert result["sort"] == "relevance" and result["search"]["mode"] == "complete"
        assert ids(result) == ["example.dock-helper", "example.quiet-hours"]
        assert not result["rows"][0]["searchSnippet"] and "dock helper" in result["rows"][1]["searchSnippet"].lower()
        assert result["rows"][1]["stars"] > result["rows"][0]["stars"]
        checks["exactNameBeatsPopularReadme"] = True
        image("results-wide", primary=True)
        resize(760, 540)
        image("results-compact")
        resize(1180, 760)

        result = query("MIDI controller")
        assert set(ids(result)) == {"example.dock-helper", "example.quiet-hours"}
        assert result["search"]["mode"] == "complete" and result["search"]["suggestion"] is None
        checks["allWordsExcludePartialWorkspace"] = True
        click(1060, 110)  # Sort dropdown, currently Best match.
        keys("Down", "Down", "Return")  # Most starred.
        wait_for(lambda: latest().get("sort") == "stars" and status()["ready"], "manual Most starred sort")
        assert ids(latest())[0] == "example.quiet-hours"
        result = query("Dock Helper")
        assert result["sort"] == "stars" and ids(result)[0] == "example.quiet-hours"
        result = query("")
        assert result["sort"] == browse_sort
        checks["manualSortSurvivesTypingAndClearRestoresBrowseSort"] = True

        result = query("MIDI telescope")
        assert result["sort"] == "relevance" and result["search"]["mode"] == "partial"
        assert result["search"]["suggestion"] is None
        assert all(row["searchReason"].startswith("Partial match (1/2 words)") for row in result["rows"])
        checks["partialFallbackExplicit"] = True
        image("partial-results")
        result = query("Neblua")
        assert result["total"] == 0 and result["query"] == "Neblua" and result["search"]["suggestion"]["query"] == "Nebula"
        image("explicit-typo")
        click(435, 156)  # Explicit suggestion button below the search row.
        wait_for(lambda: latest().get("query") == "Nebula" and status()["ready"], "explicit suggestion did not apply")
        assert ids(latest()) == ["example.nebula"]
        checks["typoRequiresExplicitClick"] = True

        query("Dock Helper")
        click(460, 245)  # First matching card, production detail route.
        wait_for(lambda: status()["selectedPlugin"] == "example.dock-helper", "card did not open detail")
        wait_for(lambda: (state / "readme-response.json").exists(), "long production README did not load")
        time.sleep(0.4)
        image("detail-before-down")
        keys("Down")  # Initial focus remains Back; no pointer focus repair.
        image("detail-after-down")
        keys("Up", "Home", "Next")  # PageDown into documentation.
        image("readme-before-pagedown")
        click(350, 330)  # Unselected, read-only README prose, not a link.
        keys("Next")
        image("readme-after-pagedown")
        if not status()["opened"] or status()["selectedPlugin"] != "example.dock-helper":
            raise RuntimeError("Reading keys closed or changed the detail")
        checks["readingKeysKeepDetailOpen"] = True
        if json.loads(run("omarchy-shell", "shell", "listPlugins")) != before:
            raise RuntimeError("Search/scroll changed native plugin inventory")
        checks["nativeInventoryUnchanged"] = True
        report = {"pass": True, "checks": checks, "steps": steps,
            "scrollVerdict": "Compare before/after images; no production scroll instrumentation was injected."}
        output.with_suffix(".search-verification.json").write_text(json.dumps(report, indent=2))
        output.with_suffix(".search-actions.json").write_text(json.dumps(records(), indent=2))
        return report
    except Exception as error:
        image("failure")
        output.with_suffix(".search-actions.json").write_text(json.dumps(records(), indent=2))
        output.with_suffix(".search-verification.json").write_text(json.dumps({"pass":False,"error":repr(error),"checks":checks,"steps":steps},indent=2))
        raise
