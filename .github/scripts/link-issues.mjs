// Tells the site which game each GitHub issue is about, so a game's page lists them with their state. Every issue is sent
// each run, so a new one, a closed one and a removed one all reach the page by themselves, however it was filed. The
// report block the app adds names the game; an issue written by hand counts when its title starts with "<game>: ".
import { pathToFileURL } from 'node:url';

/// What an issue says about its game, for the site's /api/issues.
export function parseIssue(issue) {
  const block = issue.body?.match(/```text\n(overpass-report:[\s\S]*?)```/)?.[1] ?? '';
  const fact = Object.fromEntries(block.split('\n').map((line) => line.match(/^([\w-]+): (.*)$/)?.slice(1)).filter(Boolean));
  return {
    number: issue.number, title: issue.title.slice(0, 200), url: issue.html_url,
    state: issue.state === 'open' ? 'open' : issue.state_reason === 'completed' ? 'fixed' : 'closed',
    app: fact.app, store: fact.store, profile: fact.profile,
    named: issue.title.includes(': ') ? issue.title.split(': ')[0] : null,
  };
}

export async function allIssues(repo, token, get = fetch) {
  const issues = [];
  for (let page = 1; ; page += 1) {
    const answer = await get(`https://api.github.com/repos/${repo}/issues?state=all&per_page=100&page=${page}`, {
      headers: { Authorization: `Bearer ${token}`, Accept: 'application/vnd.github+json', 'User-Agent': 'overpass-sync' },
    });
    if (!answer.ok) throw new Error(`GitHub: ${answer.status}`);
    const batch = await answer.json();
    issues.push(...batch.filter((issue) => !issue.pull_request));
    if (batch.length < 100) return issues;
  }
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const issues = (await allIssues(process.env.GITHUB_REPOSITORY, process.env.GH_TOKEN)).map(parseIssue);
  const answer = await fetch(`${process.env.SITE}/api/issues`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.SYNC_TOKEN}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ issues }),
  });
  if (answer.status === 503) {
    console.log(`The site takes no changes until ${(await answer.json().catch(() => ({}))).resets_at ?? 'its daily limit resets'}: issues wait for a later run.`);
    process.exit(0);
  }
  if (!answer.ok) throw new Error(`POST /api/issues: ${answer.status}`);
  console.log(`${issues.length} issues: ${JSON.stringify(await answer.json())}`);
}
