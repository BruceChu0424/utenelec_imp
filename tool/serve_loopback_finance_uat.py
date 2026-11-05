"""Serve built Web assets and forward API requests only to the disposable local UAT.

The company server, credentials and settings are never used. API authentication
is preserved; static assets are separate because the backend does not serve UI.
"""
from argparse import ArgumentParser
from functools import partial
from http.client import HTTPConnection
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit


def main():
    parser = ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--stop-file', type=Path, required=True)
    parser.add_argument('--port', type=int, default=18092)
    parser.add_argument('--api-port', type=int, default=18091)
    args = parser.parse_args()
    root = args.root.resolve()
    if not (root / 'index.html').is_file() or args.stop_file.exists():
        raise SystemExit('Build Web first and use a fresh owned stop marker')
    origin = f'http://127.0.0.1:{args.port}'
    api_origin = f'http://127.0.0.1:{args.api_port}'
    hop = {'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
           'te', 'trailer', 'transfer-encoding', 'upgrade', 'host', 'content-length'}

    class Handler(SimpleHTTPRequestHandler):
        def log_message(self, *_):
            pass  # No credentials, request bodies or business paths in helper logs.

        def list_directory(self, _):
            self.send_error(403)

        def _serve(self):
            if self.headers.get('Host') != urlsplit(origin).netloc or self.headers.get('Origin', origin) != origin:
                self.send_error(403)
                return
            if not urlsplit(self.path).path.startswith('/api/'):
                if self.command not in ('GET', 'HEAD'):
                    self.send_error(405)
                    return
                if self.command == 'HEAD':
                    super().do_HEAD()
                else:
                    super().do_GET()
                return
            size = int(self.headers.get('Content-Length', '0'))
            if size < 0 or size > 2 * 1024 * 1024:
                self.send_error(413)
                return
            headers = {k: v for k, v in self.headers.items() if k.lower() not in hop}
            # Same-origin local development proxy, equivalent to changeOrigin.
            if 'Origin' in headers:
                headers['Origin'] = api_origin
            if 'Referer' in headers:
                headers['Referer'] = api_origin + '/'
            connection = HTTPConnection('127.0.0.1', args.api_port, timeout=40)
            try:
                connection.request(self.command, self.path, self.rfile.read(size) if size else None, headers)
                response = connection.getresponse()
                data = response.read(16 * 1024 * 1024 + 1)
                if len(data) > 16 * 1024 * 1024:
                    self.send_error(502)
                    return
                self.send_response(response.status)
                for key, value in response.getheaders():
                    if key.lower() not in hop:
                        self.send_header(key, value)
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                if self.command != 'HEAD':
                    self.wfile.write(data)
            except (OSError, TimeoutError):
                if not args.stop_file.exists():
                    try:
                        self.send_error(502)
                    except OSError:
                        pass  # A cancelled browser request already closed its socket.
            finally:
                connection.close()

        do_GET = do_HEAD = do_POST = do_PUT = do_PATCH = do_DELETE = do_OPTIONS = _serve

    server = ThreadingHTTPServer(('127.0.0.1', args.port), partial(Handler, directory=str(root)))
    server.daemon_threads = True
    server.timeout = .25
    print(f'Local synthetic finance UI: {origin}', flush=True)
    try:
        while not args.stop_file.exists():
            server.handle_request()
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
