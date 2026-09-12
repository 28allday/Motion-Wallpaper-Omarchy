const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const {spawnSync} = require('node:child_process');
const {source, functions} = require('./service-harness.cjs');
const expression = source.match(/readonly property string stateWriteScript:\n([\s\S]+?)\n\n/)[1];
const script = vm.runInNewContext(expression);
const cap=262144;
function temp(t) {
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'motion-wallpaper-test-'));
  t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));
  return dir;
}
function write(file,input) {return spawnSync('bash',['-c',script,'_',file,String(cap)],{input,encoding:'utf8',timeout:6000,killSignal:'SIGKILL'});}

test('real atomic writer accepts payloads larger than one Linux argument',t=>{
  const file=path.join(temp(t),'state.json');const input=JSON.stringify({data:'é'.repeat(90000)})+'\n';
  assert.ok(Buffer.byteLength(input)>131072);assert.equal(write(file,input).status,0);
  assert.equal(fs.readFileSync(file,'utf8'),input);
});
test('writer rejects an oversized payload and preserves previous state',t=>{
  const dir=temp(t);const file=path.join(dir,'state.json');fs.writeFileSync(file,'previous');
  assert.notEqual(write(file,'x'.repeat(cap+1)).status,0);assert.equal(fs.readFileSync(file,'utf8'),'previous');
  assert.deepEqual(fs.readdirSync(dir),['state.json']);
});
test('writer accepts exactly its byte limit',t=>{
  const file=path.join(temp(t),'state.json');const input='x'.repeat(cap);
  assert.equal(write(file,input).status,0);assert.equal(fs.statSync(file).size,cap);
});
test('writer replaces a symlink without changing its target',t=>{
  const dir=temp(t);const target=path.join(dir,'target');fs.writeFileSync(target,'unchanged');
  const file=path.join(dir,'state.json');fs.symlinkSync(target,file);
  assert.equal(write(file,'replacement').status,0);assert.equal(fs.readFileSync(target,'utf8'),'unchanged');
  assert.equal(fs.lstatSync(file).isSymbolicLink(),false);
});
test('writer refuses directory destinations and cleans its temporary file',t=>{
  const dir=temp(t);const file=path.join(dir,'state.json');fs.mkdirSync(file);
  assert.notEqual(write(file,'replacement').status,0);
  assert.deepEqual(fs.readdirSync(file),[]);assert.deepEqual(fs.readdirSync(dir),['state.json']);
});

// Only the production Process block and writeState function are loaded in
// this tiny offscreen fixture. It never loads the plugin, media surfaces,
// installed shell config, or the user's state file.
function qmlFixture(file,body) {
  const process=source.match(/  Process \{\n    id: stateWriteProc[\s\S]+?\n  \}/)[0];
  const writeState=functions.find(f=>f.startsWith('  function writeState('));
  return `import QtQuick\nimport Quickshell.Io\nItem {\n id: root
 property string statePath: ${JSON.stringify(file)}
 property int maxStateBytes: ${cap}
 property var timeoutPrefix: ["timeout", "-k", "1", "5"]
 property string stateWriteScript: ${JSON.stringify(script)}
 property string persistenceError: ""
 property string _pendingState: ""
 ${process}
 ${writeState}
 ${body}
 Timer { interval: 8000; running: true; onTriggered: Qt.exit(9) }
}`;
}
function qmlRun(t,body,setup=()=>{}) {
  const dir=temp(t);const file=path.join(dir,'state.json');setup(file);
  const fixture=path.join(dir,'fixture.qml');fs.writeFileSync(fixture,qmlFixture(file,body));
  const runtime=path.join(dir,'runtime');fs.mkdirSync(runtime,{mode:0o700});
  const env={...process.env,QT_QPA_PLATFORM:'offscreen',QT_QPA_PLATFORMTHEME:'generic',
    QT_QUICK_CONTROLS_STYLE:'Basic',QT_FORCE_STDERR_LOGGING:'1',XDG_RUNTIME_DIR:runtime};
  delete env.WAYLAND_DISPLAY;
  const r=spawnSync('qs',['-p',fixture],{env,encoding:'utf8',timeout:12000,killSignal:'SIGKILL'});
  assert.ifError(r.error);assert.equal(r.status,0,r.stdout+r.stderr);
  assert.doesNotMatch(r.stdout+r.stderr,/binding loop|ReferenceError|TypeError|failed to load/i);
  return {file,output:r.stdout+r.stderr};
}
test('Quickshell Process flushes a large stdin payload before closing',t=>{
  const {file}=qmlRun(t,`Component.onCompleted: root.writeState("x".repeat(180000))
    Connections { target: stateWriteProc; function onExited(code) { Qt.exit(code) } }`);
  assert.equal(fs.readFileSync(file,'utf8'),'x'.repeat(180000));
});
test('Quickshell writer drains rapid saves and persists the latest request',t=>{
  const {file}=qmlRun(t,`Component.onCompleted: {
      root.writeState("a".repeat(180000));root.writeState("middle");root.writeState("latest")
    }
    Timer { interval: 30; repeat: true; running: true
      onTriggered: if (!stateWriteProc.running && root._pendingState === "") Qt.quit()
    }`);
  assert.equal(fs.readFileSync(file,'utf8'),'latest');
});
test('Quickshell writer reports failure and recovers for the next save',t=>{
  const {file,output}=qmlRun(t,`property bool sawFailure: false
    Component.onCompleted: root.writeState("first")
    Timer { interval: 30; repeat: true; running: true
      onTriggered: {
        if (stateWriteProc.running || root._pendingState !== "") return
        if (!root.sawFailure) {
          if (root.persistenceError === "") { Qt.exit(7); return }
          root.sawFailure = true
          root.statePath += ".recovered"
          root.writeState("recovered")
        } else { if (root.persistenceError !== "") Qt.exit(8); else Qt.quit() }
      }
    }`,file=>fs.mkdirSync(file));
  assert.match(output,/state write failed/);assert.equal(fs.readFileSync(file+'.recovered','utf8'),'recovered');
});
