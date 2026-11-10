import AlgerKit
import SwiftUI
import AppKit

/// 秒 → `m:ss` / `h:mm:ss`。
func formatDuration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }
    let total = Int(seconds.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%d:%02d", minutes, secs)
}

/// 空状态（**不造假数据**：没有内容就说没有，并给出下一步动作）。
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 一行曲目（本地 / 网络通用）。
struct TrackRowView<Accessory: View>: View {
    let title: String
    let subtitle: String
    var trailingText: String?
    var isCurrent: Bool = false
    var onPlay: (() -> Void)?
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 12) {
            Button {
                onPlay?()
            } label: {
                Image(systemName: isCurrent ? "speaker.wave.2.fill" : "play.fill")
                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .disabled(onPlay == nil)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let trailingText {
                Text(trailingText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            accessory()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// 单击加入临时播放；右键或按住鼠标选择具体歌单。
///
/// **只含本地目标**：网络歌单是只读的，不能作为添加目标；
/// 网络曲目仍可加入 **临时播放** 与 **本地歌单**（先下载由 core 处理）。
struct AddToPlaylistMenu<Accessory: View>: View {
    @EnvironmentObject private var model: AppModel
    let result: SearchResult
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        NativeTrackAddButton(
            onClick: { model.enqueueResult(result) },
            makeMenu: {
                let menu = NSMenu()
                menu.addItem(TrackMenuItem("加入临时播放") { model.enqueueResult(result) })
                menu.addItem(.separator())
                let local = NSMenuItem(title: "本地歌单", action: nil, keyEquivalent: "")
                local.isEnabled = false
                menu.addItem(local)
                for playlist in model.localPlaylists {
                    menu.addItem(TrackMenuItem(playlist.title) {
                        Task { await model.addToLocalPlaylist(result, playlistId: playlist.id) }
                    })
                }
                return menu
            }
        )
        .frame(width: 28, height: 28)
        .help("加入临时播放；右键或长按选择歌单")
    }
}

private final class TrackMenuItem: NSMenuItem {
    let handler: () -> Void
    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    @objc private func invoke() { handler() }
}

private struct NativeTrackAddButton: NSViewRepresentable {
    var onClick: () -> Void
    var makeMenu: () -> NSMenu
    func makeNSView(context: Context) -> TrackAddControl {
        let button = TrackAddControl()
        button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "加入临时播放")
        button.isBordered = false
        button.bezelStyle = .inline
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel("加入临时播放")
        return button
    }
    func updateNSView(_ view: TrackAddControl, context: Context) {
        view.onClick = onClick
        view.makeMenu = makeMenu
    }
}

private final class TrackAddControl: NSButton {
    var onClick: (() -> Void)?
    var makeMenu: (() -> NSMenu)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(add)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    @objc private func add() { onClick?() }
    private func showMenu() {
        highlight(false)
        makeMenu?().popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY), in: self)
    }
    override func rightMouseDown(with event: NSEvent) { showMenu() }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return }
        highlight(true)
        defer { highlight(false) }
        // 使用标准 AppKit tracking run loop，长按只弹菜单，不再执行单击添加。
        let deadline = Date().addingTimeInterval(0.45)
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: deadline,
                                           inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp {
                if bounds.contains(convert(next.locationInWindow, from: nil)) { performClick(self) }
                return
            }
            let dx = next.locationInWindow.x - event.locationInWindow.x
            let dy = next.locationInWindow.y - event.locationInWindow.y
            if hypot(dx, dy) > 5 { return }
        }
        showMenu()
    }
}

/// 「更改添加目标」面板（**撤回这次默认添加后再加入新目标**）。
///
/// **只含本地目标**：临时播放、本地歌单、新建本地歌单。
struct AdditionTargetPickerSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("更改添加目标").font(.headline)
            if let receipt = model.lastAddition {
                Text("「\(receipt.title)」上一次加入：\(targetTitle(receipt.target))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            List {
                Section("临时播放") {
                    Button("加入临时播放（临时列表）") {
                        Task { await model.changeAdditionTarget(to: .queue) }
                        dismiss()
                    }
                }
                Section("本地歌单") {
                    if model.localPlaylists.isEmpty {
                        Text("还没有本地歌单")
                    } else {
                        ForEach(model.localPlaylists) { playlist in
                            Button(playlist.title) {
                                Task { await model.changeAdditionTarget(to: .localPlaylist(playlist.id)) }
                                dismiss()
                            }
                        }
                    }
                }
                Section("新建") {
                    Button("新建本地歌单") {
                        Task { await model.changeAdditionTarget(to: .newLocalPlaylist) }
                        dismiss()
                    }
                }
            }
            .frame(height: 280)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func targetTitle(_ target: AdditionTarget) -> String {
        switch target {
        case .queue: return "临时播放"
        case .localPlaylist(let id): return model.localPlaylists.first { $0.id == id }?.title ?? "本地歌单"
        case .newLocalPlaylist: return "新建歌单"
        }
    }
}

// MARK: - 播放顺序

/// 播放顺序按钮（顺序播放 ↔ 随机播放）。
///
/// - 点击调用 `model.togglePlaybackOrder()`：**切换与持久保存都由 AppModel 负责**
///   （下次启动仍是这个模式）；
/// - 标题直接显示 `model.playbackOrder.title`（顺序播放 / 随机播放），
///   一眼能看出当前模式；
/// - `help` 是悬浮提示；**无障碍标题就是模式名本身**（`AXTitle` = “顺序播放”），
///   点击后的效果放在 `AXValue` 里 —— 辅助功能与自动化都能稳定读到、能按到；
/// - **只显示图标**（`iconOnly`）：底部播放条最右侧用；歌单头部仍是图标 + 文字。
struct PlaybackOrderButton: View {
    @EnvironmentObject private var model: AppModel
    /// 只显示图标（**底部播放条**用；歌单头部继续图标 + 文字）。
    var iconOnly: Bool = false

    var body: some View {
        Button {
            model.togglePlaybackOrder()
        } label: {
            if iconOnly {
                // **只有图标**：无障碍标题仍由下面的 accessibilityLabel 提供。
                Label(model.playbackOrder.title, systemImage: symbolName)
                    .labelStyle(.iconOnly)
            } else {
                Label(model.playbackOrder.title, systemImage: symbolName)
            }
        }
        .buttonStyle(.plain)
        .pageActionLabel()
        .help(helpText)
        .accessibilityLabel(model.playbackOrder.title)
        .accessibilityValue(hintText)
    }

    private var isShuffle: Bool {
        model.playbackOrder == .shuffle
    }

    private var symbolName: String {
        isShuffle ? "shuffle" : "list.bullet"
    }

    /// 悬浮提示：当前模式 + 点击后变成什么。
    private var helpText: String {
        isShuffle ? "随机播放（点击切换为顺序播放）" : "顺序播放（点击切换为随机播放）"
    }

    /// 无障碍里读出的“点击后会发生什么”。
    private var hintText: String {
        isShuffle ? "点击切换为顺序播放" : "点击切换为随机播放"
    }
}

/// 顶部提示条。
struct BannerView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let banner = model.banner {
            HStack(spacing: 10) {
                Image(systemName: icon(for: banner.kind))
                    .foregroundStyle(color(for: banner.kind))
                Text(banner.text)
                    .font(.callout)
                    .lineLimit(3)
                Spacer()
                Button {
                    model.banner = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.4))
            .task(id: banner.id) {
                // 成功类提示 4 秒后自动消失；错误类保留到用户关闭。
                if banner.kind != .error {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if model.banner?.id == banner.id {
                        model.banner = nil
                    }
                }
            }
        }
    }

    private func icon(for kind: AppModel.Banner.Kind) -> String {
        switch kind {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
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

/// 分区标题（**正文小节**用；页面顶部标题用 `PageHeader`）。
struct SectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.title3.weight(.semibold))
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 顶部页面标题（各页共用）

/// 顶部页面标题（**所有页面共用同一套**：字体、20pt 横边距、上下边距、
/// 底部 Divider、右侧 action 对齐）。
///
/// - 标题字体统一为 `title2.semibold`，副标题统一为 `caption`；
/// - 横边距固定 20pt，上下边距固定；
/// - 底部一条 Divider，把标题区与正文分开；
/// - 右侧 `action` 与标题基线对齐（图标 + 文字的统一样式）。
struct PageHeader<Action: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var action: () -> Action

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder action: @escaping () -> Action
    ) {
        self.title = title
        self.subtitle = subtitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                action()
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 12)
            Divider()
        }
    }
}

/// 顶部标题栏右侧操作的统一外观（**SF Symbol + 文字**）。
///
/// 按钮与菜单共用同一套内边距、字号与底色 → 各页的操作看起来一致。
struct PageActionLabelStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.10))
            )
            .contentShape(Rectangle())
    }
}

extension View {
    /// 顶部标题栏右侧操作的统一外观（图标 + 文字）。
    func pageActionLabel() -> some View {
        modifier(PageActionLabelStyle())
    }

    /// 辅助功能标识（**可选**：不给就不设标识）。
    @ViewBuilder
    func axIdentifier(_ identifier: String?) -> some View {
        if let identifier {
            self.accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}

/// 顶部标题栏右侧的 **文字操作**（图标 + 文字，单击即执行）。
struct PageActionButton: View {
    let title: String
    let systemImage: String
    var isEnabled: Bool = true
    var help: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .pageActionLabel()
        .disabled(!isEnabled)
        .help(help ?? title)
        .accessibilityLabel(title)
    }
}

/// 顶部标题栏右侧的 **排序菜单**（各页共用同一套外观）。
struct PageSortMenu<Action: View>: View {
    let title: String
    @ViewBuilder var content: () -> Action

    init(title: String, @ViewBuilder content: @escaping () -> Action) {
        self.title = title
        self.content = content
    }

    var body: some View {
        Menu {
            content()
        } label: {
            Label(title, systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .pageActionLabel()
        .accessibilityLabel(title)
    }
}

/// 推荐雷达的 **状态区**（加载 / 错误 / 空结果 / 部分失败）——各页共用。
///
/// - 错误 **显示具体原因** 并给「重试」；
/// - 空结果 **区分原因**（没有种子 / 上游没有相似歌曲）。
struct RadarStatusView: View {
    let state: RadarState
    let onRetry: () -> Void

    var body: some View {
        if state.isLoading {
            ProgressView("正在找相似的歌曲…")
                .font(.callout)
                .padding(.vertical, 6)
        } else if let error = state.error {
            VStack(alignment: .leading, spacing: 6) {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                Button("重试", action: onRetry)
                    .buttonStyle(.link)
            }
        } else if let reason = state.emptyReason {
            Text(reason)
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if state.items.isEmpty {
            Text("暂时没有推荐")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if let warning = state.warning {
            Label(warning, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}
