import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// 原生端持久状态存储（`native.json`）。
///
/// 与 `LibraryIndex` 同一套事务语义（复用 `AtomicFile` / `CooperativeFileLock` /
/// `FileFingerprint`）：
/// - **三种载入状态严格区分**：不存在 → 空状态可写；损坏 / 读失败 → 保留原文件、
///   **拒绝写入**（绝不把「读不出来」当成「不存在」而覆盖用户数据）；
/// - **事务语义**：先落盘成功、再发布内存；写失败时内存与磁盘都不变；
/// - **串行**：所有修改经同一把锁，读改写不会丢更新；
/// - **跨进程写事务**：写入期间持协作式 `flock`（`<native>.lock`）；
/// - **外部修改检测**：保存前比对磁盘指纹，被外部改过就报冲突，绝不覆盖；
/// - **基线只来自本次提交**：保存成功后基线 = 提交字节 + 同一临时 fd 的 fstat，
///   **不重新采集路径** → 外部在提交之后的改写不会被吸收进基线；
/// - **不含凭证**：这里不写 Cookie，登录态始终在 Rust 侧 `session.json`。
public final class NativeStore {
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
            case .corrupt(let message): return "应用数据损坏：\(message)"
            case .unreadable(let message): return "应用数据无法读取：\(message)"
            case .writeFailed(let message): return "应用数据写入失败：\(message)"
            case .conflict(let message): return "应用数据冲突：\(message)"
            case .refused(let message): return "应用数据拒绝写入：\(message)"
            case .locked(let message): return "应用数据正被其它进程写入：\(message)"
            }
        }
    }

    /// 载入状态。
    public enum LoadState: Equatable {
        case missing
        case loaded
        case corrupt(String)
        case unreadable(String)

        /// 是否允许写入。
        public var isWritable: Bool {
            switch self {
            case .missing, .loaded: return true
            case .corrupt, .unreadable: return false
            }
        }
    }

    public let fileURL: URL

    /// 载入状态。
    public private(set) var loadState: LoadState

    /// 载入问题描述（损坏 / 读失败时非空）。
    public private(set) var loadIssue: String?

    /// 等待跨进程写锁的上限（秒）。
    public let lockTimeout: TimeInterval

    private let lock = NSLock()
    private var state: NativeState
    /// 载入时的磁盘指纹；保存前必须与当前指纹一致。
    private var baseline: FileFingerprint = .missing

    public init(fileURL: URL, lockTimeout: TimeInterval = 5) {
        self.fileURL = fileURL
        self.lockTimeout = lockTimeout
        let loaded = NativeStore.read(fileURL: fileURL)
        self.loadState = loaded.state
        self.state = loaded.value
        self.baseline = loaded.fingerprint
        self.loadIssue = loaded.issue
    }

    // MARK: - 读取

    /// 当前状态（快照）。
    public var current: NativeState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    /// 重新载入磁盘内容（用户外部修好损坏文件后调用）。
    @discardableResult
    public func reload() -> LoadState {
        lock.lock()
        defer { lock.unlock() }
        let loaded = NativeStore.read(fileURL: fileURL)
        loadState = loaded.state
        state = loaded.value
        baseline = loaded.fingerprint
        loadIssue = loaded.issue
        return loadState
    }

    // MARK: - 修改（事务式）

    /// 事务式修改：在副本上执行闭包，**落盘成功后才发布到内存**。
    ///
    /// - Throws: 载入有问题、磁盘被外部改过、锁被占用或写入失败时抛出；
    ///   内存与磁盘都保持原样。
    public func mutate(_ body: (inout NativeState) throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        try ensureWritableLocked()
        var candidate = state
        try body(&candidate)
        let committed = try persistLocked(candidate)
        state = candidate
        baseline = committed
    }

    /// 把当前内存内容落盘（与外部修改冲突时报错）。
    public func save() throws {
        lock.lock()
        defer { lock.unlock() }
        try ensureWritableLocked()
        baseline = try persistLocked(state)
    }

    // MARK: - 内部

    private func ensureWritableLocked() throws {
        switch loadState {
        case .missing, .loaded:
            return
        case .corrupt(let reason):
            throw StoreError.refused("应用数据已损坏，保留原文件并拒绝写入：\(reason)")
        case .unreadable(let reason):
            throw StoreError.refused("应用数据无法读取，保留原文件并拒绝写入：\(reason)")
        }
    }

    private func persistLocked(_ candidate: NativeState) throws -> FileFingerprint {
        try ensureDirectoryExists()

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
            throw StoreError.writeFailed("应用数据序列化失败：\(error.localizedDescription)")
        }
        do {
            let commit = try AtomicFile.writeContents(data, to: fileURL, permissions: 0o600)
            return commit.fingerprint
        } catch let error as AtomicFileError {
            switch error {
            case .symlinkRefused:
                throw StoreError.refused("应用数据路径是符号链接，已拒绝替换：\(fileURL.path)")
            default:
                throw StoreError.writeFailed("原文件未改动：\(error.description)")
            }
        }
    }

    private func ensureDirectoryExists() throws {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw StoreError.writeFailed("创建父目录失败：\(error.localizedDescription)")
        }
    }

    private static func read(
        fileURL: URL
    ) -> (state: LoadState, value: NativeState, fingerprint: FileFingerprint, issue: String?) {
        let snapshot = FileReader.snapshot(fileURL)
        switch snapshot.fingerprint {
        case .missing:
            return (.missing, NativeState(), .missing, nil)
        case .unreadable(let reason):
            return (
                .unreadable(reason),
                NativeState(),
                snapshot.fingerprint,
                "应用数据无法读取（\(reason)），已保留原文件并拒绝写入"
            )
        case .present:
            guard let data = snapshot.contents else {
                return (
                    .unreadable("无法读取应用数据内容"),
                    NativeState(),
                    snapshot.fingerprint,
                    "应用数据无法读取，已保留原文件并拒绝写入"
                )
            }
            do {
                let value = try JSONDecoder().decode(NativeState.self, from: data)
                return (.loaded, value, snapshot.fingerprint, nil)
            } catch {
                return (
                    .corrupt(error.localizedDescription),
                    NativeState(),
                    snapshot.fingerprint,
                    "应用数据解析失败（\(error.localizedDescription)）；已保留原文件并拒绝写入"
                )
            }
        }
    }
}
