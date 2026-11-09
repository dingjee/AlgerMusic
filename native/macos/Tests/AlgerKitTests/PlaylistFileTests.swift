import Foundation
import XCTest

@testable import AlgerKit

/// M3U8 歌单测试：真实文件夹具、增删改排序、冲突检测、失败回滚、重启恢复。
final class PlaylistFileTests: XCTestCase {

    func testLoadsUTF8WithBOMCRLFChineseAndSpaces() throws {
        let workspace = try TempWorkspace("playlist-parse")
        let playlistDir = try workspace.makeDirectory("Playlists")
        let audio = try workspace.write("audio", to: "Music/歌 手/我的 歌.mp3")
        let relative = "../Music/歌 手/我的 歌.mp3"

        let text = "#EXTM3U\r\n#EXTINF:213,我的 歌\r\n\(relative)\r\n"
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(text.utf8))
        let file = playlistDir.appendingPathComponent("中文 歌单.m3u8")
        try data.write(to: file)

        let playlist = PlaylistFile(fileURL: file)
        try playlist.load()

        XCTAssertEqual(playlist.entries.count, 1)
        let entry = try XCTUnwrap(playlist.entries.first)
        XCTAssertEqual(entry.path, audio.deletingLastPathComponent().appendingPathComponent("我的 歌.mp3").path)
        XCTAssertEqual(entry.duration, 213)
        XCTAssertEqual(entry.displayName, "我的 歌")
    }

    func testAddRemoveReorderAndKeepsAudioFile() throws {
        let workspace = try TempWorkspace("playlist-edit")
        let playlistDir = try workspace.makeDirectory("Playlists")
        let audioA = try workspace.write("a", to: "Music/a.mp3")
        let audioB = try workspace.write("b", to: "Music/b.mp3")
        let audioC = try workspace.write("c", to: "Music/c.mp3")

        let file = playlistDir.appendingPathComponent("list.m3u8")
        let playlist = PlaylistFile(fileURL: file)
        try playlist.load()
        try playlist.add(PlaylistEntry(path: audioA.path, duration: 10, displayName: "甲"))
        try playlist.add(PlaylistEntry(path: audioB.path, duration: 20, displayName: "乙"))
        try playlist.add(PlaylistEntry(path: audioC.path, duration: 30, displayName: "丙"))
        try playlist.save()

        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("#EXTM3U\n"))
        XCTAssertTrue(text.contains("#EXTINF:10,甲"))
        XCTAssertTrue(text.contains("../Music/a.mp3"), text)

        // 重排：把最后一个移到最前。
        try playlist.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        try playlist.save()
        var lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "#EXTM3U")
        XCTAssertEqual(lines[2], "../Music/c.mp3")

        // 移除只去掉引用，**不删音频**。
        XCTAssertTrue(try playlist.remove(path: audioB.path))
        try playlist.save()
        lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
        XCTAssertFalse(lines.contains("../Music/b.mp3"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioB.path), "移除不得删除音频文件")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioC.path))
    }

    func testCrossDirectoryRelativePathUsesParentSegments() throws {
        let workspace = try TempWorkspace("playlist-relative")
        let playlistDir = try workspace.makeDirectory("Music/AlgerMusic/Playlists")
        let audio = try workspace.write("x", to: "Music/其它 目录/歌曲 A.mp3")

        let file = playlistDir.appendingPathComponent("rel.m3u8")
        let playlist = PlaylistFile(fileURL: file)
        try playlist.load()
        try playlist.add(PlaylistEntry(path: audio.path))
        try playlist.save()

        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("../../其它 目录/歌曲 A.mp3"), text)
    }

    func testRejectsNewlineInPathAndNonFiniteDuration() throws {
        let workspace = try TempWorkspace("playlist-invalid")
        let playlistDir = try workspace.makeDirectory("Playlists")
        let playlist = PlaylistFile(fileURL: playlistDir.appendingPathComponent("x.m3u8"))

        XCTAssertThrowsError(try playlist.add(PlaylistEntry(path: "/music/a\nb.mp3"))) { error in
            guard case PlaylistFile.PlaylistError.invalidEntry = error else {
                return XCTFail("期望非法条目错误，实际 \(error)")
            }
        }
        XCTAssertThrowsError(try playlist.add(PlaylistEntry(path: "/music/a.mp3", displayName: "名\n称"))) { error in
            guard case PlaylistFile.PlaylistError.invalidEntry = error else {
                return XCTFail("期望非法条目错误，实际 \(error)")
            }
        }
        XCTAssertThrowsError(try playlist.add(PlaylistEntry(path: "/music/a.mp3", duration: .nan))) { error in
            guard case PlaylistFile.PlaylistError.invalidEntry = error else {
                return XCTFail("期望非法条目错误，实际 \(error)")
            }
        }
        XCTAssertThrowsError(try playlist.add(PlaylistEntry(path: "/music/a.mp3", duration: .infinity)))
        XCTAssertEqual(playlist.entries.count, 0)
    }

    func testExternalCreationDeletionAndModificationAllConflict() throws {
        let workspace = try TempWorkspace("playlist-conflict")

        // 1) 外部创建：本来不存在的歌单被别的程序创建。
        let createdDir = try workspace.makeDirectory("created")
        let createdFile = createdDir.appendingPathComponent("list.m3u8")
        let created = PlaylistFile(fileURL: createdFile)
        try created.load()
        try created.add(PlaylistEntry(path: "/music/a.mp3"))
        try created.save()
        // 用一个「从未见过该文件」的实例去写 → 冲突
        let stale = PlaylistFile(fileURL: createdFile)
        XCTAssertThrowsError(try stale.save()) { error in
            guard case PlaylistFile.PlaylistError.conflict = error else {
                return XCTFail("期望冲突错误，实际 \(error)")
            }
        }

        // 2) 外部删除。
        let deletedDir = try workspace.makeDirectory("deleted")
        let deletedFile = deletedDir.appendingPathComponent("list.m3u8")
        try "#EXTM3U\n/music/a.mp3\n".write(to: deletedFile, atomically: true, encoding: .utf8)
        let deleted = PlaylistFile(fileURL: deletedFile)
        try deleted.load()
        try FileManager.default.removeItem(at: deletedFile)
        XCTAssertThrowsError(try deleted.save()) { error in
            guard case PlaylistFile.PlaylistError.conflict = error else {
                return XCTFail("期望冲突错误，实际 \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: deletedFile.path))

        // 3) 外部改写（同长度、同 mtime）。
        let modifiedDir = try workspace.makeDirectory("modified")
        let modifiedFile = modifiedDir.appendingPathComponent("list.m3u8")
        try "#EXTM3U\n/music/a.mp3\n".write(to: modifiedFile, atomically: true, encoding: .utf8)
        let modified = PlaylistFile(fileURL: modifiedFile)
        try modified.load()
        let originalDate = try FileManager.default.attributesOfItem(atPath: modifiedFile.path)[.modificationDate] as? Date
        try "#EXTM3U\n/music/b.mp3\n".write(to: modifiedFile, atomically: true, encoding: .utf8)
        if let originalDate {
            try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: modifiedFile.path)
        }
        XCTAssertThrowsError(try modified.save()) { error in
            guard case PlaylistFile.PlaylistError.conflict = error else {
                return XCTFail("期望冲突错误，实际 \(error)")
            }
        }
        XCTAssertTrue(try String(contentsOf: modifiedFile, encoding: .utf8).contains("/music/b.mp3"))
    }

    func testWriteFailureRollsBackAndKeepsOriginalFile() throws {
        let workspace = try TempWorkspace("playlist-write-fail")
        let playlistDir = try workspace.makeDirectory("Playlists")
        let file = playlistDir.appendingPathComponent("list.m3u8")
        let original = "#EXTM3U\n/music/a.mp3\n"
        try original.write(to: file, atomically: true, encoding: .utf8)

        let playlist = PlaylistFile(fileURL: file)
        try playlist.load()
        try playlist.add(PlaylistEntry(path: "/music/b.mp3"))

        // 目录不可写 → 同目录临时文件无法创建 → 写入失败
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: playlistDir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: playlistDir.path)
        }

        XCTAssertThrowsError(try playlist.save()) { error in
            guard case PlaylistFile.PlaylistError.writeFailed = error else {
                return XCTFail("期望写入失败，实际 \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original, "写入失败时原文件必须保持不变")
        XCTAssertEqual(playlist.entries.count, 2, "写入失败不改变内存条目")
    }

    func testTemporaryFileIsUniqueInSameDirectoryAndCleanedUp() throws {
        let workspace = try TempWorkspace("playlist-temp")
        let playlistDir = try workspace.makeDirectory("Playlists")
        let file = playlistDir.appendingPathComponent("list.m3u8")

        let playlist = PlaylistFile(fileURL: file)
        try playlist.load()
        try playlist.add(PlaylistEntry(path: "/music/a.mp3"))
        try playlist.save()

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: playlistDir.path)
            .filter { $0.hasPrefix(".alger-tmp") }
        XCTAssertTrue(leftovers.isEmpty, "临时文件必须被清理：\(leftovers)")

        // 同目录唯一名：连续两次保存不会互相覆盖（内容始终是最新一份）。
        try playlist.add(PlaylistEntry(path: "/music/b.mp3"))
        try playlist.save()
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("/music/a.mp3"))
        XCTAssertTrue(text.contains("/music/b.mp3"))
    }

    func testRestartRecoversPlaylistFromDisk() throws {
        let workspace = try TempWorkspace("playlist-restart")
        let playlistDir = try workspace.makeDirectory("Playlists")
        let audio = try workspace.write("x", to: "Music/歌.mp3")
        let file = playlistDir.appendingPathComponent("list.m3u8")

        let playlist = PlaylistFile(fileURL: file)
        try playlist.load()
        try playlist.add(PlaylistEntry(path: audio.path, duration: 42, displayName: "歌"))
        try playlist.save()

        // 重启：重新载入后条目、元信息、顺序都还在。
        let reopened = PlaylistFile(fileURL: file)
        try reopened.load()
        XCTAssertEqual(reopened.entries.count, 1)
        XCTAssertEqual(reopened.entries[0].path, audio.path)
        XCTAssertEqual(reopened.entries[0].duration, 42)
        XCTAssertEqual(reopened.entries[0].displayName, "歌")
    }

    func testSymlinkedPlaylistIsNotReplaced() throws {
        let workspace = try TempWorkspace("playlist-symlink")
        let target = try workspace.write("#EXTM3U\n", to: "real/list.m3u8")
        let link = workspace.url("Playlists/list.m3u8")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let playlist = PlaylistFile(fileURL: link)
        try playlist.load()
        try playlist.add(PlaylistEntry(path: "/music/a.mp3"))
        XCTAssertThrowsError(try playlist.save()) { error in
            guard case PlaylistFile.PlaylistError.refused = error else {
                return XCTFail("期望拒绝写入，实际 \(error)")
            }
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "#EXTM3U\n")
    }

    func testInvalidUTF8IsRejectedWithoutTouchingFile() throws {
        let workspace = try TempWorkspace("playlist-bad-utf8")
        let playlistDir = try workspace.makeDirectory("Playlists")
        let file = playlistDir.appendingPathComponent("list.m3u8")
        let bytes = Data([0xFF, 0xFE, 0x41, 0x0A])
        try bytes.write(to: file)

        let playlist = PlaylistFile(fileURL: file)
        XCTAssertThrowsError(try playlist.load()) { error in
            guard case PlaylistFile.PlaylistError.parseFailed = error else {
                return XCTFail("期望解析失败，实际 \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: file), bytes, "解析失败时原文件必须保持不变")
    }

    func testMetadataIsStoredAsCompatibleComments() throws {
        let workspace = try TempWorkspace("playlist-meta")
        let playlistDir = try workspace.makeDirectory("Playlists")
        let file = playlistDir.appendingPathComponent("list.m3u8")

        let playlist = PlaylistFile(fileURL: file)
        try playlist.load()
        try playlist.add(PlaylistEntry(path: "/music/a.mp3", duration: 61.5, displayName: "标题, 带逗号"))
        try playlist.save()

        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("#EXTINF:61.5,标题, 带逗号"), text)
        XCTAssertTrue(text.hasPrefix("#EXTM3U\n"))
    }

    // MARK: - 基线必须来自「本实例读入 / 提交的字节」（E1 必修 1）

    /// 提交之后外部立刻改写 → 基线 **不得** 被吸收成外部内容，
    /// 下一次公开保存必须报冲突，外部字节必须原样保留。
    func testExternalWriteRightAfterCommitIsNotAbsorbedIntoBaseline() throws {
        let workspace = try TempWorkspace("playlist-commit-race")
        let playlistDir = try workspace.makeDirectory("Playlists")
        let file = playlistDir.appendingPathComponent("list.m3u8")

        let playlist = PlaylistFile(fileURL: file)
        try playlist.load()

        // 外部进程在我们 rename 之后、重取基线之前写入的内容。
        let external = "#EXTM3U\n/music/external.mp3\n"
        playlist.afterCommitHook = {
            try? external.write(to: file, atomically: true, encoding: .utf8)
        }

        try playlist.add(PlaylistEntry(path: "/music/a.mp3"))
        try playlist.save()

        let baseline = playlist.currentBaseline
        XCTAssertNotEqual(baseline, FileFingerprint.capture(file), "基线不得是提交后重新采集的路径指纹")

        XCTAssertThrowsError(try playlist.save()) { error in
            guard case PlaylistFile.PlaylistError.conflict = error else {
                return XCTFail("期望冲突错误，实际 \(error)")
            }
        }
        XCTAssertTrue(
            try String(contentsOf: file, encoding: .utf8).contains("/music/external.mp3"),
            "外部改写不得被覆盖"
        )
    }

    /// 载入时的基线必须描述「实际读到的那份字节」。
    func testLoadedBaselineDescribesBytesActuallyRead() throws {
        let workspace = try TempWorkspace("playlist-load-baseline")
        let playlistDir = try workspace.makeDirectory("Playlists")
        let file = playlistDir.appendingPathComponent("list.m3u8")
        try "#EXTM3U\n/music/a.mp3\n".write(to: file, atomically: true, encoding: .utf8)

        let playlist = PlaylistFile(fileURL: file)
        try playlist.load()
        let baseline = playlist.currentBaseline
        guard case .present(_, let sha, _, _, _, _) = baseline else {
            return XCTFail("基线应当是 present，实际 \(baseline)")
        }
        XCTAssertEqual(sha, FileFingerprint.digest(of: try Data(contentsOf: file)))
    }

    /// 非普通文件（FIFO）必须被 **快速拒绝**，不得阻塞在 open 上。
    func testFifoPlaylistIsRejectedWithoutBlocking() throws {
        let workspace = try TempWorkspace("playlist-fifo")
        let playlistDir = try workspace.makeDirectory("Playlists")
        let file = playlistDir.appendingPathComponent("list.m3u8")
        XCTAssertEqual(mkfifo(file.path, 0o600), 0, "创建 FIFO 夹具失败")

        let playlist = PlaylistFile(fileURL: file)
        let started = Date()
        XCTAssertThrowsError(try playlist.load()) { error in
            guard case PlaylistFile.PlaylistError.parseFailed = error else {
                return XCTFail("期望解析失败，实际 \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "打开 FIFO 不得阻塞")
    }

    // MARK: - 跨进程协作锁（E1 必修 3）

    /// 另一个进程持锁时，本进程保存必须 **有界失败**，且不得改动文件。
    func testCrossProcessLockContentionFailsBoundedAndPreservesFile() throws {
        let workspace = try TempWorkspace("playlist-lock-contention")
        let playlistDir = try workspace.makeDirectory("Playlists")
        let file = playlistDir.appendingPathComponent("list.m3u8")
        try "#EXTM3U\n/music/a.mp3\n".write(to: file, atomically: true, encoding: .utf8)

        let playlist = PlaylistFile(fileURL: file, lockTimeout: 0.5)
        try playlist.load()

        let lockURL = CooperativeFileLock.lockURL(for: file)
        let holder = try LockHolderProcess.start(lockPath: lockURL.path)
        defer {
            holder.release()
            _ = holder.waitForExit()
        }

        let started = Date()
        XCTAssertThrowsError(try playlist.save()) { error in
            guard case PlaylistFile.PlaylistError.locked = error else {
                return XCTFail("期望锁冲突错误，实际 \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "锁等待必须有界")
        XCTAssertEqual(
            try String(contentsOf: file, encoding: .utf8),
            "#EXTM3U\n/music/a.mp3\n",
            "被锁挡住时不得改动文件"
        )

        holder.release()
        try playlist.add(PlaylistEntry(path: "/music/b.mp3"))
        XCTAssertNoThrow(try playlist.save())
    }

    /// 锁文件是符号链接时必须拒绝。
    func testSymlinkedLockFileIsRefused() throws {
        let workspace = try TempWorkspace("playlist-lock-symlink")
        let playlistDir = try workspace.makeDirectory("Playlists")
        let file = playlistDir.appendingPathComponent("list.m3u8")

        let playlist = PlaylistFile(fileURL: file)
        try playlist.load()

        let lockURL = CooperativeFileLock.lockURL(for: file)
        let other = try workspace.write("not a lock", to: "other.lock")
        try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: other)

        XCTAssertThrowsError(try playlist.save()) { error in
            guard case PlaylistFile.PlaylistError.refused = error else {
                return XCTFail("期望拒绝写入，实际 \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "not a lock", "软链目标不得被改写")
    }

    /// 锁文件已有内容时不得被截断。
    func testLockFileContentIsNotTruncated() throws {
        let workspace = try TempWorkspace("playlist-lock-content")
        let playlistDir = try workspace.makeDirectory("Playlists")
        let file = playlistDir.appendingPathComponent("list.m3u8")

        let playlist = PlaylistFile(fileURL: file)
        try playlist.load()
        try playlist.add(PlaylistEntry(path: "/music/a.mp3"))

        let lockURL = CooperativeFileLock.lockURL(for: file)
        try Data("既有内容".utf8).write(to: lockURL)
        try playlist.save()
        XCTAssertEqual(try String(contentsOf: lockURL, encoding: .utf8), "既有内容", "锁文件不得被截断")
    }
}
