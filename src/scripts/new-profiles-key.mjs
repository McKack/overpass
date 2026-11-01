#!/usr/bin/env node
// Makes the key that signs profile updates: the private half goes straight into the repository secret
// PROFILES_SIGNING_KEY and is never written anywhere else, the public half into the app. Run it once, from anywhere.
// Running it again replaces the key; apps from before that stop taking updates until they update themselves.

import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';

const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
const secret = spawnSync('gh', ['secret', 'set', 'PROFILES_SIGNING_KEY', '-R', 'McKack/overpass'], {
  input: privateKey.export({ type: 'pkcs8', format: 'pem' }), stdio: ['pipe', 'inherit', 'inherit'],
});
if (secret.status !== 0) process.exit(1);
const raw = publicKey.export({ type: 'spki', format: 'der' }).subarray(-32).toString('base64');
const file = new URL('../Sources/OverPass/ProfilesKey.swift', import.meta.url);
fs.writeFileSync(file, fs.readFileSync(file, 'utf8').replace(/publicKey = ".*"/, `publicKey = "${raw}"`));
console.log(`Public key: ${raw}`);
