import test from 'node:test';
import assert from 'node:assert/strict';
import { candidates, run, sameName, waiting } from './find-covers.mjs';

const answer = (body, status = 200) => new Response(typeof body === 'string' ? body : JSON.stringify(body), { status });

/// A web where only the addresses given exist; the first key found in a URL answers.
const web = (pages) => async (url) => {
  const key = Object.keys(pages).find((part) => String(url).includes(part));
  return key ? answer(pages[key]) : answer('', 404);
};

const STEAM_ITEM = (file) => ({ response: { store_items: [{ assets: { asset_url_format: 'steam/apps/1/${FILENAME}?t=2', library_capsule_2x: file } }] } });

test('names match past marks and punctuation, not past extra words', () => {
  assert.ok(sameName("Baldur's Gate™ 3", 'Baldurs Gate 3'));
  assert.ok(!sameName('Outcast', 'Outcast - Second Contact'));
});

test('only games that need a cover are waiting', () => {
  const now = 10 * 24 * 3600 * 1000;
  const game = { category: 'Games', checked_at: 0 };
  assert.equal(waiting([game], now).length, 1);
  assert.equal(waiting([{ ...game, checked_at: now - 1000 }], now).length, 0);
  assert.equal(waiting([{ ...game, file: 'a.avif' }], now).length, 0);
  assert.equal(waiting([{ ...game, brand: '112233' }], now).length, 0);
  assert.equal(waiting([{ ...game, category: 'Utilities' }], now).length, 0);
  assert.equal(waiting([{ ...game, locked: 1 }], now).length, 0);
  assert.equal(waiting([{ ...game, locked: 1, wanted: 'https://x' }], now).length, 1);
  assert.equal(waiting([{ category: null }], now).length, 1);
});

test('a Steam ID leads to Steam art from the current path', async () => {
  const { found, links } = await candidates({ name: 'A', steam: '1' }, { get: web({ GetItems: STEAM_ITEM('hash/library_2x.jpg') }) });
  assert.equal(found[0].source, 'steam');
  assert.equal(found[0].url, 'https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/1/hash/library_2x.jpg?t=2');
  assert.deepEqual(links, ['https://store.steampowered.com/app/1']);
});

test('a near name on Steam is no match, GOG\'s exact one is', async () => {
  const get = web({
    storesearch: { items: [{ id: 5, name: 'Outcast Tales' }] },
    'catalog.gog.com': { products: [{ title: 'Outcast', coverVertical: 'https://gog/cover.jpg', storeLink: 'https://www.gog.com/en/game/outcast' }] },
  });
  const { found, links } = await candidates({ name: 'Outcast' }, { get });
  assert.deepEqual(found, [{ source: 'gog', url: 'https://gog/cover.jpg' }]);
  assert.deepEqual(links, ['https://www.gog.com/en/game/outcast']);
});

test('TheGamesDB and SteamGridDB come last, and only with a key', async () => {
  const tgdb = {
    'thegamesdb.net': {
      data: { games: [{ id: 53, game_title: 'Old Game' }] },
      include: { boxart: { base_url: { original: 'https://tgdb/' }, data: { 53: [{ side: 'back', filename: 'b.jpg' }, { side: 'front', filename: 'f.jpg' }] } } },
    },
  };
  assert.deepEqual((await candidates({ name: 'Old Game' }, { get: web(tgdb) })).found, []);
  assert.deepEqual((await candidates({ name: 'Old Game' }, { get: web(tgdb), tgdb: 'k' })).found, [{ source: 'thegamesdb', url: 'https://tgdb/f.jpg' }]);
  const sgdb = {
    'autocomplete/Old': { data: [{ id: 9, name: 'Old Game' }] },
    'grids/game/9': { data: [{ url: 'https://sgdb/g.png' }] },
  };
  assert.deepEqual((await candidates({ name: 'Old Game' }, { get: web(sgdb), sgdb: 'k' })).found, [{ source: 'steamgriddb', url: 'https://sgdb/g.png' }]);
});

test('a moderator\'s image wins, and a failed one is reported', async () => {
  const sent = [];
  const get = async (url, options) => {
    if (options?.method === 'POST') { sent.push(JSON.parse(options.body)); return answer({}); }
    if (String(url).endsWith('/api/art')) return answer({ games: [{ id: 'a', name: 'A', wanted: 'https://art/a.png' }, { id: 'b', name: 'B', wanted: 'https://art/gone.png' }] });
    return String(url).endsWith('a.png') ? answer('picture') : answer('', 404);
  };
  await run({ site: 'https://site', token: 't', get, shrink: async () => Buffer.from('small'), log: () => {} });
  assert.deepEqual(sent.map(({ id, source, failed }) => [id, source, failed]), [['a', 'moderator', undefined], ['b', undefined, true]]);
  assert.equal(sent[0].image, Buffer.from('small').toString('base64'));
});

test('a picture that won\'t decode moves on to nothing rather than stopping', async () => {
  const sent = [];
  const get = async (url, options) => {
    if (options?.method === 'POST') { sent.push(JSON.parse(options.body)); return answer({}); }
    if (String(url).endsWith('/api/art')) return answer({ games: [{ id: 'a', name: 'A', steam: '1', category: 'Games' }] });
    if (String(url).includes('GetItems')) return answer(STEAM_ITEM('x.jpg'));
    return answer('not a picture');
  };
  await run({ site: 'https://site', token: 't', get, shrink: async () => { throw new Error('bad'); }, log: () => {} });
  assert.equal(sent[0].failed, true);
});
