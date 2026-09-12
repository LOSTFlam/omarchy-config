#!/bin/bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/security.sh
source "$script_dir/lib/security.sh"

ensure_private_directory "$theme_modes_preview_dir" >/dev/null || exit 1

find_preview() {
  local slug="$1"
  local ext candidate verified theme_dir name

  is_valid_slug "$slug" || return 1
  for ext in png jpg jpeg webp gif bmp; do
    candidate="$theme_modes_preview_dir/$slug.$ext"
    [[ -e $candidate ]] || continue
    verified=$(verify_preview_path "$slug" "$candidate" 2>/dev/null || true)
    [[ -n $verified ]] || continue
    field_within_limit "$verified" "$THEME_MODES_MAX_FIELD_BYTES" || return 1
    printf '%s' "$verified"
    return 0
  done

  theme_dir=$(theme_dir_for_slug "$slug" 2>/dev/null || true)
  [[ -n $theme_dir ]] || return 1
  for name in preview.png preview.jpg preview.jpeg preview.webp preview.gif preview.bmp; do
    candidate="$theme_dir/$name"
    [[ -e $candidate && ! -L $candidate ]] || continue
    verified=$(verify_preview_path "$slug" "$candidate" 2>/dev/null || true)
    [[ -n $verified ]] || continue
    field_within_limit "$verified" "$THEME_MODES_MAX_FIELD_BYTES" || return 1
    printf '%s' "$verified"
    return 0
  done
  return 1
}

build_theme_record() {
  local name="$1"
  local slug="$2"

  field_within_limit "$name" "$THEME_MODES_MAX_NAME_BYTES" || return 1
  field_within_limit "$slug" "$THEME_MODES_MAX_FIELD_BYTES" || return 1
  jq -cn \
    --arg name "$name" \
    --arg slug "$slug" \
    --arg preview "" \
    '{name:$name, slug:$slug, previewPath:$preview}'
}

json_emit_reset
while IFS= read -r raw_name; do
  [[ -n $raw_name ]] || continue
  name=$(clamp_input_line "$raw_name" "$THEME_MODES_MAX_INPUT_LINE_BYTES")
  [[ -n $name ]] || continue
  slug=$(slugify_name "$name" 2>/dev/null || true)
  [[ -n $slug ]] || continue
  record=$(build_theme_record "$name" "$slug" 2>/dev/null || true)
  [[ -n $record ]] || continue
  json_emit_record "$record" "$THEME_MODES_MAX_CATALOG_JSON_BYTES" "$THEME_MODES_MAX_CATALOG_RECORDS" || break
done < <(bounded_theme_names)
json_emit_finish
