#!/usr/bin/env python3
from pathlib import Path
import hashlib,json,subprocess
root=Path(__file__).resolve().parents[1]
source=root/'CivitViewer/Features/Collections/CollectionRead.swift';test=root/'Tests/ScopedDetailReadChecks.swift'
folder=root/'build/scoped-detail-read-checks';folder.mkdir(parents=True,exist_ok=True)
subprocess.run(['swiftc','-swift-version','5','-O','-parse-as-library',str(source),str(test),'-o',str(folder/'checks')],check=True)
subprocess.run([str(folder/'checks')],check=True)
(folder/'source-receipt.json').write_text(json.dumps({'sourceSHA256':hashlib.sha256(source.read_bytes()).hexdigest(),'testSHA256':hashlib.sha256(test.read_bytes()).hexdigest(),'passed':True},indent=2)+'\n')
