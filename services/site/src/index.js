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
//   GET  /auth/email, POST /auth/email/(signin|signup|reset)   sign-in with an address, a password and a mailed code
//   GET  /auth/email/code, POST /auth/email/code   typing that code (secret EMAIL_KEY; MAIL_URL, secret MAIL_TOKEN)
//   GET  /account                the signed-in person's page
//   POST /account, /account/delete, /auth/signout   change the name, delete the account, sign out
//   POST /account/picture, /account/picture/delete   set or remove one's picture; GET /pictures/<key>.jpg
//   POST /games/<id>/comments, /games/<id>/comments/<comment>/delete   add a comment or reply, delete one's own
//   POST /games/<id>/comments/<comment>/vote   upvote a comment, or take that back
//   POST /games/<id>/(comments|ratings)/<entry>/report   report one; three people reporting it hides it
//   GET  /moderation, POST /moderation/(comments|ratings)/<entry>/(hide|show)   for Admins and Mods
//   POST /moderation/mods, /moderation/mods/<user>/remove   Admins make an account a Mod, or stop it being one
//   POST /games/<id>/ratings, /games/<id>/ratings/delete   the same accounts rate a game on its page, or take that back
//   POST /moderation/pictures/<key>/remove       the same accounts take a person's picture down
//   POST /moderation/suggestions/<entry>/(approve|reject)   Admins decide on a suggested profile
//   GET  /api/art                what find-covers.mjs needs for each game; needs the SYNC_TOKEN secret
//   POST /api/art                { id, links, source, cover, thumb, icon, hero } from the same script; the same secret
//   GET  /api/art/<store>/<id>?name=   the art the app shows; a title not seen before joins the queue for find-covers.mjs
//   POST /games/<id>/cover, /games/<id>/cover/url, /games/<id>/cover/reset   a moderator changes a game's cover
//   GET  /pictures/covers/<file>  a moderator's upload
//   GET  /api/profiles           the signed set of profiles the app downloads
//   POST /api/profiles           { serial, body } from publish-profiles.mjs; needs the SYNC_TOKEN secret
//   GET  /api/suggestions        the approved suggestions, for publish-profiles.mjs; needs the SYNC_TOKEN secret
//   POST /api/suggestions        { published, refused }: lists of their IDs, from the same script; the same secret
//   GET  /report/<ticket>        finish a rating the app started; POST sends it through the report relay
//   POST /account/public         Public Contributor or Member: whether one's name shows on one's ratings
//   GET  /privacy                what's kept, and for how long
//
// An account holds the provider's ID for the person, the username they choose and a picture if they add one, nothing
// else: no e-mail, no name from Google. An e-mail account's ID is a keyed hash of the address, so the address itself
// is never kept: it's typed at each sign-in, the code goes to what was typed. A session is a random token in a cookie;
// the database keeps only its hash.
// Pictures are small JPEGs, cropped and shrunk in the browser, in the PICTURES store.
//
// This site can't change what people's Macs get. Approve marks a suggested profile and nothing more: a GitHub workflow
// reads the approved ones, checks them itself, commits them to profiles/ and signs the whole set with a key that's only
// on GitHub (publish-profiles.mjs). The set is stored here for downloading; the app checks its signature.

import { profileProblems, storeName } from './profile-check.js';
import { addressHash, checkPassword, cleanAddress, cleanCode, codeHash, hashPassword, newCode, same, validAddress, validPassword } from './email-auth.js';

const TIERS = ['platinum', 'gold', 'silver', 'bronze', 'borked'];
const TITLES = { platinum: 'Platinum', gold: 'Gold', silver: 'Silver', bronze: 'Bronze', borked: 'Borked' };
const REPOSITORY = 'https://github.com/McKack/overpass';

export default {
  async fetch(request, env, context) {
    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, '') || '/';
    try {
      if (path === '/api/sync' && request.method === 'POST') return await sync(request, env);
      if (path === '/api/profiles' && request.method === 'POST') return await storeProfiles(request, env);
      if (path === '/api/suggestions' && request.method === 'POST') return await settleSuggestions(request, env);
      if (path === '/api/art' && request.method === 'POST') return await storeArt(request, env);
      const commented = path.match(/^\/games\/([a-z0-9-]+)\/comments(?:\/([0-9a-f-]+)\/(delete|vote))?$/);
      const reported = path.match(/^\/games\/([a-z0-9-]+)\/(comments|ratings)\/([0-9a-f-]+)\/report$/);
      const moderated = path.match(/^\/moderation\/(comments|ratings)\/([0-9a-f-]+)\/(hide|show)$/);
      const rated = path.match(/^\/games\/([a-z0-9-]+)\/ratings(\/delete)?$/);
      const unpictured = path.match(/^\/moderation\/pictures\/([0-9a-f-]+)\/remove$/);
      const decided = path.match(/^\/moderation\/suggestions\/([0-9a-f-]+)\/(approve|reject)$/);
      const modded = path.match(/^\/moderation\/mods(?:\/([0-9a-f-]+)\/remove)?$/);
      const covered = path.match(/^\/games\/([a-z0-9-]+)\/cover(?:\/(url|reset))?$/);
      const ticket = path.match(/^\/report\/([0-9a-f]{64})$/);
      if (ticket && request.method === 'POST') {
        if (request.headers.get('Origin') !== url.origin) return html(failedPage(), 403);
        return await sendReport(request, env, ticket[1], await signedIn(request, env));
      }
      if (request.method === 'POST' && path.startsWith('/auth/email/')) {
        if (request.headers.get('Origin') !== url.origin) return html(failedPage(), 403);
        return await emailPost(request, env, context, path.slice('/auth/email/'.length));
      }
      if (request.method === 'POST' && (commented || reported || moderated || rated || unpictured || decided || modded || covered
        || ['/account', '/account/delete', '/account/picture', '/account/picture/delete', '/account/public', '/auth/signout'].includes(path))) {
        // Only this site's own forms.
        if (request.headers.get('Origin') !== url.origin) return html(failedPage(), 403);
        if (path === '/auth/signout') return await signOut(request, env);
        const user = await signedIn(request, env);
        if (!user) return redirect('/account');
        if (reported) return await report(env, user, ...reported.slice(1));
        if (moderated) return isModerator(env, user) ? await review(env, ...moderated.slice(1)) : redirect('/account');
        if (unpictured) return isModerator(env, user) ? await takeDownPicture(env, unpictured[1]) : redirect('/account');
        if (decided) return isAdmin(user) ? await decide(env, ...decided.slice(1)) : redirect('/account');
        if (modded) return isAdmin(user) ? await changeMods(request, env, modded[1]) : redirect('/account');
        if (covered) return isModerator(env, user) ? await changeCover(request, env, covered[1], covered[2]) : redirect('/account');
        if (rated) {
          if (!isModerator(env, user)) return redirect('/account');
          return rated[2] ? await deleteOwnRating(env, user, rated[1]) : await addOwnRating(request, env, user, rated[1]);
        }
        if (commented) {
          if (commented[3] === 'vote') return await vote(env, user, commented[1], commented[2]);
          return commented[2] ? await deleteComment(env, user, commented[1], commented[2]) : await addComment(request, env, user, commented[1]);
        }
        if (path === '/account/picture') return await savePicture(request, env, user);
        if (path === '/account/picture/delete') return await deletePicture(env, user);
        if (path === '/account/public') return await setPublic(request, env, user);
        return path === '/account' ? await rename(request, env, user) : await deleteAccount(env, user);
      }
      if (request.method === 'GET' || request.method === 'HEAD') {
        const picture = path.match(/^\/pictures\/([0-9a-f-]+)\.jpg$/);
        if (picture) return await servePicture(env, picture[1]);
        const art = path.match(/^\/pictures\/covers\/([0-9a-f]{32}\.(?:avif|jpg))$/);
        if (art) return await serveCover(request, env, art[1]);
        if (path === '/auth/google') return await startGoogle(url, env);
        if (path === '/auth/google/callback') return await finishGoogle(request, url, env);
        if (path === '/auth/email') return personal(emailPage(url.searchParams.get('mode'), url.searchParams.get('error'), localPath(url.searchParams.get('next'))));
        if (path === '/auth/email/code') return await codePageFor(request, env, url);
        if (path === '/account') {
          const user = await signedIn(request, env);
          return personal(accountPage(user, url.searchParams.get('error'), isModerator(env, user), localPath(url.searchParams.get('next'))));
        }
        if (path === '/moderation') {
          const user = await signedIn(request, env);
          if (!isModerator(env, user)) return redirect('/account');
          return personal(moderationPage(await queue(env), isAdmin(user) ? await suggestions(env) : null, isAdmin(user) ? await mods(env) : null, url.searchParams.get('error')));
        }
        if (path === '/privacy') {
          const moderator = isModerator(env, await signedIn(request, env));
          return (moderator ? personal : html)(privacyPage(moderator));
        }
        if (ticket) return await showReport(env, ticket[1], await signedIn(request, env));
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
    art: picture(game), brand: game.brand ?? null, color: game.color ?? game.brand ?? null, icon: game.icon ?? null, stores: storeLinks(game),
  };
}

/// A moderator's upload from here, or the address of the smallest cover the source has.
function picture(game) {
  return game.art ? `/pictures/covers/${game.art}` : game.thumb ?? game.origin ?? null;
}

async function list(env) {
  const [{ results }, rated] = await Promise.all([
    env.DB.prepare(
      `SELECT g.id, g.name, g.category, g.source, g.steam, g.verified, g.links, g.brand, g.color, a.file AS art, a.thumb, a.origin, a.icon, a.links AS found
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
      `SELECT r.id, r.tier, r.comment, r.chip, r.macos, r.overpass, r.wine, r.runtime, r.backend, r.fps, r.created_at, ${badgeOf('u')},
         CASE WHEN u.public = 1 THEN u.name END AS author, CASE WHEN u.public = 1 THEN u.picture END AS author_picture
       FROM ratings r LEFT JOIN users u ON u.id = r.user_id
       WHERE r.game_id = ? AND r.hidden = 0 ORDER BY r.created_at DESC LIMIT 100`,
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
      `INSERT INTO games (id, name, category, source, verified, notes, profile_file, profile_text, presets, steam, gog, links, brand, color, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT (id) DO UPDATE SET name = excluded.name, category = excluded.category, source = excluded.source,
         verified = excluded.verified, notes = excluded.notes, profile_file = excluded.profile_file,
         profile_text = excluded.profile_text, presets = excluded.presets, steam = excluded.steam, gog = excluded.gog,
         links = excluded.links, brand = excluded.brand, color = excluded.color`,
    ).bind(game.id, game.name, game.category, game.source, game.verified, game.notes, game.profile_file, game.profile_text,
      JSON.stringify(game.presets), game.steam, game.gog, JSON.stringify(game.links ?? []), game.brand ?? null, game.color ?? null, now));
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
    `SELECT users.id, users.name, users.picture, users.public, users.role, users.provider FROM sessions JOIN users ON users.id = sessions.user_id WHERE sessions.token_hash = ? AND sessions.expires_at > ?`,
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
  return redirect(localPath(decodeURIComponent(next.join('.'))), clear, await newSession(env, user));
}

/// Stores a new session and gives back the cookie that holds it.
async function newSession(env, user) {
  const token = randomToken(), now = Date.now();
  await env.DB.batch([
    env.DB.prepare('DELETE FROM sessions WHERE expires_at <= ?').bind(now),
    env.DB.prepare('INSERT INTO sessions (token_hash, user_id, expires_at) VALUES (?, ?, ?)')
      .bind(await hashed(token), user, now + SESSION_SECONDS * 1000),
  ]);
  return setCookie('overpass_session', token, SESSION_SECONDS);
}

const CODE_SECONDS = 600;
const CODE_TRIES = 5;
const HOUR = 3600 * 1000;
// Per hour. Asking for a code counts whether or not a mail goes out, so a limit says nothing about who has an account.
const LIMITS = { address: 5, ip: 15, wrong: 10 };

/// True when this attempt is within its limit, and counts it.
async function within(env, kind, value) {
  const key = `${kind}:${await addressHash(env, value)}`, now = Date.now();
  const count = await env.DB.prepare('SELECT COUNT(*) AS count FROM email_attempts WHERE key = ? AND at > ?').bind(key, now - HOUR).first('count');
  if (count >= LIMITS[kind]) return false;
  await env.DB.batch([
    env.DB.prepare('DELETE FROM email_attempts WHERE at <= ?').bind(now - 24 * HOUR),
    env.DB.prepare('INSERT INTO email_attempts (key, at) VALUES (?, ?)').bind(key, now),
  ]);
  return true;
}

async function sendMail(env, to, kind, code) {
  const answer = await fetch(env.MAIL_URL, {
    method: 'POST',
    headers: { Authorization: `Bearer ${env.MAIL_TOKEN}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ to, kind, code }),
  });
  if (!answer.ok) console.error(`Mail failed: ${answer.status}`);
}

/// Everything sign-up and reset show is the same with or without an account, so these never tell which it is. The mail
/// goes after the answer, so the time taken doesn't tell either. A row is made even when nobody will get its code.
async function askForCode(env, context, purpose, address, hash, mailed, password, next) {
  const token = randomToken(), code = newCode(), now = Date.now();
  await env.DB.batch([
    env.DB.prepare('DELETE FROM email_codes WHERE expires_at <= ? OR (address_hash = ? AND purpose = ?)').bind(now, hash, purpose),
    env.DB.prepare('INSERT INTO email_codes (token_hash, purpose, address_hash, code_hash, password, next, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)')
      .bind(await hashed(token), purpose, hash, await codeHash(env, token, code), password, next, now + CODE_SECONDS * 1000),
  ]);
  if (mailed) context.waitUntil(sendMail(env, address, mailed, mailed === 'exists' ? undefined : code).catch((error) => console.error(`Mail failed: ${error.message}`)));
  return redirect('/auth/email/code', setCookie('overpass_email', token, CODE_SECONDS));
}

async function emailPost(request, env, context, step) {
  const form = await request.formData();
  if (step === 'code') return await enterCode(request, env, form);
  if (!['signin', 'signup', 'reset'].includes(step)) return html(failedPage(), 404);
  const next = localPath(form.get('next'));
  const back = (error) => redirect(`/auth/email?mode=${step}&error=${error}&next=${encodeURIComponent(next)}`);
  const address = cleanAddress(form.get('address')), password = form.get('password');
  if (!validAddress(address)) return back('address');
  if (step !== 'reset' && !validPassword(password)) return back(step === 'signup' ? 'password' : 'wrong');
  const ip = request.headers.get('CF-Connecting-IP') || 'unknown';
  const hash = await addressHash(env, address);
  const account = await env.DB.prepare('SELECT password FROM users WHERE provider = ? AND provider_id = ?').bind('email', hash).first();

  if (step === 'signin') {
    const wrongs = await env.DB.prepare('SELECT COUNT(*) AS count FROM email_attempts WHERE key = ? AND at > ?').bind(`wrong:${hash}`, Date.now() - HOUR).first('count');
    if (wrongs >= LIMITS.wrong) return back('busy');
    if (!await checkPassword(env, password, account?.password) || !account) {
      await env.DB.prepare('INSERT INTO email_attempts (key, at) VALUES (?, ?)').bind(`wrong:${hash}`, Date.now()).run();
      return back('wrong');
    }
  }
  if (!await within(env, 'address', address) || !await within(env, 'ip', ip)) return back('busy');
  if (step === 'signin') return await askForCode(env, context, step, address, hash, 'signin', null, next);
  if (step === 'reset') return await askForCode(env, context, step, address, hash, account ? 'reset' : null, null, next);
  return await askForCode(env, context, step, address, hash, account ? 'exists' : 'signup', account ? null : await hashPassword(env, password), next);
}

const waitingCode = async (request, env) => {
  const token = cookie(request, 'overpass_email');
  if (!token) return null;
  const row = await env.DB.prepare('SELECT * FROM email_codes WHERE token_hash = ? AND expires_at > ?').bind(await hashed(token), Date.now()).first();
  return row && { ...row, token };
};

async function codePageFor(request, env, url) {
  const row = await waitingCode(request, env);
  if (!row) return redirect('/auth/email?error=expired');
  return personal(codePage(row.purpose, url.searchParams.get('error')));
}

async function enterCode(request, env, form) {
  const row = await waitingCode(request, env);
  const gone = setCookie('overpass_email', '', 0);
  if (!row) return redirect('/auth/email?error=expired', gone);
  const remove = env.DB.prepare('DELETE FROM email_codes WHERE token_hash = ?').bind(row.token_hash);
  if (!same(await codeHash(env, row.token, cleanCode(form.get('code'))), row.code_hash)) {
    if (row.tries + 1 >= CODE_TRIES) {
      await remove.run();
      return redirect('/auth/email?error=expired', gone);
    }
    await env.DB.prepare('UPDATE email_codes SET tries = tries + 1 WHERE token_hash = ?').bind(row.token_hash).run();
    return redirect('/auth/email/code?error=code');
  }
  const password = form.get('password');
  if (row.purpose === 'reset' && !validPassword(password)) return redirect('/auth/email/code?error=password');
  await remove.run();

  let user;
  if (row.purpose === 'signup') {
    user = crypto.randomUUID();
    const made = await env.DB.prepare('INSERT OR IGNORE INTO users (id, provider, provider_id, created_at, password) VALUES (?, ?, ?, ?, ?)')
      .bind(user, 'email', row.address_hash, Date.now(), row.password).run();
    if (!made.meta.changes) return redirect('/auth/email?error=expired', gone);
  } else {
    user = await env.DB.prepare('SELECT id FROM users WHERE provider = ? AND provider_id = ?').bind('email', row.address_hash).first('id');
    if (!user) return redirect('/auth/email?error=expired', gone);
  }
  if (row.purpose === 'reset') {
    // A new password puts out anyone who got in with the old one.
    await env.DB.batch([
      env.DB.prepare('UPDATE users SET password = ? WHERE id = ?').bind(await hashPassword(env, password), user),
      env.DB.prepare('DELETE FROM sessions WHERE user_id = ?').bind(user),
    ]);
  }
  return redirect(localPath(row.next), gone, await newSession(env, user));
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

async function setPublic(request, env, user) {
  const choice = (await request.formData()).get('public') === '1' ? 1 : 0;
  await env.DB.prepare('UPDATE users SET public = ? WHERE id = ?').bind(choice, user.id).run();
  return redirect('/account');
}

async function deleteAccount(env, user) {
  if (user.picture) await env.PICTURES.delete(user.picture);
  await env.DB.batch([
    env.DB.prepare('DELETE FROM sessions WHERE user_id = ?').bind(user.id),
    env.DB.prepare('DELETE FROM reports WHERE user_id = ?1 OR target IN (SELECT id FROM comments WHERE user_id = ?1) OR target IN (SELECT id FROM ratings WHERE install = ?2)')
      .bind(user.id, accountRater(user)),
    env.DB.prepare('DELETE FROM votes WHERE user_id = ?1 OR comment_id IN (SELECT id FROM comments WHERE user_id = ?1)').bind(user.id),
    env.DB.prepare('UPDATE comments SET parent_id = NULL WHERE parent_id IN (SELECT id FROM comments WHERE user_id = ?)').bind(user.id),
    env.DB.prepare('DELETE FROM comments WHERE user_id = ?').bind(user.id),
    env.DB.prepare('DELETE FROM ratings WHERE install = ?').bind(accountRater(user)),
    env.DB.prepare('UPDATE ratings SET user_id = NULL WHERE user_id = ?').bind(user.id),
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

/// A hidden comment still shows to the person who wrote it, so they can delete it. Most upvoted first, each with its
/// replies in the order they were written. A reply whose comment isn't shown stands on its own.
async function comments(env, id, user) {
  const { results } = await env.DB.prepare(
    `SELECT comments.id, comments.parent_id, comments.user_id, comments.body, comments.hidden, comments.created_at, users.name, users.picture, ${badgeOf('users')},
       (SELECT COUNT(*) FROM votes WHERE comment_id = comments.id) AS votes,
       EXISTS (SELECT 1 FROM votes WHERE comment_id = comments.id AND user_id = ?2) AS voted
     FROM comments JOIN users ON users.id = comments.user_id WHERE comments.game_id = ?1 AND (comments.hidden = 0 OR comments.user_id = ?2)
     ORDER BY comments.created_at DESC LIMIT 500`,
  ).bind(id, user?.id ?? null).all();
  const shown = new Map(results.map((comment) => [comment.id, { ...comment, replies: [] }]));
  const top = [];
  for (const comment of shown.values()) {
    const parent = shown.get(comment.parent_id);
    if (parent) parent.replies.unshift(comment); else top.push(comment);
  }
  return top.sort((a, b) => b.votes - a.votes || b.created_at - a.created_at);
}

/// Replies go one level deep: a reply to a reply joins the same comment.
async function addComment(request, env, user, id) {
  const back = `/games/${id}`;
  const exists = await env.DB.prepare('SELECT id FROM games WHERE id = ?').bind(id).first('id');
  if (!exists) return html(missingPage(), 404);
  if (!user.name) return redirect('/account');
  const form = await request.formData();
  const body = String(form.get('body') || '').replace(/\r\n/g, '\n').trim();
  if (!body || body.length > COMMENT_LENGTH) return redirect(`${back}?error=comment#comments`);
  const answered = form.get('parent')
    ? await env.DB.prepare('SELECT id, parent_id FROM comments WHERE id = ? AND game_id = ?').bind(String(form.get('parent')), id).first()
    : null;
  if (form.get('parent') && !answered) return redirect(`${back}?error=gone#comments`);
  const now = Date.now();
  const today = await env.DB.prepare('SELECT COUNT(*) AS n FROM comments WHERE user_id = ? AND created_at > ?')
    .bind(user.id, now - 24 * 3600 * 1000).first('n');
  if (today >= COMMENTS_A_DAY) return redirect(`${back}?error=limit#comments`);
  const comment = crypto.randomUUID();
  await env.DB.prepare('INSERT INTO comments (id, game_id, parent_id, user_id, body, created_at) VALUES (?, ?, ?, ?, ?, ?)')
    .bind(comment, id, answered ? answered.parent_id ?? answered.id : null, user.id, body, now).run();
  return redirect(`${back}#comment-${comment}`);
}

/// Its replies stay, as comments of their own.
async function deleteComment(env, user, id, comment) {
  const { meta } = await env.DB.prepare('DELETE FROM comments WHERE id = ? AND user_id = ?').bind(comment, user.id).run();
  if (meta.changes) {
    await env.DB.batch([
      env.DB.prepare('DELETE FROM reports WHERE target = ?').bind(comment),
      env.DB.prepare('DELETE FROM votes WHERE comment_id = ?').bind(comment),
      env.DB.prepare('UPDATE comments SET parent_id = NULL WHERE parent_id = ?').bind(comment),
    ]);
  }
  return redirect(`/games/${id}#comments`);
}

/// One upvote per account, not on one's own comment or a hidden one. Pressing again takes it back.
async function vote(env, user, id, comment) {
  const anchor = `/games/${id}#comment-${comment}`;
  const target = await env.DB.prepare('SELECT user_id FROM comments WHERE id = ? AND game_id = ? AND hidden = 0').bind(comment, id).first();
  if (!target || target.user_id === user.id) return redirect(anchor);
  const { meta } = await env.DB.prepare('DELETE FROM votes WHERE comment_id = ? AND user_id = ?').bind(comment, user.id).run();
  if (!meta.changes) await env.DB.prepare('INSERT OR IGNORE INTO votes (comment_id, user_id, created_at) VALUES (?, ?, ?)').bind(comment, user.id, Date.now()).run();
  return redirect(anchor);
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
    env.DB.prepare('INSERT INTO ratings (id, game_id, tier, comment, install, user_id, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)')
      .bind(crypto.randomUUID(), id, tier, comment || null, accountRater(user), user.id, Date.now()),
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

const isAdmin = (user) => user?.role === 'admin';
const isModerator = (env, user) => isAdmin(user) || user?.role === 'mod';

/// The badge a person shows. An Admin who chooses to be a Member shows as a Mod.
const badgeOf = (users) => `CASE WHEN ${users}.role = 'admin' AND ${users}.public = 1 THEN 'Admin' WHEN ${users}.role IN ('admin', 'mod') THEN 'Mod' END AS badge`;

async function mods(env) {
  const { results } = await env.DB.prepare("SELECT id, name, picture FROM users WHERE role = 'mod' ORDER BY name COLLATE NOCASE").all();
  return results;
}

/// Only ever between no role and Mod: this can't touch an Admin, or make one.
async function changeMods(request, env, id) {
  if (id) {
    await env.DB.prepare("UPDATE users SET role = NULL WHERE id = ? AND role = 'mod'").bind(id).run();
    return redirect('/moderation#mods');
  }
  const name = String((await request.formData()).get('name') || '').trim();
  const made = await env.DB.prepare("UPDATE users SET role = 'mod' WHERE name = ? COLLATE NOCASE AND role IS NULL").bind(name).run();
  return redirect(made.meta.changes ? '/moderation#mods' : '/moderation?error=mod#mods');
}

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
const roleBadge = (title) => (title ? `<span class="role">${escape(title)}</span>` : '');
const hue = (name) => [...name].reduce((sum, c) => (sum * 31 + c.charCodeAt(0)) % 360, 7);
/// Words first, split at anything that isn't a letter or digit, then a capital after a small letter inside one word:
/// Super!Blast and MusicBee give two letters, Musicbee and DOOM one. The same rule as `initials` in the app's HomeView.
function initials(name) {
  const words = name.replace(/['’]/g, '').split(/[^\p{L}\p{N}]+/u).filter(Boolean);
  const parts = words.length === 1 ? words[0].split(/(?<=\p{Ll})(?=\p{Lu})/u) : words;
  return parts.slice(0, 2).map((word) => [...word][0]).join('').toUpperCase() || '?';
}

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

/// The game's cover. Under it, and when there's none, a cover made the way the app makes one: a mark over a frosted
/// blur of itself, on the game's colour. The mark is the game's icon, a launcher's logo or the name's initials.
function cover(game) {
  const hex = /^[0-9a-f]{6}$/i.test(game.color ?? '') ? game.color : null;
  const logo = /^[0-9a-f]{6}$/i.test(game.brand ?? '');
  const art = !logo && game.art ? `<img class="art" src="${escape(game.art)}" alt="" loading="lazy" referrerpolicy="no-referrer" onerror="this.remove()">` : '';
  const icon = (name) => `<img class="${name}" src="${escape(game.icon)}" alt="" loading="lazy" referrerpolicy="no-referrer">`;
  const letters = (name) => `<span class="${name}">${escape(initials(game.name))}</span>`;
  const mark = (name) => {
    // In a wrapper: a browser masks after it filters, so a blur on the logo itself would stay sharp.
    if (logo) return `<b class="${name}"><i></i></b>`;
    return game.icon ? icon(name) : letters(name);
  };
  const paint = hex ? `--brand:#${hex};--ink:${ink(hex)}` : `--hue:${hue(game.name)}`;
  return `<div class="cover${hex ? ' tinted' : ''}" style="${paint}${logo ? `;--logo:url(/logos/${game.id}.svg)` : ''}">${art ? '' : mark('frost')}${mark('mark')}${art}</div>`;
}

/// `tab` is the header's tab this page belongs to.
function shell(title, description, body, moderator = false, tab = null) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escape(title)}</title>
<meta name="description" content="${escape(description)}">
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<link rel="stylesheet" href="/cards.css">
<link rel="stylesheet" href="/nav.css">
<link rel="stylesheet" href="/games.css">
<script src="/nav.js" defer></script>
</head>
<body>
<nav class="top">
  <a class="home" href="/" aria-label="OverPass"><img src="/icon.svg" alt=""></a>
  <div class="tabs"><a href="/">OverPass</a><a href="/games"${tab === 'games' ? ' aria-current="page"' : ''}>Games</a></div>
  <div class="side">
    ${moderator ? `<a class="round" href="/moderation" aria-label="Moderation" title="Moderation"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 2 4 5v6c0 5 3.400 9.300 8 11 4.600-1.700 8-6 8-11V5l-8-3Zm-1.100 14-3.600-3.600 1.400-1.400 2.200 2.200 4.800-4.800 1.400 1.400-6.200 6.200Z"/></svg></a>` : ''}
    <a class="round" href="/account" aria-label="Account" title="Account"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20Zm0 4a3.500 3.500 0 1 1 0 7 3.500 3.500 0 0 1 0-7Zm0 14a8 8 0 0 1-6-2.700C6.900 15.600 9.300 15 12 15s5.100.6 6 2.300A8 8 0 0 1 12 20Z"/></svg></a>
    <a class="get" href="${REPOSITORY}/releases/latest"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3a1 1 0 0 1 1 1v9.59l3.3-3.3a1 1 0 1 1 1.4 1.42l-5 5a1 1 0 0 1-1.4 0l-5-5a1 1 0 1 1 1.4-1.42l3.3 3.3V4a1 1 0 0 1 1-1Zm-8 15a1 1 0 0 1 1 1v1h14v-1a1 1 0 1 1 2 0v2a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1v-2a1 1 0 0 1 1-1Z"/></svg><span>Download</span></a>
  </div>
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
</script>`, moderator, 'games');
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
    rating.fps && `${Math.round(rating.fps)} fps`,
  ].filter(Boolean);
  return `<article class="rating" id="rating-${rating.id}">
  <div class="line">${medal(rating.tier)}${rating.author || rating.badge ? `<span class="who author">${rating.author ? `${avatar(rating.author, rating.author_picture)}${escape(rating.author)}` : ''}${roleBadge(rating.badge)}</span>` : ''}<time datetime="${new Date(rating.created_at).toISOString()}">${date(rating.created_at)}</time></div>
  ${rating.comment ? `<p class="comment">${escape(rating.comment)}</p>` : ''}
  <p class="facts">${facts.map((fact) => `<span>${escape(fact)}</span>`).join('')}</p>
  ${rating.id === own?.id ? '' : reportButton(game, 'ratings', rating.id, user, reports)}
</article>`;
}

/// A count anyone can see; pressing it needs an account, and it's not for one's own comment or a hidden one.
function voteButton(game, comment, user) {
  const back = encodeURIComponent(`/games/${game.id}#comment-${comment.id}`);
  const label = `<span>${comment.votes}</span>`;
  if (!user) return `<a class="vote" href="/account?next=${back}" aria-label="Sign in to upvote, ${comment.votes} so far">${label}</a>`;
  if (comment.user_id === user.id || comment.hidden) return `<span class="vote" aria-label="${comment.votes} upvotes">${label}</span>`;
  return `<form method="post" action="/games/${game.id}/comments/${comment.id}/vote"><button class="vote" type="submit" aria-label="Upvote" aria-pressed="${Boolean(comment.voted)}">${label}</button></form>`;
}

function replyForm(game, comment, user) {
  const back = encodeURIComponent(`/games/${game.id}#comment-${comment.id}`);
  if (!user) return `<a class="link" href="/account?next=${back}">Reply</a>`;
  if (!user.name) return '<a class="link" href="/account">Reply</a>';
  return `<details><summary>Reply</summary><form class="write" method="post" action="/games/${game.id}/comments">
  <input type="hidden" name="parent" value="${comment.id}">
  <label for="reply-${comment.id}">Reply as ${escape(user.name)}</label>
  <textarea id="reply-${comment.id}" name="body" rows="2" required maxlength="${COMMENT_LENGTH}"></textarea>
  <button class="button" type="submit">Post Reply</button>
</form></details>`;
}

function commentCard(game, comment, user, reports) {
  const mine = comment.user_id === user?.id;
  return `<article class="rating" id="comment-${comment.id}">
  <div class="line"><span class="who">${avatar(comment.name, comment.picture)}${escape(comment.name)}${roleBadge(comment.badge)}</span><time datetime="${new Date(comment.created_at).toISOString()}">${date(comment.created_at)}</time></div>
  <p class="comment">${escape(comment.body)}</p>
  ${comment.hidden ? '<p class="muted">Hidden after reports. Only you can see this.</p>' : ''}
  <div class="answers">
    ${voteButton(game, comment, user)}
    ${replyForm(game, comment, user)}
    ${mine ? `<form method="post" action="/games/${game.id}/comments/${comment.id}/delete"><button class="link" type="submit">Delete</button></form>` : reportButton(game, 'comments', comment.id, user, reports)}
  </div>
  ${comment.replies?.length ? `<div class="replies">${comment.replies.map((reply) => commentCard(game, reply, user, reports)).join('\n')}</div>` : ''}
</article>`;
}

function commentForm(game, user) {
  const back = encodeURIComponent(`/games/${game.id}#comments`);
  if (!user) return `<p><a class="button quiet" href="/account?next=${back}">Sign in to comment</a></p>`;
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

/// The draft a ticket opens, while it's waiting.
async function draftFor(env, ticket) {
  const hash = [...new Uint8Array(await sha256(ticket))].map((byte) => byte.toString(16).padStart(2, '0')).join('');
  return env.DB.prepare('SELECT * FROM drafts WHERE ticket_hash = ? AND expires_at > ?').bind(hash, Date.now()).first();
}

/// How many ratings from this Mac aren't on an account yet.
const unlinked = (env, install) => env.DB.prepare('SELECT COUNT(*) AS n FROM ratings WHERE install = ? AND user_id IS NULL').bind(install).first('n');

async function showReport(env, ticket, user, sent = {}) {
  const draft = await draftFor(env, ticket);
  if (!draft) return ticketed(reportGonePage(), 410);
  const earlier = user && draft.install ? await unlinked(env, draft.install) : 0;
  return ticketed(reportPage(ticket, draft, user, earlier, isModerator(env, user), sent));
}

/// The relay does the sending: it holds the logs and the key to GitHub, and the ticket is all it needs. Its public address
/// goes along, since the links in an issue are made from it.
async function sendReport(request, env, ticket, user) {
  const form = await request.formData();
  const tier = String(form.get('tier') ?? ''), comment = String(form.get('comment') ?? '');
  const anonymous = form.get('as') === 'anonymous', linking = form.get('link') === '1';
  // The relay deletes the draft, and it's the draft that shows this person's Mac is theirs.
  const install = (await draftFor(env, ticket))?.install;
  const sent = await env.RELAY.fetch(`${env.REPORT_RELAY}/draft/${ticket}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ tier, comment }),
  });
  const answer = await sent.json().catch(() => ({}));
  if (sent.ok && answer.url) {
    if (user && install) {
      // The relay has no say in this: the ticket proves the Mac, the session proves the person, and only this site has both.
      const newest = await env.DB.prepare('SELECT id FROM ratings WHERE install = ? ORDER BY created_at DESC LIMIT 1').bind(install).first('id');
      if (!anonymous && newest) await env.DB.prepare('UPDATE ratings SET user_id = ? WHERE id = ?').bind(user.id, newest).run();
      if (linking) await env.DB.prepare('UPDATE ratings SET user_id = ? WHERE install = ? AND user_id IS NULL AND id <> ?').bind(user.id, install, newest).run();
    }
    return redirect(answer.url);
  }
  return showReport(env, ticket, user, { tier, comment, anonymous, linking, error: answer.error ?? 'The report could not be sent. Try again in a moment.' });
}

const RATING_ERRORS = {
  rating: `Pick a medal. A comment has at most ${COMMENT_LENGTH} characters.`,
  low: 'Bronze and Borked need a comment saying what went wrong.',
};

const COMMENT_ERRORS = {
  comment: `A comment has 1 to ${COMMENT_LENGTH} characters.`,
  gone: 'That comment is gone, so your reply wasn\'t posted.',
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
</section>
<script>
  // Upvotes without leaving the place on the page. The form still works by itself.
  document.getElementById('comments').addEventListener('submit', (event) => {
    const button = event.target.querySelector('button.vote');
    if (!button) return;
    event.preventDefault();
    const on = button.getAttribute('aria-pressed') !== 'true', count = button.querySelector('span');
    button.setAttribute('aria-pressed', on);
    count.textContent = Number(count.textContent) + (on ? 1 : -1);
    fetch(event.target.action, { method: 'POST' }).then((answer) => { if (!answer.ok) location.reload(); }, () => location.reload());
  });
</script>`, moderator, 'games');
}

const ACCOUNT_ERRORS = {
  signin: 'Signing in didn\'t work. Try again.',
  name: 'A username has 2 to 30 letters, digits, spaces, dots, dashes or underscores, and starts with a letter or digit.',
  taken: 'That username is taken.',
  picture: 'That picture didn\'t work. Try a JPEG or PNG.',
};

const EMAIL_ERRORS = {
  address: 'That doesn\'t look like an e-mail address.',
  password: 'A password has 10 to 128 characters.',
  wrong: 'That address and password don\'t match.',
  busy: 'Too many tries. Wait an hour and try again.',
  expired: 'That code has run out. Start again.',
  code: 'That code isn\'t right. Check it and try again.',
};

/// Sign in, make an account or start a password reset. None of them shows whether an address has an account.
function emailPage(mode, error, next) {
  const step = ['signup', 'reset'].includes(mode) ? mode : 'signin';
  const [title, button, about] = {
    signin: ['Sign in with e-mail', 'Sign In', 'We\'ll mail you a code to finish.'],
    signup: ['Make an account', 'Make Account', 'We\'ll mail you a code to prove the address is yours. Only a scrambled form of it is kept, so you type it each time you sign in.'],
    reset: ['Choose a new password', 'Send Code', 'If this address has an account, we\'ll mail you a code.'],
  }[step];
  const link = (target, text) => `<a href="/auth/email?mode=${target}&next=${encodeURIComponent(next)}">${text}</a>`;
  return shell(`${title} · OverPass`, title, `
<header class="page"><h1>${title}</h1><p>${about}</p></header>
${EMAIL_ERRORS[error] ? `<p class="problem" role="alert">${EMAIL_ERRORS[error]}</p>` : ''}
<form class="account" method="post" action="/auth/email/${step}">
  <input type="hidden" name="next" value="${escape(next)}">
  <label for="address">E-mail address</label>
  <input id="address" name="address" type="email" required maxlength="254" autocomplete="email">
  ${step === 'reset' ? '' : `<label for="password">Password</label>
  <input id="password" name="password" type="password" required ${step === 'signup' ? 'minlength="10" ' : ''}maxlength="128" autocomplete="${step === 'signup' ? 'new-password' : 'current-password'}">`}
  <button class="button" type="submit">${button}</button>
</form>
<p class="muted">${step === 'signin' ? `${link('signup', 'Make an account')} · ${link('reset', 'Forgot your password?')}` : link('signin', 'Sign in instead')}</p>`);
}

function codePage(purpose, error) {
  return shell('Enter your code · OverPass', 'Enter the code we mailed you.', `
<header class="page"><h1>Check your mail</h1><p>Type the 6-character code. It works for 10 minutes, and the mail may land in spam.</p></header>
${EMAIL_ERRORS[error] ? `<p class="problem" role="alert">${EMAIL_ERRORS[error]}</p>` : ''}
<form class="account" method="post" action="/auth/email/code">
  <label for="code">Code</label>
  <input id="code" name="code" required maxlength="8" autocomplete="one-time-code" autocapitalize="characters" spellcheck="false" autofocus>
  ${purpose === 'reset' ? `<label for="password">New password</label>
  <input id="password" name="password" type="password" required minlength="10" maxlength="128" autocomplete="new-password">` : ''}
  <button class="button" type="submit">Continue</button>
</form>`);
}

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

/// `suggested` and `team` are only there for an Admin.
const moderationPage = (entries, suggested, team, error) => shell('Moderation · OverPass', 'Reported and hidden comments and ratings, and suggested profiles.', `
<header class="page"><h1>Moderation</h1><p>Reported and hidden comments and ratings${suggested ? ', suggested profiles and Mods' : ''}. Deciding clears an entry's reports.</p></header>
${suggested ? `<section>
  <h2>Suggested profiles</h2>
  ${suggested.length ? suggested.map(suggestionCard).join('\n') : '<p class="empty">None waiting.</p>'}
</section>` : ''}
<section>
  <h2>Reports</h2>
  ${entries.length ? entries.map(moderationCard).join('\n') : '<p class="empty">Nothing to look at.</p>'}
</section>
${team ? `<section id="mods">
  <h2>Mods</h2>
  ${error === 'mod' ? '<p class="problem" role="alert">No account without a role has that username.</p>' : ''}
  ${team.map((mod) => `<article class="rating"><div class="line"><span class="who">${avatar(mod.name ?? '?', mod.picture)}${escape(mod.name ?? 'No username yet')}</span><form method="post" action="/moderation/mods/${mod.id}/remove"><button class="link" type="submit">Remove</button></form></div></article>`).join('\n')}
  <form class="account" method="post" action="/moderation/mods">
    <label for="mod-name">Make a Mod, by username</label>
    <input id="mod-name" name="name" required maxlength="30" autocomplete="off">
    <button class="button" type="submit">Add Mod</button>
  </form>
</section>` : ''}`, true);

/// The top of the account page: the picture, which changes on a click, and the name, which is edited where it stands.
/// A person with no username yet only gets the name, as a picture needs a name to go with it.
function profileHeader(user) {
  const pen = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M16.500 3.500a2.100 2.100 0 0 1 3 3L8 18l-4 1 1-4Z"/></svg>';
  return `<header class="profile">
${user.name ? `<div class="portrait">
  <label title="Change Picture">
    ${avatar(user.name, user.picture)}
    <span class="upload">Upload</span>
    <input id="picture" class="hidden-input" type="file" accept="image/*" aria-label="Change Picture">
  </label>
  ${user.picture ? '<form method="post" action="/account/picture/delete"><button class="clear" type="submit" aria-label="Remove Picture" title="Remove Picture"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6l12 12M18 6 6 18"/></svg></button></form>' : ''}
</div>` : ''}
<div class="naming">
  <form class="name" method="post" action="/account">
    <h1 data-value="${escape(user.name || 'Choose a username')}"><input id="name" name="name" required minlength="2" maxlength="30" size="1" value="${escape(user.name)}" placeholder="Choose a username" aria-label="Username" autocomplete="username"${user.name ? '' : ' autofocus'}></h1>
    <label class="pen" for="name" title="Change Username">${pen}</label>
    <button class="button save" type="submit">Save</button>
  </form>
  ${user.name ? '' : '<p>This is the name others will see.</p>'}
</div>
</header>
<script>
  const field = document.getElementById('name'), saved = field.value;
  const fit = () => { field.parentElement.dataset.value = field.value || field.placeholder; };
  field.addEventListener('input', fit);
  field.addEventListener('keydown', (event) => {
    if (event.key !== 'Escape') return;
    field.value = saved;
    fit();
    field.blur();
  });
  document.getElementById('picture')?.addEventListener('change', async (event) => {
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

/// Public Contributor or Member, for every rating on the account at once.
function publicForm(user) {
  const choice = (value, title, about) => `<label><input type="radio" name="public" value="${value}"${(user.public ? 1 : 0) === value ? ' checked' : ''}> <strong>${title}</strong>: ${about}</label>`;
  return `<form class="write" method="post" action="/account/public">
  <fieldset class="choice"><legend>Your ratings</legend>
    ${choice(0, 'Member', user.role ? "your name isn't shown with your ratings, only a Mod badge" : "your ratings are on your account, and your name isn't shown with them")}
    ${choice(1, 'Public Contributor', `your username and picture are shown with your ratings${user.role ? `, with ${user.role === 'admin' ? 'an Admin' : 'a Mod'} badge` : ''}`)}
  </fieldset>
  <button class="button quiet" type="submit">Save</button>
</form>`;
}

function accountPage(user, error, moderator, next = '/account') {
  const problem = ACCOUNT_ERRORS[error] ? `<p class="problem" role="alert">${ACCOUNT_ERRORS[error]}</p>` : '';
  if (!user) {
    return shell('Sign in · OverPass', 'Sign in to OverPass.', `
<header class="page"><h1>Sign in</h1><p>An account lets you comment on game pages. You don't need one to play or to rate games from the app.</p></header>
${problem}
<p class="choices"><a class="button" href="/auth/google?next=${encodeURIComponent(next)}">Sign in with Google</a> <a class="button quiet" href="/auth/email?next=${encodeURIComponent(next)}">Sign in with E-mail</a></p>
<p class="muted">OverPass keeps the username you choose, a picture if you add one, and either Google's ID for you or a scrambled form of your address that can't be read back. Not your e-mail or name. <a href="/privacy">Privacy</a></p>`);
  }
  return shell('Your account · OverPass', 'Your OverPass account.', `
${profileHeader(user)}
${problem}
${user.name ? publicForm(user) : ''}
<div class="choices">
  <form method="post" action="/auth/signout"><button class="button quiet" type="submit">Sign Out</button></form>
  ${user.provider === 'email' ? '<a class="button quiet" href="/auth/email?mode=reset">Change Password</a>' : ''}
</div>
<section>
  <h2>Delete account</h2>
  <p class="muted">Removes your account, username, picture and comments at once. Ratings you sent from the app stay on the site, anonymous.</p>
  <form method="post" action="/account/delete"><button class="button danger" type="submit">Delete Account</button></form>
</section>`, moderator);
}

const privacyPage = (moderator) => shell('Privacy · OverPass', 'What OverPass keeps about you, and for how long.', `
<header class="page"><h1>Privacy</h1><p>What OverPass and this site keep, and for how long.</p></header>
<section>
  <h2>Accounts</h2>
  <p>Signing in with Google gives this site an ID for you that means nothing elsewhere. It's stored with the username you choose and the date. Your e-mail and name aren't requested, and nothing comes from your Google profile.</p>
  <p>Signing in with e-mail keeps a keyed hash of your address, which can't be turned back into it, and a salted hash of your password. You type your address each time, and the code goes to what you typed. The mail goes out through our web host (web23.osl1.nordkapp.net), whose mail logs show the address and when, as any mail server's do. While you sign in we keep hashes of your address and your network address for up to a day, to limit tries.</p>
  <p>You can add a picture on your account page. It's public next to your comments, shrunk before it's sent, and gone as soon as you replace or remove it, or delete your account. Admins can remove it.</p>
  <p>A cookie keeps you signed in for 90 days. It's the only cookie here, apart from a short-lived one while you sign in. There's no tracking and no advertising.</p>
  <p>You can delete your account on <a href="/account">its page</a>. It's removed at once, with your picture and comments.</p>
</section>
<section>
  <h2>Comments</h2>
  <p>A comment or reply is public on the game's page, with your username and the date. You can delete your own at any time; replies others wrote to it stay.</p>
  <p>Signed-in people can upvote a comment. The number is public. Who gave which upvote is never shown, and it's kept only so each person counts once. You can take an upvote back, and yours go when your account does.</p>
  <p>Signed-in people can report a comment or a rating. Three reports hide it until it's reviewed. Who reported what is never shown, and it's removed when the report is settled or the account is deleted.</p>
</section>
<section>
  <h2>Ratings from the app</h2>
  <p>A rating is public on the game's page: the medal, your comment, the frame rate of the last run, your OverPass, Wine and Runtime versions, your Mac's chip and your macOS version. A random ID for your install, never shown, lets a new rating replace your last one.</p>
  <p>A rating is anonymous unless you're signed in and send it from your account. As a Member your name isn't shown with your ratings; as a Public Contributor your username and picture are. You choose on your account page and can change it at any time. Deleting your account leaves your ratings on the site, anonymous.</p>
  <p>The app uploads what it knows and opens a private page where you finish the rating. What you don't send is deleted after a day.</p>
  <p>OverPass Admins and Mods can also rate a game on its page. Their ratings and comments carry a badge, and ratings made on the page go with their account.</p>
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

/// Finishing a rating. Everything here came from the app, so all of it is escaped like anything else a stranger sends.
function reportPage(ticket, draft, user, earlier, moderator, { tier, comment, anonymous, linking, error }) {
  const lines = draft.block.split('\n').slice(1).filter((line) => !line.startsWith('checksum: '));
  const fact = Object.fromEntries(lines.map((line) => line.match(/^([\w-]+): (.*)$/)?.slice(1)).filter(Boolean));
  const chosen = tier ?? fact.rating;
  const tiers = TIERS.map((value) => `<label><input type="radio" name="tier" value="${value}" required${value === chosen ? ' checked' : ''}>${medal(value)}</label>`).join('');
  const going = [
    ...(draft.log_name ? [`Your logs${draft.shot ? ' and screenshot' : ''}. They file a public issue on GitHub, with your comment.`] : []),
    ...(draft.profile ? ['Your settings for this game, for an admin to review.'] : []),
  ];
  return shell(`How did ${fact.app} run? · OverPass`, 'Finish your rating.', `
<header class="page"><h1>How did ${escape(fact.app)} run?</h1><p>Your rating goes on the game's page, to help others playing it on a Mac.</p></header>
${error ? `<p class="problem">${escape(error)}</p>` : ''}
<form class="write" method="post" action="/report/${ticket}">
  <fieldset class="tiers"><legend>Rating</legend>${tiers}</fieldset>
  <label for="report-comment">${draft.log_name ? 'What happened? Needed, since logs are going with it' : 'Comment, needed for Bronze and Borked'}</label>
  <textarea id="report-comment" name="comment" rows="5" maxlength="20000"${draft.log_name ? ' required' : ''}>${escape(comment ?? draft.what)}</textarea>
  ${going.length ? `<ul class="muted">${going.map((line) => `<li>${line}</li>`).join('')}</ul>` : ''}
  ${user ? sendAs(user, earlier, anonymous, linking) : `<p class="muted">Sent anonymously. <a href="/account?next=/report/${ticket}">Sign in</a> to send it from your account instead.</p>`}
  <p class="muted">Shown with your rating: the frame rate of the last run, your OverPass, Wine and Runtime versions, your Mac's chip and macOS version.</p>
  <details class="muted"><summary>Everything that's sent</summary><pre>${escape(lines.join('\n'))}</pre>${draft.profile ? `<pre>${escape(draft.profile)}</pre>` : ''}</details>
  <div class="decide"><button class="button" type="submit">Send</button></div>
</form>
<script>
  // Keeps what's typed through a sign-in, which leaves this page. Only until it's sent, and only unsent text.
  const form = document.querySelector('form.write'), text = form.elements.comment, key = 'report-text';
  try {
    const kept = JSON.parse(localStorage.getItem(key));
    if (kept?.page === location.pathname) {
      if (!text.value) text.value = kept.comment;
      if (kept.tier) form.elements.tier.value = kept.tier;
    }
  } catch {}
  const keep = () => { try { localStorage.setItem(key, JSON.stringify({ page: location.pathname, comment: text.value, tier: form.elements.tier.value })); } catch {} };
  form.addEventListener('input', keep);
  form.addEventListener('submit', () => { try { localStorage.removeItem(key); } catch {} });
</script>`, moderator);
}

/// Who a signed-in person sends this as, and whether this Mac's earlier ratings join their account.
function sendAs(user, earlier, anonymous, linking) {
  const shown = user.public && user.name ? `Your account, with your name, ${escape(user.name)}, on the rating` : "Your account, as a Member: your name isn't shown";
  return `<fieldset class="choice"><legend>Send as</legend>
    <label><input type="radio" name="as" value="account"${anonymous ? '' : ' checked'}> ${shown}</label>
    <label><input type="radio" name="as" value="anonymous"${anonymous ? ' checked' : ''}> Anonymous</label>
  </fieldset>
  ${earlier ? `<label><input type="checkbox" name="link" value="1"${linking ? ' checked' : ''}> Add this Mac's ${earlier === 1 ? 'earlier rating' : `${earlier} earlier ratings`} to my account</label>` : ''}`;
}

const reportGonePage = () => shell('Report not found · OverPass', 'This report was already sent, or has expired.', `
<header class="page"><h1>This report is gone</h1><p>It was already sent, or a day went by without it being sent. To rate the game again, use How Did It Run? in OverPass.</p></header>`);

const missingPage = () => shell('Game not found · OverPass', 'This game has no page yet.', `
<header class="page"><h1>No page for this game yet</h1><p><a href="/games">See all games</a></p></header>`, false, 'games');
const failedPage = () => shell('Something went wrong · OverPass', 'The games list could not be loaded.', `
<header class="page"><h1>Something went wrong</h1><p>The games list could not be loaded. Try again in a moment.</p></header>`);

const html = (body, status = 200) => new Response(body, {
  status, headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'public, max-age=60' },
});

/// A page that depends on who's asking: never cached.
const personal = (body) => new Response(body, {
  headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store', 'X-Frame-Options': 'DENY' },
});

/// A page whose address is a secret: not cached or indexed, and the address doesn't go out with any link or picture.
const ticketed = (body, status = 200) => new Response(body, {
  status,
  headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store', 'X-Frame-Options': 'DENY', 'Referrer-Policy': 'same-origin', 'X-Robots-Tag': 'noindex' },
});

const json = (value, status = 200) => new Response(JSON.stringify(value), {
  status,
  headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*', 'Cache-Control': status === 200 ? 'public, max-age=60' : 'no-store' },
});
