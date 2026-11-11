//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Popover menus (toolbar menus and context menus) and small modal dialogs.

export interface MenuItem {
  label: string;
  action: () => void;
  shortcut?: string;
  checked?: boolean;
  destructive?: boolean;
  disabled?: boolean;
}

/** a caption heading a group of items, or a footer. */
export interface MenuCaption {
  caption: string;
}

export type MenuEntry = MenuItem | MenuCaption | 'separator';

let openMenu: { element: HTMLElement; close: () => void } | null = null;

export function closeMenu(): void {
  openMenu?.close();
}

/** Show a menu below an element, or at a point (for context menus). */
export function showMenu(at: HTMLElement | { x: number; y: number }, entries: MenuEntry[], label = 'Menu'): void {
  closeMenu();
  const menu = document.createElement('div');
  menu.className = 'menu';
  menu.setAttribute('role', 'menu');
  menu.setAttribute('aria-label', label);
  const buttons: HTMLButtonElement[] = [];
  for (const entry of entries) {
    if (entry !== 'separator' && 'caption' in entry) {
      const c = document.createElement('div');
      c.className = 'menu-caption';
      c.textContent = entry.caption;
      menu.append(c);
      continue;
    }
    if (entry === 'separator') {
      const hr = document.createElement('div');
      hr.className = 'menu-separator';
      hr.setAttribute('role', 'separator');
      menu.append(hr);
      continue;
    }
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'menu-item' + (entry.destructive ? ' destructive' : '');
    b.setAttribute('role', entry.checked === undefined ? 'menuitem' : 'menuitemcheckbox');
    if (entry.checked !== undefined) b.setAttribute('aria-checked', String(entry.checked));
    b.disabled = !!entry.disabled;
    b.innerHTML = `<span class="menu-check">${entry.checked ? '✓' : ''}</span><span class="menu-label"></span><span class="menu-shortcut"></span>`;
    b.querySelector('.menu-label')!.textContent = entry.label;
    b.querySelector('.menu-shortcut')!.textContent = entry.shortcut ?? '';
    b.addEventListener('click', () => {
      close();
      entry.action();
    });
    menu.append(b);
    buttons.push(b);
  }
  document.body.append(menu);

  // position, keeping it on screen.
  const r = menu.getBoundingClientRect();
  let x: number, y: number;
  if (at instanceof HTMLElement) {
    const a = at.getBoundingClientRect();
    x = a.right - r.width;
    y = a.bottom + 4;
    if (x < 8) x = a.left;
  } else {
    x = at.x;
    y = at.y;
  }
  x = Math.max(8, Math.min(x, window.innerWidth - r.width - 8));
  y = Math.max(8, Math.min(y, window.innerHeight - r.height - 8));
  menu.style.left = `${x}px`;
  menu.style.top = `${y}px`;

  const previousFocus = document.activeElement as HTMLElement | null;
  const onPointerDown = (e: PointerEvent) => { if (!menu.contains(e.target as Node)) close(); };
  const onKey = (e: KeyboardEvent) => {
    const enabled = buttons.filter(b => !b.disabled);
    const i = enabled.indexOf(document.activeElement as HTMLButtonElement);
    if (e.key === 'Escape') { e.preventDefault(); close(); previousFocus?.focus(); }
    else if (e.key === 'ArrowDown') { e.preventDefault(); enabled[(i + 1) % enabled.length]?.focus(); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); enabled[(i - 1 + enabled.length) % enabled.length]?.focus(); }
    else if (e.key === 'Tab') { close(); }
  };
  function close() {
    menu.remove();
    document.removeEventListener('pointerdown', onPointerDown, true);
    document.removeEventListener('keydown', onKey, true);
    window.removeEventListener('resize', close);
    if (openMenu?.element === menu) openMenu = null;
  }
  setTimeout(() => document.addEventListener('pointerdown', onPointerDown, true), 0);
  document.addEventListener('keydown', onKey, true);
  window.addEventListener('resize', close);
  openMenu = { element: menu, close };
  buttons.find(b => !b.disabled)?.focus({ preventScroll: true });
}

// MARK: dialogs

function makeDialog(title: string): { dialog: HTMLDialogElement; body: HTMLElement; buttons: HTMLElement } {
  const dialog = document.createElement('dialog');
  dialog.className = 'dialog';
  dialog.innerHTML = `<form method="dialog"><h2 class="dialog-title"></h2><div class="dialog-body"></div><div class="dialog-buttons"></div></form>`;
  dialog.querySelector('.dialog-title')!.textContent = title;
  document.body.append(dialog);
  dialog.addEventListener('close', () => dialog.remove());
  return { dialog, body: dialog.querySelector('.dialog-body')!, buttons: dialog.querySelector('.dialog-buttons')! };
}

function addButton(container: HTMLElement, label: string, value: string, primary = false, destructive = false): HTMLButtonElement {
  const b = document.createElement('button');
  b.value = value;
  b.textContent = label;
  b.className = 'dialog-button' + (primary ? ' primary' : '') + (destructive ? ' destructive' : '');
  container.append(b);
  return b;
}

/** Ask for a line of text. Resolves to null if cancelled. */
export function promptText(title: string, initial: string, okLabel = 'OK'): Promise<string | null> {
  const { dialog, body, buttons } = makeDialog(title);
  const input = document.createElement('input');
  input.type = 'text';
  input.value = initial;
  input.className = 'dialog-input';
  input.setAttribute('aria-label', title);
  input.autocapitalize = 'off';
  input.spellcheck = false;
  body.append(input);
  addButton(buttons, 'Cancel', 'cancel');
  addButton(buttons, okLabel, 'ok', true);
  dialog.showModal();
  // select the name without its extension, as Finder does.
  const dot = initial.lastIndexOf('.');
  input.setSelectionRange(0, dot > 0 ? dot : initial.length);
  input.focus();
  return new Promise(resolve => {
    dialog.addEventListener('close', () => resolve(dialog.returnValue === 'ok' ? input.value : null));
    input.addEventListener('keydown', e => {
      if (e.key === 'Enter') { e.preventDefault(); dialog.close('ok'); }
    });
  });
}

/** Ask to confirm an action. */
export function confirmAction(title: string, message: string, okLabel: string, destructive = false): Promise<boolean> {
  const { dialog, body, buttons } = makeDialog(title);
  const p = document.createElement('p');
  p.textContent = message;
  body.append(p);
  addButton(buttons, 'Cancel', 'cancel');
  const ok = addButton(buttons, okLabel, 'ok', true, destructive);
  dialog.showModal();
  ok.focus();
  return new Promise(resolve => dialog.addEventListener('close', () => resolve(dialog.returnValue === 'ok')));
}

/** Show a message. */
export function showMessage(title: string, message: string): void {
  const { dialog, body, buttons } = makeDialog(title);
  const p = document.createElement('p');
  p.textContent = message;
  body.append(p);
  addButton(buttons, 'OK', 'ok', true).focus();
  dialog.showModal();
}
