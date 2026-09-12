# Thin static-check harness for the plugin.
#
# `make lint`         — everything below. What a local Omarchy dev runs.
# `make lint-scripts` — bash syntax + manifest JSON. What CI can run.
# `make lint-qml`     — qmllint on the .qml. Needs the Quickshell import
#                       tree (and Qt.labs.folderlistmodel), so it only runs
#                       cleanly on an Omarchy install, not on stock Ubuntu.
# `make check`        — alias for lint.
# `make help`         — list targets.
#
# The split matters because Omarchy plugins import `Quickshell`, `qs.Commons`,
# and `Qt.labs.folderlistmodel`, none of which ship in Ubuntu's Qt6 packages;
# qmllint exits non-zero on unresolved imports, which would leave CI red
# for a reason that has nothing to do with the plugin's own correctness.

.PHONY: help lint lint-scripts lint-qml check

QMLLINT ?= qmllint
PYTHON  ?= python3

QML_SOURCES := Overlay.qml Service.qml

help:
	@printf 'Targets:\n'
	@printf '  make lint          — full local check (scripts + qml)\n'
	@printf '  make lint-scripts  — bash -n + manifest JSON (what CI runs)\n'
	@printf '  make lint-qml      — qmllint on .qml (requires Omarchy imports)\n'
	@printf '  make check         — alias for lint\n'

lint-scripts:
	@printf '==> bash -n om-custom-font\n'
	@bash -n om-custom-font
	@printf '==> python -m json.tool < manifest.json\n'
	@$(PYTHON) -m json.tool < manifest.json > /dev/null
	@printf 'lint-scripts: OK\n'

lint-qml:
	@printf '==> qmllint %s\n' "$(QML_SOURCES)"
	@$(QMLLINT) $(QML_SOURCES)
	@printf 'lint-qml: OK\n'

lint: lint-scripts lint-qml
	@printf 'lint: OK\n'

check: lint
