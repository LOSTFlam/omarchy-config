#!/bin/bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/security.sh
source "$script_dir/lib/security.sh"

state_raw=""
current_theme=""

theme_modes_state_directory >/dev/null
state_raw=$(safe_read_regular_file "$theme_modes_state_file" "$THEME_MODES_MAX_STATE_BYTES" 2>/dev/null || true)

theme_modes_current_theme_directory >/dev/null
current_theme=$(safe_read_regular_file "$theme_modes_current_theme_file" "$THEME_MODES_MAX_THEME_NAME_BYTES" 2>/dev/null || true)
current_theme=${current_theme//$'\n'/}
current_theme=${current_theme//$'\r'/}

jq -cn \
  --arg state "$state_raw" \
  --arg currentTheme "$current_theme" \
  '{state:$state, currentTheme:$currentTheme}'
