# Backend performance: baseline vs candidate

## Final verification and local rollout

The required runner completed with **492 Python tests run (one optional artifact
test skipped)** and **747 QML checks passed**, plus native manifest validation.
The final native follow-up passed **23 focused checks** and **10 restoration
checks**, including synchronous EOF handoff and rapid close/reopen races. See the
[native report](vm/PERFORMANCE_RESULTS.md) for exact snapshot boundaries.

The candidate was integrated into `/home/ctl/Work/outfit` and its separate local
installation after verification. The baseline paths below describe the measurement
time; retained snapshots and tree `f54819155b1c06f51d61da17a09e70c28c5adb0c` preserve
those bytes. No commit or public push was made.

After rollout, the already-closed physical-session app reported `sleeping: true`,
`queryWorkerRunning: false`, `optionalWorkers: 0`, and `thumbnailWorkerActive: false`.
Another ten-second observation showed the same state; a process-list check found
no installed Outfit Python helpers. This verifies the idle outcome locally; the
actual 30-second transition timing was measured separately in the VM. No shared
Omarchy-shell memory or CPU reduction is attributed solely to Outfit here.

Measured 2026-09-20, using only disposable storage and fictional fixtures. **The
candidate reduces repeated hot-query work, targeted-update enrichment, and
preview/pack retry work. It does not demonstrate a general cold-query,
page-change, or five-query-cycle speedup.** No production files were edited.

## Sources and method

- Baseline: `/home/ctl/Work/outfit`, including its uncommitted pre-performance
  work. Its helper matches `scripts/outfit.py` in saved **tree**
  `f54819155b1c06f51d61da17a09e70c28c5adb0c`; that is not a helper-file hash.
- Candidate: `/home/ctl/Work/outfit-performance`. Both repositories had HEAD
  `761a9fd304c03fb62c1e79ab212f57db1fd7dd7b`; HEAD alone does not identify these
  working sources. Helper hashes were unchanged at the post-measurement check.
- Immutable-for-the-run source copies, scripts, full hashes, commands, and raw
  JSON: `/tmp/opencode/outfit-performance-evidence/`. Snapshot time:
  `2026-09-20T17:12:26Z`. See `manifest.json` for all input-file hashes.
- Python 3.14.7, Linux 7.2.5-3-omarchy x86_64, glibc 2.44.

| Input | SHA-256 |
|---|---|
| Baseline `scripts/outfit.py` | `148da35291ac33e45d1b6b6fd0c12011c0847eba587f28b45aa48767feed1240` |
| Candidate `scripts/outfit.py` | `f8cb5e83f83dcaa6f1f75358ed720fafb9b803bf1d317ffe4568ea79de7a1c5b` |
| Both `tests/benchmark.py` | `63e91df102e759c773f9cca2fa66cf14cfeb4aa3a13666c10b7b7417b7b13092` |

Helper Git blobs: baseline `abc3c6e2bbbb7de2a1de14dc6901279a0b281bf3`,
candidate `3b8b3152e824d06f05180d32a04c6cfc1f438b85`.

The existing benchmark was audited before execution: explicit temporary cache
and preference stores; supplied profile/inventory; `localOnly` requests; mocked
catalog/network/profile/inventory/native boundaries; read-only `/proc/self/status`
RSS sampling. The wrapper preserves its fixture, request path, assertions, and
serializer, adding per-request `process_time()`, requested page, RSS samples, and
final file sizes. HOME/XDG/TMPDIR point into disposable storage. An audit hook
also rejects subprocess launches, network connections, and original-home opens.
No live configuration, network, native operations, or GUI interaction was used.

Each case ran once in a fresh Python process, **baseline then candidate,
serially**. Other machine/parent activity could not be excluded; no CPU affinity,
frequency control, or repeated trials were used. CPU time helps distinguish
scheduling delay, but cannot remove frequency/cache-contention effects.

### Workloads and timing definitions

- **3,500 rows** is the representative catalog-size case; **10,000** is the
  supported ceiling. Both use the same replicated fictional catalog, unique
  revision keys, six profile signals, eight saved criteria, and 20 installed
  inventory rows. README setting: 12,000 characters; the fixture constructs
  11,950–11,964-character documents using repeated filler plus ten integration endings.
  This models corpus size and search paths, not real-world document diversity.
- **Working:** `dock orbitalwidget calendar dock spotify dock github dock`.
  Five distinct queries, with `dock` repeatedly revisited between others.
- **Cycle:** `dock orbitalwidget calendar spotify github`, in strict rotation.
  This exceeds the four-entry query/evidence LRU capacity and cannot retain a
  complete cycle. **Page:** empty query, alternating pages 1 and 2.
- All use `recommended` sort and no grouping. Each iteration uses page
  `1 + iteration % 2`, including query workloads. Iteration zero is excluded from
  warm statistics. `n` is the number of remaining requests, not independent runs.
- **Cold** is the first `app.run` after clearing store memory. Corpus creation,
  imports, normalization, and saving interests precede it; filesystem pages may
  already be warm. It is neither startup time nor a cold-disk measurement.
- **Run** is `app.run` wall time. **JSON path** additionally includes parsing the
  already-built request string and `json.dumps(response, ensure_ascii=False,
  separators=(",", ":"))`. It excludes process startup, pipes, UTF-8 byte encoding,
  actual `write_response`, and GUI handling. The candidate's actual response
  writer uses `ensure_ascii=True`; these JSON timings do **not** measure that
  changed wire protocol. CPU time covers the same in-process JSON path.
- p50 is the median. p95 is nearest-rank and is reported only for pools of at
  least 40 warm requests; even those tails are descriptive, correlated samples,
  not population estimates. Smaller pools retain raw samples/maxima in evidence.

## Timing results

All times in **milliseconds**, each cell **baseline → candidate**.

| Rows / workload | Warm n each | Cold run | Warm run p50 | Warm run p95 | JSON path p50 | JSON path p95 | Mean JSON-path CPU |
|---|---:|---:|---:|---:|---:|---:|---:|
| 3,500 working | 80 | 3651.89 → 3815.31 | 237.97 → 167.70 | 1179.97 → 287.75 | 238.64 → 168.37 | 1180.71 → 288.65 | 331.23 → 158.37 |
| 3,500 cycle | 50 | 3859.09 → 3751.98 | 256.24 → 240.57 | 1240.01 → 1147.24 | 257.00 → 241.25 | 1240.69 → 1147.87 | 439.98 → 422.72 |
| 3,500 page | 20 | 2641.83 → 2755.69 | 58.58 → 56.80 | — | 59.21 → 57.32 | — | 61.11 → 60.41 |
| 10,000 working | 40 | 11720.49 → 11587.21 | 751.20 → 497.67 | 3861.89 → 830.21 | 751.98 → 498.63 | 3862.59 → 830.87 | 1035.36 → 478.89 |
| 10,000 cycle | 25 | 11250.20 → 12271.01 | 796.22 → 779.81 | — | 797.03 → 780.59 | — | 1329.05 → 1370.10 |
| 10,000 page | 20 | 8093.68 → 7926.52 | 201.27 → 207.31 | — | 201.86 → 207.89 | — | 225.36 → 234.24 |

Observations:

- The interleaved working case cuts mean JSON-path CPU about **52% / 54%** at
  3,500 / 10,000 rows. Warm JSON-path wall means fall from **333.76 to 160.95 ms**
  and **1042.50 to 484.48 ms**. Avoiding expensive hot-query eviction spikes is
  consistent with the LRU change. The pooled medians mix cheap hits and expensive
  misses; they are not the latency of a typical individual query.
- This is **not** a uniform per-query gain: at 3,500 rows in the working case,
  `orbitalwidget` run p50 increases **236.56 → 253.49 ms**, and `dock` p50 is nearly
  unchanged (**55.73 → 56.53 ms**). The large aggregate gain is in fewer slow
  requests, not faster execution of every request.
- The five-query cycle is mixed: mean CPU falls about **4%** at 3,500, but rises
  about **3%** at 10,000; the latter wall mean rises **1345.37 → 1398.13 ms**.
  Do not credit LRU with a general cycle speedup. Ceiling-cycle cold time also
  regresses in this observation (**11.25 → 12.27 s**).
- Page changes are effectively similar at 3,500; at the ceiling, candidate p50
  wall time is about **3% higher**, mean CPU about **4% higher**. Cold requests
  remain multi-second. These small/mixed changes do not establish a reliable
  improvement or regression without controlled repeat trials.
- Benchmark response assertions passed, and baseline/candidate matched-result
  counts agree for every query and page case. This is not a full response or GUI
  equivalence test.

## Storage and sampled memory

Final file lengths are identical between helpers and across workloads at each
size; these are apparent file bytes, not allocated blocks or maximum disk use.

| Rows | SQLite index bytes | Catalog bytes | Interests bytes | All cache + preference file bytes |
|---|---:|---:|---:|---:|
| 3,500 | 43,753,472 | 3,396,762 | 328,279 | 47,511,516 |
| 10,000 | 124,882,944 | 9,709,081 | 935,379 | 135,560,407 |

Totals also include 235-byte preferences, 32,768-byte SQLite SHM, zero-length WAL,
and zero-length locks at the final snapshot. Corpus creation's transient WAL is
not measured here. Relevant limits: 10,000 catalog rows; 256 MiB search index;
24,000 characters per README; 320 inspector-cache entries / 20 MiB inspector
JSON cache; default setup page 36, maximum 60; four query/evidence entries and
240 snippet entries. Update inventory is capped at 2,000 rows. Pack limits are
64 MiB compressed / 256 MiB expanded; thumbnail cache 256 files / 64 MiB.

| Rows / workload | Baseline sampled max RSS (KiB) | Candidate sampled max RSS (KiB) |
|---|---:|---:|
| 3,500 working | 119,328 | 120,200 |
| 3,500 cycle | 119,540 | 120,748 |
| 3,500 page | 114,828 | 114,828 |
| 10,000 working | 260,124 | 261,944 |
| 10,000 cycle | 260,640 | 264,224 |
| 10,000 page | 245,960 | 245,804 |

RSS is `/proc/self/status` **VmRSS sampled after each request**, not VmHWM, not an
actual transient peak, and not memory attributable solely to the production
backend: the process also retains synthetic fixture/generator objects and the
measurement harness. There is no meaningful demonstrated RSS reduction.

## Deterministic work counts (no external operations)

Real check/update orchestration and inventory normalization were exercised;
host command responses, metadata inspection, remote responses, and update
dispatch were stubs. These count avoided calls, **not native/Git/network CPU or
end-to-end update latency**. One check then one verified modeled update:

| Installed rows N | Check-only metadata calls B → C | Check + update metadata calls B → C | Presence scans B / C | Selected-target inspections B / C |
|---|---:|---:|---:|---:|
| 20 | 20 → 0 | 80 → 0 | 4 / 4 | 4 / 4 |
| 500 | 500 → 0 | 2000 → 0 | 4 / 4 | 4 / 4 |
| 2,000 | 2000 → 0 | 8000 → 0 | 4 / 4 | 4 / 4 |

Thus a targeted check avoids one N-row enrichment pass; the update avoids three
more. Presence scans still enumerate the inventory. All explicit target
inspections addressed only `example.widget`, and both variants dispatched one
stub update. This does not make all request processing constant-time.

Fresh light preview probe: one fictional item and an initially empty store,
README fallback enabled; requests at modeled times 1000, 1061, 1122:

| Scenario / counter | Baseline per request | Candidate per request |
|---|---|---|
| Successful primary: inspector loader calls | 1, 1, 1 | 0, 0, 0 |
| Successful primary: `readmes.json` Store reads | 1, 0, 0 | 0, 0, 0 |
| Failed primary + successful fallback: inspector loader calls | 1, 1, 1 | 1, 0, 0 |
| Failed primary + successful fallback: image-fetch stub calls | 2, 1, 1 | 2, 0, 0 |

Both cached successful primary images, and both fetched fallback README discovery
only once. Candidate backoff avoids the subsequent failing-primary attempts.
These are cache/read-call assertions, not image decoding or rendering timings.

Two-document pack fixture (1,340 compressed bytes), due checks 86,401 seconds
apart: initial import makes one manifest + one asset call and validates two
records in both helpers. On unchanged due refresh, **baseline: one asset / two
records; candidate: zero assets / zero records**; each still checks the manifest.
After pruning one document, attribution rows are **2 baseline / 1 candidate**.
Both subsequently download the asset and restore the missing document; candidate
does not wrongly skip changed coverage. These small-fixture counts do not measure
large-pack import time or staging memory.

## Reproduction and evidence

The verified parent was `/tmp/opencode` before creating the evidence directory.
`measure.py snapshot` was run once; it refuses to overwrite existing snapshots.
With the retained evidence scripts and snapshots, the following commands
reproduce the measured sequence (the two helpers always run serially):

```bash
E=/tmp/opencode/outfit-performance-evidence
# Original source verification (run from outfit-performance):
git rev-parse f54819155b1c06f51d61da17a09e70c28c5adb0c:scripts/outfit.py
git hash-object /home/ctl/Work/outfit/scripts/outfit.py
git hash-object /home/ctl/Work/outfit-performance/scripts/outfit.py
# Initial snapshot creation, only in a fresh evidence directory:
# python -B "$E/measure.py" snapshot

python -B "$E/measure.py" counts baseline
python -B "$E/measure.py" counts candidate
for rows in 3500 10000; do
  iterations=10
  if [ "$rows" = 10000 ]; then iterations=5; fi
  for helper in baseline candidate; do
    python -B "$E/measure.py" bench "$helper" "$rows-working" --rows "$rows" --iterations "$iterations" --readmes --readme-chars 12000 --queries dock orbitalwidget calendar dock spotify dock github dock
  done
  for helper in baseline candidate; do
    python -B "$E/measure.py" bench "$helper" "$rows-cycle" --rows "$rows" --iterations "$iterations" --readmes --readme-chars 12000 --queries dock orbitalwidget calendar spotify github
  done
  for helper in baseline candidate; do
    python -B "$E/measure.py" bench "$helper" "$rows-page" --rows "$rows" --iterations 20 --readmes --readme-chars 12000 --queries ''
  done
done
python -B "$E/pack_counts.py" baseline
python -B "$E/pack_counts.py" candidate
python -B "$E/summarize.py"
```

Each `bench` invocation evaluates its snapshot's `tests/benchmark.py` with the
listed arguments and the documented measurement additions. Exact expanded argv
is also recorded in each result JSON. Evidence: `{baseline,candidate}-{3500,10000}-
{working,cycle,page}.json`, `{baseline,candidate}-counts.json`,
`{baseline,candidate}-pack-counts.json`, `manifest.json`, and `summary.json`.
`final-checks.json` records final source verification and measurement-script hashes;
it is produced by `python -B "$E/final_check.py"`.
All listed probes and benchmark assertions passed (exit 0). The full existing
test suite was not rerun. No commits, pushes, live changes, or GUI/native CPU
claims are part of this measurement.
