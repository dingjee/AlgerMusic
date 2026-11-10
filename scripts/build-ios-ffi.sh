#!/usr/bin/env bash
# 构建 alger-ffi staticlib 并铺到 native/ios/libs/<platform>/。
#
# 用法：
#   sh scripts/build-ios-ffi.sh            # host（macOS，swift test 用）
#   sh scripts/build-ios-ffi.sh device     # iOS 真机（arm64）
#   sh scripts/build-ios-ffi.sh sim        # iOS 模拟器（arm64 + x86_64 fat）
#   sh scripts/build-ios-ffi.sh all        # 以上全部
#
# 要点：
#   1. iOS 交叉编译 **必须** DEVELOPER_DIR 指向完整 Xcode（ring 等
#      build script 调 xcrun 取 SDK；CommandLineTools 没有 iphoneos SDK）；
#   2. Rust 工具链优先项目内 .tools（与 build-ios.sh 同一约定）；
#   3. 产物只进 native/ios/libs/（gitignored），不入 target/ 之外的路径。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

MODE="${1:-host}"

FULL_XCODE="/Applications/Xcode.app/Contents/Developer"
[ -x "$FULL_XCODE/usr/bin/xcodebuild" ] || {
  echo "错误：找不到完整 Xcode（$FULL_XCODE）" >&2
  exit 1
}
export DEVELOPER_DIR="$FULL_XCODE"

if [ -x "$ROOT/.tools/cargo/bin/cargo" ] && [ -d "$ROOT/.tools/rustup" ]; then
  export RUSTUP_HOME="$ROOT/.tools/rustup"
  export CARGO_HOME="$ROOT/.tools/cargo"
  export PATH="$(ls -d "$ROOT"/.tools/rustup/toolchains/*/bin 2>/dev/null | head -1):$ROOT/.tools/cargo/bin:$PATH"
else
  command -v cargo >/dev/null 2>&1 || {
    echo "错误：未找到 .tools 工具链，且系统 cargo 不在 PATH" >&2
    exit 1
  }
fi

MANIFEST="$ROOT/crates/alger-ffi/Cargo.toml"
OUT="$ROOT/native/ios/libs"
mkdir -p "$OUT"

build_one() {
  local triple="$1" dest="$2"
  echo ">> 构建 $triple → $dest"
  cargo build --manifest-path "$MANIFEST" --release --target "$triple"
  mkdir -p "$OUT/$dest"
  cp "$ROOT/crates/alger-ffi/target/$triple/release/libalger_ffi.a" "$OUT/$dest/"
}

case "$MODE" in
  host)
    echo ">> 构建 host（$(uname -m)-apple-darwin）→ macos"
    cargo build --manifest-path "$MANIFEST" --release
    mkdir -p "$OUT/macos"
    cp "$ROOT/crates/alger-ffi/target/release/libalger_ffi.a" "$OUT/macos/"
    ;;
  device)
    build_one aarch64-apple-ios ios-device
    ;;
  sim)
    build_one aarch64-apple-ios-sim ios-sim
    build_one x86_64-apple-ios ios-sim-x86_64
    echo ">> 合并模拟器 fat lib"
    lipo -create \
      "$OUT/ios-sim/libalger_ffi.a" \
      "$OUT/ios-sim-x86_64/libalger_ffi.a" \
      -output "$OUT/ios-sim/libalger_ffi.a"
    rm -rf "$OUT/ios-sim-x86_64"
    ;;
  all)
    "$0" host
    "$0" device
    "$0" sim
    ;;
  *)
    echo "用法：$0 [host|device|sim|all]" >&2
    exit 2
    ;;
esac

echo ">> 完成：$OUT"
