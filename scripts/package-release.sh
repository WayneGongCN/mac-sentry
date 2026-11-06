#!/bin/zsh
set -euo pipefail
task_repo="${0:A:h:h}"
task_build="${SENTRY_BUILD_DIR:-$task_repo/.build-local}"
"$task_repo/scripts/build-local.sh" Release
task_app="$task_build/Build/Products/Release/MacSentry.app"
task_version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$task_app/Contents/Info.plist")
task_output="$task_build/releases/v$task_version"
task_archive="MacSentry-v$task_version-macos-arm64.zip"
mkdir -p "$task_output"
ditto -c -k --sequesterRsrc --keepParent "$task_app" "$task_output/$task_archive"
(
  cd "$task_output"
  shasum -a 256 "$task_archive" > SHA256SUMS.txt
)
print -r -- "$task_output/$task_archive"
print -r -- "$task_output/SHA256SUMS.txt"
