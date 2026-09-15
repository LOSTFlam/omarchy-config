"""Catch missing QML types/imports without starting another shell."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
shell = next((p for p in [Path(os.environ.get("OMARCHY_PATH", "/usr/share/omarchy")) / "shell",
                        Path.home() / ".local/share/omarchy/shell"]
              if (p / "Ui/qmldir").is_file()), None)
lint = "/usr/lib/qt6/bin/qmllint"
if not Path(lint).is_file():
    lint = shutil.which("qmllint")
if not shell or not lint:
    raise SystemExit("qml-import-test: requires Omarchy shell sources and qmllint")

with tempfile.TemporaryDirectory(prefix="omaplug-qml-") as directory:
    imports = Path(directory)
    (imports / "qs").mkdir()
    for module in ("Commons", "Ui"):
        (imports / "qs" / module).symlink_to(shell / module, target_is_directory=True)
    files = [root / "Panel.qml", root / "BarWidget.qml", *sorted((root / "panel").rglob("*.qml"))]
    result = subprocess.run([lint, "-I", directory, "--json", "-", *map(str, files)],
                            capture_output=True, text=True, timeout=60)
    report = json.loads(result.stdout)
    failures = [f'{file["filename"]}:{issue.get("line", 0)}: {issue["message"]}'
                for file in report["files"] for issue in file["warnings"]
                if issue["type"] == "error" or issue.get("id") in
                ("import", "unresolved-type", "inheritance-cycle", "required", "syntax")]
    if failures:
        raise SystemExit("\n".join(failures))
print("qml-import-test: ok")
