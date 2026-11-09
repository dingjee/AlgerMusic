import Foundation
import XCTest

@testable import AlgerKit

/// 改「歌单目录」后 **既有歌单仍可访问**（真实位置与内容都不丢）。
final class PlaylistDirectoryTests: XCTestCase {

    func testChangingDirectoryKeepsExistingPlaylistsAccessible() throws {
        let workspace = try TempWorkspace("playlist-dir")
        let store = NativeStore(fileURL: workspace.url("native.json"))
        let index = LibraryIndex(fileURL: workspace.url("library/index.json"))
        let library = LocalLibrary(index: index, store: store)

        let firstDirectory = try workspace.makeDirectory("playlists-a")
        let secondDirectory = try workspace.makeDirectory("playlists-b")
        try store.mutate { $0.settings.playlistsDirectory = firstDirectory.path }

        // 在第一个目录里建歌单并加曲目。
        let playlist = try library.createPlaylist(title: "老歌单", details: "说明")
        let audio = try TestAudio.writeWAV(to: workspace.url("music/song.wav"), seconds: 0.2)
        let appended = try library.addToPlaylist(id: playlist.id, entries: [
            PlaylistEntry(path: audio.path, duration: 0.2, displayName: "歌曲")
        ])
        XCTAssertEqual(appended.count, 1)

        // **改目录**（模拟用户在设置里换位置）。
        try store.mutate { $0.settings.playlistsDirectory = secondDirectory.path }

        // 既有歌单仍然可读，内容完整，真实位置不变。
        let reloaded = try library.playlist(id: playlist.id)
        XCTAssertNotNil(reloaded, "改了目录之后既有歌单必须仍然可访问")
        XCTAssertEqual(reloaded?.entries.count, 1)
        XCTAssertEqual(reloaded?.entries.first?.path, audio.path)
        XCTAssertEqual(reloaded?.title, "老歌单")
        XCTAssertEqual(reloaded?.details, "说明")
        XCTAssertTrue(
            reloaded?.fileURL.path.hasPrefix(firstDirectory.path) ?? false,
            "既有歌单必须留在原来的真实位置"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: reloaded?.fileURL.path ?? ""))

        // 整组读取也不能把它吞掉。
        let (playlists, issues, failed) = library.playlistsWithIssues()
        XCTAssertEqual(playlists.count, 1)
        XCTAssertTrue(issues.isEmpty)
        XCTAssertTrue(failed.isEmpty)

        // 新建歌单走新目录。
        let fresh = try library.createPlaylist(title: "新歌单")
        XCTAssertTrue(fresh.fileURL.path.hasPrefix(secondDirectory.path))
    }
}
