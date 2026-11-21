#!/usr/bin/env python3
"""Check the production presentation-scoped route owner and stale stack writes."""
from pathlib import Path
import subprocess
root = Path(__file__).resolve().parents[1]
s = (root / 'CivitViewer/Media/MediaViewer.swift').read_text()
a = s.index('@MainActor @Observable final class PlaybackNavigationOwner')
b = s.index('{', a)
depth = 0
for i in range(b, len(s)):
    if s[i] == '{': depth += 1
    elif s[i] == '}':
        depth -= 1
        if depth == 0:
            body = s[a:i+1]
            break
source = (root / 'Tests/PlaybackNavigationOwnerChecks.swift').read_text().replace('// INSERT_OWNER', body)
p = root / 'build/PlaybackNavigationOwnerUnderTest.swift'
p.write_text(source)
exe = root / 'build/playback-navigation-owner-checks'
subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(p), '-o', str(exe)], check=True)
subprocess.run([str(exe)], check=True, timeout=15)
