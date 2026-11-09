// SPDX-License-Identifier: LGPL-3.0-only
// 移植自 @unblockneteasemusic/server v0.27.10 (Copyright (c) nondanee, 1715173329, pan93412)
// 详见 ../../THIRD_PARTY_LICENSES.md 与 licenses/LGPL-3.0-only.txt

//! 咪咕音源（搜索接口 + `listen-url` 换链）。
//!
//! 算法对齐上游 `@unblockneteasemusic/server` 的 `src/provider/migu.js`。

use reqwest::Client;
use serde_json::Value;

use super::{name_matched, ResolvedAudio, SourceContext, SourceError};
use crate::cookie::encode_uri_component;

const SEARCH_URL: &str = "https://m.music.migu.cn/migu/remoting/scr_search_tag";
const TRACK_URL: &str = "https://app.c.nf.migu.cn/MIGUM2.0/strategy/listen-url/v2.4";
const LABEL: &str = "migu";

/// 音质档位（上游 ENABLE_FLAC 默认关闭，因此只用 HQ / PQ）。
const TONE_FLAGS: [&str; 2] = ["HQ", "PQ"];

/// 解析咪咕音源。
pub async fn resolve(http: &Client, ctx: &SourceContext) -> Result<ResolvedAudio, SourceError> {
    let keyword = ctx.keyword_unblock();
    if keyword.trim().is_empty() {
        return Err(SourceError::NoMatch(LABEL.into()));
    }
    let url = format!(
        "{}?keyword={}&type=2&rows=20&pgc=1",
        SEARCH_URL,
        encode_uri_component(&keyword)
    );
    let resp = http
        .get(&url)
        .header("Origin", "http://music.migu.cn/")
        .header("Referer", "http://m.music.migu.cn/v3/")
        .header("channel", "0146921")
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
    let musics = json
        .get("musics")
        .and_then(|m| m.as_array())
        .cloned()
        .unwrap_or_default();
    if musics.is_empty() {
        return Err(SourceError::NoMatch(LABEL.into()));
    }

    // 咪咕搜索结果不含时长，这里按标题 + 歌手做匹配，取第一个命中项
    let picked = musics.iter().find(|m| {
        let title = m.get("title").and_then(|t| t.as_str()).unwrap_or("");
        if !name_matched(&ctx.name, title) {
            return false;
        }
        if ctx.artists.is_empty() {
            return true;
        }
        let singer = m
            .get("singerName")
            .and_then(|s| s.as_str())
            .unwrap_or("")
            .to_lowercase();
        ctx.artists
            .iter()
            .any(|a| singer.contains(&a.to_lowercase()))
    });
    let item = match picked {
        Some(i) => i,
        None => {
            return Err(SourceError::NoMatch(format!(
                "{} 未匹配到歌曲（共 {} 条候选）",
                LABEL,
                musics.len()
            )))
        }
    };
    let song_id = item
        .get("id")
        .and_then(|i| i.as_str())
        .map(|s| s.to_string())
        .or_else(|| {
            item.get("id")
                .and_then(|i| i.as_i64())
                .map(|v| v.to_string())
        })
        .unwrap_or_default();
    if song_id.is_empty() {
        return Err(SourceError::NoMatch(LABEL.into()));
    }

    let mut last_err = String::new();
    for tone in TONE_FLAGS {
        let url = format!(
            "{}?netType=01&resourceType=2&songId={}&toneFlag={}",
            TRACK_URL,
            encode_uri_component(&song_id),
            tone
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
        let data = json.get("data").cloned().unwrap_or(Value::Null);
        let fmt = data.get("audioFormatType").and_then(|f| f.as_str());
        if let Some(f) = fmt {
            if !f.is_empty() && f != tone {
                // 上游要求返回的音质与请求一致
                last_err = format!("音质不匹配（{} != {}）", f, tone);
                continue;
            }
        }
        let play_url = data
            .get("url")
            .and_then(|u| u.as_str())
            .filter(|s| s.starts_with("http"));
        if let Some(u) = play_url {
            return Ok(ResolvedAudio {
                url: u.to_string(),
                br: 0,
                size: 0,
                source: LABEL.to_string(),
                source_label: LABEL.to_string(),
                id: ctx.id,
            });
        }
        last_err = format!(
            "未返回地址：{}",
            json.get("info")
                .and_then(|i| i.as_str())
                .unwrap_or("unknown")
        );
    }
    Err(SourceError::InvalidUrl(format!(
        "{} 换链失败：{}",
        LABEL, last_err
    )))
}
