import os
import subprocess
import sys
import tempfile
import time
import unittest

import support  # noqa: F401  (puts lib/ on sys.path)
from fresh_tube import limits
from fresh_tube.errors import NETWORK, FreshTubeError


class Stream:
    """A response body that hands out `step` bytes at most per read; endless when `body` is None."""

    def __init__(self, body=None, step=None):
        self.body, self.step, self.served = body, step, 0

    def read(self, n):
        assert n > 0, "an unbounded read"
        if self.step:
            n = min(n, self.step)
        chunk = b"x" * n if self.body is None else self.body[self.served:self.served + n]
        self.served += len(chunk)
        return chunk


class Caps(unittest.TestCase):
    def test_every_cap_is_a_fixed_positive_size(self):
        for name in ("FEED_MAX_BYTES", "PAGE_MAX_BYTES", "OEMBED_MAX_BYTES", "YTDLP_MAX_BYTES"):
            self.assertIsInstance(getattr(limits, name), int, name)
            self.assertGreater(getattr(limits, name), 0, name)

    def test_caps_leave_room_for_real_answers(self):
        # Measured in 2026-09: feeds up to 45 KB, channel and watch pages up to 2 MB.
        self.assertGreaterEqual(limits.FEED_MAX_BYTES, 20 * 45_000)
        self.assertGreaterEqual(limits.PAGE_MAX_BYTES, 4 * 2_000_000)


class ReadCapped(unittest.TestCase):
    def test_short_reads_are_joined(self):
        self.assertEqual(limits.read_capped(Stream(b"0123456789", step=3), 100, "x"), b"0123456789")

    def test_a_body_of_exactly_the_cap_is_fine(self):
        self.assertEqual(limits.read_capped(Stream(b"a" * 10), 10, "x"), b"a" * 10)

    def test_one_byte_over_the_cap_is_a_network_error(self):
        stream = Stream(b"a" * 11)
        with self.assertRaises(FreshTubeError) as caught:
            limits.read_capped(stream, 10, "Answer from there")
        self.assertEqual(caught.exception.code, NETWORK)
        self.assertEqual(str(caught.exception), "Answer from there is larger than 10 bytes")
        self.assertEqual(stream.served, 11)

    def test_an_endless_body_stops_at_the_cap_plus_one_byte(self):
        for step in (None, 7):
            stream = Stream(None, step=step)
            with self.assertRaises(FreshTubeError):
                limits.read_capped(stream, 1000, "x")
            self.assertEqual(stream.served, 1001)


def python(code):
    return [sys.executable, "-c", code]


class RunCapped(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.pid_file = os.path.join(self.tmp.name, "pid")

    def tearDown(self):
        self.tmp.cleanup()

    def writes_pid(self, code):
        return f"import os\nopen({self.pid_file!r}, 'w').write(str(os.getpid()))\n{code}"

    def assert_gone(self):
        with open(self.pid_file) as f:
            pid = int(f.read())
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def test_gives_exit_code_and_text_output(self):
        done = limits.run_capped(python("import sys; print('out é'); print('err', file=sys.stderr); sys.exit(3)"),
                                 timeout=10, max_bytes=100)
        self.assertEqual((done.returncode, done.stdout, done.stderr), (3, "out é\n", "err\n"))

    def test_stdout_over_the_cap_is_a_network_error(self):
        with self.assertRaises(FreshTubeError) as caught:
            limits.run_capped(python("print('x' * 100)"), timeout=10, max_bytes=50)
        self.assertEqual(caught.exception.code, NETWORK)
        self.assertEqual(str(caught.exception), "output is larger than 50 bytes")

    def test_stderr_counts_too(self):
        with self.assertRaises(FreshTubeError):
            limits.run_capped(python("import sys; print('x' * 100, file=sys.stderr)"), timeout=10, max_bytes=50)

    def test_endless_output_kills_the_process(self):
        code = self.writes_pid("import sys\nwhile True:\n    sys.stdout.write('x' * 4096)\n    sys.stdout.flush()")
        started = time.monotonic()
        with self.assertRaises(FreshTubeError):
            limits.run_capped(python(code), timeout=20, max_bytes=100_000)
        self.assertLess(time.monotonic() - started, 10)
        self.assert_gone()

    def test_timeout_kills_the_process(self):
        code = self.writes_pid("import time\ntime.sleep(30)")
        started = time.monotonic()
        with self.assertRaises(subprocess.TimeoutExpired):
            limits.run_capped(python(code), timeout=1, max_bytes=100)
        self.assertLess(time.monotonic() - started, 10)
        self.assert_gone()

    def test_missing_program_raises_like_subprocess(self):
        with self.assertRaises(FileNotFoundError):
            limits.run_capped(["/nonexistent/yt-dlp"], timeout=1, max_bytes=100)


if __name__ == "__main__":
    unittest.main()
