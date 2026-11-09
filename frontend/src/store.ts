/** 全局应用状态（轻量发布订阅）。 */

import { api } from './api';
import type { Snapshot, Song } from './types';

export type ViewName =
  | 'login'
  | 'playlists'
  | 'playlist'
  | 'search'
  | 'downloads'
  | 'settings';

export interface AppState {
  snapshot: Snapshot | null;
  view: ViewName;
  /** 当前歌单 ID。 */
  playlistId: number | null;
  /** 当前搜索关键词。 */
  keyword: string;
  /** 播放队列。 */
  queue: Song[];
  queueIndex: number;
}

type Listener = (state: AppState) => void;

const listeners = new Set<Listener>();

export const state: AppState = {
  snapshot: null,
  view: 'login',
  playlistId: null,
  keyword: '',
  queue: [],
  queueIndex: -1,
};

export function subscribe(listener: Listener): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function emit(): void {
  for (const listener of listeners) listener(state);
}

export function setState(patch: Partial<AppState>): void {
  Object.assign(state, patch);
  emit();
}

export async function refreshSnapshot(): Promise<Snapshot> {
  const snapshot = await api.snapshot();
  setState({ snapshot });
  return snapshot;
}
