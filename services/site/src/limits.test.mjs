import test from 'node:test';
import assert from 'node:assert/strict';
import { isWriteLimit, nextReset } from './index.js';

test('a daily write limit error pauses writes', () => {
  assert.ok(isWriteLimit(new Error('D1_ERROR: Exceeded daily row write limit')));
  assert.ok(isWriteLimit(new Error('You have exceeded the daily D1 free tier limit of 100,000 rows written')));
});

test('other errors do not', () => {
  assert.ok(!isWriteLimit(new Error('D1_ERROR: no such column: colour')));
  assert.ok(!isWriteLimit(new Error('D1_ERROR: Exceeded maximum DB size')));
  assert.ok(!isWriteLimit(new Error('UNIQUE constraint failed: games.id')));
  assert.ok(!isWriteLimit(undefined));
});

test('writes come back at the next 00:00 UTC', () => {
  assert.equal(nextReset(Date.UTC(2026, 10, 3, 18, 30)), Date.UTC(2026, 10, 4));
  assert.equal(nextReset(Date.UTC(2026, 10, 30, 23, 59)), Date.UTC(2026, 11, 1));
  assert.equal(nextReset(Date.UTC(2026, 11, 31, 0, 0)), Date.UTC(2027, 0, 1));
});
