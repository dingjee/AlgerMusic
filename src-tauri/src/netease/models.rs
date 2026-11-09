// SPDX-License-Identifier: MIT
// 移植自 NeteaseCloudMusicApi (Copyright (c) 2013-2022 Binaryify) 及其增强分支 neteasecloudmusicapienhanced/api-enhanced
// 详见 ../../THIRD_PARTY_LICENSES.md

//! 网易云数据模型。
//!
//! 上游歌曲对象同时存在 `ar` / `artists` 与 `al` / `album` 两套字段，
//! 这里统一归一化为 `artists` / `album`，并把 `dt`（毫秒）归一化为 `duration_ms`。

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// 歌手。
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Artist {
    pub id: i64,
    pub name: String,
}

impl Artist {
    fn from_value(v: &Value) -> Option<Self> {
        let name = v.get("name").and_then(|n| n.as_str()).unwrap_or("");
        if name.is_empty() {
            return None;
        }
        Some(Artist {
            id: v.get("id").and_then(|i| i.as_i64()).unwrap_or(0),
            name: name.to_string(),
        })
    }
}

/// 专辑。
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Album {
    pub id: i64,
    pub name: String,
    pub pic_url: String,
}

impl Album {
    fn from_value(v: &Value) -> Self {
        Album {
            id: v.get("id").and_then(|i| i.as_i64()).unwrap_or(0),
            name: v
                .get("name")
                .and_then(|n| n.as_str())
                .unwrap_or("未知专辑")
                .to_string(),
            pic_url: v
                .get("picUrl")
                .or_else(|| v.get("pic_str"))
                .and_then(|n| n.as_str())
                .unwrap_or("")
                .to_string(),
        }
    }
}

/// 歌曲。
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Song {
    pub id: i64,
    pub name: String,
    pub artists: Vec<Artist>,
    pub album: Album,
    /// 时长（毫秒）
    pub duration_ms: i64,
    /// 1 = 免费 / 0 = 付费
    pub fee: i32,
    pub copyright: i32,
}

impl Song {
    /// 从上游原始对象解析。
    pub fn from_value(v: &Value) -> Option<Song> {
        let id = v.get("id").and_then(|i| i.as_i64()).unwrap_or(0);
        if id == 0 {
            return None;
        }
        let artists_raw = v
            .get("ar")
            .or_else(|| v.get("artists"))
            .and_then(|a| a.as_array())
            .cloned()
            .unwrap_or_default();
        let artists: Vec<Artist> = artists_raw.iter().filter_map(Artist::from_value).collect();
        let album_raw = v
            .get("al")
            .or_else(|| v.get("album"))
            .cloned()
            .unwrap_or(Value::Null);
        let duration_ms = v
            .get("dt")
            .or_else(|| v.get("duration"))
            .and_then(|d| d.as_i64())
            .unwrap_or(0);
        Some(Song {
            id,
            name: v
                .get("name")
                .and_then(|n| n.as_str())
                .unwrap_or("未知歌曲")
                .to_string(),
            artists,
            album: Album::from_value(&album_raw),
            duration_ms,
            fee: v.get("fee").and_then(|f| f.as_i64()).unwrap_or(0) as i32,
            copyright: v.get("copyright").and_then(|c| c.as_i64()).unwrap_or(0) as i32,
        })
    }

    /// 歌手名拼接。
    pub fn artist_text(&self) -> String {
        self.artists
            .iter()
            .map(|a| a.name.clone())
            .collect::<Vec<_>>()
            .join(" / ")
    }

    /// 时长（秒）。
    pub fn duration_sec(&self) -> i64 {
        self.duration_ms / 1000
    }
}

/// 歌单创建者。
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Creator {
    pub user_id: i64,
    pub nickname: String,
    pub avatar_url: String,
}

/// 歌单概要。
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Playlist {
    pub id: i64,
    pub name: String,
    pub description: Option<String>,
    pub cover_img_url: String,
    pub track_count: i64,
    pub creator: Creator,
    /// 完整歌曲 ID 列表（来自 `trackIds`）。
    pub track_ids: Vec<i64>,
    /// 是否为当前用户创建的歌单。
    pub subscribed: bool,
}

impl Playlist {
    /// 从上游原始对象解析。
    pub fn from_value(v: &Value) -> Playlist {
        let creator_raw = v.get("creator").cloned().unwrap_or(Value::Null);
        let track_ids: Vec<i64> = v
            .get("trackIds")
            .and_then(|t| t.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|t| t.get("id").and_then(|i| i.as_i64()))
                    .collect()
            })
            .unwrap_or_default();
        let track_count = v
            .get("trackCount")
            .and_then(|t| t.as_i64())
            .unwrap_or(track_ids.len() as i64);
        Playlist {
            id: v.get("id").and_then(|i| i.as_i64()).unwrap_or(0),
            name: v
                .get("name")
                .and_then(|n| n.as_str())
                .unwrap_or("未命名歌单")
                .to_string(),
            description: v
                .get("description")
                .and_then(|d| d.as_str())
                .map(|s| s.to_string()),
            cover_img_url: v
                .get("coverImgUrl")
                .and_then(|c| c.as_str())
                .unwrap_or("")
                .to_string(),
            track_count,
            creator: Creator {
                user_id: creator_raw
                    .get("userId")
                    .and_then(|i| i.as_i64())
                    .unwrap_or(0),
                nickname: creator_raw
                    .get("nickname")
                    .and_then(|n| n.as_str())
                    .unwrap_or("")
                    .to_string(),
                avatar_url: creator_raw
                    .get("avatarUrl")
                    .and_then(|n| n.as_str())
                    .unwrap_or("")
                    .to_string(),
            },
            track_ids,
            subscribed: v
                .get("subscribed")
                .and_then(|s| s.as_bool())
                .unwrap_or(false),
        }
    }
}

/// 登录账号信息。
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Account {
    pub user_id: i64,
    pub nickname: String,
    pub avatar_url: String,
    pub vip_type: i32,
}

/// 从 `/api/nuser/account/get` 响应中解析账号信息。
///
/// `profile` 为 `null` 或 `userId <= 0` 时视为 **未登录**，返回 `None`，
/// 避免把空响应误当成有效账号。
pub fn parse_account(value: &Value) -> Option<Account> {
    let profile = value.get("profile")?;
    if !profile.is_object() {
        return None;
    }
    let user_id = profile.get("userId").and_then(|i| i.as_i64()).unwrap_or(0);
    if user_id <= 0 {
        return None;
    }
    Some(Account {
        user_id,
        nickname: profile
            .get("nickname")
            .and_then(|n| n.as_str())
            .filter(|n| !n.is_empty())
            .unwrap_or("未知用户")
            .to_string(),
        avatar_url: profile
            .get("avatarUrl")
            .and_then(|n| n.as_str())
            .unwrap_or("")
            .to_string(),
        vip_type: value
            .get("account")
            .and_then(|a| a.get("vipType"))
            .and_then(|v| v.as_i64())
            .unwrap_or(0) as i32,
    })
}

/// 歌词内容。
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Lyric {
    pub lrc: String,
    pub tlyric: String,
    pub yrc: String,
}

/// 播放地址信息。
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct SongUrl {
    pub id: i64,
    pub url: Option<String>,
    /// 码率（bps）
    pub br: i64,
    pub size: i64,
    pub level: Option<String>,
    pub encode_type: Option<String>,
    /// 是否为试听片段
    pub free_trial: bool,
}

impl SongUrl {
    /// 从上游 `/song/enhance/player/url/v1` 的数据项解析。
    pub fn from_value(v: &Value) -> SongUrl {
        let free_trial = v
            .get("freeTrialInfo")
            .map(|f| !f.is_null() && f.as_str().map(|s| !s.is_empty()).unwrap_or(true))
            .unwrap_or(false);
        SongUrl {
            id: v.get("id").and_then(|i| i.as_i64()).unwrap_or(0),
            url: v
                .get("url")
                .and_then(|u| u.as_str())
                .filter(|s| !s.is_empty())
                .map(|s| s.to_string()),
            br: v.get("br").and_then(|b| b.as_i64()).unwrap_or(0),
            size: v.get("size").and_then(|s| s.as_i64()).unwrap_or(0),
            level: v
                .get("level")
                .and_then(|l| l.as_str())
                .map(|s| s.to_string()),
            encode_type: v
                .get("encodeType")
                .and_then(|l| l.as_str())
                .map(|s| s.to_string()),
            free_trial,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn song_normalizes_aliases() {
        let raw = json!({
            "id": 186016,
            "name": "晴天",
            "ar": [{"id": 6452, "name": "周杰伦"}],
            "al": {"id": 18877, "name": "叶惠美", "picUrl": "http://x/y.jpg"},
            "dt": 269000
        });
        let song = Song::from_value(&raw).unwrap();
        assert_eq!(song.id, 186016);
        assert_eq!(song.artists[0].name, "周杰伦");
        assert_eq!(song.album.name, "叶惠美");
        assert_eq!(song.duration_ms, 269000);
        assert_eq!(song.duration_sec(), 269);
    }

    #[test]
    fn song_accepts_long_aliases() {
        let raw = json!({
            "id": 1, "name": "x",
            "artists": [{"id": 2, "name": "A"}],
            "album": {"id": 3, "name": "B"},
            "duration": 1000
        });
        let song = Song::from_value(&raw).unwrap();
        assert_eq!(song.artists[0].name, "A");
        assert_eq!(song.album.name, "B");
        assert_eq!(song.duration_ms, 1000);
    }

    #[test]
    fn playlist_reads_track_ids() {
        let raw = json!({
            "id": 5, "name": "p", "trackCount": 3,
            "creator": {"userId": 9, "nickname": "n"},
            "trackIds": [{"id": 1}, {"id": 2}, {"id": 3}]
        });
        let pl = Playlist::from_value(&raw);
        assert_eq!(pl.track_ids, vec![1, 2, 3]);
        assert_eq!(pl.creator.nickname, "n");
        assert_eq!(pl.track_count, 3);
    }

    #[test]
    fn account_parses_profile() {
        let raw = json!({
            "profile": {"userId": 42, "nickname": "me", "avatarUrl": "a"},
            "account": {"vipType": 1}
        });
        let acc = parse_account(&raw).unwrap();
        assert_eq!(acc.user_id, 42);
        assert_eq!(acc.nickname, "me");
        assert_eq!(acc.vip_type, 1);
    }

    #[test]
    fn account_rejects_null_profile() {
        assert!(parse_account(&json!({"profile": null, "account": {}})).is_none());
        assert!(parse_account(&json!({})).is_none());
        assert!(parse_account(&json!({"profile": {"userId": 0}})).is_none());
        assert!(parse_account(&json!({"profile": {"userId": -1}})).is_none());
    }

    /// IPC 往返：Rust 序列化必须是 camelCase，与前端 `types.ts` 保持一致。
    #[test]
    fn ipc_payloads_use_camel_case() {
        let song = Song::from_value(&json!({
            "id": 1, "name": "n",
            "ar": [{"id": 2, "name": "a"}],
            "al": {"id": 3, "name": "b", "picUrl": "u"},
            "dt": 1000
        }))
        .unwrap();
        let v = serde_json::to_value(&song).unwrap();
        assert_eq!(v["durationMs"], 1000);
        assert_eq!(v["artists"][0]["name"], "a");
        assert_eq!(v["album"]["picUrl"], "u");

        let playlist = Playlist::from_value(&json!({
            "id": 5, "name": "p", "trackCount": 1,
            "creator": {"userId": 9, "nickname": "n"},
            "trackIds": [{"id": 1}]
        }));
        let v = serde_json::to_value(&playlist).unwrap();
        assert_eq!(v["coverImgUrl"], "");
        assert_eq!(v["trackIds"][0], 1);
        assert_eq!(v["creator"]["userId"], 9);

        let acc = parse_account(&json!({
            "profile": {"userId": 42, "nickname": "me", "avatarUrl": "a"},
            "account": {"vipType": 1}
        }))
        .unwrap();
        let v = serde_json::to_value(&acc).unwrap();
        assert_eq!(v["userId"], 42);
        assert_eq!(v["avatarUrl"], "a");
        assert_eq!(v["vipType"], 1);
    }
}
