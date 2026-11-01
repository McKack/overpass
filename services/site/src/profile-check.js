// What a profile suggested by someone may do. Profiles reach people's Macs without an app release, and they can set
// environment variables, arguments and installer URLs, so a suggestion can only add plain settings. Anything else
// stays a pull request. A line the current file already has is always fine: a suggestion usually starts from it.
//
// The moderation page uses this to explain a refusal; .github/scripts/publish-profiles.mjs runs it again before
// anything is signed, so the site alone can't get a line past it.

const RECIPE = ['install', 'launch'];
const APP_KEYS = new Set(['name', 'category', 'steam-app', 'gog-game', 'rating', 'tested-with', 'rating-date', 'rating-notes',
  'bottle', 'notes', 'engine', 'preset', 'graphics', 'prefer-graphics', 'controllers', 'env', 'dll', 'source']);
const RULE_KEYS = new Set(['program', 'steam-app', 'gog-game', 'beside', 'company', 'product', 'unless-argument', 'graphics', 'prefer-graphics',
  'd3d9', 'env', 'dll', 'add-arguments', 'source']);
// Names known to only change how a game runs. Never one that picks what code loads (DYLD_*, WINEDLLPATH, PATH...).
const ENV_NAMES = [/^DXMT_CONFIG$/, /^MTL_[A-Z0-9_]+$/, /^MVK_CONFIG_[A-Z0-9_]+$/, /^OVERPASS_(X87|MAX_RESOLUTION|NO_MAC_FRAME)$/,
  /^WINE_(LARGE_ADDRESS_AWARE|HEAP_ZERO_MEMORY|SIMULATE_WRITECOPY|FORCE_NX)$/, /^WINENCPU$/, /^QMLSCENE_DEVICE$/, /^SteamDeck$/];
const DLL = /^[A-Za-z0-9_.-]+\s*=\s*[nbd,]*$/;
const WILDCARD = /[*?]/;
const LENGTH = 20000;

export const validProfileID = (id) => /^[a-z0-9][a-z0-9-]{0,99}$/.test(id ?? '');

/// The lines of a profile as "section\0key = value", comments and spacing left out.
function settings(text) {
  let section = '';
  const found = [];
  for (const raw of String(text ?? '').split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || /^[#;]/.test(line)) continue;
    const title = line.match(/^\[(.+)\]$/);
    if (title) { section = title[1]; continue; }
    const setting = line.match(/^([\w-]+)\s*=\s*(.*)$/);
    found.push(setting ? { section, key: setting[1].toLowerCase(), value: setting[2], line } : { section, key: null, value: '', line });
  }
  return found;
}

const said = (entry) => `${entry.section}\0${entry.key}=${entry.value}`;

function problem(entry) {
  const { section, key, value, line } = entry;
  if (!section) return `"${line}" is outside any section`;
  if (key === null) return `"${line}" isn't a setting`;
  if (RECIPE.includes(section)) return `[${section}] needs a pull request`;
  const allowed = section === 'app' ? APP_KEYS : RULE_KEYS;
  if (!allowed.has(key)) return `${key} needs a pull request`;
  if (['program', 'beside', 'company', 'product'].includes(key) && (!value || WILDCARD.test(value))) return `${key} = ${value} would reach other programs`;
  if (key === 'env') {
    const name = value.split('=')[0].trim();
    if (!ENV_NAMES.some((known) => known.test(name))) return `the variable ${name} needs a pull request`;
  }
  if (key === 'dll' && !DLL.test(value)) return `dll = ${value} isn't a DLL override`;
  return null;
}

/// Why a suggestion can't go in as it stands, in plain words; an empty list means it can.
export function profileProblems(text, current) {
  if (String(text ?? '').length > LENGTH) return ['it is too long'];
  const lines = settings(text);
  if (!lines.some((entry) => entry.key)) return ['it has no settings'];
  const known = new Set(settings(current).map(said));
  return [...new Set(lines.filter((entry) => !known.has(said(entry))).map(problem).filter(Boolean))];
}
