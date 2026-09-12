#!/bin/bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/security.sh
source "$script_dir/lib/security.sh"

slug="${1:-}"
if ! is_valid_slug "$slug"; then
  printf '[]\n'
  exit 0
fi

mapfile -t roots < <(background_roots_for_slug "$slug")
if ((${#roots[@]} == 0)); then
  printf '[]\n'
  exit 0
fi

build_background_record() {
  local path="$1"
  local thumb="$2"
  local base label verified_path verified_thumb

  verified_path=$(verify_background_path "$slug" "$path" 2>/dev/null || true)
  [[ -n $verified_path ]] || return 1
  field_within_limit "$verified_path" "$THEME_MODES_MAX_FIELD_BYTES" || return 1

  if [[ -n $thumb ]]; then
    verified_thumb=$(verify_thumbnail_path "$thumb" 2>/dev/null || verify_background_path "$slug" "$thumb" 2>/dev/null || true)
  fi
  [[ -n $verified_thumb ]] || verified_thumb="$verified_path"
  field_within_limit "$verified_thumb" "$THEME_MODES_MAX_FIELD_BYTES" || verified_thumb="$verified_path"

  base=$(basename -- "$verified_path")
  label="${base%.*}"
  field_within_limit "$label" "$THEME_MODES_MAX_NAME_BYTES" || return 1

  jq -cn \
    --arg path "$verified_path" \
    --arg name "$label" \
    --arg thumbnailPath "$verified_thumb" \
    '{path:$path, name:$name, thumbnailPath:$thumbnailPath}'
}

json_emit_reset
for root in "${roots[@]}"; do
  [[ -n $root && -d $root && ! -L $root ]] || continue
  while IFS= read -r -d '' image; do
    [[ -n $image ]] || continue
    field_within_limit "$image" "$THEME_MODES_MAX_FIELD_BYTES" || continue
    record=$(build_background_record "$image" "$image" 2>/dev/null || true)
    [[ -n $record ]] || continue
    json_emit_record "$record" "$THEME_MODES_MAX_BACKGROUND_JSON_BYTES" "$THEME_MODES_MAX_BACKGROUND_RECORDS" || break 2
  done < <(find -P "$root" -maxdepth 1 -type f \
    \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' -o -iname '*.bmp' -o -iname '*.webp' \) \
    -print0 2>/dev/null)
done
json_emit_finish
