#!/bin/bash
# Pre-flight: verifies this machine can run omacord, and that the repo
# itself satisfies the Omarchy plugin contract. Changes nothing.
set -uo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$project_dir/omarchy/lib.sh"
fails=0

ok()   { printf '  ok    %s\n' "$1"; }
warn() { printf '  warn  %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

echo "omacord check"

command -v omarchy >/dev/null && ok "omarchy on PATH" || bad "omarchy not on PATH"
command -v jq >/dev/null && ok "jq present" || bad "jq missing (required to enable the theme)"

if theme_dir=$(omacord_theme_dir); then
  ok "theme dir: $theme_dir"
  [[ -f $theme_dir/colors.toml ]] &&
    ok "active theme has colors.toml" ||
    warn "active theme has no colors.toml - palette cannot be generated"
else
  bad "no Omarchy theme directory found"
fi

mapfile -t dirs < <(omacord_client_dirs)
if (( ${#dirs[@]} )); then
  for d in "${dirs[@]}"; do ok "client: ${d%/themes}"; done
else
  warn "no Vencord-compatible client found (Vesktop / Vencord)"
fi

jq -e '.schemaVersion == 1' "$project_dir/manifest.json" >/dev/null 2>&1 &&
  ok "manifest schemaVersion is 1" || bad "manifest.json invalid"

if [[ -n $(find "$project_dir" -name .git -prune -o -type l -print -quit 2>/dev/null) ]]; then
  bad "symlink inside plugin folder - Omarchy rejects these"
else
  ok "no symlinks"
fi

if command -v omarchy >/dev/null; then
  omarchy plugin validate "$project_dir" >/dev/null 2>&1 &&
    ok "omarchy plugin validate" || bad "omarchy plugin validate failed"
fi

echo
(( fails == 0 )) && echo "All good." || echo "$fails problem(s)."
exit $(( fails > 0 ))
