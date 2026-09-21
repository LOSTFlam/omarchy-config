# Plugin updates: disposable VM validation

## Final candidate verification — 2026-09-19 UTC

**The two observed production defects are fixed.** The hosted follow-up below
establishes genuine individual and sequential batch updates through the production
backend/native CLI. The first session establishes native rollback and the real
independent self-update worker across source replacement and shell restart.

After the second session, `resetSetupBatch()` was corrected to retain
`setupSelection` when `batchKind` is `update`. The new production-owner regression
`UpdatesUi::test_leaving_update_progress_keeps_pending_install_selection` clicks
the actual **Back to Updates** control and verifies both preservation and the
unchanged install-reset behavior. This final one-line state fix was verified in
QtTest; the native update/restart matrix was not repeated.

Final focused QtTest runs: **PluginUpdates 7/7**, **UpdatesUi 21/21**,
**ServiceLifecycle 34/34**. They also cover oldest-cache expiry on reopen and
available-first ordering. Before the final targeted fixes, the required aggregate
runner passed **451 Python tests** (one skipped) and **676 QML checks**, with
native manifest validation. Final portable/native validators and `git diff --check`
pass. Production update APIs were additionally exercised read-only against the
real public Radio Atlas repository using an isolated cache: installed and remote
`0.1.9`, matching HEAD `b290c29c1a9bfd1a0296f05fe995e1cd4e6e6ccd`, state `current`,
authoritative inventory, and no error. No physical-host plugin was updated.

The historical hashes and failures below identify their own exact test snapshots;
they do not imply the later state/reset and ordering changes were live-tested in
the same VM session. The running VM was fully restored after both sessions.

### Local integration smoke

The tested runtime was applied to the project checkout and its separate clean
installed checkout after confirming no unsaved interests or active batch. Outfit
was reopened on **Updates** after a shell restart. All eight installed runtime
files matched the candidate byte-for-byte. Live IPC reported authoritative
inventory, a completed update check, **8 available updates**, no running batch,
and an idle self-update worker. Some other plugins had unavailable checks and
were reported as such; no ordinary plugin update was initiated. The installed
Outfit copy now contains local development changes, so its own update is blocked
until those changes are reconciled with a published build.

## Hosted follow-up findings (before final selection fix), 2026-09-19 UTC

**The inventory-schema fix passes genuine hosted update execution. A newly
observed selection-preservation defect remains:** clicking **Back to Updates**
after a completed update batch clears the user's pending **install** selection.

The previous confirmation rejection and missing installed SHA are **fixed** in
this candidate. Individual and two-item batch confirmations successfully drove
the unchanged production Service/backend/native updater, with verified results
and updated versions in the UI. Separate self-update confirmation dispatched its
own action through the actual Service, with only that action's backend result
stubbed. No real self-restart or rollback suite was repeated.

### Follow-up candidate scope and hashes

Source worktree and base commit are unchanged from the first run below. Of the
previously staged files, exactly these three changed before this follow-up:

| File | Follow-up SHA-256 |
| --- | --- |
| `ui/OutfitApp.qml` | `955097e3aec0ce2e69885d665ef2ab0e69cb29ac574012a4d7fe2f4319121315` |
| `ui/InspectorState.js` | `a62cb29b95826d3d372581b2cedb011aae8c0b7402bdd2832b1d97cf51ef5300` |
| `tests/qml/tst_updates_ui.qml` | `2d30def27692ed935a5194e82d811be076f687ae15fc046468bcab8152425f55` |

`Service.qml`, `scripts/outfit.py`, `scripts/self_update.py`, `BackgroundWorker.qml`,
`UpdatesPage.qml`, and `PluginDetailPage.qml` retain their exact first-run hashes
listed below. In particular, the backend remains
`99b3f3d67595221ecf641f1d99562952ba673c1a6902a04066e754c2615f0c47`, and Service
remains `9ff4b634c84c4dbb02219b0f2d2b7c0a74f373d663c9c06f192f4fadc3691652`.
Completion audit found no source drift, excluding this owned results document.

The host remains Omarchy **4.0.4-1**, Quickshell **0.3.1-1**, canonical patched
`/home/tester/omarchy-host`; its native updater hash is unchanged.

### Follow-up observations

1. **Individual confirmation — PASS, genuine end to end.**
   - The installed SHA now appears in details beside the installed version.
   - Opening review sent no mutation. Activating its confirmation sent one
     `update-plugin` request with both exact reviewed revision fields.
   - Production `execute_plugin_update()` called the real canonical native CLI.
   - The response had `ok: true`, `status: completed`, `verified: true`,
     `observed: true`, and no error.
   - The detail changed from installed `1.0.0` to `2.0.0` and the matching new SHA,
     then settled to **Up to date**. The pending install selection remained at 1.

2. **Update-all execution — PASS, genuine end to end.**
   - A new fixture-one v3 commit made two ordinary updates available again.
   - The actual UI reviewed **2** rows; Outfit remained excluded.
   - Confirmation used the production Service batch state machine, issuing two
     `update-plugin` requests with `batchItem: true` and generations 2 and 3.
   - Request/response monotonic timestamps prove the first final response
     preceded dispatch of the second request. Both real native updates verified.
   - At 760×540, progress visibly advanced from one running/one waiting to
     **BATCH UPDATE COMPLETE — 2 of 2 processed**, with both rows **UPDATED**.
   - Both journal items completed with `attempts: 0`; host lifecycle became
     `settled`, `runtimeReady: true`, `endConfirmed: true`, without load errors.
   - Enabled/disabled states and left placement were preserved; shell config
     bytes remained unchanged across all three updates.

3. **Selection after leaving completed progress — FAIL, new production issue.**
   - A pending `example.install-later` selection was restored from the private
     fixture journal before testing and owned by the real Service throughout.
   - `batch-result.json`: `batchSelected: 1`, selection still present at batch
     completion.
   - Clicking the visible **Back to Updates** button produced
     `batch-settled.json`: `batchSelected: 0`, journal `selection: []`, before
     the subsequent self-update test.
   - `ui/OutfitApp.qml:7678–7681` calls `service.resetSetupBatch()` for both
     batch kinds. `Service.qml:2926` unconditionally clears `setupSelection`.
   - The required preservation therefore holds during execution, but fails
     when dismissing completed update progress. Reported to the parent;
     production was not edited.

4. **Separate Outfit confirmation — PASS, intentionally stubbed execution.**
   - Review caused no dispatch. Confirmation sent exactly one `self-update`
     action with `expectedInstalledRevision: 1111111111111111111111111111111111111111`
     and `expectedRevision: 2222222222222222222222222222222222222222`.
   - Actual `Service.beginSelfUpdate()` and its BackgroundWorker consumed a
     controlled completed response. No ordinary Outfit `update-plugin` request
     occurred; shell PID remained unchanged. The prior real-worker pass below
     supplies the independent restart/source-replacement evidence.

5. **Idle/cache settlement — PASS except the selection assertion above.**
   - Eight one-second samples had `updatesBusy`, `batchRunning`, and
     `selfUpdateBusy` all false.
   - Mutation request count stayed exactly four: three ordinary updates plus
     one separate self action. No replay or retry occurred.
   - Both ordinary update records and the production update cache were
     `current`, with equal installed/available SHAs; Update-all became **(0)**.

The group recorded **30 passing checks, no failed group checks, and no harness
errors**. The independent final idle/cache probe recorded **5 passes and the
1 selection-preservation failure**; its nonzero exit is intentional failure
evidence, not an overall pass.

### Exact revisions sent by the hosted UI

| Dispatch | Fixture | `expectedInstalledRevision` | `expectedRevision` |
| --- | --- | --- | --- |
| Individual, generation 1 | `org.example.outfit-update-one`, 1.0.0 → 2.0.0 | `a55628666002d2d3cdc0048cb119cd0296586e55` | `764412f547346f2b5804f6008ce9297c38c71fe1` |
| Batch, generation 2 | `org.example.outfit-update-one`, 2.0.0 → 3.0.0 | `764412f547346f2b5804f6008ce9297c38c71fe1` | `e9931ffea6cd9267c2d97f38e7c4a3b5ada3999c` |
| Batch, generation 3 | `org.example.outfit-update-two`, 1.0.0 → 2.0.0 | `c40ab4a945fb50b4c4ec1c89f0a73a6241980c22` | `bea3e1ccfb5d75567c84b838753b8e57044cccfc` |

All three resulting installed HEADs, manifests, backend operation receipts and
UI versions matched the expected targets. Native launch audit contains exactly
three canonical `omarchy plugin update <fixture-id> --yes` invocations.

### Follow-up real versus fixture boundaries

- Exact candidate QML, Service, BackgroundWorker and backend source bytes;
  no injected QML methods or replacement Service mutation methods.
- Real ordinary inventory obtained through native commands, retaining the
  production `installedRevision` field. Inventory presentation was limited to
  the two reserved fixture IDs and Outfit; only Outfit's version/SHA was fictional
  for its separate dispatch test.
- Real production source inspection, update-cache binding, validation,
  generation handling, progress/final protocol, native mutation, verification,
  reconciliation and batch scheduling.
- Only network discovery/content and native Git transport redirected to the
  controlled local Git repositories. Remote HEAD, manifest and ancestry
  evidence were derived from those actual repositories. Update outcomes were
  **not** mocked for either ordinary fixture.
- Catalog/profile/optional network work used isolated fictional inputs; unrelated
  network was blocked. Separate self-update result alone was stubbed.
- Both initial fixture checkouts were created locally at v1 as setup; backend
  commands were guarded to allow mutation only for `update-plugin` on those IDs.

### Follow-up evidence, commands and restoration

Evidence root: **`/tmp/opencode/outfit-updates-followup-evidence/`**.
Guest scratch root: `/home/tester/outfit-updates-followup/`.

- `followup-summary.json`: candidate hash delta, no drift, assertions and exact
  native argv.
- `source-hashes.json`: complete follow-up source snapshot.
- `evidence/protocol.jsonl`: ordered requests, progress/final responses and native
  launch audit, with no environment or lifecycle tokens logged.
- `evidence/single-result.json`, `single-settled.json`, `batch-result.json`:
  genuine update outcomes and Service/journal state.
- `evidence/batch-settled.json`: **new selection-loss evidence** immediately after
  Back to Updates, before the self stub.
- `evidence/idle-cache-proof.json`: settled cache/no retries, plus failed
  post-return selection assertion.
- `evidence/report.json`, `final-restoration.json`, `finished`: restoration and
  run state.

Reviewed captures under `evidence/`:

- `02-fixed-detail-before.png`: installed SHA now present, 1180×760.
- `03-single-review.png`, `05-single-settled.png`: confirmation and actual
  installed v2/up-to-date result.
- `07-batch-review.png`: compact review contains only two ordinary rows.
- `08-batch-running.png`, `09-batch-complete.png`: actual sequential progress
  and two verified successes at 760×540.
- `10-batch-settled-updates.png`: Update-all (0), only separate Outfit remains.
- `11-self-separate-review.png`, `12-self-dispatch-stub-complete.png`: separate
  confirmation and explicit no-restart fixture response.
- `13-disabled-fixture-updated-detail.png`: updated SHA/version while disabled.

The existing transfer/mailbox/capture/backup/restoration harness was reused at
a fresh scratch root, with one restoration-owning group:

```sh
python3 /tmp/opencode/outfit-update-followup-stage.py stage
python3 /tmp/opencode/outfit-update-followup-stage.py send '<interaction JSON>'
python3 /tmp/opencode/outfit-update-followup-stage.py sync
python3 tests/vm/ssh_guest.py \
  --work /home/ctl/.local/state/omafit-release-vm/density-pass -- \
  env OUTFIT_TEST_VM=1 python3 /home/tester/outfit/tests/vm/session_exec.py \
  python3 /home/tester/outfit-updates-followup/outfit-update-followup-idle.py
python3 /tmp/opencode/outfit-update-followup-stage.py send '{"action":"finish"}'
python3 /tmp/opencode/outfit-update-followup-stage.py get
python3 /tmp/opencode/outfit-update-followup-audit.py
```

The group restored both current/legacy source registrations and private
config/cache paths with hash/mode checks, the original runtime, and exact shell
configuration bytes. It removed both fixtures with the native CLI and restored
the saved workspace/cursor. Independent post-restoration verification confirmed
no recovery marker, no fixture IDs, an inactive self-worker, and original legacy
Outfit IPC. Shell-config SHA-256 again matched
`582c3274d150be0360f9380755231159cbd8009a7ee966c80b0b5e2677009d3d`.

No production edits, source commits/pushes, physical-host changes, full suite,
rollback repetition, or real self-restart repetition were performed. This
follow-up does not claim public network transport or a fixed selection-reset
path. The parent-owned focused QML tests were not duplicated.

---

## Historical first-run verdict — schema defect subsequently fixed

**BLOCKED for end-to-end UI release:** update confirmation reads the wrong
inventory revision field. Genuine native updates and rollback passed. The exact
production self-update worker passed a real user-systemd / native-update /
shell-restart / reopen transaction, including replacement of its source files.

Run completed on **2026-09-19 UTC** (the VM clock), using the existing
`density-pass` VM. All guest changes were restored by the session group's
`finally` block. No production files were edited in the source worktree.

## Historical schema defect — fixed in the follow-up above

In the tested candidate:

- `scripts/outfit.py:2531–2557` normalizes inventory to `installedRevision`.
- `Service.qml:1990–1995` returns that inventory row unchanged.
- `ui/OutfitApp.qml:616` instead compares `entry.revision` with the reviewed
  update's `installedRevision`.
- `ui/InspectorState.js:88` also reads `entry.revision` for the installed SHA.

**Observed:** open an available installed plugin, choose Update, then activate
the confirmation's Update button. The review remains open with:

> Plugin versions or availability changed. Cancel and review the current updates before continuing.

The input records had matching installed/available versions and valid full
40-character revisions, with `installedRevision` present and `revision` absent,
matching production backend inventory. No mutation request reached the helper.
The same shared confirmation guard covers single, Update-all, and self-update
confirmation; the single-plugin rejection was exercised live. Details show the
installed version but omit its SHA, while showing the available version/SHA.

Evidence:

- `19-after-fixture-confirmation.png`: visible rejection at 760×540.
- `fixture-update-response.json`: exact fictional response, normalized by the
  production inventory validator.
- `self-update-report.json`: real native inventory independently demonstrates
  the `installedRevision` field.
- `pre-confirmation-audit.json` and `all-ui-protocol-actions.json`: no
  `update-plugin` or `self-update` dispatch before confirmation, after review
  cancellation, or after the rejected confirmation.

Production was left untouched by the validation agent. The parent subsequently
corrected this field; the focused follow-up above verifies successful hosted
confirmation through the real backend/native updater.

## Candidate and host identity

Source: `/home/ctl/Work/outfit-updates`, dirty/uncommitted candidate based on
`761a9fd304c03fb62c1e79ab212f57db1fd7dd7b`.

170 staged source files were hashed before transfer. At completion, all 170
still matched the source worktree (`source-audit.json`: `candidateDrift: {}`).
This report is the only checkout file added by this validation.

| Candidate file | SHA-256 of tested bytes |
| --- | --- |
| `BackgroundWorker.qml` | `b703ac86c512e79f753ff87a7032c3cdf522555caa58e38f61010f298906edad` |
| `Service.qml` | `9ff4b634c84c4dbb02219b0f2d2b7c0a74f373d663c9c06f192f4fadc3691652` |
| `scripts/outfit.py` | `99b3f3d67595221ecf641f1d99562952ba673c1a6902a04066e754c2615f0c47` |
| `scripts/self_update.py` | `7972a56353858301f89d60e09ba1bdc9e4d5e8890b93829cdeabe1516642e9f4` |
| `ui/InspectorState.js` | `cbb52e4a49ceb31f07de760978233c8f4609b93a669aace177fe67eaaef21ed9` |
| `ui/OutfitApp.qml` | `c69c471f6f28ac677445ea74489a9e11a5f762d06dc4d732af46efa591ea239c` |
| `ui/PluginDetailPage.qml` | `29c350685dd2aacc13e66c32d3920b3ac5216426fa401f87d05c157a2aef72b3` |
| `ui/UpdatesPage.qml` | `5cc9fad04d65d0bace0149a36ae5deed9b2ecf7decef0b880cd1855e0acaf97f` |

Host:

- Installed packages: **Omarchy 4.0.4-1**, **Quickshell 0.3.1-1**.
- Active session runtime: `/home/tester/omarchy-host`, the existing
  continuity-patched runtime. `omarchy version` reports `dev`.
- This copied runtime has no `.git` metadata, so there is no defensible host
  commit SHA. `host-file-hashes.json` records 1,788 regular, non-symlink files.
- SHA-256 of sorted compact JSON of that file-hash map:
  `55fc26bfb118567c6b92ce6d813ed459e7d10c1e2c53a440d8cbba75dceef728`.
- Native `bin/omarchy-plugin-update` SHA-256:
  `0e7f6e7d18d77b5f13260f4374d1775cb4e2c7f88fff3c4c172dfa2b32d056be`.

## Executed checks

### Native updater — PASS

Only two harmless, locally created fixture IDs were installed:

- `org.example.outfit-update-one`: enabled, left bar placement.
- `org.example.outfit-update-two`: disabled.

For each: create a local Git repository at v1, install with the real native CLI,
commit remote v2, run the real native updater, verify installed HEAD and manifest
version `2.0.0`, then commit an invalid manifest and verify native rollback.

| Fixture | v1 HEAD | Valid v2 / restored HEAD | Invalid remote HEAD |
| --- | --- | --- | --- |
| one | `bdbc70a9525d02cdc1ab03033dc778536e76dcf8` | `dc9fe6d1c3026996b4b26a90d7005cc98014c992` | `8672598d22a52d015f561e99cf64b94e0416fd3f` |
| two | `460ba4d051e4510f36a5292ccd34622f8777611c` | `e67db9ca4374201c705f3c21e02b1823f4c2b5ce` | `0dd64e90ec52713c54e5ce331c259a50f57ff56a` |

Successful updates exited 0. Invalid updates exited 1 and printed an entry-point
validation failure plus `rolled back`. HEAD and manifest returned to valid v2.
Enabled/disabled lifecycle state was preserved. `shell.json` remained
byte-identical across each update and rollback, including the enabled fixture's
left placement. Native reconciliation reported no fixture load errors.
Both fixtures were removed with the native CLI before the hosted UI phase.

### Hosted QML / visual review — PASS except confirmation defect

The exact candidate `Service.qml`, `BackgroundWorker.qml`, and UI files ran
inside the actual canonical Omarchy shell. Only the copied demo helper was
adapted to supply fictional inventory/update records and audit protocol actions.

Observed at **1180×760** and **760×540**:

- Header `Updates (3)` versus `Update all (2)…`: two eligible ordinary plugins;
  Outfit is separate. Blocked and Omarchy-managed records were excluded.
- Details displayed installed `1.0.0` and available `2.0.0 · 2222222222`.
- Compact details retained the Update control in the bottom management area.
- The Updates list scrolls within the window; compact cards continue below the
  fold without horizontal overflow.
- Single, batch, and separate Outfit review dialogs showed readable version/SHA
  transitions and visible Cancel/confirmation buttons at compact size.
- Cancel by focused Return and Escape worked; inspector Escape returned to
  Updates. Page Back returned to Browse, and the header button reopened Updates.
- Reviews defaulted focus to Cancel. Merely opening a review or cancelling it
  did not dispatch mutation work or start a batch.
- A confirmation attempt failed closed on the field mismatch described above.

No candidate QML parse error appeared in the hosted fixture shell log. Its
warnings were the VM's EGL/BlueZ environment warnings.

The helper initially lacked an Outfit inventory record; this fixture omission
was corrected before testing its separate review. The final fixture inventory
uses the production `validate_inventory()` schema. No production UI was patched
to facilitate interactions or bypass confirmation.

### Independent self-update worker — PASS, 11 assertions

The real transaction was exercised through `self_update.launch()` after an
explicit fixture review, independently of the blocked UI confirmation path.

Because this was the full actual native restart test, it used the disposable
guest's real tester HOME/session rather than a private-HOME mock runtime. The
original Outfit/legacy registrations, sources, config/cache directories, and
shell configuration had first been moved to private backups and were restored
afterwards. The staged worker generation itself used production owner-only
cache directories/files.

Controlled fixture history:

- v1: `9.1.0-vm`, `cc25333006af9dedb2acfc922ec6b966fcb193f1`.
- v2: `9.2.0-vm`, `686e6bcfedb28505d5d6a6282b540be314b1481d`.
- v2 replaced **both** `scripts/outfit.py` and `scripts/self_update.py` with
  harmless trailing-comment changes, in addition to its version change.

Real boundaries:

- Original production `self_update.py` bytes, including launch/staging,
  acknowledgement, locks, receipts, verification and reopen state machine.
- Real local Git inspection, reviewed cache binding, production backend
  source/manifest/revision validation, and staged-source digest checks.
- Real transient `outfit-self-update.service`, launched with the production
  `systemd-run --user` argv.
- Real canonical `omarchy plugin update io.github.ctl0v0.outfit --yes`.
- Real `omarchy-restart-shell`, service readiness IPC and summon IPC.

Substituted boundaries:

- An adapter appended **only to the VM fixture backend** supplied public GitHub
  repository/ref/compare/manifest responses from the controlled local repository.
- Native Git transport was redirected from the exact fictional HTTPS origin to
  the local repository through command-scoped Git environment configuration;
  file transport was permitted only there. Native updater code was unchanged.
- The installed origin remained `https://github.com/fictional-updates/outfit.git`;
  no actual public Outfit remote was updated or fetched.
- Adapter SHA-256:
  `2760c5288f15809a4b9fe3aba7dbdd15effea3a9550a1d090d573e915d18314e`.

Observed lifecycle:

1. Launch returned `checking`, `accepted: true` after worker acknowledgement.
2. Worker PID **359897** remained the user-systemd service's MainPID through
   checking, updating, restarting, reopening and the completed receipt.
3. Before restart, receipt state had `verified: true` and the approved installed
   SHA/version. Native update changed both installed source files.
4. The staged `self_update.py` remained byte-identical to the candidate hash
   above; both staged source files differed from the replaced installed files.
5. Shell/editor PID changed from **357844** to **360480**. Outfit reopened on
   Updates with search `fictional`; receipt finished `completed`,
   `reopenState: accepted`, with the expected v2 SHA/version.
6. Shell configuration bytes were preserved by the transaction.
7. Closing Outfit and polling the terminal receipt five times did not reopen it.
8. The transient service was subsequently collected: `LoadState=not-found`,
   `ActiveState=inactive`, `MainPID=0`, `Result=success`.

The compositor initially tiled the reopened window at 1256×750 despite the
resume payload requesting 760×540. This run establishes view/query restoration,
not floating-window geometry restoration across shell restart.

## Commands and harness

From `/home/ctl/Work/outfit-updates`:

```sh
python3 /home/ctl/.agents/skills/omarchy-plugin-test/scripts/validate_plugin.py /home/ctl/Work/outfit-updates
python3 /tmp/opencode/outfit-update-stage.py stage
python3 /tmp/opencode/outfit-update-stage.py sync
python3 /tmp/opencode/outfit-update-stage.py restart-preflight
```

Portable validation: `VALID`, exit 0. Guest native validation of the original
staged candidate also exited 0.

The stage driver copied tracked and untracked candidate files without `.git`,
then launched the single restoration-owning group through `session_exec.py`.
Guest commands used the established SSH utility, for example:

```sh
python3 tests/vm/ssh_guest.py \
  --work /home/ctl/.local/state/omafit-release-vm/density-pass -- \
  env OUTFIT_TEST_VM=1 python3 /home/tester/outfit/tests/vm/session_exec.py \
  python3 /home/tester/outfit-updates-validation/outfit-update-self-check.py
```

The self-update check exited 0 with `{"checks": 11, "receipt": "completed"}`.
Inside the native phase, the relevant real commands were:

```sh
omarchy plugin add /home/tester/outfit-updates-validation/repos/<fixture-id> --yes
omarchy plugin enable org.example.outfit-update-one --section left
omarchy plugin disable org.example.outfit-update-two
omarchy plugin update <fixture-id> --yes
omarchy plugin remove <fixture-id> --yes
```

Hosted interactions used `wtype`, `hyprctl` cursor/window commands, and
`session_exec.py wlrctl pointer click left`. Captures used `grim -g` with actual
Hyprland window coordinates and asserted dimensions.

The first preflight assumed the copied host was a Git checkout; it failed before
mutating guest state and was corrected to record host file hashes. The group's
restricted PATH also omitted the existing user-local `wlrctl`; ten attempted
driver clicks are retained as harness errors in `report.json`. Those actions
were delivered subsequently via session-scoped `wlrctl` or keyboard navigation.
Do not interpret the raw harness error list as ten production failures, or the
22 passing state/restoration assertions as an overall feature pass.

## Evidence locations

Local evidence root: **`/tmp/opencode/outfit-updates-evidence/`**.

- `source-hashes.json`: all 170 tested source files.
- `source-audit.json`: no source drift, check counts, harness-error explanation.
- `evidence/report.json`: native outcomes, interactions, dimensions, restoration.
- `evidence/self-update-report.json`: worker receipts, systemd/PID samples and
  all 11 worker assertions.
- `evidence/summary.json`, `host-file-hashes.json`, protocol audit JSON files.
- `evidence/fixture-shell.log`, `native-shell.log`.

Reviewed captures, relative to `.../evidence/`:

| Capture | Evidence |
| --- | --- |
| `01-updates-normal.png` | 1180×760, available/eligible counts and separate Outfit card |
| `05-keyboard-review.png` | Ordinary-size Update-all review and Cancel default |
| `06-detail-keyboard-normal.png` | Installed → available detail values |
| `07-detail-review-normal.png` | Single-plugin review |
| `08-detail-compact.png` | 760×540 detail and persistent Update control |
| `09-updates-compact.png` | Compact Updates layout |
| `11-all-review-compact.png` | Compact Update-all (2), excludes Outfit |
| `14-self-review-compact.png` | Separate Outfit review with Cancel |
| `18-before-confirmation.png` | Reviewed single update before consent |
| `19-after-fixture-confirmation.png` | Blocking field-mismatch error |
| `20-self-update-reopened.png` | Real worker reopened Updates with saved query |
| `22-back-to-browse.png` | Visible Back navigation |
| `23-header-open-updates.png` | Header reopens Updates; real completed-worker message |

Temporary harnesses are `/tmp/opencode/outfit-update-*.py`; their guest copies,
fixture repositories and evidence remain under
`/home/tester/outfit-updates-validation/`. No VM keys, disks, credentials, worker
environment/job documents, or private original user data were copied into source.

## Restoration and limitations

Restoration passed for both current and legacy Outfit registration/source paths,
their config/cache directories (file hashes, modes, symlinks/absence), and exact
original `shell.json` bytes/mode. Native original runtime restarted; legacy
`io.github.ctl0v0.omafit` answered status and the temporary Outfit registration
did not. Both native fixture IDs were absent. Captured workspace/cursor values
were reapplied. The recovery marker was removed only after these checks;
`evidence/finished` records successful restoration.

An independent post-restoration check (`evidence/final-restoration.json`) again
confirmed byte-identical shell configuration, original runtime status, absent
fixture IDs/recovery marker, and an inactive worker unit. Restored `shell.json`
SHA-256: `582c3274d150be0360f9380755231159cbd8009a7ee966c80b0b5e2677009d3d`.

No source commit/push, physical-host configuration change, real user plugin
update, package installation, or host runtime source edit was performed. Commits
above belong only to disposable fixture Git repositories.

Not established by this run:

- Successful UI-confirmed single/batch/self mutation: **blocked by the reported
  production field mismatch**. Worker API success is not a substitute for that.
- Public Internet provenance/transport: deliberately fixture-substituted for
  self-update; native Git mutation and all worker lifecycle boundaries were real.
- A separate private-HOME mock-runtime worker test, stock unpatched runtime,
  multiple monitors, exhaustive update failure matrix, or geometry restoration.
- The parent-owned full Python/QML suite was not duplicated. Only the portable
  validator, native validation, targeted native/UI/worker VM checks were run here.
