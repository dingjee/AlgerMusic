import Foundation

/// 应用数据路径（与 Rust 侧 session 目录约定一致）。
///
/// 普通版 `AlgerMusicPlayer`；编译期标志 `ALGER_TRIAL` 时为
/// `AlgerMusicPlayer.trial`（与 Rust 的 `ALGER_TRIAL` 对应）。
///
/// **隔离运行**：`ALGER_APP_DATA_DIR`（**必须是绝对路径**）可以整体改写数据根目录，
/// 供测试与 GUI 试跑使用 —— 那里不会碰用户的真实资料库。
/// 该变量只改数据位置，**不修改 HOME 等系统变量**。
///
/// **绝不静默回落**：覆盖值存在但非法（空串 / 相对路径）时，
/// `validateDataDirectoryOverride()` 直接报错，应用 **拒绝启动**，
/// 不会因为「路径不合法」而回落到真实 profile。
public enum AppPaths {
    /// 数据根目录覆盖变量（绝对路径）。
    public static let dataDirectoryEnvironmentKey = "ALGER_APP_DATA_DIR"

    /// 数据目录覆盖的 **原始字符串**（未设置时为 nil）。
    ///
    /// 注意：**必须用原始字符串判断绝对性** —— `URL(fileURLWithPath:)` 总是
    /// 生成绝对路径（相对路径会被拼到 cwd 上），拿它判断会永远「合法」。
    ///
    /// 这里直接读 `getenv`（而不是 `ProcessInfo.environment` 的快照），
    /// 这样测试里 `setenv` 之后能立刻看到变化。
    public static var dataDirectoryOverride: String? {
        guard let raw = getenv(dataDirectoryEnvironmentKey) else { return nil }
        return String(cString: raw)
    }

    /// 校验一个具体的覆盖值（`nil` = 未设置；空串 / 相对路径 = 非法）。
    ///
    /// 拆成纯函数是为了能 **直接测**：非法值必须抛错，绝不回落真实 profile。
    public static func validateDataDirectoryOverride(raw: String?) throws {
        guard let raw else { return }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppPathsError.invalidDataDirectory(
                "\(dataDirectoryEnvironmentKey) 被设为空值：拒绝回落到真实资料目录"
            )
        }
        guard trimmed.hasPrefix("/") else {
            throw AppPathsError.invalidDataDirectory(
                "\(dataDirectoryEnvironmentKey) 必须是绝对路径（收到 \(raw)）：拒绝回落到真实资料目录"
            )
        }
    }

    /// 启动校验：覆盖值存在但非法 → **直接报错**，绝不回落真实资料目录。
    public static func validateDataDirectoryOverride() throws {
        try validateDataDirectoryOverride(raw: dataDirectoryOverride)
    }

    /// 合法的隔离目录（非法时为 nil —— 由启动校验负责报错，不在此处回落）。
    public static var isolatedDirectoryOverride: URL? {
        guard let raw = dataDirectoryOverride else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
    }

    /// Application Support 根目录（真实 profile 都在它下面）。
    public static var applicationSupportBase: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
    }

    /// 真实 profile 根目录（**不含**覆盖）。
    public static var defaultAppSupportDir: URL {
        #if ALGER_TRIAL
        return applicationSupportBase.appendingPathComponent("AlgerMusicPlayer.trial", isDirectory: true)
        #else
        return applicationSupportBase.appendingPathComponent("AlgerMusicPlayer", isDirectory: true)
        #endif
    }

    /// 会话 / 索引 / 队列的根目录（Application Support 下的应用目录）。
    public static var appSupportDir: URL {
        if let override = isolatedDirectoryOverride {
            return override
        }
        return defaultAppSupportDir
    }

    /// 是否处于隔离运行（数据目录被环境变量显式改写且合法）。
    public static var isIsolated: Bool { isolatedDirectoryOverride != nil }

    /// **编译期** trial 标志（与 Rust 侧 `ALGER_TRIAL` 对应）。
    ///
    /// 只有在编译时带上 `-D ALGER_TRIAL` 才为 true；运行时无法切换，
    /// 这样试用版与正式版的默认目录不会在同一个二进制里混淆。
    public static var isTrialBuild: Bool {
        #if ALGER_TRIAL
        return true
        #else
        return false
        #endif
    }

    /// 数据根目录是否属于 **隔离运行**。
    ///
    /// 判据：**不在 Application Support 下面** → 隔离（测试 / GUI 试跑）。
    /// 普通版与试用版的数据根目录都在 Application Support 下 → 不隔离，
    /// 因此它们仍然使用用户真实的 `~/Music/AlgerMusic`。
    public static func isIsolatedDataDirectory(_ root: URL) -> Bool {
        let base = applicationSupportBase.standardizedFileURL.path
        let path = root.standardizedFileURL.path
        return path != base && !path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    /// 音乐目录（扫描根目录 / 下载目录）。
    ///
    /// **隔离运行必须落在数据根目录内**：Rust 新建的会话默认下载目录是
    /// `~/Music/AlgerMusic`，直接沿用会把下载写进用户真实目录。
    public static func musicDirectory(dataRoot: URL, isolated: Bool) -> URL {
        if isolated {
            return dataRoot.appendingPathComponent("Music", isDirectory: true)
        }
        return FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("AlgerMusic", isDirectory: true)
    }

    /// 本地歌单目录（M3U8 存放处）。
    public static func playlistsDirectory(dataRoot: URL, isolated: Bool) -> URL {
        if isolated {
            return dataRoot.appendingPathComponent("Playlists", isDirectory: true)
        }
        return musicDirectory(dataRoot: dataRoot, isolated: false)
            .appendingPathComponent("Playlists", isDirectory: true)
    }

    /// 默认音乐目录（基于当前数据根目录）。
    public static var defaultMusicDir: URL {
        musicDirectory(dataRoot: appSupportDir, isolated: isIsolated)
    }

    /// 默认歌单目录（基于当前数据根目录）。
    public static var defaultPlaylistsDir: URL {
        playlistsDirectory(dataRoot: appSupportDir, isolated: isIsolated)
    }
}

/// 路径错误。
public enum AppPathsError: Error, CustomStringConvertible {
    case invalidDataDirectory(String)

    public var description: String {
        switch self {
        case .invalidDataDirectory(let message): return message
        }
    }
}
