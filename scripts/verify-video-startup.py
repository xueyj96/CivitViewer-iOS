#!/usr/bin/env python3
"""Exercise the actual pure startup policy without an AVPlayer or UI surrogate."""
from pathlib import Path
import hashlib,json,subprocess
root=Path(__file__).resolve().parents[1];source=root/'CivitViewer/Media/VideoSurface.swift';s=source.read_text()
a=s.index('private enum VideoStartupPreview:');z=s.index('\nprivate struct PlayerLayerView:',a)
poster_source=root/'CivitViewer/Media/BitmapMediaSurface.swift';ps=poster_source.read_text()
ia=ps.index('enum CachedPosterResourceIdentity: Equatable {')
iz=ps.index('\n}\n\n@MainActor @Observable final class CachedPosterLoadResult',ia)+2
identity=ps[ia:iz]
test=root/'Tests/VideoStartupPresentationChecks.swift';folder=root/'build/video-startup-checks';folder.mkdir(exist_ok=True)
f=folder/'ActualPolicy.swift';f.write_text(test.read_text().replace('// INSERT_STARTUP_POLICY',s[a:z]).replace('// INSERT_CACHED_POSTER_IDENTITY',identity))
binary=folder/'checks';subprocess.run(['xcrun','swiftc','-swift-version','5','-O','-parse-as-library',str(f),'-o',str(binary)],check=True)
subprocess.run([str(binary)],check=True,timeout=10)
(folder/'source-receipt.json').write_text(json.dumps({'sourceSHA256':hashlib.sha256(source.read_bytes()).hexdigest(),'posterIdentitySHA256':hashlib.sha256(poster_source.read_bytes()).hexdigest(),'testSHA256':hashlib.sha256(test.read_bytes()).hexdigest(),'passed':True},indent=2)+'\n')
