/** 应用数据类型定义。 */

export interface Artist {
  id: number;
  name: string;
}

export interface Album {
  id: number;
  name: string;
  picUrl: string;
}

export interface Song {
  id: number;
  name: string;
  artists: Artist[];
  album: Album;
  durationMs: number;
  fee: number;
  copyright: number;
}

export interface Creator {
  userId: number;
  nickname: string;
  avatarUrl: string;
}

export interface Playlist {
  id: number;
  name: string;
  description: string | null;
  coverImgUrl: string;
  trackCount: number;
  creator: Creator;
  trackIds: number[];
  subscribed: boolean;
}

export interface Account {
  userId: number;
  nickname: string;
  avatarUrl: string;
  vipType: number;
}

export interface Snapshot {
  loggedIn: boolean;
  hasCookie: boolean;
  account: Account | null;
  quality: string;
  sources: string[];
  downloadDir: string;
  sessionPath: string;
  accountVerified: boolean;
  /** 运行平台：`macos` / `ios` / 其它。 */
  platform: string;
  /**
   * 会话文件载入问题（损坏 / 读失败 / 已拒绝写入）。非空时必须明确提示，
   * 否则用户只会在后续保存失败时看到症状（E1-9）。
   */
  loadIssue: string | null;
}

export interface PlaylistDetail {
  playlist: Playlist;
  songs: Song[];
  missing: number;
}

export interface PlayableUrl {
  url: string;
  br: number;
  size: number;
  source: string;
  sourceLabel: string;
  thirdParty: boolean;
  note: string | null;
}

export interface Lyric {
  lrc: string;
  tlyric: string;
  yrc: string;
}

export interface DownloadItem {
  id: number;
  name: string;
  artist: string;
  path: string;
  downloaded: number;
  total: number;
  status: 'pending' | 'running' | 'done' | 'failed';
  error: string | null;
  source: string | null;
}

export interface LoginStatusEvent {
  status: 'pending' | 'success' | 'failed' | 'timeout';
  message: string;
}

export const SOURCE_LABELS: Record<string, string> = {
  pyncmd: 'GD 音乐台(网易云)',
  gdmusic: 'GD 音乐台',
  kugou: '酷狗',
  kuwo: '酷我',
  migu: '咪咕',
};

export const QUALITY_LABELS: Record<string, string> = {
  standard: '标准 (128k)',
  higher: '较高 (192k)',
  exhigh: '极高 (320k)',
  lossless: '无损 (FLAC)',
  hires: 'Hi-Res',
  sky: '沉浸环绕声',
};
