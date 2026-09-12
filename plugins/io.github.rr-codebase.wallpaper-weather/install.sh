#!/usr/bin/env bash
#
# Optional desktop integration for the Wallpaper Weather plugin.
#
# The plugin itself works the moment Omarchy loads it -- this script only wires
# up the conveniences that a plugin install cannot do on its own, because they
# live in files that belong to you rather than to the plugin:
#
#   * `wallpaper-weather` on your PATH (a symlink; the script stays in the plugin)
#   * bash completion for it
#   * the bar widget (and optionally the bundled Osaka Jade Weather theme)
#   * a Weather submenu in the Omarchy menu
#
# Everything is opt-in, everything is idempotent, and `--uninstall` removes
# exactly what was added. Run with --dry-run to see what it would do.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$HERE/bin/wallpaper-weather"

BIN_LINK="$HOME/.local/bin/wallpaper-weather"
COMPLETION="$HOME/.local/share/bash-completion/completions/wallpaper-weather"
BINDINGS="$HOME/.config/hypr/bindings.lua"
MENU="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
HOOK="$HOME/.config/omarchy/hooks/theme-set.d/wallpaper-weather.hook"
SHELLJSON="$HOME/.config/omarchy/shell.json"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy"
STATE="$STATE_DIR/wallpaper-weather.json"
LEGACY_STATE="$STATE_DIR/weather-fx.json"
PLUGIN_ID="io.github.rr-codebase.wallpaper-weather"
WIDGET_SECTION="${WALLPAPER_WEATHER_SECTION:-right}"
THEME_SLUG="osaka-jade-weather"
THEME_DIR="$HOME/.config/omarchy/themes/$THEME_SLUG"
STOCK_THEME="${OMARCHY_PATH:-/usr/share/omarchy}/themes/osaka-jade"
THEME_MARKER="$THEME_DIR/.installed-by-wallpaper-weather"

MARK_BEGIN="-- >>> wallpaper-weather >>>"
MARK_END="-- <<< wallpaper-weather <<<"

DRY=0
MODE=install
WANT_HOOK=0
WANT_WIDGET=1
WANT_THEME=0
for arg in "$@"; do
  case "$arg" in
  --dry-run) DRY=1 ;;
  --uninstall) MODE=uninstall ;;
  --with-theme-hook) WANT_HOOK=1 ;;
  --no-widget) WANT_WIDGET=0 ;;
  --with-theme) WANT_THEME=1 ;;
  -h | --help)
    cat <<'USAGE'
Optional desktop integration for the Wallpaper Weather plugin.

The plugin itself works as soon as Omarchy loads it. This wires up the parts a
plugin install cannot, because they live in files that belong to you.

Usage: ./install.sh [--dry-run] [--no-widget] [--with-theme] [--with-theme-hook] [--uninstall]

  (default)           PATH symlink, completion, bar widget
  --no-widget         skip the bar widget
  --with-theme        also build the bundled Osaka Jade Weather theme
  --with-theme-hook   park the weather when you switch away from its theme
  --dry-run           print the plan, change nothing
  --uninstall         remove exactly what was installed

Environment:
  WALLPAPER_WEATHER_SECTION   bar section for the widget (default: right)

Menu rows are not added automatically -- they share a file with your own
entries. Paste extras/omarchy-menu.jsonc, markers included.
USAGE
    exit 0
    ;;
  *)
    echo "install.sh: unknown option '$arg'" >&2
    exit 1
    ;;
  esac
done

say() { printf '  %s\n' "$*"; }
run() { (( DRY )) && say "would: $*" || eval "$@"; }

# ---------------------------------------------------------------- install --

# The CLI migrates the old state file too, but only if it wins the race: the
# shell service writes defaults to the new path the moment it loads, and then
# the CLI sees a file already there and leaves the legacy alone. Migrating here
# is deterministic, and the displaced file is kept rather than deleted.
migrate_state() {
  [[ -s $LEGACY_STATE ]] || return 0
  if (( DRY )); then say "would: migrate $LEGACY_STATE -> $STATE"; return 0; fi
  if [[ -e $STATE ]]; then
    mv -f -- "$STATE" "$STATE.pre-rename"
    say "kept the freshly written state as $(basename "$STATE").pre-rename"
  fi
  mv -- "$LEGACY_STATE" "$STATE"
  say "migrated settings from the plugin's previous name"
  omarchy-shell -q wallpaper-weather reload 2>/dev/null || true
}

install_all() {
  echo "Installing Wallpaper Weather integration:"

  if [[ -e $BIN_LINK && ! -L $BIN_LINK ]]; then
    say "SKIP  $BIN_LINK exists and is not a symlink -- leaving it alone"
  else
    run "mkdir -p '$(dirname "$BIN_LINK")'"
    run "ln -sfn '$CLI' '$BIN_LINK'"
    say "link  $BIN_LINK -> plugin bin/"
  fi

  if [[ -f $HERE/completions/wallpaper-weather ]]; then
    run "mkdir -p '$(dirname "$COMPLETION")'"
    run "install -m 0644 '$HERE/completions/wallpaper-weather' '$COMPLETION'"
    say "shell completion installed"
  fi

  migrate_state

  if (( WANT_THEME )); then
    add_theme
  else
    say "NOTE  bundled theme not installed; pass --with-theme to add it"
  fi

  if (( WANT_WIDGET )); then
    add_widget
  else
    say "SKIP  bar widget (--no-widget)"
  fi

  if (( WANT_HOOK )); then
    run "mkdir -p '$(dirname "$HOOK")'"
    run "install -m 0755 '$HERE/extras/theme-set-hook.sh' '$HOOK'"
    say "theme hook installed (weather parks itself outside its theme)"
  elif [[ -f $HOOK ]]; then
    say "SKIP  theme hook already installed"
  else
    say "NOTE  theme hook not installed; pass --with-theme-hook to add it"
  fi

  if [[ -f $MENU ]] && grep -q '"wallpaper-weather.rain"' "$MENU"; then
    say "SKIP  menu entries already present"
  else
    say "NOTE  menu rows not added automatically (they share a file with your"
    say "      own entries). Paste extras/omarchy-menu.jsonc into"
    say "      ~/.config/omarchy/extensions/omarchy-menu.jsonc"
  fi

  (( DRY )) || {
    command -v hyprctl >/dev/null && hyprctl reload >/dev/null 2>&1 || true
  }
  echo
  echo "Done. Try:  wallpaper-weather --help"
}

# ---------------------------------------------------------------- theme --

# Built from Omarchy's own osaka-jade theme, which is already on the machine,
# rather than shipped in this repo: no redistributing 3.6MB of someone else's
# wallpapers, and no drift when they update them.
#
# Its whole reason to exist is the trimmed backgrounds directory. The sky
# placement defaults are composed for Glowing City, so a theme carrying only
# that background can never leave the moon sitting inside a building.
add_theme() {
  if [[ ! -d $STOCK_THEME ]]; then
    say "SKIP  theme (stock osaka-jade not found at $STOCK_THEME)"
    return 0
  fi
  if [[ -e $THEME_DIR ]]; then say "SKIP  theme already installed"; return 0; fi
  if (( DRY )); then say "would: build the '$THEME_SLUG' theme from $STOCK_THEME"; return 0; fi

  cp -aL -- "$STOCK_THEME" "$THEME_DIR"
  chmod -R u+w -- "$THEME_DIR"
  find "$THEME_DIR/backgrounds" -type f ! -name '1-glowing-city.jpg' -delete 2>/dev/null || true
  ( cd "$THEME_DIR" && find . -type f ! -name '.installed-by-*' -exec sha256sum {} + | sort ) >"$THEME_MARKER"
  say "theme installed -- apply it with: omarchy theme set \"Osaka Jade Weather\""
}

remove_theme() {
  [[ -d $THEME_DIR ]] || return 0
  if [[ ! -f $THEME_MARKER ]]; then
    say "SKIP  theme was not installed by this script -- leaving it alone"
    return 0
  fi
  # Never delete edits. If anything differs from what was generated, keep it.
  local now
  now=$( cd "$THEME_DIR" && find . -type f ! -name '.installed-by-*' -exec sha256sum {} + | sort )
  if [[ $now != "$(cat "$THEME_MARKER")" ]]; then
    say "KEPT  theme has your own changes -- remove it by hand if you want it gone"
    return 0
  fi
  if (( DRY )); then say "would: remove the '$THEME_SLUG' theme"; return 0; fi

  # Removing the active theme would leave the desktop with nothing to render.
  if [[ "$(omarchy theme current 2>/dev/null)" == "Osaka Jade Weather" ]]; then
    omarchy theme set osaka-jade >/dev/null 2>&1 || true
    say "switched back to the Osaka Jade theme"
  fi
  rm -rf -- "$THEME_DIR"
  say "removed theme"
}

# ----------------------------------------------------------- bar widget --

widget_present() {
  [[ -f $SHELLJSON ]] && jq -e --arg id "$PLUGIN_ID" \
    '[.bar.layout[]?[]?.id] | index($id) != null' "$SHELLJSON" >/dev/null 2>&1
}

add_widget() {
  [[ -f $SHELLJSON ]] || { say "SKIP  $SHELLJSON not found"; return 0; }
  if widget_present; then say "SKIP  bar widget already placed"; return 0; fi
  if (( DRY )); then say "would: add the bar widget to the '$WIDGET_SECTION' section"; return 0; fi

  cp -- "$SHELLJSON" "$SHELLJSON.osaka-bak"
  if jq --arg id "$PLUGIN_ID" --arg sec "$WIDGET_SECTION" \
      '.bar.layout[$sec] = ([{id: $id}] + (.bar.layout[$sec] // []))' \
      "$SHELLJSON.osaka-bak" >"$SHELLJSON.tmp" && jq -e . "$SHELLJSON.tmp" >/dev/null; then
    mv -f -- "$SHELLJSON.tmp" "$SHELLJSON"
    rm -f -- "$SHELLJSON.osaka-bak"
    say "bar widget added to the '$WIDGET_SECTION' section"
  else
    rm -f -- "$SHELLJSON.tmp"
    mv -f -- "$SHELLJSON.osaka-bak" "$SHELLJSON"
    say "bar widget NOT added (edit would have broken $SHELLJSON)"
  fi
}

remove_widget() {
  [[ -f $SHELLJSON ]] || return 0
  widget_present || return 0
  if (( DRY )); then say "would: remove the bar widget from $SHELLJSON"; return 0; fi

  cp -- "$SHELLJSON" "$SHELLJSON.osaka-bak"
  if jq --arg id "$PLUGIN_ID" \
      '.bar.layout |= with_entries(.value |= map(select(.id != $id)))' \
      "$SHELLJSON.osaka-bak" >"$SHELLJSON.tmp" && jq -e . "$SHELLJSON.tmp" >/dev/null; then
    mv -f -- "$SHELLJSON.tmp" "$SHELLJSON"
    rm -f -- "$SHELLJSON.osaka-bak"
    say "removed bar widget"
  else
    rm -f -- "$SHELLJSON.tmp"
    mv -f -- "$SHELLJSON.osaka-bak" "$SHELLJSON"
    say "bar widget left in place (edit would have broken $SHELLJSON)"
  fi
}

# ------------------------------------------------------------- menu rows --

remove_menu_rows() {
  [[ -f $MENU ]] || return 0
  if ! grep -q "wallpaper-weather >>>" "$MENU"; then
    if grep -q '"wallpaper-weather' "$MENU"; then
      say "ACTION NEEDED  menu rows present but without the marker comments, so"
      say "               they cannot be removed safely. Delete the keys starting"
      say "               \"wallpaper-weather\" from $MENU"
    fi
    return 0
  fi

  if (( DRY )); then
    say "would: remove the marked menu rows from $MENU"
    return 0
  fi

  cp -- "$MENU" "$MENU.osaka-bak"
  python3 - "$MENU" <<'PYEOF' || { mv -f -- "$MENU.osaka-bak" "$MENU"; say "menu rows left alone (removal would have broken the file)"; return 0; }
import json, pathlib, re, sys

p = pathlib.Path(sys.argv[1])
lines = p.read_text().splitlines(keepends=True)
begin = next(i for i, l in enumerate(lines) if "wallpaper-weather >>>" in l)
end = next(i for i, l in enumerate(lines) if "wallpaper-weather <<<" in l)
kept = lines[:begin] + lines[end + 1:]

def parses(text):
    try:
        json.loads(re.sub(r"^\s*//.*$", "", text, flags=re.M))
        return True
    except ValueError:
        return False

text = "".join(kept)
if not parses(text):
    # Our block was the last entry, so the one before it now has a dangling
    # comma. Strip it from the last line that is actually JSON -- never from a
    # commented-out template line, which a regex over the whole file will
    # happily eat.
    for i in range(len(kept) - 1, -1, -1):
        stripped = kept[i].strip()
        if not stripped or stripped.startswith("//") or stripped == "}":
            continue
        if stripped.endswith(","):
            kept[i] = kept[i].rstrip()[:-1] + "\n"
        break
    text = "".join(kept)

if not parses(text):
    sys.exit(1)
p.write_text(text)
PYEOF
  rm -f -- "$MENU.osaka-bak"
  say "removed menu rows"
}

# -------------------------------------------------------------- uninstall --

uninstall_all() {
  echo "Removing Wallpaper Weather integration:"

  if [[ -L $BIN_LINK ]] && [[ "$(readlink -f "$BIN_LINK")" == "$(readlink -f "$CLI")" ]]; then
    run "rm -f '$BIN_LINK'"
    say "removed $BIN_LINK"
  else
    say "SKIP  $BIN_LINK is not our symlink"
  fi

  [[ -f $COMPLETION ]] && { run "rm -f '$COMPLETION'"; say "removed completion"; }

  # Older versions bound SUPER+ALT keys. Take them back out on upgrade paths
  # that run --uninstall, even though nothing installs them any more.
  if [[ -f $BINDINGS ]] && grep -qF -- "$MARK_BEGIN" "$BINDINGS"; then
    if (( DRY )); then
      say "would: strip the marked block from $BINDINGS"
    else
      # Delete strictly between the markers, inclusive.
      sed -i "/$(printf '%s' "$MARK_BEGIN" | sed 's/[]\/$*.^[]/\\&/g')/,/$(printf '%s' "$MARK_END" | sed 's/[]\/$*.^[]/\\&/g')/d" "$BINDINGS"
      say "removed keybindings"
    fi
  fi

  if [[ -f $HOOK ]]; then
    run "rm -f '$HOOK'"
    say "removed theme hook"
  fi

  remove_widget
  remove_menu_rows
  remove_theme

  echo
  echo "The plugin itself is untouched. Remove it with:"
  echo "  omarchy plugin enable omarchy.background"
  echo "  omarchy plugin remove io.github.rr-codebase.wallpaper-weather"
}

case "$MODE" in
install) install_all ;;
uninstall) uninstall_all ;;
esac
