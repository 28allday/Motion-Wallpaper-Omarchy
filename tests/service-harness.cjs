const fs = require('fs');
const vm = require('vm');

const path = require('path');
const filename = path.join(__dirname, '..', 'Service.qml');
const source = fs.readFileSync(filename, 'utf8');
const lines = source.split('\n');
const functions = [];
for (let i = 0; i < lines.length && !lines[i].startsWith('  IpcHandler {'); i++) {
  if (!/^  function /.test(lines[i])) continue;
  let text = lines[i];
  if (!/\}\s*$/.test(text)) {
    while (++i < lines.length) {
      text += '\n' + lines[i];
      if (lines[i] === '  }') break;
    }
  }
  functions.push(text);
}
function propertyBody(name) {
  const start = lines.findIndex(l => new RegExp('^  (readonly )?property \\w+ ' + name + ': \\{').test(l));
  if (start < 0) throw new Error('Missing property ' + name);
  let end = start + 1;
  while (lines[end] !== '  }') end++;
  return lines.slice(start + 1, end).join('\n');
}
function fresh() {
  const c = {
    console, home: '/home/test', minSpeed:.25,maxSpeed:2,minInterval:1,maxInterval:60,
    maxScreenVideos:64,maxNameLength:256,maxPathLength:4096,maxPlaylist:500,maxStateBytes:262144,
    videoPath:'/clips/a.mp4',enabled:true,output:'all',pauseOnFullscreen:false,manualPaused:false,
    speedPreviewScope:'',speedPreviewValue:1,persistenceError:'',playbackSpeed:1,rotationMode:'off',rotationOrder:'sequential',rotationInterval:1,
    playlist:[],screenVideos:{},screenRotation:{},rotCurrent:{},rotCursor:{},
    availableVideos:['a','b','c'].map(n=>({path:'/clips/'+n+'.mp4',name:n})),
    existingPaths:{'/clips/a.mp4':true,'/clips/b.mp4':true,'/clips/c.mp4':true},
    statedPaths:{},fullscreenMonitors:{},
    Quickshell:{screens:[{name:'DP-1'},{name:'DP-2'}]},
    writeState(text){ this.lastPersisted = text; }
  };
  c.root=c;vm.createContext(c);vm.runInContext(functions.join('\n'),c);
  c.writeState=function(text){c.lastPersisted=text;c.persistenceError='';};
  c.checkVideoFiles=function(){};
  for(const name of ['libraryPaths','screenPlans','anyRotationActive','anyRotationRequested','activeScreens']) {
    const get=vm.runInContext('(function(){'+propertyBody(name)+'})',c);
    Object.defineProperty(c,name,{get});
  }
  Object.defineProperty(c,'rendering',{get(){return c.activeScreens.length>0;}});
  Object.defineProperty(c,'videoFileExists',{get(){return c.pathExists(c.videoPath);}});
  return c;
}

module.exports = {fresh, source, propertyBody, functions};
