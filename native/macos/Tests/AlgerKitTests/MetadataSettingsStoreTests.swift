import Foundation
import XCTest

@testable import AlgerKit

/// 元信息设置存储回归（E5）。
///
/// 覆盖：独立文件、**0600 权限**、损坏拒写、外部改动冲突、跨进程锁。
final class MetadataSettingsStoreTests: XCTestCase {

    private func makeStore(_ workspace: TempWorkspace, lockTimeout: TimeInterval = 5) throws -> MetadataSettingsStore {
        try MetadataSettingsStore(
            fileURL: workspace.url("metadata-settings.json"),
            lockTimeout: lockTimeout
        )
    }

    func testSaveCreatesFileWith0600AndRoundTrips() async throws {
        let workspace = try TempWorkspace("metadata-settings")
        let store = try makeStore(workspace)
        XCTAssertEqual(store.loadState, .missing)

        try store.save(MetadataSettings(
            acoustIDApiKey: "key-1",
            fpcalcPath: "/opt/homebrew/bin/fpcalc"
        ))
        XCTAssertEqual(store.loadState, .loaded)      // 提交后文件已存在
        XCTAssertEqual(store.settings.acoustIDApiKey, "key-1")
        XCTAssertEqual(store.settings.fpcalcPath, "/opt/homebrew/bin/fpcalc")

        // 独立文件（**不改 `native.json`**）。
        let url = workspace.url("metadata-settings.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.url("native.json").path))

        // 权限必须是 0600。
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        XCTAssertEqual(permissions, 0o600, "设置文件（含用户填的 key）必须只有本人可读写")

        // 重新载入。
        let reopened = try makeStore(workspace)
        XCTAssertEqual(reopened.loadState, .loaded)
        XCTAssertEqual(reopened.settings.acoustIDApiKey, "key-1")
        XCTAssertEqual(reopened.settings.fpcalcPath, "/opt/homebrew/bin/fpcalc")
    }

    func testEmptySettingsAreWrittenAndDecodedLeniently() async throws {
        let workspace = try TempWorkspace("metadata-settings-empty")
        let store = try makeStore(workspace)
        try store.save(MetadataSettings())
        XCTAssertEqual(store.settings.acoustIDApiKey, "")

        // 缺字段的旧文件 → 用默认值，不报废。
        try workspace.write("{\"acoustIDApiKey\":\"only-key\"}", to: "metadata-settings.json")
        let reopened = try makeStore(workspace)
        XCTAssertEqual(reopened.loadState, .loaded)
        XCTAssertEqual(reopened.settings.acoustIDApiKey, "only-key")
        XCTAssertEqual(reopened.settings.fpcalcPath, "")
    }

    func testCorruptFileRefusesWriteAndKeepsOriginal() async throws {
        let workspace = try TempWorkspace("metadata-settings-corrupt")
        let url = workspace.url("metadata-settings.json")
        let garbage = "{ 这不是 JSON"
        try workspace.write(garbage, to: "metadata-settings.json")

        let store = try makeStore(workspace)
        guard case .corrupt = store.loadState else {
            return XCTFail("损坏文件必须标记为 corrupt，实际：\(store.loadState)")
        }
        XCTAssertFalse(store.loadState.isWritable)
        XCTAssertNotNil(store.loadIssue)

        do {
            try store.save(MetadataSettings(acoustIDApiKey: "new"))
            XCTFail("损坏文件必须拒绝写入")
        } catch let error as MetadataSettingsStore.StoreError {
            guard case .refused = error else {
                return XCTFail("应为 refused，实际：\(error)")
            }
        }
        // 原文件必须原样保留。
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text, garbage)
    }

    func testExternalModificationIsConflictAndNotOverwritten() async throws {
        let workspace = try TempWorkspace("metadata-settings-conflict")
        let store = try makeStore(workspace)
        try store.save(MetadataSettings(acoustIDApiKey: "mine"))

        // 别的程序改了同一个文件。
        let url = workspace.url("metadata-settings.json")
        let external = "{\"acoustIDApiKey\":\"theirs\",\"fpcalcPath\":\"\"}"
        try workspace.write(external, to: "metadata-settings.json")

        do {
            try store.save(MetadataSettings(acoustIDApiKey: "mine-again"))
            XCTFail("外部改动必须报冲突")
        } catch let error as MetadataSettingsStore.StoreError {
            guard case .conflict = error else {
                return XCTFail("应为 conflict，实际：\(error)")
            }
        }
        // 外部内容必须保留（不能被覆盖）。
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("theirs"))
        XCTAssertFalse(text.contains("mine-again"))
    }

    func testConcurrentWriterLockIsRespected() async throws {
        let workspace = try TempWorkspace("metadata-settings-locked")
        let store = try makeStore(workspace, lockTimeout: 0.5)
        let lockURL = CooperativeFileLock.lockURL(for: workspace.url("metadata-settings.json"))

        let holder = try LockHolderProcess.start(lockPath: lockURL.path)
        defer {
            holder.release()
            _ = holder.waitForExit(timeout: 2)
        }

        do {
            try store.save(MetadataSettings(acoustIDApiKey: "blocked"))
            XCTFail("别的进程持锁时必须失败（不能等不到锁就硬写）")
        } catch let error as MetadataSettingsStore.StoreError {
            guard case .locked = error else {
                return XCTFail("应为 locked，实际：\(error)")
            }
        }
    }

    func testDefaultFileURLIsIndependentOfNativeState() {
        let root = URL(fileURLWithPath: "/tmp/alger-data", isDirectory: true)
        let url = MetadataSettingsStore.defaultFileURL(dataRoot: root)
        XCTAssertEqual(url.lastPathComponent, "metadata-settings.json")
        XCTAssertEqual(url.deletingLastPathComponent().path, root.path)
    }
}
