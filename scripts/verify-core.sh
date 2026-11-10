#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$task_root/build"
xcrun swiftc \
  "$task_root/CivitViewer/VideoDuration.swift" "$task_root/CivitViewer/Models.swift" \
  "$task_root/CivitViewer/BrowsingPreferences.swift" \
  "$task_root/CivitViewer/MediaSearch.swift" \
  "$task_root/CivitViewer/FeedRequest.swift" \
  "$task_root/CivitViewer/CollectionRead.swift" \
  "$task_root/Tests/CoreChecks.swift" \
  -o "$task_root/build/core-checks"
"$task_root/build/core-checks"
xcrun swiftc "$task_root/CivitViewer/OfflineDiskUsage.swift" \
  "$task_root/Tests/OfflineDiskUsageChecks.swift" -o "$task_root/build/offline-disk-usage-checks"
"$task_root/build/offline-disk-usage-checks"
xcrun swiftc "$task_root/CivitViewer/VideoDuration.swift" "$task_root/CivitViewer/Models.swift" \
  "$task_root/CivitViewer/OfflineDiskUsage.swift" "$task_root/CivitViewer/OfflineFileStore.swift" \
  "$task_root/CivitViewer/MediaRepairStore.swift" "$task_root/Tests/OfflineFileStoreChecks.swift" \
  -o "$task_root/build/offline-file-store-checks"
"$task_root/build/offline-file-store-checks"
