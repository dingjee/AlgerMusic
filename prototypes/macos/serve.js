// Local-only discussion preview; exposes only the prototype and its app icon.
import { fileURLToPath } from 'node:url';
const assets = new Map([
  ['/', new URL('./index.html', import.meta.url)],
  ['/wireframe.css', new URL('./wireframe.css', import.meta.url)],
  ['/wireframe.js', new URL('./wireframe.js', import.meta.url)],
  ['/src-tauri/icons/icon-macos.png', new URL('../../src-tauri/icons/icon-macos.png', import.meta.url)],
]);
const server = Bun.serve({
  hostname: '127.0.0.1', port: 4175,
  fetch(request) {
    const path = new URL(request.url).pathname;
    const asset = assets.get(path);
    if (!asset) return new Response('Not found', { status: 404 });
    const file = Bun.file(fileURLToPath(asset));
    return new Response(file, { headers: { 'Content-Type': file.type, 'Cache-Control': 'no-store' } });
  },
});
console.log(`Alger Music wireframe: ${server.url}`);
