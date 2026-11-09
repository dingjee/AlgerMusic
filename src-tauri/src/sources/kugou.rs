// SPDX-License-Identifier: LGPL-3.0-only
// 移植自 @unblockneteasemusic/server v0.27.10 (Copyright (c) nondanee, 1715173329, pan93412)
// 详见 ../../THIRD_PARTY_LICENSES.md 与 licenses/LGPL-3.0-only.txt

//! 酷狗音源（移动端搜索接口 + `trackercdn` 换链）。
//!
//! 算法对齐上游 `@unblockneteasemusic/server` 的 `src/provider/kugou.js`。

use reqwest::Client;
use serde_json::Value;

use super::{select_by_duration, ResolvedAudio, SourceContext, SourceError};
use crate::cookie::encode_uri_component;
use crate::crypto::md5_hex;

const SEARCH_URL: &str = "http://mobilecdn.kugou.com/api/v3/search/song";
const TRACK_URL: &str = "http://trackercdn.kugou.com/i/v2/";
const LABEL: &str = "kugou";

/// 解析酷狗音源。
pub async fn resolve(http: &Client, ctx: &SourceContext) -> Result<ResolvedAudio, SourceError> {
    let keyword = ctx.keyword_unblock();
    if keyword.trim().is_empty() {
        return Err(SourceError::NoMatch(LABEL.into()));
    }
    let url = format!(
        "{}?keyword={}&page=1&pagesize=10",
        SEARCH_URL,
        encode_uri_component(&keyword)
    );
    let resp = http
        .get(&url)
        .send()
        .await
        .map_err(|e| SourceError::Request(LABEL.into(), e.to_string()))?;
    if !resp.status().is_success() {
        return Err(SourceError::Request(
            LABEL.into(),
            format!("搜索 HTTP {}", resp.status().as_u16()),
        ));
    }
    let text = resp
        .text()
        .await
        .map_err(|e| SourceError::Request(LABEL.into(), e.to_string()))?;
    let json: Value = serde_json::from_str(&text).map_err(|e| {
        SourceError::Decode(format!(
            "{} 搜索接口返回了非预期的内容（上游接口可能已变更）",
            LABEL
        ))
        .with_detail(e)
    })?;
    let info = json
        .get("data")
        .and_then(|d| d.get("info"))
        .and_then(|i| i.as_array())
        .cloned()
        .unwrap_or_default();
    if info.is_empty() {
        return Err(SourceError::NoMatch(LABEL.into()));
    }

    // 上游 select：只看前 5 条，时长差 < 5s 命中，否则取第一条
    let idx = select_by_duration(&info, ctx.duration_ms, |s| {
        s.get("duration").and_then(|d| d.as_i64()).map(|d| d * 1000)
    })
    .unwrap_or(0);
    let song = &info[idx];

    let album_id = song
        .get("album_id")
        .and_then(|a| a.as_str())
        .map(|s| s.to_string())
        .or_else(|| {
            song.get("album_id")
                .and_then(|a| a.as_i64())
                .map(|v| v.to_string())
        })
        .unwrap_or_default();

    // 上游 ENABLE_FLAC 默认关闭，因此只尝试 hqhash -> hash
    let hash_candidates = [
        song.get("320hash").and_then(|h| h.as_str()),
        song.get("hash").and_then(|h| h.as_str()),
    ];

    let mut last_err = String::new();
    for hash in hash_candidates.into_iter().flatten() {
        if hash.is_empty() {
            continue;
        }
        // key = md5(hashId + "kgcloudv2")
        let key = md5_hex(format!("{}kgcloudv2", hash).as_bytes());
        let url = format!(
            "{}?key={}&hash={}&appid=1005&pid=2&cmd=25&behavior=play&album_id={}",
            TRACK_URL, key, hash, album_id
        );
        let resp = match http.get(&url).send().await {
            Ok(r) => r,
            Err(e) => {
                last_err = e.to_string();
                continue;
            }
        };
        if !resp.status().is_success() {
            last_err = format!("HTTP {}", resp.status().as_u16());
            continue;
        }
        let text = match resp.text().await {
            Ok(t) => t,
            Err(e) => {
                last_err = e.to_string();
                continue;
            }
        };
        let json: Value = match serde_json::from_str(&text) {
            Ok(v) => v,
            Err(e) => {
                last_err = e.to_string();
                continue;
            }
        };
        if let Some(errcode) = json.get("errcode").and_then(|e| e.as_i64()) {
            if errcode != 0 {
                last_err = format!("errcode {}", errcode);
                continue;
            }
        }
        let play_url = json
            .get("url")
            .and_then(|u| u.as_array())
            .and_then(|a| a.first())
            .and_then(|v| v.as_str())
            .filter(|s| s.starts_with("http"));
        match play_url {
            Some(u) => {
                return Ok(ResolvedAudio {
                    url: u.to_string(),
                    br: 0,
                    size: 0,
                    source: LABEL.to_string(),
                    source_label: LABEL.to_string(),
                    id: ctx.id,
                });
            }
            None => {
                last_err = "返回中无有效播放地址".into();
            }
        }
    }
    Err(SourceError::InvalidUrl(format!(
        "{} 换链失败：{}",
        LABEL,
        if last_err.is_empty() {
            "无可用 hash".to_string()
        } else {
            last_err
        }
    )))
}
