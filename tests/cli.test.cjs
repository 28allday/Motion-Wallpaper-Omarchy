const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const cli = path.join(__dirname, '..', 'motion-wallpaper');
function fixture(t, status = {}, reply = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'motion-cli-test-'));
  t.after(() => fs.rmSync(dir, {recursive: true, force: true}));
  fs.writeFileSync(path.join(dir, 'status.json'), JSON.stringify(status));
  fs.writeFileSync(path.join(dir, 'reply.json'), JSON.stringify(reply));
  fs.writeFileSync(path.join(dir, 'omarchy-shell'), `#!/usr/bin/env bash
printf '%s\\0' "$@" >> "$MOTION_TEST_DIR/calls"
printf '\\n' >> "$MOTION_TEST_DIR/calls"
if [ "$2" = status ]; then cat "$MOTION_TEST_DIR/status.json"
else cat "$MOTION_TEST_DIR/reply.json"; fi
`, {mode: 0o700});
  return {
    run(...args) {
      const r = spawnSync('bash', [cli, ...args], {encoding:'utf8', timeout:6000, killSignal:'SIGKILL',
        env:{...process.env, PATH:dir + ':' + process.env.PATH, XDG_CACHE_HOME:dir, MOTION_TEST_DIR:dir}});
      assert.ifError(r.error);
      return r;
    },
    calls() { return fs.readFileSync(path.join(dir, 'calls'), 'utf8').trim().split('\n').map(x => x.split('\0').slice(0,-1)); }
  };
}
test('help prints cleanly without executing its examples', t => {
  const r = fixture(t).run('--help');
  assert.equal(r.status, 0); assert.equal(r.stderr, ''); assert.match(r.stdout, /Restart one monitor after stop <screen>/);
});
for (const defaults of [{enabled:false}, {enabled:true,manualPaused:true}]) {
  test('status follows a playing screen despite stopped or paused defaults ' + JSON.stringify(defaults), t => {
    const r = fixture(t, {...defaults,screens:[{name:'DP-1',video:'/a.mp4',playing:true,fileExists:true,off:false}]}).run('status');
    assert.equal(r.status,0); assert.match(r.stdout,/status: +playing/);
  });
}
test('status reports all stopped screens as stopped', t => {
  const r = fixture(t, {enabled:true,screens:[{name:'DP-1',video:'',off:true}]}).run('status');
  assert.equal(r.status,0); assert.match(r.stdout,/status: +stopped/);
});
test('rejected profile changes fail visibly in the CLI', t => {
  const r = fixture(t, {}, {persistenceError:'Screen profile limit reached.'}).run('speed','0.5','DP-1');
  assert.equal(r.status,1); assert.match(r.stderr,/Screen profile limit reached/);
});
test('rotation-only follow leaves playback controls untouched', t => {
  const f=fixture(t); assert.equal(f.run('follow','DP-1','rotation').status,0);
  assert.deepEqual(f.calls(),[['motion-wallpaper','status'],['motion-wallpaper','clearRotationOn','DP-1']]);
});
test('changing rotation mode leaves omitted order and interval inherited', t => {
  const f=fixture(t); assert.equal(f.run('rotate','all','','','DP-1').status,0);
  assert.deepEqual(f.calls().at(-1),['motion-wallpaper','setRotationOn','DP-1','all','','']);
});
test('order alias still maps to sequential', t => {
  const f=fixture(t); assert.equal(f.run('rotate','all','order','5','DP-1').status,0);
  assert.deepEqual(f.calls().at(-1),['motion-wallpaper','setRotationOn','DP-1','all','sequential','5']);
});
