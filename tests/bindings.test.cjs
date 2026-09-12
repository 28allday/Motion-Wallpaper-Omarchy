const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const {fresh, functions, propertyBody} = require('./service-harness.cjs');

// Exercise production bindings in Qt, mocking only the screen provider and
// I/O boundaries. This fixture has no media surfaces or installed shell.
function run(t, qml) {
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'motion-binding-test-'));
  t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));
  const file=path.join(dir,'fixture.qml');fs.writeFileSync(file,qml);
  const runtime=path.join(dir,'runtime');fs.mkdirSync(runtime,{mode:0o700});
  const env={...process.env,QT_QPA_PLATFORM:'offscreen',QT_QPA_PLATFORMTHEME:'generic',
    QT_QUICK_CONTROLS_STYLE:'Basic',QT_FORCE_STDERR_LOGGING:'1',XDG_RUNTIME_DIR:runtime};
  delete env.WAYLAND_DISPLAY;
  const r=spawnSync('qs',['-p',file],{env,encoding:'utf8',timeout:10000,killSignal:'SIGKILL'});
  assert.ifError(r.error);assert.equal(r.status,0,r.stdout+r.stderr);
  assert.doesNotMatch(r.stdout+r.stderr,/binding loop|ReferenceError|TypeError|failed to load/i);
}
function serviceFixture(body) {
  const c=fresh(); const props=[];
  for(const [key,value] of Object.entries(c)) {
    if(['root','console','Quickshell'].includes(key)||typeof value==='function') continue;
    const type=typeof value==='boolean'?'bool':typeof value==='number'?'real':typeof value==='string'?'string':'var';
    props.push(`property ${type} ${key}: (${JSON.stringify(value)})`);
  }
  const derived=['libraryPaths','screenPlans','anyRotationActive','anyRotationRequested','activeScreens']
    .map(n=>`readonly property var ${n}: {${propertyBody(n)}}`).join('\n');
  const funcs=functions.filter(f=>!/^  function (writeState|checkVideoFiles)\(/.test(f)).join('\n');
  return `import QtQuick
Item { id: root
 ${props.join('\n')}
 property var testScreens: [{name:"DP-1"},{name:"DP-2"}]
 property string lastPersisted: ""
 readonly property bool rendering: root.activeScreens.length > 0
 readonly property bool videoFileExists: root.pathExists(root.videoPath)
 ${derived}
 ${funcs}
 function writeState(text) { root.lastPersisted=text;root.persistenceError="" }
 function checkVideoFiles() {}
 onScreenPlansChanged: root.seedRotation()
 function check(ok,message) { if(!ok) { console.error(message);Qt.exit(2) } }
 Component.onCompleted: { ${body}; Qt.callLater(Qt.quit) }
 Timer { interval:5000;running:true;onTriggered:Qt.exit(9) }
}`.replaceAll('Quickshell.screens','root.testScreens');
}
test('Qt bindings preserve screen isolation and live preview without loops', t => {
  run(t,serviceFixture(`
    root.applyStop();root.applyPlayScreen("DP-1")
    check(root.activeScreens.length===1 && root.activeScreens[0].name==="DP-1","screen isolation")
    root.previewSpeed(.5,"DP-1")
    check(root.speedFor("DP-1")===.5 && root.speedFor("DP-2")===1,"preview scope")
    root.clearSpeedPreview("DP-1")
    check(root.speedFor("DP-1")===1,"preview cancellation")
  `));
});
test('Qt bindings seed new pools and recover from deleted current clips', t => {
  run(t,serviceFixture(`
    root.availableVideos=[];root.applySetRotation("all","sequential",1,"all")
    check(root.anyRotationRequested && !root.anyRotationActive,"empty pool discovery")
    root.availableVideos=[{path:"/clips/a.mp4"},{path:"/clips/b.mp4"}]
    check(root.rotCurrent["DP-1"]==="/clips/a.mp4","seed available pool")
    root.statedPaths={"/clips/a.mp4":true};root.existingPaths={"/clips/b.mp4":true}
    check(root.urlForScreen("DP-1").endsWith("/clips/b.mp4"),"missing clip recovery")
    root.testScreens=[{name:"DP-1"}]
    check(root.rotCurrent["DP-2"]===undefined,"disconnected cursor cleanup")
  `));
});
