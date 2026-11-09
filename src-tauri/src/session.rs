//! 本地会话与设置持久化。
//!
//! Cookie 与设置保存在应用配置目录下的 `session.json`（权限 0600）。
//! 凭证只写入本机文件，不上传、不写日志。

use std::path::{Path, PathBuf};

use parking_lot::{Mutex, RwLock};
use serde::{Deserialize, Serialize};

use crate::netease::models::Account;

/// 会话临时文件名计数器（同进程内唯一，避免多进程并发写互相覆盖）。
static TMP_COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// 默认音质档位。
pub const DEFAULT_QUALITY: &str = "higher";
/// 默认启用的第三方音源。
pub const DEFAULT_SOURCES: [&str; 3] = ["pyncmd", "gdmusic", "kugou"];

/// 持久化的会话与设置。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionData {
    /// 网易云 Cookie 原文。
    #[serde(default)]
    pub cookie: String,
    /// 音质档位。
    #[serde(default = "default_quality")]
    pub quality: String,
    /// 启用的第三方音源标识。
    #[serde(default = "default_sources")]
    pub sources: Vec<String>,
    /// 下载目录。
    #[serde(default)]
    pub download_dir: String,
    /// 上次登录的账号信息（仅用于展示）。
    #[serde(default)]
    pub account: Option<Account>,
}

fn default_quality() -> String {
    DEFAULT_QUALITY.to_string()
}

fn default_sources() -> Vec<String> {
    DEFAULT_SOURCES.iter().map(|s| s.to_string()).collect()
}

impl Default for SessionData {
    fn default() -> Self {
        SessionData {
            cookie: String::new(),
            quality: default_quality(),
            sources: default_sources(),
            download_dir: default_download_dir(),
            account: None,
        }
    }
}

/// 默认下载目录。
///
/// - macOS：`~/Music/AlgerMusic`；
/// - iOS：App 沙盒 `Documents/AlgerMusic`（配合 `UIFileSharingEnabled`，
///   用户可在「文件」App → 我的 iPhone → Alger Music 中直接访问）。
///   不能用 `audio_dir()`（`$HOME/Music` 在沙盒内部，用户不可见）。
pub fn default_download_dir() -> String {
    #[cfg(target_os = "ios")]
    {
        // iOS：用原生 NSFileManager 取 **当前容器** 的 Documents。
        // 沙盒容器 UUID 在重装 / 升级后会变化，持久化的绝对路径必然失效，
        // 因此这里每次都按当前沙盒重算（见 `SessionStore::download_dir`）。
        ios_documents_dir()
            .map(|p| p.join("AlgerMusic").to_string_lossy().to_string())
            // 兜底：拿不到原生路径时用 `$HOME/Documents`（沙盒进程的 HOME
            // 指向当前容器根）。两者都失败时留空（下载逻辑会明确报错），
            // 绝不退回相对路径——那会写进不可预期的进程 cwd。
            .or_else(|| {
                std::env::var("HOME")
                    .ok()
                    .filter(|h| !h.is_empty())
                    .map(|h| format!("{h}/Documents/AlgerMusic"))
            })
            .unwrap_or_default()
    }
    #[cfg(not(target_os = "ios"))]
    {
        dirs::audio_dir()
            .or_else(|| dirs::home_dir().map(|h| h.join("Music")))
            .map(|p| p.join("AlgerMusic"))
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_else(|| ".".to_string())
    }
}

/// iOS 当前沙盒的 `Documents` 目录。
///
/// 用原生 `NSFileManager` 取 **当前容器** 的 Documents（沙盒容器 UUID 在
/// 重装 / 升级后会变化，任何持久化的绝对路径都可能失效）；
/// 拿不到时回退到 `dirs::document_dir()`（即 `$HOME/Documents`）。
#[cfg(target_os = "ios")]
fn ios_documents_dir() -> Option<PathBuf> {
    use objc2_foundation::{NSFileManager, NSSearchPathDirectory, NSSearchPathDomainMask};

    let native = {
        let manager = NSFileManager::defaultManager();
        manager
            .URLForDirectory_inDomain_appropriateForURL_create_error(
                NSSearchPathDirectory::DocumentDirectory,
                NSSearchPathDomainMask::UserDomainMask,
                None,
                true,
            )
            .ok()
            .and_then(|url| url.path())
            .map(|path| PathBuf::from(path.to_string()))
    };
    native.or_else(dirs::document_dir)
}

/// 下载目录归一化。
///
/// `current` 是「当前沙盒目录」（iOS 传入，其它平台传空串表示不覆盖）。
///
/// - iOS：沙盒容器 UUID 在重装 / 升级后会变化，`session.json` 里持久化的
///   绝对路径会指向一个**已不存在的旧容器**，下载时必然报
///   「创建下载目录失败」。因此只要能算出当前目录，就以它为准，
///   完全不信任持久化值。
/// - 其它平台：保留用户自己选择的目录（`current` 为空）。
pub(crate) fn normalize_download_dir(persisted: &str, current: &str) -> String {
    if current.trim().is_empty() {
        persisted.to_string()
    } else {
        current.to_string()
    }
}

/// 会话存储（内存 + 磁盘）。
pub struct SessionStore {
    path: PathBuf,
    data: RwLock<SessionData>,
    /// 串行事务锁：任何「读 → 改 → 落盘 → 提交内存」序列必须整体持有，
    /// 防止两个写入口交错导致丢更新 / 内存与磁盘分叉（审查 R1）。
    txn: Mutex<()>,
    /// 载入问题（解析失败 / 读取失败）。存在问题时 **不覆盖原文件**，
    /// 并把原始内容备份后明确上报，绝不静默用默认值顶替用户数据。
    load_issue: parking_lot::RwLock<Option<String>>,
}

/// 会话数据目录名。
///
/// 试用构建（`scripts/install-dist.sh` 注入 `ALGER_TRIAL`，identifier 为
/// `com.alger.music.trial`）使用独立目录 `AlgerMusicPlayer.trial`，
/// 与开发 / 测试数据隔离；`scripts/clean.sh` 保留所有持久用户数据。
fn session_dir_name() -> &'static str {
    if option_env!("ALGER_TRIAL").is_some() {
        "AlgerMusicPlayer.trial"
    } else {
        "AlgerMusicPlayer"
    }
}

/// 写「损坏备份」的安全副本（审查 E0-1）。
///
/// 要求：
/// - 权限 **0600**（损坏字节里可能含完整凭证，绝不能用默认 0644）；
/// - 文件名唯一（时间戳 + pid + 毫秒 + 序号），**不覆盖**既有备份；
/// - `create_new`（O_CREAT|O_EXCL）天然拒绝跟随符号链接（避免写穿任意文件）；
/// - 失败只报错，绝不退回不安全的直写。
pub(crate) fn write_secure_backup(path: &Path, bytes: &[u8]) -> Result<PathBuf, String> {
    use std::io::Write;
    for attempt in 0..32u32 {
        let stamp = chrono::Local::now().format("%Y%m%d-%H%M%S");
        let name = format!(
            "json.corrupt-{}-{}-{}-{}",
            stamp,
            std::process::id(),
            crate::now_millis(),
            attempt
        );
        let backup = path.with_extension(&name);
        #[cfg(unix)]
        let opened = {
            use std::os::unix::fs::OpenOptionsExt;
            std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&backup)
        };
        #[cfg(not(unix))]
        let opened = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&backup);
        let mut file = match opened {
            Ok(f) => f,
            // 同名已存在：换下一个序号，**绝不覆盖**既有备份。
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(format!("创建备份 {} 失败（{}）", backup.display(), e)),
        };
        if let Err(e) = file.write_all(bytes) {
            let _ = std::fs::remove_file(&backup);
            return Err(format!("写入备份 {} 失败（{}）", backup.display(), e));
        }
        let _ = file.sync_all();
        drop(file);
        return Ok(backup);
    }
    Err("创建备份失败：同名文件持续冲突".into())
}

impl SessionStore {
    /// 打开或创建会话存储。
    ///
    /// 数据保护规则（预审清单 P1 / P2）：
    /// - 文件不存在 → 首次运行，写入默认值；
    /// - 文件存在但读取 / 解析失败 → **保留原文件不动**，另存
    ///   `session.json.corrupt-<时间戳>` 备份，内存中使用默认值，
    ///   并通过 [`Self::load_issue`] 明确上报，绝不写回默认值覆盖原文件；
    /// - 读取成功 → 不重写文件（保持启动前后字节一致）。
    pub fn open() -> SessionStore {
        let dir = dirs::config_dir()
            .or_else(|| dirs::home_dir().map(|h| h.join(".config")))
            .unwrap_or_else(|| PathBuf::from("."));
        let dir = dir.join(session_dir_name());
        let _ = std::fs::create_dir_all(&dir);
        Self::open_at(dir.join("session.json"))
    }

    /// 按 **指定路径** 打开会话存储（桥接进程与测试使用；桌面端默认路径见
    /// [`Self::open`]）。数据保护规则与 [`Self::open`] 相同。
    pub fn open_at(path: PathBuf) -> SessionStore {
        let store = SessionStore {
            path,
            data: RwLock::new(SessionData::default()),
            txn: Mutex::new(()),
            load_issue: parking_lot::RwLock::new(None),
        };

        match std::fs::read(&store.path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                // 首次运行：初始化默认文件。
                if let Err(write_err) = store.persist() {
                    *store.load_issue.write() = Some(write_err);
                }
            }
            Err(e) => {
                // 文件存在但读不了（权限等）：保留原文件，**拒绝写入**，不用默认值覆盖。
                let msg = format!(
                    "无法读取会话文件（{}）：{}；已保留原文件，本次会话拒绝写入会话文件以保护数据，处理原文件后重启应用可恢复",
                    store.path.display(),
                    e
                );
                *store.load_issue.write() = Some(msg);
            }
            Ok(bytes) => match serde_json::from_slice::<SessionData>(&bytes) {
                Ok(data) => {
                    // 正常载入：不重写文件（P1：启动前后内容一致）。
                    *store.data.write() = data;
                }
                Err(e) => {
                    // 解析失败：备份原文件并保留，不用默认值覆盖。
                    // 备份必须安全（审查 E0-1）：0600、唯一名、不跟随符号链接、
                    // 不覆盖既有文件——损坏字节里可能含完整凭证。
                    let backup_msg = match write_secure_backup(&store.path, &bytes) {
                        Ok(backup) => format!("，原文件已备份为 {}", backup.display()),
                        Err(be) => format!("，备份失败（{}），原文件保持原样", be),
                    };
                    let msg = format!(
                        "会话文件解析失败（{}）{}；已保留原文件并拒绝写入以保护数据。请先从备份恢复或修正会话文件后重启应用",
                        e, backup_msg
                    );
                    *store.load_issue.write() = Some(msg);
                }
            },
        }
        store
    }

    /// 载入问题说明（正常载入时为 `None`）。用于界面明确提示，不静默降级。
    pub fn load_issue(&self) -> Option<String> {
        self.load_issue.read().clone()
    }

    /// 当前生效的下载目录。
    ///
    /// iOS：固定为 **当前沙盒** 的 `Documents/AlgerMusic`（每次按当前容器
    /// 重算，不使用持久化值，因为沙盒容器 UUID 会变）；
    /// 其它平台：用户在设置里选择的目录。
    pub fn download_dir(&self) -> String {
        #[cfg(target_os = "ios")]
        {
            let current = default_download_dir();
            let normalized = normalize_download_dir(&self.get().download_dir, &current);
            if !normalized.trim().is_empty() {
                return normalized;
            }
        }
        // 其它平台：保留用户选择的目录（current 为空 → 不覆盖）
        normalize_download_dir(&self.get().download_dir, "")
    }

    /// 读取当前会话。
    pub fn get(&self) -> SessionData {
        self.data.read().clone()
    }

    /// 事务式更新（审查 R1）：闭包在 **内存快照** 上修改，随后整体完成
    /// 「落盘 → 提交内存」，全程持有串行锁。
    ///
    /// - 落盘被拒绝 / 失败：内存保持旧值，返回具体原因，内存与磁盘不分叉；
    /// - 并发写入口（登录、设置、Cookie）在此串行化，不会用旧快照互相覆盖；
    /// - 网络校验等耗时操作必须放在本方法 **之外**，事务内只做内存修改与落盘。
    pub fn update<T>(&self, f: impl FnOnce(&mut SessionData) -> T) -> Result<T, String> {
        self.try_update(|data| Ok(f(data)))
    }

    /// [`Self::update`] 的可中止变体：闭包返回 `Err` 时 **不落盘也不提交**
    /// （用于「快照已过期就放弃本次写」的场景，例如启动校验写回前发现
    /// Cookie 已被替换）。闭包 `Ok` 时语义与 [`Self::update`] 完全一致。
    pub fn try_update<T>(
        &self,
        f: impl FnOnce(&mut SessionData) -> Result<T, String>,
    ) -> Result<T, String> {
        let _txn = self.txn.lock();
        let mut data = self.data.read().clone();
        let out = f(&mut data)?;
        // 先落盘成功后才提交内存（审查 P0-2 / R1）
        self.persist_data(&data)?;
        *self.data.write() = data;
        Ok(out)
    }

    /// 覆盖当前会话并落盘（事务式，见 [`Self::update`]）。
    pub fn set(&self, data: SessionData) -> Result<(), String> {
        self.update(move |current| *current = data)
    }

    /// 只更新 Cookie。落盘成功后才生效；失败时内存保持旧值。
    pub fn set_cookie(&self, cookie: &str) -> Result<(), String> {
        let cookie = cookie.to_string();
        self.update(move |data| data.cookie = cookie)
    }

    /// 清除 Cookie 与账号信息（保留其他设置）。落盘成功后才生效。
    pub fn clear_login(&self) -> Result<(), String> {
        self.update(|data| {
            data.cookie.clear();
            data.account = None;
        })
    }

    /// 写盘（同目录临时文件 + 原子替换，临时文件创建即 0600 且唯一）。
    ///
    /// 数据保护（预审 F2）：
    /// - `load_issue` 存在时 **拒绝写入**，原文件保持不动；
    /// - 会话路径是符号链接时拒绝替换（避免摧毁链接语义）；
    /// - 原子替换失败时保持原文件不动并返回错误，**不退化为非原子直写**；
    /// - rename 前 fsync 临时文件与目录，缩小掉电窗口。
    pub fn persist(&self) -> Result<(), String> {
        // 与事务串行化：避免 persist 在别的提交「落盘后、提交前」插入，
        // 写出旧快照后又被新提交覆盖造成顺序错乱（审查 R1）。
        let _txn = self.txn.lock();
        let data = self.data.read().clone();
        self.persist_data(&data)
    }

    /// 把 `data` 原子写入会话文件（不读内存、不改内存）。
    fn persist_data(&self, data: &SessionData) -> Result<(), String> {
        if let Some(issue) = self.load_issue.read().clone() {
            return Err(format!(
                "会话文件存在问题，已拒绝写入以保护原文件：{}",
                issue
            ));
        }
        // 符号链接（含悬空链接）：拒绝替换，保护链接指向的数据与语义
        if let Ok(m) = std::fs::symlink_metadata(&self.path) {
            if m.file_type().is_symlink() {
                return Err(format!(
                    "会话文件 {} 是符号链接，拒绝替换以保护其指向的数据",
                    self.path.display()
                ));
            }
        }
        let json =
            serde_json::to_string_pretty(data).map_err(|e| format!("会话序列化失败：{}", e))?;
        let n = TMP_COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let tmp = self.path.with_extension(format!(
            "json.alger-{}-{}-{}.tmp",
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
            Ok(()) => Ok(()),
            Err(e) => {
                // 保持原文件不动，仅清理临时文件
                let _ = std::fs::remove_file(&tmp);
                Err(format!("会话写入失败（原文件未改动）：{}", e))
            }
        }
    }

    /// 存储路径（用于在界面中提示用户 Cookie 存放位置，不含凭证内容）。
    pub fn path(&self) -> String {
        self.path.to_string_lossy().to_string()
    }
}

/// 测试产物根目录：源码被 src-tauri 与 crates/alger-core 两处编译，
/// `env!("CARGO_MANIFEST_DIR")` 不同，统一向上找带 `src-tauri` 的仓库根。
#[cfg(test)]
pub(crate) fn session_test_artifacts() -> std::path::PathBuf {
    let manifest = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    for cand in [
        manifest.join("../.artifacts"),
        manifest.join("../../.artifacts"),
    ] {
        if cand
            .parent()
            .map(|p| p.join("src-tauri").is_dir())
            .unwrap_or(false)
        {
            return cand;
        }
    }
    manifest.join("../../.artifacts")
}

#[cfg(test)]
mod tests {

    /// 故障注入用：把目录临时改成 **只读**（制造落盘失败），
    /// 离开作用域时 **自动恢复写权限**（RAII）。
    ///
    /// 没有 RAII 时，断言 panic 会跳过手写的还原语句，
    /// 目录留在 `0o500` → 后续 `remove_dir_all` 失败 → 清理不掉。
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
            let mut perm = match std::fs::metadata(&self.path) {
                Ok(meta) => meta.permissions(),
                Err(_) => std::fs::Permissions::from_mode(0o700),
            };
            perm.set_mode(0o700);
            let _ = std::fs::set_permissions(&self.path, perm);
        }
    }

    use super::*;

    #[test]
    fn defaults_are_sane() {
        let s = SessionData::default();
        assert_eq!(s.quality, "higher");
        assert!(s.sources.contains(&"pyncmd".to_string()));
        assert!(!s.download_dir.is_empty());
    }

    #[test]
    fn session_roundtrip() {
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join(super::session_test_artifacts())
            .join(format!("alger-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("session.json");
        let data = SessionData {
            cookie: "MUSIC_U=abc".into(),
            quality: "exhigh".into(),
            sources: vec!["kugou".into()],
            download_dir: "/tmp/x".into(),
            account: None,
        };
        std::fs::write(&path, serde_json::to_string(&data).unwrap()).unwrap();
        let loaded: SessionData =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(loaded.cookie, "MUSIC_U=abc");
        assert_eq!(loaded.quality, "exhigh");
        assert_eq!(loaded.sources, vec!["kugou".to_string()]);
        std::fs::remove_dir_all(&dir).ok();
    }

    /// P1：正常载入时启动 **不重写** session.json（字节保持一致）。
    #[test]
    fn open_does_not_rewrite_existing_session() {
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join(super::session_test_artifacts())
            .join(format!("alger-open-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("session.json");
        let raw = "{\"cookie\":\"MUSIC_U=keep\",\"quality\":\"lossless\",\"sources\":[\"pyncmd\"],\"download_dir\":\"/tmp/m\",\"account\":{\"userId\":7,\"nickname\":\"n\",\"avatarUrl\":\"a\",\"vipType\":0}}";
        std::fs::write(&path, raw).unwrap();
        let before = sha256_hex(raw.as_bytes());
        let store = SessionStore::open_at(path.clone());
        assert!(store.load_issue().is_none());
        assert_eq!(store.get().cookie, "MUSIC_U=keep");
        let after_bytes = std::fs::read(&path).unwrap();
        assert_eq!(before, sha256_hex(&after_bytes));
        std::fs::remove_dir_all(&dir).ok();
    }

    /// P2：解析失败时保留原文件、另存备份、明确上报，不写默认值。
    #[test]
    fn corrupt_session_is_preserved_and_reported() {
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join(super::session_test_artifacts())
            .join(format!("alger-corrupt-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("session.json");
        let raw = "{\"cookie\":\"MUSIC_U=precious\",brok";
        std::fs::write(&path, raw).unwrap();
        let store = SessionStore::open_at(path.clone());
        let issue = store.load_issue();
        assert!(issue.is_some(), "解析失败必须明确上报");
        assert!(issue.as_deref().unwrap().contains("备份"));
        // 原文件字节保持不变
        assert_eq!(std::fs::read(&path).unwrap(), raw.as_bytes());
        // 内存为默认值，但没有把默认值写回磁盘
        assert_eq!(store.get().cookie, "");
        assert_eq!(std::fs::read(&path).unwrap(), raw.as_bytes());
        // 备份文件存在且内容一致
        let mut found = None;
        for entry in std::fs::read_dir(&dir).unwrap() {
            let name = entry.unwrap().file_name().to_string_lossy().to_string();
            if name.starts_with("session.json.corrupt-") {
                found = Some(dir.join(name));
            }
        }
        let backup = found.expect("应生成 corrupt 备份文件");
        assert_eq!(std::fs::read(&backup).unwrap(), raw.as_bytes());
        std::fs::remove_dir_all(&dir).ok();
    }

    /// F2：解析失败后任何写入都必须被拒绝，原文件字节不变。
    #[test]
    fn writes_are_refused_after_corrupt_load() {
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join(super::session_test_artifacts())
            .join(format!("alger-refuse-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("session.json");
        let raw = "{\"cookie\":\"MUSIC_U=precious\",brok";
        std::fs::write(&path, raw).unwrap();
        let store = SessionStore::open_at(path.clone());
        assert!(store.load_issue().is_some());

        let err = store
            .set(SessionData {
                cookie: "MUSIC_U=evil".into(),
                ..Default::default()
            })
            .expect_err("load_issue 存在时写入必须被拒绝");
        assert!(err.contains("拒绝写入"), "错误必须说明拒绝写入：{}", err);
        assert_eq!(
            std::fs::read(&path).unwrap(),
            raw.as_bytes(),
            "原文件必须字节不变"
        );
        // set_cookie / clear_login 同样拒绝
        assert!(store.set_cookie("MUSIC_U=evil").is_err());
        assert!(store.clear_login().is_err());
        assert_eq!(std::fs::read(&path).unwrap(), raw.as_bytes());
        // P0-2：被拒后内存必须保持默认值（未提交新值），不得与磁盘分叉
        assert_eq!(store.get().cookie, "", "被拒后内存不得保留未落盘的凭证");
        std::fs::remove_dir_all(&dir).ok();
    }

    /// P0-2：落盘失败（只读目录）后内存必须回滚，旧值仍在、磁盘未写。
    #[cfg(unix)]
    #[test]
    fn failed_persist_rolls_back_memory() {
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join(super::session_test_artifacts())
            .join(format!("alger-rollback-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("session.json");
        std::fs::write(&path, r#"{"cookie":"MUSIC_U=original"}"#).unwrap();
        let store = SessionStore::open_at(path.clone());
        assert!(store.load_issue().is_none());

        // 目录只读：落盘失败
        let _read_only = ReadOnlyDir::enter(&dir);
        let err = store
            .set_cookie("MUSIC_U=changed")
            .expect_err("只读目录落盘必须失败");

        assert!(
            err.contains("未改动") || err.contains("失败"),
            "错误需具体：{}",
            err
        );
        // 内存回滚：仍是旧值
        assert_eq!(
            store.get().cookie,
            "MUSIC_U=original",
            "落盘失败后内存必须保持旧值"
        );
        // 磁盘未写
        assert_eq!(
            std::fs::read(&path).unwrap(),
            br#"{"cookie":"MUSIC_U=original"}"#,
            "落盘失败后磁盘必须保持旧值"
        );
        drop(_read_only);
        std::fs::remove_dir_all(&dir).expect("权限故障夹具应可清理");
    }

    /// F2：读失败（权限问题）时同样拒绝写入，文件保持原样。
    #[cfg(unix)]
    #[test]
    fn unreadable_session_is_never_overwritten() {
        use std::os::unix::fs::PermissionsExt;
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join(super::session_test_artifacts())
            .join(format!("alger-unreadable-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("session.json");
        let raw = "{\"cookie\":\"MUSIC_U=keepme\",\"quality\":\"lossless\",\"sources\":[],\"download_dir\":\"/tmp\",\"account\":null}";
        std::fs::write(&path, raw).unwrap();
        let meta_before = std::fs::metadata(&path).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o000)).unwrap();
        let store = SessionStore::open_at(path.clone());
        assert!(store.load_issue().is_some(), "读失败必须上报 load_issue");
        let result = store.set(SessionData::default());
        // 恢复权限以便断言与清理（先记录结果）
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(result.is_err(), "读失败后写入必须被拒绝");
        let meta_after = std::fs::metadata(&path).unwrap();
        assert_eq!(meta_before.len(), meta_after.len(), "文件大小不得变化");
        assert_eq!(
            meta_before.modified().unwrap(),
            meta_after.modified().unwrap(),
            "文件 mtime 不得变化（未被重写）"
        );
        assert_eq!(std::fs::read(&path).unwrap(), raw.as_bytes());
        std::fs::remove_dir_all(&dir).ok();
    }

    /// persist 原子替换失败时保持原文件不动（不退化为非原子直写）。
    #[cfg(unix)]
    #[test]
    fn persist_failure_keeps_original_file() {
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join(super::session_test_artifacts())
            .join(format!("alger-persist-fail-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("session.json");
        let raw = "{\"cookie\":\"MUSIC_U=keep\",\"quality\":\"higher\",\"sources\":[],\"download_dir\":\"/tmp\",\"account\":null}";
        std::fs::write(&path, raw).unwrap();
        // 目录只读 → 临时文件写入失败 → persist 报错、原文件不动
        let _read_only = ReadOnlyDir::enter(&dir);
        let store = SessionStore::open_at(path.clone());
        assert!(store.load_issue().is_none());
        let result = store.set(SessionData {
            cookie: "MUSIC_U=new".into(),
            ..Default::default()
        });
        assert!(result.is_err(), "只读目录下写入必须失败");
        assert_eq!(
            std::fs::read(&path).unwrap(),
            raw.as_bytes(),
            "原文件必须字节不变"
        );
        // 目录内没有残留 tmp
        let leftovers: Vec<String> = std::fs::read_dir(&dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().to_string())
            .filter(|n| n.ends_with(".tmp"))
            .collect();
        assert!(leftovers.is_empty(), "不应残留临时文件：{:?}", leftovers);
        drop(_read_only);
        std::fs::remove_dir_all(&dir).expect("权限故障夹具应可清理");
    }

    /// 不存在的文件属于首次运行：初始化默认文件。
    #[test]
    fn missing_session_file_is_initialized() {
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join(super::session_test_artifacts())
            .join(format!("alger-missing-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("session.json");
        let store = SessionStore::open_at(path.clone());
        assert!(store.load_issue().is_none());
        assert!(path.exists());
        assert_eq!(store.get().quality, DEFAULT_QUALITY);
        std::fs::remove_dir_all(&dir).ok();
    }

    fn sha256_hex(data: &[u8]) -> String {
        // 仅用于测试比对：Rust 无内置 sha256，这里用长度 + 简单滚动哈希即可
        // 检测「文件被重写」——格式化差异必然改变字节内容与哈希。
        let mut h: u64 = 0xcbf29ce484222325;
        for b in data {
            h ^= *b as u64;
            h = h.wrapping_mul(0x100000001b3);
        }
        format!("{:016x}-{}", h, data.len())
    }

    /// 迁移场景：重装 / 升级后沙盒容器 UUID 变化，`session.json` 里持久化的
    /// 绝对下载目录指向**旧容器**。归一化后必须改用当前容器的目录，
    /// 否则下载必然报「创建下载目录失败」。
    #[test]
    fn stale_persisted_download_dir_is_replaced_by_current_one() {
        let persisted = "/var/mobile/Containers/Data/Application/OLD-UUID/Documents/AlgerMusic";
        let current = "/var/mobile/Containers/Data/Application/NEW-UUID/Documents/AlgerMusic";
        assert_eq!(normalize_download_dir(persisted, current), current);
    }

    /// 算不出当前目录时退回持久化值（桌面端行为不变）。
    #[test]
    fn persisted_download_dir_is_kept_when_no_current_dir() {
        let persisted = "/Users/someone/Music/AlgerMusic";
        assert_eq!(normalize_download_dir(persisted, ""), persisted);
    }

    /// 持久化值为空、当前目录可用时必须用当前目录，
    /// 绝不能退化成相对路径（会写进不可预期的进程 cwd）。
    #[test]
    fn empty_persisted_download_dir_falls_back_to_current_dir() {
        let current = "/var/mobile/Containers/Data/Application/NEW-UUID/Documents/AlgerMusic";
        assert_eq!(normalize_download_dir("", current), current);
        assert!(!normalize_download_dir("", current).is_empty());
    }

    /// E0-1：损坏备份必须 0600（损坏字节可能含完整凭证），且不覆盖既有备份。
    #[cfg(unix)]
    #[test]
    fn corrupt_backup_is_private_and_never_overwrites() {
        use std::os::unix::fs::PermissionsExt;
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join(super::session_test_artifacts())
            .join(format!("alger-backup-mode-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("session.json");
        let raw = "{\"cookie\":\"MUSIC_U=precious\",brok";
        std::fs::write(&path, raw).unwrap();
        // 预置一个同名段的既有备份（模拟碰撞），内容不得被覆盖
        let preexisting = dir.join(format!(
            "session.json.corrupt-{}",
            chrono::Local::now().format("%Y%m%d-%H%M%S")
        ));
        std::fs::write(&preexisting, b"PRE-EXISTING-BACKUP").unwrap();

        let store = SessionStore::open_at(path.clone());
        assert!(store.load_issue().is_some());

        let mut backups = Vec::new();
        for entry in std::fs::read_dir(&dir).unwrap() {
            let entry = entry.unwrap();
            let name = entry.file_name().to_string_lossy().to_string();
            if name.starts_with("session.json.corrupt-") {
                backups.push(entry.path());
            }
        }
        assert!(
            backups.len() >= 2,
            "应生成新备份且保留既有备份：{:?}",
            backups
        );
        // 新备份（内容为损坏原文）权限必须是 0600
        let fresh = backups
            .iter()
            .find(|b| **b != preexisting)
            .expect("应存在新备份");
        let mode = std::fs::metadata(fresh).unwrap().permissions().mode() & 0o777;
        assert_eq!(
            mode,
            0o600,
            "备份 {} 权限必须是 0600，实际 {:04o}",
            fresh.display(),
            mode
        );
        // 既有备份内容保持不变
        assert_eq!(
            std::fs::read(&preexisting).unwrap(),
            b"PRE-EXISTING-BACKUP".to_vec(),
            "同名既有备份不得被覆盖"
        );
        // 新备份内容与损坏原文一致
        assert_eq!(std::fs::read(fresh).unwrap(), raw.as_bytes());
        std::fs::remove_dir_all(&dir).ok();
    }

    /// E0-1：备份路径是符号链接时必须拒绝写入（不得写穿到目标文件）。
    #[cfg(unix)]
    #[test]
    fn corrupt_backup_refuses_symlink_target() {
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join(super::session_test_artifacts())
            .join(format!("alger-backup-link-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("session.json");
        let raw = "{\"cookie\":\"MUSIC_U=precious\",brok";
        std::fs::write(&path, raw).unwrap();

        let victim_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join(super::session_test_artifacts())
            .join(format!("alger-backup-link-victim-{}", std::process::id()));
        std::fs::create_dir_all(&victim_dir).unwrap();
        let victim = victim_dir.join("victim.txt");
        std::fs::write(&victim, b"IMPORTANT-VICTIM-DATA").unwrap();

        // 为当前秒前后若干时间戳预置同名符号链接
        let now = chrono::Local::now();
        for delta in -2i64..=2 {
            let stamp = (now + chrono::Duration::seconds(delta)).format("%Y%m%d-%H%M%S");
            let link = dir.join(format!("session.json.corrupt-{}", stamp));
            let _ = std::fs::remove_file(&link);
            let _ = std::os::unix::fs::symlink(&victim, &link);
        }

        let store = SessionStore::open_at(path.clone());
        assert!(store.load_issue().is_some());
        assert_eq!(
            std::fs::read(&victim).unwrap(),
            b"IMPORTANT-VICTIM-DATA".to_vec(),
            "备份不得写穿符号链接目标"
        );
        std::fs::remove_dir_all(&dir).ok();
        std::fs::remove_dir_all(&victim_dir).ok();
    }

    /// R1：两个线程并发更新 **不同字段**，双方都不得丢更新；
    /// 内存与磁盘必须一致。
    #[test]
    fn concurrent_updates_to_different_fields_do_not_lose_writes() {
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join(super::session_test_artifacts())
            .join(format!("alger-concurrent-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("session.json");
        std::fs::write(&path, r#"{"cookie":"MUSIC_U=original","quality":"higher"}"#).unwrap();
        let store = std::sync::Arc::new(SessionStore::open_at(path.clone()));
        assert!(store.load_issue().is_none());

        let mut handles = Vec::new();
        for i in 0..8 {
            let store = std::sync::Arc::clone(&store);
            handles.push(std::thread::spawn(move || {
                if i % 2 == 0 {
                    store
                        .set_cookie(&format!("MUSIC_U=thread-{}", i))
                        .expect("set_cookie");
                } else {
                    store
                        .update(|d| d.quality = format!("quality-{}", i))
                        .expect("update quality");
                }
            }));
        }
        for h in handles {
            h.join().unwrap();
        }

        // 内存里两类更新都在（最后一个写入者生效，但绝不能丢整类）
        let mem = store.get();
        assert!(
            mem.cookie.starts_with("MUSIC_U=thread-"),
            "cookie：{}",
            mem.cookie
        );
        assert!(
            mem.quality.starts_with("quality-"),
            "quality：{}",
            mem.quality
        );
        // 磁盘与内存一致
        let disk: SessionData = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(disk.cookie, mem.cookie, "磁盘与内存必须一致");
        assert_eq!(disk.quality, mem.quality, "磁盘与内存必须一致");
        // 并发交错后文件仍是合法 JSON（原子写未被截断）
        let _raw: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        std::fs::remove_dir_all(&dir).ok();
    }

    /// R1：try_update 闭包拒绝时不落盘也不提交内存。
    #[test]
    fn try_update_rejection_leaves_memory_and_disk_untouched() {
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join(super::session_test_artifacts())
            .join(format!("alger-try-update-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("session.json");
        let raw = r#"{"cookie":"MUSIC_U=keep","quality":"higher"}"#;
        std::fs::write(&path, raw).unwrap();
        let store = SessionStore::open_at(path.clone());

        let err = store
            .try_update::<()>(|data| {
                if data.cookie == "MUSIC_U=keep" {
                    return Err("快照已过期，放弃写回".into());
                }
                data.quality = "lossless".into();
                Ok(())
            })
            .expect_err("闭包拒绝时必须返回错误");
        assert!(err.contains("放弃写回"), "{}", err);
        assert_eq!(store.get().quality, "higher", "拒绝后内存不得提交");
        assert_eq!(
            std::fs::read(&path).unwrap(),
            raw.as_bytes(),
            "拒绝后磁盘不得写入"
        );

        // 闭包 Ok 时正常提交
        store
            .try_update(|data| {
                data.quality = "lossless".into();
                Ok(())
            })
            .unwrap();
        assert_eq!(store.get().quality, "lossless");
        let disk: SessionData = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(disk.quality, "lossless");
        std::fs::remove_dir_all(&dir).ok();
    }
}
