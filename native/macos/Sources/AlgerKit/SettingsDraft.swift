import Foundation

/// 设置基线：**载入那一刻的真实会话值**。
///
/// dirty 只对照这个基线判断：
/// - 基线来自 **真实会话快照**（不是硬编码默认值）；
/// - 基线未知（会话未载入 / 载入失败）→ **不提交** 音质与音源，
///   绝不拿「higher / 空音源」当改动覆盖用户的真实设置；
/// - 会话在后台刷新时 **不覆盖** 用户正在编辑的值（基线只在第一次建立）。
public struct SettingsBaseline: Equatable {

    /// 音质。
    public var quality: String
    /// 音源（**保持优先顺序**）。
    public var sources: [String]
    /// 下载目录。
    public var downloadDirectory: String
    /// 基线是否 **已知**（false = 会话没载入成功）。
    public var isKnown: Bool

    public init(
        quality: String,
        sources: [String],
        downloadDirectory: String,
        isKnown: Bool
    ) {
        self.quality = quality
        self.sources = sources
        self.downloadDirectory = downloadDirectory
        self.isKnown = isKnown
    }

    /// 从真实会话快照建立基线。
    public init(snapshot: SessionSnapshot) {
        self.init(
            quality: snapshot.quality,
            sources: snapshot.sources,
            downloadDirectory: snapshot.downloadDirectory,
            isKnown: true
        )
    }

    /// 未知基线（会话没载入成功）。
    public static let unknown = SettingsBaseline(
        quality: "",
        sources: [],
        downloadDirectory: "",
        isKnown: false
    )
}

/// 一次保存真正要提交的改动（**只包含改动字段**）。
public struct SettingsChanges: Equatable {

    /// 音质（nil = 没改，不提交）。
    public var quality: String?
    /// 音源（nil = 没改，不提交）。
    public var sources: [String]?
    /// 下载目录（nil = 没改，不提交）。
    public var downloadDirectory: String?
    /// 拒绝提交的原因（例如目录被清空、基线未知）。
    public var rejection: String?

    /// 是否没有任何可提交内容。
    public var isEmpty: Bool {
        quality == nil && sources == nil && downloadDirectory == nil
    }
}

/// 设置改动计算（**可单测的纯逻辑**）。
public enum SettingsDraft {

    /// 计算相对基线的改动。
    ///
    /// - Parameters:
    ///   - baseline: 载入时的真实基线。
    ///   - quality: 当前界面上的音质。
    ///   - sources: 当前界面上的音源（有序）。
    ///   - downloadDirectory: 当前界面上的下载目录。
    public static func changes(
        baseline: SettingsBaseline,
        quality: String,
        sources: [String],
        downloadDirectory: String
    ) -> SettingsChanges {
        var changes = SettingsChanges()

        // 基线未知 → 音质 / 音源 **不提交**（避免用默认值覆盖真实设置）。
        if baseline.isKnown {
            if quality != baseline.quality {
                changes.quality = quality
            }
            if sources != baseline.sources {
                changes.sources = sources
            }
        } else {
            changes.rejection = "会话尚未载入，音质与音源未提交（避免覆盖未知基线）"
        }

        // 下载目录：清空不允许提交（会丢掉默认目录语义）。
        if downloadDirectory != baseline.downloadDirectory {
            if downloadDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if changes.rejection == nil {
                    changes.rejection = "下载目录不能为空，已保留原值"
                }
            } else {
                changes.downloadDirectory = downloadDirectory
            }
        }
        return changes
    }
}
