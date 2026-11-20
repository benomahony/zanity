"""The HTTP server the mock services under tests/ listen with."""

import socketserver
from http.server import ThreadingHTTPServer

LOOPBACK = "127.0.0.1"


class LoopbackServer(ThreadingHTTPServer):
    """ThreadingHTTPServer on the loopback address, bound without http.server's reverse DNS lookup
    of the address, socket.getfqdn(), whose answer only names the server in responses and which
    can wait on a resolver for seconds."""

    def __init__(self, handler: type) -> None:
        super().__init__((LOOPBACK, 0), handler)

    def server_bind(self) -> None:
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        assert host == LOOPBACK, f"the mock bound {host!r}; it serves only the loopback address the tests point zanity at"
        assert port > 0, f"the mock bound port {port}; binding port 0 must leave the system's chosen port in server_address"
        self.server_name = host
        self.server_port = port
