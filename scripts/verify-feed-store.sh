#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$task_root/build"
xcrun swiftc "$task_root/CivitViewer/Diagnostics/PlaybackDiagnostics.swift" "$task_root/CivitViewer/Features/Search/LocalTagTypes.swift" "$task_root/CivitViewer/Features/Search/TagMediaAvailability.swift" "$task_root/CivitViewer/Features/Search/TagConjunctionPager.swift" "$task_root/CivitViewer/Diagnostics/LocalDiagnostics.swift" "$task_root/CivitViewer/Media/VideoDuration.swift" "$task_root/CivitViewer/Feed/Models.swift" "$task_root/CivitViewer/Features/Settings/BrowsingPreferences.swift" "$task_root/CivitViewer/Features/Search/MediaSearch.swift" "$task_root/CivitViewer/Features/History/BrowsingHistoryTypes.swift" "$task_root/CivitViewer/Features/Settings/AuthorBlocklist.swift" "$task_root/CivitViewer/Features/Timeline/TimelineState.swift" "$task_root/CivitViewer/Feed/FeedRequest.swift" "$task_root/CivitViewer/Feed/MediaReading.swift" "$task_root/CivitViewer/Feed/FeedStore.swift" "$task_root/Tests/FeedStoreChecks.swift" -o "$task_root/build/feed-store-checks"
"$task_root/build/feed-store-checks"
