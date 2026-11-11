//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

import { defineConfig } from 'vite';

// The engine uses SharedArrayBuffer (pthreads + AudioWorklet), so pages must be cross-origin isolated.
// The dev and preview servers send the headers; on static hosting public/sw.js adds them.
const isolation = {
  'Cross-Origin-Opener-Policy': 'same-origin',
  'Cross-Origin-Embedder-Policy': 'require-corp',
};

export default defineConfig({
  // SAPF_BASE is set by the GitHub Pages build, e.g. /sapf/
  base: process.env.SAPF_BASE ?? '/',
  server: { headers: isolation },
  preview: { headers: isolation },
  build: { target: 'es2022' },
});
