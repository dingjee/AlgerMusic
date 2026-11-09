import Foundation
import XCTest

@testable import AlgerKit

/// 元信息模型回归（E5）。
///
/// 覆盖：
/// - 桥接契约的形状解析（候选 / 发行 / 曲目 / 封面 / 标签）；
/// - **分数是 0…100 百分制**（后端 `UInt32`，AcoustID 也乘 100）→ 本地一律除 100；
/// - 差异列表的默认勾选规则（**只补空缺，不覆盖非空**）；
/// - 写入补丁的形状（`None` 不改、`removeArtwork` 必传）与 **数值先验证再写**。
final class MetadataModelsTests: XCTestCase {

    // MARK: - 分数：百分制 → 0…1

    func testCandidateScoreConvertsHundredScale() async throws {
        // 后端固定 0…100：87 分 = 0.87。
        let candidate = try XCTUnwrap(MetadataCandidate.parse([
            "recordingId": "rec-1",
            "title": "Song",
            "artist": "Artist",
            "durationMs": 201000,
            "score": 87,
        ]))
        XCTAssertEqual(candidate.score, 0.87, accuracy: 0.000_001)
        XCTAssertFalse(candidate.isLowConfidence)

        // 后端给 1 就是 1% —— **不做「小于 1 就当 1」的启发式**。
        let tiny = try XCTUnwrap(MetadataCandidate.parse([
            "recordingId": "rec-2",
            "score": 1,
        ]))
        XCTAssertEqual(tiny.score, 0.01, accuracy: 0.000_001)
        XCTAssertTrue(tiny.isLowConfidence)

        // 满分 100 → 1.0。
        let perfect = try XCTUnwrap(MetadataCandidate.parse([
            "recordingId": "rec-3",
            "score": 100,
        ]))
        XCTAssertEqual(perfect.score, 1.0, accuracy: 0.000_001)
        XCTAssertFalse(perfect.isLowConfidence)

        // 0 分 → 0。
        let zero = try XCTUnwrap(MetadataCandidate.parse([
            "recordingId": "rec-4",
            "score": 0,
        ]))
        XCTAssertEqual(zero.score, 0, accuracy: 0.000_001)
        XCTAssertTrue(zero.isLowConfidence)

        // 缺分数 → 0（低置信度）。
        let missing = try XCTUnwrap(MetadataCandidate.parse(["recordingId": "rec-5"]))
        XCTAssertEqual(missing.score, 0, accuracy: 0.000_001)
        XCTAssertTrue(missing.isLowConfidence)
    }

    func testCandidateParsesReleasesAndISRCs() async throws {
        let candidate = try XCTUnwrap(MetadataCandidate.parse([
            "recordingId": "rec-1",
            "title": "Song",
            "artist": "Artist",
            "durationMs": 201000,
            "score": 92,
            "isrcs": ["USRC17607839", "GBAYE0601498"],
            "releases": [[
                "id": "rel-1",
                "title": "Album",
                "date": "2019-05-01",
                "country": "GB",
                "albumArtist": "Artist",
            ]],
        ]))
        XCTAssertEqual(candidate.isrcs, ["USRC17607839", "GBAYE0601498"])
        XCTAssertEqual(candidate.releases.count, 1)
        XCTAssertEqual(candidate.releases.first?.id, "rel-1")
        XCTAssertEqual(candidate.releases.first?.date, "2019-05-01")
        XCTAssertEqual(candidate.releases.first?.albumArtist, "Artist")
    }

    func testCandidateWithoutRecordingIDIsRejected() {
        XCTAssertNil(MetadataCandidate.parse(["title": "Song"]))
        XCTAssertNil(MetadataCandidate.parse(["recordingId": ""]))
        XCTAssertNil(MetadataCandidate.parse("不是对象"))
    }

    // MARK: - 发行 / 曲目 / 封面

    func testReleaseAndTrackParsing() async throws {
        let release = try XCTUnwrap(MetadataRelease.parse([
            "id": "rel-9",
            "title": "Album",
            "date": "2020-01-02",
            "country": "US",
            "albumArtist": "AA",
        ]))
        XCTAssertEqual(release.id, "rel-9")
        XCTAssertEqual(release.country, "US")

        let track = try XCTUnwrap(MetadataTrack.parse([
            "recordingId": "rec-9",
            "title": "T",
            "artist": "A",
            "track": 3,
            "disc": 1,
            "durationMs": 1000,
        ]))
        XCTAssertEqual(track.track, 3)
        XCTAssertEqual(track.disc, 1)
        XCTAssertNil(MetadataTrack.parse(["title": "没有录音 ID"]))
    }

    func testArtworkParsing() async throws {
        let payload = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]).base64EncodedString()
        let artwork = try XCTUnwrap(MetadataArtwork.parse([
            "artworkBase64": payload,
            "mimeType": "image/jpeg",
            "releaseId": "rel-1",
        ]))
        XCTAssertEqual(artwork.releaseId, "rel-1")
        XCTAssertEqual(artwork.mimeType, "image/jpeg")
        XCTAssertEqual(artwork.data, Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]))
        // 空封面 → 无效。
        XCTAssertNil(MetadataArtwork.parse(["artworkBase64": ""]))
    }

    // MARK: - 标签读取

    func testAudioTagsDistinguishesMissingFieldFromEmptyValue() async throws {
        let tags = try XCTUnwrap(AudioTags.parse([
            "path": "/tmp/a.mp3",
            "format": "mp3",
            "durationMs": 1000,
            "title": "T",
            "artist": "",
            "album": "Album",
            "hasArtwork": true,
            "fileSize": 1234,
            "neteaseId": 42,
        ]))
        // 桥接 **没暴露** 的字段是 nil（不是空串）：无法核验。
        XCTAssertNil(tags.isrc)
        XCTAssertNil(tags.date)
        XCTAssertNil(tags.musicBrainzRecordingId)
        XCTAssertNil(tags.musicBrainzReleaseId)
        XCTAssertNil(tags.value(for: .isrc))
        // 暴露了但是空的字段 → 空串（= 空缺，可默认补上）。
        XCTAssertEqual(tags.value(for: .artist), "")
        XCTAssertEqual(tags.value(for: .title), "T")
        XCTAssertEqual(tags.value(for: .neteaseId), "42")
        XCTAssertEqual(tags.value(for: .artwork), "已有封面")
    }

    func testAudioTagsRejectsNonObject() {
        XCTAssertNil(AudioTags.parse("不是对象"))
        XCTAssertNil(AudioTags.parse([1, 2, 3]))
    }

    // MARK: - 差异与默认勾选

    func testDifferencesOnlyDefaultSelectEmptyFields() {
        let current = AudioTags(
            path: "/tmp/a.mp3",
            title: "手工改过的标题",
            artist: "",
            album: "已有专辑",
            hasArtwork: true
        )
        let proposal = MetadataProposal(
            title: "候选标题",
            artist: "候选艺人",
            album: "候选专辑",
            artworkBase64: Data([0x01]).base64EncodedString()
        )
        let differences = MetadataDifferences.compute(current: current, proposal: proposal)
        let byField = Dictionary(uniqueKeysWithValues: differences.map { ($0.field, $0) })

        // 非空字段：出现在差异里，但 **不默认勾选**。
        XCTAssertNotNil(byField[.title])
        XCTAssertFalse(byField[.title]!.defaultSelected)
        XCTAssertTrue(byField[.title]!.isVerifiable)

        // 空缺字段：默认勾选（补空缺）。
        XCTAssertNotNil(byField[.artist])
        XCTAssertTrue(byField[.artist]!.defaultSelected)
        XCTAssertTrue(byField[.artist]!.isMissing)

        // 非空且候选不同：默认不勾。
        XCTAssertNotNil(byField[.album])
        XCTAssertFalse(byField[.album]!.defaultSelected)

        // 封面：**永远不默认勾**（嵌入是用户显式选择）。
        XCTAssertNotNil(byField[.artwork])
        XCTAssertFalse(byField[.artwork]!.defaultSelected)

        // 没有差异的字段不出现。
        XCTAssertNil(byField[.genre])
    }

    func testUnreadableFieldIsNeitherSelectedNorVerifiable() {
        let current = AudioTags(path: "/tmp/a.mp3", title: "T")
        let proposal = MetadataProposal(isrc: "USRC17607839")
        let differences = MetadataDifferences.compute(current: current, proposal: proposal)
        let isrc = try? XCTUnwrap(differences.first { $0.field == .isrc })
        XCTAssertNotNil(isrc)
        XCTAssertFalse(isrc!.isVerifiable)
        XCTAssertFalse(isrc!.defaultSelected)
    }

    func testDifferencesSkipIdenticalValues() {
        let current = AudioTags(path: "/tmp/a.mp3", title: "Same", track: 3)
        let proposal = MetadataProposal(title: "Same", track: 3)
        let differences = MetadataDifferences.compute(current: current, proposal: proposal)
        XCTAssertTrue(differences.isEmpty)
    }

    // MARK: - 写入补丁

    func testPatchPayloadOmitsNilAndAlwaysSendsRemoveArtwork() async throws {
        let patch = MetadataTagPatch(title: "新标题")
        let payload = patch.payload()
        XCTAssertEqual(payload["title"] as? String, "新标题")
        // `None` 不改：**不能出现在补丁里**。
        XCTAssertNil(payload["artist"])
        XCTAssertNil(payload["album"])
        XCTAssertNil(payload["track"])
        XCTAssertNil(payload["artworkBase64"])
        XCTAssertNil(payload["neteaseId"])
        XCTAssertNil(payload["isrc"])
        XCTAssertNil(payload["musicBrainzRecordingId"])
        XCTAssertNil(payload["musicBrainzReleaseId"])
        // `removeArtwork` 是 **非可选** 字段：不删封面时必须显式 false。
        XCTAssertEqual(payload["removeArtwork"] as? Bool, false)
        XCTAssertEqual(payload.count, 2)
    }

    func testSelectionOnlyWritesCheckedFields() async throws {
        let selection = MetadataSelection(fields: [
            .title: "新标题",
            .track: "5",
            .year: "2021",
        ])
        let payload = try selection.patch().payload()
        XCTAssertEqual(payload["title"] as? String, "新标题")
        XCTAssertEqual(payload["track"] as? Int, 5)
        XCTAssertEqual(payload["year"] as? Int, 2021)
        XCTAssertNil(payload["artist"])
        XCTAssertNil(payload["album"])
        XCTAssertEqual(payload["removeArtwork"] as? Bool, false)
    }

    func testSelectionRejectsInvalidNumbersBeforeWriting() async throws {
        let invalid = ["abc", "-1", "4294967296", "3.5"]
        for value in invalid {
            let selection = MetadataSelection(fields: [.track: value])
            XCTAssertThrowsError(try selection.patch()) { error in
                guard case MetadataError.invalidSelection = error else {
                    return XCTFail("数值「\(value)」应报 invalidSelection，实际：\(error)")
                }
            }
        }
        // 边界值合法。
        XCTAssertNoThrow(try MetadataSelection(fields: [.track: "0"]).patch())
        XCTAssertNoThrow(try MetadataSelection(fields: [.track: "4294967295"]).patch())
        // 来源 ID 不能为负。
        XCTAssertThrowsError(try MetadataSelection(fields: [.neteaseId: "-1"]).patch())
    }

    /// 数值 **留空 = 显式清零**（写 0 = 未知 / 已清除），且必须由用户勾选才生效。
    func testBlankNumericMeansExplicitZero() async throws {
        let payload = try MetadataSelection(fields: [.track: "", .year: ""]).patch().payload()
        XCTAssertEqual(payload["track"] as? Int, 0)
        XCTAssertEqual(payload["year"] as? Int, 0)
        let idPayload = try MetadataSelection(fields: [.neteaseId: ""]).patch().payload()
        XCTAssertEqual(idPayload["neteaseId"] as? Int64, 0)
    }

    /// 「未知」的归一化必须统一：`""`（标签里没有）与 `"0"`（显式清零）等价。
    func testNumericNormalizeTreatsBlankAndZeroAsUnknown() async throws {
        XCTAssertEqual(MetadataField.track.normalize(""), MetadataField.track.normalize("0"))
        XCTAssertEqual(MetadataField.year.normalize("  "), MetadataField.year.normalize("0"))
        XCTAssertEqual(MetadataField.neteaseId.normalize(""), MetadataField.neteaseId.normalize("0"))
        // 非数值字段不做这个合并。
        XCTAssertNotEqual(MetadataField.title.normalize(""), MetadataField.title.normalize("0"))
        // 前导零归一化。
        XCTAssertEqual(MetadataField.track.normalize("03"), "3")
    }

    /// 低置信度：**lookup 的满分不能覆盖搜索阶段的低分**。
    func testEffectiveScoreKeepsTheLowerConfidence() async throws {
        // 搜索 12 分 → 0.12；lookup 按精确 ID 返回 100 分 → 1.0。
        let effective = MetadataCandidate.effectiveScore(searchScore: 0.12, lookupScore: 1.0)
        XCTAssertEqual(effective, 0.12, accuracy: 0.000_001)
        // 仍然是低置信度（不能因为 lookup 成功就变成高置信度）。
        let candidate = MetadataCandidate(recordingId: "rec-1", score: effective)
        XCTAssertTrue(candidate.isLowConfidence)
        // 反过来：搜索分更高时取较低者（更保守）。
        XCTAssertEqual(
            MetadataCandidate.effectiveScore(searchScore: 0.9, lookupScore: 0.4),
            0.4,
            accuracy: 0.000_001
        )
    }

    func testExplicitEmptyTextIsWrittenAndInvalidArtworkIsRejected() async throws {
        // **清空文字 = 明确写空**（不是「当 nil 忽略」）。
        let payload = try MetadataSelection(fields: [.title: ""]).patch().payload()
        XCTAssertEqual(payload["title"] as? String, "")
        XCTAssertEqual(payload["removeArtwork"] as? Bool, false)
        // 数值留空 = 显式清零（写 0）。
        let numeric = try MetadataSelection(fields: [.track: ""]).patch().payload()
        XCTAssertEqual(numeric["track"] as? Int, 0)
        // 封面数据非法必须报错。
        XCTAssertThrowsError(
            try MetadataSelection(artworkBase64: "不是 base64 ***").patch()
        )
    }

    func testSelectionCarriesArtworkAndRemoveFlags() async throws {
        let payload = try MetadataSelection(artworkBase64: Data([0x01, 0x02]).base64EncodedString()).patch().payload()
        XCTAssertEqual(payload["artworkBase64"] as? String, Data([0x01, 0x02]).base64EncodedString())
        XCTAssertEqual(payload["removeArtwork"] as? Bool, false)

        let removal = try MetadataSelection(removeArtwork: true).patch().payload()
        XCTAssertEqual(removal["removeArtwork"] as? Bool, true)
        XCTAssertNil(removal["artworkBase64"])
    }

    // MARK: - 封面基线

    func testArtworkBaselineDistinguishesNotLoadedFromNoArtwork() {
        XCTAssertFalse(MetadataArtworkBaseline.notLoaded.isLoaded)
        XCTAssertTrue(MetadataArtworkBaseline.loaded(nil).isLoaded)
        XCTAssertNil(MetadataArtworkBaseline.loaded(nil).bytes)
        XCTAssertEqual(MetadataArtworkBaseline.loaded(Data([0x01])).bytes, Data([0x01]))
        XCTAssertNotEqual(MetadataArtworkBaseline.notLoaded, MetadataArtworkBaseline.loaded(nil))
    }
}
