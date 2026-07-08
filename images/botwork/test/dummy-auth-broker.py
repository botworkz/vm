#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CAP = "dummy-auth-broker-cap"
SECRETS = b'{"tenant":"mcp","plugin":"echo","secrets":[]}'


class Handler(BaseHTTPRequestHandler):
    # HTTP/1.1 so our Content-Length response body is framed correctly for
    # session-broker's hyper client (HTTP/1.0 close-delimiting gave it EOF).
    protocol_version = "HTTP/1.1"

    def _drain_request_body(self):
        # session-broker may send the /secrets/fetch body chunked (no
        # Content-Length). If we don't fully read it, the leftover bytes
        # desync the next request on this keep-alive connection and the
        # client reads back a malformed/empty response (EOF at col 0).
        te = self.headers.get("transfer-encoding", "").lower()
        if "chunked" in te:
            while True:
                line = self.rfile.readline()
                size = int(line.split(b";", 1)[0].strip() or b"0", 16)
                if size == 0:
                    self.rfile.readline()  # trailing CRLF
                    break
                self.rfile.read(size)
                self.rfile.read(2)  # CRLF after chunk
        else:
            length = int(self.headers.get("content-length", "0"))
            if length:
                self.rfile.read(length)

    def _send(self, code, body=b"", extra_headers=()):
        self.send_response(code)
        for k, v in extra_headers:
            self.send_header(k, v)
        self.send_header("content-length", str(len(body)))
        self.send_header("connection", "close")  # avoid keep-alive desync
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_POST(self):
        self._drain_request_body()
        if self.path == "/secrets/fetch":
            if self.headers.get("x-botwork-cap") != CAP:
                self._send(403)
                return
            self._send(200, SECRETS, [("content-type", "application/json")])
            return
        self._send(200, extra_headers=[("x-botwork-cap", CAP)])

    def log_message(self, *_args):
        pass


ThreadingHTTPServer(("0.0.0.0", 9100), Handler).serve_forever()
