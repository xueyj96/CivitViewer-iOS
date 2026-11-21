#!/usr/bin/env python3
"""Compile the exact production item resolver/job against narrow account/file doubles."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
source = (root / "CivitViewer/Features/Offline/OfflineLibrary.swift").read_text()

def member(marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 0
    # These members contain no brace literals or comments with unmatched braces.
    for i in range(opening, len(source)):
        if source[i] == "{": depth += 1
        elif source[i] == "}":
            depth -= 1
            if depth == 0: return source[start:i+1]
    raise ValueError(marker)

sync = member("    private func sync(")
assert sync.index("if let targetID") < sync.index("session.refreshCollections()")
assert "lastScan = Date()" in sync
job = member("    private func syncCollectionItem(")
assert "lastScan" not in job and "refreshCollections" not in job and "collectionPage" not in job
resolver = member("@MainActor enum OfflineCollectionItemResolver")
test = (root / "Tests/OfflineCollectionJobChecks.swift").read_text()
test = test.replace("    // INSERT_ACCEPT_UPDATE", member("    func accept(_ update:"))
test = test.replace("// INSERT_RESOLVER", resolver).replace("    // INSERT_SINGLE_ITEM_JOB", job.replace("private func", "func", 1))
generated = root / "build/OfflineCollectionJobUnderTest.swift"
generated.parent.mkdir(exist_ok=True)
generated.write_text(test)
binary = root / "build/offline-collection-job-checks"
subprocess.run(["xcrun", "swiftc", "-swift-version", "5", *(str(root / "CivitViewer" / f) for f in ["Media/VideoDuration.swift", "Feed/Models.swift"]), str(generated), "-o", str(binary)], check=True)
subprocess.run([str(binary)], check=True, timeout=30)
print("Compiled production: OfflineCollectionItemResolver, syncCollectionItem; checked target dispatch precedes inventory scan")
