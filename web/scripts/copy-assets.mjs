//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Copy the bundled sapf text files from the repository root into public/sapf, with a manifest.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const webDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const repoDir = path.resolve(webDir, '..');
const outDir = path.join(webDir, 'public', 'sapf');

// same files the iOS app bundles.
const files = ['sapf-prelude.txt', 'sapf-examples.txt', 'sapf-bif-examples.txt', 'unit-tests.txt', 'README.txt', 'sapf-guide.html'];

fs.mkdirSync(outDir, { recursive: true });
const manifest = {};
for (const name of files) {
  const data = fs.readFileSync(path.join(repoDir, name));
  fs.writeFileSync(path.join(outDir, name), data);
  manifest[name] = crypto.createHash('sha256').update(data).digest('hex').slice(0, 16);
}
fs.writeFileSync(path.join(outDir, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');

if (!fs.existsSync(path.join(webDir, 'public', 'engine', 'sapf-engine.wasm'))) {
  console.warn('warning: public/engine is missing. run "npm run engine" to build the WebAssembly engine.');
}
console.log(`copied ${files.length} files to public/sapf`);
