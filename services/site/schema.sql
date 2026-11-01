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
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS ratings_install ON ratings (install, game_id);
CREATE INDEX IF NOT EXISTS ratings_game ON ratings (game_id, created_at);
CREATE INDEX IF NOT EXISTS ratings_recent ON ratings (created_at);

-- An account: the provider's ID for the person, the username they chose and maybe a picture. No e-mail, no name from
-- the provider.
CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,
  provider TEXT NOT NULL,
  provider_id TEXT NOT NULL,
  name TEXT COLLATE NOCASE,
  picture TEXT,                      -- its key in the PICTURES store, when they added one
  created_at INTEGER NOT NULL,
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
  user_id TEXT NOT NULL,
  body TEXT NOT NULL,
  hidden INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS comments_game ON comments (game_id, created_at);
CREATE INDEX IF NOT EXISTS comments_user ON comments (user_id, created_at);

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

-- The latest signed set of profiles, as the app downloads it. Signed on GitHub with a key this site doesn't hold.
CREATE TABLE IF NOT EXISTS profile_set (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  serial INTEGER NOT NULL,
  body TEXT NOT NULL
);
