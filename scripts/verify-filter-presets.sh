#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$task_root/build"
xcrun swiftc \
  "$task_root/CivitViewer/Media/VideoDuration.swift" \
  "$task_root/CivitViewer/Feed/Models.swift" \
  "$task_root/CivitViewer/Features/Settings/BrowsingPreferences.swift" \
  "$task_root/CivitViewer/Features/Search/MediaSearch.swift" \
  "$task_root/CivitViewer/Features/Settings/FilterPresets.swift" \
  "$task_root/Tests/FilterPresetChecks.swift" \
  -o "$task_root/build/filter-preset-checks"
"$task_root/build/filter-preset-checks"
