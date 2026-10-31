const test = require('node:test');
const assert = require('node:assert');
const { comment, run } = require('./issue-update.js');

test('says what the problem was, how far the fix is tested, where it shipped and what to do if it comes back', () => {
  const verified = comment({ problem: ' Fullscreen minimized the game. ', outcome: 'verified', release: '0.6.5' });
  assert.match(verified, /^Fullscreen minimized the game\.\n\nFixed: the problem was reproduced/);
  assert.match(verified, /It's in OverPass 0\.6\.5\./);
  const untested = comment({ problem: 'x', outcome: 'untested', release: '0.6.5' });
  assert.match(untested, /should work now/);
  assert.match(untested, /Closing this\. If it still happens, send a new report from OverPass\.$/);
});

test('refuses an empty description, an unknown outcome or no release', () => {
  assert.throws(() => comment({ problem: ' ', outcome: 'verified', release: '0.6.5' }));
  assert.throws(() => comment({ problem: 'x', outcome: 'constructor', release: '0.6.5' }));
  assert.throws(() => comment({ problem: 'x', outcome: 'verified', release: ' ' }));
});

const update = async inputs => {
  const calls = [];
  const note = name => async args => calls.push([name, args]);
  const github = { rest: { issues: { createComment: note('comment'), update: note('update') } } };
  await run({ github, context: { repo: { owner: 'McKack', repo: 'overpass' } }, inputs: { issue: '3', outcome: 'verified', ...inputs } });
  return calls;
};

test('comments on the issue it was given, then closes it', async () => {
  const calls = await update({ problem: 'x', release: '0.6.5' });
  assert.deepStrictEqual(calls.map(([n]) => n), ['comment', 'update']);
  assert.strictEqual(calls[0][1].issue_number, 3);
  assert.strictEqual(calls[0][1].repo, 'overpass');
  assert.strictEqual(calls[1][1].state, 'closed');
});

test('no description only closes', async () => {
  const only = await update({ problem: '' });
  assert.deepStrictEqual(only.map(([n]) => n), ['update']);
  assert.strictEqual(only[0][1].state, 'closed');
});

test('a description without a release leaves the issue open', async () => {
  await assert.rejects(update({ problem: 'x', release: '' }));
});
