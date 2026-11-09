import Foundation
import XCTest
import AVFoundation

@testable import AlgerKit

/// **回归**：播放资产的可播放性（真实故障的根因守卫）。
///
/// 真实故障（2026-11-06 定位）：
/// 产品用 `AVURLAssetPreferPreciseDurationAndTimingKey: false`（快速时长）
/// 创建资产，未压缩 PCM（WAV / AIFF）资产会直接 **不可播放**：
/// `load(.duration)` 报 `AVFoundationErrorDomain -11800`
/// （内含 `NSOSStatusErrorDomain -17770`，失败依赖是 `Duration`），
/// `load(.isPlayable)` 返回 `false` → 播放项失败、真实播放完全没有声音。
///
/// 本文件把这些诊断结论固化成 **有断言的回归**：
/// - 本地未压缩 PCM 资产必须可播放；
/// - 网络未压缩 PCM 流必须能播（「快速时长」不可播放时要退回精确时长）；
/// - 加载失败必须让界面 **不再假装在播放**。
@MainActor
final class PlaybackAudioDiagnosticsTests: XCTestCase {

    /// 本地未压缩 PCM（WAV）资产：产品用的创建方式必须可播放。
    func testLocalUncompressedAssetIsPlayable() async throws {
        let workspace = try TempWorkspace("diag-local-asset")
        let audio = try TestAudio.writeWAV(to: workspace.url("a.wav"), seconds: 1.0)

        let asset = PlayerController.makeAsset(for: audio)
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable, "未压缩 PCM（WAV）资产必须可播放，否则真实播放完全没有声音")
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 1.0, accuracy: 0.05, "本地 WAV 的时长应当能被读出来")
    }

    /// 网络未压缩 PCM 流：「快速时长」下不可播放 → 必须退回精确时长。
    func testNetworkUncompressedStreamFallsBackToPlayableAsset() async throws {
        let server = try LocalAudioServer(body: TestAudio.wavData(seconds: 1.0))
        defer { server.stop() }
        let streamURL = server.baseURL.appendingPathComponent("song.wav")

        // 「快速时长」的资产对未压缩 PCM 流不可播放（这正是要回退的原因）。
        let fastAsset = PlayerController.makeAsset(for: streamURL)
        let fastPlayable = try? await fastAsset.load(.isPlayable)
        XCTAssertNotNil(fastPlayable, "网络资产的加载本身不该抛错（地址可达）")

        // 产品最终使用的资产必须可播放。
        let asset = try await PlayerController.makePlayableAsset(for: streamURL)
        let playable = try await asset.load(.isPlayable)
        XCTAssertTrue(playable, "网络未压缩 PCM 流必须可播放（不可播放时退回精确时长）")
    }

    /// 加载失败 → 必须报错并停止「假装播放」。
    func testFailedItemReportsErrorAndStopsPlaying() async throws {
        let resolver = FakePlaybackResolver()
        resolver.setHandler { _ in
            // 指向不存在的本地文件：资产加载必然失败。
            PlaybackSource(url: URL(fileURLWithPath: "/definitely/missing/track.wav"), isLocal: true)
        }
        let player = PlayerController(resolver: resolver)

        await player.replaceQueue([PlaybackItem(
            title: "坏地址",
            artist: "",
            durationMs: 1000,
            origin: .local(path: "/definitely/missing/track.wav")
        )])

        let failed = await waitForPlayback(timeout: 15) {
            player.errorMessage != nil || player.currentPlayerItem?.status == .failed
        }
        XCTAssertTrue(failed, "加载失败必须能被观察到（错误提示或播放项失败）")
        XCTAssertFalse(player.isPlaying, "加载失败后不得继续假装在播放")
        XCTAssertNotNil(player.errorMessage, "加载失败必须给出明确的错误信息")
    }
}
