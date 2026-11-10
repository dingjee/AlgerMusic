import Foundation

/// App 容器路径（**Swift 侧计算后传给 Rust**）。
///
/// 铁律：iOS 上 `alger-core` 的 `dirs` crate 取不到可靠路径（沙盒容器
/// UUID 会随重装 / 升级变化），所有路径一律由 Foundation 计算后传入。
public enum ContainerPaths {
    /// Application Support / AlgerMusic：会话（session.json）、桥接内部状态。
    public static func applicationSupport() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("AlgerMusic", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 会话文件绝对路径（桥接 `alger_ffi_init` 用）。
    public static func sessionFile() throws -> URL {
        try applicationSupport().appendingPathComponent("session.json")
    }

    /// 下载目录（Documents / Downloads）：**文件 App 可见**（配合
    /// `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`）。
    public static func downloadsDirectory() throws -> URL {
        let docs = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = docs.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
