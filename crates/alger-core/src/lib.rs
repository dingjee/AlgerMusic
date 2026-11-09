//! Alger core —— 与 Tauri 无关的核心库。
//!
//! 通过 `#[path]` **直接复用** `src-tauri/src` 中的纯模块（加密、Cookie、网易云
//! 接口、第三方音源、会话存储），保证 Tauri 应用与原生 macOS 应用共用同一实现；
//! 本 crate 新增的模块（下载队列、音频标签、曲库扫描、网易扩展端点）不依赖 Tauri。
//!
//! 复用清单（单一实现来源）：
//! - `crypto.rs`   eapi / weapi 加密
//! - `cookie.rs`   Cookie 解析与请求头组装
//! - `netease/`    网易云接口客户端、业务端点、数据模型
//! - `sources/`    pyncmd / gdmusic / kugou / kuwo / migu 音源
//! - `session.rs`  会话与设置持久化（含损坏文件保护）
//!
//! `download` 模块是 `src-tauri/src/download.rs` 中纯工具函数的镜像副本
//! （原文件含 Tauri 事件依赖，无法整体复用）；两侧测试保持同步。

#[path = "../../../src-tauri/src/cookie.rs"]
pub mod cookie;

#[path = "../../../src-tauri/src/crypto.rs"]
pub mod crypto;

pub mod netease;

#[path = "../../../src-tauri/src/sources/mod.rs"]
pub mod sources;

#[path = "../../../src-tauri/src/session.rs"]
pub mod session;

pub mod dlq;
pub mod download;
pub mod metadata;
pub mod scan;
pub mod tags;

use chrono::Local;
use rand::Rng;

/// 当前 Unix 毫秒时间戳（与 `src-tauri/src/lib.rs` 保持一致）。
pub fn now_millis() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// 紧凑日期（`YYYYMMDD`），用于网易云客户端的 `buildver`。
pub fn today_compact() -> String {
    Local::now().format("%Y%m%d").to_string()
}

/// 生成网易云风格的 `requestId`：`{毫秒时间戳}_{4位随机数}`。
pub fn generate_request_id() -> String {
    let mut rng = rand::thread_rng();
    let suffix: u32 = rng.gen_range(0..1000);
    format!("{}_{:04}", now_millis(), suffix)
}
