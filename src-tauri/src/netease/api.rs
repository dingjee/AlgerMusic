// SPDX-License-Identifier: MIT
// 移植自 NeteaseCloudMusicApi (Copyright (c) 2013-2022 Binaryify) 及其增强分支 neteasecloudmusicapienhanced/api-enhanced
// 详见 ../../THIRD_PARTY_LICENSES.md

//! 网易云业务接口封装。
//!
//! 端点与加密方式对齐上游 `neteasecloudmusicapienhanced/api-enhanced` 的 module 定义。

use serde_json::{json, Value};

use super::client::{ApiError, NeteaseClient};
use super::models::{parse_account, Account, Lyric, Playlist, Song, SongUrl};

impl NeteaseClient {
    /// 用给定 Cookie **独立**校验账号，不影响当前会话。
    ///
    /// 登录流程先调用本方法，只有校验成功才替换现有会话；
    /// 校验失败时原有 Cookie / 账号保持不变。
    pub async fn verify_account_with(cookie_raw: &str) -> Result<Account, ApiError> {
        let probe = NeteaseClient::new();
        probe.set_cookie(cookie_raw);
        probe.account().await
    }

    /// 账号信息（同时用于校验 Cookie 是否有效）。
    pub async fn account(&self) -> Result<Account, ApiError> {
        let res = self.weapi("/api/nuser/account/get", json!({})).await?;
        parse_account(&res).ok_or(ApiError::NeedLogin)
    }

    /// 退出登录（服务端注销）。
    pub async fn logout(&self) -> Result<(), ApiError> {
        self.weapi("/api/logout", json!({})).await.map(|_| ())
    }

    /// 用 **给定 Cookie** 独立注销（不影响当前会话的客户端状态）。
    ///
    /// 退出登录必须用「发起时的旧身份」注销：网络等待期间用户可能已经
    /// 重新登录，用可变 client 会把 **新会话** 在服务端注销掉
    /// （审查 E0-6）。
    pub async fn logout_with(cookie_raw: &str) -> Result<(), ApiError> {
        let probe = NeteaseClient::new();
        probe.set_cookie(cookie_raw);
        probe.logout().await
    }

    /// 用户歌单列表。
    pub async fn user_playlists(
        &self,
        uid: i64,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<Playlist>, ApiError> {
        let res = self
            .weapi(
                "/api/user/playlist",
                json!({
                    "uid": uid.to_string(),
                    "limit": limit,
                    "offset": offset,
                    "includeVideo": true,
                }),
            )
            .await?;
        let list = res
            .get("playlist")
            .and_then(|p| p.as_array())
            .cloned()
            .unwrap_or_default();
        Ok(list.iter().map(Playlist::from_value).collect())
    }

    /// 歌单详情（含完整 `trackIds`）。
    pub async fn playlist_detail(&self, id: i64) -> Result<Playlist, ApiError> {
        let res = self
            .eapi_with_fallback(
                "/api/v6/playlist/detail",
                json!({ "id": id.to_string(), "n": 100000, "s": 8 }),
            )
            .await?;
        let pl = res
            .get("playlist")
            .ok_or_else(|| ApiError::Decode("歌单详情缺失".into()))?;
        Ok(Playlist::from_value(pl))
    }

    /// 批量歌曲详情（上游限制单次不超过 1000 个 id）。
    pub async fn song_details(&self, ids: &[i64]) -> Result<Vec<Song>, ApiError> {
        if ids.is_empty() {
            return Ok(Vec::new());
        }
        let c = ids
            .iter()
            .map(|id| format!("{{\"id\":{}}}", id))
            .collect::<Vec<_>>()
            .join(",");
        let res = self
            .weapi("/api/v3/song/detail", json!({ "c": format!("[{}]", c) }))
            .await?;
        let songs = res
            .get("songs")
            .and_then(|s| s.as_array())
            .cloned()
            .unwrap_or_default();
        Ok(songs.iter().filter_map(Song::from_value).collect())
    }

    /// 搜索单曲。
    pub async fn search_songs(
        &self,
        keywords: &str,
        limit: u32,
        offset: u32,
    ) -> Result<(Vec<Song>, i64), ApiError> {
        let res = self
            .eapi_with_fallback(
                "/api/cloudsearch/pc",
                json!({
                    "s": keywords,
                    "type": 1,
                    "limit": limit,
                    "offset": offset,
                    "total": true,
                }),
            )
            .await?;
        let result = res.get("result").cloned().unwrap_or(Value::Null);
        let songs = result
            .get("songs")
            .and_then(|s| s.as_array())
            .cloned()
            .unwrap_or_default();
        let total = result
            .get("songCount")
            .and_then(|t| t.as_i64())
            .unwrap_or(songs.len() as i64);
        Ok((songs.iter().filter_map(Song::from_value).collect(), total))
    }

    /// 歌曲播放地址。
    pub async fn song_url(&self, id: i64, level: &str) -> Result<SongUrl, ApiError> {
        let mut data = json!({
            "ids": format!("[{}]", id),
            "level": level,
            "encodeType": "flac",
        });
        if level == "sky" {
            if let Some(obj) = data.as_object_mut() {
                obj.insert("immerseType".into(), json!("c51"));
            }
        }
        let res = self
            .eapi_with_fallback("/api/song/enhance/player/url/v1", data)
            .await?;
        let item = res
            .get("data")
            .and_then(|d| d.as_array())
            .and_then(|a| a.first())
            .cloned()
            .unwrap_or(Value::Null);
        Ok(SongUrl::from_value(&item))
    }

    /// 歌词（含逐字歌词 yrc）。
    pub async fn lyric(&self, id: i64) -> Result<Lyric, ApiError> {
        let res = self
            .eapi_with_fallback(
                "/api/song/lyric/v1",
                json!({
                    "id": id.to_string(),
                    "cp": false, "tv": 0, "lv": 0, "rv": 0,
                    "kv": 0, "yv": 0, "ytv": 0, "yrv": 0,
                }),
            )
            .await?;
        Ok(Lyric {
            lrc: res
                .get("lrc")
                .and_then(|l| l.get("lyric"))
                .and_then(|l| l.as_str())
                .unwrap_or("")
                .to_string(),
            tlyric: res
                .get("tlyric")
                .and_then(|l| l.get("lyric"))
                .and_then(|l| l.as_str())
                .unwrap_or("")
                .to_string(),
            yrc: res
                .get("yrc")
                .and_then(|l| l.get("lyric"))
                .and_then(|l| l.as_str())
                .unwrap_or("")
                .to_string(),
        })
    }
}
