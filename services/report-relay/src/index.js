// Arctim report relay (reports.arctim.no): files a problem report or feature request sent from an app as a GitHub
// issue, so reporting needs no GitHub account. Each app has a path of its own and a repository in APPS
// ({"overpass": "McKack/overpass"}); the log zip and screenshot are kept here (KV) and linked from the issue.
//
//   POST /<app>/report              multipart: title, what, steps, block (the app's details block), zip (the log
//                                   zip; not when the block says "log: none"), screenshot (JPEG, optional),
//                                   profile (a submitted profile's text)
//                                   -> { "url": "<issue url>" }
//   GET  /<app>/logs/<id>/<name>.zip   the zip a report linked
//   GET  /<app>/shots/<id>.jpg         the screenshot it showed
//
// Only reports whose details block carries a valid checksum are accepted, at most HOURLY_LIMIT per address an
// hour. The issue has the same sections as the app repository's forms, so its check workflow treats it the same.
// A block with "kind: feature" is a feature request: it takes the feature form's heading, no log and no `report`.
// One with "kind: profile" is a rating and a profile: the text in `profile`, an optional comment, and no log either.

const MAX_ZIP = 20 * 1024 * 1024;
const MAX_SHOT = 4 * 1024 * 1024;
const KEEP_SECONDS = 180 * 24 * 3600;

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
      const log = path.match(/^\/logs\/([0-9a-f-]{36})\/[^/]+\.zip$/);
      if (request.method === "GET" && log) return await download(log[1], env);
      const shot = path.match(/^\/shots\/([0-9a-f-]{36})\.jpg$/);
      if (request.method === "GET" && shot) return await screenshot(shot[1], env);
      return new Response("Not found\n", { status: 404 });
    } catch (error) {
      return json({ error: "The relay failed: " + error.message }, 500);
    }
  },
};

async function report(request, env, url, app, repo) {
  if (!env.GITHUB_TOKEN && !(env.APP_ID && env.APP_PRIVATE_KEY)) return json({ error: "The relay isn't set up yet." }, 503);

  const address = request.headers.get("CF-Connecting-IP") || "unknown";
  const hour = Math.floor(Date.now() / 3600000);
  const countKey = `count:${address}:${hour}`;
  const count = parseInt((await env.REPORTS.get(countKey)) || "0", 10);
  if (count >= parseInt(env.HOURLY_LIMIT || "5", 10))
    return json({ error: "Too many reports from this network in the last hour. Try again later." }, 429);

  const form = await request.formData();
  const title = String(form.get("title") || "").trim().slice(0, 200);
  const what = String(form.get("what") || "").trim().slice(0, 20000);
  const steps = String(form.get("steps") || "").trim().slice(0, 20000);
  const block = String(form.get("block") || "").replace(/\r\n/g, "\n").trim();
  const zip = file(form.get("zip"));
  const shot = file(form.get("screenshot"));
  const feature = /^kind: feature$/m.test(block);
  const submitted = /^kind: profile$/m.test(block);
  // A submitted profile's comment is optional.
  if (!title || (!what && !submitted)) return json({ error: "The report needs a title and what happened." }, 400);
  if (!(await validBlock(block))) return json({ error: "The details block is missing or was changed." }, 400);
  const profile = String(form.get("profile") || "").replace(/\r\n/g, "\n").trim().slice(0, 20000);
  const withoutLog = /^log: none$/m.test(block);
  if (!zip && !withoutLog) return json({ error: "The log zip is missing." }, 400);
  if (submitted && !profile) return json({ error: "A submitted profile needs its text." }, 400);
  if (zip && zip.size > MAX_ZIP) return json({ error: "The log zip is larger than 20 MB." }, 413);
  if (shot && (shot.size > MAX_SHOT || shot.type !== "image/jpeg"))
    return json({ error: "The screenshot must be a JPEG of at most 4 MB." }, 413);

  const id = crypto.randomUUID();
  const name = safeName(zip?.name || "OverPass Logs.zip");
  if (zip) await env.REPORTS.put(`log:${id}`, await zip.arrayBuffer(), { expirationTtl: KEEP_SECONDS, metadata: { name } });
  if (shot) await env.REPORTS.put(`shot:${id}`, await shot.arrayBuffer(), { expirationTtl: KEEP_SECONDS });
  await env.REPORTS.put(countKey, String(count + 1), { expirationTtl: 7200 });

  // encodeURIComponent keeps parentheses, which would end the Markdown link and a check's match early.
  const logURL = `${url.origin}/${app}/logs/${id}/${encodeURIComponent(name).replace(/[()]/g, (c) => "%" + c.charCodeAt(0).toString(16))}`;
  const body = [
    // The app asks both in one field; a separate answer gets its own section.
    ...(submitted ? (what ? ["### Comment", "", what, ""] : []) : [feature ? "### What would you like?" : "### What happened", "", what, ""]),
    ...(steps ? ["### How to make it happen again", "", steps, ""] : []),
    ...(submitted ? ["### Profile", "", ...fenced(profile), ""] : []),
    ...(feature || submitted ? [] : ["### Log", "", zip ? `[${name}](${logURL})` : "_No log: sent without one._", ""]),
    ...(shot ? ["### Screenshot", "", `![Screenshot](${url.origin}/${app}/shots/${id}.jpg)`, ""] : []),
    "### Details", "", "```text", block, "```", "",
    "<sub>Sent from the app through Arctic Imaginarium's report relay.</sub>",
  ].join("\n");
  const response = await github(env, `/repos/${repo}/issues`, await issueToken(env, repo), {
    method: "POST",
    body: JSON.stringify({ title, body, labels: [feature ? "feature" : submitted ? "profile" : "report"] }),
  });
  if (!response.ok) {
    await env.REPORTS.delete(`log:${id}`);
    await env.REPORTS.delete(`shot:${id}`);
    return json({ error: `GitHub refused the issue (${response.status}).` }, 502);
  }
  const issue = await response.json();
  return json({ url: issue.html_url });
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
  const { token } = await created.json();
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
  const text = lines.slice(start, end).join("\n");
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  const sum = [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("").slice(0, 16);
  return lines[end] === `checksum: ${sum}`;
}

function safeName(name) {
  const clean = name.replace(/[^\w .()+–-]/g, "").trim().replace(/\.zip$/i, "");
  return clean.slice(0, 116) + ".zip";
}

function json(value, status = 200) {
  return new Response(JSON.stringify(value), { status, headers: { "Content-Type": "application/json" } });
}
