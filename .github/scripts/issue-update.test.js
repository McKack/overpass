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

const update = async inputs => {
  const calls = [];
  const note = name => async args => calls.push([name, args]);
  const github = { rest: { issues: { createComment: note('comment'), update: note('update') } } };
  await run({ github, context: { repo: { owner: 'McKack', repo: 'overpass' } }, inputs: { issue: '3', outcome: 'verified', ...inputs } });
  return calls;
};

test('comments on the issue it was given, and leaves it open', async () => {
  const calls = await update({ problem: 'x', close: 'false' });
  assert.deepStrictEqual(calls.map(([n]) => n), ['comment']);
  assert.strictEqual(calls[0][1].issue_number, 3);
  assert.strictEqual(calls[0][1].repo, 'overpass');
});

test('close comments first; close with no description only closes', async () => {
  assert.deepStrictEqual((await update({ problem: 'x', close: 'true' })).map(([n]) => n), ['comment', 'update']);
  const only = await update({ problem: '', close: 'true' });
  assert.deepStrictEqual(only.map(([n]) => n), ['update']);
  assert.strictEqual(only[0][1].state, 'closed');
});

test('no description and no close is a mistake', async () => {
  await assert.rejects(update({ problem: '', close: 'false' }));
});
