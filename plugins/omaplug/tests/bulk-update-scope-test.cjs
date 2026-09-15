const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const context = vm.createContext({});
vm.runInContext(fs.readFileSync(path.join(__dirname, '../panel/Presentation.js'), 'utf8')
  .replace(/^\.pragma library\s*/, ''), context);
const rows = ['verified', 'pending', 'unverified', 'unknown', 'current'].map(id => ({ id, sourceKey: id }));
const states = Object.fromEntries(rows.map(row => [row.id, row.id === 'current' ? 'CURRENT' : 'UPDATE']));
const catalog = {
  verified: { verified: true },
  pending: { verified: false, snapshotStatus: 'update-unverified' },
  unverified: { verified: false },
  current: { verified: true },
};
const keys = (scope, sourceRows = rows, entries = catalog) =>
  Array.from(context.bulkUpdateKeys(sourceRows, states, entries, scope));
assert.deepEqual(keys('verified'), ['verified']);
assert.deepEqual(keys('pending'), ['verified', 'pending']);
assert.deepEqual(keys('all'), ['verified', 'pending', 'unverified', 'unknown']);
assert.deepEqual(keys('verified', rows, {}), []);
assert.deepEqual(keys('pending', rows, {}), []);
const shared = [...rows, { id: 'unverified', sourceKey: 'verified' }];
assert.deepEqual(keys('verified', shared), []);
assert.deepEqual(keys('pending', shared), ['pending']);
assert.deepEqual(keys('all', shared), ['verified', 'pending', 'unverified', 'unknown']);
catalog.pending = { verified: true };
assert.deepEqual(keys('verified'), ['verified', 'pending']);
console.log('bulk-update-scope-test: ok');
