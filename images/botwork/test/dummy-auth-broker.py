#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, HTTPServer

CAP = "dummy-auth-broker-cap"
SECRETS = b'{"tenant":"mcp","plugin":"echo","secrets":[]}'


class Handler(BaseHTTPRequestHandler):
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
