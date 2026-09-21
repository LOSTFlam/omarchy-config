# Security reporting and boundaries

Use GitHub's private vulnerability reporting on this repository's Security page
when it is enabled. If it is unavailable, request a private contact channel in
an issue without including exploit details, credentials or personal data. Private
reporting must be enabled as part of the publication checklist.

Outfit is an unsandboxed Omarchy shell plugin. Its external Python helpers use
fixed executable paths and argument arrays, bounded input/output, restricted
probe environments, timeouts and process-group cleanup. Remote content is
untrusted: URLs are host/path constrained and cache writes are private and atomic.
Listing and device text is rendered as plain text. README formatting uses an
escaped markup allowlist; repository HTML and inline images are not rendered.
Optional video is loaded only on explicit playback.

Marketplace installation is bound to the catalog's full `listingCommit`: fetch,
checkout, identity checks and revision verification precede native installation
and any plugin execution. The native installer receives a private verified local
repository with Git hooks and inherited configuration disabled. Missing or
unavailable commits fail closed, without a moving-HEAD fallback. This boundary
does not sandbox the reviewed plugin or certify its behavior after activation.
See [implementation and tests](tests/PINNED_INSTALL_RESULTS.md).

Ordinary in-app updates and the detached self-update worker share the same
pre-execution pinning boundary for the user-confirmed target SHA. The native
updater can fetch only from a verified local snapshot, using a process-only Git
mapping with network transports disabled. The installed origin/configuration is
not temporarily changed. Executable Git configuration is rejected before status
inspection; source, fast-forward ancestry and placement are checked before native
mutation. See [update regression evidence](tests/PINNED_UPDATE_RESULTS.md).

Review `scripts/outfit.py`, `Service.qml`, `BackgroundWorker.qml`,
`ThumbnailLoader.qml`, and the media components when changing those boundaries.
New network hosts, subprocesses, write locations or automatic actions require
matching documentation and adversarial regression tests.

The demo environment is explicit and isolated by `OUTFIT_DEMO_ROOT` (with the
historical `OMAFIT_DEMO_ROOT` fallback); it dispatches
to the fictional helper instead of the system helper. Demo plugin mutations and
real network/probe commands are disabled. The VM/capture harnesses refuse physical
hosts. They do not certify that a release works on hardware not yet tested.

Static validation and passing tests are scoped evidence for a particular source
revision, not a security certification or a guarantee about third-party plugins.
