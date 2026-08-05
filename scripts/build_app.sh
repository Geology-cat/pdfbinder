#!/bin/zsh
set -euo pipefail

# SwiftPMのRelease実行ファイルから、起動可能なmacOSアプリバンドルを作成する。
SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
OUTPUT_DIR="${PROJECT_DIR}/dist"
APP_DIR="${OUTPUT_DIR}/PDFBinder.app"
CONTENTS_DIR="${APP_DIR}/Contents"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
ICONSET_DIR="$(mktemp -d)/PDFBinder.iconset"

cleanup() {
    rm -rf "${ICONSET_DIR:h}"
}
trap cleanup EXIT

cd "${PROJECT_DIR}"
SWIFT_BUILD_ARGS=(
    -c release
    --arch x86_64
    --arch arm64
    --scratch-path .build/universal
)
swift build "${SWIFT_BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}" "${ICONSET_DIR}"

ditto "${BIN_DIR}/PDFBinder" "${MACOS_DIR}/PDFBinder"
ditto "${PROJECT_DIR}/Resources/Info.plist" "${CONTENTS_DIR}/Info.plist"

# SVGのマスターからmacOS標準の各解像度を生成する。
for size in 16 32 128 256 512; do
    sips -s format png -z "${size}" "${size}" \
        "${PROJECT_DIR}/Resources/AppIcon.svg" \
        --out "${ICONSET_DIR}/icon_${size}x${size}.png" >/dev/null
    double_size=$((size * 2))
    sips -s format png -z "${double_size}" "${double_size}" \
        "${PROJECT_DIR}/Resources/AppIcon.svg" \
        --out "${ICONSET_DIR}/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "${ICONSET_DIR}" -o "${RESOURCES_DIR}/PDFBinder.icns"

plutil -lint "${CONTENTS_DIR}/Info.plist" >/dev/null
codesign --force --deep --sign - --identifier jp.pdfbinder.app "${APP_DIR}"
codesign --verify --deep --strict "${APP_DIR}"

# 同じ出力先へ再ビルドした場合でも、Finderが最新のアイコン情報を使うように
# アプリバンドルをLaunch Servicesへ強制再登録する。
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "${LSREGISTER}" ]]; then
    "${LSREGISTER}" -f "${APP_DIR}"
fi

echo "ビルド完了: ${APP_DIR}"
