import socket
import unittest
import urllib.request

from fresh_tube import page

VID = "4_fM3Nv8BB0"


def fetch(port, path):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    return opener.open(f"http://127.0.0.1:{port}{path}", timeout=5)


class Html(unittest.TestCase):
    def test_embeds_the_player_full_window(self):
        html = page.page_html(VID, 4321)
        self.assertIn('src="https://www.youtube.com/embed/4_fM3Nv8BB0?autoplay=1"', html)
        self.assertIn('allow="autoplay', html)
        self.assertIn("allowfullscreen", html)
        self.assertIn("overflow:hidden", html)

    def test_title_names_the_video_and_the_port(self):
        self.assertEqual(page.window_title(VID, 4321), "Fresh Tube 4_fM3Nv8BB0 :4321")
        self.assertIn("<title>Fresh Tube 4_fM3Nv8BB0 :4321</title>", page.page_html(VID, 4321))


class Server(unittest.TestCase):
    def setUp(self):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(1)
        self.port = self.sock.getsockname()[1]
        self.server = page.serve(self.sock, VID)
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def test_serves_the_page_on_the_given_socket(self):
        with fetch(self.port, "/") as response:
            self.assertEqual(response.status, 200)
            self.assertEqual(response.headers["Content-Type"], "text/html; charset=utf-8")
            body = response.read().decode()
        self.assertIn("/embed/4_fM3Nv8BB0?autoplay=1", body)
        self.assertIn(f"<title>{page.window_title(VID, self.port)}</title>", body)

    def test_has_no_favicon(self):
        with fetch(self.port, "/favicon.ico") as response:
            self.assertEqual(response.status, 204)


if __name__ == "__main__":
    unittest.main()
