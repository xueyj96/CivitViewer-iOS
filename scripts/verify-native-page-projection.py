#!/usr/bin/env python3
"""Exercise exact production projection/publication code, plus hosting/action boundary invariants."""
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

assert ".rootView =" not in source, "A retained UIKit hosting root must never be reassigned"
assert "[weak self] action" in source and "self?.dispatchPageAction(action, from: source)" in source
receive = member("        func receive(_ value:")
assert receive.index("latestConfiguration = value") < receive.index("if transition != nil")
assert "latestConfiguration = nil" in member("        func dismantle()")
view = (root / "CivitViewer/Media/MediaViewer.swift").read_text()
page = view[view.index("    @ViewBuilder private func page(id:"):view.index("\nenum MediaRailAction")]
prepared_callback = page[page.index("onPlaybackPrepared: {"):page.index("onQualifiedExposure: {")]
assert "action(.prepared)" in prepared_callback
assert "history.record" not in page and "openPage(" not in page and "onAuthor: onAuthor" not in page
assert "boundaryMotion.offset" not in view[view.index("    private func pageProjection("):view.index("    private func handlePageAction(")]
test = (root / "Tests/NativePageProjectionChecks.swift").read_text()
test = test.replace("// INSERT_PROJECTION", member("struct NativeMediaPageProjection"))
test = test.replace("// INSERT_PRESENTATION", member("@MainActor @Observable private final class NativePagePresentation").replace("private final", "final", 1))
generated = root / "build/NativePageProjectionUnderTest.swift"; generated.write_text(test)
binary = root / "build/native-page-projection-checks"
subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", str(generated), "-o", str(binary)], check=True)
subprocess.run([str(binary)], check=True, timeout=15)
print("Production host root is write-once; latest weak action dispatch is independent of queued configuration application")
