#!/usr/bin/env bash

set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

omarchy plugin validate "$repo_dir"
jq -e '
  .schemaVersion == 1 and
  .id == "ryrobes.beatbar" and
  .version == "1.0.2" and
  .author == "Ryan Robitaille" and
  (.kinds | index("service")) != null and
  (.kinds | index("bar-widget")) != null and
  .entryPoints.service == "Service.qml" and
  .entryPoints.barWidget == "BarWidget.qml" and
  .barWidget.allowMultiple == false and
  .barWidget.defaultSection == "center" and
  .barWidget.defaults.bassMotion == "Subtle" and
  .barWidget.defaults.auroraPulse == true and
  any(.barWidget.schema[]; .key == "bassMotion") and
  any(.barWidget.schema[]; .key == "auroraPulse")
' manifest.json >/dev/null

grep -Fxq 'method = pipewire' cava.conf
grep -Fxq 'source = auto' cava.conf
grep -Fxq 'method = raw' cava.conf
grep -Fxq 'data_format = ascii' cava.conf
grep -Fxq 'bars = 24' cava.conf
grep -Fxq 'framerate = 30' cava.conf

rg -q 'serviceFor\(moduleName\)' BarWidget.qml
rg -q 'Color\.accent' BarWidget.qml
rg -q 'bar\.barForeground' BarWidget.qml
rg -q 'property real kickEnergy' BarWidget.qml
rg -q 'property: "shakePhase"' BarWidget.qml
rg -q 'property real pulsePosition' BarWidget.qml
rg -q 'property: "pulsePosition"' BarWidget.qml
rg -q 'context\.clip\(\)' BarWidget.qml
rg -q 'if \(!pulseTravel\.running\)' BarWidget.qml
rg -A4 'property: "beatGlow"' BarWidget.qml | rg -q 'duration: 180'
rg -A4 'property: "kickEnergy"' BarWidget.qml | rg -q 'duration: 200'
rg -q 'target: "ryrobes\.beatbar"' Service.qml
rg -q 'Pipewire\.defaultAudioSink' Service.qml
rg -q 'property int beatCount' Service.qml
rg -q 'shell\.summon\("omarchy\.osd"' Service.qml
rg -q 'property bool cavaNoticeShown' Service.qml
rg -q 'Beatbar paused: CAVA is unavailable\. See the plugin README\.' Service.qml
if rg -n 'notify-send|execDetached|omarchy-notification-send' Service.qml; then
  printf 'Dependency notice must not spawn a notification command.\n' >&2
  exit 1
fi

test -s README.md
test -s LICENSE
test -s SECURITY.md
test -s preview.png
rg -q 'omarchy plugin add https://github\.com/ryrobes/omarchy-beatbar\.git --enable' README.md
rg -q 'omarchy plugin remove ryrobes\.beatbar' README.md
rg -q 'command -v cava' README.md
test -z "$(find . -type l -print -quit)"
test ! -e install-local.sh
if rg -n '\bomarchy pkg (add|drop|remove|update)\b|\bsudo\b|\bpkexec\b' \
  README.md SECURITY.md Service.qml BarWidget.qml cava.conf; then
  printf 'Unexpected package-manager or privilege command in scanned plugin files.\n' >&2
  exit 1
fi

bash -n tests/test.sh

printf 'Beatbar structural tests passed.\n'
