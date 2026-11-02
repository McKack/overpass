# OverPass report relay

A Cloudflare Worker that files problem reports from OverPass's Report Issue… and requests from its Request Feature… as
GitHub issues in `McKack/overpass`, so reporting needs no GitHub account. Ratings go to the games database (D1 `overpass-games`, see `../site/schema.sql`) instead, and the answer is the game's page on the site. A suggested profile waits for a moderator on /moderation; it also gets an issue only for a Bronze or Borked run with logs. The log zip is kept in Workers KV for 180 days
and linked from the issue or the suggestion; the issue has the same sections as the repository's report form, so its check workflow
treats it like any other report.

- Accepts only reports whose details block carries a valid checksum (the same check as the workflow), at most
  `HOURLY_LIMIT` per address an hour, zips up to 20 MB.
- `POST /<app>/draft` keeps How Did It Run?'s upload for a day and returns the site's `/report/<ticket>` page, where the
  person finishes it; `POST /<app>/draft/<ticket>` sends it, once. The ticket is the only key; D1 `drafts` has its hash.
- `POST /<app>/report` (multipart: title, what, steps, block, zip, screenshot, profile) returns `{"url": "<issue>"}`;
  `GET /logs/<id>/<name>.zip` returns a zip.

Deploy: `npx wrangler deploy`. Issues are filed as the GitHub App arctim-janitor; its ID and key are secrets
(see wrangler.toml), and it has to be installed on each app's repository.
Test locally: `npx wrangler dev --var GITHUB_API:http://127.0.0.1:<port>` against a fake GitHub.
