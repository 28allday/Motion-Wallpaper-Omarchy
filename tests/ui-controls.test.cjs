const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');

const source = fs.readFileSync(path.join(__dirname, '..', 'Panel.qml'), 'utf8');
const shell = process.env.OMARCHY_PATH || '/usr/share/omarchy';
const ui = path.join(shell, 'shell', 'Ui');

// Extract production handlers so this catches regressions in Panel.qml,
// rather than testing a separately maintained implementation of the fix.
function blockFrom(start) {
  const open = source.indexOf('{', start);
  let depth = 1;
  let end = open + 1;
  for (; depth && end < source.length; end++) {
    if (source[end] === '{') depth++;
    else if (source[end] === '}') depth--;
  }
  assert.equal(depth, 0);
  return source.slice(start, end);
}
function changed(id) {
  const start = source.indexOf('onChanged:', source.indexOf('id: ' + id));
  assert.ok(start >= 0, 'Missing handler for ' + id);
  return blockFrom(start);
}
const cancel = blockFrom(source.indexOf('function cancelSpeedPreview()'));

test('real shell controls retain screen bindings and reset cancelled speed drags', t => {
  if (!fs.existsSync(path.join(ui, 'MultiSelect.qml'))) {
    t.skip('Requires the Omarchy shell UI components');
    return;
  }
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'motion-wallpaper-ui-'));
  t.after(() => fs.rmSync(dir, {recursive: true, force: true}));
  for (const name of ['Ui', 'Commons'])
    fs.symlinkSync(path.join(shell, 'shell', name), path.join(dir, name));
  const runtime = path.join(dir, 'runtime');
  fs.mkdirSync(runtime, {mode: 0o700});
  const fixture = path.join(dir, 'fixture.qml');
  fs.writeFileSync(fixture, `import QtQuick
import qs.Ui
Item {
  id: panel
  property string scope: "DP-1"
  property var first: ["a"]
  property var second: ["c"]
  property string firstMode: "off"
  property string secondMode: "selected"
  property int firstInterval: 1
  property int secondInterval: 10
  readonly property var playlistValues: scope === "DP-1" ? first : second
  readonly property string rotationMode: scope === "DP-1" ? firstMode : secondMode
  readonly property int rotationInterval: scope === "DP-1" ? firstInterval : secondInterval
  property real pendingSpeed: -1
  property string pendingSpeedScope: ""
  property real serviceSpeed: 1
  property string clearedScope: ""
  property var service: QtObject {
    function clearSpeedPreview(scope) { panel.clearedScope = scope }
  }
  property var widget: QtObject {
    function setPlaylist(values, scope) {
      if (scope === "DP-1") panel.first = values; else panel.second = values
    }
    function setRotation(mode, order, interval, scope) {
      if (mode !== "") {
        if (scope === "DP-1") panel.firstMode = mode; else panel.secondMode = mode
      }
      if (interval !== "") {
        if (scope === "DP-1") panel.firstInterval = Number(interval); else panel.secondInterval = Number(interval)
      }
    }
  }
  ${cancel}
  Dropdown {
    id: screenDropdown
    value: panel.scope
    options: ["DP-1", "DP-2"]
    ${changed('screenDropdown')}
  }
  Dropdown {
    id: rotModeDropdown
    value: panel.rotationMode
    options: ["off", "all", "selected"]
    ${changed('rotModeDropdown')}
  }
  Dropdown {
    id: rotIntervalDropdown
    value: String(panel.rotationInterval)
    options: ["1", "5", "10"]
    ${changed('rotIntervalDropdown')}
  }
  MultiSelect {
    id: playlistSelect
    values: panel.playlistValues
    options: ["a", "b", "c"]
    ${changed('playlistSelect')}
  }
  PanelSlider {
    id: speedSlider
    value: panel.pendingSpeed >= 0 ? panel.pendingSpeed : panel.serviceSpeed
    minimum: 0.25
    maximum: 2
  }
  function check(ok, message) {
    if (!ok) { console.error(message); Qt.exit(7); throw new Error(message) }
  }
  Timer {
    interval: 100
    running: true
    onTriggered: {
      // Dropdown's actual selection path assigns value before emitting changed.
      // Exercise that operation without opening a native popup or sending input.
      rotModeDropdown.value = "all"; rotModeDropdown.changed("all")
      rotIntervalDropdown.value = "5"; rotIntervalDropdown.changed("5")
      playlistSelect.toggleValue("b")
      screenDropdown.value = "DP-2"; screenDropdown.changed("DP-2")
      check(rotModeDropdown.value === "selected", "Mode did not follow screen switch")
      check(rotIntervalDropdown.value === "10", "Interval did not follow screen switch")
      check(JSON.stringify(playlistSelect.values) === '["c"]', "Playlist did not follow screen switch")
      playlistSelect.toggleValue("a")
      check(JSON.stringify(panel.second) === '["c","a"]', "Second screen lost its original playlist")
      check(JSON.stringify(panel.first) === '["a","b"]', "First screen playlist was changed")
      panel.secondMode = "off"; panel.secondInterval = 1
      check(rotModeDropdown.value === "off" && rotIntervalDropdown.value === "1", "Controls ignored external state change")
      panel.scope = "DP-1"
      check(screenDropdown.value === "DP-1", "Screen dropdown ignored programmatic scope reset")
      speedSlider.dragging = true
      speedSlider.liveValue = 0.5
      panel.pendingSpeed = 0.5; panel.pendingSpeedScope = "DP-1"
      panel.cancelSpeedPreview()
      check(!speedSlider.dragging && speedSlider.liveValue === 1, "Cancelled drag left slider visually stuck")
      check(panel.pendingSpeed === -1 && panel.pendingSpeedScope === "" && panel.clearedScope === "DP-1", "Cancelled drag kept its preview")
      console.log("UI controls passed")
      Qt.quit()
    }
  }
  Timer { interval: 5000; running: true; onTriggered: Qt.exit(9) }
}
`);
  const env = {...process.env, QT_QPA_PLATFORM: 'offscreen', QT_QPA_PLATFORMTHEME: 'generic',
    QT_QUICK_CONTROLS_STYLE: 'Basic', QT_FORCE_STDERR_LOGGING: '1', XDG_RUNTIME_DIR: runtime};
  delete env.WAYLAND_DISPLAY;
  const result = spawnSync('qs', ['-p', fixture], {env, encoding: 'utf8', timeout: 8000, killSignal: 'SIGKILL'});
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout + result.stderr, /UI controls passed/);
  assert.doesNotMatch(result.stdout + result.stderr, /binding loop|ReferenceError|TypeError|failed to load/i);
});
