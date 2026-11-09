# 开发说明与续做交接

## 最新修订：侧栏逐级导航与隔离验收（2026-11-08，Asia/Shanghai）

用户已授权续做。侧栏启动时只显示主页、资料库、本地歌单、网络歌单和临时播放。
点击分类进入同一侧栏的二级列表。顶部返回保留当前详情。每个一级分类只有一个进入箭头。
资料库二级按歌曲、专辑、艺人、下载排列，下载入口随任务出现。网络歌单保持只读，
在设置中隐藏网络歌单时，侧栏自动退出对应二级页。
资料库的艺人和专辑浏览器初始只显示首列，随选择追加下一列。换艺人会清除旧歌曲列。

| 检查 | 结果 |
| --- | --- |
| Swift 全量与真实桥接 | **324 项通过，0 失败**。原生应用也完成编译 |
| 发布包真实交互 | 一级与三个二级列表、返回保留详情、隐藏网络歌单即时落盘、只读歌单详情均通过。艺人和专辑按选择展开，940 点宽的窗口自动滚到歌曲列 |
| 网络详情 | 隔离会话实测关注艺人的热门歌曲、网络专辑列表和选中专辑的曲目均成功加载 |
| 元信息草稿与确认 | 复用上一版相同的编辑器，用合成 M4A 实测。自动补全产生来源 ID 草稿时 SHA-256 未变，点击保存后 `ffprobe` 实读来源 ID，原有标题、艺人和专辑保留 |
| 试用版安装 | `sh scripts/install-dist.sh` 退出码 0。签名、显示名、试用身份、包内桥接、隔离启动退出与安装后复验均通过。四个既有 profile 文件的 SHA-256 保持一致 |

GUI 验证在 macOS 27.2 完成。两个隔离应用均通过定向退出并捕获退出码 0。现有测试编译警告仍在。

OpenCode 使用交互模式，各实现会话只负责一个文件，统一构建与验收。以下是各会话的 token 记录。

| 模型 | 任务与结果 | 输入 / 输出 / 推理 / 缓存读取 |
| --- | --- | --- |
| MM-F | 侧栏实现，落盘后中断额外复查 | 70,584 / 7,265 / 30,478 / 1,453,952 |
| GLM-F | 资料库按选择追加列，完成 | 32,318 / 1,372 / 6,521 / 293,312 |
| K4C | 元信息验收，周额度返回 429，由协调器完成 | 0 / 0 / 0 / 0 |

本轮三个交互会话均退出。Codex 在 10:08 的快照为 5 小时窗口已用 **17%**、周窗口 **49%**，
起始分别为 1% 和 47%。后续可用 `opencode api GET /api/session/active` 查看运行状态，
用 `opencode api GET /api/session/<id>` 读取会话 token。交出可验证的改动后由协调器接手，
减少重复审查。遇到额度 429 直接结束该会话，剩余工作交给可用模型或协调器。

## 历史交接：用户要求立即停止，保留续做现场（2026-11-07，Asia/Shanghai）

**用户最新指令：usage 已超，结束并收手。现在停止开发、测试、OC 与构建，不自动恢复。**
新增界面要求原文：**「侧栏默认只显示1级 用户点击后推入次级」**，尚未实现，续做时优先遵循此要求，
不能把当前预铺多列占位的界面视为最终验收。

两项追加源码已落盘但**未重新打包**：SidebarView 全系统单个受控折叠按钮、禁用系统额外折叠；
LibraryViews 两种详情补 `.task(id:)` 调用加载。仅语法与 diff 检查通过，未运行新包验收。
`dist/AlgerMusicPlayer.app` 仍是此前已构建、校验、隔离 smoke 通过的版本；本轮解锁后未替换它。

解锁后实际通过：艺人→专辑→歌曲三列保留选择；`+` 单击入临时播放、右键加入本地歌单，M3U8 实读新增；
随机模式退出重启保持、JSON 实读；关注艺人分区与 FM 封面实显。元信息核心字段齐全时自动补全跳过，符合规则。
**仍未验收**：新增一级推入次级要求、追加的侧栏折叠与网络详情加载、专辑两列、元信息草稿和确认写盘。
编辑器保存尝试因自动化未可靠勾选字段而未写入，界面报无选中字段，ffprobe 标签仍原值；不能判为产品缺陷或通过。

GUI OC 会话 `ses_e4ce1f1bcffeGjo5bn0f1uWBCM` 已 interrupt/idle，交互 CLI exit 0；
本轮三个隔离应用 PID 37055/38279/38684 均定向退出且进程消失，但未捕获应用自身 wait 退出码。
独立复核 OC 未产出（模型回落免费端点 429），已停并退出；两项小修由协调子代理完成，不留后台写者。
真实 trial 四文件 SHA-256 前后不变。报告、截图、隔离夹具保留 `.artifacts/gui-unlocked/`，
按用户此前“全部完成后一并清理”的约定，本次中止不清除此现场；外部临时备份在收尾移除。
未 commit/reset。续做须先获用户恢复指令，再核对源码及已装包差异，不沿用中间报告的提前 PASS。

## 解锁后追加验收记录（2026-11-07，Asia/Shanghai，已停止）

用户已解锁桌面，要求控制 usage、多委派，临近收尾留交接。OC MM-F 负责唯一桌面操作，
隔离 profile / 音频夹具 / 证据在 `.artifacts/gui-unlocked/`，真实 profile 不参与写入。
已实看关注艺人独立列表、本地艺人→专辑→歌曲三列，以及 `+` 加入临时播放。
其余操作仍待实测，不能把 OC 提前填写的 PASS 当作证据。

追加复核发现并已修：`ArtistDetailView` / `AlbumDetailView` 原先没有调用加载方法，
现用 `.task(id:)` 按艺人/专辑键加载，嵌入和独立详情共用。侧栏改为所有系统统一受控自绘按钮，
`.collapsible(false)` 禁用额外系统折叠；整行可点击，AX 标签和值反映展开状态。
两文件语法检查与 diff 检查通过；**这两项追加源码尚未重新打包，当前 dist 仍是下段已验证版本**。
待本轮旧包 GUI 退出后统一构建安装，再回验详情加载和折叠。

## 最新修订：本轮反馈已实现，试用版已更新（2026-11-07，Asia/Shanghai）

用户已授权接手续做，下面 11 月 6 日的暂停/不得恢复指令是历史状态。
当前源码已冻结，trial release 已安装；本段记录最终实现、验证与交互验收边界。

### 已实现

- **侧栏与首页**：两组歌单只保留一个受控箭头；macOS 14+ 使用系统折叠，13 的 fallback 禁用系统额外折叠。
  下载入口移到资料库最后。首页全部统一方形封面 + 播放按钮，单击选择高亮，去掉 FM 首曲大卡。
  封面 loader 对网易 CDN 的 HTTP 地址转 HTTPS，流式限额、后台降采样、缓存；本地读取真实内嵌封面。
  PlayerBar 复用相同封面组件。
- **本地资料库**：缺标签归组 `Unrecognized`，无标题用 basename，旧索引路径型标题同样去前缀。
  艺人→专辑→歌曲三列、专辑→歌曲两列，右箭头选择、保留上级状态并滚到新列；歌曲列表右端有添加入口。
  临时播放列表也补上 `+`。单击 `+` 仍默认加入临时播放，右键/长按选择本地歌单。
- **元信息补全**：新增 `MetadataCompletionService`，下载后与编辑器共用。
  可信来源优先，只补空字段；核心字段齐全不逐首请求 MusicBrainz。
  在线自动匹配要求标题/艺人/时长一致、独立自动置信阈值 >= 90%；多录音、不同版本、发行不一致、多个 ISRC 不猜。
  已有非空标签/封面不被自动补全覆盖；写前基线、写后实读校验。编辑器先生成草稿与字段差异，用户确认后保存。
- **下载去重与升级**：新 `DownloadPipeline` 统一登记、审核、完成补全、替换、入库入单；自动保存、手动重试、跨重启恢复共用审核。
  ID 优先，缺 ID 时保守标题/艺人 + 时长/专辑佐证，不误并现场/混音等不同录音。
  本地足够时直接复用；升级候选完整下载后按真实编码/码率/采样率/位深核验。
  无损不被有损替换，无损之间不按压缩码率比较，不同有损编码不直接比码率，未知编码保守保留本地。
  URL 容器只作为候选提示，**不是实测质量**；未确认更高的候选弃新复用旧。
- **替换保护**：保留旧手动标签和封面，迁移索引、M3U8、intake、内存播放引用，保留新文件正确扩展名；最后才将旧文件送入废纸篓。
  拒绝同路径/同 inode/符号链接；重启恢复重验新旧指纹、身份、质量，不确定保留两边报错。
  废纸篓失败持久保留待处理路径和指纹；重复/迟到事件解析当前存活路径，失败可重试，不会清空已迁移索引。
  同曲有未完成提交时拒绝新替换意图，防止丢失事务；部分失败不缓存为成功。
- **播放顺序**：默认顺序，歌单页与播放条可切随机，`native.json/settings.playbackOrder` 兼容旧文件并记住上次状态。
  随机不改变可见队列顺序，从任意起点遍历整轮。AppModel 转发播放器变化，使按钮/进度/当前项能更新。
- **网络只读与关注艺人**：前端、Tauri 命令、原生 UI/模型/服务、Rust bridge 七个写 handler 及共享底层写方法均移除。
  读取、播放、下载和加入本地歌单保留。关注列表分页、去重、终止保护与解析/登录错误明确，原生艺人页有独立关注分区；
  过期关注响应不会在退出登录后回写。无新作不再被当成没有关注。
- **恢复时序**：修正 Rust 下载故障测试过早恢复写权限的竞争，等待 persistError + 在途集合释放后再恢复，原断言保留。
  修正下载时间戳 Rust 毫秒 / Swift 秒不一致：解析边界兼容两种单位，旧任务能识别为上次会话。
  原生恢复复用 `retryDownload`，并用 `isRecoveringDownloads` 防重入，已有本地文件仍补入原目标歌单。

### 验证与边界

| 检查 | 最终结果 |
| --- | --- |
| Swift 全量（含新增元信息、替换事务、恢复、时间单位等） | **324 / 0，exit 0**；最后一轮约 96.7 秒 |
| 最后 AppModel 恢复共用逻辑 + 临时播放 `+` 后真实应用编译 | **exit 0**，非 stub / 复制工程 |
| 真实音频升级回归（包含在 324 中） | **2 / 0**：真实 MP3→FLAC，旧标签/封面/引用保留、解码 PCM 摘要不变、AVFoundation 可播放；真实 ALAC 不被 MP3 降级 |
| 元信息自动补全 | **31 / 0**，包含歧义、90% 阈值、来源冲突、发行一致性、写后失败 |
| Rust core | **143 lib + 8 tags_e5 / 0** |
| Rust bridge | **10 exit + 8 metadata + 2 readonly / 0** |
| Tauri | **67 / 0**，共享 API 删除后构建通过 |
| 前端 | typecheck、只读交互 **15 / 0**、播放 **4 / 0** |
| fmt / clippy | core/bridge fmt 通过；主协调器独立复核两者 clippy all-targets `-D warnings` 均 exit 0 |
| 真实只读联调 | 新桥接读取关注艺人 **33 位**、FM **3 首均有封面 URL**、MusicBrainz Imagine/John Lennon **5 个候选** |
| 隔离 GUI | 真实应用启动，本地内嵌封面及网络 FM 封面已在窗口截图实看，卡片尺寸统一；定向正常退出 **exit 0** |

**交互验收限制**：桌面处于 macOS 锁定界面，点击被系统交给 loginwindow；主协调器已停止点击，未尝试解锁/绕过安全界面。
因此本轮没有把箭头 hover/折叠、列选择/滚动、模式按钮和编辑器确认保存等**真实点击操作**标成已验收。
已向用户请求方便时解锁；自动测试和真实渲染证据保持独立。

本轮没有真实账号的网络写入，没有在真实音乐上做故障注入。核对的 4 个既有持久 profile 文件在安装前后 SHA-256 均未变。
127 个源码/测试文件已冻结。独立只读复核的索引合并、弃新后的重复事件、自动保存重试入库、未完成事务覆盖等问题已修并加回归；
此前出现的 3 个 Swift 测试失败均已关闭，不能沿用中间日志的红项作为最终结果。

### 核心入口与维护

- `native/macos/Sources/AlgerKit/{MetadataCompletionService,DownloadPipeline,DownloadMetadataCompletionAdapter,DownloadReviewService}.swift`。
- `AppModel.swift`：下载请求、完成、自动保存与恢复编排；`Views/MetadataEditorView.swift`：自动补全草稿与确认；
  Sidebar/Home/Library/Playlist/Common/PlayerBar/Downloads 视图为本轮 UI 改动。
- `Tests/AlgerKitTests/{MetadataCompletionTests,DownloadPipelineTests,DownloadRealAudioTests,FeedbackRegressionTests}.swift`。
- Rust：`crates/alger-core/{src/dlq.rs,src/netease/ext.rs,tests/tags_e5.rs}`、bridge `main.rs/tests/readonly.rs`、共享 netease API。
- OC 交互会话：下载 MM-F `ses_e4d0f7012ffeQvspqfStoG443X`、元信息 MM-F `ses_e4d0f7935ffezRKrYIenjRhcyo`、
  UI 与只读复核 MM-F `ses_e4d0f74a4ffeM0tGxIsGMxXP90`、Rust GLM-F `ses_e4d0f6b96ffeQPiyx6CoY62nZU`。
  源码冻结后均结束；未购买额度/改订阅，未 commit/reset。
- 本轮中间日志、报告、截图、隔离会话副本都在 `.artifacts/resume-1107/`；必要结论已摘录到本文。
  按用户约定，完成开发/验证/安装后才统一清理；安装脚本已成功清理这些临时路径，不作为长期文档入口。

**安装状态：`sh scripts/install-dist.sh` exit 0。** trial release 构建、包/签名校验、Finder/Dock 名称、
`com.alger.music.trial` 身份与持久数据目录校验通过；隔离 smoke 确认应用和包内 bridge 均启动，
定向正常退出码 0、子进程退出、真实 profile 不变后才替换 `dist/AlgerMusicPlayer.app`，替换后再次校验通过。
脚本自动清理成功，`dist/`、源码、依赖与持久用户数据保留；文档收尾后再执行一次 `sh scripts/clean.sh`。

## 历史交接：本轮反馈修订中途暂停，保留现场（2026-11-06，Asia/Shanghai）

**用户最新指令：准备收手、编写交接；本轮先不清理，把约定写进 DEV，后续全部完成后再一并清理。**
本段优先于下方历史“最新”段落。现在停止继续开发，不自动恢复 OC、不安装当前源码。
当前原生应用 **未通过编译，不能交付**；`dist/AlgerMusicPlayer.app` 未替换，仍保留上一轮可用试用版。
本轮 **没有运行** `scripts/install-dist.sh` 或 `scripts/clean.sh`；暂时不清理是用户明确覆盖
AGENTS.md 的逐轮清理约定，**不是遗漏**。后续获准续做并完成全部工作后再统一清理。

### 用户原始目标与当前真实进度

| 需求 | 当前落盘状态 | 尚缺什么 |
| --- | --- | --- |
| 两组歌单 hover 双箭头、展开状态不同步 | `SidebarView` 改为 macOS 14+ 的系统 `Section(isExpanded:)`；13 的自控分支显式 `.collapsible(false)` | 未做真实 GUI 验证；不得仅凭代码认定已修 |
| 无元信息归 `Unrecognized`、不重复显示绝对路径 | `TrackRecord.displayTitle/displayArtist/displayAlbum/looksLikePath` 和 `LocalLibrary` 分组已改；标题兜底 basename 去扩展名，旧路径型 title 也规范显示 | 新增回归未运行；各遗留列表/Toast/歌单行仍需统一检查 |
| 艺人/专辑向右箭头打开 Finder 式并列列表，歌曲行均有 `+` | `LibraryViews` 已改艺人→专辑→歌曲三列、专辑→歌曲两列；保留选择、自动滚到新列、歌曲行接 `AddToPlaylistMenu`；主协调器补了 `LazyVStack` | 未 GUI 验证；列内窄宽度、网络专辑、空态/错误、全部加号功能待验收 |
| 简单保守的自动补全元信息，接下载后及手动编辑器 | **尚未实现**。已交接并阅读现有 MetadataService/ApplyService，但新服务/测试尚未创建，编辑器未加入按钮 | 是续做优先项；不能把现有手动匹配编辑器当成本轮自动补全完成 |
| 下载在资料库底部，下载前查重，质量更高才替换 | 侧栏位置已改；新增 `DownloadReviewService/DownloadReplacementService`、质量模型、替换日志与部分 AppModel 入队前审核 | **流程未闭环**：下载完成尚未调用替换提交；自动保存/重试仍绕开统一审核；崩溃恢复、失败保护和真实音频测试未完成 |
| 歌单默认顺序、允许随机、记住上次模式 | `PlaybackOrder`、NativeSettings 宽容解码/持久字段、PlayerController 随机整轮、AppModel 模式设置已落盘；新增转发 player.objectWillChange | 歌单/PlayerBar **尚无模式控件**；43 项新增回归只 parse，未运行，上一首/自然结束/队列改动仍需实测 |
| 首页实际封面、统一方形 cover+play、可高亮、去 FM 首项特殊卡 | `HomeView/HomeArtwork` 已改统一卡片、单击选中/双击或按钮播放、HTTP CDN→HTTPS、流式限额/降采样/缓存 | `HomeArtwork.swift:300` 有真实编译错误；没有 GUI/封面显示验收。PlayerBar 仍用旧 AsyncImage，未复用新封面组件 |
| 网络歌单完全只读并移除写代码/UI | 前端/Tauri 命令层已完成，15 项只读回归通过；原生 AppModel/BridgeService 删除写方法，RemotePlaylistService 及其测试已删除；CommonViews/ContentView、网络详情有部分改动 | **原生未完成**：PlaylistViews 仍残留 RemotePlaylistPickerSheet/asRemote/已删除模型 API；Rust bridge 的七个 `net.*` 写 handler 实际仍存在，底层写函数也未清除 |
| 能识别关注艺人 | AppModel 已接关注列表/错误/加载状态，登录/启动刷新、退出清空；艺人页有独立关注分区；真实账号只读探测成功 | Rust `net.artistSublist` **仍只取 limit=100, offset=0 一页**，没有分页取全；失败/空响应处理、并发刷新/退出登录竞态待复核；新作列表与关注关系未端到端验收 |

### 冻结后的检查结果（不是完成声明）

所有本轮 OC 会话已 API interrupt，确认 `outcome=interrupted` 且 idle，四个本轮交互 CLI 均 exit 0。
之后只运行检查和写本文，**没有继续修产品源码**。冻结源码/测试 124 文件 SHA-256 在
`.artifacts/oc-feedback/frozen-source-sha256.json`。

| 检查 | 本轮最后真实结果 | 证据 |
| --- | --- | --- |
| 原生全应用 `swift build` | **exit 1**；HomeArtwork.swift:300 的 `min(maxBytes, max(declared, 0))` 把 `Int64` 当 `Int` | `frozen-swift-build.log` |
| 仅 AlgerKit target 构建 | **exit 0**（0.23s 增量）；只证明库能编译，不代表 App 或测试通过 | `frozen-kit-build.log` |
| 8 个相关 UI 文件 + FeedbackRegressionTests 的 `swiftc -parse` | **exit 0**；只是语法检查 | `frozen-swift-parse.log` |
| 新增 `FeedbackRegressionTests.swift` | **43 项用例，仅 parse，未编译/运行** | 源码及 `regressions-report.md` |
| Rust core 全量 `cargo test` | **138 passed / 1 failed，exit 101**；lib 失败后未运行该命令后续集成 tests | `frozen-core-test.log` |
| Rust bridge 全量 `cargo test` | **10 + 8 passed，exit 0** | `frozen-bridge-test.log` |
| 前端 typecheck + 只读歌单验收 + 播放验收 | **exit 0；15 + 4 通过** | `frozen-frontend-check.log` |
| 前端作者更早的检查 | Tauri 67 tests、fmt、clippy、Vite 构建及跨 crate check 均通过；不是最后原生增量的完整验收 | `mobile-report.md`、`verify.log`、`clippy.log`、`vite-build.log` |
| GUI / 真实音频升级 / 新 trial release / 安装 | **未做** | 不得沿用历史段中的通过结论 |

以上日志均在 `.artifacts/oc-feedback/`，按用户要求保留。

Rust core 唯一已观测失败：`dlq::tests::done_persist_failure_then_public_retry_recovers_without_redownload`，
`crates/alger-core/src/dlq.rs:2391` 断言故障注入后状态应为 `running`，实际为 `done`。
**没有判定为偶发，也没有放宽/删除断言或重跑掩盖失败**，续做需调查原因。

### 已确认阻塞与续做顺序

1. **先补齐自动元信息服务，再闭环下载。** 固定交接 API：
   `MetadataCompletionService(client: BridgeClient)`，
   `completeDownloaded(path: String, source: RemoteSong? = nil) async throws -> AudioTags`。
   可信下载来源优先，只补空字段，保留已有非空标签/封面；不足时才严格匹配，低置信/不同版本/歧义拒绝自动写入；
   无匹配返回原 tags，网络/IO 错误明确。编辑器的“自动补全”只填草稿，继续走原有差异预览与确认保存。
   参考保留的 `metadata-prompt.txt` 与 `core-metadata-handoff`；新服务和 MetadataCompletionTests **当前不存在**。
2. **修原生编译与只读 UI 中间态。** 先修 HomeArtwork:300 的 Int64/Int 转换（流量已限额，仍要安全转换），
   关注 macOS 13 下 `NSImage: Sendable` 的 availability 警告；再真实重编译暴露剩余错误。
   `PlaylistViews` 仍引用已删除的 `pendingRemoteSong/addRemoteSongs/canEdit/saveQueueAsRemotePlaylist`，
   并保留 RemotePlaylistPickerSheet 与网络另存开关，必须删除。歌单/PlayerBar 加模式控件，PlayerBar 复用 HomeArtwork。
   `readonly-ui-prompt.txt` 是完整规格。**`core-ui-handoff` 自述 Rust handler 已删与源码不符，必须以源码/检查为准。**
3. **下载审核目前只接了部分路径。** `saveQueueAsLocalPlaylist` 和 `addRemoteSongToLocalPlaylist` 调用了
   `planDownload/registerReplacement`；`finishDownload` 仍只有原 intake，没有 `replacement.commit` 或自动元信息补全。
   `AutoSaveService.Decision.reviewExistingLocal` 已新增，但 AppModel.evaluateAutoSave 仍只接受 `.enqueue`，
   enqueueAutoSave/retry/resume 仍需统一接审核。必须逐个枚举真实入队入口，不能仅凭 helper 存在宣称已统一。
4. **替换服务需独立审查和真夹具测试。** 方案已改为保持新文件的正确扩展名并迁移索引、所有本地 M3U8、
   intake 路径、内存播放队列，旧文件最后移入废纸篓。已有来源/时长核验、路径/同 inode/软链拒绝、旧文件指纹、
   标签/封面保留、提交中日志、部分回滚和 `committedWithWarning`。但尚无真实升级测试：
   `.committing` 没有启动恢复入口；回滚及 markFailed/markDiscarded/trash 仍有 `try?`；trash 失败会留下重复文件；
   指纹采集/标签保留/迁移间的外部改写及跨 actor 并发要验证；不要直接在真实音乐上试故障。
   废纸篓动作尚不可注入，测试应先补隔离接口，避免把夹具留到真实废纸篓。
5. **质量规则已修关键错误，但未测全。** Rust tags 的码率已从 lofty kbps 转为 bps，新增真实 codec/bitDepth，
   `read_file` 用 guess_file_type，容器按实际类型识别。原 192 kbps 真实夹具旧桥接读为 194，
   不转换会把所有远端版本误判更好。ALAC 必须视为无损；无损按采样率/位深的“不降且至少一项提升”，
   不比较压缩码率；未知编码保守；有损只比较相同 codec。曾发现 self/other 方向反转，**当前源码已修**，
   保留独立方向性回归。远端 ResolvedAudio 只有 URL/码率，没有 codec/PCM 属性：M4A/无损→更高无损的
   下载前升级判断仍受限，必须明确处理，不能凭 URL 后缀冒充实际编码探测。
6. **彻底移除网络写能力、补关注分页与测试。** 原生模型删除了写接口，但 bridge dispatch 和共享
   `src-tauri/src/netease/api.rs` / core ext 仍有写实现。先清调用再删共享底层，防止破坏移动端/共享 crate；
   加实际无写调用回归。关注列表当前只取一页；不要把空新作当作没有关注。
7. **跑真正的全量验证后再谈安装。** 修上面的 Rust 故障测试，运行 Swift 全量（含新增 43 项、实际音频/标签/替换/重启）、
   core/bridge、前端、必要 fmt/clippy，再做隔离 GUI：箭头 hover/展开、真实封面、统一卡片选中、三列自动滚动、
   加号、本地/网络只读、模式即时刷新与重启恢复。全部关闭必修后才 `sh scripts/install-dist.sh`；
   验证新包后替换，保留旧 app/试用身份/数据。**用户当前要求收手，不能据此段自行恢复开发或安装。**

### 文件、会话与现场

- 核心：`AppModel.swift`、`AlgerKit/{LibraryIndex,LocalLibrary,NativeState,PlaybackController,DownloadReviewService,
  AlgerEnvironment,AutoSaveService,MetadataModels,BridgeService}.swift`、`crates/alger-core/src/tags.rs`；
  下载服务是新文件，核心目录与 native 目录整体仍有既有未跟踪文件，**都要保留**。
- UI：`Views/{SidebarView,HomeView,HomeArtwork,LibraryViews,CommonViews,ContentView,PlaylistViews}.swift`。
  `PlayerBar.swift` 仍旧实现，无模式开关/新封面；`MetadataEditorView.swift` 未加入本轮自动补全。
- 新回归：`native/macos/Tests/AlgerKitTests/FeedbackRegressionTests.swift`，43 项，五个测试类。
  `regressions-report.md` 是编写时的源码推演，部分红项之后已改源码，**不能当作测试执行结果**。
- 前端/Tauri 只读范围：frontend api/main/playlists/search/styles/mobile.css/dom、Tauri commands/lib、
  `tests/playlist-dialog-acceptance.cjs`（现为只读回归）与 package.json；login.rs 还去掉了一个 clippy 检出的多余 return。
- 临时现场完整保留在 `.artifacts/oc-feedback/`：原始任务拆分 prompt、handoff、作者报告、
  frozen 日志/源码哈希、GUI 音频/内嵌封面夹具、只读 probe 结果等。
  probe/gui 下的 session.json 是权限 0600 的现有登录会话隔离副本，保持本地，不把内容写进文档或上传。
- OC 均为交互 mini：核心 MM-F `ses_e5014cd6fffek2pJy3h9RYkp4q`；
  首页/侧栏 GLM-F `ses_e5014c8dcffeM75UkXVRBvmZuw`；
  列视图→43项回归→只读UI MM-F `ses_e5014c448ffe7b5VeK4DNEr8xe`；
  移动端只读→元信息准备 MM-F `ses_e5013c9d3ffefg7OEOuYNFbXhR`。
  四个均已 interrupt/idle，交互 CLI exit 0。Kimi `ses_e50141a47ffeOm5ID08gMmWRTU` 周额度耗尽，未产生修改；
  没有购买额度/改订阅。其它项目 OC 会话没有中断。
- 真实只读探测使用既有 trial session 的隔离副本：关注艺人 **33 位**；FM 3 首都有 album.picUrl，
  **全是 HTTP**；MusicBrainz Imagine / John Lennon 返回 **3 个同名候选**（自动选取需处理歧义）。
  仅验证接口返回，没有真实账号写操作，也没有把它冒充 GUI 封面验收。
- 停止时核对的 **4 个既有持久文件 SHA-256 全部不变**（普通/trial 会话、native/index 等实际存在文件，
  精确清单在 `profiles-before.json`）；未替换 dist、未清空设置/登录/音乐，未创建 /Applications 快捷方式。
  未 commit/reset，既有 staged/unstaged/untracked 修改完整保留。

### 可复现命令与收尾约定

工具链沿用项目本地 Rust 与完整 Xcode，不改全局 xcode-select。续做得到授权后：

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export CARGO_HOME="$PWD/.tools/cargo"
export RUSTUP_HOME="$PWD/.tools/rustup"
export PATH="$CARGO_HOME/bin:$PATH"
swift build --package-path native/macos --scratch-path .artifacts/swift-build
cargo test --manifest-path crates/alger-core/Cargo.toml
cargo test --manifest-path crates/alger-bridge/Cargo.toml
sh scripts/test-swift.sh
bun run typecheck
bun tests/playlist-dialog-acceptance.cjs
bun tests/player-acceptance.cjs
```

**本轮按用户要求不清理。** 完成后续全部开发、验证、必要安装及文档后，再运行
`sh scripts/clean.sh` 作为最后维护步骤；它会删除当前保留的 `.artifacts/` 与生成构建目录，
所以有必要的交接结论先写入 DEV/README，不能只留在会被清理的日志中。


## 最新试用反馈修订：扫描入库、即时设置与简化界面（2026-11-06，Asia/Shanghai）

用户本轮明确优先修复“扫描后歌曲/专辑/艺人全空”，其余反馈也一并落实。本段覆盖下方历史UI/添加默认目标与手动保存设置的描述。

- **扫描根因与修复**：Rust 发送原始 TrackMeta 扫描事件，AppModel 旧事件分支直接忽略，ScannedTrack 旧解析还只认 entry 包装。新增 `LibraryScanner`，独立订阅扫描事件、不覆盖下载监听；等完成响应及串行事件回调排空后，核对事件数并一次事务提交索引，再刷新歌曲/专辑/艺人和最近本地。兼容原始/旧包装，保留既有来源关联；根目录不可读、事件缺失、索引写失败均报错。旧重复路径索引归并而非崩溃。
- **实测**：真实桥接扫描带中文路径/标题/艺人/专辑的 WAV，验证歌曲/专辑/艺人、重开索引、未变化重扫及旧重复路径。隔离 GUI 从空库点击扫描，3 个真实音频立即落盘并展示。无需重置任何用户数据；升级后重新扫描原目录即可补建此前漏掉的索引。
- **提示**：Toast 独立浮层、毛玻璃与轻阴影、按类型自动消失/可关闭；不参与内容布局，提示出现/消失不挤压顶部、不跳高度。
- **首页**：真实封面、FM 大卡与横向卡片短预览，分区可展开；网络用专辑封面，本地异步读取内嵌封面并按文件戳缓存，无封面才显示占位，不伪造内容。
- **添加交互（最新规格）**：曲目仅一个 `+`，单击默认加入 **临时播放**，不再默认加到当前播放歌单。右键/左键长按打开同一原生 context menu，选择具体本地/网络歌单；本地目标仍先下载后入单。整个应用“播放队列”改称“临时播放”，“远程歌单”改称“网络歌单”，持久键/枚举不变。隔离 GUI 已验证单击只加一项、右键和长按都出菜单、开菜单不误添加。
- **侧栏**：主页在资料库组上方；本地/网络歌单用与资料库一致的无图标文字分组标题，保留折叠；两类歌单条目统一图标。左下账号与侧栏连通，播放条仍固定悬浮玻璃胶囊。
- **设置**：随改随存，无统一保存按钮。控件/目录立即提交，文本防抖/回车/失焦提交；串行合并快速修改，只提交变更字段，载入不写，未知会话基线不覆盖音质/音源，失败明确可重试。设置落盘后刷新相应UI。隔离 GUI 实测切换自动保存开关后 `native.json` 已立即写入 false，无需保存按钮。

验证：最终 Swift 全量 **232 / 0，exit 0**；扫描增补重复路径回归定向 **3 / 0**；自动保存协调器+既有设置定向 **24 / 0**。应用构建、隔离扫描/首页/Toast/侧栏实看及单击/右键/长按交互通过。GLM Flash 独立只读复核认可事件排空/先落盘后返回/错误可见/合并保护；其提出的旧重复路径崩溃已修，定向已复跑。

OC：设置 MM Flash `ses_e505a5357ffekKYfVcQWXLFH4U`；首页/Toast MM M3 `ses_e505a4ecaffertFH4s5q53pAeP`；扫描只读复核 GLM Flash `ses_e50530807ffemQC6uXEdmB5KKL`。均 succeeded，交互 CLI 已结束；主代理负责扫描根修、共享加号、侧栏及GUI集成验收。无真实音乐删除/标签覆盖、无真实账号故障写入。

后续边界：扫描尚不自动移除磁盘外部删除的幽灵索引；极大曲库超过 600 秒的取消/重试流隔离，以及深层目录权限错误汇总仍待完善。本轮主问题不依赖这些后续能力。**本轮试用版已更新**：`sh scripts/install-dist.sh` exit 0。最终 `dist/AlgerMusicPlayer.app` release 签名、显示名、trial 身份校验与隔离启动/正常退出通过；安装前后核对 8 项现有 profile 文件 SHA-256 全部不变。安装清理成功，文档写回后再次执行最后清理。用户重开应用并重新扫描原音乐目录，即可补建此前丢失的扫描索引。

## 本轮修复与首轮试用验证（2026-11-06，Asia/Shanghai）

本轮按用户最新指令优先核心试用；下面旧段中的“播放仍失败 / 回执未修 / release 未验证”是历史状态。

- **播放已修**：本地 PCM 不再强制快速时长；网络流不可播放时回退资产选项；异步测试改用让出主 actor 的等待；加载失败显示错误；异步资产返回后再次检查切歌代次。仅真实网络流完整播放计数，本地优先命中不计。诊断用例已变成有断言回归。
- **添加回执已修**：远程不完整成员快照拒绝写入；失败/部分成功无撤回授权；只记录真正新增及实际副本 ID；撤回失败停止换目标。下载目标撤回持久保存，不被 Rust 旧 targets 复活，允许显式重新添加；下载完成及时补入本次新增回执。队列使用独立 entry ID 撤回，不误删相同歌曲的旧项。
- **核心体验**：关键词一改即作废旧搜索，先展示本地结果；退出登录保留最近本地；扫描提交旧索引基线，能发现外部修改；重复本地添加明确提示已存在。
- **最新 UI 要求已落实**：透明无标题窗口，仅左上系统窗口按钮、系统四角圆角；账号真实头像固定左下，无分隔线/独立底色，与侧栏连通；播放条为内容区底部固定悬浮玻璃胶囊，四周留空、细描边与轻阴影。操作按钮放内容区，不占系统标题栏。已用隔离 GUI 截图实看。
- **打包**：不可变文件的暂存副本可清理，失败保留归属标记；夹具严格拒绝认领无标记/活跃 owner 目录；chflags 不跟随符号链接。

验证：主代理最终 Swift **211 tests / 0 failures，exit 0**（包括真实播放、撤回/跨重启、队列重复项回归）；Rust core **139 + 7**、bridge **10 + 8** 全通过；打包事务 **82 / 0**；最终 UI 应用构建通过。真实 trial release 的签名、显示名、只读身份 JSON 验证通过；隔离 GUI 启动、包内桥接、正常退出通过。trial 会话隔离副本只读联调：账号、搜索 5 条、歌单 17 张均成功；没有真实账号远程写入、真实音乐删除或标签故障注入。安装前 6 项持久文件摘要保持不变。

OC 使用：MiniMax M3.1 Flash 负责播放与入单撤回，MiniMax M3 负责打包与独立核心复核；GLM 5.3 / Flash / Highspeed 均遇供应商连接中断，Kimi 周额度耗尽，OpenCode 免费模型达到免费额度限制。未购买额度或修改订阅。会话：播放/入单 `ses_e508520d1ffeYzs3Uq5szvbTi4`，打包/复核 `ses_e50846a63ffe8Ph6XAvpomuDkl`；两者已 succeeded，交互 CLI 已结束。

**本轮已安装原生首轮试用版**：`sh scripts/install-dist.sh` exit 0；最终 `dist/AlgerMusicPlayer.app` 的签名、显示名、trial 身份验证全部通过，包内桥接启动与定向正常退出通过。唯一入口与 identifier 保持，安装后核对 4 项既有 profile 文件 SHA-256 全部未变。安装脚本清理 exit 0，文档写回后再运行最后清理。后续迭代优先收集试用反馈：真实网页登录、远程歌单写入与大量条目操作、持续网络播放/下载恢复；推荐覆盖、元信息实网封面/AcoustID、移动端继续独立推进，不再要求辅助功能全部验收才允许核心试用。在线 PCM 回退可能等待完整文件加载，渐进播放性能尚未量化。AppModel 的 GUI 编排仍需继续补集成证据。

## 当前执行优先级：核心可用后开放试用（2026-11-06，Asia/Shanghai）

用户已重新授权接手续做，并调整交付策略：**先完成重点功能并允许试用，辅助功能与试用反馈中的 bugs / improvements 后续迭代。** 本段取代下方历史交接中的“现在不得恢复开发/安装”与“E2～E7 全部完成才能试用”；历史失败与数据保护约束仍然有效。

- 首轮重点：原生应用启动与退出、统一搜索、本地/网络实际播放、队列与本地 M3U8 歌单、已有账号与远程歌单读取、下载及失败重试/入单恢复、设置保持与持久数据兼容。
- 试用前必须关闭：真实播放失败、远程添加回执误撤回已有成员、包身份与验证后替换；发现的确定性数据损坏/丢失、假成功问题同样先修。验证使用隔离夹具，不对真实账号做故障写入。
- 后续迭代：推荐覆盖与艺人/专辑细节、元信息在线匹配/封面/指纹的完整实网验收、辅助体验打磨及移动端。未验收的辅助能力明确标注，不冒充完成，不阻塞已验证核心试用。
- 用户要求充分利用 OC 中有效模型：采用交互 CLI，并按互不重叠任务分工实现、修复与独立复核；供应商额度耗尽时转给仍可用模型，不购买额度或变更订阅。
- **原生首轮试用版已安装，结果见上段**。持久入口为 `dist/AlgerMusicPlayer.app`，所有旧/普通/trial 数据保持。

## 最新交接：用户要求额度耗尽收尾，E2～E7 仍未交付（2026-11-06，Asia/Shanghai）

**用户最新指令是停止推进、收尾，待额度重置后继续。现在不得恢复开发或安装。**
本轮已按多模型/多 OC 会话推进大量源码，E4/E5 原生初版与 E6 脚本均已落盘，
但全量测试及应用审查仍有阻塞，**禁止将当前原生初版替换长期可用试用版**。
下方旧交接中“E4/E5/E6 完全未做”已过时；下文是历史记录，以本段为准。
本轮没有关机授权，没有安排关机。

### 已落盘的主要内容

- **E2/E3 主应用**：`AppModel`/原生视图已扩展统一搜索分页与过期结果处理、离线最近本地、
  艺人/专辑详情、当前播放歌单的加号目标及更改、队列另存、远程描述/删除/曲序、
  本次会话下载入口、失败入单重试等；仍需逐项 GUI/权限验收，不称完整完成。
- **原来两项 P1**：下载失败结果汇总与设置基线的源码复核已通过。
  `DownloadIntake` 持久化逐目标意图/确认/撤回，`SettingsDraft` 保序并拒绝未知基线覆盖；
  歌单注册项记录真实目录，改默认目录不使已有歌单内容消失。
- **E4 初版**：`AutoSaveService` 的次数/阈值/去重/持久失败与立即重试，
  `TrashService` 的先日志、真实 trash、索引与多 M3U8 协调恢复已接应用。
  真音频完整播放测试失败，**自动保存计数端到端未验收**。
- **E5 Rust**：`metadata.rs` + `meta.search/lookup/release/artwork/fingerprint/cancel`，
  MusicBrainz 实际时刻限速/缓存/取消、CAA、fpcalc 有界执行与缺配置错误。
  `tags.rs` 扩展 AIFF/WAV 来源 ID、标准 ISRC/MBID/date、Front 封面与明确 0 清除。
- **E5 Swift**：`MetadataModels/Service/SettingsStore/ApplyService`、编辑器及真实入口，
  手动离线编辑、录音/发行选择、字段差异确认、封面预览、取消、0600 配置、
  选中字段/封面字节基线与写后实读校验；失败不回调成功。
- **E6 脚本**：`build-native.sh`、原生 `install-dist.sh`、带 `--app` 的 GUI 试跑、
  `quit-native.swift` 精确 PID 退出、Resources/Info.plist、65 项打包夹具。
  真实安装**未执行**，当前 `dist/AlgerMusicPlayer.app` 仍为旧可用版。

### 下一次必须先修的阻塞（本轮尚未关闭）

1. **真实播放在 XCTest 中失败。** 首轮 Swift 全量 **197 tests / 14 failures（2 unexpected）**；
   其中 9 个断言属于真实播放。转本机 HTTP 与运行循环诊断后，播放定向又为
   **7 tests / 12 failures，exit 1**，不能删测试、伪造结束通知或直接 skip。
   `AVAsset.load` 诊断报 **AVFoundationErrorDomain -11800 / NSOSStatusErrorDomain -17770**；
   `AVPlayerItem` 加载失败/时间为 0。**独立命令行 AVPlayer probe 能推进时间，status=1**，
   说明不能直接断言是音频格式不支持或整个 App 都无法播放，需定位 XCTest/资源加载/运行环境差异。
   `PlaybackAudioDiagnosticsTests` 只是打印诊断的临时调查用例，曾显示 passed，
   **不是播放验收通过证据**。保留源以续查，后续转为有断言回归或移回临时诊断脚本。
2. **远程加号回执可能误撤回旧成员（新 P1，未闭环）。** 独立复核发现原
   `addRemoteSongs` 失败仅 banner，而调用方无条件生成 `remoteAddedSongIds` 回执；
   “更改目标”随后 `removeTracks` 可移走本来已存在的条目，另存副本的 target 也可能错位。
   停下前新增 `RemotePlaylistService` 并接了部分分支，**不是全部修完**：
   `AppModel.changeAdditionTarget` 仍在 `await addRemoteSongs` 后无条件记录 `[song.id]`。
   下一次须全分支消费 success/partial/failure 与实际副本 ID，仅明确本次新增可撤回。
   新服务虽读取 `playlistDetail`，**未拒绝 `missing > 0` 的不完整成员快照**，也需修。
   补“原已存在 + 请求失败 + 更改目标不 remove”确定性假桥接回归；不对真实账号做故障写入。
3. **真实 release bundle 验证未通过。** 本轮 `build-native.sh --trial` 的 Rust/Swift release
   编译成功进入包验证，但 `--print-runtime-identity` 输出 `(Function)`，被校验正确拒绝。
   停下前已把 `main.swift` 改为 `RuntimeIdentity.json()`；最后 debug 增量构建 **exit 0**，
   实际执行参数已输出合法 JSON（普通 debug、trial=false），**没有重跑 trial release 包验证**。
   不得把该窄项修复当作 bundle/安装完成。

### 通过的检查与证据边界

| 范围 | 本轮真实结果 |
| --- | --- |
| core / bridge 全量（最后数值 0 修复前） | **139 / 18** 通过（bridge exit 10 + metadata 8） |
| 最后 tags 数值 0 修复后 | tags **12** + 六格式集成 **7** 通过，fresh bridge build exit 0 |
| core/bridge fmt 与 clippy all-targets `-D warnings` | 四项 **exit 0**（两处既有测试 lint 各改一行） |
| Swift Metadata 最后定向 | **61 通过 / 0 失败 / 0 跳过，exit 0**，含真实标签桥接 5 项 |
| 打包事务夹具 | **65 通过，exit 0**；作者及独立复核均复跑 |
| 最后冻结后 Swift 增量应用构建 | **exit 0，4.98 秒**；不替代仍失败的全量 tests |

标签六格式是 MP3 / FLAC / M4A / Ogg Vorbis / AIFF / WAV；音频保留断言是
**ffmpeg copy packet SHA256**，Swift MP3/FLAC 另有解码 PCM 摘要校验。
真实回归发现 track=0 被忽略，已改为 track/disc/year 的明确清除语义，未放宽 Swift 写后核验。
最后此窄项已有实桥回归，但还需最终全量与独立 delta 复核；不宣称全部冻结验收完成。

真实只读联调使用 trial 会话的 `.artifacts` 副本：账号、搜索、FM、歌单列表/完整详情、
专辑详情、心动模式成功；`artistNewWorks` 已成功返回空 works（**不等于真实新作展示验收**）。
MusicBrainz Imagine/John Lennon 查询成功返回 2 候选；另一次 Beatles 查询 HTTP503，保留失败事实。
CAA 实网封面、AcoustID 实网指纹未验收；无真实 key，PATH 无 fpcalc，UI 须明确提示缺依赖。
没有真实账号的远程歌单写入验收，没有真实用户音乐的删除/标签故障注入。

### 其它待复核与接续步骤

- 首轮另外的失败包括 Metadata track0（已修且 61 项定向通过）、
  AutoSave 的旧断言与 DownloadIntake 坏目录断言（作者修改过，**未全量重跑确认**）。
- 预审还有：副本已建但加曲失败必须说明已创建；退出登录后 recent 被清空；
  重复本地添加不应称新增；自动保存重试失败的错误归因。主作者停下前可能改了部分，
  恢复须按当前源码核对，不沿用报告旧行号。
- 两组歌单的完整排序/删除/另存、更改目标撤回、只读所有权、跨重启任务语义、
  艺人/专辑细节等仍缺完整 GUI/集成证据。不能仅凭方法存在标为产品完成。
- E7 完整原生实现最终独立审查未完成；本轮只做 tags、E6、E2～E4 部分预审。
  E2～E4 报告先前误称检出没有 Rust，主代理已纠正：源码就在 `crates/alger-bridge/src/main.rs`
  与 `crates/alger-core`。未跟踪文件同样能 hash；它未采样读取前版本是证据缺口，不能称无法采样。

恢复顺序：重新读取额度 → 真实播放诊断/剩余测试修复 → 完整关闭远程回执 P1 →
冻结后全量 Swift/Rust + 独立 delta 复核 → 原生 trial release/身份/GUI →
确认全部必修与产品缺项关闭后 `sh scripts/install-dist.sh` → 最后 `sh scripts/clean.sh`。
**用户明确要求待重置后继续，现在不要自动恢复。**

### 会话、数据与收尾

- 主流程 MM-F：`ses_e51b3dd56ffeaDtbw1VHU48zjR`；应用预审 GLM-F：
  `ses_e5191239bffelgHzlgwAmjM2cz`。用户停止后已 API interrupt，确认 outcome=interrupted/idle，
  两个交互 CLI **exit 0**。主流程代码完整落盘并可增量编译，但修复逻辑未闭环。
- Rust metadata MM-F：`ses_e51ad3156ffeURPj81zxAz2b1e`；tags MM-F：
  `ses_e51aef890ffeYdkfrHyOszvlpR`；tags GLM-F：`ses_e519bf525ffepyvEwF1g4RSHkZ`。
- Swift Metadata MM-F：`ses_e51aec7dcffevmMTZUMl5cL1NZ`；Fake bridge GLM-F：
  `ses_e5193dc07ffeogbu0VKUIKiJDo`；初稿 GLM-F `ses_e51b41654ffet904xIy4HuLujN` 已取消。
- E6 MM-F：`ses_e51af4b14ffeqzDIvdM0ZMAAq5`；GLM-F：`ses_e519d916bffeRv7ZDD6Hk7P2Wm`。
  K4C `ses_e51b45a9bffeaXJF8u4NZMMXHH` 供应商额度失败；GLM Rust 尝试
  `ses_e51b39c7fffeO8NlgCTqc19KOD` 与 E6 初稿 `ses_e51b4710fffe8NRsqATTFRz4oj` 已取消。
  主代理逐一检查以上 **13 个会话均 idle**；三名协调子代理均已结束，未留后台写者。
- **OC mini 的 `/exit` 只关前端，不保证后台停止。** 切模型/收尾必须 API interrupt 或确认
  succeeded/idle 后再退出。可用 `opencode api POST /api/session/<id>/interrupt`，再 GET 核对 data.time.idle。
- 诊断时曾误写裸 `/tmp` 的 6 个已知路径（wavgen/avprobe 相关），已只按本轮归属搬回 `.artifacts`，
  原路径全部不存在；未扫其它 `/tmp`。后续诊断必须遵守 AGENTS 的路径/标记规则。
- 停下后核对最初 10 个持久文件指纹 **全未变**；无项目生成可执行程序仍运行。
  未运行 install-dist、未替换 dist、未建 `/Applications` 快捷方式；未清除/重置任何真实资料。
  未提交、未重置 Git；既有暂存/未暂存修改全部保留。临时报告最终由 clean.sh 删除，
  必须续做内容已摘录在本段，可按上述 OC ID 追查。

本轮最后清理首次因打包故障夹具复制出的 5 个 `Resources/locked` 带 UF_IMMUTABLE 失败。
仅核对本轮 `.artifacts/native-delivery/install/alger-install-stage.*` 内的固定路径、当前 UID、
普通文件及内容 `locked\n` 后清除该位，未改其它文件/权限，随后重跑 clean.sh。
恢复时须修 `tests/native-packaging-acceptance.py` 的副本清理 RAII：它目前只清原夹具，
没有覆盖 installer 复制到 stage 的不可变文件，65 项通过不代表残留已清完。


## 最新交接：E2/E3 初版已落盘，独立复核仍有两项 P1（2026-11-06，Asia/Shanghai）

**本轮未完成 E2～E7，禁止交付当前原生版本。** E2 已有可构建的原生应用初版，
E3 已接通部分网络代码路径；下方作者阶段报告中的“完成”仅指代码已落盘，
不等于产品验收。E4/E5 的原生集成、E6 打包安装及 E7 最终审查仍待继续。
已做的 GLM-F 复核仅覆盖本轮 E2/E3 初版，不是完整 E7 验收。

### 执行、额度与验证

- MM-F 实现：`ses_e51d675ddffen5ddcoyhfu7DIQ`，产品源码完整落盘，交互 CLI **exit 0**。
- GLM-F 独立只读复核：`ses_e51c01689ffeQGdv9ullANcqE4`，交互 CLI **exit 0**；
  40 个冻结文件 SHA-256 均不变，主代理另行用 Python 重算核对，零差异。
- 作者最终运行与独立复跑 `sh scripts/test-swift.sh` 均 **100 通过 / 0 失败 / 0 跳过，exit 0**。
  Swift 应用构建 exit 0、无告警；隔离 GUI 12 秒试跑 exit 0。GUI 存活证据不代表点按、
  真音频播放、登录或下载入单端到端验收。
- 主代理只读联调采用 trial 会话的 `.artifacts` 副本；账号读取、搜索、私人 FM 成功，
  关注艺人新作返回 **Network**，尚未定位。没有对真实账号做远程歌单写入。
- 2026-11-06 **08:23:59 Asia/Shanghai** 只读额度工具返回 5 小时已用 **50%**、
  周窗口 **100%**。本轮据此收束开发并完成复核/交接；恢复时必须重新读取额度，不能沿用快照。
  未购买额度、未更改账户设置。**本轮没有关机授权，也未安排关机。**

### 下次先修的两个确定 P1（本轮未修）

1. **下载入单部分失败被成功消息覆盖。** `AppModel.swift:764` 的 `finishDownload`：
   多个 targets 中有失败、也有成功时，catch 设置的错误被末尾 `joined > 0` 的 info 覆盖；
   索引写入失败也可能被后续成功提示覆盖。Rust 合并同曲目 targets，使该场景可达。
   失败目标未登记为可重试入单操作。应汇总每个目标结果，保留失败及索引错误，
   不把部分成功显示为全部成功；增加持久待处理状态/确认机制与恢复回归。
2. **设置页静默覆盖现有音质与音源。** `Views/SettingsView.swift:141` 的 `load()`
   硬编码 `higher` 与三个默认音源；保存任意设置均把这两项提交给 session。
   应从真实 `SessionSnapshot.quality/sources` 回显、保持音源优先顺序，并只提交改动字段；
   失败前不显示“设置已保存”。用隔离会话中非默认设置补回归，确保只改目录不改其它设置。

上述 P1 是独立源码路径复核确认，**未构造动态故障注入用例**；100 项现有测试未覆盖它们。
不要将测试全绿当作 P1 已关闭。

### 其它续修点与审查边界

- **下载完成后的入单恢复**：启动 `dl.list` 不重放 done 事件；`dl.retry` 对既有 done
  返回 recovered 而不重发事件，所以现有“重试”不能补偿入单失败。重新执行添加可绕行恢复，
  但应补正式恢复路径与跨重启测试；不能只保留 targets 就声称完整恢复已验收。
- **离线首页**：未登录分支隐藏全部首页分区，`refreshHome` 清空 sections；
  “最近存入本地”必须独立于登录展示。
- **退出**：启动错误弹窗关闭后直接 `reply(toApplicationShouldTerminate:)`，
  没有挂起的 terminateLater，可能留下无窗口应用；这是源码推断，需隔离 GUI 复现。
  二次退出仍经 `applicationWillTerminate` 同步收束，并非不收束，但可能阻塞主线程数秒，
  不能宣称所有退出路径已验证为异步。
- **trial 构建**：E6 必须给 Swift 编译传 `-D ALGER_TRIAL`（或等效 Package 定义），
  并与 Rust `ALGER_TRIAL` 一致；当前没有原生 bundle 脚本来保证该条件。
  SwiftPM 本身支持传编译定义，不能将“尚未接入打包”误写为“无法构建 trial”。
- `AlgerEnvironment.locateBridgeBinary` 应在 URL 归一化前校验原始覆盖值的绝对性；
  目前相对路径检查恒过，风险低于数据目录隔离，数据目录校验已实修。
- 歌单任一文件读取失败时 `refreshLibrary` 的 `try?` 会把整组显示为空，需给出具体失败项；
  播放切歌解析期间旧声音与新 UI 状态可能不一致，也需实播验证。
- 尚缺：默认加到当前播放歌单及更改撤回、临时队列另存、艺人/专辑网络详情、
  远程歌单完整编辑与排序、下载任务跨会话显示语义、真实网络音频/登录/下载入单验收。
  E4 只存设置/次数，自动保存触发与废纸篓删除均未接；自动保存开关现无实际作用，交付前须接通。
  E5 原生匹配/封面/写标签尚未接入；既有 Rust 标签能力继续保留，AIFF/WAV 来源 ID 仍待实现。
  macOS 不应把 iOS 的 AVAudioSession 配置当作补齐原生播放的必需项。

### 现场与最后维护

未提交/重置 Git，既有暂存与未暂存修改保留。未运行 install-dist、未替换长期试用应用：
当前原生初版有 P1 且 E4～E7 不完整，不能覆盖现有可用版本。
主代理在测试与只读联调后核对初始 10 个持久文件指纹，均未变（含 dist、普通/trial 会话与索引状态）。
未访问真实资料库做写入，未创建 `/Applications` 快捷方式。
临时报告由最后 `clean.sh` 删除；追查细节用上面的 OC 会话导出。
恢复顺序：重新读额度 → 修复两个 P1 与入单恢复 → 补齐 E2/E3 验收 → E4 → E5 → E6 → E7。

## 最新交接：E2 原生界面与播放已成形，E3 部分成形（2026-11-06，Asia/Shanghai）

**本轮不是最终交付。** E2 基本成形，E3 只完成代码路径且关键路径未做真实验收，
E4 / E5 / E6 **完全未做**，E7 最终审查未完成；本轮初版已接受独立复核，结论以上方最新交接为准。
E1 三项已关闭，下面旧交接中的 E1 状态不再重复；后续 E4–E7 状态见本段末尾表格。

### 本轮落盘

- `native/macos/Sources/AlgerApp/`：**真实可执行目标**（AppKit 外壳 + SwiftUI 主界面）。
  `NavigationSplitView` 原生侧栏、首页、唯一搜索、本地歌曲 / 专辑 / 艺人、两组歌单、队列、
  下载、设置、底部播放条；主界面 **无 WebView**，`WKWebView` 只在 `LoginWindow.swift` 用于登录。
- `native/macos/Sources/AlgerKit/` 新增：`NativeState` / `NativeStore`（`native.json` 事务持久化）、
  `LocalLibrary`（索引 + 歌单注册表 + M3U8 贯通）、`BridgeService`（桥接类型化封装）、
  `PlaybackController`（AVFoundation 播放 + 队列）、`AlgerEnvironment`（桥接定位 + 隔离目录）。
- `native/macos/Package.swift`：新增 `AlgerApp` 可执行目标与 `AlgerMusic` 产物。
- `scripts/run-native-app.sh`：GUI 试跑入口，**显式**注入 `ALGER_APP_DATA_DIR`（仓库 `.artifacts` 内）
  与 `ALGER_BRIDGE_BIN`，跑完逐文件比对真实 profile 未变。
- 测试：62 → **100 项**（新增 `AppPathsTests` / `LocalLibraryTests` / `NativeStoreTests` /
  `PlaybackControllerTests` / `AlgerEnvironmentTests`）。

### 主代理抽查的四项已修

1. **隔离路径**：`ALGER_APP_DATA_DIR` 用 **原始字符串** 判绝对性；显式空值 / 相对路径 **拒绝启动**
   （不回落真实 profile）；隔离会话 `download_dir` 强制指向 `<隔离根>/Music`
   （Rust 新会话默认 `~/Music/AlgerMusic` 不再漏出）；隔离判据改为「数据根不在 Application Support 下」，
   普通版与试用版仍用真实 `~/Music/AlgerMusic`。
2. **身份关联**：`matchLocalTrack` 只接受 **准确来源 ID**（含 `fileExists`），删掉标题 + 艺人模糊匹配；
   其它关联必须走显式 `confirmAssociation`。
3. **播放状态机**：解析带 **代次令牌**（快速切歌旧结果作废）；停止 / 清队列作废在途解析并取消计数；
   **任何一次 seek 都取消本次播放的计数**。
4. **歌单部分失败**：同批条目去重；M3U8 写失败 → 抛错且内容 / 注册表不变、**不留**日志；
   删歌单 **先登记意图** → 删文件 → 更新注册表，中途失败留 `pendingOperations` **可恢复日志**，
   启动时自动修复并提示。

### 真实执行结果（退出码为真）

| 检查 | 结果 |
| --- | --- |
| `swift build --package-path native/macos` | **exit 0**，**0 warning** |
| `sh scripts/test-swift.sh` | **exit 0**，**100 通过 / 0 失败 / 0 跳过** |
| `sh scripts/run-native-app.sh --seconds 12` | **exit 0**：应用存活、1 个桥接子进程、会话 / 索引 / 状态 / 下载队列全在隔离目录内、隔离 `download_dir` 指向 `<隔离根>/Music`、**真实 profile 逐文件比对未变** |
| 主代理只读探测（trial 会话的 `.artifacts` 隔离副本） | `net.account` 成功、`net.search` 成功（2 首）、`net.personalFm` 成功（3 首）；**`net.artistNewWorks` 失败（Network）**；结果在 `.artifacts/readonly-net/results.json`，不含凭证 |

### 明确的缺项（不得当作已完成）

- **E2**：没有 `.app` 包（属 E6）、`dist/AlgerMusicPlayer.app` 未替换；未做人工 GUI 交互验收；
  扫描只用真实 WAV 夹具、未跑真实 MP3/FLAC/M4A 曲库全链路；网络播放未做真实音频与续播验证；
  「加号默认加入当前播放歌单」尚未实现（现在是列出全部本地歌单）；无歌词 / 封面 / 音频会话策略。
- **E3**：真实网易登录 **未端到端验收**；**`net.artistNewWorks` 真实失败未定位**（UI 已显示具体错误，
  **不得**称其验收成功）；歌单电台 `net.intelligenceList` 未验收；远程歌单权限分支（可编辑 / 只读另存）
  无真实账号证据；**「持久下载成功才入本地歌单」没有真实下载证据**；搜索未验证分页 / 空结果 / 限流。
- **E4 自动保存 / 废纸篓 / 删除操作日志：完全未做**（只持久化了设置项与播放计数）。
- **E5 元信息：完全未做**（MusicBrainz / Cover Art Archive / 标签写回 / AcoustID 一项都没有；
  Rust `tags` 模块本轮未被 Swift 调用）。
- **E6 交付：完全未做**（无打包脚本、未接 `install-dist.sh`、未换图标 / 显示名 / 生命周期验证）。
- **E7 独立审查：未开始**。

### 给 E4 / E5 / E6 的接口

`NativeStore`（设置 / `playCounts` / `pendingOperations`）、`LocalLibrary`（歌单全写操作 + 可恢复日志）、
`LibraryIndex`（移除不删音频）、`BridgeService.dl.enqueue(targets:)`（目标为本地歌单稳定 ID，Rust 侧持久化）、
`AppModel.finishDownload(_:)`（下载落盘后写 M3U8）、`PlayerController.onCompletedRemotePlay`
（只计完整网络播放）、`scripts/run-native-app.sh`（GUI 试跑入口）。

### 现场保护

未提交 / 未重置 Git，既有暂存 / 未暂存修改全部保留；**未运行** `install-dist.sh`、**未运行** `clean.sh`；
`dist/AlgerMusicPlayer.app` 保持上一版可用试用版；真实 profile 与 trial profile 本轮均未被写入。

## 最新交接：E1 并发边界已关闭（2026-11-06，Asia/Shanghai）

**本轮完成 E1 必修边界闭环，允许进入 E2；原生 macOS 应用尚未交付。**
下方旧交接中“三项 E1 必须续修”的状态由本段取代，其余产品规格继续有效。
E2–E7 尚未完成，保留本 DEV；不要将基础库测试通过等同于完整应用验收。
2026-11-05 的额度、停止与关机段落是历史现场，本轮没有安排关机。

### 已完成的修复

1. **保存基线不再吸收外部更新。** `AtomicFile.writeContents` 返回提交指纹，
   由实际提交字节及同一临时 fd 的 `fstat` 构造，保存方不再于 rename 后重新采集路径。
   `FileReader.snapshot` 从同一个 fd 读取内容和身份，采用非阻塞打开并拒绝非普通文件，
   避免 FIFO 在文件类型检查前阻塞。索引及 M3U8 都已接入。
   回归精确在 rename 后、更新内存基线前插入外部改写，验证下一次公开保存报冲突且外部字节保留。
   作者将基线临时改回旧逻辑时，两条回归均失败；实验后恢复修复版本。
2. **stdin 写入与关闭由同一所有者协调。** 新增 `StdinWriter`，使用非阻塞写入、
   短 poll、单调时钟截止时间及关闭取消；写与 close 在同一串行队列上执行。
   `BridgeClient` 自建 RAII 管道并明确移交端点所有权，避免 FileHandle 析构二次关闭复用的 fd。
   非阻塞 / SIGPIPE 抑制设置失败会显式抛错；所有启动失败路径回收端点并使读线程退出。
   真实回归覆盖管道背压、16 个请求并发关闭、fd 复用哨兵、无关 fd 保活、SIGPIPE、
   隔离子进程内重复启动失败和重复正常启动 / 关闭后的 fd 与读线程回收。
3. **索引 / M3U8 增加协作式跨进程写事务。** 新增 `CooperativeFileLock`，
   常驻同目录 `.lock` 文件，拒绝符号链接、不截断、校验普通文件及 inode/dev，
   使用单调时钟有界取锁、幂等 RAII 释放。排他锁覆盖基线检查至 rename 完成；
   保存方随后使用提交指纹更新基线，不吸收别人的后续提交。
   clang 编译的真实子进程夹具验证锁竞争、竞争者提交后的冲突、软链锁拒绝和锁内容保留。
   作者将锁改为错误 sidecar 后，竞争回归按预期失败。

附带完成：`scripts/test-swift.sh` 每次都增量构建当前 Rust 桥接，避免运行旧二进制。
Rust 的 8 处权限故障夹具改用 RAII 恢复权限（dlq 5 / tags 1 / session 2）。
独立复核发现测试删除夹具时守卫仍存活、以及 7 处遗留未使用导入；主代理已补显式释放后再删除，
并让删除失败直接令测试失败，同时移除这些导入。该收尾仅修改测试，未改冻结后通过审查的 Swift 实现。

### 执行与独立复核

- MM-F 实现 / 自检：`ses_e520afab7ffeEvL2bPqJSnygG2`，完整落盘，交互 CLI exit 0。
- K4C 只读审查尝试：`ses_e51ea1f03ffekpMk062s8A7qhf`，读取源码后因供应商周额度失败，
  **没有形成审查结论**；交互 CLI 已退出（exit 0），没有购买额度或更改账户设置。
- GLM-F 独立只读复核：`ses_e51e79fc8ffecHXzzxmoMj6cm5`，
  **三项 E1 必修全部实质关闭，可进入 E2；未发现确定性 P0/P1 产品缺陷。**
  复核时 17 个冻结文件摘要全部一致；审查没有修改产品源码。交互 CLI 已退出（exit 0）。

| 检查 | 本轮结果 |
| --- | --- |
| 修改前 Swift 基线 | 40 项通过 |
| `sh scripts/test-swift.sh` | 作者及独立审查均 **62 项通过**，Bridge 26 / Index 19 / Playlist 17，0 失败 / 0 跳过；新鲜 Swift 构建 0 告警 |
| `REQUIRE_FFMPEG=1 cargo test --manifest-path crates/alger-core/Cargo.toml --lib` | 独立复跑 **107 通过**，真实 ffmpeg 夹具，0 失败 / 0 忽略 |
| bridge `--test exit` | 独立复跑 **10 通过** |
| Tauri `--lib` | 独立复跑 **67 通过** |
| 独立运行隔离 xctest 泄漏检查 | exit 0，真实执行 fd / 读线程回收检查 |
| 三个 Rust manifest 的格式检查、脚本语法及改动文件空白检查 | 通过 |

Rust 测试告警及守卫释放顺序收尾后，主代理以 `REQUIRE_FFMPEG=1` 复跑 core 107 项、
并复跑 Tauri 67 项，均 exit 0，编译告警清零；8 处夹具删除断言均通过。
临时报告和日志位于 `.artifacts/`，会按约定由最后的 `clean.sh` 删除；必须续做的信息已摘录在本段。
需要追查详细执行证据时，使用上述 OC 会话导出，不依赖被清理的临时文档。

### 保留限制与下一步

- flock 仅约束遵守相同 sidecar 的写者；普通其他播放器仍可能在检查与 rename 之间写入。
  外部指纹检测保留，但不是通用文件 compare-and-swap；不要宣称能排除所有非协作写竞争。
- sidecar 常驻；取锁默认最多 5 秒，失败需要提示用户，不能显示已保存。
  SHA-256 仍每次读取整文件；目录 fsync 为 best-effort。
- `deinit` 仍可能执行数秒的有界 shutdown，E2 要设计显式异步退出路径，避免阻塞主线程。
  终态由 EOF / 子进程退出引入时，被拒请求仍可能排入一次无害写并以 EPIPE 失败；请求不会重复结算。
  并发关闭测试的精确 16 次计数仍有 300ms 登记时序前提。
- M3U8 写回统一 LF，不保留 BOM / 未知注释；稳定歌单 ID、标题 / 描述产品联动待 E2/E3。
  Rust session 仍仅有进程内事务锁，本轮只为 Swift index / M3U8 加了跨进程锁。
- **下一步 E2**：创建真实 `AlgerApp` 目标，实现 SwiftUI/AppKit 原生侧栏、首页、唯一搜索、
  本地歌曲 / 专辑 / 艺人、两组歌单与队列；AVFoundation 本地优先播放、暂停 / 跳过 / seek。
  接通真实扫描 / 索引 / M3U8，测试与 GUI 试跑必须显式使用 `.artifacts` 隔离资料目录。
  之后按原规格推进 E3 网络 / 下载、E4 自动保存 / 废纸篓日志、E5 元信息、E6 bundle / 安装和 E7 最终审查。

保留全部既有暂存 / 未暂存修改，未提交、未重置；没有访问真实资料库做写入。
接手时记录的 5 个应用 / 会话文件字节摘要保持不变。未运行 install-dist、未替换持久试用版：
当前仍只有 AlgerKit 基础库，没有原生 UI / 播放 / app bundle，不能覆盖现有可用应用。

## 历史交接：额度保护收尾（2026-11-05，Asia/Shanghai）

**原生 macOS 改版仍未完成，不得标为交付。** 本轮已停止新增开发，保留可续做源码与测试；下方上轮交接保留作历史规格，其中旧的 R1–R6 未关闭描述已由本段的新验证结果取代。

用户要求继续推进，完成后关机；若 5 小时额度无法支持完成，则在耗尽前停止开发，完成交接，等待本轮全部 OC 执行 / 审查会话结束并清理后关机。不得把额度停止当成任务完成。本轮最后复查（20:59）的只读额度快照为 5 小时已用 **87%**、周窗口 **92%**，本窗口重置时间为 2026-11-05 23:48:58（Asia/Shanghai）。剩余额度不足以完成 E2–E7，按用户要求在耗尽前交接；恢复必须重新读取，不能沿用快照。系统控制接口只读检查已通过；关机只在全部 OC 结束、最后清理后安排。

### 当前会话

- K4C 首轮实现：`ses_e54abb38cffekc2at8kfUpPd7D`，已完整落盘并退出 CLI（exit 0）。
- MM-F 独立审查及返修：`ses_e547739b9ffetGmskFf5i2iGlj`，先确认 10 项必须修，再实施修复，已完整落盘并退出 CLI（exit 0）。
- GLM-F 最终独立只读复核：`ses_e545d1ffaffeEr88KmEJzykZEL`，**通过，可进入 Swift E1，未发现确定性可复现 P0/P1 阻塞**；已退出 CLI（exit 0）。审查时源码冻结，没有两位作者并行修改源码。
- MM-F Swift E1 实现：`ses_e5457a602ffeXf47NcTkmdEjM9`，已完整落盘并退出 CLI（exit 0）。
- GLM-F Swift E1 只读复核：`ses_e54400a66ffe1uoh7ontWij4gb`，复跑 40 项通过；其初稿将下述基线 / FD 竞态降为低风险，**主代理不同意该评级，要求先修后再接真实资料库，E1 不算完整验收**。报告已修正并保留主代理否决评级与必修项；未再改产品源码，已退出 CLI（exit 0）。

### 已关闭的 E0 问题与证据

会话更新现已事务化；登录提交、客户端身份与 generation 串行切换；启动校验 / 失效清理按旧身份条件提交；两端注销使用捕获的旧 Cookie。下载目录选择只更新对应字段。损坏 session / dlq 备份为唯一 create_new、0600，不跟随链接、不覆盖旧备份。前端已消费 session://check，快照 loadIssue 可见。

下载队列使用进程内事务锁 + 有界 flock + RAII，初始载入 / 恢复 / 基线 / 落盘在锁内；锁文件不截断且拒绝符号链接，冲突令牌含 inode / dev。reserve / clear / mutate 失败精确回滚，回调在锁外；clear 不丢运行中任务。音频准确路径、完整大小与内容摘要在无覆盖落位前保存；真实 done 写失败可由公开 dl.retry 先本地验证恢复，不依赖网络解析。退出关闭入口、逐请求结算、有界取消 HTTP / 暂停下载、保留 targets，writer 等待有上界。CLI 会话路径缺值 / 空值 / 相对路径会拒绝启动，不回落真实 profile。

| 检查 | 最终结果（GLM-F 独立复跑） |
| --- | --- |
| `REQUIRE_FFMPEG=1 cargo test --manifest-path crates/alger-core/Cargo.toml --lib` | **107 通过，无跳过，真实 ffmpeg 夹具** |
| `cargo test --manifest-path src-tauri/Cargo.toml --lib` | **67 通过** |
| `cargo test --manifest-path crates/alger-bridge/Cargo.toml --test exit` | **10 通过**，包含真实在途 HTTP 下载退出与真实 dl.retry 离线恢复 |
| 前端类型检查；播放 / 歌单交互；cleanup acceptance | 通过；播放 4 项、歌单 16 项 |
| core / bridge 构建告警 | 0 |
| 主代理额外退出探针 | 排队退出重复 12 次通过；3000 hello + shutdown、stdin 保持打开、stdout 全程不读，exit 0 / 3.587 秒，writer 2 秒上界生效 |

PRIV 二进制帧、封面字节保留和真正 with_safe_write 冲突取消已补回归。MP3 / FLAC / M4A 多格式真实往返通过。**AIFF/WAV 来源 ID 写入目前明确拒绝且原文件零改动**（有真实夹具回归），仍需 E5 容器专用实现，不得宣称支持。ffmpeg 缺失有 SKIP 标记，验收须用 REQUIRE_FFMPEG=1 防止缺依赖误报。

保留的低风险限制：有效 --session-path 后的尾随未知参数仍忽略；重下回退使用当前下载目录；Responder.answered 长驻集合未回收；旧 intent 无摘要不认 done、保留旧文件后重下；FNV-1a 64 位是内容证据令牌而非密码学保证。

### Swift E1：可构建和测试，但仍有必须续修的边界

已重写 BridgeClient / LibraryIndex / PlaylistFile，新增 AtomicFile 与 XCTest。Package 仅保留真实 AlgerKit 库及测试，移除了不存在的 AlgerApp；没有占位 main、没有原生 UI、没有 AVFoundation 播放或原生 app 包。

`sh scripts/test-swift.sh` 构建真实 bridge 并注入 ALGER_BRIDGE_BIN，Swift 测试会话均用显式 --session-path 指向 .artifacts；完整 Xcode 的 DEVELOPER_DIR 只在命令内设置，未修改系统 xcode-select。AlgerKit 构建 exit 0 / 0 warning，**40 项 XCTest 通过（Bridge 19 / Index 10 / Playlist 11）**，作者连续三次及 GLM-F 独立复跑均通过。桥接测试覆盖并发配对、超时/取消/EOF/异常退出、shutdown 在途结算、真实 EPIPE、子进程回收；索引与歌单覆盖写失败、外部创建/删除/改写、重启、中文空格/BOM/CRLF/跨目录相对路径、移除不删音频。

已实修的关键问题：continuation 类型和重入死锁；Swift Character 分割 CRLF 导致空歌单；子进程断管令 xctest 被 SIGPIPE 杀死（改为自有 fd 的 F_SETNOSIGPIPE + write(2)）；shutdown 终态提前设置造成请求挂住；父端点关闭前核对 inode 归属。测试通过不代表下列边界已覆盖。

**下次先关闭这三项，再进入真实资料库 / E2，不能沿用“全部安全、可以无条件进入 E2”的审查初稿：**

1. **保存成功后基线吸收外部改动，可静默丢更新。** `LibraryIndex.swift` 的 mutate/save 成功后（当前 167、199 行）与 `PlaylistFile.swift` 保存后（187 行）重新 `FileFingerprint.capture(fileURL)`。若外部在自己的 rename 之后、重取基线之前改为 B，内存仍是 A、基线却成为 B，下一次基于 A 保存可覆盖 B 而不报冲突。这不是只能多报冲突的安全方向。建议基线由本次提交字节与自己写入的临时文件身份生成并返回，外部修改不得被吸收；补确定性插入外部写的回归。
2. **shutdown close 与 writerQueue 在途 write 的 fd 复用竞态。** `BridgeClient.swift` 当前 performShutdown 在调用线程关闭 stdin 写端（344 行），writeToChild 在独立 writerQueue（653 行起）。必须从客户端内部协调写入与关闭、明确 fd 生命周期；“在 UI 主线程串行调用 shutdown”不能消除内部异步在途写。补关闭/写并发及 fd 复用探针，保持退出有界且只回收自有进程。
3. **Swift index / M3U8 无跨进程写事务。** 当前仅进程内锁 + 内容指纹，两个进程同时通过检查仍可能互相 rename 丢更新。补协作式文件锁 / 必要单实例约束与并发夹具；注意普通其他播放器未必遵守锁，仍须保留外部变化检测及冲突提示。不要把与现有 session 的相似风险当成已验收证据；Rust 目前只有 dlq 有 flock，session 仍只有进程内事务锁。

其他已知限制：M3U8 写回统一 LF、不保留 BOM 与未知注释；播放清单标题/描述及稳定 ID 的产品联动仍需 E2/E3；SHA-256 每次整文件计算；deinit shutdown 可阻塞数秒，后续显式退出路径需设计；取消前注册集合容量 64；目录 fsync 为 best-effort；优雅退出失败会 SIGTERM/SIGKILL；真实标签/扫描/下载与 Swift 索引尚未贯通。

E2 界面与播放、E3 网易登录/推荐/搜索/下载入单、E4 自动保存/废纸篓与操作日志、E5 元信息匹配与完整格式支持、E6 原生 bundle/安装、E7 最终审查均未完成，按下方规格继续。**任务未完成，保留本 DEV，不删除。**

### 现场保护与收尾

未重置或提交 Git；保留全部既有暂存 / 未暂存修改。未运行 install-dist、未替换 dist，旧试用应用保持可用。只在 .artifacts 夹具注入故障；真实 profile 仅作只读字节校验，不输出凭证。曾误写 /tmp 的四个中间片段已移回 .artifacts，原路径均不存在。

临时报告 / 日志最终会由 clean.sh 删除，本段已摘录必须续做的结论。已核对最初记录的 7 项 session / dist 应用文件，SHA-256 全部未变。收尾格式检查通过（core / bridge / Tauri），新脚本 sh -n 与改动文件 git diff --check 通过。本轮 5 个 OC 会话导出末状态均为 idle/succeeded，全部交互 CLI exit 0；未发现遗留的项目生成可执行程序 / XCTest 进程。最后清理和关机步骤见下一段。

### 最终维护与关机

首次 `sh scripts/clean.sh` 在删除已知只读测试夹具 `dlq-order-<pid>` 时权限失败；仅恢复了归属本轮、只含 downloads.json / lock 的 11 个夹具目录写权限，未改用户目录。恢复这些已知夹具后重跑 `sh scripts/clean.sh` 已 **exit 0**：构建目录和 .artifacts 已删除，dist 注册已刷新；源码、测试、依赖、.tools、旧试用应用及全部持久数据保留。文档校验后再以 clean.sh 作为最后维护步骤。另记：`reserve_failure_keeps_task_order` 等故障测试须补 RAII 恢复目录权限，避免测试通过后仍阻塞清理。未运行 install-dist：原生界面和完整应用尚未完成，保留既有可用试用版是本轮明确约束。

关机授权来自本轮用户：任务完成后关机；额度不能支持完成时先交接、等待 OC 全部结束再关机。本轮按第二种条件收尾，**不是任务完成**。全部 OC 已结束；交接与最后清理通过后，主代理最后一步会安排延迟 30 秒向 System Events 发送系统关机请求，给最终回复留出时间。文档先于关机事件写盘，不声称已观察到机器断电；如系统被其他应用的未保存文档阻止，不应强制丢弃用户数据。

恢复建议：先重新读取额度，再读本段三项 E1 必修边界与对应源码；运行 `sh scripts/test-swift.sh` 复现，修复并独立审查后再开始 E2。OC 历史保存在上述会话，临时日志 / 报告清理后不可依赖；非交互 shell 可用 `/Users/jee/.opencode/bin/opencode session export <session-id>` 追查，避免再次把全部大 transcript 塞进模型。

## 上轮交接：额度保护收尾（2026-11-05）

**原生 macOS 改版尚未完成，不得标为交付。** 用户要求继续原生改版，并在 5 小时额度耗尽前形成新交接；全部任务真正完成后再删除本临时文档，必要长期说明转入 README。

本轮读取账户额度时，初次读取时 5 小时窗口已用 **88%**、周窗口已用 **76%**；交接写成后于 **14:48（Asia/Shanghai）** 复查，已用 **92%**、周窗口 **77%**；5 小时重置时间为 **2026-11-05 18:35:30（Asia/Shanghai）**。这是当时快照，恢复时必须重新读取，不能当成当前余额。未购买额度、未使用赠送重置、未修改账户设置。

本地额度读取工具（不请求模型、不输出凭证，位于保留的本地工具目录）：

```sh
python3 .tools/alger/check-codex-usage.py
```

它按官方 App Server 协议启动独立 stdio 客户端，initialize / initialized 后调用 `account/rateLimits/read`，只输出用量窗口与重置时间；最近快照写入 `.artifacts/usage-latest.json`。源码说明：[官方协议](https://learn.chatgpt.com/docs/app-server)。额度较低时优先更新本交接、停止执行会话、清理，不把任务标为完成。

### 当前现场与执行会话

- 工作目录：`/Users/jee/Documents/Projects/AlgerMusic`。全部既有 Git 暂存 / 未暂存修改保留，未提交、未重置。
- 本轮执行 OC `k4c`：`ses_e55c19cb8ffeq1S15JbZJ2p6np`；独立审查 OC `mm-f`：`ses_e55bb0670ffehi89NlTou7AGL4`。
- 恢复首轮 OC `glm-f`：`ses_e55cabb0affe6JUYVkQ5sIQ3nm`，因反复推演停止。更早基线执行 / 审查为 `ses_e56a8e8b0ffeM8ksCQp9M0vzbe` / `ses_e56a8a013ffe4NDxHB3gRuihhD`。
- 本轮执行与审查已结束并退出交互 CLI；执行模型确认最后文件完整落盘，无半截编辑。两条早期挂起的桥接探针已按 lsof 验证的本仓库精确可执行路径停止。
- **未执行本轮应用构建 / 安装 / 替换。** `dist/AlgerMusicPlayer.app` 仍是上一版可用试用应用。SwiftUI 界面、AVFoundation 播放和原生 bundle 尚不存在。
- 实现、自检仍交 OC；主代理负责转交、台账与必要抽查。建议按阶段启动精简 OC 会话，不加载旧大上下文；现有会话可导出用于追查，避免把整段 transcript 再塞给模型。
- 临时详细报告 / 日志放 `.artifacts/`，收尾会被 `clean.sh` 删除。下面已完整摘录必须续修的结论；不要依赖被删除的报告文件。

### 已落盘内容与可信验证

1. `crates/alger-core`：通过 `#[path]` 复用现有 crypto / cookie / netease / sources / session；新增网易推荐端点、扫描、lofty 标签、持久下载队列。禁止复制共享模块形成两套实现。
2. 标签来源 ID 改为容器专用写读：ID3 `TXXX:ALGERSONGID`、Vorbis `ALGERSONGID`、MP4 `----:com.alger.music:ALGERSONGID`。通用 Tag 的 Unknown 写法实测不可靠；ID3 TXXX 也不进入通用读取接口。
3. 标签写入使用同目录副本、写后重读、再原子替换；解析符号链接到真实目标以保留链接。MP3 / FLAC / M4A 用 ffmpeg 合成真实夹具往返通过；来源 ID 后改标题、写失败原字节不变、权限、符号链接的回归已加入。**AIFF / WAV 尚未验收**，AIFF 的 AiffText + ID3 双标签行为有差异，不得称为与 MP3 同构已验证。
4. SessionStore 已有损坏 / 读失败保护、先落盘后提交内存、创建即 0600 的唯一临时文件与 fsync、拒绝替换符号链接；但并发事务仍有问题，见下文 R1。
5. dlq 已有损坏及空文件保护、目标歌单持久字段 targets / 重复登记并集、reserve 写失败上抛、下载长度与文件大小检查；但状态写盘与回滚仍有严重缺口，见 R2–R4。
6. 桥接已能编译，session 错误传播与 dl.enqueue / retry / list 的 targets 已贯通，`dl.status` 暴露 loadIssue / lastError。EOF / app.shutdown 基本退出已修；深入生命周期问题见 R5 与主代理补充。
7. SwiftPM 初稿共 5 个文件，**全部未编译、未测试**：
   - `native/macos/Package.swift`（macOS 13+，AlgerKit / AlgerApp / AlgerKitTests）；
   - `Sources/AlgerKit/Paths.swift`（普通 / trial 路径）；
   - `Sources/AlgerKit/BridgeClient.swift`（子进程 JSON 行协议）；
   - `Sources/AlgerKit/LibraryIndex.swift`（索引持久化初稿）；
   - `Sources/AlgerKit/PlaylistFile.swift`（M3U8 / 相对路径 / 原子写 / 冲突检查初稿）。
   `Sources/AlgerApp/`、`Tests/AlgerKitTests/` 尚无内容，包声明的应用与测试目标未就绪；不能宣称 Swift 构建通过。
8. `.gitignore` / `scripts/clean.sh` 已加入两个 crate 的 target、`native/macos/.build` 和已知误落的 `crates/.artifacts`。共享 session 测试已修正 `CARGO_MANIFEST_DIR` 双构建路径定位。

最近确认的测试（代表当时测试集通过，**不代表审查闭环或原生功能完成**）：

| 检查 | 结果 |
| --- | --- |
| `cargo test --manifest-path crates/alger-core/Cargo.toml --lib` | 73 通过 |
| `cargo test --manifest-path src-tauri/Cargo.toml --lib` | 63 通过 |
| `cargo build --manifest-path crates/alger-bridge/Cargo.toml` | 通过，有待清理 warnings |
| `cargo test --manifest-path crates/alger-bridge/Cargo.toml --test exit` | 2 通过，但测试本身有缺口，见补充 |
| 后续单独 session 测试（两种 manifest） | 各 13 通过 |
| `sh -n scripts/clean.sh`、`bun tests/cleanup-acceptance.cjs` | 通过 |
| Swift / 原生 UI / 播放 / bundle / 安装 | 未执行 |

工具链：项目内 `.tools/cargo/bin`，导出 `CARGO_HOME="$PWD/.tools/cargo"`、`RUSTUP_HOME="$PWD/.tools/rustup"`，PATH 前置该 cargo/bin。不要改系统全局 Xcode 或用户数据。构建日志可重定向到 `.artifacts/`，检查真实退出码；不要用未启用 pipefail 的 `cargo ... | tail/grep` 把失败伪装成成功。

### 恢复时优先修复：第二轮独立审查尚未关闭

**R1 会话并发丢更新。** `src-tauri/src/session.rs` 的 set 是「候选落盘 → 提交内存」两步，没有覆盖读改写的事务锁；桥接 updateSettings / setCookie、Tauri 登录 / 设置仍先拿旧快照。并发操作可用旧 cookie 覆盖新登录，内存也可能与磁盘交错分叉。增加事务更新 API（如 `update` 闭包）与独立串行锁，覆盖读取、修改、落盘、提交；网络校验放事务外。所有桥接、commands、login、启动刷新写入口一起核对。补双线程不同字段更新、内存与磁盘一致的测试。

**R2 下载完成仍可能假成功。** `dlq::mutate` 仍先发事件，再 persist，失败只日志；音频 finalize 后可先对 UI 发 done，但磁盘仍 running，重启后重复下载、生成副本并重复入单。改成持久化成功后再通知；失败必须对 UI 可见，并保留可恢复的已落位音频与目标关联，不能简单清空状态。用独立 HTTP / 只读目录夹具断言没有假 done 事件、重启不重下。

**R3 队列落盘并发竞争。** dlq persist 仍使用固定 `downloads.json.tmp` 与无串行保护的 write / rename；并发进度与 reserve / clear，或多实例可竞争同一暂存文件。采用唯一 create_new 临时文件、合适权限、fsync、串行事务及必要外部修改检测；测试并发持久化始终可解析，避免只修临时名却丢更新。

**R4 回滚不完整。** clear 失败后内存已清空；reserve 失败回滚用按 ID 删除，可能连旧 done 记录的 path / targets 一起丢掉。事务内保存并准确恢复原记录；与 R3 一起处理，避免回滚覆盖另一线程更新。补 clear / reserve 写失败后的内存、磁盘、旧 path / targets 一致性测试。

**R5 桥接退出仍需复核。** 当前通过 outstanding 自旋等待请求完成；慢网络请求可阻塞退出，yield_now 自旋耗 CPU，shutdown 后排队请求与运行下载的终止语义未定义。改用有界等待 / 通知 / 明确取消及逐请求响应，未完成下载保留可恢复状态和目标；不要改回 sleep100ms + process::exit 赌输出 flush。基本 EOF 与 shutdown 曾挂住的根因包括原 req_tx 未 drop、writer 的 sender 被事件 sink 长期持有；已改明确关闭信号，不要引回旧问题。

**R6 Tauri 登录写盘失败仍可切换内存身份。** `src-tauri/src/commands.rs`、`login.rs` 中 client.set_cookie / bump_generation 仍在 session 持久化成功前执行；启动账号刷新失败只日志。共享会话修复必须兼顾现有 macOS / iOS；成功落盘后再切客户端身份，错误应能反馈用户。

第二轮审查 R7 的部分建议不成立：`preserve_format_specific_items` 是 lofty 全局解析配置，不是 WriteOptions 字段，默认已为 true，勿照抄不存在的 API；macOS 上 cp -p 和 fs::copy 的 xattr 保留经审查探针实际可用。仍须补未知二进制帧 / 封面 / 音频内容保留证据；ffmpeg 缺失时必须明确 skip，不把未跑的多格式测试写成通过。

### 主代理最后抽查新增的确定问题（尚未修）

- `tags.rs::with_safe_write` 比较 `(ino, len, mtime_nsec())`，**mtime_nsec 只是秒内纳秒部分，不含秒数**。至少把 mtime 秒也纳入；同秒 / 同大小内容变化的更强检测策略另评估。当前不能宣称完整 mtime_ns 冲突检查通过。
- `crates/alger-bridge/tests/exit.rs` 的 shutdown 测试把 stdin 变量放在花括号内，wait_exit 前已 drop，虽然注释声称「仍打开」，实际没有覆盖 stdin 保持打开场景；修测试并补长请求 / 取消用例。
- 同文件 wait_exit 超时只 assert，没有先 kill / wait 子进程；失败会遗留探针。加 Child 的 RAII 清理或超时显式停止其精确子进程。
- 同文件通过覆盖子进程 HOME 隔离 profile。改成明确的测试 session / data 路径注入，避免 repurpose HOME，并验证测试确实只触 `.artifacts`。
- Swift 4 个模块只是未编译初稿，原子写、并发、损坏保护、M3U8 外部修改冲突、桥接超时 / 子进程退出 / 凭证不回传均需独立审查，不能因为文件注释写了就算完成。

### 后续阶段与验收要求

| 阶段 | 当前状态 / 必须续做 |
| --- | --- |
| E0 架构 / 桥接 | 纯 Rust 复用与 JSON 协议已落盘、可编译；修完 R1–R6 和生命周期测试后再验收 |
| E1 本地核心 | 完成本地索引、标签关联、M3U8 增删改排序 / 原子写 / 冲突检测及 Swift 夹具测试；中文 / 空格 / 相对路径、重启恢复、移出歌单不删音频 |
| E2 原生界面 / 播放 | 尚未开始。SwiftUI/AppKit、原生 sidebar 材质、系统色 / SF Symbols、首页 / 唯一搜索 / 本地歌曲专辑艺人 / 两组歌单 / 队列；AVFoundation 本地与网络播放、暂停跳过 seek |
| E3 网络 / 下载 | 真实网易登录（WKWebView 仅用于登录）、FM / 心动模式 / 关注艺人新作、统一搜索、权限控制的远程歌单编辑、持久下载及先下载后入本地歌单 |
| E4 自动保存 / 文件操作 | 完整在线播放默认 3 次自动保存，可调 / 关闭，seek / skip / 本地不计；文件真实进废纸篓及操作日志协调索引 / 本地 M3U8，失败不先清数据 |
| E5 元信息 | MusicBrainz 候选差异确认、Cover Art Archive 封面、真实标签写回与重读；AcoustID key / 指纹工具真实配置，缺少依赖明确提示；补 AIFF/WAV 与未知帧/封面/音频保留验证 |
| E6 交付 | SwiftPM 构建 + native bundle 脚本；接 install-dist.sh 验证 / 签名后替换；显示名 Alger Music / 新图标 / 生命周期 / 数据身份验证，失败保留旧版 |
| E7 独立审查 | MM-F 已两轮审核心，问题未关闭；最终原生实现与证据还需另一 OC 模型审查，修完严重问题才交付 |

架构固定：主界面 SwiftUI/AppKit（macOS 13+，首轮当前 Mac 架构），禁止主界面 WebView；Rust 进程 JSON 行桥接；WKWebView 仅网易登录。SwiftPM 目录 `native/macos/`，AlgerKit 与 AlgerApp 分层，AVFoundation 播放。iOS 保留现有工程，原生迁移在 macOS 验收后再做。

数据布局：保留现有 session.json schema 与普通 / 历史 / trial profile；增量 native.json（设置 / 播放计数 / 文件夹）、library/index.json、bridge/downloads.json；本地歌单默认 `~/Music/AlgerMusic/Playlists/` 下 UTF-8 M3U8，可在设置改位置。Swift 与 Rust trial 标志须一致。

冻结规则：侧栏只有下载条目能显示数字；使用系统原生 sidebar 材质（随系统外观、强调色、窗口激活 / 降低透明度变化），不得 CSS blur 伪装。正式界面不得包含原型假账号、曲目、下载或标签成功信息。关窗保留 Dock / 音频 / 下载，Dock 恢复窗口，⌘Q 正常退出。

用户允许读取现有 trial 数据做真实只读联调，凭证不可输出；删除、标签覆盖和失败注入只用独立夹具。保留全部设置、登录、WebKit、音乐与普通 / 历史 / trial 数据，禁止扫删 ~/Library。唯一持久应用路径 `dist/AlgerMusicPlayer.app`，identifier `com.alger.music.trial`，会话目录 `~/Library/Application Support/AlgerMusicPlayer.trial`，不建 /Applications 快捷方式。仅在新应用实际完成并验证后安装，旧应用在替换验证前必须可用。

完成每轮：适当检查；只有应用实质改动且可验收时运行 `sh scripts/install-dist.sh`；最后运行 `sh scripts/clean.sh`。本轮未安装；`sh scripts/clean.sh` 已成功清理 Tauri / 两个 crate 的构建目录与 `.artifacts`，刷新唯一 dist 注册，保留源码、测试、工具、应用与全部用户数据。已核对本轮前存在的试用 session.json 字节校验保持不变，凭证未输出。下方保留完整产品讨论稿及既有构建说明，作为后续规格；其中迁移前状态描述不代表当前原生实现已完成。

## macOS 原生界面改版：讨论稿 02

本节为产品与技术方案，不代表正式 App 已交付以下功能。先用 Web 原型确认交互，
再做 SwiftUI 关键页与核心能力桥接。正式界面使用 Swift 原生控件、SF Symbols，
跟随系统浅色 / 深色与强调色；macOS 优先，之后适配 iPad / iPhone。

### 查看与演示

```sh
bun prototypes/macos/serve.js
# 浏览器访问 http://127.0.0.1:4175/，更新后刷新页面
```

原型源码在 `prototypes/macos/`，无需额外依赖。也可以直接打开 `index.html`。
服务只监听本机，仅提供原型与指定图标，不开放项目其他文件。
全部账号、推荐、播放、下载、文件删除与标签写入均为示例，**不访问真实账号或音乐文件**。
设置、歌单、示例曲目和完整播放计数保存在浏览器的独立示例空间，点击「重置示例」清除。
「模拟完整播完当前歌曲」「模拟下载失败」「模拟重新打开」用于验证状态变化。
「导出示例文件」只生成包含示例路径的 M3U8，不对应真实音频。

2026-11-05 第二版验证：JavaScript 构建检查与 40 项浏览器检查通过，覆盖统一搜索、
离线本地播放、完整在线播放计数 / 自动保存开关、下载失败与重启恢复、先下载再入单、
更换添加目标、临时队列另存、两组歌单折叠 / 编辑、M3U8 内容、标签编辑与两种删除，
并检查 760 / 939 / 1100 / 1440px 页面无横向溢出。本轮未修改或重新构建正式 App。

### 已确认的页面与交互

- 搜索入口唯一，同时检索本地和网络；同一录音按明确身份关联去重，存在有效本地版本就优先播放。
  离线仍可搜索本地，网络项保留已知信息但不可播放。不设置独立的在线服务页面。
- 首页默认打开：私人 FM、基于收藏歌单的歌单电台、关注艺人的新歌 / 推荐新作、最近存入本地。
  关注艺人推荐排除已收录到本地的录音；最近存入同时包含主动下载和自动保存的音乐。
- 移除侧边栏顶部品牌块、前进 / 后退导航，以及所有「导入歌单」入口。
  左下角显示网易账号头像与用户名，点击进入账号操作和设置。原型使用示例账号。
- 资料库的歌曲 / 专辑 / 艺人只归组本地文件，不再使用「全部 / 本机可播」切换或可用状态列。
  本地文件不区分「已下载」与「本地文件」；需要混合展示的搜索、远程歌单和队列仅标「本地 / 网络」。
- 艺人详情上方为本地曲目，下方为网络热门歌曲与最新单曲 / 专辑。专辑条目可以进入详情。
- 本地歌单优先，分隔线后为远程歌单；两组可独立折叠，设置中可隐藏远程组。
  侧边栏仅下载任务显示数字，其余条目与分组不显示数字；正式版使用系统原生磨砂半透明侧栏。
  两组均支持新建、改名 / 描述、添加 / 移除曲目及调整顺序。原型远程列表均为当前用户可编辑的歌单；
  正式版按上游所有权 / 权限控制，他人歌单不能假装修改成功，可先另存为自己的歌单。
- 所有曲目加号默认加入**当前正在播放的歌单**，而非当前浏览页。
  添加反馈提供「更改…」，可改到另一张本地 / 远程歌单或新建歌单；更换目标撤回这次默认添加，
  不删除此前已经存在的条目。当前为临时播放列表时默认加到该列表。
- 本地歌单始终只含本地曲目。网络曲目加入本地歌单，先下载，成功后加入；失败保留待处理任务与重试入口。
  临时队列可以保存为新歌单；保存为本地歌单时，网络曲目也遵循先下载再入单。
- 下载任务入口按本次任务出现：有进行中任务显示「正在下载」；全部成功显示「已下载」；
  失败显示待处理。无任务隐藏入口，完成任务可清除。下次打开已完成列表失活，
  已下载曲目仍归资料库；未完成任务需恢复 / 重试，不丢失其目标歌单。
- 经常听的歌自动保存默认开启、阈值为 **3 次**，可在设置中调整 / 关闭。
  只计真实**完整在线播放**；暂停续播不产生额外次数，跳过、拖进度到结尾、本地播放不计数。
  次数跨会话累计，每次播放最多计一次；达到阈值去重发起下载，失败进入待处理状态。
  调低阈值不立即批量下载所有历史歌曲，在后续完整播放时判断。

### 删除操作的区别

| 操作 | 音频文件 | 歌单 / 资料库 |
| --- | --- | --- |
| 从歌单移除 | 保留 | 仅移除该歌单的引用 |
| 删除歌单 | 保留 | 删除本地 M3U8 或有权限的远程歌单 |
| 从资料库删除文件 | 真正删除，macOS 默认移到废纸篓 | 成功后清理本地索引及所有本地歌单引用 |

资料库删除需要确认，并显示受影响本地歌单数量；不联动删除远程歌单中的网络条目。
文件删除失败时不先清空索引。删除与多份 M3U8 更新通过操作日志协调，异常中断后修复未完成操作，
不把部分成功显示为全部成功。若正在播放被删的本地文件，先停止该文件播放。
这些是待实现行为，Web 原型仅演示确认与引用清理，不调用真实废纸篓。

### 本地文件、元信息与 M3U8

**音频标签是可移植元信息的主要载体；M3U8 是本地歌单格式；数据库是索引与应用状态。**

| 载体 | 保存内容 |
| --- | --- |
| 音频文件 | 标题、艺人、专辑、专辑艺人、曲序 / 碟序、发行日期、流派、内嵌封面；合适的标准 / 自定义标签保存 ISRC、MusicBrainz / 网易关联 ID |
| UTF-8 M3U8 | 有序文件路径与可选 `#EXTINF` 的时长 / 显示名，供其他播放器复用 |
| 本地数据库 | 文件索引、来源关联、完整网络播放次数、下载状态、设置、元数据匹配来源与修改记录 |

本地歌单新建后直接以 `.m3u8` 文件保存，增删改和重排同步更新，提供查看 / 导出文件入口。
**取消「导入外部歌单」流程**，并非取消 M3U8 支持；原先的 HLS 播放理解不适用于当前需求。
音频文件路径优先相对歌单位置保存，跨目录时计算相对路径，必要时使用绝对路径。
UTF-8 中文与空格保留；`#EXTINF` 作兼容显示，完整元信息从音频读取。
修改标签不擅自重命名 / 移动音频，因此不会因标题更正而破坏歌单路径。
M3U8 写入采用同目录暂存 + 原子替换；发现其他 App 改动同一文件时提示冲突，避免静默覆盖。

音频标签写入按格式处理：MP3 / AIFF 的 ID3、FLAC / Ogg 的 Vorbis Comment、M4A 的 MP4 标签。
保留未知标签、已有封面及音频数据，不为了写标签重新编码音频。
写入后重新读取验证；失败明确标为未保存，不能只更新数据库却显示「已写入文件」。
写入后的标准标签应使用其他播放器验证，尤其是多艺人、曲序 / 碟序及内嵌封面。

### 在线匹配元信息

建议接入以下能力，优先补空缺，匹配结果先显示差异供用户确认，不自动覆盖手工修改：

1. 已有准确网易歌曲 ID 的下载：优先保留对应服务元信息与来源 ID。
   第三方音源可能返回不同版本，需要核对时长 / 录音身份，不能因为沿用了原歌曲 ID 就认定内容一致。
2. 普通本地文件：用标题、艺人、时长等查询 [MusicBrainz](https://musicbrainz.org/doc/MusicBrainz_API)，
   录音与发行版本分别匹配；同一录音的不同专辑版本需确认，避免封面 / 曲序错配。
3. 标签不足或候选冲突：以 [Chromaprint / AcoustID](https://acoustid.org/webservice) 音频指纹查找录音候选，
   再取得关联的 MusicBrainz 元信息。指纹匹配不是无条件自动覆盖标签的依据。
4. 封面按确认的发行版本从 [Cover Art Archive](https://musicbrainz.org/doc/Cover_Art_Archive/API) 获取并内嵌到音频。

MusicBrainz 公共接口按约 1 请求 / 秒限制，并提供可联系维护者的 User-Agent；
AcoustID lookup 需要应用 API key，公共服务最多 3 请求 / 秒，免费服务面向非商业使用。
匹配队列需限速、缓存、可取消，离线不阻塞播放；未知 / 低置信度结果不强行写回。
中文与冷门曲目的覆盖、封面版本及不同音源准确率需以实际曲库验证。
本轮原型的「匹配信息示例」未调用任何这些服务。

### 网易推荐能力的证据与边界

仓库现有网易模块尚未接入推荐端点。已核实上游实现（非网易官方公开 API 保证）：

| 能力 | 上游模块 / 内部端点 |
| --- | --- |
| 私人 FM | [`personal_fm`](https://github.com/neteasecloudmusicapienhanced/api-enhanced/blob/main/module/personal_fm.js)：`/api/v1/radio/get` |
| 歌单心动模式 / 智能播放 | [`playmode_intelligence_list`](https://github.com/neteasecloudmusicapienhanced/api-enhanced/blob/main/module/playmode_intelligence_list.js)：`/api/playmode/intelligence/list`，传歌单与种子歌曲 ID |
| 已关注艺人列表 | [`artist_sublist`](https://github.com/neteasecloudmusicapienhanced/api-enhanced/blob/main/module/artist_sublist.js)：`/api/artist/sublist` |
| 关注艺人新歌 | [`artist_new_song`](https://github.com/neteasecloudmusicapienhanced/api-enhanced/blob/main/module/artist_new_song.js)：`/api/sub/artist/new/works/song/list` |

心动模式返回推荐曲目序列，不一定对应一张固定推荐歌单。正式接入需用真实账号只读联调、
验证返回结构 / 登录权限 / 分页，再按本地索引过滤已收录录音。原型只展示示例数据，未读取现有 Cookie。

### 技术推进

当前下载任务仅在内存中，播放也从网络解析开始。需先建立文件索引、跨重启下载记录与来源关联，
再实现本地优先解析、完整网络播放计数与自动保存。不能只改 UI 达成这些功能。

从 Rust 模块中拆出与 Tauri 命令 / 事件无关的核心能力，再以 SwiftUI + AVFoundation 验证本地播放、
标签写入和桥接。Mac 文件权限需覆盖原文件与歌单位置；若采用 sandbox，恢复 security-scoped bookmark。
iOS 的文档访问权限与容器路径另行适配，不照搬 macOS 绝对路径。

建议先后推进：持久文件索引与标签读写 → 本地播放 / M3U8 同步 → 下载队列及自动保存 →
网易推荐 / 统一搜索 / 可编辑远程歌单 → 原生 macOS 验收 → 移动端。
`NavigationSplitView` 的最低版本与折叠行为见 [Apple 说明](https://developer.apple.com/documentation/technotes/tn3154-adopting-swiftui-navigation-split-view)。
新 UI 暂建议 macOS 13+，最低系统版本仍待确认，本轮不改现有 App 的 10.15 部署目标。

## 目录结构

```
.
├── frontend/               前端（轻量 TypeScript，无框架）
│   ├── src/
│   │   ├── main.ts         入口：布局、路由、渲染调度
│   │   ├── api.ts          应用能力封装
│   │   ├── player.ts       播放核心（队列 / 解析 / 并发保护）
│   │   ├── store.ts        全局状态
│   │   ├── dom.ts          极简 DOM 辅助
│   │   ├── format.ts       格式化工具
│   │   ├── mobile.css      移动端 / 窄屏布局（媒体查询 + 行类型语义 class）
│   │   ├── platform.ts     平台探测（iOS 标识等）
│   │   └── views/          各视图
│   └── vite.config.ts
├── src-tauri/              Rust 后端（Tauri 2）
│   ├── src/
│   │   ├── lib.rs          应用入口、命令注册、启动校验
│   │   ├── commands.rs     前端可调用的命令
│   │   ├── crypto.rs       eapi / weapi 加密
│   │   ├── cookie.rs       Cookie 解析与请求头组装
│   │   ├── login.rs        内置网页登录窗口
│   │   ├── session.rs      本地会话与设置持久化
│   │   ├── download.rs     下载管理
│   │   ├── state.rs        全局共享状态
│   │   ├── netease/        网易云接口（客户端 / 端点 / 模型）
│   │   └── sources/        第三方音源（pyncmd / gdmusic / kugou / kuwo / migu）
│   ├── examples/live_probe.rs  真实公开接口探测工具
│   ├── capabilities/       权限（仅主窗口）
│   ├── tauri.conf.json     桌面端配置
│   ├── tauri.ios.conf.json iOS 覆盖配置（identifier / Team / 最低系统版本）
│   ├── Info.ios.plist      iOS Info.plist 增量（后台音频、Files 共享、ATS）
│   └── gen/apple/          生成的 Xcode 工程（配置 / 源码 / assets 入库，构建产物忽略）
├── tests/
│   └── player-acceptance.cjs  播放核心并发场景验收
├── scripts/                构建辅助脚本
│   ├── build-ios.sh        iOS 真机构建（tauri ios build + 产物定位 + 可选安装）
│   ├── install-dist.sh     刷新长期试用安装（复制 .app 到 dist/，不建 /Applications 快捷方式）
│   ├── clean.sh            清理全部构建 / 测试残留（不动 dist/ 与源码）
│   └── xcode-build-rust.sh Xcode「Build Rust Code」phase 入口（导出工具链环境）
└── licenses/               第三方许可证全文
```

## 常用命令

### 应用图标

图标采用用户手工修订的 Algiers 地标双音符轮廓，以及已确认的石墨灰底、米白石材光影。
可编辑纯轮廓保留在 `src-tauri/icons/alger-monument-editable.svg`。

生产用矢量源与平台母版：

| 平台 | SVG 源文件 | 1024px PNG 母版 | 裁切处理 |
| --- | --- | --- | --- |
| macOS | `src-tauri/icons/app-icon-macos.svg` | `src-tauri/icons/icon-macos.png` | 一层圆角底板，外部透明；底板占 1024px 画布的 896px，不再追加留白 |
| iOS | `src-tauri/icons/app-icon-ios.svg` | `src-tauri/icons/icon-ios.png` | 满画布、不透明 RGB、直角方形；无预裁圆角、外部投影或边框，交给系统裁切 |

iOS 源使用 `viewBox="64 64 896 896"` 去除 macOS 的外部留白，并以矩形背景铺满可视区域；
保持标志相对底板的比例，避免把完整 macOS 图标再次嵌入 iOS 图标而导致缩小和双重圆角。

重新生成：`sh scripts/generate-icons.sh` 或 `bun run icons:generate`（需要 macOS、Bun / Tauri CLI）。
该命令只导出图标，不编译、安装或重启应用：

- 使用 Tauri SVG 渲染器生成两套独立的 1024px 平台母版。
- 生成桌面 `32x32.png`、`128x128.png`、`128x128@2x.png`、`icon.png`（512px），
  并用原生 `iconutil` 打包含 16–1024px 分辨率的 `icon.icns`，供现有 Tauri 配置使用。
- 按现有 `src-tauri/gen/apple/Assets.xcassets/AppIcon.appiconset/Contents.json`
  生成全部 18 个 iOS PNG，移除 alpha 通道，保留目录清单。
- 检查平台边缘、透明度、PNG 尺寸与 ICNS 往返导出，全部通过后再写入资源目录。

`icon-original.png` 和 `icon-monument.png` 保留为早期图稿，不再作为生产导出输入。
图标资源已生成；本轮名称与 macOS 窗口行为更新时一并刷新长期试用版。

### 构建与检查

| 命令 | 说明 |
| --- | --- |
| `bun install` | 安装前端依赖 |
| `bun run dev` | 启动前端开发服务器（`http://localhost:1420`） |
| `bun run tauri:dev` | 启动完整桌面应用（开发模式） |
| `bun run build` | 构建前端到 `frontend/dist` |
| `bun run tauri:build` | 打包 macOS `.app`（产物在 `src-tauri/target/release/bundle/macos/`） |
| `bun run typecheck` | 前端 TypeScript 检查 |
| `bun run test:player` | 播放核心并发场景验收 |
| `bun run test:rust` | Rust 单元测试 |
| `bun run lint` | 类型检查 + `cargo fmt --check` + `cargo clippy -D warnings` |
| `scripts/build-ios.sh` | iOS 真机构建（完整 Xcode、自动签名，产出 `.app` + `.ipa`） |
| `scripts/build-ios.sh --install` | 同上，并额外把 `.app` 安装到已连接的真机（`devicectl`） |
| `scripts/install-dist.sh` | 构建 + 安装长期试用版（试用 identifier `com.alger.music.trial`，数据独立，复制到 `dist/`，不创建 `/Applications` 快捷方式） |
| `scripts/clean.sh` | 清理已确认归属的构建 / 测试残留与临时文档；保留 `dist/` 和所有用户数据（`--dry-run` 预览） |

## 长期试用安装（dist/）

`scripts/install-dist.sh` 一条命令完成「构建 + 安装」：

- 以试用身份构建：identifier 覆盖为 `com.alger.music.trial`（`tauri.trial.conf.json`），
  并注入 `ALGER_TRIAL=1` 使会话存储走独立目录 `~/Library/Application Support/AlgerMusicPlayer.trial`；
- 对完整 bundle 做本地 ad-hoc 签名，校验 identity、可执行文件与签名后暂存；
- 替换 `dist/AlgerMusicPlayer.app`，新安装校验成功前保留旧版，失败自动回滚；
- 只安装到 `dist/AlgerMusicPlayer.app`：这是唯一的长期应用入口，不再创建 `/Applications`
  快捷方式，Spotlight 中不会出现第二份同名结果；
- 只按旧实例的精确可执行路径退出应用，原来在运行时才重启，并 `mdimport` 刷新索引；
- 成功或失败退出时自动执行清理，保留原有失败退出码。

显示名统一为 **Alger Music**。持久 bundle 的物理路径仍为 `dist/AlgerMusicPlayer.app`；
安装时 `scripts/localize-trial.swift` 在暂存副本中设置与物理名匹配的基础名称，
通过 `en` / `zh-Hans` / `zh-Hant` 的 `InfoPlist.strings` 提供统一显示名称，
并在重新签名后验证 Finder 与 AppKit 的实际显示名。
这是 [macOS 本地化显示名称机制](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CoreFoundationKeys.html#//apple_ref/doc/uid/TP40009249-SW3) 的要求，
不改 identifier、可执行文件名或用户数据目录。
仅更新打包资源时可用 `sh scripts/install-dist.sh --repackage`：复用已经签名验证的持久应用，
在暂存副本中准备资源并重新签名、验证、原子替换，不重复编译 Rust。

2026-11-05 修订验证：56 个 Rust 测试、4 个播放并发验收、16 个歌单交互验收及清理边界检查通过；
macOS 试用版签名与新图标校验通过。通过系统辅助功能实测了红色按钮关窗后进程保留、
真实 Dock 图标显示 Alger Music 并恢复原进程窗口、最小化后 Dock 恢复，以及 `⌘Q` 完全退出。
本轮未做真实音频续播 / 下载续传的长时间测试；iOS 名称已同步配置，未重新构建真机包。

**试用数据隔离**：试用版所有用户数据（登录 Cookie、设置、WebView 存储）都落在
`.trial` / `com.alger.music.trial` 命名空间下。清理始终保留普通版、旧版与试用版
的所有持久用户数据，包括登录、设置、WebKit 存储和下载的音乐。

## 任务结束自动清理

任务结束后运行 `sh scripts/clean.sh` 清理残留，此约定写在本地、git 忽略的 `AGENTS.md` 中。

- 仅在应用本身有重大修改或用户明确要求时，才运行 `sh scripts/install-dist.sh`
  重新编译并刷新长期试用版；脚本、文档、清理逻辑等改动不单独编译。
- `dist/AlgerMusicPlayer.app` 是唯一的长期应用入口：安装脚本不创建 `/Applications`
  快捷方式，清理脚本也不依赖或重建它。
- 构建产物：清理 `src-tauri/target`、前端 `dist`、Tauri schemas、iOS
  `DerivedData` / `build` / `Externals` / `Pods`；保留生成工程的源码与配置。
- 中间文档、日志、截图、临时测试数据统一放 `.artifacts/`，任务结束一并删除。
  iOS 默认构建日志也位于此目录；显式指定 `ALGER_IOS_LOG` 的外部日志由调用者管理。
- 系统 Xcode DerivedData 只有在 `info.plist` 的 WorkspacePath 指向当前仓库时才删除。
- `$TMPDIR` 和 `/tmp` 中的 `alger-*` 目录必须携带 `.alger-project` 标记，内容为
  当前仓库的规范绝对路径。其他仓库、无标记目录及仍有活动 owner PID 的目录保留。
- 不按名称杀进程，不清扫全局缓存或用户数据，不删除软链接指向的内容。
- 删除生成的 `.app` 前先注销其 Launch Services 记录；替换试用版前注销旧路径，
  清理结束后直接重新注册 `dist/AlgerMusicPlayer.app` 实体并更新 Spotlight，
  不依赖也不重建 `/Applications` 软链接，不做全局索引重置。
- `sh scripts/clean.sh --dry-run` 仅预览；`bun run test:cleanup` 验证清理边界。

## 关键实现说明

### 网易云接口加密

`src-tauri/src/crypto.rs` 实现了上游 `NeteaseCloudMusicApi` 的三种加密方式：

- `eapi`：AES-128-ECB（PKCS#7），密文为大写 HEX；`url` 参与 MD5 校验。
- `weapi`：双层 AES-128-CBC + **raw RSA（NoPadding）** 加密 `encSecKey`。
  注意上游 `node-forge` 的 `encrypt(str, 'NONE')` 是 **不做 PKCS#1 填充** 的原始 RSA，
  因此不能使用标准 `Pkcs1v15Encrypt`，实现见 `raw_rsa_encrypt_hex`。
- `linuxapi`：AES-128-ECB（当前未使用）。

`WEAPI_RSA_N_HEX` 必须是从 PEM 公钥直接导出的 **1024 位模数**（256 个十六进制字符），
不要把 DER 结构里代表 `e = 65537` 的 `0203010001` 并进去。

### 歌单完整读取

网易云 `/playlist/detail` 返回的 `tracks` 是截断的，完整歌曲 ID 在 `trackIds` 中。
`commands::playlist_detail` 会读取 `trackIds` 并按每批 500 个 ID 调用 `/song/detail` 补齐，
最后按 `trackIds` 顺序重排。

### 第三方音源

全部为本地实现，见 `src-tauri/src/sources/`：

| 音源 | 说明 |
| --- | --- |
| `pyncmd` | GD 音乐台的网易云直连转码（网易云 ID 直接换链） |
| `gdmusic` | GD 音乐台多平台搜索 + 标题 / 歌手匹配后换链 |
| `kugou` | 酷狗移动端搜索 + `trackercdn` 换链 |
| `kuwo` | 酷我搜索 + `mobi.s` 换链（查询串使用改造版 DES） |
| `migu` | 咪咕搜索 + `listen-url` 换链 |

回退策略与可靠性：

- 每个音源有独立超时（12s），整体解析有超时（30s）；
- 得到的地址会先做可用性探测（只读前 8 KiB，拒绝 HTML / JSON 伪音频），
  探测失败的地址 **不会** 阻断后续音源；
- macOS 的 ATS 会拦截明文 HTTP，因此优先尝试 HTTPS。

### 主题与图标

- **图标**：`frontend/src/icons.ts` 使用 lucide 的 `IconNode` 数据直接渲染内联 SVG。
  SVG 本身带 `aria-hidden="true"`，可访问名称由 `iconButton` / `iconTextButton`
  设置的 `aria-label` 与 `title` 提供（读屏与键盘用户均可识别）。
- **浅色 / 深色**：由 CSS 的 `prefers-color-scheme` 媒体查询跟随系统，运行时自动切换，
  不需要额外的 JS 逻辑。
- **强调色**：WebKit 对标准 `AccentColor` 属性支持有限，因此由 Rust 侧读取
  `NSColor.controlAccentColor`（`src-tauri/src/theme.rs`），转成 `#RRGGBB` 后通过
  `theme://accent` 事件推送；前端写入 `--accent` 与 `--accent-rgb` 两个 CSS 变量。
  背景线程每 1.2s 轮询检测强调色变化，另有 `WindowEvent::ThemeChanged` 触发一次立即刷新
  （不同外观下的强调色略有差异）。

### 登录窗口

- 使用 **非持久化**（incognito）数据存储，窗口关闭后 Cookie 即消失，不残留失效凭证；
- 登录窗口 **不授予任何 capability**（见 `src-tauri/capabilities/main.json`，
  其中 `"windows": ["main"]`），远程网页无法调用应用命令；
- Cookie 采集在独立线程上进行，调用侧让出主线程，
  避免上游 `cookies_for_url` 在主线程阻塞造成的死锁（参见 tauri#15489）；
- 采集到的 Cookie 先 **独立校验**，校验成功才替换现有会话，失败保留原会话。
- **iOS 必须用原生异步 Cookie API**（`src-tauri/src/ios_cookies.rs`）：
  wry 的同步 `cookies()` / `cookies_for_url()` / `delete_cookie()` 内部会在
  **主线程泵 `NSRunLoop`** 等待 WebKit 回调，与 Tao 的 control flow 嵌套后
  `unimplemented!()` panic → `panic = "abort"` → 登录成功瞬间 SIGABRT 闪退。
  iOS 改为：主线程只发起异步
  `WKWebView.configuration.websiteDataStore.httpCookieStore.getAllCookies`，
  completion block 把结果通过 channel 送回后台轮询线程（主线程不泵 RunLoop）；
  清 Cookie 同理走原生异步 `deleteCookie:completionHandler:`。
  macOS 保持 wry 的同步实现不变。

## 真实接口探测

`src-tauri/examples/live_probe.rs` 会访问真实公开接口（搜索、公开歌单、播放地址、下载），
不会登录、不会创建或修改任何歌单：

```bash
cargo run --manifest-path src-tauri/Cargo.toml --example live_probe -- "周杰伦 晴天"
```

## iOS 构建与安装

`scripts/build-ios.sh` 是 iOS 真机构建的唯一入口（**不改全局 `xcode-select`**）：

```bash
scripts/build-ios.sh            # 构建
scripts/build-ios.sh --install  # 构建 + 安装到已连接的真机（devicectl）
```

构建要点：

- 前置工具：完整 Xcode（`/Applications/Xcode.app`）、`xcodegen`、`bun`、项目内 `.tools` Rust 工具链
  （`aarch64-apple-ios` target 已安装）；均不需改动全局 `xcode-select`。
- 完整 Xcode 通过 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` 固定；
  脚本自建临时 `xcodebuild` shim，保证被调用到的 `xcodebuild` 也用完整 Xcode。
- Rust 工具链优先用项目内 `.tools`（`RUSTUP_HOME` / `CARGO_HOME` / `PATH`），缺失时回退系统工具链。
- Xcode 的「Build Rust Code」phase **不直接**调 `bun tauri ios xcode-script`，而是调用仓库内
  tracked 脚本 `scripts/xcode-build-rust.sh`：该脚本在 phase 内部从 `SRCROOT/../../..`
  定位项目根目录，自行导出 `DEVELOPER_DIR` / `RUSTUP_HOME` / `CARGO_HOME` / `PATH`，
  再 `cd` 到项目根执行 `bun tauri ios xcode-script "$@"`（参数原样透传），
  不依赖外层进程环境。修改 `src-tauri/gen/apple/project.yml` 后需重新生成 Xcode 工程：

  ```bash
  cd src-tauri/gen/apple && xcodegen generate
  ```

- **不要**在 `tauri ios build` 的 `--` 之后追加 `KEY=VALUE`：Tauri v2 会把它们当作
  **cargo 参数**透传，直接导致 `cargo build: unexpected argument 'RUSTUP_HOME=...'`。

签名与安装：

- 自动签名（`iOS Team Provisioning Profile: com.alger.music.ios`，Team `9SVGN86A32`，
  application-id `9SVGN86A32.com.alger.music.ios`，含目标测试机）；
- 描述文件到期 **2026-11-01 23:47:13 UTC**（用户本地时区 Asia/Bangkok 为
  **2026-11-02 06:47:13**）：到期后需重新签名并重新安装；
  这是**开发分发**包，不是长期分发包；
- 产物：`src-tauri/gen/apple/build/alger-music_iOS.xcarchive/Products/Applications/AlgerMusicPlayer.app`
  与 `src-tauri/gen/apple/build/arm64/AlgerMusicPlayer.ipa`；
- 安装：`xcrun devicectl device install app --device <UDID> <app 路径>`（只接受 `.app`）；
- 已知限制：iOS 的 WKWebView **不实现 JS 对话框**（`window.prompt` / `window.confirm`
  不可靠；且 `tauri-plugin-dialog` 的 `window.confirm` 是异步的、返回 Promise，
  当布尔值用会导致「取消也发写请求」），因此歌单的新建 / 加入 / 移除一律走
  **应用内 HTML 弹层**（`frontend/src/dom.ts`）。

## 平台说明

- macOS 桌面版（Apple Silicon 与 Intel）：已完成，真实账号登录与播放由用户实测通过；
  产物为个人自用的 **ad-hoc 签名、未公证**（首次打开可能需在
  「系统设置 → 隐私与安全性」中放行）。
- iOS：**已能真实构建、自动签名并安装到真机，主要流程已由用户真机验证**——
  登录（不再闪退）、重开保持登录、歌单读取与播放、下载文件与「文件」App 可见、
  新建歌单表单（名称 + 描述）的打开与取消；
  **仍未单独确认**：锁屏续播；**未执行**：真实账号的歌单创建 / 改名 / 增删。
  - 已就位：`tauri.ios.conf.json`（identifier `com.alger.music.ios`、Team `9SVGN86A32`、
    最低系统版本 16.0）、`Info.ios.plist`（后台音频、Files 共享、仅 WebContent 的 ATS 放宽）、
    生成的 Xcode 工程 `src-tauri/gen/apple/`（`project.yml` 含手工修复，须入库保留；
    `Externals/`、`Pods/`、`DerivedData/`、`build/` 等构建产物已被 .gitignore 忽略）。
  - 移动端布局由 `frontend/src/mobile.css` 接管（≤900px）：侧栏收成顶部导航、
    触控目标 ≥44px、输入框 ≥16px 防聚焦缩放；歌曲行按语义 class 区分类型
    （`song-row--search` 无多选框、`song-row--download` 为 flex 行、
    歌单详情行保留多选 checkbox），不再使用 `nth-child` 隐藏列。
  - 窄屏下侧栏的歌单列表与「新建歌单」入口被隐藏，因此「我的歌单」视图
    **正文区自带歌单概览**（`renderPlaylistOverview`）：直接列出歌单
    （点击进入歌单详情）并提供「新建歌单」按钮，未登录时提示登录；
    手机导航「我的歌单」可反复回到该列表。
  - 数据位置：iOS 下载目录固定为沙盒 `Documents/AlgerMusic`（「文件」App 可见，
    不可更改）；该路径**每次都按当前沙盒重算**（原生 `NSFileManager` 取当前容器的
    Documents），不信任 `session.json` 里持久化的绝对路径——沙盒容器 UUID 在
    重装 / 升级后会变化，旧路径会导致「创建下载目录失败」；
    会话仍在 `Library/Application Support/AlgerMusicPlayer/session.json`
    （不在「文件」App 暴露）。
  - iOS 强调色由 UIKit 系统动态色解析（`src-tauri/src/theme.rs` 的 `target_os = "ios"` 分支），
    与 macOS 的 `NSColor.controlAccentColor` 分平台实现，互不影响。
