"""Real OpenSSL contract tests; no production paths, keys, network or service writes."""
import importlib.util
import contextlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('lan_tls', Path(__file__).with_name('uten-lan-tls-renew.py'))
TLS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TLS)


class RenewalTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='uten-lan-tls-test-')
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.fixture_ip = '192.0.2.13'
        self.ip_patch = patch.object(TLS, 'IP_ADDRESS', self.fixture_ip)
        self.ip_patch.start()
        self.addCleanup(self.ip_patch.stop)
        self.paths = {name: self.work / filename for name, filename in {
            'ROOT': 'root.crt', 'ISSUER': 'issuer.crt', 'ISSUER_KEY': 'issuer.key',
            'CERT': 'server.crt', 'KEY': 'server.key', 'STATE': 'state'}.items()}
        self.paths['STATE'].mkdir(mode=0o700)
        self.patches = [patch.object(TLS, name, value) for name, value in self.paths.items()]
        for item in self.patches:
            item.start()
            self.addCleanup(item.stop)
        self.openssl('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-sha256',
                     '-days', '1000', '-subj', '/CN=Isolated Test Root',
                     '-keyout', str(self.work / 'root.key'), '-out', str(TLS.ROOT),
                     '-addext', 'basicConstraints=critical,CA:TRUE')
        self.openssl('req', '-new', '-newkey', 'rsa:2048', '-nodes', '-sha256',
                     '-subj', '/CN=Isolated LAN Issuer', '-keyout', str(TLS.ISSUER_KEY),
                     '-out', str(self.work / 'issuer.csr'))
        self.issuer_extensions = self.work / 'issuer.ext'
        self.issuer_extensions.write_text(
            'basicConstraints=critical,CA:TRUE,pathlen:0\n'
            'keyUsage=critical,keyCertSign,cRLSign\n'
            'subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n'
            'nameConstraints=critical,permitted;DNS:imp.utenelec,permitted;DNS:erp.utenelec.lan,'
            'permitted;DNS:utenelec-imp-server\n')
        self.sign_issuer()
        self.openssl('genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:2048', '-out', str(TLS.KEY))
        for key in (TLS.KEY, TLS.ISSUER_KEY):
            key.chmod(0o600)
        self.pin = patch.object(TLS, 'ROOT_SHA256', TLS.fingerprint(TLS.ROOT))
        self.pin.start()
        self.addCleanup(self.pin.stop)
        with tempfile.TemporaryDirectory(dir=self.work) as directory:
            candidate = TLS.issue(Path(directory))
            TLS.CERT.write_bytes(candidate.read_bytes() + TLS.ISSUER.read_bytes())
        TLS.CERT.chmod(0o644)
        self.original = TLS.CERT.read_bytes()
        self.real_command = TLS.command

    def openssl(self, *args):
        result = subprocess.run([TLS.OPENSSL, *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode:
            self.fail(result.stderr.decode())

    def sign_issuer(self, days='700'):
        self.openssl('x509', '-req', '-in', str(self.work / 'issuer.csr'), '-CA', str(TLS.ROOT),
                     '-CAkey', str(self.work / 'root.key'), '-set_serial', '17', '-days', days,
                     '-sha256', '-extfile', str(self.issuer_extensions), '-out', str(TLS.ISSUER))

    def service_commands(self, args, **kwargs):
        if args[0] in (TLS.NGINX, TLS.SYSTEMCTL):
            return b''
        return self.real_command(args, **kwargs)

    def test_real_issuer_and_leaf_chain_and_sans(self):
        TLS.ensure_inputs()
        TLS.validate_leaf(TLS.CERT)
        self.assertGreater(TLS.remaining(TLS.CERT), 364 * 86400)
        # Hostname verification must reject an IP absent from the leaf SAN.
        # This verifies the leaf identity, not an issuer-level IP constraint.
        result = subprocess.run([TLS.OPENSSL, 'verify', '-CAfile', str(TLS.ROOT),
                                 '-untrusted', str(TLS.ISSUER), '-verify_ip', '192.0.2.14',
                                 str(TLS.CERT)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertNotEqual(result.returncode, 0)

    def test_healthy_certificate_skips_signing_and_reload(self):
        with patch.object(TLS, 'issue') as issuing, patch.object(TLS, 'verify_served') as served:
            result = TLS.renew()
        self.assertFalse(result['renewed'])
        issuing.assert_not_called()
        served.assert_called_once_with(TLS.fingerprint(TLS.CERT))
        self.assertEqual(TLS.CERT.read_bytes(), self.original)

    def test_rerun_recovers_interruption_between_install_and_reload_without_signing(self):
        commands = []
        def recording(args, **kwargs):
            if args[0] in (TLS.NGINX, TLS.SYSTEMCTL):
                commands.append(args)
            return self.service_commands(args, **kwargs)
        with patch.object(TLS, 'issue') as issuing, \
                patch.object(TLS, 'command', side_effect=recording), \
                patch.object(TLS, 'verify_served', side_effect=[TLS.RenewalError('old served certificate'), None]):
            result = TLS.renew()
        self.assertEqual(result['result'], 'reloaded')
        self.assertFalse(result['renewed'])
        issuing.assert_not_called()
        self.assertEqual(commands, [[TLS.NGINX, '-t'], [TLS.SYSTEMCTL, 'reload', 'nginx.service']])
        self.assertEqual(TLS.CERT.read_bytes(), self.original)

    def test_check_only_does_not_repair_mismatching_served_certificate(self):
        with patch.object(TLS, 'issue') as issuing, \
                patch.object(TLS, 'command', wraps=self.real_command) as commands, \
                patch.object(TLS, 'verify_served', side_effect=TLS.RenewalError('old served certificate')):
            with self.assertRaisesRegex(TLS.RenewalError, 'old served certificate'):
                TLS.renew(check_only=True)
        issuing.assert_not_called()
        self.assertFalse(any(call.args[0][0] in (TLS.NGINX, TLS.SYSTEMCTL) for call in commands.call_args_list))
        self.assertEqual(TLS.CERT.read_bytes(), self.original)

    def test_sigterm_during_healthy_check_does_not_trigger_reload(self):
        with patch.object(TLS, 'command', wraps=self.real_command) as commands, \
                patch.object(TLS, 'verify_served', side_effect=TLS.RenewalTerminated('termination requested')):
            with self.assertRaises(TLS.RenewalTerminated):
                TLS.renew()
        self.assertFalse(any(call.args[0][0] in (TLS.NGINX, TLS.SYSTEMCTL) for call in commands.call_args_list))

    def test_threshold_renews_and_sends_full_chain_without_changing_key(self):
        key = TLS.KEY.read_bytes()
        original_remaining = TLS.remaining
        def remaining(path):
            if path == TLS.CERT and TLS.CERT.read_bytes() == self.original:
                return 29 * 86400
            return original_remaining(path)
        with patch.object(TLS, 'remaining', side_effect=remaining), \
                patch.object(TLS, 'command', side_effect=self.service_commands), \
                patch.object(TLS, 'verify_served') as served:
            result = TLS.renew()
        self.assertTrue(result['renewed'])
        self.assertEqual(TLS.KEY.read_bytes(), key)
        self.assertNotEqual(TLS.CERT.read_bytes(), self.original)
        self.assertEqual(TLS.CERT.read_bytes().count(b'BEGIN CERTIFICATE'), 2)
        TLS.validate_leaf(TLS.CERT)
        served.assert_called_once_with(TLS.fingerprint(TLS.CERT))
        self.assertEqual((TLS.STATE / 'previous-fullchain.crt').read_bytes(), self.original)
        self.assertFalse(list(TLS.STATE.glob('issue-*')))

    def test_nginx_validation_failure_restores_previous_certificate(self):
        validations = []
        def failing(args, **kwargs):
            if args[0] == TLS.NGINX:
                validations.append(TLS.CERT.read_bytes())
                if len(validations) == 1:
                    raise TLS.RenewalError('simulated invalid Nginx configuration')
                return b''
            return self.service_commands(args, **kwargs)
        with patch.object(TLS, 'command', side_effect=failing), patch.object(TLS, 'verify_served'):
            with self.assertRaisesRegex(TLS.RenewalError, 'previous certificate retained or restored'):
                TLS.renew(force=True)
        self.assertEqual(len(validations), 2)
        self.assertNotEqual(validations[0], self.original)
        self.assertEqual(validations[1], self.original)
        self.assertEqual(TLS.CERT.read_bytes(), self.original)
        self.assertFalse(list(TLS.STATE.glob('issue-*')))

    def test_live_tls_verification_failure_also_rolls_back(self):
        with patch.object(TLS, 'command', side_effect=self.service_commands), \
                patch.object(TLS, 'verify_served', side_effect=[TLS.RenewalError('live failed'), None]) as served:
            with self.assertRaises(TLS.RenewalError):
                TLS.renew(force=True)
        self.assertEqual(TLS.CERT.read_bytes(), self.original)
        self.assertEqual(served.call_count, 2)

    def test_sigterm_during_installed_certificate_transaction_rolls_back(self):
        validations = []
        def terminating(args, **kwargs):
            if args[0] == TLS.NGINX:
                validations.append(TLS.CERT.read_bytes())
                if len(validations) == 1:
                    TLS.terminate_renewal(None, None)
                return b''
            return self.service_commands(args, **kwargs)
        with patch.object(TLS, 'command', side_effect=terminating), patch.object(TLS, 'verify_served'):
            with self.assertRaisesRegex(TLS.RenewalError, 'previous certificate retained or restored'):
                TLS.renew(force=True)
        self.assertEqual(len(validations), 2)
        self.assertNotEqual(validations[0], self.original)
        self.assertEqual(validations[1], self.original)
        self.assertEqual(TLS.CERT.read_bytes(), self.original)
        self.assertFalse(list(TLS.STATE.glob('issue-*')))

    def test_sigterm_after_atomic_replace_before_return_rolls_back(self):
        original_write = TLS.atomic_write
        replaced = []
        def terminating_write(path, content, mode):
            original_write(path, content, mode)
            if path == TLS.CERT:
                replaced.append(content)
                if len(replaced) == 1:
                    TLS.terminate_renewal(None, None)
        with patch.object(TLS, 'command', side_effect=self.service_commands), \
                patch.object(TLS, 'atomic_write', side_effect=terminating_write), \
                patch.object(TLS, 'verify_served'):
            with self.assertRaisesRegex(TLS.RenewalError, 'previous certificate retained or restored'):
                TLS.renew(force=True)
        self.assertEqual(len(replaced), 2)
        self.assertEqual(TLS.CERT.read_bytes(), self.original)

    def test_wrong_root_pin_rejects_before_any_install(self):
        with patch.object(TLS, 'ROOT_SHA256', '0' * 64):
            with self.assertRaisesRegex(TLS.RenewalError, 'fingerprint'):
                TLS.renew(force=True)
        self.assertEqual(TLS.CERT.read_bytes(), self.original)

    def test_unrendered_site_address_rejects_before_any_install(self):
        with patch.object(TLS, 'IP_ADDRESS', '__LAN_IP_ADDRESS__'):
            with self.assertRaisesRegex(TLS.RenewalError, 'render one reviewed office IPv4'):
                TLS.renew(force=True)
        self.assertEqual(TLS.CERT.read_bytes(), self.original)

    def test_widened_issuer_constraints_rejected(self):
        text = self.issuer_extensions.read_text().replace('permitted;DNS:imp.utenelec', 'permitted;DNS:utenelec')
        self.issuer_extensions.write_text(text)
        self.sign_issuer()
        with self.assertRaisesRegex(TLS.RenewalError, 'name constraints'):
            TLS.renew(force=True)
        self.assertEqual(TLS.CERT.read_bytes(), self.original)

    def test_legacy_ip_issuer_constraint_rejected_for_dart_compatibility(self):
        text = self.issuer_extensions.read_text().rstrip() + f',permitted;IP:{self.fixture_ip}/255.255.255.255\n'
        self.issuer_extensions.write_text(text)
        self.sign_issuer()
        with self.assertRaisesRegex(TLS.RenewalError, 'name constraints'):
            TLS.renew(force=True)
        self.assertEqual(TLS.CERT.read_bytes(), self.original)

    def test_issuer_inside_400_day_window_rejected(self):
        self.sign_issuer(days='399')
        with self.assertRaisesRegex(TLS.RenewalError, '400 days'):
            TLS.renew(force=True)
        self.assertEqual(TLS.CERT.read_bytes(), self.original)

    def test_leaf_with_extra_san_rejected(self):
        with tempfile.TemporaryDirectory(dir=self.work) as directory:
            with patch.object(TLS, 'DNS_NAMES', (*TLS.DNS_NAMES, 'extra.imp.utenelec')):
                leaf = TLS.issue(Path(directory))
            with self.assertRaisesRegex(TLS.RenewalError, 'SAN'):
                TLS.validate_leaf(leaf)

    def test_failed_check_preserves_last_success_and_renewal_history(self):
        status_path = TLS.STATE / 'status.json'
        history = {'lastSuccessAt': '2026-10-20T01:00:00+00:00',
                   'lastRenewedAt': '2026-10-19T01:00:00+00:00'}
        status_path.write_text(json.dumps(history))
        with patch('sys.argv', ['uten-lan-tls-renew']), \
                patch.object(TLS, 'renew', side_effect=TLS.RenewalError('test failure')), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(TLS.main(), 1)
        current = json.loads(status_path.read_text())
        self.assertEqual(current['result'], 'failed')
        for field, value in history.items():
            self.assertEqual(current[field], value)


if __name__ == '__main__':
    unittest.main()
