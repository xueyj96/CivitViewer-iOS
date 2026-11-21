#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$task_root/build"
xcrun swiftc \
  "$task_root/CivitViewer/Media/VideoDuration.swift" "$task_root/CivitViewer/Feed/Models.swift" \
  "$task_root/CivitViewer/Features/Settings/BrowsingPreferences.swift" \
  "$task_root/CivitViewer/Features/Search/MediaSearch.swift" \
  "$task_root/CivitViewer/Feed/FeedRequest.swift" \
  "$task_root/CivitViewer/Features/Collections/CollectionRead.swift" \
  "$task_root/Tests/CoreChecks.swift" \
  -o "$task_root/build/core-checks"
"$task_root/build/core-checks"
xcrun swiftc "$task_root/CivitViewer/Features/Offline/OfflineDiskUsage.swift" \
  "$task_root/Tests/OfflineDiskUsageChecks.swift" -o "$task_root/build/offline-disk-usage-checks"
"$task_root/build/offline-disk-usage-checks"
xcrun swiftc "$task_root/CivitViewer/Media/VideoDuration.swift" "$task_root/CivitViewer/Feed/Models.swift" \
  "$task_root/CivitViewer/Features/Offline/OfflineDiskUsage.swift" "$task_root/CivitViewer/Features/Offline/OfflineFileStore.swift" \
  "$task_root/CivitViewer/Media/MediaRepairStore.swift" "$task_root/Tests/OfflineFileStoreChecks.swift" \
  -o "$task_root/build/offline-file-store-checks"
"$task_root/build/offline-file-store-checks"
