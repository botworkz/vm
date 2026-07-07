#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, HTTPServer

CAP = "dummy-auth-broker-cap"
SECRETS = b'{"tenant":"mcp","plugin":"echo","secrets":[]}'


class Handler(BaseHTTPRequestHandler):
    # session-broker's secrets::fetch_secrets talks to us with a raw hyper
    # http1 client that delimits the response body by Content-Length. The
    # BaseHTTPRequestHandler default of HTTP/1.0 delimits by connection-close,
    # so the hyper client read our status line but hit EOF before the body,
    # surfacing as `SecretsError::BadResponse: invalid JSON: EOF ...` and a
    # fail-closed 503 on spawn. Pin HTTP/1.1 so Content-Length framing (which
    # we already send on every response below) is honoured and the body is
    # actually read.
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        if length:
            self.rfile.read(length)
        if self.path == "/secrets/fetch":
            if self.headers.get("x-botwork-cap") != CAP:
                self.send_response(403)
                self.send_header("content-length", "0")
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(SECRETS)))
            self.end_headers()
            self.wfile.write(SECRETS)
            return
        self.send_response(200)
        self.send_header("x-botwork-cap", CAP)
        self.send_header("content-length", "0")
        self.end_headers()

    def log_message(self, *_args):
        pass


HTTPServer(("0.0.0.0", 9100), Handler).serve_forever()
