#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$root/build"
xcrun swiftc "$root/CivitViewer/Media/VideoDuration.swift" "$root/CivitViewer/Feed/Models.swift" "$root/CivitViewer/Features/Settings/BrowsingPreferences.swift" "$root/CivitViewer/Features/History/BrowsingHistoryTypes.swift" "$root/CivitViewer/Features/Search/MediaSearch.swift" "$root/CivitViewer/Features/Settings/FilterPresets.swift" "$root/Tests/MediaModeChecks.swift" -o "$root/build/media-mode-checks"
"$root/build/media-mode-checks"
