// Exercises the actual service functions; screens/files are mocked, Qt's
// binding scheduler and video renderer are not. Run: node --test tests/*.test.cjs
const test = require('node:test');
const assert = require('node:assert/strict');
const {fresh, source} = require('./service-harness.cjs');
const plain = value => JSON.parse(JSON.stringify(value));
const screens = c => plain(c.activeScreens.map(s => s.name));

test('Play one screen after global Stop leaves the other stopped', () => {
  const c=fresh();c.applyStop();c.applyPlayScreen('DP-1');
  assert.deepEqual(screens(c),['DP-1']);assert.equal(c.enabled,false);
});
test('global Stop respects an explicit per-screen Play and status agrees', () => {
  const c=fresh();c.applyPlayScreen('DP-1');c.applyStop();
  assert.deepEqual(screens(c),['DP-1']);
  assert.equal(c.screensObject()[0].playing,true);
  assert.equal(c.screensObject()[1].playing,false);
});
test('choosing a clip restarts only its screen, including its own pause', () => {
  const c=fresh();c.applyStop();c.applyStopScreen('DP-1');c.applyPauseScreen('DP-1');
  c.applySetScreenVideo('DP-1','/clips/b.mp4');
  assert.deepEqual(screens(c),['DP-1']);assert.equal(c.pausedFor('DP-1'),false);
  assert.equal(c.enabled,false);assert.equal(c.pathForScreen('DP-1'),'/clips/b.mp4');
});
test('Play releases the library Off opt-out on one screen', () => {
  const c=fresh();c.applySetScreenVideo('DP-1','');c.applyStop();c.applyPlayScreen('DP-1');
  assert.deepEqual(screens(c),['DP-1']);assert.equal(c.pathForScreen('DP-1'),'/clips/a.mp4');
});
test('Play on a screen outside legacy output does not retarget another screen', () => {
  const c=fresh();c.output='DP-2';c.applyStop();c.applyPlayScreen('DP-1');
  assert.deepEqual(screens(c),['DP-1']);assert.equal(c.output,'DP-2');
});
test('global clip selection releases stopped and paused screen overrides', () => {
  const c=fresh();c.applyStopScreen('DP-1');c.applyPauseScreen('DP-2');c.applySetSpeedOn('DP-1',.5);
  c.applyPlayAll('/clips/b.mp4');assert.deepEqual(screens(c),['DP-1','DP-2']);
  assert.equal(c.pausedFor('DP-2'),false);assert.equal(c.speedFor('DP-1'),.5);
});
test('rotation-only reset preserves all playback overrides', () => {
  const c=fresh();c.applySetSpeedOn('DP-1',.5);c.applyStopScreen('DP-1');c.applyPauseScreen('DP-1');
  c.applySetRotation('all','sequential',5,'DP-1');c.applyClearScreenRotation('DP-1');
  assert.deepEqual(plain(c.screenRotation['DP-1']),{speed:.5,off:true,paused:true});
});
test('playback-only reset preserves rotation, and clearing both removes profile', () => {
  const c=fresh();c.applySetRotation('all','sequential',5,'DP-1');c.applyStopScreen('DP-1');
  c.applyClearScreenPlayback('DP-1');
  assert.deepEqual(plain(c.screenRotation['DP-1']),{mode:'all',order:'sequential',interval:5});
  c.applyClearScreenRotation('DP-1');assert.deepEqual(plain(c.screenRotation),{});
});
test('editing one rotation field leaves the others inherited', () => {
  const c=fresh();c.applySetRotation('all','','','DP-1');
  c.applySetRotation('','shuffle',10,'all');
  assert.deepEqual(plain(c.screenRotation['DP-1']),{mode:'all'});
  assert.equal(c.rotOrderFor('DP-1'),'shuffle');assert.equal(c.rotIntervalFor('DP-1'),10);
});
test('all-mode skips a deleted current clip even before seeding reacts', () => {
  const c=fresh();c.rotationMode='all';c.seedRotation();
  delete c.existingPaths['/clips/a.mp4'];c.statedPaths['/clips/a.mp4']=true;
  assert.equal(c.pathForScreen('DP-1'),'/clips/b.mp4');
  assert.deepEqual(screens(c),['DP-1','DP-2']);
  c.seedRotation();assert.equal(c.rotCurrent['DP-1'],'/clips/b.mp4');
});
test('empty libraries keep discovery running only when rotation is requested', () => {
  const c=fresh();c.availableVideos=[];c.rotationMode='all';c.seedRotation();
  assert.equal(c.anyRotationActive,false);assert.equal(c.anyRotationRequested,true);
  c.rotationMode='off';assert.equal(c.anyRotationRequested,false);
  c.screenRotation={disconnected:{mode:'all'}};assert.equal(c.anyRotationRequested,false);
});
test('sequential rotation follows the current file after reorder and removal', () => {
  const c=fresh();c.rotationMode='selected';c.playlist=['/clips/a.mp4','/clips/b.mp4','/clips/c.mp4'];
  c.rotCurrent={'DP-1':'/clips/b.mp4'};c.rotCursor={'DP-1':1};
  c.playlist=['/clips/b.mp4','/clips/a.mp4','/clips/c.mp4'];c.seedRotation();
  assert.equal(c.rotCursor['DP-1'],0);c.advanceRotationFor('DP-1');
  assert.equal(c.rotCurrent['DP-1'],'/clips/a.mp4');
  c.playlist=['/clips/a.mp4','/clips/c.mp4'];c.advanceRotationFor('DP-1');
  assert.equal(c.rotCurrent['DP-1'],'/clips/c.mp4');
});
test('shuffle never repeats the current index', () => {
  const c=fresh();c.rotationOrder='shuffle';
  for(let i=0;i<300;i++) assert.notEqual(c._pickIndex('DP-1',[1,2,3],1),1);
});
test('unplugged monitors do not accumulate rotation cursors', () => {
  const c=fresh();c.rotCurrent={disconnected:'/clips/a.mp4'};c.rotCursor={disconnected:0};c.seedRotation();
  assert.deepEqual(plain(c.rotCurrent),{});assert.deepEqual(plain(c.rotCursor),{});
});
test('every profile insertion enforces the cap and allows existing entries to change', () => {
  for(const insert of [c=>c.applyPlayScreen('extra'),c=>c.applyStopScreen('extra'),
    c=>c.applySetSpeedOn('extra',.5),c=>c.applySetRotation('all','','','extra'),
    c=>c.applySetPlaylist(['/clips/a.mp4'],'extra')]) {
    const c=fresh();for(let i=0;i<64;i++) c.screenRotation['screen'+i]={speed:1};
    insert(c);assert.equal(Object.keys(c.screenRotation).length,64);
    c.applySetSpeedOn('screen0',.5);assert.equal(c.screenRotation.screen0.speed,.5);
    c.applyClearScreenRotation('absent');assert.equal(Object.keys(c.screenRotation).length,64);
  }
});
test('bad connector names cannot enter either map', () => {
  const c=fresh();
  for(const name of ['x'.repeat(9000),'__proto__','constructor','prototype']) {
    c.applyPlayScreen(name);c.applySetRotation('all','','',name);
    c.applySetPlaylist(['/clips/a.mp4'],name);c.applySetScreenVideo(name,'/clips/a.mp4');
  }
  assert.deepEqual(plain(c.screenRotation),{});assert.deepEqual(plain(c.screenVideos),{});
});
test('array-like hostile playlists cannot cause an unbounded loop', () => {
  const c=fresh();assert.deepEqual(plain(c.normalizePlaylist({length:Infinity})),[]);
  assert.deepEqual(plain(c.normalizePlaylist({length:1e12,0:'/clips/a.mp4'})),[]);
  assert.equal(c.normalizePlaylist(Array(500).fill('a').concat(['b'])).length,1);
});
test('large valid state is accepted, oversized state is rejected before mutation', () => {
  const c=fresh();const list=Array.from({length:500},(_,i)=>'/clips/'+String(i).padStart(4,'0')+'x'.repeat(280)+'.mp4');
  c.applySetPlaylist(list,'all');assert.ok(Buffer.byteLength(c.lastPersisted)>131072);
  assert.ok(Buffer.byteLength(c.lastPersisted)<=c.maxStateBytes);
  const before=c.lastPersisted;c.applySetPlaylist(list,'DP-1');
  assert.equal(c.lastPersisted,before);assert.equal(c.screenRotation['DP-1'],undefined);
  assert.match(c.persistenceError,/too large/);
});
test('state bound counts UTF-8 bytes and a rejected update leaves state unchanged', () => {
  const c=fresh();const before=JSON.stringify(c.stateObject());
  const list=Array.from({length:500},(_,i)=>'/clips/'+i+'é'.repeat(280)+'.mp4');
  c.applySetPlaylist(list,'all');assert.equal(JSON.stringify(c.stateObject()),before);
  assert.match(c.persistenceError,/too large/);
});
test('saved state round trips all durable playback and rotation settings', () => {
  const c=fresh();c.applyPlayScreen('DP-1');c.applySetSpeedOn('DP-1',.66);
  c.applySetRotation('selected','sequential',2,'DP-1');c.applySetPlaylist(['/clips/b.mp4'],'DP-1');
  const loaded=fresh();assert.equal(loaded.applyStateText(c.lastPersisted),true);
  assert.deepEqual(plain(loaded.stateObject()),plain(c.stateObject()));
});
test('old state without added settings keeps defaults', () => {
  const c=fresh();assert.equal(c.applyStateText('{"videoPath":"/clips/b.mp4","enabled":false}'),true);
  assert.equal(c.playbackSpeed,1);assert.equal(c.rotationMode,'off');assert.deepEqual(plain(c.screenRotation),{});
});
test('per-screen preview is live, does not persist, and cancellation restores inheritance', () => {
  const c=fresh();c.applySetSpeed(1);const saved=c.lastPersisted;
  c.previewSpeed(.5,'DP-1');assert.equal(c.speedFor('DP-1'),.5);assert.equal(c.speedFor('DP-2'),1);
  c.applySetRotation('all','','','all');assert.equal(JSON.parse(c.lastPersisted).screenRotation['DP-1'],undefined);
  assert.equal(JSON.parse(saved).playbackSpeed,JSON.parse(c.lastPersisted).playbackSpeed);
  c.clearSpeedPreview('DP-1');assert.equal(c.speedFor('DP-1'),1);
});
test('global preview respects explicit per-screen speed, release commits the selected screen', () => {
  const c=fresh();c.applySetSpeedOn('DP-2',.75);c.previewSpeed(.5,'all');
  assert.equal(c.speedFor('DP-1'),.5);assert.equal(c.speedFor('DP-2'),.75);
  c.clearSpeedPreview('all');c.previewSpeed(.66,'DP-1');c.applySetSpeedOn('DP-1',.66);c.clearSpeedPreview('DP-1');
  assert.equal(c.speedFor('DP-1'),.66);assert.equal(JSON.parse(c.lastPersisted).screenRotation['DP-1'].speed,.66);
});

test('inherited object names become real profiles and cannot bypass the state byte cap', () => {
  for (const name of ['toString', 'hasOwnProperty', 'valueOf', '__defineGetter__']) {
    const c=fresh();c.applySetSpeedOn(name,.5);
    assert.equal(JSON.parse(c.lastPersisted).screenRotation[name].speed,.5);
    const before=c.lastPersisted;
    c.applySetPlaylist(Array.from({length:500},(_,i)=>'/clips/'+i+'x'.repeat(3000)),name);
    assert.equal(c.lastPersisted,before);assert.match(c.persistenceError,/too large/);
    assert.equal(c.screenRotation[name].playlist,undefined);
  }
});
