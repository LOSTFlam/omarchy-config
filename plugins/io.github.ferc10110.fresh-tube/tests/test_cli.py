import http.client
import json
import unittest
from unittest import mock

import support
from fresh_tube import cli, store
from fresh_tube.errors import NETWORK, FreshTubeError


class CliTest(unittest.TestCase):
    def setUp(self):
        self.box = support.Sandbox()
        self.addCleanup(self.box.cleanup)

    def ok(self, *args, **kw):
        result = self.box.run(*args, **kw)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def json(self, *args, **kw):
        return json.loads(self.ok(*args, **kw))

    def fails(self, code, *args, **kw):
        result = self.box.run(*args, **kw)
        self.assertEqual(result.returncode, code, (result.stdout, result.stderr))
        if code != 2:
            self.assertTrue(result.stderr.startswith("fresh-tube: "), result.stderr)
        return result.stderr


class Usage(CliTest):
    def test_help_and_usage_errors(self):
        self.assertIn("fresh-tube", self.ok("-h"))
        self.fails(2, "nope")
        self.fails(2)


LTT = "UCXuqSBlHAE6Xw-yeJA0Tunw"


class Channels(CliTest):
    def setUp(self):
        super().setUp()
        self.box.apply()

    def add(self, text, page="channel_page.html"):
        with mock.patch("fresh_tube.resolve.fetch_url", return_value=support.fixture(page)), \
             mock.patch("fresh_tube.feed.fetch_url", return_value=support.fixture("feed.xml")), \
             mock.patch("fresh_tube.resolve.ytdlp_channel_id", return_value=None), \
             support.captured() as (out, err):
            code = cli.main(["add", "--", text])
        return code, out.getvalue(), err.getvalue()

    def add_with_no_source(self, text):
        with mock.patch("fresh_tube.resolve.fetch_url", return_value=support.fixture("channel_page.html")), \
             mock.patch("fresh_tube.feed.fetch_url", side_effect=FreshTubeError("HTTP 404 from feed", NETWORK)), \
             mock.patch("fresh_tube.ytdlp.fetch_via_ytdlp", side_effect=FreshTubeError("not installed", NETWORK)), \
             mock.patch("fresh_tube.resolve.ytdlp_channel_id", return_value=None), \
             support.captured() as (out, err):
            code = cli.main(["add", "--", text])
        return code, out.getvalue(), err.getvalue()

    def test_add_keeps_the_channel_when_no_source_answers(self):
        code, out, err = self.add_with_no_source("youtube.com/@LinusTechTips")
        self.assertEqual(code, 0, err)
        channel = json.loads(out)
        self.assertEqual(channel["id"], LTT)
        self.assertEqual(channel["name"], "@LinusTechTips")
        self.assertEqual(channel["lastError"], "feed: HTTP 404 from feed; yt-dlp: not installed")
        self.assertEqual(self.box.read_json(self.box.channels_file)["channels"][0]["id"], LTT)
        self.assertEqual(self.json("refresh", "--json", "--cached")["videos"], [])

    def test_add_without_a_handle_names_the_channel_by_id(self):
        code, out, err = self.add_with_no_source("https://www.youtube.com/channel/" + LTT)
        self.assertEqual(code, 0, err)
        self.assertEqual(json.loads(out)["name"], LTT)

    def test_refresh_fills_in_the_name_once_a_source_answers(self):
        self.add_with_no_source("@LinusTechTips")
        parsed = {"name": "Linus Tech Tips", "latest": {"videoId": "v9", "title": "Nine", "thumbnail": "t9",
                                                        "published": "2026-09-16T10:00:00+00:00"}, "recent": ["v9"]}
        with mock.patch("fresh_tube.feed.fetch_feed", return_value=parsed), \
             mock.patch("fresh_tube.ytdlp.fetch_via_ytdlp", side_effect=AssertionError("yt-dlp not expected")), \
             support.captured() as (out, err):
            self.assertEqual(cli.main(["refresh", "--json"]), 0, err.getvalue())
        self.assertEqual(json.loads(out.getvalue())["videos"][0]["channel"], "Linus Tech Tips")
        saved = self.box.read_json(self.box.channels_file)["channels"][0]
        self.assertEqual(saved["name"], "Linus Tech Tips")
        self.assertNotIn("namePending", saved)

    def test_add_prints_the_channel_and_caches_its_feed(self):
        code, out, err = self.add("@LinusTechTips")
        self.assertEqual(code, 0, err)
        channel = json.loads(out)
        self.assertEqual(channel["id"], LTT)
        self.assertEqual(channel["name"], "Example Channel")
        self.assertEqual(channel["lastError"], "")
        state = self.box.read_json(self.box.state_file)
        self.assertEqual(state["feeds"][LTT]["latest"]["videoId"], "newest22222")
        listed = self.json("channels", "--json")["channels"]
        self.assertEqual([c["id"] for c in listed], [LTT])
        self.assertIn("Example Channel", self.ok("channels"))

    def test_add_errors(self):
        self.assertEqual(self.add("https://vimeo.com/x")[0], 2)
        self.assertEqual(self.add("@Nobody", page="no_id_page.html")[0], 3)
        self.assertEqual(self.add("@LinusTechTips")[0], 0)
        code, out, err = self.add("https://www.youtube.com/channel/" + LTT)
        self.assertEqual(code, 4)
        self.assertEqual(err.strip(), "fresh-tube: Already added")
        self.assertEqual(len(self.json("channels", "--json")["channels"]), 1)

    def test_remove(self):
        self.add("@LinusTechTips")
        self.assertEqual(self.json("remove", LTT), {"removed": LTT})
        self.assertEqual(self.json("channels", "--json"), {"channels": []})
        self.assertNotIn(LTT, self.box.read_json(self.box.state_file)["feeds"])
        self.assertIn("No such channel", self.fails(5, "remove", LTT))


class Refresh(CliTest):
    def setUp(self):
        super().setUp()
        self.box.apply()
        self.channels = [{"id": "UC1", "name": "One", "url": "u1", "addedAt": "t"},
                         {"id": "UC2", "name": "Two", "url": "u2", "addedAt": "t"}]
        self.box.write_json(self.box.channels_file, {"version": 1, "channels": self.channels})

    @staticmethod
    def two_feeds(channel_id, timeout=10):
        if channel_id == "UC1":
            return {"name": "One", "latest": {"videoId": "v1", "title": "First", "thumbnail": "t1",
                                              "published": "2026-09-15T10:00:00+00:00"}, "recent": ["v1"]}
        return {"name": "Two", "latest": {"videoId": "v2", "title": "Second", "thumbnail": "t2",
                                          "published": "2026-09-16T10:00:00+00:00"}, "recent": ["v2"]}

    def refresh(self, *extra, fetch=None, ytdlp=None):
        with mock.patch("fresh_tube.feed.fetch_feed", side_effect=fetch or self.two_feeds), \
             mock.patch("fresh_tube.ytdlp.fetch_via_ytdlp",
                        side_effect=ytdlp or FreshTubeError("not installed", NETWORK)), \
             support.captured() as (out, err):
            code = cli.main(["refresh", "--json", *extra])
        self.assertEqual(code, 0, err.getvalue())
        return json.loads(out.getvalue())

    def test_live_refresh_lists_newest_first_and_caches(self):
        payload = self.refresh()
        self.assertEqual([v["videoId"] for v in payload["videos"]], ["v2", "v1"])
        self.assertEqual(payload["videos"][0]["channel"], "Two")
        self.assertEqual(payload["videos"][0]["url"], "https://www.youtube.com/watch?v=v2")
        self.assertFalse(payload["offline"])
        self.assertEqual(payload["channelCount"], 2)
        self.assertEqual(payload["errors"], [])
        self.assertRegex(payload["fetchedAt"], r"^\d{4}-")
        self.assertEqual(self.box.read_json(self.box.state_file)["feeds"]["UC1"]["latest"]["videoId"], "v1")

    def test_cached_refresh_needs_no_network(self):
        self.refresh()
        with mock.patch("fresh_tube.feed.fetch_feed", side_effect=AssertionError("network")), \
             support.captured() as (out, err):
            self.assertEqual(cli.main(["refresh", "--json", "--cached"]), 0, err.getvalue())
        payload = json.loads(out.getvalue())
        self.assertEqual([v["videoId"] for v in payload["videos"]], ["v2", "v1"])
        self.assertTrue(payload["offline"])

    def test_one_failing_channel_keeps_its_cache_and_reports(self):
        self.refresh()

        def flaky(channel_id, timeout=10):
            if channel_id == "UC2":
                raise FreshTubeError("HTTP 500 from feed", NETWORK)
            return self.two_feeds(channel_id)
        payload = self.refresh(fetch=flaky)
        self.assertEqual([v["videoId"] for v in payload["videos"]], ["v2", "v1"])
        self.assertFalse(payload["offline"])
        self.assertEqual(payload["errors"], [{"channelId": "UC2", "channel": "Two",
                                              "message": "feed: HTTP 500 from feed; yt-dlp: not installed"}])
        self.assertEqual(self.json("channels", "--json")["channels"][1]["lastError"],
                         "feed: HTTP 500 from feed; yt-dlp: not installed")
        # A later good fetch clears the error.
        self.assertEqual(self.refresh()["errors"], [])

    def test_one_channel_raising_an_unexpected_exception_does_not_abort_the_others(self):
        first = self.refresh()

        def flaky(channel_id, timeout=10):
            if channel_id == "UC2":
                raise http.client.IncompleteRead(b"")
            return self.two_feeds(channel_id)

        with mock.patch("fresh_tube.store.now_iso", return_value="2099-01-01T00:00:00+00:00"):
            payload = self.refresh(fetch=flaky)
        self.assertEqual([v["videoId"] for v in payload["videos"]], ["v2", "v1"])
        self.assertEqual(len(payload["errors"]), 1)
        self.assertEqual(payload["errors"][0]["channelId"], "UC2")
        self.assertIn("IncompleteRead", payload["errors"][0]["message"])
        self.assertEqual(self.box.read_json(self.box.state_file)["feeds"]["UC1"]["latest"]["videoId"], "v1")
        self.assertGreater(payload["fetchedAt"], first["fetchedAt"])

    def test_all_failing_is_offline_and_keeps_fetched_at(self):
        first = self.refresh()

        def down(channel_id, timeout=10):
            raise FreshTubeError("Could not reach", NETWORK)
        payload = self.refresh(fetch=down)
        self.assertTrue(payload["offline"])
        self.assertEqual(payload["fetchedAt"], first["fetchedAt"])
        self.assertEqual(len(payload["videos"]), 2)

    def test_seen_hides_the_video_and_prunes(self):
        self.refresh()
        self.assertEqual(self.json("seen", "v2"), {"seen": "v2"})
        self.assertEqual(self.json("seen", "v2"), {"seen": "v2"})
        self.assertEqual([v["videoId"] for v in self.refresh("--cached")["videos"]], ["v1"])

        def moved_on(channel_id, timeout=10):
            if channel_id == "UC2":
                return {"name": "Two", "latest": {"videoId": "v3", "title": "Third", "thumbnail": "t3",
                                                  "published": "2026-09-17T10:00:00+00:00"}, "recent": ["v3"]}
            return self.two_feeds(channel_id)
        payload = self.refresh(fetch=moved_on)
        self.assertEqual([v["videoId"] for v in payload["videos"]], ["v3", "v1"])
        self.assertEqual(self.box.read_json(self.box.state_file)["seen"], [])

    def test_feed_failure_falls_back_to_ytdlp(self):
        def down(channel_id, timeout=10):
            raise FreshTubeError("HTTP 404 from feed", NETWORK)
        payload = self.refresh(fetch=down, ytdlp=self.two_feeds)
        self.assertEqual([v["videoId"] for v in payload["videos"]], ["v2", "v1"])
        self.assertEqual(payload["errors"], [])
        self.assertFalse(payload["offline"])
        channels = self.json("channels", "--json")["channels"]
        self.assertEqual([c["source"] for c in channels], ["yt-dlp", "yt-dlp"])
        self.assertEqual([c["lastError"] for c in channels], ["", ""])

    def test_feed_success_never_runs_ytdlp(self):
        payload = self.refresh(ytdlp=AssertionError("yt-dlp not expected"))
        self.assertEqual(len(payload["videos"]), 2)
        self.assertEqual([c["source"] for c in self.json("channels", "--json")["channels"]], ["feed", "feed"])

    def test_both_sources_failing_names_both(self):
        def down(channel_id, timeout=10):
            raise FreshTubeError("HTTP 404 from feed", NETWORK)
        payload = self.refresh(fetch=down, ytdlp=FreshTubeError("This channel does not exist.", NETWORK))
        self.assertTrue(payload["offline"])
        self.assertEqual(payload["errors"][0]["message"],
                         "feed: HTTP 404 from feed; yt-dlp: This channel does not exist.")

    def test_no_channels(self):
        self.box.write_json(self.box.channels_file, {"version": 1, "channels": []})
        payload = self.refresh(fetch=mock.Mock(side_effect=AssertionError("network")))
        self.assertEqual(payload, {"videos": [], "pinned": [], "queue": [], "fetchedAt": "", "offline": False, "channelCount": 0, "errors": []})

    def test_plain_refresh_prints_one_line_per_video(self):
        with mock.patch("fresh_tube.feed.fetch_feed", side_effect=self.two_feeds), support.captured() as (out, err):
            self.assertEqual(cli.main(["refresh"]), 0)
        self.assertEqual(out.getvalue().splitlines(), ["Two: Second  https://www.youtube.com/watch?v=v2",
                                                       "One: First  https://www.youtube.com/watch?v=v1"])

    def test_cached_with_no_channels_is_not_offline(self):
        self.box.write_json(self.box.channels_file, {"version": 1, "channels": []})
        with mock.patch("fresh_tube.feed.fetch_feed", side_effect=AssertionError("network")), \
             support.captured() as (out, err):
            self.assertEqual(cli.main(["refresh", "--json", "--cached"]), 0, err.getvalue())
        payload = json.loads(out.getvalue())
        self.assertFalse(payload["offline"])
        self.assertEqual(payload["channelCount"], 0)
        self.assertEqual(payload["videos"], [])

    def test_prefs_written_during_fetch_survive_refresh(self):
        self.box.write_json(self.box.channels_file, {"version": 1, "channels": [self.channels[0]]})

        def pref_saver(channel_id, timeout=10):
            state = store.load_state()
            store.set_pref(state, "width", 777)
            store.save_state(state)
            return self.two_feeds(channel_id)

        with mock.patch("fresh_tube.feed.fetch_feed", side_effect=pref_saver), \
             support.captured() as (out, err):
            self.assertEqual(cli.main(["refresh", "--json"]), 0, err.getvalue())
        state = self.box.read_json(self.box.state_file)
        self.assertEqual(state["prefs"]["width"], 777)
        self.assertEqual(state["feeds"]["UC1"]["latest"]["videoId"], "v1")


class Prefs(CliTest):
    def test_get_and_set(self):
        self.assertEqual(self.json("prefs", "get"), {"width": 420, "height": 520, "pinned": False})
        self.assertEqual(self.json("prefs", "set", "width", "640")["width"], 640)
        self.assertEqual(self.json("prefs", "set", "pinned", "true")["pinned"], True)
        self.assertEqual(self.json("prefs", "get"), {"width": 640, "height": 520, "pinned": True})
        self.assertIn("between 220 and 4000", self.fails(2, "prefs", "set", "height", "10"))
        self.assertIn("Unknown preference", self.fails(2, "prefs", "set", "color", "red"))
        self.assertIn("needs a key and a value", self.fails(2, "prefs", "set", "width"))
        self.assertEqual(self.json("prefs", "set", "playerWidth", "860", "playerHeight", "484")["playerHeight"], 484)
        self.assertIn("between 200 and 8000", self.fails(2, "prefs", "set", "playerWidth", "900", "playerHeight", "10"))
        self.assertEqual(self.json("prefs", "get")["playerWidth"], 860)


class UnexpectedErrors(CliTest):
    def setUp(self):
        super().setUp()
        self.box.apply()

    def test_unexpected_error_prints_one_clean_line_and_exits_1(self):
        with mock.patch("fresh_tube.cli.store.load_channels", side_effect=RuntimeError("boom")), \
             support.captured() as (out, err):
            code = cli.main(["channels"])
        self.assertEqual(code, 1)
        self.assertIn("RuntimeError: boom", err.getvalue())


class Pins(CliTest):
    def setUp(self):
        super().setUp()
        self.box.apply()
        self.box.write_json(self.box.channels_file, {"version": 1, "channels": [
            {"id": "UC1", "name": "One", "url": "u1", "addedAt": "t"},
            {"id": "UC2", "name": "Two", "url": "u2", "addedAt": "t"}]})

    def refresh(self, *extra, fetch=None):
        with mock.patch("fresh_tube.feed.fetch_feed", side_effect=fetch or Refresh.two_feeds), \
             support.captured() as (out, err):
            code = cli.main(["refresh", "--json", *extra])
        self.assertEqual(code, 0, err.getvalue())
        return json.loads(out.getvalue())

    def call(self, *argv):
        with support.captured() as (out, err):
            code = cli.main(list(argv))
        return code, out.getvalue(), err.getvalue()

    def pin(self, video_id):
        code, out, err = self.call("pin", video_id)
        self.assertEqual(code, 0, err)
        return [p["videoId"] for p in json.loads(out)["pinned"]]

    def test_pin_moves_a_video_from_new_to_pinned_even_after_watching(self):
        self.refresh()
        self.assertEqual(self.pin("v2"), ["v2"])
        payload = self.refresh("--cached")
        self.assertEqual([v["videoId"] for v in payload["videos"]], ["v1"])
        self.assertEqual([p["videoId"] for p in payload["pinned"]], ["v2"])
        self.assertEqual(payload["pinned"][0]["channel"], "Two")
        self.assertEqual(payload["pinned"][0]["url"], "https://www.youtube.com/watch?v=v2")
        self.assertEqual(self.call("seen", "v2")[0], 0)
        self.assertEqual([p["videoId"] for p in self.refresh("--cached")["pinned"]], ["v2"])
        self.assertEqual(self.pin("v2"), ["v2"])  # re-pin is a no-op

    def test_pinned_video_survives_the_channel_moving_on_and_being_removed(self):
        self.refresh()
        self.pin("v2")

        def moved_on(channel_id, timeout=10):
            if channel_id == "UC2":
                return {"name": "Two", "latest": {"videoId": "v3", "title": "Third", "thumbnail": "",
                                                  "published": "2026-09-17T10:00:00+00:00"}, "recent": ["v3", "v2"]}
            return Refresh.two_feeds(channel_id, timeout)

        payload = self.refresh(fetch=moved_on)
        self.assertEqual([v["videoId"] for v in payload["videos"]], ["v3", "v1"])
        self.assertEqual([p["videoId"] for p in payload["pinned"]], ["v2"])
        self.assertEqual(self.pin("v2"), ["v2"])  # still pinnable although no longer the newest
        self.assertEqual(self.call("remove", "UC2")[0], 0)
        payload = self.refresh("--cached")
        self.assertEqual([v["videoId"] for v in payload["videos"]], ["v1"])
        self.assertEqual([p["videoId"] for p in payload["pinned"]], ["v2"])

    def test_unpin_applies_the_normal_rules(self):
        self.refresh()
        self.pin("v2")
        self.call("seen", "v2")
        code, out, err = self.call("unpin", "v2")
        self.assertEqual(code, 0, err)
        self.assertEqual(json.loads(out)["pinned"], [])
        self.assertEqual([v["videoId"] for v in self.refresh("--cached")["videos"]], ["v1"])
        self.pin("v1")
        self.assertEqual(self.call("unpin", "v1")[0], 0)
        self.assertEqual([v["videoId"] for v in self.refresh("--cached")["videos"]], ["v1"])

    def test_pin_errors(self):
        self.refresh()
        code, out, err = self.call("pin", "nope")
        self.assertEqual(code, 5)
        self.assertIn("No such video", err)
        code, out, err = self.call("unpin", "v1")
        self.assertEqual(code, 5)
        self.assertIn("That video is not pinned", err)
        state = store.load_state()
        for n in range(3):
            store.pin_video(state, {"videoId": f"p{n}", "title": "", "channelId": "UCx", "channel": "",
                                    "published": "", "thumbnail": "", "url": ""})
        store.save_state(state)
        code, out, err = self.call("pin", "v1")
        self.assertEqual(code, 6)
        self.assertIn("Pin limit reached (3)", err)
        self.assertEqual(len(store.load_state()["pins"]), 3)


META = {"title": "A title", "channel": "Some Channel", "thumbnail": "https://i.ytimg.com/vi/v/hqdefault.jpg"}
VID = "4_fM3Nv8BB0"


class Queue(CliTest):
    def setUp(self):
        super().setUp()
        self.box.apply()

    def add(self, text, meta=None, error=None):
        kw = {"side_effect": error} if error else {"return_value": meta or META}
        with mock.patch("fresh_tube.videos.fetch_metadata", **kw), support.captured() as (out, err):
            code = cli.main(["queue", "add", "--", text])
        return code, out.getvalue(), err.getvalue()

    def test_add_prints_the_record_and_appends(self):
        code, out, err = self.add("https://youtu.be/" + VID)
        self.assertEqual(code, 0, err)
        record = json.loads(out)
        self.assertEqual((record["videoId"], record["title"], record["channel"]), (VID, "A title", "Some Channel"))
        self.assertEqual(record["url"], "https://www.youtube.com/watch?v=" + VID)
        code, out, err = self.add("abcdefghijk", meta=dict(META, title="Second"))
        self.assertEqual(code, 0, err)
        self.assertEqual([q["videoId"] for q in self.json("queue", "--json")["queue"]], [VID, "abcdefghijk"])

    def test_add_rejects_non_videos_and_duplicates(self):
        with mock.patch("fresh_tube.videos.fetch_metadata", side_effect=AssertionError("no lookup")):
            with support.captured() as (out, err):
                self.assertEqual(cli.main(["queue", "add", "--", "https://www.youtube.com/@LinusTechTips"]), 2)
            self.assertIn("That doesn't look like a YouTube video", err.getvalue())
        self.add(VID)
        with mock.patch("fresh_tube.videos.fetch_metadata", side_effect=AssertionError("no lookup")):
            with support.captured() as (out, err):
                self.assertEqual(cli.main(["queue", "add", "--", VID]), 4)
            self.assertIn("Already in the list", err.getvalue())

    def test_add_without_metadata_is_a_network_error(self):
        code, out, err = self.add(VID, error=FreshTubeError("oembed: HTTP 404; yt-dlp: not installed", NETWORK))
        self.assertEqual(code, 3)
        self.assertIn("oembed: HTTP 404; yt-dlp: not installed", err)
        self.assertEqual(self.json("queue", "--json"), {"queue": []})

    def test_move_and_plain_listing(self):
        self.add("v1v1v1v1v1v")
        self.add("v2v2v2v2v2v", meta=dict(META, title="Two"))
        payload = self.json("queue", "move", "--", "v2v2v2v2v2v", "0")
        self.assertEqual([q["videoId"] for q in payload["queue"]], ["v2v2v2v2v2v", "v1v1v1v1v1v"])
        self.assertIn("Not in the list", self.fails(5, "queue", "move", "--", "nope", "0"))
        self.assertIn("whole number", self.fails(2, "queue", "move", "--", "v1v1v1v1v1v", "x"))
        self.assertEqual(self.ok("queue").splitlines()[0], "Some Channel: Two  https://www.youtube.com/watch?v=v2v2v2v2v2v")

    def test_done_removes_and_marks_seen_idempotently(self):
        self.add(VID)
        self.assertEqual(self.json("done", "--", VID), {"done": VID, "removed": True})
        self.assertEqual(self.json("done", "--", VID), {"done": VID, "removed": False})
        self.assertEqual(self.json("queue", "--json"), {"queue": []})
        self.assertIn(VID, self.box.read_json(self.box.state_file)["seen"])

    def test_refresh_payload_carries_the_queue(self):
        self.add(VID)
        self.box.write_json(self.box.channels_file, {"version": 1, "channels": []})
        with mock.patch("fresh_tube.feed.fetch_feed", side_effect=AssertionError("network")), \
             support.captured() as (out, err):
            self.assertEqual(cli.main(["refresh", "--json", "--cached"]), 0, err.getvalue())
        self.assertEqual([q["videoId"] for q in json.loads(out.getvalue())["queue"]], [VID])
