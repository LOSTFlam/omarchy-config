# Public screenshots

Captured on **September 19, 2026 (UTC)** from the installed Outfit **0.2.0**
application at source revision `c051d2f`, hosted by the local Omarchy development
shell. Service IPC confirmed `demo: false` and `ready: true`.

| Image | View |
| --- | --- |
| [`../../preview.png`](../../preview.png) | Browse all, Most liked, Comfortable cards; 3,555 entries including installed plugins |
| [`search.png`](search.png) | Search for `calendar`, Best match; 196 results |
| [`plugin-details.png`](plugin-details.png) | Radio Atlas (`akshar.radio-atlas`), with real installed/enabled state |

The app used its current public marketplace cache (catalog timestamp
`2026-09-18T21:47:33.599Z`) and actual local plugin inventory. Listing thumbnails
and the Radio Atlas preview are public images supplied by the marketplace.
Popularity metrics, search results, installation status, and recommendation
scores are the values rendered by the application during the capture session.

Images were captured directly from the Outfit window using `grim`, at
2864 × 1848 pixels. Only lossless PNG recompression and metadata stripping were
applied; no UI elements, text, metrics, or plugin imagery were composited or
replaced. The original Browse filters, workspace, and cursor were restored.

These public screenshots are separate from the deterministic fictional
regression captures produced by `demo/ui_capture.py`.
