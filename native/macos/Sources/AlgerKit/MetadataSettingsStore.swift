import Foundation

// MARK: - 设置

/// 元信息相关设置（**独立文件** `metadata-settings.json`，不进 `native.json`）。
///
/// - `acoustIDApiKey`：AcoustID 指纹匹配的应用 key（用户自己配置，不外发）；
/// - `fpcalcPath`：`fpcalc` 可执行文件路径（缺依赖时明确提示，不假成功）。
///
/// **不含凭证**：这里只存用户自己填的公开 API key 与本地工具路径。
public struct MetadataSettings: Codable, Equatable {
    /// AcoustID API key（未配置时为空）。
    public var acoustIDApiKey: String
    /// `fpcalc` 路径（未配置时为空；为空表示交给桥接在 PATH 里找）。
    public var fpcalcPath: String

    public init(acoustIDApiKey: String = "", fpcalcPath: String = "") {
        self.acoustIDApiKey = acoustIDApiKey
        self.fpcalcPath = fpcalcPath
    }

    private enum CodingKeys: String, CodingKey {
        case acoustIDApiKey
        case fpcalcPath
    }

    /// 宽容解码：缺字段用默认值（旧版本文件不会因为缺字段而整体报废）。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        acoustIDApiKey = try container.decodeIfPresent(String.self, forKey: .acoustIDApiKey) ?? ""
        fpcalcPath = try container.decodeIfPresent(String.self, forKey: .fpcalcPath) ?? ""
    }
}

// MARK: - 设置存储

/// 元信息设置的落盘存储（`metadata-settings.json`）。
///
/// 语义与 `LibraryIndex` / `NativeStore` 一致：
/// - **三种载入状态严格区分**：不存在 → 空设置可写；损坏 → 保留原文件、拒绝写入；
///   读失败（权限 / IO）→ 同样拒绝写入，**绝不**当成「不存在」而覆盖原文件；
/// - **事务语义**：先落盘成功、再发布内存；写失败时内存与磁盘都不变；
/// - **跨进程写事务**：写入期间持 **协作式 flock**（`<文件>.lock`），
///   锁覆盖「检查基线 → 原子替换提交」；
/// - **外部修改检测**：保存前比对磁盘指纹（内容摘要），被外部改过就报冲突，绝不覆盖；
/// - **基线只来自本次提交**：保存成功后基线 = 本次提交字节 + 同一临时 fd 的 fstat；
/// - **权限 0600**：设置文件里可能有用户填的 key，**强制**只有本人可读写；
/// - **符号链接不替换**。
public final class MetadataSettingsStore {
    /// 载入状态。
    public enum LoadState: Equatable {
        /// 文件不存在（首次运行）。
        case missing
        /// 正常载入。
        case loaded
        /// 文件损坏：保留原文件、拒绝写入。
        case corrupt(String)
        /// 文件读不出来：保留原文件、拒绝写入。
        case unreadable(String)

        /// 是否允许写入。
        public var isWritable: Bool {
            switch self {
            case .missing, .loaded: return true
            case .corrupt, .unreadable: return false
            }
        }
    }

    /// 存储错误。
    public enum StoreError: Error, CustomStringConvertible {
        /// 文件损坏（解析失败）。
        case corrupt(String)
        /// 文件读不出来（权限 / IO）。
        case unreadable(String)
        /// 写入失败（原文件未改动）。
        case writeFailed(String)
        /// 与磁盘现状冲突（被外部改过）。
        case conflict(String)
        /// 拒绝写入（保护原文件 / 拒绝替换符号链接）。
        case refused(String)
        /// 另一个进程正持有写锁（有界等待超时）。
        case locked(String)

        public var description: String {
            switch self {
            case .corrupt(let message): return "设置文件损坏：\(message)"
            case .unreadable(let message): return "设置文件无法读取：\(message)"
            case .writeFailed(let message): return "设置写入失败：\(message)"
            case .conflict(let message): return "设置冲突：\(message)"
            case .refused(let message): return "设置拒绝写入：\(message)"
            case .locked(let message): return "设置正被其它进程写入：\(message)"
            }
        }
    }

    /// 默认文件名（放在数据根目录下，**独立于 `native.json`**）。
    public static let fileName = "metadata-settings.json"

    /// 数据根目录下的默认设置文件路径。
    public static func defaultFileURL(dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent(fileName, isDirectory: false)
    }

    public let fileURL: URL

    /// 载入状态。
    public private(set) var loadState: LoadState

    /// 载入问题描述（损坏 / 读失败时非空）。
    public private(set) var loadIssue: String?

    /// 等待跨进程写锁的上限（秒）。
    public let lockTimeout: TimeInterval

    private let lock = NSLock()
    private var state: MetadataSettings = MetadataSettings()
    /// 载入时的磁盘指纹；保存前必须与当前指纹一致。
    private var baseline: FileFingerprint = .missing

    public init(fileURL: URL, lockTimeout: TimeInterval = 5) {
        self.fileURL = fileURL
        self.lockTimeout = lockTimeout
        let loaded = MetadataSettingsStore.read(fileURL: fileURL)
        self.loadState = loaded.state
        self.state = loaded.settings
        self.baseline = loaded.fingerprint
        self.loadIssue = loaded.issue
    }

    // MARK: 读取

    /// 当前设置（快照）。
    public var settings: MetadataSettings {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    /// 重新载入磁盘内容（用户在外部修好损坏文件后调用）。
    @discardableResult
    public func reload() -> LoadState {
        lock.lock()
        defer { lock.unlock() }
        let loaded = MetadataSettingsStore.read(fileURL: fileURL)
        loadState = loaded.state
        state = loaded.settings
        baseline = loaded.fingerprint
        loadIssue = loaded.issue
        return loadState
    }

    // MARK: 写入

    /// 保存设置（**先落盘成功、再发布内存**）。
    ///
    /// - Throws: 载入有问题、磁盘被外部改过、锁被占用或写入失败时抛出，
    ///   内存与磁盘都保持原样。
    public func save(_ settings: MetadataSettings) throws {
        lock.lock()
        defer { lock.unlock() }
        try ensureWritableLocked()
        let committed = try persistLocked(settings)
        // 基线 = 本次提交的指纹，**不再重新采集路径**。
        baseline = committed
        state = settings
        loadState = .loaded
        loadIssue = nil
    }

    // MARK: 内部

    private func ensureWritableLocked() throws {
        switch loadState {
        case .missing, .loaded:
            return
        case .corrupt(let reason):
            throw StoreError.refused("设置文件已损坏，保留原文件并拒绝写入：\(reason)")
        case .unreadable(let reason):
            throw StoreError.refused("设置文件无法读取，保留原文件并拒绝写入：\(reason)")
        }
    }

    /// 落盘（**全程持有跨进程写锁**）：检查基线 → 写临时文件 → 原子替换。
    private func persistLocked(_ candidate: MetadataSettings) throws -> FileFingerprint {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw StoreError.writeFailed("创建父目录失败：\(error.localizedDescription)")
        }

        // 协作式写锁：覆盖「检查基线 → 替换提交」全过程。
        let lockURL = CooperativeFileLock.lockURL(for: fileURL)
        let fileLock: CooperativeFileLock
        do {
            fileLock = try CooperativeFileLock.acquire(
                at: lockURL,
                timeout: lockTimeout,
                exclusive: true
            )
        } catch let error as CooperativeFileLock.LockError {
            switch error {
            case .timeout:
                throw StoreError.locked("\(fileURL.lastPathComponent) 正被其它进程写入")
            case .symlinkRefused:
                throw StoreError.refused("锁文件是符号链接，已拒绝：\(lockURL.path)")
            case .notRegularFile:
                throw StoreError.refused("锁文件不是普通文件，已拒绝：\(lockURL.path)")
            case .openFailed(let message):
                throw StoreError.writeFailed("无法获取写锁：\(message)")
            }
        }
        defer { fileLock.release() }

        let current = FileFingerprint.capture(fileURL)
        if current != baseline {
            throw StoreError.conflict(
                "\(fileURL.lastPathComponent) 已被外部创建 / 删除 / 修改，已取消写入以避免覆盖其更改"
            )
        }

        let data: Data
        do {
            data = try JSONEncoder.algerPretty.encode(candidate)
        } catch {
            throw StoreError.writeFailed("设置序列化失败：\(error.localizedDescription)")
        }
        do {
            // **强制 0600**：文件里可能有用户填的 key。
            let commit = try AtomicFile.writeContents(
                data,
                to: fileURL,
                permissions: 0o600,
                preserveExistingPermissions: false
            )
            return commit.fingerprint
        } catch let error as AtomicFileError {
            switch error {
            case .symlinkRefused:
                throw StoreError.refused("设置文件路径是符号链接，已拒绝替换：\(fileURL.path)")
            default:
                throw StoreError.writeFailed("原文件未改动：\(error.description)")
            }
        }
    }

    private static func read(
        fileURL: URL
    ) -> (state: LoadState, settings: MetadataSettings, fingerprint: FileFingerprint, issue: String?) {
        // **内容与指纹来自同一次打开**（同一快照），不会出现指纹与内容错配。
        let snapshot = FileReader.snapshot(fileURL)
        switch snapshot.fingerprint {
        case .missing:
            return (.missing, MetadataSettings(), .missing, nil)
        case .unreadable(let reason):
            return (
                .unreadable(reason),
                MetadataSettings(),
                snapshot.fingerprint,
                "设置文件无法读取（\(reason)），已保留原文件并拒绝写入"
            )
        case .present:
            guard let data = snapshot.contents else {
                return (
                    .unreadable("无法读取设置文件内容"),
                    MetadataSettings(),
                    snapshot.fingerprint,
                    "设置文件无法读取，已保留原文件并拒绝写入"
                )
            }
            do {
                let settings = try JSONDecoder().decode(MetadataSettings.self, from: data)
                return (.loaded, settings, snapshot.fingerprint, nil)
            } catch {
                return (
                    .corrupt(error.localizedDescription),
                    MetadataSettings(),
                    snapshot.fingerprint,
                    "设置文件已损坏（\(error.localizedDescription)），已保留原文件并拒绝写入"
                )
            }
        }
    }
}
