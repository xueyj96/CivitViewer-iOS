#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$task_root/build"
xcrun swiftc \
  "$task_root/CivitViewer/Media/VideoDuration.swift" \
  "$task_root/CivitViewer/Feed/Models.swift" \
  "$task_root/CivitViewer/Diagnostics/LocalDiagnostics.swift" \
  "$task_root/CivitViewer/Diagnostics/PlaybackDiagnostics.swift" \
  "$task_root/CivitViewer/Features/Settings/BrowsingPreferences.swift" \
  "$task_root/CivitViewer/Features/Search/MediaSearch.swift" \
  "$task_root/CivitViewer/Features/Search/TagConjunctionPager.swift" \
  "$task_root/CivitViewer/Features/Search/TagMediaAvailability.swift" \
  "$task_root/Tests/TagMediaAvailabilityChecks.swift" \
  -o "$task_root/build/tag-media-availability-checks"
"$task_root/build/tag-media-availability-checks"
