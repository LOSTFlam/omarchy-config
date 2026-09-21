# VM integration evidence — 2026-09-18

## Post-cleanup native smoke — PASS

The cleanup fix was tested in a **new owned guest directory**, `/home/tester/omarchy-upstream-continuity-cleanup`, against the exact handoff hash. The requested single **add → enable → disable → remove** sequence passes with **0 changed surfaces out of 108 samples**, unchanged sentinel tokens/draft, and **no destroy/cleanup errors**. This supersedes the cleanup-warning finding from the historical 0/97 run below.

Source identity was checked before staging and again in the guest before execution:

- Base: `d174d4aa279ea7393d4fad4a80fed147866106b9`.
- Post-fix `shell/shell.qml` SHA-256: **`06eed1563b648fa10ae79fa07cabb71991a5283eb19c97c9d3a1c4a0c5ea3e11`**.
- Handoff patch SHA-256: `fd9c63568b916c1cde208ba317a98e6f54a97971533f30310adbe995fd792224`.
- All **1853 staged source files** still matched their recorded hashes after the run.

| Native action | Exit | Changed surface samples | Panel/draft/widget tokens | Affected widget |
|---|---:|---:|---|---|
| Add | 0 | **0 / 29** | Unchanged | Installed disabled; no live bar item |
| Enable | 0 | **0 / 29** | Unchanged | One visible 40×24 bar item |
| Disable | 0 | **0 / 24** | Unchanged | No live bar item |
| Remove | 0 | **0 / 26** | Unchanged | Inventory, installation and config entry absent |

Before and after every measured action:

| Sentinel | Before | After |
|---|---|---|
| Outfit window / PID | `0x5e419b4d1f80` / `125102` | Same |
| Generic panel window / PID | `0x5e419b2f6c90` / `125102` | Same |
| Bar layer | `0x5e419bed25f0` | Same |
| Background layer | `0x5e419c0a2350` | Same |
| Panel draft | `continuity-marker` | Same |

After every action, `pluginReconcileStatus` was settled with `scanning:false`, `pending:false`, `scanError:""`, and `restartRequired:[]`. `pluginHostCapabilities` still reported `continuity:1`, `sourceRevisions:1`, `batchLeases:0`. Final fixture-state checks all passed: inventory absent, no active widget reported by `debugBarGeometry`, installation absent, config entry absent, discovery settled.

The **entire new shell log, including shutdown**, was inspected. There are no `Property 'destroy'`, TypeError, ReferenceError, stale-component or duplicate-registration messages. The only warnings are the guest's pre-existing Mesa DRI2 and unavailable BlueZ messages; this is a clean **cleanup/QML-error** result, not a claim that every environment warning disappeared.

Native auth was not rerun, as requested. **13 auth-related source/fixture files** match the snapshot with the prior native auth pass, including `AuthServiceStore.js`, both scoped facade implementations, lock/polkit files, and the auth-boundary fixture/script. Their full hashes are recorded in the new `report.json` under `authSourceComparison`. The prior runtime pass remains attributed to its original source snapshot; the new report correctly records `candidateAuthPassed:null` and `authBoundary.rerun:false`.

Evidence: **`/tmp/opencode/outfit-upstream-cleanup-evidence/`**, with matching guest original `/home/tester/outfit-upstream-cleanup-evidence/`:

- `report.json`: `candidateContinuityPassed:true`, `candidateCleanupPassed:true`, no phase failures, before/after tokens, live-widget geometry, final state and restoration.
- `host-source-hashes.json`, `outfit-source-hashes.json`: exact snapshots.
- `candidate/shell.log`: full post-fix shell log.
- `candidate/*-samples.json`, `*-before.png`, `*-after.png`: per-action native measurements and screenshots.
- `candidate/continuity-native.mp4`: software grim→ffmpeg recording, 200 frames / 16.66 s at nominal 12 fps. Its 2-fps `contact-sheet.png` was inspected: Outfit remains present throughout. An incidental startup polkit request was declined before the measured action; no credentials or authorization were supplied.

The run used the already-tested Outfit snapshot solely as the live continuity sentinel. No first-run tests, baseline matrix, auth-runtime repeat, source-replacement sequence or disruptive developer reload were added to this four-action smoke. The larger handoff's replacement/forced-unload cases retain the source agent's local native-Qt evidence rather than being mislabeled as new VM coverage.

Restoration passed: original plugin tree/runtime aliases and private-state hashes, exact shell config bytes, old-ID runtime, new-ID absence, one canonical shell with canonical PATH, no fixture environment variables, no recovery markers and no remaining polkit prompt. Original config SHA-256: `582c3274d150be0360f9380755231159cbd8009a7ee966c80b0b5e2677009d3d`. No live-host or GitHub changes were made. These facts are ready for the host PR-draft/VALIDATION owner to incorporate without relabeling the historical run.

Harness updates are limited to VM tests: candidate-only staging, required handoff hash, unchanged-auth-source comparison, active-widget/final-state assertions, and complete cleanup-log auditing. The post-fix command used `--hosts candidate --skip-auth --previous-host-hashes /home/tester/omarchy-upstream-continuity/vm-source-hashes.json --expect-shell-sha256 06eed1563b648fa10ae79fa07cabb71991a5283eb19c97c9d3a1c4a0c5ea3e11`.

---

## Follow-up: Outfit fixes and pre-cleanup continuity candidate (historical)

**The previously failing Outfit cases passed on this worktree snapshot.** The upstream candidate also preserved continuity across the four requested native actions against its exact-base comparison. Its native fictional auth-boundary test passed. **This pre-cleanup snapshot emitted two cleanup warnings; the separately hash-verified post-fix smoke above resolves that finding.**

The VM was restored between Outfit checks and host checks, and after every host attempt. Final checks confirm the original old-ID registration, original shell config SHA-256, canonical `/home/tester/omarchy-host` runtime, no recovery markers and no remaining polkit prompt. No production Outfit/host files were edited. No source commit, push, PR or GitHub publication was made. The native `add` test creates a fictional Git commit only inside its disposable guest-local fixture repository.

### Outfit regression results

Fresh source copies: `/home/tester/outfit-first-run-6/source` and `outfit-first-run-7/source`. Runtime: packaged Omarchy `4.0.4-1`, Quickshell `0.3.1-1`, Qt `6.11.2-3`. Existing real-backend fixture transport and native inventory reads were retained.

| Previously failing case | Current result |
|---|---|
| Immediate completed-migration rerun | **Pass.** Public old source `6db2b90` migrates; repeat `--apply` returns `already-migrated` while the new service is closed, cache-loaded and `ready:false`, without opening or analyzing the new app. |
| Close/reopen during paced pack download | **Pass.** The download is cancelled, and the second exact artifact request starts **1.884 s after reopening**. Full import finishes at **29.16 s after initial summon**, including the interruption and deliberately paced transfer. No five-minute wait. |
| Initial imported coverage | **3159 / 3464 indexed**, 7 unavailable, 298 pending/excluded, 0 failed, 3166 checked. After one blocked local batch: 3159 indexed, 7 unavailable, 12 failed, 286 awaiting checks. No false completion. |
| Compact Activity popup | **Pass at 760×540.** Popup stays inside the window with an 8-pixel bottom margin. `Tab`, `End` reveals the footer; Return activates **Close details**, closes the popup and retains Outfit. Both cold/resumed and longer offline-error layouts were captured and inspected. |
| Offline seed error after local batch | **Pass.** After the `index-readmes` final JSONL response and 12 failed local checks, `searchPackFailed:true` remains set. Banner, Activity explanation, retry deadline and **Retry search library** control remain visible. |

The first follow-up report sampled the offline state just before the local batch completed. Its screenshot subsequently showed the correct result, but that assertion was marked false. The harness now waits for the actual batch completion rather than a fixed elapsed time; the focused offline-only follow-up is **11 checks passed, no failures**. This was a sampling issue, not a new production failure.

Outfit evidence:

- `/tmp/opencode/outfit-first-run-6-evidence/report.json`, source hashes, native progress JSONL and samples.
- `omarchy-cold-compact-activity.png`, `omarchy-cold-compact-footer.png`, `omarchy-cold-compact-footer-closed.png` in that directory.
- `/tmp/opencode/outfit-first-run-7-evidence/report.json` and `omarchy-offline-transport.jsonl` establish final-response ordering and preserved error state.
- `omarchy-offline-normal-activity.png`, `omarchy-offline-compact-footer.png`, `omarchy-offline-compact-footer-closed.png` in run 7.

Transport remains deliberately paced local artifact bytes, **not real network timing**. Repeated interruptions/failure backoff were covered by the owner's regressions, not expanded into another live VM matrix here.

Current tested Outfit SHA-256 values:

| File | SHA-256 |
|---|---|
| `Service.qml` | `74ac7b87bbe78e69f97ead278914ce498b2613fe1931a4ca9cfc3f73610a0dd7` |
| `scripts/outfit.py` | `75b9b6841a893cdb82a5362e28d48ef77699b34efd2070b14dd90ea146c9287e` |
| `scripts/migrate_identity.py` | `3561110b853eb900f0d712a5fa674bc2f4770748fdb14efc24ebc6b792b6d703` |
| `ui/BackgroundActivity.qml` | `46f9d51dbcd2d949ad4dca5e1f90e9b7efdd5ae970436694792764507b8ecda6` |
| `ui/OutfitApp.qml` | `06d71f05a0efe2c4bdd78499d44c1a3f0ce7da55a06ebc972923cba4e5d004c8` |

### Upstream host: exact-base native comparison

- Host worktree: `/home/ctl/Work/omarchy-outfit-upstream`, uncommitted `plugin-host-continuity` branch.
- Exact base: `d174d4aa279ea7393d4fad4a80fed147866106b9`.
- VM candidate: **`/home/tester/omarchy-upstream-continuity`**, a new owned directory.
- VM baseline: `/home/tester/omarchy-upstream-baseline`, created directly from `git archive` of the same base.
- Scoped process `PATH`/`OMARCHY_PATH` selected each shell; `/home/tester/omarchy-host`, system configuration and installed package files were not overwritten. No dev link or reboot.
- All **1853 candidate source files** were hash-verified unchanged after the native run.
- Current compiled new-ID Outfit frontend/backend was used with isolated disabled-network preferences, alongside an ordinary fictional panel and a widget birth-token probe.
- Native single actions: **add → enable → disable → remove** of `org.example.omafit-release-fixture`. There was one completed four-action matrix per host. Sentinels were reopened only **between** baseline operations, never during measurements.

The actual documented discovery method is **`pluginReconcileStatus`**, not `pluginDiscoveryStatus`. Candidate responses:

```json
{"version":1,"continuity":1,"sourceRevisions":1,"batchLeases":0}
{"version":1,"scanning":false,"pending":false,"scanError":"","restartRequired":[]}
```

The first response is `pluginHostCapabilities`; the second is `pluginReconcileStatus` after settlement. The exact baseline has neither method. No `pluginLifecycle`, lease, batch-success or transaction API was required or simulated.

| Native action | Baseline changed surface samples | Candidate changed surface samples | Baseline widget token | Candidate panel/draft/widget tokens |
|---|---:|---:|---|---|
| Add | 31 / 34 | **0 / 26** | Recreated | Unchanged |
| Enable | 0 / 25 | **0 / 26** | Recreated | Unchanged |
| Disable | 0 / 25 | **0 / 22** | Recreated | Unchanged |
| Remove | 30 / 32 | **0 / 23** | Recreated | Unchanged |

Candidate result: **4/4 actions preserve all sentinels, 0 changed samples out of 97**. All native commands exit 0 and observed inventory reaches the requested enabled/disabled/absent state. Before and after **every** candidate action:

| Surface | Before | After |
|---|---|---|
| Outfit window address / PID | `0x5e419b2f6c90` / `121598` | Same |
| Generic panel window address / PID | `0x5e419a3a8a20` / `121598` | Same |
| Bar layer address | `0x5e419bf1b710` | Same |
| Background layer address | `0x5e419b104950` | Same |
| Panel draft | `continuity-marker` | Same |

Baseline: only **2/4 actions** preserve window/background surfaces; add/remove close both windows and replace the background. The generic widget is recreated on **all four** actions. Raw before/after token strings and addresses are in `report.json`.

### Host warning for the owning agent

The candidate's four-action run logs this twice:

```text
@shell.qml[1550:-1]: TypeError: Property 'destroy' of object TypeError: Type error is not a function
```

The line is in `syncPluginWidgets()`'s no-longer-seen cleanup branch:

```qml
if (pluginWidgetComponents[id].component) pluginWidgetComponents[id].component.destroy()
```

Evidence: `candidate/shell.log`, lines 13–14, under the final continuity evidence directory. The exact-base log does not contain this warning. It did not prevent the requested inventory outcomes or unrelated-instance continuity, and `scanError` remained empty. Its resource-cleanup implications were not established by this narrow matrix. **Host agent should investigate the component lifetime/cleanup path; host source was not modified here.**

### Native authentication-boundary check

The existing `test/shell.d/plugin-auth-boundary-test.sh` was inspected first: it creates a separate QML fixture, a temporary HOME/config/cache/state, fictional service objects and callbacks, and cleans up its process. It does not call the real lock/login authentication flow.

The first invocation stopped before runtime because the scoped test PATH omitted Node's mise shim. A focused rerun with canonical PATH plus the candidate prefix passed **all 13 emitted checks**, including:

```text
ok - plugin authentication boundary runtime behavior
```

`candidate/auth-standalone.json`: exit 0, `nativeRuntimePassed:true`, `runtimeSkipped:false`, `configBytesUnchanged:true`. This proves the documented fictional runtime facade/private-store assertions, not PAM or login/session-lock behavior.

### Host evidence, visual scope and restoration

Final evidence root: **`/tmp/opencode/outfit-upstream-continuity-evidence-2/`** (matching guest original at `/home/tester/outfit-upstream-continuity-evidence-2/`).

- `report.json`: all eight native operations, before/after addresses/PIDs/tokens, sample counts, observed capabilities and restoration.
- `host-source-hashes.json`, `outfit-source-hashes.json`: exact snapshots.
- `baseline/` and `candidate/`: per-action before/after full-screen PNGs, sampled surface JSON, shell logs and `continuity-native.mp4`.
- Videos are software `grim` PPM → ffmpeg recordings, nominal 12 fps: baseline 221 frames / 18.42 s; candidate 181 frames / 15.06 s. Filenames retain the older recorder helper's naming and do not imply hardware encoding.
- `contact-sheet.png` in each directory was extracted at 2 fps and visually inspected. Baseline shows the app disappearing and background interruption; candidate retains the app throughout.
- A network-control polkit prompt from startup is present in both recordings. No password was entered or authorization granted. It limits visual/focus claims: the generic panel is primarily established by its mapped window/address and token/draft evidence, not an unobscured visual presentation. The final original runtime has **no polkit prompt**. This was not the isolated auth-boundary fixture.
- Early setup-only attempts used a plain Qt `Window` nested under the panel item, which did not map. Switching the **test fixture only** to Quickshell `FloatingWindow` resolved that. Those attempts performed no native plugin mutations and are not host failures.
- The raw combined report retains the initial auth PATH failure. The standalone auth JSON/log is the completed runtime result; do not misread the historical `candidateAuthPassed:false` in that raw report as the final result.

Key host SHA-256 values:

| File | SHA-256 |
|---|---|
| `shell/shell.qml` | `59414fbea711f9c33f56c685b9d0074957c0c31f976c27e782d25f69d1d0ed55` |
| `shell/services/PluginRegistry.qml` | `cbfa4bbf90e84e48e98cfd31c871438655c5e998949c5b4bbda497e41a49dff5` |
| `shell/services/BarWidgetRegistry.qml` | `02e77a8cb1493a12eaa53cf407b4c6f72b7a398d032c241d28619944e7bc3bcb` |
| `shell/plugins/bar/Bar.qml` | `c6f7b70c2d97355fb02a4e563ee029e5222661c0c6d22f472595ddf1fce6c170` |
| `shell/services/plugin-scan.py` | `d790aa3d38e15adbc3b42a0511887998a306b1fc79843840dd782f8348f30045` |
| `shell/Commons/KeyedModel.js` | `8b43a29fcf602c069e34bcc380484a91403e97f20ed17cedba9e2aaa0810b0a2` |

Harness additions are confined to `tests/vm/`: `upstream_stage.py`, `upstream_continuity_check.py`, and `continuity-probe/`. `first_run_check.py --regressions` selects the focused Outfit cases. `upstream_continuity_check.py --auth-only` reruns only the isolated native auth test against an existing evidence directory. External PR drafts/review files were left for main to update from these facts.

---

## Original verification — historical outcome (superseded above)

Integration was exercised only in the existing density-pass disposable VM.
**Three release-blocking behavior/layout defects remain**, plus an offline-status
presentation issue described below. Production fixes are left to the main agent.

The original guest registration, source candidate, configuration, preferences,
cache, launchers, cursor/workspace and canonical development-host runtime were
restored after every run. Snapshot file hashes/modes were checked before the
original runtime resumed. There are no remaining recovery markers. The host's
actual `/home/ctl/Work/outfit` installation was not used or changed. No commits,
GitHub publication, dev-link change, package installation or reboot occurred.

## Confirmed production defects

### 1. Interrupted cold pack preparation does not resume

Reproduction: open a fresh fixture, allow >400 KiB of pack progress, close Outfit,
then reopen it. The native process is cancelled, but the new prepare worker
returns success without requesting the asset again. After 100 seconds the pack
state remains `none`, `due:false`, indexed documents remain zero, and local
upstream checks have started instead. The reopened startup banner is hidden.

Confirmed on both the development shell and packaged shell; the final focused
reproduction is `outfit-first-run-5` on packaged Omarchy.

- `scripts/outfit.py:3441` persists `nextCheckAt = now + 300` before download.
- `prepare_search()` returns immediately when that receipt is not due.
- `Service.qml:239` resets the cancelled frontend attempt, but the next backend
  invocation still encounters the persisted retry gate.
- `Service.qml:255` then marks that no-op result settled.

Evidence: `/tmp/opencode/outfit-first-run-5-evidence/`

- `report.json`: `omarchy-cold-resume`, final receipt and indexed counts.
- `omarchy-cold-transport.jsonl`: exactly one manifest/asset pair; generation 2
  returns `search-prepared`, `ok:true`, with no second pack request.
- `omarchy-cold-resume-stalled.png`.

Fix direction: distinguish interrupted/in-progress preparation from a completed
check or genuine failure backoff. Reopening should reattempt unfinished work.
Explicit Retry also passes through the same due gate and deserves a regression
check when this is fixed.

### 2. Completed migration is not immediately idempotent

The exact public `6db2b90` old-ID runtime migrates successfully. After the new
service has loaded its cache and stopped its query worker, leave its panel closed
and repeat `--apply --source NEW_SOURCE`. It exits 1 with:

> Save/discard drafts, finish pending work, close Outfit, then retry.

Actual state: `opened:false`, `queryBusy:false`, `backgroundBusy:false`,
`canBrowse:true`, no dirty draft/batch, but `ready:false`. The service has not yet
performed hardware analysis. Opening the new UI, waiting for analysis, closing it
and repeating the command returns `already-migrated` and preserves config bytes.

- `scripts/migrate_identity.py:254`: `idle()` requires `ready:true`.
- `_apply()` calls `plan()`/`idle()` before its already-migrated fast path.
- `Service.qml:3742`: `ready` includes `hasAnalyzed`, unrelated to safe idempotent
  registration verification for a closed service.

Evidence: run 5 `report.json`, `migrationClosedSettled`,
`migration-immediate-rerun-idempotent`, and `migration-rerun-idempotent`.

Fix direction: use actual pending-work/draft/operation state for migration idle
checks. A completed migration should not require opening Outfit or running an
optional hardware check merely to return `already-migrated`.

### 3. Activity popup is clipped at 760 × 540

At 1180 × 760 the popup fits. At 760 × 540 it starts around y=80 but extends below
the bottom of the window: lower explanatory content and/or **Close details** are
clipped. Escape dismisses the popup and retains the application, so there is a
usable keyboard escape route, but the requested compact fit fails.

- `ui/BackgroundActivity.qml:14` allows `window.height - 32` without subtracting
  the popup's actual top offset.
- `ui/OutfitApp.qml:4403` positions it below the header.

Evidence:

- `/tmp/opencode/outfit-first-run-3-evidence/omarchy-cold-compact-activity.png`
- `/tmp/opencode/outfit-first-run-3-evidence/omarchy-offline-compact-activity.png`
- Run 4 repeats the compact cold capture and confirms Escape retains the app.

Fix direction: constrain the scroll viewport to the available space below the
popup's mapped window position, or reposition the popup within window bounds.

### Offline status loses the seed failure after local indexing

The fresh offline seed initially reports an error correctly. After the local
index batch finishes with failed upstream reads, `searchPack.state` remains
`error` but the documentation lane becomes `waiting`. Its retry button/error
description disappear and the banner says “catalog search is ready.” Coverage
still says “12 will retry,” so counts remain honest, but the failed seed is no
longer clearly explained in Activity.

`Service.qml:395` replaces lane state using only the latest index result, dropping
the seed error. Evidence: run 3 `omarchy-offline-normal-activity.png` and
`omarchy-offline-final` in `report.json`. Corruption has a clear initial error;
`omarchy-corrupt-normal-activity.png` captures it before local fallback overwrites
that lane state. Consider retaining seed status/retry information independently
from local indexing status.

## Passed checks

| Area | Evidence/result |
|---|---|
| Native validation | Candidate new-ID manifest accepted by the guest validator. |
| Actual public migration | `0.1.0`, `6db2b90ec980095404d4b004884c070d12e342e9` → `io.github.ctl0v0.outfit` `0.2.0`. |
| Dry run | Shell config bytes unchanged; no new registration created. |
| Registration | Exactly one Outfit registration, under the new ID; old source archived byte-for-byte. |
| Private state | Preferences, interests and quick-setup journal bytes preserved; new files mode 0600. |
| Public cache | Catalog bytes preserved. Run 5 uses the old backend's real README schema, not an arbitrary SQLite file. |
| WAL | A committed row and an indexed fictional document stored in a live WAL survive migration. `walonlyfixture` remains searchable in the migrated database. |
| Data allowlist | Fictional raw hardware file excluded. |
| Launcher/icon | Exact new desktop asset and new icon path present; legacy desktop file removed. |
| Idempotence after readiness | `already-migrated`; shell config bytes unchanged. See closed-service defect above. |
| Cold catalog | All 3466 bundled listings available before opening; no modal onboarding block. |
| Independent inventory | Genuine native read-only inventory confirmed management capability before the delayed hardware fixture finishes. No third-party plugin mutation. |
| Native worker protocol | Production `BackgroundWorker.qml` and native Quickshell `SplitParser` process real backend JSONL progress/final responses. |
| Full import | All 7,662,590 compressed bytes read and validated; 3464 document records imported. |
| Coverage | 3159 indexed, 7 unavailable, 298 seed-excluded; not falsely “Library prepared.” After one local batch: 3159 indexed, 7 unavailable, 12 failed, 286 awaiting checks. |
| Continued local checks | An `index-readmes` batch runs after the seed. The network blocker makes the 12 attempted documents fail predictably; workers then settle without a perpetual spinner. |
| Actual UI search | Native Ctrl+F `oauth` returns **108 plugins**. Independent production-backend query against the same generated VM cache returns 108 with documents versus **2 metadata-only**, with README match reasons/snippets. |
| Disabled preference | No pack manifest or asset request. |
| Fresh offline | Bundled catalog stays browsable; seed fails with retained local search. See settled-status presentation issue above. |
| Corrupted artifact | Altered final compressed byte rejected; zero documents imported and catalog retained; clear initial error. |
| Popup dismissal | Escape retains the app at normal and compact sizes. |

## Timing and transport scope

Final uninterrupted packaged-host run (`outfit-first-run-4`), first observed
relative to summon:

| Observation | Seconds |
|---|---:|
| Browsable catalog | 0.647 (already available before summon) |
| Authoritative inventory / management | 0.828 |
| First sampled byte progress | 3.052 |
| Delayed fictional hardware complete | 21.675 |
| Imported receipt visible | 24.508 |

The transport fixture intentionally sleeps 120 ms per 64 KiB read. Its measured
14.10-second byte transfer is **not real network performance**. Real production
validation/staging/commit took about 7.31 seconds in this VM, from first import
progress to commit. JSONL reports progress every 100 imported records and a final
3464/3464 commit. The native UI sample stream and screenshot show measured bars.

Artifact: `search-pack-20260918T183520Z.jsonl.gz`, SHA-256
`76395fa67d7fa2a13cfd8236e671d12d157c390caccab828a15ce57d4a53923a`.
Only the production fixed manifest URL and that manifest's exact asset URL are
served. All other public requests fail locally. No user cache seeds the test.
Actual published GitHub/CDN transport, redirects and real network timing remain
for the post-publication smoke test.

## Environment and source evidence

- Existing guest: `/home/ctl/.local/state/omafit-release-vm/density-pass`, tester,
  SSH 22222; credentials are read by the existing harness and never logged.
- Guest packages: Omarchy `4.0.4-1`, Quickshell `0.3.1-1`, Qt base `6.11.2-3`.
- Display restored: Virtual-1, 1280 × 800, scale 1.
- Canonical runtime restored: `/home/tester/omarchy-host`; old-ID IPC present,
  new-ID IPC returns `Target not found.`
- Final restoration uses the native guest restart command to launch from
  Hyprland's canonical environment. Verified one shell process, canonical PATH,
  no `OUTFIT_*`/`OMAFIT_*` fixture variables, and no recovery markers.
- Guest shell config SHA-256 restored:
  `582c3274d150be0360f9380755231159cbd8009a7ee966c80b0b5e2677009d3d`.
- Development shell checkout has no usable Git metadata. Its `shell/shell.qml`
  SHA-256 is `e6e0713b53eda7a8251da5b7e9b0d1dfb90c3011389e67b8360c16c844e44ccd`;
  packaged shell SHA-256 is
  `4a4b7694e5b9e0bd952ce0efa2d6dc2cea44cdfa98cc2f442e40fe41cbc1beab`.

All copied source hashes are in each later run's `source-hashes.json`. Key tested
production hashes:

| File | SHA-256 |
|---|---|
| `Service.qml` | `497ec35d8b95a3dea594cf717e6c9d78ace5daa0d584c04aae2f81fb74c048ac` |
| `BackgroundWorker.qml` | `898f26f6ea909a69f6c8f2db493cf6da61977c86abe8bb2960c0188defd9831e` |
| `scripts/outfit.py` | `167be80861fb7a62541b8ff84e396e0986eb354f746b85019fc8d574b9494583` |
| `scripts/migrate_identity.py` | `e752a7c7b1dd167c775bb52b3749f7c8fad495313095701fa436e9630ae84746` |
| `ui/BackgroundActivity.qml` | `d3d85866fbe0a45c0276584597ad81f0fd3d27169813d755f4eeaed9a0cd7c35` |
| `ui/OutfitApp.qml` | `15de3cbb84fffe4c0a1d69566431b6b9cc2b24bd3ddee43f2dafcdd858056b73` |

The cold harness copies its controlled worker over **only the disposable copy's
`demo/fixture_worker.py`**, using the existing demo helper-path seam. QML,
`scripts/outfit.py`, worker process mechanics, stores, importer and ranking stay
production code. Hardware is a deterministic 20-second empty fictional scan;
native inventory is real read-only IPC. Migration uses the unmodified public old
source and unmodified new source, synthetic data and locally blocked HTTP proxies.

## Evidence locations and harness caveats

- `/tmp/opencode/outfit-first-run-2-evidence`: development + packaged full imports.
- `/tmp/opencode/outfit-first-run-3-evidence`: corrected migration, disabled,
  offline/corruption scenarios, normal/compact screenshots.
- `/tmp/opencode/outfit-first-run-4-evidence`: final native search/progress images,
  raw JSONL, sample timings, and `omarchy-cold-search-supplement.json`.
- `/tmp/opencode/outfit-first-run-5-evidence`: final valid-schema/WAL migration and
  focused cancellation/resume reproduction. No phase/harness exceptions.
- Matching originals remain under `/home/tester/outfit-first-run[-N]/evidence` in
  the disposable guest. Synthetic test state and migration backups remain outside
  installed/configured plugin discovery.

Raw reports deliberately retain early harness failures. Run 1 compared private
file modes as well as bytes and used an incomplete synthetic interests document;
both were corrected. Runs 2–3 used a search term absent from the artifact; run 4
corrects it. Run 4's extra logger assertion looked for an internal `searchEvidence`
field that is not in public setup rows; the logger now reads `searchReason` and
`searchSnippet`, and the search supplement proves 106 additional document-derived
results. Those historical assertions are **not production search/migration data
loss defects**. Earlier reports returned shell exit 0 even with failed assertions;
the current runner returns nonzero when any check/phase fails.

## Re-run

Stage into a new guest directory using `first_run_stage.py`, then invoke
`first_run_check.py` through the existing `session_exec.py` with
`OUTFIT_TEST_VM=1`. Options select `--only migration|cold|all`,
`--host stock|dev|both`, `--scenarios cold disabled offline corrupt`, and
`--resume-check` for the interruption case. `--restore` uses a surviving recovery
marker if interrupted. `first_run_search_check.py` accepts only an already
generated, marked VM fixture; it never reads the installed user's cache.
