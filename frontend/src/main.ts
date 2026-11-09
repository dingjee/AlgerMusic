/** 应用入口：布局、路由与事件绑定。 */

import './styles.css';
import './mobile.css';

import { api, onSessionCheck, onSessionExpired } from './api';
import { clear, el, iconButton, iconTextButton, input, toast } from './dom';
import { errorMessage } from './player';
import { configurePlayer } from './player';
import { reportAudioCapabilities } from './player';
import { isIos } from './platform';
import { refreshSnapshot, setState, state, subscribe } from './store';
import { initTheme } from './theme';
import { renderDownloads } from './views/downloads';
import { renderLogin } from './views/login';
import { renderPlayerBar, updatePlayerBar } from './views/playerBar';
import { renderPlaylistDetail, renderPlaylistOverview, renderPlaylistSidebar } from './views/playlists';
import { renderSearch } from './views/search';
import { renderSettings } from './views/settings';

const app = document.getElementById('app');
if (!app) throw new Error('缺少 #app 容器');

app.innerHTML = '';

const layout = el('div', { class: 'layout' });

// ---- 侧边栏 ----
const sidebar = el('aside', { class: 'sidebar' });
const brand = el('div', { class: 'brand' });
brand.appendChild(el('span', { class: 'brand-title', text: 'Alger Music' }));
brand.appendChild(el('span', { class: 'muted small', text: '网易云音乐播放器' }));
sidebar.appendChild(brand);

const nav = el('nav', { class: 'nav' });
const navItems: {
  key: 'playlists' | 'search' | 'downloads' | 'settings';
  label: string;
  icon: 'listMusic' | 'search' | 'folderDown' | 'settings';
}[] = [
  { key: 'playlists', label: '我的歌单', icon: 'listMusic' },
  { key: 'search', label: '搜索', icon: 'search' },
  { key: 'downloads', label: '下载管理', icon: 'folderDown' },
  { key: 'settings', label: '设置', icon: 'settings' },
];
const navButtons = new Map<string, HTMLButtonElement>();
for (const item of navItems) {
  const btn = iconTextButton(item.icon, item.label, () => {
    if (item.key === 'search') {
      setState({ view: 'search' });
    } else {
      setState({ view: item.key });
    }
  });
  navButtons.set(item.key, btn);
  nav.appendChild(btn);
}
sidebar.appendChild(nav);

const playlistHeader = el('div', { class: 'side-header' });
// 网络歌单只读：侧栏只有歌单列表，没有「新建歌单」之类的写入口。
playlistHeader.appendChild(el('span', { class: 'muted small', text: '歌单' }));
sidebar.appendChild(playlistHeader);

const playlistList = el('div', { class: 'playlist-list' });
sidebar.appendChild(playlistList);

const accountBox = el('div', { class: 'account-box' });
sidebar.appendChild(accountBox);

layout.appendChild(sidebar);

// ---- 主区域 ----
const main = el('main', { class: 'main' });

const topbar = el('header', { class: 'topbar' });
const searchInput = input({ placeholder: '搜索歌曲 / 歌手', spellcheck: 'false' });
const searchBtn = iconButton('search', () => {
  const keyword = searchInput.value.trim();
  setState({ view: 'search', keyword });
});
searchInput.addEventListener('keydown', (event) => {
  if ((event as KeyboardEvent).key === 'Enter') {
    setState({ view: 'search', keyword: searchInput.value.trim() });
  }
});
topbar.appendChild(el('div', { class: 'row gap grow' }, searchInput, searchBtn));

const accountArea = el('div', { class: 'row gap' });
topbar.appendChild(accountArea);

main.appendChild(topbar);

const viewRoot = el('div', { class: 'view-root' });
main.appendChild(viewRoot);

layout.appendChild(main);

// ---- 播放条 ----
const playerBar = el('footer', { class: 'player-bar' });
layout.appendChild(playerBar);

app.appendChild(layout);

// 播放条 DOM 只创建一次
renderPlayerBar(playerBar);

// ---- 渲染 ----

let rendering = false;
/** 是否还有待处理的渲染请求。 */
let renderRequested = false;
/** 当前视图的清理函数（用于释放事件订阅）。 */
let viewCleanup: (() => void) | null = null;
/**
 * 渲染代号。
 *
 * 视图渲染是异步的（要拉歌单 / 歌曲详情），如果用户在等待期间切换了视图，
 * 旧视图的结果必须被丢弃，否则会出现「切到设置后又跳回歌单」这类问题。
 */
let renderGeneration = 0;

function renderSidebar(): void {
  for (const [key, btn] of navButtons) {
    btn.classList.toggle('nav-active', state.view === key);
  }
  if (state.snapshot?.loggedIn) {
    void renderPlaylistSidebar(playlistList, (id) => setState({ view: 'playlist', playlistId: id }));
  } else {
    clear(playlistList);
    playlistList.appendChild(el('div', { class: 'muted small', text: '登录后显示歌单' }));
  }

  clear(accountArea);
  const snapshot = state.snapshot;
  // 会话文件载入问题（损坏 / 读失败）：明确提示一次（审查 E1-9）
  notifyLoadIssue(snapshot?.loadIssue);
  if (snapshot?.loggedIn) {
    accountArea.appendChild(
      el('span', {
        class: 'muted small',
        text: snapshot.account ? snapshot.account.nickname : '已登录',
      }),
    );
    accountArea.appendChild(
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
  } else {
    accountArea.appendChild(
      iconTextButton('login', '登录', () => setState({ view: 'login' })),
    );
  }

  clear(accountBox);
  if (snapshot?.account) {
    accountBox.appendChild(
      el('div', { class: 'muted small', text: `账号：${snapshot.account.nickname}` }),
    );
  } else if (snapshot?.hasCookie) {
    accountBox.appendChild(el('div', { class: 'muted small', text: 'Cookie 已保存，尚未校验' }));
  } else {
    accountBox.appendChild(el('div', { class: 'muted small', text: '未登录' }));
  }
}

async function renderView(generation: number): Promise<void> {
  // 释放上一个视图的事件订阅
  viewCleanup?.();
  viewCleanup = null;
  // 先渲染到临时容器：渲染期间若用户切换了视图，旧结果直接丢弃
  const host = document.createElement('div');
  host.className = 'view-inner';
  switch (state.view) {
    case 'login':
      viewCleanup = renderLogin(host);
      break;
    case 'playlist':
      if (state.playlistId !== null) {
        await renderPlaylistDetail(host, state.playlistId);
      } else {
        setState({ view: 'playlists' });
        return;
      }
      break;
    case 'search':
      renderSearch(host, state.keyword);
      break;
    case 'downloads':
      viewCleanup = await renderDownloads(host);
      break;
    case 'settings':
      await renderSettings(host);
      break;
    case 'playlists':
    default: {
      // 正文区概览：窄屏（iPhone）侧栏歌单列表被隐藏，这里仍可选歌单（只读）
      await renderPlaylistOverview(host, (id) => setState({ view: 'playlist', playlistId: id }));
      break;
    }
  }
  // 渲染期间用户切换了视图：丢弃本次结果，避免覆盖新视图
  if (generation !== renderGeneration) {
    viewCleanup?.();
    viewCleanup = null;
    return;
  }
  clear(viewRoot);
  while (host.firstChild) {
    viewRoot.appendChild(host.firstChild);
  }
}

function render(): void {
  renderRequested = true;
  if (rendering) return;
  rendering = true;
  void (async () => {
    try {
      while (renderRequested) {
        renderRequested = false;
        const generation = ++renderGeneration;
        renderSidebar();
        updatePlayerBar();
        await renderView(generation);
      }
    } catch (error) {
      toast(errorMessage(error), 'error');
    } finally {
      rendering = false;
    }
  })();
}

configurePlayer({
  onStateChange: () => updatePlayerBar(),
  onTrackChange: (song) => {
    if (song) {
      void api.lyric(song.id).catch(() => undefined);
    }
  },
});

subscribe(() => render());

// 会话失效（Cookie 过期 / 被顶号）：提示并回到登录页
void onSessionExpired((message) => {
  toast(message, 'error');
  void refreshSnapshot().finally(() => setState({ view: 'login' }));
});

// 会话校验结果（session://check）：
// - saveFailed：登录状态已失效或账号信息写盘失败 —— 必须让用户看到，
//   否则磁盘上的身份与界面显示不一致（审查 E0-2）。
// - unverified：暂时无法校验（网络 / 上游临时故障），已保留本机 Cookie。
void onSessionCheck((event) => {
  if (event.status === 'saveFailed') {
    toast(event.message, 'error');
    void refreshSnapshot().catch(() => undefined);
    return;
  }
  if (event.status === 'unverified') {
    toast(event.message, 'info');
  }
});

// 会话文件载入问题（损坏 / 读失败）：快照里带出来，明确提示一次
// （审查 E1-9）——否则用户只会在后续保存失败时看到症状。
let lastLoadIssue: string | null = null;
function notifyLoadIssue(issue: string | null | undefined): void {
  if (!issue || issue === lastLoadIssue) return;
  lastLoadIssue = issue;
  toast(issue, 'error');
}

async function bootstrap(): Promise<void> {
  // 主题：强调色跟随系统，浅色 / 深色由 CSS 跟随系统
  void initTheme();
  // 平台标记：移动布局与 iOS 专属样式通过根元素 class 生效
  document.body.classList.toggle('is-ios', isIos());
  try {
    const snapshot = await refreshSnapshot();
    document.body.classList.toggle('is-ios', snapshot.platform === 'ios');
    // 上报本机 WebView 实测的音频解码能力（iOS 上用于解析链回退）
    reportAudioCapabilities();
    if (snapshot.loggedIn) {
      setState({ view: 'playlists' });
    } else {
      setState({ view: 'login' });
    }
  } catch (error) {
    toast(`初始化失败：${errorMessage(error)}`, 'error');
    setState({ view: 'login' });
  }
}

void bootstrap();
