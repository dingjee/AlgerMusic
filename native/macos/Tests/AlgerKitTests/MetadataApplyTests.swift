import Foundation
import XCTest

@testable import AlgerKit

/// 写回流程回归（E5）。
///
/// 覆盖：
/// - 保存前重读 → 相对打开基线的 **冲突检查**（冲突就不写）；
/// - **数值先验证再写**（非法值在写之前就报错，不会写一半）；
/// - 写后重读 **严格核验**（核验不过 = 未能确认保存成功）；
/// - 封面按 **实际字节** 比较（旧图换新图不能被布尔掩盖）；
/// - **来源关联**：只改标题不能把索引里已有的来源 ID 清零。
final class MetadataApplyTests: XCTestCase {

    // MARK: - 夹具

    private func tagsJSON(
        title: String = "旧标题",
        artist: String = "艺人",
        album: String = "",
        track: Int = 0,
        disc: Int = 0,
        year: Int = 0,
        hasArtwork: Bool = false,
        neteaseId: Int = 0,
        isrc: String? = nil,
        musicBrainzRecordingId: String? = nil,
        musicBrainzReleaseId: String? = nil
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "path": "/tmp/a.mp3",
            "format": "mp3",
            "durationMs": 1000,
            "title": title,
            "artist": artist,
            "album": album,
            "track": track,
            "disc": disc,
            "year": year,
            "hasArtwork": hasArtwork,
            "fileSize": 10,
            "neteaseId": neteaseId,
        ]
        if let isrc { payload["isrc"] = isrc }
        if let musicBrainzRecordingId { payload["musicBrainzRecordingId"] = musicBrainzRecordingId }
        if let musicBrainzReleaseId { payload["musicBrainzReleaseId"] = musicBrainzReleaseId }
        return payload
    }

    private func makeService(_ bridge: FakeMetadataBridge) throws -> (MetadataApplyService, BridgeClient) {
        let client = try bridge.makeClient()
        let service = MetadataService(client: client)
        return (MetadataApplyService(service: service), client)
    }

    // MARK: - 冲突

    func testBaselineConflictBlocksWrite() async throws {
        let bridge = try FakeMetadataBridge()
        // 保存前重读：标题已经被别人改了。
        try bridge.enqueueSuccess(tagsJSON(title: "别人改过的标题"))
        let (applyService, client) = try makeService(bridge)
        defer { client.shutdown() }

        let baseline = AudioTags(path: "/tmp/a.mp3", title: "旧标题", artist: "艺人")
        let selection = MetadataSelection(fields: [.title: "新标题"])

        do {
            _ = try await applyService.apply(path: "/tmp/a.mp3", baseline: baseline, selection: selection)
            XCTFail("相对基线的改动必须报冲突")
        } catch let error as MetadataError {
            guard case .conflict = error else {
                return XCTFail("应为 conflict，实际：\(error)")
            }
        }
        // **没有发出写入**。
        XCTAssertFalse(bridge.methods().contains("tags.write"))
    }

    func testUnchangedBaselineAllowsWriteAndVerifies() async throws {
        let bridge = try FakeMetadataBridge()
        try bridge.enqueueSuccess(tagsJSON(title: "旧标题"))     // 保存前重读
        try bridge.enqueueSuccess(tagsJSON(title: "新标题"))     // 写入返回
        try bridge.enqueueSuccess(tagsJSON(title: "新标题"))     // 写后重读
        let (applyService, client) = try makeService(bridge)
        defer { client.shutdown() }

        let baseline = AudioTags(path: "/tmp/a.mp3", title: "旧标题", artist: "艺人")
        let selection = MetadataSelection(fields: [.title: "新标题"])

        let verified = try await applyService.apply(
            path: "/tmp/a.mp3",
            baseline: baseline,
            selection: selection
        )
        XCTAssertEqual(verified.title, "新标题")
        XCTAssertEqual(bridge.methods(), ["tags.read", "tags.write", "tags.read"])

        // 只写勾选的字段；未勾选的字段不进补丁；`removeArtwork` 必传。
        let writeParams = bridge.requests()[1]["p"] as? [String: Any]
        let patch = writeParams?["patch"] as? [String: Any]
        XCTAssertEqual(patch?["title"] as? String, "新标题")
        XCTAssertNil(patch?["artist"])
        XCTAssertNil(patch?["album"])
        XCTAssertEqual(patch?["removeArtwork"] as? Bool, false)
    }

    func testVerificationMismatchFailsWithoutSuccess() async throws {
        let bridge = try FakeMetadataBridge()
        try bridge.enqueueSuccess(tagsJSON(title: "旧标题"))     // 保存前重读
        try bridge.enqueueSuccess(tagsJSON(title: "新标题"))     // 写入返回
        try bridge.enqueueSuccess(tagsJSON(title: "还是旧标题")) // 写后重读：没写进去
        let (applyService, client) = try makeService(bridge)
        defer { client.shutdown() }

        let baseline = AudioTags(path: "/tmp/a.mp3", title: "旧标题", artist: "艺人")
        let selection = MetadataSelection(fields: [.title: "新标题"])

        do {
            _ = try await applyService.apply(path: "/tmp/a.mp3", baseline: baseline, selection: selection)
            XCTFail("核验不过必须报错（不能报成功）")
        } catch let error as MetadataError {
            guard case .verificationFailed = error else {
                return XCTFail("应为 verificationFailed，实际：\(error)")
            }
            // 文案 **不能** 断言原文件零改动（写入可能已经发生）。
            XCTAssertFalse(error.description.contains("零改动"))
            XCTAssertTrue(error.description.contains("未能确认保存成功"))
        }
    }

    func testFieldNotExposedByBridgeFailsVerification() async throws {
        let bridge = try FakeMetadataBridge()
        try bridge.enqueueSuccess(tagsJSON())                    // 保存前重读（没有 isrc）
        try bridge.enqueueSuccess(tagsJSON())                    // 写入返回
        try bridge.enqueueSuccess(tagsJSON())                    // 写后重读（仍没有 isrc）
        let (applyService, client) = try makeService(bridge)
        defer { client.shutdown() }

        let baseline = AudioTags(path: "/tmp/a.mp3", title: "旧标题", artist: "艺人")
        let selection = MetadataSelection(fields: [.isrc: "USRC17607839"])

        do {
            _ = try await applyService.apply(path: "/tmp/a.mp3", baseline: baseline, selection: selection)
            XCTFail("桥接没返回该字段时不能报成功")
        } catch let error as MetadataError {
            guard case .verificationFailed = error else {
                return XCTFail("应为 verificationFailed，实际：\(error)")
            }
        }
    }

    // MARK: - 数值校验

    func testInvalidNumberIsRejectedBeforeAnyWrite() async throws {
        let bridge = try FakeMetadataBridge()
        let (applyService, client) = try makeService(bridge)
        defer { client.shutdown() }

        let baseline = AudioTags(path: "/tmp/a.mp3", title: "旧标题", artist: "艺人")
        let selection = MetadataSelection(fields: [.track: "-3"])

        do {
            _ = try await applyService.apply(path: "/tmp/a.mp3", baseline: baseline, selection: selection)
            XCTFail("非法数值必须在写之前报错")
        } catch let error as MetadataError {
            guard case .invalidSelection = error else {
                return XCTFail("应为 invalidSelection，实际：\(error)")
            }
        }
        // **一个请求都不能发**（连读都不必读）。
        XCTAssertTrue(bridge.methods().isEmpty)
    }

    // MARK: - 封面（按字节）

    func testArtworkChangeDetectsByteLevelConflict() async throws {
        let bridge = try FakeMetadataBridge()
        try bridge.enqueueSuccess(tagsJSON(hasArtwork: true))     // 保存前重读：有封面
        try bridge.enqueueSuccess(["base64": Data([0x02, 0x03]).base64EncodedString()])  // 现在的封面（与基线不同）
        let (applyService, client) = try makeService(bridge)
        defer { client.shutdown() }

        let baseline = AudioTags(path: "/tmp/a.mp3", title: "旧标题", hasArtwork: true)
        let artworkBaseline = MetadataArtworkBaseline.loaded(Data([0x01, 0x02]))
        let selection = MetadataSelection(artworkBase64: Data([0x09]).base64EncodedString())

        do {
            _ = try await applyService.apply(
                path: "/tmp/a.mp3",
                baseline: baseline,
                selection: selection,
                artworkBaseline: artworkBaseline
            )
            XCTFail("封面被换过必须报冲突")
        } catch let error as MetadataError {
            guard case .conflict = error else {
                return XCTFail("应为 conflict，实际：\(error)")
            }
        }
        XCTAssertFalse(bridge.methods().contains("tags.write"))
    }

    func testArtworkChangeWithoutBaselineIsRefused() async throws {
        let bridge = try FakeMetadataBridge()
        try bridge.enqueueSuccess(tagsJSON(hasArtwork: true))
        let (applyService, client) = try makeService(bridge)
        defer { client.shutdown() }

        let baseline = AudioTags(path: "/tmp/a.mp3", title: "旧标题", hasArtwork: true)
        let selection = MetadataSelection(artworkBase64: Data([0x09]).base64EncodedString())

        do {
            _ = try await applyService.apply(
                path: "/tmp/a.mp3",
                baseline: baseline,
                selection: selection,
                artworkBaseline: .notLoaded
            )
            XCTFail("没有封面基线时不能改封面")
        } catch let error as MetadataError {
            guard case .conflict = error else {
                return XCTFail("应为 conflict，实际：\(error)")
            }
        }
        XCTAssertFalse(bridge.methods().contains("tags.write"))
    }

    func testArtworkWriteIsVerifiedByBytes() async throws {
        let bridge = try FakeMetadataBridge()
        let written = Data([0xAA, 0xBB])
        try bridge.enqueueSuccess(tagsJSON(hasArtwork: false))    // 保存前重读：没有封面
        try bridge.enqueueSuccess(tagsJSON(hasArtwork: true))     // 写入返回
        try bridge.enqueueSuccess(tagsJSON(hasArtwork: true))     // 写后重读
        try bridge.enqueueSuccess(["base64": written.base64EncodedString()])  // 写后封面字节
        let (applyService, client) = try makeService(bridge)
        defer { client.shutdown() }

        let baseline = AudioTags(path: "/tmp/a.mp3", title: "旧标题", hasArtwork: false)
        let selection = MetadataSelection(artworkBase64: written.base64EncodedString())

        let verified = try await applyService.apply(
            path: "/tmp/a.mp3",
            baseline: baseline,
            selection: selection,
            artworkBaseline: .loaded(nil)
        )
        XCTAssertTrue(verified.hasArtwork)
        XCTAssertEqual(bridge.methods(), ["tags.read", "tags.write", "tags.read", "tags.artwork"])
    }

    func testArtworkWriteWithDifferentBytesFailsVerification() async throws {
        let bridge = try FakeMetadataBridge()
        try bridge.enqueueSuccess(tagsJSON(hasArtwork: false))    // 保存前重读
        try bridge.enqueueSuccess(tagsJSON(hasArtwork: true))     // 写入返回
        try bridge.enqueueSuccess(tagsJSON(hasArtwork: true))     // 写后重读
        try bridge.enqueueSuccess(["base64": Data([0x01]).base64EncodedString()])  // 写后封面（与写入的不同）
        let (applyService, client) = try makeService(bridge)
        defer { client.shutdown() }

        let baseline = AudioTags(path: "/tmp/a.mp3", title: "旧标题", hasArtwork: false)
        let selection = MetadataSelection(artworkBase64: Data([0xAA]).base64EncodedString())

        do {
            _ = try await applyService.apply(
                path: "/tmp/a.mp3",
                baseline: baseline,
                selection: selection,
                artworkBaseline: .loaded(nil)
            )
            XCTFail("封面字节不一致必须报错")
        } catch let error as MetadataError {
            guard case .verificationFailed = error else {
                return XCTFail("应为 verificationFailed，实际：\(error)")
            }
        }
    }

    // MARK: - 来源关联

    func testSourceIDIsKeptWhenNotExplicitlySelected() async throws {
        let bridge = try FakeMetadataBridge()
        try bridge.enqueueSuccess(tagsJSON(title: "旧标题", neteaseId: 0))
        try bridge.enqueueSuccess(tagsJSON(title: "新标题", neteaseId: 0))
        try bridge.enqueueSuccess(tagsJSON(title: "新标题", neteaseId: 0))
        let (applyService, client) = try makeService(bridge)
        defer { client.shutdown() }

        let baseline = AudioTags(path: "/tmp/a.mp3", title: "旧标题", artist: "艺人", neteaseId: 0)
        let selection = MetadataSelection(fields: [.title: "新标题"])

        let record = try await applyService.save(
            path: "/tmp/a.mp3",
            baseline: baseline,
            selection: selection,
            preservingSourceID: 12345
        )
        // 标签里没有来源 ID、用户也没勾来源 ID → **保留索引里已有的关联**。
        XCTAssertEqual(record.neteaseId, 12345)
        XCTAssertEqual(record.title, "新标题")
    }

    func testSourceIDCanBeClearedWhenExplicitlySelected() async throws {
        let bridge = try FakeMetadataBridge()
        try bridge.enqueueSuccess(tagsJSON(title: "旧标题", neteaseId: 0))
        try bridge.enqueueSuccess(tagsJSON(title: "旧标题", neteaseId: 0))
        try bridge.enqueueSuccess(tagsJSON(title: "旧标题", neteaseId: 0))
        let (applyService, client) = try makeService(bridge)
        defer { client.shutdown() }

        let baseline = AudioTags(path: "/tmp/a.mp3", title: "旧标题", artist: "艺人", neteaseId: 0)
        // 显式勾选来源 ID 并写成 0 → 允许清除关联。
        let selection = MetadataSelection(fields: [.neteaseId: "0"])

        let record = try await applyService.save(
            path: "/tmp/a.mp3",
            baseline: baseline,
            selection: selection,
            preservingSourceID: 12345
        )
        XCTAssertEqual(record.neteaseId, 0)
    }

    func testSourceIDMergeRules() {
        XCTAssertEqual(MetadataSourceID.merge(tagValue: 7, explicitlySelected: false, original: 99), 7)
        XCTAssertEqual(MetadataSourceID.merge(tagValue: 0, explicitlySelected: false, original: 99), 99)
        XCTAssertEqual(MetadataSourceID.merge(tagValue: 0, explicitlySelected: true, original: 99), 0)
        XCTAssertEqual(MetadataSourceID.merge(tagValue: 5, explicitlySelected: true, original: 99), 5)
    }

    // MARK: - 数值清零

    func testExplicitNumericZeroClearsWithoutVerificationFailure() async throws {
        let bridge = try FakeMetadataBridge()
        // 基线里曲序是 3；保存前重读仍是 3。
        try bridge.enqueueSuccess(tagsJSON(title: "旧标题", track: 3))
        try bridge.enqueueSuccess(tagsJSON(title: "旧标题", track: 0))     // 写入返回（曲序已清零）
        try bridge.enqueueSuccess(tagsJSON(title: "旧标题", track: 0))     // 写后重读（曲序 0 = 未知 → 空串）
        let (applyService, client) = try makeService(bridge)
        defer { client.shutdown() }

        let baseline = AudioTags(path: "/tmp/a.mp3", title: "旧标题", artist: "艺人", track: 3)
        // 用户明确把曲序清成 0（必须由用户勾选才会进选择）。
        let selection = MetadataSelection(fields: [.track: "0"])

        let verified = try await applyService.apply(
            path: "/tmp/a.mp3",
            baseline: baseline,
            selection: selection
        )
        // 写成功且核验通过（`""` 与 `"0"` 都是「未知」）。
        XCTAssertEqual(verified.track, 0)
        let patch = (bridge.requests()[1]["p"] as? [String: Any])?["patch"] as? [String: Any]
        XCTAssertEqual(patch?["track"] as? Int, 0)
    }

    // MARK: - 其它

    func testEmptySelectionIsRejected() async throws {
        let bridge = try FakeMetadataBridge()
        let (applyService, client) = try makeService(bridge)
        defer { client.shutdown() }

        let baseline = AudioTags(path: "/tmp/a.mp3", title: "旧标题")
        do {
            _ = try await applyService.apply(
                path: "/tmp/a.mp3",
                baseline: baseline,
                selection: MetadataSelection()
            )
            XCTFail("什么都没选不能保存")
        } catch let error as MetadataError {
            guard case .invalidSelection = error else {
                return XCTFail("应为 invalidSelection，实际：\(error)")
            }
        }
        XCTAssertTrue(bridge.methods().isEmpty)
    }

    func testExplicitlyClearedTextIsWrittenAsEmpty() async throws {
        let bridge = try FakeMetadataBridge()
        try bridge.enqueueSuccess(tagsJSON(title: "旧标题"))
        try bridge.enqueueSuccess(tagsJSON(title: ""))
        try bridge.enqueueSuccess(tagsJSON(title: ""))
        let (applyService, client) = try makeService(bridge)
        defer { client.shutdown() }

        let baseline = AudioTags(path: "/tmp/a.mp3", title: "旧标题", artist: "艺人")
        // 用户明确清空标题 → 写空（不是「当 nil 忽略」）。
        let selection = MetadataSelection(fields: [.title: ""])

        let verified = try await applyService.apply(
            path: "/tmp/a.mp3",
            baseline: baseline,
            selection: selection
        )
        XCTAssertEqual(verified.title, "")
        let patch = (bridge.requests()[1]["p"] as? [String: Any])?["patch"] as? [String: Any]
        XCTAssertEqual(patch?["title"] as? String, "")
    }
}
