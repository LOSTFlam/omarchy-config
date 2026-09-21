# Omasing

I was tired of being bombarded with ads every time I looked up lyrics, so I
made this plugin.

It gives you lyrics without opening a browser, dodging an autoplay video, or
closing six cookie banners first.

Omasing is a native Omarchy bar plugin. Search for a song, choose the exact
recording, and read the lyrics in a focused popup. The idle search card stays
compact, then expands when results or lyrics need the room. Selected lyrics
can also be detached into a movable, lyrics-only window. Manual scrolling uses
the same fast 4× wheel/touchpad implementation as
[QuickshellSpotify](https://github.com/stappmus/Omarchy-Spotify), and
auto-scroll has a live, persistent speed control.

## Install

From GitHub:

```bash
omarchy plugin add https://github.com/stappmus/Omasing.git --enable
```

From a local checkout:

```bash
scripts/install-local.sh
```

The local installer validates the manifest, links this checkout into
`~/.config/omarchy/plugins/stappmus.lyrics`, and adds the widget to the center
of the bar. Pass `--section left`, `center`, or `right` to choose another
section.

## Requirements

Omasing requires Omarchy Quattro, Quickshell, Python 3, and network access to
the providers listed below. The helper uses only Python's standard library;
there are no API keys, account logins, elevated privileges, or extra package
dependencies.

## What “verified” means

A title alone is not enough to identify a recording. Before showing lyrics,
Omasing scores:

- track and artist names;
- album;
- duration;
- recording qualifiers such as live, acoustic, demo, remix, instrumental,
  radio edit, and slowed/sped-up.

It then fetches LRCLIB and Lyrics.ovh in parallel and compares the normalized
word sequence, overlap, and section structure. When multiple providers answer,
the popup shows how closely they agree:

- **Verified** — two providers agree strongly;
- **Mostly matched** — the words mostly agree, but formatting or repeated
  sections differ;
- **Sources disagree** — the metadata-best result is shown with a warning.

If only one provider returns usable text, Omasing still uses it but keeps that
implementation detail out of the reading view.

An explicitly selected live/demo/remix version is never silently retried as
the studio title. A remaster may fall back to the base title because it is
normally lyrically equivalent.

No matching system can prove that a community lyric is perfect. Agreement and
conflict badges keep meaningful cross-check results visible.

## Use

1. Click the lyrics icon in the Omarchy bar.
2. Type a title, artist, or lyric fragment. Search starts after a short pause;
   `Enter` runs it immediately.
3. Choose a result. Album, duration, and version are shown so live and studio
   recordings are not ambiguous. Equally relevant title matches are ordered
   using Deezer's catalog popularity; an artist included in the query and an
   explicit version such as “live” still take precedence.
4. Use the wheel/touchpad normally, or press **Auto-scroll** and adjust the
   speed from 0.25–3 rendered lines per second.
5. Press **Pop out** to replace the bar popup with a normal floating window.
   Drag its dotted title-bar handle to place it anywhere on the screen. The
   detached view has its own scroll position, auto-scroll button, and speed
   control. A pre-map Hyprland rule makes it floating immediately, without a
   tiled-window flash.

When Omarchy Spotify is actively playing a track, opening Omasing automatically
shows that recording using Spotify's title, artist, album, duration, artwork,
and current playback position. Spotify's lyrics buttons provide the same direct
handoff. The initial view uses the song's elapsed fraction and the rendered
amount of lyric text to keep the likely current line about 40% down the
viewport. The equivalent safety offset automatically grows for sparse lyrics
and shrinks for lyric-dense songs. Use Back or `/` whenever you want to search
for something else.

Keyboard controls:

- `Up` / `Down` — move through results or nudge the lyrics;
- `Enter` — open the selected result;
- `Space` — start or pause auto-scroll while reading;
- `Left` / `Right` — lower or raise auto-scroll speed;
- `/` — return to and focus search;
- `Escape` — go back, then close the popup.

In the detached view, `Space` toggles auto-scroll, `Up` / `Down` nudges the
lyrics, and `Escape` closes the window. Reopen the bar popup at any time to
search for another recording; the detached lyrics remain out of the way.

The default auto-scroll speed is also available in Omarchy's bar-widget
settings. Manual scrolling pauses auto-scroll immediately.

## Providers and privacy

- [LRCLIB](https://lrclib.net/) supplies searchable plain and synchronized
  lyrics.
- [Lyrics.ovh](https://github.com/NTag/lyrics.ovh) supplies Deezer-backed
  catalog suggestions and a second lyric result for comparison.

Search terms and selected track metadata are sent to those services. Omasing
does not use an account, API key, browser, analytics, or a local lyric cache.
Lyrics remain in the running Omarchy shell process only for the current
session. Lyrics belong to their respective copyright holders.

If either provider is unavailable, the other can still produce a result, but
Omasing reserves verification badges for results compared across providers.

## Remove

```bash
omarchy plugin remove stappmus.lyrics
```

## Development

The runtime is deliberately small: QML plus one Python standard-library
helper. There are no pip, Node, WebEngine, or scraping dependencies.

Run the full suite with:

```bash
scripts/test.sh
```

That command validates the Omarchy manifest, lints the QML, runs provider and
recording-matching unit tests, and runs the fast/manual/automatic scrolling
tests through Qt's offscreen QML test runner.
