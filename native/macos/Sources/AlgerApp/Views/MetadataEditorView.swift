import AlgerKit
import SwiftUI
import AppKit

/// 元信息编辑器（E5）。
///
/// 固定契约：
/// ```swift
/// MetadataEditorView(track: TrackRecord, client: BridgeClient, settingsURL: URL, onSaved: @escaping (TrackRecord) -> Void)
/// ```
///
/// 行为约定：
/// - **录音与发行分别确认**：先确认录音（`meta.lookup`），再确认发行版本
///   （`meta.release`）—— 同一录音的不同专辑版本必须用户自己选；
/// - **CAA 封面按发行版本**：只取封面预览（`meta.artwork`），**嵌入与否由用户勾选**；
/// - **字段差异默认只补空缺**：非空字段（手工改过的值）**不默认勾选**，必须用户手工勾；
/// - **可取消**：匹配期间可以取消（本地 Task 取消 + `meta.cancel` 通知服务端）；
/// - **错误可见**：任何失败都显示具体原因，不假成功；
/// - **保存**：保存前重读相对打开基线做冲突检查 → 写入 → 写后重读严格核验；
///   核验不过 **不回调、不显示成功**；
/// - **只回传真实重读的记录**：`onSaved` 收到的是写后重新读取生成的 `TrackRecord`。
struct MetadataEditorView: View {
    /// 被编辑的本地曲目。
    let track: TrackRecord
    /// 桥接客户端（标签读写与匹配都走它）。
    let client: BridgeClient
    /// 匹配设置文件（`metadata-settings.json`）。
    let settingsURL: URL
    /// 保存成功回调（**写后真实重读**生成的记录）。
    let onSaved: (TrackRecord) -> Void

    /// 元信息服务。
    private let service: MetadataService
    /// 写回服务（冲突检查 + 写后核验）。
    private let applyService: MetadataApplyService
    /// 自动补全服务（**同一套保守规则**：可信来源优先 + 缺字段才严格匹配）。
    private let completionService: MetadataCompletionService

    @Environment(\.dismiss) private var dismiss

    // 读取状态
    @State private var baseline: AudioTags?
    /// 打开编辑器时读到的 **内嵌封面基线**（改 / 删封面时用于冲突比较）。
    @State private var artworkBaseline: MetadataArtworkBaseline = .notLoaded
    /// 打开编辑器时读到的已有封面（仅展示）。
    @State private var existingArtwork: Data?
    @State private var isLoading = true

    // 匹配状态
    @State private var searchTitle = ""
    @State private var searchArtist = ""
    @State private var candidates: [MetadataCandidate] = []
    @State private var recording: MetadataCandidate?
    @State private var releaseItem: MetadataRelease?
    @State private var releaseTracks: [MetadataTrack] = []
    @State private var artwork: MetadataArtwork?
    @State private var embedArtwork = false
    @State private var removeArtwork = false

    // 差异与勾选
    @State private var differences: [MetadataFieldDifference] = []
    @State private var selectedFields: Set<MetadataField> = []

    // 自动补全（**只填草稿**：结果进差异预览，仍走原有确认保存流程）
    @State private var completionProposal: MetadataCompletionProposal?

    // 手动编辑（离线可用；不需先确认任何网络候选）
    @State private var manualValues: [MetadataField: String] = [:]
    @State private var manualSelected: Set<MetadataField> = []

    // 匹配设置（AcoustID key / fpcalc 路径）
    @State private var acoustIDKey = ""
    @State private var fpcalcPath = ""
    @State private var settingsIssue: String?
    /// **同一个** 设置存储实例（打开时创建）。
    ///
    /// 每次都 `new` 一个 store 会把「打开时的旧值」当成最新基线写回去，
    /// 覆盖别的程序刚改的新配置；因此始终用同一个实例，
    /// 冲突时提示重新加载，**不自动重取基线**。
    @State private var settingsStore: MetadataSettingsStore?

    // 运行状态
    @State private var isBusy = false
    /// 有 **可取消的只读匹配** 在途（决定是否显示「取消匹配」）。
    @State private var isMatching = false
    @State private var statusText: String?
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    /// 运行代号（**引用类型**）：Task 闭包里必须读到「当前」代号，
    /// 而不是创建 Task 那一刻的视图快照 —— 否则旧 Task 会用旧快照覆盖新结果。
    @State private var matchRun = MetadataMatchRun()

    init(
        track: TrackRecord,
        client: BridgeClient,
        settingsURL: URL,
        onSaved: @escaping (TrackRecord) -> Void
    ) {
        self.track = track
        self.client = client
        self.settingsURL = settingsURL
        self.onSaved = onSaved
        let service = MetadataService(client: client)
        self.service = service
        self.applyService = MetadataApplyService(service: service)
        self.completionService = MetadataCompletionService(client: client)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                matchSection
                completionSection
                recordingSection
                releaseSection
                artworkSection
                differenceSection
                manualSection
                settingsSection
                statusSection
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 580)
        .task { await load() }
        .onDisappear { searchTask?.cancel() }
        .alert(
            "出错了",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title.isEmpty ? track.path : track.title)
                    .font(.headline)
                Text(track.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - 匹配

    private var matchSection: some View {
        Section("匹配（MusicBrainz / AcoustID）") {
            LabeledContent("标题") {
                TextField("标题", text: $searchTitle)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("艺人") {
                TextField("艺人", text: $searchArtist)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Button {
                    startSearch()
                } label: {
                    Label("搜索候选", systemImage: "magnifyingglass")
                }
                .disabled(isBusy || isLoading || searchTitle.trimmingCharacters(in: .whitespaces).isEmpty)

                Button {
                    startFingerprint()
                } label: {
                    Label("指纹匹配", systemImage: "waveform")
                }
                .disabled(isBusy || isLoading)

                Button {
                    runAutoComplete()
                } label: {
                    Label("自动补全", systemImage: "wand.and.stars")
                }
                .disabled(isBusy || isLoading || baseline == nil)

                if isMatching {
                    Button(role: .cancel) {
                        cancelMatching()
                    } label: {
                        Label("取消匹配", systemImage: "xmark.circle")
                    }
                }
            }
            if !candidates.isEmpty {
                ForEach(candidates) { candidate in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(candidate.title.isEmpty ? candidate.recordingId : candidate.title)
                            Spacer()
                            if candidate.isLowConfidence {
                                Text("低置信度")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        Text("\(candidate.artist) · \(formatDuration(Double(candidate.durationMs) / 1000)) · 分数 \(candidate.score, specifier: "%.2f")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("确认这个录音") {
                            confirmRecording(candidate)
                        }
                        .buttonStyle(.link)
                        .disabled(isBusy)
                    }
                }
            }
        }
    }

    // MARK: - 自动补全

    /// 自动补全的结果（**只填草稿**：值进下面的「字段差异」，不直接写文件）。
    @ViewBuilder
    private var completionSection: some View {
        Section("自动补全") {
            if let completionProposal {
                VStack(alignment: .leading, spacing: 4) {
                    Text(completionProposal.note)
                        .font(.caption)
                        .foregroundStyle(
                            completionProposal.isCompleted && !completionProposal.hasWarning
                                ? Color.secondary
                                : Color.orange
                        )
                    Text("补充的内容会显示在下面的「字段差异」里，保存前可以逐项预览。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("只补充空白信息，保存前可预览。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 录音

    @ViewBuilder
    private var recordingSection: some View {
        if let recording {
            Section("已确认的录音") {
                LabeledContent("标题", value: recording.title)
                LabeledContent("艺人", value: recording.artist)
                LabeledContent("时长", value: formatDuration(Double(recording.durationMs) / 1000))
                LabeledContent("录音 ID", value: recording.recordingId)
                if !recording.isrcs.isEmpty {
                    LabeledContent("ISRC", value: recording.isrcs.joined(separator: " / "))
                }
                Button("重新选择录音") {
                    self.recording = nil
                    releaseItem = nil
                    releaseTracks = []
                    artwork = nil
                    embedArtwork = false
                    rebuildDifferences()
                }
                .disabled(isBusy)
            }
        }
    }

    // MARK: - 发行

    @ViewBuilder
    private var releaseSection: some View {
        if let recording {
            Section("发行版本（需单独确认）") {
                if recording.releases.isEmpty {
                    Text("这个录音没有发行版本信息。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(recording.releases) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(item.title.isEmpty ? item.id : item.title)
                            Spacer()
                            if releaseItem?.id == item.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                        Text("\(item.albumArtist) · \(item.date) · \(item.country)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("确认这个发行") {
                            confirmRelease(item)
                        }
                        .buttonStyle(.link)
                        .disabled(isBusy)
                    }
                }
                if releaseItem != nil {
                    LabeledContent("曲序", value: currentTrackEntry.map { "\($0.track)" } ?? "未知")
                    LabeledContent("碟序", value: currentTrackEntry.map { "\($0.disc)" } ?? "未知")
                }
            }
        }
    }

    // MARK: - 封面

    @ViewBuilder
    private var artworkSection: some View {
        Section("封面（Cover Art Archive）") {
            if let existingArtwork, let image = NSImage(data: existingArtwork) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("当前文件里的封面")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 140)
                }
            } else if artworkBaseline.isLoaded {
                Text("当前文件里没有内嵌封面。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("没有读到封面基线：改 / 删封面会被拒绝（无法确认封面是否被改动）。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let artwork, let data = artwork.data {
                VStack(alignment: .leading, spacing: 2) {
                    Text("候选封面（发行 \(artwork.releaseId)）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(nsImage: NSImage(data: data) ?? NSImage())
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 180)
                    Text(artwork.mimeType.isEmpty ? "未知格式" : artwork.mimeType)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("嵌入这张封面", isOn: $embedArtwork)
                    .onChange(of: embedArtwork) { newValue in
                        if newValue { removeArtwork = false }
                    }
                Toggle("移除已有封面", isOn: $removeArtwork)
                    .onChange(of: removeArtwork) { newValue in
                        if newValue { embedArtwork = false }
                    }
            } else {
                Text("还没有取到候选封面。封面按 **确认过的发行版本** 取，避免错配。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if releaseItem != nil {
                    Button("获取封面") {
                        fetchArtwork()
                    }
                    .disabled(isBusy)
                } else {
                    Text("先确认发行版本，才能取封面。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 字段差异

    @ViewBuilder
    private var differenceSection: some View {
        Section("字段差异（默认只补空缺，覆盖非空需手工勾选）") {
            if differences.isEmpty {
                Text("还没有可比较的候选信息。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(differences) { difference in
                Toggle(isOn: Binding(
                    get: { isSelected(difference) },
                    set: { enabled in setSelected(difference, enabled: enabled) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(difference.field.title)
                            Spacer()
                            Text(difference.proposed)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("当前：\(difference.current ?? "读不到（桥接未返回该字段）")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !difference.isVerifiable {
                            Text("桥接未返回该字段，无法核验，不能写入。")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .disabled(!difference.isVerifiable || isBusy)
            }
        }
    }

    // MARK: - 手动编辑（离线）

    /// 可手工编辑的字段（**不含封面**：封面只能来自确认过的发行版本）。
    private static let manualFields: [MetadataField] = [
        .title, .artist, .album, .albumArtist, .genre,
        .track, .disc, .year, .date,
        .isrc, .musicBrainzRecordingId, .musicBrainzReleaseId, .neteaseId,
    ]

    private var manualSection: some View {
        DisclosureGroup("手动编辑（离线可用，不需先确认任何候选）") {
            ForEach(Self.manualFields, id: \.self) { field in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Toggle(field.title, isOn: Binding(
                            get: { manualSelected.contains(field) },
                            set: { enabled in
                                if enabled {
                                    manualSelected.insert(field)
                                } else {
                                    manualSelected.remove(field)
                                }
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .frame(width: 160, alignment: .leading)
                        TextField(
                            manualValues[field]?.isEmpty == true ? "（空）" : "",
                            text: Binding(
                                get: { manualValues[field] ?? "" },
                                set: { manualValues[field] = $0 }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                    }
                    if baseline?.value(for: field) == nil {
                        Text("桥接未返回该字段，写入后无法核验。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Text("默认一个都不勾；清空文字 = 明确写空（不是忽略）；数值留空视为非法，要清空请填 0。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 匹配设置

    private var settingsSection: some View {
        Section("匹配设置（独立配置文件）") {
            LabeledContent("AcoustID API key") {
                TextField("AcoustID API key", text: $acoustIDKey)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("fpcalc 路径") {
                TextField("fpcalc 路径（留空则用 PATH）", text: $fpcalcPath)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Button("保存匹配设置") {
                    saveSettings()
                }
                .disabled(isBusy)
                if let settingsIssue {
                    Text(settingsIssue)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Text("设置单独存放在 metadata-settings.json（权限 0600），不进应用状态。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if let statusText {
            Section {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 底部

    private var footer: some View {
        HStack {
            Button("关闭") {
                searchTask?.cancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Spacer()
            if isBusy {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                save()
            } label: {
                Label("保存到文件", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isBusy || isLoading || baseline == nil)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - 流程

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        loadSettings()
        do {
            let tags = try await service.readTags(path: track.path)
            baseline = tags
            // 搜索框初值：标签 → 索引 → 文件名推断（**文件名只作搜索草稿**）。
            let terms = Self.initialSearchTerms(tags: tags, track: track)
            searchTitle = terms.title
            searchArtist = terms.artist
            // 手动编辑的初值 = **baseline**（不是查找用的标题 / 艺人）。
            var values: [MetadataField: String] = [:]
            for field in Self.manualFields {
                values[field] = tags.value(for: field) ?? ""
            }
            manualValues = values
        } catch {
            errorMessage = describe(error)
        }
        // 已有封面：读出来做 **基线**（改 / 删封面时用来按字节比冲突）。
        do {
            switch try await service.embeddedArtworkState(path: track.path) {
            case .present(let data):
                artworkBaseline = .loaded(data)
                existingArtwork = data
            case .none:
                artworkBaseline = .loaded(nil)
                existingArtwork = nil
            case .unreadable(let message):
                artworkBaseline = .notLoaded
                existingArtwork = nil
                statusText = "读不到已有封面（\(message)）：改 / 删封面需要封面基线，可能无法写入。"
            }
        } catch {
            artworkBaseline = .notLoaded
            existingArtwork = nil
        }
    }

    /// 载入匹配设置（**只用打开时创建的同一个 store 实例**）。
    private func loadSettings() {
        let store = ensureSettingsStore()
        settingsIssue = store.loadIssue
        acoustIDKey = store.settings.acoustIDApiKey
        fpcalcPath = store.settings.fpcalcPath
    }

    /// 取（并在必要时创建）设置存储实例。
    ///
    /// **始终复用同一个实例**：新实例会把「打开时的旧值」当成最新基线，
    /// 保存时会把别的程序刚改的新配置覆盖掉。
    private func ensureSettingsStore() -> MetadataSettingsStore {
        if let store = settingsStore { return store }
        let store = MetadataSettingsStore(fileURL: settingsURL)
        settingsStore = store
        return store
    }

    private func saveSettings() {
        let store = ensureSettingsStore()
        do {
            try store.save(MetadataSettings(
                acoustIDApiKey: acoustIDKey.trimmingCharacters(in: .whitespacesAndNewlines),
                fpcalcPath: fpcalcPath.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
            settingsIssue = nil
            statusText = "匹配设置已保存。"
        } catch let error as MetadataSettingsStore.StoreError {
            settingsIssue = describeSettings(error)
        } catch {
            settingsIssue = describe(error)
        }
    }

    /// 设置错误描述（冲突时提示重新加载，**不自动重取基线**）。
    private func describeSettings(_ error: MetadataSettingsStore.StoreError) -> String {
        switch error {
        case .conflict:
            return "\(error.description)（设置文件被其它程序改过，请重新打开编辑器后再保存；不会自动覆盖）"
        default:
            return error.description
        }
    }

    private func startSearch() {
        let title = searchTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = searchArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        let durationMs = track.durationMs > 0 ? Int(track.durationMs) : nil
        startReadOnlyRun(status: "正在搜索候选…") { token in
            let found = try await service.search(
                title: title,
                artist: artist,
                durationMs: durationMs,
                token: token
            )
            guard matchRun.token == token, !Task.isCancelled else { return }
            candidates = found
            statusText = found.isEmpty ? "没有匹配候选。" : "找到 \(found.count) 个候选，请确认录音。"
        }
    }

    private func startFingerprint() {
        let key = acoustIDKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            errorMessage = "未配置 AcoustID API key：请先在「匹配设置」里填写。"
            return
        }
        let tool = fpcalcPath.trimmingCharacters(in: .whitespacesAndNewlines)
        startReadOnlyRun(status: "正在做音频指纹匹配…") { token in
            let found = try await service.fingerprint(
                path: track.path,
                apiKey: key,
                fpcalcPath: tool,
                token: token
            )
            guard matchRun.token == token, !Task.isCancelled else { return }
            candidates = found
            statusText = found.isEmpty ? "指纹没有匹配到候选。" : "指纹找到 \(found.count) 个候选，请确认录音。"
        }
    }

    /// 自动补全：**只填草稿**（结果进差异预览），仍走原有的确认保存流程。
    ///
    /// - 规则与下载后的自动补全 **完全一致**（同一个服务）：
    ///   可信来源优先 → 缺字段才严格匹配「标题 + 艺人 + 时长」→
    ///   低置信 / 歧义 / 不同版本一律拒绝自动填写；
    /// - 结果 **不写文件**：值进「字段差异」，由用户逐项确认后走原有保存流程。
    private func runAutoComplete() {
        guard let baseline else {
            errorMessage = "还没有读到文件标签，无法自动补全。"
            return
        }
        startReadOnlyRun(status: "正在自动补全…") { token in
            let suggestion = try await completionService.proposal(
                for: baseline,
                source: trustedSource(),
                query: MetadataCompletionService.filenameQuery(path: track.path)
            )
            guard matchRun.token == token, !Task.isCancelled else { return }
            completionProposal = suggestion
            rebuildDifferences()
            statusText = suggestion.note
            // 来源 ID 冲突是 **明确的拒绝**（弹窗提示，不静默）。
            if case .sourceIDConflict = suggestion.status {
                errorMessage = suggestion.note
            }
        }
    }

    /// 可信来源（下载来源）：**只有** 带来源关联的曲目才算可信。
    ///
    /// 没有来源关联的曲目不伪造可信来源（宁可不补，也不猜）。
    private func trustedSource() -> RemoteSong? {
        guard track.neteaseId > 0 else { return nil }
        guard let title = Self.cleanText(track.title),
              let artist = Self.cleanText(track.artist) else { return nil }
        return RemoteSong(
            id: track.neteaseId,
            name: title,
            artists: [RemoteArtist(id: 0, name: artist)],
            album: RemoteAlbum(id: 0, name: Self.cleanText(track.album) ?? "", picUrl: ""),
            durationMs: Int64(track.durationMs)
        )
    }

    private func confirmRecording(_ candidate: MetadataCandidate) {
        startReadOnlyRun(status: "正在确认录音…") { token in
            let confirmed = try await service.lookup(recordingId: candidate.recordingId, token: token)
            guard matchRun.token == token, !Task.isCancelled else { return }
            // **保留搜索 / 指纹阶段的分数**：lookup 是按精确 ID 查的（分数通常满分），
            // 直接用它会把低置信度悄悄变成高置信度 → 空字段被自动勾选。
            var effective = confirmed
            effective.score = MetadataCandidate.effectiveScore(
                searchScore: candidate.score,
                lookupScore: confirmed.score
            )
            recording = effective
            releaseItem = nil
            releaseTracks = []
            artwork = nil
            embedArtwork = false
            removeArtwork = false
            rebuildDifferences()
            if effective.isLowConfidence {
                statusText = "低置信度匹配：一个字段都不会自动勾选，请逐项确认要写入的字段。"
            } else {
                statusText = "录音已确认，请再确认发行版本。"
            }
        }
    }

    private func confirmRelease(_ item: MetadataRelease) {
        let recordingId = recording?.recordingId
        startReadOnlyRun(status: "正在确认发行版本…") { token in
            let detail = try await service.release(
                releaseId: item.id,
                recordingId: recordingId,
                token: token
            )
            guard matchRun.token == token, !Task.isCancelled else { return }
            releaseItem = detail.release
            releaseTracks = detail.tracks
            artwork = nil
            embedArtwork = false
            removeArtwork = false
            rebuildDifferences()
            statusText = "发行版本已确认。"
        }
    }

    private func fetchArtwork() {
        guard let releaseItem else { return }
        let releaseId = releaseItem.id
        startReadOnlyRun(status: "正在取封面…") { token in
            let fetched = try await service.artwork(releaseId: releaseId, token: token)
            guard matchRun.token == token, !Task.isCancelled else { return }
            artwork = fetched
            embedArtwork = false
            removeArtwork = false
            rebuildDifferences()
            statusText = "已取到封面预览，是否嵌入由你勾选。"
        }
    }

    /// 取消当前的 **只读匹配运行**。
    ///
    /// 既取消本地 Task，也补发 `meta.cancel` 让服务端尽早停止；
    /// 旧运行的迟到结果有代号守卫，不会覆盖新状态。
    private func cancelMatching() {
        searchTask?.cancel()
        searchTask = nil
        if let token = matchRun.token {
            Task { _ = try? await service.cancel(token: token) }
            matchRun.token = nil
        }
        isMatching = false
        isBusy = false
        statusText = "已取消匹配。"
    }

    /// 统一的 **只读匹配运行**（搜索 / 指纹 / 录音确认 / 发行确认 / 封面预览）。
    /// - 同一时刻只有一个在途运行，新的运行会 **取消** 上一个；
    /// - 「取消匹配」既取消本地 Task，也补发 `meta.cancel` 让服务端尽早停止；
    /// - 旧运行的迟到结果 **不得** 覆盖新状态（代号守卫）；
    /// - 保存（写入）**不走这里**：已提交的写事务不强行取消。
    private func startReadOnlyRun(
        status: String,
        _ operation: @escaping (String) async throws -> Void
    ) {
        searchTask?.cancel()
        let token = UUID().uuidString
        matchRun.token = token
        isBusy = true
        isMatching = true
        errorMessage = nil
        statusText = status
        searchTask = Task {
            do {
                try await operation(token)
                guard matchRun.token == token, !Task.isCancelled else { return }
                isMatching = false
                isBusy = false
            } catch is CancellationError {
                if matchRun.token == token {
                    isMatching = false
                    isBusy = false
                }
            } catch {
                guard matchRun.token == token, !Task.isCancelled else { return }
                errorMessage = describe(error)
                statusText = nil
                isMatching = false
                isBusy = false
            }
        }
    }

    // MARK: - 差异

    private var currentTrackEntry: MetadataTrack? {
        guard let recording else { return nil }
        return releaseTracks.first { $0.recordingId == recording.recordingId }
    }

    /// 由已确认的录音 / 发行 / 封面 / 自动补全建议重建差异列表与默认勾选。
    private func rebuildDifferences() {
        guard let baseline else {
            differences = []
            selectedFields = []
            return
        }
        var proposal = MetadataProposal()
        if let recording {
            if !recording.title.isEmpty { proposal.title = recording.title }
            if !recording.artist.isEmpty { proposal.artist = recording.artist }
            if !recording.recordingId.isEmpty { proposal.musicBrainzRecordingId = recording.recordingId }
            if let isrc = recording.isrcs.first, !isrc.isEmpty { proposal.isrc = isrc }
        }
        if let releaseItem {
            if !releaseItem.title.isEmpty { proposal.album = releaseItem.title }
            if !releaseItem.albumArtist.isEmpty { proposal.albumArtist = releaseItem.albumArtist }
            if !releaseItem.date.isEmpty { proposal.date = releaseItem.date }
            if !releaseItem.id.isEmpty { proposal.musicBrainzReleaseId = releaseItem.id }
            if let year = Self.year(from: releaseItem.date) { proposal.year = year }
            if let entry = currentTrackEntry {
                if entry.track > 0 { proposal.track = entry.track }
                if entry.disc > 0 { proposal.disc = entry.disc }
            }
        }
        // 封面：只要取到就列出来（**默认不勾选**）。
        if let artwork { proposal.artworkBase64 = artwork.artworkBase64 }
        // 自动补全的建议：**只补空缺**，且 **不覆盖** 已确认的候选值。
        if let completionProposal {
            Self.applyCompletion(completionProposal.values, to: &proposal)
        }

        let computed = MetadataDifferences.compute(current: baseline, proposal: proposal)
        differences = computed
        if recording?.isLowConfidence == true {
            // 低置信度：**一个字段都不默认勾选**，
            // 必须用户逐项明确勾选（不能只显示一个警告就自动勾空字段）。
            selectedFields = []
        } else {
            // 默认勾选：**仅** 空缺字段（覆盖非空必须用户手工勾）。
            selectedFields = Set(
                computed
                    .filter { $0.defaultSelected && $0.isVerifiable }
                    .map(\.field)
            )
        }
    }

    /// 把自动补全的建议并进候选（**不覆盖** 已确认的候选值）。
    private static func applyCompletion(_ values: [MetadataField: String], to proposal: inout MetadataProposal) {
        for (field, value) in values {
            // 已有候选值（用户确认过的录音 / 发行）→ **不覆盖**。
            guard proposal.value(for: field) == nil else { continue }
            switch field {
            case .title: proposal.title = value
            case .artist: proposal.artist = value
            case .album: proposal.album = value
            case .albumArtist: proposal.albumArtist = value
            case .genre: proposal.genre = value
            case .track: proposal.track = Int(value)
            case .disc: proposal.disc = Int(value)
            case .year: proposal.year = Int(value)
            case .date: proposal.date = value
            case .isrc: proposal.isrc = value
            case .neteaseId: proposal.neteaseId = Int64(value)
            case .musicBrainzRecordingId: proposal.musicBrainzRecordingId = value
            case .musicBrainzReleaseId: proposal.musicBrainzReleaseId = value
            case .artwork: break        // 封面永远不自动填
            }
        }
    }

    /// 搜索框初值：标签 → 索引 → 文件名推断。
    ///
    /// 文件名推断出来的值 **只是搜索草稿**（不落标签、不当录音依据）。
    private static func initialSearchTerms(
        tags: AudioTags,
        track: TrackRecord
    ) -> (title: String, artist: String) {
        let filename = MetadataCompletionService.filenameQuery(path: track.path)
        let title = cleanText(tags.title) ?? cleanText(track.title) ?? filename?.title ?? ""
        let artist = cleanText(tags.artist) ?? cleanText(track.artist) ?? filename?.artist ?? ""
        return (title, artist)
    }

    /// 清洗文本（空值 / 路径 / `Unrecognized` 占位 → `nil`）。
    private static func cleanText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !TrackRecord.looksLikePath(trimmed) else { return nil }
        guard trimmed.lowercased() != TrackRecord.unrecognizedPlaceholder.lowercased() else { return nil }
        return trimmed
    }

    private func isSelected(_ difference: MetadataFieldDifference) -> Bool {
        // 封面走单独的开关（它不是普通文本字段）。
        if difference.field == .artwork { return embedArtwork }
        return selectedFields.contains(difference.field)
    }

    private func setSelected(_ difference: MetadataFieldDifference, enabled: Bool) {
        if difference.field == .artwork {
            embedArtwork = enabled
            if enabled { removeArtwork = false }
            return
        }
        if enabled {
            selectedFields.insert(difference.field)
        } else {
            selectedFields.remove(difference.field)
        }
    }

    // MARK: - 保存

    private func currentSelection() -> MetadataSelection {
        var fields: [MetadataField: String] = [:]
        // 候选差异里勾选的。
        for difference in differences {
            guard selectedFields.contains(difference.field) else { continue }
            if difference.field == .artwork { continue }
            fields[difference.field] = difference.proposed
        }
        // **手动编辑优先**（同一字段以手工值为准）。
        for field in manualSelected {
            fields[field] = manualValues[field] ?? ""
        }
        return MetadataSelection(
            fields: fields,
            artworkBase64: embedArtwork ? artwork?.artworkBase64 : nil,
            removeArtwork: removeArtwork
        )
    }

    private func save() {
        guard let baseline else {
            errorMessage = "还没有读到文件标签，无法保存。"
            return
        }
        let selection = currentSelection()
        guard !selection.isEmpty else {
            errorMessage = "没有勾选任何要写入的字段。"
            return
        }
        isBusy = true
        errorMessage = nil
        statusText = "正在写入并核验…"
        Task {
            do {
                let record = try await applyService.save(
                    path: track.path,
                    baseline: baseline,
                    selection: selection,
                    artworkBaseline: artworkBaseline,
                    // 索引里已有的来源关联：用户没显式勾来源 ID 时 **保留**。
                    preservingSourceID: track.neteaseId
                )
                // **只回传写后真实重读的记录**。
                onSaved(record)
                dismiss()
            } catch {
                // 失败：不回调、不显示成功（写入可能已经发生，只说「未能确认保存成功」）。
                errorMessage = describe(error)
                statusText = "未能确认保存成功。"
                isBusy = false
            }
        }
    }

    // MARK: - 工具

    /// 从 `YYYY-MM-DD` 取年份。
    private static func year(from date: String) -> Int? {
        let trimmed = date.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return nil }
        return Int(trimmed.prefix(4))
    }

    /// 错误描述（**界面上必须看到具体原因**）。
    private func describe(_ error: Error) -> String {
        if let metadataError = error as? MetadataError { return metadataError.description }
        if let bridgeError = error as? BridgeClient.BridgeError { return bridgeError.description }
        if let clientError = error as? BridgeClient.ClientError { return clientError.description }
        return error.localizedDescription
    }
}

// MARK: - 根视图入口

/// 匹配运行代号（**引用类型**）。
///
/// `@State` 里的类实例在视图重建之间 **保持同一个对象**；
/// Task 闭包里读到的必须是「当前」代号，而不是创建 Task 那一刻的视图快照 ——
/// 否则旧 Task 会用旧快照覆盖新结果（取消 / 重新搜索后旧结果又冒出来）。
final class MetadataMatchRun {
    /// 当前运行的代号（`nil` = 没有在途运行）。
    var token: String?
}
