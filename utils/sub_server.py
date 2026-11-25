import http.server
import os
import ssl
import sys
import urllib.parse

if len(sys.argv) < 4:
    print("Usage: python3 sub_server.py <PORT> <TOKEN> <FILE_PATH> [CERT_PATH] [KEY_PATH]")
    sys.exit(1)

PORT = int(sys.argv[1])
TOKEN = sys.argv[2]
FILE_PATH = sys.argv[3]
CERT_PATH = sys.argv[4] if len(sys.argv) > 4 else None
KEY_PATH = sys.argv[5] if len(sys.argv) > 5 else None
CLASH_FILE_PATH = "/etc/node-manager/output/clash.yaml"


class Handler(http.server.SimpleHTTPRequestHandler):
    timeout = 15

    def do_GET(self):
        req_path = urllib.parse.urlparse(self.path).path.rstrip("/")
        if req_path == f"/{TOKEN}":
            try:
                user_agent = self.headers.get("User-Agent", "").lower()
                serve_file = FILE_PATH

                # Clash / Clash Verge / Mihomo 客户端检测
                if ("clash" in user_agent or "verge" in user_agent or "mihomo" in user_agent) and os.path.exists(CLASH_FILE_PATH):
                    serve_file = CLASH_FILE_PATH

                with open(serve_file, "rb") as f:
                    content = f.read()

                self.send_response(200)
                self.send_header("Content-type", "text/plain; charset=utf-8")
                self.send_header("Content-Length", str(len(content)))
                self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
                self.end_headers()
                self.wfile.write(content)
            except Exception as e:
                self.send_error(500, str(e))
        else:
            self.send_error(404, "Not Found")

    def log_message(self, format, *args):
        pass


class ReusableThreadingHTTPServer(http.server.ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True
    ssl_context = None

    def process_request_thread(self, request, client_address):
        try:
            request.settimeout(15)
            if self.ssl_context is not None:
                request = self.ssl_context.wrap_socket(request, server_side=True)
            self.finish_request(request, client_address)
        except Exception:
            self.handle_error(request, client_address)
        finally:
            self.shutdown_request(request)


try:
    with ReusableThreadingHTTPServer(("", PORT), Handler) as httpd:
        if CERT_PATH and KEY_PATH and os.path.exists(CERT_PATH) and os.path.exists(KEY_PATH):
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(CERT_PATH, KEY_PATH)
            httpd.ssl_context = context
            print(f"Serving HTTPS on port {PORT}...")
        else:
            print(f"Serving HTTP on port {PORT}...")
        httpd.serve_forever()
except Exception as e:
    print(f"Error starting server: {e}")
    sys.exit(1)
