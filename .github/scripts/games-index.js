// The list of games the site's pages start from, read from profiles/ and the games named in Presets/: a profile is
// one game, and a preset names each game it's for in a comment above the game's steam-app or program line. Run by
// sync-games.yml on every change to profiles/; the site's /api/sync stores the result (services/site/src/index.js).
//
//   node .github/scripts/games-index.js [profiles folder]   prints { "games": [...] } as JSON

const fs = require('fs');
const path = require('path');

/// Profiles of helper programs, which nobody would look up or rate.
const NOT_A_GAME = ['chromium-programs'];

/// A page's address from a game's name. The report relay has the same function: a rated game must land on its page.
function slug(name) {
  return name.replace(/[™®©'’]/g, '').normalize('NFKD').replace(/[̀-ͯ]/g, '').toLowerCase()
    .replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
}

/// The sections of an INI file, in order, as { name, lines: [{ key, value, comment }] }; `comment` is the comment
/// right above the line. Lines above the first section belong to a section with no name.
function sections(text) {
  const found = [{ name: '', lines: [] }];
  let comment = '';
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    const title = line.match(/^\[(.+)\]$/);
    const setting = line.match(/^([\w-]+)\s*=\s*(.*)$/);
    if (/^[#;]/.test(line)) comment = line.replace(/^[#;]\s*/, '');
    else if (title) { found.push({ name: title[1], lines: [] }); comment = ''; }
    else if (setting) { found.at(-1).lines.push({ key: setting[1].toLowerCase(), value: setting[2], comment }); comment = ''; }
    else comment = '';
  }
  return found;
}

const first = (section, key) => section?.lines.find((line) => line.key === key)?.value;
const all = (section, key) => section?.lines.filter((line) => line.key === key).map((line) => line.value) ?? [];

function profile(id, text) {
  const parts = sections(text);
  const app = parts.find((part) => part.name === 'app');
  const store = parts.find((part) => part.name === 'store');
  const rules = parts.filter((part) => part.name && !['app', 'install', 'launch', 'store'].includes(part.name));
  const name = first(app, 'name') || rules[0]?.name.split(':')[0].trim() || id;
  const steam = first(app, 'steam-app') || first(store, 'steam') || rules.map((rule) => first(rule, 'steam-app')).find(Boolean) || null;
  const gog = first(app, 'gog-game') || first(store, 'gog') || null;
  const epic = first(store, 'epic') || null;
  return {
    id, name, source: 'profile', category: first(app, 'category') || 'Games',
    verified: [undefined, 'untested'].includes(first(app, 'rating')) ? null : first(app, 'rating'),
    notes: first(app, 'notes') || first(app, 'rating-notes') || null,
    profile_file: `profiles/${id}.ini`, profile_text: text.trim(), presets: all(app, 'preset'), steam, gog,
    links: all(store, 'link'), brand: first(app, 'brand-color') || null, color: first(app, 'brand-color') || null,
    keys: [['profile', id], ...(steam ? [['steam', steam]] : []), ...(gog ? [['gog', gog]] : []), ...(epic ? [['epic', epic]] : [])],
  };
}

/// The games a preset names, each as a page of its own or as an addition to a game already known.
function presetGames(file, text) {
  const preset = path.basename(file, '.ini');
  const found = [];
  for (const section of sections(text)) {
    for (const line of section.lines) {
      if (!['steam-app', 'program'].includes(line.key) || !line.comment) continue;
      const name = line.comment.replace(/\s*\(reported on .*$/, '').trim();
      if (name && name.length <= 80 && !name.endsWith('.') && slug(name)) found.push({ name, preset, steam: line.key === 'steam-app' ? line.value : null });
    }
  }
  return found;
}

function buildIndex(folder) {
  const games = new Map();
  const bySteam = new Map();
  for (const file of fs.readdirSync(folder).filter((name) => name.endsWith('.ini')).sort()) {
    if (NOT_A_GAME.includes(path.basename(file, '.ini'))) continue;
    const game = profile(path.basename(file, '.ini'), fs.readFileSync(path.join(folder, file), 'utf8'));
    // A launcher's cover is its tile on the app's Home: the logo on the brand's colour. Without a logo it's art like any game's.
    if (!fs.existsSync(path.join(folder, '..', 'site', 'logos', `${game.id}.svg`))) game.brand = null;
    games.set(game.id, game);
    if (game.steam) bySteam.set(game.steam, game);
  }
  const presets = path.join(folder, 'Presets');
  for (const file of fs.readdirSync(presets).filter((name) => name.endsWith('.ini')).sort()) {
    for (const { name, preset, steam } of presetGames(file, fs.readFileSync(path.join(presets, file), 'utf8'))) {
      const id = slug(name);
      let game = (steam && bySteam.get(steam)) || games.get(id);
      if (!game) {
        game = {
          id, name, source: 'preset', category: 'Games', verified: null, notes: null, profile_file: null, profile_text: null,
          presets: [], steam: null, gog: null, links: [], brand: null, color: null, keys: [['profile', id]],
        };
        games.set(id, game);
      }
      if (steam && !game.steam) {
        game.steam = steam;
        game.keys.push(['steam', steam]);
        bySteam.set(steam, game);
      }
      if (!game.presets.includes(preset)) game.presets.push(preset);
    }
  }
  return { games: [...games.values()] };
}

module.exports = { slug, sections, profile, presetGames, buildIndex };

if (require.main === module) {
  const folder = process.argv[2] || path.join(__dirname, '..', '..', 'profiles');
  process.stdout.write(JSON.stringify(buildIndex(folder)));
}
