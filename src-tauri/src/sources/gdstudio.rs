// SPDX-License-Identifier: LGPL-3.0-only AND MIT
// pyncmd 部分移植自 @unblockneteasemusic/server v0.27.10 (LGPL-3.0-only)
// gdmusic 部分移植自本仓库旧版 src/renderer/api/gdmusic.ts (MIT)
// 详见 ../../THIRD_PARTY_LICENSES.md

//! GD 音乐台（`music-api.gdstudio.xyz`）音源。
//!
//! - `pyncmd`：直接用网易云歌曲 ID 换链（对应上游 `@unblockneteasemusic` 的 pyncmd provider）
//! - `gdmusic`：多平台搜索 + 标题/歌手匹配后换链（对应旧版 `gdmusic.ts`）

use reqwest::Client;
use serde_json::Value;

use super::{name_matched, normalize_text, ResolvedAudio, SourceContext, SourceError};
use crate::cookie::encode_uri_component;

const BASE: &str = "https://music-api.gdstudio.xyz/api.php";

/// GD 音乐台支持的搜索源。
/// `tidal` 等源在实测中返回 400，这里只保留实测可用的平台。
const SEARCH_SOURCES: [&str; 2] = ["joox", "netease"];

/// 换链并整理成统一结果。
async fn fetch_url(
    http: &Client,
    source: &str,
    id: &str,
    br: u32,
    label: &str,
) -> Result<ResolvedAudio, SourceError> {
    let url = format!(
        "{}?types=url&source={}&id={}&br={}",
        BASE,
        source,
        encode_uri_component(id),
        br
    );
    let resp = http
        .get(&url)
        .send()
        .await
        .map_err(|e| SourceError::Request(label.to_string(), e.to_string()))?;
    let status = resp.status();
    let text = resp
        .text()
        .await
        .map_err(|e| SourceError::Request(label.to_string(), e.to_string()))?;
    if !status.is_success() {
        return Err(SourceError::Request(
            label.to_string(),
            format!("HTTP {}", status.as_u16()),
        ));
    }
    let json: Value = serde_json::from_str(&text)
        .map_err(|e| SourceError::Decode(format!("{}: {}", label, e)))?;
    let play_url = json
        .get("url")
        .and_then(|u| u.as_str())
        .map(|s| s.replace('\\', ""))
        .filter(|s| !s.is_empty());
    let play_url = match play_url {
        Some(u) => u,
        None => {
            let br = json.get("br").and_then(|b| b.as_i64()).unwrap_or(0);
            return Err(SourceError::InvalidUrl(format!(
                "{} 未返回可用地址（br={}）",
                label, br
            )));
        }
    };
    // `br` 字段单位为 kbps
    let br_kbps = json.get("br").and_then(|b| b.as_i64()).unwrap_or(0);
    let size = json.get("size").and_then(|s| s.as_i64()).unwrap_or(0);
    Ok(ResolvedAudio {
        url: play_url,
        br: if br_kbps > 0 { br_kbps * 1000 } else { 320_000 },
        size,
        source: label.to_string(),
        source_label: label.to_string(),
        id: 0,
    })
}

/// `pyncmd`：网易云 ID 直接换链。
pub async fn resolve_pyncmd(
    http: &Client,
    ctx: &SourceContext,
) -> Result<ResolvedAudio, SourceError> {
    let mut audio = fetch_url(http, "netease", &ctx.id.to_string(), 320, "pyncmd").await?;
    audio.id = ctx.id;
    Ok(audio)
}

/// `gdmusic`：多平台搜索 + 匹配后换链。
pub async fn resolve_gdmusic(
    http: &Client,
    ctx: &SourceContext,
) -> Result<ResolvedAudio, SourceError> {
    let keyword = ctx.keyword_gd();
    if keyword.len() < 2 {
        return Err(SourceError::NoMatch("gdmusic".into()));
    }
    let mut failures = Vec::new();
    for source in SEARCH_SOURCES {
        let url = format!(
            "{}?types=search&source={}&name={}&count=10&pages=1",
            BASE,
            source,
            encode_uri_component(&keyword)
        );
        let resp = match http.get(&url).send().await {
            Ok(r) => r,
            Err(e) => {
                failures.push(format!("{}: {}", source, e));
                continue;
            }
        };
        if !resp.status().is_success() {
            failures.push(format!("{}: HTTP {}", source, resp.status().as_u16()));
            continue;
        }
        let text = match resp.text().await {
            Ok(t) => t,
            Err(e) => {
                failures.push(format!("{}: {}", source, e));
                continue;
            }
        };
        let json: Value = match serde_json::from_str(&text) {
            Ok(v) => v,
            Err(e) => {
                failures.push(format!("{}: {}", source, e));
                continue;
            }
        };
        let items = match json.as_array() {
            Some(a) => a,
            None => {
                failures.push(format!("{}: 响应不是数组", source));
                continue;
            }
        };
        let matched = pick_best(items, ctx);
        let item = match matched {
            Some(i) => i,
            None => {
                failures.push(format!("{}: 未匹配到歌曲", source));
                continue;
            }
        };
        let id = item.get("id").and_then(|i| i.as_str()).unwrap_or("");
        if id.is_empty() {
            failures.push(format!("{}: 缺少 id", source));
            continue;
        }
        let track_source = item
            .get("source")
            .and_then(|s| s.as_str())
            .unwrap_or(source);
        match fetch_url(http, track_source, id, 999, "gdmusic").await {
            Ok(mut audio) => {
                audio.id = ctx.id;
                return Ok(audio);
            }
            Err(e) => failures.push(e.to_string()),
        }
    }
    Err(SourceError::NoMatch(format!(
        "gdmusic（{}）",
        failures.join("；")
    )))
}

/// 从搜索结果中挑出最佳匹配项。
///
/// 规则（对齐旧版 `gdmusic.ts`）：
/// 1. 标题必须匹配（归一化后相等或互相包含）
/// 2. 若原曲有歌手信息，候选歌手也必须匹配
fn pick_best<'a>(items: &'a [Value], ctx: &SourceContext) -> Option<&'a Value> {
    let mut best: Option<&Value> = None;
    let mut best_score = 0i32;
    for item in items {
        let name = item.get("name").and_then(|n| n.as_str()).unwrap_or("");
        if name.is_empty() || !name_matched(&ctx.name, name) {
            continue;
        }
        let candidate_artist = normalize_text(&artist_text(item));
        let score = if ctx.artists.is_empty() {
            2
        } else if candidate_artist.is_empty() {
            1
        } else {
            let matched = ctx.artists.iter().any(|a| {
                let n = normalize_text(a);
                !n.is_empty() && (candidate_artist.contains(&n) || n.contains(&candidate_artist))
            });
            if !matched {
                continue;
            }
            3
        };
        if score > best_score {
            best = Some(item);
            best_score = score;
        }
    }
    best
}

/// 提取候选歌曲的歌手文本。
fn artist_text(item: &Value) -> String {
    match item.get("artist") {
        Some(Value::Array(arr)) => arr
            .iter()
            .map(|v| match v {
                Value::String(s) => s.clone(),
                Value::Object(_) => v
                    .get("name")
                    .and_then(|n| n.as_str())
                    .unwrap_or("")
                    .to_string(),
                _ => String::new(),
            })
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>()
            .join(" "),
        Some(Value::String(s)) => s.clone(),
        _ => String::new(),
    }
}

/// 供测试使用：按时长挑选。
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn picks_exact_title_and_artist() {
        let items = vec![
            json!({"id": "1", "name": "七里香", "artist": ["周杰伦"]}),
            json!({"id": "2", "name": "晴天", "artist": ["周杰伦"]}),
        ];
        let ctx = SourceContext::new(1, "晴天", &["周杰伦".to_string()], "", 269_000);
        let picked = pick_best(&items, &ctx).unwrap();
        assert_eq!(picked.get("id").unwrap(), "2");
    }

    #[test]
    fn rejects_wrong_artist() {
        let items = vec![json!({"id": "3", "name": "晴天", "artist": ["林俊杰"]})];
        let ctx = SourceContext::new(1, "晴天", &["周杰伦".to_string()], "", 0);
        assert!(pick_best(&items, &ctx).is_none());
    }

    #[test]
    fn artist_text_handles_string_and_array() {
        assert_eq!(artist_text(&json!({"artist": ["A", "B"]})), "A B");
        assert_eq!(artist_text(&json!({"artist": "A B"})), "A B");
        assert_eq!(artist_text(&json!({})), "");
    }
}
