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
//   POST /games/<id>/(comments|ratings)/<entry>/report   report one, with a reason; three people reporting it hides it
//   GET  /users/<name>-<tag>     a person's public page
//   GET  /moderation, POST /moderation/(comments|ratings)/<entry>/(hide|show)   for Admins and Mods
//   POST /moderation/mods/<user>/(add|remove)   Admins make an account a Mod, or stop it being one
//   GET  /moderation/users?q=&filter=   the rows of the Users tab, for its search
//   POST /moderation/users/<user>/(ban|unban)   Admins and Mods ban an account without a role, or lift that
//   POST /games/<id>/ratings, /games/<id>/ratings/delete   the same accounts rate a game on its page, or take that back
//   POST /moderation/pictures/<key>/remove       the same accounts take a person's picture down
//   POST /moderation/suggestions/<entry>/(approve|reject)   Admins decide on a suggested profile
//   POST /api/issues             { issues } from link-issues.mjs: every GitHub issue and what it says about its game; the same secret
//   GET  /api/art                what find-covers.mjs needs for each game; needs the SYNC_TOKEN secret
//   POST /api/art                { id, links, source, cover, thumb, icon, hero } from the same script; the same secret
//   GET  /api/art/<store>/<id>?name=   the art the app shows; a title not seen before joins the queue for find-covers.mjs
//   POST /games/<id>/cover, /games/<id>/cover/url, /games/<id>/cover/reset   a moderator changes a game's cover
//   GET  /pictures/covers/<file>  a moderator's upload
//   GET  /api/anticheat          when AreWeAntiCheatYet's list last came, for sync-anticheat.mjs; POST { run, games } or { run, done }; needs the SYNC_TOKEN secret
//   GET  /api/profiles           the signed set of profiles the app downloads
//   POST /api/profiles           { serial, body } from publish-profiles.mjs; needs the SYNC_TOKEN secret
//   GET  /api/suggestions        the approved suggestions, for publish-profiles.mjs; needs the SYNC_TOKEN secret
//   POST /api/suggestions        { published, refused }: lists of their IDs, from the same script; the same secret
//   GET  /report/<ticket>        finish a rating the app started; POST sends it through the report relay
//   POST /account/public         Public Contributor or Member: whether one's name shows on one's ratings
//   POST /account/updates, /account/updates/code, /account/updates/stop   turn e-mail updates on, confirm by code, turn off
//   GET, POST /updates/stop/<token>   the link in every update; POST is also what a mail app's unsubscribe button sends
//   GET  /privacy                what's kept, and for how long
//
// An account holds the provider's ID for the person, the username they choose and a picture if they add one, nothing
// else: no e-mail, no name from Google, unless they turn on e-mail updates, which keeps the address they give (email_updates). An e-mail account's ID is a keyed hash of the address, so the address itself
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
/// What a rating counts for against a game's overall tier once the profile sent with it was rejected.
const UNCONFIRMED_WEIGHT = 0.01;
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
      if (path === '/api/issues' && request.method === 'POST') return await storeIssues(request, env, context);
      if (path === '/api/anticheat' && request.method === 'POST') return await storeAntiCheat(request, env);
      const commented = path.match(/^\/games\/([a-z0-9-]+)\/comments(?:\/([0-9a-f-]+)\/(delete|vote))?$/);
      const reported = path.match(/^\/games\/([a-z0-9-]+)\/(comments|ratings)\/([0-9a-f-]+)\/report$/);
      const moderated = path.match(/^\/moderation\/(comments|ratings)\/([0-9a-f-]+)\/(hide|show)$/);
      const rated = path.match(/^\/games\/([a-z0-9-]+)\/ratings(\/delete)?$/);
      const unpictured = path.match(/^\/moderation\/pictures\/([0-9a-f-]+)\/remove$/);
      const decided = path.match(/^\/moderation\/suggestions\/([0-9a-f-]+)\/(approve|reject)$/);
      const modded = path.match(/^\/moderation\/mods\/([0-9a-f-]+)\/(add|remove)$/);
      const judged = path.match(/^\/moderation\/users\/([0-9a-f-]+)\/(ban|unban)$/);
      const covered = path.match(/^\/games\/([a-z0-9-]+)\/cover(?:\/(url|reset))?$/);
      const ticket = path.match(/^\/report\/([0-9a-f]{64})$/);
      const stopping = path.match(/^\/updates\/stop\/([\w-]{43})$/);
      // No Origin check: the token is the key, and a mail app presses this one by itself.
      if (stopping && request.method === 'POST') return await stopByLink(env, stopping[1]);
      if (stopping && (request.method === 'GET' || request.method === 'HEAD')) return ticketed(stopPage(stopping[1]));
      if (ticket && request.method === 'POST') {
        if (request.headers.get('Origin') !== url.origin) return html(failedPage(), 403);
        return await sendReport(request, env, ticket[1], await signedIn(request, env));
      }
      if (request.method === 'POST' && path.startsWith('/auth/email/')) {
        if (request.headers.get('Origin') !== url.origin) return html(failedPage(), 403);
        return await emailPost(request, env, context, path.slice('/auth/email/'.length));
      }
      if (request.method === 'POST' && (commented || reported || moderated || rated || unpictured || decided || modded || judged || covered
        || ['/account', '/account/delete', '/account/picture', '/account/picture/delete', '/account/public', '/account/updates', '/account/updates/code', '/account/updates/stop', '/auth/signout'].includes(path))) {
        // Only this site's own forms.
        if (request.headers.get('Origin') !== url.origin) return html(failedPage(), 403);
        if (path === '/auth/signout') return await signOut(request, env);
        const user = await signedIn(request, env);
        if (!user) return redirect('/account');
        // A banned person can still read, and leave.
        if (user.banned && path !== '/account/delete') return redirect('/account');
        // Banning is this one press's, so it mustn't stay in the address the next page's forms are made from.
        const andBan = url.searchParams.has('ban');
        url.searchParams.delete('ban');
        const back = `/moderation${url.search}`;
        if (reported) return await report(request, env, user, ...reported.slice(1));
        if (moderated) return isModerator(env, user) ? await review(env, user, back, ...moderated.slice(1), andBan) : redirect('/account');
        if (unpictured) {
          if (!isModerator(env, user)) return redirect('/account');
          await takeDownPicture(env, unpictured[1]);
          return redirect(back);
        }
        if (decided) return isAdmin(user) ? await decide(env, context, back, ...decided.slice(1)) : redirect('/account');
        if (modded) return isAdmin(user) ? await changeMods(env, back, ...modded.slice(1)) : redirect('/account');
        if (judged) return isModerator(env, user) ? await changeBan(request, env, user, back, ...judged.slice(1)) : redirect('/account');
        if (covered) return isModerator(env, user) ? await changeCover(request, env, covered[1], covered[2]) : redirect('/account');
        if (rated) {
          if (!isModerator(env, user)) return redirect('/account');
          return rated[2] ? await deleteOwnRating(env, user, rated[1]) : await addOwnRating(request, env, user, rated[1]);
        }
        if (commented) {
          if (commented[3] === 'vote') return await vote(env, user, commented[1], commented[2]);
          return commented[2] ? await deleteComment(env, user, commented[1], commented[2]) : await addComment(request, env, context, user, commented[1]);
        }
        if (path === '/account/picture') return await savePicture(request, env, user);
        if (path === '/account/picture/delete') return await deletePicture(env, user);
        if (path === '/account/public') return await setPublic(request, env, user);
        if (path === '/account/updates') return await askUpdates(request, env, context, user);
        if (path === '/account/updates/code') return await confirmUpdates(request, env, user);
        if (path === '/account/updates/stop') return await stopUpdates(env, user);
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
          return personal(accountPage(user, url.searchParams.get('error'), isModerator(env, user), localPath(url.searchParams.get('next')), user && await updatesAddress(env, user)));
        }
        if (path === '/moderation') {
          const user = await signedIn(request, env);
          if (!isModerator(env, user)) return redirect('/account');
          return personal(await dashboard(env, user, url));
        }
        if (path === '/moderation/users') {
          const user = await signedIn(request, env);
          if (!isModerator(env, user)) return redirect('/account');
          return personal(await peopleRows(env, user, url));
        }
        const person = path.match(/^\/users\/([^/]+)-(\d{4})$/);
        if (person) return await profilePage(env, await signedIn(request, env), url, ...person.slice(1));
        if (path === '/privacy') {
          const moderator = isModerator(env, await signedIn(request, env));
          return (moderator ? personal : html)(privacyPage(moderator));
        }
        if (ticket) return await showReport(env, ticket[1], await signedIn(request, env));
        if (path === '/api/anticheat') return await antiCheatStamp(request, env);
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
    `SELECT game_id, tier, COUNT(*) AS n, SUM(unconfirmed) AS unconfirmed, MAX(created_at) AS last FROM ratings WHERE hidden = 0 ${where} GROUP BY game_id, tier`,
  ).bind(...values).all();
  const games = new Map();
  for (const row of results) {
    const game = games.get(row.game_id) ?? { counts: {}, weights: {}, unconfirmed: 0, last: 0 };
    game.counts[row.tier] = row.n;
    game.weights[row.tier] = row.n - row.unconfirmed + row.unconfirmed * UNCONFIRMED_WEIGHT;
    game.unconfirmed += row.unconfirmed;
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
    id: game.id, name: game.name, category: game.category, source: game.source, steam: game.steam, verified: game.verified, anticheat: Boolean(game.anticheat),
    tier: overall(rated?.weights ?? {}), counts, ratings: Object.values(counts).reduce((sum, n) => sum + n, 0), unconfirmed: rated?.unconfirmed ?? 0, last_rated: rated?.last ?? null,
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
      `SELECT g.id, g.name, g.category, g.source, g.steam, g.verified, g.links, g.brand, g.color, a.file AS art, a.thumb, a.origin, a.icon, a.links AS found,
         c.game_id IS NOT NULL AS anticheat
       FROM games g LEFT JOIN game_art a ON a.game_id = g.id LEFT JOIN anticheat c ON c.game_id = g.id`,
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
    `SELECT g.*, a.file AS art, a.thumb, a.origin, a.hero, a.icon, a.about, a.about_source, a.links AS found, a.source AS art_source, a.wanted AS art_wanted
     FROM games g LEFT JOIN game_art a ON a.game_id = g.id WHERE g.id = ?`,
  ).bind(id).first();
  if (!game) return null;
  const [rated, { results }, { results: issues }, guard] = await Promise.all([
    tally(env, 'AND game_id = ?', id),
    env.DB.prepare(
      `SELECT r.id, r.tier, r.comment, r.chip, r.macos, r.overpass, r.wine, r.runtime, r.backend, r.fps, r.unconfirmed, r.created_at, ${badgeOf('u')},
         CASE WHEN u.public = 1 THEN u.name END AS author, CASE WHEN u.public = 1 THEN u.tag END AS author_tag, CASE WHEN u.public = 1 THEN u.picture END AS author_picture
       FROM ratings r LEFT JOIN users u ON u.id = r.user_id
       WHERE r.game_id = ? AND r.hidden = 0 ORDER BY r.created_at DESC LIMIT 100`,
    ).bind(id).all(),
    env.DB.prepare("SELECT number, title, url, state FROM game_issues WHERE game_id = ? ORDER BY state = 'open' DESC, number DESC").bind(id).all(),
    env.DB.prepare('SELECT slug, status, anticheats, notes FROM anticheat WHERE game_id = ?').bind(id).first(),
  ]);
  return {
    ...summary(game, rated.get(id)), notes: game.notes, profile_file: game.profile_file, profile_text: game.profile_text,
    presets: JSON.parse(game.presets), art_source: game.art_source ?? null, hero: game.hero ?? null, art_wanted: game.art_wanted ?? null, rating_list: results, issues,
    about: game.about ?? null, about_source: game.about_source ?? null,
    anticheat: guard ? { slug: guard.slug, status: guard.status, names: JSON.parse(guard.anticheats), notes: JSON.parse(guard.notes) } : null,
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
    `DELETE FROM games WHERE id NOT IN (SELECT value FROM json_each(?1)) AND id NOT IN (SELECT game_id FROM ratings) AND id NOT IN (SELECT game_id FROM comments)
       AND id NOT IN (SELECT game_id FROM anticheat)`,
  ).bind(ids));
  steps.push(env.DB.prepare(
    `UPDATE games SET source = 'rated', verified = NULL, notes = NULL, profile_file = NULL, profile_text = NULL, presets = '[]'
     WHERE id NOT IN (SELECT value FROM json_each(?1)) AND source <> 'anticheat'`,
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
/// Four random digits. A name can be shared; a name with its tag can't.
const newTag = () => String(crypto.getRandomValues(new Uint16Array(1))[0] % 10000).padStart(4, '0');
/// SQL for a query on `users`: the ban on this person's sign-in.
const bannedHere = 'bans.provider = users.provider AND bans.provider_id = users.provider_id';
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
    `SELECT users.id, users.name, users.tag, users.picture, users.public, users.role, users.provider, users.provider_id,
       (SELECT reason FROM bans WHERE ${bannedHere}) AS banned
     FROM sessions JOIN users ON users.id = sessions.user_id WHERE sessions.token_hash = ? AND sessions.expires_at > ?`,
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
  await env.DB.prepare('INSERT OR IGNORE INTO users (id, provider, provider_id, created_at, tag) VALUES (?, ?, ?, ?, ?)')
    .bind(crypto.randomUUID(), 'google', claims.sub, now, newTag()).run();
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
const LIMITS = { address: 5, ip: 15, wrong: 10, update: 1 };

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

async function sendMail(env, to, kind, fields) {
  const answer = await fetch(env.MAIL_URL, {
    method: 'POST',
    headers: { Authorization: `Bearer ${env.MAIL_TOKEN}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ to, kind, ...fields }),
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
  if (mailed) context.waitUntil(sendMail(env, address, mailed, mailed === 'exists' ? {} : { code }).catch((error) => console.error(`Mail failed: ${error.message}`)));
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
  if (!row || row.purpose === 'updates') return redirect('/auth/email?error=expired');
  return personal(codePage(row.purpose, url.searchParams.get('error')));
}

async function enterCode(request, env, form) {
  const row = await waitingCode(request, env);
  const gone = setCookie('overpass_email', '', 0);
  // A code for e-mail updates proves an address, but it was never meant to sign anyone in.
  if (!row || row.purpose === 'updates') return redirect('/auth/email?error=expired', gone);
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
    const made = await env.DB.prepare('INSERT OR IGNORE INTO users (id, provider, provider_id, created_at, password, tag) VALUES (?, ?, ?, ?, ?, ?)')
      .bind(user, 'email', row.address_hash, Date.now(), row.password, newTag()).run();
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

// E-mail updates

const updatesAddress = (env, user) => env.DB.prepare('SELECT address FROM email_updates WHERE user_id = ?').bind(user.id).first('address');

const keepAddress = (env, user, address) => env.DB.prepare('INSERT OR REPLACE INTO email_updates (user_id, address, token, created_at) VALUES (?, ?, ?, ?)')
  .bind(user.id, address, randomToken(), Date.now()).run();

/// The address a person signs in with is proven already. Any other waits for a code, and it isn't stored until the code
/// is right: it stays in the page's form, and the database only has its hash.
async function askUpdates(request, env, context, user) {
  const address = cleanAddress((await request.formData()).get('address'));
  if (!validAddress(address)) return redirect('/account?error=address');
  const hash = await addressHash(env, address);
  if (user.provider === 'email' && hash === user.provider_id) {
    await keepAddress(env, user, address);
    return redirect('/account');
  }
  const ip = request.headers.get('CF-Connecting-IP') || 'unknown';
  if (!await within(env, 'address', address) || !await within(env, 'ip', ip)) return redirect('/account?error=busy');
  const token = randomToken(), code = newCode(), now = Date.now();
  await env.DB.batch([
    env.DB.prepare('DELETE FROM email_codes WHERE expires_at <= ? OR (address_hash = ? AND purpose = ?)').bind(now, hash, 'updates'),
    env.DB.prepare('INSERT INTO email_codes (token_hash, purpose, address_hash, code_hash, next, expires_at) VALUES (?, ?, ?, ?, ?, ?)')
      .bind(await hashed(token), 'updates', hash, await codeHash(env, token, code), '/account', now + CODE_SECONDS * 1000),
  ]);
  context.waitUntil(sendMail(env, address, 'updates', { code }).catch((error) => console.error(`Mail failed: ${error.message}`)));
  const page = personal(updatesCodePage(address));
  page.headers.append('Set-Cookie', setCookie('overpass_email', token, CODE_SECONDS));
  return page;
}

async function confirmUpdates(request, env, user) {
  const form = await request.formData();
  const row = await waitingCode(request, env);
  const gone = setCookie('overpass_email', '', 0);
  const address = cleanAddress(form.get('address'));
  if (row?.purpose !== 'updates' || await addressHash(env, address) !== row.address_hash) return redirect('/account?error=expired', gone);
  const remove = env.DB.prepare('DELETE FROM email_codes WHERE token_hash = ?').bind(row.token_hash);
  if (!same(await codeHash(env, row.token, cleanCode(form.get('code'))), row.code_hash)) {
    if (row.tries + 1 >= CODE_TRIES) {
      await remove.run();
      return redirect('/account?error=expired', gone);
    }
    await env.DB.prepare('UPDATE email_codes SET tries = tries + 1 WHERE token_hash = ?').bind(row.token_hash).run();
    return personal(updatesCodePage(address, 'code'));
  }
  await remove.run();
  await keepAddress(env, user, address);
  return redirect('/account', gone);
}

async function stopUpdates(env, user) {
  await env.DB.prepare('DELETE FROM email_updates WHERE user_id = ?').bind(user.id).run();
  return redirect('/account');
}

async function stopByLink(env, token) {
  await env.DB.prepare('DELETE FROM email_updates WHERE token = ?').bind(token).run();
  return ticketed(stoppedPage());
}

/// One mail of a kind per person, game and hour, so a busy thread can't fill anyone's inbox. A mail says only that there's
/// something to see and where: nothing a stranger wrote goes into it.
async function tell(env, people, kind, game, comment) {
  const { results } = await env.DB.prepare('SELECT user_id, address, token FROM email_updates WHERE user_id IN (SELECT value FROM json_each(?))')
    .bind(JSON.stringify([...new Set(people)])).all();
  for (const person of results) {
    if (await within(env, 'update', `${kind}:${person.user_id}:${game}`)) {
      await sendMail(env, person.address, kind, { game, comment, stop: person.token });
    }
  }
}

/// A reply tells whoever it answers and whoever started the thread; a new comment tells those who rated the game.
async function tellAboutComment(env, user, game, comment, answered) {
  const { results } = answered
    ? await env.DB.prepare('SELECT user_id FROM comments WHERE id IN (?, ?)').bind(answered.id, answered.parent_id).all()
    : await env.DB.prepare('SELECT DISTINCT user_id FROM ratings WHERE game_id = ? AND user_id IS NOT NULL AND hidden = 0').bind(game).all();
  await tell(env, results.map((row) => row.user_id).filter((id) => id !== user.id), answered ? 'reply' : 'comment', game, comment);
}

async function tellAboutFixes(env, fixed) {
  for (const { number, game } of fixed) {
    const { results } = await env.DB.prepare('SELECT user_id FROM issue_reporters WHERE number = ?').bind(number).all();
    await tell(env, results.map((row) => row.user_id), 'fixed', game);
  }
}

async function signOut(request, env) {
  const token = cookie(request, 'overpass_session');
  if (token) await env.DB.prepare('DELETE FROM sessions WHERE token_hash = ?').bind(await hashed(token)).run();
  return redirect('/account', setCookie('overpass_session', '', 0));
}

async function rename(request, env, user) {
  const name = String((await request.formData()).get('name') || '').trim();
  if (!USERNAME.test(name)) return redirect('/account?error=name');
  // Someone else having the name only means another tag; the person keeps theirs if they can.
  for (const tag of [user.tag, ...Array.from({ length: 30 }, newTag)]) {
    try {
      await env.DB.prepare('UPDATE users SET name = ?, tag = ? WHERE id = ?').bind(name, tag, user.id).run();
      return redirect('/account');
    } catch (error) {
      if (!/UNIQUE/i.test(error.message)) throw error;
    }
  }
  return redirect('/account?error=taken');
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
    env.DB.prepare('DELETE FROM email_updates WHERE user_id = ?').bind(user.id),
    env.DB.prepare('DELETE FROM issue_reporters WHERE user_id = ?').bind(user.id),
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
    `SELECT g.id, g.name, g.source, g.category, g.steam, g.gog, g.brand, a.wanted, a.locked, a.checked_at, COALESCE(a.file, a.origin) AS cover, a.hero, a.icon, a.about
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
  const { id, links, source, cover: image, thumb, icon, hero, about, about_source: aboutSource } = await request.json();
  const before = await env.DB.prepare('SELECT file, origin, locked FROM game_art WHERE game_id = ?').bind(id).first();
  if (!before && !await env.DB.prepare('SELECT 1 FROM games WHERE id = ?').bind(id).first()) return json({ error: 'No such game.' }, 404);
  const address = (value) => typeof value === 'string' && value.startsWith('https://') && value.length <= 1000 ? value : null;
  await env.DB.prepare(
    `INSERT INTO game_art (game_id, links, icon, hero, about, about_source, checked_at) VALUES (?1, ?2, ?3, ?4, ?6, ?7, ?5)
     ON CONFLICT (game_id) DO UPDATE SET links = ?2, icon = COALESCE(icon, ?3), hero = COALESCE(hero, ?4),
       about_source = CASE WHEN about IS NULL THEN ?7 ELSE about_source END, about = COALESCE(about, ?6), wanted = NULL, checked_at = ?5`,
  ).bind(id, JSON.stringify((links ?? []).filter(storeName)), address(icon), address(hero), Date.now(),
    typeof about === 'string' ? about.slice(0, 1000) : null, ABOUT_SOURCES[aboutSource] ? aboutSource : null).run();
  const moderator = source === 'moderator';
  const gap = !before?.locked && (!before?.origin || before.file);
  if (!address(image) || !(gap || moderator)) return json({ stored: false });
  await env.DB.prepare('UPDATE game_art SET file = NULL, source = ?2, origin = ?3, thumb = ?4, locked = ?5 WHERE game_id = ?1')
    .bind(id, source, address(image), address(thumb), moderator ? 1 : 0).run();
  if (before?.file) await env.PICTURES.delete(`covers/${before.file}`);
  return json({ stored: true });
}

/// Every GitHub issue, from link-issues.mjs. The rows are replaced each time, so a closed or removed issue shows at once.
/// An issue is about the game its report block names, or the one its title starts with. A report about a game with no
/// page gives it one, as a rating does.
async function storeIssues(request, env, context) {
  if (!env.SYNC_TOKEN || request.headers.get('Authorization') !== `Bearer ${env.SYNC_TOKEN}`) return json({ error: 'Not allowed.' }, 403);
  const { issues } = await request.json();
  const { results: keys } = await env.DB.prepare('SELECT store, store_id, game_id FROM game_keys').all();
  const { results: games } = await env.DB.prepare('SELECT id FROM games').all();
  const byKey = new Map(keys.map((key) => [`${key.store}:${key.store_id}`, key.game_id]));
  const known = new Set(games.map((game) => game.id));
  const { results: earlier } = await env.DB.prepare('SELECT number, state FROM game_issues').all();
  const wasState = new Map(earlier.map((issue) => [issue.number, issue.state]));
  const fixed = [];
  const steps = [env.DB.prepare('DELETE FROM game_issues')];
  for (const issue of issues) {
    const store = (issue.store ?? '').match(/^(.+) (\S+)$/);
    const name = String(issue.app ?? '').slice(0, 120);
    if (name === 'OverPass' || !/^https:\/\/github\.com\//.test(issue.url)) continue;
    const key = store && `${{ Steam: 'steam', GOG: 'gog', 'Epic Games': 'epic' }[store[1]] ?? store[1].toLowerCase()}:${store[2]}`;
    const profile = (issue.profile ?? 'none').replace(/ \((changed|own)\)$/, '');
    let game = byKey.get(key) ?? byKey.get(`profile:${profile}`);
    if (!game) game = [slug(name), slug(issue.named ?? '')].find((id) => known.has(id));
    if (!game && name && slug(name)) {
      game = slug(name);
      known.add(game);
      const [kind, id] = key?.split(':') ?? [];
      steps.push(env.DB.prepare("INSERT OR IGNORE INTO games (id, name, source, steam, gog, created_at) VALUES (?, ?, 'rated', ?, ?, ?)")
        .bind(game, name, kind === 'steam' ? id : null, kind === 'gog' ? id : null, Date.now()));
    }
    if (!game) continue;
    if (issue.state === 'fixed' && wasState.has(issue.number) && wasState.get(issue.number) !== 'fixed') fixed.push({ number: issue.number, game });
    steps.push(env.DB.prepare('INSERT OR REPLACE INTO game_issues (number, game_id, title, url, state) VALUES (?, ?, ?, ?, ?)')
      .bind(issue.number, game, String(issue.title).slice(0, 200), issue.url, ['open', 'fixed', 'closed'].includes(issue.state) ? issue.state : 'open'));
  }
  await env.DB.batch(steps);
  if (fixed.length) context.waitUntil(tellAboutFixes(env, fixed).catch((error) => console.error(`Mail failed: ${error.message}`)));
  return json({ linked: steps.length - 1 });
}

async function antiCheatStamp(request, env) {
  if (!fromGitHub(request, env)) return json({ error: 'Not allowed.' }, 403);
  const synced = await env.DB.prepare('SELECT MAX(run) AS run FROM anticheat').first('run');
  return new Response(JSON.stringify({ synced_at: synced }), { headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });
}

/// Part of AreWeAntiCheatYet's list, from sync-anticheat.mjs. A game is found by its store IDs, then its name; one the site
/// doesn't have gets a page. `done` ends a run: what it didn't send has left the list.
async function storeAntiCheat(request, env) {
  if (!fromGitHub(request, env)) return json({ error: 'Not allowed.' }, 403);
  const { run, games, done } = await request.json();
  if (!Number.isInteger(run)) return json({ error: 'No run.' }, 400);
  if (done) {
    await env.DB.batch([
      env.DB.prepare('DELETE FROM anticheat WHERE run <> ?').bind(run),
      env.DB.prepare(`DELETE FROM games WHERE source = 'anticheat' AND id NOT IN (SELECT game_id FROM anticheat) AND id NOT IN (SELECT game_id FROM ratings) AND id NOT IN (SELECT game_id FROM comments)`),
      env.DB.prepare('DELETE FROM game_keys WHERE game_id NOT IN (SELECT id FROM games)'),
    ]);
    return json({ done: true });
  }
  const { results: keys } = await env.DB.prepare('SELECT store, store_id, game_id FROM game_keys').all();
  const { results: known } = await env.DB.prepare('SELECT id FROM games').all();
  const byKey = new Map(keys.map((key) => [`${key.store}:${key.store_id}`, key.game_id]));
  const ids = new Set(known.map((game) => game.id));
  const steps = [];
  for (const game of games) {
    let id = byKey.get(`steam:${game.steam}`) ?? byKey.get(`epic:${game.epic}`);
    if (!id && ids.has(slug(game.name))) id = slug(game.name);
    if (!id) {
      id = slug(game.name);
      if (!id) continue;
      ids.add(id);
      steps.push(env.DB.prepare("INSERT OR IGNORE INTO games (id, name, source, steam, created_at) VALUES (?, ?, 'anticheat', ?, ?)").bind(id, game.name, game.steam, Date.now()));
    }
    for (const [store, value] of [['steam', game.steam], ['epic', game.epic]]) {
      if (value) steps.push(env.DB.prepare('INSERT OR IGNORE INTO game_keys (store, store_id, game_id) VALUES (?, ?, ?)').bind(store, value, id));
    }
    steps.push(env.DB.prepare(
      `INSERT OR REPLACE INTO anticheat (game_id, slug, status, anticheats, notes, changed, run) VALUES (?, ?, ?, ?, ?, ?, ?)`,
    ).bind(id, game.slug, game.status, JSON.stringify(game.anticheats), JSON.stringify(game.notes), game.changed, run));
  }
  if (steps.length) await env.DB.batch(steps);
  return json({ stored: games.length });
}

/// A page's address from a game's name, the same as games-index.js.
function slug(name) {
  return name.replace(/[™®©'’]/g, '').normalize('NFKD').replace(/[\u0300-\u036f]/g, '').toLowerCase()
    .replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
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
    `SELECT comments.id, comments.parent_id, comments.user_id, comments.body, comments.hidden, comments.created_at, users.name, users.tag, users.picture, ${badgeOf('users')},
       (SELECT COUNT(*) FROM votes WHERE comment_id = comments.id) AS votes,
       EXISTS (SELECT 1 FROM votes WHERE comment_id = comments.id AND user_id = ?2) AS voted
     FROM comments JOIN users ON users.id = comments.user_id
     WHERE comments.game_id = ?1 AND (comments.hidden = 0 OR comments.user_id = ?2) AND NOT EXISTS (SELECT 1 FROM bans WHERE ${bannedHere})
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
async function addComment(request, env, context, user, id) {
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
  context.waitUntil(tellAboutComment(env, user, id, comment, answered).catch((error) => console.error(`Mail failed: ${error.message}`)));
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
/// Things that get someone banned, not things someone merely dislikes.
const REPORT_REASONS = {
  harassment: 'Harassment or threats',
  hate: 'Hate speech',
  sexual: 'Sexual content',
  doxxing: 'Sharing private information',
  malware: 'Malware or dangerous links',
  scam: 'Spam or scams',
  impersonation: 'Impersonation',
  illegal: 'Illegal content',
};
const BAN_REASONS = { ...REPORT_REASONS, abuse: 'Abusing the report system', other: 'Breaking the rules' };

const isAdmin = (user) => user?.role === 'admin';
const isModerator = (env, user) => isAdmin(user) || user?.role === 'mod';

/// The badge a person shows. An Admin who chooses to be a Member shows as a Mod.
const badgeOf = (users) => `CASE WHEN ${users}.role = 'admin' AND ${users}.public = 1 THEN 'Admin' WHEN ${users}.role IN ('admin', 'mod') THEN 'Mod' END AS badge`;

/// Only ever between no role and Mod: this can't touch an Admin, or make one. The person comes from the Users tab's list,
/// so it's always someone who exists.
async function changeMods(env, back, id, action) {
  await env.DB.prepare(action === 'add' ? "UPDATE users SET role = 'mod' WHERE id = ? AND role IS NULL AND name IS NOT NULL" : "UPDATE users SET role = NULL WHERE id = ? AND role = 'mod'")
    .bind(id).run();
  return redirect(back);
}

/// Only an account without a role: a Mod has to stop being one first, and that's an Admin's call.
const banning = (env, user, id, reason) => env.DB.prepare(
  `INSERT OR REPLACE INTO bans (provider, provider_id, reason, by_user, created_at) SELECT provider, provider_id, ?, ?, ? FROM users WHERE id = ? AND role IS NULL`,
).bind(BAN_REASONS[Object.hasOwn(BAN_REASONS, reason) ? reason : 'other'], user.id, Date.now(), id);

async function changeBan(request, env, user, back, id, action) {
  if (action === 'ban') await banning(env, user, id, String((await request.formData()).get('reason'))).run();
  else await env.DB.prepare('DELETE FROM bans WHERE (provider, provider_id) IN (SELECT provider, provider_id FROM users WHERE id = ?)').bind(id).run();
  return redirect(back);
}

async function reportedBy(env, user) {
  if (!user) return new Set();
  const { results } = await env.DB.prepare('SELECT target FROM reports WHERE user_id = ?').bind(user.id).all();
  return new Set(results.map((row) => row.target));
}

/// `kind` is a table's name, from the route. A moderator's report hides the entry at once.
async function report(request, env, user, id, kind, entry) {
  const anchor = `/games/${id}#${kind === 'comments' ? 'comment' : 'rating'}-${entry}`;
  const target = await env.DB.prepare(`SELECT id, ${kind === 'comments' ? 'user_id' : 'NULL AS user_id'} FROM ${kind} WHERE id = ? AND game_id = ?`)
    .bind(entry, id).first();
  if (!target || target.user_id === user.id) return redirect(anchor);
  const form = await request.formData();
  const reason = String(form.get('reason'));
  if (!Object.hasOwn(REPORT_REASONS, reason) || form.get('confirm') !== '1') return redirect(`/games/${id}?error=report#comments`);
  const now = Date.now();
  const today = await env.DB.prepare('SELECT COUNT(*) AS n FROM reports WHERE user_id = ? AND created_at > ?')
    .bind(user.id, now - 24 * 3600 * 1000).first('n');
  if (today >= REPORTS_A_DAY) return redirect(`/games/${id}?error=reports#comments`);
  await env.DB.prepare('INSERT OR IGNORE INTO reports (target, user_id, created_at, reason) VALUES (?, ?, ?, ?)').bind(entry, user.id, now, reason).run();
  const count = await env.DB.prepare('SELECT COUNT(*) AS n FROM reports WHERE target = ?').bind(entry).first('n');
  if (count >= REPORTS_TO_HIDE || isModerator(env, user)) await env.DB.prepare(`UPDATE ${kind} SET hidden = 1 WHERE id = ?`).bind(entry).run();
  return redirect(anchor);
}

const PER_PAGE = 30;
const WEEK = 7 * 24 * 3600 * 1000;
const offset = (page) => (page - 1) * PER_PAGE;

/// The numbers on the tabs. A rating replaced in the meantime has a new ID, so its reports are simply not counted.
function tabCounts(env) {
  const waiting = (table) => `(SELECT COUNT(*) FROM ${table} WHERE id IN (SELECT target FROM reports))`;
  const hidden = (table) => `(SELECT COUNT(*) FROM ${table} WHERE hidden = 1 AND id NOT IN (SELECT target FROM reports))`;
  return env.DB.prepare(
    `SELECT ${waiting('comments')} + ${waiting('ratings')} AS reports, ${hidden('comments')} + ${hidden('ratings')} AS hidden,
       (SELECT COUNT(*) FROM suggestions WHERE status IN ('pending', 'approved')) AS profiles,
       (SELECT COUNT(*) FROM game_issues WHERE state = 'open') AS issues, (SELECT COUNT(*) FROM users WHERE name IS NOT NULL) AS users`,
  ).first();
}

/// What the Overview shows. Each is small and over everything there is: a dashboard people open now and then.
async function overview(env) {
  const now = Date.now(), since = now - 30 * 24 * 3600 * 1000;
  const [totals, tiers, days, backends, trouble, versions, unprofiled] = await env.DB.batch([
    env.DB.prepare(
      `SELECT (SELECT COUNT(*) FROM users WHERE name IS NOT NULL) AS users, (SELECT COUNT(*) FROM users WHERE created_at > ?1) AS new_users,
         (SELECT COUNT(*) FROM comments) AS comments, (SELECT COUNT(*) FROM comments WHERE created_at > ?1) AS new_comments,
         (SELECT COUNT(*) FROM ratings) AS ratings, (SELECT COUNT(*) FROM ratings WHERE created_at > ?1) AS new_ratings,
         (SELECT COUNT(*) FROM games) AS games, (SELECT COUNT(DISTINCT game_id) FROM ratings WHERE hidden = 0) AS rated,
         (SELECT COUNT(*) FROM bans) AS bans`,
    ).bind(now - WEEK),
    env.DB.prepare('SELECT tier, COUNT(*) AS n FROM ratings WHERE hidden = 0 GROUP BY tier'),
    env.DB.prepare("SELECT date(created_at / 1000, 'unixepoch') AS day, COUNT(*) AS n FROM ratings WHERE created_at > ? GROUP BY day").bind(since),
    env.DB.prepare(
      `SELECT COALESCE(backend, 'Not known') AS name, COUNT(*) AS n, SUM(tier IN ('bronze', 'borked')) AS low
       FROM ratings WHERE hidden = 0 GROUP BY name ORDER BY n DESC LIMIT 6`,
    ),
    env.DB.prepare(
      `SELECT ratings.game_id, COALESCE(games.name, ratings.game_id) AS name, COUNT(*) AS n, SUM(tier IN ('bronze', 'borked')) AS low
       FROM ratings LEFT JOIN games ON games.id = ratings.game_id WHERE hidden = 0 GROUP BY ratings.game_id HAVING low > 0 ORDER BY low DESC, n DESC LIMIT 6`,
    ),
    env.DB.prepare("SELECT overpass AS name, COUNT(*) AS n FROM ratings WHERE overpass IS NOT NULL AND created_at > ? GROUP BY overpass ORDER BY n DESC LIMIT 6").bind(since),
    env.DB.prepare(
      `SELECT games.id, games.name, COUNT(*) AS n FROM ratings JOIN games ON games.id = ratings.game_id
       WHERE games.profile_file IS NULL AND ratings.hidden = 0 GROUP BY games.id ORDER BY n DESC, MAX(ratings.created_at) DESC LIMIT 6`,
    ),
  ]);
  const perDay = new Map(days.results.map((row) => [row.day, row.n]));
  const month = Array.from({ length: 30 }, (_, i) => {
    const day = new Date(now - (29 - i) * 24 * 3600 * 1000).toISOString().slice(0, 10);
    return { day, n: perDay.get(day) ?? 0 };
  });
  return {
    totals: totals.results[0], tiers: Object.fromEntries(tiers.results.map((row) => [row.tier, row.n])), month,
    backends: backends.results, trouble: trouble.results, versions: versions.results, unprofiled: unprofiled.results,
  };
}

/// Reported entries, or those hidden with no report left. `show` narrows it to comments or ratings.
async function queue(env, tab, show, page) {
  const where = (table) => (tab === 'hidden' ? `${table}.hidden = 1 AND ${table}.id NOT IN (SELECT target FROM reports)` : `${table}.id IN (SELECT target FROM reports)`);
  const parts = {
    comments: `SELECT 'comments' AS kind, comments.id, comments.body AS text, NULL AS tier, comments.hidden, comments.created_at AS created_at, comments.game_id,
       users.id AS author_id, users.name AS author, users.tag, users.role, users.picture, games.name AS game, (SELECT COUNT(*) FROM reports WHERE target = comments.id) AS reports
     FROM comments JOIN users ON users.id = comments.user_id LEFT JOIN games ON games.id = comments.game_id WHERE ${where('comments')}`,
    ratings: `SELECT 'ratings' AS kind, ratings.id, ratings.comment AS text, ratings.tier, ratings.hidden, ratings.created_at AS created_at, ratings.game_id,
       NULL AS author_id, NULL AS author, NULL AS tag, NULL AS role, NULL AS picture, games.name AS game, (SELECT COUNT(*) FROM reports WHERE target = ratings.id) AS reports
     FROM ratings LEFT JOIN games ON games.id = ratings.game_id WHERE ${where('ratings')}`,
  };
  const { results } = await env.DB.prepare(
    `${(Object.hasOwn(parts, show) ? [parts[show]] : Object.values(parts)).join(' UNION ALL ')} ORDER BY reports DESC, created_at DESC LIMIT ? OFFSET ?`,
  ).bind(PER_PAGE + 1, offset(page)).all();
  const { results: filed } = await env.DB.prepare(
    `SELECT reports.target, reports.reason, users.name, users.tag, users.reports_dismissed FROM reports JOIN users ON users.id = reports.user_id
     WHERE reports.target IN (SELECT value FROM json_each(?)) ORDER BY reports.created_at`,
  ).bind(JSON.stringify(results.map((entry) => entry.id))).all();
  return results.map((entry) => ({ ...entry, filed: filed.filter((row) => row.target === entry.id) }));
}

/// Settles an entry: its reports go either way, so it only comes back if people report it again. Finding nothing in an
/// entry counts against those who reported it, which is how abuse of reports shows. `ban` also bans the author.
async function review(env, user, back, kind, entry, action, ban) {
  const reason = ban ? await env.DB.prepare('SELECT reason FROM reports WHERE target = ? AND reason IS NOT NULL').bind(entry).first('reason') : null;
  const author = ban && kind === 'comments' ? await env.DB.prepare('SELECT user_id FROM comments WHERE id = ?').bind(entry).first('user_id') : null;
  await env.DB.batch([
    env.DB.prepare(`UPDATE ${kind} SET hidden = ? WHERE id = ?`).bind(action === 'hide' ? 1 : 0, entry),
    ...(action === 'show' ? [env.DB.prepare('UPDATE users SET reports_dismissed = reports_dismissed + 1 WHERE id IN (SELECT user_id FROM reports WHERE target = ?)').bind(entry)] : []),
    env.DB.prepare('DELETE FROM reports WHERE target = ?').bind(entry),
    ...(author ? [banning(env, user, author, reason)] : []),
  ]);
  return redirect(back);
}

/// One page of the Users tab, accounts with a username only: search by name, and by the tag after a #. Filters narrow it
/// to the team or to banned accounts.
async function people(env, q, filter, page) {
  const [, text, tag] = q.trim().match(/^(.*?)\s*(?:#(\d{0,4}))?$/s);
  const like = (value) => value.replace(/[\\%_]/g, '\\$&');
  const { results } = await env.DB.prepare(
    `SELECT users.id, users.name, users.tag, users.picture, users.role, users.public, users.created_at, users.reports_dismissed,
       (SELECT COUNT(*) FROM comments WHERE user_id = users.id) AS comments, (SELECT reason FROM bans WHERE ${bannedHere}) AS banned
     FROM users WHERE users.name LIKE ?1 ESCAPE '\\' AND COALESCE(users.tag, '') LIKE ?2
       ${filter === 'mods' ? "AND users.role IN ('admin', 'mod')" : ''} ${filter === 'banned' ? `AND EXISTS (SELECT 1 FROM bans WHERE ${bannedHere})` : ''}
     ORDER BY ${text ? 'users.name' : 'users.created_at DESC'} LIMIT ?3 OFFSET ?4`,
  ).bind(`%${like(text)}%`, `${tag ?? ''}%`, PER_PAGE + 1, offset(page)).all();
  return results;
}

async function peopleRows(env, user, url) {
  const list = await people(env, url.searchParams.get('q') ?? '', url.searchParams.get('filter'), 1);
  return personRows(list.slice(0, PER_PAGE), user, usersTabBack(url));
}

// Suggested profiles

const fromGitHub = (request, env) => Boolean(env.SYNC_TOKEN) && request.headers.get('Authorization') === `Bearer ${env.SYNC_TOKEN}`;

/// What's waiting for a decision, with the file each one would replace and why it can't go in as it stands.
async function suggestions(env, page) {
  const { results } = await env.DB.prepare(
    `SELECT suggestions.*, games.name AS game, games.profile_text AS current FROM suggestions LEFT JOIN games ON games.id = suggestions.game_id
     WHERE status IN ('pending', 'approved') ORDER BY created_at LIMIT ? OFFSET ?`,
  ).bind(PER_PAGE + 1, offset(page)).all();
  return results.map((entry) => ({ ...entry, problems: profileProblems(entry.body, entry.current) }));
}

/// Rejecting leaves the rating sent with the suggestion on the page as unconfirmed, and closes the GitHub issue filed
/// with it: the page shows it closed at once, and the relay does it now or, if that fails, at its next cron.
async function decide(env, context, back, entry, action) {
  if (action === 'reject') {
    const refused = await env.DB.prepare("DELETE FROM suggestions WHERE id = ? AND status = 'pending' RETURNING id, issue").bind(entry).first();
    if (!refused) return redirect(back);
    await env.DB.prepare('UPDATE ratings SET unconfirmed = 1 WHERE suggestion = ?').bind(entry).run();
    const number = refused.issue;
    if (number) {
      await env.DB.batch([
        env.DB.prepare('INSERT OR IGNORE INTO issue_closes (number, created_at) VALUES (?, ?)').bind(number, Date.now()),
        env.DB.prepare("UPDATE game_issues SET state = 'closed' WHERE number = ?").bind(number),
      ]);
      context.waitUntil(env.RELAY.fetch(`${env.REPORT_RELAY}/closures`, { method: 'POST' }).catch((error) => console.error(`Closing failed: ${error.message}`)));
    }
    return redirect(back);
  }
  const found = await env.DB.prepare(
    'SELECT body, profile_text AS current FROM suggestions LEFT JOIN games ON games.id = suggestions.game_id WHERE suggestions.id = ?',
  ).bind(entry).first();
  if (found && !profileProblems(found.body, found.current).length) {
    await env.DB.prepare("UPDATE suggestions SET status = 'approved' WHERE id = ? AND status = 'pending'").bind(entry).run();
  }
  return redirect(back);
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
const profilePath = (name, tag) => `/users/${encodeURIComponent(name)}-${tag}`;
const number = (tag) => `<span class="number">#${escape(tag)}</span>`;
/// A name always with its tag, for moderators and profiles.
const fullName = (name, tag) => `${escape(name)}${number(tag)}`;
/// A name that links to the person. The tag only shows when `twins` says someone else here has the same name.
const personLink = (name, tag, twins) => `<a class="person" href="${profilePath(name, tag)}">${escape(name)}${twins?.has(name.toLowerCase()) ? number(tag) : ''}</a>`;

/// The names on a page held by more than one person.
function twinsIn(authors) {
  const tags = new Map();
  for (const { name, tag } of authors) {
    if (name) tags.set(name.toLowerCase(), (tags.get(name.toLowerCase()) ?? new Set()).add(tag));
  }
  return new Set([...tags].filter(([, seen]) => seen.size > 1).map(([name]) => name));
}
const hue = (name) => [...name].reduce((sum, c) => (sum * 31 + c.charCodeAt(0)) % 360, 7);
/// Words first, split at anything that isn't a letter or digit, then a capital after a small letter inside one word:
/// Super!Blast and MusicBee give two letters, Musicbee and DOOM one.
const words = (name) => name.replace(/['’]/g, '').split(/[^\p{L}\p{N}]+/u).filter(Boolean);
function nameLetters(name) {
  const all = words(name);
  const parts = all.length === 1 ? all[0].split(/(?<=\p{Ll})(?=\p{Lu})/u) : all;
  return parts.slice(0, 2).map((word) => [...word][0]).join('').toUpperCase();
}

/// A made cover's mark: at least two characters when the name has them. A number that starts the name comes first, up to
/// four digits, then the name's letters, then whatever comes next: 100% Orange Juice 100, 7 Days to Die 7D, 2XKO 2X,
/// Musicbee MU. The same rule as `initials` in the app's HomeView.
export function initials(name) {
  const number = [...(words(name)[0]?.match(/^\p{N}+/u)?.[0] ?? '')].slice(0, 4).join('');
  if ([...number].length > 1) return number;
  const letters = nameLetters(name);
  if ([...letters].length > 1) return letters;
  return [...words(name).join('')].slice(0, 2).join('').toUpperCase() || '?';
}

function medal(tier, large = false) {
  if (!tier) return '<span class="medal none">Not rated</span>';
  return `<span class="medal ${tier}${large ? ' large' : ''}">${TITLES[tier]}</span>`;
}

/// The person's picture when there is one, over their initials.
function avatar(name, picture) {
  const art = picture ? `<img src="/pictures/${picture}.jpg" alt="" loading="lazy" onerror="this.remove()">` : '';
  return `<span class="avatar" style="--hue:${hue(name)}">${escape(nameLetters(name) || '?')}${art}</span>`;
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

const KINDS = { profile: 'Profile', preset: 'Known fix', anticheat: 'Anti-cheat info' };
const COLUMNS = [['name', 'Game'], ['tier', 'Rating'], ['ratings', 'Ratings'], ['last', 'Last Rated'], ['category', 'Category'], ['kind', 'Type']];

function card(game) {
  const kind = KINDS[game.source] ?? '';
  // The list's script gives each picture its address as it nears the screen.
  return `<a class="card" href="/games/${game.id}" data-name="${escape(game.name.toLowerCase())}" data-tier="${game.tier ?? 'none'}" data-ratings="${game.ratings}" data-last="${game.last_rated ?? 0}" data-category="${escape(game.category ?? '')}" data-kind="${kind}"${game.anticheat ? ' data-anticheat="1"' : ''}>
  ${cover(game).replace(/(<img\b[^>]*?) src=/g, '$1 data-src=')}
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
  const filters = [['all', 'All'], ...TIERS.map((tier) => [tier, TITLES[tier]]), ['none', 'Not rated'], ['anticheat', 'Anti-cheat']]
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
      const passes = filter === 'all' || card.dataset.tier === filter || (filter === 'anticheat' && card.dataset.anticheat);
      card.hidden = !(card.dataset.name.includes(text) && passes);
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
  // Pictures load a screen and a half ahead and let go four screens behind, so a long list stays light either way.
  // The gap between the two keeps a picture from being dropped and fetched again by scrolling back and forth.
  const pictures = (card) => card.querySelectorAll('img[data-src]');
  const near = new IntersectionObserver((seen) => {
    for (const { target, isIntersecting } of seen) {
      if (isIntersecting) for (const image of pictures(target)) if (!image.hasAttribute('src')) image.src = image.dataset.src;
    }
  }, { rootMargin: '150% 0px' });
  const far = new IntersectionObserver((seen) => {
    for (const { target, isIntersecting } of seen) {
      if (!isIntersecting) for (const image of pictures(target)) image.removeAttribute('src');
    }
  }, { rootMargin: '400% 0px' });
  for (const card of cards) { near.observe(card); far.observe(card); }
</script>`, moderator, 'games');
}

/// One bar a tier, as wide as its share of the ratings.
function breakdown(game) {
  return `<div class="bars">${TIERS.map((tier) => {
    const n = game.counts[tier] || 0;
    return `<div class="bar"><span class="label">${TITLES[tier]}</span><span class="track"><span class="fill ${tier}" style="width:${Math.round(100 * n / game.ratings)}%"></span></span><span class="count">${n}</span></div>`;
  }).join('')}</div>`;
}

/// The flag; the dialog in `reportDialog` asks the rest. `name` is empty for an anonymous rating.
function reportButton(game, kind, entry, user, reports, name, text) {
  if (!user) return '';
  if (reports.has(entry)) return '<p class="reported">Reported</p>';
  return `<button class="link flag" type="button" data-report="/games/${game.id}/${kind}/${entry}/report" data-kind="${kind === 'comments' ? 'comment' : 'rating'}" data-name="${escape(name)}" data-text="${escape(String(text ?? '').slice(0, 400))}"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 2a1 1 0 0 1 1 1v1h12a1 1 0 0 1 .8 1.600L16 9.500l2.800 3.900A1 1 0 0 1 18 15H6v6a1 1 0 1 1-2 0V3a1 1 0 0 1 1-1Z"/></svg>Report</button>`;
}

function reportDialog() {
  return `<dialog id="report" class="sheet">
  <form class="write" method="post">
    <h2 id="report-title"></h2>
    <blockquote id="report-quote"></blockquote>
    <label for="report-reason">Reason:</label>
    <select id="report-reason" name="reason" required>
      <option value="">Choose a reason</option>
      ${Object.entries(REPORT_REASONS).map(([key, title]) => `<option value="${key}">${title}</option>`).join('')}
    </select>
    <label class="check"><input type="checkbox" name="confirm" value="1" required> Confirm you're not abusing the report system. Doing so will result in a ban.</label>
    <div class="decide">
      <button class="button danger" type="submit" disabled>Send Report</button>
      <button class="button quiet" type="button" value="cancel">Cancel</button>
    </div>
  </form>
</dialog>
<script>
  const dialog = document.getElementById('report'), form = dialog.querySelector('form'), send = form.querySelector('[type=submit]');
  document.addEventListener('click', (event) => {
    const flag = event.target.closest('[data-report]');
    if (!flag) return;
    const { report, kind, name, text } = flag.dataset;
    form.reset();
    form.action = report;
    send.disabled = true;
    document.getElementById('report-title').textContent = name ? 'Do you want to report ' + name + ' for this ' + kind + '?' : 'Do you want to report this ' + kind + '?';
    const quote = document.getElementById('report-quote');
    quote.textContent = text;
    quote.hidden = !text;
    dialog.showModal();
  });
  form.addEventListener('input', () => { send.disabled = !form.checkValidity(); });
  form.querySelector('[value=cancel]').addEventListener('click', () => dialog.close());
</script>`;
}

function ratingCard(game, rating, user, reports, own, twins) {
  const facts = [
    rating.chip, rating.macos && `macOS ${rating.macos}`, rating.wine && `Wine ${rating.wine}`,
    rating.runtime && rating.runtime !== 'not installed' && `Runtime ${rating.runtime}`, rating.backend,
    rating.fps && `${Math.round(rating.fps)} fps`,
  ].filter(Boolean);
  return `<article class="rating" id="rating-${rating.id}">
  <div class="line">${medal(rating.tier)}${rating.unconfirmed ? '<span class="chip" title="The profile sent with this rating was rejected, so it barely counts toward the game\'s overall rating.">Unconfirmed</span>' : ''}${rating.author || rating.badge ? `<span class="who author">${rating.author ? `${avatar(rating.author, rating.author_picture)}${personLink(rating.author, rating.author_tag, twins)}` : ''}${roleBadge(rating.badge)}</span>` : ''}<time datetime="${new Date(rating.created_at).toISOString()}">${date(rating.created_at)}</time></div>
  ${rating.comment ? `<p class="comment">${escape(rating.comment)}</p>` : ''}
  <p class="facts">${facts.map((fact) => `<span>${escape(fact)}</span>`).join('')}</p>
  ${rating.id === own?.id ? '' : reportButton(game, 'ratings', rating.id, user, reports, rating.author, rating.comment)}
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

function commentCard(game, comment, user, reports, twins) {
  const mine = comment.user_id === user?.id;
  return `<article class="rating" id="comment-${comment.id}">
  <div class="line"><span class="who">${avatar(comment.name, comment.picture)}${personLink(comment.name, comment.tag, twins)}${roleBadge(comment.badge)}</span><time datetime="${new Date(comment.created_at).toISOString()}">${date(comment.created_at)}</time></div>
  <p class="comment">${escape(comment.body)}</p>
  ${comment.hidden ? '<p class="muted">Hidden after reports. Only you can see this.</p>' : ''}
  <div class="answers">
    ${voteButton(game, comment, user)}
    ${replyForm(game, comment, user)}
    ${mine ? `<form method="post" action="/games/${game.id}/comments/${comment.id}/delete"><button class="link" type="submit">Delete</button></form>` : reportButton(game, 'comments', comment.id, user, reports, comment.name, comment.body)}
  </div>
  ${comment.replies?.length ? `<div class="replies">${comment.replies.map((reply) => commentCard(game, reply, user, reports, twins)).join('\n')}</div>` : ''}
</article>`;
}

function commentForm(game, user, banned) {
  const back = encodeURIComponent(`/games/${game.id}#comments`);
  if (banned) return '<p class="muted">This account is banned, so it can\'t post.</p>';
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
      if (!anonymous && answer.issue) await env.DB.prepare('INSERT OR IGNORE INTO issue_reporters (number, user_id) VALUES (?, ?)').bind(answer.issue, user.id).run();
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
  report: 'A report needs a reason, and your confirmation.',
};

const ABOUT_SOURCES = { steam: 'Steam', gog: 'GOG', thegamesdb: 'TheGamesDB' };
const COVER_SOURCES = { steam: 'Steam', gog: 'GOG', thegamesdb: 'TheGamesDB', steamgriddb: 'SteamGridDB', moderator: 'a moderator' };

/// For a moderator: a picture from the Mac, shrunk in the browser; an image's address; or back to automatic.
function coverForm(game, error) {
  const said = game.art_wanted ? `Waiting for ${escape(game.art_wanted)}. It's fetched within half an hour.`
    : game.art ? `This cover came from ${COVER_SOURCES[game.art_source] ?? 'an unknown source'}.` : 'No cover found yet.';
  return `<section id="cover" popover>
  <h2>Change Cover</h2>
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
  <script>
    ${error === 'cover' ? "document.getElementById('cover').showPopover();" : ''}
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

/// The middle of what players got, which one odd run can't pull around. Rates at or below 1 are menus and loading.
function median(values) {
  const sorted = values.filter((value) => value > 1).sort((a, b) => a - b);
  if (!sorted.length) return null;
  const middle = sorted.length >> 1;
  return Math.round(sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2);
}

/// What frame rate to expect, from the ratings on the page, and by chip when more than one is among them.
function expectedRate(game) {
  const runs = game.rating_list.filter((rating) => rating.fps > 1 && !rating.unconfirmed);
  const fps = median(runs.map((rating) => rating.fps));
  if (!fps) return { stat: '', chips: '' };
  const chips = [...new Set(runs.map((rating) => rating.chip).filter(Boolean))];
  return {
    stat: `<span class="stat" title="The middle of ${runs.length === 1 ? '1 run' : `${runs.length} runs`} players rated">Expect about <strong>${fps} fps</strong></span>`,
    chips: chips.length < 2 ? '' : `<p class="muted">${chips.map((chip) => `${escape(chip)}: ${median(runs.filter((rating) => rating.chip === chip).map((rating) => rating.fps))} fps`).join(' · ')}</p>`,
  };
}

const ISSUE_STATES = { open: 'Open', fixed: 'Fixed', closed: 'Closed' };

const WATCHDOG = 'https://areweanticheatyet.com';
/// What we can say about the usual ones, in our own words, with the picture's name on AreWeAntiCheatYet. By lower-case name,
/// since the list spells some several ways.
const ANTI_CHEATS = {
  'easy anti-cheat': ['eac', 'From Epic Games. A game\'s developer decides whether it runs under Wine and Proton.'],
  battleye: ['battleye', 'A widely used third-party anti-cheat. A game\'s developer decides whether it runs under Wine and Proton.'],
  vac: ['vac', 'Valve\'s anti-cheat for games on Steam.'],
  'valve anti-cheat': ['vac', 'Valve\'s anti-cheat for games on Steam.'],
  'ea anticheat': ['ea', 'Electronic Arts\' own anti-cheat, which uses a Windows kernel driver.'],
  vanguard: ['vanguard', 'Riot Games\' anti-cheat. Its Windows kernel driver starts with the computer.'],
  ricochet: ['ricochet', 'Activision\'s anti-cheat for Call of Duty, with a Windows kernel driver.'],
  'denuvo anti-cheat': ['denuvo', 'From Denuvo, with a Windows kernel driver.'],
  xigncode3: ['xigncode3', 'From Wellbia, common in Korean online games.'],
  'nprotect gameguard': ['nprotect', 'From INCA Internet, common in Korean online games.'],
  punkbuster: ['punkbuster', 'From Even Balance, an older anti-cheat found in many shooters.'],
  fairfight: ['fairfight', 'Runs on the game\'s servers and watches how people play, so nothing runs on your Mac.'],
  hyperion: ['hyperion', 'Made by Byfron, now part of Roblox.'],
  arbiter: ['arbiter', ''],
  faceit: ['faceit', 'From FACEIT, for its own competitive servers.'],
  equ8: ['equ8', ''],
  'nexon game security': ['nexon', 'Nexon\'s own anti-cheat.'],
  arkos: ['arkos', ''],
  sard: ['sard', ''],
};
/// Need a Windows kernel driver, which can't run on a Mac. The same list as the app's AntiCheat.swift.
const KERNEL_ONLY = ['ea anticheat', 'ea javelin', 'vanguard', 'ricochet', 'denuvo anti-cheat'];
const LINUX_STATES = {
  Supported: 'Works on Linux, and the developer allows it.',
  Running: 'Runs on Linux, without the developer\'s word on it.',
  Planned: 'The developer plans Linux support.',
  Broken: 'Doesn\'t work on Linux.',
  Denied: 'The developer has shut out Linux.',
};

const shield = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 2 4 5v6c0 5 3.400 9.300 8 11 4.600-1.700 8-6 8-11V5l-8-3Z"/></svg>';

/// An anti-cheat's picture, from where it's published, over a plain shield when there's none.
function antiCheatIcon(name) {
  const file = ANTI_CHEATS[name.toLowerCase()]?.[0];
  return `<span class="ac-icon">${shield}${file ? `<img src="${WATCHDOG}/anticheats/${file}.webp" alt="" loading="lazy" referrerpolicy="no-referrer" onerror="this.remove()">` : ''}</span>`;
}

/// A button for each anti-cheat; each opens a small card, and clicking or tapping elsewhere closes it.
function antiCheatRow(game) {
  const guard = game.anticheat;
  if (!guard) return '';
  const notes = guard.notes.length ? `<ul class="ac-notes">${guard.notes.map(([text, url]) => `<li>${url ? `<a href="${escape(url)}" target="_blank" rel="noopener">${escape(text)}</a>` : escape(text)}</li>`).join('')}</ul>` : '';
  const cards = guard.names.map((name, i) => {
    const known = ANTI_CHEATS[name.toLowerCase()];
    const kernel = KERNEL_ONLY.includes(name.toLowerCase());
    return `<div class="ac-card" id="anticheat-${i}" popover>
  <h3>${antiCheatIcon(name)}${escape(name)}</h3>
  ${known ? `<p>${escape(known[1])}</p>` : ''}
  ${kernel ? '<p class="problem">Needs a Windows kernel driver, which can\'t run on a Mac.</p>' : ''}
  <p><span class="state">${escape(guard.status || 'Unknown')}</span> ${escape(LINUX_STATES[guard.status] ?? '')}</p>
  <p class="muted small">That's on Linux, through Wine or Proton, which OverPass is built on too. It's a good guide for a Mac, not a test on one.</p>
  ${notes}
  <p class="ac-more"><a href="${WATCHDOG}/game/${encodeURIComponent(guard.slug)}" target="_blank" rel="noopener">See this game on AreWeAntiCheatYet</a></p>
</div>`;
  }).join('');
  return `<p class="anticheats">${guard.names.map((name, i) => `<button type="button" class="ac" popovertarget="anticheat-${i}">${antiCheatIcon(name)}${escape(name)}</button>`).join('')}</p>${cards}`;
}

/// GitHub issues about the game, open ones first.
function issueList(game) {
  if (!game.issues.length) return '';
  const short = (title) => (title.startsWith(`${game.name}: `) ? title.slice(game.name.length + 2) : title);
  return `<section id="issues">
  <h2>Issues</h2>
  <ul class="issues">${game.issues.map((issue) => `<li><a href="${escape(issue.url)}" rel="noopener">${escape(short(issue.title))}</a><span class="state ${issue.state}">${ISSUE_STATES[issue.state]}</span></li>`).join('')}</ul>
</section>`;
}

function gamePage(game, said, signedInAs, reports, error, moderator, own) {
  // A banned person reads the page as someone who isn't signed in.
  const user = signedInAs?.banned ? null : signedInAs;
  const twins = twinsIn([...said.flatMap((comment) => [comment, ...comment.replies]), ...game.rating_list.map((rating) => ({ name: rating.author, tag: rating.author_tag }))]);
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
  const rate = expectedRate(game), side = issueList(game) + settings;
  const ratings = game.rating_list.length
    ? game.rating_list.map((rating) => ratingCard(game, rating, user, reports, own, twins)).join('\n')
    : '<p class="empty">No ratings yet. Play it in OverPass and tell others how it ran.</p>';
  return shell(`${game.name} on Mac · OverPass`, `How ${game.name} runs on a Mac with OverPass.`, `
${game.hero ? `<img class="hero" src="${escape(game.hero)}" alt="" referrerpolicy="no-referrer" onerror="this.remove()">` : ''}
<a class="back" href="/games">All games</a>
<header class="game">
  ${moderator ? `<button class="cover-button" type="button" popovertarget="cover" aria-label="Change Cover">${cover(game)}<span class="upload">Change Cover</span></button>` : cover(game)}
  <div class="game-intro">
    <h1>${escape(game.name)}</h1>
    <p class="summary">${medal(game.tier, true)}<span>${game.ratings === 1 ? '1 rating' : `${game.ratings} ratings`}${game.unconfirmed ? `, ${game.unconfirmed} unconfirmed` : ''}</span>${rate.stat}</p>
    ${rate.chips}
    ${game.verified ? `<p class="muted">Tested by OverPass: ${escape(TITLES[game.verified] ?? game.verified)}</p>` : ''}
    ${game.about ? `<p class="about">${escape(game.about).replace(/\n+/g, '<br>')}</p><p class="muted credit">From ${ABOUT_SOURCES[game.about_source] ?? 'the store'}</p>` : ''}
    ${game.stores.length ? `<p class="stores">${game.stores.map((store) => `<a href="${escape(store.url)}" rel="noopener">${escape(store.name)}</a>`).join('')}</p>` : ''}
    ${antiCheatRow(game)}
  </div>
</header>
${moderator ? coverForm(game, error) : ''}
<div class="columns">
  ${side ? `<aside>${side}</aside>` : ''}
  <div>
    <section id="ratings">
      <h2>Ratings</h2>
      ${RATING_ERRORS[error] ? `<p class="problem" role="alert">${RATING_ERRORS[error]}</p>` : ''}
      ${game.ratings ? breakdown(game) : ''}
      ${moderator ? ratingForm(game, own) : ''}
      ${ratings}
    </section>
    <section id="comments">
      <h2>Comments</h2>
      ${COMMENT_ERRORS[error] ? `<p class="problem" role="alert">${COMMENT_ERRORS[error]}</p>` : ''}
      ${commentForm(game, user, signedInAs?.banned)}
      ${said.map((comment) => commentCard(game, comment, user, reports, twins)).join('\n')}
    </section>
  </div>
</div>
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
</script>
${user ? reportDialog() : ''}`, moderator, 'games');
}

const ACCOUNT_ERRORS = {
  signin: 'Signing in didn\'t work. Try again.',
  name: 'A username has 2 to 30 letters, digits, spaces, dots, dashes or underscores, and starts with a letter or digit.',
  taken: 'Too many people have that username. Try another.',
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

function suggestionCard(entry, query) {
  const facts = [entry.overpass && `OverPass ${entry.overpass}`, entry.wine && `Wine ${entry.wine}`, entry.runtime && `Runtime ${entry.runtime}`].filter(Boolean).map(escape).join(' · ');
  const issue = entry.issue ? ` · <a href="${REPOSITORY}/issues/${entry.issue}" rel="noopener">Issue #${entry.issue}</a>` : '';
  const log = entry.log ? ` · <a href="${escape(entry.log)}" rel="noopener">Logs</a>` : '';
  const shot = entry.shot ? ` · <a href="${escape(entry.shot)}" rel="noopener">Screenshot</a>` : '';
  const buttons = entry.status === 'approved' ? '<p class="muted">Approved. Goes out with the next publish, within the hour.</p>'
    : `<div class="decide">${entry.problems.length ? '' : `<form method="post" action="/moderation/suggestions/${entry.id}/approve${query}"><button class="button" type="submit">Approve</button></form>`}<form method="post" action="/moderation/suggestions/${entry.id}/reject${query}"><button class="button quiet" type="submit" title="Leaves its rating unconfirmed, counting 1%, and closes any issue">Reject</button></form></div>`;
  return `<article class="rating">
  <div class="line"><span class="who"><a href="/games/${entry.game_id}">${escape(entry.game ?? entry.game_id)}</a></span><time datetime="${new Date(entry.created_at).toISOString()}">${date(entry.created_at)}</time></div>
  <p class="muted">profiles/${escape(entry.profile_id)}.ini · ${entry.current ? 'changes the file' : 'a new file'}${facts ? ` · ${facts}` : ''}${issue}${log}${shot}</p>
  ${entry.comment ? `<p class="comment">${escape(entry.comment)}</p>` : ''}
  <pre class="diff">${difference(entry)}</pre>
  ${entry.problems.length ? `<p class="muted">Can't be approved here: ${entry.problems.map(escape).join('; ')}.</p>` : ''}
  ${buttons}
</article>`;
}

/// How many reports gave each reason, biggest first, and who sent them, with any of theirs that came to nothing.
function reportFacts(entry) {
  if (!entry.filed.length) return '';
  const reasons = new Map();
  for (const { reason } of entry.filed) reasons.set(reason, (reasons.get(reason) ?? 0) + 1);
  const chips = [...reasons].sort((a, b) => b[1] - a[1]).map(([reason, n]) => `<span class="chip">${escape(REPORT_REASONS[reason] ?? 'No reason given')}${n > 1 ? ` × ${n}` : ''}</span>`);
  const who = entry.filed.map((row) => `${fullName(row.name, row.tag)}${row.reports_dismissed ? ` <span class="muted">(${row.reports_dismissed} dismissed)</span>` : ''}`);
  return `<p class="chips">${chips.join('')}</p><p class="muted small">Reported by ${who.join(', ')}</p>`;
}

function moderationCard(entry, query) {
  const form = (path, title, style) => `<form method="post" action="/moderation/${path}"><button class="button ${style}" type="submit">${title}</button></form>`;
  const act = (action, title, style, extra = '') => form(`${entry.kind}/${entry.id}/${action}${query}${extra}`, title, style);
  const buttons = entry.hidden ? [act('show', 'Show', 'quiet')] : [act('hide', 'Hide', 'danger'), act('show', 'Keep', 'quiet')];
  if (entry.kind === 'comments' && !entry.role) buttons.push(act('hide', 'Hide and Ban Author', 'danger', `${query ? '&' : '?'}ban=1`));
  if (entry.picture) buttons.push(form(`pictures/${entry.picture}/remove${query}`, 'Remove Picture', 'quiet'));
  return `<article class="rating">
  <div class="line"><span class="who">${entry.tier ? medal(entry.tier) : `${avatar(entry.author, entry.picture)}<a class="person" href="${profilePath(entry.author, entry.tag)}">${fullName(entry.author, entry.tag)}</a>`}</span><time datetime="${new Date(entry.created_at).toISOString()}">${date(entry.created_at)}</time></div>
  ${entry.text ? `<p class="comment">${escape(entry.text)}</p>` : ''}
  ${reportFacts(entry)}
  <p class="muted small"><a href="/games/${entry.game_id}">${escape(entry.game ?? entry.game_id)}</a> · ${entry.hidden ? 'Hidden' : 'Showing'}</p>
  <div class="decide">${buttons.join('')}</div>
</article>`;
}

const usersTabBack = (url) => {
  const query = new URLSearchParams({ tab: 'users' });
  for (const key of ['q', 'filter']) if (url.searchParams.get(key)) query.set(key, url.searchParams.get(key));
  return `?${query}`;
};

/// Rows of the Users tab. Admins change Mods; Admins and Mods ban anyone without a role.
function personRows(list, viewer, query) {
  if (!list.length) return '<p class="empty">Nobody by that name.</p>';
  return list.map((person) => {
    const facts = [`Joined ${date(person.created_at)}`, person.comments === 1 ? '1 comment' : `${person.comments} comments`,
      ...(person.reports_dismissed ? [`${person.reports_dismissed} reports dismissed`] : [])];
    const actions = [];
    if (isAdmin(viewer) && person.role !== 'admin' && !person.banned) {
      actions.push(`<form method="post" action="/moderation/mods/${person.id}/${person.role ? 'remove' : 'add'}${query}"><button class="button quiet" type="submit">${person.role ? 'Remove Mod' : 'Make Mod'}</button></form>`);
    }
    if (person.banned) actions.push(`<form method="post" action="/moderation/users/${person.id}/unban${query}"><button class="button quiet" type="submit">Lift Ban</button></form>`);
    else if (!person.role) {
      actions.push(`<details class="ban"><summary class="button quiet">Ban…</summary><form method="post" action="/moderation/users/${person.id}/ban${query}">
        <select name="reason" aria-label="Reason">${Object.entries(BAN_REASONS).map(([key, title]) => `<option value="${key}">${title}</option>`).join('')}</select>
        <button class="button danger" type="submit">Ban ${escape(person.name)}</button>
      </form></details>`);
    }
    return `<article class="person-row">
  <span class="who">${avatar(person.name, person.picture)}<a class="person" href="${profilePath(person.name, person.tag)}">${fullName(person.name, person.tag)}</a>${roleBadge(person.role === 'admin' ? 'Admin' : person.role && 'Mod')}${person.banned ? '<span class="chip bad">Banned</span>' : ''}</span>
  <span class="muted small">${person.banned ? `${escape(person.banned)} · ` : ''}${facts.join(' · ')}</span>
  <div class="row-actions">${actions.join('')}</div>
</article>`;
  }).join('\n');
}

/// Previous and Next, keeping the tab and its filters.
function pager(params, page, more) {
  if (page === 1 && !more) return '';
  const link = (to, title) => `<a class="button quiet" href="/moderation?${new URLSearchParams({ ...params, page: to })}">${title}</a>`;
  return `<nav class="pager">${page > 1 ? link(page - 1, 'Previous') : '<span></span>'}<span class="muted small">Page ${page}</span>${more ? link(page + 1, 'Next') : '<span></span>'}</nav>`;
}

function pills(params, key, chosen, options) {
  return `<nav class="filters" aria-label="Show">${options.map(([value, title]) => {
    const query = new URLSearchParams({ ...params, ...(value ? { [key]: value } : {}) });
    return `<a class="pill" href="/moderation?${query}"${(chosen ?? '') === value ? ' aria-current="true"' : ''}>${title}</a>`;
  }).join('')}</nav>`;
}

/// A headline number, what it adds up from this week, and where to go for it.
const tile = (title, value, note, tab) => {
  const body = `<span class="tile-title">${title}</span><strong>${value.toLocaleString('en-GB')}</strong>${note ? `<span class="muted small">${note}</span>` : ''}`;
  return tab ? `<a class="tile" href="/moderation?tab=${tab}">${body}</a>` : `<div class="tile">${body}</div>`;
};

/// A column a day. One series, so the title says what it is; each column names its day and count on hover.
function monthChart(month) {
  const most = Math.max(1, ...month.map((day) => day.n));
  const column = ({ day, n }) => {
    const label = `${date(Date.parse(day))}: ${n === 1 ? '1 rating' : `${n} ratings`}`;
    return `<span class="day" title="${label}" aria-label="${label}" role="img"><i style="height:${n ? Math.max(4, Math.round(100 * n / most)) : 0}%"></i></span>`;
  };
  return `<div class="days">${month.map(column).join('')}</div>
  <p class="axis muted small"><span>${date(Date.parse(month[0].day))}</span><span>Most in a day: ${most}</span><span>Today</span></p>`;
}

/// Bars for one measure: how much of each thing's ratings were Bronze or Borked. Words beside them carry the numbers.
function lowBars(rows, link) {
  if (!rows.length) return '<p class="empty">No ratings yet.</p>';
  return `<div class="bars">${rows.map((row) => {
    const share = Math.round(100 * row.low / row.n);
    return `<div class="bar wide-label"><span class="label">${link ? link(row) : escape(row.name)}</span><span class="track"><span class="fill borked" style="width:${share}%"></span></span><span class="count">${share}% of ${row.n}</span></div>`;
  }).join('')}</div>`;
}

function overviewTab(data, counts, admin) {
  const { totals, tiers, month, backends, trouble, versions, unprofiled } = data;
  const week = (n) => (n ? `+${n} this week` : 'None this week');
  const rated = TIERS.reduce((sum, tier) => sum + (tiers[tier] || 0), 0);
  const game = (row) => `<a href="/games/${row.game_id ?? row.id}">${escape(row.name)}</a>`;
  const list = (rows, line) => (rows.length ? `<ul class="plain">${rows.map(line).join('')}</ul>` : '<p class="empty">Nothing yet.</p>');
  return `<section class="tiles">
  ${tile('Reports waiting', counts.reports, '', 'reports')}
  ${tile('Hidden', counts.hidden, '', 'hidden')}
  ${admin ? tile('Suggested profiles', counts.profiles, '', 'profiles') : ''}
  ${tile('Open issues', counts.issues, '', 'issues')}
</section>
<section class="tiles">
  ${tile('Users', totals.users, week(totals.new_users), 'users')}
  ${tile('Ratings', totals.ratings, week(totals.new_ratings))}
  ${tile('Comments', totals.comments, week(totals.new_comments))}
  ${tile('Games rated', totals.rated, `of ${totals.games.toLocaleString('en-GB')}`)}
</section>
<div class="panels">
  <section class="panel span"><h2>Ratings, last 30 days</h2>${monthChart(month)}</section>
  <section class="panel"><h2>How games run</h2>${rated ? breakdown({ counts: tiers, ratings: rated }) : '<p class="empty">No ratings yet.</p>'}</section>
  <section class="panel"><h2>Bronze and Borked by graphics</h2>${lowBars(backends)}</section>
  <section class="panel"><h2>Games in most trouble</h2>${lowBars(trouble, game)}</section>
  <section class="panel"><h2>Rated, with no profile</h2>${list(unprofiled, (row) => `<li>${game(row)}<span class="muted small">${row.n === 1 ? '1 rating' : `${row.n} ratings`}</span></li>`)}</section>
  <section class="panel"><h2>OverPass versions, last 30 days</h2>${list(versions, (row) => `<li>${escape(row.name)}<span class="muted small">${row.n === 1 ? '1 rating' : `${row.n} ratings`}</span></li>`)}</section>
</div>`;
}

const ISSUE_FILTERS = [['open', 'Open'], ['fixed', 'Fixed'], ['closed', 'Closed']];

async function issuesTab(env, state, page) {
  const chosen = ISSUE_FILTERS.some(([value]) => value === state) ? state : 'open';
  const { results } = await env.DB.prepare(
    `SELECT game_issues.*, games.name AS game FROM game_issues LEFT JOIN games ON games.id = game_issues.game_id WHERE state = ? ORDER BY number DESC LIMIT ? OFFSET ?`,
  ).bind(chosen, PER_PAGE + 1, offset(page)).all();
  return `<div class="tab-head">${pills({ tab: 'issues' }, 'state', chosen, ISSUE_FILTERS)}<a href="${REPOSITORY}/issues">All on GitHub</a></div>
  ${results.length ? `<ul class="issues">${results.slice(0, PER_PAGE).map((issue) => `<li><a href="${escape(issue.url)}" rel="noopener">#${issue.number} ${escape(issue.title)}</a><a class="small" href="/games/${issue.game_id}">${escape(issue.game ?? issue.game_id)}</a><span class="state ${issue.state}">${ISSUE_STATES[issue.state]}</span></li>`).join('')}</ul>` : '<p class="empty">None here.</p>'}
  ${pager({ tab: 'issues', state: chosen }, page, results.length > PER_PAGE)}
  <p class="muted small">Issues about a game. Those about OverPass itself are on GitHub only.</p>`;
}

function usersTab(list, viewer, url, page) {
  const filter = url.searchParams.get('filter') ?? '';
  const q = url.searchParams.get('q') ?? '';
  const params = { tab: 'users', ...(q ? { q } : {}) };
  return `<div class="tab-head">
  <input id="people-search" type="search" value="${escape(q)}" placeholder="Search usernames" aria-label="Search usernames" autocomplete="off" spellcheck="false">
  ${pills(params, 'filter', filter, [['', 'Everyone'], ['mods', 'Team'], ['banned', 'Banned']])}
</div>
<div id="people">${personRows(list.slice(0, PER_PAGE), viewer, usersTabBack(url))}</div>
${pager({ ...params, ...(filter ? { filter } : {}) }, page, list.length > PER_PAGE)}
<script>
  // Searches the accounts as you type. Only people who exist are listed, so only they can be chosen.
  const field = document.getElementById('people-search'), rows = document.getElementById('people');
  let waiting, asked = 0;
  field.addEventListener('input', () => {
    clearTimeout(waiting);
    waiting = setTimeout(async () => {
      const query = new URLSearchParams(location.search), mine = ++asked;
      query.delete('page');
      query.set('q', field.value);
      const answer = await fetch('/moderation/users?' + query);
      if (mine !== asked || !answer.ok) return;
      rows.innerHTML = await answer.text();
      document.querySelector('.pager')?.remove();
      history.replaceState(null, '', '?' + query);
    }, 180);
  });
</script>`;
}

/// One tab at a time, loaded only when asked for, so a long queue costs nothing elsewhere.
async function dashboard(env, user, url) {
  const admin = isAdmin(user);
  const asked = url.searchParams.get('tab');
  const tab = ['reports', 'hidden', 'issues', 'users', ...(admin ? ['profiles'] : [])].includes(asked) ? asked : 'overview';
  const page = Math.max(1, Number.parseInt(url.searchParams.get('page'), 10) || 1);
  const counts = await tabCounts(env);
  const tabs = [
    ['overview', 'Overview'], ['reports', 'Reports', counts.reports], ['hidden', 'Hidden', counts.hidden],
    ...(admin ? [['profiles', 'Suggested Profiles', counts.profiles]] : []), ['issues', 'Issues', counts.issues], ['users', 'Users', counts.users],
  ];
  url.searchParams.delete('ban');
  const query = url.search || `?tab=${tab}`;
  let body;
  if (tab === 'overview') body = overviewTab(await overview(env), counts, admin);
  if (tab === 'reports' || tab === 'hidden') {
    const show = url.searchParams.get('show');
    const entries = await queue(env, tab, show, page);
    const params = { tab, ...(show ? { show } : {}) };
    body = `${pills({ tab }, 'show', show, [['', 'All'], ['comments', 'Comments'], ['ratings', 'Ratings']])}
    ${entries.length ? `<div class="board">${entries.slice(0, PER_PAGE).map((entry) => moderationCard(entry, query)).join('\n')}</div>` : `<p class="empty">${tab === 'hidden' ? 'Nothing hidden.' : 'No reports waiting.'}</p>`}
    ${pager(params, page, entries.length > PER_PAGE)}`;
  }
  if (tab === 'profiles') {
    const entries = await suggestions(env, page);
    body = `${entries.length ? entries.slice(0, PER_PAGE).map((entry) => suggestionCard(entry, query)).join('\n') : '<p class="empty">None waiting.</p>'}
    ${pager({ tab }, page, entries.length > PER_PAGE)}`;
  }
  if (tab === 'issues') body = await issuesTab(env, url.searchParams.get('state'), page);
  if (tab === 'users') body = usersTab(await people(env, url.searchParams.get('q') ?? '', url.searchParams.get('filter'), page), user, url, page);
  return shell('Moderation · OverPass', 'Reports, suggested profiles, issues and users.', `
<div class="dashboard">
  <header class="page"><h1>Moderation</h1></header>
  <nav class="dash-tabs" aria-label="Moderation">${tabs.map(([id, title, count]) => `<a href="/moderation?tab=${id}"${id === tab ? ' aria-current="page"' : ''}>${title}${count ? `<span class="count-badge">${count.toLocaleString('en-GB')}</span>` : ''}</a>`).join('')}</nav>
  ${body}
</div>`, true);
}

/// A person's public page. The tag always shows here. Ratings only for a Public Contributor, whose name is on them anyway.
async function profilePage(env, viewer, url, encoded, tag) {
  const name = decodeURIComponent(encoded);
  const moderator = isModerator(env, viewer);
  const person = await env.DB.prepare(
    `SELECT users.id, users.name, users.tag, users.picture, users.role, users.public, users.created_at, users.reports_dismissed,
       (SELECT reason FROM bans WHERE ${bannedHere}) AS banned, ${badgeOf('users')}
     FROM users WHERE users.name = ? AND users.tag = ?`,
  ).bind(name, tag).first();
  if (!person || (person.banned && !moderator)) return html(shell('Nobody here · OverPass', 'No such person.', '<header class="page"><h1>Nobody here</h1><p>No one has this name and number.</p></header>', moderator), 404);
  const [said, rated] = await env.DB.batch([
    env.DB.prepare(
      `SELECT comments.id, comments.body, comments.game_id, comments.created_at, games.name AS game FROM comments LEFT JOIN games ON games.id = comments.game_id
       WHERE comments.user_id = ? AND comments.hidden = 0 ORDER BY comments.created_at DESC LIMIT 20`,
    ).bind(person.id),
    env.DB.prepare(
      `SELECT ratings.tier, ratings.game_id, ratings.created_at, games.name AS game FROM ratings LEFT JOIN games ON games.id = ratings.game_id
       WHERE ratings.user_id = ?1 AND ratings.hidden = 0 AND ?2 = 1 ORDER BY ratings.created_at DESC LIMIT 20`,
    ).bind(person.id, person.public),
  ]);
  const back = `?tab=users&q=${encodeURIComponent(person.name)}`;
  return (viewer ? personal : html)(shell(`${person.name} · OverPass`, `${person.name} on OverPass.`, `
<header class="profile public">
  <div class="portrait">${avatar(person.name, person.picture)}</div>
  <div class="naming"><h1>${fullName(person.name, person.tag)}</h1><p>${roleBadge(person.badge)}${person.banned ? '<span class="chip bad">Banned</span> ' : ''}Joined ${date(person.created_at)}</p></div>
</header>
${moderator ? `<div class="people-tools">${personRows([person].map((row) => ({ ...row, comments: said.results.length })), viewer, back)}</div>` : ''}
${rated.results.length ? `<section><h2>Ratings</h2><ul class="plain">${rated.results.map((row) => `<li><a href="/games/${row.game_id}">${escape(row.game ?? row.game_id)}</a>${medal(row.tier)}</li>`).join('')}</ul></section>` : ''}
<section>
  <h2>Comments</h2>
  ${said.results.length ? said.results.map((comment) => `<article class="rating"><div class="line"><a href="/games/${comment.game_id}#comment-${comment.id}">${escape(comment.game ?? comment.game_id)}</a><time datetime="${new Date(comment.created_at).toISOString()}">${date(comment.created_at)}</time></div><p class="comment">${escape(comment.body)}</p></article>`).join('\n') : '<p class="empty">No comments yet.</p>'}
</section>`, moderator));
}

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
    ${roleBadge(user.role === 'admin' && user.public ? 'Admin' : user.role && 'Mod')}
    <h1 data-value="${escape(user.name || 'Choose a username')}"><input id="name" name="name" required minlength="2" maxlength="30" size="1" value="${escape(user.name)}" placeholder="Choose a username" aria-label="Username" autocomplete="username"${user.name ? '' : ' autofocus'}></h1>
    <label class="pen" for="name" title="Change Username">${pen}</label>
    <button class="button save" type="submit">Save</button>
  </form>
  ${user.name ? `<p class="small muted">Your number is ${number(user.tag)}. It shows on <a href="${profilePath(user.name, user.tag)}">your profile</a>, and beside your name when someone else on a page has the same one.</p>` : '<p>This is the name others will see.</p>'}
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

function updatesForm(user, address) {
  if (address) {
    return `<section>
  <h2>E-mail updates</h2>
  <p class="muted">Updates go to ${escape(address)}.</p>
  <form method="post" action="/account/updates/stop"><button class="button quiet" type="submit">Stop E-mail Updates</button></form>
</section>`;
  }
  return `<section>
  <h2>E-mail updates</h2>
  <p class="muted">Get a mail when someone replies to your comment, comments on a game you rated, or an issue you reported from your account is fixed. This is off until you turn it on. Your address is then stored readable, since the site has to send to it, and every mail has a link that turns this off. <a href="/privacy">Privacy</a></p>
  <form class="account" method="post" action="/account/updates">
    <label for="updates-address">${user.provider === 'email' ? 'Your address: the one you sign in with, or another, which gets a code first' : 'Your address, which gets a code first'}</label>
    <input id="updates-address" name="address" type="email" required maxlength="254" autocomplete="email">
    <button class="button quiet" type="submit">Turn On</button>
  </form>
</section>`;
}

function updatesCodePage(address, error) {
  return shell('Enter your code · OverPass', 'Enter the code we mailed you.', `
<header class="page"><h1>Check your mail</h1><p>Type the 6-character code sent to ${escape(address)}. It works for 10 minutes, and the mail may land in spam.</p></header>
${EMAIL_ERRORS[error] ? `<p class="problem" role="alert">${EMAIL_ERRORS[error]}</p>` : ''}
<form class="account" method="post" action="/account/updates/code">
  <input type="hidden" name="address" value="${escape(address)}">
  <label for="code">Code</label>
  <input id="code" name="code" required maxlength="8" autocomplete="one-time-code" autocapitalize="characters" spellcheck="false" autofocus>
  <button class="button" type="submit">Turn On</button>
</form>`);
}

const stopPage = (token) => shell('E-mail updates · OverPass', 'Stop e-mail updates.', `
<header class="page"><h1>Stop e-mail updates?</h1><p>Your address is removed at once. Your account stays.</p></header>
<form method="post" action="/updates/stop/${token}"><button class="button" type="submit">Stop E-mail Updates</button></form>`);

const stoppedPage = () => shell('E-mail updates · OverPass', 'E-mail updates are off.', `
<header class="page"><h1>E-mail updates are off</h1><p>Your address is gone, and no more mails will come. You can turn them on again on <a href="/account">your account page</a>.</p></header>`);

function accountPage(user, error, moderator, next = '/account', updates = null) {
  const message = ACCOUNT_ERRORS[error] ?? EMAIL_ERRORS[error];
  const problem = message ? `<p class="problem" role="alert">${message}</p>` : '';
  if (!user) {
    return shell('Sign in · OverPass', 'Sign in to OverPass.', `
<header class="page"><h1>Sign in</h1><p>An account lets you comment on game pages. You don't need one to play or to rate games from the app.</p></header>
${problem}
<p class="choices"><a class="button" href="/auth/google?next=${encodeURIComponent(next)}">Sign in with Google</a> <a class="button quiet" href="/auth/email?next=${encodeURIComponent(next)}">Sign in with E-mail</a></p>
<p class="muted">OverPass keeps the username you choose, a picture if you add one, and either Google's ID for you or a scrambled form of your address that can't be read back. Not your e-mail or name, unless you turn on e-mail updates. <a href="/privacy">Privacy</a></p>`);
  }
  return shell('Your account · OverPass', 'Your OverPass account.', `
${profileHeader(user)}
${problem}
${user.banned ? `<p class="problem" role="alert">This account is banned for: ${escape(user.banned)}. You can still read, but you can't post, vote or report, and your comments are hidden.</p>` : ''}
${user.name ? publicForm(user) : ''}
${user.name ? updatesForm(user, updates) : ''}
<div class="choices">
  <form method="post" action="/auth/signout"><button class="button quiet" type="submit">Sign Out</button></form>
  ${user.provider === 'email' ? '<a class="button quiet" href="/auth/email?mode=reset">Change Password</a>' : ''}
</div>
<section>
  <h2>Delete account</h2>
  <p class="muted">Removes your account, username, picture, comments and any address kept for e-mail updates at once. Ratings you sent from the app stay on the site, anonymous.</p>
  <form method="post" action="/account/delete"><button class="button danger" type="submit">Delete Account</button></form>
</section>`, moderator);
}

const privacyPage = (moderator) => shell('Privacy · OverPass', 'What OverPass keeps about you, and for how long.', `
<header class="page"><h1>Privacy</h1><p>What OverPass and this site keep, and for how long.</p></header>
<section>
  <h2>Accounts</h2>
  <p>Signing in with Google gives this site an ID for you that means nothing elsewhere. It's stored with the username you choose, a random four-digit number that tells you apart from anyone with the same name, and the date. Your e-mail and name aren't requested, and nothing comes from your Google profile.</p>
  <p>Signing in with e-mail keeps a keyed hash of your address, which can't be turned back into it, and a salted hash of your password. You type your address each time, and the code goes to what you typed. The mail goes out through our web host (web23.osl1.nordkapp.net), whose mail logs show the address and when, as any mail server's do. While you sign in we keep hashes of your address and your network address for up to a day, to limit tries.</p>
  <p>You can add a picture on your account page. It's public next to your comments, shrunk before it's sent, and gone as soon as you replace or remove it, or delete your account. Admins can remove it.</p>
  <p>A cookie keeps you signed in for 90 days. It's the only cookie here, apart from a short-lived one while you sign in. There's no tracking and no advertising.</p>
  <p>You can delete your account on <a href="/account">its page</a>. It's removed at once, with your picture and comments.</p>
  <p>Your profile page is public: your username and number, the date you joined and your comments, and your ratings if you're a Public Contributor.</p>
  <p>If an account is banned for breaking the rules, we keep its Google ID or scrambled address with the reason, even after the account is deleted, so that the ban holds.</p>
</section>
<section>
  <h2>E-mail updates</h2>
  <p>These are off unless you turn them on on your account page. You then get a mail when someone replies to your comment, comments on a game you rated, or an issue you reported from your account is fixed. The mail names the game and links to it, and says nothing else about anyone.</p>
  <p>This is the one place your address is stored readable, because the site has to send to it without you typing it. It's used for these mails and nothing else. An address other than the one you sign in with needs a mailed code before it's kept. It goes through our web host like the sign-in mails, so the host's mail logs show it.</p>
  <p>Every mail has a link that turns this off and removes the address at once. Turning it off on your account page does the same, and so does deleting your account. We also keep which reports you sent from your account, to tell you when they're fixed; that goes with your account too.</p>
</section>
<section>
  <h2>Comments</h2>
  <p>A comment or reply is public on the game's page, with your username and the date. You can delete your own at any time; replies others wrote to it stay.</p>
  <p>Signed-in people can upvote a comment. The number is public. Who gave which upvote is never shown, and it's kept only so each person counts once. You can take an upvote back, and yours go when your account does.</p>
  <p>Signed-in people can report a comment or a rating, with a reason. Three reports hide it until it's reviewed. Who reported what is shown only to Admins and Mods, and it's removed when the report is settled or the account is deleted. We keep a count of each person's reports that came to nothing, to spot abuse of reports. It goes with the account.</p>
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
  <p>Covers and banners load directly from where they're published, such as Steam, GOG or TheGamesDB, and anti-cheat pictures from AreWeAntiCheatYet, so your browser or the app connects to those services to show them.</p>
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
