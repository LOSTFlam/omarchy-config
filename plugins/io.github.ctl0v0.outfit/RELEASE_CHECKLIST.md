# Release-candidate gates

## Public source pre-release / fresh-machine check

Publishing source for a fresh-machine test is not a tagged release or a claim that
the full release matrix below has passed. Existing dated results describe local
development/VM snapshots; record new evidence against the public candidate SHA.

Before publishing the source, review the intended file list and exclude
`test-results/`, Python bytecode and `.omarchy-workbench.json`. VM disks, captured
desktop evidence, generated passwords/SSH keys and personal configuration belong
outside the repository. `tests/vm/bootstrap.py` generates a guest password and key
under its new private external `--work` directory; those generated files are not
source fixtures. The maintainer reviews ignore rules, CI changes and Git operations
before publication.

On a fresh **stock Omarchy 4.0.4 stable / Quattro** desktop, once the public source
is available:

1. Use the normal desktop session with no demo/test environment overrides or
   development host link. Record Omarchy, Qt and Python versions.
2. Run `omarchy plugin add https://github.com/ctl0v0/outfit.git --enable`, then record
   the installed revision with
   `git -C "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/io.github.ctl0v0.outfit" rev-parse HEAD`.
   Confirm it matches the intended public candidate.
3. Open the Outfit bar widget (add it under **Other** if needed). Optionally run
   the launcher command in README and check Apps search. Verify Browse, search,
   detail opening and Settings with empty caches, then after reopening.
4. Exercise install/enable/disable/placement/removal with a harmless test plugin.
   Stock-host window reloads and several seconds of reopening delay are expected;
   verify final inventory and recovery rather than requiring continuous windows.
5. Check update, then follow README removal in order: optional launcher first,
   plugin second. Configuration/cache deletion is an explicit opt-in. Record any
   remaining launcher or plugin entry and each observed failure.

The specialized targeted-host VM harnesses require their documented fixture paths;
they are not ordinary installation steps. The public-source stock-host check above
does not require `tests/vm/host_candidate.py` or a custom Omarchy checkout.

## Automated checks

```bash
./tests/run                   # requires Qt tools; does not silently skip them
./tests/run --require-omarchy # also requires native Omarchy validation
python3 tests/benchmark.py --rows 10000 --iterations 5
python3 -B tests/benchmark.py --rows 3300 --readmes --readme-chars 24000
python3 -B tests/benchmark.py --rows 10000 --readmes
python3 tests/vm/run.py --check
```

`--python-only` is an explicitly partial developer check, not a release gate.
CI installs Qt tools and runs the portable suite. Native lifecycle evidence is
collected in a disposable stable Omarchy VM, with no personal accounts configured.

## Disposable VM

1. Install the host's QEMU tools and prepare a **stable Omarchy qcow2 base image**
   from the official distribution, verifying its official checksum. Install Qt
   test tools in the guest. Shut it down before using it as a backing image.
2. Run `python3 tests/vm/run.py --base /absolute/omarchy-base.qcow2
   --state-dir /existing/parent/new-run`. Supply `--firmware` if the base uses UEFI.
   The base is read-only; all guest changes go into the retained disposable overlay.
   Keep VM disks, ISOs, sockets and credentials outside the plugin checkout, for
   example in `~/.local/state/omafit-release-vm/`. The VM tools enforce this boundary.
3. In the guest, mount the `omafit` 9p share read-only, then copy it to a writable
   guest checkout. Do not run tests directly on the read-only share.
4. Run `OUTFIT_TEST_VM=1 python3 tests/vm/guest_check.py`. It refuses physical hosts
   and existing fixture installs, uses a harmless fixture, and cleans up that ID.
5. Separately verify interrupted installation/activation, shell restart mid-queue,
   corrupted cache, offline first launch and reconnect, disk-full/read-only state,
   and an external plugin-manager inventory change. Record each observed outcome.
6. After the public source exists, test **Outfit itself** from the exact candidate
   Git revision, including update and removal. A local fixture is not evidence of
   installing the published source. Record SHA, OS/Qt/Python versions and results.

## Fictional UI regression captures

Install the writable checkout in the guest. Run:

```bash
OUTFIT_TEST_VM=1 python3 demo/ui_capture.py --output /existing/output/preview.png
```

The real hosted UI uses committed fictional data. Supported `--scenario` values
are `ready`, `empty`, `offline`, `slow`, `failed-inventory`, `installed`, `disabled`,
`cards` (loaded, missing and failed thumbnails with mixed installation/badge states),
and `density` (eighteen fictional cards across three categories).
Use `--view discover` to override the default Browse view, `--plugin` to inspect a
fictional fixture, or `--surface actions` / `--surface settings` for stock-VM toolbar
captures. `--surface collapsed` verifies Ctrl+F search after collapse; `--surface
expanded` verifies keyboard expansion and collapse. `--narrow` exercises a 760-pixel
window. Toolbar interaction requires `wlrctl` and `wtype` in the disposable guest.
Use `--scenario density --density comfortable|compact|dense|list --grouping none|category`
to select density through the actual icon controls and verify keyboard switching
and persistence. Add `--verify-density-restart` to verify a full shell restart.
List captures also exercise Up/Down navigation and inspector focus restoration.
Use `--sort added|activity|views|copies` to inspect the additional metadata slots.
The harness backs
up shell configuration, retains a recovery marker, uses an unused workspace,
checks fixture identity via IPC and the shell environment, and restores the
normal shell/workspace/cursor. After interruption use `--restore`; ambiguous
recovery state is retained for inspection. Never capture personal notifications.

Review the generated images as regression evidence. Keep these fictional fixture
captures separate from the public README screenshots. A mockup is not evidence
of host integration. Record captured scenarios in release evidence.

## Public screenshots with real data

Root `preview.png` and `docs/screenshots/*.png` show the running production UI
with real marketplace data, not the fixture harness. See
[capture notes](docs/screenshots/README.md) for the current images.

Before replacing them, confirm service status reports `demo: false`, wait for
queries and preview images to settle, and capture only the Outfit window. Review
each image for private information and visual defects, strip image metadata,
and restore the prior view, workspace, and cursor. Update captions and capture
notes together with the images; marketplace counts and installed state are
snapshots, not permanent product claims.

## Interaction matrix

- Narrow laptop and wide desktop; 100%, 150%, 200% scaling; light/dark themes.
- Keyboard-only browse, menus, watchlist, Settings, inspector, and confirmation.
- Last-known/cached data remains visible during local scan and remote refresh.
- Unknown inventory/metrics are labelled pending rather than reported as zero.
- Opening within one minute does not repeat the local scan.
- Inline video starts muted and stops/unloads on switch/Settings/close. Missing
  module and unsupported codec show external fallback without disabling browsing.
- Repeated scrolling/opening/closing reaches a stable resource plateau.
- Diagnostics are readable and contain no personal paths or device names.
- Browse is the first/default tab; explicit Discover choices restore within the session.
- Sidebar counts use parentheses and show unknown values distinctly from zero.
- Routine scan success stays out of the results; manual updates briefly use the header.
- More actions shows compact update ages; Diagnostics retains exact timestamps.
- Filters start expanded; the two-state expand/collapse toggle preserves filters and reclaims grid width.
- The Apps launcher uses the compass icon and summons the existing hosted panel.
- README indexing yields to foreground work, persists progress/backoff, and supports offline search.
- All eight view/grouping combinations preserve thumbnail and text fields, alignment,
  full metric counts, scroll anchors and selection. Check dense cards at narrow widths.
- Density selection survives reopening/restart; rapid changes, save failures and
  unrelated settings acknowledgements cannot revert the latest choice.
- List rows retain unknown/zero metrics, installation and activation states, and
  matching reasons; test narrow status wrapping, no thumbnails and long counts.

## September 16 feature validation

- Host and stable Omarchy 4.0.4 VM: `./tests/run --require-omarchy` passed
  **127 Python tests and 67 Qt checks**, QML parsing and native manifest validation.
- Desktop entry passed `desktop-file-validate`. The VM's
  `tests/vm/launcher_check.py` verified actual Apps search and keyboard launch;
  the captured launcher icon was visually inspected.
- Hosted fictional captures checked expanded and collapsed filters, overlay
  dismissal/pinning, More actions, Settings, and a 760-pixel inspector.
  At 1256×750 the default first card starts around y=153.
- Populated-index benchmark: 3,300 × 24,000-character synthetic documents,
  114.5 ms warm median, 116.9 ms warm maximum, 60,432 KiB sampled RSS.
  10,000 × 12,000-character documents: 272.4 ms median, 274.6 ms maximum,
  103,776 KiB sampled RSS. These are observations, not portable timing guarantees.
- The tested VM product snapshot was `c6e8a0bd91af6d2652f4a355db8291ab5e285d53`;
  this is isolated fixture history, not a publication SHA. The capture harness
  additionally exercised narrow-window resizing from the working checkout.
- Local evidence is retained outside the repository under
  `~/.local/state/omafit-release-vm/cleanup-pass/compact-*.png` and
  `omafit-apps-launcher.png`. The complete scaling/theme and publication matrices
  above remain separate release gates.

## Density validation follow-up

Density follow-up: host and stable VM checks passed **130 Python tests and 74 Qt
checks**. All six density/grouping combinations were captured through the real
icon controls, including arrow-key selection, persisted choice, and a full shell
restart. Dense at 760 pixels and Compact with the inspector were also exercised.
Screenshots are in `~/.local/state/omafit-release-vm/density-pass/density-*.png`.
Scroll-anchor arithmetic, late startup replies, rapid choices and failed saves
are covered by the focused state tests. The VM restart harness waits for the old
fixture PID to exit before starting its replacement.

## List view follow-up evidence

- **131 Python tests and 77 Qt checks** passed on the host and stable VM.
- All eight view/grouping combinations were captured with real icon and arrow-key
  selection. List additionally verified Up/Down navigation, Enter/Escape inspector
  opening and focus restoration, and saved selection after a full shell restart.
- Narrow rows with full ten-digit counts, wide rows with the extra Views metric,
  and text-only rows with listing dates were inspected. Missing/failed previews
  retain the thumbnail frame and compass placeholder.
- Fixture images are retained under
  `~/.local/state/omafit-release-vm/density-pass/list-*.png`.
- A delayed inspector-focus callback was guarded against closed/destroyed panels;
  the repeated keyboard/inspector capture passed after the fix.

## Setup, inbox and lifecycle integration evidence

- Combined app suites passed 206 Python tests and 144 Qt checks before the final
  integration captures. The canonical runtime-command route was tested with real
  subprocess fixtures, including nested helpers and poisoned caller PATH.
- Native VM install/enable/remove baseline: 146/262 samples lost or replaced the
  app or background. Patched host: 224/224 continuous samples. The final real
  Outfit UI batch/uninstall test retained app, wallpaper and bar in 66/66 samples,
  confirmed both installed/enabled outcomes, and reported settled host runtime and
  released batch lease. The temporary repositories were the only command-source
  substitution; native mutation processing and host calls were real.
- A separate 30-second, 12-fps software recording and native lease/expiry checks
  retained all monitored surfaces in 324/324 samples. GPU recording was unsupported
  by llvmpipe; grim PPM capture fed FFmpeg. Sampled evidence cannot exclude events
  shorter than the capture/probe intervals.
- Native input-manager preview, draft application and persistent save passed.
  Inspecting a new match left it unread; explicit review cleared the count.
  The separate full-size preview action was visually inspected below its caption.
- Evidence lives outside the checkout under `~/.local/state/omafit-release-vm/density-pass/`:
  `continuity-native-evidence-20260916/`, `omafit-ui-native-mutation-run4/`,
  `inputs-*.png`, and `preview-action-fixed.png`.

## Standalone uninstall recovery follow-up

- The disposable VM regression `tests/vm/uninstall_recovery_check.py` uses the
  production worker, isolated app stores and a harmless fixture. It closes Outfit
  with its window X, reopens it through the Apps-style summon path and confirms a
  standalone uninstall with no prior batch. No external summons occur after confirmation.
- Packaged-host baseline removed the fixture but left Outfit closed throughout
  a 20.8-second observation. Resetting close suppression alone still failed when
  repeated host reloads discarded an accepted restoration request.
- With bounded acknowledgement retries, the packaged-host fixture was removed
  and Outfit automatically returned 7.43 seconds after confirmation (6.71 seconds
  of observed window absence). This verifies recovery, not uninterrupted continuity.
- The same final candidate on the targeted host retained the same window/PID,
  wallpaper and bar in 94/94 samples. Both runs had zero probe errors and restored
  the original VM runtime, workspace, cursor and byte-identical shell configuration;
  the fixture and recovery marker were removed and no leases remained.
- Evidence: `~/.local/state/omafit-release-vm/density-pass/` directories
  `uninstall-recovery-packaged-retryfix/` and `uninstall-recovery-targeted-retryfix/`.
  Reports bind source hashes to the VM-only candidate commit, with interaction,
  surface and recovery timelines. This is not a publication commit in the source repo.
- Qt regressions cover Apps reopening after a normal close or a finished closed
  batch, pending-batch close suppression, lost accepted requests, stale-token
  rejection, bounded retries and deliberate close during retry backoff.

## Full detail-page prototype review

Accepted product direction: full detail view inside the current window, with a
fictional fixture prototype reviewed before production controls are connected.
Keep the existing plugin ID, kinds, service ownership and native command boundary.

- `ui/PluginDetailPage.qml` has no Service, process, IPC, persistence or browser
  dependency. Its owner supplies metadata/state and handles action signals.
- The normal inspector is retained. A `details` scenario plus the isolated demo
  root enables the new surface; this is not a production rollout or new host feature.
- Dense metrics distinguish GitHub stars, marketplace likes/views/command copies
  from Recommended/Hardware fit. Metrics are never behind a disclosure. Source
  and Marketplace are header actions; management stays visible during body scrolling.
- Fixture states: available, installed, disabled, service, pending, failed, manual,
  full-bar replacement, long metadata/large counts, missing metadata. Artwork and
  all identities/data are fictional. Open, install, enable, position and uninstall
  are simulated in memory; initial pending is held deterministically.
- `./tests/run --require-omarchy` passed **206 Python tests and 201 Qt checks**,
  including 42 detail-page checks for both sizes, pointer/keyboard interaction,
  metrics/disclosures, full-size media, explicit review, lifecycle resets and controls
  remaining reachable while content scrolls. Native manifest and QML parsing passed.
- Hosted VM captures cover all ten states at **1180×760** and **760×540**. Actual
  input exercised simulated Open/dismissal, uninstall Cancel and confirm, disabled
  position preservation, full-size Escape, Back/card reopen and inert pending controls.
  No relevant QML errors; native inventory was unchanged and no fixture plugin was installed.
- Runtime source hashes are in image sidecars under
  `~/.local/state/omafit-release-vm/density-pass/details-prototype-096c5277/`.
  VM-only candidate: `096c5277dc109ca90aa2d6c1d601a329f39953e0`. Captures and reports
  remain outside the checkout. Normal VM shell/workspace/cursor/config were restored,
  with no recovery marker or lease remaining.
- At minimum height some secondary gallery buttons/captions require a short scroll;
  the preview image, metrics and management controls remain visible in the ordinary
  compact fixtures. Exceptionally long names use accessible ellipsis to retain room.

The prototype captures above do not establish native action integration. The
following rollout evidence supersedes the prototype-only deployment boundary.

### Production detail rollout

- Default plugin selection now opens the full page with real metadata, compact
  metrics, validated README media/video and thumbnail fallback, persistent native
  controls, source links, explicit match review and preserved navigation/focus.
- A dedicated bounded Open lane validates authoritative installed capabilities,
  submits only `shell summon <validated-id> {}`, distinguishes accepted/unavailable/
  unconfirmed, and never retries or claims that acceptance proves rendering.
- Full checks passed **218 Python tests / 259 Qt checks** before the final
  media-sizing correction; its focused asynchronous media-growth regression passed
  afterward. The live desktop image was then checked with real marketplace media.
- VM candidate `17cba5f271c0e227e5fd157da36630ad5703221a` demonstrated genuine native
  Open with a harmless declared-panel fixture on packaged and targeted hosts.
  Targeted standalone uninstall retained surfaces in 114/114 samples; packaged
  recovery returned at 6.39 seconds after confirmation. Real batch install/uninstall
  retained surfaces in 79/79 samples, with verified command routing and lease end.
- Evidence: `density-pass/production-detail-targeted-17cba5f2-run3/`,
  `production-detail-packaged-17cba5f2/`, `production-detail-batch-17cba5f2/` under
  the external VM state directory. All fixture/config/runtime recovery checks passed.
- Local source-only rollback snapshot:
  `~/.local/state/omafit-release-vm/omafit-before-live-detail-20260917.tar`
  (Git tree `31501ede171e86330bcc5c3bd132de41355cba6b`; no source commit created).
  It contains code, not personal preferences or cache. Restore the relevant source
  files from that snapshot and reload the shell to undo this rollout; preserve newer
  unrelated work and all user configuration.

Research informing the design:
- https://flathub.org/apps/org.gnome.Extensions
- https://code.visualstudio.com/docs/configure/extensions/extension-marketplace
- https://addons.mozilla.org/en-US/firefox/addon/ublock-origin/
- https://developer.gnome.org/hig/guidelines/adaptive.html
- https://developer.gnome.org/hig/patterns/nav/browsing.html

## Tagged release / marketplace boundary

Before a tagged release or marketplace submission: resolve every high/medium finding, run the VM gates, provide a
root preview, enable private security reporting, document actual compatibility,
create the authorized Git history/origin and obtain green CI. Bind version, tests,
release notes and marketplace submission to the same clean commit. Creating Git
commits, tags, releases or a marketplace issue is a separate owner-authorized step.
