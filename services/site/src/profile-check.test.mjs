// node --test services/site/src/
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { profileProblems, validProfileID } from './profile-check.js';

const current = `# Rated by hand
[app]
name = Some Game
bottle-group = games

[install]
download = https://example.com/setup.exe

[Some Game]
steam-app = 10
replace-path = a=b
env = DYLD_FALLBACK_LIBRARY_PATH=/already/here
`;

test('plain settings pass', () => {
  assert.deepEqual(profileProblems(`[app]\nname = New Game\nrating = gold\n\n[My settings]\nprogram = game.exe\ngraphics = dxmt\nd3d9 = mtld3d\nadd-arguments = -dx11\nenv = DXMT_CONFIG=d3d12.asyncPipelineCompile=False\nenv = OVERPASS_X87=0\ndll = xaudio2_7=n,b\n`), []);
});

test('lines the current file has pass, even ones a suggestion could not add', () => {
  assert.deepEqual(profileProblems(`${current}\n[My settings]\nsteam-app = 10\ngraphics = dxmt\n`, current), []);
});

test('install and launch stay pull requests', () => {
  assert.deepEqual(profileProblems('[app]\nname = A\n[install]\ndownload = https://evil.example/x.exe\n'), ['[install] needs a pull request']);
  assert.deepEqual(profileProblems('[app]\nname = A\n[launch]\nexecutable = C:\\x.exe\n'), ['[launch] needs a pull request']);
  assert.deepEqual(profileProblems(current.replace('setup.exe', 'other.exe'), current), ['[install] needs a pull request']);
});

test('keys that run or change files are refused', () => {
  for (const key of ['replace-path', 'file', 'stale-file', 'json-setting', 'wait-ignore']) {
    assert.deepEqual(profileProblems(`[Rule]\nprogram = a.exe\n${key} = x\n`), [`${key} needs a pull request`]);
  }
  for (const key of ['icon', 'cover', 'component', 'dependency', 'runtime', 'bottle-group', 'featured']) {
    assert.deepEqual(profileProblems(`[app]\nname = A\n${key} = x\n`), [`${key} needs a pull request`]);
  }
});

test('a value change on an existing line counts as new', () => {
  assert.deepEqual(profileProblems(current.replace('a=b', 'a=c'), current), ['replace-path needs a pull request']);
});

test('variables that pick what code loads are refused', () => {
  for (const name of ['DYLD_INSERT_LIBRARIES', 'WINEDLLPATH', 'WINELOADER', 'PATH', 'LD_PRELOAD', 'OVERPASS_COMPAT_RULES']) {
    assert.deepEqual(profileProblems(`[Rule]\nprogram = a.exe\nenv = ${name}=x\n`), [`the variable ${name} needs a pull request`]);
  }
});

test('a rule can not reach every program', () => {
  assert.deepEqual(profileProblems('[Rule]\nprogram = *\ngraphics = dxmt\n'), ['program = * would reach other programs']);
  assert.deepEqual(profileProblems('[Rule]\nprogram = gam?.exe\n'), ['program = gam?.exe would reach other programs']);
});

test('case and spacing do not get a key past the check', () => {
  assert.deepEqual(profileProblems('[Rule]\nprogram = a.exe\nREPLACE-PATH=x\n'), ['replace-path needs a pull request']);
  assert.deepEqual(profileProblems('[Rule]\nprogram = a.exe\n  Env =  WINEDLLPATH=x\n'), ['the variable WINEDLLPATH needs a pull request']);
});

test('dll values are overrides, nothing else', () => {
  assert.deepEqual(profileProblems('[Rule]\nprogram = a.exe\ndll = ..\\..\\x=n\n'), ['dll = ..\\..\\x=n isn\'t a DLL override']);
});

test('text that is no setting, none at all, or too long', () => {
  assert.deepEqual(profileProblems('name = A\n'), ['"name = A" is outside any section']);
  assert.deepEqual(profileProblems('[Rule]\nhello there\nprogram = a.exe\n'), ['"hello there" isn\'t a setting']);
  assert.deepEqual(profileProblems('# nothing\n'), ['it has no settings']);
  assert.deepEqual(profileProblems(`[Rule]\nprogram = a.exe\n# ${'x'.repeat(20000)}\n`), ['it is too long']);
});

test('profile IDs are safe file names', () => {
  assert.ok(validProfileID('baldurs-gate-3'));
  for (const id of ['', null, '../x', 'a/b', 'A', '-a', 'a.ini']) assert.ok(!validProfileID(id));
});
