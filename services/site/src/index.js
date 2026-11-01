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
//   POST /games/<id>/comments, /games/<id>/comments/<comment>/delete   add a comment, delete one's own
//   POST /games/<id>/(comments|ratings)/<entry>/report   report one; three people reporting it hides it
//   GET  /moderation, POST /moderation/(comments|ratings)/<entry>/(hide|show)   for the accounts in MODERATORS
//   POST /games/<id>/ratings, /games/<id>/ratings/delete   the same accounts rate a game on its page, or take that back
//   GET  /privacy                what's kept, and for how long
//
// An account holds the provider's ID for the person and the username they choose, nothing else: no e-mail, no name
// from Google. A session is a random token in a cookie; the database keeps only its hash.

const TIERS = ['platinum', 'gold', 'silver', 'bronze', 'borked'];
const TITLES = { platinum: 'Platinum', gold: 'Gold', silver: 'Silver', bronze: 'Bronze', borked: 'Borked' };
const REPOSITORY = 'https://github.com/McKack/overpass';

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, '') || '/';
    try {
      if (path === '/api/sync' && request.method === 'POST') return await sync(request, env);
      const commented = path.match(/^\/games\/([a-z0-9-]+)\/comments(?:\/([0-9a-f-]+)\/delete)?$/);
      const reported = path.match(/^\/games\/([a-z0-9-]+)\/(comments|ratings)\/([0-9a-f-]+)\/report$/);
      const moderated = path.match(/^\/moderation\/(comments|ratings)\/([0-9a-f-]+)\/(hide|show)$/);
      const rated = path.match(/^\/games\/([a-z0-9-]+)\/ratings(\/delete)?$/);
      if (request.method === 'POST' && (commented || reported || moderated || rated || ['/account', '/account/delete', '/auth/signout'].includes(path))) {
        // Only this site's own forms.
        if (request.headers.get('Origin') !== url.origin) return html(failedPage(), 403);
        if (path === '/auth/signout') return await signOut(request, env);
        const user = await signedIn(request, env);
        if (!user) return redirect('/account');
        if (reported) return await report(env, user, ...reported.slice(1));
        if (moderated) return isModerator(env, user) ? await review(env, ...moderated.slice(1)) : redirect('/account');
        if (rated) {
          if (!isModerator(env, user)) return redirect('/account');
          return rated[2] ? await deleteOwnRating(env, user, rated[1]) : await addOwnRating(request, env, user, rated[1]);
        }
        if (commented) {
          return commented[2] ? await deleteComment(env, user, commented[1], commented[2]) : await addComment(request, env, user, commented[1]);
        }
        return path === '/account' ? await rename(request, env, user) : await deleteAccount(env, user);
      }
      if (request.method === 'GET' || request.method === 'HEAD') {
        if (path === '/auth/google') return await startGoogle(url, env);
        if (path === '/auth/google/callback') return await finishGoogle(request, url, env);
        if (path === '/account') {
          const user = await signedIn(request, env);
          return personal(accountPage(user, url.searchParams.get('error'), isModerator(env, user)));
        }
        if (path === '/moderation') {
          const user = await signedIn(request, env);
          return isModerator(env, user) ? personal(moderationPage(await queue(env))) : redirect('/account');
        }
        if (path === '/privacy') {
          const moderator = isModerator(env, await signedIn(request, env));
          return (moderator ? personal : html)(privacyPage(moderator));
        }
        if (path === '/api/recent') return json(await recent(env));
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

function summary(game, rated) {
  const counts = rated?.counts ?? {};
  return {
    id: game.id, name: game.name, category: game.category, source: game.source, steam: game.steam, verified: game.verified,
    tier: overall(counts), counts, ratings: Object.values(counts).reduce((sum, n) => sum + n, 0), last_rated: rated?.last ?? null,
  };
}

async function list(env) {
  const [{ results }, rated] = await Promise.all([
    env.DB.prepare('SELECT id, name, category, source, steam, verified FROM games').all(),
    tally(env),
  ]);
  return results.map((game) => summary(game, rated.get(game.id)))
    .sort((a, b) => (b.last_rated ?? 0) - (a.last_rated ?? 0) || a.name.localeCompare(b.name));
}

async function recent(env) {
  return (await list(env)).filter((game) => game.last_rated).slice(0, 8);
}

async function detail(env, id) {
  const game = await env.DB.prepare('SELECT * FROM games WHERE id = ?').bind(id).first();
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
    presets: JSON.parse(game.presets), rating_list: results,
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
      `INSERT INTO games (id, name, category, source, verified, notes, profile_file, profile_text, presets, steam, gog, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT (id) DO UPDATE SET name = excluded.name, category = excluded.category, source = excluded.source,
         verified = excluded.verified, notes = excluded.notes, profile_file = excluded.profile_file,
         profile_text = excluded.profile_text, presets = excluded.presets, steam = excluded.steam, gog = excluded.gog`,
    ).bind(game.id, game.name, game.category, game.source, game.verified, game.notes, game.profile_file, game.profile_text,
      JSON.stringify(game.presets), game.steam, game.gog, now));
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
    `SELECT users.id, users.name FROM sessions JOIN users ON users.id = sessions.user_id WHERE sessions.token_hash = ? AND sessions.expires_at > ?`,
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

// Comments

const COMMENT_LENGTH = 2000;
const COMMENTS_A_DAY = 20;

/// A hidden comment still shows to the person who wrote it, so they can delete it.
async function comments(env, id, user) {
  const { results } = await env.DB.prepare(
    `SELECT comments.id, comments.user_id, comments.body, comments.hidden, comments.created_at, users.name FROM comments
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
       users.name AS author, games.name AS game, (SELECT COUNT(*) FROM reports WHERE target = comments.id) AS reports
     FROM comments JOIN users ON users.id = comments.user_id LEFT JOIN games ON games.id = comments.game_id
     WHERE comments.hidden = 1 OR comments.id IN (SELECT target FROM reports)
     UNION ALL
     SELECT 'ratings', ratings.id, ratings.comment, ratings.tier, ratings.hidden, ratings.created_at, ratings.game_id,
       NULL, games.name, (SELECT COUNT(*) FROM reports WHERE target = ratings.id)
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

// Pages

const escape = (text) => String(text ?? '').replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
const date = (time) => new Date(time).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'UTC' });
const hue = (name) => [...name].reduce((sum, c) => (sum * 31 + c.charCodeAt(0)) % 360, 7);
const initials = (name) => name.replace(/[^\p{L}\p{N} ]/gu, '').split(/\s+/).filter(Boolean).slice(0, 2).map((word) => [...word][0]).join('').toUpperCase() || '?';

function medal(tier, large = false) {
  if (!tier) return '<span class="medal none">Not rated</span>';
  return `<span class="medal ${tier}${large ? ' large' : ''}">${TITLES[tier]}</span>`;
}

/// The Steam cover when there is one, over a tile made from the name that shows when there isn't.
function cover(game) {
  const art = game.steam
    ? `<img src="https://cdn.cloudflare.steamstatic.com/steam/apps/${escape(game.steam)}/library_600x900.jpg" alt="" loading="lazy" onerror="this.remove()">`
    : '';
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

function card(game) {
  const tag = game.source === 'profile' ? 'Profile' : game.source === 'preset' ? 'Known fix' : '';
  return `<a class="card" href="/games/${game.id}" data-name="${escape(game.name.toLowerCase())}" data-tier="${game.tier ?? 'none'}">
  ${cover(game)}
  <h3>${escape(game.name)}</h3>
  <p>${medal(game.tier)}${tag ? `<span class="tag">${tag}</span>` : ''}</p>
</a>`;
}

function gamesPage(games, moderator) {
  const rated = games.filter((game) => game.tier).length;
  const filters = [['all', 'All'], ...TIERS.map((tier) => [tier, TITLES[tier]]), ['none', 'Not rated']]
    .map(([value, title]) => `<button type="button" data-filter="${value}" aria-pressed="${value === 'all'}">${title}</button>`).join('');
  return shell('Games · OverPass', 'How Windows games run on a Mac with OverPass: ratings from players and each game\'s settings.', `
<header class="page">
  <h1>Games</h1>
  <p>How Windows games run on a Mac with OverPass. ${games.length} games, ${rated} rated by players.</p>
</header>
<div class="controls">
  <input id="search" type="search" placeholder="Search games" aria-label="Search games" autocomplete="off">
  <div class="filters" id="filters">${filters}</div>
</div>
<div class="grid" id="grid">${games.map(card).join('\n')}</div>
<p class="empty" id="nothing" hidden>No games match.</p>
<script>
  const cards = [...document.querySelectorAll('#grid .card')], search = document.getElementById('search');
  const buttons = [...document.querySelectorAll('#filters button')], nothing = document.getElementById('nothing');
  let filter = 'all';
  function apply() {
    const text = search.value.trim().toLowerCase();
    let shown = 0;
    for (const card of cards) {
      card.hidden = !(card.dataset.name.includes(text) && (filter === 'all' || card.dataset.tier === filter));
      if (!card.hidden) shown++;
    }
    nothing.hidden = shown > 0;
  }
  search.addEventListener('input', apply);
  for (const button of buttons) button.addEventListener('click', () => {
    filter = button.dataset.filter;
    for (const other of buttons) other.setAttribute('aria-pressed', other === button);
    apply();
  });
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
  <div class="line"><span class="who"><span class="avatar" style="--hue:${hue(comment.name)}">${escape(initials(comment.name))}</span>${escape(comment.name)}</span><time datetime="${new Date(comment.created_at).toISOString()}">${date(comment.created_at)}</time></div>
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
<header class="game">
  ${cover(game)}
  <div>
    <h1>${escape(game.name)}</h1>
    <p class="summary">${medal(game.tier, true)}<span>${game.ratings === 1 ? '1 rating' : `${game.ratings} ratings`}</span></p>
    ${game.verified ? `<p class="muted">Tested by OverPass: ${escape(TITLES[game.verified] ?? game.verified)}</p>` : ''}
    ${game.ratings ? breakdown(game) : ''}
  </div>
</header>
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
};

function moderationCard(entry) {
  const buttons = entry.hidden
    ? [['show', 'Show', 'quiet']]
    : [['hide', 'Hide', 'danger'], ['show', 'Keep', 'quiet']];
  return `<article class="rating">
  <div class="line"><span class="who">${entry.tier ? medal(entry.tier) : escape(entry.author)}</span><time datetime="${new Date(entry.created_at).toISOString()}">${date(entry.created_at)}</time></div>
  ${entry.text ? `<p class="comment">${escape(entry.text)}</p>` : ''}
  <p class="muted"><a href="/games/${entry.game_id}">${escape(entry.game ?? entry.game_id)}</a> · ${entry.hidden ? 'Hidden' : 'Showing'} · ${entry.reports === 1 ? '1 report' : `${entry.reports} reports`}</p>
  <div class="decide">${buttons.map(([action, title, style]) => `<form method="post" action="/moderation/${entry.kind}/${entry.id}/${action}"><button class="button ${style}" type="submit">${title}</button></form>`).join('')}</div>
</article>`;
}

const moderationPage = (entries) => shell('Moderation · OverPass', 'Reported and hidden comments and ratings.', `
<header class="page"><h1>Moderation</h1><p>Reported and hidden comments and ratings. Deciding clears an entry's reports.</p></header>
${entries.length ? entries.map(moderationCard).join('\n') : '<p class="empty">Nothing to look at.</p>'}`, true);

function accountPage(user, error, moderator) {
  const problem = ACCOUNT_ERRORS[error] ? `<p class="problem" role="alert">${ACCOUNT_ERRORS[error]}</p>` : '';
  if (!user) {
    return shell('Sign in · OverPass', 'Sign in to OverPass.', `
<header class="page"><h1>Sign in</h1><p>An account lets you comment on game pages. You don't need one to play or to rate games from the app.</p></header>
${problem}
<p><a class="button" href="/auth/google">Sign in with Google</a></p>
<p class="muted">OverPass keeps Google's ID for your account and the username you choose, not your e-mail or name. <a href="/privacy">Privacy</a></p>`);
  }
  return shell('Your account · OverPass', 'Your OverPass account.', `
<header class="page"><h1>${user.name ? escape(user.name) : 'Choose a username'}</h1>${user.name ? '' : '<p>This is the name others will see.</p>'}</header>
${problem}
<form class="account" method="post" action="/account">
  <label for="name">Username</label>
  <input id="name" name="name" required minlength="2" maxlength="30" value="${escape(user.name)}" autocomplete="username">
  <button class="button" type="submit">Save</button>
</form>
<form class="account" method="post" action="/auth/signout"><button class="button quiet" type="submit">Sign Out</button></form>
<section>
  <h2>Delete account</h2>
  <p class="muted">Removes your account, username and comments at once. Ratings sent from the app aren't tied to an account, so they stay.</p>
  <form method="post" action="/account/delete"><button class="button danger" type="submit">Delete Account</button></form>
</section>`, moderator);
}

const privacyPage = (moderator) => shell('Privacy · OverPass', 'What OverPass keeps about you, and for how long.', `
<header class="page"><h1>Privacy</h1><p>What OverPass and this site keep, and for how long.</p></header>
<section>
  <h2>Accounts</h2>
  <p>Signing in with Google gives this site an ID for you that means nothing elsewhere. It's stored with the username you choose and the date. Your e-mail and name aren't requested, and no picture is stored.</p>
  <p>A cookie keeps you signed in for 90 days. It's the only cookie here, apart from a short-lived one while you sign in. There's no tracking and no advertising.</p>
  <p>You can delete your account on <a href="/account">its page</a>. It's removed at once, with your comments.</p>
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
</section>
<section>
  <h2>Logs and reports</h2>
  <p>Logs are only sent when you choose to. They file a public issue on <a href="${REPOSITORY}/issues">GitHub</a>, and the log and any screenshot are kept for 180 days. Your name, home folder, computer name and e-mail addresses are taken out first. The report service counts reports per network address to limit abuse, and those counts are gone within two hours.</p>
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
