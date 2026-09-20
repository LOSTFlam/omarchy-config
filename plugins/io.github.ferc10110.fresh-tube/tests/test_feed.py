import http.client
import io
import unittest
import urllib.error
from unittest import mock

import support
from fresh_tube import feed, limits
from fresh_tube.errors import NETWORK, FreshTubeError


class Parse(unittest.TestCase):
    def test_parses_name_latest_by_date_and_recent_ids(self):
        parsed = feed.parse_feed(support.fixture("feed.xml"))
        self.assertEqual(parsed["name"], "Example Channel")
        self.assertEqual(parsed["latest"], {"videoId": "newest22222", "title": "Newest video",
                                            "published": "2026-09-15T17:00:03+00:00",
                                            "thumbnail": "https://i.ytimg.com/vi/newest22222/hqdefault.jpg"})
        self.assertEqual(parsed["recent"], ["older111111", "newest22222", "middle33333"])

    def test_empty_feed_has_no_latest(self):
        xml = b'<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"><title>Quiet</title></feed>'
        self.assertEqual(feed.parse_feed(xml), {"name": "Quiet", "latest": None, "recent": []})

    def test_entry_without_thumbnail_still_counts(self):
        xml = (b'<feed xmlns="http://www.w3.org/2005/Atom" xmlns:yt="http://www.youtube.com/xml/schemas/2015">'
               b'<title>T</title><entry><yt:videoId>abc</yt:videoId><title>A</title>'
               b'<published>2026-01-01T00:00:00+00:00</published></entry></feed>')
        self.assertEqual(feed.parse_feed(xml)["latest"]["thumbnail"], "")

    def test_invalid_xml_is_a_network_error(self):
        with self.assertRaises(FreshTubeError) as caught:
            feed.parse_feed(b"<html>not a feed")
        self.assertEqual(caught.exception.code, NETWORK)


class Fetch(unittest.TestCase):
    def test_feed_url(self):
        self.assertEqual(feed.feed_url("UC1"), "https://www.youtube.com/feeds/videos.xml?channel_id=UC1")

    def test_fetch_feed_uses_fetch_url(self):
        with mock.patch("fresh_tube.feed.fetch_url", return_value=support.fixture("feed.xml")) as fetch:
            parsed = feed.fetch_feed("UC1", timeout=3)
        fetch.assert_called_once_with("https://www.youtube.com/feeds/videos.xml?channel_id=UC1", 3, limits.FEED_MAX_BYTES)
        self.assertEqual(parsed["latest"]["videoId"], "newest22222")

    def test_http_errors_become_network_errors_and_are_closed(self):
        raised = []

        def boom(request, timeout):
            raised.append(urllib.error.HTTPError(request.full_url, 404, "Not Found", {}, io.BytesIO(b"")))
            raise raised[-1]
        with mock.patch("fresh_tube.feed.urlopen", boom):
            with self.assertRaises(FreshTubeError) as caught:
                feed.fetch_url("https://example.invalid/x", 1, 100)
        self.assertEqual(caught.exception.code, NETWORK)
        self.assertIn("404", str(caught.exception))
        self.assertTrue(raised[0].fp.closed)

    def test_unreachable_host_is_a_network_error(self):
        def boom(request, timeout):
            raise urllib.error.URLError("no route")
        with mock.patch("fresh_tube.feed.urlopen", boom):
            with self.assertRaises(FreshTubeError) as caught:
                feed.fetch_url("https://example.invalid/x", 1, 100)
        self.assertEqual(caught.exception.code, NETWORK)

    def test_incomplete_read_is_a_network_error(self):
        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

            def read(self, n=-1):
                raise http.client.IncompleteRead(b"")

        def capture(request, timeout):
            return Response()
        with mock.patch("fresh_tube.feed.urlopen", capture):
            with self.assertRaises(FreshTubeError) as caught:
                feed.fetch_url("https://example.invalid/x", 1, 100)
        self.assertEqual(caught.exception.code, NETWORK)

    def test_request_carries_a_browser_user_agent(self):
        seen = {}

        class Response:
            body = io.BytesIO(b"body")

            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

            def read(self, n=-1):
                return self.body.read(n)

        def capture(request, timeout):
            seen["ua"] = request.get_header("User-agent")
            seen["timeout"] = timeout
            return Response()
        with mock.patch("fresh_tube.feed.urlopen", capture):
            self.assertEqual(feed.fetch_url("https://example.invalid/x", 7, 100), b"body")
        self.assertIn("Mozilla", seen["ua"])
        self.assertEqual(seen["timeout"], 7)

    def test_an_answer_over_the_cap_is_a_network_error(self):
        served = []

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

            def read(self, n=-1):
                assert n > 0, "an unbounded read"
                served.append(n)
                return b"x" * n

        with mock.patch("fresh_tube.feed.urlopen", lambda request, timeout: Response()):
            with self.assertRaises(FreshTubeError) as caught:
                feed.fetch_url("https://example.invalid/x", 1, 10)
        self.assertEqual(caught.exception.code, NETWORK)
        self.assertEqual(str(caught.exception), "Answer from https://example.invalid/x is larger than 10 bytes")
        self.assertEqual(sum(served), 11)
