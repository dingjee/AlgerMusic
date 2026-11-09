import Foundation
import XCTest

@testable import AlgerKit

/// 自动保存服务回归（**真实持久化 / 真实索引 / 真实故障注入**）。
final class AutoSaveServiceTests: XCTestCase {

    private struct Environment {
        let workspace: TempWorkspace
        let store: NativeStore
        let index: LibraryIndex
        let library: LocalLibrary

        init(label: String) throws {
            workspace = try TempWorkspace(label)
            store = NativeStore(fileURL: workspace.url("native.json"))
            index = LibraryIndex(fileURL: workspace.url("library/index.json"))
            library = LocalLibrary(index: index, store: store)
        }

        func service() -> AutoSaveService {
            AutoSaveService(store: store, library: library)
        }
    }

    private func makeTask(id: Int64, status: String, path: String = "") -> DownloadTask {
        DownloadTask(
            id: id,
            name: "歌曲",
            artist: "艺人",
            album: "专辑",
            durationMs: 1000,
            path: path,
            downloaded: 0,
            total: 0,
            percent: 0,
            status: status,
            error: nil,
            source: nil,
            targets: []
        )
    }

    /// 未达阈值 → 不触发。
    func testBelowThresholdDoesNotTrigger() throws {
        let environment = try Environment(label: "auto-below")
        try environment.store.mutate { state in
            state.settings.autoSaveEnabled = true
            state.settings.autoSaveThreshold = 3
            state.playCounts[NativeState.playCountKey(neteaseId: 1)] = 2
        }
        let decision = environment.service().evaluate(
            neteaseId: 1,
            title: "歌曲",
            artist: "艺人",
            durationMs: 1000
        )
        XCTAssertEqual(decision, .none(reason: "播放次数 2/3"))
    }

    /// 达到阈值 → 触发一次；重复评估不会重复触发（登记后状态是 pending）。
    func testReachingThresholdTriggersOnce() throws {
        let environment = try Environment(label: "auto-threshold")
        try environment.store.mutate { state in
            state.settings.autoSaveEnabled = true
            state.settings.autoSaveThreshold = 3
            state.playCounts[NativeState.playCountKey(neteaseId: 2)] = 3
        }
        let service = environment.service()
        XCTAssertEqual(
            service.evaluate(neteaseId: 2, title: "歌曲", artist: "艺人", durationMs: 1000),
            .enqueue
        )
        try service.markEnqueued(neteaseId: 2, title: "歌曲", artist: "艺人", durationMs: 1000)
        // 已经在队列里 → 不再重复发起。
        XCTAssertEqual(
            service.evaluate(neteaseId: 2, title: "歌曲", artist: "艺人", durationMs: 1000),
            .none(reason: "已经在下载队列中")
        )
        XCTAssertEqual(service.records.count, 1)
    }

    /// 开关关闭 → 不触发。
    func testDisabledDoesNotTrigger() throws {
        let environment = try Environment(label: "auto-disabled")
        try environment.store.mutate { state in
            state.settings.autoSaveEnabled = false
            state.playCounts[NativeState.playCountKey(neteaseId: 3)] = 99
        }
        let decision = environment.service().evaluate(
            neteaseId: 3,
            title: "歌曲",
            artist: "艺人",
            durationMs: 1000
        )
        guard case .none = decision else {
            return XCTFail("关闭自动保存时不得触发")
        }
    }

    /// **已在本地去重**：本地已有同来源文件 → 不再下载。
    func testAlreadyLocalIsDeduplicated() throws {
        let environment = try Environment(label: "auto-local")
        let audio = try TestAudio.writeWAV(to: environment.workspace.url("music/song.wav"), seconds: 0.2)
        try environment.index.upsert(TrackRecord(
            path: audio.path,
            neteaseId: 5,
            title: "歌曲",
            artist: "艺人",
            album: "专辑",
            durationMs: 200,
            format: "wav",
            size: 1,
            modifiedAt: 1
        ))
        try environment.store.mutate { state in
            state.settings.autoSaveThreshold = 1
            state.playCounts[NativeState.playCountKey(neteaseId: 5)] = 5
        }
        let decision = environment.service().evaluate(
            neteaseId: 5,
            title: "歌曲",
            artist: "艺人",
            durationMs: 200
        )
        // 本地已有文件 → **不再直接跳过**，交给「下载前审核」判断要不要升级质量
        // （直接跳过会让低码率的本地版本永远得不到升级）。
        XCTAssertEqual(decision, .reviewExistingLocal(reason: "本地已有文件，审核是否需要升级质量"))
    }

    /// **跨重启累计次数** + **阈值降低不会立刻批量下载**。
    func testCountsPersistAndLoweringThresholdDoesNotDownload() throws {
        let environment = try Environment(label: "auto-restart")
        try environment.store.mutate { state in
            state.settings.autoSaveThreshold = 3
            state.playCounts[NativeState.playCountKey(neteaseId: 6)] = 2
        }
        // 重启：新实例读到同样的次数。
        let reopened = NativeStore(fileURL: environment.workspace.url("native.json"))
        let reopenedIndex = LibraryIndex(fileURL: environment.workspace.url("library/index.json"))
        let reopenedLibrary = LocalLibrary(index: reopenedIndex, store: reopened)
        let service = AutoSaveService(store: reopened, library: reopenedLibrary)

        XCTAssertEqual(reopened.current.playCounts[NativeState.playCountKey(neteaseId: 6)], 2)

        // 把阈值调低 → **不会** 自动产生任何记录或下载（只在后续完整播放时判断）。
        try reopened.mutate { $0.settings.autoSaveThreshold = 1 }
        XCTAssertTrue(service.records.isEmpty, "调低阈值不得立刻批量下载历史歌曲")

        // 下一次完整播放（评估）才会触发。
        try reopened.mutate { $0.playCounts[NativeState.playCountKey(neteaseId: 6)] = 1 }
        XCTAssertEqual(
            service.evaluate(neteaseId: 6, title: "歌曲", artist: "艺人", durationMs: 1000),
            .enqueue
        )
    }

    /// 下载失败 → 待处理（可重试），状态必须写进磁盘。
    func testFailureBecomesRetryablePending() throws {
        let environment = try Environment(label: "auto-fail")
        let service = environment.service()
        try service.markEnqueued(neteaseId: 8, title: "歌曲", artist: "艺人", durationMs: 1000)
        try service.markFailed(neteaseId: 8, error: "解析下载地址失败")

        XCTAssertEqual(service.pending.count, 1)
        XCTAssertEqual(service.pending.first?.lastError, "解析下载地址失败")
        // 重启后仍然是待处理。
        let reopened = NativeStore(fileURL: environment.workspace.url("native.json"))
        let reopenedIndex = LibraryIndex(fileURL: environment.workspace.url("library/index.json"))
        let reopenedService = AutoSaveService(
            store: reopened,
            library: LocalLibrary(index: reopenedIndex, store: reopened)
        )
        XCTAssertEqual(reopenedService.pending.count, 1, "待处理必须跨重启可见")
    }

    /// **与真实下载队列对账**：队列里没有任务 → 不能永远 pending。
    func testReconcileWithQueueDoesNotStayPendingForever() throws {
        let environment = try Environment(label: "auto-reconcile")
        let service = environment.service()
        try service.markEnqueued(neteaseId: 9, title: "歌曲", artist: "艺人", durationMs: 1000)

        // 队列里还有进行中的任务 → 保持 pending。
        let stillRunning = try service.reconcile(with: [makeTask(id: 9, status: "running")])
        XCTAssertEqual(stillRunning.stillDownloading, [9])
        XCTAssertEqual(service.pending.count, 0, "进行中的任务不是待处理")
        XCTAssertEqual(service.record(neteaseId: 9)?.state, .pending)

        // 队列里没有任务 → 转成 **可重试的失败**（不会永远 pending）。
        let lost = try service.reconcile(with: [])
        XCTAssertEqual(lost.becameRetryable, [9])
        XCTAssertEqual(service.record(neteaseId: 9)?.state, .failed)
        XCTAssertEqual(service.pending.count, 1, "任务丢失后应当可以重试")
    }

    /// 任务已完成且文件在 → 标记已保存。
    func testReconcileMarksSavedWhenFileExists() throws {
        let environment = try Environment(label: "auto-saved")
        let service = environment.service()
        try service.markEnqueued(neteaseId: 10, title: "歌曲", artist: "艺人", durationMs: 1000)
        let audio = try TestAudio.writeWAV(to: environment.workspace.url("music/done.wav"), seconds: 0.2)
        let report = try service.reconcile(with: [makeTask(id: 10, status: "done", path: audio.path)])
        XCTAssertEqual(report.becameSaved, [10])
        XCTAssertEqual(service.record(neteaseId: 10)?.state, .saved)
    }

    /// **NativeStore 故障注入**：写不进去时必须 **抛错**，
    /// 不能假装登记成功（否则去重登记会丢）。
    func testStoreFailureThrowsInsteadOfFakeSuccess() throws {
        let environment = try Environment(label: "auto-store-fault")
        let storeURL = environment.workspace.url("native.json")
        // 写坏数据 → NativeStore 拒绝写入（保留原文件）。
        try Data("{ 这不是合法 JSON".utf8).write(to: storeURL)
        let store = NativeStore(fileURL: storeURL)
        XCTAssertFalse(store.loadState.isWritable)

        let service = AutoSaveService(
            store: store,
            library: LocalLibrary(
                index: LibraryIndex(fileURL: environment.workspace.url("library/index.json")),
                store: store
            )
        )
        XCTAssertThrowsError(
            try service.markEnqueued(neteaseId: 11, title: "歌曲", artist: "艺人", durationMs: 1000),
            "持久化失败必须抛错，不能假装成功"
        )
        XCTAssertThrowsError(try service.markSaved(neteaseId: 11))
        XCTAssertThrowsError(try service.markFailed(neteaseId: 11, error: "x"))
        // 对账在没有待处理记录时 **不会写盘**（不写就不该抛错）；
        // 真正的写入路径（markEnqueued / markSaved / markFailed）上面已经证明会抛错。
        XCTAssertNoThrow(try service.reconcile(with: []))
        // 原文件必须保留（不被覆盖）。
        XCTAssertEqual(
            try String(contentsOf: storeURL, encoding: .utf8),
            "{ 这不是合法 JSON",
            "损坏的原始文件不得被覆盖"
        )
    }
}
