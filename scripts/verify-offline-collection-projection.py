#!/usr/bin/env python3
"""Compile the production per-work collection projection against a controllable library double."""
from pathlib import Path
import hashlib
import json
import subprocess

root = Path(__file__).resolve().parents[1]
source_path = root / "CivitViewer/Features/Offline/OfflineLibrary.swift"
source = source_path.read_text()


def member(marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise ValueError(f"Unclosed production member: {marker}")


content_state = member("struct OfflineCollectionContentState")
projection = member("@MainActor final class OfflineCollectionContentProjection")
content_methods = "\n\n".join(member(marker) for marker in (
    "    func collectionContentState(",
    "    func localCollectionPlayback(",
    "    @concurrent private static func projectCollectionPlayback(",
    "    private nonisolated static func collectionFiles(",
    "    func verifiedCollectionMediaURL(",
))
test_path = root / "Tests/OfflineCollectionProjectionChecks.swift"
test = test_path.read_text()
test = test.replace("// INSERT_PROJECTION_TYPES", content_state + "\n\n" + projection)
test = test.replace("    // INSERT_COLLECTION_CONTENT_STATE", content_methods)

folder = root / "build/offline-collection-projection-checks"
folder.mkdir(parents=True, exist_ok=True)
generated = folder / "ActualOfflineCollectionProjection.swift"
generated.write_text(test)
binary = folder / "checks"
subprocess.run([
    "xcrun", "swiftc", "-swift-version", "5", "-O", "-parse-as-library",
    str(root / "CivitViewer/Media/VideoDuration.swift"),
    str(root / "CivitViewer/Feed/Models.swift"),
    str(generated), "-o", str(binary)
], check=True)
subprocess.run([str(binary)], check=True, timeout=20)
(folder / "source-receipt.json").write_text(json.dumps({
    "offlineLibrarySHA256": hashlib.sha256(source_path.read_bytes()).hexdigest(),
    "testSHA256": hashlib.sha256(test_path.read_bytes()).hexdigest(),
    "passed": True,
}, indent=2) + "\n")
