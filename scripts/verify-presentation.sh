#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$root/build"
xcrun swiftc "$root/CivitViewer/Navigation/PresentationLifecycle.swift" "$root/Tests/PresentationLifecycleChecks.swift" -o "$root/build/presentation-lifecycle-checks"
"$root/build/presentation-lifecycle-checks"
