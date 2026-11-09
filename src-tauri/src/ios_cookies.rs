//! iOS 专用的原生异步 Cookie 读取 / 清理。
//!
//! # 为什么不能用 wry 的同步 Cookie API
//!
//! wry 的 `cookies()` / `cookies_for_url()` / `delete_cookie()` 内部都用
//! `wait_for_blocking_operation` 等待 WebKit 的异步回调，等待期间会在
//! **当前线程泵 NSRunLoop**（`NSRunLoop.acceptInputForMode_beforeDate`）。
//! 而 Tauri 把这些调用派发到 **主线程** 执行，于是变成「在 Tao 的 control
//! flow 内部再泵一次 RunLoop」：
//!
//! - tao 的 iOS `control_flow_begin_handler` 对 `kCFRunLoopEntry` 分支是
//!   `unimplemented!()`（`tao-0.37.2/src/platform_impl/ios/event_loop.rs`）；
//! - release profile 是 `panic = "abort"`。
//!
//! 结果是真机登录成功瞬间 SIGABRT 闪退。已符号化的真机崩溃栈
//! （binary UUID 734DBAE6-0CE3-35C9-ACA9-9C0EE89FD586）：
//!
//! ```text
//! tao::platform_impl::ios::event_loop::control_flow_begin_handler
//!   → NSRunLoop.acceptInputForMode_beforeDate
//!     → wry::wkwebview::InnerWebView::cookies
//!       → tauri_runtime_wry::handle_user_message
//!         → tao::platform_impl::ios::event_loop::control_flow_main_end_handler
//! ```
//!
//! 注意：**调用方在后台线程并不能规避**——泵 RunLoop 的是主线程本身，
//! 只要走到 wry 的同步等待路径就一定会崩。
//!
//! # iOS 的做法：原生异步，主线程不泵 RunLoop
//!
//! - 读：主线程只用 `WKWebView.configuration.websiteDataStore.httpCookieStore`
//!   **发起**异步 `getAllCookies`，completion block 里把结果通过 channel
//!   送回后台轮询线程；后台线程等待，主线程继续跑自己的事件循环；
//! - 清：同样走原生异步（`deleteCookie:completionHandler:`），不调用会
//!   同步等待的 wry API。
//!
//! macOS 保持原有 wry 行为不变：桌面端 `wait_for_blocking_operation` 泵的是
//! AppKit 事件循环，不会与 Tao 的 control flow 冲突。

use std::ptr::NonNull;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use objc2::msg_send;
use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2_foundation::{NSArray, NSHTTPCookie};
use objc2_web_kit::{WKHTTPCookieStore, WKWebViewConfiguration};

/// 等待 WebKit 回调的最长时间。
const CALLBACK_TIMEOUT: Duration = Duration::from_secs(5);

/// 一次 Cookie 读取的结果。
///
/// 只承载纯 Rust 数据（不跨线程传 UIKit 对象）。
#[derive(Debug, Clone)]
pub struct CookieEntry {
    /// Cookie 名。
    pub name: String,
    /// Cookie 值。
    pub value: String,
    /// Cookie 域名（可能带前导点）。
    pub domain: String,
}

/// 读取指定窗口数据存储中的全部 Cookie（iOS 原生异步）。
///
/// 返回 `None` 表示读取失败或超时（调用方按「暂时没拿到 Cookie」处理）。
pub fn read_cookies(window: &tauri::WebviewWindow) -> Option<Vec<CookieEntry>> {
    let (tx, rx): (Sender<Vec<CookieEntry>>, Receiver<Vec<CookieEntry>>) = channel();
    // completion block 只会被调用一次，用 Mutex<Option<Sender>> 包一层
    let slot = Arc::new(Mutex::new(Some(tx)));

    window
        .with_webview(move |webview| {
            let Some(cookie_store) = http_cookie_store(&webview) else {
                return;
            };
            let slot = Arc::clone(&slot);
            let block = block2::RcBlock::new(move |cookies: NonNull<NSArray<NSHTTPCookie>>| {
                let entries = collect_cookies(cookies);
                if let Some(tx) = slot.lock().ok().and_then(|mut guard| guard.take()) {
                    let _ = tx.send(entries);
                }
            });
            // 只发起异步请求，不等待结果：主线程不泵 RunLoop
            unsafe { cookie_store.getAllCookies(&block) };
        })
        .ok()?;

    rx.recv_timeout(CALLBACK_TIMEOUT).ok()
}

/// 异步删除指定窗口数据存储中的全部 Cookie（iOS 原生异步）。
///
/// 不等待删除结果（WebKit 的 completion block 回调时进程可能已经退出）。
pub fn clear_cookies(window: &tauri::WebviewWindow) {
    let _ = window.with_webview(move |webview| {
        let Some(cookie_store) = http_cookie_store(&webview) else {
            return;
        };
        // 闭包需要一份自己的副本（Retained 不是 Copy）
        let store_for_block = cookie_store.clone();
        let block = block2::RcBlock::new(move |cookies: NonNull<NSArray<NSHTTPCookie>>| {
            let list = unsafe { cookies.as_ref() };
            for cookie in list.to_vec() {
                // 原生异步删除：不等待回调，因此不会阻塞主线程
                unsafe { store_for_block.deleteCookie_completionHandler(&cookie, None) };
            }
        });
        unsafe { cookie_store.getAllCookies(&block) };
    });
}

/// 取窗口 WKWebView 所在数据存储的 HTTP Cookie 存储。
fn http_cookie_store(
    webview: &tauri::webview::PlatformWebview,
) -> Option<Retained<WKHTTPCookieStore>> {
    // iOS：`PlatformWebview::inner()` 是 WKWebView 的裸指针。
    // 注意 objc2-web-kit 只在 macOS 提供 `WKWebView` 类（iOS 的版本由 wry
    // 自带，因为父类是 UIView），所以这里用 `msg_send!` 取配置，不依赖类名。
    let ptr = webview.inner() as *const AnyObject;
    let obj: &AnyObject = unsafe { &*ptr };
    let config: Retained<WKWebViewConfiguration> = unsafe { msg_send![obj, configuration] };
    let store = unsafe { config.websiteDataStore() };
    Some(unsafe { store.httpCookieStore() })
}

/// 把 `NSArray<NSHTTPCookie>` 转成纯 Rust 数据。
fn collect_cookies(cookies: NonNull<NSArray<NSHTTPCookie>>) -> Vec<CookieEntry> {
    let list = unsafe { cookies.as_ref() };
    list.to_vec()
        .into_iter()
        .map(|cookie| CookieEntry {
            name: cookie.name().to_string(),
            value: cookie.value().to_string(),
            domain: cookie.domain().to_string(),
        })
        .collect()
}
