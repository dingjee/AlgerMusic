//! 网易云 Cookie 的解析、规范化与请求头构造。
//!
//! 行为对齐上游 `util/index.js` 与 `util/request.js`：
//! - `cookie_to_json`：按 **第一个** `=` 切分，保留值中的 `=`
//! - `cookie_obj_to_string`：`encodeURIComponent(key)=encodeURIComponent(value)`，以 `; ` 连接

use std::collections::BTreeMap;

use crate::crypto::{generate_device_id, random_hex};

/// 网易云客户端缺省参数（对应上游 `osMap.pc`）。
const OS_PC: (&str, &str, &str, &str) = (
    "pc",
    "3.1.17.204416",
    "Microsoft-Windows-10-Professional-build-19045-64bit",
    "netease",
);

/// 解析 `a=1; b=2` 形式的 Cookie 串。
pub fn cookie_to_json(raw: &str) -> BTreeMap<String, String> {
    let mut map = BTreeMap::new();
    for part in raw.split(';') {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }
        // 只按第一个等号拆分，值里的 `=` 保留
        if let Some((k, v)) = part.split_once('=') {
            let key = k.trim();
            if key.is_empty() {
                continue;
            }
            map.insert(key.to_string(), v.trim().to_string());
        }
    }
    map
}

/// 把 Cookie 字典序列化为请求头用的字符串。
pub fn cookie_obj_to_string(cookie: &BTreeMap<String, String>) -> String {
    cookie
        .iter()
        .map(|(k, v)| format!("{}={}", encode_uri_component(k), encode_uri_component(v)))
        .collect::<Vec<_>>()
        .join("; ")
}

/// JavaScript `encodeURIComponent` 的等价实现。
///
/// 未编码字符：`A-Z a-z 0-9 - _ . ! ~ * ' ( )`
pub fn encode_uri_component(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for b in input.as_bytes() {
        let c = *b as char;
        if c.is_ascii_alphanumeric()
            || matches!(c, '-' | '_' | '.' | '!' | '~' | '*' | '\'' | '(' | ')')
        {
            out.push(c);
        } else {
            out.push_str(&format!("%{:02X}", b));
        }
    }
    out
}

/// 已规范化的会话 Cookie。
#[derive(Debug, Clone, Default)]
pub struct SessionCookie {
    /// 原始 Cookie 串（由用户粘贴或从登录窗口采集）。
    pub raw: String,
    /// 解析后的键值对。
    pub fields: BTreeMap<String, String>,
}

impl SessionCookie {
    /// 从原始 Cookie 串构造。
    pub fn parse(raw: &str) -> Self {
        Self {
            raw: raw.trim().to_string(),
            fields: cookie_to_json(raw),
        }
    }

    /// 是否携带登录标识 `MUSIC_U`。
    pub fn has_music_u(&self) -> bool {
        self.fields
            .get("MUSIC_U")
            .map(|v| !v.is_empty())
            .unwrap_or(false)
    }

    /// `__csrf` 值。
    pub fn csrf(&self) -> &str {
        self.fields.get("__csrf").map(|s| s.as_str()).unwrap_or("")
    }

    /// 用户 ID（若 Cookie 中带有）。
    pub fn uid(&self) -> Option<String> {
        self.fields
            .get("uid")
            .or_else(|| self.fields.get("userId"))
            .cloned()
    }

    /// 构造 weapi 请求所需的完整 Cookie 头（对应上游 `processCookieObject`）。
    pub fn processed_cookie(&self) -> BTreeMap<String, String> {
        let mut cookie = self.fields.clone();
        let nuid = random_hex(16);
        cookie.insert("__remember_me".into(), "true".into());
        cookie.insert("ntes_kaola_ad".into(), "1".into());
        cookie
            .entry("_ntes_nuid".into())
            .or_insert_with(|| nuid.clone());
        cookie
            .entry("_ntes_nnid".into())
            .or_insert_with(|| format!("{},{}", nuid, crate::now_millis()));
        cookie
            .entry("WNMCID".into())
            .or_insert_with(|| format!("{}.{}.01.0", random_hex(3), crate::now_millis()));
        cookie
            .entry("WEVNSM".into())
            .or_insert_with(|| "1.0.0".into());
        cookie
            .entry("osver".into())
            .or_insert_with(|| OS_PC.2.to_string());
        cookie
            .entry("deviceId".into())
            .or_insert_with(generate_device_id);
        cookie
            .entry("os".into())
            .or_insert_with(|| OS_PC.0.to_string());
        cookie
            .entry("channel".into())
            .or_insert_with(|| OS_PC.3.to_string());
        cookie
            .entry("appver".into())
            .or_insert_with(|| OS_PC.1.to_string());
        cookie.entry("NMTID".into()).or_insert_with(|| {
            format!("00O{}", random_hex(19).chars().take(19).collect::<String>())
        });
        cookie
    }

    /// 构造 eapi 请求头里的 `header` 对象（对应上游 eapi 分支）。
    pub fn eapi_header(&self) -> BTreeMap<String, String> {
        let processed = self.processed_cookie();
        let mut header = BTreeMap::new();
        header.insert(
            "osver".into(),
            processed.get("osver").cloned().unwrap_or_default(),
        );
        header.insert(
            "deviceId".into(),
            processed.get("deviceId").cloned().unwrap_or_default(),
        );
        header.insert(
            "os".into(),
            processed.get("os").cloned().unwrap_or_default(),
        );
        header.insert(
            "appver".into(),
            processed.get("appver").cloned().unwrap_or_default(),
        );
        header.insert("versioncode".into(), "140".into());
        header.insert("mobilename".into(), String::new());
        header.insert("buildver".into(), crate::today_compact());
        header.insert("resolution".into(), "1920x1080".into());
        header.insert("__csrf".into(), self.csrf().to_string());
        header.insert(
            "channel".into(),
            processed.get("channel").cloned().unwrap_or_default(),
        );
        header.insert("requestId".into(), crate::generate_request_id());
        if let Some(v) = processed.get("MUSIC_U").filter(|v| !v.is_empty()) {
            header.insert("MUSIC_U".into(), v.clone());
        }
        if let Some(v) = processed.get("NMTID").filter(|v| !v.is_empty()) {
            header.insert("NMTID".into(), v.clone());
        }
        header
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_keeps_equals_in_value() {
        let c = cookie_to_json("MUSIC_U=abc%2Fdef==; __csrf=1234; ; x=");
        assert_eq!(c.get("MUSIC_U").unwrap(), "abc%2Fdef==");
        assert_eq!(c.get("__csrf").unwrap(), "1234");
        assert_eq!(c.get("x").unwrap(), "");
    }

    #[test]
    fn encode_uri_component_matches_js() {
        assert_eq!(encode_uri_component("a b"), "a%20b");
        assert_eq!(encode_uri_component("A-Z_a.z!~*'()"), "A-Z_a.z!~*'()");
        assert_eq!(encode_uri_component("%2F"), "%252F");
        assert_eq!(encode_uri_component("中文"), "%E4%B8%AD%E6%96%87");
    }

    #[test]
    fn processed_cookie_has_defaults() {
        let c = SessionCookie::parse("MUSIC_U=xyz");
        let p = c.processed_cookie();
        assert_eq!(p.get("__remember_me").unwrap(), "true");
        assert_eq!(p.get("os").unwrap(), "pc");
        assert!(p.get("deviceId").unwrap().len() >= 32);
        assert!(p.contains_key("NMTID"));
        assert!(c.has_music_u());
    }

    #[test]
    fn eapi_header_contains_session() {
        let c = SessionCookie::parse("MUSIC_U=xyz; __csrf=tok");
        let h = c.eapi_header();
        assert_eq!(h.get("MUSIC_U").unwrap(), "xyz");
        assert_eq!(h.get("__csrf").unwrap(), "tok");
        assert_eq!(h.get("versioncode").unwrap(), "140");
        assert!(h.get("requestId").unwrap().contains('_'));
    }
}
