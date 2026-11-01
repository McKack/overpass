const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { slug, profile, presetGames, buildIndex } = require('./games-index.js');

test('a page address drops marks and punctuation', () => {
  assert.strictEqual(slug('The Sims™ 4'), 'the-sims-4');
  assert.strictEqual(slug("Baldur's Gate 3"), 'baldurs-gate-3');
  assert.strictEqual(slug('God of War Ragnarök'), 'god-of-war-ragnarok');
  assert.strictEqual(slug('ゲーム'), '');
});

test('a profile takes its name and ids from [app]', () => {
  const game = profile('demo', '[app]\nname = Demo\ncategory = Games\nrating = gold\nsteam-app = 5\ngog-game = 6\npreset = a\n');
  assert.deepStrictEqual([game.name, game.verified, game.steam, game.gog, game.presets], ['Demo', 'gold', '5', '6', ['a']]);
  assert.deepStrictEqual(game.keys, [['profile', 'demo'], ['steam', '5'], ['gog', '6']]);
});

test('a rules-only profile is named after its first rule', () => {
  const game = profile('ac', '# why\n[ARMORED CORE VI: skip the starter]\nsteam-app = 1888160\n');
  assert.deepStrictEqual([game.name, game.steam, game.verified], ['ARMORED CORE VI', '1888160', null]);
});

test('a preset names games in the comment above their line, not in the explanations', () => {
  const text = [
    '# Preset x: does something.', '[Preset: x]', '# Satisfactory (reported on Highball: does not start)', 'steam-app = 526870',
    '# Age of Empires II (2013)', 'steam-app = 221380', 'steam-app = 999', '# This line explains the next rule.', 'program = a.exe',
  ].join('\n');
  assert.deepStrictEqual(presetGames('x.ini', text).map((game) => [game.name, game.steam]),
    [['Satisfactory', '526870'], ['Age of Empires II (2013)', '221380']]);
});

test('a game in a preset joins the profile with its Steam ID, and two presets share one page', () => {
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'games-'));
  fs.mkdirSync(path.join(folder, 'Presets'));
  fs.writeFileSync(path.join(folder, 'demo.ini'), '[app]\nname = Demo\nsteam-app = 5\n');
  fs.writeFileSync(path.join(folder, 'chromium-programs.ini'), '[Chromium]\nprogram = a.exe\n');
  fs.writeFileSync(path.join(folder, 'Presets', 'a.ini'), '# Demo Deluxe\nsteam-app = 5\n# Other\nsteam-app = 7\n');
  fs.writeFileSync(path.join(folder, 'Presets', 'b.ini'), '# Other\nsteam-app = 7\n');
  const { games } = buildIndex(folder);
  assert.deepStrictEqual(games.map((game) => [game.id, game.source, game.presets]),
    [['demo', 'profile', ['a']], ['other', 'preset', ['a', 'b']]]);
  fs.rmSync(folder, { recursive: true });
});

test('the real profiles build, with unique ids and keys', () => {
  const { games } = buildIndex(path.join(__dirname, '..', '..', 'profiles'));
  assert.ok(games.length > 100);
  assert.strictEqual(new Set(games.map((game) => game.id)).size, games.length);
  const keys = games.flatMap((game) => game.keys.map((key) => key.join(':')));
  assert.strictEqual(new Set(keys).size, keys.length);
});
