import Foundation
import XCTest

@testable import AlgerKit

#if canImport(Darwin)
import Darwin
#endif

/// 真实桥接进程 + 隔离数据目录的回归。
@MainActor
final class AlgerEnvironmentTests: XCTestCase {

    /// 目录快照（路径 + 大小 + 修改时间），用于证明「真实 profile 没被碰」。
    private func snapshot(_ directory: URL) -> [String: String] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        ) else { return [:] }
        var result: [String: String] = [:]
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            result[url.path] = "\(size)-\(modified)"
        }
        return result
    }

    /// 隔离运行：会话、索引、应用状态、下载目录 **全部** 落在隔离目录内，
    /// 真实 profile 一个字节都不许被改。
    func testIsolatedEnvironmentStaysInsideIsolatedDirectory() async throws {
        let workspace = try TempWorkspace("env-isolated")
        let isolated = workspace.root.appendingPathComponent("isolated", isDirectory: true)

        let realProfile = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("AlgerMusicPlayer", isDirectory: true)
        let realBefore = snapshot(realProfile)
        let realExisted = FileManager.default.fileExists(atPath: realProfile.path)

        let environment = try AlgerEnvironment.make(
            dataDirectory: isolated,
            bridgeBinary: TestPaths.bridgeBinary
        )
        defer { environment.client.shutdown() }

        let notes = try await environment.applyDataDirectoryDefaults()
        XCTAssertFalse(notes.isEmpty, "隔离运行必须把下载目录改到隔离目录内")

        let snapshotValue = try await environment.bridge.sessionSnapshot()
        XCTAssertTrue(snapshotValue.sessionPath.hasPrefix(isolated.path), snapshotValue.sessionPath)
        XCTAssertTrue(
            snapshotValue.downloadDirectory.hasPrefix(isolated.path),
            "下载目录必须落在隔离目录内，实际：\(snapshotValue.downloadDirectory)"
        )
        XCTAssertFalse(snapshotValue.downloadDirectory.contains("/Music/AlgerMusic") && !isolated.path.contains("/Music/AlgerMusic"),
                       "隔离运行不得沿用 Rust 的 ~/Music/AlgerMusic 默认值")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotValue.sessionPath))

        // 应用状态与索引也在隔离目录内。
        XCTAssertTrue(environment.store.fileURL.path.hasPrefix(isolated.path))
        XCTAssertTrue(environment.index.fileURL.path.hasPrefix(isolated.path))

        // 真实 profile 不得被创建 / 改写。
        XCTAssertEqual(FileManager.default.fileExists(atPath: realProfile.path), realExisted)
        XCTAssertEqual(snapshot(realProfile), realBefore, "真实 profile 不得被改写")
    }

    /// 真实桥接：协议握手。
    func testBridgeHelloUsesRealBridgeBinary() async throws {
        let workspace = try TempWorkspace("env-hello")
        let isolated = workspace.root.appendingPathComponent("isolated", isDirectory: true)
        let environment = try AlgerEnvironment.make(
            dataDirectory: isolated,
            bridgeBinary: TestPaths.bridgeBinary
        )
        defer { environment.client.shutdown() }
        let response = try await environment.bridge.hello()
        XCTAssertEqual(JSONValue.int(response["protocol"]), 1)
        XCTAssertEqual(JSONValue.string(response["platform"]), "macos")
    }

    /// 会话路径必须是绝对路径：相对路径会让桥接 **拒绝启动**（不回落真实 profile）。
    func testRelativeSessionPathIsRefusedByBridge() async throws {
        let workspace = try TempWorkspace("env-relative")
        let relative = "relative-session.json"
        let client = try BridgeClient(
            executableURL: TestPaths.bridgeBinary,
            arguments: ["--session-path", relative]
        )
        defer { client.shutdown() }
        do {
            _ = try await client.callDictionary("app.hello", timeout: 10)
            XCTFail("相对会话路径必须被拒绝")
        } catch {
            // 期望：桥接启动即失败（退出码 2），客户端报「已结束 / 无法启动」。
            XCTAssertTrue(
                error is BridgeClient.ClientError || error is BridgeClient.BridgeError,
                "实际错误：\(error)"
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: relative),
            "桥接不得在当前目录创建相对会话文件"
        )
        _ = workspace
    }
}
