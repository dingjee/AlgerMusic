import Foundation
import XCTest

@testable import AlgerKit

/// 假桥接（**真实子进程** + JSON 行协议 + 罐装响应）。
///
/// 用途：
/// - 不依赖网络与真实桥接实现，**精确控制**每个请求的返回
///   （成功 / 业务错误 / 慢响应）；
/// - 记录收到的 **请求行**（用来断言方法名与参数）。
///
/// 响应按请求顺序消费：第 N 个请求拿到 `resp-NNN.json`；
/// 没有对应罐装响应时回一个业务错误（不会静默挂住）。
final class FakeMetadataBridge {
    let workspace: TempWorkspace
    let directory: URL
    let scriptURL: URL
    private var counter = 0

    init(label: String = "fake-metadata-bridge") throws {
        workspace = try TempWorkspace(label)
        directory = workspace.root
        scriptURL = try workspace.writeScript(
            FakeMetadataBridge.script(directory: directory),
            named: "fake-bridge.sh"
        )
    }

    /// 假桥接脚本（`__ID__` 会被替换成请求 id）。
    private static func script(directory: URL) -> String {
        """
        #!/bin/sh
        DIR="\(directory.path)"
        COUNTER="$DIR/counter"
        while IFS= read -r line; do
          printf '%s\\n' "$line" >> "$DIR/requests.log"
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
          case "$line" in
            *'"m":"app.shutdown"'*)
              printf '{"id":%s,"ok":true,"r":{"bye":true}}\\n' "$id"
              exit 0
              ;;
          esac
          n=$(cat "$COUNTER" 2>/dev/null || echo 0)
          n=$((n + 1))
          printf '%s' "$n" > "$COUNTER"
          if [ -f "$DIR/slow-$n" ]; then
            sleep 3
          fi
          f=$(printf '%s/resp-%03d.json' "$DIR" "$n")
          if [ -f "$f" ]; then
            sed "s/__ID__/$id/g" "$f"
          else
            printf '{"id":%s,"ok":false,"e":{"code":"Unsupported","message":"\\u6ca1\\u6709\\u7f50\\u88c5\\u54cd\\u5e94"}}\n' "$id"
          fi
        done
        """
    }

    // MARK: - 罐装响应

    /// 追加一个成功响应（`r` 的内容是 JSON 文本）。
    @discardableResult
    func enqueueSuccess(_ payload: String) throws -> Int {
        counter += 1
        try workspace.write(
            "{\"id\":__ID__,\"ok\":true,\"r\":\(payload)}\n",
            to: responseName(counter)
        )
        return counter
    }

    /// 追加一个成功响应（`r` 是对象）。
    @discardableResult
    func enqueueSuccess(_ payload: [String: Any]) throws -> Int {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return try enqueueSuccess(String(decoding: data, as: UTF8.self))
    }

    /// 追加一个业务错误响应。
    @discardableResult
    func enqueueError(code: String = "Business", message: String = "匹配服务不可用") throws -> Int {
        counter += 1
        let escaped = message.replacingOccurrences(of: "\"", with: "\\\"")
        try workspace.write(
            "{\"id\":__ID__,\"ok\":false,\"e\":{\"code\":\"\(code)\",\"message\":\"\(escaped)\"}}\n",
            to: responseName(counter)
        )
        return counter
    }

    /// 让第 N 个请求变慢（用来测取消）。
    func markSlow(_ index: Int) throws {
        try workspace.write("slow\n", to: "slow-\(index)")
    }

    private func responseName(_ index: Int) -> String {
        String(format: "resp-%03d.json", index)
    }

    // MARK: - 观察

    /// 收到的请求行（按顺序）。
    func requestLines() -> [String] {
        let url = directory.appendingPathComponent("requests.log")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    /// 收到的请求（解析成对象）。
    func requests() -> [[String: Any]] {
        requestLines().compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }

    /// 收到的方法名（按顺序）。
    func methods() -> [String] {
        requests().compactMap { $0["m"] as? String }
    }

    // MARK: - 客户端

    /// 起一个连到假桥接的客户端。
    func makeClient() throws -> BridgeClient {
        try BridgeClient(executableURL: scriptURL)
    }
}

/// 元信息服务回归（E5）。
///
/// 覆盖：桥接方法名与参数、返回解析、错误可见、取消通知。
final class MetadataServiceTests: XCTestCase {

    private func makeService(_ bridge: FakeMetadataBridge) throws -> (MetadataService, BridgeClient) {
        let client = try bridge.makeClient()
        return (MetadataService(client: client), client)
    }

    // MARK: - 搜索

    func testSearchParsesCandidatesAndSendsContractParams() async throws {
        let bridge = try FakeMetadataBridge()
        try bridge.enqueueSuccess([
            "candidates": [[
                "recordingId": "rec-1",
                "title": "Song",
                "artist": "Artist",
                "durationMs": 201000,
                "score": 88,
                "isrcs": ["USRC17607839"],
                "releases": [["id": "rel-1", "title": "Album"]],
            ]],
        ])
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        let candidates = try await service.search(
            title: "Song",
            artist: "Artist",
            durationMs: 201000,
            limit: 5,
            token: "tok-1"
        )
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.recordingId, "rec-1")
        // 后端 0…100 → 本地 0…1。
        XCTAssertEqual(candidates.first?.score ?? 0, 0.88, accuracy: 0.000_001)
        XCTAssertEqual(candidates.first?.isrcs, ["USRC17607839"])
        XCTAssertEqual(candidates.first?.releases.first?.id, "rel-1")

        // 请求方法名与参数必须符合契约。
        XCTAssertEqual(bridge.methods(), ["meta.search"])
        let params = bridge.requests().first?["p"] as? [String: Any]
        XCTAssertEqual(params?["title"] as? String, "Song")
        XCTAssertEqual(params?["artist"] as? String, "Artist")
        XCTAssertEqual(params?["durationMs"] as? Int, 201000)
        XCTAssertEqual(params?["limit"] as? Int, 5)
        XCTAssertEqual(params?["token"] as? String, "tok-1")
    }

    func testSearchSurfacesBridgeError() async throws {
        let bridge = try FakeMetadataBridge()
        try bridge.enqueueError(code: "Network", message: "MusicBrainz 不可达")
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        do {
            _ = try await service.search(title: "Song", artist: "Artist")
            XCTFail("桥接错误必须抛出来")
        } catch let error as BridgeClient.BridgeError {
            XCTAssertEqual(error.code, "Network")
            XCTAssertTrue(error.message.contains("不可达"))
        }
    }

    func testSearchRejectsUnparsableCandidate() async throws {
        let bridge = try FakeMetadataBridge()
        try bridge.enqueueSuccess(["candidates": [["title": "没有录音 ID"]]])
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        do {
            _ = try await service.search(title: "Song", artist: "Artist")
            XCTFail("无法解析的候选必须报错")
        } catch let error as MetadataError {
            guard case .invalidResponse = error else {
                return XCTFail("应为 invalidResponse，实际：\(error)")
            }
        }
    }

    // MARK: - 录音 / 发行 / 封面

    func testLookupReturnsCandidate() async throws {
        let bridge = try FakeMetadataBridge()
        try bridge.enqueueSuccess([
            "candidate": [
                "recordingId": "rec-9",
                "title": "Song",
                "artist": "Artist",
                "durationMs": 1000,
                "score": 100,
            ],
        ])
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        let candidate = try await service.lookup(recordingId: "rec-9", token: "tok-2")
        XCTAssertEqual(candidate.recordingId, "rec-9")
        XCTAssertEqual(candidate.score, 1.0, accuracy: 0.000_001)
        XCTAssertEqual(bridge.methods(), ["meta.lookup"])
        XCTAssertEqual((bridge.requests().first?["p"] as? [String: Any])?["recordingId"] as? String, "rec-9")
    }

    func testReleaseReturnsReleaseAndTracks() async throws {
        let bridge = try FakeMetadataBridge()
        try bridge.enqueueSuccess([
            "release": [
                "id": "rel-1",
                "title": "Album",
                "date": "2019-05-01",
                "country": "GB",
                "albumArtist": "AA",
            ],
            "tracks": [[
                "recordingId": "rec-1",
                "title": "Song",
                "artist": "Artist",
                "track": 3,
                "disc": 1,
                "durationMs": 1000,
            ]],
        ])
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        let detail = try await service.release(releaseId: "rel-1", recordingId: "rec-1")
        XCTAssertEqual(detail.release.id, "rel-1")
        XCTAssertEqual(detail.release.date, "2019-05-01")
        XCTAssertEqual(detail.tracks.count, 1)
        XCTAssertEqual(detail.tracks.first?.track, 3)
        XCTAssertEqual(detail.tracks.first?.disc, 1)

        let params = bridge.requests().first?["p"] as? [String: Any]
        XCTAssertEqual(params?["releaseId"] as? String, "rel-1")
        XCTAssertEqual(params?["recordingId"] as? String, "rec-1")
    }

    func testArtworkDecodesBytes() async throws {
        let bridge = try FakeMetadataBridge()
        let payload = Data([0xFF, 0xD8, 0xFF, 0xE0]).base64EncodedString()
        try bridge.enqueueSuccess([
            "artworkBase64": payload,
            "mimeType": "image/jpeg",
            "releaseId": "rel-1",
        ])
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        let artwork = try await service.artwork(releaseId: "rel-1", token: "tok-3")
        XCTAssertEqual(artwork.data, Data([0xFF, 0xD8, 0xFF, 0xE0]))
        XCTAssertEqual(artwork.mimeType, "image/jpeg")
        XCTAssertEqual(artwork.releaseId, "rel-1")
        XCTAssertEqual(bridge.methods(), ["meta.artwork"])
    }

    func testArtworkWithoutDataIsInvalidResponse() async throws {
        let bridge = try FakeMetadataBridge()
        try bridge.enqueueSuccess(["artworkBase64": "", "mimeType": "image/jpeg"])
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        do {
            _ = try await service.artwork(releaseId: "rel-1")
            XCTFail("空封面必须报错")
        } catch let error as MetadataError {
            guard case .invalidResponse = error else {
                return XCTFail("应为 invalidResponse，实际：\(error)")
            }
        }
    }

    // MARK: - 指纹

    func testFingerprintRequiresAPIKeyWithoutCallingBridge() async throws {
        let bridge = try FakeMetadataBridge()
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        do {
            _ = try await service.fingerprint(path: "/tmp/a.mp3", apiKey: "   ")
            XCTFail("缺 key 必须报错")
        } catch let error as MetadataError {
            guard case .missingConfiguration = error else {
                return XCTFail("应为 missingConfiguration，实际：\(error)")
            }
        }
        // 缺配置时 **不能** 发请求（更不能假成功）。
        XCTAssertTrue(bridge.methods().isEmpty)
    }

    func testFingerprintSendsPathKeyAndTool() async throws {
        let bridge = try FakeMetadataBridge()
        try bridge.enqueueSuccess(["candidates": [["recordingId": "rec-1", "score": 95]]])
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        let candidates = try await service.fingerprint(
            path: "/tmp/a.mp3",
            apiKey: "key-1",
            fpcalcPath: "/opt/homebrew/bin/fpcalc",
            token: "tok-4"
        )
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.score ?? 0, 0.95, accuracy: 0.000_001)
        let params = bridge.requests().first?["p"] as? [String: Any]
        XCTAssertEqual(params?["path"] as? String, "/tmp/a.mp3")
        XCTAssertEqual(params?["apiKey"] as? String, "key-1")
        XCTAssertEqual(params?["fpcalcPath"] as? String, "/opt/homebrew/bin/fpcalc")
        XCTAssertEqual(params?["token"] as? String, "tok-4")
    }

    // MARK: - 取消

    func testCancelSendsToken() async throws {
        let bridge = try FakeMetadataBridge()
        try bridge.enqueueSuccess(["cancelled": true])
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        let cancelled = try await service.cancel(token: "tok-5")
        XCTAssertTrue(cancelled)
        XCTAssertEqual(bridge.methods(), ["meta.cancel"])
        XCTAssertEqual((bridge.requests().first?["p"] as? [String: Any])?["token"] as? String, "tok-5")
    }

    func testCancelledTaskNotifiesServerWithMetaCancel() async throws {
        let bridge = try FakeMetadataBridge()
        try bridge.enqueueSuccess(["candidates": []])
        try bridge.markSlow(1)               // 第一个请求（search）变慢
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        let task = Task {
            try await service.search(title: "Song", artist: "Artist", token: "tok-6")
        }
        // 等请求真的发出去再取消。
        let sent = await waitUntil(timeout: 3) { !bridge.requestLines().isEmpty }
        XCTAssertTrue(sent)
        task.cancel()

        // 取消后服务端必须收到 `meta.cancel`（本地 Task 取消 → 补发通知）。
        let notified = await waitUntil(timeout: 5) {
            bridge.methods().contains("meta.cancel")
        }
        XCTAssertTrue(notified, "取消后必须补发 meta.cancel")
        let cancelParams = (bridge.requests()
            .first { $0["m"] as? String == "meta.cancel" }?["p"] as? [String: Any])
        XCTAssertEqual(cancelParams?["token"] as? String, "tok-6")
    }

    // MARK: - 标签读写

    func testReadTagsAndWriteTagsUseContractShape() async throws {
        let bridge = try FakeMetadataBridge()
        try bridge.enqueueSuccess([
            "path": "/tmp/a.mp3",
            "format": "mp3",
            "durationMs": 1000,
            "title": "旧标题",
            "artist": "艺人",
            "hasArtwork": false,
            "fileSize": 10,
            "neteaseId": 0,
        ])
        try bridge.enqueueSuccess([
            "path": "/tmp/a.mp3",
            "format": "mp3",
            "durationMs": 1000,
            "title": "新标题",
            "artist": "艺人",
            "hasArtwork": false,
            "fileSize": 10,
            "neteaseId": 0,
        ])
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        let tags = try await service.readTags(path: "/tmp/a.mp3")
        XCTAssertEqual(tags.title, "旧标题")

        let written = try await service.writeTags(
            path: "/tmp/a.mp3",
            patch: MetadataTagPatch(title: "新标题")
        )
        XCTAssertEqual(written.title, "新标题")

        XCTAssertEqual(bridge.methods(), ["tags.read", "tags.write"])
        let writeParams = bridge.requests()[1]["p"] as? [String: Any]
        XCTAssertEqual(writeParams?["path"] as? String, "/tmp/a.mp3")
        let patch = writeParams?["patch"] as? [String: Any]
        XCTAssertEqual(patch?["title"] as? String, "新标题")
        // `removeArtwork` 非可选：必须出现。
        XCTAssertEqual(patch?["removeArtwork"] as? Bool, false)
    }

    func testEmbeddedArtworkStateDistinguishesNoneFromUnreadable() async throws {
        let bridge = try FakeMetadataBridge()
        // 没有封面：tags.read 说 hasArtwork=false → 不再请求 tags.artwork。
        try bridge.enqueueSuccess(["path": "/tmp/a.mp3", "hasArtwork": false])
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        let state = try await service.embeddedArtworkState(path: "/tmp/a.mp3")
        XCTAssertEqual(state, .none)
        XCTAssertEqual(bridge.methods(), ["tags.read"])
    }

    func testEmbeddedArtworkStateReturnsBytes() async throws {
        let bridge = try FakeMetadataBridge()
        try bridge.enqueueSuccess(["path": "/tmp/a.mp3", "hasArtwork": true])
        try bridge.enqueueSuccess(["base64": Data([0x01, 0x02, 0x03]).base64EncodedString()])
        let (service, client) = try makeService(bridge)
        defer { client.shutdown() }

        let state = try await service.embeddedArtworkState(path: "/tmp/a.mp3")
        XCTAssertEqual(state, .present(Data([0x01, 0x02, 0x03])))
        XCTAssertEqual(bridge.methods(), ["tags.read", "tags.artwork"])
    }
}
