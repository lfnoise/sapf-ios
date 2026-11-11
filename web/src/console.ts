//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Interpreter output: error lines in red, evaluated code echoed in grey. A port of ios/Sapf/Views/ConsoleView.swift.
// Text goes straight into the DOM rather than through a model, because the output can get long.

const kMaxLength = 300_000;

type Style = 'plain' | 'error' | 'input';

export class ConsoleBuffer {
  readonly element: HTMLElement;
  private length = 0;
  private lastChar = '';
  /** everything appended, for tests and the example runner (characters ever appended, not trimmed). */
  totalLength = 0;
  private recent = '';

  constructor() {
    this.element = document.createElement('pre');
    this.element.className = 'console';
    this.element.tabIndex = 0;
    this.element.setAttribute('role', 'log');
    this.element.setAttribute('aria-label', 'Console');
  }

  private add(text: string, style: Style): void {
    if (!text) return;
    const last = this.element.lastElementChild as HTMLElement | null;
    if (last && last.dataset.style === style) {
      last.append(text);
    } else {
      const span = document.createElement('span');
      span.dataset.style = style;
      if (style !== 'plain') span.className = style;
      span.textContent = text;
      this.element.append(span);
    }
    this.length += text.length;
    this.totalLength += text.length;
    this.lastChar = text[text.length - 1];
    this.recent = (this.recent + text).slice(-kMaxLength);
  }

  /** run a change, keeping the view at the bottom if it was already there. */
  private update(change: () => void): void {
    const e = this.element;
    const atBottom = e.scrollTop >= e.scrollHeight - e.clientHeight - 40;
    change();
    this.trim();
    if (atBottom || e.scrollHeight <= e.clientHeight) e.scrollTop = e.scrollHeight;
  }

  append(output: string): void {
    this.update(() => {
      // color lines that report errors.
      for (const line of output.match(/[^\n]*\n|[^\n]+$/g) ?? []) {
        const isError = line.startsWith('error') || line.startsWith('\nerror') || line.includes('exception in real time');
        this.add(line, isError ? 'error' : 'plain');
      }
    });
  }

  /** echoes code that was evaluated, like the terminal prompt does. */
  echo(code: string): void {
    let shown = code.trim();
    if (shown.length > 400) shown = shown.slice(0, 400) + ' ...';
    shown = shown.replaceAll('\n', '\n       ');
    this.update(() => {
      if (this.length > 0 && this.lastChar !== '\n') this.add('\n', 'plain');
      this.add('sapf> ' + shown + '\n', 'input');
    });
  }

  clear(): void {
    this.element.replaceChildren();
    this.length = 0;
    this.lastChar = '';
  }

  /** text appended since totalLength was mark (as much as is kept). */
  textSince(mark: number): string {
    const n = this.totalLength - mark;
    return n <= 0 ? '' : this.recent.slice(-n);
  }

  private trim(): void {
    if (this.length <= kMaxLength) return;
    let excess = this.length - (kMaxLength * 3) / 4;
    while (excess > 0 && this.element.firstChild) {
      const node = this.element.firstElementChild as HTMLElement;
      const text = node.textContent ?? '';
      if (text.length <= excess) {
        node.remove();
        excess -= text.length;
        this.length -= text.length;
      } else {
        node.textContent = text.slice(excess);
        this.length -= excess;
        excess = 0;
      }
    }
  }
}
