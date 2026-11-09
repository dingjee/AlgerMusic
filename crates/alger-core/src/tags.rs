//! 音频标签读写（E1 / E5 核心）。
//!
//! 按格式走标准标签容器：
//! - MP3 / AIFF → ID3v2
//! - FLAC / Ogg → Vorbis Comment
//! - M4A / MP4  → MP4 ilst
//!
//! 数据保护规则（预审清单 F7）：
//! - 只改标签区域，**不触碰音频流**（lofty 保存即此语义，不重编码）；
//! - 保留未知标签与既有封面（未涉及的帧 / 字段原样保留）；
//! - 写入后必须重新读取验证，返回「写后实读」的值，失败明确报错；
//! - 网易 / 来源关联 ID 以自定义字段写入：ID3v2 `TXXX:ALGERSONGID`、
//!   Vorbis `ALGERSONGID`、MP4 freeform `----:com.alger.music:ALGERSONGID`。

use std::path::Path;

use base64::Engine as _;
use serde::{Deserialize, Serialize};

/// 读取到的音频元信息。
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct TrackMeta {
    pub path: String,
    /// 容器格式：`mp3` / `flac` / `m4a` / `aiff` / `ogg` / `opus` / `wav`
    pub format: String,
    /// 时长（毫秒，未知 0）。
    pub duration_ms: u64,
    /// 码率（bps，未知 0）。
    pub bitrate: u32,
    /// 采样率（Hz，未知 0）。
    pub sample_rate: u32,
    /// 位深（bit，未知 0；无损文件用来证明质量，不靠压缩后码率比优劣）。
    pub bit_depth: u8,
    /// 实际编码（`alac` / `aac` / `mp3` / `flac` / `vorbis` / `opus` / `pcm` …；
    /// 空串 = **无法判定**（例如 m4a 容器既可能是 ALAC 也可能是 AAC）。
    pub codec: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub album_artist: String,
    pub genre: String,
    /// 曲目号（未知 0）。
    pub track: u32,
    /// 碟序号（未知 0）。
    pub disc: u32,
    /// 发行年份（未知 0）。
    pub year: u32,
    /// 是否内嵌封面。
    pub has_artwork: bool,
    /// 文件大小（字节）。
    pub file_size: u64,
    /// 来源关联：网易云歌曲 ID（容器专用 `ALGERSONGID`，0 = 未知）。
    pub netease_id: i64,
    /// ISRC（标准映射，lofty `ItemKey::Isrc`）。
    pub isrc: String,
    /// MusicBrainz 录音 ID（标准映射，lofty `ItemKey::MusicBrainzRecordingId`）。
    pub music_brainz_recording_id: String,
    /// MusicBrainz 发行 ID（标准映射，lofty `ItemKey::MusicBrainzReleaseId`）。
    pub music_brainz_release_id: String,
    /// 录制日期（完整年月日，如 `2003-07-31`；未知为空）。
    pub date: String,
}

/// 可写的标签字段（`None` = 不修改）。
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TagPatch {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub album_artist: Option<String>,
    pub genre: Option<String>,
    pub track: Option<u32>,
    pub disc: Option<u32>,
    pub year: Option<u32>,
    /// 以 base64 传入的新封面（JPEG / PNG）；`Some` 时替换封面。
    pub artwork_base64: Option<String>,
    /// 移除全部封面。
    pub remove_artwork: bool,
    /// 来源关联：网易云歌曲 ID（容器专用 `ALGERSONGID`）。
    ///
    /// `None` = 不修改；`Some(0)` 或负数 = 清除来源 ID。
    pub netease_id: Option<i64>,
    /// ISRC（标准映射）。
    pub isrc: Option<String>,
    /// MusicBrainz 录音 ID（标准映射；ID3v2 容器写 `UFID` 帧）。
    pub music_brainz_recording_id: Option<String>,
    /// MusicBrainz 发行 ID（标准映射）。
    pub music_brainz_release_id: Option<String>,
    /// 录制日期（完整年月日，如 `2003-07-31`）。
    ///
    /// 与 `year` 同时给出时以 `date` 为准。
    pub date: Option<String>,
}

/// 标签错误。
#[derive(Debug, thiserror::Error)]
pub enum TagError {
    #[error("无法打开音频文件 {path}：{detail}")]
    Open { path: String, detail: String },
    #[error("读取标签失败 {path}：{detail}")]
    Read { path: String, detail: String },
    #[error("写入标签失败 {path}：{detail}")]
    Write { path: String, detail: String },
    #[error("写入后验证不一致 {path}：{detail}")]
    Verify { path: String, detail: String },
    #[error("封面数据无效：{0}")]
    Artwork(String),
}

impl TagError {
    fn open(path: impl AsRef<Path>, source: impl std::fmt::Display) -> Self {
        TagError::Open {
            path: path.as_ref().display().to_string(),
            detail: source.to_string(),
        }
    }
}

use lofty::file::{AudioFile, TaggedFileExt};
use lofty::probe::Probe;
use lofty::tag::{ItemKey, ItemValue, Tag, TagItem, TagType};

/// 临时文件计数器（保证同进程内不冲突）。
static TMP_COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// 冲突检测签名（unix）：inode + 长度 + mtime **秒与纳秒**。
/// 单独成函数以便回归测试锁定「秒必须纳入」这一约束。
#[cfg(unix)]
fn conflict_signature(m: &std::fs::Metadata) -> (u64, u64, i64, i64) {
    use std::os::unix::fs::MetadataExt;
    (m.ino(), m.len(), m.mtime(), m.mtime_nsec())
}

/// 安全写标签的核心：**同目录临时副本** 上执行 `f`（含 lofty 保存与读回验证），
/// 全部成功后才原子 rename 覆盖原文件。
///
/// 数据保护（审查 F1 / F6 / F7）：
/// - lofty 的 `save_to_path` 是「截断 + 整体重写」；本包装保证任何失败
///   （进程被杀 / 磁盘满 / 校验不一致）都 **不改动原文件**；
/// - 临时副本用 `cp -p` 复制，保留权限与扩展属性（Finder 标签等）；
///   `cp` 不可用时退化为 `fs::copy`（仅权限位）；
/// - 临时文件与原文件同目录同名扩展（`.alger-tags-<pid>-<n>.<ext>`），
///   隐藏且不进入曲库扫描；
/// - rename 在同一目录内完成（同一卷 → 原子）；rename 前 fsync 文件与目录，
///   rename 失败时清理临时文件；
/// - **冲突检测**：复制前记录 (inode, size, mtime_ns)，rename 前重新 stat，
///   不一致则返回冲突错误、不覆盖（其他 App 的修改不丢）。
fn with_safe_write(
    path: &Path,
    f: impl FnOnce(&Path) -> Result<(), TagError>,
) -> Result<(), TagError> {
    // 符号链接：解析到真实目标，避免 rename 把链接替换成普通文件（审查 F6）
    let path = &match std::fs::symlink_metadata(path) {
        Ok(m) if m.file_type().is_symlink() => {
            std::fs::canonicalize(path).map_err(|e| TagError::Open {
                path: path.display().to_string(),
                detail: format!("符号链接无法解析：{}", e),
            })?
        }
        _ => path.to_path_buf(),
    };
    // 写入前基线（冲突检测）：inode + 长度 + mtime 秒与纳秒。
    // 注意：必须包含 mtime **秒**——只用 mtime_nsec()（秒内纳秒部分）时，
    // 跨秒但同纳秒的修改会被误判为未修改（抽查确认问题）。
    // 同秒 + 同长度 + 同纳秒的原地同长改写无法仅靠 stat 区分，属已知限制。
    let before = std::fs::metadata(path).map_err(|e| TagError::open(path, e))?;
    let baseline = conflict_signature(&before);
    let dir = path.parent().ok_or_else(|| TagError::Write {
        path: path.display().to_string(),
        detail: "文件没有父目录".into(),
    })?;
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("audio")
        .to_string();
    let n = TMP_COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let tmp = dir.join(format!(
        ".alger-tags-{}-{}-{}.{}",
        std::process::id(),
        crate::now_millis(),
        n,
        ext
    ));
    let _ = std::fs::remove_file(&tmp);

    // 复制原文件（保留权限与扩展属性）
    let copied = std::process::Command::new("cp")
        .arg("-p")
        .arg(path)
        .arg(&tmp)
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if !copied {
        std::fs::copy(path, &tmp).map_err(|e| TagError::Write {
            path: path.display().to_string(),
            detail: format!("创建临时副本失败：{}", e),
        })?;
    }

    match f(&tmp) {
        Ok(()) => {}
        Err(e) => {
            let _ = std::fs::remove_file(&tmp);
            return Err(e);
        }
    }

    // rename 前冲突检测：原文件被其他 App 修改过则不覆盖（审查 F7）
    let after = std::fs::metadata(path).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        TagError::Write {
            path: path.display().to_string(),
            detail: format!("无法重新读取原文件状态：{}", e),
        }
    })?;
    if conflict_signature(&after) != baseline {
        let _ = std::fs::remove_file(&tmp);
        return Err(TagError::Write {
            path: path.display().to_string(),
            detail: "文件在写入期间被其他应用修改，已取消本次写入以避免覆盖".into(),
        });
    }

    // 落盘后再原子替换，缩小掉电窗口
    if let Ok(f) = std::fs::File::open(&tmp) {
        let _ = f.sync_all();
    }
    std::fs::rename(&tmp, path).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        TagError::Write {
            path: path.display().to_string(),
            detail: format!("替换原文件失败（原文件未改动）：{}", e),
        }
    })?;
    if let Ok(d) = std::fs::File::open(dir) {
        let _ = d.sync_all();
    }
    Ok(())
}

/// 自定义来源字段键（各容器统一写入同一语义键）。
const SOURCE_ID_KEY: &str = "ALGERSONGID";
/// MP4 freeform 的 mean（`----:com.alger.music:ALGERSONGID`）。
const SOURCE_ID_MEAN: &str = "com.alger.music";

/// MusicBrainz 唯一文件标识的 owner（标准值，lofty 内部常量未导出）。
const MB_UFID_OWNER: &str = "http://musicbrainz.org";

/// 内嵌封面体积上限（4 MiB）。
///
/// 桥接协议是单行 JSON，`tags.artwork` 返回的 base64 会被塞进一行里；
/// 协议行上限 8 MiB，base64 会膨胀约 4/3，因此原始图片上限取 4 MiB，
/// 保证编码后仍在限额内。超过上限的封面 **读取时** 明确报错，
/// 不会被截断、压缩或悄悄丢弃。
const MAX_ARTWORK_BYTES: usize = 4 * 1024 * 1024;

/// 标准标识字段（ISRC / MusicBrainz / 日期）——写后重读校验用。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct StandardFields {
    isrc: String,
    music_brainz_recording_id: String,
    music_brainz_release_id: String,
    date: String,
}

impl StandardFields {
    /// 从通用标签读取标准标识字段。
    fn from_tag(tag: &Tag) -> Self {
        Self {
            isrc: tag_string(tag, &ItemKey::Isrc),
            music_brainz_recording_id: tag_string(tag, &ItemKey::MusicBrainzRecordingId),
            music_brainz_release_id: tag_string(tag, &ItemKey::MusicBrainzReleaseId),
            date: tag_string(tag, &ItemKey::RecordingDate),
        }
    }
}

/// 来源 ID 的通用键（Id3v2 TXXX / Vorbis Comment 用）。
fn source_key_plain() -> ItemKey {
    ItemKey::Unknown(SOURCE_ID_KEY.to_string())
}

/// 来源 ID 的 MP4 freeform 完整键（不含 `----` 前缀的四字键会被
/// lofty 静默丢弃，必须写成 `----:mean:name` 全格式）。
fn source_key_mp4() -> ItemKey {
    ItemKey::Unknown(format!("----:{}:{}", SOURCE_ID_MEAN, SOURCE_ID_KEY))
}

/// 容器专用读取来源 ID。
///
/// lofty 0.22 读取 Id3v2 时，TXXX 用户文本帧保留在容器专用标签里，
/// **不进入通用 `Tag`**（`split_tag` 中 `Frame::UserText` 为 retained），
/// 因此通用 `get_string(ItemKey::Unknown(...))` 读不到 TXXX（审查 F1 根因）。
/// 读取规则：
/// - MP3 / AIFF / WAV（Id3v2）→ `Id3v2Tag::get_user_text("ALGERSONGID")`；
/// - M4A / MP4（ilst）→ 通用键 `----:com.alger.music:ALGERSONGID`（读写对称）；
/// - FLAC / Ogg / Opus（Vorbis Comment）→ 通用键 `ALGERSONGID`；
/// - 其他 → 通用键兜底（读不到按 0 = 未知，不猜测）。
pub fn read_source_id(path: &Path) -> Result<i64, TagError> {
    let (file, _) = read_file(path)?;
    read_source_id_from(&file, path)
}

/// 从已探测的 TaggedFile 读取来源 ID（验证路径复用；ID3 容器需按 path 重开，
/// 因为 TXXX 不进通用 Tag）。
fn read_source_id_from(file: &lofty::file::TaggedFile, path: &Path) -> Result<i64, TagError> {
    use lofty::file::FileType;
    use lofty::mpeg::MpegFile;

    let generic = primary_or_new(file);
    let parse = |s: Option<&str>| s.and_then(|v| v.trim().parse::<i64>().ok()).unwrap_or(0);

    match file.file_type() {
        FileType::Mpeg => {
            let mut f = std::fs::File::open(path).map_err(|e| TagError::open(path, e))?;
            let text = MpegFile::read_from(&mut f, lofty::config::ParseOptions::default())
                .ok()
                .and_then(|ff| {
                    ff.id3v2()
                        .and_then(|t| t.get_user_text(SOURCE_ID_KEY).map(str::to_string))
                });
            Ok(parse(text.as_deref()))
        }
        FileType::Aiff | FileType::Wav => {
            let mut f = std::fs::File::open(path).map_err(|e| TagError::open(path, e))?;
            let text = read_id3v2_user_text_other(&mut f, file.file_type());
            Ok(parse(text.as_deref()))
        }
        FileType::Mp4 => Ok(parse(generic.get_string(&source_key_mp4()))),
        _ => Ok(parse(generic.get_string(&source_key_plain()))),
    }
}

/// AIFF / WAV 的容器专用 id3v2 标签读取（ID3 chunk 里的标签）。
fn read_id3v2_tag_other(
    reader: &mut std::fs::File,
    file_type: lofty::file::FileType,
) -> Option<lofty::id3::v2::Id3v2Tag> {
    use lofty::file::AudioFile;
    let opts = lofty::config::ParseOptions::default();
    match file_type {
        lofty::file::FileType::Aiff => lofty::iff::aiff::AiffFile::read_from(reader, opts)
            .ok()
            .and_then(|ff| ff.id3v2().cloned()),
        lofty::file::FileType::Wav => lofty::iff::wav::WavFile::read_from(reader, opts)
            .ok()
            .and_then(|ff| ff.id3v2().cloned()),
        _ => None,
    }
}

/// AIFF / WAV 的容器专用 id3v2 用户文本读取（与 MpegFile 同 API 形态）。
fn read_id3v2_user_text_other(
    reader: &mut std::fs::File,
    file_type: lofty::file::FileType,
) -> Option<String> {
    read_id3v2_tag_other(reader, file_type)
        .and_then(|t| t.get_user_text(SOURCE_ID_KEY).map(str::to_string))
}

/// 支持的音频扩展名（与曲库扫描一致）。
pub const AUDIO_EXTENSIONS: [&str; 8] = ["mp3", "flac", "m4a", "aac", "ogg", "opus", "wav", "aiff"];

fn read_file(path: &Path) -> Result<(lofty::file::TaggedFile, String), TagError> {
    // **按内容签名探测**真实格式：扩展名不可信
    // （例如把 FLAC 内容写进一个 `.mp3` 路径，或反过来）。
    // 只按扩展名选解析器会让读标签直接失败。
    let tagged = Probe::open(path)
        .map_err(|e| TagError::open(path, e))?
        .guess_file_type()
        .map_err(|e| TagError::open(path, e))?
        .read()
        .map_err(|e| TagError::open(path, e))?;
    let format = format_of(&tagged, path);
    Ok((tagged, format))
}

/// 由 **实际文件类型** 推导容器格式名（不是扩展名）。
fn format_of(file: &lofty::file::TaggedFile, path: &Path) -> String {
    use lofty::file::FileType;
    match file.file_type() {
        FileType::Mpeg => "mp3".into(),
        FileType::Flac => "flac".into(),
        FileType::Vorbis => "ogg".into(),
        FileType::Opus => "opus".into(),
        FileType::Aiff => "aiff".into(),
        FileType::Wav => "wav".into(),
        FileType::Aac => "aac".into(),
        FileType::WavPack => "wv".into(),
        FileType::Ape => "ape".into(),
        FileType::Mp4 => "m4a".into(),
        // 识别不出 → 退回按扩展名（总比空串好）。
        _ => container_format(path),
    }
}

/// 实际音频编码（**不看扩展名**：m4a 既可能是 ALAC 也可能是 AAC）。
fn codec_of(file: &lofty::file::TaggedFile, path: &Path) -> String {
    use lofty::file::FileType;
    match file.file_type() {
        FileType::Mpeg => "mp3".into(),
        FileType::Flac => "flac".into(),
        FileType::Vorbis => "vorbis".into(),
        FileType::Opus => "opus".into(),
        FileType::Aiff => "pcm".into(),
        FileType::Wav => "pcm".into(),
        FileType::Aac => "aac".into(),
        FileType::WavPack => "wavpack".into(),
        FileType::Ape => "ape".into(),
        FileType::Mp4 => {
            // MP4 容器：真正的编码在 **MP4 专用属性** 里（ALAC / AAC / FLAC / MP3）。
            // 通用 `FileProperties` 没有 `codec()`，必须按 MP4 解析器再读一次。
            use lofty::config::ParseOptions;
            use lofty::file::AudioFile;
            use std::fs::File;
            let mut opened = match File::open(path) {
                Ok(file) => file,
                Err(_) => return String::new(),
            };
            match lofty::mp4::Mp4File::read_from(&mut opened, ParseOptions::new()) {
                Ok(mp4) => match mp4.properties().codec() {
                    lofty::mp4::Mp4Codec::AAC => "aac".into(),
                    lofty::mp4::Mp4Codec::ALAC => "alac".into(),
                    lofty::mp4::Mp4Codec::MP3 => "mp3".into(),
                    lofty::mp4::Mp4Codec::FLAC => "flac".into(),
                    _ => String::new(),
                },
                Err(_) => String::new(),
            }
        }
        _ => String::new(),
    }
}

/// 按扩展名 / 文件类型推断容器格式名。
fn container_format(path: &Path) -> String {
    match path
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_ascii_lowercase())
    {
        Some(ext) if AUDIO_EXTENSIONS.contains(&ext.as_str()) => ext,
        _ => "audio".to_string(),
    }
}

/// 取「最适合读写的标签」：优先主标签，其次第一个，最后为空标签（按格式新建）。
fn primary_or_new(file: &lofty::file::TaggedFile) -> Tag {
    if let Some(tag) = file.primary_tag() {
        return tag.clone();
    }
    if let Some(tag) = file.first_tag() {
        return tag.clone();
    }
    Tag::new(default_tag_type(file))
}

/// 无标签时的默认标签类型（按文件实际容器选择）。
fn default_tag_type(file: &lofty::file::TaggedFile) -> TagType {
    match file.file_type() {
        lofty::file::FileType::Mpeg => TagType::Id3v2,
        lofty::file::FileType::Aiff => TagType::Id3v2,
        lofty::file::FileType::Flac => TagType::VorbisComments,
        lofty::file::FileType::Vorbis => TagType::VorbisComments,
        lofty::file::FileType::Opus => TagType::VorbisComments,
        lofty::file::FileType::Mp4 => TagType::Mp4Ilst,
        lofty::file::FileType::Wav => TagType::Id3v2,
        _ => TagType::Id3v2,
    }
}

fn tag_string(tag: &Tag, key: &ItemKey) -> String {
    tag.get_string(key)
        .map(|s| s.trim().to_string())
        .unwrap_or_default()
}

fn tag_u32(tag: &Tag, key: &ItemKey) -> u32 {
    tag.get_string(key)
        .and_then(|s| s.split('/').next())
        .and_then(|s| s.trim().parse::<u32>().ok())
        .unwrap_or(0)
}

/// 读取音频文件的元信息（不返回封面字节）。
pub fn read_meta(path: &Path) -> Result<TrackMeta, TagError> {
    let (file, format) = read_file(path)?;
    let properties = file.properties();
    let tag = primary_or_new(&file);

    // 来源 ID 走容器专用读取（ID3v2 TXXX 不进通用 Tag，审查 F1 根因）
    let netease_id = read_source_id(path)?;

    // 标准标识字段（ISRC / MusicBrainz / 日期）
    let standard = StandardFields::from_tag(&tag);

    // 年份：优先日期字段（ID3v2 TDRC → RecordingDate），其次 Year
    let year = tag
        .get_string(&ItemKey::RecordingDate)
        .or_else(|| tag.get_string(&ItemKey::Year))
        .and_then(|d| d.get(..4).and_then(|y| y.parse::<u32>().ok()))
        .or_else(|| Some(tag_u32(&tag, &ItemKey::Year)))
        .unwrap_or_else(|| tag_u32(&tag, &ItemKey::Year));

    Ok(TrackMeta {
        path: path.display().to_string(),
        format,
        duration_ms: properties.duration().as_millis() as u64,
        // **单位**：lofty 的 `audio_bitrate()` 是 **kbps**，
        // 这里统一换算成 **bps**（与远端 `ResolvedAudio.br` 同单位），
        // 否则 192 kbps 的本地文件会被当成 192 bps → 误判「远端质量更高」。
        bitrate: properties.audio_bitrate().unwrap_or(0).saturating_mul(1000),
        sample_rate: properties.sample_rate().unwrap_or(0),
        bit_depth: properties.bit_depth().unwrap_or(0),
        codec: codec_of(&file, path),
        title: tag_string(&tag, &ItemKey::TrackTitle),
        artist: tag_string(&tag, &ItemKey::TrackArtist),
        album: tag_string(&tag, &ItemKey::AlbumTitle),
        album_artist: tag_string(&tag, &ItemKey::AlbumArtist),
        genre: tag_string(&tag, &ItemKey::Genre),
        track: tag_u32(&tag, &ItemKey::TrackNumber),
        disc: tag_u32(&tag, &ItemKey::DiscNumber),
        year,
        // 封面可能不在 primary 标签里（AIFF / WAV 双标签：原生 Text / RIFF 与
        // ID3 各存一份），必须扫全部标签区，否则会误报「无封面」。
        has_artwork: !collect_pictures(&file, path).is_empty(),
        file_size: std::fs::metadata(path).map(|m| m.len()).unwrap_or(0),
        netease_id,
        isrc: standard.isrc,
        music_brainz_recording_id: standard.music_brainz_recording_id,
        music_brainz_release_id: standard.music_brainz_release_id,
        date: standard.date,
    })
}

/// 内嵌封面（base64 编码，取最大的图片）。
///
/// **协议上限**：base64 后的体积必须小于 8 MiB 的单行协议上限，
/// 因此原始图片超过 [`MAX_ARTWORK_BYTES`]（4 MiB）时返回
/// [`TagError::Artwork`]，绝不产出超大协议行把整个 Bridge 客户端顶掉。
///
/// 注意：这里只是 **读取** 时的上限；文件里已存在的超大封面在写标签时
/// 不会被改写或删除（只要 patch 不涉及封面）。
pub fn artwork_base64(path: &Path) -> Result<String, TagError> {
    let (file, _format) = read_file(path)?;
    let pictures = collect_pictures(&file, path);
    // 选封面语义：**优先 Front（封面正面）里最大的那张**；
    // 只有完全没有 Front 时才退回「所有图片里最大的」。
    // 否则一张更大的 Back 图会让 Swift 侧读到的封面与写入的 Front 不一致。
    let picture = pictures
        .iter()
        .filter(|p| p.pic_type() == lofty::picture::PictureType::CoverFront)
        .max_by_key(|p| p.data().len())
        .or_else(|| pictures.iter().max_by_key(|p| p.data().len()))
        .ok_or_else(|| TagError::Artwork(format!("{}：文件内没有内嵌封面", path.display())))?;
    if picture.data().len() > MAX_ARTWORK_BYTES {
        return Err(TagError::Artwork(format!(
            "{}：内嵌封面 {} 字节，超过 {} 字节上限，无法通过协议返回",
            path.display(),
            picture.data().len(),
            MAX_ARTWORK_BYTES
        )));
    }
    Ok(base64::engine::general_purpose::STANDARD.encode(picture.data()))
}

/// 收集文件内全部封面（跨所有标签区）。
///
/// AIFF / WAV 同时有原生标签区（AIFF text chunks / WAV RIFF INFO）和
/// ID3 chunk，两处都可能带封面；只看 `primary_or_new` 的主标签会漏掉
/// 「封面在 ID3 里」的情况。
fn collect_pictures(file: &lofty::file::TaggedFile, path: &Path) -> Vec<lofty::picture::Picture> {
    let mut out: Vec<lofty::picture::Picture> = Vec::new();
    for tag in file.tags() {
        for picture in tag.pictures() {
            out.push(picture.clone());
        }
    }
    // AIFF / WAV：ID3 chunk 的封面可能不在通用标签里（双标签容器），
    // 这里再用容器专用 API 兜底读一次。
    match file.file_type() {
        lofty::file::FileType::Aiff | lofty::file::FileType::Wav => {
            if let Ok(mut handle) = std::fs::File::open(path) {
                if let Some(id3) = read_id3v2_tag_other(&mut handle, file.file_type()) {
                    let generic = Tag::from(id3);
                    for picture in generic.pictures() {
                        out.push(picture.clone());
                    }
                }
            }
        }
        _ => {}
    }
    out
}

/// 写入标签并重新读取验证。
///
/// 流程（审查 F1 / E5）：
/// - **同一 safe 副本事务**：标签与来源 ID 在同一个临时副本上一次写完，
///   写后重读校验全部请求字段，任何一步失败原文件零改动；
/// - **容器专用路径**：ID3v2 容器（MP3 / AIFF / WAV）走容器原生 API，
///   AIFF / WAV 的原生标签区（text chunks / RIFF INFO）与 ID3 chunk
///   **双标签同时保留**；
/// - 标准元信息用 lofty 既有 `ItemKey` 映射（ISRC / MusicBrainz / 日期），
///   来源 ID 继续用容器专用 `ALGERSONGID`。
///
/// 返回写后实读的 [`TrackMeta`]；调用方必须据此显示「未保存」。
pub fn write_tags(path: &Path, patch: &TagPatch) -> Result<TrackMeta, TagError> {
    // 写前基线：时长与容器类型（用于音频完整性校验；按 file_type 而非扩展名，
    // 避免「格式改变」校验恒为假阳性 —— 审查 F8）
    let (before_file, _) = read_file(path)?;
    let before_duration = before_file.properties().duration().as_millis() as u64;
    let before_ft = before_file.file_type();
    // patch 不涉及来源 ID 时它必须原样保留（下载关联不丢）
    let before_source_id = read_source_id_from(&before_file, path)?;

    with_safe_write(path, |tmp| {
        // 1) 在副本上一次事务内写入「标签 + 来源 ID」
        apply_patch_to_file(tmp, patch)?;

        // —— 副本上的读回验证 ——
        let (verify_file, _verify_format) = read_file(tmp)?;
        let verify_tag = primary_or_new(&verify_file);
        let mut problems: Vec<String> = Vec::new();
        check_field(
            &mut problems,
            "标题",
            &patch.title,
            &tag_string(&verify_tag, &ItemKey::TrackTitle),
        );
        check_field(
            &mut problems,
            "艺人",
            &patch.artist,
            &tag_string(&verify_tag, &ItemKey::TrackArtist),
        );
        check_field(
            &mut problems,
            "专辑",
            &patch.album,
            &tag_string(&verify_tag, &ItemKey::AlbumTitle),
        );
        check_field(
            &mut problems,
            "专辑艺人",
            &patch.album_artist,
            &tag_string(&verify_tag, &ItemKey::AlbumArtist),
        );
        check_field(
            &mut problems,
            "流派",
            &patch.genre,
            &tag_string(&verify_tag, &ItemKey::Genre),
        );
        // 曲序 / 碟序：写后必须核验实际值；显式 0 = 清除（读回必须是 0）。
        if let Some(n) = patch.track {
            let got = tag_u32(&verify_tag, &ItemKey::TrackNumber);
            if n == 0 {
                if got != 0 {
                    problems.push(format!("曲序 未清除（读回 {}）", got));
                }
            } else if got != n {
                problems.push(format!("曲序写为 {}，读回 {}", n, got));
            }
        }
        if let Some(n) = patch.disc {
            let got = tag_u32(&verify_tag, &ItemKey::DiscNumber);
            if n == 0 {
                if got != 0 {
                    problems.push(format!("碟序 未清除（读回 {}）", got));
                }
            } else if got != n {
                problems.push(format!("碟序写为 {}，读回 {}", n, got));
            }
        }

        // 标准标识字段（ISRC / MusicBrainz / 日期）
        let got_standard = StandardFields::from_tag(&verify_tag);
        check_field(&mut problems, "ISRC", &patch.isrc, &got_standard.isrc);
        check_field(
            &mut problems,
            "MusicBrainz 录音 ID",
            &patch.music_brainz_recording_id,
            &got_standard.music_brainz_recording_id,
        );
        check_field(
            &mut problems,
            "MusicBrainz 发行 ID",
            &patch.music_brainz_release_id,
            &got_standard.music_brainz_release_id,
        );
        // 日期：date（完整年月日）优先，其次 year
        if let Some(d) = &patch.date {
            let want = d.trim().to_string();
            if want.is_empty() {
                if !got_standard.date.is_empty() {
                    problems.push(format!("日期 未清除（仍为「{}」）", got_standard.date));
                }
            } else if !date_matches(&want, &got_standard.date) {
                problems.push(format!(
                    "日期 写为「{}」，读回「{}」",
                    want, got_standard.date
                ));
            }
        } else if let Some(y) = patch.year {
            if y > 0 {
                let want = y.to_string();
                if !date_matches(&want, &got_standard.date)
                    && tag_u32(&verify_tag, &ItemKey::Year) != y
                {
                    problems.push(format!("年份 写为 {}，读回「{}」", y, got_standard.date));
                }
            } else {
                // year=0 且未给 date：Year 与 RecordingDate 都必须被清除。
                if !got_standard.date.is_empty() {
                    problems.push(format!("年份 未清除（日期仍为「{}」）", got_standard.date));
                }
                if tag_u32(&verify_tag, &ItemKey::Year) != 0 {
                    problems.push("年份键 未清除".into());
                }
            }
        }

        // 封面（跨所有标签区：AIFF / WAV 双标签时封面可能在 ID3 里）
        let verify_pictures = collect_pictures(&verify_file, tmp);
        if patch.artwork_base64.is_some() && verify_pictures.is_empty() {
            problems.push("封面写入后未读回".into());
        }
        if patch.remove_artwork && !verify_pictures.is_empty() {
            problems.push("封面未移除".into());
        }

        // 音频流完整性：容器类型一致、时长一致、来源 ID 未丢、文件非空
        let tmp_props = verify_file.properties();
        if verify_file.file_type() != before_ft {
            problems.push(format!(
                "容器类型改变（{:?} → {:?}）",
                before_ft,
                verify_file.file_type()
            ));
        }
        if tmp_props.duration().as_millis() as u64 != before_duration {
            problems.push(format!(
                "音频时长改变（{}ms → {}ms），疑似音频流被破坏",
                before_duration,
                tmp_props.duration().as_millis()
            ));
        }
        match read_source_id_from(&verify_file, tmp) {
            Ok(id) if id == expected_source_id(patch, before_source_id) => {}
            Ok(id) => problems.push(format!(
                "来源 ID 写为 {}，读回 {}",
                expected_source_id(patch, before_source_id),
                id
            )),
            Err(e) => problems.push(format!("来源 ID 验证读取失败：{}", e)),
        }
        let tmp_size = std::fs::metadata(tmp).map(|m| m.len()).unwrap_or(0);
        if tmp_size == 0 {
            problems.push("临时副本为空文件".into());
        }
        if !problems.is_empty() {
            return Err(TagError::Verify {
                path: tmp.display().to_string(),
                detail: problems.join("；"),
            });
        }
        Ok(())
    })?;

    // 原文件已被原子替换；以真实文件为准再读一次返回
    let after = read_meta(path)?;
    Ok(after)
}

/// 日期比较：ID3v2 的 `TDRC` 读回是时间戳（可能补 `T00:00:00`），
/// 只要年月日部分一致即视为写回成功（完整年月日必须保留）。
fn date_matches(want: &str, got: &str) -> bool {
    let want = want.trim();
    if want.is_empty() {
        return got.trim().is_empty();
    }
    if want == got.trim() {
        return true;
    }
    want.len() == 10
        && got.len() >= 10
        && want.eq_ignore_ascii_case(got.trim().get(..10).unwrap_or(""))
}

/// 单字段写后重读校验（`None` = 不修改，不校验）。
fn check_field(problems: &mut Vec<String>, name: &str, want: &Option<String>, got: &str) {
    let Some(w) = want else {
        return;
    };
    let w = w.trim();
    if w.is_empty() {
        if !got.is_empty() {
            problems.push(format!("{} 未清除（仍为「{}」）", name, got));
        }
    } else if got != w {
        problems.push(format!("{} 写为「{}」，读回「{}」", name, w, got));
    }
}

/// 期望的来源 ID：patch 未给 → 保持原值；给了 ≤0 → 清除（0）。
fn expected_source_id(patch: &TagPatch, before: i64) -> i64 {
    match patch.netease_id {
        None => before,
        Some(id) => id.max(0),
    }
}

// ---------------------------------------------------------------------------
// 写入实现（容器专用路径）
// ---------------------------------------------------------------------------

/// 把 patch 应用到容器（不做校验，写后由调用方重读校验）。
///
/// - **ID3v2 容器**（MP3 / AIFF / WAV）：走容器原生 API
///   （`MpegFile` / `AiffFile` / `WavFile`），原生帧直接保留，
///   AIFF / WAV 的双标签（原生 Text / RIFF + ID3 chunk）同时保留；
/// - **其余容器**（FLAC / Ogg / Opus / M4A …）：走通用标签路径，
///   来源 ID 用容器专用键写入同一标签区（一次保存）。
fn apply_patch_to_file(path: &Path, patch: &TagPatch) -> Result<(), TagError> {
    let (file, _format) = read_file(path)?;
    match file.file_type() {
        lofty::file::FileType::Mpeg => write_id3v2_mpeg(path, patch),
        lofty::file::FileType::Aiff => write_id3v2_aiff(path, patch),
        lofty::file::FileType::Wav => write_id3v2_wav(path, patch),
        _ => write_generic_tags(path, patch),
    }
}

/// MP3：ID3v2 原生标签（容器专用 API，未映射帧原样保留）。
fn write_id3v2_mpeg(path: &Path, patch: &TagPatch) -> Result<(), TagError> {
    use lofty::mpeg::MpegFile;

    let mut handle = std::fs::File::open(path).map_err(|e| TagError::open(path, e))?;
    let mut mpeg = MpegFile::read_from(&mut handle, lofty::config::ParseOptions::default())
        .map_err(|e| TagError::Read {
            path: path.display().to_string(),
            detail: e.to_string(),
        })?;
    if mpeg.id3v2().is_none() {
        mpeg.set_id3v2(lofty::id3::v2::Id3v2Tag::new());
    }
    {
        let id3 = mpeg.id3v2_mut().expect("ID3v2 标签已创建");
        apply_id3v2_patch(id3, patch)?;
    }
    mpeg.save_to_path(path, lofty::config::WriteOptions::default())
        .map_err(|e| TagError::Write {
            path: path.display().to_string(),
            detail: e.to_string(),
        })?;
    Ok(())
}

/// AIFF：ID3 chunk 写标准元信息与来源 ID，原生 text chunks 保留。
fn write_id3v2_aiff(path: &Path, patch: &TagPatch) -> Result<(), TagError> {
    use lofty::iff::aiff::AiffFile;

    let mut handle = std::fs::File::open(path).map_err(|e| TagError::open(path, e))?;
    let mut aiff = AiffFile::read_from(&mut handle, lofty::config::ParseOptions::default())
        .map_err(|e| TagError::Read {
            path: path.display().to_string(),
            detail: e.to_string(),
        })?;
    if aiff.id3v2().is_none() {
        aiff.set_id3v2(lofty::id3::v2::Id3v2Tag::new());
    }
    {
        let id3 = aiff.id3v2_mut().expect("ID3v2 标签已创建");
        apply_id3v2_patch(id3, patch)?;
    }
    // 原生 text chunks：**已存在**时同步标题 / 艺人，保持两个标签区一致。
    // 不新建：lofty 0.22 在「没有可替换的原生 chunk」时插入点按小端解析
    // AIFF 的大端 COMM 长度，插入点会算错（有损坏文件的风险），
    // 因此没有原生 chunk 时只写 ID3 chunk。
    if let Some(text) = aiff.text_chunks_mut() {
        if let Some(v) = &patch.title {
            text.name = non_empty(v);
        }
        if let Some(v) = &patch.artist {
            text.author = non_empty(v);
        }
    }
    aiff.save_to_path(path, lofty::config::WriteOptions::default())
        .map_err(|e| TagError::Write {
            path: path.display().to_string(),
            detail: e.to_string(),
        })?;
    Ok(())
}

/// WAV：ID3 chunk 写标准元信息与来源 ID，原生 RIFF INFO 保留。
fn write_id3v2_wav(path: &Path, patch: &TagPatch) -> Result<(), TagError> {
    use lofty::iff::wav::WavFile;

    let mut handle = std::fs::File::open(path).map_err(|e| TagError::open(path, e))?;
    let mut wav =
        WavFile::read_from(&mut handle, lofty::config::ParseOptions::default()).map_err(|e| {
            TagError::Read {
                path: path.display().to_string(),
                detail: e.to_string(),
            }
        })?;
    if wav.id3v2().is_none() {
        wav.set_id3v2(lofty::id3::v2::Id3v2Tag::new());
    }
    {
        let id3 = wav.id3v2_mut().expect("ID3v2 标签已创建");
        apply_id3v2_patch(id3, patch)?;
    }
    // 原生 RIFF INFO：已存在时同步可映射字段（INAM / IART / IPRD / IGNR /
    // IPRT / ICRD），保持两个标签区一致。显式 0 = 清除对应键，
    // 不能让旧值留在原生区里。
    if let Some(info) = wav.riff_info_mut() {
        if let Some(v) = &patch.title {
            set_riff_info(info, "INAM", v);
        }
        if let Some(v) = &patch.artist {
            set_riff_info(info, "IART", v);
        }
        if let Some(v) = &patch.album {
            set_riff_info(info, "IPRD", v);
        }
        if let Some(v) = &patch.genre {
            set_riff_info(info, "IGNR", v);
        }
        match patch.track {
            Some(0) => {
                let _ = info.remove("IPRT");
            }
            Some(n) => {
                info.insert("IPRT".to_string(), n.to_string());
            }
            None => {}
        }
        // 日期 / 年份 → ICRD：date 优先；year=0 且未给 date 时清除。
        if let Some(d) = &patch.date {
            set_riff_info(info, "ICRD", d);
        } else if let Some(y) = patch.year {
            if y == 0 {
                let _ = info.remove("ICRD");
            } else {
                info.insert("ICRD".to_string(), y.to_string());
            }
        }
    }
    wav.save_to_path(path, lofty::config::WriteOptions::default())
        .map_err(|e| TagError::Write {
            path: path.display().to_string(),
            detail: e.to_string(),
        })?;
    Ok(())
}

/// 通用标签路径（FLAC / Ogg / Opus / M4A …）：标签与来源 ID 一次写完。
fn write_generic_tags(path: &Path, patch: &TagPatch) -> Result<(), TagError> {
    let mut tagged = Probe::open(path)
        .map_err(|e| TagError::open(path, e))?
        .read()
        .map_err(|e| TagError::open(path, e))?;
    let tag_type = tagged
        .primary_tag()
        .map(|t| t.tag_type())
        .unwrap_or_else(|| default_tag_type(&tagged));
    let mut tag = primary_or_new(&tagged);
    apply_generic_fields(&mut tag, patch, true)?;

    // 来源 ID：容器专用键。通用 Tag 的 `Unknown` 键会被 lofty 的映射检查
    // 静默丢弃，必须用 `insert_unchecked` 绕过（写入的仍是同一语义键）。
    if let Some(id) = patch.netease_id {
        let key = source_key_for(tag_type);
        if id > 0 {
            tag.insert_unchecked(TagItem::new(key, ItemValue::Text(id.to_string())));
        } else {
            tag.remove_key(&key);
        }
    }

    // 用修改后的标签替换文件中的同类型标签；其他类型的标签原样保留。
    tagged.remove(tag_type);
    tagged.insert_tag(tag);
    tagged
        .save_to_path(path, lofty::config::WriteOptions::default())
        .map_err(|e| TagError::Write {
            path: path.display().to_string(),
            detail: e.to_string(),
        })?;
    Ok(())
}

/// 把 patch 的通用字段应用到标签（`None` = 不修改）。
///
/// `allow_mb_recording_id`：ID3v2 的 `ID3V2_MAP` **没有**
/// `MusicBrainzRecordingId` 的条目，因此 `Tag::insert` 的映射检查
/// （`TagItem::re_map` → `map_key(TagType::Id3v2, false)` 返回 `None`）
/// 会把这个键**静默丢弃**——通用 `Tag` 根本装不下这个值。
/// lofty 里带 UFID 分支的是 `From<TagItem> for Option<Frame>`
/// （`id3/v2/frame/conversion.rs`），但那条分支只在
/// `Id3v2Tag::from(tag)` 的合并路径生效；通用 `Tag::save_to` 实际走的
/// `TryFrom<&TagItem> for FrameRef` **没有** UFID 分支，写出时会被丢掉。
/// 所以 ID3v2 走容器专用的显式 UFID 路径（见 `apply_mb_recording_id_ufid`）。
fn apply_generic_fields(
    tag: &mut Tag,
    patch: &TagPatch,
    allow_mb_recording_id: bool,
) -> Result<(), TagError> {
    let tag_type = tag.tag_type();

    let set_text = |tag: &mut Tag, key: ItemKey, value: &Option<String>| {
        if let Some(v) = value {
            let v = v.trim();
            if v.is_empty() {
                tag.remove_key(&key);
            } else {
                tag.insert(TagItem::new(key, ItemValue::Text(v.to_string())));
            }
        }
    };
    set_text(tag, ItemKey::TrackTitle, &patch.title);
    set_text(tag, ItemKey::TrackArtist, &patch.artist);
    set_text(tag, ItemKey::AlbumTitle, &patch.album);
    set_text(tag, ItemKey::AlbumArtist, &patch.album_artist);
    set_text(tag, ItemKey::Genre, &patch.genre);
    // 曲序 / 碟序：显式 `Some(0)` = **清除**对应标签键
    // （不是写 "0"，也不是像旧实现那样 `if n > 0` 直接忽略）。
    match patch.track {
        Some(0) => {
            tag.remove_key(&ItemKey::TrackNumber);
            tag.remove_key(&ItemKey::TrackTotal);
        }
        Some(n) => {
            tag.insert(TagItem::new(
                ItemKey::TrackNumber,
                ItemValue::Text(n.to_string()),
            ));
        }
        None => {}
    }
    match patch.disc {
        Some(0) => {
            tag.remove_key(&ItemKey::DiscNumber);
            tag.remove_key(&ItemKey::DiscTotal);
        }
        Some(n) => {
            tag.insert(TagItem::new(
                ItemKey::DiscNumber,
                ItemValue::Text(n.to_string()),
            ));
        }
        None => {}
    }
    // 日期：完整年月日优先；没有 date 时才用 year（保持既有语义）。
    if let Some(d) = &patch.date {
        let d = d.trim().to_string();
        if d.is_empty() {
            tag.remove_key(&ItemKey::RecordingDate);
        } else {
            tag.insert(TagItem::new(ItemKey::RecordingDate, ItemValue::Text(d)));
        }
        // date 优先：显式 year=0 只清 Year 键，不再动 RecordingDate。
        if patch.year == Some(0) {
            tag.remove_key(&ItemKey::Year);
        }
    } else if let Some(y) = patch.year {
        if y > 0 {
            let date_text = y.to_string();
            // 按容器实际映射写日期字段：ID3v2 只有 RecordingDate（TDRC）
            // 有映射；ItemKey::Year 在 ID3v2 中无映射、直接写入会被
            // lofty 静默丢弃，所以两者都按 `map_key` 判定后再写。
            if ItemKey::RecordingDate.map_key(tag_type, false).is_some() {
                tag.insert(TagItem::new(
                    ItemKey::RecordingDate,
                    ItemValue::Text(date_text.clone()),
                ));
            }
            if ItemKey::Year.map_key(tag_type, false).is_some() {
                tag.insert(TagItem::new(ItemKey::Year, ItemValue::Text(date_text)));
            }
        } else {
            // year=0 且未给 date：清除 Year 与 RecordingDate。
            tag.remove_key(&ItemKey::Year);
            tag.remove_key(&ItemKey::RecordingDate);
        }
    }
    // 标准标识字段（lofty 既有映射，不另造自定义 MB 键）。
    set_text(tag, ItemKey::Isrc, &patch.isrc);
    set_text(
        tag,
        ItemKey::MusicBrainzReleaseId,
        &patch.music_brainz_release_id,
    );
    if allow_mb_recording_id {
        set_text(
            tag,
            ItemKey::MusicBrainzRecordingId,
            &patch.music_brainz_recording_id,
        );
    }

    if patch.remove_artwork {
        let types: Vec<lofty::picture::PictureType> =
            tag.pictures().iter().map(|p| p.pic_type()).collect();
        for t in types {
            tag.remove_picture_type(t);
        }
    }
    if let Some(b64) = &patch.artwork_base64 {
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(b64.trim())
            .map_err(|e| TagError::Artwork(format!("base64 解码失败：{}", e)))?;
        if bytes.is_empty() {
            return Err(TagError::Artwork("封面数据为空".into()));
        }
        // 协议行上限保护：超大封面写不进去（读取时同样报错）。
        if bytes.len() > MAX_ARTWORK_BYTES {
            return Err(TagError::Artwork(format!(
                "封面数据 {} 字节，超过 {} 字节上限",
                bytes.len(),
                MAX_ARTWORK_BYTES
            )));
        }
        let mime_type = if bytes.starts_with(&[0x89, b'P', b'N', b'G']) {
            lofty::picture::MimeType::Png
        } else {
            lofty::picture::MimeType::Jpeg
        };
        let picture = lofty::picture::Picture::new_unchecked(
            lofty::picture::PictureType::CoverFront,
            Some(mime_type),
            None,
            bytes,
        );
        // 写入语义：**替换 Front（封面正面）**，其它图片（Back / 未知类型）
        // 原样保留；没有 Front 时才追加为 Front。
        // 与读取语义对称（读取同样优先 Front），Swift 侧按返回字节校验。
        match tag
            .pictures()
            .iter()
            .position(|p| p.pic_type() == lofty::picture::PictureType::CoverFront)
        {
            Some(index) => tag.set_picture(index, picture),
            None => {
                let index = tag.pictures().len();
                tag.set_picture(index, picture);
            }
        }
    }
    Ok(())
}

/// ID3v2 容器专用的 patch 应用。
///
/// - 通用字段走「原生帧 → 通用 Tag → 原生帧」：未被映射的帧由 lofty 的
///   companion 机制保留（未知二进制帧 / PRIV / 封面不会被丢）；
/// - MusicBrainz 录音 ID **显式**构造容器标准 `UFID` 帧：
///   `ItemKey::MusicBrainzRecordingId` 在 `ID3V2_MAP` 里没有条目，
///   `Tag::insert` 会按映射检查静默丢弃该键；lofty 带 UFID 分支的
///   `From<TagItem> for Option<Frame>`（`id3/v2/frame/conversion.rs`）
///   只在 `Id3v2Tag::from(tag)` 合并路径生效，而通用 `Tag::save_to` 走的
///   `TryFrom<&TagItem> for FrameRef` 没有 UFID 分支。
///   这里直接构造 `Frame::UniqueFileIdentifier` 并由原生帧路径写出，
///   保证 UFID 真正落盘；
/// - 来源 ID 用 `TXXX:ALGERSONGID`。
fn apply_id3v2_patch(id3: &mut lofty::id3::v2::Id3v2Tag, patch: &TagPatch) -> Result<(), TagError> {
    let mut generic = Tag::from(id3.clone());
    apply_generic_fields(&mut generic, patch, false)?;
    let mut rebuilt = lofty::id3::v2::Id3v2Tag::from(generic);

    apply_mb_recording_id_ufid(&mut rebuilt, patch.music_brainz_recording_id.as_deref());
    apply_source_id_txxx(&mut rebuilt, patch.netease_id);

    *id3 = rebuilt;
    Ok(())
}

/// 写 / 清除 MusicBrainz 录音 ID（ID3v2 标准 `UFID` 帧）。
fn apply_mb_recording_id_ufid(id3: &mut lofty::id3::v2::Id3v2Tag, value: Option<&str>) {
    use lofty::id3::v2::{Frame, FrameId, UniqueFileIdentifierFrame};
    use std::borrow::Cow;

    let Some(value) = value else {
        return; // None = 不修改
    };

    // 先移除既有的 UFID（其它 owner 的 UFID 原样放回）。
    let removed: Vec<Frame<'static>> = id3.remove(&FrameId::Valid(Cow::Borrowed("UFID"))).collect();
    for frame in removed {
        let keep = matches!(&frame, Frame::UniqueFileIdentifier(u) if u.owner != MB_UFID_OWNER);
        if keep {
            id3.insert(frame);
        }
    }

    let value = value.trim();
    if value.is_empty() {
        return; // 空串 = 清除
    }
    id3.insert(Frame::UniqueFileIdentifier(UniqueFileIdentifierFrame::new(
        MB_UFID_OWNER.to_string(),
        value.as_bytes().to_vec(),
    )));
}

/// 写 / 清除来源 ID（`TXXX:ALGERSONGID`）。
fn apply_source_id_txxx(id3: &mut lofty::id3::v2::Id3v2Tag, netease_id: Option<i64>) {
    match netease_id {
        None => {}
        Some(id) if id > 0 => {
            id3.insert_user_text(SOURCE_ID_KEY.to_string(), id.to_string());
        }
        Some(_) => {
            id3.remove_user_text(SOURCE_ID_KEY);
        }
    }
}

/// 容器对应的来源 ID 键（与读取路径对称）。
fn source_key_for(tag_type: TagType) -> ItemKey {
    match tag_type {
        TagType::Mp4Ilst => source_key_mp4(),
        _ => source_key_plain(),
    }
}

/// 空串 → `None`（表示不写该字段）。
fn non_empty(value: &str) -> Option<String> {
    let value = value.trim();
    if value.is_empty() {
        None
    } else {
        Some(value.to_string())
    }
}

/// 写 WAV 的 RIFF INFO 字段（空串 = 清除）。
fn set_riff_info(info: &mut lofty::iff::wav::RiffInfoList, key: &str, value: &str) {
    match non_empty(value) {
        Some(v) => {
            info.insert(key.to_string(), v);
        }
        None => {
            let _ = info.remove(key);
        }
    }
}

/// 写入来源关联 ID（下载完成后由 Swift 调用，使索引能跨重启关联）。
///
/// 走与标签写入完全相同的「临时副本 → 写后重读 → 原子替换」事务，
/// 只写这一个容器专用字段（`ALGERSONGID`）。
/// AIFF / WAV 也支持（写进 ID3 chunk），与读取路径对称。
pub fn write_source_id(path: &Path, netease_id: i64) -> Result<(), TagError> {
    let patch = TagPatch {
        netease_id: Some(netease_id),
        ..Default::default()
    };
    write_tags(path, &patch).map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    /// 夹具目录（.artifacts/fixtures/<run>），由 build 固定的测试根提供。
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

    fn fixture_dir(name: &str) -> PathBuf {
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../.artifacts/fixtures")
            .join(name);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// 生成最小可读的 MP3（ID3v2 头 + 若干静音帧）。
    fn make_mp3(path: &Path) {
        let mut data: Vec<u8> = Vec::new();
        data.extend_from_slice(b"ID3\x03\x00\x00\x00\x00\x00\x00"); // 10 字节 ID3v2 空头
                                                                    // MPEG-1 Layer III 128kbps 44100Hz 静音帧：帧头 + 全零数据
        let frame_header: [u8; 4] = [0xff, 0xfb, 0x90, 0x00];
        for _ in 0..64 {
            data.extend_from_slice(&frame_header);
            data.extend(std::iter::repeat_n(0u8, 413));
        }
        std::fs::write(path, data).unwrap();
    }

    #[test]
    fn read_write_roundtrip_preserves_audio_and_unknown_fields() {
        let dir = fixture_dir(format!("tags-{}", std::process::id()).as_str());
        let path = dir.join("周杰伦 - 晴天.mp3");
        make_mp3(&path);

        let mut patch = TagPatch {
            title: Some("晴天".into()),
            artist: Some("周杰伦".into()),
            album: Some("叶惠美".into()),
            album_artist: Some("周杰伦".into()),
            genre: Some("Pop".into()),
            track: Some(3),
            disc: Some(1),
            year: Some(2003),
            ..Default::default()
        };
        let meta = write_tags(&path, &patch).expect("首次写入");
        assert_eq!(meta.title, "晴天");
        assert_eq!(meta.artist, "周杰伦");
        assert_eq!(meta.track, 3);
        assert_eq!(meta.year, 2003);

        // 未提供的字段不被清除；中文与空格路径保持不变
        patch = TagPatch {
            title: Some("晴天 (Live)".into()),
            ..Default::default()
        };
        let meta2 = write_tags(&path, &patch).unwrap();
        assert_eq!(meta2.title, "晴天 (Live)");
        assert_eq!(meta2.artist, "周杰伦");
        assert_eq!(meta2.album, "叶惠美");

        // 音频数据未被破坏：仍是 MP3 帧
        let raw = std::fs::read(&path).unwrap();
        assert!(raw.starts_with(b"ID3"));

        // 来源 ID 写读一致
        write_source_id(&path, 186016).unwrap();
        let meta3 = read_meta(&path).unwrap();
        assert_eq!(meta3.netease_id, 186016);

        std::fs::remove_dir_all(&dir).ok();
    }

    /// 回归：先写来源 ID，再改标题，来源 ID 必须仍在（TXXX 保留）。
    #[test]
    fn source_id_survives_title_rewrite() {
        let dir = fixture_dir(format!("tags-order-{}", std::process::id()).as_str());
        let path = dir.join("order.mp3");
        make_mp3(&path);

        write_source_id(&path, 186016).unwrap();
        let meta = write_tags(
            &path,
            &TagPatch {
                title: Some("晴天".into()),
                artist: Some("周杰伦".into()),
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(meta.title, "晴天");
        assert_eq!(
            meta.netease_id, 186016,
            "改标题后来源 ID 必须保留（TXXX 帧不能丢）"
        );

        // 反向顺序同样成立
        let path2 = dir.join("order2.mp3");
        make_mp3(&path2);
        write_tags(
            &path2,
            &TagPatch {
                title: Some("七里香".into()),
                ..Default::default()
            },
        )
        .unwrap();
        write_source_id(&path2, 347230).unwrap();
        let meta2 = write_tags(
            &path2,
            &TagPatch {
                title: Some("七里香 (Remaster)".into()),
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(meta2.netease_id, 347230);
        assert_eq!(meta2.title, "七里香 (Remaster)");

        std::fs::remove_dir_all(&dir).ok();
    }

    /// 失败注入：目标目录只读时写入必须失败，且原文件字节不变。
    #[test]
    fn failed_write_leaves_original_bytes_untouched() {
        let dir = fixture_dir(format!("tags-ro-{}", std::process::id()).as_str());
        let path = dir.join("ro.mp3");
        make_mp3(&path);
        let original = std::fs::read(&path).unwrap();
        // 来源 ID 写入成功（目录可写）
        write_source_id(&path, 186016).unwrap();
        let with_id = std::fs::read(&path).unwrap();
        assert_ne!(with_id, original);

        // 只读目录 → 临时副本无法创建 → 报错且原文件不变
        let _read_only = ReadOnlyDir::enter(&dir);
        let result = write_tags(
            &path,
            &TagPatch {
                title: Some("不该写入".into()),
                ..Default::default()
            },
        );

        assert!(result.is_err(), "只读目录下写入必须失败");
        assert_eq!(
            std::fs::read(&path).unwrap(),
            with_id,
            "失败后原文件必须字节不变"
        );
        // 无残留临时文件
        let leftovers = std::fs::read_dir(&dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .any(|e| e.file_name().to_string_lossy().starts_with(".alger-tags-"));
        assert!(!leftovers, "失败后不得残留临时文件");

        drop(_read_only);
        std::fs::remove_dir_all(&dir).expect("权限故障夹具应可清理");
    }

    /// 权限位保留：0600 文件写标签后 mode 不变。
    #[test]
    fn write_preserves_permission_bits() {
        use std::os::unix::fs::PermissionsExt;
        let dir = fixture_dir(format!("tags-mode-{}", std::process::id()).as_str());
        let path = dir.join("mode.mp3");
        make_mp3(&path);
        let mut perm = std::fs::metadata(&path).unwrap().permissions();
        perm.set_mode(0o600);
        std::fs::set_permissions(&path, perm).unwrap();

        write_source_id(&path, 186016).unwrap();
        write_tags(
            &path,
            &TagPatch {
                title: Some("晴天".into()),
                ..Default::default()
            },
        )
        .unwrap();
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "写标签不得改变权限位");

        std::fs::remove_dir_all(&dir).ok();
    }

    /// 符号链接：写标签应作用于链接目标，链接本身保持符号链接。
    #[test]
    fn write_through_symlink_keeps_link() {
        let dir = fixture_dir(format!("tags-link-{}", std::process::id()).as_str());
        let target = dir.join("real.mp3");
        let link = dir.join("link.mp3");
        make_mp3(&target);
        std::os::unix::fs::symlink(&target, &link).unwrap();

        write_source_id(&link, 186016).unwrap();
        let m = std::fs::symlink_metadata(&link).unwrap();
        assert!(m.file_type().is_symlink(), "链接不得被替换成普通文件");
        assert_eq!(read_meta(&target).unwrap().netease_id, 186016);
        assert_eq!(read_meta(&link).unwrap().netease_id, 186016);

        std::fs::remove_dir_all(&dir).ok();
    }

    /// 用 ffmpeg 合成夹具，覆盖 **MP3 / FLAC / M4A** 三种受控格式的
    /// 「来源 ID 写读 + 改标题保留来源 ID + 未知字段保留」往返。
    ///
    /// AIFF / WAV 不在本用例内：它们的来源 ID 需要容器专用写入路径
    /// （当前明确拒绝，见 `aiff_wav_source_id_is_explicitly_rejected_without_touching_file`）。
    ///
    /// 环境无 ffmpeg 时 **明确跳过**（不计入通过）；`REQUIRE_FFMPEG=1` 时
    /// 直接失败（审查 E1-7：不允许把「没跑」写成「通过」）。
    #[test]
    fn multi_format_roundtrip_with_real_containers() {
        let Some(ffmpeg) = ffmpeg_or_skip(&ffmpeg_candidates()) else {
            return;
        };
        let dir = fixture_dir(format!("tags-multi-{}", std::process::id()).as_str());

        // (扩展名, ffmpeg 编码参数)。AIFF / WAV 的来源 ID 走容器专用写入
        // 路径（尚未实现，见 aiff_wav_source_id_is_explicitly_rejected），
        // 因此这里只覆盖受控格式 MP3 / FLAC / M4A。
        let formats: [(&str, [&str; 2]); 3] = [
            ("mp3", ["-c:a", "libmp3lame"]),
            ("flac", ["-c:a", "flac"]),
            ("m4a", ["-c:a", "aac"]),
        ];
        for (ext, codec) in formats {
            let path = dir.join(format!("fixture.{}", ext));
            let status = std::process::Command::new(&ffmpeg)
                .args(["-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.5"])
                .args(codec)
                .arg("-metadata")
                .arg("title=初始标题")
                .arg("-metadata")
                .arg("description=keep-me")
                .arg("-metadata")
                .arg("ALGERUNKNOWN=unknown-value")
                .arg(&path)
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status();
            let ok = matches!(status, Ok(s) if s.success());
            assert!(ok, "ffmpeg 生成 {} 夹具失败", ext);

            // ffmpeg 不会把任意自定义键写成 MP4 freeform，用 lofty 补 seed
            if ext == "m4a" {
                let mut tagged = Probe::open(&path).unwrap().read().unwrap();
                if ext == "m4a" {
                    use lofty::mp4::{Atom, AtomData, AtomIdent, Ilst};
                    let ilst: Ilst = tagged
                        .primary_tag()
                        .cloned()
                        .map(Ilst::from)
                        .unwrap_or_default();
                    let mut ilst = ilst;
                    ilst.insert(Atom::new(
                        AtomIdent::Freeform {
                            mean: std::borrow::Cow::Borrowed("com.apple.iTunes"),
                            name: std::borrow::Cow::Borrowed("ALGERUNKNOWN"),
                        }
                        .into_owned(),
                        AtomData::UTF8("unknown-value".into()),
                    ));
                    tagged.remove(lofty::tag::TagType::Mp4Ilst);
                    tagged.insert_tag(ilst.into());
                } else {
                    use lofty::id3::v2::Id3v2Tag;
                    let id3 = tagged
                        .primary_tag()
                        .cloned()
                        .map(Id3v2Tag::from)
                        .unwrap_or_default();
                    let mut id3 = id3;
                    id3.insert_user_text("ALGERUNKNOWN".to_string(), "unknown-value".to_string());
                    id3.insert_user_text("description".to_string(), "keep-me".to_string());
                    tagged.remove(lofty::tag::TagType::Id3v2);
                    tagged.insert_tag(id3.into());
                }
                tagged
                    .save_to_path(&path, lofty::config::WriteOptions::default())
                    .unwrap();
            }

            // 写前实测标签值（夹具 seed 的实际形态为准：ffmpeg 常把
            // COMMENT 写成 TXXX:comment 而非 COMM，不假设标准键存在）
            let (file, _) = read_file(&path).unwrap();
            let before_custom = custom_field(&file, &path, "ALGERUNKNOWN");
            let before_comment = custom_field(&file, &path, "description");
            assert_eq!(
                before_custom, "unknown-value",
                "{} 夹具自定义字段应已写入",
                ext
            );
            assert!(
                !before_comment.is_empty(),
                "{} 夹具 comment 字段应已写入（实测形态：{:?}）",
                ext,
                before_comment
            );

            // 来源 ID 写读一致
            write_source_id(&path, 186016).expect("写来源 ID");
            let meta = read_meta(&path).expect("读元信息");
            assert_eq!(meta.netease_id, 186016, "{} 来源 ID 读回不符", ext);
            assert_eq!(meta.title, "初始标题", "{} 标题读取", ext);

            // 改标题后来源 ID 与未知字段仍在
            let meta = write_tags(
                &path,
                &TagPatch {
                    title: Some("改后标题".into()),
                    ..Default::default()
                },
            )
            .expect("改标题");
            assert_eq!(meta.title, "改后标题", "{} 标题写读", ext);
            assert_eq!(meta.netease_id, 186016, "{} 改标题后来源 ID 必须保留", ext);

            // 未知字段写前/后一致（容器专用 API 读取）
            let (file, _) = read_file(&path).unwrap();
            assert_eq!(
                custom_field(&file, &path, "ALGERUNKNOWN"),
                before_custom,
                "{} 自定义未知字段必须保留",
                ext
            );
            assert_eq!(
                custom_field(&file, &path, "description"),
                before_comment,
                "{} description 字段必须保留",
                ext
            );

            // 音频仍在：时长 > 0
            assert!(meta.duration_ms > 0, "{} 音频时长不应为 0", ext);
        }

        std::fs::remove_dir_all(&dir).ok();
    }

    /// 冲突签名必须包含 mtime **秒**：跨秒同纳秒（touch -t 秒精度，nsec=0）
    /// 的修改在「只看 nsec」的旧实现下会被漏检（抽查确认问题）。
    #[cfg(unix)]
    #[test]
    fn conflict_signature_includes_mtime_seconds() {
        let dir = fixture_dir(format!("tags-mtime-{}", std::process::id()).as_str());
        let path = dir.join("mtime.mp3");
        make_mp3(&path);
        let touch = |t: &str| {
            let ok = std::process::Command::new("touch")
                .arg("-t")
                .arg(t)
                .arg(&path)
                .status()
                .map(|s| s.success())
                .unwrap_or(false);
            assert!(ok, "touch -t {} 失败", t);
        };
        touch("202001010000.00");
        let m1 = std::fs::metadata(&path).unwrap();
        touch("202101010000.00");
        let m2 = std::fs::metadata(&path).unwrap();
        // 秒精度 touch：纳秒均为 0 → 这是「同纳秒、不同秒」的用例
        {
            use std::os::unix::fs::MetadataExt;
            assert_eq!(m1.mtime_nsec(), 0);
            assert_eq!(m2.mtime_nsec(), 0);
            assert_ne!(m1.mtime(), m2.mtime());
        }
        let sig1 = conflict_signature(&m1);
        let sig2 = conflict_signature(&m2);
        assert_ne!(sig1, sig2, "mtime 秒必须纳入冲突签名");
        // 同一文件未修改：签名稳定
        assert_eq!(conflict_signature(&m1), sig1);
        std::fs::remove_dir_all(&dir).ok();
    }

    /// 写入标签必须保留既有内嵌封面与未知二进制帧（TXXX），音频内容不变。
    #[test]
    fn artwork_and_unknown_frames_survive_title_rewrite() {
        let dir = fixture_dir(format!("tags-art-{}", std::process::id()).as_str());
        let path = dir.join("art.mp3");
        make_mp3(&path);
        // seed：封面 + 未知 TXXX 帧（纯 lofty，不经 ffmpeg）
        {
            use lofty::id3::v2::Id3v2Tag;
            use lofty::picture::{MimeType, Picture, PictureType};
            let mut tagged = Probe::open(&path).unwrap().read().unwrap();
            let mut id3: Id3v2Tag = tagged
                .primary_tag()
                .cloned()
                .map(Id3v2Tag::from)
                .unwrap_or_default();
            let png_bytes = vec![0x89, b'P', b'N', b'G', 0, 0, 0, 0, 1, 2, 3, 4];
            id3.insert_picture(Picture::new_unchecked(
                PictureType::CoverFront,
                Some(MimeType::Png),
                None,
                png_bytes,
            ));
            id3.insert_user_text("ALGERUNKNOWN".to_string(), "mystery-value".to_string());
            tagged.remove(TagType::Id3v2);
            tagged.insert_tag(id3.into());
            tagged
                .save_to_path(&path, lofty::config::WriteOptions::default())
                .unwrap();
        }
        let before = read_meta(&path).unwrap();
        assert!(before.has_artwork, "夹具应含内嵌封面");

        let after = write_tags(
            &path,
            &TagPatch {
                title: Some("新标题".into()),
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(after.title, "新标题");
        assert!(after.has_artwork, "改标题后封面必须保留");
        // 未知 TXXX 帧保留（容器专用读取）
        {
            use lofty::file::AudioFile;
            let mut f = std::fs::File::open(&path).unwrap();
            let ff =
                lofty::mpeg::MpegFile::read_from(&mut f, lofty::config::ParseOptions::default())
                    .unwrap();
            let id3 = ff.id3v2().expect("ID3v2 必须在");
            assert_eq!(
                id3.get_user_text("ALGERUNKNOWN"),
                Some("mystery-value"),
                "未知二进制帧（TXXX）必须保留"
            );
        }
        // 音频未被破坏：仍是 ID3 头 + MPEG 帧
        let raw = std::fs::read(&path).unwrap();
        assert!(raw.starts_with(b"ID3"), "ID3 头必须保留");
        assert!(
            raw.windows(4).any(|w| w == [0xff, 0xfb, 0x90, 0x00]),
            "MPEG 音频帧必须保留"
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    /// AIFF / WAV 的来源 ID：**容器专用真实写回**（不再拒绝）。
    ///
    /// 读取走 ID3 chunk（`read_source_id_from`），写入必须对称：
    /// 用 `AiffFile` / `WavFile` 的容器专用 API 写 ID3 chunk，
    /// 同时 **保留原生标签区**（AIFF text chunks / WAV RIFF INFO），
    /// 不重编码音频、不动封面与未知帧。
    #[test]
    fn aiff_wav_source_id_is_written_through_container_specific_path() {
        let Some(ffmpeg) = ffmpeg_or_skip(&ffmpeg_candidates()) else {
            return;
        };
        let dir = fixture_dir(format!("tags-aiffwav-{}", std::process::id()).as_str());
        for (ext, codec) in [("aiff", "pcm_s16be"), ("wav", "pcm_s16le")] {
            let path = dir.join(format!("fixture.{}", ext));
            let status = std::process::Command::new(&ffmpeg)
                .args(["-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.5"])
                .args(["-c:a", codec])
                .arg("-metadata")
                .arg("title=初始标题")
                .arg(&path)
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status();
            assert!(
                matches!(status, Ok(s) if s.success()),
                "ffmpeg 生成 {} 夹具失败",
                ext
            );
            let before = read_meta(&path).unwrap();
            assert!(before.duration_ms > 0, "{} 夹具时长应为正", ext);

            // 来源 ID 真实写回（此前是明确拒绝）
            write_source_id(&path, 186016).expect("AIFF/WAV 的来源 ID 必须真实写回");
            let meta = read_meta(&path).unwrap();
            assert_eq!(meta.netease_id, 186016, "{} 来源 ID 读回不符", ext);
            assert_eq!(
                meta.duration_ms, before.duration_ms,
                "{} 音频时长不得改变",
                ext
            );

            // 改标题：来源 ID 必须仍在（同一标签区）
            let meta = write_tags(
                &path,
                &TagPatch {
                    title: Some("改后标题".into()),
                    ..Default::default()
                },
            )
            .expect("AIFF/WAV 的标题写回必须可用");
            assert_eq!(meta.title, "改后标题", "{} 标题写读", ext);
            assert_eq!(meta.netease_id, 186016, "{} 改标题后来源 ID 必须保留", ext);
            assert!(meta.duration_ms > 0, "{} 音频时长不应为 0", ext);

            // 原生标签区保留（双标签：原生 Text / RIFF + ID3）
            let native = native_tag_snapshot(&path, ext);
            assert!(
                native,
                "{} 的原生标签区（text chunks / RIFF INFO）必须保留",
                ext
            );
        }
        std::fs::remove_dir_all(&dir).ok();
    }

    /// 读取 AIFF / WAV 的原生标签区（AIFF text chunks / WAV RIFF INFO），
    /// 返回是否仍然存在（用于双标签保留断言）。
    fn native_tag_snapshot(path: &Path, ext: &str) -> bool {
        use lofty::file::AudioFile;
        let opts = lofty::config::ParseOptions::default();
        let mut handle = std::fs::File::open(path).unwrap();
        match ext {
            "aiff" => lofty::iff::aiff::AiffFile::read_from(&mut handle, opts)
                .map(|f| f.text_chunks().is_some())
                .unwrap_or(false),
            _ => lofty::iff::wav::WavFile::read_from(&mut handle, opts)
                .map(|f| f.riff_info().is_some())
                .unwrap_or(false),
        }
    }

    /// ID3v2 快照：用于逐字节校验「未知二进制帧 / 封面字节」是否保留。
    /// ffmpeg 候选路径（按顺序取第一个存在的）。
    fn ffmpeg_candidates() -> Vec<PathBuf> {
        [
            "ffmpeg",
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
        ]
        .iter()
        .map(PathBuf::from)
        .collect()
    }

    /// ffmpeg 缺失语义（审查 E1-7）：
    /// - 找不到 → **明确跳过**（返回 None；用例必须自行 return，不得算通过）；
    /// - `REQUIRE_FFMPEG=1` 且找不到 → **直接失败**（不接受静默跳过）。
    fn ffmpeg_or_skip(candidates: &[PathBuf]) -> Option<PathBuf> {
        if let Some(found) = candidates.iter().find(|p| p.exists()) {
            return Some(found.clone());
        }
        if std::env::var_os("REQUIRE_FFMPEG").is_some() {
            panic!("REQUIRE_FFMPEG=1：本机没有 ffmpeg，多格式测试必须真实执行（不允许跳过）");
        }
        eprintln!(
            "SKIP: 本机没有 ffmpeg —— 多格式测试 **未执行**（不计为通过；\
             装好 ffmpeg，或用 REQUIRE_FFMPEG=1 让它硬失败）"
        );
        None
    }

    /// ffmpeg 缺失必须是 **显式 skip / 硬失败**，不得静默当成通过。
    #[test]
    fn missing_ffmpeg_is_explicit_skip_or_hard_failure() {
        // 先在「未设置 REQUIRE_FFMPEG」下验证明确跳过分支
        let prev = std::env::var_os("REQUIRE_FFMPEG");
        std::env::remove_var("REQUIRE_FFMPEG");
        assert!(
            ffmpeg_or_skip(&[]).is_none(),
            "没有 ffmpeg 时必须返回 None（调用方据此跳过）"
        );

        // REQUIRE_FFMPEG=1 → 必须硬失败
        let prev_hook = std::panic::take_hook();
        std::panic::set_hook(Box::new(|_| {}));
        std::env::set_var("REQUIRE_FFMPEG", "1");
        let result = std::panic::catch_unwind(|| ffmpeg_or_skip(&[]));
        std::env::remove_var("REQUIRE_FFMPEG");
        std::panic::set_hook(prev_hook);
        if let Some(v) = prev {
            std::env::set_var("REQUIRE_FFMPEG", v);
        }
        assert!(
            result.is_err(),
            "REQUIRE_FFMPEG=1 且无 ffmpeg 时必须失败（不得静默跳过）"
        );
    }

    struct Id3Snapshot {
        txxx: Option<String>,
        priv_frames: usize,
        priv_bytes: Vec<u8>,
        apic: usize,
        apic_bytes: Vec<u8>,
    }

    fn id3_snapshot(path: &Path) -> Id3Snapshot {
        use lofty::file::AudioFile;
        use lofty::id3::v2::FrameId;
        use std::borrow::Cow;
        let mut f = std::fs::File::open(path).unwrap();
        let ff = lofty::mpeg::MpegFile::read_from(&mut f, lofty::config::ParseOptions::default())
            .unwrap();
        let id3 = ff.id3v2().cloned().unwrap_or_default();
        let mut priv_frames = 0;
        let mut priv_bytes = Vec::new();
        if let Some(lofty::id3::v2::Frame::Private(p)) =
            id3.get(&FrameId::Valid(Cow::Borrowed("PRIV")))
        {
            priv_frames = 1;
            priv_bytes = p.private_data.clone();
        }
        let mut apic = 0;
        let mut apic_bytes = Vec::new();
        if let Some(lofty::id3::v2::Frame::Picture(p)) =
            id3.get(&FrameId::Valid(Cow::Borrowed("APIC")))
        {
            apic = 1;
            apic_bytes = p.picture.data().to_vec();
        }
        Id3Snapshot {
            txxx: id3.get_user_text("ALGERUNKNOWN").map(str::to_string),
            priv_frames,
            priv_bytes,
            apic,
            apic_bytes,
        }
    }

    /// E1-7：改标题后必须保留 **未知二进制帧**（PRIV）与 **封面字节**
    /// （逐字节比对，不能只断言「有封面」）。
    #[test]
    fn unknown_binary_frame_and_artwork_bytes_survive_title_rewrite() {
        let dir = fixture_dir(format!("tags-binary-{}", std::process::id()).as_str());
        let path = dir.join("binary.mp3");
        make_mp3(&path);
        let artwork: Vec<u8> = vec![
            0x89, b'P', b'N', b'G', 0xDE, 0xAD, 0xBE, 0xEF, 1, 2, 3, 4, 5, 6, 7, 8,
        ];
        {
            use lofty::file::TaggedFileExt;
            use lofty::id3::v2::{Frame, Id3v2Tag, PrivateFrame};
            use lofty::picture::{MimeType, Picture, PictureType};
            let mut tagged = Probe::open(&path).unwrap().read().unwrap();
            let mut id3: Id3v2Tag = tagged
                .primary_tag()
                .cloned()
                .map(Id3v2Tag::from)
                .unwrap_or_default();
            id3.insert_picture(Picture::new_unchecked(
                PictureType::CoverFront,
                Some(MimeType::Png),
                None,
                artwork.clone(),
            ));
            id3.insert_user_text("ALGERUNKNOWN".to_string(), "mystery-value".to_string());
            // 真正的未知二进制帧（PRIV）：通用 Tag 往返最容易把它丢掉
            id3.insert(Frame::Private(PrivateFrame::new(
                "owner@example".to_string(),
                vec![0xAAu8; 32],
            )));
            tagged.remove(TagType::Id3v2);
            tagged.insert_tag(id3.into());
            tagged
                .save_to_path(&path, lofty::config::WriteOptions::default())
                .unwrap();
        }
        let before = id3_snapshot(&path);
        assert_eq!(before.priv_frames, 1, "夹具必须含 PRIV 帧");
        assert_eq!(before.apic, 1, "夹具必须含封面");

        write_tags(
            &path,
            &TagPatch {
                title: Some("新标题".into()),
                ..Default::default()
            },
        )
        .unwrap();

        let after = id3_snapshot(&path);
        assert_eq!(
            after.txxx.as_deref(),
            Some("mystery-value"),
            "未知用户文本帧必须保留"
        );
        assert_eq!(after.priv_frames, 1, "未知二进制帧（PRIV）必须保留");
        assert_eq!(
            after.priv_bytes,
            vec![0xAAu8; 32],
            "PRIV 字节必须逐字节保留"
        );
        assert_eq!(after.apic, 1, "封面必须保留");
        assert_eq!(after.apic_bytes, artwork, "封面字节必须逐字节保留");
        std::fs::remove_dir_all(&dir).ok();
    }

    /// E1-8：真实安全写路径的冲突检测——写入期间原文件被 **跨秒** 修改时，
    /// 写入必须被取消且原文件保持不变（不能只测辅助签名函数）。
    #[cfg(unix)]
    #[test]
    fn safe_write_aborts_when_file_changes_during_write() {
        let dir = fixture_dir(format!("tags-conflict-{}", std::process::id()).as_str());
        let path = dir.join("conflict.mp3");
        make_mp3(&path);
        let before = std::fs::read(&path).unwrap();

        // 写入过程中把原文件改成 **同长度但不同内容**，并把 mtime 设到另一秒
        let err = with_safe_write(&path, |_tmp| {
            let mut same_len = before.clone();
            same_len[0] = b'X'; // 同长度、内容不同
            std::fs::write(&path, &same_len).unwrap();
            let f = std::fs::File::options().write(true).open(&path).unwrap();
            f.set_times(std::fs::FileTimes::new().set_modified(
                std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_600_000_000),
            ))
            .unwrap();
            Ok(())
        })
        .expect_err("原文件在写入期间被修改必须取消写入");

        assert!(
            err.to_string().contains("被其他应用修改"),
            "错误需说明冲突：{}",
            err
        );
        let after = std::fs::read(&path).unwrap();
        assert_eq!(after.len(), before.len(), "原文件长度不得变化");
        assert_eq!(after[0], b'X', "原文件不得被本次写入覆盖");
        let leftovers = std::fs::read_dir(&dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .any(|e| e.file_name().to_string_lossy().starts_with(".alger-tags-"));
        assert!(!leftovers, "取消后不得残留临时文件");
        std::fs::remove_dir_all(&dir).ok();
    }

    /// 容器专用读取自定义字段：ID3v2 → TXXX 用户文本；其余 → 通用键。
    fn custom_field(file: &lofty::file::TaggedFile, path: &Path, key: &str) -> String {
        use lofty::file::AudioFile;
        let opts = lofty::config::ParseOptions::default();
        let id3 = match file.file_type() {
            lofty::file::FileType::Mpeg => std::fs::File::open(path)
                .ok()
                .and_then(|mut f| lofty::mpeg::MpegFile::read_from(&mut f, opts).ok())
                .and_then(|ff| ff.id3v2().cloned()),
            lofty::file::FileType::Aiff => std::fs::File::open(path)
                .ok()
                .and_then(|mut f| lofty::iff::aiff::AiffFile::read_from(&mut f, opts).ok())
                .and_then(|ff| ff.id3v2().cloned()),
            lofty::file::FileType::Wav => std::fs::File::open(path)
                .ok()
                .and_then(|mut f| lofty::iff::wav::WavFile::read_from(&mut f, opts).ok())
                .and_then(|ff| ff.id3v2().cloned()),
            _ => None,
        };
        if let Some(id3) = id3 {
            // ID3v2：TXXX 用户文本（含 ffmpeg 写的 TXXX:comment）
            if let Some(v) = id3.get_user_text(key) {
                return v.to_string();
            }
            // COMM 帧兜底
            return id3
                .get_text(&lofty::id3::v2::FrameId::Valid(std::borrow::Cow::Borrowed(
                    "COMM",
                )))
                .unwrap_or_default()
                .to_string();
        }
        // Vorbis / MP4：通用键（ffmpeg 的 MP4 freeform 是
        // `----:com.apple.iTunes:KEY` 且常大写；comment/description 在标准映射里）
        let tag = primary_or_new(file);
        let upper = key.to_uppercase();
        for candidate in [
            key.to_string(),
            upper.clone(),
            format!("----:com.apple.iTunes:{}", upper),
            format!("----:com.apple.iTunes:{}", key),
        ] {
            if let Some(v) = tag.get_string(&ItemKey::Unknown(candidate)) {
                return v.to_string();
            }
        }
        if key.eq_ignore_ascii_case("comment") || key.eq_ignore_ascii_case("description") {
            if let Some(v) = tag.get_string(&ItemKey::Comment) {
                return v.to_string();
            }
            if let Some(v) = tag.get_string(&ItemKey::Description) {
                return v.to_string();
            }
        }
        String::new()
    }
}
