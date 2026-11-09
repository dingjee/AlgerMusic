import Foundation
import XCTest

@testable import AlgerKit

#if canImport(Darwin)
import Darwin
#endif

/// 应用状态（`native.json`）的回归。
final class NativeStoreTests: XCTestCase {

    func testMissingFileLoadsEmptyAndSaveCreatesParentDirectory() throws {
        let workspace = try TempWorkspace("store-missing")
        let file = workspace.url("data/native.json")
        let store = NativeStore(fileURL: file)
        XCTAssertEqual(store.loadState, .missing)
        XCTAssertTrue(store.current.playlists.isEmpty)

        try store.mutate { $0.settings.autoSaveThreshold = 5 }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let decoded = try JSONDecoder().decode(NativeState.self, from: Data(contentsOf: file))
        XCTAssertEqual(decoded.settings.autoSaveThreshold, 5)
    }

    func testCorruptFileIsPreservedAndWritesRefused() throws {
        let workspace = try TempWorkspace("store-corrupt")
        let file = try workspace.write("{ not json", to: "native.json")
        let original = try Data(contentsOf: file)

        let store = NativeStore(fileURL: file)
        guard case .corrupt = store.loadState else {
            return XCTFail("期望损坏状态，实际 \(store.loadState)")
        }
        XCTAssertNotNil(store.loadIssue)
        XCTAssertThrowsError(try store.mutate { $0.settings.autoSaveEnabled = false })
        XCTAssertEqual(try Data(contentsOf: file), original, "损坏原文件必须保持原样")
    }

    func testExternalModificationIsDetectedAsConflict() throws {
        let workspace = try TempWorkspace("store-conflict")
        let file = try workspace.write("{}", to: "native.json")
        let store = NativeStore(fileURL: file)
        try store.mutate { $0.version = 1 }

        // 外部改写。
        var external = try JSONDecoder().decode(NativeState.self, from: Data(contentsOf: file))
        external.settings.autoSaveThreshold = 9
        try JSONEncoder.algerPretty.encode(external).write(to: file)

        XCTAssertThrowsError(try store.mutate { $0.version = 2 }) { error in
            guard case NativeStore.StoreError.conflict = error else {
                return XCTFail("期望冲突错误，实际 \(error)")
            }
        }
        let onDisk = try JSONDecoder().decode(NativeState.self, from: Data(contentsOf: file))
        XCTAssertEqual(onDisk.settings.autoSaveThreshold, 9, "外部改动不得被覆盖")
    }

    func testConcurrentMutationsAreSerializedWithoutLosingUpdates() async throws {
        let workspace = try TempWorkspace("store-concurrent")
        let store = NativeStore(fileURL: workspace.url("native.json"))
        let count = 30

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<count {
                group.addTask {
                    try store.mutate { state in
                        state.playlists.append(LocalPlaylistRecord(
                            id: "pl-\(index)",
                            title: "歌单 \(index)",
                            fileName: "pl-\(index).m3u8",
                            createdAt: 0,
                            updatedAt: 0
                        ))
                    }
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(store.current.playlists.count, count)
        let onDisk = try JSONDecoder().decode(NativeState.self, from: Data(contentsOf: workspace.url("native.json")))
        XCTAssertEqual(onDisk.playlists.count, count)
    }

    func testPendingOperationsRoundTrip() throws {
        let workspace = try TempWorkspace("store-pending")
        let store = NativeStore(fileURL: workspace.url("native.json"))
        try store.mutate { state in
            state.pendingOperations.append(PendingOperation(
                kind: .deletePlaylist,
                playlistId: "pl-x",
                fileName: "pl-x.m3u8",
                details: "测试"
            ))
        }
        let reopened = NativeStore(fileURL: workspace.url("native.json"))
        XCTAssertEqual(reopened.current.pendingOperations.count, 1)
        XCTAssertEqual(reopened.current.pendingOperations.first?.kind, .deletePlaylist)
        XCTAssertEqual(reopened.current.pendingOperations.first?.playlistId, "pl-x")
    }

    func testMissingFieldsFallBackToDefaults() throws {
        let workspace = try TempWorkspace("store-tolerant")
        let file = try workspace.write(#"{"playlists":[{"id":"pl-1"}]}"#, to: "native.json")
        let store = NativeStore(fileURL: file)
        XCTAssertEqual(store.loadState, .loaded)
        XCTAssertEqual(store.current.playlists.count, 1)
        XCTAssertEqual(store.current.playlists.first?.title, "未命名歌单")
        XCTAssertEqual(store.current.settings.autoSaveThreshold, 3)
        XCTAssertTrue(store.current.settings.autoSaveEnabled)
    }
}
