// SPDX-License-Identifier: MIT
// 移植自 NeteaseCloudMusicApi (Copyright (c) 2013-2022 Binaryify) 及其增强分支 neteasecloudmusicapienhanced/api-enhanced
// 详见 ../../THIRD_PARTY_LICENSES.md

//! 网易云接口请求层：负责 weapi / eapi 加密、Cookie 组装与错误归一化。

use std::sync::Arc;

use parking_lot::RwLock;
use serde_json::{json, Value};

use crate::cookie::{cookie_obj_to_string, SessionCookie};
use crate::crypto::{eapi_encrypt, weapi_encrypt};

/// 网易云 Web 域名（weapi）。
pub const DOMAIN: &str = "https://music.163.com";
/// 网易云 EAPI 域名。
pub const EAPI_DOMAIN: &str = "https://interface.music.163.com";
/// EAPI 备用域名（上游新版配置）。
pub const EAPI_DOMAIN_PC: &str = "https://interfacepc.music.163.com";

const UA_WEAPI: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 Edg/124.0.0.0";
const UA_EAPI: &str = "NeteaseMusic 9.0.90/5038 (iPhone; iOS 16.2; zh_CN)";

/// 接口调用错误。
#[derive(Debug, thiserror::Error)]
pub enum ApiError {
    /// 需要登录（上游返回 301）。
    #[error("需要登录，请重新登录后再试")]
    NeedLogin,
    /// 业务错误。
    #[error("{0}")]
    Business(String),
    /// 网络 / 协议错误。
    #[error("网络请求失败：{0}")]
    Network(String),
    /// 数据解析失败。
    #[error("响应解析失败：{0}")]
    Decode(String),
    /// 未配置登录 Cookie。
    #[error("尚未登录，请先登录网易云账号")]
    NotLoggedIn,
}

/// 网易云接口客户端。
pub struct NeteaseClient {
    http: reqwest::Client,
    cookie: RwLock<Option<Arc<SessionCookie>>>,
}

impl NeteaseClient {
    /// 创建客户端。
    pub fn new() -> Self {
        let http = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(20))
            .connect_timeout(std::time::Duration::from_secs(10))
            .user_agent(UA_WEAPI)
            .build()
            .expect("build reqwest client");
        Self {
            http,
            cookie: RwLock::new(None),
        }
    }

    /// 设置登录 Cookie。
    pub fn set_cookie(&self, raw: &str) {
        let trimmed = raw.trim();
        if trimmed.is_empty() {
            self.cookie.write().take();
        } else {
            self.cookie
                .write()
                .replace(Arc::new(SessionCookie::parse(trimmed)));
        }
    }

    /// 清除登录 Cookie。
    pub fn clear_cookie(&self) {
        self.cookie.write().take();
    }

    /// 当前是否已登录。
    pub fn is_logged_in(&self) -> bool {
        self.cookie
            .read()
            .as_ref()
            .map(|c| c.has_music_u())
            .unwrap_or(false)
    }

    /// 当前 Cookie 原文（仅用于显示是否已设置，不回传凭证给前端）。
    pub fn has_cookie(&self) -> bool {
        self.cookie.read().is_some()
    }

    fn current_cookie(&self) -> Result<Arc<SessionCookie>, ApiError> {
        self.cookie.read().clone().ok_or(ApiError::NotLoggedIn)
    }

    /// weapi 请求（`https://music.163.com/weapi/...`）。
    pub async fn weapi(&self, uri: &str, data: Value) -> Result<Value, ApiError> {
        let cookie = self
            .current_cookie()
            .unwrap_or_else(|_| SessionCookie::parse("").into());
        let mut payload = data;
        if let Some(obj) = payload.as_object_mut() {
            obj.insert("csrf_token".into(), json!(cookie.csrf()));
        }
        let enc = weapi_encrypt(&payload);
        let cookie_header = cookie_obj_to_string(&cookie.processed_cookie());
        let url = format!("{}/weapi/{}", DOMAIN, &uri[5..]);
        self.post_form(
            &url,
            &[("params", &enc.params), ("encSecKey", &enc.enc_sec_key)],
            &cookie_header,
            UA_WEAPI,
            Some(DOMAIN),
        )
        .await
    }

    /// eapi 请求（`https://interface.music.163.com/eapi/...`）。
    pub async fn eapi(&self, uri: &str, data: Value) -> Result<Value, ApiError> {
        let cookie = self
            .current_cookie()
            .unwrap_or_else(|_| SessionCookie::parse("").into());
        let header = cookie.eapi_header();
        let cookie_header = cookie_obj_to_string(&header);
        let mut payload = data;
        if let Some(obj) = payload.as_object_mut() {
            obj.insert(
                "header".into(),
                serde_json::to_value(&header).unwrap_or(Value::Null),
            );
        }
        let params = eapi_encrypt(uri, &payload);
        let url = format!("{}/eapi/{}", EAPI_DOMAIN, &uri[5..]);
        self.post_form(&url, &[("params", &params)], &cookie_header, UA_EAPI, None)
            .await
    }

    /// eapi 请求，失败时自动切换到备用域名重试一次。
    pub async fn eapi_with_fallback(&self, uri: &str, data: Value) -> Result<Value, ApiError> {
        match self.eapi(uri, data.clone()).await {
            Ok(v) => Ok(v),
            Err(first) => {
                let cookie = self
                    .current_cookie()
                    .unwrap_or_else(|_| SessionCookie::parse("").into());
                let header = cookie.eapi_header();
                let cookie_header = cookie_obj_to_string(&header);
                let mut payload = data;
                if let Some(obj) = payload.as_object_mut() {
                    obj.insert(
                        "header".into(),
                        serde_json::to_value(&header).unwrap_or(Value::Null),
                    );
                }
                let params = crate::crypto::eapi_encrypt(uri, &payload);
                let url = format!("{}/eapi/{}", EAPI_DOMAIN_PC, &uri[5..]);
                match self
                    .post_form(&url, &[("params", &params)], &cookie_header, UA_EAPI, None)
                    .await
                {
                    Ok(v) => Ok(v),
                    Err(_) => Err(first),
                }
            }
        }
    }

    async fn post_form(
        &self,
        url: &str,
        form: &[(&str, &str)],
        cookie_header: &str,
        ua: &str,
        referer: Option<&str>,
    ) -> Result<Value, ApiError> {
        let mut req = self
            .http
            .post(url)
            .header("Cookie", cookie_header)
            .header("User-Agent", ua);
        if let Some(r) = referer {
            req = req.header("Referer", r);
        }
        let resp = req
            .form(form)
            .send()
            .await
            .map_err(|e| ApiError::Network(e.to_string()))?;
        let status = resp.status();
        let text = resp
            .text()
            .await
            .map_err(|e| ApiError::Network(e.to_string()))?;
        if !status.is_success() {
            return Err(ApiError::Network(format!("HTTP {}", status.as_u16())));
        }
        let value: Value = serde_json::from_str(&text)
            .map_err(|e| ApiError::Decode(format!("{}: {}", e, truncate(&text, 200))))?;
        Self::check_response(value)
    }

    /// 统一校验上游响应码。
    pub fn check_response(value: Value) -> Result<Value, ApiError> {
        let code = value.get("code").and_then(|c| c.as_i64()).unwrap_or(200);
        match code {
            200 => Ok(value),
            301 => Err(ApiError::NeedLogin),
            _ => {
                let msg = value
                    .get("msg")
                    .or_else(|| value.get("message"))
                    .and_then(|m| m.as_str())
                    .unwrap_or("未知错误");
                Err(ApiError::Business(format!("{} (code {})", msg, code)))
            }
        }
    }
}

fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        s.to_string()
    } else {
        s.chars().take(max).collect::<String>() + "..."
    }
}

impl Default for NeteaseClient {
    fn default() -> Self {
        Self::new()
    }
}
