//! 持久下载队列（原生 macOS 端）。
//!
//! 与 `src-tauri/src/download.rs`（内存 + Tauri 事件）不同，本模块：
//! - 任务状态持久化到 `bridge/downloads.json`（原子写），重启后未完成任务仍在，
//!   目标歌单关联由 Swift 侧持有（本模块只负责把音频文件真实落到磁盘）；
//! - 事件通过回调通道推给桥接 stdout（`{"ev":"dl", ...}`），不依赖任何 UI；
//! - 失败任务保留原因与可重试入口；成功后文件落位与临时文件清理与
//!   Tauri 侧语义一致（`*.part` + 原子落位 + 不覆盖已有文件）。

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use tokio::io::AsyncWriteExt;

use crate::download::{detect_extension, guess_extension, sanitize_filename, unique_path};

/// 单个下载任务的状态：`queued` / `running` / `done` / `failed`。
pub const STATUS_QUEUED: &str = "queued";
pub const STATUS_RUNNING: &str = "running";
pub const STATUS_DONE: &str = "done";
pub const STATUS_FAILED: &str = "failed";

/// 持久化的下载任务。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DlTask {
    /// 网易云歌曲 ID。
    pub id: i64,
    pub name: String,
    pub artist: String,
    pub album: String,
    /// 时长毫秒（用于音源匹配）。
    pub duration_ms: i64,
    /// 目标文件路径（done 后有效）。
    pub path: String,
    pub downloaded: u64,
    pub total: u64,
    pub status: String,
    pub error: Option<String>,
    pub source: Option<String>,
    /// 任务创建时间（Unix 毫秒）。
    pub created_at: u64,
    /// 最近更新时间（Unix 毫秒）。
    pub updated_at: u64,
    /// 目标歌单标识列表（Swift 侧歌单的稳定 ID；下载成功后据此入单）。
    /// 持久化在 downloads.json，跨重启不丢失（审查 F3）。
    #[serde(default)]
    pub targets: Vec<String>,
    /// 完成凭据摘要（内容 FNV-1a 64 位十六进制）。
    ///
    /// 与 `path` + 大小一起构成「这个路径上的文件确实是我们落位的那份」
    /// 的证据：只比大小的话，同大小的无关文件会被误认成已完成
    /// （审查 E1-6）。
    ///
    /// **兼容限制**：升级前写入的旧记录没有该字段（空串）。这类记录
    /// **无法证明**同一性，恢复时不得自动认 done——会显式标注待处理并
    /// 重新下载（见 `run` 的 intent 恢复分支）。
    #[serde(default)]
    pub digest: String,
}

impl DlTask {
    fn percent(&self) -> u32 {
        if self.total == 0 {
            0
        } else {
            ((self.downloaded as f64 / self.total as f64) * 100.0).clamp(0.0, 100.0) as u32
        }
    }
}

/// 持久化文件结构（含统计，便于人工排查）。
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct DlState {
    #[serde(default)]
    tasks: Vec<DlTask>,
}

/// 事件回调：`true` 表示队列需要落盘。
pub type EventSink = Arc<dyn Fn(serde_json::Value) + Send + Sync>;

/// 磁盘冲突令牌：修改时间 + 长度 + **inode + 设备号**。
///
/// 加上 inode / 设备号后，「同长度、同 mtime」的替换（rename 换 inode）
/// 也能被识别出来（审查 E1-4）；仅比较 (mtime, len) 时这种替换会被漏检。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct DiskToken {
    mtime: std::time::SystemTime,
    len: u64,
    ino: u64,
    dev: u64,
}

impl DiskToken {
    fn of(meta: &std::fs::Metadata) -> DiskToken {
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            DiskToken {
                mtime: meta.modified().unwrap_or(std::time::UNIX_EPOCH),
                len: meta.len(),
                ino: meta.ino(),
                dev: meta.dev(),
            }
        }
        #[cfg(not(unix))]
        {
            DiskToken {
                mtime: meta.modified().unwrap_or(std::time::UNIX_EPOCH),
                len: meta.len(),
                ino: 0,
                dev: 0,
            }
        }
    }

    fn of_path(path: &Path) -> Option<DiskToken> {
        std::fs::metadata(path).ok().map(|m| DiskToken::of(&m))
    }
}

/// 跨进程文件锁的等待上限：超过即报错，**绝不无限阻塞**（审查 E1-5）。
const FLOCK_WAIT: std::time::Duration = std::time::Duration::from_secs(10);

/// 持久下载队列。
pub struct DlQueue {
    http: reqwest::Client,
    state: Mutex<DlState>,
    path: PathBuf,
    sink: EventSink,
    /// 本进程内已派生下载任务、**真正仍在运行**的歌曲 ID。
    ///
    /// 这是「是否真的在下载」的唯一判据：持久状态是 `running` 不等于还在
    /// 下载（落盘失败时磁盘会停在 running，但下载其实已经结束）——
    /// 对外用 [`Self::is_active`] 暴露，避免重试路径被假 running 挡住
    /// （审查 E0-8）。
    active: Mutex<HashSet<i64>>,
    /// 进程关闭标志：置位后在途下载在下一个块边界暂停（状态持久化为
    /// queued + 可重试错误，targets 保留），新入队被拒绝。
    shutdown: std::sync::atomic::AtomicBool,
    /// 关闭通知：在途 **HTTP 请求** 据此被立即取消（审查 E1-2）。
    shutdown_notify: Arc<tokio::sync::Notify>,
    /// 磁盘冲突令牌：每次成功落盘后记录。在 **文件锁内** 比对——不一致说明
    /// downloads.json 被其他实例 / 进程修改或删除，拒绝用旧快照覆盖。
    disk_tag: Mutex<Option<DiskToken>>,
    /// 跨进程互斥锁文件（flock）：整个「检查 → 写」序列持排他锁，
    /// 两个实例不可能同时通过检查再互相覆盖。
    lock_file: std::fs::File,
    /// 进程内事务锁：串行化「取跨进程锁 → 改状态 → 落盘」整段。
    ///
    /// **必须**有它：flock 是「按打开文件描述」生效的，同一进程内第二个
    /// 线程用同一个 fd 再加锁会 **假成功**（内核认为已经持有）→ 两个线程
    /// 会同时进入临界区；而其中一个先 LOCK_UN 时，**实际的文件锁会被提前
    /// 释放**，另一实例就能插进来写坏数据。
    /// 有了这把进程内锁，「跨进程锁」在任一时刻只被一个线程持有，
    /// 加锁 / 解锁严格 1:1 配对（RAII 守卫），不再需要计数器。
    txn: Mutex<()>,
    /// 跨进程锁的等待上限（测试可缩短）。
    lock_wait: std::time::Duration,
    /// 载入问题（downloads.json 损坏等）。存在问题时拒绝写入持久化文件。
    load_issue: parking_lot::RwLock<Option<String>>,
    /// 最近一次落盘错误（写失败必须可见，不能吞掉）。
    last_error: parking_lot::RwLock<Option<String>>,
}

impl DlQueue {
    /// 打开队列并载入持久化状态。
    ///
    /// **初始读取、状态转换与首次落盘整体在跨进程锁内完成**（审查 E0-4）：
    /// 「锁外读 + 锁外首次写」会形成陈旧快照覆盖另一实例的窗口
    /// （旧快照 + 新基线 = 冲突检测形同虚设：读到的不是最新，写出的却是）。
    ///
    /// 重启恢复规则：
    /// - `running` 状态是上次进程中断的产物，改回 `queued` 并保留原因
    ///   「应用重启，任务未完成」，其 `targets`（目标歌单）原样保留；
    /// - `done` / `failed` 状态原样保留；
    /// - downloads.json 读取 / 解析失败时 **备份原文件、上报问题、拒绝写入**，
    ///   绝不静默清空后覆盖（审查 F3）；备份本身 0600、不写穿符号链接、
    ///   不覆盖既有文件（审查 E0-1）。
    pub fn open(dir: &Path, sink: EventSink) -> std::io::Result<DlQueue> {
        std::fs::create_dir_all(dir)?;
        let path = dir.join("downloads.json");
        // 锁文件：绝不截断既有目标（符号链接指向的文件也不能被截断）——
        // 审查 E0-10。
        let lock_file = open_lock_file(&dir.join("downloads.json.lock"))?;
        let queue = DlQueue {
            http: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(1800))
                .connect_timeout(std::time::Duration::from_secs(15))
                .user_agent(
                    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
                )
                .build()
                .expect("build download client"),
            state: Mutex::new(DlState::default()),
            path,
            sink,
            active: Mutex::new(HashSet::new()),
            shutdown: std::sync::atomic::AtomicBool::new(false),
            shutdown_notify: Arc::new(tokio::sync::Notify::new()),
            disk_tag: Mutex::new(None),
            // 锁文件常开：flock 锁依附 fd，进程崩溃由内核自动释放
            lock_file,
            txn: Mutex::new(()),
            lock_wait: FLOCK_WAIT,
            load_issue: parking_lot::RwLock::new(None),
            last_error: parking_lot::RwLock::new(None),
        };

        // —— 跨进程锁内完成「读取 → 解析 → 转换 → 落盘 → 采基线」——
        {
            let _txn = queue.txn.lock();
            let _flock =
                FileLockGuard::acquire(&queue, FLOCK_WAIT).map_err(std::io::Error::other)?;
            let mut state = queue.state.lock();
            let issue = queue.load_initial_state(&mut state);
            *queue.load_issue.write() = issue;
            // running → queued（锁内，保证落盘内容就是转换后的状态）
            let now = crate::now_millis();
            for t in state.tasks.iter_mut() {
                if t.status == STATUS_RUNNING {
                    t.status = STATUS_QUEUED.to_string();
                    t.error = Some("应用重启，任务未完成，可重试".into());
                    t.updated_at = now;
                }
            }
            // 锁内落盘：此刻 disk_tag 为 None → 不做冲突判定；但状态来自
            // **同一临界区内**的读取，其它实例此刻拿不到锁，不会丢数据。
            if let Err(e) = queue.write_state_locked(&state) {
                eprintln!("alger-core: download queue persist failed: {}", e);
            }
            drop(state);
            // 锁内采集磁盘基线（与初始读取同一临界区）。
            *queue.disk_tag.lock() = DiskToken::of_path(&queue.path);
        }
        Ok(queue)
    }

    /// 锁内读取并解析 downloads.json；损坏时安全备份并返回载入问题。
    fn load_initial_state(&self, state: &mut DlState) -> Option<String> {
        match std::fs::read(&self.path) {
            Ok(bytes) => match serde_json::from_slice::<DlState>(&bytes) {
                Ok(parsed) => {
                    *state = parsed;
                    None
                }
                Err(e) => {
                    // 空文件与损坏同权处理：仅 NotFound 才算首次运行；
                    // 空文件可能是外部截断，静默回写默认状态会掩盖问题。
                    let why = if bytes.is_empty() {
                        "下载队列为空文件（可能被截断）".to_string()
                    } else {
                        format!("下载队列文件解析失败（{}）", e)
                    };
                    let backup_note = match crate::session::write_secure_backup(&self.path, &bytes)
                    {
                        Ok(backup) => format!("，原文件已备份为 {}", backup.display()),
                        Err(be) => format!("，备份失败（{}），原文件保持原样", be),
                    };
                    Some(format!("{}{}；已保留原文件并拒绝写入", why, backup_note))
                }
            },
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
            Err(e) => Some(format!(
                "下载队列文件无法读取（{}）：{}；已保留原文件并拒绝写入",
                self.path.display(),
                e
            )),
        }
    }

    /// 载入问题（正常时为 `None`）。桥接层必须把它透出给界面。
    pub fn load_issue(&self) -> Option<String> {
        self.load_issue.read().clone()
    }

    /// 最近一次落盘错误（正常时为 `None`）。
    pub fn last_error(&self) -> Option<String> {
        self.last_error.read().clone()
    }

    /// 当前任务列表。
    pub fn list(&self) -> Vec<DlTask> {
        self.state.lock().tasks.clone()
    }

    /// 该任务当前是否 **真的** 在下载（进程内在途集合）。
    ///
    /// 持久状态 `running` ≠ 还在下载：完成后的落盘失败会让磁盘停在
    /// `running`，而下载其实已经结束。用它区分二者，公开重试路径才能
    /// 正确放行「已完成但状态没落盘」的 intent 任务（审查 E0-8）。
    pub fn is_active(&self, id: i64) -> bool {
        self.active.lock().contains(&id)
    }

    /// 把 `snap` 原子写入 downloads.json（**调用方必须已持有跨进程锁**）。
    ///
    /// 多实例安全（审查 R3 / E0-4）：stat 比较 + rename 不是跨进程事务，
    /// 必须持有真实文件锁后 **在锁内重判** 冲突令牌；文件被其他进程修改
    /// 或删除都判冲突，拒绝用旧快照覆盖 / 拒绝静默重建。
    fn write_state_locked(&self, snap: &DlState) -> Result<(), String> {
        if let Some(issue) = self.load_issue.read().clone() {
            let err = format!("下载队列拒绝写入（{}）", issue);
            *self.last_error.write() = Some(err.clone());
            return Err(err);
        }
        // 符号链接（含悬空链接）：拒绝替换——rename 会摧毁链接本身，
        // 既不写穿目标也会丢失链接语义。
        if let Ok(m) = std::fs::symlink_metadata(&self.path) {
            if m.file_type().is_symlink() {
                let err = format!(
                    "下载队列文件 {} 是符号链接，拒绝替换以保护其指向的数据",
                    self.path.display()
                );
                *self.last_error.write() = Some(err.clone());
                return Err(err);
            }
        }
        // 锁内重判磁盘令牌：与本实例上次记录不一致 = 其他实例已写入
        if let Some(expect) = *self.disk_tag.lock() {
            match std::fs::metadata(&self.path) {
                Ok(m) => {
                    if DiskToken::of(&m) != expect {
                        let err =
                            "下载队列文件被其他进程修改，拒绝用旧状态覆盖（请重启应用重载队列）"
                                .to_string();
                        *self.last_error.write() = Some(err.clone());
                        return Err(err);
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                    // 已跟踪的文件被删除也是并发修改：静默重建会丢掉
                    // 另一实例刚写入的任务，判冲突
                    let err =
                        "下载队列文件被其他进程删除，拒绝重建覆盖并发状态（请重启应用重载队列）"
                            .to_string();
                    *self.last_error.write() = Some(err.clone());
                    return Err(err);
                }
                Err(e) => {
                    let err = format!("下载队列写入前无法读取现有文件：{}", e);
                    *self.last_error.write() = Some(err.clone());
                    return Err(err);
                }
            }
        }
        let json =
            serde_json::to_string_pretty(snap).map_err(|e| format!("下载队列序列化失败：{}", e))?;
        // 唯一临时文件：进程内计数 + 时间戳，并发持久化永不共享同一暂存
        static TMP_N: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let n = TMP_N.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let tmp = self.path.with_extension(format!(
            "json.dl-{}-{}-{}.tmp",
            std::process::id(),
            crate::now_millis(),
            n
        ));
        let result = (|| -> std::io::Result<()> {
            use std::io::Write;
            #[cfg(unix)]
            let mut file = {
                use std::os::unix::fs::OpenOptionsExt;
                std::fs::OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .mode(0o600)
                    .open(&tmp)?
            };
            #[cfg(not(unix))]
            let mut file = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&tmp)?;
            file.write_all(json.as_bytes())?;
            file.sync_all()?;
            std::fs::rename(&tmp, &self.path)?;
            if let Ok(d) = std::fs::File::open(self.path.parent().unwrap_or_else(|| Path::new(".")))
            {
                let _ = d.sync_all();
            }
            Ok(())
        })();
        match result {
            Ok(()) => {
                // 记录新磁盘令牌（供下次外部修改检测）
                *self.disk_tag.lock() = DiskToken::of_path(&self.path);
                *self.last_error.write() = None;
                Ok(())
            }
            Err(e) => {
                let _ = std::fs::remove_file(&tmp);
                let err = format!("下载队列写入失败（原文件未改动）：{}", e);
                *self.last_error.write() = Some(err.clone());
                Err(err)
            }
        }
    }

    /// 落盘当前内存状态（测试辅助：整表替换后写盘）。
    #[cfg(test)]
    fn persist(&self) -> Result<(), String> {
        let _txn = self.txn.lock();
        let _flock = FileLockGuard::acquire(self, self.lock_wait)?;
        let guard = self.state.lock();
        self.write_state_locked(&guard)
    }

    /// 落盘失败时对 UI 可见的事件（不携带假成功状态）。
    fn emit_persist_error(&self, id: Option<i64>, error: &str) {
        let payload = match id {
            Some(id) => serde_json::json!({ "id": id, "error": error }),
            None => serde_json::json!({ "error": error }),
        };
        (self.sink)(serde_json::json!({ "ev": "dl.persistError", "p": payload }));
    }

    fn emit(&self, task: &DlTask) {
        let payload = serde_json::json!({
            "id": task.id,
            "name": task.name,
            "artist": task.artist,
            "album": task.album,
            "durationMs": task.duration_ms,
            "path": task.path,
            "downloaded": task.downloaded,
            "total": task.total,
            "percent": task.percent(),
            "status": task.status,
            "error": task.error,
            "source": task.source,
            "createdAt": task.created_at,
            "updatedAt": task.updated_at,
            "targets": task.targets,
        });
        (self.sink)(serde_json::json!({ "ev": "dl", "p": payload }));
    }

    /// 事务化修改任务（审查 R2 / R3 / R4 / E1-5 / E1-10）：
    /// 1. 先取 **跨进程锁**（有界等待），再取进程内状态锁——锁序固定为
    ///    `flock → state`，避免在等待跨进程锁时长时间占住状态锁；
    /// 2. 定位任务并保存旧记录；
    /// 3. 应用修改；
    /// 4. **先落盘**（同一临界区内，串行化）；
    /// 5. 落盘成功后才发事件（UI 永不见假 done），且 **不持锁** 回调；
    /// 6. 落盘失败：内存 **精确恢复旧记录**（不丢旧 path / targets / 摘要），
    ///    发 `dl.persistError` 事件使失败对 UI 可见，返回 `None`。
    fn mutate<F: FnOnce(&mut DlTask)>(&self, id: i64, f: F) -> Option<DlTask> {
        let mut saved: Option<DlTask> = None;
        let mut failure: Option<String> = None;
        {
            let _txn = self.txn.lock();
            match FileLockGuard::acquire(self, self.lock_wait) {
                Ok(_flock) => {
                    let mut guard = self.state.lock();
                    if let Some(idx) = guard.tasks.iter().position(|t| t.id == id) {
                        let old = guard.tasks[idx].clone();
                        let now = crate::now_millis();
                        f(&mut guard.tasks[idx]);
                        guard.tasks[idx].updated_at = now;
                        let snap = guard.tasks[idx].clone();
                        match self.write_state_locked(&guard) {
                            Ok(()) => saved = Some(snap),
                            Err(e) => {
                                guard.tasks[idx] = old;
                                failure = Some(e);
                            }
                        }
                    }
                }
                Err(e) => failure = Some(e),
            }
        } // ← 进程内事务锁 / 跨进程锁 / 状态锁 在此全部释放
        if let Some(e) = failure {
            *self.last_error.write() = Some(e.clone());
            self.emit_persist_error(Some(id), &e);
            return None;
        }
        if let Some(snap) = saved {
            self.emit(&snap);
            return Some(snap);
        }
        None
    }

    /// 登记任务（同步，在任何 await 之前调用，避免并发重复下载）。
    ///
    /// 落盘失败时：内存 **精确恢复旧记录**（审查 R4：不得按 ID 删除，
    /// 否则旧 done 记录的 path / targets 一并丢失），发 persistError 事件，
    /// 并上抛错误（审查 P0-3）——下载不得在没有持久化记录的情况下启动。
    ///
    /// 同 id 重入：合并 targets（旧值在前，新增去重追加），并保留旧记录的
    /// **发布 intent**（path / 大小 / 内容摘要）——上次中断或「落盘失败」
    /// 留下的最终路径与内容凭据是恢复的依据，不得在新登记时清空
    /// （否则 run 的 intent 恢复分支永远走不到）。
    fn reserve(&self, task: DlTask) -> Result<(), String> {
        let mut task = task;
        let mut failure: Option<String> = None;
        {
            let _txn = self.txn.lock();
            let flock = match FileLockGuard::acquire(self, self.lock_wait) {
                Ok(g) => g,
                Err(e) => {
                    *self.last_error.write() = Some(e.clone());
                    self.emit_persist_error(Some(task.id), &e);
                    return Err(format!("{}；任务未启动", e));
                }
            };
            let _flock = flock;
            let mut guard = self.state.lock();
            let old_index = guard.tasks.iter().position(|t| t.id == task.id);
            let old_record = old_index.map(|i| guard.tasks[i].clone());
            if let Some(old) = &old_record {
                let mut merged = old.targets.clone();
                for t in std::mem::take(&mut task.targets) {
                    if !merged.contains(&t) {
                        merged.push(t);
                    }
                }
                task.targets = merged;
                if task.path.is_empty() {
                    task.path = old.path.clone();
                }
                if task.downloaded == 0 {
                    task.downloaded = old.downloaded;
                }
                if task.total == 0 {
                    task.total = old.total;
                }
                if task.digest.is_empty() {
                    task.digest = old.digest.clone();
                }
            }
            // 同 id 重入 **保持原位置**（任务顺序稳定，审查 E1-10）
            match old_index {
                Some(i) => guard.tasks[i] = task.clone(),
                None => guard.tasks.push(task.clone()),
            }
            match self.write_state_locked(&guard) {
                Ok(()) => {}
                Err(e) => {
                    // R4 / E1-10：按 **原位** 恢复旧记录（保留旧 path /
                    // targets / 摘要 / 顺序），不得按 ID 删除后追加到末尾。
                    match old_index {
                        Some(i) => {
                            guard.tasks[i] = old_record.clone().unwrap_or_else(|| task.clone())
                        }
                        None => {
                            guard.tasks.retain(|t| t.id != task.id);
                        }
                    }
                    failure = Some(e);
                }
            }
        } // ← 全部锁在此释放
        if let Some(e) = failure {
            *self.last_error.write() = Some(e.clone());
            self.emit_persist_error(Some(task.id), &e);
            return Err(format!("{}；任务未启动", e));
        }
        // 持久化成功后才发布事件（R2）
        self.emit(&task);
        Ok(())
    }

    /// 入队并开始下载（内部完成音源 URL 之后的 HTTP 下载环节）。
    #[allow(clippy::too_many_arguments)]
    pub fn enqueue(
        self: &Arc<Self>,
        id: i64,
        name: &str,
        artist: &str,
        album: &str,
        duration_ms: i64,
        url: &str,
        dir: &Path,
        source: Option<String>,
        targets: Vec<String>,
    ) -> Result<String, String> {
        std::fs::create_dir_all(dir)
            .map_err(|e| format!("创建下载目录失败（{}）：{}", dir.display(), e))?;
        if self.shutdown.load(std::sync::atomic::Ordering::SeqCst) {
            return Err("下载队列正在关闭，不再接受新任务".into());
        }
        // 本进程内同 ID 只允许一个在途下载（重启后的 queued 记录不在此列，
        // 必须可以重新入队恢复——R2 / R3）。
        //
        // 这里用 **在途集合** 判断「真的在下载」，而不是持久状态：
        // 持久状态是 `running` 但下载其实已结束（完成后的落盘失败）时，
        // 必须允许重试走 intent 恢复（审查 E0-8）。
        {
            let mut active = self.active.lock();
            if !active.insert(id) {
                return Err("该歌曲正在下载中".into());
            }
        }
        let spawned = (|| -> Result<(), String> {
            let task = DlTask {
                id,
                name: name.to_string(),
                artist: artist.to_string(),
                album: album.to_string(),
                duration_ms,
                path: String::new(),
                downloaded: 0,
                total: 0,
                status: STATUS_QUEUED.into(),
                error: None,
                source,
                created_at: crate::now_millis(),
                updated_at: crate::now_millis(),
                targets,
                digest: String::new(),
            };
            self.reserve(task)?;
            let queue = Arc::clone(self);
            let dir = dir.to_path_buf();
            let url = url.to_string();
            let name = name.to_string();
            let artist = artist.to_string();
            // 独立 tokio 任务执行；结果通过 mutate 写回并持久化
            tokio::spawn(async move {
                queue.run(id, &name, &artist, &url, &dir).await;
            });
            Ok(())
        })();
        if spawned.is_err() {
            self.active.lock().remove(&id);
        }
        spawned.map(|_| "queued".to_string())
    }

    async fn run(self: Arc<Self>, id: i64, name: &str, artist: &str, url: &str, dir: &Path) {
        // 本进程在途标记：任务结束（成功/失败/取消）时释放，允许再次入队。
        struct ActiveGuard {
            queue: Arc<DlQueue>,
            id: i64,
        }
        impl Drop for ActiveGuard {
            fn drop(&mut self) {
                self.queue.active.lock().remove(&self.id);
            }
        }
        let _active = ActiveGuard {
            queue: Arc::clone(&self),
            id,
        };

        // 关闭收束：已请求关闭则直接暂停（持久化可恢复状态后退出）
        if self.shutdown.load(std::sync::atomic::Ordering::SeqCst) {
            self.pause_for_shutdown(id, None);
            return;
        }

        self.mutate(id, |t| t.status = STATUS_RUNNING.into());

        // 按 **已持久记录的 intent（最终路径 + 大小 + 内容摘要）** 恢复
        // （E0 audit：不猜文件名）：
        // 上次在「finalize 落位后、done 落盘前」中断时，path 已在发布前
        // 持久记录且文件已落位 → 校验大小 **与内容摘要** 一致后直接完成，
        // 重启不重下、不产生副本。
        if let Some(t) = self.task(id) {
            if t.status != STATUS_DONE && !t.path.is_empty() {
                let expect = if t.total > 0 { t.total } else { t.downloaded };
                let placed_ok = expect > 0
                    && std::fs::metadata(&t.path)
                        .map(|m| m.len() == expect)
                        .unwrap_or(false);
                if !placed_ok {
                    // 记录了路径但文件缺失（上次在 finalize 前中断）：
                    // 清掉过期 intent 后正常重新下载。
                    self.mutate(id, |tt| {
                        tt.path.clear();
                        tt.digest.clear();
                    });
                } else if t.digest.is_empty() {
                    // **旧记录没有内容摘要**（升级前写入）→ 无法证明「路径上
                    // 的文件就是本次下载的那份」：同大小不等于同一份文件。
                    // 因此 **不得自动认 done**（审查 E1-6 兼容限制）：
                    // 显式标注待处理并重新下载（原文件保留，不删除）。
                    self.mutate(id, |tt| {
                        tt.path.clear();
                        tt.digest.clear();
                        tt.error = Some(
                            "该记录来自升级前（无内容摘要），无法确认已落位文件是否为本次下载；\
                             已重新排队，重新下载可能产生副本（原文件保留）"
                                .into(),
                        );
                    });
                } else {
                    // 摘要证据（审查 E1-6）：同大小不等于同一份文件。
                    let digest_ok = file_digest(Path::new(&t.path))
                        .map(|d| d == t.digest)
                        .unwrap_or(false);
                    if digest_ok {
                        self.mutate(id, |tt| {
                            tt.status = STATUS_DONE.into();
                            tt.error = None;
                            tt.downloaded = expect;
                            tt.total = expect;
                        });
                        return;
                    }
                    // 摘要不符 → 路径上的是无关文件：清掉 intent 后重新下载
                    // （绝不删除用户文件）。
                    self.mutate(id, |tt| {
                        tt.path.clear();
                        tt.digest.clear();
                    });
                }
            }
        }

        let tmp = dir.join(format!(".alger-dl-{}.part", id));

        // HTTP 请求必须能被关闭立即取消（审查 E1-2）：响应头迟迟不来时，
        // 仅靠块边界检查收束不了（client 总超时 1800s）。
        let resp = {
            let notified = self.shutdown_notify.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            if self.shutdown.load(std::sync::atomic::Ordering::SeqCst) {
                return self.pause_for_shutdown(id, None);
            }
            tokio::select! {
                r = self.http.get(url).send() => r,
                _ = notified => {
                    return self.pause_for_shutdown(id, None);
                }
            }
        };
        let resp = match resp {
            Ok(r) => r,
            Err(e) => {
                return self.fail(id, format!("下载请求失败：{}", e), None);
            }
        };
        let status = resp.status();
        if !status.is_success() {
            return self.fail(id, format!("下载失败：HTTP {}", status.as_u16()), None);
        }
        let content_type = resp
            .headers()
            .get("content-type")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
            .to_ascii_lowercase();
        let total = resp.content_length().unwrap_or(0);
        self.mutate(id, |t| {
            t.status = STATUS_RUNNING.into();
            t.total = total;
        });

        let mut extension = guess_extension(&content_type, url);
        let mut file = match tokio::fs::File::create(&tmp).await {
            Ok(f) => f,
            Err(e) => return self.fail(id, format!("写入临时文件失败：{}", e), None),
        };

        use futures_util::StreamExt;
        let stream = resp.bytes_stream();
        let mut downloaded: u64 = 0;
        let mut last_emit = std::time::Instant::now();
        let mut head: Vec<u8> = Vec::new();
        futures_util::pin_mut!(stream);
        loop {
            // 关闭收束：块边界响应取消（最长约 100ms 粒度）
            if self.shutdown.load(std::sync::atomic::Ordering::SeqCst) {
                return self.pause_for_shutdown(id, Some(&tmp));
            }
            let chunk = tokio::select! {
                c = stream.next() => c,
                _ = tokio::time::sleep(std::time::Duration::from_millis(100)) => continue,
            };
            let chunk = match chunk {
                Some(Ok(c)) => c,
                Some(Err(e)) => {
                    return self.fail(id, format!("下载中断：{}", e), Some(&tmp));
                }
                None => break,
            };
            if head.len() < 16 {
                let need = 16 - head.len();
                head.extend_from_slice(&chunk[..chunk.len().min(need)]);
                if let Some(detected) = detect_extension(&head) {
                    extension = detected.to_string();
                }
            }
            if let Err(e) = file.write_all(&chunk).await {
                return self.fail(id, format!("写入文件失败：{}", e), Some(&tmp));
            }
            downloaded += chunk.len() as u64;
            if last_emit.elapsed() >= std::time::Duration::from_millis(400) {
                last_emit = std::time::Instant::now();
                self.mutate(id, |t| {
                    t.downloaded = downloaded;
                    t.total = total;
                });
            }
        }
        if let Err(e) = file.flush().await {
            return self.fail(id, format!("写入文件失败：{}", e), Some(&tmp));
        }
        drop(file);

        if downloaded == 0 {
            return self.fail(id, "下载内容为空".into(), Some(&tmp));
        }
        // 完整性：声明长度与实际收到不一致即失败（截断保护，审查 P1-5）
        if total > 0 && downloaded != total {
            return self.fail(
                id,
                format!(
                    "下载不完整：实际收到 {} 字节，声明 {} 字节",
                    downloaded, total
                ),
                Some(&tmp),
            );
        }
        if let Ok(m) = std::fs::metadata(&tmp) {
            if m.len() != downloaded {
                return self.fail(
                    id,
                    format!("落盘文件大小 {} 与实际收到 {} 不一致", m.len(), downloaded),
                    Some(&tmp),
                );
            }
        }
        if crate::sources::looks_like_document(&head) {
            return self.fail(id, "下载到的不是音频（返回了网页/JSON）".into(), Some(&tmp));
        }

        // 内容摘要（审查 E1-6）：与 path + 大小一起构成「这份文件确实是
        // 我们落位的那份」的凭据；崩溃恢复时据此拒绝同大小的无关文件。
        let digest = match file_digest(&tmp) {
            Ok(d) => d,
            Err(e) => {
                return self.fail(id, format!("计算下载内容摘要失败：{}", e), Some(&tmp));
            }
        };

        let final_name = sanitize_filename(name, artist, &extension);
        // E0 audit：发布（finalize 落位）**之前** 先持久记录准确 final path
        // 与完整大小 intent（含 chunked total=0 情形：以实际收到的字节数为准）。
        // 此后即使 done 保存失败，重启也按该 intent 恢复，绝不靠猜测文件名。
        // 记录落盘失败则不落位、不发布，失败对 UI 可见。
        let planned = unique_path(dir, &final_name);
        if self
            .mutate(id, |t| {
                t.path = planned.to_string_lossy().to_string();
                t.downloaded = downloaded;
                t.total = if total > 0 { total } else { downloaded };
                t.digest = digest.clone();
            })
            .is_none()
        {
            let _ = std::fs::remove_file(&tmp);
            return;
        }
        // 落位必须发生在 **准确的 planned path**（无覆盖）；并发冲突时先
        // 持久化新 intent 再落位，任何一步失败都中止且原文件/记录不动。
        let final_target = match self.finalize_at_planned(id, &tmp, dir, &planned) {
            Ok(p) => p,
            Err(e) => return self.fail(id, e, Some(&tmp)),
        };

        // done：mutate 内部先落盘成功后才会发 done 事件（R2）
        self.mutate(id, |t| {
            t.downloaded = downloaded;
            t.total = if total > 0 { total } else { downloaded };
            t.status = STATUS_DONE.into();
            t.error = None;
            t.path = final_target.to_string_lossy().to_string();
            t.digest = digest.clone();
        });
    }

    /// 落位必须发生在 **准确的 planned path**（不覆盖已有文件）。
    ///
    /// 只使用 hard_link 作为 no-replace 原语：链接在目标已存在时以
    /// `AlreadyExists` 原子失败，**绝不覆盖检查后新建的文件**（POSIX
    /// rename 兜底会静默覆盖，已删除）。hard_link 不可用（跨卷 / 文件
    /// 系统不支持）时明确报错，不落位。
    /// 并发冲突（落位前他人占用了 planned path）→ 另选候选名，
    /// **先持久化新 intent**（`mutate`，失败即中止、不落位），再落位，
    /// 循环直到成功——路径记录与实际落位永不分叉。
    fn finalize_at_planned(
        &self,
        id: i64,
        tmp: &Path,
        dir: &Path,
        planned: &Path,
    ) -> Result<PathBuf, String> {
        let filename = planned
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .ok_or_else(|| "落位路径缺少文件名".to_string())?;
        let mut candidate = planned.to_path_buf();
        loop {
            let placed = match std::fs::hard_link(tmp, &candidate) {
                Ok(()) => true,
                // no-replace：目标已存在（含落位检查后被他人新建的），
                // 一律换名，不重试覆盖
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => false,
                Err(e) => {
                    return Err(format!(
                        "保存文件失败（无法在不覆盖既有文件的前提下落位 {}）：{}",
                        candidate.display(),
                        e
                    ));
                }
            };
            if placed {
                let _ = std::fs::remove_file(tmp);
                return Ok(candidate);
            }
            // 冲突：换名 + 先持久新 intent，再尝试落位
            let next = unique_path(dir, &filename);
            if next == candidate {
                return Err("目标目录中同名文件过多".into());
            }
            if self
                .mutate(id, |t| t.path = next.to_string_lossy().to_string())
                .is_none()
            {
                return Err("落位路径冲突且新 intent 保存失败，已取消本次落位".into());
            }
            candidate = next;
        }
    }

    fn fail(&self, id: i64, message: String, tmp: Option<&Path>) {
        if let Some(path) = tmp {
            let _ = std::fs::remove_file(path);
        }
        self.mutate(id, |t| {
            t.status = STATUS_FAILED.into();
            t.error = Some(message);
            t.downloaded = 0;
        });
    }

    /// 进程关闭收束：下载在块边界暂停——清理临时文件，把任务持久化为
    /// `queued` + 可重试错误（targets 原样保留），事件经 sink 发出。
    /// 下次启动按既有恢复语义重新入队即可继续。
    fn pause_for_shutdown(&self, id: i64, tmp: Option<&Path>) {
        if let Some(path) = tmp {
            let _ = std::fs::remove_file(path);
        }
        self.mutate(id, |t| {
            t.status = STATUS_QUEUED.into();
            t.error = Some("应用退出，下载已暂停，可重试".into());
        });
    }

    /// 请求关闭并 **有界** 等待在途下载暂停（每个下载在下一个块边界
    /// 自行持久化可恢复状态）。返回截止时间后仍在途的数量（理论上
    /// 应为 0；非 0 时这些任务在进程退出后由重启恢复语义兜底）。
    pub fn begin_shutdown(&self, wait: std::time::Duration) -> usize {
        self.shutdown
            .store(true, std::sync::atomic::Ordering::SeqCst);
        // 立即唤醒在途请求：卡在 HTTP 响应头的下载据此立刻取消
        // （审查 E1-2），不必等 1800s 的 client 超时。
        self.shutdown_notify.notify_waiters();
        let deadline = std::time::Instant::now() + wait;
        loop {
            let remaining = self.active.lock().len();
            if remaining == 0 {
                return 0;
            }
            if std::time::Instant::now() >= deadline {
                return remaining;
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
    }

    /// 重试失败 / 排队任务：由桥接层先重新解析地址再调用 [`Self::enqueue`]。
    pub fn task(&self, id: i64) -> Option<DlTask> {
        self.state.lock().tasks.iter().find(|t| t.id == id).cloned()
    }

    /// 清除任务（`done` / 全部）。音频文件不动。
    ///
    /// `only_done = false` 时 **仍在本进程运行的下载不被清除**（记录保留，
    /// 否则下载完成后文件落位却无任何记录，成为孤儿）。
    ///
    /// 锁序（审查 E0-9）：`txn → flock → state → active`——必须 **先取状态锁、
    /// 再快照 active**；否则 clear 可能拿到空快照，而此刻入队的任务正在
    /// 下载 → 记录被删 → 落位后成孤儿（无 path / targets）。
    ///
    /// 落盘失败返回错误并 **回滚内存**（R4：clear 失败后内存不得已清空），
    /// 不静默吞掉。
    pub fn clear(&self, only_done: bool) -> Result<(), String> {
        let mut failure: Option<String> = None;
        {
            let _txn = self.txn.lock();
            match FileLockGuard::acquire(self, self.lock_wait) {
                Ok(_flock) => {
                    let mut guard = self.state.lock();
                    let active_ids = self.active.lock().clone();
                    let backup = guard.tasks.clone();
                    if only_done {
                        guard.tasks.retain(|t| t.status != STATUS_DONE);
                    } else {
                        guard.tasks.retain(|t| active_ids.contains(&t.id));
                    }
                    if let Err(e) = self.write_state_locked(&guard) {
                        // 整表还原：顺序与内容都不变（审查 E1-10）
                        guard.tasks = backup;
                        failure = Some(e);
                    }
                }
                Err(e) => failure = Some(e),
            }
        } // ← 全部锁在此释放
        match failure {
            None => Ok(()),
            Some(e) => {
                *self.last_error.write() = Some(e.clone());
                // 先释放全部锁再回调用户 sink（审查 E1-10）
                self.emit_persist_error(None, &e);
                Err(e)
            }
        }
    }

    /// 本地 intent 恢复：若记录里的「路径 + 大小 + 内容摘要」与磁盘上的
    /// 文件完全一致，直接把任务标为 done（先落盘、后发事件），**不需要网络**。
    ///
    /// 返回 `Ok(true)` = 已就地恢复；`Ok(false)` = 无法确认（缺摘要 / 文件
    /// 不匹配 / 落盘失败），调用方应走「重新解析地址并下载」的路径。
    ///
    /// 用途（审查 E0-8 / 桥接 dl.retry）：**先本地恢复、再解析新地址**——
    /// 否则离线或音源解析失败时，即使文件早已落位也无法恢复。
    pub fn try_complete_from_intent(&self, id: i64) -> Result<bool, String> {
        let task = match self.task(id) {
            Some(t) => t,
            None => return Ok(false),
        };
        if task.status == STATUS_DONE {
            return Ok(true);
        }
        // 无摘要的旧记录 **无法证明同一性** → 不就地认 done（兼容限制）
        if task.path.is_empty() || task.digest.is_empty() {
            return Ok(false);
        }
        let expect = if task.total > 0 {
            task.total
        } else {
            task.downloaded
        };
        if expect == 0 {
            return Ok(false);
        }
        let placed_ok = std::fs::metadata(&task.path)
            .map(|m| m.len() == expect)
            .unwrap_or(false);
        if !placed_ok {
            return Ok(false);
        }
        let digest_ok = file_digest(Path::new(&task.path))
            .map(|d| d == task.digest)
            .unwrap_or(false);
        if !digest_ok {
            return Ok(false);
        }
        // 落盘为 done（失败时 mutate 已精确回滚并发出 persistError）
        Ok(self
            .mutate(id, |t| {
                t.status = STATUS_DONE.into();
                t.error = None;
                t.downloaded = expect;
                t.total = expect;
            })
            .is_some())
    }

    /// 标记任务失败（例如解析失败：URL 拿不到）。
    pub fn mark_failed(&self, id: i64, message: String) {
        self.fail(id, message, None);
    }
}

/// 文件内容摘要（FNV-1a 64 位，十六进制）。
///
/// 用于确认「同一路径上的文件」确实是我们落位的那一份：只比大小的话，
/// 同大小的无关文件会被误认成已完成（审查 E1-6）。
fn file_digest(path: &Path) -> Result<String, String> {
    use std::io::Read;
    let mut f = std::fs::File::open(path)
        .map_err(|e| format!("读取摘要失败（{}）：{}", path.display(), e))?;
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    let mut buf = vec![0u8; 64 * 1024];
    loop {
        let n = f
            .read(&mut buf)
            .map_err(|e| format!("读取摘要失败（{}）：{}", path.display(), e))?;
        if n == 0 {
            break;
        }
        for b in &buf[..n] {
            h ^= *b as u64;
            h = h.wrapping_mul(0x100_0000_01b3);
        }
    }
    Ok(format!("{:016x}", h))
}

/// 打开队列锁文件：**绝不截断**既有目标，绝不跟随符号链接（审查 E0-10）。
///
/// 锁文件内容毫无用途；用 `truncate(true)` 打开只会带来「符号链接指向的
/// 任意文件被截断」的风险，因此改为 `truncate(false)` + `O_NOFOLLOW`
/// + 普通文件校验。
fn open_lock_file(path: &Path) -> std::io::Result<std::fs::File> {
    #[cfg(unix)]
    let file = {
        use std::os::unix::fs::OpenOptionsExt;
        std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .custom_flags(libc::O_NOFOLLOW)
            .open(path)?
    };
    #[cfg(not(unix))]
    let file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(path)?;
    let meta = file.metadata()?;
    if !meta.is_file() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            format!("下载队列锁文件 {} 不是普通文件", path.display()),
        ));
    }
    Ok(file)
}

#[cfg(unix)]
impl DlQueue {
    /// 跨进程排他锁（**有界**等待：审查 E1-5）。
    ///
    /// 用 `LOCK_EX | LOCK_NB` + 轮询，超时即报错——绝不无限阻塞（另一个
    /// 实例卡死时本进程不会跟着挂死）。
    ///
    /// 语义约定（**必须**遵守，否则会出现「实际文件锁被提前释放」）：
    /// - flock 按 **打开文件描述** 生效：同进程第二个线程用同一个 fd 再加锁
    ///   会 *假成功*。因此进程内互斥由 [`Self::txn`] 保证——只有拿到
    ///   `txn` 的线程才会走到这里，**任一时刻只有一个线程持有跨进程锁**；
    /// - 加锁 / 解锁严格 1:1 配对（由 [`FileLockGuard`] 的 Drop 保证），
    ///   不存在嵌套，也不需要计数器。
    fn flock_lock(&self, wait: std::time::Duration) -> Result<(), String> {
        use std::os::unix::io::AsRawFd;
        let deadline = std::time::Instant::now() + wait;
        loop {
            let rc =
                unsafe { libc::flock(self.lock_file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
            if rc == 0 {
                return Ok(());
            }
            let err = std::io::Error::last_os_error();
            if err.kind() != std::io::ErrorKind::WouldBlock {
                return Err(format!("下载队列文件锁获取失败：{}", err));
            }
            if std::time::Instant::now() >= deadline {
                return Err(format!(
                    "下载队列文件锁获取超时（等待 {:?}）：另一个实例正在写队列，请稍后重试",
                    wait
                ));
            }
            // 轮询间隙不持有任何锁（进程内 txn 由调用方持有，见 with_txn）
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
    }

    fn flock_unlock(&self) {
        use std::os::unix::io::AsRawFd;
        unsafe {
            let _ = libc::flock(self.lock_file.as_raw_fd(), libc::LOCK_UN);
        }
    }
}

/// 跨进程文件锁守卫：Drop 时自动 `LOCK_UN`。
///
/// 异常 / 提前返回路径也不会漏解锁；与 `flock_lock` 严格配对。
struct FileLockGuard<'a> {
    queue: &'a DlQueue,
}

impl<'a> FileLockGuard<'a> {
    fn acquire(queue: &'a DlQueue, wait: std::time::Duration) -> Result<Self, String> {
        queue.flock_lock(wait)?;
        Ok(FileLockGuard { queue })
    }
}

impl Drop for FileLockGuard<'_> {
    fn drop(&mut self) {
        self.queue.flock_unlock();
    }
}

#[cfg(not(unix))]
impl DlQueue {
    // 非 Unix 暂无等效互斥原语：退化为进程内串行（单实例桌面端成立，
    // 多实例共用一个队列目录时不提供跨进程保护，写入前仍会检测外部修改）。
    fn flock_lock(&self, _wait: std::time::Duration) -> Result<(), String> {
        Ok(())
    }

    fn flock_unlock(&self) {}
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_dir(name: &str) -> PathBuf {
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../.artifacts/fixtures")
            .join(name);
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn noop_sink() -> EventSink {
        Arc::new(|_| {})
    }

    /// 故障注入用：把目录临时改成 **只读**（制造落盘失败），
    /// 离开作用域时 **自动恢复写权限**。
    ///
    /// 为什么必须 RAII：
    /// - 手写的 `set_permissions` 还原语句一旦被断言 panic 跳过，
    ///   目录就会永久留在 `0o500`，后续 `remove_dir_all` 失败，
    ///   整个测试目录清理不掉（上一轮 `clean.sh` 就因此失败）；
    /// - 还原时必须保证 **属主可写**（`0o700`），
    ///   否则目录仍然无法删除。
    struct ReadOnlyDir {
        path: std::path::PathBuf,
    }

    impl ReadOnlyDir {
        fn enter(path: &std::path::Path) -> Self {
            use std::os::unix::fs::PermissionsExt;
            let mut perm = std::fs::metadata(path).unwrap().permissions();
            perm.set_mode(0o500);
            std::fs::set_permissions(path, perm).unwrap();
            Self {
                path: path.to_path_buf(),
            }
        }
    }

    impl Drop for ReadOnlyDir {
        fn drop(&mut self) {
            use std::os::unix::fs::PermissionsExt;
            // 恢复成属主可写：目录必须可写才能被删除。
            let mut perm = std::fs::metadata(&self.path)
                .map(|m| m.permissions())
                .unwrap_or_else(|_| {
                    let mut p = std::fs::Permissions::from_mode(0o700);
                    p.set_mode(0o700);
                    p
                });
            perm.set_mode(0o700);
            let _ = std::fs::set_permissions(&self.path, perm);
        }
    }

    /// 重启恢复：running → queued，保留可重试语义。
    #[test]
    fn running_tasks_recover_to_queued_on_restart() {
        let dir = test_dir(format!("dlq-{}", std::process::id()).as_str());
        let path = dir.join("downloads.json");
        let state = DlState {
            tasks: vec![DlTask {
                id: 1,
                name: "test".into(),
                artist: "a".into(),
                album: String::new(),
                duration_ms: 0,
                path: String::new(),
                downloaded: 100,
                total: 200,
                status: STATUS_RUNNING.into(),
                error: None,
                source: None,
                created_at: 1,
                updated_at: 1,
                targets: vec!["morning".into(), "netease:99".into()],
                digest: String::new(),
            }],
        };
        std::fs::write(&path, serde_json::to_string(&state).unwrap()).unwrap();
        let q = DlQueue::open(&dir, noop_sink()).unwrap();
        let list = q.list();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].status, STATUS_QUEUED);
        assert!(list[0].error.as_deref().unwrap().contains("重启"));
        // 持久化文件已被更新
        let raw: DlState = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(raw.tasks[0].status, STATUS_QUEUED);
        std::fs::remove_dir_all(&dir).ok();
    }

    /// done / failed 状态重启后原样保留。
    #[test]
    fn finished_tasks_survive_restart() {
        let dir = test_dir(format!("dlq2-{}", std::process::id()).as_str());
        let path = dir.join("downloads.json");
        let state = DlState {
            tasks: vec![
                DlTask {
                    id: 1,
                    name: "a".into(),
                    artist: "x".into(),
                    album: String::new(),
                    duration_ms: 0,
                    path: "/tmp/a.mp3".into(),
                    downloaded: 1,
                    total: 1,
                    status: STATUS_DONE.into(),
                    error: None,
                    source: None,
                    created_at: 1,
                    updated_at: 1,
                    targets: Vec::new(),
                    digest: String::new(),
                },
                DlTask {
                    id: 2,
                    name: "b".into(),
                    artist: "y".into(),
                    album: String::new(),
                    duration_ms: 0,
                    path: String::new(),
                    downloaded: 0,
                    total: 0,
                    status: STATUS_FAILED.into(),
                    error: Some("网络".into()),
                    source: None,
                    created_at: 1,
                    updated_at: 1,
                    targets: vec!["quiet".into()],
                    digest: String::new(),
                },
            ],
        };
        std::fs::write(&path, serde_json::to_string(&state).unwrap()).unwrap();
        let q = DlQueue::open(&dir, noop_sink()).unwrap();
        let list = q.list();
        assert_eq!(list[0].status, STATUS_DONE);
        assert_eq!(list[1].status, STATUS_FAILED);
        assert_eq!(list[1].error.as_deref(), Some("网络"));
        std::fs::remove_dir_all(&dir).ok();
    }

    /// F3：带目标歌单的任务跨重启恢复（queued 状态 + targets 原样保留）。
    #[test]
    fn targets_survive_restart() {
        let dir = test_dir(format!("dlq-targets-{}", std::process::id()).as_str());
        let path = dir.join("downloads.json");
        let state = DlState {
            tasks: vec![DlTask {
                id: 42,
                name: "晴天".into(),
                artist: "周杰伦".into(),
                album: "叶惠美".into(),
                duration_ms: 269_000,
                path: String::new(),
                downloaded: 0,
                total: 0,
                status: STATUS_RUNNING.into(),
                error: None,
                source: None,
                created_at: 1,
                updated_at: 1,
                targets: vec!["慢慢醒来".into(), "netease:123456".into()],
                digest: String::new(),
            }],
        };
        std::fs::write(&path, serde_json::to_string(&state).unwrap()).unwrap();
        let q = DlQueue::open(&dir, noop_sink()).unwrap();
        let list = q.list();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].status, STATUS_QUEUED);
        assert_eq!(
            list[0].targets,
            vec!["慢慢醒来".to_string(), "netease:123456".to_string()],
            "目标歌单必须跨重启保留"
        );
        assert!(q.load_issue().is_none());
        std::fs::remove_dir_all(&dir).ok();
    }

    /// F3：downloads.json 损坏时备份 + 上报 + 拒绝写入，不静默清空。
    #[test]
    fn corrupt_queue_file_is_preserved_and_reported() {
        let dir = test_dir(format!("dlq-corrupt-{}", std::process::id()).as_str());
        let path = dir.join("downloads.json");
        let raw = r#"{"tasks":[{"id":1,"name":"broken""#;
        std::fs::write(&path, raw).unwrap();
        let q = DlQueue::open(&dir, noop_sink()).unwrap();
        let issue = q.load_issue();
        assert!(issue.is_some(), "解析失败必须上报 load_issue");
        assert!(issue.as_deref().unwrap().contains("拒绝写入"));
        // 原文件字节不变
        assert_eq!(std::fs::read(&path).unwrap(), raw.as_bytes());
        // 备份存在
        let found = std::fs::read_dir(&dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .any(|e| {
                e.file_name()
                    .to_string_lossy()
                    .starts_with("downloads.json.corrupt-")
            });
        assert!(found, "应生成 corrupt 备份文件");
        // 写入被拒绝：任务列表修改不会覆盖原文件
        assert!(q.clear(true).is_err(), "load_issue 存在时 clear 必须报错");
        assert_eq!(std::fs::read(&path).unwrap(), raw.as_bytes());
        assert!(q.last_error().is_some() || q.load_issue().is_some());
        std::fs::remove_dir_all(&dir).ok();
    }

    /// 空 downloads.json 按损坏处理：保留、上报、拒绝写入（仅 NotFound 首次运行）。
    #[test]
    fn empty_queue_file_is_preserved_and_reported() {
        let dir = test_dir(format!("dlq-empty-{}", std::process::id()).as_str());
        let path = dir.join("downloads.json");
        std::fs::write(&path, b"").unwrap();
        let q = DlQueue::open(&dir, noop_sink()).unwrap();
        let issue = q.load_issue();
        assert!(issue.is_some(), "空文件必须上报 load_issue");
        assert!(issue.as_deref().unwrap().contains("空文件"));
        assert_eq!(std::fs::read(&path).unwrap(), b"");
        assert!(q.clear(false).is_err(), "空文件状态下写入必须被拒绝");
        assert_eq!(std::fs::read(&path).unwrap(), b"", "原空文件必须保持不动");
        std::fs::remove_dir_all(&dir).ok();
    }

    /// P0-4：同 id 二次入队，targets 取并集且旧值在前。
    #[test]
    fn reenqueue_unions_targets() {
        let dir = test_dir(format!("dlq-union-{}", std::process::id()).as_str());
        let q = DlQueue::open(&dir, noop_sink()).unwrap();
        let task = |targets: Vec<&str>| DlTask {
            id: 7,
            name: "t".into(),
            artist: "a".into(),
            album: String::new(),
            duration_ms: 0,
            path: String::new(),
            downloaded: 0,
            total: 0,
            status: STATUS_FAILED.into(),
            error: None,
            source: None,
            created_at: 1,
            updated_at: 1,
            targets: targets.into_iter().map(str::to_string).collect(),
            digest: String::new(),
        };
        q.reserve(task(vec!["歌单A", "netease:1"])).unwrap();
        // 第一个任务标记失败后带新目标重入
        q.reserve(task(vec!["歌单B", "歌单A"])).unwrap();
        let t = q.task(7).unwrap();
        assert_eq!(
            t.targets,
            vec![
                "歌单A".to_string(),
                "netease:1".to_string(),
                "歌单B".to_string()
            ],
            "targets 必须为并集且旧值在前"
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    /// P0-3：落盘失败（load_issue / 只读目录）时 reserve 上抛且不保留内存登记。
    #[cfg(unix)]
    #[test]
    fn reserve_fails_when_persist_refused() {
        let dir = test_dir(format!("dlq-ro-{}", std::process::id()).as_str());
        let q = DlQueue::open(&dir, noop_sink()).unwrap();
        // 目录只读 → persist 失败
        let _read_only = ReadOnlyDir::enter(&dir);
        let err = q
            .reserve(DlTask {
                id: 9,
                name: "t".into(),
                artist: "a".into(),
                album: String::new(),
                duration_ms: 0,
                path: String::new(),
                downloaded: 0,
                total: 0,
                status: STATUS_QUEUED.into(),
                error: None,
                source: None,
                created_at: 1,
                updated_at: 1,
                targets: vec!["歌单A".into()],
                digest: String::new(),
            })
            .expect_err("落盘失败时 reserve 必须上抛");
        assert!(err.contains("任务未启动"), "错误需说明任务未启动：{}", err);
        assert!(q.task(9).is_none(), "失败的登记必须回滚，不得留在内存");
        drop(_read_only);
        std::fs::remove_dir_all(&dir).expect("权限故障夹具应可清理");
    }

    /// 清除已完成不影响待处理任务。
    #[test]
    fn clear_keeps_pending_tasks() {
        let dir = test_dir(format!("dlq3-{}", std::process::id()).as_str());
        let q = DlQueue::open(&dir, noop_sink()).unwrap();
        q.mutate_all(vec![
            (1, STATUS_DONE),
            (2, STATUS_FAILED),
            (3, STATUS_QUEUED),
        ]);
        q.clear(true).unwrap();
        let list = q.list();
        assert_eq!(list.len(), 2);
        std::fs::remove_dir_all(&dir).ok();
    }

    impl DlQueue {
        /// 测试辅助：直接替换任务列表。
        fn mutate_all(&self, items: Vec<(i64, &str)>) {
            let now = crate::now_millis();
            let mut guard = self.state.lock();
            guard.tasks = items
                .into_iter()
                .map(|(id, status)| DlTask {
                    id,
                    name: format!("t{}", id),
                    artist: "a".into(),
                    album: String::new(),
                    duration_ms: 0,
                    path: String::new(),
                    downloaded: 0,
                    total: 0,
                    status: status.into(),
                    error: None,
                    source: None,
                    created_at: now,
                    updated_at: now,
                    targets: Vec::new(),
                    digest: String::new(),
                })
                .collect();
            drop(guard);
            let _ = self.persist();
        }
    }

    fn task_stub(id: i64, status: &str, targets: Vec<&str>) -> DlTask {
        DlTask {
            id,
            name: "t".into(),
            artist: "a".into(),
            album: String::new(),
            duration_ms: 0,
            path: String::new(),
            downloaded: 0,
            total: 0,
            status: status.into(),
            error: None,
            source: None,
            created_at: 1,
            updated_at: 1,
            targets: targets.into_iter().map(str::to_string).collect(),
            digest: String::new(),
        }
    }

    fn collecting_sink() -> (EventSink, Arc<std::sync::Mutex<Vec<serde_json::Value>>>) {
        let events = Arc::new(std::sync::Mutex::new(Vec::new()));
        let out = Arc::clone(&events);
        (Arc::new(move |v| out.lock().unwrap().push(v)), events)
    }

    /// 本地计数 HTTP 服务器：返回 `body`，每次连接计数 +1。
    /// 返回 (port, hits)。
    fn counting_server(body: &'static [u8]) -> (u16, Arc<std::sync::atomic::AtomicUsize>) {
        use std::sync::atomic::{AtomicUsize, Ordering};
        use std::sync::Arc as StdArc;
        let hits = StdArc::new(AtomicUsize::new(0));
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let h2 = StdArc::clone(&hits);
        std::thread::spawn(move || {
            use std::io::{Read, Write};
            for stream in listener.incoming() {
                h2.fetch_add(1, Ordering::SeqCst);
                let mut s = stream.unwrap();
                let mut buf = [0u8; 1024];
                let _ = s.read(&mut buf);
                let head =
                    "HTTP/1.1 200 OK\r\ncontent-type: audio/mpeg\r\nconnection: close\r\n\r\n";
                let _ = s.write_all(head.as_bytes());
                let _ = s.write_all(body);
            }
        });
        (port, hits)
    }

    fn wait_status(q: &Arc<DlQueue>, id: i64, want: &str) -> DlTask {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        loop {
            if let Some(t) = q.task(id) {
                if t.status == want {
                    return t;
                }
            }
            assert!(std::time::Instant::now() < deadline, "等待 {} 超时", want);
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
    }

    /// 有界确定性等待：条件出现即返回 true，超时返回 false。
    /// 只用短轮询同步时序，不依赖长 sleep（E0-8 故障测试的等待原语）。
    fn wait_for(cond: impl Fn() -> bool) -> bool {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while !cond() {
            if std::time::Instant::now() >= deadline {
                return false;
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        true
    }

    /// R2：落盘失败时不得发出假 done 事件；失败对 UI 可见（persistError）；
    /// 内存精确回滚（不留假 path）。
    #[cfg(unix)]
    #[test]
    fn no_fake_done_event_when_persist_fails() {
        let dir = test_dir(format!("dlq-nofake-{}", std::process::id()).as_str());
        let (sink, events) = collecting_sink();
        let q = DlQueue::open(&dir, sink).unwrap();
        q.reserve(task_stub(1, STATUS_QUEUED, vec![])).unwrap();

        let _read_only = ReadOnlyDir::enter(&dir);
        let r = q.mutate(1, |t| {
            t.status = STATUS_DONE.into();
            t.path = "/x/fake.mp3".into();
        });

        assert!(r.is_none(), "落盘失败的 mutate 必须返回 None");
        let evs = events.lock().unwrap();
        assert!(
            !evs.iter().any(|e| e["p"]["status"] == STATUS_DONE),
            "绝不允许假 done 事件：{:?}",
            *evs
        );
        assert!(
            evs.iter().any(|e| e["ev"] == "dl.persistError"),
            "落盘失败必须发 persistError 事件：{:?}",
            *evs
        );
        drop(evs);
        let t = q.task(1).expect("任务必须仍在");
        assert_ne!(t.status, STATUS_DONE, "内存不得保留假 done");
        assert!(t.path.is_empty(), "内存不得保留假 path");
        drop(_read_only);
        std::fs::remove_dir_all(&dir).expect("权限故障夹具应可清理");
    }

    /// R4：reserve 落盘失败后按原位恢复 **旧记录**（旧 done 的 path / targets
    /// 不得丢失，也不得被未提交的合并污染）。
    #[cfg(unix)]
    #[test]
    fn reserve_failure_restores_exact_old_record() {
        let dir = test_dir(format!("dlq-rb-{}", std::process::id()).as_str());
        let path = dir.join("downloads.json");
        let old = DlTask {
            id: 5,
            name: "old".into(),
            artist: "a".into(),
            album: String::new(),
            duration_ms: 0,
            path: "/music/old.mp3".into(),
            downloaded: 10,
            total: 10,
            status: STATUS_DONE.into(),
            error: None,
            source: None,
            created_at: 1,
            updated_at: 1,
            targets: vec!["keep-me".into()],
            digest: String::new(),
        };
        std::fs::write(
            &path,
            serde_json::to_string(&DlState { tasks: vec![old] }).unwrap(),
        )
        .unwrap();
        let q = DlQueue::open(&dir, noop_sink()).unwrap();

        let _read_only = ReadOnlyDir::enter(&dir);
        let err = q
            .reserve(task_stub(5, STATUS_QUEUED, vec!["new-target"]))
            .expect_err("落盘失败必须上抛");
        assert!(err.contains("任务未启动"), "{}", err);

        let t = q.task(5).expect("旧记录必须恢复");
        assert_eq!(t.status, STATUS_DONE, "旧状态必须原样恢复");
        assert_eq!(t.path, "/music/old.mp3", "旧 path 不得丢");
        assert_eq!(
            t.targets,
            vec!["keep-me".to_string()],
            "旧 targets 不得被未提交合并污染"
        );
        let raw: DlState = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(raw.tasks[0].path, "/music/old.mp3");
        drop(_read_only);
        std::fs::remove_dir_all(&dir).expect("权限故障夹具应可清理");
    }

    /// reserve 重入必须保留旧记录的发布 intent（path / downloaded / total），
    /// 否则 run 的 intent 恢复分支永远走不到（抽查问题 1）。
    #[test]
    fn reserve_carries_over_publish_intent() {
        let dir = test_dir(format!("dlq-intent-carry-{}", std::process::id()).as_str());
        let old = DlTask {
            id: 6,
            name: "晴天".into(),
            artist: "周杰伦".into(),
            album: String::new(),
            duration_ms: 0,
            path: "/music/周杰伦 - 晴天.mp3".into(),
            downloaded: 4,
            total: 0, // chunked：无 content-length
            status: STATUS_QUEUED.into(),
            error: None,
            source: None,
            created_at: 1,
            updated_at: 1,
            targets: vec!["p1".into()],
            digest: String::new(),
        };
        std::fs::write(
            dir.join("downloads.json"),
            serde_json::to_string(&DlState { tasks: vec![old] }).unwrap(),
        )
        .unwrap();
        let q = DlQueue::open(&dir, noop_sink()).unwrap();
        q.reserve(task_stub(6, STATUS_QUEUED, vec!["p2"])).unwrap();
        let t = q.task(6).unwrap();
        assert_eq!(
            t.path, "/music/周杰伦 - 晴天.mp3",
            "旧 path intent 必须保留"
        );
        assert_eq!(t.downloaded, 4, "旧 downloaded 必须保留");
        assert_eq!(t.targets, vec!["p1".to_string(), "p2".to_string()]);
        std::fs::remove_dir_all(&dir).ok();
    }

    /// R4：clear 落盘失败后内存回滚（不得不清）。
    #[cfg(unix)]
    #[test]
    fn clear_failure_rolls_back_memory() {
        let dir = test_dir(format!("dlq-clear-rb-{}", std::process::id()).as_str());
        let q = DlQueue::open(&dir, noop_sink()).unwrap();
        q.mutate_all(vec![
            (1, STATUS_DONE),
            (2, STATUS_FAILED),
            (3, STATUS_QUEUED),
        ]);

        let _read_only = ReadOnlyDir::enter(&dir);
        let err = q.clear(false).expect_err("落盘失败必须上抛");
        assert!(err.contains("写入失败"), "{}", err);
        assert_eq!(q.list().len(), 3, "clear 失败后内存必须回滚");
        assert!(q.last_error().is_some(), "失败必须可见");
        drop(_read_only);
        std::fs::remove_dir_all(&dir).expect("权限故障夹具应可清理");
    }

    /// R3：并发 mutate（各自落盘）最终结果始终可解析、不丢任务。
    #[test]
    fn concurrent_mutations_leave_parseable_state() {
        let dir = test_dir(format!("dlq-conc-{}", std::process::id()).as_str());
        let q = Arc::new(DlQueue::open(&dir, noop_sink()).unwrap());
        q.mutate_all((1..=8).map(|i| (i, STATUS_QUEUED)).collect());
        let mut handles = Vec::new();
        for i in 1..=8i64 {
            let q = Arc::clone(&q);
            handles.push(std::thread::spawn(move || {
                for n in 1..=20u64 {
                    q.mutate(i, |t| t.downloaded = n);
                }
            }));
        }
        for h in handles {
            h.join().unwrap();
        }
        let raw = std::fs::read(dir.join("downloads.json")).unwrap();
        let parsed: DlState = serde_json::from_slice(&raw).expect("并发落盘后文件必须可解析");
        assert_eq!(parsed.tasks.len(), 8, "任务不得丢失");
        for t in &parsed.tasks {
            assert_eq!(t.downloaded, 20, "每个任务的更新不得丢：id={}", t.id);
        }
        std::fs::remove_dir_all(&dir).ok();
    }

    /// R3：外部修改检测——本实例落盘前发现文件被其他进程改动，必须拒绝
    /// 用旧快照覆盖，且原文件内容保持不动。
    #[test]
    fn external_modification_is_detected_and_never_overwritten() {
        let dir = test_dir(format!("dlq-ext-{}", std::process::id()).as_str());
        let path = dir.join("downloads.json");
        let q = DlQueue::open(&dir, noop_sink()).unwrap();
        q.reserve(task_stub(1, STATUS_QUEUED, vec![])).unwrap();

        // 模拟第二个实例：读取并改写 downloads.json
        let mut other: DlState = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        other
            .tasks
            .push(task_stub(99, STATUS_QUEUED, vec!["other-instance"]));
        std::fs::write(&path, serde_json::to_string(&other).unwrap()).unwrap();

        let err = q
            .reserve(task_stub(2, STATUS_QUEUED, vec![]))
            .expect_err("旧快照不得覆盖外部修改");
        assert!(
            err.contains("其他进程修改") || err.contains("拒绝"),
            "错误需说明外部修改：{}",
            err
        );
        assert!(q.last_error().is_some());
        // 外部写入的内容原样保留
        let after: DlState = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(after.tasks.len(), 2, "外部修改不得被覆盖");
        assert_eq!(after.tasks[1].id, 99);
        std::fs::remove_dir_all(&dir).ok();
    }

    /// R2 / E0 audit：finalize 前已持久记录 final path + 完整大小 intent，
    /// 重启后按 intent 恢复 done——**不重发 HTTP、不产生副本、targets 保留**。
    /// 覆盖 chunked（total=0）场景：以 downloaded 为准。
    #[test]
    fn restart_recovers_placed_file_by_intent_without_redownload() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let qdir = test_dir(format!("dlq-intent-q-{}", std::process::id()).as_str());
            let dl_dir = test_dir(format!("dlq-intent-dl-{}", std::process::id()).as_str());
            // 上次中断时持久化的状态：文件已落位、path intent 已记录、
            // downloaded=实际字节（chunked total=0）、**内容摘要**已记录
            let placed = dl_dir.join("周杰伦 - 晴天.mp3");
            std::fs::write(&placed, b"abcd").unwrap();
            let digest = super::file_digest(&placed).unwrap();
            let seed = DlTask {
                id: 42,
                name: "晴天".into(),
                artist: "周杰伦".into(),
                album: String::new(),
                duration_ms: 0,
                path: placed.to_string_lossy().to_string(),
                downloaded: 4,
                total: 0,
                status: STATUS_RUNNING.into(),
                error: None,
                source: None,
                created_at: 1,
                updated_at: 1,
                targets: vec![],
                digest,
            };
            std::fs::write(
                qdir.join("downloads.json"),
                serde_json::to_string(&DlState { tasks: vec![seed] }).unwrap(),
            )
            .unwrap();

            let (port, hits) = counting_server(b"abcd");
            let q = Arc::new(DlQueue::open(&qdir, noop_sink()).unwrap());
            q.enqueue(
                42,
                "晴天",
                "周杰伦",
                "",
                0,
                &format!("http://127.0.0.1:{}/a.mp3", port),
                &dl_dir,
                None,
                vec!["morning".into()],
            )
            .unwrap();

            let t = wait_status(&q, 42, STATUS_DONE);
            assert_eq!(
                hits.load(std::sync::atomic::Ordering::SeqCst),
                0,
                "按 intent 恢复不得重新下载"
            );
            assert_eq!(t.path, placed.to_string_lossy(), "path intent 原样保留");
            assert!(
                t.targets.contains(&"morning".to_string()),
                "入队带入的 targets 必须保留：{:?}",
                t.targets
            );
            // 无重复副本
            let copies = std::fs::read_dir(&dl_dir)
                .unwrap()
                .filter_map(|e| e.ok())
                .filter(|e| e.file_name().to_string_lossy().starts_with("周杰伦 - 晴天"))
                .count();
            assert_eq!(copies, 1, "不得产生重复副本");
            std::fs::remove_dir_all(&qdir).ok();
            std::fs::remove_dir_all(&dl_dir).ok();
        });
    }

    /// 落位必须发生在准确 planned path；并发冲突时先持久新 intent 再落位，
    /// decoy 文件不被覆盖、路径记录与实际落位一致（抽查问题 3）。
    #[test]
    fn finalize_conflict_republishes_intent_before_placing() {
        let dir = test_dir(format!("dlq-fin-{}", std::process::id()).as_str());
        let q = Arc::new(DlQueue::open(&dir, noop_sink()).unwrap());
        q.reserve(task_stub(7, STATUS_QUEUED, vec![])).unwrap();

        // decoy 占用 planned path
        let planned = dir.join("a - t.mp3");
        std::fs::write(&planned, b"decoy").unwrap();
        let tmp = dir.join(".part");
        std::fs::write(&tmp, b"real-data").unwrap();

        let placed = q.finalize_at_planned(7, &tmp, &dir, &planned).unwrap();
        assert_ne!(placed, planned, "冲突时必须换名，不得覆盖 decoy");
        assert_eq!(placed.file_name().unwrap(), "a - t (1).mp3");
        assert_eq!(
            std::fs::read(&planned).unwrap(),
            b"decoy",
            "decoy 必须字节不变"
        );
        assert_eq!(std::fs::read(&placed).unwrap(), b"real-data");
        assert!(!tmp.exists());
        // intent 记录与实际落位一致
        assert_eq!(q.task(7).unwrap().path, placed.to_string_lossy());

        // 无冲突时落位到准确 planned path
        let tmp2 = dir.join(".part2");
        std::fs::write(&tmp2, b"more").unwrap();
        let planned2 = dir.join("b - u.mp3");
        let placed2 = q.finalize_at_planned(7, &tmp2, &dir, &planned2).unwrap();
        assert_eq!(placed2, planned2, "无冲突必须落在准确 planned path");
        std::fs::remove_dir_all(&dir).ok();
    }

    /// clear(all) 不得清除本进程仍在运行的下载（否则文件落位后记录消失，
    /// 成为孤儿）。活动任务完成后可正常清除。
    #[test]
    fn clear_all_keeps_active_download() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let qdir = test_dir(format!("dlq-clear-act-{}", std::process::id()).as_str());
            let dl_dir = test_dir(format!("dlq-clear-act-dl-{}", std::process::id()).as_str());
            // 慢服务器：等测试发出 clear 后才放行
            let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            let port = listener.local_addr().unwrap().port();
            let release = Arc::new(std::sync::Mutex::new(Vec::new()));
            let rel2 = Arc::clone(&release);
            std::thread::spawn(move || {
                use std::io::{Read, Write};
                for stream in listener.incoming() {
                    let mut s = stream.unwrap();
                    let mut buf = [0u8; 1024];
                    let _ = s.read(&mut buf);
                    // 阻塞直到测试放行
                    loop {
                        if !rel2.lock().unwrap().is_empty() {
                            break;
                        }
                        std::thread::sleep(std::time::Duration::from_millis(20));
                    }
                    let body = b"abcd";
                    let head = "HTTP/1.1 200 OK\r\ncontent-type: audio/mpeg\r\ncontent-length: 4\r\nconnection: close\r\n\r\n";
                    let _ = s.write_all(head.as_bytes());
                    let _ = s.write_all(body);
                }
            });

            let q = Arc::new(DlQueue::open(&qdir, noop_sink()).unwrap());
            q.enqueue(
                11,
                "慢歌",
                "歌手",
                "",
                0,
                &format!("http://127.0.0.1:{}/a.mp3", port),
                &dl_dir,
                None,
                vec![],
            )
            .unwrap();
            wait_status(&q, 11, STATUS_RUNNING);
            // 在途期间 clear(all)：记录必须保留
            q.clear(false).unwrap();
            assert!(q.task(11).is_some(), "clear(all) 不得删除在途下载记录");
            // 放行下载完成
            release.lock().unwrap().push(());
            let t = wait_status(&q, 11, STATUS_DONE);
            assert!(std::path::Path::new(&t.path).exists(), "落位文件必须在");
            q.clear(true).unwrap();
            assert!(q.task(11).is_none(), "完成后 clear(done) 正常清除");
            std::fs::remove_dir_all(&qdir).ok();
            std::fs::remove_dir_all(&dl_dir).ok();
        });
    }

    /// 进程关闭收束：运行中的下载在块边界暂停——状态持久化为 queued +
    /// 可重试错误、targets 保留、临时文件清理；重新入队后从本地服务器
    /// 完成（真正的运行中 HTTP 下载 + shutdown 语义）。
    #[test]
    fn shutdown_pauses_active_download_and_recovers() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let qdir = test_dir(format!("dlq-shutdown-q-{}", std::process::id()).as_str());
            let dl_dir = test_dir(format!("dlq-shutdown-dl-{}", std::process::id()).as_str());
            // 慢服务器：收到请求后等待放行
            let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            let port = listener.local_addr().unwrap().port();
            let release = Arc::new(std::sync::Mutex::new(false));
            let rel2 = Arc::clone(&release);
            std::thread::spawn(move || {
                use std::io::{Read, Write};
                for stream in listener.incoming() {
                    let mut s = stream.unwrap();
                    let mut buf = [0u8; 1024];
                    let _ = s.read(&mut buf);
                    // 已发头（声明 4 字节），挂起 body 直到放行
                    let head = "HTTP/1.1 200 OK\r\ncontent-type: audio/mpeg\r\ncontent-length: 4\r\nconnection: close\r\n\r\n";
                    let _ = s.write_all(head.as_bytes());
                    while !*rel2.lock().unwrap() {
                        std::thread::sleep(std::time::Duration::from_millis(20));
                    }
                    let _ = s.write_all(b"abcd");
                    let _ = s.flush();
                }
            });

            let q = Arc::new(DlQueue::open(&qdir, noop_sink()).unwrap());
            q.enqueue(
                21,
                "暂停歌",
                "歌手",
                "",
                0,
                &format!("http://127.0.0.1:{}/a.mp3", port),
                &dl_dir,
                None,
                vec!["playlist-x".into()],
            )
            .unwrap();
            wait_status(&q, 21, STATUS_RUNNING);

            // 关闭收束：有界等待在途下载暂停
            let remaining = q.begin_shutdown(std::time::Duration::from_secs(5));
            assert_eq!(remaining, 0, "块边界内必须完成暂停");

            let t = q.task(21).expect("暂停后记录必须在");
            assert_eq!(t.status, STATUS_QUEUED, "状态必须持久化为 queued");
            assert!(
                t.error.as_deref().unwrap_or("").contains("暂停"),
                "错误需说明暂停可重试：{:?}",
                t.error
            );
            assert_eq!(t.targets, vec!["playlist-x".to_string()], "targets 必须保留");
            // 临时文件清理
            let parts: Vec<_> = std::fs::read_dir(&dl_dir)
                .unwrap()
                .filter_map(|e| e.ok())
                .filter(|e| e.file_name().to_string_lossy().ends_with(".part"))
                .collect();
            assert!(parts.is_empty(), "暂停后不得残留 .part：{:?}", parts);
            // 落盘内容同样为可恢复状态（模拟重启核对）
            let raw: DlState =
                serde_json::from_slice(&std::fs::read(qdir.join("downloads.json")).unwrap()).unwrap();
            assert_eq!(raw.tasks[0].status, STATUS_QUEUED);
            assert_eq!(raw.tasks[0].targets, vec!["playlist-x".to_string()]);

            // 关闭后拒绝新入队
            let err = q
                .enqueue(22, "x", "y", "", 0, "http://127.0.0.1:1/a.mp3", &dl_dir, None, vec![])
                .expect_err("关闭后不得再入队");
            assert!(err.contains("关闭"), "{}", err);

            // 模拟重启：新实例重新入队，放行后完成
            let q2 = Arc::new(DlQueue::open(&qdir, noop_sink()).unwrap());
            assert_eq!(q2.task(21).unwrap().status, STATUS_QUEUED);
            q2.enqueue(
                21,
                "暂停歌",
                "歌手",
                "",
                0,
                &format!("http://127.0.0.1:{}/a.mp3", port),
                &dl_dir,
                None,
                vec![],
            )
            .unwrap();
            *release.lock().unwrap() = true;
            let done = wait_status(&q2, 21, STATUS_DONE);
            assert!(std::path::Path::new(&done.path).exists(), "完成后文件必须落位");
            std::fs::remove_dir_all(&qdir).ok();
            std::fs::remove_dir_all(&dl_dir).ok();
        });
    }

    /// 重启后的 queued 记录必须可重新入队（恢复语义），只有本进程
    /// 在途下载才被拒绝。
    #[test]
    fn queued_record_can_be_reenqueued_after_restart() {
        let dir = test_dir(format!("dlq-re-{}", std::process::id()).as_str());
        let path = dir.join("downloads.json");
        std::fs::write(
            &path,
            serde_json::to_string(&DlState {
                tasks: vec![task_stub(9, STATUS_QUEUED, vec!["p1"])],
            })
            .unwrap(),
        )
        .unwrap();
        let q = DlQueue::open(&dir, noop_sink()).unwrap();
        assert_eq!(q.task(9).unwrap().status, STATUS_QUEUED);
        q.reserve(task_stub(9, STATUS_QUEUED, vec!["p2"]))
            .expect("queued 记录必须可重新入队");
        let t = q.task(9).unwrap();
        assert_eq!(t.targets, vec!["p1".to_string(), "p2".to_string()]);
        std::fs::remove_dir_all(&dir).ok();
    }

    /// R3：已跟踪的 downloads.json 被外部删除 = 并发修改，必须判冲突，
    /// 不得静默重建（重建会丢掉另一实例刚写入的任务）。
    #[test]
    fn deleted_queue_file_is_conflict_not_silent_recreate() {
        let dir = test_dir(format!("dlq-del-{}", std::process::id()).as_str());
        let path = dir.join("downloads.json");
        let q = DlQueue::open(&dir, noop_sink()).unwrap();
        q.reserve(task_stub(1, STATUS_QUEUED, vec![])).unwrap();
        assert!(path.exists());

        std::fs::remove_file(&path).unwrap();
        let err = q
            .reserve(task_stub(2, STATUS_QUEUED, vec![]))
            .expect_err("文件被删必须判冲突");
        assert!(
            err.contains("删除") || err.contains("修改"),
            "错误需说明并发删除/修改：{}",
            err
        );
        assert!(!path.exists(), "不得静默重建 downloads.json");
        std::fs::remove_dir_all(&dir).ok();
    }

    /// R3：downloads.json 是符号链接时拒绝替换——rename 会摧毁链接本身。
    #[cfg(unix)]
    #[test]
    fn symlink_queue_file_is_never_replaced() {
        let dir = test_dir(format!("dlq-link-{}", std::process::id()).as_str());
        let real_dir = test_dir(format!("dlq-link-real-{}", std::process::id()).as_str());
        let real = real_dir.join("downloads.json");
        std::fs::write(&real, serde_json::to_string(&DlState::default()).unwrap()).unwrap();
        let link = dir.join("downloads.json");
        std::os::unix::fs::symlink(&real, &link).unwrap();

        let q = DlQueue::open(&dir, noop_sink()).unwrap();
        let err = q
            .reserve(task_stub(1, STATUS_QUEUED, vec![]))
            .expect_err("符号链接必须拒绝写入");
        assert!(err.contains("符号链接"), "{}", err);
        // 链接本身与目标都保持原样
        assert!(std::fs::symlink_metadata(&link)
            .unwrap()
            .file_type()
            .is_symlink());
        assert_eq!(
            std::fs::read(&real).unwrap(),
            serde_json::to_string(&DlState::default())
                .unwrap()
                .into_bytes()
        );
        std::fs::remove_dir_all(&dir).ok();
        std::fs::remove_dir_all(&real_dir).ok();
    }
    // ---------------------------------------------------------------------
    // E0 修复回归（审查 .artifacts/mmf-e0-review.md）
    // ---------------------------------------------------------------------

    /// E0-4：`open()` 的初始读取必须在 **跨进程锁内** —— 另一实例在 open
    /// 期间写入的任务不得被旧快照覆盖（旧实现：锁外读 + 锁外写 + 锁后基线）。
    #[test]
    fn open_reads_under_the_cross_process_lock() {
        use std::os::unix::io::AsRawFd;
        let dir = test_dir(format!("dlq-openlock-{}", std::process::id()).as_str());
        let path = dir.join("downloads.json");
        let seed = DlState {
            tasks: vec![task_stub(1, STATUS_QUEUED, vec!["p1"])],
        };
        std::fs::write(&path, serde_json::to_string(&seed).unwrap()).unwrap();

        // 独占队列锁文件：open() 必须阻塞在这里（证明读取也在锁内）
        let lock = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(dir.join("downloads.json.lock"))
            .unwrap();
        let rc = unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) };
        assert_eq!(rc, 0, "flock 失败");

        let dir2 = dir.clone();
        let handle = std::thread::spawn(move || DlQueue::open(&dir2, noop_sink()));
        std::thread::sleep(std::time::Duration::from_millis(300));
        assert!(
            !handle.is_finished(),
            "open() 必须等待跨进程锁（初始读取不得在锁外）"
        );

        // 另一实例在 open 期间写入任务 99
        let mut st: DlState = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        st.tasks
            .push(task_stub(99, STATUS_QUEUED, vec!["other-instance"]));
        std::fs::write(&path, serde_json::to_string(&st).unwrap()).unwrap();

        unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_UN) };
        let q = handle.join().unwrap().unwrap();
        assert!(
            q.task(99).is_some(),
            "另一实例的任务不得被 open() 的旧快照覆盖"
        );
        let raw: DlState = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert!(
            raw.tasks.iter().any(|t| t.id == 99),
            "磁盘上另一实例的任务也不得丢失"
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    /// E0-10：锁文件是符号链接时必须拒绝打开，且 **不得截断** 目标文件。
    #[cfg(unix)]
    #[test]
    fn lock_file_symlink_is_refused_without_truncating_target() {
        let dir = test_dir(format!("dlq-locklink-{}", std::process::id()).as_str());
        let victim_dir = test_dir(format!("dlq-locklink-victim-{}", std::process::id()).as_str());
        let victim = victim_dir.join("victim.bin");
        std::fs::write(&victim, vec![7u8; 4096]).unwrap();
        std::os::unix::fs::symlink(&victim, dir.join("downloads.json.lock")).unwrap();

        let opened = DlQueue::open(&dir, noop_sink());
        let err = match opened {
            Ok(_) => panic!("锁文件为符号链接必须拒绝打开"),
            Err(e) => e,
        };
        assert!(!err.to_string().is_empty(), "必须给出明确原因：{}", err);
        assert_eq!(
            std::fs::metadata(&victim).unwrap().len(),
            4096,
            "锁文件不得截断符号链接指向的目标"
        );
        std::fs::remove_dir_all(&dir).ok();
        std::fs::remove_dir_all(&victim_dir).ok();
    }

    /// E1-4：同长度、同 mtime 的替换（换 inode）也必须被识别为冲突。
    #[test]
    fn same_size_same_mtime_replacement_is_detected() {
        let dir = test_dir(format!("dlq-token-{}", std::process::id()).as_str());
        let path = dir.join("downloads.json");
        let q = DlQueue::open(&dir, noop_sink()).unwrap();
        q.reserve(task_stub(1, STATUS_QUEUED, vec![])).unwrap();

        // 外部替换：内容长度相同、mtime 保持不变、inode 变化
        let original = std::fs::read(&path).unwrap();
        let mtime = std::fs::metadata(&path).unwrap().modified().unwrap();
        let tmp = dir.join("external.tmp");
        std::fs::write(&tmp, &original).unwrap();
        std::fs::rename(&tmp, &path).unwrap();
        let f = std::fs::File::options().write(true).open(&path).unwrap();
        f.set_times(std::fs::FileTimes::new().set_modified(mtime))
            .unwrap();
        drop(f);
        let meta = std::fs::metadata(&path).unwrap();
        assert_eq!(meta.len(), original.len() as u64, "长度必须一致");
        assert_eq!(meta.modified().unwrap(), mtime, "mtime 必须一致");

        let err = q
            .reserve(task_stub(2, STATUS_QUEUED, vec![]))
            .expect_err("同大小同 mtime 的替换（换 inode）必须判冲突");
        assert!(
            err.contains("其他进程修改") || err.contains("拒绝"),
            "错误需说明并发修改：{}",
            err
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    /// E0-9：clear(all) 与入队的竞态 —— 在途任务的记录不得被删掉
    /// （删掉就成为孤儿：文件落位却无 path / targets）。
    #[test]
    fn clear_all_never_drops_an_inflight_task_record() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let dir = test_dir(format!("dlq-clearrace-{}", std::process::id()).as_str());
            let q = Arc::new(DlQueue::open(&dir, noop_sink()).unwrap());
            q.reserve(task_stub(5, STATUS_QUEUED, vec!["keep"]))
                .unwrap();

            // 先占住状态锁：clear 会阻塞在取锁处
            let guard = q.state.lock();
            let q2 = Arc::clone(&q);
            let handle = std::thread::spawn(move || q2.clear(false));
            std::thread::sleep(std::time::Duration::from_millis(150));
            // 此刻「入队」把任务登记为在途（旧实现在这里用空快照删掉记录）
            q.active.lock().insert(5);
            drop(guard);
            handle.join().unwrap().unwrap();

            assert!(
                q.task(5).is_some(),
                "在途任务的记录不得被 clear(all) 删除（否则落位后成孤儿）"
            );
            std::fs::remove_dir_all(&dir).ok();
        });
    }

    /// E0-8（端到端）：真实 HTTP 下载完成 → done 落盘失败 → **公开重试**
    /// 必须按 intent 恢复：不重下、不产生副本、path / 大小 / targets 保留。
    #[cfg(unix)]
    #[test]
    fn done_persist_failure_then_public_retry_recovers_without_redownload() {
        use std::os::unix::fs::PermissionsExt;
        use std::sync::atomic::{AtomicBool, Ordering};
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let qdir = test_dir(format!("dlq-e08-q-{}", std::process::id()).as_str());
            let dl_dir = test_dir(format!("dlq-e08-dl-{}", std::process::id()).as_str());
            let (port, hits) = counting_server(b"real-audio-bytes");

            // 故障注入：意图落盘（path 已记录）之后把队列目录设为只读 →
            // 随后的 done 落盘必然失败（临时文件无法创建）。
            //
            // 时序（确定性，不靠竞争取胜）：
            // - 注入发生在 intent 事件的 sink 回调里，而 `mutate` 是
            //   「先落盘成功、后回调」——回调返回时目录已只读，后续
            //   done 写入严格晚于注入，必然失败；
            // - 权限恢复必须等「persistError 事件已发出 + 在途集合已
            //   释放（下载任务真正结束）」两个信号都出现。只等文件落位
            //   就恢复权限会与 done 写入竞争：恢复先到则 done 写入
            //   成功，持久状态变 done，测试意图（done 落盘失败停在
            //   running）被破坏——这正是之前 flaky 的根因。
            let injected = Arc::new(AtomicBool::new(false));
            let persist_failed = Arc::new(AtomicBool::new(false));
            let fault_dir = qdir.clone();
            let sink: EventSink = {
                let injected = Arc::clone(&injected);
                let persist_failed = Arc::clone(&persist_failed);
                Arc::new(move |v: serde_json::Value| {
                    let is_intent = v.get("ev").and_then(|e| e.as_str()) == Some("dl")
                        && v["p"]["status"].as_str() == Some("running")
                        && v["p"]["path"]
                            .as_str()
                            .map(|p| !p.is_empty())
                            .unwrap_or(false);
                    if is_intent && !injected.swap(true, Ordering::SeqCst) {
                        let _ = std::fs::set_permissions(
                            &fault_dir,
                            std::fs::Permissions::from_mode(0o500),
                        );
                    }
                    if v.get("ev").and_then(|e| e.as_str()) == Some("dl.persistError") {
                        persist_failed.store(true, Ordering::SeqCst);
                    }
                })
            };

            let q = Arc::new(DlQueue::open(&qdir, sink).unwrap());
            q.enqueue(
                31,
                "歌",
                "人",
                "",
                0,
                &format!("http://127.0.0.1:{}/a.mp3", port),
                &dl_dir,
                None,
                vec!["pl-x".into()],
            )
            .unwrap();

            // 等待确定性收束：注入已发生 → done 落盘失败（persistError
            // 事件已发出）→ 在途集合释放（下载任务真正结束）。三者齐备
            // 后磁盘与内存都不再有写者，此时恢复权限不存在竞争窗口。
            assert!(
                wait_for(|| injected.load(Ordering::SeqCst)),
                "故障注入应发生（intent 事件已触发只读）"
            );
            // 权限恢复 RAII 兜底先行：后续任何断言失败也不会把目录留在 0o500
            let _restore = ReadOnlyDir { path: qdir.clone() };
            assert!(
                wait_for(|| persist_failed.load(Ordering::SeqCst) && !q.is_active(31)),
                "done 落盘应失败（persistError）且在途应结束"
            );

            // 恢复目录写权限（重试需要写盘）
            std::fs::set_permissions(&qdir, std::fs::Permissions::from_mode(0o700)).unwrap();

            // done 落盘失败 → 持久状态停在 running，但下载其实已结束
            let t = q.task(31).unwrap();
            assert_eq!(
                t.status, STATUS_RUNNING,
                "done 落盘失败后持久状态停在 running"
            );
            assert!(!q.is_active(31), "下载已结束：不应仍算在途");
            assert_eq!(hits.load(Ordering::SeqCst), 1, "真实 HTTP 只应请求一次");
            assert!(!t.digest.is_empty(), "意图必须带内容摘要");
            let placed_path = t.path.clone();
            assert!(
                !placed_path.is_empty() && std::path::Path::new(&placed_path).exists(),
                "intent 的最终路径必须已真实落位：{}",
                placed_path
            );

            // 公开重试路径（桥接 dl.retry 走的就是 enqueue）
            q.enqueue(
                31,
                "歌",
                "人",
                "",
                0,
                &format!("http://127.0.0.1:{}/a.mp3", port),
                &dl_dir,
                None,
                vec!["pl-y".into()],
            )
            .unwrap();
            let done = wait_status(&q, 31, STATUS_DONE);
            assert_eq!(
                hits.load(Ordering::SeqCst),
                1,
                "重试不得重新下载（必须按 intent 恢复）"
            );
            assert_eq!(done.path, placed_path, "path 必须原样保留");
            assert!(
                done.targets.contains(&"pl-x".to_string())
                    && done.targets.contains(&"pl-y".to_string()),
                "targets 必须保留并集：{:?}",
                done.targets
            );
            let copies = std::fs::read_dir(&dl_dir)
                .unwrap()
                .filter_map(|e| e.ok())
                .filter(|e| e.file_name().to_string_lossy().ends_with(".mp3"))
                .count();
            assert_eq!(copies, 1, "不得产生重复副本");

            std::fs::remove_dir_all(&qdir).ok();
            std::fs::remove_dir_all(&dl_dir).ok();
        });
    }

    /// E1-6：路径上是 **同大小但内容不同** 的无关文件时，绝不能被当作
    /// 「已完成」——必须重新下载，且绝不删除用户文件。
    #[test]
    fn unrelated_same_size_file_is_not_treated_as_completed() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let qdir = test_dir(format!("dlq-digest-q-{}", std::process::id()).as_str());
            let dl_dir = test_dir(format!("dlq-digest-dl-{}", std::process::id()).as_str());
            // 无关文件：大小与记录一致，内容不同
            let unrelated = dl_dir.join("别的歌 - 别的.mp3");
            std::fs::write(&unrelated, b"aaaa").unwrap();
            let seed = DlTask {
                id: 77,
                name: "歌".into(),
                artist: "人".into(),
                album: String::new(),
                duration_ms: 0,
                path: unrelated.to_string_lossy().to_string(),
                downloaded: 4,
                total: 4,
                status: STATUS_RUNNING.into(),
                error: None,
                source: None,
                created_at: 1,
                updated_at: 1,
                targets: vec!["p".into()],
                // 摘要属于另一份内容 → 与磁盘上的文件不匹配
                digest: "0123456789abcdef".into(),
            };
            std::fs::write(
                qdir.join("downloads.json"),
                serde_json::to_string(&DlState { tasks: vec![seed] }).unwrap(),
            )
            .unwrap();

            let (port, hits) = counting_server(b"bbbb");
            let q = Arc::new(DlQueue::open(&qdir, noop_sink()).unwrap());
            q.enqueue(
                77,
                "歌",
                "人",
                "",
                0,
                &format!("http://127.0.0.1:{}/a.mp3", port),
                &dl_dir,
                None,
                vec!["p".into()],
            )
            .unwrap();
            let t = wait_status(&q, 77, STATUS_DONE);
            assert_eq!(
                hits.load(std::sync::atomic::Ordering::SeqCst),
                1,
                "摘要不符必须重新下载（不得把无关文件当成已完成）"
            );
            assert_ne!(t.path, unrelated.to_string_lossy(), "不得认领无关文件");
            assert!(unrelated.exists(), "无关文件必须保留（绝不删除用户文件）");
            std::fs::remove_dir_all(&qdir).ok();
            std::fs::remove_dir_all(&dl_dir).ok();
        });
    }

    /// E1-2：关闭必须能 **立即取消** 卡在响应头的 HTTP 请求（不必等
    /// client 的 1800s 超时），并把任务持久化为可恢复状态。
    #[test]
    fn shutdown_cancels_stuck_http_request() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let qdir = test_dir(format!("dlq-shutreq-q-{}", std::process::id()).as_str());
            let dl_dir = test_dir(format!("dlq-shutreq-dl-{}", std::process::id()).as_str());
            // 服务器接受连接但 **从不响应**（响应头都不给）
            let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            let port = listener.local_addr().unwrap().port();
            std::thread::spawn(move || {
                use std::io::Read;
                for stream in listener.incoming() {
                    let mut s = stream.unwrap();
                    let mut buf = [0u8; 16];
                    let _ = s.read(&mut buf);
                    // 不写任何响应，永久挂起
                    std::thread::sleep(std::time::Duration::from_secs(30));
                }
            });

            let q = Arc::new(DlQueue::open(&qdir, noop_sink()).unwrap());
            q.enqueue(
                41,
                "卡住",
                "人",
                "",
                0,
                &format!("http://127.0.0.1:{}/a.mp3", port),
                &dl_dir,
                None,
                vec!["pl".into()],
            )
            .unwrap();
            wait_status(&q, 41, STATUS_RUNNING);

            let start = std::time::Instant::now();
            let remaining = q.begin_shutdown(std::time::Duration::from_secs(8));
            assert_eq!(remaining, 0, "在途下载必须被取消并收束");
            assert!(
                start.elapsed() < std::time::Duration::from_secs(5),
                "取消必须及时（不能等 client 超时）：{:?}",
                start.elapsed()
            );
            let t = q.task(41).unwrap();
            assert_eq!(t.status, STATUS_QUEUED, "取消后必须持久化为可恢复状态");
            assert!(t.targets.contains(&"pl".to_string()), "targets 必须保留");
            std::fs::remove_dir_all(&qdir).ok();
            std::fs::remove_dir_all(&dl_dir).ok();
        });
    }

    /// E1-10：reserve 落盘失败后回滚必须 **保持原位置**（顺序不变）。
    #[cfg(unix)]
    #[test]
    fn reserve_failure_keeps_task_order() {
        let dir = test_dir(format!("dlq-order-{}", std::process::id()).as_str());
        let q = DlQueue::open(&dir, noop_sink()).unwrap();
        q.reserve(task_stub(1, STATUS_QUEUED, vec!["a"])).unwrap();
        q.reserve(task_stub(2, STATUS_QUEUED, vec!["b"])).unwrap();
        q.reserve(task_stub(3, STATUS_QUEUED, vec!["c"])).unwrap();
        let before: Vec<i64> = q.list().iter().map(|t| t.id).collect();
        assert_eq!(before, vec![1, 2, 3]);

        let _read_only = ReadOnlyDir::enter(&dir);
        let err = q
            .reserve(task_stub(2, STATUS_QUEUED, vec!["new"]))
            .expect_err("落盘失败必须上抛");
        assert!(err.contains("任务未启动"), "{}", err);

        let after: Vec<i64> = q.list().iter().map(|t| t.id).collect();
        assert_eq!(after, before, "回滚后任务顺序不得改变");
        assert_eq!(
            q.task(2).unwrap().targets,
            vec!["b".to_string()],
            "回滚后旧 targets 不得被未提交的新值污染"
        );
        drop(_read_only);
        std::fs::remove_dir_all(&dir).expect("权限故障夹具应可清理");
    }

    /// E1-5 / 并发：跨进程锁必须真正互斥——另一实例持锁时，本实例的写入
    /// 必须 **有界超时失败**（不得假成功，也不得提前释放 OS 锁）。
    #[test]
    fn cross_process_lock_blocks_writes_until_bounded_timeout() {
        use std::os::unix::io::AsRawFd;
        let dir = test_dir(format!("dlq-lockwait-{}", std::process::id()).as_str());
        let mut q = DlQueue::open(&dir, noop_sink()).unwrap();
        // 测试里缩短等待上限（生产默认 5s）
        q.lock_wait = std::time::Duration::from_millis(300);

        // 另一实例持有同一把跨进程锁
        let lock = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(dir.join("downloads.json.lock"))
            .unwrap();
        let rc = unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) };
        assert_eq!(rc, 0, "flock 失败");

        let start = std::time::Instant::now();
        let err = q
            .reserve(task_stub(1, STATUS_QUEUED, vec![]))
            .expect_err("锁被占用时写入必须失败（不得假成功）");
        let waited = start.elapsed();
        assert!(
            err.contains("锁") || err.contains("超时"),
            "错误需说明锁冲突：{}",
            err
        );
        assert!(
            waited >= std::time::Duration::from_millis(250),
            "必须有界等待（不能立刻假成功）：{:?}",
            waited
        );
        assert!(
            waited < std::time::Duration::from_secs(5),
            "等待必须有上界：{:?}",
            waited
        );
        assert!(q.task(1).is_none(), "写入失败不得留下内存登记");

        // 另一实例释放后写入恢复正常
        unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_UN) };
        q.reserve(task_stub(1, STATUS_QUEUED, vec![]))
            .expect("释放后写入必须成功");
        assert!(q.task(1).is_some());
        std::fs::remove_dir_all(&dir).ok();
    }

    /// 并发写者：进程内事务锁必须把「取跨进程锁 → 改状态 → 落盘」串行化，
    /// 不能出现两个线程同时进入临界区（flock 按 fd 生效，同进程会假成功）。
    #[test]
    fn concurrent_writers_are_serialized_and_state_stays_consistent() {
        let dir = test_dir(format!("dlq-txnserial-{}", std::process::id()).as_str());
        let q = Arc::new(DlQueue::open(&dir, noop_sink()).unwrap());
        let mut handles = Vec::new();
        for i in 1..=6i64 {
            let q = Arc::clone(&q);
            handles.push(std::thread::spawn(move || {
                for n in 1..=10u64 {
                    let _ = q.reserve(task_stub(i, STATUS_QUEUED, vec!["t"]));
                    q.mutate(i, |t| t.downloaded = n);
                }
            }));
        }
        for h in handles {
            h.join().unwrap();
        }
        // 文件始终可解析，且 6 个任务都在
        let raw = std::fs::read(dir.join("downloads.json")).unwrap();
        let parsed: DlState = serde_json::from_slice(&raw).expect("并发落盘后文件必须可解析");
        assert_eq!(parsed.tasks.len(), 6, "任务不得丢失");
        for t in &parsed.tasks {
            assert_eq!(t.downloaded, 10, "每个任务的更新不得丢：id={}", t.id);
        }
        // 内存与磁盘一致
        let mem = q.list();
        assert_eq!(mem.len(), 6);
        for t in &mem {
            assert_eq!(t.downloaded, 10);
        }
        std::fs::remove_dir_all(&dir).ok();
    }

    /// E1-6 兼容限制：升级前的旧记录（无内容摘要）**不得**被自动认 done，
    /// 必须显式标注待处理并重新下载（不能声称已证明同一性）。
    #[test]
    fn legacy_intent_without_digest_is_not_auto_completed() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let qdir = test_dir(format!("dlq-legacy-q-{}", std::process::id()).as_str());
            let dl_dir = test_dir(format!("dlq-legacy-dl-{}", std::process::id()).as_str());
            // 旧记录：有 path + 大小，但 **没有摘要**
            let placed = dl_dir.join("旧歌 - 旧名.mp3");
            std::fs::write(&placed, b"abcd").unwrap();
            let seed = DlTask {
                id: 88,
                name: "旧歌".into(),
                artist: "旧名".into(),
                album: String::new(),
                duration_ms: 0,
                path: placed.to_string_lossy().to_string(),
                downloaded: 4,
                total: 4,
                status: STATUS_RUNNING.into(),
                error: None,
                source: None,
                created_at: 1,
                updated_at: 1,
                targets: vec!["p".into()],
                digest: String::new(), // 升级前记录：无摘要
            };
            std::fs::write(
                qdir.join("downloads.json"),
                serde_json::to_string(&DlState { tasks: vec![seed] }).unwrap(),
            )
            .unwrap();

            let (port, hits) = counting_server(b"abcd");
            let q = Arc::new(DlQueue::open(&qdir, noop_sink()).unwrap());
            q.enqueue(
                88,
                "旧歌",
                "旧名",
                "",
                0,
                &format!("http://127.0.0.1:{}/a.mp3", port),
                &dl_dir,
                None,
                vec!["p".into()],
            )
            .unwrap();
            let t = wait_status(&q, 88, STATUS_DONE);
            assert_eq!(
                hits.load(std::sync::atomic::Ordering::SeqCst),
                1,
                "无摘要的旧 intent 不得被当成已证明同一性，必须重新下载"
            );
            assert!(!t.digest.is_empty(), "重新下载后必须记录内容摘要");
            assert!(placed.exists(), "旧文件必须保留（绝不删除用户文件）");
            std::fs::remove_dir_all(&qdir).ok();
            std::fs::remove_dir_all(&dl_dir).ok();
        });
    }
}
