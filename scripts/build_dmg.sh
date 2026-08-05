#!/bin/zsh
set -euo pipefail

# PDFBinder.app、使い方ガイド、初回起動準備AppleScriptを配布用DMGへまとめる。
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
VERSION="1.0.1"
VOLUME_NAME="PDFBinder ${VERSION}"
OUTPUT_DIR="${PROJECT_DIR}/dist"
FINAL_DMG="${OUTPUT_DIR}/PDFBinder-${VERSION}.dmg"
CHECKSUM_FILE="${FINAL_DMG}.sha256"
RW_DMG="${OUTPUT_DIR}/PDFBinder-${VERSION}-rw.dmg"
STAGING_DIR="${PROJECT_DIR}/.build/dmg-staging"
MOUNT_DIR=""
IS_MOUNTED=false

cleanup() {
    if [[ "${IS_MOUNTED}" == true ]]; then
        hdiutil detach "${MOUNT_DIR}" -force >/dev/null 2>&1 || true
    fi
    rm -rf "${RW_DMG}"
}
trap cleanup EXIT

cd "${PROJECT_DIR}"
"${PROJECT_DIR}/scripts/build_app.sh"

rm -rf "${STAGING_DIR}" "${FINAL_DMG}" "${CHECKSUM_FILE}"
mkdir -p "${STAGING_DIR}/guide-assets"

ditto "${OUTPUT_DIR}/PDFBinder.app" "${STAGING_DIR}/PDFBinder.app"
ditto "${PROJECT_DIR}/Distribution/使い方ガイド.html" "${STAGING_DIR}/使い方ガイド.html"
ditto "${PROJECT_DIR}/Distribution/guide-assets" "${STAGING_DIR}/guide-assets"
ln -s /Applications "${STAGING_DIR}/Applications"

# 初回起動準備をAppleScriptアプリとしてコンパイルする。
HELPER_APP="${STAGING_DIR}/PDFBinder 初回起動準備.app"
osacompile -o "${HELPER_APP}" "${PROJECT_DIR}/Distribution/Gatekeeper解除.applescript"
HELPER_PLIST="${HELPER_APP}/Contents/Info.plist"

# osacompileが追加する未使用のプライバシー説明を取り除き、必要な情報だけに整える。
UNUSED_PRIVACY_KEYS=(
    NSAppleEventsUsageDescription
    NSAppleMusicUsageDescription
    NSCalendarsUsageDescription
    NSCameraUsageDescription
    NSContactsUsageDescription
    NSHomeKitUsageDescription
    NSMicrophoneUsageDescription
    NSPhotoLibraryUsageDescription
    NSRemindersUsageDescription
    NSSiriUsageDescription
)
for key in "${UNUSED_PRIVACY_KEYS[@]}"; do
    /usr/libexec/PlistBuddy -c "Delete :${key}" "${HELPER_PLIST}" >/dev/null 2>&1 || true
done

/usr/libexec/PlistBuddy -c "Set :CFBundleDevelopmentRegion ja" "${HELPER_PLIST}"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string jp.pdfbinder.firstlaunch" "${HELPER_PLIST}"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string PDFBinder 初回起動準備" "${HELPER_PLIST}"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string ${VERSION}" "${HELPER_PLIST}"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 1" "${HELPER_PLIST}"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 14.0" "${HELPER_PLIST}"
/usr/libexec/PlistBuddy -c "Set :NSSystemAdministrationUsageDescription PDFBinderの隔離属性を解除するために管理者認証を使用します。" "${HELPER_PLIST}"

codesign --force --deep --sign - --identifier jp.pdfbinder.firstlaunch "${HELPER_APP}"
codesign --verify --deep --strict "${HELPER_APP}"

/usr/bin/SetFile -a V "${STAGING_DIR}/guide-assets"

# 読み書き可能なイメージへFinderレイアウトを保存してから、圧縮DMGへ変換する。
hdiutil create \
    -volname "${VOLUME_NAME}" \
    -srcfolder "${STAGING_DIR}" \
    -fs HFS+ \
    -format UDRW \
    -ov \
    "${RW_DMG}" >/dev/null

ATTACH_OUTPUT="$(hdiutil attach "${RW_DMG}" \
    -readwrite \
    -noverify \
    -noautoopen)"
MOUNT_DIR="$(print -r -- "${ATTACH_OUTPUT}" | awk -F '\t' 'END {print $NF}')"
test -d "${MOUNT_DIR}"
IS_MOUNTED=true

/usr/bin/SetFile -a V "${MOUNT_DIR}/guide-assets"
sleep 1

DMG_VOLUME_NAME="${VOLUME_NAME}" osascript <<'APPLESCRIPT'
set volumeName to system attribute "DMG_VOLUME_NAME"

tell application "Finder"
    tell disk volumeName
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set pathbar visible of container window to false
        set bounds of container window to {140, 100, 860, 600}

        set viewOptions to icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 82
        set text size of viewOptions to 12
        set position of item "PDFBinder.app" to {145, 190}
        set position of item "Applications" to {575, 190}
        set position of item "PDFBinder 初回起動準備.app" to {225, 330}
        set position of item "使い方ガイド.html" to {500, 330}

        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach "${MOUNT_DIR}" >/dev/null
IS_MOUNTED=false

hdiutil convert "${RW_DMG}" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "${FINAL_DMG}" >/dev/null

hdiutil verify "${FINAL_DMG}" >/dev/null
shasum -a 256 "${FINAL_DMG}" | tee "${CHECKSUM_FILE}"

echo "DMG作成完了: ${FINAL_DMG}"
