import http.server
import socketserver
import sys
import os

if len(sys.argv) != 4:
    print("Usage: python3 sub_server.py <PORT> <TOKEN> <FILE_PATH>")
    sys.exit(1)

PORT = int(sys.argv[1])
TOKEN = sys.argv[2]
FILE_PATH = sys.argv[3]

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
                    self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
                    self.end_headers()
                    self.wfile.write(f.read())
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
        httpd.serve_forever()
except Exception as e:
    print(f"Error starting server: {e}")
    sys.exit(1)
