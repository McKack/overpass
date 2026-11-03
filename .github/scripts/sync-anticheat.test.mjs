import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { entry, section, writeProfiles } from './sync-anticheat.mjs';

const game = {
  slug: 'halo', name: 'Halo', status: 'Supported', anticheats: ['Easy Anti-Cheat'], storeIds: { steam: '976730' }, dateChanged: '2024-01-02',
  notes: [['Works', 'https://example.com/a'], ['No link', ''], ['Bad link', 'javascript:alert(1)'], ['', 'https://example.com/b'], 'odd'],
};

const folder = (files) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'anticheat-'));
  for (const [name, text] of Object.entries(files)) fs.writeFileSync(path.join(root, name), text);
  return root;
};
const read = (root, name) => fs.readFileSync(path.join(root, name), 'utf8');

test('keeps what a profile holds', () => {
  const kept = entry(game);
  assert.equal(kept.steam, '976730');
  assert.deepEqual(kept.notes, [['Works', 'https://example.com/a'], ['No link', ''], ['Bad link', '']]);
});

test('notes may be missing', () => assert.deepEqual(entry({ ...game, notes: '' }).notes, []));

test('a game without an anti-cheat or a slug is left out', () => {
  assert.equal(entry({ ...game, anticheats: [] }), null);
  assert.equal(entry({ ...game, slug: '' }), null);
});

test('a line break in a note can\'t start a new setting', () => {
  const text = section(entry({ ...game, notes: [['One\n[app]\nname = x', '']] }));
  assert.ok(text.includes('note = One [app] name = x\n'));
});

test('a game with no profile gets one with just this', () => {
  const root = folder({});
  writeProfiles([entry(game)], root);
  const text = read(root, 'halo.ini');
  assert.ok(text.includes('[store]\nsteam = 976730\n'));
  assert.ok(text.includes('[anti-cheat]\ngame = Halo\nuses = Easy Anti-Cheat\nstatus = Supported\npage = halo\nchanged = 2024-01-02\nnote = Works | https://example.com/a\n'));
});

test('a profile of the game gets the section under another name, and keeps the rest', () => {
  const root = folder({ 'master-chief.ini': '[app]\nname = MCC\nsteam-app = 976730\n\n[launch]\nprogram = a.exe\n' });
  writeProfiles([entry(game)], root);
  assert.equal(fs.readdirSync(root).length, 1);
  const text = read(root, 'master-chief.ini');
  assert.ok(text.startsWith('[app]\nname = MCC\nsteam-app = 976730\n\n[launch]\nprogram = a.exe\n\n[anti-cheat]\n'));
});

test('a second run with the same list changes nothing, and a new status replaces the section', () => {
  const root = folder({ 'halo.ini': '[app]\nname = Halo\nsteam-app = 976730\n\n[launch]\nprogram = a.exe\n' });
  writeProfiles([entry(game)], root);
  const once = read(root, 'halo.ini');
  writeProfiles([entry(game)], root);
  assert.equal(read(root, 'halo.ini'), once);
  writeProfiles([entry({ ...game, status: 'Broken', notes: [] })], root);
  const text = read(root, 'halo.ini');
  assert.ok(text.includes('status = Broken') && !text.includes('note =') && text.includes('[launch]'));
  assert.equal(text.match(/\[anti-cheat\]/g).length, 1);
});

test('a section in the middle of a file comes out clean', () => {
  const root = folder({ 'halo.ini': '[app]\nname = Halo\nsteam-app = 976730\n\n[anti-cheat]\nuses = Old\n\n[launch]\nprogram = a.exe\n' });
  writeProfiles([entry(game)], root);
  const text = read(root, 'halo.ini');
  assert.ok(!text.includes('Old') && text.includes('[launch]\nprogram = a.exe'));
});

test('a game off the list loses the section, and a profile that held only that goes', () => {
  const root = folder({ 'gone.ini': '[store]\nsteam = 1\n\n[anti-cheat]\ngame = Gone\n', 'kept.ini': '[app]\nname = Kept\n\n[anti-cheat]\ngame = Kept\n', 'other.ini': '[app]\nname = Other\n' });
  writeProfiles([entry(game)], root);
  assert.deepEqual(fs.readdirSync(root).sort(), ['halo.ini', 'kept.ini', 'other.ini']);
  assert.equal(read(root, 'kept.ini'), '[app]\nname = Kept\n');
});

test('two games with one store ID both stay, and only the first keeps it', () => {
  const root = folder({});
  writeProfiles([entry(game), entry({ ...game, slug: 'other', name: 'Other' })], root);
  assert.ok(read(root, 'halo.ini').includes('steam = 976730'));
  assert.ok(!read(root, 'other.ini').includes('steam') && read(root, 'other.ini').includes('game = Other'));
});
