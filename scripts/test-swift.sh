#!/usr/bin/env bash
# SwiftPM（原生端 E1）可复现测试脚本。
#
# 用法：
#   sh scripts/test-swift.sh              # 构建桥接二进制（如缺）并跑全部 Swift 测试
#   sh scripts/test-swift.sh --filter X   # 透传 swift test 的其它参数
#
# 并发隔离（多个任务同时跑 Swift 测试时用，避免互相覆盖构建产物与日志）：
#   ALGER_SWIFT_SCRATCH=/path/to/scratch   # 覆盖 SwiftPM scratch path
#   ALGER_SWIFT_LOG_DIR=/path/to/logs      # 覆盖日志目录（每个任务一个）
#
# 设计要点：
#  1. **不改系统 xcode-select**：只在命令级设置 DEVELOPER_DIR 指向完整 Xcode
#     （CommandLineTools 没有 XCTest 框架，swift test 会直接失败）；
#  2. **不依赖外部 cargo**：优先用仓库内 .tools 工具链（CARGO_HOME / RUSTUP_HOME），
#     桥接二进制缺失时现场构建 crates/alger-bridge；
#  3. **产物只进 .artifacts/**：SwiftPM scratch path、日志都在 .artifacts 下，
#     不污染源码目录、不触碰用户数据；
#  4. **退出码取自真实命令**：不用未启用 pipefail 的取尾管道伪装成功。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

ARTIFACTS="$ROOT/.artifacts"
LOG_DIR="${ALGER_SWIFT_LOG_DIR:-$ARTIFACTS/logs}"
SCRATCH="${ALGER_SWIFT_SCRATCH:-$ARTIFACTS/swift-build}"
mkdir -p "$LOG_DIR" "$SCRATCH"

# 1) 工具链：完整 Xcode（只在命令级生效，不动系统设置）
if [ -x "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild" ]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
else
  echo "警告：找不到完整 /Applications/Xcode.app，XCTest 可能不可用" >&2
fi

# 2) Rust 工具链：仓库内优先
if [ -x "$ROOT/.tools/cargo/bin/cargo" ]; then
  export CARGO_HOME="$ROOT/.tools/cargo"
  export RUSTUP_HOME="$ROOT/.tools/rustup"
  export PATH="$ROOT/.tools/cargo/bin:$PATH"
fi

BRIDGE="$ROOT/crates/alger-bridge/target/debug/alger-bridge"
# **总是**构建（cargo 增量）：只看二进制是否存在会漏掉「源码已改、二进制还是旧的」，
# 测试就会跑在过期实现上，结论不可信。
echo "构建桥接二进制（增量）：$BRIDGE"
cargo build --manifest-path "$ROOT/crates/alger-bridge/Cargo.toml" \
  > "$LOG_DIR/swift-bridge-build.log" 2>&1 || {
    echo "桥接构建失败，见 $LOG_DIR/swift-bridge-build.log" >&2
    tail -20 "$LOG_DIR/swift-bridge-build.log" >&2
    exit 1
  }
if [ ! -x "$BRIDGE" ]; then
  echo "桥接二进制缺失：$BRIDGE" >&2
  exit 1
fi
export ALGER_BRIDGE_BIN="$BRIDGE"

# 3) Swift 测试
echo "运行 Swift 测试（真实桥接：${ALGER_BRIDGE_BIN}）"
swift test \
  --package-path "$ROOT/native/macos" \
  --scratch-path "$SCRATCH" \
  "$@" \
  2>&1 | tee "$LOG_DIR/swift-test.log"
status="${PIPESTATUS[0]}"
echo "swift test 退出码：$status"
exit "$status"
