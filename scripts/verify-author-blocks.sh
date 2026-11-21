#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$task_root/build"
xcrun swiftc \
  "$task_root/CivitViewer/Media/VideoDuration.swift" "$task_root/CivitViewer/Feed/Models.swift" \
  "$task_root/CivitViewer/Features/History/BrowsingHistoryTypes.swift" \
  "$task_root/CivitViewer/Features/Settings/AuthorBlocklist.swift" \
  "$task_root/Tests/AuthorBlocklistChecks.swift" \
  -o "$task_root/build/author-blocklist-checks"
"$task_root/build/author-blocklist-checks"
