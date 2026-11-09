import Foundation
import XCTest

@testable import AlgerKit

/// 设置自动保存协调器回归（**随改随存**：串行合并 / 只提交改动字段 / 失败可重试）。
@MainActor
final class SettingsAutoSaveCoordinatorTests: XCTestCase {

    // MARK: - 夹具

    /// 确定性假落盘实现（**不碰真实会话 / 真实文件**）。
    final class FakePersistence: SettingsPersistence {

        struct SessionCall: Equatable {
            var quality: String?
            var sources: [String]?
            var downloadDirectory: String?
        }

        struct NativeCall: Equatable {
            var playlistsDirectory: String?
            var libraryFolders: [String]?
            var downloadDirectory: String?
            var autoSaveEnabled: Bool?
            var autoSaveThreshold: Int?
            var hideRemotePlaylists: Bool?
        }

        private(set) var sessionCalls: [SessionCall] = []
        private(set) var nativeCalls: [NativeCall] = []
        private(set) var snapshotReads = 0
        /// 当前「真实」会话状态。
        var snapshot: SessionSnapshot
        /// 当前「真实」原生设置。
        var nativeSettings = NativeSettings()
        /// 会话侧写入失败。
        var sessionError: Error?
        /// 原生侧写入失败。
        var nativeError: Error?
        /// 写入 **不生效**（模拟桥接静默忽略）。
        var ignoresWrites = false
        /// 每个请求的模拟耗时（秒）。
        var latency: TimeInterval = 0
        /// 观察到的最大并发数（**必须恒为 1**：保存是串行的）。
        private(set) var maxConcurrent = 0
        private var concurrent = 0

        var totalCalls: Int { sessionCalls.count + nativeCalls.count }

        init(snapshot: SessionSnapshot = FakePersistence.makeSnapshot()) {
            self.snapshot = snapshot
        }

        nonisolated static func makeSnapshot(
            quality: String = "higher",
            sources: [String] = ["pyncmd", "gdmusic"],
            downloadDirectory: String = "/Users/me/Music/AlgerMusic"
        ) -> SessionSnapshot {
            SessionSnapshot(
                loggedIn: true,
                hasCookie: true,
                account: nil,
                quality: quality,
                sources: sources,
                downloadDirectory: downloadDirectory,
                sessionPath: "/tmp/session.json",
                loadIssue: nil,
                downloadLoadIssue: nil,
                downloadLastError: nil
            )
        }

        func applySession(
            quality: String?,
            sources: [String]?,
            downloadDirectory: String?
        ) async throws {
            concurrent += 1
            maxConcurrent = max(maxConcurrent, concurrent)
            defer { concurrent -= 1 }

            if latency > 0 {
                try? await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000))
            }
            if let sessionError { throw sessionError }
            sessionCalls.append(
                SessionCall(
                    quality: quality,
                    sources: sources,
                    downloadDirectory: downloadDirectory
                )
            )
            guard !ignoresWrites else { return }
            if let quality { snapshot.quality = quality }
            if let sources { snapshot.sources = sources }
            if let downloadDirectory { snapshot.downloadDirectory = downloadDirectory }
        }

        func applyNative(
            playlistsDirectory: String?,
            libraryFolders: [String]?,
            downloadDirectory: String?,
            autoSaveEnabled: Bool?,
            autoSaveThreshold: Int?,
            hideRemotePlaylists: Bool?
        ) async throws {
            concurrent += 1
            maxConcurrent = max(maxConcurrent, concurrent)
            defer { concurrent -= 1 }

            if latency > 0 {
                try? await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000))
            }
            if let nativeError { throw nativeError }
            nativeCalls.append(
                NativeCall(
                    playlistsDirectory: playlistsDirectory,
                    libraryFolders: libraryFolders,
                    downloadDirectory: downloadDirectory,
                    autoSaveEnabled: autoSaveEnabled,
                    autoSaveThreshold: autoSaveThreshold,
                    hideRemotePlaylists: hideRemotePlaylists
                )
            )
            if let playlistsDirectory { nativeSettings.playlistsDirectory = playlistsDirectory }
            if let libraryFolders { nativeSettings.libraryFolders = libraryFolders }
            if let downloadDirectory { nativeSettings.downloadDirectory = downloadDirectory }
            if let autoSaveEnabled { nativeSettings.autoSaveEnabled = autoSaveEnabled }
            if let autoSaveThreshold { nativeSettings.autoSaveThreshold = autoSaveThreshold }
            if let hideRemotePlaylists { nativeSettings.hideRemotePlaylists = hideRemotePlaylists }
        }

        func readSessionSnapshot() async throws -> SessionSnapshot {
            snapshotReads += 1
            if latency > 0 {
                try? await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000))
            }
            if let sessionError { throw sessionError }
            return snapshot
        }
    }

    private enum TestError: Error, CustomStringConvertible {
        case boom(String)
        var description: String {
            switch self {
            case .boom(let message): return message
            }
        }
    }

    // MARK: - 辅助

    private func makeCoordinator(
        persistence: FakePersistence,
        debounce: TimeInterval = 0.4
    ) -> SettingsAutoSaveCoordinator {
        let coordinator = SettingsAutoSaveCoordinator(debounceInterval: debounce)
        coordinator.attach(persistence: persistence)
        return coordinator
    }

    /// 等到这一轮保存真正结束（不再是 `.saving`）。
    private func waitForSave(
        _ coordinator: SettingsAutoSaveCoordinator,
        _ persistence: FakePersistence,
        atLeastCalls expected: Int = 1,
        timeout: TimeInterval = 5
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if persistence.totalCalls >= expected {
                if case .saving = coordinator.status {
                    try? await Task.sleep(nanoseconds: 2_000_000)
                    continue
                }
                return true
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return false
    }

    /// 等到协调器 **完全收敛**（没有待保存内容）。
    private func waitForConverged(
        _ coordinator: SettingsAutoSaveCoordinator,
        timeout: TimeInterval = 5
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .saving = coordinator.status {
                try? await Task.sleep(nanoseconds: 2_000_000)
                continue
            }
            if case .failed = coordinator.status { return true }
            if coordinator.lastSavedAt != nil { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return false
    }

    /// 等到失败状态出现。
    private func waitForFailure(
        _ coordinator: SettingsAutoSaveCoordinator,
        timeout: TimeInterval = 5
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .failed = coordinator.status { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return false
    }

    // MARK: - 载入不触发保存

    /// 载入（建立基线）**不触发保存**。
    func testPrimeDoesNotTriggerSave() async {
        let persistence = FakePersistence()
        let coordinator = makeCoordinator(persistence: persistence)
        coordinator.prime(
            session: FakePersistence.makeSnapshot(),
            native: NativeSettings(playlistsDirectory: "/Users/me/Playlists")
        )
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(persistence.totalCalls, 0, "载入不是改动，不该提交任何字段")
        XCTAssertEqual(coordinator.status, .idle)
    }

    /// 基线未知（会话没载入）→ **不提交** 音质 / 音源。
    func testUnknownBaselineNeverSubmitsQualityOrSources() async {
        let persistence = FakePersistence()
        let coordinator = makeCoordinator(persistence: persistence)
        coordinator.prime(session: nil, native: NativeSettings())

        coordinator.setQuality("lossless")
        coordinator.setSources(["kugou"])
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(persistence.sessionCalls.isEmpty, "基线未知时不得提交音质 / 音源")
        XCTAssertEqual(coordinator.values.quality, "lossless", "界面值仍然更新（只是不提交）")
        XCTAssertEqual(coordinator.values.sources, ["kugou"])
        XCTAssertFalse(coordinator.isSessionBaselineKnown)
    }

    // MARK: - 控件立即保存

    /// 改音质 → **立即保存**，且 **只提交改动的字段**。
    func testControlChangeSavesImmediatelyWithOnlyChangedField() async throws {
        let persistence = FakePersistence()
        let coordinator = makeCoordinator(persistence: persistence)
        coordinator.prime(session: FakePersistence.makeSnapshot(), native: NativeSettings())

        coordinator.setQuality("lossless")
        let settled = await waitForSave(coordinator, persistence)
        XCTAssertTrue(settled)
        XCTAssertEqual(persistence.sessionCalls.count, 1)
        let call = try XCTUnwrap(persistence.sessionCalls.first)
        XCTAssertEqual(call.quality, "lossless")
        XCTAssertNil(call.sources, "没改音源就不提交音源")
        XCTAssertNil(call.downloadDirectory, "没改目录就不提交目录")
        XCTAssertTrue(persistence.nativeCalls.isEmpty, "没改本地设置就不提交本地设置")
    }

    /// 音源 **保持优先顺序** 提交。
    func testSourceOrderIsPreserved() async throws {
        let persistence = FakePersistence()
        let coordinator = makeCoordinator(persistence: persistence)
        coordinator.prime(session: FakePersistence.makeSnapshot(), native: NativeSettings())

        coordinator.setSources(["kugou", "pyncmd", "migu"])
        let settled = await waitForSave(coordinator, persistence)
        XCTAssertTrue(settled)
        let call = try XCTUnwrap(persistence.sessionCalls.first)
        XCTAssertEqual(call.sources, ["kugou", "pyncmd", "migu"], "音源顺序必须原样提交")
    }

    /// 音源不能为空（空列表会被桥接忽略 = 什么都没改）→ 拒绝并保留原值。
    func testEmptySourcesIsRejected() async {
        let persistence = FakePersistence()
        let coordinator = makeCoordinator(persistence: persistence)
        coordinator.prime(
            session: FakePersistence.makeSnapshot(sources: ["pyncmd", "kugou"]),
            native: NativeSettings()
        )

        coordinator.setSources([])
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(coordinator.values.sources, ["pyncmd", "kugou"], "空音源必须被拒绝")
        XCTAssertNotNil(coordinator.rejectionMessage)
        XCTAssertTrue(persistence.sessionCalls.isEmpty)
    }

    // MARK: - 文本防抖

    /// 文本输入 **防抖**：连续输入只提交一次，且提交的是 **最终值**。
    func testTextChangeIsDebouncedAndMerged() async throws {
        let persistence = FakePersistence()
        let coordinator = makeCoordinator(persistence: persistence, debounce: 0.4)
        coordinator.prime(session: FakePersistence.makeSnapshot(), native: NativeSettings())

        coordinator.setDownloadDirectory("/Volumes/Music/A")
        coordinator.setDownloadDirectory("/Volumes/Music/AlgerMusic")
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(persistence.totalCalls, 0, "防抖窗口内不该提交")

        let settled = await waitForSave(coordinator, persistence)
        XCTAssertTrue(settled)
        XCTAssertEqual(persistence.sessionCalls.count, 1, "连续输入只提交一次")
        let call = try XCTUnwrap(persistence.sessionCalls.first)
        XCTAssertEqual(call.downloadDirectory, "/Volumes/Music/AlgerMusic", "提交的是最终值")
    }

    /// 回车 / 失焦提交：立刻写下去，不等防抖。
    func testCommitPendingTextSavesImmediately() async throws {
        let persistence = FakePersistence()
        let coordinator = makeCoordinator(persistence: persistence, debounce: 5)
        coordinator.prime(session: FakePersistence.makeSnapshot(), native: NativeSettings())

        coordinator.setDownloadDirectory("/Volumes/Music/AlgerMusic")
        coordinator.commitPendingText()
        let settled = await waitForSave(coordinator, persistence)
        XCTAssertTrue(settled)
        XCTAssertEqual(persistence.sessionCalls.count, 1)
    }

    /// 离开界面前 flush：待保存内容不能丢。
    func testFlushPersistsPendingTextChange() async throws {
        let persistence = FakePersistence()
        let coordinator = makeCoordinator(persistence: persistence, debounce: 5)
        coordinator.prime(session: FakePersistence.makeSnapshot(), native: NativeSettings())

        coordinator.setPlaylistsDirectory("/Users/me/Playlists")
        coordinator.flush()
        let settled = await waitForSave(coordinator, persistence)
        XCTAssertTrue(settled)
        XCTAssertEqual(persistence.nativeCalls.count, 1)
        XCTAssertEqual(persistence.nativeCalls.first?.playlistsDirectory, "/Users/me/Playlists")
    }

    // MARK: - 串行合并

    /// 快速连续改动 → **合并成一次提交**（提交的是最终值）。
    func testRapidChangesAreMergedIntoOneSubmit() async throws {
        let persistence = FakePersistence()
        persistence.latency = 0.05
        let coordinator = makeCoordinator(persistence: persistence)
        coordinator.prime(session: FakePersistence.makeSnapshot(), native: NativeSettings())

        coordinator.setQuality("exhigh")
        coordinator.setQuality("lossless")
        coordinator.setQuality("standard")
        let converged = await waitForConverged(coordinator)
        XCTAssertTrue(converged)

        XCTAssertEqual(persistence.maxConcurrent, 1, "保存必须串行，不能并发")
        XCTAssertEqual(persistence.sessionCalls.count, 1, "快速改动应合并成一次提交")
        let call = try XCTUnwrap(persistence.sessionCalls.first)
        XCTAssertEqual(call.quality, "standard", "提交的是最后一次的值")
        XCTAssertEqual(persistence.snapshot.quality, "standard")
    }

    /// 保存途中又改了 → **合并进下一轮**（不丢），旧请求不会覆盖新值。
    func testChangeDuringSaveIsMergedIntoNextRound() async throws {
        let persistence = FakePersistence()
        persistence.latency = 0.08
        let coordinator = makeCoordinator(persistence: persistence)
        coordinator.prime(session: FakePersistence.makeSnapshot(), native: NativeSettings())

        coordinator.setQuality("exhigh")
        // 等第一轮真的发出去了再改（模拟「保存途中又改了」）。
        try? await Task.sleep(nanoseconds: 20_000_000)
        coordinator.setQuality("lossless")

        let converged = await waitForConverged(coordinator)
        XCTAssertTrue(converged)

        XCTAssertEqual(persistence.maxConcurrent, 1, "保存必须串行")
        XCTAssertEqual(persistence.sessionCalls.count, 2, "两轮改动 = 两次提交（不丢不重）")
        XCTAssertEqual(persistence.sessionCalls.first?.quality, "exhigh")
        XCTAssertEqual(persistence.sessionCalls.last?.quality, "lossless")
        XCTAssertEqual(persistence.snapshot.quality, "lossless", "最终值必须是最后一次改动")
    }

    // MARK: - 只提交改动字段

    /// 改歌单目录 → **只提交本地设置**，不动会话。
    func testOnlyChangedSideIsSubmitted() async throws {
        let persistence = FakePersistence()
        let coordinator = makeCoordinator(persistence: persistence)
        coordinator.prime(session: FakePersistence.makeSnapshot(), native: NativeSettings())

        coordinator.setPlaylistsDirectory("/Users/me/Playlists")
        let settled = await waitForSave(coordinator, persistence)
        XCTAssertTrue(settled)

        XCTAssertTrue(persistence.sessionCalls.isEmpty, "没改会话设置就不提交会话")
        XCTAssertEqual(persistence.nativeCalls.count, 1)
        let call = try XCTUnwrap(persistence.nativeCalls.first)
        XCTAssertEqual(call.playlistsDirectory, "/Users/me/Playlists")
        XCTAssertNil(call.libraryFolders, "没改音乐目录就不提交音乐目录")
        XCTAssertNil(call.autoSaveEnabled, "没改开关就不提交开关")
        XCTAssertNil(call.downloadDirectory, "没改下载目录就不提交下载目录")
    }

    /// 同一个值不重复提交（基线推进后不再重复写）。
    func testSameValueIsNotResubmitted() async {
        let persistence = FakePersistence()
        let coordinator = makeCoordinator(persistence: persistence)
        coordinator.prime(session: FakePersistence.makeSnapshot(), native: NativeSettings())

        coordinator.setAutoSaveEnabled(false)
        let settled = await waitForSave(coordinator, persistence)
        XCTAssertTrue(settled)
        coordinator.setAutoSaveEnabled(false)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(persistence.nativeCalls.count, 1, "同样的值不该重复提交")
    }

    // MARK: - 拒绝（不假成功）

    /// 下载目录清空 → **不提交**（保留原值）并明确说明。
    func testEmptyDownloadDirectoryIsRejected() async {
        let persistence = FakePersistence()
        let coordinator = makeCoordinator(persistence: persistence, debounce: 5)
        coordinator.prime(session: FakePersistence.makeSnapshot(), native: NativeSettings())

        coordinator.setDownloadDirectory("")
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(persistence.sessionCalls.isEmpty, "空目录不该被提交")
        XCTAssertTrue(persistence.nativeCalls.isEmpty)
        XCTAssertNotNil(coordinator.rejectionMessage, "必须明确说明没有保存")
        XCTAssertEqual(coordinator.status, .idle)
    }

    // MARK: - 失败可重试

    /// 保存失败 → **明确失败**（不假装成功），保留待保存内容，可重试。
    func testFailureIsReportedAndCanBeRetried() async throws {
        let persistence = FakePersistence()
        persistence.sessionError = TestError.boom("桥接不可用")
        let coordinator = makeCoordinator(persistence: persistence)
        coordinator.prime(session: FakePersistence.makeSnapshot(), native: NativeSettings())

        coordinator.setQuality("lossless")
        let failed = await waitForFailure(coordinator)
        XCTAssertTrue(failed)

        guard case .failed(let message) = coordinator.status else {
            return XCTFail("保存失败必须显示失败状态，实际：\(coordinator.status)")
        }
        XCTAssertTrue(message.contains("桥接不可用"), "失败原因必须具体：\(message)")
        XCTAssertNotNil(coordinator.failureMessage)
        XCTAssertNil(coordinator.lastSavedAt, "失败不能算已保存")

        // 修好后重试：这次必须真的落盘。
        persistence.sessionError = nil
        coordinator.retry()
        let settled = await waitForSave(coordinator, persistence)
        XCTAssertTrue(settled)
        XCTAssertEqual(persistence.snapshot.quality, "lossless")
        XCTAssertEqual(coordinator.status, .idle)
        XCTAssertNotNil(coordinator.lastSavedAt)
    }

    /// 写入 **不生效**（桥接静默忽略）→ 核验失败，**不假装成功**。
    func testVerificationFailureIsNotFakeSuccess() async {
        let persistence = FakePersistence()
        persistence.ignoresWrites = true
        let coordinator = makeCoordinator(persistence: persistence)
        coordinator.prime(session: FakePersistence.makeSnapshot(), native: NativeSettings())

        coordinator.setQuality("lossless")
        let failed = await waitForFailure(coordinator)
        XCTAssertTrue(failed)

        guard case .failed(let message) = coordinator.status else {
            return XCTFail("没生效必须算失败，实际：\(coordinator.status)")
        }
        XCTAssertTrue(message.contains("核验"), "失败原因要说明核验不一致：\(message)")
        XCTAssertNil(coordinator.lastSavedAt)
    }

    /// 本地侧失败 **不阻断** 会话侧（磁盘只读不应该连音质都改不了）。
    func testNativeFailureDoesNotBlockSessionSubmit() async throws {
        let persistence = FakePersistence()
        persistence.nativeError = TestError.boom("磁盘只读")
        let coordinator = makeCoordinator(persistence: persistence)
        coordinator.prime(session: FakePersistence.makeSnapshot(), native: NativeSettings())

        coordinator.setAutoSaveEnabled(false)
        coordinator.setQuality("lossless")
        let failed = await waitForFailure(coordinator)
        XCTAssertTrue(failed)

        XCTAssertTrue(persistence.nativeCalls.isEmpty, "本地侧失败时本地没写成功")
        XCTAssertEqual(persistence.sessionCalls.count, 1, "会话侧不受本地失败影响")
        XCTAssertEqual(persistence.snapshot.quality, "lossless")
        XCTAssertNotNil(coordinator.failureMessage)
    }

    // MARK: - 补丁纯逻辑

    /// 会话侧补丁：基线未知 → 不含音质 / 音源。
    func testSessionPatchSkipsRemoteFieldsWhenBaselineUnknown() {
        let values = SettingsValues(quality: "lossless", sources: ["kugou"])
        let patch = SettingsPatch.session(values: values, baseline: .unknown)
        XCTAssertNil(patch.quality)
        XCTAssertNil(patch.sources)
    }

    /// 原生侧补丁：只含改动字段，空目录不提交。
    func testNativePatchOnlyContainsChangedFields() {
        let baseline = NativeSettings(
            playlistsDirectory: "/Users/me/Playlists",
            libraryFolders: ["/Users/me/Music"],
            downloadDirectory: "/Users/me/Music/AlgerMusic",
            autoSaveEnabled: true,
            autoSaveThreshold: 3,
            hideRemotePlaylists: false
        )
        var values = SettingsValues()
        values.playlistsDirectory = baseline.playlistsDirectory
        values.libraryFolders = baseline.libraryFolders
        values.downloadDirectory = baseline.downloadDirectory
        values.autoSaveEnabled = true
        values.autoSaveThreshold = 3
        values.hideRemotePlaylists = false

        var patch = SettingsPatch.native(values: values, baseline: baseline)
        XCTAssertTrue(patch.isEmpty, "没改就不该有补丁")

        values.autoSaveEnabled = false
        patch = SettingsPatch.native(values: values, baseline: baseline)
        XCTAssertEqual(patch.autoSaveEnabled, false)
        XCTAssertNil(patch.playlistsDirectory)
        XCTAssertNil(patch.libraryFolders)
        XCTAssertNil(patch.downloadDirectory)
        XCTAssertNil(patch.autoSaveThreshold)
        XCTAssertNil(patch.hideRemotePlaylists)

        // 目录清空 → 不提交（保留原值）。
        values.downloadDirectory = ""
        values.playlistsDirectory = ""
        patch = SettingsPatch.native(values: values, baseline: baseline)
        XCTAssertNil(patch.downloadDirectory)
        XCTAssertNil(patch.playlistsDirectory)
    }
}
