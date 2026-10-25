import importlib.util
from pathlib import Path
import socket
import struct
import unittest
from unittest.mock import MagicMock, patch

spec = importlib.util.spec_from_file_location("scanner_probe", Path(__file__).with_name("probe_scanner.py"))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class ScannerProbeTest(unittest.TestCase):
    def setUp(self):
        # Protocol tests use a fake socket on Windows too; runtime deployment is Linux.
        unix = patch.object(probe.socket, "AF_UNIX", 1, create=True)
        unix.start()
        self.addCleanup(unix.stop)

    def socket_with(self, chunks):
        endpoint = MagicMock()
        endpoint.__enter__.return_value = endpoint
        endpoint.recv.side_effect = chunks
        return endpoint

    def test_clean_result_uses_bounded_instream_and_null_terminator(self):
        endpoint = self.socket_with([b"stream: ", b"OK\x00"])
        with patch.object(probe.socket, "socket", return_value=endpoint):
            self.assertEqual("CLEAN", probe.scan("/run/test/socket", b"clean"))
        self.assertGreaterEqual(endpoint.settimeout.call_count, 3)
        self.assertTrue(all(0 < call.args[0] <= 5 for call in endpoint.settimeout.call_args_list))
        endpoint.sendall.assert_called_once_with(b"zINSTREAM\x00" + struct.pack("!I", 5) + b"clean" + b"\x00" * 4)

    def test_infected_result_is_explicit(self):
        with patch.object(probe.socket, "socket", return_value=self.socket_with([b"stream: Eicar-Signature FOUND\x00"])):
            self.assertEqual("INFECTED", probe.scan("/run/test/socket", b"test"))

    def test_incomplete_and_indefinite_response_never_become_clean(self):
        for chunks in ([b"stream: OK", b""], [b"stream: ERROR\x00"], [b"x" * 1025]):
            with self.subTest(chunks=chunks), patch.object(probe.socket, "socket", return_value=self.socket_with(chunks)):
                with self.assertRaises(ValueError):
                    probe.scan("/run/test/socket", b"test")

    def test_timeout_and_socket_unavailable_remain_errors(self):
        for failure in (socket.timeout("timeout"), ConnectionRefusedError("unavailable")):
            with self.subTest(failure=failure), patch.object(probe.socket, "socket", return_value=self.socket_with([failure])):
                with self.assertRaises(OSError):
                    probe.scan("/run/test/socket", b"test")

    def test_invalid_path_or_unbounded_content_is_rejected_before_connect(self):
        for endpoint, content in (("relative", b"test"), ("/run/test/socket", b""), ("/run/test/socket", b"x" * 8193)):
            with self.subTest(endpoint=endpoint, size=len(content)), self.assertRaises(ValueError):
                probe.scan(endpoint, content)

    def test_whole_exchange_deadline_does_not_reset_for_a_slow_reply(self):
        endpoint = self.socket_with([b"stream:", b" OK\x00"])
        with patch.object(probe.socket, "socket", return_value=endpoint), patch.object(probe.time, "monotonic", side_effect=[0, 0, 1, 2, 6]):
            with self.assertRaisesRegex(TimeoutError, "deadline"):
                probe.scan("/run/test/socket", b"test")


if __name__ == "__main__":
    unittest.main()
