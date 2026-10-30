const test = require('node:test');
const assert = require('node:assert');
const { comment, run } = require('./issue-update.js');

test('says what the problem was, how far the fix is tested and where it ships', () => {
  const verified = comment({ problem: ' Fullscreen minimized the game. ', outcome: 'verified', release: '0.6.5' });
  assert.match(verified, /^Fullscreen minimized the game\.\n\nFixed: the problem was reproduced/);
  assert.match(verified, /It's in OverPass 0\.6\.5\./);
  const untested = comment({ problem: 'x', outcome: 'untested', release: '' });
  assert.match(untested, /should work now/);
  assert.match(untested, /next OverPass update/);
  assert.match(untested, /send a new report from OverPass/);
});

test('refuses an empty description or an unknown outcome', () => {
  assert.throws(() => comment({ problem: ' ', outcome: 'verified' }));
  assert.throws(() => comment({ problem: 'x', outcome: 'constructor' }));
});

test('comments on the issue it was given', async () => {
  const calls = [];
  const github = { rest: { issues: { createComment: async args => calls.push(args) } } };
  await run({ github, context: { repo: { owner: 'McKack', repo: 'overpass' } }, inputs: { issue: '3', problem: 'x', outcome: 'verified' } });
  assert.strictEqual(calls[0].issue_number, 3);
  assert.strictEqual(calls[0].repo, 'overpass');
});
