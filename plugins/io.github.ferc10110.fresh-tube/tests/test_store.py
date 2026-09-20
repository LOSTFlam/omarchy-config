import os
import threading
import time
import unittest

import support
from fresh_tube import store
from fresh_tube.errors import DUPLICATE, PIN_LIMIT, UNKNOWN, USAGE, FreshTubeError

LTT = "UCXuqSBlHAE6Xw-yeJA0Tunw"


class StoreTest(unittest.TestCase):
    def setUp(self):
        self.box = support.Sandbox()
        self.box.apply()
        self.addCleanup(self.box.cleanup)


class Paths(StoreTest):
    def test_paths_follow_xdg(self):
        self.assertEqual(store.channels_path(), self.box.channels_file)
        self.assertEqual(store.state_path(), self.box.state_file)

    def test_paths_fall_back_to_home(self):
        os.environ["XDG_CONFIG_HOME"] = ""
        os.environ["XDG_STATE_HOME"] = ""
        self.assertEqual(store.channels_path(),
                         os.path.join(self.box.home, ".config", "fresh-tube", "channels.json"))
        self.assertEqual(store.state_path(),
                         os.path.join(self.box.home, ".local", "state", "fresh-tube", "state.json"))

    def test_now_iso_is_utc_with_offset(self):
        self.assertRegex(store.now_iso(), r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\+00:00$")


class Channels(StoreTest):
    def test_missing_file_is_empty(self):
        self.assertEqual(store.load_channels(), [])

    def test_add_save_and_reload(self):
        channels = []
        added = store.add_channel(channels, LTT, "Linus Tech Tips")
        self.assertEqual(added["id"], LTT)
        self.assertEqual(added["name"], "Linus Tech Tips")
        self.assertEqual(added["url"], "https://www.youtube.com/channel/" + LTT)
        self.assertRegex(added["addedAt"], r"^\d{4}-\d\d-\d\dT")
        store.save_channels(channels)
        self.assertEqual(store.load_channels(), [added])
        self.assertEqual(self.box.read_json(self.box.channels_file)["version"], 1)
        self.assertEqual(store.find_channel(channels, LTT), added)
        self.assertIsNone(store.find_channel(channels, "UCnothere0000000000000xx"))

    def test_duplicate_is_refused(self):
        channels = [store.add_channel([], LTT, "LTT")]
        with self.assertRaises(FreshTubeError) as caught:
            store.add_channel(channels, LTT, "Again")
        self.assertEqual(caught.exception.code, DUPLICATE)
        self.assertEqual(len(channels), 1)

    def test_remove(self):
        channels = [store.add_channel([], LTT, "LTT")]
        self.assertEqual(store.remove_channel(channels, LTT), [])
        with self.assertRaises(FreshTubeError) as caught:
            store.remove_channel(channels, LTT)
        self.assertEqual(caught.exception.code, UNKNOWN)

    def test_corrupt_file_is_reported_not_overwritten(self):
        os.makedirs(os.path.dirname(self.box.channels_file))
        with open(self.box.channels_file, "w") as f:
            f.write("{not json")
        with self.assertRaises(FreshTubeError) as caught:
            store.load_channels()
        self.assertIn("channels.json", str(caught.exception))
        with open(self.box.channels_file) as f:
            self.assertEqual(f.read(), "{not json")

    def test_write_is_atomic_and_leaves_no_temp_files(self):
        store.save_channels([])
        folder = os.path.dirname(self.box.channels_file)
        self.assertEqual(os.listdir(folder), ["channels.json"])


PARSED = {"name": "Example",
          "latest": {"videoId": "new", "title": "New", "published": "2026-09-15T17:00:03+00:00",
                     "thumbnail": "https://i/new.jpg"},
          "recent": ["new", "old"]}


class State(StoreTest):
    def test_missing_state_has_defaults(self):
        self.assertEqual(store.load_state(), {"version": 1, "seen": [], "feeds": {}, "fetchedAt": "",
                                              "prefs": {"width": 420, "height": 520, "pinned": False},
                                              "pins": [], "queue": []})

    def test_save_and_reload(self):
        state = store.load_state()
        store.mark_seen(state, "abc")
        store.save_state(state)
        self.assertEqual(store.load_state()["seen"], ["abc"])

    def test_mark_seen_is_idempotent(self):
        state = store.load_state()
        store.mark_seen(state, "abc")
        store.mark_seen(state, "abc")
        self.assertEqual(state["seen"], ["abc"])

    def test_prefs_validation(self):
        state = store.load_state()
        self.assertEqual(store.set_pref(state, "width", "500")["width"], 500)
        self.assertEqual(store.set_pref(state, "height", "300")["height"], 300)
        self.assertIs(store.set_pref(state, "pinned", "true")["pinned"], True)
        self.assertIs(store.set_pref(state, "pinned", "False")["pinned"], False)
        for key, value in (("width", "10"), ("width", "abc"), ("height", "99999"),
                           ("pinned", "maybe"), ("color", "red")):
            with self.assertRaises(FreshTubeError, msg=(key, value)) as caught:
                store.set_pref(state, key, value)
            self.assertEqual(caught.exception.code, USAGE)

    def test_partial_prefs_are_completed(self):
        self.box.write_json(self.box.state_file, {"version": 1, "prefs": {"width": 600}})
        self.assertEqual(store.load_state()["prefs"], {"width": 600, "height": 520, "pinned": False})

    def test_invalid_saved_prefs_fall_back_to_defaults(self):
        # Corrupted or hand-edited state.json with invalid pref values must not corrupt the popup.
        self.box.write_json(self.box.state_file, {"version": 1, "prefs": {"width": "banana", "height": 999999, "pinned": "yes"}})
        self.assertEqual(store.load_state()["prefs"], store.DEFAULT_PREFS)
        # Also confirm that a valid partial dict still survives.
        self.box.write_json(self.box.state_file, {"version": 1, "prefs": {"width": 640, "height": 300}})
        self.assertEqual(store.load_state()["prefs"], {"width": 640, "height": 300, "pinned": False})


class Feeds(StoreTest):
    def test_update_feed_and_error_keep_cache(self):
        state = store.load_state()
        store.update_feed(state, "UC1", PARSED, "2026-09-16T10:00:00+00:00")
        self.assertEqual(state["feeds"]["UC1"], {"fetchedAt": "2026-09-16T10:00:00+00:00", "lastError": "",
                                                 "source": "feed", "latest": PARSED["latest"],
                                                 "recent": ["new", "old"]})
        store.update_feed(state, "UC3", PARSED, "2026-09-16T10:00:00+00:00", "yt-dlp")
        self.assertEqual(state["feeds"]["UC3"]["source"], "yt-dlp")
        store.set_feed_error(state, "UC1", "timed out")
        self.assertEqual(state["feeds"]["UC1"]["lastError"], "timed out")
        self.assertEqual(state["feeds"]["UC1"]["latest"], PARSED["latest"])
        store.set_feed_error(state, "UC2", "timed out")
        self.assertEqual(state["feeds"]["UC2"], {"fetchedAt": "", "lastError": "timed out",
                                                 "latest": None, "recent": []})
        store.drop_feed(state, "UC1")
        self.assertNotIn("UC1", state["feeds"])

    def test_prune_keeps_only_ids_still_in_a_feed(self):
        state = store.load_state()
        store.update_feed(state, "UC1", PARSED, "2026-09-16T10:00:00+00:00")
        state["seen"] = ["new", "gone", "old"]
        store.prune_seen(state)
        self.assertEqual(state["seen"], ["new", "old"])

    def test_unseen_videos_one_per_channel_newest_first(self):
        state = store.load_state()
        channels = [{"id": "UC1", "name": "One"}, {"id": "UC2", "name": "Two"}, {"id": "UC3", "name": "Three"}]
        store.update_feed(state, "UC1", PARSED, "2026-09-16T10:00:00+00:00")
        later = dict(PARSED, latest=dict(PARSED["latest"], videoId="later", published="2026-09-16T09:00:00+00:00"))
        store.update_feed(state, "UC2", later, "2026-09-16T10:00:00+00:00")
        # UC3 has no cache yet and must simply be absent.
        videos = store.unseen_videos(state, channels)
        self.assertEqual([v["videoId"] for v in videos], ["later", "new"])
        self.assertEqual(videos[0]["channel"], "Two")
        self.assertEqual(videos[0]["channelId"], "UC2")
        self.assertEqual(videos[0]["url"], "https://www.youtube.com/watch?v=later")
        self.assertEqual(videos[1]["thumbnail"], "https://i/new.jpg")
        store.mark_seen(state, "later")
        self.assertEqual([v["videoId"] for v in store.unseen_videos(state, channels)], ["new"])

    @staticmethod
    def pin(video_id, channel_id="UC1"):
        return {"videoId": video_id, "title": "T " + video_id, "channelId": channel_id, "channel": "One",
                "published": "2026-09-15T10:00:00+00:00", "thumbnail": "", "url": store.WATCH_URL.format(video_id)}

    def test_pins_are_capped_at_three_and_survive_reload(self):
        state = store.load_state()
        for n in range(3):
            store.pin_video(state, self.pin(f"p{n}"))
        with self.assertRaises(FreshTubeError) as caught:
            store.pin_video(state, self.pin("p3"))
        self.assertEqual(caught.exception.code, PIN_LIMIT)
        self.assertEqual(str(caught.exception), "Pin limit reached (3)")
        store.pin_video(state, self.pin("p1"))  # already pinned: no-op, no error
        store.save_state(state)
        self.assertEqual([p["videoId"] for p in store.load_state()["pins"]], ["p0", "p1", "p2"])

    def test_unpin(self):
        state = store.load_state()
        store.pin_video(state, self.pin("p0"))
        self.assertEqual(store.unpin_video(state, "p0"), [])
        with self.assertRaises(FreshTubeError) as caught:
            store.unpin_video(state, "p0")
        self.assertEqual(caught.exception.code, UNKNOWN)
        self.assertEqual(str(caught.exception), "That video is not pinned")

    def test_invalid_saved_pins_are_dropped_on_load(self):
        self.box.write_json(self.box.state_file, {"pins": [self.pin("ok"), {"title": "no id"}, "junk",
                                                           {"videoId": ""}, self.pin("a"), self.pin("b"),
                                                           self.pin("c")]})
        self.assertEqual([p["videoId"] for p in store.load_state()["pins"]], ["ok", "a", "b"])

    def test_pinned_videos_are_not_new_and_not_pruned(self):
        channels = [{"id": "UC1", "name": "One"}]
        state = store.load_state()
        store.update_feed(state, "UC1", {"name": "One", "latest": {"videoId": "v1", "title": "First",
                                          "published": "2026-09-15T10:00:00+00:00", "thumbnail": "th"},
                                          "recent": ["v1"]}, "t1")
        video = store.find_latest(state, channels, "v1")
        self.assertEqual(video, {"videoId": "v1", "title": "First", "channelId": "UC1", "channel": "One",
                                 "published": "2026-09-15T10:00:00+00:00", "thumbnail": "th",
                                 "url": "https://www.youtube.com/watch?v=v1"})
        self.assertIsNone(store.find_latest(state, channels, "nope"))
        store.pin_video(state, video)
        self.assertEqual(store.unseen_videos(state, channels), [])
        self.assertEqual(store.pinned_videos(state), [video])
        store.mark_seen(state, "v1")
        store.update_feed(state, "UC1", {"name": "One", "latest": {"videoId": "v2", "title": "Second",
                                          "published": "2026-09-16T10:00:00+00:00", "thumbnail": ""},
                                          "recent": ["v2"]}, "t2")
        store.prune_seen(state)
        self.assertEqual(state["seen"], ["v1"])
        store.unpin_video(state, "v1")
        store.prune_seen(state)
        self.assertEqual(state["seen"], [])
        self.assertEqual([v["videoId"] for v in store.unseen_videos(state, channels)], ["v2"])


META = {"title": "A title", "channel": "Some Channel", "thumbnail": "https://i.ytimg.com/vi/v1/hqdefault.jpg"}


class Queue(StoreTest):
    def record(self, video_id):
        return store.queue_record(video_id, META)

    def test_record_shape(self):
        record = self.record("v1")
        self.assertEqual(record["videoId"], "v1")
        self.assertEqual(record["url"], "https://www.youtube.com/watch?v=v1")
        self.assertEqual((record["title"], record["channel"], record["thumbnail"]),
                         ("A title", "Some Channel", META["thumbnail"]))
        self.assertRegex(record["addedAt"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\+00:00$")

    def test_add_keeps_order_and_rejects_duplicates(self):
        state = store.load_state()
        self.assertEqual(state["queue"], [])
        store.queue_add(state, self.record("v1"))
        store.queue_add(state, self.record("v2"))
        self.assertEqual(store.queue_ids(state), ["v1", "v2"])
        with self.assertRaises(FreshTubeError) as caught:
            store.queue_add(state, self.record("v1"))
        self.assertEqual(str(caught.exception), "Already in the list")
        self.assertEqual(caught.exception.code, DUPLICATE)

    def test_move_clamps_to_the_ends(self):
        state = store.load_state()
        for video_id in ("v1", "v2", "v3"):
            store.queue_add(state, self.record(video_id))
        store.queue_move(state, "v3", 0)
        self.assertEqual(store.queue_ids(state), ["v3", "v1", "v2"])
        store.queue_move(state, "v3", 99)
        self.assertEqual(store.queue_ids(state), ["v1", "v2", "v3"])
        store.queue_move(state, "v2", -5)
        self.assertEqual(store.queue_ids(state), ["v2", "v1", "v3"])
        store.queue_move(state, "v1", 1)
        self.assertEqual(store.queue_ids(state), ["v2", "v1", "v3"])
        with self.assertRaises(FreshTubeError) as caught:
            store.queue_move(state, "nope", 0)
        self.assertEqual(str(caught.exception), "Not in the list")
        self.assertEqual(caught.exception.code, UNKNOWN)

    def test_remove_reports_whether_it_was_there(self):
        state = store.load_state()
        store.queue_add(state, self.record("v1"))
        self.assertTrue(store.queue_remove(state, "v1"))
        self.assertFalse(store.queue_remove(state, "v1"))
        self.assertEqual(state["queue"], [])

    def test_queue_survives_save_and_load_in_order(self):
        state = store.load_state()
        for video_id in ("v2", "v1"):
            store.queue_add(state, self.record(video_id))
        store.save_state(state)
        self.assertEqual(store.queue_ids(store.load_state()), ["v2", "v1"])

    def test_load_drops_bad_entries_and_duplicates(self):
        self.box.write_json(self.box.state_file, {
            "version": 1, "queue": [{"videoId": "v1", "title": "one"}, "junk", {"title": "no id"},
                                    {"videoId": ""}, {"videoId": "v1", "title": "dup"}, {"videoId": "v2"}]})
        self.assertEqual([q["videoId"] for q in store.load_state()["queue"]], ["v1", "v2"])
        self.assertEqual(store.load_state()["queue"][0]["title"], "one")
        self.box.write_json(self.box.state_file, {"version": 1, "queue": "nope"})
        self.assertEqual(store.load_state()["queue"], [])

    def test_queue_does_not_affect_unseen_or_pins(self):
        state = store.load_state()
        store.update_feed(state, "UC1", PARSED, "2026-09-16T10:00:00+00:00")
        store.queue_add(state, self.record(PARSED["latest"]["videoId"]))
        channels = [{"id": "UC1", "name": "One"}]
        self.assertEqual([v["videoId"] for v in store.unseen_videos(state, channels)], [PARSED["latest"]["videoId"]])
        store.mark_seen(state, PARSED["latest"]["videoId"])
        self.assertEqual(store.unseen_videos(state, channels), [])
        self.assertEqual(store.queue_ids(state), [PARSED["latest"]["videoId"]])


class Transactions(StoreTest):
    def test_overlapping_transactions_both_land(self):
        started = threading.Event()

        def slow_writer():
            with store.state_transaction() as state:
                started.set()
                time.sleep(0.3)
                store.mark_seen(state, "slow")

        worker = threading.Thread(target=slow_writer)
        worker.start()
        self.assertTrue(started.wait(2))
        with store.state_transaction() as state:  # blocks until the slow writer has saved
            store.mark_seen(state, "fast")
        worker.join(2)
        self.assertEqual(sorted(store.load_state()["seen"]), ["fast", "slow"])

    def test_failed_transaction_saves_nothing(self):
        with self.assertRaises(FreshTubeError):
            with store.state_transaction() as state:
                store.mark_seen(state, "x")
                raise FreshTubeError("boom")
        self.assertEqual(store.load_state()["seen"], [])


class PlayerPrefs(StoreTest):
    def test_player_size_is_absent_until_set(self):
        state = store.load_state()
        self.assertNotIn("playerWidth", state["prefs"])
        store.set_pref(state, "playerWidth", "860")
        store.set_pref(state, "playerHeight", "484")
        store.save_state(state)
        prefs = store.load_state()["prefs"]
        self.assertEqual((prefs["playerWidth"], prefs["playerHeight"]), (860, 484))

    def test_player_size_limits(self):
        state = store.load_state()
        with self.assertRaises(FreshTubeError) as caught:
            store.set_pref(state, "playerWidth", "100")
        self.assertIn("between 200 and 8000", str(caught.exception))
        self.assertEqual(caught.exception.code, USAGE)
        self.box.write_json(self.box.state_file, {"version": 1, "prefs": {"playerWidth": 9999, "playerHeight": "x"}})
        self.assertNotIn("playerWidth", store.load_state()["prefs"])
        self.assertNotIn("playerHeight", store.load_state()["prefs"])

    def test_set_prefs_is_all_or_nothing(self):
        state = store.load_state()
        prefs = store.set_prefs(state, [("playerWidth", "860"), ("playerHeight", "484")])
        self.assertEqual((prefs["playerWidth"], prefs["playerHeight"]), (860, 484))
        with self.assertRaises(FreshTubeError):
            store.set_prefs(state, [("playerWidth", "900"), ("playerHeight", "10")])
        self.assertEqual((state["prefs"]["playerWidth"], state["prefs"]["playerHeight"]), (860, 484))


class BrowserPrefs(StoreTest):
    def test_browser_size_limits(self):
        state = store.load_state()
        store.set_prefs(state, [("browserWidth", "640"), ("browserHeight", "360")])
        store.save_state(state)
        prefs = store.load_state()["prefs"]
        self.assertEqual((prefs["browserWidth"], prefs["browserHeight"]), (640, 360))
        with self.assertRaises(FreshTubeError) as caught:
            store.set_pref(state, "browserHeight", "9999")
        self.assertIn("between 200 and 8000", str(caught.exception))
        self.assertEqual(caught.exception.code, USAGE)
