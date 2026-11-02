import assert from 'node:assert/strict';
import { test } from 'node:test';
import { chunks, entry, isDue } from './sync-anticheat.mjs';

const game = {
  slug: 'halo', name: 'Halo', status: 'Supported', anticheats: ['Easy Anti-Cheat'], storeIds: { steam: '976730' },
  notes: [['Works', 'https://example.com/a'], ['No link', ''], ['Bad link', 'javascript:alert(1)'], ['', 'https://example.com/b'], 'odd'],
};

test('keeps what the site shows', () => {
  const kept = entry(game);
  assert.equal(kept.steam, '976730');
  assert.deepEqual(kept.notes, [['Works', 'https://example.com/a'], ['No link', ''], ['Bad link', '']]);
});

test('notes may be missing', () => assert.deepEqual(entry({ ...game, notes: '' }).notes, []));

test('a game without an anti-cheat or a slug is left out', () => {
  assert.equal(entry({ ...game, anticheats: [] }), null);
  assert.equal(entry({ ...game, slug: '' }), null);
});

test('a month between runs', () => {
  assert.equal(isDue(null), true);
  assert.equal(isDue(1000, 1000 + 29 * 864e5), false);
  assert.equal(isDue(1000, 1000 + 30 * 864e5), true);
});

test('chunks keep everything', () => {
  assert.deepEqual(chunks([1, 2, 3], 2), [[1, 2], [3]]);
  assert.deepEqual(chunks([], 2), []);
});
