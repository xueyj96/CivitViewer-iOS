#!/usr/bin/env python3
"""Verify actual presentation lifetime policy independently of SwiftUI rendering."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
source = (root / 'CivitViewer/Media/MediaViewer.swift').read_text()
chrome = source[source.index('@MainActor @Observable final class ViewingChromeController'):source.index('\nlet playbackRailFadeDuration')]
start = source.index('@MainActor\nfinal class MediaDeckPresentationLease')
lease = source[start:source.index('\n@MainActor\nfinal class MediaDeckVisibility', start)]
test = (root / 'Tests/MediaDeckPresentationLeaseChecks.swift').read_text().replace('// INSERT_CHROME', chrome).replace('// INSERT_LEASE', lease)
generated = root / 'build/MediaDeckPresentationLeaseUnderTest.swift'
generated.write_text(test)
exe = root / 'build/presentation-lease-checks'
subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(generated), '-o', str(exe)], check=True)
subprocess.run([str(exe)], check=True, timeout=15)
