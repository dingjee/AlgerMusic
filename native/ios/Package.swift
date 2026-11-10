// swift-tools-version:5.9
import PackageDescription

// 链接的 staticlib 由 scripts/build-ios-ffi.sh 按目标平台产出到 libs/<platform>/。
// 宿主（macOS）测试用 libs/macos；iOS 真机 / 模拟器由脚本产到对应目录后，
// 经 xcodeproj 的按 SDK 搜索路径选择（见 native/ios 工程配置）。
let packageDir = Context.packageDirectory
let ffiLibDir = packageDir + "/libs/macos"

let package = Package(
    name: "AlgerIOS",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
    ],
    products: [
        .library(name: "AlgerKit", targets: ["AlgerKit"]),
    ],
    targets: [
        .target(
            name: "CAlgerFFI",
            path: "Sources/CAlgerFFI",
            linkerSettings: [
                .unsafeFlags(["-L\(ffiLibDir)", "-lalger_ffi"]),
            ]
        ),
        .target(
            name: "AlgerKit",
            dependencies: ["CAlgerFFI"]
        ),
        .testTarget(
            name: "AlgerKitTests",
            dependencies: ["AlgerKit"]
        ),
    ]
)
