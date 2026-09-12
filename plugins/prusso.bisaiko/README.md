# Bisaikō

Bisaikō is an Omarchy bar plugin that previews `btop` in an 80×24 terminal
anchored beneath its icon. Hover to preview it, click to pin it, and click again
to close it. Right-click the icon to configure the popup and icon placement.


## Requirements

- Omarchy with the user-plugin system
- `btop` available on `PATH`
- `foot`, `jq`, `flock`, and `hyprctl`

For faster repeat openings, Bisaikō automatically uses Foot's socket-activated
server when `footclient` and `$XDG_RUNTIME_DIR/foot.sock` are available. It
falls back to launching Foot normally otherwise.

## Install from the Omarchy plugin marketplace

Install and enable Bisaikō directly from its public repository:

```bash
omarchy plugin add https://github.com/prusso/bisaiko.git --enable
```

Then add `{ "id": "prusso.bisaiko" }` to the desired bar section in
`~/.config/omarchy/shell.json` and add the rule from `hyprland.lua` to the
personal overrides at the bottom of `~/.config/hypr/hyprland.lua`.

## Install locally

Copy `BarWidget.qml`, `bisaiko`, and `manifest.json` to
`~/.config/omarchy/plugins/prusso.bisaiko/`, make the `bisaiko` helper
executable, and add `{ "id": "prusso.bisaiko" }` to the
desired bar section in `~/.config/omarchy/shell.json`. To install under a
different id, change it in all three places: the directory name, the
`moduleName` in `BarWidget.qml`, and `module_name` in the `bisaiko` helper.

Add the rule from `hyprland.lua` to the personal overrides at the bottom of
`~/.config/hypr/hyprland.lua`. Reload Hyprland and verify that
`hyprctl configerrors` is empty.

The recommended placement is the center section. The bar entry is
intentionally separate from the plugin files so users can choose their own
placement, and the settings menu can move it later.

## Usage

- Hover over the icon to preview btop.
- Move into the btop window to interact with it.
- Move away from both the icon and window to close an unpinned preview.
- Click the icon to pin the preview; click again to close it.
- When hover preview is disabled, click once to open an unpinned preview, click
  again to pin it, click again to unpin it, and click once more to close it.
- Right-click the icon to open Bisaikō settings.
- Changing workspaces or opening a special/scratchpad workspace closes it.

After Omarchy's standard hover delay, a compact one-line hint explains the
click-to-pin and right-click-for-settings controls without presenting Bisaikō
as multiple bar icons. Its typography matches Omarchy's native tooltips, while
its total height is reduced by 39.25% so it obscures less of the preview.

## Settings

The right-click menu provides nine popup positions: all four corners, the
middle of all four edges, and the center of the screen. It can also move the
icon between the bar's left, center, and right sections. The highlighted
section is read from Omarchy's live bar layout, so it stays correct even if
the icon is moved with `omarchy bar move` or by dragging it in the shell.

Opening delay and dismissal polling are adjustable in milliseconds. The
defaults preserve Bisaikō's tuned behavior: a 50 ms opening delay and an 80 ms
dismissal polling interval. **Reset Bisaikō defaults** restores every Bisaikō
setting to its opinionated default: the top-center popup position, the center
icon section, the 50 ms opening delay, and the 80 ms dismissal polling
interval.

Hover preview can be turned off in the settings menu when you prefer to open
Bisaikō only with a click. Clicking the icon still toggles the popup while
hover preview is disabled.

These preferences persist across shell reloads and logins in
`~/.config/omarchy/prusso.bisaiko-settings.json`.

The helper serializes state changes so rapid hover/click events cannot create
multiple btop windows. Position-specific app IDs let Hyprland place each popup
correctly before it is drawn, avoiding a visible post-map jump.

## Uninstall

Close Bisaikō, remove its bar entry and plugin directory, then remove the
Bisaikō rule from `~/.config/hypr/hyprland.lua`.

## Design notes

The popup is a real Foot terminal rather than an imitation of btop. Its watcher
exists only while the popup is open and exits when the terminal closes.

Runtime state (lock, PID, and hover/pin flags) lives in
`$XDG_RUNTIME_DIR/bisaiko-$UID`. When `$XDG_RUNTIME_DIR` is unset or is not a
private directory, Bisaikō falls back to `/tmp/bisaiko-$UID`, which it creates
with mode `700` and refuses to use if the path already exists as a symlink or
as a directory not privately owned by the current user. The PID read before
any `kill` is only taken from a regular, non-symlink file inside that
validated directory.
