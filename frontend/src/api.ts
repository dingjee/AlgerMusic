/** 应用能力封装：登录、歌单、搜索、播放、下载等操作都通过这里调用。 */

import { invoke } from '@tauri-apps/api/core';
import { listen, type UnlistenFn } from '@tauri-apps/api/event';

import type {
  Account,
  DownloadItem,
  Lyric,
  PlayableUrl,
  Playlist,
  PlaylistDetail,
  Snapshot,
  Song,
} from './types';

export const api = {
  snapshot: (): Promise<Snapshot> => invoke('get_snapshot'),

  loginWithCookie: (cookie: string): Promise<Snapshot> =>
    invoke('login_with_cookie', { cookie }),

  openLoginWindow: (): Promise<void> => invoke('open_login_window'),

  logout: (): Promise<Snapshot> => invoke('logout'),

  updateSettings: (settings: {
    quality?: string;
    sources?: string[];
    downloadDir?: string;
  }): Promise<Snapshot> => invoke('update_settings', settings),

  userPlaylists: (): Promise<Playlist[]> => invoke('user_playlists'),

  playlistDetail: (id: number): Promise<PlaylistDetail> =>
    invoke('playlist_detail', { id }),

  // 网络歌单只读：这里只封装读取接口。

  searchSongs: (keywords: string, limit?: number): Promise<[Song[], number]> =>
    invoke('search_songs', { keywords, limit: limit ?? null }),

  lyric: (id: number): Promise<Lyric> => invoke('get_lyric', { id }),

  resolvePlayable: (song: Song): Promise<PlayableUrl> =>
    invoke('resolve_playable', { song }),

  downloadSong: (song: Song): Promise<string> => invoke('download_song', { song }),

  listDownloads: (): Promise<DownloadItem[]> => invoke('list_downloads'),

  openDownloadFolder: (): Promise<void> => invoke('open_download_folder'),

  revealFile: (path: string): Promise<void> => invoke('reveal_file', { path }),

  pickDownloadDir: (): Promise<string> => invoke('pick_download_dir'),

  /** 当前系统强调色（十六进制），不可用时返回 null。 */
  themeAccent: (): Promise<string | null> => invoke('theme_accent'),

  /** 上报本机 WebView 实测无法播放的音频格式（空列表 = 全部支持）。 */
  setUnsupportedAudioFormats: (extensions: string[]): Promise<void> =>
    invoke('set_unsupported_audio_formats', { extensions }),
};

export function onDownloadProgress(
  handler: (item: DownloadItem) => void,
): Promise<UnlistenFn> {
  return listen<DownloadItem>('download://progress', (event) =>
    handler(event.payload),
  );
}

export function onLoginStatus(
  handler: (event: { status: string; message: string }) => void,
): Promise<UnlistenFn> {
  return listen<{ status: string; message: string }>('login://status', (event) =>
    handler(event.payload),
  );
}

/** 会话失效事件（Cookie 过期 / 被顶号）。 */
export function onSessionExpired(
  handler: (message: string) => void,
): Promise<UnlistenFn> {
  return listen<{ message: string }>('session://expired', (event) =>
    handler(event.payload.message),
  );
}

/**
 * 会话校验结果事件（`session://check`）。
 *
 * 状态：
 * - `saveFailed`：登录状态已失效 / 账号信息写盘失败 —— **必须让用户知道**，
 *   否则磁盘上的身份与界面显示不一致（审查 E0-2）。
 * - `unverified`：暂时无法校验（网络 / 上游临时故障），已保留本机 Cookie。
 */
export function onSessionCheck(
  handler: (event: { status: string; message: string }) => void,
): Promise<UnlistenFn> {
  return listen<{ status: string; message: string }>('session://check', (event) =>
    handler(event.payload),
  );
}

export type { Account };
