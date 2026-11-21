#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
out_dir="$(mktemp -d)"
trap 'rm -rf "$out_dir"' EXIT
xcrun swiftc \
  "$task_root/CivitViewer/Media/VideoDuration.swift" \
  "$task_root/CivitViewer/Feed/Models.swift" \
  "$task_root/CivitViewer/Diagnostics/LocalDiagnostics.swift" \
  "$task_root/CivitViewer/Diagnostics/PlaybackDiagnostics.swift" \
  "$task_root/CivitViewer/Features/Settings/BrowsingPreferences.swift" \
  "$task_root/CivitViewer/Features/Search/MediaSearch.swift" \
  "$task_root/CivitViewer/Features/Search/TagConjunctionPager.swift" \
  "$task_root/CivitViewer/Features/Search/TagMediaAvailability.swift" \
  "$task_root/Tests/TagObservationChecks.swift" \
  -o "$out_dir/tag-observation-checks"
"$out_dir/tag-observation-checks"
