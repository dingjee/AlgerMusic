import AlgerKit
import SwiftUI
import AppKit

/// 设置：**随改随存**（macOS 习惯），**没有「保存」按钮**。
///
/// 关键约定：
/// - **控件 / 目录改完立刻保存**，**文本**输入做防抖（停顿 / 回车 / 失焦提交）；
/// - 保存 **串行合并**：快速改动会合并，旧请求不会覆盖新值；
/// - **只提交改动字段**（没改音质就不提交音质），不发送整份过期快照；
/// - **载入不触发保存**；会话基线未知时 **不提交** 音质 / 音源（不覆盖真实设置）；
/// - 保存失败 **明确显示原因并可重试**，绝不假装成功。
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    /// 自动保存协调器（**唯一写设置的入口**）。
    @StateObject private var coordinator = SettingsAutoSaveCoordinator()
    /// 文本框焦点（失焦即提交）。
    @FocusState private var focusedField: TextFieldKind?

    private enum TextFieldKind: Hashable {
        case download
        case playlists
    }

    private let qualityOptions = [
        ("standard", "标准"),
        ("higher", "较高"),
        ("exhigh", "极高"),
        ("lossless", "无损"),
    ]

    private let sourceOptions = [
        ("pyncmd", "GD 音乐台（网易直连）"),
        ("gdmusic", "GD 音乐台（多平台）"),
        ("kugou", "酷狗"),
        ("kuwo", "酷我"),
        ("migu", "咪咕"),
    ]

    var body: some View {
        Form {
            Section("账号") {
                if model.isLoggedIn {
                    LabeledContent("昵称", value: model.account?.nickname ?? "未知")
                    LabeledContent("用户 ID", value: "\(model.account?.userId ?? 0)")
                    Button("退出登录") {
                        Task { await model.logout() }
                    }
                } else {
                    Text("未登录网易云")
                        .foregroundStyle(.secondary)
                    Button("打开登录窗口") {
                        model.openLoginWindow()
                    }
                }
                if let issue = model.sessionIssue {
                    Text(issue)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("播放") {
                Picker("音质", selection: qualityBinding) {
                    ForEach(qualityOptions, id: \.0) { option in
                        Text(option.1).tag(option.0)
                    }
                }
                .disabled(!coordinator.isSessionBaselineKnown)
                Text("第三方音源（官方地址不可用时回退）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(sourceOptions, id: \.0) { option in
                    Toggle(option.1, isOn: sourceBinding(option.0))
                        .disabled(!coordinator.isSessionBaselineKnown)
                }
                if !coordinator.isSessionBaselineKnown {
                    Label(
                        "会话尚未载入，音质与音源暂不可修改（避免覆盖未知基线）。",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else if !coordinator.values.sources.isEmpty {
                    Text("当前顺序：\(coordinator.values.sources.map { label(for: $0) }.joined(separator: " → "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("目录") {
                LabeledContent("下载目录") {
                    HStack {
                        TextField("下载目录", text: downloadDirectoryBinding)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .download)
                            .onSubmit { coordinator.commitPendingText() }
                        Button("选择…") { chooseDirectory(kind: .download) }
                    }
                }
                LabeledContent("歌单目录") {
                    HStack {
                        TextField("歌单目录", text: playlistsDirectoryBinding)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .playlists)
                            .onSubmit { coordinator.commitPendingText() }
                        Button("选择…") { chooseDirectory(kind: .playlists) }
                    }
                }
                LabeledContent("音乐目录") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(coordinator.values.libraryFolders, id: \.self) { folder in
                            Text(folder).font(.caption)
                        }
                        HStack {
                            Button("添加目录…") { chooseDirectory(kind: .library) }
                            Button("移除全部") { coordinator.setLibraryFolders([]) }
                        }
                    }
                }
            }

            Section("自动保存") {
                Toggle("完整在线播放后自动保存", isOn: autoSaveEnabledBinding)
                Stepper(
                    "阈值：\(coordinator.values.autoSaveThreshold) 次",
                    value: autoSaveThresholdBinding,
                    in: 1...20
                )
                Text("只统计真实完整播完的网络曲目；跳过、拖进度到结尾、本地播放都不计数。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !model.autoSavePending.isEmpty {
                    Label("有 \(model.autoSavePending.count) 首自动保存失败，待重试", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("歌单") {
                Toggle("隐藏网络歌单分组", isOn: hideRemotePlaylistsBinding)
            }

            Section("保存状态") {
                saveStatus
            }
        }
        .formStyle(.grouped)
        .task {
            coordinator.attach(persistence: EnvironmentSettingsPersistence(environment: model.environment))
            coordinator.onSaved = { summary in
                if summary.nativeApplied {
                    // 本地侧设置（音乐目录 / 自动保存 / 隐藏网络歌单分组）已落盘：
                    // 刷新本地状态，界面（侧栏分组等）才会 **重新读** `store.current`，
                    // 否则改了开关侧栏仍显示旧分组。
                    model.refreshLibrary()
                }
                if summary.sessionApplied {
                    // 保存后重新读会话，确保界面显示的是 **真实落盘** 的值。
                    Task { await model.refreshSession() }
                }
            }
            prime()
        }
        .onChange(of: model.sessionSnapshot?.quality) { _ in prime() }
        .onChange(of: model.sessionSnapshot?.sources) { _ in prime() }
        .onChange(of: model.sessionSnapshot?.downloadDirectory) { _ in prime() }
        .onChange(of: focusedField) { _ in coordinator.commitPendingText() }
        .onDisappear { coordinator.flush() }
    }

    // MARK: - 绑定

    private var qualityBinding: Binding<String> {
        Binding(
            get: { coordinator.values.quality },
            set: { coordinator.setQuality($0) }
        )
    }

    private func sourceBinding(_ source: String) -> Binding<Bool> {
        Binding(
            get: { coordinator.values.sources.contains(source) },
            set: { enabled in
                var sources = coordinator.values.sources
                if enabled {
                    // 保持 **优先顺序**：新勾选的排到末尾。
                    if !sources.contains(source) { sources.append(source) }
                } else {
                    sources.removeAll { $0 == source }
                }
                coordinator.setSources(sources)
            }
        )
    }

    /// 下载目录：文本输入 **防抖** 保存（停顿 / 回车 / 失焦提交）。
    private var downloadDirectoryBinding: Binding<String> {
        Binding(
            get: { coordinator.values.downloadDirectory },
            set: { coordinator.setDownloadDirectory($0, urgency: .debounced) }
        )
    }

    /// 歌单目录：文本输入 **防抖** 保存。
    private var playlistsDirectoryBinding: Binding<String> {
        Binding(
            get: { coordinator.values.playlistsDirectory },
            set: { coordinator.setPlaylistsDirectory($0, urgency: .debounced) }
        )
    }

    private var autoSaveEnabledBinding: Binding<Bool> {
        Binding(
            get: { coordinator.values.autoSaveEnabled },
            set: { coordinator.setAutoSaveEnabled($0) }
        )
    }

    private var autoSaveThresholdBinding: Binding<Int> {
        Binding(
            get: { coordinator.values.autoSaveThreshold },
            set: { coordinator.setAutoSaveThreshold($0) }
        )
    }

    private var hideRemotePlaylistsBinding: Binding<Bool> {
        Binding(
            get: { coordinator.values.hideRemotePlaylists },
            set: { coordinator.setHideRemotePlaylists($0) }
        )
    }

    // MARK: - 状态

    @ViewBuilder
    private var saveStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch coordinator.status {
            case .idle:
                if let date = coordinator.lastSavedAt {
                    Label("已保存（\(Self.timeText(date))）", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("设置会自动保存：控件改完立即生效，文本停顿后保存。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .saving:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在保存…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("重试保存") { coordinator.retry() }
                        .buttonStyle(.borderless)
                }
            }
            if let rejection = coordinator.rejectionMessage {
                Label(rejection, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - 载入

    /// 载入：**真实快照**优先（音质 / 音源 / 下载目录），其余来自本地设置。
    ///
    /// 只建立基线，**不触发保存**（载入不是改动）。
    private func prime() {
        coordinator.prime(
            session: model.sessionSnapshot,
            native: model.environment.store.current.settings
        )
    }

    private func label(for source: String) -> String {
        sourceOptions.first { $0.0 == source }?.1 ?? source
    }

    // MARK: - 目录选择

    private enum DirectoryKind {
        case download
        case playlists
        case library
    }

    /// 选择目录：**立即保存**（不是文本输入，不需要防抖）。
    private func chooseDirectory(kind: DirectoryKind) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = kind == .library
        panel.prompt = "选择"
        guard panel.runModal() == .OK else { return }
        switch kind {
        case .download:
            if let url = panel.url {
                coordinator.setDownloadDirectory(url.path, urgency: .immediate)
            }
        case .playlists:
            if let url = panel.url {
                coordinator.setPlaylistsDirectory(url.path, urgency: .immediate)
            }
        case .library:
            var folders = coordinator.values.libraryFolders
            for url in panel.urls where !folders.contains(url.path) {
                folders.append(url.path)
            }
            coordinator.setLibraryFolders(folders)
        }
    }

    private static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
