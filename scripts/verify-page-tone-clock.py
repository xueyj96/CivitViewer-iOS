#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,subprocess
root=Path(__file__).resolve().parents[1]
source=root/'CivitViewer/Navigation/HeaderHandoff.swift'
s=source.read_text();start=s.index('@MainActor @Observable\nfinal class PageToneClock');end=s.index('\n@MainActor\nstruct PageToneTransition',start)
test=root/'Tests/PageToneClockChecks.swift'
folder=root/'build/page-tone-clock-checks';folder.mkdir(parents=True,exist_ok=True)
combined=folder/'Checks.swift'
combined.write_text('import Foundation\nimport QuartzCore\nimport SwiftUI\nimport Observation\nstruct PageToneTransition { static let duration: Double = 0.3 }\n'+s[start:end]+test.read_text())
subprocess.run(['swiftc','-swift-version','5','-O','-parse-as-library',str(combined),'-o',str(folder/'checks')],check=True)
subprocess.run([str(folder/'checks')],check=True)
(folder/'source-receipt.json').write_text(json.dumps({'source':str(source),'sourceSHA256':hashlib.sha256(source.read_bytes()).hexdigest(),'testsSHA256':hashlib.sha256(test.read_bytes()).hexdigest(),'passed':True},indent=2)+'\n')
