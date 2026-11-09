import Foundation
import XCTest

@testable import AlgerKit

/// 设置 dirty 计算回归（**基线来自真实会话快照**）。
final class SettingsDraftTests: XCTestCase {

    private func snapshot(
        quality: String = "higher",
        sources: [String] = ["pyncmd", "gdmusic", "kugou"],
        downloadDirectory: String = "/Users/me/Music/AlgerMusic"
    ) -> SessionSnapshot {
        SessionSnapshot(
            loggedIn: true,
            hasCookie: true,
            account: nil,
            quality: quality,
            sources: sources,
            downloadDirectory: downloadDirectory,
            sessionPath: "/tmp/session.json",
            loadIssue: nil,
            downloadLoadIssue: nil,
            downloadLastError: nil
        )
    }

    /// 什么都没改 → **不提交任何字段**。
    func testNoChangeSubmitsNothing() {
        let baseline = SettingsBaseline(snapshot: snapshot())
        let changes = SettingsDraft.changes(
            baseline: baseline,
            quality: "higher",
            sources: ["pyncmd", "gdmusic", "kugou"],
            downloadDirectory: "/Users/me/Music/AlgerMusic"
        )
        XCTAssertTrue(changes.isEmpty)
        XCTAssertNil(changes.rejection)
    }

    /// 只改目录 → **只提交目录**（音质 / 音源不动）。
    func testOnlyDirectoryChangeSubmitsOnlyDirectory() {
        let baseline = SettingsBaseline(snapshot: snapshot())
        let changes = SettingsDraft.changes(
            baseline: baseline,
            quality: "higher",
            sources: ["pyncmd", "gdmusic", "kugou"],
            downloadDirectory: "/Volumes/Music/AlgerMusic"
        )
        XCTAssertNil(changes.quality)
        XCTAssertNil(changes.sources)
        XCTAssertEqual(changes.downloadDirectory, "/Volumes/Music/AlgerMusic")
    }

    /// 音源顺序变了也算改动（**优先顺序必须提交**）。
    func testSourceOrderChangeIsSubmitted() {
        let baseline = SettingsBaseline(snapshot: snapshot())
        let changes = SettingsDraft.changes(
            baseline: baseline,
            quality: "higher",
            sources: ["gdmusic", "pyncmd", "kugou"],
            downloadDirectory: "/Users/me/Music/AlgerMusic"
        )
        XCTAssertEqual(changes.sources, ["gdmusic", "pyncmd", "kugou"])
        XCTAssertNil(changes.quality)
    }

    /// 基线未知（会话没载入）→ **不提交** 音质 / 音源，
    /// 绝不能把默认值当改动覆盖真实设置。
    func testUnknownBaselineNeverSubmitsRemoteFields() {
        let changes = SettingsDraft.changes(
            baseline: .unknown,
            quality: "higher",
            sources: [],
            downloadDirectory: "/Users/me/Music/AlgerMusic"
        )
        XCTAssertNil(changes.quality, "基线未知时不得提交音质")
        XCTAssertNil(changes.sources, "基线未知时不得提交音源")
        XCTAssertNotNil(changes.rejection)
    }

    /// 目录被清空 → 拒绝提交，保留原值。
    func testEmptyDirectoryIsRejected() {
        let baseline = SettingsBaseline(snapshot: snapshot())
        let changes = SettingsDraft.changes(
            baseline: baseline,
            quality: "higher",
            sources: ["pyncmd", "gdmusic", "kugou"],
            downloadDirectory: ""
        )
        XCTAssertNil(changes.downloadDirectory)
        XCTAssertNotNil(changes.rejection)
    }

    /// 非默认音质 / 音源必须被 **原样保留**（不会被默认值覆盖）。
    func testNonDefaultSnapshotIsPreserved() {
        let snapshot = self.snapshot(quality: "lossless", sources: ["kuwo", "migu"])
        let baseline = SettingsBaseline(snapshot: snapshot)
        XCTAssertEqual(baseline.quality, "lossless")
        XCTAssertEqual(baseline.sources, ["kuwo", "migu"])
        let changes = SettingsDraft.changes(
            baseline: baseline,
            quality: "lossless",
            sources: ["kuwo", "migu"],
            downloadDirectory: "/Users/me/Music/AlgerMusic"
        )
        XCTAssertTrue(changes.isEmpty, "未改动不得提交")
    }
}
