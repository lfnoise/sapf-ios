//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The waveform, spectrum and spectrogram views. A port of ios/Sapf/Visuals/ScopeViews.swift and WaveformView.swift.
//
// Dragging on them drives mousex and mousey. The waveform shows the live output or a plot of the top of the stack:
// for the output, pinch (or the scroll wheel) zooms from milliseconds to 30 seconds, short spans trigger on a rising
// zero crossing so periodic sounds stand still, and long ones show the amplitude envelope; for a plot, pinch or the
// wheel zooms around the pointer and dragging scrolls. Double-click returns to the default zoom, or fits the plot.

import { MIN_DB, MIN_FREQUENCY, type AnalyzerDisplay, type AudioAnalyzer } from './analyzer.ts';
import type { PlotData } from './engine.ts';

const theme = {
  background: 'rgb(18,18,18)',
  grid: 'rgba(255,255,255,0.09)',
  gridLabel: 'rgba(255,255,255,0.45)',
  trace: 'rgb(89,242,191)',
  fill: 'rgba(89,242,191,0.18)',
  pointer: 'rgb(255,204,0)',
  labelFont: '10px ui-monospace, SFMono-Regular, Menlo, monospace',
  titleFont: '600 11px -apple-system, BlinkMacSystemFont, system-ui, sans-serif',
};

/** Common behavior: redraws on analyzer updates while visible; dragging drives mousex and mousey. */
abstract class ScopeBaseView implements AnalyzerDisplay {
  readonly element: HTMLElement;
  protected canvas: HTMLCanvasElement;
  protected ctx: CanvasRenderingContext2D;
  protected width = 0;
  protected height = 0;
  private pointer: { x: number; y: number } | null = null;
  protected touches = new Map<number, { x: number; y: number }>();

  abstract get title(): string;
  /** whether dragging drives mousex and mousey. */
  get drivesPointer(): boolean { return true; }

  protected analyzer: AudioAnalyzer;
  constructor(analyzer: AudioAnalyzer, label: string) {
    this.analyzer = analyzer;
    this.element = document.createElement('div');
    this.element.className = 'scope';
    this.canvas = document.createElement('canvas');
    this.canvas.setAttribute('role', 'img');
    this.canvas.setAttribute('aria-label', label);
    this.canvas.title = 'Drag to control mousex and mousey.';
    this.element.append(this.canvas);
    this.ctx = this.canvas.getContext('2d')!;
    this.canvas.style.touchAction = 'none';

    // only analyze while on screen.
    new IntersectionObserver(entries => {
      for (const e of entries) {
        if (e.isIntersecting) this.analyzer.add(this); else this.analyzer.remove(this);
      }
    }).observe(this.element);
    new ResizeObserver(() => this.redraw()).observe(this.element);

    this.canvas.addEventListener('pointerdown', e => {
      this.canvas.setPointerCapture(e.pointerId);
      this.touches.set(e.pointerId, { x: e.offsetX, y: e.offsetY });
      this.pointerChanged(e, true);
    });
    this.canvas.addEventListener('pointermove', e => {
      if (!this.touches.has(e.pointerId)) return;
      this.touches.set(e.pointerId, { x: e.offsetX, y: e.offsetY });
      this.pointerChanged(e, true);
    });
    const end = (e: PointerEvent) => {
      if (!this.touches.has(e.pointerId)) return;
      this.touches.delete(e.pointerId);
      this.pointerChanged(e, false);
    };
    this.canvas.addEventListener('pointerup', end);
    this.canvas.addEventListener('pointercancel', end);
  }

  protected pointerChanged(e: PointerEvent, down: boolean): void {
    if (!this.drivesPointer && !this.pointer) return;
    // a second finger means a pinch, not pointing.
    const isDown = down && this.drivesPointer && this.touches.size === 1;
    const x = Math.max(0, Math.min(1, e.offsetX / Math.max(this.width, 1)));
    const y = Math.max(0, Math.min(1, 1 - e.offsetY / Math.max(this.height, 1)));
    this.analyzer.engine.setPointer(x, y, isDown);
    this.pointer = isDown ? { x: e.offsetX, y: e.offsetY } : null;
    this.redraw();
  }

  analyzerDidUpdate(): void {
    this.redraw();
  }

  redraw(): void {
    const dpr = window.devicePixelRatio || 1;
    this.width = this.element.clientWidth;
    this.height = this.element.clientHeight;
    if (this.width === 0 || this.height === 0) return;
    const w = Math.round(this.width * dpr);
    const h = Math.round(this.height * dpr);
    if (this.canvas.width !== w || this.canvas.height !== h) {
      this.canvas.width = w;
      this.canvas.height = h;
    }
    const ctx = this.ctx;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.fillStyle = theme.background;
    ctx.fillRect(0, 0, this.width, this.height);
    this.drawScope(ctx);
    ctx.font = theme.titleFont;
    ctx.fillStyle = theme.gridLabel;
    ctx.textBaseline = 'top';
    ctx.textAlign = 'left';
    ctx.fillText(this.title, 8, 6);
    const p = this.pointer;
    if (p) {
      ctx.strokeStyle = 'rgba(255,204,0,0.6)';
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(p.x, 0); ctx.lineTo(p.x, this.height);
      ctx.moveTo(0, p.y); ctx.lineTo(this.width, p.y);
      ctx.stroke();
      ctx.fillStyle = theme.pointer;
      ctx.beginPath();
      ctx.arc(p.x, p.y, 5, 0, Math.PI * 2);
      ctx.fill();
    }
  }

  protected abstract drawScope(ctx: CanvasRenderingContext2D): void;

  protected drawLabel(text: string, x: number, y: number, alignRight = false): void {
    const ctx = this.ctx;
    ctx.font = theme.labelFont;
    ctx.fillStyle = theme.gridLabel;
    ctx.textBaseline = 'top';
    ctx.textAlign = alignRight ? 'right' : 'left';
    ctx.fillText(text, x, y);
  }
}

// MARK: Spectrum

/** Log frequency magnitude spectrum. */
export class SpectrumView extends ScopeBaseView {
  get title() { return 'Spectrum'; }

  constructor(analyzer: AudioAnalyzer) { super(analyzer, 'Spectrum'); }

  protected drawScope(ctx: CanvasRenderingContext2D): void {
    const w = this.width;
    const h = this.height;
    const fmin = MIN_FREQUENCY;
    const fmax = Math.min(this.analyzer.sampleRate / 2, 22050);
    const xFor = (f: number) => (Math.log(f / fmin) / Math.log(fmax / fmin)) * w;
    const yFor = (db: number) => (db / MIN_DB) * (h - 2) + 1;

    ctx.strokeStyle = theme.grid;
    ctx.lineWidth = 1;
    ctx.beginPath();
    for (let db = -20; db > MIN_DB; db -= 20) {
      const y = yFor(db);
      ctx.moveTo(0, y); ctx.lineTo(w, y);
    }
    for (const f of [50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000]) {
      if (f >= fmax) continue;
      const x = xFor(f);
      ctx.moveTo(x, 0); ctx.lineTo(x, h);
    }
    ctx.stroke();
    for (const f of [100, 1000, 10000]) {
      if (f < fmax) this.drawLabel(f >= 1000 ? `${f / 1000}k` : `${f}`, xFor(f) + 3, h - 14);
    }
    for (let db = -20; db > MIN_DB; db -= 40) this.drawLabel(`${db}`, w - 4, yFor(db) + 1, true);

    const columns = Math.max(Math.trunc(w), 2);
    ctx.beginPath();
    ctx.moveTo(0, h);
    for (let c = 0; c <= columns; ++c) {
      const f0 = fmin * (fmax / fmin) ** (c / columns);
      const f1 = fmin * (fmax / fmin) ** ((c + 1) / columns);
      ctx.lineTo((c * w) / columns, yFor(this.analyzer.level(f0, f1)));
    }
    ctx.lineTo(w, h);
    ctx.closePath();
    ctx.fillStyle = theme.fill;
    ctx.fill();
    ctx.strokeStyle = theme.trace;
    ctx.lineWidth = 1.25;
    ctx.stroke();
  }
}

// MARK: Spectrogram

/** Scrolling spectrogram (sonogram): time left to right, log frequency bottom to top. */
export class SpectrogramView extends ScopeBaseView {
  private offscreen = document.createElement('canvas');

  get title() { return 'Spectrogram'; }

  constructor(analyzer: AudioAnalyzer) {
    super(analyzer, 'Spectrogram');
    this.offscreen.width = analyzer.spectrogram.width;
    this.offscreen.height = analyzer.spectrogram.height;
  }

  protected drawScope(ctx: CanvasRenderingContext2D): void {
    const w = this.width;
    const h = this.height;
    this.offscreen.getContext('2d')!.putImageData(this.analyzer.spectrogram.makeImage(), 0, 0);
    ctx.imageSmoothingEnabled = true;
    ctx.imageSmoothingQuality = 'medium';
    ctx.drawImage(this.offscreen, 0, 0, w, h);

    const fmin = MIN_FREQUENCY;
    const fmax = Math.min(this.analyzer.sampleRate / 2, 22050);
    for (const f of [100, 1000, 10000]) {
      if (f >= fmax) continue;
      const y = h - (Math.log(f / fmin) / Math.log(fmax / fmin)) * h;
      ctx.strokeStyle = theme.grid;
      ctx.beginPath();
      ctx.moveTo(0, y); ctx.lineTo(w, y);
      ctx.stroke();
      this.drawLabel(f >= 1000 ? `${f / 1000}k` : `${f}`, w - 4, y + 1, true);
    }
  }
}

// MARK: Waveform

/** A plot with its summary and value range. */
export class Plot {
  readonly range: { lo: number; hi: number };

  readonly data: PlotData;
  constructor(data: PlotData) {
    this.data = data;
    let lo = Infinity;
    let hi = -Infinity;
    for (const c of data.channels) for (const v of c) { if (v < lo) lo = v; if (v > hi) hi = v; }
    this.range = Number.isFinite(lo) && Number.isFinite(hi) ? { lo, hi } : { lo: -1, hi: 1 };
  }

  /** a short description, e.g. "2 channels, 1.50 s". */
  get summary(): string {
    const d = this.data;
    const channelText = d.channels.length === 1 ? '' : `${d.channels.length} channels, `;
    if (d.isSignal) {
      const seconds = durationText(d.frameCount / d.sampleRate);
      return channelText + (d.truncated ? `first ${seconds} of a longer signal` : seconds);
    }
    return `${d.frameCount} values` + (d.truncated ? ' (truncated)' : '');
  }
}

export function durationText(seconds: number): string {
  if (seconds < 1) return `${(seconds * 1000).toFixed(0)} ms`;
  return seconds < 10 ? `${seconds.toFixed(2)} s` : `${seconds.toFixed(1)} s`;
}

function valueText(v: number): string {
  const a = Math.abs(v);
  return a >= 1000 || (a < 0.01 && v !== 0) ? Number(v.toPrecision(3)).toString() : v.toFixed(3);
}

/** What the waveform views show and how far they're zoomed. Shared, so every waveform view on screen stays in step. */
export class WaveformState {
  static readonly defaultOutputSpan = 2048;
  static readonly minOutputSpan = 128;
  static readonly minPlotSpan = 8;
  // after the constants above, which the constructor uses.
  static readonly shared = new WaveformState();

  source: 'output' | 'plot' = 'output';
  plot: Plot | null = null;
  plotStart = 0;
  plotSpan = 1;
  private _outputSpan: number;
  private listeners = new Set<() => void>();
  maxOutputSpan = 30 * 48000;

  private constructor() {
    const saved = Number(localStorage.getItem('waveformSpan'));
    this._outputSpan = saved > 0 ? saved : WaveformState.defaultOutputSpan;
  }

  /** output: frames across the view, newest at the right edge. */
  get outputSpan(): number { return this._outputSpan; }
  set outputSpan(span: number) {
    this._outputSpan = span;
    try { localStorage.setItem('waveformSpan', String(span)); } catch { /* storage unavailable */ }
    this.changed();
  }

  onChange(listener: () => void): void {
    this.listeners.add(listener);
  }

  show(plot: Plot): void {
    this.plot = plot;
    this.source = 'plot';
    this.fitPlot();
  }

  /** discards the plot and goes back to the output. */
  clearPlot(): void {
    if (!this.plot) return;
    this.plot = null;
    this.source = 'output';
    this.changed();
  }

  setSource(source: 'output' | 'plot'): void {
    if (source === this.source || (source === 'plot' && !this.plot)) return;
    this.source = source;
    this.changed();
  }

  /** from the first frame to the last. */
  private get plotExtent(): number {
    return Math.max((this.plot?.data.frameCount ?? 2) - 1, 1);
  }

  fitPlot(): void {
    this.plotStart = 0;
    this.plotSpan = this.plotExtent;
    this.changed();
  }

  /** sets the visible part of the plot, kept within the plot. */
  setPlotWindow(start: number, span: number): void {
    const total = this.plotExtent;
    this.plotSpan = Math.min(Math.max(span, Math.min(WaveformState.minPlotSpan, total)), total);
    this.plotStart = Math.min(Math.max(start, 0), total - this.plotSpan);
    this.changed();
  }

  private changed(): void {
    for (const l of this.listeners) l();
  }
}

const channelColors = ['rgb(89,242,191)', '#ff9500', '#ff2d55', '#ffcc00', '#32ade6', '#af52de', '#34c759', '#ff3b30'];

type ColumnRange = [number, number];

/** an oscilloscope of the live output, or a plot of the top of the stack. */
export class WaveformView extends ScopeBaseView {
  private state = WaveformState.shared;
  private header: HTMLElement;
  private envelopeMin = new Float32Array(0);
  private envelopeMax = new Float32Array(0);
  private gesture: { start: number; span: number; anchor: number; x0: number; distance: number } | null = null;

  get title() { return this.state.source === 'output' ? 'Waveform' : 'Plot'; }
  get drivesPointer() { return this.state.source === 'output'; }

  constructor(analyzer: AudioAnalyzer) {
    super(analyzer, 'Waveform');
    this.canvas.title = 'Drag to control mousex and mousey. Scroll or pinch to zoom; double-click to reset.';
    this.state.maxOutputSpan = Math.min(analyzer.engine.envelopeBlocks * analyzer.engine.envelopeBlockSize, 30 * analyzer.sampleRate);

    // Output | Plot switch and close button, shown only when there is a plot.
    this.header = document.createElement('div');
    this.header.className = 'scope-switch';
    this.header.innerHTML = `
      <div class="segmented small" role="tablist" aria-label="Waveform source">
        <button type="button" role="tab" data-source="output">Output</button>
        <button type="button" role="tab" data-source="plot">Plot</button>
      </div>
      <button type="button" class="close-plot" aria-label="Close Plot" title="Close Plot">✕</button>`;
    this.element.append(this.header);
    for (const b of this.header.querySelectorAll<HTMLButtonElement>('[data-source]')) {
      b.addEventListener('click', () => this.state.setSource(b.dataset.source as 'output' | 'plot'));
    }
    this.header.querySelector('.close-plot')!.addEventListener('click', () => this.state.clearPlot());

    this.canvas.addEventListener('dblclick', () => {
      if (this.state.source === 'output') this.state.outputSpan = WaveformState.defaultOutputSpan;
      else this.state.fitPlot();
    });
    this.canvas.addEventListener('wheel', e => this.wheel(e), { passive: false });
    this.state.onChange(() => this.stateChanged());
    this.stateChanged();
  }

  private stateChanged(): void {
    this.header.hidden = !this.state.plot;
    for (const b of this.header.querySelectorAll<HTMLButtonElement>('[data-source]')) {
      const selected = b.dataset.source === this.state.source;
      b.classList.toggle('selected', selected);
      b.setAttribute('aria-selected', String(selected));
    }
    this.canvas.style.cursor = this.state.source === 'plot' ? 'grab' : 'crosshair';
    this.redraw();
  }

  // MARK: Gestures

  private wheel(e: WheelEvent): void {
    e.preventDefault();
    const w = Math.max(this.width, 1);
    const factor = Math.exp(e.deltaY * (e.ctrlKey ? 0.01 : 0.002));
    if (this.state.source === 'output') {
      this.state.outputSpan = Math.min(Math.max(this.state.outputSpan * factor, WaveformState.minOutputSpan), this.state.maxOutputSpan);
    } else if (Math.abs(e.deltaX) > Math.abs(e.deltaY) && !e.ctrlKey) {
      this.state.setPlotWindow(this.state.plotStart + (e.deltaX / w) * this.state.plotSpan, this.state.plotSpan);
    } else {
      // keep the frame under the pointer where it is.
      const x = e.offsetX / w;
      const anchor = this.state.plotStart + x * this.state.plotSpan;
      const span = this.state.plotSpan * factor;
      this.state.setPlotWindow(anchor - x * span, span);
    }
  }

  protected pointerChanged(e: PointerEvent, down: boolean): void {
    const w = Math.max(this.width, 1);
    const points = [...this.touches.values()];
    if (points.length >= 2) {
      // pinch
      const [a, b] = points;
      const distance = Math.max(Math.hypot(a.x - b.x, a.y - b.y), 1);
      const center = (a.x + b.x) / 2 / w;
      if (!this.gesture || this.gesture.distance === 0) {
        this.gesture = { start: this.state.plotStart, span: this.state.source === 'output' ? this.state.outputSpan : this.state.plotSpan,
          anchor: this.state.plotStart + center * this.state.plotSpan, x0: center, distance };
      }
      const scale = distance / this.gesture.distance;
      if (this.state.source === 'output') {
        this.state.outputSpan = Math.min(Math.max(this.gesture.span / scale, WaveformState.minOutputSpan), this.state.maxOutputSpan);
      } else {
        const span = this.gesture.span / scale;
        this.state.setPlotWindow(this.gesture.anchor - center * span, span);
      }
      super.pointerChanged(e, false);
      return;
    }
    if (this.state.source === 'plot') {
      // one finger scrolls the plot
      if (down && points.length === 1) {
        if (!this.gesture || this.gesture.distance !== 0) this.gesture = { start: this.state.plotStart, span: this.state.plotSpan, anchor: 0, x0: points[0].x, distance: 0 };
        const dx = (points[0].x - this.gesture.x0) / w;
        this.state.setPlotWindow(this.gesture.start - dx * this.state.plotSpan, this.state.plotSpan);
      } else {
        this.gesture = null;
      }
      return;
    }
    if (!down) this.gesture = null;
    super.pointerChanged(e, down);
  }

  // MARK: Drawing

  private get columnCount(): number {
    return Math.max(Math.trunc(this.width * (window.devicePixelRatio || 1)), 2);
  }

  protected drawScope(ctx: CanvasRenderingContext2D): void {
    const w = this.width;
    const h = this.height;
    ctx.strokeStyle = theme.grid;
    ctx.lineWidth = 1;
    ctx.beginPath();
    for (const f of [0.25, 0.5, 0.75]) { ctx.moveTo(0, h * f); ctx.lineTo(w, h * f); }
    ctx.stroke();
    if (this.state.source === 'output') this.drawOutput(ctx); else this.drawPlot(ctx);
  }

  /** strokes one trace through per-column minimums and maximums, mapping values with y. */
  private drawColumns(ctx: CanvasRenderingContext2D, ranges: ColumnRange[], color: string, y: (v: number) => number): void {
    if (ranges.length === 0) return;
    const dx = this.width / Math.max(ranges.length - 1, 1);
    ctx.beginPath();
    ranges.forEach(([lo, hi], c) => {
      const x = c * dx;
      const y0 = y(hi);
      const y1 = y(lo);
      if (c === 0) ctx.moveTo(x, y0); else ctx.lineTo(x, y0);
      if (y1 - y0 > 1) ctx.lineTo(x, y1);
    });
    ctx.strokeStyle = color;
    ctx.lineWidth = 1.5;
    ctx.lineJoin = 'round';
    ctx.stroke();
  }

  /** minimum and maximum of samples[start ..< start + span] for each pixel column. */
  private columnRanges(samples: Float32Array, start: number, span: number): ColumnRange[] {
    const columns = this.columnCount;
    const perColumn = span / columns;
    const ranges: ColumnRange[] = [];
    for (let c = 0; c < columns; ++c) {
      const a = Math.min(Math.max(Math.trunc(start + c * perColumn), 0), samples.length - 1);
      const b = Math.min(Math.max(a + 1, Math.trunc(start + (c + 1) * perColumn)), samples.length);
      let lo = Infinity;
      let hi = -Infinity;
      for (let i = a; i < b; ++i) { const v = samples[i]; if (v < lo) lo = v; if (v > hi) hi = v; }
      ranges.push([lo, hi]);
    }
    return ranges;
  }

  private drawOutput(ctx: CanvasRenderingContext2D): void {
    const w = this.width;
    const h = this.height;
    const mid = h / 2;
    const span = this.state.outputSpan;
    const history = this.analyzer.history;
    const engine = this.analyzer.engine;
    let ranges: ColumnRange[];

    if (span * 2 <= history.length) {
      // search back from the newest possible start for a rising zero crossing.
      const n = Math.trunc(span);
      let start = history.length - n;
      for (let i = start; i > history.length - 2 * n; --i) {
        if (history[i - 1] <= 0 && history[i] > 0) { start = i; break; }
      }
      ranges = this.columnRanges(history, start, span);
    } else if (span <= history.length) {
      ranges = this.columnRanges(history, history.length - span, span);
    } else {
      // longer than the sample history: use the engine's block minimums and maximums.
      const blocks = Math.min(Math.trunc(span / engine.envelopeBlockSize), engine.envelopeBlocks);
      if (this.envelopeMin.length !== blocks) {
        this.envelopeMin = new Float32Array(blocks);
        this.envelopeMax = new Float32Array(blocks);
      }
      engine.copyOutputEnvelope(this.envelopeMin, this.envelopeMax);
      const columns = this.columnCount;
      const perColumn = blocks / columns;
      ranges = [];
      for (let c = 0; c < columns; ++c) {
        const a = Math.min(Math.trunc(c * perColumn), blocks - 1);
        const b = Math.min(Math.max(a + 1, Math.trunc((c + 1) * perColumn)), blocks);
        let lo = Infinity;
        let hi = -Infinity;
        for (let i = a; i < b; ++i) { lo = Math.min(lo, this.envelopeMin[i]); hi = Math.max(hi, this.envelopeMax[i]); }
        ranges.push([lo, hi]);
      }
    }

    // never clip loud sounds.
    const peak = ranges.reduce((m, [lo, hi]) => Math.max(m, Math.abs(lo), Math.abs(hi)), 0);
    const gain = (peak > 1 ? 1 / peak : 1) * (mid - 4);
    this.drawColumns(ctx, ranges, theme.trace, v => mid - v * gain);

    this.drawLabel(durationText(span / this.analyzer.sampleRate), w - 6, 6, true);
    if (this.analyzer.playingCount > 0) {
      const peakDB = 20 * Math.log10(Math.max(this.analyzer.peak, 1e-6));
      const a = this.analyzer;
      this.drawLabel(`${a.playingCount} playing   peak ${peakDB.toFixed(1)} dB   load ${(a.renderLoad * 100).toFixed(0)}% (max ${(a.maxRenderLoad * 100).toFixed(0)}%)`, 8, h - 32);
      // counted since launch: a dropout is a gap in the output's timeline, a late render one that took
      // longer than its buffer lasts.
      const t = engine.timing(false);
      this.drawLabel(`dropouts ${t.dropouts}   late ${t.lateRenders}`, 8, h - 18);
    }
  }

  private drawPlot(ctx: CanvasRenderingContext2D): void {
    const plot = this.state.plot;
    if (!plot) return;
    const w = this.width;
    const h = this.height;
    const top = 30;
    const bottom = h - 22;

    // scale to the whole plot's range so it doesn't jump around while zooming.
    let lo = plot.range.lo;
    let hi = plot.range.hi;
    if (hi - lo < 1e-9) { lo -= 1; hi += 1; }
    const pad = (hi - lo) * 0.05;
    lo -= pad;
    hi += pad;
    const y = (v: number) => bottom - ((v - lo) / (hi - lo)) * (bottom - top);

    if (lo < 0 && hi > 0) {
      ctx.strokeStyle = 'rgba(255,255,255,0.135)';
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(0, y(0)); ctx.lineTo(w, y(0));
      ctx.stroke();
    }

    const start = this.state.plotStart;
    const span = this.state.plotSpan;
    plot.data.channels.forEach((channel, i) => {
      const color = channelColors[i % channelColors.length];
      if (span <= this.columnCount) {
        // zoomed in: a line through the points.
        const first = Math.max(Math.floor(start), 0);
        const last = Math.min(Math.ceil(start + span), channel.length - 1);
        if (first > last) return;
        ctx.beginPath();
        for (let k = first; k <= last; ++k) {
          const px = ((k - start) / span) * w;
          if (k === first) ctx.moveTo(px, y(channel[k])); else ctx.lineTo(px, y(channel[k]));
        }
        ctx.strokeStyle = color;
        ctx.lineWidth = 1.5;
        ctx.stroke();
      } else {
        this.drawColumns(ctx, this.columnRanges(channel, start, span), color, y);
      }
    });

    this.drawLabel(valueText(hi - pad), w - 6, top - 2, true);
    this.drawLabel(valueText(lo + pad), w - 6, bottom - 12, true);
    const d = plot.data;
    const position = (frame: number) => (d.isSignal ? durationText(frame / d.sampleRate) : String(Math.trunc(frame)));
    this.drawLabel(position(start), 8, h - 16);
    this.drawLabel(position(start + span), w - 6, h - 16, true);
    this.drawLabel(plot.summary, w / 2 - 40, h - 16);
  }
}
