#!/bin/bash
#
# Keep the weather layer with the theme it belongs to.
#
# Install with:  ./install.sh --with-theme-hook
#
# The FX geometry -- where the moon sits, where the stars stop, where the mist
# band lies -- is tuned to the Osaka Jade city photograph. On any other theme it
# would be drawing weather over the wrong sky, so park it and put the mood back
# when the theme returns.
#
# Delete this file if you would rather have weather on every theme.
set -euo pipefail

# The theme this plugin's weather belongs to. Change it if you tuned the sky
# placement for a different theme's wallpaper.
THEME_SLUG="${WALLPAPER_WEATHER_THEME:-osaka-jade-weather}"

THEME="${1:-}"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/wallpaper-weather.json"
SAVED="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/weather-fx.parked.json"

command -v wallpaper-weather >/dev/null || exit 0
command -v jq >/dev/null || exit 0

if [[ $THEME == "$THEME_SLUG" ]]; then
  # Coming back: restore whatever was on last time, defaulting to night.
  if [[ -s $SAVED ]]; then
    rain=$(jq -r '.rain // false' "$SAVED")
    day=$(jq -r '.day // false' "$SAVED")
    night=$(jq -r '.night // true' "$SAVED")
    rm -f "$SAVED"
  else
    rain=false day=false night=true
  fi
  wallpaper-weather mood "$rain" "$day" "$night" >/dev/null 2>&1 || true
else
  # Leaving: remember the mood, then go still. Don't clobber an existing
  # parked mood -- two non-jade themes in a row would overwrite it with all-off.
  if [[ ! -s $SAVED && -s $STATE ]]; then
    jq '{rain, day, night}' "$STATE" >"$SAVED" 2>/dev/null || true
  fi
  wallpaper-weather clear >/dev/null 2>&1 || true
fi
