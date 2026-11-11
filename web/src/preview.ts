//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Shows a file the interpreter produced or opened (recordings, spectrograms, help text), or a non-text file
// chosen in the sidebar. The web counterpart of the iOS Quick Look preview.

import { baseName, extensionOf, type DocumentStore } from './documents.ts';

const isTextPath = (path: string) => ['txt', 'sapf', 'md', ''].includes(extensionOf(path));

const mimeTypes: Record<string, string> = {
  wav: 'audio/wav', aif: 'audio/aiff', aiff: 'audio/aiff', mp3: 'audio/mpeg', m4a: 'audio/mp4', caf: 'audio/x-caf',
  flac: 'audio/flac', ogg: 'audio/ogg',
  jpg: 'image/jpeg', jpeg: 'image/jpeg', png: 'image/png', gif: 'image/gif', webp: 'image/webp',
  txt: 'text/plain', md: 'text/markdown', sapf: 'text/plain',
};

export function mimeType(path: string): string {
  return mimeTypes[extensionOf(path)] ?? 'application/octet-stream';
}

export function downloadFile(workspace: DocumentStore, path: string): void {
  const bytes = workspace.readBytes(path);
  const url = URL.createObjectURL(new Blob([bytes.slice()], { type: mimeType(path) }));
  const a = document.createElement('a');
  a.href = url;
  a.download = baseName(path);
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 10_000);
}

export class PreviewDialog {
  private dialog: HTMLDialogElement | null = null;
  private objectURL: string | null = null;

  private workspace: DocumentStore;
  private openInEditor: (path: string) => void;

  constructor(workspace: DocumentStore, openInEditor: (path: string) => void) {
    this.workspace = workspace;
    this.openInEditor = openInEditor;
  }

  /** shows a file. Text files can offer to open in the editor when allowEdit. */
  show(path: string, allowEdit = false): void {
    this.close();
    let bytes: Uint8Array;
    try {
      bytes = this.workspace.readBytes(path);
    } catch {
      return;
    }
    const ext = extensionOf(path);
    const type = mimeType(path);
    const dialog = document.createElement('dialog');
    dialog.className = 'dialog preview-dialog';
    dialog.setAttribute('aria-label', baseName(path));
    dialog.innerHTML = `
      <header class="preview-header">
        <h2 class="dialog-title"></h2>
        <span class="spacer"></span>
        <button type="button" class="text-button" data-action="edit" hidden>Open in Editor</button>
        <button type="button" class="text-button" data-action="download">Download</button>
        <button type="button" class="text-button" data-action="close">Done</button>
      </header>
      <div class="preview-body"></div>`;
    dialog.querySelector('.dialog-title')!.textContent = baseName(path);
    const body = dialog.querySelector<HTMLElement>('.preview-body')!;

    if (type.startsWith('audio/')) {
      this.objectURL = URL.createObjectURL(new Blob([bytes.slice()], { type }));
      const audio = document.createElement('audio');
      audio.controls = true;
      audio.src = this.objectURL;
      body.append(audio);
      const info = document.createElement('p');
      info.className = 'preview-info';
      info.textContent = `${(bytes.length / 1024).toFixed(0)} KB`;
      body.append(info);
    } else if (type.startsWith('image/')) {
      this.objectURL = URL.createObjectURL(new Blob([bytes.slice()], { type }));
      const img = document.createElement('img');
      img.src = this.objectURL;
      img.alt = baseName(path);
      body.append(img);
    } else if (isTextPath(path) || ext === '') {
      const pre = document.createElement('pre');
      pre.className = 'preview-text';
      pre.textContent = new TextDecoder().decode(bytes);
      body.append(pre);
      const edit = dialog.querySelector<HTMLButtonElement>('[data-action="edit"]')!;
      edit.hidden = !allowEdit;
      edit.addEventListener('click', () => { this.close(); this.openInEditor(path); });
    } else {
      const p = document.createElement('p');
      p.textContent = 'This file can\'t be shown here. Download it to open it in another app.';
      body.append(p);
    }

    dialog.querySelector('[data-action="download"]')!.addEventListener('click', () => downloadFile(this.workspace, path));
    dialog.querySelector('[data-action="close"]')!.addEventListener('click', () => this.close());
    dialog.addEventListener('close', () => this.cleanup(dialog));
    document.body.append(dialog);
    dialog.showModal();
    this.dialog = dialog;
  }

  close(): void {
    this.dialog?.close();
  }

  private cleanup(dialog: HTMLDialogElement): void {
    dialog.querySelector('audio')?.pause();
    dialog.remove();
    if (this.objectURL) URL.revokeObjectURL(this.objectURL);
    this.objectURL = null;
    if (this.dialog === dialog) this.dialog = null;
  }
}
