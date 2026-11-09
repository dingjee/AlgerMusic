#!/usr/bin/env bash
# 构建、校验、隔离试跑并安装原生 macOS trial 应用；失败可回滚，旧应用始终可用。
#
# 用法：
#   sh scripts/install-dist.sh [--repackage]
#
# 流程（顺序不可颠倒）：
#   1. **构建**：默认走原生构建（scripts/build-native.sh，trial + release）；
#      `--repackage` 只重做打包（复用既有可执行文件），不重新编译；
#   2. **独立校验**：`scripts/build-native.sh --verify`（结构 + 签名 + 显示名 +
#      只读运行时身份），**不通过就不碰现有应用**；
#   3. **隔离试跑**：真实启动新包（隔离数据目录、清除 ALGER_BRIDGE_BIN，
#      验证包内桥接、定向退出），**不通过就不碰现有应用**；
#   4. **停旧进程**：只按 **精确可执行文件路径** 停 dist 里的那个进程；
#   5. **替换**：旧应用先改名保留 → 复制新包 → 再次校验；
#   6. **提交**：校验通过才丢弃备份；任何失败都回滚，旧应用保持可用。
#
# 约定：
#   * `dist/AlgerMusicPlayer.app` 是唯一长期入口：**不建 /Applications 快捷方式、
#     不扫描 ~/Library、不重置任何数据**；
#   * 退出时自动清理（成功与失败都执行，且不掩盖失败）。
#
# 夹具模式（仅测试用，强保护）：
#   * `ALGER_DIST_DIR` 必须是仓库 `.artifacts/` 下的绝对路径；
#   * `ALGER_INSTALL_SOURCE_APP` 指定待安装的既有 .app（跳过构建）；
#   * `ALGER_INSTALL_FAULT=<point>` 在指定步骤注入失败（校验事务回滚）；
#   * 以上三个变量**只在夹具模式下生效**，缺一即拒绝执行。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${ROOT}"

DIST_ROOT="${ROOT}/dist"
FIXTURE=0
REPACKAGE=0
SOURCE_APP=""
FAULT=""

INSTALL_ROOT="${ROOT}/.artifacts/native-delivery/install"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

usage() {
  cat <<'EOF'
用法：sh scripts/install-dist.sh [--repackage]

  --repackage   只重做打包（复用既有可执行文件），不重新编译
  --help        显示本帮助

夹具模式环境变量（仅测试）：
  ALGER_DIST_DIR          输出目录，必须位于仓库 .artifacts/ 之下
  ALGER_INSTALL_SOURCE_APP 待安装的既有 .app 绝对路径（跳过构建）
  ALGER_INSTALL_FAULT     注入失败：build|verify|smoke|stop|stage|swap
EOF
}

fail() {
  echo "[install-dist] 失败：$*" >&2
  exit 1
}

log() {
  echo "[install-dist] $*"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repackage)
      REPACKAGE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "参数错误：未知参数 $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# ---------------------------------------------------------------------------
# 夹具模式判定与强保护
# ---------------------------------------------------------------------------
if [ -n "${ALGER_DIST_DIR:-}" ]; then
  DIST_ROOT="${ALGER_DIST_DIR}"
  FIXTURE=1
fi

case "${DIST_ROOT}" in
  /*) ;;
  *) echo "参数错误：输出目录必须是绝对路径：${DIST_ROOT}" >&2; exit 2 ;;
esac

DIST_APP="${DIST_ROOT}/AlgerMusicPlayer.app"
DIST_BIN="${DIST_APP}/Contents/MacOS/AlgerMusicPlayer"

# 拒绝符号链接路径（输出本身或任一父目录）。
assert_no_symlink_chain() {
  local path="$1"
  local current="${path}"
  local next
  while [ "${current}" != "/" ]; do
    if [ -L "${current}" ]; then
      echo "参数错误：拒绝符号链接路径：${current}" >&2
      exit 2
    fi
    [ "${current}" = "${ROOT}" ] && break
    next="$(dirname "${current}")"
    [ "${next}" = "${current}" ] && break
    current="${next}"
  done
}

if [ "${FIXTURE}" -eq 1 ]; then
  # 夹具输出只允许落在仓库 .artifacts/ 之下（绝不允许任意根路径写入）。
  case "${DIST_ROOT}" in
    "${ROOT}/.artifacts/"*) ;;
    *)
      echo "参数错误：夹具输出目录必须位于 ${ROOT}/.artifacts/ 之下：${DIST_ROOT}" >&2
      exit 2
      ;;
  esac
  # 拒绝 . / .. 组件与软链父链，避免前缀绕过。
  case "${DIST_ROOT}" in
    */../*|*/..|../*|..|*/./*|*/.|./*|.)
      echo "参数错误：输出目录不能包含 . 或 .. 组件：${DIST_ROOT}" >&2
      exit 2
      ;;
  esac
  assert_no_symlink_chain "${DIST_ROOT}"
  assert_no_symlink_chain "${DIST_APP}"
else
  # 正常模式同样拒绝软链：dist/ 与应用目录本身都不能是符号链接。
  [ ! -L "${DIST_ROOT}" ] || { echo "拒绝符号链接的输出目录：${DIST_ROOT}" >&2; exit 1; }
  [ ! -L "${DIST_APP}" ] || { echo "拒绝符号链接的应用目录：${DIST_APP}" >&2; exit 1; }
  assert_no_symlink_chain "${DIST_ROOT}"
  assert_no_symlink_chain "${DIST_APP}"
fi

if [ -n "${ALGER_INSTALL_SOURCE_APP:-}" ]; then
  SOURCE_APP="${ALGER_INSTALL_SOURCE_APP}"
  case "${SOURCE_APP}" in
    /*) ;;
    *) echo "参数错误：ALGER_INSTALL_SOURCE_APP 必须是绝对路径：${SOURCE_APP}" >&2; exit 2 ;;
  esac
  [ -d "${SOURCE_APP}" ] || { echo "参数错误：源 bundle 不存在：${SOURCE_APP}" >&2; exit 2; }
  [ "${FIXTURE}" -eq 1 ] || { echo "参数错误：ALGER_INSTALL_SOURCE_APP 只在夹具模式下生效" >&2; exit 2; }
fi

if [ -n "${ALGER_INSTALL_FAULT:-}" ]; then
  FAULT="${ALGER_INSTALL_FAULT}"
  [ "${FIXTURE}" -eq 1 ] || { echo "参数错误：ALGER_INSTALL_FAULT 只在夹具模式下生效" >&2; exit 2; }
  case "${FAULT}" in
    build|verify|smoke|stop|stage|copy|swap) ;;
    *) echo "参数错误：未知的注入失败点：${FAULT}" >&2; exit 2 ;;
  esac
fi

# ---------------------------------------------------------------------------
# 工具链：完整 Xcode（只在命令级生效，不改系统 xcode-select）
# ---------------------------------------------------------------------------
if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi
if [ -x "${ROOT}/.tools/cargo/bin/cargo" ] && [ -d "${ROOT}/.tools/rustup" ]; then
  export RUSTUP_HOME="${ROOT}/.tools/rustup"
  export CARGO_HOME="${ROOT}/.tools/cargo"
  export PATH="${ROOT}/.tools/cargo/bin:${PATH}"
fi

DIST_APP="${DIST_ROOT}/AlgerMusicPlayer.app"
DIST_BIN="${DIST_APP}/Contents/MacOS/AlgerMusicPlayer"
STAGE=""
BACKUP=""
SWAPPED=0
COMMITTED=0
WAS_RUNNING=0

exact_pids() {
  ps -ww -axo pid=,comm= | awk -v bin="${DIST_BIN}" '
    { pid=$1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, ""); if ($0 == bin) print pid }
  '
}

inject_fault() {
  [ "${FAULT}" = "$1" ] || return 0
  log "注入失败点：$1"
  exit 1
}

# 删除一棵**自己创建的**目录树。
#
# 为什么需要专门处理不可变标志：`ditto` 会把源文件的 `UF_IMMUTABLE`
# （uchg）标志一起复制过去，于是 `rm -rf` 会在该文件上直接失败，
# 目录残留下来 —— 残留还会让 `rm -rf .artifacts`（scripts/clean.sh）失败。
#
# 这里只清**不可变标志**，不动内容、不动权限、不动其它标志位；
# 作用范围严格限定在传进来的那棵树（installer 自己建的暂存目录）。
#
# 归属标记（`.alger-project` / `.alger-owner-pid`）**先保留、最后才删**：
# 只有目录真的删掉了，标记才跟着消失。这样万一清理失败，残留目录仍然
# 带得上归属标记，外层（夹具 / 清理脚本）能凭它确认「这是本仓库自己建的」，
# 而不会把别的会话刚生成的目录误当成自己的。
remove_owned_tree() {
  local target="$1"
  [ -e "${target}" ] || return 0
  if [ -d "${target}" ]; then
    # 先清目录树里的 uchg，再删（清两遍：第一遍清掉文件上的，
    # 目录自身的 uchg 会挡住第二遍的遍历）。
    find "${target}" -flags +uchg -exec chflags -h nouchg '{}' \; 2>/dev/null || true
    find "${target}" -flags +uchg -exec chflags -h nouchg '{}' \; 2>/dev/null || true
  fi
  rm -rf -- "${target}"
}

# 删除 installer 自己的暂存目录：**标记最后才删**。
#
# 顺序很重要：先把标记挪出目录（挪到同级临时名），再删目录内容，
# 最后删标记。这样清理失败时，残留目录仍带得上归属标记。
remove_install_stage() {
  local stage="$1"
  local marker_hold=""
  [ -e "${stage}" ] || return 0
  if [ -f "${stage}/.alger-project" ]; then
    marker_hold="${stage}.alger-marker-hold.$$"
    mv "${stage}/.alger-project" "${marker_hold}" 2>/dev/null || marker_hold=""
  fi
  if ! remove_owned_tree "${stage}"; then
    # 删不掉：把标记放回去，残留目录仍能证明归属。
    if [ -n "${marker_hold}" ] && [ -f "${marker_hold}" ]; then
      mv "${marker_hold}" "${stage}/.alger-project" 2>/dev/null || true
    fi
    return 1
  fi
  [ -z "${marker_hold}" ] || rm -f -- "${marker_hold}"
  return 0
}

verify_bundle_structure() {
  local app="$1"
  local identifier
  [ -d "${app}" ] || fail "bundle 目录不存在：${app}"
  [ -f "${app}/Contents/Info.plist" ] || fail "缺少 Info.plist：${app}/Contents/Info.plist"
  plutil -lint "${app}/Contents/Info.plist" >/dev/null || fail "Info.plist 不是合法 plist"
  identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${app}/Contents/Info.plist" 2>/dev/null || true)"
  [ "${identifier}" = "com.alger.music.trial" ] || fail "CFBundleIdentifier 为 ${identifier:-<空>}，期望 com.alger.music.trial"
  [ -x "${app}/Contents/MacOS/AlgerMusicPlayer" ] || fail "缺少可执行文件：${app}/Contents/MacOS/AlgerMusicPlayer"
}

verify_bundle() {
  local app="$1"
  if [ "${FIXTURE}" -eq 1 ]; then
    verify_bundle_structure "${app}"
  else
    # 独立校验：结构 + 签名 + 显示名 + 只读运行时身份
    bash "${ROOT}/scripts/build-native.sh" --verify "${app}" || fail "新 bundle 校验未通过"
  fi
}

run_smoke() {
  local app="$1"
  if [ "${FIXTURE}" -eq 1 ]; then
    log "夹具模式：跳过隔离试跑（夹具不是真实 GUI 应用）"
    return 0
  fi
  # 隔离试跑：隔离数据目录 + 清除 ALGER_BRIDGE_BIN + 验证包内桥接 + 定向退出
  bash "${ROOT}/scripts/run-native-app.sh" --app "${app}" --seconds 8 \
    || fail "隔离试跑未通过（新 bundle 未替换现有应用）"
}

mkdir -p "${INSTALL_ROOT}"
STAGE="$(mktemp -d "${INSTALL_ROOT}/alger-install-stage.XXXXXX")"
printf '%s\n' "${ROOT}" > "${STAGE}/.alger-project"
printf '%s\n' "$$" > "${STAGE}/.alger-owner-pid"

finish() {
  local status=$?
  local restored=1
  trap - EXIT HUP INT TERM
  set +e
  if [ "${COMMITTED}" -eq 0 ]; then
    if [ "${SWAPPED}" -eq 1 ]; then
      # 只有替换后的进程停下之后才回滚。
      for pid in $(exact_pids); do kill "${pid}" 2>/dev/null || true; done
      count=0
      while [ -n "$(exact_pids)" ] && [ "${count}" -lt 20 ]; do
        sleep 0.5
        count=$((count + 1))
      done
      if [ -n "$(exact_pids)" ]; then
        echo "[install-dist] 替换后的应用仍在运行；旧应用保留在 ${BACKUP}" >&2
        status=1
      elif rm -rf -- "${DIST_APP}"; then
        if [ -n "${BACKUP}" ] && [ -d "${BACKUP}" ]; then
          if mv "${BACKUP}" "${DIST_APP}"; then
            echo "[install-dist] 已回滚到旧应用：${DIST_APP}" >&2
          else
            # 回滚失败：**旧应用必须保留**在备份里，不能被清掉。
            echo "[install-dist] 回滚失败：旧应用仍保留在 ${BACKUP}（请手动放回 ${DIST_APP}）" >&2
            restored=0
            status=1
          fi
        fi
      else
        echo "[install-dist] 无法移除替换产物；旧应用保留在 ${BACKUP}" >&2
        status=1
      fi
    elif [ -n "${BACKUP}" ] && [ -d "${BACKUP}" ] && [ ! -e "${DIST_APP}" ]; then
      if mv "${BACKUP}" "${DIST_APP}"; then
        echo "[install-dist] 已回滚到旧应用：${DIST_APP}" >&2
      else
        echo "[install-dist] 回滚失败：旧应用仍保留在 ${BACKUP}" >&2
        restored=0
        status=1
      fi
    fi
    if [ "${WAS_RUNNING}" -eq 1 ] && [ -d "${DIST_APP}" ] && [ -z "$(exact_pids)" ]; then
      open -g "${DIST_APP}" || true
    fi
  fi
  if [ "${restored}" -eq 0 ]; then
    echo "[install-dist] 备份目录已保留（回滚失败，勿删）：${BACKUP}" >&2
  fi
  # 暂存目录是 installer **自己**建的：删之前先清掉复制过来的不可变标志，
  # 否则 `ditto` 复制来的 uchg 文件会让 `rm -rf` 失败并留下残留
  # （残留还会卡住 scripts/clean.sh 的 `rm -rf .artifacts`）。
  # 归属标记最后才删：清理失败时残留目录仍带得上标记，外层能据此认领。
  [ -z "${STAGE}" ] || remove_install_stage "${STAGE}" || status=1
  # 退出时自动清理：成功与失败都执行，且不掩盖失败。
  if [ "${FIXTURE}" -eq 1 ]; then
    # 夹具模式只做演练，绝不真的删除 .artifacts（夹具树就在里面）。
    sh "${ROOT}/scripts/clean.sh" --dry-run >/dev/null 2>&1 || status=1
  else
    sh "${ROOT}/scripts/clean.sh" || status=1
  fi
  exit "${status}"
}
trap finish EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# ---------------------------------------------------------------------------
# 1. 构建 / 复用
# ---------------------------------------------------------------------------
APP="${STAGE}/AlgerMusicPlayer.app"
inject_fault build

if [ "${REPACKAGE}" -eq 1 ]; then
  [ -d "${DIST_APP}" ] || fail "没有可复用的现有应用：${DIST_APP}"
  log "复用现有可执行文件，只重做打包"
  ditto "${DIST_APP}" "${APP}"
  swift "${ROOT}/scripts/localize-trial.swift" "${APP}" || fail "显示名准备失败"
  codesign --force --deep --sign - "${APP}" || fail "重新签名失败"
elif [ -n "${SOURCE_APP}" ]; then
  log "使用既有源 bundle：${SOURCE_APP}"
  ditto "${SOURCE_APP}" "${APP}"
else
  log "原生构建（trial + release）"
  bash "${ROOT}/scripts/build-native.sh" --output "${APP}" || fail "原生构建失败"
fi

# ---------------------------------------------------------------------------
# 2. 独立校验（不通过就不碰现有应用）
# ---------------------------------------------------------------------------
inject_fault verify
verify_bundle "${APP}"

# ---------------------------------------------------------------------------
# 3. 隔离试跑（不通过就不碰现有应用）
# ---------------------------------------------------------------------------
inject_fault smoke
run_smoke "${APP}"

# ---------------------------------------------------------------------------
# 4. 停掉旧进程（只按精确可执行文件路径）
# ---------------------------------------------------------------------------
inject_fault stop
pids="$(exact_pids)"
if [ -n "${pids}" ]; then
  WAS_RUNNING=1
  for pid in ${pids}; do kill "${pid}"; done
  count=0
  while [ -n "$(exact_pids)" ] && [ "${count}" -lt 20 ]; do
    sleep 0.5
    count=$((count + 1))
  done
  [ -z "$(exact_pids)" ] || fail "旧应用未能停止；现有应用保持不变"
fi

# ---------------------------------------------------------------------------
# 5. 替换（旧应用先改名保留）
# ---------------------------------------------------------------------------
inject_fault stage
mkdir -p "${DIST_ROOT}"
if [ -e "${DIST_APP}" ]; then
  BACKUP="${DIST_ROOT}/AlgerMusicPlayer.app.previous-$$"
  [ ! -e "${BACKUP}" ] || fail "备份已存在：${BACKUP}"
  if [ "${FIXTURE}" -eq 0 ] && [ -x "${LSREGISTER}" ]; then
    "${LSREGISTER}" -u "${DIST_APP}" >/dev/null 2>&1 || true
  fi
  mv "${DIST_APP}" "${BACKUP}" || fail "无法保留现有应用"
fi

# 从这里开始任何失败都必须走回滚：SWAPPED 必须在复制**之前**置位。
# 否则“复制中途失败”会留下半成品目录，而 trap 因为 SWAPPED=0 不还原备份，
# 旧应用就滞留在备份里 —— 入口丢失。
SWAPPED=1
ditto "${APP}" "${DIST_APP}" || fail "无法复制新应用到 ${DIST_APP}"

if [ "${FAULT}" = "copy" ]; then
  # 注入“复制到一半失败”：目录已存在但内容不完整。
  log "注入失败点：copy（模拟复制中途失败）"
  rm -rf -- "${DIST_APP}/Contents/MacOS" 2>/dev/null || true
  exit 1
fi

inject_fault swap
verify_bundle "${DIST_APP}"

# ---------------------------------------------------------------------------
# 6. 重启（原本在跑才重启）+ 提交
# ---------------------------------------------------------------------------
if [ "${WAS_RUNNING}" -eq 1 ]; then
  open -g "${DIST_APP}"
  count=0
  while [ -z "$(exact_pids)" ] && [ "${count}" -lt 30 ]; do
    sleep 0.5
    count=$((count + 1))
  done
  sleep 2
  [ "$(exact_pids | awk 'NF {n++} END {print n+0}')" -eq 1 ] || fail "替换后的应用没有保持单实例运行"
fi

COMMITTED=1
[ -z "${BACKUP}" ] || rm -rf -- "${BACKUP}"
log "已安装：${DIST_APP}"
