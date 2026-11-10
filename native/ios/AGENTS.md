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
  `crates/alger-bridge` 已拆出 **lib target**（`Bridge` / `dispatch`），
  `crates/alger-ffi` 是它的 **进程内 C ABI 封装**（staticlib）。
- **复用** JSON-line 协议语义（dispatch 方法名 / 错误码），Swift 端心智不变；
  传输改为：Rust 把每条协议行交给 Swift 注册的**行回调**。
- UI / 分层照抄 `native/macos`：SwiftPM 包、AlgerKit（客户端 + 播放器 + 下载）、
  App 层（状态中枢 + 页面）、AVFoundation 播放。
- `src-tauri/gen/apple`（Tauri iOS 管线）与 `scripts/build-ios.sh` 在本分支
  **冻结不动**，仅作签名 / 真机安装（devicectl）命令参考。

## 目录（现状）

```
crates/alger-bridge/src/lib.rs   桥接核心（Bridge / dispatch）：stdio 与 FFI 共用
crates/alger-ffi/src/lib.rs      进程内 C ABI：init / call / shutdown + 行回调
native/ios/ffi/alger_ffi.h       C 头文件（与 alger-ffi 的 C ABI 一一对应）
native/ios/Package.swift         SwiftPM：binaryTarget(AlgerFFI) + AlgerKit + 测试
native/ios/Sources/AlgerKit/     FFIClient / BridgeService / 模型 / 播放器 / 下载
native/ios/Sources/AlgerApp/     SwiftUI 应用层（登录门 + 找歌 / 播放 / 已下载）
native/ios/App/project.yml       Xcode 工程唯一真源（xcodegen 生成 .xcodeproj）
scripts/build-ios-ffi.sh         构建各平台 slice → libs/AlgerFFI.xcframework
scripts/test-ios-swift.sh        宿主（macOS）跑 Swift 包测试
scripts/build-ios-app.sh         生成工程 + xcodebuild 构建（sim / device）
```

## 命令（都从仓库根跑）

```sh
# 1) FFI 静态库 → xcframework（macOS 宿主测试 / iOS 真机 / 模拟器 共用一份）
sh scripts/build-ios-ffi.sh all        # 产物：native/ios/libs/AlgerFFI.xcframework（不入库）

# 2) Swift 包测试（宿主 arm64 macOS；缺 xcframework 会自动先构建）
sh scripts/test-ios-swift.sh

# 3) iOS 应用构建
sh scripts/build-ios-app.sh sim                    # 模拟器 Debug（不签名）
sh scripts/build-ios-app.sh device                 # 真机 Debug（Team 9SVGN86A32 自动签名）
sh scripts/build-ios-app.sh device --install       # 真机构建并安装（devicectl）

# 4) Rust 侧测试
cargo test --manifest-path crates/alger-core/Cargo.toml
cargo test --manifest-path crates/alger-bridge/Cargo.toml
cargo test --manifest-path crates/alger-ffi/Cargo.toml
```

## 硬约束

1. **保真继承现状**：不动 `native/macos` 与 `crates/*` 既有行为；改 `alger-core`
   必须先跑它的测试，改桥接相关才跑 `alger-bridge` / `alger-ffi` 测试。
2. **iOS 路径与后台**：
   - 会话 / 设置落 `Application Support/AlgerMusic/`，下载落
     `Documents/Downloads/`（**文件 App 可见**）；路径 **一律由 Swift 计算后
     传给 Rust**（`ContainerPaths`）——`alger-core` 里的 `dirs` crate 在 iOS
     不可靠；
   - 后台播放：`UIBackgroundModes: audio` + AVAudioSession `.playback`；
   - 登录：WKWebView 只用于登录页，取 `MUSIC_U` Cookie 交桥接校验后落盘。
3. **签名**：Team `9SVGN86A32`、开发签名；bundle id `com.alger.music.ios.minimal`
   （不与 Tauri 版 `com.alger.music.ios` 冲突）。
4. **不破坏既有资产**：`dist/`、`~/Library` 用户数据、`.tools/` 一律不碰；
   Tauri iOS 工程不改不删。

## 已知坑（踩过的，别再踩）

- **`DEVELOPER_DIR` 必须指向完整 Xcode**（`/Applications/Xcode.app/Contents/Developer`）：
  否则 iOS 交叉编译时 ring 的 build script 找不到 `iphoneos` SDK。
- **xcframework 不入库**：换机器 / 干净检出后，先跑 `scripts/build-ios-ffi.sh all`，
  否则 SwiftPM 载入 `binaryTarget` 直接失败。
- **shell 变量后紧跟全角标点**必须写成 `${VAR}`：非 UTF-8 locale 下 bash 会把
  全角字节并入变量名（`$MODE）` → `unbound variable`）。
- **部署目标 iOS 16**（`NavigationStack` 需要 16+）。
- **模拟器 slice 只有 arm64**（Apple Silicon）；构建模拟器用
  `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`。
- **行回调的字符串所有权转给 Swift**：Swift 侧必须 `free()`（见
  `FFIClient.swift` 的 `deliver`）；漏 free 会泄漏，重复 free 会崩。
- **C 回调没有 context 指针**：响应行靠 **进程级唯一 id** 路由（`FFIRegistry`）；
  事件行无 id，广播给全部客户端。
- **xcodegen 生成的 Info.plist 是静态文件**：版本号必须写成
  `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`——写死会让
  `xcodebuild CURRENT_PROJECT_VERSION=…` 覆盖失效（TestFlight 构建号被判重复）。
- **归档产物在 `.artifacts/ios-archive/`**（`clean.sh` 会清掉）；`.ipa` 在
  `.artifacts/ios-export/`。未签名包（`--no-sign`）只能本地看，**不能上传**。
- **签名团队是 `MFMGY838LG`（JI DING）**，不是 Tauri 版用的 `9SVGN86A32`：
  后者在本机 Xcode **没有账号**（报 No Account for Team / No Team Found in
  Archive）；前者是当前登录账号所属的**付费**团队，且钥匙串里已有
  Apple Distribution 证书。换团队时同步改 `project.yml` 的
  `DEVELOPMENT_TEAM` 与 `build-ios-testflight.sh` 的 `TEAM_ID`。
- **`CODE_SIGN_IDENTITY` 必须留空**（xcodegen 默认写 "iPhone Developer" 会
  匹配**开发**描述文件 → 导出报 No profiles for ... App Store；手写
  "Apple Distribution" 又报 conflicting provisioning settings）。
  留空由 Xcode 按 Archive 动作自动选分发身份 + App Store 描述文件
  （需 `-allowProvisioningUpdates` 让它自动建 App ID 与描述文件）。
- **CLI 归档的 Team 元数据为空**：`xcodebuild archive`（身份留空）写出的
  `xcarchive/Info.plist → ApplicationProperties.SigningIdentity / Team`
  是空串 → **Organizer 会报 "No Team Found in Archive"**（Organizer 会把
  归档**复制**进 `~/Library/Developer/Xcode/Archives/`，拖新包前先删旧副本）。
  两种解法：
  - **上传 .ipa 就行**（推荐）：Transporter.app 拖入
    `.artifacts/ios-export/AlgerMusicMinimal.ipa`，或 `altool --upload-app`
    （都 **不需要** Organizer）；
  - 要让 Organizer 可用：门户 **手动**建一个 App Store 描述文件（非
    Xcode managed），工程改 `CODE_SIGN_STYLE: Manual` +
    `PROVISIONING_PROFILE_SPECIFIER`（Xcode 自动建的描述文件带
    "Xcode managed" 标记，手动签名不认）。
