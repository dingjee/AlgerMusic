//! 真实公开接口探测工具（不写入任何账户数据）。
//!
//! 用法：
//! ```text
//! cargo run --example live_probe -- [搜索关键词]
//! ```
//!
//! 该工具只访问 **公开** 接口：搜索、公开歌单详情、歌曲播放地址与第三方音源解析，
//! 不会登录、不会创建 / 修改任何歌单。

use std::time::Duration;

use alger_music_lib::netease::NeteaseClient;
use alger_music_lib::sources::{Resolver, SourceContext, SourceKind};

/// 一个公开歌单（网易云「华语热歌榜」类公开歌单），用于验证完整歌单读取。
const PUBLIC_PLAYLIST_ID: i64 = 3778678;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let keyword = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "周杰伦 晴天".to_string());

    let client = NeteaseClient::new();
    let resolver = Resolver::new();

    println!("=== 0. 系统强调色（NSColor.controlAccentColor）===");
    match alger_music_lib::theme::accent_hex() {
        Some(hex) => println!("  accent = {hex}"),
        None => println!("  accent = 不可用（当前平台不支持）"),
    }

    println!("=== 1. 公开搜索：{} ===", keyword);
    let (songs, total) = client.search_songs(&keyword, 10, 0).await?;
    println!("  结果总数 = {total}，本页 = {}", songs.len());
    for song in songs.iter().take(5) {
        println!(
            "  - id={} «{}» / {}  {}",
            song.id,
            song.name,
            song.artist_text(),
            song.album.name
        );
    }
    if songs.is_empty() {
        return Err("搜索无结果，无法继续".into());
    }
    let target = songs[0].clone();

    println!(
        "\n=== 2. 公开歌单详情：{}（验证 trackIds 分页补齐）===",
        PUBLIC_PLAYLIST_ID
    );
    let playlist = client.playlist_detail(PUBLIC_PLAYLIST_ID).await?;
    println!(
        "  «{}» trackCount={} trackIds={}",
        playlist.name,
        playlist.track_count,
        playlist.track_ids.len()
    );
    let ids: Vec<i64> = playlist.track_ids.iter().copied().take(500).collect();
    let detail = client.song_details(&ids).await?;
    println!(
        "  首 500 个 id 补齐到 {} 首歌曲（缺失 {}）",
        detail.len(),
        ids.len() - detail.len()
    );

    println!("\n=== 3. 第三方音源解析：{} ===", target.name);
    let ctx = SourceContext::new(
        target.id,
        &target.name,
        &target
            .artists
            .iter()
            .map(|a| a.name.clone())
            .collect::<Vec<_>>(),
        &target.album.name,
        target.duration_ms,
    );
    for kind in SourceKind::all() {
        let started = std::time::Instant::now();
        match resolver.resolve_one(kind, &ctx).await {
            Ok(audio) => {
                println!(
                    "  [{}] 命中 {}  url={}  ({:.1}s)",
                    kind.as_str(),
                    audio.source_label,
                    &audio.url[..audio.url.len().min(96)],
                    started.elapsed().as_secs_f64()
                );
                match resolver.probe_best(&audio.url).await {
                    Ok((url, br, size, ext)) => println!(
                        "        探测通过: {}  {}  {}  格式={}",
                        &url[..url.len().min(96)],
                        br,
                        size,
                        if ext.is_empty() { "未知" } else { &ext }
                    ),
                    Err(e) => println!("        探测失败: {e}"),
                }
            }
            Err(e) => println!(
                "  [{}] 失败: {}  ({:.1}s)",
                kind.as_str(),
                e,
                started.elapsed().as_secs_f64()
            ),
        }
    }

    println!("\n=== 4. 官方播放地址（未登录，通常无版权）===");
    match client.song_url(target.id, "higher").await {
        Ok(u) => println!(
            "  url={:?} br={} size={} freeTrial={}",
            u.url, u.br, u.size, u.free_trial
        ),
        Err(e) => println!("  失败: {e}"),
    }

    println!("\n=== 5. 下载链路（第三方音源，落到临时目录）===");
    let dir = std::env::temp_dir().join("alger-live-probe");
    let _ = std::fs::create_dir_all(&dir);
    let kinds = [SourceKind::Pyncmd, SourceKind::GdMusic];
    match resolver.resolve(&ctx, &kinds).await {
        Ok(audio) => {
            let http = reqwest::Client::builder()
                .timeout(Duration::from_secs(60))
                .build()?;
            let resp = http.get(&audio.url).send().await?;
            println!(
                "  HTTP {} content-length={:?} type={:?}",
                resp.status(),
                resp.content_length(),
                resp.headers().get("content-type")
            );
            let bytes = resp.bytes().await?;
            println!("  下载字节数 = {}", bytes.len());
            let path = dir.join("probe.bin");
            std::fs::write(&path, &bytes)?;
            println!("  已保存到 {}", path.display());
        }
        Err(failures) => {
            for (kind, e) in failures {
                println!("  [{}] {e}", kind.as_str());
            }
        }
    }

    println!("\n探测完成。");
    Ok(())
}
