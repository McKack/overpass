// Arctim report relay (reports.arctim.no): files a problem report or feature request sent from an app as a GitHub
// issue, so reporting needs no GitHub account. Each app has a path of its own and a repository in APPS
// ({"overpass": "McKack/overpass"}); the log zip and screenshot are kept here (KV) and linked from the issue.
//
//   POST /<app>/report              multipart: title, what, steps, block (the app's details block), zip (the log
//                                   zip; not when the block says "log: none"), screenshot (JPEG, optional),
//                                   profile (a submitted profile's text), install (the app's random ID, for ratings)
//                                   -> { "url": "<issue url>" }
//   POST /<app>/draft               the same fields, without title and steps: a rating to finish on the site. Keeps
//                                   it for a day -> { "url": "<the site's page for it>" }
//   POST /<app>/draft/<ticket>      JSON { tier, comment }, from that page: sends the draft, once -> { "url": ... }
//   GET  /<app>/logs/<id>/<name>.zip   the zip a report linked
//   GET  /<app>/shots/<id>.jpg         the screenshot it showed
//
// Only reports whose details block carries a valid checksum are accepted, at most HOURLY_LIMIT per address an
// hour. The issue has the same sections as the app repository's forms, so its check workflow treats it the same.
// A block with "kind: feature" is a feature request: it takes the feature form's heading, no log and no `report`.
// One with "kind: profile" is a rating and a profile: the text in `profile`, an optional comment, and a log if asked for.
// One with "kind: rating" is a rating alone: no profile or log, and a comment only if it's Bronze or Borked.
// Ratings go to the games database, for the site's game pages, and the answer is that page's address. A submitted
// profile waits there too, for a moderator. A report with a log can carry a `rating:` line as well, with or without a
// profile: it makes its issue, the rating and profile go to the database too, and the answer is the issue.
//
// How Did It Run? goes through a draft: the app uploads what it knows and opens the page the answer names, where the
// person picks the medal and writes the comment. The page's random ticket is the only key to a draft, and the database
// keeps only its hash. /report remains for the app's other reports and for older versions.

const MAX_ZIP = 20 * 1024 * 1024;
const MAX_SHOT = 4 * 1024 * 1024;
const KEEP_SECONDS = 180 * 24 * 3600;
const DRAFT_SECONDS = 24 * 3600;
const TIERS = { platinum: "Platinum", gold: "Gold", silver: "Silver", bronze: "Bronze", borked: "Borked" };

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    try {
      const apps = JSON.parse(env.APPS || "{}");
      const [, app, ...rest] = url.pathname.split("/");
      const repo = apps[app];
      if (!repo) return new Response("Arctic Imaginarium report relay\n", { status: url.pathname === "/" ? 200 : 404 });
      const path = "/" + rest.join("/");
      if (request.method === "POST" && path === "/report") return await report(request, env, url, app, repo);
      if (request.method === "POST" && path === "/draft") return await draft(request, env, app);
      // Anyone may knock: it only works through the queue, which only the site's moderators fill.
      if (request.method === "POST" && path === "/closures") return json({ closed: await closeIssues(env, repo) });
      const ticket = path.match(/^\/draft\/([0-9a-f]{64})$/);
      if (request.method === "POST" && ticket) return await sendDraft(request, env, url, app, repo, ticket[1]);
      const log = path.match(/^\/logs\/([0-9a-f-]{36})\/[^/]+\.zip$/);
      if (request.method === "GET" && log) return await download(log[1], env);
      const shot = path.match(/^\/shots\/([0-9a-f-]{36})\.jpg$/);
      if (request.method === "GET" && shot) return await screenshot(shot[1], env);
      return new Response("Not found\n", { status: 404 });
    } catch (error) {
      // Cloudflare D1's free plan takes 100,000 rows written a day; past that, writes fail until 00:00 UTC.
      const message = String(error?.message ?? error);
      if (/\b(limit|exceeded|quota)\b/i.test(message) && /writ|row/i.test(message)) {
        console.error(`Database writes refused until the daily reset: ${message}`);
        const day = new Date();
        const reset = Date.UTC(day.getUTCFullYear(), day.getUTCMonth(), day.getUTCDate() + 1);
        return new Response(JSON.stringify({
          error: `The report service can't save anything until ${new Date(reset).toUTCString().replace(/:00 GMT$/, " UTC")}. Please send it again after that.`,
          resets_at: new Date(reset).toISOString(),
        }), { status: 503, headers: { "Content-Type": "application/json", "Retry-After": String(Math.max(60, Math.ceil((reset - Date.now()) / 1000))) } });
      }
      return json({ error: "The relay failed: " + message }, 500);
    }
  },

  // GitHub's own schedule skips most runs, and art and issue links only move when sync-games.yml runs.
  async scheduled(controller, env, context) {
    context.waitUntil(startSync(env));
    context.waitUntil(closeIssues(env, JSON.parse(env.APPS || "{}").overpass));
  },
};

/// Closes what moderators turned down. A row stays until GitHub agrees, so a failure is tried again by the next cron.
async function closeIssues(env, repo) {
  const { results } = await env.GAMES.prepare("SELECT number FROM issue_closes ORDER BY created_at LIMIT 20").all();
  if (!results.length) return 0;
  const token = await issueToken(env, repo);
  let closed = 0;
  for (const { number } of results) {
    await github(env, `/repos/${repo}/issues/${number}/comments`, token, {
      method: "POST",
      body: JSON.stringify({ body: "An admin reviewed the settings sent with this report and didn't add them, so this report is closed." }),
    });
    const response = await github(env, `/repos/${repo}/issues/${number}`, token, {
      method: "PATCH",
      body: JSON.stringify({ state: "closed", state_reason: "not_planned" }),
    });
    if (!response.ok && response.status !== 404 && response.status !== 410) {
      console.error(`GitHub wouldn't close #${number} (${response.status})`);
      continue;
    }
    await env.GAMES.prepare("DELETE FROM issue_closes WHERE number = ?").bind(number).run();
    closed++;
  }
  return closed;
}

async function startSync(env) {
  const repo = JSON.parse(env.APPS || "{}").overpass;
  const response = await github(env, `/repos/${repo}/actions/workflows/sync-games.yml/dispatches`, await issueToken(env, repo), {
    method: "POST",
    body: JSON.stringify({ ref: "main" }),
  });
  if (!response.ok) {
    const needs = response.headers.get("X-Accepted-GitHub-Permissions");
    throw new Error(`GitHub wouldn't start the sync (${response.status}, needs ${needs}): ${await response.text()}`);
  }
}

/// Counts one more report from the sender's address, or answers that there have been too many.
async function counted(request, env) {
  const address = request.headers.get("CF-Connecting-IP") || "unknown";
  const hour = Math.floor(Date.now() / 3600000);
  const countKey = `count:${address}:${hour}`;
  const count = parseInt((await env.REPORTS.get(countKey)) || "0", 10);
  if (count >= parseInt(env.HOURLY_LIMIT || "5", 10))
    return json({ error: "Too many reports from this network in the last hour. Try again later." }, 429);
  return async () => env.REPORTS.put(countKey, String(count + 1), { expirationTtl: 7200 });
}

async function report(request, env, url, app, repo) {
  if (!env.GITHUB_TOKEN && !(env.APP_ID && env.APP_PRIVATE_KEY)) return json({ error: "The relay isn't set up yet." }, 503);
  const count = await counted(request, env);
  if (count instanceof Response) return count;

  const form = await request.formData();
  const title = String(form.get("title") || "").trim().slice(0, 200);
  const what = String(form.get("what") || "").trim().slice(0, 20000);
  const steps = String(form.get("steps") || "").trim().slice(0, 20000);
  const block = String(form.get("block") || "").replace(/\r\n/g, "\n").trim();
  const zip = file(form.get("zip"));
  const shot = file(form.get("screenshot"));
  const feature = /^kind: feature$/m.test(block);
  const submitted = /^kind: profile$/m.test(block);
  const rated = /^kind: rating$/m.test(block);
  // A submitted profile's comment is optional, and a rating's unless it's low.
  if (!title || (!what && !submitted && !rated)) return json({ error: "The report needs a title and what happened." }, 400);
  if (rated && !what && /^rating: (bronze|borked)$/m.test(block)) return json({ error: "A low rating needs a comment." }, 400);
  if (!(await validBlock(block))) return json({ error: "The details block is missing or was changed." }, 400);
  const profile = String(form.get("profile") || "").replace(/\r\n/g, "\n").trim().slice(0, 20000);
  const withoutLog = /^log: none$/m.test(block);
  if (!zip && !withoutLog) return json({ error: "The log zip is missing." }, 400);
  if (submitted && !profile) return json({ error: "A submitted profile needs its text." }, 400);
  if (zip && zip.size > MAX_ZIP) return json({ error: "The log zip is larger than 20 MB." }, 413);
  if (shot && (shot.size > MAX_SHOT || shot.type !== "image/jpeg"))
    return json({ error: "The screenshot must be a JPEG of at most 4 MB." }, 413);

  const install = String(form.get("install") || "").toLowerCase().match(/^[0-9a-f-]{36}$/)?.[0] ?? null;

  await count();
  return deliver(env, url, app, repo, {
    title, what, steps, block, profile, install,
    zip: zip && { name: zip.name, bytes: await zip.arrayBuffer() },
    shot: shot && (await shot.arrayBuffer()),
  });
}

/// Keeps a rating from the app until the person finishes it on the site, and answers with that page's address. The
/// checks the medal and comment need wait for that page.
async function draft(request, env, app) {
  const count = await counted(request, env);
  if (count instanceof Response) return count;
  const form = await request.formData();
  const block = String(form.get("block") || "").replace(/\r\n/g, "\n").trim();
  const zip = file(form.get("zip"));
  const shot = file(form.get("screenshot"));
  const profile = String(form.get("profile") || "").replace(/\r\n/g, "\n").trim().slice(0, 20000);
  if (!(await validBlock(block)) || !/^rating: /m.test(block)) return json({ error: "The details block is missing or was changed." }, 400);
  if (!zip && !/^log: none$/m.test(block)) return json({ error: "The log zip is missing." }, 400);
  if (/^kind: profile$/m.test(block) && !profile) return json({ error: "A submitted profile needs its text." }, 400);
  if (zip && zip.size > MAX_ZIP) return json({ error: "The log zip is larger than 20 MB." }, 413);
  if (shot && (shot.size > MAX_SHOT || shot.type !== "image/jpeg"))
    return json({ error: "The screenshot must be a JPEG of at most 4 MB." }, 413);

  await count();
  const now = Date.now();
  await env.GAMES.prepare("DELETE FROM drafts WHERE expires_at < ?").bind(now).run();
  const ticket = [...crypto.getRandomValues(new Uint8Array(32))].map((b) => b.toString(16).padStart(2, "0")).join("");
  const hash = await sha256(ticket);
  // An hour past the draft, so one sent in its last moments still has them.
  const keep = { expirationTtl: DRAFT_SECONDS + 3600 };
  if (zip) await env.REPORTS.put(`draft-log:${hash}`, await zip.arrayBuffer(), keep);
  if (shot) await env.REPORTS.put(`draft-shot:${hash}`, await shot.arrayBuffer(), keep);
  await env.GAMES.prepare(
    "INSERT INTO drafts (ticket_hash, app, block, what, profile, install, log_name, shot, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
  ).bind(hash, app, block, String(form.get("what") || "").trim().slice(0, 20000), profile || null,
    String(form.get("install") || "").toLowerCase().match(/^[0-9a-f-]{36}$/)?.[0] ?? null,
    zip ? safeName(zip.name || "OverPass Logs.zip") : null, shot ? 1 : 0, now, now + DRAFT_SECONDS * 1000).run();
  return json({ url: `${JSON.parse(env.SITES)[app]}/report/${ticket}` });
}

/// Sends a draft with the medal and comment from its page. Two presses at once can't both send: the first claims the row
/// and a failure gives it back. A claim left by a run that died runs out after a minute.
async function sendDraft(request, env, url, app, repo, ticket) {
  if (!env.GITHUB_TOKEN && !(env.APP_ID && env.APP_PRIVATE_KEY)) return json({ error: "The relay isn't set up yet." }, 503);
  const hash = await sha256(ticket);
  const now = Date.now();
  const row = await env.GAMES.prepare(
    "UPDATE drafts SET claimed_at = ? WHERE ticket_hash = ? AND app = ? AND expires_at > ? AND (claimed_at IS NULL OR claimed_at < ?) RETURNING *",
  ).bind(now, hash, app, now, now - 60000).first();
  if (!row) return json({ error: "This report was already sent, or has expired." }, 410);
  const release = () => env.GAMES.prepare("UPDATE drafts SET claimed_at = NULL WHERE ticket_hash = ?").bind(hash).run();
  try {
    const { tier, comment } = await request.json();
    const what = String(comment || "").replace(/\r\n/g, "\n").trim().slice(0, 20000);
    if (!TIERS[tier]) {
      await release();
      return json({ error: "Pick a medal." }, 400);
    }
    if (!what && (row.log_name || tier === "bronze" || tier === "borked")) {
      await release();
      return json({ error: row.log_name ? "Say what happened: it goes in the report with your logs." : "Bronze and Borked need a comment saying what went wrong." }, 400);
    }
    const bytes = row.log_name && (await env.REPORTS.get(`draft-log:${hash}`, { type: "arrayBuffer" }));
    if (row.log_name && !bytes) {
      await release();
      return json({ error: "The logs of this report are gone. Send it again from OverPass." }, 410);
    }
    const name = facts(row.block).app || "Unknown game";
    const submitted = /^kind: profile$/m.test(row.block);
    const response = await deliver(env, url, app, repo, {
      title: row.log_name ? `${name}: ${what.split("\n")[0].slice(0, 80)}` : `${submitted ? "Profile" : "Rating"}: ${name} + ${TIERS[tier]}`,
      what, steps: "", block: await withRating(row.block, tier), profile: row.profile ?? "", install: row.install,
      zip: bytes ? { name: row.log_name, bytes } : null,
      shot: row.shot ? await env.REPORTS.get(`draft-shot:${hash}`, { type: "arrayBuffer" }) : null,
    });
    if (!response.ok) {
      await release();
      return response;
    }
    await env.GAMES.prepare("DELETE FROM drafts WHERE ticket_hash = ?").bind(hash).run();
    await env.REPORTS.delete(`draft-log:${hash}`);
    await env.REPORTS.delete(`draft-shot:${hash}`);
    return response;
  } catch (error) {
    await release();
    throw error;
  }
}

/// A report that passed its checks: an issue, a rating, a suggested profile, or the mix its block asks for.
async function deliver(env, url, app, repo, { title, what, steps, block, profile, install, zip, shot }) {
  const feature = /^kind: feature$/m.test(block);
  const submitted = /^kind: profile$/m.test(block);
  const rated = /^kind: rating$/m.test(block);
  if (rated) return json({ url: await addRating(env, app, block, what, null, install) });

  const id = crypto.randomUUID();
  const name = safeName(zip?.name || "OverPass Logs.zip");
  if (zip) await env.REPORTS.put(`log:${id}`, zip.bytes, { expirationTtl: KEEP_SECONDS, metadata: { name } });
  if (shot) await env.REPORTS.put(`shot:${id}`, shot, { expirationTtl: KEEP_SECONDS });

  // encodeURIComponent keeps parentheses, which would end the Markdown link and a check's match early.
  const logURL = `${url.origin}/${app}/logs/${id}/${encodeURIComponent(name).replace(/[()]/g, (c) => "%" + c.charCodeAt(0).toString(16))}`;
  const shotURL = `${url.origin}/${app}/shots/${id}.jpg`;
  // A suggested profile is for a moderator until it's approved; only a run that went badly and came with logs is an issue.
  if (submitted && !(zip && /^rating: (bronze|borked)$/m.test(block))) {
    const suggestion = await addSuggestion(env, block, profile, what, install, null, zip ? logURL : null, shot ? shotURL : null);
    return json({ url: await addRating(env, app, block, what, null, install, suggestion) });
  }
  const body = [
    // The app asks both in one field; a separate answer gets its own section.
    feature ? "### What would you like?" : "### What happened", "", what, "",
    ...(steps ? ["### How to make it happen again", "", steps, ""] : []),
    ...(submitted ? ["### Profile", "", ...fenced(profile), ""] : []),
    ...(feature ? [] : ["### Log", "", zip ? `[${name}](${logURL})` : "_No log: sent without one._", ""]),
    ...(shot ? ["### Screenshot", "", `![Screenshot](${shotURL})`, ""] : []),
    "### Details", "", "```text", block, "```", "",
    "<sub>Sent from the app through Arctic Imaginarium's report relay.</sub>",
  ].join("\n");
  const response = await github(env, `/repos/${repo}/issues`, await issueToken(env, repo), {
    method: "POST",
    body: JSON.stringify({ title, body, labels: feature ? ["feature"] : submitted ? ["profile", "report"] : ["report"] }),
  });
  if (!response.ok) {
    await env.REPORTS.delete(`log:${id}`);
    await env.REPORTS.delete(`shot:${id}`);
    return json({ error: `GitHub refused the issue (${response.status}).` }, 502);
  }
  const issue = await response.json();
  // The issue is filed: a problem with the rating or the profile mustn't fail the report.
  const suggestion = submitted ? await addSuggestion(env, block, profile, what, install, issue.number).catch(() => null) : null;
  await linkIssue(env, block, issue).catch(() => {});
  if (!/^rating: /m.test(block)) return json({ url: issue.html_url, issue: issue.number });
  // The game's page lists the issue, so that's where the person goes.
  return json({ url: await addRating(env, app, block, what, issue.html_url, install, suggestion).catch(() => issue.html_url), issue: issue.number });
}

/// The key lines of a details block.
function facts(block) {
  return Object.fromEntries(block.split("\n").map((line) => line.match(/^([\w-]+): (.*)$/)?.slice(1)).filter(Boolean));
}

/// Puts a new issue on its game's page straight away; link-issues.mjs keeps it up to date from then on. A report about the
/// app itself has no game.
async function linkIssue(env, block, issue) {
  const fact = facts(block);
  if (!fact.app || fact.app === "OverPass") return;
  const game = await gameFor(env.GAMES, fact);
  await env.GAMES.prepare("INSERT OR REPLACE INTO game_issues (number, game_id, title, url, state) VALUES (?, ?, ?, ?, 'open')")
    .bind(issue.number, game, String(issue.title).slice(0, 200), issue.html_url).run();
}

/// A page's address from a game's name, the same as .github/scripts/games-index.js.
function slug(name) {
  return name.replace(/[™®©'’]/g, "").normalize("NFKD").replace(/[\u0300-\u036f]/g, "").toLowerCase()
    .replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
}

/// The game a rating is for: by its store ID, its profile, then its name. One never seen before gets a page.
async function gameFor(db, fact) {
  const store = (fact.store || "").match(/^(.+) (\S+)$/);
  const known = store && store[1] !== "Store" ? [{ Steam: "steam", GOG: "gog", "Epic Games": "epic" }[store[1]] ?? store[1].toLowerCase(), store[2]] : null;
  const profile = (fact.profile || "none").replace(/ \((changed|own)\)$/, "");
  const name = String(fact.app || "").slice(0, 120) || "Unknown game";
  const candidates = [...(known ? [known] : []), ...(profile !== "none" ? [["profile", profile]] : [])];
  let id = null;
  for (const [key, value] of candidates) {
    id ??= (await db.prepare("SELECT game_id FROM game_keys WHERE store = ? AND store_id = ?").bind(key, value).first("game_id"));
  }
  const named = slug(name) || (known ? slug(known.join("-")) : "") || "unknown-game";
  id ??= await db.prepare("SELECT id FROM games WHERE id = ?").bind(named).first("id");
  if (!id) {
    id = named;
    await db.prepare("INSERT OR IGNORE INTO games (id, name, source, steam, gog, created_at) VALUES (?, ?, 'rated', ?, ?, ?)")
      .bind(id, name, known?.[0] === "steam" ? known[1] : null, known?.[0] === "gog" ? known[1] : null, Date.now()).run();
  }
  if (known) await db.prepare("INSERT OR IGNORE INTO game_keys (store, store_id, game_id) VALUES (?, ?, ?)").bind(...known, id).run();
  return id;
}

/// Stores a rating and returns the address of its game's page. The chip is all it keeps of the Mac's facts. A new rating
/// from the same install on the same OverPass, Wine and Runtime replaces the last one, and stays hidden if that was.
async function addRating(env, app, block, comment, issueURL, install, suggestion = null) {
  const fact = facts(block);
  const tier = ["platinum", "gold", "silver", "bronze", "borked"].find((name) => name === fact.rating);
  if (!tier) throw new Error("the rating isn't one of the tiers");
  const game = await gameFor(env.GAMES, fact);
  let hidden = 0;
  if (install) {
    const same = "install = ? AND game_id = ? AND overpass IS ? AND wine IS ? AND runtime IS ?";
    const setup = [install, game, fact.overpass || null, fact.wine || null, fact.runtime || null];
    hidden = (await env.GAMES.prepare(`SELECT MAX(hidden) AS hidden FROM ratings WHERE ${same}`).bind(...setup).first("hidden")) ?? 0;
    await env.GAMES.prepare(`DELETE FROM ratings WHERE ${same}`).bind(...setup).run();
  }
  await env.GAMES.prepare(
    `INSERT INTO ratings (id, game_id, tier, comment, chip, macos, overpass, wine, runtime, graphics, backend, fps, profile, issue_url, hidden, install, created_at, suggestion)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).bind(crypto.randomUUID(), game, tier, comment || null, (fact.mac || "").split(", ")[1] || null,
    (fact.macos || "").split(" ")[0].replace(/\.0$/, "") || null, fact.overpass || null, fact.wine || null, fact.runtime || null,
    fact.graphics || null, fact.backend && fact.backend !== "unknown" ? fact.backend : null, parseFloat(fact.frames) || null,
    fact.profile || null, issueURL, hidden, install, Date.now(), suggestion).run();
  return `${JSON.parse(env.SITES)[app]}/games/${game}`;
}

/// Keeps a suggested profile for a moderator and returns its ID. A newer one from the same install replaces one still waiting.
async function addSuggestion(env, block, text, comment, install, issue = null, log = null, shot = null) {
  const fact = facts(block);
  const game = await gameFor(env.GAMES, fact);
  const file = await env.GAMES.prepare("SELECT profile_file FROM games WHERE id = ?").bind(game).first("profile_file");
  const profile = file?.match(/^profiles\/([a-z0-9-]+)\.ini$/)?.[1] ?? game;
  if (install) await env.GAMES.prepare("DELETE FROM suggestions WHERE install = ? AND game_id = ? AND status = 'pending'").bind(install, game).run();
  const id = crypto.randomUUID();
  await env.GAMES.prepare(
    "INSERT INTO suggestions (id, game_id, profile_id, body, comment, overpass, wine, runtime, install, created_at, issue, log, shot) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
  ).bind(id, game, profile, text, comment || null, fact.overpass || null, fact.wine || null, fact.runtime || null, install, Date.now(), issue, log, shot).run();
  return id;
}

function github(env, path, token, init = {}) {
  return fetch(`${env.GITHUB_API || "https://api.github.com"}${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/vnd.github+json",
      "User-Agent": "overpass-report-relay",
      "X-GitHub-Api-Version": "2022-11-28",
    },
  });
}

// Issues are filed as the arctim-janitor GitHub App: a JWT signed with its key buys an hour-long token for its
// installation on the app's repository, kept in KV for 50 minutes. GITHUB_TOKEN (a plain token) is used instead
// when set.
async function issueToken(env, repo) {
  if (env.GITHUB_TOKEN) return env.GITHUB_TOKEN;
  const cacheKey = `token:${repo}`;
  const cached = await env.REPORTS.get(cacheKey);
  if (cached) return cached;
  const jwt = await appJWT(env.APP_ID, env.APP_PRIVATE_KEY);
  const installation = await github(env, `/repos/${repo}/installation`, jwt);
  if (!installation.ok) throw new Error(`the GitHub App isn't installed on ${repo} (${installation.status})`);
  const { id } = await installation.json();
  const created = await github(env, `/app/installations/${id}/access_tokens`, jwt, { method: "POST" });
  if (!created.ok) throw new Error(`GitHub gave no installation token (${created.status})`);
  const { token, permissions } = await created.json();
  console.log(`GitHub token for ${repo} has ${JSON.stringify(permissions)}`);
  await env.REPORTS.put(cacheKey, token, { expirationTtl: 3000 });
  return token;
}

/// RS256 JWT for the app, from its private key in PKCS#8 PEM form.
async function appJWT(appId, pem) {
  const base64url = (bytes) => btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
  const text = (value) => base64url(new TextEncoder().encode(JSON.stringify(value)));
  const now = Math.floor(Date.now() / 1000);
  const unsigned = `${text({ alg: "RS256", typ: "JWT" })}.${text({ iat: now - 60, exp: now + 540, iss: String(appId) })}`;
  const der = Uint8Array.from(atob(pem.replace(/-----[^-]+-----|\s/g, "")), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(unsigned));
  return `${unsigned}.${base64url(signature)}`;
}

async function download(id, env) {
  const { value, metadata } = await env.REPORTS.getWithMetadata(`log:${id}`, { type: "arrayBuffer" });
  if (!value) return new Response("This log has expired or doesn't exist.\n", { status: 404 });
  return new Response(value, {
    headers: {
      "Content-Type": "application/zip",
      "Content-Disposition": `attachment; filename*=UTF-8''${encodeURIComponent(safeName(metadata?.name || "OverPass Logs.zip"))}`,
    },
  });
}

async function screenshot(id, env) {
  const value = await env.REPORTS.get(`shot:${id}`, { type: "arrayBuffer" });
  if (!value) return new Response("This screenshot has expired or doesn't exist.\n", { status: 404 });
  return new Response(value, { headers: { "Content-Type": "image/jpeg", "Cache-Control": "public, max-age=86400" } });
}

/// Text as a code block, with a fence longer than any it holds.
function fenced(text) {
  const longest = Math.max(2, ...(text.match(/`+/g) || []).map((run) => run.length));
  const fence = "`".repeat(longest + 1);
  return [`${fence}ini`, text, fence];
}

/// A form field that holds a non-empty file, or null.
function file(value) {
  return value && typeof value !== "string" && value.size > 0 ? value : null;
}

// The same check as the report repository's workflow: "overpass-report: 1", key lines, then
// "checksum: <first 16 hex of SHA-256 over the lines before it>".
async function validBlock(block) {
  const lines = block.split("\n").map((l) => l.trim());
  const start = lines.indexOf("overpass-report: 1");
  const end = start < 0 ? -1 : lines.findIndex((l, i) => i > start && l.startsWith("checksum: "));
  if (end < 0) return false;
  const sum = (await sha256(lines.slice(start, end).join("\n"))).slice(0, 16);
  return lines[end] === `checksum: ${sum}`;
}

/// The block with the medal chosen on the page, and a checksum that matches it.
async function withRating(block, tier) {
  const lines = block.split("\n").filter((line) => !line.startsWith("checksum: "));
  const text = lines.map((line) => (line.startsWith("rating: ") ? `rating: ${tier}` : line)).join("\n");
  return `${text}\nchecksum: ${(await sha256(text)).slice(0, 16)}`;
}

async function sha256(text) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function safeName(name) {
  const clean = name.replace(/[^\w .()+–-]/g, "").trim().replace(/\.zip$/i, "");
  return clean.slice(0, 116) + ".zip";
}

function json(value, status = 200) {
  return new Response(JSON.stringify(value), { status, headers: { "Content-Type": "application/json" } });
}
