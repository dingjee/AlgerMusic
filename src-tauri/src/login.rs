//! 内置网易云网页登录窗口。
//!
//! 安全要点：
//! - 登录窗口使用 **独立的数据存储**（`data_store_identifier`），只采集本 App 登录窗口产生的 Cookie。
//! - 登录窗口 **不授予任何 capability**，远程网页无法调用本应用的业务 IPC。
//! - 读取 Cookie 的轮询任务运行在 **独立线程** 上（不是主线程的同步命令），
//!   避免上游 `cookies_for_url` / `cookies` 在主线程阻塞导致的死锁
//!   （参见 tauri-apps/tauri#15489、wry 的 `wait_for_blocking_operation` 实现：
//!   它会在主线程 `NSRunLoop` 上泵事件，因此调用线程必须让出主线程）。
//! - **iOS 例外**：wry 的同步 Cookie API 在 iOS 上会在主线程泵 `NSRunLoop`，
//!   与 Tao 的 control flow 嵌套后直接 SIGABRT 闪退（真机崩溃栈见
//!   `crate::ios_cookies`），因此 iOS 改用原生异步 Cookie API。
//! - 候选 Cookie 先 **独立校验**，成功后才替换现有会话；失败保留原会话。

use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindowBuilder};

use crate::netease::models::Account;
use crate::netease::NeteaseClient;
use crate::state::AppState;

/// 登录窗口 label。
pub const LOGIN_WINDOW_LABEL: &str = "login";
/// 网易云网页登录地址。
pub const LOGIN_URL: &str = "https://music.163.com/#/login/";
/// 登录状态事件名。
pub const LOGIN_EVENT: &str = "login://status";
/// 会话失效事件名（Cookie 过期 / 被顶号）。
pub const SESSION_EXPIRED_EVENT: &str = "session://expired";
/// 会话校验结果事件名（`ok` / `expired` / `unverified`）。
pub const SESSION_CHECK_EVENT: &str = "session://check";
/// 网易云主域名（用于筛选 Cookie）。
const MUSIC_DOMAIN: &str = "music.163.com";

/// 是否已有轮询线程在运行。
static POLLER_RUNNING: AtomicBool = AtomicBool::new(false);

/// 登录窗关闭按钮的注入脚本（iOS 用）。
///
/// iOS 上登录窗是全屏独立窗口，没有标题栏关闭按钮；这里注入一个
/// 悬浮「✕」按钮，点击后把地址改为自定义 scheme，由 Rust 侧
/// `on_navigation` 拦截后关闭窗口。脚本不读取页面内容，也不暴露
/// 任何 IPC 给远程页面。
///
/// 注意：initialization script 以 `atDocumentStart` 注入，此时
/// `<head>`/`<body>` 多半还不存在，直接 append 会抛异常导致脚本失效；
/// 因此脚本内部等待 DOM ready 再挂载。同时 WKUserScript 会注入所有
/// frame，必须仅在顶层 frame 挂载按钮，避免页面内 iframe 重复出现。
const IOS_CLOSE_BUTTON_SCRIPT: &str = r#"
(function () {
  if (window.self !== window.top) return;
  function mount() {
    if (document.getElementById('alger-login-close')) return;
    var btn = document.createElement('button');
    btn.id = 'alger-login-close';
    btn.textContent = '✕ 关闭';
    btn.setAttribute('aria-label', '关闭登录窗口');
    var style = document.createElement('style');
    style.textContent = [
      '#alger-login-close {',
      '  position: fixed; top: calc(env(safe-area-inset-top, 0px) + 10px);',
      '  right: calc(env(safe-area-inset-right, 0px) + 12px);',
      '  z-index: 2147483647; padding: 8px 14px; border-radius: 18px;',
      '  border: 1px solid rgba(120,120,128,0.4);',
      '  background: rgba(250,250,250,0.92); color: #1c1c1e;',
      '  font: 600 14px -apple-system, "PingFang SC", sans-serif;',
      '  box-shadow: 0 2px 10px rgba(0,0,0,0.18); cursor: pointer; }',
      '@media (prefers-color-scheme: dark) {',
      '  #alger-login-close { background: rgba(40,40,44,0.92); color: #f2f2f7; }',
      '}'
    ].join('\n');
    (document.head || document.documentElement).appendChild(style);
    btn.addEventListener('click', function () {
      window.location.href = 'alger-login://close';
    });
    (document.body || document.documentElement).appendChild(btn);
  }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', mount);
  } else {
    mount();
  }
})();
"#;

/// 关闭（iOS 上隐藏复用）登录窗口。
///
/// iOS 上 `WebviewWindow::close()` 底层是 tao `Window::drop()`，依赖实现显示
/// 该路径既不把窗口从屏幕移除，也不把 key window 让还给主窗口，会留下无法
/// 交互的全屏遮挡（源码级证据；真机行为待验收确认）。因此 iOS 统一走
/// `hide()` + 主窗口 `set_focus()`：
/// 窗口对象保留，下次登录直接 `show()` 复用（同一非持久化数据存储）。
/// 桌面端保持真正的 `close()`。
///
/// 三个路径都必须经过这里：登录成功（poller）、手动取消（on_navigation
/// 拦截 `alger-login://close`）。
fn dismiss_login_window(app: &AppHandle) {
    let Some(window) = app.get_webview_window(LOGIN_WINDOW_LABEL) else {
        return;
    };
    if cfg!(target_os = "ios") {
        let _ = window.hide();
        if let Some(main) = app.get_webview_window("main") {
            let _ = main.set_focus();
        }
    } else {
        let _ = window.close();
    }
}

/// 打开（或聚焦）登录窗口。
pub fn open_login_window(app: &AppHandle) -> Result<(), String> {
    if let Some(window) = app.get_webview_window(LOGIN_WINDOW_LABEL) {
        // 桌面端可复用窗口并最小化还原；iOS 没有最小化概念
        #[cfg(desktop)]
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
        // 之前校验失败或窗口被复用时，确保监听仍然在跑
        ensure_poller(app);
        return Ok(());
    }

    let builder = WebviewWindowBuilder::new(
        app,
        LOGIN_WINDOW_LABEL,
        WebviewUrl::External(LOGIN_URL.parse::<url::Url>().map_err(|e| e.to_string())?),
    )
    .title("网易云音乐登录")
    .devtools(false)
    // 使用 **非持久化** 数据存储（macOS / iOS 上的 incognito）：
    // 登录窗口关闭后 Cookie 即消失，不会残留失效的旧 Cookie；
    // 同时也不会与主窗口共享存储。
    .incognito(true);

    // 平台差异：
    // - macOS：常规桌面窗口，给固定尺寸与最小尺寸；
    // - iOS：登录窗是独立全屏 UIWindow（tao 按屏幕 bounds 建窗，
    //   设置 inner_size 反而会让窗口尺寸错误），因此不设置任何尺寸；
    //   另注入悬浮关闭按钮（iOS 无标题栏），通过 on_navigation 拦截
    //   自定义 URL 实现无 IPC 的关窗路径。
    let builder = if cfg!(target_os = "ios") {
        let app_for_nav = app.clone();
        builder
            .initialization_script(IOS_CLOSE_BUTTON_SCRIPT)
            .on_navigation(move |url| {
                if url.scheme() == "alger-login" && url.host_str() == Some("close") {
                    // 手动取消：iOS 隐藏复用 / 桌面真正关闭
                    dismiss_login_window(&app_for_nav);
                    return false;
                }
                true
            })
    } else {
        builder
            .inner_size(1024.0, 760.0)
            .min_inner_size(720.0, 560.0)
            .resizable(true)
    };

    builder
        .build()
        .map_err(|e| format!("打开登录窗口失败：{}", e))?;

    ensure_poller(app);
    Ok(())
}

/// 确保 Cookie 轮询线程在运行（已运行则跳过）。
fn ensure_poller(app: &AppHandle) {
    if POLLER_RUNNING.swap(true, Ordering::SeqCst) {
        return;
    }
    let app_handle = app.clone();
    let spawned = std::thread::Builder::new()
        .name("alger-login-cookie".into())
        .spawn(move || {
            poll_login_cookies(app_handle);
            POLLER_RUNNING.store(false, Ordering::SeqCst);
        });
    if spawned.is_err() {
        POLLER_RUNNING.store(false, Ordering::SeqCst);
    }
}

/// 轮询登录窗口的 Cookie，直到出现可校验的 `MUSIC_U`。
fn poll_login_cookies(app: AppHandle) {
    let deadline = std::time::Instant::now() + Duration::from_secs(600);
    let mut reported = false;
    while std::time::Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(1500));
        let window = match app.get_webview_window(LOGIN_WINDOW_LABEL) {
            Some(w) => w,
            // 用户关闭了登录窗口
            None => return,
        };
        // iOS 上窗口只会被隐藏（hide 复用），隐藏即表示登录已取消或已完成，
        // 停止轮询。桌面端不能按可见性判断：最小化登录窗继续使用主窗口
        // 是支持的场景，销毁（窗口消失）才是取消信号。
        if cfg!(target_os = "ios") && !window.is_visible().unwrap_or(true) {
            return;
        }
        let cookies = match read_music_cookies(&window) {
            Some(c) => c,
            None => continue,
        };
        if !cookies.contains("MUSIC_U=") {
            continue;
        }
        if !reported {
            reported = true;
            emit_status(&app, "pending", "已检测到登录，正在校验账号…");
        }
        match verify_and_store(&app, &cookies) {
            Ok(message) => {
                emit_status(&app, "success", &message);
                // 登录成功后立即清掉登录窗口里的 Cookie，避免残留失效凭证，
                // 然后关闭（iOS 上隐藏复用）登录窗口
                clear_login_window_cookies(&app);
                dismiss_login_window(&app);
                return;
            }
            Err(e) => {
                // 校验失败：保留原会话，继续等待用户重新登录
                emit_status(&app, "failed", &e);
            }
        }
    }
    emit_status(&app, "timeout", "登录超时，请重试或使用手动粘贴 Cookie");
}

/// 读取登录窗口中属于 `music.163.com` 的 Cookie。
///
/// iOS 必须走 **原生异步** 路径（`crate::ios_cookies`）：wry 的同步
/// `cookies()` 会在主线程泵 NSRunLoop，与 Tao 的 control flow 嵌套后
/// 直接 SIGABRT 闪退（真机崩溃栈见 `crate::ios_cookies` 模块说明）。
/// macOS 保持 wry 的同步实现不变。
fn read_music_cookies(window: &tauri::WebviewWindow) -> Option<String> {
    #[cfg(target_os = "ios")]
    {
        let entries = crate::ios_cookies::read_cookies(window)?;
        let mut parts: Vec<String> = Vec::new();
        for cookie in entries {
            let domain = cookie.domain.trim_start_matches('.').to_ascii_lowercase();
            if domain != MUSIC_DOMAIN {
                continue;
            }
            if cookie.name.is_empty() {
                continue;
            }
            parts.push(format!("{}={}", cookie.name, cookie.value));
        }
        if parts.is_empty() {
            None
        } else {
            Some(parts.join("; "))
        }
    }
    #[cfg(not(target_os = "ios"))]
    {
        // `cookies()` 的实现在主线程的消息循环中执行，真正的阻塞发生在当前线程，
        // 主线程保持空闲，因此不会与页面加载 / eval 形成死锁。
        let cookies = window.cookies().ok()?;
        let mut parts: Vec<String> = Vec::new();
        for cookie in cookies {
            let domain = cookie.domain().unwrap_or_default();
            let domain = domain.trim_start_matches('.').to_ascii_lowercase();
            if domain != MUSIC_DOMAIN {
                continue;
            }
            let name = cookie.name();
            let value = cookie.value();
            if name.is_empty() {
                continue;
            }
            parts.push(format!("{}={}", name, value));
        }
        if parts.is_empty() {
            None
        } else {
            Some(parts.join("; "))
        }
    }
}

/// 校验候选 Cookie；**校验成功并持久化后才**替换当前会话（R6 / E0 audit）。
fn verify_and_store(app: &AppHandle, cookie: &str) -> Result<String, String> {
    let account: Account =
        tauri::async_runtime::block_on(NeteaseClient::verify_account_with(cookie))
            .map_err(|e| format!("登录校验失败：{}", e))?;
    {
        let state = app.state::<AppState>();
        // 共享身份事务：先落盘（事务闭包，不用旧快照），成功后在同一
        // 临界区内切客户端 Cookie 并自增 generation；落盘失败时客户端
        // 保持旧身份，错误反馈用户（不能用新 Cookie 假装已登录）。
        let owned_cookie = cookie.to_string();
        let message = format!("登录成功：{}", account.nickname);
        state
            .commit_identity(
                move |session| {
                    session.update(move |data| {
                        data.cookie = owned_cookie;
                        data.account = Some(account);
                    })
                },
                Some(cookie),
            )
            .map_err(|e| format!("登录成功但保存会话失败（{}）", e))?;
        Ok(message)
    }
}

/// 清理登录窗口中遗留的 Cookie（退出登录 / 会话失效时调用）。
///
/// 登录窗口使用 **非持久化** 数据存储（进程内共享），因此：
/// - 窗口仍在（含 iOS 上被 `hide()` 复用的窗口）：直接删除
///   `music.163.com` 的 Cookie 并清空浏览数据；
/// - 窗口已关闭：新建一个临时隐藏窗口清空同一个数据存储后立即关闭，
///   否则旧 Cookie 会残留到本次运行结束。该兜底仅限桌面端——
///   iOS 上登录窗只 `hide()` 不销毁、始终能命中上面的分支；且
///   tao 在 iOS 建窗即是全屏 UIWindow，临时窗口会覆盖主窗口。
///
/// 只影响本 App 自己的登录数据存储，不触碰其他应用或浏览器的 Cookie。
pub fn clear_login_window_cookies(app: &AppHandle) {
    if let Some(window) = app.get_webview_window(LOGIN_WINDOW_LABEL) {
        #[cfg(target_os = "ios")]
        {
            // iOS：原生异步删除。wry 的 `delete_cookie()` 内部会同步等待
            // （主线程泵 NSRunLoop）→ 与 Tao control flow 嵌套 → SIGABRT，
            // 因此这里走 `httpCookieStore.deleteCookie:completionHandler:`。
            crate::ios_cookies::clear_cookies(&window);
            // 清浏览数据（localStorage 等）：wry 的该实现本身就是异步的
            // （removeDataOfTypes:modifiedSince:），不等待回调，安全。
            let _ = window.clear_all_browsing_data();
        }
        #[cfg(not(target_os = "ios"))]
        {
            // 逐个删除 music.163.com 的 Cookie
            if let Ok(cookies) = window.cookies() {
                for cookie in cookies {
                    let domain = cookie.domain().unwrap_or_default();
                    let domain = domain.trim_start_matches('.').to_ascii_lowercase();
                    if domain == MUSIC_DOMAIN {
                        let _ = window.delete_cookie(cookie);
                    }
                }
            }
            let _ = window.clear_all_browsing_data();
        }
        return;
    }

    if cfg!(target_os = "ios") {
        return;
    }

    // 窗口已关闭：用临时窗口清空共享的非持久化数据存储（桌面端兜底）
    let temp_label = "login-store-cleanup";
    let Ok(url) = "https://music.163.com/".parse::<url::Url>() else {
        return;
    };
    if let Ok(temp) = WebviewWindowBuilder::new(app, temp_label, WebviewUrl::External(url))
        .incognito(true)
        .visible(false)
        .build()
    {
        let _ = temp.clear_all_browsing_data();
        let _ = temp.close();
    }
}

/// 会话失效：条件清理本地会话与登录窗口 Cookie，并通知前端重新登录。
///
/// E0 audit：`expected_cookie` / `expected_generation` 带入身份锁内比对：
/// - 一致 → 持久化清除成功后才清客户端 Cookie，再清登录窗口并通知；
/// - stale（校验期间用户已重新登录或退出）→ **静默跳过**，不得清掉新登录；
/// - 落盘失败 → 原会话与登录状态保留，向前端发 `saveFailed`，
///   不得在未清理成功时宣称「session expired」。
pub fn expire_session(
    app: &AppHandle,
    reason: &str,
    expected_cookie: &str,
    expected_generation: u64,
) {
    enum Outcome {
        Cleared,
        Stale,
        SaveFailed(String),
    }
    let outcome = {
        let state = app.state::<AppState>();
        match state.clear_identity_if_current(expected_cookie, expected_generation) {
            Ok(true) => Outcome::Cleared,
            Ok(false) => Outcome::Stale,
            Err(e) => Outcome::SaveFailed(e),
        }
    };
    match outcome {
        Outcome::Cleared => {
            clear_login_window_cookies(app);
            use tauri::Emitter;
            let _ = app.emit(
                SESSION_EXPIRED_EVENT,
                serde_json::json!({ "message": reason }),
            );
        }
        // stale：期间身份已变化，本次失效结论不再适用，不清理也不通知
        Outcome::Stale => {}
        Outcome::SaveFailed(e) => {
            eprintln!("清理失效会话失败（原会话与登录状态保留）：{}", e);
            use tauri::Emitter;
            let _ = app.emit(
                SESSION_CHECK_EVENT,
                serde_json::json!({
                    "status": "saveFailed",
                    "message": format!("登录状态已失效，但清理本地会话失败（{}），请重启应用后重新登录", e),
                }),
            );
        }
    }
}

/// 向前端推送登录状态。
fn emit_status(app: &AppHandle, status: &str, message: &str) {
    use tauri::Emitter;
    let _ = app.emit(
        LOGIN_EVENT,
        serde_json::json!({ "status": status, "message": message }),
    );
}
