// swift-tools-version: 5.9
import PackageDescription

// 原生 macOS 应用（E2 / E3）：
// - AlgerKit：原生端核心库（桥接客户端、本地索引、M3U8 歌单、原子落盘、
//             应用状态、本地资料库、AVFoundation 播放）；
// - AlgerApp：真实可执行应用（SwiftUI 主界面 + AppKit 外壳，**主界面没有 WebView**，
//             WKWebView 只用于网易云登录）；
// - AlgerKitTests：XCTest 夹具测试（真实文件 / 真实子进程 / 真实桥接）。
//
// 不声明空目标、不放占位 main：每个目标都必须有真实实现。
let package = Package(
    name: "AlgerMusic",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AlgerKit", targets: ["AlgerKit"]),
        .executable(name: "AlgerMusic", targets: ["AlgerApp"]),
    ],
    targets: [
        .target(name: "AlgerKit"),
        .executableTarget(
            name: "AlgerApp",
            dependencies: ["AlgerKit"]
        ),
        .testTarget(
            name: "AlgerKitTests",
            dependencies: ["AlgerKit"]
        ),
    ]
)
