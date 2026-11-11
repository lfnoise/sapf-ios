//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

// End-to-end tests of the web app in headless Chrome.
//
//   node scripts/browser-test.mjs            against the dev server (Vite sends the isolation headers)
//   node scripts/browser-test.mjs --prod     against dist/ on a plain static server with no special headers,
//                                            so isolation must come from the service worker; also checks offline use
//   add --examples to also run every example block (several minutes); the report is printed.
//
// Chrome is found at CHROME_PATH, or the usual install locations.

import puppeteer from 'puppeteer-core';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const webDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const prod = process.argv.includes('--prod');
const runExamples = process.argv.includes('--examples');

function findChrome() {
  const candidates = [
    process.env.CHROME_PATH,
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/usr/bin/google-chrome',
    '/usr/bin/google-chrome-stable',
    '/usr/bin/chromium',
    '/usr/bin/chromium-browser',
  ];
  const found = candidates.find(p => p && fs.existsSync(p));
  if (!found) throw new Error('Chrome not found. Set CHROME_PATH.');
  return found;
}

const types = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css', '.wasm': 'application/wasm',
  '.json': 'application/json', '.webmanifest': 'application/manifest+json', '.svg': 'image/svg+xml', '.png': 'image/png', '.txt': 'text/plain' };

/** a static server for dist/ that sends no isolation headers. */
function serveDist(port) {
  const root = path.join(webDir, 'dist');
  const server = http.createServer((req, res) => {
    let p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    if (p.endsWith('/')) p += 'index.html';
    const file = path.join(root, p);
    if (!file.startsWith(root) || !fs.existsSync(file)) { res.writeHead(404); res.end(); return; }
    res.writeHead(200, { 'Content-Type': types[path.extname(file)] ?? 'application/octet-stream' });
    fs.createReadStream(file).pipe(res);
  });
  return new Promise(resolve => server.listen(port, '127.0.0.1', () => resolve(server)));
}

let server;
let url;
if (prod) {
  if (!fs.existsSync(path.join(webDir, 'dist', 'index.html'))) throw new Error('Run "npm run build" first.');
  server = await serveDist(5180);
  url = 'http://127.0.0.1:5180/';
} else {
  const { createServer } = await import('vite');
  server = await createServer({ root: webDir, server: { port: 5181, strictPort: true }, logLevel: 'warn' });
  await server.listen();
  url = 'http://localhost:5181/';
}

const browser = await puppeteer.launch({
  executablePath: findChrome(),
  headless: true,
  args: ['--autoplay-policy=no-user-gesture-required', '--no-sandbox'],
});

let failures = 0;
function check(name, ok, detail = '') {
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${detail ? '  ' + detail : ''}`);
  if (!ok) failures += 1;
}
const sleep = ms => new Promise(r => setTimeout(r, ms));
const readyOn = p => p.waitForFunction(() => window.sapf?.help?.builtInWords?.size > 100 && !window.sapf.engine.isBusy, { timeout: 60000 });

try {
  const context = await browser.createBrowserContext();
  let page = await context.newPage();
  const pageErrors = [];
  const watch = p => p.on('pageerror', e => pageErrors.push(e.message));
  watch(page);
  await page.setViewport({ width: 1366, height: 900 });
  await page.goto(url);
  await readyOn(page);
  if (prod) {
    // On the first visit the page reloads itself once the service worker is installed. Chrome then moves the tab to a
    // new process, which confuses later automated reloads of that tab, so continue in a fresh tab, as a returning
    // visitor would.
    check('first visit becomes isolated through the service worker', await page.evaluate(() => self.crossOriginIsolated));
    await page.close();
    page = await context.newPage();
    watch(page);
    await page.setViewport({ width: 1366, height: 900 });
    await page.goto(url);
    await readyOn(page);
  }
  const ready = () => readyOn(page);

  const app = fn => page.evaluate(fn);
  const consoleText = () => app(() => document.querySelector('.console').textContent);
  const run = async code => {
    await page.evaluate(c => window.sapf.evaluate(c), code);
    await page.waitForFunction(() => !window.sapf.engine.isBusy, { timeout: 60000 });
    await sleep(100);
  };
  const scopePeak = () => app(() => { const b = new Float32Array(4800); window.sapf.engine.copyOutputSamples(b); return b.reduce((m, v) => Math.max(m, Math.abs(v)), 0); });

  check('page is cross-origin isolated', await app(() => self.crossOriginIsolated));
  check('engine started, prelude loaded, help table built', await app(() => window.sapf.help.builtInWords.has('sinosc') && document.querySelector('.console').textContent.includes('done loading file')));
  check('audio worklet running', await app(() => window.sapf.engine.audioState === 1));
  check('Scratch opens first, with run buttons beside its blocks', await app(() => window.sapf.currentDocument === '/work/Scratch.sapf' && document.querySelectorAll('.run-block').length === 3));

  // the margin run button
  await page.click('.run-block');
  await sleep(800);
  const peak = await scopePeak();
  check('a run button plays its block', peak > 0.15 && peak < 0.25, `peak ${peak.toFixed(3)}`);
  check('the console echoes the code', (await consoleText()).includes('sapf> 440 0 sinosc .2 * play'));
  await page.click('.tool-button.stop');
  await sleep(300);
  check('Stop silences everything', (await scopePeak()) < 1e-6 && (await app(() => window.sapf.analyzer.playingCount)) === 0);

  // help on a word
  const at = await app(() => {
    const v = window.sapf.editor.view;
    const i = v.state.doc.toString().indexOf('sinosc');
    const c = v.coordsAtPos(i + 2);
    return { x: c.left + 2, y: (c.top + c.bottom) / 2 };
  });
  await page.mouse.click(at.x, at.y);
  await sleep(200);
  const tip = await app(() => { const t = document.querySelector('.help-tooltip'); return t.hidden ? '' : t.innerText; });
  check('clicking a word shows its help', tip.includes('sinosc') && tip.includes('@zz') && tip.includes('(freq phase --> out)'), JSON.stringify(tip));
  await page.mouse.click(at.x, at.y);
  await sleep(100);
  check('clicking it again hides the help', await app(() => document.querySelector('.help-tooltip').hidden));

  // a variable's value
  await run('440 = freq');
  await app(() => window.sapf.editor.setText('freq 0 sinosc'));
  const fat = await app(() => { const c = window.sapf.editor.view.coordsAtPos(1); return { x: c.left + 2, y: (c.top + c.bottom) / 2 }; });
  await page.mouse.click(fat.x, fat.y);
  await sleep(400);
  const vtip = await app(() => { const t = document.querySelector('.help-tooltip'); return t.hidden ? '' : t.innerText; });
  check("clicking a variable shows its value", vtip.includes('freq') && vtip.includes('value') && vtip.includes('440'), JSON.stringify(vtip));

  // Expand Selection, with the keyboard
  await app(() => { const e = window.sapf.editor; e.setText('x (1 [2 3] +) play\ny\n\nz'); e.view.dispatch({ selection: { anchor: 6 } }); e.view.focus(); });
  const steps = [];
  for (let i = 0; i < 5; ++i) {
    await page.keyboard.down('Meta'); await page.keyboard.press('b'); await page.keyboard.up('Meta');
    steps.push(await app(() => { const s = window.sapf.editor.view.state; const r = s.selection.main; return s.doc.sliceString(r.from, r.to); }));
  }
  check('Expand Selection (Cmd-B) grows by brackets, then the block', JSON.stringify(steps) === JSON.stringify(['2 3', '[2 3]', '1 [2 3] +', '(1 [2 3] +)', 'x (1 [2 3] +) play\ny']), JSON.stringify(steps));

  // plot
  await run('clear [300 0 sinosc 500 0 sinosc] (1 .3 0 line) *');
  await app(() => window.sapf.plotTopOfStack());
  await sleep(300);
  check('Plot Top of Stack shows a plot and says so', (await app(() => !document.querySelector('.scope-switch').hidden)) && (await consoleText()).includes('plot: 2 channels, 1.00 s'));
  await page.click('.close-plot');
  await sleep(100);
  check('Close Plot returns to the output', await app(() => document.querySelector('.scope-switch').hidden));
  await run('clear');
  await app(() => window.sapf.plotTopOfStack());
  await sleep(300);
  check('plotting an empty stack says why', (await consoleText()).includes('plot: the stack is empty'));

  // dragging on a scope drives mousex
  const scope = await page.$('.scope canvas');
  const box = await scope.boundingBox();
  await page.mouse.move(box.x + box.width * 0.25, box.y + box.height / 2);
  await page.mouse.down();
  await run('clear 0 100 mousex 4 N');
  await page.mouse.up();
  check('dragging on a scope drives mousex', /#\[25/.test(await consoleText()));

  // record and sgram open previews
  await run('clear 440 0 sinosc (.3 .2 0 line) * "rec-test" record');
  await page.waitForSelector('.preview-dialog audio', { timeout: 10000 }).catch(() => {});
  check('record writes to Recordings and shows a preview', await app(() => window.sapf.documents.exists('/work/Recordings/rec-test.wav') && !!document.querySelector('.preview-dialog audio')));
  await app(() => window.sapf.preview.close());
  await run('clear 200 0 (1 1 100 xline) blip 144 "sg-test" sgram');
  await page.waitForSelector('.preview-dialog img', { timeout: 10000 }).catch(() => {});
  check('sgram writes to Spectrograms and shows the image', await app(() => window.sapf.documents.exists('/work/Spectrograms/sg-test-144.jpg') && !!document.querySelector('.preview-dialog img')));
  await app(() => window.sapf.preview.close());

  // the log, README and All Functions
  check('evaluated code is logged', await app(() => window.sapf.documents.readText('/work/sapf-log.txt').includes('440 = freq')));
  await run('logfile');
  await sleep(200);
  check('logfile shows the log', await app(() => document.querySelector('.preview-dialog .dialog-title')?.textContent === 'sapf-log.txt'));
  await app(() => window.sapf.preview.close());
  await run('readme');
  await sleep(200);
  check('readme shows the README without the command line sections', await app(() => {
    const t = document.querySelector('.preview-dialog .preview-text')?.textContent ?? '';
    return t.includes('BUILT IN FUNCTION HELP') && !t.includes('QUICK SET-UP');
  }));
  await app(() => window.sapf.preview.close());
  await page.click('.tool-button.more');
  await app(() => [...document.querySelectorAll('.menu-item')].find(b => b.textContent.includes('List All Functions')).click());
  await sleep(200);
  check('List All Functions shows styled entries', await app(() => document.querySelectorAll('.function-list p.entry').length > 300 && !!document.querySelector('.function-list .fn-name')));
  await app(() => document.querySelector('.function-list-dialog').close());

  // documents: new, edit, revert, persistence
  await page.click('.tool-button.documents');
  await app(() => [...document.querySelectorAll('.menu-item')].find(b => b.textContent.includes('New Document')).click());
  await sleep(100);
  check('New Document makes Untitled', await app(() => window.sapf.currentDocument === '/work/Untitled.sapf' && document.querySelector('.toolbar-title').textContent === 'Untitled'));
  await app(() => { const v = window.sapf.editor.view; v.dispatch({ changes: { from: 0, insert: '1 2 3 + +\n\n4 5 *\n' } }); });
  await app(() => window.sapf.saveNow());
  await app(() => window.sapf.loadDocument('/work/Examples.sapf'));
  await app(() => { const v = window.sapf.editor.view; v.dispatch({ changes: { from: 0, insert: '; my change\n' } }); window.sapf.saveNow(); window.sapf.refreshDocuments(); });
  await page.click('.tool-button.documents');
  const docMenu = await app(() => [...document.querySelectorAll('.menu-item')].map(b => b.textContent.trim()));
  check('the Documents menu lists documents and offers Revert for a changed built-in',
    ['Scratch', 'Examples', 'Builtin Examples', 'Prelude', 'Untitled'].every(n => docMenu.some(t => t.endsWith(n))) && docMenu.some(t => t.includes('Revert to Original')), JSON.stringify(docMenu));
  await app(() => [...document.querySelectorAll('.menu-item')].find(b => b.textContent.includes('Revert to Original')).click());
  await sleep(100);
  await app(() => [...document.querySelectorAll('.dialog-button')].find(b => b.textContent === 'Revert').click());
  await sleep(200);
  check('Revert to Original puts it back', await app(() => !window.sapf.editor.text.startsWith('; my change') && !window.sapf.documents.modifiedBuiltIns().length));

  await app(() => window.sapf.loadDocument('/work/Untitled.sapf'));
  await app(() => { const v = window.sapf.editor.view; v.dispatch({ selection: { anchor: 12 } }); });
  await app(() => window.sapf.documents.syncNow());
  await page.reload();
  await ready();
  await sleep(300);
  const after = await app(() => ({ doc: window.sapf.currentDocument, text: window.sapf.editor.text, sel: window.sapf.editor.view.state.selection.main.head }));
  check('documents, the current document and its position persist across reload',
    after.doc === '/work/Untitled.sapf' && after.text === '1 2 3 + +\n\n4 5 *\n' && after.sel === 12, JSON.stringify(after));

  // UI Mode
  await page.click('.tool-button.more');
  await app(() => [...document.querySelectorAll('.menu-item')].find(b => b.textContent.trim() === 'Dark').click());
  check('UI Mode Dark applies', await app(() => document.documentElement.dataset.theme === 'dark'));
  await page.click('.tool-button.more');
  await app(() => [...document.querySelectorAll('.menu-item')].find(b => b.textContent.trim() === 'Auto').click());

  if (prod) {
    // a hard reload bypasses the service worker; the app must still come up.
    await page.reload({ ignoreCache: true });
    await ready();
    check('recovers after a hard reload', await app(() => self.crossOriginIsolated));
  }

  // a phone, in its own tab (changing the emulated device reloads a tab)
  const phone = await context.newPage();
  watch(phone);
  await phone.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true });
  await phone.goto(url);
  await readyOn(phone);
  check('on a phone: reading mode, reading bar, tabs, Run in the More menu', await phone.evaluate(() =>
    !window.sapf.editor.isEditing && !document.querySelector('.reading-bar').hidden && !!document.querySelector('.tabbed-picker') &&
    document.querySelector('.tool-button.run').hidden && !document.querySelector('.edit-toggle').hidden));
  await phone.close();

  // unit tests through the engine
  const tests = fs.readFileSync(path.join(webDir, '..', 'unit-tests.txt'), 'utf8');
  const mark = await app(() => window.sapf.console.totalLength);
  await run(tests);
  await sleep(300);
  const unit = await page.evaluate(m => window.sapf.console.textSince(m), mark);
  const passed = unit.split('Passed').length - 1;
  const failed = unit.split('*** FAILED ***').length - 1;
  check('unit tests pass in the browser', passed > 300 && failed === 0, `passed ${passed}, failed ${failed}`);

  if (prod) {
    // everything loaded so far is cached by the service worker, so the app must start with no network.
    const offline = await context.newPage();
    await offline.setOfflineMode(true);
    await offline.goto(url);
    await readyOn(offline);
    await offline.evaluate(() => window.sapf.evaluate('clear 2 3 *'));
    await offline.waitForFunction(() => !window.sapf.engine.isBusy);
    await sleep(200);
    check('works offline', await offline.evaluate(() => document.querySelector('.console').textContent.trimEnd().endsWith('6')));
    await offline.close();
  }

  if (runExamples) {
    console.log('running all examples (several minutes)…');
    await app(() => { window.sapf.engine.muted = true; window.__report = null; void window.sapf.runner.run().then(r => { window.__report = r; }); });
    let report = null;
    while (report === null) {
      await sleep(5000);
      const r = await app(() => ({ report: window.__report, status: document.querySelector('.runner-status')?.textContent ?? '' }));
      report = r.report;
      if (r.status) process.stdout.write(`\r  ${r.status}            `);
    }
    process.stdout.write('\n');
    console.log(report);
    check('example runner finished', report.startsWith('SUMMARY'), report.split('\n')[0]);
  }

  check('no uncaught page errors', pageErrors.length === 0, pageErrors.join(' | '));
} finally {
  await browser.close();
  await server.close();
}

console.log(failures ? `\n${failures} check(s) failed` : '\nall checks passed');
process.exit(failures ? 1 : 0);
