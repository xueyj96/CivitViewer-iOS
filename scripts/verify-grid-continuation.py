#!/usr/bin/env python3
"""Exercise the actual grid owner with controlled delayed request completions."""
from pathlib import Path
import subprocess, hashlib, json
root = Path(__file__).resolve().parents[1]
p = root / 'CivitViewer/UI/MediaGrid.swift'
s = p.read_text()
a = s.index('@MainActor @Observable final class GridContinuationLoader')
z = s.index('\nstruct MediaGrid: View', a)
code = s[a:z]
test = root / 'Tests/GridContinuationChecks.swift'
folder = root / 'build/grid-continuation-checks'; folder.mkdir(exist_ok=True)
f = folder / 'ActualGridContinuation.swift'; f.write_text(test.read_text().replace('// INSERT_GRID_LOADER', code))
binary = folder / 'checks'
subprocess.run(['xcrun','swiftc','-swift-version','5','-O','-parse-as-library',str(f),'-o',str(binary)],check=True)
subprocess.run([str(binary)],check=True,timeout=15)
(folder / 'source-receipt.json').write_text(json.dumps({'sourceSHA256':hashlib.sha256(p.read_bytes()).hexdigest(),'testSHA256':hashlib.sha256(test.read_bytes()).hexdigest(),'passed':True},indent=2)+'\n')
