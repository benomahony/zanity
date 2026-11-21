from http.server import BaseHTTPRequestHandler


class Handler(BaseHTTPRequestHandler):
    def forward(self, value):
        self.send_header("X-Forwarded-User", value)

    def fixed(self):
        self.send_header("Content-Type", "text/plain")
