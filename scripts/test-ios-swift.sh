#!/usr/bin/env bash
# native/ios Swift 包宿主测试（可复现，不改全局 xcode-select）。
#
# 用法：
#   sh scripts/test-ios-swift.sh              # 构建 host FFI 库（如缺）并跑全部测试
#   sh scripts/test-ios-swift.sh --filter X   # 透传 swift test 的其它参数
#
# 与 scripts/test-swift.sh（macOS 包）同一套约定：
#   1. 只在命令级设置 DEVELOPER_DIR 指向完整 Xcode（CommandLineTools
#      没有 XCTest，swift test 直接失败）；
#   2. SwiftPM scratch / 日志只进 .artifacts/；
#   3. 退出码取自真实命令。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

FULL_XCODE="/Applications/Xcode.app/Contents/Developer"
[ -x "$FULL_XCODE/usr/bin/xcodebuild" ] || {
  echo "错误：找不到完整 Xcode（${FULL_XCODE}）" >&2
  exit 1
}
export DEVELOPER_DIR="$FULL_XCODE"

ARTIFACTS="$ROOT/.artifacts"
LOG_DIR="${ALGER_IOS_SWIFT_LOG_DIR:-$ARTIFACTS/logs}"
SCRATCH="${ALGER_IOS_SWIFT_SCRATCH:-$ARTIFACTS/ios-swift-build}"
mkdir -p "$LOG_DIR" "$SCRATCH"

# 1) FFI xcframework：缺失时先构建（macOS + iOS 真机 + 模拟器 slice）。
if [ ! -d "$ROOT/native/ios/libs/AlgerFFI.xcframework" ]; then
  echo ">> 构建 FFI xcframework…"
  sh "$ROOT/scripts/build-ios-ffi.sh" all
fi

# 2) swift test（日志进 .artifacts，退出码取真实命令）。
set +e
swift test --package-path "$ROOT/native/ios" \
  --scratch-path "$SCRATCH" \
  "$@" > "$LOG_DIR/ios-swift-test.log" 2>&1
code=$?
set -e
tail -n 20 "$LOG_DIR/ios-swift-test.log"
echo "swift test 退出码：${code}（完整日志：${LOG_DIR}/ios-swift-test.log）"
exit "$code"
