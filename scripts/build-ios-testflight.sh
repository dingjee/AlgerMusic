#!/usr/bin/env bash
# TestFlight（App Store Connect 内测）打包脚本：archive → 导出 .ipa →（可选）上传。
#
# 用法：
#   sh scripts/build-ios-testflight.sh              # archive + 导出 .ipa
#   sh scripts/build-ios-testflight.sh --upload     # 导出后自动上传到 App Store Connect
#   sh scripts/build-ios-testflight.sh --no-sign    # 只 archive 且 **不签名**（本地验证用，不可上传）
#   BUILD_NUMBER=42 sh scripts/build-ios-testflight.sh --upload   # 指定构建号
#
# 上传需要 App Store Connect API Key（环境变量）：
#   ASC_KEY_ID      密钥 ID（10 位）
#   ASC_ISSUER_ID   Issuer ID（UUID）
#   ASC_KEY_PATH    .p8 文件路径
# 没有 API Key 时，产物 .ipa 可用 Transporter.app / Xcode Organizer 手动上传。
#
# 产物：
#   .artifacts/ios-archive/AlgerMusicMinimal.xcarchive   归档
#   .artifacts/ios-export/AlgerMusicMinimal.ipa           可上传的包
#
# 依赖：Xcode（含完整 Xcode）、xcodegen、已登录的 Apple ID（Team 9SVGN86A32）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

UPLOAD=0
NO_SIGN=0
for arg in "$@"; do
  [ "$arg" = "--upload" ] && UPLOAD=1
  [ "$arg" = "--no-sign" ] && NO_SIGN=1
done

FULL_XCODE="/Applications/Xcode.app/Contents/Developer"
[ -x "$FULL_XCODE/usr/bin/xcodebuild" ] || {
  echo "错误：找不到完整 Xcode（${FULL_XCODE}）" >&2
  exit 1
}
export DEVELOPER_DIR="$FULL_XCODE"

command -v xcodegen >/dev/null 2>&1 || {
  echo "错误：需要 xcodegen（brew install xcodegen）" >&2
  exit 1
}

# 构建号：App Store Connect 要求递增；默认用时间戳（合法整数）。
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%y%m%d%H%M)}"
# 签名团队：与 project.yml 的 DEVELOPMENT_TEAM 一致（导出选项要用）。
TEAM_ID="${TEAM_ID:-MFMGY838LG}"
APP_DIR="$ROOT/native/ios/App"
PROJECT="$APP_DIR/AlgerMusicMinimal.xcodeproj"
ARCHIVE_DIR="$ROOT/.artifacts/ios-archive"
EXPORT_DIR="$ROOT/.artifacts/ios-export"
LOG="$ROOT/.artifacts/ios-testflight.log"
mkdir -p "$ARCHIVE_DIR" "$EXPORT_DIR"

echo ">> 1/4 构建 FFI xcframework"
sh "$ROOT/scripts/build-ios-ffi.sh" all

echo ">> 2/4 生成 Xcode 工程"
xcodegen generate --spec "$APP_DIR/project.yml" --project "$APP_DIR"

echo ">> 3/4 archive（Release，build ${BUILD_NUMBER}）"
rm -rf "$ARCHIVE_DIR/AlgerMusicMinimal.xcarchive"
if [ "$NO_SIGN" -eq 1 ]; then
  # 未签名：只验证 Release 构建能过（**不可上传**）。
  set +e
  xcodebuild archive \
    -project "$PROJECT" \
    -scheme AlgerMusicMinimal \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE_DIR/AlgerMusicMinimal.xcarchive" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    CODE_SIGNING_ALLOWED=NO \
    > "$LOG" 2>&1
  code=$?
  set -e
  if [ "$code" -ne 0 ]; then
    echo "archive 失败（退出码 ${code}）：" >&2
    grep -E "error:" "$LOG" | sort -u | head -12 >&2
    echo "完整日志：${LOG}" >&2
    exit "$code"
  fi
  echo ">> 未签名归档就绪：${ARCHIVE_DIR}/AlgerMusicMinimal.xcarchive"
  echo ">> （未签名包不可上传；登录 Team 账号后重跑不带 --no-sign 即可导出 .ipa）"
  exit 0
fi
set +e
xcodebuild archive \
  -project "$PROJECT" \
  -scheme AlgerMusicMinimal \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_DIR/AlgerMusicMinimal.xcarchive" \
  -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  > "$LOG" 2>&1
code=$?
set -e
if [ "$code" -ne 0 ]; then
  echo "archive 失败（退出码 ${code}）：" >&2
  grep -E "error:|Provisioning|Signing|requires a development team|No profiles" "$LOG" | sort -u | head -12 >&2
  echo "完整日志：${LOG}" >&2
  exit "$code"
fi

echo ">> 4/4 导出 .ipa（app-store-connect）"
EXPORT_PLIST="$EXPORT_DIR/ExportOptions.plist"
cat > "$EXPORT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>stripSwiftSymbols</key>
    <true/>
    <key>uploadSymbols</key>
    <true/>
</dict>
</plist>
EOF

rm -f "$EXPORT_DIR/AlgerMusicMinimal.ipa"
set +e
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_DIR/AlgerMusicMinimal.xcarchive" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -allowProvisioningUpdates \
  > "$LOG.export" 2>&1
code=$?
set -e
if [ "$code" -ne 0 ]; then
  echo "导出失败（退出码 ${code}）：" >&2
  tail -n 20 "$LOG.export" >&2
  exit "$code"
fi

IPA="$EXPORT_DIR/AlgerMusicMinimal.ipa"
[ -f "$IPA" ] || { echo "产物缺失：${IPA}" >&2; exit 1; }
echo ">> .ipa 就绪：${IPA}（构建号 ${BUILD_NUMBER}）"

if [ "$UPLOAD" -eq 1 ]; then
  [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] && [ -n "${ASC_KEY_PATH:-}" ] || {
    echo "错误：--upload 需要 ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH 三个环境变量" >&2
    exit 2
  }
  echo ">> 上传到 App Store Connect…"
  set +e
  xcrun altool --upload-app \
    -f "$IPA" \
    -t ios \
    --apiKey "$ASC_KEY_ID" \
    --apiIssuer "$ASC_ISSUER_ID" \
    > "$LOG.upload" 2>&1
  code=$?
  set -e
  if [ "$code" -ne 0 ]; then
    echo "上传失败（退出码 ${code}）：" >&2
    tail -n 20 "$LOG.upload" >&2
    exit "$code"
  fi
  echo ">> 上传成功（到 App Store Connect → TestFlight → 内部测试构建）"
else
  echo ">> 未上传：用 Transporter.app 打开 ${IPA}，或加 --upload 并提供 ASC API Key"
fi
