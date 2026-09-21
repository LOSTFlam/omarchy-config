# Support and diagnostics

Outfit supports **stock Omarchy 4.0.4 with Quattro** and Python 3.12 or newer.
Start with the [user guide and FAQ](docs/USER_GUIDE.md) for everyday controls,
or the [migration guide](IDENTITY_MIGRATION.md) if you are upgrading an early test
build. These instructions describe the 0.3.2 build.

## Quick recovery

### Listings appear, but Install is not ready

Open **More actions → Background activity** and check **Installed plugins**.
Outfit shows bundled/cached listings before it has confirmed local inventory.
Plugin changes wait for that check, independently of optional hardware scanning.
Use the inventory retry control or **More actions → Rescan system**. A failed
inventory check is not treated as proof that a plugin is uninstalled.

### Documentation is downloading, importing, or incomplete

Background activity separates the pack download from its local validation/import.
A completed download still needs importing before those documents are searchable.
**Library prepared** means available documents are searchable, not that all
repositories have usable documentation. Check searchable, pending, unavailable,
retrying, and skipped counts in the documentation status.

If the public pack is unavailable—including before its assets are published—
catalog search and previously cached text remain usable. Remaining eligible
READMEs are indexed locally while Outfit is open. Use the documentation retry or
pause/resume controls in Background activity, More actions, or Settings. Indexing
yields to manual maintenance and plugin changes; closing Outfit pauses it.

GitHub rate limits and complete network failures trigger a persisted wait before
retrying; missing documents have longer per-document retries. Pausing indexing
keeps cached text searchable. Turning off **Use GitHub READMEs and previews**
also turns off README matches, even for cached documents.

For a damaged search database, close Outfit and remove only
`readme-search.sqlite`, `readme-search.sqlite-wal`, and `readme-search.sqlite-shm`
from `${XDG_CACHE_HOME:-$HOME/.cache}/io.github.ctl0v0.outfit/`, then reopen.
The library can be prepared again from the pack and progressive local indexing.
Keep preferences and other caches. See [storage details](docs/TECHNICAL.md#private-storage-and-retention).

### Listings, counts, or previews look out of date

- **More actions → Refresh catalog** retries public listings and popularity data.
  Failed updates retain previous usable data; a dash means unknown, not zero.
- **Settings → Clear preview cache** removes recognized local images, retaining
  the catalog, preferences, interests, and batch queue. If temporarily disabled,
  wait for active preview work to stop.
- Marketplace thumbnails and GitHub README/previews have separate settings.
  A missing image does not prevent reading or managing a plugin.
- If Qt Multimedia or a video codec is missing, choose **Open externally**.
  Video support is optional.

### Outfit closes during a plugin change

Stock Omarchy can reload shell surfaces after plugin changes. Outfit retries
reopening, including when a later reload discards the first request. Allow several
seconds, then reopen from the widget or optional Apps launcher if needed.
Intentionally closing Outfit cancels recovery for that operation group; opening
it again enables recovery for later operations.

Interrupted batches remain available for review and explicit retry. A timeout
alone does not prove installation failed: Outfit checks actual inventory. An
installed plugin can still have a load error or need a restart; those outcomes
are reported separately. Optional host lifecycle support can improve continuity,
but uninterrupted windows are not promised on stock Omarchy. See
[host lifecycle details](docs/TECHNICAL.md#host-lifecycle-and-session-recovery).

### Hardware, saved interests, or startup need attention

- **Rescan system** retries local checks. Detected inputs distinguish failed
  checks from absent devices; last-confirmed observations can appear as stale.
- After an interest revision conflict, reload saved inputs. The draft is retained
  until explicitly discarded. An interest with zero matches is still valid.
- **Retry startup** retries a helper/storage failure. The message distinguishes
  permissions/read-only storage from disk or quota exhaustion.
- Optional hardware and documentation errors have separate retry controls in
  Background activity, so you can keep browsing while investigating them.

## Report an issue

Use [GitHub Issues](https://github.com/ctl0v0/outfit/issues). Include:

- Steps to reproduce the problem and what you expected.
- **Settings → Check diagnostics → Copy diagnostics**.
- Whether it occurs offline, with previews disabled, or after reopening Outfit.
- A cropped screenshot, if useful, after checking it for private information.

The report contains versions, optional-command availability, cache sizes, and
timestamps. It excludes raw hardware profiles, device names, paths, and watchlist
contents. Review it before sharing; do not attach your entire configuration,
environment, credentials, or unrelated notification/history data.

For vulnerabilities, use the private reporting guidance in [SECURITY.md](SECURITY.md).
Development versions, runtime limits, and verification references are in the
[technical guide](docs/TECHNICAL.md); historical results do not establish that an
unpublished or changed public revision passed fresh-machine verification.
