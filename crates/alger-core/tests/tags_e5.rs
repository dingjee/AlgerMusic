//! E5 元信息扩展测试（tags 专用）。
//!
//! 覆盖：
//! - AIFF / WAV 的容器专用来源 ID **真实写回**（不再拒绝），双标签保留；
//! - TagPatch / TrackMeta 扩展字段：`neteaseId` / `isrc` /
//!   `musicBrainzRecordingId` / `musicBrainzReleaseId` / `date`（完整年月日）；
//! - MP3 / FLAC / M4A / Ogg / AIFF / WAV **真实多格式往返**（ffmpeg 夹具）；
//! - 未知帧 / 封面 / 音频摘要保留；失败时原文件字节不变；
//! - 封面 4 MiB 上限（保护桥接单行协议）。
//!
//! 环境无 ffmpeg 时 **明确跳过**（不计为通过）；`REQUIRE_FFMPEG=1` 时直接失败。

use std::path::{Path, PathBuf};

use alger_core::tags::{self, TagError, TagPatch};
use lofty::config::{ParseOptions, WriteOptions};
use lofty::file::{AudioFile, TaggedFileExt};
use lofty::tag::{ItemKey, ItemValue, Tag, TagItem, TagType};

// ---------------------------------------------------------------- 夹具工具

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

/// ffmpeg 缺失语义：找不到 → 明确跳过；`REQUIRE_FFMPEG=1` → 直接失败。
fn ffmpeg_or_skip(candidates: &[PathBuf]) -> Option<PathBuf> {
    if let Some(found) = candidates.iter().find(|p| p.exists() && p.is_file()) {
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

fn fixture_dir(name: &str) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../.artifacts/fixtures")
        .join(name);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// 受支持的真实容器（扩展名, ffmpeg 编码参数）。
const FORMATS: [(&str, &[&str]); 6] = [
    ("mp3", &["-c:a", "libmp3lame"]),
    ("flac", &["-c:a", "flac"]),
    ("m4a", &["-c:a", "aac"]),
    ("ogg", &["-ac", "2", "-c:a", "vorbis", "-strict", "-2"]),
    ("aiff", &["-c:a", "pcm_s16be"]),
    ("wav", &["-c:a", "pcm_s16le"]),
];

fn make_fixture(dir: &Path, ext: &str, codec: &[&str]) -> PathBuf {
    let ffmpeg = ffmpeg_or_skip(&ffmpeg_candidates()).expect("ffmpeg 必须存在");
    let path = dir.join(format!("fixture.{}", ext));
    let mut cmd = std::process::Command::new(&ffmpeg);
    cmd.args(["-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.5"])
        .args(codec)
        .arg("-metadata")
        .arg("title=初始标题")
        .arg("-metadata")
        .arg("artist=初始艺人")
        .arg(&path)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    let status = cmd.status().expect("ffmpeg 启动失败");
    assert!(status.success(), "ffmpeg 生成 {} 夹具失败", ext);
    assert!(std::fs::metadata(&path).unwrap().len() > 0);
    path
}

// ------------------------------------------------------- 未知字段 / 封面 seed

const UNKNOWN_KEY: &str = "ALGERUNKNOWN";
const UNKNOWN_VALUE: &str = "unknown-value";
/// 封面字节（可辨认的伪 PNG 头）。
const ARTWORK: &[u8] = &[
    0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0xDE, 0xAD, 0xBE, 0xEF, 1, 2, 3, 4, 5, 6, 7, 8,
];

fn artwork_picture() -> lofty::picture::Picture {
    lofty::picture::Picture::new_unchecked(
        lofty::picture::PictureType::CoverFront,
        Some(lofty::picture::MimeType::Png),
        None,
        ARTWORK.to_vec(),
    )
}

/// 在夹具里塞入「未知字段 + 内嵌封面」，返回未知字段的写入方式标记。
fn seed_unknown_and_artwork(path: &Path, ext: &str) {
    use lofty::id3::v2::Id3v2Tag;
    use lofty::iff::aiff::AiffFile;
    use lofty::iff::wav::WavFile;
    use lofty::mpeg::MpegFile;

    match ext {
        "mp3" => {
            let mut handle = std::fs::File::open(path).unwrap();
            let mut file = MpegFile::read_from(&mut handle, ParseOptions::default()).unwrap();
            if file.id3v2().is_none() {
                file.set_id3v2(Id3v2Tag::new());
            }
            let id3 = file.id3v2_mut().unwrap();
            id3.insert_user_text(UNKNOWN_KEY.to_string(), UNKNOWN_VALUE.to_string());
            id3.insert_picture(artwork_picture());
            file.save_to_path(path, WriteOptions::default()).unwrap();
        }
        "aiff" | "wav" => {
            let mut handle = std::fs::File::open(path).unwrap();
            if ext == "aiff" {
                let mut file = AiffFile::read_from(&mut handle, ParseOptions::default()).unwrap();
                if file.id3v2().is_none() {
                    file.set_id3v2(Id3v2Tag::new());
                }
                let id3 = file.id3v2_mut().unwrap();
                id3.insert_user_text(UNKNOWN_KEY.to_string(), UNKNOWN_VALUE.to_string());
                id3.insert_picture(artwork_picture());
                file.save_to_path(path, WriteOptions::default()).unwrap();
            } else {
                let mut file = WavFile::read_from(&mut handle, ParseOptions::default()).unwrap();
                if file.id3v2().is_none() {
                    file.set_id3v2(Id3v2Tag::new());
                }
                let id3 = file.id3v2_mut().unwrap();
                id3.insert_user_text(UNKNOWN_KEY.to_string(), UNKNOWN_VALUE.to_string());
                id3.insert_picture(artwork_picture());
                file.save_to_path(path, WriteOptions::default()).unwrap();
            }
        }
        // FLAC / M4A / Ogg：通用标签路径（lofty 的 Vorbis / ilst 都支持
        // 未知键与封面）。
        _ => {
            let mut tagged = lofty::probe::Probe::open(path).unwrap().read().unwrap();
            let tag_type = tagged
                .primary_tag()
                .map(|t| t.tag_type())
                .unwrap_or(TagType::VorbisComments);
            let mut tag: Tag = tagged
                .primary_tag()
                .cloned()
                .unwrap_or_else(|| Tag::new(tag_type));
            let unknown_key = if tag_type == TagType::Mp4Ilst {
                format!("----:com.apple.iTunes:{}", UNKNOWN_KEY)
            } else {
                UNKNOWN_KEY.to_string()
            };
            tag.insert_unchecked(TagItem::new(
                ItemKey::Unknown(unknown_key),
                ItemValue::Text(UNKNOWN_VALUE.to_string()),
            ));
            tag.set_picture(0, artwork_picture());
            tagged.remove(tag_type);
            tagged.insert_tag(tag);
            tagged.save_to_path(path, WriteOptions::default()).unwrap();
        }
    }
}

/// 读回未知字段（容器专用路径），缺失返回空串。
fn read_unknown_field(path: &Path, ext: &str) -> String {
    use lofty::id3::v2::Id3v2Tag;
    use lofty::iff::aiff::AiffFile;
    use lofty::iff::wav::WavFile;
    use lofty::mpeg::MpegFile;

    match ext {
        "mp3" => {
            let mut handle = std::fs::File::open(path).unwrap();
            MpegFile::read_from(&mut handle, ParseOptions::default())
                .ok()
                .and_then(|f| f.id3v2().cloned())
                .and_then(|id3: Id3v2Tag| id3.get_user_text(UNKNOWN_KEY).map(str::to_string))
                .unwrap_or_default()
        }
        "aiff" => {
            let mut handle = std::fs::File::open(path).unwrap();
            AiffFile::read_from(&mut handle, ParseOptions::default())
                .ok()
                .and_then(|f| f.id3v2().cloned())
                .and_then(|id3: Id3v2Tag| id3.get_user_text(UNKNOWN_KEY).map(str::to_string))
                .unwrap_or_default()
        }
        "wav" => {
            let mut handle = std::fs::File::open(path).unwrap();
            WavFile::read_from(&mut handle, ParseOptions::default())
                .ok()
                .and_then(|f| f.id3v2().cloned())
                .and_then(|id3: Id3v2Tag| id3.get_user_text(UNKNOWN_KEY).map(str::to_string))
                .unwrap_or_default()
        }
        _ => {
            let tagged = match lofty::probe::Probe::open(path).unwrap().read() {
                Ok(t) => t,
                Err(_) => return String::new(),
            };
            let tag = match tagged.primary_tag() {
                Some(t) => t,
                None => return String::new(),
            };
            let candidates = [
                UNKNOWN_KEY.to_string(),
                format!("----:com.apple.iTunes:{}", UNKNOWN_KEY),
            ];
            for key in candidates {
                if let Some(v) = tag.get_string(&ItemKey::Unknown(key)) {
                    return v.to_string();
                }
            }
            String::new()
        }
    }
}

// ------------------------------------------------------------------ 用例

/// 六种真实容器：来源 ID + 完整日期 + ISRC + MusicBrainz 录音/发行 ID
/// 一次写完、读回一致；`None` 字段不被改动。
#[test]
fn e5_multi_format_roundtrip_with_standard_identifiers() {
    if ffmpeg_or_skip(&ffmpeg_candidates()).is_none() {
        return;
    }
    let dir = fixture_dir("tags-e5-roundtrip");

    for (ext, codec) in FORMATS {
        let path = make_fixture(&dir, ext, codec);
        let before = tags::read_meta(&path).expect("读初始元信息");

        // 一次事务写入：标签 + 来源 ID + 标准标识字段
        let patch = TagPatch {
            title: Some("新标题".into()),
            artist: Some("新艺人".into()),
            album: Some("新专辑".into()),
            date: Some("2003-07-31".into()),
            isrc: Some("USRC17607839".into()),
            music_brainz_recording_id: Some("b9d4b1a4-1111-2222-3333-444455556666".into()),
            music_brainz_release_id: Some("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee".into()),
            netease_id: Some(186016),
            ..Default::default()
        };
        let meta = tags::write_tags(&path, &patch).expect("写标签");

        assert_eq!(meta.title, "新标题", "{} 标题写读", ext);
        assert_eq!(meta.artist, "新艺人", "{} 艺人写读", ext);
        assert_eq!(meta.album, "新专辑", "{} 专辑写读", ext);
        assert_eq!(meta.netease_id, 186016, "{} 来源 ID 写读", ext);
        assert_eq!(meta.isrc, "USRC17607839", "{} ISRC 写读", ext);
        assert_eq!(
            meta.music_brainz_recording_id, "b9d4b1a4-1111-2222-3333-444455556666",
            "{} MusicBrainz 录音 ID 写读",
            ext
        );
        assert_eq!(
            meta.music_brainz_release_id, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            "{} MusicBrainz 发行 ID 写读",
            ext
        );
        assert!(
            meta.date.starts_with("2003-07-31"),
            "{} 日期必须保留完整年月日，实际「{}」",
            ext,
            meta.date
        );
        assert_eq!(meta.year, 2003, "{} 年份应从日期推导", ext);

        // 音频摘要不变（不重编码）
        assert_eq!(
            meta.duration_ms, before.duration_ms,
            "{} 音频时长不得改变",
            ext
        );
        assert_eq!(
            meta.sample_rate, before.sample_rate,
            "{} 采样率不得改变",
            ext
        );

        // 二次写入只改标题：其余字段必须原样保留（None = 不修改）
        let meta2 = tags::write_tags(
            &path,
            &TagPatch {
                title: Some("只改标题".into()),
                ..Default::default()
            },
        )
        .expect("二次写入");
        assert_eq!(meta2.title, "只改标题", "{} 二次标题写读", ext);
        assert_eq!(meta2.netease_id, 186016, "{} 二次写入来源 ID 必须保留", ext);
        assert_eq!(meta2.isrc, "USRC17607839", "{} 二次写入 ISRC 必须保留", ext);
        assert_eq!(
            meta2.music_brainz_recording_id, "b9d4b1a4-1111-2222-3333-444455556666",
            "{} 二次写入 MB 录音 ID 必须保留",
            ext
        );
        assert_eq!(
            meta2.music_brainz_release_id, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
            "{} 二次写入 MB 发行 ID 必须保留",
            ext
        );
        assert!(
            meta2.date.starts_with("2003-07-31"),
            "{} 二次写入日期必须保留",
            ext
        );

        // 清除语义：空串 = 清除该字段
        let meta3 = tags::write_tags(
            &path,
            &TagPatch {
                isrc: Some(String::new()),
                ..Default::default()
            },
        )
        .expect("清除 ISRC");
        assert!(meta3.isrc.is_empty(), "{} ISRC 应被清除", ext);

        std::fs::remove_file(&path).ok();
    }
    std::fs::remove_dir_all(&dir).ok();
}

/// 未知字段 / 内嵌封面 / 音频摘要必须保留（写标签不能顺手删掉别的标签区）。
#[test]
fn e5_unknown_field_artwork_and_audio_preserved() {
    if ffmpeg_or_skip(&ffmpeg_candidates()).is_none() {
        return;
    }
    let dir = fixture_dir("tags-e5-preserve");

    for (ext, codec) in FORMATS {
        let path = make_fixture(&dir, ext, codec);
        seed_unknown_and_artwork(&path, ext);

        let before = tags::read_meta(&path).expect("读初始元信息");
        assert!(before.has_artwork, "{} 夹具应含内嵌封面", ext);
        assert_eq!(
            read_unknown_field(&path, ext),
            UNKNOWN_VALUE,
            "{} 夹具应含未知字段",
            ext
        );
        // 音频 packet payload 的真实摘要（写前）
        let (hash_method, hash_before) = audio_payload_sha256(&path);
        eprintln!(
            "[{}] 音频哈希方法={} 写前={}",
            ext, hash_method, hash_before
        );

        let meta = tags::write_tags(
            &path,
            &TagPatch {
                title: Some("换标题".into()),
                netease_id: Some(186016),
                ..Default::default()
            },
        )
        .expect("写标签");
        assert_eq!(meta.title, "换标题", "{} 标题写读", ext);

        // 未知字段保留
        assert_eq!(
            read_unknown_field(&path, ext),
            UNKNOWN_VALUE,
            "{} 未知字段必须保留",
            ext
        );
        // 封面保留（字节一致）
        assert!(meta.has_artwork, "{} 封面必须保留", ext);
        let cover = tags::artwork_base64(&path).expect("读封面");
        use base64::Engine as _;
        let decoded = base64::engine::general_purpose::STANDARD
            .decode(cover.trim())
            .expect("base64 解码");
        assert_eq!(decoded, ARTWORK, "{} 封面字节必须逐字节保留", ext);
        // 音频摘要保留（真实 packet payload SHA256 逐字节证据）
        let (hash_method_after, hash_after) = audio_payload_sha256(&path);
        assert_eq!(
            hash_method, hash_method_after,
            "{} 音频哈希方法必须前后一致",
            ext
        );
        assert_eq!(
            hash_before, hash_after,
            "{} 音频 packet payload SHA256 必须在写标签前后完全一致（音频被改动！）",
            ext
        );
        assert_eq!(
            meta.duration_ms, before.duration_ms,
            "{} 音频时长不得改变",
            ext
        );
        assert_eq!(
            meta.sample_rate, before.sample_rate,
            "{} 采样率不得改变",
            ext
        );

        std::fs::remove_file(&path).ok();
    }
    std::fs::remove_dir_all(&dir).ok();
}

/// 失败注入：写入失败必须 **原文件字节不变**（含 AIFF / WAV）。
#[test]
fn e5_failed_write_keeps_original_bytes() {
    if ffmpeg_or_skip(&ffmpeg_candidates()).is_none() {
        return;
    }
    let dir = fixture_dir("tags-e5-failure");
    use std::os::unix::fs::PermissionsExt;
    let set_dir_mode = |mode: u32| {
        let mut perm = std::fs::metadata(&dir).unwrap().permissions();
        perm.set_mode(mode);
        std::fs::set_permissions(&dir, perm).unwrap();
    };

    let mut results = Vec::new();
    for (ext, codec) in FORMATS {
        let path = dir.join(format!("fixture.{}", ext));
        // 只读目录下无法生成夹具，先在可写目录生成再搬过来
        set_dir_mode(0o700);
        make_fixture(&dir, ext, codec);
        let original = std::fs::read(&path).unwrap();
        set_dir_mode(0o500);

        let result = tags::write_tags(
            &path,
            &TagPatch {
                title: Some("不该写入".into()),
                netease_id: Some(186016),
                ..Default::default()
            },
        );
        results.push((ext, result.is_err()));

        set_dir_mode(0o700);
        assert_eq!(
            std::fs::read(&path).unwrap(),
            original,
            "{} 写入失败后原文件字节必须不变",
            ext
        );
    }
    for (ext, is_err) in results {
        assert!(is_err, "{} 只读目录下写入必须失败", ext);
    }
    std::fs::remove_dir_all(&dir).ok();
}

/// 封面上限：超过 4 MiB 的封面既不能写入，也不能通过协议返回。
#[test]
fn e5_oversized_artwork_is_rejected() {
    if ffmpeg_or_skip(&ffmpeg_candidates()).is_none() {
        return;
    }
    let dir = fixture_dir("tags-e5-artwork-limit");
    let path = make_fixture(&dir, "mp3", &["-c:a", "libmp3lame"]);
    let original = std::fs::read(&path).unwrap();

    // 写入超大封面：必须明确报错，原文件不变
    use base64::Engine as _;
    let huge = base64::engine::general_purpose::STANDARD.encode(vec![0x41u8; 5 * 1024 * 1024]);
    let err = tags::write_tags(
        &path,
        &TagPatch {
            artwork_base64: Some(huge),
            ..Default::default()
        },
    )
    .expect_err("超大封面必须被拒绝");
    assert!(
        matches!(err, TagError::Artwork(_)),
        "必须是 TagError::Artwork，实际：{}",
        err
    );
    assert_eq!(
        std::fs::read(&path).unwrap(),
        original,
        "超大封面写入失败后原文件必须字节不变"
    );

    // 读回：超大封面不得通过协议返回
    {
        use lofty::id3::v2::Id3v2Tag;
        use lofty::mpeg::MpegFile;
        let mut handle = std::fs::File::open(&path).unwrap();
        let mut file = MpegFile::read_from(&mut handle, ParseOptions::default()).unwrap();
        if file.id3v2().is_none() {
            file.set_id3v2(Id3v2Tag::new());
        }
        let id3 = file.id3v2_mut().unwrap();
        id3.insert_picture(lofty::picture::Picture::new_unchecked(
            lofty::picture::PictureType::CoverFront,
            Some(lofty::picture::MimeType::Png),
            None,
            vec![0x42u8; 5 * 1024 * 1024],
        ));
        file.save_to_path(&path, WriteOptions::default()).unwrap();
    }
    let err = tags::artwork_base64(&path).expect_err("超大封面不得通过协议返回");
    assert!(
        matches!(err, TagError::Artwork(_)),
        "必须是 TagError::Artwork，实际：{}",
        err
    );
    // 明确存在封面（hasArtwork 不能误报 false）
    assert!(
        tags::read_meta(&path).unwrap().has_artwork,
        "超大封面仍应报告有封面"
    );

    // 文字 patch 不涉及封面时：超大封面必须原样保留，不得被改写或删除
    let before_size = std::fs::metadata(&path).unwrap().len();
    tags::write_tags(
        &path,
        &TagPatch {
            title: Some("只改标题".into()),
            ..Default::default()
        },
    )
    .expect("只改标题必须成功");
    assert!(
        tags::read_meta(&path).unwrap().has_artwork,
        "只改标题不得删除封面"
    );
    let after_size = std::fs::metadata(&path).unwrap().len();
    assert!(
        after_size >= before_size - 4096,
        "只改标题不得缩小文件（封面被删）：{} → {}",
        before_size,
        after_size
    );

    std::fs::remove_dir_all(&dir).ok();
}

/// 封面选择语义：**Front 优先**（即使 Back 更大）；写封面只替换 Front，
/// 其它图片（Back / 未知类型）保留；`removeArtwork` 才清空全部。
///
/// Swift 侧按 `tags.artwork` 返回的字节校验写后封面，读写语义必须对称。
#[test]
fn e5_artwork_front_selection_and_replacement() {
    use base64::Engine as _;
    use lofty::picture::{MimeType, Picture, PictureType};

    if ffmpeg_or_skip(&ffmpeg_candidates()).is_none() {
        return;
    }
    let dir = fixture_dir("tags-e5-artwork-front");
    let path = make_fixture(&dir, "mp3", &["-c:a", "libmp3lame"]);

    let front_bytes = vec![0xF1u8; 1024];
    let back_bytes = vec![0xB2u8; 8192];
    {
        use lofty::id3::v2::Id3v2Tag;
        use lofty::mpeg::MpegFile;
        let mut handle = std::fs::File::open(&path).unwrap();
        let mut file = MpegFile::read_from(&mut handle, ParseOptions::default()).unwrap();
        if file.id3v2().is_none() {
            file.set_id3v2(Id3v2Tag::new());
        }
        let id3 = file.id3v2_mut().unwrap();
        id3.insert_picture(Picture::new_unchecked(
            PictureType::CoverFront,
            Some(MimeType::Png),
            None,
            front_bytes.clone(),
        ));
        id3.insert_picture(Picture::new_unchecked(
            PictureType::CoverBack,
            Some(MimeType::Png),
            None,
            back_bytes.clone(),
        ));
        file.save_to_path(&path, WriteOptions::default()).unwrap();
    }

    // 读取：必须选 Front（不是更大的 Back）
    let cover = tags::artwork_base64(&path).expect("读封面");
    let decoded = base64::engine::general_purpose::STANDARD
        .decode(cover.trim())
        .expect("base64 解码");
    assert_eq!(decoded, front_bytes, "必须选 Front 封面，而不是更大的 Back");

    // 写新封面：替换 Front，保留 Back
    let new_front = vec![0xA7u8; 2048];
    tags::write_tags(
        &path,
        &TagPatch {
            artwork_base64: Some(
                base64::engine::general_purpose::STANDARD.encode(new_front.clone()),
            ),
            ..Default::default()
        },
    )
    .expect("写新封面");
    let cover = tags::artwork_base64(&path).expect("读封面");
    let decoded = base64::engine::general_purpose::STANDARD
        .decode(cover.trim())
        .expect("base64 解码");
    assert_eq!(decoded, new_front, "写后必须读回新的 Front 封面");

    let pictures = read_pictures(&path);
    assert!(
        pictures
            .iter()
            .any(|(t, data)| *t == PictureType::CoverBack && data == &back_bytes),
        "Back 封面必须保留（写封面只替换 Front）"
    );

    // remove_artwork：全部删除
    tags::write_tags(
        &path,
        &TagPatch {
            remove_artwork: true,
            ..Default::default()
        },
    )
    .expect("移除封面");
    assert!(
        !tags::read_meta(&path).unwrap().has_artwork,
        "removeArtwork 后不得再有封面"
    );

    std::fs::remove_dir_all(&dir).ok();
}

/// 读取文件里的全部图片（类型 + 字节）。
fn read_pictures(path: &Path) -> Vec<(lofty::picture::PictureType, Vec<u8>)> {
    use lofty::id3::v2::Id3v2Tag;
    use lofty::mpeg::MpegFile;

    let mut handle = std::fs::File::open(path).unwrap();
    let file = MpegFile::read_from(&mut handle, ParseOptions::default()).unwrap();
    let id3: Id3v2Tag = file.id3v2().cloned().unwrap_or_default();
    let generic: Tag = Tag::from(id3);
    generic
        .pictures()
        .iter()
        .map(|p| (p.pic_type(), p.data().to_vec()))
        .collect()
}

/// 音频 **packet payload** 的 SHA256（ffmpeg 流拷贝哈希）。
///
/// 命令：`ffmpeg -v error -i <file> -map 0:a:0 -c:a copy -f hash -hash sha256 -`
/// —— `-c:a copy` 不解码、不重编码，哈希的是原始音频 packet payload，
/// 因此写标签前后哈希相同即证明音频流没被改动。
/// 若某容器不支持流拷贝，退回解码 PCM 后哈希（此时哈希的是 PCM 样本，
/// 方法标记为 `pcm`，**不是** packet payload，报告里必须如实注明）。
///
/// 返回 `(方法, 十六进制摘要)`。
fn audio_payload_sha256(path: &Path) -> (String, String) {
    let ffmpeg = ffmpeg_or_skip(&ffmpeg_candidates()).expect("ffmpeg 必须存在");
    if let Some(hash) = run_ffmpeg_hash(&ffmpeg, path, &["-c:a", "copy"]) {
        return ("copy".to_string(), hash);
    }
    let hash = run_ffmpeg_hash(&ffmpeg, path, &["-c:a", "pcm_s16le"]).unwrap_or_else(|| {
        panic!(
            "{}: ffmpeg 音频哈希失败（流拷贝与 PCM 兜底都不行），无法提供音频内容证据",
            path.display()
        )
    });
    ("pcm".to_string(), hash)
}

/// 跑一次 ffmpeg 哈希命令，检查 **真实退出码**；成功才返回摘要。
fn run_ffmpeg_hash(ffmpeg: &Path, path: &Path, codec_args: &[&str]) -> Option<String> {
    let output = std::process::Command::new(ffmpeg)
        .args(["-v", "error", "-i"])
        .arg(path)
        .args(["-map", "0:a:0"])
        .args(codec_args)
        .args(["-f", "hash", "-hash", "sha256", "-"])
        .output()
        .ok()?;
    if !output.status.success() {
        eprintln!(
            "ffmpeg 哈希失败（{:?}，exit={:?}）：{}",
            codec_args,
            output.status.code(),
            String::from_utf8_lossy(&output.stderr).trim()
        );
        return None;
    }
    let text = String::from_utf8_lossy(&output.stdout);
    let line = text.lines().find(|l| l.starts_with("SHA256="))?;
    let hash = line.trim_start_matches("SHA256=").trim().to_string();
    if hash.len() != 64 || !hash.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    Some(hash)
}

/// 数值字段 **显式 0 = 清除**（Swift 真实回归：
/// `MetadataRealBridgeTests.testRealNumericClearToZeroRoundTrip`
/// 写 track=0 后必须读回 0，而不是旧值 3）。
///
/// 先在 6 种真实容器里 seed `track=3 / disc=2 / year=2020`，
/// 再用显式 0 清除：读回必须是 0 / 空；
/// 其余字段（标题 / 来源 ID / 内嵌封面 / 未知字段 /
/// 音频 packet payload SHA256）必须原样保留。
#[test]
fn e5_numeric_clear_to_zero_roundtrip() {
    use base64::Engine as _;

    if ffmpeg_or_skip(&ffmpeg_candidates()).is_none() {
        return;
    }
    let dir = fixture_dir("tags-e5-numeric-clear");

    for (ext, codec) in FORMATS {
        let path = make_fixture(&dir, ext, codec);
        seed_unknown_and_artwork(&path, ext);

        // seed：曲序 3 / 碟序 2 / 年份 2020 + 标题 + 来源 ID
        let seeded = tags::write_tags(
            &path,
            &TagPatch {
                title: Some("保留标题".into()),
                track: Some(3),
                disc: Some(2),
                year: Some(2020),
                netease_id: Some(186016),
                ..Default::default()
            },
        )
        .expect("seed 写入");
        assert_eq!(seeded.track, 3, "{} seed 曲序", ext);
        assert_eq!(seeded.disc, 2, "{} seed 碟序", ext);
        assert_eq!(seeded.year, 2020, "{} seed 年份", ext);

        let (hash_method, hash_before) = audio_payload_sha256(&path);

        // 清除：显式 0
        let cleared = tags::write_tags(
            &path,
            &TagPatch {
                track: Some(0),
                disc: Some(0),
                year: Some(0),
                ..Default::default()
            },
        )
        .expect("清除写入");
        assert_eq!(cleared.track, 0, "{} 曲序必须被清除（读回 0）", ext);
        assert_eq!(cleared.disc, 0, "{} 碟序必须被清除（读回 0）", ext);
        assert_eq!(cleared.year, 0, "{} 年份必须被清除（读回 0）", ext);
        assert!(
            cleared.date.is_empty(),
            "{} 日期必须被清除，实际「{}」",
            ext,
            cleared.date
        );

        // 其它字段必须保留
        assert_eq!(cleared.title, "保留标题", "{} 标题必须保留", ext);
        assert_eq!(cleared.netease_id, 186016, "{} 来源 ID 必须保留", ext);
        assert!(cleared.has_artwork, "{} 封面必须保留", ext);
        assert_eq!(
            read_unknown_field(&path, ext),
            UNKNOWN_VALUE,
            "{} 未知字段必须保留",
            ext
        );
        let cover = tags::artwork_base64(&path).expect("读封面");
        let decoded = base64::engine::general_purpose::STANDARD
            .decode(cover.trim())
            .expect("base64 解码");
        assert_eq!(decoded, ARTWORK, "{} 封面字节必须逐字节保留", ext);

        // 音频 packet payload 不得改变
        let (hash_method_after, hash_after) = audio_payload_sha256(&path);
        assert_eq!(hash_method, hash_method_after, "{} 哈希方法必须一致", ext);
        assert_eq!(
            hash_before, hash_after,
            "{} 音频 packet payload SHA256 必须在清除前后一致",
            ext
        );

        std::fs::remove_file(&path).ok();
    }
    std::fs::remove_dir_all(&dir).ok();
}

/// AIFF / WAV 双标签：封面在 ID3 里时 `hasArtwork` / `artwork_base64`
/// 必须读得到，不能只看原生主标签。
#[test]
fn e5_aiff_wav_dual_tag_artwork_is_detected() {
    if ffmpeg_or_skip(&ffmpeg_candidates()).is_none() {
        return;
    }
    let dir = fixture_dir("tags-e5-dual-tag");
    for (ext, codec) in [
        ("aiff", &["-c:a", "pcm_s16be"][..]),
        ("wav", &["-c:a", "pcm_s16le"][..]),
    ] {
        let path = make_fixture(&dir, ext, codec);
        seed_unknown_and_artwork(&path, ext);

        let meta = tags::read_meta(&path).expect("读元信息");
        assert!(
            meta.has_artwork,
            "{} 的 ID3 封面必须被识别（双标签容器）",
            ext
        );
        let cover = tags::artwork_base64(&path).expect("读封面");
        use base64::Engine as _;
        let decoded = base64::engine::general_purpose::STANDARD
            .decode(cover.trim())
            .expect("base64 解码");
        assert_eq!(decoded, ARTWORK, "{} 封面字节必须一致", ext);

        // 原生标签区仍在（双标签保留）
        let native_exists = {
            use lofty::file::AudioFile;
            let mut handle = std::fs::File::open(&path).unwrap();
            if ext == "aiff" {
                lofty::iff::aiff::AiffFile::read_from(&mut handle, ParseOptions::default())
                    .map(|f| f.text_chunks().is_some())
                    .unwrap_or(false)
            } else {
                lofty::iff::wav::WavFile::read_from(&mut handle, ParseOptions::default())
                    .map(|f| f.riff_info().is_some())
                    .unwrap_or(false)
            }
        };
        assert!(native_exists, "{} 原生标签区必须保留", ext);

        std::fs::remove_file(&path).ok();
    }
    std::fs::remove_dir_all(&dir).ok();
}

// ---------------------------------------------- 码率单位 / 编码识别 / 内容探测

/// 指定码率生成夹具（其余同 `make_fixture`）。
fn make_fixture_br(dir: &Path, name: &str, codec: &[&str], br: &str) -> PathBuf {
    let ffmpeg = ffmpeg_or_skip(&ffmpeg_candidates()).expect("ffmpeg 必须存在");
    let path = dir.join(name);
    let status = std::process::Command::new(&ffmpeg)
        .args(["-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=2"])
        .args(codec)
        .args(["-b:a", br])
        .arg(&path)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .expect("ffmpeg 启动失败");
    assert!(status.success(), "生成 {} 失败", name);
    path
}

/// 真实夹具验证三类关键读取语义：
/// 1. **码率单位是 bps**：192k MP3 读出 ~194000（编码器实际输出），
///    而不是 194 —— 旧实现直接把 lofty 的 kbps 当 bps，会把本地
///    192kbps 误判成 192bps，从而认为远端「质量更高」触发无谓升级；
/// 2. **编码按内容识别，不看扩展名**：m4a 容器里 ALAC / AAC 必须区分
///    （ALAC 是无损，直接决定「远端更高」的方向性判断）；
/// 3. **错扩展名可读**：MP3 内容伪装 `.bin` 仍能按内容签名识别并读全
///    （扩展名不可信，读前 guess_file_type）。
#[test]
fn e5_real_bitrate_bps_codec_content_detection() {
    if ffmpeg_or_skip(&ffmpeg_candidates()).is_none() {
        return;
    }
    let dir = fixture_dir("tags-e5-quality");

    // 1) 真实 192kbps MP3 → bps 量级（ffmpeg libmp3lame "192k" 实际 ~194000）
    let mp3 = make_fixture_br(&dir, "real192.mp3", &["-c:a", "libmp3lame"], "192k");
    let m = tags::read_meta(&mp3).expect("读 192k MP3");
    assert_eq!(m.format, "mp3");
    assert_eq!(m.codec, "mp3");
    assert!(
        (150_000..=250_000).contains(&m.bitrate),
        "192k MP3 的码率必须是 bps 量级（实测 {}，若为 ~194 则是 kbps 误读）",
        m.bitrate
    );

    // 2) ALAC（无损）在 m4a 容器内必须识别为 alac，位深真实读出
    let alac = make_fixture_br(&dir, "real_alac.m4a", &["-c:a", "alac"], "192k");
    let m = tags::read_meta(&alac).expect("读 ALAC m4a");
    assert_eq!(m.format, "m4a", "容器仍是 m4a");
    assert_eq!(
        m.codec, "alac",
        "m4a 容器内的 ALAC 必须按 MP4 专用属性识别（不能空串/不能当 aac）"
    );
    assert_eq!(m.bit_depth, 16, "sine 16-bit 源的 ALAC 位深");

    // 对照组：同容器 AAC 必须识别为 aac（证明不是按扩展名猜编码）
    let aac = make_fixture_br(&dir, "real_aac.m4a", &["-c:a", "aac"], "96k");
    let m = tags::read_meta(&aac).expect("读 AAC m4a");
    assert_eq!(m.codec, "aac", "同容器的 AAC 不能被当成 ALAC");

    // FLAC：无损 + 位深（与远端比质量时依赖真实位深而非压缩码率）
    let flac = make_fixture_br(&dir, "real.flac", &["-c:a", "flac"], "192k");
    let m = tags::read_meta(&flac).expect("读 FLAC");
    assert_eq!(m.codec, "flac");
    assert_eq!(m.bit_depth, 16);

    // 3) 错扩展名：MP3 内容伪装 .bin 仍按内容识别、可读
    let bin = dir.join("wrongext.bin");
    std::fs::copy(&mp3, &bin).expect("复制错扩展名夹具");
    let m = tags::read_meta(&bin).expect("错扩展名必须可读（按内容探测）");
    assert_eq!(m.format, "mp3", "容器按实际内容识别，不看扩展名");
    assert_eq!(m.codec, "mp3");
    assert!(
        (150_000..=250_000).contains(&m.bitrate),
        "错扩展名文件的码率同样按 bps 读：{}",
        m.bitrate
    );

    std::fs::remove_dir_all(&dir).ok();
}
