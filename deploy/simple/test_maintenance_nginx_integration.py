"""Actual five-template nginx maintenance gate in a disposable Linux container."""
from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('maintenance_nginx_fixture', ROOT / 'deploy/client/nginx_client_updates_integration.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


@unittest.skipUnless(os.name == 'posix' and Path('/.dockerenv').exists(), 'Requires disposable Linux Docker nginx')
class MaintenanceNginxTest(unittest.TestCase):
    def test_all_employee_entries_survive_backend_shutdown_and_keep_security_headers(self):
        templates = [
            'deploy/nginx/uten-imp-http-lan.conf', 'deploy/nginx/uten-imp.conf.example',
            'deploy/nginx/uten-imp-internal-test.conf.example', 'deploy/cloud/nginx-cloud.conf.example',
            'deploy/remote-access/templates/company-nginx.conf.tmpl',
        ]
        with tempfile.TemporaryDirectory(prefix='uten-maintenance-nginx-') as temporary:
            base = Path(temporary)
            base.chmod(0o755)
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                            '-subj', '/CN=erp.example.test', '-addext', 'subjectAltName=DNS:erp.example.test',
                            '-keyout', str(base / 'fixture.key'), '-out', str(base / 'fixture.crt')],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            for index, template in enumerate(templates):
                with self.subTest(template=template):
                    work = base / str(index)
                    work.mkdir(mode=0o755)
                    for name in ('fixture.key', 'fixture.crt'):
                        (work / name).write_bytes((base / name).read_bytes())
                    for name in ('tls', 'web', 'body', 'proxy', 'fastcgi', 'uwsgi', 'scgi', 'public'):
                        (work / name).mkdir(mode=0o755)
                    for name in ('transport-server.crt', 'cloud-client-ca.crt', 'employee-fullchain.crt'):
                        (work / 'tls' / name).write_bytes((base / 'fixture.crt').read_bytes())
                    for name in ('transport-server.key', 'employee.key'):
                        (work / 'tls' / name).write_bytes((base / 'fixture.key').read_bytes())
                    # Deliberately old release, with no maintenance assets.
                    (work / 'web/index.html').write_text('APPLICATION')
                    for name, body in {'maintenance.html': 'MAINTENANCE',
                                       'maintenance.css': 'body{color:navy}', 'maintenance.js': 'void 0'}.items():
                        (work / 'public' / name).write_text(body)
                    status_file = work / 'public/maintenance.json'
                    status_file.write_text(json.dumps({'schemaVersion': 1, 'state': 'scheduled'}))
                    config = work / 'nginx.conf'
                    rendered = fixture.render((ROOT / template).read_text(encoding='utf-8'), work, 'remote-access' in template)
                    config.write_text(rendered.replace('/var/lib/uten-imp-public', str(work / 'public')))
                    checked = subprocess.run(['nginx', '-t', '-q', '-c', str(config)], capture_output=True, text=True)
                    self.assertEqual(0, checked.returncode, checked.stderr)
                    self.assertNotIn('[warn]', checked.stderr)
                    process = subprocess.Popen(['nginx', '-c', str(config), '-g', 'daemon off;'],
                                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    try:
                        fixture.wait_listener()
                        code, headers, body = fixture.request(work, '/', authorized=False)
                        self.assertEqual(200, code)
                        self.assertEqual(b'APPLICATION', body)
                        policy = {
                            directive.split()[0]: directive.split()[1:]
                            for directive in headers['Content-Security-Policy'].split(';')
                            if directive.strip()
                        }
                        # Private media is fetched and verified by the application
                        # before a local blob is handed to the browser player.
                        # Keep this permission scoped to media, without permitting
                        # remote players, arbitrary hosts or blob scripts.
                        self.assertEqual(["'self'", 'blob:'], policy['media-src'])
                        self.assertEqual(["'self'"], policy['default-src'])
                        self.assertEqual(["'none'"], policy['object-src'])
                        self.assertNotIn('blob:', policy['script-src'])
                        self.assertNotIn('*', policy['connect-src'])
                        # No backend is started: this is independent of Spring,
                        # the database and authentication authority.
                        code, headers, body = fixture.request(work, '/api/system/maintenance', authorized=False)
                        self.assertEqual(200, code)
                        self.assertEqual('scheduled', json.loads(body)['state'])
                        self.assertIn('no-store', headers['Cache-Control'])
                        self.assertIn('Date', headers)
                        self.assertIn('Content-Security-Policy', headers)
                        self.assertEqual(403, fixture.request(work, '/api/system/maintenance', 'POST', b'', authorized=False)[0])
                        (work / 'public/updating').write_text('updating\n')
                        status_file.write_text(json.dumps({'schemaVersion': 1, 'state': 'updating'}))
                        for path in ('/', '/index.html', '/sales/orders'):
                            code, headers, body = fixture.request(work, path, authorized=False)
                            self.assertEqual(503, code, path)
                            self.assertEqual(b'MAINTENANCE', body)
                            self.assertIn('no-store', headers['Cache-Control'])
                            self.assertIn('Content-Security-Policy', headers)
                            self.assertEqual('nosniff', headers['X-Content-Type-Options'])
                        for path in ('/maintenance.html', '/maintenance.css', '/maintenance.js'):
                            code, headers, body = fixture.request(work, path, authorized=False)
                            self.assertEqual(200, code, path)
                            self.assertIn('no-store', headers['Cache-Control'])
                            self.assertIn('Content-Security-Policy', headers)
                            expected_type = {'/maintenance.html': 'text/html', '/maintenance.css': 'text/css',
                                             '/maintenance.js': 'application/javascript'}[path]
                            self.assertIn(expected_type, headers['Content-Type'])
                        self.assertEqual('updating', json.loads(fixture.request(work, '/api/system/maintenance', authorized=False)[2])['state'])
                        (work / 'public/updating').unlink()
                        self.assertEqual(b'APPLICATION', fixture.request(work, '/', authorized=False)[2])
                    finally:
                        process.terminate()
                        process.wait(timeout=5)


if __name__ == '__main__':
    unittest.main()
