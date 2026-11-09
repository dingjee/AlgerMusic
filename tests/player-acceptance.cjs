/**
 * 播放核心并发场景验收脚本。
 *
 * 用真实的 `frontend/src/player.ts`（通过 esbuild 打包）+ 音频 / 接口替身，
 * 验证以下场景：
 *
 *  1. 旧解析结果不能覆盖更新的曲目（切歌后旧请求返回不应起播）；
 *  2. 清空队列会取消待处理的播放（不应再起播）；
 *  3. 解析新歌时的播放/暂停不会恢复上一首；
 *  4. 旧请求失败触发的自动跳歌定时器不能推进用户后来选择的队列。
 *
 * 运行方式（仓库根目录）：
 *   node tests/player-acceptance.cjs
 *   或
 *   bun tests/player-acceptance.cjs
 *
 * 依赖：esbuild（frontend/package.json 的 devDependencies，工作区安装后位于
 * frontend/node_modules 或根 node_modules）
 */
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
  // 最后交给 Node 的标准解析（依赖已提升到根 node_modules 时可用）
  return require(require.resolve('esbuild', { paths: [project, path.join(project, 'frontend')] }));
}

const { build } = loadEsbuild();
const vm = require('node:vm');
const assert = require('node:assert/strict');

async function main() {
  const result = await build({
    stdin: {
      contents: `export * from '${project}/frontend/src/player.ts';`,
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
          b.onResolve({ filter: /^\.\/api$/ }, () => ({ path: 'api', namespace: 'test' }));
          b.onResolve({ filter: /^\.\/dom$/ }, () => ({ path: 'dom', namespace: 'test' }));
          b.onLoad({ filter: /.*/, namespace: 'test' }, (a) => ({
            contents:
              a.path === 'api'
                ? 'export const api = globalThis.testApi;'
                : 'export function toast() {}',
            loader: 'js',
          }));
        },
      },
    ],
  });

  function fixture() {
    const requests = [];
    const timers = [];
    class AudioStub {
      constructor() {
        this.src = '';
        this.paused = true;
        this.ended = false;
        this.currentTime = 0;
        this.volume = 1;
        this.plays = [];
      }
      pause() {
        this.paused = true;
      }
      play() {
        this.paused = false;
        this.plays.push(this.src);
        return Promise.resolve();
      }
      addEventListener() {}
      removeAttribute(name) {
        if (name === 'src') this.src = '';
      }
      load() {}
    }
    const context = {
      module: { exports: {} },
      exports: {},
      Audio: AudioStub,
      window: {
        setTimeout: (fn) => (timers.push(fn), timers.length),
        clearTimeout: () => {},
      },
      setTimeout: (fn) => (timers.push(fn), timers.length),
      clearTimeout: () => {},
      testApi: {
        resolvePlayable: (song) =>
          new Promise((resolve, reject) => requests.push({ song, resolve, reject })),
        // 能力上报替身：player 首次解析前会 await 一次
        setUnsupportedAudioFormats: () => Promise.resolve(),
      },
      console,
    };
    vm.runInNewContext(result.outputFiles[0].text, context);
    return { p: context.module.exports, requests, timers };
  }

  const song = (id) => ({
    id,
    name: String(id),
    artists: [],
    album: { id: 0, name: '', picUrl: '' },
    durationMs: 1000,
    fee: 0,
    copyright: 0,
  });
  const audio = (id) => ({
    url: `https://audio.test/${id}.mp3`,
    br: 128000,
    size: 1000,
    sourceLabel: 'test',
    note: null,
  });
  const flush = async () => {
    for (let i = 0; i < 6; i++) await Promise.resolve();
  };

  const cases = [
    [
      'stale resolve cannot replace newer track',
      async () => {
        const f = fixture();
        f.p.setQueue([song(1)]);
        // 能力上报为一次微任务等待：flush 后旧歌的解析请求才发出
        await flush();
        f.p.setQueue([song(2)]);
        await flush();
        f.requests[1].resolve(audio(2));
        await flush();
        // 迟到的旧结果此时才返回：解析已作废，不得起播
        f.requests[0].resolve(audio(1));
        await flush();
        assert.equal(f.p.audioElement().src, audio(2).url);
        assert.deepEqual(Array.from(f.p.audioElement().plays), [audio(2).url]);
      },
    ],
    [
      'empty queue cancels pending playback',
      async () => {
        const f = fixture();
        f.p.setQueue([song(1)]);
        await flush();
        f.p.setQueue([]);
        f.requests[0].resolve(audio(1));
        await flush();
        assert.equal(f.p.audioElement().paused, true);
        assert.equal(f.p.audioElement().plays.length, 0);
      },
    ],
    [
      'toggle during resolve does not resume previous track',
      async () => {
        const f = fixture();
        f.p.setQueue([song(1)]);
        await flush();
        f.requests[0].resolve(audio(1));
        await flush();
        f.p.setQueue([song(2)]);
        f.p.togglePlay();
        await flush();
        assert.equal(f.p.audioElement().plays.filter((x) => x === audio(1).url).length, 1);
      },
    ],
    [
      'old error timer cannot advance replacement queue',
      async () => {
        const f = fixture();
        f.p.setQueue([song(1), song(2)]);
        await flush();
        f.requests[0].reject('expected failure');
        await flush();
        f.p.setQueue([song(3), song(4)]);
        await flush();
        f.requests[1].resolve(audio(3));
        await flush();
        for (const timer of f.timers) timer();
        await flush();
        assert.equal(f.p.currentSong().id, 3);
      },
    ],
  ];

  let failed = 0;
  for (const [name, test] of cases) {
    try {
      await test();
      console.log(`PASS ${name}`);
    } catch (e) {
      failed++;
      console.log(`FAIL ${name}: ${e.message}`);
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
