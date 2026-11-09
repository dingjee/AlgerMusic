/** 下载列表视图。 */

import { api, onDownloadProgress } from '../api';
import { clear, el, iconButton, iconTextButton, toast } from '../dom';
import { formatSize } from '../format';
import { errorMessage } from '../player';
import { isIos } from '../platform';
import type { DownloadItem } from '../types';

export async function renderDownloads(root: HTMLElement): Promise<() => void> {
  clear(root);
  const head = el('div', { class: 'card row gap' });
  head.appendChild(el('h3', { text: '下载管理' }));
  if (isIos()) {
    head.appendChild(
      el('span', {
        class: 'muted small',
        text: '文件保存在「文件」App → 我的 iPhone → Alger Music',
      }),
    );
  } else {
    head.appendChild(
      iconTextButton('folderOpen', '打开下载目录', async () => {
        try {
          await api.openDownloadFolder();
        } catch (error) {
          toast(errorMessage(error), 'error');
        }
      }),
    );
  }
  root.appendChild(head);

  const list = el('div', { class: 'card song-list' });
  root.appendChild(list);

  const items = await api.listDownloads();
  if (items.length === 0) {
    list.appendChild(el('div', { class: 'muted pad', text: '暂无下载任务' }));
  } else {
    for (const item of items) list.appendChild(renderRow(item));
  }

  let disposed = false;
  let unlisten: (() => void) | null = null;
  await onDownloadProgress((item) => {
    if (disposed) return;
    const existing = list.querySelector(`[data-download-id="${item.id}"]`);
    if (existing) existing.replaceWith(renderRow(item));
    else list.prepend(renderRow(item));
  }).then((fn) => {
    if (disposed) {
      fn();
      return;
    }
    unlisten = fn;
  });

  // 视图切换时释放事件订阅
  return () => {
    disposed = true;
    unlisten?.();
    unlisten = null;
  };
}

function renderRow(item: DownloadItem): HTMLElement {
  const row = el('div', { class: 'song-row song-row--download', 'data-download-id': String(item.id) });
  const info = el('div', { class: 'song-info' });
  info.appendChild(el('div', { class: 'song-name', text: item.name }));
  const statusText =
    item.status === 'done'
      ? `已完成 · ${formatSize(item.total || item.downloaded)}`
      : item.status === 'failed'
        ? `失败：${item.error ?? '未知错误'}`
        : item.status === 'running'
          ? `下载中 ${formatSize(item.downloaded)} / ${formatSize(item.total)}`
          : '等待中';
  info.appendChild(el('div', { class: 'muted small', text: statusText }));
  row.appendChild(info);
  if (item.source) {
    row.appendChild(el('span', { class: 'muted small dl-source', text: item.source }));
  }
  if (item.status === 'done' && !isIos()) {
    row.appendChild(
      iconButton(
        'folderOpen',
        async () => {
          try {
            await api.revealFile(item.path);
          } catch (error) {
            toast(errorMessage(error), 'error');
          }
        },
        { 'aria-label': `在访达中显示 ${item.name}` },
      ),
    );
  }
  row.appendChild(el('span', { class: 'muted small song-path', text: item.path }));
  return row;
}
