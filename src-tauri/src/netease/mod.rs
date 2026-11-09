//! 网易云音乐接口客户端（原生 Rust 直连，不依赖任何本地 Node 服务）。

pub mod api;
pub mod client;
pub mod models;

pub use client::{ApiError, NeteaseClient};
pub use models::*;
