#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$task_root/build"
xcrun swiftc "$task_root/CivitViewer/Media/VideoDuration.swift" "$task_root/CivitViewer/Feed/Models.swift" \
    "$task_root/CivitViewer/Feed/JSONCacheFile.swift" "$task_root/CivitViewer/Features/Authors/FollowingList.swift" \
    "$task_root/Tests/FollowingListChecks.swift" -o "$task_root/build/following-list-checks"
"$task_root/build/following-list-checks"
