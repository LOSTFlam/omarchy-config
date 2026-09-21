# Pinned marketplace installation — 0.3.1

Finding: [marketplace review #7585](https://github.com/omacom/omarchy-plugin-marketplace/issues/7585#issuecomment-5752220543).

## Production boundary

`scripts/outfit.py::install_reviewed_plugin` fetches the catalog's exact full SHA,
checks out and verifies that revision in private staging, verifies manifest ID,
and invokes native validation before handing the verified repository to native
`omarchy plugin add`. No remote HEAD is installed and reset afterward. Only file
transport is permitted during the native handoff; hooks and inherited Git config
are disabled throughout. Origin is restored only for an exact clean installation
cloned from that stage. Requested activation follows successful final verification.

Single and batch install recovery retain the SHA. Backend activation retries also
recheck the current listing, installed checkout and canonical upstream origin.

## Reproduction

```sh
python3 -B -m unittest -v tests.test_pinned_install
```

The disposable repository has reviewed commit A and a different remote HEAD B.
Both contain an installer-hook fixture with distinct harmless marker files. At
native handoff, the fixture asserts that A has already been checked out; it clones
the supplied local source and executes the hook. Only A's marker is created.
Installed HEAD and file contents equal A, origin is the canonical catalog URL,
and staging is removed without leaving Git alternates. A subsequent fetch and
fast-forward still works.

Other cases reject invalid/missing SHAs, unavailable/wrong fetched commits, wrong
manifest ID, failed checkout/validation, and pre-existing destinations. Poisoned
global hook/template/filter/URL-rewrite settings cannot execute. A simulated native
completion timeout finalizes only the exact verified checkout. Backend recovery
rejects wrong origins and installed revisions; inventory cannot label B successful.

The optional native test copies the installed Omarchy add, validate and URL-check
scripts into an isolated runtime, uses a temporary HOME and inert catalog/shell
IPC, and installs A through those actual scripts. Tested locally on Omarchy 4.0.4.
Machines without Omarchy skip that one integration test. No real desktop plugin
or shell registration is modified.

The public-network fetch alone is substituted with a local fixture transport;
Git object transfer, checkout, verification and native subprocess execution are
real. The sentinel installer is a test double for the execution boundary, not a
claim that stock Omarchy runs `install.py`. Live QML loading and a fresh whole-VM
lifecycle run are outside this focused regression's scope.

QML fixtures cover exact-revision success, mismatch rejection during reconciliation,
and single/batch activation retries preserving authorization. Existing lifecycle
fixtures now supply the revisions required by this contract. The full QML suite
passed 749 checks on Qt 6.11.2 with the repository's host stubs.

## Checks run

- `python3 -B -m unittest tests.test_pinned_install`: 11 passed, including the
  packaged native integration test on this Omarchy host.
- `./tests/run --python-only`: 503 tests run, one optional search-pack artifact
  test skipped; Python syntax, fixture, portable and native manifest checks passed.
- `QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software /usr/lib/qt6/bin/qmltestrunner
  -input tests/qml -import tests/qml/imports`: 749 passed, zero failures.
- Portable plugin validator, `qmlformat Service.qml` parsing and
  `git diff --check`: passed.

An initial all-QML invocation reached the tool's 120-second timeout. The completed
run used a sufficient deadline (about 204 seconds) after fixing stale fixture
revision expectations and the pre-existing compact-spacing test mismatch.
