import Foundation
import XCTest

@testable import AlgerKit

#if canImport(Darwin)
import Darwin
#endif

/// 本地资料库（索引 + 歌单注册表 + M3U8）的回归。
final class LocalLibraryTests: XCTestCase {

    private struct Fixture {
        let workspace: TempWorkspace
        let index: LibraryIndex
        let store: NativeStore
        let library: LocalLibrary
        let playlistsDir: URL
        let audioDir: URL
    }

    private func makeFixture(_ label: String) throws -> Fixture {
        let workspace = try TempWorkspace(label)
        let index = LibraryIndex(fileURL: workspace.url("library/index.json"))
        let store = NativeStore(fileURL: workspace.url("native.json"))
        let playlistsDir = workspace.root.appendingPathComponent("Playlists", isDirectory: true)
        let audioDir = workspace.root.appendingPathComponent("Music", isDirectory: true)
        try FileManager.default.createDirectory(at: playlistsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        try store.mutate { state in
            state.settings.playlistsDirectory = playlistsDir.path
            state.settings.libraryFolders = [audioDir.path]
        }
        let library = LocalLibrary(index: index, store: store)
        return Fixture(
            workspace: workspace,
            index: index,
            store: store,
            library: library,
            playlistsDir: playlistsDir,
            audioDir: audioDir
        )
    }

    @discardableResult
    private func makeAudio(
        _ fixture: Fixture,
        _ name: String,
        neteaseId: Int64 = 0,
        title: String = "",
        artist: String = ""
    ) throws -> URL {
        let url = fixture.audioDir.appendingPathComponent(name, isDirectory: false)
        try TestAudio.writeWAV(to: url, seconds: 0.2)
        try fixture.index.upsert(TrackRecord(
            path: url.path,
            neteaseId: neteaseId,
            title: title.isEmpty ? name : title,
            artist: artist,
            album: "测试专辑",
            durationMs: 200,
            format: "wav",
            size: UInt64(try Data(contentsOf: url).count),
            modifiedAt: Date().timeIntervalSince1970
        ))
        return url
    }

    // MARK: - 身份关联（只认明确来源 ID）

    /// 同名同艺人但来源 ID 不同 → **不得**被当成同一录音。
    func testMatchLocalTrackOnlyUsesExplicitSourceID() throws {
        let fixture = try makeFixture("library-identity")
        let a = try makeAudio(fixture, "a.wav", neteaseId: 111, title: "同一首歌", artist: "同一艺人")
        let b = try makeAudio(fixture, "b.wav", neteaseId: 222, title: "同一首歌", artist: "同一艺人")

        let matched = fixture.library.matchLocalTrack(neteaseId: 222)
        XCTAssertEqual(matched?.path, b.path, "必须按来源 ID 命中，不能按标题 + 艺人")
        XCTAssertNotEqual(matched?.path, a.path)

        // 未登记来源 ID 的曲目永远不会被自动命中。
        XCTAssertNil(fixture.library.matchLocalTrack(neteaseId: 999))
        XCTAssertNil(fixture.library.matchLocalTrack(neteaseId: 0))
    }

    /// 没有来源 ID 的本地文件 **不得** 被任何网络曲目自动匹配上。
    func testUntaggedLocalFileIsNeverAutoMatched() throws {
        let fixture = try makeFixture("library-untagged")
        try makeAudio(fixture, "x.wav", neteaseId: 0, title: "歌", artist: "人")
        XCTAssertNil(fixture.library.matchLocalTrack(neteaseId: 12345))
    }

    /// 索引里有记录但文件已删除 → 不算命中（避免播放到不存在的文件）。
    func testMatchLocalTrackRequiresExistingFile() throws {
        let fixture = try makeFixture("library-missing-file")
        let url = try makeAudio(fixture, "gone.wav", neteaseId: 7)
        XCTAssertNotNil(fixture.library.matchLocalTrack(neteaseId: 7))
        try FileManager.default.removeItem(at: url)
        XCTAssertNil(fixture.library.matchLocalTrack(neteaseId: 7), "文件不存在时不得命中")
    }

    /// 明确确认关联后，来源 ID 生效。
    func testConfirmAssociationPersistsSourceID() throws {
        let fixture = try makeFixture("library-confirm")
        let url = try makeAudio(fixture, "c.wav", neteaseId: 0)
        XCTAssertNil(fixture.library.matchLocalTrack(neteaseId: 555))
        try fixture.library.confirmAssociation(localPath: url.path, neteaseId: 555)
        XCTAssertEqual(fixture.library.matchLocalTrack(neteaseId: 555)?.path, url.path)
        // 关联是持久的（重启后仍在）。
        let reopened = LibraryIndex(fileURL: fixture.workspace.url("library/index.json"))
        let reopenedLibrary = LocalLibrary(index: reopened, store: fixture.store)
        XCTAssertEqual(reopenedLibrary.matchLocalTrack(neteaseId: 555)?.path, url.path)
    }

    // MARK: - 歌单（M3U8 + 注册表）

    /// 新建歌单 → 稳定 ID + 标题 + 描述 + M3U8 文件。
    func testCreatePlaylistKeepsStableIDAndMetadata() throws {
        let fixture = try makeFixture("library-create")
        let playlist = try fixture.library.createPlaylist(title: "我的歌单", details: "描述")
        XCTAssertTrue(playlist.id.hasPrefix("pl-"))
        XCTAssertEqual(playlist.title, "我的歌单")
        XCTAssertEqual(playlist.details, "描述")
        XCTAssertTrue(FileManager.default.fileExists(atPath: playlist.fileURL.path))
        XCTAssertEqual(fixture.store.current.playlists.count, 1)

        // 改名 / 改描述：**稳定 ID 不变**。
        try fixture.library.updatePlaylist(id: playlist.id, title: "新名字", details: "新描述")
        let updated = try fixture.library.playlist(id: playlist.id)
        XCTAssertEqual(updated?.id, playlist.id, "稳定 ID 不能变")
        XCTAssertEqual(updated?.title, "新名字")
        XCTAssertEqual(updated?.details, "新描述")
        XCTAssertEqual(fixture.store.current.playlists.first?.id, playlist.id)
    }

    /// 加入 / 移除曲目 → M3U8 真的变了，音频文件保留。
    func testAddAndRemoveEntriesUpdatesM3U8AndKeepsAudio() throws {
        let fixture = try makeFixture("library-entries")
        let playlist = try fixture.library.createPlaylist(title: "歌单")
        let audio = try makeAudio(fixture, "song.wav", neteaseId: 42, title: "曲")

        try fixture.library.addToPlaylist(id: playlist.id, entries: [PlaylistEntry(
            path: audio.path,
            duration: 0.2,
            displayName: "曲"
        )])
        let reloaded = try fixture.library.playlist(id: playlist.id)
        XCTAssertEqual(reloaded?.entries.count, 1)
        XCTAssertEqual(reloaded?.entries.first?.path, audio.path)

        let text = try String(contentsOf: playlist.fileURL, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("#EXTM3U"), text)
        XCTAssertTrue(text.contains("song.wav"), text)

        try fixture.library.removeFromPlaylist(id: playlist.id, paths: [audio.path])
        let emptied = try fixture.library.playlist(id: playlist.id)
        XCTAssertEqual(emptied?.entries.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path), "移出歌单不得删除音频")
    }

    /// 同批条目 **按路径去重**。
    func testAddToPlaylistDeduplicatesWithinSameBatch() throws {
        let fixture = try makeFixture("library-dedupe")
        let playlist = try fixture.library.createPlaylist(title: "歌单")
        let audio = try makeAudio(fixture, "dup.wav", neteaseId: 1)

        try fixture.library.addToPlaylist(id: playlist.id, entries: [
            PlaylistEntry(path: audio.path, duration: 0.2, displayName: "重复"),
            PlaylistEntry(path: audio.path, duration: 0.2, displayName: "重复"),
            PlaylistEntry(path: audio.path, duration: 0.2, displayName: "重复"),
        ])
        let reloaded = try fixture.library.playlist(id: playlist.id)
        XCTAssertEqual(reloaded?.entries.count, 1, "同一批里的重复路径只能保留一条")
    }

    /// 已经是歌单里的条目，重复加入不会产生第二条。
    func testAddToPlaylistSkipsExistingEntries() throws {
        let fixture = try makeFixture("library-dedupe-existing")
        let playlist = try fixture.library.createPlaylist(title: "歌单")
        let audio = try makeAudio(fixture, "dup2.wav", neteaseId: 2)
        let entry = PlaylistEntry(path: audio.path, duration: 0.2, displayName: "曲")
        try fixture.library.addToPlaylist(id: playlist.id, entries: [entry])
        try fixture.library.addToPlaylist(id: playlist.id, entries: [entry])
        let reloaded = try fixture.library.playlist(id: playlist.id)
        XCTAssertEqual(reloaded?.entries.count, 1)
    }

    /// 删除歌单 → M3U8 与注册表都清掉，音频保留。
    func testDeletePlaylistRemovesFileAndRegistryButKeepsAudio() throws {
        let fixture = try makeFixture("library-delete")
        let playlist = try fixture.library.createPlaylist(title: "待删")
        let audio = try makeAudio(fixture, "keep.wav", neteaseId: 3)
        try fixture.library.addToPlaylist(id: playlist.id, entries: [PlaylistEntry(path: audio.path)])

        try fixture.library.deletePlaylist(id: playlist.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: playlist.fileURL.path))
        XCTAssertTrue(fixture.store.current.playlists.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path), "删歌单不得删音频")
    }

    // MARK: - 部分失败：不得假成功

    /// M3U8 写失败 → 抛错，歌单内容与注册表都不变，**不留待恢复日志**。
    func testAddToPlaylistFailureDoesNotFakeSuccess() throws {
        let fixture = try makeFixture("library-write-fail")
        let playlist = try fixture.library.createPlaylist(title: "歌单")
        let audio = try makeAudio(fixture, "x.wav", neteaseId: 4)

        // 让歌单目录不可写 → 临时文件无法创建 → 落盘失败。
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: fixture.playlistsDir.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: fixture.playlistsDir.path
            )
        }

        XCTAssertThrowsError(try fixture.library.addToPlaylist(id: playlist.id, entries: [
            PlaylistEntry(path: audio.path)
        ]))
        let after = try fixture.library.playlist(id: playlist.id)
        XCTAssertEqual(after?.entries.count, 0, "写失败时歌单内容不得变化")
        XCTAssertTrue(fixture.store.current.pendingOperations.isEmpty, "写失败不应留下待恢复日志")
    }

    /// 删除歌单中途失败（文件删不掉）→ **留下可恢复日志**，修复后状态一致。
    func testDeletePlaylistFailureLeavesRecoverableOperation() throws {
        let fixture = try makeFixture("library-delete-recover")
        let playlist = try fixture.library.createPlaylist(title: "待删")
        let audio = try makeAudio(fixture, "y.wav", neteaseId: 5)

        // 歌单目录只读 → 删不掉 M3U8；native.json 在别处，仍可写。
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: fixture.playlistsDir.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: fixture.playlistsDir.path
            )
        }

        XCTAssertThrowsError(try fixture.library.deletePlaylist(id: playlist.id))
        let pending = fixture.store.current.pendingOperations
        XCTAssertEqual(pending.count, 1, "删除失败必须留下可恢复日志")
        XCTAssertEqual(pending.first?.kind, .deletePlaylist)
        XCTAssertTrue(FileManager.default.fileExists(atPath: playlist.fileURL.path), "文件没删掉")
        XCTAssertEqual(fixture.store.current.playlists.count, 1, "注册表条目必须还在（否则就是假成功）")

        // 恢复权限后修复：文件与注册表一起清掉，日志清空。
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fixture.playlistsDir.path
        )
        let report = try fixture.library.repairPendingOperations()
        XCTAssertFalse(report.isEmpty, "修复应当有说明")
        XCTAssertFalse(FileManager.default.fileExists(atPath: playlist.fileURL.path))
        XCTAssertTrue(fixture.store.current.playlists.isEmpty)
        XCTAssertTrue(fixture.store.current.pendingOperations.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path), "音频不受影响")
    }

    /// 外部改动歌单文件 → **不得**被静默覆盖（外部条目仍在）。
    func testExternalPlaylistModificationIsNotSilentlyOverwritten() throws {
        let fixture = try makeFixture("library-conflict")
        let playlist = try fixture.library.createPlaylist(title: "歌单")
        let audio = try makeAudio(fixture, "z.wav", neteaseId: 6)

        // 外部直接改写 M3U8（追加一条外部条目）。
        var external = try String(contentsOf: playlist.fileURL, encoding: .utf8)
        external += "#EXTINF:1,外部写入\n外部条目.mp3\n"
        try external.write(to: playlist.fileURL, atomically: true, encoding: .utf8)

        try fixture.library.addToPlaylist(id: playlist.id, entries: [
            PlaylistEntry(path: audio.path)
        ])
        let text = try String(contentsOf: playlist.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("外部条目.mp3"), "外部内容不得被覆盖：\(text)")
        XCTAssertTrue(text.contains("z.wav"), "新增条目必须在：\(text)")

        let reloaded = try fixture.library.playlist(id: playlist.id)
        XCTAssertEqual(reloaded?.entries.count, 2)
    }

    // MARK: - 分组

    /// 专辑 / 艺人分组只归组本地文件。
    func testAlbumsAndArtistsGroupLocalTracks() throws {
        let fixture = try makeFixture("library-groups")
        try makeAudio(fixture, "a1.wav", neteaseId: 1, title: "曲一", artist: "艺人甲")
        try makeAudio(fixture, "a2.wav", neteaseId: 2, title: "曲二", artist: "艺人甲")
        try makeAudio(fixture, "b1.wav", neteaseId: 3, title: "曲三", artist: "艺人乙")

        XCTAssertEqual(fixture.library.songs().count, 3)
        // 专辑按「专辑 + 专辑艺人」归组：两位艺人 → 两个分组。
        XCTAssertEqual(fixture.library.albums().count, 2)
        XCTAssertEqual(fixture.library.artists().count, 2)
        XCTAssertEqual(fixture.library.artists().first { $0.name == "艺人甲" }?.tracks.count, 2)
        XCTAssertEqual(fixture.library.artists().first { $0.name == "艺人乙" }?.tracks.count, 1)
    }
}
