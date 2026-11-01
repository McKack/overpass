-- Added later, on the live database by hand before the code that reads them:
--   ALTER TABLE ratings ADD COLUMN user_id TEXT;
--   ALTER TABLE users ADD COLUMN public INTEGER NOT NULL DEFAULT 0;
--   CREATE INDEX ratings_user ON ratings (user_id);
--   ALTER TABLE users ADD COLUMN role TEXT;
--   ALTER TABLE comments ADD COLUMN parent_id TEXT;
--   ALTER TABLE users ADD COLUMN password TEXT;
--   ALTER TABLE games ADD COLUMN color TEXT;
--   ALTER TABLE game_art ADD COLUMN about TEXT;
--   ALTER TABLE game_art ADD COLUMN about_source TEXT;
--   CREATE INDEX comments_parent ON comments (parent_id);
-- An Admin is only ever made here, by hand: UPDATE users SET role = 'admin', public = 1 WHERE id = '<users.id>';
--
-- The games database (D1 "overpass-games"), shared by the site's worker, which reads it and stores the list of games
-- from profiles/, and the report relay, which adds ratings. Apply with:
--   npx wrangler d1 execute overpass-games --remote --file schema.sql
-- Approved profiles stay files in profiles/; profile_text is a copy for showing them.

CREATE TABLE IF NOT EXISTS games (
  id TEXT PRIMARY KEY,               -- the page's address: the profile's file name, or the name as a slug
  name TEXT NOT NULL,
  category TEXT,
  source TEXT NOT NULL,              -- profile, preset, or rated: known only from a rating
  verified TEXT,                     -- the profile's own `rating`, when it isn't untested
  notes TEXT,
  profile_file TEXT,
  profile_text TEXT,
  presets TEXT NOT NULL DEFAULT '[]',
  steam TEXT,
  gog TEXT,
  links TEXT NOT NULL DEFAULT '[]',  -- the profile's store pages
  brand TEXT,                        -- a launcher's colour: its cover is its logo on this, as on the app's Home
  color TEXT,                        -- the profile's colour, logo or not: a made cover is painted with it
  created_at INTEGER NOT NULL
);

-- What leads to a game: store = steam, gog, epic..., or profile for a profile's ID.
CREATE TABLE IF NOT EXISTS game_keys (
  store TEXT NOT NULL,
  store_id TEXT NOT NULL,
  game_id TEXT NOT NULL,
  PRIMARY KEY (store, store_id)
);
CREATE INDEX IF NOT EXISTS game_keys_game ON game_keys (game_id);

-- The addresses of a game's art, where the pictures stay, and the store pages found for it. find-covers.mjs fills this
-- from GitHub. A row whose game_id is <store>:<id> is a title the app asked about that has no page; checked_at 0 means it
-- waits for its first look.
CREATE TABLE IF NOT EXISTS game_art (
  game_id TEXT PRIMARY KEY,
  name TEXT,                         -- the name the app gave, for a title with no page
  file TEXT,                         -- a moderator's upload: covers/<file> in the PICTURES store
  source TEXT,                       -- steam, gog, thegamesdb, steamgriddb or moderator
  about TEXT,                        -- the store's description
  about_source TEXT,                 -- steam, gog or thegamesdb
  origin TEXT,                       -- the cover's address
  thumb TEXT,                        -- a smaller cover, where the source has one
  icon TEXT,
  hero TEXT,
  links TEXT NOT NULL DEFAULT '[]',
  wanted TEXT,                       -- an image's address from a moderator, waiting for find-covers.mjs
  locked INTEGER NOT NULL DEFAULT 0, -- a moderator's choice: nothing automatic replaces it
  checked_at INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS ratings (
  id TEXT PRIMARY KEY,
  game_id TEXT NOT NULL,
  tier TEXT NOT NULL,                -- platinum, gold, silver, bronze or borked
  comment TEXT,
  chip TEXT,
  macos TEXT,
  overpass TEXT,
  wine TEXT,
  runtime TEXT,
  graphics TEXT,
  backend TEXT,
  fps REAL,
  profile TEXT,                      -- the profile it ran with, as the app's report says it
  issue_url TEXT,                    -- the review issue of a profile sent with it
  hidden INTEGER NOT NULL DEFAULT 0,
  install TEXT,                      -- the app's random ID, never shown: a new rating replaces its last one;
                                     -- account:<users.id> for a moderator's rating from the game's page
  created_at INTEGER NOT NULL,
  user_id TEXT                       -- the account it was sent from; anonymous without one
);
CREATE INDEX IF NOT EXISTS ratings_install ON ratings (install, game_id);
CREATE INDEX IF NOT EXISTS ratings_game ON ratings (game_id, created_at);
CREATE INDEX IF NOT EXISTS ratings_recent ON ratings (created_at);

-- An account: the provider's ID for the person, the username they chose and maybe a picture. No e-mail, no name from
-- the provider; an address is only ever in email_updates.
CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,
  provider TEXT NOT NULL,
  provider_id TEXT NOT NULL,
  name TEXT COLLATE NOCASE,
  picture TEXT,                      -- its key in the PICTURES store, when they added one
  created_at INTEGER NOT NULL,
  public INTEGER NOT NULL DEFAULT 0, -- a Public Contributor: their name shows on their ratings. 0 is a Member: it doesn't
  role TEXT,                         -- admin, or mod, which Admins hand out on /moderation
  password TEXT,                     -- e-mail accounts: salt.hash. Their provider_id is the address's keyed hash
  UNIQUE (provider, provider_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS users_name ON users (name) WHERE name IS NOT NULL;

CREATE TABLE IF NOT EXISTS sessions (
  token_hash TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS sessions_user ON sessions (user_id);

-- What people say on a game's page. Deleting an account deletes its comments.
CREATE TABLE IF NOT EXISTS comments (
  id TEXT PRIMARY KEY,
  game_id TEXT NOT NULL,
  parent_id TEXT,                    -- the comment this replies to; replies go one level deep
  user_id TEXT NOT NULL,
  body TEXT NOT NULL,
  hidden INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS comments_game ON comments (game_id, created_at);
CREATE INDEX IF NOT EXISTS comments_user ON comments (user_id, created_at);
CREATE INDEX IF NOT EXISTS comments_parent ON comments (parent_id);

-- Upvotes on comments, one per account. Only the count is shown.
CREATE TABLE IF NOT EXISTS votes (
  comment_id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (comment_id, user_id)
);
CREATE INDEX IF NOT EXISTS votes_user ON votes (user_id);

-- Who reported a comment or a rating; `target` is its ID. Gone once a moderator has decided, or with either side's deletion.
CREATE TABLE IF NOT EXISTS reports (
  target TEXT NOT NULL,
  user_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (target, user_id)
);
CREATE INDEX IF NOT EXISTS reports_user ON reports (user_id, created_at);

-- Profiles people suggest from the app. A moderator's Approve only marks one; publish-profiles.mjs, which runs on GitHub,
-- checks it, commits it to profiles/ and marks it published.
CREATE TABLE IF NOT EXISTS suggestions (
  id TEXT PRIMARY KEY,
  game_id TEXT NOT NULL,
  profile_id TEXT NOT NULL,          -- the file it would become: profiles/<profile_id>.ini
  body TEXT NOT NULL,
  comment TEXT,
  overpass TEXT,
  wine TEXT,
  runtime TEXT,
  install TEXT,                      -- the app's random ID: a newer suggestion from it replaces a waiting one
  status TEXT NOT NULL DEFAULT 'pending',   -- pending, approved or published; a refused one is deleted
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS suggestions_status ON suggestions (status, created_at);
CREATE INDEX IF NOT EXISTS suggestions_install ON suggestions (install, game_id);

-- A rating on its way from the app: the relay keeps it until the person finishes it on /report/<ticket>, for a day at most.
-- Only the ticket's hash is kept. The zip and screenshot wait in the relay's store; sending the draft deletes all of it.
CREATE TABLE IF NOT EXISTS drafts (
  ticket_hash TEXT PRIMARY KEY,
  app TEXT NOT NULL,
  block TEXT NOT NULL,               -- the app's details block
  what TEXT,                         -- the comment so far
  profile TEXT,                      -- settings being shared
  install TEXT,
  log_name TEXT,                     -- the zip's name, when logs came with it
  shot INTEGER NOT NULL DEFAULT 0,
  claimed_at INTEGER,                -- being sent right now
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS drafts_expires ON drafts (expires_at);

-- The latest signed set of profiles, as the app downloads it. Signed on GitHub with a key this site doesn't hold.
CREATE TABLE IF NOT EXISTS profile_set (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  serial INTEGER NOT NULL,
  body TEXT NOT NULL
);

-- A code on its way to someone. The address isn't here, only its keyed hash, and the cookie's token only as a hash.
CREATE TABLE IF NOT EXISTS email_codes (
  token_hash TEXT PRIMARY KEY,
  purpose TEXT NOT NULL,             -- signup, signin, reset or updates
  address_hash TEXT NOT NULL,
  code_hash TEXT NOT NULL,
  password TEXT,                     -- signup: the hash of the password chosen, until the code proves the address
  next TEXT NOT NULL,
  tries INTEGER NOT NULL DEFAULT 0,
  expires_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS email_codes_expires ON email_codes (expires_at);

-- Counts for the rate limits: one row per attempt, hashed, gone after a day.
CREATE TABLE IF NOT EXISTS email_attempts (
  key TEXT NOT NULL,
  at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS email_attempts_key ON email_attempts (key, at);

-- GitHub issues about a game, kept up to date by .github/scripts/link-issues.mjs. The relay adds one as soon as it's filed.
CREATE TABLE IF NOT EXISTS game_issues (
  number INTEGER PRIMARY KEY,
  game_id TEXT NOT NULL,
  title TEXT NOT NULL,
  url TEXT NOT NULL,
  state TEXT NOT NULL                -- open, fixed or closed
);
CREATE INDEX IF NOT EXISTS game_issues_game ON game_issues (game_id);

-- E-mail updates, for those who turned them on: the one place an address is readable, since the site has to send to it.
-- Gone when they stop, by the mail's link or on /account, or delete the account.
CREATE TABLE IF NOT EXISTS email_updates (
  user_id TEXT PRIMARY KEY,
  address TEXT NOT NULL,
  token TEXT NOT NULL UNIQUE,        -- the stop link in every mail
  created_at INTEGER NOT NULL
);

-- Who to tell when an issue is fixed: reports sent from an account, not anonymous ones.
CREATE TABLE IF NOT EXISTS issue_reporters (
  number INTEGER NOT NULL,
  user_id TEXT NOT NULL,
  PRIMARY KEY (number, user_id)
);
CREATE INDEX IF NOT EXISTS issue_reporters_user ON issue_reporters (user_id);
