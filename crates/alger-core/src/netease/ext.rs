//! 原生端新增的网易云端点（私人 FM / 心动模式 / 关注艺人 / 新作 / 热门 / 专辑 / 艺人详情）。
//!
//! 端点与参数对齐上游 `neteasecloudmusicapienhanced/api-enhanced` 的对应 module：
//! - `personal_fm`             → weapi `/api/v1/radio/get`
//! - `playmode_intelligence_list` → weapi `/api/playmode/intelligence/list`
//! - `artist_sublist`          → weapi `/api/artist/sublist`
//! - `artist_new_song`         → weapi `/api/sub/artist/new/works/song/list`
//! - `artist_top_song`         → weapi `/api/artist/top/song`
//! - `artist_albums`           → weapi `/api/artist/albums/{id}`
//! - `artist_detail`           → weapi `/api/artist/v3/detail`
//! - `top_playlists`           → weapi `/api/playlist/list`（公开热门歌单，**匿名可用**）
//!
//! 上游结构解析全部防御式：字段缺失返回空集合，不 panic；
//! 真实返回结构以只读联调验证为准（见 DEV 执行状态）。

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use super::client::{ApiError, NeteaseClient};
use super::models::{Artist, Playlist, Song};

impl NeteaseClient {
    /// 私人 FM：返回一槽推荐歌曲。
    pub async fn personal_fm(&self) -> Result<Vec<Song>, ApiError> {
        let res = self.weapi("/api/v1/radio/get", json!({})).await?;
        let data = res
            .get("data")
            .and_then(|d| d.as_array())
            .cloned()
            .unwrap_or_default();
        let mut out = Vec::new();
        for item in &data {
            // FM 条目可能是 {mainSong: {...}} 也可能直接是歌曲对象
            let song_value = item.get("mainSong").unwrap_or(item);
            if let Some(song) = Song::from_value(song_value) {
                out.push(song);
            }
        }
        Ok(out)
    }

    /// 歌单心动模式 / 智能播放：基于歌单与种子歌曲返回推荐序列。
    pub async fn playmode_intelligence(
        &self,
        playlist_id: i64,
        song_id: i64,
        start_music_id: i64,
    ) -> Result<Vec<Song>, ApiError> {
        let res = self
            .weapi(
                "/api/playmode/intelligence/list",
                json!({
                    "songId": song_id.to_string(),
                    "pid": playlist_id.to_string(),
                    "type": "fromPlayOne",
                    "playlistId": playlist_id.to_string(),
                    "startMusicId": start_music_id.to_string(),
                    "count": 1,
                }),
            )
            .await?;
        let data = res
            .get("data")
            .and_then(|d| d.as_array())
            .cloned()
            .unwrap_or_default();
        let mut out = Vec::new();
        for item in &data {
            let song_value = item.get("songInfo").unwrap_or(item);
            if let Some(song) = Song::from_value(song_value) {
                out.push(song);
            }
        }
        Ok(out)
    }

    /// 已关注艺人（**分页取全**）。
    ///
    /// 旧实现只取 `limit=100, offset=0` 一页，关注超过 100 个时静默丢人。
    /// 现在按 `more` / `hasMore` 信号翻页取全：去重、空页终止、页数上限
    /// 保护；登录 / 业务 / 解析错误一律上抛，绝不吞成空列表（否则「关注
    /// 艺人的新作」会假空）。关注关系完全来自上游真实返回，不做任何合成。
    pub async fn artist_sublist_all(&self) -> Result<Vec<FollowArtist>, ApiError> {
        artist_sublist_collect(|limit, offset| {
            let client = self;
            async move { client.artist_sublist_page(limit, offset).await }
        })
        .await
    }

    /// 单页拉取 + 解析（code!=200 的登录 / 业务错误由 `check_response`
    /// 上抛，这里只处理结构解析）。
    async fn artist_sublist_page(
        &self,
        limit: u32,
        offset: u32,
    ) -> Result<ArtistSublistPage, ApiError> {
        let res = self
            .weapi(
                "/api/artist/sublist",
                json!({ "limit": limit, "offset": offset }),
            )
            .await?;
        parse_artist_sublist_page(&res)
    }

    /// 关注艺人的新歌 / 新作（按艺人分组）。
    ///
    /// 上游 `artist_new_song.js` 实际发送的是
    /// `{limit, startTimestamp: query.before || Date.now()}` —— **不是**
    /// `offset` / `total`；旧实现用 `offset` / `total` 会拿不到数据。
    pub async fn artist_new_works(
        &self,
        limit: u32,
        before_timestamp: Option<i64>,
    ) -> Result<Vec<ArtistNewWorks>, ApiError> {
        let res = self
            .weapi(
                "/api/sub/artist/new/works/song/list",
                artist_new_works_payload(limit, before_timestamp),
            )
            .await?;
        let data = res
            .get("data")
            .and_then(|d| d.as_array())
            .cloned()
            .unwrap_or_default();
        Ok(data.iter().filter_map(ArtistNewWorks::from_value).collect())
    }

    /// 专辑内容（`/api/v1/album/{id}`）：专辑信息 + 曲目列表。
    pub async fn album_detail(&self, id: i64) -> Result<AlbumDetail, ApiError> {
        let res = self
            .weapi(&format!("/api/v1/album/{}", id), json!({}))
            .await?;
        let album_raw = res.get("album").cloned().unwrap_or(Value::Null);
        let album = AlbumBrief {
            id: album_raw.get("id").and_then(|i| i.as_i64()).unwrap_or(id),
            name: album_raw
                .get("name")
                .and_then(|n| n.as_str())
                .unwrap_or("未知专辑")
                .to_string(),
            pic_url: album_raw
                .get("picUrl")
                .and_then(|p| p.as_str())
                .unwrap_or("")
                .to_string(),
            artists: album_raw
                .get("artists")
                .and_then(|a| a.as_array())
                .map(|a| a.iter().filter_map(Artist::from_value_raw).collect())
                .unwrap_or_default(),
        };
        let songs = res
            .get("songs")
            .and_then(|s| s.as_array())
            .cloned()
            .unwrap_or_default();
        let songs: Vec<Song> = songs.iter().filter_map(Song::from_value).collect();
        Ok(AlbumDetail { album, songs })
    }

    /// 艺人热门歌曲。
    pub async fn artist_top_songs(&self, id: i64, limit: u32) -> Result<Vec<Song>, ApiError> {
        let res = self
            .weapi(
                "/api/artist/top/song",
                json!({ "id": id.to_string(), "limit": limit }),
            )
            .await?;
        let songs = res
            .get("songs")
            .and_then(|s| s.as_array())
            .cloned()
            .unwrap_or_default();
        Ok(songs.iter().filter_map(Song::from_value).collect())
    }

    /// 艺人专辑列表。
    pub async fn artist_albums(
        &self,
        id: i64,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<RichAlbum>, ApiError> {
        let res = self
            .weapi(
                &format!("/api/artist/albums/{}", id),
                json!({ "limit": limit, "offset": offset }),
            )
            .await?;
        let albums = res
            .get("hotAlbums")
            .and_then(|a| a.as_array())
            .cloned()
            .unwrap_or_default();
        Ok(albums.iter().filter_map(RichAlbum::from_value).collect())
    }

    /// 艺人详情（名称、头像、作品数量、关注状态）。
    pub async fn artist_detail(&self, id: i64) -> Result<ArtistDetail, ApiError> {
        let res = self
            .weapi("/api/artist/v3/detail", json!({ "id": id.to_string() }))
            .await?;
        let artist = res
            .get("data")
            .and_then(|d| d.get("artist"))
            .cloned()
            .ok_or_else(|| ApiError::Decode("艺人详情缺失".into()))?;
        Ok(ArtistDetail {
            id: artist.get("id").and_then(|i| i.as_i64()).unwrap_or(id),
            name: artist
                .get("name")
                .and_then(|n| n.as_str())
                .unwrap_or("")
                .to_string(),
            pic_url: artist
                .get("img1v1Url")
                .or_else(|| artist.get("picUrl"))
                .and_then(|p| p.as_str())
                .unwrap_or("")
                .to_string(),
            album_size: artist
                .get("albumSize")
                .and_then(|v| v.as_i64())
                .unwrap_or(0),
            music_size: artist
                .get("musicSize")
                .and_then(|v| v.as_i64())
                .unwrap_or(0),
            followed: artist
                .get("followed")
                .and_then(|f| f.as_bool())
                .unwrap_or(false),
        })
    }

    /// 公开热门歌单（`/api/playlist/list`）。
    ///
    /// 上游参数：`{cat, order, limit, offset, total}`（参考
    /// `NeteaseCloudMusicApiEnhanced/api-enhanced/module/top_playlist.js`）。
    ///
    /// - **匿名可用**：不需要登录（探索页的「推荐歌单」分区用）；
    /// - `playlists` 缺失 / 不是数组 → **明确的解析错误**（绝不伪装成
    ///   「没有歌单」）；合法空数组 → 空列表；
    /// - **坏 ID 剔除**（`id <= 0`）、**重复 ID 按首次出现去重**（顺序稳定）。
    pub async fn top_playlists(
        &self,
        category: &str,
        order: &str,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<Playlist>, ApiError> {
        let res = self
            .weapi(
                "/api/playlist/list",
                json!({
                    "cat": category,
                    "order": order,
                    "limit": limit,
                    "offset": offset,
                    "total": true,
                }),
            )
            .await?;
        parse_top_playlists(&res)
    }

    /// 歌词以外的单曲详情（含 MV / 关联信息时的防御式封装）。
    pub async fn song_detail(&self, id: i64) -> Result<Song, ApiError> {
        let songs = self.song_details(&[id]).await?;
        songs
            .into_iter()
            .next()
            .ok_or_else(|| ApiError::Decode("歌曲详情缺失".into()))
    }

    /// 相似歌曲（`/api/v1/discovery/simiSong`）。
    ///
    /// 上游 `simi_song.js` 的请求体是 `{songid, limit, offset}`（weapi），
    /// 响应通常带 **顶层** `songs` 数组；少数上游把数组放在 `data.songs`。
    ///
    /// - **结构错误 ≠ 空结果**：`songs` 缺失 / 不是数组 → 明确的解析错误
    ///   （绝不伪装成「没有相似歌曲」）；
    /// - **合法空数组** → `Ok(vec![])`（上游真的没有相似歌曲）；
    /// - 解析复用 `Song::from_value`（`ar` / `al` / `dt` 字段都归一化）。
    pub async fn similar_songs(
        &self,
        song_id: i64,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<Song>, ApiError> {
        let res = self
            .weapi(
                "/api/v1/discovery/simiSong",
                json!({
                    "songid": song_id.to_string(),
                    "limit": limit,
                    "offset": offset,
                }),
            )
            .await?;
        parse_similar_songs(&res)
    }
}

/// 解析相似歌曲响应（**结构错误与合法空数组严格区分**）。
///
/// - `songs` 顶层优先，其次 `data.songs`（不同上游变体）；
/// - 都没有 → `ApiError::Decode`（结构不识别，不是「没有相似歌曲」）；
/// - 是数组但为空 → 合法空结果；
/// - 数组非空却一条都解析不出 → `ApiError::Decode`（条目结构不识别）。
pub(crate) fn parse_similar_songs(res: &Value) -> Result<Vec<Song>, ApiError> {
    let raw = res.get("songs").or_else(|| res.get("data").and_then(|d| d.get("songs")));
    let raw = match raw {
        Some(value) => value,
        None => {
            return Err(ApiError::Decode(
                "相似歌曲响应缺少 songs 字段（结构不识别）".into(),
            ))
        }
    };
    let arr = raw.as_array().ok_or_else(|| {
        ApiError::Decode("相似歌曲响应的 songs 不是数组（结构不识别）".into())
    })?;
    let songs: Vec<Song> = arr.iter().filter_map(Song::from_value).collect();
    if arr.len() > 0 && songs.is_empty() {
        return Err(ApiError::Decode(format!(
            "相似歌曲返回 {} 条但全部无法解析（条目结构不识别）",
            arr.len()
        )));
    }
    Ok(songs)
}

/// 解析公开歌单响应（**结构错误与合法空数组严格区分**）。
///
/// - `playlists` 顶层优先，其次 `data.playlists`（不同上游变体）；
/// - 都没有 → `ApiError::Decode`（结构不识别，不是「没有歌单」）；
/// - 是数组但为空 → 合法空结果；
/// - **坏 ID**（`id <= 0`）按条目剔除、**重复 ID** 按首次出现去重
///   （顺序稳定，上游偶发重复不会产生重复条目）。
pub(crate) fn parse_top_playlists(res: &Value) -> Result<Vec<Playlist>, ApiError> {
    let raw = res
        .get("playlists")
        .or_else(|| res.get("data").and_then(|d| d.get("playlists")));
    let raw = match raw {
        Some(value) => value,
        None => {
            return Err(ApiError::Decode(
                "公开歌单响应缺少 playlists 字段（结构不识别）".into(),
            ))
        }
    };
    let arr = raw.as_array().ok_or_else(|| {
        ApiError::Decode("公开歌单响应的 playlists 不是数组（结构不识别）".into())
    })?;
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::with_capacity(arr.len());
    for value in arr {
        let playlist = Playlist::from_value(value);
        if playlist.id <= 0 {
            continue;
        }
        if !seen.insert(playlist.id) {
            continue;
        }
        out.push(playlist);
    }
    Ok(out)
}

/// 已关注艺人（侧栏 / 首页「关注艺人的新作」数据源）。
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct FollowArtist {
    pub id: i64,
    pub name: String,
    pub pic_url: String,
    /// 专辑数量（用于展示）。
    pub album_count: i64,
    /// 歌曲数量（用于展示）。
    pub music_count: i64,
}

/// `/api/artist/sublist` 单页解析结果。
#[derive(Debug, Clone)]
pub struct ArtistSublistPage {
    /// 解析出的关注艺人（可为空 = 真实空页）。
    pub data: Vec<FollowArtist>,
    /// 上游「还有更多」信号：`more` / `hasMore` 任一出现即取其值
    /// （不同上游变体字段名不同）；两者都缺省为 `None`，由收集循环
    /// 按「非空页继续翻页」语义处理，空页终止。
    pub more: Option<bool>,
}

/// 单页解析。
///
/// - `data` **必须**是数组（可为空数组）：缺失 / null / 非数组都是明确的
///   解析失败并上抛——绝不静默当空列表（那会把登录态异常 / 上游结构
///   变化伪装成「没有关注任何艺人」）；
/// - 非空 `data` 却一条都解析不出（条目结构不认识）→ 同样明确失败；
/// - code != 200 在 `check_response` 已转为 `NeedLogin` / `Business`，
///   不会走到这里。
pub(crate) fn parse_artist_sublist_page(res: &Value) -> Result<ArtistSublistPage, ApiError> {
    let data = res
        .get("data")
        .ok_or_else(|| ApiError::Decode("关注艺人列表响应缺少 data 字段".into()))?;
    let arr = data
        .as_array()
        .ok_or_else(|| ApiError::Decode("关注艺人列表响应 data 不是数组".into()))?;
    let mut items = Vec::with_capacity(arr.len());
    for v in arr {
        if let Some(a) = FollowArtist::from_value(v) {
            items.push(a);
        }
    }
    if arr.len() > items.len() && items.is_empty() {
        return Err(ApiError::Decode(format!(
            "关注艺人列表返回 {} 条但全部无法解析（条目结构不识别）",
            arr.len()
        )));
    }
    let more = res
        .get("more")
        .and_then(|v| v.as_bool())
        .or_else(|| res.get("hasMore").and_then(|v| v.as_bool()));
    Ok(ArtistSublistPage { data: items, more })
}

/// 分页参数与终止保护：每页 100，最多 20 页（2000 个关注艺人）。
/// 上限内取不全 → 明确报错，不静默截断成不完整列表。
pub(crate) const ARTIST_SUBLIST_PAGE_SIZE: u32 = 100;
pub(crate) const ARTIST_SUBLIST_MAX_PAGES: u32 = 20;

/// 通用分页收集（`fetch(limit, offset)` 由真实客户端或测试 fake 提供）。
///
/// - **去重**：跨页按 id 去重，保留首次出现顺序（上游偶发重复不产生
///   重复条目）；
/// - **终止**：空页立即终止（无论 more 与否）；`more=false` 终止；
///   信号缺省时按「非空页继续」处理（空页兜底终止）；
/// - **保护**：页数达上限仍未结束 → `Business` 错误（明确失败，不返回
///   伪装完整的半截列表）；
/// - **错误不吞**：任何一页的登录 / 业务 / 解析错误原样上抛。
pub(crate) async fn artist_sublist_collect<F, Fut>(
    mut fetch: F,
) -> Result<Vec<FollowArtist>, ApiError>
where
    F: FnMut(u32, u32) -> Fut,
    Fut: std::future::Future<Output = Result<ArtistSublistPage, ApiError>>,
{
    let mut seen = std::collections::HashSet::new();
    let mut out: Vec<FollowArtist> = Vec::new();
    let mut offset: u32 = 0;
    for _ in 0..ARTIST_SUBLIST_MAX_PAGES {
        let page = fetch(ARTIST_SUBLIST_PAGE_SIZE, offset).await?;
        // 空页终止：先于任何信号判断（上游结尾可能给空页，也防 more 恒真）
        let page_len = page.data.len();
        if page_len == 0 {
            return Ok(out);
        }
        for a in page.data {
            if seen.insert(a.id) {
                out.push(a);
            }
        }
        // offset 按上游 **实际返回条数** 推进（去重前计数）
        offset = offset.saturating_add(page_len as u32);
        match page.more {
            Some(false) => return Ok(out),
            // Some(true) / None：继续翻页（None 语义见 ArtistSublistPage）
            _ => continue,
        }
    }
    Err(ApiError::Business(format!(
        "关注艺人超过单次拉取上限（{} 页 × {} 条），已停止以避免返回不完整列表",
        ARTIST_SUBLIST_MAX_PAGES, ARTIST_SUBLIST_PAGE_SIZE
    )))
}

impl FollowArtist {
    fn from_value(v: &Value) -> Option<Self> {
        let id = v.get("id").and_then(|i| i.as_i64()).unwrap_or(0);
        if id == 0 {
            return None;
        }
        Some(FollowArtist {
            id,
            name: v
                .get("name")
                .and_then(|n| n.as_str())
                .unwrap_or("")
                .to_string(),
            pic_url: v
                .get("picUrl")
                .or_else(|| v.get("img1v1Url"))
                .and_then(|p| p.as_str())
                .unwrap_or("")
                .to_string(),
            album_count: v.get("albumSize").and_then(|a| a.as_i64()).unwrap_or(0),
            music_count: v.get("musicSize").and_then(|a| a.as_i64()).unwrap_or(0),
        })
    }
}

/// 某位关注艺人的新作（新歌列表）。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ArtistNewWorks {
    pub artist: Artist,
    pub songs: Vec<Song>,
}

impl ArtistNewWorks {
    fn from_value(v: &Value) -> Option<Self> {
        let artist = v
            .get("artist")
            .and_then(Artist::from_value_raw)
            .unwrap_or(Artist {
                id: 0,
                name: String::new(),
            });
        let songs = v
            .get("songs")
            .and_then(|s| s.as_array())
            .cloned()
            .unwrap_or_default();
        let songs: Vec<Song> = songs.iter().filter_map(Song::from_value).collect();
        if songs.is_empty() {
            return None;
        }
        Some(ArtistNewWorks { artist, songs })
    }
}

/// 带发行信息的专辑（艺人专辑列表条目）。
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct RichAlbum {
    pub id: i64,
    pub name: String,
    pub pic_url: String,
    /// 发行时间（Unix 毫秒，未知为 0）。
    pub publish_time: i64,
    /// 曲目数量。
    pub size: i64,
    pub company: String,
}

impl RichAlbum {
    fn from_value(v: &Value) -> Option<Self> {
        let id = v.get("id").and_then(|i| i.as_i64()).unwrap_or(0);
        if id == 0 {
            return None;
        }
        Some(RichAlbum {
            id,
            name: v
                .get("name")
                .and_then(|n| n.as_str())
                .unwrap_or("未知专辑")
                .to_string(),
            pic_url: v
                .get("picUrl")
                .and_then(|p| p.as_str())
                .unwrap_or("")
                .to_string(),
            publish_time: v.get("publishTime").and_then(|t| t.as_i64()).unwrap_or(0),
            size: v.get("size").and_then(|s| s.as_i64()).unwrap_or(0),
            company: v
                .get("company")
                .and_then(|c| c.as_str())
                .unwrap_or("")
                .to_string(),
        })
    }
}

/// 艺人详情。
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ArtistDetail {
    pub id: i64,
    pub name: String,
    pub pic_url: String,
    pub album_size: i64,
    pub music_size: i64,
    pub followed: bool,
}

/// 专辑概要（`net.albumDetail` 的 `album` 字段）。
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct AlbumBrief {
    pub id: i64,
    pub name: String,
    pub pic_url: String,
    pub artists: Vec<Artist>,
}

/// 专辑详情（专辑概要 + 曲目）。
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct AlbumDetail {
    pub album: AlbumBrief,
    pub songs: Vec<Song>,
}

/// 关注艺人新歌的请求体（上游 `artist_new_song.js`）。
///
/// 上游实际发送 `{limit, startTimestamp: query.before || Date.now()}`；
/// **没有** `offset` / `total`（旧实现用错参数会拿不到数据）。
pub fn artist_new_works_payload(limit: u32, before_timestamp: Option<i64>) -> Value {
    let start = before_timestamp
        .filter(|v| *v > 0)
        .unwrap_or_else(|| crate::now_millis() as i64);
    json!({ "limit": limit, "startTimestamp": start })
}

impl Artist {
    /// 上游部分端点的艺人对象字段与 `models::Artist` 一致；
    /// 这里提供一个包内可见的原始解析包装，避免修改上游文件。
    pub(crate) fn from_value_raw(v: &Value) -> Option<Artist> {
        let name = v.get("name").and_then(|n| n.as_str())?;
        if name.is_empty() {
            return None;
        }
        Some(Artist {
            id: v.get("id").and_then(|i| i.as_i64()).unwrap_or(0),
            name: name.to_string(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 上游 `artist_new_song.js` 的真实参数：`{limit, startTimestamp}`。
    #[test]
    fn artist_new_works_payload_matches_upstream() {
        let p = artist_new_works_payload(20, Some(1_700_000_000_000));
        assert_eq!(p["limit"], 20);
        assert_eq!(p["startTimestamp"], 1_700_000_000_000i64);
        assert!(p.get("offset").is_none(), "上游没有 offset 参数");
        assert!(p.get("total").is_none(), "上游没有 total 参数");
        // 缺省 before 时用当前时间戳
        let p = artist_new_works_payload(5, None);
        assert!(p["startTimestamp"].as_i64().unwrap() > 0);
    }

    // ---------- artist_sublist 分页（fake 服务测试） ----------

    fn fa(id: i64) -> FollowArtist {
        FollowArtist {
            id,
            name: format!("艺人{}", id),
            pic_url: String::new(),
            album_count: 1,
            music_count: 2,
        }
    }

    fn ok_page(ids: &[i64], more: Option<bool>) -> ArtistSublistPage {
        ArtistSublistPage {
            data: ids.iter().map(|&i| fa(i)).collect(),
            more,
        }
    }

    /// 多页顺序取全：offset 按「上游实际返回条数」推进，more=false 停。
    #[tokio::test]
    async fn sublist_pagination_fetches_all_pages_in_order() {
        let pages = [
            ok_page(&(0..100).collect::<Vec<_>>(), Some(true)),
            ok_page(&(100..150).collect::<Vec<_>>(), Some(true)),
            ok_page(&(150..180).collect::<Vec<_>>(), Some(false)),
        ];
        let calls = std::rc::Rc::new(std::cell::RefCell::new(Vec::<(u32, u32)>::new()));
        let fetch = {
            let calls = std::rc::Rc::clone(&calls);
            move |limit: u32, offset: u32| {
                let idx = calls.borrow().len();
                calls.borrow_mut().push((limit, offset));
                let page = pages
                    .get(idx)
                    .cloned()
                    .unwrap_or_else(|| ok_page(&[], None));
                async move { Ok::<_, ApiError>(page) }
            }
        };
        let all = artist_sublist_collect(fetch).await.unwrap();
        assert_eq!(all.len(), 180, "三页必须取全（100+50+30）");
        assert_eq!(all[0].id, 0, "顺序保留：首个");
        assert_eq!(all[179].id, 179, "顺序保留：末个");
        assert_eq!(
            calls.borrow().as_slice(),
            &[(100, 0), (100, 100), (100, 150)],
            "分页参数必须按实际返回条数推进"
        );
    }

    /// 跨页重复 id 去重：保留首次出现，顺序不乱。
    #[tokio::test]
    async fn sublist_dedup_keeps_first_occurrence_and_order() {
        let pages = [
            ok_page(&[1, 2, 3], Some(true)),
            ok_page(&[2, 3, 4], Some(false)),
        ];
        let mut idx = 0usize;
        let fetch = move |_limit: u32, _offset: u32| {
            let p = pages
                .get(idx)
                .cloned()
                .unwrap_or_else(|| ok_page(&[], None));
            idx += 1;
            async move { Ok::<_, ApiError>(p) }
        };
        let all = artist_sublist_collect(fetch).await.unwrap();
        let ids: Vec<i64> = all.iter().map(|a| a.id).collect();
        assert_eq!(ids, vec![1, 2, 3, 4], "去重且保持首现顺序：{:?}", ids);
    }

    /// 空页立即终止：即使 more 恒真也不死循环。
    #[tokio::test]
    async fn sublist_empty_page_terminates_even_if_more_true() {
        let mut calls = 0usize;
        let fetch = move |_limit: u32, _offset: u32| {
            calls += 1;
            let p = if calls == 1 {
                ok_page(&[7], Some(true))
            } else {
                ok_page(&[], Some(true)) // 空页 + more=true（上游谎言/结尾）
            };
            async move { Ok::<_, ApiError>(p) }
        };
        let all = artist_sublist_collect(fetch).await.unwrap();
        assert_eq!(all.len(), 1, "空页即终止：{:?}", all.len());
    }

    /// more/hasMore 信号都缺省：按「非空页继续」翻页，空页兜底终止。
    #[tokio::test]
    async fn sublist_missing_more_signal_continues_until_empty() {
        let pages = [
            ok_page(&[1, 2], None),
            ok_page(&[3], None),
            ok_page(&[], None),
        ];
        let mut idx = 0usize;
        let fetch = move |_limit: u32, _offset: u32| {
            let p = pages
                .get(idx)
                .cloned()
                .unwrap_or_else(|| ok_page(&[], None));
            idx += 1;
            async move { Ok::<_, ApiError>(p) }
        };
        let all = artist_sublist_collect(fetch).await.unwrap();
        let ids: Vec<i64> = all.iter().map(|a| a.id).collect();
        assert_eq!(ids, vec![1, 2, 3]);
    }

    /// 终止保护：页数达上限仍未结束 → 明确报错，绝不静默截断。
    #[tokio::test]
    async fn sublist_page_cap_errors_instead_of_truncating() {
        let mut next_id = 0i64;
        let fetch = move |_limit: u32, _offset: u32| {
            let ids: Vec<i64> = (0..100)
                .map(|_| {
                    next_id += 1;
                    next_id
                })
                .collect();
            async move { Ok::<_, ApiError>(ok_page(&ids, Some(true))) }
        };
        let err = artist_sublist_collect(fetch)
            .await
            .expect_err("达到上限必须明确失败");
        let msg = err.to_string();
        assert!(msg.contains("上限"), "错误必须说明是分页上限保护：{}", msg);
    }

    /// 错误不吞：登录错误 / 中途业务错误原样上抛（绝不变成空列表）。
    #[tokio::test]
    async fn sublist_errors_are_propagated_not_swallowed() {
        // 首页即登录失效
        let fetch = |_l: u32, _o: u32| async { Err::<ArtistSublistPage, _>(ApiError::NeedLogin) };
        let err = artist_sublist_collect(fetch).await.unwrap_err();
        assert!(matches!(err, ApiError::NeedLogin), "实际 {:?}", err);

        // 第二页业务错误：错误上抛，不返回第一页的半截列表
        let mut n = 0usize;
        let fetch = move |_l: u32, _o: u32| {
            n += 1;
            let r = if n == 1 {
                Ok(ok_page(&[1], Some(true)))
            } else {
                Err(ApiError::Business("分页中途失败".into()))
            };
            async move { r }
        };
        let err = artist_sublist_collect(fetch).await.unwrap_err();
        assert!(
            matches!(err, ApiError::Business(ref m) if m.contains("中途")),
            "中途错误必须原样上抛：{:?}",
            err
        );
    }

    // ---------- artist_sublist 单页解析 ----------

    /// data 缺失 / 非数组 → 明确解析失败（不吞成空）。
    #[test]
    fn sublist_parse_rejects_missing_or_malformed_data() {
        let err = parse_artist_sublist_page(&json!({ "code": 200 })).unwrap_err();
        assert!(matches!(err, ApiError::Decode(_)), "缺 data：{:?}", err);

        let err = parse_artist_sublist_page(&json!({ "code": 200, "data": null })).unwrap_err();
        assert!(matches!(err, ApiError::Decode(_)), "data=null：{:?}", err);

        let err = parse_artist_sublist_page(&json!({ "code": 200, "data": "x" })).unwrap_err();
        assert!(matches!(err, ApiError::Decode(_)), "data 非数组：{:?}", err);
    }

    /// 非空 data 却一条都解析不出（条目结构不识别）→ 明确失败。
    #[test]
    fn sublist_parse_rejects_unparseable_nonempty_page() {
        let res = json!({
            "code": 200,
            "data": [ { "noId": 1 }, { "noId": 2 } ],
            "more": true,
        });
        let err = parse_artist_sublist_page(&res).unwrap_err();
        assert!(
            matches!(err, ApiError::Decode(ref m) if m.contains("全部无法解析")),
            "实际 {:?}",
            err
        );
    }

    /// 正常页：空数组合法；more / hasMore 两种字段都按真实信号解析；
    /// 都缺省为 None；id=0 的坏条目按既有防御式语义剔除。
    #[test]
    fn sublist_parse_normal_pages_and_more_variants() {
        // 真实空页：空数组 + hasMore=false（新版字段）
        let p = parse_artist_sublist_page(&json!({ "code": 200, "data": [], "hasMore": false }))
            .unwrap();
        assert!(p.data.is_empty());
        assert_eq!(p.more, Some(false));

        // 旧版字段名 more
        let p = parse_artist_sublist_page(
            &json!({ "code": 200, "data": [ { "id": 5, "name": "a" } ], "more": true }),
        )
        .unwrap();
        assert_eq!(p.data.len(), 1);
        assert_eq!(p.data[0].id, 5);
        assert_eq!(p.more, Some(true));

        // 信号都缺省 → None
        let p = parse_artist_sublist_page(&json!({ "code": 200, "data": [] })).unwrap();
        assert_eq!(p.more, None);

        // id=0 条目剔除，但仍有可解析条目时不报错
        let p = parse_artist_sublist_page(
            &json!({ "code": 200, "data": [ { "id": 0 }, { "id": 9, "name": "b" } ] }),
        )
        .unwrap();
        assert_eq!(p.data.len(), 1);
        assert_eq!(p.data[0].id, 9);
    }

    // ---------- 相似歌曲（simiSong） ----------

    fn simi_song(id: i64, name: &str) -> Value {
        json!({
            "id": id,
            "name": name,
            "ar": [ { "id": 7, "name": "艺人甲" } ],
            "al": { "id": 8, "name": "专辑乙", "picUrl": "http://x" },
            "dt": 200000,
        })
    }

    /// 正常响应：顶层 `songs` 数组 → 解析出曲目（字段归一化）。
    #[test]
    fn similar_songs_parses_top_level_array() {
        let res = json!({
            "code": 200,
            "songs": [ simi_song(100, "甲"), simi_song(101, "乙") ],
        });
        let songs = parse_similar_songs(&res).unwrap();
        assert_eq!(songs.len(), 2);
        assert_eq!(songs[0].id, 100);
        assert_eq!(songs[0].name, "甲");
        assert_eq!(songs[0].artist_text(), "艺人甲");
        assert_eq!(songs[0].album.name, "专辑乙");
        assert_eq!(songs[0].duration_ms, 200000);
    }

    /// **合法空数组** ≠ 错误：上游真的没有相似歌曲时必须返回空列表。
    #[test]
    fn similar_songs_accepts_legal_empty_array() {
        let res = json!({ "code": 200, "songs": [] });
        let songs = parse_similar_songs(&res).unwrap();
        assert!(songs.is_empty());
    }

    /// **结构错误** ≠ 空结果：缺 `songs` / 类型不对 → 明确解析错误。
    #[test]
    fn similar_songs_rejects_malformed_structure() {
        let err = parse_similar_songs(&json!({ "code": 200 })).unwrap_err();
        assert!(matches!(err, ApiError::Decode(_)), "缺 songs：{:?}", err);

        let err = parse_similar_songs(&json!({ "code": 200, "songs": null })).unwrap_err();
        assert!(matches!(err, ApiError::Decode(_)), "songs=null：{:?}", err);

        let err = parse_similar_songs(&json!({ "code": 200, "songs": "x" })).unwrap_err();
        assert!(matches!(err, ApiError::Decode(_)), "songs 非数组：{:?}", err);
    }

    /// 非空数组却一条都解析不出 → 明确失败（不伪装成空结果）。
    #[test]
    fn similar_songs_rejects_unparseable_entries() {
        let res = json!({
            "code": 200,
            "songs": [ { "noId": 1 }, { "noId": 2 } ],
        });
        let err = parse_similar_songs(&res).unwrap_err();
        assert!(
            matches!(err, ApiError::Decode(ref m) if m.contains("全部无法解析")),
            "实际 {:?}",
            err
        );
    }

    /// 兼容 `data.songs` 变体（少数上游把数组包在 `data` 里）。
    #[test]
    fn similar_songs_accepts_data_wrapped_array() {
        let res = json!({ "code": 200, "data": { "songs": [ simi_song(200, "丙") ] } });
        let songs = parse_similar_songs(&res).unwrap();
        assert_eq!(songs.len(), 1);
        assert_eq!(songs[0].id, 200);
    }

    // ---------- 公开热门歌单（playlist/list） ----------

    fn public_playlist(id: i64, name: &str, nickname: &str) -> Value {
        json!({
            "id": id,
            "name": name,
            "coverImgUrl": "https://p1.music.126.net/cover.jpg",
            "trackCount": 30,
            "creator": { "userId": 9, "nickname": nickname, "avatarUrl": "" },
        })
    }

    /// 正常响应：顶层 `playlists` → 解析出歌单（标题与网友昵称都在）。
    #[test]
    fn top_playlists_parses_top_level_array() {
        let res = json!({
            "code": 200,
            "total": 2,
            "playlists": [
                public_playlist(101, "热门歌单一", "网友甲"),
                public_playlist(102, "热门歌单二", "网友乙"),
            ],
        });
        let playlists = parse_top_playlists(&res).unwrap();
        assert_eq!(playlists.len(), 2);
        assert_eq!(playlists[0].id, 101);
        assert_eq!(playlists[0].name, "热门歌单一");
        assert_eq!(playlists[0].creator.nickname, "网友甲");
        assert_eq!(playlists[0].track_count, 30);
        assert_eq!(playlists[1].creator.nickname, "网友乙");
    }

    /// **合法空数组** ≠ 错误：上游真的没有公开歌单时必须返回空列表。
    #[test]
    fn top_playlists_accepts_legal_empty_array() {
        let res = json!({ "code": 200, "playlists": [] });
        let playlists = parse_top_playlists(&res).unwrap();
        assert!(playlists.is_empty());
    }

    /// **结构错误** ≠ 空结果：缺 `playlists` / 类型不对 → 明确解析错误。
    #[test]
    fn top_playlists_rejects_malformed_structure() {
        let err = parse_top_playlists(&json!({ "code": 200 })).unwrap_err();
        assert!(
            matches!(err, ApiError::Decode(_)),
            "缺 playlists：{:?}",
            err
        );

        let err = parse_top_playlists(&json!({ "code": 200, "playlists": null })).unwrap_err();
        assert!(
            matches!(err, ApiError::Decode(_)),
            "playlists=null：{:?}",
            err
        );

        let err = parse_top_playlists(&json!({ "code": 200, "playlists": "x" })).unwrap_err();
        assert!(
            matches!(err, ApiError::Decode(_)),
            "playlists 非数组：{:?}",
            err
        );
    }

    /// 坏 ID 剔除 + 重复 ID 按首次出现去重（顺序稳定）。
    #[test]
    fn top_playlists_filters_bad_ids_and_dedupes() {
        let res = json!({
            "code": 200,
            "playlists": [
                public_playlist(101, "甲", "n1"),
                public_playlist(0, "坏 ID", "n2"),
                public_playlist(101, "甲重复", "n3"),
                { "name": "没有 ID" },
                public_playlist(102, "乙", "n4"),
            ],
        });
        let playlists = parse_top_playlists(&res).unwrap();
        assert_eq!(
            playlists.len(),
            2,
            "坏 ID 剔除、重复去重：{:?}",
            playlists.len()
        );
        assert_eq!(playlists[0].id, 101);
        assert_eq!(playlists[0].name, "甲", "保留首次出现");
        assert_eq!(playlists[1].id, 102);
    }

    /// 兼容 `data.playlists` 变体。
    #[test]
    fn top_playlists_accepts_data_wrapped_array() {
        let res = json!({
            "code": 200,
            "data": { "playlists": [ public_playlist(200, "丙", "n5") ] },
        });
        let playlists = parse_top_playlists(&res).unwrap();
        assert_eq!(playlists.len(), 1);
        assert_eq!(playlists[0].id, 200);
    }
}
