// The sums behind e-mail sign-in. An address is kept only as a keyed hash: a plain hash could be reversed by trying
// addresses, so it needs EMAIL_KEY, a secret. Nothing here can give an address back. The same key goes into password
// and code hashes, so the database alone is no use for guessing either.
//
// A Worker's PBKDF2 stops at 100,000 rounds; the key makes up for the rounds that are missing.

const encoder = new TextEncoder();
const ROUNDS = 100000;
// No 0, O, 1 or I: a code gets read off one screen and typed into another.
const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

const hex = (bytes) => [...new Uint8Array(bytes)].map((byte) => byte.toString(16).padStart(2, '0')).join('');

async function keyed(env, purpose, text) {
  const key = await crypto.subtle.importKey('raw', encoder.encode(env.EMAIL_KEY), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return crypto.subtle.sign('HMAC', key, encoder.encode(`${purpose}:${text}`));
}

export const cleanAddress = (text) => String(text ?? '').normalize('NFKC').trim().toLowerCase();
export const validAddress = (address) => address.length <= 254 && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(address);
export const validPassword = (password) => typeof password === 'string' && password.length >= 10 && password.length <= 128;

export const addressHash = async (env, address) => hex(await keyed(env, 'address', address));
export const codeHash = async (env, token, code) => hex(await keyed(env, `code:${token}`, code));

export function newCode() {
  // 32 goes evenly into 256, so every letter is as likely.
  return [...crypto.getRandomValues(new Uint8Array(6))].map((byte) => ALPHABET[byte % ALPHABET.length]).join('');
}
export const cleanCode = (text) => String(text ?? '').replace(/\s+/g, '').toUpperCase();

async function stretched(env, password, salt) {
  const start = await crypto.subtle.importKey('raw', await keyed(env, 'password', password), 'PBKDF2', false, ['deriveBits']);
  return crypto.subtle.deriveBits({ name: 'PBKDF2', hash: 'SHA-256', salt, iterations: ROUNDS }, start, 256);
}

export async function hashPassword(env, password) {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  return `${hex(salt)}.${hex(await stretched(env, password, salt))}`;
}

/// With no stored hash this still does the work, so the time taken doesn't tell whether an account exists.
export async function checkPassword(env, password, stored) {
  const [salt, hash] = (stored || `${'0'.repeat(32)}.`).split('.');
  const tried = hex(await stretched(env, password, Uint8Array.from(salt.match(/../g), (pair) => parseInt(pair, 16))));
  return same(tried, hash);
}

export function same(left, right) {
  if (left.length !== right.length) return false;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  return difference === 0;
}
