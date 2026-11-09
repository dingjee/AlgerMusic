/** 搜索视图。 */

import { api } from '../api';
import { clear, el, iconButton, iconTextButton, input, toast } from '../dom';
import { artistText, formatDuration } from '../format';
import { enqueue, errorMessage, setQueue } from '../player';
import type { Song } from '../types';

let lastResults: Song[] = [];

export function renderSearch(root: HTMLElement, keyword: string): void {
  clear(root);
  const searchInput = input({
    placeholder: '搜索歌曲名或歌手',
    value: keyword,
    spellcheck: 'false',
  });
  const go = iconTextButton('search', '搜索', () => void run());
  searchInput.addEventListener('keydown', (event) => {
    if ((event as KeyboardEvent).key === 'Enter') void run();
  });

  const bar = el('div', { class: 'card row gap search-bar' }, searchInput, go);
  root.appendChild(bar);

  const results = el('div', { class: 'song-list card' });
  root.appendChild(results);

  async function run(): Promise<void> {
    const value = searchInput.value.trim();
    if (!value) {
      toast('请输入搜索关键词', 'error');
      return;
    }
    clear(results);
    results.appendChild(el('div', { class: 'muted', text: '搜索中…' }));
    try {
      const [songs, total] = await api.searchSongs(value);
      lastResults = songs;
      clear(results);
      results.appendChild(
        el('div', { class: 'muted small pad', text: `共 ${total} 首，展示 ${songs.length} 首` }),
      );
      if (songs.length === 0) {
        results.appendChild(el('div', { class: 'muted pad', text: '没有找到相关歌曲' }));
        return;
      }
      songs.forEach((song, index) => {
        const row = el('div', { class: 'song-row song-row--search' });
        row.appendChild(el('span', { class: 'song-index', text: String(index + 1) }));
        const info = el('div', { class: 'song-info' });
        info.appendChild(el('div', { class: 'song-name', text: song.name, title: song.name }));
        info.appendChild(el('div', { class: 'muted small', text: artistText(song.artists) }));
        row.appendChild(info);
        row.appendChild(el('span', { class: 'muted small song-duration', text: formatDuration(song.durationMs) }));
        const cell = el('div', { class: 'row gap song-actions' });
        cell.appendChild(
          iconButton('play', () => setQueue(songs, index), {
            'aria-label': `播放 ${song.name}`,
          }),
        );
        cell.appendChild(
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
        // 网络歌单是只读的：搜索结果只能加入 **本地临时播放队列**，
        // 不再提供「加入歌单」这类会改动云端歌单的入口。
        cell.appendChild(
          iconTextButton('queue', '加入队列', () => enqueue([song]), {
            'aria-label': `加入队列 ${song.name}`,
          }),
        );
        row.appendChild(cell);
        results.appendChild(row);
      });
    } catch (error) {
      clear(results);
      results.appendChild(
        el('div', { class: 'error pad', text: `搜索失败：${errorMessage(error)}` }),
      );
    }
  }

  if (keyword.trim()) void run();
}

export function searchResults(): Song[] {
  return lastResults;
}
