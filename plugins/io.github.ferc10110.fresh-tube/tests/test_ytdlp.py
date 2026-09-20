import subprocess
import unittest
from unittest import mock

import support  # noqa: F401  (puts lib/ on sys.path)
from fresh_tube import limits, ytdlp
from fresh_tube.errors import NETWORK, FreshTubeError

OUTPUT = ("v1\tFirst video\t20260916\n"
          "v2\tSecond video\t20260915\n"
          "v3\tNo date\tNA\n"
          "#name\tExample Channel\n")


class Parse(unittest.TestCase):
    def test_first_entry_is_latest_with_iso_date_and_thumbnail(self):
        parsed = ytdlp.parse_output(OUTPUT)
        self.assertEqual(parsed["name"], "Example Channel")
        self.assertEqual(parsed["latest"], {"videoId": "v1", "title": "First video",
                                            "published": "2026-09-16T00:00:00+00:00",
                                            "thumbnail": "https://i.ytimg.com/vi/v1/hqdefault.jpg"})
        self.assertEqual(parsed["recent"], ["v1", "v2", "v3"])

    def test_missing_date_and_name_are_empty(self):
        parsed = ytdlp.parse_output("v3\tNo date\tNA\n")
        self.assertEqual(parsed["latest"]["published"], "")
        self.assertEqual(parsed["name"], "")

    def test_no_entries_means_no_latest(self):
        self.assertEqual(ytdlp.parse_output("#name\tEmpty\n"), {"name": "Empty", "latest": None, "recent": []})

    def test_lines_without_tabs_are_skipped(self):
        parsed = ytdlp.parse_output("WARNING: something\n\nv1\tTitle\t20260101\n")
        self.assertEqual(parsed["recent"], ["v1"])


class Fetch(unittest.TestCase):
    def run_patch(self, **kw):
        return mock.patch("fresh_tube.ytdlp.run_capped", **kw)

    def test_runs_ytdlp_on_the_videos_tab_and_parses(self):
        done = mock.Mock(returncode=0, stdout=OUTPUT, stderr="")
        with self.run_patch(return_value=done) as run:
            parsed = ytdlp.fetch_via_ytdlp("UC123")
        self.assertEqual(parsed["latest"]["videoId"], "v1")
        self.assertEqual(parsed["name"], "Example Channel")
        args = run.call_args.args[0]
        self.assertEqual(args[0], "yt-dlp")
        self.assertEqual(args[-1], "https://www.youtube.com/channel/UC123/videos")
        self.assertIn("--flat-playlist", args)
        self.assertIn("youtubetab:approximate_date", args)
        self.assertEqual(run.call_args.kwargs["timeout"], ytdlp.YTDLP_TIMEOUT)
        self.assertEqual(run.call_args.kwargs["max_bytes"], limits.YTDLP_MAX_BYTES)

    def test_failure_reports_the_last_error_line(self):
        done = mock.Mock(returncode=1, stdout="",
                         stderr="WARNING: x\nERROR: [youtube:tab] UC123: This channel does not exist.\n")
        with self.run_patch(return_value=done), self.assertRaises(FreshTubeError) as caught:
            ytdlp.fetch_via_ytdlp("UC123")
        self.assertEqual(caught.exception.code, NETWORK)
        self.assertEqual(str(caught.exception), "This channel does not exist.")

    def test_failure_without_error_line(self):
        done = mock.Mock(returncode=1, stdout="", stderr="")
        with self.run_patch(return_value=done), self.assertRaises(FreshTubeError) as caught:
            ytdlp.fetch_via_ytdlp("UC123")
        self.assertEqual(str(caught.exception), "exit code 1")

    def test_missing_binary(self):
        with self.run_patch(side_effect=FileNotFoundError), self.assertRaises(FreshTubeError) as caught:
            ytdlp.fetch_via_ytdlp("UC123")
        self.assertEqual(str(caught.exception), "not installed")
        self.assertEqual(caught.exception.code, NETWORK)

    def test_timeout(self):
        with self.run_patch(side_effect=subprocess.TimeoutExpired("yt-dlp", 40)), \
             self.assertRaises(FreshTubeError) as caught:
            ytdlp.fetch_via_ytdlp("UC123")
        self.assertEqual(str(caught.exception), "timed out")

    def test_output_over_the_cap(self):
        with self.run_patch(side_effect=FreshTubeError("output is larger than 1 bytes", NETWORK)), \
             self.assertRaises(FreshTubeError) as caught:
            ytdlp.fetch_via_ytdlp("UC123")
        self.assertEqual(str(caught.exception), "output is larger than 1 bytes")
        self.assertEqual(caught.exception.code, NETWORK)


if __name__ == "__main__":
    unittest.main()
