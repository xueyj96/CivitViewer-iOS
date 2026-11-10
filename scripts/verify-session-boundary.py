#!/usr/bin/env python3
"""Exercise the production request client with local OAuth, WebKit and public HTTP doubles."""
from hashlib import sha256
from pathlib import Path
import os
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
site_path = root / "CivitViewer/SiteSession.swift"
test_path = root / "Tests/SessionBoundaryChecks.swift"
site = site_path.read_text()
test = test_path.read_text()


def extract_braced(marker: str) -> str:
    start = site.index(marker)
    opening = site.index("{", start)
    depth = 0
    i = opening
    state = "code"
    block_depth = 0
    while i < len(site):
        if state == "line_comment":
            if site[i] == "\n":
                state = "code"
        elif state == "block_comment":
            if site.startswith("/*", i):
                block_depth += 1; i += 1
            elif site.startswith("*/", i):
                block_depth -= 1; i += 1
                if block_depth == 0: state = "code"
        elif state == "triple_string":
            if site.startswith('"""', i):
                state = "code"; i += 2
        elif state == "string":
            if site[i] == "\\":
                i += 1
            elif site[i] == '"':
                state = "code"
        else:
            if site.startswith("//", i):
                state = "line_comment"; i += 1
            elif site.startswith("/*", i):
                state = "block_comment"; block_depth = 1; i += 1
            elif site.startswith('"""', i):
                state = "triple_string"; i += 2
            elif site[i] == '"':
                state = "string"
            elif site[i] == "{":
                depth += 1
            elif site[i] == "}":
                depth -= 1
                if depth == 0:
                    return site[start:i + 1].strip()
        i += 1
    raise ValueError(f"Unclosed Swift member: {marker}")


identity_line = next(line.strip() for line in site.splitlines() if line.strip().startswith("var feedIdentity: String {"))
request = extract_braced("private func request<T: Decodable>(")
request = request.replace("private func request<T:", "func request<T:", 1)
hydrate_media = extract_braced("private func hydrateMedia(").replace("private func ", "func ", 1)

replacements = {
    "    // INSERT_EXTRACTED_FEED_IDENTITY": identity_line,
    "    // INSERT_EXTRACTED_REQUEST": request,
    "    // INSERT_EXTRACTED_HYDRATE_MEDIA": hydrate_media,
}
for marker, implementation in replacements.items():
    if test.count(marker) != 1:
        raise ValueError(f"Expected one extraction marker: {marker}")
    test = test.replace(marker, implementation, 1)

generated = root / "build/SessionBoundaryUnderTest.swift"
generated.parent.mkdir(exist_ok=True)
generated.write_text(test)
binary = root / "build/session-boundary-checks"
log_path = root / "build/session-boundary-checks.log"
env = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}


def run_logged(command, timeout=None):
    completed = subprocess.run(command, env=env, capture_output=True, text=True, timeout=timeout)
    with log_path.open("a") as log:
        log.write("$ " + " ".join(command) + "\n")
        log.write(completed.stdout)
        log.write(completed.stderr)
    if completed.stdout:
        print(completed.stdout, end="")
    if completed.returncode:
        print(completed.stderr, end="", file=sys.stderr)
        raise subprocess.CalledProcessError(completed.returncode, command)


log_path.write_text("")
sources = ["LocalDiagnostics.swift", "PlaybackDiagnostics.swift", "VideoDuration.swift", "Models.swift",
           "BrowsingPreferences.swift", "MediaSearch.swift", "LocalTagTypes.swift", "SiteRequestClient.swift"]
run_logged(["xcrun", "swiftc", *(str(root / "CivitViewer" / source) for source in sources), str(generated), "-o", str(binary)])
run_logged([str(binary)], timeout=45)
print("Source SiteSession.swift SHA-256:", sha256(site_path.read_bytes()).hexdigest())
print("Compiled production client: SiteRequestClient.swift")
print("Extracted production session members: feedIdentity, request adapter, hydrateMedia")
print("Build/test log:", log_path)
