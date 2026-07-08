#!/usr/bin/env python3
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CAP = "dummy-auth-broker-cap"
SECRETS = b'{"tenant":"mcp","plugin":"echo","secrets":[]}'


class Handler(BaseHTTPRequestHandler):
    # session-broker/src/secrets.rs reads the /secrets/fetch response with a raw
    # hyper http1 client, strictly by Content-Length. Its own passing test
    # server (secrets.rs `spawn_http_server`) writes the WHOLE response --
    # status line, headers, body -- as ONE buffer ending with `Connection:
    # close`, then closes. Earlier attempts used BaseHTTPRequestHandler's
    # buffered, multi-write, Server/Date-injecting response path and the hyper
    # client kept reading an empty body (EOF at line 1 column 0). Emit the exact
    # bytes the reference test server uses instead.
    protocol_version = "HTTP/1.1"

    def _raw(self, status, reason, body=b"", content_type=None, extra=()):
        head = f"HTTP/1.1 {status} {reason}\r\n"
        if content_type:
            head += f"Content-Type: {content_type}\r\n"
        for k, v in extra:
            head += f"{k}: {v}\r\n"
        head += f"Content-Length: {len(body)}\r\n"
        head += "Connection: close\r\n\r\n"
        self.wfile.write(head.encode("ascii") + body)
        self.wfile.flush()

    def do_POST(self):
        # session-broker sends Content-Length: 0 with an empty body. Drain
        # whatever Content-Length declares so the socket stays framed.
        length = int(self.headers.get("content-length", "0"))
        if length:
            self.rfile.read(length)

        if self.path == "/secrets/fetch":
            if self.headers.get("x-botwork-cap") != CAP:
                # secrets.rs maps 401 -> SecretsError::Unauthorized; anything
                # else non-200 -> BadResponse. Use 401 for the bad-cap path.
                self._raw(401, "Unauthorized")
                return
            self._raw(200, "OK", SECRETS, "application/json")
            return
        # ext_authz /auth/check path: mint the cap header onto the response.
        self._raw(200, "OK", extra=[("x-botwork-cap", CAP)])

    def log_message(self, fmt, *args):
        # Log to stderr so `docker logs dummy-auth-broker` shows real traffic
        # instead of silence when something goes wrong.
        sys.stderr.write("[dummy-auth-broker] " + (fmt % args) + "\n")


ThreadingHTTPServer(("0.0.0.0", 9100), Handler).serve_forever()
