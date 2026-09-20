"""Hard caps on everything Fresh Tube reads from the network.

A huge, malformed or endless answer must fail instead of growing memory, so
every read below stops at its cap plus one byte and anything larger is an
error before any parsing. Sizes seen in 2026-09: RSS feeds up to 45 KB,
channel and watch pages up to 2 MB, oEmbed under 1 KB, and a few KB from the
yt-dlp commands the plugin runs.
"""
import os
import selectors
import subprocess
import time

from .errors import NETWORK, FreshTubeError

FEED_MAX_BYTES = 1 << 20     # 1 MiB: one channel's RSS feed; refresh fetches up to six at once
PAGE_MAX_BYTES = 8 << 20     # 8 MiB: a channel or watch page, read once when adding a channel
OEMBED_MAX_BYTES = 64 << 10  # 64 KiB: one video's oEmbed JSON
YTDLP_MAX_BYTES = 1 << 20    # 1 MiB: each of yt-dlp's stdout and stderr
CHUNK_BYTES = 64 << 10


def read_capped(response, max_bytes, what):
    """The whole body of `response`, reading at most max_bytes + 1 bytes; a larger body is a network error."""
    body = bytearray()
    while len(body) <= max_bytes:
        chunk = response.read(min(CHUNK_BYTES, max_bytes + 1 - len(body)))
        if not chunk:
            return bytes(body)
        body += chunk
    raise FreshTubeError(f"{what} is larger than {max_bytes} bytes", NETWORK)


def run_capped(args, timeout, max_bytes):
    """Like subprocess.run(args, capture_output=True, text=True, timeout=timeout), but stdout and stderr each
    stop at max_bytes + 1 bytes: past that, or past the timeout, the process is killed and the call raises."""
    process = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    deadline = time.monotonic() + timeout
    stdout, stderr = bytearray(), bytearray()
    buffers = {process.stdout.fileno(): stdout, process.stderr.fileno(): stderr}
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            selector.register(process.stderr, selectors.EVENT_READ)
            while selector.get_map():
                left = deadline - time.monotonic()
                if left <= 0:
                    raise subprocess.TimeoutExpired(args, timeout)
                for key, _ in selector.select(left):
                    buffer = buffers[key.fd]
                    chunk = os.read(key.fd, min(CHUNK_BYTES, max_bytes + 1 - len(buffer)))
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    buffer += chunk
                    if len(buffer) > max_bytes:
                        raise FreshTubeError(f"output is larger than {max_bytes} bytes", NETWORK)
        returncode = process.wait(timeout=max(deadline - time.monotonic(), 0))
    except BaseException:
        process.kill()
        process.wait()
        raise
    finally:
        process.stdout.close()
        process.stderr.close()
    return subprocess.CompletedProcess(args, returncode, stdout.decode("utf-8", "replace"),
                                       stderr.decode("utf-8", "replace"))
