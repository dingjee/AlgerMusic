//! 第三方音源解析。
//!
//! 全部为原生 Rust 实现，不依赖任何外部 Node 服务：
//! - `pyncmd`：GD 音乐台的网易云直连转码（网易云歌曲 ID 直接换链）
//! - `gdmusic`：GD 音乐台多平台搜索 + 匹配 + 换链
//! - `kugou`  ：酷狗移动端搜索 + `trackercdn` 换链
//! - `kuwo`   ：酷我搜索 + `mobi.s` 换链（改造版 DES）
//! - `migu`   ：咪咕搜索 + `listen-url` 换链

pub mod gdstudio;
pub mod kugou;
pub mod kuwo;
pub mod kwdes;
pub mod migu;
pub mod probe;

use serde::{Deserialize, Serialize};

/// 可选的第三方音源。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SourceKind {
    /// GD 音乐台（多平台搜索）。
    GdMusic,
    /// GD 音乐台网易云直连转码。
    Pyncmd,
    /// 酷狗。
    Kugou,
    /// 酷我。
    Kuwo,
    /// 咪咕。
    Migu,
}

impl SourceKind {
    /// 音源标识（用于前端展示与结果回传）。
    pub fn as_str(&self) -> &'static str {
        match self {
            SourceKind::GdMusic => "gdmusic",
            SourceKind::Pyncmd => "pyncmd",
            SourceKind::Kugou => "kugou",
            SourceKind::Kuwo => "kuwo",
            SourceKind::Migu => "migu",
        }
    }

    /// 解析音源标识。
    pub fn parse(s: &str) -> Option<SourceKind> {
        match s.trim().to_ascii_lowercase().as_str() {
            "gdmusic" | "gd" => Some(SourceKind::GdMusic),
            "pyncmd" | "py" => Some(SourceKind::Pyncmd),
            "kugou" | "kg" => Some(SourceKind::Kugou),
            "kuwo" | "kw" => Some(SourceKind::Kuwo),
            "migu" | "mg" => Some(SourceKind::Migu),
            _ => None,
        }
    }

    /// 全部可用音源。
    pub fn all() -> Vec<SourceKind> {
        vec![
            SourceKind::Pyncmd,
            SourceKind::GdMusic,
            SourceKind::Kugou,
            SourceKind::Kuwo,
            SourceKind::Migu,
        ]
    }

    /// 音源中文名。
    pub fn label(&self) -> &'static str {
        match self {
            SourceKind::GdMusic => "GD 音乐台",
            SourceKind::Pyncmd => "GD 音乐台(网易云)",
            SourceKind::Kugou => "酷狗",
            SourceKind::Kuwo => "酷我",
            SourceKind::Migu => "咪咕",
        }
    }
}

/// 参与匹配的歌曲信息。
#[derive(Debug, Clone, Default)]
pub struct SourceContext {
    /// 网易云歌曲 ID。
    pub id: i64,
    pub name: String,
    pub artists: Vec<String>,
    pub album: String,
    /// 时长（毫秒）。
    pub duration_ms: i64,
}

impl SourceContext {
    /// 构造匹配上下文。
    pub fn new(id: i64, name: &str, artists: &[String], album: &str, duration_ms: i64) -> Self {
        SourceContext {
            id,
            name: name.to_string(),
            artists: artists.to_vec(),
            album: album.to_string(),
            duration_ms,
        }
    }

    /// 上游 `@unblockneteasemusic` 的搜索关键字：`歌曲名 - 歌手1 / 歌手2`。
    pub fn keyword_unblock(&self) -> String {
        let limit = |tokens: &[String]| -> String {
            let mut out: Vec<String> = Vec::new();
            if let Some(first) = tokens.first() {
                out.push(first.clone());
            }
            let mut len: usize = out.iter().map(|t| t.chars().count()).sum();
            for t in tokens.iter().skip(1) {
                if len > 15 {
                    break;
                }
                out.push(t.clone());
                len += t.chars().count();
            }
            out.join(" / ")
        };
        format!(
            "{} - {}",
            strip_cover_annotations(&self.name).trim(),
            limit(&self.artists)
        )
    }

    /// GD 音乐台的搜索关键字：`歌曲名 歌手1 歌手2`。
    pub fn keyword_gd(&self) -> String {
        format!("{} {}", self.name.trim(), self.artists.join(" "))
            .trim()
            .to_string()
    }
}

/// 解析出的播放地址。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResolvedAudio {
    pub url: String,
    /// 码率（bps）。
    pub br: i64,
    /// 文件大小（字节）。
    pub size: i64,
    /// 命中的音源标识。
    pub source: String,
    /// 音源中文名。
    pub source_label: String,
    /// 歌曲 ID。
    pub id: i64,
}

/// 音源解析失败原因。
#[derive(Debug, Clone, thiserror::Error)]
pub enum SourceError {
    #[error("音源 {0} 请求失败：{1}")]
    Request(String, String),
    #[error("音源 {0} 未匹配到歌曲")]
    NoMatch(String),
    #[error("音源 {0} 返回了无效的播放地址")]
    InvalidUrl(String),
    #[error("音源 {0} 返回格式无法解析")]
    Decode(String),
    #[error("音源 {0} 返回格式无法解析：{1}")]
    DecodeWithDetail(String, String),
    #[error("所有已启用的音源都解析失败")]
    AllFailed,
}

/// 单个音源的超时时间。
pub const SOURCE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(12);
/// 整体解析的超时时间。
pub const RESOLVE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

impl SourceError {
    /// 为「返回格式无法解析」补充底层原因，便于排查。
    pub fn with_detail(self, detail: impl std::fmt::Display) -> SourceError {
        match self {
            SourceError::Decode(msg) => SourceError::DecodeWithDetail(msg, detail.to_string()),
            other => other,
        }
    }
}

/// 解析器：持有 HTTP 客户端，按用户启用的音源顺序做回退。
pub struct Resolver {
    http: reqwest::Client,
    /// 前端上报的「本机无法播放」格式集合，见 `set_unsupported_formats`。
    unsupported_exts: parking_lot::Mutex<std::collections::HashSet<String>>,
}

impl Resolver {
    /// 创建解析器。
    pub fn new() -> Self {
        let http = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(15))
            .connect_timeout(std::time::Duration::from_secs(8))
            .user_agent(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36",
            )
            .build()
            .expect("build source http client");
        Self {
            http,
            unsupported_exts: parking_lot::Mutex::new(std::collections::HashSet::new()),
        }
    }

    /// 更新前端上报的「本机无法播放」格式集合（小写）。
    ///
    /// iOS 的格式支持随 WebKit 版本变化（例如 Safari / WebKit 18.4 起
    /// 已支持 Ogg 容器的 Opus / Vorbis），因此 **不** 在后端硬编码
    /// 平台支持表；由前端用 `audio.canPlayType` 实测当前 WebView 的
    /// 能力后上报，解析链据此把「探测通过但本机放不了」的候选视为
    /// 不可用并回退下一个音源。
    ///
    /// 空集合表示「未上报 / 全部支持」——此时不做格式过滤，让播放错误
    /// 自然暴露，避免误拦截本机其实支持的格式。
    pub fn set_unsupported_formats(&self, exts: Vec<String>) {
        let set: std::collections::HashSet<String> = exts
            .into_iter()
            .map(|e| e.trim().to_ascii_lowercase())
            .filter(|e| !e.is_empty())
            .collect();
        *self.unsupported_exts.lock() = set;
    }

    /// 该格式是否被前端判定为无法播放。
    pub fn rejects_format(&self, extension: &str) -> bool {
        if extension.is_empty() {
            return false;
        }
        self.unsupported_exts
            .lock()
            .contains(extension.to_ascii_lowercase().as_str())
    }

    /// 依次回退解析，返回第一个成功的结果。
    ///
    /// 每个音源得到的地址都会先做一次 **可用性探测**：
    /// 探测失败的坏链不会阻断后续音源，而是记录原因后继续尝试下一个。
    /// 失败时返回每个音源的具体原因，便于前端展示“不可用”提示。
    ///
    /// 探测通过但命中「前端上报的本机不支持格式」的候选同样视为
    /// 不可用并继续回退（见 `set_unsupported_formats`）。
    pub async fn resolve(
        &self,
        ctx: &SourceContext,
        kinds: &[SourceKind],
    ) -> Result<ResolvedAudio, Vec<(SourceKind, SourceError)>> {
        if kinds.is_empty() {
            return Err(Vec::new());
        }
        let mut failures = Vec::new();
        for kind in kinds {
            // 单个音源超时保护：某个源卡住不影响后续回退
            let audio =
                match tokio::time::timeout(SOURCE_TIMEOUT, self.resolve_one(*kind, ctx)).await {
                    Ok(Ok(a)) => a,
                    Ok(Err(e)) => {
                        failures.push((*kind, e));
                        continue;
                    }
                    Err(_) => {
                        failures.push((
                            *kind,
                            SourceError::Request(
                                kind.label().to_string(),
                                format!("解析超时（{}s）", SOURCE_TIMEOUT.as_secs()),
                            ),
                        ));
                        continue;
                    }
                };
            // 探测地址可用性（同样受超时保护）
            let probed = tokio::time::timeout(SOURCE_TIMEOUT, self.probe_best(&audio.url)).await;
            match probed {
                Ok(Ok((url, br, size, ext))) => {
                    if self.rejects_format(&ext) {
                        failures.push((
                            *kind,
                            SourceError::InvalidUrl(format!(
                                "{} 返回的 {} 格式本机无法播放，已尝试下一个音源",
                                audio.source_label, ext
                            )),
                        ));
                        continue;
                    }
                    return Ok(ResolvedAudio {
                        url,
                        br: if br > 0 { br } else { audio.br },
                        size: if size > 0 { size } else { audio.size },
                        source: audio.source,
                        source_label: audio.source_label,
                        id: audio.id,
                    });
                }
                Ok(Err(e)) => {
                    failures.push((
                        *kind,
                        SourceError::InvalidUrl(format!(
                            "{} 地址不可用：{}",
                            audio.source_label, e
                        )),
                    ));
                }
                Err(_) => {
                    failures.push((
                        *kind,
                        SourceError::InvalidUrl(format!("{} 地址探测超时", audio.source_label)),
                    ));
                }
            }
        }
        Err(failures)
    }

    /// 解析单个音源（不做探测），带整体超时保护。
    pub async fn resolve_within(
        &self,
        kind: SourceKind,
        ctx: &SourceContext,
    ) -> Result<ResolvedAudio, SourceError> {
        match tokio::time::timeout(RESOLVE_TIMEOUT, self.resolve_one(kind, ctx)).await {
            Ok(r) => r,
            Err(_) => Err(SourceError::Request(
                kind.label().to_string(),
                format!("解析超时（{}s）", RESOLVE_TIMEOUT.as_secs()),
            )),
        }
    }

    /// 解析单个音源（不做探测）。
    pub async fn resolve_one(
        &self,
        kind: SourceKind,
        ctx: &SourceContext,
    ) -> Result<ResolvedAudio, SourceError> {
        match kind {
            SourceKind::Pyncmd => gdstudio::resolve_pyncmd(&self.http, ctx).await,
            SourceKind::GdMusic => gdstudio::resolve_gdmusic(&self.http, ctx).await,
            SourceKind::Kugou => kugou::resolve(&self.http, ctx).await,
            SourceKind::Kuwo => kuwo::resolve(&self.http, ctx).await,
            SourceKind::Migu => migu::resolve(&self.http, ctx).await,
        }
    }

    /// 探测播放地址，返回第一个可用候选的（URL, 码率, 大小, 格式）。
    ///
    /// macOS 的 ATS 会拦截明文 HTTP，因此优先尝试 HTTPS。
    /// 格式（扩展名）按 Content-Type / URL / 字节特征判定，未知时为空串；
    /// iOS 端用它过滤 WKWebView 不支持的格式。
    pub async fn probe_best(&self, url: &str) -> Result<(String, i64, i64, String), String> {
        let mut candidates: Vec<String> = Vec::new();
        if let Some(rest) = url.strip_prefix("http://") {
            candidates.push(format!("https://{}", rest));
            candidates.push(url.to_string());
        } else {
            candidates.push(url.to_string());
        }
        let mut last_err = String::new();
        for candidate in &candidates {
            match self.probe(candidate).await {
                Ok((br, size, ext)) => return Ok((candidate.clone(), br, size, ext)),
                Err(e) => last_err = e,
            }
        }
        Err(if last_err.is_empty() {
            "地址不可用".to_string()
        } else {
            last_err
        })
    }

    /// 探测播放地址是否可用（Range 请求 + 码率识别）。
    ///
    /// 只读取前 8 KiB，并拒绝 HTML / JSON 等伪音频响应。
    /// 返回（码率 bps, 大小字节, 格式扩展名）；
    /// 格式按字节特征 → Content-Type → URL 后缀依次判定，未知时为空串。
    pub async fn probe(&self, url: &str) -> Result<(i64, i64, String), String> {
        use futures_util::StreamExt;

        let resp = self
            .http
            .get(url)
            .header("Range", "bytes=0-8191")
            .header("Accept-Encoding", "identity")
            .send()
            .await
            .map_err(|e| e.to_string())?;
        let status = resp.status();
        if !status.is_success() {
            return Err(format!("HTTP {}", status.as_u16()));
        }
        let content_type = resp
            .headers()
            .get("content-type")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
            .to_ascii_lowercase();
        if is_not_audio_content_type(&content_type) {
            return Err(format!("返回的不是音频（{}）", content_type));
        }
        let content_length = resp
            .headers()
            .get("content-length")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.parse::<i64>().ok());
        let content_range = resp
            .headers()
            .get("content-range")
            .and_then(|v| v.to_str().ok())
            .map(|s| s.to_string());

        // 只读取有限字节，避免大文件被整体拉取
        let mut stream = resp.bytes_stream();
        let mut buf: Vec<u8> = Vec::with_capacity(8192);
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.map_err(|e| e.to_string())?;
            buf.extend_from_slice(&chunk);
            if buf.len() >= 8192 {
                break;
            }
        }
        if buf.is_empty() {
            return Err("响应为空".to_string());
        }
        if looks_like_document(&buf) {
            return Err("返回的是网页/JSON 而非音频".to_string());
        }

        let br = probe::detect_bitrate_bps(&buf).unwrap_or(0);
        let size = content_range
            .as_deref()
            .and_then(|r| r.rsplit('/').next())
            .and_then(|s| s.parse::<i64>().ok())
            .or(content_length)
            .unwrap_or(0);
        // 格式判定：优先字节特征（最可靠），其次 Content-Type，最后 URL 后缀
        let ext = crate::download::detect_extension(&buf)
            .map(str::to_string)
            .unwrap_or_else(|| crate::download::guess_extension(&content_type, url));
        Ok((br, size, ext))
    }
}

/// 判断 Content-Type 是否明显不是音频。
pub fn is_not_audio_content_type(content_type: &str) -> bool {
    if content_type.is_empty() {
        return false;
    }
    let ct = content_type.trim();
    ct.starts_with("text/html")
        || ct.starts_with("application/json")
        || ct.starts_with("text/plain")
        || ct.starts_with("application/xml")
        || ct.starts_with("text/xml")
}

/// 根据内容判断是否为网页 / JSON 文档（而非音频）。
pub fn looks_like_document(data: &[u8]) -> bool {
    let head: Vec<u8> = data
        .iter()
        .copied()
        .filter(|b| !b.is_ascii_whitespace())
        .take(16)
        .collect();
    if head.is_empty() {
        return false;
    }
    if head[0] == b'<' {
        return true; // HTML / XML
    }
    if head[0] == b'{' || head[0] == b'[' {
        return true; // JSON
    }
    false
}

impl Default for Resolver {
    fn default() -> Self {
        Self::new()
    }
}

/// 移除歌曲名中的 `（cover: …）` / `(cover: …)` / `（翻自: …）` 注释。
///
/// 对齐上游 `find.js` 中的四条 `replace` 规则。
pub fn strip_cover_annotations(name: &str) -> String {
    const MARKERS: [&str; 4] = ["cover:", "cover：", "翻自:", "翻自："];
    let mut out = String::with_capacity(name.len());
    let chars: Vec<char> = name.chars().collect();
    let mut i = 0usize;
    while i < chars.len() {
        let c = chars[i];
        let close = match c {
            '（' => Some('）'),
            '(' => Some(')'),
            _ => None,
        };
        if let Some(close_char) = close {
            if let Some(end) = chars[i + 1..].iter().position(|x| *x == close_char) {
                let inner: String = chars[i + 1..i + 1 + end].iter().collect();
                let lowered = inner.trim_start().to_lowercase();
                if MARKERS.iter().any(|m| lowered.starts_with(m)) {
                    // 跳过整段注释
                    i = i + end + 2;
                    continue;
                }
            }
        }
        out.push(c);
        i += 1;
    }
    out
}

/// 文本归一化：去掉括号注释、空白与标点，转小写。
pub fn normalize_text(text: &str) -> String {
    let lower = text.to_lowercase();
    let mut out = String::with_capacity(lower.len());
    let mut depth = 0usize;
    for ch in lower.chars() {
        match ch {
            '（' | '(' | '【' | '[' => depth += 1,
            '）' | ')' | '】' | ']' => {
                depth = depth.saturating_sub(1);
            }
            _ if depth == 0 => out.push(ch),
            _ => {}
        }
    }
    let stripped: String = out
        .chars()
        .filter(|c| {
            !c.is_whitespace()
                && !matches!(
                    c,
                    '-' | '—'
                        | '_'
                        | '·'
                        | '・'
                        | '\''
                        | '’'
                        | '"'
                        | '“'
                        | '”'
                        | '!'
                        | '！'
                        | '?'
                        | '？'
                        | '.'
                        | ','
                        | '，'
                        | '。'
                        | '&'
                        | '＆'
                        | '+'
                )
        })
        .collect();
    if stripped.is_empty() {
        lower
            .chars()
            .filter(|c| {
                !c.is_whitespace()
                    && !matches!(
                        c,
                        '-' | '—'
                            | '_'
                            | '·'
                            | '・'
                            | '\''
                            | '’'
                            | '"'
                            | '“'
                            | '”'
                            | '!'
                            | '！'
                            | '?'
                            | '？'
                            | '.'
                            | ','
                            | '，'
                            | '。'
                            | '&'
                            | '＆'
                            | '+'
                    )
            })
            .collect()
    } else {
        stripped
    }
}

/// 标题匹配：相等或互相包含。
pub fn name_matched(expected: &str, candidate: &str) -> bool {
    let e = normalize_text(expected);
    let c = normalize_text(candidate);
    if e.is_empty() || c.is_empty() {
        return false;
    }
    e == c || c.contains(&e) || e.contains(&c)
}

/// 时长匹配：在候选列表的前 5 个里找时长差小于 5 秒的，否则取第一个。
pub fn select_by_duration<T, F>(list: &[T], duration_ms: i64, get_duration: F) -> Option<usize>
where
    F: Fn(&T) -> Option<i64>,
{
    if list.is_empty() {
        return None;
    }
    for (i, item) in list.iter().take(5).enumerate() {
        if let Some(d) = get_duration(item) {
            if (d - duration_ms).abs() < 5_000 {
                return Some(i);
            }
        }
    }
    Some(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_strips_annotations() {
        assert_eq!(normalize_text("晴天 (Live)"), "晴天");
        assert_eq!(normalize_text("【高音质】晴天"), "晴天");
        assert_eq!(normalize_text("Hello-World"), "helloworld");
    }

    #[test]
    fn name_match_handles_containment() {
        assert!(name_matched("晴天", "晴天"));
        assert!(name_matched("晴天", "晴天 (Live版)"));
        assert!(!name_matched("晴天", "七里香"));
    }

    #[test]
    fn keyword_formats() {
        let ctx = SourceContext::new(
            1,
            "晴天",
            &["周杰伦".to_string(), "费玉清".to_string()],
            "叶惠美",
            269_000,
        );
        assert_eq!(ctx.keyword_unblock(), "晴天 - 周杰伦 / 费玉清");
        assert_eq!(ctx.keyword_gd(), "晴天 周杰伦 费玉清");
    }

    #[test]
    fn cover_annotations_are_stripped() {
        assert_eq!(strip_cover_annotations("晴天（cover: 周杰伦）"), "晴天");
        // 与上游 `replace` 行为一致：仅移除括号段，前面的空格保留
        assert_eq!(strip_cover_annotations("晴天 (cover: 周杰伦)"), "晴天 ");
        assert_eq!(strip_cover_annotations("晴天（翻自: 费玉清）"), "晴天");
        assert_eq!(strip_cover_annotations("晴天"), "晴天");
        assert_eq!(strip_cover_annotations("晴天（Live）"), "晴天（Live）");
    }

    #[test]
    fn select_by_duration_prefers_close_match() {
        let items = vec![1000i64, 269_000, 500_000];
        let idx = select_by_duration(&items, 270_000, |x| Some(*x));
        assert_eq!(idx, Some(1));
    }

    #[test]
    fn select_by_duration_falls_back_to_first() {
        let items = vec![1000i64, 2000, 3000];
        let idx = select_by_duration(&items, 269_000, |x| Some(*x));
        assert_eq!(idx, Some(0));
    }

    #[test]
    fn source_kind_roundtrip() {
        for k in SourceKind::all() {
            assert_eq!(SourceKind::parse(k.as_str()), Some(k));
        }
        assert_eq!(SourceKind::parse("unknown"), None);
    }
}
