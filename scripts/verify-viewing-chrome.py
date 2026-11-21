#!/usr/bin/env python3
"""Verify production chrome projections and actual Observation dependencies."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
source = (root / 'CivitViewer/Media/MediaViewer.swift').read_text()
start = source.index('@MainActor @Observable final class ViewingChromeController')
end = source.index('\nlet playbackRailFadeDuration', start)
test = (root / 'Tests/ViewingChromeChecks.swift').read_text().replace('// INSERT_CONTROLLER', source[start:end])
generated = root / 'build/ViewingChromeUnderTest.swift'
generated.write_text(test)
executable = root / 'build/viewing-chrome-checks'
subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(generated), '-o', str(executable)], check=True)
subprocess.run([str(executable)], check=True, timeout=15)
