//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

// sapf in the browser. The web counterpart of the iOS app's ContentView and AppModel: the layout, toolbar and
// menus, documents, settings, and running code.

import './style.css';
import { SapfEngine } from './engine.ts';
import { HelpTable } from './help.ts';
import { CodeEditor, type Position, type BlockRun } from './editor.ts';
import { ConsoleBuffer } from './console.ts';
import { AudioAnalyzer } from './analyzer.ts';
import { WaveformView, SpectrumView, SpectrogramView, WaveformState, Plot } from './scopes.ts';
import { DocumentStore, DIRECTORY, RECORDINGS, SPECTROGRAMS, SOUNDS, PRELUDE, LOG, README, TMPDIR, SCRATCH, BUNDLED, RENAMED, GUIDE, title, baseName, extensionOf } from './documents.ts';
import { PreviewDialog, downloadFile } from './preview.ts';
import { showFunctionList } from './functionList.ts';
import { ExampleRunner } from './exampleRunner.ts';
import { showMenu, confirmAction, closeMenu, promptText, showMessage, type MenuEntry } from './menu.ts';
import { WebMidi, type MidiRequest } from './midi.ts';
import { importSound } from './soundImport.ts';

const BASE = import.meta.env.BASE_URL;
const isMac = /Mac|iPhone|iPad/.test(navigator.platform) || navigator.userAgent.includes('Mac');
const mod = isMac ? '⌘' : 'Ctrl+';
const touch = matchMedia('(pointer: coarse)');

type UIMode = 'Auto' | 'Light' | 'Dark';
type PanelTab = 'Console' | 'Scope' | 'Spectrum' | 'Sonogram';
const audioBufferChoices = [256, 512, 1024, 2048];

// MARK: settings, kept in localStorage under the iOS app's UserDefaults keys

function load<T>(key: string, fallback: T): T {
  try {
    const v = localStorage.getItem(key);
    return v === null ? fallback : (JSON.parse(v) as T);
  } catch {
    return fallback;
  }
}

function save(key: string, value: unknown): void {
  try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* storage unavailable */ }
}

const svg = (body: string, size = 22) => `<svg viewBox="0 0 24 24" width="${size}" height="${size}" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${body}</svg>`;
const icons = {
  folder: svg('<path d="M3 6.5A1.5 1.5 0 0 1 4.5 5H9l2 2h8.5A1.5 1.5 0 0 1 21 8.5v9a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 17.5z"/>'),
  keyboard: svg('<rect x="2.5" y="6" width="19" height="12" rx="2"/><path d="M6 10h.01M10 10h.01M14 10h.01M18 10h.01M7 14h10"/>'),
  hideKeyboard: svg('<rect x="2.5" y="3" width="19" height="11" rx="2"/><path d="M6 7h.01M10 7h.01M14 7h.01M18 7h.01M7 10.5h10M9 18l3 3 3-3"/>'),
  run: '<svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true"><path d="M7 4.5v15l12-7.5z" fill="currentColor"/></svg>',
  stop: '<svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true"><rect x="5.5" y="5.5" width="13" height="13" rx="2" fill="currentColor"/></svg>',
  more: svg('<circle cx="12" cy="12" r="9.5"/><circle cx="8" cy="12" r=".6" fill="currentColor"/><circle cx="12" cy="12" r=".6" fill="currentColor"/><circle cx="16" cy="12" r=".6" fill="currentColor"/>'),
  book: svg('<path d="M12 6.5C10 5 7.5 4.5 3.5 4.5v13c4 0 6.5.5 8.5 2 2-1.5 4.5-2 8.5-2v-13c-4 0-6.5.5-8.5 2z"/><path d="M12 6.5v13"/>'),
};

/** what the guide page asks for, in messages posted to this window. */
type GuideMessage =
  | { action: 'run'; code: string; example?: number }
  | { action: 'stopExample'; example: number }
  | { action: 'stop' | 'functions' | 'readme' | 'close' }
  | { action: 'open'; document: string };

class App {
  engine!: SapfEngine;
  documents!: DocumentStore;
  help = new HelpTable();
  console = new ConsoleBuffer();
  editor!: CodeEditor;
  analyzer!: AudioAnalyzer;
  waveform!: WaveformView;
  spectrum!: SpectrumView;
  spectrogram!: SpectrogramView;
  preview!: PreviewDialog;
  runner!: ExampleRunner;
  midi!: WebMidi;

  currentDocument = SCRATCH;
  private documentList: string[] = [];
  private modifiedBuiltIns: string[] = [];
  private positions: Record<string, Position> = load('documentPositions', {});
  private saveTimer = 0;
  private savePending = false;
  private plotCount = 0;
  /** each document's blocks' last runs, for their Stop buttons. */
  private blockRuns = new Map<string, BlockRun[]>();
  /** the tags of the runs of each of the guide's examples, oldest first, by the example's number. */
  private guideRuns = new Map<number, number[]>();
  private guidePlayingKey = '';
  private suppressPreviews = false;
  private params = new URLSearchParams(location.search);

  // settings
  private showsHelpOnTap = load('helpOnTap', true);
  private editorFontSize = load<number>('editorFontSize', matchMedia('(min-width: 700px)').matches ? 16 : 14);
  private audioBufferFrames = load('audioBufferFrames', 1024);
  private uiMode: UIMode = load('uiMode', 'Auto');
  private panelFraction = load('panelFraction', 0.4);
  /** the side panel's share of the width in the wide layout, once its divider has been dragged. */
  private sideFraction = load<number | null>('sideFraction', null);
  /** the scopes' share of the height, above the console in the side panel. */
  private sideScopeFraction = load('sideScopeFraction', 0.5);
  /** the scopes' share of the width, beside the console in the panel below. */
  private rowScopeFraction = load('rowScopeFraction', 0.45);
  private typingScopeHeight = load('typingScopeHeight', 80);
  private panelTab: PanelTab = (sessionStorage.getItem('panelTab') as PanelTab) || 'Console';

  // elements
  private appEl = document.getElementById('app')!;
  private content!: HTMLElement;
  private editorWrap!: HTMLElement;
  private readingBar!: HTMLElement;
  private keyBar!: HTMLElement;
  private divider!: HTMLElement;
  private sideDivider!: HTMLElement;
  private sideScopeDivider!: HTMLElement;
  private rowScopeDivider!: HTMLElement;
  /** the three scopes together, and one view at a time with a picker, for the layouts that show them so. */
  private scopeStackEl = Object.assign(document.createElement('div'), { className: 'scope-stack' });
  private tabbedBox = Object.assign(document.createElement('div'), { className: 'tabbed' });
  private panel!: HTMLElement;
  private titleButton!: HTMLButtonElement;
  private editButton!: HTMLButtonElement;
  private runButton!: HTMLButtonElement;
  private busyIndicator!: HTMLElement;
  private banner!: HTMLElement;
  private tabPicker!: HTMLElement;
  private guidePane!: HTMLElement;
  private guideFrame!: HTMLIFrameElement;

  async start(): Promise<void> {
    this.applyUIMode();
    const status = document.getElementById('loading-text')!;
    status.textContent = 'Loading the sound engine…';
    this.engine = await SapfEngine.load(BASE, {
      SAPF_RECORDINGS: RECORDINGS,
      SAPF_SPECTROGRAMS: SPECTROGRAMS,
      SAPF_SOUNDS: SOUNDS,
      SAPF_TMPDIR: TMPDIR,
      SAPF_PRELUDE: PRELUDE,
      SAPF_LOG: LOG,
      SAPF_README: README,
      SAPF_EXAMPLES: BUNDLED[0][0],
      HOME: DIRECTORY,
    });
    // relative paths in sapf code (e.g. for sound files) are relative to the documents folder.
    status.textContent = 'Loading your documents…';
    this.documents = new DocumentStore(this.engine.module, BASE);
    await this.documents.setUp();
    this.followRenamedDocuments();
    try { (this.engine.module.FS as unknown as { chdir(p: string): void }).chdir(DIRECTORY); } catch { /* not fatal */ }

    this.analyzer = new AudioAnalyzer(this.engine);
    this.buildUI();
    this.connectEngine();
    this.watchPlayingTags();
    const hint = this.audioBufferFrames <= 256 ? 'interactive' : this.audioBufferFrames >= 2048 ? 'playback' : 'balanced';
    const started = this.engine.start(PRELUDE, hint);
    if (this.params.has('mute')) this.engine.muted = true;
    this.installAudioUnlock();

    this.refreshDocuments();
    const requested = this.params.get('currentDocument');
    const saved = `${DIRECTORY}/${requested ?? load('currentDocument', baseName(SCRATCH))}`;
    this.loadDocument(this.documents.exists(saved) ? saved : SCRATCH);

    await started;
    this.layout();
    // the first time, open the guide, unless launched to do something else.
    if (!load('guideShown', false) && !this.params.has('evaluate') && !this.params.has('runExamples')) this.showGuide();
    void this.handleLaunchParameters();
  }

  // MARK: window

  private buildUI(): void {
    this.appEl.replaceChildren();
    this.preview = new PreviewDialog(this.documents, path => this.loadDocument(path));
    this.editor = new CodeEditor(this.help, {
      evaluate: (code, tag) => this.evaluate(code, tag),
      newTag: () => this.engine.newPlayTag(),
      stopTag: tag => this.engine.stopTag(tag),
      stop: () => this.stop(),
      plot: () => void this.plotTopOfStack(),
      describeWord: word => this.engine.describeWord(word),
      textChanged: () => this.scheduleSave(),
    }, {
      fontSize: this.editorFontSize,
      // on a phone the keyboard covers most of the screen, so start out reading.
      isEditing: !(touch.matches && matchMedia('(max-width: 700px)').matches),
      showsHelpOnTap: this.showsHelpOnTap,
    });
    this.editor.onEditingEnded = () => this.setEditing(false);

    this.waveform = new WaveformView(this.analyzer);
    this.spectrum = new SpectrumView(this.analyzer);
    this.spectrogram = new SpectrogramView(this.analyzer);

    const toolbar = this.buildToolbar();
    this.content = document.createElement('main');
    this.content.className = 'content';

    this.editorWrap = document.createElement('div');
    this.editorWrap.className = 'editor-wrap';
    this.readingBar = this.editor.makeBar(false);
    this.guidePane = this.buildGuidePane();
    this.editorWrap.append(this.editor.element, this.readingBar, this.guidePane);
    this.keyBar = this.editor.makeBar(true);
    this.keyBar.hidden = true;
    document.body.append(this.keyBar);

    this.divider = this.buildDivider();
    this.buildWideDividers();
    this.panel = document.createElement('div');
    this.panel.className = 'panel';
    this.tabPicker = this.buildTabPicker();

    this.banner = document.createElement('div');
    this.banner.className = 'runner-banner';
    this.banner.hidden = true;
    this.banner.setAttribute('role', 'status');
    this.banner.innerHTML = '<span class="spinner"></span><span class="runner-status"></span><button type="button" class="text-button">Cancel</button>';
    this.banner.querySelector('button')!.addEventListener('click', () => this.runner.cancel());

    this.appEl.append(toolbar, this.content, this.banner);
    this.content.append(this.editorWrap);

    this.runner = new ExampleRunner({
      engine: this.engine,
      console: this.console,
      documents: this.documents,
      assetBase: BASE,
      stop: () => this.stop(),
      setStatus: s => { this.banner.hidden = s === null; this.banner.querySelector('.runner-status')!.textContent = s ?? ''; },
      setSuppressPreviews: s => { this.suppressPreviews = s; if (s) this.preview.close(); },
    });

    new ResizeObserver(() => this.layout()).observe(this.appEl);
    window.visualViewport?.addEventListener('resize', () => this.layout());
    window.visualViewport?.addEventListener('scroll', () => this.positionKeyBar());
    this.editor.view.contentDOM.addEventListener('focus', () => this.updateKeyBar());
    this.editor.view.contentDOM.addEventListener('blur', () => setTimeout(() => this.updateKeyBar(), 0));
    touch.addEventListener('change', () => this.updateEditingUI());
    WaveformState.shared.onChange(() => this.updateTabPicker());
    this.installShortcuts();
    this.installSoundFileDrop();
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'hidden') { this.saveNow(); this.rememberPosition(); void this.documents.syncNow(); }
      else { this.refreshDocuments(); void this.resumeAudioIfInterrupted(); }
    });
    window.addEventListener('pagehide', () => { this.saveNow(); this.rememberPosition(); });
    this.updateEditingUI();
  }

  private buildToolbar(): HTMLElement {
    const bar = document.createElement('header');
    bar.className = 'toolbar';
    const button = (cls: string, label: string, html: string, action: (b: HTMLButtonElement) => void, shortcut = '') => {
      const b = document.createElement('button');
      b.type = 'button';
      b.className = `tool-button ${cls}`;
      b.title = shortcut ? `${label} (${shortcut})` : label;
      b.setAttribute('aria-label', label);
      b.innerHTML = html;
      b.addEventListener('click', () => action(b));
      return b;
    };
    const documents = button('documents', 'Documents', icons.folder, b => showMenu(b, this.documentMenu(), 'Documents'));
    documents.setAttribute('aria-haspopup', 'menu');
    const guide = button('guide', 'Guide', icons.book, () => this.guidePane.hidden ? this.showGuide() : this.closeGuide());
    this.editButton = button('edit-toggle', 'Edit', icons.keyboard, () => this.setEditing(!this.editor.isEditing));
    this.titleButton = document.createElement('button');
    this.titleButton.type = 'button';
    this.titleButton.className = 'toolbar-title';
    this.titleButton.setAttribute('aria-haspopup', 'menu');
    this.titleButton.addEventListener('click', () => showMenu(this.titleButton, this.documentMenu(), 'Documents'));
    this.busyIndicator = document.createElement('span');
    this.busyIndicator.className = 'spinner';
    this.busyIndicator.setAttribute('role', 'status');
    this.busyIndicator.setAttribute('aria-label', 'Evaluating');
    this.busyIndicator.hidden = true;
    this.runButton = button('run', 'Run', icons.run, () => this.editor.evaluate(true), `${mod}Return`);
    const stop = button('stop', 'Stop', icons.stop, () => this.stop(), `${mod}.`);
    const more = button('more', 'More', icons.more, b => showMenu(b, this.moreMenu(), 'More'));
    more.setAttribute('aria-haspopup', 'menu');

    const leading = document.createElement('div');
    leading.className = 'toolbar-group';
    leading.append(documents, guide, this.editButton);
    const trailing = document.createElement('div');
    trailing.className = 'toolbar-group trailing';
    trailing.append(this.busyIndicator, this.runButton, stop, more);
    bar.append(leading, this.titleButton, trailing);
    return bar;
  }

  private documentMenu(): MenuEntry[] {
    const entries: MenuEntry[] = [
      { label: 'New Document', action: () => this.newDocument() },
      { label: 'Open…', action: () => this.chooseDocumentFiles() },
      { label: 'Rename…', disabled: !this.documents.canRename(this.currentDocument), action: () => void this.renameDocument() },
      { label: 'Download', action: () => this.downloadDocument() },
      'separator',
      { label: 'Log', action: () => this.showLog() },
      { label: 'Import Sound Files…', action: () => this.chooseSoundFiles() },
    ];
    if (this.modifiedBuiltIns.includes(this.currentDocument)) {
      entries.push({ label: 'Revert to Original…', destructive: true, action: () => void this.confirmRevert([this.currentDocument], false) });
    }
    if (this.modifiedBuiltIns.length) {
      entries.push({ label: 'Revert All Built-in Files…', destructive: true, action: () => void this.confirmRevert(this.modifiedBuiltIns, true) });
    }
    entries.push('separator');
    for (const path of this.documentList) {
      entries.push({ label: title(path), checked: path === this.currentDocument, action: () => this.loadDocument(path) });
    }
    return entries;
  }

  private moreMenu(): MenuEntry[] {
    const compact = this.isCompact();
    const rate = Math.max(this.engine.sampleRate, 8000);
    const entries: MenuEntry[] = [];
    if (compact) entries.push({ label: 'Run', shortcut: `${mod}↩`, action: () => this.editor.evaluate(true) });
    entries.push(
      { label: 'Help on Tap', checked: this.showsHelpOnTap, action: () => this.setHelpOnTap(!this.showsHelpOnTap) },
      'separator',
      // not Cmd-+ and Cmd--: in a browser those zoom the page, which people rely on.
      { label: 'Bigger Text', action: () => this.setFontSize(this.editorFontSize + 1) },
      { label: 'Smaller Text', action: () => this.setFontSize(this.editorFontSize - 1) },
      'separator',
      { caption: 'UI Mode' },
      ...(['Auto', 'Light', 'Dark'] as UIMode[]).map(m => ({ label: m, checked: this.uiMode === m, action: () => this.setUIMode(m) })),
      'separator',
      { caption: 'Audio Buffer' },
      ...audioBufferChoices.map(frames => ({
        label: `${frames} frames (${Math.round((frames / rate) * 1000)} ms)`,
        checked: this.audioBufferFrames === frames,
        action: () => this.setAudioBufferFrames(frames),
      })),
      'separator',
      { label: 'Find', shortcut: `${mod}F`, action: () => this.editor.showFind() },
      { label: 'Plot Top of Stack', shortcut: `⇧${mod}P`, action: () => void this.plotTopOfStack() },
      'separator',
      { label: 'Guide', action: () => this.showGuide() },
      { label: 'README', action: () => this.preview.show(README) },
      { label: 'List All Functions', action: () => showFunctionList(this.help.allHelpText()) },
      { label: 'Clear Stack', action: () => void this.clearStack() },
      { label: 'Clear Console', action: () => this.console.clear() },
      { label: 'Run All Examples', disabled: this.runner.isRunning, action: () => void this.runner.run() },
      'separator',
      { caption: `sapf ${this.engine.version} · ${Math.round(this.engine.sampleRate)} Hz` },
    );
    return entries;
  }

  // MARK: the guide

  /**
   * The guide pane, over the editor: a bar with Done, and the guide page in a frame, loaded when first shown. The
   * toolbar, with Stop, and the console and scopes stay in view.
   */
  private buildGuidePane(): HTMLElement {
    const pane = document.createElement('section');
    pane.className = 'guide-pane';
    pane.hidden = true;
    pane.setAttribute('aria-label', 'Guide');
    pane.innerHTML = '<div class="guide-bar"><span class="guide-title">sapf Guide</span><button type="button" class="text-button bold">Done</button></div>';
    pane.querySelector('.text-button')!.addEventListener('click', () => this.closeGuide());
    this.guideFrame = document.createElement('iframe');
    this.guideFrame.title = 'sapf Guide';
    pane.append(this.guideFrame);
    window.addEventListener('message', e => {
      if (e.source !== this.guideFrame.contentWindow || e.origin !== location.origin) return;
      const m = (e.data as { sapfGuide?: GuideMessage } | null)?.sapfGuide;
      if (m) this.guideAsked(m);
    });
    return pane;
  }

  showGuide(): void {
    closeMenu();
    if (!this.guideFrame.src) {
      const theme = this.uiMode === 'Auto' ? '' : `&theme=${this.uiMode.toLowerCase()}`;
      this.guideFrame.src = `${BASE}sapf/${GUIDE}?platform=web${theme}`;
    }
    this.editor.hideTooltip();
    this.editor.blur();
    this.guidePane.hidden = false;
    save('guideShown', true);
  }

  closeGuide(): void {
    this.guidePane.hidden = true;
  }

  /** tells the guide which of its examples are playing, so it shows their Stop buttons. */
  private setGuidePlaying(examples: number[]): void {
    const page = this.guideFrame.contentWindow as (Window & { sapfSetPlaying?: (examples: number[]) => void }) | null;
    try { page?.sapfSetPlaying?.(examples); } catch { /* not loaded yet */ }
  }

  private guideAsked(m: GuideMessage): void {
    switch (m.action) {
      case 'run': {
        if (typeof m.code !== 'string') break;
        // tagged, so the example's own Stop button stops just its sound.
        const tag = this.engine.newPlayTag();
        if (typeof m.example === 'number') this.guideRuns.set(m.example, [...(this.guideRuns.get(m.example) ?? []), tag]);
        this.evaluate(m.code, tag);
        break;
      }
      case 'stopExample': {
        // the latest run still playing: pressing Stop again and again stops them last in, first out.
        const playing = this.engine.playingTags();
        const tag = (this.guideRuns.get(m.example) ?? []).findLast(t => playing.has(t));
        if (tag) this.engine.stopTag(tag);
        // the guide hides its Stop button; show it again now if earlier runs are still playing.
        const more = (this.guideRuns.get(m.example) ?? []).some(t => t !== tag && playing.has(t));
        if (more) { this.guidePlayingKey = ''; }
        break;
      }
      case 'stop': this.stop(); break;
      case 'functions': showFunctionList(this.help.allHelpText()); break;
      case 'readme': this.preview.show(README); break;
      case 'close': this.closeGuide(); break;
      case 'open': {
        const path = this.documents.list().find(p => title(p) === m.document);
        if (path) { this.closeGuide(); this.loadDocument(path); }
        break;
      }
    }
  }

  /**
   * A divider to drag, or move with the arrow keys. A vertical one stands between things side by side. Moving it by
   * d pixels (right or down) makes the thing it sizes sign * d bigger: size() measures that thing, resize() sets it.
   */
  private makeDivider(label: string, options: { vertical?: boolean; inner?: boolean; sign: 1 | -1; size: () => number; resize: (px: number) => void }): HTMLElement {
    const { vertical = false, inner = false, sign, size, resize } = options;
    const d = document.createElement('div');
    d.className = 'panel-divider' + (vertical ? ' vertical' : '') + (inner ? ' inner' : '');
    d.setAttribute('role', 'separator');
    d.setAttribute('aria-label', label);
    d.setAttribute('aria-orientation', vertical ? 'vertical' : 'horizontal');
    d.tabIndex = 0;
    d.innerHTML = '<span class="grip"></span>';
    const at = (e: PointerEvent) => (vertical ? e.clientX : e.clientY);
    let start = 0;
    let startSize = 0;
    d.addEventListener('pointerdown', e => {
      d.setPointerCapture(e.pointerId);
      start = at(e);
      startSize = size();
    });
    d.addEventListener('pointermove', e => {
      if (!d.hasPointerCapture(e.pointerId)) return;
      resize(startSize + sign * (at(e) - start));
    });
    d.addEventListener('keydown', e => {
      const keys: Record<string, number> = vertical ? { ArrowLeft: -40, ArrowRight: 40 } : { ArrowUp: -40, ArrowDown: 40 };
      const step = keys[e.key];
      if (step === undefined) return;
      e.preventDefault();
      resize(size() + sign * step);
    });
    return d;
  }

  /** the divider above the panel when it's below the editor. */
  private buildDivider(): HTMLElement {
    return this.makeDivider('Panel size', { sign: -1, size: () => this.panel.getBoundingClientRect().height, resize: h => this.setPanelHeight(h) });
  }

  /**
   * The wide layout's dividers: between the editor and the panel at the side, and between the scopes and the console
   * in it. And, when the panel is below, between the console and the scopes beside it.
   */
  private buildWideDividers(): void {
    const fraction = (px: number, min: number, total: number, reserve: number) => Math.min(Math.max(px, min), Math.max(min, total - reserve)) / total;
    this.sideDivider = this.makeDivider('Side panel width', {
      vertical: true,
      sign: -1,
      size: () => this.panel.getBoundingClientRect().width,
      resize: w => { this.sideFraction = fraction(w, 260, this.metrics().width, 320); save('sideFraction', this.sideFraction); this.layout(); },
    });
    this.sideScopeDivider = this.makeDivider('Scopes height', {
      inner: true,
      sign: 1,
      size: () => this.scopeStackEl.getBoundingClientRect().height ?? 0,
      resize: h => { this.sideScopeFraction = fraction(h, 120, this.metrics().height, 120); save('sideScopeFraction', this.sideScopeFraction); this.layout(); },
    });
    this.rowScopeDivider = this.makeDivider('Scopes width', {
      vertical: true,
      inner: true,
      sign: -1,
      size: () => this.scopeStackEl.getBoundingClientRect().width ?? 0,
      resize: w => { this.rowScopeFraction = fraction(w, 200, this.metrics().width, 200); save('rowScopeFraction', this.rowScopeFraction); this.layout(); },
    });
  }

  /** dragging the divider: the panel's share of the height, or the waveform's height while typing on a phone. */
  private setPanelHeight(h: number): void {
    const { height, typing } = this.metrics();
    if (typing) {
      this.typingScopeHeight = Math.min(Math.max(h, 40), Math.max(40, height * 0.6));
      save('typingScopeHeight', this.typingScopeHeight);
    } else {
      const clamped = Math.min(Math.max(h, 120), Math.max(120, height - 140));
      this.panelFraction = clamped / height;
      save('panelFraction', this.panelFraction);
    }
    this.layout();
  }

  private buildTabPicker(): HTMLElement {
    const picker = document.createElement('div');
    picker.className = 'tabbed-picker';
    picker.innerHTML = `<div class="segmented" role="tablist" aria-label="Panel">${
      (['Console', 'Scope', 'Spectrum', 'Sonogram'] as PanelTab[]).map(t => `<button type="button" role="tab" data-tab="${t}">${t}</button>`).join('')}</div>`;
    for (const b of picker.querySelectorAll<HTMLButtonElement>('[data-tab]')) {
      b.addEventListener('click', () => {
        this.panelTab = b.dataset.tab as PanelTab;
        sessionStorage.setItem('panelTab', this.panelTab);
        this.layout();
      });
    }
    return picker;
  }

  private updateTabPicker(): void {
    for (const b of this.tabPicker.querySelectorAll<HTMLButtonElement>('[data-tab]')) {
      const selected = b.dataset.tab === this.panelTab;
      b.classList.toggle('selected', selected);
      b.setAttribute('aria-selected', String(selected));
    }
  }

  private isCompact(): boolean {
    return window.innerWidth < 700;
  }

  /** the content area's size, how much the on-screen keyboard covers, and whether we're typing on a phone. */
  private metrics() {
    const rect = this.content.getBoundingClientRect();
    const vv = window.visualViewport;
    const keyboard = vv && touch.matches ? Math.max(0, window.innerHeight - (vv.height + vv.offsetTop)) : 0;
    const width = rect.width;
    const height = Math.max(rect.height - keyboard, 1);
    const wide = width > rect.height * 1.15 && width >= 640;
    const typing = !wide && width < 600 && keyboard > 120;
    return { width, height, keyboard, wide, typing };
  }

  /**
   * Arranges the editor and the panels for the space, as the iOS app does. The editor element stays first in the
   * content area throughout, so changing layouts doesn't take the keyboard away.
   */
  layout(): void {
    if (!this.content) return;
    const { width, height, keyboard, wide, typing } = this.metrics();
    this.content.style.paddingBottom = `${keyboard}px`;
    this.content.classList.toggle('wide', wide);
    this.titleButton.textContent = title(this.currentDocument);
    this.runButton.hidden = this.isCompact();
    const keep = [this.editorWrap];

    // Elements already in place are left there, not removed and put back: that would end a drag of a divider, and
    // lose the keyboard. So the scope stack and the tabbed box are made once and reused.
    const setChildren = (parent: HTMLElement, children: HTMLElement[]) => {
      const current = parent.children;
      if (current.length === children.length && children.every((c, i) => current[i] === c)) return;
      parent.replaceChildren(...children);
    };
    const tabbed = (): HTMLElement => {
      const view = { Console: this.console.element, Scope: this.waveform.element, Spectrum: this.spectrum.element, Sonogram: this.spectrogram.element }[this.panelTab];
      setChildren(this.tabbedBox, [this.tabPicker, view]);
      this.updateTabPicker();
      return this.tabbedBox;
    };
    const scopeStack = (): HTMLElement => {
      setChildren(this.scopeStackEl, [this.waveform.element, this.spectrum.element, this.spectrogram.element]);
      this.scopeStackEl.style.width = '';
      this.scopeStackEl.style.height = '';
      return this.scopeStackEl;
    };
    const clamp = (v: number, min: number, max: number) => Math.min(Math.max(v, min), Math.max(min, max));

    this.panel.className = 'panel';
    this.panel.style.width = '';
    this.panel.style.height = '';
    if (wide) {
      this.panel.classList.add('side');
      // until you drag its divider, as wide as the iOS app's.
      const side = this.sideFraction === null ? Math.min(Math.max(300, width * 0.38), 520) : this.sideFraction * width;
      this.panel.style.width = `${clamp(side, 260, width - 320)}px`;
      if (height >= 600) {
        const stack = scopeStack();
        stack.style.height = `${clamp(this.sideScopeFraction * height, 120, height - 120)}px`;
        setChildren(this.panel, [stack, this.sideScopeDivider, this.console.element]);
      } else {
        setChildren(this.panel, [tabbed()]);
      }
      setChildren(this.content, [...keep, this.sideDivider, this.panel]);
    } else if (typing) {
      // typing on a phone: keep a small live waveform so you can still see what's playing.
      const h = Math.min(Math.max(this.typingScopeHeight, 40), Math.max(40, height * 0.6));
      this.panel.style.height = `${h}px`;
      setChildren(this.panel, [this.waveform.element]);
      setChildren(this.content, [...keep, this.divider, this.panel]);
    } else {
      const panelHeight = Math.min(Math.max(this.panelFraction * height, 120), Math.max(120, height - 140));
      this.panel.style.height = `${panelHeight}px`;
      if (width >= 600) {
        this.panel.classList.add('row');
        const stack = scopeStack();
        stack.style.width = `${clamp(this.rowScopeFraction * width, 200, width - 200)}px`;
        setChildren(this.panel, [this.console.element, this.rowScopeDivider, stack]);
      } else {
        setChildren(this.panel, [tabbed()]);
      }
      setChildren(this.content, [...keep, this.divider, this.panel]);
    }
    this.positionKeyBar();
  }

  // MARK: editing and reading

  private setEditing(editing: boolean): void {
    this.editor.isEditing = editing;
    if (editing) this.editor.focus(); else this.editor.blur();
    this.updateEditingUI();
  }

  private updateEditingUI(): void {
    const editing = this.editor.isEditing;
    // reading mode is for touch screens, where editing brings up the keyboard.
    this.editButton.hidden = !touch.matches;
    this.editButton.innerHTML = editing ? icons.hideKeyboard : icons.keyboard;
    this.editButton.setAttribute('aria-label', editing ? 'Hide keyboard' : 'Edit');
    this.editButton.title = editing ? 'Hide keyboard' : 'Edit';
    this.readingBar.hidden = editing || !touch.matches;
    this.updateKeyBar();
  }

  private updateKeyBar(): void {
    this.keyBar.hidden = !(touch.matches && this.editor.isEditing && this.editor.view.hasFocus);
    this.positionKeyBar();
  }

  private positionKeyBar(): void {
    const vv = window.visualViewport;
    if (this.keyBar.hidden || !vv) return;
    this.keyBar.style.top = `${vv.offsetTop + vv.height - this.keyBar.offsetHeight}px`;
  }

  // MARK: settings

  private setHelpOnTap(on: boolean): void {
    this.showsHelpOnTap = on;
    this.editor.showsHelpOnTap = on;
    if (!on) this.editor.hideTooltip();
    save('helpOnTap', on);
  }

  private setFontSize(size: number): void {
    this.editorFontSize = Math.min(Math.max(size, 9), 32);
    this.editor.fontSize = this.editorFontSize;
    save('editorFontSize', this.editorFontSize);
  }

  private setUIMode(mode: UIMode): void {
    this.uiMode = mode;
    save('uiMode', mode);
    this.applyUIMode();
  }

  private applyUIMode(): void {
    // the guide, if it's loaded, follows too.
    for (const root of [document.documentElement, this.guideFrame?.contentDocument?.documentElement]) {
      if (!root) continue;
      if (this.uiMode === 'Auto') root.removeAttribute('data-theme');
      else root.dataset.theme = this.uiMode.toLowerCase();
    }
  }

  /** a browser picks its own audio buffer; this asks for a latency to match, which takes effect on reload. */
  private setAudioBufferFrames(frames: number): void {
    if (frames === this.audioBufferFrames) return;
    this.audioBufferFrames = frames;
    save('audioBufferFrames', frames);
    this.console.append('The audio buffer setting takes effect the next time sapf starts.\n');
  }

  // MARK: documents

  /** the saved current document and positions refer to documents by name, so follow built-ins that were renamed. */
  private followRenamedDocuments(): void {
    let changed = false;
    for (const [from, to] of Object.entries(RENAMED)) {
      if (load('currentDocument', '') === from) save('currentDocument', to);
      if (this.positions[from] && !this.positions[to]) {
        this.positions[to] = this.positions[from];
        delete this.positions[from];
        changed = true;
      }
    }
    if (changed) save('documentPositions', this.positions);
  }

  refreshDocuments(): void {
    this.documentList = this.documents.list();
    this.modifiedBuiltIns = this.documents.modifiedBuiltIns();
  }

  loadDocument(path: string): void {
    this.saveNow();
    this.rememberPosition();
    let text = '';
    try { text = this.documents.readText(path); } catch { /* missing: empty */ }
    this.blockRuns.set(this.currentDocument, this.editor.blockRuns);
    this.currentDocument = path;
    save('currentDocument', baseName(path));
    this.editor.setText(text, this.blockRuns.get(path));
    const position = this.positions[baseName(path)];
    if (position) this.editor.restore(position);
    this.refreshDocuments();
    this.layout();
    document.title = `${title(path)} – sapf`;
  }

  /** notes where you are in the current document, to return there next time it's opened. */
  private rememberPosition(): void {
    if (!this.editor) return;
    this.positions[baseName(this.currentDocument)] = this.editor.position;
    save('documentPositions', this.positions);
  }

  private newDocument(): void {
    const path = this.documents.newDocumentPath();
    this.documents.writeText(path, '');
    this.loadDocument(path);
    this.setEditing(true);
  }

  /** renames the current document. Scratch and the built-in documents keep their names. */
  private async renameDocument(): Promise<void> {
    const from = this.currentDocument;
    if (!this.documents.canRename(from)) return;
    const typed = await promptText(`Rename “${title(from)}”`, title(from), 'Rename');
    if (typed === null) return;
    let name = typed.trim();
    let extension = extensionOf(from) || 'sapf';
    const typedExtension = /\.(sapf|txt)$/i.exec(name);
    if (typedExtension) {
      extension = typedExtension[1].toLowerCase();
      name = name.slice(0, -typedExtension[0].length).trim();
    }
    if (!name || name.includes('/') || name.startsWith('.')) {
      showMessage('Can\'t use that name', 'A name can\'t be empty, contain “/”, or start with “.”.');
      return;
    }
    const to = `${DIRECTORY}/${name}.${extension}`;
    if (to === from || this.currentDocument !== from) return;
    if (this.documents.exists(to) || to === LOG) {
      showMessage('That name is taken', `There's already a document called “${name}”.`);
      return;
    }
    this.saveNow();
    this.documents.rename(from, to);
    const [oldKey, newKey] = [baseName(from), baseName(to)];
    if (this.positions[oldKey]) {
      this.positions[newKey] = this.positions[oldKey];
      delete this.positions[oldKey];
      save('documentPositions', this.positions);
    }
    const runs = this.blockRuns.get(from);
    if (runs) { this.blockRuns.delete(from); this.blockRuns.set(to, runs); }
    this.currentDocument = to;
    save('currentDocument', newKey);
    document.title = `${title(to)} – sapf`;
    this.refreshDocuments();
    this.layout();
  }

  /** saves the current document to the browser's downloads. */
  private downloadDocument(): void {
    this.saveNow();
    downloadFile(this.documents, this.currentDocument);
  }

  /** asks for documents to open. */
  private chooseDocumentFiles(): void {
    const input = document.createElement('input');
    input.type = 'file';
    input.multiple = true;
    input.accept = '.sapf,.txt,text/plain';
    input.addEventListener('change', () => void this.openDocumentFiles([...(input.files ?? [])]));
    input.click();
  }

  /**
   * copies documents from disk into the documents folder and opens the last. One with a name already taken gets a
   * number added, unless it's the same text, when the one there is opened.
   */
  private async openDocumentFiles(files: File[]): Promise<void> {
    let last: string | null = null;
    for (const file of files) {
      let text: string;
      try { text = await file.text(); } catch {
        this.console.append(`could not read ${file.name}\n`);
        continue;
      }
      const name = title(file.name).replaceAll('/', '-') || 'Untitled';
      const extension = extensionOf(file.name).toLowerCase() === 'txt' ? 'txt' : 'sapf';
      const same = `${DIRECTORY}/${name}.${extension}`;
      if (same !== LOG && this.documents.exists(same) && this.documents.readText(same) === text) {
        last = same;
        continue;
      }
      let path = this.documents.unusedPath(name, extension);
      if (path === LOG) path = this.documents.unusedPath(`${name} 2`, extension);
      this.documents.writeText(path, text);
      last = path;
    }
    if (!last) return;
    await this.documents.syncNow();
    this.loadDocument(last);
  }

  private scheduleSave(): void {
    this.savePending = true;
    window.clearTimeout(this.saveTimer);
    this.saveTimer = window.setTimeout(() => this.saveNow(), 1000);
  }

  saveNow(): void {
    if (!this.savePending) return;
    window.clearTimeout(this.saveTimer);
    this.savePending = false;
    this.documents.writeText(this.currentDocument, this.editor.text);
    if (this.documents.bundledResource(this.currentDocument)) this.modifiedBuiltIns = this.documents.modifiedBuiltIns();
  }

  private async confirmRevert(paths: string[], all: boolean): Promise<void> {
    const names = paths.map(title).sort().join(', ');
    const heading = all ? `Revert ${names} to the originals?` : `Revert ${names} to the original?`;
    if (!(await confirmAction(heading, 'Your changes will be lost.', 'Revert', true))) return;
    for (const path of paths) this.revertToOriginal(path);
  }

  /** puts a built-in document back the way it came. Edits to it are lost. */
  private revertToOriginal(path: string): void {
    const resource = this.documents.bundledResource(path);
    if (!resource) return;
    const current = path === this.currentDocument;
    if (current) {
      // drop any unsaved edits, or loading would save them over the original.
      window.clearTimeout(this.saveTimer);
      this.savePending = false;
    }
    this.documents.restoreOriginal(path, resource);
    if (current) this.loadDocument(path);
    if (path === PRELUDE) {
      this.console.append("Prelude.sapf reverted. It's loaded when sapf starts, so the change takes effect next launch.\n");
    }
    this.refreshDocuments();
  }

  /** shows the log of everything run, read-only. */
  private showLog(): void {
    if (!this.documents.exists(LOG)) this.documents.writeText(LOG, '');
    this.preview.show(LOG);
  }

  /** sapf wants to show a file: documents open in the editor; anything else in the preview. */
  private open(path: string): void {
    this.documents.scheduleSync();
    if (path === LOG) {
      this.showLog();
    } else if (['sapf', 'txt'].includes(extensionOf(path)) && this.documents.isInDocuments(path)) {
      this.loadDocument(path);
    } else if (!this.suppressPreviews) {
      this.preview.show(path);
    }
  }

  // MARK: sound files

  /** asks for sound files to import. */
  private chooseSoundFiles(): void {
    const input = document.createElement('input');
    input.type = 'file';
    input.multiple = true;
    input.accept = 'audio/*,.wav,.wave,.aif,.aiff,.aifc,.caf,.flac,.mp3,.m4a,.aac,.ogg,.oga,.opus,.webm';
    input.addEventListener('change', () => void this.importSoundFiles([...(input.files ?? [])]));
    input.click();
  }

  /** sound files dropped anywhere on the window are imported, and documents opened (rather than typed into the editor). */
  private installSoundFileDrop(): void {
    const isSound = (f: File) => f.type.startsWith('audio/') || /\.(wave?|aiff?|aifc|caf|flac|mp3|m4a|aac|ogg|oga|opus)$/i.test(f.name);
    const hasFiles = (e: DragEvent) => !!e.dataTransfer && [...e.dataTransfer.types].includes('Files');
    document.addEventListener('dragover', e => {
      if (!hasFiles(e)) return;
      e.preventDefault();
      e.dataTransfer!.dropEffect = 'copy';
    }, true);
    document.addEventListener('drop', e => {
      if (!hasFiles(e)) return;
      const files = [...e.dataTransfer!.files];
      const sounds = files.filter(isSound);
      const docs = files.filter(f => /\.(sapf|txt)$/i.test(f.name));
      e.preventDefault();
      e.stopPropagation();
      if (sounds.length) void this.importSoundFiles(sounds);
      if (docs.length) void this.openDocumentFiles(docs);
      if (!sounds.length && !docs.length) this.console.append('Only sound files and .sapf or .txt documents can be dropped here.\n');
    }, true);
  }

  /** imports sound files into the Sounds folder, at the engine's sample rate, and says how to play them. */
  async importSoundFiles(files: File[]): Promise<string[]> {
    const names: string[] = [];
    for (const file of files) {
      try {
        const sound = await importSound(file, this.engine.audioContext, SOUNDS, (path, bytes) => this.documents.writeBytes(path, bytes));
        const channels = sound.channels === 1 ? '1 channel' : `${sound.channels} channels`;
        this.console.append(`imported "${sound.name}" into Sounds${sound.replaced ? ', replacing the one there' : ''}: ${channels}, ${sound.seconds.toFixed(2)} s. Play it with:\n"${sound.name}" sf> play\n`);
        names.push(sound.name);
      } catch (e) {
        this.console.append(`could not import ${file.name}: this browser can't read it as sound${e instanceof Error && e.message ? ` (${e.message})` : ''}\n`);
      }
    }
    if (names.length) await this.documents.syncNow();
    return names;
  }

  // MARK: running

  private connectEngine(): void {
    this.engine.onOutput = text => this.console.append(text);
    this.engine.onBusyChange = busy => { this.busyIndicator.hidden = !busy; };
    this.engine.onOpenFile = path => this.open(path);
    this.midi = new WebMidi((port, data) => this.engine.midiInput(port, data), text => this.console.append(text));
    this.engine.onMidiRequest = (request, uid, port) => this.midi.request(request as MidiRequest, uid, port);
    this.engine.onHelp = (builtIn, userDefined) => {
      this.help.add(builtIn, userDefined);
      this.editor.vocabularyChanged();
    };
  }

  /** runs code. The sounds it starts are tagged with tag (0 for none), so they can be stopped on their own. */
  evaluate(code: string, tag = 0): void {
    void this.engine.resumeAudio().catch(() => {});
    this.console.echo(code);
    void this.engine.evaluate(code, tag).then(() => this.documents.scheduleSync());
  }

  /** shows and hides the Stop buttons beside blocks, and beside the guide's examples, as their sounds start and end. */
  private watchPlayingTags(): void {
    window.setInterval(() => {
      const tags = this.engine.playingTags();
      this.editor.setPlayingTags(tags);
      const examples = [...this.guideRuns].filter(([, runs]) => runs.some(t => tags.has(t))).map(([example]) => example);
      const key = examples.join(',');
      if (key !== this.guidePlayingKey) {
        this.guidePlayingKey = key;
        this.setGuidePlaying(examples);
      }
    }, 250);
  }

  stop(): void {
    this.engine.stop();
  }

  /** plots up to a minute of the value on top of the stack in the waveform views. */
  async plotTopOfStack(): Promise<void> {
    const { plot, message } = await this.engine.plotTopOfStack(60);
    if (!plot) {
      this.console.append(`plot: ${message}\n`);
      return;
    }
    const shown = new Plot(plot);
    WaveformState.shared.show(shown);
    this.plotCount += 1;
    // a new plot brings the waveform into view.
    if (this.panelTab !== 'Scope') {
      this.panelTab = 'Scope';
      sessionStorage.setItem('panelTab', this.panelTab);
      this.layout();
    }
    this.console.append(`plot: ${shown.summary}\n`);
  }

  async clearStack(): Promise<void> {
    await this.engine.clearStack();
    this.console.append('stack cleared\n');
  }

  /** browsers only start audio from a user gesture. */
  private installAudioUnlock(): void {
    const unlock = () => {
      void this.engine.resumeAudio().then(() => {
        if (this.engine.audioContext.state === 'running') {
          document.removeEventListener('pointerdown', unlock, true);
          document.removeEventListener('keydown', unlock, true);
        }
      }).catch(() => {});
    };
    document.addEventListener('pointerdown', unlock, true);
    document.addEventListener('keydown', unlock, true);
  }

  /** the browser may suspend audio while the page is hidden; pick up where the sounds were. */
  private async resumeAudioIfInterrupted(): Promise<void> {
    const ctx = this.engine.audioContext;
    if (ctx.state === 'running') return;
    try {
      await ctx.resume();
      // resume() changes the state, which TypeScript can't see.
      if ((ctx.state as AudioContextState) === 'running') this.engine.module._sapf_restart();
    } catch { /* needs a gesture; installAudioUnlock covers it */ }
  }

  private installShortcuts(): void {
    document.addEventListener('keydown', e => {
      if (e.defaultPrevented) return;
      const modKey = isMac ? e.metaKey : e.ctrlKey;
      if (!modKey) return;
      const inField = (e.target as HTMLElement).closest?.('input, textarea, dialog');
      if (e.key === '.') { e.preventDefault(); this.stop(); }
      else if (e.key === 'Enter' && !inField) {
        // not the block hidden under the guide.
        if (!this.guidePane.hidden) return;
        e.preventDefault();
        this.editor.evaluate(true);
      }
      else if (e.shiftKey && e.key.toLowerCase() === 'p') { e.preventDefault(); void this.plotTopOfStack(); }
      else return;
      closeMenu();
    });
  }

  /** ?evaluate=code[&plot], ?runExamples, ?mute, ?currentDocument=name, like the iOS launch arguments. */
  private async handleLaunchParameters(): Promise<void> {
    const code = this.params.get('evaluate');
    if (code) {
      this.evaluate(code);
      if (this.params.has('plot')) await this.plotTopOfStack();
    }
    if (this.params.has('runExamples')) {
      const report = await this.runner.run();
      (window as unknown as { sapfReport: string }).sapfReport = report;
    }
  }
}

function showFatal(heading: string, message: string, offerReload = false): void {
  const loading = document.getElementById('loading');
  if (!loading) return;
  loading.innerHTML = '<h2></h2><p></p>';
  loading.querySelector('h2')!.textContent = heading;
  loading.querySelector('p')!.textContent = message;
  if (offerReload) {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'dialog-button primary';
    b.textContent = 'Reload';
    b.addEventListener('click', () => { sessionStorage.removeItem('sapf-sw-reload'); location.reload(); });
    loading.append(b);
  }
}

async function main(): Promise<void> {
  // the service worker adds the cross-origin isolation headers on static hosting, and caches for offline use.
  if (import.meta.env.PROD && 'serviceWorker' in navigator) {
    const { ensureServiceWorker } = await import('./serviceWorkerClient.ts');
    if (!(await ensureServiceWorker(BASE))) {
      // reloading. If that doesn't happen, say so rather than spinning forever.
      setTimeout(() => showFatal('sapf is still starting', 'The page needs to reload once to start the audio engine.', true), 5000);
      return;
    }
  }
  if (!self.crossOriginIsolated) {
    showFatal("sapf couldn't start its audio engine",
      'The engine needs a cross-origin isolated page (for SharedArrayBuffer). Reloading usually fixes this. If it keeps happening, use a current version of Chrome, Edge, Firefox or Safari, and make sure the site may use service workers.',
      true);
    return;
  }
  if (typeof AudioWorkletNode === 'undefined') {
    showFatal('Audio is not available', 'This browser does not support AudioWorklet, which sapf needs to make sound.');
    return;
  }
  const app = new App();
  (window as unknown as { sapf: App }).sapf = app;
  try {
    await app.start();
  } catch (e) {
    console.error(e);
    showFatal('sapf could not start', e instanceof Error ? e.message : String(e));
  }
}

void main();
