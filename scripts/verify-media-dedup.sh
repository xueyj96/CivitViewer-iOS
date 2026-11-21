#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$task_root/build"
xcrun swiftc "$task_root/CivitViewer/Media/VideoDuration.swift" "$task_root/CivitViewer/Feed/Models.swift" "$task_root/Tests/MediaDedupChecks.swift" -o "$task_root/build/media-dedup-checks"
"$task_root/build/media-dedup-checks"
