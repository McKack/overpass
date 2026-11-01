import test from 'node:test';
import assert from 'node:assert/strict';
import { plainText, due, findArt, run, sameName, tgdbShare } from './find-covers.mjs';

const answer = (body, status = 200, type = 'application/json') => new Response(typeof body === 'string' ? body : JSON.stringify(body), { status, headers: { 'Content-Type': type } });

/// A web where only the addresses given exist; the first key found in a URL answers.
const web = (pages) => async (url) => {
  const key = Object.keys(pages).find((part) => String(url).includes(part));
  return key ? answer(pages[key]) : answer('', 404);
};

const STEAM_ITEM = (file) => ({ response: { store_items: [{ assets: { asset_url_format: 'steam/apps/1/${FILENAME}?t=2', library_capsule_2x: file, library_capsule: 'small.jpg', library_hero: 'hero.jpg', community_icon: 'abc' } }] } });

test('names match past marks and punctuation, not past extra words', () => {
  assert.ok(sameName("Baldur's Gate™ 3", 'Baldurs Gate 3'));
  assert.ok(!sameName('Outcast', 'Outcast - Second Contact'));
});

test('the queue goes first, then those missing art, a month after their last look', () => {
  const month = 30 * 24 * 3600 * 1000, now = 2 * month;
  const looked = { category: 'Games', checked_at: 1000 };
  const complete = { cover: 'c', hero: 'h', icon: 'i', about: 'a' };
  assert.deepEqual(due([{ ...looked, ...complete }], now), []);
  assert.equal(due([{ ...looked, cover: 'c', hero: 'h' }], now).length, 1);
  assert.deepEqual(due([{ ...looked, checked_at: now - 1000 }], now), []);
  const many = Array.from({ length: 1500 }, (_, index) => ({ id: `g${index}`, ...looked, checked_at: 2000 - index }));
  assert.deepEqual(due(many, now).map((game) => game.id), ['g1499', 'g1498']);
  const queued = Array.from({ length: 30 }, (_, index) => ({ id: `n${index}`, category: null, checked_at: 0, ...complete }));
  assert.equal(due(queued, now).length, 20);
  assert.deepEqual(due([{ id: 'a', category: 'Games', brand: '112233' }, { id: 'b', category: 'Utilities' }], now), []);
  const wanted = { id: 'c', category: 'Utilities', wanted: 'https://x', ...looked };
  assert.deepEqual(due([{ ...wanted, category: 'Utilities', checked_at: now }], now).map((game) => game.id), ['c']);
});

test('TheGamesDB\'s allowance is shared out over the runs left', async () => {
  const limit = (left, timer) => web({ 'API/Limit': { remaining_monthly_allowance: left, extra_allowance: 0, allowance_refresh_timer: timer } });
  assert.equal(await tgdbShare(limit(2880, 2592000), 'k', 0), 1);
  assert.equal(await tgdbShare(limit(1000, 2592000), 'k', 0), 0);
  assert.equal(await tgdbShare(limit(1000, 2592000), 'k', 0.9), 1);
  assert.equal(await tgdbShare(limit(0, 1800), 'k', 0.9), 0);
  assert.equal(await tgdbShare(limit(9999, null), 'k', 0), 5);
  assert.equal(await tgdbShare(web({}), 'k', 0.9), 0);
});

test('a Steam ID leads to all of Steam\'s art', async () => {
  const { art, links } = await findArt({ name: 'A', steam: '1' }, { get: web({ GetItems: STEAM_ITEM('hash/library_2x.jpg') }) });
  const base = 'https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/1/';
  assert.deepEqual(art, {
    source: 'steam', thumb: `${base}small.jpg?t=2`, cover: `${base}hash/library_2x.jpg?t=2`, hero: `${base}hero.jpg?t=2`,
    icon: 'https://cdn.akamai.steamstatic.com/steamcommunity/public/images/apps/1/abc.jpg',
  });
  assert.deepEqual(links, ['https://store.steampowered.com/app/1']);
});

test('a near name on Steam is no match, GOG\'s exact one is', async () => {
  const get = web({
    storesearch: { items: [{ id: 5, name: 'Outcast Tales' }] },
    'catalog.gog.com': { products: [{ id: '7', title: 'Outcast', coverVertical: 'https://gog/cover.jpg', storeLink: 'https://www.gog.com/en/game/outcast' }] },
    'external_releases/7': { game: { background: { url_format: 'https://gog/bg{formatter}.{ext}' }, square_icon: { url_format: 'https://gog/i{formatter}.{ext}' } } },
  });
  const { art, links } = await findArt({ name: 'Outcast' }, { get });
  assert.deepEqual(art, { source: 'gog', cover: 'https://gog/cover.jpg', thumb: undefined, hero: 'https://gog/bg.jpg', icon: 'https://gog/i.png' });
  assert.deepEqual(links, ['https://www.gog.com/en/game/outcast']);
});

test('GOG\'s square icon beats Steam\'s tiny one', async () => {
  const get = web({ GetItems: STEAM_ITEM('x.jpg'), 'external_releases/7': { game: { square_icon: { url_format: 'https://gog/i{formatter}.{ext}' } } } });
  const { art } = await findArt({ steam: '1', gog: '7' }, { get });
  assert.equal(art.source, 'steam');
  assert.equal(art.icon, 'https://gog/i.png');
});

test('a title that only has an ID, from the app, is still looked up', async () => {
  const { art } = await findArt({ steam: '1' }, { get: web({ GetItems: STEAM_ITEM('x.jpg') }) });
  assert.equal(art.source, 'steam');
});

test('TheGamesDB and SteamGridDB come last, and only with a key and a share', async () => {
  const tgdb = {
    'Games/ByGameName': {
      data: { games: [{ id: 53, game_title: 'Old Game' }] },
      include: { boxart: { base_url: { original: 'https://tgdb/', medium: 'https://tgdb/m/' }, data: { 53: [{ side: 'back', filename: 'b.jpg' }, { side: 'front', filename: 'f.jpg' }] } } },
    },
    'Games/Images': { data: { base_url: { original: 'https://tgdb/' }, images: { 53: [{ filename: 'fan.jpg' }] } } },
  };
  assert.deepEqual((await findArt({ name: 'Old Game' }, { get: web(tgdb) })).art, {});
  assert.deepEqual((await findArt({ name: 'Old Game' }, { get: web(tgdb), tgdb: { key: 'k', share: 0 } })).art, {});
  const allowance = { key: 'k', share: 1 };
  const { art } = await findArt({ name: 'Old Game' }, { get: web(tgdb), tgdb: allowance });
  assert.deepEqual(art, { source: 'thegamesdb', thumb: 'https://tgdb/m/f.jpg', cover: 'https://tgdb/f.jpg', hero: 'https://tgdb/fan.jpg' });
  assert.equal(allowance.share, 0);
  const sgdb = {
    'autocomplete/Old': { data: [{ id: 9, name: 'Old Game' }] },
    'grids/game/9': { data: [{ url: 'https://sgdb/g.png' }] },
  };
  assert.equal((await findArt({ name: 'Old Game' }, { get: web(sgdb), sgdb: 'k' })).art.cover, 'https://sgdb/g.png');
});

test('a moderator\'s image wins if it is one, and either way the wait ends', async () => {
  const sent = [];
  const get = async (url, options) => {
    if (options?.method === 'POST') { sent.push(JSON.parse(options.body)); return answer({}); }
    if (String(url).endsWith('/api/art')) return answer({ games: [{ id: 'a', name: 'A', wanted: 'https://art/a.png' }, { id: 'b', name: 'B', wanted: 'https://art/page.html' }] });
    if (String(url).endsWith('a.png')) return answer('picture', 200, 'image/png');
    return answer('', 404);
  };
  await run({ site: 'https://site', token: 't', get, log: () => {} });
  assert.deepEqual(sent.map(({ id, source, cover }) => [id, source, cover]), [['a', 'moderator', 'https://art/a.png'], ['b', undefined, undefined]]);
});

test('a store description comes out as plain text', () => {
  assert.equal(plainText('<a href="x"><img src="y"></a>\n\n<i>A truly &amp; good</i> game.<br>It&#39;s fun.'), "A truly & good game.\nIt's fun.");
  assert.equal(plainText(undefined), undefined);
  assert.equal(plainText('<img src="y">'), undefined);
  const long = plainText(`${'Word word word. '.repeat(100)}`);
  assert.ok(long.length <= 700 && long.endsWith('.'));
});
