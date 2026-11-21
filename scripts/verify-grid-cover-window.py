#!/usr/bin/env python3
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
grid = (root / "CivitViewer/UI/MediaGrid.swift").read_text()
creator = (root / "CivitViewer/Features/Authors/CreatorView.swift").read_text()
assert "onScrollTargetVisibilityChange(idType: Int.self, threshold: 0.05)" in grid
assert "projectedItems.map(\\.id)" not in grid
assert "_ = revision" not in grid
prep = creator[creator.index("let preparedCommit = await preparation.firstPage.value"):]
assert "paneFeed.requestKey == paneKey" in prep
assert "paneFeed.accepts(preparedCommit, identity: session.feedIdentity)" in prep
assert "if preparedStateIsConsumable { return }" in prep
assert prep.index("if preparedStateIsConsumable { return }") < prep.index("let retainedKey = paneFeed.requestKey == paneKey")
production = (root / "CivitViewer/UI/GridCoverImageWindow.swift").read_text()
window_source = production[production.index("@MainActor @Observable final class GridCoverImageSlot"):]
window_source = window_source.replace("@MainActor", "").replace("@Observable", "").replace("@ObservationIgnored", "")

stub = """
import Foundation
final class CachedPosterLoadResult {
    private(set) var clearCount = 0
    func clear() { clearCount += 1 }
}
"""
harness = (root / "Tests/GridCoverWindowChecks.swift").read_text()
with tempfile.TemporaryDirectory(prefix="grid-cover-window-") as temp:
    source = Path(temp) / "GridCoverWindowChecks.swift"
    binary = Path(temp) / "grid-cover-window-checks"
    source.write_text(stub + "\n" + window_source + "\n" + harness)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-O", "-parse-as-library", str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
