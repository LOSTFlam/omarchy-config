#!/bin/bash
# omacord shared helpers. Sourced by install.sh, uninstall.sh and the
# theme-set hook so client discovery has exactly one definition.

OMACORD_DATA="${OMACORD_DATA:-$HOME/.local/share/omacord}"
OMACORD_THEME_FILE="omacord.theme.css"
OMACORD_PALETTE="omacord.palette.css"

# Resolve the Omarchy theme directory. 4.x keeps it under state; older
# layouts used config. Both are checked so the hook works either way.
omacord_theme_dir() {
  if [[ -d $HOME/.local/state/omarchy/current/theme ]]; then
    printf '%s\n' "$HOME/.local/state/omarchy/current/theme"
  elif [[ -d $HOME/.config/omarchy/current/theme ]]; then
    printf '%s\n' "$HOME/.config/omarchy/current/theme"
  else
    return 1
  fi
}

# Every Vencord-compatible themes directory present on this machine, one
# per line. A themes dir is the unit of installation: Vencord reads every
# *.css in it and applies the ones named in enabledThemes.
#
# $OMACORD_THEMES_DIR overrides discovery entirely, for testing.
omacord_client_dirs() {
  local candidate
  local -a roots=()

  if [[ -n ${OMACORD_THEMES_DIR:-} ]]; then
    printf '%s\n' "$OMACORD_THEMES_DIR"
    return 0
  fi

  roots+=("$HOME/.config/vesktop")
  roots+=("$HOME/.config/Vencord")

  # Flatpak keeps the same layout one level down.
  shopt -s nullglob
  roots+=("$HOME"/.var/app/*/config/vesktop)
  roots+=("$HOME"/.var/app/*/config/Vencord)
  shopt -u nullglob

  for candidate in "${roots[@]}"; do
    # Require the client's own config to exist, not just the themes dir:
    # creating themes/ under a path the client never made would leave
    # litter in a directory that is not ours.
    [[ -d $candidate ]] || continue
    printf '%s\n' "$candidate/themes"
  done
}

# The Vencord settings file for a themes dir. Note this is
# <root>/settings/settings.json - for Vesktop the sibling
# <root>/settings.json is the Vesktop *app* config, a different file.
omacord_settings_for() {
  local themes_dir="$1"
  printf '%s\n' "${themes_dir%/themes}/settings/settings.json"
}

# True while a Discord client is running. Vencord rewrites its settings
# file from memory, so an edit made underneath a live client is lost.
omacord_client_running() {
  pgrep -x -u "$(id -u)" 'vesktop|Vesktop|Discord|discord|equibop' >/dev/null 2>&1
}
