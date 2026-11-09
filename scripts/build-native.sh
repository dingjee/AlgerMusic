#!/usr/bin/env bash
# 构建原生 macOS trial 应用包（SwiftPM 应用 + Rust 桥接），并提供独立校验。
#
# 用法：
#   sh scripts/build-native.sh [--trial] [--configuration debug|release]
#                              [--output /绝对路径/AlgerMusicPlayer.app]
#   sh scripts/build-native.sh --verify /绝对路径/AlgerMusicPlayer.app
#
# 约定（与交付要求一致）：
#   * **默认 trial**：Swift 侧 `-Xswiftc -DALGER_TRIAL` 与 Rust 侧 `ALGER_TRIAL=1`
#     （编译期 option_env!）**永远同时**生效，两半的身份不可能不一致；
#   * **默认 release**：`--configuration debug` 只影响 Swift 产物与桥接产物；
#   * **产物自包含**：`Contents/MacOS/AlgerMusicPlayer` 是应用可执行文件，
#     `Contents/Resources/alger-bridge` 是随包桥接（运行时不需要 ALGER_BRIDGE_BIN）；
#   * **唯一入口身份**：`CFBundleIdentifier=com.alger.music.trial`，
#     显示名 “Alger Music”（沿用 scripts/localize-trial.swift）；
#   * **不污染源码树**：日志 / Swift scratch / cargo target 全部落在
#     `.artifacts/native-delivery/build/`，Swift 使用**独立** scratch，
#     不占用 `swift test` 的 scratch；
#   * **--verify 是独立校验**：只校验一个已存在的 .app（结构、签名、显示名、
#     只读运行时身份），不构建、不启动 GUI、不写任何 profile；
#   * **--output 受限**：只能写在仓库 `.artifacts/` 下、basename 固定
#     `AlgerMusicPlayer.app`，拒绝符号链接，永远拒绝 `dist/`；
#   * **发布是事务性的**：新包先在暂存目录校验通过，才复制到输出同父的
#     唯一临时目录；旧包被改名保留，失败时恢复，**不会先删旧包**。
#
# 退出码：
#   0 成功；1 校验/构建失败；2 参数错误。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${ROOT}"

CONFIGURATION="release"
OUTPUT=""
OUTPUT_EXPLICIT=0
VERIFY_TARGET=""
EXPLICIT_TRIAL=0

ARTIFACTS="${ROOT}/.artifacts"
DELIVERY="${ARTIFACTS}/native-delivery"
BUILD_DIR="${DELIVERY}/build"
LOG_DIR="${BUILD_DIR}/logs"
SWIFT_SCRATCH="${BUILD_DIR}/swift-scratch"
CARGO_TARGET_DIR="${BUILD_DIR}/cargo-target"
DEFAULT_OUTPUT="${ARTIFACTS}/native-build/AlgerMusicPlayer.app"

BUNDLE_NAME="AlgerMusicPlayer"
BUNDLE_FILENAME="AlgerMusicPlayer.app"
BUNDLE_IDENTIFIER="com.alger.music.trial"
TRIAL_PROFILE_NAME="AlgerMusicPlayer.trial"
RUNTIME_IDENTITY_FLAG="--print-runtime-identity"

usage() {
  cat <<'EOF'
Usage:
  sh scripts/build-native.sh [--trial] [--configuration debug|release]
                             [--output /absolute/path/AlgerMusicPlayer.app]
  sh scripts/build-native.sh --verify /absolute/path/AlgerMusicPlayer.app

Options:
  --trial                trial 构建（默认；仅支持这一种身份）
  --no-trial             不支持：普通版 bundle 身份与数据目录尚未确定
  --configuration debug|release   构建配置（默认 release）
  --output PATH          输出 .app 绝对路径（默认 .artifacts/native-build/AlgerMusicPlayer.app）
                         限制：必须位于仓库 .artifacts/ 下，basename 固定 AlgerMusicPlayer.app，
                         拒绝符号链接，永远拒绝 dist/
  --verify PATH          独立校验已存在的 .app（不构建；不能与 --output 同时使用）
EOF
}

die_usage() {
  echo "参数错误：$*" >&2
  usage >&2
  exit 2
}

fail() {
  echo "[build-native] 失败：$*" >&2
  exit 1
}

log() {
  echo "[build-native] $*"
}

# 删除一棵**自己创建的**目录树。
#
# `ditto` 会把源文件的 `UF_IMMUTABLE`（uchg）标志一起复制过去，
# 于是 `rm -rf` 会在该文件上失败并留下残留（残留还会让
# `rm -rf .artifacts` 失败）。这里只清**不可变标志**，不动内容与权限，
# 作用范围严格限定在传进来的那棵树（build 自己建的暂存 / 发布目录）。
remove_owned_tree() {
  local target="$1"
  [ -e "${target}" ] || return 0
  if [ -d "${target}" ]; then
    find "${target}" -flags +uchg -exec chflags -h nouchg '{}' \; 2>/dev/null || true
    find "${target}" -flags +uchg -exec chflags -h nouchg '{}' \; 2>/dev/null || true
  fi
  rm -rf -- "${target}"
}

# ---------------------------------------------------------------------------
# 路径安全：输出必须落在仓库 .artifacts/ 下，且不得经过符号链接
# ---------------------------------------------------------------------------
assert_no_symlink_path() {
  local path="$1"
  local current="${path}"
  local next
  while :; do
    if [ -L "${current}" ]; then
      die_usage "拒绝符号链接路径：${current}"
    fi
    [ "${current}" = "${ROOT}" ] && break
    next="$(dirname "${current}")"
    [ "${next}" = "${current}" ] && break
    current="${next}"
  done
}

# 拒绝 `.` 与 `..` 路径组件。
#
# 为什么必须先做这一步：纯字符串前缀检查会被
# `<repo>/.artifacts/../dist/AlgerMusicPlayer.app` 绕过 —— 前缀看起来在
# .artifacts 之下，实际落点却在 dist/。因此先消灭歧义组件，再做前缀检查。
reject_dot_components() {
  local path="$1"
  local rest="${path#/}"
  local component
  while [ -n "${rest}" ]; do
    component="${rest%%/*}"
    case "${rest}" in
      */*) rest="${rest#*/}" ;;
      *) rest="" ;;
    esac
    case "${component}" in
      "."|"..")
        die_usage "路径不能包含 . 或 .. 组件（请给规范化的绝对路径）：${path}"
        ;;
    esac
  done
}

validate_output_path() {
  local out="$1"
  local base parent parent_real artifacts_real

  case "${out}" in
    /*) ;;
    *) die_usage "--output 需要绝对路径（收到 ${out}）" ;;
  esac

  # 1) 先拒绝 `.` / `..` 组件，消除 `.artifacts/../dist` 这类绕过。
  reject_dot_components "${out}"

  # 2) 永远拒绝 dist/（即使将来放宽 .artifacts 限制）。
  case "${out}" in
    "${ROOT}/dist"|"${ROOT}/dist/"*) die_usage "--output 永远拒绝 dist/：${out}" ;;
  esac

  # 3) 规范化之后必须位于仓库 .artifacts/ 之下。
  case "${out}" in
    "${ARTIFACTS}/"*) ;;
    *) die_usage "--output 必须位于 ${ARTIFACTS}/ 之下（收到 ${out}）" ;;
  esac

  base="$(basename "${out}")"
  [ "${base}" = "${BUNDLE_FILENAME}" ] || die_usage "--output 的 basename 必须是 ${BUNDLE_FILENAME}（收到 ${base}）"

  # 4) 拒绝输出本身及所有父目录的软链。
  assert_no_symlink_path "${out}"

  parent="$(dirname "${out}")"
  if [ ! -d "${parent}" ]; then
    mkdir -p "${parent}" || die_usage "无法创建输出目录：${parent}"
    assert_no_symlink_path "${parent}"
  fi

  # 5) 物理路径复核：真实父目录必须仍然落在 .artifacts 内。
  artifacts_real="$(cd "${ARTIFACTS}" 2>/dev/null && pwd -P)" \
    || die_usage "无法解析 .artifacts 的真实路径"
  parent_real="$(cd "${parent}" 2>/dev/null && pwd -P)" \
    || die_usage "无法解析输出父目录的真实路径：${parent}"
  case "${parent_real}" in
    "${artifacts_real}/"*) ;;
    *) die_usage "--output 的真实父目录不在 .artifacts 内：${parent_real}" ;;
  esac
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --trial)
      EXPLICIT_TRIAL=1
      shift
      ;;
    --no-trial)
      die_usage "只支持 trial 身份（--no-trial 尚未定义 bundle 标识与数据目录）"
      ;;
    --configuration)
      [ $# -ge 2 ] || die_usage "--configuration 缺少取值"
      CONFIGURATION="$2"
      shift 2
      ;;
    --configuration=*)
      CONFIGURATION="${1#*=}"
      shift
      ;;
    --output)
      [ $# -ge 2 ] || die_usage "--output 缺少取值"
      OUTPUT="$2"
      OUTPUT_EXPLICIT=1
      shift 2
      ;;
    --output=*)
      OUTPUT="${1#*=}"
      OUTPUT_EXPLICIT=1
      shift
      ;;
    --verify)
      [ $# -ge 2 ] || die_usage "--verify 缺少取值"
      VERIFY_TARGET="$2"
      shift 2
      ;;
    --verify=*)
      VERIFY_TARGET="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die_usage "未知参数 $1"
      ;;
  esac
done

case "${CONFIGURATION}" in
  debug|release) ;;
  *) die_usage "--configuration 只支持 debug|release（收到 ${CONFIGURATION}）" ;;
esac

if [ -n "${VERIFY_TARGET}" ] && [ "${OUTPUT_EXPLICIT}" -eq 1 ]; then
  die_usage "--verify 与 --output 不能同时使用（校验既有包 / 构建新包是两种模式）"
fi

if [ -n "${VERIFY_TARGET}" ]; then
  case "${VERIFY_TARGET}" in
    /*) ;;
    *) die_usage "--verify 需要绝对路径（收到 ${VERIFY_TARGET}）" ;;
  esac
  [ -d "${VERIFY_TARGET}" ] || die_usage "--verify 目标不存在：${VERIFY_TARGET}"
else
  if [ "${OUTPUT_EXPLICIT}" -eq 0 ]; then
    OUTPUT="${DEFAULT_OUTPUT}"
  fi
  validate_output_path "${OUTPUT}"
fi

mkdir -p "${LOG_DIR}"

# ---------------------------------------------------------------------------
# 工具链：完整 Xcode（只在命令级生效，**不改系统 xcode-select**）
# ---------------------------------------------------------------------------
if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

# Rust 工具链：仓库内 .tools 优先
if [ -x "${ROOT}/.tools/cargo/bin/cargo" ] && [ -d "${ROOT}/.tools/rustup" ]; then
  export RUSTUP_HOME="${ROOT}/.tools/rustup"
  export CARGO_HOME="${ROOT}/.tools/cargo"
  export PATH="${ROOT}/.tools/cargo/bin:${PATH}"
fi

# ---------------------------------------------------------------------------
# trial 身份：Swift 编译期标志与 Rust 编译期环境变量必须一致
# ---------------------------------------------------------------------------
export ALGER_TRIAL=1
SWIFT_TRIAL_FLAGS=(-Xswiftc "-DALGER_TRIAL")

# ---------------------------------------------------------------------------
# 只读运行时身份校验
#
# 约定：
#   * 只调用 `AlgerMusicPlayer --print-runtime-identity`（**只读**：不建 AppModel、
#     不启动桥接、不写任何 profile），输出单行 JSON；
#   * **只在该命令上清除 ALGER_APP_DATA_DIR**，以便看到“默认 profile”；
#   * 该命令若不存在，进程会退化成启动 GUI —— 因此先做静态检查，
#     命中不了就直接失败（不 fallback、不略过），并且运行时带超时兜底；
#   * 绝不在无隔离的情况下放行 GUI 启动。
# ---------------------------------------------------------------------------
runtime_identity_json() {
  local app="$1"
  local exe="${app}/Contents/MacOS/${BUNDLE_NAME}"
  local out="${LOG_DIR}/runtime-identity.json"
  local err="${LOG_DIR}/runtime-identity.stderr"
  local pid waited status

  if ! grep -a -q -F -- "${RUNTIME_IDENTITY_FLAG}" "${exe}" 2>/dev/null; then
    echo "[build-native] 可执行文件里没有 ${RUNTIME_IDENTITY_FLAG}：只读身份接口不存在" >&2
    return 1
  fi
  : > "${out}"
  : > "${err}"

  # 只读命令：不继承隔离目录覆盖，因此报告的是默认 profile。
  env -u ALGER_APP_DATA_DIR -u ALGER_BRIDGE_BIN \
    "${exe}" "${RUNTIME_IDENTITY_FLAG}" >"${out}" 2>"${err}" &
  pid=$!

  waited=0
  while kill -0 "${pid}" 2>/dev/null; do
    waited=$((waited + 1))
    if [ "${waited}" -ge 150 ]; then
      kill -TERM "${pid}" 2>/dev/null || true
      sleep 1
      kill -KILL "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
      echo "[build-native] 只读身份查询超时：${RUNTIME_IDENTITY_FLAG} 没有生效" >&2
      return 1
    fi
    sleep 0.1
  done
  if wait "${pid}"; then
    status=0
  else
    status=$?
  fi
  if [ "${status}" -ne 0 ]; then
    echo "[build-native] 只读身份查询退出码 ${status}" >&2
    sed -n '1,20p' "${err}" >&2 || true
    return 1
  fi
  if [ ! -s "${out}" ]; then
    echo "[build-native] 只读身份查询没有输出" >&2
    return 1
  fi
  cat "${out}"
}

check_runtime_identity() {
  local app="$1"
  local json="${LOG_DIR}/runtime-identity.json"
  local python_bin

  runtime_identity_json "${app}" >/dev/null || return 1

  python_bin="$(command -v python3 || true)"
  if [ -z "${python_bin}" ]; then
    python_bin="/usr/bin/python3"
  fi
  [ -x "${python_bin}" ] || {
    echo "[build-native] 缺少 python3，无法校验只读身份 JSON" >&2
    return 1
  }

  "${python_bin}" - "${json}" "${BUNDLE_IDENTIFIER}" "${TRIAL_PROFILE_NAME}" "${HOME}" <<'PY'
import json
import os
import sys

path, expected_identifier, expected_profile, home = sys.argv[1:5]
raw = open(path, encoding="utf-8").read().strip()
if not raw:
    print("只读身份输出为空", file=sys.stderr)
    sys.exit(1)
try:
    data = json.loads(raw.splitlines()[-1])
except Exception as exc:  # 明确报告，不吞错
    print(f"只读身份输出不是 JSON：{exc}；原文：{raw[:200]}", file=sys.stderr)
    sys.exit(1)
if not isinstance(data, dict):
    print("只读身份输出不是对象", file=sys.stderr)
    sys.exit(1)

for key in ("bundleIdentifier", "dataDirectory", "trial"):
    if key not in data:
        print(f"只读身份缺少键 {key}", file=sys.stderr)
        sys.exit(1)

if data["trial"] is not True:
    print(f"trial 标志为 {data['trial']!r}，期望 True（必须是编译期 trial 产物）", file=sys.stderr)
    sys.exit(1)

if data["bundleIdentifier"] != expected_identifier:
    print(f"bundleIdentifier 为 {data['bundleIdentifier']!r}，期望 {expected_identifier}", file=sys.stderr)
    sys.exit(1)

directory = data["dataDirectory"]
if not isinstance(directory, str) or not directory:
    print("dataDirectory 不是非空字符串", file=sys.stderr)
    sys.exit(1)
if os.path.basename(directory.rstrip("/")) != expected_profile:
    print(f"默认 profile 目录名不是 {expected_profile}：{directory}", file=sys.stderr)
    sys.exit(1)
expected_directory = os.path.join(home, "Library", "Application Support", expected_profile)
if os.path.normpath(directory) != os.path.normpath(expected_directory):
    print(f"默认 profile 目录不是 {expected_directory}：{directory}", file=sys.stderr)
    sys.exit(1)

print(f"只读身份校验通过：identifier={data['bundleIdentifier']} trial={data['trial']} dataDirectory={directory}")
PY
}

# ---------------------------------------------------------------------------
# 独立校验：结构 + 签名 + 显示名 + 只读运行时身份
# ---------------------------------------------------------------------------
verify_bundle() {
  local app="$1"
  local plist="${app}/Contents/Info.plist"
  local identifier executable

  [ -d "${app}" ] || fail "bundle 目录不存在：${app}"
  [ -f "${plist}" ] || fail "缺少 Info.plist：${plist}"
  plutil -lint "${plist}" >/dev/null || fail "Info.plist 不是合法 plist"

  identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${plist}" 2>/dev/null || true)"
  [ "${identifier}" = "${BUNDLE_IDENTIFIER}" ] || fail "CFBundleIdentifier 为 ${identifier:-<空>}，期望 ${BUNDLE_IDENTIFIER}"

  executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${plist}" 2>/dev/null || true)"
  [ "${executable}" = "${BUNDLE_NAME}" ] || fail "CFBundleExecutable 为 ${executable:-<空>}，期望 ${BUNDLE_NAME}"

  [ -x "${app}/Contents/MacOS/${BUNDLE_NAME}" ] || fail "应用可执行文件缺失或不可执行：Contents/MacOS/${BUNDLE_NAME}"
  [ -x "${app}/Contents/Resources/alger-bridge" ] || fail "包内桥接缺失或不可执行：Contents/Resources/alger-bridge"
  [ -f "${app}/Contents/Resources/icon.icns" ] || fail "缺少图标：Contents/Resources/icon.icns"

  codesign --verify --deep --strict "${app}" || fail "代码签名校验失败"

  swift "${ROOT}/scripts/localize-trial.swift" --verify "${app}" || fail "显示名校验失败"

  check_runtime_identity "${app}" || fail "只读运行时身份校验失败"

  log "校验通过：${app}"
}

# ---------------------------------------------------------------------------
# 校验模式：不构建，只校验既有 bundle
# ---------------------------------------------------------------------------
if [ -n "${VERIFY_TARGET}" ]; then
  log "独立校验：${VERIFY_TARGET}"
  verify_bundle "${VERIFY_TARGET}"
  exit 0
fi

# ---------------------------------------------------------------------------
# 构建模式
# ---------------------------------------------------------------------------
log "配置：${CONFIGURATION}（trial）"
log "输出：${OUTPUT}"

mkdir -p "${BUILD_DIR}"
# 暂存目录：仓库内 mktemp（唯一、随用随删），不预删固定路径。
STAGE="$(mktemp -d "${BUILD_DIR}/alger-native-stage.XXXXXX")"
printf '%s\n' "${ROOT}" > "${STAGE}/.alger-project"
printf '%s\n' "$$" > "${STAGE}/.alger-owner-pid"

PUBLISH_DIR=""
BACKUP_DIR=""
PUBLISH_BACKUP=""

finish() {
  local status=$?
  local restored=1
  trap - EXIT HUP INT TERM
  set +e
  if [ "${status}" -ne 0 ] && [ -n "${PUBLISH_BACKUP}" ] && [ -e "${PUBLISH_BACKUP}" ]; then
    # 发布中途失败：把旧包恢复回输出路径（保留可用产物）。
    if [ -e "${OUTPUT}" ]; then
      rm -rf -- "${OUTPUT}"
    fi
    if mv "${PUBLISH_BACKUP}" "${OUTPUT}" 2>/dev/null; then
      echo "[build-native] 已恢复原有产物：${OUTPUT}" >&2
    else
      # 恢复失败：**必须保留**含旧包的备份目录（它是旧包的唯一副本），
      # 连同目录标记一起保留，并且返回失败。
      echo "[build-native] 恢复失败：旧产物仍保留在 ${PUBLISH_BACKUP}" >&2
      echo "[build-native] 请手动把它放回 ${OUTPUT}" >&2
      restored=0
      status=1
    fi
  fi
  [ -z "${PUBLISH_DIR}" ] || remove_owned_tree "${PUBLISH_DIR}"
  if [ "${restored}" -eq 1 ]; then
    # 只有在旧包已回到输出位置（或根本没有旧包）时才清理备份目录。
    [ -z "${BACKUP_DIR}" ] || remove_owned_tree "${BACKUP_DIR}"
  else
    echo "[build-native] 备份目录已保留（恢复失败，勿删）：${BACKUP_DIR}" >&2
  fi
  remove_owned_tree "${STAGE}"
  exit "${status}"
}
trap finish EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# ---- Rust 桥接 ------------------------------------------------------------
CARGO_PROFILE_FLAG=""
if [ "${CONFIGURATION}" = "release" ]; then
  CARGO_PROFILE_FLAG="--release"
fi

BRIDGE_LOG="${LOG_DIR}/bridge-build.log"
log "构建 Rust 桥接（ALGER_TRIAL=1，日志：${BRIDGE_LOG}）"
if ! CARGO_TARGET_DIR="${CARGO_TARGET_DIR}" cargo build \
    --manifest-path "${ROOT}/crates/alger-bridge/Cargo.toml" \
    ${CARGO_PROFILE_FLAG} > "${BRIDGE_LOG}" 2>&1; then
  echo "[build-native] 桥接构建失败，见 ${BRIDGE_LOG}" >&2
  tail -n 30 "${BRIDGE_LOG}" >&2 || true
  exit 1
fi

if [ "${CONFIGURATION}" = "release" ]; then
  BRIDGE_BIN="${CARGO_TARGET_DIR}/release/alger-bridge"
else
  BRIDGE_BIN="${CARGO_TARGET_DIR}/debug/alger-bridge"
fi
[ -x "${BRIDGE_BIN}" ] || fail "桥接产物缺失或不可执行：${BRIDGE_BIN}"

# ---- Swift 应用 -----------------------------------------------------------
SWIFT_LOG="${LOG_DIR}/swift-build.log"
log "构建 Swift 应用（-DALGER_TRIAL，scratch：${SWIFT_SCRATCH}，日志：${SWIFT_LOG}）"
if ! swift build \
    --package-path "${ROOT}/native/macos" \
    --scratch-path "${SWIFT_SCRATCH}" \
    -c "${CONFIGURATION}" \
    "${SWIFT_TRIAL_FLAGS[@]}" > "${SWIFT_LOG}" 2>&1; then
  echo "[build-native] Swift 构建失败，见 ${SWIFT_LOG}" >&2
  tail -n 30 "${SWIFT_LOG}" >&2 || true
  exit 1
fi

# 直接捕获 swift 的真实输出与真实退出码（不用管道掩盖失败）。
BIN_DIR_RAW=""
if ! BIN_DIR_RAW="$(swift build \
    --package-path "${ROOT}/native/macos" \
    --scratch-path "${SWIFT_SCRATCH}" \
    -c "${CONFIGURATION}" \
    --show-bin-path 2>"${LOG_DIR}/swift-bin-path.log")"; then
  echo "[build-native] 无法解析 Swift 产物目录，见 ${LOG_DIR}/swift-bin-path.log" >&2
  tail -n 10 "${LOG_DIR}/swift-bin-path.log" >&2 || true
  exit 1
fi
BIN_DIR="$(printf '%s\n' "${BIN_DIR_RAW}" | tail -n 1)"
[ -n "${BIN_DIR}" ] || fail "无法解析 Swift 产物目录"
APP_BIN="${BIN_DIR}/AlgerMusic"
[ -x "${APP_BIN}" ] || fail "Swift 产物缺失或不可执行：${APP_BIN}"

# ---- 组装 bundle ----------------------------------------------------------
APP="${STAGE}/${BUNDLE_FILENAME}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

cp "${APP_BIN}" "${APP}/Contents/MacOS/${BUNDLE_NAME}"
chmod 0755 "${APP}/Contents/MacOS/${BUNDLE_NAME}"
cp "${BRIDGE_BIN}" "${APP}/Contents/Resources/alger-bridge"
chmod 0755 "${APP}/Contents/Resources/alger-bridge"

ICON=""
for candidate in \
  "${ROOT}/native/macos/Resources/icon.icns" \
  "${ROOT}/src-tauri/icons/icon.icns" \
  "${ROOT}/dist/${BUNDLE_FILENAME}/Contents/Resources/icon.icns"; do
  if [ -f "${candidate}" ]; then
    ICON="${candidate}"
    break
  fi
done
[ -n "${ICON}" ] || fail "找不到既有 icon.icns（src-tauri/icons/icon.icns）"
cp "${ICON}" "${APP}/Contents/Resources/icon.icns"

cp "${ROOT}/native/macos/Resources/Info.plist" "${APP}/Contents/Info.plist"

VERSION="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${ROOT}/package.json" | head -n 1)"
[ -n "${VERSION}" ] || fail "无法从 package.json 读取版本号"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${APP}/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "${APP}/Contents/Info.plist" >/dev/null

# 显示名：沿用既有本地化脚本（Finder / Dock 显示 Alger Music）
swift "${ROOT}/scripts/localize-trial.swift" "${APP}" || fail "显示名准备失败"

# ---- 签名 -----------------------------------------------------------------
# 先签随包桥接（它是 Mach-O 可执行文件），再签整个 bundle，最后严格校验。
codesign --force --sign - "${APP}/Contents/Resources/alger-bridge" >/dev/null 2>&1 \
  || fail "包内桥接签名失败"
codesign --force --deep --sign - "${APP}" >/dev/null 2>&1 \
  || fail "bundle 签名失败"
codesign --verify --deep --strict "${APP}" || fail "签名校验失败"

# ---- 校验（新包先在暂存目录校验通过，才动输出路径）----------------------
verify_bundle "${APP}"

# ---- 发布（事务性：先复制到输出同父的唯一临时目录，旧包改名保留）--------
OUTPUT_PARENT="$(dirname "${OUTPUT}")"
PUBLISH_DIR="$(mktemp -d "${OUTPUT_PARENT}/.alger-publish.XXXXXX")"
printf '%s\n' "${ROOT}" > "${PUBLISH_DIR}/.alger-project"
PUBLISH_APP="${PUBLISH_DIR}/${BUNDLE_FILENAME}"
ditto "${APP}" "${PUBLISH_APP}"
# 复制之后再校验一次：确认复制没有破坏签名或结构。
verify_bundle "${PUBLISH_APP}"

if [ -e "${OUTPUT}" ]; then
  BACKUP_DIR="$(mktemp -d "${OUTPUT_PARENT}/.alger-backup.XXXXXX")"
  printf '%s\n' "${ROOT}" > "${BACKUP_DIR}/.alger-project"
  PUBLISH_BACKUP="${BACKUP_DIR}/${BUNDLE_FILENAME}"
  # 改名保留旧包（同分区 rename），**不先删除旧包**。
  mv "${OUTPUT}" "${PUBLISH_BACKUP}" || fail "无法保留原有产物"
fi

# 同父 rename 就位；失败时由 finish() 恢复旧包。
mv "${PUBLISH_APP}" "${OUTPUT}" || fail "无法发布新产物到 ${OUTPUT}"

verify_bundle "${OUTPUT}"

# 发布成功：备份可以丢弃。
PUBLISH_BACKUP=""
remove_owned_tree "${BACKUP_DIR}" 2>/dev/null || true
BACKUP_DIR=""

log "完成：${OUTPUT}"
