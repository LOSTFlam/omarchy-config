#!/usr/bin/env python3
"""Focused native performance probe; runs only in the existing disposable VM.

Host: python3 tests/vm/performance_check.py --work <VM work> --evidence <new dir>
Uses native Quickshell/Omarchy with derived fixture entry points, real Process
objects, and isolated fictional backend data. Never edits candidate source bytes.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tarfile
import time
import traceback

APP = "io.github.ctl0v0.outfit"
OLD = "io.github.ctl0v0.omafit"

FIND = '''
  function find(item, name) {
    if (!item) return null
    if (item.objectName === name) return item
    var children = Array.from(item.children || []).concat(Array.from(item.resources || []))
    if (item.contentItem && item.contentItem !== item && children.indexOf(item.contentItem) < 0) children.push(item.contentItem)
    for (var parser of [item.stdout, item.stderr])
      if (parser && children.indexOf(parser) < 0) children.push(parser)
    for (var child of children) { var match = find(child, name); if (match) return match }
    return null
  }
'''
SERVICE = '''import QtQuick
import Quickshell.Io
Service {
  id: probe
  property var probeResult: null
  property var probeProgress: []
''' + FIND + '''
  BackgroundWorker {
    id: transport
    helperPath: Qt.resolvedUrl("transport.py").toString().replace("file://", "")
    onFinished: function(result, request) { probe.probeResult = result }
    onProgress: function(event, request) { probe.probeProgress = probe.probeProgress.concat([event]) }
  }
  IpcHandler {
    target: "outfit-performance-service"
    function evaluate(code: string): string {
      try { return JSON.stringify({ok:true,value:eval(code)}) }
      catch(error) { return JSON.stringify({ok:false,error:String(error)}) }
    }
  }
}
'''
PANEL = '''import QtQuick
import Quickshell.Io
import "ui"
OutfitApp {
  id: probe
''' + FIND + '''
  IpcHandler {
    target: "outfit-performance-panel"
    function evaluate(code: string): string {
      try { return JSON.stringify({ok:true,value:eval(code)}) }
      catch(error) { return JSON.stringify({ok:false,error:String(error)}) }
    }
  }
}
'''
TRANSPORT = '''import json, os, signal, sys, time
from pathlib import Path
request = json.loads(sys.stdin.readline())
mode = request.get("mode", "chunks")
Path(__file__).with_name("transport-pid.json").write_text(json.dumps({"pid":os.getpid(),"mode":mode}))
if mode == "timeout":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    time.sleep(120)
value = {"ok":True,"action":request["action"],"generation":request["generation"],"text":"雪 café 😀 Ελληνικά é","payload":"x" * 131072}
raw = json.dumps(value, ensure_ascii=True).encode() + (b"" if mode == "eof" else b"\\n")
if mode == "chunks":
    progress = dict(value, responseKind="progress", final=False, sequence=1, payload="")
    raw = json.dumps(progress, ensure_ascii=True).encode() + b"\\n" + raw
    for offset in range(0,len(raw),37):
        os.write(1,raw[offset:offset+37])
        if offset < 2000: time.sleep(.001)
else: os.write(1,raw)
'''


def digest(path):
    if path.is_symlink():
        return {"link": os.readlink(path)}
    if path.is_file():
        return {"sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "mode": path.stat().st_mode & 0o777}
    if path.is_dir():
        return {str(p.relative_to(path)): digest(p) for p in sorted(path.rglob("*")) if not p.is_dir() or p.is_symlink()}
    return None


def remove(path):
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.exists():
        shutil.rmtree(path)


def host(args):
    source = Path(__file__).resolve().parents[2]
    meta = json.loads((args.work / "bootstrap.json").read_text())
    ssh = ["ssh", "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
           "-o", f"UserKnownHostsFile={args.work}/known_hosts", "-i", str(args.work / "ssh-key"),
           "-p", str(meta["sshPort"]), f'{meta["username"]}@127.0.0.1']
    root = "/home/tester/" + args.evidence.name
    def remote(argv, **kwargs):
        return subprocess.run([*ssh, shlex.join(argv)], **kwargs)
    assert args.evidence.parent.is_dir() and not args.evidence.exists()
    args.evidence.mkdir(mode=0o700)
    remote(["python3", "-c", f"from pathlib import Path; p=Path({root!r}); assert p.parent.is_dir() and not p.exists(); p.mkdir(mode=0o700)"], check=True)
    names = subprocess.check_output(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=source).decode().split("\0")
    hashes = {}
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w:gz") as archive:
        for name in sorted(set(names)):
            path = source / name
            if not name or not path.is_file() or name.startswith("test-results/"):
                continue
            raw = path.read_bytes()
            hashes[name] = hashlib.sha256(raw).hexdigest()
            info = tarfile.TarInfo("source/" + name)
            info.size, info.mode = len(raw), path.stat().st_mode & 0o777
            archive.addfile(info, io.BytesIO(raw))
        raw = json.dumps(hashes, indent=2).encode()
        info = tarfile.TarInfo("source-hashes.json")
        info.size = len(raw)
        archive.addfile(info, io.BytesIO(raw))
    (args.evidence / "source-hashes.json").write_text(json.dumps(hashes, indent=2))
    remote(["tar", "-xz", "-C", root], input=stream.getvalue(), check=True)
    argv = ["env", "OUTFIT_TEST_VM=1", "python3", root + "/source/tests/vm/session_exec.py",
            "python3", root + "/source/tests/vm/performance_check.py", "--guest", root]
    if args.continued: argv.append("--continued")
    if args.interactive: argv.append("--interactive")
    if args.probe_only: argv.append("--probe-only")
    (args.evidence / "command.json").write_text(json.dumps(argv, indent=2))
    with (args.evidence / "driver.log").open("w") as log:
        result = remote(argv, stdout=log, stderr=subprocess.STDOUT)
    data = remote(["tar", "-cz", "-C", root, "evidence"], stdout=subprocess.PIPE, check=True).stdout
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        archive.extractall(args.evidence, filter="data")
    drift = {name: {"tested": value, "current": hashlib.sha256((source / name).read_bytes()).hexdigest() if (source / name).is_file() else None}
             for name, value in hashes.items() if not (source / name).is_file() or hashlib.sha256((source / name).read_bytes()).hexdigest() != value}
    (args.evidence / "source-drift.json").write_text(json.dumps({"production": {n:v for n,v in drift.items() if not n.startswith("tests/")},
                                                               "tests": {n:v for n,v in drift.items() if n.startswith("tests/")}}, indent=2))
    print(json.dumps({"exit": result.returncode, "evidence": str(args.evidence), "guest": root}))
    return result.returncode


def guest(root):
    home, hostroot = Path.home(), Path(os.environ["OMARCHY_PATH"])
    assert os.environ.get("OUTFIT_TEST_VM") == "1" and home == Path("/home/tester")
    assert hostroot == home / "omarchy-host"
    assert subprocess.check_output(["systemd-detect-virt", "--vm"], text=True).strip() == "kvm"
    evidence, backup, source = root / "evidence", root / "backup", root / "source"
    evidence.mkdir(); backup.mkdir(mode=0o700)
    cfg = home / ".config/omarchy/shell.json"
    plugins = cfg.parent / "plugins"
    environment = dict(os.environ, PATH=str(hostroot / "bin") + ":" + os.environ["PATH"], PYTHONDONTWRITEBYTECODE="1")
    report = {"checks": {}, "samples": {}, "failures": []}
    shell = None
    def save():
        (evidence / "report.json").write_text(json.dumps(report, indent=2))
    def run(*argv, check=True, timeout=60):
        return subprocess.run(list(map(str, argv)), capture_output=True, text=True, check=check, env=environment, timeout=timeout)
    def ipc(*argv, check=True):
        return run(hostroot / "bin/omarchy-shell", *argv, check=check).stdout.strip()
    def status(identity=APP):
        try: return json.loads(ipc(identity, "status", check=False))
        except (ValueError, subprocess.SubprocessError): return {}
    def evaluate(code, panel=False):
        value = json.loads(ipc("outfit-performance-panel" if panel else "outfit-performance-service", "evaluate", code))
        if not value["ok"]: raise RuntimeError(value)
        return value.get("value")
    def wait(fn, label, seconds=30):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            value = fn()
            if value: return value
            time.sleep(.15)
        raise RuntimeError("Timed out: " + label)
    def check(name, passed, detail=None):
        report["checks"][name] = {"passed": bool(passed), "detail": detail}; save()
        if not passed: raise AssertionError(name)
    def stop():
        nonlocal shell
        run("quickshell", "kill", "-p", hostroot / "shell", "--any-display", check=False)
        if shell:
            try: shell.wait(15)
            except subprocess.TimeoutExpired: shell.terminate(); shell.wait(10)
            shell = None
        time.sleep(.5)
    def alive(pid): return pid > 0 and Path(f"/proc/{pid}").exists()
    def ticks(pid):
        fields = Path(f"/proc/{pid}/stat").read_text().split(")", 1)[1].split()
        return int(fields[11]) + int(fields[12])
    def starts():
        path = root / "ui-state/performance-audit.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
    def sample(label):
        value = evaluate('({sleeping:probe.sleeping,paused:probe.presentationPaused,blocked:probe.sleepBlocked,delay:probe.sleepDelay,queryPid:find(probe,"queryWorker").processId,queryRunning:find(probe,"queryWorker").running,requestActive:probe.requestActive,rows:probe.rows.length,setupRows:probe.setupRows.length,readmeBlocks:probe.readmeBlocks.length,readmeContent:probe.readmeContent.length,discoveryRows:probe.discoveryRows.length,matches:probe.matches.rows.length,payload:probe.editorSessionPayload,preferences:probe.preferences,pendingSearch:probe.pendingSearch,pendingSetup:probe.pendingSetup,pendingReadme:probe.pendingReadmeId})')
        value.update(status=status(), monotonic=time.monotonic(), helperAuditRecords=len(starts()))
        report["samples"][label] = value; save(); return value
    def open_panel():
        evaluate('probe.openEditor()')
        wait(lambda: status().get("canBrowse") and status().get("inventoryReady"), "browse/inventory")
        wait(lambda: evaluate('probe.setupRows.length > 0 && !probe.requestActive'), "browse rows settled")
    def mailbox_loop(context):
        (evidence / "ready").write_text("Additional focused checks may use command.json; finish restores.\n")
        deadline = time.monotonic() + 1800
        while time.monotonic() < deadline:
            mailbox = root / "command.json"
            if not mailbox.exists(): time.sleep(.2); continue
            command = json.loads(mailbox.read_text()); mailbox.unlink()
            if command["action"] == "finish": break
            if command["action"] == "evaluate":
                value = evaluate(command["code"], command.get("panel", False))
            elif command["action"] == "python":
                exec(compile(command["code"], "<native-performance-check>", "exec"), context)
                value = context.get("result")
            else: raise ValueError(command)
            (evidence / (command["label"] + ".json")).write_text(json.dumps(value, indent=2))
    saved = {"paths": [], "config": digest(cfg), "workspace": json.loads(run("hyprctl", "activeworkspace", "-j").stdout)["id"],
             "cursor": json.loads(run("hyprctl", "cursorpos", "-j").stdout), "openedOld": status(OLD).get("opened", False)}
    shutil.copy2(cfg, backup / "shell.json")
    report["host"] = {"packages": run("pacman", "-Q", "omarchy", "quickshell", "qt6-base", check=False).stdout,
                      "root": str(hostroot), "nativeUpdater": digest(hostroot / "bin/omarchy-plugin-update")}
    report["host"]["files"] = digest(hostroot / "shell")
    def interrupted(*_): raise RuntimeError("Interrupted; restoring")
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP): signal.signal(sig, interrupted)
    try:
        stop()
        for index, path in enumerate(base / identity for base in (plugins, home / ".config", home / ".cache", home / ".local/state") for identity in (APP, OLD)):
            row = {"path": str(path), "backup": str(backup / str(index)), "digest": digest(path)}
            saved["paths"].append(row)
            if path.exists() or path.is_symlink(): shutil.move(str(path), row["backup"])
            (root / "recovery.json").write_text(json.dumps(saved, indent=2))
        fixture = root / "fixture"
        shutil.copytree(source, fixture)
        (fixture / "ProbeService.qml").write_text(SERVICE)
        (fixture / "ProbePanel.qml").write_text(PANEL)
        (fixture / "transport.py").write_text(TRANSPORT)
        manifest = json.loads((fixture / "manifest.json").read_text())
        manifest["entryPoints"].update(service="ProbeService.qml", panel="ProbePanel.qml")
        (fixture / "manifest.json").write_text(json.dumps(manifest))
        worker = fixture / "demo/fixture_worker.py"
        text = worker.read_text()
        text = text.replace('try:\n    while True:', '''
def performance_audit(kind, **fields):
    with (base / "performance-audit.jsonl").open("a") as stream:
        stream.write(json.dumps({"kind":kind,"pid":os.getpid(),"time":time.monotonic(),**fields}) + "\\n")
performance_audit("start", serve="--serve" in sys.argv)
try:
    while True:''')
        text = text.replace('request = app.safe_json_loads(raw, "Fixture request")', 'request = app.safe_json_loads(raw, "Fixture request")\n            performance_audit("request", action=request.get("action"))')
        worker.write_text(text)
        (plugins / APP).symlink_to(fixture)
        config = json.loads(cfg.read_text())
        for owner, key in [(config, "plugins"), *[(config["bar"]["layout"], k) for k in config["bar"]["layout"]]]:
            owner[key] = [x for x in owner.get(key, []) if (x.get("id") if isinstance(x, dict) else x) not in {APP, OLD}]
        config["bar"]["layout"]["right"].append({"id": APP})
        config["idle"] = {"screensaver": 0, "lock": 0}
        cfg.write_text(json.dumps(config))
        env = dict(environment, OUTFIT_DEMO_ROOT=str(root / "ui-state"), OUTFIT_DEMO_SCENARIO="installed",
                   OUTFIT_DEMO_THUMBNAILS="0", https_proxy="http://127.0.0.1:9", http_proxy="http://127.0.0.1:9")
        with (evidence / "shell.log").open("w") as log:
            shell = subprocess.Popen(["quickshell", "-n", "-p", str(hostroot / "shell")], env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        wait(lambda: bool(status()), "hosted Service load")
        report["shellPid"] = shell.pid
        if args.probe_only:
            open_panel()
            mailbox_loop(dict(globals(), **locals()))
            return 0
        # Actual Process transport, including final JSON delivered only at EOF.
        for mode in (() if args.continued else ("chunks", "eof")):
            evaluate('probe.probeResult=null; probe.probeProgress=[]; transport.submit("probe",{mode:' + json.dumps(mode) + '})')
            wait(lambda: evaluate('probe.probeResult !== null'), "native transport " + mode)
            result = evaluate('({ok:probe.probeResult.ok,text:probe.probeResult.text,length:(probe.probeResult.payload||"").length,progress:probe.probeProgress.length,active:transport.active,pid:find(transport,"backgroundWorker").processId,error:probe.probeResult.error})')
            check("transport-" + mode, result.get("ok") and result.get("text") == "雪 café 😀 Ελληνικά é" and result.get("length") == 131072 and not result["active"], result)
        # Fixture-only timeout override; production worker stop/kill logic is real.
        if not args.continued:
            evaluate('probe.probeResult=null; find(transport,"backgroundDeadline").interval=300; transport.submit("probe",{mode:"timeout"})')
            time.sleep(.2)
            pid = json.loads((fixture / "transport-pid.json").read_text())["pid"]
            wait(lambda: evaluate('probe.probeResult !== null'), "timeout cleanup", 8)
            check("transport-timeout-no-live-helper", not alive(pid) and not evaluate('transport.active'), {"pid": pid, "result": evaluate('probe.probeResult')})
            evaluate('probe.probeResult=null; find(transport,"backgroundWorker").command=["/nonexistent/outfit-performance"]; transport.submit("probe",{})')
            wait(lambda: evaluate('probe.probeResult !== null'), "spawn failure cleanup", 6)
            check("transport-spawn-failure-clean", not evaluate('transport.active') and not evaluate('find(transport,"backgroundWorker").processId'), evaluate('probe.probeResult'))
        open_panel()
        if args.continued: evaluate('probe.sleepDelay=350')
        before = sample("open-before-grace")
        check("fixture-short-grace" if args.continued else "actual-default-grace", before["delay"] == (350 if args.continued else 30000) and before["queryPid"] > 0, before["queryPid"])
        # UI-owned drafts and navigation state go through the actual close path.
        evaluate('probe.settingsTouched=true; probe.draftReadmes=true; probe.rememberPanel(); probe.close()', panel=True)
        closed = sample("immediate-close")
        check("immediate-close-pauses-optional", closed["paused"] and closed["status"]["optionalWorkers"] == 0 and closed["pendingSearch"] is None and closed["pendingSetup"] is None and not closed["pendingReadme"], closed)
        if not args.continued:
            time.sleep(27)
            late = sample("closed-before-30s")
            check("query-survives-grace", not late["sleeping"] and alive(before["queryPid"]), late)
        wait(lambda: status().get("sleeping"), "close sleep", 8)
        wait(lambda: not alive(before["queryPid"]), "query PID retired", 5)
        asleep = sample("asleep-after-grace")
        check("sleep-retires-heavy-state", not asleep["queryRunning"] and not asleep["rows"] and not asleep["setupRows"] and not asleep["readmeBlocks"] and not asleep["readmeContent"] and not asleep["discoveryRows"] and not asleep["matches"], asleep)
        count, cpu, start = len(starts()), ticks(shell.pid), time.monotonic()
        time.sleep(1 if args.continued else 60)
        idle = sample("closed-short-idle" if args.continued else "closed-60s-idle")
        measurement = {"seconds": time.monotonic()-start, "shellCpuTicks": ticks(shell.pid)-cpu, "ticksPerSecond": os.sysconf("SC_CLK_TCK"), "shellPid": shell.pid, "retiredQueryPid": before["queryPid"], "auditRecordsBefore":count,"auditRecordsAfter":len(starts())}
        check("closed-short-no-helper-starts" if args.continued else "closed-60s-no-helper-starts", len(starts()) == count and idle["status"]["optionalWorkers"] == 0 and not idle["queryRunning"], measurement)
        open_panel()
        reopened = sample("reopened")
        draft = evaluate('({touched:probe.settingsTouched,readmes:probe.draftReadmes})', panel=True)
        check("fresh-open-restores-browse-drafts", reopened["setupRows"] > 0 and reopened["preferences"] == before["preferences"] and draft == {"touched":True,"readmes":True}, {"draft":draft,"queryPid":reopened["queryPid"]})
        evaluate('probe.sleepDelay=350')
        for cycle in range(3):
            pid = sample("cycle-" + str(cycle) + "-open")["queryPid"]
            evaluate('probe.close()', panel=True)
            wait(lambda: status().get("sleeping") and not alive(pid), "short fixture grace")
            sample("cycle-" + str(cycle) + "-asleep")
            open_panel()
        check("three-additional-open-close-cycles", True, {"fixtureSleepDelayMs":350})
        # Large Updates uses production ListView, with fictional state only.
        for count in (1000, 2000):
            evaluate('var fictionalRows=[]; for(var idx=0;idx<' + str(count) + ';idx++) fictionalRows.push({id:"fictional.performance."+idx,name:"Fictional "+String(idx).padStart(4,"0"),state:"current",installedVersion:"1.0.0",availableVersion:"1.0.0",installedRevision:"1".repeat(40),availableRevision:"1".repeat(40),reason:"Fictional status explanation",canUpdate:false}); probe.updates=fictionalRows; probe.updatesLoaded=true')
            evaluate('probe.setupStage="updates"', panel=True)
            wait(lambda:evaluate('find(probe,"updatesPage").filteredRows.length',panel=True)==count,'Updates replacement model')
            result = evaluate('var page=find(probe,"updatesPage"); ({rows:page.filteredRows.length,delegates:page.instantiatedRowCount})', panel=True)
            check("virtual-updates-" + str(count), result["rows"] == count and 0 < result["delegates"] < 100, result)
        evaluate('find(probe,"updatesPage").focusRow("fictional.performance.0","explain")', panel=True)
        run("wtype", "-k", "Return")
        time.sleep(.3)
        check("keyboard-expands-update", evaluate('find(probe,"updatesPage").expandedIds["fictional.performance.0"] === true', panel=True))
        run("wtype", "-k", "Down")
        time.sleep(.3)
        check("keyboard-next-row-focus", evaluate('find(probe,"updatesPage").focusedId', panel=True) == "fictional.performance.1")
        save()
        if args.interactive:
            mailbox_loop(dict(globals(), **locals()))
    except Exception:
        report["failures"].append(traceback.format_exc()); save()
        report["failureStatus"] = status()
        try:
            report["failureService"] = evaluate('({error:probe.error,action:probe.activeAction,queryStopping:probe.queryStopping,cacheLoaded:probe.cacheLoaded,setupRows:probe.setupRows.length,setupError:probe.setupError})')
        except Exception:
            pass
        save()
    finally:
        stop()
        for row in saved["paths"]:
            path = Path(row["path"]); remove(path)
            if row["digest"] is not None: shutil.move(row["backup"], path)
            report["checks"]["restored-" + str(path)] = {"passed": digest(path) == row["digest"]}
        shutil.copy2(backup / "shell.json", cfg)
        run(hostroot / "bin/omarchy-restart-shell")
        wait(lambda: bool(status(OLD)), "original runtime restored")
        if saved["openedOld"]: ipc("shell", "summon", OLD, "{}")
        run("hyprctl", "eval", 'hl.dispatch(hl.dsp.focus({workspace=' + json.dumps(str(saved["workspace"])) + '}))')
        c = saved["cursor"]
        run("hyprctl", "eval", f'hl.dispatch(hl.dsp.cursor.move({{x={c["x"]},y={c["y"]}}}))')
        report["checks"]["restored-config-bytes-mode"] = {"passed": digest(cfg) == saved["config"], "detail": digest(cfg)}
        report["checks"]["restored-original-runtime"] = {"passed": bool(status(OLD)) and not status(APP)}
        restoration = {k:v for k,v in report["checks"].items() if k.startswith("restored-")}
        (evidence / "restoration.json").write_text(json.dumps(restoration, indent=2))
        if all(v["passed"] for v in restoration.values()):
            (root / "recovery.json").unlink(); (evidence / "finished").write_text("restored\n")
        log = (evidence / "shell.log").read_text()
        report["qmlWarnings"] = [line for line in log.splitlines() if any(s in line for s in ("TypeError", "ReferenceError", "Binding loop", "Cannot assign", "Unable to load configuration", "Syntax error"))]
        audit = root / "ui-state/performance-audit.jsonl"
        if audit.exists(): shutil.copy2(audit, evidence / audit.name)
        save()
        if not all(v["passed"] for v in restoration.values()):
            raise RuntimeError("Guest restoration failed; recovery.json retained")
        if report["qmlWarnings"]:
            raise RuntimeError("Native QML errors recorded in report.json")
    return int(bool(report["failures"]) or any(not v["passed"] for v in report["checks"].values()))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path)
    parser.add_argument("--evidence", type=Path)
    parser.add_argument("--guest", type=Path)
    parser.add_argument("--continued", action="store_true", help="Skip already-recorded transport and 30s/60s checks; use 350ms fixture grace")
    parser.add_argument("--interactive", action="store_true", help="Hold the restoration group open for additional focused mailbox checks")
    parser.add_argument("--probe-only", action="store_true", help="Run only additional mailbox probes inside a restoration group")
    args = parser.parse_args()
    if args.guest:
        raise SystemExit(guest(args.guest))
    if not args.work or not args.evidence: parser.error("--work and --evidence are required")
    raise SystemExit(host(args))
