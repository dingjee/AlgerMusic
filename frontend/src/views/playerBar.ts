/** 底部播放条。 */

// 播放条 DOM 只创建一次，后续仅更新内容，避免重复绑定事件导致泄漏。
import { clear, el, iconButton } from '../dom';
import { artistText, formatDuration } from '../format';
import { icon } from '../icons';
import {
  audioElement,
  currentSong,
  getVolume,
  isPlaying,
  next,
  previous,
  reparseCurrent,
  setVolume,
  togglePlay,
} from '../player';

let root: HTMLElement | null = null;
let titleNode: HTMLElement | null = null;
let artistNode: HTMLElement | null = null;
let playButton: HTMLButtonElement | null = null;
let progress: HTMLInputElement | null = null;
let timeNode: HTMLElement | null = null;
let listenersBound = false;

export function renderPlayerBar(container: HTMLElement): void {
  root = container;
  clear(container);

  const info = el('div', { class: 'player-info' });
  titleNode = el('div', { class: 'song-name', text: '未在播放' });
  artistNode = el('div', { class: 'muted small', text: '从歌单或搜索结果中选择歌曲' });
  info.appendChild(titleNode);
  info.appendChild(artistNode);
  container.appendChild(info);

  const controls = el('div', { class: 'player-controls' });
  controls.appendChild(iconButton('prev', () => previous()));
  playButton = iconButton('play', () => togglePlay(), { class: 'btn btn-icon btn-primary' });
  controls.appendChild(playButton);
  controls.appendChild(iconButton('next', () => next()));
  controls.appendChild(
    iconButton('reparse', () => {
      void reparseCurrent();
    }),
  );
  container.appendChild(controls);

  progress = el('input', {
    type: 'range',
    class: 'progress',
    min: '0',
    max: '1000',
    value: '0',
  });
  progress.addEventListener('input', () => {
    const audio = audioElement();
    const duration = audio.duration;
    if (progress && Number.isFinite(duration) && duration > 0) {
      audio.currentTime = (Number(progress.value) / 1000) * duration;
    }
  });
  container.appendChild(progress);

  timeNode = el('span', { class: 'muted small player-time', text: '00:00 / 00:00' });
  container.appendChild(timeNode);

  const volume = el('input', {
    type: 'range',
    class: 'volume',
    min: '0',
    max: '100',
    value: String(Math.round(getVolume() * 100)),
  });
  volume.addEventListener('input', () => setVolume(Number(volume.value) / 100));
  container.appendChild(volume);

  bindAudioListeners();
  updatePlayerBar();
}

function bindAudioListeners(): void {
  if (listenersBound) return;
  listenersBound = true;
  const audio = audioElement();
  audio.addEventListener('timeupdate', updatePlayerBar);
  audio.addEventListener('play', updatePlayerBar);
  audio.addEventListener('pause', updatePlayerBar);
  audio.addEventListener('ended', updatePlayerBar);
  audio.addEventListener('loadedmetadata', updatePlayerBar);
}

/** 仅刷新播放条内容。 */
export function updatePlayerBar(): void {
  if (!root) return;
  const song = currentSong();
  const audio = audioElement();
  if (titleNode) titleNode.textContent = song ? song.name : '未在播放';
  if (artistNode) {
    artistNode.textContent = song
      ? artistText(song.artists)
      : '从歌单或搜索结果中选择歌曲';
  }
  if (playButton) {
    const playing = isPlaying();
    const name = playing ? '暂停' : '播放';
    // 播放 / 暂停图标切换，同时保持可访问名称同步
    while (playButton.firstChild) playButton.removeChild(playButton.firstChild);
    playButton.appendChild(icon(playing ? 'pause' : 'play'));
    playButton.setAttribute('aria-label', name);
    playButton.setAttribute('title', name);
  }
  const duration = audio.duration;
  if (progress) {
    if (Number.isFinite(duration) && duration > 0) {
      progress.value = String(Math.round((audio.currentTime / duration) * 1000));
    } else {
      progress.value = '0';
    }
  }
  if (timeNode) {
    if (Number.isFinite(duration) && duration > 0) {
      timeNode.textContent = `${formatDuration(audio.currentTime * 1000)} / ${formatDuration(duration * 1000)}`;
    } else {
      timeNode.textContent = '00:00 / 00:00';
    }
  }
}
