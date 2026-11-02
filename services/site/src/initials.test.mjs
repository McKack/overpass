import test from 'node:test';
import assert from 'node:assert/strict';
import { initials } from './index.js';

test('a number that starts the name comes first, up to four digits', () => {
  for (const [name, mark] of [['100% Orange Juice', '100'], ['12Tails', '12'], ['1000 Days', '1000'], ['12345 Nights', '1234'], ['007 Legends', '007'], ['99', '99']]) {
    assert.equal(initials(name), mark);
  }
});

test('a single digit takes the next word, or the next character', () => {
  for (const [name, mark] of [['7 Days to Die', '7D'], ['3on3 FreeStyle', '3F'], ['2XKO', '2X'], ['9Dragons', '9D']]) {
    assert.equal(initials(name), mark);
  }
});

test('one letter takes the next character', () => {
  for (const [name, mark] of [['Musicbee', 'MU'], ['DOOM', 'DO'], ["Don't", 'DO'], ['Ékra', 'ÉK']]) {
    assert.equal(initials(name), mark);
  }
});

test('names with two parts are unchanged', () => {
  for (const [name, mark] of [['MusicBee', 'MB'], ['OverPass', 'OP'], ['Super!Blast', 'SB'], ['Half-Life 2', 'HL'], ['Portal 2', 'P2']]) {
    assert.equal(initials(name), mark);
  }
});

test('a name too short for two keeps what it has', () => {
  assert.equal(initials('9'), '9');
  assert.equal(initials('X'), 'X');
  assert.equal(initials('!!!'), '?');
  assert.equal(initials(''), '?');
});
