# Decisions log

Newest entries first. Each entry records a decision and the reasoning behind
it, so future work does not have to reverse-engineer it from diffs.

## 2026-09-02 — Harden runtime-state directory (v0.3.7, commit `9b541fd`)

The Omarchy marketplace verification review (issue
`omacom/omarchy-plugin-marketplace#3889`) flagged the `bisaiko` helper's
runtime-state directory: the `/tmp/bisaiko-$UID` fallback was a predictable
path used without verifying ownership, permissions, or symlinks before a PID
was read from it and passed to `kill`.

Fix in `bisaiko`:

- `resolve_state_dir()` uses `$XDG_RUNTIME_DIR` only after validating it is a
  real directory (not a symlink), owned by the current uid, mode `700`.
- Otherwise it falls back to `/tmp/bisaiko-$UID` and: dies if that path is a
  symlink; dies if it exists but is not a private (`uid`/`700`, non-symlink)
  directory; otherwise creates it with `umask 077` and plain `mkdir` (no
  `-p`, so a creation race loses) and re-verifies.
- `read_state()` requires a regular, non-symlink, readable file.
- `close_popup()` reads the PID only from a regular non-symlink `pid_file`,
  on top of the existing `^[0-9]+$` guard.
- The Foot control socket (`$runtime_root/foot.sock`) is trusted only on the
  validated private-runtime path, never in the `/tmp` fallback.

Released as v0.3.7 (git tag + GitHub Release; the marketplace sync watches the
releases feed, so a bare tag is not enough). Fresh verification request filed
at `omacom/omarchy-plugin-marketplace#4542`; issues #3875 (malformed form
headings) and #3889 (fix landed at a newer commit) were closed as superseded.

Status as of 2026-09-03: #4542 open, all automation green, awaiting a
maintainer `approved-and-verified` label. Once applied, the marketplace's
daily catalog refresh flips `verificationStatus` to `verified`.
