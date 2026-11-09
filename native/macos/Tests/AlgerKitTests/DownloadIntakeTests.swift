import Foundation
import XCTest
import Network

@testable import AlgerKit

/// 本机 HTTP 音频服务器（**合法音频**：本地生成的短 WAV）。
///
/// 用途：把「下载落盘」这一步做成 **真实 HTTP 取字节**，
/// 而不是伪造一个文件（这样入单链路的输入与真实下载一致）。
final class LocalAudioServer {

    private let listener: NWListener
    private let queue = DispatchQueue(label: "alger.test.http")
    private let body: Data
    /// 实际监听的端口。
    private(set) var port: UInt16 = 0

    init(body: Data) throws {
        self.body = body
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener

        let semaphore = DispatchSemaphore(value: 0)
        var failure: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                semaphore.signal()
            case .failed(let error):
                failure = error
                semaphore.signal()
            default:
                break
            }
        }
        // 闭包 **不捕获 self**（初始化未完成时捕获 self 会用不到初始化的属性）。
        let queue = self.queue
        let body = self.body
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            LocalAudioServer.handle(connection, body: body, queue: queue)
        }
        listener.start(queue: queue)
        guard semaphore.wait(timeout: .now() + 5) == .success else {
            throw NSError(domain: "LocalAudioServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "服务器启动超时"])
        }
        if let failure {
            throw failure
        }
        guard let port = listener.port?.rawValue else {
            throw NSError(domain: "LocalAudioServer", code: 2, userInfo: [NSLocalizedDescriptionKey: "没有监听端口"])
        }
        self.port = port
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    /// 真实 HTTP 下载（**取字节并落盘**）。
    @discardableResult
    func download(relativePath: String, to destination: URL) async throws -> URL {
        let url = baseURL.appendingPathComponent(relativePath)
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = response as? HTTPURLResponse
        XCTAssertEqual(http?.statusCode, 200, "本机 HTTP 服务器应当返回 200")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination)
        return destination
    }

    private static func handle(_ connection: NWConnection, body: Data, queue: DispatchQueue) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            // AVPlayer 会发 Range 请求：**必须支持分段**（否则报
            // "The server is not correctly configured"）。
            var start = 0
            var end = body.count - 1
            var isRange = false
            if let rangeLine = request.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("range:") }),
               let spec = rangeLine.split(separator: "=").last {
                let parts = spec.split(separator: "-")
                if let first = parts.first, let lower = Int(first) {
                    start = lower
                    isRange = true
                }
                if parts.count > 1, let upper = Int(parts[1]) {
                    end = min(upper, body.count - 1)
                }
            }
            let payload = isRange ? body.subdata(in: start..<(end + 1)) : body
            var response = Data()
            if isRange {
                response.append(contentsOf: Array("HTTP/1.1 206 Partial Content\r\n".utf8))
                response.append(contentsOf: Array("Content-Range: bytes \(start)-\(end)/\(body.count)\r\n".utf8))
            } else {
                response.append(contentsOf: Array("HTTP/1.1 200 OK\r\n".utf8))
            }
            response.append(contentsOf: Array("Content-Type: audio/wav\r\n".utf8))
            response.append(contentsOf: Array("Accept-Ranges: bytes\r\n".utf8))
            response.append(contentsOf: Array("Content-Length: \(payload.count)\r\n".utf8))
            response.append(contentsOf: Array("Connection: close\r\n\r\n".utf8))
            response.append(payload)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    func stop() {
        listener.cancel()
    }
}

/// 下载入单服务回归（**真实索引 / 真实 M3U8 / 真实持久化**）。
final class DownloadIntakeTests: XCTestCase {

    /// 造一个「下载好的」音频文件（**真实 HTTP 取字节**）。
    private func downloadedAudio(server: LocalAudioServer, workspace: TempWorkspace) async throws -> URL {
        let server2 = server
        let destination = workspace.url("music/艺人 - 歌曲.wav")
        try await server2.download(relativePath: "song.wav", to: destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        return destination
    }

    /// 全部目标成功 → 两个歌单都写入，索引也有记录。
    func testIntakeWritesAllTargetsAndIndex() async throws {
        let workspace = try TempWorkspace("intake-happy")
        let server = try LocalAudioServer(body: TestAudio.wavData(seconds: 0.4))
        defer { server.stop() }
        let audio = try await downloadedAudio(server: server, workspace: workspace)

        let store = NativeStore(fileURL: workspace.url("native.json"))
        let index = LibraryIndex(fileURL: workspace.url("library/index.json"))
        let library = LocalLibrary(index: index, store: store)
        let playlistsDirectory = try workspace.makeDirectory("playlists")
        try store.mutate { $0.settings.playlistsDirectory = playlistsDirectory.path }
        let first = try library.createPlaylist(title: "歌单一")
        let second = try library.createPlaylist(title: "歌单二")

        let service = DownloadIntakeService(store: store, library: library)
        let outcome = try service.performIntake(
            taskId: 1001,
            targets: [first.id, second.id],
            path: audio.path,
            title: "歌曲",
            artist: "艺人",
            album: "专辑",
            durationMs: 400
        )

        XCTAssertTrue(outcome.isFullySuccessful, "全部目标应当成功：\(outcome.pending.map { $0.lastError ?? "" })")
        XCTAssertEqual(outcome.confirmed.count, 2)
        XCTAssertTrue(service.pending.isEmpty, "成功之后不应留下待处理记录")
        XCTAssertEqual(index.track(path: audio.path)?.neteaseId, 1001, "索引应当记录来源 ID")

        let firstEntries = try library.playlist(id: first.id)?.entries ?? []
        let secondEntries = try library.playlist(id: second.id)?.entries ?? []
        XCTAssertEqual(firstEntries.count, 1)
        XCTAssertEqual(secondEntries.count, 1)
        XCTAssertEqual(firstEntries.first?.path, audio.path)
    }

    /// **多目标一处失败**：失败的目标保持待处理，成功的目标不受影响，
    /// 而且失败提示 **不会** 被成功覆盖。
    func testPartialFailureKeepsPendingWithoutHidingSuccess() async throws {
        let workspace = try TempWorkspace("intake-partial")
        let server = try LocalAudioServer(body: TestAudio.wavData(seconds: 0.4))
        defer { server.stop() }
        let audio = try await downloadedAudio(server: server, workspace: workspace)

        let store = NativeStore(fileURL: workspace.url("native.json"))
        let index = LibraryIndex(fileURL: workspace.url("library/index.json"))
        let library = LocalLibrary(index: index, store: store)
        let playlistsDirectory = try workspace.makeDirectory("playlists")
        try store.mutate { $0.settings.playlistsDirectory = playlistsDirectory.path }
        let good = try library.createPlaylist(title: "好歌单")
        let bad = try library.createPlaylist(title: "坏歌单")

        // 把坏歌单的 M3U8 变成 **目录** → 读写都会失败（真实故障注入）。
        let badFile = bad.fileURL
        try FileManager.default.removeItem(at: badFile)
        try FileManager.default.createDirectory(at: badFile, withIntermediateDirectories: true)

        let service = DownloadIntakeService(store: store, library: library)
        let outcome = try service.performIntake(
            taskId: 2002,
            targets: [good.id, bad.id],
            path: audio.path,
            title: "歌曲",
            artist: "艺人",
            album: "专辑",
            durationMs: 400
        )

        XCTAssertTrue(outcome.hasFailure, "部分失败必须被报告为失败")
        XCTAssertEqual(outcome.confirmed.count, 1, "成功的目标应当确认")
        XCTAssertEqual(outcome.pending.count, 1, "失败的目标必须保持待处理")
        XCTAssertNotNil(outcome.pending.first?.lastError, "失败必须有具体原因")
        XCTAssertEqual(service.pendingCount, 1, "失败目标应当持久可见")

        // 成功的那一份确实写进去了，失败的那一份没有。
        XCTAssertEqual(try library.playlist(id: good.id)?.entries.count, 1)
        XCTAssertThrowsError(try library.playlist(id: bad.id), "坏歌单读不出来时应报错而不是假装为空")

        // 修好坏歌单 → 重试 → 补入，且好的歌单 **不会重复加入**。
        try FileManager.default.removeItem(at: badFile)
        let repaired = PlaylistFile(fileURL: badFile)
        try repaired.load()
        try repaired.save()

        let retry = service.retryPending()
        XCTAssertTrue(retry.isFullySuccessful, "修好后应当全部补入")
        XCTAssertEqual(try library.playlist(id: bad.id)?.entries.count, 1)
        XCTAssertEqual(try library.playlist(id: good.id)?.entries.count, 1, "重试不得重复加入")
    }

    /// **持久待处理跨重启**：重启后记录仍在，重放能补入。
    func testPendingSurvivesRestartAndIsReplayed() async throws {
        let workspace = try TempWorkspace("intake-restart")
        let server = try LocalAudioServer(body: TestAudio.wavData(seconds: 0.4))
        defer { server.stop() }
        let audio = try await downloadedAudio(server: server, workspace: workspace)

        let store = NativeStore(fileURL: workspace.url("native.json"))
        let index = LibraryIndex(fileURL: workspace.url("library/index.json"))
        let library = LocalLibrary(index: index, store: store)
        let playlistsDirectory = try workspace.makeDirectory("playlists")
        try store.mutate { $0.settings.playlistsDirectory = playlistsDirectory.path }
        let target = try library.createPlaylist(title: "目标歌单")

        let badFile = target.fileURL
        try FileManager.default.removeItem(at: badFile)
        try FileManager.default.createDirectory(at: badFile, withIntermediateDirectories: true)

        let service = DownloadIntakeService(store: store, library: library)
        _ = try service.performIntake(
            taskId: 3003,
            targets: [target.id],
            path: audio.path,
            title: "歌曲",
            artist: "艺人",
            album: "专辑",
            durationMs: 400
        )
        XCTAssertEqual(service.pendingCount, 1)

        // **重启**：新的 NativeStore（同一份文件）。
        let reopenedStore = NativeStore(fileURL: workspace.url("native.json"))
        let reopenedIndex = LibraryIndex(fileURL: workspace.url("library/index.json"))
        let reopenedLibrary = LocalLibrary(index: reopenedIndex, store: reopenedStore)
        let reopenedService = DownloadIntakeService(store: reopenedStore, library: reopenedLibrary)
        XCTAssertEqual(reopenedService.pendingCount, 1, "待处理记录必须跨重启存活")

        // 修好歌单文件 → 重放补入。
        try FileManager.default.removeItem(at: badFile)
        let repaired = PlaylistFile(fileURL: badFile)
        try repaired.load()
        try repaired.save()

        let outcome = reopenedService.retryPending()
        XCTAssertTrue(outcome.isFullySuccessful)
        XCTAssertEqual(try reopenedLibrary.playlist(id: target.id)?.entries.count, 1)
        XCTAssertTrue(reopenedService.pending.isEmpty)
    }

    /// **索引失败不可假成功**：索引写不进去时，入单不确认、错误可见。
    func testIndexFailureIsNotReportedAsSuccess() async throws {
        let workspace = try TempWorkspace("intake-index-fail")
        let server = try LocalAudioServer(body: TestAudio.wavData(seconds: 0.4))
        defer { server.stop() }
        let audio = try await downloadedAudio(server: server, workspace: workspace)

        let store = NativeStore(fileURL: workspace.url("native.json"))
        // 索引路径是一个 **目录** → 写入必然失败（真实故障注入）。
        let brokenIndexPath = try workspace.makeDirectory("index-broken")
        let index = LibraryIndex(fileURL: brokenIndexPath)
        let library = LocalLibrary(index: index, store: store)
        let playlistsDirectory = try workspace.makeDirectory("playlists")
        try store.mutate { $0.settings.playlistsDirectory = playlistsDirectory.path }
        let target = try library.createPlaylist(title: "目标歌单")

        let service = DownloadIntakeService(store: store, library: library)
        let outcome = try service.performIntake(
            taskId: 4004,
            targets: [target.id],
            path: audio.path,
            title: "歌曲",
            artist: "艺人",
            album: "专辑",
            durationMs: 400
        )

        XCTAssertNotNil(outcome.indexError, "索引失败必须被报告")
        XCTAssertTrue(outcome.hasFailure)
        XCTAssertTrue(outcome.confirmed.isEmpty, "索引失败不得算作入单成功")
        XCTAssertEqual(outcome.pending.count, 1, "索引失败时目标保持待处理")
        XCTAssertEqual(service.pendingCount, 1)
    }

    /// **以前就有的条目不撤回**：只撤回本次新增。
    func testUndoOnlyRemovesEntriesAddedThisTime() async throws {
        let workspace = try TempWorkspace("intake-undo")
        let server = try LocalAudioServer(body: TestAudio.wavData(seconds: 0.4))
        defer { server.stop() }
        let audio = try await downloadedAudio(server: server, workspace: workspace)

        let store = NativeStore(fileURL: workspace.url("native.json"))
        let index = LibraryIndex(fileURL: workspace.url("library/index.json"))
        let library = LocalLibrary(index: index, store: store)
        let playlistsDirectory = try workspace.makeDirectory("playlists")
        try store.mutate { $0.settings.playlistsDirectory = playlistsDirectory.path }
        let target = try library.createPlaylist(title: "目标歌单")

        // 之前就已经在歌单里的条目。
        let existing = PlaylistEntry(path: audio.path, duration: 0.4, displayName: "歌曲")
        let appended = try library.addToPlaylist(id: target.id, entries: [existing])
        XCTAssertEqual(appended.count, 1)

        let service = DownloadIntakeService(store: store, library: library)
        let outcome = try service.performIntake(
            taskId: 5005,
            targets: [target.id],
            path: audio.path,
            title: "歌曲",
            artist: "艺人",
            album: "专辑",
            durationMs: 400
        )
        XCTAssertTrue(outcome.isFullySuccessful)
        XCTAssertTrue(outcome.newlyAdded[target.id]?.isEmpty ?? true, "已经在歌单里的条目不算本次新增")

        // 撤回「本次新增」→ 之前的条目 **不能** 被删掉。
        _ = service.undoNewlyAdded(outcome.newlyAdded)
        XCTAssertEqual(try library.playlist(id: target.id)?.entries.count, 1, "撤回不得删掉此前已有的条目")
    }

    /// **已确认的意图不会被重放复活**（用户后来手动移除的条目不会被加回来）。
    func testConfirmedIntentIsNotResurrectedAfterUserRemoval() async throws {
        let workspace = try TempWorkspace("intake-no-resurrect")
        let server = try LocalAudioServer(body: TestAudio.wavData(seconds: 0.4))
        defer { server.stop() }
        let audio = try await downloadedAudio(server: server, workspace: workspace)

        let store = NativeStore(fileURL: workspace.url("native.json"))
        let index = LibraryIndex(fileURL: workspace.url("library/index.json"))
        let library = LocalLibrary(index: index, store: store)
        let playlistsDirectory = try workspace.makeDirectory("playlists")
        try store.mutate { $0.settings.playlistsDirectory = playlistsDirectory.path }
        let target = try library.createPlaylist(title: "目标歌单")

        let service = DownloadIntakeService(store: store, library: library)
        let outcome = try service.performIntake(
            taskId: 6006,
            targets: [target.id],
            path: audio.path,
            title: "歌曲",
            artist: "艺人",
            album: "专辑",
            durationMs: 400
        )
        XCTAssertTrue(outcome.isFullySuccessful)
        XCTAssertEqual(try library.playlist(id: target.id)?.entries.count, 1)

        // 用户手动移除。
        try library.removeFromPlaylist(id: target.id, paths: [audio.path])
        XCTAssertEqual(try library.playlist(id: target.id)?.entries.count, 0)

        // 重放（重启后）→ **不得** 把条目加回来。
        let reopenedStore = NativeStore(fileURL: workspace.url("native.json"))
        let reopenedIndex = LibraryIndex(fileURL: workspace.url("library/index.json"))
        let reopenedLibrary = LocalLibrary(index: reopenedIndex, store: reopenedStore)
        let reopenedService = DownloadIntakeService(store: reopenedStore, library: reopenedLibrary)
        let replay = reopenedService.retryPending()
        XCTAssertTrue(replay.confirmed.isEmpty, "已确认的意图不应再次入单")
        XCTAssertEqual(try reopenedLibrary.playlist(id: target.id)?.entries.count, 0, "用户移除的条目不得被复活")
    }

    /// **显式重新添加**（用户主动再加一次）→ 允许作为 **新意图** 再次入单。
    func testExplicitReAddAfterRemovalCreatesNewIntent() async throws {        let workspace = try TempWorkspace("intake-readd")
        let server = try LocalAudioServer(body: TestAudio.wavData(seconds: 0.4))
        defer { server.stop() }
        let audio = try await downloadedAudio(server: server, workspace: workspace)

        let store = NativeStore(fileURL: workspace.url("native.json"))
        let index = LibraryIndex(fileURL: workspace.url("library/index.json"))
        let library = LocalLibrary(index: index, store: store)
        let playlistsDirectory = try workspace.makeDirectory("playlists")
        try store.mutate { $0.settings.playlistsDirectory = playlistsDirectory.path }
        let target = try library.createPlaylist(title: "目标歌单")

        let service = DownloadIntakeService(store: store, library: library)
        _ = try service.performIntake(
            taskId: 7007,
            targets: [target.id],
            path: audio.path,
            title: "歌曲",
            artist: "艺人",
            album: "专辑",
            durationMs: 400
        )
        try library.removeFromPlaylist(id: target.id, paths: [audio.path])

        // 用户显式再添加一次 → **新意图**。
        try service.registerIntent(
            taskId: 7007,
            targets: [target.id],
            displayName: "歌曲 - 艺人",
            durationMs: 400
        )
        let outcome = try service.performIntake(
            taskId: 7007,
            targets: [target.id],
            path: audio.path,
            title: "歌曲",
            artist: "艺人",
            album: "专辑",
            durationMs: 400
        )
        XCTAssertTrue(outcome.isFullySuccessful)
        XCTAssertEqual(try library.playlist(id: target.id)?.entries.count, 1, "显式重新添加应当再次入单")
    }

    // MARK: - 撤回（改目标 / 取消添加）

    /// **撤回** 待处理意图：持久 `superseded` + 撤回标记，跨重启仍然有效。
    func testWithdrawPendingPersistsSupersededIntent() async throws {
        let workspace = try TempWorkspace("intake-withdraw")
        let server = try LocalAudioServer(body: TestAudio.wavData(seconds: 0.4))
        defer { server.stop() }
        let audio = try await downloadedAudio(server: server, workspace: workspace)

        let store = NativeStore(fileURL: workspace.url("native.json"))
        let index = LibraryIndex(fileURL: workspace.url("library/index.json"))
        let library = LocalLibrary(index: index, store: store)
        let playlistsDirectory = try workspace.makeDirectory("playlists")
        try store.mutate { $0.settings.playlistsDirectory = playlistsDirectory.path }
        let target = try library.createPlaylist(title: "目标歌单")

        let service = DownloadIntakeService(store: store, library: library)
        try service.registerIntent(
            taskId: 8008,
            targets: [target.id],
            displayName: "歌曲 - 艺人",
            durationMs: 400
        )
        XCTAssertEqual(service.pendingCount, 1)

        let withdrawn = try service.withdrawPending(taskId: 8008, playlistId: target.id)
        XCTAssertEqual(withdrawn.count, 1, "撤回应当返回被撤回的意图 ID")
        XCTAssertEqual(service.pendingCount, 0, "撤回后不再有待处理意图")
        let record = service.records.first { $0.id == withdrawn[0] }
        XCTAssertEqual(record?.superseded, true, "撤回必须持久化 superseded")
        XCTAssertTrue(record?.isWithdrawn ?? false, "撤回必须留下撤回标记")

        // **跨重启**：撤回状态必须还在。
        let reopenedStore = NativeStore(fileURL: workspace.url("native.json"))
        let reopenedIndex = LibraryIndex(fileURL: workspace.url("library/index.json"))
        let reopenedLibrary = LocalLibrary(index: reopenedIndex, store: reopenedStore)
        let reopenedService = DownloadIntakeService(store: reopenedStore, library: reopenedLibrary)
        XCTAssertEqual(reopenedService.pendingCount, 0, "撤回状态必须跨重启存活")
        XCTAssertTrue(reopenedService.isWithdrawn(taskId: 8008, playlistId: target.id), "撤回状态必须跨重启存活")
        XCTAssertEqual(reopenedService.records.first { $0.id == withdrawn[0] }?.superseded, true)

        // 撤回没有待处理意图可撤时：不重复留痕，但也不丢撤回状态。
        let again = try reopenedService.withdrawPending(taskId: 8008, playlistId: target.id)
        XCTAssertTrue(again.isEmpty, "没有待处理意图时返回空数组")
        XCTAssertTrue(reopenedService.isWithdrawn(taskId: 8008, playlistId: target.id), "撤回状态不得丢失")
    }

    /// **下载中改目标**：旧目标的意图被撤回后，Rust 侧 **过期的 targets**
    /// 不得让旧目标复活 → 只有新目标入单 → 跨重启仍不复活 →
    /// 用户 **显式** 重新添加旧目标后可以再次入单。
    func testChangingTargetDuringDownloadDoesNotResurrectOldTarget() async throws {
        let workspace = try TempWorkspace("intake-change-target")
        let server = try LocalAudioServer(body: TestAudio.wavData(seconds: 0.4))
        defer { server.stop() }
        let audio = try await downloadedAudio(server: server, workspace: workspace)

        let store = NativeStore(fileURL: workspace.url("native.json"))
        let index = LibraryIndex(fileURL: workspace.url("library/index.json"))
        let library = LocalLibrary(index: index, store: store)
        let playlistsDirectory = try workspace.makeDirectory("playlists")
        try store.mutate { $0.settings.playlistsDirectory = playlistsDirectory.path }
        let oldTarget = try library.createPlaylist(title: "旧目标")
        let newTarget = try library.createPlaylist(title: "新目标")

        let service = DownloadIntakeService(store: store, library: library)
        // 入队下载前登记意图（旧目标 + 新目标）。
        try service.registerIntent(
            taskId: 9009,
            targets: [oldTarget.id, newTarget.id],
            displayName: "歌曲 - 艺人",
            durationMs: 400
        )
        XCTAssertEqual(service.pendingCount, 2)

        // 下载进行中，用户改目标 → 撤回旧目标。
        let withdrawn = try service.withdrawPending(taskId: 9009, playlistId: oldTarget.id)
        XCTAssertEqual(withdrawn.count, 1, "撤回应当返回被撤回的意图 ID")
        XCTAssertEqual(service.pendingCount, 1, "撤回后只剩新目标待处理")
        let recordsBefore = service.records.count

        // 下载完成：Rust 侧事件里仍然是 **旧 targets**（旧目标 + 新目标）。
        let outcome = try service.performIntake(
            taskId: 9009,
            targets: [oldTarget.id, newTarget.id],
            path: audio.path,
            title: "歌曲",
            artist: "艺人",
            album: "专辑",
            durationMs: 400
        )
        XCTAssertEqual(
            try library.playlist(id: oldTarget.id)?.entries.count,
            0,
            "已撤回的目标不得被 Rust 的旧 targets 复活"
        )
        XCTAssertEqual(
            try library.playlist(id: newTarget.id)?.entries.count,
            1,
            "只有新目标入单"
        )
        XCTAssertEqual(outcome.confirmed.count, 1, "只有新目标算确认")
        XCTAssertEqual(outcome.skipped.count, 1, "撤回的目标应当被跳过")
        XCTAssertTrue(outcome.pending.isEmpty, "撤回不该算失败")
        XCTAssertTrue(outcome.isFullySuccessful)
        XCTAssertEqual(
            service.records.count,
            recordsBefore,
            "已撤回的目标不得按旧 targets 重建意图"
        )

        // **跨重启**：Rust 再次推送同一条过期 targets → 仍然不得复活。
        let reopenedStore = NativeStore(fileURL: workspace.url("native.json"))
        let reopenedIndex = LibraryIndex(fileURL: workspace.url("library/index.json"))
        let reopenedLibrary = LocalLibrary(index: reopenedIndex, store: reopenedStore)
        let reopenedService = DownloadIntakeService(store: reopenedStore, library: reopenedLibrary)
        let replay = try reopenedService.performIntake(
            taskId: 9009,
            targets: [oldTarget.id, newTarget.id],
            path: audio.path,
            title: "歌曲",
            artist: "艺人",
            album: "专辑",
            durationMs: 400
        )
        XCTAssertEqual(try reopenedLibrary.playlist(id: oldTarget.id)?.entries.count, 0, "跨重启也不得复活旧目标")
        XCTAssertEqual(try reopenedLibrary.playlist(id: newTarget.id)?.entries.count, 1, "新目标不得重复入单")
        XCTAssertTrue(replay.confirmed.isEmpty, "跨重启不得再确认任何目标")
        XCTAssertEqual(replay.skipped.count, 2, "两个目标都应当被跳过")

        // 启动重放（补偿）也不得复活旧目标。
        let retry = reopenedService.retryPending()
        XCTAssertTrue(retry.confirmed.isEmpty)
        XCTAssertEqual(try reopenedLibrary.playlist(id: oldTarget.id)?.entries.count, 0, "重放不得复活旧目标")

        // 用户 **显式** 重新添加到旧目标 → 新意图 → 可以再次入单。
        try reopenedService.registerIntent(
            taskId: 9009,
            targets: [oldTarget.id],
            displayName: "歌曲 - 艺人",
            durationMs: 400
        )
        XCTAssertFalse(reopenedService.isWithdrawn(taskId: 9009, playlistId: oldTarget.id), "显式重加后不再是撤回状态")
        let readd = try reopenedService.performIntake(
            taskId: 9009,
            targets: [oldTarget.id, newTarget.id],
            path: audio.path,
            title: "歌曲",
            artist: "艺人",
            album: "专辑",
            durationMs: 400
        )
        XCTAssertEqual(readd.confirmed.count, 1, "显式重加后应当确认一次")
        XCTAssertEqual(try reopenedLibrary.playlist(id: oldTarget.id)?.entries.count, 1, "显式重加后旧目标可以再次入单")
        XCTAssertEqual(try reopenedLibrary.playlist(id: newTarget.id)?.entries.count, 1, "新目标不得重复入单")

        // **再撤回**（重加并完成之后）：这时没有待处理意图，
        // 撤回痕迹仍然必须写下来（不能被更早的撤回记录吞掉）。
        let withdrawnAgain = try reopenedService.withdrawPending(taskId: 9009, playlistId: oldTarget.id)
        XCTAssertTrue(withdrawnAgain.isEmpty, "已完成的意图没有待处理意图可撤")
        XCTAssertTrue(
            reopenedService.isWithdrawn(taskId: 9009, playlistId: oldTarget.id),
            "再撤回必须写回撤回状态（不能被更早的撤回记录吞掉）"
        )
        XCTAssertTrue(
            reopenedService.latestRecord(taskId: 9009, playlistId: oldTarget.id)?.isWithdrawn ?? false,
            "最新记录必须带撤回标记"
        )
    }
}
