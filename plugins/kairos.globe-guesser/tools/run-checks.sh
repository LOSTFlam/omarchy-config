#!/usr/bin/env bash
# Run every check the plugin has.
#
#   tools/run-checks.sh
#
# 1. Both bundled data files rebuild byte-for-byte from their pinned upstream
#    commit.
# 2. GeoMath.js and Sanitise.js behave under Node.
# 3. Both libraries, and the data, behave under Qt's V4 engine -- which is the
#    engine omarchy-shell actually uses, and is not Node.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

status=0
note() { printf '\n=== %s ===\n' "$1"; }

note "bundled data reproducibility"
if command -v python3 >/dev/null 2>&1; then
  if python3 tools/build-world.py --check; then
    echo "  data/ reproduces from the pinned upstream commit"
  else
    echo "  FAILED: data/ does not match a fresh build"
    status=1
  fi
else
  echo "  skipped: python3 not installed"
fi

note "GeoMath and Sanitise under Node"
if command -v node >/dev/null 2>&1; then
  node tools/check-geomath.js || status=1
else
  echo "  skipped: node not installed (development-only dependency)"
fi

note "Qt V4 engine"
# Qt's `qml` runner suppresses console output on some builds, so the check
# communicates through its exit code instead. Offscreen because there is nothing
# to display and CI has no compositor.
qml_bin=""
for candidate in /usr/lib/qt6/bin/qml "$(command -v qml6 2>/dev/null)" "$(command -v qml 2>/dev/null)"; do
  [ -n "$candidate" ] && [ -x "$candidate" ] && qml_bin="$candidate" && break
done

if [ -n "$qml_bin" ]; then
  QT_QPA_PLATFORM=offscreen "$qml_bin" tools/check-qml-engine.qml
  code=$?
  if [ "$code" -eq 0 ]; then
    echo "  all V4 checks passed"
  else
    echo "  FAILED at check $code (see tools/check-qml-engine.qml for what that number is)"
    status=1
  fi
else
  echo "  skipped: no qml runner found"
fi

note "result"
if [ "$status" -eq 0 ]; then
  echo "everything passed"
else
  echo "one or more checks failed"
fi
exit "$status"
