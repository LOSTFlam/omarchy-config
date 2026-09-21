# Spotify for Omarchy

Spotify, living in your Omarchy bar.

The bar shows a little cover of whatever is playing. Click it and you get the
whole thing: album art, play/pause/skip, a seek bar, volume, a heart, your
playlists, audiobooks and podcasts, and search across all of Spotify. It can
even play music with no Spotify window open at all.

![The Spotify panel open under the bar](preview.png)

| Search results | Audiobook chapters | Devices and headless player |
|---|---|---|
| ![Search](preview1.png) | ![Audiobook](preview2.png) | ![Devices](preview3.png) |

## What you get

- **In the bar:** the current cover art (or the last thing you played) and a
  scrolling "Title · Artist". Left-click opens the panel, middle-click
  pauses, right-click skips, scrolling changes the volume.
- **Now playing:** big cover, title, artist and album, a seek bar you can
  drag, shuffle / previous / play / next / repeat, a volume slider, and a
  heart that saves the track to your library.
- **Search:** type once and get tracks, artists, albums, playlists, podcasts,
  episodes and audiobooks, grouped. With nothing typed you see what you
  played recently.
- **Playlists:** Liked Songs plus everything you made or follow. Open one to
  see its tracks, play from any row, or shuffle the whole thing.
- **Books:** your saved audiobooks, with every chapter and how far you got.
- **Podcasts:** shows you follow, with episodes, dates, length and progress.
- **Devices:** switch between your computer, phone, speakers and so on, or
  set up a headless player that needs no window (more below).
- **Keyboard:** everything works without a mouse. See the cheat sheet.

## Before you start

You need three things. Two of them are Spotify's rules, not ours.

1. **Spotify Premium.** Spotify only lets Premium accounts be controlled
   this way.
2. **A Spotify "developer app".** This is a free, two-minute step on
   Spotify's website that gives the plugin permission to talk to your
   account. Every person needs their own; Spotify does not allow sharing
   one. The panel walks you through it.
3. **Something to play the sound.** The panel is a remote control, not a
   speaker. It drives any Spotify Connect device: the Spotify desktop app,
   your phone, a speaker, or a headless player you install yourself and the
   panel then runs for you.

## Install

```sh
omarchy plugin add https://github.com/ninepointlabs/omarchy-spotify.git --enable
```

The chip appears in the right section of the bar. Put it wherever you like:

```sh
omarchy bar move ninepointlabs.spotify --before omarchy.audio
```

If you cloned this repository instead, run `./install.sh` from inside it.

## Connect your account

Click the chip. The panel shows three steps; here they are in full.

1. Open <https://developer.spotify.com/dashboard>, sign in with your Spotify
   account, and click **Create app**. Name it anything you like.
2. In the app's settings, under **Redirect URIs**, type exactly

   ```
   http://127.0.0.1:8888/callback
   ```

   then click **Add**, tick **Web API**, and **Save**. Spotify rejects
   `localhost`, so use the numbers. (If you ever see
   *"redirect_uri: Not matching configuration"*, this line is wrong or was
   never saved.)
3. Copy the app's **Client ID** into the panel and click **Connect**. Your
   browser opens Spotify's permission page; approve it and the panel
   switches to the player by itself.

That's the whole connection. It stays connected for six months; after that
the panel shows the same card again and one click renews it.

## Pick something to play through

Open the device button at the top right of the panel. Anything already
running Spotify on your account is listed; click one to play there.

### Option A: the Spotify desktop app

Simplest. Install it with the panel's **Install Spotify** button (or
`omarchy install service spotify`), open it once, and it appears in the
list. If you'd rather never see its window, start it hidden at login by
adding these two lines to your Hyprland Lua config:

```lua
-- ~/.config/hypr/autostart.lua
o.launch_on_start("spotify")

-- ~/.config/hypr/hyprland.lua
o.window("^(spotify|Spotify)$", { workspace = "special:spotify silent" })
```

Run `hyprctl reload`, then `hyprctl configerrors` to be sure it took.

### Option B: a headless player (no window, ever)

Spotify publishes a small program called **Spotify Soloist** that plays
music as a background service. **You install it; the plugin does not.** Once
it is on your machine the panel finds it and runs it for you.

Why the split: Spotify serves those builds from one mutable URL with no
checksum, no signature and no release manifest, so nothing downloaded from it
can be verified against a known-good artifact. A plugin that fetched and ran
it anyway would be a standing download-and-execute path, so this one doesn't.
Getting the bytes is left to a package manager, which does have a review trail
and a checksum you can read before you install. (An AUR checksum can lag behind
Spotify rotating the file at that URL; when it does, the install fails instead of
running something unverified, which is the right way round.)

1. Install Soloist yourself, from a source you trust:
   - on Arch/Omarchy, the AUR package `spotify-soloist-bin` (read the PKGBUILD
     first, as always with the AUR); or
   - follow Spotify's own instructions at
     <https://developer.spotify.com/documentation/soloist>, unpacking the
     `soloist` binary into `~/.local/bin`.

   The plugin looks for `soloist` in the system directories (`/usr/bin`,
   `/bin`, …) and in `~/.local/bin` — not on your `PATH`. A copy in
   `~/.local/bin` is used only if it is a regular executable owned by you (or
   root) that nobody else can write to, in a directory nobody else can write
   to, wherever a symlink there points.
2. Give Soloist a service to run under — see
   [Running Soloist yourself](#running-soloist-yourself) below. **The plugin
   does not write one**, for the same reason it does not download the binary:
   Soloist takes its API key only as a command-line argument, and a unit
   generated here would have to put your key into a command line that anyone
   who can read `/proc` can see.
3. Open the Spotify app on your phone or computer, open its device picker,
   and choose **Omarchy** once. That pairs it. Soloist remembers the session
   from then on.

Now the panel lists Omarchy as a device, offers **Start Soloist** if it's
ever stopped, and hands playback to it automatically when nothing else is
playing.

Spotify's builds stop working about 90 days after they are made. When that
happens the panel says so; update Soloist the same way you installed it
(`yay -Syu`, or a fresh unpack). Nothing updates it behind your back.

#### Running Soloist yourself

Soloist needs a service, and writing it is yours to do. If your package ships
one, use that. Otherwise a minimal `~/.config/systemd/user/soloist.service`
looks like this — fill in the path to your binary and your key:

```ini
[Unit]
Description=Spotify Soloist
After=pipewire.service network-online.target
Wants=pipewire.service network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/soloist --device-name Omarchy --api-key YOUR_KEY_HERE --ws 127.0.0.1:0
Restart=on-failure
RestartSec=5
# Soloist exits 10 when the build expires; restarting won't help.
RestartPreventExitStatus=10

[Install]
WantedBy=default.target
```

Then `systemctl --user daemon-reload && systemctl --user enable --now soloist`.

Get the key from <https://developer.spotify.com/dashboard>: open
**Spotify Soloist API Key**, accept the terms, click Generate.

**Read this before you paste your key in.** However you write that unit, the
key ends up on Soloist's command line, because Soloist accepts it no other way
(see [The API key and the command line](#the-api-key-and-the-command-line)).
Anything that can read `/proc` on this machine can read it there. Keep the unit
file itself at `0600` if you put the key straight into it, or keep it in a
`0600` `EnvironmentFile` and expand it — that protects the file, not the
command line. To see exactly what is exposed right now:

```sh
bin/spotify-bridge soloist audit
```

That reads the live unit and the running process and tells you whether the key
is on a command line, without printing the key itself.

> **Upgrading from an earlier version?** Versions before this one wrote a
> `soloist.service` for you, with your key expanded into `ExecStart`. That unit
> is still on your machine and still exposes the key; the panel now says so and
> offers **Remove the old plugin service** — one click disables and deletes
> `~/.config/systemd/user/soloist.service`. Replace it with a unit of your own
> from the template above, and consider regenerating the key, since it has been
> readable in the process list for as long as that unit has been running. Even
> older versions also installed a weekly `soloist-update.timer` that
> re-downloaded the binary; if yours still has it, the panel shows **Remove the
> old auto-updater**, or run `bin/spotify-bridge soloist drop-updater`.

> **Why not spotifyd or librespot?** Since late 2025 Spotify refuses to give
> those open-source players the keys to decode audio for accounts created in
> the last couple of years. They connect, then skip every track in silence.
> Soloist is Spotify's own engine, so it just works.

## Using it

| Where | Action |
|---|---|
| Bar chip, left click | open or close the panel |
| Bar chip, middle click | play / pause |
| Bar chip, right click | next track |
| Bar chip, scroll | volume up / down |
| Cover in the panel | play / pause |
| A row, click | play it (tracks, episodes, chapters, artists) or open it (playlists, albums, podcasts, audiobooks) |
| A row, right click | add to queue |
| Hover a row | reveals **+** (queue) and **▶** (play) |
| Device button | switch device, start or stop Soloist, sign out |

### Keyboard cheat sheet

| Key | Does |
|---|---|
| `j` / `k` or arrows | move between rows |
| `Enter` | open or play the highlighted row |
| `Space` | play / pause |
| `n` / `p` | next / previous |
| `s` | shuffle on / off |
| `f` | save / unsave the current track |
| `+` / `-` | volume up / down |
| `q` | queue the highlighted row |
| `/` | jump to the search box (`Esc` leaves it, `↓` jumps to results) |
| `1` `2` `3` `4` or `h` / `l` | switch tabs |
| `h` or `Esc` | go back out of a playlist, book or podcast |
| `d` | devices |
| `r` | refresh |
| `Tab` / `Shift+Tab` | switch to the next / previous bar panel |
| `Esc` | close |

## Settings

These live on the widget's entry in `~/.config/omarchy/shell.json`. Change
them with `omarchy bar set ninepointlabs.spotify <key> <value>`.

| Key | Default | What it does |
|---|---|---|
| `clientId` | `""` | Your developer app's Client ID. The panel fills this in. |
| `redirectPort` | `8888` | The port in the redirect URI. Change both if 8888 is taken. |
| `showTrack` | `true` | Show "Title · Artist" next to the cover in the bar. |
| `maxLabelWidth` | `180` | How wide that text may get before it scrolls. |
| `defaultTab` | `"search"` | Which tab opens first. Remembers the last one you used. |

## If something's off

- **"redirect_uri: Not matching configuration"** when connecting: the
  redirect URI in your Spotify app is not exactly
  `http://127.0.0.1:8888/callback`, or wasn't saved. Fix it, then click
  Connect again.
- **"No active device"**: nothing is playing Spotify right now. Open the
  device button and pick one, launch the desktop app, or start Soloist.
- **"Spotify Premium is required"**: the account you connected isn't
  Premium. Spotify won't allow playback control without it.
- **"Spotify rate limit hit"**: you clicked a lot very fast. It clears in a
  few seconds.
- **"Your Spotify session expired"**: six months passed. Click Connect.
- **"Soloist build expired"**: Spotify's builds stop working after 90 days.
  Update Soloist however you installed it (`yay -S spotify-soloist-bin`, or a
  fresh unpack into `~/.local/bin`), then start it again from the panel.
- **"No soloist binary found"**: install it first — see Option B above. The
  plugin will not fetch it for you.
- **Soloist starts but skips every track silently**: that's the librespot
  problem above, which Soloist doesn't have. Make sure `spotifyd` or another
  player isn't the active device.
- **Panel says "Spotify only lists tracks for playlists you own"**: a
  Spotify limit for playlists made by other people. Play still works.
- Something else: run
  `~/.config/omarchy/plugins/ninepointlabs.spotify/bin/spotify-bridge status`
  in a terminal and look at what it prints, and `journalctl --user -u soloist`
  for the headless player.

## Uninstall

```sh
omarchy plugin remove ninepointlabs.spotify          # the plugin
rm -rf ~/.local/state/omarchy-spotify ~/.cache/omarchy-spotify   # login and cover cache
```

If an earlier version of the plugin wrote a `soloist.service` for you, click
**Remove the old plugin service** in the panel first (or run
`bin/spotify-bridge soloist remove`). A unit you wrote, or one from a package,
is yours to remove — the plugin refuses to touch it. Then optionally
`rm -rf ~/.config/soloist ~/.local/share/soloist ~/.cache/soloist`. The
`soloist` binary itself is not the plugin's to remove — uninstall it the way
you installed it.

## Scripting

Two IPC targets are available while the shell runs:

```sh
omarchy-shell ninepointlabs.spotify toggle   # open/close the panel
omarchy-shell spotify playPause              # also next, previous, volumeUp, volumeDown
omarchy-shell spotify status                 # JSON: playing, title, artist, device, progress
```

Bind them in `~/.config/hypr/bindings.lua` for media keys. The helper
`bin/spotify-bridge` is a normal command-line tool too; `--help` lists
everything it can do. It runs under `/usr/bin/python3 -I` and replaces its
inherited environment with a short allow-list as soon as it starts, exactly
as it does under the panel.

## How it's built

- `bin/spotify-bridge` is a Python script (standard library only) that does
  all the talking to Spotify: the login, playback control, your library,
  search, and caching cover art under `~/.cache/omarchy-spotify`. Your login
  is kept in `~/.local/state/omarchy-spotify/auth.json`, readable only by
  you. No client secret is involved.
- `Service.qml` runs once per shell and keeps the state everything else
  reads. It checks the player every 4 seconds while the panel is open, every
  15 while something plays with the panel closed, and every minute when idle.
- `BarWidget.qml` is the chip, `Panel.qml` the popup. They use the same
  building blocks as Omarchy's own panels, so they follow your theme.
- There is no systemd unit in this repository, and nothing in the plugin
  writes one — see [The API key and the command line](#the-api-key-and-the-command-line).
  `bin/spotify-bridge soloist` only audits, starts, stops and cleans up. There
  is no downloader and no updater either.

Spotify's February 2026 rules for apps like this one shape a few things:
search shows at most 10 results per type, other people's playlists don't
expose their track lists, and the connection must be renewed every six months.

## Security notes

- **What is stored where.** The only secret the plugin stores is your Spotify
  login — a refresh token, no password — in
  `~/.local/state/omarchy-spotify/auth.json`, created with mode 0600 and
  readable only by your user. The Client ID in `shell.json` is not a secret.
  The Soloist API key is not stored by the plugin at all.
- **Login is PKCE.** There is no client secret anywhere. The one-time
  browser login talks to a listener on `127.0.0.1` only, checks the `state`
  it issued, and escapes anything it echoes.
- **No shell, no eval.** Every command the plugin runs is an argument list;
  nothing from Spotify or from you is ever pasted into a shell string, and
  nothing goes through `bash -c` or the bar's shell runner. IDs and URIs are
  validated before they go into an API path. Text from Spotify is rendered as
  plain text, never as rich text.
- **Nothing runs through your PATH or inherits your environment.** At startup
  the service probes a fixed list of absolute interpreters (`/usr/bin/python3`,
  `/bin/python3`, `/run/current-system/sw/bin/python3`) and runs the bridge as
  `<that python> -I -B bin/spotify-bridge …`: `-I` ignores every `PYTHON*`
  variable and user site-packages, and the script's `#!` line is never used.
  If none is found, nothing runs. The bridge gets a cleared environment —
  a fixed `PATH` of root-owned system directories, the XDG directories, the
  session bus, and the display handles the login needs to open a browser —
  and scrubs its own environment again on entry. Every program the bridge
  starts (`systemctl`, `pgrep`, `xdg-open`) is an absolute path found in
  `/usr/bin`, `/bin`, `/usr/sbin`, `/sbin` or `/run/current-system/sw/bin`,
  and only if it and every directory leading to it are root-owned and
  writable by nobody else; each child gets a rebuilt environment too. The
  three things the panel launches detached when you click — the Spotify app
  via `uwsm-app`, Omarchy's launch-or-focus, and Omarchy's floating terminal
  for the app installer — use absolute paths from that same resolution,
  re-checked in `Model.js`, with a cleared environment. `LD_PRELOAD`,
  `BASH_ENV`, exported shell functions, proxies and `/usr/local/bin` or
  `~/.local/bin` entries never reach any of them.
- **State files are opened defensively.** `auth.json`, `last-played.json`,
  a systemd unit being checked for removal, and the cover cache are reached through
  a directory held open by descriptor, walked from `/` with every directory
  checked to be yours or root's and writable by nobody else; the plugin's own
  directories must be real directories (never symlinks) and are kept at 0700.
  Reads use `O_NOFOLLOW|O_NONBLOCK` and are refused — not silently treated as
  empty — if the entry is a symlink, FIFO or device, not owned by you, hard
  linked, open to other users, or larger than a fixed cap (64 KiB for the
  login). Writes go to a fresh random temp name created with
  `O_CREAT|O_EXCL|O_NOFOLLOW` at 0600, are fsynced, and are renamed into place
  inside the same held directory; an existing destination that is not a
  regular file you own is refused rather than replaced.
- **Every network body is capped.** Web API and token replies are limited to
  2 MiB, error bodies to 64 KiB, cover art to 8 MB — checked against
  `Content-Length` first, then enforced while reading, with an overall
  deadline on top of the socket timeout. Redirects are never followed (so the
  bearer token is never replayed elsewhere), proxies are not taken from the
  environment, only HTTPS is spoken, and cover art is fetched only from
  Spotify's image CDNs (`*.scdn.co`, `*.spotifycdn.com`). The login listener
  reads at most 16 KiB of any request, times out idle connections, and
  ignores a callback that does not carry its `state` instead of aborting the
  login.
- **The plugin downloads no executables.** It never fetches, installs,
  updates or replaces a binary, and it ships no timer or service that could.
  Spotify serves its Soloist builds from a single mutable URL with no
  published checksum, signature or release manifest, so a download could not
  be bound to any reviewed artifact; installing Soloist is therefore left to
  your package manager or to you. The only thing the plugin downloads at all
  is cover art, over HTTPS, capped at 8 MB per image.
- **The API key and the command line.** Soloist takes its API key exactly one
  way: `-k/--api-key KEY` as a command-line argument. There is no environment
  variable, no key file, no file-descriptor handoff and no config file, and
  Soloist does not scrub its own `argv` afterwards, so the key stays readable
  in `/proc/PID/cmdline` — to `ps`, to `systemctl status`, to anything that
  scrapes the process table, and to the crash reporter Soloist embeds — for as
  long as it runs. Spotify's own [command-line
  reference](https://developer.spotify.com/documentation/soloist/reference/command-line)
  documents that one flag and says to treat the value as a secret. Verify it
  for yourself:

  ```sh
  # The only documented input, and no environment fallback:
  soloist --help | grep -- --api-key
  SOLOIST_API_KEY=x soloist --device-name Test   # → Error: --api-key is required
  strings "$(command -v soloist)" | grep -c SOLOIST_    # → 0
  ```

  **So this plugin never handles that key and never starts Soloist.** It writes
  no unit, stores no key, and has no field to type one into. Whatever runs
  Soloist has to put the key in a command line, so that decision — and the
  file it lives in — stays with you and with whatever package or unit you
  chose, outside the plugin's snapshot. The plugin only reports what it finds:

  ```sh
  bin/spotify-bridge soloist audit
  ```

  reads the live unit (`systemctl --user show -p ExecStart`, where variables
  are still unexpanded) and every running `soloist` command line in `/proc`,
  and reports whether an API key argument is present. Findings come back with
  the argument vector redacted, so neither the audit, the panel, nor any error
  or log line the plugin writes ever reprints the key. `tests/test_bridge.py`
  pins all of this: that the writers are gone, that no shipped file declares a
  command to run, that the panel has no key field, and that the audit finds a
  real key-bearing process in `/proc` while leaving a clean one alone.
- **Nothing phones home.** The plugin talks to `api.spotify.com`,
  `accounts.spotify.com`, and Spotify's image CDN. That's the full list.
- **It never creates a user service.** The plugin writes nothing to systemd.
  It reads (`systemctl --user is-active` / `show`) while polling status, and
  **Start Soloist**, **Stop** and **Restart** in the panel map to
  `systemctl --user start|stop|restart soloist` on a unit that was already
  there. Everything is `--user` scope; the plugin never touches system units,
  never installs a timer, and never asks for root. `install.sh` only copies
  the plugin files into place; it does not install or start any service.
- **The only thing it deletes is its own leftovers.** Units written by earlier
  versions carry a `# Managed by the ninepointlabs.spotify Omarchy plugin`
  marker on the first line, and **Remove the old plugin service** deletes a
  unit only if it carries that marker (or is recognisably the unmarked unit an
  even older version wrote). A `soloist.service` from a package or one you
  wrote by hand is refused, not removed, and the `soloist` binary is never
  touched. `~/.config/soloist/soloist.env` is left alone as well — this
  version of the plugin does not read, write or even know about that file.

## License

MIT. See `LICENSE`.
