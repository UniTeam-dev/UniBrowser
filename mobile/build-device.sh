#!/bin/bash
# Собирает подписанный ad-hoc .ipa iPhone-приложения для установки на зарегистрированный телефон.
# Запускать на маке. Профиль лежит в mobile/signing/ (внутри папки проекта).
set -o pipefail
cd "$(dirname "$0")"
PROFILE="${1:-signing/Ilya.mobileprovision}"  # внутри папки проекта, не трогаем ничего снаружи
[ -f "$PROFILE" ] || { echo "Не найден профиль: $PROFILE"; exit 1; }
mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles"
cp "$PROFILE" "$HOME/Library/MobileDevice/Provisioning Profiles/Ilya.mobileprovision"
command -v xcodegen >/dev/null || brew install xcodegen || exit 1
xcodegen generate || exit 1
xcodebuild -project UniBrowserMobile.xcodeproj -scheme UniBrowserMobile \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/UniBrowserMobile.xcarchive archive > build-device.log 2>&1 || { echo "archive FAILED, см. mobile/build-device.log"; tail -20 build-device.log; exit 1; }
xcodebuild -exportArchive -archivePath build/UniBrowserMobile.xcarchive \
  -exportOptionsPlist exportOptions.plist -exportPath build/ipa >> build-device.log 2>&1 || { echo "export FAILED, см. mobile/build-device.log"; tail -20 build-device.log; exit 1; }
echo "Готово: mobile/build/ipa/UniBrowserMobile.ipa"
