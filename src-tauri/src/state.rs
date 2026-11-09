//! 应用共享状态。

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use parking_lot::Mutex;

use crate::download::DownloadManager;
use crate::netease::models::Account;
use crate::netease::NeteaseClient;
use crate::session::SessionStore;
use crate::sources::Resolver;

/// 全局共享状态。
pub struct AppState {
    /// 网易云接口客户端。
    pub client: NeteaseClient,
    /// 第三方音源解析器。
    pub resolver: Arc<Resolver>,
    /// 本地会话与设置。
    pub session: SessionStore,
    /// 下载管理器。
    pub downloads: Arc<DownloadManager>,
    /// 会话代号。
    ///
    /// 每次登录 / 退出都会自增。异步校验（启动时校验已保存的 Cookie）
    /// 必须在写回结果前比对代号，避免：
    /// - 用户已退出登录后，启动校验又把旧登录写回来；
    /// - 用户已重新登录后，启动校验把新登录覆盖成旧的。
    pub session_generation: AtomicU64,
    /// 身份事务锁（E0 audit）：会话持久化提交、网络客户端 Cookie 切换与
    /// generation 自增必须 **整体** 在本锁内完成，防止跨线程交错——
    /// 否则会出现「磁盘已写新身份、内存客户端仍是旧身份」或反之的分叉；
    /// 启动校验与失效清理也在持锁后再次比对 cookie / generation。
    pub identity: Mutex<()>,
}

impl AppState {
    /// 构造状态并载入已保存的 Cookie。
    pub fn new() -> Self {
        let session = SessionStore::open();
        let client = NeteaseClient::new();
        let cookie = session.get().cookie;
        if !cookie.trim().is_empty() {
            client.set_cookie(&cookie);
        }
        Self {
            client,
            resolver: Arc::new(Resolver::new()),
            session,
            downloads: Arc::new(DownloadManager::new()),
            session_generation: AtomicU64::new(0),
            identity: Mutex::new(()),
        }
    }

    /// 当前会话代号。
    pub fn generation(&self) -> u64 {
        self.session_generation.load(Ordering::SeqCst)
    }

    /// 会话发生变化（登录 / 退出）时自增代号。
    pub fn bump_generation(&self) -> u64 {
        self.session_generation.fetch_add(1, Ordering::SeqCst) + 1
    }

    /// 身份变更共享事务（E0 audit）：
    /// 1. 持身份锁；
    /// 2. `persist` 完成会话写入（内部先落盘后提交内存；失败即返回，
    ///    客户端身份不被触碰）；
    /// 3. 同一临界区内切换网络客户端 Cookie（`Some` = 设置，`None` = 清除）
    ///    并自增 generation。
    ///
    /// 登录 / 退出 / 失效清理都必须走本入口，不得在外面直接
    /// `client.set_cookie` / `clear_cookie`。
    pub fn commit_identity(
        &self,
        persist: impl FnOnce(&SessionStore) -> Result<(), String>,
        cookie: Option<&str>,
    ) -> Result<(), String> {
        let _g = self.identity.lock();
        persist(&self.session)?;
        match cookie {
            Some(c) => self.client.set_cookie(c),
            None => self.client.clear_cookie(),
        }
        self.bump_generation();
        Ok(())
    }

    /// 条件失效清理（E0 audit）：在身份锁内比对 cookie / generation——
    /// 一致才持久化清除并清客户端 Cookie；stale（期间用户已重新登录或
    /// 退出）返回 `Ok(false)` 静默跳过，不得清掉新登录；`Err` = 落盘失败，
    /// 原会话与客户端身份都保留，由调用方对用户可见地反馈。
    pub fn clear_identity_if_current(&self, cookie: &str, generation: u64) -> Result<bool, String> {
        let _g = self.identity.lock();
        if self.generation() != generation || self.session.get().cookie != cookie {
            return Ok(false);
        }
        self.session.clear_login()?;
        self.client.clear_cookie();
        self.bump_generation();
        Ok(true)
    }

    /// 启动校验写回（E0 audit）：在身份锁内 **再次比对** cookie 与
    /// generation——任一不匹配说明用户期间已登录 / 退出，本次写回放弃。
    /// 返回 `Ok(false)` = 已过期静默跳过；`Err` = 持久化失败（需对用户可见）。
    pub fn refresh_account_if_current(
        &self,
        cookie: &str,
        generation: u64,
        account: Account,
    ) -> Result<bool, String> {
        let _g = self.identity.lock();
        if self.generation() != generation {
            return Ok(false);
        }
        self.session.try_update::<()>(|data| {
            if data.cookie != cookie {
                return Err("stale".into());
            }
            data.account = Some(account);
            Ok(())
        })?;
        self.client.set_cookie(cookie);
        Ok(true)
    }
}

impl Default for AppState {
    fn default() -> Self {
        Self::new()
    }
}
