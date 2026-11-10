# AGENTS — iOS 极简版（`ios/minimal` 分支）

> 本文件已入库，任何 AI / 机器检出本分支即可读到。根目录 `AGENTS.md`（本地，
> 不入库）管 macOS 试用版，职责互不覆盖；两边冲突时以各自分支范围为准。

## 分支使命

给妈妈做一个**极简的 iPhone 播放 & 下载 App**：

- 只做四件事：**搜索 → 播放 / 下载 / 本地（已下载）**；
- 长辈友好：大字号、大按钮、少层级、无复杂设置、无账号概念（首次替她登录一次即可）；
- 明确不做：歌单管理、推荐雷达、私人 FM、均衡器、多语言、桌面端功能对齐……

**下一步**（不在本分支范围）：极简版验收后，在此基础上扩展作者自用完整版。
设计取舍优先「极简版能直接继承」的结构，但**不提前实现**自用版功能。

## 技术路线（已定，勿再讨论）

**原生 SwiftUI iOS App + Rust 静态库**，与 `native/macos` 同代架构。

- **禁止**沿用 `crates/alger-bridge` 的 stdio 子进程模型：iOS 不允许 fork/exec。
  新建 `crates/alger-ffi`（staticlib / C ABI），依赖 `alger-core`——它已是纯 lib
  crate，依赖（reqwest+rustls / tokio / lofty）全部兼容 `aarch64-apple-ios`。
- **复用** JSON-line 协议的**语义**（dispatch 方法名 / 错误码，见
  `crates/alger-bridge/src/main.rs` 的 `dispatch`），Swift 端心智不变；
  实现可改为进程内调用（如后台线程 + 队列），不必逐字复刻 stdio。
- UI / 分层照抄 `native/macos`：SwiftPM 包、AlgerKit（桥接客户端 + 播放器 + 下载器）
  与 AlgerApp（界面）分目录、`AppModel` 状态中枢、AVFoundation 播放
  （参考 `PlaybackController`，注意 iOS 需 AVAudioSession 分类与激活）。
- `src-tauri/gen/apple`（Tauri iOS 管线）与 `scripts/build-ios.sh` 在本分支
  **冻结不动**，仅作签名 / 真机安装（devicectl）命令参考。

## 目录规划（本分支新增）

```
native/ios/                SwiftPM 包
  Sources/AlgerKit/        FFI 桥接客户端 + 播放器 + 下载器
  Sources/AlgerApp/        SwiftUI 界面（搜索 / 播放 / 本地 三 Tab）
  Tests/AlgerKitTests/
  AGENTS.md                本文件
crates/alger-ffi/          Rust 静态库 crate（依赖 alger-core）
```

## 硬约束

1. **保真继承现状**：不动 `native/macos` 与 `crates/*` 既有行为；改 `alger-core`
   必须先跑它的测试（见下），改桥接相关才跑 `alger-bridge` 测试。
2. **iOS 路径与后台**：
   - 会话 / 设置 / 已下载音频放 App 容器（`FileManager` 的 Application Support /
     Documents），**不照搬 macOS 绝对路径**；`alger-core` 里的 `dirs` crate 在
     iOS 返回值不可靠，路径一律由 Swift 层传入 Rust；
   - 后台播放：`UIBackgroundModes: audio` + AVAudioSession 正确分类与中断处理；
   - 「文件」App 可见下载目录：`UIFileSharingEnabled` +
     `LSSupportsOpeningDocumentsInPlace`（参考 `src-tauri/Info.ios.plist`）。
3. **签名**：Team `9SVGN86A32`、开发签名；bundle id 用新值（如
   `com.alger.music.ios.minimal`），不与 Tauri 版 `com.alger.music.ios` 冲突。
4. **不破坏既有资产**：`dist/`、`~/Library` 用户数据、`.tools/` 一律不碰；
   Tauri iOS 工程不改不删。

## 检查（每次改动后跑对应的）

```sh
cargo test --manifest-path crates/alger-core/Cargo.toml   # 动了 core
cargo test --manifest-path crates/alger-bridge/Cargo.toml # 动了 bridge
sh scripts/test-swift.sh                                   # 动了 native/macos
# native/ios 与 crates/alger-ffi 就位后，在此补各自的测试命令
```

临时产物一律进 `.artifacts/`（已 gitignore），不留仓库根目录。
