#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_tmp="$(mktemp -d)"
trap 'rm -rf "$task_tmp"' EXIT
xcrun swiftc "$task_root/CivitViewer/Diagnostics/LocalDiagnostics.swift" \
  "$task_root/CivitViewer/Diagnostics/PlaybackDiagnostics.swift" \
  "$task_root/CivitViewer/Media/VideoDuration.swift" "$task_root/CivitViewer/Feed/Models.swift" \
  "$task_root/CivitViewer/Features/Settings/BrowsingPreferences.swift" "$task_root/CivitViewer/Features/Search/MediaSearch.swift" \
  "$task_root/CivitViewer/Features/Search/LocalTagTypes.swift" "$task_root/Tests/SiteCooldownChecks.swift" \
  -o "$task_tmp/site-cooldown-checks"
"$task_tmp/site-cooldown-checks"
