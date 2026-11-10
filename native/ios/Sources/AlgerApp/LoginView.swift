import SwiftUI
import WebKit

/// 登录页（**WKWebView 仅用于登录**；主界面没有 WebView）。
///
/// 流程：打开网易云登录页 → 登录成功后从 `WKHTTPCookieStore` 取
/// `MUSIC_U` → 交桥接校验并落盘 → 关闭本页。
struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var webView: WKWebView?
    @State private var status = "请在下方完成登录"
    @State private var isChecking = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text(status)
                    .font(ElderUI.captionFont)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let webView {
                    WebViewContainer(webView: webView)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("登录网易云")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .font(ElderUI.buttonFont)
                }
            }
        }
        .task {
            let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
            webView = web
            web.load(URLRequest(url: URL(string: "https://music.163.com/#/login")!))
            await pollForCookie(web)
        }
    }

    /// 轮询 Cookie：登录成功后 `MUSIC_U` 出现 → 提交桥接。
    private func pollForCookie(_ web: WKWebView) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        for _ in 0..<180 { // 最多等 3 分钟
            if let cookie = await musicCookie(in: web) {
                status = "正在登录…"
                let ok = await model.completeLogin(cookie: cookie)
                if ok {
                    status = "登录成功"
                    dismiss()
                } else {
                    status = "登录失败，请重试"
                }
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        status = "还没有检测到登录，请完成登录后返回"
    }

    private func musicCookie(in web: WKWebView) async -> String? {
        // iOS 16 只有回调版本（async 的 allCookies() 是 iOS 17+）。
        let store = web.configuration.websiteDataStore.httpCookieStore
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
        return cookies.first { $0.name == "MUSIC_U" }?.value
    }
}

/// WKWebView 的 SwiftUI 包装（UIKit representable）。
struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
