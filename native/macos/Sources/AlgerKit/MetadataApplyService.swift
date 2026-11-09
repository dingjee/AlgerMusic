import Foundation

// MARK: - 保存服务

/// 元信息写回服务（**保存前冲突检查 → 写入 → 写后重读核验**）。
///
/// 硬规则（E5）：
/// - **保存前重新读**：把「即将写入的字段」与「打开编辑器时的基线」逐项比较；
///   文件在这期间被别的程序改过 → **报冲突，不写**（绝不覆盖别人的改动）；
/// - **封面按字节比**：只看 `hasArtwork` 布尔 **不够**（旧图 A 换成 B 仍然是 true）；
///   改 / 删封面之前必须用 `tags.artwork` 的 **实际字节** 与基线比较；
///   写完之后同样用 **实际字节** 与写入的字节比较；
/// - **数值先验证再写**：曲序 / 碟序 / 年份 / 来源 ID 非法（不是整数 / 负数 / 超 `u32`）
///   在 **写入之前** 就报错，绝不「解析失败就丢掉这个字段」；
/// - **只写勾选的字段**：未勾选的字段不进补丁（`None` = 不改），
///   未选中的标签、未知标签与 **旧封面** 一律保留；
/// - **写后重新 `tags.read` 严格核验**：逐项比对被选字段；
///   核验不过 → **未能确认保存成功**（写入可能已经发生，**不断言原文件零改动**）；
/// - **不改音频路径**：只写标签，不重命名 / 不移动 / 不重编码音频。
public final class MetadataApplyService {
    /// 桥接封装。
    public let service: MetadataService

    public init(service: MetadataService) {
        self.service = service
    }

    // MARK: 写入

    /// 写入选中的字段。
    ///
    /// - Parameters:
    ///   - path: 音频文件路径（**只读标签，不移动文件**）。
    ///   - baseline: 打开编辑器时读到的标签（冲突比较的基线）。
    ///   - selection: 用户勾选的字段与封面。
    ///   - artworkBaseline: 打开编辑器时读到的内嵌封面字节（改 / 删封面时必需）。
    /// - Returns: **写后重新读取** 的标签（已逐项核验过）。
    @discardableResult
    public func apply(
        path: String,
        baseline: AudioTags,
        selection: MetadataSelection,
        artworkBaseline: MetadataArtworkBaseline = .notLoaded
    ) async throws -> AudioTags {
        guard !selection.isEmpty else {
            throw MetadataError.invalidSelection("没有勾选任何要写入的字段")
        }

        // 1) **先验证再写**：数值非法 / 文本为空 / 封面数据非法 → 写之前就报错。
        let patch = try selection.patch()

        // 2) 保存前重新读：相对基线检查冲突（含封面字节）。
        let current = try await service.readTags(path: path)
        try await checkConflict(
            path: path,
            baseline: baseline,
            current: current,
            selection: selection,
            artworkBaseline: artworkBaseline
        )

        // 3) 写入（**只写勾选的字段**；未勾选的标签与旧封面保持不变）。
        _ = try await service.writeTags(path: path, patch: patch)

        // 4) 写后重新读并严格核验（不信任写入返回值）。
        let verified = try await service.readTags(path: path)
        try await verify(path: path, tags: verified, selection: selection)
        return verified
    }

    /// 写入并返回 **写后真实重读** 生成的曲目记录。
    ///
    /// - Parameters:
    ///   - preservingSourceID: 索引里已有的来源关联（标签里可能没有这个 ID）。
    ///     用户 **没有** 显式勾选来源 ID 字段时保留它 —— 只改标题不能把来源关联清零。
    /// - Returns: 写后真实重读的记录；失败时 **不返回、不回调**。
    public func save(
        path: String,
        baseline: AudioTags,
        selection: MetadataSelection,
        artworkBaseline: MetadataArtworkBaseline = .notLoaded,
        preservingSourceID: Int64 = 0
    ) async throws -> TrackRecord {
        let verified = try await apply(
            path: path,
            baseline: baseline,
            selection: selection,
            artworkBaseline: artworkBaseline
        )
        var record = try makeTrackRecord(path: path, tags: verified)
        record.neteaseId = MetadataSourceID.merge(
            tagValue: verified.neteaseId,
            explicitlySelected: selection.fields.keys.contains(.neteaseId),
            original: preservingSourceID
        )
        return record
    }

    // MARK: 内部

    /// 冲突检查：被选字段的当前值必须与「打开时的基线」一致。
    private func checkConflict(
        path: String,
        baseline: AudioTags,
        current: AudioTags,
        selection: MetadataSelection,
        artworkBaseline: MetadataArtworkBaseline
    ) async throws {
        for field in selection.fields.keys {
            guard let baseValue = baseline.value(for: field),
                  let currentValue = current.value(for: field) else {
                // 读不到这个字段 → 无从比较（写后核验会兜住）。
                continue
            }
            if field.normalize(baseValue) != field.normalize(currentValue) {
                throw MetadataError.conflict(
                    "「\(field.title)」在打开编辑器后被改动（\(baseValue) → \(currentValue)），已取消写入"
                )
            }
        }

        // 封面：**按字节比**，布尔不足以发现「旧图换新图」。
        if selection.artworkBase64 != nil || selection.removeArtwork {
            guard artworkBaseline.isLoaded else {
                throw MetadataError.conflict(
                    "没有封面基线（打开编辑器时未读到内嵌封面），无法确认封面是否被改动，已取消写入"
                )
            }
            let currentBytes: Data?
            switch try await service.embeddedArtworkState(path: path, tags: current) {
            case .present(let data): currentBytes = data
            case .none: currentBytes = nil
            case .unreadable(let message):
                throw MetadataError.conflict("读取内嵌封面失败：\(message)，已取消写入")
            }
            if currentBytes != artworkBaseline.bytes {
                throw MetadataError.conflict("内嵌封面在打开编辑器后被改动，已取消写入")
            }
        }
    }

    /// 写后核验：被选字段必须与写入值一致；封面按 **实际字节** 比。
    private func verify(path: String, tags: AudioTags, selection: MetadataSelection) async throws {
        for (field, expected) in selection.fields {
            guard let actual = tags.value(for: field) else {
                throw MetadataError.verificationFailed(
                    "\(path)：写后重读没有返回字段「\(field.title)」，未能确认保存成功"
                )
            }
            if field.normalize(actual) != field.normalize(expected) {
                throw MetadataError.verificationFailed(
                    "\(path)：写后重读字段「\(field.title)」与写入值不一致（写入「\(expected)」，重读「\(actual)」），未能确认保存成功"
                )
            }
        }

        if let expectedBase64 = selection.artworkBase64 {
            guard let expected = Data(base64Encoded: expectedBase64) else {
                throw MetadataError.verificationFailed("\(path)：写入的封面数据无效，未能确认保存成功")
            }
            switch try await service.embeddedArtworkState(path: path, tags: tags) {
            case .present(let actual):
                if actual != expected {
                    throw MetadataError.verificationFailed(
                        "\(path)：写后重读的封面与写入的封面不一致，未能确认保存成功"
                    )
                }
            case .none:
                throw MetadataError.verificationFailed("\(path)：写后重读没有内嵌封面，未能确认保存成功")
            case .unreadable(let message):
                throw MetadataError.verificationFailed(
                    "\(path)：写后重读封面失败（\(message)），未能确认保存成功"
                )
            }
        }

        if selection.removeArtwork {
            switch try await service.embeddedArtworkState(path: path, tags: tags) {
            case .present:
                throw MetadataError.verificationFailed("\(path)：写后重读仍有内嵌封面，未能确认保存成功")
            case .none:
                break
            case .unreadable(let message):
                throw MetadataError.verificationFailed(
                    "\(path)：写后重读封面失败（\(message)），未能确认保存成功"
                )
            }
        }
    }

    /// 由 **写后真实重读** 的标签生成曲目记录。
    ///
    /// 只读文件属性（大小 / 修改时间），**不做整文件哈希**，也不改文件。
    private func makeTrackRecord(path: String, tags: AudioTags) throws -> TrackRecord {
        let url = URL(fileURLWithPath: path)
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? UInt64(max(0, tags.fileSize))
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let format = tags.format.isEmpty ? url.pathExtension.lowercased() : tags.format
        return TrackRecord(
            path: path,
            neteaseId: tags.neteaseId,
            title: tags.title,
            artist: tags.artist,
            album: tags.album,
            durationMs: UInt64(max(0, tags.durationMs)),
            format: format,
            size: size,
            modifiedAt: modified
        )
    }
}
