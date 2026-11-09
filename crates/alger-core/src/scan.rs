//! 本地曲库扫描（E1）。
//!
//! 遍历目录（跳过隐藏目录与 `*.part` 临时文件），对音频文件读取标签元信息，
//! 以流式回调逐条交给调用方（桥接层转成事件推给 Swift，避免大 JSON 一次性
//! 占用内存）。扫描并发受限，保证 UI 可取消、可分批合并。

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use serde::{Deserialize, Serialize};

use crate::tags::{read_meta, TagError, TrackMeta, AUDIO_EXTENSIONS};

/// 扫描进度事件。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScanEntry {
    pub entry: TrackMeta,
}

/// 扫描统计。
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ScanSummary {
    pub scanned: u64,
    pub updated: u64,
    pub skipped: u64,
    pub errors: u64,
    pub duration_ms: u64,
    /// 失败文件与原因（最多保留 50 条，供界面诊断）。
    pub error_samples: Vec<String>,
}

/// 取消标志。
pub type CancelFlag = Arc<AtomicBool>;

/// 递归枚举目录中的音频文件（跳过隐藏目录/文件）。
pub fn collect_audio_files(dirs: &[PathBuf], cancel: &CancelFlag, out: &mut Vec<PathBuf>) {
    for dir in dirs {
        if cancel.load(Ordering::Relaxed) {
            return;
        }
        let Ok(entries) = std::fs::read_dir(dir) else {
            continue;
        };
        for entry in entries.flatten() {
            if cancel.load(Ordering::Relaxed) {
                return;
            }
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().to_string();
            if name.starts_with('.') {
                continue;
            }
            let Ok(file_type) = entry.file_type() else {
                continue;
            };
            if file_type.is_dir() {
                collect_audio_files(&[path], cancel, out);
            } else if file_type.is_file() {
                let is_audio = path
                    .extension()
                    .and_then(|e| e.to_str())
                    .map(|e| AUDIO_EXTENSIONS.contains(&e.to_ascii_lowercase().as_str()))
                    .unwrap_or(false);
                if is_audio {
                    out.push(path);
                }
            }
        }
    }
}

/// 扫描参数。
#[derive(Debug, Clone, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ScanOptions {
    /// 待扫描目录（必须存在）。
    pub dirs: Vec<PathBuf>,
    /// 已知索引：`path → (size, mtime 秒)`。未变化的文件跳过标签读取。
    #[serde(default)]
    pub known: HashMap<String, KnownStamp>,
}

/// 已知文件的戳（大小 + 修改时间）。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KnownStamp {
    pub size: u64,
    pub mtime: i64,
}

/// 执行扫描：对每个需要更新的文件调用 `on_entry`，结束时返回统计。
///
/// `on_entry(entry)` 由调用方决定如何合并进索引。
pub fn scan(
    options: &ScanOptions,
    cancel: &CancelFlag,
    mut on_entry: impl FnMut(TrackMeta),
) -> ScanSummary {
    let started = std::time::Instant::now();
    let mut summary = ScanSummary::default();
    let mut files: Vec<PathBuf> = Vec::new();
    collect_audio_files(&options.dirs, cancel, &mut files);
    files.sort();
    for path in files {
        if cancel.load(Ordering::Relaxed) {
            break;
        }
        let Ok(md) = std::fs::metadata(&path) else {
            summary.errors += 1;
            continue;
        };
        let mtime: i64 = md
            .modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        let key = path.to_string_lossy().to_string();
        if let Some(stamp) = options.known.get(&key) {
            if stamp.size == md.len() && stamp.mtime == mtime {
                summary.skipped += 1;
                summary.scanned += 1;
                continue;
            }
        }
        match read_meta(&path) {
            Ok(meta) => {
                summary.updated += 1;
                summary.scanned += 1;
                on_entry(meta);
            }
            Err(TagError::Open { path: p, detail }) | Err(TagError::Read { path: p, detail }) => {
                summary.errors += 1;
                if summary.error_samples.len() < 50 {
                    summary.error_samples.push(format!("{}：{}", p, detail));
                }
            }
            Err(_) => summary.errors += 1,
        }
    }
    summary.duration_ms = started.elapsed().as_millis() as u64;
    summary
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 中文 / 空格 / 子目录枚举 + known 跳过语义。
    #[test]
    fn scan_walks_and_skips_unchanged() {
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../.artifacts/fixtures")
            .join(format!("scan-{}", std::process::id()));
        let sub = dir.join("我的 专辑");
        std::fs::create_dir_all(&sub).unwrap();

        // 手工生成两个可读 MP3（复用 tags 测试的生成方式）
        for (name, title) in [("周杰伦 - 晴天.mp3", "晴天"), ("子目录 - 夜曲.mp3", "夜曲")]
        {
            let mut data: Vec<u8> = Vec::new();
            data.extend_from_slice(b"ID3\x03\x00\x00\x00\x00\x00\x00");
            let frame_header: [u8; 4] = [0xff, 0xfb, 0x90, 0x00];
            for _ in 0..32 {
                data.extend_from_slice(&frame_header);
                data.extend(std::iter::repeat_n(0u8, 413));
            }
            let target = if name.contains("子目录") {
                sub.join(name)
            } else {
                dir.join(name)
            };
            std::fs::write(&target, &data).unwrap();
            // 写标题标签以便验证读回
            let patch = crate::tags::TagPatch {
                title: Some(title.into()),
                artist: Some("测试艺人".into()),
                ..Default::default()
            };
            crate::tags::write_tags(&target, &patch).unwrap();
        }
        // 非 / 隐藏文件
        std::fs::write(dir.join("notes.txt"), b"x").unwrap();
        std::fs::write(dir.join(".hidden.mp3"), b"x").unwrap();

        let cancel = Arc::new(AtomicBool::new(false));
        let opts = ScanOptions {
            dirs: vec![dir.clone()],
            known: HashMap::new(),
        };
        let mut seen: Vec<TrackMeta> = Vec::new();
        let summary = scan(&opts, &cancel, |m| seen.push(m));
        assert_eq!(summary.updated, 2, "两个音频文件都要更新");
        assert_eq!(summary.errors, 0);
        assert!(seen.iter().any(|m| m.title == "晴天"));
        assert!(seen.iter().any(|m| m.title == "夜曲"));

        // 第二轮：把已见文件作为 known → 全部跳过
        let mut known = HashMap::new();
        for m in &seen {
            let md = std::fs::metadata(&m.path).unwrap();
            let mtime: i64 = md
                .modified()
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_secs() as i64)
                .unwrap_or(0);
            known.insert(
                m.path.clone(),
                KnownStamp {
                    size: md.len(),
                    mtime,
                },
            );
        }
        let opts2 = ScanOptions {
            dirs: vec![dir.clone()],
            known,
        };
        let summary2 = scan(&opts2, &cancel, |_| {});
        assert_eq!(summary2.updated, 0);
        assert_eq!(summary2.skipped, 2);

        std::fs::remove_dir_all(&dir).ok();
    }
}
