//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Run All Examples: runs every block of the example files and the unit tests, listening briefly to each sound,
// and writes a report of errors and silent sounds to example-report.txt. A check that the whole interpreter works
// in the browser.

import { tokenize } from './lexer.ts';
import { CodeStructure } from './codeStructure.ts';
import type { SapfEngine } from './engine.ts';
import type { ConsoleBuffer } from './console.ts';
import { DIRECTORY, BUNDLED, type DocumentStore } from './documents.ts';

export interface RunnerHost {
  engine: SapfEngine;
  console: ConsoleBuffer;
  documents: DocumentStore;
  assetBase: string;
  stop(): void;
  setStatus(status: string | null): void;
  setSuppressPreviews(suppress: boolean): void;
}

const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));
const errorMarkers = ['error:', 'parse error', 'exception in real time', 'notFound', '*** FAILED ***', 'undefined', 'not enough memory', 'unknown error'];

/** every runnable block of a file, with its 1-based line number. */
export function runnableBlocks(text: string): { code: string; line: number }[] {
  const structure = new CodeStructure(text, tokenize(text, new Set(), new Set()));
  return structure.blocks
    .filter(b => b.codeStart !== null)
    .map(b => ({ code: text.slice(b.range.from, b.range.to), line: text.slice(0, b.range.from).split('\n').length }));
}

export class ExampleRunner {
  isRunning = false;
  private cancelled = false;
  listenSeconds = 1.5;
  extraSilentSeconds = 8;

  private host: RunnerHost;
  constructor(host: RunnerHost) {
    this.host = host;}

  cancel(): void {
    this.cancelled = true;
  }

  async run(): Promise<string> {
    if (this.isRunning) return '';
    const h = this.host;
    this.isRunning = true;
    this.cancelled = false;
    h.setSuppressPreviews(true);
    let report = '';
    try {
      report = await this.runAll();
      const path = `${DIRECTORY}/example-report.txt`;
      h.documents.writeText(path, report);
      h.console.append(`\nexample report written to ${path}\n`);
    } finally {
      h.stop();
      h.setSuppressPreviews(false);
      h.setStatus(null);
      this.isRunning = false;
    }
    return report;
  }

  /** output reaches the console after evaluation completes. Wait until it stops arriving. */
  private async settle(): Promise<void> {
    let length = -1;
    while (length !== this.host.console.totalLength) {
      length = this.host.console.totalLength;
      this.host.engine.poll();
      await sleep(200);
    }
  }

  private async runAll(): Promise<string> {
    const h = this.host;
    const engine = h.engine;
    let report = '';
    let failures = 0;
    let silent = 0;
    let total = 0;
    const scope = new Float32Array(4800);

    for (const [path] of BUNDLED.filter(b => b[1] !== 'sapf-prelude.txt')) {
      const name = path.slice(DIRECTORY.length + 1);
      let source: string;
      try { source = h.documents.readText(path); } catch { report += `could not read ${name}\n`; continue; }
      const blocks = runnableBlocks(source);
      report += `==== ${name}: ${blocks.length} blocks\n`;
      for (const [index, block] of blocks.entries()) {
        if (this.cancelled) return report + 'cancelled\n';
        total += 1;
        h.setStatus(`${name} ${index + 1} of ${blocks.length}`);
        const mark = h.console.totalLength;
        const plays = /\bplay\b/.test(block.code);
        h.console.append(`\n>>>> ${name}:${block.line}\n`);
        await engine.evaluate(block.code);
        let peak = 0;
        if (plays) {
          // sweep the pointer back and forth so examples played with the mouse make sound.
          const start = performance.now();
          let elapsed = 0;
          while (elapsed < this.listenSeconds || (peak < 1e-5 && elapsed < this.listenSeconds + this.extraSilentSeconds)) {
            await sleep(100);
            elapsed = (performance.now() - start) / 1000;
            const phase = elapsed % 1;
            const sweep = phase < 0.5 ? phase * 2 : 2 - phase * 2;
            engine.setPointer(sweep, sweep, true);
            engine.copyOutputSamples(scope);
            for (const s of scope) peak = Math.max(peak, Math.abs(s));
            if (this.cancelled) break;
          }
          engine.setPointer(0.5, 0.5, false);
          h.stop();
          await sleep(150);
        }
        await this.settle();
        await engine.clearStack();
        const text = h.console.textSince(mark);
        const errors = text.split('\n').filter(line => errorMarkers.some(m => line.includes(m)));
        const firstLine = block.code.split('\n').find(l => !l.trim().startsWith(';') && l.trim()) ?? '';
        let line = `${name}:${block.line} `;
        if (errors.length) { failures += 1; line += 'ERROR '; }
        else if (plays && peak < 1e-5) { silent += 1; line += 'SILENT '; }
        else line += 'ok ';
        if (plays) line += `peak ${peak.toFixed(3)} `;
        line += `| ${firstLine.slice(0, 90)}`;
        for (const error of errors.slice(0, 3)) line += `\n      ${error}`;
        report += line + '\n';
      }
    }

    // unit tests run as one program, printing *** FAILED *** for failures.
    if (!this.cancelled) {
      h.setStatus('unit tests');
      const response = await fetch(`${h.assetBase}sapf/unit-tests.txt`);
      if (response.ok) {
        const mark = h.console.totalLength;
        await engine.evaluate(await response.text());
        await this.settle();
        await engine.clearStack();
        const text = h.console.textSince(mark);
        const passed = text.split('Passed').length - 1;
        const failed = text.split('*** FAILED ***').length - 1;
        const errored = text.includes('error:');
        report += `==== unit tests: ${passed} passed, ${failed} failed${errored ? ', errors reported' : ''}\n`;
        if (failed > 0 || errored) failures += 1;
      }
    }

    const summary = `SUMMARY: ${total} blocks, ${failures} with errors, ${silent} silent\n`;
    h.console.append('\n' + summary);
    return summary + report;
  }
}
