// Puts approved profile suggestions into profiles/ and signs the set the app downloads. Run by sync-games.yml, with
// the code on main: the site only says what a moderator approved, so every suggestion is checked again here, and the
// signing key (repository secret PROFILES_SIGNING_KEY) never leaves GitHub.
//
//   node .github/scripts/publish-profiles.mjs
//
// Needs SITE, SYNC_TOKEN and PROFILES_SIGNING_KEY. Writes changed=true to GITHUB_OUTPUT when profiles/ moved.
// The set's serial is the time of the last commit that touched profiles/, which build-app.sh stamps on the bundled
// copy too, so the app can tell which of the two is newer.

import { execFileSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { profileProblems, validProfileID } from '../../services/site/src/profile-check.js';

const git = (...args) => execFileSync('git', args, { encoding: 'utf8' }).trim();

/// Every profile and preset, by its path under profiles/.
export function profileFiles(root) {
  const files = {};
  for (const folder of ['', 'Presets']) {
    for (const name of fs.readdirSync(path.join(root, folder)).sort()) {
      if (name.endsWith('.ini')) files[path.posix.join(folder, name)] = fs.readFileSync(path.join(root, folder, name), 'utf8');
    }
  }
  return files;
}

/// The signed form of a set: the text that was signed, kept as text, and its signature.
export function signedSet(serial, commit, files, privateKey) {
  const payload = JSON.stringify({ format: 1, serial, commit, files });
  return JSON.stringify({ payload, signature: crypto.sign(null, Buffer.from(payload), privateKey).toString('base64') });
}

/// Writes the suggestions that pass and sorts them into those that went in and those that didn't.
export function apply(suggestions, root) {
  const published = [];
  const refused = [];
  for (const entry of suggestions) {
    const file = path.join(root, `${entry.profile_id}.ini`);
    const current = validProfileID(entry.profile_id) && fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '';
    const problems = validProfileID(entry.profile_id) ? profileProblems(entry.body, current) : ['its file name is not valid'];
    if (problems.length) {
      console.log(`Refused ${entry.id} for ${entry.profile_id}: ${problems.join('; ')}`);
      refused.push(entry.id);
      continue;
    }
    fs.writeFileSync(file, `${entry.body.trim()}\n`);
    published.push(entry.id);
  }
  return { published, refused };
}

async function site(address, init = {}) {
  const response = await fetch(`${process.env.SITE}${address}`, {
    ...init, headers: { Authorization: `Bearer ${process.env.SYNC_TOKEN}`, 'Content-Type': 'application/json' },
  });
  if (!response.ok) throw new Error(`${address} answered ${response.status}: ${await response.text()}`);
  return response;
}

async function main() {
  const { suggestions } = await (await site('/api/suggestions')).json();
  const { published, refused } = apply(suggestions, 'profiles');
  if (git('status', '--porcelain', 'profiles')) {
    git('config', 'user.name', 'arctim-janitor[bot]');
    git('config', 'user.email', 'arctim-janitor[bot]@users.noreply.github.com');
    git('add', 'profiles');
    git('commit', '-m', `Profiles: ${published.length === 1 ? 'a suggestion' : `${published.length} suggestions`} from the site`);
    git('pull', '--rebase', 'origin', 'main');
    git('push', 'origin', 'HEAD:main');
    if (process.env.GITHUB_OUTPUT) fs.appendFileSync(process.env.GITHUB_OUTPUT, 'changed=true\n');
  }
  if (published.length || refused.length) await site('/api/suggestions', { method: 'POST', body: JSON.stringify({ published, refused }) });

  if (!process.env.PROFILES_SIGNING_KEY) return console.log('No signing key yet: run src/scripts/new-profiles-key.mjs.');
  const serial = Number(git('log', '-1', '--format=%ct', '--', 'profiles'));
  const live = await fetch(`${process.env.SITE}/api/profiles`);
  if (Number(live.headers.get('X-Profiles-Serial')) >= serial) return;
  const body = signedSet(serial, git('rev-parse', 'HEAD'), profileFiles('profiles'), crypto.createPrivateKey(process.env.PROFILES_SIGNING_KEY));
  await site('/api/profiles', { method: 'POST', body: JSON.stringify({ serial, body }) });
  console.log(`Published set ${serial}`);
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) await main();
