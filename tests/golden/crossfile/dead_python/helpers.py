def used_helper(n):
    return n * 2


def old_helper(n):
    return n * 3


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        return self.path
