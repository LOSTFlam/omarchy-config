import unittest
from unittest import mock

import support
from fresh_tube import limits, resolve
from fresh_tube.errors import NETWORK, USAGE, FreshTubeError

LTT = "UCXuqSBlHAE6Xw-yeJA0Tunw"


class Inputs(unittest.TestCase):
    def test_looks_like_youtube(self):
        for good in ("https://www.youtube.com/@LinusTechTips", "youtube.com/c/LinusTechTips",
                     "https://youtu.be/3xngArcFpek", "@LinusTechTips", LTT,
                     "https://www.youtube.com/channel/" + LTT + "/videos", "https://m.youtube.com/@x"):
            self.assertTrue(resolve.looks_like_youtube(good), good)
        for bad in ("", "   ", "https://vimeo.com/x", "linus tech tips", "@two words", "UCshort",
                    "https://notyoutube.com/@x"):
            self.assertFalse(resolve.looks_like_youtube(bad), bad)

    def test_normalize_input(self):
        self.assertEqual(resolve.normalize_input("@LinusTechTips"), "https://www.youtube.com/@LinusTechTips")
        self.assertEqual(resolve.normalize_input(LTT), "https://www.youtube.com/channel/" + LTT)
        self.assertEqual(resolve.normalize_input("youtube.com/c/LinusTechTips"), "https://youtube.com/c/LinusTechTips")
        self.assertEqual(resolve.normalize_input("  https://www.youtube.com/@x/videos "),
                         "https://www.youtube.com/@x/videos")

    def test_direct_channel_id(self):
        self.assertEqual(resolve.direct_channel_id("https://www.youtube.com/channel/" + LTT), LTT)
        self.assertEqual(resolve.direct_channel_id("https://www.youtube.com/channel/" + LTT + "/videos?x=1"), LTT)
        self.assertIsNone(resolve.direct_channel_id("https://www.youtube.com/@LinusTechTips"))
        # A watch URL is not a channel URL even when an id appears elsewhere in it.
        self.assertIsNone(resolve.direct_channel_id("https://www.youtube.com/watch?v=abc&ab_channel=" + LTT))


class Html(unittest.TestCase):
    def test_canonical_link_wins_over_decoy_ids(self):
        self.assertEqual(resolve.channel_id_from_html(support.fixture("channel_page.html").decode()), LTT)

    def test_watch_page_uses_itemprop(self):
        self.assertEqual(resolve.channel_id_from_html(support.fixture("watch_page.html").decode()), LTT)

    def test_page_without_id(self):
        self.assertIsNone(resolve.channel_id_from_html(support.fixture("no_id_page.html").decode()))


class Resolve(unittest.TestCase):
    def test_direct_id_needs_no_network(self):
        never = mock.Mock(side_effect=AssertionError("no network expected"))
        self.assertEqual(resolve.resolve_channel_id(LTT, fetch=never, ytdlp=never), LTT)
        self.assertEqual(resolve.resolve_channel_id("https://www.youtube.com/channel/" + LTT, fetch=never, ytdlp=never), LTT)

    def test_handle_via_page(self):
        fetch = mock.Mock(return_value=support.fixture("channel_page.html"))
        ytdlp = mock.Mock(side_effect=AssertionError("yt-dlp not expected"))
        self.assertEqual(resolve.resolve_channel_id("@LinusTechTips", fetch=fetch, ytdlp=ytdlp), LTT)
        fetch.assert_called_once_with("https://www.youtube.com/@LinusTechTips", 20, limits.PAGE_MAX_BYTES)

    def test_video_url_adds_its_channel(self):
        fetch = mock.Mock(return_value=support.fixture("watch_page.html"))
        self.assertEqual(resolve.resolve_channel_id("https://youtu.be/3xngArcFpek", fetch=fetch, ytdlp=mock.Mock()), LTT)

    def test_falls_back_to_ytdlp(self):
        fetch = mock.Mock(return_value=support.fixture("no_id_page.html"))
        ytdlp = mock.Mock(return_value=LTT)
        self.assertEqual(resolve.resolve_channel_id("https://www.youtube.com/@Someone", fetch=fetch, ytdlp=ytdlp), LTT)
        ytdlp.assert_called_once_with("https://www.youtube.com/@Someone")

    def test_page_fetch_failure_still_tries_ytdlp(self):
        fetch = mock.Mock(side_effect=FreshTubeError("HTTP 404", NETWORK))
        ytdlp = mock.Mock(return_value=LTT)
        self.assertEqual(resolve.resolve_channel_id("@Someone", fetch=fetch, ytdlp=ytdlp), LTT)

    def test_nothing_found(self):
        fetch = mock.Mock(return_value=support.fixture("no_id_page.html"))
        ytdlp = mock.Mock(return_value=None)
        with self.assertRaises(FreshTubeError) as caught:
            resolve.resolve_channel_id("@Nobody", fetch=fetch, ytdlp=ytdlp)
        self.assertEqual(caught.exception.code, NETWORK)
        self.assertEqual(str(caught.exception), "Couldn't find that channel")

    def test_not_youtube(self):
        with self.assertRaises(FreshTubeError) as caught:
            resolve.resolve_channel_id("https://vimeo.com/x", fetch=mock.Mock(), ytdlp=mock.Mock())
        self.assertEqual(caught.exception.code, USAGE)
        self.assertEqual(str(caught.exception), "That doesn't look like a YouTube channel")


class YtDlp(unittest.TestCase):
    def test_reads_the_printed_id(self):
        done = mock.Mock(returncode=0, stdout=LTT + "\n")
        with mock.patch("fresh_tube.resolve.run_capped", return_value=done) as run:
            self.assertEqual(resolve.ytdlp_channel_id("https://www.youtube.com/@x"), LTT)
        self.assertEqual(run.call_args.args[0][:2], ["yt-dlp", "--flat-playlist"])
        self.assertEqual(run.call_args.kwargs["timeout"], 20)
        self.assertEqual(run.call_args.kwargs["max_bytes"], limits.YTDLP_MAX_BYTES)

    def test_missing_or_failing_ytdlp_is_none(self):
        with mock.patch("fresh_tube.resolve.run_capped", side_effect=FileNotFoundError):
            self.assertIsNone(resolve.ytdlp_channel_id("https://www.youtube.com/@x"))
        with mock.patch("fresh_tube.resolve.run_capped", side_effect=FreshTubeError("output is larger than 1 bytes", NETWORK)):
            self.assertIsNone(resolve.ytdlp_channel_id("https://www.youtube.com/@x"))
        with mock.patch("fresh_tube.resolve.run_capped", return_value=mock.Mock(returncode=1, stdout="NA\n")):
            self.assertIsNone(resolve.ytdlp_channel_id("https://www.youtube.com/@x"))
        with mock.patch("fresh_tube.resolve.run_capped", return_value=mock.Mock(returncode=0, stdout="NA\n")):
            self.assertIsNone(resolve.ytdlp_channel_id("https://www.youtube.com/@x"))
