#!/bin/bash
#
# omacord installer.
#
# Safe to run repeatedly: it rewrites what it owns and leaves everything else
# alone. The shell plugin runs it at startup for exactly that reason.
#
# Environment:
#   OMACORD_LAYERS       comma-separated style layers, or "all" or "none".
#                        Unset means the default set.
#   OMACORD_THEMES_DIR   install into this themes directory only, skipping
#                        client discovery.
#
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/omarchy/lib.sh"

hooks="$HOME/.config/omarchy/hooks/theme-set.d"
templates="$HOME/.config/omarchy/themed"
backup_root="$HOME/.local/state/omacord/backups/$(date +%Y%m%d-%H%M%S)-$$"

# transparent stays out of the default set. It only has an effect once the
# client's own transparency option is on, and looks wrong without a
# compositor behind the window.
default_layers=(rounded flat compact)
available_layers=(rounded flat compact transparent)

note() { printf 'omacord: %s\n' "$1"; }
warn() { printf 'omacord: %s\n' "$1" >&2; }

# Copy a file aside before overwriting it. The names omacord writes are few
# and do not collide, so a flat directory per run is enough to undo one.
snapshot() {
  local target=$1
  [[ -e $target || -L $target ]] || return 0
  mkdir -p "$backup_root"
  cp -a -- "$target" "$backup_root/${target##*/}" 2>/dev/null || true
}

# Print the layers to apply, one per line. Fails on an unknown name rather
# than silently shipping a stylesheet the caller did not ask for.
resolve_layers() {
  local requested=${OMACORD_LAYERS-__unset__}
  local layer

  case $requested in
    __unset__) printf '%s\n' "${default_layers[@]}"; return 0 ;;
    all)       printf '%s\n' "${available_layers[@]}"; return 0 ;;
    none | '') return 0 ;;
  esac

  # Built before IFS changes, so the message stays space separated.
  local known=" ${available_layers[*]} "
  local pretty="${available_layers[*]}"

  local IFS=,
  for layer in $requested; do
    [[ -n $layer ]] || continue
    if [[ $known != *" $layer "* ]]; then
      warn "unknown layer '$layer'"
      warn "available layers: $pretty"
      return 1
    fi
    printf '%s\n' "$layer"
  done
}

layer_list=$(resolve_layers) || exit 1
layers=()
[[ -n $layer_list ]] && mapfile -t layers <<<"$layer_list"

# ------------------------------------------------------------------ omarchy
mkdir -p "$hooks" "$templates" "$OMACORD_DATA"

snapshot "$templates/omacord.palette.css.tpl"
install -m 644 "$here/assets/omarchy/omacord.palette.css.tpl" \
  "$templates/omacord.palette.css.tpl"

install -m 644 "$here/omarchy/lib.sh" "$OMACORD_DATA/lib.sh"
install -m 755 "$here/omarchy/theme-set-hook" "$hooks/omacord"

# Flatten the stylesheet now so that applying a theme is two file reads and a
# write, rather than a directory walk.
{
  cat "$here/assets/discord/base.css"
  for layer in ${layers+"${layers[@]}"}; do
    printf '\n'
    cat "$here/assets/discord/layers/$layer.css"
  done
} >"$OMACORD_DATA/style.css.partial"
mv -f "$OMACORD_DATA/style.css.partial" "$OMACORD_DATA/style.css"

# ------------------------------------------------------------------ clients
# Add omacord to the client's enabled theme list. Vencord serves that list
# from memory and rewrites the whole file when it exits, so editing it under
# a running client accomplishes nothing; say so instead of failing silently.
enable_in() {
  local settings=$1 staged
  [[ -f $settings ]] || return 0

  if jq -e --arg name "$OMACORD_THEME_FILE" \
    '(.enabledThemes // []) | index($name) != null' "$settings" >/dev/null 2>&1; then
    return 0
  fi

  if omacord_client_running; then
    note "Discord is running, so its theme list was left untouched."
    note "Turn omacord on under Settings > Themes, or close Discord and run this again."
    return 0
  fi

  snapshot "$settings"
  staged=$(mktemp)
  if jq --arg name "$OMACORD_THEME_FILE" \
    '.enabledThemes = ((.enabledThemes // []) + [$name] | unique)' \
    "$settings" >"$staged" 2>/dev/null; then
    mv -f "$staged" "$settings"
    note "turned on in $settings"
  else
    rm -f "$staged"
    warn "could not edit $settings; turn omacord on under Settings > Themes"
  fi
}

targets=()
mapfile -t targets < <(omacord_client_dirs)

if (( ${#targets[@]} == 0 )); then
  note "no Vencord-based Discord client found yet (looked for Vesktop and Vencord)"
  note "install one and run this again; the shell plugin also retries at startup"
fi

for themes in ${targets+"${targets[@]}"}; do
  mkdir -p "$themes"
  snapshot "$themes/$OMACORD_THEME_FILE"
  note "client: ${themes%/themes}"
  enable_in "$(omacord_settings_for "$themes")"
done

# ------------------------------------------------------------------- render
# Refreshing re-renders the palette and runs the hook, which is what puts the
# stylesheet in front of the client.
if command -v omarchy >/dev/null 2>&1; then
  omarchy theme refresh >/dev/null 2>&1 || warn "'omarchy theme refresh' failed, run it yourself"
else
  warn "omarchy is not on PATH, run 'omarchy theme refresh' once it is"
fi

if (( ${#layers[@]} )); then
  note "layers: ${layers[*]}"
else
  note "layers: none, palette only"
fi
[[ -d $backup_root ]] && note "backups: $backup_root"
note "done, switch themes with 'omarchy theme set <name>'"
exit 0
