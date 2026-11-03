// Keeps the [anti-cheat] section of the profiles in step with AreWeAntiCheatYet's list (areweanticheatyet.com, MIT): which
// anti-cheat a game uses, how that does on Linux, and its notes. A game with no profile gets one that holds just that, so
// profiles/ is where the app and the site read all of it. Runs at the start of sync-games.yml once a day; ANTICHEAT_NOW=1
// runs it any time. Writes changed=true to GITHUB_OUTPUT when profiles/ moved.
//
//   node .github/scripts/sync-anticheat.mjs [--no-commit]

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const { slug, sections } = createRequire(import.meta.url)('./games-index.js');

const LIST = 'https://raw.githubusercontent.com/AreWeAntiCheatYet/AreWeAntiCheatYet/HEAD/games.json';
const SECTION = /^\[anti-cheat\]\r?\n(?:(?!\[).*(?:\r?\n|$))*/m;
/// The hour of the day it runs at, UTC.
const HOUR = 4;

const line = (text) => String(text).replace(/\s+/g, ' ').trim();

/// What a profile keeps of a game. One with no anti-cheat named is no use here.
export function entry(game) {
  if (!game.slug || !game.name || !game.anticheats?.length) return null;
  const notes = (Array.isArray(game.notes) ? game.notes : [])
    .filter((note) => Array.isArray(note) && typeof note[0] === 'string' && note[0])
    .map(([text, url]) => [line(text).slice(0, 300), /^https:\/\/\S+$/.test(url ?? '') ? url : '']).slice(0, 10);
  return {
    slug: game.slug, name: line(game.name).slice(0, 120), status: game.status ?? '', anticheats: game.anticheats.slice(0, 8).map(line), notes,
    steam: /^\d{1,10}$/.test(game.storeIds?.steam ?? '') ? game.storeIds.steam : null,
    epic: /^[\w-]{1,64}$/.test(typeof game.storeIds?.epic === 'string' ? game.storeIds.epic : '') ? game.storeIds.epic : null,
    changed: line(game.dateChanged ?? ''),
  };
}

/// The [anti-cheat] section of a profile.
export function section(game) {
  const lines = [
    '[anti-cheat]', `game = ${game.name}`, ...game.anticheats.map((name) => `uses = ${name}`),
    ...(game.status ? [`status = ${game.status}`] : []), `page = ${game.slug}`, ...(game.changed ? [`changed = ${game.changed}`] : []),
    ...game.notes.map(([text, url]) => `note = ${text}${url ? ` | ${url}` : ''}`),
  ];
  return `${lines.join('\n')}\n`;
}

/// A new profile for a game that has only this.
function minimal(game) {
  const stores = [...(game.steam ? [`steam = ${game.steam}`] : []), ...(game.epic ? [`epic = ${game.epic}`] : [])];
  return `# What's known about this game's anti-cheat. sync-anticheat.mjs keeps [anti-cheat] up to date from AreWeAntiCheatYet (MIT).\n${
    stores.length ? `[store]\n${stores.join('\n')}\n\n` : ''}${section(game)}`;
}

/// Whether a profile holds nothing but what this script wrote.
function onlyAntiCheat(text) {
  return sections(text).every((part) => !part.name || ['store', 'anti-cheat'].includes(part.name)) && !/^\[store\][\s\S]*^link\s*=/m.test(text);
}

const storeID = (text, keys) => {
  for (const part of sections(text)) {
    for (const { key, value } of part.lines) if (keys.includes(key)) return value;
  }
  return null;
};

/// Brings the profiles in `root` in line with the list. An existing profile of the game keeps everything else it has.
export function writeProfiles(games, root) {
  const files = new Map(fs.readdirSync(root).filter((name) => name.endsWith('.ini')).map((name) => [name.slice(0, -4), fs.readFileSync(path.join(root, name), 'utf8')]));
  const bySteam = new Map(), byEpic = new Map();
  for (const [id, text] of files) {
    const steam = storeID(text, ['steam-app', 'steam']), epic = storeID(text, ['epic']);
    if (steam) bySteam.set(steam, id);
    if (epic) byEpic.set(epic, id);
  }
  const wanted = new Map();
  const name = (game) => slug(game.name).slice(0, 100).replace(/-+$/, '');
  for (const game of games) {
    const id = bySteam.get(game.steam) ?? byEpic.get(game.epic) ?? name(game);
    // The list has two games with one store ID now and then: the first keeps it, or two pages would be one game.
    if (wanted.has(id)) {
      if (name(game) && !wanted.has(name(game))) wanted.set(name(game), { ...game, steam: null, epic: null });
    } else if (id) {
      wanted.set(id, game);
      if (game.steam) bySteam.set(game.steam, id);
      if (game.epic) byEpic.set(game.epic, id);
    }
  }
  for (const [id, game] of wanted) {
    const before = files.get(id);
    const text = before === undefined ? minimal(game) : SECTION.test(before) ? before.replace(SECTION, section(game))
      : `${before.trimEnd()}\n\n${section(game)}`;
    if (text !== before) fs.writeFileSync(path.join(root, `${id}.ini`), text);
  }
  for (const [id, text] of files) {
    if (wanted.has(id) || !SECTION.test(text)) continue;
    if (onlyAntiCheat(text)) fs.rmSync(path.join(root, `${id}.ini`));
    else fs.writeFileSync(path.join(root, `${id}.ini`), `${text.replace(SECTION, '').trimEnd()}\n`);
  }
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (new Date().getUTCHours() !== HOUR && !process.env.ANTICHEAT_NOW) process.exit(0);
  const answer = await fetch(LIST);
  if (!answer.ok) throw new Error(`The list: ${answer.status}`);
  const games = (await answer.json()).map(entry).filter(Boolean);
  // A broken download mustn't empty the profiles.
  if (games.length < 100) throw new Error(`Only ${games.length} games in the list`);
  writeProfiles(games, 'profiles');
  const git = (...args) => execFileSync('git', args, { encoding: 'utf8' }).trim();
  if (process.argv.includes('--no-commit') || !git('status', '--porcelain', 'profiles')) process.exit(0);
  git('config', 'user.name', 'arctim-janitor[bot]');
  git('config', 'user.email', 'arctim-janitor[bot]@users.noreply.github.com');
  git('add', 'profiles');
  git('commit', '-m', 'Profiles: anti-cheat list from AreWeAntiCheatYet');
  git('pull', '--rebase', 'origin', 'main');
  git('push', 'origin', 'HEAD:main');
  if (process.env.GITHUB_OUTPUT) fs.appendFileSync(process.env.GITHUB_OUTPUT, 'changed=true\n');
  console.log(`Anti-cheat: ${games.length} games`);
}
