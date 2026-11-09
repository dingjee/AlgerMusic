import AppKit
import WebKit

/// 网易云登录窗口（**WKWebView 仅用于登录**，主界面没有 WebView）。
///
/// 规则：
/// - 使用 **非持久化** 数据存储：窗口关闭后网页侧的 Cookie 不残留；
/// - 登录成功后只取 `MUSIC_U`，交给桥接 **校验并落盘**（失败保留原会话）；
/// - 不给网页任何本地能力（没有注入脚本、没有消息处理器）。
@MainActor
final class LoginWindowController: NSObject, NSWindowDelegate {
    /// 网易云登录地址。
    static let loginURL = URL(string: "https://music.163.com/#/login/")!

    private var window: NSWindow?
    private var webView: WKWebView?
    private var pollTimer: Timer?
    private var didSubmit = false

    /// 拿到登录 Cookie（`MUSIC_U=...`）。
    var onCookie: ((String) -> Void)?
    /// 窗口关闭。
    var onClose: (() -> Void)?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 460, height: 640), configuration: configuration)
        self.webView = webView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "登录网易云音乐"
        window.delegate = self
        window.contentView = webView
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)

        webView.load(URLRequest(url: Self.loginURL))
        startPolling()
    }

    func focus() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        stopPolling()
        onClose?()
    }

    // MARK: - Cookie 采集

    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkCookies()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func checkCookies() {
        guard !didSubmit, let webView else { return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            Task { @MainActor in
                guard let self, !self.didSubmit else { return }
                guard let musicU = cookies.first(where: { cookie in
                    cookie.name == "MUSIC_U" && cookie.domain.contains("music.163.com")
                }) else { return }
                self.didSubmit = true
                self.stopPolling()
                self.onCookie?("MUSIC_U=\(musicU.value)")
                self.window?.close()
            }
        }
    }
}
