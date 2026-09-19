const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const source = fs.readFileSync(require('node:path').join(__dirname, '../panel/Presentation.js'), 'utf8')
  .replace('.pragma library', '');
const context = vm.createContext({});
vm.runInContext(source, context);

for (const input of [
  'https://github.com/owner/repo',
  'https://github.com/owner/repo.git',
  'git@github.com:owner/repo.git',
  'ssh://git@github.com/owner/repo.git'
]) {
  assert.equal(context.normalizedGitHubUrl(input), 'https://github.com/owner/repo');
}
for (const input of [
  'file:///tmp/repo',
  'git@gitlab.com:owner/repo.git',
  'https://github.com/owner/../repo',
  'https://github.com/owner/repo?command=bad'
]) {
  assert.equal(context.normalizedGitHubUrl(input), '');
}
console.log('presentation-links-test: ok');
