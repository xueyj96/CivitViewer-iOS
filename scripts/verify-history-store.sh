#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$task_root/build"
xcrun swiftc "$task_root/CivitViewer/Diagnostics/PlaybackDiagnostics.swift" "$task_root/CivitViewer/Diagnostics/LocalDiagnostics.swift" "$task_root/CivitViewer/Media/VideoDuration.swift" "$task_root/CivitViewer/Feed/Models.swift" "$task_root/CivitViewer/Features/History/BrowsingHistoryTypes.swift" "$task_root/CivitViewer/Features/History/BrowsingHistoryDatabase.swift" "$task_root/CivitViewer/Features/History/BrowsingHistory.swift" "$task_root/Tests/BrowsingHistoryStoreChecks.swift" -o "$task_root/build/browsing-history-store-checks"
"$task_root/build/browsing-history-store-checks"
