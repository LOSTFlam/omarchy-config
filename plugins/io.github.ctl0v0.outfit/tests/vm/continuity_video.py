#!/usr/bin/env python3
"""Disposable-VM native lifecycle video and lease evidence; never restarts the shell.

Run via session_exec.py. Only the fictional release fixture is installed/removed.
Lease tokens remain in memory and never enter logs or reports.
"""
import argparse
import bisect
import json
import os
from pathlib import Path
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = "org.example.omafit-release-fixture"
APP = "io.github.ctl0v0.outfit"
TITLE = "Outfit - Plugin Manager"


def run(*argv, timeout=60, env=None):
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"Timed out: {Path(argv[0]).name}") from None
    if result.returncode:
        # argv can contain lease tokens. Do not expose argv, stdout or stderr.
        raise RuntimeError(f"Command failed: {Path(argv[0]).name} (exit {result.returncode})")
    return result.stdout.strip()


def ipc(method, *args):
    raw = run("omarchy-shell", "shell", method, *args)
    try:
        return json.loads(raw)
    except ValueError:
        raise RuntimeError(f"Non-JSON IPC result: {method}") from None


def require(value, message):
    if not value:
        raise RuntimeError(message)


def wait_for(predicate, description, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.1)
    raise RuntimeError(f"Timed out waiting for {description}")


def status():
    return ipc("pluginLifecycle")


def settled():
    current = status()
    return (not any(current[k] for k in ("held", "pending", "scanning", "reconciling"))
            and current["settledGeneration"] >= current["generation"] and not current["scanError"])


def widget_visible():
    return any(row.get("id") == FIXTURE and row.get("visible") and row.get("itemVisible")
               and row.get("width", 0) > 0 for row in ipc("debugBarGeometry"))


def surfaces():
    clients = json.loads(run("hyprctl", "clients", "-j", timeout=5))
    layers = json.loads(run("hyprctl", "layers", "-j", timeout=5))
    apps = [c for c in clients if c.get("title") == TITLE and c.get("mapped") and not c.get("hidden")]
    all_layers = [row for monitor in layers.values() for rows in monitor.get("levels", {}).values() for row in rows]
    return {"windows": sorted(c["address"] for c in apps), "pids": sorted(c["pid"] for c in apps),
            "backgrounds": sorted(r["address"] for r in all_layers if r.get("namespace") == "omarchy-background"),
            "bars": sorted(r["address"] for r in all_layers if r.get("namespace") == "omarchy-bar")}


class Recorder:
    def __init__(self, directory, mode):
        self.directory, self.mode = directory, mode
        self.frames = []
        self.stop_event = threading.Event()
        self.failure = ""
        self.native = False
        self.thread = None
        self.process = None
        self.log = None
        self.fps = 12
        self.started = None
        self.video = directory / "continuity-native.mp4"
        self.mechanism = ""
        self.native_attempt = {}

    def native_pids(self):
        result = subprocess.run(["pgrep", "-f", "^gpu-screen-recorder"], capture_output=True, text=True)
        return result.stdout.split()

    def start(self):
        require(not self.native_pids(), "A recording is already active")
        if self.mode == "auto":
            debug = Path("/tmp/omarchy-screenrecord.log")
            offset = debug.stat().st_size if debug.exists() else 0
            environment = dict(os.environ, OMARCHY_SCREENRECORD_DIR=str(self.directory.parent),
                               OMARCHY_SCREENRECORD_DEBUG="true")
            self.started = time.monotonic()
            with (self.directory / "native-recording-command.log").open("w") as log:
                command = subprocess.Popen(["omarchy", "screenrecord", "--fullscreen"],
                                           stdout=log, stderr=log, env=environment)
                try:
                    result = command.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    command.terminate()
                    command.wait(timeout=5)
                    for pid in self.native_pids():
                        os.kill(int(pid), signal.SIGINT)
                    wait_for(lambda: not self.native_pids(), "owned native recorder shutdown", 10)
                    raise RuntimeError("Native recorder startup timed out; inspect before retrying") from None
            if debug.exists():
                with debug.open("rb") as stream:
                    stream.seek(offset)
                    (self.directory / "native-recording-debug.log").write_bytes(stream.read())
            self.native_attempt = {"exitCode": result, "recorderRunning": bool(self.native_pids())}
            if self.native_pids():
                self.native = True
                self.native_env = environment
                self.native_video = Path("/tmp/omarchy-screenrecord-filename").read_text().strip()
                self.mechanism = "omarchy screenrecord --fullscreen (native CPU fallback enabled)"
                return
        self.mechanism = "software fallback: grim PPM image stream -> ffmpeg libx264, nominal 12 fps, no audio"
        self.log = (self.directory / "software-recording.log").open("w")
        self.process = subprocess.Popen([
            "ffmpeg", "-hide_banner", "-loglevel", "warning", "-nostdin", "-n",
            "-f", "image2pipe", "-framerate", str(self.fps), "-vcodec", "ppm", "-i", "pipe:0",
            "-an", "-c:v", "libx264", "-preset", "ultrafast", "-crf", "20",
            "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(self.video)],
            stdin=subprocess.PIPE, stdout=self.log, stderr=self.log)
        self.started = time.monotonic()

        def record():
            try:
                while not self.stop_event.is_set():
                    started = time.monotonic()
                    image = subprocess.run(["grim", "-t", "ppm", "-"], capture_output=True, timeout=5)
                    if image.returncode or not image.stdout.startswith(b"P6"):
                        raise RuntimeError("grim PPM capture failed")
                    self.process.stdin.write(image.stdout)
                    self.process.stdin.flush()
                    self.frames.append({"index": len(self.frames), "time": started})
                    self.stop_event.wait(max(0, self.started + len(self.frames) / self.fps - time.monotonic()))
            except Exception as error:
                self.failure = type(error).__name__

        self.thread = threading.Thread(target=record, daemon=True)
        self.thread.start()
        wait_for(lambda: len(self.frames) >= 3 or self.failure, "initial software video frames", 10)
        require(not self.failure, "Software capture failed")

    def stop(self):
        if self.native:
            run("omarchy", "screenrecord", "--stop-recording", timeout=60, env=self.native_env)
            require(not self.native_pids(), "Native recorder did not stop")
            shutil.copy2(self.native_video, self.video)
        elif self.thread:
            self.stop_event.set()
            self.thread.join(timeout=10)
            require(not self.thread.is_alive(), "Software capture did not stop")
            self.process.stdin.close()
            result = self.process.wait(timeout=30)
            self.log.close()
            require(result == 0 and not self.failure, "Software recorder failed to finalize")
        require(self.video.is_file() and self.video.stat().st_size > 0, "Video artifact missing")

    def video_time(self, monotonic):
        if self.frames:
            index = bisect.bisect_left([row["time"] for row in self.frames], monotonic)
            return min(index, len(self.frames) - 1) / self.fps
        return max(0, monotonic - self.started - 0.1)


class Evidence:
    def __init__(self, directory):
        self.directory = directory
        self.phase = "baseline"
        self.samples, self.checks, self.marks, self.tokens = [], [], [], []
        self.stop_event = threading.Event()
        self.baseline = surfaces()
        require(all(self.baseline[key] for key in ("windows", "backgrounds", "bars")), "Visible Outfit/background/bar required")

    def start(self):
        def sample():
            while not self.stop_event.is_set():
                timestamp = time.monotonic()
                try:
                    row = surfaces()
                except Exception:
                    row = {"probeError": True}
                self.samples.append({"time": timestamp, "phase": self.phase, **row})
                self.stop_event.wait(0.04)
        self.thread = threading.Thread(target=sample, daemon=True)
        self.thread.start()

    def stop(self):
        self.stop_event.set()
        self.thread.join(timeout=10)

    def check(self, name, condition, **details):
        self.checks.append({"name": name, "ok": bool(condition), **details})
        require(condition, name)

    def mark(self, label):
        self.phase = label
        started = time.monotonic()
        time.sleep(0.4)
        finished = time.monotonic()
        # Select inside the stable interval, not on the boundary immediately
        # before the next operation changes the fixture's visual state.
        self.marks.append({"label": label, "time": (started + finished) / 2,
                           "holdStart": started, "holdEnd": finished})

    def begin(self, milliseconds):
        response = ipc("beginPluginChanges", str(milliseconds))
        require(response.get("ok"), "Lease begin failed")
        token = response["token"]
        self.tokens.append(token)
        return token, response["expiresAt"]

    def end(self, token):
        response = ipc("endPluginChanges", token)
        require(response.get("ok"), "Lease end failed")
        self.tokens.remove(token)
        return response["generation"]

    def cleanup(self):
        for token in list(self.tokens):
            ipc("endPluginChanges", token)
            self.tokens.remove(token)
        if FIXTURE in status()["plugins"]:
            run("omarchy", "plugin", "remove", FIXTURE, "--yes")
        wait_for(settled, "final fixture cleanup", 30)

    def leases(self, source):
        first, expiry = self.begin(8000)
        second, _ = self.begin(15000)
        self.check("overlapping leases hold independently", status()["leaseCount"] == 2 and status()["held"])
        run("omarchy", "plugin", "add", str(source), "--yes")
        wait_for(lambda: FIXTURE in status()["plugins"], "discovery during hold")
        run("omarchy", "plugin", "enable", FIXTURE, "right")
        current = status()
        self.check("authoritative discovery and enable proceed while held",
                   current["plugins"][FIXTURE]["enabled"] and current["held"] and current["pending"])
        self.check("held enabled widget is not visually instantiated", not widget_visible())
        self.mark("overlap-held-enabled")
        renewed = ipc("renewPluginChanges", first, "15000")
        self.check("renew extends a live lease", renewed.get("ok") and renewed["expiresAt"] > expiry)
        self.end(first)
        wait_for(lambda: not status()["scanning"], "discovery after first lease end")
        self.check("ending first lease retains second hold", status()["held"] and status()["leaseCount"] == 1 and not widget_visible())
        self.mark("one-lease-still-held")
        generation = self.end(second)
        wait_for(settled, "last-lease reconciliation")
        current = status()
        self.check("last lease end applies pending widget", current["settledGeneration"] >= generation and widget_visible())
        self.check("fixture loaded without restart requirement or errors",
                   not current["plugins"][FIXTURE]["loadErrors"] and not current["plugins"][FIXTURE]["restartRequired"])
        self.mark("overlap-released-widget-visible")
        run("omarchy", "plugin", "remove", FIXTURE, "--yes")
        wait_for(lambda: FIXTURE not in status()["plugins"] and settled(), "overlap fixture removal")
        self.check("enabled uninstall retains all surface IDs", surfaces() == self.baseline)

        abandoned, _ = self.begin(5000)
        run("omarchy", "plugin", "add", str(source), "--yes")
        wait_for(lambda: FIXTURE in status()["plugins"], "discovery during expiring lease")
        run("omarchy", "plugin", "enable", FIXTURE, "right")
        self.check("abandoned lease initially holds pending visual work", status()["held"] and not widget_visible())
        self.mark("expiry-held-enabled")
        wait_for(settled, "automatic lease expiry and reconciliation", 10)
        self.check("abandoned lease expires and pending widget appears", status()["leaseCount"] == 0 and widget_visible())
        self.check("expired token cannot renew", ipc("renewPluginChanges", abandoned, "5000").get("ok") is False)
        self.check("expired token cannot end successfully", ipc("endPluginChanges", abandoned).get("ok") is False)
        self.tokens.remove(abandoned)
        self.mark("expired-widget-visible")
        run("omarchy", "plugin", "remove", FIXTURE, "--yes")
        wait_for(lambda: FIXTURE not in status()["plugins"] and settled(), "expiry fixture removal")
        self.mark("final-fixture-removed")


def make_frames(directory, recorder, marks, replace=False):
    frame_paths = []
    overwrite = "-y" if replace else "-n"
    for index, mark in enumerate(marks):
        position = recorder.video_time(mark["time"])
        frame = directory / f"frame-{index:02d}-{mark['label']}.png"
        run("ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", overwrite,
            "-ss", f"{position:.3f}", "-i", str(recorder.video), "-frames:v", "1", str(frame))
        require(frame.is_file(), "Evidence frame extraction failed")
        frame_paths.append(frame)
        mark["videoSeconds"] = round(position, 3)
        mark["frame"] = str(frame)
        tile = directory / f"tile-{index:02d}.png"
        label = f"{index:02d} {mark['label']}  t={position:.2f}s"
        run("ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", overwrite, "-i", str(frame),
            "-vf", f"scale=640:400,pad=640:432:0:32:color=black,drawtext=text='{label}':fontcolor=white:fontsize=14:x=8:y=8",
            "-frames:v", "1", str(tile))
    sheet = directory / "continuity-contact-sheet.png"
    rows = (len(frame_paths) + 2) // 3
    run("ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", overwrite, "-framerate", "1",
        "-i", str(directory / "tile-%02d.png"), "-vf", f"tile=3x{rows}:nb_frames={len(frame_paths)}",
        "-frames:v", "1", str(sheet))
    return str(sheet)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="New evidence directory under test-results")
    parser.add_argument("--capture", choices=("auto", "software"), default="auto")
    parser.add_argument("--render-existing", action="store_true", help="Re-extract frames only; no desktop/IPC operations")
    args = parser.parse_args()
    require((os.environ.get("OUTFIT_TEST_VM") or os.environ.get("OMAFIT_TEST_VM")) == "1", "Disposable VM flag required")
    require(run("systemd-detect-virt", "--vm") == "kvm", "Disposable KVM guest required")
    require(os.environ.get("OMARCHY_PATH") == "/home/tester/omarchy-host", "Use session_exec.py with the canonical VM host checkout")
    directory = args.output.resolve()
    if args.render_existing:
        require(directory.parent == ROOT / "test-results" and (directory / "report.json").is_file(), "Existing evidence directory required")
        report = json.loads((directory / "report.json").read_text())
        recorder = Recorder(directory, "software")
        recorder.frames = json.loads((directory / "recording-frames.json").read_text())
        require(recorder.frames, "Timestamped software frames required for offline extraction")
        ordinary_labels = {"install-disabled", "enable", "remove-enabled", "reinstall-disabled", "remove-disabled"}
        repaired = []
        for mark in report["marks"]:
            if mark["label"] not in ordinary_labels and "holdStart" not in mark:
                repaired.append({"label": mark["label"], "originalMarkerTime": mark["time"],
                                 "originalVideoSeconds": mark.get("videoSeconds")})
                mark["holdEnd"] = mark["time"]
                mark["holdStart"] = mark["time"] - 0.4
                mark["time"] -= 0.2
        if repaired:
            report["frameSelectionCorrection"] = {
                "reason": "Initial harness marked the end of each 0.4s stable pause; select its midpoint to avoid capturing the following operation.",
                "originalMarkers": repaired}
        report["contactSheet"] = make_frames(directory, recorder, report["marks"], replace=True)
        (directory / "report.json").write_text(json.dumps(report, indent=2))
        print(json.dumps({"renderedExistingVideo": True, "frames": len(report["marks"]), "contactSheet": report["contactSheet"]}))
        return 0
    require(directory.parent == ROOT / "test-results" and directory.parent.is_dir() and not directory.exists(), "Choose a new evidence directory under existing test-results")
    require(FIXTURE not in status()["plugins"] and not status()["held"], "Fixture or an existing lease is active")
    wait_for(settled, "initial lifecycle settlement")
    initial_config = ipc("listShellConfig")
    directory.mkdir()
    evidence = Evidence(directory)
    recorder = Recorder(directory, args.capture)
    failure = None
    ordinary_path = directory / "continuity-operations.json"
    before_temps = set(Path(tempfile.gettempdir()).glob("omafit-continuity-*"))
    try:
        recorder.start()
        evidence.start()
        evidence.mark("video-baseline")
        evidence.phase = "ordinary-native-operations"
        result = run(sys.executable, str(ROOT / "tests/vm/continuity_check.py"),
                     "--output", str(ordinary_path), "--expect-continuity", timeout=180)
        evidence.check("existing continuity_check passes real add/enable/remove", json.loads(result)["discontinuousSamples"] == 0)
        ordinary = json.loads(ordinary_path.read_text())
        for phase in ("install-disabled", "enable", "remove-enabled", "reinstall-disabled", "remove-disabled"):
            samples = [row for row in ordinary if row["phase"] == phase]
            require(samples, f"Missing native phase: {phase}")
            evidence.marks.append({"label": phase, "time": samples[len(samples) // 2]["time"]})
            evidence.check(phase + " retains app/background IDs", all(
                row.get("windows") == evidence.baseline["windows"] and row.get("backgrounds") == evidence.baseline["backgrounds"]
                for row in samples), samples=len(samples))
        new_temps = set(Path(tempfile.gettempdir()).glob("omafit-continuity-*")) - before_temps
        require(len(new_temps) == 1, "Could not identify this test's generated fixture repository")
        source = next(iter(new_temps)) / "fixture"
        require(json.loads((source / "manifest.json").read_text())["id"] == FIXTURE, "Unexpected generated fixture identity")
        wait_for(settled, "ordinary operation settlement")
        evidence.leases(source)
    except Exception as error:
        failure = str(error)
    finally:
        try:
            evidence.cleanup()
            evidence.check("final shell config restored", ipc("listShellConfig") == initial_config)
            evidence.check("final fixture absent and lifecycle settled", FIXTURE not in status()["plugins"] and settled())
        except Exception as error:
            failure = failure or str(error)
        if hasattr(evidence, "thread"):
            evidence.stop()
        if recorder.started is not None:
            try:
                recorder.stop()
            except Exception as error:
                failure = failure or str(error)
    changed = [row for row in evidence.samples if any(row.get(key) != value for key, value in evidence.baseline.items())]
    gaps = [b["time"] - a["time"] for a, b in zip(evidence.samples, evidence.samples[1:])]
    report = {"ok": failure is None and not changed, "failure": failure, "baseline": evidence.baseline,
              "sampleCount": len(evidence.samples), "discontinuousSamples": len(changed),
              "probeErrors": sum(bool(row.get("probeError")) for row in evidence.samples),
              "sampleMedianIntervalMs": round(statistics.median(gaps) * 1000, 1) if gaps else None,
              "sampleMaxIntervalMs": round(max(gaps) * 1000, 1) if gaps else None,
              "checks": evidence.checks, "mechanism": recorder.mechanism,
              "nativeAttempt": recorder.native_attempt, "video": str(recorder.video), "marks": evidence.marks}
    (directory / "surfaces.json").write_text(json.dumps(evidence.samples, indent=2))
    (directory / "recording-frames.json").write_text(json.dumps(recorder.frames, indent=2))
    if not failure:
        report["videoProbe"] = json.loads(run("ffprobe", "-v", "error", "-show_entries",
            "format=duration,size:stream=codec_name,width,height,r_frame_rate,nb_frames", "-of", "json", str(recorder.video)))
        require(float(report["videoProbe"]["format"]["duration"]) > 5, "Video is too short")
        report["contactSheet"] = make_frames(directory, recorder, evidence.marks)
    (directory / "report.json").write_text(json.dumps(report, indent=2))
    print(json.dumps({"ok": report["ok"], "failure": failure, "samples": len(evidence.samples),
                      "discontinuousSamples": len(changed), "mechanism": recorder.mechanism,
                      "report": str(directory / "report.json")}))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
