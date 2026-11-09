#!/usr/bin/env bash
# 原生 macOS 应用 **隔离试跑** 脚本（真实启动，隔离数据目录）。
#
# 用法：
#   sh scripts/run-native-app.sh [--app /绝对路径/AlgerMusicPlayer.app] \
#                                [--seconds 12] [--screenshot]
#
# 两种模式：
#   * **不带 --app**：从 SwiftPM 源码构建（开发用），桥接通过 ALGER_BRIDGE_BIN 注入；
#   * **带 --app**：直接运行既有 bundle（交付用），**不构建、不注入**桥接，
#     应用必须自己找到 `Contents/Resources/alger-bridge`。
#
# 设计要点：
#  1. **数据显式隔离**：ALGER_APP_DATA_DIR 指向仓库内 .artifacts 下的 **唯一**
#     临时目录（mktemp），不同次启动互不共享旧 profile、并发互不踩踏；
#     **绝不写用户真实资料库**，也 **不改 HOME 等系统变量**；
#  2. **--app 模式清除 ALGER_BRIDGE_BIN**：验证的正是“包内桥接”这条路径，
#     而不是开发时的环境变量注入；
#  3. **退出必须定向到本次启动的那个 PID**：用 scripts/quit-native.swift
#     （NSAppleEventDescriptor(processIdentifier:) + kAEQuitApplication），
#     **绝不**用 `tell application id ... to quit` —— 那会按 bundle 标识匹配，
#     可能误关用户正在运行的同标识旧版本；
#  4. **正常退出需要三重证据**：退出事件发送成功 **且** 应用自身退出码为 0
#     **且** 桥接子进程也已退出；缺一不可（只看到进程消失不算正常退出）；
#  5. **SIGTERM 只是清理兜底**：它**不构成**正常退出的证据，脚本会如实标注；
#  6. **真实 profile 比对放在正常退出之后**：退出过程本身也会落盘，
#     必须在退出完成后再比对，否则会漏检退出时写入的数据；
#  7. **产物只进 .artifacts/**：SwiftPM scratch path、日志都在 .artifacts 下，
#     且使用**独立** scratch（不占用 `swift test` 的 scratch）；
#  8. **退出码取自真实命令**：不用未启用 pipefail 的取尾管道伪装成功。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${ROOT}"

SECONDS_TO_RUN=12
TAKE_SCREENSHOT=0
APP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --seconds)
      [ $# -ge 2 ] || { echo "--seconds 缺少取值" >&2; exit 2; }
      SECONDS_TO_RUN="$2"
      shift 2
      ;;
    --screenshot)
      TAKE_SCREENSHOT=1
      shift
      ;;
    --app)
      [ $# -ge 2 ] || { echo "--app 缺少取值" >&2; exit 2; }
      APP="$2"
      shift 2
      ;;
    -h|--help)
      echo "用法：sh scripts/run-native-app.sh [--app /绝对路径/AlgerMusicPlayer.app] [--seconds 12] [--screenshot]"
      exit 0
      ;;
    *)
      echo "未知参数：$1" >&2
      exit 2
      ;;
  esac
done

RUN_ROOT="${ROOT}/.artifacts/native-delivery/run"
LOG_DIR="${RUN_ROOT}/logs"
SCRATCH="${ROOT}/.artifacts/native-delivery/run/swift-scratch"
mkdir -p "${LOG_DIR}"

# 数据目录：**唯一**临时目录（mktemp），不同次启动互不共享。
RUN_DIR="$(mktemp -d "${RUN_ROOT}/alger-run.XXXXXX")"
DATA_DIR="${RUN_DIR}/data"
mkdir -p "${DATA_DIR}"

# ---------------------------------------------------------------------------
# 工具链：完整 Xcode（只在命令级生效，不改系统 xcode-select）
# ---------------------------------------------------------------------------
if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

# Rust 工具链：仓库内优先
if [ -x "${ROOT}/.tools/cargo/bin/cargo" ] && [ -d "${ROOT}/.tools/rustup" ]; then
  export CARGO_HOME="${ROOT}/.tools/cargo"
  export RUSTUP_HOME="${ROOT}/.tools/rustup"
  export PATH="${ROOT}/.tools/cargo/bin:${PATH}"
fi

# ---------------------------------------------------------------------------
# 数据目录：**绝对路径**，显式隔离
# ---------------------------------------------------------------------------
export ALGER_APP_DATA_DIR="${DATA_DIR}"
REAL_PROFILES=(
  "${HOME}/Library/Application Support/AlgerMusicPlayer"
  "${HOME}/Library/Application Support/AlgerMusicPlayer.trial"
)

snapshot_profiles() {
  local profile
  for profile in "${REAL_PROFILES[@]}"; do
    if [ -d "${profile}" ]; then
      find "${profile}" -type f -exec stat -f '%N %z %m' {} \; 2>/dev/null | sort
    else
      echo "(不存在) ${profile}"
    fi
  done
}

# 进程可执行文件的完整路径（路径可能含空格，**不能**用 awk $NF 截断）。
process_executable() {
  local pid="$1" path=""
  path="$(ps -ww -o comm= -p "${pid}" 2>/dev/null | head -1)"
  if [ -z "${path}" ] || [ "${path}" = "${pid}" ]; then
    # 退回 lsof 的机器可读字段输出（n = 名称，t = 类型）。
    path="$(lsof -F nt -p "${pid}" 2>/dev/null \
      | awk '/^t/ { type=$0; getline name; if (type ~ /txt/ && name ~ /^n/) { sub(/^n/, "", name); print name; exit } }')"
  fi
  printf '%s\n' "${path}"
}

# ---------------------------------------------------------------------------
# 解析要运行的 bundle
# ---------------------------------------------------------------------------
if [ -n "${APP}" ]; then
  case "${APP}" in
    /*) ;;
    *) echo "--app 需要绝对路径：${APP}" >&2; exit 2 ;;
  esac
  [ -d "${APP}" ] || { echo "--app 目标不存在：${APP}" >&2; exit 2; }
  # 规范化一次即可（不要再拼 basename，否则会重复出 ".../App.app/App.app"）。
  APP="$(cd "${APP}" && pwd -P)"
  APP_BIN="${APP}/Contents/MacOS/AlgerMusicPlayer"
  [ -x "${APP_BIN}" ] || { echo "bundle 内没有可执行文件：${APP_BIN}" >&2; exit 1; }
  BUNDLED_BRIDGE="${APP}/Contents/Resources/alger-bridge"
  [ -x "${BUNDLED_BRIDGE}" ] || { echo "bundle 内没有随包桥接：${BUNDLED_BRIDGE}" >&2; exit 1; }
  # 交付模式：**不注入**桥接路径，验证包内桥接这条唯一路径。
  unset ALGER_BRIDGE_BIN
  echo "运行既有 bundle：${APP}"
else
  BRIDGE="${ROOT}/crates/alger-bridge/target/debug/alger-bridge"
  echo "构建桥接二进制（增量）：${BRIDGE}"
  cargo build --manifest-path "${ROOT}/crates/alger-bridge/Cargo.toml" \
    > "${LOG_DIR}/gui-bridge-build.log" 2>&1 || {
    echo "桥接构建失败，见 ${LOG_DIR}/gui-bridge-build.log" >&2
    tail -20 "${LOG_DIR}/gui-bridge-build.log" >&2
    exit 1
  }
  [ -x "${BRIDGE}" ] || { echo "桥接二进制缺失：${BRIDGE}" >&2; exit 1; }
  export ALGER_BRIDGE_BIN="${BRIDGE}"

  echo "构建原生应用"
  if ! swift build --package-path "${ROOT}/native/macos" --scratch-path "${SCRATCH}" \
      > "${LOG_DIR}/gui-app-build.log" 2>&1; then
    echo "应用构建失败，见 ${LOG_DIR}/gui-app-build.log" >&2
    tail -20 "${LOG_DIR}/gui-app-build.log" >&2
    exit 1
  fi
  BIN_DIR="$(swift build --package-path "${ROOT}/native/macos" --scratch-path "${SCRATCH}" \
    --show-bin-path 2>/dev/null | tail -1)"
  APP_BIN="${BIN_DIR}/AlgerMusic"
  if [ ! -x "${APP_BIN}" ]; then
    echo "找不到应用可执行文件：${APP_BIN}" >&2
    exit 1
  fi
  BUNDLED_BRIDGE=""
fi

# ---------------------------------------------------------------------------
# 启动
# ---------------------------------------------------------------------------
PROFILE_BEFORE="$(snapshot_profiles)"
"${APP_BIN}" > "${LOG_DIR}/gui-app-stdout.log" 2> "${LOG_DIR}/gui-app-stderr.log" &
APP_PID=$!

cleanup() {
  local status=$?
  set +e
  # SIGTERM 只是清理兜底：**不构成**正常退出的证据。
  if kill -0 "${APP_PID}" 2>/dev/null; then
    kill -TERM "${APP_PID}" 2>/dev/null || true
    for _ in $(seq 1 20); do
      kill -0 "${APP_PID}" 2>/dev/null || break
      sleep 0.25
    done
    if kill -0 "${APP_PID}" 2>/dev/null; then
      kill -KILL "${APP_PID}" 2>/dev/null || true
    fi
  fi
  exit "${status}"
}
trap cleanup EXIT

sleep "${SECONDS_TO_RUN}"

echo "--- 试跑检查 ---"
ALIVE=0
if kill -0 "${APP_PID}" 2>/dev/null; then
  ALIVE=1
  echo "应用进程：运行中（pid ${APP_PID}）"
else
  echo "应用进程：已退出（可能是崩溃，见 ${LOG_DIR}/gui-app-stderr.log）"
fi

# ---------------------------------------------------------------------------
# 桥接来源核验：子进程的可执行文件必须就是包内随包桥接
# ---------------------------------------------------------------------------
BRIDGE_PID=""
BRIDGE_SOURCE=""
for child in $(pgrep -P "${APP_PID}" 2>/dev/null || true); do
  exe="$(process_executable "${child}")"
  [ -n "${exe}" ] || continue
  BRIDGE_SOURCE="${exe}"
  BRIDGE_PID="${child}"
  break
done

BRIDGE_OK=1
if [ -n "${BUNDLED_BRIDGE}" ]; then
  if [ "${BRIDGE_SOURCE}" = "${BUNDLED_BRIDGE}" ]; then
    echo "包内桥接已启动：${BRIDGE_SOURCE}（pid ${BRIDGE_PID}）"
  else
    BRIDGE_OK=0
    echo "包内桥接未启动：期望 ${BUNDLED_BRIDGE}，实际 ${BRIDGE_SOURCE:-<无子进程>}" >&2
  fi
else
  echo "桥接来源：${BRIDGE_SOURCE:-<无子进程>}"
fi

if [ -f "${ALGER_APP_DATA_DIR}/session.json" ]; then
  echo "会话文件：${ALGER_APP_DATA_DIR}/session.json（隔离目录内）"
else
  echo "会话文件：缺失（${ALGER_APP_DATA_DIR}/session.json）"
fi
if [ -f "${ALGER_APP_DATA_DIR}/native.json" ]; then
  echo "应用状态：${ALGER_APP_DATA_DIR}/native.json"
else
  echo "应用状态：缺失"
fi

if [ "${TAKE_SCREENSHOT}" = "1" ]; then
  SHOT="${RUN_DIR}/screenshot.png"
  screencapture -x "${SHOT}" 2>/dev/null && echo "截图：${SHOT}" || echo "截图失败（忽略）"
fi

# ---------------------------------------------------------------------------
# 定向退出：只针对本次启动的 PID
# ---------------------------------------------------------------------------
echo "--- 定向退出（kAEQuitApplication → pid ${APP_PID}）---"
QUIT_SENT=0
if swift "${ROOT}/scripts/quit-native.swift" "${APP_PID}" > "${LOG_DIR}/quit.log" 2>&1; then
  QUIT_SENT=1
  echo "已发送 kAEQuitApplication"
else
  echo "发送 kAEQuitApplication 失败，见 ${LOG_DIR}/quit.log" >&2
  tail -5 "${LOG_DIR}/quit.log" >&2 || true
fi

waited=0
while kill -0 "${APP_PID}" 2>/dev/null && [ "${waited}" -lt 150 ]; do
  sleep 0.1
  waited=$((waited + 1))
done

APP_EXIT=""
if kill -0 "${APP_PID}" 2>/dev/null; then
  echo "应用未响应定向退出事件；SIGTERM 仅用于清理，不构成正常退出证据" >&2
  APP_EXIT="仍在运行"
else
  # 进程已退出：取它**真实**的退出码（不能只看“进程没了”）。
  if wait "${APP_PID}"; then
    APP_EXIT=0
  else
    APP_EXIT=$?
  fi
  echo "应用退出码：${APP_EXIT}"
fi

# 桥接子进程也必须已经退出。
BRIDGE_STOPPED=1
if [ -n "${BRIDGE_PID}" ]; then
  bridge_waited=0
  while kill -0 "${BRIDGE_PID}" 2>/dev/null && [ "${bridge_waited}" -lt 50 ]; do
    sleep 0.1
    bridge_waited=$((bridge_waited + 1))
  done
  if kill -0 "${BRIDGE_PID}" 2>/dev/null; then
    BRIDGE_STOPPED=0
    echo "桥接子进程仍在运行（pid ${BRIDGE_PID}）" >&2
  else
    echo "桥接子进程已退出（pid ${BRIDGE_PID}）"
  fi
fi

GRACEFUL_QUIT=0
if [ "${QUIT_SENT}" -eq 1 ] && [ "${APP_EXIT}" = "0" ] && [ "${BRIDGE_STOPPED}" -eq 1 ]; then
  GRACEFUL_QUIT=1
  echo "正常退出证据齐备：事件已发送 + 应用退出码 0 + 桥接子进程已退出"
else
  echo "正常退出证据不足（事件发送=${QUIT_SENT}，应用退出码=${APP_EXIT}，桥接已退出=${BRIDGE_STOPPED}）" >&2
fi

# ---------------------------------------------------------------------------
# 真实 profile 不该被本次试跑改动（**在退出之后**比对：退出时也会落盘）
# ---------------------------------------------------------------------------
PROFILE_AFTER="$(snapshot_profiles)"
PROFILE_CHANGED=0
if [ "${PROFILE_BEFORE}" = "${PROFILE_AFTER}" ]; then
  echo "真实 profile 未被改动"
else
  PROFILE_CHANGED=1
  echo "真实 profile 发生变化（不应发生）" >&2
  printf '%s\n' "${PROFILE_BEFORE}" > "${RUN_DIR}/profile-before.txt"
  printf '%s\n' "${PROFILE_AFTER}" > "${RUN_DIR}/profile-after.txt"
  diff "${RUN_DIR}/profile-before.txt" "${RUN_DIR}/profile-after.txt" >&2 || true
fi

if [ -f "${ALGER_APP_DATA_DIR}/session.json" ]; then
  DOWNLOAD_DIR="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8")).get("download_dir",""))' "${ALGER_APP_DATA_DIR}/session.json" 2>/dev/null || echo "读取失败")"
  echo "隔离会话 downloadDir：${DOWNLOAD_DIR}"
  case "${DOWNLOAD_DIR}" in
    "${ALGER_APP_DATA_DIR}"*) echo "下载目录在隔离目录内：OK" ;;
    *) echo "下载目录不在隔离目录内：${DOWNLOAD_DIR}" >&2; PROFILE_CHANGED=1 ;;
  esac
fi

echo "--- stderr ---"
tail -20 "${LOG_DIR}/gui-app-stderr.log" || true

echo "试跑目录：${RUN_DIR}"
if [ "${ALIVE}" -eq 1 ] && [ "${PROFILE_CHANGED}" -eq 0 ] && [ "${BRIDGE_OK}" -eq 1 ] && [ "${GRACEFUL_QUIT}" -eq 1 ]; then
  echo "试跑完成：应用正常运行，包内桥接可用，真实 profile 未被改动，正常退出"
  exit 0
fi
echo "试跑失败：应用提前退出 / 桥接来源不符 / 真实 profile 被改动 / 未正常退出" >&2
exit 1
