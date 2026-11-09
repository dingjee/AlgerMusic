# 第三方代码归属与许可证说明

本项目在从 Electron/Vue 迁移到 Rust/Tauri 2 的过程中，**移植**了若干第三方项目的算法实现。
为避免把所有代码都错误地标注为 MIT，这里逐项说明来源与许可证。

| 模块 / 文件 | 来源 | 上游许可证 | 说明 |
| --- | --- | --- | --- |
| `src-tauri/src/sources/kwdes.rs` | [`@unblockneteasemusic/server`](https://github.com/UnblockNeteaseMusic/server) v0.27.10 `src/kwDES.js`（其算法又源自 [XuShaohua/kwplayer](https://github.com/XuShaohua/kwplayer) 与 [Levi233/MusicPlayer](https://github.com/Levi233/MusicPlayer)） | **LGPL-3.0-only** | 酷我 `mobi.s` 接口使用的「改造版 DES」（自定义 E 表与 S 盒），逐位移植 |
| `src-tauri/src/sources/kugou.rs` | `@unblockneteasemusic/server` v0.27.10 `src/provider/kugou.js` | **LGPL-3.0-only** | 酷狗搜索 / `trackercdn` 换链算法 |
| `src-tauri/src/sources/kuwo.rs` | `@unblockneteasemusic/server` v0.27.10 `src/provider/kuwo.js` | **LGPL-3.0-only** | 酷我搜索 / `mobi.s` 换链算法 |
| `src-tauri/src/sources/migu.rs` | `@unblockneteasemusic/server` v0.27.10 `src/provider/migu.js` | **LGPL-3.0-only** | 咪咕搜索 / `listen-url` 换链算法 |
| `src-tauri/src/sources/probe.rs` | `@unblockneteasemusic/server` v0.27.10 `src/provider/match.js` 中的 `decode()` | **LGPL-3.0-only** | 从音频字节探测码率（MP3 帧头 / FLAC / ID3） |
| `src-tauri/src/sources/gdstudio.rs`（`pyncmd` 部分） | `@unblockneteasemusic/server` v0.27.10 `src/provider/pyncmd.js` | **LGPL-3.0-only** | GD 音乐台网易云直连转码 |
| `src-tauri/src/sources/gdstudio.rs`（`gdmusic` 部分） | 本仓库旧版 `src/renderer/api/gdmusic.ts` | MIT（本仓库） | GD 音乐台多平台搜索与标题 / 歌手匹配 |
| `src-tauri/src/crypto.rs` | [NeteaseCloudMusicApi](https://github.com/Binaryify/NeteaseCloudMusicApi)（MIT，Copyright (c) 2013-2022 Binaryify）及其增强分支 [`neteasecloudmusicapienhanced/api-enhanced`](https://github.com/neteasecloudmusicapienhanced/api-enhanced)（MIT） | **MIT** | `eapi` / `weapi` / `linuxapi` 加密算法 |
| `src-tauri/src/netease/*` | 同上 | **MIT** | 网易云接口端点与数据模型 |
| `frontend/src/icons.ts` | [lucide](https://github.com/lucide-icons/lucide) | **ISC** | 界面图标（`IconNode` 数据渲染为内联 SVG） |
| `frontend/src/*`（其余） | 本仓库自有 | **MIT** | 前端界面代码 |

## 许可证结论

- 本仓库自身新增的代码（前端、Tauri 壳、下载管理、会话管理、UI 等）沿用 **MIT**（见 `LICENSE`）。
- 上述标注 **LGPL-3.0-only** 的文件属于 LGPL-3.0-only 授权：
  - 这些文件以 SPDX 标识 `SPDX-License-Identifier: LGPL-3.0-only` 标注在文件头部；
  - 许可证全文见 `licenses/LGPL-3.0-only.txt`；
  - 再次分发本项目时，必须以 **LGPL-3.0-only** 继续提供这些文件，并保留其原始版权声明；
  - 若对这些文件做了修改，修改后的版本同样需要以 LGPL-3.0-only 提供。
- 标注 **MIT** 的文件保留上游 MIT 许可条款与版权声明。
- 标注 **ISC** 的文件（lucide 图标数据）保留上游 ISC 许可条款与版权声明。

## 第三方服务说明

第三方音源解析会访问以下外部服务，其可用性由各自服务方决定，本项目不做任何承诺：

- `music-api.gdstudio.xyz`（GD 音乐台）
- `mobilecdn.kugou.com`、`trackercdn.kugou.com`（酷狗）
- `search.kuwo.cn`、`mobi.kuwo.cn`（酷我）
- `m.music.migu.cn`、`app.c.nf.migu.cn`（咪咕）

网易云音乐相关接口与资源版权归网易 / 网易云音乐所有；本项目仅供个人学习与个人使用。
