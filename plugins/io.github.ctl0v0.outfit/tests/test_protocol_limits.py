import io
import json
import unittest
from unittest import mock

from tests.test_outfit import OUTFIT as app


class ProtocolLimitsTests(unittest.TestCase):
    def test_wire_json_is_ascii_and_preserves_unicode(self):
        output = io.BytesIO()
        value = {"ok":True,"action":"search","generation":1,"name":"你好 ☃ 😀"}
        with mock.patch.object(app.sys,"stdout",mock.Mock(buffer=output)):
            app.write_response(value)
        raw = output.getvalue()
        self.assertTrue(raw.isascii())
        self.assertEqual(json.loads(raw),value)

    def test_oversized_unterminated_request_does_not_drain_or_execute_more_requests(self):
        source = io.BytesIO(b"x" * 100)
        cache, config = mock.Mock(), mock.Mock()
        with mock.patch.object(app,"MAX_REQUEST_BYTES",8), \
                mock.patch.object(app.sys,"stdin",mock.Mock(buffer=source)), \
                mock.patch.object(app,"open_stores",return_value=(cache,config)), \
                mock.patch.object(app,"write_response") as write, \
                mock.patch.object(app,"run") as execute:
            self.assertEqual(app.serve(),1)
        self.assertEqual(source.tell(),9)
        write.assert_called_once()
        self.assertFalse(write.call_args.args[0]["ok"])
        execute.assert_not_called()
        cache.close.assert_called_once()
        config.close.assert_called_once()
