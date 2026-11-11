//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The All Functions viewer: every function's help, styled so names stand out from their descriptions, with Find
// and Share. A port of ios/Sapf/Views/FunctionListView.swift and FunctionList.swift.

import { functionEntry } from './help.ts';

/** the list as DOM: headings, entries (name, @mask, stack effect, description) and other lines. */
export function renderFunctionList(text: string): HTMLElement {
  const root = document.createElement('div');
  root.className = 'function-list';
  for (const line of text.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    if (trimmed === 'BUILT IN FUNCTIONS' || trimmed === 'USER DEFINED FUNCTIONS') {
      const h = document.createElement('h2');
      h.textContent = trimmed.toLowerCase().replace(/\b\w/g, c => c.toUpperCase());
      root.append(h);
    } else if (trimmed.startsWith('***')) {
      const h = document.createElement('h3');
      h.textContent = trimmed.replace(/^[* ]+|[* ]+$/g, '');
      root.append(h);
    } else {
      const e = functionEntry(line);
      const p = document.createElement('p');
      if (e) {
        p.className = 'entry';
        const name = document.createElement('b');
        name.className = 'fn-name';
        name.textContent = e.name;
        p.append(name);
        if (e.mask) {
          const m = document.createElement('span');
          m.className = 'fn-mask';
          m.textContent = '  @' + e.mask;
          p.append(m);
        }
        if (e.effect) {
          const ef = document.createElement('span');
          ef.className = 'fn-effect';
          ef.textContent = '  ' + e.effect;
          p.append(ef);
        }
        if (e.description) p.append('  ' + e.description);
      } else {
        p.className = 'other' + (line.startsWith(' ') ? ' indented' : '');
        p.textContent = trimmed;
      }
      root.append(p);
    }
  }
  return root;
}

export function showFunctionList(text: string): void {
  const dialog = document.createElement('dialog');
  dialog.className = 'dialog sheet function-list-dialog';
  dialog.setAttribute('aria-label', 'All Functions');
  dialog.innerHTML = `
    <header class="sheet-header">
      <h2 class="dialog-title">All Functions</h2>
      <span class="spacer"></span>
      <button type="button" class="text-button" data-action="share">Share</button>
      <button type="button" class="text-button" data-action="find">Find</button>
      <button type="button" class="text-button bold" data-action="done">Done</button>
    </header>
    <div class="find-bar" hidden>
      <input type="search" placeholder="Find" aria-label="Find in functions" spellcheck="false" autocapitalize="off">
      <span class="find-count"></span>
      <button type="button" class="text-button" data-action="prev" aria-label="Previous match">‹</button>
      <button type="button" class="text-button" data-action="next" aria-label="Next match">›</button>
    </div>
    <div class="sheet-body"></div>`;
  const body = dialog.querySelector<HTMLElement>('.sheet-body')!;
  body.append(renderFunctionList(text));
  document.body.append(dialog);

  const findBar = dialog.querySelector<HTMLElement>('.find-bar')!;
  const input = findBar.querySelector('input')!;
  const count = findBar.querySelector<HTMLElement>('.find-count')!;
  let matches: HTMLElement[] = [];
  let current = -1;

  const clearMarks = () => {
    for (const m of body.querySelectorAll('mark')) m.replaceWith(document.createTextNode(m.textContent ?? ''));
    body.normalize();
  };
  const search = () => {
    clearMarks();
    matches = [];
    current = -1;
    const q = input.value.toLowerCase();
    if (!q) { count.textContent = ''; return; }
    const walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT);
    const nodes: Text[] = [];
    for (let n = walker.nextNode(); n; n = walker.nextNode()) nodes.push(n as Text);
    for (const node of nodes) {
      const text = node.data;
      const lower = text.toLowerCase();
      let i = lower.indexOf(q);
      if (i < 0) continue;
      const frag = document.createDocumentFragment();
      let last = 0;
      while (i >= 0) {
        frag.append(text.slice(last, i));
        const mark = document.createElement('mark');
        mark.textContent = text.slice(i, i + q.length);
        frag.append(mark);
        matches.push(mark);
        last = i + q.length;
        i = lower.indexOf(q, last);
      }
      frag.append(text.slice(last));
      node.replaceWith(frag);
    }
    step(1);
  };
  const step = (dir: number) => {
    if (matches.length === 0) { count.textContent = input.value ? 'not found' : ''; return; }
    matches[current]?.classList.remove('current');
    current = (current + dir + matches.length) % matches.length;
    matches[current].classList.add('current');
    matches[current].scrollIntoView({ block: 'center' });
    count.textContent = `${current + 1}/${matches.length}`;
  };
  const openFind = () => { findBar.hidden = false; input.focus(); input.select(); };

  input.addEventListener('input', search);
  input.addEventListener('keydown', e => {
    if (e.key === 'Enter') { e.preventDefault(); step(e.shiftKey ? -1 : 1); }
  });
  dialog.addEventListener('keydown', e => {
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'f') { e.preventDefault(); openFind(); }
    if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'g') { e.preventDefault(); step(e.shiftKey ? -1 : 1); }
  });
  dialog.querySelector('[data-action="find"]')!.addEventListener('click', openFind);
  dialog.querySelector('[data-action="prev"]')!.addEventListener('click', () => step(-1));
  dialog.querySelector('[data-action="next"]')!.addEventListener('click', () => step(1));
  dialog.querySelector('[data-action="done"]')!.addEventListener('click', () => dialog.close());
  const share = dialog.querySelector<HTMLButtonElement>('[data-action="share"]')!;
  share.addEventListener('click', async () => {
    try {
      if (navigator.share) await navigator.share({ title: 'sapf functions', text });
      else { await navigator.clipboard.writeText(text); share.textContent = 'Copied'; setTimeout(() => (share.textContent = 'Share'), 1500); }
    } catch { /* cancelled */ }
  });
  dialog.addEventListener('close', () => dialog.remove());
  dialog.showModal();
}
