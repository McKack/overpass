// Every value OverPass can write into a report's details has to pass, whatever it's combined with; anything else
// may only ever label a report. Run with `node --test .github/scripts/`.
const test = require('node:test');
const assert = require('node:assert');
const crypto = require('crypto');
const { check, run, TOLERATED } = require('./check-report.js');

const zip = 'https://reports.arctim.no/overpass/logs/654051b5-8bb7-4772-868a-084720b61770/OverPass%20Logs.zip';

function block(facts) {
  const text = ['overpass-report: 1', ...Object.entries(facts).map(([k, v]) => `${k}: ${v}`)].join('\n');
  return `${text}\nchecksum: ${crypto.createHash('sha256').update(text).digest('hex').slice(0, 16)}`;
}
const relayed = (facts, log = `[Logs](${zip})`) =>
  `### What happened\n\nIt broke.\n\n### Log\n\n${log}\n\n### Details\n\n\`\`\`text\n${block(facts)}\n\`\`\`\n`;
const game = over => ({
  app: 'Astroneer', profile: 'none', store: 'none', overpass: '0.6.4', wine: '11.0-11', runtime: '0.3.0',
  graphics: 'auto (dxmt)', windows: 'windows10', macos: '26.6.2 (25G83)', mac: 'Mac15,3, Apple M3, 24 GB',
  log: 'recorded', ...over,
});
const crash = over => ({ app: 'OverPass', overpass: '0.6.4', macos: '26.6.2 (25G83)',
                         crash: 'EXC_BREAKPOINT SIGTRAP at OverPass  closure #1', log: 'crash report', ...over });

// The tags that exist on GitHub.
const tags = new Set(['v0.6.4', 'v0.6.1', 'v0.3.2', 'v0.1.0', 'v0.3.0', 'overpass-wine-11.0-11', 'overpass-wine-11.0-2']);
const released = async (repo, tag) => tags.has(tag);

const product = (...lists) => lists.reduce((all, list) => all.flatMap(a => list.map(b => [...a, b])), [[]]);

test('every combination the app can write passes clean', async () => {
  const combos = product(
    ['auto (dxmt)', 'auto (wined3d)', 'auto (auto)', 'wined3d', 'dxmt', 'd3dmetal', 'dxvk'],
    ['windows7', 'windows10', 'windows11', 'win7_64', 'win10_64', 'win11_64'],
    ['none', 'Steam 2171440', 'Epic Games fn2f3a', 'GOG 1207658924', 'Xbox 9NBLGGH4R315', 'Store 7'],
    ['none', 'fear-hunger-2-termina', 'steam (changed)', 'astroneer (own)', 'pokémon (own)', 'ファイナル-2 (own)'],
    ['recorded', 'last run', 'none'],
    ['0.3.0', 'not installed'],
    ['11.0-11', 'not found'],
    ['0.6.4', '0.1.0', 'development build'],
  );
  assert.ok(combos.length > 10000);
  for (const [graphics, windows, store, profile, log, runtime, wine, overpass] of combos) {
    const facts = game({ graphics, windows, store, profile, log, runtime, wine, overpass });
    const { broken, odd } = await check(relayed(facts, log === 'none' ? '_No log: sent without one._' : undefined), released);
    assert.deepStrictEqual([...broken, ...odd], [], JSON.stringify(facts));
  }
});

test('every app name passes', async () => {
  for (const app of ['Fear & Hunger 2: Termina', 'Notepad++', 'Foo (Demo)', 'checksum: nothing', 'ファイナルファンタジー', 'unknown', '🎮 Game'])
    assert.deepStrictEqual((await check(relayed(game({ app })), released)).odd, [], app);
});

test('crash reports pass, with or without a log', async () => {
  for (const log of ['crash report', 'none'])
    for (const overpass of ['0.6.4', 'development build', '?'])
      for (const line of ['EXC_BAD_ACCESS SIGSEGV at libswiftCore.dylib  0x1a2b', ' at ', 'at x: y'])
        assert.deepStrictEqual((await check(relayed(crash({ log, overpass, crash: line.trim() || 'at' }), log === 'none' ? '' : undefined), released)).odd, []);
});

test('the report that started this: Fear & Hunger 2, no Runtime', async () => {
  const { broken, odd, labels } = await check(relayed(game({
    app: 'Fear & Hunger 2: Termina', profile: 'fear-hunger-2-termina (own)', store: 'Steam 2171440', overpass: '0.6.1',
    runtime: 'not installed', graphics: 'auto (auto)',
  })), released);
  assert.deepStrictEqual([...broken, ...odd], []);
  assert.ok(labels.some(([n]) => n === 'graphics wined3d'));
  assert.ok(labels.some(([n]) => n === 'store steam'));
});

test('log links, on GitHub and through the relay', async () => {
  const links = [
    'https://reports.arctim.no/overpass/logs/654051b5-8bb7-4772-868a-084720b61770/OverPass%20Logs%20Foo%20(Demo)%20x.zip',
    `[Foo (Demo).zip](${zip})`,
    '[a.zip](https://github.com/user-attachments/files/123/a.zip)',
    '[a.zip](https://github.com/McKack/overpass/files/123/a.zip)',
  ];
  for (const link of links) assert.deepStrictEqual((await check(relayed(game(), link), released)).odd, [], link);
  assert.match((await check(relayed(game(), ''), released)).odd.join(), /zip/);
});

test('keys a newer OverPass adds are left alone', async () => {
  assert.deepStrictEqual((await check(relayed(game({ tweaks: 'hairworks off' })), released)).odd, []);
});

test('when GitHub can\'t answer, a version counts as fine but earns no label', async () => {
  const { odd, labels } = await check(relayed(game({ wine: '11.0-99' })), async () => null);
  assert.deepStrictEqual(odd, []);
  assert.ok(!labels.some(([n]) => n.startsWith('wine ')));
});

test('an unknown value earns no label: label names are capped at 50 characters', async () => {
  const { labels } = await check(relayed(game({ wine: 'x'.repeat(200), graphics: 'y'.repeat(200) })), released);
  assert.deepStrictEqual(labels, []);
  const { labels: long } = await check(relayed(game({ store: `${'z'.repeat(200)} 1` })), released);
  assert.ok(long.every(([n]) => n.length <= 50));
});

// A stand-in for the part of the GitHub API the check uses, recording every change.
function fake(issue, comments = []) {
  const calls = [];
  const note = name => async args => { calls.push([name, args]); return { data: {} }; };
  return {
    calls,
    github: {
      paginate: async () => comments,
      rest: {
        issues: {
          get: async () => ({ data: issue }), listComments: null,
          createComment: note('createComment'), updateComment: note('updateComment'), deleteComment: note('deleteComment'),
          update: note('update'), lock: note('lock'), addLabels: note('addLabels'), removeLabel: note('removeLabel'),
          createLabel: async ({ name }) => { if (name.length > 50) throw Object.assign(new Error('too long'), { status: 422 }); },
        },
        repos: { getReleaseByTag: async ({ tag }) => {
          if (tags.has(tag)) return {};
          throw Object.assign(new Error('Not Found'), { status: 404 });
        } },
      },
    },
    context: { repo: { owner: 'McKack', repo: 'overpass' }, payload: { issue: { number: 3 } } },
  };
}
const issue = (body, over = {}) => ({ body, state: 'open', labels: [{ name: 'report' }], user: { type: 'Bot' }, ...over });
const added = calls => calls.find(([n]) => n === 'addLabels')[1].labels;
const said = calls => calls.find(([n]) => n === 'createComment')?.[1].body;
const assertStaysOpen = calls => {
  assert.ok(!calls.some(([n, a]) => n === 'lock' || (n === 'update' && a.state === 'closed')), 'closed or locked');
};

test('a clean report gets labels and no comment', async () => {
  const f = fake(issue(relayed(game())));
  await run(f);
  assert.ok(added(f.calls).includes('graphics dxmt'));
  assert.ok(!added(f.calls).some(l => l === 'invalid' || l === 'unverified'));
  assert.strictEqual(said(f.calls), undefined);
});

test(`up to ${TOLERATED} oddities: unverified, still labelled, open`, async () => {
  const f = fake(issue(relayed(game({ wine: 'dev-local', runtime: '9.9.9', overpass: '9.9.9' }))));
  await run(f);
  assert.ok(added(f.calls).includes('unverified'));
  assert.ok(!added(f.calls).includes('invalid'));
  assert.ok(added(f.calls).includes('graphics dxmt'));
  assert.match(said(f.calls), /nothing more is needed/);
  assertStaysOpen(f.calls);
});

test('past the allowance: invalid, still open', async () => {
  const f = fake(issue(relayed(game({ wine: 'a', runtime: 'b', overpass: 'c', windows: 'd' }))));
  await run(f);
  assert.ok(added(f.calls).includes('invalid'));
  assertStaysOpen(f.calls);
});

test('a changed block or no block: invalid, still open', async () => {
  for (const body of [relayed(game()).replace('Astroneer', 'Tampered'), 'I just typed this.', '', null]) {
    const f = fake(issue(body));
    await run(f);
    assert.ok(added(f.calls).includes('invalid'), String(body));
    assertStaysOpen(f.calls);
  }
});

test('only an issue someone can edit is told to edit it', async () => {
  const relay = fake(issue('nothing', { user: { type: 'Bot' } }));
  await run(relay);
  assert.doesNotMatch(said(relay.calls), /Editing the issue/);
  const form = fake(issue('nothing', { user: { type: 'User' } }));
  await run(form);
  assert.match(said(form.calls), /Editing the issue/);
});

test('a report an earlier check closed reopens; one a person closed stays closed', async () => {
  const bot = fake(issue(relayed(game()), { state: 'closed', closed_by: { type: 'Bot' } }));
  await run(bot);
  assert.ok(bot.calls.some(([n, a]) => n === 'update' && a.state === 'open'));
  const person = fake(issue(relayed(game()), { state: 'closed', closed_by: { type: 'User' } }));
  await run(person);
  assert.ok(!person.calls.some(([n]) => n === 'update'));
});

test('a fixed report loses the mark and the comment', async () => {
  const old = { id: 9, user: { type: 'Bot' }, body: '<!-- overpass-report-check -->\nold' };
  const f = fake(issue(relayed(game()), { labels: [{ name: 'report' }, { name: 'invalid' }, { name: 'wine 11.0-2' }] }), [old]);
  await run(f);
  assert.ok(f.calls.some(([n, a]) => n === 'deleteComment' && a.comment_id === 9));
  const removed = f.calls.filter(([n]) => n === 'removeLabel').map(([, a]) => a.name).sort();
  assert.deepStrictEqual(removed, ['invalid', 'wine 11.0-2']);
});
