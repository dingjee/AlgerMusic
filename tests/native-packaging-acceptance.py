#!/usr/bin/env python3
"""原生打包 / 安装事务验收。

**夹具隔离**：所有安装都在仓库 `.artifacts/` 下的隔离目录里进行，
真实 `dist/AlgerMusicPlayer.app` 与用户资料库只被**读取**（指纹比对），
绝不被写入、替换或删除。

覆盖：
  * 安装事务：成功替换、旧包保留与回滚；
  * **复制中途失败**的回归（旧应用必须回到原位，入口不丢）；
  * 失败保留：校验失败 / 替换失败时旧应用原封不动；
  * 无法回滚时**旧包不得被删除**（必须留在备份里）；
  * 参数与路径保护（夹具外写入、故障注入开关、路径穿越）；
  * 脚本静态约定（trial 标志一致、原生构建、无 tauri、按 PID 定向退出）；
  * **副本清理 RAII**：installer 把带不可变标志的源包复制到 install stage 后，
    夹具结束时必须把**这些副本**一起清掉 —— 只清原夹具会让
    `.artifacts/native-delivery/install/alger-install-stage.*` 残留，
    残留带 `UF_IMMUTABLE` 会让 `rm -rf .artifacts` 失败（清理被卡住），
    而“夹具全绿”并不代表残留已清完。

用法：
    python3 tests/native-packaging-acceptance.py
"""

from __future__ import annotations

import hashlib
import os
import shutil
import stat
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
ARTIFACTS = ROOT / ".artifacts"
FIXTURE_ROOT = ARTIFACTS / "native-acceptance"

PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>CFBundleExecutable</key>
\t<string>AlgerMusicPlayer</string>
\t<key>CFBundleIdentifier</key>
\t<string>com.alger.music.trial</string>
\t<key>CFBundleName</key>
\t<string>AlgerMusicPlayer</string>
\t<key>CFBundlePackageType</key>
\t<string>APPL</string>
</dict>
</plist>
"""

RESULTS: list[tuple[str, bool, str]] = []


def check(name: str, ok: bool, detail: str = "") -> bool:
    RESULTS.append((name, bool(ok), detail))
    print(("PASS  " if ok else "FAIL  ") + name + (f"   [{detail}]" if detail else ""))
    return bool(ok)


def fingerprint(path: Path) -> str:
    """目录内容指纹（相对路径 + 文件内容），用于“是否被改动”的判定。"""
    digest = hashlib.sha256()
    if not path.exists():
        return "missing"
    for item in sorted(path.rglob("*")):
        digest.update(str(item.relative_to(path)).encode("utf-8"))
        if item.is_file() and not item.is_symlink():
            digest.update(item.read_bytes())
    return digest.hexdigest()


def profile_fingerprint() -> str:
    """真实用户资料库指纹（普通版 + trial），只读比对。"""
    digest = hashlib.sha256()
    base = Path.home() / "Library" / "Application Support"
    for name in ("AlgerMusicPlayer", "AlgerMusicPlayer.trial"):
        digest.update(name.encode("utf-8"))
        target = base / name
        if target.exists():
            for item in sorted(target.rglob("*")):
                if item.is_file():
                    digest.update(str(item).encode("utf-8"))
                    digest.update(item.read_bytes())
        else:
            digest.update(b"missing")
    return digest.hexdigest()


def force_remove(path: Path) -> None:
    """删除目录树（先清掉不可变标志，否则删不掉）。"""
    if not path.exists():
        return
    for item in path.rglob("*"):
        try:
            os.chflags(item, os.stat(item).st_flags & ~stat.UF_IMMUTABLE)
        except OSError:
            pass
    shutil.rmtree(path, ignore_errors=True)


def clear_immutable(path: Path) -> None:
    """清掉一棵树上所有 `UF_IMMUTABLE` 标志（只改标志，不改内容/权限）。

    **绝不跟随符号链接**：只用 `lstat` 看标志，遇到软链就跳过 ——
    否则会改到软链**指向的真实文件**上（可能根本不属于本夹具）。
    `os.lstat` 不跟随软链，但 `Path.rglob("*")` 会**列出**软链；
    这里逐个用 `lstat` 判断，遇到软链直接跳过。
    """
    if not path.exists() and not path.is_symlink():
        return
    candidates = [path, *path.rglob("*")]
    for item in candidates:
        try:
            info = os.lstat(item)
        except OSError:
            continue
        # 软链：不碰（lstat 拿到的是链接自身的标志，不是目标的）。
        if stat.S_ISLNK(info.st_mode):
            continue
        if info.st_flags & stat.UF_IMMUTABLE:
            try:
                os.chflags(item, info.st_flags & ~stat.UF_IMMUTABLE, follow_symlinks=False)
            except OSError:
                pass


def remove_owned_tree(path: Path) -> bool:
    """删除一棵**归属本夹具**的目录树。

    不可变文件（`UF_IMMUTABLE`）会让 `rm -rf` / `shutil.rmtree` 直接失败，
    因此先清标志再删。返回是否真的删干净了。

    软链本身会被删掉，但**不会**顺着软链删到别处去
    （`shutil.rmtree` 对目录软链不会下钻；`clear_immutable` 也不跟随软链）。
    """
    if not path.exists() and not path.is_symlink():
        return True
    clear_immutable(path)
    # rmtree 遇到目录里的软链不会下钻；顶层若是软链则只删链接本身。
    if path.is_symlink() and not path.is_dir():
        try:
            path.unlink()
        except OSError:
            pass
    else:
        shutil.rmtree(path, ignore_errors=True)
    if path.exists() or path.is_symlink():
        # 再试一次：清标志后重试能删掉第一遍因标志残留失败的条目。
        clear_immutable(path)
        shutil.rmtree(path, ignore_errors=True)
    return not path.exists() and not path.is_symlink()


def install_stage_root() -> Path:
    """installer 的暂存根目录（`scripts/install-dist.sh` 里的 INSTALL_ROOT）。"""
    return ARTIFACTS / "native-delivery" / "install"


def stage_marker_ok(stage: Path) -> bool:
    """暂存目录是否带本仓库的归属标记（`.alger-project` == 仓库根）。

    归属标记是**认领前提**：没有标记的目录一律不认领（宁可漏清，也不误删
    别的会话刚生成的目录）。

    installer 的清理顺序保证：标记**最后才删** —— 清理失败时残留目录仍然
    带得上标记，外层能据此确认「这是本仓库自己建的」。
    """
    marker = stage / ".alger-project"
    if not marker.is_file() or marker.is_symlink():
        return False
    try:
        return marker.read_text(encoding="utf-8").strip() == str(ROOT)
    except OSError:
        return False


def stage_owner_alive(stage: Path) -> bool:
    """暂存目录的 owner 进程是否还活着（活着就不能动它）。

    标记缺失时（残留目录）返回 `False`：owner 已经随 installer 退出。
    """
    owner_file = stage / ".alger-owner-pid"
    if not owner_file.is_file() or owner_file.is_symlink():
        return False
    try:
        owner = owner_file.read_text(encoding="utf-8").strip()
    except OSError:
        return False
    if not owner.isdigit():
        return False
    try:
        os.kill(int(owner), 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        # 进程存在但不属于当前用户：仍然认为它在运行，不动它。
        return True
    except OSError:
        return False
    return True


def all_install_stages() -> list[Path]:
    """列出 installer 暂存根下的**所有**候选 stage 目录。

    只列一层、只列 `alger-install-stage.*` 前缀的**目录**（不跟随软链）。
    归属判定在 `stage_is_owned` 里做，不在这里做。
    """
    root = install_stage_root()
    if not root.is_dir() or root.is_symlink():
        return []
    stages: list[Path] = []
    for stage in sorted(root.iterdir()):
        if not stage.is_dir() or stage.is_symlink():
            continue
        if not stage.name.startswith("alger-install-stage."):
            continue
        stages.append(stage)
    return stages


def stage_is_owned(stage: Path, known_before: set[Path]) -> bool:
    """判断一个 stage 目录是否**归属本夹具**（可以安全清理）。

    规则（**全部满足**才认归属）：
      1. **快照差集**：夹具调用 installer 之前不存在的 stage，才可能是这次
         产生的 —— installer 用 `mktemp -d` 生成唯一名，不会撞名；
      2. **owner 仍在运行** → 一律不动（别的任务正在用它）；
      3. **必须有归属标记**：`.alger-project` 存在且内容等于本仓库规范路径。
         **没有标记的目录一律不认** —— 只凭「新出现 + 里面像 .app」去认领是
         不安全的：别的会话 / 别的任务刚生成的目录也可能长这样，不能因为
         名字前缀和结构像就删掉别人的东西。

    所以 installer 必须**自己**把暂存目录连标记一起删干净；夹具这边只做
    兜底，绝不代替 installer 去认领无标记目录。

    绝不按目录名盲删，也绝不碰 `.artifacts` 之外的路径。
    """
    if stage in known_before:
        return False  # 调用 installer 之前就存在的 → 不是这次产生的
    if stage_owner_alive(stage):
        return False  # owner 还活着 → 别的任务正在用
    # 没有归属标记 → 不认领（宁可漏清，也不误删别人的目录）。
    if not stage_marker_ok(stage):
        return False
    return True


class FixtureScope:
    """夹具作用域：退出时（正常或异常）一定清掉**归属本夹具**的全部内容。

    关键点：installer 会把源包 `ditto` 到
    `.artifacts/native-delivery/install/alger-install-stage.*/`。`ditto` 会
    **保留** `UF_IMMUTABLE` 标志，于是 installer 自己的 `rm -rf "${STAGE}"`
    删不掉它，残留会一直挂在 `.artifacts` 里，并且让 `rm -rf .artifacts`
    （也就是 `scripts/clean.sh`）失败。

    因此清理必须覆盖两类路径：
      * 夹具自己的用例目录；
      * installer 复制到 stage 的**副本**（同样带不可变标志）。
    """

    def __init__(self, name: str) -> None:
        self.name = name
        self.case = FIXTURE_ROOT / f"{name}-{os.getpid()}"
        self._owned: list[Path] = []
        # 调用 installer **之前**的 stage 快照：只有快照之后新出现的 stage
        # 才可能是本次夹具产生的（installer 用 mktemp -d 生成唯一名）。
        self._stages_before: set[Path] = set(all_install_stages())
        self.residue: list[Path] = []

    # -- 登记 ---------------------------------------------------------------
    def own(self, path: Path) -> Path:
        self._owned.append(path)
        return path

    # -- 上下文管理 ---------------------------------------------------------
    def __enter__(self) -> "FixtureScope":
        remove_owned_tree(self.case)
        return self

    def __exit__(self, exc_type, exc, tb) -> bool:
        self.cleanup()
        return False  # 不吞异常

    # -- 清理 ---------------------------------------------------------------
    def cleanup(self) -> list[Path]:
        """清掉夹具目录 + installer stage 副本，返回**没清干净**的路径。"""
        leftovers: list[Path] = []

        # 1) installer 复制到 stage 的副本（含不可变标志的那些）。
        for stage in all_install_stages():
            if not stage_is_owned(stage, self._stages_before):
                continue
            if not remove_owned_tree(stage):
                leftovers.append(stage)

        # 2) 夹具自己的目录。
        for path in self._owned:
            if not remove_owned_tree(path):
                leftovers.append(path)
        if not remove_owned_tree(self.case):
            leftovers.append(self.case)

        self.residue = leftovers
        return leftovers


def has_immutable(path: Path) -> bool:
    """树里是否还有带 `UF_IMMUTABLE` 的条目。"""
    if not path.exists():
        return False
    for item in [path, *path.rglob("*")]:
        try:
            if os.lstat(item).st_flags & stat.UF_IMMUTABLE:
                return True
        except OSError:
            continue
    return False


def make_stub_app(parent: Path, name: str, marker: str, immutable: bool = False) -> Path:
    """造一个结构合法的夹具 bundle（可执行文件里写 marker 便于识别）。"""
    app = parent / name
    (app / "Contents" / "MacOS").mkdir(parents=True, exist_ok=True)
    (app / "Contents" / "Resources").mkdir(parents=True, exist_ok=True)
    executable = app / "Contents" / "MacOS" / "AlgerMusicPlayer"
    executable.write_text(f"#!/bin/sh\n# marker:{marker}\necho {marker}\n", encoding="utf-8")
    executable.chmod(0o755)
    (app / "Contents" / "Info.plist").write_text(PLIST, encoding="utf-8")
    if immutable:
        locked = app / "Contents" / "Resources" / "locked"
        locked.write_text("locked\n", encoding="utf-8")
        os.chflags(locked, os.stat(locked).st_flags | stat.UF_IMMUTABLE)
    return app


def run_installer(env_extra: dict[str, str], timeout: int = 900) -> tuple[int, str]:
    env = os.environ.copy()
    env.update(env_extra)
    proc = subprocess.run(
        ["sh", str(SCRIPTS / "install-dist.sh")],
        cwd=str(ROOT),
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def marker_of(app: Path) -> str:
    executable = app / "Contents" / "MacOS" / "AlgerMusicPlayer"
    if not executable.exists():
        return ""
    return executable.read_text(encoding="utf-8")


# ---------------------------------------------------------------------------
# 1. 安装事务
# ---------------------------------------------------------------------------
def test_transaction() -> None:
    with FixtureScope("transaction") as scope:
        case = scope.case
        dist = case / "dist"
        dist.mkdir(parents=True, exist_ok=True)
        old = make_stub_app(dist, "AlgerMusicPlayer.app", "OLD")
        source = make_stub_app(case / "source", "Source.app", "NEW")
        old_fingerprint = fingerprint(old)

        env = {"ALGER_DIST_DIR": str(dist), "ALGER_INSTALL_SOURCE_APP": str(source)}

        # --- 成功路径 -----------------------------------------------------
        rc, out = run_installer(env)
        check("事务/成功：返回 0", rc == 0, out.strip().splitlines()[-1] if out.strip() else "")
        installed = dist / "AlgerMusicPlayer.app"
        check("事务/成功：入口是新包", "NEW" in marker_of(installed))
        check("事务/成功：旧包已被替换", "OLD" not in marker_of(installed))
        check("事务/成功：只有一个 .app 入口", len(list(dist.glob("*.app"))) == 1)
        check("事务/成功：没有残留备份", not list(dist.glob("*.previous-*")))
        check("事务/成功：没有留下 /Applications 快捷方式",
              not (Path("/Applications") / "AlgerMusicPlayer.app").exists())

        # --- 复制中途失败（旧应用必须回到原位）----------------------------
        current_fp = fingerprint(installed)
        rc, out = run_installer({**env, "ALGER_INSTALL_FAULT": "copy"})
        check("事务/复制中途失败：返回非 0", rc != 0)
        check("事务/复制中途失败：旧应用回到原位", fingerprint(installed) == current_fp)
        check("事务/复制中途失败：没有残留备份", not list(dist.glob("*.previous-*")))
        check("事务/复制中途失败：入口完整（没有半成品）",
              (installed / "Contents" / "MacOS" / "AlgerMusicPlayer").exists())

        # --- 替换后校验失败（同样必须回滚）--------------------------------
        rc, out = run_installer({**env, "ALGER_INSTALL_FAULT": "swap"})
        check("事务/替换后失败：返回非 0", rc != 0)
        check("事务/替换后失败：旧应用回到原位", fingerprint(installed) == current_fp)
        check("事务/替换后失败：没有残留备份", not list(dist.glob("*.previous-*")))

        # --- 校验阶段失败（完全不该动现有应用）----------------------------
        before = fingerprint(installed)
        rc, out = run_installer({**env, "ALGER_INSTALL_FAULT": "verify"})
        check("事务/校验失败：返回非 0", rc != 0)
        check("事务/校验失败：现有应用原封不动", fingerprint(installed) == before)

    check("清理/事务夹具没有残留", not scope.residue,
          "残留：" + ", ".join(str(p) for p in scope.residue))


# ---------------------------------------------------------------------------
# 2. 无法回滚时旧包不得被删除
# ---------------------------------------------------------------------------
def test_backup_preserved_when_rollback_impossible() -> None:
    with FixtureScope("rollback") as scope:
        case = scope.case
        dist = case / "dist"
        dist.mkdir(parents=True, exist_ok=True)
        old = make_stub_app(dist, "AlgerMusicPlayer.app", "OLD")
        # 源包里放一个不可变文件：复制后 `rm -rf` 会失败 → 回滚无法完成。
        source = make_stub_app(case / "source", "Source.app", "NEW", immutable=True)
        old_fingerprint = fingerprint(old)

        rc, out = run_installer({
            "ALGER_DIST_DIR": str(dist),
            "ALGER_INSTALL_SOURCE_APP": str(source),
            "ALGER_INSTALL_FAULT": "swap",
        })
        check("回滚不可能：返回非 0", rc != 0)
        backups = list(dist.glob("*.previous-*"))
        check("回滚不可能：旧包仍留在备份里", bool(backups))
        if backups:
            # 备份路径本身就是被移走的旧应用（dist/AlgerMusicPlayer.app.previous-<pid>）。
            check("回滚不可能：备份里的旧包内容完好", fingerprint(backups[0]) == old_fingerprint)
        check("回滚不可能：日志说明了旧包位置", "旧应用" in out or "旧包" in out)

    check("清理/回滚夹具没有残留", not scope.residue,
          "残留：" + ", ".join(str(p) for p in scope.residue))


# ---------------------------------------------------------------------------
# 3. 参数与路径保护（非破坏）
# ---------------------------------------------------------------------------
def test_parameter_guards() -> None:
    with FixtureScope("guards") as scope:
        case = scope.case
        case.mkdir(parents=True, exist_ok=True)

        # 夹具输出目录必须位于仓库 .artifacts/ 之下
        outside = Path("/tmp/alger-guard-should-not-exist")
        rc, out = run_installer({"ALGER_DIST_DIR": str(outside)})
        check("保护/夹具目录必须在 .artifacts/ 之下", rc == 2, out.strip().splitlines()[0] if out.strip() else "")
        check("保护/越权目录未被创建", not outside.exists())

        # 故障注入只能在夹具模式下生效
        rc, out = run_installer({"ALGER_INSTALL_FAULT": "swap"})
        check("保护/故障注入需要夹具模式", rc == 2, out.strip().splitlines()[0] if out.strip() else "")

        # 源 bundle 覆盖只能在夹具模式下生效
        source = make_stub_app(case, "Source.app", "NEW")
        rc, out = run_installer({"ALGER_INSTALL_SOURCE_APP": str(source)})
        check("保护/源 bundle 覆盖需要夹具模式", rc == 2, out.strip().splitlines()[0] if out.strip() else "")

        # 路径穿越：.artifacts/../dist 不得被当成合法输出
        traversal = f"{ROOT}/.artifacts/../dist/AlgerMusicPlayer.app"
        proc = subprocess.run(
            ["sh", str(SCRIPTS / "build-native.sh"), "--output", traversal],
            cwd=str(ROOT), capture_output=True, text=True, timeout=120,
        )
        check("保护/路径穿越被拒绝（构建脚本）", proc.returncode == 2,
              (proc.stdout + proc.stderr).strip().splitlines()[0] if (proc.stdout + proc.stderr).strip() else "")

        # --verify 与 --output 不能同时使用
        proc = subprocess.run(
            ["sh", str(SCRIPTS / "build-native.sh"), "--verify", str(ROOT / "dist"),
             "--output", f"{ARTIFACTS}/native-build/AlgerMusicPlayer.app"],
            cwd=str(ROOT), capture_output=True, text=True, timeout=120,
        )
        check("保护/--verify 与 --output 互斥", proc.returncode == 2)

    check("清理/保护夹具没有残留", not scope.residue,
          "残留：" + ", ".join(str(p) for p in scope.residue))


# ---------------------------------------------------------------------------
# 4. 脚本静态约定
# ---------------------------------------------------------------------------
def read_script(name: str) -> str:
    return (SCRIPTS / name).read_text(encoding="utf-8")


def test_static_contracts() -> None:
    build = read_script("build-native.sh")
    install = read_script("install-dist.sh")
    runner = read_script("run-native-app.sh")
    quit_script = (SCRIPTS / "quit-native.swift").read_text(encoding="utf-8")

    check("静态/Swift trial 标志", "-Xswiftc" in build and "-DALGER_TRIAL" in build)
    check("静态/Rust trial 标志", "export ALGER_TRIAL=1" in build)
    check("静态/完整 Xcode（不改 xcode-select）", "DEVELOPER_DIR" in build)
    check("静态/包内桥接路径", "Contents/Resources/alger-bridge" in build)
    check("静态/应用可执行文件名", "Contents/MacOS/${BUNDLE_NAME}" in build)
    check("静态/只读身份接口", "--print-runtime-identity" in build)
    check("静态/trial bundle 标识", "com.alger.music.trial" in build)
    check("静态/复用既有本地化脚本", "localize-trial.swift" in build)
    check("静态/拒绝 . 与 .. 组件", "reject_dot_components" in build)

    check("静态/安装器走原生构建", "build-native.sh" in install)
    check("静态/安装器不再走 tauri", "tauri build" not in install)
    check("静态/安装器调用独立校验", "build-native.sh --verify" in install)
    check("静态/安装器调用隔离试跑",
          "run-native-app.sh" in install and "--app" in install)
    check("静态/安装器先置 SWAPPED 再复制",
          install.index("SWAPPED=1") < install.index('ditto "${APP}" "${DIST_APP}"'))
    check("静态/安装器保留旧包（回滚）", "已回滚到旧应用" in install)

    check("静态/试跑支持 --app", "--app" in runner)
    check("静态/试跑清除 ALGER_BRIDGE_BIN", "unset ALGER_BRIDGE_BIN" in runner)
    check("静态/试跑按 PID 定向退出", "quit-native.swift" in runner)
    check("静态/试跑读取完整可执行路径", "ps -ww -o comm=" in runner)
    check("静态/试跑使用唯一数据目录", "mktemp -d" in runner)

    check("静态/定向退出用 processIdentifier", "processIdentifier" in quit_script)
    check("静态/定向退出用 kAEQuitApplication", "kAEQuitApplication" in quit_script)
    # 只看**代码**：注释里可以解释为什么不用 `tell application id ...`。
    quit_code = "\n".join(
        line for line in quit_script.splitlines()
        if not line.strip().startswith("//")
    )
    check("静态/定向退出不按 bundle id", "tell application" not in quit_code)

    # 脚本语法
    for name in ("build-native.sh", "install-dist.sh", "run-native-app.sh", "clean.sh"):
        proc = subprocess.run(["bash", "-n", str(SCRIPTS / name)], capture_output=True, text=True)
        check(f"语法/{name} bash -n", proc.returncode == 0, proc.stderr.strip())
        proc = subprocess.run(["sh", "-n", str(SCRIPTS / name)], capture_output=True, text=True)
        check(f"语法/{name} sh -n", proc.returncode == 0, proc.stderr.strip())

    # Info.plist 模板
    plist = (ROOT / "native/macos/Resources/Info.plist").read_text(encoding="utf-8")
    check("静态/Info.plist 标识", "<string>com.alger.music.trial</string>" in plist)
    check("静态/Info.plist 可执行文件", "<string>AlgerMusicPlayer</string>" in plist)
    check("静态/Info.plist 图标", "<string>icon.icns</string>" in plist)


# ---------------------------------------------------------------------------
# 4. 副本清理 RAII：installer stage 里的不可变副本必须被清掉
# ---------------------------------------------------------------------------
def test_stage_copy_residue_cleaned() -> None:
    """installer stage 里的不可变副本必须被清掉（两层都要成立）。

    这正是「65 项通过不代表残留已清完」的来源：
      * `ditto` **保留** `UF_IMMUTABLE`（uchg）；
      * 旧版 installer 用 `rm -rf "${STAGE}"` 删不掉带该标志的文件；
      * 残留挂在 `.artifacts/native-delivery/install/alger-install-stage.*/`，
        并且让 `rm -rf .artifacts`（`scripts/clean.sh`）失败。

    本用例分别检验两层：
      1. **installer 层**：installer 退出后，它自己的 stage 必须已经清干净
         （含复制来的不可变文件）—— 不依赖夹具帮忙；
      2. **夹具 RAII 层**：即使 installer 留下残留，夹具作用域退出时也必须
         把本次产生的 stage 连同不可变副本一起清掉；
      3. **作用域安全性**：只清归属本夹具的 stage，别人的 / owner 仍活着的
         一律不动。
    """
    root = install_stage_root()
    root.mkdir(parents=True, exist_ok=True)

    # 别人的 stage：标记正确但 owner 还活着 —— 必须保留。
    foreign = root / "alger-install-stage.foreignfixture"
    foreign.mkdir(parents=True, exist_ok=True)
    (foreign / ".alger-project").write_text(f"{ROOT}\n", encoding="utf-8")
    (foreign / ".alger-owner-pid").write_text(f"{os.getpid()}\n", encoding="utf-8")
    (foreign / "keep.bin").write_text("keep\n", encoding="utf-8")

    # 别人的 stage：没有本仓库标记 —— 必须保留。
    unmarked = root / "alger-install-stage.unmarkedfixture"
    unmarked.mkdir(parents=True, exist_ok=True)
    (unmarked / "keep.bin").write_text("keep\n", encoding="utf-8")

    try:
        with FixtureScope("stagecopy") as scope:
            case = scope.case
            dist = case / "dist"
            dist.mkdir(parents=True, exist_ok=True)
            make_stub_app(dist, "AlgerMusicPlayer.app", "OLD")
            # 源包带不可变文件：installer `ditto` 到 stage 后副本也带该标志。
            source = make_stub_app(case / "source", "Source.app", "NEW", immutable=True)

            rc, out = run_installer({
                "ALGER_DIST_DIR": str(dist),
                "ALGER_INSTALL_SOURCE_APP": str(source),
                "ALGER_INSTALL_FAULT": "swap",
            })
            check("副本清理：注入故障后返回非 0", rc != 0)

            # 第 1 层：installer 自己必须已经清干净（不依赖夹具 RAII）。
            # 这一层直接盯住「installer 的退出清理是否处理了不可变标志」。
            produced = [s for s in all_install_stages() if stage_is_owned(s, scope._stages_before)]
            check("副本清理：installer 退出后自己的 stage 已清干净（含不可变文件）",
                  not produced,
                  "；".join(str(s) for s in produced))
            check("副本清理：installer 没有留下不可变残留",
                  not any(has_immutable(s) for s in produced))

        # 第 2 层：夹具作用域退出后，本次产生的 stage 必须全部消失
        # （installer 要是漏了，夹具 RAII 兜底）。
        after = [s for s in all_install_stages() if stage_is_owned(s, scope._stages_before)]
        check("副本清理：stage 副本已全部清除（含不可变文件）", not after,
              "；".join(str(s) for s in after))
        check("副本清理：没有留下不可变残留",
              not any(has_immutable(s) for s in after))
        check("副本清理：夹具作用域报告无残留", not scope.residue,
              "残留：" + ", ".join(str(p) for p in scope.residue))

        # 第 3 层：别人的 stage 必须原封不动。
        check("副本清理：owner 仍在运行的 stage 被保留", (foreign / "keep.bin").exists())
        check("副本清理：无标记的 stage 被保留", (unmarked / "keep.bin").exists())
    finally:
        # 本用例自己造的两个 stage 必须无条件清掉（避免污染后续用例）。
        for path in (foreign, unmarked):
            remove_owned_tree(path)


# ---------------------------------------------------------------------------
# 4b. 夹具 RAII 层单独验证：带归属标记的 stage 残留必须被夹具清掉
# ---------------------------------------------------------------------------
def test_fixture_raii_cleans_leftover_stage() -> None:
    """夹具作用域必须能清掉「installer 漏下」的 stage 残留（含不可变文件）。

    这一层单独验证，不依赖 installer 自己的清理是否正确：
    造一个 installer 失败后会留下的残留 —— 带归属标记、里面是 bundle 结构、
    还有一个 `UF_IMMUTABLE` 文件 —— 看夹具作用域退出时是否清干净。

    这是旧版「只清原夹具」的实现漏掉的路径：夹具目录清干净了，
    stage 里的副本还挂着，`rm -rf .artifacts` 因此失败。

    同时验证**收紧后的归属规则**：无标记的目录即使长得很像 stage，
    夹具也**不得**去清它（不能扫掉别的会话刚生成的目录）。
    """
    root = install_stage_root()
    root.mkdir(parents=True, exist_ok=True)

    # 作用域先建立（快照 = 当前已有的 stage），再制造「残留」，
    # 这样残留就落在快照之后，符合「installer 这次产生的」语义。
    scope = FixtureScope("raiicheck")

    # 模拟 installer 失败后留下的 stage：带归属标记 + 带不可变标志的副本。
    leftover = root / "alger-install-stage.leftoverfixture"
    remove_owned_tree(leftover)
    bundle = leftover / "AlgerMusicPlayer.app" / "Contents" / "Resources"
    bundle.mkdir(parents=True, exist_ok=True)
    (leftover / ".alger-project").write_text(f"{ROOT}\n", encoding="utf-8")
    locked = bundle / "locked"
    locked.write_text("locked\n", encoding="utf-8")
    os.chflags(locked, os.stat(locked).st_flags | stat.UF_IMMUTABLE)

    # 长得像 stage、但**没有归属标记**：不得被认领、不得被清掉。
    unmarked = root / "alger-install-stage.unmarkedother"
    remove_owned_tree(unmarked)
    (unmarked / "AlgerMusicPlayer.app").mkdir(parents=True, exist_ok=True)
    (unmarked / "AlgerMusicPlayer.app" / "keep.bin").write_text("keep\n", encoding="utf-8")

    try:
        # 带标记的残留：属于本仓库自己建的 stage → 夹具可以清。
        check("夹具RAII：带标记的残留被认领为归属本夹具",
              stage_is_owned(leftover, scope._stages_before))
        # 无标记的：不得被认领。
        check("夹具RAII：无标记的残留不被认领",
              not stage_is_owned(unmarked, scope._stages_before))

        scope.own(leftover)
        scope.cleanup()

        check("夹具RAII：installer 遗留的 stage 被清掉", not leftover.exists())
        check("夹具RAII：残留里的不可变文件没有留下",
              not has_immutable(leftover))
        check("夹具RAII：作用域报告无残留", not scope.residue,
              "残留：" + ", ".join(str(p) for p in scope.residue))
        # 无标记的目录必须原封不动。
        check("夹具RAII：无标记的目录没有被清掉",
              (unmarked / "AlgerMusicPlayer.app" / "keep.bin").exists())
    finally:
        remove_owned_tree(leftover)
        remove_owned_tree(unmarked)


# ---------------------------------------------------------------------------
# 5. 脚本静态约定
# ---------------------------------------------------------------------------
def test_real_state_untouched() -> None:
    dist = ROOT / "dist"
    check("真实产物/dist 仍在", dist.exists())
    check("真实产物/唯一入口仍是 dist/AlgerMusicPlayer.app",
          (dist / "AlgerMusicPlayer.app").exists())
    check("真实产物/没有 /Applications 快捷方式",
          not (Path("/Applications") / "AlgerMusicPlayer.app").exists())


def main() -> int:
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    FIXTURE_ROOT.mkdir(parents=True, exist_ok=True)

    dist_before = fingerprint(ROOT / "dist")
    profiles_before = profile_fingerprint()
    applications_before = (Path("/Applications") / "AlgerMusicPlayer.app").exists()

    test_transaction()
    test_backup_preserved_when_rollback_impossible()
    test_parameter_guards()
    test_stage_copy_residue_cleaned()
    test_fixture_raii_cleans_leftover_stage()
    test_static_contracts()
    test_real_state_untouched()

    dist_after = fingerprint(ROOT / "dist")
    profiles_after = profile_fingerprint()
    applications_after = (Path("/Applications") / "AlgerMusicPlayer.app").exists()

    check("真实产物/dist 指纹未变", dist_before == dist_after)
    check("真实产物/用户资料库指纹未变", profiles_before == profiles_after)
    check("真实产物/没有新建 /Applications 快捷方式", applications_before == applications_after)

    failed = [name for name, ok, _ in RESULTS if not ok]
    print()
    print(f"合计 {len(RESULTS)} 项，失败 {len(failed)} 项")
    for name in failed:
        print(f"  失败：{name}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
