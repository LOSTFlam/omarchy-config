"""Shared test helpers: a throwaway XDG environment and the command runner.

Importing this module puts lib/ on sys.path, so tests can import fresh_tube.
"""
import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "lib"))
FRESH_TUBE = os.path.join(ROOT, "bin", "fresh-tube")
FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")


def fixture(name):
    with open(os.path.join(FIXTURES, name), "rb") as f:
        return f.read()


class Sandbox:
    """A temp HOME with its own XDG config and state dirs."""

    def __init__(self):
        self.root = tempfile.mkdtemp(prefix="fresh-tube-test-")
        self.home = self._dir("home")
        self.config = self._dir("config")
        self.state = self._dir("state")
        self.env = {
            "HOME": self.home,
            "XDG_CONFIG_HOME": self.config,
            "XDG_STATE_HOME": self.state,
            "PATH": "/usr/bin:/bin",
            "PYTHONDONTWRITEBYTECODE": "1",
        }
        self._saved = {}

    def _dir(self, relative):
        path = os.path.join(self.root, relative)
        os.makedirs(path, exist_ok=True)
        return path

    # In-process tests: put the sandbox environment into os.environ.
    def apply(self):
        for key, value in self.env.items():
            self._saved.setdefault(key, os.environ.get(key))
            os.environ[key] = value

    def restore(self):
        for key, value in self._saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        self._saved = {}

    def cleanup(self):
        self.restore()
        shutil.rmtree(self.root, ignore_errors=True)

    @property
    def channels_file(self):
        return os.path.join(self.config, "fresh-tube", "channels.json")

    @property
    def state_file(self):
        return os.path.join(self.state, "fresh-tube", "state.json")

    def read_json(self, path):
        with open(path, encoding="utf-8") as f:
            return json.load(f)

    def write_json(self, path, data):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f)

    # The real command, in a child process with the sandbox environment.
    def run(self, *args, env=None):
        full = dict(self.env)
        full.update(env or {})
        return subprocess.run([sys.executable, FRESH_TUBE, *args], capture_output=True,
                              env=full, timeout=30, text=True)


@contextlib.contextmanager
def captured():
    """Collect what an in-process main() call prints: yields (stdout, stderr) buffers."""
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        yield out, err
