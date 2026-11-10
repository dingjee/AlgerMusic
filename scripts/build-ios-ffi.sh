#!/usr/bin/env bash
# 构建 alger-ffi staticlib 并打成 xcframework（native/ios/libs/AlgerFFI.xcframework）。
#
# 用法：
#   sh scripts/build-ios-ffi.sh            # host + iOS 全部（默认）
#   sh scripts/build-ios-ffi.sh host       # 仅 macOS（宿主测试用）
#   sh scripts/build-ios-ffi.sh device     # 仅 iOS 真机
#   sh scripts/build-ios-ffi.sh sim        # 仅 iOS 模拟器
#
# 要点：
#   1. iOS 交叉编译 **必须** DEVELOPER_DIR 指向完整 Xcode（ring 等
#      build script 调 xcrun 取 SDK；CommandLineTools 没有 iphoneos SDK）；
#   2. Rust 工具链优先项目内 .tools（与 build-ios.sh 同一约定）；
#   3. 产物只进 native/ios/libs/（gitignored）；xcframework 同时含
#      macOS / iOS 真机 / iOS 模拟器 slice，宿主测试与真机构建共用同一份；
#   4. macOS slice 只含当前宿主架构（Apple Silicon）；Intel 机器需自行
#      安装 x86_64-apple-darwin target 后再构建（脚本会提示）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

MODE="${1:-all}"

FULL_XCODE="/Applications/Xcode.app/Contents/Developer"
[ -x "$FULL_XCODE/usr/bin/xcodebuild" ] || {
  echo "错误：找不到完整 Xcode（${FULL_XCODE}）" >&2
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
HEADER_SRC="$ROOT/native/ios/ffi/alger_ffi.h"
OUT="$ROOT/native/ios/libs"
STAGE="$OUT/stage"
mkdir -p "$OUT"

# ---- 编译各平台 slice -------------------------------------------------
build_slice() {
  local triple="$1" name="$2"
  echo ">> 构建 $triple → $name"
  cargo build --manifest-path "$MANIFEST" --release --target "$triple"
  mkdir -p "$STAGE/$name"
  cp "$ROOT/crates/alger-ffi/target/$triple/release/libalger_ffi.a" "$STAGE/$name/libalger_ffi.a"
  cp "$HEADER_SRC" "$STAGE/$name/alger_ffi.h"
  cat > "$STAGE/$name/module.modulemap" <<'EOF'
module AlgerFFI {
    header "alger_ffi.h"
    export *
}
EOF
}

HOST_TRIPLE="$(rustc -vV | awk '/^host:/{print $2}')"

build_host() {
  build_slice "$HOST_TRIPLE" macos
}

build_device() {
  build_slice aarch64-apple-ios ios-device
}

build_sim() {
  build_slice aarch64-apple-ios-sim ios-sim
}

case "$MODE" in
  host) build_host ;;
  device) build_device ;;
  sim) build_sim ;;
  all)
    build_host
    build_device
    build_sim
    ;;
  *)
    echo "用法：$0 [all|host|device|sim]" >&2
    exit 2
    ;;
esac

# ---- 打 xcframework（按已有 slice 生成）--------------------------------
ARGS=()
for name in macos ios-device ios-sim; do
  [ -f "$STAGE/$name/libalger_ffi.a" ] || continue
  ARGS+=(-library "$STAGE/$name/libalger_ffi.a" -headers "$STAGE/$name")
done
if [ ${#ARGS[@]} -gt 0 ]; then
  echo ">> 生成 xcframework（${#ARGS[@]} / 2 个 slice）"
  rm -rf "$OUT/AlgerFFI.xcframework"
  # shellcheck disable=SC2086
  xcodebuild -create-xcframework "${ARGS[@]}" \
    -output "$OUT/AlgerFFI.xcframework" >/dev/null
  echo ">> 完成：$OUT/AlgerFFI.xcframework"
else
  echo ">> 没有可用的 slice，xcframework 未更新" >&2
  exit 1
fi
