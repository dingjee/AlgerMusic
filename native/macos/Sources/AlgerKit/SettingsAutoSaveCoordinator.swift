import Combine
import Foundation

// MARK: - 设置值

/// 设置界面值（**权威副本**）。
///
/// 界面上的每个控件都直接绑定到这里；协调器据此算出
/// **只含改动字段** 的提交内容（绝不拿整份旧快照覆盖别的字段）。
public struct SettingsValues: Equatable {

    /// 音质。
    public var quality: String
    /// 音源（**保持优先顺序**，不是无序集合）。
    public var sources: [String]
    /// 下载目录。
    public var downloadDirectory: String
    /// 歌单目录（M3U8 存放处）。
    public var playlistsDirectory: String
    /// 参与扫描的音乐目录。
    public var libraryFolders: [String]
    /// 完整在线播放后自动保存。
    public var autoSaveEnabled: Bool
    /// 自动保存阈值（完整在线播放次数）。
    public var autoSaveThreshold: Int
    /// 是否隐藏网络歌单分组。
    public var hideRemotePlaylists: Bool

    public init(
        quality: String = "higher",
        sources: [String] = [],
        downloadDirectory: String = "",
        playlistsDirectory: String = "",
        libraryFolders: [String] = [],
        autoSaveEnabled: Bool = true,
        autoSaveThreshold: Int = 3,
        hideRemotePlaylists: Bool = false
    ) {
        self.quality = quality
        self.sources = sources
        self.downloadDirectory = downloadDirectory
        self.playlistsDirectory = playlistsDirectory
        self.libraryFolders = libraryFolders
        self.autoSaveEnabled = autoSaveEnabled
        self.autoSaveThreshold = autoSaveThreshold
        self.hideRemotePlaylists = hideRemotePlaylists
    }
}

/// 改动紧急度。
public enum SettingsUrgency: Equatable {
    /// **立即保存**（控件切换、目录选择）。
    case immediate
    /// **防抖后保存**（文本输入：停顿或回车提交）。
    case debounced
}

// MARK: - 补丁

/// 原生侧改动（**只含改动字段**；`nil` = 不提交该字段）。
public struct NativeSettingsChanges: Equatable {

    /// 歌单目录。
    public var playlistsDirectory: String?
    /// 音乐目录。
    public var libraryFolders: [String]?
    /// 下载目录。
    public var downloadDirectory: String?
    /// 自动保存开关。
    public var autoSaveEnabled: Bool?
    /// 自动保存阈值。
    public var autoSaveThreshold: Int?
    /// 是否隐藏网络歌单分组。
    public var hideRemotePlaylists: Bool?

    public init(
        playlistsDirectory: String? = nil,
        libraryFolders: [String]? = nil,
        downloadDirectory: String? = nil,
        autoSaveEnabled: Bool? = nil,
        autoSaveThreshold: Int? = nil,
        hideRemotePlaylists: Bool? = nil
    ) {
        self.playlistsDirectory = playlistsDirectory
        self.libraryFolders = libraryFolders
        self.downloadDirectory = downloadDirectory
        self.autoSaveEnabled = autoSaveEnabled
        self.autoSaveThreshold = autoSaveThreshold
        self.hideRemotePlaylists = hideRemotePlaylists
    }

    /// 是否没有任何可提交内容。
    public var isEmpty: Bool {
        playlistsDirectory == nil
            && libraryFolders == nil
            && downloadDirectory == nil
            && autoSaveEnabled == nil
            && autoSaveThreshold == nil
            && hideRemotePlaylists == nil
    }
}

/// 设置补丁计算（**纯逻辑**，可单测）。
public enum SettingsPatch {

    /// 会话侧补丁：基线来自真实会话快照。
    ///
    /// - 基线未知 → **不提交** 音质 / 音源（绝不拿默认值覆盖真实设置）；
    /// - 下载目录为空 → **不提交**（保留原值）。
    public static func session(
        values: SettingsValues,
        baseline: SettingsBaseline
    ) -> SettingsChanges {
        SettingsDraft.changes(
            baseline: baseline,
            quality: values.quality,
            sources: values.sources,
            downloadDirectory: trimmed(values.downloadDirectory)
        )
    }

    /// 原生侧补丁：基线来自本地设置（`native.json`）。
    ///
    /// - 歌单 / 下载目录为空 → **不提交**（保留原值，不把空目录写进设置）；
    /// - 其余字段只在 **真的改动** 时提交（不拿整份快照覆盖别的字段）。
    public static func native(
        values: SettingsValues,
        baseline: NativeSettings
    ) -> NativeSettingsChanges {
        var changes = NativeSettingsChanges()

        let playlists = trimmed(values.playlistsDirectory)
        if !playlists.isEmpty && playlists != baseline.playlistsDirectory {
            changes.playlistsDirectory = playlists
        }
        if values.libraryFolders != baseline.libraryFolders {
            changes.libraryFolders = values.libraryFolders
        }
        let download = trimmed(values.downloadDirectory)
        if !download.isEmpty && download != baseline.downloadDirectory {
            changes.downloadDirectory = download
        }
        if values.autoSaveEnabled != baseline.autoSaveEnabled {
            changes.autoSaveEnabled = values.autoSaveEnabled
        }
        if values.autoSaveThreshold != baseline.autoSaveThreshold {
            changes.autoSaveThreshold = max(1, values.autoSaveThreshold)
        }
        if values.hideRemotePlaylists != baseline.hideRemotePlaylists {
            changes.hideRemotePlaylists = values.hideRemotePlaylists
        }
        return changes
    }

    /// 去掉首尾空白（目录里手抖多打的空格不该进设置）。
    static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 落盘接口

/// 设置落盘接口（**可注入**，测试用确定性假实现）。
///
/// 约定：
/// - `nil` = **不提交**该字段（绝不整份覆盖）；
/// - 抛错 = **没有落盘**（调用方不得当成成功）。
@MainActor
public protocol SettingsPersistence: AnyObject {

    /// 提交会话侧设置（音质 / 音源 / 下载目录）。
    func applySession(
        quality: String?,
        sources: [String]?,
        downloadDirectory: String?
    ) async throws

    /// 提交原生侧设置（歌单目录 / 音乐目录 / 下载目录 / 自动保存 / 隐藏网络歌单）。
    func applyNative(
        playlistsDirectory: String?,
        libraryFolders: [String]?,
        downloadDirectory: String?,
        autoSaveEnabled: Bool?,
        autoSaveThreshold: Int?,
        hideRemotePlaylists: Bool?
    ) async throws

    /// 读回真实会话快照（**用来核验真的落盘了**，不是假成功）。
    func readSessionSnapshot() async throws -> SessionSnapshot
}

/// 基于真实运行环境（桥接 + 原生状态存储）的落盘实现。
@MainActor
public final class EnvironmentSettingsPersistence: SettingsPersistence {

    private let bridge: BridgeService
    private let store: NativeStore

    public init(environment: AlgerEnvironment) {
        self.bridge = environment.bridge
        self.store = environment.store
    }

    public init(bridge: BridgeService, store: NativeStore) {
        self.bridge = bridge
        self.store = store
    }

    public func applySession(
        quality: String?,
        sources: [String]?,
        downloadDirectory: String?
    ) async throws {
        // **只提交改动字段**：Rust 侧同样是读改写事务，没带的字段原样保留。
        try await bridge.updateSettings(
            quality: quality,
            sources: sources,
            downloadDirectory: downloadDirectory
        )
    }

    public func applyNative(
        playlistsDirectory: String?,
        libraryFolders: [String]?,
        downloadDirectory: String?,
        autoSaveEnabled: Bool?,
        autoSaveThreshold: Int?,
        hideRemotePlaylists: Bool?
    ) async throws {
        try store.mutate { state in
            if let playlistsDirectory { state.settings.playlistsDirectory = playlistsDirectory }
            if let libraryFolders { state.settings.libraryFolders = libraryFolders }
            if let downloadDirectory { state.settings.downloadDirectory = downloadDirectory }
            if let autoSaveEnabled { state.settings.autoSaveEnabled = autoSaveEnabled }
            if let autoSaveThreshold { state.settings.autoSaveThreshold = max(1, autoSaveThreshold) }
            if let hideRemotePlaylists { state.settings.hideRemotePlaylists = hideRemotePlaylists }
        }
    }

    public func readSessionSnapshot() async throws -> SessionSnapshot {
        try await bridge.sessionSnapshot()
    }
}

// MARK: - 错误

/// 设置保存错误。
public enum SettingsSaveError: Error, CustomStringConvertible {

    /// 写完之后读回的值与提交值不一致（**没有假成功**）。
    case verificationFailed(String)

    public var description: String {
        switch self {
        case .verificationFailed(let message):
            return "保存后核验不一致：\(message)"
        }
    }
}

// MARK: - 协调器

/// 设置自动保存协调器（**随改随存**，macOS 习惯，没有「保存」按钮）。
///
/// 关键约定：
/// - **控件 / 目录立即保存**，**文本防抖后保存**（停顿或回车提交）；
/// - **串行合并**：同一时间只有一次提交在途，期间的改动 **合并** 进下一轮，
///   旧请求 **不会** 覆盖新值（提交内容在 **发送前** 才计算）；
/// - **只提交改动字段**：没改音质就不提交音质，绝不发送整份过期快照；
/// - **载入不触发保存**：基线由 `prime(session:native:)` 建立；
/// - **基线未知不提交音质 / 音源**（会话没载入成功时绝不覆盖真实设置）；
/// - **失败明确可重试**：失败保留待保存内容并显示真实原因，**绝不假装成功**；
/// - 保存之后 **读回真实快照核验**：写进去 ≠ 真的生效（不生效就是失败）。
@MainActor
public final class SettingsAutoSaveCoordinator: ObservableObject {

    // MARK: 对外状态

    /// 保存状态。
    public enum Status: Equatable {
        /// 没有待保存的内容。
        case idle
        /// 正在保存。
        case saving
        /// 保存失败（**可重试**；`message` 是真实原因）。
        case failed(String)
    }

    /// 当前界面值（**权威副本**）。
    @Published public private(set) var values = SettingsValues()
    /// 保存状态。
    @Published public private(set) var status: Status = .idle
    /// 最近一次 **成功** 保存的时间（`nil` = 还没成功保存过）。
    @Published public private(set) var lastSavedAt: Date?
    /// 最近一次保存失败的原因（`nil` = 没有失败）。
    @Published public private(set) var failureMessage: String?
    /// 最近一次「无法提交」的说明（例如目录被清空）。
    @Published public private(set) var rejectionMessage: String?

    /// 会话基线是否已知（**未知 → 音质 / 音源不提交**）。
    public var isSessionBaselineKnown: Bool { sessionBaseline.isKnown }

    /// 保存成功的回调（说明这次真正落盘了什么，界面据此刷新数据）。
    public var onSaved: ((SaveSummary) -> Void)?

    /// 一次保存真正落盘了什么。
    public struct SaveSummary: Equatable {
        /// 会话侧（音质 / 音源 / 下载目录）已落盘并核验通过。
        public var sessionApplied: Bool
        /// 原生侧（歌单目录 / 音乐目录 / 自动保存 / 隐藏网络歌单）已落盘。
        public var nativeApplied: Bool
        /// 音乐目录变了（界面需要刷新资料库）。
        public var libraryFoldersChanged: Bool

        public init(
            sessionApplied: Bool = false,
            nativeApplied: Bool = false,
            libraryFoldersChanged: Bool = false
        ) {
            self.sessionApplied = sessionApplied
            self.nativeApplied = nativeApplied
            self.libraryFoldersChanged = libraryFoldersChanged
        }
    }

    // MARK: 内部状态

    private var persistence: SettingsPersistence?
    /// 会话基线（真实会话快照；**只对照它判断改动**）。
    private var sessionBaseline: SettingsBaseline = .unknown
    /// 原生侧基线（`native.json` 的设置段）。
    private var nativeBaseline = NativeSettings()
    /// 文本防抖间隔（秒）。
    private let debounceInterval: TimeInterval
    /// 在途的保存任务（**串行**：同一时间只有一个）。
    private var saveTask: Task<Void, Never>?
    /// 在途的防抖任务。
    private var debounceTask: Task<Void, Never>?
    /// 原生侧基线是否已经建立。
    private var didPrimeNative = false
    /// 会话基线是否已经建立。
    private var didPrimeSession = false
    /// 上一轮保存是否失败（失败后 **不自动重试**，等用户点「重试」）。
    private var didFailLastRun = false
    /// 音源被拒绝的说明（空音源列表）。
    private var sourcesRejection: String?

    // MARK: 初始化

    /// 建立协调器。
    ///
    /// - Parameters:
    ///   - persistence: 落盘实现（`nil` = 稍后用 `attach(persistence:)` 挂上）。
    ///   - debounceInterval: 文本输入的防抖间隔（秒）。
    public init(persistence: SettingsPersistence? = nil, debounceInterval: TimeInterval = 0.6) {
        self.persistence = persistence
        self.debounceInterval = debounceInterval
    }

    deinit {
        debounceTask?.cancel()
        saveTask?.cancel()
    }

    /// 挂上落盘实现（界面在拿到运行环境后才挂）。
    ///
    /// 挂上时如果已经有待保存内容（例如挂之前用户已经改了东西），立刻补一次保存。
    public func attach(persistence: SettingsPersistence) {
        self.persistence = persistence
        if hasPendingChanges {
            startSave()
        }
    }

    // MARK: 载入（**不触发保存**）

    /// 建立基线（**载入不触发保存**）。
    ///
    /// - 会话基线只在 **第一次** 有真实快照时建立：会话在后台刷新 **不会**
    ///   覆盖用户正在编辑的值，也不会把真实设置当成「改动」提交出去；
    /// - 原生侧基线取自本地设置（`native.json`）。
    public func prime(session snapshot: SessionSnapshot?, native nativeSettings: NativeSettings) {
        if !didPrimeNative {
            didPrimeNative = true
            nativeBaseline = nativeSettings
            values.playlistsDirectory = nativeSettings.playlistsDirectory
            values.libraryFolders = nativeSettings.libraryFolders
            values.autoSaveEnabled = nativeSettings.autoSaveEnabled
            values.autoSaveThreshold = nativeSettings.autoSaveThreshold
            values.hideRemotePlaylists = nativeSettings.hideRemotePlaylists
        }
        if let snapshot, !didPrimeSession {
            didPrimeSession = true
            sessionBaseline = SettingsBaseline(snapshot: snapshot)
            if !snapshot.quality.isEmpty {
                values.quality = snapshot.quality
            }
            // 音源 **保持上游顺序**。
            values.sources = snapshot.sources
            if !snapshot.downloadDirectory.isEmpty {
                values.downloadDirectory = snapshot.downloadDirectory
                // 下载目录是 **同一个** 用户设置：两侧基线对齐，
                // 否则第一次保存会顺手把本地那份改成会话那份（不是用户要的改动）。
                nativeBaseline.downloadDirectory = snapshot.downloadDirectory
            }
        }
        updateRejectionMessage()
    }

    // MARK: 改动入口

    /// 改音质（控件 → **立即保存**）。
    public func setQuality(_ value: String) {
        guard value != values.quality else { return }
        values.quality = value
        schedule(.immediate)
    }

    /// 改音源（控件 → **立即保存**；**保持优先顺序**）。
    ///
    /// 音源不能为空：桥接侧会忽略空列表（等于什么都没改），
    /// 这里直接拒绝并保留原值，避免「看起来改了、其实没改」。
    public func setSources(_ value: [String]) {
        if value.isEmpty {
            sourcesRejection = "至少需要保留一个音源（已保留原顺序）"
            updateRejectionMessage()
            return
        }
        guard value != values.sources else { return }
        values.sources = value
        sourcesRejection = nil
        updateRejectionMessage()
        schedule(.immediate)
    }

    /// 改下载目录（文本 → 防抖；目录选择 → 立即）。
    public func setDownloadDirectory(_ value: String, urgency: SettingsUrgency = .debounced) {
        guard value != values.downloadDirectory else { return }
        values.downloadDirectory = value
        updateRejectionMessage()
        schedule(urgency)
    }

    /// 改歌单目录（文本 → 防抖；目录选择 → 立即）。
    public func setPlaylistsDirectory(_ value: String, urgency: SettingsUrgency = .debounced) {
        guard value != values.playlistsDirectory else { return }
        values.playlistsDirectory = value
        updateRejectionMessage()
        schedule(urgency)
    }

    /// 改音乐目录（控件 → **立即保存**）。
    public func setLibraryFolders(_ value: [String]) {
        guard value != values.libraryFolders else { return }
        values.libraryFolders = value
        schedule(.immediate)
    }

    /// 改自动保存开关（控件 → **立即保存**）。
    public func setAutoSaveEnabled(_ value: Bool) {
        guard value != values.autoSaveEnabled else { return }
        values.autoSaveEnabled = value
        schedule(.immediate)
    }

    /// 改自动保存阈值（控件 → **立即保存**）。
    public func setAutoSaveThreshold(_ value: Int) {
        let clamped = max(1, value)
        guard clamped != values.autoSaveThreshold else { return }
        values.autoSaveThreshold = clamped
        schedule(.immediate)
    }

    /// 改「隐藏网络歌单」（控件 → **立即保存**）。
    public func setHideRemotePlaylists(_ value: Bool) {
        guard value != values.hideRemotePlaylists else { return }
        values.hideRemotePlaylists = value
        schedule(.immediate)
    }

    /// 提交文本（回车 / 失焦）：立刻把待保存内容写下去。
    public func commitPendingText() {
        cancelDebounce()
        guard hasPendingChanges else { return }
        startSave()
    }

    /// 离开界面前把待保存内容写下去（不能因为视图销毁而丢掉改动）。
    public func flush() {
        cancelDebounce()
        guard hasPendingChanges else { return }
        startSave()
    }

    /// 重试失败的那次保存（失败后 **保留** 待保存内容，等用户点这个）。
    public func retry() {
        failureMessage = nil
        status = .idle
        guard hasPendingChanges else { return }
        startSave()
    }

    // MARK: 内部

    /// 是否还有待保存的内容。
    private var hasPendingChanges: Bool {
        !currentSessionChanges().isEmpty || !currentNativeChanges().isEmpty
    }

    /// 当前会话侧改动（**发送前才算**，保证提交的是最新值）。
    private func currentSessionChanges() -> SettingsChanges {
        SettingsPatch.session(values: values, baseline: sessionBaseline)
    }

    /// 当前原生侧改动。
    private func currentNativeChanges() -> NativeSettingsChanges {
        SettingsPatch.native(values: values, baseline: nativeBaseline)
    }

    /// 更新「无法提交」的说明（目录被清空等）。
    private func updateRejectionMessage() {
        var messages: [String] = []
        let download = SettingsPatch.trimmed(values.downloadDirectory)
        if download.isEmpty && !sessionBaseline.downloadDirectory.isEmpty {
            messages.append("下载目录不能为空，已保留原值「\(sessionBaseline.downloadDirectory)」")
        }
        let playlists = SettingsPatch.trimmed(values.playlistsDirectory)
        if playlists.isEmpty && !nativeBaseline.playlistsDirectory.isEmpty {
            messages.append("歌单目录不能为空，已保留原值「\(nativeBaseline.playlistsDirectory)」")
        }
        if let sourcesRejection {
            messages.append(sourcesRejection)
        }
        rejectionMessage = messages.isEmpty ? nil : messages.joined(separator: "；")
    }

    /// 安排保存。
    private func schedule(_ urgency: SettingsUrgency) {
        guard persistence != nil else {
            // 还没挂上落盘实现：改动先记在 `values` 里，
            // `attach(persistence:)` 时会补一次保存（不会丢）。
            return
        }
        switch urgency {
        case .immediate:
            cancelDebounce()
            startSave()
        case .debounced:
            cancelDebounce()
            let interval = debounceInterval
            debounceTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.startSave()
            }
        }
    }

    private func cancelDebounce() {
        debounceTask?.cancel()
        debounceTask = nil
    }

    /// 启动保存（**串行**：已有在途任务时不并发，等它结束后由循环继续）。
    private func startSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [self] in
            await runSaveLoop()
            saveTask = nil
            // 收尾期间又来了新改动 → 立刻再跑一轮（不能丢）。
            if !didFailLastRun && hasPendingChanges {
                startSave()
            }
        }
    }

    /// 保存循环：一直合并到 **没有待保存内容** 为止。
    private func runSaveLoop() async {
        didFailLastRun = false
        while true {
            let sessionChanges = currentSessionChanges()
            let nativeChanges = currentNativeChanges()
            guard !sessionChanges.isEmpty || !nativeChanges.isEmpty else {
                status = .idle
                updateRejectionMessage()
                return
            }

            status = .saving
            var summary = SaveSummary()
            var failures: [String] = []

            // 1) 原生侧落盘（本地、快、不依赖网络）。
            //    **两侧互相独立**：一侧失败不阻断另一侧（否则磁盘只读会连音质都改不了）。
            if !nativeChanges.isEmpty {
                do {
                    try await persistence?.applyNative(
                        playlistsDirectory: nativeChanges.playlistsDirectory,
                        libraryFolders: nativeChanges.libraryFolders,
                        downloadDirectory: nativeChanges.downloadDirectory,
                        autoSaveEnabled: nativeChanges.autoSaveEnabled,
                        autoSaveThreshold: nativeChanges.autoSaveThreshold,
                        hideRemotePlaylists: nativeChanges.hideRemotePlaylists
                    )
                    advanceNativeBaseline(nativeChanges)
                    summary.nativeApplied = true
                    summary.libraryFoldersChanged = nativeChanges.libraryFolders != nil
                } catch {
                    failures.append("保存本地设置失败：\(Self.describe(error))")
                }
            }

            // 2) 会话侧（桥接）：提交后 **读回核验**，写进去 ≠ 真的生效。
            if !sessionChanges.isEmpty {
                do {
                    try await persistence?.applySession(
                        quality: sessionChanges.quality,
                        sources: sessionChanges.sources,
                        downloadDirectory: sessionChanges.downloadDirectory
                    )
                    let snapshot = try await persistence?.readSessionSnapshot()
                    if let snapshot {
                        try Self.verify(snapshot: snapshot, against: sessionChanges)
                    }
                    advanceSessionBaseline(sessionChanges)
                    summary.sessionApplied = true
                } catch {
                    failures.append("保存会话设置失败：\(Self.describe(error))")
                }
            }

            // 3) 通知界面：这一轮 **真正落盘** 的部分（失败的那一侧不算）。
            //    即使整体失败，已经落盘的那一侧也要刷新（侧栏分组等）。
            onSaved?(summary)

            // 4) 有任何一侧失败 → **明确失败**（不假装成功），保留那一侧的待保存内容。
            if !failures.isEmpty {
                fail(failures.joined(separator: "；"))
                return
            }

            failureMessage = nil
            lastSavedAt = Date()
            updateRejectionMessage()
        }
    }

    /// 记录失败（**保留待保存内容**，等用户重试；绝不假装成功）。
    private func fail(_ message: String) {
        didFailLastRun = true
        failureMessage = message
        status = .failed(message)
    }

    /// 会话侧基线推进（**只推进真正提交成功的字段**）。
    private func advanceSessionBaseline(_ changes: SettingsChanges) {
        if let quality = changes.quality { sessionBaseline.quality = quality }
        if let sources = changes.sources { sessionBaseline.sources = sources }
        if let directory = changes.downloadDirectory { sessionBaseline.downloadDirectory = directory }
    }

    /// 原生侧基线推进。
    private func advanceNativeBaseline(_ changes: NativeSettingsChanges) {
        if let value = changes.playlistsDirectory { nativeBaseline.playlistsDirectory = value }
        if let value = changes.libraryFolders { nativeBaseline.libraryFolders = value }
        if let value = changes.downloadDirectory { nativeBaseline.downloadDirectory = value }
        if let value = changes.autoSaveEnabled { nativeBaseline.autoSaveEnabled = value }
        if let value = changes.autoSaveThreshold { nativeBaseline.autoSaveThreshold = value }
        if let value = changes.hideRemotePlaylists { nativeBaseline.hideRemotePlaylists = value }
    }

    /// 核验：读回的真实值必须与提交值一致，否则 **算失败**（不假成功）。
    static func verify(snapshot: SessionSnapshot, against changes: SettingsChanges) throws {
        if let quality = changes.quality, snapshot.quality != quality {
            throw SettingsSaveError.verificationFailed(
                "音质仍是「\(snapshot.quality)」（提交的是「\(quality)」）"
            )
        }
        if let sources = changes.sources, snapshot.sources != sources {
            throw SettingsSaveError.verificationFailed(
                "音源仍是「\(snapshot.sources.joined(separator: " → "))」（提交的是「\(sources.joined(separator: " → "))」）"
            )
        }
        if let directory = changes.downloadDirectory, snapshot.downloadDirectory != directory {
            throw SettingsSaveError.verificationFailed(
                "下载目录仍是「\(snapshot.downloadDirectory)」（提交的是「\(directory)」）"
            )
        }
    }

    /// 错误描述（**具体原因**，不吞错）。
    static func describe(_ error: Error) -> String {
        if let saveError = error as? SettingsSaveError { return saveError.description }
        if let storeError = error as? NativeStore.StoreError { return storeError.description }
        if let serviceError = error as? BridgeServiceError { return serviceError.description }
        if let bridgeError = error as? BridgeClient.BridgeError { return bridgeError.description }
        if let clientError = error as? BridgeClient.ClientError { return clientError.description }
        // 自定义错误通常带 `description`（比 Foundation 的通用文案具体）。
        if let convertible = error as? CustomStringConvertible { return convertible.description }
        return error.localizedDescription
    }
}
