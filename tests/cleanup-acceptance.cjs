// Verify destructive cleanup boundaries in a disposable checkout and HOME.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const fixture = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'alger-cleanup-check.')));
const root = path.join(fixture, 'checkout with spaces');
const home = path.join(fixture, 'home');
const tmp = path.join(fixture, 'tmp');
const registrationLog = path.join(fixture, 'unregistered-apps');
const lsregister = path.join(fixture, 'lsregister');
const put = (file, value = 'keep') => {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, value);
};
try {
  put(path.join(fixture, '.alger-project'), fs.realpathSync(path.join(__dirname, '..')));
  put(path.join(fixture, '.alger-owner-pid'), String(process.pid));
  fs.mkdirSync(tmp, { recursive: true });
  put(path.join(root, 'scripts/clean.sh'), fs.readFileSync(path.join(__dirname, '../scripts/clean.sh')));
  put(lsregister, '#!/bin/sh\n[ "$1" = -u ] && [ -d "$2" ] || exit 1\nprintf "%s\\n" "$2" >> "$ALGER_REGISTRATION_LOG"\n');
  fs.chmodSync(lsregister, 0o755);
  const generated = ['src-tauri/target/output', 'frontend/dist/index.html', '.artifacts/plan.md'];
  for (const relative of generated) put(path.join(root, relative));
  const generatedApp = path.join(root, 'src-tauri/target/release/bundle/macos/AlgerMusicPlayer.app');
  put(path.join(generatedApp, 'Contents/Info.plist'));
  const protectedPaths = [
    'checkout with spaces/dist/AlgerMusicPlayer.app/Contents/keep',
    'checkout with spaces/src-tauri/src/lib.rs',
    'checkout with spaces/tests/keep',
    'checkout with spaces/node_modules/keep',
    'checkout with spaces/.tools/keep',
    'home/Library/Application Support/AlgerMusicPlayer/session.json',
    'home/Library/Application Support/AlgerMusicPlayer.trial/session.json',
    'home/Library/Caches/com.alger.music/keep',
    'home/Library/WebKit/com.alger.music.trial/keep',
    'tmp/alger-unmarked/keep',
    'tmp/alger-foreign/keep',
    'tmp/alger-active/keep',
  ];
  for (const relative of protectedPaths) put(path.join(fixture, relative));
  put(path.join(tmp, 'alger-owned/.alger-project'), root);
  const temporaryApp = path.join(tmp, 'alger-owned/AlgerMusicPlayer.app');
  put(path.join(temporaryApp, 'Contents/Info.plist'));
  put(path.join(tmp, 'alger-foreign/.alger-project'), '/some/other/checkout');
  put(path.join(tmp, 'alger-active/.alger-project'), root);
  put(path.join(tmp, 'alger-active/.alger-owner-pid'), String(process.pid));
  const derived = path.join(home, 'Library/Developer/Xcode/DerivedData');
  const xcodeAvailable = fs.existsSync('/usr/libexec/PlistBuddy');
  if (xcodeAvailable) {
    const plist = workspace => `<?xml version="1.0"?><plist version="1.0"><dict><key>WorkspacePath</key><string>${workspace}</string></dict></plist>`;
    put(path.join(derived, 'owned/info.plist'), plist(path.join(root, 'src-tauri/gen/apple/app.xcworkspace')));
    put(path.join(derived, 'foreign/info.plist'), plist('/another/checkout/app.xcworkspace'));
    put(path.join(derived, 'alger-music-unproven/keep'));
  }
  // A generated path pointing at the persistent application must be skipped.
  fs.symlinkSync(path.join(root, 'dist'), path.join(root, 'src-tauri/gen'));
  put(path.join(root, 'dist/schemas/keep'));
  const run = (...args) => {
    const result = spawnSync('/bin/sh', [path.join(root, 'scripts/clean.sh'), ...args], {
      cwd: fixture, env: {
        ...process.env, HOME: home, TMPDIR: tmp,
        ALGER_LSREGISTER: lsregister, ALGER_REGISTRATION_LOG: registrationLog,
      }, encoding: 'utf8',
    });
    assert.equal(result.status, 0, result.stdout + result.stderr);
    return result.stdout;
  };
  assert.match(run('--dry-run'), /would remove/);
  for (const relative of generated) assert.ok(fs.existsSync(path.join(root, relative)));
  assert.ok(fs.existsSync(path.join(tmp, 'alger-owned')));
  assert.ok(!fs.existsSync(registrationLog), 'dry run must not alter application registrations');
  run();
  assert.deepEqual(fs.readFileSync(registrationLog, 'utf8').trim().split('\n').sort(), [generatedApp, temporaryApp].sort());
  for (const relative of generated) assert.ok(!fs.existsSync(path.join(root, relative)), relative);
  assert.ok(!fs.existsSync(path.join(tmp, 'alger-owned')));
  for (const relative of protectedPaths) {
    assert.equal(fs.readFileSync(path.join(fixture, relative), 'utf8'), 'keep', relative);
  }
  assert.equal(fs.readFileSync(path.join(root, 'dist/schemas/keep'), 'utf8'), 'keep');
  if (xcodeAvailable) {
    assert.ok(!fs.existsSync(path.join(derived, 'owned')));
    assert.ok(fs.existsSync(path.join(derived, 'foreign/info.plist')));
    assert.ok(fs.existsSync(path.join(derived, 'alger-music-unproven/keep')));
  }
  run(); // Cleanup is repeatable.
  console.log('cleanup acceptance passed: dry run, arbitrary cwd, ownership, active PID, symlinks, persistent data, unregister bundles before deletion');
} finally {
  fs.rmSync(fixture, { recursive: true, force: true });
}
