// overpass.arctim.no: the static site in ../../site, plus the game pages and their JSON from the games database
// (schema.sql). Ratings arrive through the report relay; the list of games comes from profiles/ by way of
// sync-games.yml.
//
//   GET  /games, /games/<id>     the pages
//   GET  /api/games              every game with its overall tier
//   GET  /api/games/<id>         one game with its ratings
//   GET  /api/recent             the games rated last
//   POST /api/sync               { games } from .github/scripts/games-index.js; needs the SYNC_TOKEN secret
//   GET  /auth/google, /auth/google/callback   sign-in with Google (GOOGLE_CLIENT_ID, secret GOOGLE_CLIENT_SECRET)
//   GET  /account                the signed-in person's page
//   POST /account, /account/delete, /auth/signout   change the name, delete the account, sign out
//   POST /account/picture, /account/picture/delete   set or remove one's picture; GET /pictures/<key>.jpg
//   POST /games/<id>/comments, /games/<id>/comments/<comment>/delete   add a comment, delete one's own
//   POST /games/<id>/(comments|ratings)/<entry>/report   report one; three people reporting it hides it
//   GET  /moderation, POST /moderation/(comments|ratings)/<entry>/(hide|show)   for the accounts in MODERATORS
//   POST /games/<id>/ratings, /games/<id>/ratings/delete   the same accounts rate a game on its page, or take that back
//   POST /moderation/pictures/<key>/remove       the same accounts take a person's picture down
//   POST /moderation/suggestions/<entry>/(approve|reject)   the same accounts decide on a suggested profile
//   GET  /api/art                what find-covers.mjs needs for each game; needs the SYNC_TOKEN secret
//   POST /api/art                { id, links, source, cover, thumb, icon, hero } from the same script; the same secret
//   GET  /api/art/<store>/<id>?name=   the art the app shows; a title not seen before joins the queue for find-covers.mjs
//   POST /games/<id>/cover, /games/<id>/cover/url, /games/<id>/cover/reset   a moderator changes a game's cover
//   GET  /pictures/covers/<file>  a moderator's upload
//   GET  /api/profiles           the signed set of profiles the app downloads
//   POST /api/profiles           { serial, body } from publish-profiles.mjs; needs the SYNC_TOKEN secret
//   GET  /api/suggestions        the approved suggestions, for publish-profiles.mjs; needs the SYNC_TOKEN secret
//   POST /api/suggestions        { published, refused }: lists of their IDs, from the same script; the same secret
//   GET  /privacy                what's kept, and for how long
//
// An account holds the provider's ID for the person, the username they choose and a picture if they add one, nothing
// else: no e-mail, no name from Google. A session is a random token in a cookie; the database keeps only its hash.
// Pictures are small JPEGs, cropped and shrunk in the browser, in the PICTURES store.
//
// This site can't change what people's Macs get. Approve marks a suggested profile and nothing more: a GitHub workflow
// reads the approved ones, checks them itself, commits them to profiles/ and signs the whole set with a key that's only
// on GitHub (publish-profiles.mjs). The set is stored here for downloading; the app checks its signature.

import { profileProblems, storeName } from './profile-check.js';

const TIERS = ['platinum', 'gold', 'silver', 'bronze', 'borked'];
const TITLES = { platinum: 'Platinum', gold: 'Gold', silver: 'Silver', bronze: 'Bronze', borked: 'Borked' };
const REPOSITORY = 'https://github.com/McKack/overpass';

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, '') || '/';
    try {
      if (path === '/api/sync' && request.method === 'POST') return await sync(request, env);
      if (path === '/api/profiles' && request.method === 'POST') return await storeProfiles(request, env);
      if (path === '/api/suggestions' && request.method === 'POST') return await settleSuggestions(request, env);
      if (path === '/api/art' && request.method === 'POST') return await storeArt(request, env);
      const commented = path.match(/^\/games\/([a-z0-9-]+)\/comments(?:\/([0-9a-f-]+)\/delete)?$/);
      const reported = path.match(/^\/games\/([a-z0-9-]+)\/(comments|ratings)\/([0-9a-f-]+)\/report$/);
      const moderated = path.match(/^\/moderation\/(comments|ratings)\/([0-9a-f-]+)\/(hide|show)$/);
      const rated = path.match(/^\/games\/([a-z0-9-]+)\/ratings(\/delete)?$/);
      const unpictured = path.match(/^\/moderation\/pictures\/([0-9a-f-]+)\/remove$/);
      const decided = path.match(/^\/moderation\/suggestions\/([0-9a-f-]+)\/(approve|reject)$/);
      const covered = path.match(/^\/games\/([a-z0-9-]+)\/cover(?:\/(url|reset))?$/);
      if (request.method === 'POST' && (commented || reported || moderated || rated || unpictured || decided || covered
        || ['/account', '/account/delete', '/account/picture', '/account/picture/delete', '/auth/signout'].includes(path))) {
        // Only this site's own forms.
        if (request.headers.get('Origin') !== url.origin) return html(failedPage(), 403);
        if (path === '/auth/signout') return await signOut(request, env);
        const user = await signedIn(request, env);
        if (!user) return redirect('/account');
        if (reported) return await report(env, user, ...reported.slice(1));
        if (moderated) return isModerator(env, user) ? await review(env, ...moderated.slice(1)) : redirect('/account');
        if (unpictured) return isModerator(env, user) ? await takeDownPicture(env, unpictured[1]) : redirect('/account');
        if (decided) return isModerator(env, user) ? await decide(env, ...decided.slice(1)) : redirect('/account');
        if (covered) return isModerator(env, user) ? await changeCover(request, env, covered[1], covered[2]) : redirect('/account');
        if (rated) {
          if (!isModerator(env, user)) return redirect('/account');
          return rated[2] ? await deleteOwnRating(env, user, rated[1]) : await addOwnRating(request, env, user, rated[1]);
        }
        if (commented) {
          return commented[2] ? await deleteComment(env, user, commented[1], commented[2]) : await addComment(request, env, user, commented[1]);
        }
        if (path === '/account/picture') return await savePicture(request, env, user);
        if (path === '/account/picture/delete') return await deletePicture(env, user);
        return path === '/account' ? await rename(request, env, user) : await deleteAccount(env, user);
      }
      if (request.method === 'GET' || request.method === 'HEAD') {
        const picture = path.match(/^\/pictures\/([0-9a-f-]+)\.jpg$/);
        if (picture) return await servePicture(env, picture[1]);
        const art = path.match(/^\/pictures\/covers\/([0-9a-f]{32}\.(?:avif|jpg))$/);
        if (art) return await serveCover(request, env, art[1]);
        if (path === '/auth/google') return await startGoogle(url, env);
        if (path === '/auth/google/callback') return await finishGoogle(request, url, env);
        if (path === '/account') {
          const user = await signedIn(request, env);
          return personal(accountPage(user, url.searchParams.get('error'), isModerator(env, user)));
        }
        if (path === '/moderation') {
          const user = await signedIn(request, env);
          return isModerator(env, user) ? personal(moderationPage(await queue(env), await suggestions(env))) : redirect('/account');
        }
        if (path === '/privacy') {
          const moderator = isModerator(env, await signedIn(request, env));
          return (moderator ? personal : html)(privacyPage(moderator));
        }
        if (path === '/api/recent') return json(await recent(env));
        if (path === '/api/profiles') return await serveProfiles(env);
        if (path === '/api/suggestions') return await approvedSuggestions(request, env);
        if (path === '/api/art') return await artList(request, env);
        const asked = path.match(/^\/api\/art\/(steam|gog|epic)\/([A-Za-z0-9-]{1,64})$/);
        if (asked) return await artFor(env, url, asked[1], asked[2]);
        if (path === '/api/games') return json(await list(env));
        const api = path.match(/^\/api\/games\/([a-z0-9-]+)$/);
        if (api) {
          const game = await detail(env, api[1]);
          return game ? json(game) : json({ error: 'No such game.' }, 404);
        }
        if (path === '/games') {
          const moderator = isModerator(env, await signedIn(request, env));
          return (moderator ? personal : html)(gamesPage(await list(env), moderator));
        }
        const page = path.match(/^\/games\/([a-z0-9-]+)$/);
        if (page) {
          const game = await detail(env, page[1]);
          if (!game) return html(missingPage(), 404);
          const user = await signedIn(request, env);
          const moderator = isModerator(env, user);
          const own = moderator ? await ownRating(env, user, game.id) : null;
          return personal(gamePage(game, await comments(env, game.id, user), user, await reportedBy(env, user), url.searchParams.get('error'), moderator, own));
        }
      }
      return env.ASSETS.fetch(request);
    } catch (error) {
      console.error(error);
      return path.startsWith('/api/') ? json({ error: 'The games database failed.' }, 500) : html(failedPage(), 500);
    }
  },
};

// Data

/// The tier half of a game's ratings reach: a few bad ratings don't sink a Platinum game, or the other way around.
export function overall(counts) {
  const total = TIERS.reduce((sum, tier) => sum + (counts[tier] || 0), 0);
  if (!total) return null;
  let seen = 0;
  for (const tier of TIERS) {
    seen += counts[tier] || 0;
    if (seen * 2 >= total) return tier;
  }
  return null;
}

async function tally(env, where = '', ...values) {
  const { results } = await env.DB.prepare(
    `SELECT game_id, tier, COUNT(*) AS n, MAX(created_at) AS last FROM ratings WHERE hidden = 0 ${where} GROUP BY game_id, tier`,
  ).bind(...values).all();
  const games = new Map();
  for (const row of results) {
    const game = games.get(row.game_id) ?? { counts: {}, last: 0 };
    game.counts[row.tier] = row.n;
    game.last = Math.max(game.last, row.last);
    games.set(row.game_id, game);
  }
  return games;
}

/// A game's store pages, one for each store: a profile's own, then the ones found for it.
function storeLinks(game) {
  const links = [...(game.steam ? [`https://store.steampowered.com/app/${game.steam}`] : []), ...JSON.parse(game.links ?? '[]'), ...JSON.parse(game.found ?? '[]')];
  const stores = new Map();
  for (const url of links) {
    const name = storeName(url);
    if (name && !stores.has(name)) stores.set(name, url);
  }
  return [...stores].map(([name, url]) => ({ name, url }));
}

function summary(game, rated) {
  const counts = rated?.counts ?? {};
  return {
    id: game.id, name: game.name, category: game.category, source: game.source, steam: game.steam, verified: game.verified,
    tier: overall(counts), counts, ratings: Object.values(counts).reduce((sum, n) => sum + n, 0), last_rated: rated?.last ?? null,
    art: picture(game), brand: game.brand ?? null, stores: storeLinks(game),
  };
}

/// A moderator's upload from here, or the address of the smallest cover the source has.
function picture(game) {
  return game.art ? `/pictures/covers/${game.art}` : game.thumb ?? game.origin ?? null;
}

async function list(env) {
  const [{ results }, rated] = await Promise.all([
    env.DB.prepare(
      `SELECT g.id, g.name, g.category, g.source, g.steam, g.verified, g.links, g.brand, a.file AS art, a.thumb, a.origin, a.links AS found
       FROM games g LEFT JOIN game_art a ON a.game_id = g.id`,
    ).all(),
    tally(env),
  ]);
  return results.map((game) => summary(game, rated.get(game.id)))
    .sort((a, b) => (b.last_rated ?? 0) - (a.last_rated ?? 0) || a.name.localeCompare(b.name));
}

async function recent(env) {
  return (await list(env)).filter((game) => game.last_rated).slice(0, 8).map((game) => ({ ...game, cover: cover(game) }));
}

async function detail(env, id) {
  const game = await env.DB.prepare(
    `SELECT g.*, a.file AS art, a.thumb, a.origin, a.hero, a.links AS found, a.source AS art_source, a.wanted AS art_wanted
     FROM games g LEFT JOIN game_art a ON a.game_id = g.id WHERE g.id = ?`,
  ).bind(id).first();
  if (!game) return null;
  const [rated, { results }] = await Promise.all([
    tally(env, 'AND game_id = ?', id),
    env.DB.prepare(
      `SELECT id, tier, comment, chip, macos, overpass, wine, runtime, backend, fps, created_at, install LIKE 'account:%' AS admin FROM ratings
       WHERE game_id = ? AND hidden = 0 ORDER BY created_at DESC LIMIT 100`,
    ).bind(id).all(),
  ]);
  return {
    ...summary(game, rated.get(id)), notes: game.notes, profile_file: game.profile_file, profile_text: game.profile_text,
    presets: JSON.parse(game.presets), art_source: game.art_source ?? null, hero: game.hero ?? null, art_wanted: game.art_wanted ?? null, rating_list: results,
  };
}

/// Replaces the list of games. A game that gained a profile takes over the ratings and comments of the page it had;
/// one that lost its file keeps its page while it has either.
async function sync(request, env) {
  const token = request.headers.get('Authorization');
  if (!env.SYNC_TOKEN || token !== `Bearer ${env.SYNC_TOKEN}`) return json({ error: 'Not allowed.' }, 403);
  const { games } = await request.json();
  if (!Array.isArray(games) || !games.length) return json({ error: 'No games.' }, 400);
  const now = Date.now();
  const steps = [];
  for (const game of games) {
    steps.push(env.DB.prepare(
      `INSERT INTO games (id, name, category, source, verified, notes, profile_file, profile_text, presets, steam, gog, links, brand, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT (id) DO UPDATE SET name = excluded.name, category = excluded.category, source = excluded.source,
         verified = excluded.verified, notes = excluded.notes, profile_file = excluded.profile_file,
         profile_text = excluded.profile_text, presets = excluded.presets, steam = excluded.steam, gog = excluded.gog,
         links = excluded.links, brand = excluded.brand`,
    ).bind(game.id, game.name, game.category, game.source, game.verified, game.notes, game.profile_file, game.profile_text,
      JSON.stringify(game.presets), game.steam, game.gog, JSON.stringify(game.links ?? []), game.brand ?? null, now));
    for (const [store, id] of game.keys) {
      steps.push(env.DB.prepare(
        `UPDATE ratings SET game_id = ?1 WHERE game_id IN (SELECT game_id FROM game_keys WHERE store = ?2 AND store_id = ?3 AND game_id <> ?1)`,
      ).bind(game.id, store, id));
      steps.push(env.DB.prepare(
        `UPDATE comments SET game_id = ?1 WHERE game_id IN (SELECT game_id FROM game_keys WHERE store = ?2 AND store_id = ?3 AND game_id <> ?1)`,
      ).bind(game.id, store, id));
      steps.push(env.DB.prepare('INSERT OR REPLACE INTO game_keys (store, store_id, game_id) VALUES (?, ?, ?)').bind(store, id, game.id));
    }
  }
  const ids = JSON.stringify(games.map((game) => game.id));
  steps.push(env.DB.prepare(
    `DELETE FROM games WHERE id NOT IN (SELECT value FROM json_each(?1)) AND id NOT IN (SELECT game_id FROM ratings) AND id NOT IN (SELECT game_id FROM comments)`,
  ).bind(ids));
  steps.push(env.DB.prepare(
    `UPDATE games SET source = 'rated', verified = NULL, notes = NULL, profile_file = NULL, profile_text = NULL, presets = '[]'
     WHERE id NOT IN (SELECT value FROM json_each(?1))`,
  ).bind(ids));
  steps.push(env.DB.prepare('DELETE FROM game_keys WHERE game_id NOT IN (SELECT id FROM games)'));
  await env.DB.batch(steps);
  const { results: gone } = await env.DB.prepare(`SELECT game_id, file FROM game_art WHERE game_id NOT IN (SELECT id FROM games) AND game_id NOT LIKE '%:%'`).all();
  for (const entry of gone) {
    if (entry.file) await env.PICTURES.delete(`covers/${entry.file}`);
    await env.DB.prepare('DELETE FROM game_art WHERE game_id = ?').bind(entry.game_id).run();
  }
  return json({ games: games.length });
}

// Accounts

const SESSION_SECONDS = 90 * 24 * 3600;
const STATE_SECONDS = 600;
const USERNAME = /^[\p{L}\p{N}][\p{L}\p{N} ._-]{1,29}$/u;
const GOOGLE_ISSUERS = ['https://accounts.google.com', 'accounts.google.com'];

const base64url = (bytes) => btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
const randomToken = () => base64url(crypto.getRandomValues(new Uint8Array(32)));
const sha256 = (text) => crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
const hashed = async (token) => base64url(await sha256(token));

function cookie(request, name) {
  const pair = (request.headers.get('Cookie') || '').split(/; */).find((part) => part.startsWith(`${name}=`));
  return pair?.slice(name.length + 1) ?? null;
}

const setCookie = (name, value, seconds) => `${name}=${value}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=${seconds}`;

function redirect(location, ...cookies) {
  const headers = new Headers({ Location: location, 'Cache-Control': 'no-store' });
  for (const line of cookies) headers.append('Set-Cookie', line);
  return new Response(null, { status: 303, headers });
}

/// Only a path on this site, so a sign-in link can't send someone elsewhere afterwards.
const localPath = (path) => (/^\/(?![/\\])/.test(path || '') ? path : '/account');

async function signedIn(request, env) {
  const token = cookie(request, 'overpass_session');
  if (!token) return null;
  return env.DB.prepare(
    `SELECT users.id, users.name, users.picture FROM sessions JOIN users ON users.id = sessions.user_id WHERE sessions.token_hash = ? AND sessions.expires_at > ?`,
  ).bind(await hashed(token), Date.now()).first();
}

async function startGoogle(url, env) {
  const state = randomToken(), verifier = randomToken();
  const signIn = new URL(env.GOOGLE_AUTH_URL || 'https://accounts.google.com/o/oauth2/v2/auth');
  signIn.search = new URLSearchParams({
    client_id: env.GOOGLE_CLIENT_ID, redirect_uri: `${url.origin}/auth/google/callback`, response_type: 'code', scope: 'openid',
    state, code_challenge: base64url(await sha256(verifier)), code_challenge_method: 'S256',
  });
  const next = encodeURIComponent(localPath(url.searchParams.get('next')));
  return redirect(signIn.href, setCookie('overpass_signin', `${state}.${verifier}.${next}`, STATE_SECONDS));
}

/// The token comes straight from Google over TLS, so its claims are read without checking its signature.
async function finishGoogle(request, url, env) {
  const [state, verifier, ...next] = (cookie(request, 'overpass_signin') || '').split('.');
  const clear = setCookie('overpass_signin', '', 0);
  const failed = (reason) => {
    console.error(`Google sign-in failed: ${reason}`);
    return redirect('/account?error=signin', clear);
  };
  const code = url.searchParams.get('code');
  if (!code) return failed(`no code, ${url.searchParams.get('error')}`);
  if (!state) return failed('no sign-in cookie');
  if (url.searchParams.get('state') !== state) return failed('state differs from the cookie');
  const answer = await fetch(env.GOOGLE_TOKEN_URL || 'https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      client_id: env.GOOGLE_CLIENT_ID, client_secret: env.GOOGLE_CLIENT_SECRET, code, code_verifier: verifier,
      grant_type: 'authorization_code', redirect_uri: `${url.origin}/auth/google/callback`,
    }),
  });
  if (!answer.ok) return failed(`token ${answer.status}, ${(await answer.text()).slice(0, 300)}`);
  const { id_token: idToken } = await answer.json();
  const payload = (idToken || '').split('.')[1];
  if (!payload) return failed('no ID token');
  const claims = JSON.parse(atob(payload.replace(/-/g, '+').replace(/_/g, '/')));
  if (claims.aud !== env.GOOGLE_CLIENT_ID || !GOOGLE_ISSUERS.includes(claims.iss) || !claims.sub || claims.exp * 1000 < Date.now()) {
    return failed(`claims, aud ${claims.aud === env.GOOGLE_CLIENT_ID}, iss ${claims.iss}, exp ${claims.exp}`);
  }

  const now = Date.now();
  await env.DB.prepare('INSERT OR IGNORE INTO users (id, provider, provider_id, created_at) VALUES (?, ?, ?, ?)')
    .bind(crypto.randomUUID(), 'google', claims.sub, now).run();
  const user = await env.DB.prepare('SELECT id FROM users WHERE provider = ? AND provider_id = ?').bind('google', claims.sub).first('id');
  const token = randomToken();
  await env.DB.batch([
    env.DB.prepare('DELETE FROM sessions WHERE expires_at <= ?').bind(now),
    env.DB.prepare('INSERT INTO sessions (token_hash, user_id, expires_at) VALUES (?, ?, ?)')
      .bind(await hashed(token), user, now + SESSION_SECONDS * 1000),
  ]);
  return redirect(localPath(decodeURIComponent(next.join('.'))), clear, setCookie('overpass_session', token, SESSION_SECONDS));
}

async function signOut(request, env) {
  const token = cookie(request, 'overpass_session');
  if (token) await env.DB.prepare('DELETE FROM sessions WHERE token_hash = ?').bind(await hashed(token)).run();
  return redirect('/account', setCookie('overpass_session', '', 0));
}

async function rename(request, env, user) {
  const name = String((await request.formData()).get('name') || '').trim();
  if (!USERNAME.test(name)) return redirect('/account?error=name');
  const taken = await env.DB.prepare('SELECT id FROM users WHERE name = ? COLLATE NOCASE AND id <> ?').bind(name, user.id).first('id');
  if (taken) return redirect('/account?error=taken');
  await env.DB.prepare('UPDATE users SET name = ? WHERE id = ?').bind(name, user.id).run();
  return redirect('/account');
}

async function deleteAccount(env, user) {
  if (user.picture) await env.PICTURES.delete(user.picture);
  await env.DB.batch([
    env.DB.prepare('DELETE FROM sessions WHERE user_id = ?').bind(user.id),
    env.DB.prepare('DELETE FROM reports WHERE user_id = ?1 OR target IN (SELECT id FROM comments WHERE user_id = ?1) OR target IN (SELECT id FROM ratings WHERE install = ?2)')
      .bind(user.id, accountRater(user)),
    env.DB.prepare('DELETE FROM comments WHERE user_id = ?').bind(user.id),
    env.DB.prepare('DELETE FROM ratings WHERE install = ?').bind(accountRater(user)),
    env.DB.prepare('DELETE FROM users WHERE id = ?').bind(user.id),
  ]);
  return redirect('/account', setCookie('overpass_session', '', 0));
}

// Pictures

const PICTURE_BYTES = 64 * 1024;
const PICTURE_SIDE = 160;

async function savePicture(request, env, user) {
  if (Number(request.headers.get('Content-Length')) > PICTURE_BYTES) return redirect('/account?error=picture');
  const bytes = new Uint8Array(await request.arrayBuffer());
  const jpeg = bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  if (!jpeg || bytes.length > PICTURE_BYTES) return redirect('/account?error=picture');
  const key = crypto.randomUUID();
  await env.PICTURES.put(key, bytes);
  await env.DB.prepare('UPDATE users SET picture = ? WHERE id = ?').bind(key, user.id).run();
  if (user.picture) await env.PICTURES.delete(user.picture);
  return redirect('/account');
}

async function deletePicture(env, user) {
  if (user.picture) await takeDownPicture(env, user.picture);
  return redirect('/account');
}

async function takeDownPicture(env, key) {
  await env.DB.prepare('UPDATE users SET picture = NULL WHERE picture = ?').bind(key).run();
  await env.PICTURES.delete(key);
  return redirect('/moderation');
}

/// A key is never reused, so a picture can be cached for good; a new one has a new address.
async function servePicture(env, key) {
  const bytes = await env.PICTURES.get(key, 'arrayBuffer');
  if (!bytes) return new Response('No such picture.', { status: 404 });
  return new Response(bytes, {
    headers: { 'Content-Type': 'image/jpeg', 'X-Content-Type-Options': 'nosniff', 'Cache-Control': 'public, max-age=31536000, immutable' },
  });
}

// Art. find-covers.mjs, on GitHub, finds the addresses, and the pictures stay where they are. Only a moderator's upload
// is kept here.

const COVER_BYTES = 256 * 1024;
/// How many titles from the app can wait for a first look. Past this they're asked about again another day.
const ART_QUEUE = 500;

/// Replaces a game's cover. A file's name comes from its bytes, so it can be cached for good.
async function saveCover(env, id, bytes, extension, source, origin, locked) {
  const hash = await crypto.subtle.digest('SHA-256', bytes);
  const file = `${[...new Uint8Array(hash)].slice(0, 16).map((byte) => byte.toString(16).padStart(2, '0')).join('')}.${extension}`;
  const before = await env.DB.prepare('SELECT file FROM game_art WHERE game_id = ?').bind(id).first('file');
  await env.PICTURES.put(`covers/${file}`, bytes);
  await env.DB.prepare(
    `INSERT INTO game_art (game_id, file, source, origin, locked, checked_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
     ON CONFLICT (game_id) DO UPDATE SET file = ?2, source = ?3, origin = ?4, thumb = NULL, locked = ?5, wanted = NULL, checked_at = ?6`,
  ).bind(id, file, source, origin, locked ? 1 : 0, Date.now()).run();
  if (before && before !== file) await env.PICTURES.delete(`covers/${before}`);
}

async function serveCover(request, env, file) {
  const cached = await caches.default.match(request);
  if (cached) return cached;
  const bytes = await env.PICTURES.get(`covers/${file}`, 'arrayBuffer');
  if (!bytes) return new Response('No such picture.', { status: 404 });
  const response = new Response(bytes, {
    headers: { 'Content-Type': file.endsWith('.avif') ? 'image/avif' : 'image/jpeg', 'X-Content-Type-Options': 'nosniff', 'Cache-Control': 'public, max-age=31536000, immutable' },
  });
  if (request.method === 'GET') await caches.default.put(request, response.clone());
  return response;
}

async function artList(request, env) {
  if (!env.SYNC_TOKEN || request.headers.get('Authorization') !== `Bearer ${env.SYNC_TOKEN}`) return json({ error: 'Not allowed.' }, 403);
  const { results } = await env.DB.prepare(
    `SELECT g.id, g.name, g.category, g.steam, g.gog, g.brand, a.wanted, a.locked, a.checked_at, COALESCE(a.file, a.origin) AS cover, a.hero, a.icon
     FROM games g LEFT JOIN game_art a ON a.game_id = g.id`,
  ).all();
  const { results: asked } = await env.DB.prepare(`SELECT game_id AS id, name, checked_at, COALESCE(file, origin) AS cover, hero, icon FROM game_art WHERE game_id LIKE '%:%'`).all();
  const titles = asked.map((title) => {
    const [store, id] = title.id.split(':');
    return { ...title, [store]: id };
  });
  return new Response(JSON.stringify({ games: [...results, ...titles] }), { headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });
}

/// What find-covers.mjs found for one game or title. It fills gaps: art that's there stays, unless it's a moderator's
/// image coming in. A stored copy from before covers were linked counts as a gap; a moderator's upload doesn't.
async function storeArt(request, env) {
  if (!env.SYNC_TOKEN || request.headers.get('Authorization') !== `Bearer ${env.SYNC_TOKEN}`) return json({ error: 'Not allowed.' }, 403);
  const { id, links, source, cover: image, thumb, icon, hero } = await request.json();
  const before = await env.DB.prepare('SELECT file, origin, locked FROM game_art WHERE game_id = ?').bind(id).first();
  if (!before && !await env.DB.prepare('SELECT 1 FROM games WHERE id = ?').bind(id).first()) return json({ error: 'No such game.' }, 404);
  const address = (value) => typeof value === 'string' && value.startsWith('https://') && value.length <= 1000 ? value : null;
  await env.DB.prepare(
    `INSERT INTO game_art (game_id, links, icon, hero, checked_at) VALUES (?1, ?2, ?3, ?4, ?5)
     ON CONFLICT (game_id) DO UPDATE SET links = ?2, icon = COALESCE(icon, ?3), hero = COALESCE(hero, ?4), wanted = NULL, checked_at = ?5`,
  ).bind(id, JSON.stringify((links ?? []).filter(storeName)), address(icon), address(hero), Date.now()).run();
  const moderator = source === 'moderator';
  const gap = !before?.locked && (!before?.origin || before.file);
  if (!address(image) || !(gap || moderator)) return json({ stored: false });
  await env.DB.prepare('UPDATE game_art SET file = NULL, source = ?2, origin = ?3, thumb = ?4, locked = ?5 WHERE game_id = ?1')
    .bind(id, source, address(image), address(thumb), moderator ? 1 : 0).run();
  if (before?.file) await env.PICTURES.delete(`covers/${before.file}`);
  return json({ stored: true });
}

/// The art for a title in the app, by its store's ID. A title nobody has asked about joins the queue, and the app falls
/// back on the store itself meanwhile.
async function artFor(env, url, store, id) {
  const key = `${store}:${id}`;
  const game = await env.DB.prepare('SELECT game_id FROM game_keys WHERE store = ? AND store_id = ?').bind(store, id).first('game_id');
  const art = await env.DB.prepare(
    'SELECT file, origin, icon, hero FROM game_art WHERE game_id IN (?1, ?2) ORDER BY file IS NULL AND origin IS NULL LIMIT 1',
  ).bind(key, game ?? key).first();
  const name = url.searchParams.get('name')?.trim().slice(0, 200);
  if (!art && !game && name) {
    await env.DB.prepare(
      `INSERT OR IGNORE INTO game_art (game_id, name) SELECT ?1, ?2
       WHERE (SELECT COUNT(*) FROM game_art WHERE checked_at = 0 AND game_id LIKE '%:%') < ?3`,
    ).bind(key, name, ART_QUEUE).run();
  }
  const cover = art?.file ? `${url.origin}/pictures/covers/${art.file}` : art?.origin ?? null;
  return new Response(JSON.stringify({ cover, icon: art?.icon ?? null, hero: art?.hero ?? null }), {
    headers: { 'Content-Type': 'application/json', 'Cache-Control': cover ? 'public, max-age=86400' : 'no-store' },
  });
}

/// A moderator's picture, already shrunk in the browser; an image's address for find-covers.mjs to fetch; or back to
/// finding it automatically.
async function changeCover(request, env, id, action) {
  const back = `/games/${id}`;
  if (!await env.DB.prepare('SELECT 1 FROM games WHERE id = ?').bind(id).first()) return redirect('/games');
  if (action === 'url') {
    const url = String((await request.formData()).get('url') ?? '').trim();
    if (!url.startsWith('https://') || url.length > 1000) return redirect(`${back}?error=cover#cover`);
    await env.DB.prepare(
      'INSERT INTO game_art (game_id, wanted) VALUES (?1, ?2) ON CONFLICT (game_id) DO UPDATE SET wanted = ?2',
    ).bind(id, url).run();
  } else if (action === 'reset') {
    const file = await env.DB.prepare('SELECT file FROM game_art WHERE game_id = ?').bind(id).first('file');
    await env.DB.prepare('DELETE FROM game_art WHERE game_id = ?').bind(id).run();
    if (file) await env.PICTURES.delete(`covers/${file}`);
  } else {
    const bytes = new Uint8Array(await request.arrayBuffer());
    if (bytes[0] !== 0xff || bytes[1] !== 0xd8 || bytes[2] !== 0xff || bytes.length > COVER_BYTES) return redirect(`${back}?error=cover#cover`);
    await saveCover(env, id, bytes, 'jpg', 'moderator', null, true);
  }
  return redirect(`${back}#cover`);
}

// Comments

const COMMENT_LENGTH = 2000;
const COMMENTS_A_DAY = 20;

/// A hidden comment still shows to the person who wrote it, so they can delete it.
async function comments(env, id, user) {
  const { results } = await env.DB.prepare(
    `SELECT comments.id, comments.user_id, comments.body, comments.hidden, comments.created_at, users.name, users.picture FROM comments
     JOIN users ON users.id = comments.user_id WHERE comments.game_id = ? AND (comments.hidden = 0 OR comments.user_id = ?)
     ORDER BY comments.created_at DESC LIMIT 200`,
  ).bind(id, user?.id ?? null).all();
  return results;
}

async function addComment(request, env, user, id) {
  const back = `/games/${id}`;
  const exists = await env.DB.prepare('SELECT id FROM games WHERE id = ?').bind(id).first('id');
  if (!exists) return html(missingPage(), 404);
  if (!user.name) return redirect('/account');
  const body = String((await request.formData()).get('body') || '').replace(/\r\n/g, '\n').trim();
  if (!body || body.length > COMMENT_LENGTH) return redirect(`${back}?error=comment#comments`);
  const now = Date.now();
  const today = await env.DB.prepare('SELECT COUNT(*) AS n FROM comments WHERE user_id = ? AND created_at > ?')
    .bind(user.id, now - 24 * 3600 * 1000).first('n');
  if (today >= COMMENTS_A_DAY) return redirect(`${back}?error=limit#comments`);
  await env.DB.prepare('INSERT INTO comments (id, game_id, user_id, body, created_at) VALUES (?, ?, ?, ?, ?)')
    .bind(crypto.randomUUID(), id, user.id, body, now).run();
  return redirect(`${back}#comments`);
}

async function deleteComment(env, user, id, comment) {
  const { meta } = await env.DB.prepare('DELETE FROM comments WHERE id = ? AND user_id = ?').bind(comment, user.id).run();
  if (meta.changes) await env.DB.prepare('DELETE FROM reports WHERE target = ?').bind(comment).run();
  return redirect(`/games/${id}#comments`);
}

// Ratings from a moderator

const LOW_TIERS = ['bronze', 'borked'];

/// What stands in `ratings.install` for a moderator. The app's IDs are UUIDs, so the two can't meet.
const accountRater = (user) => `account:${user.id}`;

const ownRating = (env, user, id) => env.DB.prepare('SELECT id, tier, comment FROM ratings WHERE install = ? AND game_id = ?')
  .bind(accountRater(user), id).first();

/// Without a run behind it, so the page marks it as an admin's. A new one replaces the last; like the app, low needs a comment.
async function addOwnRating(request, env, user, id) {
  const back = `/games/${id}`;
  const exists = await env.DB.prepare('SELECT id FROM games WHERE id = ?').bind(id).first('id');
  if (!exists) return html(missingPage(), 404);
  const form = await request.formData();
  const tier = String(form.get('tier') || '');
  const comment = String(form.get('comment') || '').replace(/\r\n/g, '\n').trim();
  if (!TIERS.includes(tier) || comment.length > COMMENT_LENGTH) return redirect(`${back}?error=rating#ratings`);
  if (LOW_TIERS.includes(tier) && !comment) return redirect(`${back}?error=low#ratings`);
  await env.DB.batch([
    ...forgetOwnRating(env, user, id),
    env.DB.prepare('INSERT INTO ratings (id, game_id, tier, comment, install, created_at) VALUES (?, ?, ?, ?, ?, ?)')
      .bind(crypto.randomUUID(), id, tier, comment || null, accountRater(user), Date.now()),
  ]);
  return redirect(`${back}#ratings`);
}

async function deleteOwnRating(env, user, id) {
  await env.DB.batch(forgetOwnRating(env, user, id));
  return redirect(`/games/${id}#ratings`);
}

const forgetOwnRating = (env, user, id) => [
  env.DB.prepare('DELETE FROM reports WHERE target IN (SELECT id FROM ratings WHERE install = ? AND game_id = ?)').bind(accountRater(user), id),
  env.DB.prepare('DELETE FROM ratings WHERE install = ? AND game_id = ?').bind(accountRater(user), id),
];

// Reports

const REPORTS_TO_HIDE = 3;
const REPORTS_A_DAY = 20;

const isModerator = (env, user) => Boolean(user) && (env.MODERATORS || '').split(',').includes(user.id);

async function reportedBy(env, user) {
  if (!user) return new Set();
  const { results } = await env.DB.prepare('SELECT target FROM reports WHERE user_id = ?').bind(user.id).all();
  return new Set(results.map((row) => row.target));
}

/// `kind` is a table's name, from the route. A moderator's report hides the entry at once.
async function report(env, user, id, kind, entry) {
  const anchor = `/games/${id}#${kind === 'comments' ? 'comment' : 'rating'}-${entry}`;
  const target = await env.DB.prepare(`SELECT id, ${kind === 'comments' ? 'user_id' : 'NULL AS user_id'} FROM ${kind} WHERE id = ? AND game_id = ?`)
    .bind(entry, id).first();
  if (!target || target.user_id === user.id) return redirect(anchor);
  const now = Date.now();
  const today = await env.DB.prepare('SELECT COUNT(*) AS n FROM reports WHERE user_id = ? AND created_at > ?')
    .bind(user.id, now - 24 * 3600 * 1000).first('n');
  if (today >= REPORTS_A_DAY) return redirect(`/games/${id}?error=reports#comments`);
  await env.DB.prepare('INSERT OR IGNORE INTO reports (target, user_id, created_at) VALUES (?, ?, ?)').bind(entry, user.id, now).run();
  const count = await env.DB.prepare('SELECT COUNT(*) AS n FROM reports WHERE target = ?').bind(entry).first('n');
  if (count >= REPORTS_TO_HIDE || isModerator(env, user)) await env.DB.prepare(`UPDATE ${kind} SET hidden = 1 WHERE id = ?`).bind(entry).run();
  return redirect(anchor);
}

/// Everything reported or hidden. A rating replaced in the meantime has a new ID, so its reports are simply not found.
async function queue(env) {
  const { results } = await env.DB.prepare(
    `SELECT 'comments' AS kind, comments.id, comments.body AS text, NULL AS tier, comments.hidden, comments.created_at AS created_at, comments.game_id,
       users.name AS author, users.picture, games.name AS game, (SELECT COUNT(*) FROM reports WHERE target = comments.id) AS reports
     FROM comments JOIN users ON users.id = comments.user_id LEFT JOIN games ON games.id = comments.game_id
     WHERE comments.hidden = 1 OR comments.id IN (SELECT target FROM reports)
     UNION ALL
     SELECT 'ratings', ratings.id, ratings.comment, ratings.tier, ratings.hidden, ratings.created_at, ratings.game_id,
       NULL, NULL, games.name, (SELECT COUNT(*) FROM reports WHERE target = ratings.id)
     FROM ratings LEFT JOIN games ON games.id = ratings.game_id
     WHERE ratings.hidden = 1 OR ratings.id IN (SELECT target FROM reports)
     ORDER BY reports DESC, created_at DESC LIMIT 200`,
  ).all();
  return results;
}

/// Settles an entry: its reports go either way, so it only comes back if people report it again.
async function review(env, kind, entry, action) {
  await env.DB.batch([
    env.DB.prepare(`UPDATE ${kind} SET hidden = ? WHERE id = ?`).bind(action === 'hide' ? 1 : 0, entry),
    env.DB.prepare('DELETE FROM reports WHERE target = ?').bind(entry),
  ]);
  return redirect('/moderation');
}

// Suggested profiles

const fromGitHub = (request, env) => Boolean(env.SYNC_TOKEN) && request.headers.get('Authorization') === `Bearer ${env.SYNC_TOKEN}`;

/// What's waiting for a decision, with the file each one would replace and why it can't go in as it stands.
async function suggestions(env) {
  const { results } = await env.DB.prepare(
    `SELECT suggestions.*, games.name AS game, games.profile_text AS current FROM suggestions LEFT JOIN games ON games.id = suggestions.game_id
     WHERE status IN ('pending', 'approved') ORDER BY created_at LIMIT 100`,
  ).all();
  return results.map((entry) => ({ ...entry, problems: profileProblems(entry.body, entry.current) }));
}

async function decide(env, entry, action) {
  if (action === 'reject') {
    await env.DB.prepare("DELETE FROM suggestions WHERE id = ? AND status = 'pending'").bind(entry).run();
    return redirect('/moderation');
  }
  const found = await env.DB.prepare(
    'SELECT body, profile_text AS current FROM suggestions LEFT JOIN games ON games.id = suggestions.game_id WHERE suggestions.id = ?',
  ).bind(entry).first();
  if (found && !profileProblems(found.body, found.current).length) {
    await env.DB.prepare("UPDATE suggestions SET status = 'approved' WHERE id = ? AND status = 'pending'").bind(entry).run();
  }
  return redirect('/moderation');
}

async function approvedSuggestions(request, env) {
  if (!fromGitHub(request, env)) return json({ error: 'Not allowed.' }, 403);
  const { results } = await env.DB.prepare("SELECT id, game_id, profile_id, body FROM suggestions WHERE status = 'approved' ORDER BY created_at").all();
  return new Response(JSON.stringify({ suggestions: results }), { headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });
}

/// The workflow's answer: what went into profiles/, and what it wouldn't take, which goes back to waiting.
async function settleSuggestions(request, env) {
  if (!fromGitHub(request, env)) return json({ error: 'Not allowed.' }, 403);
  const { published = [], refused = [] } = await request.json();
  await env.DB.batch([
    env.DB.prepare("UPDATE suggestions SET status = 'published' WHERE id IN (SELECT value FROM json_each(?)) AND status = 'approved'").bind(JSON.stringify(published)),
    env.DB.prepare("UPDATE suggestions SET status = 'pending' WHERE id IN (SELECT value FROM json_each(?)) AND status = 'approved'").bind(JSON.stringify(refused)),
  ]);
  return json({ published: published.length, refused: refused.length });
}

/// Keeps a newer signed set. The signature is the app's to check; an older set never replaces this one.
async function storeProfiles(request, env) {
  if (!fromGitHub(request, env)) return json({ error: 'Not allowed.' }, 403);
  const { serial, body } = await request.json();
  if (!Number.isInteger(serial) || typeof body !== 'string') return json({ error: 'No profiles.' }, 400);
  await env.DB.prepare(
    'INSERT INTO profile_set (id, serial, body) VALUES (1, ?1, ?2) ON CONFLICT (id) DO UPDATE SET serial = ?1, body = ?2 WHERE serial < ?1',
  ).bind(serial, body).run();
  return json({ serial });
}

async function serveProfiles(env) {
  const set = await env.DB.prepare('SELECT serial, body FROM profile_set WHERE id = 1').first();
  if (!set) return json({ error: 'No profiles yet.' }, 404);
  return new Response(set.body, { headers: { 'Content-Type': 'application/json', 'Cache-Control': 'public, max-age=300', 'X-Profiles-Serial': String(set.serial) } });
}

// Pages

const escape = (text) => String(text ?? '').replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
const date = (time) => new Date(time).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'UTC' });
const hue = (name) => [...name].reduce((sum, c) => (sum * 31 + c.charCodeAt(0)) % 360, 7);
const initials = (name) => name.replace(/[^\p{L}\p{N} ]/gu, '').split(/\s+/).filter(Boolean).slice(0, 2).map((word) => [...word][0]).join('').toUpperCase() || '?';

function medal(tier, large = false) {
  if (!tier) return '<span class="medal none">Not rated</span>';
  return `<span class="medal ${tier}${large ? ' large' : ''}">${TITLES[tier]}</span>`;
}

/// The person's picture when there is one, over their initials.
function avatar(name, picture) {
  const art = picture ? `<img src="/pictures/${picture}.jpg" alt="" loading="lazy" onerror="this.remove()">` : '';
  return `<span class="avatar" style="--hue:${hue(name)}">${escape(initials(name))}${art}</span>`;
}

/// Black or white, whichever stands out on a brand's colour.
function ink(brand) {
  const [red, green, blue] = brand.match(/../g).map((part) => parseInt(part, 16));
  return 0.299 * red + 0.587 * green + 0.114 * blue > 160 ? '#000' : '#fff';
}

/// A launcher's logo on its colour, as on the app's Home; otherwise the game's cover over a tile made from the name,
/// which shows when there's no cover.
function cover(game) {
  if (/^[0-9a-f]{6}$/i.test(game.brand ?? '')) {
    return `<div class="cover tile" style="--brand:#${game.brand};--ink:${ink(game.brand)};--logo:url(/logos/${game.id}.svg)"><i></i></div>`;
  }
  const art = game.art ? `<img src="${escape(game.art)}" alt="" loading="lazy" referrerpolicy="no-referrer" onerror="this.remove()">` : '';
  return `<div class="cover" style="--hue:${hue(game.name)}"><span>${escape(initials(game.name))}</span>${art}</div>`;
}

function shell(title, description, body, moderator = false) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escape(title)}</title>
<meta name="description" content="${escape(description)}">
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/cards.css">
<link rel="stylesheet" href="/games.css">
</head>
<body>
<nav class="top">
  <a class="brand" href="/"><img src="/icon.svg" alt="">OverPass</a>
  <span class="links"><a href="/games">Games</a>${moderator ? '<a href="/moderation">Moderation</a>' : ''}<a href="/account">Account</a></span>
</nav>
<main>${body}</main>
<footer>
  <a class="maker" href="https://arctim.no"><img src="/arctic-imaginarium.svg" alt="">Made by Arctic Imaginarium</a>
  <span aria-hidden="true">·</span> <a href="${REPOSITORY}">GitHub</a>
  <span aria-hidden="true">·</span> <a href="https://ko-fi.com/arctim">Ko-fi</a>
  <span aria-hidden="true">·</span> <a href="/privacy">Privacy</a>
</footer>
</body>
</html>`;
}

const KINDS = { profile: 'Profile', preset: 'Known fix' };
const COLUMNS = [['name', 'Game'], ['tier', 'Rating'], ['ratings', 'Ratings'], ['last', 'Last Rated'], ['category', 'Category'], ['kind', 'Type']];

function card(game) {
  const kind = KINDS[game.source] ?? '';
  return `<a class="card" href="/games/${game.id}" data-name="${escape(game.name.toLowerCase())}" data-tier="${game.tier ?? 'none'}" data-ratings="${game.ratings}" data-last="${game.last_rated ?? 0}" data-category="${escape(game.category ?? '')}" data-kind="${kind}">
  ${cover(game)}
  <h3>${escape(game.name)}</h3>
  <p>${medal(game.tier)}${kind ? `<span class="tag">${kind}</span>` : ''}</p>
  <span class="column">${game.ratings || ''}</span>
  <span class="column">${game.last_rated ? date(game.last_rated) : ''}</span>
  <span class="column wide">${escape(game.category ?? '')}</span>
  <span class="column medium">${kind}</span>
  <span class="column wide">${game.stores.map((store) => escape(store.name)).join(', ')}</span>
</a>`;
}

function gamesPage(games, moderator) {
  const rated = games.filter((game) => game.tier).length;
  const filters = [['all', 'All'], ...TIERS.map((tier) => [tier, TITLES[tier]]), ['none', 'Not rated']]
    .map(([value, title]) => `<button type="button" data-filter="${value}" aria-pressed="${value === 'all'}">${title}</button>`).join('');
  const heads = COLUMNS.map(([key, title]) => `<button type="button" data-sort="${key}" class="${{ category: 'wide', kind: 'medium' }[key] ?? ''}">${title}</button>`).join('');
  const sorts = [['last', 'Last Rated'], ['name', 'Name'], ['tier', 'Rating'], ['ratings', 'Number of Ratings'], ['category', 'Category'], ['kind', 'Type']]
    .map(([value, title]) => `<option value="${value}">${title}</option>`).join('');
  return shell('Games · OverPass', 'How Windows games run on a Mac with OverPass: ratings from players and each game\'s settings.', `
<header class="page">
  <h1>Games</h1>
  <p>How Windows games run on a Mac with OverPass. ${games.length} games, ${rated} rated by players.</p>
</header>
<div class="controls">
  <input id="search" type="search" placeholder="Search games" aria-label="Search games" autocomplete="off">
  <div class="filters" id="filters">${filters}</div>
  <div class="arrange">
    <label>Sort by <select id="sort">${sorts}</select></label>
    <button type="button" id="direction" aria-label="Reverse the order"></button>
    <span class="filters" id="views"><button type="button" data-view="covers" aria-pressed="true">Covers</button><button type="button" data-view="rows" aria-pressed="false">Rows</button></span>
  </div>
</div>
<div class="heads" id="heads" hidden>${heads}<span class="wide">Stores</span></div>
<div class="grid" id="grid">${games.map(card).join('\n')}</div>
<p class="empty" id="nothing" hidden>No games match.</p>
<script>
  const grid = document.getElementById('grid'), heads = document.getElementById('heads'), sort = document.getElementById('sort');
  const cards = [...grid.querySelectorAll('.card')], search = document.getElementById('search');
  const direction = document.getElementById('direction'), views = [...document.querySelectorAll('#views button')];
  const buttons = [...document.querySelectorAll('#filters button')], nothing = document.getElementById('nothing');
  const tiers = ${JSON.stringify(TIERS)}, titles = ${JSON.stringify(TITLES)};
  // What each sort reads from a card, which way it starts, and the heading of the group a card falls under, for the
  // sorts where groups make sense. null sorts last either way. NFD splits an accent from its letter: É goes under E.
  const keys = {
    name: [(card) => card.dataset.name, true, (card) => {
      const first = [...card.dataset.name.normalize('NFD')][0] ?? '';
      return /\\p{L}/u.test(first) ? first.toUpperCase() : '#';
    }],
    tier: [(card) => tiers.includes(card.dataset.tier) ? tiers.indexOf(card.dataset.tier) : null, true, (card) => titles[card.dataset.tier] ?? 'Not rated'],
    ratings: [(card) => Number(card.dataset.ratings) || null, false],
    last: [(card) => Number(card.dataset.last) || null, false],
    category: [(card) => card.dataset.category || null, true, (card) => card.dataset.category || 'No category'],
    kind: [(card) => card.dataset.kind || null, true, (card) => card.dataset.kind || 'Other'],
  };
  let filter = 'all', state = { key: 'last', up: false, view: 'covers' };
  try { state = { ...state, ...JSON.parse(localStorage.getItem('games-view')) }; } catch {}
  if (!keys[state.key]) state.key = 'last';
  function apply() {
    const text = search.value.trim().toLowerCase();
    let shown = 0;
    for (const card of cards) {
      card.hidden = !(card.dataset.name.includes(text) && (filter === 'all' || card.dataset.tier === filter));
      if (!card.hidden) shown++;
    }
    nothing.hidden = shown > 0;
    // A heading shows when a card under it does.
    let heading = null;
    for (const item of grid.children) {
      if (item.matches('.group')) { heading = item; heading.hidden = true; } else if (!item.hidden && heading) heading.hidden = false;
    }
  }
  function arrange() {
    const [read, , group] = keys[state.key];
    const compare = (a, b) => (typeof a === 'string' ? a.localeCompare(b) : a - b);
    const sorted = [...cards].sort((a, b) => {
      const [first, second] = [read(a), read(b)];
      const order = first === null || second === null ? (first === null) - (second === null) : compare(first, second) * (state.up ? 1 : -1);
      return order || a.dataset.name.localeCompare(b.dataset.name);
    });
    let last = null;
    grid.replaceChildren(...sorted.flatMap((card) => {
      const title = group?.(card) ?? null;
      if (title === last) return [card];
      last = title;
      const heading = document.createElement('h2');
      heading.className = 'group';
      heading.textContent = title;
      return [heading, card];
    }));
    apply();
    sort.value = state.key;
    direction.textContent = state.up ? '↑' : '↓';
    grid.classList.toggle('rows', state.view === 'rows');
    heads.hidden = state.view !== 'rows';
    for (const view of views) view.setAttribute('aria-pressed', view.dataset.view === state.view);
    for (const head of heads.querySelectorAll('button')) {
      const active = head.dataset.sort === state.key;
      head.dataset.arrow = active ? (state.up ? '↑' : '↓') : '';
      if (active) head.setAttribute('aria-current', 'true'); else head.removeAttribute('aria-current');
    }
    try { localStorage.setItem('games-view', JSON.stringify(state)); } catch {}
  }
  function sortBy(key) {
    state.up = state.key === key ? !state.up : keys[key][1];
    state.key = key;
    arrange();
  }
  search.addEventListener('input', apply);
  for (const button of buttons) button.addEventListener('click', () => {
    filter = button.dataset.filter;
    for (const other of buttons) other.setAttribute('aria-pressed', other === button);
    apply();
  });
  sort.addEventListener('change', () => { state.key = sort.value; state.up = keys[sort.value][1]; arrange(); });
  direction.addEventListener('click', () => { state.up = !state.up; arrange(); });
  heads.addEventListener('click', (event) => { const head = event.target.closest('button'); if (head) sortBy(head.dataset.sort); });
  for (const view of views) view.addEventListener('click', () => { state.view = view.dataset.view; arrange(); });
  arrange();
</script>`, moderator);
}

/// One bar a tier, as wide as its share of the ratings.
function breakdown(game) {
  return `<div class="bars">${TIERS.map((tier) => {
    const n = game.counts[tier] || 0;
    return `<div class="bar"><span class="label">${TITLES[tier]}</span><span class="track"><span class="fill ${tier}" style="width:${Math.round(100 * n / game.ratings)}%"></span></span><span class="count">${n}</span></div>`;
  }).join('')}</div>`;
}

function reportButton(game, kind, entry, user, reports) {
  if (!user) return '';
  if (reports.has(entry)) return '<p class="reported">Reported</p>';
  return `<form method="post" action="/games/${game.id}/${kind}/${entry}/report"><button class="link" type="submit">Report</button></form>`;
}

function ratingCard(game, rating, user, reports, own) {
  const facts = [
    rating.chip, rating.macos && `macOS ${rating.macos}`, rating.wine && `Wine ${rating.wine}`,
    rating.runtime && rating.runtime !== 'not installed' && `Runtime ${rating.runtime}`, rating.backend,
    rating.fps && `${Math.round(rating.fps)} fps`, rating.admin && 'Admin rating',
  ].filter(Boolean);
  return `<article class="rating" id="rating-${rating.id}">
  <div class="line">${medal(rating.tier)}<time datetime="${new Date(rating.created_at).toISOString()}">${date(rating.created_at)}</time></div>
  ${rating.comment ? `<p class="comment">${escape(rating.comment)}</p>` : ''}
  <p class="facts">${facts.map((fact) => `<span>${escape(fact)}</span>`).join('')}</p>
  ${rating.id === own?.id ? '' : reportButton(game, 'ratings', rating.id, user, reports)}
</article>`;
}

function commentCard(game, comment, user, reports) {
  const mine = comment.user_id === user?.id;
  return `<article class="rating" id="comment-${comment.id}">
  <div class="line"><span class="who">${avatar(comment.name, comment.picture)}${escape(comment.name)}</span><time datetime="${new Date(comment.created_at).toISOString()}">${date(comment.created_at)}</time></div>
  <p class="comment">${escape(comment.body)}</p>
  ${comment.hidden ? '<p class="muted">Hidden after reports. Only you can see this.</p>' : ''}
  ${mine ? `<form method="post" action="/games/${game.id}/comments/${comment.id}/delete"><button class="link" type="submit">Delete</button></form>` : reportButton(game, 'comments', comment.id, user, reports)}
</article>`;
}

function commentForm(game, user) {
  const back = encodeURIComponent(`/games/${game.id}#comments`);
  if (!user) return `<p><a class="button quiet" href="/auth/google?next=${back}">Sign in to comment</a></p>`;
  if (!user.name) return `<p><a class="button quiet" href="/account">Choose a username to comment</a></p>`;
  return `<form class="write" method="post" action="/games/${game.id}/comments">
  <label for="body">Comment as ${escape(user.name)}</label>
  <textarea id="body" name="body" rows="3" required maxlength="${COMMENT_LENGTH}"></textarea>
  <button class="button" type="submit">Post Comment</button>
</form>`;
}

/// For a moderator: every tier as a choice, with what they gave this game before.
function ratingForm(game, own) {
  const tiers = TIERS.map((tier) => `<label><input type="radio" name="tier" value="${tier}" required${own?.tier === tier ? ' checked' : ''}>${medal(tier)}</label>`).join('');
  return `<form class="write" method="post" action="/games/${game.id}/ratings">
  <fieldset class="tiers"><legend>${own ? 'Your rating' : 'Rate this game'}</legend>${tiers}</fieldset>
  <label for="rating-comment">Comment, needed for Bronze and Borked</label>
  <textarea id="rating-comment" name="comment" rows="2" maxlength="${COMMENT_LENGTH}">${escape(own?.comment)}</textarea>
  <div class="decide">
    <button class="button" type="submit">${own ? 'Update Rating' : 'Save Rating'}</button>
    ${own ? `<button class="button quiet" type="submit" formaction="/games/${game.id}/ratings/delete" formnovalidate>Remove Rating</button>` : ''}
  </div>
</form>`;
}

const RATING_ERRORS = {
  rating: `Pick a medal. A comment has at most ${COMMENT_LENGTH} characters.`,
  low: 'Bronze and Borked need a comment saying what went wrong.',
};

const COMMENT_ERRORS = {
  comment: `A comment has 1 to ${COMMENT_LENGTH} characters.`,
  limit: `That's ${COMMENTS_A_DAY} comments in a day, the most you can post. Try again tomorrow.`,
  reports: `That's ${REPORTS_A_DAY} reports in a day, the most you can send. Try again tomorrow.`,
};

const COVER_SOURCES = { steam: 'Steam', gog: 'GOG', thegamesdb: 'TheGamesDB', steamgriddb: 'SteamGridDB', moderator: 'a moderator' };

/// For a moderator: a picture from the Mac, shrunk in the browser; an image's address; or back to automatic.
function coverForm(game, error) {
  const said = game.art_wanted ? `Waiting for ${escape(game.art_wanted)}. It's fetched within half an hour.`
    : game.art ? `This cover came from ${COVER_SOURCES[game.art_source] ?? 'an unknown source'}.` : 'No cover found yet.';
  return `<section id="cover">
  <details${error === 'cover' ? ' open' : ''}><summary>Change Cover</summary>
  ${error === 'cover' ? `<p class="problem" role="alert">That didn't work. Use a picture, or an https:// address of an image.</p>` : ''}
  <p class="muted">${said}</p>
  <div class="decide">
    <label class="button quiet">Choose Picture…<input id="cover-file" type="file" accept="image/*" hidden></label>
    <form method="post" action="/games/${game.id}/cover/reset"><button class="button quiet" type="submit">Find Automatically</button></form>
  </div>
  <form class="write" method="post" action="/games/${game.id}/cover/url">
    <label for="cover-url">Or an image's address</label>
    <input id="cover-url" name="url" type="url" required maxlength="1000" placeholder="https://">
    <button class="button quiet" type="submit">Use This Image</button>
  </form>
  </details>
  <script>
    document.getElementById('cover-file').addEventListener('change', async (event) => {
      const image = await createImageBitmap(event.target.files[0]).catch(() => null);
      if (!image) return location.assign('/games/${game.id}?error=cover#cover');
      const canvas = document.createElement('canvas');
      canvas.width = 400;
      canvas.height = 600;
      const scale = Math.max(400 / image.width, 600 / image.height), context = canvas.getContext('2d');
      context.imageSmoothingQuality = 'high';
      context.drawImage(image, (400 - image.width * scale) / 2, (600 - image.height * scale) / 2, image.width * scale, image.height * scale);
      canvas.toBlob(async (blob) => {
        const answer = await fetch('/games/${game.id}/cover', { method: 'POST', headers: { 'Content-Type': 'image/jpeg' }, body: blob });
        location.assign(answer.url);
      }, 'image/jpeg', 0.7);
    });
  </script>
</section>`;
}

function gamePage(game, said, user, reports, error, moderator, own) {
  const hasSettings = game.profile_text || game.presets.length;
  const presets = game.presets.map((name) => `<li><a href="${REPOSITORY}/blob/main/profiles/Presets/${encodeURIComponent(name)}.ini">${escape(name)}</a></li>`).join('');
  const settings = !hasSettings ? '' : `
<section>
  <h2>${game.profile_text ? 'Profile' : 'Known fixes'}</h2>
  ${game.notes ? `<p>${escape(game.notes)}</p>` : ''}
  ${game.profile_text ? `<p class="muted">OverPass applies these settings for you.</p>` : `<p class="muted">OverPass applies these settings for this game. They come from reports and are not all tested on OverPass.</p>`}
  ${presets ? `<ul class="presets">${presets}</ul>` : ''}
  ${game.profile_text ? `<details><summary>Show the profile</summary><pre>${escape(game.profile_text)}</pre></details>
  <p><a href="${REPOSITORY}/blob/main/${escape(game.profile_file)}">See it on GitHub</a></p>` : ''}
</section>`;
  const ratings = game.rating_list.length
    ? game.rating_list.map((rating) => ratingCard(game, rating, user, reports, own)).join('\n')
    : '<p class="empty">No ratings yet. Play it in OverPass and tell others how it ran.</p>';
  return shell(`${game.name} on Mac · OverPass`, `How ${game.name} runs on a Mac with OverPass.`, `
<a class="back" href="/games">All games</a>
${game.hero ? `<img class="hero" src="${escape(game.hero)}" alt="" referrerpolicy="no-referrer" onerror="this.remove()">` : ''}
<header class="game">
  ${cover(game)}
  <div>
    <h1>${escape(game.name)}</h1>
    <p class="summary">${medal(game.tier, true)}<span>${game.ratings === 1 ? '1 rating' : `${game.ratings} ratings`}</span></p>
    ${game.verified ? `<p class="muted">Tested by OverPass: ${escape(TITLES[game.verified] ?? game.verified)}</p>` : ''}
    ${game.ratings ? breakdown(game) : ''}
    ${game.stores.length ? `<p class="stores">${game.stores.map((store) => `<a href="${escape(store.url)}" rel="noopener">${escape(store.name)}</a>`).join('')}</p>` : ''}
  </div>
</header>
${moderator ? coverForm(game, error) : ''}
${settings}
<section id="ratings">
  <h2>Ratings</h2>
  ${RATING_ERRORS[error] ? `<p class="problem" role="alert">${RATING_ERRORS[error]}</p>` : ''}
  ${moderator ? ratingForm(game, own) : ''}
  ${ratings}
</section>
<section id="comments">
  <h2>Comments</h2>
  ${COMMENT_ERRORS[error] ? `<p class="problem" role="alert">${COMMENT_ERRORS[error]}</p>` : ''}
  ${commentForm(game, user)}
  ${said.map((comment) => commentCard(game, comment, user, reports)).join('\n')}
</section>`, moderator);
}

const ACCOUNT_ERRORS = {
  signin: 'Signing in didn\'t work. Try again.',
  name: 'A username has 2 to 30 letters, digits, spaces, dots, dashes or underscores, and starts with a letter or digit.',
  taken: 'That username is taken.',
  picture: 'That picture didn\'t work. Try a JPEG or PNG.',
};

/// The lines a suggestion takes away and adds, against the file it would replace.
function difference(entry) {
  const lines = (text) => String(text ?? '').split(/\r?\n/).map((line) => line.trimEnd()).filter(Boolean);
  const before = lines(entry.current);
  const after = lines(entry.body);
  const changed = [
    ...before.filter((line) => !after.includes(line)).map((line) => `<del>- ${escape(line)}</del>`),
    ...after.filter((line) => !before.includes(line)).map((line) => `<ins>+ ${escape(line)}</ins>`),
  ];
  return changed.length ? changed.join('\n') : 'Same as the current file.';
}

function suggestionCard(entry) {
  const facts = [entry.overpass && `OverPass ${entry.overpass}`, entry.wine && `Wine ${entry.wine}`, entry.runtime && `Runtime ${entry.runtime}`].filter(Boolean).map(escape).join(' · ');
  const buttons = entry.status === 'approved' ? '<p class="muted">Approved. Goes out with the next publish, within the hour.</p>'
    : `<div class="decide">${entry.problems.length ? '' : `<form method="post" action="/moderation/suggestions/${entry.id}/approve"><button class="button" type="submit">Approve</button></form>`}<form method="post" action="/moderation/suggestions/${entry.id}/reject"><button class="button quiet" type="submit">Reject</button></form></div>`;
  return `<article class="rating">
  <div class="line"><span class="who"><a href="/games/${entry.game_id}">${escape(entry.game ?? entry.game_id)}</a></span><time datetime="${new Date(entry.created_at).toISOString()}">${date(entry.created_at)}</time></div>
  <p class="muted">profiles/${escape(entry.profile_id)}.ini · ${entry.current ? 'changes the file' : 'a new file'}${facts ? ` · ${facts}` : ''}</p>
  ${entry.comment ? `<p class="comment">${escape(entry.comment)}</p>` : ''}
  <pre class="diff">${difference(entry)}</pre>
  ${entry.problems.length ? `<p class="muted">Can't be approved here: ${entry.problems.map(escape).join('; ')}.</p>` : ''}
  ${buttons}
</article>`;
}

function moderationCard(entry) {
  const buttons = entry.hidden
    ? [['show', 'Show', 'quiet']]
    : [['hide', 'Hide', 'danger'], ['show', 'Keep', 'quiet']];
  return `<article class="rating">
  <div class="line"><span class="who">${entry.tier ? medal(entry.tier) : `${avatar(entry.author, entry.picture)}${escape(entry.author)}`}</span><time datetime="${new Date(entry.created_at).toISOString()}">${date(entry.created_at)}</time></div>
  ${entry.text ? `<p class="comment">${escape(entry.text)}</p>` : ''}
  <p class="muted"><a href="/games/${entry.game_id}">${escape(entry.game ?? entry.game_id)}</a> · ${entry.hidden ? 'Hidden' : 'Showing'} · ${entry.reports === 1 ? '1 report' : `${entry.reports} reports`}</p>
  <div class="decide">${buttons.map(([action, title, style]) => `<form method="post" action="/moderation/${entry.kind}/${entry.id}/${action}"><button class="button ${style}" type="submit">${title}</button></form>`).join('')}${entry.picture ? `<form method="post" action="/moderation/pictures/${entry.picture}/remove"><button class="button quiet" type="submit">Remove Picture</button></form>` : ''}</div>
</article>`;
}

const moderationPage = (entries, suggested) => shell('Moderation · OverPass', 'Reported and hidden comments and ratings, and suggested profiles.', `
<header class="page"><h1>Moderation</h1><p>Suggested profiles, and reported and hidden comments and ratings. Deciding clears an entry's reports.</p></header>
<section>
  <h2>Suggested profiles</h2>
  ${suggested.length ? suggested.map(suggestionCard).join('\n') : '<p class="empty">None waiting.</p>'}
</section>
<section>
  <h2>Reports</h2>
  ${entries.length ? entries.map(moderationCard).join('\n') : '<p class="empty">Nothing to look at.</p>'}
</section>`, true);

/// Crops to a square and shrinks it here, so only a small JPEG is ever sent.
function pictureForm(user) {
  return `<section class="picture">
  ${avatar(user.name, user.picture)}
  <label class="button quiet">Choose Picture…<input id="picture" type="file" accept="image/*" hidden></label>
  ${user.picture ? '<form method="post" action="/account/picture/delete"><button class="button quiet" type="submit">Remove Picture</button></form>' : ''}
</section>
<script>
  document.getElementById('picture').addEventListener('change', async (event) => {
    const image = await createImageBitmap(event.target.files[0]).catch(() => null);
    if (!image) return location.assign('/account?error=picture');
    const side = Math.min(image.width, image.height), canvas = document.createElement('canvas');
    canvas.width = canvas.height = ${PICTURE_SIDE};
    const context = canvas.getContext('2d');
    context.fillStyle = '#ffffff';
    context.fillRect(0, 0, canvas.width, canvas.height);
    context.drawImage(image, (image.width - side) / 2, (image.height - side) / 2, side, side, 0, 0, canvas.width, canvas.height);
    canvas.toBlob(async (blob) => {
      const answer = await fetch('/account/picture', { method: 'POST', headers: { 'Content-Type': 'image/jpeg' }, body: blob });
      location.assign(answer.url);
    }, 'image/jpeg', 0.85);
  });
</script>`;
}

function accountPage(user, error, moderator) {
  const problem = ACCOUNT_ERRORS[error] ? `<p class="problem" role="alert">${ACCOUNT_ERRORS[error]}</p>` : '';
  if (!user) {
    return shell('Sign in · OverPass', 'Sign in to OverPass.', `
<header class="page"><h1>Sign in</h1><p>An account lets you comment on game pages. You don't need one to play or to rate games from the app.</p></header>
${problem}
<p><a class="button" href="/auth/google">Sign in with Google</a></p>
<p class="muted">OverPass keeps Google's ID for your account, the username you choose and a picture if you add one, not your e-mail or name. <a href="/privacy">Privacy</a></p>`);
  }
  return shell('Your account · OverPass', 'Your OverPass account.', `
<header class="page"><h1>${user.name ? escape(user.name) : 'Choose a username'}</h1>${user.name ? '' : '<p>This is the name others will see.</p>'}</header>
${problem}
${user.name ? pictureForm(user) : ''}
<form class="account" method="post" action="/account">
  <label for="name">Username</label>
  <input id="name" name="name" required minlength="2" maxlength="30" value="${escape(user.name)}" autocomplete="username">
  <button class="button" type="submit">Save</button>
</form>
<form class="account" method="post" action="/auth/signout"><button class="button quiet" type="submit">Sign Out</button></form>
<section>
  <h2>Delete account</h2>
  <p class="muted">Removes your account, username, picture and comments at once. Ratings sent from the app aren't tied to an account, so they stay.</p>
  <form method="post" action="/account/delete"><button class="button danger" type="submit">Delete Account</button></form>
</section>`, moderator);
}

const privacyPage = (moderator) => shell('Privacy · OverPass', 'What OverPass keeps about you, and for how long.', `
<header class="page"><h1>Privacy</h1><p>What OverPass and this site keep, and for how long.</p></header>
<section>
  <h2>Accounts</h2>
  <p>Signing in with Google gives this site an ID for you that means nothing elsewhere. It's stored with the username you choose and the date. Your e-mail and name aren't requested, and nothing comes from your Google profile.</p>
  <p>You can add a picture on your account page. It's public next to your comments, shrunk before it's sent, and gone as soon as you replace or remove it, or delete your account. Admins can remove it.</p>
  <p>A cookie keeps you signed in for 90 days. It's the only cookie here, apart from a short-lived one while you sign in. There's no tracking and no advertising.</p>
  <p>You can delete your account on <a href="/account">its page</a>. It's removed at once, with your picture and comments.</p>
</section>
<section>
  <h2>Comments</h2>
  <p>A comment is public on the game's page, with your username and the date. You can delete your own at any time.</p>
  <p>Signed-in people can report a comment or a rating. Three reports hide it until it's reviewed. Who reported what is never shown, and it's removed when the report is settled or the account is deleted.</p>
</section>
<section>
  <h2>Ratings from the app</h2>
  <p>A rating is public on the game's page: the medal, your comment, the frame rate of the last run, your OverPass, Wine and Runtime versions, your Mac's chip and your macOS version. A random ID for your install, never shown, lets a new rating replace your last one. Ratings aren't tied to an account.</p>
  <p>OverPass admins can also rate a game on its page. Those ratings are marked as an admin's and go with the admin's account.</p>
  <p>If you share your settings, they wait for an admin along with your comment and versions. Approved settings become public in the game's profile on GitHub, without your comment or anything that says who sent them.</p>
</section>
<section>
  <h2>Logs and reports</h2>
  <p>Logs are only sent when you choose to. They file a public issue on <a href="${REPOSITORY}/issues">GitHub</a>, and the log and any screenshot are kept for 180 days. Your name, home folder, computer name and e-mail addresses are taken out first. The report service counts reports per network address to limit abuse, and those counts are gone within two hours.</p>
</section>
<section>
  <h2>Game art</h2>
  <p>Covers and banners load directly from where they're published, such as Steam, GOG or TheGamesDB, so your browser or the app connects to those services to show them.</p>
  <p>To find a cover, the app sends this site the title's store ID and name, and nothing about you or your install. A title the site hasn't seen is added to the list it looks up art for.</p>
</section>
<section>
  <h2>Who runs this</h2>
  <p>OverPass is made by <a href="https://arctim.no">Arctic Imaginarium</a>. The site runs on Cloudflare. For a question or to have something removed, open an <a href="${REPOSITORY}/issues">issue</a>.</p>
</section>`, moderator);

const missingPage = () => shell('Game not found · OverPass', 'This game has no page yet.', `
<header class="page"><h1>No page for this game yet</h1><p><a href="/games">See all games</a></p></header>`);
const failedPage = () => shell('Something went wrong · OverPass', 'The games list could not be loaded.', `
<header class="page"><h1>Something went wrong</h1><p>The games list could not be loaded. Try again in a moment.</p></header>`);

const html = (body, status = 200) => new Response(body, {
  status, headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'public, max-age=60' },
});

/// A page that depends on who's asking: never cached.
const personal = (body) => new Response(body, {
  headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store', 'X-Frame-Options': 'DENY' },
});

const json = (value, status = 200) => new Response(JSON.stringify(value), {
  status,
  headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*', 'Cache-Control': status === 200 ? 'public, max-age=60' : 'no-store' },
});
