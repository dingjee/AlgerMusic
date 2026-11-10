import AlgerKit
import Foundation
import XCTest

/// FFIClient 宿主测试（macOS arm64 跑真实 staticlib，与 iOS 同一套 Rust 代码）。
final class FFIClientTests: XCTestCase {
    private func tempSessionPath(tag: String) -> String {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("alger-ios-test-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)-\(tag)")
            .appendingPathComponent("session.json")
            .standardizedFileURL.path
    }

    func testInitRejectsRelativePath() {
        XCTAssertThrowsError(try FFIClient(sessionPath: "relative/session.json")) { error in
            guard case FFIClientError.initFailed(let reason) = error else {
                return XCTFail("应为 initFailed，实际 \(error)")
            }
            XCTAssertTrue(reason.contains("绝对路径"), "实际：\(reason)")
        }
    }

    func testUnknownMethodThrowsUnsupported() async throws {
        let client = try FFIClient(sessionPath: tempSessionPath(tag: "unknown"))
        defer { client.shutdown() }
        do {
            _ = try await client.call("bogus.method")
            XCTFail("未知方法应抛错")
        } catch let FFIClientError.bridge(code, _) {
            XCTAssertEqual(code, "Unsupported")
        }
    }

    /// 公开热门歌单：匿名可用；上游不可达时只接受 Network 错误
    /// （与 crates 侧只读探测同一语义）。
    func testTopPlaylistsAnonymous() async throws {
        let client = try FFIClient(sessionPath: tempSessionPath(tag: "toplists"))
        defer { client.shutdown() }
        do {
            let r = try await client.call("net.topPlaylists", params: ["limit": 3, "offset": 0])
            guard let dict = r as? [String: Any], dict["playlists"] is [Any] else {
                return XCTFail("成功响应应带 playlists 数组：\(r)")
            }
        } catch let FFIClientError.bridge(code, _) {
            XCTAssertEqual(code, "Network", "匿名公开歌单只应因网络失败：\(code)")
        }
    }

    /// shutdown 立即失败在途调用（.closed），且 Rust 侧不崩溃、不泄漏续体。
    func testShutdownFailsPendingCalls() async throws {
        setenv("ALGER_BRIDGE_TEST_HOOKS", "1", 1)
        // 有界等待压短：确定性走「超时回 ShuttingDown + 中止任务」路径。
        setenv("ALGER_FFI_EXIT_WAIT_MS", "500", 1)
        let client = try FFIClient(sessionPath: tempSessionPath(tag: "shutdown"))
        do {
            async let slow: Any = client.call("test.slow", params: ["ms": 10_000])
            try await Task.sleep(nanoseconds: 100_000_000) // 等请求真正入队
            client.shutdown()
            _ = try await slow
            XCTFail("关闭后慢调用应抛错")
        } catch FFIClientError.closed {
            // 预期
        }
        XCTAssertEqual(client.pendingCount, 0)
    }

    /// 事件回调：用 test.dlEnqueue 走真实下载事件太重组件；这里验证
    /// 注册/移除不崩溃，行解析路径已被响应测试覆盖。
    func testEventHandlerRegistration() throws {
        let client = try FFIClient(sessionPath: tempSessionPath(tag: "events"))
        defer { client.shutdown() }
        client.onEvent { _, _ in }
    }
}
