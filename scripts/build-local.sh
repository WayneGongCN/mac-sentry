#!/bin/zsh
set -euo pipefail
task_repo="${0:A:h:h}"
task_build="${SENTRY_BUILD_DIR:-$task_repo/.build-local}"
task_config="${1:-Release}"
xcodebuild -project "$task_repo/Sentry.xcodeproj" -scheme Sentry \
  -configuration "$task_config" -derivedDataPath "$task_build" \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
codesign --verify --deep --strict "$task_build/Build/Products/$task_config/MacSentry.app"
print -r -- "$task_build/Build/Products/$task_config/MacSentry.app"
