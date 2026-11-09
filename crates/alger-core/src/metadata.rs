//! 在线匹配元信息（E5）：MusicBrainz / Cover Art Archive / AcoustID。
//!
//! 契约（与桥接层 `meta.*` 一一对应）：
//! - `meta.search {title,artist,durationMs?,limit?,token?}` → `{candidates:[Candidate]}`
//! - `meta.lookup {recordingId,token?}` → `{candidate:Candidate}`
//! - `meta.release {releaseId,recordingId?,token?}` → `{release:Release,tracks:[Track]}`
//! - `meta.artwork {releaseId,token?}` → `{artworkBase64,mimeType,releaseId}`
//! - `meta.fingerprint {path,apiKey,fpcalcPath?,token?}` → `{candidates:[Candidate]}`
//! - `meta.cancel {token}` → `{cancelled:true}`
//!
//! 关键约束：
//! - **取消**：所有 `meta.*` 方法的 `token` 可选；`meta.cancel` 必须让原请求
//!   返回 `Cancelled` 错误（不得悬挂），并由该请求 **杀 + 回收** 自己的
//!   `fpcalc` 子进程；取消等待不阻塞其它请求（每请求独立令牌 + `select!`）。
//! - **限速**：MusicBrainz ≤ 1 rps（进程全局共享限速器）、AcoustID ≤ 3 rps、
//!   Cover Art Archive ≤ 1 rps；等待同样可被取消。
//! - **有界**：HTTP 超时 + 响应体大小上限；MusicBrainz 响应缓存有界（条目数 +
//!   有效期），缓存不参与取消语义（命中缓存立即返回）。
//! - **User-Agent**：带可联系信息（MusicBrainz 公共接口要求）。
//! - **封面**：`/release/{mbid}/front` 是 307 跳转，必须跟随重定向；404 明确
//!   表示「无封面」；仅在用户确认发行版本后按 `releaseId` 取。
//! - **指纹**：AcoustID key 由调用方提供（缺失 → 明确报错）；`fpcalc` 缺失 →
//!   明确报错（不做任何静默降级）。

use std::collections::HashMap;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use base64::Engine as _;
use futures_util::StreamExt as _;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::sync::Notify;
use url::Url;

use crate::now_millis;

/// MusicBrainz 根地址（默认官方地址；测试可用环境变量覆盖）。
pub const MUSICBRAINZ_BASE_DEFAULT: &str = "https://musicbrainz.org";
/// Cover Art Archive 根地址（默认官方地址）。
pub const COVER_ART_BASE_DEFAULT: &str = "https://coverartarchive.org";
/// AcoustID 根地址（默认官方地址）。
pub const ACOUSTID_BASE_DEFAULT: &str = "https://api.acoustid.org";
/// 带可联系信息的 User-Agent（MusicBrainz 公共接口要求提供联系方式）。
pub const USER_AGENT: &str = "AlgerMusic/5.2.0 ( https://github.com/algerkong/AlgerMusicPlayer )";

/// 响应体上限（JSON）。
const MAX_JSON_BYTES: usize = 8 * 1024 * 1024;
/// 响应体上限（封面图片）：4 MiB。
pub const MAX_IMAGE_BYTES: usize = 4 * 1024 * 1024;
/// MusicBrainz 最小请求间隔（≤ 1 rps）。
const MUSICBRAINZ_INTERVAL: Duration = Duration::from_millis(1000);
/// Cover Art Archive 最小请求间隔（≤ 1 rps）。
const COVER_ART_INTERVAL: Duration = Duration::from_millis(1000);
/// AcoustID 最小请求间隔（≤ 3 rps）。
const ACOUSTID_INTERVAL: Duration = Duration::from_millis(340);
/// HTTP 超时。
const HTTP_TIMEOUT: Duration = Duration::from_secs(20);
/// 连接超时。
const HTTP_CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// 缓存条目上限。
const CACHE_MAX_ENTRIES: usize = 64;
/// 缓存有效期。
const CACHE_TTL: Duration = Duration::from_secs(30 * 60);
/// 指纹候选的 MusicBrainz 补全数量上限（每条都要 1 次 MB 请求，受 1 rps 限制）。
const FINGERPRINT_ENRICH_LIMIT: usize = 3;
/// fpcalc 总超时（跑太久必须显式报错，不得无限等待）。
const FPCALC_TIMEOUT: Duration = Duration::from_secs(60);
/// fpcalc 单个输出流的读取上限。
const FPCALC_MAX_OUTPUT: usize = 1024 * 1024;
/// fpcalc 输出读取的收尾等待上限（后代进程继承管道时不得挂住）。
const FPCALC_READER_TIMEOUT: Duration = Duration::from_secs(5);
/// 子进程 kill 后 wait 回收的上限。
const CHILD_REAP_TIMEOUT: Duration = Duration::from_secs(5);

// ---------------------------------------------------------------------------
// 错误
// ---------------------------------------------------------------------------

/// 元信息错误。
#[derive(Debug, thiserror::Error)]
pub enum MetadataError {
    /// 请求被取消（`meta.cancel`）。
    #[error("请求已取消")]
    Cancelled,
    /// 缺少 AcoustID API key。
    #[error("缺少 AcoustID API key（请在调用时提供 apiKey）")]
    MissingApiKey,
    /// 找不到 fpcalc。
    #[error(
        "找不到 fpcalc（{0}）：请安装 Chromaprint（fpcalc）并用 fpcalcPath 指定可执行文件路径"
    )]
    FpcalcMissing(String),
    /// 目标文件不存在。
    #[error("文件不存在：{0}")]
    FileMissing(String),
    /// 网络错误。
    #[error("网络请求失败：{0}")]
    Network(String),
    /// 请求超时。
    #[error("请求超时")]
    Timeout,
    /// HTTP 状态码错误。
    #[error("HTTP {status}：{message}")]
    Http { status: u16, message: String },
    /// 响应解析失败。
    #[error("响应解析失败：{0}")]
    Decode(String),
    /// 无封面（CAA 返回 404）。
    #[error("该发行版本没有封面")]
    NoArtwork,
    /// 响应体超限。
    #[error("响应体超过上限（{size} 字节 > {limit} 字节）")]
    TooLarge { size: usize, limit: usize },
    /// 参数错误。
    #[error("{0}")]
    Invalid(String),
}

// ---------------------------------------------------------------------------
// 数据模型（与契约字段一一对应）
// ---------------------------------------------------------------------------

/// 录音候选。
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Candidate {
    /// MusicBrainz 录音 MBID。
    pub recording_id: String,
    pub title: String,
    pub artist: String,
    /// 时长（毫秒，未知 0）。
    pub duration_ms: u64,
    /// 匹配分（0～100）。
    pub score: u32,
    /// ISRC 列表。
    pub isrcs: Vec<String>,
    /// 该录音的发行版本。
    pub releases: Vec<Release>,
}

/// 发行版本。
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Release {
    /// MusicBrainz 发行 MBID。
    pub id: String,
    pub title: String,
    /// 发行日期（未知空串）。
    pub date: String,
    /// 发行国家（未知空串）。
    pub country: String,
    /// 专辑艺人（未知空串）。
    pub album_artist: String,
}

/// 发行版本内的曲目。
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Track {
    /// MusicBrainz 录音 MBID。
    pub recording_id: String,
    pub title: String,
    pub artist: String,
    /// 曲序（未知 0）。
    pub track: u32,
    /// 碟序（未知 0）。
    pub disc: u32,
    /// 时长（毫秒，未知 0）。
    pub duration_ms: u64,
}

/// 发行版本详情（`meta.release` 的响应体）。
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ReleaseDetail {
    pub release: Release,
    pub tracks: Vec<Track>,
}

/// 封面（`meta.artwork` 的响应体）。
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Artwork {
    /// base64 编码的图片数据。
    pub artwork_base64: String,
    /// MIME 类型（如 `image/jpeg`）。
    pub mime_type: String,
    /// 发行 MBID。
    pub release_id: String,
}

/// 搜索请求。
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchRequest {
    pub title: String,
    #[serde(default)]
    pub artist: String,
    #[serde(default)]
    pub duration_ms: Option<u64>,
    #[serde(default)]
    pub limit: Option<u32>,
    #[serde(default)]
    pub token: Option<String>,
}

/// 录音查询请求。
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LookupRequest {
    pub recording_id: String,
    #[serde(default)]
    pub token: Option<String>,
}

/// 发行版本查询请求。
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReleaseRequest {
    pub release_id: String,
    #[serde(default)]
    pub recording_id: Option<String>,
    #[serde(default)]
    pub token: Option<String>,
}

/// 封面请求。
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ArtworkRequest {
    pub release_id: String,
    #[serde(default)]
    pub token: Option<String>,
}

/// 指纹请求。
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FingerprintRequest {
    pub path: String,
    /// 调用方提供的 AcoustID API key（缺失 → 明确报错）。
    #[serde(default)]
    pub api_key: String,
    /// 可选：fpcalc 可执行文件路径。
    #[serde(default)]
    pub fpcalc_path: Option<String>,
    #[serde(default)]
    pub token: Option<String>,
}

// ---------------------------------------------------------------------------
// 取消令牌
// ---------------------------------------------------------------------------

/// 取消令牌：一次请求一个，令牌之间互不影响。
#[derive(Clone, Debug)]
pub struct CancelToken {
    cancelled: Arc<AtomicBool>,
    notify: Arc<Notify>,
}

impl Default for CancelToken {
    fn default() -> Self {
        Self::new()
    }
}

impl CancelToken {
    pub fn new() -> Self {
        Self {
            cancelled: Arc::new(AtomicBool::new(false)),
            notify: Arc::new(Notify::new()),
        }
    }

    /// 是否已取消。
    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::SeqCst)
    }

    /// 置位取消并唤醒等待者（幂等）。
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::SeqCst);
        self.notify.notify_waiters();
    }

    /// 等待取消（被取消时返回）。
    pub async fn cancelled(&self) {
        loop {
            if self.is_cancelled() {
                return;
            }
            let notified = self.notify.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            if self.is_cancelled() {
                return;
            }
            notified.await;
        }
    }
}

/// 取消状态：`token` → 在途令牌，以及 **预取消墓碑**。
///
/// `meta.cancel` 可能先于请求登记到达（桥接把每个请求派发到独立任务，
/// 取消与请求之间存在真实竞态）。墓碑让「先到的取消」不丢失：请求随后
/// 登记时立即承接这次取消。
///
/// **登记 / 取消 / 注销必须原子协调**：两者共用 **同一把锁**，否则会出现
/// 「cancel 先查不到在途请求 → register 登记并查不到墓碑 → cancel 才写
/// 墓碑」的丢取消窗口。
#[derive(Default)]
struct CancelState {
    /// 在途请求：`token` → (令牌, 引用计数)。
    live: HashMap<String, (CancelToken, usize)>,
    /// 预取消墓碑：`token` → 写入时间（超 TTL 失效）。
    tombstones: HashMap<String, Instant>,
}

/// 墓碑有效期（先到的取消最多等这么久；之后同名 token 视为新请求）。
const TOMBSTONE_TTL: Duration = Duration::from_secs(30);
/// 墓碑容量上限（防止无限增长）。
const TOMBSTONE_MAX: usize = 256;

/// 取消登记表（单一状态锁，保证 register / cancel / release 原子协调）。
#[derive(Default)]
struct CancelRegistry {
    state: Mutex<CancelState>,
}

impl CancelRegistry {
    /// 登记请求：若该 token 已有 **预取消墓碑**，立即承接取消。
    fn register(&self, key: &str) -> CancelToken {
        let mut state = self.state.lock().expect("cancel registry poisoned");
        let token = {
            let entry = state
                .live
                .entry(key.to_string())
                .or_insert_with(|| (CancelToken::new(), 0));
            entry.1 += 1;
            entry.0.clone()
        };
        // 承接先到的取消（墓碑只消费一次，避免影响后续独立请求）。
        if state.tombstones.remove(key).is_some() {
            token.cancel();
        }
        token
    }

    /// 注销（RAII 守卫 drop 时调用）。
    fn release(&self, key: &str) {
        let mut state = self.state.lock().expect("cancel registry poisoned");
        if let Some(entry) = state.live.get_mut(key) {
            entry.1 = entry.1.saturating_sub(1);
            if entry.1 == 0 {
                state.live.remove(key);
                // 该 token 的请求已结束：残留墓碑不得影响后续同名请求。
                state.tombstones.remove(key);
            }
        }
    }

    /// 取消：`token` 已登记 → 立即取消；未登记 → 记 **墓碑**（随后登记时承接）。
    ///
    /// 返回是否命中在途请求（`false` = 只记了墓碑）。
    fn cancel(&self, key: &str) -> bool {
        let mut state = self.state.lock().expect("cancel registry poisoned");
        if let Some((token, _)) = state.live.get(key) {
            // `CancelToken::cancel` 只动原子位与通知，不回调登记表 → 不会重入死锁。
            token.cancel();
            return true;
        }
        // 未登记：记墓碑（与上面的查询在同一临界区内，不会丢取消）。
        let now = Instant::now();
        state
            .tombstones
            .retain(|_, at| now.duration_since(*at) < TOMBSTONE_TTL);
        if !state.tombstones.contains_key(key) {
            if state.tombstones.len() >= TOMBSTONE_MAX {
                // 容量上限：淘汰最旧的一条墓碑。
                let mut oldest: Option<String> = None;
                let mut oldest_at = now;
                for (k, at) in state.tombstones.iter() {
                    if oldest.is_none() || *at < oldest_at {
                        oldest_at = *at;
                        oldest = Some(k.clone());
                    }
                }
                if let Some(k) = oldest {
                    state.tombstones.remove(&k);
                }
            }
            state.tombstones.insert(key.to_string(), now);
        }
        false
    }
}

/// 取消登记的 RAII 守卫：请求被取消、失败 **或 future 被 abort**（桥接退出时）
/// 时都会自动注销，避免登记表泄漏。
struct CancelGuard<'a> {
    registry: &'a CancelRegistry,
    key: Option<String>,
    token: CancelToken,
}

impl<'a> CancelGuard<'a> {
    fn token(&self) -> &CancelToken {
        &self.token
    }
}

impl Drop for CancelGuard<'_> {
    fn drop(&mut self) {
        if let Some(key) = self.key.take() {
            self.registry.release(&key);
        }
    }
}

// ---------------------------------------------------------------------------
// 限速器与缓存
// ---------------------------------------------------------------------------

/// 最小间隔限速器。
///
/// 用 **tokio 互斥闸** 串行调度：拿到闸的请求等到「上一次实际发出时刻 +
/// 最小间隔」才继续，等待期间闸不释放，因此不会出现「多个请求在同一时刻
/// 一起发出」违反速率上限的情况。取消时直接放弃本次时隙（**不留空洞**），
/// 不会让后续请求被一个已经被取消的等待拖住。
#[derive(Debug)]
pub struct RateLimiter {
    min_interval: Duration,
    /// 闸 + 「下一次允许发出的时刻」。
    gate: tokio::sync::Mutex<Instant>,
}

impl RateLimiter {
    pub fn new(min_interval: Duration) -> Self {
        Self {
            min_interval,
            gate: tokio::sync::Mutex::new(Instant::now()),
        }
    }

    /// 预约一个请求时隙并等待；返回实际等待时长。
    ///
    /// 三个边界都必须可取消，且 **不得消耗时隙**：
    /// - 排队等闸（gate 未打开）时被取消 → 立即返回，不占时隙；
    /// - 拿到闸后、等待间隔期间被取消 → 立即返回，不占时隙；
    /// - 已经取消的请求即使恰好拿到闸（等待为 0）→ 立即返回，不占时隙。
    pub async fn acquire(&self, token: Option<&CancelToken>) -> Result<Duration, MetadataError> {
        // 等闸本身也要可取消：排在闸后面的请求被取消时立即返回。
        let mut next = match token {
            Some(t) => {
                tokio::select! {
                    biased;
                    _ = t.cancelled() => return Err(MetadataError::Cancelled),
                    g = self.gate.lock() => g,
                }
            }
            None => self.gate.lock().await,
        };
        // 拿到闸后再查一次（可能是在等闸期间被取消的）。
        if let Some(t) = token {
            if t.is_cancelled() {
                return Err(MetadataError::Cancelled);
            }
        }
        let now = Instant::now();
        let start = if *next <= now { now } else { *next };
        let wait = start.saturating_duration_since(now);
        if !wait.is_zero() {
            match token {
                Some(t) => {
                    tokio::select! {
                        biased;
                        _ = t.cancelled() => return Err(MetadataError::Cancelled),
                        _ = tokio::time::sleep(wait) => {}
                    }
                }
                None => tokio::time::sleep(wait).await,
            }
        }
        // 消费时隙前再查一次：已取消的请求不得推进 next（否则会留下空洞）。
        if let Some(t) = token {
            if t.is_cancelled() {
                return Err(MetadataError::Cancelled);
            }
        }
        // 按 **实际** 发出时刻推进：调度被推迟时不会提前占用未来时隙。
        *next = Instant::now() + self.min_interval;
        Ok(wait)
    }

    /// 最小间隔（供测试与诊断）。
    pub fn min_interval(&self) -> Duration {
        self.min_interval
    }
}

/// 有界缓存（条目数 + 有效期上限）。
#[derive(Debug)]
pub struct BoundedCache {
    entries: Mutex<Vec<(String, Value, Instant)>>,
    max: usize,
    ttl: Duration,
}

impl BoundedCache {
    fn new(max: usize, ttl: Duration) -> Self {
        Self {
            entries: Mutex::new(Vec::new()),
            max,
            ttl,
        }
    }

    fn get(&self, key: &str) -> Option<Value> {
        let mut guard = self.entries.lock().expect("cache poisoned");
        let now = Instant::now();
        guard.retain(|(_, _, at)| now.duration_since(*at) < self.ttl);
        guard
            .iter()
            .find(|(k, _, _)| k == key)
            .map(|(_, v, _)| v.clone())
    }

    fn put(&self, key: &str, value: Value) {
        let mut guard = self.entries.lock().expect("cache poisoned");
        let now = Instant::now();
        guard.retain(|(_, _, at)| now.duration_since(*at) < self.ttl);
        if let Some(slot) = guard.iter_mut().find(|(k, _, _)| k == key) {
            slot.1 = value;
            slot.2 = now;
            return;
        }
        if guard.len() >= self.max {
            // 淘汰最旧的一条（保持缓存有界）。
            let mut oldest = 0usize;
            let mut oldest_at = guard[0].2;
            for (i, (_, _, at)) in guard.iter().enumerate() {
                if *at < oldest_at {
                    oldest_at = *at;
                    oldest = i;
                }
            }
            guard.remove(oldest);
        }
        guard.push((key.to_string(), value, now));
    }

    /// 当前条目数（测试用）。
    pub fn len(&self) -> usize {
        self.entries.lock().expect("cache poisoned").len()
    }

    /// 是否为空（测试用）。
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

// ---------------------------------------------------------------------------
// 配置
// ---------------------------------------------------------------------------

/// 服务配置（生产默认值 + 测试覆盖）。
#[derive(Debug, Clone)]
pub struct MetadataConfig {
    pub musicbrainz_base: String,
    pub cover_art_base: String,
    pub acoustid_base: String,
    pub musicbrainz_interval: Duration,
    pub cover_art_interval: Duration,
    pub acoustid_interval: Duration,
    pub timeout: Duration,
    pub max_json_bytes: usize,
    pub max_image_bytes: usize,
    /// 默认 fpcalc 路径（None = 在 PATH 中查找）。
    pub fpcalc_path: Option<PathBuf>,
}

impl Default for MetadataConfig {
    fn default() -> Self {
        Self {
            musicbrainz_base: MUSICBRAINZ_BASE_DEFAULT.to_string(),
            cover_art_base: COVER_ART_BASE_DEFAULT.to_string(),
            acoustid_base: ACOUSTID_BASE_DEFAULT.to_string(),
            musicbrainz_interval: MUSICBRAINZ_INTERVAL,
            cover_art_interval: COVER_ART_INTERVAL,
            acoustid_interval: ACOUSTID_INTERVAL,
            timeout: HTTP_TIMEOUT,
            max_json_bytes: MAX_JSON_BYTES,
            max_image_bytes: MAX_IMAGE_BYTES,
            fpcalc_path: None,
        }
    }
}

impl MetadataConfig {
    /// 从环境变量读取（测试可覆盖服务地址与限速间隔；生产使用默认值）。
    pub fn from_env() -> Self {
        let mut cfg = MetadataConfig::default();
        if let Ok(v) = std::env::var("ALGER_METADATA_MUSICBRAINZ_BASE") {
            if !v.trim().is_empty() {
                cfg.musicbrainz_base = v.trim().trim_end_matches('/').to_string();
            }
        }
        if let Ok(v) = std::env::var("ALGER_METADATA_COVERART_BASE") {
            if !v.trim().is_empty() {
                cfg.cover_art_base = v.trim().trim_end_matches('/').to_string();
            }
        }
        if let Ok(v) = std::env::var("ALGER_METADATA_ACOUSTID_BASE") {
            if !v.trim().is_empty() {
                cfg.acoustid_base = v.trim().trim_end_matches('/').to_string();
            }
        }
        if let Some(v) = env_millis("ALGER_MB_MIN_INTERVAL_MS") {
            cfg.musicbrainz_interval = Duration::from_millis(v);
        }
        if let Some(v) = env_millis("ALGER_CAA_MIN_INTERVAL_MS") {
            cfg.cover_art_interval = Duration::from_millis(v);
        }
        if let Some(v) = env_millis("ALGER_ACOUSTID_MIN_INTERVAL_MS") {
            cfg.acoustid_interval = Duration::from_millis(v);
        }
        if let Ok(v) = std::env::var("ALGER_FPCALC_PATH") {
            if !v.trim().is_empty() {
                cfg.fpcalc_path = Some(PathBuf::from(v.trim()));
            }
        }
        cfg
    }
}

fn env_millis(key: &str) -> Option<u64> {
    std::env::var(key)
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
}

/// 全局限速器：MusicBrainz / CAA / AcoustID 各一个，**进程内共享**，
/// 保证「全局 ≤ 1 rps」而不是「每客户端 1 rps」。
fn global_limiters() -> (Arc<RateLimiter>, Arc<RateLimiter>, Arc<RateLimiter>) {
    static MB: OnceLock<Arc<RateLimiter>> = OnceLock::new();
    static CAA: OnceLock<Arc<RateLimiter>> = OnceLock::new();
    static ACOUSTID: OnceLock<Arc<RateLimiter>> = OnceLock::new();
    let cfg = MetadataConfig::from_env();
    (
        MB.get_or_init(|| Arc::new(RateLimiter::new(cfg.musicbrainz_interval)))
            .clone(),
        CAA.get_or_init(|| Arc::new(RateLimiter::new(cfg.cover_art_interval)))
            .clone(),
        ACOUSTID
            .get_or_init(|| Arc::new(RateLimiter::new(cfg.acoustid_interval)))
            .clone(),
    )
}

// ---------------------------------------------------------------------------
// 服务
// ---------------------------------------------------------------------------

/// 元信息服务（MusicBrainz / CAA / AcoustID）。
pub struct MetadataService {
    http: reqwest::Client,
    cfg: MetadataConfig,
    mb_limiter: Arc<RateLimiter>,
    caa_limiter: Arc<RateLimiter>,
    acoustid_limiter: Arc<RateLimiter>,
    cache: Arc<BoundedCache>,
    cancels: CancelRegistry,
    fingerprint_enrich_limit: usize,
}

impl std::fmt::Debug for MetadataService {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MetadataService")
            .field("musicbrainz_base", &self.cfg.musicbrainz_base)
            .field("cover_art_base", &self.cfg.cover_art_base)
            .field("acoustid_base", &self.cfg.acoustid_base)
            .finish()
    }
}

impl MetadataService {
    /// 生产实例：限速器 **进程全局共享**。
    pub fn new() -> Self {
        let cfg = MetadataConfig::from_env();
        let (mb, caa, acoustid) = global_limiters();
        Self::build(cfg, mb, caa, acoustid)
    }

    /// 测试实例：使用配置里的独立限速器（间隔可控，确定性）。
    pub fn with_config(cfg: MetadataConfig) -> Self {
        let mb = Arc::new(RateLimiter::new(cfg.musicbrainz_interval));
        let caa = Arc::new(RateLimiter::new(cfg.cover_art_interval));
        let acoustid = Arc::new(RateLimiter::new(cfg.acoustid_interval));
        Self::build(cfg, mb, caa, acoustid)
    }

    fn build(
        cfg: MetadataConfig,
        mb: Arc<RateLimiter>,
        caa: Arc<RateLimiter>,
        acoustid: Arc<RateLimiter>,
    ) -> Self {
        let http = reqwest::Client::builder()
            .timeout(cfg.timeout)
            .connect_timeout(HTTP_CONNECT_TIMEOUT)
            .redirect(reqwest::redirect::Policy::limited(10))
            .user_agent(USER_AGENT)
            .build()
            .expect("build reqwest client");
        Self {
            http,
            cfg,
            mb_limiter: mb,
            caa_limiter: caa,
            acoustid_limiter: acoustid,
            cache: Arc::new(BoundedCache::new(CACHE_MAX_ENTRIES, CACHE_TTL)),
            cancels: CancelRegistry::default(),
            fingerprint_enrich_limit: FINGERPRINT_ENRICH_LIMIT,
        }
    }

    /// MusicBrainz 限速器（测试可检查是否进程全局共享）。
    pub fn musicbrainz_limiter(&self) -> Arc<RateLimiter> {
        Arc::clone(&self.mb_limiter)
    }

    /// 封面限速器。
    pub fn cover_art_limiter(&self) -> Arc<RateLimiter> {
        Arc::clone(&self.caa_limiter)
    }

    /// AcoustID 限速器。
    pub fn acoustid_limiter(&self) -> Arc<RateLimiter> {
        Arc::clone(&self.acoustid_limiter)
    }

    // ---------------- 取消 ----------------

    /// 取消某个 `token` 对应的在途请求。
    ///
    /// - 立即返回（不等待被取消的请求结束），因此 **不阻塞其它请求**；
    /// - 被取消的请求会返回 `MetadataError::Cancelled`；
    /// - 若该请求正在跑 `fpcalc`，取消会让它 **杀掉并回收** 子进程；
    /// - 若取消 **先于** 请求登记到达（桥接把请求派发到独立任务，存在真实
    ///   竞态），会记 **预取消墓碑**：请求随后登记时立即被取消，不会丢。
    pub fn cancel(&self, token: &str) -> bool {
        let key = token.trim();
        if key.is_empty() {
            return false;
        }
        self.cancels.cancel(key)
    }

    fn begin(&self, token: Option<&str>) -> Option<CancelGuard<'_>> {
        let key = token.map(str::trim).filter(|t| !t.is_empty())?;
        let token = self.cancels.register(key);
        Some(CancelGuard {
            registry: &self.cancels,
            key: Some(key.to_string()),
            token,
        })
    }

    // ---------------- 元信息查询 ----------------

    /// 按标题 / 艺人搜索录音候选。
    pub async fn search(&self, req: &SearchRequest) -> Result<Vec<Candidate>, MetadataError> {
        let title = req.title.trim();
        if title.is_empty() {
            return Err(MetadataError::Invalid("搜索标题不能为空".into()));
        }
        let artist = req.artist.trim();
        let limit = req.limit.unwrap_or(25).clamp(1, 100) as usize;
        let guard = self.begin(req.token.as_deref());
        let token = guard.as_ref().map(|g| g.token().clone());
        let result = self
            .search_inner(title, artist, req.duration_ms, limit, token)
            .await;
        result
    }

    async fn search_inner(
        &self,
        title: &str,
        artist: &str,
        duration_ms: Option<u64>,
        limit: usize,
        token: Option<CancelToken>,
    ) -> Result<Vec<Candidate>, MetadataError> {
        let query = build_recording_query(title, artist);
        let mut url = Url::parse(&format!("{}/ws/2/recording", self.cfg.musicbrainz_base))
            .map_err(|e| MetadataError::Invalid(format!("MusicBrainz 地址无效：{}", e)))?;
        url.query_pairs_mut()
            .append_pair("query", &query)
            .append_pair("fmt", "json")
            .append_pair("limit", &limit.to_string());
        let json = self.mb_get_json(url.as_str(), token.as_ref()).await?;
        let mut candidates = parse_recording_search(&json);
        for c in candidates.iter_mut() {
            c.score = score_candidate(title, artist, duration_ms, c);
        }
        candidates.sort_by(|a, b| {
            b.score
                .cmp(&a.score)
                .then_with(|| a.title.cmp(&b.title))
                .then_with(|| a.recording_id.cmp(&b.recording_id))
        });
        candidates.truncate(limit);
        Ok(candidates)
    }

    /// 按录音 MBID 查询单个候选。
    pub async fn lookup(&self, req: &LookupRequest) -> Result<Candidate, MetadataError> {
        let mbid = req.recording_id.trim();
        if mbid.is_empty() {
            return Err(MetadataError::Invalid("缺少 recordingId".into()));
        }
        let guard = self.begin(req.token.as_deref());
        let token = guard.as_ref().map(|g| g.token().clone());
        let result = self.lookup_inner(mbid, token).await;
        result
    }

    async fn lookup_inner(
        &self,
        mbid: &str,
        token: Option<CancelToken>,
    ) -> Result<Candidate, MetadataError> {
        let url = self.recording_url(mbid)?;
        let json = self.mb_get_json(url.as_str(), token.as_ref()).await?;
        parse_recording(&json)
            .ok_or_else(|| MetadataError::Decode("MusicBrainz 录音响应缺少 id / title".into()))
    }

    /// 查询发行版本及其曲目。
    pub async fn release(&self, req: &ReleaseRequest) -> Result<ReleaseDetail, MetadataError> {
        let mbid = req.release_id.trim();
        if mbid.is_empty() {
            return Err(MetadataError::Invalid("缺少 releaseId".into()));
        }
        let guard = self.begin(req.token.as_deref());
        let token = guard.as_ref().map(|g| g.token().clone());
        let result = self.release_inner(mbid, token).await;
        result
    }

    async fn release_inner(
        &self,
        mbid: &str,
        token: Option<CancelToken>,
    ) -> Result<ReleaseDetail, MetadataError> {
        if !is_mbid(mbid) {
            return Err(MetadataError::Invalid(format!(
                "不是合法的 MusicBrainz MBID：{}",
                mbid
            )));
        }
        let url = format!(
            "{}/ws/2/release/{}?inc=recordings+artist-credits&fmt=json",
            self.cfg.musicbrainz_base, mbid
        );
        let json = self.mb_get_json(&url, token.as_ref()).await?;
        parse_release(&json)
            .map(|(release, tracks)| ReleaseDetail { release, tracks })
            .ok_or_else(|| MetadataError::Decode("MusicBrainz 发行响应缺少 id / title".into()))
    }

    /// 取发行版本封面（用户确认发行版本后才调用）。
    pub async fn artwork(&self, req: &ArtworkRequest) -> Result<Artwork, MetadataError> {
        let mbid = req.release_id.trim();
        if mbid.is_empty() {
            return Err(MetadataError::Invalid("缺少 releaseId".into()));
        }
        let guard = self.begin(req.token.as_deref());
        let token = guard.as_ref().map(|g| g.token().clone());
        let result = self.artwork_inner(mbid, token).await;
        result
    }

    async fn artwork_inner(
        &self,
        mbid: &str,
        token: Option<CancelToken>,
    ) -> Result<Artwork, MetadataError> {
        // 封面限速（CAA 与 MB 同为 1 rps 量级，独立限速器）。
        acquire(&self.caa_limiter, token.as_ref()).await?;
        let url = format!("{}/release/{}/front", self.cfg.cover_art_base, mbid);
        let (bytes, mime) = cancellable(token.as_ref(), async {
            let resp = self
                .http
                .get(&url)
                .header("User-Agent", USER_AGENT)
                .send()
                .await
                .map_err(map_reqwest_error)?;
            let status = resp.status();
            if status.as_u16() == 404 {
                return Err(MetadataError::NoArtwork);
            }
            if !status.is_success() {
                let body = read_capped(resp, self.cfg.max_json_bytes)
                    .await
                    .unwrap_or_default();
                return Err(MetadataError::Http {
                    status: status.as_u16(),
                    message: truncate(&String::from_utf8_lossy(&body), 200),
                });
            }
            let mime = resp
                .headers()
                .get(reqwest::header::CONTENT_TYPE)
                .and_then(|v| v.to_str().ok())
                .map(|v| v.split(';').next().unwrap_or("").trim().to_string())
                .filter(|v| !v.is_empty())
                .unwrap_or_else(|| "image/jpeg".to_string());
            if let Some(len) = resp.content_length() {
                if len > self.cfg.max_image_bytes as u64 {
                    return Err(MetadataError::TooLarge {
                        size: len as usize,
                        limit: self.cfg.max_image_bytes,
                    });
                }
            }
            let bytes = read_capped(resp, self.cfg.max_image_bytes).await?;
            Ok((bytes, mime))
        })
        .await?;
        Ok(Artwork {
            artwork_base64: base64::engine::general_purpose::STANDARD.encode(&bytes),
            mime_type: mime,
            release_id: mbid.to_string(),
        })
    }

    /// 音频指纹匹配（Chromaprint → AcoustID → MusicBrainz 补全）。
    pub async fn fingerprint(
        &self,
        req: &FingerprintRequest,
    ) -> Result<Vec<Candidate>, MetadataError> {
        let api_key = req.api_key.trim();
        if api_key.is_empty() {
            return Err(MetadataError::MissingApiKey);
        }
        // 配置类错误优先明确报出：fpcalc 缺失 → 明确错误（不静默降级）。
        let fpcalc = self.resolve_fpcalc(req.fpcalc_path.as_deref())?;
        let path = Path::new(req.path.trim());
        if req.path.trim().is_empty() {
            return Err(MetadataError::Invalid("缺少 path".into()));
        }
        if !path.exists() {
            return Err(MetadataError::FileMissing(req.path.clone()));
        }
        let guard = self.begin(req.token.as_deref());
        let token = guard.as_ref().map(|g| g.token().clone());
        let result = self.fingerprint_inner(api_key, &fpcalc, path, token).await;
        result
    }

    async fn fingerprint_inner(
        &self,
        api_key: &str,
        fpcalc: &Path,
        path: &Path,
        token: Option<CancelToken>,
    ) -> Result<Vec<Candidate>, MetadataError> {
        let (duration_sec, fingerprint) = self.run_fpcalc(fpcalc, path, token.clone()).await?;
        let json = self
            .acoustid_lookup(api_key, duration_sec, &fingerprint, token.as_ref())
            .await?;
        let mut candidates = parse_acoustid_results(&json);
        // 用 MusicBrainz 补全 ISRC / 发行版本（受 1 rps 限制，只补前几条）。
        let enrich = self.fingerprint_enrich_limit.min(candidates.len());
        for c in candidates.iter_mut().take(enrich) {
            if c.recording_id.is_empty() {
                continue;
            }
            let url = match self.recording_url(&c.recording_id) {
                Ok(u) => u,
                Err(_) => continue,
            };
            if let Ok(json) = self.mb_get_json(url.as_str(), token.as_ref()).await {
                if let Some(full) = parse_recording(&json) {
                    if !full.isrcs.is_empty() {
                        c.isrcs = full.isrcs;
                    }
                    if !full.releases.is_empty() {
                        c.releases = full.releases;
                    }
                    if c.duration_ms == 0 {
                        c.duration_ms = full.duration_ms;
                    }
                    if c.artist.is_empty() {
                        c.artist = full.artist;
                    }
                }
            }
        }
        Ok(candidates)
    }

    fn recording_url(&self, mbid: &str) -> Result<String, MetadataError> {
        if !is_mbid(mbid) {
            return Err(MetadataError::Invalid(format!(
                "不是合法的 MusicBrainz MBID：{}",
                mbid
            )));
        }
        Ok(format!(
            "{}/ws/2/recording/{}?inc=artist-credits+releases+isrcs&fmt=json",
            self.cfg.musicbrainz_base, mbid
        ))
    }

    // ---------------- HTTP ----------------

    async fn mb_get_json(
        &self,
        url: &str,
        token: Option<&CancelToken>,
    ) -> Result<Value, MetadataError> {
        if let Some(v) = self.cache.get(url) {
            return Ok(v);
        }
        acquire(&self.mb_limiter, token).await?;
        let text = cancellable(token, self.get_text(url, self.cfg.max_json_bytes)).await?;
        let value: Value = serde_json::from_str(&text)
            .map_err(|e| MetadataError::Decode(format!("{}: {}", e, truncate(&text, 200))))?;
        self.cache.put(url, value.clone());
        Ok(value)
    }

    async fn get_text(&self, url: &str, limit: usize) -> Result<String, MetadataError> {
        let resp = self
            .http
            .get(url)
            .header("User-Agent", USER_AGENT)
            .send()
            .await
            .map_err(map_reqwest_error)?;
        let status = resp.status();
        if !status.is_success() {
            let body = read_capped(resp, limit).await.unwrap_or_default();
            return Err(MetadataError::Http {
                status: status.as_u16(),
                message: truncate(&String::from_utf8_lossy(&body), 200),
            });
        }
        let bytes = read_capped(resp, limit).await?;
        String::from_utf8(bytes).map_err(|e| MetadataError::Decode(format!("非 UTF-8 响应：{}", e)))
    }

    async fn acoustid_lookup(
        &self,
        api_key: &str,
        duration_sec: f64,
        fingerprint: &str,
        token: Option<&CancelToken>,
    ) -> Result<Value, MetadataError> {
        acquire(&self.acoustid_limiter, token).await?;
        let url = format!("{}/v2/lookup", self.cfg.acoustid_base);
        let form = [
            ("client", api_key.to_string()),
            ("duration", format!("{:.3}", duration_sec)),
            ("fingerprint", fingerprint.to_string()),
            ("meta", "recordings+releasegroups+compress".to_string()),
        ];
        let (status, bytes) = cancellable(token, async {
            let resp = self
                .http
                .post(&url)
                .header("User-Agent", USER_AGENT)
                .form(&form)
                .send()
                .await
                .map_err(map_reqwest_error)?;
            let status = resp.status();
            let bytes = read_capped(resp, self.cfg.max_json_bytes).await?;
            Ok((status, bytes))
        })
        .await?;
        let text = String::from_utf8_lossy(&bytes).to_string();
        let value: Value = serde_json::from_str(&text)
            .map_err(|e| MetadataError::Decode(format!("{}: {}", e, truncate(&text, 200))))?;
        if !status.is_success() {
            let message = value
                .get("error")
                .and_then(|e| e.get("message"))
                .and_then(|m| m.as_str())
                .map(|s| s.to_string())
                .unwrap_or_else(|| truncate(&text, 200));
            return Err(MetadataError::Http {
                status: status.as_u16(),
                message,
            });
        }
        if let Some(status_text) = value.get("status").and_then(|s| s.as_str()) {
            if status_text == "error" {
                let message = value
                    .get("error")
                    .and_then(|e| e.get("message"))
                    .and_then(|m| m.as_str())
                    .unwrap_or("AcoustID 返回错误")
                    .to_string();
                return Err(MetadataError::Http {
                    status: status.as_u16(),
                    message,
                });
            }
        }
        Ok(value)
    }

    // ---------------- fpcalc ----------------

    /// 解析 fpcalc 可执行文件路径；缺失时 **明确报错**（不静默降级）。
    pub fn resolve_fpcalc(&self, explicit: Option<&str>) -> Result<PathBuf, MetadataError> {
        if let Some(p) = explicit.map(str::trim).filter(|p| !p.is_empty()) {
            let path = PathBuf::from(p);
            if path.exists() {
                return Ok(path);
            }
            return Err(MetadataError::FpcalcMissing(p.to_string()));
        }
        if let Some(cfg_path) = &self.cfg.fpcalc_path {
            if cfg_path.exists() {
                return Ok(cfg_path.clone());
            }
            return Err(MetadataError::FpcalcMissing(cfg_path.display().to_string()));
        }
        match find_in_path("fpcalc") {
            Some(p) => Ok(p),
            None => Err(MetadataError::FpcalcMissing("fpcalc".to_string())),
        }
    }

    /// 运行 fpcalc 取时长与指纹。
    ///
    /// 约束（审查要求）：
    /// - **总超时**：fpcalc 跑太久必须显式报超时错误，不能无限等待；
    /// - **输出上限**：stdout / stderr 各自有上限，超限显式报错；
    /// - **精确 kill + 回收**：取消 / 超时都只杀 **自己启动的** 子进程，并
    ///   `wait` 回收（不留僵尸）；管道读取任务有界回收（后代进程继承管道
    ///   时不会把请求挂住）。
    async fn run_fpcalc(
        &self,
        fpcalc: &Path,
        path: &Path,
        token: Option<CancelToken>,
    ) -> Result<(f64, String), MetadataError> {
        let mut cmd = tokio::process::Command::new(fpcalc);
        cmd.arg("-json").arg(path);
        cmd.stdout(Stdio::piped());
        cmd.stderr(Stdio::piped());
        cmd.kill_on_drop(true);
        let mut child = cmd.spawn().map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                MetadataError::FpcalcMissing(fpcalc.display().to_string())
            } else {
                MetadataError::Network(format!("无法启动 fpcalc：{}", e))
            }
        })?;
        let stdout = child.stdout.take();
        let stderr = child.stderr.take();
        let mut out_task = tokio::spawn(read_capped_pipe(stdout, FPCALC_MAX_OUTPUT));
        let mut err_task = tokio::spawn(read_capped_pipe(stderr, FPCALC_MAX_OUTPUT));

        let status = match token.as_ref() {
            Some(t) => {
                tokio::select! {
                    biased;
                    _ = t.cancelled() => {
                        kill_and_reap(&mut child).await;
                        abort_readers(&mut out_task, &mut err_task).await;
                        return Err(MetadataError::Cancelled);
                    }
                    r = tokio::time::timeout(FPCALC_TIMEOUT, child.wait()) => {
                        match r {
                            Ok(Ok(st)) => st,
                            Ok(Err(e)) => {
                                abort_readers(&mut out_task, &mut err_task).await;
                                return Err(MetadataError::Network(format!("fpcalc 执行失败：{}", e)));
                            }
                            Err(_) => {
                                kill_and_reap(&mut child).await;
                                abort_readers(&mut out_task, &mut err_task).await;
                                return Err(MetadataError::Timeout);
                            }
                        }
                    }
                }
            }
            None => match tokio::time::timeout(FPCALC_TIMEOUT, child.wait()).await {
                Ok(Ok(st)) => st,
                Ok(Err(e)) => {
                    abort_readers(&mut out_task, &mut err_task).await;
                    return Err(MetadataError::Network(format!("fpcalc 执行失败：{}", e)));
                }
                Err(_) => {
                    kill_and_reap(&mut child).await;
                    abort_readers(&mut out_task, &mut err_task).await;
                    return Err(MetadataError::Timeout);
                }
            },
        };
        let out = join_reader(&mut out_task, FPCALC_READER_TIMEOUT).await;
        let err = join_reader(&mut err_task, FPCALC_READER_TIMEOUT).await;
        if out.len() >= FPCALC_MAX_OUTPUT {
            return Err(MetadataError::TooLarge {
                size: out.len(),
                limit: FPCALC_MAX_OUTPUT,
            });
        }
        if !status.success() {
            let message = truncate(&String::from_utf8_lossy(&err), 200);
            return Err(MetadataError::Invalid(format!(
                "fpcalc 执行失败（{}）：{}",
                status.code().unwrap_or(-1),
                message
            )));
        }
        let text = String::from_utf8_lossy(&out).to_string();
        let value: Value = serde_json::from_str(&text)
            .map_err(|e| MetadataError::Decode(format!("fpcalc 输出无法解析：{}", e)))?;
        let duration = value
            .get("duration")
            .and_then(|d| d.as_f64())
            .ok_or_else(|| MetadataError::Decode("fpcalc 输出缺少 duration".into()))?;
        let fingerprint = value
            .get("fingerprint")
            .and_then(|f| f.as_str())
            .map(|s| s.to_string())
            .ok_or_else(|| MetadataError::Decode("fpcalc 输出缺少 fingerprint".into()))?;
        if fingerprint.trim().is_empty() {
            return Err(MetadataError::Decode("fpcalc 输出指纹为空".into()));
        }
        Ok((duration, fingerprint))
    }
}

impl Default for MetadataService {
    fn default() -> Self {
        Self::new()
    }
}

// ---------------------------------------------------------------------------
// 解析（纯函数，可离线回归）
// ---------------------------------------------------------------------------

/// 解析 MusicBrainz 录音搜索结果。
pub fn parse_recording_search(json: &Value) -> Vec<Candidate> {
    let list = json
        .get("recordings")
        .and_then(|r| r.as_array())
        .cloned()
        .unwrap_or_default();
    list.iter().filter_map(parse_recording).collect()
}

/// 解析单个 MusicBrainz 录音对象。
pub fn parse_recording(json: &Value) -> Option<Candidate> {
    let id = json.get("id").and_then(|i| i.as_str()).unwrap_or("");
    if id.is_empty() {
        return None;
    }
    let title = json
        .get("title")
        .and_then(|t| t.as_str())
        .unwrap_or("")
        .to_string();
    let artist = credit_text(json.get("artist-credit"));
    let duration_ms = json
        .get("length")
        .and_then(|l| l.as_i64())
        .unwrap_or(0)
        .max(0) as u64;
    let isrcs = json
        .get("isrcs")
        .and_then(|i| i.as_array())
        .map(|a| {
            a.iter()
                .filter_map(|x| x.as_str())
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect()
        })
        .unwrap_or_default();
    let releases = json
        .get("releases")
        .and_then(|r| r.as_array())
        .map(|a| a.iter().map(parse_release_entry).collect())
        .unwrap_or_default();
    Some(Candidate {
        recording_id: id.to_string(),
        title,
        artist,
        duration_ms,
        score: 0,
        isrcs,
        releases,
    })
}

fn parse_release_entry(v: &Value) -> Release {
    Release {
        id: v
            .get("id")
            .and_then(|i| i.as_str())
            .unwrap_or("")
            .to_string(),
        title: v
            .get("title")
            .and_then(|t| t.as_str())
            .unwrap_or("")
            .to_string(),
        date: v
            .get("date")
            .and_then(|d| d.as_str())
            .unwrap_or("")
            .to_string(),
        country: v
            .get("country")
            .and_then(|c| c.as_str())
            .unwrap_or("")
            .to_string(),
        album_artist: credit_text(v.get("artist-credit")),
    }
}

/// 解析 MusicBrainz 发行版本（发行信息 + 曲目）。
pub fn parse_release(json: &Value) -> Option<(Release, Vec<Track>)> {
    let id = json.get("id").and_then(|i| i.as_str()).unwrap_or("");
    if id.is_empty() {
        return None;
    }
    let release = Release {
        id: id.to_string(),
        title: json
            .get("title")
            .and_then(|t| t.as_str())
            .unwrap_or("")
            .to_string(),
        date: json
            .get("date")
            .and_then(|d| d.as_str())
            .unwrap_or("")
            .to_string(),
        country: json
            .get("country")
            .and_then(|c| c.as_str())
            .unwrap_or("")
            .to_string(),
        album_artist: credit_text(json.get("artist-credit")),
    };
    let mut tracks = Vec::new();
    if let Some(media) = json.get("media").and_then(|m| m.as_array()) {
        for m in media {
            let disc = m
                .get("position")
                .and_then(|p| p.as_i64())
                .unwrap_or(0)
                .max(0) as u32;
            if let Some(list) = m.get("tracks").and_then(|t| t.as_array()) {
                for t in list {
                    tracks.push(parse_track(t, disc));
                }
            }
        }
    }
    Some((release, tracks))
}

fn parse_track(v: &Value, disc: u32) -> Track {
    let position = v
        .get("position")
        .and_then(|p| p.as_i64())
        .filter(|p| *p > 0)
        .map(|p| p as u32);
    let number = position.or_else(|| {
        v.get("number")
            .and_then(|n| n.as_str())
            .and_then(|n| n.split('-').next())
            .and_then(|n| n.trim().parse::<u32>().ok())
    });
    Track {
        recording_id: v
            .get("id")
            .and_then(|i| i.as_str())
            .unwrap_or("")
            .to_string(),
        title: v
            .get("title")
            .and_then(|t| t.as_str())
            .unwrap_or("")
            .to_string(),
        artist: credit_text(v.get("artist-credit")),
        track: number.unwrap_or(0),
        disc,
        duration_ms: v.get("length").and_then(|l| l.as_i64()).unwrap_or(0).max(0) as u64,
    }
}

/// 解析 AcoustID 查询结果（录音候选）。
pub fn parse_acoustid_results(json: &Value) -> Vec<Candidate> {
    let results = json
        .get("results")
        .and_then(|r| r.as_array())
        .cloned()
        .unwrap_or_default();
    let mut out = Vec::new();
    for r in results {
        let score = r.get("score").and_then(|s| s.as_f64()).unwrap_or(0.0);
        let recordings = r
            .get("recordings")
            .and_then(|x| x.as_array())
            .cloned()
            .unwrap_or_default();
        for rec in recordings {
            let id = rec.get("id").and_then(|i| i.as_str()).unwrap_or("");
            if id.is_empty() {
                continue;
            }
            let artist = rec
                .get("artists")
                .and_then(|a| a.as_array())
                .map(|a| {
                    a.iter()
                        .filter_map(|x| x.get("name").and_then(|n| n.as_str()))
                        .collect::<Vec<_>>()
                        .join(" / ")
                })
                .unwrap_or_default();
            let duration_ms = rec
                .get("length")
                .and_then(|l| l.as_i64())
                .unwrap_or(0)
                .max(0) as u64;
            out.push(Candidate {
                recording_id: id.to_string(),
                title: rec
                    .get("title")
                    .and_then(|t| t.as_str())
                    .unwrap_or("")
                    .to_string(),
                artist,
                duration_ms,
                score: (score.clamp(0.0, 1.0) * 100.0).round() as u32,
                isrcs: Vec::new(),
                releases: Vec::new(),
            });
        }
    }
    out
}

/// 拼接 artist-credit（`{name}` 或 `{artist:{name}}`）。
pub fn credit_text(credit: Option<&Value>) -> String {
    let arr = match credit {
        Some(Value::Array(a)) => a,
        Some(Value::Object(o)) => {
            return o
                .get("name")
                .and_then(|n| n.as_str())
                .unwrap_or("")
                .to_string()
        }
        _ => return String::new(),
    };
    arr.iter()
        .map(|c| {
            c.get("name")
                .and_then(|n| n.as_str())
                .or_else(|| {
                    c.get("artist")
                        .and_then(|a| a.get("name"))
                        .and_then(|n| n.as_str())
                })
                .unwrap_or("")
                .trim()
                .to_string()
        })
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join(" / ")
}

/// 构造 MusicBrainz Lucene 查询。
pub fn build_recording_query(title: &str, artist: &str) -> String {
    let mut q = format!("recording:\"{}\"", escape_lucene(title.trim()));
    let artist = artist.trim();
    if !artist.is_empty() {
        q.push_str(&format!(" AND artist:\"{}\"", escape_lucene(artist)));
    }
    q
}

fn escape_lucene(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

/// 候选评分（0～100）：标题 / 艺人相似度 + 时长接近度。
pub fn score_candidate(
    query_title: &str,
    query_artist: &str,
    query_duration_ms: Option<u64>,
    candidate: &Candidate,
) -> u32 {
    let title_sim = similarity(query_title, &candidate.title);
    let artist_sim = if query_artist.trim().is_empty() {
        1.0
    } else {
        similarity(query_artist, &candidate.artist)
    };
    let duration_sim = match query_duration_ms {
        None => 0.5,
        Some(d) => {
            if candidate.duration_ms == 0 {
                0.5
            } else {
                let diff = (d as i64 - candidate.duration_ms as i64).abs();
                if diff <= 1_000 {
                    1.0
                } else if diff <= 3_000 {
                    0.8
                } else if diff <= 8_000 {
                    0.5
                } else {
                    0.1
                }
            }
        }
    };
    let local = 0.45 * title_sim + 0.30 * artist_sim + 0.25 * duration_sim;
    ((local * 100.0).round() as u32).min(100)
}

/// 归一化相似度（0～1）。
pub fn similarity(a: &str, b: &str) -> f64 {
    let a = normalize(a);
    let b = normalize(b);
    if a.is_empty() || b.is_empty() {
        return 0.0;
    }
    if a == b {
        return 1.0;
    }
    let ac: Vec<char> = a.chars().collect();
    let bc: Vec<char> = b.chars().collect();
    let dist = levenshtein(&ac, &bc) as f64;
    let max = ac.len().max(bc.len()) as f64;
    let mut score = 1.0 - dist / max;
    if contains_subsequence(&ac, &bc) || contains_subsequence(&bc, &ac) {
        score = score.max(0.85);
    }
    score.clamp(0.0, 1.0)
}

/// `needle` 是否是 `haystack` 的（连续）子序列。
fn contains_subsequence(haystack: &[char], needle: &[char]) -> bool {
    if needle.is_empty() {
        return true;
    }
    if needle.len() > haystack.len() {
        return false;
    }
    haystack.windows(needle.len()).any(|w| w == needle)
}

fn normalize(s: &str) -> String {
    s.chars()
        .filter(|c| !c.is_whitespace())
        .flat_map(|c| c.to_lowercase())
        .filter(|c| c.is_alphanumeric())
        .collect()
}

fn levenshtein(a: &[char], b: &[char]) -> usize {
    if a.is_empty() {
        return b.len();
    }
    if b.is_empty() {
        return a.len();
    }
    let mut prev: Vec<usize> = (0..=b.len()).collect();
    let mut cur = vec![0usize; b.len() + 1];
    for i in 1..=a.len() {
        cur[0] = i;
        for j in 1..=b.len() {
            let cost = if a[i - 1] == b[j - 1] { 0 } else { 1 };
            cur[j] = (prev[j] + 1).min(cur[j - 1] + 1).min(prev[j - 1] + cost);
        }
        std::mem::swap(&mut prev, &mut cur);
    }
    prev[b.len()]
}

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------

/// 限速等待（可被取消；取消不留空洞）。
async fn acquire(limiter: &RateLimiter, token: Option<&CancelToken>) -> Result<(), MetadataError> {
    limiter.acquire(token).await.map(|_| ())
}

/// 可取消地执行一段异步操作。
async fn cancellable<T>(
    token: Option<&CancelToken>,
    fut: impl Future<Output = Result<T, MetadataError>>,
) -> Result<T, MetadataError> {
    match token {
        None => fut.await,
        Some(t) => {
            tokio::select! {
                biased;
                _ = t.cancelled() => Err(MetadataError::Cancelled),
                r = fut => r,
            }
        }
    }
}

/// 读取响应体（带上限）。
async fn read_capped(resp: reqwest::Response, limit: usize) -> Result<Vec<u8>, MetadataError> {
    if let Some(len) = resp.content_length() {
        if len > limit as u64 {
            return Err(MetadataError::TooLarge {
                size: len as usize,
                limit,
            });
        }
    }
    let mut stream = resp.bytes_stream();
    let mut buf: Vec<u8> = Vec::new();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(map_reqwest_error)?;
        if buf.len() + chunk.len() > limit {
            return Err(MetadataError::TooLarge {
                size: buf.len() + chunk.len(),
                limit,
            });
        }
        buf.extend_from_slice(&chunk);
    }
    Ok(buf)
}

/// 读取子进程管道（**有上限**：读到上限即停止，不无限读）。
async fn read_capped_pipe<R>(pipe: Option<R>, limit: usize) -> Vec<u8>
where
    R: tokio::io::AsyncRead + Unpin,
{
    let mut pipe = match pipe {
        Some(p) => p,
        None => return Vec::new(),
    };
    let mut buf: Vec<u8> = Vec::new();
    let mut chunk = vec![0u8; 8192];
    loop {
        use tokio::io::AsyncReadExt as _;
        let n = match pipe.read(&mut chunk).await {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        if buf.len() + n > limit {
            let room = limit.saturating_sub(buf.len());
            buf.extend_from_slice(&chunk[..room]);
            break;
        }
        buf.extend_from_slice(&chunk[..n]);
    }
    buf
}

/// 杀掉 **自己启动的** 子进程并回收（有界等待，不留僵尸）。
async fn kill_and_reap(child: &mut tokio::process::Child) {
    let _ = child.start_kill();
    let _ = tokio::time::timeout(CHILD_REAP_TIMEOUT, child.wait()).await;
}

/// 有界回收管道读取任务（超时即 abort，避免被继承管道的后代挂住）。
async fn abort_readers(
    out: &mut tokio::task::JoinHandle<Vec<u8>>,
    err: &mut tokio::task::JoinHandle<Vec<u8>>,
) {
    out.abort();
    err.abort();
    let _ = out.await;
    let _ = err.await;
}

/// 有界回收管道读取任务并取回已读内容。
async fn join_reader(handle: &mut tokio::task::JoinHandle<Vec<u8>>, timeout: Duration) -> Vec<u8> {
    match tokio::time::timeout(timeout, &mut *handle).await {
        Ok(Ok(v)) => v,
        Ok(Err(_)) => Vec::new(),
        Err(_) => {
            handle.abort();
            Vec::new()
        }
    }
}

fn map_reqwest_error(e: reqwest::Error) -> MetadataError {
    if e.is_timeout() {
        return MetadataError::Timeout;
    }
    if e.is_decode() {
        return MetadataError::Decode(e.to_string());
    }
    MetadataError::Network(e.to_string())
}

fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        s.to_string()
    } else {
        s.chars().take(max).collect::<String>() + "..."
    }
}

/// 是否看起来像 MusicBrainz MBID（36 位 UUID）。
pub fn is_mbid(s: &str) -> bool {
    let s = s.trim();
    s.len() == 36
        && s.chars().all(|c| c.is_ascii_hexdigit() || c == '-')
        && s.matches('-').count() == 4
}

/// 在 PATH 中查找可执行文件。
pub fn find_in_path(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        if dir.as_os_str().is_empty() {
            continue;
        }
        let candidate = dir.join(name);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

/// 当前的 Unix 毫秒时间戳（供上游 `startTimestamp` 使用）。
pub fn unix_millis() -> u64 {
    now_millis()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_search_results_with_defaults() {
        let raw = json!({
            "count": 2,
            "recordings": [
                {
                    "id": "b1a9c0b9-d987-404e-a7db-3b00416af0c9",
                    "title": "Yesterday",
                    "length": 269000,
                    "score": 98,
                    "artist-credit": [
                        {"name": "The Beatles", "artist": {"id": "x", "name": "The Beatles"}}
                    ],
                    "isrcs": ["GBAYE0601498"],
                    "releases": [
                        {
                            "id": "0da2e35a-1234-4a5b-9f9d-1a2b3c4d5e6f",
                            "title": "Help!",
                            "date": "1965-08-06",
                            "country": "GB",
                            "artist-credit": [{"name": "The Beatles"}]
                        }
                    ]
                },
                {"id": "", "title": "坏数据"}
            ]
        });
        let cands = parse_recording_search(&raw);
        assert_eq!(cands.len(), 1, "缺 id 的条目必须丢弃");
        let c = &cands[0];
        assert_eq!(c.recording_id, "b1a9c0b9-d987-404e-a7db-3b00416af0c9");
        assert_eq!(c.title, "Yesterday");
        assert_eq!(c.artist, "The Beatles");
        assert_eq!(c.duration_ms, 269000);
        assert_eq!(c.isrcs, vec!["GBAYE0601498".to_string()]);
        assert_eq!(c.releases.len(), 1);
        assert_eq!(c.releases[0].title, "Help!");
        assert_eq!(c.releases[0].date, "1965-08-06");
        assert_eq!(c.releases[0].country, "GB");
        assert_eq!(c.releases[0].album_artist, "The Beatles");
    }

    #[test]
    fn parses_release_and_tracks() {
        let raw = json!({
            "id": "0da2e35a-1234-4a5b-9f9d-1a2b3c4d5e6f",
            "title": "Help!",
            "date": "1965-08-06",
            "country": "GB",
            "artist-credit": [{"name": "The Beatles"}],
            "media": [
                {
                    "position": 1,
                    "tracks": [
                        {"id": "r1", "title": "Help!", "length": 180000,
                         "position": 1, "artist-credit": [{"name": "The Beatles"}]},
                        {"id": "r2", "title": "Ticket to Ride", "length": null,
                         "number": "2", "artist-credit": []}
                    ]
                },
                {
                    "position": 2,
                    "tracks": [
                        {"id": "r3", "title": "磁带 A 面", "length": 1000, "position": 1}
                    ]
                }
            ]
        });
        let (release, tracks) = parse_release(&raw).expect("应解析出发行");
        assert_eq!(release.id, "0da2e35a-1234-4a5b-9f9d-1a2b3c4d5e6f");
        assert_eq!(release.country, "GB");
        assert_eq!(release.album_artist, "The Beatles");
        assert_eq!(tracks.len(), 3);
        assert_eq!(tracks[0].track, 1);
        assert_eq!(tracks[0].disc, 1);
        assert_eq!(tracks[0].duration_ms, 180000);
        assert_eq!(tracks[1].track, 2, "缺 position 时回落到 number");
        assert_eq!(tracks[1].duration_ms, 0, "未知时长必须是 0");
        assert_eq!(tracks[1].artist, "", "未知字符串必须为空串");
        assert_eq!(tracks[2].disc, 2);
    }

    #[test]
    fn parses_acoustid_results() {
        let raw = json!({
            "status": "ok",
            "results": [
                {
                    "id": "abc",
                    "score": 0.98,
                    "recordings": [
                        {
                            "id": "b1a9c0b9-d987-404e-a7db-3b00416af0c9",
                            "title": "Yesterday",
                            "length": 269000,
                            "artists": [{"name": "The Beatles"}],
                            "releasegroups": [{"id": "g1", "title": "Help!"}]
                        }
                    ]
                }
            ]
        });
        let cands = parse_acoustid_results(&raw);
        assert_eq!(cands.len(), 1);
        assert_eq!(
            cands[0].recording_id,
            "b1a9c0b9-d987-404e-a7db-3b00416af0c9"
        );
        assert_eq!(cands[0].title, "Yesterday");
        assert_eq!(cands[0].artist, "The Beatles");
        assert_eq!(cands[0].duration_ms, 269000);
        assert_eq!(cands[0].score, 98);
        assert!(cands[0].releases.is_empty());
    }

    #[test]
    fn unknown_fields_default_to_zero_and_empty() {
        let raw = json!({"id": "x", "title": "t"});
        let c = parse_recording(&raw).unwrap();
        assert_eq!(c.duration_ms, 0);
        assert_eq!(c.artist, "");
        assert!(c.isrcs.is_empty());
        assert!(c.releases.is_empty());
    }

    #[test]
    fn lucene_query_is_escaped() {
        let q = build_recording_query("He said \"hi\"", "AC/DC");
        assert_eq!(q, "recording:\"He said \\\"hi\\\"\" AND artist:\"AC/DC\"");
        assert!(!build_recording_query("x", "  ").contains("artist"));
    }

    #[test]
    fn similarity_behaves() {
        assert!((similarity("Yesterday", "yesterday") - 1.0).abs() < 1e-9);
        assert!(similarity("Yesterday", "Yesterday (Remastered)") >= 0.85);
        assert!(similarity("", "x") == 0.0);
        assert!(similarity("abc", "xyz") < 0.5);
    }

    #[test]
    fn score_rewards_matching_title_artist_and_duration() {
        let good = Candidate {
            recording_id: "a".into(),
            title: "Yesterday".into(),
            artist: "The Beatles".into(),
            duration_ms: 269_000,
            ..Default::default()
        };
        let bad = Candidate {
            recording_id: "b".into(),
            title: "Completely Other".into(),
            artist: "Nobody".into(),
            duration_ms: 10_000,
            ..Default::default()
        };
        let s1 = score_candidate("Yesterday", "The Beatles", Some(269_000), &good);
        let s2 = score_candidate("Yesterday", "The Beatles", Some(269_000), &bad);
        assert!(s1 > s2, "匹配候选分数必须更高：{} vs {}", s1, s2);
        assert!(s1 <= 100);
    }

    #[test]
    fn mbid_validation() {
        assert!(is_mbid("b1a9c0b9-d987-404e-a7db-3b00416af0c9"));
        assert!(!is_mbid("not-a-mbid"));
        assert!(!is_mbid(""));
    }

    #[tokio::test]
    async fn rate_limiter_enforces_interval() {
        let limiter = RateLimiter::new(Duration::from_millis(80));
        let start = Instant::now();
        limiter.acquire(None).await.expect("第一次");
        limiter.acquire(None).await.expect("第二次");
        let elapsed = start.elapsed();
        assert!(
            elapsed >= Duration::from_millis(70),
            "两次请求间隔必须 >= 限速间隔，实际 {:?}",
            elapsed
        );
    }

    /// 并发请求不得在同一时刻一起发出（闸必须串行调度）。
    #[tokio::test]
    async fn rate_limiter_serialises_concurrent_requests() {
        let limiter = Arc::new(RateLimiter::new(Duration::from_millis(60)));
        let mut handles = Vec::new();
        for _ in 0..4 {
            let l = Arc::clone(&limiter);
            handles.push(tokio::spawn(async move {
                let start = Instant::now();
                l.acquire(None).await.expect("acquire");
                start.elapsed()
            }));
        }
        let mut starts = Vec::new();
        for h in handles {
            starts.push(h.await.expect("task"));
        }
        // 第 4 个请求至少要等 3 个间隔。
        let max = starts.iter().copied().max().unwrap_or_default();
        assert!(
            max >= Duration::from_millis(150),
            "并发请求必须被闸串行化，实际最大等待 {:?}",
            max
        );
    }

    /// 取消不得在限速器里留下空洞（后续请求不得被已取消的等待拖住）。
    #[tokio::test]
    async fn rate_limiter_cancel_leaves_no_hole() {
        let limiter = Arc::new(RateLimiter::new(Duration::from_millis(300)));
        limiter.acquire(None).await.expect("第一次");
        let token = CancelToken::new();
        let t = token.clone();
        let waiter_limiter = Arc::clone(&limiter);
        let waiter = tokio::spawn(async move {
            let started = Instant::now();
            let r = waiter_limiter.acquire(Some(&t)).await;
            (started.elapsed(), r)
        });
        tokio::time::sleep(Duration::from_millis(50)).await;
        token.cancel();
        let (waited, r) = waiter.await.expect("task");
        assert!(matches!(r, Err(MetadataError::Cancelled)));
        assert!(waited < Duration::from_millis(250), "取消必须立即返回");
        // 取消后不得留下「未来时隙」：下一次请求最多等 **一个** 间隔
        // （旧实现会提前预约未来时隙，被取消的等待会把后续请求多挡一个间隔）。
        let start = Instant::now();
        limiter.acquire(None).await.expect("后续请求");
        assert!(
            start.elapsed() < Duration::from_millis(400),
            "取消不得留下空洞（不得多挡一个间隔），实际等待 {:?}",
            start.elapsed()
        );
    }

    /// 已有 waiter 持闸时，排队等闸的请求被取消必须 **立即返回**，
    /// 且不得改动 `next`（不留下空洞、不多挡一个间隔）。
    #[tokio::test]
    async fn rate_limiter_cancelled_queue_waiter_returns_immediately() {
        let limiter = Arc::new(RateLimiter::new(Duration::from_millis(300)));
        // A 连续取两次时隙：第二次会在 **持闸** 状态下等待 300ms。
        let a = Arc::clone(&limiter);
        let handle_a = tokio::spawn(async move {
            a.acquire(None).await.expect("A1");
            a.acquire(None).await.expect("A2");
        });
        tokio::time::sleep(Duration::from_millis(60)).await;
        assert!(
            !handle_a.is_finished(),
            "A 的第二次取隙应仍在持闸等待（间隔 300ms），闸未打开"
        );
        // B 排队等闸（闸被 A 持有）
        let token = CancelToken::new();
        let t = token.clone();
        let b = Arc::clone(&limiter);
        let handle_b = tokio::spawn(async move {
            let started = Instant::now();
            let r = b.acquire(Some(&t)).await;
            (started.elapsed(), r)
        });
        tokio::time::sleep(Duration::from_millis(60)).await;
        token.cancel();
        let (waited, r) = tokio::time::timeout(Duration::from_secs(2), handle_b)
            .await
            .expect("排队等闸时被取消必须立即返回，不得等闸打开")
            .expect("task");
        assert!(matches!(r, Err(MetadataError::Cancelled)));
        assert!(
            waited < Duration::from_millis(150),
            "取消必须立即返回，实际 {:?}",
            waited
        );
        let _ = handle_a.await;
        // B 的取消不得改动 next：后续请求最多等一个间隔。
        let start = Instant::now();
        limiter.acquire(None).await.expect("后续请求");
        assert!(
            start.elapsed() < Duration::from_millis(400),
            "被取消的排队者不得改动 next，实际等待 {:?}",
            start.elapsed()
        );
    }

    #[tokio::test]
    async fn search_cancel_makes_pending_request_fail() {
        let base = spawn_stub(r#"{"count":0,"recordings":[]}"#);
        // 慢桩：2 秒后才回
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            use std::io::{Read, Write};
            for stream in listener.incoming() {
                let mut s = stream.unwrap();
                let mut buf = [0u8; 4096];
                let _ = s.read(&mut buf);
                std::thread::sleep(Duration::from_millis(2000));
                let body = r#"{"count":0,"recordings":[]}"#;
                let head = format!(
                    "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n",
                    body.len()
                );
                let _ = s.write_all(head.as_bytes());
                let _ = s.write_all(body.as_bytes());
            }
        });
        let _ = base;
        let cfg = MetadataConfig {
            musicbrainz_base: format!("http://127.0.0.1:{}", port),
            musicbrainz_interval: Duration::from_millis(1),
            ..MetadataConfig::default()
        };
        let svc = Arc::new(MetadataService::with_config(cfg));
        let req = SearchRequest {
            title: "Yesterday".into(),
            artist: String::new(),
            duration_ms: None,
            limit: Some(5),
            token: Some("tok-search".into()),
        };
        let worker = Arc::clone(&svc);
        let handle = tokio::spawn(async move { worker.search(&req).await });
        tokio::time::sleep(Duration::from_millis(200)).await;
        assert!(svc.cancel("tok-search"), "取消必须命中在途请求");
        let result = tokio::time::timeout(Duration::from_secs(5), handle)
            .await
            .expect("取消后不得悬挂")
            .expect("task");
        assert!(
            matches!(result, Err(MetadataError::Cancelled)),
            "取消必须返回 Cancelled，实际 {:?}",
            result
        );
    }

    /// 取消 **先于** 请求登记到达时，不得丢失（预取消墓碑）。
    #[tokio::test]
    async fn cancel_before_request_registers_is_honoured() {
        let hits = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let base = spawn_stub_counted(r#"{"count":0,"recordings":[]}"#, Arc::clone(&hits));
        let cfg = MetadataConfig {
            musicbrainz_base: base.clone(),
            musicbrainz_interval: Duration::from_millis(1),
            ..MetadataConfig::default()
        };
        let svc = MetadataService::with_config(cfg);
        // 先取消（此时还没有任何请求登记这个 token）
        assert!(
            !svc.cancel("tok-early"),
            "未登记时不算命中在途请求（只记墓碑）"
        );
        // 随后到达的请求必须立即被取消，且 **不得发起** 任何 HTTP 请求
        let req = SearchRequest {
            title: "Yesterday".into(),
            token: Some("tok-early".into()),
            ..Default::default()
        };
        let err = svc.search(&req).await.expect_err("必须取消");
        assert!(
            matches!(err, MetadataError::Cancelled),
            "先到的取消必须被承接，实际 {:?}",
            err
        );
        assert_eq!(
            hits.load(std::sync::atomic::Ordering::SeqCst),
            0,
            "被预取消的请求不得发出 HTTP 请求"
        );
        // 墓碑只消费一次：换一个 token 不受影响
        let req = SearchRequest {
            title: "Yesterday".into(),
            token: Some("tok-other".into()),
            ..Default::default()
        };
        let ok = svc.search(&req).await.expect("其它 token 必须正常执行");
        assert!(ok.is_empty());
        assert_eq!(
            hits.load(std::sync::atomic::Ordering::SeqCst),
            1,
            "其它 token 的请求必须真的发出"
        );
    }

    /// 墓碑必须有界（不得无限增长）。
    #[test]
    fn cancel_tombstones_are_bounded() {
        let registry = CancelRegistry::default();
        for i in 0..(TOMBSTONE_MAX * 2) {
            registry.cancel(&format!("tok-{}", i));
        }
        let state = registry.state.lock().expect("cancel state");
        assert!(
            state.tombstones.len() <= TOMBSTONE_MAX,
            "墓碑数量必须有界，实际 {}",
            state.tombstones.len()
        );
    }

    /// **定序**回归：取消先到 → 随后登记必须承接取消。
    #[test]
    fn cancel_before_register_is_carried_over() {
        let registry = CancelRegistry::default();
        registry.cancel("tok-order");
        let token = registry.register("tok-order");
        assert!(token.is_cancelled(), "先到的取消必须被承接");
    }

    /// **定序**回归：登记先到 → 随后取消必须命中在途令牌。
    #[test]
    fn cancel_after_register_hits_live_token() {
        let registry = CancelRegistry::default();
        let token = registry.register("tok-order-2");
        assert!(registry.cancel("tok-order-2"), "必须命中在途请求");
        assert!(token.is_cancelled());
    }

    /// **并发**回归：register 与 cancel 竞态时，取消 **不得丢失**。
    ///
    /// （旧实现用两把锁时存在窗口：cancel 查到无在途 → register 登记并查到
    /// 无墓碑 → cancel 才写墓碑，这次请求不会被取消。）
    #[test]
    fn cancel_is_never_lost_under_race() {
        for i in 0..500 {
            let registry = std::sync::Arc::new(CancelRegistry::default());
            let r1 = std::sync::Arc::clone(&registry);
            let r2 = std::sync::Arc::clone(&registry);
            let key = format!("tok-race-{}", i);
            let k1 = key.clone();
            let k2 = key.clone();
            let canceler = std::thread::spawn(move || {
                r1.cancel(&k1);
            });
            let registrar = std::thread::spawn(move || r2.register(&k2));
            let token = registrar.join().expect("register thread");
            canceler.join().expect("cancel thread");
            assert!(token.is_cancelled(), "并发下取消不得丢失（第 {} 次）", i);
        }
    }

    /// 墓碑不得影响后续 **同名** 的独立请求（请求结束后墓碑被清理）。
    #[test]
    fn tombstone_does_not_leak_to_later_requests() {
        let registry = CancelRegistry::default();
        registry.cancel("tok-reuse");
        let first = registry.register("tok-reuse");
        assert!(first.is_cancelled(), "先到的取消必须被承接");
        registry.release("tok-reuse");
        let second = registry.register("tok-reuse");
        assert!(
            !second.is_cancelled(),
            "已结束的请求不得把取消留给后续同名请求"
        );
    }

    #[tokio::test]
    async fn cancel_marks_token_and_wakes_waiter() {
        let token = CancelToken::new();
        assert!(!token.is_cancelled());
        let t = token.clone();
        let handle = tokio::spawn(async move {
            t.cancelled().await;
            true
        });
        tokio::time::sleep(Duration::from_millis(20)).await;
        token.cancel();
        assert!(token.is_cancelled());
        assert!(tokio::time::timeout(Duration::from_secs(2), handle)
            .await
            .expect("等待者必须被唤醒")
            .unwrap());
    }

    #[tokio::test]
    async fn cancellable_returns_cancelled_error() {
        let token = CancelToken::new();
        token.cancel();
        let result: Result<(), MetadataError> = cancellable(Some(&token), async {
            tokio::time::sleep(Duration::from_secs(5)).await;
            Ok(())
        })
        .await;
        assert!(matches!(result, Err(MetadataError::Cancelled)));
    }

    #[test]
    fn bounded_cache_evicts_and_expires() {
        let cache = BoundedCache::new(2, Duration::from_secs(60));
        cache.put("a", json!(1));
        cache.put("b", json!(2));
        assert_eq!(cache.get("a"), Some(json!(1)));
        cache.put("c", json!(3));
        assert!(cache.len() <= 2, "缓存必须有界");
    }

    // ---------------- fpcalc / AcoustID 夹具 ----------------

    /// 夹具目录：`.artifacts/rust-metadata/meta/fixtures`。
    fn fixture_dir() -> PathBuf {
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../.artifacts/rust-metadata/meta/fixtures");
        std::fs::create_dir_all(&dir).expect("创建夹具目录");
        dir
    }

    /// 写一个 **真实可执行** 的脚本夹具（fpcalc 替身）。
    fn write_script(name: &str, body: &str) -> PathBuf {
        let path = fixture_dir().join(name);
        std::fs::write(&path, body).expect("写脚本夹具");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = std::fs::metadata(&path).expect("stat").permissions();
            perms.set_mode(0o755);
            std::fs::set_permissions(&path, perms).expect("chmod");
        }
        path
    }

    /// 本地 HTTP 桩服务：任何请求都返回固定 JSON。
    fn spawn_stub(body: &'static str) -> String {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind stub");
        let port = listener.local_addr().expect("addr").port();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let mut s = match stream {
                    Ok(s) => s,
                    Err(_) => break,
                };
                let mut buf = Vec::new();
                let mut chunk = [0u8; 4096];
                // 读请求头
                loop {
                    match s.read(&mut chunk) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => {
                            buf.extend_from_slice(&chunk[..n]);
                            if buf.windows(4).any(|w| w == b"\r\n\r\n") {
                                break;
                            }
                        }
                    }
                }
                // 读请求体（按 content-length）
                let head = String::from_utf8_lossy(&buf).to_string();
                let len = head
                    .lines()
                    .find(|l| l.to_ascii_lowercase().starts_with("content-length:"))
                    .and_then(|l| l.split(':').nth(1))
                    .and_then(|v| v.trim().parse::<usize>().ok())
                    .unwrap_or(0);
                let mut body_read =
                    buf.len() - head.find("\r\n\r\n").map(|i| i + 4).unwrap_or(buf.len());
                while body_read < len {
                    match s.read(&mut chunk) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => body_read += n,
                    }
                }
                let head = format!(
                    "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n",
                    body.len()
                );
                let _ = s.write_all(head.as_bytes());
                let _ = s.write_all(body.as_bytes());
                let _ = s.flush();
            }
        });
        format!("http://127.0.0.1:{}", port)
    }

    /// 本地 HTTP 桩服务：任何请求都返回固定 JSON（并统计命中次数）。
    fn spawn_stub_counted(body: &'static str, hits: Arc<std::sync::atomic::AtomicUsize>) -> String {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind stub");
        let port = listener.local_addr().expect("addr").port();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let mut s = match stream {
                    Ok(s) => s,
                    Err(_) => break,
                };
                let mut buf = Vec::new();
                let mut chunk = [0u8; 4096];
                loop {
                    match s.read(&mut chunk) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => {
                            buf.extend_from_slice(&chunk[..n]);
                            if buf.windows(4).any(|w| w == b"\r\n\r\n") {
                                break;
                            }
                        }
                    }
                }
                hits.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                let head = String::from_utf8_lossy(&buf).to_string();
                let len = head
                    .lines()
                    .find(|l| l.to_ascii_lowercase().starts_with("content-length:"))
                    .and_then(|l| l.split(':').nth(1))
                    .and_then(|v| v.trim().parse::<usize>().ok())
                    .unwrap_or(0);
                let mut body_read =
                    buf.len() - head.find("\r\n\r\n").map(|i| i + 4).unwrap_or(buf.len());
                while body_read < len {
                    match s.read(&mut chunk) {
                        Ok(0) | Err(_) => break,
                        Ok(n) => body_read += n,
                    }
                }
                let head = format!(
                    "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n",
                    body.len()
                );
                let _ = s.write_all(head.as_bytes());
                let _ = s.write_all(body.as_bytes());
                let _ = s.flush();
            }
        });
        format!("http://127.0.0.1:{}", port)
    }

    fn service_with(base: &str) -> MetadataService {
        let cfg = MetadataConfig {
            acoustid_base: base.to_string(),
            musicbrainz_base: base.to_string(),
            musicbrainz_interval: Duration::from_millis(1),
            cover_art_interval: Duration::from_millis(1),
            acoustid_interval: Duration::from_millis(1),
            ..MetadataConfig::default()
        };
        MetadataService::with_config(cfg)
    }

    #[tokio::test]
    async fn fingerprint_without_api_key_fails_explicitly() {
        let svc = MetadataService::with_config(MetadataConfig::default());
        let req = FingerprintRequest {
            path: "/tmp/does-not-matter.mp3".into(),
            api_key: "  ".into(),
            ..Default::default()
        };
        let err = svc.fingerprint(&req).await.expect_err("必须报错");
        assert!(
            matches!(err, MetadataError::MissingApiKey),
            "缺 key 必须明确报错，实际 {:?}",
            err
        );
    }

    #[tokio::test]
    async fn fingerprint_without_fpcalc_fails_explicitly() {
        let svc = MetadataService::with_config(MetadataConfig::default());
        let missing = fixture_dir().join("no-such-fpcalc");
        let req = FingerprintRequest {
            path: "/tmp/does-not-matter.mp3".into(),
            api_key: "k".into(),
            fpcalc_path: Some(missing.display().to_string()),
            ..Default::default()
        };
        let err = svc.fingerprint(&req).await.expect_err("必须报错");
        assert!(
            matches!(err, MetadataError::FpcalcMissing(_)),
            "缺 fpcalc 必须明确报错，实际 {:?}",
            err
        );
        // 显式路径不存在时 resolve_fpcalc 也要直接报错。
        let err = svc
            .resolve_fpcalc(Some("/definitely/not/here/fpcalc"))
            .expect_err("必须报错");
        assert!(matches!(err, MetadataError::FpcalcMissing(_)));
        // PATH 里没有 fpcalc 时（本机确实没有）也必须明确报错。
        if find_in_path("fpcalc").is_none() {
            let err = svc.resolve_fpcalc(None).expect_err("必须报错");
            assert!(matches!(err, MetadataError::FpcalcMissing(_)));
        }
    }

    #[tokio::test]
    async fn fingerprint_runs_fpcalc_and_queries_acoustid() {
        let script = write_script(
            "fpcalc-ok.sh",
            "#!/bin/sh\nprintf '%s' '{\"duration\": 269.5, \"fingerprint\": \"AQADtEm0yE=\"}'\n",
        );
        let base = spawn_stub(
            r#"{"status":"ok","results":[{"id":"r1","score":0.97,"recordings":[{"id":"b1a9c0b9-d987-404e-a7db-3b00416af0c9","title":"Yesterday","length":269000,"artists":[{"name":"The Beatles"}]}]}]}"#,
        );
        let svc = service_with(&base);
        let audio = fixture_dir().join("sample.mp3");
        std::fs::write(&audio, b"fake audio").expect("写夹具音频");
        let req = FingerprintRequest {
            path: audio.display().to_string(),
            api_key: "test-key".into(),
            fpcalc_path: Some(script.display().to_string()),
            token: None,
        };
        let candidates = svc.fingerprint(&req).await.expect("指纹查询必须成功");
        assert_eq!(candidates.len(), 1);
        assert_eq!(
            candidates[0].recording_id,
            "b1a9c0b9-d987-404e-a7db-3b00416af0c9"
        );
        assert_eq!(candidates[0].title, "Yesterday");
        assert_eq!(candidates[0].score, 97);
    }

    #[tokio::test]
    async fn fingerprint_cancel_kills_and_reaps_fpcalc() {
        let pid_file = fixture_dir().join("fpcalc-slow.pid");
        let _ = std::fs::remove_file(&pid_file);
        let script = write_script(
            "fpcalc-slow.sh",
            &format!(
                "#!/bin/sh\necho $$ > '{}'\nsleep 20\nprintf '%s' '{{\"duration\": 1.0, \"fingerprint\": \"AQ==\"}}'\n",
                pid_file.display()
            ),
        );
        let base = spawn_stub(r#"{"status":"ok","results":[]}"#);
        let svc = Arc::new(service_with(&base));
        let audio = fixture_dir().join("sample-slow.mp3");
        std::fs::write(&audio, b"fake audio").expect("写夹具音频");
        let req = FingerprintRequest {
            path: audio.display().to_string(),
            api_key: "test-key".into(),
            fpcalc_path: Some(script.display().to_string()),
            token: Some("tok-cancel-1".into()),
        };
        // 取消登记在 **同一个服务实例** 里（与桥接一致：一个服务管全部 token）。
        let worker = Arc::clone(&svc);
        let handle = tokio::spawn(async move { worker.fingerprint(&req).await });
        // 等脚本真的起来
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline && !pid_file.exists() {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        assert!(pid_file.exists(), "fpcalc 脚本必须真的启动");
        // 等 pid 文件真正写入内容
        let mut pid: i32 = 0;
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            if let Ok(text) = std::fs::read_to_string(&pid_file) {
                if let Ok(p) = text.trim().parse::<i32>() {
                    pid = p;
                    break;
                }
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        assert!(pid > 0, "必须拿到 fpcalc 子进程 pid");
        // 取消必须立即让原请求返回 Cancelled
        let start = Instant::now();
        assert!(svc.cancel("tok-cancel-1"), "取消必须命中在途请求");
        let result = tokio::time::timeout(Duration::from_secs(10), handle)
            .await
            .expect("取消后不得悬挂")
            .expect("任务");
        assert!(
            matches!(result, Err(MetadataError::Cancelled)),
            "取消必须返回 Cancelled，实际 {:?}",
            result
        );
        assert!(
            start.elapsed() < Duration::from_secs(5),
            "取消必须快速返回，实际 {:?}",
            start.elapsed()
        );
        // 子进程必须被杀掉（回收后进程不再存在）
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            if !process_alive(pid) {
                break;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        assert!(
            !process_alive(pid),
            "取消后 fpcalc 子进程必须被杀（pid {}）",
            pid
        );
    }

    /// 进程是否仍存活（unix）。
    fn process_alive(pid: i32) -> bool {
        std::process::Command::new("/bin/kill")
            .arg("-0")
            .arg(pid.to_string())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
    }
}
