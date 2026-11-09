/** 设置视图：音质、第三方音源、下载目录。 */

import { api } from '../api';
import { clear, el, iconTextButton, toast } from '../dom';
import { errorMessage } from '../player';
import { isIos } from '../platform';
import { refreshSnapshot, state } from '../store';
import { QUALITY_LABELS, SOURCE_LABELS } from '../types';

const QUALITY_OPTIONS = [
  'standard',
  'higher',
  'exhigh',
  'lossless',
  'hires',
  'sky',
];

const SOURCE_OPTIONS = ['pyncmd', 'gdmusic', 'kugou', 'kuwo', 'migu'];

export async function renderSettings(root: HTMLElement): Promise<void> {
  clear(root);
  const snapshot = state.snapshot ?? (await refreshSnapshot());

  const card = el('div', { class: 'card' });
  card.appendChild(el('h3', { text: '播放设置' }));

  const qualityRow = el('div', { class: 'field' });
  qualityRow.appendChild(el('label', { class: 'field-label', text: '音质' }));
  const qualitySelect = el('select', { class: 'input' });
  for (const q of QUALITY_OPTIONS) {
    const option = el('option', { value: q, text: QUALITY_LABELS[q] ?? q });
    if (q === snapshot.quality) option.setAttribute('selected', '');
    qualitySelect.appendChild(option);
  }
  qualitySelect.addEventListener('change', async () => {
    try {
      await api.updateSettings({ quality: qualitySelect.value });
      await refreshSnapshot();
      toast('音质已更新', 'success');
    } catch (error) {
      toast(errorMessage(error), 'error');
    }
  });
  qualityRow.appendChild(qualitySelect);
  card.appendChild(qualityRow);

  const sourceRow = el('div', { class: 'field' });
  sourceRow.appendChild(
    el('label', { class: 'field-label', text: '第三方音源（按顺序回退）' }),
  );
  const sourceBox = el('div', { class: 'checkbox-grid' });
  const checks = new Map<string, HTMLInputElement>();
  for (const key of SOURCE_OPTIONS) {
    const label = el('label', { class: 'checkbox' });
    const check = el('input', { type: 'checkbox' });
    if (snapshot.sources.includes(key)) check.setAttribute('checked', '');
    checks.set(key, check);
    label.appendChild(check);
    label.appendChild(el('span', { text: SOURCE_LABELS[key] ?? key }));
    sourceBox.appendChild(label);
  }
  sourceRow.appendChild(sourceBox);
  card.appendChild(sourceRow);

  card.appendChild(
    iconTextButton('settings', '保存音源设置', async () => {
      const selected = [...checks.entries()]
        .filter(([, check]) => check.checked)
        .map(([key]) => key);
      if (selected.length === 0) {
        toast('请至少启用一个音源', 'error');
        return;
      }
      try {
        await api.updateSettings({ sources: selected });
        await refreshSnapshot();
        toast('音源设置已保存', 'success');
      } catch (error) {
        toast(errorMessage(error), 'error');
      }
    }),
  );
  root.appendChild(card);

  const dirCard = el('div', { class: 'card' });
  dirCard.appendChild(el('h3', { text: '下载目录' }));
  dirCard.appendChild(el('div', { class: 'muted', text: snapshot.downloadDir }));
  if (isIos()) {
    dirCard.appendChild(
      el('div', {
        class: 'muted small',
        text: 'iOS 版下载目录固定为沙盒 Documents，可在系统「文件」App → 我的 iPhone → Alger Music 中访问。',
      }),
    );
  } else {
    dirCard.appendChild(
      iconTextButton('folderDown', '更换目录', async () => {
        try {
          const dir = await api.pickDownloadDir();
          await refreshSnapshot();
          toast(`下载目录已改为 ${dir}`, 'success');
          await renderSettings(root);
        } catch (error) {
          if (errorMessage(error) !== '已取消') toast(errorMessage(error), 'error');
        }
      }),
    );
  }
  root.appendChild(dirCard);

  const infoCard = el('div', { class: 'card' });
  infoCard.appendChild(el('h3', { text: '账号与本地数据' }));
  infoCard.appendChild(
    el('div', {
      class: 'muted small',
      text: snapshot.account
        ? `当前账号：${snapshot.account.nickname}（${snapshot.account.userId}）`
        : '当前未登录。',
    }),
  );
  infoCard.appendChild(
    el('div', {
      class: 'muted small',
      text: `登录信息仅保存在本机：${snapshot.sessionPath}`,
    }),
  );
  root.appendChild(infoCard);
}
