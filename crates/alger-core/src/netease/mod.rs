//! 网易云模块：以 `#[path]` 复用 `src-tauri/src/netease` 的同一实现，
//! 外加原生端扩展端点。

#[path = "../../../../src-tauri/src/netease/api.rs"]
pub mod api;
#[path = "../../../../src-tauri/src/netease/client.rs"]
pub mod client;
/// 原生端新增端点（私人 FM / 心动模式 / 关注艺人 / 新作 / 热门 / 专辑）。
pub mod ext;
#[path = "../../../../src-tauri/src/netease/models.rs"]
pub mod models;

pub use client::*;
pub use ext::*;
pub use models::*;
