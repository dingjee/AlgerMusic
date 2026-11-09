/**
 * 网络歌单只读验收脚本。
 *
 * 背景：
 * - 网络歌单不再支持增删改：新建 / 改名 / 删除 / 加入 / 移除 / 重排 /
 *   「目标歌单」选择器等写入口全部下线，界面只保留读取、播放、搜索、
 *   下载与登录。
 * - 搜索结果里原先的「加入歌单」改为「加入临时播放队列」（本地队列）。
 *
 * 本脚本分两部分：
 *
 *  1. **源码层断言**（静态检查，防止写入口被改回来）：
 *     - `frontend/src/api.ts` 不再封装任何歌单写接口；
 *     - `frontend/src/views/*` 与 `main.ts` 不再调用歌单写封装；
 *     - `src-tauri/src/lib.rs` 不再注册歌单写命令；
 *     - `src-tauri/src/commands.rs` 不再实现歌单写命令；
 *     - **构建兼容**：移动端命令层不调用网络歌单写 API（与公共
 *       `netease/api.rs` 里这些方法是否还在无关），且跨 crate 仍复用
 *       同一份 netease 实现。
 *
 *  2. **行为层回归**（真实 `frontend/src/views/playlists.ts`、
 *     `frontend/src/views/search.ts`、`frontend/src/dom.ts`，通过 esbuild
 *     打包 + DOM / 接口 / 播放器替身）：
 *     - 歌单列表、概览、详情仍然正常渲染（读取能力没坏）；
 *     - 详情与搜索里 **没有** 任何写入口（按钮 / 多选框 / 目标歌单下拉）；
 *     - 播放 / 下载 / 加入队列这些只读或本地能力仍然可用；
 *     - 全程 **不发起任何写调用**（接口替身会记录并断言）。
 *
 *  另外保留应用内弹层（`dom.ts` 的通用表单 / 确认框）的语义回归：
 *  必填校验、取消、焦点还原、焦点陷阱。
 *
 * 全程离线：不访问真实账号、不发起真实网络请求。
 *
 * 运行方式（仓库根目录）：
 *   node tests/playlist-dialog-acceptance.cjs
 *   或
 *   bun tests/playlist-dialog-acceptance.cjs
 *
 * 依赖：esbuild（frontend/package.json 的 devDependencies）
 */
const fs = require('node:fs');
const path = require('node:path');
const project = path.resolve(__dirname, '..');

function loadEsbuild() {
  const candidates = [
    path.join(project, 'frontend', 'node_modules', 'esbuild'),
    path.join(project, 'node_modules', 'esbuild'),
  ];
  for (const candidate of candidates) {
    try {
      return require(candidate);
    } catch {
      /* 继续尝试下一个位置 */
    }
  }
  return require(require.resolve('esbuild', { paths: [project, path.join(project, 'frontend')] }));
}

const { build } = loadEsbuild();
const vm = require('node:vm');
const assert = require('node:assert/strict');

const domPath = path.join(project, 'frontend', 'src', 'dom.ts');
const playlistsPath = path.join(project, 'frontend', 'src', 'views', 'playlists.ts');
const searchPath = path.join(project, 'frontend', 'src', 'views', 'search.ts');
const apiPath = path.join(project, 'frontend', 'src', 'api.ts');
const storePath = path.join(project, 'frontend', 'src', 'store.ts');
const mainPath = path.join(project, 'frontend', 'src', 'main.ts');
const libRsPath = path.join(project, 'src-tauri', 'src', 'lib.rs');
const commandsRsPath = path.join(project, 'src-tauri', 'src', 'commands.rs');
const coreNeteasePath = path.join(project, 'crates', 'alger-core', 'src', 'netease', 'mod.rs');

/** 网络歌单的写命令（Tauri IPC 名）。 */
const WRITE_COMMANDS = [
  'create_playlist',
  'update_playlist',
  'add_to_playlist',
  'remove_from_playlist',
];

/** 网络歌单的写封装（前端 api 方法名）。 */
const WRITE_METHODS = [
  'createPlaylist',
  'updatePlaylist',
  'addToPlaylist',
  'removeFromPlaylist',
];

/** 界面上不允许出现的写入口文案。 */
const WRITE_LABELS = ['新建歌单', '编辑歌单', '加入歌单', '从歌单移除', '目标歌单'];

/* ------------------------------------------------------------------ *
 * 极简 DOM 替身
 *
 * 只实现前端代码真正用到的那部分：元素树、属性、文本、事件、焦点。
 * ------------------------------------------------------------------ */

let shimDocument = null;

class ShimText {
  constructor(text) {
    this.nodeType = 3;
    this.text = String(text);
    this.parentNode = null;
  }
  get textContent() {
    return this.text;
  }
  set textContent(value) {
    this.text = String(value);
  }
}

class ShimElement {
  constructor(tagName, namespaceURI) {
    this.nodeType = 1;
    this.tagName = String(tagName).toUpperCase();
    this.namespaceURI = namespaceURI || null;
    this.childNodes = [];
    this.parentNode = null;
    this.attributes = new Map();
    this.style = {};
    this.className = '';
    this.checked = false;
    this._value = undefined;
    this._listeners = new Map();

    const self = this;
    this.classList = {
      add(...names) {
        const set = new Set(self.className.split(/\s+/).filter(Boolean));
        for (const name of names) set.add(name);
        self.className = [...set].join(' ');
      },
      remove(...names) {
        const set = new Set(self.className.split(/\s+/).filter(Boolean));
        for (const name of names) set.delete(name);
        self.className = [...set].join(' ');
      },
      toggle(name, force) {
        const has = self.classList.contains(name);
        const next = force === undefined ? !has : !!force;
        if (next) self.classList.add(name);
        else self.classList.remove(name);
        return next;
      },
      contains(name) {
        return self.className.split(/\s+/).includes(name);
      },
    };
  }

  get children() {
    return this.childNodes.filter((node) => node.nodeType === 1);
  }

  get firstChild() {
    return this.childNodes[0] ?? null;
  }

  get parentElement() {
    return this.parentNode && this.parentNode.nodeType === 1 ? this.parentNode : null;
  }

  set textContent(value) {
    this.childNodes = [];
    const text = value === null || value === undefined ? '' : String(value);
    if (text !== '') {
      const node = new ShimText(text);
      node.parentNode = this;
      this.childNodes.push(node);
    }
  }

  get textContent() {
    return this.childNodes.map((node) => node.textContent).join('');
  }

  set innerHTML(value) {
    this.childNodes = [];
    this._innerHTML = String(value);
  }

  get innerHTML() {
    return this._innerHTML ?? this.childNodes.map((node) => node.textContent).join('');
  }

  setAttribute(name, value) {
    this.attributes.set(String(name), String(value));
  }

  getAttribute(name) {
    return this.attributes.has(name) ? this.attributes.get(name) : null;
  }

  hasAttribute(name) {
    return this.attributes.has(name);
  }

  removeAttribute(name) {
    this.attributes.delete(name);
  }

  appendChild(node) {
    if (node.parentNode) node.parentNode.removeChild(node);
    node.parentNode = this;
    this.childNodes.push(node);
    return node;
  }

  removeChild(node) {
    const index = this.childNodes.indexOf(node);
    if (index >= 0) this.childNodes.splice(index, 1);
    node.parentNode = null;
    return node;
  }

  remove() {
    if (this.parentNode) this.parentNode.removeChild(this);
  }

  contains(node) {
    let current = node;
    while (current) {
      if (current === this) return true;
      current = current.parentNode;
    }
    return false;
  }

  addEventListener(type, handler) {
    if (!this._listeners.has(type)) this._listeners.set(type, []);
    this._listeners.get(type).push(handler);
  }

  removeEventListener(type, handler) {
    const list = this._listeners.get(type);
    if (!list) return;
    const index = list.indexOf(handler);
    if (index >= 0) list.splice(index, 1);
  }

  dispatchEvent(event) {
    if (!event.target) event.target = this;
    const list = (this._listeners.get(event.type) || []).slice();
    for (const handler of list) handler.call(this, event);
    return true;
  }

  focus() {
    if (shimDocument) shimDocument.activeElement = this;
  }

  blur() {
    if (shimDocument && shimDocument.activeElement === this) shimDocument.activeElement = null;
  }
}

Object.defineProperty(ShimElement.prototype, 'value', {
  get() {
    if (this._value !== undefined) return this._value;
    if (this.tagName === 'SELECT') {
      // 与浏览器一致：未显式赋值时取第一个选项
      const option = this.childNodes.find(
        (node) => node.nodeType === 1 && node.tagName === 'OPTION',
      );
      if (!option) return '';
      return option.getAttribute('value') ?? option.textContent;
    }
    const attr = this.getAttribute('value');
    return attr === null ? '' : attr;
  },
  set(value) {
    this._value = String(value);
  },
});

function walk(node, visit) {
  if (!node || node.nodeType !== 1) return;
  visit(node);
  for (const child of node.childNodes) walk(child, visit);
}

function findAll(root, predicate) {
  const out = [];
  walk(root, (node) => {
    if (predicate(node)) out.push(node);
  });
  return out;
}

function findButtonByText(root, text) {
  return (
    findAll(root, (node) => node.tagName === 'BUTTON' && node.textContent.includes(text))[0] || null
  );
}

function findButtonByAriaLabel(root, matcher) {
  return (
    findAll(root, (node) => {
      if (node.tagName !== 'BUTTON') return false;
      const label = node.getAttribute('aria-label') || '';
      return typeof matcher === 'string' ? label === matcher : matcher.test(label);
    })[0] || null
  );
}

function makeEvent(type, target, extra = {}) {
  return {
    type,
    target: target ?? null,
    currentTarget: target ?? null,
    key: extra.key,
    shiftKey: !!extra.shiftKey,
    defaultPrevented: false,
    preventDefault() {
      this.defaultPrevented = true;
    },
    stopPropagation() {},
  };
}

function createDom() {
  const doc = {
    activeElement: null,
    listeners: new Map(),
    body: null,
    createElement(tag) {
      return new ShimElement(tag);
    },
    createElementNS(namespace, tag) {
      return new ShimElement(tag, namespace);
    },
    getElementById(id) {
      let found = null;
      walk(doc.body, (node) => {
        if (!found && node.getAttribute('id') === id) found = node;
      });
      return found;
    },
    addEventListener(type, handler) {
      if (!doc.listeners.has(type)) doc.listeners.set(type, []);
      doc.listeners.get(type).push(handler);
    },
    removeEventListener(type, handler) {
      const list = doc.listeners.get(type);
      if (!list) return;
      const index = list.indexOf(handler);
      if (index >= 0) list.splice(index, 1);
    },
    dispatchEvent(event) {
      event.target = event.target ?? doc.body;
      const list = (this ? doc.listeners.get(event.type) || [] : []).slice();
      for (const handler of list) handler.call(doc, event);
      return true;
    },
  };
  doc.body = new ShimElement('body');
  shimDocument = doc;
  return doc;
}

/* ------------------------------------------------------------------ *
 * 替身：接口 / 播放器
 * ------------------------------------------------------------------ */

function song(id, name) {
  return {
    id,
    name: name ?? `歌曲${id}`,
    artists: [{ id: 1, name: '测试歌手' }],
    album: { id: 0, name: '测试专辑', picUrl: '' },
    durationMs: 1000,
    fee: 0,
    copyright: 0,
  };
}

/**
 * 接口替身。
 *
 * 用 Proxy 兜住 **所有** 方法调用：只读方法正常返回，写方法（以及任何
 * 未声明的方法）会被记录下来，测试据此断言「没有发起写调用」。
 */
function createApiStub() {
  const calls = [];
  const record = (method, args) => {
    calls.push({ method, args });
  };
  const songs = [song(101, '歌曲一'), song(102, '歌曲二')];
  const playlist = {
    id: 7,
    name: '测试歌单',
    description: null,
    coverImgUrl: '',
    trackCount: songs.length,
    creator: { userId: 1, nickname: '测试用户', avatarUrl: '' },
    trackIds: songs.map((item) => item.id),
    subscribed: false,
  };
  const second = {
    ...playlist,
    id: 8,
    name: '另一个歌单',
    trackCount: 0,
    trackIds: [],
  };
  // 订阅来的歌单：仍然要能在列表里看到（只读浏览）
  const subscribed = {
    ...playlist,
    id: 9,
    name: '订阅的歌单',
    subscribed: true,
  };
  const impl = {
    userPlaylists: async () => [playlist, second, subscribed],
    playlistDetail: async () => ({ playlist, songs, missing: 0 }),
    searchSongs: async (keywords) => {
      record('searchSongs', [keywords]);
      return [songs, songs.length];
    },
    downloadSong: async (item) => {
      record('downloadSong', [item.id]);
      return '/tmp/song.mp3';
    },
    snapshot: async () => ({
      loggedIn: true,
      hasCookie: true,
      account: { userId: 1, nickname: '测试用户', vipType: 0 },
      quality: 'standard',
      sources: ['pyncmd'],
      downloadDir: '/tmp',
      sessionPath: '',
      accountVerified: true,
      platform: 'ios',
      loadIssue: null,
    }),
    setUnsupportedAudioFormats: async () => {},
    lyric: async () => ({}),
  };
  const api = new Proxy(impl, {
    get(target, prop) {
      if (typeof prop === 'symbol') return Reflect.get(target, prop);
      if (prop === 'then' || prop === 'toJSON' || prop === 'constructor') {
        return Reflect.get(target, prop);
      }
      if (prop in target) {
        const value = target[prop];
        return typeof value === 'function' ? value.bind(target) : value;
      }
      // 未声明的方法：视为违规调用（例如写接口被改回来）——只记录，不抛错，
      // 这样断言能给出「发起了写调用」的明确信息。
      return (...args) => {
        record(String(prop), args);
        return undefined;
      };
    },
  });
  return { api, calls, songs, playlist, playlists: [playlist, second, subscribed] };
}

/** 播放器替身：只记录队列动作，不真的播放。 */
function createPlayerStub() {
  const calls = [];
  return {
    calls,
    enqueue: (songs) => calls.push({ method: 'enqueue', args: [songs] }),
    setQueue: (songs, index) => calls.push({ method: 'setQueue', args: [songs, index] }),
  };
}

function createContext(doc) {
  const timers = [];
  const context = {
    module: { exports: {} },
    exports: {},
    console,
    document: doc,
    window: {
      setTimeout: (fn) => (timers.push(fn), timers.length),
      clearTimeout: () => {},
      innerWidth: 390,
      innerHeight: 844,
    },
    setTimeout: (fn) => (timers.push(fn), timers.length),
    clearTimeout: () => {},
  };
  return context;
}

/** 跨 realm 的值用 JSON 归一化后再比较（vm 里的原型与宿主不同）。 */
function plain(value) {
  return JSON.parse(JSON.stringify(value === undefined ? null : value));
}

const flush = async (rounds = 3) => {
  for (let i = 0; i < rounds; i++) {
    await new Promise((resolve) => setImmediate(resolve));
  }
};

/* ------------------------------------------------------------------ *
 * 打包：真实视图 + 真实 dom.ts（接口与播放器被替身接管）
 * ------------------------------------------------------------------ */

async function bundleApp() {
  const apiStub = 'export const api = globalThis.testApi;';
  const playerStub = [
    'export function enqueue(songs) { globalThis.testPlayer.enqueue(songs); }',
    'export function setQueue(songs, index) { globalThis.testPlayer.setQueue(songs, index); }',
    'export function errorMessage(error) {',
    "  if (error && typeof error === 'object' && 'message' in error) return String(error.message);",
    '  return String(error);',
    '}',
  ].join('\n');

  const result = await build({
    stdin: {
      contents: [
        `export { renderPlaylistSidebar, renderPlaylistOverview, renderPlaylistDetail } from ${JSON.stringify(playlistsPath)};`,
        `export { renderSearch } from ${JSON.stringify(searchPath)};`,
        `export { state, setState } from ${JSON.stringify(storePath)};`,
        `export { requestFields, confirmAction } from ${JSON.stringify(domPath)};`,
      ].join('\n'),
      resolveDir: project,
      loader: 'ts',
    },
    bundle: true,
    platform: 'node',
    format: 'cjs',
    write: false,
    plugins: [
      {
        name: 'acceptance-stubs',
        setup(b) {
          b.onResolve({ filter: /^\.\.\/api$/ }, () => ({ path: 'api', namespace: 'test' }));
          b.onResolve({ filter: /^\.\.\/player$/ }, () => ({ path: 'player', namespace: 'test' }));
          b.onLoad({ filter: /.*/, namespace: 'test' }, (a) => ({
            contents: a.path === 'api' ? apiStub : playerStub,
            loader: 'js',
            resolveDir: project,
          }));
        },
      },
    ],
  });
  return result.outputFiles[0].text;
}

/** 造一套隔离环境：DOM + 接口 + 播放器替身。 */
function fixture(code) {
  const doc = createDom();
  const stub = createApiStub();
  const player = createPlayerStub();
  const context = createContext(doc);
  context.testApi = stub.api;
  context.testPlayer = player;
  vm.runInNewContext(code, context);
  return { doc, api: stub, player, mod: context.module.exports };
}

/** 断言：整个流程没有发起任何网络歌单写调用。 */
function assertNoWriteCalls(api, allowed = []) {
  const writes = api.calls.filter((call) => WRITE_METHODS.includes(call.method));
  assert.deepEqual(
    writes.map((call) => call.method),
    [],
    '发起了网络歌单写调用',
  );
  const unexpected = api.calls
    .map((call) => call.method)
    .filter((method) => !allowed.includes(method));
  assert.deepEqual(unexpected, [], '调用了不该出现的接口');
}

/** 断言：界面上没有网络歌单写入口。 */
function assertNoWriteUi(root) {
  for (const label of WRITE_LABELS) {
    const button = findButtonByText(root, label);
    assert.equal(button, null, `界面上仍有「${label}」写入口`);
  }
  const checkboxes = findAll(root, (node) => node.getAttribute('type') === 'checkbox');
  assert.equal(checkboxes.length, 0, '歌单里还有多选框（批量写操作的入口）');
  const selects = findAll(root, (node) => node.tagName === 'SELECT');
  assert.equal(selects.length, 0, '还有目标歌单下拉选择器');
}

/* ------------------------------------------------------------------ *
 * 场景
 * ------------------------------------------------------------------ */

async function main() {
  const code = await bundleApp();
  const cases = [];

  /* --- 源码层：写入口不再存在 --- */

  cases.push([
    'api.ts: 不再封装任何网络歌单写接口',
    async () => {
      const content = fs.readFileSync(apiPath, 'utf8');
      for (const command of WRITE_COMMANDS) {
        assert.ok(!content.includes(command), `api.ts 仍有写接口 ${command}`);
      }
    },
  ]);

  cases.push([
    'views / main.ts: 不再调用网络歌单写封装',
    async () => {
      const files = [playlistsPath, searchPath, mainPath];
      for (const file of files) {
        const content = fs.readFileSync(file, 'utf8');
        for (const method of WRITE_METHODS) {
          assert.ok(!content.includes(method), `${path.basename(file)} 仍调用 ${method}`);
        }
        assert.ok(!content.includes('playlistTarget'), `${path.basename(file)} 仍有目标歌单选择器`);
      }
    },
  ]);

  cases.push([
    'src-tauri: 不再注册 / 实现网络歌单写命令',
    async () => {
      const lib = fs.readFileSync(libRsPath, 'utf8');
      const commands = fs.readFileSync(commandsRsPath, 'utf8');
      for (const command of WRITE_COMMANDS) {
        assert.ok(!lib.includes(`commands::${command}`), `lib.rs 仍注册 ${command}`);
        assert.ok(
          !commands.includes(`pub async fn ${command}`),
          `commands.rs 仍实现 ${command}`,
        );
      }
    },
  ]);

  cases.push([
    '构建兼容：命令层不调用网络歌单写 API，跨 crate 仍复用同一实现',
    async () => {
      const commands = fs.readFileSync(commandsRsPath, 'utf8');
      const core = fs.readFileSync(coreNeteasePath, 'utf8');
      // 移动端命令层不得调用网络歌单写 API —— 与这些方法是否还在公共
      // api.rs 里无关：方法删掉后这里同样不能引用，方法加回来也不该引用。
      for (const method of [
        'create_playlist',
        'update_playlist_name',
        'update_playlist_desc',
        'add_tracks',
        'remove_tracks',
      ]) {
        assert.ok(
          !commands.includes(`.${method}(`),
          `commands.rs 仍调用网络写 API ${method}`,
        );
      }
      // 跨 crate 仍复用同一份 netease 实现，避免两份实现漂移
      assert.ok(
        core.includes('src-tauri/src/netease/api.rs'),
        'alger-core 不再复用 src-tauri/src/netease/api.rs',
      );
    },
  ]);

  /* --- 行为层：歌单仍然可读 --- */

  cases.push([
    '侧栏歌单列表：正常渲染歌单名与曲目数',
    async () => {
      const f = fixture(code);
      const container = f.doc.createElement('div');
      await f.mod.renderPlaylistSidebar(container, () => {});
      const text = container.textContent;
      assert.ok(text.includes('测试歌单'), '没有渲染出歌单名');
      assert.ok(text.includes('另一个歌单'), '没有渲染出第二个歌单');
      assert.ok(text.includes('订阅的歌单'), '订阅的歌单也应可见（只读浏览）');
      assert.equal(findAll(container, (n) => n.tagName === 'BUTTON').length, 3);
      assertNoWriteUi(container);
      assertNoWriteCalls(f.api, ['userPlaylists']);
    },
  ]);

  cases.push([
    '我的歌单概览：列出歌单并说明只读，没有新建入口',
    async () => {
      const f = fixture(code);
      f.mod.setState({
        snapshot: {
          loggedIn: true,
          hasCookie: true,
          account: { userId: 1, nickname: '测试用户', vipType: 0 },
          quality: 'standard',
          sources: ['pyncmd'],
          downloadDir: '/tmp',
          sessionPath: '',
          accountVerified: true,
          platform: 'ios',
          loadIssue: null,
        },
      });
      const root = f.doc.createElement('div');
      await f.mod.renderPlaylistOverview(root, () => {});
      assert.ok(root.textContent.includes('测试歌单'), '概览没有列出歌单');
      assert.ok(root.textContent.includes('只读'), '概览没有说明只读');
      assertNoWriteUi(root);
      assertNoWriteCalls(f.api, ['userPlaylists']);
    },
  ]);

  cases.push([
    '歌单详情：渲染曲目与只读操作，没有任何写入口',
    async () => {
      const f = fixture(code);
      const root = f.doc.createElement('div');
      await f.mod.renderPlaylistDetail(root, 7);
      // 先断言没有写调用：即使写入口换了文案也拦得住
      assertNoWriteCalls(f.api, ['playlistDetail']);
      assertNoWriteUi(root);
      assert.ok(root.textContent.includes('歌曲一'), '没有渲染出曲目');
      assert.ok(root.textContent.includes('测试歌单'), '没有渲染出歌单名');
      assert.ok(findButtonByText(root, '播放全部'), '没有「播放全部」');
      assert.ok(findButtonByAriaLabel(root, /^播放 歌曲一$/), '没有单曲播放按钮');
      assert.ok(findButtonByAriaLabel(root, /^下载 歌曲一$/), '没有下载按钮');
      assert.ok(findButtonByAriaLabel(root, /^加入队列 歌曲一$/), '没有加入队列按钮');
      assertNoWriteUi(root);
      assertNoWriteCalls(f.api, ['playlistDetail']);
    },
  ]);

  cases.push([
    '歌单详情：播放全部 / 加入队列 走本地队列，不发写调用',
    async () => {
      const f = fixture(code);
      const root = f.doc.createElement('div');
      await f.mod.renderPlaylistDetail(root, 7);
      // 把详情里的按钮点一遍：任何写入口都会在这里被记录下来
      const buttons = findAll(root, (n) => n.tagName === 'BUTTON');
      assert.ok(buttons.length >= 4, '歌单详情缺少操作按钮');
      for (const button of buttons) {
        button.dispatchEvent(makeEvent('click', button));
      }
      await flush();
      assertNoWriteCalls(f.api, ['playlistDetail', 'downloadSong']);
      const setQueue = f.player.calls.find((call) => call.method === 'setQueue');
      assert.ok(setQueue, '「播放全部」没有设置播放队列');
      assert.equal(setQueue.args[1], 0);
      assert.ok(
        f.player.calls.some((call) => call.method === 'enqueue'),
        '没有加入队列的动作',
      );
    },
  ]);

  cases.push([
    '搜索结果：只读操作（播放 / 下载 / 加入队列）可用，且不发起写调用',
    async () => {
      const f = fixture(code);
      const root = f.doc.createElement('div');
      f.mod.renderSearch(root, '测试');
      await flush();
      // 先断言没有写调用：即使写入口换了文案也拦得住
      assertNoWriteCalls(f.api, ['searchSongs']);
      assertNoWriteUi(root);
      assert.ok(root.textContent.includes('歌曲一'), '没有渲染出搜索结果');

      const rows = findAll(root, (n) => n.classList.contains('song-row'));
      assert.ok(rows.length >= 1, '没有渲染出搜索结果行');
      const buttons = findAll(rows[0], (n) => n.tagName === 'BUTTON');
      assert.ok(buttons.length >= 3, '搜索结果行缺少操作按钮');
      // 把这一行的操作按钮点一遍：任何写入口都会在这里被记录下来
      for (const button of buttons) {
        button.dispatchEvent(makeEvent('click', button));
      }
      await flush();
      assertNoWriteCalls(f.api, ['searchSongs', 'downloadSong']);
      assert.ok(
        f.player.calls.some((call) => call.method === 'enqueue'),
        '没有加入队列的动作',
      );
      assert.ok(
        f.api.calls.some((call) => call.method === 'downloadSong'),
        '下载没有调用下载接口',
      );
    },
  ]);

  cases.push([
    '搜索结果：下载仍然可用（本地写盘，不改云端歌单）',
    async () => {
      const f = fixture(code);
      const root = f.doc.createElement('div');
      f.mod.renderSearch(root, '测试');
      await flush();
      const download = findButtonByAriaLabel(root, /^下载 歌曲一$/);
      assert.ok(download, '没有下载按钮');
      download.dispatchEvent(makeEvent('click', download));
      await flush();
      assert.ok(
        f.api.calls.some((call) => call.method === 'downloadSong'),
        '下载没有调用下载接口',
      );
      assertNoWriteCalls(f.api, ['searchSongs', 'downloadSong']);
    },
  ]);

  /* --- 应用内弹层语义（dom.ts 保留的通用控件） --- */

  cases.push([
    'real requestFields: 必填校验拦下空提交，提交后返回字段值',
    async () => {
      const f = fixture(code);
      const promise = f.mod.requestFields('新建歌单', [
        { name: 'name', label: '歌单名称', required: true },
        { name: 'description', label: '歌单描述', type: 'textarea' },
      ]);
      await flush();
      const modal = findAll(f.doc.body, (n) => n.getAttribute('role') === 'dialog')[0];
      assert.ok(modal, '弹层没有渲染出来');
      const inputs = findAll(modal, (n) => n.tagName === 'INPUT' || n.tagName === 'TEXTAREA');
      assert.equal(inputs.length, 2);
      // 焦点落在第一个输入框
      assert.equal(f.doc.activeElement, inputs[0]);
      const buttons = findAll(modal, (n) => n.tagName === 'BUTTON');
      const confirm = buttons[0];
      // 空值提交 → 校验失败，Promise 不结算
      confirm.dispatchEvent(makeEvent('click', confirm));
      await flush();
      const error = findAll(modal, (n) => n.classList.contains('modal-error'))[0];
      assert.ok(error, '没有找到错误提示元素');
      assert.equal(error.textContent, '请填写歌单名称');
      // 填写后提交 → 返回字段值表
      inputs[0].value = '深夜循环';
      inputs[1].value = '  描述  ';
      confirm.dispatchEvent(makeEvent('click', confirm));
      const values = await promise;
      assert.deepEqual(plain(values), { name: '深夜循环', description: '描述' });
      // 弹层已从 DOM 移除
      assert.equal(findAll(f.doc.body, (n) => n.getAttribute('role') === 'dialog').length, 0);
    },
  ]);

  cases.push([
    'real requestFields: Esc / 取消按钮都结算为 null，且只结算一次',
    async () => {
      const f = fixture(code);
      const promise = f.mod.requestFields('新建歌单', [{ name: 'name', label: '歌单名称' }]);
      await flush();
      f.doc.dispatchEvent(makeEvent('keydown', f.doc.body, { key: 'Escape' }));
      assert.equal(await promise, null);
      assert.equal(findAll(f.doc.body, (n) => n.getAttribute('role') === 'dialog').length, 0);

      const second = f.mod.requestFields('新建歌单', [{ name: 'name', label: '歌单名称' }]);
      await flush();
      const modal = findAll(f.doc.body, (n) => n.getAttribute('role') === 'dialog')[0];
      const cancel = findAll(modal, (n) => n.tagName === 'BUTTON')[1];
      cancel.dispatchEvent(makeEvent('click', cancel));
      assert.equal(await second, null);
    },
  ]);

  cases.push([
    'real requestFields: 焦点在关闭后还原到打开前的元素，Tab 被限制在弹层内',
    async () => {
      const f = fixture(code);
      const opener = f.doc.createElement('button');
      f.doc.body.appendChild(opener);
      opener.focus();
      assert.equal(f.doc.activeElement, opener);

      const promise = f.mod.requestFields('新建歌单', [
        { name: 'name', label: '歌单名称' },
        { name: 'description', label: '歌单描述' },
      ]);
      await flush();
      const modal = findAll(f.doc.body, (n) => n.getAttribute('role') === 'dialog')[0];
      const controls = findAll(modal, (n) => n.tagName === 'INPUT' || n.tagName === 'TEXTAREA');
      const buttons = findAll(modal, (n) => n.tagName === 'BUTTON');
      // 最后一个可聚焦元素按 Tab 应回到第一个（焦点陷阱）
      buttons[buttons.length - 1].focus();
      f.doc.dispatchEvent(makeEvent('keydown', f.doc.body, { key: 'Tab' }));
      assert.equal(f.doc.activeElement, controls[0]);
      // Shift+Tab 从第一个回到最后一个
      f.doc.dispatchEvent(makeEvent('keydown', f.doc.body, { key: 'Tab', shiftKey: true }));
      assert.equal(f.doc.activeElement, buttons[buttons.length - 1]);

      buttons[0].dispatchEvent(makeEvent('click', buttons[0]));
      await promise;
      // 焦点还原
      assert.equal(f.doc.activeElement, opener);
    },
  ]);

  cases.push([
    'real requestFields: select 字段返回选中项的值',
    async () => {
      const f = fixture(code);
      const promise = f.mod.requestFields('选择', [
        {
          name: 'playlistId',
          label: '目标歌单',
          type: 'select',
          required: true,
          options: [
            { value: '7', label: '测试歌单' },
            { value: '8', label: '另一个歌单' },
          ],
        },
      ]);
      await flush();
      const modal = findAll(f.doc.body, (n) => n.getAttribute('role') === 'dialog')[0];
      assert.ok(modal);
      const select = findAll(modal, (n) => n.tagName === 'SELECT')[0];
      assert.ok(select, '没有渲染下拉框');
      // 默认选中第一个选项
      assert.equal(select.value, '7');
      select.value = '8';
      const confirm = findAll(modal, (n) => n.tagName === 'BUTTON')[0];
      confirm.dispatchEvent(makeEvent('click', confirm));
      const values = await promise;
      assert.deepEqual(plain(values), { playlistId: '8' });
    },
  ]);

  cases.push([
    'real confirmAction: 确定 → true，取消 / Esc → false',
    async () => {
      const f = fixture(code);
      const promise = f.mod.confirmAction('确认移除？');
      await flush();
      const modal = findAll(f.doc.body, (n) => n.getAttribute('role') === 'dialog')[0];
      assert.ok(modal);
      const buttons = findAll(modal, (n) => n.tagName === 'BUTTON');
      buttons[0].dispatchEvent(makeEvent('click', buttons[0]));
      assert.equal(await promise, true);

      const second = f.mod.confirmAction('确认移除？');
      await flush();
      const modal2 = findAll(f.doc.body, (n) => n.getAttribute('role') === 'dialog')[0];
      findAll(modal2, (n) => n.tagName === 'BUTTON')[1].dispatchEvent(
        makeEvent('click', findAll(modal2, (n) => n.tagName === 'BUTTON')[1]),
      );
      assert.equal(await second, false);

      const third = f.mod.confirmAction('确认移除？');
      await flush();
      f.doc.dispatchEvent(makeEvent('keydown', f.doc.body, { key: 'Escape' }));
      assert.equal(await third, false);
    },
  ]);

  let failed = 0;
  for (const [name, test] of cases) {
    try {
      await test();
      console.log(`PASS ${name}`);
    } catch (e) {
      failed++;
      console.log(`FAIL ${name}: ${e && e.message ? e.message : e}`);
      if (process.env.PLAYLIST_DIALOG_DEBUG) console.log(e);
    }
  }
  if (failed > 0) {
    console.error(`${failed} 个场景未通过`);
    process.exitCode = 1;
  } else {
    console.log(`全部 ${cases.length} 个场景通过`);
  }
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
