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
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS ratings_game ON ratings (game_id, created_at);
CREATE INDEX IF NOT EXISTS ratings_recent ON ratings (created_at);
