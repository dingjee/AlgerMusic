/** 播放核心：队列、解析、错误提示。 */

import { api } from './api';
import { toast } from './dom';
import { formatBitrate, formatSize } from './format';
import { setState, state } from './store';
import type { PlayableUrl, Song } from './types';

const audio = new Audio();
audio.preload = 'none';

// 说明：iOS 上无需手势解锁逻辑。wry 0.57.1 的 WebViewAttributes 默认
// `autoplay: true`，wkwebview 实现据此设置
// `setMediaTypesRequiringUserActionForPlayback(None)`（iOS 10+），
// 即媒体播放不要求用户手势，异步解析完成后的 `play()` 可以直接生效。

/**
 * 能力上报的就绪 Promise（只执行一次）。
 *
 * 首次解析播放前必须等待上报完成，否则「第一首歌」会在后端过滤集合
 * 为空时解析，可能拿到本机放不了的格式；后续播放直接复用已完成的结果。
 */
let capabilitiesReady: Promise<void> | null = null;

/**
 * 用 `audio.canPlayType` 实测本机 WebView 的解码能力并上报后端。
 *
 * 后端解析链据此把「探测可用但本机放不了」的格式视为不可用并回退
 * 下一个音源。iOS 的格式支持随 WebKit 版本演进（18.4 起支持
 * Ogg/Opus/Vorbis），因此以实测为准，不做平台硬编码。
 *
 * 扩展名与后端 `guess_extension` 的输出保持一致：AAC（ADTS/MP4）在
 * 后端统一判为 `m4a`，因此这里只按 `audio/mp4` 探测一次，不再单列
 * `aac`，避免「上报了 aac、后端却返回 m4a」的口径错位。
 */
export function reportAudioCapabilities(): Promise<void> {
  if (capabilitiesReady) return capabilitiesReady;
  const probes: Array<[string, string]> = [
    ['mp3', 'audio/mpeg'],
    ['m4a', 'audio/mp4'],
    ['flac', 'audio/flac'],
    ['wav', 'audio/wav'],
    ['ogg', 'audio/ogg; codecs="vorbis"'],
    ['opus', 'audio/ogg; codecs="opus"'],
    ['webm', 'audio/webm; codecs="opus"'],
  ];
  const unsupported: string[] = [];
  for (const [ext, mime] of probes) {
    const can = typeof audio.canPlayType === 'function' ? audio.canPlayType(mime) : 'maybe';
    if (!can) unsupported.push(ext);
  }
  capabilitiesReady = api
    .setUnsupportedAudioFormats(unsupported)
    .catch(() => undefined)
    .then(() => undefined);
  return capabilitiesReady;
}

let currentUrl = '';

/**
 * 解析请求代号。
 *
 * 每次发起解析都会自增；异步结果回来后若代号已过期则直接丢弃。
 * 这样可以保证：
 * - 解析期间切歌时，旧结果不会覆盖新曲目；
 * - 清空队列 / 播放到队尾时，待处理的解析会被作废；
 * - 失败自动跳下一首的定时器不会推进用户后来选择的队列。
 */
let resolveToken = 0;
/** 是否正在解析（用于阻止解析期间的播放/暂停操作触碰旧地址）。 */
let isResolving = false;

export interface PlayerEvents {
  onStateChange?: () => void;
  onTrackChange?: (song: Song | null) => void;
  onMessage?: (message: string, kind: 'info' | 'error' | 'success') => void;
}

const events: PlayerEvents = {};

export function configurePlayer(listeners: PlayerEvents): void {
  Object.assign(events, listeners);
}

export function currentSong(): Song | null {
  const { queue, queueIndex } = state;
  if (queueIndex < 0 || queueIndex >= queue.length) return null;
  return queue[queueIndex];
}

export function isPlaying(): boolean {
  return !audio.paused && !audio.ended;
}

export function audioElement(): HTMLAudioElement {
  return audio;
}

/** 停止播放并清空当前地址（不触发错误事件）。 */
function stopAudio(): void {
  audio.pause();
  audio.removeAttribute('src');
  audio.load();
  currentUrl = '';
}

/** 设置播放队列并从指定位置开始。 */
export function setQueue(songs: Song[], startIndex = 0): void {
  if (songs.length === 0) {
    // 作废待处理的解析，停止播放
    resolveToken += 1;
    isResolving = false;
    stopAudio();
    setState({ queue: [], queueIndex: -1 });
    events.onStateChange?.();
    return;
  }
  const index = Math.max(0, Math.min(startIndex, songs.length - 1));
  setState({ queue: songs, queueIndex: index });
  events.onStateChange?.();
  void playCurrent();
}

/** 追加到队列末尾。 */
export function enqueue(songs: Song[]): void {
  if (songs.length === 0) return;
  setState({ queue: [...state.queue, ...songs] });
  events.onStateChange?.();
  toast(`已加入播放队列（${songs.length} 首）`, 'success');
}

/** 播放当前曲目。 */
export async function playCurrent(): Promise<void> {
  const song = currentSong();
  if (!song) return;
  const token = ++resolveToken;
  isResolving = true;
  // 先断开旧地址，避免解析期间误播上一首
  audio.pause();
  audio.removeAttribute('src');
  audio.load();
  events.onStateChange?.();
  try {
    // 首次播放前先等能力上报完成（内部只执行一次），确保后端解析链
    // 拿到本机真实支持的格式集合后再解析。token 必须在 await 之前自增、
    // 在 await 之后校验，防止上报等待期间用户切歌导致的过时解析。
    await reportAudioCapabilities();
    if (token !== resolveToken) return;
    const playable: PlayableUrl = await api.resolvePlayable(song);
    // 结果过期：说明用户在解析期间切歌 / 清空了队列，直接丢弃
    if (token !== resolveToken) return;
    if (playable.note) {
      toast(playable.note, 'info');
    }
    currentUrl = playable.url;
    audio.src = playable.url;
    await audio.play();
    if (token !== resolveToken) return;
    const extra = [
      formatBitrate(playable.br),
      playable.size ? formatSize(playable.size) : '',
      playable.sourceLabel,
    ].filter(Boolean);
    toast(`正在播放：${song.name}（${extra.join(' · ')}）`, 'success');
  } catch (error) {
    if (token !== resolveToken) return;
    const message = errorMessage(error);
    toast(`播放失败：${message}`, 'error');
    events.onMessage?.(message, 'error');
    // 连续失败时自动跳到下一首；定时器必须校验请求代号与当前曲目，
    // 否则会推进用户后来选择的队列。
    if (state.queueIndex >= 0 && state.queueIndex < state.queue.length - 1) {
      const failedSongId = song.id;
      window.setTimeout(() => {
        if (token !== resolveToken) return;
        const current = currentSong();
        if (!current || current.id !== failedSongId) return;
        void next();
      }, 600);
    }
  } finally {
    if (token === resolveToken) {
      isResolving = false;
      events.onStateChange?.();
      events.onTrackChange?.(song);
    }
  }
}

/** 暂停 / 继续。 */
export function togglePlay(): void {
  // 解析进行中：不恢复旧地址，也不重新发起解析
  if (isResolving) return;
  if (!audio.src) {
    void playCurrent();
    return;
  }
  if (audio.paused) {
    void audio.play().catch((e) => toast(`播放失败：${errorMessage(e)}`, 'error'));
  } else {
    audio.pause();
  }
  events.onStateChange?.();
}

export function next(): void {
  const { queue, queueIndex } = state;
  if (queue.length === 0) return;
  const index = queueIndex + 1;
  if (index >= queue.length) {
    // 队尾：作废待处理的解析并停止播放
    resolveToken += 1;
    isResolving = false;
    stopAudio();
    setState({ queueIndex: queue.length - 1 });
    events.onStateChange?.();
    return;
  }
  setState({ queueIndex: index });
  events.onStateChange?.();
  void playCurrent();
}

export function previous(): void {
  const { queue, queueIndex } = state;
  if (queue.length === 0) return;
  if (audio.currentTime > 3) {
    audio.currentTime = 0;
    return;
  }
  const index = queueIndex - 1;
  if (index < 0) {
    audio.currentTime = 0;
    return;
  }
  setState({ queueIndex: index });
  events.onStateChange?.();
  void playCurrent();
}

export function seek(seconds: number): void {
  if (Number.isFinite(seconds)) {
    audio.currentTime = seconds;
  }
}

export function setVolume(value: number): void {
  audio.volume = Math.min(1, Math.max(0, value));
}

export function getVolume(): number {
  return audio.volume;
}

/** 重新解析当前曲目（切换音源后使用）。 */
export async function reparseCurrent(): Promise<void> {
  const song = currentSong();
  if (!song) return;
  stopAudio();
  await playCurrent();
}

export function currentSourceUrl(): string {
  return currentUrl;
}

audio.addEventListener('ended', () => {
  next();
});

audio.addEventListener('timeupdate', () => {
  events.onStateChange?.();
});
audio.addEventListener('play', () => events.onStateChange?.());
audio.addEventListener('pause', () => events.onStateChange?.());
audio.addEventListener('error', () => {
  if (!audio.src) return;
  const code = audio.error?.code;
  const messages: Record<number, string> = {
    1: '加载被中止',
    2: '网络错误',
    3: '解码失败',
    4: '音频格式不受支持或地址失效',
  };
  const message = messages[code ?? 0] ?? '未知播放错误';
  toast(`播放失败：${message}`, 'error');
  events.onMessage?.(message, 'error');
});

/** 把抛出的错误转成可读文本。 */
export function errorMessage(error: unknown): string {
  if (typeof error === 'string') return error;
  if (error instanceof Error) return error.message;
  if (error && typeof error === 'object' && 'message' in error) {
    return String((error as { message: unknown }).message);
  }
  return String(error);
}
