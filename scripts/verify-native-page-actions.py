#!/usr/bin/env python3
"""Run actual production source callback creation and dispatch with controlled late receipts."""
from pathlib import Path
import subprocess
root = Path(__file__).resolve().parents[1]
source = (root / "CivitViewer/Media/NativeMediaPager.swift").read_text()
def member(marker):
    start = source.index(marker); opening = source.index("{", start); depth = 0
    for i in range(opening, len(source)):
        if source[i] == "{": depth += 1
        elif source[i] == "}":
            depth -= 1
            if depth == 0: return source[start:i+1]
    raise ValueError(marker)
test = (root / "Tests/NativePageActionChecks.swift").read_text()
for marker, code in {
    "// INSERT_ACTION": member("enum NativeMediaPageAction"),
    "// INSERT_SOURCE": member("struct NativeMediaPageSource"),
    "// INSERT_EDGE_OWNER": member("struct NativeMediaEdgeDrag"),
    "    // INSERT_KEY": member("        struct PageKey:"),
    "    // INSERT_FACTORY": member("        private func pageAction(").replace("private func", "func", 1),
    "    // INSERT_DISPATCH": member("        private func dispatchPageAction("),
    "    // INSERT_ACCEPT_SOURCE": member("        private func acceptsPageSource(").replace("latest: NativeMediaPagerController", "latest: Configuration"),
    "    // INSERT_CANCEL_EDGE": member("        private func cancelEdgeDrag("),
}.items(): test = test.replace(marker, code)
generated = root / "build/NativePageActionUnderTest.swift"; generated.write_text(test)
binary = root / "build/native-page-action-checks"
subprocess.run(["xcrun", "swiftc", "-swift-version", "5", *(str(root / "CivitViewer" / f) for f in ["Media/VideoDuration.swift", "Feed/Models.swift"]), str(generated), "-o", str(binary)], check=True)
subprocess.run([str(binary)], check=True, timeout=20)
