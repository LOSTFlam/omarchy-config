"""fresh-tube: the latest unseen video of the YouTube channels you pick."""
import argparse
import json
import socket
import sys
from concurrent.futures import ThreadPoolExecutor

from . import feed, page, play, resolve, store, videos, ytdlp
from .errors import DUPLICATE, GENERAL, UNKNOWN, USAGE, FreshTubeError


def emit(data):
    print(json.dumps(data, ensure_ascii=False))


def channel_payload(channel, state):
    feed_state = state["feeds"].get(channel["id"]) or {}
    return dict(channel, lastError=feed_state.get("lastError", ""), source=feed_state.get("source", ""))


def cmd_add(args):
    channel_id = resolve.resolve_channel_id(args.url)
    if store.find_channel(store.load_channels(), channel_id):
        raise FreshTubeError("Already added", DUPLICATE)
    # Network first, files last: the fetch can take seconds and the panel may
    # write state (a seen video, a preference) in the meantime.
    parsed, source, error = fetch_one({"id": channel_id})
    channels = store.load_channels()
    name = (parsed or {}).get("name") or ""
    if name:
        channel = store.add_channel(channels, channel_id, name)
    else:
        # Kept anyway: the channel is real, only today's sources are silent.
        channel = store.add_channel(channels, channel_id, resolve.handle_of(args.url) or channel_id,
                                    name_pending=True)
    store.save_channels(channels)
    with store.state_transaction() as state:
        if parsed is not None:
            store.update_feed(state, channel_id, parsed, store.now_iso(), source)
        else:
            store.set_feed_error(state, channel_id, error)
    emit(channel_payload(channel, state))
    return 0


def cmd_remove(args):
    channels = store.load_channels()
    store.remove_channel(channels, args.channel_id)
    store.save_channels(channels)
    with store.state_transaction() as state:
        store.drop_feed(state, args.channel_id)
        store.prune_seen(state)
    emit({"removed": args.channel_id})
    return 0


def cmd_channels(args):
    state = store.load_state()
    payload = {"channels": [channel_payload(c, state) for c in store.load_channels()]}
    if args.json:
        emit(payload)
        return 0
    for c in payload["channels"]:
        line = f"{c['id']}  {c['name']}"
        if c["lastError"]:
            line += f"  ({c['lastError']})"
        print(line)
    return 0


MAX_PARALLEL_FETCHES = 6


def _failure(e):
    return str(e) if isinstance(e, FreshTubeError) else f"{type(e).__name__}: {e}"


def fetch_one(channel):
    """(parsed, source, error): the RSS feed, then yt-dlp when the feed fails, else why both failed."""
    try:
        return feed.fetch_feed(channel["id"]), "feed", ""
    except Exception as e:
        feed_error = _failure(e)
    try:
        return ytdlp.fetch_via_ytdlp(channel["id"]), "yt-dlp", ""
    except Exception as e:
        return None, "", f"feed: {feed_error}; yt-dlp: {_failure(e)}"


def refresh_all(channels, cached):
    results = []
    if channels and not cached:
        with ThreadPoolExecutor(max_workers=MAX_PARALLEL_FETCHES) as pool:
            results = list(pool.map(fetch_one, channels))
    if channels and not cached:
        # Load the state only now: the fetches took a while and the panel may
        # have saved a preference or a seen video in the meantime.
        now = store.now_iso()
        any_ok = False
        names = {}
        with store.state_transaction() as state:
            for channel, (parsed, source, error) in zip(channels, results):
                if parsed is not None:
                    store.update_feed(state, channel["id"], parsed, now, source)
                    names[channel["id"]] = parsed.get("name") or ""
                    any_ok = True
                else:
                    store.set_feed_error(state, channel["id"], error)
            if any_ok:
                state["fetchedAt"] = now
            store.prune_seen(state)
        if store.fill_pending_names(channels, names):
            store.save_channels(channels)
        offline = not any_ok
    else:
        # Load the state only now: there was nothing to fetch (or `--cached`
        # skipped it), and the panel may have saved a preference or a seen
        # video while we were deciding that.
        state = store.load_state()
        offline = cached and bool(channels)
    errors = []
    for channel in channels:
        message = (state["feeds"].get(channel["id"]) or {}).get("lastError", "")
        if message:
            errors.append({"channelId": channel["id"], "channel": channel.get("name", ""), "message": message})
    return {"videos": store.unseen_videos(state, channels), "pinned": store.pinned_videos(state),
            "queue": list(state.get("queue", [])),
            "fetchedAt": state["fetchedAt"], "offline": offline, "channelCount": len(channels),
            "errors": errors}


def cmd_refresh(args):
    payload = refresh_all(store.load_channels(), args.cached)
    if args.json:
        emit(payload)
        return 0
    for v in payload["videos"]:
        print(f"{v['channel']}: {v['title']}  {v['url']}")
    return 0


def cmd_seen(args):
    with store.state_transaction() as state:
        store.mark_seen(state, args.video_id)
    emit({"seen": args.video_id})
    return 0


def cmd_pin(args):
    channels = store.load_channels()
    with store.state_transaction() as state:
        video = store.find_latest(state, channels, args.video_id)
        if video is None:
            # Re-pinning something already pinned must work even after its channel moved on.
            already = [p for p in state["pins"] if p["videoId"] == args.video_id]
            if not already:
                raise FreshTubeError("No such video", UNKNOWN)
            video = already[0]
        store.pin_video(state, video)
    emit({"pinned": store.pinned_videos(state)})
    return 0


def cmd_unpin(args):
    with store.state_transaction() as state:
        store.unpin_video(state, args.video_id)
    emit({"pinned": store.pinned_videos(state)})
    return 0


def queue_payload(state):
    return {"queue": list(state.get("queue", []))}


def cmd_queue(args):
    if args.action == "add":
        if not args.value:
            raise FreshTubeError("queue add needs a video URL or id", USAGE)
        video_id = videos.video_id_from(args.value)
        if not video_id:
            raise FreshTubeError("That doesn't look like a YouTube video", USAGE)
        if video_id in store.queue_ids(store.load_state()):
            raise FreshTubeError("Already in the list", DUPLICATE)
        # Network first, file last, like `add`.
        meta = videos.fetch_metadata(video_id)
        record = store.queue_record(video_id, meta)
        with store.state_transaction() as state:
            store.queue_add(state, record)
        emit(record)
        return 0
    if args.action == "move":
        if not args.value or args.position is None:
            raise FreshTubeError("queue move needs a video id and a position", USAGE)
        try:
            index = int(args.position)
        except ValueError:
            raise FreshTubeError("position must be a whole number", USAGE)
        with store.state_transaction() as state:
            store.queue_move(state, args.value, index)
        emit(queue_payload(state))
        return 0
    state = store.load_state()
    if args.json:
        emit(queue_payload(state))
        return 0
    for q in state["queue"]:
        print(f"{q['channel']}: {q['title']}  {q['url']}")
    return 0


def cmd_done(args):
    """Finished with a video: out of the list, and seen."""
    with store.state_transaction() as state:
        removed = store.queue_remove(state, args.video_id)
        store.mark_seen(state, args.video_id)
    emit({"done": args.video_id, "removed": removed})
    return 0


def cmd_play(args):
    """Launch the player for a video; seen only once the player is running."""
    if not videos.VIDEO_ID_RE.match(args.video_id or ""):
        raise FreshTubeError("That doesn't look like a YouTube video id", USAGE)
    with store.state_transaction() as state:
        size = play.size_for(args.player, state["prefs"])
        play.start(args.player, args.video_id, size, args.fallback)
        store.mark_seen(state, args.video_id)
    emit({"played": args.video_id})
    return 0


def size_arg(text):
    parts = text.lower().split("x")
    if len(parts) != 2 or not all(part.isdigit() for part in parts):
        raise argparse.ArgumentTypeError("expected WIDTHxHEIGHT")
    return int(parts[0]), int(parts[1])


def cmd_place_window(args):
    """Hidden helper spawned by `play`: wait for the player's window, put it below the bar, and for browsers
    serve the page that embeds the player, size the window and remember the size it closes with."""
    server = title = None
    if args.serve is not None:
        if not videos.VIDEO_ID_RE.match(args.video or ""):
            raise FreshTubeError("--serve needs --video with a YouTube video id", USAGE)
        try:
            sock = socket.socket(fileno=args.serve)
            server = page.serve(sock, args.video)
            title = page.window_title(args.video, sock.getsockname()[1])
        except OSError as e:
            raise FreshTubeError(f"Could not serve the player page: {e.strerror or e}", GENERAL)
    try:
        window = play.find_window(args.pid, title)
        if window is None:
            return 0
        play.place_window(window, args.resize)
        if args.watch:
            # The window's own pid: it may belong to a browser instance that was already running.
            pid = window.get("pid")
            size = play.watch_window(window, pid if isinstance(pid, int) and pid > 0 else args.pid)
            if size:
                try:
                    with store.state_transaction() as state:
                        store.set_prefs(state, [("browserWidth", str(size[0])), ("browserHeight", str(size[1]))])
                except FreshTubeError:
                    pass  # a size outside the allowed range is not worth remembering
        return 0
    finally:
        if server:
            server.shutdown()
            server.server_close()


def cmd_login(args):
    """Open the fallback browser's profile on YouTube so the user can sign in (and add an ad blocker)."""
    play.launch(play.login_argv(args.player))
    emit({"login": args.player})
    return 0


def cmd_prefs(args):
    if args.action == "set":
        pairs = args.pairs
        if not pairs or len(pairs) % 2 != 0:
            raise FreshTubeError("prefs set needs a key and a value", USAGE)
        with store.state_transaction() as state:
            store.set_prefs(state, list(zip(pairs[0::2], pairs[1::2])))
    else:
        state = store.load_state()
    emit(state["prefs"])
    return 0


def build_parser():
    parser = argparse.ArgumentParser(prog="fresh-tube", description=__doc__)
    sub = parser.add_subparsers(dest="command", metavar="command")
    sub.required = True

    p = sub.add_parser("add", help="add a channel by URL, @handle or id")
    p.add_argument("url")
    p.set_defaults(func=cmd_add)

    p = sub.add_parser("remove", help="remove a channel by id")
    p.add_argument("channel_id")
    p.set_defaults(func=cmd_remove)

    p = sub.add_parser("channels", help="list the channels")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_channels)

    p = sub.add_parser("refresh", help="fetch every channel's feed and list the unseen videos")
    p.add_argument("--json", action="store_true")
    p.add_argument("--cached", action="store_true", help="only what is already on disk, no network")
    p.set_defaults(func=cmd_refresh)

    p = sub.add_parser("seen", help="mark a video as seen")
    p.add_argument("video_id")
    p.set_defaults(func=cmd_seen)

    p = sub.add_parser("pin", help="keep a video listed even after watching it (at most 3)")
    p.add_argument("video_id")
    p.set_defaults(func=cmd_pin)

    p = sub.add_parser("unpin", help="stop keeping a video pinned")
    p.add_argument("video_id")
    p.set_defaults(func=cmd_unpin)

    p = sub.add_parser("prefs", help="read or change the preferences (width, height, pinned, playerWidth, playerHeight)")
    p.add_argument("action", choices=["get", "set"])
    p.add_argument("pairs", nargs="*", metavar="key value")
    p.set_defaults(func=cmd_prefs)

    p = sub.add_parser("queue", help="the Watch later list: `queue add <url>`, `queue move <id> <pos>`, `queue --json`")
    p.add_argument("action", nargs="?", choices=["add", "move"])
    p.add_argument("value", nargs="?", help="video URL or id")
    p.add_argument("position", nargs="?", help="new index for `move`, from 0")
    p.add_argument("--json", action="store_true")
    p.set_defaults(func=cmd_queue)

    p = sub.add_parser("done", help="finished with a video: out of the Watch later list, and seen")
    p.add_argument("video_id")
    p.set_defaults(func=cmd_done)

    p = sub.add_parser("play", help="play a video in the configured player and mark it seen")
    p.add_argument("--player", default="mpv", help="player command line (default: mpv)")
    p.add_argument("--fallback", default=None, help="player to open when mpv cannot open the video")
    p.add_argument("video_id")
    p.set_defaults(func=cmd_play)

    p = sub.add_parser("place-window", help=argparse.SUPPRESS)
    p.add_argument("pid", type=int)
    p.add_argument("--resize", type=size_arg, default=None)
    p.add_argument("--watch", action="store_true")
    p.add_argument("--serve", type=int, default=None, metavar="FD")
    p.add_argument("--video", default=None)
    p.set_defaults(func=cmd_place_window)

    p = sub.add_parser("login", help="open the fallback browser on YouTube so you can sign in")
    p.add_argument("--player", default="chromium", help="browser command line (default: chromium)")
    p.set_defaults(func=cmd_login)

    return parser, sub


def main(argv=None):
    parser, _ = build_parser()
    try:
        args = parser.parse_args(argv)
    except SystemExit as e:
        # argparse already printed its own usage/error message; just surface the code
        # instead of letting it tear down an in-process caller (e.g. the test suite).
        return e.code if isinstance(e.code, int) else GENERAL
    try:
        return args.func(args)
    except FreshTubeError as e:
        print(f"fresh-tube: {e}", file=sys.stderr)
        return e.code
    except Exception as e:
        print(f"fresh-tube: {type(e).__name__}: {e}", file=sys.stderr)
        return GENERAL
