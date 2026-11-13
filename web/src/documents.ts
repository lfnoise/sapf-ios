//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The user's documents. A port of DocumentStore in ios/Sapf/App/AppModel.swift.
//
// They live in the engine's file system (Emscripten FS, with /work kept in IndexedDB), so the interpreter
// reads and writes the same files: the prelude, the log, recordings and spectrograms.

import type { SapfModule } from './engine.ts';

export const DIRECTORY = '/work';
export const RECORDINGS = `${DIRECTORY}/Recordings`;
export const SPECTROGRAMS = `${DIRECTORY}/Spectrograms`;
/** imported sound files, which sf> finds by name. */
export const SOUNDS = `${DIRECTORY}/Sounds`;
export const SCRATCH = `${DIRECTORY}/Scratch.sapf`;
export const PRELUDE = `${DIRECTORY}/Prelude.sapf`;
/** every block run, with a timestamp line each hour. Not in the documents list. */
export const LOG = `${DIRECTORY}/sapf-log.txt`;
/** the README as the app shows it, rewritten at each start. */
export const README = '/cache/README.txt';
export const TMPDIR = '/tmp';

/** documents copied from the bundled files, and the bundled file names, in the order the Documents menu lists them. */
export const BUNDLED: [string, string][] = [
  [`${DIRECTORY}/Examples.sapf`, 'sapf-examples.txt'],
  [`${DIRECTORY}/Builtin Function Examples.sapf`, 'sapf-bif-examples.txt'],
  [PRELUDE, 'sapf-prelude.txt'],
];

/** built-in documents that were renamed: old file name to new. Existing copies are renamed, keeping any edits. */
export const RENAMED: Record<string, string> = {
  'Builtin Examples.sapf': 'Builtin Function Examples.sapf',
};

/** the guide, in the bundled files. */
export const GUIDE = 'sapf-guide.html';

export const WELCOME = `; Welcome to sapf. The Guide (the book button) explains it, with examples to try.
; Put the cursor in a block of code and press Run (or Cmd-Return / Ctrl-Return).
; Click a word to see its help. Stop sounds with the stop button (or Cmd-. / Ctrl-.).
; Drag on the waveform or spectrum to control mousex and mousey.

440 0 sinosc .2 * play

(300 1000 xmousex 0 sinosc .2 * play)

;; analog bubbles
((.4 0 lfsaw) 2 * ([8 7.23] 0 lfsaw) .25 * 9.667 + + exp2) 0 sinosc .04 * .2 0 4 combn play
`;

export function baseName(path: string): string {
  return path.slice(path.lastIndexOf('/') + 1);
}

export function extensionOf(path: string): string {
  const name = baseName(path);
  const dot = name.lastIndexOf('.');
  return dot > 0 ? name.slice(dot + 1).toLowerCase() : '';
}

/** a document's title: its name without the extension. */
export function title(path: string): string {
  const name = baseName(path);
  const dot = name.lastIndexOf('.');
  return dot > 0 ? name.slice(0, dot) : name;
}

export class DocumentStore {
  /** the bundled files' text, for reverting and for telling whether a built-in was changed. */
  private originals = new Map<string, string>();
  private syncTimer = 0;
  private syncing: Promise<void> | null = null;
  private syncAgain = false;

  private m: SapfModule;
  private assetBase: string;
  constructor(m: SapfModule, assetBase: string) {
    this.m = m;
    this.assetBase = assetBase;}

  private get fs() { return this.m.FS; }

  exists(path: string): boolean {
    return this.fs.analyzePath(path).exists;
  }

  private mkdirs(path: string): void {
    let p = '';
    for (const part of path.split('/').filter(Boolean)) {
      p += '/' + part;
      if (!this.exists(p)) this.fs.mkdir(p);
    }
  }

  /** mount the persistent folder, load what was saved, and set up the documents. */
  async setUp(): Promise<void> {
    this.mkdirs(DIRECTORY);
    this.fs.mount(this.m.IDBFS, {}, DIRECTORY);
    await new Promise<void>((resolve, reject) => this.fs.syncfs(true, err => (err ? reject(err) : resolve())));

    const names = [...BUNDLED.map(b => b[1]), 'README.txt'];
    const texts = await Promise.all(names.map(async name => {
      const response = await fetch(`${this.assetBase}sapf/${name}`);
      if (!response.ok) throw new Error(`could not load ${name}`);
      return response.text();
    }));
    names.forEach((name, i) => this.originals.set(name, texts[i]));

    this.mkdirs(RECORDINGS);
    this.mkdirs(SPECTROGRAMS);
    this.mkdirs(SOUNDS);
    this.mkdirs(TMPDIR);
    for (const [from, to] of Object.entries(RENAMED)) {
      const [oldPath, newPath] = [`${DIRECTORY}/${from}`, `${DIRECTORY}/${to}`];
      if (this.exists(oldPath) && !this.exists(newPath)) this.fs.rename(oldPath, newPath);
    }
    // fetch the guide now so the service worker keeps it for offline use.
    void fetch(`${this.assetBase}sapf/${GUIDE}`).catch(() => {});
    for (const [path, resource] of BUNDLED) {
      if (!this.exists(path)) this.restoreOriginal(path, resource);
    }
    if (!this.exists(SCRATCH)) this.fs.writeFile(SCRATCH, WELCOME);
    this.mkdirs('/cache');
    this.fs.writeFile(README, appReadme(this.originals.get('README.txt') ?? ''));
    this.scheduleSync(0);
  }

  restoreOriginal(path: string, resource: string): void {
    this.fs.writeFile(path, this.originals.get(resource) ?? '');
    this.scheduleSync();
  }

  bundledResource(path: string): string | null {
    return BUNDLED.find(b => b[0] === path)?.[1] ?? null;
  }

  /** whether a built-in document differs from the bundled copy (or is missing). */
  isModified(path: string, resource: string): boolean {
    if (!this.exists(path)) return true;
    return this.readText(path) !== this.originals.get(resource);
  }

  modifiedBuiltIns(): string[] {
    return BUNDLED.filter(([path, resource]) => this.isModified(path, resource)).map(b => b[0]);
  }

  /** all editable documents: Scratch first, then the built-in ones in their order, then the rest in Finder order. */
  list(): string[] {
    let names: string[] = [];
    try {
      names = this.fs.readdir(DIRECTORY);
    } catch {
      return [SCRATCH];
    }
    const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: 'base' });
    const docs = names
      .filter(n => ['sapf', 'txt'].includes(extensionOf(n)) && n !== baseName(LOG))
      .sort(collator.compare)
      .map(n => `${DIRECTORY}/${n}`);
    const builtIns = BUNDLED.map(b => b[0]).filter(p => docs.includes(p));
    return [SCRATCH, ...builtIns, ...docs.filter(p => p !== SCRATCH && !builtIns.includes(p))];
  }

  newDocumentPath(): string {
    return this.unusedPath('Untitled', 'sapf');
  }

  /** a path in the documents folder for name.extension, numbered (“name 2”, “name 3”, …) if that's taken. */
  unusedPath(name: string, extension: string): string {
    for (let n = 1; ; ++n) {
      const path = `${DIRECTORY}/${n === 1 ? name : `${name} ${n}`}.${extension}`;
      if (!this.exists(path)) return path;
    }
  }

  /** whether a document can be renamed: not Scratch or a built-in one, which are made again if missing. */
  canRename(path: string): boolean {
    return path !== SCRATCH && !this.bundledResource(path) && this.isInDocuments(path);
  }

  rename(from: string, to: string): void {
    this.fs.rename(from, to);
    this.scheduleSync(0);
  }

  readText(path: string): string {
    return this.fs.readFile(path, { encoding: 'utf8' });
  }

  readBytes(path: string): Uint8Array {
    return this.fs.readFile(path);
  }

  /** writes a file, replacing any there. Returns whether one was replaced. */
  writeBytes(path: string, bytes: Uint8Array): boolean {
    const replaced = this.exists(path);
    this.fs.writeFile(path, bytes);
    this.scheduleSync();
    return replaced;
  }

  writeText(path: string, text: string): void {
    this.fs.writeFile(path, text);
    this.scheduleSync();
  }

  isInDocuments(path: string): boolean {
    return path.startsWith(DIRECTORY + '/');
  }

  /** save the file system to IndexedDB soon. Writes are coalesced. */
  scheduleSync(delay = 500): void {
    window.clearTimeout(this.syncTimer);
    this.syncTimer = window.setTimeout(() => void this.syncNow(), delay);
  }

  /** save the file system to IndexedDB now. */
  async syncNow(): Promise<void> {
    window.clearTimeout(this.syncTimer);
    if (this.syncing) {
      this.syncAgain = true;
      return this.syncing;
    }
    this.syncing = new Promise<void>(resolve => {
      this.fs.syncfs(false, err => {
        if (err) console.warn('could not save files', err);
        resolve();
      });
    });
    await this.syncing;
    this.syncing = null;
    if (this.syncAgain) {
      this.syncAgain = false;
      await this.syncNow();
    }
  }
}

// MARK: README

/** the README for reading in the app: without the command line sections, and with paragraphs reflowed. */
export function appReadme(text: string): string {
  return reflow(withoutCommandLineSections(text));
}

/** leaves out QUICK SET-UP up to BUILT IN FUNCTION HELP. Returns the text unchanged if they're not found. */
export function withoutCommandLineSections(text: string): string {
  const lines = text.split('\n');
  const heading = (name: string) => lines.findIndex(l => l.trim() === name);
  const start = heading('QUICK SET-UP');
  const end = heading('BUILT IN FUNCTION HELP');
  if (start < 0 || end < 0 || start >= end) return text;
  lines.splice(start, end - start);
  return lines.join('\n');
}

/**
 * Joins lines that were broken only to fit 80 columns. A line is joined onto the one before when both are prose at
 * the same shallow indent and the one before is nearly full and doesn't end a sentence. Deeper indents and lines
 * with --> or starting with ; are code examples and are left alone.
 */
export function reflow(text: string): string {
  const indent = (line: string) => /^[ \t]*/.exec(line)![0];
  const columns = (s: string) => [...s].reduce((n, c) => n + (c === '\t' ? 4 : 1), 0);
  const trimEnd = (s: string) => s.replace(/[ \t]+$/, '');
  const isProse = (line: string) => {
    const body = line.replace(/^[ \t]+/, '');
    return body !== '' && columns(indent(line)) <= 4 && !body.startsWith(';') && !line.includes('-->');
  };
  // a line that ends a sentence may be a list item, so the next line starts a new one.
  const endsSentence = (line: string) => {
    const t = trimEnd(line);
    return t !== '' && '.:?!'.includes(t[t.length - 1]);
  };

  const out: string[] = [];
  let previous: string | null = null;
  for (const line of text.split('\n')) {
    if (previous !== null && isProse(previous) && isProse(line) && indent(previous) === indent(line) &&
        columns(trimEnd(previous)) >= 60 && !endsSentence(previous)) {
      // measure each original line, not the joined result, so a paragraph's short last line still ends it.
      out[out.length - 1] = trimEnd(out[out.length - 1]) + ' ' + line.replace(/^[ \t]+/, '');
    } else {
      out.push(line);
    }
    previous = line;
  }
  return out.join('\n');
}
