import Foundation
import XCTest
import CryptoKit

@testable import AlgerKit

/// 真实桥接回归（E5）：**真实 `BridgeClient` → `MetadataService` → `MetadataApplyService`**
/// 对 **真实音频文件** 做标签写 / 读。
///
/// 规则：
/// - 音频文件与桥接会话都在 `.artifacts/` 下的隔离目录里（**不碰真实 profile / 真实音乐**）；
/// - 依赖缺失（没有桥接二进制 / 没有 ffmpeg）时 **明确跳过**，不假装通过；
/// - 写完必须 **重新读** 验证，并且 **音频本身仍可解码**（不重编码、路径不变）。
final class MetadataRealBridgeTests: XCTestCase {

    /// ffmpeg 路径（找不到就跳过）。
    private static let ffmpegCandidates = [
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/usr/bin/ffmpeg",
    ]

    private var ffmpeg: URL? {
        for candidate in Self.ffmpegCandidates
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    /// 用 ffmpeg 生成一个隔离的音频文件（无声正弦，1 秒）。
    private func makeAudio(_ tool: URL, arguments: [String], named name: String, in workspace: TempWorkspace) throws -> URL {
        let output = workspace.url(name)
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments + ["-y", output.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "MetadataRealBridgeTests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "ffmpeg 生成夹具失败：\(name)"
            ])
        }
        return output
    }

    /// 起真实桥接（**隔离会话路径**）。
    private func makeRealClient(_ workspace: TempWorkspace) throws -> BridgeClient {
        try BridgeClient(
            executableURL: TestPaths.bridgeBinary,
            arguments: ["--session-path", workspace.url("session.json").path]
        )
    }

    // MARK: - 真实标签写 / 读

    func testRealTagWriteReadRoundTripKeepsAudioIntact() async throws {
        try XCTSkipIf(
            !FileManager.default.isExecutableFile(atPath: TestPaths.bridgeBinary.path),
            "缺少真实桥接二进制：\(TestPaths.bridgeBinary.path)"
        )
        guard let ffmpeg else {
            throw XCTSkip("缺少 ffmpeg，无法生成真实音频夹具")
        }
        let workspace = try TempWorkspace("metadata-real-tags")
        let audio = try makeAudio(
            ffmpeg,
            arguments: ["-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-c:a", "libmp3lame", "-b:a", "128k"],
            named: "fixture.mp3",
            in: workspace
        )
        let before = try FileManager.default.attributesOfItem(atPath: audio.path)
        // **音频内容基线**：解码成 PCM 的摘要（写标签不得改动音频流）。
        let pcmBefore = try decodedPCM(audio, with: ffmpeg)
        XCTAssertFalse(pcmBefore.isEmpty, "夹具必须能解码出音频数据")

        let client = try makeRealClient(workspace)
        defer { client.shutdown() }
        let service = MetadataService(client: client)
        let applyService = MetadataApplyService(service: service)

        // 1) 读基线。
        let baseline = try await service.readTags(path: audio.path)
        XCTAssertEqual(baseline.format, "mp3")
        XCTAssertEqual(baseline.path, audio.path)

        // 2) 写入（只写勾选的字段）。
        let selection = MetadataSelection(fields: [
            .title: "真实回归标题",
            .artist: "真实回归艺人",
        ])
        let verified = try await applyService.apply(
            path: audio.path,
            baseline: baseline,
            selection: selection
        )
        XCTAssertEqual(verified.title, "真实回归标题")
        XCTAssertEqual(verified.artist, "真实回归艺人")

        // 3) 再读一次（真实文件）。
        let reread = try await service.readTags(path: audio.path)
        XCTAssertEqual(reread.title, "真实回归标题")
        XCTAssertEqual(reread.artist, "真实回归艺人")

        // 4) 音频本身没被动过：路径不变、时长不变、**解码出的 PCM 完全一致**
        //    （标签字节会让文件变大，但音频流不得被重编码或改动）。
        XCTAssertEqual(reread.path, audio.path, "写标签不得改音频路径")
        XCTAssertEqual(reread.durationMs, baseline.durationMs, "写标签不得改时长")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        let pcmAfter = try decodedPCM(audio, with: ffmpeg)
        XCTAssertEqual(
            Self.digest(pcmBefore),
            Self.digest(pcmAfter),
            "写标签不得改动音频内容（解码 PCM 必须逐字节一致）"
        )
        try assertDecodable(audio, with: ffmpeg)
        _ = before
    }

    func testRealTagConflictDetectsExternalChange() async throws {
        try XCTSkipIf(
            !FileManager.default.isExecutableFile(atPath: TestPaths.bridgeBinary.path),
            "缺少真实桥接二进制：\(TestPaths.bridgeBinary.path)"
        )
        guard let ffmpeg else {
            throw XCTSkip("缺少 ffmpeg，无法生成真实音频夹具")
        }
        let workspace = try TempWorkspace("metadata-real-conflict")
        let audio = try makeAudio(
            ffmpeg,
            arguments: ["-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-c:a", "libmp3lame", "-b:a", "128k"],
            named: "fixture.mp3",
            in: workspace
        )

        let client = try makeRealClient(workspace)
        defer { client.shutdown() }
        let service = MetadataService(client: client)
        let applyService = MetadataApplyService(service: service)

        let baseline = try await service.readTags(path: audio.path)

        // 别的程序改了标题（这里用同一个桥接模拟外部写入）。
        _ = try await service.writeTags(
            path: audio.path,
            patch: MetadataTagPatch(title: "别人写的标题")
        )

        // 相对基线的写入必须被拒。
        do {
            _ = try await applyService.apply(
                path: audio.path,
                baseline: baseline,
                selection: MetadataSelection(fields: [.title: "我的标题"])
            )
            XCTFail("外部改动后必须报冲突")
        } catch let error as MetadataError {
            guard case .conflict = error else {
                return XCTFail("应为 conflict，实际：\(error)")
            }
        }
        // 外部的改动必须保留。
        let after = try await service.readTags(path: audio.path)
        XCTAssertEqual(after.title, "别人写的标题")
    }

    func testRealArtworkWriteIsVerifiedByBytes() async throws {
        try XCTSkipIf(
            !FileManager.default.isExecutableFile(atPath: TestPaths.bridgeBinary.path),
            "缺少真实桥接二进制：\(TestPaths.bridgeBinary.path)"
        )
        guard let ffmpeg else {
            throw XCTSkip("缺少 ffmpeg，无法生成真实音频夹具")
        }
        let workspace = try TempWorkspace("metadata-real-artwork")
        let audio = try makeAudio(
            ffmpeg,
            arguments: ["-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-c:a", "libmp3lame", "-b:a", "128k"],
            named: "fixture.mp3",
            in: workspace
        )
        // 生成一张真实 PNG 当封面。
        let cover = try makeAudio(
            ffmpeg,
            arguments: ["-f", "lavfi", "-i", "color=c=red:s=16x16", "-frames:v", "1"],
            named: "cover.png",
            in: workspace
        )
        let coverBytes = try Data(contentsOf: cover)

        let client = try makeRealClient(workspace)
        defer { client.shutdown() }
        let service = MetadataService(client: client)
        let applyService = MetadataApplyService(service: service)

        let baseline = try await service.readTags(path: audio.path)
        let artworkBaseline = MetadataArtworkBaseline.loaded(nil)

        let selection = MetadataSelection(artworkBase64: coverBytes.base64EncodedString())
        let verified = try await applyService.apply(
            path: audio.path,
            baseline: baseline,
            selection: selection,
            artworkBaseline: artworkBaseline
        )
        XCTAssertTrue(verified.hasArtwork, "写后重读必须能看到内嵌封面")

        // 封面字节必须与写入的一致。
        let state = try await service.embeddedArtworkState(path: audio.path)
        guard case .present(let bytes) = state else {
            return XCTFail("写后必须能读回封面，实际：\(state)")
        }
        XCTAssertEqual(bytes, coverBytes, "内嵌封面字节必须与写入的一致")
    }

    func testRealFlacRoundTrip() async throws {
        try XCTSkipIf(
            !FileManager.default.isExecutableFile(atPath: TestPaths.bridgeBinary.path),
            "缺少真实桥接二进制：\(TestPaths.bridgeBinary.path)"
        )
        guard let ffmpeg else {
            throw XCTSkip("缺少 ffmpeg，无法生成真实音频夹具")
        }
        let workspace = try TempWorkspace("metadata-real-flac")
        let audio = try makeAudio(
            ffmpeg,
            arguments: ["-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-c:a", "flac"],
            named: "fixture.flac",
            in: workspace
        )

        let client = try makeRealClient(workspace)
        defer { client.shutdown() }
        let service = MetadataService(client: client)
        let applyService = MetadataApplyService(service: service)

        let baseline = try await service.readTags(path: audio.path)
        XCTAssertEqual(baseline.format, "flac")
        let pcmBefore = try decodedPCM(audio, with: ffmpeg)

        let verified = try await applyService.apply(
            path: audio.path,
            baseline: baseline,
            selection: MetadataSelection(fields: [
                .title: "FLAC 标题",
                .album: "FLAC 专辑",
                .track: "3",
            ])
        )
        XCTAssertEqual(verified.title, "FLAC 标题")
        XCTAssertEqual(verified.album, "FLAC 专辑")
        XCTAssertEqual(verified.track, 3)
        // 音频内容不变。
        XCTAssertEqual(
            Self.digest(pcmBefore),
            Self.digest(try decodedPCM(audio, with: ffmpeg)),
            "写标签不得改动音频内容（解码 PCM 必须逐字节一致）"
        )
        try assertDecodable(audio, with: ffmpeg)
    }

    /// 真实桥接：把曲序 **显式清零** 必须写成功且核验通过（`0` 与「未知」等价）。
    func testRealNumericClearToZeroRoundTrip() async throws {
        try XCTSkipIf(
            !FileManager.default.isExecutableFile(atPath: TestPaths.bridgeBinary.path),
            "缺少真实桥接二进制：\(TestPaths.bridgeBinary.path)"
        )
        guard let ffmpeg else {
            throw XCTSkip("缺少 ffmpeg，无法生成真实音频夹具")
        }
        let workspace = try TempWorkspace("metadata-real-zero")
        let audio = try makeAudio(
            ffmpeg,
            arguments: ["-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-c:a", "libmp3lame", "-b:a", "128k"],
            named: "fixture.mp3",
            in: workspace
        )
        let client = try makeRealClient(workspace)
        defer { client.shutdown() }
        let service = MetadataService(client: client)
        let applyService = MetadataApplyService(service: service)

        // 先写曲序 3。
        let baseline = try await service.readTags(path: audio.path)
        let written = try await applyService.apply(
            path: audio.path,
            baseline: baseline,
            selection: MetadataSelection(fields: [.track: "3"])
        )
        XCTAssertEqual(written.track, 3)

        // 再显式清零（写 0）：必须成功，核验不得误报。
        let current = try await service.readTags(path: audio.path)
        XCTAssertEqual(current.track, 3)
        let cleared = try await applyService.apply(
            path: audio.path,
            baseline: current,
            selection: MetadataSelection(fields: [.track: "0"])
        )
        XCTAssertEqual(cleared.track, 0)
        let reread = try await service.readTags(path: audio.path)
        XCTAssertEqual(reread.track, 0)
    }

    // MARK: - 工具

    /// ffmpeg 解码成 PCM（原始字节），用于比较 **音频内容**。
    ///
    /// 注意：先 **读完 stdout 再 wait**（否则管道背压会把子进程挂住），
    /// stderr 直接丢到 `/dev/null`（不占管道）。
    private func decodedPCM(_ audio: URL, with tool: URL) throws -> Data {
        let process = Process()
        process.executableURL = tool
        process.arguments = [
            "-v", "error",
            "-i", audio.path,
            "-f", "s16le",
            "-acodec", "pcm_s16le",
            "-",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "MetadataRealBridgeTests", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "ffmpeg 解码失败（exit \(process.terminationStatus)）：\(audio.lastPathComponent)"
            ])
        }
        return data
    }

    /// 字节摘要。
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 音频仍可解码（标签写入没有破坏音频流）。
    private func assertDecodable(_ audio: URL, with tool: URL) throws {
        let process = Process()
        process.executableURL = tool
        process.arguments = ["-v", "error", "-i", audio.path, "-f", "null", "-"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(
            process.terminationStatus,
            0,
            "写标签后音频必须仍可解码（exit \(process.terminationStatus)）"
        )
    }
}
