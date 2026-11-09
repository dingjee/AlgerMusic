import Foundation
import XCTest

@testable import AlgerKit

#if canImport(Darwin)
import Darwin
#endif

/// 数据目录覆盖（隔离运行）的回归。
final class AppPathsTests: XCTestCase {

    /// 显式空值 → 必须报错（**不回落真实 profile**）。
    func testEmptyOverrideIsRejected() {
        XCTAssertThrowsError(try AppPaths.validateDataDirectoryOverride(raw: "")) { error in
            guard let pathError = error as? AppPathsError else {
                return XCTFail("期望 AppPathsError，实际 \(error)")
            }
            XCTAssertTrue(pathError.description.contains("空值"), pathError.description)
        }
        XCTAssertThrowsError(try AppPaths.validateDataDirectoryOverride(raw: "   "))
    }

    /// 相对路径 → 必须报错（相对路径会随 cwd 漂移，可能误指真实 profile）。
    func testRelativeOverrideIsRejected() {
        for raw in ["relative/path", "./artifacts", "artifacts/x", "~/Music"] {
            XCTAssertThrowsError(try AppPaths.validateDataDirectoryOverride(raw: raw), raw) { error in
                guard let pathError = error as? AppPathsError else {
                    return XCTFail("期望 AppPathsError，实际 \(error)")
                }
                XCTAssertTrue(pathError.description.contains("绝对路径"), pathError.description)
            }
        }
    }

    /// 绝对路径 → 合法。
    func testAbsoluteOverrideIsAccepted() throws {
        XCTAssertNoThrow(try AppPaths.validateDataDirectoryOverride(raw: "/tmp/alger-isolated"))
        XCTAssertNoThrow(try AppPaths.validateDataDirectoryOverride(raw: nil))
    }

    /// 判绝对性必须看 **原始字符串**：`URL(fileURLWithPath:)` 永远给绝对路径。
    func testAbsoluteDetectionUsesRawString() {
        // 相对路径即使被拼成绝对路径，也必须被判定为非法。
        XCTAssertThrowsError(try AppPaths.validateDataDirectoryOverride(raw: "relative/path"))
        XCTAssertFalse("relative/path".hasPrefix("/"))
        XCTAssertTrue("/abs/path".hasPrefix("/"))
    }

    /// 环境变量确实生效（`getenv` 读到的是当前值）。
    func testEnvironmentOverrideIsReadLive() throws {
        let workspace = try TempWorkspace("paths-env")
        let isolated = workspace.root.appendingPathComponent("isolated", isDirectory: true)
        let restore = TestEnvironment.set(AppPaths.dataDirectoryEnvironmentKey, isolated.path)
        defer { restore() }

        XCTAssertEqual(AppPaths.dataDirectoryOverride, isolated.path)
        XCTAssertNoThrow(try AppPaths.validateDataDirectoryOverride())
        XCTAssertTrue(AppPaths.isIsolated)
        XCTAssertEqual(AppPaths.appSupportDir.standardizedFileURL, isolated.standardizedFileURL)
        XCTAssertTrue(AppPaths.isIsolatedDataDirectory(isolated))
    }

    /// 还原后不再是隔离运行。
    func testOverrideIsRestoredAfterTest() throws {
        let workspace = try TempWorkspace("paths-restore")
        let isolated = workspace.root.appendingPathComponent("isolated", isDirectory: true)
        let restore = TestEnvironment.set(AppPaths.dataDirectoryEnvironmentKey, isolated.path)
        XCTAssertTrue(AppPaths.isIsolated)
        restore()
        XCTAssertNil(AppPaths.dataDirectoryOverride, "结束后必须恢复原值")
        XCTAssertFalse(AppPaths.isIsolated)
    }

    /// 隔离运行时：歌单目录与音乐目录 **必须** 落在隔离目录内
    /// （Rust 新会话默认 `~/Music/AlgerMusic`，不能漏出去）。
    func testIsolatedDirectoriesStayInsideIsolatedRoot() throws {
        let workspace = try TempWorkspace("paths-isolated-dirs")
        let isolated = workspace.root.appendingPathComponent("isolated", isDirectory: true)
        let restore = TestEnvironment.set(AppPaths.dataDirectoryEnvironmentKey, isolated.path)
        defer { restore() }

        let playlists = AppPaths.defaultPlaylistsDir.standardizedFileURL.path
        let music = AppPaths.defaultMusicDir.standardizedFileURL.path
        XCTAssertTrue(playlists.hasPrefix(isolated.path), playlists)
        XCTAssertTrue(music.hasPrefix(isolated.path), music)
    }

    /// 普通 / 试用 profile（在 Application Support 下）**不算**隔离：
    /// 它们仍然使用用户真实的 `~/Music/AlgerMusic`。
    func testProfileDirectoriesAreNotConsideredIsolated() throws {
        XCTAssertFalse(AppPaths.isIsolatedDataDirectory(AppPaths.defaultAppSupportDir))
        let trial = AppPaths.applicationSupportBase
            .appendingPathComponent("AlgerMusicPlayer.trial", isDirectory: true)
        XCTAssertFalse(AppPaths.isIsolatedDataDirectory(trial))
        XCTAssertTrue(AppPaths.isIsolatedDataDirectory(URL(fileURLWithPath: "/tmp/alger-isolated")))
    }
}
