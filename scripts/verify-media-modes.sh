#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$root/build"
xcrun swiftc "$root/CivitViewer/VideoDuration.swift" "$root/CivitViewer/Models.swift" "$root/CivitViewer/BrowsingPreferences.swift" "$root/CivitViewer/BrowsingHistoryTypes.swift" "$root/CivitViewer/MediaSearch.swift" "$root/CivitViewer/FilterPresets.swift" "$root/Tests/MediaModeChecks.swift" -o "$root/build/media-mode-checks"
"$root/build/media-mode-checks"
