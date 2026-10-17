#!/bin/bash
# Собирает подписанный .ipa iPhone-приложения. Запускать на маке.
#   build-device.sh [профиль]  — ad-hoc для своего телефона; профиль по умолчанию
#                                mobile/signing/Ilya.mobileprovision (внутри папки проекта).
#   build-device.sh appstore   — архив и .ipa для App Store Connect (ничего не загружает).
#                                Подпись автоматическая: в Xcode → Settings → Accounts нужен
#                                вход в команду 7SJ59D8JGU. Номер сборки: BUILD_NUMBER=2.
set -o pipefail
cd "$(dirname "$0")"
command -v xcodegen >/dev/null || brew install xcodegen || exit 1

if [ "$1" = appstore ]; then
  xcodegen generate || exit 1
  ARCHIVE=build/UniBrowser-AppStore.xcarchive
  xcodebuild -project UniBrowserMobile.xcodeproj -scheme UniBrowserMobile \
    -configuration Release -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" \
    PROVISIONING_PROFILE_SPECIFIER= ${BUILD_NUMBER:+CURRENT_PROJECT_VERSION=$BUILD_NUMBER} \
    archive > build-device.log 2>&1 || { echo "archive FAILED, см. mobile/build-device.log"; tail -20 build-device.log; exit 1; }
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -allowProvisioningUpdates \
    -exportOptionsPlist ExportOptions-AppStore.plist -exportPath build/appstore >> build-device.log 2>&1 || { echo "export FAILED, см. mobile/build-device.log"; tail -20 build-device.log; exit 1; }
  echo "Готово: mobile/build/appstore/UniBrowser.ipa — загрузить через Transporter или Xcode Organizer"
  exit 0
fi

PROFILE="${1:-signing/Ilya.mobileprovision}"  # внутри папки проекта, не трогаем ничего снаружи
[ -f "$PROFILE" ] || { echo "Не найден профиль: $PROFILE"; exit 1; }
mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles"
cp "$PROFILE" "$HOME/Library/MobileDevice/Provisioning Profiles/Ilya.mobileprovision"
xcodegen generate || exit 1
xcodebuild -project UniBrowserMobile.xcodeproj -scheme UniBrowserMobile \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/UniBrowserMobile.xcarchive archive > build-device.log 2>&1 || { echo "archive FAILED, см. mobile/build-device.log"; tail -20 build-device.log; exit 1; }
xcodebuild -exportArchive -archivePath build/UniBrowserMobile.xcarchive \
  -exportOptionsPlist exportOptions.plist -exportPath build/ipa >> build-device.log 2>&1 || { echo "export FAILED, см. mobile/build-device.log"; tail -20 build-device.log; exit 1; }
echo "Готово: mobile/build/ipa/UniBrowser.ipa"
