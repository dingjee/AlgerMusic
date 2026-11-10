// swift-tools-version:5.9
import PackageDescription

// FFI 静态库以 xcframework 形式提供（macOS 宿主测试 / iOS 真机 / 模拟器
// 共用同一份）：由 scripts/build-ios-ffi.sh 生成到 libs/AlgerFFI.xcframework。
// xcframework 不在版本库里（体积大、可复现构建），首次使用前必须先跑脚本。
let package = Package(
    name: "AlgerIOS",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "AlgerKit", targets: ["AlgerKit"]),
    ],
    targets: [
        .binaryTarget(
            name: "AlgerFFI",
            path: "libs/AlgerFFI.xcframework"
        ),
        .target(
            name: "AlgerKit",
            dependencies: ["AlgerFFI"]
        ),
        .testTarget(
            name: "AlgerKitTests",
            dependencies: ["AlgerKit"]
        ),
    ]
)
