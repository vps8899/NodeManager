import http.server
import socketserver
import sys
import os

import ssl

if len(sys.argv) < 4:
    print("Usage: python3 sub_server.py <PORT> <TOKEN> <FILE_PATH> [CERT_PATH] [KEY_PATH]")
    sys.exit(1)

PORT = int(sys.argv[1])
TOKEN = sys.argv[2]
FILE_PATH = sys.argv[3]
CERT_PATH = sys.argv[4] if len(sys.argv) > 4 else None
KEY_PATH = sys.argv[5] if len(sys.argv) > 5 else None

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == f"/{TOKEN}":
            try:
                user_agent = self.headers.get("User-Agent", "").lower()
                serve_file = FILE_PATH
                
                # Clash / Clash Verge 客户端检测
                if "clash" in user_agent or "verge" in user_agent or "mihomo" in user_agent:
                    serve_file = "/etc/node-manager/output/clash.yaml"
                    
                with open(serve_file, 'rb') as f:
                    self.send_response(200)
                    self.send_header("Content-type", "text/plain; charset=utf-8")
                    
                    content = f.read()
                    self.send_header("Content-Length", str(len(content)))
                    self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
                    self.end_headers()
                    self.wfile.write(content)
            except Exception as e:
                self.send_error(500, str(e))
        else:
            self.send_error(404, "Not Found")

    # Disable logging to stdout to keep it quiet, or log to a file
    def log_message(self, format, *args):
        pass

try:
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("", PORT), Handler) as httpd:
        if CERT_PATH and KEY_PATH and os.path.exists(CERT_PATH) and os.path.exists(KEY_PATH):
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(CERT_PATH, KEY_PATH)
            httpd.socket = context.wrap_socket(httpd.socket, server_side=True)
            print(f"Serving HTTPS on port {PORT}...")
        else:
            print(f"Serving HTTP on port {PORT}...")
        httpd.serve_forever()
except Exception as e:
    print(f"Error starting server: {e}")
    sys.exit(1)
