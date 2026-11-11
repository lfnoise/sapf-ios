//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The interpreter, compiled to WebAssembly (web/engine/sapf_web.cpp). The web counterpart of the iOS SapfEngine.
//
// Requests (evaluate, plot, describe a word, clear the stack) run in order on the interpreter's own thread;
// their results and printed output are collected by polling. Stop, the pointer and the scope act immediately.

/* eslint-disable @typescript-eslint/no-explicit-any */

export interface EmscriptenFS {
  mkdir(path: string): void;
  mount(type: unknown, opts: object, mountpoint: string): void;
  syncfs(populate: boolean, callback: (err: unknown) => void): void;
  readdir(path: string): string[];
  stat(path: string): { mode: number; size: number; mtime: Date };
  isDir(mode: number): boolean;
  readFile(path: string, opts: { encoding: 'utf8' }): string;
  readFile(path: string): Uint8Array;
  writeFile(path: string, data: string | Uint8Array): void;
  rename(from: string, to: string): void;
  unlink(path: string): void;
  rmdir(path: string): void;
  analyzePath(path: string): { exists: boolean };
}

export interface SapfModule {
  FS: EmscriptenFS;
  IDBFS: unknown;
  ENV: Record<string, string>;
  wasmMemory: WebAssembly.Memory;
  UTF8ToString(ptr: number): string;
  stringToUTF8(s: string, ptr: number, max: number): void;
  lengthBytesUTF8(s: string): number;
  emscriptenGetAudioObject(handle: number): AudioContext;
  _malloc(n: number): number;
  _free(ptr: number): void;
  [name: `_${string}`]: any;
}

/** Samples taken from the top of the stack. */
export interface PlotData {
  channels: Float32Array[];
  frameCount: number;
  /** signals are at the sample rate; otherwise each frame is one item of a list of numbers. */
  isSignal: boolean;
  truncated: boolean;
  sampleRate: number;
}

interface RawResult {
  id: number;
  ok: boolean;
  bif?: string[];
  udf?: string[];
  plot?: { ptr: number; channels: number; frames: number; isSignal: boolean; truncated: boolean; sampleRate: number } | null;
  message?: string;
  value?: string | null;
}

interface PollResult {
  busy: number;
  output: string;
  results: RawResult[];
  open: string[];
}

export interface AudioTiming {
  dropouts: number;
  lateRenders: number;
  peakLoad: number;
}

export class SapfEngine {
  module!: SapfModule;
  sampleRate = 48000;
  version = '0.1.22';
  /** printed text, delivered in order. */
  onOutput: (text: string) => void = () => {};
  /** a file the interpreter wants shown (recordings, spectrograms, the README, the log). */
  onOpenFile: (path: string) => void = () => {};
  /** whether requests are queued or running. */
  onBusyChange: (busy: boolean) => void = () => {};
  /** new help lines: built-in ones once at startup, user defined ones as they are defined. */
  onHelp: (builtIn: string[], userDefined: string[]) => void = () => {};

  private nextId = 1;
  private pending = new Map<number, (r: RawResult) => void>();
  private busy = false;
  private pollTimer = 0;
  private scratch = 0;
  private scratchBytes = 0;

  // Scope geometry, from Play.hpp.
  scopeBufferSize = 16384;
  envelopeBlockSize = 128;
  envelopeBlocks = 16384;

  /**
   * Load the engine module from base (the site root, ending in /). env is the environment the interpreter
   * sees (SAPF_RECORDINGS etc.); it is given here because the C runtime reads it once at startup.
   */
  static async load(base: string, env: Record<string, string>): Promise<SapfEngine> {
    if (!self.crossOriginIsolated) {
      throw new Error('This page is not cross-origin isolated, so the audio engine cannot run.');
    }
    // The engine is served as-is from public/engine, not bundled: its pthread workers and audio worklet load the
    // same file again by URL. A plain import() would be rewritten by Vite, so it is hidden from the bundler.
    const url = new URL(`${base}engine/sapf-engine.mjs`, location.href).href;
    const importModule = new Function('url', 'return import(url)') as (url: string) => Promise<{ default: unknown }>;
    const factory = (await importModule(url)).default as (opts?: object) => Promise<SapfModule>;
    const engine = new SapfEngine();
    engine.module = await factory({
      preRun: [(m: SapfModule) => Object.assign(m.ENV, env)],
      // output arrives through sapf_poll; these only catch anything printed outside the interpreter.
      print: (s: string) => console.log(s),
      printErr: (s: string) => console.warn(s),
    });
    const m = engine.module;
    engine.scopeBufferSize = m._sapf_scope_buffer_size();
    engine.envelopeBlockSize = m._sapf_scope_envelope_block_size();
    engine.envelopeBlocks = m._sapf_scope_envelope_blocks();
    return engine;
  }

  /** a view of floats in the shared heap, copied out (the heap may grow, so make a fresh view each time). */
  private f32(ptr: number, count: number): Float32Array {
    return new Float32Array(this.module.wasmMemory.buffer, ptr, count).slice();
  }

  private ensureScratch(bytes: number): number {
    if (bytes > this.scratchBytes) {
      if (this.scratch) this.module._free(this.scratch);
      this.scratchBytes = Math.max(bytes, 65536);
      this.scratch = this.module._malloc(this.scratchBytes);
    }
    return this.scratch;
  }

  private withString<T>(s: string, f: (ptr: number) => T): T {
    const m = this.module;
    const n = m.lengthBytesUTF8(s) + 1;
    const p = m._malloc(n);
    m.stringToUTF8(s, p, n);
    try {
      return f(p);
    } finally {
      m._free(p);
    }
  }

  /**
   * Create the audio context and start the interpreter, loading the prelude at preludePath (in the engine's file
   * system). Resolves once the prelude has loaded.
   */
  start(preludePath: string, latencyHint: string): Promise<void> {
    const done = new Promise<void>(resolve => this.pending.set(0, () => resolve()));
    this.sampleRate = this.withString(preludePath, p => this.withString(latencyHint, h => this.module._sapf_start(p, h)));
    this.pollTimer = window.setInterval(() => this.poll(), 30);
    this.setBusy(true);
    return done;
  }

  get audioContext(): AudioContext {
    return this.module.emscriptenGetAudioObject(this.module._sapf_audio_context());
  }

  /** 0 starting, 1 ready, -1 failed. */
  get audioState(): number {
    return this.module._sapf_audio_state();
  }

  async resumeAudio(): Promise<void> {
    const ctx = this.audioContext;
    if (ctx.state !== 'running') await ctx.resume();
  }

  private request(send: (id: number) => void): Promise<RawResult> {
    const id = this.nextId++;
    const done = new Promise<RawResult>(resolve => this.pending.set(id, resolve));
    send(id);
    this.setBusy(true);
    return done;
  }

  /** Evaluate code at top level. Errors and the stack are printed. Resolves when it has run. */
  async evaluate(code: string): Promise<boolean> {
    const r = await this.request(id => this.withString(code, p => this.module._sapf_evaluate(p, id)));
    return r.ok;
  }

  /** Plot the top of the stack without removing it: the samples, or a message saying why not. */
  async plotTopOfStack(maxSeconds: number): Promise<{ plot: PlotData | null; message: string }> {
    const r = await this.request(id => this.module._sapf_plot(maxSeconds, id));
    const p = r.plot;
    if (!p) return { plot: null, message: r.message ?? '' };
    const all = this.f32(p.ptr, p.channels * p.frames);
    this.module._free(p.ptr);
    const channels: Float32Array[] = [];
    for (let c = 0; c < p.channels; ++c) channels.push(all.subarray(c * p.frames, (c + 1) * p.frames));
    return { plot: { channels, frameCount: p.frames, isSignal: p.isSignal, truncated: p.truncated, sampleRate: p.sampleRate }, message: '' };
  }

  /** The value of a workspace variable, printed short, or null if there is none. */
  async describeWord(word: string): Promise<string | null> {
    const r = await this.request(id => this.withString(word, p => this.module._sapf_describe_word(p, id)));
    return r.value ?? null;
  }

  async clearStack(): Promise<void> {
    await this.request(id => this.module._sapf_clear_stack(id));
  }

  /** stop all sound. Immediate, even while something is evaluating. */
  stop(): void {
    this.module._sapf_stop();
  }

  setPointer(x: number, y: number, down: boolean): void {
    this.module._sapf_set_pointer(x, y, down ? 1 : 0);
  }

  set muted(muted: boolean) {
    this.module._sapf_set_muted(muted ? 1 : 0);
  }

  /** the newest n frames of the mono mix of everything playing, oldest first, into out. Returns how many are playing. */
  copyOutputSamples(out: Float32Array): number {
    const n = out.length;
    const p = this.ensureScratch(n * 4);
    const playing = this.module._sapf_scope_samples(p, n);
    out.set(new Float32Array(this.module.wasmMemory.buffer, p, n));
    return playing;
  }

  /** the newest n envelope blocks, oldest first. Returns how many are playing. */
  copyOutputEnvelope(min: Float32Array, max: Float32Array): number {
    const n = min.length;
    const p = this.ensureScratch(n * 8);
    const playing = this.module._sapf_scope_envelope(p, p + n * 4, n);
    const buf = this.module.wasmMemory.buffer;
    min.set(new Float32Array(buf, p, n));
    max.set(new Float32Array(buf, p + n * 4, n));
    return playing;
  }

  timing(resetPeakLoad: boolean): AudioTiming {
    const p = this.ensureScratch(12);
    this.module._sapf_timing(p, resetPeakLoad ? 1 : 0);
    const [dropouts, lateRenders, peakLoad] = new Float32Array(this.module.wasmMemory.buffer, p, 3);
    return { dropouts, lateRenders, peakLoad };
  }

  get isBusy(): boolean { return this.busy; }

  private setBusy(busy: boolean): void {
    if (busy !== this.busy) {
      this.busy = busy;
      this.onBusyChange(busy);
    }
  }

  /** collect output and results. Called on a timer; may also be called directly. */
  poll(): void {
    const r = JSON.parse(this.module.UTF8ToString(this.module._sapf_poll())) as PollResult;
    if (r.output) this.onOutput(r.output);
    for (const result of r.results) {
      if ((result.bif && result.bif.length) || (result.udf && result.udf.length)) this.onHelp(result.bif ?? [], result.udf ?? []);
      const resolve = this.pending.get(result.id);
      this.pending.delete(result.id);
      resolve?.(result);
    }
    for (const path of r.open) this.onOpenFile(path);
    this.setBusy(r.busy > 0);
  }

  dispose(): void {
    window.clearInterval(this.pollTimer);
  }
}
