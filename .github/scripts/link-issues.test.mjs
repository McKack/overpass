import assert from 'node:assert/strict';
import { test } from 'node:test';
import { allIssues, parseIssue } from './link-issues.mjs';

const body = (lines) => `### What happened\n\nHello\n\n### Details\n\n\`\`\`text\noverpass-report: 1\n${lines}\nchecksum: ab\n\`\`\`\n`;
const issue = { number: 5, title: 'Deus Ex GOTY: Test', html_url: 'https://x/5', state: 'open' };

test('the report block names the game', () => {
  const parsed = parseIssue({ ...issue, body: body('app: Deus Ex GOTY\nprofile: none\nstore: GOG 1207658995') });
  assert.deepEqual([parsed.app, parsed.store, parsed.profile, parsed.state], ['Deus Ex GOTY', 'GOG 1207658995', 'none', 'open']);
});

test('a hand-written issue has only its title', () => {
  const parsed = parseIssue({ ...issue, body: 'It broke' });
  assert.equal(parsed.app, undefined);
  assert.equal(parsed.named, 'Deus Ex GOTY');
  assert.equal(parseIssue({ ...issue, title: 'Sound crackles', body: null }).named, null);
});

test('closed says how', () => {
  assert.equal(parseIssue({ ...issue, state: 'closed', state_reason: 'completed' }).state, 'fixed');
  assert.equal(parseIssue({ ...issue, state: 'closed', state_reason: 'not_planned' }).state, 'closed');
});

test('every page is read, pull requests left out', async () => {
  const pages = [Array.from({ length: 100 }, (_, number) => ({ number })), [{ number: 100 }, { number: 101, pull_request: {} }]];
  const get = async () => ({ ok: true, json: async () => pages.shift() });
  assert.equal((await allIssues('a/b', 't', get)).length, 101);
});
