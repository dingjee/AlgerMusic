//! 系统主题桥接。
//!
//! 浅色 / 深色由前端的 `prefers-color-scheme` 媒体查询跟随系统；
//! 但 WebKit 对标准 `AccentColor` 属性支持有限，因此这里用 Rust 直接读取
//! 系统强调色（macOS 的 `NSColor.controlAccentColor`、iOS 的 UIKit 系统动态色），
//! 把十六进制值推送给前端写入 CSS 变量。

use tauri::{AppHandle, Emitter};

/// 强调色事件名。
pub const THEME_EVENT: &str = "theme://accent";

/// 读取当前系统强调色（`#RRGGBB`）。
///
/// macOS 读取 `NSColor.controlAccentColor`；iOS 读取 UIKit 的系统动态色；
/// 其它平台返回 `None`，由前端使用 CSS 兜底值。
///
/// 注意：系统颜色应在主线程读取。生产路径上
/// `theme_accent` 是同步命令（主线程执行），macOS 的后台轮询也通过
/// `run_on_main_thread` 回到主线程后再取值。
#[cfg(target_os = "macos")]
pub fn accent_hex() -> Option<String> {
    use objc2_app_kit::{NSColor, NSColorSpace};
    {
        let color = NSColor::controlAccentColor();
        let rgb = color.colorUsingColorSpace(&NSColorSpace::sRGBColorSpace())?;
        let to_byte = |v: f64| (v * 255.0).round().clamp(0.0, 255.0) as u8;
        Some(format!(
            "#{:02X}{:02X}{:02X}",
            to_byte(rgb.redComponent()),
            to_byte(rgb.greenComponent()),
            to_byte(rgb.blueComponent())
        ))
    }
}

/// iOS 的强调色：读取 UIKit 的系统动态色，并按当前 trait 解析为 RGB。
///
/// - UIKit 的系统颜色必须在主线程读取：这里用 `MainThreadMarker` 做保护，
///   非主线程调用返回 `None`（前端回退到 CSS 兜底值）。
/// - `systemBlueColor` 是 iOS 系统控件默认使用的动态蓝，会随浅色 / 深色变化；
///   用当前 `UITraitCollection` 解析后即得到当前外观下的实际取值。
/// - `getRed:green:blue:alpha:` 的分量类型是 `CGFloat`（64 位 Apple 平台即 `f64`），
///   这里直接用 `f64` 变量承接，避免为命名 `CGFloat` 再引入一个依赖。
#[cfg(target_os = "ios")]
pub fn accent_hex() -> Option<String> {
    use objc2::MainThreadMarker;
    use objc2_ui_kit::{UIColor, UITraitCollection};

    // UIKit 系统颜色只能在主线程读取
    MainThreadMarker::new()?;

    unsafe {
        // 当前 trait 决定动态色的解析结果（浅色 / 深色）
        let traits = UITraitCollection::currentTraitCollection();
        let color = UIColor::systemBlueColor().resolvedColorWithTraitCollection(&traits);
        // `CGFloat` 在 64 位 Apple 平台上即 `f64`（iOS 16+ 仅 64 位），
        // 这里直接用 `f64` 变量承接分量，避免额外依赖来命名 `CGFloat`。
        let mut r: f64 = 0.0;
        let mut g: f64 = 0.0;
        let mut b: f64 = 0.0;
        let mut _alpha: f64 = 0.0;
        if !color.getRed_green_blue_alpha(&mut r, &mut g, &mut b, &mut _alpha) {
            return None;
        }
        let to_byte = |v: f64| (v * 255.0).round().clamp(0.0, 255.0) as u8;
        Some(format!(
            "#{:02X}{:02X}{:02X}",
            to_byte(r),
            to_byte(g),
            to_byte(b)
        ))
    }
}

/// 其余平台没有系统强调色。
#[cfg(not(any(target_os = "macos", target_os = "ios")))]
pub fn accent_hex() -> Option<String> {
    None
}

/// 立即把当前强调色推送给前端。
pub fn push_accent(app: &AppHandle) {
    if let Some(accent) = accent_hex() {
        let _ = app.emit(THEME_EVENT, serde_json::json!({ "accent": accent }));
    }
}

/// 启动强调色监听（仅 macOS）。
///
/// 系统的强调色可以在运行中通过「系统设置 → 外观 → 强调色」修改，
/// 这里轮询检测变化并实时推送；应用外观（浅色 / 深色）切换时由
/// `WindowEvent::ThemeChanged` 触发一次立即推送。
#[cfg(target_os = "macos")]
pub fn start_theme_watch(app: AppHandle) {
    push_accent(&app);
    let handle = app.clone();
    let spawned = std::thread::Builder::new()
        .name("alger-theme".into())
        .spawn(move || {
            let mut last: Option<String> = None;
            loop {
                std::thread::sleep(std::time::Duration::from_millis(1200));
                // 在主线程读取系统颜色，保证解析到当前外观下的值
                let (tx, rx) = std::sync::mpsc::channel::<Option<String>>();
                let target = handle.clone();
                if target
                    .run_on_main_thread(move || {
                        let _ = tx.send(accent_hex());
                    })
                    .is_err()
                {
                    // 应用已退出
                    break;
                }
                let current = match rx.recv_timeout(std::time::Duration::from_millis(800)) {
                    Ok(value) => value,
                    Err(_) => continue,
                };
                if current != last {
                    last = current.clone();
                    if let Some(accent) = current {
                        let _ = handle.emit(THEME_EVENT, serde_json::json!({ "accent": accent }));
                    }
                }
            }
        });
    if spawned.is_err() {
        // 线程创建失败不影响功能，前端仍可使用 CSS 兜底值
    }
}

/// 非 macOS 平台不做常驻轮询。
///
/// - iOS 读取 UIKit 的系统动态色（随浅色 / 深色变化）；
/// - tao 在 iOS 上不派发 `WindowEvent::ThemeChanged`，因此不做后台轮询
///   （避免在手机上反复 dispatch 唤醒主线程）；
/// - 改为由前端在「外观变化」与「应用回到前台」时重新调用 `theme_accent` 取值；
/// - 浅色 / 深色本身由前端 `prefers-color-scheme` 自动跟随。
#[cfg(not(target_os = "macos"))]
pub fn start_theme_watch(app: AppHandle) {
    push_accent(&app);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accent_is_hex_or_none() {
        if let Some(value) = accent_hex() {
            assert!(value.starts_with('#'), "强调色应为 #RRGGBB：{}", value);
            assert_eq!(value.len(), 7, "强调色长度应为 7：{}", value);
            assert!(value[1..].chars().all(|c| c.is_ascii_hexdigit()));
        }
    }
}
