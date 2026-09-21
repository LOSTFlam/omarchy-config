# Changelog

## 0.3.2 — 2026-09-20

- Extend pre-execution commit pinning to individual/batch updates and the detached
  Outfit self-update worker. Both use the same verified snapshot helper as installs.
- Bind the native updater's fetch to that snapshot with a process-only Git mapping
  and local-only transport. Preserve the installed public origin and configuration.
- Verify manifest version, fast-forward ancestry and current installed state before
  native mutation; preserve native validation, rollback and final outcome checks.
- Reject executable Git configuration before status inspection and block unsupported
  replacement objects, partial clones, alternates and shared worktrees.
- Add real-Git races where upstream HEAD moves immediately before native fetch,
  including packaged Omarchy updater tests for ordinary and self-update identities.

Evidence and test boundaries: [pinned-update results](tests/PINNED_UPDATE_RESULTS.md).

## 0.3.1 — 2026-09-20

- Bind marketplace installs to the catalog's exact full commit SHA. Fetch and
  verify a private checkout before native installation; never install moving HEAD.
- Disable inherited Git hooks, templates, filters, credentials and URL rewrites
  during staging and the native local-repository handoff. Preserve the public
  upstream origin for subsequent updates.
- Retain reviewed revisions through installation retries, batch activation and
  inventory reconciliation.
- Add real-Git regressions with remote HEAD ahead of the reviewed commit, an
  execution sentinel, failure cases and isolated native add/validate coverage.
- Align the compact-layout spacing test with the existing short-window layout.

Evidence and boundaries: [pinned-install results](tests/PINNED_INSTALL_RESULTS.md).

## 0.3.0 — 2026-09-20

### Plugin updates

- Inspect installed and upstream versions/revisions from plugin details.
- Review available updates in a virtualized table, with individual and batch
  updates through native Omarchy commands.
- Update Outfit separately through **More actions → Update Outfit…**; an
  independent user-systemd worker verifies the result and reopens the app.
- Show local customizations, manual installations, and unavailable checks as
  distinct states. Preserve local edits rather than overwriting them.

### Previews and usability

- Fall back to suitable screenshots from pinned GitHub READMEs when marketplace
  previews are missing or unavailable, respecting both preview/README settings.
- Cache preview discovery, back off failed image requests, and keep useful
  in-flight work while scrolling.
- Return pagination to the top of new results while preserving detail-Back position.
- Align update controls to the right, use compact table rows with left-side
  expanders, and match confirmation buttons to the theme's corner radius.
- Place version information above recommendations and update checking with the
  installed-plugin controls.

### Performance and reliability

- Pause optional work when closed and sleep after 30 seconds, releasing the query
  helper and heavy view data. Explicit saves and plugin operations finish safely.
- Construct only the active Browse layout and visible Updates delegates; coalesce
  viewport work, bound image decoding, and release inactive document/media content.
- Avoid unrelated Git-version scans during targeted updates, merge concurrent
  README-cache writes, skip unchanged search packs when coverage remains valid,
  and prune obsolete attribution records.
- Bound IPC before complete-line delivery, preserve Unicode with escaped JSON,
  validate request ownership, and fix timeout, EOF-handoff, and rapid-reopen races.

Validation and measurements: [backend results](tests/PERFORMANCE_RESULTS.md),
[native lifecycle results](tests/vm/PERFORMANCE_RESULTS.md), and
[plugin-update results](tests/vm/PLUGIN_UPDATES_RESULTS.md). Performance gains are
workload-specific; cold queries did not demonstrate a general speedup.

## 0.2.0

- Introduced the `io.github.ctl0v0.outfit` identity and explicit migration helper.
- Added immediate bundled-catalog browsing, public documentation search packs,
  background preparation status, and local README relevance search.
