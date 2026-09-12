#!/bin/bash
#
# Reverses install.sh. Backups under ~/.local/state/omacord/backups/ are left
# where they are.
#
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -r $here/omarchy/lib.sh ]]; then
  . "$here/omarchy/lib.sh"
else
  . "${OMACORD_DATA:-$HOME/.local/share/omacord}/lib.sh"
fi

hook="$HOME/.config/omarchy/hooks/theme-set.d/omacord"
template="$HOME/.config/omarchy/themed/omacord.palette.css.tpl"
shipped="$here/assets/omarchy/omacord.palette.css.tpl"

note() { printf 'omacord: %s\n' "$1"; }

rm -f "$hook"

# Leave the template alone if it has been edited: someone may have tuned the
# palette mapping and that work is theirs, not ours to delete.
if [[ -f $template ]]; then
  if [[ -f $shipped ]] && ! cmp -s "$template" "$shipped"; then
    note "kept your modified template at $template"
  else
    rm -f "$template"
  fi
fi

# Take omacord back out of Vencord's enabled list. As with installing, this is
# pointless while Discord is running, since Vencord rewrites the file from
# memory when it exits.
disable_in() {
  local settings=$1 staged
  [[ -f $settings ]] || return 0

  if omacord_client_running; then
    note "Discord is running, so its theme list was left as it is."
    note "Turn omacord off under Settings > Themes if you want it gone from the list."
    return 0
  fi

  staged=$(mktemp)
  if jq --arg name "$OMACORD_THEME_FILE" \
    '.enabledThemes = ((.enabledThemes // []) - [$name])' "$settings" >"$staged" 2>/dev/null; then
    mv -f "$staged" "$settings"
  else
    rm -f "$staged"
  fi
}

while read -r themes; do
  [[ -d $themes ]] || continue
  rm -f "$themes/$OMACORD_THEME_FILE"
  note "removed from ${themes%/themes}"
  disable_in "$(omacord_settings_for "$themes")"
done < <(omacord_client_dirs)

rm -f "${OMACORD_DATA:?}/style.css" "${OMACORD_DATA:?}/lib.sh"
rmdir "$OMACORD_DATA" 2>/dev/null || true

note "removed. Backups, if any: ~/.local/state/omacord/backups/"
