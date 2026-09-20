import subprocess
import unittest
from unittest import mock

import support  # noqa: F401  (puts lib/ on sys.path)
from fresh_tube import limits, videos
from fresh_tube.errors import NETWORK, FreshTubeError

ID = "4_fM3Nv8BB0"
OEMBED = (b'{"title": "A title", "author_name": "Some Channel", '
          b'"thumbnail_url": "https://i.ytimg.com/vi/4_fM3Nv8BB0/hqdefault.jpg", "html": "<iframe>"}')


class Ids(unittest.TestCase):
    def test_every_link_shape_gives_the_id(self):
        for text in ("https://www.youtube.com/watch?v=4_fM3Nv8BB0",
                     "youtube.com/watch?v=4_fM3Nv8BB0&t=42s",
                     "https://m.youtube.com/watch?feature=share&v=4_fM3Nv8BB0",
                     "https://youtu.be/4_fM3Nv8BB0",
                     "youtu.be/4_fM3Nv8BB0?si=abc",
                     "https://www.youtube.com/shorts/4_fM3Nv8BB0",
                     "https://www.youtube.com/embed/4_fM3Nv8BB0?autoplay=1",
                     "https://www.youtube.com/live/4_fM3Nv8BB0",
                     "  4_fM3Nv8BB0  "):
            self.assertEqual(videos.video_id_from(text), ID, text)

    def test_channels_and_noise_are_not_videos(self):
        for text in ("https://www.youtube.com/@LinusTechTips",
                     "https://www.youtube.com/channel/UCXuqSBlHAE6Xw-yeJA0Tunw",
                     "UCXuqSBlHAE6Xw-yeJA0Tunw",
                     "https://vimeo.com/12345",
                     "https://www.youtube.com/watch?v=short",
                     "hello world", "", None):
            self.assertIsNone(videos.video_id_from(text), text)


class Oembed(unittest.TestCase):
    def test_parse_picks_title_channel_and_thumbnail(self):
        self.assertEqual(videos.parse_oembed(OEMBED),
                         {"title": "A title", "channel": "Some Channel",
                          "thumbnail": "https://i.ytimg.com/vi/4_fM3Nv8BB0/hqdefault.jpg"})

    def test_parse_rejects_non_json_and_non_objects(self):
        with self.assertRaises(FreshTubeError) as caught:
            videos.parse_oembed(b"<html>")
        self.assertEqual(caught.exception.code, NETWORK)
        with self.assertRaises(FreshTubeError):
            videos.parse_oembed(b"[1, 2]")

    def test_fetch_asks_the_oembed_endpoint_for_the_watch_url(self):
        fetch = mock.Mock(return_value=OEMBED)
        parsed = videos.fetch_oembed(ID, fetch=fetch)
        self.assertEqual(parsed["title"], "A title")
        url, timeout, max_bytes = fetch.call_args.args
        self.assertTrue(url.startswith("https://www.youtube.com/oembed?url="), url)
        self.assertIn("watch%3Fv%3D4_fM3Nv8BB0", url)
        self.assertTrue(url.endswith("&format=json"), url)
        self.assertEqual(timeout, videos.OEMBED_TIMEOUT)
        self.assertEqual(max_bytes, limits.OEMBED_MAX_BYTES)


class Ytdlp(unittest.TestCase):
    def test_reads_title_and_channel_and_builds_the_thumbnail(self):
        done = mock.Mock(returncode=0, stdout="A title\tSome Channel\n", stderr="")
        with mock.patch("fresh_tube.videos.run_capped", return_value=done) as run:
            parsed = videos.fetch_via_ytdlp(ID)
        self.assertEqual(parsed, {"title": "A title", "channel": "Some Channel",
                                  "thumbnail": "https://i.ytimg.com/vi/4_fM3Nv8BB0/hqdefault.jpg"})
        args = run.call_args.args[0]
        self.assertEqual(args[0], "yt-dlp")
        self.assertIn("--no-download", args)
        self.assertEqual(args[-1], "https://www.youtube.com/watch?v=4_fM3Nv8BB0")
        self.assertEqual(run.call_args.kwargs["timeout"], videos.YTDLP_TIMEOUT)
        self.assertEqual(run.call_args.kwargs["max_bytes"], limits.YTDLP_MAX_BYTES)

    def test_na_fields_are_empty(self):
        done = mock.Mock(returncode=0, stdout="NA\tNA\n", stderr="")
        with mock.patch("fresh_tube.videos.run_capped", return_value=done):
            parsed = videos.fetch_via_ytdlp(ID)
        self.assertEqual((parsed["title"], parsed["channel"]), ("", ""))

    def test_failures_become_network_errors(self):
        cases = [
            (dict(return_value=mock.Mock(returncode=1, stdout="", stderr="ERROR: [youtube] x: Video unavailable")),
             "Video unavailable"),
            (dict(side_effect=FileNotFoundError), "not installed"),
            (dict(side_effect=subprocess.TimeoutExpired("yt-dlp", 40)), "timed out"),
            (dict(side_effect=FreshTubeError("output is larger than 1 bytes", NETWORK)), "output is larger than 1 bytes"),
        ]
        for patch_kw, message in cases:
            with mock.patch("fresh_tube.videos.run_capped", **patch_kw), \
                 self.assertRaises(FreshTubeError) as caught:
                videos.fetch_via_ytdlp(ID)
            self.assertEqual(str(caught.exception), message)
            self.assertEqual(caught.exception.code, NETWORK)


class Metadata(unittest.TestCase):
    def test_oembed_first(self):
        with mock.patch("fresh_tube.videos.fetch_url", return_value=OEMBED), \
             mock.patch("fresh_tube.videos.run_capped", side_effect=AssertionError("yt-dlp not expected")):
            self.assertEqual(videos.fetch_metadata(ID)["channel"], "Some Channel")

    def test_ytdlp_when_oembed_fails(self):
        done = mock.Mock(returncode=0, stdout="A title\tSome Channel\n", stderr="")
        with mock.patch("fresh_tube.videos.fetch_url", side_effect=FreshTubeError("HTTP 404 from oembed", NETWORK)), \
             mock.patch("fresh_tube.videos.run_capped", return_value=done):
            self.assertEqual(videos.fetch_metadata(ID)["title"], "A title")

    def test_both_failing_names_both(self):
        with mock.patch("fresh_tube.videos.fetch_url", side_effect=FreshTubeError("HTTP 404 from oembed", NETWORK)), \
             mock.patch("fresh_tube.videos.run_capped", side_effect=FileNotFoundError), \
             self.assertRaises(FreshTubeError) as caught:
            videos.fetch_metadata(ID)
        self.assertEqual(str(caught.exception), "oembed: HTTP 404 from oembed; yt-dlp: not installed")
        self.assertEqual(caught.exception.code, NETWORK)

    def test_unexpected_exceptions_are_named(self):
        with mock.patch("fresh_tube.videos.fetch_url", side_effect=ValueError("boom")), \
             mock.patch("fresh_tube.videos.run_capped", side_effect=FileNotFoundError), \
             self.assertRaises(FreshTubeError) as caught:
            videos.fetch_metadata(ID)
        self.assertEqual(str(caught.exception), "oembed: ValueError: boom; yt-dlp: not installed")


if __name__ == "__main__":
    unittest.main()
