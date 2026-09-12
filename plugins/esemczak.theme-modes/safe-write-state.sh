#!/bin/bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/security.sh
source "$script_dir/lib/security.sh"

theme_modes_state_directory >/dev/null
safe_write_regular_file "$theme_modes_state_file" "$THEME_MODES_MAX_STATE_BYTES"
