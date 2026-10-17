#!/bin/bash
# Generates the Xcode project and builds UniBrowser for iPhone (simulator, no
# signing). The full log goes to build.log so it can be read back.
set -o pipefail
cd "$(dirname "$0")"
command -v xcodegen >/dev/null || brew install xcodegen || exit 1
xcodegen generate || exit 1
xcodebuild -project UniBrowserMobile.xcodeproj -scheme UniBrowserMobile -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build > build.log 2>&1
status=$?
grep -E "error:|BUILD (SUCCEEDED|FAILED)" build.log | sort -u | head -40
[ $status -eq 0 ] && echo "Готово: build/Build/Products/Debug-iphonesimulator/UniBrowserMobile.app"
exit $status
