//! `src-tauri/src/download.rs` 中纯工具函数的镜像副本。
//!
//! 原文件包含 `tauri::AppHandle` 事件依赖，无法被本 crate 复用；
//! 这里的函数与原实现保持一致（两侧测试同步维护）。修改任一侧时必须
//! 同步另一侧，或在未来把 Tauri 事件从该模块剥离后合并回单一来源。

use std::path::{Path, PathBuf};

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

/// 把临时文件 **原子** 落位到最终文件名（hard_link 优先，失败退化 rename）。
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
    // MP4 容器：偏移 4 字节处为 "ftyp"
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

    /// 与 `src-tauri/src/download.rs` 同步的行为校验。
    #[test]
    fn filename_is_sanitized() {
        let f = sanitize_filename("晴天", "周杰伦", "mp3");
        assert_eq!(f, "周杰伦 - 晴天.mp3");
    }

    #[test]
    fn extension_detection() {
        assert_eq!(detect_extension(b"fLaC\x00"), Some("flac"));
        assert_eq!(detect_extension(b"ID3\x04"), Some("mp3"));
        assert_eq!(detect_extension(b"OggS"), Some("ogg"));
        assert_eq!(detect_extension(b"RIFF"), Some("wav"));
        assert_eq!(detect_extension(b"\0\0\0\x20ftypM4A"), Some("m4a"));
        assert_eq!(detect_extension(&[0xff, 0xfb, 0x90, 0x00]), Some("mp3"));
    }

    #[test]
    fn finalize_is_atomic_and_never_overwrites() {
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../.artifacts/tests")
            .join(format!("alger-core-fin-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let existing = dir.join("song.mp3");
        std::fs::write(&existing, b"old").unwrap();
        let tmp = dir.join(".part");
        std::fs::write(&tmp, b"new").unwrap();
        let target = finalize_atomically(&tmp, &dir, "song.mp3").unwrap();
        assert_eq!(target.file_name().unwrap(), "song (1).mp3");
        assert_eq!(std::fs::read(&existing).unwrap(), b"old");
        assert_eq!(std::fs::read(&target).unwrap(), b"new");
        assert!(!tmp.exists());
        std::fs::remove_dir_all(&dir).ok();
    }
}
