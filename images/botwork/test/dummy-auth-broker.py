#!/usr/bin/env python3
import socketserver
import sys

CAP = "dummy-auth-broker-cap"
SECRETS = b'{"tenant":"mcp","plugin":"echo","secrets":[]}'


def response(status, reason, body=b"", content_type=None, extra=()):
    head = [f"HTTP/1.1 {status} {reason}\r\n".encode("ascii")]
    if content_type:
        head.append(f"Content-Type: {content_type}\r\n".encode("ascii"))
    for key, value in extra:
        head.append(f"{key}: {value}\r\n".encode("ascii"))
    head.append(f"Content-Length: {len(body)}\r\n".encode("ascii"))
    head.append(b"Connection: close\r\n\r\n")
    return b"".join(head) + body


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        request_line = self.rfile.readline()
        if not request_line:
            return

        try:
            method, path, _version = request_line.decode("latin-1").rstrip("\r\n").split(" ", 2)
        except ValueError:
            self.wfile.write(response(400, "Bad Request"))
            self.wfile.flush()
            return

        headers = {}
        while True:
            line = self.rfile.readline()
            if line in (b"", b"\n", b"\r\n"):
                break
            key, sep, value = line.decode("latin-1").partition(":")
            if sep:
                headers[key.strip().lower()] = value.strip()

        length = int(headers.get("content-length", "0") or "0")
        if length:
            self.rfile.read(length)

        sys.stderr.write(
            f"[dummy-auth-broker] {self.client_address[0]} {method} {path} "
            f"cap={'present' if headers.get('x-botwork-cap') else 'missing'}\n"
        )
        sys.stderr.flush()

        if method != "POST":
            payload = response(405, "Method Not Allowed")
        elif path == "/secrets/fetch":
            # session-broker calls this endpoint EXACTLY (no prefixing). Gate on
            # the cap header being present and non-empty, not on an exact literal
            # value: session-broker forwards the real short-lived capability
            # token minted by ext_authz, which is not the stub's CAP constant.
            if not headers.get("x-botwork-cap"):
                payload = response(401, "Unauthorized")
            else:
                payload = response(200, "OK", SECRETS, "application/json")
        elif path == "/auth/check" or path.startswith("/auth/check/"):
            # envoy's ext_authz `path_prefix: /auth/check` is PREPENDED to the
            # (Lua-rewritten) request path, so the auth check arrives as e.g.
            # POST /auth/check/mcp/demo/echo -- NOT a bare /auth/check. Match the
            # prefix, or ext_authz gets a 404, treats it as deny, and the client
            # sees 404 flags=UAEX details=ext_authz_denied.
            payload = response(200, "OK", extra=[("x-botwork-cap", CAP)])
        else:
            payload = response(404, "Not Found")

        self.wfile.write(payload)
        self.wfile.flush()


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True


Server(("0.0.0.0", 9100), Handler).serve_forever()
