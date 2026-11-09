import Foundation
import XCTest

@testable import AlgerKit

/// 本地索引测试：真实文件夹具、事务语义、外部修改检测、重启恢复。
final class LibraryIndexTests: XCTestCase {

    private func makeIndex(_ workspace: TempWorkspace, name: String = "library/index.json") -> LibraryIndex {
        LibraryIndex(fileURL: workspace.url(name))
    }

    func testMissingFileLoadsEmptyAndSaveCreatesParentDirectory() throws {
        let workspace = try TempWorkspace("index-missing")
        let index = makeIndex(workspace)
        XCTAssertEqual(index.loadState, .missing)
        XCTAssertTrue(index.tracks.isEmpty)
        XCTAssertNil(index.loadIssue)

        try index.upsert(TrackRecord(path: "/music/a.mp3", title: "A"))

        let file = workspace.url("library/index.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "父目录应被创建")
        let decoded = try JSONDecoder().decode([TrackRecord].self, from: Data(contentsOf: file))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.title, "A")
    }

    func testCorruptFileIsPreservedAndWritesRefused() throws {
        let workspace = try TempWorkspace("index-corrupt")
        let file = try workspace.write("{ this is not json", to: "library/index.json")
        let original = try Data(contentsOf: file)

        let index = makeIndex(workspace)
        guard case .corrupt = index.loadState else {
            return XCTFail("期望损坏状态，实际 \(index.loadState)")
        }
        XCTAssertNotNil(index.loadIssue)

        // 拒绝写入：内存不发布，磁盘原样保留。
        XCTAssertThrowsError(try index.upsert(TrackRecord(path: "/music/a.mp3")))
        XCTAssertTrue(index.tracks.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), original, "损坏原文件必须保持原样")

        // 外部修好之后 reload() 才能继续写入。
        try JSONEncoder.algerPretty.encode([TrackRecord(path: "/music/a.mp3")]).write(to: file)
        XCTAssertEqual(index.reload(), .loaded)
        XCTAssertNoThrow(try index.upsert(TrackRecord(path: "/music/b.mp3")))
        XCTAssertEqual(index.tracks.count, 2)
    }

    func testUnreadableFileIsDistinguishedFromMissing() throws {
        let workspace = try TempWorkspace("index-unreadable")
        let file = try workspace.write("[]", to: "library/index.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }

        let index = makeIndex(workspace)
        guard case .unreadable = index.loadState else {
            return XCTFail("期望读失败状态，实际 \(index.loadState)")
        }
        XCTAssertNotNil(index.loadIssue)
        XCTAssertThrowsError(try index.upsert(TrackRecord(path: "/music/a.mp3")))
        XCTAssertTrue(index.tracks.isEmpty)
    }

    func testWriteFailureDoesNotPublishMemoryAndKeepsFileIntact() throws {
        let workspace = try TempWorkspace("index-write-fail")
        let file = try workspace.write("[]", to: "library/index.json")
        let index = makeIndex(workspace)
        XCTAssertEqual(index.loadState, .loaded)

        // 让目录不可写 → 临时文件无法创建 → 落盘失败
        let directory = file.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }

        XCTAssertThrowsError(try index.upsert(TrackRecord(path: "/music/a.mp3", title: "A")))
        XCTAssertTrue(index.tracks.isEmpty, "落盘失败时不得先发布内存")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "[]", "原文件必须保持不变")
    }

    func testExternalModificationIsDetectedEvenWithSameSizeAndMTime() throws {
        let workspace = try TempWorkspace("index-external")
        let file = try workspace.write("[]", to: "library/index.json")
        let index = makeIndex(workspace)
        try index.upsert(TrackRecord(path: "/music/a.mp3", title: "AAAA"))

        // 外部改写：内容不同但长度相同，并把 mtime 改回原值。
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let originalDate = originalAttributes[.modificationDate] as? Date
        let external = try JSONDecoder().decode([TrackRecord].self, from: Data(contentsOf: file))
        var tampered = external
        tampered[0].title = "BBBB"
        let tamperedData = try JSONEncoder.algerPretty.encode(tampered)
        XCTAssertEqual(tamperedData.count, try Data(contentsOf: file).count, "外部改写必须保持同样长度")
        try tamperedData.write(to: file)
        if let originalDate {
            try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: file.path)
        }

        XCTAssertThrowsError(try index.upsert(TrackRecord(path: "/music/b.mp3"))) { error in
            guard case LibraryIndex.IndexError.conflict = error else {
                return XCTFail("期望冲突错误，实际 \(error)")
            }
        }
        XCTAssertEqual(index.tracks.count, 1, "冲突时内存不变")
        let onDisk = try JSONDecoder().decode([TrackRecord].self, from: Data(contentsOf: file))
        XCTAssertEqual(onDisk.first?.title, "BBBB", "外部改动不得被覆盖")
    }

    func testExternalDeletionIsDetected() throws {
        let workspace = try TempWorkspace("index-deleted")
        let file = try workspace.write("[]", to: "library/index.json")
        let index = makeIndex(workspace)
        try FileManager.default.removeItem(at: file)

        XCTAssertThrowsError(try index.upsert(TrackRecord(path: "/music/a.mp3"))) { error in
            guard case LibraryIndex.IndexError.conflict = error else {
                return XCTFail("期望冲突错误，实际 \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "不得擅自重建被外部删除的文件")
    }

    func testConcurrentMutationsAreSerializedWithoutLosingUpdates() async throws {
        let workspace = try TempWorkspace("index-concurrent")
        let index = makeIndex(workspace)
        let count = 40

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index_ in 0..<count {
                group.addTask {
                    try index.upsert(TrackRecord(path: "/music/track-\(index_).mp3", title: "T\(index_)"))
                }
            }
            try await group.waitForAll()
        }

        XCTAssertEqual(index.tracks.count, count, "并发修改不得丢更新")
        let onDisk = try JSONDecoder().decode([TrackRecord].self, from: Data(contentsOf: workspace.url("library/index.json")))
        XCTAssertEqual(onDisk.count, count)
        XCTAssertEqual(Set(onDisk.map(\.path)).count, count)
    }

    func testRestartRecoversRecords() throws {
        let workspace = try TempWorkspace("index-restart")
        let index = makeIndex(workspace)
        try index.upsert(TrackRecord(path: "/music/a.mp3", neteaseId: 12345, title: "曲 A"))
        try index.upsert(TrackRecord(path: "/music/b.mp3", title: "曲 B"))

        // 重启：新建实例从磁盘恢复。
        let reopened = makeIndex(workspace)
        XCTAssertEqual(reopened.loadState, .loaded)
        XCTAssertEqual(reopened.tracks.count, 2)
        XCTAssertEqual(reopened.track(neteaseId: 12345)?.title, "曲 A")
        XCTAssertEqual(reopened.track(path: "/music/b.mp3")?.title, "曲 B")
    }

    func testRemovingRecordKeepsAudioFile() throws {
        let workspace = try TempWorkspace("index-remove")
        let audio = try workspace.write("fake audio bytes", to: "music/a.mp3")
        let index = makeIndex(workspace)
        try index.upsert(TrackRecord(path: audio.path, title: "曲 A"))

        XCTAssertTrue(try index.remove(path: audio.path))
        XCTAssertTrue(index.tracks.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path), "移出索引不得删除音频")
    }

    func testSymlinkedIndexIsNotReplaced() throws {
        let workspace = try TempWorkspace("index-symlink")
        let target = try workspace.write("[]", to: "real/index.json")
        let link = workspace.url("library/index.json")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let index = makeIndex(workspace)
        XCTAssertThrowsError(try index.upsert(TrackRecord(path: "/music/a.mp3"))) { error in
            guard case LibraryIndex.IndexError.refused = error else {
                return XCTFail("期望拒绝写入，实际 \(error)")
            }
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink, "符号链接不得被替换")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "[]", "链接目标不得被改写")
    }

    // MARK: - 基线必须来自「本实例读入 / 提交的字节」（E1 必修 1）

    /// 提交之后外部立刻改写 → 基线 **不得** 被吸收成外部内容，
    /// 下一次公开保存必须报冲突，外部字节必须原样保留。
    func testExternalWriteRightAfterCommitIsNotAbsorbedIntoBaseline() throws {
        let workspace = try TempWorkspace("index-commit-race")
        let file = try workspace.write("[]", to: "library/index.json")
        let index = makeIndex(workspace)

        // 外部进程在我们 rename 之后、重取基线之前写入的内容。
        let external = Data("[]".utf8)
        index.afterCommitHook = {
            try? external.write(to: file)
        }

        try index.upsert(TrackRecord(path: "/music/a.mp3", title: "A"))

        // 基线描述的是「本次提交的字节」，不是外部改写后的字节。
        let baseline = index.currentBaseline
        XCTAssertNotEqual(baseline, FileFingerprint.capture(file), "基线不得是提交后重新采集的路径指纹")

        // 下一次保存必须报冲突（不得静默覆盖外部改动）。
        XCTAssertThrowsError(try index.upsert(TrackRecord(path: "/music/b.mp3"))) { error in
            guard case LibraryIndex.IndexError.conflict = error else {
                return XCTFail("期望冲突错误，实际 \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: file), external, "外部改写不得被覆盖")
        XCTAssertEqual(index.tracks.count, 1, "冲突时内存不变")
    }

    /// 提交成功后基线必须与「落盘内容」一致（摘要相同）。
    func testBaselineDescribesCommittedBytes() throws {
        let workspace = try TempWorkspace("index-baseline")
        let file = workspace.url("library/index.json")
        let index = makeIndex(workspace)
        try index.upsert(TrackRecord(path: "/music/a.mp3", title: "A"))

        let baseline = index.currentBaseline
        let onDisk = try Data(contentsOf: file)
        guard case .present(let size, let sha, _, _, _, _) = baseline else {
            return XCTFail("基线应当是 present，实际 \(baseline)")
        }
        XCTAssertEqual(size, onDisk.count)
        XCTAssertEqual(sha, FileFingerprint.digest(of: onDisk), "基线摘要必须是本次提交字节的摘要")
        XCTAssertEqual(baseline, FileFingerprint.capture(file), "此刻路径内容就是提交内容")
    }

    /// 载入时的基线必须描述「实际读到的那份字节」（内容与指纹同一快照）。
    func testLoadedBaselineDescribesBytesActuallyRead() throws {
        let workspace = try TempWorkspace("index-load-baseline")
        let file = try workspace.write("[]", to: "library/index.json")
        let index = makeIndex(workspace)

        let baseline = index.currentBaseline
        let onDisk = try Data(contentsOf: file)
        guard case .present(_, let sha, _, _, _, _) = baseline else {
            return XCTFail("基线应当是 present，实际 \(baseline)")
        }
        XCTAssertEqual(sha, FileFingerprint.digest(of: onDisk))

        // 外部改写 → reload 之后基线才跟着更新。
        let tampered = try JSONEncoder.algerPretty.encode([TrackRecord(path: "/music/x.mp3")])
        try tampered.write(to: file)
        XCTAssertEqual(index.reload(), .loaded)
        let reloaded = index.currentBaseline
        guard case .present(_, let reloadedSHA, _, _, _, _) = reloaded else {
            return XCTFail("基线应当是 present，实际 \(reloaded)")
        }
        XCTAssertEqual(reloadedSHA, FileFingerprint.digest(of: try Data(contentsOf: file)))
        XCTAssertNotEqual(reloadedSHA, sha)
    }

    /// 读取器：内容与指纹必须来自同一次打开（同一快照）。
    func testFileReaderReturnsContentAndFingerprintFromSameSnapshot() throws {
        let workspace = try TempWorkspace("index-snapshot")
        let file = try workspace.write("hello 世界", to: "a.txt")
        let snapshot = FileReader.snapshot(file)
        XCTAssertEqual(snapshot.contents, Data("hello 世界".utf8))
        guard case .present(let size, let sha, _, _, _, _) = snapshot.fingerprint else {
            return XCTFail("指纹应当是 present，实际 \(snapshot.fingerprint)")
        }
        XCTAssertEqual(size, snapshot.contents?.count)
        XCTAssertEqual(sha, FileFingerprint.digest(of: snapshot.contents ?? Data()))
    }

    /// 非普通文件（FIFO）必须被 **快速拒绝**，不得阻塞在 open 上。
    func testFifoIndexIsRejectedWithoutBlocking() throws {
        let workspace = try TempWorkspace("index-fifo")
        let file = workspace.url("library/index.json")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertEqual(mkfifo(file.path, 0o600), 0, "创建 FIFO 夹具失败")

        let started = Date()
        let index = makeIndex(workspace)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "打开 FIFO 不得阻塞")
        guard case .unreadable = index.loadState else {
            return XCTFail("期望读失败状态，实际 \(index.loadState)")
        }
        XCTAssertThrowsError(try index.upsert(TrackRecord(path: "/music/a.mp3"))) { error in
            guard case LibraryIndex.IndexError.refused = error else {
                return XCTFail("期望拒绝写入，实际 \(error)")
            }
        }
        var info = stat()
        XCTAssertEqual(lstat(file.path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFIFO, "FIFO 不得被替换")
    }

    // MARK: - 跨进程协作锁（E1 必修 3）

    /// 另一个进程持锁时，本进程写入必须 **有界失败**，且不得改动文件。
    func testCrossProcessLockContentionFailsBoundedAndPreservesFile() throws {
        let workspace = try TempWorkspace("index-lock-contention")
        let file = try workspace.write("[]", to: "library/index.json")
        let index = LibraryIndex(fileURL: file, lockTimeout: 0.5)
        XCTAssertEqual(index.loadState, .loaded)

        let lockURL = CooperativeFileLock.lockURL(for: file)
        let holder = try LockHolderProcess.start(lockPath: lockURL.path)
        defer {
            holder.release()
            _ = holder.waitForExit()
        }

        let started = Date()
        XCTAssertThrowsError(try index.upsert(TrackRecord(path: "/music/a.mp3"))) { error in
            guard case LibraryIndex.IndexError.locked = error else {
                return XCTFail("期望锁冲突错误，实际 \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "锁等待必须有界")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "[]", "被锁挡住时不得改动文件")

        // 对方放锁之后，同一个实例必须能继续写。
        holder.release()
        XCTAssertNoThrow(try index.upsert(TrackRecord(path: "/music/a.mp3")))
        XCTAssertEqual(index.tracks.count, 1)
    }

    /// 协作写者（另一个进程）提交之后，本进程必须报冲突而不是覆盖它。
    func testCompetingWriterCommitIsDetectedAsConflict() throws {
        let workspace = try TempWorkspace("index-lock-competing")
        let file = try workspace.write("[]", to: "library/index.json")
        let index = makeIndex(workspace)

        // 另一个进程准备提交的内容。
        let replacement = try workspace.write(
            try JSONEncoder.algerPretty.encode([TrackRecord(path: "/music/other.mp3")]),
            to: "other.json"
        )
        let lockURL = CooperativeFileLock.lockURL(for: file)
        let writer = try LockHolderProcess.startCompetingWriter(
            lockPath: lockURL.path,
            sourcePath: replacement.path,
            targetPath: file.path
        )
        defer { _ = writer.waitForExit() }
        XCTAssertNotNil(writer.waitForExit(timeout: 5), "协作写者应当完成")

        // 本进程的基线已经过时 → 必须报冲突，外部提交的内容不得被覆盖。
        XCTAssertThrowsError(try index.upsert(TrackRecord(path: "/music/a.mp3"))) { error in
            guard case LibraryIndex.IndexError.conflict = error else {
                return XCTFail("期望冲突错误，实际 \(error)")
            }
        }
        let onDisk = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("other.mp3"), "外部提交的内容不得被覆盖：\(onDisk)")
    }

    /// 锁文件是符号链接时必须拒绝（不得跟随软链去锁别的文件）。
    func testSymlinkedLockFileIsRefused() throws {
        let workspace = try TempWorkspace("index-lock-symlink")
        let file = try workspace.write("[]", to: "library/index.json")
        let index = makeIndex(workspace)

        let lockURL = CooperativeFileLock.lockURL(for: file)
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let other = try workspace.write("not a lock", to: "other.lock")
        try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: other)

        XCTAssertThrowsError(try index.upsert(TrackRecord(path: "/music/a.mp3"))) { error in
            guard case LibraryIndex.IndexError.refused = error else {
                return XCTFail("期望拒绝写入，实际 \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "not a lock", "软链目标不得被改写")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "[]", "原文件不得被改动")
    }

    /// 锁文件已有内容时不得被截断。
    func testLockFileContentIsNotTruncated() throws {
        let workspace = try TempWorkspace("index-lock-content")
        let file = try workspace.write("[]", to: "library/index.json")
        let index = makeIndex(workspace)

        let lockURL = CooperativeFileLock.lockURL(for: file)
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("既有内容".utf8).write(to: lockURL)

        try index.upsert(TrackRecord(path: "/music/a.mp3"))
        XCTAssertEqual(try String(contentsOf: lockURL, encoding: .utf8), "既有内容", "锁文件不得被截断")
    }
}
