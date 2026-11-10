#!/usr/bin/env bash
# iOS 真机构建脚本（可复现，不改全局 xcode-select）。
#
# 用法：
#   scripts/build-ios.sh                 # 构建（官方 tauri ios build 管线）
#   scripts/build-ios.sh --install       # 构建并安装到已连接的测试机
#
# 设计要点：
#   1. 不依赖外部既有 shim：脚本在临时目录自建 xcodebuild wrapper
#      （强制 DEVELOPER_DIR 指向完整 Xcode 后 exec 真身），clean checkout 可复现；
#   2. Rust 工具链优先项目内 .tools（存在则用），否则回退系统 cargo
#      （要求系统 rustup default 已配置）；PATH 同时前置 **真实 toolchain bin**
#      （非 rustup proxy），Xcode「Build Rust Code」script phase 即使丢失
#      部分进程 env 也能找到可用的 cargo；
#   3. Rust 工具链环境由 **仓库内 tracked 脚本** scripts/xcode-build-rust.sh
#      在 Xcode script phase 内部自行导出（DEVELOPER_DIR / RUSTUP_HOME /
#      CARGO_HOME / PATH），不依赖父进程 env；
#      也 **绝不** 用 `tauri ios build -- KEY=VALUE` 透传 build settings：
#      Tauri v2 会把它们当作 **cargo 参数**，导致
#      `cargo build: unexpected argument 'RUSTUP_HOME=...'`；
#   4. 正式导出显式 `--export-method debugging --ci`（开发签名、非交互、
#      不走商店分发），导出失败时用 xcarchive + xcodebuild -exportArchive
#      -allowProvisioningUpdates 兜底重导（允许 provisioning 更新）；
#   5. 安装目标只认 **.app bundle**（xcarchive 的 Products/Applications），
#      产物路径用 find 在真实构建输出里定位，不做多层 glob 猜测。
#
# 日志：脚本内 LOG（默认 .artifacts/ios-build.log）是唯一日志，运行方
# 不需要也不要再把外层输出重定向到同一文件。退出码始终取构建命令本身
# （set +e 包住 pipeline 捕获 PIPESTATUS），tail 显示成功不代表构建成功。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

FULL_XCODE="/Applications/Xcode.app/Contents/Developer"
[ -x "$FULL_XCODE/usr/bin/xcodebuild" ] || {
  echo "错误：找不到完整 Xcode（${FULL_XCODE}）" >&2
  exit 1
}
# 外层进程也必须固定完整 Xcode：下面的 xcrun（取 SDKROOT）、exportArchive、
# devicectl 都在本 shell 里直接调用；shim 里的 export 只作用于子进程。
export DEVELOPER_DIR="$FULL_XCODE"

mkdir -p "$ROOT/.artifacts"
LOG="${ALGER_IOS_LOG:-$ROOT/.artifacts/ios-build.log}"
: > "$LOG"

# ---- 自建临时 xcodebuild shim（强制完整 Xcode）--------------------------
SHIM_DIR="$(mktemp -d /tmp/alger-xcodebuild-shim.XXXXXX)"
printf '%s\n' "$ROOT" > "$SHIM_DIR/.alger-project"
printf '%s\n' "$$" > "$SHIM_DIR/.alger-owner-pid"
trap 'rm -rf "$SHIM_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cat > "$SHIM_DIR/xcodebuild" <<EOF
#!/bin/sh
export DEVELOPER_DIR="$FULL_XCODE"
exec "$FULL_XCODE/usr/bin/xcodebuild" "\$@"
EOF
chmod +x "$SHIM_DIR/xcodebuild"

# ---- Rust 工具链：项目内 .tools 优先，系统回退 ---------------------------
# 这里只保证 **外层**（xcodebuild / exportArchive / devicectl）可用；
# Xcode script phase 内部的环境由 scripts/xcode-build-rust.sh 自行导出。
if [ -x "$ROOT/.tools/cargo/bin/cargo" ] && [ -d "$ROOT/.tools/rustup" ]; then
  export RUSTUP_HOME="$ROOT/.tools/rustup"
  export CARGO_HOME="$ROOT/.tools/cargo"
  # 真实 toolchain bin（cargo 直连，不经过 rustup proxy）
  TOOLCHAIN_BIN="$(ls -d "$ROOT"/.tools/rustup/toolchains/*/bin 2>/dev/null | head -1 || true)"
  export PATH="$SHIM_DIR:${TOOLCHAIN_BIN:-$ROOT/.tools/cargo/bin}:$ROOT/.tools/cargo/bin:/opt/homebrew/bin:$PATH"
else
  # 系统回退：要求 cargo 在 PATH 且 rustup default 已配置
  command -v cargo >/dev/null 2>&1 || {
    echo "错误：未找到 .tools 工具链，且系统 cargo 不在 PATH" >&2
    exit 1
  }
  export PATH="$SHIM_DIR:/opt/homebrew/bin:$PATH"
  echo ">> 未发现项目内 .tools，使用系统工具链：$(cargo --version 2>&1 | head -1)"
fi

# SDK 环境：先固定 DEVELOPER_DIR（经 shim 已保证），再取 iOS SDK 路径
SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
export SDKROOT

echo ">> xcodebuild: $(xcodebuild -version | head -1)"
echo ">> SDKROOT: $SDKROOT"
echo ">> rustc: $(rustc --version)"
echo ">> 日志: $LOG"

# ---- 官方管线构建 --------------------------------------------------------
# beforeBuildCommand 构建前端；Rust ios target 编译；xcodebuild archive +
# export（ExportOptions.plist / --export-method：debugging，自动签名）。
#
# 注意：**不要**在 `--` 之后追加 KEY=VALUE。Tauri v2 会把 `ios build` 的
# 额外参数当成 **cargo 参数** 透传到 `cargo build`，导致
# `unexpected argument 'RUSTUP_HOME=...'`（build settings 不是 cargo 参数）。
# Xcode script phase 需要的工具链环境由 scripts/xcode-build-rust.sh 自行导出。
set +e
bun tauri ios build --target aarch64 --export-method debugging --ci 2>&1 | tee -a "$LOG"
BUILD_EXIT="${PIPESTATUS[0]}"
set -e
if [ "${BUILD_EXIT}" -ne 0 ]; then
  echo "构建失败（exit=${BUILD_EXIT}），日志尾部：" >&2
  tail -40 "$LOG" >&2
  exit "${BUILD_EXIT}"
fi
echo ">> tauri ios build 成功"

# ---- 产物定位（真实输出，find 而非多层 glob 猜测）------------------------
ARCHIVE="$(find "$ROOT/src-tauri/gen/apple/build" -maxdepth 3 -type d -name '*.xcarchive' -not -path '*/Archives/*' 2>/dev/null | head -1 || true)"
APP_BUNDLE=""
if [ -n "$ARCHIVE" ]; then
  APP_BUNDLE="$(find "$ARCHIVE/Products/Applications" -maxdepth 1 -type d -name '*.app' 2>/dev/null | head -1 || true)"
fi
IPA="$(find "$ROOT/src-tauri/gen/apple/build" -maxdepth 4 -type f -name '*.ipa' 2>/dev/null | head -1 || true)"

# 导出失败兜底：xcarchive + -exportArchive 允许 provisioning 更新重导
if [ -z "$IPA" ] && [ -n "$ARCHIVE" ]; then
  echo ">> 未找到 IPA，使用 xcodebuild -exportArchive（-allowProvisioningUpdates）重导"
  EXPORT_DIR="$ROOT/src-tauri/gen/apple/build/export-fallback"
  mkdir -p "$EXPORT_DIR"
  set +e
  xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$ROOT/src-tauri/gen/apple/ExportOptions.plist" \
    -exportPath "$EXPORT_DIR" -allowProvisioningUpdates 2>&1 | tee -a "$LOG"
  EXPORT_EXIT="${PIPESTATUS[0]}"
  set -e
  if [ "${EXPORT_EXIT}" -eq 0 ]; then
    IPA="$(find "$EXPORT_DIR" -maxdepth 2 -type f -name '*.ipa' 2>/dev/null | head -1 || true)"
  else
    echo ">> 兜底导出失败（exit=${EXPORT_EXIT}），继续用 xcarchive 产物" | tee -a "$LOG"
  fi
fi

# .app 兜底：优先 xcarchive；无 archive 时从 IPA 解包
if [ -z "$APP_BUNDLE" ] && [ -n "$IPA" ]; then
  UNZIP_DIR="$ROOT/src-tauri/gen/apple/build/ipa-extract"
  rm -rf "$UNZIP_DIR"
  mkdir -p "$UNZIP_DIR"
  unzip -q "$IPA" -d "$UNZIP_DIR"
  APP_BUNDLE="$(find "$UNZIP_DIR/Payload" -maxdepth 1 -type d -name '*.app' 2>/dev/null | head -1 || true)"
fi

[ -n "$APP_BUNDLE" ] || {
  echo "错误：未找到可安装的 .app（archive=${ARCHIVE:-none} ipa=${IPA:-none}）" >&2
  exit 1
}

# ---- 产物自检：bundle id / 版本 / Files 共享 / 后台音频 / 签名 ------------
PLIST="$APP_BUNDLE/Info.plist"
echo ">> app:        $APP_BUNDLE"
echo ">> bundle id:  $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
echo ">> version:    $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
echo ">> file share: $(/usr/libexec/PlistBuddy -c 'Print :UIFileSharingEnabled' "$PLIST" 2>/dev/null || echo MISSING)"
echo ">> background: $(/usr/libexec/PlistBuddy -c 'Print :UIBackgroundModes' "$PLIST" 2>/dev/null || echo MISSING)"
codesign -dvv "$APP_BUNDLE" 2>&1 | grep -E "TeamIdentifier|Authority" | head -3 || true

# ---- 可选：安装到真机（只认 .app bundle）---------------------------------
if [ "${1:-}" = "--install" ]; then
  UDID="${ALGER_IOS_UDID:-00008130-000E59603CDB803A}"
  echo ">> 安装 .app 到设备 $UDID"
  set +e
  xcrun devicectl device install app --device "$UDID" "$APP_BUNDLE" 2>&1 | tee -a "$LOG"
  INSTALL_EXIT="${PIPESTATUS[0]}"
  set -e
  if [ "${INSTALL_EXIT}" -ne 0 ]; then
    echo "安装失败（exit=${INSTALL_EXIT}），日志尾部：" >&2
    tail -20 "$LOG" >&2
    exit "${INSTALL_EXIT}"
  fi
  echo ">> 安装完成（启动请用：xcrun devicectl device process launch --device $UDID <bundle-id>）"
fi

echo ">> 完成。app: $APP_BUNDLE ipa: ${IPA:-none}"
