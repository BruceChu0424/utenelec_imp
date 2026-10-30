"""Endpoint embedding checks for formal Windows client bundles."""
import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "verify_client_endpoints", Path(__file__).with_name("verify_client_endpoints.py"))
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


def write_snapshot(directory: Path, *urls: str) -> Path:
    data = directory / "data"
    data.mkdir()
    snapshot = data / "app.so"
    snapshot.write_bytes(b"\x00".join(url.encode("utf-8") for url in urls) + b"\x00")
    return snapshot


class EndpointEmbeddingTest(unittest.TestCase):
    def test_reports_missing_endpoint(self):
        with tempfile.TemporaryDirectory() as tmp:
            snapshot = write_snapshot(Path(tmp), "https://erp.utenelec.lan/api")
            missing = verify.missing_endpoints(snapshot, [
                "https://erp.utenelec.lan/api", "https://justplayit.cn/api"])
        self.assertEqual(missing, ["https://justplayit.cn/api"])

    def test_passes_when_every_required_url_is_embedded(self):
        with tempfile.TemporaryDirectory() as tmp:
            snapshot = write_snapshot(Path(tmp), "https://erp.utenelec.lan/api",
                                      "https://justplayit.cn/api")
            self.assertEqual(
                verify.missing_endpoints(snapshot, [
                    "https://erp.utenelec.lan/api", "https://justplayit.cn/api"]), [])

    def test_rejects_unknown_bundle_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(SystemExit):
                verify.find_snapshot(Path(tmp) / "nowhere")

    def test_cli_fails_without_any_requirement(self):
        with tempfile.TemporaryDirectory() as tmp:
            snapshot = write_snapshot(Path(tmp))
            with self.assertRaises(SystemExit):
                verify.main(["--bundle", str(snapshot)])

    def test_cli_exit_code_reflects_missing_endpoint(self):
        with tempfile.TemporaryDirectory() as tmp:
            snapshot = write_snapshot(Path(tmp), "https://erp.utenelec.lan/api")
            self.assertEqual(verify.main([
                "--bundle", str(snapshot),
                "--require", "https://erp.utenelec.lan/api"]), 0)
            self.assertEqual(verify.main([
                "--bundle", str(snapshot),
                "--require", "https://justplayit.cn/api"]), 1)


if __name__ == "__main__":
    unittest.main()
