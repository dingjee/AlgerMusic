import Foundation
import XCTest

@testable import AlgerKit

/// 下载 **替换事务** 与 **统一流程** 的回归。
///
/// 覆盖（真实文件 + 真实索引 + 真实持久化，全部落在 `.artifacts` 下）：
/// - **路径校验方向**：不同文件必须放行、同一 inode 必须拒绝；
/// - **连续两次升级**：第二次不得被第一次的 committed 记录挡住；
/// - **索引标签**：保留旧标签后，索引里必须是 **最终** 的标签；
/// - **废纸篓失败**：替换仍然成功，旧文件留待恢复（不重复入单）；
/// - **重启恢复**：`.committing` 状态能在下次启动补完；
/// - **部分迁移失败**：回滚，旧文件原样保留；
/// - **流程幂等**：重复 / 并发的完成事件只生效一次；
/// - **复用本地**：本地已有且质量不低时 **不下载**。
final class DownloadPipelineTests: XCTestCase {

    // MARK: - 夹具

    /// 替换事务夹具（真实索引 / 歌单 / 入单 / 持久状态）。
    private final class Fixture {
        let workspace: TempWorkspace
        let index: LibraryIndex
        let store: NativeStore
        let library: LocalLibrary
        let intake: DownloadIntakeService
        let autoSave: AutoSaveService
        /// 隔离的废纸篓目录（**绝不写真实用户废纸篓**）。
        let trashDirectory: URL
        /// 废纸篓失败注入（nil = 正常）。
        var trashFailure: String?

        init(_ label: String) throws {
            workspace = try TempWorkspace(label)
            index = LibraryIndex(fileURL: workspace.url("library/index.json"))
            store = NativeStore(fileURL: workspace.url("native.json"))
            library = LocalLibrary(index: index, store: store)
            intake = DownloadIntakeService(store: store, library: library)
            autoSave = AutoSaveService(store: store, library: library)
            trashDirectory = workspace.url("Trash")
            try FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true)
        }

        /// 废纸篓动作（**隔离目录**；`trashFailure` 非空时模拟失败）。
        func trashAction() -> DownloadReplacementService.TrashAction {
            let directory = trashDirectory
            return { [weak self] path in
                if let failure = self?.trashFailure { throw FeedbackFixtureError(message: failure) }
                let source = URL(fileURLWithPath: path)
                guard FileManager.default.fileExists(atPath: path) else { return }
                let target = directory.appendingPathComponent(source.lastPathComponent)
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.moveItem(at: source, to: target)
            }
        }

        /// 写一个本地文件并登记到索引。
        @discardableResult
        func addTrack(
            name: String,
            title: String,
            artist: String,
            album: String = "叶惠美",
            durationMs: Int = 269_000,
            neteaseId: Int64 = 0
        ) throws -> TrackRecord {
            let url = workspace.url("Music/\(name)")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("旧内容".utf8).write(to: url)
            let track = TrackRecord(
                path: url.path,
                neteaseId: neteaseId,
                title: title,
                artist: artist,
                album: album,
                durationMs: UInt64(max(0, durationMs))
            )
            try index.upsert(track)
            return track
        }

        /// 写一个 **新下载** 的文件（不在索引里）。
        func writeDownloaded(name: String, contents: String) throws -> URL {
            let url = workspace.url("Downloads/\(name)")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
            return url
        }
    }

    /// 标签读取夹具（按路径返回配置好的标签；**可变**，模拟写入后的重读）。
    final class TagReader: AudioTagReading, @unchecked Sendable {
        private let lock = NSLock()
        private var tags: [String: AudioTags]
        private let unreadable: Set<String>

        init(tags: [String: AudioTags] = [:], unreadable: Set<String> = []) {
            self.tags = tags
            self.unreadable = unreadable
        }

        func readAudioTags(path: String) async throws -> AudioTags {
            lock.lock()
            defer { lock.unlock() }
            if unreadable.contains(path) {
                throw FeedbackFixtureError(message: "标签读不出来")
            }
            guard let tags = tags[path] else {
                throw FeedbackFixtureError(message: "没有为该路径配置标签")
            }
            return tags
        }

        /// 写入标签（模拟「保留旧标签」之后的新文件状态）。
        func set(_ tags: AudioTags, for path: String) {
            lock.lock()
            defer { lock.unlock() }
            self.tags[path] = tags
        }
    }

    /// 标签保留夹具：把旧文件的 **非空标签** 覆盖到新文件（与真实实现同语义）。
    final class TagPreserver: TagPreserving, @unchecked Sendable {
        private let reader: TagReader

        init(reader: TagReader) {
            self.reader = reader
        }

        func preserveTags(from oldPath: String, to newPath: String) async throws {
            guard let old = try? await reader.readAudioTags(path: oldPath) else {
                throw FeedbackFixtureError(message: "读不出旧标签")
            }
            guard var updated = try? await reader.readAudioTags(path: newPath) else {
                throw FeedbackFixtureError(message: "读不出新标签")
            }
            // 只复制 **文本标签**（真实实现不碰编码 / 码率 / PCM 属性）。
            updated.title = old.title
            updated.artist = old.artist
            updated.album = old.album
            updated.albumArtist = old.albumArtist
            updated.genre = old.genre
            updated.date = old.date
            updated.path = newPath
            reader.set(updated, for: newPath)
        }
    }

    /// 永远失败的解析器（**不联网**）。
    private final class FailingResolver: AudioSourceResolving, @unchecked Sendable {
        func resolve(song: RemoteSong) async throws -> ResolvedAudio {
            throw FeedbackFixtureError(message: "不解析远端")
        }
    }

    /// 固定结果的解析器。
    private final class FixedResolver: AudioSourceResolving, @unchecked Sendable {
        private let audio: ResolvedAudio?
        private let failure: String?

        init(audio: ResolvedAudio? = nil, failure: String? = nil) {
            self.audio = audio
            self.failure = failure
        }

        func resolve(song: RemoteSong) async throws -> ResolvedAudio {
            if let failure { throw FeedbackFixtureError(message: failure) }
            guard let audio else {
                throw FeedbackFixtureError(message: "没有配置解析结果")
            }
            return audio
        }
    }

    private func makeSong(
        id: Int64 = 100,
        name: String = "晴天",
        artist: String = "周杰伦",
        album: String = "叶惠美",
        durationMs: Int = 269_000
    ) -> RemoteSong {
        RemoteSong(
            id: id,
            name: name,
            artists: [RemoteArtist(id: 9, name: artist)],
            album: RemoteAlbum(id: 3, name: album, picUrl: ""),
            durationMs: Int64(durationMs)
        )
    }

    private func makeTask(
        id: Int64,
        path: String,
        targets: [String] = [],
        name: String = "晴天",
        artist: String = "周杰伦",
        album: String = "叶惠美",
        durationMs: Int = 269_000,
        createdAt: Double = 1_000,
        updatedAt: Double = 1_000
    ) -> DownloadTask {
        DownloadTask(
            id: id,
            name: name,
            artist: artist,
            album: album,
            durationMs: Int64(durationMs),
            path: path,
            downloaded: 1,
            total: 1,
            percent: 100,
            status: "done",
            error: nil,
            source: "test",
            targets: targets,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    // MARK: - 路径校验方向（inode）

    /// **不同文件必须放行**（旧实现的判定方向反了：不同 inode 反而被拒绝）。
    func testDifferentFilesAreAcceptedForReplacement() async throws {
        let fixture = try Fixture("download-inode-different")
        let oldTrack = try fixture.addTrack(name: "old.flac", title: "晴天", artist: "周杰伦")
        let newFile = try fixture.writeDownloaded(name: "new.flac", contents: "新版本内容")
        let service = makeReplacement(fixture: fixture, tags: [
            oldTrack.path: lossyTags(path: oldTrack.path),
            newFile.path: losslessTags(path: newFile.path, sampleRate: 96_000, bitDepth: 24)
        ])

        try service.register(neteaseId: 1, oldPath: oldTrack.path)
        let outcome = await service.commit(neteaseId: 1, newPath: newFile.path)

        guard case .committed = outcome else {
            return XCTFail("不同文件必须允许替换，实际：\(outcome)")
        }
    }

    /// **同一个 inode**（硬链接）必须拒绝。
    func testSameInodeIsRejectedForReplacement() async throws {
        let fixture = try Fixture("download-inode-same")
        let oldTrack = try fixture.addTrack(name: "old.flac", title: "晴天", artist: "周杰伦")
        // 硬链接：同设备 + 同 inode，但是 **另一个路径**。
        let linkPath = fixture.workspace.url("Downloads/hardlink.flac")
        try FileManager.default.createDirectory(
            at: linkPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.linkItem(atPath: oldTrack.path, toPath: linkPath.path)

        let service = makeReplacement(fixture: fixture, tags: [
            oldTrack.path: lossyTags(path: oldTrack.path),
            linkPath.path: losslessTags(path: linkPath.path, sampleRate: 96_000, bitDepth: 24)
        ])
        try service.register(neteaseId: 2, oldPath: oldTrack.path)
        let outcome = await service.commit(neteaseId: 2, newPath: linkPath.path)

        guard case .failed(let reason) = outcome else {
            return XCTFail("同一 inode 必须拒绝替换，实际：\(outcome)")
        }
        XCTAssertTrue(reason.contains("同一个文件"), reason)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: oldTrack.path),
            "被拒绝时旧文件必须原样保留"
        )
    }

    /// 同一个 **路径** 也必须拒绝。
    func testSamePathIsRejectedForReplacement() async throws {
        let fixture = try Fixture("download-inode-same-path")
        let oldTrack = try fixture.addTrack(name: "old.flac", title: "晴天", artist: "周杰伦")
        let service = makeReplacement(fixture: fixture, tags: [
            oldTrack.path: lossyTags(path: oldTrack.path)
        ])
        try service.register(neteaseId: 3, oldPath: oldTrack.path)
        let outcome = await service.commit(neteaseId: 3, newPath: oldTrack.path)
        guard case .failed(let reason) = outcome else {
            return XCTFail("同一个路径必须拒绝替换，实际：\(outcome)")
        }
        XCTAssertTrue(reason.contains("同一个路径"), reason)
    }

    // MARK: - 连续两次升级

    /// 第二次质量升级 **不得** 被第一次的 committed 记录挡住。
    func testSecondUpgradeIsNotBlockedByPreviousCommittedRecord() async throws {
        let fixture = try Fixture("download-two-upgrades")
        let oldTrack = try fixture.addTrack(name: "old.mp3", title: "晴天", artist: "周杰伦")
        let middle = try fixture.writeDownloaded(name: "middle.flac", contents: "中等质量")
        let best = try fixture.writeDownloaded(name: "best.flac", contents: "最好质量")

        // 旧文件：有损 192 kbps；中间文件：无损 44.1k/16；最好文件：无损 96k/24。
        let service = makeReplacement(fixture: fixture, tags: [
            oldTrack.path: lossyTags(path: oldTrack.path),
            middle.path: losslessTags(path: middle.path, sampleRate: 44_100, bitDepth: 16),
            best.path: losslessTags(path: best.path, sampleRate: 96_000, bitDepth: 24)
        ])

        // 第一次升级：有损 → 无损。
        try service.register(neteaseId: 10, oldPath: oldTrack.path)
        let first = await service.commit(neteaseId: 10, newPath: middle.path)
        guard case .committed(let firstPath) = first else {
            return XCTFail("第一次升级应当成功，实际：\(first)")
        }
        XCTAssertEqual(firstPath, middle.path)

        // 第二次升级：无损 44.1k/16 → 无损 96k/24（**必须还能升级**）。
        try service.register(neteaseId: 10, oldPath: middle.path)
        let second = await service.commit(neteaseId: 10, newPath: best.path)
        guard case .committed(let secondPath) = second else {
            return XCTFail("第二次升级不得被第一次的记录挡住，实际：\(second)")
        }
        XCTAssertEqual(secondPath, best.path)
        XCTAssertNotNil(fixture.index.track(path: best.path), "索引必须指向第二次升级后的文件")
        XCTAssertNil(fixture.index.track(path: middle.path), "中间文件不得留在索引里")
    }

    // MARK: - 索引标签

    /// 保留旧标签之后，索引里必须是 **最终** 的标签（不能漏掉用户手工标签）。
    ///
    /// 用 **非身份字段**（流派 / 专辑艺人 / 发行日期）验证保留：
    /// 身份字段（标题 / 艺人）不一致属于 **身份冲突**，必须拒绝（见下一个用例）。
    func testIndexKeepsTagsAfterPreservation() async throws {
        let fixture = try Fixture("download-index-tags")
        let oldTrack = try fixture.addTrack(name: "old.flac", title: "晴天", artist: "周杰伦")
        let newFile = try fixture.writeDownloaded(name: "new.flac", contents: "新版本内容")

        // 旧文件带 **用户手工标签**；新文件带 **上游标签**（非身份字段不同）。
        var oldTags = losslessTags(
            path: oldTrack.path,
            sampleRate: 44_100,
            bitDepth: 16,
            title: "晴天",
            artist: "周杰伦"
        )
        oldTags.genre = "摇滚"
        oldTags.albumArtist = "周杰伦"
        oldTags.date = "2003-07-31"
        oldTags.album = "叶惠美（用户收藏版）"
        var newTags = losslessTags(
            path: newFile.path,
            sampleRate: 96_000,
            bitDepth: 24,
            title: "晴天",
            artist: "周杰伦"
        )
        newTags.genre = "流行"
        newTags.albumArtist = ""
        newTags.date = "2003"
        newTags.album = "叶惠美"

        let service = makeReplacement(fixture: fixture, tags: [
            oldTrack.path: oldTags,
            newFile.path: newTags
        ])
        try service.register(neteaseId: 20, oldPath: oldTrack.path)
        let outcome = await service.commit(neteaseId: 20, newPath: newFile.path)
        guard case .committed = outcome else {
            return XCTFail("替换应当成功，实际：\(outcome)")
        }
        let indexed = fixture.index.track(path: newFile.path)
        XCTAssertEqual(indexed?.title, "晴天", "索引必须保留用户手工标题")
        XCTAssertEqual(indexed?.artist, "周杰伦", "索引必须保留用户手工艺人")
        XCTAssertEqual(indexed?.album, "叶惠美（用户收藏版）", "索引必须保留用户手工专辑")
    }

    /// **身份冲突**（艺人不同）必须拒绝替换，并保留旧文件。
    func testDifferentArtistIsRejectedAsIdentityConflict() async throws {
        let fixture = try Fixture("download-identity-conflict")
        let oldTrack = try fixture.addTrack(name: "old.flac", title: "晴天", artist: "周杰伦")
        let newFile = try fixture.writeDownloaded(name: "new.flac", contents: "新版本内容")

        let service = makeReplacement(fixture: fixture, tags: [
            oldTrack.path: losslessTags(
                path: oldTrack.path,
                sampleRate: 44_100,
                bitDepth: 16,
                title: "晴天",
                artist: "周杰伦"
            ),
            newFile.path: losslessTags(
                path: newFile.path,
                sampleRate: 96_000,
                bitDepth: 24,
                title: "晴天",
                artist: "其他人"
            )
        ])
        try service.register(neteaseId: 21, oldPath: oldTrack.path)
        let outcome = await service.commit(neteaseId: 21, newPath: newFile.path)
        guard case .failed(let reason) = outcome else {
            return XCTFail("艺人不同必须拒绝替换，实际：\(outcome)")
        }
        XCTAssertTrue(reason.contains("艺人"), reason)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: oldTrack.path),
            "被拒绝时旧文件必须原样保留"
        )
        XCTAssertNotNil(fixture.index.track(path: oldTrack.path), "索引必须还指向旧文件")
    }

    // MARK: - 废纸篓失败

    /// 废纸篓失败 **不算替换失败**：新文件已在位，旧文件留待恢复（不重复入单）。
    func testTrashFailureKeepsCommittedStateAndRecoveryRetries() async throws {
        let fixture = try Fixture("download-trash-failure")
        let oldTrack = try fixture.addTrack(name: "old.flac", title: "晴天", artist: "周杰伦")
        let newFile = try fixture.writeDownloaded(name: "new.flac", contents: "新版本内容")
        let service = makeReplacement(fixture: fixture, tags: [
            oldTrack.path: lossyTags(path: oldTrack.path),
            newFile.path: losslessTags(path: newFile.path, sampleRate: 96_000, bitDepth: 24)
        ])
        fixture.trashFailure = "废纸篓不可用"

        try service.register(neteaseId: 30, oldPath: oldTrack.path)
        let outcome = await service.commit(neteaseId: 30, newPath: newFile.path)
        guard case .committedWithWarning(let path, let warning) = outcome else {
            return XCTFail("废纸篓失败必须如实报告（替换本身成功），实际：\(outcome)")
        }
        XCTAssertEqual(path, newFile.path)
        XCTAssertFalse(warning.isEmpty, "必须说明旧文件没移走")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: oldTrack.path),
            "旧文件没移走时必须仍在原处（不能删用户文件）"
        )
        let record = fixture.store.current.pendingReplacements.last { $0.neteaseId == 30 }
        XCTAssertEqual(record?.state, .committed, "替换本身必须记为已提交")
        XCTAssertEqual(record?.pendingTrashPath, oldTrack.path, "待清理路径必须记下来")

        // 废纸篓恢复：再试一次（这次成功）。
        fixture.trashFailure = nil
        let report = await service.repairPending()
        XCTAssertFalse(report.isEmpty, "恢复必须给出说明")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: oldTrack.path),
            "恢复后旧文件应当已移入隔离废纸篓"
        )
        let after = fixture.store.current.pendingReplacements.last { $0.neteaseId == 30 }
        XCTAssertEqual(after?.pendingTrashPath, "", "清理完成后不得再留待清理路径")
    }

    // MARK: - 重启恢复

    /// 上次崩在 `.committing`：下次启动必须把引用迁移补完。
    func testRestartRecoveryFinishesInterruptedCommit() async throws {
        let fixture = try Fixture("download-restart-recovery")
        let oldTrack = try fixture.addTrack(name: "old.flac", title: "晴天", artist: "周杰伦")
        let newFile = try fixture.writeDownloaded(name: "new.flac", contents: "新版本内容")

        // 模拟崩溃：记录停在 `.committing`（新路径已写入，引用还没迁完）。
        try fixture.store.mutate { state in
            state.pendingReplacements.append(PendingReplacement(
                neteaseId: 40,
                oldPath: oldTrack.path,
                newPath: newFile.path,
                state: .committing
            ))
        }
        let service = makeReplacement(fixture: fixture, tags: [
            oldTrack.path: lossyTags(path: oldTrack.path),
            newFile.path: losslessTags(path: newFile.path, sampleRate: 96_000, bitDepth: 24)
        ])

        let report = await service.repairPending()
        XCTAssertFalse(report.isEmpty, "恢复必须给出说明")
        XCTAssertNotNil(fixture.index.track(path: newFile.path), "索引必须迁到新路径")
        XCTAssertNil(fixture.index.track(path: oldTrack.path), "旧路径不得留在索引里")
        let record = fixture.store.current.pendingReplacements.last { $0.neteaseId == 40 }
        XCTAssertEqual(record?.state, .committed, "恢复后必须记为已提交")
    }

    // MARK: - 部分迁移失败

    /// 歌单读不出来 → 迁移整体失败 → **回滚**，旧文件原样保留。
    func testPartialMigrationFailureRollsBackAndKeepsOldFile() async throws {
        let fixture = try Fixture("download-partial-migration")
        let oldTrack = try fixture.addTrack(name: "old.flac", title: "晴天", artist: "周杰伦")
        let newFile = try fixture.writeDownloaded(name: "new.flac", contents: "新版本内容")

        // 造一个 **读不出来** 的歌单：M3U8 路径其实是个目录。
        try fixture.store.mutate { state in
            state.playlists.append(LocalPlaylistRecord(
                id: "pl-broken",
                title: "坏歌单",
                fileName: "broken.m3u8",
                directory: fixture.workspace.url("Playlists").path,
                createdAt: 1,
                updatedAt: 1
            ))
        }
        try FileManager.default.createDirectory(
            at: fixture.workspace.url("Playlists/broken.m3u8"),
            withIntermediateDirectories: true
        )

        let service = makeReplacement(fixture: fixture, tags: [
            oldTrack.path: lossyTags(path: oldTrack.path),
            newFile.path: losslessTags(path: newFile.path, sampleRate: 96_000, bitDepth: 24)
        ])
        try service.register(neteaseId: 50, oldPath: oldTrack.path)
        let outcome = await service.commit(neteaseId: 50, newPath: newFile.path)

        guard case .failed(let reason) = outcome else {
            return XCTFail("迁移失败必须如实失败，实际：\(outcome)")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: oldTrack.path),
            "迁移失败时旧文件必须原样保留"
        )
        XCTAssertNotNil(
            fixture.index.track(path: oldTrack.path),
            "回滚后索引必须还指向旧文件"
        )
        XCTAssertNil(fixture.index.track(path: newFile.path), "回滚后不得留下新路径的索引")
    }

    // MARK: - 流程幂等

    /// 重复的「下载完成」事件 **只生效一次**（入单一次、索引一条）。
    func testDuplicateCompletionEventsAreIdempotent() async throws {
        let fixture = try Fixture("download-duplicate-events")
        let downloaded = try fixture.writeDownloaded(name: "song.mp3", contents: "音频内容")
        let playlist = try makePlaylist(fixture: fixture)

        let pipeline = makePipeline(fixture: fixture)
        let task = makeTask(id: 60, path: downloaded.path, targets: [playlist.id])

        let first = await pipeline.completeDownload(task: task)
        let second = await pipeline.completeDownload(task: task)

        XCTAssertEqual(first.confirmedPlaylistIds, [playlist.id])
        XCTAssertEqual(second.confirmedPlaylistIds, [playlist.id], "重复事件必须报同样的结果")
        let entries = try fixture.library.playlist(id: playlist.id)?.entries ?? []
        XCTAssertEqual(entries.filter { $0.path == downloaded.path }.count, 1, "不得重复入单")
        let indexed = fixture.index.tracks.filter { $0.path == downloaded.path }
        XCTAssertEqual(indexed.count, 1, "索引不得出现重复条目")
    }

    /// **并发** 的完成事件也只生效一次。
    func testConcurrentCompletionEventsAreIdempotent() async throws {
        let fixture = try Fixture("download-concurrent-events")
        let downloaded = try fixture.writeDownloaded(name: "song.mp3", contents: "音频内容")
        let playlist = try makePlaylist(fixture: fixture)

        let pipeline = makePipeline(fixture: fixture)
        let task = makeTask(id: 61, path: downloaded.path, targets: [playlist.id])

        async let first = pipeline.completeDownload(task: task)
        async let second = pipeline.completeDownload(task: task)
        _ = await (first, second)

        let entries = try fixture.library.playlist(id: playlist.id)?.entries ?? []
        XCTAssertEqual(entries.filter { $0.path == downloaded.path }.count, 1, "并发事件不得重复入单")
    }

    /// 本地已有且质量不低 → **不下载**（不碰桥接）。
    func testReuseLocalDoesNotQueueDownload() async throws {
        let fixture = try Fixture("download-reuse-local")
        let track = try fixture.addTrack(name: "song.mp3", title: "晴天", artist: "周杰伦")
        let playlist = try makePlaylist(fixture: fixture)

        let pipeline = makePipeline(fixture: fixture, resolver: FixedResolver(failure: "不解析"))
        let outcome = await pipeline.requestDownload(
            song: makeSong(),
            targets: [playlist.id],
            purpose: .playlistAddition,
            directory: nil
        )
        guard case .reusedLocal(let path, _, let added) = outcome else {
            return XCTFail("本地已有可用文件时必须复用，实际：\(outcome)")
        }
        XCTAssertEqual(path, track.path)
        XCTAssertFalse(added.isEmpty, "复用本地时必须真的入单")
        let entries = try fixture.library.playlist(id: playlist.id)?.entries ?? []
        XCTAssertEqual(entries.count, 1)
    }

    /// 索引写失败 → 自动保存 **不得** 记为已保存（保持可重试）。
    func testAutoSaveIsNotMarkedSavedWhenIntakeFails() async throws {
        let fixture = try Fixture("download-autosave-index-failure")
        let downloaded = try fixture.writeDownloaded(name: "song.mp3", contents: "音频内容")

        // 登记一条自动保存记录（pending）。
        try fixture.autoSave.markEnqueued(
            neteaseId: 70,
            title: "晴天",
            artist: "周杰伦",
            durationMs: 269_000
        )

        // 让索引写不进去：把索引文件换成 **损坏** 的 JSON（索引会拒绝写入）。
        let indexURL = fixture.workspace.url("library/index.json")
        try FileManager.default.createDirectory(
            at: indexURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{ 这不是合法 JSON".utf8).write(to: indexURL)
        let brokenIndex = LibraryIndex(fileURL: indexURL)
        let brokenLibrary = LocalLibrary(index: brokenIndex, store: fixture.store)
        let brokenIntake = DownloadIntakeService(store: fixture.store, library: brokenLibrary)

        let pipeline = DownloadPipeline(
            library: brokenLibrary,
            intake: brokenIntake,
            review: DownloadReviewService(
                library: brokenLibrary,
                tagReader: TagReader(),
                resolver: FailingResolver()
            ),
            replacement: DownloadReplacementService(
                store: fixture.store,
                index: brokenIndex,
                library: brokenLibrary,
                intake: brokenIntake,
                review: DownloadReviewService(
                    library: brokenLibrary,
                    tagReader: TagReader(),
                    resolver: FailingResolver()
                ),
                trash: fixture.trashAction()
            ),
            autoSave: fixture.autoSave,
            bridge: makeBridge(),
            metadataCompletion: nil
        )

        let task = makeTask(id: 70, path: downloaded.path)
        let result = await pipeline.completeDownload(task: task)
        XCTAssertNotNil(result.indexError, "索引写失败必须被报告")
        XCTAssertEqual(
            fixture.autoSave.record(neteaseId: 70)?.state,
            .failed,
            "索引写失败时自动保存不得记为已保存"
        )
    }

    // MARK: - 复核补的回归

    /// 恢复 / 重试迁移后 **索引条目不得被清空**（来源 ID 与标题都还在）。
    ///
    /// 场景：索引已经迁到新路径（旧条目已删），但替换记录仍停在 `.committing`
    /// → 恢复时 `oldTrack == nil`，绝不能拿空记录覆盖已迁好的条目。
    func testRecoveryKeepsIndexEntryWhenOldTrackIsGone() async throws {
        let fixture = try Fixture("download-recovery-index-merge")
        let oldTrack = try fixture.addTrack(
            name: "old.flac",
            title: "晴天",
            artist: "周杰伦",
            neteaseId: 777
        )
        let newFile = try fixture.writeDownloaded(name: "new.flac", contents: "新版本内容")

        // 模拟「索引已迁到新路径、旧条目已删，但记录仍停在 .committing」。
        try fixture.index.mutate { tracks in
            tracks.removeAll { $0.path == oldTrack.path }
            tracks.append(TrackRecord(
                path: newFile.path,
                neteaseId: 777,
                title: "晴天",
                artist: "周杰伦",
                album: "叶惠美",
                durationMs: 269_000
            ))
        }
        try fixture.store.mutate { state in
            state.pendingReplacements.append(PendingReplacement(
                neteaseId: 80,
                oldPath: oldTrack.path,
                newPath: newFile.path,
                state: .committing
            ))
        }

        let service = makeReplacement(fixture: fixture, tags: [
            oldTrack.path: lossyTags(path: oldTrack.path),
            newFile.path: losslessTags(path: newFile.path, sampleRate: 96_000, bitDepth: 24)
        ])
        _ = await service.repairPending()

        let indexed = fixture.index.track(path: newFile.path)
        XCTAssertEqual(indexed?.neteaseId, 777, "来源 ID 不能被清空（否则按 ID 去重失效）")
        XCTAssertEqual(indexed?.title, "晴天", "标题不能被清空")
        XCTAssertEqual(indexed?.artist, "周杰伦", "艺人不能被清空")
    }

    /// **放弃替换** 之后的重复完成事件：必须用 **存活路径**（旧文件），
    /// 歌单里只能有一条条目。
    func testRepeatedEventAfterDiscardUsesSurvivingOldFile() async throws {
        let fixture = try Fixture("download-discard-repeat")
        let oldTrack = try fixture.addTrack(name: "old.mp3", title: "晴天", artist: "周杰伦")
        let newFile = try fixture.writeDownloaded(name: "new.mp3", contents: "新下载内容")

        // 替换被放弃（实测不比旧版本好）：记录状态 = `.discarded`，新文件仍在磁盘上。
        try fixture.store.mutate { state in
            state.pendingReplacements.append(PendingReplacement(
                neteaseId: 90,
                oldPath: oldTrack.path,
                newPath: newFile.path,
                state: .discarded,
                lastError: "新下载版本不比本地版本好"
            ))
        }
        let playlist = try makePlaylist(fixture: fixture)
        let pipeline = makePipeline(fixture: fixture)
        let task = makeTask(id: 90, path: newFile.path, targets: [playlist.id])

        let result = await pipeline.completeDownload(task: task)
        XCTAssertEqual(result.path, oldTrack.path, "存活路径必须是旧文件（不是被弃掉的新文件）")
        let entries = try fixture.library.playlist(id: playlist.id)?.entries ?? []
        XCTAssertEqual(entries.count, 1, "歌单里只能有一条条目")
        XCTAssertEqual(entries.first?.path, oldTrack.path, "入单的必须是旧文件")
        XCTAssertNil(
            fixture.index.track(path: newFile.path),
            "被弃掉的新文件不得进索引"
        )
    }

    /// 自动保存的收尾必须走 **统一流程**：文件进索引 + 记为已保存。
    func testAutoSaveCompletionGoesThroughUnifiedPipeline() async throws {
        let fixture = try Fixture("download-autosave-unified")
        let downloaded = try fixture.writeDownloaded(name: "song.mp3", contents: "音频内容")
        try fixture.autoSave.markEnqueued(
            neteaseId: 95,
            title: "晴天",
            artist: "周杰伦",
            durationMs: 269_000
        )
        let pipeline = makePipeline(fixture: fixture)
        let task = makeTask(id: 95, path: downloaded.path)

        let result = await pipeline.completeDownload(task: task)
        XCTAssertTrue(result.notes.isEmpty, "收尾不应有失败项：\(result.notes)")
        let indexed = fixture.index.track(path: downloaded.path)
        XCTAssertNotNil(indexed, "文件必须进索引（否则资料库里查不到）")
        XCTAssertEqual(indexed?.neteaseId, 95, "索引必须带来源 ID")
        XCTAssertEqual(indexed?.title, "晴天")
        XCTAssertEqual(
            fixture.autoSave.record(neteaseId: 95)?.state,
            .saved,
            "自动保存必须记为已保存"
        )
    }

    /// 登记新的替换意图时，同曲若还有 **中断的 `.committing`** 记录：
    /// **必须拒绝**（先让 `repairPending()` 收尾），且旧记录保持完整。
    func testRegisterRefusesWhileInterruptedCommitExists() async throws {
        let fixture = try Fixture("download-register-committing")
        let oldTrack = try fixture.addTrack(name: "old.flac", title: "晴天", artist: "周杰伦")
        let interrupted = fixture.workspace.url("Downloads/interrupted.flac")
        try fixture.store.mutate { state in
            state.pendingReplacements.append(PendingReplacement(
                neteaseId: 96,
                oldPath: oldTrack.path,
                newPath: interrupted.path,
                state: .committing
            ))
        }
        let service = makeReplacement(fixture: fixture, tags: [
            oldTrack.path: lossyTags(path: oldTrack.path),
            interrupted.path: losslessTags(path: interrupted.path, sampleRate: 96_000, bitDepth: 24)
        ])

        // **必须拒绝**：不能同曲再开一条事务（旧迁移会变成孤儿）。
        XCTAssertThrowsError(try service.register(neteaseId: 96, oldPath: oldTrack.path)) { error in
            guard let rejection = error as? DownloadReplacementError else {
                return XCTFail("期望 DownloadReplacementError，实际 \(error)")
            }
            XCTAssertTrue(rejection.description.contains("收尾"), rejection.description)
        }

        let records = fixture.store.current.pendingReplacements.filter { $0.neteaseId == 96 }
        XCTAssertEqual(records.count, 1, "不得另建 pending 记录（只能有一条事务）")
        XCTAssertEqual(records.first?.state, .committing, "旧记录必须保持 .committing")
        XCTAssertEqual(records.first?.newPath, interrupted.path, "旧记录必须完整")
    }

    /// 恢复完成后才可以登记新的替换意图。
    func testRegisterSucceedsAfterRecoveryFinishesTheInterruptedCommit() async throws {
        let fixture = try Fixture("download-register-after-recovery")
        let oldTrack = try fixture.addTrack(name: "old.flac", title: "晴天", artist: "周杰伦")
        let interrupted = try fixture.writeDownloaded(name: "interrupted.flac", contents: "上一轮的新版本")
        try fixture.store.mutate { state in
            state.pendingReplacements.append(PendingReplacement(
                neteaseId: 97,
                oldPath: oldTrack.path,
                newPath: interrupted.path,
                state: .committing
            ))
        }
        let service = makeReplacement(fixture: fixture, tags: [
            oldTrack.path: lossyTags(path: oldTrack.path),
            interrupted.path: losslessTags(path: interrupted.path, sampleRate: 96_000, bitDepth: 24)
        ])
        let report = await service.repairPending()
        XCTAssertFalse(report.isEmpty, "恢复必须给出说明")
        let committing = fixture.store.current.pendingReplacements.filter {
            $0.neteaseId == 97 && $0.state == .committing
        }
        XCTAssertTrue(committing.isEmpty, "恢复后不得还有 .committing 记录")

        // 现在可以登记新的替换意图。
        XCTAssertNoThrow(try service.register(neteaseId: 97, oldPath: interrupted.path))
    }

    // MARK: - 时间戳（跨重启恢复）

    /// Rust 侧发的是 **毫秒** → 解析边界必须归一化到 **秒**。
    func testTaskTimestampsAreNormalizedToSeconds() throws {
        let nowSeconds = Date().timeIntervalSince1970
        let millis = (nowSeconds * 1000).rounded()
        let task = try XCTUnwrap(DownloadTask.parse([
            "id": 1,
            "name": "曲目",
            "status": "queued",
            "createdAt": millis,
            "updatedAt": millis
        ]))
        XCTAssertEqual(
            task.createdAt,
            millis / 1000,
            accuracy: 0.0001,
            "毫秒时间戳必须换算成秒"
        )
        XCTAssertEqual(
            task.updatedAt,
            millis / 1000,
            accuracy: 0.0001,
            "毫秒时间戳必须换算成秒"
        )
    }

    /// 旧数据已经是 **秒** → 原样保留（不能被再除一次）。
    func testTaskTimestampsKeepLegacySeconds() throws {
        let seconds = Date().timeIntervalSince1970
        let task = try XCTUnwrap(DownloadTask.parse([
            "id": 2,
            "name": "曲目",
            "status": "queued",
            "createdAt": seconds,
            "updatedAt": seconds
        ]))
        XCTAssertEqual(task.createdAt, seconds, accuracy: 0.001)
        XCTAssertEqual(task.updatedAt, seconds, accuracy: 0.001)
    }

    /// 缺失 / 0 → 0（不猜）。
    func testTaskTimestampsFallBackToZero() throws {
        let task = try XCTUnwrap(DownloadTask.parse([
            "id": 3,
            "name": "曲目",
            "status": "queued"
        ]))
        XCTAssertEqual(task.createdAt, 0)
        XCTAssertEqual(task.updatedAt, 0)
    }

    /// **上次会话遗留** 的任务：时间戳必须 **小于** 本次会话开始时间，
    /// 否则会被当成本次会话 → 跨重启恢复被跳过。
    func testLegacyTaskTimestampIsBeforeSessionStart() throws {
        let sessionStartedAt = Date().timeIntervalSince1970
        // 上一会话：10 分钟前（Rust 发的毫秒）。
        let legacySeconds = sessionStartedAt - 600
        let task = try XCTUnwrap(DownloadTask.parse([
            "id": 4,
            "name": "曲目",
            "status": "running",
            "createdAt": legacySeconds * 1000,
            "updatedAt": legacySeconds * 1000
        ]))
        let stamp = max(task.updatedAt, task.createdAt)
        XCTAssertLessThan(
            stamp,
            sessionStartedAt,
            "上次会话的任务必须被识别为「不是本次会话」（否则跨重启恢复会被跳过）"
        )
    }

    // MARK: - 内部

    /// 造一个替换服务（标签夹具 + 标签保留 + 隔离废纸篓）。
    ///
    /// - Parameters:
    ///   - tags: 每个路径的标签（读标签夹具）。
    private func makeReplacement(
        fixture: Fixture,
        tags: [String: AudioTags]
    ) -> DownloadReplacementService {
        let reader = TagReader(tags: tags)
        let review = DownloadReviewService(
            library: fixture.library,
            tagReader: reader,
            resolver: FailingResolver()
        )
        return DownloadReplacementService(
            store: fixture.store,
            index: fixture.index,
            library: fixture.library,
            intake: fixture.intake,
            review: review,
            tagPreserver: TagPreserver(reader: reader),
            trash: fixture.trashAction()
        )
    }

    /// 有损标签（192 kbps MP3）。
    private func lossyTags(path: String, title: String = "晴天", artist: String = "周杰伦") -> AudioTags {
        AudioTags(
            path: path,
            format: "mp3",
            durationMs: 269_000,
            bitrate: 192_000,
            sampleRate: 44_100,
            codec: "mp3",
            title: title,
            artist: artist,
            album: "叶惠美"
        )
    }

    /// 无损标签（FLAC）。
    private func losslessTags(
        path: String,
        sampleRate: Int,
        bitDepth: Int,
        bitrate: Int = 900_000,
        title: String = "晴天",
        artist: String = "周杰伦"
    ) -> AudioTags {
        AudioTags(
            path: path,
            format: "flac",
            durationMs: 269_000,
            bitrate: bitrate,
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            codec: "flac",
            title: title,
            artist: artist,
            album: "叶惠美"
        )
    }

    /// 造一个本地歌单（真实 M3U8）。
    private func makePlaylist(fixture: Fixture) throws -> LocalPlaylist {
        try fixture.store.mutate { state in
            state.settings.playlistsDirectory = fixture.workspace.url("Playlists").path
        }
        return try fixture.library.createPlaylist(title: "测试歌单")
    }

    /// 造一个下载流程（**不联网**：桥接用回声夹具）。
    private func makePipeline(
        fixture: Fixture,
        resolver: AudioSourceResolving? = nil
    ) -> DownloadPipeline {
        let review = DownloadReviewService(
            library: fixture.library,
            tagReader: TagReader(),
            resolver: resolver ?? FailingResolver()
        )
        return DownloadPipeline(
            library: fixture.library,
            intake: fixture.intake,
            review: review,
            replacement: DownloadReplacementService(
                store: fixture.store,
                index: fixture.index,
                library: fixture.library,
                intake: fixture.intake,
                review: review,
                trash: fixture.trashAction()
            ),
            autoSave: fixture.autoSave,
            bridge: makeBridge(),
            metadataCompletion: nil
        )
    }

    /// 回声桥接（真实子进程；**不联网**）。
    private func makeBridge() -> BridgeService {
        BridgeService(client: TestBridgeFactory.shared.echoClient())
    }
}

/// 测试用桥接（回声夹具，**真实子进程**，不联网）。
enum TestBridgeFactory {
    final class Holder {
        private var client: BridgeClient?
        private var workspace: TempWorkspace?

        func echoClient() -> BridgeClient {
            if let client { return client }
            let workspace = try! TempWorkspace("bridge-echo")
            let script = try! workspace.writeScript(Fixtures.echoServer, named: "fixture.sh")
            let client = try! BridgeClient(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [script.path]
            )
            self.client = client
            self.workspace = workspace
            return client
        }
    }

    static let shared = Holder()
}
