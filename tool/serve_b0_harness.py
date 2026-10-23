"""Loopback-only collector for the explicit B0 synthetic Flutter harness."""
from argparse import ArgumentParser
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import functools
import json
from datetime import datetime, timezone

parser = ArgumentParser()
parser.add_argument('--root', required=True)
parser.add_argument('--evidence-dir', required=True)
parser.add_argument('--port', type=int, default=53871)
args = parser.parse_args()
evidence = Path(args.evidence_dir).resolve()
evidence.mkdir(parents=True, exist_ok=True)

class Handler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data: blob:; font-src 'self'; worker-src 'self'; object-src 'none'")
        self.send_header('X-Content-Type-Options', 'nosniff')
        super().end_headers()

    def do_POST(self):
        if self.path != '/b0-results':
            self.send_error(404)
            return
        size = int(self.headers.get('Content-Length', '0'))
        if not 0 < size <= 200000:
            self.send_error(413)
            return
        data = json.loads(self.rfile.read(size))
        data['recordedUtc'] = datetime.now(timezone.utc).isoformat()
        with (evidence / 'browser-results.jsonl').open('a', encoding='utf-8') as stream:
            stream.write(json.dumps(data, ensure_ascii=False) + '\n')
        print(json.dumps(data, ensure_ascii=False), flush=True)
        self.send_response(204)
        self.end_headers()

    def log_message(self, fmt, *values):
        if args and self.path.endswith('uten_json_worker.js'):
            print('worker asset requested', flush=True)

server = ThreadingHTTPServer(('127.0.0.1', args.port), functools.partial(Handler, directory=str(Path(args.root).resolve())))
print(f'B0 harness http://127.0.0.1:{args.port}', flush=True)
server.serve_forever()
