"""Serve one explicit local synthetic build and collect bounded test receipts.

No proxying, production connections, credential handling, or business data.
"""
from __future__ import annotations

import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import hashlib
import re
from pathlib import Path
import threading
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--directory', required=True, type=Path)
    parser.add_argument('--receipts', required=True, type=Path)
    parser.add_argument('--port', type=int, default=8849)
    parser.add_argument('--variant', choices=('baseline', 'candidate'), required=True)
    parser.add_argument('--run-prefix', required=True)
    args = parser.parse_args()
    directory = args.directory.resolve(strict=True)
    receipts = args.receipts.resolve()
    receipts.mkdir(parents=True, exist_ok=True)
    build_sha = hashlib.sha256((directory/'main.dart.js').read_bytes()).hexdigest()
    lock = threading.Lock()

    class Handler(SimpleHTTPRequestHandler):
        def do_POST(self):
            if self.path != '/__table_read_receipt':
                self.send_error(405)
                return
            size = int(self.headers.get('Content-Length', '0'))
            if not 0 < size <= 131072:
                self.send_error(413)
                return
            try:
                value = json.loads(self.rfile.read(size))
                if value.get('syntheticOnly') is not True:
                    raise ValueError('synthetic marker required')
                scenario = value['scenario']
                if scenario not in ('load', 'churn', 'interrupt', 'reopen', 'refresh'):
                    raise ValueError('unknown fixture scenario')
                run_id = value.get('runId', '')
                if not re.fullmatch(r'[A-Za-z0-9_-]{1,80}', run_id) or not run_id.startswith(args.run_prefix):
                    raise ValueError('unexpected run id')
                if value.get('variant') != args.variant:
                    raise ValueError('unexpected build variant')
                value['servedBuildSha256'] = build_sha
                value['observedAtUnixMs'] = time.time_ns()//1_000_000
                # No caller-controlled file path is accepted.
                stamp = time.time_ns()
                with lock:
                    target = receipts/f'{stamp}-{scenario}.json'
                    target.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding='utf-8')
            except (ValueError, KeyError, TypeError):
                self.send_error(400)
                return
            self.send_response(204)
            self.end_headers()

        def end_headers(self):
            self.send_header('Cache-Control', 'no-store')
            super().end_headers()

        def log_message(self, format, *args):
            # Noise-free during timing. Errors still have explicit HTTP status.
            pass

    server = ThreadingHTTPServer(('127.0.0.1', args.port), partial(Handler, directory=str(directory)))
    print(f'Local synthetic fixture: http://127.0.0.1:{args.port}', flush=True)
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
