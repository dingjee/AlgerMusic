#!/usr/bin/env bash
# iOS 极简版（妈妈版）构建 / 安装脚本。
#
# 用法：
#   sh scripts/build-ios-app.sh                 # 模拟器 Debug 构建（不签名）
#   sh scripts/build-ios-app.sh device          # 真机 Debug 构建（自动签名）
#   sh scripts/build-ios-app.sh device --install # 真机构建并安装到已连接设备
#
# 流程：
#   1. 构建 FFI xcframework（macOS / iOS 真机 / 模拟器 slice）；
#   2. xcodegen 生成工程（project.yml 是唯一真源，生成的 .xcodeproj 不入库）；
#   3. xcodebuild 构建（模拟器不带签名；真机走 Team 9SVGN86A32 自动签名）；
#   4. --install 用 devicectl 装到已连接的真机。
#
# 日志：.artifacts/ios-app-build.log；退出码取自真实构建命令。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

MODE="${1:-sim}"
INSTALL=0
for arg in "$@"; do
  [ "$arg" = "--install" ] && INSTALL=1
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

mkdir -p "$ROOT/.artifacts"
LOG="$ROOT/.artifacts/ios-app-build.log"

APP_DIR="$ROOT/native/ios/App"
PROJECT="$APP_DIR/AlgerMusicMinimal.xcodeproj"

echo ">> 1/3 构建 FFI xcframework"
sh "$ROOT/scripts/build-ios-ffi.sh" all

echo ">> 2/3 生成 Xcode 工程"
xcodegen generate --spec "$APP_DIR/project.yml" --project "$APP_DIR"

echo ">> 3/3 构建（${MODE}）"
set +e
case "$MODE" in
  sim)
    xcodebuild build \
      -project "$PROJECT" \
      -scheme AlgerMusicMinimal \
      -configuration Debug \
      -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath "$ROOT/.artifacts/ios-app-derived" \
      ARCHS=arm64 \
      ONLY_ACTIVE_ARCH=YES \
      CODE_SIGNING_ALLOWED=NO \
      > "$LOG" 2>&1
    code=$?
    ;;
  device)
    xcodebuild build \
      -project "$PROJECT" \
      -scheme AlgerMusicMinimal \
      -configuration Debug \
      -destination 'generic/platform=iOS' \
      -derivedDataPath "$ROOT/.artifacts/ios-app-derived" \
      -allowProvisioningUpdates \
      > "$LOG" 2>&1
    code=$?
    ;;
  *)
    echo "用法：$0 [sim|device] [--install]" >&2
    exit 2
    ;;
esac
set -e

tail -n 25 "$LOG"
if [ "$code" -ne 0 ]; then
  echo "构建失败（退出码 ${code}），完整日志：$LOG" >&2
  exit "$code"
fi

APP_PATH="$ROOT/.artifacts/ios-app-derived/Build/Products"
if [ "$MODE" = "sim" ]; then
  APP_PATH="$APP_PATH/Debug-iphonesimulator/AlgerMusicMinimal.app"
else
  APP_PATH="$APP_PATH/Debug-iphoneos/AlgerMusicMinimal.app"
fi
[ -d "$APP_PATH" ] || { echo "产物缺失：$APP_PATH" >&2; exit 1; }
echo ">> 产物：$APP_PATH"

if [ "$INSTALL" -eq 1 ]; then
  echo ">> 安装到已连接设备…"
  xcrun devicectl device install app --device "$ALGER_IOS_DEVICE" "$APP_PATH"
fi
