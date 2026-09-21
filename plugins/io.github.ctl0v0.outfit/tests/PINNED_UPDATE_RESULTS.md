# Pinned updates — 0.3.2

Follow-up hardening to the installation finding in
[marketplace review #7585](https://github.com/omacom/omarchy-plugin-marketplace/issues/7585#issuecomment-5752220543).
The maintainer's reported finding concerned installs; this follow-up closes the
related moving-HEAD race in ordinary updates and the independent self-update worker.

## Production path

- `scripts/outfit.py::reviewed_repository`: shared install/update exact-SHA fetch,
  checkout, identity, clean-tree and native validation in private staging.
- `scripts/outfit.py::update_reviewed_plugin`: staged version and actual Git
  fast-forward proof; fresh installed source/config/placement checks; process-local
  URL mapping to the staged checkout; file-only transport before native update.
- `execute_plugin_update` and `scripts/self_update.py::_work`: both dispatch
  through that helper, then retain their final result/receipt verification.
- `inspect_update_target`: rejects executable Git configuration before status
  could invoke a clean filter; blocks replacement refs and unsupported repository
  layouts. No installed configuration is modified to achieve pinning.

The update SHA is the user-confirmed upstream target. Marketplace installation
continues to require the catalog's `listingCommit`; user confirmation of an update
does not imply marketplace approval of that newer revision.

## Adversarial regression

```sh
python3 -B -m unittest -v tests.test_pinned_update
python3 -B -m unittest tests.test_pinned_update tests.test_pinned_install tests.test_plugin_updates tests.test_self_update
```

The fixture starts at installed A, offers reviewed update B, and moves upstream
HEAD to C immediately before native execution. The native fetch still receives B
from verified local staging. At the modeled code-loading boundary, only B's harmless
execution marker appears; C's marker never appears. Installed `.git/config` remains
byte-identical, the public origin is retained, and staging is removed.

The cases run for an ordinary plugin ID and `io.github.ctl0v0.outfit`:

- unavailable or wrong fetched SHA never reaches the native updater;
- mismatched version or missing fast-forward ancestry blocks mutation;
- local edits or placement changes during staging prevent dispatch;
- an unconfirmed effective-origin mapping fails closed;
- native validation rollback and completion timeout preserve origin and cleanup;
- changing origin to HTTPS after the mapping check yields Git's explicit
  `transport 'https' not allowed` refusal, with no network fallback;
- a configured clean filter cannot execute during eligibility inspection.

Two optional cases execute the installed Omarchy 4.0.4 updater and validator
scripts with an isolated HOME/runtime and inert shell IPC. The rescan stub checks
installed HEAD B before executing its sentinel. This exercises actual native
fetch/fast-forward/validation ordering without touching the running desktop.

Public fetch transport alone is substituted with a local repository. Git fetch,
checkout, ancestry checks, URL mapping and native subprocesses are real. The
portable fixture models native rollback; the packaged-native cases exercise
success and the late-HEAD race. Self-update transaction tests separately model
the pinned mutator and verify that its original/target SHAs, source binding and
version are retained before restart. No new live systemd worker/restart or full
graphical VM lifecycle run is claimed by this report.

## Results

- Focused install/update/self-update suites: **118 tests passed**, including all
  **20** new real-Git update cases and both packaged-native updater cases locally.
- Full Python suite: **523 tests run**, one optional search-pack artifact skipped.
  CI hosts without Omarchy additionally skip the native installer and two native
  updater cases.
- No QML implementation changed; existing QML state/lifecycle coverage is run by
  the portable CI job on the published candidate.

The first Ubuntu CI run exposed system Git configuration leaking into disposable
metadata fixtures (host-wide Git LFS filters make such a source unsupported by the
production policy). Test launch adapters now explicitly disable system Git config
for those fixture reads while preserving repository-local adversarial settings.
The production configuration checks were not weakened. Arch/Qt passed that initial
run; final CI is linked from the marketplace submission at its final candidate SHA.

The prior [0.3.1 install report](PINNED_INSTALL_RESULTS.md) and older
[VM update report](vm/PLUGIN_UPDATES_RESULTS.md) describe their own snapshots and
are not claims that these newer paths were exercised in those earlier sessions.
