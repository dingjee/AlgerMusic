import Foundation
import XCTest

@testable import AlgerKit

/// 运行时身份（`--print-runtime-identity`）回归。
final class RuntimeIdentityTests: XCTestCase {

    /// JSON 形状固定（键固定、值真实）。
    func testJSONShapeIsStable() throws {
        let json = RuntimeIdentity.json(
            bundleIdentifier: "com.alger.music.trial",
            dataDirectory: "/tmp/alger-data",
            trial: true
        )
        XCTAssertFalse(json.contains("\n"), "输出必须是单行 JSON")
        let data = try XCTUnwrap(json.data(using: .utf8))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["bundleIdentifier", "dataDirectory", "trial"])
        XCTAssertEqual(object["bundleIdentifier"] as? String, "com.alger.music.trial")
        XCTAssertEqual(object["dataDirectory"] as? String, "/tmp/alger-data")
        XCTAssertEqual(object["trial"] as? Bool, true)
    }

    /// trial 旗标与 `AppPaths.isTrialBuild` 一致（编译期决定）。
    func testTrialFlagMatchesAppPaths() {
        XCTAssertEqual(RuntimeIdentity.isTrial, AppPaths.isTrialBuild)
        let json = RuntimeIdentity.json()
        XCTAssertTrue(json.contains("\"trial\":\(AppPaths.isTrialBuild)"))
    }

    /// 数据目录与 `AppPaths.appSupportDir` 一致（只读，不创建目录）。
    func testDataDirectoryMatchesAppPaths() {
        XCTAssertEqual(RuntimeIdentity.dataDirectory, AppPaths.appSupportDir.path)
    }
}
