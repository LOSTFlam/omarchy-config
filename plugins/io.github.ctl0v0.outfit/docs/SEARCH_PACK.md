# Public search-pack pipeline

`scripts/build_search_pack.py` produces a bounded, licensed README search seed from
the current official public marketplace catalog. It uses Python's standard library
and GitHub's public-source APIs. `gh` is needed only for optional local credentials
and explicit release publication. This document covers the builder, provenance,
wire contract, and publisher; runtime import behavior belongs to `scripts/outfit.py`.

## Sources and bootstrap catalog

- Catalog: `https://plugins.omarchy.org/catalog.json` (16 MiB maximum).
- `data/bootstrap-catalog.json` is a real fetched snapshot, not fixture listings.
  It retains bounded public listing fields in the official raw shape accepted by
  `normalize_catalog`: `plugins`, `generatedAt`, `sourceType: "community"`, and
  `listingValidatedCommit`. Extra cache/profile fields are discarded. One compact
  listing per line keeps the snapshot reviewable. The uncompressed snapshot fits
  below the runtime's 20 MiB cache limit.
- The snapshot's `provenance` records the official URL, fetch time, and SHA-256 of
  the original catalog response. The manifest also hashes the exact minimized
  snapshot distributed as `catalog.json` beside the immutable pack.
- README identity is the normalized public GitHub repository plus the catalog's
  full 40-character `listingValidatedCommit`. Branch names and current HEAD are
  never substituted. Duplicate repository/commit listings share one record.
  Listings without a usable pin are counted separately and have no invented key.
- Engagement statistics are optional enrichment and are not needed or fetched by
  this builder. No personal cache or desktop profile is used as a source.

The backend is imported lazily with `importlib`; only its pure catalog, identity,
and text normalization definitions are used. No `Store`, scanner, profile helper,
runtime importer, desktop entry point, or README cache is invoked. The builder
fetches metadata, license/notice text, and README text only. It does not fetch or
execute plugin code, shaders, images, or SQLite databases.

## Conservative redistribution policy (version 1)

Public README availability alone is **not** a redistribution grant.

1. GitHub repository metadata must say public and match the catalog identity.
   Authenticated access to a private repository does not qualify. Authenticated
   builds batch only visibility metadata first; root-tree queries are issued only
   for repositories confirmed public. Tree entries are metadata, not file bodies.
2. `GET /repos/{owner}/{repo}/license?ref={fullSHA}` must return a root LICENSE or
   COPYING file and a recognized GitHub SPDX classification. The exact license
   blob must match the root tree at that SHA. A Git blob SHA-1 and an independent
   source SHA-256 are checked/recorded. The complete license text is retained.
3. The exact SPDX allowlist is **MIT, Apache-2.0, BSD-2-Clause, BSD-3-Clause, ISC**.
   No local keyword/license guesser is used. GitHub's pinned license classification
   is the evidence authority; default-branch metadata by itself is insufficient.
   `NOASSERTION`, missing licenses, other BSD variants, copyleft/Creative Commons,
   custom grants, and compound SPDX expressions are unsupported and excluded.
   Supporting another license requires a policy change and review of its terms.
4. Additional root LICENSE/COPYING variants make scope ambiguous and are excluded.
   Only ordinary root `README.md`, `readme.md`, `README.MD`, `README.rst`, or `README`
   files are supported. Nested documentation is not assumed to inherit the grant.
   Explicit README/documentation-specific licensing wording is conservatively
   excluded for review. This is a deliberately narrow pipeline, not general legal
   interpretation of arbitrary repository licensing arrangements.
5. Root `NOTICE`, `AUTHORS`, and `COPYRIGHT` files, including suffixed variants, are
   preserved in full. A missing, binary, symlinked, oversized, or unreadable legal
   notice blocks indexing rather than silently dropping attribution. Each legal
   text is at most 128 KiB; combined license and notices are at most 512 KiB.
6. README and notice bodies are fetched from unauthenticated public raw URLs at
   the pinned SHA, with their Git blob hashes checked against the pinned tree.
   The token is sent only to `api.github.com`, never redirects, raw content,
   catalog hosts, logs, manifests, or public resume state.

Original copyright lines and license/notice text retain their spelling and case;
only README search text is normalized. Each indexed record identifies the
transformation and possible truncation. Outfit's own license does not relicense
borrowed README content. Redistributors must retain the per-record license and
notice fields (or distribute an equivalent attribution artifact).

## Wire contract

The stable manifest alias is:

```
https://github.com/ctl0v0/outfit/releases/download/search-pack/latest.json
```

An immutable version uses a UTC build timestamp, for example `20260918T183000Z`:

```
release tag: search-pack-20260918T183000Z
asset:       search-pack-20260918T183000Z.jsonl.gz
assetUrl:    https://github.com/ctl0v0/outfit/releases/download/search-pack-20260918T183000Z/search-pack-20260918T183000Z.jsonl.gz
```

Required manifest fields:

| Field | Meaning |
| --- | --- |
| `schemaVersion` | Integer `1` |
| `format` | `jsonl-gzip` |
| `dataVersion` | Backend `SEARCH_INDEX_VERSION`, currently integer `1` |
| `version` | Build timestamp `YYYYMMDDTHHMMSSZ` |
| `generatedAt` | Same build time in ISO 8601 UTC |
| `catalogGeneratedAt` | Official catalog generation timestamp |
| `docCount` | Number of JSONL records, including excluded/unavailable records |
| `compressedBytes`, `uncompressedBytes` | Exact UTF-8 asset lengths |
| `sha256` | SHA-256 of the **compressed** gzip asset |
| `assetUrl` | HTTPS immutable release URL in `ctl0v0/outfit` |

Additional fields: `complete`, `publishable`, `catalogCount`, `candidateCount`,
`unpinnedCount`, `stateCounts`, `reasonCounts`, `requests`, `apiRemaining`, and
`publicationBlocked` when appropriate. Indexed coverage is
`stateCounts.indexed / candidateCount`, **not** `docCount / catalogCount`.
`publishable` reports corpus quality; the explicit publisher additionally requires
clean committed sources and a matching policy fingerprint.

`provenance` contains `sourceRepository`, `sourceCommit`, `sourceDirty`,
`builderSha256`, `normalizerSha256`, `catalogUrl`, `catalogSha256` (original
response), `catalogSnapshotSha256` (distributed minimal snapshot),
`catalogFetchedAt`, `licensePolicyVersion`, and `policyFingerprint`. A local build
from uncommitted work honestly records that fact; a publisher rejects it. Source
digests describe the code loaded by the process even if another worktree editor
subsequently changes files.

The gzip is UTF-8 JSON Lines with a trailing newline per record, sorted by key.
Gzip timestamps are zero for reproducibility. Each record has:

```json
{
  "key": "<sha256 of canonical repo.lower() + NUL + commit>",
  "repo": "https://github.com/example/plugin",
  "commit": "<40-character commit SHA>",
  "path": "README.md",
  "body": "normalized plain searchable text",
  "state": "indexed",
  "version": 1,
  "truncated": false,
  "license": "MIT",
  "sourceSha256": "<sha256 of original README bytes>",
  "reason": "licensed"
}
```

Identity uses the backend's existing `readme_key`; body uses
`normalized(markdown_content(source))[:24000]`. `truncated` is conservative at the
24,000-character boundary. Indexed records additionally carry `sourceLicenseText`,
`sourceLicensePath`, `sourceLicenseSha256`, `licenseEvidenceUrl`, `modifications`,
and `sourceNotices` (`[{"path": ..., "text": ..., "sha256": ...}]`). The source SHA
is over original bytes, before UTF-8 BOM removal or normalization.

`excluded` means license/visibility/scope policy prevented inclusion;
`unavailable` means required public text or evidence could not be obtained.
Both have empty `body` and `sourceSha256`; no excluded README text is serialized.
Reasons are aggregated verbatim in `reasonCounts`. A missing root README is
`unavailable`; an unknown license is `excluded`. Rate/permission failures stop
the build instead of pretending that all remaining READMEs are unavailable.

Bounds: 64 MiB compressed, 256 MiB uncompressed, 1 MiB per JSONL line, at most
10,000 records, 256 KiB source README, and 24,000 body characters. The validator
checks compressed/uncompressed hashes and sizes, key uniqueness and identity,
versions, field bounds, license evidence, counters, timestamps, own-repository
asset URLs, provenance, and exact catalog/key coherence.

## Build, validate, and resume

Run from a clean checkout for a release-quality artifact:

```sh
python -m unittest tests.test_search_pack_builder
python scripts/build_search_pack.py \
  --output /tmp/opencode/outfit-pack-build/run-1 \
  --state-dir /tmp/opencode/outfit-pack-build/public-state \
  --use-gh-auth --previous-public
python scripts/build_search_pack.py \
  --validate /tmp/opencode/outfit-pack-build/run-1 --require-publishable
```

The parent must be an approved external build location. Artifacts and public
resume state are rejected inside the source worktree. Output directories must
not already contain a manifest. No Python dependencies need installation.
`GH_TOKEN` or `GITHUB_TOKEN` is preferred in CI; `--use-gh-auth` explicitly obtains
the local authenticated `gh` token in memory. Anonymous smoke builds also work,
subject to GitHub's smaller anonymous REST allowance.

Use `--catalog data/bootstrap-catalog.json` to reproduce the captured source
selection. To refresh just the checked-in public snapshot:

```sh
python scripts/build_search_pack.py --catalog-only \
  --write-catalog data/bootstrap-catalog.json
```

`--max-documents N` is test-only and **always** marks the artifact incomplete and
non-publishable, even when N covers a small catalog. Without this flag the entire
deduplicated pinned catalog is attempted. `--workers` defaults to four (maximum
eight). Authenticated metadata batching plus raw README/notice requests leaves
approximately one REST license request per new repository; a cold catalog can
still exceed a workflow token's hourly budget.

On rate exhaustion, the command exits nonzero, writes an inspectable partial
pack with `complete: false`, and retains successfully processed public records
in the explicitly chosen state directory. Resume using the same state directory
and a **new output directory** after the API budget resets. Unavailable records
are retried. Indexed and policy-excluded records are reusable only when their
identity and builder/normalizer/policy fingerprint match. A previously published
pack is reusable only after downloading the own-repository HTTPS manifest and
verifying the complete referenced gzip. Local state is trusted builder output,
not a general import interface for arbitrary third-party caches.

## Daily workflow and publication gates

`.github/workflows/search-pack.yml` runs daily at 05:23 UTC and manually. Runs are
serialized without cancellation. The build job has `contents: read`, tests the
builder, fetches the current public catalog, and saves only public resume state
to an Actions cache (including on failed builds). No machine cache is restored.
Only validated, complete assets pass to a separate `contents: write` publisher.
Action versions are pinned to full commit SHAs. No PR or marketplace issue is
created, and no daily gzip is committed to Git.

Promotion is blocked for:

- Empty indexed corpora, incomplete/test runs, or incoherent manifest/data/catalog.
- Indexed coverage below 10% (can be raised with `--min-coverage`).
- More than 20% unavailable pinned sources.
- More than a 20% decline versus the current public pack in candidate count,
  indexed count, **or** indexed coverage ratio.
- Dirty source trees or changed builder/normalizer policy fingerprints at publish.

The previous pack is compared again immediately before publication. The publisher
creates the immutable versioned release with gzip, `catalog.json`, and its own
`latest.json`; it never overwrites those versioned assets. It verifies the actual
public bytes before uploading a separately named candidate alias manifest. Only
then is the prior alias renamed to `previous-before-<new-version>.json` and the
candidate renamed to `latest.json`. No old manifest is deleted. A failed rename
restores the prior alias, with retries and handling for lost successful responses.

GitHub provides no atomic release-asset replacement. The two rename calls can
therefore expose a brief missing-alias interval; an API outage during rollback
may require renaming the preserved prior asset back to `latest.json`. The error
identifies that asset ID and backup name. Build, validation, immutable-upload, and
candidate-upload failures never change the old alias. Preserved manifests and
immutable assets remain available for recovery.

`--publish DIRECTORY` is an explicit remote-write operation. Building, validating,
or using `--previous-public` never publishes. Local initial builds are review
artifacts; release/tag creation requires the maintainer's separate authorization.
