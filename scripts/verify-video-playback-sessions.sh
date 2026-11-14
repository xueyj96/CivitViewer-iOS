#!/bin/bash
set -euo pipefail

task_root="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="$task_root/build"
mkdir -p "$output_dir"
log_file="$output_dir/172-playback-pool-final-checks.log"

source_file="$task_root/CivitViewer/VideoPlaybackSessions.swift"
source_sha_before="$(shasum -a 256 "$source_file" | awk '{print $1}')"
if [[ -n "${EXPECTED_PLAYBACK_POOL_SHA:-}" && "$source_sha_before" != "$EXPECTED_PLAYBACK_POOL_SHA" ]]; then
  printf 'Expected pool SHA %s; found %s\n' "$EXPECTED_PLAYBACK_POOL_SHA" "$source_sha_before" >&2
  exit 1
fi

printf 'Pool source SHA before build: %s\n' "$source_sha_before" | tee "$log_file"
if [[ -n "${EXPECTED_PLAYBACK_POOL_SHA:-}" ]]; then
  printf 'Requested frozen SHA: %s\n' "$EXPECTED_PLAYBACK_POOL_SHA" | tee -a "$log_file"
fi

xcrun swiftc -swift-version 6 -parse-as-library \
  "$source_file" \
  "$task_root/Tests/VideoPlaybackSessionChecks.swift" \
  -o "$output_dir/video-playback-session-checks"

"$output_dir/video-playback-session-checks" \
  "$task_root/Tests/Fixtures/playback-layout-fixture.mp4" 2>&1 | tee -a "$log_file"

source_sha_after="$(shasum -a 256 "$source_file" | awk '{print $1}')"
printf 'Pool source SHA after run: %s\n' "$source_sha_after" | tee -a "$log_file"
if [[ "$source_sha_before" != "$source_sha_after" ]]; then
  printf 'Pool source changed during verification\n' >&2
  exit 1
fi
