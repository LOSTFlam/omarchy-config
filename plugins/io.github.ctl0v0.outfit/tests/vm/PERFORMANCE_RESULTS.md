# Native performance validation — 2026-09-20

## Current verdict — final native follow-up PASS, 18:10 UTC

**The confirmed EOF reentrancy defect is fixed in the final candidate. All 23
focused native assertions and all 10 restoration checks passed**, with no harness
failure or candidate QML warning/error. The transport and close/reopen checks ran
in one restoration-owned session on the existing VM. No production code was
edited by this validation.

### Final native results

- **Exact former failure reproduced successfully:** the unchanged reproduction
  script first ran four sequential chunk/EOF requests, then synchronously called
  `submit()` from an EOF request's actual `finished` signal. Generations **5 and
  6 both returned `ok: true`**, the full **131,072-character payload**, and
  `雪 café 😀 Ελληνικά é`. Sequential chunked cases each received one progress
  frame; inactive parsers had `accepting: false`, empty pending buffers and zero
  byte counters.
- **Early close/reopen with cancellation in flight:** fictional helper requests
  for Browse, inventory and catalog were held before backend execution. The
  normal `closeEditor()`/`openEditor()` path reopened while the old processes were
  still alive and both startup workers remained active/cancelled. The fixture
  delayed SIGTERM exit by **1.2 seconds**, rather than fabricating process exits.
  `queryStopping` and `queryBusy` stayed true, with no active new query.
- **Both startup lanes retried automatically:** their generations advanced
  **2 → 3** only after cancellation finished, and both settled `complete`.
  Inventory became ready and Browse reconstructed all three fictional rows,
  without manually assigning Service readiness, worker state or generations.

| Lane | Retired PID | Replacement PID |
| --- | ---: | ---: |
| Query/Browse | 31836 | 31909 |
| Startup inventory | 31847 | 31910 |
| Startup catalog | 31848 | 31911 |

- **Late output discarded:** all three cancelled Python processes actually
  wrote a late JSON frame followed by an unterminated partial frame. While they
  were still retiring, the native parsers retained no bytes/partial buffers and
  the cancelled fictional row never appeared. Protocol timestamps prove new
  requests followed the old processes' retirement events.
- **Writes gated during retirement:** `savePreferences()` returned false while
  the old query PID was retiring. A density change queued through the normal
  public method, completed on the replacement helper and persisted `list` to
  private preferences; the rejected preference value was never saved.
- **Sleep-time retirement/reopen:** with fixture-only `sleepDelay = 350`, sleep
  cleared Browse and began terminating query PID **31909**. Reopening during
  its live retirement window left `requestActive: false` and `queryBusy: true`.
  After that PID exited, **32004** loaded the cache and rebuilt Browse, with
  inventory/catalog complete and no Service error.
- **Service legacy EOF:** the production `write_response()` serialized through
  a controlled 37-byte stdout sink that omitted the final newline and ended
  each helper. Five observed ASCII frames included `load`, `verify-inventory`,
  `catalog-refresh` and two `quick-setup` results. Browse reconstructed normally;
  subsequent close settled asleep with query/optional/thumbnail workers absent.

The helper used the existing fictional demo inputs and production backend
serialization/response handling. Artificial request latency, delayed termination,
late cancelled output and stdout framing were confined to the disposable helper.
No native plugin mutation or public-network operation was performed.

### Final tested snapshot

Host remains **Omarchy 4.0.4-1 / Quickshell 0.3.1-1 / Qt 6.11.2-3** at
`/home/tester/omarchy-host`. Source bytes were hashed before transfer. Exactly
`BackgroundWorker.qml`, `Service.qml` and `ThumbnailLoader.qml` changed from the
failed 18:02 snapshot. **Final audit found no non-test source drift**, and all
original runtime files below matched their staged source copies byte-for-byte.

| Final tested file | SHA-256 |
| --- | --- |
| `Service.qml` | `9b8cf0ae0a22fe294dc4ecd21e643d099cf4ad4cd7e927afd1a799b5d3587509` |
| `BackgroundWorker.qml` | `d664401489b0ffbb81630a2177d2ec79c7ad36a61f2055917ada1d208dbd2b0e` |
| `BoundedJsonParser.qml` | `a43cc5cea8f3c01c4ba676c674d6ac6f88cd1e477bd42c9d9115b117819937dc` |
| `ThumbnailLoader.qml` | `f5250de6e9590a232c52ddeafb4ba5b45de82109389228ffbb2b16f037447774` |
| `ui/OutfitApp.qml` | `43cc1228253076e66915a6d8636d22c4887df745a2381c2821ac37014c0fd846` |
| `ui/UpdatesPage.qml` | `cd49e9aa3f89c91b60ef220c0a603b1698d69eae79f3b1ae0f47a28d0157d46d` |
| `ui/PluginDetailPage.qml` | `d5fd01e4223924498c73bb6d1ed745305b0c5ebe8486c04665264414c69301cc` |
| `scripts/outfit.py` | `f8cb5e83f83dcaa6f1f75358ed720fafb9b803bf1d317ffe4568ea79de7a1c5b` |
| `scripts/self_update.py` | `8309202aa55acf2c2438f6ff6ab35f5183d71e0b6cd00a452011257c1d8a9861` |

### Final evidence, restoration and limits

Evidence root: **`/tmp/opencode/outfit-native-performance-final/`**.

- `evidence/accepting-transport.json`: exact former reproduction, now successful.
- `evidence/close-reopen-races.json`, `report.json`, `followup-protocol.jsonl`:
  native PID/generation transitions, late writes, startup retry and EOF delivery.
- `evidence/fictional-worker.py`: exact latency/framing adapter used in the VM.
- `source-hashes.json`, `source-drift.json`, `final-audit.json`: final snapshot,
  comparison with the failed snapshot, 23/23 focused and 10/10 restoration checks.
- `evidence/restoration.json`, `evidence/finished`, `final-restoration.json`:
  restoration and independent post-session verification.

```sh
python3 tests/vm/performance_check.py \
  --work /home/ctl/.local/state/omafit-release-vm/density-pass \
  --evidence /tmp/opencode/outfit-native-performance-final --probe-only
python3 /tmp/opencode/outfit-performance-control.py python \
  /tmp/opencode/outfit-performance-followup-transport.py accepting-transport
python3 /tmp/opencode/outfit-performance-control.py python \
  /tmp/opencode/outfit-performance-final-adapter.py adapter
python3 /tmp/opencode/outfit-performance-control.py python \
  /tmp/opencode/outfit-performance-final-races.py close-reopen-races
python3 /tmp/opencode/outfit-performance-control.py python \
  /tmp/opencode/outfit-performance-final-session-check.py final-native
python3 /tmp/opencode/outfit-performance-control.py send '{"action":"finish"}'
python3 /tmp/opencode/outfit-performance-final-audit.py
python3 /tmp/opencode/outfit-performance-restoration-audit.py
```

Copies of the focused probe scripts/control helper are archived under `evidence/`.
The control helper now addresses the final root. Restoration preserved original
registrations, source/config/cache/state, workspace/cursor and shell-config bytes
and mode. Independent verification found the original legacy runtime, absent
candidate/fixture registrations, no recovery markers and **no live candidate
Python PIDs**. Shell-config SHA-256 remains
`582c3274d150be0360f9380755231159cbd8009a7ee966c80b0b5e2677009d3d`, mode **0644**.

The earlier **actual 30s/60s soak, native install/update and large Updates UI
gates were not repeated**. Their historical snapshot boundaries remain below;
backend/UpdatesPage/PluginDetailPage source hashes are unchanged from the original
pass. No new CPU/RSS benchmark was collected. Thumbnail/mutation EOF reentrancy,
README identity and thumbnail-positioning notifications were not individually
native-regressed in this bounded follow-up, nor was real self-restart. The
parent-owned full suite was not duplicated. No production/unit-test edit, host
configuration change, commit or push was performed.

## Fixed history — native EOF reentrancy defect, 18:02 UTC

**Historical FAIL, fixed and verified by the final follow-up above:** synchronous
re-submission from `BackgroundWorker.finished`. Ordinary
ASCII-chunk and legacy-EOF delivery passed on the final-change snapshot. A real
native reproduction then found a production worker defect; testing stopped and
the VM was restored. Production code was not edited.

### Confirmed failure

The exact candidate `BackgroundWorker.qml` and `BoundedJsonParser.qml` ran in the
native Omarchy shell, with the existing fictional Python transport helper:

1. Four sequential requests (`chunks`, `eof`, `chunks`, `eof`) all returned the
   complete **131,072-character payload** and `雪 café 😀 Ελληνικά é`. Chunked
   cases delivered one progress frame. On completion the worker was inactive,
   PID null, parser `accepting: false`, and pending buffer/byte count zero.
2. A fifth request delivered its final JSON **without a newline**, at EOF.
   Its actual `finished` signal synchronously called `submit()` for a sixth
   request, using normal newline/chunked output from a new Python process.
3. Generation **5 succeeded**. Generation **6 failed**: `ok: false`, no text and
   payload length **0**, despite the same helper mode passing twice immediately
   beforehand. The result is recorded under
   `checks.accepting-finished-signal-resubmit` in `evidence/report.json`.

The causal path is in **`BackgroundWorker.qml:136`**:

```qml
onTriggered: { outputParser.flush(); root.received = true; root.finish() }
```

`flush()` synchronously delivers the EOF frame. `receiveLine()` completes the old
request and emits `finished`; the callback's successful `submit()` initializes
the new request with `received = false`. Control then returns to the **old drain
handler**, which writes `received = true` into the **new request**. Its progress
and final frames are ignored by the `received` guards at lines 52 and 59; exit
finishes with no accepted response. The drain continuation is not generation-
guarded. This does not establish that the new `accepting` property introduced the
defect: the unguarded continuation also existed in the earlier snapshot.

The reproduction uses real `Process`/EOF/signals and the public `submit()` API;
it does not fabricate process exits, receive events or Service status. Its
`finished` callback is fixture-added. The failure therefore establishes the
worker's reentrant-callback boundary, not that every Service startup path reaches
it. In particular, the new `resumeStartupLater()` schedules through `Qt.callLater`.

### Snapshot, scope and evidence

Evidence root: **`/tmp/opencode/outfit-native-performance-followup-2/`**;
guest root: `/home/tester/outfit-native-performance-followup-2/`.
Packages remain Omarchy **4.0.4-1**, Quickshell **0.3.1-1**, Qt **6.11.2-3**.
`source-hashes.json` identifies every transferred file;
`followup-audit.json` records the six changed production files and **no production
drift at report time**:

| Changed production file | Tested SHA-256 |
| --- | --- |
| `Service.qml` | `41ca3960b48be57834c06480e53cb6b37a7624e6dc806f1f012b7b3170e93d25` |
| `BackgroundWorker.qml` | `2687dad6102e08f81b07bc77882c6255a83d9fabb46826201b0a1584cb253938` |
| `BoundedJsonParser.qml` | `a43cc5cea8f3c01c4ba676c674d6ac6f88cd1e477bd42c9d9115b117819937dc` |
| `ThumbnailLoader.qml` | `21df56c901ca00ef71f77440efb13f80f736380cfbf732a9d00235467d6e5085` |
| `ui/OutfitApp.qml` | `43cc1228253076e66915a6d8636d22c4887df745a2381c2821ac37014c0fd846` |
| `scripts/self_update.py` | `8309202aa55acf2c2438f6ff6ab35f5183d71e0b6cd00a452011257c1d8a9861` |

The backend `scripts/outfit.py`, `ui/UpdatesPage.qml`, and
`ui/PluginDetailPage.qml` retain the earlier hashes below. Earlier native
install/update, large-table UI and 30s/60s measurements remain evidence for their
documented snapshot; **they were not rerun or relabeled as new-snapshot passes**.

The final candidate successfully loaded and reached Browse as the transport
session prerequisite. **Injected-latency query retirement/fast reopen and optional
startup cancellation/retry were not run after the confirmed defect.** README
identity, thumbnail positioning notifications and self-update payload changes
were not separately native-regressed here. No full suite, long soak, native
install/update repetition or real self-restart was performed.

Reproduction commands:

```sh
python3 tests/vm/performance_check.py \
  --work /home/ctl/.local/state/omafit-release-vm/density-pass \
  --evidence /tmp/opencode/outfit-native-performance-followup-2 --probe-only
python3 /tmp/opencode/outfit-performance-control.py python \
  /tmp/opencode/outfit-performance-followup-transport.py accepting-transport
python3 /tmp/opencode/outfit-performance-followup-audit.py
python3 /tmp/opencode/outfit-performance-restoration-audit.py
```

The control helper addressed this follow-up root for that run. Its failed assertion
intentionally terminates the session through the harness's restoration `finally`.
An initial follow-up attempt needed a **harness-only** traversal correction to
inspect native `Process.stdout` parsers; its restoration also passed. No production
behavior was changed to enable these probes.

`evidence/restoration.json`, `evidence/finished`, and independent
`final-restoration.json` confirm restored registrations/config/cache/state,
original legacy runtime, byte-identical mode-0644 shell config, no recovery
markers and **no live candidate Python helpers**. `evidence/shell.log` contains
only the known VM EGL/BlueZ warnings, with no candidate QML warning/error.

## Earlier snapshot verdict — retained historical evidence

**The selected native performance gates passed on the hashed candidate below.**
No production performance defect was confirmed. The real 30-second close grace,
60-second closed interval, process cleanup, reopen/state retention, native
install/update continuation, and virtualized Updates UI were exercised.

Evidence spans restoration-owned sessions because the new harness needed fixture
corrections. This is **not a claim that every historical runner invocation passed**.
The initial 30-second/60-second measurement was performed once; subsequent
lifecycle checks used fixture-only `sleepDelay` assignments of 350 or 700 ms.
The full Python/QML suite and the parent's focused unit tests were not repeated.

## Candidate and native host

- Source: `/home/ctl/Work/outfit-performance`, based on
  `761a9fd304c03fb62c1e79ab212f57db1fd7dd7b`.
- VM work: `/home/ctl/.local/state/omafit-release-vm/density-pass`, KVM.
- Native packages: **Omarchy 4.0.4-1**, **Quickshell 0.3.1-1**,
  **Qt 6.11.2-3**. Desktop runtime: `/home/tester/omarchy-host`.
- This is the existing continuity-patched runtime, not a stock-runtime claim.
  There is no host Git revision to report. Each `report.json` records the shell
  file hash/mode map. SHA-256 of its sorted compact JSON:
  `68f5d87cfb5647b7d9feeb569fef7d57590e4af75473c26a5fcdc4a1e485b27f`.
- Native updater SHA-256:
  `0e7f6e7d18d77b5f13260f4374d1775cb4e2c7f88fff3c4c172dfa2b32d056be`.

Each transfer read source bytes once, hashed those bytes, and archived those same
bytes before starting the guest. **All eight staged snapshots have identical
non-test source hashes. Final audit found no production drift from the current
worktree.** Harness/test-file drift is recorded separately. Final hosted checks
also compared original runtime files against the staged source byte-for-byte.

| Tested file | SHA-256 |
| --- | --- |
| `Service.qml` | `31be87ea26be1983f4cf71271ab7ea5b1b7ccf26969fe7a0a3d14d43b0d03b57` |
| `BackgroundWorker.qml` | `9d5bcf5ab9c521f70f817e6784913e0c92862803b050ab7ff0617fe3f0d4e4de` |
| `BoundedJsonParser.qml` | `32b57ad3d552873f91687c54aefc305d8d5f2d3615c4a91712a1c83ae0cc0749` |
| `ThumbnailLoader.qml` | `30be28b44bc0a4afd79612d0a6f4ad7d389053b055e49d65ed40c90f96c239d6` |
| `ui/OutfitApp.qml` | `89b95e7bf786382ddee87483ef014922111d7cb1e4b47ee638a6694a974718cf` |
| `ui/UpdatesPage.qml` | `cd49e9aa3f89c91b60ef220c0a603b1698d69eae79f3b1ae0f47a28d0157d46d` |
| `ui/PluginDetailPage.qml` | `d5fd01e4223924498c73bb6d1ed745305b0c5ebe8486c04665264414c69301cc` |
| `scripts/outfit.py` | `f8cb5e83f83dcaa6f1f75358ed720fafb9b803bf1d317ffe4568ea79de7a1c5b` |
| `scripts/self_update.py` | `f10fb395cbaf27ec1a2cf8e94cf549f98845d49404a451ee9f057c60516f0458` |

## Native observations

### Close, sleep and reopen — PASS

Run 3 used the unmodified **`sleepDelay: 30000`**. Query PID **11068** was alive
after close and at the pre-deadline sample, then disappeared after sleep.
Immediate close set `presentationPaused`, cleared pending read-only work, and
reported `optionalWorkers: 0`. Sleep retired Browse rows and the query process.

The subsequent **60.0858-second** closed observation recorded:

- no helper starts or requests: protocol audit count remained **9 → 9**;
- query absent, optional workers **0**, thumbnail worker inactive;
- whole-shell PID **10832** CPU delta **368 ticks**, at **100 ticks/second**:
  **3.68 CPU-seconds** across the entire Omarchy shell. This includes other shell
  services and is not attributable solely to Outfit or a before/after benchmark.

Run 4 used only a fixture property override of **350 ms** for additional cycles.
PIDs **13637**, **13740**, and **13819** each retired; each sleep had zero Browse
rows, and reopening reconstructed three fictional Browse rows in a new helper.
Opening used `Service.openEditor()` so the saved payload followed the same route
as the bar widget. The unsaved settings draft survived.

Run 8 exercised populated state, not only already-empty containers:

- a **170,000-character README**, blocks/media, result rows, discovery/history,
  matches, and thumbnail image/attempt/retry maps were populated with fiction;
- after close/sleep every measured collection was empty and thumbnail activity
  was false;
- a genuinely running optional Python update-check process, PID **24934**, was
  terminated by close; optional workers settled to **0**;
- populated pending search/setup/README/discovery/analyze queues cleared;
- reopen retained a valid unsaved interest draft, `interestsDirty`, List density,
  collapsed filters, an open settings page and its unsaved README toggle;
- private `preferences.json` bytes were unchanged across this sleep/reopen.

### Real Process framing and cleanup — PASS

Run 3 used the candidate `BackgroundWorker` and `BoundedJsonParser` with native
Quickshell `Process`, not the QtTest process stub:

- Python wrote ASCII-escaped JSON in **37-byte writes**, including a progress
  frame and a **131,072-character payload**. `雪 café 😀 Ελληνικά é` arrived
  intact, including the supplementary-plane character and combining mark.
- A legacy final JSON object **without a trailing newline**, delivered at process
  EOF, completed successfully with the same payload.
- A Python helper ignoring SIGTERM, PID **11306**, was gone after the worker's
  timeout/kill cleanup; `active` became false. Only the fixture's deadline was
  shortened to 300 ms; production stop/kill logic was unchanged.
- A nonexistent executable exercised actual spawn failure and the launch
  deadline. The worker settled inactive with no PID.

Run 7 additionally exercised the **production backend `write_response()`** through
a byte sink splitting its output into 37-byte writes. Its bytes were asserted
ASCII before writing. Native Service queries reconstructed Unicode catalog and
preferences values. The same sink removed the newline and exited each query
helper to exercise **Service's legacy EOF grace**, including successful reopen
and a protected density save. Backend NFKC normalization was accounted for in
these expectations; the lower-level transport test separately preserved the
un-normalized combining sequence.

### Closed protected work — PASS

Run 6 called the actual Service mutation APIs, production backend
`process_request()`/mutation implementation, and canonical native CLI:

| Operation | Reserved fixture | Mutation PID | Query/verification PID | Result |
| --- | --- | --- | --- | --- |
| Update | `org.example.outfit-update-two` | 18200 | 17932 | v1 → v2, completed |
| Install, disabled | `org.example.outfit-update-one` | 18658 | 18499 | genuine new checkout, completed |

Update changed `c40ab4a945fb50b4c4ec1c89f0a73a6241980c22` to
`bea3e1ccfb5d75567c84b838753b8e57044cccfc`. Install produced
`e9931ffea6cd9267c2d97f38e7c4a3b5ada3999c`.

Both panels were user-closed while execution was active. Samples covered **4.92 s**
and **4.52 s** of closed execution/verification. The fixture deliberately withheld
the mutation response's authoritative-inventory flag, requiring an independent
real `verify-inventory` query, delayed two seconds to make the boundary observable.
The original production mutation receipts were retained separately and reported
successful native outcomes. No native mutation outcome was fabricated.

Every sampled active-mutation/checking phase blocked sleep. The Service slept
only after its verification queue completed, with terminal operation `completed`,
no pending intent and no error. Final independent restoration audit found no
candidate Python helper alive.

Run 7 also closed during real production preference and density saves. They
remained active past the short fixture grace, persisted Unicode notes/List
density, then slept. A **fictional no-op self-update protocol** used real Python
oneshots and BackgroundWorker/Service state transitions: `checking` blocked sleep,
polling continued closed, and `completed` allowed sleep. This is not evidence of
the production independent self-update worker or a shell restart.

### Native Updates UI — PASS

Run 6 presented **1,000 and 2,000 fictional rows** through the actual hosted
`UpdatesPage`. The native page reported **9 instantiated delegates** for each
size, including pooled delegates; after keyboard navigation/expansion it reported
8. The full dataset was present in both the Service and filtered model.

Real `wtype` keyboard events verified Return expansion, Down row focus, opening
Details, and Escape back to the same row's Details focus. Reviewed capture:
`outfit-native-performance-6/evidence/updates-2000-native.png`, **1256×750**.
The screenshot's update-check error belongs to the intentionally network-disabled
demo backend; the table data is explicitly fictional.

All hosted logs were reviewed: **no candidate QML warnings/errors**. The logs
contain the VM's EGL/BlueZ warnings and, in transport runs, the intentionally
provoked missing-executable warning. Portable and guest native manifest validators
passed. No physical-host shell was exercised or changed.

## Evidence and commands

Local roots are `/tmp/opencode/outfit-native-performance-N/`; guest roots use
`/home/tester/outfit-native-performance-N/`. Relevant evidence:

| Run | Evidence |
| --- | --- |
| 3 | `evidence/report.json`, `performance-audit.jsonl`: actual grace/60-second idle and native transport |
| 4 | `evidence/report.json`: corrected normal reopen, drafts and three short cycles |
| 6 | `evidence/ui-diagnostic.json`, `ui-keyboard.json`, capture, `native-mutations.json`, `native-protocol.jsonl`, `*-closed-samples.json` |
| 7 | `evidence/protected-work.json`, `native-protocol.jsonl`, `report.json`: production serializer, query EOF, saves, self-state fixture |
| 8 | `evidence/heavy-retirement.json`, `final-native.json`, `report.json`, `restoration.json`, `finished` |
| 8 | `aggregate-audit.json`: all snapshots, final production-drift audit, historical failures, CPU/PIDs |
| 8 | `final-restoration.json`: independent post-group restoration/process audit |

Each root also contains `source-hashes.json`, `source-drift.json`, `command.json`
and the driver's log. The focused checked-in harness owns staging/restoration and
the baseline native probes. Additional temporary probes are preserved as
`/tmp/opencode/outfit-performance-{ui-probe,ui-finish,native-prepare,native-mutations,protected,retirement,finalize}.py`;
the guarded backend adapter is `outfit-performance-native-worker.py`.

Representative executed commands, from the candidate checkout:

```sh
python3 tests/vm/performance_check.py \
  --work /home/ctl/.local/state/omafit-release-vm/density-pass \
  --evidence /tmp/opencode/outfit-native-performance-3
# Continuations used --continued --interactive, or --probe-only for mailbox work.
python3 /tmp/opencode/outfit-performance-control.py python \
  /tmp/opencode/outfit-performance-retirement.py heavy-retirement
python3 /tmp/opencode/outfit-performance-control.py send '{"action":"finish"}'
python3 tests/vm/ssh_guest.py \
  --work /home/ctl/.local/state/omafit-release-vm/density-pass -- \
  env OUTFIT_TEST_VM=1 python3 /home/tester/outfit/tests/vm/session_exec.py \
  /home/tester/omarchy-host/bin/omarchy plugin validate \
  /home/tester/outfit-native-performance-8/source
python3 /tmp/opencode/outfit-performance-audit.py
python3 /tmp/opencode/outfit-performance-restoration-audit.py
```

The mailbox helper's guest-root constant was advanced between focused sessions;
it currently addresses run 8. The native mutation adapter allowed only the two
reserved IDs. Public discovery/content and Git transport were substituted with
local fixture repositories. Their **existing** commit histories were reused;
this task created no commits, pushed nothing and used no public network.

## Historical harness corrections and limits

Raw nonzero runs are retained rather than reclassified as clean passes:

1. An inactive native PID is `null`, not integer zero; corrected harness assertion.
2. The existing demo `density` scenario overwrites its `original` function map and
   fails with `KeyError: fetch_readme`. Used the working `installed` scenario;
   demo/production source was not repaired.
3. Empty summon payload bypassed saved drafts, and the first draft probe used a
   legacy service-picker field. Corrected to normal `Service.openEditor()` and
   actual settings/interest draft contracts.
4. QObject traversal needed the native window's `contentItem`.
5. A replacement-model sample still saw 1,000 rows. The resolved probe used
   distinct local variable names and verified Service/model counts; 2,000 rows
   then consistently had only 8–9 delegates.
6. A Unicode expectation initially ignored production NFKC normalization.
7. A fabricated nonempty *new* interest ID was rejected by the backend. Using the
   required empty ID established draft retention without bypassing validation.

There was no duplicate full suite. Native checks ran in grouped restoration
sessions, but harness corrections prevented completing the requested matrix in
one uninterrupted session. The final checked-in harness includes test-only
cleanup/label improvements after the captured snapshots; production bytes remain
identical. Multi-monitor, compact-size coverage, public-network behavior, real
self-update/restart, a performance baseline comparison and heap/RSS profiling
were not run. Spawn-failure/forced-timeout probes cover BackgroundWorker; Service
queries additionally cover native streaming/EOF and normal sleep termination.

## Restoration

Every session's `finally` restored current/legacy registration links or source
directories, config/cache/state paths with original hashes/modes/absence, exact
shell configuration bytes, the original runtime, workspace and cursor. Native
fixture registrations were removed. All eight recovery markers are absent.

Independent final verification confirmed legacy Outfit IPC, absent candidate IPC,
absent fixture IDs and **no live candidate Python PIDs**. Restored `shell.json`
is mode **0644**, SHA-256:
`582c3274d150be0360f9380755231159cbd8009a7ee966c80b0b5e2677009d3d`.

Only this report and `tests/vm/performance_check.py` were authored in the worktree.
No production/unit-test edit, physical-host configuration change, user-plugin
mutation, commit, push or remote publication was performed.
