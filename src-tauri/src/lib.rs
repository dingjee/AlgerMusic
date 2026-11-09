//! Alger Music —— Rust / Tauri 2 后端。
//!
//! 所有网易云接口、Cookie 会话、歌单读取、第三方音源解析与文件下载均由本 crate 原生实现，
//! 运行时不依赖 Node.js / 本地 HTTP 服务。
//!
//! 网络歌单在移动端是 **只读** 的。

pub mod commands;
pub mod cookie;
pub mod crypto;
pub mod download;
pub mod login;
pub mod netease;
pub mod session;
pub mod sources;
pub mod state;
pub mod theme;

/// iOS 专用的原生异步 Cookie 读取 / 清理（避免 wry 同步 API 泵 NSRunLoop）。
#[cfg(target_os = "ios")]
pub mod ios_cookies;

use chrono::Local;
use tauri::Manager;

/// 当前 Unix 毫秒时间戳。
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
    use rand::Rng;
    let mut rng = rand::thread_rng();
    let suffix: u32 = rng.gen_range(0..1000);
    format!("{}_{:04}", now_millis(), suffix)
}

/// 桌面端入口。
#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .manage(state::AppState::new())
        .setup(|app| {
            // 监听系统强调色变化并推送给前端
            theme::start_theme_watch(app.handle().clone());
            // 启动时校验已保存的 Cookie：
            // - 确认失效（未登录 / 401）→ 清理会话并提示前端重新登录；
            // - 网络等临时故障 → **保留** Cookie，只提示「暂时无法校验」，
            //   不做破坏性清理。
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                let state = handle.state::<state::AppState>();
                let cookie = state.session.get().cookie;
                if cookie.trim().is_empty() {
                    return;
                }
                // 记录发起校验时的会话代号与 Cookie，写回前必须比对
                let generation = state.generation();
                match netease::NeteaseClient::verify_account_with(&cookie).await {
                    Ok(account) => {
                        // E0 audit：写回在身份锁内再次比对 cookie/generation，
                        // 期间用户已登录/退出则静默放弃；持久化失败对用户可见。
                        match state.refresh_account_if_current(&cookie, generation, account) {
                            Ok(true) | Ok(false) => {}
                            Err(e) => {
                                use tauri::Emitter;
                                let _ = handle.emit(
                                    login::SESSION_CHECK_EVENT,
                                    serde_json::json!({
                                        "status": "saveFailed",
                                        "message": format!("登录状态未变，但刷新账号信息保存失败（{}），重启应用后可能需要重新登录", e),
                                    }),
                                );
                            }
                        }
                    }
                    Err(netease::client::ApiError::NeedLogin) => {
                        // E0 audit：expected cookie / generation 带入身份锁内
                        // 条件清理；stale 静默跳过，落盘失败发 saveFailed，
                        // 不得在未清理成功时宣称 session expired。
                        login::expire_session(&handle, "登录状态已失效，请重新登录", &cookie, generation);
                    }
                    Err(netease::client::ApiError::Business(msg)) => {
                        // 上游返回业务错误：可能确实是登录失效，也可能是其它限制。
                        // 这里 **不** 清空 Cookie，只提示用户稍后重试。
                        if state.generation() != generation {
                            return;
                        }
                        use tauri::Emitter;
                        let _ = handle.emit(
                            login::SESSION_CHECK_EVENT,
                            serde_json::json!({
                                "status": "unverified",
                                "message": format!("暂时无法校验登录状态（{}），已保留本机 Cookie", msg),
                            }),
                        );
                    }
                    Err(e) => {
                        // 网络 / 解码等临时故障：只读提示，不动本地 Cookie
                        if state.generation() != generation {
                            return;
                        }
                        use tauri::Emitter;
                        let _ = handle.emit(
                            login::SESSION_CHECK_EVENT,
                            serde_json::json!({
                                "status": "unverified",
                                "message": format!("暂时无法校验登录状态（{}），已保留本机 Cookie", e),
                            }),
                        );
                    }
                }
            });
            Ok(())
        })
        .on_window_event(|window, event| {
            // 浅色 / 深色切换时立即刷新强调色（不同外观下的强调色略有差异）
            if let tauri::WindowEvent::ThemeChanged(_) = event {
                theme::push_accent(window.app_handle());
            }
            // macOS：主窗口关闭改为隐藏到 Dock（配合 RunEvent::Reopen 恢复）；
            // 登录窗口等其它窗口不拦截，正常关闭。ExitRequested 不拦截，
            // 保证 Cmd+Q 仍然退出应用。
            #[cfg(target_os = "macos")]
            {
                if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                    if window.label() == "main" {
                        api.prevent_close();
                        let _ = window.hide();
                    }
                }
            }
        })
        .invoke_handler(tauri::generate_handler![
            commands::get_snapshot,
            commands::login_with_cookie,
            commands::open_login_window,
            commands::logout,
            commands::update_settings,
            commands::user_playlists,
            commands::playlist_detail,
            commands::search_songs,
            commands::get_lyric,
            commands::resolve_playable,
            commands::download_song,
            commands::list_downloads,
            commands::open_download_folder,
            commands::reveal_file,
            commands::pick_download_dir,
            commands::probe_source,
            commands::theme_accent,
            commands::set_unsupported_audio_formats,
        ])
        .build(tauri::generate_context!())
        .expect("启动 Tauri 应用失败");

    // macOS：主窗口隐藏后，点击 Dock 图标（RunEvent::Reopen）恢复显示、
    // 取消最小化并聚焦；不拦截 ExitRequested，保证 Cmd+Q 正常退出。
    #[cfg(target_os = "macos")]
    app.run(|app_handle, event| {
        if let tauri::RunEvent::Reopen { .. } = event {
            if let Some(main) = app_handle.get_webview_window("main") {
                let _ = main.show();
                let _ = main.unminimize();
                let _ = main.set_focus();
            }
        }
    });

    #[cfg(not(target_os = "macos"))]
    app.run(|_, _| {});
}
