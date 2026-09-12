# Bisaikō — roadmap

## Automate the Hyprland window-rule install

Currently, getting the popup to float/position correctly requires manually
copying the rule from `hyprland.lua` into the user's own
`~/.config/hypr/hyprland.lua` (documented in README.md's install steps).
`omarchy plugin add` has no post-install hook mechanism at all — by design,
per Omarchy's own explicit warning that plugins run as unsandboxed code, so
it deliberately never auto-executes anything beyond loading a plugin's
declared QML entry points. So this can't be collapsed into
`omarchy plugin add ... --enable` alone; the best available shape is a
separate, idempotent install script the user runs once by hand (the same
two-step pattern `youtube-notification-floater` already uses for its own
Hyprland window-rule wiring).

Steps:

1. Ship the window rule as its own separate file in this repo (e.g.
   `hypr/bisaiko-window-rules.lua`, holding the `bisaiko_windows` table +
   `for` loop) instead of documentation telling the user to copy-paste it
   into their personal `hyprland.lua`.
2. Add an `install.sh` that copies that file into
   `~/.config/hypr/bisaiko-window-rules.lua`, then appends one short,
   self-guarding hook line to `hyprland.lua` — check the file exists, then
   `dofile` it (the exact same shape as the App Homes and youtube-floater
   hooks already commonly found in that file).
3. Check the hook line isn't already present before appending, so
   re-running install is a safe no-op instead of duplicating it.

Once built, update README.md's install steps to point at `install.sh`
instead of the manual copy-paste instructions, and update the marketplace
`description` in `manifest.json` accordingly.

## Before any of that: cut a real release for the current manifest.json change

`manifest.json`'s `description` was already updated (2026-09-06) to mention
the manual copy-paste step, since that's how setup actually works today.
But per this repo's own DECISIONS.md ("the marketplace sync watches the
releases feed, so a bare tag is not enough"), a plain commit/push to `main`
does **not** update what's shown on the live marketplace page
(plugins.omarchy.org/plugin.html?id=prusso.bisaiko) -- that needs an actual
versioned release (git tag + GitHub Release), following whatever this
person's normal release-approval process is before any external
release/marketplace action.

So the actual order of operations:
1. Cut a real release now, so the marketplace reflects the current
   (manual-copy-paste) setup instructions already committed to
   `manifest.json`.
2. Later, once `install.sh` exists (the three steps above), update
   `manifest.json`'s `description` again to describe running `install.sh`
   instead of the manual copy-paste step.
3. Cut another release after that second description change, so the
   marketplace catches up to the automated instructions too.
