import Foundation

/// **只读**运行时身份（bundle 标识 / 数据目录 / trial 旗标）。
///
/// 用途：交付脚本在不启动应用、不启动桥接、不写任何 profile 的前提下，
/// 核验「这个二进制到底是谁、用哪个数据目录」。因此这里 **只做路径计算**，
/// 不创建目录、不读写会话或索引。
public enum RuntimeIdentity {

    /// 当前 bundle 标识（未打成 .app 时为空串）。
    public static var bundleIdentifier: String { Bundle.main.bundleIdentifier ?? "" }

    /// 当前生效的数据根目录（隔离覆盖优先，见 `AppPaths.appSupportDir`）。
    public static var dataDirectory: String { AppPaths.appSupportDir.path }

    /// 编译期 trial 旗标。
    public static var isTrial: Bool { AppPaths.isTrialBuild }

    /// 身份负载（键固定，便于脚本断言）。
    public static func payload(
        bundleIdentifier: String = RuntimeIdentity.bundleIdentifier,
        dataDirectory: String = RuntimeIdentity.dataDirectory,
        trial: Bool = RuntimeIdentity.isTrial
    ) -> [String: Any] {
        [
            "bundleIdentifier": bundleIdentifier,
            "dataDirectory": dataDirectory,
            "trial": trial
        ]
    }

    /// **单行 JSON**（键按字典序，稳定可比对）。
    public static func json(
        bundleIdentifier: String = RuntimeIdentity.bundleIdentifier,
        dataDirectory: String = RuntimeIdentity.dataDirectory,
        trial: Bool = RuntimeIdentity.isTrial
    ) -> String {
        let object = payload(
            bundleIdentifier: bundleIdentifier,
            dataDirectory: dataDirectory,
            trial: trial
        )
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        // 兜底：手写转义（理论上不会走到，但不能输出非法 JSON）。
        return "{\"bundleIdentifier\":\"\(escape(bundleIdentifier))\","
            + "\"dataDirectory\":\"\(escape(dataDirectory))\","
            + "\"trial\":\(trial ? "true" : "false")}"
    }

    private static func escape(_ value: String) -> String {
        var out = ""
        for character in value.unicodeScalars {
            switch character {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if character.value < 0x20 {
                    out += String(format: "\\u%04x", character.value)
                } else {
                    out.unicodeScalars.append(character)
                }
            }
        }
        return out
    }
}
