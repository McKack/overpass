// Fills the site with AreWeAntiCheatYet's list (areweanticheatyet.com, MIT): which anti-cheat a game uses, how that does
// on Linux, and its notes. A game the site doesn't have gets a page. Every run of sync-games.yml starts this; it asks the
// site when the list last came and only goes on after a month, so one missed run costs nothing.
import { pathToFileURL } from 'node:url';

const LIST = 'https://raw.githubusercontent.com/AreWeAntiCheatYet/AreWeAntiCheatYet/HEAD/games.json';
const MONTH = 30 * 24 * 3600 * 1000;
/// How many games go in one request: the site writes them in one batch.
const CHUNK = 200;

/// What the site keeps of a game. One with no anti-cheat named is no use here.
export function entry(game) {
  if (!game.slug || !game.name || !game.anticheats?.length) return null;
  const notes = (Array.isArray(game.notes) ? game.notes : [])
    .filter((note) => Array.isArray(note) && typeof note[0] === 'string' && note[0])
    .map(([text, url]) => [text.slice(0, 300), /^https:\/\//.test(url ?? '') ? url : '']).slice(0, 10);
  return {
    slug: game.slug, name: game.name.slice(0, 120), status: game.status ?? '', anticheats: game.anticheats.slice(0, 8), notes,
    steam: game.storeIds?.steam ?? null, epic: typeof game.storeIds?.epic === 'string' ? game.storeIds.epic : null,
    changed: game.dateChanged ?? null,
  };
}

export const chunks = (list, size = CHUNK) => Array.from({ length: Math.ceil(list.length / size) }, (_, i) => list.slice(i * size, (i + 1) * size));

export const isDue = (syncedAt, now = Date.now()) => !syncedAt || now - syncedAt >= MONTH;

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const site = (path, init = {}) => fetch(`${process.env.SITE}${path}`, {
    ...init, headers: { Authorization: `Bearer ${process.env.SYNC_TOKEN}`, 'Content-Type': 'application/json' },
  });
  const { synced_at: syncedAt } = await (await site('/api/anticheat')).json();
  if (!isDue(syncedAt)) process.exit(0);
  const answer = await fetch(LIST);
  if (!answer.ok) throw new Error(`The list: ${answer.status}`);
  const games = (await answer.json()).map(entry).filter(Boolean);
  // A broken download mustn't empty the site.
  if (games.length < 100) throw new Error(`Only ${games.length} games in the list`);
  const run = Date.now();
  for (const part of chunks(games)) {
    const sent = await site('/api/anticheat', { method: 'POST', body: JSON.stringify({ run, games: part }) });
    if (!sent.ok) throw new Error(`The site: ${sent.status} ${await sent.text()}`);
  }
  const done = await site('/api/anticheat', { method: 'POST', body: JSON.stringify({ run, done: true }) });
  if (!done.ok) throw new Error(`The site: ${done.status} ${await done.text()}`);
  console.log(`Anti-cheat: ${games.length} games`);
}
