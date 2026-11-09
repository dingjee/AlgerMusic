//! Tauri 命令层：前端与 Rust 后端之间的全部接口。

use serde::Serialize;
use serde_json::Value;
use std::path::Path;
use tauri::{AppHandle, State};

use crate::download::DownloadItem;
use crate::login;
use crate::netease::models::{Account, Lyric, Playlist, Song};
use crate::netease::NeteaseClient;
use crate::sources::{SourceContext, SourceKind};
use crate::state::AppState;

/// 单次 `/song/detail` 请求的最大歌曲数量（上游限制 1000，这里取 500 与旧实现一致）。
const SONG_DETAIL_BATCH: usize = 500;

/// 前端状态快照。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AppSnapshot {
    pub logged_in: bool,
    pub has_cookie: bool,
    pub account: Option<Account>,
    pub quality: String,
    pub sources: Vec<String>,
    pub download_dir: String,
    pub session_path: String,
    /// 当前登录态是否已经过真实校验。
    pub account_verified: bool,
    /// 运行平台：`macos` / `ios` / 其它。前端据此隐藏桌面专属功能。
    pub platform: String,
    /// 会话文件载入问题（损坏 / 读失败 / 已拒绝写入）。非空时必须
    /// **明确提示用户**（审查 E1-9）：否则用户只会看到后续保存失败，
    /// 不知道自己的会话文件出了什么问题。
    pub load_issue: Option<String>,
}

/// 当前运行平台标识。
fn platform_name() -> String {
    if cfg!(target_os = "ios") {
        "ios".to_string()
    } else if cfg!(target_os = "macos") {
        "macos".to_string()
    } else {
        "other".to_string()
    }
}

fn snapshot_of(state: &AppState) -> AppSnapshot {
    let data = state.session.get();
    AppSnapshot {
        logged_in: state.client.is_logged_in(),
        has_cookie: state.client.has_cookie(),
        account: data.account.clone(),
        quality: data.quality.clone(),
        sources: data.sources.clone(),
        download_dir: state.session.download_dir(),
        session_path: state.session.path(),
        account_verified: data.account.is_some(),
        platform: platform_name(),
        // 会话载入问题必须透出到界面（审查 E1-9）
        load_issue: state.session.load_issue(),
    }
}

/// 上报前端实测的音频解码能力（`audio.canPlayType` 结果）。
///
/// 前端把本机 WebView **无法播放** 的扩展名列表传上来（空列表 = 全部支持），
/// 解析链据此把「探测通过但本机放不了」的候选视为不可用并回退下一个音源。
/// iOS 的格式支持随 WebKit 版本演进（18.4 起已支持 Ogg/Opus/Vorbis），
/// 因此以运行时实测为准，不做硬编码平台表。
#[tauri::command]
pub fn set_unsupported_audio_formats(
    state: State<'_, AppState>,
    extensions: Vec<String>,
) -> Result<(), String> {
    state.resolver.set_unsupported_formats(extensions);
    Ok(())
}

/// 歌单详情（歌单信息 + 完整歌曲列表）。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlaylistDetail {
    pub playlist: Playlist,
    pub songs: Vec<Song>,
    /// 未能补齐的歌曲数量（上游 `trackIds` 中解析失败的条目）。
    pub missing: usize,
}

/// 可播放地址。
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlayableUrl {
    pub url: String,
    /// 码率（bps）
    pub br: i64,
    pub size: i64,
    /// 使用的音源标识。
    pub source: String,
    pub source_label: String,
    /// 是否为第三方音源。
    pub third_party: bool,
    /// 解析过程中的说明（例如官方无权限，已回退到第三方）。
    pub note: Option<String>,
}

/// 获取当前状态。
#[tauri::command]
pub fn get_snapshot(state: State<'_, AppState>) -> AppSnapshot {
    snapshot_of(&state)
}

/// 手动粘贴 Cookie 登录。
///
/// 候选 Cookie 先 **独立校验**，校验成功后才替换当前会话；
/// 校验失败时原有会话保持不变。
#[tauri::command]
pub async fn login_with_cookie(
    state: State<'_, AppState>,
    cookie: String,
) -> Result<AppSnapshot, String> {
    let cookie = cookie.trim().to_string();
    if cookie.is_empty() {
        return Err("请填写 Cookie".into());
    }
    if !cookie.contains("MUSIC_U") {
        return Err("Cookie 中未找到 MUSIC_U，请确认已登录网易云音乐后重新复制".into());
    }
    let account = crate::netease::NeteaseClient::verify_account_with(&cookie)
        .await
        .map_err(|e| format!("登录校验失败：{}", e))?;
    // E0 audit：登录入口不得 get+set 旧快照——会话写走事务闭包，持久化
    // 成功后在同一身份临界区内切换客户端 Cookie 并自增 generation；
    // 落盘失败时客户端保持旧身份，错误反馈用户。
    let account_cookie = cookie.clone();
    state
        .commit_identity(
            move |session| {
                session.update(move |data| {
                    data.cookie = account_cookie;
                    data.account = Some(account);
                })
            },
            Some(&cookie),
        )
        .map_err(|e| format!("保存会话失败：{}", e))?;
    Ok(snapshot_of(&state))
}

/// 打开内置网易云网页登录窗口。
#[tauri::command]
pub fn open_login_window(app: AppHandle) -> Result<(), String> {
    login::open_login_window(&app)
}

/// 退出登录（同时清理本 App 登录窗口中的 Cookie）。
#[tauri::command]
pub async fn logout(app: AppHandle, state: State<'_, AppState>) -> Result<AppSnapshot, String> {
    // E0 audit：记录发起时的 cookie / generation；网络注销等待期间用户
    // 可能已完成新登录，清理必须在身份锁内按「仍是旧身份」条件执行——
    // stale 时保留新登录，不得清掉。
    let cookie = state.session.get().cookie;
    let generation = state.generation();
    // 用 **捕获的旧 cookie** 注销（审查 E0-6）：用可变 client 会在等待
    // 期间切到新登录时把 **新会话** 在服务端注销掉。
    let _ = NeteaseClient::logout_with(&cookie).await;
    let cleared = state
        .clear_identity_if_current(&cookie, generation)
        .map_err(|e| format!("清理会话失败：{}", e))?;
    if cleared {
        login::clear_login_window_cookies(&app);
    }
    Ok(snapshot_of(&state))
}

/// 更新设置（音质、音源、下载目录）。
#[tauri::command]
pub fn update_settings(
    state: State<'_, AppState>,
    quality: Option<String>,
    sources: Option<Vec<String>>,
    download_dir: Option<String>,
) -> Result<AppSnapshot, String> {
    // R1：读改写整体走事务（串行锁 + 先落盘后提交），不用旧快照覆盖
    state
        .session
        .update(|data| {
            if let Some(q) = quality {
                if !q.trim().is_empty() {
                    data.quality = q.trim().to_string();
                }
            }
            if let Some(s) = sources {
                let filtered: Vec<String> = s
                    .iter()
                    .filter(|x| SourceKind::parse(x).is_some())
                    .map(|x| x.trim().to_lowercase())
                    .collect();
                if !filtered.is_empty() {
                    data.sources = filtered;
                }
            }
            if let Some(d) = download_dir {
                // iOS 的下载目录固定为当前沙盒的 Documents/AlgerMusic，不接受外部指定
                #[cfg(not(target_os = "ios"))]
                if !d.trim().is_empty() {
                    data.download_dir = d.trim().to_string();
                }
                #[cfg(target_os = "ios")]
                let _ = d;
            }
        })
        .map_err(|e| format!("保存设置失败：{}", e))?;
    Ok(snapshot_of(&state))
}

/// 用户歌单列表。
#[tauri::command]
pub async fn user_playlists(state: State<'_, AppState>) -> Result<Vec<Playlist>, String> {
    let uid = state
        .client
        .account()
        .await
        .map_err(|e| format!("获取账号信息失败：{}", e))?
        .user_id;
    let mut out = Vec::new();
    let mut offset = 0u32;
    loop {
        let page = state
            .client
            .user_playlists(uid, 50, offset)
            .await
            .map_err(|e| format!("获取歌单列表失败：{}", e))?;
        if page.is_empty() {
            break;
        }
        let count = page.len();
        out.extend(page);
        offset += count as u32;
        if count < 50 || offset > 1000 {
            break;
        }
    }
    Ok(out)
}

/// 歌单详情（含按 `trackIds` 补齐的完整歌曲列表）。
#[tauri::command]
pub async fn playlist_detail(
    state: State<'_, AppState>,
    id: i64,
) -> Result<PlaylistDetail, String> {
    let playlist = state
        .client
        .playlist_detail(id)
        .await
        .map_err(|e| format!("获取歌单详情失败：{}", e))?;
    let ids = playlist.track_ids.clone();
    let mut songs: Vec<Song> = Vec::with_capacity(ids.len());
    for chunk in ids.chunks(SONG_DETAIL_BATCH) {
        let batch = state
            .client
            .song_details(chunk)
            .await
            .map_err(|e| format!("补齐歌单歌曲失败：{}", e))?;
        songs.extend(batch);
    }
    let missing = ids.len().saturating_sub(songs.len());
    // 按 `trackIds` 顺序重排
    let mut map = std::collections::HashMap::new();
    for s in songs {
        map.insert(s.id, s);
    }
    let mut ordered: Vec<Song> = Vec::with_capacity(map.len());
    for id in &ids {
        if let Some(song) = map.remove(id) {
            ordered.push(song);
        }
    }
    Ok(PlaylistDetail {
        playlist,
        songs: ordered,
        missing,
    })
}

/// 搜索歌曲。
#[tauri::command]
pub async fn search_songs(
    state: State<'_, AppState>,
    keywords: String,
    limit: Option<u32>,
) -> Result<(Vec<Song>, i64), String> {
    let keywords = keywords.trim().to_string();
    if keywords.is_empty() {
        return Err("请输入搜索关键词".into());
    }
    state
        .client
        .search_songs(&keywords, limit.unwrap_or(50), 0)
        .await
        .map_err(|e| format!("搜索失败：{}", e))
}

/// 获取歌词。
#[tauri::command]
pub async fn get_lyric(state: State<'_, AppState>, id: i64) -> Result<Lyric, String> {
    state
        .client
        .lyric(id)
        .await
        .map_err(|e| format!("获取歌词失败：{}", e))
}

/// 解析播放地址：优先官方，失败后回退到第三方音源。
#[tauri::command]
pub async fn resolve_playable(
    state: State<'_, AppState>,
    song: Song,
) -> Result<PlayableUrl, String> {
    resolve_playable_impl(&state, song).await
}

/// 解析播放地址的内部实现（供下载复用）。
async fn resolve_playable_impl(state: &AppState, song: Song) -> Result<PlayableUrl, String> {
    let quality = state.session.get().quality;
    let mut note: Option<String> = None;

    match state.client.song_url(song.id, &quality).await {
        Ok(official) => {
            if let Some(url) = official.url.clone() {
                if !official.free_trial {
                    // 官方链接必须探测通过才算可用；坏链必须继续回退到第三方音源
                    match state.resolver.probe_best(&url).await {
                        Ok((url, br, size, ext)) => {
                            // 探测通过但格式本机放不了（如旧 WebView 不支持 Ogg）：
                            // 视为不可用，继续回退第三方音源
                            if state.resolver.rejects_format(&ext) {
                                note = Some(format!(
                                    "官方链接为 {} 格式，本机无法播放，已尝试第三方音源",
                                    ext
                                ));
                            } else {
                                return Ok(PlayableUrl {
                                    url,
                                    br: if br > 0 { br } else { official.br },
                                    size: if size > 0 { size } else { official.size },
                                    source: "netease".into(),
                                    source_label: "网易云官方".into(),
                                    third_party: false,
                                    note,
                                });
                            }
                        }
                        Err(e) => {
                            note = Some(format!("官方链接不可用（{}），已尝试第三方音源", e));
                        }
                    }
                } else {
                    note = Some("官方链接为试听片段，已尝试第三方音源".into());
                }
            } else {
                note = Some("官方未返回可播放地址（可能为 VIP 或无版权），已尝试第三方音源".into());
            }
        }
        Err(e) => {
            note = Some(format!("官方接口请求失败（{}），已尝试第三方音源", e));
        }
    }

    // 第三方回退
    let kinds: Vec<SourceKind> = state
        .session
        .get()
        .sources
        .iter()
        .filter_map(|s| SourceKind::parse(s))
        .collect();
    if kinds.is_empty() {
        return Err(format!(
            "{}；请在设置中至少启用一个第三方音源",
            note.unwrap_or_else(|| "未配置可用的第三方音源".into())
        ));
    }
    let ctx = SourceContext::new(
        song.id,
        &song.name,
        &song
            .artists
            .iter()
            .map(|a| a.name.clone())
            .collect::<Vec<_>>(),
        &song.album.name,
        song.duration_ms,
    );
    match state.resolver.resolve(&ctx, &kinds).await {
        Ok(audio) => Ok(PlayableUrl {
            url: audio.url,
            br: audio.br,
            size: audio.size,
            source: audio.source.clone(),
            source_label: audio.source_label.clone(),
            third_party: true,
            note,
        }),
        Err(failures) => {
            let detail = failures
                .iter()
                .map(|(k, e)| format!("{}：{}", k.label(), e))
                .collect::<Vec<_>>()
                .join("；");
            Err(format!(
                "{}{}",
                note.unwrap_or_else(|| "所有音源解析失败".into()),
                if detail.is_empty() {
                    String::new()
                } else {
                    format!("。{}", detail)
                }
            ))
        }
    }
}

/// 下载歌曲。
#[tauri::command]
pub async fn download_song(
    app: AppHandle,
    state: State<'_, AppState>,
    song: Song,
) -> Result<String, String> {
    let playable = resolve_playable_impl(&state, song.clone()).await?;
    // iOS：始终使用当前沙盒的固定目录（沙盒容器 UUID 会变，持久化路径会失效）
    let dir = state.session.download_dir();
    let name = song.name.clone();
    let artist = song.artist_text();
    let source = Some(playable.source.clone());
    state
        .downloads
        .start(
            app,
            song.id,
            &name,
            &artist,
            &playable.url,
            Path::new(&dir),
            source,
        )
        .await
}

/// 下载任务列表。
#[tauri::command]
pub fn list_downloads(state: State<'_, AppState>) -> Vec<DownloadItem> {
    state.downloads.list()
}

/// 打开下载目录。
///
/// iOS 没有桌面意义上的「打开文件夹」：下载文件位于沙盒 `Documents`，
/// 用户通过「文件」App 访问，这里返回明确提示而不是静默失败。
#[tauri::command]
pub fn open_download_folder(app: AppHandle, state: State<'_, AppState>) -> Result<(), String> {
    if cfg!(target_os = "ios") {
        return Err(
            "iOS 上请在系统「文件」App → 我的 iPhone → Alger Music 中查看下载的文件".into(),
        );
    }
    use tauri_plugin_opener::OpenerExt;
    let dir = state.session.download_dir();
    let path = PathBuf::from(&dir);
    if !path.exists() {
        std::fs::create_dir_all(&path).map_err(|e| format!("创建目录失败：{}", e))?;
    }
    app.opener()
        .open_path(path.to_string_lossy().to_string(), None::<&str>)
        .map_err(|e| format!("打开失败：{}", e))
}

/// 在文件管理器中显示文件。
#[tauri::command]
pub fn reveal_file(app: AppHandle, path: String) -> Result<(), String> {
    if cfg!(target_os = "ios") {
        return Err(
            "iOS 上请在系统「文件」App → 我的 iPhone → Alger Music 中查看下载的文件".into(),
        );
    }
    use tauri_plugin_opener::OpenerExt;
    let p = PathBuf::from(&path);
    if !p.exists() {
        return Err("文件不存在".into());
    }
    app.opener()
        .reveal_item_in_dir(&p)
        .map_err(|e| format!("打开失败：{}", e))
}

/// 选择下载目录。
///
/// iOS 沙盒内固定使用 `Documents/AlgerMusic`（「文件」App 可见），
/// 不提供目录选择；iOS 的安全作用域书签也无法长期持有外部目录。
#[tauri::command]
pub async fn pick_download_dir(
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<String, String> {
    #[cfg(target_os = "ios")]
    {
        let _ = app;
        Err(format!(
            "iOS 版下载目录固定为 {}（可在「文件」App 中访问）",
            state.session.download_dir()
        ))
    }
    #[cfg(not(target_os = "ios"))]
    {
        use tauri_plugin_dialog::DialogExt;
        let current = state.session.get().download_dir;
        let picked = app
            .dialog()
            .file()
            .set_title("选择下载目录")
            .set_directory(&current)
            .blocking_pick_folder();
        match picked.and_then(|p| p.into_path().ok()) {
            Some(p) => {
                // R1 / E0-7：读改写整体走事务闭包，不得用旧快照整体覆盖
                // （否则会回滚并发写入的 cookie / 账号 / 其它设置）。
                let dir = p.to_string_lossy().to_string();
                state
                    .session
                    .update(|data| {
                        data.download_dir = dir.clone();
                    })
                    .map_err(|e| format!("保存设置失败：{}", e))?;
                Ok(dir)
            }
            None => Err("已取消".into()),
        }
    }
}

/// 获取当前系统强调色（十六进制）。前端用它写入 CSS 变量。
#[tauri::command]
pub fn theme_accent() -> Option<String> {
    crate::theme::accent_hex()
}

/// 调试用：查看某个第三方音源的原始解析结果。
#[tauri::command]
pub async fn probe_source(
    state: State<'_, AppState>,
    kind: String,
    song: Song,
) -> Result<Value, String> {
    let source = SourceKind::parse(&kind).ok_or_else(|| "未知音源".to_string())?;
    let ctx = SourceContext::new(
        song.id,
        &song.name,
        &song
            .artists
            .iter()
            .map(|a| a.name.clone())
            .collect::<Vec<_>>(),
        &song.album.name,
        song.duration_ms,
    );
    match state.resolver.resolve_one(source, &ctx).await {
        Ok(audio) => Ok(serde_json::to_value(audio).unwrap_or(Value::Null)),
        Err(e) => Err(e.to_string()),
    }
}

use std::path::PathBuf;
