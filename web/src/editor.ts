//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The code editor. A port of ios/Sapf/Editor/CodeTextView.swift, on CodeMirror:
//   coloring that follows the parser's rules, a run button beside each block (touch and hold, or right-click, for
//   Select and Copy Block) and a bar beside the block Run would evaluate, click a word for its help (or a variable's
//   value), Expand Selection, double-click a bracket to select through its match, find, and where you were in each
//   document. While reading (on touch screens) taps don't bring up the keyboard; they show help and pick the block.

import { EditorState, StateEffect, StateField, Compartment, Prec, RangeSetBuilder, type Extension } from '@codemirror/state';
import {
  EditorView, Decoration, ViewPlugin, keymap, drawSelection, highlightSpecialChars, gutter, GutterMarker,
  type DecorationSet, type ViewUpdate,
} from '@codemirror/view';
import { defaultKeymap, history, historyKeymap, indentWithTab, insertNewlineAndIndent } from '@codemirror/commands';
import { indentUnit } from '@codemirror/language';
import { searchKeymap, openSearchPanel, search } from '@codemirror/search';
import { tokenize, type Token, type TokenKind } from './lexer.ts';
import { CodeStructure, type Range } from './codeStructure.ts';
import type { HelpTable } from './help.ts';
import { showMenu } from './menu.ts';

export interface EditorActions {
  evaluate(code: string): void;
  stop(): void;
  plot(): void;
  describeWord(word: string): Promise<string | null>;
  textChanged(): void;
}

/** where you were in a document: the first visible character, the selection. Character indexes survive font changes. */
export interface Position {
  top: number;
  selection: number;
  selectionLength: number;
}

const kMinFont = 9;
const kMaxFont = 32;

// MARK: tokens and structure, recomputed when the text or the vocabulary changes

interface Analysis {
  tokens: Token[];
  structure: CodeStructure;
}

const vocabularyChanged = StateEffect.define<null>();

function makeAnalysisField(help: HelpTable) {
  const analyze = (text: string): Analysis => {
    const tokens = tokenize(text, help.builtInWords, help.userWords);
    return { tokens, structure: new CodeStructure(text, tokens) };
  };
  return StateField.define<Analysis>({
    create: state => analyze(state.doc.toString()),
    update(value, tr) {
      if (tr.docChanged || tr.effects.some(e => e.is(vocabularyChanged))) return analyze(tr.state.doc.toString());
      return value;
    },
  });
}

/** the token containing pos (from <= pos < to), by binary search. */
function tokenAt(tokens: Token[], pos: number): Token | null {
  let lo = 0;
  let hi = tokens.length - 1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    const t = tokens[mid];
    if (pos < t.from) hi = mid - 1;
    else if (pos >= t.to) lo = mid + 1;
    else return t;
  }
  return null;
}

// MARK: highlighting

const tokenMarks: Partial<Record<TokenKind, Decoration>> = {};
for (const kind of ['comment', 'string', 'number', 'builtIn', 'userWord', 'symbol', 'key', 'assign', 'assignTarget', 'lambda', 'lambdaArg', 'eachOp', 'bracket'] as TokenKind[]) {
  tokenMarks[kind] = Decoration.mark({ class: `tok-${kind}` });
}

function highlighter(field: StateField<Analysis>) {
  const build = (view: EditorView): DecorationSet => {
    const { tokens } = view.state.field(field);
    const builder = new RangeSetBuilder<Decoration>();
    for (const { from, to } of view.visibleRanges) {
      // first token ending after from
      let lo = 0;
      let hi = tokens.length;
      while (lo < hi) {
        const mid = (lo + hi) >> 1;
        if (tokens[mid].to <= from) lo = mid + 1; else hi = mid;
      }
      for (let i = lo; i < tokens.length && tokens[i].from < to; ++i) {
        const t = tokens[i];
        const mark = tokenMarks[t.kind];
        if (mark && t.to > t.from) builder.add(t.from, t.to, mark);
      }
    }
    return builder.finish();
  };
  return ViewPlugin.fromClass(class {
    decorations: DecorationSet;
    constructor(view: EditorView) { this.decorations = build(view); }
    update(u: ViewUpdate) {
      if (u.docChanged || u.viewportChanged || u.transactions.some(tr => tr.effects.some(e => e.is(vocabularyChanged)))) {
        this.decorations = build(u.view);
      }
    }
  }, { decorations: v => v.decorations });
}

// MARK: flash of the evaluated code

const addFlash = StateEffect.define<Range>();
const clearFlash = StateEffect.define<null>();
const flashMark = Decoration.mark({ class: 'cm-sapf-flash' });
const flashField = StateField.define<DecorationSet>({
  create: () => Decoration.none,
  update(flashes, tr) {
    flashes = flashes.map(tr.changes);
    for (const e of tr.effects) {
      if (e.is(addFlash) && e.value.to > e.value.from) flashes = Decoration.set([flashMark.range(e.value.from, e.value.to)]);
      if (e.is(clearFlash)) flashes = Decoration.none;
    }
    return flashes;
  },
  provide: f => EditorView.decorations.from(f),
});

// MARK: gutter: run buttons and the block bar

class RunMarker extends GutterMarker {
  readonly codeStart: number;
  constructor(codeStart: number) { super();
    this.codeStart = codeStart; }
  eq(other: RunMarker) { return other.codeStart === this.codeStart; }
  toDOM() {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'run-block';
    b.dataset.codeStart = String(this.codeStart);
    b.setAttribute('aria-label', 'Run block');
    b.title = 'Run block (right-click or touch and hold for more)';
    b.innerHTML = '<svg viewBox="0 0 24 24" width="11" height="11" aria-hidden="true"><path d="M6 3.5v17l14-8.5z" fill="currentColor"/></svg>';
    return b;
  }
}

class BarMarker extends GutterMarker {
  readonly first: boolean;
  readonly last: boolean;
  constructor(first: boolean, last: boolean) { super();
    this.first = first;
    this.last = last; }
  eq(other: BarMarker) { return other.first === this.first && other.last === this.last; }
  toDOM() {
    const d = document.createElement('div');
    d.className = 'block-bar' + (this.first ? ' first' : '') + (this.last ? ' last' : '');
    return d;
  }
}

export class CodeEditor {
  readonly view: EditorView;
  readonly element: HTMLElement;
  private analysis: StateField<Analysis>;
  private editable = new Compartment();
  private flashTimer = 0;
  private tooltip: HTMLElement;
  private tooltipToken: Token | null = null;
  private pendingPosition: Position | null = null;
  private _fontSize: number;
  private _isEditing: boolean;
  showsHelpOnTap: boolean;
  /** called when editing ends by itself (the on-screen keyboard was dismissed). */
  onEditingEnded: () => void = () => {};

  private help: HelpTable;
  private actions: EditorActions;
  constructor(help: HelpTable, actions: EditorActions, options: { fontSize: number; isEditing: boolean; showsHelpOnTap: boolean }) {
    this.help = help;
    this.actions = actions;
    this._fontSize = options.fontSize;
    this._isEditing = options.isEditing;
    this.showsHelpOnTap = options.showsHelpOnTap;
    this.element = document.createElement('div');
    this.element.className = 'editor';
    this.analysis = makeAnalysisField(help);
    this.view = new EditorView({ parent: this.element, state: this.makeState('') });
    this.tooltip = document.createElement('div');
    this.tooltip.className = 'help-tooltip';
    this.tooltip.hidden = true;
    this.tooltip.setAttribute('role', 'tooltip');
    this.tooltip.setAttribute('aria-live', 'polite');
    this.view.scrollDOM.append(this.tooltip);
    this.applyFontSize();
    this.installEventHandlers();
  }

  private extensions(): Extension[] {
    const field = this.analysis;
    return [
      Prec.highest(keymap.of([
        { key: 'Mod-Enter', run: () => { this.evaluate(true); return true; } },
        { key: 'Shift-Enter', run: () => { this.evaluate(false); return true; } },
        { key: 'Mod-.', run: () => { this.actions.stop(); return true; } },
        { key: 'Mod-b', run: () => { this.expandSelection(); return true; } },
        { key: 'Shift-Mod-p', run: () => { this.actions.plot(); return true; } },
        // pressing return keeps the current line's indentation.
        { key: 'Enter', run: insertNewlineAndIndent },
      ])),
      field,
      highlighter(field),
      flashField,
      gutter({
        class: 'run-gutter',
        markers: view => {
          const builder = new RangeSetBuilder<GutterMarker>();
          for (const block of view.state.field(field).structure.blocks) {
            if (block.codeStart === null) continue;
            const line = view.state.doc.lineAt(block.codeStart);
            builder.add(line.from, line.from, new RunMarker(block.codeStart));
          }
          return builder.finish();
        },
      }),
      gutter({
        class: 'bar-gutter',
        markers: view => {
          const builder = new RangeSetBuilder<GutterMarker>();
          const sel = view.state.selection.main;
          if (!sel.empty) return builder.finish();
          const { structure } = view.state.field(field);
          const block = structure.blockAt(sel.head);
          if (!block || block.codeStart === null) return builder.finish();
          const r = structure.trimmed(block.range);
          const doc = view.state.doc;
          const first = doc.lineAt(r.from).number;
          const last = doc.lineAt(Math.max(r.from, r.to)).number;
          for (let n = first; n <= last; ++n) {
            const line = doc.line(n);
            builder.add(line.from, line.from, new BarMarker(n === first, n === last));
          }
          return builder.finish();
        },
        lineMarkerChange: u => u.selectionSet || u.docChanged,
      }),
      history(),
      drawSelection(),
      highlightSpecialChars(),
      search({ top: true }),
      EditorState.tabSize.of(4),
      indentUnit.of('\t'),
      keymap.of([...defaultKeymap, ...historyKeymap, ...searchKeymap, indentWithTab]),
      EditorView.lineWrapping,
      this.editable.of(EditorView.editable.of(this._isEditing)),
      EditorView.contentAttributes.of({ autocorrect: 'off', autocapitalize: 'off', spellcheck: 'false', 'aria-label': 'Code' }),
      EditorView.updateListener.of(u => {
        if (u.docChanged) {
          this.hideTooltip();
          this.actions.textChanged();
        }
        if (u.geometryChanged && this.pendingPosition) {
          const p = this.pendingPosition;
          this.pendingPosition = null;
          this.apply(p);
        }
      }),
    ];
  }

  private makeState(text: string): EditorState {
    return EditorState.create({ doc: text, extensions: this.extensions() });
  }

  get text(): string {
    return this.view.state.doc.toString();
  }

  setText(text: string): void {
    this.hideTooltip();
    this.view.setState(this.makeState(text));
  }

  /** the help table changed: recolor. */
  vocabularyChanged(): void {
    this.view.dispatch({ effects: vocabularyChanged.of(null) });
  }

  private get structure(): CodeStructure {
    return this.view.state.field(this.analysis).structure;
  }

  private get tokens(): Token[] {
    return this.view.state.field(this.analysis).tokens;
  }

  // MARK: editing and reading

  get isEditing(): boolean { return this._isEditing; }
  set isEditing(editing: boolean) {
    if (editing === this._isEditing) return;
    this._isEditing = editing;
    this.view.dispatch({ effects: this.editable.reconfigure(EditorView.editable.of(editing)) });
    this.element.classList.toggle('reading', !editing);
  }

  focus(): void {
    this.view.focus();
  }

  blur(): void {
    this.view.contentDOM.blur();
  }

  // MARK: font size

  get fontSize(): number { return this._fontSize; }
  set fontSize(size: number) {
    this._fontSize = Math.min(kMaxFont, Math.max(kMinFont, size));
    this.applyFontSize();
  }

  private applyFontSize(): void {
    this.element.style.setProperty('--editor-font-size', `${this._fontSize}px`);
    this.view.requestMeasure();
  }

  // MARK: evaluation

  /** the selection if there is one, otherwise the block around the cursor (or its line). */
  codeToEvaluate(wholeBlock: boolean): Range {
    const sel = this.view.state.selection.main;
    if (!sel.empty) return { from: sel.from, to: sel.to };
    const line = this.view.state.doc.lineAt(sel.head);
    const lineRange = { from: line.from, to: Math.min(line.to + 1, this.view.state.doc.length) };
    if (!wholeBlock) return lineRange;
    return this.structure.blockAt(sel.head)?.range ?? lineRange;
  }

  evaluate(wholeBlock = true): void {
    const range = this.codeToEvaluate(wholeBlock);
    const code = this.text.slice(range.from, range.to);
    if (!code.trim()) return;
    this.flash(range);
    this.actions.evaluate(code);
  }

  private blockWithCodeStart(codeStart: number) {
    return this.structure.blocks.find(b => b.codeStart === codeStart) ?? null;
  }

  /** runs the block whose code starts at a location (from a run button). */
  evaluateBlock(codeStart: number): void {
    const block = this.blockWithCodeStart(codeStart);
    if (!block) return;
    this.hideTooltip();
    this.flash(block.range);
    this.actions.evaluate(this.text.slice(block.range.from, block.range.to));
  }

  selectBlock(codeStart: number): void {
    const block = this.blockWithCodeStart(codeStart);
    if (!block) return;
    const r = this.structure.trimmed(block.range);
    this.view.dispatch({ selection: { anchor: r.from, head: r.to } });
    this.view.focus();
  }

  copyBlock(codeStart: number): void {
    const block = this.blockWithCodeStart(codeStart);
    if (!block) return;
    const r = this.structure.trimmed(block.range);
    void navigator.clipboard?.writeText(this.text.slice(r.from, r.to));
  }

  /** selects the next larger enclosing expression: inside the brackets, the brackets, then the block. */
  expandSelection(): void {
    const sel = this.view.state.selection.main;
    const range = this.structure.expand({ from: sel.from, to: sel.to });
    if (!range) return;
    this.view.dispatch({ selection: { anchor: range.from, head: range.to } });
    this.view.focus();
  }

  showFind(): void {
    openSearchPanel(this.view);
  }

  private flash(range: Range): void {
    window.clearTimeout(this.flashTimer);
    this.view.dispatch({ effects: addFlash.of(range) });
    this.flashTimer = window.setTimeout(() => this.view.dispatch({ effects: clearFlash.of(null) }), 350);
  }

  // MARK: clicks: help, brackets, run buttons

  private installEventHandlers(): void {
    const view = this.view;

    // run buttons in the margin
    this.element.addEventListener('click', e => {
      const b = (e.target as HTMLElement).closest<HTMLButtonElement>('.run-block');
      if (!b) return;
      e.preventDefault();
      this.evaluateBlock(Number(b.dataset.codeStart));
    });
    const blockMenu = (b: HTMLElement, x: number, y: number) => {
      const codeStart = Number(b.dataset.codeStart);
      showMenu({ x, y }, [
        { label: 'Run Block', action: () => this.evaluateBlock(codeStart) },
        { label: 'Select Block', action: () => this.selectBlock(codeStart) },
        { label: 'Copy Block', action: () => this.copyBlock(codeStart) },
      ], 'Block');
    };
    this.element.addEventListener('contextmenu', e => {
      const b = (e.target as HTMLElement).closest<HTMLElement>('.run-block');
      if (!b) return;
      e.preventDefault();
      blockMenu(b, e.clientX, e.clientY);
    });
    let pressTimer = 0;
    this.element.addEventListener('pointerdown', e => {
      const b = (e.target as HTMLElement).closest<HTMLElement>('.run-block');
      if (!b || e.pointerType !== 'touch') return;
      pressTimer = window.setTimeout(() => { pressTimer = -1; blockMenu(b, e.clientX, e.clientY); }, 500);
    });
    const cancelPress = (e: Event) => {
      if (pressTimer === -1) { e.preventDefault(); pressTimer = 0; return; }
      window.clearTimeout(pressTimer);
      pressTimer = 0;
    };
    this.element.addEventListener('pointerup', cancelPress);
    this.element.addEventListener('pointercancel', cancelPress);

    // a click shows a word's help; clicking the same word again hides it.
    view.contentDOM.addEventListener('click', e => {
      if (e.detail > 1) return;
      if (!view.state.selection.main.empty) { this.hideTooltip(); return; }
      this.wordClicked(e.clientX, e.clientY);
    });

    // double-clicking a bracket selects through its match, instead of selecting a word.
    view.contentDOM.addEventListener('dblclick', e => {
      const pos = view.posAtCoords({ x: e.clientX, y: e.clientY }, false);
      const token = tokenAt(this.tokens, pos) ?? tokenAt(this.tokens, pos - 1);
      if (!token || token.kind !== 'bracket') return;
      const pair = this.structure.pairWithBracketAt(token.from);
      if (!pair) return;
      setTimeout(() => view.dispatch({ selection: { anchor: pair.from, head: pair.to } }), 0);
    });

    // dismissing the on-screen keyboard ends editing on touch screens.
    view.contentDOM.addEventListener('blur', () => {
      if (matchMedia('(pointer: coarse)').matches && this._isEditing) {
        setTimeout(() => { if (!view.hasFocus && document.activeElement?.closest('.key-bar') == null) this.onEditingEnded(); }, 0);
      }
    });
    view.scrollDOM.addEventListener('keydown', e => { if (e.key === 'Escape') this.hideTooltip(); });
  }

  private wordClicked(x: number, y: number): void {
    const view = this.view;
    if (!this.showsHelpOnTap) { this.hideTooltip(); return; }
    const pos = view.posAtCoords({ x, y }, false);
    const token = tokenAt(this.tokens, pos);
    const helpKinds: TokenKind[] = ['builtIn', 'userWord', 'word', 'symbol', 'key', 'assignTarget'];
    if (!token || !helpKinds.includes(token.kind)) { this.hideTooltip(); return; }
    // the click must be on the word, not just nearest to it.
    const start = view.coordsAtPos(token.from, 1);
    const end = view.coordsAtPos(token.to, -1);
    if (!start || !end || x < start.left - 6 || x > end.right + 6 || y < start.top - 4 || y > end.bottom + 4) {
      this.hideTooltip();
      return;
    }
    if (this.tooltipToken && this.tooltipToken.from === token.from && this.tooltipToken.to === token.to && !this.tooltip.hidden) {
      this.hideTooltip();
      return;
    }

    let word = this.text.slice(token.from, token.to);
    if (token.kind === 'symbol' || token.kind === 'key') word = word.slice(1);
    this.tooltipToken = token;
    const rect = { left: start.left, right: end.right, top: start.top, bottom: end.bottom };

    const h = this.help.get(word);
    if (h) {
      this.showTooltip(h.name, h.mask, h.help, h.builtIn ? null : 'user defined', rect);
      return;
    }
    // not a function with help. If it's a variable, show its value.
    this.hideTooltip();
    this.tooltipToken = token;
    void this.actions.describeWord(word).then(value => {
      if (value === null || this.tooltipToken !== token) return;
      this.showTooltip(word, null, value, 'value', rect);
    });
  }

  private showTooltip(name: string, mask: string | null, help: string, detail: string | null, rect: { left: number; right: number; top: number; bottom: number }): void {
    const t = this.tooltip;
    t.replaceChildren();
    const head = document.createElement('div');
    const nameEl = document.createElement('span');
    nameEl.className = 'help-name';
    nameEl.textContent = name;
    head.append(nameEl);
    if (mask) {
      const m = document.createElement('span');
      m.className = 'help-mask';
      m.textContent = '  @' + mask;
      head.append(m);
    }
    if (detail) {
      const d = document.createElement('span');
      d.className = 'help-detail';
      d.textContent = '  ' + detail;
      head.append(d);
    }
    t.append(head);
    // help usually starts with a stack effect like "(in freq --> out)". Show it in mono.
    let body = help;
    if (body.startsWith('(')) {
      const close = body.indexOf(')');
      if (close >= 0) {
        const effect = document.createElement('div');
        effect.className = 'help-effect';
        effect.textContent = body.slice(0, close + 1);
        t.append(effect);
        body = body.slice(close + 1).trim();
      }
    }
    if (body) {
      const text = document.createElement('div');
      text.className = 'help-text';
      text.textContent = body;
      t.append(text);
    }

    // place it above the word if there's room, otherwise below; within the visible area.
    t.hidden = false;
    t.classList.remove('below');
    const scroller = this.view.scrollDOM;
    const sr = scroller.getBoundingClientRect();
    const maxWidth = Math.min(sr.width - 16, 460);
    t.style.maxWidth = `${maxWidth}px`;
    const tw = t.offsetWidth;
    const th = t.offsetHeight;
    const arrow = 7;
    const center = (rect.left + rect.right) / 2;
    let left = Math.min(Math.max(center - tw / 2, sr.left + 8), sr.right - 8 - tw);
    let top = rect.top - th - arrow;
    if (top < sr.top + 4) {
      top = rect.bottom + arrow;
      t.classList.add('below');
    }
    t.style.left = `${left - sr.left + scroller.scrollLeft}px`;
    t.style.top = `${top - sr.top + scroller.scrollTop}px`;
    t.style.setProperty('--arrow-x', `${center - left}px`);
  }

  hideTooltip(): void {
    this.tooltip.hidden = true;
    this.tooltipToken = null;
  }

  // MARK: position memory

  get position(): Position {
    const view = this.view;
    const sel = view.state.selection.main;
    const top = view.lineBlockAtHeight(view.scrollDOM.scrollTop).from;
    return { top, selection: sel.from, selectionLength: sel.to - sel.from };
  }

  restore(position: Position): void {
    if (!this.view.dom.isConnected || this.view.scrollDOM.clientHeight === 0) {
      // wait for layout.
      this.pendingPosition = position;
      return;
    }
    this.apply(position);
  }

  private apply(p: Position): void {
    const length = this.view.state.doc.length;
    const clamp = (n: number) => Math.min(Math.max(n, 0), length);
    const anchor = clamp(p.selection);
    this.view.dispatch({
      selection: { anchor, head: clamp(p.selection + p.selectionLength) },
      effects: EditorView.scrollIntoView(clamp(p.top), { y: 'start' }),
    });
  }

  // MARK: key bar and reading bar (touch screens)

  /** Run, Stop, Expand Selection, Plot and Find; with keys for the symbols sapf uses when withKeys. */
  makeBar(withKeys: boolean): HTMLElement {
    const bar = document.createElement('div');
    bar.className = withKeys ? 'key-bar' : 'reading-bar';
    bar.setAttribute('role', 'toolbar');
    bar.setAttribute('aria-label', withKeys ? 'Keys' : 'Commands');
    const scroller = document.createElement('div');
    scroller.className = 'bar-buttons';
    const button = (html: string, label: string, cls: string, action: () => void) => {
      const b = document.createElement('button');
      b.type = 'button';
      b.innerHTML = html;
      b.title = label;
      b.setAttribute('aria-label', label);
      b.className = cls;
      // keep focus in the editor so the keyboard stays up.
      b.addEventListener('pointerdown', e => e.preventDefault());
      b.addEventListener('click', action);
      return b;
    };
    const svg = (body: string) => `<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${body}</svg>`;
    scroller.append(
      button('<svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true"><path d="M7 4.5v15l12-7.5z" fill="currentColor"/></svg>', 'Evaluate', 'cmd run', () => this.evaluate(true)),
      button('<svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true"><rect x="6" y="6" width="12" height="12" rx="1.5" fill="currentColor"/></svg>', 'Stop', 'cmd stop', () => this.actions.stop()),
      button(svg('<path d="M4 9V5a1 1 0 0 1 1-1h4M15 4h4a1 1 0 0 1 1 1v4M20 15v4a1 1 0 0 1-1 1h-4M9 20H5a1 1 0 0 1-1-1v-4"/><path d="M9 12h6M12 9v6"/>'), 'Expand Selection', 'cmd expand', () => this.expandSelection()),
      button(svg('<path d="M3 3v18h18"/><path d="M6 15c2-6 4-6 6-1s4 4 7-6"/>'), 'Plot', 'cmd plot', () => this.actions.plot()),
      button(svg('<circle cx="10.5" cy="10.5" r="6.5"/><path d="M15.5 15.5 21 21"/>'), 'Find', 'cmd find', () => this.showFind()),
    );
    if (withKeys) {
      for (const key of ['[', ']', '(', ')', '{', '}', '\\', '@', "'", '`', '=', ':', ';', '"', '#', ',', '.']) {
        const b = button('', key, 'key', () => this.insert(key));
        b.textContent = key;
        scroller.append(b);
      }
    }
    bar.append(scroller);
    return bar;
  }

  private insert(text: string): void {
    const sel = this.view.state.selection.main;
    this.view.dispatch({ changes: { from: sel.from, to: sel.to, insert: text }, selection: { anchor: sel.from + text.length }, scrollIntoView: true });
  }
}

