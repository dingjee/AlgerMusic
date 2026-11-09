/** 我的歌单：侧边栏列表与歌单详情（只读）。 */

import { api } from '../api';
import {
  clear,
  el,
  iconButton,
  iconTextButton,
  toast,
} from '../dom';
import { artistText, formatDuration } from '../format';
import { enqueue, errorMessage, setQueue } from '../player';
import { setState, state } from '../store';
import type { Playlist, Song } from '../types';

/** 侧边栏歌单列表。 */
export async function renderPlaylistSidebar(
  container: HTMLElement,
  onSelect: (id: number) => void,
): Promise<void> {
  clear(container);
  container.appendChild(el('div', { class: 'muted small', text: '加载中…' }));
  try {
    const playlists = await api.userPlaylists();
    clear(container);
    if (playlists.length === 0) {
      container.appendChild(el('div', { class: 'muted small', text: '暂无歌单' }));
      return;
    }
    for (const playlist of playlists) {
      const item = el(
        'button',
        {
          class: `side-item${
            state.playlistId === playlist.id ? ' side-item-active' : ''
          }`,
          type: 'button',
          title: playlist.name,
        },
        el('span', { class: 'side-name', text: playlist.name }),
        el('span', { class: 'muted small', text: String(playlist.trackCount) }),
      );
      item.addEventListener('click', () => onSelect(playlist.id));
      container.appendChild(item);
    }
  } catch (error) {
    clear(container);
    container.appendChild(
      el('div', { class: 'muted small', text: `加载失败：${errorMessage(error)}` }),
    );
  }
}

/**
 * 我的歌单概览（正文区）。
 *
 * 窄屏（iPhone）下侧栏的「歌单」列表会被隐藏，若正文区仍只显示
 * 「在左侧选择一个歌单」，手机端就完全无法选择歌单。这里在正文区直接
 * 列出歌单，所有平台通用。
 *
 * 只读：只拉取歌单列表并跳转。
 */
export async function renderPlaylistOverview(
  root: HTMLElement,
  onSelect: (id: number) => void,
): Promise<void> {
  clear(root);

  if (!state.snapshot?.loggedIn) {
    const card = el('div', { class: 'card' });
    card.appendChild(el('h3', { text: '我的歌单' }));
    card.appendChild(el('p', { class: 'muted', text: '登录后即可查看你的歌单。' }));
    card.appendChild(iconTextButton('login', '登录', () => setState({ view: 'login' })));
    root.appendChild(card);
    return;
  }

  const head = el('div', { class: 'card row gap wrap' });
  head.appendChild(el('h3', { class: 'grow', text: '我的歌单' }));
  head.appendChild(el('span', { class: 'muted small', text: '只读' }));
  root.appendChild(head);

  const list = el('div', { class: 'card playlist-overview-list' });
  root.appendChild(list);
  await renderPlaylistSidebar(list, onSelect);
}

/**
 * 歌单详情视图（只读）。
 *
 * 只展示歌单信息与曲目列表，并提供播放 / 下载 / 加入播放队列这类
 * **本地** 操作。
 */
export async function renderPlaylistDetail(
  root: HTMLElement,
  playlistId: number,
): Promise<void> {
  clear(root);
  root.appendChild(el('div', { class: 'muted', text: '加载歌单中…' }));

  let playlist: Playlist;
  let songs: Song[];
  try {
    const detail = await api.playlistDetail(playlistId);
    playlist = detail.playlist;
    songs = detail.songs;
  } catch (error) {
    clear(root);
    root.appendChild(
      el('div', { class: 'card' }, el('div', { class: 'error', text: `加载失败：${errorMessage(error)}` })),
    );
    return;
  }

  clear(root);
  const head = el('div', { class: 'detail-head card' });
  head.appendChild(
    el('div', { class: 'cover' }, playlist.coverImgUrl ? el('img', { src: playlist.coverImgUrl, alt: '' }) : el('span', { text: '♪' })),
  );
  const meta = el('div', { class: 'detail-meta' });
  meta.appendChild(el('h2', { text: playlist.name }));
  meta.appendChild(
    el('div', {
      class: 'muted small',
      text: `${playlist.creator.nickname || '未知'} · ${songs.length} 首`,
    }),
  );

  const actions = el('div', { class: 'row gap wrap' });
  actions.appendChild(
    iconTextButton('play', '播放全部', () => {
      if (songs.length > 0) setQueue(songs, 0);
    }),
  );
  actions.appendChild(el('span', { class: 'muted small', text: '只读' }));
  meta.appendChild(actions);
  head.appendChild(meta);
  root.appendChild(head);

  if (songs.length === 0) {
    root.appendChild(
      el('div', { class: 'card muted', text: '歌单内暂无歌曲，可在搜索结果中搜索并加入播放队列。' }),
    );
    return;
  }

  const list = el('div', { class: 'card song-list' });
  songs.forEach((song, index) => {
    const row = el('div', { class: 'song-row song-row--playlist' });
    row.appendChild(el('span', { class: 'song-index', text: String(index + 1) }));
    const info = el('div', { class: 'song-info' });
    info.appendChild(el('div', { class: 'song-name', text: song.name, title: song.name }));
    info.appendChild(el('div', { class: 'muted small', text: artistText(song.artists) }));
    row.appendChild(info);
    row.appendChild(el('span', { class: 'muted small song-duration', text: formatDuration(song.durationMs) }));
    const actionsCell = el('div', { class: 'row gap song-actions' });
    actionsCell.appendChild(
      iconButton('play', () => setQueue(songs, index), { 'aria-label': `播放 ${song.name}` }),
    );
    actionsCell.appendChild(
      iconButton(
        'download',
        async () => {
          try {
            toast('开始下载…', 'info');
            await api.downloadSong(song);
            toast('下载完成', 'success');
          } catch (error) {
            toast(errorMessage(error), 'error');
          }
        },
        { 'aria-label': `下载 ${song.name}` },
      ),
    );
    actionsCell.appendChild(
      iconButton('queue', () => enqueue([song]), { 'aria-label': `加入队列 ${song.name}` }),
    );
    row.appendChild(actionsCell);
    list.appendChild(row);
  });
  root.appendChild(list);
}
