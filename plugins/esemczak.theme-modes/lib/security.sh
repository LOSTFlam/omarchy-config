#!/bin/bash

set -euo pipefail

readonly THEME_MODES_MAX_STATE_BYTES=65536
readonly THEME_MODES_MAX_THEME_NAME_BYTES=256
readonly THEME_MODES_MAX_SCRIPT_OUTPUT_BYTES=524288
readonly THEME_MODES_MAX_CATALOG_JSON_BYTES=524288
readonly THEME_MODES_MAX_BACKGROUND_JSON_BYTES=524288
readonly THEME_MODES_MAX_CATALOG_RECORDS=256
readonly THEME_MODES_MAX_BACKGROUND_RECORDS=256
readonly THEME_MODES_MAX_INPUT_LINE_BYTES=256
readonly THEME_MODES_MAX_FIELD_BYTES=4096
readonly THEME_MODES_MAX_NAME_BYTES=128
readonly THEME_MODES_MAX_ENTRY_JSON_BYTES=16384
readonly THEME_MODES_MAX_IMAGE_BYTES=52428800
readonly THEME_MODES_IMAGE_EXTENSIONS='jpg jpeg png gif bmp webp'

theme_modes_json_bytes=0
theme_modes_json_records=0

theme_modes_lib_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

theme_modes_home="${HOME:?HOME is required}"
theme_modes_state_file="$theme_modes_home/.local/state/omarchy/settings/theme-modes.json"
theme_modes_current_theme_file="$theme_modes_home/.local/state/omarchy/current/theme.name"
theme_modes_preview_dir="${XDG_CACHE_HOME:-$theme_modes_home/.cache}/omarchy/theme-selector/previews"
theme_modes_image_cache_dir="${XDG_CACHE_HOME:-$theme_modes_home/.cache}/omarchy/image-selector"
theme_modes_verified_image_cache_dir="${XDG_CACHE_HOME:-$theme_modes_home/.cache}/omarchy/theme-modes/verified-images"
theme_modes_omarchy_path="${OMARCHY_PATH:-/usr/share/omarchy}"

_security_py() {
  python3 "$theme_modes_lib_dir/security_core.py" "$@"
}

is_valid_slug() {
  local slug="${1:-}"
  [[ -n $slug && $slug != "." && $slug != ".." ]] || return 1
  [[ $slug =~ ^[a-z0-9]+$ || $slug =~ ^[a-z0-9]+([_-][a-z0-9]+)*$ ]]
}

slugify_name() {
  local value="${1:-}"
  [[ $value != *"/"* && $value != *"\\"* && $value != *".."* ]] || return 1
  value=$(printf '%s' "$value" | sed -E 's/<[^>]+>//g; s/[[:space:]]+/-/g; y/ABCDEFGHIJKLMNOPQRSTUVWXYZ/abcdefghijklmnopqrstuvwxyz/; s/[^a-z0-9_-]+//g')
  while [[ $value == [-_]* ]]; do value=${value#?}; done
  while [[ $value == *[-_] ]]; do value=${value%?}; done
  while [[ $value == *--* ]]; do value=${value//--/-}; done
  while [[ $value == *-_* ]]; do value=${value//-_/-}; done
  while [[ $value == *_-* ]]; do value=${value//_-/}; done
  is_valid_slug "$value" || return 1
  printf '%s' "$value"
}

path_is_under_root() {
  local root="$1"
  local target="$2"
  local resolved_root resolved_target

  [[ -n $root && -n $target ]] || return 1
  resolved_root=$(readlink -f -- "$root" 2>/dev/null) || return 1
  resolved_target=$(readlink -f -- "$target" 2>/dev/null) || return 1
  [[ $resolved_target == "$resolved_root" || $resolved_target == "$resolved_root/"* ]]
}

ensure_private_directory() {
  local dir="$1"
  [[ -n $dir ]] || return 1
  _security_py ensure-dir "$dir"
}

theme_modes_state_directory() {
  ensure_private_directory "$(dirname -- "$theme_modes_state_file")"
}

theme_modes_current_theme_directory() {
  ensure_private_directory "$(dirname -- "$theme_modes_current_theme_file")"
}

safe_read_regular_file() {
  local path="$1"
  local max_bytes="${2:-4096}"
  _security_py read-regular "$path" "$max_bytes"
}

safe_write_regular_file() {
  local path="$1"
  local max_bytes="${2:-65536}"
  _security_py write-regular "$path" "$max_bytes"
}

image_extension_for() {
  local path="$1"
  local base ext
  base=$(basename -- "$path")
  ext=${base##*.}
  ext=$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')
  case " $THEME_MODES_IMAGE_EXTENSIONS " in
    *" $ext "*) printf '%s' "$ext" ;;
    *) return 1 ;;
  esac
}

verify_regular_image_under() {
  local path="$1"
  local root="$2"
  local max_bytes="${3:-$THEME_MODES_MAX_IMAGE_BYTES}"

  [[ -n $path && -n $root ]] || return 1
  image_extension_for "$path" >/dev/null || return 1
  _security_py materialize-image "$path" "$root" "$max_bytes" "$theme_modes_verified_image_cache_dir"
}

theme_dir_for_slug() {
  local slug="$1"
  local user_dir stock_dir

  is_valid_slug "$slug" || return 1
  user_dir="$theme_modes_home/.config/omarchy/themes/$slug"
  if [[ -d $user_dir && ! -L $user_dir ]]; then
    readlink -f -- "$user_dir"
    return 0
  fi
  stock_dir="$theme_modes_omarchy_path/themes/$slug"
  if [[ -d $stock_dir && ! -L $stock_dir ]]; then
    readlink -f -- "$stock_dir"
    return 0
  fi
  return 1
}

background_roots_for_slug() {
  local slug="$1"
  local theme_dir user_dir

  is_valid_slug "$slug" || return 1
  theme_dir=$(theme_dir_for_slug "$slug" 2>/dev/null || true)
  if [[ -n $theme_dir && -d $theme_dir/backgrounds && ! -L $theme_dir/backgrounds ]]; then
    readlink -f -- "$theme_dir/backgrounds"
  fi
  user_dir="$theme_modes_home/.config/omarchy/backgrounds/$slug"
  if [[ -d $user_dir && ! -L $user_dir ]]; then
    readlink -f -- "$user_dir"
  fi
}

verify_background_path() {
  local slug="$1"
  local path="$2"
  local root verified

  is_valid_slug "$slug" || return 1
  [[ -n $path ]] || return 1
  while IFS= read -r root; do
    [[ -n $root ]] || continue
    verified=$(_security_py materialize-image "$path" "$root" "$THEME_MODES_MAX_IMAGE_BYTES" "$theme_modes_verified_image_cache_dir" 2>/dev/null || true)
    if [[ -n $verified ]]; then
      printf '%s' "$verified"
      return 0
    fi
  done < <(background_roots_for_slug "$slug")
  return 1
}

theme_preview_roots_for_slug() {
  local slug="$1"
  local theme_dir

  is_valid_slug "$slug" || return 1
  ensure_private_directory "$theme_modes_preview_dir" >/dev/null || true
  printf '%s\n' "$theme_modes_preview_dir"
  theme_dir=$(theme_dir_for_slug "$slug" 2>/dev/null || true)
  [[ -n $theme_dir ]] && printf '%s\n' "$theme_dir"
}

verify_preview_path() {
  local slug="$1"
  local path="$2"
  local root verified

  is_valid_slug "$slug" || return 1
  [[ -n $path && -e $path ]] || return 1

  while IFS= read -r root; do
    [[ -n $root ]] || continue
    verified=$(_security_py materialize-image "$path" "$root" "$THEME_MODES_MAX_IMAGE_BYTES" "$theme_modes_verified_image_cache_dir" 2>/dev/null || true)
    if [[ -n $verified ]]; then
      printf '%s' "$verified"
      return 0
    fi
  done < <(theme_preview_roots_for_slug "$slug")
  return 1
}

verify_thumbnail_path() {
  local path="$1"
  local verified

  [[ -n $path ]] || return 1
  ensure_private_directory "$theme_modes_image_cache_dir" >/dev/null || return 1
  verified=$(_security_py materialize-image "$path" "$theme_modes_image_cache_dir" "$THEME_MODES_MAX_IMAGE_BYTES" "$theme_modes_verified_image_cache_dir" 2>/dev/null || true)
  [[ -n $verified ]] || return 1
  printf '%s' "$verified"
}

field_within_limit() {
  local value="$1"
  local max_bytes="${2:-$THEME_MODES_MAX_FIELD_BYTES}"
  local size

  [[ -n $value ]] || return 1
  size=$(printf '%s' "$value" | wc -c | tr -d ' ')
  (( size <= max_bytes ))
}

clamp_input_line() {
  local value="$1"
  local max_bytes="${2:-$THEME_MODES_MAX_INPUT_LINE_BYTES}"
  printf '%s' "$value" | python3 -c 'import sys; limit=int(sys.argv[1]); data=sys.stdin.read(); sys.stdout.write(data.encode("utf-8", errors="replace")[:limit].decode("utf-8", errors="ignore"))' "$max_bytes"
}

json_emit_reset() {
  theme_modes_json_bytes=1
  theme_modes_json_records=0
  printf '['
}

json_emit_record() {
  local record="$1"
  local max_bytes="${2:-$THEME_MODES_MAX_CATALOG_JSON_BYTES}"
  local max_records="${3:-$THEME_MODES_MAX_CATALOG_RECORDS}"
  local record_bytes sep_bytes

  if (( theme_modes_json_records >= max_records )); then
    return 2
  fi

  record_bytes=$(printf '%s' "$record" | wc -c | tr -d ' ')
  if (( record_bytes > THEME_MODES_MAX_ENTRY_JSON_BYTES )); then
    return 1
  fi

  sep_bytes=0
  if (( theme_modes_json_records > 0 )); then
    sep_bytes=1
  fi

  if (( theme_modes_json_bytes + sep_bytes + record_bytes + 1 > max_bytes )); then
    return 2
  fi

  if (( theme_modes_json_records > 0 )); then
    printf ','
  fi
  printf '%s' "$record"
  theme_modes_json_bytes=$((theme_modes_json_bytes + sep_bytes + record_bytes))
  theme_modes_json_records=$((theme_modes_json_records + 1))
  return 0
}

json_emit_finish() {
  printf ']\n'
  theme_modes_json_bytes=$((theme_modes_json_bytes + 1))
}

bounded_theme_names() {
  _security_py bounded-theme-names \
    "$THEME_MODES_MAX_CATALOG_RECORDS" \
    "$THEME_MODES_MAX_INPUT_LINE_BYTES" \
    20 \
    $((THEME_MODES_MAX_CATALOG_RECORDS * THEME_MODES_MAX_INPUT_LINE_BYTES))
}
