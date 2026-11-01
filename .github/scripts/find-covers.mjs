// Finds the addresses of each game's art for the site, which keeps the addresses and links to the pictures where they
// are. Run by sync-games.yml every half hour. Each kind of art comes from the first of these that has it: Steam by the
// game's ID, Steam by the exact name, GOG by ID, GOG by the exact name, TheGamesDB (TGDB_KEY), and for a cover
// SteamGridDB (SGDB_KEY). Only an exact name counts: a near match puts the wrong game's art on a page. A moderator's
// image goes first and stays. Store pages found on the way go on the game's page.
//
// Art a game already has stays. A game missing a cover, hero or icon is looked at again once a month, the longest
// unchecked first, spread out over the runs. The queue goes ahead of that, up to NEW_A_RUN at a time: titles the app has
// just asked about and anything else not checked yet. TheGamesDB's monthly allowance is shared out the same way.
//
//   SITE=... SYNC_TOKEN=... node find-covers.mjs

import { pathToFileURL } from 'node:url';

const RUN_SECONDS = 1800;
const MONTH_SECONDS = 30 * 24 * 3600;
const RUNS_A_MONTH = MONTH_SECONDS / RUN_SECONDS;
const NEW_A_RUN = 20;
/// The most games TheGamesDB is asked about in a run, whatever is left of the allowance.
const TGDB_A_RUN = 5;
const STEAM_ART = 'https://shared.akamai.steamstatic.com/store_item_assets/';
const STEAM_ICONS = 'https://cdn.akamai.steamstatic.com/steamcommunity/public/images/apps/';
const SGDB = 'https://www.steamgriddb.com/api/v2';
const ABOUT_LENGTH = 700;
/// TheGamesDB's platform number for PC.
const TGDB_PC = 1;

/// A name reduced to what two stores would agree on.
export function sameName(a, b) {
  const plain = (name) => name.replace(/[™®©]/g, '').normalize('NFKD').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, '');
  return plain(a) === plain(b);
}

/// The games to look at now: a moderator's image, the queue, and this run's share of those still missing art. Launchers
/// and programs that aren't games keep their tiles.
export function due(games, now = Date.now()) {
  const turns = games.filter((game) => !game.brand && [null, undefined, 'Games'].includes(game.category));
  const fresh = turns.filter((game) => !game.checked_at).slice(0, NEW_A_RUN);
  const missing = turns.filter((game) => game.checked_at && !(game.cover && game.hero && game.icon && game.about));
  const ready = missing.filter((game) => now - game.checked_at >= MONTH_SECONDS * 1000).sort((a, b) => a.checked_at - b.checked_at);
  const picked = [...fresh, ...ready.slice(0, Math.ceil(missing.length / RUNS_A_MONTH))];
  return [...games.filter((game) => game.wanted && !picked.includes(game)), ...picked];
}

/// A store's description as plain text, at most `ABOUT_LENGTH` characters and ending on a sentence where it can. Stores
/// write HTML and paste banners into it.
export function plainText(text) {
  if (typeof text !== 'string') return undefined;
  const words = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ' };
  const plain = text.replace(/<(script|style)[\s\S]*?<\/\1>/gi, ' ').replace(/<br\s*\/?>|<\/p>|<\/li>/gi, '\n').replace(/<[^>]*>/g, ' ')
    .replace(/&(?:#(\d+)|#x([0-9a-f]+)|(\w+));/gi, (all, number, hex, name) => {
      if (name) return words[name.toLowerCase()] ?? all;
      return String.fromCodePoint(number ? Number(number) : parseInt(hex, 16));
    })
    .replace(/[ \t]+/g, ' ').replace(/ ?\n ?/g, '\n').replace(/\n{2,}/g, '\n\n').trim();
  if (plain.length <= ABOUT_LENGTH) return plain || undefined;
  const cut = plain.slice(0, ABOUT_LENGTH);
  const stop = Math.max(cut.lastIndexOf('. '), cut.lastIndexOf('.\n'), cut.lastIndexOf('! '), cut.lastIndexOf('? '));
  return stop > ABOUT_LENGTH / 2 ? cut.slice(0, stop + 1) : `${cut.slice(0, cut.lastIndexOf(' '))}…`;
}

async function json(get, url, headers) {
  const response = await get(url, { headers }).catch(() => null);
  return response?.ok ? response.json().catch(() => null) : null;
}

async function steamArt(get, id) {
  const input = { ids: [{ appid: Number(id) }], context: { language: 'english', country_code: 'US', steam_realm: 1 }, data_request: { include_assets: true, include_basic_info: true } };
  const answer = await json(get, `https://api.steampowered.com/IStoreBrowseService/GetItems/v1?input_json=${encodeURIComponent(JSON.stringify(input))}`);
  const item = answer?.response?.store_items?.[0];
  const about = plainText(item?.basic_info?.short_description);
  const assets = item?.assets;
  if (!assets?.asset_url_format) return { about };
  const address = (file) => file ? STEAM_ART + assets.asset_url_format.replace('${FILENAME}', file) : undefined;
  return {
    cover: address(assets.library_capsule_2x ?? assets.library_capsule),
    thumb: address(assets.library_capsule),
    hero: address(assets.library_hero),
    icon: assets.community_icon ? `${STEAM_ICONS}${id}/${assets.community_icon}.jpg` : undefined,
    about,
  };
}

async function steamMatch(get, name) {
  const answer = await json(get, `https://store.steampowered.com/api/storesearch/?term=${encodeURIComponent(name)}&l=english&cc=US`);
  return answer?.items?.find((item) => sameName(item.name, name))?.id ?? null;
}

async function gogMatch(get, name) {
  const answer = await json(get, `https://catalog.gog.com/v1/catalog?limit=10&query=${encodeURIComponent(`like:${name}`)}&productType=in:game`);
  return answer?.products?.find((product) => sameName(product.title, name)) ?? null;
}

async function gogArt(get, id) {
  const game = (await json(get, `https://gamesdb.gog.com/platforms/gog/external_releases/${id}`))?.game;
  const address = (art, extension) => art?.url_format?.replace('{formatter}', '').replace('{ext}', extension);
  return {
    cover: address(game?.vertical_cover, 'jpg'), hero: address(game?.background, 'jpg'), icon: address(game?.square_icon, 'png'),
    about: plainText(game?.summary?.['en-US'] ?? game?.summary?.['*']),
  };
}

/// How many games TheGamesDB can be asked about in this run, so what's left of the allowance lasts until it refills. A
/// share under one becomes one now and then. Each game takes two requests. Asking this doesn't count against it.
export async function tgdbShare(get, key, chance = Math.random()) {
  const limit = await json(get, `https://api.thegamesdb.net/v1/API/Limit?apikey=${encodeURIComponent(key)}`);
  if (!limit) return 0;
  if (limit.allowance_refresh_timer == null) return TGDB_A_RUN;
  const left = (limit.remaining_monthly_allowance ?? 0) + (limit.extra_allowance ?? 0);
  return Math.min(TGDB_A_RUN, Math.floor(left / 2 / Math.max(1, limit.allowance_refresh_timer / RUN_SECONDS) + chance));
}

async function tgdbArt(get, name, key) {
  const query = new URLSearchParams({ apikey: key, name, include: 'boxart', fields: 'overview', 'filter[platform]': TGDB_PC });
  const answer = await json(get, `https://api.thegamesdb.net/v1.1/Games/ByGameName?${query}`);
  const game = answer?.data?.games?.find((entry) => sameName(entry.game_title, name));
  if (!game) return {};
  const boxart = answer.include?.boxart;
  const front = boxart?.data?.[game.id]?.find((image) => image.side === 'front');
  const images = new URLSearchParams({ apikey: key, games_id: game.id, 'filter[type]': 'fanart' });
  const fanart = (await json(get, `https://api.thegamesdb.net/v1/Games/Images?${images}`))?.data;
  const hero = fanart?.images?.[game.id]?.[0];
  return {
    cover: front && boxart.base_url.original + front.filename,
    thumb: front && boxart.base_url.medium + front.filename,
    hero: hero && fanart.base_url.original + hero.filename,
    about: plainText(game.overview),
  };
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

/// The addresses of a game's art, the source of its cover, and the store pages found. `tgdb` is { key, share }, and uses up
/// the share.
export async function findArt(game, { get = fetch, tgdb, sgdb } = {}) {
  const art = {};
  const fill = (source, found) => {
    if (found.cover && !art.cover) { art.source = source; art.thumb = found.thumb; }
    for (const kind of ['cover', 'hero', 'icon']) if (found[kind]) art[kind] ??= found[kind];
    if (found.about && !art.about) Object.assign(art, { about: found.about, about_source: source });
  };
  const steam = game.steam ?? (game.name ? await steamMatch(get, game.name) : null);
  const gog = game.name ? await gogMatch(get, game.name) : null;
  if (steam) fill('steam', await steamArt(get, steam));
  const release = game.gog ?? gog?.id;
  if (release) {
    const found = await gogArt(get, release);
    fill('gog', found);
    // Steam's icons are only 32 px.
    if (found.icon) art.icon = found.icon;
  }
  if (gog?.coverVertical) fill('gog', { cover: gog.coverVertical });
  if ((!art.cover || !art.hero) && tgdb?.share > 0) {
    tgdb.share -= 1;
    fill('thegamesdb', await tgdbArt(get, game.name, tgdb.key));
  }
  if (!art.cover && sgdb) fill('steamgriddb', { cover: await sgdbCover(get, game, steam, sgdb) });
  const links = [...(steam ? [`https://store.steampowered.com/app/${steam}`] : []), ...(gog?.storeLink ? [gog.storeLink] : [])];
  return { art, links };
}

async function isImage(get, url) {
  const response = await get(url).catch(() => null);
  return Boolean(response?.ok && response.headers.get('Content-Type')?.startsWith('image/'));
}

export async function run({ site, token, get = fetch, tgdb, sgdb, log = console.log }) {
  const headers = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
  const answer = await get(`${site}/api/art`, { headers });
  if (!answer.ok) throw new Error(`GET /api/art: ${answer.status}`);
  const { games } = await answer.json();
  const allowance = tgdb ? { key: tgdb, share: await tgdbShare(get, tgdb) } : null;
  for (const game of due(games)) {
    const { art, links } = await findArt(game, { get, tgdb: allowance, sgdb });
    if (game.wanted && await isImage(get, game.wanted)) Object.assign(art, { source: 'moderator', cover: game.wanted, thumb: undefined });
    const posted = await get(`${site}/api/art`, { method: 'POST', headers, body: JSON.stringify({ id: game.id, links, ...art }) });
    log(`${game.id}: ${art.source ?? 'nothing'} ${posted.ok ? '' : `(the site said ${posted.status})`}`);
  }
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  await run({ site: process.env.SITE, token: process.env.SYNC_TOKEN, tgdb: process.env.TGDB_KEY, sgdb: process.env.SGDB_KEY });
}
