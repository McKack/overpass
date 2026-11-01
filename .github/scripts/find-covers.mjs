// Finds each game's cover and shrinks it for the site, which keeps and serves it (services/site/src/index.js). Run by
// sync-games.yml. A cover comes from the first of these that has one: Steam by the game's ID, Steam by the exact name,
// GOG by ID, GOG by the exact name, TheGamesDB (TGDB_KEY), SteamGridDB (SGDB_KEY). Only an exact name counts: a near
// match puts the wrong game's cover on a page. A moderator's image goes first and stays. Store pages found on the way
// go on the game's page.
//
//   SITE=... SYNC_TOKEN=... node find-covers.mjs            does up to LIMIT games
//   SITE=... SYNC_TOKEN=... node find-covers.mjs --waiting  exits 0 when there's work, 1 when there's none

import { pathToFileURL } from 'node:url';

const LIMIT = 200;
const RETRY = 7 * 24 * 3600 * 1000;
const STEAM_ART = 'https://shared.akamai.steamstatic.com/store_item_assets/';
const SGDB = 'https://www.steamgriddb.com/api/v2';
/// TheGamesDB's platform number for PC.
const TGDB_PC = 1;

/// A name reduced to what two stores would agree on.
export function sameName(a, b) {
  const plain = (name) => name.replace(/[™®©]/g, '').normalize('NFKD').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, '');
  return plain(a) === plain(b);
}

/// The games to look at now: a moderator's image, or no cover yet and not looked for lately. Launchers and programs
/// that aren't games keep their tiles.
export function waiting(games, now = Date.now()) {
  return games.filter((game) => game.wanted
    || (!game.locked && !game.file && !game.brand && [null, 'Games'].includes(game.category) && now - (game.checked_at ?? 0) > RETRY));
}

async function json(get, url, headers) {
  const response = await get(url, { headers }).catch(() => null);
  return response?.ok ? response.json().catch(() => null) : null;
}

async function steamCover(get, id) {
  const input = { ids: [{ appid: Number(id) }], context: { language: 'english', country_code: 'US', steam_realm: 1 }, data_request: { include_assets: true } };
  const answer = await json(get, `https://api.steampowered.com/IStoreBrowseService/GetItems/v1?input_json=${encodeURIComponent(JSON.stringify(input))}`);
  const assets = answer?.response?.store_items?.[0]?.assets;
  const file = assets?.library_capsule_2x ?? assets?.library_capsule;
  return file ? STEAM_ART + assets.asset_url_format.replace('${FILENAME}', file) : null;
}

async function steamMatch(get, name) {
  const answer = await json(get, `https://store.steampowered.com/api/storesearch/?term=${encodeURIComponent(name)}&l=english&cc=US`);
  return answer?.items?.find((item) => sameName(item.name, name))?.id ?? null;
}

async function gogMatch(get, name) {
  const answer = await json(get, `https://catalog.gog.com/v1/catalog?limit=10&query=${encodeURIComponent(`like:${name}`)}&productType=in:game`);
  return answer?.products?.find((product) => sameName(product.title, name)) ?? null;
}

async function gogCover(get, id) {
  const answer = await json(get, `https://gamesdb.gog.com/platforms/gog/external_releases/${id}`);
  return answer?.game?.vertical_cover?.url_format?.replace('{formatter}', '').replace('{ext}', 'jpg') ?? null;
}

async function tgdbCover(get, name, key) {
  const query = new URLSearchParams({ apikey: key, name, include: 'boxart', 'filter[platform]': TGDB_PC });
  const answer = await json(get, `https://api.thegamesdb.net/v1.1/Games/ByGameName?${query}`);
  const game = answer?.data?.games?.find((entry) => sameName(entry.game_title, name));
  const boxart = answer?.include?.boxart;
  const front = boxart?.data?.[game?.id]?.find((image) => image.side === 'front');
  return front ? boxart.base_url.original + front.filename : null;
}

async function sgdbCover(get, game, steam, key) {
  const headers = { Authorization: `Bearer ${key}` };
  const grids = (path) => json(get, `${SGDB}/grids/${path}?dimensions=600x900&types=static&nsfw=false&humor=false`, headers);
  let answer = steam ? await grids(`steam/${steam}`) : null;
  if (!answer?.data?.length) {
    const found = await json(get, `${SGDB}/search/autocomplete/${encodeURIComponent(game.name)}`, headers);
    const match = found?.data?.find((entry) => sameName(entry.name, game.name));
    if (match) answer = await grids(`game/${match.id}`);
  }
  return answer?.data?.[0]?.url ?? null;
}

/// Addresses of images for a game, best first as { source, url }, and the store pages found.
export async function candidates(game, { get = fetch, tgdb, sgdb } = {}) {
  const found = [];
  const add = async (source, url) => { const address = await url; if (address) found.push({ source, url: address }); };
  const steam = game.steam ?? await steamMatch(get, game.name);
  const gog = await gogMatch(get, game.name);
  if (game.wanted) found.push({ source: 'moderator', url: game.wanted });
  else {
    if (steam) await add('steam', steamCover(get, steam));
    if (!found.length && game.gog) await add('gog', gogCover(get, game.gog));
    if (!found.length && gog?.coverVertical) await add('gog', gog.coverVertical);
    if (!found.length && tgdb) await add('thegamesdb', tgdbCover(get, game.name, tgdb));
    if (!found.length && sgdb) await add('steamgriddb', sgdbCover(get, game, steam, sgdb));
  }
  const links = [...(steam ? [`https://store.steampowered.com/app/${steam}`] : []), ...(gog?.storeLink ? [gog.storeLink] : [])];
  return { found, links };
}

/// The first candidate that downloads and shrinks.
async function firstImage(found, { get, shrink }) {
  for (const { source, url } of found) {
    const response = await get(url).catch(() => null);
    if (!response?.ok) continue;
    const image = await shrink(Buffer.from(await response.arrayBuffer())).catch(() => null);
    if (image) return { source, origin: url, image: image.toString('base64') };
  }
  return null;
}

export async function run({ site, token, get = fetch, shrink, tgdb, sgdb, log = console.log }) {
  const headers = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
  const answer = await get(`${site}/api/art`, { headers });
  if (!answer.ok) throw new Error(`GET /api/art: ${answer.status}`);
  const { games } = await answer.json();
  for (const game of waiting(games).slice(0, LIMIT)) {
    const { found, links } = await candidates(game, { get, tgdb, sgdb });
    const image = await firstImage(found, { get, shrink });
    const posted = await get(`${site}/api/art`, { method: 'POST', headers, body: JSON.stringify({ id: game.id, links, ...(image ?? { failed: true }) }) });
    log(`${game.id}: ${image ? image.source : 'nothing'} ${posted.ok ? '' : `(the site said ${posted.status})`}`);
  }
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const site = process.env.SITE, token = process.env.SYNC_TOKEN;
  if (process.argv.includes('--waiting')) {
    const answer = await fetch(`${site}/api/art`, { headers: { Authorization: `Bearer ${token}` } });
    if (!answer.ok) throw new Error(`GET /api/art: ${answer.status}`);
    process.exit(waiting((await answer.json()).games).length ? 0 : 1);
  }
  const { default: sharp } = await import('sharp');
  const shrink = (bytes) => sharp(bytes).resize(400, 600, { fit: 'cover' }).avif({ quality: 50, effort: 6 }).toBuffer();
  await run({ site, token, shrink, tgdb: process.env.TGDB_KEY, sgdb: process.env.SGDB_KEY });
}
