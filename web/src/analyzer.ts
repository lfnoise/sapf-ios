//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Once per display frame, grabs the most recent output of everything playing and analyzes it for the waveform,
// spectrum and spectrogram views. Runs only while one of them is on screen. A port of
// ios/Sapf/Visuals/AudioAnalyzer.swift.

import type { SapfEngine } from './engine.ts';

export interface AnalyzerDisplay {
  analyzerDidUpdate(analyzer: AudioAnalyzer): void;
}

export const FFT_SIZE = 4096;
export const MIN_DB = -100;
export const MIN_FREQUENCY = 20;

/** In-place radix-2 complex FFT (forward, unnormalized). */
function fft(re: Float32Array, im: Float32Array, cos: Float32Array, sin: Float32Array): void {
  const n = re.length;
  for (let i = 1, j = 0; i < n; ++i) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) {
      let t = re[i]; re[i] = re[j]; re[j] = t;
      t = im[i]; im[i] = im[j]; im[j] = t;
    }
  }
  for (let len = 2; len <= n; len <<= 1) {
    const half = len >> 1;
    const step = n / len;
    for (let start = 0; start < n; start += len) {
      for (let k = 0; k < half; ++k) {
        const wr = cos[k * step];
        const wi = -sin[k * step];
        const a = start + k;
        const b = a + half;
        const xr = re[b] * wr - im[b] * wi;
        const xi = re[b] * wi + im[b] * wr;
        re[b] = re[a] - xr;
        im[b] = im[a] - xi;
        re[a] += xr;
        im[a] += xi;
      }
    }
  }
}

export class AudioAnalyzer {
  /** the latest output, oldest first, as much as the engine keeps. */
  readonly history: Float32Array;
  /** the latest FFT_SIZE samples of history. */
  readonly samples = new Float32Array(FFT_SIZE);
  /** smoothed magnitude spectrum in dB re full scale sine, FFT_SIZE / 2 bins. */
  readonly spectrumDB = new Float32Array(FFT_SIZE / 2).fill(MIN_DB);
  playingCount = 0;
  peak = 0;
  /** the longest recent audio render as a fraction of the time it had, falling slowly from each peak. */
  renderLoad = 0;
  /** the longest render since sounds last started playing, held so brief spikes can be seen. */
  maxRenderLoad = 0;
  readonly spectrogram = new SpectrogramBuffer(600, 256);

  private displays = new Set<AnalyzerDisplay>();
  private frame = 0;
  private silentFrames = 0;
  private window = new Float32Array(FFT_SIZE);
  private re = new Float32Array(FFT_SIZE);
  private im = new Float32Array(FFT_SIZE);
  private cos = new Float32Array(FFT_SIZE / 2);
  private sin = new Float32Array(FFT_SIZE / 2);

  readonly engine: SapfEngine;
  constructor(engine: SapfEngine) {
    this.engine = engine;
    this.history = new Float32Array(engine.scopeBufferSize);
    for (let i = 0; i < FFT_SIZE; ++i) this.window[i] = 0.5 * (1 - Math.cos((2 * Math.PI * i) / FFT_SIZE));
    for (let k = 0; k < FFT_SIZE / 2; ++k) {
      this.cos[k] = Math.cos((2 * Math.PI * k) / FFT_SIZE);
      this.sin[k] = Math.sin((2 * Math.PI * k) / FFT_SIZE);
    }
  }

  get sampleRate(): number { return Math.max(this.engine.sampleRate, 1); }

  add(display: AnalyzerDisplay): void {
    this.displays.add(display);
    if (!this.frame) this.frame = requestAnimationFrame(() => this.tick());
  }

  remove(display: AnalyzerDisplay): void {
    this.displays.delete(display);
  }

  private tick(): void {
    this.frame = 0;
    if (this.displays.size === 0) return;
    this.frame = requestAnimationFrame(() => this.tick());

    const wasPlaying = this.playingCount > 0;
    this.playingCount = this.engine.copyOutputSamples(this.history);
    if (this.playingCount > 0 && !wasPlaying) this.maxRenderLoad = 0;
    this.samples.set(this.history.subarray(this.history.length - FFT_SIZE));

    // when nothing has played for a while, stop scrolling and drawing to save power.
    this.silentFrames = this.playingCount > 0 ? 0 : this.silentFrames + 1;
    if (this.silentFrames > 90) return;

    let maxMag = 0;
    for (const s of this.samples) maxMag = Math.max(maxMag, Math.abs(s));
    this.peak = maxMag;
    const load = this.engine.timing(true).peakLoad;
    this.renderLoad = Math.max(load, this.renderLoad * 0.98);
    if (this.playingCount > 0) this.maxRenderLoad = Math.max(this.maxRenderLoad, load);

    this.analyzeSpectrum();
    this.spectrogram.addColumn(this.spectrumDB, this.sampleRate);

    for (const d of this.displays) d.analyzerDidUpdate(this);
  }

  private analyzeSpectrum(): void {
    const n = FFT_SIZE;
    const half = n / 2;
    for (let i = 0; i < n; ++i) {
      this.re[i] = this.samples[i] * this.window[i];
      this.im[i] = 0;
    }
    fft(this.re, this.im, this.cos, this.sin);
    // With a Hann window (mean 0.5), a full scale sine has a bin magnitude of n/2 * 0.5 = n/4, so scale by 4/n
    // to make that 0 dB. (The iOS app gets the same result from vDSP's real FFT, which is scaled by 2.)
    const scale = (4 / n) * (4 / n); // magnitudes are squared
    for (let i = 0; i < half; ++i) {
      // bin 0 has no imaginary part; vDSP packs the Nyquist bin there, and the iOS app zeroes it.
      const power = (this.re[i] * this.re[i] + (i === 0 ? 0 : this.im[i] * this.im[i])) * scale;
      const v = Math.max(10 * Math.log10(Math.max(power, 1e-12)), MIN_DB);
      // fast attack, slow release, so the display doesn't flicker.
      const old = this.spectrumDB[i];
      this.spectrumDB[i] = v > old ? v : old + (v - old) * 0.25;
    }
  }

  /** maximum dB over the bins between two frequencies. */
  level(f0: number, f1: number): number {
    const binHz = this.sampleRate / FFT_SIZE;
    const count = this.spectrumDB.length;
    const lo = Math.max(1, Math.min(Math.trunc(f0 / binHz), count - 1));
    const hi = Math.max(lo, Math.min(Math.trunc(f1 / binHz), count - 1));
    let m = MIN_DB;
    for (let i = lo; i <= hi; ++i) m = Math.max(m, this.spectrumDB[i]);
    return m;
  }
}

/** A scrolling spectrogram image with log frequency on the vertical axis. */
export class SpectrogramBuffer {
  /** RGBA pixels, width columns used as a ring buffer. Row 0 is the top (highest frequency). */
  readonly pixels: Uint32Array;
  /** the column that will be written next; the oldest column. */
  nextColumn = 0;
  private colors: Uint32Array;
  private rowBins: [number, number][] = [];
  private rowBinsSampleRate = 0;
  private image: ImageData | null = null;

  readonly width: number;
  readonly height: number;
  constructor(width: number, height: number) {
    this.width = width;
    this.height = height;
    this.colors = SpectrogramBuffer.makeColorTable();
    this.pixels = new Uint32Array(width * height).fill(this.colors[0]);
  }

  addColumn(spectrumDB: Float32Array, sampleRate: number): void {
    if (this.rowBinsSampleRate !== sampleRate) this.computeRowBins(spectrumDB.length, sampleRate);
    const x = this.nextColumn;
    for (let row = 0; row < this.height; ++row) {
      const [lo, hi] = this.rowBins[row];
      let m = MIN_DB;
      for (let i = lo; i <= hi; ++i) m = Math.max(m, spectrumDB[i]);
      const t = (m - MIN_DB) / -MIN_DB;
      const c = Math.trunc(Math.max(0, Math.min(1, t)) * (this.colors.length - 1));
      this.pixels[row * this.width + x] = this.colors[c];
    }
    this.nextColumn = (this.nextColumn + 1) % this.width;
  }

  private computeRowBins(bins: number, sampleRate: number): void {
    const binHz = sampleRate / FFT_SIZE;
    const fmax = Math.min(sampleRate / 2, 22050);
    const fmin = MIN_FREQUENCY;
    this.rowBins = [];
    for (let row = 0; row < this.height; ++row) {
      const y = this.height - 1 - row; // row 0 is the top
      const f0 = fmin * (fmax / fmin) ** (y / this.height);
      const f1 = fmin * (fmax / fmin) ** ((y + 1) / this.height);
      const lo = Math.max(1, Math.min(Math.trunc(f0 / binHz), bins - 1));
      const hi = Math.max(lo, Math.min(Math.trunc(f1 / binHz), bins - 1));
      this.rowBins.push([lo, hi]);
    }
    this.rowBinsSampleRate = sampleRate;
  }

  /** the image, oldest column on the left. */
  makeImage(): ImageData {
    if (!this.image) this.image = new ImageData(this.width, this.height);
    const out = new Uint32Array(this.image.data.buffer);
    const split = this.nextColumn;
    for (let row = 0; row < this.height; ++row) {
      const s = row * this.width;
      out.set(this.pixels.subarray(s + split, s + this.width), s);
      out.set(this.pixels.subarray(s, s + split), s + this.width - split);
    }
    return this.image;
  }

  /** black through indigo, red and orange to pale yellow. */
  private static makeColorTable(): Uint32Array {
    const stops: [number, number, number, number][] = [
      [0.00, 0.00, 0.00, 0.02],
      [0.25, 0.20, 0.05, 0.45],
      [0.50, 0.70, 0.10, 0.45],
      [0.70, 0.95, 0.40, 0.10],
      [0.88, 1.00, 0.80, 0.25],
      [1.00, 1.00, 1.00, 0.85],
    ];
    const table = new Uint32Array(256);
    const bytes = new Uint8Array(table.buffer);
    for (let i = 0; i < 256; ++i) {
      const t = i / 255;
      let k = 0;
      while (k < stops.length - 2 && t > stops[k + 1][0]) k += 1;
      const a = stops[k];
      const b = stops[k + 1];
      const u = (t - a[0]) / (b[0] - a[0]);
      // bytes in memory order R G B A, as ImageData wants.
      bytes[i * 4] = Math.trunc((a[1] + (b[1] - a[1]) * u) * 255);
      bytes[i * 4 + 1] = Math.trunc((a[2] + (b[2] - a[2]) * u) * 255);
      bytes[i * 4 + 2] = Math.trunc((a[3] + (b[3] - a[3]) * u) * 255);
      bytes[i * 4 + 3] = 255;
    }
    return table;
  }
}
