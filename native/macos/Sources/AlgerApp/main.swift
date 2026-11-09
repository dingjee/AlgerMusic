import AppKit
import AlgerKit

// 原生 macOS 应用入口（AppKit 外壳 + SwiftUI 内容）。
//
// - **主界面只用 SwiftUI / AppKit**（macOS 13+），主界面里没有 WebView；
// - WKWebView 只用于网易云登录（见 `LoginWindow.swift`）；
// - 关窗隐藏、Dock 恢复、⌘Q 异步退出都由 `AppDelegate` 负责。

// 只读运行时身份查询（供打包 / 交付脚本核验真实运行身份）。
//
// 约定：
//   * **不创建 AppModel**、**不启动桥接**、**不写任何 profile**（只读路径计算）；
//   * 输出 **单行 JSON**，键固定为 bundleIdentifier / dataDirectory / trial；
//   * 退出码固定 0（查询本身不失败）。
if CommandLine.arguments.contains("--print-runtime-identity") {
    print(RuntimeIdentity.json())
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
