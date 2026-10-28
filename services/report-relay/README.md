# OverPass report relay

A Cloudflare Worker that files problem reports from OverPass's Report Issue… as GitHub issues in
`McKack/overpass`, so reporting needs no GitHub account. The log zip is kept in Workers KV for 180 days
and linked from the issue; the issue has the same sections as the repository's report form, so its check workflow
treats it like any other report.

- Accepts only reports whose details block carries a valid checksum (the same check as the workflow), at most
  `HOURLY_LIMIT` per address an hour, zips up to 20 MB.
- `POST /<app>/report` (multipart: title, what, steps, block, zip, screenshot) returns `{"url": "<issue>"}`;
  `GET /logs/<id>/<name>.zip` returns a zip.

Deploy: `npx wrangler deploy`. The issue is filed with a bot account's token, kept as a secret:
`npx wrangler secret put GITHUB_TOKEN` (fine-grained, Issues: read and write, on the app repo only).
Test locally: `npx wrangler dev --var GITHUB_API:http://127.0.0.1:<port>` against a fake GitHub.
