// Checks what OverPass sends in: a game's report (Report Issue… on a title), OverPass's own crash (the window offered
// at the next start, whose details carry `crash:`), and the Help menu's report on OverPass and feature request (`kind:
// general`, `kind: feature`), and a profile sent with Submit Profile… (`kind: profile`). Run by .github/workflows/check-report.yml; test with `node --test .github/scripts/`.
//
// A report is never closed or locked: a person wrote it, and most reports come through the report relay, whose
// sender has no GitHub account to edit or reopen anything with. What the check finds only labels it:
//   - all recognised:            `report` and labels from its details
//   - up to TOLERATED oddities:  the same, plus `unverified` and a comment listing them
//   - more, or no intact block:  `invalid` and the comment (fixing the issue clears both)
// The checksum only shows the block wasn't edited by hand: OverPass is open source, so it can't prove a report came
// from the app.
const crypto = require('crypto');

const TOLERATED = 3;
const MARKER = '<!-- overpass-report-check -->';

// What each kind of report carries, and the log kinds it can have. Keys not listed here are left alone, so a newer
// OverPass can add facts without tripping an older check.
const KINDS = {
  game: { keys: ['app', 'profile', 'store', 'overpass', 'wine', 'runtime', 'graphics', 'windows', 'macos', 'mac', 'log'],
          logs: ['recorded', 'last run', 'none'] },
  crash: { keys: ['app', 'overpass', 'macos', 'crash', 'log'], logs: ['crash report', 'none'] },
  general: { keys: ['app', 'overpass', 'wine', 'runtime', 'macos', 'mac', 'log'], logs: ['none'] },
  // A request, not a problem report: it gets `feature` instead of `report`.
  feature: { keys: ['app', 'overpass', 'macos', 'log'], logs: ['none'], label: ['feature', 'a2eeef'] },
  // A profile to review, also not a problem report: it gets `profile`, and has passed a test run on the sender's Mac.
  profile: { keys: ['test', 'app', 'profile', 'store', 'overpass', 'wine', 'runtime', 'graphics', 'windows', 'macos', 'mac', 'log'],
             logs: ['none'], label: ['profile', '5319e7'] },
};
const BACKENDS = 'wined3d|dxmt|d3dmetal|dxvk';
// OverPass up to 0.6.4 writes `auto (auto)` when the Runtime isn't installed: Automatic then means Wine's own.
const GRAPHICS = new RegExp(`^(?:auto \\((${BACKENDS}|auto)\\)|(${BACKENDS}))$`);
// Profile IDs keep any letter or digit (a game's name can be in any script). "(changed)" and "(own)" are the app's.
const PROFILE = /^(none|[\p{L}\p{N}][\p{L}\p{N}._-]*( \((changed|own)\))?)$/u;
// "<store name> <the store's ID for the game>".
const STORE = /^(none|([\p{L}\p{N}][\p{L}\p{N} .&'-]*) \S+)$/u;
const WINDOWS = /^(windows(7|10|11)|win(7|10|11)_64)$/;
// The zip is attached on GitHub, or kept by the report relay (services/report-relay), which links it. A name can
// hold parentheses, and the relay's links left them unescaped up to 0.6.4.
const ATTACHED = /https:\/\/github\.com\/(user-attachments\/files|[\w.-]+\/[\w.-]+\/files)\/\d+\/\S+\.zip/;
const RELAYED = /https:\/\/reports\.arctim\.no\/[\w-]+\/logs\/[0-9a-f-]{36}\/\S+\.zip/;

const shown = s => '`' + String(s).replace(/[`@\n]/g, '').slice(0, 80) + '`';

/// Reads an issue's body. `released(repository, tag)` answers true, false, or null when GitHub couldn't say.
/// Returns what's wrong (`broken`: no intact block; `odd`: everything else) and the labels the details give.
async function check(rawBody, released) {
  const body = (rawBody || '').replace(/\r\n/g, '\n');
  const broken = [], odd = [], facts = {}, labels = [];
  let kind = KINDS.game;

  // The block: "overpass-report: 1", "key: value" lines, then "checksum: <16 hex>" over the lines before it.
  const lines = body.split('\n').map(l => l.trim());
  const start = lines.indexOf('overpass-report: 1');
  const end = start < 0 ? -1 : lines.findIndex((l, i) => i > start && l.startsWith('checksum: '));
  if (start < 0 || end < 0) {
    broken.push('The details block is missing or cut short, so this report says nothing about the setup it came from.');
    return { kind, broken, odd, labels };
  }
  const block = lines.slice(start, end);
  for (const line of block.slice(1)) {
    const m = line.match(/^([a-z]+): (.+)$/);
    if (m) facts[m[1]] = m[2]; else odd.push(`A line in the details isn't understood: ${shown(line)}.`);
  }
  const sum = crypto.createHash('sha256').update(block.join('\n')).digest('hex').slice(0, 16);
  if (lines[end] !== `checksum: ${sum}`) broken.push("The details were changed after OverPass wrote them (the checksum doesn't match).");
  if ('crash' in facts) kind = KINDS.crash;
  else if (Object.hasOwn(KINDS, facts.kind)) kind = KINDS[facts.kind];
  for (const key of kind.keys) if (!(key in facts)) odd.push(`The details lack ${shown(key)}.`);

  // Values the app writes when there's nothing to name are facts too, not oddities.
  const given = (key, ...plain) => key in facts && !['unknown', '?', ...plain].includes(facts[key]);

  if (given('overpass', 'development build')) {
    const known = await released('overpass', `v${facts.overpass}`) ?? true;
    if (!known && !(await released('overpass-releases', `v${facts.overpass}`) ?? true))
      odd.push(`OverPass ${shown(facts.overpass)} isn't a released version.`);
  }
  if (given('wine', 'not found')) {
    const known = await released('overpass-wine', `overpass-wine-${facts.wine}`);
    if (known === false) odd.push(`OverPass Wine ${shown(facts.wine)} isn't a released version.`);
    if (known) labels.push([`wine ${facts.wine}`, '7e57c2']);
  }
  if (given('runtime', 'not installed') && (await released('overpass-runtime', `v${facts.runtime}`)) === false)
    odd.push(`OverPass Runtime ${shown(facts.runtime)} isn't a released version.`);

  const graphics = (facts.graphics || '').match(GRAPHICS);
  if (given('graphics') && !graphics) odd.push(`The graphics ${shown(facts.graphics)} aren't one OverPass has.`);
  if (graphics) {
    const backend = graphics[2] || graphics[1];
    labels.push([`graphics ${backend === 'auto' ? 'wined3d' : backend}`, '1d76db']);
  }
  if (given('windows') && !WINDOWS.test(facts.windows)) odd.push(`The Windows version ${shown(facts.windows)} isn't one OverPass has.`);
  if (given('profile') && !PROFILE.test(facts.profile)) odd.push(`The profile ${shown(facts.profile)} isn't a profile ID.`);
  const store = (facts.store || '').match(STORE);
  if (given('store') && !store) odd.push(`The store ${shown(facts.store)} isn't understood.`);
  if (store && store[2] && store[2] !== 'Store') labels.push([`store ${store[2].toLowerCase()}`.slice(0, 50), '0e8a16']);
  if (given('log') && !kind.logs.includes(facts.log)) odd.push(`The log kind ${shown(facts.log)} isn't understood.`);
  // A report sent without a log says "log: none" and has no zip.
  if (facts.log !== 'none' && !ATTACHED.test(body) && !RELAYED.test(body)) odd.push('The log zip isn\'t attached.');

  if (kind === KINDS.profile) {
    if (given('test') && !/^ran \d+ s$/.test(facts.test)) odd.push(`The test result ${shown(facts.test)} isn't understood.`);
    if (!/^### Profile\n\n(`{3,})ini\n[\s\S]*?\n\1$/m.test(body)) odd.push("The profile's text is missing.");
    if (!/^### Screenshot$/m.test(body)) odd.push("The test run's screenshot is missing.");
  }

  if (kind === KINDS.crash) labels.push(['app crash', 'b60205']);
  if (kind === KINDS.general) labels.push(['app issue', 'b60205']);
  return { kind, broken, odd, labels };
}

/// The check's comment, or null when there's nothing to say. Only someone with a GitHub account can edit an issue;
/// the relay files issues itself.
function comment(broken, odd, editable) {
  const problems = [...broken, ...odd];
  if (!problems.length) return null;
  const list = problems.map(p => `- ${p}`).join('\n');
  if (!broken.length && odd.length <= TOLERATED)
    return `${MARKER}\nSome details of this report weren't recognised, so it's marked \`unverified\`. It stays open and nothing more is needed:\n\n${list}`;
  return `${MARKER}\nThis report is marked \`invalid\` for now, but it stays open:\n\n${list}` +
    (editable ? '\n\nEditing the issue to fix this clears the mark. Report Issue… in OverPass fills the details in for you.' : '');
}

/// The workflow's step: checks the issue the event is about and labels it. Reopens one an earlier check closed.
async function run({ github, context }) {
  const owner = context.repo.owner, repo = context.repo.repo;
  const number = context.payload.issue.number;
  const issue = (await github.rest.issues.get({ owner, repo, issue_number: number })).data;

  async function released(repository, tag) {
    try { await github.rest.repos.getReleaseByTag({ owner, repo: repository, tag }); return true; }
    catch (e) { return e.status === 404 ? false : null; }
  }
  const { kind, broken, odd, labels } = await check(issue.body, released);

  const text = comment(broken, odd, issue.user?.type !== 'Bot');
  const comments = await github.paginate(github.rest.issues.listComments, { owner, repo, issue_number: number });
  const mine = comments.find(c => c.user.type === 'Bot' && c.body.includes(MARKER));
  if (text && mine) await github.rest.issues.updateComment({ owner, repo, comment_id: mine.id, body: text });
  else if (text) await github.rest.issues.createComment({ owner, repo, issue_number: number, body: text });
  else if (mine) await github.rest.issues.deleteComment({ owner, repo, comment_id: mine.id });

  if (issue.state === 'closed' && issue.closed_by?.type === 'Bot')
    await github.rest.issues.update({ owner, repo, issue_number: number, state: 'open' });

  const wanted = [kind.label || ['report', 'd73a4a'], ...labels];
  if (broken.length || odd.length > TOLERATED) wanted.push(['invalid', 'e4e669']);
  else if (odd.length) wanted.push(['unverified', 'fbca04']);
  for (const [name, color] of wanted) {
    try { await github.rest.issues.createLabel({ owner, repo, name, color }); }
    catch (e) { if (e.status !== 422) throw e; }
  }
  // Earlier details may have named another Wine or backend, or been wrong.
  const stale = issue.labels.map(l => l.name)
    .filter(l => /^(wine|graphics|store) |^(report|invalid|unverified)$/.test(l) && !wanted.some(([n]) => n === l));
  for (const name of stale) await github.rest.issues.removeLabel({ owner, repo, issue_number: number, name });
  await github.rest.issues.addLabels({ owner, repo, issue_number: number, labels: wanted.map(([n]) => n) });
}

module.exports = { check, comment, run, TOLERATED };
