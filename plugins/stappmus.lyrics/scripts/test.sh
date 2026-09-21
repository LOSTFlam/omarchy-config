#!/usr/bin/env bash
set -euo pipefail

source_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$source_root"

for command_name in omarchy python3; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "test.sh: missing test command: $command_name" >&2
    exit 1
  }
done

qml_test_runner=/usr/lib/qt6/bin/qmltestrunner
[[ -x $qml_test_runner ]] || {
  echo "test.sh: Qt 6 qmltestrunner is missing: $qml_test_runner" >&2
  exit 1
}

qml_linter=/usr/lib/qt6/bin/qmllint
[[ -x $qml_linter ]] || {
  echo "test.sh: Qt 6 qmllint is missing: $qml_linter" >&2
  exit 1
}

omarchy plugin validate .
"$qml_linter" --silent -I /usr/share/omarchy/shell \
  FastScrollHandler.qml AutoScrollController.qml LyricsService.qml Panel.qml
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_*.py' -v
QT_QPA_PLATFORM=offscreen "$qml_test_runner" \
  -input tests \
  -import "$source_root" \
  -o -,txt

echo "All validation and tests passed."
