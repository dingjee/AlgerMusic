import AVFoundation
import CryptoKit
import Foundation
import XCTest

@testable import AlgerKit

/// Exercises the real Rust tag reader/writer and real encoded audio; trash remains inside the fixture.
final class DownloadRealAudioTests: XCTestCase {
    private let ffmpeg = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")

    private func run(_ arguments: [String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = ffmpeg
        process.arguments = ["-hide_banner", "-loglevel", "error", "-y"] + arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "DownloadRealAudioTests", code: Int(process.terminationStatus))
        }
        return data
    }

    private func audio(_ name: String, codec: [String], in workspace: TempWorkspace) throws -> URL {
        let path = workspace.url(name)
        _ = try run(["-f", "lavfi", "-i", "sine=frequency=440:duration=3"] + codec + [path.path])
        return path
    }

    private func pcmDigest(_ path: URL) throws -> String {
        let pcm = try run(["-i", path.path, "-map", "0:a:0", "-ac", "1", "-ar", "44100", "-f", "s16le", "pipe:1"])
        XCTAssertFalse(pcm.isEmpty)
        return SHA256.hash(data: pcm).map { String(format: "%02x", $0) }.joined()
    }

    private func makeClient(_ workspace: TempWorkspace) throws -> BridgeClient {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: ffmpeg.path), "ffmpeg unavailable")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: TestPaths.bridgeBinary.path), "bridge unavailable")
        return try BridgeClient(executableURL: TestPaths.bridgeBinary, arguments: ["--session-path", workspace.url("session.json").path])
    }

    func testRealMP3ToFLACUpgradePreservesUserTagsArtworkAudioAndReferences() async throws {
        let workspace = try TempWorkspace("real-audio-upgrade")
        let client = try makeClient(workspace)
        defer { client.shutdown() }
        let bridge = BridgeService(client: client)
        let metadata = MetadataService(client: client)
        let old = try audio("old.mp3", codec: ["-c:a", "libmp3lame", "-b:a", "128k"], in: workspace)
        let new = try audio("new.flac", codec: ["-c:a", "flac"], in: workspace)
        let oldCover = try Data(contentsOf: TestPaths.repoRoot.appendingPathComponent("src-tauri/icons/icon-macos.png"))
        let newCover = try Data(contentsOf: TestPaths.repoRoot.appendingPathComponent("src-tauri/icons/icon-ios.png"))
        XCTAssertNotEqual(oldCover, newCover)
        _ = try await metadata.writeTags(path: old.path, patch: MetadataTagPatch(
            title: "我的标题", artist: "测试艺人", album: "测试专辑", albumArtist: "我的专辑艺人",
            genre: "手动分类", artworkBase64: oldCover.base64EncodedString(), neteaseId: 123
        ))
        _ = try await metadata.writeTags(path: new.path, patch: MetadataTagPatch(
            title: "原始标题", artist: "测试艺人", album: "测试专辑", albumArtist: "上游艺人",
            genre: "上游分类", artworkBase64: newCover.base64EncodedString(), neteaseId: 123
        ))
        let tags = try await metadata.readTags(path: old.path)
        XCTAssertEqual(tags.codec, "mp3")
        XCTAssertGreaterThan(tags.bitrate, 100_000, "lofty kbps must be converted to bps")
        XCTAssertLessThan(tags.bitrate, 200_000)
        let expectedPCM = try pcmDigest(new)
        let index = LibraryIndex(fileURL: workspace.url("index.json"))
        let store = NativeStore(fileURL: workspace.url("native.json"))
        try store.mutate { $0.settings.playlistsDirectory = workspace.url("Playlists").path }
        try index.upsert(TrackRecord(path: old.path, neteaseId: 123, title: tags.title, artist: tags.artist,
                                     album: tags.album, durationMs: UInt64(tags.durationMs), format: tags.format))
        let library = LocalLibrary(index: index, store: store)
        let playlist = try library.createPlaylist(title: "保留引用")
        _ = try library.addToPlaylist(id: playlist.id, entries: [PlaylistEntry(path: old.path, duration: 3, displayName: tags.title)])
        let intake = DownloadIntakeService(store: store, library: library)
        let trash = try workspace.makeDirectory("Trash")
        let review = DownloadReviewService(library: library, tagReader: bridge, resolver: bridge)
        let replacement = DownloadReplacementService(store: store, index: index, library: library, intake: intake,
            review: review, tagPreserver: MetadataTagPreserver(service: metadata), trash: { path in
                try FileManager.default.moveItem(at: URL(fileURLWithPath: path),
                                                 to: trash.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent))
            })
        try replacement.register(neteaseId: 123, oldPath: old.path)
        let outcome = await replacement.commit(neteaseId: 123, newPath: new.path)
        guard case .committed(let path) = outcome else { return XCTFail("Upgrade failed: \(outcome)") }
        XCTAssertEqual(path, new.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("old.mp3").path))
        let verified = try await metadata.readTags(path: new.path)
        XCTAssertEqual(verified.codec, "flac")
        XCTAssertEqual(verified.title, "我的标题")
        XCTAssertEqual(verified.albumArtist, "我的专辑艺人")
        XCTAssertEqual(verified.genre, "手动分类")
        let artwork = try await metadata.embeddedArtwork(path: new.path)
        XCTAssertEqual(artwork, oldCover)
        XCTAssertEqual(try pcmDigest(new), expectedPCM, "Tag preservation must not transcode the new audio")
        let asset = AVURLAsset(url: new)
        let playable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration)
        XCTAssertTrue(playable, "The upgraded file must remain playable by the native playback framework")
        XCTAssertEqual(duration.seconds, 3, accuracy: 0.2)
        XCTAssertNil(index.track(path: old.path))
        XCTAssertEqual(index.track(path: new.path)?.title, verified.title)
        let savedPlaylist = try XCTUnwrap(library.playlist(id: playlist.id))
        XCTAssertEqual(savedPlaylist.entries.map(\.path), [new.path])
        let reopened = LibraryIndex(fileURL: workspace.url("index.json"))
        XCTAssertEqual(reopened.track(path: new.path)?.title, "我的标题")
        let repeated = await replacement.commit(neteaseId: 123, newPath: new.path)
        XCTAssertEqual(repeated.survivingPath, new.path)
    }

    func testRealALACRemainsLosslessAndRejectsLossyReplacement() async throws {
        let workspace = try TempWorkspace("real-alac-protection")
        let client = try makeClient(workspace)
        defer { client.shutdown() }
        let bridge = BridgeService(client: client)
        let metadata = MetadataService(client: client)
        let old = try audio("old.m4a", codec: ["-c:a", "alac"], in: workspace)
        let new = try audio("new.mp3", codec: ["-c:a", "libmp3lame", "-b:a", "320k"], in: workspace)
        for path in [old, new] {
            _ = try await metadata.writeTags(path: path.path, patch: MetadataTagPatch(
                title: "测试歌曲", artist: "测试艺人", album: "测试专辑", neteaseId: 456
            ))
        }
        let oldBytes = try Data(contentsOf: old)
        let oldTags = try await metadata.readTags(path: old.path)
        let newTags = try await metadata.readTags(path: new.path)
        XCTAssertEqual(oldTags.codec, "alac")
        XCTAssertEqual(AudioQuality.measured(tags: oldTags).codecClass, .lossless)
        XCTAssertFalse(AudioQuality.measured(tags: newTags).isProvablyHigher(than: .measured(tags: oldTags)))
        let index = LibraryIndex(fileURL: workspace.url("index.json"))
        try index.upsert(TrackRecord(path: old.path, neteaseId: 456, title: oldTags.title, artist: oldTags.artist))
        let store = NativeStore(fileURL: workspace.url("native.json"))
        let library = LocalLibrary(index: index, store: store)
        let intake = DownloadIntakeService(store: store, library: library)
        let review = DownloadReviewService(library: library, tagReader: bridge, resolver: bridge)
        let trash = try workspace.makeDirectory("Trash")
        let replacement = DownloadReplacementService(store: store, index: index, library: library, intake: intake,
            review: review, tagPreserver: MetadataTagPreserver(service: metadata), trash: { path in
                try FileManager.default.moveItem(at: URL(fileURLWithPath: path),
                                                 to: trash.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent))
            })
        try replacement.register(neteaseId: 456, oldPath: old.path)
        let result = await replacement.commit(neteaseId: 456, newPath: new.path)
        guard case .discarded = result else { return XCTFail("Lossy downgrade must be discarded: \(result)") }
        XCTAssertEqual(try Data(contentsOf: old), oldBytes)
        XCTAssertNotNil(index.track(path: old.path))
        XCTAssertNil(index.track(path: new.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.path))
    }
}
