const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../panel/dialogs/Shortcut.qml'), 'utf8');
const pressed = source.match(/Keys\.onPressed: function\(event\) \{([\s\S]*?)\n        \}\n        Keys\.onReleased/)[1];
const released = source.match(/Keys\.onReleased: function\(event\) \{([\s\S]*?)\n        \}/)[1];
const Qt = {Key_A: 65, Key_Z: 90, Key_0: 48, Key_9: 57, Key_F1: 0x1000030,
  Key_F12: 0x100003b, MetaModifier: 0x10000000, ControlModifier: 0x04000000,
  AltModifier: 0x08000000, ShiftModifier: 0x02000000, KeypadModifier: 0x20000000,
  GroupSwitchModifier: 0x40000000, NoModifier: 0, Key_Space: 32, Key_Slash: 47, Key_Question: 63};
['Escape', 'Tab', 'Backtab', 'Backspace', 'Return', 'Enter', 'Insert', 'Delete'].forEach((k, i) => Qt['Key_' + k] = 0x1000000 + i);
['Home', 'End', 'Left', 'Up', 'Right', 'Down', 'PageUp', 'PageDown'].forEach((k, i) => Qt['Key_' + k] = 0x1000010 + i);
const saves = [];
const dialog = {running: false, capturedShortcut: '', actionRequested: (...args) => saves.push(args), closeRequested: () => saves.push(['close'])};
const context = vm.createContext({Qt, dialog, captureBox: {heldKey: 0}, shortcutInhibitor: {active: true}});
vm.runInContext(`function press(event) {${pressed}}; function release(event) {${released}}`, context);
const chord = {key: 80, modifiers: Qt.MetaModifier | Qt.ControlModifier, isAutoRepeat: false};
context.press(chord);
assert.deepEqual(saves, [['save', 'SUPER + CTRL + P']]);
context.press(chord);
assert.equal(saves.length, 1); // Holding a chord must not save repeatedly.
context.release(chord);
context.press({...chord, isAutoRepeat: true});
assert.equal(saves.length, 1);
context.shortcutInhibitor.active = false;
context.press(chord);
assert.equal(saves.length, 1); // Never save if compositor capture is unavailable.
context.shortcutInhibitor.active = true;
context.press({...chord, modifiers: 0});
assert.equal(saves.length, 1);
context.press({...chord, key: Qt.Key_F1, modifiers: Qt.AltModifier});
assert.deepEqual(saves[1], ['save', 'ALT + F1']);
context.release({key: Qt.Key_F1});
context.press({key: Qt.Key_Escape, modifiers: 0});
assert.deepEqual(saves[2], ['close']);
console.log('shortcut-capture-test: ok');

context.press({key: Qt.Key_Question, modifiers: Qt.MetaModifier});
assert.deepEqual(saves[3], ['save', 'SUPER + SHIFT + SLASH']);

// Feed the real process response handler a conflict, then a successful replacement.
const panel = fs.readFileSync(path.join(__dirname, '../Panel.qml'), 'utf8');
const handler = panel.match(/property Process shortcutProcess: Process \{[\s\S]*?onExited: function\(exitCode\) \{([\s\S]*?)\n    \}\n  \}/)[1];
const state = {shortcutSaved: '', shortcutPending: '', shortcutResult: ''};
const output = {text: JSON.stringify({shortcut: '', pendingShortcut: 'SUPER + SHIFT + SLASH', message: 'Already assigned to Passwords.'})};
const response = vm.createContext({root: state, shortcutOutput: output, action: 'save'});
vm.runInContext(`function exited(exitCode) {${handler}}`, response);
response.exited(0);
assert.equal(state.shortcutPending, 'SUPER + SHIFT + SLASH');
assert.equal(state.shortcutSaved, '');
response.action = 'replace';
output.text = JSON.stringify({shortcut: 'SUPER + SHIFT + SLASH', message: 'Shortcut saved.'});
response.exited(0);
assert.equal(state.shortcutPending, '');
assert.equal(state.shortcutSaved, 'SUPER + SHIFT + SLASH');
