#!/usr/bin/env bash
# Xcode "Build Rust Code" script phase 的唯一入口（tracked，可复现）。
#
# 背景：Tauri iOS 的 build phase 需要在 Xcode 的 script phase 里运行
#   `bun tauri ios xcode-script <flags...>`，而 Xcode 注入的进程环境里
#   既没有完整 Xcode 的 DEVELOPER_DIR，也没有项目内 Rust 工具链
#   （RUSTUP_HOME / CARGO_HOME / PATH）。之前靠外层 shell 透传 env 和
#   `tauri ios build -- KEY=VALUE`（build settings）解决，后者在 Tauri v2
#   里会被当成 **cargo 参数** 透传，直接导致 `cargo build` 报
#   "unexpected argument 'RUSTUP_HOME=...'"。
#
# 本脚本的职责（全部在 script phase 内部自包含完成，不依赖父进程 env）：
#   1. 定位项目 ROOT：Xcode 里 SRCROOT = <repo>/src-tauri/gen/apple，
#      故 ROOT = SRCROOT/../../..；退化时用脚本自身位置推导；
#   2. 显式 export 完整 Xcode 的 DEVELOPER_DIR（不改全局 xcode-select）；
#   3. 显式 export Rust 工具链环境：项目内 .tools 优先，否则系统回退；
#   4. cd 到项目 ROOT 后 exec `bun tauri ios xcode-script "$@"`，参数原样透传。
#
# 用法（由 project.yml 的 preBuildScript 调用，不要手工改参数）：
#   scripts/xcode-build-rust.sh -v --platform iOS --sdk-root ... --configuration release arm64

set -euo pipefail

# ---- 1. 定位项目 ROOT ------------------------------------------------------
ROOT=""
if [ -n "${SRCROOT:-}" ]; then
  CAND="$(cd "${SRCROOT}/../../.." 2>/dev/null && pwd || true)"
  if [ -n "$CAND" ] && [ -f "$CAND/src-tauri/Cargo.toml" ]; then
    ROOT="$CAND"
  fi
fi
if [ -z "$ROOT" ]; then
  CAND="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if [ -f "$CAND/src-tauri/Cargo.toml" ]; then
    ROOT="$CAND"
  fi
fi
if [ -z "$ROOT" ]; then
  echo "xcode-build-rust.sh: 无法定位项目 ROOT（SRCROOT=${SRCROOT:-unset}）" >&2
  exit 1
fi

# ---- 2. 固定完整 Xcode（不修改全局 xcode-select）--------------------------
FULL_XCODE="/Applications/Xcode.app/Contents/Developer"
if [ -x "$FULL_XCODE/usr/bin/xcodebuild" ]; then
  export DEVELOPER_DIR="$FULL_XCODE"
fi

# ---- 3. Rust 工具链：项目内 .tools 优先，系统回退 -------------------------
if [ -x "$ROOT/.tools/cargo/bin/cargo" ] && [ -d "$ROOT/.tools/rustup" ]; then
  export RUSTUP_HOME="$ROOT/.tools/rustup"
  export CARGO_HOME="$ROOT/.tools/cargo"
  # 真实 toolchain bin（直接用 cargo/rustc，不经过 rustup proxy）
  TOOLCHAIN_BIN="$(ls -d "$ROOT"/.tools/rustup/toolchains/*/bin 2>/dev/null | head -1 || true)"
  EXTRA_PATH="${TOOLCHAIN_BIN:-$ROOT/.tools/cargo/bin}:$ROOT/.tools/cargo/bin"
elif command -v cargo >/dev/null 2>&1; then
  EXTRA_PATH="$HOME/.cargo/bin"
  echo "xcode-build-rust.sh: 未发现项目内 .tools，回退系统 cargo：$(command -v cargo)"
else
  echo "xcode-build-rust.sh: 既无项目内 .tools 工具链，系统也无 cargo" >&2
  exit 1
fi

# bun（tauri CLI 的入口）也需要在 PATH 里
BUN_BIN="$(command -v bun 2>/dev/null || true)"
if [ -n "$BUN_BIN" ]; then
  EXTRA_PATH="$EXTRA_PATH:$(dirname "$BUN_BIN")"
else
  EXTRA_PATH="$EXTRA_PATH:/opt/homebrew/bin:$HOME/.bun/bin"
fi

export PATH="$EXTRA_PATH:$PATH"

# ---- 4. 调 Tauri CLI（参数原样透传）--------------------------------------
cd "$ROOT"
exec bun tauri ios xcode-script "$@"
