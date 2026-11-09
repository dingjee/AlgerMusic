import AlgerKit
import SwiftUI

/// 悬浮提示（Toast）：**浮在内容之上，不占布局空间**。
///
/// 规则（产品规格）：
/// - **不占顶部布局空间**：用 `overlay` 承载，**不参与** VStack 排版，
///   因此出现 / 消失都 **不会让下面的内容跳动**（不跳高度）；
/// - **优雅浮动**：毛玻璃胶囊 + 轻描边 + 轻阴影，随系统浅深色与强调色变化；
/// - **成功类自动消失**，**错误类停留更久并可关闭**；
/// - **不遮挡播放条**：提示定位在内容区 **顶部**，播放条在底部，互不重叠；
/// - 提示内容直接来自 `AppModel.banner`（**不造数据**）。
struct ToastView: View {
    @EnvironmentObject private var model: AppModel

    /// 提示最多停留多久（秒）。**错误类停留更久**，方便看清原因。
    static func lifetime(for kind: AppModel.Banner.Kind) -> Double {
        switch kind {
        case .info: return 3.0
        case .warning: return 5.0
        // 错误：停留更久（但仍会自动消失，用户也可以手动关闭）。
        case .error: return 9.0
        }
    }

    var body: some View {
        if let banner = model.banner {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon(for: banner.kind))
                    .foregroundStyle(color(for: banner.kind))
                    .font(.callout)
                    .padding(.top, 1)

                Text(banner.text)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420, alignment: .leading)

                Button {
                    dismiss(banner.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("关闭提示")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
            .overlay {
                Capsule().strokeBorder(color(for: banner.kind).opacity(0.35), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.14), radius: 12, x: 0, y: 4)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, alignment: .center)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: banner.id) {
                // 自动消失：按类型区分停留时长；**期间出现新提示就换 id**，
                // 旧提示的计时随之取消，不会误关掉新提示。
                let seconds = Self.lifetime(for: banner.kind)
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                dismiss(banner.id)
            }
            .animation(.spring(response: 0.36, dampingFraction: 0.86), value: banner.id)
        }
    }

    /// 关闭提示（只关当前这一条）。
    private func dismiss(_ id: UUID) {
        if model.banner?.id == id {
            model.banner = nil
        }
    }

    private func icon(for kind: AppModel.Banner.Kind) -> String {
        switch kind {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private func color(for kind: AppModel.Banner.Kind) -> Color {
        switch kind {
        case .info: return .accentColor
        case .warning: return .orange
        case .error: return .red
        }
    }
}
