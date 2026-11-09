import XCTest
@testable import AlgerKit

@MainActor
final class LibraryScannerTests: XCTestCase {
    func testRealScanPersistsSongsAlbumsArtistsAndSkipsUnchangedOnRescan() async throws {
        let workspace = try TempWorkspace("library-scan")
        let music = try workspace.makeDirectory("Music 中文")
        let file = try TestAudio.writeWAV(to: music.appendingPathComponent("一首歌.wav"), seconds: 0.2)
        let client = try BridgeClient(executableURL: TestPaths.bridgeBinary,
                                      arguments: ["--session-path", workspace.url("session.json").path])
        defer { client.shutdown() }
        _ = try await client.call("tags.write", params: ["path": file.path, "patch": [
            "title": "测试歌曲", "artist": "测试艺人", "album": "测试专辑", "removeArtwork": false
        ]])
        let index = LibraryIndex(fileURL: workspace.url("library/index.json"))
        let store = NativeStore(fileURL: workspace.url("native.json"))
        let library = LocalLibrary(index: index, store: store)
        let scanner = LibraryScanner(client: client, index: index)
        let summary = try await scanner.scan(directories: [music.path])
        XCTAssertEqual(summary.updated, 1)
        XCTAssertEqual(library.songs().map(\.path), [file.path])
        XCTAssertEqual(library.songs().first?.title, "测试歌曲")
        XCTAssertEqual(library.albums().map(\.name), ["测试专辑"])
        XCTAssertEqual(library.artists().map(\.name), ["测试艺人"])
        let reopened = LibraryIndex(fileURL: workspace.url("library/index.json"))
        XCTAssertEqual(reopened.tracks.count, 1, "扫描结束意味着索引已经落盘，不依赖稍后才执行的UI事件")
        let again = try await scanner.scan(directories: [music.path])
        XCTAssertEqual(again.updated, 0)
        XCTAssertEqual(again.skipped, 1)
        XCTAssertEqual(index.tracks.count, 1)
        // 宽容读取旧索引中的重复路径，扫描应归并而非Dictionary初始化崩溃。
        try index.mutate { tracks in tracks.append(tracks[0]) }
        _ = try await scanner.scan(directories: [music.path])
        XCTAssertEqual(index.tracks.count, 1)
    }

    func testParserAcceptsActualBridgePayloadAndLegacyEnvelope() {
        let raw: [String: Any] = ["path": "/fixture/a.wav", "title": "歌", "artist": "艺人", "album": "专辑"]
        XCTAssertEqual(ScannedTrack.parse(raw)?.artist, "艺人")
        XCTAssertEqual(ScannedTrack.parse(["entry": raw])?.album, "专辑")
        XCTAssertNil(ScannedTrack.parse([:]))
    }

    func testMissingRootReportsFailureInsteadOfEmptySuccess() async throws {
        let workspace = try TempWorkspace("library-scan-missing")
        let client = try BridgeClient(executableURL: TestPaths.bridgeBinary,
                                      arguments: ["--session-path", workspace.url("session.json").path])
        defer { client.shutdown() }
        let scanner = LibraryScanner(client: client, index: LibraryIndex(fileURL: workspace.url("index.json")))
        do {
            _ = try await scanner.scan(directories: [workspace.url("missing").path])
            XCTFail("缺失的音乐目录必须报错")
        } catch { }
    }
}
