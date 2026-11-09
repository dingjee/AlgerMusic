//! 下载管理：后台下载音频文件并向前端推送进度。
//!
//! 健壮性要求：
//! - 先写入 `*.part` 临时文件，成功后再重命名为最终文件，避免留下半成品。
//! - 目标文件已存在时自动追加序号，**不覆盖**已有文件。
//! - 文件扩展名按真实响应格式（Content-Type / URL / 字节特征）判定。
//! - 任何失败都把任务标记为 `failed` 并清理临时文件。

use std::path::{Path, PathBuf};
use std::sync::Arc;

use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter};
use tokio::io::AsyncWriteExt;

/// 下载事件名（前端通过 `listen` 订阅）。
pub const DOWNLOAD_EVENT: &str = "download://progress";

/// 单个下载任务的状态。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DownloadItem {
    /// 网易云歌曲 ID。
    pub id: i64,
    pub name: String,
    pub artist: String,
    /// 目标文件路径。
    pub path: String,
    /// 已下载字节。
    pub downloaded: u64,
    /// 总字节（未知时为 0）。
    pub total: u64,
    /// 状态：`pending` / `running` / `done` / `failed`。
    pub status: String,
    /// 失败原因。
    pub error: Option<String>,
    /// 使用的音源。
    pub source: Option<String>,
}

impl DownloadItem {
    fn new(id: i64, name: &str, artist: &str, path: PathBuf) -> Self {
        DownloadItem {
            id,
            name: name.to_string(),
            artist: artist.to_string(),
            path: path.to_string_lossy().to_string(),
            downloaded: 0,
            total: 0,
            status: "pending".into(),
            error: None,
            source: None,
        }
    }

    /// 进度百分比。
    pub fn percent(&self) -> u32 {
        if self.total == 0 {
            0
        } else {
            ((self.downloaded as f64 / self.total as f64) * 100.0).clamp(0.0, 100.0) as u32
        }
    }
}

/// 下载管理器。
pub struct DownloadManager {
    http: reqwest::Client,
    items: Mutex<Vec<DownloadItem>>,
}

impl DownloadManager {
    /// 创建下载管理器。
    pub fn new() -> Self {
        let http = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(1800))
            .connect_timeout(std::time::Duration::from_secs(15))
            .user_agent(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
            )
            .build()
            .expect("build download client");
        Self {
            http,
            items: Mutex::new(Vec::new()),
        }
    }

    /// 当前任务列表。
    pub fn list(&self) -> Vec<DownloadItem> {
        self.items.lock().clone()
    }

    /// 更新任务状态。
    fn update<F: FnOnce(&mut DownloadItem)>(&self, id: i64, f: F) {
        let mut guard = self.items.lock();
        if let Some(item) = guard.iter_mut().find(|i| i.id == id) {
            f(item);
        }
    }

    /// 推送给前端。
    fn emit(&self, app: &AppHandle, item: &DownloadItem) {
        let _ = app.emit(DOWNLOAD_EVENT, item);
    }

    /// 标记失败并清理临时文件。
    fn fail(&self, app: &AppHandle, id: i64, message: String, tmp: Option<&Path>) {
        if let Some(path) = tmp {
            let _ = std::fs::remove_file(path);
        }
        self.update(id, |i| {
            i.status = "failed".into();
            i.error = Some(message.clone());
        });
        if let Some(i) = self.items.lock().iter().find(|i| i.id == id).cloned() {
            self.emit(app, &i);
        }
    }

    /// **同步**登记下载任务（必须在任何 `await` 之前调用）。
    ///
    /// 这样可以保证：
    /// - 同一首歌不会被并发下载两次（都写同一个临时文件）；
    /// - 即使后续请求失败，任务也会以 `failed` 状态出现在列表里，
    ///   不会留下永远停留在 `pending` / `running` 的僵尸任务。
    fn reserve(
        &self,
        id: i64,
        name: &str,
        artist: &str,
        source: Option<String>,
    ) -> Result<(), String> {
        let mut guard = self.items.lock();
        if let Some(existing) = guard.iter().find(|i| i.id == id) {
            if existing.status == "pending" || existing.status == "running" {
                return Err("该歌曲正在下载中".into());
            }
        }
        let mut item = DownloadItem::new(id, name, artist, PathBuf::new());
        item.source = source;
        item.status = "pending".into();
        guard.retain(|i| i.id != id);
        guard.push(item);
        Ok(())
    }

    /// 开始下载。
    #[allow(clippy::too_many_arguments)]
    pub async fn start(
        self: &Arc<Self>,
        app: AppHandle,
        id: i64,
        name: &str,
        artist: &str,
        url: &str,
        dir: &Path,
        source: Option<String>,
    ) -> Result<String, String> {
        if let Err(e) = std::fs::create_dir_all(dir) {
            // 带上具体目录与 IO 原因，便于定位（不涉及任何凭证）
            let msg = format!("创建下载目录失败（{}）：{}", dir.display(), e);
            // 目录都建不出来时无法登记任务，直接返回
            return Err(msg);
        }

        // 1) 同步登记任务（在任何 await 之前），避免并发重复下载
        self.reserve(id, name, artist, source.clone())?;
        if let Some(item) = self.items.lock().iter().find(|i| i.id == id).cloned() {
            self.emit(&app, &item);
        }

        // 2) 请求（同时拿到 Content-Type 用于判定真实格式）
        let resp = match self.http.get(url).send().await {
            Ok(r) => r,
            Err(e) => {
                let msg = format!("下载请求失败：{}", e);
                self.fail(&app, id, msg.clone(), None);
                return Err(msg);
            }
        };
        let status = resp.status();
        if !status.is_success() {
            let msg = format!("下载失败：HTTP {}", status.as_u16());
            self.fail(&app, id, msg.clone(), None);
            return Err(msg);
        }
        let content_type = resp
            .headers()
            .get("content-type")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
            .to_ascii_lowercase();
        let total = resp.content_length().unwrap_or(0);

        // 3) 标记 running
        self.update(id, |i| {
            i.status = "running".into();
            i.total = total;
        });
        if let Some(item) = self.items.lock().iter().find(|i| i.id == id).cloned() {
            self.emit(&app, &item);
        }

        // 扩展名先按 Content-Type / URL 判断，读到字节后再按特征修正
        let mut extension = guess_extension(&content_type, url);
        // 临时文件统一命名，成功后再原子落位
        let tmp = dir.join(format!(".alger-dl-{}.part", id));

        let mut file = match tokio::fs::File::create(&tmp).await {
            Ok(f) => f,
            Err(e) => {
                let msg = format!("写入临时文件失败：{}", e);
                self.fail(&app, id, msg.clone(), None);
                return Err(msg);
            }
        };

        let mut stream = resp.bytes_stream();
        let mut downloaded: u64 = 0;
        let mut last_emit = std::time::Instant::now();
        let mut head: Vec<u8> = Vec::new();
        use futures_util::StreamExt;
        while let Some(chunk) = stream.next().await {
            let chunk = match chunk {
                Ok(c) => c,
                Err(e) => {
                    let msg = format!("下载中断：{}", e);
                    self.fail(&app, id, msg.clone(), Some(&tmp));
                    return Err(msg);
                }
            };
            if head.len() < 16 {
                let need = 16 - head.len();
                head.extend_from_slice(&chunk[..chunk.len().min(need)]);
                if let Some(detected) = detect_extension(&head) {
                    extension = detected.to_string();
                }
            }
            if let Err(e) = file.write_all(&chunk).await {
                let msg = format!("写入文件失败：{}", e);
                self.fail(&app, id, msg.clone(), Some(&tmp));
                return Err(msg);
            }
            downloaded += chunk.len() as u64;
            if last_emit.elapsed() >= std::time::Duration::from_millis(200) {
                last_emit = std::time::Instant::now();
                self.update(id, |i| {
                    i.downloaded = downloaded;
                    i.total = total;
                });
                if let Some(i) = self.items.lock().iter().find(|i| i.id == id).cloned() {
                    self.emit(&app, &i);
                }
            }
        }
        if let Err(e) = file.flush().await {
            let msg = format!("写入文件失败：{}", e);
            self.fail(&app, id, msg.clone(), Some(&tmp));
            return Err(msg);
        }
        drop(file);

        // 4) 内容校验：空文件或网页伪音频都算失败
        if downloaded == 0 {
            let msg = "下载内容为空".to_string();
            self.fail(&app, id, msg.clone(), Some(&tmp));
            return Err(msg);
        }
        if crate::sources::looks_like_document(&head) {
            let msg = "下载到的不是音频（返回了网页/JSON）".to_string();
            self.fail(&app, id, msg.clone(), Some(&tmp));
            return Err(msg);
        }

        // 5) 原子落位：目标已存在时追加序号，绝不覆盖已有文件
        let final_name = sanitize_filename(name, artist, &extension);
        let final_target = match finalize_atomically(&tmp, dir, &final_name) {
            Ok(p) => p,
            Err(e) => {
                self.fail(&app, id, e.clone(), Some(&tmp));
                return Err(e);
            }
        };

        self.update(id, |i| {
            i.downloaded = downloaded;
            i.total = if total > 0 { total } else { downloaded };
            i.status = "done".into();
            i.path = final_target.to_string_lossy().to_string();
        });
        if let Some(i) = self.items.lock().iter().find(|i| i.id == id).cloned() {
            self.emit(&app, &i);
        }
        Ok(final_target.to_string_lossy().to_string())
    }
}

impl Default for DownloadManager {
    fn default() -> Self {
        Self::new()
    }
}

/// 生成安全的文件名：`歌手 - 歌名.ext`。
pub fn sanitize_filename(name: &str, artist: &str, extension: &str) -> String {
    let base = if artist.is_empty() {
        name.to_string()
    } else {
        format!("{} - {}", artist, name)
    };
    let cleaned: String = base
        .chars()
        .map(|c| match c {
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' | '\0' => '_',
            c => c,
        })
        .collect();
    let trimmed = cleaned.trim().trim_matches('.').to_string();
    let stem = if trimmed.is_empty() {
        "unknown".to_string()
    } else {
        trimmed
    };
    format!("{}.{}", stem, extension)
}

/// 若目标文件已存在，追加 ` (1)`、` (2)` … 生成不冲突的路径。
pub fn unique_path(dir: &Path, filename: &str) -> PathBuf {
    let candidate = dir.join(filename);
    if !candidate.exists() {
        return candidate;
    }
    let (stem, ext) = split_filename(filename);
    for n in 1..1000 {
        let name = if ext.is_empty() {
            format!("{} ({})", stem, n)
        } else {
            format!("{} ({}).{}", stem, n, ext)
        };
        let path = dir.join(name);
        if !path.exists() {
            return path;
        }
    }
    dir.join(filename)
}

/// 拆分文件名的主干与扩展名。
fn split_filename(filename: &str) -> (String, String) {
    match filename.rsplit_once('.') {
        Some((s, e)) if !s.is_empty() => (s.to_string(), e.to_string()),
        _ => (filename.to_string(), String::new()),
    }
}

/// 把临时文件 **原子** 落位到最终文件名。
///
/// 使用 `hard_link` 实现「目标存在则失败」的原子语义（不会出现覆盖竞态），
/// 若文件系统不支持硬链接则退化为 `rename` + 存在性检查。
pub fn finalize_atomically(tmp: &Path, dir: &Path, filename: &str) -> Result<PathBuf, String> {
    let (stem, ext) = split_filename(filename);
    let mut candidate = dir.join(filename);
    let mut n = 1u32;
    loop {
        match std::fs::hard_link(tmp, &candidate) {
            Ok(()) => {
                let _ = std::fs::remove_file(tmp);
                return Ok(candidate);
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                let name = if ext.is_empty() {
                    format!("{} ({})", stem, n)
                } else {
                    format!("{} ({}).{}", stem, n, ext)
                };
                candidate = dir.join(name);
                n += 1;
                if n > 1000 {
                    return Err("目标目录中同名文件过多".into());
                }
            }
            Err(_e) => {
                // 文件系统不支持硬链接时退化为 rename
                if candidate.exists() {
                    let name = if ext.is_empty() {
                        format!("{} ({})", stem, n)
                    } else {
                        format!("{} ({}).{}", stem, n, ext)
                    };
                    candidate = dir.join(name);
                    n += 1;
                    if n > 1000 {
                        return Err("目标目录中同名文件过多".into());
                    }
                    continue;
                }
                std::fs::rename(tmp, &candidate).map_err(|err| format!("保存文件失败：{}", err))?;
                return Ok(candidate);
            }
        }
    }
}

/// 根据 Content-Type 与 URL 推断音频扩展名。
pub fn guess_extension(content_type: &str, url: &str) -> String {
    let ct = content_type.trim();
    let mapped = if ct.contains("flac") {
        "flac"
    } else if ct.contains("mpeg") || ct.contains("mp3") {
        "mp3"
    } else if ct.contains("mp4") || ct.contains("m4a") || ct.contains("aac") {
        "m4a"
    } else if ct.contains("ogg") || ct.contains("opus") {
        "ogg"
    } else if ct.contains("wav") {
        "wav"
    } else if ct.contains("webm") {
        "webm"
    } else {
        ""
    };
    if !mapped.is_empty() {
        return mapped.to_string();
    }
    // 退回到 URL 后缀
    let path = url.split('?').next().unwrap_or(url);
    for ext in ["flac", "mp3", "m4a", "aac", "ogg", "opus", "wav", "webm"] {
        if path.to_ascii_lowercase().ends_with(&format!(".{}", ext)) {
            return ext.to_string();
        }
    }
    "mp3".to_string()
}

/// 根据音频字节特征判断扩展名。
pub fn detect_extension(head: &[u8]) -> Option<&'static str> {
    if head.len() >= 4 && &head[0..4] == b"fLaC" {
        return Some("flac");
    }
    if head.len() >= 3 && &head[0..3] == b"ID3" {
        return Some("mp3");
    }
    if head.len() >= 4 && &head[0..4] == b"OggS" {
        return Some("ogg");
    }
    if head.len() >= 4 && &head[0..4] == b"RIFF" {
        return Some("wav");
    }
    if head.len() >= 8 && &head[4..8] == b"ftyp" {
        return Some("m4a");
    }
    if head.len() >= 2 && head[0] == 0xff && (head[1] & 0xe0) == 0xe0 {
        return Some("mp3");
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn filename_is_sanitized() {
        let f = sanitize_filename("晴天", "周杰伦", "mp3");
        assert_eq!(f, "周杰伦 - 晴天.mp3");
        let f2 = sanitize_filename("a/b:c", "d", "flac");
        assert!(!f2.contains('/'));
        assert!(!f2.contains(':'));
        assert!(f2.ends_with(".flac"));
    }

    #[test]
    fn empty_name_falls_back() {
        assert_eq!(sanitize_filename("", "", "mp3"), "unknown.mp3");
    }

    #[test]
    fn extension_guessing() {
        assert_eq!(guess_extension("audio/flac", ""), "flac");
        assert_eq!(guess_extension("audio/mpeg", ""), "mp3");
        assert_eq!(guess_extension("audio/mp4", ""), "m4a");
        assert_eq!(guess_extension("", "http://x/y.flac?a=1"), "flac");
        assert_eq!(guess_extension("", "http://x/y"), "mp3");
    }

    #[test]
    fn extension_detection() {
        assert_eq!(detect_extension(b"fLaC\x00"), Some("flac"));
        assert_eq!(detect_extension(b"ID3\x04"), Some("mp3"));
        assert_eq!(detect_extension(b"OggS"), Some("ogg"));
        assert_eq!(detect_extension(b"RIFF"), Some("wav"));
        // 真实 MP4 容器的 ftyp box 位于偏移 4
        assert_eq!(detect_extension(b"\0\0\0\x20ftypM4A"), Some("m4a"));
        assert_eq!(detect_extension(&[0xff, 0xfb, 0x90, 0x00]), Some("mp3"));
        assert_eq!(detect_extension(b"nope"), None);
    }

    #[test]
    fn unique_path_avoids_overwrite() {
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../.artifacts/tests")
            .join(format!("alger-dl-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p1 = unique_path(&dir, "a.mp3");
        assert_eq!(p1.file_name().unwrap(), "a.mp3");
        std::fs::write(&p1, b"x").unwrap();
        let p2 = unique_path(&dir, "a.mp3");
        assert_eq!(p2.file_name().unwrap(), "a (1).mp3");
        std::fs::write(&p2, b"x").unwrap();
        let p3 = unique_path(&dir, "a.mp3");
        assert_eq!(p3.file_name().unwrap(), "a (2).mp3");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn finalize_is_atomic_and_never_overwrites() {
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../.artifacts/tests")
            .join(format!("alger-fin-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let existing = dir.join("song.mp3");
        std::fs::write(&existing, b"old").unwrap();

        let tmp = dir.join(".part");
        std::fs::write(&tmp, b"new").unwrap();
        let target = finalize_atomically(&tmp, &dir, "song.mp3").unwrap();
        assert_eq!(target.file_name().unwrap(), "song (1).mp3");
        assert_eq!(std::fs::read(&existing).unwrap(), b"old");
        assert_eq!(std::fs::read(&target).unwrap(), b"new");
        // 临时文件已被清理
        assert!(!tmp.exists());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn finalize_uses_plain_name_when_free() {
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../.artifacts/tests")
            .join(format!("alger-fin2-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let tmp = dir.join(".part");
        std::fs::write(&tmp, b"new").unwrap();
        let target = finalize_atomically(&tmp, &dir, "song.mp3").unwrap();
        assert_eq!(target.file_name().unwrap(), "song.mp3");
        std::fs::remove_dir_all(&dir).ok();
    }
}
