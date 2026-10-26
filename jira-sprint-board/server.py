#!/usr/bin/env python3
"""Local server for the Jira sprint board.

Serves the board page and forwards read-only Jira REST requests to your Jira.
Browsers block pages from calling Jira directly (Jira doesn't allow
cross-origin requests), so the page talks to this server instead.

    python3 server.py                # then open http://localhost:8787
    python3 server.py --port 9000
    python3 server.py --insecure     # skip TLS checks, for Jira on a self-signed certificate

The page sends the Jira URL and token with each request. This server keeps
nothing, only listens on 127.0.0.1, only forwards GET requests to Jira's REST
API, and never follows redirects (so the token can't be sent to another host).
"""
import argparse
import json
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PROXY_PREFIX = "/jira"
ALLOWED_PATHS = ("/rest/agile/1.0/", "/rest/api/2/", "/rest/greenhopper/1.0/")
TIMEOUT_SECONDS = 30


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Surface redirects as errors instead of following them with the token attached."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Handler(SimpleHTTPRequestHandler):
    port = 0
    opener = None

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def do_GET(self):
        if not self._from_this_machine():
            return self._json(403, {"error": "Only pages served from localhost can use this server."})
        if self.path == PROXY_PREFIX or self.path.startswith(PROXY_PREFIX + "/"):
            return self._proxy()
        return super().do_GET()

    def _from_this_machine(self):
        # Checking Host blocks DNS-rebinding; checking Origin blocks other sites
        # in the same browser from using the proxy.
        allowed_hosts = {f"localhost:{self.port}", f"127.0.0.1:{self.port}"}
        if self.headers.get("Host", "") not in allowed_hosts:
            return False
        origin = self.headers.get("Origin")
        return origin is None or origin in {f"http://{h}" for h in allowed_hosts}

    def _proxy(self):
        target = self.path[len(PROXY_PREFIX):]
        path = urllib.parse.urlsplit(target).path
        if not path.startswith(ALLOWED_PATHS) or ".." in path:
            return self._json(400, {"error": f"Only Jira REST API reads are forwarded, not {path or '/'}."})

        base = (self.headers.get("X-Jira-Url") or "").strip().rstrip("/")
        parts = urllib.parse.urlsplit(base)
        if parts.scheme not in ("http", "https") or not parts.netloc or parts.query or parts.fragment:
            return self._json(400, {"error": "Enter your Jira URL, like https://jira.example.com."})

        auth = self.headers.get("X-Jira-Auth", "")
        if not auth.startswith(("Bearer ", "Basic ")):
            return self._json(400, {"error": "Enter your Jira token."})

        request = urllib.request.Request(
            base + target,
            headers={"Authorization": auth, "Accept": "application/json", "User-Agent": "jira-sprint-board"},
        )
        try:
            with self.opener.open(request, timeout=TIMEOUT_SECONDS) as resp:
                status, body = resp.status, resp.read()
                content_type = resp.headers.get("Content-Type", "application/json")
        except urllib.error.HTTPError as err:
            if 300 <= err.code < 400:
                location = err.headers.get("Location", "another page")
                return self._json(502, {"error": f"Jira redirected the request to {location}. "
                                                 "Check the Jira URL (include any path such as /jira) and the token."})
            status, body = err.code, err.read()
            content_type = err.headers.get("Content-Type", "application/json")
        except urllib.error.URLError as err:
            if isinstance(err.reason, ssl.SSLCertVerificationError):
                return self._json(502, {"error": f"{parts.netloc} has a TLS certificate this computer doesn't trust. "
                                                 "If that's expected (a self-signed certificate), restart server.py with --insecure."})
            if isinstance(err.reason, ssl.SSLError):
                return self._json(502, {"error": f"Couldn't make a secure (https) connection to {parts.netloc}. "
                                                 "If your Jira uses plain http, start the Jira URL with http://."})
            return self._json(502, {"error": f"Couldn't reach {parts.netloc}: {err.reason}."})
        except TimeoutError:
            return self._json(504, {"error": f"{parts.netloc} didn't answer within {TIMEOUT_SECONDS} seconds."})

        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    parser = argparse.ArgumentParser(description="Serve the Jira sprint board and proxy Jira REST reads.")
    parser.add_argument("--port", type=int, default=8787, help="port to listen on (default 8787)")
    parser.add_argument("--insecure", action="store_true",
                        help="don't verify Jira's TLS certificate (for self-signed certificates)")
    args = parser.parse_args()

    context = ssl.create_default_context()
    if args.insecure:
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE

    Handler.port = args.port
    Handler.opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=context), NoRedirect)

    try:
        server = ThreadingHTTPServer(("127.0.0.1", args.port), partial(Handler, directory=str(ROOT)))
    except OSError as err:
        sys.exit(f"Can't listen on port {args.port}: {err.strerror}. Try --port with another number.")

    print(f"Sprint board running at http://localhost:{args.port}  (Ctrl+C to stop)")
    if args.insecure:
        print("Warning: TLS certificate checks are off (--insecure).")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print()


if __name__ == "__main__":
    main()
