/** 登录视图：内置网页登录 + 手动粘贴 Cookie。 */

import { api, onLoginStatus } from '../api';
import { el, iconTextButton, textarea, toast } from '../dom';
import { errorMessage } from '../player';
import { isIos } from '../platform';
import { refreshSnapshot, setState } from '../store';

export function renderLogin(root: HTMLElement): () => void {
  root.innerHTML = '';
  const card = el('div', { class: 'card login-card' });

  card.appendChild(el('h2', { text: '登录网易云音乐' }));
  card.appendChild(
    el(
      'p',
      { class: 'muted' },
      isIos()
        ? '推荐使用内置网页登录：将打开全屏登录页，完成后自动保存登录状态并校验账号；可随时点右上角「✕ 关闭」退出。'
        : '推荐使用内置网页登录：在弹出的窗口中完成登录，登录成功后会自动保存登录状态并校验账号。',
    ),
  );

  const webRow = el('div', { class: 'row gap' });
  webRow.appendChild(
    iconTextButton('login', '打开网易云网页登录', async () => {
      try {
        await api.openLoginWindow();
        toast('已打开登录窗口，请在窗口中完成登录', 'info');
      } catch (error) {
        toast(`打开登录窗口失败：${errorMessage(error)}`, 'error');
      }
    }),
  );
  card.appendChild(webRow);

  const statusNode = el('div', { class: 'login-status muted', text: '等待登录…' });
  card.appendChild(statusNode);

  card.appendChild(el('hr'));
  card.appendChild(el('h3', { text: '备用：手动粘贴 Cookie' }));
  card.appendChild(
    el(
      'p',
      { class: 'muted small' },
      '若网页登录不可用，可在浏览器登录网易云音乐后复制整站 Cookie（需包含 MUSIC_U）粘贴到下方。',
    ),
  );

  const cookieInput = textarea({
    placeholder: 'MUSIC_U=...; __csrf=...',
    rows: 5,
    spellcheck: 'false',
  });
  card.appendChild(cookieInput);

  const manualRow = el('div', { class: 'row gap' });
  manualRow.appendChild(
    iconTextButton('login', '使用 Cookie 登录', async () => {
      try {
        await api.loginWithCookie(cookieInput.value);
        await refreshSnapshot();
        toast('登录成功', 'success');
        setState({ view: 'playlists' });
      } catch (error) {
        toast(errorMessage(error), 'error');
      }
    }),
  );
  manualRow.appendChild(
    iconTextButton('logout', '退出登录', async () => {
      try {
        await api.logout();
        await refreshSnapshot();
        toast('已退出登录', 'success');
        setState({ view: 'login' });
      } catch (error) {
        toast(errorMessage(error), 'error');
      }
    }),
  );
  card.appendChild(manualRow);

  root.appendChild(card);

  let disposed = false;
  let unlisten: (() => void) | null = null;
  void onLoginStatus((event) => {
    if (disposed) return;
    statusNode.textContent = event.message;
    if (event.status === 'success') {
      void refreshSnapshot().then(() => setState({ view: 'playlists' }));
    }
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
