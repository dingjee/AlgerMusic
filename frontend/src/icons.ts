/**
 * 图标库（lucide）。
 *
 * 直接使用 lucide 的 `IconNode` 数据渲染内联 SVG：
 * - 不依赖 DOM 扫描，可以随时插入；
 * - SVG 本身 `aria-hidden`，可访问名称由按钮的 `aria-label` / `title` 提供。
 *
 * 图标许可：lucide（ISC License），详见 node_modules/lucide/LICENSE。
 */

import {
  ChevronLeft,
  CircleAlert,
  Disc3,
  Download,
  FolderDown,
  FolderOpen,
  ListMusic,
  ListOrdered,
  Loader,
  LogIn,
  LogOut,
  Music,
  Pause,
  Pencil,
  Play,
  Plus,
  RefreshCw,
  Search,
  Settings,
  SkipBack,
  SkipForward,
  Trash2,
  Volume2,
  X,
  type IconNode,
} from 'lucide';

const SVG_NS = 'http://www.w3.org/2000/svg';

/** 可用的图标名。 */
export const ICONS = {
  back: ChevronLeft,
  alert: CircleAlert,
  disc: Disc3,
  download: Download,
  folderDown: FolderDown,
  folderOpen: FolderOpen,
  listMusic: ListMusic,
  queue: ListOrdered,
  spinner: Loader,
  login: LogIn,
  logout: LogOut,
  music: Music,
  pause: Pause,
  edit: Pencil,
  play: Play,
  plus: Plus,
  reparse: RefreshCw,
  search: Search,
  settings: Settings,
  prev: SkipBack,
  next: SkipForward,
  remove: Trash2,
  volume: Volume2,
  close: X,
} as const satisfies Record<string, IconNode>;

export type IconName = keyof typeof ICONS;

/** 图标名 -> 无障碍名称。 */
const ICON_LABELS: Record<IconName, string> = {
  back: '返回',
  alert: '提示',
  disc: '专辑封面',
  download: '下载',
  folderDown: '下载管理',
  folderOpen: '打开文件夹',
  listMusic: '我的歌单',
  queue: '播放队列',
  spinner: '处理中',
  login: '登录',
  logout: '退出登录',
  music: '音乐',
  pause: '暂停',
  edit: '编辑',
  play: '播放',
  plus: '新建',
  reparse: '重新解析',
  search: '搜索',
  settings: '设置',
  prev: '上一首',
  next: '下一首',
  remove: '移除',
  volume: '音量',
  close: '关闭',
};

/**
 * 创建一个内联 SVG 图标。
 *
 * 图标本身是装饰性的（`aria-hidden`），因此调用方必须提供可访问名称。
 */
export function icon(name: IconName, size = 16): SVGElement {
  const node = ICONS[name];
  const svg = document.createElementNS(SVG_NS, 'svg');
  svg.setAttribute('xmlns', SVG_NS);
  svg.setAttribute('width', String(size));
  svg.setAttribute('height', String(size));
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('fill', 'none');
  svg.setAttribute('stroke', 'currentColor');
  svg.setAttribute('stroke-width', '2');
  svg.setAttribute('stroke-linecap', 'round');
  svg.setAttribute('stroke-linejoin', 'round');
  svg.setAttribute('aria-hidden', 'true');
  svg.setAttribute('focusable', 'false');
  svg.classList.add('icon');
  for (const [tag, attrs] of node) {
    const child = document.createElementNS(SVG_NS, tag);
    for (const [key, value] of Object.entries(attrs)) {
      if (value === undefined || value === null) continue;
      child.setAttribute(key, String(value));
    }
    svg.appendChild(child);
  }
  return svg;
}

/** 图标的可访问名称。 */
export function iconLabel(name: IconName): string {
  return ICON_LABELS[name];
}
