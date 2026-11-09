import AlgerKit
import ImageIO
import SwiftUI

/// 图片盒子：**`NSImage` 只有 macOS 14+ 才声明 `Sendable`**，而本应用最低支持
/// macOS 13。跨并发域传递时用这个不可变盒子包一层（`@unchecked` 由我们负责：
/// 盒子里的图片只被读取，不在并发路径上被改写）。
private struct ArtworkImage: @unchecked Sendable {
    let image: NSImage?
}

/// 图片解码（**后台线程**，不占主线程）。
///
/// 放在普通类型里而不是 `View` 里：`View` 的成员带主线程隔离，
/// 放到后台任务里调用会被编译器要求 `await`（解码就变成在主线程跑了）。
private enum ArtworkDecoder {
    /// 解码降采样上限（132pt @2x ≈ 264px，512px 富余且能挡住超大位图）。
    static let maxDecodedPixel = 512

    /// 在后台线程解码 + 降采样（主线程只等结果）。
    static func decodeInBackground(_ data: Data) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let box = await Task.detached(priority: .utility) {
            ArtworkImage(image: decode(data, maxPixel: maxDecodedPixel))
        }.value
        return box.image
    }

    /// 解码并降采样；解析失败回退 `NSImage(data:)`。
    static func decode(_ data: Data, maxPixel: Int) -> NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return NSImage(data: data)
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        if let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions) {
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        return NSImage(data: data)
    }
}

/// 首页封面。
///
/// 规则（产品规格）：
/// - **网络封面**：加载 `RemoteSong.album.picUrl` 指向的 **真实远程图**，不伪造；
///   **不走 `AsyncImage`**——真实探测证实网易云返回的 `picUrl` 全部是 `http://`
///   （`.artifacts/oc-feedback/probe/result.json`），而应用没有 ATS 例外，
///   明文 HTTP 会被系统全部拦截 → 用户实看封面全空。改用内部 loader：
///   - 对网易云 CDN 域（`music.126.net` 及其子域）做 **http→https 规范化**
///     （同一张真实图，CDN 支持 TLS）；其余 URL 原样加载；
///   - `URLSession.bytes(for:)` **流式下载**：先查 `Content-Length`，读取超过
///     10MiB 立即放弃（**不把无界响应缓冲进内存**）；HTTP 2xx 且非空才解码；
///   - 解码降采样到 512px（132pt @2x ≈ 264px 已富余），避免超大位图占内存；
///   - `NSCache`（带 cost）+ 进行中任务去重：同一封面只下载一次；
///     **失败不写缓存**，下次仍重试；
/// - **本地封面**：通过桥接 `tags.artwork` 取内嵌封面（协议已核对：`path` →
///   `{"base64": …}`），**只走一次桥接调用**（不先 `tags.read` 预读大文件）；
///   base64 / 图片解码都在后台完成；
/// - **本地缓存按文件 mtime + 大小 失效**（指纹进缓存键，文件变了即未命中），
///   用 **有界 NSCache** 存图，不做无界字典；
/// - **没有封面时**用占位图标（`music.note`），**不拿别的图冒充**；
/// - 跟随系统浅深色（用系统材质与 `secondary` 样式，不写死颜色）。
struct HomeArtwork: View {
    /// 封面来源。
    enum Source: Hashable {
        /// 网络封面地址（可为空 = 没有封面）。
        case remote(URL?)
        /// 本地文件（通过桥接读内嵌封面）。
        case local(path: String)
        /// 明确没有封面。
        case none

        /// 缓存键（同一个来源只触发一次加载）。
        var cacheKey: String {
            switch self {
            case .remote(let url): return "net:\(url?.absoluteString ?? "")"
            case .local(let path): return "local:\(path)"
            case .none: return "none"
            }
        }
    }

    /// 加载阶段（决定占位图是否变暗）。
    private enum Phase {
        case loading
        case loaded
        /// 无 URL / 加载失败 / 无内嵌封面 → 标准占位图。
        case placeholder
    }

    let source: Source
    /// 封面边长（点）。
    var size: CGFloat = 64
    /// 圆角（0 = 方形）。
    var cornerRadius: CGFloat = 8
    /// 桥接客户端（本地封面用；为 nil 时只用占位图）。
    var client: BridgeClient?

    @State private var remoteImage: NSImage?
    @State private var localImage: NSImage?
    @State private var phase: Phase = .loading

    var body: some View {
        content
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
            .task(id: source.cacheKey) {
                await loadArtwork()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch source {
        case .remote(let url):
            if let remoteImage {
                Image(nsImage: remoteImage)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder(dimmed: url != nil && phase == .loading)
            }
        case .local:
            if let localImage {
                Image(nsImage: localImage)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder(dimmed: phase == .loading)
            }
        case .none:
            placeholder()
        }
    }

    private func placeholder(dimmed: Bool = false) -> some View {
        ZStack {
            Rectangle()
                .fill(.quaternary.opacity(dimmed ? 0.5 : 0.35))
            Image(systemName: "music.note")
                .font(.system(size: size * 0.34, weight: .light))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 加载

    /// 按来源加载封面（网络 / 本地），结束时更新 `phase`。
    private func loadArtwork() async {
        switch source {
        case .remote(let url):
            remoteImage = nil
            guard let url else {
                phase = .placeholder
                return
            }
            phase = .loading
            let image = await RemoteArtworkLoader.shared.image(for: url)
            guard !Task.isCancelled else { return }
            remoteImage = image
            phase = image == nil ? .placeholder : .loaded
        case .local(let path):
            localImage = nil
            phase = .loading
            let image = await loadLocalArtwork(path: path)
            guard !Task.isCancelled else { return }
            localImage = image
            phase = image == nil ? .placeholder : .loaded
        case .none:
            phase = .placeholder
        }
    }

    /// 读取本地内嵌封面：**只调一次 `tags.artwork`**（不先 `tags.read`，避免重复
    /// 解析大文件），解码在后台完成，**不阻塞主线程**。
    ///
    /// - 缓存按 **mtime + 大小** 失效：指纹不一致（文件被改写）视为未命中；
    ///   读不到文件属性 → 不读缓存也不写缓存（宁可重读，也不给过期封面）；
    /// - **失败不写缓存**：桥接不可达 / 没有内嵌封面时保持占位图，下次仍会重试。
    private func loadLocalArtwork(path: String) async -> NSImage? {
        guard let client else { return nil }

        let stamp = Self.fileStamp(for: path)
        if let stamp, let cached = LocalArtworkCache.shared.image(for: path, stamp: stamp) {
            return cached
        }

        guard let dict = try? await client.callDictionary("tags.artwork", params: ["path": path]),
              let base64 = dict["base64"] as? String, !base64.isEmpty,
              let data = Data(base64Encoded: base64) else {
            return nil
        }
        guard let image = await ArtworkDecoder.decodeInBackground(data) else { return nil }
        if let stamp {
            LocalArtworkCache.shared.store(image, for: path, stamp: stamp)
        }
        return image
    }

    /// 文件指纹（mtime + 大小）：用来判断缓存是否过期。
    fileprivate static func fileStamp(for path: String) -> LocalArtworkCache.Stamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        return LocalArtworkCache.Stamp(modifiedAt: modified.timeIntervalSince1970, size: size.int64Value)
    }
}

/// 网络封面加载器（进程内共享：带 cost 的 NSCache + 进行中去重）。
///
/// 为什么不用 `AsyncImage`：网易云 `picUrl` 全是 `http://`（真实探测），应用没有
/// ATS 例外，`AsyncImage` 全部被拦截且无重试/去重控制；这里显式规范化到 https。
private final class RemoteArtworkLoader: @unchecked Sendable {
    static let shared = RemoteArtworkLoader()

    /// 单张封面字节上限（远大于正常封面，挡住异常大图 / 无限下载）。
    private static let maxBytes = 10 * 1024 * 1024
    /// NSCache cost：按最大解码位图字节数（512×512×4 ≈ 1MiB）计。
    private static let imageCost = ArtworkDecoder.maxDecodedPixel * ArtworkDecoder.maxDecodedPixel * 4

    private let session: URLSession
    private let cache = NSCache<NSString, NSImage>()
    private let lock = NSLock()
    /// 进行中的下载（同一 URL 并发请求只下载一次）。
    private var inflight: [String: Task<ArtworkImage?, Never>] = [:]

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
        cache.countLimit = 512
        cache.totalCostLimit = 128 * Self.imageCost
    }

    /// 锁区必须保持同步（锁内绝不 await）：统一走这个小 helper。
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// ATS：只有网易云 CDN 域把 http 规范化为 https（同一张真实图），
    /// 其余 URL 原样返回。域匹配按「等于 `music.126.net` 或以其子域结尾」判定，
    /// 防止 `…music.126.net` 字样被误配到别的 host。
    static func normalizedURL(for url: URL) -> URL {
        guard url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased(),
              host == "music.126.net" || host.hasSuffix(".music.126.net"),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.scheme = "https"
        return components.url ?? url
    }

    /// 取封面：缓存 → 进行中去重 → 流式下载解码。失败返回 nil（**不缓存失败**）。
    func image(for url: URL) async -> NSImage? {
        let requestURL = Self.normalizedURL(for: url)
        let key = requestURL.absoluteString
        if let hit = cache.object(forKey: key as NSString) { return hit }

        // 同步锁区内注册进行中任务；真正的 await 全部在锁外。
        let task: Task<ArtworkImage?, Never> = withLock {
            if let running = inflight[key] { return running }
            let session = session
            let created = Task.detached(priority: .utility) {
                await Self.fetchAndDecode(url: requestURL, session: session)
            }
            inflight[key] = created
            return created
        }

        let box = await task.value
        withLock { inflight[key] = nil }
        guard let image = box?.image else { return nil }
        cache.setObject(image, forKey: key as NSString, cost: Self.imageCost)
        return image
    }

    /// 流式下载（后台线程）：先看 `Content-Length`，再按字节读、超过上限立即放弃，
    /// **绝不把无界响应整体缓冲进内存**；2xx 且非空才解码。
    private static func fetchAndDecode(url: URL, session: URLSession) async -> ArtworkImage? {
        guard !Task.isCancelled else { return nil }
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        guard let (stream, response) = try? await session.bytes(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return nil
        }
        // Content-Length 预检（-1 = 未知，只能靠流式上限兜底）。
        let declared = http.expectedContentLength
        let limit = Int64(maxBytes)
        if declared > limit { return nil }

        var data = Data()
        // `expectedContentLength` 是 Int64，容量是 Int —— **显式安全转换**；
        // 未知长度（-1）按 0 处理，让 Data 自己增长。
        let expected = declared > 0 ? Int(clamping: declared) : 0
        data.reserveCapacity(min(maxBytes, expected))
        do {
            for try await byte in stream {
                if data.count >= maxBytes { return nil }
                data.append(byte)
            }
        } catch {
            return nil // 取消 / 连接中断：视为失败（不缓存，下次重试）。
        }
        if data.isEmpty { return nil }
        guard let image = await ArtworkDecoder.decodeInBackground(data) else { return nil }
        return ArtworkImage(image: image)
    }
}

/// 本地封面缓存（**有界 NSCache**，NSCache 自身线程安全）。
///
/// - **失败不缓存**：读不到封面时不做任何缓存，下次仍会尝试；
/// - **命中条件**：路径 + mtime + 大小 全部一致 —— 指纹直接编进缓存键，
///   文件被改写后旧键不再命中；条目可被 NSCache 回收，不做无界字典。
private final class LocalArtworkCache {
    /// 文件指纹。
    struct Stamp: Equatable {
        var modifiedAt: Double
        var size: Int64
    }

    static let shared = LocalArtworkCache()

    /// NSCache cost：按最大解码位图字节数（512×512×4 ≈ 1MiB）计。
    private static let imageCost = ArtworkDecoder.maxDecodedPixel * ArtworkDecoder.maxDecodedPixel * 4

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 512
        cache.totalCostLimit = 128 * Self.imageCost
    }

    private static func key(path: String, stamp: Stamp) -> NSString {
        "\(path)|mtime=\(stamp.modifiedAt)|size=\(stamp.size)" as NSString
    }

    /// 取缓存命中（路径 + mtime + 大小 必须全部一致）。
    func image(for path: String, stamp: Stamp) -> NSImage? {
        cache.object(forKey: Self.key(path: path, stamp: stamp))
    }

    func store(_ image: NSImage, for path: String, stamp: Stamp) {
        cache.setObject(image, forKey: Self.key(path: path, stamp: stamp), cost: Self.imageCost)
    }
}
