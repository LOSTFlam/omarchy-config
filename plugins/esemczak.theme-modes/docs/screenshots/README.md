# Screenshots

Real desktop captures live in this folder and are referenced from the root README.

| File | Source | Shows |
|------|--------|-------|
| `panel-general.png` | `001.png` | General tab — automatic battery switching |
| `panel-light-themes.png` | `002.png` | Light theme carousel + background picker |
| `panel-dark-themes.png` | `003.png` | Dark theme carousel + background picker |

The marketplace listing uses [`preview.png`](../../preview.png), copied from `panel-light-themes.png`.

## Regenerate from new captures

Place raw PNGs in `~/Pictures/omarchy-plugin/` (or any folder), then:

```bash
SRC=~/Pictures/omarchy-plugin
DST=docs/screenshots

magick "$SRC/001.png" -strip -resize 1200x\> "$DST/panel-general.png"
magick "$SRC/002.png" -strip -resize 1200x\> "$DST/panel-light-themes.png"
magick "$SRC/003.png" -strip -resize 1200x\> "$DST/panel-dark-themes.png"
cp "$DST/panel-light-themes.png" preview.png
```

Keep screenshots at roughly 900-1200 px wide for readable GitHub rendering.
