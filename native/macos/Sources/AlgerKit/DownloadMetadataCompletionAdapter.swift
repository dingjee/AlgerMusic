import Foundation

// MARK: - 元信息补全接缝

/// 元信息补全服务（**由元信息会话实现**：`MetadataCompletionService`）
/// 与下载流程之间的接缝。
///
/// 下载流程只依赖 `DownloadMetadataCompleting` 协议，
/// 因此测试可以注入假实现，**不会**碰真实网络。
extension MetadataCompletionService: DownloadMetadataCompleting {}

/// 下载流程的 **元信息补全** 工厂。
public enum DownloadMetadataCompletionFactory {
    /// 真实实现：元信息会话的 `MetadataCompletionService`
    /// （`completeDownloaded(path:source:)`：只补空字段 + 写后实读核验）。
    public static func make(client: BridgeClient) -> DownloadMetadataCompleting? {
        MetadataCompletionService(client: client)
    }
}
