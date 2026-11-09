# Alger Music

一款网易云音乐第三方客户端。macOS 原生试用版使用 **SwiftUI / AppKit + Rust**；
iOS 与保留的 Web 界面使用 **Tauri 2 + 轻量 TypeScript**。

> 本仓库自 5.2.0 起由 Electron/Vue 版本迁移而来。开发、构建与维护说明见 [`DEV.md`](./DEV.md)。
> 旧版本保留在 Git 标签 `archive/electron-vue-v5.1.0`（提交 `a6f50e9`）。

## 功能

- **登录**
  - 内置网易云网页登录窗口：登录成功后自动保存登录状态并校验账号；
  - 备用方式：手动粘贴浏览器 Cookie（需包含 `MUSIC_U`）；
  - 登录状态失效时会在启动时提示重新登录，退出登录会清理本机登录窗口的 Cookie。
- **歌单**
  - 读取「我的歌单」，按完整歌曲 ID 列表补齐全部歌曲（不受默认截断影响）；
  - macOS 本地 M3U8 歌单支持新建、修改、增删歌曲与排序；网络歌单只读，可浏览、播放和下载。
- **资料库（macOS）**：本地艺人、专辑使用并列目录列浏览；缺失标签统一归入 `Unrecognized`，标题只显示文件名。登录后可读取已关注艺人。
- **搜索**：按歌曲名 / 歌手搜索，可直接播放、下载或加入本地歌单 / 临时播放。
- **播放**：临时播放、上一首 / 下一首、播放 / 暂停和进度拖动；macOS 默认顺序播放，可切换随机并记住上次模式。
- **下载**：后台下载并展示进度；macOS 下载前审核本地已有版本，足够时直接复用，候选升级下载后实测确认再替换，迁移本地歌单引用并保留原标签与封面。无法确认质量时保守保留本地。
- **元信息（macOS）**：下载后自动补充空白标签；编辑器使用同一匹配规则，先预览再保存，歧义候选不自动采用。
- **第三方音源**：当官方地址不可用（VIP / 无版权 / 网络受限）时，按用户设置的顺序回退到
  酷狗 / 酷我 / 咪咕 / GD 音乐台等公开音源，全部为本地实现；某个音源不可用时会给出具体原因并继续尝试下一个。
- **界面**：macOS 原生界面使用系统符号和材质；Web / iOS 使用 [lucide](https://lucide.dev) 图标（内联 SVG，图标本身对读屏软件隐藏，
  可访问名称由按钮的 `aria-label` 提供）；浅色 / 深色跟随系统设置，强调色跟随系统的「强调色」偏好，
  运行中修改系统外观或强调色会实时生效。

## 使用

macOS 关闭主窗口（红色关闭按钮或 `⌘W`）会隐藏窗口，应用保留在 Dock，播放与下载继续。
点击 Dock 图标可恢复窗口；使用 `⌘Q` 或菜单「退出 Alger Music」完全退出。

macOS / iOS 使用地标双音符图标。macOS 首页采用统一方形封面和播放按钮；
本地优先、离线资料库、M3U8 与维护说明见 [`DEV.md`](./DEV.md)。

1. 启动应用，macOS 点击左下角账号打开登录与设置；Web / iOS 选择「登录」。
2. 点击「打开网易云网页登录」，在弹出的窗口中完成登录，登录成功后会自动关闭窗口。
   - 若网页登录不可用，可在浏览器登录网易云音乐后复制整站 Cookie 粘贴到「手动粘贴 Cookie」输入框。
3. 登录后即可在左侧看到自己的歌单，点击歌单查看完整歌曲列表。

### 关于第三方音源

- 音源在「设置」中启用与排序，默认启用 `pyncmd`、`gdmusic`、`kugou`。
- 第三方音源依赖外部服务，可用性由服务方决定；解析失败时应用会显示具体原因
  （例如「返回中无有效播放地址」），而不是静默失败。
- 解析得到的地址会在使用前做一次可用性探测，失效地址不会阻断后续音源。

### 数据存放

- 登录信息（Cookie）只保存在本机：`~/Library/Application Support/AlgerMusicPlayer/session.json`
  （长期试用版为 `AlgerMusicPlayer.trial/session.json`；文件权限 `0600`），不会上传、不会写入日志。iOS 版为 App 沙盒内的同相对路径
  （`Library/Application Support/AlgerMusicPlayer/session.json`），不出现在「文件」App 中。
- 下载目录默认为 `~/Music/AlgerMusic`，可在「设置」中更改。
  iOS 版固定为 App 沙盒 `Documents/AlgerMusic`，不可更改；该目录对用户可见，
  可在系统「文件」App → 我的 iPhone → Alger Music → AlgerMusic 中查看、就近打开下载的文件。

## 开发

macOS 原生改版正在进行：已加入独立 Rust 核心、JSON 行桥接和 Swift `AlgerKit` 基础库。
SwiftUI/AppKit、下载去重与升级、自动保存、元信息补全与编辑、原生打包均已实现。
当前按“核心可用后试用、反馈驱动迭代”推进：播放、添加撤回与打包阻塞已修复，
本轮 Swift 324 项、Rust core 151 项 / bridge 20 项，以及前端只读与播放回归通过。
界面采用无标题通栏窗口、左下固定账号和底部悬浮玻璃播放条。
扫描结果写入本地资料库；设置随改随存；首页使用封面卡片与悬浮提示。
曲目单击「+」加入临时播放，右键或长按选择本地歌单；网络歌单保持只读。
原生试用版已构建验证并安装；长期试用入口为 `dist/AlgerMusicPlayer.app`。
验证范围、桌面锁定导致的点击验收限制与后续反馈安排见 DEV.md 顶部。
原生库测试使用完整 Xcode 和项目 Rust 工具链，夹具与构建产物放在 `.artifacts/`，不使用真实账号数据：

```bash
sh scripts/test-swift.sh   # 构建桥接，运行 SwiftPM 测试
sh scripts/run-native-app.sh --seconds 12  # 使用 .artifacts 隔离数据试跑原生界面
```

```bash
# 依赖
# - Rust stable（https://rustup.rs）
# - Node.js 18+ 或 Bun
# - Xcode 命令行工具（macOS）

bun install          # 安装前端依赖（生成 bun.lock）
bun run typecheck    # 前端类型检查
bun run test         # 播放核心验收 + Rust 单元测试
bun run lint         # 类型检查 + cargo fmt/clippy

# 启动开发环境（Tauri + 前端热更新）
bun run tauri:dev

# 打包 macOS 应用
bun run tauri:build
```

打包产物位于：

```
src-tauri/target/release/bundle/macos/Alger Music.app
```

长期试用：`scripts/install-dist.sh` 已切换为原生 SwiftPM + Rust **试用版**构建；
刷新前先完成 DEV.md 所列检查，脚本验证新包通过后才替换旧版。
脚本使用独立 identifier 与试用数据目录，先验证再安装到 `dist/AlgerMusicPlayer.app`；
清理脚本保留这些持久数据。
`dist/AlgerMusicPlayer.app` 是唯一的长期应用入口，脚本不再创建 `/Applications` 快捷方式，
避免 `/Applications` 与 `dist/` 形成重复启动入口。
`scripts/install-dist.sh` 先校验新应用再替换旧版，并在退出时自动清理；
仅在应用本身有重大改动或明确需要时才会重新编译刷新试用版。
`sh scripts/clean.sh` 清理项目构建 / 测试残留及 `.artifacts/` 中的临时文档，
保留 `dist/` 和所有用户数据（包括普通版与试用版）；`--dry-run` 可预览。详见 [`DEV.md`](./DEV.md)。

## 许可证

- 本项目自身代码：[MIT](./LICENSE)
- 移植自第三方项目的部分（第三方音源算法、酷我改造版 DES、网易云接口加密）遵循各自上游许可证，
  逐文件说明见 [`THIRD_PARTY_LICENSES.md`](./THIRD_PARTY_LICENSES.md)。
- 网易云音乐相关接口与资源版权归网易 / 网易云音乐所有，本项目仅供个人学习与个人使用。
