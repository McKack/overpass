import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { apply, profileFiles, signedSet } from './publish-profiles.mjs';

function folder() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'profiles-'));
  fs.mkdirSync(path.join(root, 'Presets'));
  fs.writeFileSync(path.join(root, 'old.ini'), '[app]\nname = Old\n[install]\ndownload = https://example.com/a.exe\n');
  fs.writeFileSync(path.join(root, 'Presets', 'one.ini'), '[One]\ngraphics = dxmt\n');
  fs.writeFileSync(path.join(root, 'README.md'), 'not a profile');
  return root;
}

test('a good suggestion is written, a bad one left alone and refused', () => {
  const root = folder();
  const old = fs.readFileSync(path.join(root, 'old.ini'), 'utf8');
  const result = apply([
    { id: 'a', profile_id: 'new-game', body: '[Rule]\nprogram = g.exe\ngraphics = dxmt' },
    { id: 'b', profile_id: 'old', body: '[app]\nname = Old\n[install]\ndownload = https://evil.example/a.exe' },
    { id: 'c', profile_id: '../../outside', body: '[Rule]\nprogram = g.exe' },
  ], root);
  assert.deepEqual(result, { published: ['a'], refused: ['b', 'c'] });
  assert.equal(fs.readFileSync(path.join(root, 'new-game.ini'), 'utf8'), '[Rule]\nprogram = g.exe\ngraphics = dxmt\n');
  assert.equal(fs.readFileSync(path.join(root, 'old.ini'), 'utf8'), old);
  assert.ok(!fs.existsSync(path.join(root, '..', '..', 'outside.ini')));
});

test('a suggestion keeps the lines a file already has', () => {
  const root = folder();
  const body = '[app]\nname = Old\n[install]\ndownload = https://example.com/a.exe\n[Rule]\nprogram = g.exe\n';
  assert.deepEqual(apply([{ id: 'a', profile_id: 'old', body }], root), { published: ['a'], refused: [] });
});

test('the set holds profiles and presets only', () => {
  assert.deepEqual(Object.keys(profileFiles(folder())), ['old.ini', 'Presets/one.ini']);
});

test('the signature covers the exact text, and only that', () => {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
  const { payload, signature } = JSON.parse(signedSet(5, 'abc', { 'a.ini': 'x' }, privateKey));
  assert.equal(JSON.parse(payload).serial, 5);
  assert.ok(crypto.verify(null, Buffer.from(payload), publicKey, Buffer.from(signature, 'base64')));
  assert.ok(!crypto.verify(null, Buffer.from(payload.replace('"x"', '"y"')), publicKey, Buffer.from(signature, 'base64')));
});
