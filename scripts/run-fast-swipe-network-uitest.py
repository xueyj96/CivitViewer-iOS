#!/usr/bin/env python3
"""Run the real timeline and AVPlayer probe with a localhost-only video fixture."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
VIDEO = ROOT / "Tests/Fixtures/playback-layout-fixture.mp4"
VIDEO_DURATION = 30.0  # Duration of the existing fast-start fixture.
RUN = re.compile(r"/([0-9A-F-]{36})/(ready|release-final|release-skipped|[123]\.mp4)")


class SwipesServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, bitrate_multiplier):
        super().__init__(("127.0.0.1", 49371), Handler)
        self.video = VIDEO.read_bytes()
        self.bytes_per_second = len(self.video) / VIDEO_DURATION * bitrate_multiplier
        self.lock = threading.Lock()
        self.runs = {}

    def event(self, run, name):
        with self.lock:
            return self.runs.setdefault(run, {}).setdefault(name, threading.Event())


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        match = RUN.fullmatch(self.path)
        if match is None:
            self.send_error(404)
            return
        run, path = match.groups()
        if path in {"ready", "release-final", "release-skipped"}:
            self.server.event(run, path).set()
            self.record(run, path, "control", None)
            self.respond(200, 0)
            return
        ranged = self.headers.get("Range")
        self.record(run, path, "request", ranged)
        gate = self.server.event(run, "release-final" if path == "3.mp4" else "release-skipped")
        if not gate.wait(timeout=50):
            self.send_error(504)
            return
        size = len(self.server.video)
        start, end = 0, size - 1
        if ranged:
            parsed = re.fullmatch(r"bytes=(\d+)-(\d*)", ranged)
            if not parsed:
                self.send_error(416)
                return
            start = int(parsed[1])
            if parsed[2]:
                end = min(end, int(parsed[2]))
            if start > end:
                self.send_error(416)
                return
        try:
            self.respond(206 if ranged else 200, end + 1 - start,
                         ("Content-Range", f"bytes {start}-{end}/{size}") if ranged else None)
            payload = memoryview(self.server.video)[start:end + 1]
            self.record(run, path, "first-byte", ranged)
            rate = self.server.bytes_per_second if path == "3.mp4" else 0
            if not rate:
                self.wfile.write(payload)
            else:
                clock = time.monotonic()
                chunk = 16 * 1024
                for offset in range(0, len(payload), chunk):
                    time.sleep(max(0.0, clock + offset / rate - time.monotonic()))
                    self.wfile.write(payload[offset:offset + chunk])
            self.record(run, path, "complete", ranged)
        except (BrokenPipeError, ConnectionResetError):
            self.record(run, path, "cancelled", ranged)

    def respond(self, status, size, content_range=None):
        self.send_response(status)
        self.send_header("Content-Type", "video/mp4" if size else "text/plain")
        self.send_header("Content-Length", str(size))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Cache-Control", "no-store")
        if content_range:
            self.send_header(*content_range)
        self.end_headers()

    @staticmethod
    def record(run, path, event, ranged):
        print("FAST_SWIPE_HTTP " + json.dumps({
            "run": run, "path": path, "event": event, "range": ranged, "seconds": time.monotonic(),
        }), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("simulator_udid")
    parser.add_argument("--final-bitrate-multiplier", type=float, default=0,
                        help="Throttle the final response to the given multiple of the fixture video bitrate.")
    args = parser.parse_args()
    if args.final_bitrate_multiplier < 0:
        parser.error("bitrate multiplier cannot be negative")
    with SwipesServer(args.final_bitrate_multiplier) as server:
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            command = [str(ROOT / "scripts/run-resume-prompt-uitests.sh"), args.simulator_udid,
                       "testFastSwipeNetworkPlaybackReachesFinalVisibleFrame"]
            return subprocess.run(command, env=os.environ | {"CIVIT_UI_TEST_OPTIMIZED": "1"}).returncode
        finally:
            server.shutdown()
            worker.join()


if __name__ == "__main__":
    sys.exit(main())
