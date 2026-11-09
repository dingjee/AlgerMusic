// SPDX-License-Identifier: LGPL-3.0-only
// 移植自 @unblockneteasemusic/server v0.27.10 (Copyright (c) nondanee, 1715173329, pan93412)
// 详见 ../../THIRD_PARTY_LICENSES.md 与 licenses/LGPL-3.0-only.txt

//! 酷我音源（搜索接口 + `mobi.s` 换链，查询串使用改造版 DES 加密）。
//!
//! 算法对齐上游 `@unblockneteasemusic/server` 的 `src/provider/kuwo.js`。

use reqwest::Client;
use serde_json::Value;

use super::{select_by_duration, ResolvedAudio, SourceContext, SourceError};
use crate::cookie::encode_uri_component;
use crate::sources::kwdes;

const SEARCH_URL: &str = "http://search.kuwo.cn/r.s";
const TRACK_URL: &str = "http://mobi.kuwo.cn/mobi.s";
const LABEL: &str = "kuwo";

/// 解析酷我音源。
pub async fn resolve(http: &Client, ctx: &SourceContext) -> Result<ResolvedAudio, SourceError> {
    // 上游会把关键字里的 " - " 去掉后再搜索
    let keyword = ctx.keyword_unblock().replace(" - ", " ");
    if keyword.trim().is_empty() {
        return Err(SourceError::NoMatch(LABEL.into()));
    }
    let url = format!(
        "{}?&correct=1&stype=comprehensive&encoding=utf8&rformat=json&mobi=1&show_copyright_off=1&searchapi=6&all={}",
        SEARCH_URL,
        encode_uri_component(keyword.trim())
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
    let list = json
        .get("content")
        .and_then(|c| c.get(1))
        .and_then(|c| c.get("musicpage"))
        .and_then(|m| m.get("abslist"))
        .and_then(|a| a.as_array())
        .cloned()
        .unwrap_or_default();
    if list.is_empty() {
        return Err(SourceError::NoMatch(LABEL.into()));
    }

    let idx = select_by_duration(&list, ctx.duration_ms, |s| {
        s.get("DURATION").and_then(|d| d.as_i64()).map(|d| d * 1000)
    })
    .unwrap_or(0);
    let song = &list[idx];
    let music_rid = song
        .get("MUSICRID")
        .and_then(|r| r.as_str())
        .unwrap_or("")
        .to_string();
    if music_rid.is_empty() {
        return Err(SourceError::NoMatch(LABEL.into()));
    }
    let numeric_id = music_rid
        .rsplit('_')
        .next()
        .unwrap_or(&music_rid)
        .to_string();

    // 依次尝试两种 rid 形式，提高兼容性
    let mut last_err = String::new();
    for rid in [format!("MUSIC_{}", numeric_id), numeric_id.clone()] {
        let query = format!(
            "corp=kuwo&source=kwplayer_ar_5.1.0.0_B_jiakong_vh.apk&p2p=1&type=convert_url2&sig=0&format=mp3&rid={}",
            rid
        );
        let encrypted = kwdes::encrypt_query(&query);
        let url = format!("{}?f=kuwo&q={}", TRACK_URL, encrypted);
        let resp = match http
            .get(&url)
            .header("User-Agent", "okhttp/3.10.0")
            .send()
            .await
        {
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
        let body = match resp.text().await {
            Ok(t) => t,
            Err(e) => {
                last_err = e.to_string();
                continue;
            }
        };
        if let Some(u) = extract_first_url(&body) {
            return Ok(ResolvedAudio {
                url: u,
                br: 0,
                size: 0,
                source: LABEL.to_string(),
                source_label: LABEL.to_string(),
                id: ctx.id,
            });
        }
        last_err = format!(
            "响应中无有效地址：{}",
            body.chars().take(80).collect::<String>()
        );
    }
    Err(SourceError::InvalidUrl(format!(
        "{} 换链失败：{}",
        LABEL, last_err
    )))
}

/// 从响应文本中提取第一个 `http...` 链接（对齐上游正则 `/http[^\s$"]+/`）。
fn extract_first_url(body: &str) -> Option<String> {
    let bytes = body.as_bytes();
    let mut start = None;
    for (i, b) in bytes.iter().enumerate() {
        if *b == b'h' && body[i..].starts_with("http") {
            start = Some(i);
            break;
        }
    }
    let start = start?;
    let mut end = start;
    while end < bytes.len() {
        let c = bytes[end] as char;
        if c.is_whitespace() || c == '$' || c == '"' {
            break;
        }
        end += 1;
    }
    let url = &body[start..end];
    if url.starts_with("http://") || url.starts_with("https://") {
        Some(url.to_string())
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_url_from_text() {
        assert_eq!(
            extract_first_url("xxx http://mobi.kuwo.cn/x.mp3 yyy").as_deref(),
            Some("http://mobi.kuwo.cn/x.mp3")
        );
        assert_eq!(
            extract_first_url("{\"url\":\"http://a.b/c.mp3\"}").as_deref(),
            Some("http://a.b/c.mp3")
        );
        assert_eq!(extract_first_url("no url here"), None);
    }
}
