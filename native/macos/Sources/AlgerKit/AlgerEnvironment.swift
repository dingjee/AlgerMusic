import Foundation

/// 原生端的运行环境（桥接进程 + 本地资料库 + 播放器）。
///
/// 职责：
/// - 定位 `alger-bridge` 二进制并用 **绝对路径** 启动（会话路径同样绝对）；
/// - 组装索引 / 应用状态 / 本地资料库 / 桥接服务 / 播放器；
/// - **不改任何系统变量**（不碰 HOME），隔离运行只靠 `ALGER_APP_DATA_DIR`。
public struct AlgerEnvironment {
    /// 桥接二进制路径。
    public let bridgeBinary: URL
    /// 会话文件路径（**绝对路径**，交给桥接的 `--session-path`）。
    public let sessionPath: URL
    /// 数据根目录。
    public let dataDirectory: URL
    /// 是否隔离运行（数据根目录不在 Application Support 下）。
    ///
    /// 隔离时 **所有** 落盘位置（会话、索引、应用状态、下载、歌单）都在
    /// 数据根目录内，绝不写用户真实资料库。
    public let isIsolated: Bool
    /// 本地索引。
    public let index: LibraryIndex
    /// 原生端状态（native.json）。
    public let store: NativeStore
    /// 本地资料库服务。
    public let library: LocalLibrary
    /// 下载入单服务（持久化 + 可恢复 + 不重复加入）。
    public let intake: DownloadIntakeService
    /// 废纸篓删除服务（真实废纸篓 + 操作日志）。
    public let trash: TrashService
    /// 自动保存服务（阈值 + 去重 + 失败可重试）。
    public let autoSave: AutoSaveService
    /// 下载前审核服务（**本地已有就复用 / 质量可能更高才更新**）。
    public let review: DownloadReviewService
    /// 优质替换服务（**先下载验证，再原子替换**）。
    public let replacement: DownloadReplacementService
    /// 统一下载流程（**所有下载入口都走这里**：审核 → 登记 → 入队 → 收尾）。
    public let pipeline: DownloadPipeline
    /// 桥接客户端。
    public let client: BridgeClient
    /// 桥接服务。
    public let bridge: BridgeService
    /// 播放器。
    public let player: PlayerController

    /// 组装运行环境。
    ///
    /// - Parameters:
    ///   - dataDirectory: 数据根目录（`nil` = `AppPaths.appSupportDir`）。
    ///   - bridgeBinary: 桥接二进制（`nil` = 自动定位）。
    ///   - sessionPath: 会话文件（`nil` = `<数据根目录>/session.json`）。
    @MainActor
    public static func make(
        dataDirectory: URL? = nil,
        bridgeBinary: URL? = nil,
        sessionPath: URL? = nil
    ) throws -> AlgerEnvironment {
        // **先校验数据目录覆盖**：显式空值 / 相对路径必须 **拒绝启动**，
        // 绝不能因为「路径不合法」而回落到用户的真实 profile。
        try AppPaths.validateDataDirectoryOverride()

        let root = dataDirectory ?? AppPaths.appSupportDir
        let isolated = AppPaths.isIsolatedDataDirectory(root)
        let binary = try bridgeBinary ?? locateBridgeBinary()
        let session = sessionPath ?? root.appendingPathComponent("session.json", isDirectory: false)

        // 会话路径必须绝对：相对路径会随 cwd 漂移，可能误指真实 profile。
        guard session.path.hasPrefix("/") else {
            throw AlgerEnvironmentError.invalidPath("会话路径必须是绝对路径：\(session.path)")
        }
        guard binary.path.hasPrefix("/") else {
            throw AlgerEnvironmentError.invalidPath("桥接二进制路径必须是绝对路径：\(binary.path)")
        }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: session.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let index = LibraryIndex(
            fileURL: root.appendingPathComponent("library/index.json", isDirectory: false)
        )
        let store = NativeStore(fileURL: root.appendingPathComponent("native.json", isDirectory: false))
        let library = LocalLibrary(index: index, store: store)
        let intake = DownloadIntakeService(store: store, library: library)
        let trash = TrashService(store: store, index: index, library: library)
        let autoSave = AutoSaveService(store: store, library: library)
        let client = try BridgeClient(
            executableURL: binary,
            arguments: ["--session-path", session.path]
        )
        let bridge = BridgeService(client: client)
        let review = DownloadReviewService(library: library, tagReader: bridge, resolver: bridge)
        let player = PlayerController(resolver: LibraryPlaybackResolver(library: library, bridge: bridge))
        let replacement = DownloadReplacementService(
            store: store,
            index: index,
            library: library,
            intake: intake,
            review: review,
            tagPreserver: MetadataTagPreserver(service: MetadataService(client: client)),
            playbackReferences: player
        )
        // **统一下载流程**：所有入口（加入歌单 / 队列另存 / 自动保存 / 重试）共用。
        let pipeline = DownloadPipeline(
            library: library,
            intake: intake,
            review: review,
            replacement: replacement,
            autoSave: autoSave,
            bridge: bridge,
            metadataCompletion: DownloadMetadataCompletionFactory.make(client: client)
        )

        return AlgerEnvironment(
            bridgeBinary: binary,
            sessionPath: session,
            dataDirectory: root,
            isIsolated: isolated,
            index: index,
            store: store,
            library: library,
            intake: intake,
            trash: trash,
            autoSave: autoSave,
            review: review,
            replacement: replacement,
            pipeline: pipeline,
            client: client,
            bridge: bridge,
            player: player
        )
    }

    /// 启动准备：把 **会话** 与 **应用状态** 的默认路径对齐到当前数据目录。
    ///
    /// 关键点：Rust 新建的会话默认下载目录是 `~/Music/AlgerMusic`。
    /// 隔离运行时必须把它改到隔离目录内，否则下载会写进用户真实目录。
    /// （写入只发生在隔离会话文件上；普通模式下默认值本来就对，不写盘。）
    ///
    /// - Returns: 实际做出的调整说明（空数组 = 没有需要调整的）。
    @discardableResult
    public func applyDataDirectoryDefaults() async throws -> [String] {
        var notes: [String] = []
        let snapshot = try await bridge.sessionSnapshot()
        let musicDir = AppPaths.musicDirectory(dataRoot: dataDirectory, isolated: isIsolated)
        let playlistsDir = AppPaths.playlistsDirectory(dataRoot: dataDirectory, isolated: isIsolated)
        let desiredDownload = isIsolated
            ? musicDir.path
            : (snapshot.downloadDirectory.isEmpty ? musicDir.path : snapshot.downloadDirectory)
        if snapshot.downloadDirectory != desiredDownload {
            try await bridge.updateSettings(downloadDirectory: desiredDownload)
            notes.append("下载目录已设为 \(desiredDownload)")
        }
        var settings = store.current.settings
        var changed = false
        if settings.playlistsDirectory.isEmpty {
            settings.playlistsDirectory = playlistsDir.path
            changed = true
        }
        if settings.libraryFolders.isEmpty {
            settings.libraryFolders = [musicDir.path]
            changed = true
        }
        if settings.downloadDirectory.isEmpty {
            settings.downloadDirectory = desiredDownload
            changed = true
        }
        if changed {
            try store.mutate { $0.settings = settings }
        }
        return notes
    }

    /// 定位 `alger-bridge` 二进制。
    /// 顺序：
    /// 1. `ALGER_BRIDGE_BIN`（**绝对路径**）—— 开发 / 测试注入；
    /// 2. 应用包内的 `Contents/Resources/alger-bridge`—— 打包后的正式形态；
    /// 3. 可执行文件同目录 / 上一级 `Resources` —— 免安装试跑；
    /// 4. 仓库内构建产物 —— `swift run` 开发用。
    public static func locateBridgeBinary() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let raw = environment["ALGER_BRIDGE_BIN"], !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            // **必须校验原始字符串**：`URL(fileURLWithPath:)` 总会把相对路径
            // 拼成绝对路径，拿它判断绝对性等于「永远合法」。
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("/") else {
                throw AlgerEnvironmentError.invalidPath("ALGER_BRIDGE_BIN 必须是绝对路径：\(raw)")
            }
            let url = URL(fileURLWithPath: trimmed)
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw AlgerEnvironmentError.bridgeNotFound("ALGER_BRIDGE_BIN 指向的文件不可执行：\(url.path)")
            }
            return url
        }

        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("alger-bridge", isDirectory: false))
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
        let executableDirectory = executable.deletingLastPathComponent()
        candidates.append(executableDirectory.appendingPathComponent("alger-bridge", isDirectory: false))
        candidates.append(
            executableDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/alger-bridge", isDirectory: false)
        )
        candidates.append(
            executableDirectory
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("crates/alger-bridge/target/release/alger-bridge", isDirectory: false)
        )
        candidates.append(
            executableDirectory
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("crates/alger-bridge/target/debug/alger-bridge", isDirectory: false)
        )
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        throw AlgerEnvironmentError.bridgeNotFound(
            "找不到 alger-bridge 二进制（可用 ALGER_BRIDGE_BIN 指定绝对路径）"
        )
    }
}

/// 环境错误。
public enum AlgerEnvironmentError: Error, CustomStringConvertible {
    case invalidPath(String)
    case bridgeNotFound(String)

    public var description: String {
        switch self {
        case .invalidPath(let message): return message
        case .bridgeNotFound(let message): return message
        }
    }
}
