#!/bin/bash
# Generates the Xcode project and builds UniBrowser; the full log goes to build.log
# so it can be read back without copying from the terminal.
# NO_OPEN=1 skips launching the app.
set -o pipefail
cd "$(dirname "$0")/.."
target=UniBrowser
command -v xcodegen >/dev/null || brew install xcodegen || exit 1
xcodegen generate || exit 1
xcodebuild -project UniBrowser.xcodeproj -scheme $target -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build > build.log 2>&1
status=$?
grep -E "error:|BUILD (SUCCEEDED|FAILED)" build.log | sort -u | head -40
if [ $status -eq 0 ]; then
  echo "Готово: build/Build/Products/Debug/$target.app"
  [ -n "$NO_OPEN" ] || open build/Build/Products/Debug/$target.app
fi
exit $status
