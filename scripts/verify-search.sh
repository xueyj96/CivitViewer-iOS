#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$task_root/build"
xcrun swiftc "$task_root/CivitViewer/Diagnostics/PlaybackDiagnostics.swift" "$task_root/CivitViewer/Diagnostics/LocalDiagnostics.swift" "$task_root/CivitViewer/Media/VideoDuration.swift" "$task_root/CivitViewer/Feed/Models.swift" "$task_root/CivitViewer/Features/Settings/BrowsingPreferences.swift" "$task_root/CivitViewer/Features/Search/MediaSearch.swift" "$task_root/CivitViewer/Features/Search/LocalTagTypes.swift" "$task_root/CivitViewer/Features/Search/TagDirectory.swift" "$task_root/CivitViewer/Features/Authors/Biography.swift" "$task_root/Tests/SearchChecks.swift" -o "$task_root/build/search-checks"
"$task_root/build/search-checks"
