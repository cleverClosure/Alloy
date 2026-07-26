# Author: Timur Isaev

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import re


CHECKPOINT_QUANTUM = 64 * 1024
PAYLOAD = bytes(index % 251 for index in range(CHECKPOINT_QUANTUM * 3 + 257))
RANGE_PATTERN = re.compile(r"bytes=(\d+)-\Z")


class TransportRequestHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        offset = 0
        status = 200
        ignores_range = self.path.startswith("/ignore-range/")
        range_header = None if ignores_range else self.headers.get("Range")
        if range_header is not None:
            match = RANGE_PATTERN.fullmatch(range_header)
            if match is None:
                self.send_error(400)
                return
            offset = int(match.group(1))
            if offset >= len(PAYLOAD):
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{len(PAYLOAD)}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            status = 206

        body = PAYLOAD[offset:]
        self.send_response(status)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("ETag", '"alloy-fault-matrix"')
        if status == 206:
            self.send_header(
                "Content-Range",
                f"bytes {offset}-{len(PAYLOAD) - 1}/{len(PAYLOAD)}",
            )
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, _format, *_arguments):
        pass


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), TransportRequestHandler)
    print(f"http://127.0.0.1:{server.server_port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
