# Outfit 0.2.0 identity migration

Outfit 0.2.0 uses **`io.github.ctl0v0.outfit`** for its manifest, runtime IPC,
private stores, Apps launcher, icon, and native plugin registration. The existing
public repository remains `https://github.com/ctl0v0/outfit.git`.

## Upgrading from an early test build?

Use this one-time helper to keep your settings, interests, and supported caches
while moving to the new build's registration. A normal native update alone does
not rename an old registration folder or its shell configuration entries. The
compatibility identity is `io.github.ctl0v0.omafit`; new installations and later
updates use `io.github.ctl0v0.outfit`.

The public repository must contain the **new-ID build** before using `--official`.
Until publication, its default branch may still contain the early test build.
Version 0.2.0 in this checkout does not mean a `v0.2.0` tag has been created. Once
the new build is published, use the [ordinary public installation](#ordinary-public-installation-using-native-add)
steps below: download a separate checkout, review it, preview the migration, then
apply it explicitly. Source and search-pack assets can be published separately;
the pack is not a migration prerequisite.

The one-time helper supports public `6db2b90` installs, developer symlinks, and an
old-named installation folder whose manifest was already changed by a native
update. It runs only when explicitly invoked. Importing it, launching Outfit,
or installing the Apps launcher does not migrate plugin registration or data.

## Before applying

Finish any batch and pending save, save or discard interests and Settings drafts,
then close Outfit's panel. The helper checks **both** identities through bounded
status IPC. Public `6db2b90` does not expose a separate Settings-dirty flag, so a
closed panel is required. If an installed service has never finished its first
analysis, open it once, let it finish, then close it. A missing plugin IPC target
is acceptable; an unavailable, unresponsive, or incompatible shell is not treated
as proof that the service stopped.

Run from a terminal in the Omarchy session, with its trusted `OMARCHY_PATH` set.
The helper resolves native tools under that installation, uses fixed argument
arrays, and never executes a script from `--source`. A supplied local checkout
must be trusted: enabling it loads its QML just as native plugin enable does.

## Separate new checkout: public old installation or developer symlink

For a reviewed new-ID checkout at a separate path, preview with (replace the
example path with your checkout's absolute path):

```bash
python3 -I -B /absolute/path/to/outfit-new/scripts/migrate_identity.py \
  --source /absolute/path/to/outfit-new --dry-run
```

Only when ready to change the desktop registration, repeat explicitly:

```bash
python3 -I -B /absolute/path/to/outfit-new/scripts/migrate_identity.py \
  --source /absolute/path/to/outfit-new --apply
```

`--source` links the new registration to the specified external checkout. Keep
that checkout at the chosen path. For a legacy developer symlink, the old link
is archived; its external target is never edited or moved.

Do not first change a shared manifest used by the running old registration.
Stage a separate new checkout and invoke its helper while the original old
registration is still intact. A live old-ID symlink to a shared manifest that
already changed is also supported: both old and new IPC targets are checked.

## Ordinary public installation using native add

After the public repository's default branch contains the new-ID build, download
a separate checkout into an unused directory. For example, from a directory where
you keep source checkouts:

```bash
git clone https://github.com/ctl0v0/outfit.git outfit-migration-review
```

Review that checkout's `manifest.json`, this guide, `scripts/migrate_identity.py`,
and `scripts/launcher.py` before running the helper. Confirm the manifest uses
`io.github.ctl0v0.outfit` and the new build version. This clone command neither
installs nor enables the plugin. Finish the [preparation steps](#before-applying),
then preview from the same parent directory:

```bash
python3 -I -B ./outfit-migration-review/scripts/migrate_identity.py --official --dry-run
```

Review the plan. When ready, apply it explicitly:

```bash
python3 -I -B ./outfit-migration-review/scripts/migrate_identity.py --official --apply
```

`--official` installs from the public default branch at application time, not from
the review checkout. It is appropriate once that branch contains the reviewed new
build; `--source` above is the separate local-checkout option.

This uses native `omarchy-plugin-add` with the fixed public Git URL and `--yes`,
**without `--enable`**, while the original installation is still retained. An
unreleased old-ID public HEAD is rejected by native duplicate-ID validation.
Data copying and validation complete before the helper restores enabled state
under the new ID. The resulting normal Git clone supports future native updates:

```bash
omarchy plugin update io.github.ctl0v0.outfit
```

For a genuinely fresh installation with no old data or registration, use the
ordinary native install procedure with the same repository and new identity.

## Native update left a new manifest in the old installation folder

Native update does not rename registration folders or `shell.json` entries.
If the old-named folder already contains the 0.2.0 manifest and this helper:

```bash
old="$HOME/.config/omarchy/plugins/io.github.ctl0v0.omafit"
python3 -I -B "$old/scripts/migrate_identity.py" --source "$old" --dry-run
python3 -I -B "$old/scripts/migrate_identity.py" --source "$old" --apply
```

A regular installed checkout is copied to the new folder, including its Git
metadata; the complete old checkout is retained in the migration backup. If
`old` is a symlink, the new registration links to its resolved external source.
An unchanged 0.1.0 checkout cannot be the new source: use a separate reviewed
0.2.0 checkout or `--official` after publication.

From an already new-ID installed path, use:

```bash
new="$HOME/.config/omarchy/plugins/io.github.ctl0v0.outfit"
python3 -I -B "$new/scripts/migrate_identity.py" --source "$new" --dry-run
python3 -I -B "$new/scripts/migrate_identity.py" --source "$new" --apply
```

An existing new installation is validated and preserved. Successful reruns do
not replace its files or reset settings. Existing new data always takes priority.

## Preservation and failure behavior

- Only supported version-1 `shell.json` registration slots are mapped: exact
  IDs in bar `left`/`center`/`right`, `plugins`, and the matching `centerAnchor`.
  Placement, order, inline settings, unrelated plugins, and opaque fields are
  preserved. The original file mode is retained across atomic config updates.
  Unknown/future config shapes, duplicate JSON keys, and old/new registration
  collisions are refused without rewriting the config.
- The helper temporarily removes only the two Outfit IDs, asks the native shell
  to reload that exact config, and waits for both service IPC targets to disappear.
  It does not kill the shell or unrelated processes.
- Private `preferences.json`, `interests.json`, and `quick-setup.json` are copied
  byte-for-byte only if the corresponding new file is absent. Recorded journal
  identities/history and unknown private file schemas are not rewritten.
- Public catalog, README, engagement, preview, thumbnail, and search-index caches
  are allowlisted. SQLite uses the backup API, including committed WAL data;
  WAL/SHM/journal files are not copied as independent database snapshots. New
  files are private (`0600`), published without overwriting an existing file.
  Raw hardware/profile memory, lock files, and unknown files are not migrated.
- Outfit stores honor absolute XDG config/cache/data roots. Native Omarchy's
  shell config and plugin registration use `$HOME/.config/omarchy`, matching the
  native host independently of the private preferences XDG root.
- Old data is retained. Registration and config backups live in a private
  `$HOME/.config/omarchy/.outfit-identity-*` directory. Its `mapping.json` records
  the IDs, source, original mode, phase, and copied paths; `original.json`,
  `paused.json`, and `final.json` preserve recovery evidence.
- The new registration is validated before the new Apps assets are installed.
  The launcher validates both new assets before removing only exact old-ID
  filenames with recognized historical/current ownership markers. Unmanaged
  files or symlinks are refused.
- Normal failures restore the old registration and config when they still match
  this transaction. Copied new data is retained; it is never deleted on rollback.
  Concurrent config edits are preserved and require manual reconciliation.

For a killed/interrupted helper, a rerun prints the pending backup path. Recover
with the same reviewed helper, then rerun the migration:

```bash
python3 -I -B /absolute/path/to/outfit-0.2.0/scripts/migrate_identity.py \
  --rollback "$HOME/.config/omarchy/.outfit-identity-REPLACE_WITH_PRINTED_SUFFIX" --dry-run
python3 -I -B /absolute/path/to/outfit-0.2.0/scripts/migrate_identity.py \
  --rollback "$HOME/.config/omarchy/.outfit-identity-REPLACE_WITH_PRINTED_SUFFIX" --apply
```

Recovery also checks status before changing registration. It refuses to overwrite
config edits made outside the transaction. Completed migration backups are kept
as evidence, not used as an automatic downgrade mechanism.

## Focused verification

```bash
python3 -B -m unittest tests.test_identity_migration tests.test_identity_runtime tests.test_launcher
```

The isolated matrix covers the public old-ID layout, updated old-folder/new-ID
manifest, old and updated developer symlinks, an existing new registration,
missing old service, disabled/service-only placement, inline/opaque settings,
private file modes, future schemas, no-clobber data copying, WAL backup, active
batch/draft gates, bounded IPC, unmanaged assets, source/state symlinks, native
add arguments, runtime failure rollback, interrupted recovery, concurrent edits,
and idempotent reruns. Real-session migration is a separate coordinated staging
action; these tests never call desktop IPC.
