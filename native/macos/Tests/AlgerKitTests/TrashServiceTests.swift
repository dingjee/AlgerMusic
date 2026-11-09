import Foundation
import XCTest

@testable import AlgerKit

/// 废纸篓删除服务回归（**真实索引 / 真实 M3U8 / 真实文件移动**）。
///
/// 废纸篓动作是 **注入的**：测试把文件移到隔离目录里的 `.Trash`，
/// 既能验证真实删除行为，又 **不会写用户的真实废纸篓**。
final class TrashServiceTests: XCTestCase {

    private struct Environment {
        let workspace: TempWorkspace
        let store: NativeStore
        let index: LibraryIndex
        let library: LocalLibrary
        let trashDirectory: URL

        init(label: String) throws {
            workspace = try TempWorkspace(label)
            store = NativeStore(fileURL: workspace.url("native.json"))
            index = LibraryIndex(fileURL: workspace.url("library/index.json"))
            library = LocalLibrary(index: index, store: store)
            let playlists = try workspace.makeDirectory("playlists")
            try store.mutate { $0.settings.playlistsDirectory = playlists.path }
            trashDirectory = try workspace.makeDirectory(".Trash")
        }
    }

    /// 注入的废纸篓动作：把文件 **真的移动** 到隔离的 `.Trash` 目录。
    private func makeTrash(_ directory: URL) -> (String) throws -> Void {
        { path in
            let source = URL(fileURLWithPath: path)
            let destination = directory.appendingPathComponent(source.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }

    /// 造一个已入索引、已被两个歌单引用的文件。
    private func makeIndexedSong(
        _ environment: Environment,
        name: String = "song.wav"
    ) throws -> (track: TrackRecord, first: LocalPlaylist, second: LocalPlaylist) {
        let audio = try TestAudio.writeWAV(to: environment.workspace.url("music/\(name)"), seconds: 0.3)
        let track = TrackRecord(
            path: audio.path,
            neteaseId: 42,
            title: "歌曲",
            artist: "艺人",
            album: "专辑",
            durationMs: 300,
            format: "wav",
            size: 1024,
            modifiedAt: 1
        )
        try environment.index.upsert(track)
        let first = try environment.library.createPlaylist(title: "歌单一")
        let second = try environment.library.createPlaylist(title: "歌单二")
        _ = try environment.library.addToPlaylist(id: first.id, entries: [PlaylistEntry(path: audio.path, duration: 0.3, displayName: "歌曲")])
        _ = try environment.library.addToPlaylist(id: second.id, entries: [PlaylistEntry(path: audio.path, duration: 0.3, displayName: "歌曲")])
        return (track, first, second)
    }

    /// 删除成功：文件移走、索引清理、**两个歌单的引用都清掉**、日志清空。
    func testDeleteMovesFileAndCleansIndexAndPlaylists() throws {
        let environment = try Environment(label: "trash-ok")
        let (track, first, second) = try makeIndexedSong(environment)
        let service = TrashService(
            store: environment.store,
            index: environment.index,
            library: environment.library,
            trash: makeTrash(environment.trashDirectory)
        )

        let result = try service.delete(path: track.path, title: track.title)
        XCTAssertTrue(result.movedToTrash)
        XCTAssertTrue(result.isComplete, "清理应当完整完成：\(result.cleanupFailures)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: track.path), "文件应当已被移走")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: environment.trashDirectory.appendingPathComponent("song.wav").path),
            "文件应当真的在废纸篓里"
        )
        XCTAssertNil(environment.index.track(path: track.path), "索引应当已清理")
        XCTAssertEqual(try environment.library.playlist(id: first.id)?.entries.count, 0)
        XCTAssertEqual(try environment.library.playlist(id: second.id)?.entries.count, 0)
        XCTAssertTrue(service.pending.isEmpty, "成功之后不应留下待处理日志")
    }

    /// 废纸篓失败 → **不提前清数据**，失败被记录（可重试）。
    func testTrashFailureKeepsDataAndRecordsFailure() throws {
        let environment = try Environment(label: "trash-fail")
        let (track, first, second) = try makeIndexedSong(environment)
        let service = TrashService(
            store: environment.store,
            index: environment.index,
            library: environment.library,
            trash: { _ in throw NSError(domain: "test", code: 7, userInfo: [NSLocalizedDescriptionKey: "废纸篓不可用"]) }
        )

        XCTAssertThrowsError(try service.delete(path: track.path, title: track.title))
        XCTAssertTrue(FileManager.default.fileExists(atPath: track.path), "失败时文件必须还在")
        XCTAssertNotNil(environment.index.track(path: track.path), "失败时索引不得被清空")
        XCTAssertEqual(try environment.library.playlist(id: first.id)?.entries.count, 1, "失败时歌单引用不得被清空")
        XCTAssertEqual(try environment.library.playlist(id: second.id)?.entries.count, 1)
        XCTAssertEqual(service.pending.count, 1, "失败必须留下可重试的日志")
        XCTAssertEqual(service.pending.first?.state, .failed)
    }

    /// 一个坏 M3U8 → **不能** 把受影响歌单数说成 0：
    /// 读不出来的歌单必须进入待清理范围，并给出具体问题。
    func testPlanKeepsUnreadablePlaylistsInScope() throws {
        let environment = try Environment(label: "trash-plan")
        let (track, first, _) = try makeIndexedSong(environment)
        // 把第二个歌单的 M3U8 变成目录 → 读不出来。
        let second = try environment.library.playlists().first { $0.id != first.id }
        let brokenURL = try XCTUnwrap(second?.fileURL)
        try FileManager.default.removeItem(at: brokenURL)
        try FileManager.default.createDirectory(at: brokenURL, withIntermediateDirectories: true)

        let service = TrashService(
            store: environment.store,
            index: environment.index,
            library: environment.library,
            trash: makeTrash(environment.trashDirectory)
        )
        let plan = service.plan(path: track.path, title: track.title)
        XCTAssertEqual(plan.affectedPlaylistCount, 1, "只有能读出来的歌单才计入")
        XCTAssertTrue(plan.hasUnknownScope, "读不出来的歌单必须被标出来")
        XCTAssertEqual(plan.unreadablePlaylistIds.count, 1)
        XCTAssertFalse(plan.issues.isEmpty, "必须给出具体问题")
        XCTAssertTrue(plan.cleanupScopePlaylistIds.contains(plan.unreadablePlaylistIds[0]), "读不出来的歌单要进待清理范围")

        // 删除时它也会进待清理范围（失败会留在日志里，不会假装成功）。
        let result = try service.delete(path: track.path, title: track.title)
        XCTAssertFalse(result.isComplete, "读不出来的歌单没清理干净就不能算完整成功")
        XCTAssertEqual(service.pending.count, 1, "未完成的清理必须留在日志里")
    }

    /// 崩溃恢复：文件已经进废纸篓，但索引 / 歌单还没清理 → 启动修复补齐。
    func testRepairFinishesCleanupAfterCrash() throws {
        let environment = try Environment(label: "trash-repair")
        let (track, first, second) = try makeIndexedSong(environment)
        let service = TrashService(
            store: environment.store,
            index: environment.index,
            library: environment.library,
            trash: makeTrash(environment.trashDirectory)
        )

        // 模拟「文件已移走、清理没做完」的崩溃现场：先写日志，再移文件。
        try environment.store.mutate { state in
            state.pendingFileDeletions.append(PendingFileDeletion(
                path: track.path,
                title: track.title,
                playlistIds: [first.id, second.id]
            ))
        }
        try FileManager.default.moveItem(
            at: URL(fileURLWithPath: track.path),
            to: environment.trashDirectory.appendingPathComponent("song.wav")
        )

        let report = service.repairPending()
        XCTAssertFalse(report.isEmpty, "应当报告修复动作")
        XCTAssertNil(environment.index.track(path: track.path), "索引应当被补清理")
        XCTAssertEqual(try environment.library.playlist(id: first.id)?.entries.count, 0)
        XCTAssertEqual(try environment.library.playlist(id: second.id)?.entries.count, 0)
        XCTAssertTrue(service.pending.isEmpty, "修复完成后日志应当清空")
    }

    /// 文件本来就不在索引里 → **幂等成功**，不得误报「未清理」。
    func testMissingIndexEntryIsIdempotentSuccess() throws {
        let environment = try Environment(label: "trash-idempotent")
        let audio = try TestAudio.writeWAV(to: environment.workspace.url("music/loose.wav"), seconds: 0.2)
        let service = TrashService(
            store: environment.store,
            index: environment.index,
            library: environment.library,
            trash: makeTrash(environment.trashDirectory)
        )
        let result = try service.delete(path: audio.path, title: "loose")
        XCTAssertTrue(result.isComplete, "索引里没有该文件也算清理完成：\(result.cleanupFailures)")
    }

    /// **真实 macOS 废纸篓往返**（`FileManager.trashItem`）：
    /// - 源是 `.artifacts` 里唯一命名的音频夹具；
    /// - 注入的 wrapper 调用 **真实** `trashItem` 并捕获 `resultingItemURL`；
    /// - 核验：原路径消失、真实废纸篓里 **同字节**、索引与歌单都清理；
    /// - `defer` **只** 删除这一个精确返回的 URL（核对归属，不扫废纸篓）。
    func testRealTrashItemRoundTrip() throws {
        let environment = try Environment(label: "trash-real")
        let uniqueName = "alger-\(UUID().uuidString).wav"
        let audio = try environment.workspace.url("music/\(uniqueName)")
        try TestAudio.writeWAV(to: audio, seconds: 0.25)
        let originalBytes = try Data(contentsOf: audio)

        // 入索引 + 两个歌单引用。
        let track = TrackRecord(
            path: audio.path,
            neteaseId: 77,
            title: "真实废纸篓夹具",
            artist: "艺人",
            album: "专辑",
            durationMs: 250,
            format: "wav",
            size: UInt64(originalBytes.count),
            modifiedAt: 1
        )
        try environment.index.upsert(track)
        let first = try environment.library.createPlaylist(title: "歌单一")
        let second = try environment.library.createPlaylist(title: "歌单二")
        _ = try environment.library.addToPlaylist(id: first.id, entries: [PlaylistEntry(path: audio.path, duration: 0.25, displayName: "夹具")])
        _ = try environment.library.addToPlaylist(id: second.id, entries: [PlaylistEntry(path: audio.path, duration: 0.25, displayName: "夹具")])

        var trashedURL: URL?
        let service = TrashService(
            store: environment.store,
            index: environment.index,
            library: environment.library,
            trash: { path in
                // **真实** 废纸篓操作（失败必须抛错，不得当成成功）。
                var resulting: NSURL?
                try FileManager.default.trashItem(
                    at: URL(fileURLWithPath: path),
                    resultingItemURL: &resulting
                )
                trashedURL = resulting as URL?
            }
        )
        defer {
            // **只** 清理这一个精确返回的 URL（核对归属，不扫描废纸篓）。
            if let url = trashedURL {
                XCTAssertEqual(url.lastPathComponent, uniqueName, "只处理本次返回的文件")
                try? FileManager.default.removeItem(at: url)
            }
        }

        let result: TrashService.Result
        do {
            result = try service.delete(path: audio.path, title: track.title)
        } catch {
            XCTFail("真实废纸篓删除失败：\(error.localizedDescription)")
            return
        }

        XCTAssertTrue(result.movedToTrash, "文件应当已移入真实废纸篓")
        XCTAssertTrue(result.isComplete, "索引与歌单应当清理干净：\(result.cleanupFailures)")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: audio.path),
            "原路径应当已经消失"
        )

        let returned = try XCTUnwrap(trashedURL, "真实 trashItem 应当返回废纸篓中的位置")
        XCTAssertEqual(returned.lastPathComponent, uniqueName, "归属核对：文件名必须一致")
        XCTAssertTrue(FileManager.default.fileExists(atPath: returned.path), "废纸篓里应当真的有这个文件")
        let trashedBytes = try Data(contentsOf: returned)
        XCTAssertEqual(trashedBytes.count, originalBytes.count, "废纸篓里的文件应当是同一份字节")
        XCTAssertEqual(trashedBytes, originalBytes, "废纸篓里的文件内容必须一致")

        // 索引与歌单都清理了。
        XCTAssertNil(environment.index.track(path: audio.path), "索引应当已清理")
        XCTAssertEqual(try environment.library.playlist(id: first.id)?.entries.count, 0)
        XCTAssertEqual(try environment.library.playlist(id: second.id)?.entries.count, 0)
        XCTAssertTrue(service.pending.isEmpty, "成功之后不应留下待处理日志")
    }
}
