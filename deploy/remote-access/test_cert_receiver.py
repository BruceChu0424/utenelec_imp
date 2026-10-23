import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("cert_receiver", Path(__file__).with_name("cert_receiver.py"))
receiver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(receiver)


class CertificateReceiverTest(unittest.TestCase):
    def test_forced_command_has_no_shell_or_filename_escape(self):
        for command in ("get-csr", "publish-cert", "publish-status"):
            self.assertEqual(receiver.operation(command), command)
        for command in ("id", "get-csr /etc/shadow", "get-csr; id", "publish-cert --path /etc/shadow", "", "bash"):
            with self.assertRaises(ValueError):
                receiver.operation(command)

    def test_admin_identity_cannot_expand_to_employee_wildcard_or_extra_names(self):
        receiver.exact_san("DNS:admin.justplayit.cn")
        for names in ("DNS:justplayit.cn", "DNS:*.justplayit.cn", "DNS:admin.justplayit.cn, DNS:justplayit.cn", "IP Address:127.0.0.1"):
            with self.assertRaises(ValueError):
                receiver.exact_san(names)

    def test_certificate_receiver_never_accepts_private_material_or_arbitrary_text(self):
        for content in (b"", b"-----BEGIN PRIVATE KEY-----\nfixture\n-----END PRIVATE KEY-----", b"file=/etc/shadow", b"a" * 65537):
            with self.assertRaises(ValueError):
                receiver.split_chain(content)

    @unittest.skipUnless(Path("/usr/bin/openssl").is_file(), "real CSR validation runs in the Linux deployment container")
    def test_real_csr_proves_key_possession_and_rejects_employee_or_multiple_sans(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            for san, accepted in (("DNS:admin.justplayit.cn", True), ("DNS:justplayit.cn", False), ("DNS:admin.justplayit.cn,DNS:justplayit.cn", False)):
                subprocess.run(["/usr/bin/openssl", "req", "-new", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes",
                                "-subj", "/CN=admin.justplayit.cn", "-addext", "subjectAltName=" + san,
                                "-keyout", str(directory / "dr.key"), "-out", str(directory / "dr.csr")], capture_output=True, check=True)
                with patch.object(receiver, "TLS", directory):
                    if accepted:
                        self.assertTrue(receiver.csr_bytes().startswith(b"-----BEGIN CERTIFICATE REQUEST-----"))
                    else:
                        with self.assertRaises(ValueError):
                            receiver.csr_bytes()


if __name__ == "__main__":
    unittest.main()
