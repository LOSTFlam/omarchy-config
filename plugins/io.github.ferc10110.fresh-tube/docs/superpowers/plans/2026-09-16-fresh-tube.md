# Fresh Tube Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Un widget de la barra de Omarchy que lista el último video no visto de canales de YouTube elegidos a mano, lo reproduce en `mpv` al hacer click, y cuyo popup se puede pinnear y redimensionar.

**Architecture:** Backend Python (solo stdlib) en `bin/fresh-tube` + `lib/fresh_tube/` que resuelve canales, baja feeds RSS, guarda estado y siempre imprime JSON. QML como cara: `BarWidget.qml` (icono + contador + timer) carga `Panel.qml` (estado, runners, IPC) que monta `FeedPopup.qml` (layer-shell con pin y grip de resize) con dos vistas, `VideosView.qml` y `ChannelsView.qml`.

**Tech Stack:** Python 3.14 stdlib (`urllib`, `xml.etree`, `json`, `concurrent.futures`), `unittest`; Quickshell 0.3.1 QML (`qs.Commons`, `qs.Ui`, `Quickshell.Io`, `Quickshell.Wayland`); Node 26 `node --test` para los helpers JS; `yt-dlp` (fallback de resolución) y `mpv` (reproducción).

**Spec:** `docs/superpowers/specs/2026-09-16-fresh-tube-design.md` (mismo repo). El plan argumenta desde el spec; leer los dos.

## Global Constraints

- Repo y directorio de trabajo: `~/.config/omarchy/plugins/io.github.ferc10110.fresh-tube/`. Todos los comandos de este plan se corren desde ahí. Nada se crea en `~/Projects/youtube-proyect`.
- Id del plugin `io.github.ferc10110.fresh-tube`; target IPC igual; `defaultSection: "left"`; nombre visible "Fresh Tube".
- Python: solo stdlib. Fechas con `datetime.datetime.now(datetime.timezone.utc)`; nunca `utcnow()`.
- Tests Python con `unittest` (no hay pytest en la máquina): `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v`. Nunca tocan la red: `urlopen`, `fetch_url`, `fetch_feed` y `subprocess.run` se mockean.
- Tests JS: `node --test tests/model.test.js`.
- Textos de UI, README y comentarios en inglés. Este plan y el spec en español.
- Nunca editar nada bajo `/usr/share/omarchy/`. Leerlo está bien.
- La shell recarga el plugin al guardar cualquier archivo del directorio. Errores QML se leen con `quickshell log -p /usr/share/omarchy/shell -t 40`.
- `omarchy plugin validate .` debe pasar (exit 0, sin salida) desde la Tarea 1 en adelante.
- Exit codes del CLI: 0 ok, 1 inesperado, 2 uso/entrada inválida, 3 red/resolución, 4 duplicado, 5 canal desconocido. Errores en stderr con prefijo `fresh-tube: `.
- Cada commit termina con estas dos líneas:
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_011DPqvBbwQCc2wPWRZoVQkC
  ```
  Autor: `git -c user.name="Fernando Cancro" -c user.email="fernando.cancro@gmail.com" commit ...` si el repo no tiene identidad configurada.

---

## Estructura de archivos

| Archivo | Responsabilidad |
|---|---|
| `manifest.json` | Identidad del plugin, entry point, sección por defecto, settings `playerCommand` y `refreshMinutes`. |
| `bin/fresh-tube` | Entry point Python: pone `lib/` en `sys.path`, llama `cli.main()`. |
| `lib/fresh_tube/errors.py` | `FreshTubeError(message, code)` y las constantes de exit code. |
| `lib/fresh_tube/store.py` | `channels.json` y `state.json`: rutas XDG, lectura/escritura atómica, canales, vistos, caché de feeds, prefs, `unseen_videos`. |
| `lib/fresh_tube/feed.py` | `fetch_url`, `feed_url`, `parse_feed`, `fetch_feed`. |
| `lib/fresh_tube/resolve.py` | De lo pegado al `channel_id`: normalización, id directo, HTML, fallback `yt-dlp`. |
| `lib/fresh_tube/cli.py` | argparse, comandos `add/remove/channels/refresh/seen/prefs`, `refresh_all`, `main`. |
| `tests/support.py` | `Sandbox` con XDG temporal, `run()` por subproceso, `captured()`, `fixture()`. |
| `tests/fixtures/*` | `feed.xml`, `channel_page.html`, `watch_page.html`, `no_id_page.html`. |
| `tests/test_*.py`, `tests/model.test.js` | Tests por módulo. |
| `FreshTubeModel.js` | Helpers puros: `relativeTime`, `formatClock`, `looksLikeChannelInput`, `playerArgs`, `playerName`. |
| `FreshTubeCommand.qml` | Un proceso a la vez con timeout; señal `finished(code, out, err)`. |
| `FeedPopup.qml` | Popup layer-shell: alineado al icono, pin, grip de resize. |
| `BarWidget.qml` | Icono `󰗃` + contador, click, timer de polling, broadcast. |
| `Panel.qml` | Estado, runners, prefs, IPC, monta popup y vistas. |
| `VideoRow.qml`, `VideosView.qml` | Fila con thumbnail y lista de nuevos con cabecera. |
| `ChannelsView.qml` | Alta/baja de canales. |
| `README.md`, `LICENSE`, `THIRD_PARTY_NOTICES.md` | Docs y licencias. |

---

### Task 1: Esqueleto: manifest, entry point, errores, CLI vacío, sandbox de tests, icono mínimo

**Files:**
- Create: `manifest.json`
- Create: `bin/fresh-tube`
- Create: `lib/fresh_tube/__init__.py`
- Create: `lib/fresh_tube/errors.py`
- Create: `lib/fresh_tube/cli.py`
- Create: `tests/support.py`
- Create: `tests/test_cli.py`
- Create: `BarWidget.qml` (mínimo; se reemplaza completo en la Tarea 11)
- Modify: `docs/superpowers/specs/2026-09-16-fresh-tube-design.md` (pytest → unittest)

**Interfaces:**
- Produces: `errors.FreshTubeError(message, code=GENERAL)` con `.code`; constantes `GENERAL=1, USAGE=2, NETWORK=3, DUPLICATE=4, UNKNOWN=5`. `cli.build_parser() -> (parser, subparsers)`, `cli.emit(data)`, `cli.main(argv=None) -> int`. `support.Sandbox` (`.apply()`, `.restore()`, `.cleanup()`, `.run(*args, env=None)`, `.channels_file`, `.state_file`, `.read_json(path)`, `.write_json(path, data)`), `support.captured()` (context manager que devuelve `(out, err)` StringIO), `support.fixture(name) -> bytes`.

- [ ] **Step 1: Escribir el sandbox y el primer test (falla)**

`tests/support.py`:

```python
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
```

`tests/test_cli.py`:

```python
import json
import unittest

import support


class CliTest(unittest.TestCase):
    def setUp(self):
        self.box = support.Sandbox()
        self.addCleanup(self.box.cleanup)

    def ok(self, *args, **kw):
        result = self.box.run(*args, **kw)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def json(self, *args, **kw):
        return json.loads(self.ok(*args, **kw))

    def fails(self, code, *args, **kw):
        result = self.box.run(*args, **kw)
        self.assertEqual(result.returncode, code, (result.stdout, result.stderr))
        if code != 2:
            self.assertTrue(result.stderr.startswith("fresh-tube: "), result.stderr)
        return result.stderr


class Usage(CliTest):
    def test_help_and_usage_errors(self):
        self.assertIn("fresh-tube", self.ok("-h"))
        self.fails(2, "nope")
        self.fails(2)
```

- [ ] **Step 2: Correr el test y ver que falla**

Run: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v`
Expected: FAIL. `self.ok("-h")` falla porque `bin/fresh-tube` no existe (returncode 2 de Python "No such file").

- [ ] **Step 3: Escribir errors, cli y el entry point**

`lib/fresh_tube/__init__.py`: archivo vacío.

`lib/fresh_tube/errors.py`:

```python
"""The one exception every command raises, carrying the exit code to use."""

GENERAL = 1
USAGE = 2
NETWORK = 3
DUPLICATE = 4
UNKNOWN = 5


class FreshTubeError(Exception):
    def __init__(self, message, code=GENERAL):
        super().__init__(message)
        self.code = code
```

`lib/fresh_tube/cli.py`:

```python
"""fresh-tube: the latest unseen video of the YouTube channels you pick."""
import argparse
import json
import sys

from .errors import FreshTubeError


def emit(data):
    print(json.dumps(data, ensure_ascii=False))


def build_parser():
    parser = argparse.ArgumentParser(prog="fresh-tube", description=__doc__)
    sub = parser.add_subparsers(dest="command", metavar="command")
    sub.required = True
    return parser, sub


def main(argv=None):
    parser, _ = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except FreshTubeError as e:
        print(f"fresh-tube: {e}", file=sys.stderr)
        return e.code
```

`bin/fresh-tube`:

```python
#!/usr/bin/env python3
"""Entry point for Fresh Tube. The code lives in lib/fresh_tube next to this folder."""
import os
import sys

# The shell reloads the plugin when a file in its folder changes, so Python must
# not leave bytecode caches behind in it.
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.realpath(__file__))), "lib"))

from fresh_tube.cli import main  # noqa: E402

sys.exit(main())
```

Run: `chmod +x bin/fresh-tube`

- [ ] **Step 4: Correr el test y ver que pasa**

Run: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v`
Expected: `test_help_and_usage_errors ... ok`. Con cero subcomandos registrados, argparse rechaza `nope` y la ausencia de comando con exit 2.

- [ ] **Step 5: Manifest e icono mínimo, validar y habilitar**

`manifest.json`:

```json
{
  "schemaVersion": 1,
  "id": "io.github.ferc10110.fresh-tube",
  "name": "Fresh Tube",
  "version": "0.1.0",
  "author": "Fernando Cancro",
  "license": "MIT",
  "description": "The latest unseen video of the YouTube channels you pick, one click from the bar, played in mpv.",
  "kinds": ["bar-widget"],
  "entryPoints": { "barWidget": "BarWidget.qml" },
  "barWidget": {
    "displayName": "Fresh Tube",
    "description": "New videos from your chosen YouTube channels",
    "category": "Media",
    "aliases": ["youtube", "fresh-tube", "videos"],
    "allowMultiple": false,
    "defaultSection": "left",
    "defaults": { "playerCommand": "mpv", "refreshMinutes": 15 },
    "schema": [
      { "key": "playerCommand", "type": "string", "label": "Player command" },
      { "key": "refreshMinutes", "type": "number", "label": "Refresh every (minutes)" }
    ]
  }
}
```

`BarWidget.qml` (versión mínima, la Tarea 11 la reemplaza entera):

```qml
import QtQuick
import qs.Commons
import qs.Ui

// Bar entry point for Fresh Tube. The panel arrives in a later task; for now
// the icon only proves the plugin loads and sits in the left section.
BarWidget {
  id: root
  moduleName: "io.github.ferc10110.fresh-tube"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰗃"
    fontSize: Style.font.bodySmall
    horizontalMargin: 6
    dimmed: true
    tooltipText: "Fresh Tube"
  }
}
```

Run:
```bash
omarchy plugin validate . ; echo "validate exit=$?"
omarchy-shell shell rescanPlugins
omarchy plugin enable io.github.ferc10110.fresh-tube
quickshell log -p /usr/share/omarchy/shell -t 30 | grep -i -E 'fresh|error|warn' | tail -10
```
Expected: `validate exit=0` sin otra salida; el icono `󰗃` atenuado aparece en la sección izquierda de la barra, después de los workspaces; el log no muestra errores QML para `fresh-tube`.

- [ ] **Step 6: Corregir el spec: unittest en vez de pytest**

En `docs/superpowers/specs/2026-09-16-fresh-tube-design.md`, en la sección "Pruebas", reemplazar la línea

```
Python (`pytest`, sin red; `urlopen` y `subprocess.run` mockeados):
```
por
```
Python (`unittest`, no hay pytest en la máquina; sin red: `urlopen`, `fetch_url`, `fetch_feed` y `subprocess.run` mockeados):
```
y en "Instalación y desarrollo" reemplazar
```
Los tests Python corren
con `python -m pytest tests/` desde la carpeta del plugin; los de Node con
`node --test tests/model.test.js`.
```
por
```
Los tests Python corren
con `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v` desde
la carpeta del plugin; los de Node con `node --test tests/model.test.js`.
```

- [ ] **Step 7: Commit**

```bash
git add manifest.json bin/fresh-tube lib/fresh_tube tests/support.py tests/test_cli.py BarWidget.qml docs/superpowers/specs/2026-09-16-fresh-tube-design.md
git commit -F - <<'EOF'
Scaffold the plugin: manifest, CLI entry point and test sandbox

The bar shows a dimmed icon in the left section; the script only knows
how to print its help. Tests use unittest, which is what the machine has.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_011DPqvBbwQCc2wPWRZoVQkC
EOF
```

---

### Task 2: store.py: rutas XDG y channels.json

**Files:**
- Create: `lib/fresh_tube/store.py`
- Create: `tests/test_store.py`

**Interfaces:**
- Consumes: `errors.FreshTubeError`, `DUPLICATE`, `UNKNOWN`, `GENERAL`.
- Produces: `store.now_iso() -> str` (ISO UTC con `+00:00`, segundos); `store.config_dir()`, `store.state_dir()`, `store.channels_path()`, `store.state_path()`; `store.read_json(path, empty) -> dict`; `store.write_json(path, data)` (atómica); `store.load_channels() -> list[dict]`; `store.save_channels(channels)`; `store.find_channel(channels, channel_id) -> dict|None`; `store.add_channel(channels, channel_id, name) -> dict` (`{"id","name","url","addedAt"}`, lanza `DUPLICATE`); `store.remove_channel(channels, channel_id) -> list` (lanza `UNKNOWN`). `CHANNEL_URL = "https://www.youtube.com/channel/{}"`.

- [ ] **Step 1: Escribir los tests (fallan)**

`tests/test_store.py`:

```python
import os
import unittest

import support
from fresh_tube import store
from fresh_tube.errors import DUPLICATE, UNKNOWN, USAGE, FreshTubeError

LTT = "UCXuqSBlHAE6Xw-yeJA0Tunw"


class StoreTest(unittest.TestCase):
    def setUp(self):
        self.box = support.Sandbox()
        self.box.apply()
        self.addCleanup(self.box.cleanup)


class Paths(StoreTest):
    def test_paths_follow_xdg(self):
        self.assertEqual(store.channels_path(), self.box.channels_file)
        self.assertEqual(store.state_path(), self.box.state_file)

    def test_paths_fall_back_to_home(self):
        os.environ["XDG_CONFIG_HOME"] = ""
        os.environ["XDG_STATE_HOME"] = ""
        self.assertEqual(store.channels_path(),
                         os.path.join(self.box.home, ".config", "fresh-tube", "channels.json"))
        self.assertEqual(store.state_path(),
                         os.path.join(self.box.home, ".local", "state", "fresh-tube", "state.json"))

    def test_now_iso_is_utc_with_offset(self):
        self.assertRegex(store.now_iso(), r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\+00:00$")


class Channels(StoreTest):
    def test_missing_file_is_empty(self):
        self.assertEqual(store.load_channels(), [])

    def test_add_save_and_reload(self):
        channels = []
        added = store.add_channel(channels, LTT, "Linus Tech Tips")
        self.assertEqual(added["id"], LTT)
        self.assertEqual(added["name"], "Linus Tech Tips")
        self.assertEqual(added["url"], "https://www.youtube.com/channel/" + LTT)
        self.assertRegex(added["addedAt"], r"^\d{4}-\d\d-\d\dT")
        store.save_channels(channels)
        self.assertEqual(store.load_channels(), [added])
        self.assertEqual(self.box.read_json(self.box.channels_file)["version"], 1)
        self.assertEqual(store.find_channel(channels, LTT), added)
        self.assertIsNone(store.find_channel(channels, "UCnothere0000000000000xx"))

    def test_duplicate_is_refused(self):
        channels = [store.add_channel([], LTT, "LTT")]
        with self.assertRaises(FreshTubeError) as caught:
            store.add_channel(channels, LTT, "Again")
        self.assertEqual(caught.exception.code, DUPLICATE)
        self.assertEqual(len(channels), 1)

    def test_remove(self):
        channels = [store.add_channel([], LTT, "LTT")]
        self.assertEqual(store.remove_channel(channels, LTT), [])
        with self.assertRaises(FreshTubeError) as caught:
            store.remove_channel(channels, LTT)
        self.assertEqual(caught.exception.code, UNKNOWN)

    def test_corrupt_file_is_reported_not_overwritten(self):
        os.makedirs(os.path.dirname(self.box.channels_file))
        with open(self.box.channels_file, "w") as f:
            f.write("{not json")
        with self.assertRaises(FreshTubeError) as caught:
            store.load_channels()
        self.assertIn("channels.json", str(caught.exception))
        with open(self.box.channels_file) as f:
            self.assertEqual(f.read(), "{not json")

    def test_write_is_atomic_and_leaves_no_temp_files(self):
        store.save_channels([])
        folder = os.path.dirname(self.box.channels_file)
        self.assertEqual(os.listdir(folder), ["channels.json"])
```

- [ ] **Step 2: Correr y ver que falla**

Run: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests.test_store -v` (desde la raíz del plugin, con `cd tests` no hace falta: usar `python3 -m unittest discover -s tests -p 'test_store.py' -v`)
Expected: FAIL con `ModuleNotFoundError: No module named 'fresh_tube.store'`.

- [ ] **Step 3: Escribir store.py (parte de canales)**

`lib/fresh_tube/store.py`:

```python
"""channels.json and state.json: where Fresh Tube keeps what it knows."""
import datetime
import json
import os
import tempfile

from .errors import DUPLICATE, GENERAL, UNKNOWN, USAGE, FreshTubeError

APP = "fresh-tube"
CHANNELS_VERSION = 1
STATE_VERSION = 1
CHANNEL_URL = "https://www.youtube.com/channel/{}"


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")


def _xdg(var, fallback_parts):
    base = os.environ.get(var, "")
    if not base:
        base = os.path.join(os.path.expanduser("~"), *fallback_parts)
    return os.path.join(base, APP)


def config_dir():
    return _xdg("XDG_CONFIG_HOME", [".config"])


def state_dir():
    return _xdg("XDG_STATE_HOME", [".local", "state"])


def channels_path():
    return os.path.join(config_dir(), "channels.json")


def state_path():
    return os.path.join(state_dir(), "state.json")


def read_json(path, empty):
    """The parsed file, `empty` when it does not exist. A file that is not JSON is an error."""
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        return empty
    except (OSError, ValueError) as e:
        raise FreshTubeError(f"Could not read {os.path.basename(path)}: {e}", GENERAL)
    if not isinstance(data, dict):
        raise FreshTubeError(f"Could not read {os.path.basename(path)}: not an object", GENERAL)
    return data


def write_json(path, data):
    """Write through a temp file in the same directory so a crash never leaves half a file."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write("\n")
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


# --- channels ---------------------------------------------------------------

def load_channels():
    data = read_json(channels_path(), {"version": CHANNELS_VERSION, "channels": []})
    channels = data.get("channels")
    if not isinstance(channels, list):
        return []
    return [c for c in channels if isinstance(c, dict) and c.get("id")]


def save_channels(channels):
    write_json(channels_path(), {"version": CHANNELS_VERSION, "channels": channels})


def find_channel(channels, channel_id):
    for c in channels:
        if c.get("id") == channel_id:
            return c
    return None


def add_channel(channels, channel_id, name):
    if find_channel(channels, channel_id):
        raise FreshTubeError("Already added", DUPLICATE)
    channel = {"id": channel_id, "name": name, "url": CHANNEL_URL.format(channel_id), "addedAt": now_iso()}
    channels.append(channel)
    return channel


def remove_channel(channels, channel_id):
    if not find_channel(channels, channel_id):
        raise FreshTubeError("No such channel", UNKNOWN)
    channels[:] = [c for c in channels if c.get("id") != channel_id]
    return channels
```

- [ ] **Step 4: Correr y ver que pasa**

Run: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v`
Expected: todos `ok` (los de `Paths` y `Channels` más el de la Tarea 1). `USAGE` importado sin usar en el test está bien: lo usa la Tarea 3.

- [ ] **Step 5: Commit**

```bash
git add lib/fresh_tube/store.py tests/test_store.py
git commit -F - <<'EOF'
Keep the channel list in channels.json under XDG config

Atomic writes through a temp file; a corrupt file is reported, never
overwritten.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_011DPqvBbwQCc2wPWRZoVQkC
EOF
```

---

### Task 3: store.py: state.json (vistos, caché de feeds, prefs, unseen_videos)

**Files:**
- Modify: `lib/fresh_tube/store.py` (agregar al final)
- Modify: `tests/test_store.py` (agregar al final)

**Interfaces:**
- Produces: `store.DEFAULT_PREFS = {"width": 420, "height": 520, "pinned": False}`; `store.empty_state()`; `store.load_state() -> dict` con claves `version, seen(list), feeds(dict), fetchedAt(str), prefs(dict completo)`; `store.save_state(state)`; `store.set_pref(state, key, value) -> prefs` (lanza `USAGE`); `store.mark_seen(state, video_id)`; `store.prune_seen(state)`; `store.update_feed(state, channel_id, parsed, fetched_at)` donde `parsed = {"name", "latest", "recent"}`; `store.set_feed_error(state, channel_id, message)`; `store.drop_feed(state, channel_id)`; `store.unseen_videos(state, channels) -> list[dict]` con `{"videoId","title","channelId","channel","published","thumbnail","url"}` ordenados por `published` desc. `WATCH_URL = "https://www.youtube.com/watch?v={}"`.

- [ ] **Step 1: Agregar los tests (fallan)**

Al final de `tests/test_store.py`:

```python
PARSED = {"name": "Example",
          "latest": {"videoId": "new", "title": "New", "published": "2026-09-15T17:00:03+00:00",
                     "thumbnail": "https://i/new.jpg"},
          "recent": ["new", "old"]}


class State(StoreTest):
    def test_missing_state_has_defaults(self):
        self.assertEqual(store.load_state(), {"version": 1, "seen": [], "feeds": {}, "fetchedAt": "",
                                              "prefs": {"width": 420, "height": 520, "pinned": False}})

    def test_save_and_reload(self):
        state = store.load_state()
        store.mark_seen(state, "abc")
        store.save_state(state)
        self.assertEqual(store.load_state()["seen"], ["abc"])

    def test_mark_seen_is_idempotent(self):
        state = store.load_state()
        store.mark_seen(state, "abc")
        store.mark_seen(state, "abc")
        self.assertEqual(state["seen"], ["abc"])

    def test_prefs_validation(self):
        state = store.load_state()
        self.assertEqual(store.set_pref(state, "width", "500")["width"], 500)
        self.assertEqual(store.set_pref(state, "height", "300")["height"], 300)
        self.assertIs(store.set_pref(state, "pinned", "true")["pinned"], True)
        self.assertIs(store.set_pref(state, "pinned", "False")["pinned"], False)
        for key, value in (("width", "10"), ("width", "abc"), ("height", "99999"),
                           ("pinned", "maybe"), ("color", "red")):
            with self.assertRaises(FreshTubeError, msg=(key, value)) as caught:
                store.set_pref(state, key, value)
            self.assertEqual(caught.exception.code, USAGE)

    def test_partial_prefs_are_completed(self):
        self.box.write_json(self.box.state_file, {"version": 1, "prefs": {"width": 600}})
        self.assertEqual(store.load_state()["prefs"], {"width": 600, "height": 520, "pinned": False})


class Feeds(StoreTest):
    def test_update_feed_and_error_keep_cache(self):
        state = store.load_state()
        store.update_feed(state, "UC1", PARSED, "2026-09-16T10:00:00+00:00")
        self.assertEqual(state["feeds"]["UC1"], {"fetchedAt": "2026-09-16T10:00:00+00:00", "lastError": "",
                                                 "latest": PARSED["latest"], "recent": ["new", "old"]})
        store.set_feed_error(state, "UC1", "timed out")
        self.assertEqual(state["feeds"]["UC1"]["lastError"], "timed out")
        self.assertEqual(state["feeds"]["UC1"]["latest"], PARSED["latest"])
        store.set_feed_error(state, "UC2", "timed out")
        self.assertEqual(state["feeds"]["UC2"], {"fetchedAt": "", "lastError": "timed out",
                                                 "latest": None, "recent": []})
        store.drop_feed(state, "UC1")
        self.assertNotIn("UC1", state["feeds"])

    def test_prune_keeps_only_ids_still_in_a_feed(self):
        state = store.load_state()
        store.update_feed(state, "UC1", PARSED, "2026-09-16T10:00:00+00:00")
        state["seen"] = ["new", "gone", "old"]
        store.prune_seen(state)
        self.assertEqual(state["seen"], ["new", "old"])

    def test_unseen_videos_one_per_channel_newest_first(self):
        state = store.load_state()
        channels = [{"id": "UC1", "name": "One"}, {"id": "UC2", "name": "Two"}, {"id": "UC3", "name": "Three"}]
        store.update_feed(state, "UC1", PARSED, "2026-09-16T10:00:00+00:00")
        later = dict(PARSED, latest=dict(PARSED["latest"], videoId="later", published="2026-09-16T09:00:00+00:00"))
        store.update_feed(state, "UC2", later, "2026-09-16T10:00:00+00:00")
        # UC3 has no cache yet and must simply be absent.
        videos = store.unseen_videos(state, channels)
        self.assertEqual([v["videoId"] for v in videos], ["later", "new"])
        self.assertEqual(videos[0]["channel"], "Two")
        self.assertEqual(videos[0]["channelId"], "UC2")
        self.assertEqual(videos[0]["url"], "https://www.youtube.com/watch?v=later")
        self.assertEqual(videos[1]["thumbnail"], "https://i/new.jpg")
        store.mark_seen(state, "later")
        self.assertEqual([v["videoId"] for v in store.unseen_videos(state, channels)], ["new"])
```

- [ ] **Step 2: Correr y ver que falla**

Run: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_store.py' -v`
Expected: FAIL con `AttributeError: module 'fresh_tube.store' has no attribute 'load_state'`.

- [ ] **Step 3: Agregar la parte de estado a store.py**

Al final de `lib/fresh_tube/store.py`:

```python
# --- state -------------------------------------------------------------------

DEFAULT_PREFS = {"width": 420, "height": 520, "pinned": False}
PREF_LIMITS = {"width": (300, 4000), "height": (220, 4000)}
WATCH_URL = "https://www.youtube.com/watch?v={}"


def empty_state():
    return {"version": STATE_VERSION, "seen": [], "feeds": {}, "fetchedAt": "", "prefs": dict(DEFAULT_PREFS)}


def load_state():
    data = read_json(state_path(), None)
    state = empty_state()
    if data is None:
        return state
    if isinstance(data.get("seen"), list):
        state["seen"] = [str(s) for s in data["seen"]]
    if isinstance(data.get("feeds"), dict):
        state["feeds"] = data["feeds"]
    if isinstance(data.get("fetchedAt"), str):
        state["fetchedAt"] = data["fetchedAt"]
    prefs = data.get("prefs")
    if isinstance(prefs, dict):
        for key in DEFAULT_PREFS:
            if key in prefs:
                state["prefs"][key] = prefs[key]
    return state


def save_state(state):
    write_json(state_path(), state)


def set_pref(state, key, value):
    if key in PREF_LIMITS:
        low, high = PREF_LIMITS[key]
        try:
            number = int(str(value).strip())
        except ValueError:
            raise FreshTubeError(f"{key} must be a whole number", USAGE)
        if not low <= number <= high:
            raise FreshTubeError(f"{key} must be between {low} and {high}", USAGE)
        state["prefs"][key] = number
    elif key == "pinned":
        text = str(value).strip().lower()
        if text not in ("true", "false"):
            raise FreshTubeError("pinned must be true or false", USAGE)
        state["prefs"]["pinned"] = text == "true"
    else:
        raise FreshTubeError(f"Unknown preference: {key}", USAGE)
    return state["prefs"]


def mark_seen(state, video_id):
    if video_id not in state["seen"]:
        state["seen"].append(video_id)


def prune_seen(state):
    """Forget seen ids that no cached feed lists any more; they can never show up again."""
    keep = set()
    for feed in state["feeds"].values():
        keep.update(feed.get("recent") or [])
    state["seen"] = [s for s in state["seen"] if s in keep]


def update_feed(state, channel_id, parsed, fetched_at):
    state["feeds"][channel_id] = {"fetchedAt": fetched_at, "lastError": "",
                                  "latest": parsed.get("latest"), "recent": list(parsed.get("recent") or [])}


def set_feed_error(state, channel_id, message):
    """Remember why a channel failed while keeping whatever it had cached."""
    feed = state["feeds"].setdefault(channel_id, {"fetchedAt": "", "lastError": "", "latest": None, "recent": []})
    feed["lastError"] = message


def drop_feed(state, channel_id):
    state["feeds"].pop(channel_id, None)


def unseen_videos(state, channels):
    """The newest video of every channel whose newest video was not seen, newest first."""
    seen = set(state["seen"])
    videos = []
    for channel in channels:
        feed = state["feeds"].get(channel["id"]) or {}
        latest = feed.get("latest")
        if not latest or latest.get("videoId") in seen:
            continue
        videos.append({"videoId": latest["videoId"], "title": latest.get("title", ""),
                       "channelId": channel["id"], "channel": channel.get("name", ""),
                       "published": latest.get("published", ""), "thumbnail": latest.get("thumbnail", ""),
                       "url": WATCH_URL.format(latest["videoId"])})
    videos.sort(key=lambda v: v["published"], reverse=True)
    return videos
```

- [ ] **Step 4: Correr y ver que pasa**

Run: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v`
Expected: todos `ok`.

- [ ] **Step 5: Commit**

```bash
git add lib/fresh_tube/store.py tests/test_store.py
git commit -F - <<'EOF'
Keep seen videos, cached feeds and popup prefs in state.json

Seen ids are pruned to what some feed still lists, so the set never
grows past a few hundred entries.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_011DPqvBbwQCc2wPWRZoVQkC
EOF
```

---

### Task 4: feed.py: bajar y parsear el RSS de un canal

**Files:**
- Create: `lib/fresh_tube/feed.py`
- Create: `tests/fixtures/feed.xml`
- Create: `tests/test_feed.py`

**Interfaces:**
- Consumes: `errors.FreshTubeError`, `NETWORK`.
- Produces: `feed.feed_url(channel_id) -> str`; `feed.fetch_url(url, timeout) -> bytes` (lanza `NETWORK`); `feed.parse_feed(data: bytes) -> {"name": str, "latest": dict|None, "recent": list[str]}` con `latest = {"videoId","title","published","thumbnail"}`; `feed.fetch_feed(channel_id, timeout=10) -> parsed`. `feed.urlopen` es un alias de módulo de `urllib.request.urlopen` para que los tests lo reemplacen.

- [ ] **Step 1: Fixture y tests (fallan)**

`tests/fixtures/feed.xml` (la entrada más nueva va en el medio a propósito):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns:media="http://search.yahoo.com/mrss/" xmlns="http://www.w3.org/2005/Atom">
 <link rel="self" href="http://www.youtube.com/feeds/videos.xml?channel_id=UCXuqSBlHAE6Xw-yeJA0Tunw"/>
 <id>yt:channel:XuqSBlHAE6Xw-yeJA0Tunw</id>
 <yt:channelId>XuqSBlHAE6Xw-yeJA0Tunw</yt:channelId>
 <title>Example Channel</title>
 <published>2008-11-25T00:46:52+00:00</published>
 <entry>
  <id>yt:video:older111111</id>
  <yt:videoId>older111111</yt:videoId>
  <yt:channelId>UCXuqSBlHAE6Xw-yeJA0Tunw</yt:channelId>
  <title>Older video</title>
  <link rel="alternate" href="https://www.youtube.com/watch?v=older111111"/>
  <published>2026-09-10T10:00:00+00:00</published>
  <media:group>
   <media:title>Older video</media:title>
   <media:thumbnail url="https://i.ytimg.com/vi/older111111/hqdefault.jpg" width="480" height="360"/>
  </media:group>
 </entry>
 <entry>
  <id>yt:video:newest22222</id>
  <yt:videoId>newest22222</yt:videoId>
  <yt:channelId>UCXuqSBlHAE6Xw-yeJA0Tunw</yt:channelId>
  <title>Newest video</title>
  <link rel="alternate" href="https://www.youtube.com/watch?v=newest22222"/>
  <published>2026-09-15T17:00:03+00:00</published>
  <media:group>
   <media:title>Newest video</media:title>
   <media:thumbnail url="https://i.ytimg.com/vi/newest22222/hqdefault.jpg" width="480" height="360"/>
  </media:group>
 </entry>
 <entry>
  <id>yt:video:middle33333</id>
  <yt:videoId>middle33333</yt:videoId>
  <yt:channelId>UCXuqSBlHAE6Xw-yeJA0Tunw</yt:channelId>
  <title>Middle video</title>
  <link rel="alternate" href="https://www.youtube.com/watch?v=middle33333"/>
  <published>2026-09-12T08:30:00+00:00</published>
  <media:group>
   <media:title>Middle video</media:title>
   <media:thumbnail url="https://i.ytimg.com/vi/middle33333/hqdefault.jpg" width="480" height="360"/>
  </media:group>
 </entry>
</feed>
```

`tests/test_feed.py`:

```python
import unittest
import urllib.error
from unittest import mock

import support
from fresh_tube import feed
from fresh_tube.errors import NETWORK, FreshTubeError


class Parse(unittest.TestCase):
    def test_parses_name_latest_by_date_and_recent_ids(self):
        parsed = feed.parse_feed(support.fixture("feed.xml"))
        self.assertEqual(parsed["name"], "Example Channel")
        self.assertEqual(parsed["latest"], {"videoId": "newest22222", "title": "Newest video",
                                            "published": "2026-09-15T17:00:03+00:00",
                                            "thumbnail": "https://i.ytimg.com/vi/newest22222/hqdefault.jpg"})
        self.assertEqual(parsed["recent"], ["older111111", "newest22222", "middle33333"])

    def test_empty_feed_has_no_latest(self):
        xml = b'<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"><title>Quiet</title></feed>'
        self.assertEqual(feed.parse_feed(xml), {"name": "Quiet", "latest": None, "recent": []})

    def test_entry_without_thumbnail_still_counts(self):
        xml = (b'<feed xmlns="http://www.w3.org/2005/Atom" xmlns:yt="http://www.youtube.com/xml/schemas/2015">'
               b'<title>T</title><entry><yt:videoId>abc</yt:videoId><title>A</title>'
               b'<published>2026-01-01T00:00:00+00:00</published></entry></feed>')
        self.assertEqual(feed.parse_feed(xml)["latest"]["thumbnail"], "")

    def test_invalid_xml_is_a_network_error(self):
        with self.assertRaises(FreshTubeError) as caught:
            feed.parse_feed(b"<html>not a feed")
        self.assertEqual(caught.exception.code, NETWORK)


class Fetch(unittest.TestCase):
    def test_feed_url(self):
        self.assertEqual(feed.feed_url("UC1"), "https://www.youtube.com/feeds/videos.xml?channel_id=UC1")

    def test_fetch_feed_uses_fetch_url(self):
        with mock.patch("fresh_tube.feed.fetch_url", return_value=support.fixture("feed.xml")) as fetch:
            parsed = feed.fetch_feed("UC1", timeout=3)
        fetch.assert_called_once_with("https://www.youtube.com/feeds/videos.xml?channel_id=UC1", 3)
        self.assertEqual(parsed["latest"]["videoId"], "newest22222")

    def test_http_errors_become_network_errors(self):
        def boom(request, timeout):
            raise urllib.error.HTTPError(request.full_url, 404, "Not Found", {}, None)
        with mock.patch("fresh_tube.feed.urlopen", boom):
            with self.assertRaises(FreshTubeError) as caught:
                feed.fetch_url("https://example.invalid/x", 1)
        self.assertEqual(caught.exception.code, NETWORK)
        self.assertIn("404", str(caught.exception))

    def test_unreachable_host_is_a_network_error(self):
        def boom(request, timeout):
            raise urllib.error.URLError("no route")
        with mock.patch("fresh_tube.feed.urlopen", boom):
            with self.assertRaises(FreshTubeError) as caught:
                feed.fetch_url("https://example.invalid/x", 1)
        self.assertEqual(caught.exception.code, NETWORK)

    def test_request_carries_a_browser_user_agent(self):
        seen = {}

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

            def read(self):
                return b"body"

        def capture(request, timeout):
            seen["ua"] = request.get_header("User-agent")
            seen["timeout"] = timeout
            return Response()
        with mock.patch("fresh_tube.feed.urlopen", capture):
            self.assertEqual(feed.fetch_url("https://example.invalid/x", 7), b"body")
        self.assertIn("Mozilla", seen["ua"])
        self.assertEqual(seen["timeout"], 7)
```

- [ ] **Step 2: Correr y ver que falla**

Run: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_feed.py' -v`
Expected: FAIL con `ModuleNotFoundError: No module named 'fresh_tube.feed'`.

- [ ] **Step 3: Escribir feed.py**

`lib/fresh_tube/feed.py`:

```python
"""One channel's RSS feed: download it and pick the newest video."""
import socket
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

from .errors import NETWORK, FreshTubeError

FEED_URL = "https://www.youtube.com/feeds/videos.xml?channel_id={}"
USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36"
NS = {"atom": "http://www.w3.org/2005/Atom",
      "yt": "http://www.youtube.com/xml/schemas/2015",
      "media": "http://search.yahoo.com/mrss/"}

urlopen = urllib.request.urlopen  # module-level so tests can replace it


def feed_url(channel_id):
    return FEED_URL.format(channel_id)


def fetch_url(url, timeout):
    """The body at `url`, or a network error saying why."""
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept-Language": "en"})
    try:
        with urlopen(request, timeout=timeout) as response:
            return response.read()
    except urllib.error.HTTPError as e:
        raise FreshTubeError(f"HTTP {e.code} from {url}", NETWORK)
    except (urllib.error.URLError, socket.timeout, TimeoutError, OSError) as e:
        reason = getattr(e, "reason", e)
        raise FreshTubeError(f"Could not reach {url}: {reason}", NETWORK)


def _text(element, path):
    found = element.find(path, NS)
    return (found.text or "").strip() if found is not None else ""


def parse_feed(data):
    """{"name", "latest", "recent"} from the Atom document; latest is the newest by date, not by position."""
    try:
        root = ET.fromstring(data)
    except ET.ParseError as e:
        raise FreshTubeError(f"Feed is not valid XML: {e}", NETWORK)
    entries = []
    for entry in root.findall("atom:entry", NS):
        video_id = _text(entry, "yt:videoId")
        if not video_id:
            continue
        thumbnail = entry.find("media:group/media:thumbnail", NS)
        entries.append({"videoId": video_id, "title": _text(entry, "atom:title"),
                        "published": _text(entry, "atom:published"),
                        "thumbnail": thumbnail.get("url", "") if thumbnail is not None else ""})
    latest = max(entries, key=lambda e: e["published"]) if entries else None
    return {"name": _text(root, "atom:title"), "latest": latest, "recent": [e["videoId"] for e in entries]}


def fetch_feed(channel_id, timeout=10):
    return parse_feed(fetch_url(feed_url(channel_id), timeout))
```

- [ ] **Step 4: Correr y ver que pasa**

Run: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v`
Expected: todos `ok`. Las fechas de YouTube son ISO con `+00:00`, así que comparar los strings ordena bien.

- [ ] **Step 5: Commit**

```bash
git add lib/fresh_tube/feed.py tests/fixtures/feed.xml tests/test_feed.py
git commit -F - <<'EOF'
Read a channel's RSS feed and pick its newest video

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_011DPqvBbwQCc2wPWRZoVQkC
EOF
```

---

### Task 5: resolve.py: de lo pegado al channel_id

**Files:**
- Create: `lib/fresh_tube/resolve.py`
- Create: `tests/fixtures/channel_page.html`
- Create: `tests/fixtures/watch_page.html`
- Create: `tests/fixtures/no_id_page.html`
- Create: `tests/test_resolve.py`

**Interfaces:**
- Consumes: `feed.fetch_url(url, timeout)`, `errors.FreshTubeError`, `USAGE`, `NETWORK`.
- Produces: `resolve.looks_like_youtube(text) -> bool`; `resolve.normalize_input(text) -> str` (URL con `https://`); `resolve.direct_channel_id(url) -> str|None`; `resolve.channel_id_from_html(html) -> str|None`; `resolve.ytdlp_channel_id(url) -> str|None`; `resolve.resolve_channel_id(text, fetch=None, ytdlp=None) -> str` (con `None` usa `feed.fetch_url` y `ytdlp_channel_id` del módulo, resueltos al llamar para que `mock.patch` funcione) (lanza `USAGE` "That doesn't look like a YouTube channel" o `NETWORK` "Couldn't find that channel"). `PAGE_TIMEOUT = 20`, `YTDLP_TIMEOUT = 20`.

- [ ] **Step 1: Fixtures y tests (fallan)**

`tests/fixtures/channel_page.html` (ids señuelo de otros canales antes del canonical, como en la página real):

```html
<!DOCTYPE html><html><head>
<meta charset="utf-8">
<script>var ytInitialData = {"header":{"related":[{"channelId":"UCdecoy0000000000000000x"},{"channelId":"UCother000000000000000xy"}]}};</script>
<link rel="canonical" href="https://www.youtube.com/channel/UCXuqSBlHAE6Xw-yeJA0Tunw">
<meta itemprop="identifier" content="UCXuqSBlHAE6Xw-yeJA0Tunw">
<title>Linus Tech Tips - YouTube</title>
</head><body></body></html>
```

`tests/fixtures/watch_page.html`:

```html
<!DOCTYPE html><html><head>
<meta charset="utf-8">
<link rel="canonical" href="https://www.youtube.com/watch?v=3xngArcFpek">
<meta itemprop="channelId" content="UCXuqSBlHAE6Xw-yeJA0Tunw">
<title>I Promise you this is NOT Stupid - YouTube</title>
</head><body></body></html>
```

`tests/fixtures/no_id_page.html`:

```html
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Before you continue to YouTube</title></head>
<body><form action="https://consent.youtube.com/save"><button>Accept all</button></form></body></html>
```

`tests/test_resolve.py`:

```python
import unittest
from unittest import mock

import support
from fresh_tube import resolve
from fresh_tube.errors import NETWORK, USAGE, FreshTubeError

LTT = "UCXuqSBlHAE6Xw-yeJA0Tunw"


class Inputs(unittest.TestCase):
    def test_looks_like_youtube(self):
        for good in ("https://www.youtube.com/@LinusTechTips", "youtube.com/c/LinusTechTips",
                     "https://youtu.be/3xngArcFpek", "@LinusTechTips", LTT,
                     "https://www.youtube.com/channel/" + LTT + "/videos", "https://m.youtube.com/@x"):
            self.assertTrue(resolve.looks_like_youtube(good), good)
        for bad in ("", "   ", "https://vimeo.com/x", "linus tech tips", "@two words", "UCshort",
                    "https://notyoutube.com/@x"):
            self.assertFalse(resolve.looks_like_youtube(bad), bad)

    def test_normalize_input(self):
        self.assertEqual(resolve.normalize_input("@LinusTechTips"), "https://www.youtube.com/@LinusTechTips")
        self.assertEqual(resolve.normalize_input(LTT), "https://www.youtube.com/channel/" + LTT)
        self.assertEqual(resolve.normalize_input("youtube.com/c/LinusTechTips"), "https://youtube.com/c/LinusTechTips")
        self.assertEqual(resolve.normalize_input("  https://www.youtube.com/@x/videos "),
                         "https://www.youtube.com/@x/videos")

    def test_direct_channel_id(self):
        self.assertEqual(resolve.direct_channel_id("https://www.youtube.com/channel/" + LTT), LTT)
        self.assertEqual(resolve.direct_channel_id("https://www.youtube.com/channel/" + LTT + "/videos?x=1"), LTT)
        self.assertIsNone(resolve.direct_channel_id("https://www.youtube.com/@LinusTechTips"))
        # A watch URL is not a channel URL even when an id appears elsewhere in it.
        self.assertIsNone(resolve.direct_channel_id("https://www.youtube.com/watch?v=abc&ab_channel=" + LTT))


class Html(unittest.TestCase):
    def test_canonical_link_wins_over_decoy_ids(self):
        self.assertEqual(resolve.channel_id_from_html(support.fixture("channel_page.html").decode()), LTT)

    def test_watch_page_uses_itemprop(self):
        self.assertEqual(resolve.channel_id_from_html(support.fixture("watch_page.html").decode()), LTT)

    def test_page_without_id(self):
        self.assertIsNone(resolve.channel_id_from_html(support.fixture("no_id_page.html").decode()))


class Resolve(unittest.TestCase):
    def test_direct_id_needs_no_network(self):
        never = mock.Mock(side_effect=AssertionError("no network expected"))
        self.assertEqual(resolve.resolve_channel_id(LTT, fetch=never, ytdlp=never), LTT)
        self.assertEqual(resolve.resolve_channel_id("https://www.youtube.com/channel/" + LTT, fetch=never, ytdlp=never), LTT)

    def test_handle_via_page(self):
        fetch = mock.Mock(return_value=support.fixture("channel_page.html"))
        ytdlp = mock.Mock(side_effect=AssertionError("yt-dlp not expected"))
        self.assertEqual(resolve.resolve_channel_id("@LinusTechTips", fetch=fetch, ytdlp=ytdlp), LTT)
        fetch.assert_called_once_with("https://www.youtube.com/@LinusTechTips", 20)

    def test_video_url_adds_its_channel(self):
        fetch = mock.Mock(return_value=support.fixture("watch_page.html"))
        self.assertEqual(resolve.resolve_channel_id("https://youtu.be/3xngArcFpek", fetch=fetch, ytdlp=mock.Mock()), LTT)

    def test_falls_back_to_ytdlp(self):
        fetch = mock.Mock(return_value=support.fixture("no_id_page.html"))
        ytdlp = mock.Mock(return_value=LTT)
        self.assertEqual(resolve.resolve_channel_id("https://www.youtube.com/@Someone", fetch=fetch, ytdlp=ytdlp), LTT)
        ytdlp.assert_called_once_with("https://www.youtube.com/@Someone")

    def test_page_fetch_failure_still_tries_ytdlp(self):
        fetch = mock.Mock(side_effect=FreshTubeError("HTTP 404", NETWORK))
        ytdlp = mock.Mock(return_value=LTT)
        self.assertEqual(resolve.resolve_channel_id("@Someone", fetch=fetch, ytdlp=ytdlp), LTT)

    def test_nothing_found(self):
        fetch = mock.Mock(return_value=support.fixture("no_id_page.html"))
        ytdlp = mock.Mock(return_value=None)
        with self.assertRaises(FreshTubeError) as caught:
            resolve.resolve_channel_id("@Nobody", fetch=fetch, ytdlp=ytdlp)
        self.assertEqual(caught.exception.code, NETWORK)
        self.assertEqual(str(caught.exception), "Couldn't find that channel")

    def test_not_youtube(self):
        with self.assertRaises(FreshTubeError) as caught:
            resolve.resolve_channel_id("https://vimeo.com/x", fetch=mock.Mock(), ytdlp=mock.Mock())
        self.assertEqual(caught.exception.code, USAGE)
        self.assertEqual(str(caught.exception), "That doesn't look like a YouTube channel")


class YtDlp(unittest.TestCase):
    def test_reads_the_printed_id(self):
        done = mock.Mock(returncode=0, stdout=LTT + "\n")
        with mock.patch("fresh_tube.resolve.subprocess.run", return_value=done) as run:
            self.assertEqual(resolve.ytdlp_channel_id("https://www.youtube.com/@x"), LTT)
        self.assertEqual(run.call_args.args[0][:2], ["yt-dlp", "--flat-playlist"])
        self.assertEqual(run.call_args.kwargs["timeout"], 20)

    def test_missing_or_failing_ytdlp_is_none(self):
        with mock.patch("fresh_tube.resolve.subprocess.run", side_effect=FileNotFoundError):
            self.assertIsNone(resolve.ytdlp_channel_id("https://www.youtube.com/@x"))
        with mock.patch("fresh_tube.resolve.subprocess.run", return_value=mock.Mock(returncode=1, stdout="NA\n")):
            self.assertIsNone(resolve.ytdlp_channel_id("https://www.youtube.com/@x"))
        with mock.patch("fresh_tube.resolve.subprocess.run", return_value=mock.Mock(returncode=0, stdout="NA\n")):
            self.assertIsNone(resolve.ytdlp_channel_id("https://www.youtube.com/@x"))
```

- [ ] **Step 2: Correr y ver que falla**

Run: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_resolve.py' -v`
Expected: FAIL con `ModuleNotFoundError: No module named 'fresh_tube.resolve'`.

- [ ] **Step 3: Escribir resolve.py**

`lib/fresh_tube/resolve.py`:

```python
"""Turn whatever the user pasted into a YouTube channel id."""
import re
import subprocess

from .errors import NETWORK, USAGE, FreshTubeError
from .feed import fetch_url

CHANNEL_ID = r"UC[0-9A-Za-z_-]{22}"
CHANNEL_ID_RE = re.compile(r"^" + CHANNEL_ID + r"$")
CHANNEL_PATH_RE = re.compile(r"youtube\.com/channel/(" + CHANNEL_ID + r")(?:[/?#]|$)")
# The channel page lists other channels' ids in its JSON before its own, so
# only the canonical link and the itemprop metas are trusted.
CANONICAL_RE = re.compile(r'<link\s+rel="canonical"\s+href="https://www\.youtube\.com/channel/(' + CHANNEL_ID + r')"')
ITEMPROP_RE = re.compile(r'<meta\s+itemprop="(?:identifier|channelId)"\s+content="(' + CHANNEL_ID + r')"')
HANDLE_RE = re.compile(r"^@[A-Za-z0-9._-]+$")
YOUTUBE_HOST_RE = re.compile(r"^(https?://)?(www\.|m\.)?(youtube\.com|youtu\.be)(/|$)", re.IGNORECASE)
PAGE_TIMEOUT = 20
YTDLP_TIMEOUT = 20


def looks_like_youtube(text):
    text = (text or "").strip()
    if not text or re.search(r"\s", text):
        return False
    return bool(CHANNEL_ID_RE.match(text) or HANDLE_RE.match(text) or YOUTUBE_HOST_RE.match(text))


def normalize_input(text):
    text = (text or "").strip()
    if CHANNEL_ID_RE.match(text):
        return "https://www.youtube.com/channel/" + text
    if HANDLE_RE.match(text):
        return "https://www.youtube.com/" + text
    if not re.match(r"^https?://", text, re.IGNORECASE):
        return "https://" + text
    return text


def direct_channel_id(url):
    found = CHANNEL_PATH_RE.search(url)
    return found.group(1) if found else None


def channel_id_from_html(html):
    for pattern in (CANONICAL_RE, ITEMPROP_RE):
        found = pattern.search(html)
        if found:
            return found.group(1)
    return None


def ytdlp_channel_id(url):
    """yt-dlp's answer for the channel behind `url`, or None when it is missing or cannot tell."""
    try:
        done = subprocess.run(["yt-dlp", "--flat-playlist", "-I", "0", "--print", "playlist:channel_id", url],
                              capture_output=True, text=True, timeout=YTDLP_TIMEOUT)
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        return None
    if done.returncode != 0:
        return None
    for line in done.stdout.splitlines():
        if CHANNEL_ID_RE.match(line.strip()):
            return line.strip()
    return None


def resolve_channel_id(text, fetch=None, ytdlp=None):
    # Looked up at call time, not bound as defaults, so tests can patch the module.
    fetch = fetch or fetch_url
    ytdlp = ytdlp or ytdlp_channel_id
    if not looks_like_youtube(text):
        raise FreshTubeError("That doesn't look like a YouTube channel", USAGE)
    url = normalize_input(text)
    direct = direct_channel_id(url)
    if direct:
        return direct
    try:
        html = fetch(url, PAGE_TIMEOUT).decode("utf-8", "replace")
    except FreshTubeError:
        html = ""
    found = channel_id_from_html(html) if html else None
    if not found:
        found = ytdlp(url)
    if not found:
        raise FreshTubeError("Couldn't find that channel", NETWORK)
    return found
```

- [ ] **Step 4: Correr y ver que pasa**

Run: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v`
Expected: todos `ok`.

- [ ] **Step 5: Commit**

```bash
git add lib/fresh_tube/resolve.py tests/fixtures/channel_page.html tests/fixtures/watch_page.html tests/fixtures/no_id_page.html tests/test_resolve.py
git commit -F - <<'EOF'
Resolve handles, channel URLs and video URLs to a channel id

The canonical link of the channel page is the source of truth; yt-dlp is
the fallback when the page gives nothing away.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_011DPqvBbwQCc2wPWRZoVQkC
EOF
```

---

### Task 6: CLI: add, remove, channels

**Files:**
- Modify: `lib/fresh_tube/cli.py`
- Modify: `tests/test_cli.py` (agregar al final)

**Interfaces:**
- Consumes: `resolve.resolve_channel_id(text)`, `feed.fetch_feed(channel_id)`, `store.load_channels/save_channels/find_channel/add_channel/remove_channel/load_state/save_state/update_feed/drop_feed/prune_seen/now_iso`.
- Produces: subcomandos `add <url>`, `remove <channel_id>`, `channels [--json]`; `cli.channel_payload(channel, state) -> dict` (canal + `lastError` tomado de `state["feeds"][id]`). `add` imprime el canal; `remove` imprime `{"removed": id}`; `channels --json` imprime `{"channels": [...]}`.

- [ ] **Step 1: Agregar los tests (fallan)**

Al final de `tests/test_cli.py` (y sumar `from unittest import mock` y `from fresh_tube import cli` y `from fresh_tube.errors import NETWORK, FreshTubeError` arriba, junto a los imports existentes):

```python
LTT = "UCXuqSBlHAE6Xw-yeJA0Tunw"


class Channels(CliTest):
    def setUp(self):
        super().setUp()
        self.box.apply()

    def add(self, text, page="channel_page.html"):
        with mock.patch("fresh_tube.resolve.fetch_url", return_value=support.fixture(page)), \
             mock.patch("fresh_tube.feed.fetch_url", return_value=support.fixture("feed.xml")), \
             mock.patch("fresh_tube.resolve.ytdlp_channel_id", return_value=None), \
             support.captured() as (out, err):
            code = cli.main(["add", "--", text])
        return code, out.getvalue(), err.getvalue()

    def test_add_prints_the_channel_and_caches_its_feed(self):
        code, out, err = self.add("@LinusTechTips")
        self.assertEqual(code, 0, err)
        channel = json.loads(out)
        self.assertEqual(channel["id"], LTT)
        self.assertEqual(channel["name"], "Example Channel")
        self.assertEqual(channel["lastError"], "")
        state = self.box.read_json(self.box.state_file)
        self.assertEqual(state["feeds"][LTT]["latest"]["videoId"], "newest22222")
        listed = self.json("channels", "--json")["channels"]
        self.assertEqual([c["id"] for c in listed], [LTT])
        self.assertIn("Example Channel", self.ok("channels"))

    def test_add_errors(self):
        self.assertEqual(self.add("https://vimeo.com/x")[0], 2)
        self.assertEqual(self.add("@Nobody", page="no_id_page.html")[0], 3)
        self.assertEqual(self.add("@LinusTechTips")[0], 0)
        code, out, err = self.add("https://www.youtube.com/channel/" + LTT)
        self.assertEqual(code, 4)
        self.assertEqual(err.strip(), "fresh-tube: Already added")
        self.assertEqual(len(self.json("channels", "--json")["channels"]), 1)

    def test_add_reports_a_feed_that_cannot_be_fetched(self):
        with mock.patch("fresh_tube.resolve.fetch_url", return_value=support.fixture("channel_page.html")), \
             mock.patch("fresh_tube.feed.fetch_url", side_effect=FreshTubeError("HTTP 404 from feed", NETWORK)), \
             support.captured() as (out, err):
            self.assertEqual(cli.main(["add", "@LinusTechTips"]), 3)
        self.assertIn("HTTP 404", err.getvalue())
        self.assertEqual(self.json("channels", "--json"), {"channels": []})

    def test_remove(self):
        self.add("@LinusTechTips")
        self.assertEqual(self.json("remove", LTT), {"removed": LTT})
        self.assertEqual(self.json("channels", "--json"), {"channels": []})
        self.assertNotIn(LTT, self.box.read_json(self.box.state_file)["feeds"])
        self.assertIn("No such channel", self.fails(5, "remove", LTT))
```

- [ ] **Step 2: Correr y ver que falla**

Run: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_cli.py' -v`
Expected: FAIL: `cli.main(["add", ...])` lanza `SystemExit(2)` porque `add` no es un comando.

- [ ] **Step 3: Implementar los tres comandos**

Reemplazar `lib/fresh_tube/cli.py` completo por:

```python
"""fresh-tube: the latest unseen video of the YouTube channels you pick."""
import argparse
import json
import sys

from . import feed, resolve, store
from .errors import DUPLICATE, FreshTubeError


def emit(data):
    print(json.dumps(data, ensure_ascii=False))


def channel_payload(channel, state):
    feed_state = state["feeds"].get(channel["id"]) or {}
    return dict(channel, lastError=feed_state.get("lastError", ""))


def cmd_add(args):
    channel_id = resolve.resolve_channel_id(args.url)
    if store.find_channel(store.load_channels(), channel_id):
        raise FreshTubeError("Already added", DUPLICATE)
    # Network first, files last: the fetch can take seconds and the panel may
    # write state (a seen video, a preference) in the meantime.
    parsed = feed.fetch_feed(channel_id)
    channels = store.load_channels()
    channel = store.add_channel(channels, channel_id, parsed["name"] or channel_id)
    store.save_channels(channels)
    state = store.load_state()
    store.update_feed(state, channel_id, parsed, store.now_iso())
    store.save_state(state)
    emit(channel_payload(channel, state))
    return 0


def cmd_remove(args):
    channels = store.load_channels()
    store.remove_channel(channels, args.channel_id)
    store.save_channels(channels)
    state = store.load_state()
    store.drop_feed(state, args.channel_id)
    store.prune_seen(state)
    store.save_state(state)
    emit({"removed": args.channel_id})
    return 0


def cmd_channels(args):
    state = store.load_state()
    payload = {"channels": [channel_payload(c, state) for c in store.load_channels()]}
    if args.json:
        emit(payload)
        return 0
    for c in payload["channels"]:
        line = f"{c['id']}  {c['name']}"
        if c["lastError"]:
            line += f"  ({c['lastError']})"
        print(line)
    return 0


def build_parser():
    parser = argparse.ArgumentParser(prog="fresh-tube", description=__doc__)
    sub = parser.add_subparsers(dest="command", metavar="command")
    sub.required = True

    p = sub.add_parser("add", help="add a channel by URL, @handle or id")
    p.add_argument("url")
    p.set_defaults(func=cmd_add)

    p = sub.add_parser("remove", help="remove a channel by id")
    p.add_argument("channel_id")
    p.set_defaults(func=cmd_remove)

    p = sub.add_parser("channels", help="list the channels")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_channels)

    return parser, sub


def main(argv=None):
    parser, _ = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except FreshTubeError as e:
        print(f"fresh-tube: {e}", file=sys.stderr)
        return e.code
```

- [ ] **Step 4: Correr y ver que pasa**

Run: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v`
Expected: todos `ok`.

- [ ] **Step 5: Probar contra la red real una vez, a mano**

Run (con un HOME temporal para no ensuciar el estado real):
```bash
XDG_CONFIG_HOME=/tmp/ft-cfg XDG_STATE_HOME=/tmp/ft-state bin/fresh-tube add @LinusTechTips
XDG_CONFIG_HOME=/tmp/ft-cfg XDG_STATE_HOME=/tmp/ft-state bin/fresh-tube channels
rm -rf /tmp/ft-cfg /tmp/ft-state
```
Expected: la primera línea es un JSON con `"id": "UCXuqSBlHAE6Xw-yeJA0Tunw"` y `"name": "Linus Tech Tips"`; la segunda lista ese canal.

- [ ] **Step 6: Commit**

```bash
git add lib/fresh_tube/cli.py tests/test_cli.py
git commit -F - <<'EOF'
Add, remove and list channels from the command line

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_011DPqvBbwQCc2wPWRZoVQkC
EOF
```

---

### Task 7: CLI: refresh y seen

**Files:**
- Modify: `lib/fresh_tube/cli.py`
- Modify: `tests/test_cli.py` (agregar al final)

**Interfaces:**
- Consumes: `feed.fetch_feed`, `store.*` de las Tareas 2 y 3.
- Produces: `cli.fetch_one(channel) -> (parsed|None, error_message)`; `cli.refresh_all(channels, cached: bool) -> payload` con `{"videos", "fetchedAt", "offline", "channelCount", "errors"}`; subcomandos `refresh [--json] [--cached]` y `seen <video_id>` (imprime `{"seen": id}`).

- [ ] **Step 1: Agregar los tests (fallan)**

Al final de `tests/test_cli.py`:

```python
class Refresh(CliTest):
    def setUp(self):
        super().setUp()
        self.box.apply()
        self.channels = [{"id": "UC1", "name": "One", "url": "u1", "addedAt": "t"},
                         {"id": "UC2", "name": "Two", "url": "u2", "addedAt": "t"}]
        self.box.write_json(self.box.channels_file, {"version": 1, "channels": self.channels})

    @staticmethod
    def two_feeds(channel_id, timeout=10):
        if channel_id == "UC1":
            return {"name": "One", "latest": {"videoId": "v1", "title": "First", "thumbnail": "t1",
                                              "published": "2026-09-15T10:00:00+00:00"}, "recent": ["v1"]}
        return {"name": "Two", "latest": {"videoId": "v2", "title": "Second", "thumbnail": "t2",
                                          "published": "2026-09-16T10:00:00+00:00"}, "recent": ["v2"]}

    def refresh(self, *extra, fetch=None):
        with mock.patch("fresh_tube.feed.fetch_feed", side_effect=fetch or self.two_feeds), \
             support.captured() as (out, err):
            code = cli.main(["refresh", "--json", *extra])
        self.assertEqual(code, 0, err.getvalue())
        return json.loads(out.getvalue())

    def test_live_refresh_lists_newest_first_and_caches(self):
        payload = self.refresh()
        self.assertEqual([v["videoId"] for v in payload["videos"]], ["v2", "v1"])
        self.assertEqual(payload["videos"][0]["channel"], "Two")
        self.assertEqual(payload["videos"][0]["url"], "https://www.youtube.com/watch?v=v2")
        self.assertFalse(payload["offline"])
        self.assertEqual(payload["channelCount"], 2)
        self.assertEqual(payload["errors"], [])
        self.assertRegex(payload["fetchedAt"], r"^\d{4}-")
        self.assertEqual(self.box.read_json(self.box.state_file)["feeds"]["UC1"]["latest"]["videoId"], "v1")

    def test_cached_refresh_needs_no_network(self):
        self.refresh()
        with mock.patch("fresh_tube.feed.fetch_feed", side_effect=AssertionError("network")), \
             support.captured() as (out, err):
            self.assertEqual(cli.main(["refresh", "--json", "--cached"]), 0, err.getvalue())
        payload = json.loads(out.getvalue())
        self.assertEqual([v["videoId"] for v in payload["videos"]], ["v2", "v1"])
        self.assertTrue(payload["offline"])

    def test_one_failing_channel_keeps_its_cache_and_reports(self):
        self.refresh()

        def flaky(channel_id, timeout=10):
            if channel_id == "UC2":
                raise FreshTubeError("HTTP 500 from feed", NETWORK)
            return self.two_feeds(channel_id)
        payload = self.refresh(fetch=flaky)
        self.assertEqual([v["videoId"] for v in payload["videos"]], ["v2", "v1"])
        self.assertFalse(payload["offline"])
        self.assertEqual(payload["errors"], [{"channelId": "UC2", "channel": "Two", "message": "HTTP 500 from feed"}])
        self.assertEqual(self.json("channels", "--json")["channels"][1]["lastError"], "HTTP 500 from feed")
        # A later good fetch clears the error.
        self.assertEqual(self.refresh()["errors"], [])

    def test_all_failing_is_offline_and_keeps_fetched_at(self):
        first = self.refresh()

        def down(channel_id, timeout=10):
            raise FreshTubeError("Could not reach", NETWORK)
        payload = self.refresh(fetch=down)
        self.assertTrue(payload["offline"])
        self.assertEqual(payload["fetchedAt"], first["fetchedAt"])
        self.assertEqual(len(payload["videos"]), 2)

    def test_seen_hides_the_video_and_prunes(self):
        self.refresh()
        self.assertEqual(self.json("seen", "v2"), {"seen": "v2"})
        self.assertEqual(self.json("seen", "v2"), {"seen": "v2"})
        self.assertEqual([v["videoId"] for v in self.refresh("--cached")["videos"]], ["v1"])

        def moved_on(channel_id, timeout=10):
            if channel_id == "UC2":
                return {"name": "Two", "latest": {"videoId": "v3", "title": "Third", "thumbnail": "t3",
                                                  "published": "2026-09-17T10:00:00+00:00"}, "recent": ["v3"]}
            return self.two_feeds(channel_id)
        payload = self.refresh(fetch=moved_on)
        self.assertEqual([v["videoId"] for v in payload["videos"]], ["v3", "v1"])
        self.assertEqual(self.box.read_json(self.box.state_file)["seen"], [])

    def test_no_channels(self):
        self.box.write_json(self.box.channels_file, {"version": 1, "channels": []})
        payload = self.refresh(fetch=mock.Mock(side_effect=AssertionError("network")))
        self.assertEqual(payload, {"videos": [], "fetchedAt": "", "offline": False, "channelCount": 0, "errors": []})

    def test_plain_refresh_prints_one_line_per_video(self):
        with mock.patch("fresh_tube.feed.fetch_feed", side_effect=self.two_feeds), support.captured() as (out, err):
            self.assertEqual(cli.main(["refresh"]), 0)
        self.assertEqual(out.getvalue().splitlines(), ["Two: Second  https://www.youtube.com/watch?v=v2",
                                                       "One: First  https://www.youtube.com/watch?v=v1"])
```

- [ ] **Step 2: Correr y ver que falla**

Run: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_cli.py' -v`
Expected: FAIL con `SystemExit: 2` en los tests de `Refresh` (comando desconocido).

- [ ] **Step 3: Implementar refresh y seen**

En `lib/fresh_tube/cli.py`, agregar `from concurrent.futures import ThreadPoolExecutor` a los imports, y estas funciones antes de `build_parser`:

```python
MAX_PARALLEL_FETCHES = 6


def fetch_one(channel):
    try:
        return feed.fetch_feed(channel["id"]), ""
    except FreshTubeError as e:
        return None, str(e)


def refresh_all(channels, cached):
    results = []
    if channels and not cached:
        with ThreadPoolExecutor(max_workers=MAX_PARALLEL_FETCHES) as pool:
            results = list(pool.map(fetch_one, channels))
    # Load the state only now: the fetches took a while and the panel may have
    # saved a preference or a seen video in the meantime.
    state = store.load_state()
    if channels and not cached:
        now = store.now_iso()
        any_ok = False
        for channel, (parsed, error) in zip(channels, results):
            if parsed is not None:
                store.update_feed(state, channel["id"], parsed, now)
                any_ok = True
            else:
                store.set_feed_error(state, channel["id"], error)
        if any_ok:
            state["fetchedAt"] = now
        store.prune_seen(state)
        store.save_state(state)
        offline = not any_ok
    else:
        offline = cached
    errors = []
    for channel in channels:
        message = (state["feeds"].get(channel["id"]) or {}).get("lastError", "")
        if message:
            errors.append({"channelId": channel["id"], "channel": channel.get("name", ""), "message": message})
    return {"videos": store.unseen_videos(state, channels), "fetchedAt": state["fetchedAt"],
            "offline": offline, "channelCount": len(channels), "errors": errors}


def cmd_refresh(args):
    payload = refresh_all(store.load_channels(), args.cached)
    if args.json:
        emit(payload)
        return 0
    for v in payload["videos"]:
        print(f"{v['channel']}: {v['title']}  {v['url']}")
    return 0


def cmd_seen(args):
    state = store.load_state()
    store.mark_seen(state, args.video_id)
    store.save_state(state)
    emit({"seen": args.video_id})
    return 0
```

Y en `build_parser`, antes de `return parser, sub`:

```python
    p = sub.add_parser("refresh", help="fetch every channel's feed and list the unseen videos")
    p.add_argument("--json", action="store_true")
    p.add_argument("--cached", action="store_true", help="only what is already on disk, no network")
    p.set_defaults(func=cmd_refresh)

    p = sub.add_parser("seen", help="mark a video as seen")
    p.add_argument("video_id")
    p.set_defaults(func=cmd_seen)
```

- [ ] **Step 4: Correr y ver que pasa**

Run: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v`
Expected: todos `ok`.

- [ ] **Step 5: Commit**

```bash
git add lib/fresh_tube/cli.py tests/test_cli.py
git commit -F - <<'EOF'
Refresh every feed in parallel and list what is still unseen

A channel that fails keeps its cache and reports the error; the state is
loaded after the fetches so a preference saved meanwhile survives.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_011DPqvBbwQCc2wPWRZoVQkC
EOF
```

---

### Task 8: CLI: prefs

**Files:**
- Modify: `lib/fresh_tube/cli.py`
- Modify: `tests/test_cli.py` (agregar al final)

**Interfaces:**
- Consumes: `store.load_state/save_state/set_pref`.
- Produces: subcomando `prefs get` y `prefs set <key> <value>`; ambos imprimen el objeto prefs completo `{"width", "height", "pinned"}`.

- [ ] **Step 1: Agregar el test (falla)**

Al final de `tests/test_cli.py`:

```python
class Prefs(CliTest):
    def test_get_and_set(self):
        self.assertEqual(self.json("prefs", "get"), {"width": 420, "height": 520, "pinned": False})
        self.assertEqual(self.json("prefs", "set", "width", "640")["width"], 640)
        self.assertEqual(self.json("prefs", "set", "pinned", "true")["pinned"], True)
        self.assertEqual(self.json("prefs", "get"), {"width": 640, "height": 520, "pinned": True})
        self.assertIn("between 220 and 4000", self.fails(2, "prefs", "set", "height", "10"))
        self.assertIn("Unknown preference", self.fails(2, "prefs", "set", "color", "red"))
        self.assertIn("needs a key and a value", self.fails(2, "prefs", "set", "width"))
```

- [ ] **Step 2: Correr y ver que falla**

Run: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_cli.py' -v`
Expected: FAIL en `Prefs.test_get_and_set` (returncode 2 en vez de 0 para `prefs get`).

- [ ] **Step 3: Implementar prefs**

En `lib/fresh_tube/cli.py`, sumar `USAGE` al import de `.errors` (`from .errors import DUPLICATE, USAGE, FreshTubeError`), agregar antes de `build_parser`:

```python
def cmd_prefs(args):
    state = store.load_state()
    if args.action == "set":
        if args.key is None or args.value is None:
            raise FreshTubeError("prefs set needs a key and a value", USAGE)
        store.set_pref(state, args.key, args.value)
        store.save_state(state)
    emit(state["prefs"])
    return 0
```

Y en `build_parser`, antes de `return parser, sub`:

```python
    p = sub.add_parser("prefs", help="read or change the popup preferences (width, height, pinned)")
    p.add_argument("action", choices=["get", "set"])
    p.add_argument("key", nargs="?")
    p.add_argument("value", nargs="?")
    p.set_defaults(func=cmd_prefs)
```

- [ ] **Step 4: Correr y ver que pasa**

Run: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v`
Expected: todos `ok`.

- [ ] **Step 5: Commit**

```bash
git add lib/fresh_tube/cli.py tests/test_cli.py
git commit -F - <<'EOF'
Persist the popup size and pinned state through prefs get/set

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_011DPqvBbwQCc2wPWRZoVQkC
EOF
```

---

### Task 9: FreshTubeModel.js y sus tests en Node

**Files:**
- Create: `FreshTubeModel.js`
- Create: `tests/model.test.js`

**Interfaces:**
- Produces (`.pragma library`, importado en QML como `import "FreshTubeModel.js" as Model`): `relativeTime(iso, nowMs) -> string` ("just now", "5 min ago", "3 h ago", "yesterday", "4 d ago", "Sep 1", "" si inválido); `formatClock(iso) -> "HH:mm"` local o ""; `looksLikeChannelInput(text) -> bool`; `playerArgs(command) -> string[]` (default `["mpv"]`); `playerName(command) -> string`.

- [ ] **Step 1: Escribir el test (falla)**

`tests/model.test.js`:

```js
const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")

const source = fs.readFileSync(path.join(__dirname, "..", "FreshTubeModel.js"), "utf8").replace(/^\.pragma library\s*$/m, "")
const Model = new Function(source + "\nreturn { relativeTime, formatClock, looksLikeChannelInput, playerArgs, playerName }")()

const NOW = Date.parse("2026-09-16T12:00:00Z")

test("relativeTime buckets", () => {
  assert.equal(Model.relativeTime("2026-09-16T11:59:40Z", NOW), "just now")
  assert.equal(Model.relativeTime("2026-09-16T11:55:00Z", NOW), "5 min ago")
  assert.equal(Model.relativeTime("2026-09-16T09:00:00Z", NOW), "3 h ago")
  assert.equal(Model.relativeTime("2026-09-15T08:00:00Z", NOW), "yesterday")
  assert.equal(Model.relativeTime("2026-09-12T12:00:00Z", NOW), "4 d ago")
  assert.equal(Model.relativeTime("2026-09-01T12:00:00Z", NOW), "Sep 1")
  assert.equal(Model.relativeTime("2026-09-16T13:00:00Z", NOW), "just now")
  assert.equal(Model.relativeTime("garbage", NOW), "")
  assert.equal(Model.relativeTime("", NOW), "")
  assert.equal(Model.relativeTime(null, NOW), "")
})

test("formatClock is hh:mm local", () => {
  const stamp = new Date(2026, 8, 16, 9, 5).toISOString()
  assert.equal(Model.formatClock(stamp), "09:05")
  assert.equal(Model.formatClock("nope"), "")
})

test("looksLikeChannelInput", () => {
  for (const good of ["https://www.youtube.com/@LinusTechTips", "youtube.com/c/x", "@handle",
                      "UCXuqSBlHAE6Xw-yeJA0Tunw", "https://youtu.be/abc", "  @spaced  "])
    assert.ok(Model.looksLikeChannelInput(good), good)
  for (const bad of ["", "  ", "two words", "https://vimeo.com/x", "UCshort", null])
    assert.ok(!Model.looksLikeChannelInput(bad), String(bad))
})

test("playerArgs and playerName", () => {
  assert.deepEqual(Model.playerArgs("mpv"), ["mpv"])
  assert.deepEqual(Model.playerArgs("  mpv --profile=yt  --mute "), ["mpv", "--profile=yt", "--mute"])
  assert.deepEqual(Model.playerArgs(""), ["mpv"])
  assert.deepEqual(Model.playerArgs(undefined), ["mpv"])
  assert.equal(Model.playerName("mpv --x"), "mpv")
  assert.equal(Model.playerName(null), "mpv")
})
```

- [ ] **Step 2: Correr y ver que falla**

Run: `node --test tests/model.test.js`
Expected: FAIL con `ENOENT ... FreshTubeModel.js`.

- [ ] **Step 3: Escribir FreshTubeModel.js**

```js
.pragma library

// Pure helpers for the Fresh Tube panel: no Quickshell, no files, so Node can
// test them (tests/model.test.js).

var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

function text(value) {
  return value === undefined || value === null ? "" : String(value)
}

// "just now", "5 min ago", "3 h ago", "yesterday", "4 d ago", then "Sep 1".
function relativeTime(iso, nowMs) {
  var t = Date.parse(text(iso))
  if (isNaN(t)) return ""
  var now = nowMs === undefined ? Date.now() : nowMs
  var seconds = Math.max(0, Math.round((now - t) / 1000))
  if (seconds < 60) return "just now"
  var minutes = Math.floor(seconds / 60)
  if (minutes < 60) return minutes + " min ago"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + " h ago"
  var days = Math.floor(hours / 24)
  if (days === 1) return "yesterday"
  if (days < 7) return days + " d ago"
  var date = new Date(t)
  return MONTHS[date.getMonth()] + " " + date.getDate()
}

function pad(n) {
  return (n < 10 ? "0" : "") + n
}

// Local wall-clock time of an ISO stamp, "09:05".
function formatClock(iso) {
  var t = Date.parse(text(iso))
  if (isNaN(t)) return ""
  var date = new Date(t)
  return pad(date.getHours()) + ":" + pad(date.getMinutes())
}

// A quick sanity check before the script does the real resolution.
function looksLikeChannelInput(value) {
  var s = text(value).trim()
  if (s === "" || /\s/.test(s)) return false
  return /^UC[0-9A-Za-z_-]{22}$/.test(s) || /^@[A-Za-z0-9._-]+$/.test(s)
    || /^(https?:\/\/)?(www\.|m\.)?(youtube\.com|youtu\.be)(\/|$)/i.test(s)
}

// The playerCommand setting split into argv; the video URL goes last.
function playerArgs(command) {
  var parts = text(command).trim().split(/\s+/).filter(function(p) { return p !== "" })
  return parts.length > 0 ? parts : ["mpv"]
}

function playerName(command) {
  return playerArgs(command)[0]
}
```

- [ ] **Step 4: Correr y ver que pasa**

Run: `node --test tests/model.test.js`
Expected: `# pass 4`, `# fail 0`.

- [ ] **Step 5: Commit**

```bash
git add FreshTubeModel.js tests/model.test.js
git commit -F - <<'EOF'
Add the panel's pure helpers with Node tests

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_011DPqvBbwQCc2wPWRZoVQkC
EOF
```

---

### Task 10: FeedPopup.qml: popup con pin y grip de resize

**Files:**
- Create: `FeedPopup.qml`
- Create: `THIRD_PARTY_NOTICES.md`

**Interfaces:**
- Consumes: `qs.Ui.BorderSurface`, `qs.Commons.{Style,Color,Border}`, `Quickshell.PanelWindow`, `Quickshell.Wayland.WlrLayershell`; el objeto `bar` (facade `PluginBarApi`: `position`, `barSize`, `activePopout`, `requestPopout(owner)`, `releasePopout(owner)`, `clickTargets`, `targetBelongsToWindow(t, w)`).
- Produces: componente `FeedPopup` con propiedades `anchorItem` (required), `bar` (required), `owner`, `open`, `pinned`, `resizable`, `contentWidth`, `contentHeight`, `minContentWidth` (300), `minContentHeight` (220), `gripColor`, `focusTarget`, `padding`, `margin`; funciones `fittedContentWidth(width, cap)`, `cappedContentHeight(height)`, `close()`; señales `resizeRequested(int width, int height)` (durante el arrastre, ya clampeadas) y `resized(int width, int height)` (al soltar); readonly `containsMouse`, `verticalContentInset`, `cardOrigin`, `popoutSwitchClosing`. El contenido hijo se ubica dentro de la tarjeta (`default property alias contentItem`).

Esta tarea no tiene test automático: la Tarea 11 lo monta y lo verifica a mano. Se verifica acá solo que el archivo carga sin errores QML.

- [ ] **Step 1: Escribir FeedPopup.qml**

```qml
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Layer-shell popup hanging from the bar icon, with two things the stock
// KeyboardPanel does not have: a pinned mode that survives clicks elsewhere
// and other panels opening, and a grip in the bottom-right corner to resize
// it. Adapted from Omarchy's Ui/KeyboardPanel.qml (MIT, David Heinemeier
// Hansson) and the pinned mode of yani.camera's CameraPopup.qml (MIT, Yani);
// see THIRD_PARTY_NOTICES.md.
//
// The card's leading edge lines up with the icon's leading edge along the
// bar, so growing it from the bottom-right corner never moves it. The popup
// never assigns its own contentWidth/contentHeight: it asks the owner through
// resizeRequested and the owner's binding feeds the new size back.
PanelWindow {
  id: root

  required property Item anchorItem
  required property QtObject bar
  property var owner: null
  property int margin: Style.gapsOut
  property int padding: Style.spacing.popupPadding
  property int contentWidth: Style.space(280)
  property int contentHeight: Style.space(200)
  property int minContentWidth: 300
  property int minContentHeight: 220
  property var borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
  property bool open: false
  property bool pinned: false
  property bool resizable: true
  property color gripColor: Color.foreground
  property int gap: Style.gapsOut
  property bool popoutSwitching: false
  property bool popoutSwitchClosing: false
  property bool focusPrimed: false

  // Item that takes keyboard focus once the panel maps.
  property Item focusTarget: null

  signal resizeRequested(int width, int height)
  signal resized(int width, int height)

  default property alias contentItem: contentHolder.children

  readonly property var coordinatorKey: owner || root
  readonly property var anchorWindow: anchorItem ? anchorItem.QsWindow.window : null
  readonly property string barPos: bar ? bar.position : "top"
  readonly property bool containsMouse: cardHover.hovered

  function close() {
    if (owner && "close" in owner) owner.close()
    else root.open = false
  }

  function beginFocusPrime() {
    if (open && backingWindowVisible) focusPrimeTimer.restart()
  }

  function clamp(value, low, high) {
    return Math.max(low, Math.min(high, value))
  }

  // --- screen + lifetime ---------------------------------------------------

  screen: anchorWindow ? anchorWindow.screen : null
  visible: open || card.opacity > 0 || popoutSwitching
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore

  WlrLayershell.namespace: "fresh-tube-popup"
  WlrLayershell.layer: WlrLayer.Overlay
  // Exclusive for a moment so a keyboard summon gets focus, then OnDemand so
  // clicks reach other outputs. Pinned goes straight to OnDemand: it must
  // never steal focus from the window the user is working in.
  WlrLayershell.keyboardFocus: open
    ? (pinned || focusPrimed ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive)
    : WlrKeyboardFocus.None

  onBackingWindowVisibleChanged: beginFocusPrime()

  anchors {
    top: true
    bottom: true
    left: true
    right: true
  }

  readonly property real _barStripSize: {
    if (!bar) return 0
    var actual = (root.barPos === "top" || root.barPos === "bottom") ? root.barH : root.barW
    return Math.max(bar.barSize, actual) + root.gap
  }

  // Unpinned: the whole screen is ours so a click anywhere dismisses.
  // Pinned: only the card takes input; everything else reaches the apps below.
  mask: Region {
    x: root.pinned ? root.cardOrigin.x : 0
    y: root.pinned ? root.cardOrigin.y : 0
    width: root.pinned ? root.contentWidth : root.screenW
    height: root.pinned ? root.contentHeight : root.screenH
  }

  TransformWatcher {
    id: anchorWatcher
    a: anchorWindow ? anchorWindow.contentItem : null
    b: anchorItem
  }

  readonly property point anchorScreenPos: {
    anchorWatcher.transform  // reactive dependency
    if (!anchorItem || !anchorWindow) return Qt.point(0, 0)
    return anchorItem.mapToItem(anchorWindow.contentItem, 0, 0)
  }
  readonly property real screenW: screen ? screen.width : 0
  readonly property real screenH: screen ? screen.height : 0
  readonly property real barW: anchorWindow ? anchorWindow.width : screenW
  readonly property real barH: anchorWindow ? anchorWindow.height : 0
  readonly property real availableCardWidth: screenW > 0
    ? Math.max(120, screenW - ((barPos === "left" || barPos === "right") ? barW + gap + margin : margin * 2))
    : 0
  readonly property real availableCardHeight: screenH > 0
    ? Math.max(120, screenH - ((barPos === "top" || barPos === "bottom") ? barH + gap + margin : margin * 2))
    : 0
  readonly property real verticalContentInset: padding * 2 + Border.top(borderSpec) + Border.bottom(borderSpec)

  function fittedContentWidth(width, cap) {
    var desired = Math.max(1, Number(width) || 1)
    var maxWidth = root.availableCardWidth > 0 ? root.availableCardWidth : desired
    if (cap !== undefined && Number(cap) > 0) maxWidth = Math.min(maxWidth, Number(cap))
    return Math.round(Math.min(desired, maxWidth))
  }

  function cappedContentHeight(height) {
    var desired = Math.max(root.padding * 2, Number(height) || root.padding * 2)
    var maxHeight = root.availableCardHeight > 0 ? root.availableCardHeight : desired
    return Math.round(Math.min(desired, maxHeight))
  }

  // Top-left of the card on screen: flush with the icon's leading edge along
  // the bar, one gap away from the bar across it, kept inside the screen.
  readonly property point cardOrigin: {
    if (!anchorItem || !bar) return Qt.point(margin, margin)
    var x = 0, y = 0
    if (barPos === "bottom") {
      x = anchorScreenPos.x
      y = screenH - barH - contentHeight - gap
    } else if (barPos === "left") {
      x = barW + gap
      y = anchorScreenPos.y
    } else if (barPos === "right") {
      x = screenW - barW - contentWidth - gap
      y = anchorScreenPos.y
    } else {
      x = anchorScreenPos.x
      y = barH + gap
    }
    x = clamp(x, margin, Math.max(margin, screenW - contentWidth - margin))
    y = clamp(y, margin, Math.max(margin, screenH - contentHeight - margin))
    return Qt.point(Math.round(x), Math.round(y))
  }

  // --- popout coordination ---------------------------------------------------

  // A pinned popup steps out of the bar's one-popout-at-a-time model: it
  // gives the slot back so other panels open without closing it, and takes
  // it again when unpinned while open.
  onPinnedChanged: {
    if (!bar || !open) return
    if (pinned) {
      if (bar.activePopout === coordinatorKey) bar.releasePopout(coordinatorKey)
    } else {
      bar.requestPopout(coordinatorKey)
    }
  }

  onOpenChanged: {
    if (open) {
      focusPrimed = false
      beginFocusPrime()
      if (focusTarget) Qt.callLater(function() {
        if (root.open && root.focusTarget) root.focusTarget.forceActiveFocus()
      })
    } else {
      focusPrimeTimer.stop()
      focusPrimed = false
    }
    if (!bar || pinned) return
    if (open) {
      popoutSwitchClosing = false
      popoutSwitching = bar.activePopout && bar.activePopout !== coordinatorKey
      bar.requestPopout(coordinatorKey)
      if (popoutSwitching) popoutSwitchTimer.restart()
    } else {
      popoutSwitchClosing = !!(owner && owner.popoutSwitchClosing)
      popoutSwitching = false
      if (bar.activePopout === coordinatorKey) bar.releasePopout(coordinatorKey)
      if (popoutSwitchClosing) closeSwitchTimer.restart()
    }
  }

  Timer {
    id: focusPrimeTimer
    interval: 75
    onTriggered: if (root.open) root.focusPrimed = true
  }

  Timer {
    id: popoutSwitchTimer
    interval: 150
    onTriggered: root.popoutSwitching = false
  }

  Timer {
    id: closeSwitchTimer
    interval: 1
    onTriggered: root.popoutSwitchClosing = false
  }

  // --- outside-click dismissal (unpinned only) ------------------------------

  MouseArea {
    id: dismissArea
    anchors.fill: parent
    enabled: root.open && !root.pinned
    acceptedButtons: Qt.AllButtons
    hoverEnabled: true
    property bool hoveringBar: false
    cursorShape: hoveringBar ? Qt.PointingHandCursor : Qt.ArrowCursor

    function inBarRegion(px, py) {
      if (root.barPos === "bottom") return py >= root.screenH - root._barStripSize
      if (root.barPos === "left") return px <= root._barStripSize
      if (root.barPos === "right") return px >= root.screenW - root._barStripSize
      return py <= root._barStripSize
    }

    function barPoint(px, py) {
      if (root.barPos === "bottom") return Qt.point(px, py - (root.screenH - root.barH))
      if (root.barPos === "right") return Qt.point(px - (root.screenW - root.barW), py)
      return Qt.point(px, py)
    }

    function pressTargetAt(px, py) {
      if (!root.anchorWindow || !root.anchorWindow.contentItem || !root.bar || !root.bar.clickTargets) return null
      var p = barPoint(px, py)
      var targets = root.bar.clickTargets
      for (var i = targets.length - 1; i >= 0; i--) {
        var target = targets[i]
        if (!target || !target.triggerPress || target.visible === false || target.opacity === 0 || !target.mapToItem) continue
        if (root.bar.targetBelongsToWindow && !root.bar.targetBelongsToWindow(target, root.anchorWindow)) continue
        var pos = root.anchorWindow.itemPosition(target)
        if (p.x >= pos.x && p.x <= pos.x + target.width && p.y >= pos.y && p.y <= pos.y + target.height) return target
      }
      return null
    }

    function forwardBarClick(px, py, button) {
      if (button !== Qt.LeftButton && button !== Qt.RightButton && button !== Qt.MiddleButton) return false
      var target = pressTargetAt(px, py)
      if (!target) return false
      target.triggerPress(button)
      return true
    }

    onPositionChanged: function(mouse) { hoveringBar = inBarRegion(mouse.x, mouse.y) }
    onExited: hoveringBar = false
    onClicked: function(mouse) {
      if (root.focusPrimed && inBarRegion(mouse.x, mouse.y) && forwardBarClick(mouse.x, mouse.y, mouse.button)) return
      root.close()
    }
  }

  // Other monitors get a transparent twin whose only job is to catch the
  // dismissing click. Not needed while pinned.
  Variants {
    model: root.open && !root.pinned ? Quickshell.screens : []

    delegate: Component {
      PanelWindow {
        required property var modelData

        screen: modelData
        visible: root.open && !!root.screen && modelData.name !== root.screen.name
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore

        WlrLayershell.namespace: "fresh-tube-popup-dismiss"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        anchors {
          top: true
          bottom: true
          left: true
          right: true
        }

        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.AllButtons
          onPressed: root.close()
        }
      }
    }
  }

  // --- card ----------------------------------------------------------------

  BorderSurface {
    id: card
    x: root.cardOrigin.x
    y: root.cardOrigin.y
    width: root.contentWidth
    height: root.contentHeight
    color: Color.popups.background
    borderSpec: root.borderSpec
    padding: root.padding
    radius: Style.cornerRadius
    opacity: root.open || root.popoutSwitching ? 1.0 : 0

    Behavior on opacity {
      enabled: !root.popoutSwitching && !root.popoutSwitchClosing
      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }

    HoverHandler { id: cardHover }

    // Clicks on the card stay on the card.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.AllButtons
    }

    Item {
      id: contentHolder
      anchors.fill: parent
      anchors.topMargin: card.contentTopInset
      anchors.rightMargin: card.contentRightInset
      anchors.bottomMargin: card.contentBottomInset
      anchors.leftMargin: card.contentLeftInset
      opacity: root.popoutSwitching ? (root.open ? 1.0 : 0) : 1.0

      Behavior on opacity {
        enabled: root.popoutSwitching
        NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
      }
    }

    // The resize grip, declared last so it sits above the content. The size
    // is computed from the press point in window coordinates, so it stays
    // stable while the card (and the grip with it) grows under the cursor.
    MouseArea {
      id: grip
      visible: root.resizable
      width: Style.space(18)
      height: Style.space(18)
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      hoverEnabled: true
      preventStealing: true
      acceptedButtons: Qt.LeftButton
      cursorShape: Qt.SizeFDiagCursor

      property point start
      property int startWidth
      property int startHeight

      onPressed: function(mouse) {
        start = mapToItem(null, mouse.x, mouse.y)
        startWidth = root.contentWidth
        startHeight = root.contentHeight
      }
      onPositionChanged: function(mouse) {
        if (!pressed) return
        var p = mapToItem(null, mouse.x, mouse.y)
        var maxW = Math.max(root.minContentWidth, root.screenW - card.x - root.margin)
        var maxH = Math.max(root.minContentHeight, root.screenH - card.y - root.margin)
        root.resizeRequested(
          Math.round(root.clamp(startWidth + (p.x - start.x), root.minContentWidth, maxW)),
          Math.round(root.clamp(startHeight + (p.y - start.y), root.minContentHeight, maxH)))
      }
      onReleased: root.resized(root.contentWidth, root.contentHeight)

      Text {
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.rightMargin: Style.space(3)
        anchors.bottomMargin: Style.space(2)
        text: "◢"
        textFormat: Text.PlainText
        color: root.gripColor
        opacity: grip.containsMouse || grip.pressed ? 0.9 : 0.35
        font.pixelSize: Style.font.caption

        Behavior on opacity { NumberAnimation { duration: 120 } }
      }
    }
  }
}
```

- [ ] **Step 2: Escribir THIRD_PARTY_NOTICES.md**

```markdown
# Third-party notices

`FeedPopup.qml` adapts two MIT-licensed files:

- `Ui/KeyboardPanel.qml` from the Omarchy shell.
  Copyright (c) David Heinemeier Hansson. MIT License.
- `CameraPopup.qml` from the `yani.camera` Omarchy plugin (the pinned mode).
  Copyright (c) Yani. MIT License.

MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 3: Verificar que la shell recarga sin errores**

Run: `sleep 2; quickshell log -p /usr/share/omarchy/shell -t 40 | grep -i -E 'error|warn|fresh' | tail -10`
Expected: solo líneas `Local plugin changed, reloading: io.github.ferc10110.fresh-tube`. El archivo todavía no lo instancia nadie, así que un error de sintaxis recién aparecería en la Tarea 11; leerlo dos veces antes de seguir.

- [ ] **Step 4: Commit**

```bash
git add FeedPopup.qml THIRD_PARTY_NOTICES.md
git commit -F - <<'EOF'
Add a pinnable, resizable popup anchored to the bar icon

Adapted from the shell's KeyboardPanel and yani.camera's pinned mode,
both MIT.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_011DPqvBbwQCc2wPWRZoVQkC
EOF
```

---

### Task 11: Widget con contador, runner, Panel y lista de videos

**Files:**
- Create: `FreshTubeCommand.qml`
- Create: `Panel.qml`
- Create: `VideoRow.qml`
- Create: `VideosView.qml`
- Modify: `BarWidget.qml` (reemplazo completo del mínimo de la Tarea 1)

**Interfaces:**
- Consumes: `FeedPopup` (Tarea 10), `FreshTubeModel.js` (Tarea 9), el CLI (Tareas 6 a 8), `qs.Ui.{Panel,BarWidget,WidgetButton,Button}`.
- Produces:
  - `FreshTubeCommand { program; timeoutMs (30000); running; start(args) -> bool; signal finished(int code, string out, string err) }`.
  - `Panel` (id `io.github.ferc10110.fresh-tube`) con propiedades `anchorItem`, `hostWidget`, `view`, `videos`, `errors`, `fetchedAt`, `offline`, `channelCount`, `notice`, `noticeIsError`, `pinned`, `popupWidth`, `popupHeight`, `playerFound`, `refreshing`, `foreground`, `dim`, `urgent`, `fontFamily`; funciones `refresh()`, `reloadCached()`, `play(video)`, `dismiss(video)`, `togglePin()`, `setPinned(bool)`, `setNotice(msg, isError)`, `focusCurrent()`; IPC `open/close/toggle/refresh/togglePin`.
  - `BarWidget` con `opened`, `pinned`, `count`, `open()`, `close()`, `togglePanel()`, `closeForPopoutSwitch()`, `refresh()`, `reloadCached()`, `isPoller()`.
  - `VideosView { host; focusItem }`, `VideoRow { host; video; selected; nowMs; signals activated(), dismissed() }`.

- [ ] **Step 1: FreshTubeCommand.qml**

```qml
import QtQuick
import Quickshell.Io

// One run of bin/fresh-tube at a time. It keeps what the command printed,
// reports once the process is gone, and stops a command that runs past its
// deadline so a stuck network call cannot leave the panel waiting.
Item {
  id: command

  property string program: ""
  property int timeoutMs: 30000
  property bool pending: false
  readonly property bool running: pending

  signal finished(int code, string out, string err)

  property string _out: ""
  property string _err: ""
  property int _code: 0
  property bool _exited: false
  property bool _outDone: false
  property bool _errDone: false
  property bool _timedOut: false

  function start(args) {
    if (pending) return false
    _out = ""
    _err = ""
    _code = 0
    _exited = false
    _outDone = false
    _errDone = false
    _timedOut = false
    pending = true
    proc.command = [program].concat(args)
    proc.running = true
    watchdog.restart()
    return true
  }

  function _finish() {
    if (!pending) return
    pending = false
    watchdog.stop()
    settle.stop()
    if (_timedOut) finished(1, _out, "fresh-tube: took too long and was stopped")
    else finished(_code, _out, _err)
  }

  function _maybeFinish() {
    if (_exited && _outDone && _errDone) _finish()
  }

  Process {
    id: proc

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        command._out = String(text || "")
        command._outDone = true
        command._maybeFinish()
      }
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        command._err = String(text || "")
        command._errDone = true
        command._maybeFinish()
      }
    }

    onExited: function(exitCode) {
      command._code = exitCode
      command._exited = true
      command._maybeFinish()
      // The streams close with the process; this only covers one that never says so.
      settle.restart()
    }
  }

  Timer {
    id: settle
    interval: 250
    onTriggered: command._finish()
  }

  Timer {
    id: watchdog
    interval: command.timeoutMs
    onTriggered: {
      command._timedOut = true
      proc.running = false
      settle.restart()
    }
  }
}
```

- [ ] **Step 2: VideoRow.qml**

```qml
import QtQuick
import qs.Commons
import qs.Ui
import "FreshTubeModel.js" as Model

// One video: thumbnail, title, channel and age. A click plays it; the ✕ that
// shows on hover (or on the keyboard-selected row) marks it seen instead.
Rectangle {
  id: row

  property var host: null
  property var video: null
  property bool selected: false
  property real nowMs: Date.now()

  signal activated()
  signal dismissed()

  readonly property color fg: host ? host.foreground : Color.foreground
  readonly property color dim: host ? host.dim : Qt.darker(Color.foreground, 1.55)
  readonly property string family: host ? host.fontFamily : Style.font.family
  readonly property bool showDismiss: hover.containsMouse || selected

  implicitHeight: Math.max(thumb.height, textColumn.implicitHeight) + Style.space(12)
  radius: Style.cornerRadius
  color: selected ? Style.selectionFillFor(fg, Color.accent)
    : (hover.containsMouse ? Style.hoverFillFor(fg, Color.accent) : "transparent")

  MouseArea {
    id: hover
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: row.activated()
  }

  Row {
    id: content
    x: Style.space(8)
    y: Style.space(6)
    width: row.width - Style.space(16)
    spacing: Style.space(10)

    Rectangle {
      id: thumb
      width: Style.space(96)
      height: Style.space(54)
      radius: Math.max(2, Style.cornerRadius / 2)
      color: Qt.rgba(row.fg.r, row.fg.g, row.fg.b, 0.08)
      clip: true

      Image {
        anchors.fill: parent
        source: row.video && row.video.thumbnail ? row.video.thumbnail : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        sourceSize.width: Style.space(192)
      }
    }

    Column {
      id: textColumn
      width: content.width - thumb.width - content.spacing
        - (dismissButton.visible ? dismissButton.implicitWidth + content.spacing : 0)
      spacing: Style.space(3)
      anchors.verticalCenter: parent.verticalCenter

      Text {
        width: parent.width
        text: row.video ? row.video.title : ""
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        maximumLineCount: 2
        elide: Text.ElideRight
        color: row.fg
        font.family: row.family
        font.pixelSize: Style.font.body
        font.bold: true
      }

      Text {
        width: parent.width
        text: row.video ? row.video.channel + " · " + Model.relativeTime(row.video.published, row.nowMs) : ""
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: row.dim
        font.family: row.family
        font.pixelSize: Style.font.caption
      }
    }

    Button {
      id: dismissButton
      visible: row.showDismiss
      anchors.verticalCenter: parent.verticalCenter
      iconText: "󰅖"
      tooltipText: "Mark as seen (Delete)"
      foreground: row.fg
      fontFamily: row.family
      onClicked: row.dismissed()
    }
  }
}
```

- [ ] **Step 3: VideosView.qml**

```qml
import QtQuick
import qs.Commons
import qs.Ui
import "FreshTubeModel.js" as Model

// The list of new videos with the header actions. Choosing a video asks the
// panel to play it; nothing here runs the script.
Item {
  id: view

  property var host: null
  property int selected: 0
  property real nowMs: Date.now()

  readonly property Item focusItem: keys
  readonly property color fg: host ? host.foreground : Color.foreground
  readonly property color dim: host ? host.dim : Qt.darker(Color.foreground, 1.55)
  readonly property color urgent: host ? host.urgent : Color.urgent
  readonly property string family: host ? host.fontFamily : Style.font.family
  readonly property var rows: host ? host.videos : []
  readonly property real gap: Style.space(8)

  onRowsChanged: if (selected >= rows.length) selected = Math.max(0, rows.length - 1)
  onVisibleChanged: if (visible) nowMs = Date.now()

  // Ages tick while the list is showing.
  Timer {
    interval: 60000
    running: view.visible
    repeat: true
    onTriggered: view.nowMs = Date.now()
  }

  function moveSelection(delta) {
    if (rows.length === 0) return
    selected = Math.max(0, Math.min(rows.length - 1, selected + delta))
    list.positionViewAtIndex(selected, ListView.Contain)
  }

  function handleKey(event) {
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    if (event.key === Qt.Key_Down) {
      moveSelection(1)
    } else if (event.key === Qt.Key_Up) {
      moveSelection(-1)
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      if (rows[selected]) host.play(rows[selected])
    } else if (event.key === Qt.Key_Delete) {
      if (rows[selected]) host.dismiss(rows[selected])
    } else if (event.key === Qt.Key_Escape) {
      host.close()
    } else if (ctrl && event.key === Qt.Key_R) {
      host.refresh()
    } else {
      return
    }
    event.accepted = true
  }

  // Holds keyboard focus: there is no text field in this view.
  Item {
    id: keys
    focus: true
    Keys.onPressed: function(event) { view.handleKey(event) }
  }

  Column {
    id: upper
    width: parent.width
    spacing: view.gap

    Item {
      width: parent.width
      height: Math.max(heading.implicitHeight, actions.implicitHeight)

      Text {
        id: heading
        anchors.verticalCenter: parent.verticalCenter
        text: "Fresh Tube"
        textFormat: Text.PlainText
        color: view.fg
        font.family: view.family
        font.pixelSize: Style.font.title
        font.bold: true
      }

      Row {
        id: actions
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(4)

        Button {
          iconText: "󰑐"
          iconSpinning: view.host ? view.host.refreshing : false
          tooltipText: "Refresh (Ctrl+R)"
          foreground: view.fg
          fontFamily: view.family
          onClicked: view.host.refresh()
        }

        Button {
          iconText: "󰐃"
          selected: view.host ? view.host.pinned : false
          tooltipText: view.host && view.host.pinned ? "Unpin: close when clicking elsewhere" : "Pin: stay open"
          foreground: view.fg
          fontFamily: view.family
          onClicked: view.host.togglePin()
        }
      }
    }

    Text {
      width: parent.width
      visible: text !== ""
      text: view.host ? view.host.notice : ""
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: view.host && view.host.noticeIsError ? view.urgent : view.dim
      font.family: view.family
      font.pixelSize: Style.font.bodySmall
    }
  }

  ListView {
    id: list
    anchors.top: upper.bottom
    anchors.topMargin: view.gap
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(4)
    width: parent.width
    visible: view.rows.length > 0
    clip: true
    spacing: Style.space(2)
    boundsBehavior: Flickable.StopAtBounds
    model: view.rows

    delegate: VideoRow {
      required property var modelData
      required property int index
      width: list.width
      host: view.host
      video: modelData
      selected: index === view.selected
      nowMs: view.nowMs
      onActivated: view.host.play(modelData)
      onDismissed: view.host.dismiss(modelData)
    }
  }

  Column {
    id: empty
    anchors.centerIn: parent
    width: parent.width
    visible: view.rows.length === 0
    spacing: Style.space(4)

    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      text: "Nothing new"
      textFormat: Text.PlainText
      color: view.fg
      font.family: view.family
      font.pixelSize: Style.font.subtitle
    }

    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      visible: text !== ""
      text: view.host && view.host.fetchedAt !== "" ? "updated " + Model.formatClock(view.host.fetchedAt) : ""
      textFormat: Text.PlainText
      color: view.dim
      font.family: view.family
      font.pixelSize: Style.font.caption
    }
  }
}
```

- [ ] **Step 4: Panel.qml**

```qml
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "FreshTubeModel.js" as Model

// The panel is a thin face over bin/fresh-tube: every fetch and every write
// happens in that script, and the panel only shows the JSON it prints.
Panel {
  id: root
  moduleName: "io.github.ferc10110.fresh-tube"
  ipcTarget: "io.github.ferc10110.fresh-tube"
  // Its own IpcHandler below adds refresh and togglePin to open/close/toggle.
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  property string view: "videos"
  property var videos: []
  property var errors: []
  property string fetchedAt: ""
  property bool offline: false
  property int channelCount: 0
  property string notice: ""
  property bool noticeIsError: false
  property bool pinned: false
  property int popupWidth: 420
  property int popupHeight: 520
  property bool playerFound: true
  property var pendingPlay: null
  property var prefsQueue: []

  readonly property bool refreshing: refreshCmd.running
  readonly property string program: pluginPath("bin/fresh-tube")
  readonly property string playerCommand: String(setting("playerCommand", "mpv") || "mpv")
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property Item currentFocus: videosView.focusItem

  // Absolute path of a file shipped inside this plugin, wherever it is installed.
  function pluginPath(relative) {
    var url = String(Qt.resolvedUrl(relative))
    return url.indexOf("file://") === 0 ? decodeURIComponent(url.substring(7)) : url
  }

  function parseJson(out) {
    try {
      var data = JSON.parse(String(out || ""))
      return data && typeof data === "object" ? data : null
    } catch (e) {
      return null
    }
  }

  function lastLine(err) {
    var lines = String(err || "").trim().split("\n")
    return lines[lines.length - 1].replace(/^fresh-tube: /, "")
  }

  function setNotice(message, isError) {
    notice = message || ""
    noticeIsError = isError === true
  }

  function focusCurrent() {
    Qt.callLater(function() {
      if (root.opened && root.currentFocus) root.currentFocus.forceActiveFocus()
    })
  }

  function applyPayload(data) {
    videos = Array.isArray(data.videos) ? data.videos : []
    errors = Array.isArray(data.errors) ? data.errors : []
    fetchedAt = String(data.fetchedAt || "")
    offline = data.offline === true
    channelCount = Number(data.channelCount) || 0
  }

  function loadCached() {
    cachedCmd.start(["refresh", "--json", "--cached"])
  }

  function reloadCached() { loadCached() }

  function refresh() {
    refreshCmd.start(["refresh", "--json"])
  }

  function checkPlayer() {
    playerCheckCmd.start(["-c", "command -v -- \"$0\"", Model.playerName(root.playerCommand)])
  }

  function removeVideo(videoId) {
    videos = videos.filter(function(v) { return v.videoId !== videoId })
  }

  function play(video) {
    if (!video || seenCmd.running) return
    if (!playerFound) {
      setNotice(Model.playerName(playerCommand) + " not found. Set playerCommand in shell.json.", true)
      return
    }
    pendingPlay = video
    seenCmd.start(["seen", "--", video.videoId])
  }

  function dismiss(video) {
    if (!video || seenCmd.running) return
    pendingPlay = null
    seenCmd.start(["seen", "--", video.videoId])
  }

  // Every `prefs set` rewrites the whole state file, so writes go one at a
  // time through a queue; two in parallel would drop one of the values.
  function queuePref(key, value) {
    prefsQueue = prefsQueue.concat([[key, String(value)]])
    pumpPrefs()
  }

  function pumpPrefs() {
    if (prefsCmd.running || prefsQueue.length === 0) return
    var next = prefsQueue[0]
    prefsQueue = prefsQueue.slice(1)
    prefsCmd.start(["prefs", "set", next[0], next[1]])
  }

  function setPinned(value) {
    var next = value === true
    if (pinned === next) return
    pinned = next
    queuePref("pinned", next ? "true" : "false")
  }

  function togglePin() { setPinned(!pinned) }

  function saveSize(w, h) {
    popupWidth = w
    popupHeight = h
    queuePref("width", w)
    queuePref("height", h)
  }

  onOpenedChanged: {
    if (opened) {
      setNotice("", false)
      view = "videos"
      loadCached()
      refresh()
      focusCurrent()
    }
  }

  onViewChanged: focusCurrent()

  Component.onCompleted: {
    prefsGetCmd.start(["prefs", "get"])
    checkPlayer()
    loadCached()
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
    function togglePin(): void { root.togglePin() }
  }

  FreshTubeCommand {
    id: prefsGetCmd
    program: root.program
    onFinished: function(code, out, err) {
      var data = root.parseJson(out)
      if (!data) return
      root.popupWidth = Number(data.width) || 420
      root.popupHeight = Number(data.height) || 520
      root.pinned = data.pinned === true
    }
  }

  FreshTubeCommand {
    id: prefsCmd
    program: root.program
    onFinished: function(code, out, err) {
      if (code !== 0) root.setNotice(root.lastLine(err) || "Could not save preferences", true)
      root.pumpPrefs()
    }
  }

  FreshTubeCommand {
    id: cachedCmd
    program: root.program
    onFinished: function(code, out, err) {
      var data = root.parseJson(out)
      if (code !== 0 || !data) {
        root.setNotice(root.lastLine(err) || "Could not read the cache", true)
        return
      }
      root.applyPayload(data)
    }
  }

  FreshTubeCommand {
    id: refreshCmd
    program: root.program
    timeoutMs: 60000
    onFinished: function(code, out, err) {
      var data = root.parseJson(out)
      if (code !== 0 || !data) {
        root.setNotice(root.lastLine(err) || "Could not refresh", true)
        return
      }
      root.applyPayload(data)
      if (data.offline === true && root.channelCount > 0) {
        var when = Model.formatClock(root.fetchedAt)
        root.setNotice("Offline, showing videos from " + (when !== "" ? when : "the last time"), false)
      } else if (root.errors.length > 0) {
        root.setNotice(root.errors.length + (root.errors.length === 1 ? " channel" : " channels") + " failed to update", false)
      } else if (!root.noticeIsError) {
        root.setNotice("", false)
      }
      if (root.hostWidget && typeof root.hostWidget.broadcast === "function") root.hostWidget.broadcast("reloadCached")
    }
  }

  FreshTubeCommand {
    id: seenCmd
    program: root.program
    onFinished: function(code, out, err) {
      var video = root.pendingPlay
      root.pendingPlay = null
      if (code !== 0) {
        root.setNotice(root.lastLine(err) || "Could not mark it as seen", true)
        return
      }
      var data = root.parseJson(out)
      var id = data ? String(data.seen || "") : ""
      if (id !== "") root.removeVideo(id)
      if (video) {
        Quickshell.execDetached(Model.playerArgs(root.playerCommand).concat([video.url]))
        if (!root.pinned) root.close()
      }
    }
  }

  FreshTubeCommand {
    id: playerCheckCmd
    program: "/bin/sh"
    onFinished: function(code, out, err) { root.playerFound = code === 0 }
  }

  FeedPopup {
    id: popup
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    pinned: root.pinned
    focusTarget: root.currentFocus
    gripColor: root.foreground
    contentWidth: popup.fittedContentWidth(root.popupWidth)
    contentHeight: popup.cappedContentHeight(root.popupHeight)
    onResizeRequested: function(w, h) {
      root.popupWidth = w
      root.popupHeight = h
    }
    onResized: function(w, h) { root.saveSize(w, h) }

    VideosView {
      id: videosView
      anchors.fill: parent
      visible: root.view === "videos"
      host: root
    }
  }
}
```

- [ ] **Step 5: BarWidget.qml (reemplazo completo)**

```qml
import QtQuick
import qs.Commons
import qs.Ui

// Bar entry point for Fresh Tube: the icon, the count of new videos, and the
// timer that keeps that count fresh. The panel owns everything else.
BarWidget {
  id: root
  moduleName: "io.github.ferc10110.fresh-tube"

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool pinned: panelLoader.item ? panelLoader.item.pinned === true : false
  readonly property int count: panelLoader.item && panelLoader.item.videos ? panelLoader.item.videos.length : 0
  // Forwarded so this widget can stand in for the panel as the bar's popout identity.
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  readonly property int refreshMs: Math.max(1, Number(setting("refreshMinutes", 15)) || 15) * 60000

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }

  // The bar closes the open popout when another one opens. A pinned panel stays.
  function closeForPopoutSwitch() {
    if (panelLoader.item && !pinned) panelLoader.item.closeForPopoutSwitch()
  }

  function refresh() { if (panelLoader.item) panelLoader.item.refresh() }
  function reloadCached() { if (panelLoader.item) panelLoader.item.reloadCached() }

  // One widget per monitor, but the feeds only need fetching once: the first
  // instance polls and, through broadcast, tells the others to reread the cache.
  function isPoller() {
    var items = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : []
    return items.length === 0 || items[0] === root
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // A first real fetch shortly after the shell starts, then every refreshMinutes.
  Timer {
    interval: 5000
    running: true
    repeat: false
    onTriggered: if (root.isPoller()) root.refresh()
  }

  Timer {
    interval: root.refreshMs
    running: true
    repeat: true
    onTriggered: if (root.isPoller()) root.refresh()
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.count > 0 ? "󰗃 " + root.count : "󰗃"
    fontSize: Style.font.bodySmall
    horizontalMargin: 6
    dimmed: root.count === 0
    tooltipText: root.count === 0 ? "Nothing new" : (root.count === 1 ? "1 new video" : root.count + " new videos")
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }
  }
}
```

- [ ] **Step 6: Verificar en la barra real**

Run:
```bash
sleep 2; quickshell log -p /usr/share/omarchy/shell -t 60 | grep -i -E 'error|warn|fresh' | tail -15
bin/fresh-tube add @LinusTechTips
bin/fresh-tube refresh --json | head -c 400; echo
```
Expected: sin errores QML; `add` imprime el canal; `refresh` lista al menos un video. Luego, en la barra:

1. El icono muestra `󰗃 1` (o más) a los pocos segundos y deja de estar atenuado.
2. Click en el icono: cae el panel alineado con el borde izquierdo del icono, con una fila con thumbnail, título y "Linus Tech Tips · … ago".
3. Click en la fila: se abre `mpv`, la fila desaparece, el panel se cierra, el icono vuelve a `󰗃` atenuado.
4. `bin/fresh-tube add @veritasium` desde una terminal, click medio en el icono: el contador sube sin abrir el panel. Abrir, pasar el mouse por la fila, click en `✕`: la fila desaparece sin abrir mpv.
5. Pin: click en `󰐃`; click en una ventana de atrás: el panel sigue; abrir el panel de audio de la barra: Fresh Tube sigue abierto; `Esc` con el foco en el panel lo cierra. `omarchy restart shell` y abrir: aparece pinneado.
6. Resize: arrastrar el `◢` de la esquina inferior derecha; la tarjeta crece hacia la derecha y abajo; cerrar y abrir conserva el tamaño; `cat ~/.local/state/fresh-tube/state.json | grep -A3 prefs` muestra los valores nuevos.
7. Teclado con el panel abierto: `↓`/`↑` mueven el resaltado, `Enter` reproduce, `Delete` descarta, `Ctrl+R` refresca, `Esc` cierra.
8. `omarchy-shell io.github.ferc10110.fresh-tube toggle` abre y cierra el panel desde la terminal.

Si algo falla, leer el log y corregir antes de seguir; no avanzar con un error QML pendiente.

- [ ] **Step 7: Commit**

```bash
git add FreshTubeCommand.qml Panel.qml VideoRow.qml VideosView.qml BarWidget.qml
git commit -F - <<'EOF'
Show the new videos from the bar and play them in mpv

The icon carries the count and polls every refreshMinutes; the panel
lists the unseen videos, pins, resizes and remembers both.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_011DPqvBbwQCc2wPWRZoVQkC
EOF
```

---

### Task 12: Vista de canales: agregar y quitar desde el panel

**Files:**
- Create: `ChannelsView.qml`
- Modify: `Panel.qml` (propiedades, funciones, tres runners, `currentFocus`, montar la vista)
- Modify: `VideosView.qml` (botón de canales en la cabecera, estado vacío sin canales)

**Interfaces:**
- Consumes: CLI `add`, `remove`, `channels --json`; `Model.looksLikeChannelInput`.
- Produces: `ChannelsView { host; error (string); focusItem; clearInput() }`. En `Panel`: `channels` (array), `adding` (bool), `addChannel(text)`, `removeChannel(id)`, `showChannels()`, `showVideos()`, `loadChannels()`; `currentFocus` cambia según `view`.

- [ ] **Step 1: ChannelsView.qml**

```qml
import QtQuick
import qs.Commons
import qs.Ui

// Add and remove channels. Adding asks the panel, which runs the script; this
// view only shows the list and the error under the field.
Item {
  id: view

  property var host: null
  property string error: ""

  readonly property Item focusItem: input
  readonly property color fg: host ? host.foreground : Color.foreground
  readonly property color dim: host ? host.dim : Qt.darker(Color.foreground, 1.55)
  readonly property color urgent: host ? host.urgent : Color.urgent
  readonly property string family: host ? host.fontFamily : Style.font.family
  readonly property var rows: host ? host.channels : []
  readonly property bool adding: host ? host.adding : false
  readonly property real gap: Style.space(8)

  function clearInput() {
    input.text = ""
    error = ""
  }

  function submit() {
    if (adding) return
    host.addChannel(input.text)
  }

  function handleKey(event) {
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      submit()
    } else if (event.key === Qt.Key_Escape) {
      host.showVideos()
    } else {
      return
    }
    event.accepted = true
  }

  Column {
    id: upper
    width: parent.width
    spacing: view.gap

    Item {
      width: parent.width
      height: Math.max(back.implicitHeight, heading.implicitHeight)

      Button {
        id: back
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        iconText: "󰁍"
        text: "Back"
        tooltipText: "Back to the videos (Esc)"
        foreground: view.fg
        fontFamily: view.family
        onClicked: view.host.showVideos()
      }

      Text {
        id: heading
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: "Channels"
        textFormat: Text.PlainText
        color: view.fg
        font.family: view.family
        font.pixelSize: Style.font.title
        font.bold: true
      }
    }

    Row {
      width: parent.width
      spacing: Style.space(6)

      TextField {
        id: input
        width: parent.width - addButton.implicitWidth - parent.spacing
        enabled: !view.adding
        placeholderText: view.adding ? "Looking up channel…" : "Paste a channel URL or @handle"
        foreground: view.fg
        font.family: view.family
        Keys.onPressed: function(event) { view.handleKey(event) }
      }

      Button {
        id: addButton
        anchors.verticalCenter: parent.verticalCenter
        text: "Add"
        bordered: true
        enabled: !view.adding && input.text.trim() !== ""
        opacity: enabled ? 1 : 0.55
        foreground: view.fg
        fontFamily: view.family
        onClicked: view.submit()
      }
    }

    Text {
      width: parent.width
      visible: text !== ""
      text: view.error
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: view.urgent
      font.family: view.family
      font.pixelSize: Style.font.bodySmall
    }
  }

  ListView {
    id: list
    anchors.top: upper.bottom
    anchors.topMargin: view.gap
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(4)
    width: parent.width
    visible: view.rows.length > 0
    clip: true
    spacing: Style.space(2)
    boundsBehavior: Flickable.StopAtBounds
    model: view.rows

    delegate: Rectangle {
      id: channelRow
      required property var modelData
      width: list.width
      implicitHeight: Math.max(labels.implicitHeight, remove.implicitHeight) + Style.space(8)
      radius: Style.cornerRadius
      color: rowHover.hovered ? Style.hoverFillFor(view.fg, Color.accent) : "transparent"

      HoverHandler { id: rowHover }

      Column {
        id: labels
        anchors.left: parent.left
        anchors.leftMargin: Style.space(8)
        anchors.right: remove.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          width: parent.width
          text: channelRow.modelData.name || channelRow.modelData.id
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: view.fg
          font.family: view.family
          font.pixelSize: Style.font.body
        }

        Text {
          width: parent.width
          visible: text !== ""
          text: channelRow.modelData.lastError || ""
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: view.dim
          font.family: view.family
          font.pixelSize: Style.font.caption
        }
      }

      Button {
        id: remove
        anchors.right: parent.right
        anchors.rightMargin: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        iconText: "󰅖"
        tooltipText: "Remove channel"
        foreground: view.fg
        fontFamily: view.family
        onClicked: view.host.removeChannel(channelRow.modelData.id)
      }
    }
  }

  Text {
    anchors.top: upper.bottom
    anchors.topMargin: view.gap
    width: parent.width
    visible: view.rows.length === 0
    text: "No channels yet. Paste a channel URL above."
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: view.dim
    font.family: view.family
    font.pixelSize: Style.font.bodySmall
  }
}
```

- [ ] **Step 2: Editar Panel.qml**

(a) Después de `property var prefsQueue: []` agregar:

```qml
  property var channels: []
```

(b) Después de `readonly property bool refreshing: refreshCmd.running` agregar:

```qml
  readonly property bool adding: addCmd.running
```

(c) Reemplazar

```qml
  readonly property Item currentFocus: videosView.focusItem
```
por
```qml
  readonly property Item currentFocus: view === "channels" ? channelsView.focusItem : videosView.focusItem
```

(d) Después de la función `togglePin()` agregar:

```qml
  function loadChannels() {
    channelsCmd.start(["channels", "--json"])
  }

  function showChannels() {
    channelsView.error = ""
    view = "channels"
    loadChannels()
  }

  function showVideos() {
    view = "videos"
  }

  function addChannel(text) {
    var value = String(text || "").trim()
    if (value === "" || addCmd.running) return
    if (!Model.looksLikeChannelInput(value)) {
      channelsView.error = "That doesn't look like a YouTube channel"
      return
    }
    channelsView.error = ""
    addCmd.start(["add", "--", value])
  }

  function removeChannel(channelId) {
    if (!channelId || removeCmd.running) return
    removeCmd.start(["remove", "--", channelId])
  }
```

(e) Después del runner `playerCheckCmd` agregar:

```qml
  FreshTubeCommand {
    id: channelsCmd
    program: root.program
    onFinished: function(code, out, err) {
      var data = root.parseJson(out)
      if (code !== 0 || !data) {
        channelsView.error = root.lastLine(err) || "Could not read the channels"
        return
      }
      root.channels = Array.isArray(data.channels) ? data.channels : []
    }
  }

  // Resolving a channel can chain a page fetch, a yt-dlp fallback and the
  // feed, so this one gets a longer leash.
  FreshTubeCommand {
    id: addCmd
    program: root.program
    timeoutMs: 60000
    onFinished: function(code, out, err) {
      if (code !== 0) {
        channelsView.error = root.lastLine(err) || "Could not add that channel"
        return
      }
      channelsView.clearInput()
      root.loadChannels()
      root.loadCached()
      root.refresh()
    }
  }

  FreshTubeCommand {
    id: removeCmd
    program: root.program
    onFinished: function(code, out, err) {
      if (code !== 0) channelsView.error = root.lastLine(err) || "Could not remove that channel"
      root.loadChannels()
      root.loadCached()
    }
  }
```

(f) Dentro de `FeedPopup { ... }`, después del bloque `VideosView { ... }` agregar:

```qml
    ChannelsView {
      id: channelsView
      anchors.fill: parent
      visible: root.view === "channels"
      host: root
    }
```

- [ ] **Step 3: Editar VideosView.qml**

(a) En el `Row { id: actions ... }`, después del botón de pin agregar:

```qml
        Button {
          iconText: "󰕲"
          tooltipText: "Channels"
          foreground: view.fg
          fontFamily: view.family
          onClicked: view.host.showChannels()
        }
```

(b) Reemplazar el bloque `Column { id: empty ... }` completo por:

```qml
  Column {
    id: empty
    anchors.centerIn: parent
    width: parent.width
    visible: view.rows.length === 0
    spacing: Style.space(6)

    readonly property bool noChannels: view.host && view.host.channelCount === 0

    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      text: empty.noChannels ? "Paste a channel URL to start" : "Nothing new"
      textFormat: Text.PlainText
      color: view.fg
      font.family: view.family
      font.pixelSize: Style.font.subtitle
    }

    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      visible: !empty.noChannels && text !== ""
      text: view.host && view.host.fetchedAt !== "" ? "updated " + Model.formatClock(view.host.fetchedAt) : ""
      textFormat: Text.PlainText
      color: view.dim
      font.family: view.family
      font.pixelSize: Style.font.caption
    }

    Button {
      anchors.horizontalCenter: parent.horizontalCenter
      visible: empty.noChannels
      text: "Add channel"
      iconText: "󰐕"
      bordered: true
      foreground: view.fg
      fontFamily: view.family
      onClicked: view.host.showChannels()
    }
  }
```

- [ ] **Step 4: Verificar en la barra real**

Run: `sleep 2; quickshell log -p /usr/share/omarchy/shell -t 60 | grep -i -E 'error|warn|fresh' | tail -15`
Expected: sin errores QML. Luego:

1. Abrir el panel, click en `󰕲`: la vista de canales con los dos canales agregados en la Tarea 11 y el campo con foco.
2. Pegar `https://www.youtube.com/@Fireship` y `Enter`: el campo muestra "Looking up channel…", después vuelve vacío y el canal aparece en la lista; `Esc` vuelve a los videos y ahí está el último de Fireship.
3. Pegar `https://vimeo.com/x` y Add: error inline "That doesn't look like a YouTube channel". Pegar `@estecanalnoexiste0x0x0` y Add: "Couldn't find that channel". Volver a pegar `@Fireship`: "Already added".
4. Click en `󰅖` de un canal: desaparece y su video deja de estar en la lista de videos.
5. Quitar todos los canales: la vista de videos dice "Paste a channel URL to start" con el botón "Add channel", que lleva a la vista de canales.

- [ ] **Step 5: Commit**

```bash
git add ChannelsView.qml Panel.qml VideosView.qml
git commit -F - <<'EOF'
Add and remove channels from the panel

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_011DPqvBbwQCc2wPWRZoVQkC
EOF
```

---

### Task 13: README, LICENSE, checklist final y versión

**Files:**
- Create: `README.md`
- Create: `LICENSE`
- Modify: `manifest.json` (version `1.0.0`)

- [ ] **Step 1: LICENSE**

```
MIT License

Copyright (c) 2026 Fernando Cancro

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 2: README.md**

````markdown
# Fresh Tube

The latest unseen video of the YouTube channels you pick, one click from the
Omarchy bar, played in mpv.

You follow dozens of channels but only a handful matter every day, and finding
them on youtube.com means scrolling past everything else. Fresh Tube keeps
your own short list: the bar shows how many of those channels posted something
you have not watched, the panel lists one video per channel, a click plays it
in `mpv`, and what you watched disappears.

## Install

```sh
omarchy plugin add https://github.com/FerC10110/omarchy-fresh-tube.git --enable
```

The bar gains a 󰗃 button on the left. It needs `mpv` (with `yt-dlp`, which
mpv uses for YouTube) and, only as a fallback when a channel page gives
nothing away, `yt-dlp` on `PATH`. Both ship with Omarchy.

## Use

- Click the icon to open the panel; the number next to it is how many new
  videos there are.
- Click 󰕲 and paste a channel: `https://www.youtube.com/@handle`, a
  `/channel/UC…` link, a bare `@handle`, or even a video link (its channel is
  added). Remove a channel with ✕.
- Click a video to play it in mpv. Hover a row and click ✕ to mark it seen
  without playing.
- 󰐃 in the header pins the panel: it stays open while you click elsewhere or
  open other bar panels. Drag the ◢ corner to resize. Both are remembered.
- 󰐃 on a row pins that video (up to three): it moves to the top and stays
  listed after you play it, for the album you play all week or the long talk
  you watch over several days. Unpin it when you are done.
- Middle-click the icon to refresh without opening.
- Keyboard: ↑/↓ select, Enter plays, Delete dismisses, P pins, Ctrl+R
  refreshes, Esc closes.

Feeds refresh every 15 minutes, when the panel opens, and on demand.

## Settings

Inline on the widget entry in `~/.config/omarchy/shell.json`:

| Key | Default | What it does |
|---|---|---|
| `playerCommand` | `mpv` | Command that gets the video URL as its last argument. |
| `refreshMinutes` | `15` | Minutes between automatic refreshes. |

```sh
omarchy bar set io.github.ferc10110.fresh-tube playerCommand "mpv --profile=yt"
```

## Keybinding

```lua
o.bind("SUPER SHIFT", "Y", "omarchy-shell io.github.ferc10110.fresh-tube toggle")
```

## Files

- `~/.config/fresh-tube/channels.json`: your channels.
- `~/.local/state/fresh-tube/state.json`: seen videos, cached feeds, pinned
  videos, popup size and pin.

Everything comes from each channel's public RSS feed
(`youtube.com/feeds/videos.xml?channel_id=…`): no API key, no login, and no
sync with your YouTube account.

## Development

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
node --test tests/model.test.js
```

The Python tests use a temporary home and never touch the network. Saving any
file in the plugin folder reloads it in the running shell; errors show in
`quickshell log -p /usr/share/omarchy/shell -t 40`.

The `bin/fresh-tube` script is usable on its own: `add`, `remove`, `channels`,
`refresh [--cached]`, `seen`, `pin`, `unpin`, `prefs get|set`; add `--json` for
machine output.
````

- [ ] **Step 3: Versión 1.0.0**

En `manifest.json` cambiar `"version": "0.1.0"` por `"version": "1.0.0"`.

- [ ] **Step 4: Checklist final completo**

Run:
```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v 2>&1 | tail -3
node --test tests/model.test.js 2>&1 | tail -4
omarchy plugin validate . ; echo "validate exit=$?"
git status --short
find . -name '__pycache__' -not -path './.git/*'
```
Expected: `OK` en unittest, `# fail 0` en Node, `validate exit=0`, sin `__pycache__` en el repo.

Recorrer la lista manual del spec (sección "Pruebas", checklist QML) de punta a punta con la shell real:

1. Icono a la izquierda tras `omarchy plugin enable`.
2. Sin canales, el panel invita a agregar; pegar un `@handle` agrega y vuelve a la lista con su último video.
3. Click en un video abre mpv, la fila desaparece, el panel se cierra.
4. `✕` descarta sin abrir mpv.
5. Pin: click afuera no cierra; abrir el panel de audio no lo cierra; `Esc` sí. `omarchy restart shell` y reabrir: sigue pinneado.
6. Resize desde la esquina: crece a la derecha y abajo; cerrar/abrir y `omarchy restart shell` conservan el tamaño.
7. `nmcli networking off`, click medio en el icono, abrir: aviso "Offline, showing videos from hh:mm" y lista intacta. `nmcli networking on`.
8. Teclado: `↑`/`↓`/`Enter`/`Delete`/`Ctrl+R`/`Esc`.
9. El contador baja al descartar y sube tras `omarchy-shell io.github.ferc10110.fresh-tube refresh` cuando hay algo nuevo.

Anotar en el commit cualquier punto que no se pudo verificar y por qué.

- [ ] **Step 5: Commit**

```bash
git add README.md LICENSE manifest.json
git commit -F - <<'EOF'
Document Fresh Tube and release 1.0.0

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_011DPqvBbwQCc2wPWRZoVQkC
EOF
```

---

### Task 14: Videos pineados (backend): `pins` en state.json, `pin`/`unpin`, `pinned` en refresh

Agregado tras la aprobación del usuario del 2026-09-16 (sección "Videos pineados" del spec).

**Files:**
- Modify: `lib/fresh_tube/errors.py` (agregar `PIN_LIMIT = 6`)
- Modify: `lib/fresh_tube/store.py` (pins; `unseen_videos` y `prune_seen` los respetan)
- Modify: `lib/fresh_tube/cli.py` (`pin`, `unpin`, `"pinned"` en el payload de `refresh`)
- Modify: `tests/test_store.py` (ajustar `test_missing_state_has_defaults`; agregar al final de `State`)
- Modify: `tests/test_cli.py` (agregar al final)

**Interfaces:**
- Consumes: `store.*` y `cli.*` de las Tareas 2 a 8.
- Produces: `errors.PIN_LIMIT = 6`; `store.MAX_PINS = 3`; `store.video_record(channel, latest) -> dict` (la forma pública `{videoId,title,channelId,channel,published,thumbnail,url}`); `store.pinned_ids(state) -> set`; `store.pinned_videos(state) -> list[dict]` (copias, en orden de pineo); `store.find_latest(state, channels, video_id) -> dict|None`; `store.pin_video(state, video) -> list` (no-op si ya estaba; lanza `PIN_LIMIT` "Pin limit reached (3)"); `store.unpin_video(state, video_id) -> list` (lanza `UNKNOWN` "That video is not pinned"); `state["pins"]` en `empty_state()`/`load_state()` (entradas sin `videoId` descartadas, máximo 3); `unseen_videos` excluye pineados; `prune_seen` conserva pineados. CLI: `pin <video_id>` y `unpin <video_id>` imprimen `{"pinned": [...]}`; `pin` de un id que no es `latest` de ningún canal ni está pineado → exit 5 "No such video"; `refresh --json` agrega `"pinned": store.pinned_videos(state)`.

- [ ] **Step 1: Tests de store (fallan)**

En `tests/test_store.py`, sumar `PIN_LIMIT` al import de `fresh_tube.errors`, cambiar el esperado de `test_missing_state_has_defaults` para que incluya `"pins": []`:

```python
    def test_missing_state_has_defaults(self):
        self.assertEqual(store.load_state(), {"version": 1, "seen": [], "feeds": {}, "fetchedAt": "",
                                              "prefs": {"width": 420, "height": 520, "pinned": False},
                                              "pins": []})
```

y agregar al final de la clase `State`:

```python
    @staticmethod
    def pin(video_id, channel_id="UC1"):
        return {"videoId": video_id, "title": "T " + video_id, "channelId": channel_id, "channel": "One",
                "published": "2026-09-15T10:00:00+00:00", "thumbnail": "", "url": store.WATCH_URL.format(video_id)}

    def test_pins_are_capped_at_three_and_survive_reload(self):
        state = store.load_state()
        for n in range(3):
            store.pin_video(state, self.pin(f"p{n}"))
        with self.assertRaises(FreshTubeError) as caught:
            store.pin_video(state, self.pin("p3"))
        self.assertEqual(caught.exception.code, PIN_LIMIT)
        self.assertEqual(str(caught.exception), "Pin limit reached (3)")
        store.pin_video(state, self.pin("p1"))  # already pinned: no-op, no error
        store.save_state(state)
        self.assertEqual([p["videoId"] for p in store.load_state()["pins"]], ["p0", "p1", "p2"])

    def test_unpin(self):
        state = store.load_state()
        store.pin_video(state, self.pin("p0"))
        self.assertEqual(store.unpin_video(state, "p0"), [])
        with self.assertRaises(FreshTubeError) as caught:
            store.unpin_video(state, "p0")
        self.assertEqual(caught.exception.code, UNKNOWN)
        self.assertEqual(str(caught.exception), "That video is not pinned")

    def test_invalid_saved_pins_are_dropped_on_load(self):
        self.box.write_json(self.box.state_file, {"pins": [self.pin("ok"), {"title": "no id"}, "junk",
                                                           {"videoId": ""}, self.pin("a"), self.pin("b"),
                                                           self.pin("c")]})
        self.assertEqual([p["videoId"] for p in store.load_state()["pins"]], ["ok", "a", "b"])

    def test_pinned_videos_are_not_new_and_not_pruned(self):
        channels = [{"id": "UC1", "name": "One"}]
        state = store.load_state()
        store.update_feed(state, "UC1", {"name": "One", "latest": {"videoId": "v1", "title": "First",
                                          "published": "2026-09-15T10:00:00+00:00", "thumbnail": "th"},
                                          "recent": ["v1"]}, "t1")
        video = store.find_latest(state, channels, "v1")
        self.assertEqual(video, {"videoId": "v1", "title": "First", "channelId": "UC1", "channel": "One",
                                 "published": "2026-09-15T10:00:00+00:00", "thumbnail": "th",
                                 "url": "https://www.youtube.com/watch?v=v1"})
        self.assertIsNone(store.find_latest(state, channels, "nope"))
        store.pin_video(state, video)
        self.assertEqual(store.unseen_videos(state, channels), [])
        self.assertEqual(store.pinned_videos(state), [video])
        store.mark_seen(state, "v1")
        store.update_feed(state, "UC1", {"name": "One", "latest": {"videoId": "v2", "title": "Second",
                                          "published": "2026-09-16T10:00:00+00:00", "thumbnail": ""},
                                          "recent": ["v2"]}, "t2")
        store.prune_seen(state)
        self.assertEqual(state["seen"], ["v1"])
        store.unpin_video(state, "v1")
        store.prune_seen(state)
        self.assertEqual(state["seen"], [])
        self.assertEqual([v["videoId"] for v in store.unseen_videos(state, channels)], ["v2"])
```

- [ ] **Step 2: Correr y ver que fallan**

Run: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -k store -v`
Expected: `ImportError: cannot import name 'PIN_LIMIT'`.

- [ ] **Step 3: Implementar errors.py y store.py**

`lib/fresh_tube/errors.py`: agregar después de `UNKNOWN = 5`:

```python
PIN_LIMIT = 6
```

`lib/fresh_tube/store.py`: sumar `PIN_LIMIT` al import de `.errors`; agregar después de `PREF_LIMITS`:

```python
MAX_PINS = 3
```

reemplazar `empty_state`:

```python
def empty_state():
    return {"version": STATE_VERSION, "seen": [], "feeds": {}, "fetchedAt": "",
            "prefs": dict(DEFAULT_PREFS), "pins": []}
```

agregar después de `_valid_pref`:

```python
def _valid_pin(entry):
    """A saved pin is usable when it is an object with a non-empty videoId."""
    return isinstance(entry, dict) and isinstance(entry.get("videoId"), str) and entry["videoId"] != ""
```

en `load_state`, después del bloque de `prefs` y antes del `return state`:

```python
    if isinstance(data.get("pins"), list):
        state["pins"] = [dict(p) for p in data["pins"] if _valid_pin(p)][:MAX_PINS]
```

reemplazar `prune_seen`:

```python
def prune_seen(state):
    """Forget seen ids that no cached feed lists any more, unless they are pinned."""
    keep = set()
    for feed in state["feeds"].values():
        keep.update(feed.get("recent") or [])
    keep.update(pinned_ids(state))
    state["seen"] = [s for s in state["seen"] if s in keep]
```

y reemplazar `unseen_videos` por este bloque (que además agrega las funciones nuevas):

```python
def video_record(channel, latest):
    """The public shape of a video, shared by the new-video list and the pins."""
    return {"videoId": latest["videoId"], "title": latest.get("title", ""),
            "channelId": channel["id"], "channel": channel.get("name", ""),
            "published": latest.get("published", ""), "thumbnail": latest.get("thumbnail", ""),
            "url": WATCH_URL.format(latest["videoId"])}


def unseen_videos(state, channels):
    """The newest video of every channel whose newest video was not seen or pinned, newest first."""
    skip = set(state["seen"]) | pinned_ids(state)
    videos = []
    for channel in channels:
        feed = state["feeds"].get(channel["id"]) or {}
        latest = feed.get("latest")
        if not latest or latest.get("videoId") in skip:
            continue
        videos.append(video_record(channel, latest))
    videos.sort(key=lambda v: v["published"], reverse=True)
    return videos


def find_latest(state, channels, video_id):
    """The full record of a video that is currently some channel's newest, or None."""
    for channel in channels:
        latest = (state["feeds"].get(channel["id"]) or {}).get("latest")
        if latest and latest.get("videoId") == video_id:
            return video_record(channel, latest)
    return None


def pinned_ids(state):
    return {p["videoId"] for p in state.get("pins", [])}


def pinned_videos(state):
    return [dict(p) for p in state.get("pins", [])]


def pin_video(state, video):
    """Keep a video around regardless of seen/newest; at most MAX_PINS, re-pinning is a no-op."""
    pins = state.setdefault("pins", [])
    if any(p["videoId"] == video["videoId"] for p in pins):
        return pins
    if len(pins) >= MAX_PINS:
        raise FreshTubeError(f"Pin limit reached ({MAX_PINS})", PIN_LIMIT)
    pins.append(dict(video))
    return pins


def unpin_video(state, video_id):
    pins = state.setdefault("pins", [])
    kept = [p for p in pins if p["videoId"] != video_id]
    if len(kept) == len(pins):
        raise FreshTubeError("That video is not pinned", UNKNOWN)
    state["pins"] = kept
    return kept
```

- [ ] **Step 4: Correr los tests de store**

Run: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -k store -v`
Expected: PASS (los 4 nuevos y los anteriores).

- [ ] **Step 5: Tests del CLI (fallan)**

Al final de `tests/test_cli.py`:

```python
class Pins(CliTest):
    def setUp(self):
        super().setUp()
        self.box.apply()
        self.box.write_json(self.box.channels_file, {"version": 1, "channels": [
            {"id": "UC1", "name": "One", "url": "u1", "addedAt": "t"},
            {"id": "UC2", "name": "Two", "url": "u2", "addedAt": "t"}]})

    def refresh(self, *extra, fetch=None):
        with mock.patch("fresh_tube.feed.fetch_feed", side_effect=fetch or Refresh.two_feeds), \
             support.captured() as (out, err):
            code = cli.main(["refresh", "--json", *extra])
        self.assertEqual(code, 0, err.getvalue())
        return json.loads(out.getvalue())

    def call(self, *argv):
        with support.captured() as (out, err):
            code = cli.main(list(argv))
        return code, out.getvalue(), err.getvalue()

    def pin(self, video_id):
        code, out, err = self.call("pin", video_id)
        self.assertEqual(code, 0, err)
        return [p["videoId"] for p in json.loads(out)["pinned"]]

    def test_pin_moves_a_video_from_new_to_pinned_even_after_watching(self):
        self.refresh()
        self.assertEqual(self.pin("v2"), ["v2"])
        payload = self.refresh("--cached")
        self.assertEqual([v["videoId"] for v in payload["videos"]], ["v1"])
        self.assertEqual([p["videoId"] for p in payload["pinned"]], ["v2"])
        self.assertEqual(payload["pinned"][0]["channel"], "Two")
        self.assertEqual(payload["pinned"][0]["url"], "https://www.youtube.com/watch?v=v2")
        self.assertEqual(self.call("seen", "v2")[0], 0)
        self.assertEqual([p["videoId"] for p in self.refresh("--cached")["pinned"]], ["v2"])
        self.assertEqual(self.pin("v2"), ["v2"])  # re-pin is a no-op

    def test_pinned_video_survives_the_channel_moving_on_and_being_removed(self):
        self.refresh()
        self.pin("v2")

        def moved_on(channel_id, timeout=10):
            if channel_id == "UC2":
                return {"name": "Two", "latest": {"videoId": "v3", "title": "Third", "thumbnail": "",
                                                  "published": "2026-09-17T10:00:00+00:00"}, "recent": ["v3", "v2"]}
            return Refresh.two_feeds(channel_id, timeout)

        payload = self.refresh(fetch=moved_on)
        self.assertEqual([v["videoId"] for v in payload["videos"]], ["v3", "v1"])
        self.assertEqual([p["videoId"] for p in payload["pinned"]], ["v2"])
        self.assertEqual(self.pin("v2"), ["v2"])  # still pinnable although no longer the newest
        self.assertEqual(self.call("remove", "UC2")[0], 0)
        payload = self.refresh("--cached")
        self.assertEqual([v["videoId"] for v in payload["videos"]], ["v1"])
        self.assertEqual([p["videoId"] for p in payload["pinned"]], ["v2"])

    def test_unpin_applies_the_normal_rules(self):
        self.refresh()
        self.pin("v2")
        self.call("seen", "v2")
        code, out, err = self.call("unpin", "v2")
        self.assertEqual(code, 0, err)
        self.assertEqual(json.loads(out)["pinned"], [])
        self.assertEqual([v["videoId"] for v in self.refresh("--cached")["videos"]], ["v1"])
        self.pin("v1")
        self.assertEqual(self.call("unpin", "v1")[0], 0)
        self.assertEqual([v["videoId"] for v in self.refresh("--cached")["videos"]], ["v1"])

    def test_pin_errors(self):
        self.refresh()
        code, out, err = self.call("pin", "nope")
        self.assertEqual(code, 5)
        self.assertIn("No such video", err)
        code, out, err = self.call("unpin", "v1")
        self.assertEqual(code, 5)
        self.assertIn("That video is not pinned", err)
        state = store.load_state()
        for n in range(3):
            store.pin_video(state, {"videoId": f"p{n}", "title": "", "channelId": "UCx", "channel": "",
                                    "published": "", "thumbnail": "", "url": ""})
        store.save_state(state)
        code, out, err = self.call("pin", "v1")
        self.assertEqual(code, 6)
        self.assertIn("Pin limit reached (3)", err)
        self.assertEqual(len(store.load_state()["pins"]), 3)
```

- [ ] **Step 6: Correr y ver que fallan**

Run: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -k Pins -v`
Expected: `SystemExit: 2` (argparse no conoce `pin`) y `KeyError: 'pinned'`.

- [ ] **Step 7: Implementar en cli.py**

Sumar `UNKNOWN` al import de `.errors` si no está. En `refresh_all`, el `return` pasa a:

```python
    return {"videos": store.unseen_videos(state, channels), "pinned": store.pinned_videos(state),
            "fetchedAt": state["fetchedAt"], "offline": offline, "channelCount": len(channels),
            "errors": errors}
```

Agregar después de `cmd_seen`:

```python
def cmd_pin(args):
    channels = store.load_channels()
    state = store.load_state()
    video = store.find_latest(state, channels, args.video_id)
    if video is None:
        # Re-pinning something already pinned must work even after its channel moved on.
        already = [p for p in state["pins"] if p["videoId"] == args.video_id]
        if not already:
            raise FreshTubeError("No such video", UNKNOWN)
        video = already[0]
    store.pin_video(state, video)
    store.save_state(state)
    emit({"pinned": store.pinned_videos(state)})
    return 0


def cmd_unpin(args):
    state = store.load_state()
    store.unpin_video(state, args.video_id)
    store.save_state(state)
    emit({"pinned": store.pinned_videos(state)})
    return 0
```

Y en `build_parser`, después del subparser `seen`:

```python
    p = sub.add_parser("pin", help="keep a video listed even after watching it (at most 3)")
    p.add_argument("video_id")
    p.set_defaults(func=cmd_pin)

    p = sub.add_parser("unpin", help="stop keeping a video pinned")
    p.add_argument("video_id")
    p.set_defaults(func=cmd_unpin)
```

- [ ] **Step 8: Suite completa, validate y commit**

Run:
```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v 2>&1 | tail -3
omarchy plugin validate . ; echo "validate exit=$?"
```
Expected: `OK` con 8 tests más que antes; `validate exit=0`.

```bash
git add lib/fresh_tube/errors.py lib/fresh_tube/store.py lib/fresh_tube/cli.py tests/test_store.py tests/test_cli.py
git commit -F - <<'MSG'
Pin up to three videos so watching them does not hide them

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_011DPqvBbwQCc2wPWRZoVQkC
MSG
```

---

### Task 15: Videos pineados (UI): botón de pin por fila, pineados arriba, tecla P

Agregado tras la aprobación del usuario del 2026-09-16. Se ejecuta después de la Tarea 14 y antes de la 13.

**Files:**
- Modify: `Panel.qml` (`pinnedVideos`, `isPinned`, `pin`, `unpin`, `togglePinVideo`, runner `pinCmd`, `applyPayload`)
- Modify: `VideosView.qml` (filas = pineados + nuevos, tecla `P`, `Delete` no descarta pineados, delegate)
- Modify: `VideoRow.qml` (botón de pin, `✕` oculto en pineados)

**Interfaces:**
- Consumes: CLI `pin`/`unpin` y `pinned` en el payload (Tarea 14); `Panel`, `VideosView`, `VideoRow` de las Tareas 11 y 12.
- Produces: en `Panel`: `pinnedVideos` (array), `maxPins` (3), `pinsFull` (bool), `isPinned(video) -> bool`, `pin(video)`, `unpin(video)`, `togglePinVideo(video)`; `VideoRow { pinned; pinsFull; signal pinToggled() }`; en `VideosView`: `pinnedCount`. `BarWidget` no cambia: `count` sigue siendo `videos.length`, que ya excluye los pineados.

No hay test automático de QML: se verifica con el log de la shell, el CLI y el archivo de estado; lo visual queda para el checklist manual (punto 10 del spec).

- [ ] **Step 1: Panel.qml**

Después de `property var channels: []` agregar:

```qml
  property var pinnedVideos: []

  readonly property int maxPins: 3
  readonly property bool pinsFull: pinnedVideos.length >= maxPins
```

En `applyPayload`, después de la línea de `videos`:

```qml
    pinnedVideos = Array.isArray(data.pinned) ? data.pinned : []
```

Después de `function dismiss(video) { ... }` agregar:

```qml
  function isPinned(video) {
    if (!video) return false
    for (var i = 0; i < pinnedVideos.length; i++) {
      if (pinnedVideos[i].videoId === video.videoId) return true
    }
    return false
  }

  function pin(video) {
    if (!video || pinCmd.running) return
    if (pinsFull) {
      setNotice("Pin limit reached (" + maxPins + ")", true)
      return
    }
    pinCmd.start(["pin", "--", video.videoId])
  }

  function unpin(video) {
    if (!video || pinCmd.running) return
    pinCmd.start(["unpin", "--", video.videoId])
  }

  function togglePinVideo(video) {
    if (isPinned(video)) unpin(video)
    else pin(video)
  }
```

Después del runner `seenCmd` agregar:

```qml
  // Pinning moves a video between the two lists, so the cache is reread
  // instead of patching them by hand; other screens get told the same way.
  FreshTubeCommand {
    id: pinCmd
    program: root.program
    onFinished: function(code, out, err) {
      var data = root.parseJson(out)
      if (code !== 0 || !data) {
        root.setNotice(root.lastLine(err) || "Could not change the pin", true)
        return
      }
      if (root.noticeIsError) root.setNotice("", false)
      root.loadCached()
      if (root.hostWidget && typeof root.hostWidget.broadcast === "function") root.hostWidget.broadcast("reloadCached")
    }
  }
```

- [ ] **Step 2: VideoRow.qml**

Reemplazar el comentario de cabecera por:

```qml
// One video: thumbnail, title, channel and age. A click plays it. On hover
// (or on the keyboard-selected row) a pin keeps it listed after watching and,
// unless it is pinned, a ✕ marks it seen instead.
```

Después de `property real nowMs: Date.now()` agregar:

```qml
  property bool pinned: false
  property bool pinsFull: false
```

Después de `signal dismissed()` agregar:

```qml
  signal pinToggled()
```

Reemplazar la línea de `showDismiss` por:

```qml
  readonly property bool showPin: pinned || hover.containsMouse || selected
  readonly property bool showDismiss: !pinned && (hover.containsMouse || selected)
```

Reemplazar el `width` de `textColumn` por:

```qml
      width: content.width - thumb.width - content.spacing
        - (pinButton.visible ? pinButton.implicitWidth + content.spacing : 0)
        - (dismissButton.visible ? dismissButton.implicitWidth + content.spacing : 0)
```

Y antes del `Button { id: dismissButton ... }` agregar:

```qml
    Button {
      id: pinButton
      visible: row.showPin
      anchors.verticalCenter: parent.verticalCenter
      iconText: "󰐃"
      selected: row.pinned
      opacity: !row.pinned && row.pinsFull ? 0.4 : 1
      tooltipText: row.pinned ? "Unpin (P)"
        : (row.pinsFull ? "Pin limit reached (3)" : "Pin: keep it listed after watching (P)")
      foreground: row.fg
      fontFamily: row.family
      onClicked: row.pinToggled()
    }
```

- [ ] **Step 3: VideosView.qml**

Reemplazar el comentario de cabecera por:

```qml
// The pinned videos followed by the new ones, with the header actions.
// Choosing a video asks the panel to play it; nothing here runs the script.
```

Reemplazar la línea de `rows` por:

```qml
  readonly property int pinnedCount: host ? host.pinnedVideos.length : 0
  readonly property var rows: host ? host.pinnedVideos.concat(host.videos) : []
```

En `handleKey`, reemplazar la rama de `Qt.Key_Delete` por:

```qml
    } else if (event.key === Qt.Key_Delete) {
      if (rows[selected] && !host.isPinned(rows[selected])) host.dismiss(rows[selected])
    } else if (!ctrl && event.key === Qt.Key_P) {
      if (rows[selected]) host.togglePinVideo(rows[selected])
```

En el `delegate: VideoRow { ... }`, después de `nowMs: view.nowMs` agregar:

```qml
      pinned: index < view.pinnedCount
      pinsFull: view.host ? view.host.pinsFull : false
      onPinToggled: view.host.togglePinVideo(modelData)
```

- [ ] **Step 4: Verificar en la barra real**

Run:
```bash
sleep 2; quickshell log -p /usr/share/omarchy/shell -t 60 | grep -i -E 'error|warn|fresh' | grep -v qt.qpa.services | tail -10
bin/fresh-tube add @LinusTechTips
ID=$(bin/fresh-tube refresh --json --cached | python3 -c 'import json,sys; print(json.load(sys.stdin)["videos"][0]["videoId"])')
bin/fresh-tube pin "$ID"
bin/fresh-tube refresh --json --cached | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["videos"]), [p["videoId"] for p in d["pinned"]])'
bin/fresh-tube seen "$ID"
bin/fresh-tube refresh --json --cached | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["videos"]), [p["videoId"] for p in d["pinned"]])'
omarchy-shell io.github.ferc10110.fresh-tube open; sleep 1; omarchy-shell io.github.ferc10110.fresh-tube close
sleep 1; quickshell log -p /usr/share/omarchy/shell -t 30 | grep -i -E 'error|warn' | grep -v qt.qpa.services | tail -5
bin/fresh-tube unpin "$ID"
bin/fresh-tube remove "$(bin/fresh-tube channels --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["channels"][0]["id"])')"
```
Expected: sin errores QML; tras `pin`: `0 ['<id>']`; tras `seen`: sigue `0 ['<id>']`; el panel abre y cierra limpio con el video pineado cargado; al final `channels.json` vacío y `state.json` sin pins.

Después, en la barra (checklist del usuario, punto 10 del spec): el pin en una fila la manda arriba y queda marcado; reproducirla no la saca; el contador no la cuenta; con 3 pineados el pin de las otras filas se ve atenuado y al hacer click aparece "Pin limit reached (3)"; `P` pinea la fila resaltada; `Delete` no descarta una pineada; despinear una ya vista la hace desaparecer.

- [ ] **Step 5: Commit**

```bash
git add Panel.qml VideosView.qml VideoRow.qml
git commit -F - <<'MSG'
Pin videos from the panel and keep them on top

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_011DPqvBbwQCc2wPWRZoVQkC
MSG
```
